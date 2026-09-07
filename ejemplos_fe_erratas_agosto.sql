/*===========================================================================================
  EJEMPLOS CONCRETOS PARA SUSTENTAR LA FE DE ERRATAS — cierre de agosto 2026
  -------------------------------------------------------------------------------------------
  Autor : Analitica financiera - Universidad CUN
  Objeto: [Financiera].[Cartera_CUN_Asesor_Unico]
  Corte : extraccion del 2026-09-07 (la tabla es foto diaria: las cifras se mueven)

  Para que sirve: en vez de discutir porcentajes, mostrar cedulas puntuales donde se ve
  el error. Cada bloque devuelve casos que se pueden abrir uno por uno en el CRM.

  Los cuatro casos, en el orden en que conviene contarlos:
     A. El bot tipifico y el sistema se lo acredito a un asesor humano.  <- el error
     B. Pago de una persona que NADIE gestiono.                          <- $1.807,3 MM
     C. Pago ANTERIOR a la primera gestion del asesor.                   <- $1.391,0 MM
     D. Gestion y pago bien atribuidos.                                  <- el contraejemplo

  ⚠ Estas consultas devuelven numeros de identificacion: son datos personales. Sirven
    para sustentar internamente ante la Coordinacion, que ya tiene acceso a la base
    completa. No pegar cedulas en documentos que circulen fuera de esa conversacion.
===========================================================================================*/

DECLARE @ini date = '2026-08-01', @fin date = '2026-09-01';

/*===========================================================================================
  CASO A — El bot tipifico, el sistema se lo acredito a un asesor
  -------------------------------------------------------------------------------------------
  Asesor_Unico trae el nombre de una persona real, asi que el filtro viejo
  (NOT IN 'Reasignar en CRM','Sin asignar') los contaba como gestionados. Pero la
  tipificacion la hizo CUN DIGITAL y GESTION_MARCA es 0: nadie los trabajo.
  Es exactamente el mecanismo que inflo las gestiones de 22.941 a 61.767.
===========================================================================================*/
SELECT TOP 10
    'A. El bot tipifico, se acredito a un asesor'       AS CASO,
    LTRIM(RTRIM(G.[Número_de_identificación]))          AS IDENTIFICACION,
    LTRIM(RTRIM(G.Asesor_Unico))                        AS ASESOR_QUE_SE_ACREDITABA,
    G.Hecho_por                                         AS QUIEN_TIPIFICO_DE_VERDAD,
    G.Hora_modificacion_tipif                           AS FECHA_TIPIFICACION,
    G.GESTION_MARCA                                     AS TUVO_GESTION_HUMANA,
    G.GESTION_ASESOR                                    AS GESTOR_REAL,
    G.[Número_de_crédito]                               AS NUMERO_CREDITO
FROM Financiera.Cartera_CUN_Asesor_Unico G
WHERE G.Asesor_Unico NOT IN ('Reasignar en CRM','Sin asignar')
  AND NULLIF(LTRIM(RTRIM(G.Asesor_Unico)),'') IS NOT NULL
  AND G.GESTION_MARCA = 0                       -- nadie lo gestiono
  AND UPPER(G.Hecho_por) LIKE '%CUN DIGITAL%'   -- pero el bot si lo toco
  AND TRY_CONVERT(datetime, G.Hora_modificacion_tipif, 103) >= @ini
  AND TRY_CONVERT(datetime, G.Hora_modificacion_tipif, 103) <  @fin
ORDER BY TRY_CONVERT(datetime, G.Hora_modificacion_tipif, 103) DESC;


/*===========================================================================================
  CASO B — Pago de una persona que NADIE gestiono
  -------------------------------------------------------------------------------------------
  El criterio viejo sumaba cualquier pago de cartera asignada. Estas personas pagaron
  en agosto sin que ningun asesor las contactara nunca: el pago llego solo. Son 4.983
  pagos por $1.807,3 MM que se estaban reportando como recaudo del equipo.
===========================================================================================*/
SELECT TOP 10
    'B. Pago sin ninguna gestion previa'                AS CASO,
    LTRIM(RTRIM(G.[Número_de_identificación]))          AS IDENTIFICACION,
    LTRIM(RTRIM(G.Asesor_Unico))                        AS ASESOR_QUE_SE_ACREDITABA,
    G.GESTION_MARCA                                     AS TUVO_GESTION_HUMANA,
    G.[Fecha_de_pago]                                   AS FECHA_PAGO,
    TRY_CONVERT(DECIMAL(18,2),
        REPLACE(REPLACE(REPLACE(G.Valor_pagado,'CO$',''),',',''),' ','')) AS VALOR_PAGADO,
    G.[Número_de_crédito]                               AS NUMERO_CREDITO
FROM Financiera.Cartera_CUN_Asesor_Unico G
WHERE G.Asesor_Unico NOT IN ('Reasignar en CRM','Sin asignar')
  AND NULLIF(LTRIM(RTRIM(G.Asesor_Unico)),'') IS NOT NULL
  AND G.GESTION_MARCA = 0
  /* Solo estudiantes: el pago mas alto sin gestion es un NIT (899999035), un
     convenio con miles de creditos. Como ejemplo confunde en vez de explicar. */
  AND G.[Tipo_cliente] = 'ESTUDIANTES'
  AND TRY_CONVERT(date, G.[Fecha_de_pago], 103) >= @ini
  AND TRY_CONVERT(date, G.[Fecha_de_pago], 103) <  @fin
  AND TRY_CONVERT(DECIMAL(18,2),
        REPLACE(REPLACE(REPLACE(G.Valor_pagado,'CO$',''),',',''),' ','')) > 0
ORDER BY TRY_CONVERT(DECIMAL(18,2),
        REPLACE(REPLACE(REPLACE(G.Valor_pagado,'CO$',''),',',''),' ','')) DESC;


/*===========================================================================================
  CASO C — El pago llego ANTES de que el asesor tocara el caso
  -------------------------------------------------------------------------------------------
  Aqui si hubo gestion humana, pero el estudiante ya habia pagado cuando el asesor lo
  contacto. La columna DIAS_ANTES dice cuantos dias antes del primer contacto se pago.
  Son 5.269 pagos por $1.391,0 MM. Este es el CAMBIO DE CRITERIO, no un error: la cifra
  anterior estaba bien calculada, pero medía otra cosa.
===========================================================================================*/
SELECT TOP 10
    'C. Pago anterior a la primera gestion'             AS CASO,
    LTRIM(RTRIM(G.[Número_de_identificación]))          AS IDENTIFICACION,
    G.GESTION_ASESOR                                    AS ASESOR_QUE_GESTIONO,
    G.[Fecha_de_pago]                                   AS FECHA_PAGO,
    G.GESTION_FECHA_PRIMERA                             AS PRIMERA_GESTION,
    DATEDIFF(DAY, TRY_CONVERT(date, G.[Fecha_de_pago], 103),
                  CAST(G.GESTION_FECHA_PRIMERA AS date)) AS DIAS_ANTES,
    TRY_CONVERT(DECIMAL(18,2),
        REPLACE(REPLACE(REPLACE(G.Valor_pagado,'CO$',''),',',''),' ','')) AS VALOR_PAGADO
FROM Financiera.Cartera_CUN_Asesor_Unico G
WHERE G.GESTION_MARCA = 1
  AND G.GESTION_PAGO_POST_MARCA = 0             -- hubo gestion, pero el pago es anterior
  AND G.[Tipo_cliente] = 'ESTUDIANTES'
  /* La primera gestion tambien dentro de agosto: asi el caso se cuenta solo
     ("pago el 5, lo llamaron el 20"). Sin este filtro dominan las gestiones de
     septiembre, que son otra historia -- en el cierre aun no los habian tocado. */
  AND G.GESTION_FECHA_PRIMERA >= @ini
  AND G.GESTION_FECHA_PRIMERA <  @fin
  AND TRY_CONVERT(date, G.[Fecha_de_pago], 103) >= @ini
  AND TRY_CONVERT(date, G.[Fecha_de_pago], 103) <  @fin
  AND TRY_CONVERT(DECIMAL(18,2),
        REPLACE(REPLACE(REPLACE(G.Valor_pagado,'CO$',''),',',''),' ','')) > 0
ORDER BY DIAS_ANTES DESC;


/*===========================================================================================
  CASO D — Contraejemplo: gestion y pago bien atribuidos
  -------------------------------------------------------------------------------------------
  Se incluye a proposito para mostrar que el criterio nuevo no castiga al equipo: el
  asesor contacto, y despues llego el pago. DIAS_DESPUES es el tiempo de respuesta.
  Estos son los 9.280 pagos / $2.408,0 MM que si se le atribuyen al equipo.
===========================================================================================*/
SELECT TOP 10
    'D. Gestion y pago bien atribuidos'                 AS CASO,
    LTRIM(RTRIM(G.[Número_de_identificación]))          AS IDENTIFICACION,
    G.GESTION_ASESOR                                    AS ASESOR_QUE_GESTIONO,
    G.GESTION_FECHA_PRIMERA                             AS PRIMERA_GESTION,
    G.[Fecha_de_pago]                                   AS FECHA_PAGO,
    DATEDIFF(DAY, CAST(G.GESTION_FECHA_PRIMERA AS date),
                  TRY_CONVERT(date, G.[Fecha_de_pago], 103)) AS DIAS_DESPUES,
    TRY_CONVERT(DECIMAL(18,2),
        REPLACE(REPLACE(REPLACE(G.Valor_pagado,'CO$',''),',',''),' ','')) AS VALOR_PAGADO
FROM Financiera.Cartera_CUN_Asesor_Unico G
WHERE G.GESTION_PAGO_POST_MARCA = 1
  AND G.[Tipo_cliente] = 'ESTUDIANTES'
  AND TRY_CONVERT(date, G.[Fecha_de_pago], 103) >= @ini
  AND TRY_CONVERT(date, G.[Fecha_de_pago], 103) <  @fin
  AND TRY_CONVERT(DECIMAL(18,2),
        REPLACE(REPLACE(REPLACE(G.Valor_pagado,'CO$',''),',',''),' ','')) > 0
ORDER BY TRY_CONVERT(DECIMAL(18,2),
        REPLACE(REPLACE(REPLACE(G.Valor_pagado,'CO$',''),',',''),' ','')) DESC;


/*===========================================================================================
  RESUMEN — cuantas cedulas hay de cada caso, para dimensionar los ejemplos
===========================================================================================*/
SELECT
    CASE WHEN G.GESTION_MARCA = 0 AND UPPER(G.Hecho_por) LIKE '%CUN DIGITAL%'
              THEN 'A. Bot tipifico, acreditado a un asesor'
         WHEN G.GESTION_MARCA = 0
              THEN 'B. Pago sin ninguna gestion previa'
         WHEN G.GESTION_PAGO_POST_MARCA = 0
              THEN 'C. Pago anterior a la primera gestion'
         ELSE 'D. Gestion y pago bien atribuidos' END  AS CASO,
    COUNT(*)                                           AS REGISTROS,
    COUNT(DISTINCT LTRIM(RTRIM(G.[Número_de_identificación]))) AS PERSONAS,
    CAST(SUM(TRY_CONVERT(DECIMAL(18,2),
        REPLACE(REPLACE(REPLACE(G.Valor_pagado,'CO$',''),',',''),' ','')))/1e6
        AS DECIMAL(18,1))                              AS VALOR_MM
FROM Financiera.Cartera_CUN_Asesor_Unico G
WHERE G.Asesor_Unico NOT IN ('Reasignar en CRM','Sin asignar')
  AND NULLIF(LTRIM(RTRIM(G.Asesor_Unico)),'') IS NOT NULL
  AND TRY_CONVERT(date, G.[Fecha_de_pago], 103) >= @ini
  AND TRY_CONVERT(date, G.[Fecha_de_pago], 103) <  @fin
  AND TRY_CONVERT(DECIMAL(18,2),
        REPLACE(REPLACE(REPLACE(G.Valor_pagado,'CO$',''),',',''),' ','')) > 0
GROUP BY
    CASE WHEN G.GESTION_MARCA = 0 AND UPPER(G.Hecho_por) LIKE '%CUN DIGITAL%'
              THEN 'A. Bot tipifico, acreditado a un asesor'
         WHEN G.GESTION_MARCA = 0
              THEN 'B. Pago sin ninguna gestion previa'
         WHEN G.GESTION_PAGO_POST_MARCA = 0
              THEN 'C. Pago anterior a la primera gestion'
         ELSE 'D. Gestion y pago bien atribuidos' END
ORDER BY CASO;
