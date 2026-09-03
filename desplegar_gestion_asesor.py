# -*- coding: utf-8 -*-
"""Agrega las columnas GESTION_* a Financiera.Usp_Cartera_CUN_Asesor_Unico.

Asesor_Unico nunca queda vacio (baja una escalera de 5 prioridades), asi que
filtrarlo con NOT LIKE '%asignar%' para "contar gestiones" deja pasar a todo el
que solo toco el registro en el CRM o es el dueno asignado de la cartera. Las
columnas GESTION_* salen unicamente del historico de tipificacion.

Uso:
    python desplegar_gestion_asesor.py --check     # solo mide, no despliega
    python desplegar_gestion_asesor.py             # mide, despliega y verifica
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
SRC = 'alter_usp_cartera_cun_asesor_unico_gestion_asesor.sql'
SOLO_CHECK = '--check' in sys.argv

# Predicado de bot, identico al de la prioridad 0 de la escalera del SP.
NO_BOT = ("UPPER(e.Hecho_por) NOT LIKE '%CUN DIGITAL%' "
          "AND UPPER(e.Hecho_por) NOT LIKE '%PENAGOS%'")

# Universo que produce el filtro viejo sobre Asesor_Unico.
FILTRO_VIEJO = ("Asesor_Unico NOT IN ('Reasignar en CRM','Sin asignar') "
                "AND NULLIF(LTRIM(RTRIM(Asesor_Unico)),'') IS NOT NULL")

conn = pyodbc.connect(CONN_STR, timeout=30)
conn.autocommit = True
conn.timeout = 900
cur = conn.cursor()


def uno(sql):
    return cur.execute(sql).fetchone()


def pct(parte, total):
    return '%.1f%%' % (100.0 * parte / total) if total else 'n/a'


# ── PRE 1: cuanto infla el filtro viejo ──────────────────────────────────────
print('[PRE 1] Sobreestimacion del filtro viejo (Asesor_Unico vs gestion real)')
viejo_filas, viejo_ced = uno("""
    SELECT COUNT(*), COUNT(DISTINCT LTRIM(RTRIM(Número_de_identificación)))
    FROM Financiera.Cartera_CUN_Asesor_Unico
    WHERE %s;""" % FILTRO_VIEJO)

real_ced = uno("""
    SELECT COUNT(DISTINCT LTRIM(RTRIM(CONVERT(varchar(20), c.[Número_de_identificación]))))
    FROM [ZOHO].[CRM].[Historico_tipificacion_contact] e
    JOIN ZOHO.CRM.Cartera_CUN c
          ON CONVERT(varchar(30), c.Id) = CONVERT(varchar(30), e.Cartera_CUN)
    WHERE e.Cartera_CUN IS NOT NULL
      AND c.[Número_de_identificación] IS NOT NULL
      AND c.[Número_de_identificación] <> ''
      AND e.Hecho_por IS NOT NULL
      AND LTRIM(RTRIM(CONVERT(varchar(200), e.Hecho_por))) <> ''
      AND %s;""" % NO_BOT)[0]

print('        Filtro viejo : %8d filas / %7d cedulas' % (viejo_filas, viejo_ced))
print('        Gestion real : %8s        %7d cedulas' % ('-', real_ced))
print('        SOBREESTIMA  : %8s        %7d cedulas (%s de mas)'
      % ('-', viejo_ced - real_ced, pct(viejo_ced - real_ced, real_ced)))

# ── PRE 2: cuanto se descarta por bots ───────────────────────────────────────
print('\n[PRE 2] Filas del historico descartadas por bot (CUN DIGITAL / PENAGOS)')
tot, bots = uno("""
    SELECT COUNT(*),
           SUM(CASE WHEN UPPER(e.Hecho_por) LIKE '%CUN DIGITAL%'
                      OR UPPER(e.Hecho_por) LIKE '%PENAGOS%' THEN 1 ELSE 0 END)
    FROM [ZOHO].[CRM].[Historico_tipificacion_contact] e
    WHERE e.Cartera_CUN IS NOT NULL AND e.Hecho_por IS NOT NULL;""")
print('        Historico con Hecho_por : %7d' % tot)
print('        De bots                 : %7d (%s)' % (bots, pct(bots, tot)))

ced_con_bot = uno("""
    SELECT COUNT(*) FROM (
        SELECT LTRIM(RTRIM(CONVERT(varchar(20), c.[Número_de_identificación]))) AS ident
        FROM [ZOHO].[CRM].[Historico_tipificacion_contact] e
        JOIN ZOHO.CRM.Cartera_CUN c
              ON CONVERT(varchar(30), c.Id) = CONVERT(varchar(30), e.Cartera_CUN)
        WHERE e.Cartera_CUN IS NOT NULL AND e.Hecho_por IS NOT NULL
          AND c.[Número_de_identificación] IS NOT NULL
          AND c.[Número_de_identificación] <> ''
        GROUP BY LTRIM(RTRIM(CONVERT(varchar(20), c.[Número_de_identificación])))
        HAVING SUM(CASE WHEN %s THEN 1 ELSE 0 END) = 0
    ) x;""" % NO_BOT)[0]
print('        Cedulas que pierden la gestion por ser SOLO bot : %d' % ced_con_bot)

# ── PRE 3: huerfanas que el JOIN por Id descarta ─────────────────────────────
print('\n[PRE 3] Filas del historico que no cruzan contra Cartera_CUN.Id')
nulas, sin_match = uno("""
    SELECT SUM(CASE WHEN e.Cartera_CUN IS NULL THEN 1 ELSE 0 END),
           SUM(CASE WHEN e.Cartera_CUN IS NOT NULL AND c.Id IS NULL
                    THEN 1 ELSE 0 END)
    FROM [ZOHO].[CRM].[Historico_tipificacion_contact] e
    LEFT JOIN ZOHO.CRM.Cartera_CUN c
           ON CONVERT(varchar(30), c.Id) = CONVERT(varchar(30), e.Cartera_CUN);""")
print('        Cartera_CUN NULL          : %d  (esperado ~1.878, ya documentado)' % nulas)
print('        Cartera_CUN sin match Id  : %d' % sin_match)
if sin_match > nulas:
    print('        *** OJO: mas huerfanas sin match que NULL. Revisar el cruce por Id.')

# ── PRE 4: duplicados que reventarian el indice unico ────────────────────────
print('\n[PRE 4] Unicidad por cedula de la temporal (simula el CREATE UNIQUE)')
dup = uno("""
    SELECT COUNT(*) FROM (
        SELECT LTRIM(RTRIM(CONVERT(varchar(20), c.[Número_de_identificación]))) AS ident
        FROM [ZOHO].[CRM].[Historico_tipificacion_contact] e
        JOIN ZOHO.CRM.Cartera_CUN c
              ON CONVERT(varchar(30), c.Id) = CONVERT(varchar(30), e.Cartera_CUN)
        WHERE e.Cartera_CUN IS NOT NULL AND %s
          AND c.[Número_de_identificación] IS NOT NULL
          AND c.[Número_de_identificación] <> ''
          AND e.Hecho_por IS NOT NULL
        GROUP BY LTRIM(RTRIM(CONVERT(varchar(20), c.[Número_de_identificación])))
        HAVING COUNT(*) > 1
    ) x;""" % NO_BOT)[0]
print('        Cedulas con >1 tipificacion (se colapsan a 1) : %d  -> OK, es lo esperado' % dup)

filas_antes = uno('SELECT COUNT(*) FROM Financiera.Cartera_CUN_Asesor_Unico;')[0]
print('\n        Filas actuales de Cartera_CUN_Asesor_Unico : %d' % filas_antes)

if SOLO_CHECK:
    print('\n--check: no se despliega nada.')
    conn.close()
    sys.exit(0)

# ── DESPLIEGUE ───────────────────────────────────────────────────────────────
d = open(SRC, encoding='utf-8').read()
# El encabezado viene como "CREATE PROCEDURE" (o "CREATE   PROCEDURE" si lo dejo
# un CREATE OR ALTER previo), por eso el reemplazo tolera espacios multiples.
ddl, n = re.subn(r'\bCREATE\s+PROCEDURE\b', 'ALTER PROCEDURE', d, count=1)
if n != 1:
    sys.exit('ERROR: no se encontro el encabezado del procedimiento en %s.' % SRC)

print('\n[1/3] Aplicando ALTER PROCEDURE Financiera.Usp_Cartera_CUN_Asesor_Unico...')
cur.execute(ddl)
print('      OK - SP compilado.')

print('[2/3] Ejecutando el SP (reconstruye la tabla con DROP + SELECT INTO)...')
cur.execute('EXEC Financiera.Usp_Cartera_CUN_Asesor_Unico;')
while cur.nextset():
    pass
print('      OK - SP ejecutado.')

# ── POST ─────────────────────────────────────────────────────────────────────
print('\n[3/3] Verificacion:')
filas_despues = uno('SELECT COUNT(*) FROM Financiera.Cartera_CUN_Asesor_Unico;')[0]
print('      Filas antes / despues : %d / %d  -> %s'
      % (filas_antes, filas_despues,
         'OK, sin fan-out' if filas_despues == filas_antes else '*** CAMBIO DE CONTEO ***'))

falta = [c for c in ('GESTION_ASESOR', 'GESTION_MARCA', 'GESTION_FECHA_PRIMERA',
                     'GESTION_FECHA_ULTIMA', 'GESTION_PAGO_POST_MARCA')
         if not uno("SELECT COL_LENGTH('Financiera.Cartera_CUN_Asesor_Unico','%s')" % c)[0]]
print('      Columnas GESTION_* creadas : %s' % ('OK' if not falta else '*** FALTAN: %s' % falta))

marca, asesor, fprim = uno("""
    SELECT SUM(CONVERT(int, GESTION_MARCA)),
           SUM(CASE WHEN GESTION_ASESOR        IS NOT NULL THEN 1 ELSE 0 END),
           SUM(CASE WHEN GESTION_FECHA_PRIMERA IS NOT NULL THEN 1 ELSE 0 END)
    FROM Financiera.Cartera_CUN_Asesor_Unico;""")
print('      Coherencia MARCA=1 / ASESOR / FECHA_PRIMERA : %d / %d / %d  -> %s'
      % (marca, asesor, fprim,
         'OK' if marca == asesor == fprim else '*** INCOHERENTE ***'))

orden_mal = uno("""
    SELECT COUNT(*) FROM Financiera.Cartera_CUN_Asesor_Unico
    WHERE GESTION_FECHA_PRIMERA > GESTION_FECHA_ULTIMA;""")[0]
print('      Filas con PRIMERA > ULTIMA : %d  -> %s'
      % (orden_mal, 'OK' if orden_mal == 0 else '*** REVISAR ***'))

sucio = uno("""
    SELECT COUNT(*) FROM Financiera.Cartera_CUN_Asesor_Unico
    WHERE GESTION_ASESOR IN ('Sin asignar','Reasignar en CRM','CUN DIGITAL','')
       OR GESTION_ASESOR LIKE '%CUN DIGITAL%'
       OR GESTION_ASESOR LIKE '%PENAGOS%';""")[0]
print('      Centinelas/bots dentro de GESTION_ASESOR : %d  -> %s'
      % (sucio, 'OK' if sucio == 0 else '*** CONTAMINADO ***'))

# Si el LTRIM del join desalineo la cedula, esto cae en picada.
coincide, total_m = uno("""
    SELECT SUM(CASE WHEN UPPER(LTRIM(RTRIM(Asesor_Unico))) = GESTION_ASESOR
                    THEN 1 ELSE 0 END), COUNT(*)
    FROM Financiera.Cartera_CUN_Asesor_Unico WHERE GESTION_MARCA = 1;""")
print('      GESTION_ASESOR = Asesor_Unico (con gestion) : %s  -> %s'
      % (pct(coincide, total_m),
         'OK' if total_m and coincide * 1.0 / total_m > 0.8 else '*** revisar el cruce por cedula'))

print('\n      Comparativa final del universo de medicion:')
print('        Filas filtro viejo   : %d' % viejo_filas)
print('        Filas GESTION_MARCA=1: %d' % marca)
conn.close()
