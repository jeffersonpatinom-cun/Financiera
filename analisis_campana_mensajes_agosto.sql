/*===========================================================================================
  ANALISIS — CAMPANA DE MENSAJES PREVENTIVOS (WhatsApp / SMS)   Agosto 2026
  -------------------------------------------------------------------------------------------
  Autor    : Analitica financiera - Universidad CUN
  Objeto   : Financiera.Cartera_CUN_Asesor_Unico, campos [Plantilla] y [Población]
  Ref      : Logica_Estructura_Mensajes_Preventivos.md

  QUE MIDE. La gestion que NO ejecuta un asesor sino la automatizacion de envio de
  mensajes configurada en Zoho. Se aisla el universo que NO cruza con gestion de
  asesor (GESTION_MARCA = 0) para que ningun pago se cuente dos veces: lo que aqui
  se atribuye a la campana es lo que ningun asesor toco.

  NOMENCLATURA. [Plantilla] codifica CANAL_POBLACION_MOMENTO:
      CANAL     WA (WhatsApp) | SMS
      POBLACION P1 nuevos | P2 antiguos/reingreso | P3 pagos parciales
      MOMENTO   PRE (3 dias antes del vencimiento) | M01 | M03 | M08 (dias despues)

  ⚠ LIMITACION CENTRAL — ESTO NO PRUEBA QUE EL MENSAJE SE HAYA ENVIADO.
  Los campos [Plantilla] y [Población] describen la automatizacion CONFIGURADA en
  Zoho: que plantilla le corresponde a ese registro. NO son un acuse del proveedor.
  Con la informacion disponible hoy NO se puede establecer:
      - si el mensaje efectivamente salio,
      - en que fecha y hora salio,
      - si fue entregado al dispositivo,
      - si fue leido, ni si hubo respuesta.
  Todo eso vive en la API de WhatsApp Meta, que aun no esta integrada. Mientras no
  lo este, las cifras de este bloque son un TECHO de impacto potencial, no recaudo
  demostrado, y la atribucion es por COINCIDENCIA (el registro tenia plantilla y
  pago), no por causalidad.

  ⚠ SIN FECHA DE ENVIO NO HAY REGLA DE ANTERIORIDAD. Al recaudo de asesores se le
  exige que el pago sea POSTERIOR a la primera gestion (GESTION_PAGO_POST_MARCA).
  Aqui esa regla no se puede aplicar porque no hay fecha del mensaje. Es una
  atribucion estrictamente mas debil y no debe compararse de igual a igual contra
  la del equipo humano.

  ⚠ [Población] esta poblada al 100% de la tabla: es el SEGMENTO del estudiante, no
  evidencia de envio. Filtrar campana por [Población] mide toda la cartera. El unico
  campo que indica que hay una plantilla asignada es [Plantilla] (9,75% de filas).

  ⚠ La tabla es foto del dia: [Plantilla] se sobrescribe en cada corrida. Lo que se
  asigno en agosto y cambio despues ya no se ve. Las cifras son un piso.

  ⚠⚠ CONFUSION MEDIDA (bloque 8) — NO LEER LA CONVERSION POR MOMENTO COMO EFECTO.
  Fecha_de_pago esta poblada en el 92,3% de las filas SIN marca academica y en solo
  el 0,1% de las que SI la tienen: registrar pago es, en la practica, propiedad de
  haber salido ya de Cartera_Gestion, no del mensaje. Y el MOMENTO correlaciona casi
  perfecto con esa composicion:
        M01  98% sin marca      PRE  48%      M03  22%      M08  18%
  Por eso la lectura ingenua da PRE/M01 en 42% y M03/M08 en 9%: es la mezcla de
  poblacion, no el disparo. Los bloques 3, 4 y 5 quedan como descriptivos y NO
  soportan conclusiones de efectividad por momento, segmento ni canal.

  La unica comparacion con algo de control esta en el bloque 8.2: dentro de la misma
  poblacion (sin marca academica), CON plantilla paga 57,1% y SIN plantilla 38,3%.
  La diferencia de 18,8 puntos es sugerente pero TAMPOCO es causal: no hay
  asignacion aleatoria, la plantilla se asigna por criterios que se correlacionan
  con la propension a pagar, y sigue sin haber fecha de envio.
===========================================================================================*/

IF OBJECT_ID('tempdb..#CAMP') IS NOT NULL DROP TABLE #CAMP;

/* Universo de campana PURA: tiene plantilla asignada y NINGUN asesor lo gestiono.
   Se normaliza el prefijo 'Plantilla ' que traen 9 filas sucias del CRM. */
SELECT
    LTRIM(RTRIM(REPLACE(LTRIM(RTRIM(G.Plantilla)), 'Plantilla ', '')))  AS PLANTILLA,
    LTRIM(RTRIM(G.[Población]))                                         AS POBLACION_CAMPO,
    LTRIM(RTRIM(G.Número_de_identificación))                            AS IDENTIFICACION,
    G.Número_de_crédito                                                 AS NUMERO_CREDITO,
    G.Periodo                                                           AS PERIODO,
    G.MARCA_ACADEMICA_GESTION                                           AS MARCA_ACADEMICA,
    G.CLASIFICACION_CARTERA                                             AS CLASIFICACION_CARTERA,
    TRY_CONVERT(date, G.Fecha_de_pago, 103)                             AS FECHA_PAGO,
    TRY_CONVERT(DECIMAL(18,2),
        REPLACE(REPLACE(REPLACE(G.Valor_pagado,'CO$',''),',',''),' ','')) AS VALOR_PAGADO
INTO #CAMP
FROM Financiera.Cartera_CUN_Asesor_Unico G
WHERE NULLIF(LTRIM(RTRIM(G.Plantilla)),'') IS NOT NULL
  AND G.GESTION_MARCA = 0;          /* sin cruce con asesor: evita doble conteo */

/* Descomposicion del codigo. PARSENAME invierte el orden de los tramos separados por
   punto, asi que se cambia '_' por '.' y se leen las posiciones al reves:
   WA_P1_PRE -> WA.P1.PRE -> parte 3 = WA, parte 2 = P1, parte 1 = PRE. */
ALTER TABLE #CAMP ADD CANAL varchar(10), SEGMENTO varchar(10), MOMENTO varchar(10);
UPDATE #CAMP SET
    CANAL    = PARSENAME(REPLACE(PLANTILLA, '_', '.'), 3),
    SEGMENTO = PARSENAME(REPLACE(PLANTILLA, '_', '.'), 2),
    MOMENTO  = PARSENAME(REPLACE(PLANTILLA, '_', '.'), 1);


/*===========================================================================================
  1 — Cobertura: cuanto de la cartera tiene plantilla asignada y cuanto es campana pura
===========================================================================================*/
SELECT
    COUNT(*)                                                            AS FILAS_TOTALES,
    SUM(CASE WHEN NULLIF(LTRIM(RTRIM(Plantilla)),'') IS NOT NULL
             THEN 1 ELSE 0 END)                                         AS CON_PLANTILLA,
    SUM(CASE WHEN NULLIF(LTRIM(RTRIM(Plantilla)),'') IS NOT NULL
              AND GESTION_MARCA = 1 THEN 1 ELSE 0 END)                  AS PLANTILLA_Y_ASESOR,
    SUM(CASE WHEN NULLIF(LTRIM(RTRIM(Plantilla)),'') IS NOT NULL
              AND GESTION_MARCA = 0 THEN 1 ELSE 0 END)                  AS CAMPANA_PURA,
    COUNT(DISTINCT CASE WHEN NULLIF(LTRIM(RTRIM(Plantilla)),'') IS NOT NULL
                         AND GESTION_MARCA = 0
                        THEN LTRIM(RTRIM(Número_de_identificación)) END) AS PERSONAS_CAMPANA_PURA
FROM Financiera.Cartera_CUN_Asesor_Unico;

/*--- 1.1 El campo Población NO indica envio: esta al 100% de la tabla -------------------*/
SELECT ISNULL(NULLIF(LTRIM(RTRIM([Población])),''), '(vacio)')          AS POBLACION,
       COUNT(*)                                                         AS FILAS,
       COUNT(DISTINCT LTRIM(RTRIM(Número_de_identificación)))           AS PERSONAS,
       SUM(CASE WHEN NULLIF(LTRIM(RTRIM(Plantilla)),'') IS NOT NULL
                THEN 1 ELSE 0 END)                                      AS DE_ESAS_CON_PLANTILLA
FROM Financiera.Cartera_CUN_Asesor_Unico
GROUP BY ISNULL(NULLIF(LTRIM(RTRIM([Población])),''), '(vacio)')
ORDER BY FILAS DESC;


/*===========================================================================================
  2 — Impactos y pago por PLANTILLA (campana pura, pagos de agosto)
===========================================================================================*/
SELECT
    PLANTILLA, CANAL, SEGMENTO, MOMENTO,
    COUNT(*)                                                            AS IMPACTOS,
    COUNT(DISTINCT IDENTIFICACION)                                      AS PERSONAS,
    SUM(CASE WHEN FECHA_PAGO >= '2026-08-01' AND FECHA_PAGO < '2026-09-01'
              AND VALOR_PAGADO > 0 THEN 1 ELSE 0 END)                   AS PAGOS,
    CAST(SUM(CASE WHEN FECHA_PAGO >= '2026-08-01' AND FECHA_PAGO < '2026-09-01'
                   AND VALOR_PAGADO > 0 THEN VALOR_PAGADO ELSE 0 END)/1e6
         AS DECIMAL(18,1))                                              AS VALOR_MM,
    CAST(100.0 * SUM(CASE WHEN FECHA_PAGO >= '2026-08-01' AND FECHA_PAGO < '2026-09-01'
                           AND VALOR_PAGADO > 0 THEN 1 ELSE 0 END)
         / COUNT(*) AS DECIMAL(5,2))                                    AS PCT_CONVERSION
FROM #CAMP
GROUP BY PLANTILLA, CANAL, SEGMENTO, MOMENTO
ORDER BY VALOR_MM DESC;


/*===========================================================================================
  3 — Por MOMENTO de envio: ¿rinde mas el preventivo o la mora?
      Es la lectura accionable: PRE es cobro oportuno, M08 es cierre de gestion preventiva.
===========================================================================================*/
SELECT
    MOMENTO,
    CASE MOMENTO WHEN 'PRE' THEN '3 dias ANTES del vencimiento'
                 WHEN 'M01' THEN '1 dia despues'
                 WHEN 'M03' THEN '3 dias despues'
                 WHEN 'M08' THEN '8 dias despues' ELSE '(otro)' END     AS DISPARO,
    COUNT(*)                                                            AS IMPACTOS,
    COUNT(DISTINCT IDENTIFICACION)                                      AS PERSONAS,
    SUM(CASE WHEN FECHA_PAGO >= '2026-08-01' AND FECHA_PAGO < '2026-09-01'
              AND VALOR_PAGADO > 0 THEN 1 ELSE 0 END)                   AS PAGOS,
    CAST(SUM(CASE WHEN FECHA_PAGO >= '2026-08-01' AND FECHA_PAGO < '2026-09-01'
                   AND VALOR_PAGADO > 0 THEN VALOR_PAGADO ELSE 0 END)/1e6
         AS DECIMAL(18,1))                                              AS VALOR_MM,
    CAST(100.0 * SUM(CASE WHEN FECHA_PAGO >= '2026-08-01' AND FECHA_PAGO < '2026-09-01'
                           AND VALOR_PAGADO > 0 THEN 1 ELSE 0 END)
         / COUNT(*) AS DECIMAL(5,2))                                    AS PCT_CONVERSION
FROM #CAMP GROUP BY MOMENTO ORDER BY PCT_CONVERSION DESC;


/*===========================================================================================
  4 — Por SEGMENTO de poblacion (P1 nuevos / P2 antiguos / P3 pagos parciales)
===========================================================================================*/
SELECT
    SEGMENTO,
    CASE SEGMENTO WHEN 'P1' THEN 'Nuevos'
                  WHEN 'P2' THEN 'Antiguos / reingreso'
                  WHEN 'P3' THEN 'Pagos parciales' ELSE '(otro)' END    AS PERFIL,
    COUNT(*)                                                            AS IMPACTOS,
    COUNT(DISTINCT IDENTIFICACION)                                      AS PERSONAS,
    SUM(CASE WHEN FECHA_PAGO >= '2026-08-01' AND FECHA_PAGO < '2026-09-01'
              AND VALOR_PAGADO > 0 THEN 1 ELSE 0 END)                   AS PAGOS,
    CAST(SUM(CASE WHEN FECHA_PAGO >= '2026-08-01' AND FECHA_PAGO < '2026-09-01'
                   AND VALOR_PAGADO > 0 THEN VALOR_PAGADO ELSE 0 END)/1e6
         AS DECIMAL(18,1))                                              AS VALOR_MM,
    CAST(100.0 * SUM(CASE WHEN FECHA_PAGO >= '2026-08-01' AND FECHA_PAGO < '2026-09-01'
                           AND VALOR_PAGADO > 0 THEN 1 ELSE 0 END)
         / COUNT(*) AS DECIMAL(5,2))                                    AS PCT_CONVERSION
FROM #CAMP GROUP BY SEGMENTO ORDER BY VALOR_MM DESC;


/*===========================================================================================
  5 — Por CANAL. Sirve para verificar si el SMS esta operando: el documento define 12
      plantillas SMS_*, y si no aparece ninguna es que ese canal no se esta registrando.
===========================================================================================*/
SELECT
    CANAL, COUNT(*) AS IMPACTOS, COUNT(DISTINCT IDENTIFICACION) AS PERSONAS,
    SUM(CASE WHEN FECHA_PAGO >= '2026-08-01' AND FECHA_PAGO < '2026-09-01'
              AND VALOR_PAGADO > 0 THEN 1 ELSE 0 END)                   AS PAGOS,
    CAST(SUM(CASE WHEN FECHA_PAGO >= '2026-08-01' AND FECHA_PAGO < '2026-09-01'
                   AND VALOR_PAGADO > 0 THEN VALOR_PAGADO ELSE 0 END)/1e6
         AS DECIMAL(18,1))                                              AS VALOR_MM
FROM #CAMP GROUP BY CANAL ORDER BY IMPACTOS DESC;


/*===========================================================================================
  6 — Total de la campana pura, para el informe
===========================================================================================*/
SELECT
    COUNT(*)                                                            AS IMPACTOS,
    COUNT(DISTINCT IDENTIFICACION)                                      AS PERSONAS,
    SUM(CASE WHEN FECHA_PAGO >= '2026-08-01' AND FECHA_PAGO < '2026-09-01'
              AND VALOR_PAGADO > 0 THEN 1 ELSE 0 END)                   AS PAGOS,
    COUNT(DISTINCT CASE WHEN FECHA_PAGO >= '2026-08-01' AND FECHA_PAGO < '2026-09-01'
                         AND VALOR_PAGADO > 0 THEN IDENTIFICACION END)  AS PERSONAS_CON_PAGO,
    CAST(SUM(CASE WHEN FECHA_PAGO >= '2026-08-01' AND FECHA_PAGO < '2026-09-01'
                   AND VALOR_PAGADO > 0 THEN VALOR_PAGADO ELSE 0 END)/1e6
         AS DECIMAL(18,1))                                              AS VALOR_MM
FROM #CAMP;

/*===========================================================================================
  7 — Marca academica de la poblacion impactada: a quien le esta llegando la campana
===========================================================================================*/
SELECT TOP 8
    ISNULL(NULLIF(LTRIM(RTRIM(MARCA_ACADEMICA)),''),'(sin marca)')      AS MARCA_ACADEMICA,
    COUNT(*)                                                            AS IMPACTOS,
    SUM(CASE WHEN FECHA_PAGO >= '2026-08-01' AND FECHA_PAGO < '2026-09-01'
              AND VALOR_PAGADO > 0 THEN 1 ELSE 0 END)                   AS PAGOS,
    CAST(100.0 * SUM(CASE WHEN FECHA_PAGO >= '2026-08-01' AND FECHA_PAGO < '2026-09-01'
                           AND VALOR_PAGADO > 0 THEN 1 ELSE 0 END)
         / COUNT(*) AS DECIMAL(5,2))                                    AS PCT_CONVERSION
FROM #CAMP
GROUP BY ISNULL(NULLIF(LTRIM(RTRIM(MARCA_ACADEMICA)),''),'(sin marca)')
ORDER BY IMPACTOS DESC;


/*===========================================================================================
  8 — DIAGNOSTICO DE LA CONFUSION. Es lo que impide leer los bloques 3-5 como efectividad.
===========================================================================================*/

/*--- 8.1 Fecha_de_pago casi solo existe fuera de Cartera_Gestion -------------------------
        Es decir: "tener pago registrado" equivale, en la practica, a "ya salio de la
        cartera activa". No es una senal que la campana pueda reclamar.              */
SELECT
    CASE WHEN MARCA_ACADEMICA_GESTION IS NULL THEN 'SIN marca (no cruza Cartera_Gestion)'
         ELSE 'CON marca (esta en Cartera_Gestion)' END                 AS GRUPO,
    COUNT(*)                                                            AS FILAS,
    SUM(CASE WHEN NULLIF(LTRIM(RTRIM(Fecha_de_pago)),'') IS NOT NULL
             THEN 1 ELSE 0 END)                                         AS CON_FECHA_PAGO,
    CAST(100.0 * SUM(CASE WHEN NULLIF(LTRIM(RTRIM(Fecha_de_pago)),'') IS NOT NULL
                          THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS PCT
FROM Financiera.Cartera_CUN_Asesor_Unico
GROUP BY CASE WHEN MARCA_ACADEMICA_GESTION IS NULL THEN 'SIN marca (no cruza Cartera_Gestion)'
              ELSE 'CON marca (esta en Cartera_Gestion)' END;

/*--- 8.2 La UNICA comparacion con grupo de control ---------------------------------------
        Se restringe a poblacion comparable (sin marca academica, donde el pago si se
        registra) y se contrasta contra quienes NO recibieron plantilla. Sugerente,
        no causal: la plantilla no se asigna al azar.                                */
SELECT
    CASE WHEN NULLIF(LTRIM(RTRIM(Plantilla)),'') IS NOT NULL THEN 'CON plantilla'
         ELSE 'SIN plantilla (control)' END                             AS GRUPO,
    COUNT(*)                                                            AS FILAS,
    SUM(CASE WHEN TRY_CONVERT(date, Fecha_de_pago,103) >= '2026-08-01'
              AND TRY_CONVERT(date, Fecha_de_pago,103) <  '2026-09-01'
              AND TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(REPLACE(
                  Valor_pagado,'CO$',''),',',''),' ','')) > 0
             THEN 1 ELSE 0 END)                                         AS PAGOS,
    CAST(100.0 * SUM(CASE WHEN TRY_CONVERT(date, Fecha_de_pago,103) >= '2026-08-01'
                           AND TRY_CONVERT(date, Fecha_de_pago,103) <  '2026-09-01'
                           AND TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(REPLACE(
                               Valor_pagado,'CO$',''),',',''),' ','')) > 0
                          THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS PCT_PAGO
FROM Financiera.Cartera_CUN_Asesor_Unico
WHERE GESTION_MARCA = 0 AND MARCA_ACADEMICA_GESTION IS NULL
GROUP BY CASE WHEN NULLIF(LTRIM(RTRIM(Plantilla)),'') IS NOT NULL THEN 'CON plantilla'
              ELSE 'SIN plantilla (control)' END;

/*--- 8.3 El momento esta confundido con la composicion de la poblacion -------------------
        Ordenado por % sin marca: reproduce exactamente el orden de la "conversion"
        del bloque 3, que es la prueba de que ese bloque no mide el disparo.        */
SELECT
    PARSENAME(REPLACE(PLANTILLA, '_', '.'), 1)                          AS MOMENTO,
    SUM(CASE WHEN MARCA_ACADEMICA IS NULL THEN 1 ELSE 0 END)            AS SIN_MARCA,
    SUM(CASE WHEN MARCA_ACADEMICA IS NOT NULL THEN 1 ELSE 0 END)        AS CON_MARCA,
    COUNT(*)                                                            AS TOTAL,
    CAST(100.0 * SUM(CASE WHEN MARCA_ACADEMICA IS NULL THEN 1 ELSE 0 END)
         / COUNT(*) AS DECIMAL(5,2))                                    AS PCT_SIN_MARCA
FROM #CAMP
GROUP BY PARSENAME(REPLACE(PLANTILLA, '_', '.'), 1)
ORDER BY PCT_SIN_MARCA DESC;
