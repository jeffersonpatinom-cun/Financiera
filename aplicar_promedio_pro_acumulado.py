# -*- coding: utf-8 -*-
"""
Unifica la fuente de PROMEDIO en SP_Cartera_Total y la hace coherente con MARCA_ACADEMICA.

Contexto (2026-08-26, aprobado por Coordinacion de Cartera):
  * Hoy conviven DOS promedios distintos dentro del mismo SP:
      - columna PROMEDIO de Cartera_Gestion  <- #PROM <- sinu.V_DEMOGRAFICO_ESTUDIANTE_VIG
                                                        filtrada ESTADO_PAGO='PAGO'
      - MARCA_ACADEMICA                      <- COALESCE(B.PROMEDIO, E.PROMEDIO)
                                                = CUN.ESTADISTICA_ESTUDIANTE_2 / ESTADISTICA_ACADEMICA
    Resultado: filas marcadas GESTIONABLE con la columna PROMEDIO vacia, y viceversa.
  * Fuente unica aprobada: SINU.SRC_HIS_ACADEMICA + SRC_ALUM_PERIODO, campo PRO_ACUMULADO,
    cruzada SOLO por identificacion.

Efecto medido (read-only, 259.571 filas):
  * Cobertura de PROMEDIO: 42,78% -> 81,03% (111.041 -> 210.333 obligaciones).
  * 25.259 obligaciones (9,73%) cambian de MARCA_ACADEMICA.

NO cambia nombres de columnas (PROMEDIO, ultimoaccesoplataformlimpio): Zoho CRM los consume.
NO toca la fuente de Moodle: ya era CUN_STAGE.moodle.repli_mdl_user, la misma que valido Cartera.

Uso:
    .venv/Scripts/python.exe aplicar_promedio_pro_acumulado.py <sp_volcado.sql> <salida.sql>
"""
import sys
import io

# ---------------------------------------------------------------------------------------
# Bloque nuevo: #PROM se construye ANTES de Cartera_Total (como ya se hizo con #MOODLE),
# porque ahora la MARCA_ACADEMICA lo consume.
# ---------------------------------------------------------------------------------------
BLOQUE_PROM = """
        -- ─────────────────────────────────────────────────────────────────────────────────────────
        -- #PROM (movido aquí desde el PASO 4): PROMEDIO ACUMULADO por IDENTIFICACION.
        --   Fuente única aprobada por Coordinación de Cartera (2026-08-26):
        --   SINU.SRC_HIS_ACADEMICA + SRC_ALUM_PERIODO, campo PRO_ACUMULADO.
        --
        --   Reemplaza a sinu.V_DEMOGRAFICO_ESTUDIANTE_VIG, que filtraba ESTADO_PAGO='PAGO' y
        --   solo cubría el 42,78% de las obligaciones. La fuente nueva cubre 81,03%.
        --   Se construye AQUÍ (antes de Cartera_Total) porque MARCA_ACADEMICA ahora lo consume:
        --   antes la marca usaba COALESCE(B.PROMEDIO, E.PROMEDIO) — un promedio DISTINTO del que
        --   la tabla mostraba — y eso producía filas GESTIONABLE con la columna PROMEDIO vacía.
        --
        --   ⚠ La llave es SOLO IDENTIFICACION, sin PERIODO. PRO_ACUMULADO es el promedio
        --     acumulado del estudiante, no la nota de un periodo: una obligación de 2022 queda
        --     evaluada con el acumulado vigente. Es la regla que definió Cartera, no un descuido.
        --
        --   Desempate (5,3 filas por estudiante en promedio):
        --     1) semestre (NUM_NIV_CURSA) más avanzado = el acumulado más completo;
        --     2) fec_inicio real del periodo (Periodos_Calendario), porque el 47% empata en
        --        semestre y COD_PERIODO NO es ordenable: sus 2 últimos caracteres son la
        --        iteración de la modalidad, no el periodo del año (26I17 es ANTERIOR a 26V05),
        --        y el 45% de las filas ni siquiera los tiene numéricos (26PI3, 2026C, 017E1);
        --     3) PRO_ACUMULADO desc como último recurso, para que el resultado sea determinista.
        -- ─────────────────────────────────────────────────────────────────────────────────────────
        IF OBJECT_ID('tempdb..#PROM') IS NOT NULL DROP TABLE #PROM;
        SELECT id_k, PROMEDIO
        INTO #PROM
        FROM (
            SELECT LTRIM(RTRIM(SRC.num_identificacion))              AS id_k,
                   TRY_CAST(SRC.PRO_ACUMULADO AS DECIMAL(9,4))       AS PROMEDIO,
                   ROW_NUMBER() OVER (
                        PARTITION BY LTRIM(RTRIM(SRC.num_identificacion))
                        ORDER BY TRY_CAST(SRC.semestre AS INT)             DESC,
                                 CAL.fec_inicio                            DESC,
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
            -- Fecha real del periodo. La llave de Periodos_Calendario es cod_periodo +
            -- descripcion_metod, así que se colapsa con MAX(fec_inicio) por cod_periodo para
            -- no multiplicar filas del lado académico.
            LEFT JOIN (
                SELECT LTRIM(RTRIM(cod_periodo)) AS cod_periodo, MAX(fec_inicio) AS fec_inicio
                FROM Dbo.Periodos_Calendario
                GROUP BY LTRIM(RTRIM(cod_periodo))
            ) CAL ON CAL.cod_periodo = LTRIM(RTRIM(SRC.COD_PERIODO))
        ) z WHERE rn = 1;
        CREATE CLUSTERED INDEX IX_prom ON #PROM(id_k);
"""

# ---------------------------------------------------------------------------------------
# Reemplazos: (etiqueta, texto_viejo, texto_nuevo, ocurrencias_esperadas)
# ---------------------------------------------------------------------------------------
ANCLA_MOODLE = "        CREATE CLUSTERED INDEX IX_moodle ON #MOODLE(id_k);\n"

VIEJO_PROM_PASO4 = """        IF OBJECT_ID('tempdb..#PROM') IS NOT NULL DROP TABLE #PROM;
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

NUEVO_PROM_PASO4 = """        -- #PROM ya se construyó en el PASO 3 (antes de Cartera_Total), porque MARCA_ACADEMICA
        -- lo consume. Persiste en tempdb todo el batch; aquí solo se reutiliza en el JOIN de
        -- Cartera_Gestion. No se reconstruye. Ver el bloque #PROM del PASO 3.
"""

REEMPLAZOS = [
    # 1) Cartera_Total: la columna PROMEDIO pasa a la fuente unica.
    (
        "columna PROMEDIO de Cartera_Total",
        "                COALESCE(B.PROMEDIO, E.PROMEDIO)                            AS PROMEDIO,",
        "                P.PROMEDIO                                                  AS PROMEDIO,",
        1,
    ),
    # 2) Escalera de MARCA_ACADEMICA: misma fuente que la columna (esto es la coherencia).
    (
        "escalera MARCA_ACADEMICA < 1.55",
        "                        WHEN COALESCE(B.PROMEDIO, E.PROMEDIO) <  1.55  THEN 'SIN REGISTRO DE CLASE'",
        "                        WHEN P.PROMEDIO <  1.55                    THEN 'SIN REGISTRO DE CLASE'",
        1,
    ),
    (
        "escalera MARCA_ACADEMICA < 3.0",
        "                        WHEN COALESCE(B.PROMEDIO, E.PROMEDIO) <  3.0   THEN 'PERIODO PERDIDO, PRIORIDAD ALTA'",
        "                        WHEN P.PROMEDIO <  3.0                     THEN 'PERIODO PERDIDO, PRIORIDAD ALTA'",
        1,
    ),
    (
        "escalera MARCA_ACADEMICA >= 3.0",
        "                        WHEN COALESCE(B.PROMEDIO, E.PROMEDIO) >= 3.0   THEN 'GESTIONABLE'",
        "                        WHEN P.PROMEDIO >= 3.0                     THEN 'GESTIONABLE'",
        1,
    ),
    # 3) JOIN de #PROM en Cartera_Total (solo por identificacion).
    (
        "JOIN #PROM en Cartera_Total",
        """        LEFT JOIN #MOODLE M
                ON M.id_k = LTRIM(RTRIM(CONVERT(VARCHAR(50), A.IDENTIFICACION)))
        LEFT JOIN CTAYUDA_RIESGO F""",
        """        LEFT JOIN #MOODLE M
                ON M.id_k = LTRIM(RTRIM(CONVERT(VARCHAR(50), A.IDENTIFICACION)))
        -- PROMEDIO ACUMULADO: llave SOLO identificacion (PRO_ACUMULADO no es por periodo).
        LEFT JOIN #PROM P
                ON P.id_k = LTRIM(RTRIM(CONVERT(VARCHAR(50), A.IDENTIFICACION)))
        LEFT JOIN CTAYUDA_RIESGO F""",
        1,
    ),
    # 4) Cartera_Gestion: el JOIN pierde el PERIODO.
    (
        "JOIN #PROM en Cartera_Gestion",
        """        LEFT JOIN #PROM P
            ON P.COD_PERIODO = C.PERIODO
            AND P.id_k       = LTRIM(RTRIM(CONVERT(VARCHAR(50), C.IDENTIFICACION)))""",
        """        LEFT JOIN #PROM P
            ON P.id_k = LTRIM(RTRIM(CONVERT(VARCHAR(50), C.IDENTIFICACION)))""",
        1,
    ),
    # 5) Comentario de cabecera de la columna en Cartera_Gestion.
    (
        "comentario columna PROMEDIO en Cartera_Gestion",
        "            P.PROMEDIO AS PROMEDIO,                          -- fuente viva: V_DEMOGRAFICO_ESTUDIANTE_VIG",
        "            P.PROMEDIO AS PROMEDIO,                          -- fuente unica: SRC_ALUM_PERIODO.PRO_ACUMULADO",
        1,
    ),
    # 6) Documentacion del encabezado del SP.
    (
        "encabezado: fuente de promedio",
        "--   · [172.16.1.175] sinu.V_DEMOGRAFICO_ESTUDIANTE_VIG : promedio de notas (ESTADO_PAGO='PAGO') vía OPENQUERY",
        "--   · [172.16.1.175] SINU.SRC_HIS_ACADEMICA + SRC_ALUM_PERIODO : PRO_ACUMULADO vía OPENQUERY (llave: solo identificación)",
        1,
    ),
    (
        "encabezado: diagrama de flujo",
        "--             │        · PROMEDIO ← OPENQUERY sinu.V_DEMOGRAFICO_ESTUDIANTE_VIG",
        "--             │        · PROMEDIO ← OPENQUERY SRC_ALUM_PERIODO.PRO_ACUMULADO (solo identificación)",
        1,
    ),
    (
        "comentario PASO 4: fuente de #PROM",
        """        --   · #PROM   : promedio de notas vía OPENQUERY 172.16.1.175
        --               sinu.V_DEMOGRAFICO_ESTUDIANTE_VIG (ESTADO_PAGO='PAGO'),
        --               deduplicado por COD_PERIODO + NUM_IDENTIFICACION.""",
        """        --   · #PROM   : promedio ACUMULADO vía OPENQUERY 172.16.1.175
        --               SINU.SRC_HIS_ACADEMICA + SRC_ALUM_PERIODO (PRO_ACUMULADO),
        --               deduplicado por NUM_IDENTIFICACION -- SIN periodo en la llave.""",
        1,
    ),
    # 7) Mover la construccion de #PROM al PASO 3.
    ("quitar #PROM del PASO 4", VIEJO_PROM_PASO4, NUEVO_PROM_PASO4, 1),
]


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(2)
    origen, destino = sys.argv[1], sys.argv[2]

    with io.open(origen, "r", encoding="utf-8") as fh:
        sql = fh.read()

    errores = []

    # Insercion del bloque #PROM justo despues del indice de #MOODLE.
    n = sql.count(ANCLA_MOODLE)
    if n != 1:
        errores.append("ancla #MOODLE: esperaba 1 ocurrencia, encontre %d" % n)
    else:
        sql = sql.replace(ANCLA_MOODLE, ANCLA_MOODLE + BLOQUE_PROM, 1)
        print("  OK  insertado bloque #PROM despues de IX_moodle")

    for etiqueta, viejo, nuevo, esperadas in REEMPLAZOS:
        n = sql.count(viejo)
        if n != esperadas:
            errores.append("%s: esperaba %d ocurrencia(s), encontre %d" % (etiqueta, esperadas, n))
            continue
        sql = sql.replace(viejo, nuevo, esperadas)
        print("  OK  %s" % etiqueta)

    # Verificaciones de cierre: no debe quedar rastro de la fuente vieja EN CODIGO.
    # Las lineas de comentario se ignoran: la documentacion nueva menciona la fuente vieja
    # a proposito, para dejar registro de que se reemplazo y por que.
    for pat in ("V_DEMOGRAFICO_ESTUDIANTE_VIG", "COALESCE(B.PROMEDIO, E.PROMEDIO)"):
        restantes = [(i, l) for i, l in enumerate(sql.split("\n"), 1)
                     if pat in l and not l.strip().startswith("--")]
        if restantes:
            errores.append("quedaron %d referencia(s) a %s:" % (len(restantes), pat))
            for i, l in restantes:
                errores.append("       linea %d: %s" % (i, l.strip()[:110]))
    if sql.count("INTO #PROM") != 1:
        errores.append("se esperaba exactamente un 'INTO #PROM', hay %d" % sql.count("INTO #PROM"))

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
