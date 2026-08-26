# -*- coding: utf-8 -*-
"""
Aplica a USP_Foto_Meta_Comercial_Mensual el mismo colapso del calendario que
SP_Cartera_Total: UNA fila por cod_periodo, con MIN(fec_inicio) / MAX(fec_fin).

El CTE PERIODO_CAL hacia SELECT DISTINCT sobre cod_periodo, pero la llave real de
Periodos_Calendario es cod_periodo + descripcion_metod y 24 codigos tienen fec_fin
distinta segun la modalidad. El dia que una modalidad cierre y otra no, ese DISTINCT
devuelve DOS filas para el mismo periodo y multiplica filas en el SELECT que lo consume.

Hoy no ocurre (0 codigos con ESTADO divergente), pero es la misma bomba de tiempo que
se desactivo en SP_Cartera_Total. Decision de Cartera (2026-08-26): MIN/MAX.

NO agrega CLASIFICACION_CARTERA: ver nota en el reporte -- este SP congela atributos al
primer ingreso del credito a la meta, y la clasificacion cambia con el tiempo, asi que
necesita una decision de negocio aparte (congelar vs refrescar cada mes).

Uso:
    .venv/Scripts/python.exe aplicar_calendario_min_max_meta.py <volcado.sql> <salida.sql>
"""
import sys
import io

VIEJO = """        PERIODO_CAL AS (
            SELECT DISTINCT CONVERT(VARCHAR(10), cod_periodo) AS PERIODO,
                CASE
                    WHEN fec_inicio >  CAST(GETDATE() AS DATE)                                             THEN 'PERIODO NO HA INICIADO'
                    WHEN fec_inicio <= CAST(GETDATE() AS DATE) AND fec_fin >= CAST(GETDATE() AS DATE)      THEN 'ACTIVO'
                    ELSE 'NO ACTIVO'
                END AS ESTADO
            FROM Dbo.Periodos_Calendario
        )"""

NUEVO = """        PERIODO_CAL AS (
            -- UNA fila por cod_periodo. La llave real de Periodos_Calendario es
            -- cod_periodo + descripcion_metod, y 24 codigos tienen fec_fin distinta segun la
            -- modalidad: el SELECT DISTINCT anterior podia devolver DOS filas para el mismo
            -- periodo y multiplicar filas. Se colapsa con MIN(fec_inicio) / MAX(fec_fin),
            -- igual que en SP_Cartera_Total (decision de Cartera, 2026-08-26).
            -- OJO: ese rango envolvente no corresponde a ninguna modalidad concreta.
            SELECT pc.PERIODO,
                CASE
                    WHEN pc.FEC_INICIO >  CAST(GETDATE() AS DATE) THEN 'PERIODO NO HA INICIADO'
                    WHEN pc.FEC_FIN    >= CAST(GETDATE() AS DATE) THEN 'ACTIVO'
                    ELSE 'NO ACTIVO'
                END AS ESTADO
            FROM (
                SELECT CONVERT(VARCHAR(10), cod_periodo) AS PERIODO,
                       MIN(fec_inicio) AS FEC_INICIO,
                       MAX(fec_fin)    AS FEC_FIN
                FROM Dbo.Periodos_Calendario
                GROUP BY CONVERT(VARCHAR(10), cod_periodo)
            ) pc
        )"""


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(2)
    origen, destino = sys.argv[1], sys.argv[2]

    with io.open(origen, "r", encoding="utf-8") as fh:
        sql = fh.read()

    n = sql.count(VIEJO)
    if n != 1:
        print("ABORTADO: esperaba 1 ocurrencia de PERIODO_CAL, encontre %d." % n)
        sys.exit(1)

    sql = sql.replace(VIEJO, NUEVO, 1)
    print("  OK  PERIODO_CAL colapsado a 1 fila por cod_periodo")

    if "SELECT DISTINCT CONVERT(VARCHAR(10), cod_periodo)" in sql:
        print("ABORTADO: quedo un SELECT DISTINCT viejo sobre el calendario")
        sys.exit(1)

    with io.open(destino, "w", encoding="utf-8") as fh:
        fh.write(sql)
    print("\nEscrito: %s  (%d chars)" % (destino, len(sql)))


if __name__ == "__main__":
    main()
