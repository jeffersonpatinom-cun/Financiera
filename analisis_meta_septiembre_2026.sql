/*===========================================================================================
  ANALISIS DESCRIPTIVO — Meta Comercial SEPTIEMBRE 2026
  -------------------------------------------------------------------------------------------
  Objeto   : [Financiera].[Cartera_Meta_Comercial_Historico]
  Autor    : Analitica financiera - Universidad CUN
  Fuente   : corrida del JOB_USP_Foto_Meta_Comercial_Mensual del 2026-09-01 07:40 (858 s, OK)
  Universo : creditos cuya columna Meta_2026 contiene la marca '202609'.
  Nota     : 1 fila = 1 cuota/obligacion (NUMERO_CREDITO), NO 1 persona. Los conteos de
             personas usan COUNT(DISTINCT IDENTIFICACION).
===========================================================================================*/
IF OBJECT_ID('tempdb..#SEP') IS NOT NULL DROP TABLE #SEP;
SELECT
    H.NUMERO_CREDITO, H.IDENTIFICACION, H.PERIODO, H.Meta_2026, H.Anio_Mes_Ingreso,
    H.[Asignacion Q], H.MARCA_ACADEMICA, H.MARCA_ACADEMICA_DETALLE, H.ESTADO_ALUMNO,
    H.Promedio_notas, H.Ultimo_acceso_moodle, H.EMAIL, H.TEL_CELULAR, H.WHATSAPP,
    CAST(H.TOTAL AS DECIMAL(18,2))            AS SALDO,
    CAST(H.VALOR_ORIGINAL AS DECIMAL(18,2))   AS VALOR_ORIGINAL,
    TRY_CONVERT(date, H.FECHA_VENCIMIENTO, 103) AS FEC_VENC,
    LEN(H.Meta_2026) - LEN(REPLACE(H.Meta_2026, ',', '')) + 1 AS MESES_EN_META,
    CASE WHEN H.Anio_Mes_Ingreso = '202609' THEN 'NUEVO EN SEPTIEMBRE'
         ELSE 'ARRASTRE (ya venia)' END       AS ORIGEN,
    CASE WHEN CAST(H.GR360MAS  AS DECIMAL(18,2)) > 0 THEN '7. +360 dias'
         WHEN CAST(H.GR151A360 AS DECIMAL(18,2)) > 0 THEN '6. 151-360'
         WHEN CAST(H.GR121A150 AS DECIMAL(18,2)) > 0 THEN '5. 121-150'
         WHEN CAST(H.GR91A120  AS DECIMAL(18,2)) > 0 THEN '4. 91-120'
         WHEN CAST(H.GR61A90   AS DECIMAL(18,2)) > 0 THEN '3. 61-90'
         WHEN CAST(H.GR31A60   AS DECIMAL(18,2)) > 0 THEN '2. 31-60'
         WHEN CAST(H.GR1A30    AS DECIMAL(18,2)) > 0 THEN '1. 1-30'
         ELSE '0. sin edad de mora' END       AS EDAD_MORA
INTO #SEP
FROM Financiera.Cartera_Meta_Comercial_Historico H
WHERE H.Meta_2026 LIKE '%202609%';

/*--- 1. Tamano de la meta ---------------------------------------------------------------*/
SELECT 'META SEPTIEMBRE 2026' AS CORTE,
       COUNT(*)                        AS OBLIGACIONES,
       COUNT(DISTINCT IDENTIFICACION)  AS CLIENTES,
       CAST(SUM(SALDO)/1000000.0 AS DECIMAL(18,1))  AS SALDO_MM,
       CAST(AVG(SALDO) AS DECIMAL(18,0))            AS TICKET_PROM,
       CAST(1.0*COUNT(*)/COUNT(DISTINCT IDENTIFICACION) AS DECIMAL(6,2)) AS OBLIG_X_CLIENTE
FROM #SEP;

/*--- 2. Nuevos vs arrastre ---------------------------------------------------------------*/
SELECT ORIGEN, COUNT(*) AS OBLIGACIONES, COUNT(DISTINCT IDENTIFICACION) AS CLIENTES,
       CAST(SUM(SALDO)/1000000.0 AS DECIMAL(18,1)) AS SALDO_MM,
       CAST(100.0*SUM(SALDO)/SUM(SUM(SALDO)) OVER () AS DECIMAL(5,2)) AS PCT_SALDO
FROM #SEP GROUP BY ORIGEN ORDER BY SALDO_MM DESC;

/*--- 3. Permanencia: cuantos meses lleva el credito en la meta --------------------------*/
SELECT MESES_EN_META, COUNT(*) AS OBLIGACIONES,
       CAST(SUM(SALDO)/1000000.0 AS DECIMAL(18,1)) AS SALDO_MM,
       CAST(100.0*COUNT(*)/SUM(COUNT(*)) OVER () AS DECIMAL(5,2)) AS PCT_OBLIG
FROM #SEP GROUP BY MESES_EN_META ORDER BY MESES_EN_META;

/*--- 4. Asignacion Q (congelada al mes de ingreso) --------------------------------------*/
SELECT ISNULL([Asignacion Q],'(nulo)') AS Q, COUNT(*) AS OBLIGACIONES,
       CAST(SUM(SALDO)/1000000.0 AS DECIMAL(18,1)) AS SALDO_MM,
       CAST(100.0*SUM(SALDO)/SUM(SUM(SALDO)) OVER () AS DECIMAL(5,2)) AS PCT_SALDO
FROM #SEP GROUP BY [Asignacion Q] ORDER BY Q;

/*--- 5. Marca academica -----------------------------------------------------------------*/
SELECT ISNULL(MARCA_ACADEMICA,'(nulo)') AS MARCA_ACADEMICA, COUNT(*) AS OBLIGACIONES,
       COUNT(DISTINCT IDENTIFICACION) AS CLIENTES,
       CAST(SUM(SALDO)/1000000.0 AS DECIMAL(18,1)) AS SALDO_MM,
       CAST(100.0*SUM(SALDO)/SUM(SUM(SALDO)) OVER () AS DECIMAL(5,2)) AS PCT_SALDO
FROM #SEP GROUP BY MARCA_ACADEMICA ORDER BY SALDO_MM DESC;

/*--- 6. Detalle de marca ----------------------------------------------------------------*/
SELECT ISNULL(MARCA_ACADEMICA_DETALLE,'(nulo)') AS DETALLE, COUNT(*) AS OBLIGACIONES,
       CAST(SUM(SALDO)/1000000.0 AS DECIMAL(18,1)) AS SALDO_MM
FROM #SEP GROUP BY MARCA_ACADEMICA_DETALLE ORDER BY OBLIGACIONES DESC;

/*--- 7. Estado del alumno ---------------------------------------------------------------*/
SELECT ISNULL(ESTADO_ALUMNO,'(sin dato)') AS ESTADO_ALUMNO, COUNT(*) AS OBLIGACIONES,
       COUNT(DISTINCT IDENTIFICACION) AS CLIENTES,
       CAST(SUM(SALDO)/1000000.0 AS DECIMAL(18,1)) AS SALDO_MM
FROM #SEP GROUP BY ESTADO_ALUMNO ORDER BY OBLIGACIONES DESC;

/*--- 8. Edad de mora --------------------------------------------------------------------*/
SELECT EDAD_MORA, COUNT(*) AS OBLIGACIONES,
       CAST(SUM(SALDO)/1000000.0 AS DECIMAL(18,1)) AS SALDO_MM,
       CAST(100.0*SUM(SALDO)/SUM(SUM(SALDO)) OVER () AS DECIMAL(5,2)) AS PCT_SALDO
FROM #SEP GROUP BY EDAD_MORA ORDER BY EDAD_MORA;

/*--- 9. Periodo academico ---------------------------------------------------------------*/
SELECT PERIODO, COUNT(*) AS OBLIGACIONES, COUNT(DISTINCT IDENTIFICACION) AS CLIENTES,
       CAST(SUM(SALDO)/1000000.0 AS DECIMAL(18,1)) AS SALDO_MM
FROM #SEP GROUP BY PERIODO ORDER BY OBLIGACIONES DESC;

/*--- 10. Contactabilidad y cobertura de datos -------------------------------------------*/
SELECT
    COUNT(*) AS OBLIGACIONES,
    SUM(CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(EMAIL,''))),'')       IS NULL THEN 1 ELSE 0 END) AS SIN_EMAIL,
    SUM(CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(TEL_CELULAR,''))),'') IS NULL THEN 1 ELSE 0 END) AS SIN_CELULAR,
    SUM(CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(WHATSAPP,''))),'')    IS NULL THEN 1 ELSE 0 END) AS SIN_WHATSAPP,
    SUM(CASE WHEN Promedio_notas       IS NULL THEN 1 ELSE 0 END) AS SIN_PROMEDIO,
    SUM(CASE WHEN Ultimo_acceso_moodle IS NULL THEN 1 ELSE 0 END) AS SIN_MOODLE,
    SUM(CASE WHEN Ultimo_acceso_moodle >= DATEADD(DAY,-30,CAST(GETDATE() AS DATE)) THEN 1 ELSE 0 END) AS MOODLE_30D,
    SUM(CASE WHEN MARCA_ACADEMICA IS NULL THEN 1 ELSE 0 END) AS SIN_MARCA
FROM #SEP;

/*--- 11. Movimiento agosto -> septiembre ------------------------------------------------*/
SELECT
    SUM(CASE WHEN Meta_2026 LIKE '%202608%' AND Meta_2026 LIKE '%202609%' THEN 1 ELSE 0 END) AS SIGUEN_AGO_Y_SEP,
    SUM(CASE WHEN Meta_2026 LIKE '%202608%' AND Meta_2026 NOT LIKE '%202609%' THEN 1 ELSE 0 END) AS SALIERON_EN_SEP,
    SUM(CASE WHEN Meta_2026 NOT LIKE '%202608%' AND Meta_2026 LIKE '%202609%' THEN 1 ELSE 0 END) AS ENTRARON_EN_SEP
FROM Financiera.Cartera_Meta_Comercial_Historico;

SELECT 'SALIERON (pagaron / dejaron de cumplir filtro)' AS CONCEPTO,
       COUNT(*) AS OBLIGACIONES, COUNT(DISTINCT IDENTIFICACION) AS CLIENTES,
       CAST(SUM(CAST(TOTAL AS DECIMAL(18,2)))/1000000.0 AS DECIMAL(18,1)) AS SALDO_MM_ULT_FOTO
FROM Financiera.Cartera_Meta_Comercial_Historico
WHERE Meta_2026 LIKE '%202608%' AND Meta_2026 NOT LIKE '%202609%';

/*--- 12. Integridad de la corrida -------------------------------------------------------*/
SELECT
    (SELECT COUNT(*) FROM Financiera.Cartera_Meta_Comercial_Historico)                        AS FILAS_HISTORICO,
    (SELECT COUNT(DISTINCT NUMERO_CREDITO) FROM Financiera.Cartera_Meta_Comercial_Historico)  AS CREDITOS_DISTINTOS,
    (SELECT COUNT(*) FROM Financiera.Cartera_Meta_Comercial_Snapshot_Mensual)                 AS FILAS_BACKUP_PREVIO,
    (SELECT COUNT(*) FROM #SEP)                                                               AS META_SEPTIEMBRE,
    (SELECT COUNT(*) FROM Financiera.Cartera_Meta_Comercial_Historico
      WHERE Meta_2026 LIKE '%202609%' AND Meta_2026 LIKE '%202609%202609%')                   AS MARCA_DUPLICADA,
    (SELECT COUNT(*) FROM Financiera.Cartera_Meta_Comercial_Historico
      WHERE Meta_2026 IS NULL)                                                                AS SIN_MARCA_ANIO;

/*--- 13. Contraste contra la fuente viva (lo que HOY cumple el filtro del SP) ------------*/
SELECT 'FUENTE FINANCIERA.CARTERA hoy' AS CORTE,
       COUNT(*) AS OBLIGACIONES, COUNT(DISTINCT IDENTIFICACION) AS CLIENTES,
       CAST(SUM(CAST(TOTAL AS DECIMAL(18,2)))/1000000.0 AS DECIMAL(18,1)) AS SALDO_MM,
       MAX(FECHA_CORTE) AS FECHA_CORTE_MAX
FROM FINANCIERA.CARTERA
WHERE DOCUMENTO='NDB' AND NOMBRE_TIPO_CLIENTE='ESTUDIANTES'
  AND NOMBRE_CONCEPTO='701-ND CARGOS FINANCIEROS A ESTUDIANTES'
  AND NOMBRE_CAUSA='715-CUOTA CAPITAL CLTIENE'
  AND CORRIENTE=0 AND TOTAL>24000 AND PERIODO LIKE '%26%';

/*--- 14. Creditos que reaparecieron (hueco en la secuencia mensual) ----------------------*/
SELECT Meta_2026, COUNT(*) AS OBLIGACIONES
FROM Financiera.Cartera_Meta_Comercial_Historico
WHERE Meta_2026 LIKE '%202609%'
  AND (Meta_2026 LIKE '202606%' AND Meta_2026 NOT LIKE '%202607%202608%')
GROUP BY Meta_2026 ORDER BY OBLIGACIONES DESC;
