# -*- coding: utf-8 -*-
"""
CLASIFICACION_CARTERA: columna nueva que parte la cartera en dos segun el cierre academico
del periodo, y herencia generica de columnas hacia Creditos_pagos_CTAYUDA.

Decisiones de Cartera (2026-08-26):
  1. Periodo ausente del calendario -> 'CARTERA' (25 codigos / 819 obligaciones).
  2. fec_fin = hoy -> hereda el criterio del ESTADO existente: cuenta como VIGENTE.
  3. La columna va en TODAS las tablas que materializa el SP.
  4. El join al calendario colapsa con MIN(fec_inicio) / MAX(fec_fin) por cod_periodo.
  5. Creditos_pagos_CTAYUDA hereda columnas por NOMBRE (patron de Cartera_Destiempo_ZOHO),
     no por lista a mano.

Reparto por tabla:
  Cartera_Total           -> se agrega explicito (PASO 3)
  Cartera_Gestion         -> se agrega desde Cartera_Total_Dedup (PASO 4)
  Cartera_Foto_Ayer       -> hereda sola (SELECT *)
  Cartera_Destiempo_ZOHO  -> hereda sola (auto-reparacion de esquema ya existente)
  Creditos_pagos_CTAYUDA  -> hereda por nombre con el bloque generico nuevo

Uso:
    .venv/Scripts/python.exe aplicar_clasificacion_cartera.py <volcado.sql> <salida.sql>
"""
import sys
import io

# ---------------------------------------------------------------------------------------
# 1) JOIN AL CALENDARIO: una sola fila por cod_periodo (decision 4)
# ---------------------------------------------------------------------------------------
CAL_VIEJO = """        LEFT JOIN (
                SELECT DISTINCT CONVERT(VARCHAR(10), cod_periodo) AS PERIODO,
                        CASE
                                WHEN fec_inicio > CAST(GETDATE() AS DATE)      THEN 'PERIODO NO HA INICIADO'
                                WHEN fec_inicio <= CAST(GETDATE() AS DATE) AND fec_fin >= CAST(GETDATE() AS DATE)  THEN 'ACTIVO'
                                ELSE 'NO ACTIVO'
                        END AS ESTADO
                FROM Dbo.Periodos_Calendario
        ) C ON A.PERIODO = C.PERIODO"""

CAL_NUEVO = """        LEFT JOIN (
                -- UNA fila por cod_periodo. La llave real de Periodos_Calendario es
                -- cod_periodo + descripcion_metod, y 24 codigos tienen fec_fin distinta segun
                -- la modalidad. El SELECT DISTINCT anterior podia devolver DOS filas para el
                -- mismo periodo (el dia que una modalidad cierre y otra no) y MULTIPLICAR las
                -- filas de Cartera_Total. Hoy no pasa -- 0 codigos con ESTADO divergente --,
                -- pero era una bomba de tiempo.
                --
                -- Se colapsa con MIN(fec_inicio) / MAX(fec_fin) por decision de Cartera
                -- (2026-08-26): el periodo esta vigente desde que abre la primera modalidad
                -- hasta que cierra la ultima.
                -- OJO: ese rango envolvente no corresponde a ninguna modalidad concreta.
                SELECT pc.PERIODO,
                        CASE
                                WHEN pc.FEC_INICIO > CAST(GETDATE() AS DATE) THEN 'PERIODO NO HA INICIADO'
                                WHEN pc.FEC_FIN   >= CAST(GETDATE() AS DATE) THEN 'ACTIVO'
                                ELSE 'NO ACTIVO'
                        END AS ESTADO
                FROM (
                        SELECT CONVERT(VARCHAR(10), cod_periodo) AS PERIODO,
                               MIN(fec_inicio) AS FEC_INICIO,
                               MAX(fec_fin)    AS FEC_FIN
                        FROM Dbo.Periodos_Calendario
                        GROUP BY CONVERT(VARCHAR(10), cod_periodo)
                ) pc
        ) C ON A.PERIODO = C.PERIODO"""

# ---------------------------------------------------------------------------------------
# 2) CLASIFICACION_CARTERA en Cartera_Total (antes de AUD_FECHA_PROCESAMIENTO)
# ---------------------------------------------------------------------------------------
CT_VIEJO = """                F.RECAUDO_PAGOS_NOMBRE_FRANQUICIA,
                GETDATE() AS AUD_FECHA_PROCESAMIENTO   -- Marca de auditoría: instante de carga del lote
        INTO Financiera.Cartera_Total"""

CT_NUEVO = """                F.RECAUDO_PAGOS_NOMBRE_FRANQUICIA,
                -- CLASIFICACION_CARTERA: colapso a DOS del mismo C.ESTADO que alimenta la
                -- marca academica. Derivarla de ahi (en vez de re-consultar el calendario)
                -- garantiza que las dos columnas no puedan contradecirse nunca.
                --   CUENTAS POR COBRAR = periodo vigente o aun no iniciado (fec_fin >= hoy)
                --   CARTERA            = periodo academicamente cerrado   (fec_fin <  hoy)
                -- El periodo ausente del calendario (C.ESTADO NULL) cae en CARTERA por
                -- decision de Cartera (2026-08-26): son 25 codigos / 819 obligaciones.
                -- fec_fin = hoy cuenta como VIGENTE, heredando el criterio de C.ESTADO.
                CASE WHEN C.ESTADO IN ('ACTIVO', 'PERIODO NO HA INICIADO')
                     THEN 'CUENTAS POR COBRAR'
                     ELSE 'CARTERA'
                END AS CLASIFICACION_CARTERA,
                GETDATE() AS AUD_FECHA_PROCESAMIENTO   -- Marca de auditoría: instante de carga del lote
        INTO Financiera.Cartera_Total"""

# ---------------------------------------------------------------------------------------
# 3) Cartera_Total_Dedup + Cartera_Gestion
# ---------------------------------------------------------------------------------------
DEDUP_VIEJO = """                RES_PERFIL_RIESGO, RES_SCORE, RECAUDO_PAGOS_NOMBRE_CAJA, RECAUDO_PAGOS_NOMBRE_FRANQUICIA,
                ROW_NUMBER() OVER (PARTITION BY IDENTIFICACION, PERIODO ORDER BY IDENTIFICACION) AS rn"""

DEDUP_NUEVO = """                RES_PERFIL_RIESGO, RES_SCORE, RECAUDO_PAGOS_NOMBRE_CAJA, RECAUDO_PAGOS_NOMBRE_FRANQUICIA,
                CLASIFICACION_CARTERA,
                ROW_NUMBER() OVER (PARTITION BY IDENTIFICACION, PERIODO ORDER BY IDENTIFICACION) AS rn"""

CG_VIEJO = """            CT.RECAUDO_PAGOS_NOMBRE_CAJA, CT.RECAUDO_PAGOS_NOMBRE_FRANQUICIA,
            GETDATE() AS AUD_FECHA_PROCESAMIENTO   -- Marca de auditoría: instante de carga del lote
        INTO Financiera.Cartera_Gestion"""

CG_NUEVO = """            CT.RECAUDO_PAGOS_NOMBRE_CAJA, CT.RECAUDO_PAGOS_NOMBRE_FRANQUICIA,
            CT.CLASIFICACION_CARTERA,   -- CUENTAS POR COBRAR / CARTERA (ver PASO 3)
            GETDATE() AS AUD_FECHA_PROCESAMIENTO   -- Marca de auditoría: instante de carga del lote
        INTO Financiera.Cartera_Gestion"""

# ---------------------------------------------------------------------------------------
# 4) CTAYUDA: herencia generica de columnas (reemplaza el bloque de ~40 ALTER a mano)
#    Se reemplaza desde el comentario "(2) Agregar columnas..." hasta el ultimo ADD (ESTADO).
# ---------------------------------------------------------------------------------------
ADD_INICIO = "            -- (2) Agregar columnas de Cartera_Gestion que falten (filas viejas quedan NULL)\n"
ADD_FIN = ("            IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID("
           "'Financiera.Creditos_pagos_CTAYUDA') AND name='ESTADO')\n"
           "                ALTER TABLE Financiera.Creditos_pagos_CTAYUDA ADD ESTADO varchar(50) NULL;\n")

ADD_NUEVO = """            -- (2) HERENCIA GENERICA de columnas desde Cartera_Gestion.
            --     Antes habia ~40 IF NOT EXISTS ... ALTER TABLE ADD escritos a mano: cada
            --     columna nueva de Cartera_Gestion obligaba a editar tres sitios y, si alguien
            --     lo olvidaba, la columna se perdia en silencio.
            --     Ahora se derivan de sys.columns, igual que hace Cartera_Destiempo_ZOHO.
            --     Excepciones: IDENTIFICACION y TOTAL ya se renombraron arriba a
            --     NUMERO_DOCUMENTO / TOTAL_PAGADO, asi que se excluyen para no duplicarlas.
            DECLARE @cols_add NVARCHAR(MAX);
            SELECT @cols_add = STRING_AGG(CAST(
                    'ALTER TABLE Financiera.Creditos_pagos_CTAYUDA ADD '
                    + QUOTENAME(g.name) + ' '
                    + CASE
                        WHEN t.name IN ('varchar','char') THEN t.name + '('
                             + CASE WHEN g.max_length = -1 THEN 'MAX'
                                    ELSE CAST(g.max_length AS varchar(10)) END + ')'
                        WHEN t.name IN ('nvarchar','nchar') THEN t.name + '('
                             + CASE WHEN g.max_length = -1 THEN 'MAX'
                                    ELSE CAST(g.max_length / 2 AS varchar(10)) END + ')'
                        WHEN t.name IN ('decimal','numeric') THEN t.name + '('
                             + CAST(g.precision AS varchar(10)) + ','
                             + CAST(g.scale AS varchar(10)) + ')'
                        ELSE t.name
                      END
                    + ' NULL;' AS NVARCHAR(MAX)), CHAR(13) + CHAR(10))
            FROM sys.columns g
            JOIN sys.types  t ON t.user_type_id = g.user_type_id
            WHERE g.object_id = OBJECT_ID('Financiera.Cartera_Gestion')
              AND g.name NOT IN ('IDENTIFICACION', 'TOTAL')
              AND NOT EXISTS (SELECT 1 FROM sys.columns c
                              WHERE c.object_id = OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA')
                                AND c.name = g.name);

            IF @cols_add IS NOT NULL
                EXEC sp_executesql @cols_add;
"""

# ---------------------------------------------------------------------------------------
# 5) CTAYUDA: INSERT generico por nombre (reemplaza la lista explicita de ~55 columnas)
# ---------------------------------------------------------------------------------------
INS_INICIO = """            -- Insercion diferida (sp_executesql) tras los ALTER, evita el error 207.
            -- CTAYUDA queda con TODAS las columnas de Cartera_Gestion (foto del credito pagado)
            -- mas ESTADO_CUOTA y FECHA_DETECCION_PAGO (seguimiento de recaudo).
            EXEC sp_executesql N'
            INSERT INTO Financiera.Creditos_pagos_CTAYUDA ("""

INS_NUEVO = """            -- Insercion diferida (sp_executesql) tras los ALTER, evita el error 207.
            --
            -- La lista de columnas se arma por NOMBRE desde la interseccion
            -- Cartera_Foto_Ayer INTERSECT Creditos_pagos_CTAYUDA, no a mano: cualquier columna
            -- nueva de Cartera_Gestion entra sola. Antes eran ~55 nombres repetidos en el
            -- INSERT y en el SELECT, en el mismo orden, mantenidos manualmente.
            --
            -- SEIS casos NO se pueden derivar y van explicitos al final (por eso se excluyen
            -- de la lista generica): dos renombres, una conversion de tipo y tres calculadas.
            --     IDENTIFICACION       -> NUMERO_DOCUMENTO
            --     TOTAL                -> TOTAL_PAGADO
            --     FECHA_VENCIMIENTO    -> TRY_CONVERT(DATETIME, ..., 103)   (varchar -> datetime)
            --     AUD_FECHA_PROCESAMIENTO = GETDATE()
            --     ESTADO_CUOTA            = 'Cuota Cancelada'
            --     FECHA_DETECCION_PAGO    = CAST(GETDATE() AS DATE)
            --
            -- Ambas listas se ordenan por el MISMO column_id, asi que INSERT y SELECT quedan
            -- alineados posicionalmente aunque el orden fisico de las tablas cambie.
            DECLARE @cols_ct NVARCHAR(MAX), @cols_sel NVARCHAR(MAX);
            SELECT @cols_ct  = STRING_AGG(CAST(QUOTENAME(c.name) AS NVARCHAR(MAX)), ', ')
                                   WITHIN GROUP (ORDER BY c.column_id),
                   @cols_sel = STRING_AGG(CAST('Ayer.' + QUOTENAME(c.name) AS NVARCHAR(MAX)), ', ')
                                   WITHIN GROUP (ORDER BY c.column_id)
            FROM sys.columns c
            WHERE c.object_id = OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA')
              AND c.name NOT IN ('NUMERO_DOCUMENTO', 'TOTAL_PAGADO', 'FECHA_VENCIMIENTO',
                                 'AUD_FECHA_PROCESAMIENTO', 'ESTADO_CUOTA', 'FECHA_DETECCION_PAGO')
              AND EXISTS (SELECT 1 FROM sys.columns g
                          WHERE g.object_id = OBJECT_ID('Financiera.Cartera_Foto_Ayer')
                            AND g.name = c.name);

            DECLARE @sql_pagos NVARCHAR(MAX) = N'
            INSERT INTO Financiera.Creditos_pagos_CTAYUDA (' + @cols_ct + N',
                NUMERO_DOCUMENTO,
                TOTAL_PAGADO,
                FECHA_VENCIMIENTO,
                AUD_FECHA_PROCESAMIENTO,
                ESTADO_CUOTA,
                FECHA_DETECCION_PAGO
            )
            SELECT ' + @cols_sel + N',
                Ayer.IDENTIFICACION,
                Ayer.TOTAL,
                TRY_CONVERT(DATETIME, Ayer.FECHA_VENCIMIENTO, 103),
                GETDATE(),
                ''Cuota Cancelada'',
                CAST(GETDATE() AS DATE)
            FROM Financiera.Cartera_Foto_Ayer Ayer
            LEFT JOIN Financiera.Cartera_Gestion Hoy
                ON  Ayer.IDENTIFICACION       = Hoy.IDENTIFICACION
                AND Ayer.PERIODO              = Hoy.PERIODO
                AND Ayer.NUMERO_CREDITO       = Hoy.NUMERO_CREDITO
                AND ISNULL(Ayer.NRO_CUOTA, 0) = ISNULL(Hoy.NRO_CUOTA, 0)
                AND Ayer.FECHA_VENCIMIENTO    = Hoy.FECHA_VENCIMIENTO
                AND Hoy.DOCUMENTO             = ''NDB''
            WHERE Hoy.IDENTIFICACION IS NULL
              AND NOT EXISTS (
                  SELECT 1
                  FROM Financiera.Creditos_pagos_CTAYUDA H
                  WHERE H.FECHA_DETECCION_PAGO    = CAST(GETDATE() AS DATE)
                    AND H.NUMERO_DOCUMENTO        = Ayer.IDENTIFICACION
                    AND H.PERIODO                 = Ayer.PERIODO
                    AND H.NUMERO_CREDITO          = Ayer.NUMERO_CREDITO
                    AND ISNULL(H.NRO_CUOTA, 0)    = ISNULL(Ayer.NRO_CUOTA, 0)
                    AND H.FECHA_VENCIMIENTO       = TRY_CONVERT(DATETIME, Ayer.FECHA_VENCIMIENTO, 103)
              );';

            EXEC sp_executesql @sql_pagos;
"""


def corta(sql, inicio, fin, etiqueta):
    """Reemplaza el tramo [inicio .. fin] inclusive. Aborta si no es unico."""
    i = sql.find(inicio)
    if i == -1 or sql.count(inicio) != 1:
        raise ValueError("%s: no encontre un unico inicio de bloque" % etiqueta)
    j = sql.find(fin, i)
    if j == -1:
        raise ValueError("%s: no encontre el fin del bloque" % etiqueta)
    return sql[:i], sql[j + len(fin):]


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(2)
    origen, destino = sys.argv[1], sys.argv[2]

    with io.open(origen, "r", encoding="utf-8") as fh:
        sql = fh.read()

    simples = [
        ("join al calendario (MIN/MAX por cod_periodo)", CAL_VIEJO, CAL_NUEVO),
        ("CLASIFICACION_CARTERA en Cartera_Total", CT_VIEJO, CT_NUEVO),
        ("CLASIFICACION_CARTERA en Cartera_Total_Dedup", DEDUP_VIEJO, DEDUP_NUEVO),
        ("CLASIFICACION_CARTERA en Cartera_Gestion", CG_VIEJO, CG_NUEVO),
    ]
    for etiqueta, viejo, nuevo in simples:
        n = sql.count(viejo)
        if n != 1:
            print("ABORTADO - %s: esperaba 1 ocurrencia, encontre %d" % (etiqueta, n))
            sys.exit(1)
        sql = sql.replace(viejo, nuevo, 1)
        print("  OK  %s" % etiqueta)

    try:
        pre, post = corta(sql, ADD_INICIO, ADD_FIN, "bloque de ~40 ALTER TABLE ADD")
        sql = pre + ADD_NUEVO + post
        print("  OK  CTAYUDA hereda columnas por nombre (fuera ~40 ALTER a mano)")

        # El INSERT explicito va desde su comentario hasta el cierre del sp_executesql.
        pre, post = corta(sql, INS_INICIO, "              );';\n", "INSERT explicito de CTAYUDA")
        sql = pre + INS_NUEVO + post
        print("  OK  CTAYUDA: INSERT generico por nombre")
    except ValueError as e:
        print("ABORTADO - %s" % e)
        sys.exit(1)

    # ---- Verificaciones de cierre -------------------------------------------------
    errores = []
    if sql.count("CLASIFICACION_CARTERA") < 4:
        errores.append("faltan referencias a CLASIFICACION_CARTERA (%d)" % sql.count("CLASIFICACION_CARTERA"))
    if "SELECT DISTINCT CONVERT(VARCHAR(10), cod_periodo)" in sql:
        errores.append("quedo el SELECT DISTINCT viejo del calendario")
    if sql.count("ALTER TABLE Financiera.Creditos_pagos_CTAYUDA ADD ") > 1:
        errores.append("quedaron ALTER TABLE ADD a mano sobre CTAYUDA (%d)"
                       % sql.count("ALTER TABLE Financiera.Creditos_pagos_CTAYUDA ADD "))
    # AUD_FECHA_PROCESAMIENTO debe seguir siendo la ultima columna de ambos SELECT INTO
    for tabla in ("Cartera_Total", "Cartera_Gestion"):
        marca = "GETDATE() AS AUD_FECHA_PROCESAMIENTO   -- Marca de auditoría: instante de carga del lote\n        INTO Financiera." + tabla
        if marca not in sql:
            errores.append("AUD_FECHA_PROCESAMIENTO dejo de ser la ultima columna de %s" % tabla)

    if errores:
        print("\nABORTADO. No se escribio nada:")
        for e in errores:
            print("   - %s" % e)
        sys.exit(1)
    print("  OK  AUD_FECHA_PROCESAMIENTO sigue al final en ambas tablas")

    with io.open(destino, "w", encoding="utf-8") as fh:
        fh.write(sql)
    print("\nEscrito: %s  (%d chars)" % (destino, len(sql)))


if __name__ == "__main__":
    main()
