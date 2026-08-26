# -*- coding: utf-8 -*-
"""
Alinea USP_Foto_Meta_Comercial_Mensual con la fuente unica de PROMEDIO.

Este SP recalcula su PROPIA MARCA_ACADEMICA y la escribe en
Financiera.Cartera_Meta_Comercial_Historico. Tenia exactamente la misma incoherencia
que SP_Cartera_Total: mostraba Promedio_notas de una fuente (V_DEMOGRAFICO) y calculaba
la marca con otra (COALESCE(B.PROMEDIO, E.PROMEDIO) = ESTADISTICA). Si no se alinea,
quedan dos MARCA_ACADEMICA distintas conviviendo en el ecosistema.

Cambios (espejo de aplicar_promedio_pro_acumulado.py):
  1. #PROM pasa a SRC_ALUM_PERIODO.PRO_ACUMULADO, llave SOLO identificacion.
  2. La escalera de MARCA_ACADEMICA consume ese mismo #PROM.
  3. #MOODLE gana el NULLIF(lastaccess, 0) que este SP no tenia: sin el, "nunca ingreso"
     (lastaccess = 0) se convertia en 1970-01-01, una fecha valida que la rama de
     Moodle-90d leia como "sin acceso reciente" por casualidad, no por diseno.

NO cambia nombres de columnas: Promedio_notas y Ultimo_acceso_moodle se conservan.

Uso:
    .venv/Scripts/python.exe aplicar_promedio_pro_acumulado_meta.py <volcado.sql> <salida.sql>
"""
import sys
import io

NUEVO_PROM = """        -- ------------------------------------------------------------------
        -- #PROM: PROMEDIO ACUMULADO por IDENTIFICACION.
        --   Fuente unica aprobada por Coordinacion de Cartera (2026-08-26):
        --   SINU.SRC_HIS_ACADEMICA + SRC_ALUM_PERIODO, campo PRO_ACUMULADO.
        --   Identica a la de [Financiera].[SP_Cartera_Total]: ambos SP deben producir
        --   la MISMA MARCA_ACADEMICA, y para eso deben leer el MISMO promedio.
        --
        --   Reemplaza a sinu.V_DEMOGRAFICO_ESTUDIANTE_VIG (filtraba ESTADO_PAGO='PAGO',
        --   cobertura 42,78% -> 81,03% con la fuente nueva).
        --
        --   La llave es SOLO IDENTIFICACION: PRO_ACUMULADO es el acumulado del
        --   estudiante, no la nota de un periodo.
        --   Desempate: semestre mas avanzado -> fec_inicio real del periodo -> promedio.
        --   COD_PERIODO no sirve para ordenar (sus 2 ultimos caracteres son la iteracion
        --   de la modalidad, no el periodo del anio: 26I17 es ANTERIOR a 26V05).
        -- ------------------------------------------------------------------
        IF OBJECT_ID('tempdb..#PROM') IS NOT NULL DROP TABLE #PROM;
        SELECT id_k, PROMEDIO
        INTO #PROM
        FROM (
            SELECT LTRIM(RTRIM(SRC.num_identificacion))                AS id_k,
                   TRY_CAST(SRC.PRO_ACUMULADO AS DECIMAL(9,4))         AS PROMEDIO,
                   ROW_NUMBER() OVER (
                        PARTITION BY LTRIM(RTRIM(SRC.num_identificacion))
                        ORDER BY TRY_CAST(SRC.semestre AS INT)               DESC,
                                 CAL.fec_inicio                              DESC,
                                 TRY_CAST(SRC.PRO_ACUMULADO AS DECIMAL(9,4)) DESC
                   ) AS rn
            FROM OPENQUERY([172.16.1.175],
                'select DISTINCT C.num_identificacion, A.COD_PERIODO,
                        AP.PRO_ACUMULADO, AP.NUM_NIV_CURSA as semestre
                 from SINU.SRC_HIS_ACADEMICA A
                 INNER JOIN sinu.SRC_ALUM_PROGRAMA B ON A.ID_ALUM_PROGRAMA = B.ID_ALUM_PROGRAMA
                 INNER JOIN SINU.SRC_ALUM_PERIODO AP ON A.ID_ALUM_PROGRAMA = AP.ID_ALUM_PROGRAMA
                                                    AND AP.COD_PERIODO = A.COD_PERIODO
                 INNER JOIN src_enc_matricula M ON M.id_alum_programa = B.id_alum_programa
                                               AND M.cod_periodo = A.cod_periodo
                 INNER JOIN sinu.BAS_TERCERO C ON B.ID_TERCERO = C.ID_TERCERO
                 INNER JOIN SRC_UNI_ACADEMICA E ON E.COD_UNIDAD = B.COD_UNIDAD
                 INNER JOIN bas_dependencia dep ON dep.id_dependencia = E.id_dependencia
                 INNER JOIN SRC_GENERICA D ON D.TIP_TABLA = B.COD_EST_ALUMNO
                                          AND D.COD_TABLA = B.EST_ALUMNO
                 INNER JOIN SRC_GENERICA F ON F.TIP_TABLA = E.COD_NIVEL_FOR
                                          AND F.COD_TABLA = E.NIV_FORMACION') SRC
            LEFT JOIN (
                SELECT LTRIM(RTRIM(cod_periodo)) AS cod_periodo, MAX(fec_inicio) AS fec_inicio
                FROM Dbo.Periodos_Calendario
                GROUP BY LTRIM(RTRIM(cod_periodo))
            ) CAL ON CAL.cod_periodo = LTRIM(RTRIM(SRC.COD_PERIODO))
        ) z WHERE rn = 1;
        CREATE CLUSTERED INDEX IX_prom ON #PROM(id_k);
"""

VIEJO_PROM = """        IF OBJECT_ID('tempdb..#PROM') IS NOT NULL DROP TABLE #PROM;
        SELECT COD_PERIODO, id_k, PROMEDIO
        INTO #PROM
        FROM (
            SELECT COD_PERIODO, LTRIM(RTRIM(NUM_IDENTIFICACION)) AS id_k, PROMEDIO,
                   ROW_NUMBER() OVER (PARTITION BY COD_PERIODO, LTRIM(RTRIM(NUM_IDENTIFICACION))
                                      ORDER BY (SELECT 1)) AS rn
            FROM OPENQUERY([172.16.1.175],
                'select NUM_IDENTIFICACION,COD_PERIODO,PROMEDIO
                 from sinu.V_DEMOGRAFICO_ESTUDIANTE_VIG
                 where ESTADO_PAGO = ''PAGO''')
        ) z WHERE rn = 1;
        CREATE CLUSTERED INDEX IX_prom ON #PROM(COD_PERIODO, id_k);
"""

REEMPLAZOS = [
    ("bloque #PROM", VIEJO_PROM, NUEVO_PROM, 1),
    (
        "fix NULLIF(lastaccess,0) en #MOODLE",
        "                   DATEADD(SECOND, lastaccess, '1970-01-01') AS Ultimo_acceso_moodle,",
        "                   -- NULLIF: lastaccess = 0 en Moodle es \"nunca ingreso\", no 1970-01-01.\n"
        "                   DATEADD(SECOND, NULLIF(lastaccess, 0), '1970-01-01') AS Ultimo_acceso_moodle,",
        1,
    ),
    (
        "JOIN #PROM (solo identificacion)",
        """        LEFT JOIN #PROM   P ON P.COD_PERIODO = S.PERIODO
                           AND P.id_k        = LTRIM(RTRIM(S.IDENTIFICACION))""",
        """        -- PROMEDIO ACUMULADO: llave SOLO identificacion (PRO_ACUMULADO no es por periodo).
        LEFT JOIN #PROM   P ON P.id_k = LTRIM(RTRIM(S.IDENTIFICACION))""",
        1,
    ),
    (
        "escalera < 1.55",
        "                WHEN COALESCE(B.PROMEDIO, E.PROMEDIO) <  1.55 THEN 'SIN REGISTRO DE CLASE'",
        "                WHEN P.PROMEDIO <  1.55                   THEN 'SIN REGISTRO DE CLASE'",
        1,
    ),
    (
        "escalera < 3.0",
        "                WHEN COALESCE(B.PROMEDIO, E.PROMEDIO) <  3.0  THEN 'PERIODO PERDIDO, PRIORIDAD ALTA'",
        "                WHEN P.PROMEDIO <  3.0                    THEN 'PERIODO PERDIDO, PRIORIDAD ALTA'",
        1,
    ),
    (
        "escalera >= 3.0",
        "                WHEN COALESCE(B.PROMEDIO, E.PROMEDIO) >= 3.0  THEN 'GESTIONABLE'",
        "                WHEN P.PROMEDIO >= 3.0                    THEN 'GESTIONABLE'",
        1,
    ),
    (
        "encabezado: fuente de Promedio_notas",
        """         * Promedio_notas       : OPENQUERY 172.16.1.175 sinu.V_DEMOGRAFICO_ESTUDIANTE_VIG
                                  (COD_PERIODO + NUM_IDENTIFICACION) -> PROMEDIO.""",
        """         * Promedio_notas       : OPENQUERY 172.16.1.175 SINU.SRC_HIS_ACADEMICA +
                                  SRC_ALUM_PERIODO -> PRO_ACUMULADO (llave: SOLO
                                  NUM_IDENTIFICACION; es acumulado, no por periodo).""",
        1,
    ),
    (
        "encabezado: origen de la marca",
        "                                  deriva del estado del periodo (Dbo.Periodos_Calendario) y el\n"
        "                                  PROMEDIO de ESTADISTICA_ESTUDIANTE_2. SE REFRESCAN cada mes.",
        "                                  deriva del estado del periodo (Dbo.Periodos_Calendario) y el\n"
        "                                  MISMO PROMEDIO que se muestra en Promedio_notas (PRO_ACUMULADO),\n"
        "                                  no de ESTADISTICA_ESTUDIANTE_2. SE REFRESCAN cada mes.",
        1,
    ),
]


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(2)
    origen, destino = sys.argv[1], sys.argv[2]

    with io.open(origen, "r", encoding="utf-8") as fh:
        sql = fh.read()

    errores = []
    for etiqueta, viejo, nuevo, esperadas in REEMPLAZOS:
        n = sql.count(viejo)
        if n != esperadas:
            errores.append("%s: esperaba %d, encontre %d" % (etiqueta, esperadas, n))
            continue
        sql = sql.replace(viejo, nuevo, esperadas)
        print("  OK  %s" % etiqueta)

    # Sin rastros de la fuente vieja EN CODIGO (los comentarios pueden mencionarla).
    for pat in ("V_DEMOGRAFICO_ESTUDIANTE_VIG", "COALESCE(B.PROMEDIO, E.PROMEDIO)"):
        restantes = [(i, l) for i, l in enumerate(sql.split("\n"), 1)
                     if pat in l and not l.strip().startswith("--")]
        if restantes:
            errores.append("quedaron %d referencia(s) en codigo a %s:" % (len(restantes), pat))
            for i, l in restantes:
                errores.append("       linea %d: %s" % (i, l.strip()[:110]))

    if errores:
        print("\nABORTADO. No se escribio nada:")
        for e in errores:
            print("   - %s" % e)
        sys.exit(1)

    with io.open(destino, "w", encoding="utf-8") as fh:
        fh.write(sql)
    print("\nEscrito: %s  (%d chars)" % (destino, len(sql)))


if __name__ == "__main__":
    main()
