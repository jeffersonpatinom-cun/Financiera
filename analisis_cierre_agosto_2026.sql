/*===========================================================================================
  ANALISIS DESCRIPTIVO — Cierre de AGOSTO 2026
  -------------------------------------------------------------------------------------------
  Autor    : Analitica financiera - Universidad CUN
  Bloques  : 1) cumplimiento de la meta de agosto
             2) gestion del equipo de asesores
             3) recaudo registrado en CRM

  REGLAS DE CALCULO (definidas con Coordinacion de Recaudo y Cartera, 2026-09-02;
                     bloques 2 y 3 CORREGIDOS el 2026-09-03, ver fe de erratas)
  -------------------------------------------------------------------------------------------
  * Universo de asesores : OBSOLETO. Se usaba Asesor_Unico distinto de 'Reasignar en CRM' y
                           'Sin asignar'. Ese campo esta disenado para NUNCA quedar vacio:
                           cuando nadie tipifico cae al usuario que modifico el registro o al
                           propietario de la cartera. El filtro solo descartaba los dos
                           literales y dejaba pasar a todo el que jamas gestiono.
  * Gestion              : AHORA una fila por tipificacion del historico
                           [ZOHO].[CRM].[Historico_tipificacion_contact], excluyendo los bots
                           CUN DIGITAL y PENAGOS, y con el asesor tomado de Hecho_por.
                           Medido: de las 61.767 "gestiones" publicadas, 42.768 las hizo el
                           bot. Las gestiones humanas reales de agosto son 22.941.
                           Sobre la tabla materializada el equivalente es GESTION_MARCA = 1.
  * Pago                 : AHORA GESTION_PAGO_POST_MARCA = 1 — Fecha_de_pago en el mes sobre
                           una persona efectivamente gestionada Y con el pago posterior a la
                           PRIMERA gestion. Un pago anterior a que el asesor tocara el caso no
                           es fruto de su gestion.
  * Asignacion           : para "de quien es la cartera" (bloque 2.4) Asesor_Unico SI es el
                           campo correcto. El error era usarlo para medir quien gestiono.
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
  BLOQUE 2 — GESTION DEL EQUIPO DE ASESORES   (CORREGIDO 2026-09-03)
  -------------------------------------------------------------------------------------------
  La version anterior armaba #GES desde Financiera.Cartera_CUN_Asesor_Unico filtrando
  Asesor_Unico. Eso contaba como gestion del equipo 42.768 tipificaciones del bot CUN DIGITAL,
  porque cuando el bot tipifica, la escalera de Asesor_Unico cae al usuario modificador o al
  propietario de la cartera y le atribuye ese trabajo a una persona real.

  Ahora la gestion se lee del historico, que es la unica fuente que dice QUIEN ejecuto.
  El ranking 2.6 va con nombre porque la Coordinacion lo pidio para la liquidacion; el
  informe ejecutivo sigue reportando el equipo en agregado.
===========================================================================================*/

IF OBJECT_ID('tempdb..#GES') IS NOT NULL DROP TABLE #GES;
SELECT
    UPPER(LTRIM(RTRIM(CONVERT(varchar(200), e.Hecho_por))))         AS ASESOR,
    LTRIM(RTRIM(c.[Número_de_identificación]))                      AS IDENTIFICACION,
    c.Número_de_crédito                                             AS NUMERO_CREDITO,
    c.Periodo                                                       AS PERIODO,
    NULLIF(LTRIM(RTRIM(CONVERT(varchar(200), e.Tipificación_nueva))),'') AS TIPIFICACION,
    COALESCE(TRY_CONVERT(datetime, e.Hora_de_modificación, 103),
             TRY_CONVERT(datetime, e.Hora_de_creación,     103))    AS FECHA_GESTION
INTO #GES
FROM [ZOHO].[CRM].[Historico_tipificacion_contact] e
JOIN ZOHO.CRM.Cartera_CUN c
      ON CONVERT(varchar(30), c.Id) = CONVERT(varchar(30), e.Cartera_CUN)
WHERE e.Hecho_por IS NOT NULL
  /* Cuentas de sistema, no personas. Son el 54,3% del historico. */
  AND UPPER(e.Hecho_por) NOT LIKE '%CUN DIGITAL%'
  AND UPPER(e.Hecho_por) NOT LIKE '%PENAGOS%'
  AND c.[Número_de_identificación] IS NOT NULL AND c.[Número_de_identificación] <> ''
  AND COALESCE(TRY_CONVERT(datetime, e.Hora_de_modificación, 103),
               TRY_CONVERT(datetime, e.Hora_de_creación, 103)) >= '2026-08-01'
  AND COALESCE(TRY_CONVERT(datetime, e.Hora_de_modificación, 103),
               TRY_CONVERT(datetime, e.Hora_de_creación, 103)) <  '2026-09-01';

/* Pagos atribuibles: la marca ya exige gestion real + pago posterior a la primera. */
IF OBJECT_ID('tempdb..#PAG') IS NOT NULL DROP TABLE #PAG;
SELECT
    G.GESTION_ASESOR                                                AS ASESOR,
    LTRIM(RTRIM(G.Número_de_identificación))                        AS IDENTIFICACION,
    G.Número_de_crédito                                             AS NUMERO_CREDITO,
    G.Periodo                                                       AS PERIODO,
    TRY_CONVERT(date, G.Fecha_de_pago, 103)                         AS FECHA_PAGO,
    TRY_CONVERT(DECIMAL(18,2),
        REPLACE(REPLACE(REPLACE(G.Valor_pagado,'CO$',''),',',''),' ','')) AS VALOR_PAGADO
INTO #PAG
FROM Financiera.Cartera_CUN_Asesor_Unico G
WHERE G.GESTION_PAGO_POST_MARCA = 1
  AND TRY_CONVERT(date, G.Fecha_de_pago, 103) >= '2026-08-01'
  AND TRY_CONVERT(date, G.Fecha_de_pago, 103) <  '2026-09-01'
  AND TRY_CONVERT(DECIMAL(18,2),
        REPLACE(REPLACE(REPLACE(G.Valor_pagado,'CO$',''),',',''),' ','')) > 0;

/*--- 2.1 Indicadores del mes -------------------------------------------------------------*/
SELECT
    (SELECT COUNT(DISTINCT LTRIM(RTRIM(Número_de_identificación)))
     FROM Financiera.Cartera_CUN_Asesor_Unico
     WHERE Asesor_Unico NOT IN ('Reasignar en CRM','Sin asignar')
       AND NULLIF(LTRIM(RTRIM(Asesor_Unico)),'') IS NOT NULL)       AS BASE_ASIGNADA_PERSONAS,
    COUNT(*)                                                        AS GESTIONES_AGOSTO,
    COUNT(DISTINCT IDENTIFICACION)                                  AS PERSONAS_GESTIONADAS,
    COUNT(DISTINCT ASESOR)                                          AS ASESORES_ACTIVOS
FROM #GES;

/*--- 2.2 Dispersion de la carga ----------------------------------------------------------*/
WITH POR_ASESOR AS (
    SELECT ASESOR, COUNT(*) AS GESTIONES FROM #GES GROUP BY ASESOR
)
SELECT COUNT(*) AS ASESORES_ACTIVOS, MIN(GESTIONES) AS MINIMO, MAX(GESTIONES) AS MAXIMO,
       AVG(GESTIONES) AS PROMEDIO, SUM(GESTIONES) AS TOTAL_GESTIONES,
       CAST(100.0 * MAX(GESTIONES) / SUM(GESTIONES) AS DECIMAL(5,2)) AS PCT_DEL_MAYOR
FROM POR_ASESOR;

/*--- 2.3 Embudo: gestionadas -> pagaron ---------------------------------------------------*/
WITH GESTIONADAS AS (SELECT DISTINCT IDENTIFICACION FROM #GES),
     PAGARON     AS (SELECT DISTINCT IDENTIFICACION FROM #PAG)
SELECT
    (SELECT COUNT(*) FROM GESTIONADAS)                              AS GESTIONADAS,
    (SELECT COUNT(*) FROM PAGARON)                                  AS CON_PAGO_ATRIBUIBLE,
    (SELECT COUNT(*) FROM GESTIONADAS G JOIN PAGARON P
      ON P.IDENTIFICACION = G.IDENTIFICACION)                       AS GESTIONADAS_Y_PAGARON,
    CAST(100.0 * (SELECT COUNT(*) FROM GESTIONADAS G JOIN PAGARON P
                   ON P.IDENTIFICACION = G.IDENTIFICACION)
         / NULLIF((SELECT COUNT(*) FROM GESTIONADAS),0) AS DECIMAL(5,2)) AS PCT_EFECTIVIDAD;

/*--- 2.4 Cartera sin dueno ----------------------------------------------------------------
        Aqui Asesor_Unico SI es el campo correcto: la pregunta es de asignacion.           */
SELECT
    ISNULL(NULLIF(LTRIM(RTRIM(Asesor_Unico)),''),'(vacio)')         AS ESTADO_ASIGNACION,
    COUNT(*)                                                        AS REGISTROS,
    COUNT(DISTINCT Número_de_identificación)                        AS PERSONAS,
    SUM(CONVERT(int, GESTION_MARCA))                                AS REGISTROS_CON_GESTION
FROM Financiera.Cartera_CUN_Asesor_Unico
WHERE Asesor_Unico IN ('Reasignar en CRM', 'Sin asignar')
   OR NULLIF(LTRIM(RTRIM(Asesor_Unico)), '') IS NULL
GROUP BY Asesor_Unico
ORDER BY REGISTROS DESC;

/*--- 2.5 Tipificaciones aplicadas en agosto -----------------------------------------------*/
SELECT TOP 12
    ISNULL(TIPIFICACION, '(sin tipificar)')                         AS TIPIFICACION,
    COUNT(*)                                                        AS GESTIONES,
    COUNT(DISTINCT IDENTIFICACION)                                  AS PERSONAS,
    CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,2))  AS PCT
FROM #GES GROUP BY TIPIFICACION ORDER BY GESTIONES DESC;

/*--- 2.6 LIQUIDACION: ranking nominal por asesor ------------------------------------------
        Va con nombre por peticion expresa de la Coordinacion (liquidacion de agosto).
        FULL JOIN a proposito: un asesor puede tener pago atribuible sin gestion en agosto,
        cuando la gestion que lo origino fue de un mes anterior. Con un LEFT esos pagos
        desapareceran y el total por asesor no cuadraria con el del equipo.                */
WITH G AS (SELECT ASESOR, COUNT(*) AS GESTIONES,
                  COUNT(DISTINCT IDENTIFICACION) AS PERSONAS_GESTIONADAS
           FROM #GES GROUP BY ASESOR),
     P AS (SELECT ASESOR, COUNT(*) AS PAGOS,
                  COUNT(DISTINCT IDENTIFICACION) AS PERSONAS_CON_PAGO,
                  SUM(VALOR_PAGADO) AS VALOR
           FROM #PAG GROUP BY ASESOR)
SELECT
    ISNULL(G.ASESOR, P.ASESOR)                                      AS ASESOR,
    ISNULL(G.GESTIONES, 0)                                          AS GESTIONES,
    ISNULL(G.PERSONAS_GESTIONADAS, 0)                               AS PERSONAS_GESTIONADAS,
    ISNULL(P.PAGOS, 0)                                              AS PAGOS_ATRIBUIBLES,
    ISNULL(P.PERSONAS_CON_PAGO, 0)                                  AS PERSONAS_CON_PAGO,
    CAST(ISNULL(P.VALOR,0)/1e6 AS DECIMAL(18,1))                    AS VALOR_MM,
    CAST(100.0 * ISNULL(P.PERSONAS_CON_PAGO,0)
         / NULLIF(G.PERSONAS_GESTIONADAS,0) AS DECIMAL(5,2))        AS PCT_EFECTIVIDAD
FROM G FULL JOIN P ON P.ASESOR = G.ASESOR
ORDER BY VALOR_MM DESC;


/*===========================================================================================
  BLOQUE 3 — RECAUDO ATRIBUIBLE A LA GESTION
  OJO: es lo que los asesores marcaron como pagado en el CRM, NO la caja institucional.
===========================================================================================*/

/*--- 3.1 Totales del mes -----------------------------------------------------------------*/
SELECT COUNT(*) AS PAGOS, COUNT(DISTINCT IDENTIFICACION) AS PERSONAS,
       CAST(SUM(VALOR_PAGADO)/1e6 AS DECIMAL(18,1)) AS VALOR_MM,
       CAST(AVG(VALOR_PAGADO) AS DECIMAL(18,0))     AS TICKET_PROMEDIO
FROM #PAG;

/*--- 3.2 Que quedo FUERA del recaudo atribuible, y por que --------------------------------
        Esta es la conciliacion contra los $5.483,9 MM que se publicaron el 2 de septiembre. */
SELECT
    CASE WHEN G.GESTION_MARCA = 0 THEN 'Pago de persona que nadie gestiono'
         ELSE 'Pago anterior a la primera gestion' END              AS MOTIVO_EXCLUSION,
    COUNT(*)                                                        AS PAGOS,
    COUNT(DISTINCT LTRIM(RTRIM(G.Número_de_identificación)))        AS ESTUDIANTES,
    CAST(SUM(TRY_CONVERT(DECIMAL(18,2),
        REPLACE(REPLACE(REPLACE(G.Valor_pagado,'CO$',''),',',''),' ','')))/1e6
        AS DECIMAL(18,1))                                           AS VALOR_MM
FROM Financiera.Cartera_CUN_Asesor_Unico G
WHERE G.Asesor_Unico NOT IN ('Reasignar en CRM','Sin asignar')
  AND NULLIF(LTRIM(RTRIM(G.Asesor_Unico)),'') IS NOT NULL
  AND G.GESTION_PAGO_POST_MARCA = 0
  AND TRY_CONVERT(date, G.Fecha_de_pago, 103) >= '2026-08-01'
  AND TRY_CONVERT(date, G.Fecha_de_pago, 103) <  '2026-09-01'
  AND TRY_CONVERT(DECIMAL(18,2),
        REPLACE(REPLACE(REPLACE(G.Valor_pagado,'CO$',''),',',''),' ','')) > 0
GROUP BY CASE WHEN G.GESTION_MARCA = 0 THEN 'Pago de persona que nadie gestiono'
              ELSE 'Pago anterior a la primera gestion' END;

/*--- 3.3 Por periodo academico -----------------------------------------------------------*/
SELECT TOP 12
    ISNULL(NULLIF(LTRIM(RTRIM(PERIODO)),''),'(sin periodo)')        AS PERIODO,
    COUNT(*) AS PAGOS, COUNT(DISTINCT IDENTIFICACION) AS PERSONAS,
    CAST(SUM(VALOR_PAGADO)/1e6 AS DECIMAL(18,1))                    AS VALOR_MM,
    CAST(100.0 * SUM(VALOR_PAGADO) / SUM(SUM(VALOR_PAGADO)) OVER () AS DECIMAL(5,2)) AS PCT_VALOR
FROM #PAG GROUP BY PERIODO ORDER BY VALOR_MM DESC;

/*--- 3.4 Distribucion del ticket ---------------------------------------------------------*/
SELECT
    CASE WHEN VALOR_PAGADO <   100000 THEN '1. menos de 100k'
         WHEN VALOR_PAGADO <   300000 THEN '2. 100k - 300k'
         WHEN VALOR_PAGADO <   600000 THEN '3. 300k - 600k'
         WHEN VALOR_PAGADO <  1000000 THEN '4. 600k - 1M'
         ELSE                              '5. mas de 1M' END       AS RANGO_TICKET,
    COUNT(*) AS PAGOS,
    CAST(SUM(VALOR_PAGADO)/1e6 AS DECIMAL(18,1))                    AS VALOR_MM
FROM #PAG
GROUP BY CASE WHEN VALOR_PAGADO <   100000 THEN '1. menos de 100k'
              WHEN VALOR_PAGADO <   300000 THEN '2. 100k - 300k'
              WHEN VALOR_PAGADO <   600000 THEN '3. 300k - 600k'
              WHEN VALOR_PAGADO <  1000000 THEN '4. 600k - 1M'
              ELSE                              '5. mas de 1M' END
ORDER BY RANGO_TICKET;
