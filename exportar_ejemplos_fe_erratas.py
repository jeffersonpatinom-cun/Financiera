# -*- coding: utf-8 -*-
"""Exporta a Excel la POBLACION COMPLETA que sustenta la fe de erratas de agosto.

Va a Oscar Penagos para que verifique el mismo, asi que no son ejemplos sueltos:
es el universo entero de cada caso, y los totales tienen que cuadrar con el
informe. Por eso NO se filtra Tipo_cliente aqui -- las cifras publicadas incluyen
NITs de convenio, y filtrarlos aqui haria que los totales no cuadren. Se trae
TIPO_CLIENTE como columna para que el pueda separarlos si quiere.

Hojas:
  Resumen    : conteos y valores por caso. Cuadra con la seccion 5 del informe.
  Detalle A  : 11.822 acciones de asesor que el CRM replico (el conteo inflado).
  Detalle B  :  4.983 pagos de personas que nadie gestiono.
  Detalle C  :  5.269 pagos anteriores a la primera gestion.
  Detalle D  :  9.280 pagos atribuibles a la gestion.
  Cedulas    : las identificaciones distintas de cada caso, lista limpia.

META_2026 trae los meses en que la obligacion estuvo en la meta comercial
(lista separada por comas, ej. "202606, 202607, 202608"). Poblada en 76.560 de
316.862 filas: el resto es cartera fuera de meta. En el caso A es la meta del
credito que el asesor tipifico, mas la marca EN_META_AGOSTO si cualquiera de
los creditos tocados por esa accion estaba en la meta del mes.
  Guia       : que prueba cada caso.

QUE ES EL CASO A (lo importante). Cuando un asesor tipifica, el CRM replica esa
misma tipificacion a las demas cuotas del estudiante bajo el usuario CUN Digital,
en el mismo minuto. Medido en agosto: 38.793 de los 43.556 movimientos del robot
(89,1%) son ese eco; solo 4.595 son accion propia suya. El criterio viejo contaba
cada replica como una gestion mas, y por eso daba 61.767 en vez de 22.941.
Una fila de Detalle A = una accion real del asesor, con las replicas que genero.

⚠ Contiene numeros de identificacion. Se entrega por canal interno.

Uso:  .venv/Scripts/python.exe exportar_ejemplos_fe_erratas.py
"""
import sys

import pandas as pd
import pyodbc
from openpyxl.styles import Alignment, Font, PatternFill
from openpyxl.utils import get_column_letter

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

# Nombre de salida opcional por argumento: si el .xlsx esta abierto en Excel,
# openpyxl falla con PermissionError y se pierde la corrida entera.
SALIDA = sys.argv[1] if len(sys.argv) > 1 else "Ejemplos_Fe_Erratas_Agosto_2026.xlsx"
CONN = ("DRIVER={ODBC Driver 18 for SQL Server};SERVER=172.16.1.33;"
        "DATABASE=CUN_REPOSITORIO;Trusted_Connection=yes;TrustServerCertificate=yes;")
INI, FIN = "2026-08-01", "2026-09-01"
HEX_MARINO = "0C2340"

DINERO = ("TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(REPLACE("
          "G.Valor_pagado,'CO$',''),',',''),' ',''))")
VIEJO = ("G.Asesor_Unico NOT IN ('Reasignar en CRM','Sin asignar') "
         "AND NULLIF(LTRIM(RTRIM(G.Asesor_Unico)),'') IS NOT NULL")

SQL_A = f"""
/* Una fila = una accion del asesor (cedula + tipificacion + minuto) con las
   replicas que el CRM genero sobre las otras cuotas bajo CUN Digital. */
SELECT
    LTRIM(RTRIM(c.[Número_de_identificación]))                  AS IDENTIFICACION,
    MAX(c.[Tipo_cliente])                                       AS TIPO_CLIENTE,
    MAX(CASE WHEN q.quien = 'HUMANO' THEN q.asesor END)         AS ASESOR_QUE_GESTIONO,
    MAX(CASE WHEN q.quien = 'HUMANO'
             THEN NULLIF(LTRIM(RTRIM(g.Meta_2026)),'') END)     AS META_2026,
    MAX(CASE WHEN g.Meta_2026 LIKE '%202608%' THEN 'Si' ELSE 'No' END) AS EN_META_AGOSTO,
    q.tip                                                       AS TIPIFICACION,
    q.cuando                                                    AS MINUTO,
    SUM(CASE WHEN q.quien = 'HUMANO' THEN 1 ELSE 0 END)         AS GESTIONES_REALES,
    SUM(CASE WHEN q.quien = 'BOT'    THEN 1 ELSE 0 END)         AS ECOS_DEL_BOT,
    COUNT(*)                                                    AS TOTAL_CONTADO_ANTES
FROM [ZOHO].[CRM].[Historico_tipificacion_contact] e
JOIN ZOHO.CRM.Cartera_CUN c
      ON CONVERT(varchar(30), c.Id) = CONVERT(varchar(30), e.Cartera_CUN)
/* 1:1 por Id, no hay fan-out: la tabla materializada esta al grano de Cartera_CUN.Id */
LEFT JOIN Financiera.Cartera_CUN_Asesor_Unico g
      ON CONVERT(varchar(30), g.Id) = CONVERT(varchar(30), c.Id)
CROSS APPLY (SELECT
      CASE WHEN UPPER(e.Hecho_por) LIKE '%CUN DIGITAL%'
             OR UPPER(e.Hecho_por) LIKE '%PENAGOS%' THEN 'BOT' ELSE 'HUMANO' END AS quien,
      UPPER(LTRIM(RTRIM(CONVERT(varchar(200), e.Hecho_por))))                    AS asesor,
      LTRIM(RTRIM(CONVERT(varchar(200), e.[Tipificación_nueva])))                AS tip,
      COALESCE(TRY_CONVERT(datetime, e.[Hora_de_modificación], 103),
               TRY_CONVERT(datetime, e.[Hora_de_creación], 103))                 AS cuando) q
WHERE e.Hecho_por IS NOT NULL
  AND c.[Número_de_identificación] IS NOT NULL AND c.[Número_de_identificación] <> ''
  AND q.cuando >= '{INI}' AND q.cuando < '{FIN}'
GROUP BY LTRIM(RTRIM(c.[Número_de_identificación])), q.tip, q.cuando
HAVING SUM(CASE WHEN q.quien = 'HUMANO' THEN 1 ELSE 0 END) >= 1
   AND SUM(CASE WHEN q.quien = 'BOT'    THEN 1 ELSE 0 END) >= 1
ORDER BY ECOS_DEL_BOT DESC, IDENTIFICACION;
"""

SQL_B = f"""
SELECT
    LTRIM(RTRIM(G.[Número_de_identificación]))          AS IDENTIFICACION,
    G.[Tipo_cliente]                                    AS TIPO_CLIENTE,
    LTRIM(RTRIM(G.Asesor_Unico))                        AS ASESOR_QUE_SE_ACREDITABA,
    NULLIF(LTRIM(RTRIM(G.Meta_2026)),'')               AS META_2026,
    G.[Número_de_crédito]                               AS NUMERO_CREDITO,
    G.Periodo                                           AS PERIODO,
    G.[Fecha_de_pago]                                   AS FECHA_PAGO,
    {DINERO}                                            AS VALOR_PAGADO
FROM Financiera.Cartera_CUN_Asesor_Unico G
WHERE {VIEJO} AND G.GESTION_MARCA = 0
  AND TRY_CONVERT(date, G.[Fecha_de_pago], 103) >= '{INI}'
  AND TRY_CONVERT(date, G.[Fecha_de_pago], 103) <  '{FIN}' AND {DINERO} > 0
ORDER BY VALOR_PAGADO DESC;
"""

SQL_C = f"""
SELECT
    LTRIM(RTRIM(G.[Número_de_identificación]))          AS IDENTIFICACION,
    G.[Tipo_cliente]                                    AS TIPO_CLIENTE,
    G.GESTION_ASESOR                                    AS ASESOR_QUE_GESTIONO,
    NULLIF(LTRIM(RTRIM(G.Meta_2026)),'')               AS META_2026,
    G.[Número_de_crédito]                               AS NUMERO_CREDITO,
    G.[Fecha_de_pago]                                   AS FECHA_PAGO,
    G.GESTION_FECHA_PRIMERA                             AS PRIMERA_GESTION,
    DATEDIFF(DAY, TRY_CONVERT(date, G.[Fecha_de_pago], 103),
             CAST(G.GESTION_FECHA_PRIMERA AS date))     AS DIAS_ANTES,
    {DINERO}                                            AS VALOR_PAGADO
FROM Financiera.Cartera_CUN_Asesor_Unico G
WHERE G.GESTION_MARCA = 1 AND G.GESTION_PAGO_POST_MARCA = 0
  AND TRY_CONVERT(date, G.[Fecha_de_pago], 103) >= '{INI}'
  AND TRY_CONVERT(date, G.[Fecha_de_pago], 103) <  '{FIN}' AND {DINERO} > 0
ORDER BY VALOR_PAGADO DESC;
"""

SQL_D = f"""
SELECT
    LTRIM(RTRIM(G.[Número_de_identificación]))          AS IDENTIFICACION,
    G.[Tipo_cliente]                                    AS TIPO_CLIENTE,
    G.GESTION_ASESOR                                    AS ASESOR_QUE_GESTIONO,
    NULLIF(LTRIM(RTRIM(G.Meta_2026)),'')               AS META_2026,
    G.[Número_de_crédito]                               AS NUMERO_CREDITO,
    G.GESTION_FECHA_PRIMERA                             AS PRIMERA_GESTION,
    G.[Fecha_de_pago]                                   AS FECHA_PAGO,
    DATEDIFF(DAY, CAST(G.GESTION_FECHA_PRIMERA AS date),
             TRY_CONVERT(date, G.[Fecha_de_pago], 103)) AS DIAS_DESPUES,
    {DINERO}                                            AS VALOR_PAGADO
FROM Financiera.Cartera_CUN_Asesor_Unico G
WHERE G.GESTION_PAGO_POST_MARCA = 1
  AND TRY_CONVERT(date, G.[Fecha_de_pago], 103) >= '{INI}'
  AND TRY_CONVERT(date, G.[Fecha_de_pago], 103) <  '{FIN}' AND {DINERO} > 0
ORDER BY VALOR_PAGADO DESC;
"""

CASOS = [
    ("A", "Una accion del asesor contada varias veces", SQL_A,
     "El asesor tipifico UNA vez y el CRM replico esa misma tipificacion, en el mismo "
     "minuto, a las demas cuotas del estudiante bajo el usuario CUN Digital. El criterio "
     "viejo contaba cada replica como una gestion mas: por eso 61.767 en vez de 22.941. "
     "En agosto, 38.793 de los 43.556 movimientos del robot (89,1%) son ese eco. Compare "
     "GESTIONES_REALES contra TOTAL_CONTADO_ANTES."),
    ("B", "Pago sin ninguna gestion previa", SQL_B,
     "Pagaron en agosto sin que ningun asesor los contactara nunca. El criterio anterior "
     "sumaba estos pagos como recaudo del equipo."),
    ("C", "Pago anterior a la primera gestion", SQL_C,
     "Si hubo gestion, pero el estudiante ya habia pagado cuando lo contactaron. "
     "DIAS_ANTES dice cuantos dias antes. Es cambio de criterio, no error de calculo."),
    ("D", "Gestion y pago bien atribuidos", SQL_D,
     "Contraejemplo: el asesor contacto y despues llego el pago. DIAS_DESPUES es el "
     "tiempo de respuesta. Son los pagos que si se le atribuyen al equipo."),
]


def formatear(ws, df, ancho_max=40):
    relleno = PatternFill("solid", fgColor=HEX_MARINO)
    fuente = Font(name="Montserrat", bold=True, color="FFFFFF", size=10)
    for j, col in enumerate(df.columns, start=1):
        c = ws.cell(row=1, column=j)
        c.fill, c.font = relleno, fuente
        c.alignment = Alignment(vertical="center", horizontal="left")
        # solo las primeras 500 filas para medir el ancho: con 12k filas, medir
        # todas se vuelve lento y no cambia el resultado.
        largo = df[col].head(500).astype(str).str.len().max()
        largo = 0 if pd.isna(largo) else int(largo)
        ws.column_dimensions[get_column_letter(j)].width = min(
            max(len(str(col)), largo) + 3, ancho_max)
    ws.row_dimensions[1].height = 20
    ws.freeze_panes = "A2"
    ws.auto_filter.ref = ws.dimensions


def main():
    print("Consultando 172.16.1.33 / CUN_REPOSITORIO ...")
    datos, resumen, cedulas = {}, [], []
    with pyodbc.connect(CONN) as cn:
        cn.timeout = 1800
        for letra, titulo, sql, _ in CASOS:
            df = pd.read_sql(sql, cn)
            df["IDENTIFICACION"] = df["IDENTIFICACION"].astype(str)
            datos[letra] = df
            etiqueta = "%s. %s" % (letra, titulo)

            if letra == "A":
                fila = {"CASO": etiqueta, "FILAS": len(df),
                        "ESTUDIANTES": df["IDENTIFICACION"].nunique(),
                        "VALOR_MM": None,
                        "NOTA": "%d gestiones reales generaron %d replicas: el criterio "
                                "viejo contaba %d" % (df["GESTIONES_REALES"].sum(),
                                                      df["ECOS_DEL_BOT"].sum(),
                                                      df["TOTAL_CONTADO_ANTES"].sum())}
            else:
                fila = {"CASO": etiqueta, "FILAS": len(df),
                        "ESTUDIANTES": df["IDENTIFICACION"].nunique(),
                        "VALOR_MM": round(df["VALOR_PAGADO"].sum() / 1e6, 1),
                        "NOTA": ""}
            resumen.append(fila)
            cedulas.append(pd.DataFrame(
                {"CASO": etiqueta,
                 "IDENTIFICACION": sorted(df["IDENTIFICACION"].unique())}))
            print("  Detalle %s  %6d filas / %5d estudiantes" % (
                letra, len(df), df["IDENTIFICACION"].nunique()))

    df_res = pd.DataFrame(resumen)
    df_ced = pd.concat(cedulas, ignore_index=True)
    df_guia = pd.DataFrame([{"CASO": "%s. %s" % (l, t), "QUE PRUEBA": q}
                            for l, t, _, q in CASOS])

    print("Escribiendo %s ..." % SALIDA)
    with pd.ExcelWriter(SALIDA, engine="openpyxl") as xl:
        df_res.to_excel(xl, sheet_name="Resumen", index=False)
        ws = xl.sheets["Resumen"]
        for col, w in (("A", 46), ("B", 12), ("C", 14), ("D", 12), ("E", 78)):
            ws.column_dimensions[col].width = w
        for i in range(2, len(df_res) + 2):
            ws.cell(row=i, column=5).alignment = Alignment(wrap_text=True, vertical="top")
        for j in range(1, 6):
            c = ws.cell(row=1, column=j)
            c.fill = PatternFill("solid", fgColor=HEX_MARINO)
            c.font = Font(name="Montserrat", bold=True, color="FFFFFF", size=10)

        for letra, titulo, _, _ in CASOS:
            nombre = "Detalle " + letra
            datos[letra].to_excel(xl, sheet_name=nombre, index=False)
            formatear(xl.sheets[nombre], datos[letra])

        df_ced.to_excel(xl, sheet_name="Cedulas", index=False)
        formatear(xl.sheets["Cedulas"], df_ced)

        df_guia.to_excel(xl, sheet_name="Guia", index=False)
        wg = xl.sheets["Guia"]
        wg.column_dimensions["A"].width = 46
        wg.column_dimensions["B"].width = 110
        for i in range(2, len(df_guia) + 2):
            wg.cell(row=i, column=2).alignment = Alignment(wrap_text=True, vertical="top")

    print("\nOK -> %s" % SALIDA)
    print(df_res.to_string(index=False))


if __name__ == "__main__":
    main()
