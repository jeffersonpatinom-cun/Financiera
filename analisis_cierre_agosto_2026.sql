/*===========================================================================================
  ANALISIS DESCRIPTIVO — Cierre de AGOSTO 2026
  -------------------------------------------------------------------------------------------
  Autor    : Analitica financiera - Universidad CUN
  Bloques  : 1) cumplimiento de la meta de agosto
             2) gestion del equipo de asesores
             3) recaudo registrado en CRM

  REGLAS DE CALCULO (definidas con Coordinacion de Recaudo y Cartera, 2026-09-02)
  -------------------------------------------------------------------------------------------
  * Universo de asesores : Financiera.Cartera_CUN_Asesor_Unico con Asesor_Unico distinto de
                           'Reasignar en CRM' y 'Sin asignar'. Sin ese filtro toda metrica de
                           gestion queda inflada un 27% (84.179 de 311.640 registros).
  * Gestion              : Hora_modificacion_tipif dentro de agosto. NO se usa
                           Hora_de_modificación: cae en agosto para el 93% de la base por una
                           actualizacion masiva (1.538 en julio contra 210.789 en agosto), asi
                           que mide carga de sistema y no gestion del asesor.
  * Pago                 : Fecha_de_pago dentro de agosto, sumando Valor_pagado.
  * Q y MARCA de la meta : SIEMPRE desde Cartera_Meta_Comercial_Snapshot_Mensual con
                           ANIO_MES_SNAPSHOT='202609' (foto previa al refresco = cierre de
                           agosto). Leerlas de la tabla viva mezcla la Q de septiembre de los
                           que siguen con la de agosto de los que salieron, y da un falso
                           99,7% de cumplimiento en Q4 contra 4,0% en Q1.

  TRAMPAS DE FORMATO
  -------------------------------------------------------------------------------------------
  * Fechas en dd/MM/yyyy  -> TRY_CONVERT(..., 103).
  * Dinero como 'CO$ 351,576.50' -> hay que quitar 'CO$', comas y espacios; sin eso toda
    suma da 0 en silencio.

  LIMITACION DECLARADA
  -------------------------------------------------------------------------------------------
  * No se puede medir el abono parcial de agosto: BASELINE_20260826 y los snapshots 202608 y
    202609 tienen saldo identico ($15.198,0 MM), porque el refresco total de saldos solo
    empezo a correr el 2026-09-01. El cumplimiento se mide por SALIDA COMPLETA de la meta.
  * Cartera_CUN_Asesor_Unico es foto del dia, no historico: lo tipificado en agosto y
    sobrescrito despues ya no se ve.
===========================================================================================*/

/*===========================================================================================
  BLOQUE 1 — CUMPLIMIENTO DE LA META DE AGOSTO
===========================================================================================*/

/*--- 1.1 Universo, salidas y remanente ---------------------------------------------------
        El SALDO sale del snapshot 202609, no de la tabla viva: la corrida del 1 de
        septiembre ya refresco el saldo de los 40.857 que siguen, asi que la tabla viva
        reporta $15.042,0 MM y subestima con que saldo se trabajo realmente agosto.      */
SELECT
    'META AGOSTO 2026'                                              AS CORTE,
    COUNT(*)                                                        AS OBLIGACIONES,
    COUNT(DISTINCT S.IDENTIFICACION)                                AS ESTUDIANTES,
    CAST(SUM(CAST(S.TOTAL AS DECIMAL(18,2)))/1e6 AS DECIMAL(18,1))  AS SALDO_MM,
    SUM(CASE WHEN H.Meta_2026 NOT LIKE '%202609%' THEN 1 ELSE 0 END) AS SALIERON,
    SUM(CASE WHEN H.Meta_2026 LIKE '%202609%' THEN 1 ELSE 0 END)    AS SIGUEN,
    CAST(100.0 * SUM(CASE WHEN H.Meta_2026 NOT LIKE '%202609%' THEN 1 ELSE 0 END)
         / COUNT(*) AS DECIMAL(5,2))                                AS PCT_CUMPLIMIENTO
FROM Financiera.Cartera_Meta_Comercial_Snapshot_Mensual S
JOIN Financiera.Cartera_Meta_Comercial_Historico H ON H.NUMERO_CREDITO = S.NUMERO_CREDITO
WHERE S.ANIO_MES_SNAPSHOT = '202609' AND S.Meta_2026 LIKE '%202608%';

/*--- 1.2 Detalle de las salidas ----------------------------------------------------------*/
SELECT
    'SALIERON (pagaron / normalizaron)'                             AS CONCEPTO,
    COUNT(*)                                                        AS OBLIGACIONES,
    COUNT(DISTINCT IDENTIFICACION)                                  AS ESTUDIANTES,
    CAST(SUM(CAST(TOTAL AS DECIMAL(18,2)))/1e6 AS DECIMAL(18,1))    AS SALDO_LIBERADO_MM
FROM Financiera.Cartera_Meta_Comercial_Historico
WHERE Meta_2026 LIKE '%202608%' AND Meta_2026 NOT LIKE '%202609%';

/*--- 1.3 Cumplimiento por CUARTIL — leido del snapshot del cierre de agosto --------------
        La Q de la tabla viva ya fue recalculada por la corrida del 1 de septiembre.
        El snapshot 202609 es la foto PREVIA a ese refresco: la Q con la que se trabajo.  */
SELECT
    S.[Asignacion Q]                                                AS CUARTIL,
    COUNT(*)                                                        AS META_AGOSTO,
    SUM(CASE WHEN H.Meta_2026 NOT LIKE '%202609%' THEN 1 ELSE 0 END) AS SALIERON,
    CAST(100.0 * SUM(CASE WHEN H.Meta_2026 NOT LIKE '%202609%' THEN 1 ELSE 0 END)
         / COUNT(*) AS DECIMAL(5,2))                                AS PCT_CUMPLIMIENTO,
    CAST(SUM(CAST(S.TOTAL AS DECIMAL(18,2)))/1e6 AS DECIMAL(18,1))  AS SALDO_MM
FROM Financiera.Cartera_Meta_Comercial_Snapshot_Mensual S
JOIN Financiera.Cartera_Meta_Comercial_Historico H ON H.NUMERO_CREDITO = S.NUMERO_CREDITO
WHERE S.ANIO_MES_SNAPSHOT = '202609' AND S.Meta_2026 LIKE '%202608%'
GROUP BY S.[Asignacion Q]
ORDER BY CUARTIL;

/*--- 1.4 Cumplimiento por MARCA ACADEMICA — tambien del snapshot -------------------------*/
SELECT
    ISNULL(NULLIF(LTRIM(RTRIM(S.MARCA_ACADEMICA)),''),'(sin marca)') AS MARCA_ACADEMICA,
    COUNT(*)                                                        AS META_AGOSTO,
    SUM(CASE WHEN H.Meta_2026 NOT LIKE '%202609%' THEN 1 ELSE 0 END) AS SALIERON,
    CAST(100.0 * SUM(CASE WHEN H.Meta_2026 NOT LIKE '%202609%' THEN 1 ELSE 0 END)
         / COUNT(*) AS DECIMAL(5,2))                                AS PCT_CUMPLIMIENTO,
    CAST(SUM(CAST(S.TOTAL AS DECIMAL(18,2)))/1e6 AS DECIMAL(18,1))  AS SALDO_MM
FROM Financiera.Cartera_Meta_Comercial_Snapshot_Mensual S
JOIN Financiera.Cartera_Meta_Comercial_Historico H ON H.NUMERO_CREDITO = S.NUMERO_CREDITO
WHERE S.ANIO_MES_SNAPSHOT = '202609' AND S.Meta_2026 LIKE '%202608%'
GROUP BY S.MARCA_ACADEMICA
ORDER BY META_AGOSTO DESC;

/*--- 1.5 Prueba de la trampa: la MISMA consulta contra la tabla viva da otro resultado ----
        Se deja documentada para que nadie la reintroduzca por descuido.                  */
SELECT
    'CONTROL - NO USAR: Q leida de la tabla viva'                   AS ADVERTENCIA,
    H.[Asignacion Q]                                                AS CUARTIL,
    COUNT(*)                                                        AS META_AGOSTO,
    SUM(CASE WHEN H.Meta_2026 NOT LIKE '%202609%' THEN 1 ELSE 0 END) AS SALIERON
FROM Financiera.Cartera_Meta_Comercial_Historico H
WHERE H.Meta_2026 LIKE '%202608%'
GROUP BY H.[Asignacion Q]
ORDER BY CUARTIL;


/*===========================================================================================
  BLOQUE 2 — GESTION DEL EQUIPO DE ASESORES
  Se reporta SOLO en agregado: el informe no nombra asesores.
===========================================================================================*/

IF OBJECT_ID('tempdb..#GES') IS NOT NULL DROP TABLE #GES;
SELECT
    LTRIM(RTRIM(G.Asesor_Unico))                                    AS ASESOR,
    LTRIM(RTRIM(G.Número_de_identificación))                        AS IDENTIFICACION,
    G.Número_de_crédito                                             AS NUMERO_CREDITO,
    G.Periodo                                                       AS PERIODO,
    NULLIF(LTRIM(RTRIM(G.Tipificación_a_marcar)),'')                AS TIPIFICACION,
    TRY_CONVERT(datetime, G.Hora_modificacion_tipif, 103)           AS FECHA_GESTION,
    TRY_CONVERT(date,     G.Fecha_de_pago,           103)           AS FECHA_PAGO,
    TRY_CONVERT(DECIMAL(18,2),
        REPLACE(REPLACE(REPLACE(G.Valor_pagado,'CO$',''),',',''),' ','')) AS VALOR_PAGADO
INTO #GES
FROM Financiera.Cartera_CUN_Asesor_Unico G
WHERE G.Asesor_Unico NOT IN ('Reasignar en CRM', 'Sin asignar')
  AND NULLIF(LTRIM(RTRIM(G.Asesor_Unico)), '') IS NOT NULL;

/*--- 2.1 Indicadores del mes -------------------------------------------------------------*/
SELECT
    COUNT(*)                                                        AS BASE_ASIGNADA,
    COUNT(DISTINCT ASESOR)                                          AS ASESORES_CON_BASE,
    SUM(CASE WHEN FECHA_GESTION >= '2026-08-01'
              AND FECHA_GESTION <  '2026-09-01' THEN 1 ELSE 0 END)  AS GESTIONES_AGOSTO,
    COUNT(DISTINCT CASE WHEN FECHA_GESTION >= '2026-08-01'
                         AND FECHA_GESTION <  '2026-09-01'
                        THEN IDENTIFICACION END)                    AS PERSONAS_GESTIONADAS,
    COUNT(DISTINCT CASE WHEN FECHA_GESTION >= '2026-08-01'
                         AND FECHA_GESTION <  '2026-09-01'
                        THEN ASESOR END)                            AS ASESORES_ACTIVOS
FROM #GES;

/*--- 2.2 Dispersion de la carga, sin nombres ---------------------------------------------*/
WITH POR_ASESOR AS (
    SELECT ASESOR, COUNT(*) AS GESTIONES
    FROM #GES
    WHERE FECHA_GESTION >= '2026-08-01' AND FECHA_GESTION < '2026-09-01'
    GROUP BY ASESOR
)
SELECT
    COUNT(*)                                                        AS ASESORES_ACTIVOS,
    MIN(GESTIONES)                                                  AS MINIMO,
    MAX(GESTIONES)                                                  AS MAXIMO,
    AVG(GESTIONES)                                                  AS PROMEDIO,
    SUM(GESTIONES)                                                  AS TOTAL_GESTIONES
FROM POR_ASESOR;

/*--- 2.3 Embudo: base -> gestionadas -> con pago registrado ------------------------------*/
WITH GESTIONADAS AS (
    SELECT DISTINCT IDENTIFICACION FROM #GES
    WHERE FECHA_GESTION >= '2026-08-01' AND FECHA_GESTION < '2026-09-01'
), PAGARON AS (
    SELECT DISTINCT IDENTIFICACION FROM #GES
    WHERE FECHA_PAGO >= '2026-08-01' AND FECHA_PAGO < '2026-09-01'
)
SELECT
    (SELECT COUNT(DISTINCT IDENTIFICACION) FROM #GES)               AS PERSONAS_EN_BASE,
    (SELECT COUNT(*) FROM GESTIONADAS)                              AS GESTIONADAS,
    (SELECT COUNT(*) FROM PAGARON)                                  AS CON_PAGO,
    (SELECT COUNT(*) FROM GESTIONADAS G JOIN PAGARON P
      ON P.IDENTIFICACION = G.IDENTIFICACION)                       AS GESTIONADAS_Y_PAGARON,
    CAST(100.0 * (SELECT COUNT(*) FROM GESTIONADAS G JOIN PAGARON P
                   ON P.IDENTIFICACION = G.IDENTIFICACION)
         / NULLIF((SELECT COUNT(*) FROM GESTIONADAS),0) AS DECIMAL(5,2)) AS PCT_EFECTIVIDAD;

/*--- 2.4 Cartera sin dueño: lo que el filtro deja fuera ----------------------------------*/
SELECT
    ISNULL(NULLIF(LTRIM(RTRIM(Asesor_Unico)),''),'(vacio)')         AS ESTADO_ASIGNACION,
    COUNT(*)                                                        AS REGISTROS,
    COUNT(DISTINCT Número_de_identificación)                        AS PERSONAS
FROM Financiera.Cartera_CUN_Asesor_Unico
WHERE Asesor_Unico IN ('Reasignar en CRM', 'Sin asignar')
   OR NULLIF(LTRIM(RTRIM(Asesor_Unico)), '') IS NULL
GROUP BY Asesor_Unico
ORDER BY REGISTROS DESC;

/*--- 2.5 Tipificaciones aplicadas en agosto ----------------------------------------------*/
SELECT TOP 12
    ISNULL(TIPIFICACION, '(sin tipificar)')                         AS TIPIFICACION,
    COUNT(*)                                                        AS GESTIONES,
    COUNT(DISTINCT IDENTIFICACION)                                  AS PERSONAS,
    CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,2))  AS PCT
FROM #GES
WHERE FECHA_GESTION >= '2026-08-01' AND FECHA_GESTION < '2026-09-01'
GROUP BY TIPIFICACION
ORDER BY GESTIONES DESC;


/*===========================================================================================
  BLOQUE 3 — RECAUDO REGISTRADO EN CRM
  OJO: es lo que los asesores marcaron como pagado, NO la caja institucional.
===========================================================================================*/

/*--- 3.1 Totales del mes -----------------------------------------------------------------*/
SELECT
    COUNT(*)                                                        AS PAGOS,
    COUNT(DISTINCT IDENTIFICACION)                                  AS PERSONAS,
    CAST(SUM(VALOR_PAGADO)/1e6 AS DECIMAL(18,1))                    AS VALOR_MM,
    CAST(AVG(VALOR_PAGADO) AS DECIMAL(18,0))                        AS TICKET_PROMEDIO
FROM #GES
WHERE FECHA_PAGO >= '2026-08-01' AND FECHA_PAGO < '2026-09-01';

/*--- 3.2 Por periodo academico -----------------------------------------------------------*/
SELECT TOP 12
    ISNULL(NULLIF(LTRIM(RTRIM(PERIODO)),''),'(sin periodo)')        AS PERIODO,
    COUNT(*)                                                        AS PAGOS,
    COUNT(DISTINCT IDENTIFICACION)                                  AS PERSONAS,
    CAST(SUM(VALOR_PAGADO)/1e6 AS DECIMAL(18,1))                    AS VALOR_MM,
    CAST(100.0 * SUM(VALOR_PAGADO) / SUM(SUM(VALOR_PAGADO)) OVER () AS DECIMAL(5,2)) AS PCT_VALOR
FROM #GES
WHERE FECHA_PAGO >= '2026-08-01' AND FECHA_PAGO < '2026-09-01'
GROUP BY PERIODO
ORDER BY VALOR_MM DESC;

/*--- 3.3 Por tipificacion registrada -----------------------------------------------------*/
SELECT TOP 10
    ISNULL(TIPIFICACION, '(sin tipificar)')                         AS TIPIFICACION,
    COUNT(*)                                                        AS PAGOS,
    CAST(SUM(VALOR_PAGADO)/1e6 AS DECIMAL(18,1))                    AS VALOR_MM
FROM #GES
WHERE FECHA_PAGO >= '2026-08-01' AND FECHA_PAGO < '2026-09-01'
GROUP BY TIPIFICACION
ORDER BY VALOR_MM DESC;

/*--- 3.4 Distribucion del ticket ---------------------------------------------------------*/
SELECT
    CASE WHEN VALOR_PAGADO IS NULL      THEN '0. sin valor'
         WHEN VALOR_PAGADO <   100000   THEN '1. menos de 100k'
         WHEN VALOR_PAGADO <   300000   THEN '2. 100k - 300k'
         WHEN VALOR_PAGADO <   600000   THEN '3. 300k - 600k'
         WHEN VALOR_PAGADO <  1000000   THEN '4. 600k - 1M'
         ELSE                                '5. mas de 1M' END     AS RANGO_TICKET,
    COUNT(*)                                                        AS PAGOS,
    CAST(SUM(VALOR_PAGADO)/1e6 AS DECIMAL(18,1))                    AS VALOR_MM
FROM #GES
WHERE FECHA_PAGO >= '2026-08-01' AND FECHA_PAGO < '2026-09-01'
GROUP BY CASE WHEN VALOR_PAGADO IS NULL      THEN '0. sin valor'
              WHEN VALOR_PAGADO <   100000   THEN '1. menos de 100k'
              WHEN VALOR_PAGADO <   300000   THEN '2. 100k - 300k'
              WHEN VALOR_PAGADO <   600000   THEN '3. 300k - 600k'
              WHEN VALOR_PAGADO <  1000000   THEN '4. 600k - 1M'
              ELSE                                '5. mas de 1M' END
ORDER BY RANGO_TICKET;
