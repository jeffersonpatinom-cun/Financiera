# -*- coding: utf-8 -*-
"""
Muestra representativa y ANONIMIZADA de Financiera.Cartera_CUN_Asesor_Unico
para analisis con un LLM.

Autor: Analitica financiera - Universidad CUN

Diseno
------
1. Se eligen ~200 estudiantes (Tipo_cliente = 'ESTUDIANTES') por muestreo
   ESTRATIFICADO PROPORCIONAL sobre MARCA_ACADEMICA_GESTION, que es la
   variable que enruta la gestion de cobro. Dentro de cada estrato la
   seleccion es pseudoaleatoria pero REPRODUCIBLE (hash MD5 de la
   identificacion + semilla fija).
2. Se traen TODAS las filas de esos estudiantes, no una fila por persona.
   La tabla tiene grano OBLIGACION, no persona (~3,3 filas por estudiante):
   quedarse con una sola fila destruiria justo la estructura que un LLM
   necesita ver.
3. Se anonimiza en Python, no en SQL, con un mapa en memoria y una SAL
   ALEATORIA POR CORRIDA que NO se persiste en ningun lado. Sin la sal el
   mapeo no es reversible ni siquiera por quien corre el script.

Que se anonimiza (ver hoja "Anonimizacion" del Excel)
-----------------------------------------------------
- Identidad del estudiante  -> EST-0001, consistente en las 4 columnas que
  llevan la cedula. OJO con dos de ellas:
    * Documento es la cedula O el literal 'NDB' (marca de nueva deuda,
      37.755 filas). NDB es informacion de negocio y se conserva tal cual.
    * Documento_Cartera_CUN es una llave COMPUESTA
      {cedula}-{periodo}-{id_credito}. Se trata por partes para no destruir
      el periodo academico, que no es dato personal.
- Telefonos                 -> sinteticos, conservando la forma (celular
  colombiano 3XXXXXXXXX o fijo) para que el analisis de calidad de dato siga
  siendo posible.
- Correos                   -> estudianteNNNN@ejemplo-cun.edu.co. OJO: el
  correo institucional real se construye con el NOMBRE del estudiante
  (nombre.apellido@cun.edu.co), por eso es identificante y no se puede dejar.
- Direccion                 -> direccion sintetica con formato colombiano.
- Nombres de asesores       -> "Asesor NNN", preservando los centinelas de
  negocio ('CUN DIGITAL', 'Reasignar en CRM', 'Sin asignar'), que SI son
  informacion analitica y no un nombre propio. Cubre tanto Asesor_Unico (de
  quien es la cartera) como GESTION_ASESOR (quien la gestiono de verdad); el
  mapa es compartido, asi que un mismo asesor recibe el mismo alias en las dos.

  MANTENIMIENTO: cada vez que el SP exponga una columna nueva con nombres de
  personas hay que agregarla a COL_NOMBRE_ASE, o la muestra la publica en claro.
  La verificacion final aborta si detecta nombres sin anonimizar.
- Ids de Zoho y numero de credito -> sinteticos, consistentes entre columnas
  y entre filas, para que las llaves sigan cruzando dentro de la muestra.
- Texto libre               -> se enmascaran correos, cadenas largas de
  digitos y presuntos nombres propios. Ver LIMITACION abajo.

LIMITACION CONOCIDA
-------------------
La columna Descripcion es texto libre y SI contiene nombres completos de
personas ("Que el senor(a) APELLIDO APELLIDO NOMBRE...", "NOMBRE DEL
AFILIADO..."). El enmascarado usa una heuristica de frecuencia: una secuencia
de palabras en mayuscula se enmascara salvo que TODAS sus palabras sean
vocabulario de negocio conocido o aparezcan en >=3 filas distintas de la
muestra. Es buena, no es perfecta. Antes de enviar el archivo a un tercero,
revisar la hoja "Texto_libre_revisar", que lista los valores enmascarados
para inspeccion visual.
"""

import hashlib
import os
import random
import re
import secrets
import sys
from collections import Counter

import pandas as pd
import pyodbc

# ---------------------------------------------------------------- conexion
SERVER = '172.16.1.33'
DATABASE = 'CUN_REPOSITORIO'
CONN_STR = (
    'DRIVER={ODBC Driver 18 for SQL Server};'
    f'SERVER={SERVER};DATABASE={DATABASE};'
    'Trusted_Connection=yes;TrustServerCertificate=yes;Connect Timeout=30;'
)

TABLA = 'Financiera.Cartera_CUN_Asesor_Unico'
OBJETIVO_ESTUDIANTES = 200
SEMILLA_MUESTRA = 'muestra-llm-2026'          # fija: la muestra es reproducible
SAL = secrets.token_hex(16)                    # aleatoria: el mapeo NO lo es
SALIDA = 'Muestra_Cartera_CUN_Anonimizada.xlsx'


def conectar(query_timeout=1800):
    """El timeout de query va en conn.timeout, NO en cursor.timeout."""
    cn = pyodbc.connect(CONN_STR, timeout=30)
    cn.timeout = query_timeout
    return cn


# ------------------------------------------------------------- extraccion
SQL_MUESTRA = f"""
/* Estudiantes elegidos: estratificado proporcional por marca academica. */
WITH Base AS (
    SELECT CONVERT(varchar(20), [Número_de_identificación])                  AS ident,
           ISNULL(NULLIF(LTRIM(RTRIM(MARCA_ACADEMICA_GESTION)), ''),
                  '(SIN MARCA)')                                            AS marca
    FROM {TABLA}
    WHERE Tipo_cliente = 'ESTUDIANTES'
      AND NULLIF(LTRIM(RTRIM(CONVERT(varchar(20), [Número_de_identificación]))), '') IS NOT NULL
),
Conteo AS (
    SELECT ident, marca, COUNT(*) AS n FROM Base GROUP BY ident, marca
),
/* Un estudiante puede caer en varias marcas (varios periodos). Se le asigna
   la dominante para no contarlo dos veces en la estratificacion. */
Dominante AS (
    SELECT ident, marca,
           ROW_NUMBER() OVER (PARTITION BY ident ORDER BY n DESC, marca ASC) AS rn
    FROM Conteo
),
Estudiante AS (
    SELECT ident, marca FROM Dominante WHERE rn = 1
),
Ranked AS (
    SELECT ident, marca,
           ROW_NUMBER() OVER (
               PARTITION BY marca
               ORDER BY CONVERT(varbinary(16),
                                HASHBYTES('MD5', ident + '{SEMILLA_MUESTRA}'))
           )                                        AS rn_estrato,
           COUNT(*) OVER (PARTITION BY marca)       AS n_estrato,
           COUNT(*) OVER ()                         AS n_total
    FROM Estudiante
)
SELECT ident, marca, n_estrato, n_total
FROM Ranked
WHERE rn_estrato <= CEILING({OBJETIVO_ESTUDIANTES}.0 * n_estrato / n_total);
"""


def extraer():
    cn = conectar()
    print('Seleccionando estudiantes (muestreo estratificado)...', flush=True)
    elegidos = pd.read_sql(SQL_MUESTRA, cn)
    idents = elegidos['ident'].tolist()
    print(f'  {len(idents)} estudiantes en {elegidos["marca"].nunique()} estratos',
          flush=True)

    print('Trayendo todas las filas de esos estudiantes...', flush=True)
    marcas = ', '.join('?' * len(idents))
    sql = (f'SELECT * FROM {TABLA} '
           f'WHERE CONVERT(varchar(20), [Número_de_identificación]) IN ({marcas})')
    df = pd.read_sql(sql, cn, params=idents)
    cn.close()
    print(f'  {len(df)} filas x {len(df.columns)} columnas', flush=True)
    return df, elegidos


# ---------------------------------------------------------- anonimizacion
def _h(valor, ambito, modulo):
    """Entero determinista a partir de (valor, ambito, SAL)."""
    crudo = f'{ambito}|{SAL}|{valor}'.encode('utf-8')
    return int(hashlib.sha256(crudo).hexdigest(), 16) % modulo


def _vacio(v):
    return v is None or (isinstance(v, float) and pd.isna(v)) or str(v).strip() == ''


class Anonimizador:
    def __init__(self):
        self.est = {}          # cedula      -> EST-0001
        self.asesor = {}       # nombre      -> Asesor 001
        self.zoho = {}         # id zoho     -> id sintetico
        self.credito = {}      # n. credito  -> n. sintetico
        self.correo_est = {}
        self.correo_ase = {}

    # --- identidades ----------------------------------------------------
    def estudiante(self, v):
        if _vacio(v):
            return v
        k = str(v).strip()
        if k not in self.est:
            self.est[k] = f'EST-{len(self.est) + 1:04d}'
        return self.est[k]

    def nombre_asesor(self, v):
        if _vacio(v):
            return v
        k = str(v).strip()
        # Centinelas de negocio: son informacion, no nombres propios.
        if k.upper() in ('CUN DIGITAL', 'REASIGNAR EN CRM', 'SIN ASIGNAR'):
            return k
        if k not in self.asesor:
            self.asesor[k] = f'Asesor {len(self.asesor) + 1:03d}'
        return self.asesor[k]

    def id_zoho(self, v):
        if _vacio(v):
            return v
        k = str(v).strip()
        if k not in self.zoho:
            # Conserva el largo del id de Zoho (19 digitos) para que el
            # analisis de formato siga siendo valido.
            largo = max(len(k), 6)
            self.zoho[k] = str(_h(k, 'zoho', 10 ** largo)).zfill(largo)
        return self.zoho[k]

    def num_credito(self, v):
        if _vacio(v):
            return v
        k = str(v).strip()
        if k not in self.credito:
            largo = max(len(k), 6)
            self.credito[k] = str(_h(k, 'credito', 10 ** largo)).zfill(largo)
        return self.credito[k]

    # --- contacto -------------------------------------------------------
    def telefono(self, v):
        if _vacio(v):
            return v
        k = str(v).strip()
        digitos = re.sub(r'\D', '', k)
        if not digitos:
            return k
        if len(digitos) == 10 and digitos.startswith('3'):      # celular CO
            return '3' + str(_h(k, 'cel', 10 ** 9)).zfill(9)
        if len(digitos) == 10 and digitos.startswith('60'):     # fijo CO
            return '60' + str(_h(k, 'fijo', 10 ** 8)).zfill(8)
        return str(_h(k, 'tel', 10 ** len(digitos))).zfill(len(digitos))

    def correo_estudiante(self, v):
        if _vacio(v):
            return v
        k = str(v).strip().lower()
        if k not in self.correo_est:
            self.correo_est[k] = (f'estudiante{len(self.correo_est) + 1:04d}'
                                  '@ejemplo-cun.edu.co')
        return self.correo_est[k]

    def correo_asesor(self, v):
        if _vacio(v):
            return v
        k = str(v).strip().lower()
        if k not in self.correo_ase:
            self.correo_ase[k] = (f'asesor{len(self.correo_ase) + 1:03d}'
                                  '@ejemplo-cun.edu.co')
        return self.correo_ase[k]

    def documento(self, v):
        """Documento es la cedula O el literal 'NDB' (marca de nueva deuda,
        37.755 filas). NDB es informacion de negocio, no una identidad."""
        if _vacio(v):
            return v
        k = str(v).strip()
        return self.estudiante(k) if k.isdigit() else k

    def documento_cartera_cun(self, v):
        """Llave COMPUESTA: {cedula}-{periodo}-{id_credito}. Se trata por
        partes: la cedula toma el seudonimo del estudiante, el periodo se
        conserva (es informacion academica, no personal) y el id de credito
        toma el seudonimo de credito."""
        if _vacio(v):
            return v
        partes = str(v).strip().split('-')
        if len(partes) != 3 or not partes[0].isdigit():
            return self.estudiante(v)          # forma inesperada: se opaca entera
        cedula, periodo, credito = partes
        return f'{self.estudiante(cedula)}-{periodo}-{self.num_credito(credito)}'

    def direccion(self, v):
        if _vacio(v):
            return v
        k = str(v).strip()
        via = ['CL', 'KR', 'AV', 'DG', 'TV'][_h(k, 'via', 5)]
        return (f'{via} {_h(k, "d1", 120) + 1} # '
                f'{_h(k, "d2", 90) + 1}-{_h(k, "d3", 99) + 1}')


# ----------------------------------------------------- texto libre (PII)
VOCAB_NEGOCIO = {
    'SOLICITUD', 'CREADA', 'AUTOMATICAMENTE', 'POR', 'LIQUIDACION', 'NOTA',
    'GENERADA', 'PARA', 'EL', 'LA', 'CREDITO', 'CARGO', 'DE', 'GASTOS',
    'TRAMITE', 'AVAL', 'RECIBO', 'MIXTO', 'COBRO', 'AUTOMATICO', 'NIVEL',
    'IDIOMAS', 'RESTITUCION', 'DEUDA', 'ANULADO', 'REVERSION', 'DESDE',
    'DEBITO', 'REGISTRAR', 'PAGO', 'ABONO', 'SE', 'CARGA', 'DEL',
    'ESTUDIANTE', 'GENERA', 'NCR', 'AJUSTE', 'SALDOS', 'FAMA', 'DESCUENTO',
    'SEGUN', 'SEGÚN', 'RESOLUCION', 'ENTIDAD', 'NO', 'CARGUE', 'BENEFICIO',
    'CORREO', 'ENVIADO', 'APLICACION', 'ECONOMICO', 'RETIRAR', 'CORRE',
    'APLICA', 'LEGALIZACION', 'BAJO', 'LINEA', 'LÍNEA', 'TRADICIONAL',
    'CONVENIO', 'APOYO', 'MATRICULA', 'CUOTA', 'CUOTAS', 'ACUERDO', 'DIA',
    'VALOR', 'TOTAL', 'PARCIAL', 'PERIODO', 'PRIMERA', 'SEGUNDA', 'CAPITAL',
    'FINANCIEROS', 'ESTUDIANTES', 'CARGOS', 'FECHA', 'EXPEDICION',
    'CANCELADA', 'COBRANZA', 'NEGOCIACION', 'ANTIGUO', 'NUEVO', 'SIN',
    'CON', 'Y', 'O', 'A', 'EN', 'AL', 'ES', 'QUE', 'LOS', 'LAS', 'UN',
    'UNA', 'SU', 'SUS', 'MES', 'MESES', 'ANO', 'AÑO', 'CLTIENE',
    'FINANCIACION', 'FINANCIAC', 'ND', 'NCR', 'FOES', 'ALCALDIA',
    'ALCANDIA', 'COMFAMILIAR', 'ATLANTICO', 'SEM', 'CV', 'COTA', 'SYS',
    'TIC', 'AFILIADO', 'NOMBRE', 'SENOR', 'SEÑOR', 'SENORA', 'SEÑORA',
}

RE_CORREO = re.compile(r'[\w\.\-\+]+@[\w\.\-]+\.\w+')
RE_DIGITOS = re.compile(r'\d{6,}')
# 2+ palabras seguidas en mayuscula (con tildes y ñ), de 3+ letras cada una
RE_MAYUS = re.compile(r'\b[A-ZÁÉÍÓÚÑ]{3,}(?:\s+[A-ZÁÉÍÓÚÑ]{3,})+\b')


def construir_whitelist(series_texto):
    """Tokens en mayuscula que aparecen en >=3 filas distintas: vocabulario
    operativo, no nombres propios."""
    doc_freq = Counter()
    for v in series_texto:
        if _vacio(v):
            continue
        tokens = set(re.findall(r'\b[A-ZÁÉÍÓÚÑ]{3,}\b', str(v)))
        doc_freq.update(tokens)
    return {t for t, n in doc_freq.items() if n >= 3} | VOCAB_NEGOCIO


def redactar(valor, whitelist, contador):
    if _vacio(valor):
        return valor
    t = str(valor)
    t, n1 = RE_CORREO.subn('[CORREO]', t)
    t, n2 = RE_DIGITOS.subn('[NUM]', t)

    def _mask(m):
        palabras = m.group(0).split()
        if all(p in whitelist for p in palabras):
            return m.group(0)
        contador['nombres'] += 1
        return '[NOMBRE]'

    t = RE_MAYUS.sub(_mask, t)
    contador['correos'] += n1
    contador['numeros'] += n2
    return t


# --------------------------------------------------------------- mapeo
# Identificador siempre trae la misma cedula que Número_de_identificación
# (0 filas discrepantes; el resto son vacios), asi que comparten el mapa.
COL_ESTUDIANTE = ['Número_de_identificación', 'Identificador']
COL_TELEFONO = ['Celular', 'Teléfono', 'Otro_teléfono']
COL_CORREO_EST = ['Correo_electrónico', 'Correo_electrónico_secundario']
COL_CORREO_ASE = ['Usuarios.Correo_electrónico']
COL_DIRECCION = ['Dirección_casa']
# GESTION_ASESOR se agrega el 2026-09-03 con el SP de gestion real. Trae nombres de
# asesores igual que Asesor_Unico: si no entra en esta lista, la muestra "anonimizada"
# los publica en claro.
COL_NOMBRE_ASE = ['Propietario_de_Cartera_CUN_Name', 'Hecho_por',
                  'Asesor_Unico', 'GESTION_ASESOR', 'Ejecutivo_responsable',
                  'Usuarios.Nombre_completo']
COL_ID_ZOHO = ['Id', 'Interesado', 'Propietario_de_Cartera_CUN',
               'Modificado_por', 'Creado_por']
COL_CREDITO = ['Número_de_crédito']
COL_TEXTO = ['Descripción', 'Observaciones',
             'Observaciones_del_compromiso_de_pago',
             'Observaciones_pago_realizado', 'Motivo_de_no_acuerdo']


def anonimizar(df):
    a = Anonimizador()
    contador = Counter()
    presentes = lambda cols: [c for c in cols if c in df.columns]

    for c in presentes(COL_ESTUDIANTE):
        df[c] = df[c].map(a.estudiante)
    if 'Documento' in df.columns:
        df['Documento'] = df['Documento'].map(a.documento)
    if 'Documento_Cartera_CUN' in df.columns:
        df['Documento_Cartera_CUN'] = df['Documento_Cartera_CUN'].map(
            a.documento_cartera_cun)
    for c in presentes(COL_TELEFONO):
        df[c] = df[c].map(a.telefono)
    for c in presentes(COL_CORREO_EST):
        df[c] = df[c].map(a.correo_estudiante)
    for c in presentes(COL_CORREO_ASE):
        df[c] = df[c].map(a.correo_asesor)
    for c in presentes(COL_DIRECCION):
        df[c] = df[c].map(a.direccion)
    for c in presentes(COL_NOMBRE_ASE):
        df[c] = df[c].map(a.nombre_asesor)
    for c in presentes(COL_ID_ZOHO):
        df[c] = df[c].map(a.id_zoho)
    for c in presentes(COL_CREDITO):
        df[c] = df[c].map(a.num_credito)

    cols_texto = presentes(COL_TEXTO)
    todo_texto = pd.concat([df[c] for c in cols_texto]) if cols_texto else pd.Series(dtype=object)
    whitelist = construir_whitelist(todo_texto)
    revisar = []
    for c in cols_texto:
        antes = df[c].copy()
        df[c] = df[c].map(lambda v: redactar(v, whitelist, contador))
        cambio = antes.fillna('') != df[c].fillna('')
        for v in df.loc[cambio, c].head(200):
            revisar.append({'columna': c, 'texto_enmascarado': v})

    resumen = {
        'estudiantes_seudonimizados': len(a.est),
        'asesores_seudonimizados': len(a.asesor),
        'ids_zoho_seudonimizados': len(a.zoho),
        'creditos_seudonimizados': len(a.credito),
        'correos_estudiante_reemplazados': len(a.correo_est),
        'correos_asesor_reemplazados': len(a.correo_ase),
        'texto_libre_correos_enmascarados': contador['correos'],
        'texto_libre_numeros_enmascarados': contador['numeros'],
        'texto_libre_nombres_enmascarados': contador['nombres'],
    }
    return df, resumen, pd.DataFrame(revisar)


# ---------------------------------------------------------------- salida
def hoja_anonimizacion(resumen):
    filas = [
        ('Número_de_identificación / Identificador', 'Seudonimo EST-NNNN',
         'Identificador trae la misma cedula (0 filas discrepantes). Mismo seudonimo en ambas.'),
        ('Documento', "EST-NNNN o 'NDB' intacto",
         "Documento es la cedula O el literal 'NDB' (37.755 filas): NDB es marca de negocio, se conserva."),
        ('Documento_Cartera_CUN', 'EST-NNNN-{periodo}-{credito seudonimo}',
         'Llave COMPUESTA cedula-periodo-credito. Se trata por partes: el periodo academico se conserva.'),
        ('Celular / Teléfono / Otro_teléfono', 'Numero sintetico',
         'Se conserva la forma (celular 3XXXXXXXXX, fijo 60XXXXXXXX) y el largo.'),
        ('Correo_electrónico / Correo_electrónico_secundario',
         'estudianteNNNN@ejemplo-cun.edu.co',
         'El correo institucional real se arma con el nombre del estudiante: es identificante.'),
        ('Usuarios.Correo_electrónico', 'asesorNNN@ejemplo-cun.edu.co', 'Correo de personal interno.'),
        ('Dirección_casa', 'Direccion sintetica', 'Formato colombiano, sin relacion con la real.'),
        ('Propietario_de_Cartera_CUN_Name / Hecho_por / Asesor_Unico / Ejecutivo_responsable / Usuarios.Nombre_completo',
         'Asesor NNN',
         "Se PRESERVAN los centinelas 'CUN DIGITAL', 'Reasignar en CRM' y 'Sin asignar': son informacion de negocio."),
        ('Id / Interesado / Propietario_de_Cartera_CUN / Modificado_por / Creado_por',
         'Id sintetico del mismo largo', 'Consistente entre filas y columnas: las llaves siguen cruzando.'),
        ('Número_de_crédito', 'Numero sintetico del mismo largo', 'Consistente dentro de la muestra.'),
        ('Descripción / Observaciones / Observaciones_del_compromiso_de_pago / Observaciones_pago_realizado / Motivo_de_no_acuerdo',
         '[CORREO] / [NUM] / [NOMBRE]',
         'Texto libre. Heuristica de frecuencia para nombres: REVISAR la hoja Texto_libre_revisar.'),
        ('Resto de columnas (valores, fechas, estados, marcas academicas)',
         'SIN CAMBIOS', 'No son datos personales; se dejan intactos para el analisis.'),
    ]
    df = pd.DataFrame(filas, columns=['Columna(s)', 'Tratamiento', 'Nota'])
    res = pd.DataFrame(sorted(resumen.items()), columns=['Metrica', 'Valor'])
    return df, res


CENTINELAS = ('CUN DIGITAL', 'REASIGNAR EN CRM', 'SIN ASIGNAR')


def verificar_sin_nombres(df):
    """Aborta si algun nombre real de asesor sobrevivio a la anonimizacion.

    La lista de columnas a anonimizar (COL_NOMBRE_ASE) es manual, asi que se
    desactualiza sola cada vez que el SP expone una columna nueva con nombres —
    justo lo que paso con GESTION_ASESOR en septiembre de 2026. Esta verificacion
    no depende de esa lista: trae los nombres reales de la base y los busca en
    TODA la muestra ya anonimizada.
    """
    with conectar() as cn:
        cur = cn.cursor()
        nombres = set()
        for col in ('Asesor_Unico', 'GESTION_ASESOR', 'Hecho_por',
                    'Propietario_de_Cartera_CUN_Name'):
            if not cur.execute(
                    "SELECT COL_LENGTH(?, ?)", TABLA, col).fetchone()[0]:
                continue                      # la columna aun no existe
            for (v,) in cur.execute(
                    f'SELECT DISTINCT LTRIM(RTRIM(CONVERT(varchar(200), [{col}]))) '
                    f'FROM {TABLA} WHERE [{col}] IS NOT NULL').fetchall():
                if v and v.upper() not in CENTINELAS and len(v) > 4:
                    nombres.add(v.upper())

    fugas = []
    for col in df.columns:
        # NO filtrar por `dtype != object`: pandas nuevo entrega las columnas de
        # texto con dtype 'str' (StringDtype), no object, y esa comparacion
        # saltaba TODAS las columnas — la verificacion pasaba habiendo mirado
        # cero. Se descarta solo lo que con certeza no lleva nombres.
        if (pd.api.types.is_numeric_dtype(df[col])
                or pd.api.types.is_datetime64_any_dtype(df[col])
                or pd.api.types.is_bool_dtype(df[col])):
            continue
        vals = df[col].dropna().astype(str).str.strip().str.upper()
        hit = vals[vals.isin(nombres)]
        if not hit.empty:
            fugas.append(f'  {col}: {len(hit)} filas, p.ej. {hit.iloc[0][:40]!r}')

    if fugas:
        sys.exit('ABORTADO — nombres reales de asesor en la muestra anonimizada:\n'
                 + '\n'.join(fugas)
                 + '\n\nAgregar esas columnas a COL_NOMBRE_ASE y volver a correr.')
    print(f'  Verificacion: sin nombres reales ({len(nombres)} nombres buscados).')


def main():
    df, elegidos = extraer()
    n_filas, n_cols = df.shape
    df, resumen, revisar = anonimizar(df)
    verificar_sin_nombres(df)

    trato, res = hoja_anonimizacion(resumen)
    estratos = (elegidos.groupby('marca')
                .agg(estudiantes_en_muestra=('ident', 'count'),
                     estudiantes_en_poblacion=('n_estrato', 'max'))
                .reset_index())
    estratos['pct_poblacion'] = (100 * estratos['estudiantes_en_poblacion']
                                 / estratos['estudiantes_en_poblacion'].sum()).round(2)
    estratos['pct_muestra'] = (100 * estratos['estudiantes_en_muestra']
                               / estratos['estudiantes_en_muestra'].sum()).round(2)

    with pd.ExcelWriter(SALIDA, engine='openpyxl') as xl:
        df.to_excel(xl, sheet_name='Datos', index=False)
        estratos.to_excel(xl, sheet_name='Muestreo', index=False)
        trato.to_excel(xl, sheet_name='Anonimizacion', index=False)
        res.to_excel(xl, sheet_name='Anonimizacion', index=False,
                     startrow=len(trato) + 3)
        if not revisar.empty:
            revisar.to_excel(xl, sheet_name='Texto_libre_revisar', index=False)

    print(f'\nOK -> {os.path.abspath(SALIDA)}')
    print(f'  {n_filas} filas x {n_cols} columnas')
    print(f'  {resumen["estudiantes_seudonimizados"]} estudiantes distintos')
    for k, v in sorted(resumen.items()):
        print(f'  {k:42s} {v}')


if __name__ == '__main__':
    main()
