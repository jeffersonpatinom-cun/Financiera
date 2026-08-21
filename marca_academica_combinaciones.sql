/*===========================================================================================
  MARCA_ACADEMICA — Matriz de casuisticas y asignacion de marca
  -------------------------------------------------------------------------------------------
  Objeto      : FINANCIERA.Cartera_Gestion
  Autor       : Analitica financiera - Universidad CUN
  Proposito   : Tipificar las variables de entrada, enumerar TODAS las combinaciones realmente
                presentes en la cartera y asignar la marca que enruta la gestion de cobro.

  Salidas (3 conjuntos de resultados):
      1. Matriz de combinaciones observadas (casuistica + volumen).
      2. Resumen por marca: obligaciones y clientes distintos.
      3. Resumen a nivel CLIENTE UNICO: una sola marca por persona (la de mayor prioridad).

  Columnas de entrada:
      NOMBRE_TIPO_CLIENTE          -> segmento (ESTUDIANTES / COMERCIAL / COLABORADORES)
      ESTADO                       -> estado de calendario del periodo
      ESTADO_ALUMNO                -> vinculo del deudor con la institucion
      RES_PERFIL_RIESGO            -> perfil crediticio (fuente: CTAYUDA_V2 / perfil_crediticio)
      ultimoaccesoplataformlimpio  -> ultimo acceso a plataforma academica
      PROMEDIO                     -> promedio de notas del periodo

  Escala de riesgo verificada contra datos (RES_SCORE observado):
      Riesgo Alto       0 - 579     |  Riesgo Regular   580 - 668
      Riesgo Bueno    670 - 798     |  Riesgo Muy Bueno 800 - 899
      Riesgo Excelente 904 - 1000
      => Corte de riesgo adverso: Alto + Regular (score < 670).

  NOTA DE CONTEO: Cartera_Gestion tiene una fila por OBLIGACION, no por persona. Un mismo
  estudiante aparece varias veces (varios periodos / creditos). Por eso los conjuntos 1 y 2
  reportan CLIENTES_UNICOS por combinacion -- que NO suman el total de la cartera, porque una
  persona puede caer en mas de una casuistica. El conjunto 3 resuelve eso: asigna una unica
  marca por persona y si suma exactamente el universo de clientes.
===========================================================================================*/

/*===========================================================================================
  BLOQUE COMUN DE TIPIFICACION Y MARCADO
===========================================================================================*/
IF OBJECT_ID('tempdb..#MARCA') IS NOT NULL DROP TABLE #MARCA;

WITH Cartera_Tipificada AS (
    SELECT
        IDENTIFICACION,

        /*--- 0. Segmento del deudor ---------------------------------------------------
                Se separa ANTES de cualquier lectura academica: un NIT empresarial no
                tiene notas, ni plataforma, ni periodo academico que evaluar. -----------*/
        ISNULL(NULLIF(LTRIM(RTRIM(NOMBRE_TIPO_CLIENTE)), ''), 'SIN DATO') AS TIPO_CLIENTE,

        /*--- 1. Estado de calendario del periodo -------------------------------------*/
        ISNULL(NULLIF(LTRIM(RTRIM(ESTADO)), ''), 'SIN DATO')            AS ESTADO_PERIODO,

        /*--- 2. Vinculo del deudor ----------------------------------------------------*/
        ISNULL(NULLIF(LTRIM(RTRIM(ESTADO_ALUMNO)), ''), 'SIN DATO')     AS ESTADO_ALUMNO,

        /*--- 3. Riesgo crediticio ADVERSO: SI = Riesgo Alto o Regular (score < 670).
                No es presencia del dato: un perfil Bueno/Muy Bueno/Excelente es senal
                POSITIVA de pago y no debe escalar la prioridad. -----------------------*/
        CASE
            WHEN LTRIM(RTRIM(ISNULL(RES_PERFIL_RIESGO,''))) IN ('Riesgo Alto', 'Riesgo Regular')
                THEN 'SI'
            ELSE 'NO'
        END                                                             AS RES_PERFIL_RIESGO,

        /*--- 3b. Cobertura del dato (diagnostico, NO criterio de marca) ---------------*/
        CASE
            WHEN NULLIF(LTRIM(RTRIM(ISNULL(RES_PERFIL_RIESGO,''))), '') IS NOT NULL
                THEN 'SI'
            ELSE 'NO'
        END                                                             AS COBERTURA_PERFIL,

        /*--- 4. Evidencia de conexion academica --------------------------------------*/
        CASE
            WHEN ultimoaccesoplataformlimpio IS NOT NULL THEN 'SI'
            ELSE 'NO'
        END                                                             AS [acceso plataforma],

        /*--- 5. Resultado academico del periodo --------------------------------------*/
        CASE
            WHEN PROMEDIO IS NULL   THEN 'SIN NOTA'
            WHEN PROMEDIO >= 3.0    THEN 'APROBO'
            ELSE 'PERDIO'
        END                                                             AS [ESTADO NOTAS]
    FROM FINANCIERA.Cartera_Gestion
)
SELECT
    IDENTIFICACION,
    TIPO_CLIENTE,
    ESTADO_PERIODO,
    ESTADO_ALUMNO,
    RES_PERFIL_RIESGO,
    COBERTURA_PERFIL,
    [acceso plataforma],
    [ESTADO NOTAS],

    /*========================================================================
      MARCA_ACADEMICA — escalera excluyente, nunca NULL.
      El orden ES la regla: la primera condicion que se cumple gana.
    ========================================================================*/
    CASE
        -- 0. Segmento no estudiantil: la lectura academica no aplica.
        WHEN TIPO_CLIENTE <> 'ESTUDIANTES'
            THEN 'CARTERA EMPRESARIAL'

        -- 1. El calendario manda: aun no hay hecho academico que evaluar.
        WHEN ESTADO_PERIODO = 'PERIODO NO HA INICIADO'
            THEN 'PERIODO NO HA INICIADO'

        -- 2. Periodo abierto: la nota es parcial, no es un fallo consumado.
        WHEN ESTADO_PERIODO = 'ACTIVO'
          OR ([acceso plataforma] = 'SI'
              AND [ESTADO NOTAS] IN ('APROBO', 'SIN NOTA')
              AND ESTADO_PERIODO <> 'NO ACTIVO')
            THEN 'PERIODO EN CURSO'

        -- 3. Periodo cerrado con fallo academico, o riesgo crediticio ADVERSO
        --    en un deudor vigente/egresado/graduado.
        WHEN [ESTADO NOTAS] = 'PERDIO'
          OR (RES_PERFIL_RIESGO = 'SI'
              AND ESTADO_ALUMNO IN ('1-Activo', '2-Egresado', '3-Graduado'))
            THEN 'PERIODO PERDIDO, PRIORIDAD ALTA'

        -- 4. Cumplio academicamente o ya cerro su ciclo: cobro ordinario.
        WHEN [ESTADO NOTAS] = 'APROBO'
          OR ESTADO_ALUMNO IN ('2-Egresado', '3-Graduado')
            THEN 'GESTIONABLE'

        -- 5. Catch-all: sin evidencia academica de ningun tipo.
        ELSE 'SIN REGISTRO DE CLASE'
    END AS MARCA_ACADEMICA,

    /*========================================================================
      MARCA_ACADEMICA_DETALLE — abre cada marca segun el riesgo crediticio.
    ========================================================================*/
    CASE
        WHEN TIPO_CLIENTE <> 'ESTUDIANTES'
            THEN 'CARTERA EMPRESARIAL - ' + TIPO_CLIENTE

        WHEN ESTADO_PERIODO = 'PERIODO NO HA INICIADO'
            THEN 'PERIODO NO HA INICIADO'

        WHEN (ESTADO_PERIODO = 'ACTIVO'
              OR ([acceso plataforma] = 'SI'
                  AND [ESTADO NOTAS] IN ('APROBO','SIN NOTA')
                  AND ESTADO_PERIODO <> 'NO ACTIVO'))
             AND [ESTADO NOTAS] = 'PERDIO'
            THEN 'PERIODO EN CURSO - ALERTA ACADEMICA'

        WHEN (ESTADO_PERIODO = 'ACTIVO'
              OR ([acceso plataforma] = 'SI'
                  AND [ESTADO NOTAS] IN ('APROBO','SIN NOTA')
                  AND ESTADO_PERIODO <> 'NO ACTIVO'))
             AND RES_PERFIL_RIESGO = 'SI'
            THEN 'PERIODO EN CURSO - RIESGO CREDITICIO'

        WHEN ESTADO_PERIODO = 'ACTIVO'
          OR ([acceso plataforma] = 'SI'
              AND [ESTADO NOTAS] IN ('APROBO','SIN NOTA')
              AND ESTADO_PERIODO <> 'NO ACTIVO')
            THEN 'PERIODO EN CURSO'

        WHEN [ESTADO NOTAS] = 'PERDIO' AND RES_PERFIL_RIESGO = 'SI'
            THEN 'PERIODO PERDIDO + RIESGO CREDITICIO'

        WHEN [ESTADO NOTAS] = 'PERDIO'
            THEN 'PERIODO PERDIDO'

        WHEN RES_PERFIL_RIESGO = 'SI'
             AND ESTADO_ALUMNO IN ('1-Activo','2-Egresado','3-Graduado')
            THEN 'RIESGO CREDITICIO ADVERSO'

        WHEN [ESTADO NOTAS] = 'APROBO' OR ESTADO_ALUMNO IN ('2-Egresado','3-Graduado')
            THEN 'GESTIONABLE'

        WHEN [acceso plataforma] = 'SI'
            THEN 'SIN REGISTRO DE CLASE - CON CONEXION'

        ELSE 'SIN REGISTRO DE CLASE - SIN CONTACTO'
    END AS MARCA_ACADEMICA_DETALLE
INTO #MARCA
FROM Cartera_Tipificada;


/*===========================================================================================
  RESULTADO 1 — Matriz de casuisticas: una fila por combinacion REAL de las variables.
  CLIENTES_UNICOS = personas distintas en esa casuistica (no suma el total: ver nota arriba).
===========================================================================================*/
SELECT
    TIPO_CLIENTE,
    ESTADO_PERIODO,
    ESTADO_ALUMNO,
    RES_PERFIL_RIESGO,
    COBERTURA_PERFIL,
    [acceso plataforma],
    [ESTADO NOTAS],
    MARCA_ACADEMICA,
    MARCA_ACADEMICA_DETALLE,
    COUNT(DISTINCT IDENTIFICACION)                                  AS CLIENTES_UNICOS,
    COUNT(*)                                                        AS OBLIGACIONES
FROM #MARCA
GROUP BY
    TIPO_CLIENTE, ESTADO_PERIODO, ESTADO_ALUMNO, RES_PERFIL_RIESGO, COBERTURA_PERFIL,
    [acceso plataforma], [ESTADO NOTAS], MARCA_ACADEMICA, MARCA_ACADEMICA_DETALLE
ORDER BY MARCA_ACADEMICA, CLIENTES_UNICOS DESC;


/*===========================================================================================
  RESULTADO 2 — Resumen por marca (obligaciones vs clientes distintos).
===========================================================================================*/
SELECT
    MARCA_ACADEMICA,
    COUNT(DISTINCT IDENTIFICACION)                                  AS CLIENTES_UNICOS,
    COUNT(*)                                                        AS OBLIGACIONES,
    CAST(1.0 * COUNT(*) / COUNT(DISTINCT IDENTIFICACION) AS DECIMAL(6,2)) AS OBLIG_X_CLIENTE
FROM #MARCA
GROUP BY MARCA_ACADEMICA
ORDER BY CLIENTES_UNICOS DESC;


/*===========================================================================================
  RESULTADO 3 — Vista a nivel CLIENTE UNICO.
  Una persona puede tener obligaciones en varias marcas (distintos periodos). Para la cola de
  trabajo se le asigna UNA sola: la de mayor urgencia de gestion. Este conjunto SI suma el
  universo total de clientes de la cartera.
===========================================================================================*/
WITH PRIORIZADO AS (
    SELECT
        IDENTIFICACION,
        MARCA_ACADEMICA,
        ROW_NUMBER() OVER (
            PARTITION BY IDENTIFICACION
            ORDER BY CASE MARCA_ACADEMICA
                        WHEN 'CARTERA EMPRESARIAL'             THEN 1
                        WHEN 'PERIODO PERDIDO, PRIORIDAD ALTA' THEN 2
                        WHEN 'SIN REGISTRO DE CLASE'           THEN 3
                        WHEN 'GESTIONABLE'                     THEN 4
                        WHEN 'PERIODO EN CURSO'                THEN 5
                        WHEN 'PERIODO NO HA INICIADO'          THEN 6
                     END
        ) AS rn
    FROM #MARCA
)
SELECT
    MARCA_ACADEMICA,
    COUNT(*)                                                        AS CLIENTES_UNICOS,
    CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,2))   AS PCT_CLIENTES
FROM PRIORIZADO
WHERE rn = 1
GROUP BY MARCA_ACADEMICA
ORDER BY CLIENTES_UNICOS DESC;
