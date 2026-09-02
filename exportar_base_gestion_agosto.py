"""Exporta a Excel la base de gestion de asesores de agosto 2026.

Acompana al Informe_Ejecutivo_Cierre_Agosto_2026.docx: el informe reporta el
equipo en agregado y sin nombres; esta base sí los trae, porque es el archivo de
trabajo del coordinador que los tiene a cargo.

Reglas de calculo (las mismas del informe, ver .claude/skills/informes-cartera-word):
  * Universo : Asesor_Unico distinto de 'Reasignar en CRM' y 'Sin asignar'.
  * Gestion  : Hora_modificacion_tipif dentro de agosto. NO Hora_de_modificación,
               que cae en agosto para el 93% de la base por una actualizacion masiva.
  * Pago     : Fecha_de_pago dentro de agosto, sumando Valor_pagado.
  * El dinero viene como 'CO$ 351,576.50' y sin sanear suma 0 en silencio.

Hojas:
  1. Base_Gestion_Agosto : las 61.767 gestiones del mes, una fila por movimiento.
  2. Base_Pagos_Agosto   : los 19.002 pagos del mes ($5.483,9 MM), que son los que
                           reporta el informe. Solo 8.560 caen sobre una fila que
                           ademas se tipifico en agosto.
  3. Resumen_Asesor      : gestiones, personas, pagos y efectividad por asesor.
  4. Resumen_Tipificacion: en que termina la gestion.
  5. Sin_Asignar         : los 84.179 registros sin asesor responsable.
  6. Diccionario         : que significa cada columna.

Uso:  .venv/Scripts/python.exe exportar_base_gestion_agosto.py
"""
import sys

import pandas as pd
import pyodbc
from openpyxl.styles import Alignment, Font, PatternFill
from openpyxl.utils import get_column_letter

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

SALIDA = "Base_Gestion_Asesores_Agosto_2026.xlsx"
DESDE, HASTA = "2026-08-01", "2026-09-01"

CONN = (
    "DRIVER={ODBC Driver 18 for SQL Server};"
    "SERVER=172.16.1.33;DATABASE=CUN_REPOSITORIO;"
    "Trusted_Connection=yes;TrustServerCertificate=yes;"
)

HEX_MARINO = "0C2340"
HEX_ZEBRA = "F8F9FA"

# Saneo del dinero del CRM: 'CO$ 351,576.50' -> 351576.50
DINERO = ("TRY_CONVERT(DECIMAL(18,2), "
          "REPLACE(REPLACE(REPLACE({0},'CO$',''),',',''),' ',''))")

FILTRO_ASESOR = ("G.Asesor_Unico NOT IN ('Reasignar en CRM','Sin asignar') "
                 "AND NULLIF(LTRIM(RTRIM(G.Asesor_Unico)),'') IS NOT NULL")

SQL_BASE = f"""
SELECT
    LTRIM(RTRIM(G.Asesor_Unico))                          AS ASESOR,
    G.Propietario_de_Cartera_CUN_Name                     AS PROPIETARIO_CRM,
    TRY_CONVERT(datetime, G.Hora_modificacion_tipif, 103) AS FECHA_GESTION,
    LTRIM(RTRIM(G.Número_de_identificación))              AS IDENTIFICACION,
    G.Documento_Cartera_CUN                               AS REGISTRO,
    G.Número_de_crédito                                   AS NUMERO_CREDITO,
    G.Periodo                                             AS PERIODO,
    G.Programa_académico                                  AS PROGRAMA,
    G.Semestre                                            AS SEMESTRE,
    G.Estado_cartera                                      AS ESTADO_CARTERA,
    NULLIF(LTRIM(RTRIM(G.Tipificación_anterior)),'')      AS TIPIFICACION_ANTERIOR,
    NULLIF(LTRIM(RTRIM(G.Tipificación_nueva)),'')         AS TIPIFICACION_NUEVA,
    NULLIF(LTRIM(RTRIM(G.Tipificación_a_marcar)),'')      AS TIPIFICACION_VIGENTE,
    TRY_CONVERT(datetime, G.Fechahora_llamada, 103)       AS FECHA_LLAMADA,
    TRY_CONVERT(date,     G.Fecha_de_pago,     103)       AS FECHA_PAGO,
    {DINERO.format('G.Valor_pagado')}                     AS VALOR_PAGADO,
    {DINERO.format('G.Valor_total')}                      AS VALOR_CUOTA,
    {DINERO.format('G.Deuda_total')}                      AS DEUDA_TOTAL,
    {DINERO.format('G.Valor_de_compromiso')}              AS VALOR_COMPROMISO,
    TRY_CONVERT(date, G.Fecha_del_pago_según_acuerdo, 103) AS FECHA_ACUERDO,
    G.Días_de_mora                                        AS DIAS_MORA,
    G.CLASIFICACION_CARTERA                               AS CLASIFICACION_CARTERA,
    G.MARCA_ACADEMICA_GESTION                             AS MARCA_ACADEMICA,
    G.RES_PERFIL_RIESGO                                   AS PERFIL_RIESGO,
    G.Celular                                             AS CELULAR,
    G.Correo_electrónico                                  AS CORREO,
    CASE WHEN TRY_CONVERT(date, G.Fecha_de_pago, 103) >= '{DESDE}'
          AND TRY_CONVERT(date, G.Fecha_de_pago, 103) <  '{HASTA}'
         THEN 'SI' ELSE 'NO' END                          AS PAGO_EN_AGOSTO
FROM Financiera.Cartera_CUN_Asesor_Unico G
WHERE {FILTRO_ASESOR}
  AND TRY_CONVERT(datetime, G.Hora_modificacion_tipif, 103) >= '{DESDE}'
  AND TRY_CONVERT(datetime, G.Hora_modificacion_tipif, 103) <  '{HASTA}'
ORDER BY ASESOR, FECHA_GESTION;
"""

# Universo de PAGO distinto al de gestion, a proposito: de los 19.002 pagos de
# agosto solo 8.560 caen sobre una fila que ademas se tipifico en agosto. El
# informe reporta los 19.002, asi que la base tiene que traerlos todos o las dos
# cifras no cuadrarian.
SQL_PAGOS = f"""
SELECT
    LTRIM(RTRIM(G.Asesor_Unico))                          AS ASESOR,
    TRY_CONVERT(date, G.Fecha_de_pago, 103)               AS FECHA_PAGO,
    LTRIM(RTRIM(G.Número_de_identificación))              AS IDENTIFICACION,
    G.Documento_Cartera_CUN                               AS REGISTRO,
    G.Número_de_crédito                                   AS NUMERO_CREDITO,
    G.Periodo                                             AS PERIODO,
    G.Programa_académico                                  AS PROGRAMA,
    G.Estado_cartera                                      AS ESTADO_CARTERA,
    NULLIF(LTRIM(RTRIM(G.Tipificación_a_marcar)),'')      AS TIPIFICACION_VIGENTE,
    {DINERO.format('G.Valor_pagado')}                     AS VALOR_PAGADO,
    {DINERO.format('G.Valor_total')}                      AS VALOR_CUOTA,
    TRY_CONVERT(datetime, G.Hora_modificacion_tipif, 103) AS FECHA_GESTION,
    CASE WHEN TRY_CONVERT(datetime, G.Hora_modificacion_tipif, 103) >= '{DESDE}'
          AND TRY_CONVERT(datetime, G.Hora_modificacion_tipif, 103) <  '{HASTA}'
         THEN 'SI' ELSE 'NO' END                          AS GESTIONADO_EN_AGOSTO
FROM Financiera.Cartera_CUN_Asesor_Unico G
WHERE {FILTRO_ASESOR}
  AND TRY_CONVERT(date, G.Fecha_de_pago, 103) >= '{DESDE}'
  AND TRY_CONVERT(date, G.Fecha_de_pago, 103) <  '{HASTA}'
ORDER BY ASESOR, FECHA_PAGO;
"""

SQL_SIN_ASIGNAR = f"""
SELECT
    LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(G.Asesor_Unico)),''),'(vacio)'))) AS ESTADO_ASIGNACION,
    LTRIM(RTRIM(G.Número_de_identificación))              AS IDENTIFICACION,
    G.Documento_Cartera_CUN                               AS REGISTRO,
    G.Número_de_crédito                                   AS NUMERO_CREDITO,
    G.Periodo                                             AS PERIODO,
    G.Programa_académico                                  AS PROGRAMA,
    G.Estado_cartera                                      AS ESTADO_CARTERA,
    NULLIF(LTRIM(RTRIM(G.Tipificación_a_marcar)),'')      AS ULTIMA_TIPIFICACION,
    {DINERO.format('G.Valor_total')}                      AS VALOR_CUOTA,
    {DINERO.format('G.Deuda_total')}                      AS DEUDA_TOTAL,
    G.Días_de_mora                                        AS DIAS_MORA,
    G.CLASIFICACION_CARTERA                               AS CLASIFICACION_CARTERA,
    G.MARCA_ACADEMICA_GESTION                             AS MARCA_ACADEMICA,
    G.Celular                                             AS CELULAR,
    G.Correo_electrónico                                  AS CORREO
FROM Financiera.Cartera_CUN_Asesor_Unico G
WHERE G.Asesor_Unico IN ('Reasignar en CRM','Sin asignar')
   OR NULLIF(LTRIM(RTRIM(G.Asesor_Unico)),'') IS NULL
ORDER BY ESTADO_ASIGNACION, IDENTIFICACION;
"""

DICCIONARIO = [
    ("ASESOR", "Asesor responsable del registro (columna Asesor_Unico del CRM). Excluye 'Reasignar en CRM' y 'Sin asignar', que van en su propia hoja."),
    ("PROPIETARIO_CRM", "Propietario del registro en el CRM. Puede diferir del asesor responsable."),
    ("FECHA_GESTION", "Momento en que cambio la tipificacion. Es lo que cuenta como gestion del mes."),
    ("IDENTIFICACION", "Documento del estudiante. Llave para agrupar por persona."),
    ("REGISTRO", "Identificador del registro en el CRM: identificacion-periodo-credito."),
    ("NUMERO_CREDITO", "Obligacion. Una fila es una gestion sobre una obligacion, NO una persona."),
    ("TIPIFICACION_ANTERIOR / NUEVA", "De que tipificacion a cual se movio el registro. Solo el 11% tiene la anterior."),
    ("TIPIFICACION_VIGENTE", "Tipificacion con la que quedo el registro al momento de la extraccion."),
    ("FECHA_LLAMADA", "Marca de la llamada, cuando el asesor la registro."),
    ("FECHA_PAGO / VALOR_PAGADO", "Pago registrado en el CRM. Ojo: es lo que el asesor marco, no la caja."),
    ("PAGO_EN_AGOSTO", "SI cuando esa misma fila registra pago en agosto. Solo 8.560 de los 19.002 pagos del mes caen sobre una fila tipificada en agosto; los 19.002 completos estan en la hoja Base_Pagos_Agosto."),
    ("GESTIONADO_EN_AGOSTO", "Solo en Base_Pagos_Agosto: si esa obligacion ademas se tipifico dentro del mes."),
    ("Gestionadas_que_pagaron", "Personas gestionadas en agosto que registraron pago en agosto, en cualquiera de sus obligaciones. Es el numerador de la efectividad y la definicion que usa el informe."),
    ("VALOR_CUOTA / DEUDA_TOTAL", "Valor de la cuota y deuda total del estudiante segun el CRM."),
    ("VALOR_COMPROMISO / FECHA_ACUERDO", "Acuerdo de pago pactado, cuando existe."),
    ("DIAS_MORA", "Dias de mora de la obligacion."),
    ("CLASIFICACION_CARTERA", "Clasificacion de la cartera (CUENTAS POR COBRAR, CXC REFINANCIADO, etc.)."),
    ("MARCA_ACADEMICA", "Marca que enruta la gestion segun el vinculo academico del deudor."),
    ("PERFIL_RIESGO", "Perfil crediticio del deudor. Riesgo Alto o Regular es señal adversa."),
    ("ESTADO_ASIGNACION", "Solo en la hoja Sin_Asignar: si el registro esta 'Reasignar en CRM' o 'Sin asignar'."),
]


def formatear(ws, df, congelar=True, ancho_max=38):
    relleno = PatternFill("solid", fgColor=HEX_MARINO)
    fuente = Font(name="Montserrat", bold=True, color="FFFFFF", size=10)
    for j, col in enumerate(df.columns, start=1):
        c = ws.cell(row=1, column=j)
        c.fill = relleno
        c.font = fuente
        c.alignment = Alignment(vertical="center", horizontal="left")
        largo = df[col].head(300).astype(str).str.len().max()
        largo = 0 if pd.isna(largo) else int(largo)
        ancho = max(len(str(col)), largo) + 2
        ws.column_dimensions[get_column_letter(j)].width = min(ancho, ancho_max)
    ws.row_dimensions[1].height = 22
    if congelar:
        ws.freeze_panes = "A2"
        ws.auto_filter.ref = ws.dimensions


def main():
    print("Conectando a 172.16.1.33 / CUN_REPOSITORIO ...")
    with pyodbc.connect(CONN) as cn:
        cn.timeout = 600
        base = pd.read_sql(SQL_BASE, cn)
        pagos = pd.read_sql(SQL_PAGOS, cn)
        sin_asignar = pd.read_sql(SQL_SIN_ASIGNAR, cn)
    print(f"  gestiones de agosto : {len(base):,} filas")
    print(f"  pagos de agosto     : {len(pagos):,} filas")
    print(f"  sin asignar         : {len(sin_asignar):,} filas")

    # ---- Resumen por asesor.
    # La efectividad se mide a nivel PERSONA y con la misma definicion del
    # informe: de las personas que gestione en agosto, cuantas registraron pago
    # en agosto, aunque el pago haya quedado en otra obligacion del mismo
    # estudiante. Medirla fila contra fila daria un numero mas bajo y no
    # cuadraria con el 32,1% que ya recibio la Coordinacion.
    resumen = (base.groupby("ASESOR")
               .agg(Gestiones=("NUMERO_CREDITO", "size"),
                    Personas_gestionadas=("IDENTIFICACION", "nunique"))
               .reset_index())
    pag = (pagos.groupby("ASESOR")
           .agg(Pagos_registrados=("NUMERO_CREDITO", "size"),
                Personas_con_pago=("IDENTIFICACION", "nunique"),
                Valor_pagado=("VALOR_PAGADO", "sum"))
           .reset_index())

    ids_pagaron = set(pagos["IDENTIFICACION"])
    cruce = (base[base["IDENTIFICACION"].isin(ids_pagaron)]
             .groupby("ASESOR")["IDENTIFICACION"].nunique()
             .rename("Gestionadas_que_pagaron").reset_index())

    resumen = (resumen.merge(pag, on="ASESOR", how="left")
                      .merge(cruce, on="ASESOR", how="left")
                      .fillna({"Pagos_registrados": 0, "Personas_con_pago": 0,
                               "Valor_pagado": 0, "Gestionadas_que_pagaron": 0}))
    for c in ("Pagos_registrados", "Personas_con_pago", "Gestionadas_que_pagaron"):
        resumen[c] = resumen[c].astype(int)
    resumen["Efectividad_pct"] = (100 * resumen["Gestionadas_que_pagaron"]
                                  / resumen["Personas_gestionadas"]).round(2)
    resumen["Valor_pagado_MM"] = (resumen["Valor_pagado"] / 1e6).round(1)
    resumen["Pct_de_la_gestion"] = (100 * resumen["Gestiones"]
                                    / resumen["Gestiones"].sum()).round(2)
    resumen = resumen.drop(columns=["Valor_pagado"]).sort_values(
        "Gestiones", ascending=False)

    gest_pago = base[base["IDENTIFICACION"].isin(ids_pagaron)]["IDENTIFICACION"].nunique()
    total = pd.DataFrame([{
        "ASESOR": "TOTAL EQUIPO",
        "Gestiones": len(base),
        "Personas_gestionadas": base["IDENTIFICACION"].nunique(),
        "Pagos_registrados": len(pagos),
        "Personas_con_pago": pagos["IDENTIFICACION"].nunique(),
        "Gestionadas_que_pagaron": gest_pago,
        "Efectividad_pct": round(100 * gest_pago / base["IDENTIFICACION"].nunique(), 2),
        "Valor_pagado_MM": round(pagos["VALOR_PAGADO"].sum() / 1e6, 1),
        "Pct_de_la_gestion": 100.0}])
    resumen = pd.concat([resumen, total], ignore_index=True)

    # ---- Resumen por tipificacion
    tipif = (base.assign(TIPIFICACION_VIGENTE=base["TIPIFICACION_VIGENTE"]
                         .fillna("(sin tipificar)"))
             .groupby("TIPIFICACION_VIGENTE")
             .agg(Gestiones=("NUMERO_CREDITO", "size"),
                  Personas=("IDENTIFICACION", "nunique"))
             .reset_index()
             .sort_values("Gestiones", ascending=False))
    tipif["Pct"] = (100 * tipif["Gestiones"] / tipif["Gestiones"].sum()).round(2)

    diccionario = pd.DataFrame(DICCIONARIO, columns=["Columna", "Significado"])

    print(f"Escribiendo {SALIDA} ...")
    with pd.ExcelWriter(SALIDA, engine="openpyxl") as xl:
        for nombre, df, congelar in [
            ("Base_Gestion_Agosto", base, True),
            ("Base_Pagos_Agosto", pagos, True),
            ("Resumen_Asesor", resumen, False),
            ("Resumen_Tipificacion", tipif, False),
            ("Sin_Asignar", sin_asignar, True),
            ("Diccionario", diccionario, False),
        ]:
            df.to_excel(xl, sheet_name=nombre, index=False)
            formatear(xl.sheets[nombre], df, congelar=congelar)

        # zebra suave + total en negrita en el resumen por asesor
        wr = xl.sheets["Resumen_Asesor"]
        for i in range(2, len(resumen) + 2):
            if i % 2 == 1:
                for j in range(1, len(resumen.columns) + 1):
                    wr.cell(row=i, column=j).fill = PatternFill("solid", fgColor=HEX_ZEBRA)
        for j in range(1, len(resumen.columns) + 1):
            wr.cell(row=len(resumen) + 1, column=j).font = Font(bold=True)

        wd = xl.sheets["Diccionario"]
        wd.column_dimensions["A"].width = 34
        wd.column_dimensions["B"].width = 104
        for i in range(2, len(diccionario) + 2):
            wd.cell(row=i, column=2).alignment = Alignment(wrap_text=True, vertical="top")

    print(f"OK -> {SALIDA}")
    print(f"   Gestiones            : {len(base):,}")
    print(f"   Asesores             : {base['ASESOR'].nunique()}")
    print(f"   Personas gestionadas : {base['IDENTIFICACION'].nunique():,}")
    print(f"   Pagos en agosto      : {len(pagos):,}  "
          f"(${pagos['VALOR_PAGADO'].sum()/1e6:,.1f} MM)")
    print(f"   Efectividad equipo   : {resumen.iloc[-1]['Efectividad_pct']}%")
    print(f"   Sin asignar          : {len(sin_asignar):,} registros, "
          f"{sin_asignar['IDENTIFICACION'].nunique():,} personas")


if __name__ == "__main__":
    main()
