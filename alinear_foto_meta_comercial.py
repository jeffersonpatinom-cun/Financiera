# -*- coding: utf-8 -*-
"""Alinea Financiera.USP_Foto_Meta_Comercial_Mensual con la MARCA_ACADEMICA V2.

Este SP NO leia la marca de Cartera_Gestion: la recalculaba con una regla propia
y desactualizada. Lo que se corrige:

  1. Cortes de promedio: 1.56-2.95 (con hueco 1.55-1.56 que dejaba NULL) -> escalera
     contigua < 1.55 / < 3.0 / >= 3.0, igual que SP_Cartera_Total.
  2. Promedio coalescido COALESCE(B.PROMEDIO, E.PROMEDIO); antes solo usaba B.
  3. Fallbacks que faltaban: egresado/graduado -> GESTIONABLE, y ultimo acceso a
     Moodle <= 90 dias -> PERIODO EN CURSO.
  4. Catch-all: el CASE interno no tenia ELSE y devolvia NULL.
  5. Refinamiento por riesgo crediticio adverso ('Riesgo Alto' + 'Riesgo Regular'),
     que exige cruzar Financiaciones_CTAYUDA_V2 -- este SP no la cruzaba.
  6. Nueva columna MARCA_ACADEMICA_DETALLE, persistida en el historico.

NO se agrega la rama CARTERA EMPRESARIAL: el origen ya filtra
NOMBRE_TIPO_CLIENTE = 'ESTUDIANTES', asi que seria codigo muerto.

Genera el .sql y lo despliega. NO ejecuta el SP (corre a comienzo de mes).
"""
import io
import re
import sys

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
import pyodbc

CONN_STR = (
    'DRIVER={ODBC Driver 18 for SQL Server};'
    'SERVER=172.16.1.33;DATABASE=CUN_REPOSITORIO;'
    'Trusted_Connection=yes;TrustServerCertificate=yes;Connect Timeout=30;'
)
SRC = 'USP_Foto_Meta_Comercial_Mensual_BASELINE_20260821.sql'
OUT = 'alter_usp_foto_meta_comercial_marca_v2.sql'

d = open(SRC, encoding='utf-8').read()
n_ok = 0


def rep(viejo, nuevo, etiqueta, esperado=1):
    global d, n_ok
    c = d.count(viejo)
    if c != esperado:
        print('  [FALLO] %-46s encontrado %d veces (esperado %d)' % (etiqueta, c, esperado))
        sys.exit(1)
    d = d.replace(viejo, nuevo)
    n_ok += 1
    print('  [OK]    %s' % etiqueta)


# ------------------------------------------------------------------ 1) Bootstrap DDL
rep("""        IF COL_LENGTH('Financiera.Cartera_Meta_Comercial_Historico', 'MARCA_ACADEMICA') IS NULL
            ALTER TABLE Financiera.Cartera_Meta_Comercial_Historico ADD MARCA_ACADEMICA VARCHAR(50) NULL;""",
    """        IF COL_LENGTH('Financiera.Cartera_Meta_Comercial_Historico', 'MARCA_ACADEMICA') IS NULL
            ALTER TABLE Financiera.Cartera_Meta_Comercial_Historico ADD MARCA_ACADEMICA VARCHAR(50) NULL;
        IF COL_LENGTH('Financiera.Cartera_Meta_Comercial_Historico', 'MARCA_ACADEMICA_DETALLE') IS NULL
            ALTER TABLE Financiera.Cartera_Meta_Comercial_Historico ADD MARCA_ACADEMICA_DETALLE VARCHAR(50) NULL;""",
    '1) Bootstrap MARCA_ACADEMICA_DETALLE en el historico')

# ------------------------------------------------------------------ 2) CTE de riesgo
rep("""        PERIODO_CAL AS (""",
    """        -- Riesgo crediticio del deudor (replicado de [Financiera].[SP_Cartera_Total]).
        -- Dedup 1:1 por documento+periodo dejando el PEOR riesgo / menor score, para que
        -- el escalamiento sea conservador cuando hay varias financiaciones.
        CTAYUDA_RIESGO AS (
            SELECT DR_NUMERO_DOCUMENTO_ESTUDIANTE, ZH_PERIODO, RES_PERFIL_RIESGO
            FROM (
                SELECT DR_NUMERO_DOCUMENTO_ESTUDIANTE, ZH_PERIODO, RES_PERFIL_RIESGO,
                       ROW_NUMBER() OVER (
                           PARTITION BY DR_NUMERO_DOCUMENTO_ESTUDIANTE, ZH_PERIODO
                           ORDER BY CASE RES_PERFIL_RIESGO
                                        WHEN 'Riesgo Alto'      THEN 1
                                        WHEN 'Riesgo Regular'   THEN 2
                                        WHEN 'Riesgo Bueno'     THEN 3
                                        WHEN 'Riesgo Muy Bueno' THEN 4
                                        WHEN 'Riesgo Excelente' THEN 5
                                        ELSE 9 END ASC,
                                    TRY_CAST(RES_SCORE AS FLOAT) ASC
                       ) AS rn
                FROM Financiera.Financiaciones_CTAYUDA_V2
            ) x WHERE rn = 1
        ),
        PERIODO_CAL AS (""",
    '2) CTE CTAYUDA_RIESGO')

# ------------------------------------------------------------------ 3) La marca
rep("""            CASE
                WHEN PC.ESTADO = 'ACTIVO'                 THEN 'PERIODO EN CURSO'
                WHEN PC.ESTADO = 'PERIODO NO HA INICIADO' THEN 'PERIODO NO HA INICIADO'
                ELSE CASE
                        WHEN PC.ESTADO = 'NO ACTIVO' AND B.PROMEDIO < 1.55                THEN 'SIN REGISTRO DE CLASE'
                        WHEN PC.ESTADO = 'NO ACTIVO' AND B.PROMEDIO BETWEEN 1.56 AND 2.95 THEN 'PERIODO PERDIDO, PRIORIDAD ALTA'
                        WHEN PC.ESTADO = 'NO ACTIVO' AND B.PROMEDIO > 2.95               THEN 'GESTIONABLE'
                     END
            END                          AS MARCA_ACADEMICA
        INTO #SRC""",
    """            -- MARCA_ACADEMICA alineada con [Financiera].[SP_Cartera_Total] (V2, 2026-08-21).
            -- La escalera base vive en el CROSS APPLY MB de abajo; aqui solo se aplica el
            -- refinamiento por riesgo crediticio ADVERSO ('Riesgo Alto' + 'Riesgo Regular',
            -- score < 670): un caso academicamente blando pero con buro adverso se escala.
            CASE
                WHEN MB.MARCA_BASE = 'GESTIONABLE'
                 AND F.RES_PERFIL_RIESGO IN ('Riesgo Alto', 'Riesgo Regular')
                     THEN 'PERIODO PERDIDO, PRIORIDAD ALTA'
                ELSE MB.MARCA_BASE
            END                          AS MARCA_ACADEMICA,
            -- Subcategoria: ordena la cola de trabajo dentro de cada marca.
            CASE
                WHEN MB.MARCA_BASE = 'PERIODO NO HA INICIADO' THEN 'PERIODO NO HA INICIADO'

                WHEN MB.MARCA_BASE = 'PERIODO EN CURSO'
                 AND F.RES_PERFIL_RIESGO IN ('Riesgo Alto', 'Riesgo Regular')
                     THEN 'PERIODO EN CURSO - RIESGO CREDITICIO'
                WHEN MB.MARCA_BASE = 'PERIODO EN CURSO'      THEN 'PERIODO EN CURSO'

                WHEN MB.MARCA_BASE = 'PERIODO PERDIDO, PRIORIDAD ALTA'
                 AND F.RES_PERFIL_RIESGO IN ('Riesgo Alto', 'Riesgo Regular')
                     THEN 'PERIODO PERDIDO + RIESGO CREDITICIO'
                WHEN MB.MARCA_BASE = 'PERIODO PERDIDO, PRIORIDAD ALTA' THEN 'PERIODO PERDIDO'

                WHEN MB.MARCA_BASE = 'GESTIONABLE'
                 AND F.RES_PERFIL_RIESGO IN ('Riesgo Alto', 'Riesgo Regular')
                     THEN 'RIESGO CREDITICIO ADVERSO'
                WHEN MB.MARCA_BASE = 'GESTIONABLE'           THEN 'GESTIONABLE'

                WHEN M.Ultimo_acceso_moodle IS NOT NULL THEN 'SIN REGISTRO DE CLASE - CON CONEXION'
                ELSE 'SIN REGISTRO DE CLASE - SIN CONTACTO'
            END                          AS MARCA_ACADEMICA_DETALLE
        INTO #SRC""",
    '3) MARCA_ACADEMICA + MARCA_ACADEMICA_DETALLE')

# ------------------------------------------------------------------ 4) JOIN de riesgo + CROSS APPLY
rep("""        LEFT JOIN PERIODO_CAL PC
               ON S.PERIODO = PC.PERIODO;""",
    """        LEFT JOIN PERIODO_CAL PC
               ON S.PERIODO = PC.PERIODO
        LEFT JOIN CTAYUDA_RIESGO F
               ON CONVERT(VARCHAR(50), S.IDENTIFICACION) = F.DR_NUMERO_DOCUMENTO_ESTUDIANTE
              AND CONVERT(VARCHAR(20), S.PERIODO) = CONVERT(VARCHAR(20), F.ZH_PERIODO)
        -- Escalera academica base, identica a la de SP_Cartera_Total salvo la rama de
        -- segmento: aqui el origen ya filtra NOMBRE_TIPO_CLIENTE = 'ESTUDIANTES', asi que
        -- 'CARTERA EMPRESARIAL' seria codigo muerto y se omite a proposito.
        CROSS APPLY (VALUES (
            CASE
                WHEN PC.ESTADO = 'ACTIVO'                 THEN 'PERIODO EN CURSO'
                WHEN PC.ESTADO = 'PERIODO NO HA INICIADO' THEN 'PERIODO NO HA INICIADO'

                WHEN COALESCE(B.PROMEDIO, E.PROMEDIO) <  1.55 THEN 'SIN REGISTRO DE CLASE'
                WHEN COALESCE(B.PROMEDIO, E.PROMEDIO) <  3.0  THEN 'PERIODO PERDIDO, PRIORIDAD ALTA'
                WHEN COALESCE(B.PROMEDIO, E.PROMEDIO) >= 3.0  THEN 'GESTIONABLE'

                WHEN COALESCE(B.ESTADO_ALUMNO, Z.ESTADO_ALUMNO, E.ESTADO_ALUMNO) LIKE '%graduad%'
                  OR COALESCE(B.ESTADO_ALUMNO, Z.ESTADO_ALUMNO, E.ESTADO_ALUMNO) LIKE '%egresad%'
                                                              THEN 'GESTIONABLE'

                WHEN M.Ultimo_acceso_moodle >= DATEADD(DAY, -90, CAST(GETDATE() AS DATE))
                                                              THEN 'PERIODO EN CURSO'

                ELSE 'SIN REGISTRO DE CLASE'
            END
        )) AS MB(MARCA_BASE);""",
    '4) JOIN CTAYUDA_RIESGO + CROSS APPLY MARCA_BASE')

# ------------------------------------------------------------------ 5) UPDATE del historico
rep("""                   T.MARCA_ACADEMICA         = S.MARCA_ACADEMICA,        -- refresco mensual""",
    """                   T.MARCA_ACADEMICA         = S.MARCA_ACADEMICA,        -- refresco mensual
                   T.MARCA_ACADEMICA_DETALLE = S.MARCA_ACADEMICA_DETALLE,-- refresco mensual""",
    '5) UPDATE del historico')

# ------------------------------------------------------------------ 6) INSERT: columnas y valores
rep("""                 ESTADO_ALUMNO, MARCA_ACADEMICA,
                 Anio_Mes_Ingreso,""",
    """                 ESTADO_ALUMNO, MARCA_ACADEMICA, MARCA_ACADEMICA_DETALLE,
                 Anio_Mes_Ingreso,""",
    '6a) INSERT - lista de columnas')

rep("""                 S.ESTADO_ALUMNO, S.MARCA_ACADEMICA,
                 @Periodo, GETDATE(), GETDATE(), @Periodo""",
    """                 S.ESTADO_ALUMNO, S.MARCA_ACADEMICA, S.MARCA_ACADEMICA_DETALLE,
                 @Periodo, GETDATE(), GETDATE(), @Periodo""",
    '6b) INSERT - lista de valores')

# ------------------------------------------------------------------ verificaciones
assert 'BETWEEN 1.56 AND 2.95' not in d, 'quedo el corte viejo con hueco'
assert d.count('MARCA_ACADEMICA_DETALLE') >= 5
# La frase aparece en el comentario que explica por que se omite; lo que no debe
# existir es la rama que la ASIGNA.
assert "THEN 'CARTERA EMPRESARIAL'" not in d, 'rama muerta: el origen ya es solo ESTUDIANTES'
open(OUT, 'w', encoding='utf-8').write(d)
print('\n  %d/7 reemplazos aplicados -> %s' % (n_ok, OUT))

# ------------------------------------------------------------------ despliegue
ddl, n = re.subn(r'\bCREATE\s+(OR\s+ALTER\s+)?PROCEDURE\b', 'ALTER PROCEDURE', d, count=1)
if n != 1:
    sys.exit('ERROR: no se encontro el encabezado del procedimiento.')

conn = pyodbc.connect(CONN_STR, timeout=30)
conn.autocommit = True
conn.timeout = 600
cur = conn.cursor()

print('\n[1/2] Aplicando ALTER PROCEDURE Financiera.USP_Foto_Meta_Comercial_Mensual...')
cur.execute(ddl)
print('      OK - SP compilado.')

print('[2/2] Verificacion sobre la definicion viva:')
viva = cur.execute("""SELECT definition FROM sys.sql_modules
                      WHERE object_id=OBJECT_ID('Financiera.USP_Foto_Meta_Comercial_Mensual')""").fetchone()[0]
for etiqueta, aguja, debe_estar in [
        ('Escalera contigua (sin hueco 1.55-1.56)', 'BETWEEN 1.56 AND 2.95', False),
        ('Corte de aprobacion en 3.0', '>= 3.0', True),
        ('Promedio coalescido B/E', 'COALESCE(B.PROMEDIO, E.PROMEDIO)', True),
        ('Fallback egresado/graduado', "LIKE '%egresad%'", True),
        ('Fallback Moodle 90 dias', 'DATEADD(DAY, -90', True),
        ('Riesgo adverso Alto + Regular', "IN ('Riesgo Alto', 'Riesgo Regular')", True),
        ('Cruce con Financiaciones_CTAYUDA_V2', 'CTAYUDA_RIESGO', True),
        ('MARCA_ACADEMICA_DETALLE', 'MARCA_ACADEMICA_DETALLE', True)]:
    ok = (aguja in viva) == debe_estar
    print('      %-42s %s' % (etiqueta, 'OK' if ok else '*** REVISAR ***'))

print('\n      Modificado: %s' % cur.execute(
    "SELECT modify_date FROM sys.objects WHERE object_id=OBJECT_ID('Financiera.USP_Foto_Meta_Comercial_Mensual')"
).fetchone()[0])
print('\n      SP no ejecutado: se poblara en la corrida de comienzo de mes.')
conn.close()
