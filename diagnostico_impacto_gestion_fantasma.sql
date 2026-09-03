/*===========================================================================================
  DIAGNOSTICO — IMPACTO OPERATIVO de las NDB fantasma sobre el equipo de gestion
  -------------------------------------------------------------------------------------------
  Objeto      : Financiera.Cartera_Gestion  x  Financiera.Cartera_CUN_Asesor_Unico
  Autor       : Analitica financiera - Universidad CUN
  Proposito   : Cuantificar cuanto trabajo del equipo de cobranza se esta gastando en
                obligaciones YA PAGADAS. El diagnostico de cartera fantasma probo que
                existen 17.967 cuotas pagadas que siguen vivas; aqui se mide cuantas de
                ellas estan cargadas en la herramienta de gestion, asignadas a un asesor,
                y sobre cuantas se registro gestion real (tipificacion o llamada).

  SOLO LECTURA. No escribe nada.

  Llave de cruce (verificada 1:1 en AMBOS lados, 0 duplicados):
      Cartera_Gestion   : IDENTIFICACION + '-' + PERIODO + '-' + NUMERO_CREDITO
      Cartera_CUN_...   : Documento_Cartera_CUN (que ya viene con ese formato compuesto)

  ⚠ NO cruzar por Número_de_identificación a secas: ambas tablas tienen grano OBLIGACION y
    el cruce por persona produce un cartesiano N×N (283k filas -> 62M en un intento previo).

  ⚠ Toda Cartera_CUN_Asesor_Unico es varchar(MAX) sobre HEAP. Se aplica LTRIM/RTRIM en la
    llave: hay espacios finales que rompen el match silenciosamente.

  CORREGIDO 2026-09-03 — la version anterior media la gestion mal, por partida doble:
    1. El flag GESTIONADA se basaba en que Tipificación_nueva o Fechahora_llamada
       estuvieran pobladas. Esas columnas salen de #Tipificacion_Ultima, que toma la
       ultima tipificacion INCLUYENDO las del bot CUN DIGITAL (54,3% del historico).
       Contaba como "trabajo de asesor sobre deuda inexistente" lo que hizo el robot.
    2. Atribuia el caso al Asesor_Unico, campo disenado para nunca quedar vacio: cuando
       nadie tipifico cae al propietario de la cartera, que jamas la trabajo.

  Ahora la gestion se lee del historico, AL GRANO DE OBLIGACION (#GEST_OBL). No se usa
  GESTION_MARCA de la tabla materializada porque esa columna esta al grano de CEDULA:
  diria que la obligacion fue gestionada cuando en realidad se gestiono otra cuota de la
  misma persona, y aqui la pregunta es exactamente sobre cual cuota se gasto el trabajo.

  Centinelas de Asesor_Unico que NO son personas y no deben contarse como carga de un
  asesor: 'Reasignar en CRM', 'Sin asignar', 'CUN DIGITAL'.

  Salidas (6 conjuntos de resultados):
      1. Cobertura: cuantas fantasmas llegaron a la herramienta y con asesor asignado.
      2. Gestion efectiva ejercida sobre obligaciones ya pagadas (el dato de impacto),
         separando trabajo humano de trabajo del bot.
      3. Carga por asesor: cuantos casos fantasma trabajo cada uno de verdad.
      4. Que se tipifico sobre esas obligaciones (¿los asesores ya detectaron el pago?).
      5. Contraste: tasa de gestion sobre fantasmas vs. sobre cartera real.
      6. Estado de cartera y tipo de cartera en que estan clasificadas las fantasmas.
===========================================================================================*/

IF OBJECT_ID('tempdb..#FANT')     IS NOT NULL DROP TABLE #FANT;
IF OBJECT_ID('tempdb..#CRUCE')    IS NOT NULL DROP TABLE #CRUCE;
IF OBJECT_ID('tempdb..#GEST_OBL') IS NOT NULL DROP TABLE #GEST_OBL;

/*--- Gestion HUMANA al grano de obligacion ------------------------------------------------
      Una fila por Cartera_CUN.Id que alguna vez tuvo una tipificacion de una persona.
      Se guarda la ultima (quien y cuando) y cuantas veces se toco.                    */
SELECT cartera_id, TIPIF_HUMANA, GESTOR_HUMANO, FECHA_HUMANA, TOQUES_HUMANOS
INTO #GEST_OBL
FROM (
    SELECT
        CONVERT(varchar(30), e.Cartera_CUN)                                  AS cartera_id,
        CONVERT(varchar(200), e.Tipificación_nueva)                          AS TIPIF_HUMANA,
        UPPER(LTRIM(RTRIM(CONVERT(varchar(200), e.Hecho_por))))              AS GESTOR_HUMANO,
        COALESCE(TRY_CONVERT(datetime, e.Hora_de_modificación, 103),
                 TRY_CONVERT(datetime, e.Hora_de_creación, 103))             AS FECHA_HUMANA,
        COUNT(*)      OVER (PARTITION BY CONVERT(varchar(30), e.Cartera_CUN)) AS TOQUES_HUMANOS,
        ROW_NUMBER()  OVER (PARTITION BY CONVERT(varchar(30), e.Cartera_CUN)
                            ORDER BY COALESCE(TRY_CONVERT(datetime, e.Hora_de_modificación, 103),
                                              TRY_CONVERT(datetime, e.Hora_de_creación, 103)) DESC,
                                     CONVERT(varchar(30), e.Id) DESC)        AS rn
    FROM [ZOHO].[CRM].[Historico_tipificacion_contact] e
    WHERE e.Cartera_CUN IS NOT NULL
      AND e.Hecho_por   IS NOT NULL
      AND UPPER(e.Hecho_por) NOT LIKE '%CUN DIGITAL%'
      AND UPPER(e.Hecho_por) NOT LIKE '%PENAGOS%'
) x
WHERE x.rn = 1;

CREATE UNIQUE CLUSTERED INDEX IX_tmp_gestobl ON #GEST_OBL (cartera_id);

/*--- Toques del BOT sobre la misma obligacion, para contrastar los dos volumenes ---------*/
IF OBJECT_ID('tempdb..#BOT_OBL') IS NOT NULL DROP TABLE #BOT_OBL;
SELECT CONVERT(varchar(30), e.Cartera_CUN) AS cartera_id, COUNT(*) AS TOQUES_BOT
INTO #BOT_OBL
FROM [ZOHO].[CRM].[Historico_tipificacion_contact] e
WHERE e.Cartera_CUN IS NOT NULL AND e.Hecho_por IS NOT NULL
  AND (UPPER(e.Hecho_por) LIKE '%CUN DIGITAL%' OR UPPER(e.Hecho_por) LIKE '%PENAGOS%')
GROUP BY CONVERT(varchar(30), e.Cartera_CUN);

CREATE UNIQUE CLUSTERED INDEX IX_tmp_botobl ON #BOT_OBL (cartera_id);

/*--- Universo fantasma, con la misma definicion del informe -----------------------------*/
SELECT
    LTRIM(RTRIM(IDENTIFICACION)) + '-' + LTRIM(RTRIM(PERIODO)) + '-'
        + LTRIM(RTRIM(CAST(NUMERO_CREDITO AS varchar(20))))     AS DOC_KEY,
    IDENTIFICACION,
    CAST(VALOR_ORIGINAL AS DECIMAL(18,2))                       AS VALOR_ORIGINAL,
    CAST(TOTAL          AS DECIMAL(18,2))                       AS SALDO_HOY,
    TRY_CONVERT(date, FECHA_VENCIMIENTO, 103)                   AS FEC_VENC
INTO #FANT
FROM Financiera.Cartera_Gestion
WHERE DOCUMENTO = 'NDB'
  AND CAST(VALOR_ORIGINAL AS DECIMAL(18,4)) >= 50000
  AND CAST(TOTAL          AS DECIMAL(18,4)) <  1000
  AND CAST(TOTAL          AS DECIMAL(18,4)) >= 0;

/*--- Cruce contra la herramienta de gestion ---------------------------------------------*/
SELECT
    F.DOC_KEY, F.IDENTIFICACION, F.VALOR_ORIGINAL, F.SALDO_HOY, F.FEC_VENC,
    A.Asesor_Unico                                              AS ASESOR_ASIGNADO,
    G.GESTOR_HUMANO                                             AS GESTIONADO_POR,
    A.Estado_cartera                                            AS ESTADO_CARTERA,
    A.Tipo_de_cartera                                           AS TIPO_CARTERA,
    G.TIPIF_HUMANA                                              AS TIPIFICACION,
    G.FECHA_HUMANA                                              AS FECHA_GESTION,
    ISNULL(G.TOQUES_HUMANOS, 0)                                 AS TOQUES_HUMANOS,
    ISNULL(B.TOQUES_BOT, 0)                                     AS TOQUES_BOT,
    A.Fechahora_llamada                                         AS FECHAHORA_LLAMADA,
    CASE WHEN A.Documento_Cartera_CUN IS NULL                              THEN 'No esta en la herramienta'
         WHEN LTRIM(RTRIM(ISNULL(A.Asesor_Unico,''))) IN ('', 'Reasignar en CRM', 'Sin asignar', 'CUN DIGITAL')
                                                                           THEN 'En la herramienta, sin asesor humano'
         ELSE 'Asignada a un asesor'
    END                                                         AS SITUACION_ASIGNACION,
    /* Gestion REAL de una persona sobre ESTA obligacion. La llamada cuenta aunque no
       haya tipificacion: es trabajo igual. Lo que ya no cuenta es el toque del bot. */
    CASE WHEN G.cartera_id IS NOT NULL
           OR NULLIF(LTRIM(RTRIM(ISNULL(A.Fechahora_llamada,''))),'') IS NOT NULL
         THEN 1 ELSE 0 END                                      AS GESTIONADA
INTO #CRUCE
FROM #FANT F
LEFT JOIN Financiera.Cartera_CUN_Asesor_Unico A
       ON LTRIM(RTRIM(A.Documento_Cartera_CUN)) = F.DOC_KEY
LEFT JOIN #GEST_OBL G ON G.cartera_id = CONVERT(varchar(30), A.Id)
LEFT JOIN #BOT_OBL  B ON B.cartera_id = CONVERT(varchar(30), A.Id);


/*===========================================================================================
  RESULTADO 1 — Cobertura: ¿cuantas obligaciones ya pagadas llegaron a la cola de trabajo?
===========================================================================================*/
SELECT
    SITUACION_ASIGNACION,
    COUNT(*)                                                    AS OBLIGACIONES,
    COUNT(DISTINCT IDENTIFICACION)                              AS PERSONAS,
    CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,2)) AS PCT,
    CAST(SUM(VALOR_ORIGINAL) AS DECIMAL(18,2))                  AS VALOR_ORIGINAL_TOTAL
FROM #CRUCE
GROUP BY SITUACION_ASIGNACION
ORDER BY OBLIGACIONES DESC;


/*===========================================================================================
  RESULTADO 2 — EL DATO DE IMPACTO: gestion efectivamente ejercida sobre cuotas ya pagadas.
  Cada fila con tipificacion o llamada es trabajo de un asesor sobre una deuda inexistente.
===========================================================================================*/
SELECT
    'Fantasmas cargadas en la herramienta de gestion'            AS INDICADOR,
    COUNT(*)                                                    AS OBLIGACIONES,
    COUNT(DISTINCT IDENTIFICACION)                              AS PERSONAS
FROM #CRUCE WHERE SITUACION_ASIGNACION <> 'No esta en la herramienta'
UNION ALL
SELECT 'Fantasmas asignadas a un asesor humano', COUNT(*), COUNT(DISTINCT IDENTIFICACION)
FROM #CRUCE WHERE SITUACION_ASIGNACION = 'Asignada a un asesor'
UNION ALL
SELECT 'Fantasmas CON gestion HUMANA (tipificacion o llamada)', COUNT(*), COUNT(DISTINCT IDENTIFICACION)
FROM #CRUCE WHERE GESTIONADA = 1
UNION ALL
SELECT 'Fantasmas con TIPIFICACION humana', COUNT(*), COUNT(DISTINCT IDENTIFICACION)
FROM #CRUCE WHERE TIPIFICACION IS NOT NULL
UNION ALL
SELECT 'Fantasmas con LLAMADA registrada', COUNT(*), COUNT(DISTINCT IDENTIFICACION)
FROM #CRUCE WHERE NULLIF(LTRIM(RTRIM(ISNULL(FECHAHORA_LLAMADA,''))),'') IS NOT NULL
UNION ALL
/* Contraste: lo que toco SOLO el bot no es trabajo desperdiciado de un asesor, pero si
   mide cuanto ruido genera el robot sobre deuda que ya no existe. */
SELECT 'Fantasmas tocadas SOLO por el bot (no cuentan como trabajo de asesor)',
       COUNT(*), COUNT(DISTINCT IDENTIFICACION)
FROM #CRUCE WHERE GESTIONADA = 0 AND TOQUES_BOT > 0;

/*--- Volumen de toques: humano contra bot sobre la misma poblacion fantasma -------------*/
SELECT
    SUM(TOQUES_HUMANOS)                                         AS TOQUES_HUMANOS,
    SUM(TOQUES_BOT)                                             AS TOQUES_BOT,
    CAST(100.0 * SUM(TOQUES_HUMANOS)
         / NULLIF(SUM(TOQUES_HUMANOS) + SUM(TOQUES_BOT), 0) AS DECIMAL(5,2)) AS PCT_HUMANO
FROM #CRUCE WHERE SITUACION_ASIGNACION <> 'No esta en la herramienta';


/*===========================================================================================
  RESULTADO 3 — Carga por asesor. Dos preguntas distintas, dos columnas distintas:
    CASOS_FANTASMA        : cuantas fantasmas tiene ASIGNADAS  -> Asesor_Unico
    FANTASMA_TRABAJADAS   : sobre cuantas gasto trabajo de verdad -> GESTIONADO_POR
  La version anterior mezclaba las dos y le cargaba al asesor asignado el trabajo del bot.
===========================================================================================*/
WITH COLA_TOTAL AS (
    SELECT LTRIM(RTRIM(Asesor_Unico)) AS ASESOR, COUNT(*) AS CASOS_TOTALES
    FROM Financiera.Cartera_CUN_Asesor_Unico
    GROUP BY LTRIM(RTRIM(Asesor_Unico))
),
FANT_ASIGNADAS AS (
    SELECT LTRIM(RTRIM(ASESOR_ASIGNADO)) AS ASESOR,
           COUNT(*)                        AS CASOS_FANTASMA,
           COUNT(DISTINCT IDENTIFICACION)  AS PERSONAS_FANTASMA
    FROM #CRUCE
    WHERE SITUACION_ASIGNACION = 'Asignada a un asesor'
    GROUP BY LTRIM(RTRIM(ASESOR_ASIGNADO))
),
FANT_TRABAJADAS AS (
    SELECT GESTIONADO_POR AS ASESOR, COUNT(*) AS FANTASMA_TRABAJADAS,
           SUM(TOQUES_HUMANOS) AS TOQUES_DESPERDICIADOS
    FROM #CRUCE
    WHERE GESTIONADO_POR IS NOT NULL
    GROUP BY GESTIONADO_POR
)
SELECT
    ISNULL(A.ASESOR, W.ASESOR)                                  AS ASESOR,
    T.CASOS_TOTALES,
    ISNULL(A.CASOS_FANTASMA, 0)                                 AS CASOS_FANTASMA,
    ISNULL(A.PERSONAS_FANTASMA, 0)                              AS PERSONAS_FANTASMA,
    ISNULL(W.FANTASMA_TRABAJADAS, 0)                            AS FANTASMA_TRABAJADAS,
    ISNULL(W.TOQUES_DESPERDICIADOS, 0)                          AS TOQUES_DESPERDICIADOS,
    CAST(100.0 * ISNULL(A.CASOS_FANTASMA,0)
         / NULLIF(T.CASOS_TOTALES,0) AS DECIMAL(5,2))           AS PCT_DE_SU_COLA
FROM FANT_ASIGNADAS A
FULL JOIN FANT_TRABAJADAS W ON W.ASESOR = A.ASESOR
LEFT JOIN COLA_TOTAL      T ON T.ASESOR = ISNULL(A.ASESOR, W.ASESOR)
ORDER BY FANTASMA_TRABAJADAS DESC, CASOS_FANTASMA DESC;


/*===========================================================================================
  RESULTADO 4 — ¿Que tipificaron los asesores sobre estas obligaciones?
  Si aparecen tipificaciones de "pago" el equipo ya lo detecto en campo y el reporte es el
  que esta desactualizado. Si aparecen compromisos o no-contacto, se gestionaron a ciegas.
===========================================================================================*/
SELECT TOP 25
    LTRIM(RTRIM(TIPIFICACION))                                  AS TIPIFICACION,
    COUNT(*)                                                    AS OBLIGACIONES,
    COUNT(DISTINCT IDENTIFICACION)                              AS PERSONAS
FROM #CRUCE
WHERE NULLIF(LTRIM(RTRIM(ISNULL(TIPIFICACION,''))),'') IS NOT NULL
GROUP BY LTRIM(RTRIM(TIPIFICACION))
ORDER BY OBLIGACIONES DESC;
/* Solo tipificaciones humanas: TIPIFICACION viene de #GEST_OBL. Antes salia de la
   ultima tipificacion cualquiera, asi que el ranking lo dominaba el bot. */


/*===========================================================================================
  RESULTADO 5 — Contraste contra la cartera real. Responde la objecion obvia:
  "¿no sera que esas obligaciones estan ahi pero nadie las trabaja?"
===========================================================================================*/
/* Mismo criterio HUMANO en los dos universos, o el contraste no sirve de nada. */
WITH REAL_ AS (
    SELECT COUNT(*) AS CASOS,
           SUM(CASE WHEN G.cartera_id IS NOT NULL
                      OR NULLIF(LTRIM(RTRIM(ISNULL(A.Fechahora_llamada,''))),'') IS NOT NULL
                    THEN 1 ELSE 0 END) AS GESTIONADOS
    FROM Financiera.Cartera_CUN_Asesor_Unico A
    LEFT JOIN #GEST_OBL G ON G.cartera_id = CONVERT(varchar(30), A.Id)
    WHERE NOT EXISTS (SELECT 1 FROM #FANT F WHERE F.DOC_KEY = LTRIM(RTRIM(A.Documento_Cartera_CUN)))
)
SELECT 'Cartera REAL (deuda vigente)' AS UNIVERSO,
       CASOS AS OBLIGACIONES, GESTIONADOS AS CON_GESTION,
       CAST(100.0*GESTIONADOS/NULLIF(CASOS,0) AS DECIMAL(5,2)) AS PCT_GESTIONADO
FROM REAL_
UNION ALL
SELECT 'Cartera FANTASMA (ya pagada)', COUNT(*), SUM(GESTIONADA),
       CAST(100.0*SUM(GESTIONADA)/NULLIF(COUNT(*),0) AS DECIMAL(5,2))
FROM #CRUCE WHERE SITUACION_ASIGNACION <> 'No esta en la herramienta';


/*===========================================================================================
  RESULTADO 6 — Como esta clasificada la cartera fantasma dentro de la herramienta.
===========================================================================================*/
SELECT
    ISNULL(NULLIF(LTRIM(RTRIM(ESTADO_CARTERA)),''), 'SIN DATO') AS ESTADO_CARTERA,
    ISNULL(NULLIF(LTRIM(RTRIM(TIPO_CARTERA)),''),   'SIN DATO') AS TIPO_CARTERA,
    COUNT(*)                                                    AS OBLIGACIONES,
    SUM(GESTIONADA)                                             AS CON_GESTION
FROM #CRUCE
WHERE SITUACION_ASIGNACION <> 'No esta en la herramienta'
GROUP BY ISNULL(NULLIF(LTRIM(RTRIM(ESTADO_CARTERA)),''), 'SIN DATO'),
         ISNULL(NULLIF(LTRIM(RTRIM(TIPO_CARTERA)),''),   'SIN DATO')
ORDER BY OBLIGACIONES DESC;
