# -*- coding: utf-8 -*-
"""Despliega la nueva logica de MARCA_ACADEMICA en Financiera.SP_Cartera_Total.

NO ejecuta el SP: solo aplica DDL. La ejecucion queda para el job de las 6:00 am
o para una corrida manual en ventana de baja contencion.

Orden obligatorio:
  1. ALTER TABLE ... ADD MARCA_ACADEMICA_DETALLE  (bootstrap)
     Sin esto el ALTER PROCEDURE falla con error 207: el CTE Cartera_Total_Dedup
     lee de la tabla FISICA Financiera.Cartera_Total, que aun no tiene la columna
     (resolucion diferida de nombres).
  2. ALTER PROCEDURE
"""
import io
import sys

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
import pyodbc

CONN_STR = (
    'DRIVER={ODBC Driver 18 for SQL Server};'
    'SERVER=172.16.1.33;DATABASE=CUN_REPOSITORIO;'
    'Trusted_Connection=yes;TrustServerCertificate=yes;Connect Timeout=30;'
)
SQL_FILE = 'alter_sp_cartera_total_marca_v2.sql'

ddl = open(SQL_FILE, encoding='utf-8').read()
if 'CREATE PROCEDURE' not in ddl:
    sys.exit('ERROR: no se encontro CREATE PROCEDURE en %s' % SQL_FILE)
ddl = ddl.replace('CREATE PROCEDURE', 'ALTER PROCEDURE', 1)

conn = pyodbc.connect(CONN_STR, timeout=30)
conn.autocommit = True
conn.timeout = 600          # el timeout de query va en conn, NO en cursor
cur = conn.cursor()

# ---------------------------------------------------------------- 1) Bootstrap
print('[1/3] Bootstrap de columnas (evita el error 207 por resolucion diferida)...')
cur.execute("""
    IF COL_LENGTH('Financiera.Cartera_Total','MARCA_ACADEMICA_DETALLE') IS NULL
        ALTER TABLE Financiera.Cartera_Total ADD MARCA_ACADEMICA_DETALLE varchar(50) NULL;
""")
tiene = cur.execute(
    "SELECT COL_LENGTH('Financiera.Cartera_Total','MARCA_ACADEMICA_DETALLE')").fetchone()[0]
print('      Cartera_Total.MARCA_ACADEMICA_DETALLE -> %s' % ('OK' if tiene else 'NO CREADA'))
if not tiene:
    sys.exit('ERROR: la columna no quedo creada; se aborta antes del ALTER PROCEDURE.')

# ---------------------------------------------------------------- 2) ALTER PROCEDURE
print('[2/3] Aplicando ALTER PROCEDURE Financiera.SP_Cartera_Total...')
cur.execute(ddl)
print('      OK - SP compilado (referencias de objetos validas).')

# ---------------------------------------------------------------- 3) Verificacion
print('[3/3] Verificando la definicion desplegada:')
d = cur.execute("""SELECT definition FROM sys.sql_modules
                   WHERE object_id = OBJECT_ID('Financiera.SP_Cartera_Total')""").fetchone()[0]
checks = [
    ("Rama de segmento empresarial", "THEN 'CARTERA EMPRESARIAL'"),
    ("Riesgo adverso (Alto + Regular)", "IN ('Riesgo Alto', 'Riesgo Regular')"),
    ("Corte de aprobacion en 3.0", "< 3.0"),
    ("Columna MARCA_ACADEMICA_DETALLE", "MARCA_ACADEMICA_DETALLE"),
]
for etiqueta, aguja in checks:
    print('      %-38s %s' % (etiqueta, 'OK' if aguja in d else '*** FALTA ***'))
for etiqueta, aguja in [("Corte viejo 2.95 removido", "<= 2.95"),
                        ("Filtro viejo de riesgo removido", "F.RES_PERFIL_RIESGO = 'Riesgo Alto'")]:
    print('      %-38s %s' % (etiqueta, 'OK' if aguja not in d else '*** SIGUE PRESENTE ***'))

print('\n      Modificado: %s' % cur.execute(
    "SELECT modify_date FROM sys.objects WHERE object_id=OBJECT_ID('Financiera.SP_Cartera_Total')"
).fetchone()[0])
print('\n      El SP NO fue ejecutado. La nueva marca se materializa en la proxima corrida.')
conn.close()
