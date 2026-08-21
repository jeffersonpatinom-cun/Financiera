# -*- coding: utf-8 -*-
"""Expone MARCA_ACADEMICA_DETALLE en Financiera.Usp_Cartera_CUN_Asesor_Unico.

Se aliasa como MARCA_ACADEMICA_DETALLE_GESTION, siguiendo la convencion _GESTION
que ya usa ese SP para las columnas que vienen de Cartera_Gestion y que chocarian
de nombre con las de Cartera_CUN (c.*).

Bootstrap previo: Cartera_Gestion aun no tiene la columna (se materializa en la
proxima corrida de SP_Cartera_Total). Sin el ALTER TABLE, el ALTER PROCEDURE
falla con error 207 al resolver ct.MARCA_ACADEMICA_DETALLE.
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
SRC = 'Usp_Cartera_CUN_Asesor_Unico_BASELINE_20260821.sql'
OUT = 'alter_usp_cartera_cun_asesor_unico_detalle.sql'

VIEJO = "            ct.MARCA_ACADEMICA             AS MARCA_ACADEMICA_GESTION,"
NUEVO = ("            ct.MARCA_ACADEMICA             AS MARCA_ACADEMICA_GESTION,\n"
         "            ct.MARCA_ACADEMICA_DETALLE     AS MARCA_ACADEMICA_DETALLE_GESTION,")

d = open(SRC, encoding='utf-8').read()
if d.count(VIEJO) != 1:
    sys.exit('ERROR: el ancla aparece %d veces (esperado 1).' % d.count(VIEJO))
d = d.replace(VIEJO, NUEVO)
open(OUT, 'w', encoding='utf-8').write(d)
print('Generado %s' % OUT)

# El encabezado viene como "CREATE   PROCEDURE" (lo deja un CREATE OR ALTER previo),
# por eso el reemplazo tolera espacios multiples.
ddl, n = re.subn(r'\bCREATE\s+PROCEDURE\b', 'ALTER PROCEDURE', d, count=1)
if n != 1:
    sys.exit('ERROR: no se encontro el encabezado del procedimiento.')

conn = pyodbc.connect(CONN_STR, timeout=30)
conn.autocommit = True
conn.timeout = 600
cur = conn.cursor()

print('[1/3] Bootstrap en Cartera_Gestion (se recrea en la proxima corrida del SP)...')
cur.execute("""
    IF COL_LENGTH('Financiera.Cartera_Gestion','MARCA_ACADEMICA_DETALLE') IS NULL
        ALTER TABLE Financiera.Cartera_Gestion ADD MARCA_ACADEMICA_DETALLE varchar(50) NULL;
""")
tiene = cur.execute(
    "SELECT COL_LENGTH('Financiera.Cartera_Gestion','MARCA_ACADEMICA_DETALLE')").fetchone()[0]
print('      Cartera_Gestion.MARCA_ACADEMICA_DETALLE -> %s' % ('OK' if tiene else 'NO CREADA'))
if not tiene:
    sys.exit('ERROR: columna no creada; se aborta.')

print('[2/3] Aplicando ALTER PROCEDURE Financiera.Usp_Cartera_CUN_Asesor_Unico...')
cur.execute(ddl)
print('      OK - SP compilado.')

print('[3/3] Verificacion:')
viva = cur.execute("""SELECT definition FROM sys.sql_modules
                      WHERE object_id=OBJECT_ID('Financiera.Usp_Cartera_CUN_Asesor_Unico')""").fetchone()[0]
print('      MARCA_ACADEMICA_DETALLE_GESTION expuesta: %s'
      % ('OK' if 'MARCA_ACADEMICA_DETALLE_GESTION' in viva else '*** FALTA ***'))
print('      Modificado: %s' % cur.execute(
    "SELECT modify_date FROM sys.objects WHERE object_id=OBJECT_ID('Financiera.Usp_Cartera_CUN_Asesor_Unico')"
).fetchone()[0])
print('\n      SP no ejecutado. Se materializa al re-ejecutarlo tras la corrida de SP_Cartera_Total.')
conn.close()
