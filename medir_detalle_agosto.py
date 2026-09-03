# -*- coding: utf-8 -*-
"""Descompone las diferencias de la fe de erratas y arma las tablas corregidas
del informe de agosto 2026 (tipificaciones, recaudo por periodo, ticket,
ranking por asesor para la liquidacion).
"""
import io
import json
import sys

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
import pyodbc

CONN_STR = ('DRIVER={ODBC Driver 18 for SQL Server};SERVER=172.16.1.33;'
            'DATABASE=CUN_REPOSITORIO;Trusted_Connection=yes;TrustServerCertificate=yes;')
INI, FIN = '2026-08-01', '2026-09-01'
VALOR = ("TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(REPLACE("
         "G.Valor_pagado,'CO$',''),',',''),' ',''))")
FP = "TRY_CONVERT(date, G.Fecha_de_pago, 103)"
VIEJO = ("G.Asesor_Unico NOT IN ('Reasignar en CRM','Sin asignar') "
         "AND NULLIF(LTRIM(RTRIM(G.Asesor_Unico)),'') IS NOT NULL")
NO_BOT = ("UPPER(e.Hecho_por) NOT LIKE '%CUN DIGITAL%' "
          "AND UPPER(e.Hecho_por) NOT LIKE '%PENAGOS%'")
FECHA_H = ("COALESCE(TRY_CONVERT(datetime, e.Hora_de_modificación, 103),"
           "TRY_CONVERT(datetime, e.Hora_de_creación, 103))")
HIST = """
    FROM [ZOHO].[CRM].[Historico_tipificacion_contact] e
    JOIN ZOHO.CRM.Cartera_CUN c ON CONVERT(varchar(30), c.Id) = CONVERT(varchar(30), e.Cartera_CUN)
    WHERE e.Hecho_por IS NOT NULL AND {nb}
      AND c.[Número_de_identificación] IS NOT NULL AND c.[Número_de_identificación] <> ''
      AND {fh} >= '{i}' AND {fh} < '{n}'""".format(nb=NO_BOT, fh=FECHA_H, i=INI, n=FIN)

conn = pyodbc.connect(CONN_STR, timeout=30)
conn.timeout = 900
cur = conn.cursor()
R = json.load(open('impacto_fe_erratas_agosto.json', encoding='utf-8'))
uno = lambda s: cur.execute(s).fetchone()
todos = lambda s: cur.execute(s).fetchall()
cab = lambda t: print('\n' + '=' * 78 + '\n  %s\n' % t + '=' * 78)
mm = lambda x: round(float(x or 0) / 1e6, 1)

# ── 1. De donde sale la caida de "gestiones" ────────────────────────────────
cab('DESCOMPOSICION: 61.767 gestiones publicadas')
# Mismo criterio viejo (una fila por credito, ultima tipificacion en agosto)
# pero separando si quien tipifico fue humano o bot.
hum, bot = uno("""
    SELECT SUM(CASE WHEN UPPER(G.Hecho_por) NOT LIKE '%%CUN DIGITAL%%'
                     AND UPPER(G.Hecho_por) NOT LIKE '%%PENAGOS%%' THEN 1 ELSE 0 END),
           SUM(CASE WHEN UPPER(G.Hecho_por) LIKE '%%CUN DIGITAL%%'
                      OR UPPER(G.Hecho_por) LIKE '%%PENAGOS%%' THEN 1 ELSE 0 END)
    FROM Financiera.Cartera_CUN_Asesor_Unico G
    WHERE %s AND TRY_CONVERT(datetime, G.Hora_modificacion_tipif, 103) >= '%s'
      AND TRY_CONVERT(datetime, G.Hora_modificacion_tipif, 103) < '%s';"""
               % (VIEJO, INI, FIN))
print('  Filas-credito con ultima tipificacion en agosto : %d' % (hum + bot))
print('    de un asesor humano : %d' % hum)
print('    de un bot           : %d  <- se atribuian al asesor por la escalera' % bot)
print('  Tipificaciones humanas reales del historico     : %d' % R['Gestiones de agosto']['nuevo'])
R['desc_gestiones'] = {'filas_humano': hum, 'filas_bot': bot}

# ── 2. De donde sale la caida del recaudo ───────────────────────────────────
cab('DESCOMPOSICION: $5.483,9 MM de recaudo publicado')
tot, sin_g, pre_g, ok = uno("""
    SELECT SUM({v}),
           SUM(CASE WHEN G.GESTION_MARCA = 0 THEN {v} ELSE 0 END),
           SUM(CASE WHEN G.GESTION_MARCA = 1 AND G.GESTION_PAGO_POST_MARCA = 0
                    THEN {v} ELSE 0 END),
           SUM(CASE WHEN G.GESTION_PAGO_POST_MARCA = 1 THEN {v} ELSE 0 END)
    FROM Financiera.Cartera_CUN_Asesor_Unico G
    WHERE {f} AND {fp} >= '{i}' AND {fp} < '{n}' AND {v} > 0;""".format(
    v=VALOR, f=VIEJO, fp=FP, i=INI, n=FIN))
print('  Publicado                                  : $%s MM' % mm(tot))
print('    (-) de personas que NADIE gestiono       : $%s MM' % mm(sin_g))
print('    (-) pago ANTERIOR a la primera gestion   : $%s MM' % mm(pre_g))
print('    (=) atribuible a la gestion del equipo   : $%s MM' % mm(ok))
R['desc_recaudo'] = {'publicado': mm(tot), 'sin_gestion': mm(sin_g),
                     'pago_previo': mm(pre_g), 'atribuible': mm(ok)}

# ── 3. Tipificaciones aplicadas en agosto (corregido) ───────────────────────
cab('TIPIFICACIONES DE AGOSTO (solo humanas)')
tip = todos("""
    SELECT LTRIM(RTRIM(CONVERT(varchar(200), e.Tipificación_nueva))) AS tipif,
           COUNT(*) AS gestiones,
           COUNT(DISTINCT LTRIM(RTRIM(CONVERT(varchar(20), c.[Número_de_identificación])))) AS personas
    %s AND NULLIF(LTRIM(RTRIM(CONVERT(varchar(200), e.Tipificación_nueva))),'') IS NOT NULL
    GROUP BY LTRIM(RTRIM(CONVERT(varchar(200), e.Tipificación_nueva)))
    ORDER BY gestiones DESC;""" % HIST)
tt = sum(r[1] for r in tip)
R['tipificaciones'] = [[r[0], r[1], r[2], round(100.0 * r[1] / tt, 1)] for r in tip]
for r in R['tipificaciones'][:10]:
    print('  %-46s %6d  %6d  %5s%%' % (r[0][:46], r[1], r[2], r[3]))

# ── 4. Recaudo por periodo (corregido) ──────────────────────────────────────
cab('RECAUDO POR PERIODO (atribuible a gestion)')
per = todos("""
    SELECT LTRIM(RTRIM(G.Periodo)) AS periodo, COUNT(*) AS pagos,
           COUNT(DISTINCT LTRIM(RTRIM(G.Número_de_identificación))) AS est, SUM({v}) AS valor
    FROM Financiera.Cartera_CUN_Asesor_Unico G
    WHERE G.GESTION_PAGO_POST_MARCA = 1 AND {fp} >= '{i}' AND {fp} < '{n}' AND {v} > 0
    GROUP BY LTRIM(RTRIM(G.Periodo)) ORDER BY valor DESC;""".format(
    v=VALOR, fp=FP, i=INI, n=FIN))
tv = sum(float(r[3]) for r in per)
R['recaudo_periodo'] = [[r[0], r[1], r[2], mm(r[3]), round(100.0 * float(r[3]) / tv, 1)]
                        for r in per[:6]]
R['recaudo_periodo_resto'] = [sum(r[1] for r in per[6:]), mm(sum(float(r[3]) for r in per[6:])),
                              round(100.0 * sum(float(r[3]) for r in per[6:]) / tv, 1)]
for r in R['recaudo_periodo']:
    print('  %-8s %6d pagos  %6d est  $%8s MM  %5s%%' % tuple(r))
print('  %-8s %6d pagos  %6s      $%8s MM  %5s%%'
      % ('Resto', R['recaudo_periodo_resto'][0], '-', *R['recaudo_periodo_resto'][1:]))

# ── 5. Distribucion del ticket (corregido) ──────────────────────────────────
cab('DISTRIBUCION DEL TICKET (atribuible a gestion)')
tk = uno("""
    SELECT SUM(CASE WHEN {v} < 100000 THEN 1 ELSE 0 END),
           SUM(CASE WHEN {v} >= 100000 AND {v} < 300000 THEN 1 ELSE 0 END),
           SUM(CASE WHEN {v} >= 300000 AND {v} < 600000 THEN 1 ELSE 0 END),
           SUM(CASE WHEN {v} >= 600000 AND {v} < 1000000 THEN 1 ELSE 0 END),
           SUM(CASE WHEN {v} >= 1000000 THEN 1 ELSE 0 END),
           SUM(CASE WHEN {v} < 100000 THEN {v} ELSE 0 END),
           SUM(CASE WHEN {v} >= 100000 AND {v} < 300000 THEN {v} ELSE 0 END),
           SUM(CASE WHEN {v} >= 300000 AND {v} < 600000 THEN {v} ELSE 0 END),
           SUM(CASE WHEN {v} >= 600000 AND {v} < 1000000 THEN {v} ELSE 0 END),
           SUM(CASE WHEN {v} >= 1000000 THEN {v} ELSE 0 END)
    FROM Financiera.Cartera_CUN_Asesor_Unico G
    WHERE G.GESTION_PAGO_POST_MARCA = 1 AND {fp} >= '{i}' AND {fp} < '{n}' AND {v} > 0;""".format(
    v=VALOR, fp=FP, i=INI, n=FIN))
R['ticket'] = {'pagos': list(tk[:5]), 'valor_mm': [mm(x) for x in tk[5:]]}
print('  Pagos : %s' % R['ticket']['pagos'])
print('  Valor : %s' % R['ticket']['valor_mm'])

# ── 6. Ranking por asesor: la base de la liquidacion ────────────────────────
cab('RANKING POR ASESOR (liquidacion)')
rk = todos("""
    WITH GES AS (
        SELECT UPPER(LTRIM(RTRIM(CONVERT(varchar(200), e.Hecho_por)))) AS asesor,
               COUNT(*) AS gestiones,
               COUNT(DISTINCT LTRIM(RTRIM(CONVERT(varchar(20), c.[Número_de_identificación])))) AS personas
        %s GROUP BY UPPER(LTRIM(RTRIM(CONVERT(varchar(200), e.Hecho_por))))
    ), PAG AS (
        SELECT G.GESTION_ASESOR AS asesor, COUNT(*) AS pagos,
               COUNT(DISTINCT LTRIM(RTRIM(G.Número_de_identificación))) AS est_pago,
               SUM(%s) AS valor
        FROM Financiera.Cartera_CUN_Asesor_Unico G
        WHERE G.GESTION_PAGO_POST_MARCA = 1 AND %s >= '%s' AND %s < '%s' AND %s > 0
        GROUP BY G.GESTION_ASESOR
    )
    SELECT g.asesor, g.gestiones, g.personas,
           ISNULL(p.pagos,0), ISNULL(p.est_pago,0), ISNULL(p.valor,0)
    FROM GES g LEFT JOIN PAG p ON p.asesor = g.asesor
    ORDER BY ISNULL(p.valor,0) DESC;""" % (HIST, VALOR, FP, INI, FP, FIN, VALOR))
R['ranking'] = [[r[0], r[1], r[2], r[3], r[4], mm(r[5])] for r in rk]
print('  %-28s %8s %8s %7s %10s' % ('ASESOR', 'GEST', 'PERS', 'PAGOS', '$MM'))
for r in R['ranking']:
    print('  %-28s %8d %8d %7d %10s' % (r[0][:28], r[1], r[2], r[3], r[5]))
print('  %-28s %8d %8s %7d %10s'
      % ('TOTAL', sum(r[1] for r in R['ranking']), '-',
         sum(r[3] for r in R['ranking']), round(sum(r[5] for r in R['ranking']), 1)))

json.dump(R, open('impacto_fe_erratas_agosto.json', 'w', encoding='utf-8'),
          ensure_ascii=False, indent=2)
print('\n-> impacto_fe_erratas_agosto.json actualizado')
conn.close()
