# -*- coding: utf-8 -*-
"""Recalcula las cifras publicadas del Informe de Cierre de Agosto 2026.

Compara el criterio VIEJO (universo por Asesor_Unico, que nunca queda vacio)
contra el CORRECTO (gestion real desde el historico de tipificacion) para cada
cifra que salio en el informe, y deja el resultado en JSON para alimentar la fe
de erratas, la base xlsx y el informe corregido.

Ventana: agosto 2026 (2026-08-01 .. 2026-09-01).
"""
import io
import json
import sys

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
import pyodbc

CONN_STR = (
    'DRIVER={ODBC Driver 18 for SQL Server};'
    'SERVER=172.16.1.33;DATABASE=CUN_REPOSITORIO;'
    'Trusted_Connection=yes;TrustServerCertificate=yes;Connect Timeout=30;'
)
INI, FIN = '2026-08-01', '2026-09-01'
SALIDA = 'impacto_fe_erratas_agosto.json'

# Valor_pagado viene como texto 'CO$ 1,234,567'. Mismo saneo que uso el informe.
VALOR = ("TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(REPLACE("
         "G.Valor_pagado,'CO$',''),',',''),' ',''))")
FECHA_PAGO = "TRY_CONVERT(date, G.Fecha_de_pago, 103)"
FILTRO_VIEJO = ("G.Asesor_Unico NOT IN ('Reasignar en CRM','Sin asignar') "
                "AND NULLIF(LTRIM(RTRIM(G.Asesor_Unico)),'') IS NOT NULL")

conn = pyodbc.connect(CONN_STR, timeout=30)
conn.timeout = 900
cur = conn.cursor()
R = {}


def uno(sql, **kw):
    return cur.execute(sql.format(**kw)).fetchone()


def todos(sql, **kw):
    return cur.execute(sql.format(**kw)).fetchall()


def cab(t):
    print('\n' + '=' * 78 + '\n  %s\n' % t + '=' * 78)


def cmp_(nombre, publicado, viejo, nuevo, fmt='%s'):
    """Imprime y registra una cifra publicada contra su version corregida."""
    R[nombre] = {'publicado': publicado, 'viejo': viejo, 'nuevo': nuevo}
    d = ''
    if isinstance(viejo, (int, float)) and isinstance(nuevo, (int, float)) and nuevo:
        d = '  (%+.1f%%)' % (100.0 * (viejo - nuevo) / nuevo)
    print('  %-34s publicado %-12s -> corregido %-12s%s'
          % (nombre, fmt % publicado, fmt % nuevo, d))


# ═══════════════════════════════════════════════════ BLOQUE GESTION
cab('BLOQUE 3 — GESTION DEL EQUIPO')

# VIEJO: filas de la tabla cuya ULTIMA tipificacion cayo en agosto, con el
# asesor tomado de Asesor_Unico (que puede no ser quien tipifico).
v_ges, v_per, v_ase = uno("""
    SELECT COUNT(*), COUNT(DISTINCT LTRIM(RTRIM(G.Número_de_identificación))),
           COUNT(DISTINCT LTRIM(RTRIM(G.Asesor_Unico)))
    FROM Financiera.Cartera_CUN_Asesor_Unico G
    WHERE {f}
      AND TRY_CONVERT(datetime, G.Hora_modificacion_tipif, 103) >= '{i}'
      AND TRY_CONVERT(datetime, G.Hora_modificacion_tipif, 103) <  '{n}';""",
                          f=FILTRO_VIEJO, i=INI, n=FIN)

# NUEVO: tipificaciones humanas reales del historico dentro de agosto.
n_ges, n_per, n_ase = uno("""
    SELECT COUNT(*),
           COUNT(DISTINCT LTRIM(RTRIM(CONVERT(varchar(20), c.[Número_de_identificación])))),
           COUNT(DISTINCT UPPER(LTRIM(RTRIM(CONVERT(varchar(200), e.Hecho_por)))))
    FROM [ZOHO].[CRM].[Historico_tipificacion_contact] e
    JOIN ZOHO.CRM.Cartera_CUN c
          ON CONVERT(varchar(30), c.Id) = CONVERT(varchar(30), e.Cartera_CUN)
    WHERE e.Cartera_CUN IS NOT NULL
      AND c.[Número_de_identificación] IS NOT NULL AND c.[Número_de_identificación] <> ''
      AND e.Hecho_por IS NOT NULL
      AND UPPER(e.Hecho_por) NOT LIKE '%CUN DIGITAL%'
      AND UPPER(e.Hecho_por) NOT LIKE '%PENAGOS%'
      AND COALESCE(TRY_CONVERT(datetime, e.Hora_de_modificación, 103),
                   TRY_CONVERT(datetime, e.Hora_de_creación, 103)) >= '{i}'
      AND COALESCE(TRY_CONVERT(datetime, e.Hora_de_modificación, 103),
                   TRY_CONVERT(datetime, e.Hora_de_creación, 103)) <  '{n}';""",
                          i=INI, n=FIN)

cmp_('Gestiones de agosto', 61767, v_ges, n_ges, '%d')
cmp_('Personas gestionadas', 18716, v_per, n_per, '%d')
cmp_('Asesores activos', 18, v_ase, n_ase, '%d')

# Cuantas de las "gestiones" viejas eran en realidad de un bot.
bot_ges = uno("""
    SELECT COUNT(*)
    FROM [ZOHO].[CRM].[Historico_tipificacion_contact] e
    WHERE e.Cartera_CUN IS NOT NULL AND e.Hecho_por IS NOT NULL
      AND (UPPER(e.Hecho_por) LIKE '%CUN DIGITAL%' OR UPPER(e.Hecho_por) LIKE '%PENAGOS%')
      AND COALESCE(TRY_CONVERT(datetime, e.Hora_de_modificación, 103),
                   TRY_CONVERT(datetime, e.Hora_de_creación, 103)) >= '{i}'
      AND COALESCE(TRY_CONVERT(datetime, e.Hora_de_modificación, 103),
                   TRY_CONVERT(datetime, e.Hora_de_creación, 103)) <  '{n}';""",
              i=INI, n=FIN)[0]
R['tipificaciones_bot_agosto'] = bot_ges
print('  %-34s %d tipificaciones de agosto eran de bot' % ('(de las cuales)', bot_ges))

# Base asignada: esta cifra NO cambia, la asignacion si es Asesor_Unico.
base_asig = uno("""
    SELECT COUNT(DISTINCT LTRIM(RTRIM(G.Número_de_identificación)))
    FROM Financiera.Cartera_CUN_Asesor_Unico G WHERE {f};""", f=FILTRO_VIEJO)[0]
R['base_asignada_personas'] = base_asig
print('  %-34s %d  (definicion correcta: asignacion SI es Asesor_Unico)'
      % ('Base asignada (personas)', base_asig))

# ═══════════════════════════════════════════════════ EMBUDO Y EFECTIVIDAD
cab('EMBUDO: gestionadas -> pagaron')

v_emb = uno("""
    WITH B AS (SELECT LTRIM(RTRIM(G.Número_de_identificación)) AS ident,
                      TRY_CONVERT(datetime, G.Hora_modificacion_tipif, 103) AS fg,
                      {vp} AS fp
               FROM Financiera.Cartera_CUN_Asesor_Unico G WHERE {f}),
    GEST AS (SELECT DISTINCT ident FROM B WHERE fg >= '{i}' AND fg < '{n}'),
    PAGO AS (SELECT DISTINCT ident FROM B WHERE fp >= '{i}' AND fp < '{n}')
    SELECT (SELECT COUNT(*) FROM GEST), (SELECT COUNT(*) FROM PAGO),
           (SELECT COUNT(*) FROM GEST g JOIN PAGO p ON p.ident = g.ident);""",
             f=FILTRO_VIEJO, vp=FECHA_PAGO, i=INI, n=FIN)

n_emb = uno("""
    WITH GEST AS (
        SELECT DISTINCT LTRIM(RTRIM(CONVERT(varchar(20), c.[Número_de_identificación]))) AS ident
        FROM [ZOHO].[CRM].[Historico_tipificacion_contact] e
        JOIN ZOHO.CRM.Cartera_CUN c ON CONVERT(varchar(30), c.Id) = CONVERT(varchar(30), e.Cartera_CUN)
        WHERE e.Hecho_por IS NOT NULL
          AND UPPER(e.Hecho_por) NOT LIKE '%CUN DIGITAL%'
          AND UPPER(e.Hecho_por) NOT LIKE '%PENAGOS%'
          AND c.[Número_de_identificación] IS NOT NULL AND c.[Número_de_identificación] <> ''
          AND COALESCE(TRY_CONVERT(datetime, e.Hora_de_modificación, 103),
                       TRY_CONVERT(datetime, e.Hora_de_creación, 103)) >= '{i}'
          AND COALESCE(TRY_CONVERT(datetime, e.Hora_de_modificación, 103),
                       TRY_CONVERT(datetime, e.Hora_de_creación, 103)) <  '{n}'),
    PAGO AS (
        SELECT DISTINCT LTRIM(RTRIM(G.Número_de_identificación)) AS ident
        FROM Financiera.Cartera_CUN_Asesor_Unico G
        WHERE G.GESTION_MARCA = 1 AND {vp} >= '{i}' AND {vp} < '{n}')
    SELECT (SELECT COUNT(*) FROM GEST), (SELECT COUNT(*) FROM PAGO),
           (SELECT COUNT(*) FROM GEST g JOIN PAGO p ON p.ident = g.ident);""",
            vp=FECHA_PAGO, i=INI, n=FIN)

cmp_('Gestionadas que pagaron', 6011, v_emb[2], n_emb[2], '%d')
ef_v = 100.0 * v_emb[2] / v_emb[0] if v_emb[0] else 0
ef_n = 100.0 * n_emb[2] / n_emb[0] if n_emb[0] else 0
cmp_('Efectividad (%)', 32.1, round(ef_v, 1), round(ef_n, 1), '%s')

# ═══════════════════════════════════════════════════ RECAUDO DEL EQUIPO
cab('BLOQUE 5 — RECAUDO REGISTRADO POR EL EQUIPO')

v_rec = uno("""
    SELECT COUNT(*), COUNT(DISTINCT LTRIM(RTRIM(G.Número_de_identificación))),
           SUM({v})
    FROM Financiera.Cartera_CUN_Asesor_Unico G
    WHERE {f} AND {vp} >= '{i}' AND {vp} < '{n}' AND {v} > 0;""",
            f=FILTRO_VIEJO, v=VALOR, vp=FECHA_PAGO, i=INI, n=FIN)

# Correcto: solo pagos de personas efectivamente gestionadas, y posteriores a
# la primera gestion (que es lo que el equipo puede reclamar como suyo).
n_rec = uno("""
    SELECT COUNT(*), COUNT(DISTINCT LTRIM(RTRIM(G.Número_de_identificación))),
           SUM({v})
    FROM Financiera.Cartera_CUN_Asesor_Unico G
    WHERE G.GESTION_PAGO_POST_MARCA = 1
      AND {vp} >= '{i}' AND {vp} < '{n}' AND {v} > 0;""",
            v=VALOR, vp=FECHA_PAGO, i=INI, n=FIN)

cmp_('Pagos registrados', 19002, v_rec[0], n_rec[0], '%d')
cmp_('Estudiantes que pagaron', 11804, v_rec[1], n_rec[1], '%d')
cmp_('Valor recaudado ($MM)', 5483.9,
     round(float(v_rec[2] or 0) / 1e6, 1), round(float(n_rec[2] or 0) / 1e6, 1), '%s')
tk_v = float(v_rec[2] or 0) / v_rec[0] if v_rec[0] else 0
tk_n = float(n_rec[2] or 0) / n_rec[0] if n_rec[0] else 0
cmp_('Ticket promedio ($)', 288642, int(tk_v), int(tk_n), '%d')

# Cuanto del recaudo publicado venia de gente que NADIE gestiono.
sin_gest = uno("""
    SELECT COUNT(*), SUM({v})
    FROM Financiera.Cartera_CUN_Asesor_Unico G
    WHERE {f} AND G.GESTION_MARCA = 0
      AND {vp} >= '{i}' AND {vp} < '{n}' AND {v} > 0;""",
               f=FILTRO_VIEJO, v=VALOR, vp=FECHA_PAGO, i=INI, n=FIN)
R['recaudo_sin_gestion'] = {'pagos': sin_gest[0],
                            'valor_mm': round(float(sin_gest[1] or 0) / 1e6, 1)}
print('  %-34s %d pagos / $%s MM venian de personas que NADIE gestiono'
      % ('(del publicado)', sin_gest[0], R['recaudo_sin_gestion']['valor_mm']))

# ═══════════════════════════════════════════════════ DISPERSION POR ASESOR
cab('DISPERSION DE LA CARGA POR ASESOR (corregido)')

disp = todos("""
    SELECT UPPER(LTRIM(RTRIM(CONVERT(varchar(200), e.Hecho_por)))) AS asesor,
           COUNT(*) AS gestiones,
           COUNT(DISTINCT LTRIM(RTRIM(CONVERT(varchar(20), c.[Número_de_identificación])))) AS personas
    FROM [ZOHO].[CRM].[Historico_tipificacion_contact] e
    JOIN ZOHO.CRM.Cartera_CUN c ON CONVERT(varchar(30), c.Id) = CONVERT(varchar(30), e.Cartera_CUN)
    WHERE e.Hecho_por IS NOT NULL
      AND UPPER(e.Hecho_por) NOT LIKE '%CUN DIGITAL%'
      AND UPPER(e.Hecho_por) NOT LIKE '%PENAGOS%'
      AND c.[Número_de_identificación] IS NOT NULL AND c.[Número_de_identificación] <> ''
      AND COALESCE(TRY_CONVERT(datetime, e.Hora_de_modificación, 103),
                   TRY_CONVERT(datetime, e.Hora_de_creación, 103)) >= '{i}'
      AND COALESCE(TRY_CONVERT(datetime, e.Hora_de_modificación, 103),
                   TRY_CONVERT(datetime, e.Hora_de_creación, 103)) <  '{n}'
    GROUP BY UPPER(LTRIM(RTRIM(CONVERT(varchar(200), e.Hecho_por))))
    ORDER BY gestiones DESC;""", i=INI, n=FIN)

tot_g = sum(r[1] for r in disp)
R['dispersion'] = {'asesores': len(disp), 'min': disp[-1][1], 'max': disp[0][1],
                   'promedio': int(round(tot_g * 1.0 / len(disp))), 'total': tot_g,
                   'concentracion_top1': round(100.0 * disp[0][1] / tot_g, 1)}
print('  Asesores con gestion : %d' % len(disp))
print('  Rango                : %d a %d gestiones (promedio %d)'
      % (disp[-1][1], disp[0][1], R['dispersion']['promedio']))
print('  Top 1 concentra      : %s%% de la actividad' % R['dispersion']['concentracion_top1'])

json.dump(R, open(SALIDA, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
print('\n-> %s' % SALIDA)
conn.close()
