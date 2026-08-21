# -*- coding: utf-8 -*-
"""Simulacion READ-ONLY de la nueva MARCA_ACADEMICA antes de la corrida del job.

Replica las expresiones exactas ya desplegadas en SP_Cartera_Total usando los
valores YA materializados en Cartera_Gestion:
    PROMEDIO                    = COALESCE(B.PROMEDIO, E.PROMEDIO) del SP
    ultimoaccesoplataformlimpio = M.Ultimo_acceso_moodle del SP
    ESTADO, NOMBRE_TIPO_CLIENTE, RES_PERFIL_RIESGO = passthrough

Sirve para anticipar la distribucion de manana sin ejecutar el SP (10-13 min).
No escribe nada.
"""
import io
import sys

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
import pyodbc

CONN = ('DRIVER={ODBC Driver 18 for SQL Server};SERVER=172.16.1.33;'
        'DATABASE=CUN_REPOSITORIO;Trusted_Connection=yes;TrustServerCertificate=yes;')

MARCA_BASE = """
    CASE
        WHEN ISNULL(NOMBRE_TIPO_CLIENTE,'') <> 'ESTUDIANTES' THEN 'CARTERA EMPRESARIAL'
        WHEN ESTADO = 'ACTIVO'                 THEN 'PERIODO EN CURSO'
        WHEN ESTADO = 'PERIODO NO HA INICIADO' THEN 'PERIODO NO HA INICIADO'
        WHEN PROMEDIO <  1.55 THEN 'SIN REGISTRO DE CLASE'
        WHEN PROMEDIO <  3.0  THEN 'PERIODO PERDIDO, PRIORIDAD ALTA'
        WHEN PROMEDIO >= 3.0  THEN 'GESTIONABLE'
        WHEN ESTADO_ALUMNO LIKE '%graduad%' OR ESTADO_ALUMNO LIKE '%egresad%' THEN 'GESTIONABLE'
        WHEN ultimoaccesoplataformlimpio >= DATEADD(DAY,-90,CAST(GETDATE() AS DATE))
                              THEN 'PERIODO EN CURSO'
        ELSE 'SIN REGISTRO DE CLASE'
    END"""

SQL = """
WITH BASE AS (
    SELECT IDENTIFICACION, MARCA_ACADEMICA AS MARCA_HOY,
           RES_PERFIL_RIESGO, ultimoaccesoplataformlimpio,
           {mb} AS MARCA_BASE
    FROM Financiera.Cartera_Gestion
), NUEVA AS (
    SELECT *,
        CASE WHEN MARCA_BASE = 'GESTIONABLE'
              AND RES_PERFIL_RIESGO IN ('Riesgo Alto','Riesgo Regular')
                  THEN 'PERIODO PERDIDO, PRIORIDAD ALTA'
             ELSE MARCA_BASE END AS MARCA_NUEVA,
        CASE
            WHEN MARCA_BASE = 'CARTERA EMPRESARIAL'    THEN 'CARTERA EMPRESARIAL'
            WHEN MARCA_BASE = 'PERIODO NO HA INICIADO' THEN 'PERIODO NO HA INICIADO'
            WHEN MARCA_BASE = 'PERIODO EN CURSO'
             AND RES_PERFIL_RIESGO IN ('Riesgo Alto','Riesgo Regular')
                                                       THEN 'PERIODO EN CURSO - RIESGO CREDITICIO'
            WHEN MARCA_BASE = 'PERIODO EN CURSO'       THEN 'PERIODO EN CURSO'
            WHEN MARCA_BASE = 'PERIODO PERDIDO, PRIORIDAD ALTA'
             AND RES_PERFIL_RIESGO IN ('Riesgo Alto','Riesgo Regular')
                                                       THEN 'PERIODO PERDIDO + RIESGO CREDITICIO'
            WHEN MARCA_BASE = 'PERIODO PERDIDO, PRIORIDAD ALTA' THEN 'PERIODO PERDIDO'
            WHEN MARCA_BASE = 'GESTIONABLE'
             AND RES_PERFIL_RIESGO IN ('Riesgo Alto','Riesgo Regular')
                                                       THEN 'RIESGO CREDITICIO ADVERSO'
            WHEN MARCA_BASE = 'GESTIONABLE'            THEN 'GESTIONABLE'
            WHEN ultimoaccesoplataformlimpio IS NOT NULL
                                                THEN 'SIN REGISTRO DE CLASE - CON CONEXION'
            ELSE 'SIN REGISTRO DE CLASE - SIN CONTACTO'
        END AS DETALLE
    FROM BASE
)
""".format(mb=MARCA_BASE)

cn = pyodbc.connect(CONN, timeout=30); cn.timeout = 900
cu = cn.cursor()


def q(titulo, cola):
    print('\n=== ' + titulo)
    cu.execute(SQL + cola)
    print('  ' + ' | '.join(c[0] for c in cu.description))
    for r in cu.fetchall():
        print('  ' + ' | '.join('(vacio)' if v is None else str(v) for v in r))


q('1. Distribucion nueva vs actual', """
SELECT MARCA_NUEVA, COUNT(*) OBLIGACIONES, COUNT(DISTINCT IDENTIFICACION) CLIENTES
FROM NUEVA GROUP BY MARCA_NUEVA ORDER BY OBLIGACIONES DESC""")

q('2. Matriz de movimiento (solo lo que cambia)', """
SELECT MARCA_HOY, MARCA_NUEVA, COUNT(*) OBLIGACIONES
FROM NUEVA WHERE MARCA_HOY <> MARCA_NUEVA
GROUP BY MARCA_HOY, MARCA_NUEVA ORDER BY OBLIGACIONES DESC""")

q('3. Marcas vacias o nulas (debe dar 0)', """
SELECT SUM(CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(MARCA_NUEVA,''))),'') IS NULL THEN 1 ELSE 0 END) MARCA_VACIA,
       SUM(CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(DETALLE,''))),'')     IS NULL THEN 1 ELSE 0 END) DETALLE_VACIO,
       COUNT(*) TOTAL
FROM NUEVA""")

q('4. Apertura por detalle', """
SELECT DETALLE, COUNT(*) OBLIGACIONES, COUNT(DISTINCT IDENTIFICACION) CLIENTES
FROM NUEVA GROUP BY DETALLE ORDER BY OBLIGACIONES DESC""")

q('5. Longitud maxima de los valores (cabe en varchar(50)?)', """
SELECT MAX(LEN(MARCA_NUEVA)) MAX_MARCA, MAX(LEN(DETALLE)) MAX_DETALLE FROM NUEVA""")

cn.close()
