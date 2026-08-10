-- ===================================================================================================
-- ARQUITECTURA DE DATOS: Financiera.USP_PROCESAR_FINANCIACION_CTAYUDA_V2
-- Autor: Analitica financiera — Universidad CUN
-- ===================================================================================================
-- FECHA MODIFICACIÓN    : 2026-08-06
-- VERSIÓN               : 13.0 (+ RECAUDO_PAGOS_VALOR; + FECHA_ACTUALIZACION en Recaudos_Caja_Detalle)
--
-- CRITERIO DE PREFIJOS (orden físico de columnas):
--   1) DR_*            -> ICEBERG.CLTIENE_360_ESTUDIANTES   (solicitud / datos del estudiante)
--   2) RES_*           -> ICEBERG.CLTIENE_360_RESPUESTA     (respuesta del análisis crediticio)
--   3) RPVI_*          -> ICEBERG.ORDEN / CUNT_TRAMITE_EXTERNO / SINU.BAS_TERCERO
--   4) ZH_*            -> zoho.Base_Personas
--   5) ING_*           -> Financiera.resultado_ingresoxperiodo_final
--   6) RECAUDO_PAGOS_* -> ICEBERG.R_RECAUDO_PAGOS + PORTAL_PAGOS_CUN (medio de pago)
--   7) AUD_*           -> auditoría
--
-- CAMBIO V13.0:
--   + RECAUDO_PAGOS_VALOR agregado a la sabana (valor del recaudo del ultimo pago).
--   + Recaudos_Caja_Detalle: nueva columna FECHA_ACTUALIZACION (DATETIME DEFAULT GETDATE()) que
--     marca la fecha de ultima actualizacion por fila; el INSERT de refresco pasa a lista explicita
--     para que el DEFAULT se estampe solo.
-- (V12.0) Fase 2.6a materializa TODO el recaudo en tabla persistente Financiera.Recaudos_Caja_Detalle
--     (siembra 48 meses la 1a vez; luego refresca los ultimos 6 meses vía DELETE+INSERT en
--     transaccion). Fase 2.6b arma el subset (ultimo pago por REFERENCIA) para el cruce.
--   Campos RECAUDO_PAGOS_: NUMERO, FECHA_DE_PAGO, VALOR, CAJA, DESCRIPCION, NOMBRE_CAJA,
--   NOMBRE_FRANQUICIA. Cruce por [REFERENCIA DE PAGO] (llave 100% poblada, unica, 88% match).
--
-- PREREQUISITO: ejecutar migracion_ctayuda_recaudo_pagos.sql y migracion_ctayuda_valor_timestamp.sql
--               antes de aplicar este SP.
-- ===================================================================================================
CREATE OR ALTER PROCEDURE [Financiera].[USP_PROCESAR_FINANCIACION_CTAYUDA_V2]
    @Debug BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO CUN_REPOSITORIO.dbo.LogControlProcesos (baseDatos, usuario, proceso, registrosAfectados, fechaEjecucion, error)
    VALUES (DB_NAME(), USER_NAME(), 'Inicio ETL CTAYUDA V13.0', 0, GETDATE(), 0);

    DECLARE @ErrorMessage NVARCHAR(4000), @ErrorSeverity INT, @ErrorState INT, @RowCount INT, @rc INT;

    RAISERROR('>> [INICIO] ETL CTAYUDA V13.0', 0, 1) WITH NOWAIT;

    BEGIN TRY

        -- ===========================================================================================
        -- FASE 1: LIMPIEZA DE STAGING
        -- ===========================================================================================
        RAISERROR('>> Fase 1: Limpiando staging temporal...', 0, 1) WITH NOWAIT;

        IF OBJECT_ID('tempdb..#Stg_Base_Estudiantes') IS NOT NULL DROP TABLE #Stg_Base_Estudiantes;
        IF OBJECT_ID('tempdb..#Stg_Ordenes_Tramite')  IS NOT NULL DROP TABLE #Stg_Ordenes_Tramite;
        IF OBJECT_ID('tempdb..#Stg_Creditos')         IS NOT NULL DROP TABLE #Stg_Creditos;
        IF OBJECT_ID('tempdb..#Stg_Respuestas')       IS NOT NULL DROP TABLE #Stg_Respuestas;
        IF OBJECT_ID('tempdb..#Stg_Zoho')             IS NOT NULL DROP TABLE #Stg_Zoho;
        IF OBJECT_ID('tempdb..#Stg_Ingreso')          IS NOT NULL DROP TABLE #Stg_Ingreso;
        IF OBJECT_ID('tempdb..#Stg_Descuentos')       IS NOT NULL DROP TABLE #Stg_Descuentos;
        IF OBJECT_ID('tempdb..#Stg_Recaudo')          IS NOT NULL DROP TABLE #Stg_Recaudo;


        -- ===========================================================================================
        -- FASE 2.1: NÚCLEO DE ESTUDIANTES (CLTIENE_360_ESTUDIANTES)
        -- ===========================================================================================
        RAISERROR('>> Fase 2.1: Extrayendo Nucleo Estudiantes...', 0, 1) WITH NOWAIT;

        SELECT
            LTRIM(RTRIM(COALESCE(CAST(CAST(TRY_CAST(IDENTIFICACION AS FLOAT) AS DECIMAL(38,0)) AS NVARCHAR(100)), CAST(IDENTIFICACION AS NVARCHAR(100))))) AS IDENTIFICACION,
            LTRIM(RTRIM(COALESCE(CAST(CAST(TRY_CAST(ORDEN_CUN AS FLOAT) AS DECIMAL(38,0)) AS NVARCHAR(100)), CAST(ORDEN_CUN AS NVARCHAR(100))))) AS ORDEN_CUN,
            LTRIM(RTRIM(COALESCE(CAST(CAST(TRY_CAST([REFERENCIA DE PAGO] AS FLOAT) AS DECIMAL(38,0)) AS NVARCHAR(100)), CAST([REFERENCIA DE PAGO] AS NVARCHAR(100))))) AS [REFERENCIA DE PAGO],
            [TIPO DE IDENTIFICACIÓN], NOMBRE,
            [EMAIL INSTITUCIONAL], [EMAIL PERSONAL],
            LTRIM(RTRIM(COALESCE(CAST(CAST(TRY_CAST(CELULAR AS FLOAT) AS DECIMAL(38,0)) AS NVARCHAR(100)), CAST(CELULAR AS NVARCHAR(100))))) AS CELULAR,
            [TELÉFONO],
            [FECHA CREA ESTUDIANTE CLTIENE],
            [VALOR AVAL], [SERVIIO MÉDICO], VALOR_PAGADO, VALOR_ORDEN, VALOR_FINANCIADO,
            [GASTOS TÉCNICOS], [PORCENTAJE DE INTERÉS], [ESTADO DE PAGO ESTUDIO],
            [FECHA DE APROBACIÓN CUOTA INI], VALOR_PAGADO_EN_ICEBERG, OBSERVACION,
            TIPO_PROGRAMA, TIPO_FINANCIACION, DIR_RESIDENCIA, FEC_NACIMIENTO,
            TIPO_SOLICITANTE, ESTADO_FINANCIACION_NUM
        INTO #Stg_Base_Estudiantes
        FROM (
            SELECT
                IDENTIFICACION, ORDEN_CUN,
                [REFERENCIA DE PAGO], [TIPO DE IDENTIFICACIÓN], NOMBRE,
                [EMAIL INSTITUCIONAL], [EMAIL PERSONAL], CELULAR, [TELÉFONO],
                [FECHA CREA ESTUDIANTE CLTIENE],
                [VALOR AVAL], [SERVIIO MÉDICO], VALOR_PAGADO, VALOR_ORDEN, VALOR_FINANCIADO,
                [GASTOS TÉCNICOS], [PORCENTAJE DE INTERÉS], [ESTADO DE PAGO ESTUDIO],
                [FECHA DE APROBACIÓN CUOTA INI], VALOR_PAGADO_EN_ICEBERG, OBSERVACION,
                TIPO_PROGRAMA, TIPO_FINANCIACION, DIR_RESIDENCIA, FEC_NACIMIENTO,
                TIPO_SOLICITANTE, ESTADO_FINANCIACION_NUM,
                ROW_NUMBER() OVER(PARTITION BY IDENTIFICACION, ORDEN_CUN
                                  ORDER BY [FECHA CREA ESTUDIANTE CLTIENE] DESC) AS rn
            FROM OPENQUERY([172.16.1.175], '
                SELECT E.NUMERO_DOCUMENTO                                        AS IDENTIFICACION,
                       E.ORDEN_CUN,
                       E.REFERENCIA_PAGO                                         AS "REFERENCIA DE PAGO",
                       E.TIPO_DOCUMENTO                                          AS "TIPO DE IDENTIFICACIÓN",
                       E.NOMBRES_COMPLETOS                                       AS NOMBRE,
                       B.DIR_EMAIL                                               AS "EMAIL INSTITUCIONAL",
                       E.CORREO_PERSONAL                                         AS "EMAIL PERSONAL",
                       E.CELULAR                                                 AS CELULAR,
                       B.TEL_RESIDENCIA                                          AS "TELÉFONO",
                       E.FEC_CREACION                                            AS "FECHA CREA ESTUDIANTE CLTIENE",
                       E.VALOR_AVAL                                              AS "VALOR AVAL",
                       E.SERVICIO_MEDICO                                         AS "SERVIIO MÉDICO",
                       E.VALOR_PAGADO,
                       E.VALOR_MATRICULA                                         AS VALOR_ORDEN,
                       E.VALOR_FINANCIACION                                      AS VALOR_FINANCIADO,
                       E.GASTOS_TECNICOS                                         AS "GASTOS TÉCNICOS",
                       E.PORCENTAJE_INTERES                                      AS "PORCENTAJE DE INTERÉS",
                       E.ESTADO_PAGO_ESTUDIO                                     AS "ESTADO DE PAGO ESTUDIO",
                       C.FECHA_PAGO                                              AS "FECHA DE APROBACIÓN CUOTA INI",
                       C.VALOR                                                   AS VALOR_PAGADO_EN_ICEBERG,
                       DECODE(E.ESTADO_FINANCIACION, 1, ''CREDITO COMPLETADO'',
                                                        ''CREDITO PENDIENTE CTAYUDA'') AS OBSERVACION,
                       E.TIPO_PROGRAMA                                           AS TIPO_PROGRAMA,
                       E.TIPO_FINANCIACION                                       AS TIPO_FINANCIACION,
                       E.DIR_RESIDENCIA                                          AS DIR_RESIDENCIA,
                       E.FEC_NACIMIENTO                                          AS FEC_NACIMIENTO,
                       E.TIPO_SOLICITANTE                                        AS TIPO_SOLICITANTE,
                       E.ESTADO_FINANCIACION                                     AS ESTADO_FINANCIACION_NUM
                FROM ICEBERG.CLTIENE_360_ESTUDIANTES E
                INNER JOIN SINU.BAS_TERCERO B ON B.NUM_IDENTIFICACION = TO_CHAR(E.NUMERO_DOCUMENTO)
                LEFT JOIN PORTAL_PAGOS_CUN.PPT_CUN_DETALLE_RESPUESTA_PAGO D ON D.REFERENCIA = E.REFERENCIA_PAGO
                LEFT JOIN RECIBO_CAJA C ON C.NUMERO = D.RECIBO_ICEBERG AND C.ESTADO = ''V''
                WHERE E.ESTADO_FINANCIACION = 1
            ')
        ) d WHERE rn = 1;
        SET @rc = @@ROWCOUNT;
        RAISERROR('>> Fase 2.1 OK - %d registros', 0, 1, @rc) WITH NOWAIT;


        -- ===========================================================================================
        -- FASE 2.2: ÓRDENES RPVI  (sin cambios respecto a v9.2)
        -- ===========================================================================================
        RAISERROR('>> Fase 2.2: Extrayendo Tramites y Ordenes RPVI...', 0, 1) WITH NOWAIT;

        SELECT
            LTRIM(RTRIM(COALESCE(CAST(CAST(TRY_CAST(IDENTIFICACION AS FLOAT) AS DECIMAL(38,0)) AS NVARCHAR(100)), CAST(IDENTIFICACION AS NVARCHAR(100))))) AS IDENTIFICACION,
            LTRIM(RTRIM(COALESCE(CAST(CAST(TRY_CAST(ORDEN_CUN AS FLOAT) AS DECIMAL(38,0)) AS NVARCHAR(100)), CAST(ORDEN_CUN AS NVARCHAR(100))))) AS ORDEN_CUN,
            LTRIM(RTRIM(COALESCE(CAST(CAST(TRY_CAST(DOCUMENTO AS FLOAT) AS DECIMAL(38,0)) AS NVARCHAR(100)), CAST(DOCUMENTO AS NVARCHAR(100))))) AS DOCUMENTO,
            LTRIM(RTRIM(COALESCE(CAST(CAST(TRY_CAST([ORDEN RPVI] AS FLOAT) AS DECIMAL(38,0)) AS NVARCHAR(100)), CAST([ORDEN RPVI] AS NVARCHAR(100))))) AS [ORDEN RPVI],
            LTRIM(RTRIM(COALESCE(CAST(CAST(TRY_CAST([DOCUMENTO DE LA ORDEN INICIAL] AS FLOAT) AS DECIMAL(38,0)) AS NVARCHAR(100)), CAST([DOCUMENTO DE LA ORDEN INICIAL] AS NVARCHAR(100))))) AS [DOCUMENTO DE LA ORDEN INICIAL],
            LTRIM(RTRIM(COALESCE(CAST(CAST(TRY_CAST([ORDEN INICIAL] AS FLOAT) AS DECIMAL(38,0)) AS NVARCHAR(100)), CAST([ORDEN INICIAL] AS NVARCHAR(100))))) AS [ORDEN INICIAL],
            [ESTADO ORDEN RPVI], PERIODO,
            [FECHA DE LA ORDEN], [FECHA DE VENCIMIENTO DE ORDEN], MENSAJE, [CENTRO DE COSTO],
            [VALOR DE LA ORDEN], DESCRIPCION, GRUPO, FONDO, [FUENTE FUNCIÓN],
            [¿ORDEN RPVI LIQUIDADA?], [¿ORDEN INICIAL LIQUIDADA?]
        INTO #Stg_Ordenes_Tramite
        FROM (
            SELECT
                IDENTIFICACION, ORDEN_CUN, DOCUMENTO, [ORDEN RPVI],
                [DOCUMENTO DE LA ORDEN INICIAL], [ORDEN INICIAL], [ESTADO ORDEN RPVI], PERIODO,
                [FECHA DE LA ORDEN], [FECHA DE VENCIMIENTO DE ORDEN], MENSAJE, [CENTRO DE COSTO],
                [VALOR DE LA ORDEN], DESCRIPCION, GRUPO, FONDO, [FUENTE FUNCIÓN],
                [¿ORDEN RPVI LIQUIDADA?], [¿ORDEN INICIAL LIQUIDADA?],
                ROW_NUMBER() OVER(PARTITION BY IDENTIFICACION, ORDEN_CUN
                                  ORDER BY [FECHA DE LA ORDEN] DESC) AS rn
            FROM OPENQUERY([172.16.1.175], '
                SELECT T.IDENTIFICACION,
                       T.ORDEN AS ORDEN_CUN,
                       O.DOCUMENTO,
                       O.ORDEN                                                   AS "ORDEN RPVI",
                       T.DOCUMENTO                                               AS "DOCUMENTO DE LA ORDEN INICIAL",
                       T.ORDEN_INICIAL                                           AS "ORDEN INICIAL",
                       DECODE(ORD.ESTADO,''V'',''VIGENTE'',''A'',''ANULADA'',ORD.ESTADO)       AS "ESTADO ORDEN RPVI",
                       O.PERIODO,
                       O.FECHA_ORDEN                                             AS "FECHA DE LA ORDEN",
                       O.FECHA_VENCIMIENTO                                       AS "FECHA DE VENCIMIENTO DE ORDEN",
                       O.MENSAJE,
                       O.CENTRO_COSTO                                            AS "CENTRO DE COSTO",
                       O.VALOR_TOTAL                                             AS "VALOR DE LA ORDEN",
                       O.DESCRIPCION,
                       O.GRUPO,
                       O.FONDO,
                       O.FUENTE_FUNCION                                          AS "FUENTE FUNCIÓN",
                       DECODE(LR.LIQUIDACION, NULL, ''NO'', ''SI'')              AS "¿ORDEN RPVI LIQUIDADA?",
                       DECODE(LM.LIQUIDACION, NULL, ''NO'', ''SI'')              AS "¿ORDEN INICIAL LIQUIDADA?"
                FROM ICEBERG.CUNT_TRAMITE_EXTERNO T
                INNER JOIN ICEBERG.ORDEN O ON O.ORDEN = T.ORDEN_INICIAL AND O.DOCUMENTO = ''RPVI'' AND O.ESTADO = ''V'' AND UPPER(O.DESCRIPCION) LIKE ''%CLTIENE%''
                INNER JOIN SINU.BAS_CEN_COSTO CC ON CC.COD_CEN_COSTO = O.CENTRO_COSTO
                LEFT JOIN ORDEN ORD ON ORD.ORDEN = T.ORDEN_INICIAL AND ORD.DOCUMENTO = T.DOCUMENTO_INICIAL
                LEFT JOIN LIQUIDACION_ORDEN LR ON LR.ORDEN = T.ORDEN_INICIAL AND LR.DOCUMENTO = T.DOCUMENTO_INICIAL
                LEFT JOIN LIQUIDACION_ORDEN LM ON LM.ORDEN = T.ORDEN AND LM.DOCUMENTO = T.DOCUMENTO
            ')
        ) d WHERE rn = 1;
        SET @rc = @@ROWCOUNT;
        RAISERROR('>> Fase 2.2 OK - %d registros', 0, 1, @rc) WITH NOWAIT;


        -- ===========================================================================================
        -- FASE 2.3: SOLICITUDES DE CRÉDITO  (sin cambios)
        -- ===========================================================================================
        RAISERROR('>> Fase 2.3: Extrayendo Solicitudes de Credito...', 0, 1) WITH NOWAIT;

        SELECT
            LTRIM(RTRIM(COALESCE(CAST(CAST(TRY_CAST(IDENTIFICACION AS FLOAT) AS DECIMAL(38,0)) AS NVARCHAR(100)), CAST(IDENTIFICACION AS NVARCHAR(100))))) AS IDENTIFICACION,
            LTRIM(RTRIM(COALESCE(CAST(CAST(TRY_CAST(ORDEN_CUN AS FLOAT) AS DECIMAL(38,0)) AS NVARCHAR(100)), CAST(ORDEN_CUN AS NVARCHAR(100))))) AS ORDEN_CUN,
            [FECHA SOLICITUD DE CREDITO]
        INTO #Stg_Creditos
        FROM (
            SELECT
                IDENTIFICACION, ORDEN_CUN, [FECHA SOLICITUD DE CREDITO],
                ROW_NUMBER() OVER(PARTITION BY IDENTIFICACION, ORDEN_CUN
                                  ORDER BY [FECHA SOLICITUD DE CREDITO] DESC) AS rn
            FROM OPENQUERY([172.16.1.175], '
                SELECT CLIENTE AS IDENTIFICACION,
                       ORDEN AS ORDEN_CUN,
                       FECHA_SOLICITUD AS "FECHA SOLICITUD DE CREDITO"
                FROM ICEBERG.CREDITO
                WHERE OBSERVACIONES LIKE ''%CLTIENE%''
            ')
        ) d WHERE rn = 1;
        SET @rc = @@ROWCOUNT;
        RAISERROR('>> Fase 2.3 OK - %d registros', 0, 1, @rc) WITH NOWAIT;


        -- ===========================================================================================
        -- FASE 2.4: RESPUESTA 360 (CLTIENE_360_RESPUESTA)
        -- ===========================================================================================
        RAISERROR('>> Fase 2.4: Extrayendo Validacion 360 (Respuesta crediticia)...', 0, 1) WITH NOWAIT;

        SELECT
            LTRIM(RTRIM(COALESCE(CAST(CAST(TRY_CAST(IDENTIFICACION AS FLOAT) AS DECIMAL(38,0)) AS NVARCHAR(100)), CAST(IDENTIFICACION AS NVARCHAR(100))))) AS IDENTIFICACION,
            LTRIM(RTRIM(COALESCE(CAST(CAST(TRY_CAST(ORDEN_CUN AS FLOAT) AS DECIMAL(38,0)) AS NVARCHAR(100)), CAST(ORDEN_CUN AS NVARCHAR(100))))) AS ORDEN_CUN,
            [FECHA FIN DE PROCESO CLTIENE], [¿TIENE PROCESO LEGALIZADO?],
            TIPO_PROGRAMA_ESTUDIANTE,
            GENERO_ESTUDIANTE, EDAD_ESTUDIANTE,
            VALOR_MATRICULA, VALOR_TOTAL_FINANCIACION,
            VALOR_CUOTA_INICIAL, CUOTAS,
            DETALLES_CUOTAS, VALOR_CUOTA, COSTO_PLATAFORMA,
            PERFIL_RIESGO, SCORE
        INTO #Stg_Respuestas
        FROM (
            SELECT
                IDENTIFICACION, ORDEN_CUN,
                [FECHA FIN DE PROCESO CLTIENE], [¿TIENE PROCESO LEGALIZADO?],
                TIPO_PROGRAMA_ESTUDIANTE,
                GENERO_ESTUDIANTE, EDAD_ESTUDIANTE,
                VALOR_MATRICULA, VALOR_TOTAL_FINANCIACION,
                VALOR_CUOTA_INICIAL, CUOTAS,
                DETALLES_CUOTAS, VALOR_CUOTA, COSTO_PLATAFORMA,
                PERFIL_RIESGO, SCORE,
                ROW_NUMBER() OVER(PARTITION BY IDENTIFICACION, ORDEN_CUN
                                  ORDER BY [FECHA FIN DE PROCESO CLTIENE] DESC) AS rn
            FROM OPENQUERY([172.16.1.175], '
                SELECT NUMERO_DOCUMENTO_ESTUDIANTE                              AS IDENTIFICACION,
                       ORDEN_CUN,
                       FEC_CREACION                                             AS "FECHA FIN DE PROCESO CLTIENE",
                       DECODE(ID, NULL, ''NO'', ''SI'')                         AS "¿TIENE PROCESO LEGALIZADO?",
                       TIPO_PROGRAMA_ESTUDIANTE,
                       GENERO_ESTUDIANTE, EDAD_ESTUDIANTE,
                       VALOR_MATRICULA, VALOR_TOTAL_FINANCIACION,
                       VALOR_CUOTA_INICIAL, CUOTAS,
                       DETALLES_CUOTAS, VALOR_CUOTA, COSTO_PLATAFORMA,
                       PERFIL_RIESGO, SCORE
                FROM ICEBERG.CLTIENE_360_RESPUESTA
                WHERE VALIDACION = 1
            ')
        ) d WHERE rn = 1;
        SET @rc = @@ROWCOUNT;
        RAISERROR('>> Fase 2.4 OK - %d registros', 0, 1, @rc) WITH NOWAIT;


        -- ===========================================================================================
        -- FASE 2.5: PRE-STAGING LOCAL (Zoho + Ingreso + Descuentos)
        -- ===========================================================================================
        RAISERROR('>> Fase 2.5a: Pre-stage Zoho CRM...', 0, 1) WITH NOWAIT;

        SELECT
            LTRIM(RTRIM(COALESCE(CAST(CAST(TRY_CAST(DOC_ALUM AS FLOAT) AS DECIMAL(38,0)) AS NVARCHAR(100)), CAST(DOC_ALUM AS NVARCHAR(100))))) AS DOC_ALUM,
            LTRIM(RTRIM(COALESCE(CAST(CAST(TRY_CAST(ORDEN AS FLOAT) AS DECIMAL(38,0)) AS NVARCHAR(100)), CAST(ORDEN AS NVARCHAR(100))))) AS ORDEN,
            NOM_PROGRAMA, MODALIDAD, SECCIONAL, ESTADO_PAGO,
            Periodo_data, Fuerza_comercial_data, EST_MATRICULADO,
            TIPO_ALUM_DATA, NUEVO, lat, lon, ciudad, departamento, localidad
        INTO #Stg_Zoho
        FROM (
            SELECT
                DOC_ALUM, ORDEN, NOM_PROGRAMA, MODALIDAD, SECCIONAL, ESTADO_PAGO,
                Periodo_data, Fuerza_comercial_data, EST_MATRICULADO,
                TIPO_ALUM_DATA, NUEVO, lat, lon, ciudad, departamento, localidad,
                ROW_NUMBER() OVER (
                    PARTITION BY DOC_ALUM, ORDEN
                    ORDER BY Periodo_data DESC
                ) AS rn
            FROM [CUN_REPOSITORIO].[zoho].[Base_Personas] WITH (NOLOCK)
        ) z
        WHERE rn = 1
        AND EXISTS (
            SELECT 1 FROM #Stg_Base_Estudiantes b
            WHERE b.IDENTIFICACION = LTRIM(RTRIM(COALESCE(CAST(CAST(TRY_CAST(z.DOC_ALUM AS FLOAT) AS DECIMAL(38,0)) AS NVARCHAR(100)), CAST(z.DOC_ALUM AS NVARCHAR(100)))))
            AND b.ORDEN_CUN = LTRIM(RTRIM(COALESCE(CAST(CAST(TRY_CAST(z.ORDEN AS FLOAT) AS DECIMAL(38,0)) AS NVARCHAR(100)), CAST(z.ORDEN AS NVARCHAR(100)))))
        );
        SET @rc = @@ROWCOUNT;
        RAISERROR('>> Fase 2.5a OK - Zoho: %d registros', 0, 1, @rc) WITH NOWAIT;


        RAISERROR('>> Fase 2.5b: Pre-stage Ingreso Neto...', 0, 1) WITH NOWAIT;

        CREATE TABLE #Stg_Ingreso (
            IDENTIFICACION  NVARCHAR(20)   NOT NULL,
            ORDEN           NVARCHAR(20)   NOT NULL,
            PERIODO         VARCHAR(10)    NULL,
            ORDEN_NETO      DECIMAL(18,2)  NULL,
            rn_orden        INT            NOT NULL,
            rn_periodo      INT            NOT NULL
        );

        INSERT INTO #Stg_Ingreso (IDENTIFICACION, ORDEN, PERIODO, ORDEN_NETO, rn_orden, rn_periodo)
        SELECT
            CAST(LTRIM(RTRIM(COALESCE(CAST(CAST(TRY_CAST(Documento_Estudiante_zoho AS FLOAT) AS DECIMAL(38,0)) AS NVARCHAR(100)), CAST(Documento_Estudiante_zoho AS NVARCHAR(100))))) AS NVARCHAR(20)) AS IDENTIFICACION,
            CAST(LTRIM(RTRIM(COALESCE(CAST(CAST(TRY_CAST(ORDEN AS FLOAT) AS DECIMAL(38,0)) AS NVARCHAR(100)), CAST(ORDEN AS NVARCHAR(100))))) AS NVARCHAR(20)) AS ORDEN,
            CAST(PERIODO AS VARCHAR(10))  AS PERIODO,
            ORDEN_NETO,
            ROW_NUMBER() OVER (
                PARTITION BY Documento_Estudiante_zoho, ORDEN
                ORDER BY ORDEN DESC
            ) AS rn_orden,
            ROW_NUMBER() OVER (
                PARTITION BY Documento_Estudiante_zoho, PERIODO
                ORDER BY ORDEN DESC
            ) AS rn_periodo
        FROM [CUN_REPOSITORIO].[Financiera].[resultado_ingresoxperiodo_final] WITH (NOLOCK)
        WHERE EXISTS (
            SELECT 1 FROM #Stg_Base_Estudiantes b
            WHERE b.IDENTIFICACION = CAST(LTRIM(RTRIM(COALESCE(CAST(CAST(TRY_CAST(Documento_Estudiante_zoho AS FLOAT) AS DECIMAL(38,0)) AS NVARCHAR(100)), CAST(Documento_Estudiante_zoho AS NVARCHAR(100))))) AS NVARCHAR(20))
        );

        SET @rc = @@ROWCOUNT;
        CREATE INDEX IX_Stg_Ing_Ord ON #Stg_Ingreso(IDENTIFICACION, ORDEN)   INCLUDE (ORDEN_NETO, rn_orden);
        CREATE INDEX IX_Stg_Ing_Per ON #Stg_Ingreso(IDENTIFICACION, PERIODO)  INCLUDE (ORDEN_NETO, rn_periodo);

        RAISERROR('>> Fase 2.5b OK - Ingreso: %d registros', 0, 1, @rc) WITH NOWAIT;


        RAISERROR('>> Fase 2.5c: Pre-stage Financiera.Descuentos (fallback Zoho)...', 0, 1) WITH NOWAIT;

        CREATE TABLE #Stg_Descuentos (
            DOC_ALUM            VARCHAR(20)    NOT NULL,
            ORDEN               VARCHAR(20)    NOT NULL,
            PERIODO             VARCHAR(10)    NULL,
            NOM_PROGRAMA        NVARCHAR(200)  NULL,
            MODALIDAD           NVARCHAR(50)   NULL,
            SECCIONAL           NVARCHAR(100)  NULL,
            EST_PAG_FINANCIERO  VARCHAR(30)    NULL,
            TIPO                NVARCHAR(30)   NULL,
            NUEVO               VARCHAR(10)    NULL
        );

        INSERT INTO #Stg_Descuentos (DOC_ALUM, ORDEN, PERIODO, NOM_PROGRAMA, MODALIDAD,
                                     SECCIONAL, EST_PAG_FINANCIERO, TIPO, NUEVO)
        SELECT DOC_ALUM, ORDEN, PERIODO, NOM_PROGRAMA, MODALIDAD,
               SECCIONAL, EST_PAG_FINANCIERO, TIPO, NUEVO
        FROM (
            SELECT
                CAST(LTRIM(RTRIM(COALESCE(CAST(CAST(TRY_CAST(d.DOC_ALUM AS FLOAT) AS DECIMAL(38,0)) AS NVARCHAR(100)), CAST(d.DOC_ALUM AS NVARCHAR(100))))) AS VARCHAR(20)) AS DOC_ALUM,
                CAST(LTRIM(RTRIM(COALESCE(CAST(CAST(TRY_CAST(d.ORDEN AS FLOAT) AS DECIMAL(38,0)) AS NVARCHAR(100)), CAST(d.ORDEN AS NVARCHAR(100))))) AS VARCHAR(20)) AS ORDEN,
                CAST(d.PERIODO  AS VARCHAR(10)) AS PERIODO,
                d.NOM_PROGRAMA, d.MODALIDAD, d.SECCIONAL,
                d.EST_PAG_FINANCIERO, d.TIPO, d.NUEVO,
                ROW_NUMBER() OVER (
                    PARTITION BY d.DOC_ALUM, d.ORDEN
                    ORDER BY d.PERIODO DESC
                ) AS rn
            FROM [CUN_REPOSITORIO].[Financiera].[Descuentos] d WITH (NOLOCK)
        ) x
        WHERE rn = 1
        AND EXISTS (
            SELECT 1 FROM #Stg_Base_Estudiantes b
            WHERE b.IDENTIFICACION = x.DOC_ALUM
              AND b.ORDEN_CUN      = x.ORDEN
        );

        SET @rc = @@ROWCOUNT;
        CREATE INDEX IX_Stg_Desc ON #Stg_Descuentos(DOC_ALUM, ORDEN)
            INCLUDE (NOM_PROGRAMA, MODALIDAD, SECCIONAL, EST_PAG_FINANCIERO, TIPO, NUEVO, PERIODO);

        RAISERROR('>> Fase 2.5c OK - Descuentos fallback: %d registros', 0, 1, @rc) WITH NOWAIT;


        -- ===========================================================================================
        -- FASE 2.6: RECAUDO DE PAGOS -> tabla persistente Financiera.Recaudos_Caja_Detalle  [V13.0]
        --   Materializa TODO el recaudo (no solo CLTIENE) en una tabla aparte reutilizable:
        --     * Primera corrida (tabla no existe): SIEMBRA los ultimos 48 meses (4 años dinamico).
        --     * Corridas siguientes: REFRESCA los ultimos 6 meses (DELETE + INSERT en transaccion;
        --       preserva el historico de 4 años; un fallo del OPENQUERY hace ROLLBACK).
        --   Llave REFERENCIA (D.REFERENCIA) validada sobre CLTIENE: 100% poblada, unica (sin fan-out),
        --   88% de match. La sabana se cruza por [REFERENCIA DE PAGO].
        -- ===========================================================================================
        RAISERROR('>> Fase 2.6a: Materializando recaudo en Financiera.Recaudos_Caja_Detalle...', 0, 1) WITH NOWAIT;

        IF OBJECT_ID('CUN_REPOSITORIO.Financiera.Recaudos_Caja_Detalle', 'U') IS NULL
        BEGIN
            -- SIEMBRA: ultimos 48 meses (crea la tabla)
            SELECT *
            INTO CUN_REPOSITORIO.Financiera.Recaudos_Caja_Detalle
            FROM OPENQUERY([172.16.1.175], '
                SELECT DISTINCT
                        CAST(RP.DOC_ALUM AS VARCHAR(100)) AS CLIENTE,
                        RP.PERIODO                        AS PERIODO,
                        CAST(RP.NUMERO AS VARCHAR(100))   AS NUMERO,
                        RP.FECHA_DE_PAGO                  AS FECHA_DE_PAGO,
                        RP.VALOR_INGRESO_DIRECTO          AS VALOR,
                        RC.CAJA                           AS CAJA,
                        RC.DESCRIPCION                    AS DESCRIPCION,
                        C.NOMBRE_CAJA                     AS NOMBRE_CAJA,
                        P.NOMBRE                          AS NOMBRE_FRANQUICIA,
                        D.REFERENCIA                      AS REFERENCIA
                    FROM ICEBERG.R_RECAUDO_PAGOS RP
                    LEFT JOIN ICEBERG.RECIBO_CAJA RC ON RC.NUMERO = RP.NUMERO
                    LEFT JOIN CAJA C ON C.CAJA = RC.CAJA
                    LEFT JOIN PORTAL_PAGOS_CUN.PPT_CUN_DETALLE_RESPUESTA_PAGO D ON D.RECIBO_ICEBERG = RP.NUMERO
                    LEFT JOIN PORTAL_PAGOS_CUN.PPT_CUN_RESPUESTA_PAGO RPP ON RPP.REFERENCIA = D.REFERENCIA AND RPP.SECUENCIA = D.SECUENCIA
                    LEFT JOIN PORTAL_PAGOS_CUN.PPT_CUN_NOMBRE_FRANQUICIA_PAGO P ON P.FRANQUICIA = RPP.FRANCHISE
                    WHERE TO_DATE(RP.FECHA_DE_PAGO, ''DD/MM/YYYY'') >= ADD_MONTHS(TRUNC(SYSDATE), -48)
            ');
            SET @rc = @@ROWCOUNT;
            -- Timestamp de ultima actualizacion: estampa las filas recien sembradas
            -- y deja el DEFAULT para los INSERT de refresco posteriores.
            IF COL_LENGTH('CUN_REPOSITORIO.Financiera.Recaudos_Caja_Detalle','FECHA_ACTUALIZACION') IS NULL
                ALTER TABLE CUN_REPOSITORIO.Financiera.Recaudos_Caja_Detalle
                    ADD FECHA_ACTUALIZACION DATETIME NOT NULL
                        CONSTRAINT DF_Recaudos_Caja_Detalle_FecAct DEFAULT GETDATE();
            RAISERROR('>> Fase 2.6a SIEMBRA 48m OK - Recaudo: %d registros', 0, 1, @rc) WITH NOWAIT;
        END
        ELSE
        BEGIN
            -- REFRESCO: ultimos 6 meses (preserva el historico de 4 años)
            BEGIN TRANSACTION;

            DELETE FROM CUN_REPOSITORIO.Financiera.Recaudos_Caja_Detalle
            WHERE TRY_CONVERT(date, FECHA_DE_PAGO, 103) >= DATEADD(MONTH, -6, CAST(GETDATE() AS date));

            -- INSERT con lista explicita: FECHA_ACTUALIZACION se estampa sola vía DEFAULT GETDATE().
            INSERT INTO CUN_REPOSITORIO.Financiera.Recaudos_Caja_Detalle
                (CLIENTE, PERIODO, NUMERO, FECHA_DE_PAGO, VALOR, CAJA, DESCRIPCION,
                 NOMBRE_CAJA, NOMBRE_FRANQUICIA, REFERENCIA)
            SELECT *
            FROM OPENQUERY([172.16.1.175], '
                SELECT DISTINCT
                        CAST(RP.DOC_ALUM AS VARCHAR(100)) AS CLIENTE,
                        RP.PERIODO                        AS PERIODO,
                        CAST(RP.NUMERO AS VARCHAR(100))   AS NUMERO,
                        RP.FECHA_DE_PAGO                  AS FECHA_DE_PAGO,
                        RP.VALOR_INGRESO_DIRECTO          AS VALOR,
                        RC.CAJA                           AS CAJA,
                        RC.DESCRIPCION                    AS DESCRIPCION,
                        C.NOMBRE_CAJA                     AS NOMBRE_CAJA,
                        P.NOMBRE                          AS NOMBRE_FRANQUICIA,
                        D.REFERENCIA                      AS REFERENCIA
                    FROM ICEBERG.R_RECAUDO_PAGOS RP
                    LEFT JOIN ICEBERG.RECIBO_CAJA RC ON RC.NUMERO = RP.NUMERO
                    LEFT JOIN CAJA C ON C.CAJA = RC.CAJA
                    LEFT JOIN PORTAL_PAGOS_CUN.PPT_CUN_DETALLE_RESPUESTA_PAGO D ON D.RECIBO_ICEBERG = RP.NUMERO
                    LEFT JOIN PORTAL_PAGOS_CUN.PPT_CUN_RESPUESTA_PAGO RPP ON RPP.REFERENCIA = D.REFERENCIA AND RPP.SECUENCIA = D.SECUENCIA
                    LEFT JOIN PORTAL_PAGOS_CUN.PPT_CUN_NOMBRE_FRANQUICIA_PAGO P ON P.FRANQUICIA = RPP.FRANCHISE
                    WHERE TO_DATE(RP.FECHA_DE_PAGO, ''DD/MM/YYYY'') >= ADD_MONTHS(TRUNC(SYSDATE), -6)
            ');
            SET @rc = @@ROWCOUNT;

            COMMIT TRANSACTION;
            RAISERROR('>> Fase 2.6a REFRESCO 6m OK - Recaudo: %d registros', 0, 1, @rc) WITH NOWAIT;
        END

        -- Fase 2.6b: subset deduplicado (ULTIMO pago por REFERENCIA) de las referencias presentes
        --            en la base, para el cruce de la sabana.
        RAISERROR('>> Fase 2.6b: Preparando subset de recaudo para el cruce...', 0, 1) WITH NOWAIT;

        SELECT
            LTRIM(RTRIM(COALESCE(CAST(CAST(TRY_CAST(REFERENCIA AS FLOAT) AS DECIMAL(38,0)) AS NVARCHAR(100)), CAST(REFERENCIA AS NVARCHAR(100))))) AS REFERENCIA,
            RECAUDO_PAGOS_NUMERO,
            RECAUDO_PAGOS_FECHA_DE_PAGO,
            RECAUDO_PAGOS_VALOR,
            RECAUDO_PAGOS_CAJA,
            RECAUDO_PAGOS_DESCRIPCION,
            RECAUDO_PAGOS_NOMBRE_CAJA,
            RECAUDO_PAGOS_NOMBRE_FRANQUICIA
        INTO #Stg_Recaudo
        FROM (
            SELECT
                REFERENCIA,
                CAST(NUMERO            AS NVARCHAR(100)) AS RECAUDO_PAGOS_NUMERO,
                CAST(FECHA_DE_PAGO     AS NVARCHAR(30))  AS RECAUDO_PAGOS_FECHA_DE_PAGO,
                CAST(VALOR             AS DECIMAL(18,2)) AS RECAUDO_PAGOS_VALOR,
                CAST(CAJA              AS NVARCHAR(100)) AS RECAUDO_PAGOS_CAJA,
                CAST(DESCRIPCION       AS NVARCHAR(255)) AS RECAUDO_PAGOS_DESCRIPCION,
                CAST(NOMBRE_CAJA       AS NVARCHAR(255)) AS RECAUDO_PAGOS_NOMBRE_CAJA,
                CAST(NOMBRE_FRANQUICIA AS NVARCHAR(255)) AS RECAUDO_PAGOS_NOMBRE_FRANQUICIA,
                ROW_NUMBER() OVER (PARTITION BY REFERENCIA
                                   ORDER BY TRY_CONVERT(datetime, FECHA_DE_PAGO, 103) DESC) AS rn
            FROM CUN_REPOSITORIO.Financiera.Recaudos_Caja_Detalle
            WHERE REFERENCIA IS NOT NULL AND LTRIM(RTRIM(CAST(REFERENCIA AS NVARCHAR(100)))) <> ''
        ) d
        WHERE rn = 1
        AND EXISTS (
            SELECT 1 FROM #Stg_Base_Estudiantes b
            WHERE b.[REFERENCIA DE PAGO] = LTRIM(RTRIM(COALESCE(CAST(CAST(TRY_CAST(d.REFERENCIA AS FLOAT) AS DECIMAL(38,0)) AS NVARCHAR(100)), CAST(d.REFERENCIA AS NVARCHAR(100)))))
        );
        SET @rc = @@ROWCOUNT;
        CREATE INDEX IX_Stg_Recaudo ON #Stg_Recaudo(REFERENCIA)
            INCLUDE (RECAUDO_PAGOS_NUMERO, RECAUDO_PAGOS_FECHA_DE_PAGO, RECAUDO_PAGOS_VALOR, RECAUDO_PAGOS_CAJA,
                     RECAUDO_PAGOS_DESCRIPCION, RECAUDO_PAGOS_NOMBRE_CAJA, RECAUDO_PAGOS_NOMBRE_FRANQUICIA);
        RAISERROR('>> Fase 2.6b OK - Subset recaudo: %d registros', 0, 1, @rc) WITH NOWAIT;


        -- ===========================================================================================
        -- FASE 3: DROP ÍNDICES + TRUNCATE
        -- ===========================================================================================
        RAISERROR('>> Fase 3: Iniciando drop idx y truncate...', 0, 1) WITH NOWAIT;

        IF EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('CUN_REPOSITORIO.Financiera.Financiaciones_CTAYUDA_V2') AND name = 'IX_FIN_DOC')
            DROP INDEX IX_FIN_DOC     ON CUN_REPOSITORIO.Financiera.Financiaciones_CTAYUDA_V2;
        IF EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('CUN_REPOSITORIO.Financiera.Financiaciones_CTAYUDA_V2') AND name = 'IX_FIN_ORDEN')
            DROP INDEX IX_FIN_ORDEN   ON CUN_REPOSITORIO.Financiera.Financiaciones_CTAYUDA_V2;
        IF EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('CUN_REPOSITORIO.Financiera.Financiaciones_CTAYUDA_V2') AND name = 'IX_FIN_PERIODO')
            DROP INDEX IX_FIN_PERIODO ON CUN_REPOSITORIO.Financiera.Financiaciones_CTAYUDA_V2;

        TRUNCATE TABLE CUN_REPOSITORIO.Financiera.Financiaciones_CTAYUDA_V2;


        -- ===========================================================================================
        -- FASE 4: INSERCIÓN MAESTRA — columnas y SELECT en el mismo orden físico de la tabla:
        --   DR_* -> RES_* -> RPVI_* -> ZH_* -> ING_* -> RECAUDO_PAGOS_* -> AUD_*
        -- ===========================================================================================
        RAISERROR('>> Fase 4: Ensamblando e insertando sabana maestra...', 0, 1) WITH NOWAIT;

        INSERT INTO CUN_REPOSITORIO.Financiera.Financiaciones_CTAYUDA_V2 (
            -- 1) DR_*
            DR_NUMERO_DOCUMENTO_ESTUDIANTE, DR_TIPO_DOCUMENTO_ESTUDIANTE, DR_NOMBRES_COMPLETOS_ESTUDIANTE,
            DR_ORDEN_CUN, DR_REFERENCIA_PAGO, DR_CELULAR, DR_EMAIL_PERSONAL,
            DR_TIPO_PROGRAMA, DR_TIPO_FINANCIACION, DR_DIR_RESIDENCIA, DR_FEC_NACIMIENTO,
            DR_TIPO_SOLICITANTE, DR_ESTADO_FINANCIACION,
            DR_VALOR_ORDEN, DR_VALOR_FINANCIADO, DR_VALOR_AVAL, DR_SERVICIO_MEDICO,
            DR_VALOR_PAGADO, DR_GASTOS_TECNICOS, DR_PORCENTAJE_INTERES, DR_ESTADO_PAGO_ESTUDIO,
            DR_FECHA_CREA_ESTUDIANTE_CLTIENE,
            -- 2) RES_*
            RES_TIPO_PROGRAMA_ESTUDIANTE, RES_GENERO_ESTUDIANTE, RES_EDAD_ESTUDIANTE,
            RES_VALOR_MATRICULA, RES_VALOR_FINANCIACION, RES_VALOR_CUOTA_INICIAL,
            RES_CUOTAS, RES_DETALLES_CUOTAS, RES_VALOR_CUOTA, RES_COSTO_PLATAFORMA,
            RES_PERFIL_RIESGO, RES_SCORE,
            RES_FECHA_SOLICITUD_CREDITO, RES_FECHA_APROBACION,
            RES_AÑO_APROBACION, RES_MES_APROBACION, RES_DIA_APROBACION,
            -- 3) RPVI_*
            RPVI_EMAIL_INSTITUCIONAL, RPVI_TELEFONO,
            RPVI_DOCUMENTO_RPVI, RPVI_ORDEN_RPVI, RPVI_DOCUMENTO_ORDEN_INICIAL,
            RPVI_FECHA_ORDEN, RPVI_FECHA_VENCIMIENTO_ORDEN, RPVI_FECHA_APROBACION_CUOTA_INI,
            RPVI_FECHA_FIN_PROCESO_CLTIENE,
            RPVI_VALOR_PAGADO_EN_ICEBERG, RPVI_VALOR_ORDEN_TOTAL,
            RPVI_ESTADO_ORDEN_RPVI, RPVI_MENSAJE, RPVI_CENTRO_COSTO, RPVI_DESCRIPCION,
            RPVI_GRUPO, RPVI_FONDO, RPVI_FUENTE_FUNCION,
            RPVI_TIENE_PROCESO_360, RPVI_TIENE_PROCESO_LEGALIZADO,
            RPVI_ORDEN_RPVI_LIQUIDADA, RPVI_ORDEN_INICIAL_LIQUIDADA,
            RPVI_OBSERVACION, RPVI_PERIODO_FACTURACION,
            -- 4) ZH_*
            ZH_PROGRAMA, ZH_MODALIDAD, ZH_REGIONAL, ZH_ESTADO_PAGO, ZH_PERIODO,
            ZH_FUERZA_COMERCIAL, ZH_EST_MATRICULADO, ZH_TIPO, ZH_NUEVO,
            ZH_lat, ZH_lon, ZH_ciudad_geo, ZH_departamento, ZH_localidad,
            -- 5) ING_*
            ING_ORDEN_NETO,
            -- 6) RECAUDO_PAGOS_*  [V13.0 + VALOR en V13.0]
            RECAUDO_PAGOS_NUMERO, RECAUDO_PAGOS_FECHA_DE_PAGO, RECAUDO_PAGOS_VALOR, RECAUDO_PAGOS_CAJA,
            RECAUDO_PAGOS_DESCRIPCION, RECAUDO_PAGOS_NOMBRE_CAJA, RECAUDO_PAGOS_NOMBRE_FRANQUICIA,
            -- 7) AUD_*
            AUD_FECHA_PROCESAMIENTO
        )
        SELECT
            -- 1) DR_*
            base.IDENTIFICACION,
            base.[TIPO DE IDENTIFICACIÓN],
            base.NOMBRE,
            base.ORDEN_CUN,
            base.[REFERENCIA DE PAGO],
            base.CELULAR,
            base.[EMAIL PERSONAL],
            base.TIPO_PROGRAMA,
            base.TIPO_FINANCIACION,
            base.DIR_RESIDENCIA,
            base.FEC_NACIMIENTO,
            base.TIPO_SOLICITANTE,
            base.ESTADO_FINANCIACION_NUM,
            base.VALOR_ORDEN,
            base.VALOR_FINANCIADO,
            base.[VALOR AVAL],
            base.[SERVIIO MÉDICO],
            base.VALOR_PAGADO,
            base.[GASTOS TÉCNICOS],
            base.[PORCENTAJE DE INTERÉS],
            base.[ESTADO DE PAGO ESTUDIO],
            base.[FECHA CREA ESTUDIANTE CLTIENE],

            -- 2) RES_*
            dbo.NORMALIZAR(resp.TIPO_PROGRAMA_ESTUDIANTE),
            resp.GENERO_ESTUDIANTE,
            resp.EDAD_ESTUDIANTE,
            COALESCE(resp.VALOR_MATRICULA, base.VALOR_ORDEN),
            resp.VALOR_TOTAL_FINANCIACION,
            resp.VALOR_CUOTA_INICIAL,
            TRY_CAST(resp.CUOTAS AS INT),
            resp.DETALLES_CUOTAS,
            resp.VALOR_CUOTA,
            resp.COSTO_PLATAFORMA,
            resp.PERFIL_RIESGO,
            CAST(resp.SCORE AS NVARCHAR(50)),
            cred.[FECHA SOLICITUD DE CREDITO],
            base.[FECHA DE APROBACIÓN CUOTA INI],
            YEAR(base.[FECHA DE APROBACIÓN CUOTA INI]),
            CASE MONTH(base.[FECHA DE APROBACIÓN CUOTA INI])
                WHEN 1  THEN 'Enero'      WHEN 2  THEN 'Febrero'
                WHEN 3  THEN 'Marzo'      WHEN 4  THEN 'Abril'
                WHEN 5  THEN 'Mayo'       WHEN 6  THEN 'Junio'
                WHEN 7  THEN 'Julio'      WHEN 8  THEN 'Agosto'
                WHEN 9  THEN 'Septiembre' WHEN 10 THEN 'Octubre'
                WHEN 11 THEN 'Noviembre'  WHEN 12 THEN 'Diciembre'
            END,
            DAY(base.[FECHA DE APROBACIÓN CUOTA INI]),

            -- 3) RPVI_*
            base.[EMAIL INSTITUCIONAL],
            base.[TELÉFONO],
            ord.DOCUMENTO,
            ord.[ORDEN RPVI],
            ord.[DOCUMENTO DE LA ORDEN INICIAL],
            ord.[FECHA DE LA ORDEN],
            ord.[FECHA DE VENCIMIENTO DE ORDEN],
            base.[FECHA DE APROBACIÓN CUOTA INI],
            resp.[FECHA FIN DE PROCESO CLTIENE],
            base.VALOR_PAGADO_EN_ICEBERG,
            ord.[VALOR DE LA ORDEN],
            ord.[ESTADO ORDEN RPVI],
            ord.MENSAJE,
            ord.[CENTRO DE COSTO],
            ord.DESCRIPCION,
            ord.GRUPO,
            ord.FONDO,
            ord.[FUENTE FUNCIÓN],
            'SI',
            COALESCE(resp.[¿TIENE PROCESO LEGALIZADO?], 'NO'),
            ord.[¿ORDEN RPVI LIQUIDADA?],
            ord.[¿ORDEN INICIAL LIQUIDADA?],
            base.OBSERVACION,
            ord.PERIODO,

            -- 4) ZH_*
            dbo.NORMALIZAR(COALESCE(zb.NOM_PROGRAMA, dsc.NOM_PROGRAMA)),
            dbo.NORMALIZAR(COALESCE(zb.MODALIDAD, dsc.MODALIDAD)),
            dbo.NORMALIZAR(COALESCE(zb.SECCIONAL, dsc.SECCIONAL)),
            COALESCE(zb.ESTADO_PAGO, dsc.EST_PAG_FINANCIERO),
            COALESCE(zb.Periodo_data, ord.PERIODO, dsc.PERIODO),
            dbo.NORMALIZAR(zb.Fuerza_comercial_data),
            zb.EST_MATRICULADO,
            COALESCE(zb.TIPO_ALUM_DATA, dsc.TIPO),
            COALESCE(zb.NUEVO, dsc.NUEVO),
            zb.lat,
            zb.lon,
            zb.ciudad,
            zb.departamento,
            zb.localidad,

            -- 5) ING_*
            COALESCE(rip1.ORDEN_NETO, rip2.ORDEN_NETO),

            -- 6) RECAUDO_PAGOS_*  [V13.0 + VALOR en V13.0]
            rec.RECAUDO_PAGOS_NUMERO,
            rec.RECAUDO_PAGOS_FECHA_DE_PAGO,
            rec.RECAUDO_PAGOS_VALOR,
            rec.RECAUDO_PAGOS_CAJA,
            rec.RECAUDO_PAGOS_DESCRIPCION,
            rec.RECAUDO_PAGOS_NOMBRE_CAJA,
            rec.RECAUDO_PAGOS_NOMBRE_FRANQUICIA,

            -- 7) AUD_*
            GETDATE()

        FROM #Stg_Base_Estudiantes base
        LEFT JOIN #Stg_Ordenes_Tramite ord  ON ord.IDENTIFICACION  = base.IDENTIFICACION AND ord.ORDEN_CUN  = base.ORDEN_CUN
        LEFT JOIN #Stg_Creditos cred        ON cred.IDENTIFICACION = base.IDENTIFICACION AND cred.ORDEN_CUN = base.ORDEN_CUN
        LEFT JOIN #Stg_Respuestas resp      ON resp.IDENTIFICACION = base.IDENTIFICACION AND resp.ORDEN_CUN = base.ORDEN_CUN
        LEFT JOIN #Stg_Zoho zb              ON zb.DOC_ALUM         = base.IDENTIFICACION AND zb.ORDEN       = base.ORDEN_CUN
        LEFT JOIN #Stg_Descuentos dsc       ON dsc.DOC_ALUM        = base.IDENTIFICACION AND dsc.ORDEN      = base.ORDEN_CUN
        LEFT JOIN #Stg_Ingreso rip1         ON rip1.IDENTIFICACION = base.IDENTIFICACION AND rip1.ORDEN     = base.ORDEN_CUN AND rip1.rn_orden   = 1
        LEFT JOIN #Stg_Ingreso rip2         ON rip2.IDENTIFICACION = base.IDENTIFICACION AND rip2.PERIODO   = ord.PERIODO    AND rip2.rn_periodo = 1 AND rip1.IDENTIFICACION IS NULL
        LEFT JOIN #Stg_Recaudo rec          ON rec.REFERENCIA      = base.[REFERENCIA DE PAGO];

        SET @RowCount = @@ROWCOUNT;
        RAISERROR('>> Fase 4 OK - Sabana maestra: %d registros insertados', 0, 1, @RowCount) WITH NOWAIT;


        -- ===========================================================================================
        -- FASE 5: ÍNDICES FINALES
        -- ===========================================================================================
        RAISERROR('>> Fase 5: Creando indices finales en tabla destino...', 0, 1) WITH NOWAIT;

        CREATE INDEX IX_FIN_DOC     ON CUN_REPOSITORIO.Financiera.Financiaciones_CTAYUDA_V2(DR_NUMERO_DOCUMENTO_ESTUDIANTE);
        CREATE INDEX IX_FIN_ORDEN   ON CUN_REPOSITORIO.Financiera.Financiaciones_CTAYUDA_V2(DR_ORDEN_CUN);
        CREATE INDEX IX_FIN_PERIODO ON CUN_REPOSITORIO.Financiera.Financiaciones_CTAYUDA_V2(ZH_PERIODO);

        INSERT INTO CUN_REPOSITORIO.dbo.LogControlProcesos (baseDatos, usuario, proceso, registrosAfectados, fechaEjecucion, error)
        VALUES (DB_NAME(), USER_NAME(), 'Carga exitosa CTAYUDA V13.0', @RowCount, GETDATE(), 0);

        RAISERROR('>> [FIN] Proceso finalizado OK. Registros cargados: %d', 0, 1, @RowCount) WITH NOWAIT;

    END TRY
    BEGIN CATCH
        SELECT @ErrorMessage = ERROR_MESSAGE(), @ErrorSeverity = ERROR_SEVERITY(), @ErrorState = ERROR_STATE();

        INSERT INTO CUN_REPOSITORIO.dbo.LogControlProcesos (baseDatos, usuario, proceso, registrosAfectados, fechaEjecucion, error)
        VALUES (DB_NAME(), USER_NAME(),
                'Error ETL CTAYUDA V13.0 | ERR ' + CAST(ERROR_NUMBER() AS NVARCHAR) + ': ' + @ErrorMessage,
                0, GETDATE(), ERROR_NUMBER());

        RAISERROR(@ErrorMessage, @ErrorSeverity, @ErrorState);
    END CATCH
END
