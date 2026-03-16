"""
ETL Zoho Llamadas
=================
Cruza zoho.Base_Personas con coe.venta_contact_nuevo por número de teléfono
normalizado y carga el resultado en coe.FCT_Zoho_Llamadas.

Estrategia de carga:
  - Siempre carga completa (TRUNCATE + INSERT) para el año en curso.
  - El año se determina automáticamente con datetime.now().year.
  - Variable de entorno ETL_ZOHO_ANIO sobreescribe el año si se necesita
    procesar un año específico.

Columna de auditoría:
  - [timestamp] : datetime que registra cuándo se realizó la carga.

Variables de entorno requeridas:
    ETL_DB_USER            - Usuario de base de datos
    ETL_DB_PASSWORD        - Contraseña de base de datos

Variables de entorno opcionales:
    ETL_DB_SERVER          - Servidor       (default: 172.16.1.33)
    ETL_DB_DATABASE        - Base de datos  (default: CUN_REPOSITORIO)
    ETL_ZOHO_TABLA_DESTINO - Tabla destino  (default: FCT_Zoho_Llamadas)
    ETL_ZOHO_TABLA_SCHEMA  - Schema destino (default: coe)
    ETL_ZOHO_CHUNK_SIZE    - Lote de carga  (default: 5000)
    ETL_ZOHO_ANIO          - Año a procesar (default: año actual)
"""

import os
import re
import logging
import unicodedata
import urllib.parse
from datetime import datetime
from pathlib import Path

from dotenv import load_dotenv
load_dotenv()

import pandas as pd
import pyodbc
from rapidfuzz import fuzz
from sqlalchemy import create_engine


# ---------------------------------------------------------------------------
# Logging — consola + archivo (última ejecución siempre al inicio del log)
# ---------------------------------------------------------------------------
import io as _io

_LOG_DIR = Path(__file__).parent / 'logs'
_LOG_DIR.mkdir(exist_ok=True)

_MESES_ES = [
    'enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio',
    'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre',
]
_DIAS_ES = ['lunes', 'martes', 'miercoles', 'jueves', 'viernes', 'sabado', 'domingo']


class _FmtES(logging.Formatter):
    """Formatter con fecha en español: 2026-marzo-10-martes 14:16:25"""
    def formatTime(self, record, datefmt=None):
        dt = datetime.fromtimestamp(record.created)
        mes = _MESES_ES[dt.month - 1]
        dia = _DIAS_ES[dt.weekday()]
        return dt.strftime(f'%Y-{mes}-%d-{dia} %H:%M:%S')


_fmt = _FmtES('%(asctime)s | %(levelname)s | %(message)s')

# Buffer en memoria que captura los logs de la ejecución actual
_run_buffer = _io.StringIO()
_run_handler = logging.StreamHandler(_run_buffer)
_run_handler.setFormatter(_fmt)
_run_handler.setLevel(logging.INFO)

_console = logging.StreamHandler()
_console.setFormatter(_fmt)
_console.setLevel(logging.INFO)

_error_handler = logging.FileHandler(
    filename=_LOG_DIR / 'etl_zoho_llamadas_errores.log',
    mode='a',
    encoding='utf-8',
)
_error_handler.setFormatter(_fmt)
_error_handler.setLevel(logging.ERROR)

logging.basicConfig(level=logging.INFO, handlers=[_console, _run_handler, _error_handler])
log = logging.getLogger(__name__)


def _flush_log_to_file() -> None:
    """Prepende los logs de esta ejecución al inicio del archivo principal."""
    _run_handler.flush()
    nuevo = _run_buffer.getvalue()
    if not nuevo:
        return
    log_path = _LOG_DIR / 'etl_zoho_llamadas.log'
    existente = log_path.read_text(encoding='utf-8') if log_path.exists() else ''
    separador = '-' * 80 + '\n'
    log_path.write_text(nuevo + separador + existente, encoding='utf-8')


def log_etl(step: str, status: str, rows: int = 0, msg: str = '') -> None:
    """Registra un evento ETL estructurado: STEP | STATUS | ROWS | MSG."""
    entry = f'{step.upper()} | {status.upper()} | {rows} | {msg}'
    if status.upper() in ('ERROR', 'WARNING'):
        log.warning(entry) if status.upper() == 'WARNING' else log.error(entry)
    else:
        log.info(entry)


# ---------------------------------------------------------------------------
# Configuración
# ---------------------------------------------------------------------------
SERVER         = os.environ.get('ETL_DB_SERVER',           '172.16.1.33')
DATABASE       = os.environ.get('ETL_DB_DATABASE',         'CUN_REPOSITORIO')
TABLA_DESTINO  = os.environ.get('ETL_ZOHO_TABLA_DESTINO',  'FCT_Zoho_Llamadas')
SCHEMA_DESTINO = os.environ.get('ETL_ZOHO_TABLA_SCHEMA',   'coe')
CHUNK_SIZE     = int(os.environ.get('ETL_ZOHO_CHUNK_SIZE', '5000'))
ANIO_ACTUAL    = os.environ.get('ETL_ZOHO_ANIO', str(datetime.now().year))

_usuario  = os.environ.get('ETL_DB_USER')
_password = os.environ.get('ETL_DB_PASSWORD')
if not _usuario or not _password:
    raise EnvironmentError(
        'Se requieren las variables de entorno ETL_DB_USER y ETL_DB_PASSWORD.'
    )

# Columnas de texto sobre las que se aplica normalización completa
COLUMNAS_TEXTO = [
    'NOM_TERCERO', 'SEG_NOMBRE', 'PRI_APELLIDO', 'SEG_APELLIDO',
    'EMAIL', 'EMAIL_INS', 'EMAIL_PER',
    'PROGRAMA', 'NOM_PROGRAMA', 'SEDE', 'SECCIONAL',
    'VENDEDOR', 'NOM_VENDEDOR', 'CLASE_ACTUAL', 'TIPO',
    'Ciudad', 'Departamento', 'Localidad',
    'Programa_Detectado',
    'correo', 'Usuario_crea',
]

# Columnas de email: no se eliminan tildes ni caracteres especiales del dominio
COLUMNAS_EMAIL = ['EMAIL', 'EMAIL_INS', 'EMAIL_PER', 'correo']

# Columna que siempre debe tener valor (ISNULL de ambos lados del JOIN)
COLUMNAS_CLAVE = ['Telefono_Limpio']


# ---------------------------------------------------------------------------
# Normalización de texto
# ---------------------------------------------------------------------------
def _quitar_tildes(texto: str) -> str:
    """Convierte caracteres acentuados a su equivalente ASCII (á→a, ñ→n, etc.)."""
    return ''.join(
        c for c in unicodedata.normalize('NFD', texto)
        if unicodedata.category(c) != 'Mn'
    )


def normalizar_texto(valor) -> object:
    """
    Normaliza una celda de texto:
      1. Strip de espacios extremos
      2. Elimina caracteres especiales (conserva letras, números, espacios y . @ _ -)
      3. Colapsa espacios dobles o múltiples a uno solo
      4. Quita tildes y acentuaciones
    Retorna el valor original si no es str (preserva None/NaN).
    """
    if not isinstance(valor, str):
        return valor
    valor = valor.strip()
    valor = re.sub(r'[^A-Za-záéíóúÁÉÍÓÚüÜ0-9 .@_\-]', '', valor)
    valor = re.sub(r' {2,}', ' ', valor)
    valor = _quitar_tildes(valor)
    return valor


def normalizar_email(valor) -> object:
    """
    Normalización más suave para emails:
      1. Strip y minúsculas
      2. Elimina espacios internos
    No elimina tildes ni caracteres especiales para no corromper el dominio.
    """
    if not isinstance(valor, str):
        return valor
    return valor.strip().lower().replace(' ', '')


# Sufijos a eliminar al final del nombre del programa
_RE_MODALIDAD = re.compile(
    r'\s*[-–]?\s*\b(Virtual|Presencial|A\s+Distancia|Distancia|Semipresencial)\b\s*$',
    re.IGNORECASE,
)
# Ciudad: " - BOGOTA", " - SANTA MARTA", etc. (1-3 palabras en mayúsculas tras guion)
_RE_CIUDAD = re.compile(r'\s+[-–]\s+[A-Z][A-Z\s]{1,30}$')


def unificar_programas(serie: pd.Series, umbral: int = 85) -> tuple[pd.Series, int]:
    """
    Unifica nombres de programas académicos similares en dos pasos:

    Paso 1 — Limpieza de sufijos:
      - Elimina modalidad al final: Virtual, Presencial, A Distancia, Semipresencial
      - Elimina ciudad al final: " - BOGOTA", " - SANTA MARTA", etc.

    Paso 2 — Clustering fuzzy (fuzz.ratio >= umbral):
      - Agrupa nombres con similitud >= umbral
      - Asigna como canónico el nombre más frecuente del grupo

    Retorna la Serie normalizada y el número de programas unificados.
    """
    def _limpiar_sufijos(x):
        if not isinstance(x, str):
            return x
        x = _RE_MODALIDAD.sub('', x).strip()
        x = _RE_CIUDAD.sub('', x).strip()
        return x

    serie = serie.apply(_limpiar_sufijos)

    # Frecuencias descendentes → el primero del grupo es el más frecuente (canónico)
    frecuencias = serie.value_counts()
    valores = [v for v in frecuencias.index if isinstance(v, str)]

    mapa: dict[str, str] = {}
    procesados: set[str] = set()
    unificados = 0

    for val in valores:
        if val in procesados:
            continue
        grupo = [
            v for v in valores
            if v not in procesados and fuzz.ratio(val, v) >= umbral
        ]
        canonical = grupo[0]  # más frecuente del grupo
        for v in grupo:
            mapa[v] = canonical
            procesados.add(v)
        if len(grupo) > 1:
            unificados += len(grupo) - 1

    return serie.apply(lambda x: mapa.get(x, x) if isinstance(x, str) else x), unificados


# ---------------------------------------------------------------------------
# SQL de extracción
# ---------------------------------------------------------------------------
def build_sql(anio: str) -> str:
    """
    Construye el query filtrando por el año indicado.
    Siempre carga completa: ANIO = anio (o NULL para no perder registros sin año).

    Deduplicación en SQL antes del JOIN:
      - Zoho : llave_zoho = PERIODO|DOC_ALUM|PROGRAMA
               Prioridad 1: ESTADO_PAGO = 'PAGO'  → se conserva sobre cualquier otro estado
               Prioridad 2 (desempate): FEC_VENTA más reciente
                 → Si todos los registros del grupo tienen ESTADO_PAGO = 'NO PAGO',
                   se conserva el de FEC_VENTA más reciente
      - COE  : llave_llamadas = Celular_Prospecto|Fecha|Hora_Llamada
               Sin prioridad específica (se conserva un registro por combinación)
    """
    filtro_zoho = (
        f"(CLASE_ACTUAL = 'Nuevo' ) "
        f"AND TIPO IN ('pregrado', 'postgrado')  "
        f"AND ANIO = '{anio}' "
    )

    return f"""
WITH
-- ── Zoho: dedup por PERIODO+DOC_ALUM+PROGRAMA, prioridad ESTADO_PAGO='PAGO' ──────────
Zoho_Raw AS (
    SELECT
        *,
        CONCAT(
            COALESCE(CAST(PERIODO   AS VARCHAR(50)), ''), '|',
            COALESCE(CAST(DOC_ALUM  AS VARCHAR(50)), ''), '|',
            COALESCE(CAST(PROGRAMA  AS VARCHAR(50)), '')
        ) AS llave_zoho,
        RIGHT(REPLACE(REPLACE(REPLACE(REPLACE(TEL_CASA, ' ', ''), '-', ''), '(', ''), ')', ''), 10) AS tel_match,
        ROW_NUMBER() OVER (
            PARTITION BY PERIODO, DOC_ALUM, PROGRAMA
            ORDER BY
                CASE WHEN ESTADO_PAGO = 'PAGO' THEN 0 ELSE 1 END,
                TRY_CAST(FEC_VENTA AS DATE) DESC  -- desempate: registro más reciente
        ) AS rn_zoho
    FROM zoho.Base_Personas
    WHERE {filtro_zoho}
),
Zoho_Filtrado AS (
    SELECT * FROM Zoho_Raw WHERE rn_zoho = 1
),

-- ── COE: dedup por Celular_Prospecto+Fecha+Hora_Llamada ─────────────────────────────
COE_Raw AS (
    SELECT
        *,
        CONCAT(
            COALESCE(CAST(Celular_Prospecto AS VARCHAR(50)), ''), '|',
            COALESCE(CAST(Fecha            AS VARCHAR(50)), ''), '|',
            COALESCE(CAST(Hora_Llamada     AS VARCHAR(50)), '')
        ) AS llave_llamadas,
        RIGHT(REPLACE(REPLACE(REPLACE(REPLACE(celular_prospecto, ' ', ''), '-', ''), '(', ''), ')', ''), 10) AS cel_match,
        ROW_NUMBER() OVER (
            PARTITION BY Celular_Prospecto, Fecha, Hora_Llamada
            ORDER BY (SELECT NULL)
        ) AS rn_coe
    FROM coe.venta_contact_nuevo
),
COE_Filtrado AS (
    SELECT * FROM COE_Raw WHERE rn_coe = 1
)

SELECT
    ISNULL(z.tel_match, c.cel_match) AS Telefono_Limpio,
    z.*,
    c.*
FROM Zoho_Filtrado z
FULL OUTER JOIN COE_Filtrado c
    ON z.tel_match = c.cel_match
"""


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def get_driver() -> str:
    drivers = [d for d in pyodbc.drivers() if 'SQL Server' in d]
    if not drivers:
        raise RuntimeError('No se encontró un driver ODBC de SQL Server instalado.')
    return drivers[-1]


def build_engine(driver: str):
    params = urllib.parse.quote_plus(
        f"DRIVER={{{driver}}};SERVER={SERVER};DATABASE={DATABASE};"
        f"UID={_usuario};PWD={_password};TrustServerCertificate=yes"
    )
    return create_engine(
        f"mssql+pyodbc:///?odbc_connect={params}",
        fast_executemany=True,
    )


# ---------------------------------------------------------------------------
# Fases ETL
# ---------------------------------------------------------------------------
def extraer(engine, sql: str) -> pd.DataFrame:
    log_etl('EXTRACCION', 'START', msg=f'Servidor {SERVER} | BD {DATABASE} | Año {ANIO_ACTUAL}')
    df = pd.read_sql_query(sql, engine)
    if df.empty:
        log_etl('EXTRACCION', 'ERROR', msg='La consulta no retornó registros. Se cancela la carga.')
        raise ValueError('La consulta no retornó registros. Se cancela la carga.')
    log_etl('EXTRACCION', 'SUCCESS', rows=len(df))
    return df


def transformar(df: pd.DataFrame) -> pd.DataFrame:
    log_etl('TRANSFORMACION', 'START', rows=len(df))
    total_inicial = len(df)

    # 1. Eliminar columnas auxiliares del dedup SQL (no deben ir a destino)
    for col in ['rn_zoho', 'rn_coe']:
        if col in df.columns:
            df = df.drop(columns=[col])

    # 2. Normalización de texto: tildes, caracteres especiales y espacios dobles
    _SIN_UPPER = set(COLUMNAS_EMAIL) | {'Programa_Detectado'}
    for col in COLUMNAS_TEXTO:
        if col in df.columns:
            if col in COLUMNAS_EMAIL:
                df[col] = df[col].apply(normalizar_email)
            else:
                df[col] = df[col].apply(normalizar_texto)
                if col not in _SIN_UPPER:
                    df[col] = df[col].str.upper()
    log_etl('NORMALIZACION', 'SUCCESS', msg='Tildes, caracteres especiales y mayusculas aplicados')

    # 3. Unificar nombres de programas por similitud (solo columna PROGRAMA de Zoho)
    if 'PROGRAMA' in df.columns:
        df['PROGRAMA'], n_unif = unificar_programas(df['PROGRAMA'])
        log_etl('UNIF_PROGRAMAS', 'SUCCESS', rows=n_unif, msg='Programas unificados por similitud fuzzy')

    # 4. PROGRAMA_LIMPIO_JOIN: unifica PROGRAMA (Zoho) y Programa_Detectado (COE)
    #    Prioridad: PROGRAMA cuando existe → fallback Programa_Detectado
    #    Valores ignorados: nulos, vacíos o 'No Detectado'
    _NO_DETECTADO = {'', 'NO DETECTADO', 'NO DETECTO', 'N/A', 'NONE'}

    def _es_valido(v):
        return isinstance(v, str) and v.strip().upper() not in _NO_DETECTADO

    if 'PROGRAMA' in df.columns and 'Programa_Detectado' in df.columns:
        df['PROGRAMA_LIMPIO_JOIN'] = df.apply(
            lambda r: (
                r['PROGRAMA'].strip()          if _es_valido(r['PROGRAMA'])          else
                r['Programa_Detectado'].strip() if _es_valido(r['Programa_Detectado']) else
                None
            ),
            axis=1,
        )

        # Verificar coincidencias fuzzy en pares únicos (PROGRAMA, Programa_Detectado)
        mask_ambos = df['PROGRAMA'].apply(_es_valido) & df['Programa_Detectado'].apply(_es_valido)
        pares_unicos = (
            df.loc[mask_ambos, ['PROGRAMA', 'Programa_Detectado']]
            .drop_duplicates()
        )
        if not pares_unicos.empty:
            coincidencias = pares_unicos.apply(
                lambda r: fuzz.ratio(r['PROGRAMA'].upper(), r['Programa_Detectado'].upper()) >= 70,
                axis=1,
            ).sum()
            log_etl(
                'PROGRAMA_JOIN', 'SUCCESS',
                rows=df['PROGRAMA_LIMPIO_JOIN'].notna().sum(),
                msg=f'Coincidencias Zoho-COE (>=70%): {coincidencias} de {len(pares_unicos)} pares unicos',
            )
        else:
            log_etl('PROGRAMA_JOIN', 'SUCCESS', msg='Sin pares para verificar coincidencias')

    # 5. Descartar registros sin teléfono limpio
    # Excepción: si el registro proviene de Zoho (llave_zoho no es null), se conserva
    # aunque su teléfono sea null (puede tener datos valiosos de otros campos).
    # Solo se descartan registros sin teléfono que tampoco tienen datos de Zoho (COE puro).
    antes = len(df)
    tiene_zoho = df['llave_zoho'].notna() if 'llave_zoho' in df.columns else pd.Series(False, index=df.index)
    df = df[df[COLUMNAS_CLAVE[0]].notna() | tiene_zoho]
    descartados = antes - len(df)
    if descartados > 0:
        log_etl('FILTRO_TELEFONO', 'WARNING', rows=descartados, msg='Registros COE sin telefono descartados')

    # 6. Columna de auditoría
    # Nota: 'timestamp' es palabra reservada en SQL Server; pandas lo escapa con [timestamp]
    df['timestamp'] = datetime.now().replace(microsecond=0)

    log_etl('TRANSFORMACION', 'SUCCESS', rows=len(df), msg=f'{total_inicial} -> {len(df)} registros')
    return df


def cargar(df: pd.DataFrame, engine) -> None:
    if df.empty:
        log_etl('CARGA', 'WARNING', msg='Sin registros. Tabla destino no modificada.')
        return

    tabla_fqn = f'{SCHEMA_DESTINO}.{TABLA_DESTINO}'
    log_etl('CARGA', 'START', rows=len(df), msg=tabla_fqn)

    # Deduplicar nombres de columna (SQL Server es case-insensitive: TIPO == Tipo)
    seen_upper: dict[str, int] = {}
    new_cols = []
    for col in df.columns:
        key = col.upper()
        if key in seen_upper:
            seen_upper[key] += 1
            new_name = f"{col}_{seen_upper[key]}"
            new_cols.append(new_name)
            log_etl('CARGA', 'WARNING', msg=f'Columna duplicada renombrada: {col} -> {new_name}')
        else:
            seen_upper[key] = 0
            new_cols.append(col)
    df.columns = new_cols

    with engine.begin() as conn:
        # Carga completa: replace recrea la tabla con el esquema actual del DataFrame.
        # Esto maneja automáticamente cualquier cambio de columnas entre ejecuciones.
        df.to_sql(
            TABLA_DESTINO,
            conn,
            schema=SCHEMA_DESTINO,
            if_exists='replace',
            index=False,
            chunksize=CHUNK_SIZE,
        )

    log_etl('CARGA', 'SUCCESS', rows=len(df), msg=f'{DATABASE}.{tabla_fqn}')


# ---------------------------------------------------------------------------
# Punto de entrada
# ---------------------------------------------------------------------------
def main() -> None:
    engine = None
    try:
        driver = get_driver()
        log_etl('ETL', 'START', msg=f'Driver: {driver} | Año: {ANIO_ACTUAL}')
        engine = build_engine(driver)

        sql = build_sql(ANIO_ACTUAL)

        df = extraer(engine, sql)
        df = transformar(df)
        cargar(df, engine)

        log_etl('ETL', 'SUCCESS')

    except Exception as e:
        linea = e.__traceback__.tb_lineno if e.__traceback__ else '?'
        log_etl('ETL', 'ERROR', msg=f'Linea {linea}: {type(e).__name__}: {e}')
        raise

    finally:
        if engine is not None:
            engine.dispose()
            log_etl('CONEXION', 'CLOSED')
        _flush_log_to_file()


if __name__ == '__main__':
    main()
