# -*- coding: utf-8 -*-
"""Exporta a Excel las cedulas de ejemplo que sustentan la fe de erratas.

Hoja 1 (Cedulas): la lista limpia, solo CASO + IDENTIFICACION, para pegar o cruzar.
Hoja 2 (Detalle) : los mismos casos con los campos que PRUEBAN cada uno, porque una
                   cedula sola no explica nada si toca sustentarla.

Se deduplica por cedula: en el caso A una misma persona aparecia 7 veces, una por
cada credito, y como ejemplo eso solo hace ruido.

Solo ESTUDIANTES en los cuatro casos: los saldos mas altos de la tabla son NITs
(convenios con miles de creditos) y como ejemplo confunden en vez de explicar.

Una cedula puede salir en dos casos a la vez -- por ejemplo 1104700301, en A y en D --
y eso no es un error: en un credito la toco el bot y en otro hubo gestion real con su
pago. Es justo el mecanismo que se quiere mostrar.

⚠ Contiene datos personales. Es para sustentar ante la Coordinacion, que ya tiene la
  base completa. No circular fuera de esa conversacion.

Uso:  .venv/Scripts/python.exe exportar_ejemplos_fe_erratas.py
"""
import sys

import pandas as pd
import pyodbc
from openpyxl.styles import Alignment, Font, PatternFill
from openpyxl.utils import get_column_letter

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

SALIDA = "Ejemplos_Fe_Erratas_Agosto_2026.xlsx"
CONN = ("DRIVER={ODBC Driver 18 for SQL Server};SERVER=172.16.1.33;"
        "DATABASE=CUN_REPOSITORIO;Trusted_Connection=yes;TrustServerCertificate=yes;")
INI, FIN = "2026-08-01", "2026-09-01"
TOPE = 15                       # cedulas por caso
HEX_MARINO = "0C2340"

DINERO = ("TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(REPLACE("
          "G.Valor_pagado,'CO$',''),',',''),' ',''))")
VIEJO = ("G.Asesor_Unico NOT IN ('Reasignar en CRM','Sin asignar') "
         "AND NULLIF(LTRIM(RTRIM(G.Asesor_Unico)),'') IS NOT NULL")

# Una fila por CEDULA en cada caso. El ROW_NUMBER se queda con el registro de mayor
# valor pagado, que es el mas ilustrativo para mostrar de que tamano es el caso.
CASOS = {
    "A. El bot tipifico, se acredito a un asesor": f"""
        SELECT TOP {TOPE} IDENTIFICACION, ASESOR_QUE_SE_ACREDITABA, QUIEN_TIPIFICO,
               FECHA_TIPIFICACION, GESTOR_REAL, TUVO_GESTION_HUMANA, VALOR_PAGADO
        FROM (
          SELECT LTRIM(RTRIM(G.[Número_de_identificación])) AS IDENTIFICACION,
                 LTRIM(RTRIM(G.Asesor_Unico))               AS ASESOR_QUE_SE_ACREDITABA,
                 G.Hecho_por                                AS QUIEN_TIPIFICO,
                 G.Hora_modificacion_tipif                  AS FECHA_TIPIFICACION,
                 ISNULL(G.GESTION_ASESOR, '(nadie)')        AS GESTOR_REAL,
                 CASE WHEN G.GESTION_MARCA = 1 THEN 'Si, en otro credito'
                      ELSE 'No, nunca' END                  AS TUVO_GESTION_HUMANA,
                 {DINERO}                                   AS VALOR_PAGADO,
                 ROW_NUMBER() OVER (PARTITION BY LTRIM(RTRIM(G.[Número_de_identificación]))
                                    ORDER BY {DINERO} DESC) AS rn
          FROM Financiera.Cartera_CUN_Asesor_Unico G
          /* NO se exige GESTION_MARCA = 0. Esa marca es por CEDULA, y casi toda
             persona con un toque del bot tuvo contacto humano en algun otro
             credito: pedirlo dejaba 1 sola cedula de ejemplo. El error no es
             "nadie lo toco" sino que ESTE movimiento, que fue del bot, se contaba
             como una gestion mas del asesor. Son 42.738 filas de 14.385 cedulas. */
          WHERE {VIEJO} AND G.[Tipo_cliente] = 'ESTUDIANTES'
            AND UPPER(G.Hecho_por) LIKE '%CUN DIGITAL%'
            AND TRY_CONVERT(datetime, G.Hora_modificacion_tipif, 103) >= '{INI}'
            AND TRY_CONVERT(datetime, G.Hora_modificacion_tipif, 103) <  '{FIN}'
        ) x WHERE rn = 1 ORDER BY VALOR_PAGADO DESC;""",

    "B. Pago sin ninguna gestion previa": f"""
        SELECT TOP {TOPE} IDENTIFICACION, ASESOR_QUE_SE_ACREDITABA, FECHA_PAGO, VALOR_PAGADO
        FROM (
          SELECT LTRIM(RTRIM(G.[Número_de_identificación])) AS IDENTIFICACION,
                 LTRIM(RTRIM(G.Asesor_Unico))               AS ASESOR_QUE_SE_ACREDITABA,
                 G.[Fecha_de_pago]                          AS FECHA_PAGO,
                 {DINERO}                                   AS VALOR_PAGADO,
                 ROW_NUMBER() OVER (PARTITION BY LTRIM(RTRIM(G.[Número_de_identificación]))
                                    ORDER BY {DINERO} DESC) AS rn
          FROM Financiera.Cartera_CUN_Asesor_Unico G
          WHERE {VIEJO} AND G.GESTION_MARCA = 0 AND G.[Tipo_cliente] = 'ESTUDIANTES'
            AND TRY_CONVERT(date, G.[Fecha_de_pago], 103) >= '{INI}'
            AND TRY_CONVERT(date, G.[Fecha_de_pago], 103) <  '{FIN}' AND {DINERO} > 0
        ) x WHERE rn = 1 ORDER BY VALOR_PAGADO DESC;""",

    "C. Pago anterior a la primera gestion": f"""
        SELECT TOP {TOPE} IDENTIFICACION, ASESOR_QUE_GESTIONO, FECHA_PAGO,
               PRIMERA_GESTION, DIAS_ANTES, VALOR_PAGADO
        FROM (
          SELECT LTRIM(RTRIM(G.[Número_de_identificación])) AS IDENTIFICACION,
                 G.GESTION_ASESOR                           AS ASESOR_QUE_GESTIONO,
                 G.[Fecha_de_pago]                          AS FECHA_PAGO,
                 G.GESTION_FECHA_PRIMERA                    AS PRIMERA_GESTION,
                 DATEDIFF(DAY, TRY_CONVERT(date, G.[Fecha_de_pago], 103),
                          CAST(G.GESTION_FECHA_PRIMERA AS date)) AS DIAS_ANTES,
                 {DINERO}                                   AS VALOR_PAGADO,
                 ROW_NUMBER() OVER (PARTITION BY LTRIM(RTRIM(G.[Número_de_identificación]))
                                    ORDER BY {DINERO} DESC) AS rn
          FROM Financiera.Cartera_CUN_Asesor_Unico G
          WHERE G.GESTION_MARCA = 1 AND G.GESTION_PAGO_POST_MARCA = 0
            AND G.[Tipo_cliente] = 'ESTUDIANTES'
            AND G.GESTION_FECHA_PRIMERA >= '{INI}' AND G.GESTION_FECHA_PRIMERA < '{FIN}'
            AND TRY_CONVERT(date, G.[Fecha_de_pago], 103) >= '{INI}'
            AND TRY_CONVERT(date, G.[Fecha_de_pago], 103) <  '{FIN}' AND {DINERO} > 0
        ) x WHERE rn = 1 ORDER BY VALOR_PAGADO DESC;""",

    "D. Gestion y pago bien atribuidos": f"""
        SELECT TOP {TOPE} IDENTIFICACION, ASESOR_QUE_GESTIONO, PRIMERA_GESTION,
               FECHA_PAGO, DIAS_DESPUES, VALOR_PAGADO
        FROM (
          SELECT LTRIM(RTRIM(G.[Número_de_identificación])) AS IDENTIFICACION,
                 G.GESTION_ASESOR                           AS ASESOR_QUE_GESTIONO,
                 G.GESTION_FECHA_PRIMERA                    AS PRIMERA_GESTION,
                 G.[Fecha_de_pago]                          AS FECHA_PAGO,
                 DATEDIFF(DAY, CAST(G.GESTION_FECHA_PRIMERA AS date),
                          TRY_CONVERT(date, G.[Fecha_de_pago], 103)) AS DIAS_DESPUES,
                 {DINERO}                                   AS VALOR_PAGADO,
                 ROW_NUMBER() OVER (PARTITION BY LTRIM(RTRIM(G.[Número_de_identificación]))
                                    ORDER BY {DINERO} DESC) AS rn
          FROM Financiera.Cartera_CUN_Asesor_Unico G
          WHERE G.GESTION_PAGO_POST_MARCA = 1 AND G.[Tipo_cliente] = 'ESTUDIANTES'
            AND TRY_CONVERT(date, G.[Fecha_de_pago], 103) >= '{INI}'
            AND TRY_CONVERT(date, G.[Fecha_de_pago], 103) <  '{FIN}' AND {DINERO} > 0
        ) x WHERE rn = 1 ORDER BY VALOR_PAGADO DESC;""",
}

QUE_PRUEBA = {
    "A. El bot tipifico, se acredito a un asesor":
        "Asesor_Unico trae un nombre real, pero quien tipifico fue CUN Digital. Son 42.738 "
        "filas de 14.385 cedulas: el mecanismo que inflo las gestiones de 22.941 a 61.767. "
        "Ojo: la persona SI pudo tener contacto humano en otro credito; lo que no es "
        "gestion del asesor es ESTE movimiento, que lo hizo el robot.",
    "B. Pago sin ninguna gestion previa":
        "Pagaron en agosto sin que ningun asesor los contactara nunca. "
        "Son 4.983 pagos / $1.807,3 MM que se reportaban como recaudo del equipo.",
    "C. Pago anterior a la primera gestion":
        "Si hubo gestion, pero el estudiante ya habia pagado cuando lo contactaron. "
        "Son 5.269 pagos / $1.391,0 MM. Es cambio de criterio, no error de calculo.",
    "D. Gestion y pago bien atribuidos":
        "Contraejemplo: el asesor contacto y despues llego el pago. "
        "Son los 9.280 pagos / $2.408,0 MM que si se atribuyen al equipo.",
}


def formatear(ws, df, ancho_max=40):
    relleno = PatternFill("solid", fgColor=HEX_MARINO)
    fuente = Font(name="Montserrat", bold=True, color="FFFFFF", size=10)
    for j, col in enumerate(df.columns, start=1):
        c = ws.cell(row=1, column=j)
        c.fill, c.font = relleno, fuente
        c.alignment = Alignment(vertical="center", horizontal="left")
        largo = df[col].astype(str).str.len().max()
        largo = 0 if pd.isna(largo) else int(largo)
        ws.column_dimensions[get_column_letter(j)].width = min(
            max(len(str(col)), largo) + 3, ancho_max)
    ws.row_dimensions[1].height = 20
    ws.freeze_panes = "A2"
    ws.auto_filter.ref = ws.dimensions


def main():
    print("Consultando 172.16.1.33 / CUN_REPOSITORIO ...")
    detalle, cedulas = [], []
    with pyodbc.connect(CONN) as cn:
        cn.timeout = 900
        for caso, sql in CASOS.items():
            df = pd.read_sql(sql, cn)
            df.insert(0, "CASO", caso)
            detalle.append(df)
            cedulas.append(df[["CASO", "IDENTIFICACION"]])
            print("  %-45s %2d cedulas" % (caso[:45], len(df)))

    hoja_cedulas = pd.concat(cedulas, ignore_index=True)
    # IDENTIFICACION como texto: Excel convierte a numero y se come los ceros
    # a la izquierda de las cedulas que empiezan por 0.
    hoja_cedulas["IDENTIFICACION"] = hoja_cedulas["IDENTIFICACION"].astype(str)

    guia = pd.DataFrame(
        [{"CASO": k, "QUE PRUEBA ESTE CASO": v} for k, v in QUE_PRUEBA.items()])

    print("Escribiendo %s ..." % SALIDA)
    with pd.ExcelWriter(SALIDA, engine="openpyxl") as xl:
        hoja_cedulas.to_excel(xl, sheet_name="Cedulas", index=False)
        formatear(xl.sheets["Cedulas"], hoja_cedulas)

        for df, (caso, _) in zip(detalle, QUE_PRUEBA.items()):
            nombre = "Detalle " + caso[:1]        # "Detalle A", "Detalle B"...
            df2 = df.drop(columns=["CASO"]).copy()
            df2["IDENTIFICACION"] = df2["IDENTIFICACION"].astype(str)
            df2.to_excel(xl, sheet_name=nombre, index=False)
            formatear(xl.sheets[nombre], df2)

        guia.to_excel(xl, sheet_name="Guia", index=False)
        wg = xl.sheets["Guia"]
        wg.column_dimensions["A"].width = 44
        wg.column_dimensions["B"].width = 100
        for i in range(2, len(guia) + 2):
            wg.cell(row=i, column=2).alignment = Alignment(wrap_text=True, vertical="top")

    print("OK -> %s   (%d cedulas en total)" % (SALIDA, len(hoja_cedulas)))


if __name__ == "__main__":
    main()
