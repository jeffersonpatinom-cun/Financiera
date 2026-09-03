# -*- coding: utf-8 -*-
"""Analisis temporal de agosto 2026: cuanto tarda un pago en llegar despues de la
gestion, como se reparte el esfuerzo dentro del mes, y que tipificacion convierte.

Alimenta la seccion "Ritmo de la gestion" del informe de cierre.
"""
import io
import json
import sys

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
import pyodbc

CONN = ('DRIVER={ODBC Driver 18 for SQL Server};SERVER=172.16.1.33;'
        'DATABASE=CUN_REPOSITORIO;Trusted_Connection=yes;TrustServerCertificate=yes;')
INI, FIN = '2026-08-01', '2026-09-01'
VALOR = ("TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(REPLACE("
         "G.Valor_pagado,'CO$',''),',',''),' ',''))")
FP = "TRY_CONVERT(date, G.Fecha_de_pago, 103)"
NO_BOT = ("UPPER(e.Hecho_por) NOT LIKE '%CUN DIGITAL%' "
          "AND UPPER(e.Hecho_por) NOT LIKE '%PENAGOS%'")
FECHA_H = ("COALESCE(TRY_CONVERT(datetime, e.Hora_de_modificación, 103),"
           "TRY_CONVERT(datetime, e.Hora_de_creación, 103))")

conn = pyodbc.connect(CONN, timeout=30)
conn.timeout = 900
cur = conn.cursor()
todos = lambda s: cur.execute(s).fetchall()
uno = lambda s: cur.execute(s).fetchone()
cab = lambda t: print('\n' + '=' * 78 + '\n  %s\n' % t + '=' * 78)
R = {}

# ── 1. Latencia: dias entre la ULTIMA gestion y el pago ─────────────────────
# Se mide contra la ultima gestion previa al pago, que es la que razonablemente
# lo detona. GESTION_FECHA_ULTIMA puede ser POSTERIOR al pago (el asesor volvio a
# tipificar despues de cobrar); esos casos se separan en su propia categoria en
# vez de contarlos como latencia negativa.
cab('LATENCIA: del contacto al pago')
lat = todos("""
    SELECT CASE
             WHEN {fp} < CAST(G.GESTION_FECHA_ULTIMA AS date) THEN '0. pago antes de la ultima gestion'
             WHEN DATEDIFF(day, CAST(G.GESTION_FECHA_ULTIMA AS date), {fp}) = 0  THEN '1. mismo dia'
             WHEN DATEDIFF(day, CAST(G.GESTION_FECHA_ULTIMA AS date), {fp}) <= 3 THEN '2. 1 a 3 dias'
             WHEN DATEDIFF(day, CAST(G.GESTION_FECHA_ULTIMA AS date), {fp}) <= 7 THEN '3. 4 a 7 dias'
             WHEN DATEDIFF(day, CAST(G.GESTION_FECHA_ULTIMA AS date), {fp}) <= 15 THEN '4. 8 a 15 dias'
             ELSE '5. mas de 15 dias' END                        AS TRAMO,
           COUNT(*) AS PAGOS,
           CAST(SUM({v})/1e6 AS DECIMAL(18,1))                   AS VALOR_MM
    FROM Financiera.Cartera_CUN_Asesor_Unico G
    WHERE G.GESTION_PAGO_POST_MARCA = 1
      AND {fp} >= '{i}' AND {fp} < '{n}' AND {v} > 0
    GROUP BY CASE
             WHEN {fp} < CAST(G.GESTION_FECHA_ULTIMA AS date) THEN '0. pago antes de la ultima gestion'
             WHEN DATEDIFF(day, CAST(G.GESTION_FECHA_ULTIMA AS date), {fp}) = 0  THEN '1. mismo dia'
             WHEN DATEDIFF(day, CAST(G.GESTION_FECHA_ULTIMA AS date), {fp}) <= 3 THEN '2. 1 a 3 dias'
             WHEN DATEDIFF(day, CAST(G.GESTION_FECHA_ULTIMA AS date), {fp}) <= 7 THEN '3. 4 a 7 dias'
             WHEN DATEDIFF(day, CAST(G.GESTION_FECHA_ULTIMA AS date), {fp}) <= 15 THEN '4. 8 a 15 dias'
             ELSE '5. mas de 15 dias' END
    ORDER BY TRAMO;""".format(fp=FP, v=VALOR, i=INI, n=FIN))
tp = sum(r[1] for r in lat)
tv = sum(float(r[2]) for r in lat)
R['latencia'] = [[r[0][3:], r[1], float(r[2]), round(100.0 * r[1] / tp, 1)] for r in lat]
for r in R['latencia']:
    print('  %-36s %6d pagos  $%8s MM  %5s%%' % (r[0], r[1], r[2], r[3]))
print('  %-36s %6d          $%8.1f MM' % ('TOTAL', tp, tv))

# Mediana de dias (solo los que pagaron despues de la ultima gestion).
med = uno("""
    SELECT DISTINCT PERCENTILE_CONT(0.5) WITHIN GROUP (
               ORDER BY DATEDIFF(day, CAST(G.GESTION_FECHA_ULTIMA AS date), {fp})) OVER ()
    FROM Financiera.Cartera_CUN_Asesor_Unico G
    WHERE G.GESTION_PAGO_POST_MARCA = 1
      AND {fp} >= '{i}' AND {fp} < '{n}' AND {v} > 0
      AND {fp} >= CAST(G.GESTION_FECHA_ULTIMA AS date);""".format(
    fp=FP, v=VALOR, i=INI, n=FIN))[0]
R['latencia_mediana'] = float(med)
print('  Mediana de dias del contacto al pago : %s' % med)

# ── 2. Ritmo dentro del mes: gestiones y pagos por semana ───────────────────
cab('RITMO DENTRO DEL MES')
ges_sem = todos("""
    SELECT DATEPART(week, {fh}) - DATEPART(week, '{i}') + 1 AS SEMANA, COUNT(*)
    FROM [ZOHO].[CRM].[Historico_tipificacion_contact] e
    JOIN ZOHO.CRM.Cartera_CUN c ON CONVERT(varchar(30), c.Id) = CONVERT(varchar(30), e.Cartera_CUN)
    WHERE e.Hecho_por IS NOT NULL AND {nb}
      AND c.[Número_de_identificación] IS NOT NULL AND c.[Número_de_identificación] <> ''
      AND {fh} >= '{i}' AND {fh} < '{n}'
    GROUP BY DATEPART(week, {fh}) - DATEPART(week, '{i}') + 1
    ORDER BY SEMANA;""".format(fh=FECHA_H, nb=NO_BOT, i=INI, n=FIN))
pag_sem = todos("""
    SELECT DATEPART(week, {fp}) - DATEPART(week, '{i}') + 1 AS SEMANA, COUNT(*),
           CAST(SUM({v})/1e6 AS DECIMAL(18,1))
    FROM Financiera.Cartera_CUN_Asesor_Unico G
    WHERE G.GESTION_PAGO_POST_MARCA = 1
      AND {fp} >= '{i}' AND {fp} < '{n}' AND {v} > 0
    GROUP BY DATEPART(week, {fp}) - DATEPART(week, '{i}') + 1
    ORDER BY SEMANA;""".format(fp=FP, v=VALOR, i=INI, n=FIN))
gd = dict(ges_sem)
pd_ = {r[0]: (r[1], float(r[2])) for r in pag_sem}
R['semanas'] = []
print('  %-10s %10s %10s %12s' % ('SEMANA', 'GESTIONES', 'PAGOS', '$MM'))
for s in sorted(set(gd) | set(pd_)):
    g = gd.get(s, 0)
    p, v = pd_.get(s, (0, 0.0))
    R['semanas'].append([s, g, p, v])
    print('  %-10s %10d %10d %12.1f' % ('Semana %d' % s, g, p, v))

# ── 3. Que tipificacion convierte, y en cuanto tiempo ───────────────────────
# Se toma la ULTIMA tipificacion de agosto de cada persona como la que define su
# estado al cierre, y se mira si pago.
cab('CONVERSION POR TIPIFICACION')
conv = todos("""
    WITH ULT AS (
        SELECT LTRIM(RTRIM(CONVERT(varchar(20), c.[Número_de_identificación]))) AS ident,
               NULLIF(LTRIM(RTRIM(CONVERT(varchar(200), e.Tipificación_nueva))),'') AS tipif,
               ROW_NUMBER() OVER (
                   PARTITION BY LTRIM(RTRIM(CONVERT(varchar(20), c.[Número_de_identificación])))
                   ORDER BY {fh} DESC, CONVERT(varchar(30), e.Id) DESC) AS rn
        FROM [ZOHO].[CRM].[Historico_tipificacion_contact] e
        JOIN ZOHO.CRM.Cartera_CUN c ON CONVERT(varchar(30), c.Id) = CONVERT(varchar(30), e.Cartera_CUN)
        WHERE e.Hecho_por IS NOT NULL AND {nb}
          AND c.[Número_de_identificación] IS NOT NULL AND c.[Número_de_identificación] <> ''
          AND {fh} >= '{i}' AND {fh} < '{n}'
    ), PAGO AS (
        SELECT DISTINCT LTRIM(RTRIM(G.Número_de_identificación)) AS ident
        FROM Financiera.Cartera_CUN_Asesor_Unico G
        WHERE G.GESTION_PAGO_POST_MARCA = 1
          AND {fp} >= '{i}' AND {fp} < '{n}' AND {v} > 0
    )
    SELECT u.tipif, COUNT(*) AS PERSONAS,
           SUM(CASE WHEN p.ident IS NOT NULL THEN 1 ELSE 0 END) AS PAGARON,
           CAST(100.0 * SUM(CASE WHEN p.ident IS NOT NULL THEN 1 ELSE 0 END)
                / COUNT(*) AS DECIMAL(5,1)) AS PCT
    FROM ULT u LEFT JOIN PAGO p ON p.ident = u.ident
    WHERE u.rn = 1 AND u.tipif IS NOT NULL
    GROUP BY u.tipif HAVING COUNT(*) >= 50
    ORDER BY PCT DESC;""".format(fh=FECHA_H, nb=NO_BOT, fp=FP, v=VALOR, i=INI, n=FIN))
R['conversion'] = [[r[0], r[1], r[2], float(r[3])] for r in conv]
print('  %-42s %8s %8s %7s' % ('TIPIFICACION (ultima del mes)', 'PERSONAS', 'PAGARON', '%'))
for r in R['conversion']:
    print('  %-42s %8d %8d %6s%%' % (r[0][:42], r[1], r[2], r[3]))

json.dump(R, open('tiempos_gestion_agosto.json', 'w', encoding='utf-8'),
          ensure_ascii=False, indent=2)
print('\n-> tiempos_gestion_agosto.json')
conn.close()
