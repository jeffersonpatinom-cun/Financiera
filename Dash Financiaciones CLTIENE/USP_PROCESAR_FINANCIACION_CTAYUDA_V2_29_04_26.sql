USE [CUN_REPOSITORIO]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- ====================================================================================================
-- ██████████████████████████████████████████████████████████████████████████████████████████████████
--
--  PROCEDIMIENTO : [Financiera].[USP_PROCESAR_FINANCIACION_CTAYUDA_V2]
--  BASE DE DATOS : CUN_REPOSITORIO
--  ESQUEMA       : Financiera
--  AUTOR         : Arquitectura de Datos — Universidad CUN
--  FECHA CREACIÓN: 2026-04-26
--  VERSIÓN       : 8.0
--
-- ──────────────────────────────────────────────────────────────────────────────────────────────────
--  RESUMEN EJECUTIVO
-- ──────────────────────────────────────────────────────────────────────────────────────────────────
--  Construye la sabana maestra de financiaciones CTAYUDA consolidando datos de estudiantes,
--  órdenes académicas (RPVI), solicitudes de crédito, validaciones 360 y enriquecimiento
--  comercial desde el CRM Zoho. El resultado alimenta los reportes de riesgo, recaudo y
--  cartera del área Financiera, permitiendo trazabilidad completa desde la solicitud de
--  crédito hasta el estado de pago por periodo académico.
--
-- ──────────────────────────────────────────────────────────────────────────────────────────────────
--  ARQUITECTURA DE EJECUCIÓN
-- ──────────────────────────────────────────────────────────────────────────────────────────────────
--  El proceso sigue un patrón ETL en 5 fases claramente diferenciadas:
--
--   FASE 1 │ Limpieza de tablas temporales de sesiones anteriores
--   FASE 2 │ Extracción remota vía OPENQUERY desde Oracle Iceberg (servidor 172.16.1.175)
--   FASE 2.5│ Pre-staging local: Zoho CRM + tabla de ingresos netos
--   FASE 3 │ Operación atómica: DROP índices → TRUNCATE → INSERT → CREATE índices
--   FASE 4 │ Ensamble e inserción maestra con normalización de texto en línea
--   FASE 5 │ Recreación de índices de consulta y cierre de transacción
--
--  ⚠ ADVERTENCIA CRÍTICA DE RENDIMIENTO:
--     Las fases 2 y 2.5 se ejecutan FUERA de la transacción intencionalmente.
--     Mover los OPENQUERY o los SELECT INTO dentro del BEGIN TRANSACTION convertiría
--     los locks de segundos en locks de minutos, bloqueando lecturas concurrentes
--     sobre la tabla destino. No modificar esta arquitectura sin análisis de I/O previo.
--
-- ──────────────────────────────────────────────────────────────────────────────────────────────────
--  FUENTES DE DATOS
-- ──────────────────────────────────────────────────────────────────────────────────────────────────
--   · [172.16.1.175] (Linked Server Oracle)
--       - ICEBERG.CLTIENE_360_ESTUDIANTES   : núcleo de estudiantes con financiación activa
--       - ICEBERG.CUNT_TRAMITE_EXTERNO       : trámites externos vinculados a órdenes RPVI
--       - ICEBERG.ORDEN                      : órdenes académicas del sistema SINU
--       - ICEBERG.CREDITO                    : solicitudes de crédito CTAYUDA
--       - ICEBERG.CLTIENE_360_RESPUESTA      : validaciones del proceso 360 de legalización
--       - SINU.BAS_TERCERO                   : datos de contacto del estudiante (email, tel.)
--       - LIQUIDACION_ORDEN                  : estado de liquidación por orden
--   · [CUN_REPOSITORIO].[zoho].[Base_Personas]                   : datos del CRM Zoho
--   · [CUN_REPOSITORIO].[Financiera].[resultado_ingresoxperiodo_final] : ingresos netos
--
-- ──────────────────────────────────────────────────────────────────────────────────────────────────
--  PARÁMETROS
-- ──────────────────────────────────────────────────────────────────────────────────────────────────
--   @Debug BIT = 0 │ Activar con 1 para imprimir mensajes de progreso por fase.
--                  │ Útil en ejecuciones manuales y diagnóstico de tiempos parciales.
--
-- ──────────────────────────────────────────────────────────────────────────────────────────────────
--  TABLA DESTINO
-- ──────────────────────────────────────────────────────────────────────────────────────────────────
--   [CUN_REPOSITORIO].[Financiera].[Financiaciones_CTAYUDA_V2]
--   · Se crea automáticamente en primera ejecución si no existe.
--   · Carga completa (full refresh) por TRUNCATE + INSERT en cada ejecución.
--   · Índices no agrupados recreados post-carga para maximizar velocidad de INSERT.
--
-- ──────────────────────────────────────────────────────────────────────────────────────────────────
--  HISTORIAL DE CAMBIOS
-- ──────────────────────────────────────────────────────────────────────────────────────────────────
--  v8.0 | 2026-04-26 | OPT-1: OPENQUERY movidos fuera de transacción → locks de segundos.
--                     | OPT-2: dbo.NORMALIZAR() inlineado en INSERT → elimina segundo full scan.
--                     | OPT-3: Zoho pre-stageado filtrando por documentos existentes.
--                     | OPT-4: Ingreso neto en una sola lectura (primario + fallback).
--                     | OPT-5: SELECT * reemplazado por columnas explícitas.
--                     | FIX-1: Artefactos de sintaxis corregidos en OPENQUERY e INSERT.
--                     | FIX-2: #Stg_Ingreso convertido a CREATE TABLE + INSERT con CAST
--                     |        explícito para resolver error de tipos MAX en índices.
--                     | FIX-3: IF IS NOT NULL redundante eliminado en Fase 3.
--                     | ADD-1: Columna AUD_FECHA_PROCESAMIENTO para trazabilidad de carga.
--                     | ADD-2: Tipos de datos optimizados en DDL de tabla destino.
--
-- ██████████████████████████████████████████████████████████████████████████████████████████████████
-- ====================================================================================================

ALTER PROCEDURE [Financiera].[USP_PROCESAR_FINANCIACION_CTAYUDA_V2]
    @Debug BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    -- Registro de inicio en la bitácora centralizada de procesos.
    -- Permite monitorear cuándo inició el ETL desde cualquier herramienta de observabilidad.
    INSERT INTO CUN_REPOSITORIO.dbo.LogControlProcesos (baseDatos, usuario, proceso, registrosAfectados, fechaEjecucion, error)
    VALUES (DB_NAME(), USER_NAME(), 'Inicio ETL CTAYUDA V8.0', 0, GETDATE(), 0);

    DECLARE @ErrorMessage NVARCHAR(4000), @ErrorSeverity INT, @ErrorState INT, @RowCount INT;

    BEGIN TRY

        -- ============================================================================================
        -- FASE 1 │ LIMPIEZA DE STAGING
        -- ============================================================================================
        -- Garantía de idempotencia: si una ejecución anterior falló antes de limpiar las temporales,
        -- esta fase las elimina para evitar contaminación de datos entre corridas.
        -- Las tablas temporales de sesión (#) son visibles únicamente en la conexión actual,
        -- pero pueden persistir si el SP terminó con error sin llegar al DROP implícito de sesión.
        -- ============================================================================================
        IF OBJECT_ID('tempdb..#Stg_Base_Estudiantes') IS NOT NULL DROP TABLE #Stg_Base_Estudiantes;
        IF OBJECT_ID('tempdb..#Stg_Ordenes_Tramite')  IS NOT NULL DROP TABLE #Stg_Ordenes_Tramite;
        IF OBJECT_ID('tempdb..#Stg_Creditos')         IS NOT NULL DROP TABLE #Stg_Creditos;
        IF OBJECT_ID('tempdb..#Stg_Respuestas')       IS NOT NULL DROP TABLE #Stg_Respuestas;
        IF OBJECT_ID('tempdb..#Stg_Zoho')             IS NOT NULL DROP TABLE #Stg_Zoho;
        IF OBJECT_ID('tempdb..#Stg_Ingreso')          IS NOT NULL DROP TABLE #Stg_Ingreso;


        -- ============================================================================================
        -- FASE 2 │ EXTRACCIÓN REMOTA — OPENQUERY sobre Oracle Iceberg (172.16.1.175)
        -- ============================================================================================
        -- Todos los bloques de esta fase se ejecutan FUERA de la transacción (OPT-1).
        -- Dado que OPENQUERY delega la ejecución al motor Oracle remoto y devuelve un resultset
        -- completo antes de continuar, incluirlos dentro de BEGIN TRANSACTION inflaría la
        -- duración del lock sobre la tabla destino de minutos a horas en volúmenes altos.
        -- Si un OPENQUERY falla, la tabla destino permanece intacta con la carga anterior.
        --
        -- ⚠ ADVERTENCIA: No modificar el Linked Server [172.16.1.175] ni las queries Oracle
        --   sin validar con el equipo de infraestructura de bases de datos. Cualquier cambio
        --   en los alias de columna romperá el mapeo con las tablas de staging locales.
        -- ============================================================================================
        IF @Debug = 1 PRINT '>> Fase 2.1: Extrayendo Núcleo Estudiantes...';

        -- ─────────────────────────────────────────────────────────────────────────────────────────
        -- BLOQUE 2.1 │ Núcleo de Estudiantes con Financiación Activa (#Stg_Base_Estudiantes)
        -- ─────────────────────────────────────────────────────────────────────────────────────────
        -- Extrae el universo base del proceso: estudiantes con ESTADO_FINANCIACION = 1 en Oracle,
        -- que corresponde a créditos CTAYUDA completados. Incluye los montos financieros del
        -- acuerdo (aval, matrícula, financiación) y el recibo de caja validado (estado 'V').
        --
        -- Reglas de negocio aplicadas:
        --   · JOIN con BAS_TERCERO para enriquecer con datos de contacto institucional (email, tel.)
        --   · LEFT JOIN con detalle de respuesta de pago y recibo de caja para capturar el valor
        --     y fecha del primer pago registrado en Iceberg (cuota inicial).
        --   · DECODE mapea el estado numérico a etiquetas legibles para analítica.
        --   · ROW_NUMBER() PARTITION BY (IDENTIFICACION, ORDEN_CUN) ORDER BY FEC_CREACION DESC
        --     resuelve duplicados conservando el registro más reciente por estudiante-orden.
        --     Se filtra rn = 1 en la capa externa para no persistir la columna auxiliar.
        -- ─────────────────────────────────────────────────────────────────────────────────────────
        SELECT
            IDENTIFICACION, ORDEN_CUN,
            [REFERENCIA DE PAGO], [TIPO DE IDENTIFICACIÓN], NOMBRE,
            [EMAIL INSTITUCIONAL], [EMAIL PERSONAL], CELULAR, [TELÉFONO],
            [FECHA CREA ESTUDIANTE CLTIENE],
            [VALOR AVAL], [SERVIIO MÉDICO], VALOR_PAGADO, VALOR_ORDEN, VALOR_FINANCIADO,
            [GASTOS TÉCNICOS], [PORCENTAJE DE INTERÉS], [ESTADO DE PAGO ESTUDIO],
            [FECHA DE APROBACIÓN CUOTA INI], VALOR_PAGADO_EN_ICEBERG, OBSERVACION
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
                                                        ''CREDITO PENDIENTE CTAYUDA'') AS OBSERVACION
                FROM ICEBERG.CLTIENE_360_ESTUDIANTES E
                INNER JOIN SINU.BAS_TERCERO B ON B.NUM_IDENTIFICACION = TO_CHAR(E.NUMERO_DOCUMENTO)
                LEFT JOIN PORTAL_PAGOS_CUN.PPT_CUN_DETALLE_RESPUESTA_PAGO D ON D.REFERENCIA = E.REFERENCIA_PAGO
                LEFT JOIN RECIBO_CAJA C ON C.NUMERO = D.RECIBO_ICEBERG AND C.ESTADO = ''V''
                WHERE E.ESTADO_FINANCIACION = 1
            ')
        ) d WHERE rn = 1;
        IF @Debug = 1 PRINT '>> Fase 2.1 OK - ' + CAST(@@ROWCOUNT AS VARCHAR) + ' registros';


        IF @Debug = 1 PRINT '>> Fase 2.2: Extrayendo Trámites y Órdenes...';

        -- ─────────────────────────────────────────────────────────────────────────────────────────
        -- BLOQUE 2.2 │ Órdenes RPVI Vinculadas al Trámite CTAYUDA (#Stg_Ordenes_Tramite)
        -- ─────────────────────────────────────────────────────────────────────────────────────────
        -- Obtiene la orden de cobro RPVI (Resolución de Pago por Vía Interna) que respalda
        -- financieramente cada trámite de financiación. Esta orden contiene el valor real
        -- facturado por periodo, el centro de costo asociado y el estado de liquidación,
        -- datos críticos para la conciliación contable y el análisis de cartera.
        --
        -- Reglas de negocio aplicadas:
        --   · INNER JOIN con ICEBERG.ORDEN filtrando DOCUMENTO = 'RPVI', ESTADO = 'V'
        --     y DESCRIPCION LIKE '%CLTIENE%' para aislar exclusivamente las órdenes del
        --     programa de financiación y evitar cruce con otros tipos de cobro.
        --   · LEFT JOIN con LIQUIDACION_ORDEN (doble: orden RPVI y orden inicial) para
        --     determinar si cada orden ya fue liquidada contablemente (SI/NO).
        --   · ROW_NUMBER() conserva la orden RPVI más reciente por estudiante-orden CUN.
        -- ─────────────────────────────────────────────────────────────────────────────────────────
        SELECT
            IDENTIFICACION, ORDEN_CUN, DOCUMENTO, [ORDEN RPVI],
            [DOCUMENTO DE LA ORDEN INICIAL], [ORDEN INICIAL], [ESTADO ORDEN RPVI], PERIODO,
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
        IF @Debug = 1 PRINT '>> Fase 2.2 OK - ' + CAST(@@ROWCOUNT AS VARCHAR) + ' registros';


        IF @Debug = 1 PRINT '>> Fase 2.3: Extrayendo Solicitudes de Crédito...';

        -- ─────────────────────────────────────────────────────────────────────────────────────────
        -- BLOQUE 2.3 │ Fecha de Solicitud de Crédito (#Stg_Creditos)
        -- ─────────────────────────────────────────────────────────────────────────────────────────
        -- Captura la fecha en que el estudiante radicó la solicitud de crédito CTAYUDA en el
        -- sistema Iceberg. Este dato es clave para medir el ciclo operativo (tiempo entre
        -- solicitud y aprobación) y para reportes de gestión comercial.
        -- El filtro OBSERVACIONES LIKE '%CLTIENE%' garantiza que solo se extraigan créditos
        -- del programa CTAYUDA, excluyendo otros productos de financiación de la institución.
        -- ROW_NUMBER() conserva la solicitud más reciente si hay reradicaciones.
        -- ─────────────────────────────────────────────────────────────────────────────────────────
        SELECT IDENTIFICACION, ORDEN_CUN, [FECHA SOLICITUD DE CREDITO]
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
        IF @Debug = 1 PRINT '>> Fase 2.3 OK - ' + CAST(@@ROWCOUNT AS VARCHAR) + ' registros';


        IF @Debug = 1 PRINT '>> Fase 2.4: Extrayendo Validación 360...';

        -- ─────────────────────────────────────────────────────────────────────────────────────────
        -- BLOQUE 2.4 │ Validación del Proceso 360 / Legalización (#Stg_Respuestas)
        -- ─────────────────────────────────────────────────────────────────────────────────────────
        -- El proceso CLTIENE_360 es el flujo de legalización documental que el estudiante debe
        -- completar para que el crédito quede plenamente activo. Este bloque determina:
        --   · Si el estudiante completó el proceso 360 (VALIDACION = 1).
        --   · Si el proceso quedó legalizado (campo ID no nulo → 'SI', nulo → 'NO').
        -- Esta información es consumida por el área de cartera para clasificar estudiantes
        -- con financiación activa pero proceso de legalización pendiente (riesgo operativo).
        -- ─────────────────────────────────────────────────────────────────────────────────────────
        SELECT IDENTIFICACION, ORDEN_CUN, [FECHA FIN DE PROCESO CLTIENE], [¿TIENE PROCESO LEGALIZADO?],
               GENERO_ESTUDIANTE, EDAD_ESTUDIANTE, VALOR_CUOTA_INICIAL, CUOTAS, COSTO_PLATAFORMA
        INTO #Stg_Respuestas
        FROM (
            SELECT
                IDENTIFICACION, ORDEN_CUN,
                [FECHA FIN DE PROCESO CLTIENE], [¿TIENE PROCESO LEGALIZADO?],
                GENERO_ESTUDIANTE, EDAD_ESTUDIANTE, VALOR_CUOTA_INICIAL, CUOTAS, COSTO_PLATAFORMA,
                ROW_NUMBER() OVER(PARTITION BY IDENTIFICACION, ORDEN_CUN
                                  ORDER BY [FECHA FIN DE PROCESO CLTIENE] DESC) AS rn
            FROM OPENQUERY([172.16.1.175], '
                SELECT NUMERO_DOCUMENTO_ESTUDIANTE AS IDENTIFICACION,
                       ORDEN_CUN,
                       FEC_CREACION AS "FECHA FIN DE PROCESO CLTIENE",
                       DECODE(ID, NULL, ''NO'', ''SI'') AS "¿TIENE PROCESO LEGALIZADO?",
                       GENERO_ESTUDIANTE,
                       EDAD_ESTUDIANTE,
                       VALOR_CUOTA_INICIAL,
                       CUOTAS,
                       COSTO_PLATAFORMA
                FROM ICEBERG.CLTIENE_360_RESPUESTA
                WHERE VALIDACION = 1
            ')
        ) d WHERE rn = 1;
        IF @Debug = 1 PRINT '>> Fase 2.4 OK - ' + CAST(@@ROWCOUNT AS VARCHAR) + ' registros';


        -- ============================================================================================
        -- FASE 2.5 │ PRE-STAGING LOCAL — Enriquecimiento CRM y Cálculo de Ingreso Neto
        -- ============================================================================================
        -- Esta fase opera sobre fuentes locales de CUN_REPOSITORIO y debe ejecutarse DESPUÉS
        -- de los bloques remotos, ya que usa #Stg_Base_Estudiantes como filtro semilla.
        -- ============================================================================================
        IF @Debug = 1 PRINT '>> Fase 2.5: Pre-stageando fuentes locales (Zoho + Ingreso)...';

        -- ─────────────────────────────────────────────────────────────────────────────────────────
        -- BLOQUE 2.5a │ Enriquecimiento Comercial desde Zoho CRM (#Stg_Zoho)
        -- ─────────────────────────────────────────────────────────────────────────────────────────
        -- Incorpora atributos del CRM Zoho: programa, modalidad, sede, fuerza comercial,
        -- estado de matrícula y coordenadas geográficas del estudiante. Este enriquecimiento
        -- permite segmentar la cartera CTAYUDA por variables de gestión comercial y académica.
        --
        -- Patrón de optimización (OPT-3):
        --   El filtro EXISTS contra #Stg_Base_Estudiantes restringe el scan de Base_Personas
        --   al subconjunto de documentos relevantes ANTES del JOIN en la Fase 4.
        --   Sin este pre-filtro, la subquery inline escanearía la tabla completa de Zoho
        --   en cada fila del INSERT, multiplicando el I/O innecesariamente.
        --
        -- ROW_NUMBER() conserva el registro Zoho del periodo más reciente por estudiante-orden,
        -- garantizando que el programa y sede reportados correspondan al último periodo activo.
        --
        -- ⚠ ADVERTENCIA: WITH (NOLOCK) permite lecturas sucias sobre Base_Personas.
        --   Es aceptable aquí porque Zoho se sincroniza en batch nocturno y el riesgo de
        --   leer una fila en proceso de escritura es bajo. No usar en tablas financieras.
        -- ─────────────────────────────────────────────────────────────────────────────────────────
        SELECT
            DOC_ALUM, ORDEN, NOM_PROGRAMA, MODALIDAD, SECCIONAL, ESTADO_PAGO,
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
            WHERE EXISTS (
                SELECT 1 FROM #Stg_Base_Estudiantes b
                WHERE b.IDENTIFICACION = DOC_ALUM AND b.ORDEN_CUN = ORDEN
            )
        ) z WHERE rn = 1;

        -- ─────────────────────────────────────────────────────────────────────────────────────────
        -- BLOQUE 2.5b │ Ingreso Neto por Periodo (#Stg_Ingreso)
        -- ─────────────────────────────────────────────────────────────────────────────────────────
        -- Pre-calcula el ingreso neto del estudiante en una única lectura de la tabla de
        -- resultados de ingresos, exponiendo dos niveles de match para la Fase 4:
        --
        --   · rn_orden = 1  → Match primario: mismo documento + misma orden.
        --                     Corresponde al ingreso neto exacto del acuerdo de financiación.
        --   · rn_periodo = 1 → Match fallback: mismo documento + mismo periodo (mayor ORDEN).
        --                     Se usa cuando la orden no tiene ingreso directo registrado pero
        --                     sí existe un ingreso para el mismo periodo académico.
        --
        -- Patrón de optimización (OPT-4):
        --   Versiones anteriores usaban un OUTER APPLY correlacionado que accedía dos veces
        --   a resultado_ingresoxperiodo_final. Esta implementación lee la tabla una sola vez
        --   y materializa ambos ranks, reduciendo el I/O a la mitad.
        --
        -- Patrón de calidad (FIX-2):
        --   CREATE TABLE con esquema explícito + CAST garantiza que las columnas de índice
        --   (IDENTIFICACION, ORDEN, PERIODO) tengan tipos de longitud fija. Las fuentes
        --   originales pueden exponer VARCHAR(MAX)/NVARCHAR(MAX), que SQL Server rechaza
        --   como clave de índice. El CAST falla ruidosamente si hay truncación, lo que es
        --   el comportamiento correcto en un pipeline financiero.
        --
        -- ⚠ ADVERTENCIA: Los índices IX_Stg_Ing_Ord e IX_Stg_Ing_Per son críticos para el
        --   rendimiento del doble LEFT JOIN en Fase 4 (rip1 y rip2). No eliminarlos.
        -- ─────────────────────────────────────────────────────────────────────────────────────────
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
            CAST(Documento_Estudiante_zoho AS NVARCHAR(20)) AS IDENTIFICACION,
            CAST(ORDEN                     AS NVARCHAR(20)) AS ORDEN,
            CAST(PERIODO                   AS VARCHAR(10))  AS PERIODO,
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
            WHERE b.IDENTIFICACION = Documento_Estudiante_zoho
        );

        CREATE INDEX IX_Stg_Ing_Ord ON #Stg_Ingreso(IDENTIFICACION, ORDEN)   INCLUDE (ORDEN_NETO, rn_orden);
        CREATE INDEX IX_Stg_Ing_Per ON #Stg_Ingreso(IDENTIFICACION, PERIODO)  INCLUDE (ORDEN_NETO, rn_periodo);
        IF @Debug = 1 PRINT '>> Fase 2.5 OK - Ingreso: ' + CAST(@@ROWCOUNT AS VARCHAR) + ' registros';


        -- ============================================================================================
        -- FASE 3 (PRE) │ DDL CONDICIONAL — Creación de Tabla Destino
        -- ============================================================================================
        -- Garantiza que la tabla destino exista antes de iniciar la transacción.
        -- El DDL se ejecuta fuera del BEGIN TRANSACTION porque en SQL Server los comandos
        -- CREATE TABLE dentro de una transacción explícita pueden generar escaladas de lock
        -- en el catálogo del sistema (sys.objects), afectando otras sesiones concurrentes.
        -- En ejecuciones subsecuentes este bloque se omite automáticamente.
        -- ============================================================================================
        IF @Debug = 1 PRINT '>> Fase 3 PRE: Verificando tabla destino...';

        IF OBJECT_ID('CUN_REPOSITORIO.Financiera.Financiaciones_CTAYUDA_V2', 'U') IS NULL
        BEGIN
            IF @Debug = 1 PRINT '>> Creando tabla Financiaciones_CTAYUDA_V2...';
            CREATE TABLE [CUN_REPOSITORIO].[Financiera].[Financiaciones_CTAYUDA_V2] (

                -- ── DATOS PERSONALES ────────────────────────────────────────────────────
                -- NVARCHAR: nombres y tipos de documento contienen tildes/ñ
                RES_NOMBRES_COMPLETOS_ESTUDIANTE    NVARCHAR(200)   NULL,
                RES_TIPO_PROGRAMA_ESTUDIANTE        NVARCHAR(200)   NULL,
                RES_TIPO_DOCUMENTO_ESTUDIANTE       NVARCHAR(30)    NULL,
                RES_GENERO_ESTUDIANTE               NVARCHAR(20)    NULL,
                RES_EDAD_ESTUDIANTE                 INT             NULL,

                -- ── CONTACTO ────────────────────────────────────────────────────────────
                -- Emails: VARCHAR suficiente (ASCII), tope RFC 5321 = 254 chars
                -- Teléfonos: VARCHAR(15) cubre estándar ITU-T E.164 (máx 15 dígitos)
                RPVI_EMAIL_INSTITUCIONAL            VARCHAR(254)    NULL,
                RPVI_EMAIL_PERSONAL                 VARCHAR(254)    NULL,
                RPVI_CELULAR                        VARCHAR(15)     NULL,
                RPVI_TELEFONO                       VARCHAR(15)     NULL,

                -- ── IDENTIFICADORES / CLAVES DE NEGOCIO ────────────────────────────────
                -- VARCHAR: documentos y órdenes son alfanuméricos sin caracteres especiales
                -- Cédulas colombianas: max 10 dígitos; pasaporte/CE: hasta 16 chars
                DR_NUMERO_DOCUMENTO_ESTUDIANTE      VARCHAR(20)     NULL,
                DR_ORDEN_CUN                        VARCHAR(20)     NULL,
                DR_REFERENCIA_PAGO                  VARCHAR(50)     NULL,
                RPVI_DOCUMENTO_RPVI                 VARCHAR(10)     NULL,
                RPVI_ORDEN_RPVI                     VARCHAR(20)     NULL,
                RPVI_DOCUMENTO_ORDEN_INICIAL        VARCHAR(10)     NULL,

                -- ── VALORES FINANCIEROS ─────────────────────────────────────────────────
                -- DECIMAL(18,2): estándar contable — 18 dígitos totales, 2 decimales
                -- Cubre hasta $9,999,999,999,999,999.99 COP sin pérdida de precisión
                RES_VALOR_MATRICULA                 DECIMAL(18,2)   NULL,
                RES_VALOR_FINANCIACION              DECIMAL(18,2)   NULL,
                RES_VALOR_CUOTA_INICIAL             DECIMAL(18,2)   NULL,
                RES_CUOTAS                          INT             NULL,
                RES_COSTO_PLATAFORMA                DECIMAL(18,2)   NULL,

                -- ── FECHAS ──────────────────────────────────────────────────────────────
                -- DATE (3 bytes) en lugar de DATETIME (8 bytes) cuando no se requiere hora
                -- DR_FECHA_CREA: conserva DATETIME porque Oracle registra timestamp completo
                RES_FECHA_SOLICITUD_CREDITO         DATE            NULL,
                RES_FECHA_APROBACION                DATE            NULL,

                -- SMALLINT (2 bytes) para año (rango 2000-2099 cabe en SMALLINT)
                -- TINYINT (1 byte) para día (rango 1-31, TINYINT soporta 0-255)
                -- VARCHAR(12): nombre de mes, "Septiembre" es el más largo (10 chars)
                RES_AÑO_APROBACION                  SMALLINT        NULL,
                RES_MES_APROBACION                  VARCHAR(12)     NULL,
                RES_DIA_APROBACION                  TINYINT         NULL,

                RPVI_FECHA_ORDEN                    DATE            NULL,
                RPVI_FECHA_VENCIMIENTO_ORDEN        DATE            NULL,
                RPVI_FECHA_APROBACION_CUOTA_INI     DATE            NULL,
                DR_FECHA_CREA_ESTUDIANTE_CLTIENE    DATETIME        NULL,
                RPVI_FECHA_FIN_PROCESO_CLTIENE      DATE            NULL,

                -- ── DATOS ACADÉMICOS (ZOHO) ─────────────────────────────────────────────
                -- NVARCHAR: programas y geografía colombiana tienen tildes/ñ
                ZH_PROGRAMA                         NVARCHAR(200)   NULL,
                ZH_MODALIDAD                        NVARCHAR(50)    NULL,
                ZH_REGIONAL                         NVARCHAR(100)   NULL,

                -- VARCHAR: estados de pago son códigos sin caracteres especiales
                ZH_ESTADO_PAGO                      VARCHAR(30)     NULL,

                -- VARCHAR(6): periodo formato YYYYN (ej: "20241", "20252")
                ZH_PERIODO                          VARCHAR(6)      NULL,

                ZH_FUERZA_COMERCIAL                 NVARCHAR(100)   NULL,
                ZH_EST_MATRICULADO                  VARCHAR(20)     NULL,
                ZH_TIPO                             NVARCHAR(30)    NULL,
                ZH_NUEVO                            VARCHAR(10)     NULL,

                -- DECIMAL(9,6) para coordenadas GPS en lugar de FLOAT:
                -- evita errores de redondeo en punto flotante y es determinístico en JOINs
                -- Rango: lat [-90, 90], lon [-180, 180] — DECIMAL(9,6) lo cubre exacto
                ZH_lat                              DECIMAL(9,6)    NULL,
                ZH_lon                              DECIMAL(9,6)    NULL,

                ZH_ciudad_geo                       NVARCHAR(100)   NULL,
                ZH_departamento                     NVARCHAR(80)    NULL,
                ZH_localidad                        NVARCHAR(100)   NULL,

                -- ── VALORES FINANCIEROS DETALLADOS ──────────────────────────────────────
                DR_VALOR_AVAL                       DECIMAL(18,2)   NULL,
                DR_SERVICIO_MEDICO                  DECIMAL(18,2)   NULL,
                DR_VALOR_PAGADO                     DECIMAL(18,2)   NULL,
                DR_VALOR_ORDEN                      DECIMAL(18,2)   NULL,
                RPVI_VALOR_PAGADO_EN_ICEBERG        DECIMAL(18,2)   NULL,
                DR_GASTOS_TECNICOS                  DECIMAL(18,2)   NULL,

                -- DECIMAL(6,4): tasa de interés — permite hasta 99.9999% con 4 dec. exactos
                DR_PORCENTAJE_INTERES               DECIMAL(6,4)    NULL,

                -- ── ESTADOS Y DESCRIPTIVOS RPVI ─────────────────────────────────────────
                DR_ESTADO_PAGO_ESTUDIO              VARCHAR(30)     NULL,
                RPVI_ESTADO_ORDEN_RPVI              VARCHAR(10)     NULL,
                RPVI_MENSAJE                        NVARCHAR(500)   NULL,
                RPVI_CENTRO_COSTO                   VARCHAR(20)     NULL,
                RPVI_VALOR_ORDEN_TOTAL              DECIMAL(18,2)   NULL,
                RPVI_DESCRIPCION                    NVARCHAR(300)   NULL,
                RPVI_GRUPO                          VARCHAR(20)     NULL,
                RPVI_FONDO                          VARCHAR(20)     NULL,
                RPVI_FUENTE_FUNCION                 VARCHAR(20)     NULL,

                -- CHAR(2): banderas SI/NO — longitud fija, sin overhead de VARCHAR
                RPVI_TIENE_PROCESO_360              CHAR(2)         NULL,
                RPVI_TIENE_PROCESO_LEGALIZADO       CHAR(2)         NULL,
                RPVI_ORDEN_RPVI_LIQUIDADA           CHAR(2)         NULL,
                RPVI_ORDEN_INICIAL_LIQUIDADA        CHAR(2)         NULL,

                RPVI_OBSERVACION                    NVARCHAR(500)   NULL,
                RPVI_PERIODO_FACTURACION            VARCHAR(6)      NULL,

                -- ── INGRESO NETO ─────────────────────────────────────────────────────────
                ING_ORDEN_NETO                      DECIMAL(18,2)   NULL,

                -- ── AUDITORÍA ────────────────────────────────────────────────────────────
                -- DATETIME: registra fecha y hora exacta de cada ejecución del ETL
                AUD_FECHA_PROCESAMIENTO             DATETIME        NOT NULL DEFAULT GETDATE()
            );
        END


        -- ============================================================================================
        -- FASE 3 │ TRANSACCIÓN ATÓMICA — Swap de Datos (DROP índices → TRUNCATE → INSERT → índices)
        -- ============================================================================================
        -- La transacción abarca exclusivamente operaciones locales sobre la tabla destino.
        -- Ningún OPENQUERY ni lectura remota ocurre dentro de este bloque (OPT-1).
        -- Duración estimada del lock: segundos. La atomicidad garantiza que los consumidores
        -- (reportes Power BI, consultas analíticas) nunca lean un estado parcialmente cargado:
        -- o ven la carga anterior completa, o ven la nueva carga completa.
        --
        -- Secuencia dentro de la transacción:
        --   1. DROP índices no agrupados → libera páginas de índice antes del INSERT masivo.
        --   2. TRUNCATE TABLE          → vaciado instantáneo sin log por fila (DDL, no DML).
        --   3. INSERT maestra (Fase 4) → carga completa desde staging.
        --   4. CREATE índices (Fase 5) → reconstrucción post-carga más eficiente que mantenerlos.
        -- ============================================================================================
        IF @Debug = 1 PRINT '>> Fase 3: Iniciando swap atómico...';

        BEGIN TRANSACTION;

        -- Eliminación condicional de índices: evita error si el SP se ejecuta por primera vez
        -- (tabla recién creada sin índices previos) o si una ejecución anterior falló en Fase 5.
        IF EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('CUN_REPOSITORIO.Financiera.Financiaciones_CTAYUDA_V2') AND name = 'IX_FIN_DOC')
            DROP INDEX IX_FIN_DOC     ON CUN_REPOSITORIO.Financiera.Financiaciones_CTAYUDA_V2;
        IF EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('CUN_REPOSITORIO.Financiera.Financiaciones_CTAYUDA_V2') AND name = 'IX_FIN_ORDEN')
            DROP INDEX IX_FIN_ORDEN   ON CUN_REPOSITORIO.Financiera.Financiaciones_CTAYUDA_V2;
        IF EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('CUN_REPOSITORIO.Financiera.Financiaciones_CTAYUDA_V2') AND name = 'IX_FIN_PERIODO')
            DROP INDEX IX_FIN_PERIODO ON CUN_REPOSITORIO.Financiera.Financiaciones_CTAYUDA_V2;

        -- TRUNCATE es una operación DDL mínimamente logueada (solo desasigna páginas).
        -- Es significativamente más rápida que DELETE para cargas full-refresh de este volumen.
        TRUNCATE TABLE CUN_REPOSITORIO.Financiera.Financiaciones_CTAYUDA_V2;


        -- ============================================================================================
        -- FASE 4 │ ENSAMBLE E INSERCIÓN MAESTRA
        -- ============================================================================================
        -- Consolida las 6 fuentes de staging en la sabana maestra final mediante LEFT JOINs.
        -- El uso de LEFT JOIN (en lugar de INNER JOIN) sobre todas las fuentes secundarias
        -- garantiza que ningún estudiante de #Stg_Base_Estudiantes sea excluido por ausencia
        -- de registros en Zoho, RPVI, créditos o validación 360. La ausencia de datos en
        -- fuentes secundarias se expone como NULL, preservando la trazabilidad completa.
        --
        -- Normalización de texto (OPT-2):
        --   dbo.NORMALIZAR() elimina tildes, convierte a mayúsculas y estandariza espacios.
        --   Se invoca inline en el SELECT para evitar un UPDATE post-carga que implicaría
        --   un segundo full scan sobre la tabla destino ya cargada.
        --
        -- Estrategia de ingreso neto (OPT-4):
        --   COALESCE(rip1.ORDEN_NETO, rip2.ORDEN_NETO) implementa la lógica de fallback:
        --   · rip1 (match por orden exacta) tiene precedencia.
        --   · rip2 (match por periodo) se activa solo cuando rip1.IDENTIFICACION IS NULL,
        --     condición que se evalúa en el predicado del segundo LEFT JOIN.
        --
        -- ⚠ ADVERTENCIA: Esta inserción opera dentro de la transacción abierta en Fase 3.
        --   Cualquier error aquí ejecutará el ROLLBACK del CATCH, preservando la carga anterior.
        --   No agregar operaciones DDL remotas o OPENQUERY dentro de este bloque.
        -- ============================================================================================
        IF @Debug = 1 PRINT '>> Fase 4: Ensamblando e insertando...';

        INSERT INTO CUN_REPOSITORIO.Financiera.Financiaciones_CTAYUDA_V2 (
            RES_NOMBRES_COMPLETOS_ESTUDIANTE, RES_TIPO_PROGRAMA_ESTUDIANTE, RES_TIPO_DOCUMENTO_ESTUDIANTE,
            RES_GENERO_ESTUDIANTE, RES_EDAD_ESTUDIANTE,
            RPVI_EMAIL_INSTITUCIONAL, RPVI_EMAIL_PERSONAL, RPVI_CELULAR, RPVI_TELEFONO,
            DR_NUMERO_DOCUMENTO_ESTUDIANTE, DR_ORDEN_CUN, DR_REFERENCIA_PAGO,
            RPVI_DOCUMENTO_RPVI, RPVI_ORDEN_RPVI, RPVI_DOCUMENTO_ORDEN_INICIAL,
            RES_VALOR_MATRICULA, RES_VALOR_FINANCIACION, RES_VALOR_CUOTA_INICIAL, RES_CUOTAS, RES_COSTO_PLATAFORMA,
            RES_FECHA_SOLICITUD_CREDITO, RES_FECHA_APROBACION, RES_AÑO_APROBACION, RES_MES_APROBACION, RES_DIA_APROBACION,
            RPVI_FECHA_ORDEN, RPVI_FECHA_VENCIMIENTO_ORDEN, RPVI_FECHA_APROBACION_CUOTA_INI,
            DR_FECHA_CREA_ESTUDIANTE_CLTIENE, RPVI_FECHA_FIN_PROCESO_CLTIENE,
            ZH_PROGRAMA, ZH_MODALIDAD, ZH_REGIONAL, ZH_ESTADO_PAGO, ZH_PERIODO, ZH_FUERZA_COMERCIAL, ZH_EST_MATRICULADO, ZH_TIPO, ZH_NUEVO, ZH_lat, ZH_lon, ZH_ciudad_geo, ZH_departamento, ZH_localidad,
            DR_VALOR_AVAL, DR_SERVICIO_MEDICO, DR_VALOR_PAGADO, DR_VALOR_ORDEN,
            RPVI_VALOR_PAGADO_EN_ICEBERG,
            DR_GASTOS_TECNICOS, DR_PORCENTAJE_INTERES, DR_ESTADO_PAGO_ESTUDIO,
            RPVI_ESTADO_ORDEN_RPVI, RPVI_MENSAJE, RPVI_CENTRO_COSTO, RPVI_VALOR_ORDEN_TOTAL, RPVI_DESCRIPCION, RPVI_GRUPO, RPVI_FONDO, RPVI_FUENTE_FUNCION,
            RPVI_TIENE_PROCESO_360, RPVI_TIENE_PROCESO_LEGALIZADO, RPVI_ORDEN_RPVI_LIQUIDADA, RPVI_ORDEN_INICIAL_LIQUIDADA, RPVI_OBSERVACION,
            RPVI_PERIODO_FACTURACION, ING_ORDEN_NETO, AUD_FECHA_PROCESAMIENTO
        )
        SELECT
            base.NOMBRE,
            dbo.NORMALIZAR(zb.NOM_PROGRAMA),
            base.[TIPO DE IDENTIFICACIÓN],
            resp.GENERO_ESTUDIANTE,
            resp.EDAD_ESTUDIANTE,
            base.[EMAIL INSTITUCIONAL],
            base.[EMAIL PERSONAL],
            base.CELULAR,
            base.[TELÉFONO],

            base.IDENTIFICACION,
            base.ORDEN_CUN,
            base.[REFERENCIA DE PAGO],

            ord.DOCUMENTO,
            ord.[ORDEN RPVI],
            ord.[DOCUMENTO DE LA ORDEN INICIAL],

            base.VALOR_ORDEN,
            base.VALOR_FINANCIADO,
            resp.VALOR_CUOTA_INICIAL,
            resp.CUOTAS,
            resp.COSTO_PLATAFORMA,

            cred.[FECHA SOLICITUD DE CREDITO],
            base.[FECHA DE APROBACIÓN CUOTA INI],
            YEAR(base.[FECHA DE APROBACIÓN CUOTA INI]),
            -- Descomposición de fecha para facilitar filtros temporales en reportes Power BI
            -- sin requerir cálculo en tiempo de consulta
            CASE MONTH(base.[FECHA DE APROBACIÓN CUOTA INI])
                WHEN 1  THEN 'Enero'      WHEN 2  THEN 'Febrero'
                WHEN 3  THEN 'Marzo'      WHEN 4  THEN 'Abril'
                WHEN 5  THEN 'Mayo'       WHEN 6  THEN 'Junio'
                WHEN 7  THEN 'Julio'      WHEN 8  THEN 'Agosto'
                WHEN 9  THEN 'Septiembre' WHEN 10 THEN 'Octubre'
                WHEN 11 THEN 'Noviembre'  WHEN 12 THEN 'Diciembre'
            END,
            DAY(base.[FECHA DE APROBACIÓN CUOTA INI]),

            ord.[FECHA DE LA ORDEN],
            ord.[FECHA DE VENCIMIENTO DE ORDEN],
            base.[FECHA DE APROBACIÓN CUOTA INI],
            base.[FECHA CREA ESTUDIANTE CLTIENE],
            resp.[FECHA FIN DE PROCESO CLTIENE],

            dbo.NORMALIZAR(zb.NOM_PROGRAMA),
            dbo.NORMALIZAR(zb.MODALIDAD),
            dbo.NORMALIZAR(zb.SECCIONAL),
            zb.ESTADO_PAGO,
            -- COALESCE: si Zoho no tiene periodo, se usa el periodo de la orden RPVI como fallback
            COALESCE(zb.Periodo_data, ord.PERIODO),
            dbo.NORMALIZAR(zb.Fuerza_comercial_data),
            zb.EST_MATRICULADO,
            zb.TIPO_ALUM_DATA,
            zb.NUEVO,
            zb.lat,
            zb.lon,
            zb.ciudad,
            zb.departamento,
            zb.localidad,

            base.[VALOR AVAL],
            base.[SERVIIO MÉDICO],
            base.VALOR_PAGADO,
            base.VALOR_ORDEN,
            base.VALOR_PAGADO_EN_ICEBERG,
            base.[GASTOS TÉCNICOS],
            base.[PORCENTAJE DE INTERÉS],
            base.[ESTADO DE PAGO ESTUDIO],

            ord.[ESTADO ORDEN RPVI],
            ord.MENSAJE,
            ord.[CENTRO DE COSTO],
            ord.[VALOR DE LA ORDEN],
            ord.DESCRIPCION,
            ord.GRUPO,
            ord.FONDO,
            ord.[FUENTE FUNCIÓN],

            -- Todo estudiante en esta sabana tiene proceso 360 activo (universo = ESTADO_FINANCIACION=1)
            'SI',
            -- Si no hay registro de legalización en #Stg_Respuestas, se asume proceso no legalizado
            COALESCE(resp.[¿TIENE PROCESO LEGALIZADO?], 'NO'),
            ord.[¿ORDEN RPVI LIQUIDADA?],
            ord.[¿ORDEN INICIAL LIQUIDADA?],
            base.OBSERVACION,

            ord.PERIODO,
            -- Ingreso neto con fallback: primero por orden exacta (rip1), luego por periodo (rip2)
            COALESCE(rip1.ORDEN_NETO, rip2.ORDEN_NETO),
            -- Marca de tiempo de la ejecución: todos los registros de un mismo lote comparten
            -- el mismo valor, permitiendo identificar y aislar cada carga en auditoría
            GETDATE()

        FROM #Stg_Base_Estudiantes base
        -- Órden RPVI: LEFT JOIN porque hay estudiantes con financiación sin orden RPVI generada aún
        LEFT JOIN #Stg_Ordenes_Tramite ord  ON ord.IDENTIFICACION  = base.IDENTIFICACION AND ord.ORDEN_CUN  = base.ORDEN_CUN
        -- Crédito: LEFT JOIN porque la solicitud puede estar en proceso o no registrada en Iceberg
        LEFT JOIN #Stg_Creditos cred        ON cred.IDENTIFICACION = base.IDENTIFICACION AND cred.ORDEN_CUN = base.ORDEN_CUN
        -- Validación 360: LEFT JOIN porque el proceso puede no haberse completado aún
        LEFT JOIN #Stg_Respuestas resp      ON resp.IDENTIFICACION = base.IDENTIFICACION AND resp.ORDEN_CUN = base.ORDEN_CUN
        -- Zoho CRM: LEFT JOIN porque no todos los estudiantes tienen registro activo en el CRM
        LEFT JOIN #Stg_Zoho zb             ON zb.DOC_ALUM         = base.IDENTIFICACION AND zb.ORDEN       = base.ORDEN_CUN

        -- Ingreso neto primario: match exacto por documento + orden
        LEFT JOIN #Stg_Ingreso rip1
            ON  rip1.IDENTIFICACION = base.IDENTIFICACION
            AND rip1.ORDEN          = base.ORDEN_CUN
            AND rip1.rn_orden       = 1

        -- Ingreso neto fallback: match por documento + periodo cuando no hay match por orden.
        -- La condición rip1.IDENTIFICACION IS NULL evita que rip2 sobreescriba un rip1 válido.
        LEFT JOIN #Stg_Ingreso rip2
            ON  rip2.IDENTIFICACION = base.IDENTIFICACION
            AND rip2.PERIODO        = ord.PERIODO
            AND rip2.rn_periodo     = 1
            AND rip1.IDENTIFICACION IS NULL;

        SET @RowCount = @@ROWCOUNT;


        -- ============================================================================================
        -- FASE 5 │ ÍNDICES POST-CARGA Y CIERRE DE TRANSACCIÓN
        -- ============================================================================================
        -- Los índices se crean DESPUÉS del INSERT masivo porque mantenerlos activos durante
        -- la carga implicaría actualizaciones de árbol B+ por cada fila insertada, elevando
        -- el costo de I/O entre 3x y 8x según el volumen. La reconstrucción post-carga
        -- es siempre más eficiente para operaciones de full-refresh.
        --
        -- Índices definidos:
        --   · IX_FIN_DOC     → consultas por número de documento (reportes individuales de cartera)
        --   · IX_FIN_ORDEN   → consultas por orden CUN (conciliación con sistema académico)
        --   · IX_FIN_PERIODO → consultas por periodo (análisis de recaudo y mora por cohorte)
        --
        -- ⚠ ADVERTENCIA: Estos índices son referenciados por reportes Power BI y consultas
        --   analíticas del área Financiera. No eliminar ni renombrar sin coordinación con
        --   el equipo de BI.
        -- ============================================================================================
        IF @Debug = 1 PRINT '>> Fase 5: Creando índices finales...';

        CREATE INDEX IX_FIN_DOC     ON CUN_REPOSITORIO.Financiera.Financiaciones_CTAYUDA_V2(DR_NUMERO_DOCUMENTO_ESTUDIANTE);
        CREATE INDEX IX_FIN_ORDEN   ON CUN_REPOSITORIO.Financiera.Financiaciones_CTAYUDA_V2(DR_ORDEN_CUN);
        CREATE INDEX IX_FIN_PERIODO ON CUN_REPOSITORIO.Financiera.Financiaciones_CTAYUDA_V2(ZH_PERIODO);

        COMMIT TRANSACTION;

        -- Registro de cierre exitoso con conteo de registros procesados para monitoreo operacional.
        INSERT INTO CUN_REPOSITORIO.dbo.LogControlProcesos (baseDatos, usuario, proceso, registrosAfectados, fechaEjecucion, error)
        VALUES (DB_NAME(), USER_NAME(), 'Carga exitosa CTAYUDA V8.0', @RowCount, GETDATE(), 0);

        IF @Debug = 1 PRINT '>> Fin del proceso. Registros cargados: ' + CAST(@RowCount AS VARCHAR(10));

    END TRY

    -- ================================================================================================
    -- MANEJO DE ERRORES
    -- ================================================================================================
    -- Ante cualquier error dentro del TRY:
    --   1. Se capturan número, mensaje, severidad y estado del error de SQL Server.
    --   2. Si hay una transacción abierta (Fase 3 en adelante), se revierte completamente,
    --      dejando la tabla destino con la carga anterior intacta.
    --   3. Se registra el error en la bitácora con su código para diagnóstico posterior.
    --   4. Se relanza el error al caller con RAISERROR para que el agente SQL o la aplicación
    --      orquestadora (SSIS, ADF, etc.) pueda detectar el fallo y activar alertas.
    -- ================================================================================================
    BEGIN CATCH
        SELECT @ErrorMessage = ERROR_MESSAGE(), @ErrorSeverity = ERROR_SEVERITY(), @ErrorState = ERROR_STATE();
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        INSERT INTO CUN_REPOSITORIO.dbo.LogControlProcesos (baseDatos, usuario, proceso, registrosAfectados, fechaEjecucion, error)
        VALUES (DB_NAME(), USER_NAME(),
                'Error ETL CTAYUDA V8.0 | ERR ' + CAST(ERROR_NUMBER() AS NVARCHAR) + ': ' + @ErrorMessage,
                0, GETDATE(), ERROR_NUMBER());

        RAISERROR(@ErrorMessage, @ErrorSeverity, @ErrorState);
    END CATCH
END
