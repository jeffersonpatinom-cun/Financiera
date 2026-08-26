# -*- coding: utf-8 -*-
"""
Segundo cruce academico por CEDULA SOLA + escalera de ciclo corregida y homologada.

PROBLEMA
--------
El bloque academico (NOM_UNIDAD / CICLO / ESTADO_ALUMNO / MODALIDAD / NOM_SECCIONAL / NUEVO)
se llena con LEFT JOIN por IDENTIFICACION + PERIODO contra tres fuentes. Cuando ese par no
cruza, las seis columnas quedan vacias: 1.372 clientes / 3.400 obligaciones / $855 MM.

SOLUCION (aprobada por Cartera, 2026-08-26)
-------------------------------------------
Cuarta fuente #ACAD_CEDULA: mismo dato cruzado SOLO por identificacion, una fila por
persona, elegida por el nivel de ciclo mas alto. Entra al final del COALESCE, asi que
NUNCA pisa un dato que ya cruzo por id+periodo: solo rellena huecos.

Impacto medido (read-only, sobre la corrida del 2026-08-26 14:12):
    Hueco            1.372 clientes / 3.400 obligaciones / $855 MM
    Se recupera      1.199 clientes (87%) / 2.461 obligaciones (72%) / $453 MM
    Sin rescate        173 clientes -> conservan la marca

ESCALERA DE CICLO
-----------------
    1 Especializacion  2 Profesional  3 Tecnologo  4 Tecnico Profesional
    5 Modulos / Diplomado / Curso de Extension / Universitaria
    6 vacio (siempre pierde contra cualquier nivel real)

Dos correcciones que venian de antes:

  a) La escalera vieja era 'Profesional'=1, 'Tecnologo'=2, 'Tecnico Profesional'=3,
     ELSE 99. Especializacion caia en el 99, es decir POR DEBAJO de Tecnico. Corregido.

  b) ESTADISTICA_ACADEMICA usa OTRO vocabulario: TECNICO / PROFESIONAL / TECNOLOGO, contra
     Tecnico Profesional / Profesional / Tecnologo de las otras dos. Con comparacion
     literal, sus 785k filas caian todas al bucket "resto". Se compara con collation
     CI_AI (case- y accent-insensitive) + LIKE, que absorbe ambos vocabularios sin
     mantener listas literales.

  c) Homologacion de salida: TECNICO -> Tecnico Profesional, TECNOLOGO -> Tecnologo,
     PROFESIONAL -> Profesional. Se aplica en el CTE de la fuente, asi que corrige tambien
     el camino normal por id+periodo: hoy hay 71 obligaciones en produccion escritas con la
     ortografia cruda, que partian en dos cualquier conteo por ciclo.

NULLIF en el COALESCE: las fuentes traen cadenas vacias, no solo NULL. Un COALESCE pelado
daba por bueno un '' de la primera fuente y nunca consultaba las siguientes. Se envuelve
cada termino en NULLIF(LTRIM(RTRIM(x)),'') para que el fallback dispare de verdad.

Uso:
    .venv/Scripts/python.exe aplicar_fallback_academico_cedula.py <volcado.sql> <salida.sql>
"""
import sys
import io

# Escalera reutilizable. %s se sustituye por la expresion del ciclo.
ESCALERA = """CASE
                        WHEN UPPER(LTRIM(RTRIM(ISNULL(%(c)s,'')))) COLLATE Latin1_General_CI_AI LIKE 'ESPECIALIZACION%%' THEN 1
                        WHEN UPPER(LTRIM(RTRIM(ISNULL(%(c)s,'')))) COLLATE Latin1_General_CI_AI LIKE 'PROFESIONAL%%'     THEN 2
                        WHEN UPPER(LTRIM(RTRIM(ISNULL(%(c)s,'')))) COLLATE Latin1_General_CI_AI LIKE 'TECNOLOGO%%'       THEN 3
                        WHEN UPPER(LTRIM(RTRIM(ISNULL(%(c)s,'')))) COLLATE Latin1_General_CI_AI LIKE 'TECNICO%%'         THEN 4
                        WHEN NULLIF(LTRIM(RTRIM(ISNULL(%(c)s,''))),'') IS NULL                                          THEN 6
                        ELSE 5
                   END"""

# Homologacion de la ortografia del ciclo.
HOMOLOGA = """CASE
                        WHEN UPPER(LTRIM(RTRIM(ISNULL(%(c)s,'')))) COLLATE Latin1_General_CI_AI LIKE 'ESPECIALIZACION%%' THEN 'Especializacion'
                        WHEN UPPER(LTRIM(RTRIM(ISNULL(%(c)s,'')))) COLLATE Latin1_General_CI_AI LIKE 'PROFESIONAL%%'     THEN 'Profesional'
                        WHEN UPPER(LTRIM(RTRIM(ISNULL(%(c)s,'')))) COLLATE Latin1_General_CI_AI LIKE 'TECNOLOGO%%'       THEN 'Tecn' + CHAR(243) + 'logo'
                        WHEN UPPER(LTRIM(RTRIM(ISNULL(%(c)s,'')))) COLLATE Latin1_General_CI_AI LIKE 'TECNICO%%'         THEN 'T' + CHAR(233) + 'cnico Profesional'
                        ELSE %(c)s
                   END"""

BLOQUE_FALLBACK = """
        -- ─────────────────────────────────────────────────────────────────────────────────────────
        -- #ACAD_CEDULA — 2do cruce academico, SOLO por identificacion (aprobado 2026-08-26).
        --
        --   Cuando el par IDENTIFICACION + PERIODO no cruza contra ninguna de las tres fuentes,
        --   las seis columnas academicas quedan vacias: 1.372 clientes / 3.400 obligaciones /
        --   $855 MM en la corrida del 26-ago. Esta tabla recupera 1.199 de esos clientes (87%),
        --   2.461 obligaciones, $453 MM. Los 173 restantes no existen en NINGUNA fuente ni por
        --   cedula: conservan la marca, como se acordo.
        --
        --   Entra como ULTIMO termino del COALESCE, asi que jamas pisa un dato que si cruzo
        --   por id+periodo. Solo rellena huecos.
        --
        --   UNA fila por persona. Desempate:
        --     1) nivel de ciclo mas alto  (Especializacion > Profesional > Tecnologo >
        --        Tecnico Profesional > Modulos/Diplomado/Curso/Universitaria > vacio)
        --     2) fuente mas confiable     (ESTADISTICA_ESTUDIANTE_2 > Zoho > ESTADISTICA_ACADEMICA)
        --     3) COD_PERIODO mas reciente
        --   El desempate NO es un detalle de borde: 372 de los 1.199 clientes tienen mas de
        --   20 filas candidatas y solo 52 tienen una sola.
        --
        --   Se exige NOM_UNIDAD no vacio para no elegir un candidato hueco. El CICLO vacio se
        --   admite pero ordena ultimo: 3 clientes quedaran con NOM_UNIDAD lleno y CICLO vacio,
        --   por decision de Cartera (rellenar lo que haya).
        -- ─────────────────────────────────────────────────────────────────────────────────────────
        IF OBJECT_ID('tempdb..#ACAD_CEDULA') IS NOT NULL DROP TABLE #ACAD_CEDULA;
        SELECT id_k, NOM_UNIDAD, NOM_SECCIONAL, MODALIDAD, CICLO, ESTADO_ALUMNO, NUEVO
        INTO #ACAD_CEDULA
        FROM (
            SELECT S.*,
                   ROW_NUMBER() OVER (
                        PARTITION BY S.id_k
                        ORDER BY S.ORDEN_CICLO ASC, S.ORDEN_FUENTE ASC, S.COD_PERIODO DESC
                   ) AS rn
            FROM (
                -- Fuente 1: ESTADISTICA_ESTUDIANTE_2
                SELECT CAST(LTRIM(RTRIM(NUM_IDENTIFICACION)) AS VARCHAR(50)) AS id_k,
                       CAST(NOM_UNIDAD    AS VARCHAR(200)) AS NOM_UNIDAD,
                       CAST(NOM_SECCIONAL AS VARCHAR(100)) AS NOM_SECCIONAL,
                       CAST(MODALIDAD     AS VARCHAR(100)) AS MODALIDAD,
                       CAST(__HOMOLOGA_B__ AS VARCHAR(60)) AS CICLO,
                       CAST(ESTADO_ALUMNO AS VARCHAR(60))  AS ESTADO_ALUMNO,
                       CAST(NUEVO         AS VARCHAR(60))  AS NUEVO,
                       CAST(COD_PERIODO   AS VARCHAR(10))  AS COD_PERIODO,
                       __ESCALERA_B__ AS ORDEN_CICLO,
                       1 AS ORDEN_FUENTE
                FROM CUN.ESTADISTICA_ESTUDIANTE_2
                WHERE NULLIF(LTRIM(RTRIM(ISNULL(NOM_UNIDAD,''))),'') IS NOT NULL

                UNION ALL
                -- Fuente 2: Zoho BASE_PERSONAS
                SELECT CAST(LTRIM(RTRIM(DOC_ALUM)) AS VARCHAR(50)),
                       CAST(NOM_PROGRAMA    AS VARCHAR(200)),
                       CAST(SECCIONAL       AS VARCHAR(100)),
                       CAST(MODALIDAD       AS VARCHAR(100)),
                       CAST(__HOMOLOGA_Z__ AS VARCHAR(60)),
                       CAST(EST_MATRICULADO AS VARCHAR(60)),
                       CAST(NUEVO           AS VARCHAR(60)),
                       CAST(PERIODO         AS VARCHAR(10)),
                       __ESCALERA_Z__,
                       2
                FROM ZOHO.BASE_PERSONAS
                WHERE NULLIF(LTRIM(RTRIM(ISNULL(NOM_PROGRAMA,''))),'') IS NOT NULL

                UNION ALL
                -- Fuente 3: ESTADISTICA_ACADEMICA. Su EST_ALUMNO viene sin el prefijo numerico
                -- que usan las otras dos, asi que se mapea igual que en el CTE de arriba.
                SELECT CAST(LTRIM(RTRIM(NUM_IDENTIFICACION)) AS VARCHAR(50)),
                       CAST(NOM_UNIDAD AS VARCHAR(200)),
                       NULL,
                       CAST(MODALIDAD  AS VARCHAR(100)),
                       CAST(__HOMOLOGA_E__ AS VARCHAR(60)),
                       CAST(CASE
                                WHEN EST_ALUMNO = 'Activo'           THEN '1-Activo'
                                WHEN EST_ALUMNO = 'Egresado'         THEN '2-Egresado'
                                WHEN EST_ALUMNO = 'Graduado'         THEN '3-Graduado'
                                WHEN EST_ALUMNO = 'Graduado Postumo' THEN '12-Graduado Postumo'
                                ELSE EST_ALUMNO
                            END AS VARCHAR(60)),
                       NULL,
                       CAST(COD_PERIODO AS VARCHAR(10)),
                       __ESCALERA_E__,
                       3
                FROM CUN.ESTADISTICA_ACADEMICA
                WHERE NULLIF(LTRIM(RTRIM(ISNULL(NOM_UNIDAD,''))),'') IS NOT NULL
            ) S
        ) z WHERE rn = 1;
        CREATE CLUSTERED INDEX IX_acad_cedula ON #ACAD_CEDULA(id_k);
"""

ANCLA_PROM = "        CREATE CLUSTERED INDEX IX_prom ON #PROM(id_k);\n"

# --- COALESCE de las seis columnas academicas -------------------------------------------
COAL_VIEJO = """                COALESCE(B.ESTADO_ALUMNO, Z.ESTADO_ALUMNO, E.ESTADO_ALUMNO) AS ESTADO_ALUMNO,
                COALESCE(B.NOM_UNIDAD,    Z.NOM_UNIDAD,    E.NOM_UNIDAD)    AS NOM_UNIDAD,
                COALESCE(B.NOM_SECCIONAL, Z.NOM_SECCIONAL, E.NOM_SECCIONAL) AS NOM_SECCIONAL,
                COALESCE(B.MODALIDAD,     Z.MODALIDAD,     E.MODALIDAD)     AS MODALIDAD,
                COALESCE(B.CICLO,         Z.CICLO,         E.CICLO)         AS CICLO,
                COALESCE(B.NUEVO,         Z.NUEVO,         E.NUEVO)         AS NUEVO,"""


def _nz(expr):
    return "NULLIF(LTRIM(RTRIM(ISNULL(%s,''))),'')" % expr


def _coal(nombre, b, z, e, x):
    return ("                COALESCE(%s,\n"
            "                         %s,\n"
            "                         %s,\n"
            "                         %s) AS %s," % (_nz(b), _nz(z), _nz(e), _nz(x), nombre))


COAL_NUEVO = "\n".join([
    "                -- Cuarto termino X = #ACAD_CEDULA: fallback por cedula sola (ver PASO 3).",
    "                -- Va al final, asi que solo actua si las tres fuentes por id+periodo fallaron.",
    "                -- NULLIF: las fuentes traen cadenas vacias, no solo NULL. Sin el, un '' de la",
    "                -- primera fuente se daba por bueno y el fallback nunca disparaba.",
    _coal("ESTADO_ALUMNO", "B.ESTADO_ALUMNO", "Z.ESTADO_ALUMNO", "E.ESTADO_ALUMNO", "X.ESTADO_ALUMNO"),
    _coal("NOM_UNIDAD", "B.NOM_UNIDAD", "Z.NOM_UNIDAD", "E.NOM_UNIDAD", "X.NOM_UNIDAD"),
    _coal("NOM_SECCIONAL", "B.NOM_SECCIONAL", "Z.NOM_SECCIONAL", "E.NOM_SECCIONAL", "X.NOM_SECCIONAL"),
    _coal("MODALIDAD", "B.MODALIDAD", "Z.MODALIDAD", "E.MODALIDAD", "X.MODALIDAD"),
    _coal("CICLO", "B.CICLO", "Z.CICLO", "E.CICLO", "X.CICLO"),
    _coal("NUEVO", "B.NUEVO", "Z.NUEVO", "E.NUEVO", "X.NUEVO"),
])

# --- JOIN de la cuarta fuente ------------------------------------------------------------
JOIN_VIEJO = """        LEFT JOIN #MOODLE M
                ON M.id_k = LTRIM(RTRIM(CONVERT(VARCHAR(50), A.IDENTIFICACION)))
        -- PROMEDIO ACUMULADO: llave SOLO identificacion (PRO_ACUMULADO no es por periodo)."""

JOIN_NUEVO = """        -- 2do cruce academico por CEDULA SOLA: solo rellena lo que B/Z/E dejaron vacio.
        LEFT JOIN #ACAD_CEDULA X
                ON X.id_k = LTRIM(RTRIM(CONVERT(VARCHAR(50), A.IDENTIFICACION)))
        LEFT JOIN #MOODLE M
                ON M.id_k = LTRIM(RTRIM(CONVERT(VARCHAR(50), A.IDENTIFICACION)))
        -- PROMEDIO ACUMULADO: llave SOLO identificacion (PRO_ACUMULADO no es por periodo)."""

# --- Escalera vieja en los dos dedup -----------------------------------------------------
ORDEN_P3_VIEJO = """                                        CASE WHEN CICLO = 'Profesional'                    THEN 1
                                             WHEN CICLO = 'Tecn' + CHAR(243) + 'logo'      THEN 2
                                             WHEN CICLO = 'T' + CHAR(233) + 'cnico Profesional' THEN 3
                                             ELSE 99 END AS ORDEN_CICLO,"""

ORDEN_P3_NUEVO = """                                        -- Escalera corregida (2026-08-26). La anterior dejaba
                                        -- Especializacion en el ELSE 99, o sea POR DEBAJO de
                                        -- Tecnico, y no reconocia el vocabulario en mayusculas
                                        -- de ESTADISTICA_ACADEMICA. CI_AI absorbe ambos.
                                        CASE
                                            WHEN UPPER(LTRIM(RTRIM(ISNULL(CICLO,'')))) COLLATE Latin1_General_CI_AI LIKE 'ESPECIALIZACION%' THEN 1
                                            WHEN UPPER(LTRIM(RTRIM(ISNULL(CICLO,'')))) COLLATE Latin1_General_CI_AI LIKE 'PROFESIONAL%'     THEN 2
                                            WHEN UPPER(LTRIM(RTRIM(ISNULL(CICLO,'')))) COLLATE Latin1_General_CI_AI LIKE 'TECNOLOGO%'       THEN 3
                                            WHEN UPPER(LTRIM(RTRIM(ISNULL(CICLO,'')))) COLLATE Latin1_General_CI_AI LIKE 'TECNICO%'         THEN 4
                                            WHEN NULLIF(LTRIM(RTRIM(ISNULL(CICLO,''))),'') IS NULL                                          THEN 6
                                            ELSE 5
                                        END AS ORDEN_CICLO,"""

ORDEN_P4_VIEJO = """                            CASE WHEN CICLO = 'Profesional'                    THEN 1
                                 WHEN CICLO = 'Tecn' + CHAR(243) + 'logo'      THEN 2
                                 WHEN CICLO = 'T' + CHAR(233) + 'cnico Profesional' THEN 3
                                 ELSE 99 END ASC,"""

ORDEN_P4_NUEVO = """                            -- Escalera corregida (2026-08-26), identica a la del PASO 3.
                            CASE
                                WHEN UPPER(LTRIM(RTRIM(ISNULL(CICLO,'')))) COLLATE Latin1_General_CI_AI LIKE 'ESPECIALIZACION%' THEN 1
                                WHEN UPPER(LTRIM(RTRIM(ISNULL(CICLO,'')))) COLLATE Latin1_General_CI_AI LIKE 'PROFESIONAL%'     THEN 2
                                WHEN UPPER(LTRIM(RTRIM(ISNULL(CICLO,'')))) COLLATE Latin1_General_CI_AI LIKE 'TECNOLOGO%'       THEN 3
                                WHEN UPPER(LTRIM(RTRIM(ISNULL(CICLO,'')))) COLLATE Latin1_General_CI_AI LIKE 'TECNICO%'         THEN 4
                                WHEN NULLIF(LTRIM(RTRIM(ISNULL(CICLO,''))),'') IS NULL                                          THEN 6
                                ELSE 5
                            END ASC,"""

# --- Homologacion en el CTE de ESTADISTICA_ACADEMICA (corrige el camino normal) ----------
E_CTE_VIEJO = "                        NULL AS NOM_SECCIONAL, MODALIDAD, NIVEL_FORMACION AS CICLO,"
E_CTE_NUEVO = ("                        NULL AS NOM_SECCIONAL, MODALIDAD,\n"
               "                        -- Homologacion: esta fuente escribe TECNICO / PROFESIONAL /\n"
               "                        -- TECNOLOGO mientras las otras dos usan Tecnico Profesional /\n"
               "                        -- Profesional / Tecnologo. Sin esto conviven dos ortografias del\n"
               "                        -- mismo nivel en CICLO y cualquier conteo por ciclo se parte en dos\n"
               "                        -- (hoy hay 71 obligaciones en produccion con la forma cruda).\n"
               "                        " + HOMOLOGA % {"c": "NIVEL_FORMACION"} + " AS CICLO,")


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(2)
    origen, destino = sys.argv[1], sys.argv[2]

    with io.open(origen, "r", encoding="utf-8") as fh:
        sql = fh.read()

    bloque = (BLOQUE_FALLBACK
              .replace("__HOMOLOGA_B__", HOMOLOGA % {"c": "CICLO"})
              .replace("__ESCALERA_B__", ESCALERA % {"c": "CICLO"})
              .replace("__HOMOLOGA_Z__", HOMOLOGA % {"c": "NIVEL"})
              .replace("__ESCALERA_Z__", ESCALERA % {"c": "NIVEL"})
              .replace("__HOMOLOGA_E__", HOMOLOGA % {"c": "NIVEL_FORMACION"})
              .replace("__ESCALERA_E__", ESCALERA % {"c": "NIVEL_FORMACION"}))

    pasos = [
        ("bloque #ACAD_CEDULA", ANCLA_PROM, ANCLA_PROM + bloque),
        ("COALESCE con 4a fuente + NULLIF", COAL_VIEJO, COAL_NUEVO),
        ("JOIN de #ACAD_CEDULA", JOIN_VIEJO, JOIN_NUEVO),
        ("escalera corregida (PASO 3)", ORDEN_P3_VIEJO, ORDEN_P3_NUEVO),
        ("escalera corregida (PASO 4)", ORDEN_P4_VIEJO, ORDEN_P4_NUEVO),
        ("homologacion de CICLO en ESTADISTICA_ACADEMICA", E_CTE_VIEJO, E_CTE_NUEVO),
    ]
    for etiqueta, viejo, nuevo in pasos:
        n = sql.count(viejo)
        if n != 1:
            print("ABORTADO - %s: esperaba 1 ocurrencia, encontre %d" % (etiqueta, n))
            sys.exit(1)
        sql = sql.replace(viejo, nuevo, 1)
        print("  OK  %s" % etiqueta)

    errores = []
    if "ELSE 99 END" in sql:
        errores.append("quedo una escalera vieja con ELSE 99")
    # Se construye exactamente una vez y se consume exactamente una vez.
    if sql.count("INTO #ACAD_CEDULA") != 1:
        errores.append("se esperaba 1 'INTO #ACAD_CEDULA', hay %d" % sql.count("INTO #ACAD_CEDULA"))
    if sql.count("LEFT JOIN #ACAD_CEDULA") != 1:
        errores.append("se esperaba 1 'LEFT JOIN #ACAD_CEDULA', hay %d" % sql.count("LEFT JOIN #ACAD_CEDULA"))
    if sql.count("X.NOM_UNIDAD") != 1 or sql.count("X.CICLO") != 1:
        errores.append("el COALESCE no quedo enlazado a la cuarta fuente")
    # El fallback debe construirse ANTES de usarse.
    if sql.index("INTO #ACAD_CEDULA") > sql.index("LEFT JOIN #ACAD_CEDULA"):
        errores.append("#ACAD_CEDULA se usa antes de construirse")

    if errores:
        print("\nABORTADO. No se escribio nada:")
        for e in errores:
            print("   - %s" % e)
        sys.exit(1)
    print("  OK  #ACAD_CEDULA se construye antes de usarse")

    with io.open(destino, "w", encoding="utf-8") as fh:
        fh.write(sql)
    print("\nEscrito: %s  (%d chars)" % (destino, len(sql)))


if __name__ == "__main__":
    main()
