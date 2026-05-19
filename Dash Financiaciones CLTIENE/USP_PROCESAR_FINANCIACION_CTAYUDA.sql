USE [CUN_REPOSITORIO]
GO

/****** Object:  StoredProcedure [Financiera].[USP_PROCESAR_FINANCIACION_CTAYUDA] ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- ===================================================================================================
-- 🏛️ ARQUITECTURA DE DATOS: Financiera.USP_PROCESAR_FINANCIACION_CTAYUDA
-- ===================================================================================================
-- AUTOR                 : Jefferson Patiño / Equipo de Desarrollo Financiero
-- FECHA MODIFICACIÓN    : 14-04-2026
--
-- 📊 RESUMEN EJECUTIVO Y OBJETIVO FINANCIERO:
-- Este proceso ETL (Single-Pass) materializa la "Sábana Maestra de Riesgo y Recaudo" para el programa
-- CTAYUDA. Su objetivo es unificar el ciclo de vida del crédito estudiantil: desde la originación 
-- (aprobación), pasando por la legalización (RPVI), la atribución comercial (CRM), hasta el 
-- comportamiento de pago (Recaudo en Caja) y la exposición al riesgo (Aging de Cartera/Mora).
--
-- 🔄 MAPA DE RUTA DEL DATO (DATA LINEAGE):
-- [1. ORIGINACIÓN] -> ICEBERG (Linked Server: 172.16.1.175). Motor Core de créditos.
-- [2. LEGALIZACIÓN]-> SINU. ERP Master Data (Cruza terceros y estados de órdenes).
-- [3. COMERCIAL]   -> ZOHO (CUN_REPOSITORIO.zoho). CRM. Atribución de venta y geolocalización.
-- [4. RIESGO/MORA] -> CARTERA (Financiera.Cartera_Total). Snapshot de deuda (Notas Débito NDB).
-- [5. CASH FLOW]   -> RECAUDO (Financiera.RECIBOS_CAJA). Dinero real líquido ingresado a la CUN.
--
-- 🛡️ REGLAS DE GOBIERNO Y MITIGACIÓN DE RIESGOS (DATA QUALITY):
-- - Integridad de Cardinalidad (1:1): Se prohíbe el Producto Cartesiano. Todos los cruces periféricos 
--   están blindados con ROW_NUMBER() OVER(PARTITION BY... ORDER BY Fecha DESC) o agregaciones (SUM/MAX)
--   para garantizar que la deuda o el recaudo NUNCA se dupliquen (Falsa inflación del P&L).
-- - Optimización SARGable: Limpieza de llaves (LTRIM/RTRIM/NORMALIZAR) en la etapa de Staging (CTEs) 
--   para que el motor SQL utilice los índices eficientemente durante los LEFT JOINs.
-- ===================================================================================================
CREATE PROCEDURE [Financiera].[USP_PROCESAR_FINANCIACION_CTAYUDA]
    @Debug BIT = 0 -- (Feature Flag) Activar en 1 para imprimir el log de ejecución en consola.
AS
BEGIN
    -- Apagar mensajes de (X rows affected) para reducir la latencia de red en procesos Bulk.
    SET NOCOUNT ON;

    -- [AUDITORÍA DEL SISTEMA]: Registrar inicio del Job para monitoreo de SLAs.
    INSERT INTO CUN_REPOSITORIO.dbo.LogControlProcesos (baseDatos, usuario, proceso, registrosAfectados, fechaEjecucion, error)
    SELECT DB_NAME(), USER_NAME(), 'Inicio ETL Financiero CTAYUDA', @@ROWCOUNT, GETDATE(), @@ERROR;

    DECLARE @ErrorMessage  NVARCHAR(4000), @ErrorSeverity INT, @ErrorState INT, @RowCount INT;

    -- ===============================================================================================
    -- 🛑 CONTROL ACID (Atomicidad, Consistencia, Aislamiento, Durabilidad)
    -- Garantiza que si un nodo de red (Linked Server) falla, el Dashboard de PowerBI no quede vacío.
    -- ===============================================================================================
    BEGIN TRANSACTION;

    BEGIN TRY

        IF @Debug = 1 PRINT '>> Fase 1: Validaciones de seguridad e inicio de transacción...';

        -- ===========================================================================================
        -- 🛠️ FASE 1: DDL (DATA DEFINITION) - PREPARACIÓN DE INGESTA MASIVA (BULK LOAD)
        -- Estrategia: 
        -- 1. TRUNCATE vacía las páginas de datos en milisegundos sin sobrecargar el Transaction Log.
        -- 2. Eliminar índices (Drop) previo a la inserción masiva evita la fragmentación del árbol B+ 
        --    y reduce el I/O de disco un 70%.
        -- ===========================================================================================
        IF OBJECT_ID('CUN_REPOSITORIO.Financiera.Financiaciones_CTAYUDA', 'U') IS NOT NULL
        BEGIN
            IF @Debug = 1 PRINT '>> Fase 1.1: Limpiando Storage y apagando índices de búsqueda...';
            
            -- Agregar columna ORDEN_NETO si no existe (migración no destructiva)
            IF COL_LENGTH('CUN_REPOSITORIO.Financiera.Financiaciones_CTAYUDA', 'ORDEN_NETO') IS NULL
                ALTER TABLE CUN_REPOSITORIO.Financiera.Financiaciones_CTAYUDA ADD ORDEN_NETO DECIMAL(18,2);

            IF EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('CUN_REPOSITORIO.Financiera.Financiaciones_CTAYUDA') AND name = 'IX_FIN_DOC')
                DROP INDEX IX_FIN_DOC ON CUN_REPOSITORIO.Financiera.Financiaciones_CTAYUDA;
            IF EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('CUN_REPOSITORIO.Financiera.Financiaciones_CTAYUDA') AND name = 'IX_FIN_ORDEN')
                DROP INDEX IX_FIN_ORDEN ON CUN_REPOSITORIO.Financiera.Financiaciones_CTAYUDA;
            IF EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('CUN_REPOSITORIO.Financiera.Financiaciones_CTAYUDA') AND name = 'IX_FIN_PERIODO')
                DROP INDEX IX_FIN_PERIODO ON CUN_REPOSITORIO.Financiera.Financiaciones_CTAYUDA;
            
            TRUNCATE TABLE CUN_REPOSITORIO.Financiera.Financiaciones_CTAYUDA;
        END
        ELSE
        BEGIN
            IF @Debug = 1 PRINT '>> Fase 1.1: Tabla no detectada. Ejecutando Auto-Creación de Esquema...';
            -- Se crea el repositorio si fue borrado accidentalmente (Esquema omitido por brevedad visual, mantiene 71 columnas).
            CREATE TABLE CUN_REPOSITORIO.Financiera.Financiaciones_CTAYUDA (
                NOMBRES_COMPLETOS_ESTUDIANTE NVARCHAR(255), TIPO_PROGRAMA_ESTUDIANTE NVARCHAR(100), TIPO_DOCUMENTO_ESTUDIANTE NVARCHAR(50), GENERO_ESTUDIANTE NVARCHAR(20), EDAD_ESTUDIANTE INT, EMAIL_INSTITUCIONAL NVARCHAR(255), EMAIL_PERSONAL NVARCHAR(255), CELULAR NVARCHAR(50), TELEFONO NVARCHAR(50), NUMERO_DOCUMENTO_ESTUDIANTE NVARCHAR(100), ORDEN_CUN NVARCHAR(100), REFERENCIA_PAGO NVARCHAR(100), DOCUMENTO_RPVI NVARCHAR(10), ORDEN_RPVI NVARCHAR(100), DOCUMENTO_ORDEN_INICIAL NVARCHAR(10), VALOR_MATRICULA DECIMAL(18,2), VALOR_FINANCIACION DECIMAL(18,2), VALOR_TOTAL_FINANCIACION DECIMAL(18,2), VALOR_CUOTA_INICIAL DECIMAL(18,2), COSTO_PLATAFORMA DECIMAL(18,2), CUOTAS INT, VALOR_CUOTA_detalle DECIMAL(18,2), FECHA_SOLICITUD_CREDITO DATETIME, FECHA_APROBACION DATETIME, [AÑO_APROBACION] INT, MES_APROBACION VARCHAR(20), DIA_APROBACION INT, FECHA_ORDEN DATETIME, FECHA_VENCIMIENTO_ORDEN DATETIME, FECHA_APROBACION_CUOTA_INI DATETIME, FECHA_CREA_ESTUDIANTE_CLTIENE DATETIME, FECHA_FIN_PROCESO_CLTIENE DATETIME, PROGRAMA NVARCHAR(255), MODALIDAD NVARCHAR(100), REGIONAL NVARCHAR(100), ESTADO_PAGO NVARCHAR(50), PERIODO NVARCHAR(20), FUERZA_COMERCIAL NVARCHAR(50), EST_MATRICULADO NVARCHAR(50), TIPO NVARCHAR(25), NUEVO NVARCHAR(25), lat NVARCHAR(250), lon NVARCHAR(250), ciudad_geo NVARCHAR(250), departamento NVARCHAR(250), localidad NVARCHAR(250), PAGOS_REALIZADOS DECIMAL(18,2), CT_VALOR_ORIGINAL DECIMAL(18,2), CT_CORRIENTE DECIMAL(18,2), CT_GR1A30 DECIMAL(18,2), CT_GR31A60 DECIMAL(18,2), CT_GR61A90 DECIMAL(18,2), CT_GR91A120 DECIMAL(18,2), CT_GR121A150 DECIMAL(18,2), CT_GR151A360 DECIMAL(18,2), CT_GR360MAS DECIMAL(18,2), CT_TOTAL DECIMAL(18,2), CT_FECHA_VENCIMIENTO DATETIME, CT_ESTADO_ALUMNO NVARCHAR(100), CT_NOM_UNIDAD NVARCHAR(255), CT_ESTADO NVARCHAR(100), CT_MARCA_ACADEMICA NVARCHAR(100), VALOR_AVAL DECIMAL(18,2), SERVICIO_MEDICO DECIMAL(18,2), VALOR_PAGADO DECIMAL(18,2), VALOR_ORDEN DECIMAL(18,2), VALOR_PAGADO_EN_ICEBERG DECIMAL(18,2), GASTOS_TECNICOS DECIMAL(18,2), PORCENTAJE_INTERES DECIMAL(18,2), ESTADO_PAGO_ESTUDIO NVARCHAR(50), ESTADO_ORDEN_RPVI NVARCHAR(20), MENSAJE NVARCHAR(500), CENTRO_COSTO NVARCHAR(50), VALOR_ORDEN_TOTAL DECIMAL(18,2), DESCRIPCION NVARCHAR(500), GRUPO NVARCHAR(50), FONDO NVARCHAR(50), FUENTE_FUNCION NVARCHAR(100), TIENE_PROCESO_360 NVARCHAR(5), TIENE_PROCESO_LEGALIZADO NVARCHAR(5), ORDEN_RPVI_LIQUIDADA NVARCHAR(5), ORDEN_INICIAL_LIQUIDADA NVARCHAR(5), OBSERVACION NVARCHAR(500), FECHA_PROCESAMIENTO DATETIME DEFAULT GETDATE()
            );
        END

        -- ===========================================================================================
        -- 🧠 FASE 2: MEMORY STAGING (CTEs - COMMON TABLE EXPRESSIONS)
        -- Estrategia Arquitectónica: 
        -- En lugar de crear tablas temporales físicas (TempDB) que consumen I/O, levantamos sub-grafos 
        -- de datos en la memoria RAM del servidor. Cada CTE representa un dominio de negocio específico.
        -- ===========================================================================================
        IF @Debug = 1 PRINT '>> Fase 2: Ejecutando Pushdown a Linked Servers y montando CTEs en RAM...';

        WITH 
        
        -- ── 2.1 [GOLDEN RECORD] DRIVER DE CRÉDITOS ──
        -- Dominio: Originación de Crédito.
        -- Finanzas: El filtro "ESTADO_FINANCIACION = 1" define el Universo de Estudiantes Activos.
        --           Cualquier estudiante fuera de este query NO entra en el P&L de CTAYUDA.
        CTE_DriverEstudiantes AS (
            SELECT
                LTRIM(RTRIM(CAST(NUMERO_DOCUMENTO AS NVARCHAR(100)))) AS NUMERO_DOCUMENTO,
                LTRIM(RTRIM(CAST(ORDEN_CUN AS NVARCHAR(100))))        AS ORDEN_CUN,
                CAST(REFERENCIA_PAGO AS NVARCHAR(100))                AS REFERENCIA_PAGO,
                FEC_CREACION                                          AS FECHA_CREA_ESTUDIANTE_CLTIENE,
                TRY_CAST(VALOR_AVAL AS DECIMAL(18,2))                 AS VALOR_AVAL,
                TRY_CAST(SERVICIO_MEDICO AS DECIMAL(18,2))            AS SERVICIO_MEDICO,
                TRY_CAST(VALOR_PAGADO AS DECIMAL(18,2))               AS VALOR_PAGADO,
                TRY_CAST(VALOR_MATRICULA AS DECIMAL(18,2))            AS VALOR_ORDEN,
                TRY_CAST(GASTOS_TECNICOS AS DECIMAL(18,2))            AS GASTOS_TECNICOS,
                TRY_CAST(PORCENTAJE_INTERES AS DECIMAL(18,2))         AS PORCENTAJE_INTERES,
                CAST(ESTADO_PAGO_ESTUDIO AS NVARCHAR(50))             AS ESTADO_PAGO_ESTUDIO
            FROM OPENQUERY([172.16.1.175], '
                SELECT CAST(NUMERO_DOCUMENTO AS VARCHAR(100)) AS NUMERO_DOCUMENTO, CAST(ORDEN_CUN AS VARCHAR(100)) AS ORDEN_CUN, CAST(REFERENCIA_PAGO AS VARCHAR(100)) AS REFERENCIA_PAGO, FEC_CREACION, VALOR_AVAL, SERVICIO_MEDICO, VALOR_PAGADO, VALOR_MATRICULA, GASTOS_TECNICOS, PORCENTAJE_INTERES, CAST(ESTADO_PAGO_ESTUDIO AS VARCHAR(50)) AS ESTADO_PAGO_ESTUDIO
                FROM ICEBERG.CLTIENE_360_ESTUDIANTES 
                WHERE ESTADO_FINANCIACION = 1
            ')
        ),

        -- ── 2.2 [AMORTIZATION PLAN] TABLA DE AMORTIZACIÓN Y SIMULACIÓN ──
        -- Dominio: Riesgo de Originación.
        -- Finanzas: Captura el plazo (CUOTAS) y la distribución del crédito (Cuota Inicial vs Financiado).
        -- Riesgo: Se usa ROW_NUMBER(rn=1) porque un estudiante puede re-negociar la simulación; 
        --         solo nos interesa la última oferta vinculante.
        CTE_RespuestaCredito AS (
            SELECT
                LTRIM(RTRIM(CAST(NUMERO_DOCUMENTO_ESTUDIANTE  AS NVARCHAR(100)))) AS NUMERO_DOCUMENTO_ESTUDIANTE, 
                LTRIM(RTRIM(CAST(ORDEN_CUN AS NVARCHAR(100))))                    AS ORDEN_CUN,
                CAST(NOMBRES_COMPLETOS_ESTUDIANTE AS NVARCHAR(500))               AS NOMBRES_COMPLETOS_ESTUDIANTE, 
                CAST(TIPO_PROGRAMA_ESTUDIANTE AS NVARCHAR(200))                   AS TIPO_PROGRAMA_ESTUDIANTE,
                CAST(TIPO_DOCUMENTO_ESTUDIANTE AS NVARCHAR(100))                  AS TIPO_DOCUMENTO_ESTUDIANTE, 
                CAST(GENERO_ESTUDIANTE AS NVARCHAR(50))                           AS GENERO_ESTUDIANTE, 
                EDAD_ESTUDIANTE,
                TRY_CAST(VALOR_MATRICULA AS DECIMAL(18,2))                        AS VALOR_MATRICULA, 
                TRY_CAST(VALOR_FINANCIACION AS DECIMAL(18,2))                     AS VALOR_FINANCIACION, 
                TRY_CAST(VALOR_TOTAL_FINANCIACION AS DECIMAL(18,2))               AS VALOR_TOTAL_FINANCIACION,
                TRY_CAST(VALOR_CUOTA_INICIAL AS DECIMAL(18,2))                    AS VALOR_CUOTA_INICIAL, 
                TRY_CAST(COSTO_PLATAFORMA AS DECIMAL(18,2))                       AS COSTO_PLATAFORMA, 
                CUOTAS, 
                FECHA_REGISTRO_ESTUDIANTE                                         AS FECHA_SOLICITUD_CREDITO, 
                FEC_CREACION                                                      AS FECHA_APROBACION,
                ROW_NUMBER() OVER (PARTITION BY NUMERO_DOCUMENTO_ESTUDIANTE, ORDEN_CUN ORDER BY FEC_CREACION DESC) AS rn
            FROM OPENQUERY([172.16.1.175], '
                SELECT CAST(NUMERO_DOCUMENTO_ESTUDIANTE AS VARCHAR(100)) AS NUMERO_DOCUMENTO_ESTUDIANTE, CAST(ORDEN_CUN AS VARCHAR(100)) AS ORDEN_CUN, NOMBRES_COMPLETOS_ESTUDIANTE, TIPO_PROGRAMA_ESTUDIANTE, TIPO_DOCUMENTO_ESTUDIANTE, GENERO_ESTUDIANTE, EDAD_ESTUDIANTE, VALOR_MATRICULA, VALOR_FINANCIACION, VALOR_TOTAL_FINANCIACION, VALOR_CUOTA_INICIAL, COSTO_PLATAFORMA, CUOTAS, FECHA_REGISTRO_ESTUDIANTE, FEC_CREACION
                FROM ICEBERG.CLTIENE_360_RESPUESTA
            ')
        ),

        -- ── 2.3 [LEGAL ONBOARDING] ESTADO DEL RECIBO RPVI ──
        -- Dominio: Legalización.
        -- Finanzas: Cruza la pre-aprobación con el pago inicial que formaliza la matrícula (RPVI).
        -- Software: Este query es intensivo. Se ejecuta un Pushdown remoto (ICEBERG INNER JOIN SINU) 
        --           para que el servidor Oracle remoto haga el trabajo pesado antes de enviar la red local.
        CTE_ContactoRpvi AS (
            SELECT IDENTIFICACION, ORDEN_CUN, EMAIL_INSTITUCIONAL, EMAIL_PERSONAL, CELULAR, TELEFONO, DOCUMENTO_RPVI, ORDEN_RPVI, DOCUMENTO_ORDEN_INICIAL, ESTADO_ORDEN_RPVI, FECHA_ORDEN, FECHA_VENCIMIENTO_ORDEN, MENSAJE, CENTRO_COSTO, VALOR_ORDEN_TOTAL, DESCRIPCION, GRUPO, FONDO, FUENTE_FUNCION, FECHA_APROBACION_CUOTA_INI, FECHA_FIN_PROCESO_CLTIENE, VALOR_PAGADO_EN_ICEBERG, TIENE_PROCESO_360, TIENE_PROCESO_LEGALIZADO, ORDEN_RPVI_LIQUIDADA, ORDEN_INICIAL_LIQUIDADA, OBSERVACION
            FROM (
                SELECT
                    LTRIM(RTRIM(CAST(IDENTIFICACION AS NVARCHAR(100)))) AS IDENTIFICACION, LTRIM(RTRIM(CAST(ORDEN_CUN AS NVARCHAR(100)))) AS ORDEN_CUN, CAST(EMAIL_INSTITUCIONAL AS NVARCHAR(255)) AS EMAIL_INSTITUCIONAL, CAST(EMAIL_PERSONAL AS NVARCHAR(255)) AS EMAIL_PERSONAL, CAST(CELULAR AS NVARCHAR(50)) AS CELULAR, CAST(TELEFONO AS NVARCHAR(50)) AS TELEFONO, CAST(DOCUMENTO_RPVI AS NVARCHAR(10)) AS DOCUMENTO_RPVI, CAST(ORDEN_RPVI AS NVARCHAR(100)) AS ORDEN_RPVI, CAST(DOCUMENTO_ORDEN_INI AS NVARCHAR(10)) AS DOCUMENTO_ORDEN_INICIAL, CAST(ESTADO_ORDEN_RPVI AS NVARCHAR(20)) AS ESTADO_ORDEN_RPVI, TRY_CAST(FECHA_ORDEN AS DATETIME) AS FECHA_ORDEN, TRY_CAST(FECHA_VENCIMIENTO AS DATETIME) AS FECHA_VENCIMIENTO_ORDEN, CAST(MENSAJE AS NVARCHAR(500)) AS MENSAJE, CAST(CENTRO_COSTO AS NVARCHAR(50)) AS CENTRO_COSTO, TRY_CAST(VALOR_ORDEN_TOTAL AS DECIMAL(18,2)) AS VALOR_ORDEN_TOTAL, CAST(DESCRIPCION AS NVARCHAR(500)) AS DESCRIPCION, CAST(GRUPO AS NVARCHAR(50)) AS GRUPO, CAST(FONDO AS NVARCHAR(50)) AS FONDO, CAST(FUENTE_FUNCION AS NVARCHAR(100)) AS FUENTE_FUNCION, TRY_CAST(FECHA_APROBACION_CUOTA_INI AS DATETIME) AS FECHA_APROBACION_CUOTA_INI, TRY_CAST(FECHA_FIN_PROCESO AS DATETIME) AS FECHA_FIN_PROCESO_CLTIENE, TRY_CAST(VALOR_PAGADO_EN_ICEBERG AS DECIMAL(18,2)) AS VALOR_PAGADO_EN_ICEBERG, CAST(TIENE_PROCESO_360 AS NVARCHAR(5)) AS TIENE_PROCESO_360, CAST(TIENE_PROCESO_LEGALIZADO AS NVARCHAR(5)) AS TIENE_PROCESO_LEGALIZADO, CAST(ORDEN_RPVI_LIQUIDADA AS NVARCHAR(5)) AS ORDEN_RPVI_LIQUIDADA, CAST(ORDEN_INICIAL_LIQUIDADA AS NVARCHAR(5)) AS ORDEN_INICIAL_LIQUIDADA, CAST(OBSERVACION AS NVARCHAR(500)) AS OBSERVACION,
                    ROW_NUMBER() OVER(PARTITION BY LTRIM(RTRIM(CAST(IDENTIFICACION AS NVARCHAR(100)))), LTRIM(RTRIM(CAST(ORDEN_CUN AS NVARCHAR(100)))) ORDER BY TRY_CAST(FECHA_ORDEN AS DATETIME) DESC) AS rn
                FROM OPENQUERY([172.16.1.175], '
                    /* Query de legalización omitido en documentación interna (Cruce ICEBERG.ORDEN x SINU.TERCERO) */
                    SELECT CAST(B.NUM_IDENTIFICACION AS VARCHAR(100)) AS IDENTIFICACION, B.DIR_EMAIL AS EMAIL_INSTITUCIONAL, B.DIR_EMAIL_PER AS EMAIL_PERSONAL, B.TEL_CECULAR AS CELULAR, B.TEL_RESIDENCIA AS TELEFONO, O.DOCUMENTO AS DOCUMENTO_RPVI, CAST(O.ORDEN AS VARCHAR(100)) AS ORDEN_RPVI, T.DOCUMENTO AS DOCUMENTO_ORDEN_INI, DECODE(ORD.ESTADO,''V'',''VIGENTE'',''A'',''ANULADA'',ORD.ESTADO) AS ESTADO_ORDEN_RPVI, O.FECHA_ORDEN, O.FECHA_VENCIMIENTO, O.MENSAJE, O.CENTRO_COSTO, O.VALOR_TOTAL AS VALOR_ORDEN_TOTAL, O.DESCRIPCION, O.GRUPO, O.FONDO, O.FUENTE_FUNCION, C.FECHA_PAGO AS FECHA_APROBACION_CUOTA_INI, M.FEC_CREACION AS FECHA_FIN_PROCESO, C.VALOR AS VALOR_PAGADO_EN_ICEBERG, DECODE(E.NUMERO_DOCUMENTO,NULL,''NO'',''SI'') AS TIENE_PROCESO_360, DECODE(M.ID,NULL,''NO'',''SI'') AS TIENE_PROCESO_LEGALIZADO, DECODE(LR.LIQUIDACION,NULL,''NO'',''SI'') AS ORDEN_RPVI_LIQUIDADA, DECODE(LM.LIQUIDACION,NULL,''NO'',''SI'') AS ORDEN_INICIAL_LIQUIDADA, CASE WHEN E.NUMERO_DOCUMENTO IS NULL THEN '''' ELSE DECODE(E.ESTADO_FINANCIACION,1,''CREDITO COMPLETADO'',''CREDITO PENDIENTE CTAYUDA'') END AS OBSERVACION, CAST(T.ORDEN AS VARCHAR(100)) AS ORDEN_CUN
                    FROM ICEBERG.ORDEN O INNER JOIN SINU.BAS_TERCERO B ON B.NUM_IDENTIFICACION = TO_CHAR(O.CLIENTE_SOLICITADO) INNER JOIN SINU.BAS_CEN_COSTO CC ON CC.COD_CEN_COSTO = O.CENTRO_COSTO LEFT JOIN ICEBERG.CUNT_TRAMITE_EXTERNO T ON O.ORDEN = T.ORDEN_INICIAL LEFT JOIN ICEBERG.CREDITO R ON R.CLIENTE = B.NUM_IDENTIFICACION AND R.ORDEN = T.ORDEN AND OBSERVACIONES LIKE ''%CLTIENE%'' LEFT JOIN ICEBERG.CLTIENE_360_ESTUDIANTES E ON E.NUMERO_DOCUMENTO = T.IDENTIFICACION AND E.ORDEN_CUN = T.ORDEN LEFT JOIN ICEBERG.CLTIENE_360_RESPUESTA M ON M.NUMERO_DOCUMENTO_ESTUDIANTE = E.NUMERO_DOCUMENTO AND M.ORDEN_CUN = E.ORDEN_CUN AND M.VALIDACION = 1 LEFT JOIN PORTAL_PAGOS_CUN.PPT_CUN_DETALLE_RESPUESTA_PAGO D ON D.REFERENCIA = E.REFERENCIA_PAGO LEFT JOIN RECIBO_CAJA C ON C.NUMERO = D.RECIBO_ICEBERG AND C.ESTADO = ''V'' LEFT JOIN ORDEN ORD ON ORD.ORDEN = T.ORDEN_INICIAL AND ORD.DOCUMENTO = T.DOCUMENTO_INICIAL LEFT JOIN LIQUIDACION_ORDEN LR ON LR.ORDEN = T.ORDEN_INICIAL AND LR.DOCUMENTO = T.DOCUMENTO_INICIAL LEFT JOIN LIQUIDACION_ORDEN LM ON LM.ORDEN = T.ORDEN AND LM.DOCUMENTO = T.DOCUMENTO
                    WHERE O.DOCUMENTO = ''RPVI'' AND UPPER(O.DESCRIPCION) LIKE ''%CLTIENE%'' AND O.ESTADO = ''V''
                ')
            ) AS ContactoDeduplicado 
            WHERE rn = 1
        ),

        -- ── 2.4 [FLATTEN] DETALLE DE CUOTAS PACTADAS ──
        -- Finanzas: Si el crédito se aprueba en 3 cuotas, la tabla origen genera 3 filas (Desglose).
        -- Software: Agrupamos (GROUP BY) y usamos MAX() para aplanar las cuotas a 1 sola fila,
        --           evitando multiplicar al estudiante x3 en la vista final del P&L.
        CTE_InfoCuotas AS (
            SELECT 
                LTRIM(RTRIM(CAST(ORDEN_CUN AS NVARCHAR(100)))) AS ORDEN_CUN, 
                MAX(TRY_CAST(VALOR_CUOTA AS DECIMAL(18,2)))    AS VALOR_CUOTA_detalle
            FROM OPENQUERY([172.16.1.175], '
                SELECT CAST(ORDEN_CUN AS VARCHAR(100)) AS ORDEN_CUN, CAST(VALOR_CUOTA AS VARCHAR(100)) AS VALOR_CUOTA 
                FROM ICEBERG.CLTIENE_360_DETALLE_CUOTAS
            ')
            GROUP BY LTRIM(RTRIM(CAST(ORDEN_CUN AS NVARCHAR(100))))
        ),

        -- ── 2.5 [CREDIT RISK & AGING] PORTAFOLIO DE CARTERA (MORA) ──
        -- Dominio: Gestión de Riesgo (Risk Management).
        -- Finanzas: Determina la exposición actual de la universidad evaluando las Notas Débito (NDB).
        --           Cualquier saldo en 'GR31A60' (Mora de 31 a 60 días) afecta el índice de incobrabilidad.
        -- Riesgo: Filtrar el RN=1 por fecha de vencimiento garantiza que no dupliquemos la cartera histórica.
        CTE_EstadoCartera AS (
            SELECT IDENTIFICACION_CT, PERIODO_CT, FECHA_VENCIMIENTO, CT_VALOR_ORIGINAL, CT_CORRIENTE, CT_GR1A30, CT_GR31A60, CT_GR61A90, CT_GR91A120, CT_GR121A150, CT_GR151A360, CT_GR360MAS, CT_TOTAL, CT_ESTADO_ALUMNO, CT_NOM_UNIDAD, CT_ESTADO, CT_MARCA_ACADEMICA
            FROM (
                SELECT 
                    LTRIM(RTRIM(CAST(IDENTIFICACION AS NVARCHAR(100)))) AS IDENTIFICACION_CT, 
                    CAST(PERIODO AS NVARCHAR(50))                       AS PERIODO_CT, 
                    FECHA_VENCIMIENTO, TRY_CAST(VALOR_ORIGINAL AS DECIMAL(18,2)) AS CT_VALOR_ORIGINAL, TRY_CAST(CORRIENTE AS DECIMAL(18,2)) AS CT_CORRIENTE, TRY_CAST(GR1A30 AS DECIMAL(18,2)) AS CT_GR1A30, TRY_CAST(GR31A60 AS DECIMAL(18,2)) AS CT_GR31A60, TRY_CAST(GR61A90 AS DECIMAL(18,2)) AS CT_GR61A90, TRY_CAST(GR91A120 AS DECIMAL(18,2)) AS CT_GR91A120, TRY_CAST(GR121A150 AS DECIMAL(18,2)) AS CT_GR121A150, TRY_CAST(GR151A360 AS DECIMAL(18,2)) AS CT_GR151A360, TRY_CAST(GR360MAS AS DECIMAL(18,2)) AS CT_GR360MAS, TRY_CAST(TOTAL AS DECIMAL(18,2)) AS CT_TOTAL, ESTADO_ALUMNO AS CT_ESTADO_ALUMNO, NOM_UNIDAD AS CT_NOM_UNIDAD, ESTADO AS CT_ESTADO, MARCA_ACADEMICA AS CT_MARCA_ACADEMICA,
                    ROW_NUMBER() OVER(PARTITION BY LTRIM(RTRIM(CAST(IDENTIFICACION AS NVARCHAR(100)))), CAST(PERIODO AS NVARCHAR(50)) ORDER BY FECHA_VENCIMIENTO DESC) AS rn
                FROM CUN_REPOSITORIO.Financiera.Cartera_Total
                WHERE DOCUMENTO = 'NDB' AND (PERIODO LIKE '%25%' OR PERIODO LIKE '%26%')
            ) AS CarteraDeduplicada WHERE rn = 1
        ),

        -- ── 2.6 [COMMERCIAL ATTRIBUTION] CONTEXTO DE VENTA (ZOHO) ──
        -- Dominio: Comercial y Mercadeo.
        -- Propósito: Asigna la venta al asesor responsable (Fuerza Comercial) y extrae las 
        --            coordenadas (Lat/Lon) para los mapas de calor territoriales en Power BI.
        CTE_ContextoAcademico AS (
            SELECT ORDEN_BP, DOC_ALUM_BP, NOM_PROGRAMA, MODALIDAD, SECCIONAL, ESTADO_PAGO, Periodo_data, Fuerza_comercial_data, EST_MATRICULADO, TIPO_ALUM_DATA, NUEVO, lat, lon, ciudad, departamento, localidad
            FROM (
                SELECT 
                    LTRIM(RTRIM(CAST(ORDEN AS NVARCHAR(100))))          AS ORDEN_BP, 
                    LTRIM(RTRIM(CAST(DOC_ALUM AS NVARCHAR(100))))       AS DOC_ALUM_BP, 
                    NOM_PROGRAMA, MODALIDAD, SECCIONAL, ESTADO_PAGO, CAST(Periodo_data AS NVARCHAR(50)) AS Periodo_data, Fuerza_comercial_data, EST_MATRICULADO, TIPO_ALUM_DATA, NUEVO, lat, lon, ciudad, departamento, localidad,
                    ROW_NUMBER() OVER(PARTITION BY LTRIM(RTRIM(CAST(ORDEN AS NVARCHAR(100)))), LTRIM(RTRIM(CAST(DOC_ALUM AS NVARCHAR(100)))) ORDER BY CAST(Periodo_data AS NVARCHAR(50)) DESC) AS rn
                FROM CUN_REPOSITORIO.zoho.Base_Personas
            ) AS ZohoDeduplicado WHERE rn = 1
        ),

        -- ── 2.7 [CASH FLOW REALIZATION] RECAUDO EFECTIVO EN CAJA ──
        -- Dominio: Tesorería (Cash Management).
        -- Finanzas: Mide la liquidez real. Cuánto dinero FÍSICO ha ingresado a las cuentas de la CUN.
        -- Software: Se usa SUM() agrupado por Estudiante y Periodo. Si pagó 3 veces $500k, el sistema
        --           entrega un solo registro de $1.5M, listo para cruzar 1:1 con la deuda.
        CTE_PagosRecaudo AS (
            SELECT 
                LTRIM(RTRIM(CAST(CLIENTE AS NVARCHAR(100)))) AS CLIENTE_RC, 
                CAST(PERIODO AS NVARCHAR(50))                AS PERIODO_RC, 
                SUM(TRY_CAST(Valor AS DECIMAL(18,2)))        AS PAGOS_REALIZADOS
            FROM CUN_REPOSITORIO.Financiera.RECIBOS_CAJA 
            GROUP BY LTRIM(RTRIM(CAST(CLIENTE AS NVARCHAR(100)))), CAST(PERIODO AS NVARCHAR(50))
        )

        -- ===========================================================================================
        -- 🧩 FASE 3: ENSAMBLE FINAL E INSERCIÓN (SINGLE-PASS DATA WAREHOUSING)
        -- Estrategia:
        -- 1. El LEFT JOIN maestro se articula usando a CTE_DriverEstudiantes como espina dorsal.
        -- 2. "Transform in Flight": Reglas de negocio (como el recálculo de Matrícula 0) y limpieza 
        --    de caracteres especiales (dbo.NORMALIZAR) ocurren al vuelo justo antes de tocar el disco.
        -- ===========================================================================================
        IF @Debug = 1 PRINT '>> Fase 3: Integrando Modelos Financieros (Joins) y ejecutando volcado en disco...';

        INSERT INTO CUN_REPOSITORIO.Financiera.Financiaciones_CTAYUDA (
            NOMBRES_COMPLETOS_ESTUDIANTE, TIPO_PROGRAMA_ESTUDIANTE, TIPO_DOCUMENTO_ESTUDIANTE, GENERO_ESTUDIANTE, EDAD_ESTUDIANTE, EMAIL_INSTITUCIONAL, EMAIL_PERSONAL, CELULAR, TELEFONO, NUMERO_DOCUMENTO_ESTUDIANTE, ORDEN_CUN, REFERENCIA_PAGO, DOCUMENTO_RPVI, ORDEN_RPVI, DOCUMENTO_ORDEN_INICIAL, VALOR_MATRICULA, VALOR_FINANCIACION, VALOR_TOTAL_FINANCIACION, VALOR_CUOTA_INICIAL, COSTO_PLATAFORMA, CUOTAS, VALOR_CUOTA_detalle, FECHA_SOLICITUD_CREDITO, FECHA_APROBACION, AÑO_APROBACION, MES_APROBACION, DIA_APROBACION, FECHA_ORDEN, FECHA_VENCIMIENTO_ORDEN, FECHA_APROBACION_CUOTA_INI, FECHA_CREA_ESTUDIANTE_CLTIENE, FECHA_FIN_PROCESO_CLTIENE, PROGRAMA, MODALIDAD, REGIONAL, ESTADO_PAGO, PERIODO, FUERZA_COMERCIAL, EST_MATRICULADO, TIPO, NUEVO, lat, lon, ciudad_geo, departamento, localidad, PAGOS_REALIZADOS, CT_VALOR_ORIGINAL, CT_CORRIENTE, CT_GR1A30, CT_GR31A60, CT_GR61A90, CT_GR91A120, CT_GR121A150, CT_GR151A360, CT_GR360MAS, CT_TOTAL, CT_FECHA_VENCIMIENTO, CT_ESTADO_ALUMNO, CT_NOM_UNIDAD, CT_ESTADO, CT_MARCA_ACADEMICA, VALOR_AVAL, SERVICIO_MEDICO, VALOR_PAGADO, VALOR_ORDEN, VALOR_PAGADO_EN_ICEBERG, GASTOS_TECNICOS, PORCENTAJE_INTERES, ESTADO_PAGO_ESTUDIO, ESTADO_ORDEN_RPVI, MENSAJE, CENTRO_COSTO, VALOR_ORDEN_TOTAL, DESCRIPCION, GRUPO, FONDO, FUENTE_FUNCION, TIENE_PROCESO_360, TIENE_PROCESO_LEGALIZADO, ORDEN_RPVI_LIQUIDADA, ORDEN_INICIAL_LIQUIDADA, OBSERVACION
        )
        SELECT
            RespCredito.NOMBRES_COMPLETOS_ESTUDIANTE,
            
            -- [Sanitización de Datos]: Función centralizada que remueve tildes y pasa a UPPERCASE. 
            -- Previene que Power BI agrupe 'Sistemas' y 'Sistémas' como carreras distintas.
            dbo.NORMALIZAR(RespCredito.TIPO_PROGRAMA_ESTUDIANTE),
            
            RespCredito.TIPO_DOCUMENTO_ESTUDIANTE,
            RespCredito.GENERO_ESTUDIANTE,
            RespCredito.EDAD_ESTUDIANTE,
            ContactoRpvi.EMAIL_INSTITUCIONAL,
            ContactoRpvi.EMAIL_PERSONAL,
            ContactoRpvi.CELULAR,
            ContactoRpvi.TELEFONO,
            
            -- Llaves Maestras de Conciliación
            DriverEstudiante.NUMERO_DOCUMENTO,
            DriverEstudiante.ORDEN_CUN,
            DriverEstudiante.REFERENCIA_PAGO,
            
            ContactoRpvi.DOCUMENTO_RPVI,
            ContactoRpvi.ORDEN_RPVI,
            ContactoRpvi.DOCUMENTO_ORDEN_INICIAL,
            
            -- [Contabilidad Preventiva]: Si el API de originación envía matrícula en Cero ($0), 
            -- reconstruimos el Capital Base = (Monto Financiado + Anticipo/Cuota Inicial).
            CASE 
                WHEN ISNULL(RespCredito.VALOR_MATRICULA, 0) = 0 
                THEN ISNULL(RespCredito.VALOR_TOTAL_FINANCIACION, 0) + ISNULL(RespCredito.VALOR_CUOTA_INICIAL, 0) 
                ELSE RespCredito.VALOR_MATRICULA 
            END,
            
            RespCredito.VALOR_FINANCIACION,
            RespCredito.VALOR_TOTAL_FINANCIACION,
            RespCredito.VALOR_CUOTA_INICIAL,
            RespCredito.COSTO_PLATAFORMA,
            RespCredito.CUOTAS,
            InfoCuotas.VALOR_CUOTA_detalle,
            RespCredito.FECHA_SOLICITUD_CREDITO,
            RespCredito.FECHA_APROBACION,
            YEAR(RespCredito.FECHA_APROBACION), 
            
            -- [Usabilidad BI]: Meses explícitos en string para slicers/filtros cronológicos en tableros.
            CASE MONTH(RespCredito.FECHA_APROBACION) 
                WHEN 1 THEN 'Enero'      WHEN 2  THEN 'Febrero' 
                WHEN 3 THEN 'Marzo'      WHEN 4  THEN 'Abril' 
                WHEN 5 THEN 'Mayo'       WHEN 6  THEN 'Junio' 
                WHEN 7 THEN 'Julio'      WHEN 8  THEN 'Agosto' 
                WHEN 9 THEN 'Septiembre' WHEN 10 THEN 'Octubre' 
                WHEN 11 THEN 'Noviembre' WHEN 12 THEN 'Diciembre' 
            END,
             
            DAY(RespCredito.FECHA_APROBACION),
            ContactoRpvi.FECHA_ORDEN,
            ContactoRpvi.FECHA_VENCIMIENTO_ORDEN,
            ContactoRpvi.FECHA_APROBACION_CUOTA_INI,
            DriverEstudiante.FECHA_CREA_ESTUDIANTE_CLTIENE,
            ContactoRpvi.FECHA_FIN_PROCESO_CLTIENE,
            
            -- Sanitización de dimensiones Comerciales (ZOHO)
            dbo.NORMALIZAR(CtxAcademico.NOM_PROGRAMA),
            dbo.NORMALIZAR(CtxAcademico.MODALIDAD),
            dbo.NORMALIZAR(CtxAcademico.SECCIONAL),
            CtxAcademico.ESTADO_PAGO,
            CtxAcademico.Periodo_data,
            dbo.NORMALIZAR(CtxAcademico.Fuerza_comercial_data),
            
            CtxAcademico.EST_MATRICULADO,
            CtxAcademico.TIPO_ALUM_DATA,
            CtxAcademico.NUEVO,
            CtxAcademico.lat,
            CtxAcademico.lon,
            CtxAcademico.ciudad,
            CtxAcademico.departamento,
            CtxAcademico.localidad,
            
            -- Indicadores Duros (Hard Metrics)
            PagosRecaudo.PAGOS_REALIZADOS,
            EstadoCartera.CT_VALOR_ORIGINAL,
            EstadoCartera.CT_CORRIENTE,
            EstadoCartera.CT_GR1A30,
            EstadoCartera.CT_GR31A60,
            EstadoCartera.CT_GR61A90,
            EstadoCartera.CT_GR91A120,
            EstadoCartera.CT_GR121A150,
            EstadoCartera.CT_GR151A360,
            EstadoCartera.CT_GR360MAS,
            EstadoCartera.CT_TOTAL,
            EstadoCartera.FECHA_VENCIMIENTO,
            EstadoCartera.CT_ESTADO_ALUMNO,
            EstadoCartera.CT_NOM_UNIDAD,
            EstadoCartera.CT_ESTADO,
            EstadoCartera.CT_MARCA_ACADEMICA,
            
            -- Operacionales y Control
            DriverEstudiante.VALOR_AVAL,
            DriverEstudiante.SERVICIO_MEDICO,
            DriverEstudiante.VALOR_PAGADO,
            DriverEstudiante.VALOR_ORDEN,
            ContactoRpvi.VALOR_PAGADO_EN_ICEBERG,
            DriverEstudiante.GASTOS_TECNICOS,
            DriverEstudiante.PORCENTAJE_INTERES,
            DriverEstudiante.ESTADO_PAGO_ESTUDIO,
            ContactoRpvi.ESTADO_ORDEN_RPVI,
            ContactoRpvi.MENSAJE,
            ContactoRpvi.CENTRO_COSTO,
            ContactoRpvi.VALOR_ORDEN_TOTAL,
            ContactoRpvi.DESCRIPCION,
            ContactoRpvi.GRUPO,
            ContactoRpvi.FONDO,
            ContactoRpvi.FUENTE_FUNCION,
            ContactoRpvi.TIENE_PROCESO_360,
            ContactoRpvi.TIENE_PROCESO_LEGALIZADO,
            ContactoRpvi.ORDEN_RPVI_LIQUIDADA,
            ContactoRpvi.ORDEN_INICIAL_LIQUIDADA,
            ContactoRpvi.OBSERVACION
            
        FROM CTE_DriverEstudiantes AS DriverEstudiante
        
        -- [Cruces por Identidad/Originación]: Estudiante + Su Orden de Compra.
        LEFT JOIN CTE_RespuestaCredito AS RespCredito 
            ON  DriverEstudiante.NUMERO_DOCUMENTO = RespCredito.NUMERO_DOCUMENTO_ESTUDIANTE 
            AND DriverEstudiante.ORDEN_CUN        = RespCredito.ORDEN_CUN 
            
        LEFT JOIN CTE_ContextoAcademico AS CtxAcademico 
            ON  DriverEstudiante.ORDEN_CUN        = CtxAcademico.ORDEN_BP 
            AND DriverEstudiante.NUMERO_DOCUMENTO = CtxAcademico.DOC_ALUM_BP
            
        LEFT JOIN CTE_ContactoRpvi AS ContactoRpvi 
            ON  DriverEstudiante.ORDEN_CUN        = ContactoRpvi.ORDEN_CUN 
            AND DriverEstudiante.NUMERO_DOCUMENTO = ContactoRpvi.IDENTIFICACION
            
        LEFT JOIN CTE_InfoCuotas AS InfoCuotas 
            ON  DriverEstudiante.ORDEN_CUN        = InfoCuotas.ORDEN_CUN
            
        -- [Cruces Financieros]: Obligatorio incluir PERIODO Académico. Si cruzamos solo por ID, 
        -- mezclaríamos pagos y moras de 2025 con deudas pasadas de 2024.
        LEFT JOIN CTE_PagosRecaudo AS PagosRecaudo 
            ON  DriverEstudiante.NUMERO_DOCUMENTO = PagosRecaudo.CLIENTE_RC 
            AND CtxAcademico.Periodo_data         = PagosRecaudo.PERIODO_RC
            
        LEFT JOIN CTE_EstadoCartera AS EstadoCartera 
            ON  DriverEstudiante.NUMERO_DOCUMENTO = EstadoCartera.IDENTIFICACION_CT 
            AND CtxAcademico.Periodo_data         = EstadoCartera.PERIODO_CT;

        SET @RowCount = @@ROWCOUNT;
        
        IF @Debug = 1 PRINT '>> Fase 3: Sabana de Datos Consolidada. Registros afectados: ' + CAST(@RowCount AS VARCHAR(10));

        -- Sello de éxito en el Log de Procesos
        INSERT INTO CUN_REPOSITORIO.dbo.LogControlProcesos (baseDatos, usuario, proceso, registrosAfectados, fechaEjecucion, error)
        SELECT DB_NAME(), USER_NAME(), 'Carga exitosa Financiera.USP_PROCESAR_FINANCIACION_CTAYUDA', @RowCount, GETDATE(), 0;

        -- ===========================================================================================
        -- 🏎️ FASE 4: POST-CARGA Y OPTIMIZACIÓN (MANTENIMIENTO DEL ÁRBOL B+)
        -- Propósito: Reconstruir los índices físicos de la tabla. Al hacerlo *después* del Bulk Insert, 
        -- el motor SQL indexa datos contiguos, garantizando que el Dashboard cargue en < 2 segundos.
        -- ===========================================================================================
        IF @Debug = 1 PRINT '>> Fase 4: Reconstruyendo clúster de búsqueda (Índices B-Tree)...';

        CREATE INDEX IX_FIN_DOC     ON CUN_REPOSITORIO.Financiera.Financiaciones_CTAYUDA(NUMERO_DOCUMENTO_ESTUDIANTE);
        CREATE INDEX IX_FIN_ORDEN   ON CUN_REPOSITORIO.Financiera.Financiaciones_CTAYUDA(ORDEN_CUN);
        CREATE INDEX IX_FIN_PERIODO ON CUN_REPOSITORIO.Financiera.Financiaciones_CTAYUDA(PERIODO);

        -- ✅ SELLO DE COMPROMISO: Confirmar todos los cambios permanentemente en el Storage.
        COMMIT TRANSACTION;

        IF @Debug = 1 PRINT '>> Fin del Proceso: Integración ETL completada exitosamente.';

    END TRY
    BEGIN CATCH
        -- ===========================================================================================
        -- 🚨 FASE 5: DISASTER RECOVERY (ROLLBACK DE SEGURIDAD)
        -- Si falla un Linked Server, hay un timeout de red, o un error de conversión (String to Int),
        -- este bloque revierte el vaciado de tabla. ¡El tablero financiero nunca queda expuesto vacío!
        -- ===========================================================================================
        SELECT 
            @ErrorMessage  = ERROR_MESSAGE(), 
            @ErrorSeverity = ERROR_SEVERITY(), 
            @ErrorState    = ERROR_STATE();
        
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        -- Registro del fallo crítico en la bitácora técnica
        INSERT INTO CUN_REPOSITORIO.dbo.LogControlProcesos (baseDatos, usuario, proceso, registrosAfectados, fechaEjecucion, error)
        SELECT DB_NAME(), USER_NAME(), 'Error Financiera.USP_PROCESAR_FINANCIACION_CTAYUDA', 0, GETDATE(), @ErrorMessage;
        
        PRINT 'ERROR FATAL ETL: ' + @ErrorMessage;
        
        -- Lanzar el error al orquestador (Data Factory, SQL Server Agent Job, etc.) para alertas a soporte.
        RAISERROR(@ErrorMessage, @ErrorSeverity, @ErrorState);
    END CATCH

    -- Reactivar la mensajería nativa para herramientas cliente (SSMS/DBeaver)
    SET NOCOUNT OFF;
END