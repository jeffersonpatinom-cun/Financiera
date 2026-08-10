
-- ====================================================================================================
-- ██████████████████████████████████████████████████████████████████████████████████████████████████
--
--  PROCEDIMIENTO : [Financiera].[SP_Cartera_Total]
--  BASE DE DATOS : CUN_REPOSITORIO
--  ESQUEMA       : Financiera
--  AUTOR         : Arquitectura de Datos — Universidad CUN
--  FECHA SCRIPT  : 2026-04-27
--
-- ──────────────────────────────────────────────────────────────────────────────────────────────────
--  RESUMEN EJECUTIVO
-- ──────────────────────────────────────────────────────────────────────────────────────────────────
--  Construye la sabana maestra de cartera activa (documento NDB) consolidando la cartera bruta
--  extraída desde Oracle Iceberg con información académica y comercial (Zoho, ESTADISTICA,
--  Moodle). Adicionalmente detecta cuotas canceladas por comparación diaria (foto de ayer vs.
--  cartera fresca de hoy) y registra los pagos en Creditos_pagos_CTAYUDA.
--  El resultado alimenta los dashboards de riesgo, mora y recaudo del área Financiera CUN.
--
-- ──────────────────────────────────────────────────────────────────────────────────────────────────
--  TABLAS DE SALIDA Y COLUMNA DE AUDITORÍA
-- ──────────────────────────────────────────────────────────────────────────────────────────────────
--  Todas las tablas de salida incluyen la columna AUD_FECHA_PROCESAMIENTO (DATETIME NOT NULL)
--  que registra el instante exacto de ejecución del ETL. Todos los registros de un mismo lote
--  comparten el mismo valor, permitiendo identificar y aislar cada carga para auditoría y
--  trazabilidad operacional.
--
--   · Financiera.Cartera_Foto_Ayer        → Snapshot de Cartera_Gestion previo al refresh.
--   · Financiera.Cartera_Total            → Sabana maestra enriquecida con datos académicos.
--   · Financiera.Cartera_Gestion          → Vista operativa final con datos Moodle y cuotas.
--   · Financiera.Creditos_pagos_CTAYUDA   → Registro acumulado de cuotas canceladas.
--
-- ──────────────────────────────────────────────────────────────────────────────────────────────────
--  ARQUITECTURA DE EJECUCIÓN (flujo secuencial)
-- ──────────────────────────────────────────────────────────────────────────────────────────────────
--   PASO 0 │ Respaldar estado de ayer en Cartera_Foto_Ayer (antes de cualquier DROP)
--   PASO 1 │ Extraer cartera bruta desde Oracle Iceberg → Financiera.Cartera (staging)
--   PASO 3 │ Construir sabana enriquecida → Financiera.Cartera_Total
--   PASO 4 │ Crear/recargar Financiera.Cartera_Gestion (enriquecida con Moodle y NRO_CUOTA)
--   PASO 5 │ Detectar cuotas pagadas (anti-join foto ayer vs. hoy) → Creditos_pagos_CTAYUDA
--   AUDIT  │ Validación de integridad: suma TOTAL Cartera_Total vs. Cartera_Gestion
--
--  ⚠ ADVERTENCIA: Todo el proceso corre dentro de una única transacción explícita.
--    Los pasos 1-5 son atómicos. Si cualquier paso falla, se revierte todo y la tabla
--    Cartera_Gestion queda en su estado anterior. No modificar el scope de la transacción
--    sin analizar el impacto en bloqueos concurrentes sobre las tablas Financiera.*.
--
-- ──────────────────────────────────────────────────────────────────────────────────────────────────
--  FUENTES DE DATOS
-- ──────────────────────────────────────────────────────────────────────────────────────────────────
--   · [172.16.1.175] (Linked Server Oracle) — ICEBERG.VM_CARTERA_CORPORATIVA
--   · [CUN_REPOSITORIO].[ZOHO].[BASE_PERSONAS]          : datos CRM Zoho por periodo
--   · [CUN_REPOSITORIO].[CUN].[ESTADISTICA_ESTUDIANTE_2]: estadística académica deduplicada
--   · [CUN_REPOSITORIO].[CUN].[ESTADISTICA_ACADEMICA]   : fallback académico por semestre
--   · [CUN_REPOSITORIO].[DBARON].[CURSOS_MOODLE_2026]   : último acceso a plataforma virtual
--   · [CUN_REPOSITORIO].[Dbo].[Periodos_Calendario]     : fechas inicio/fin de cada periodo
--
-- ──────────────────────────────────────────────────────────────────────────────────────────────────
--  BITÁCORA DE CAMBIOS
-- ──────────────────────────────────────────────────────────────────────────────────────────────────
--  2026-04-27 │ ADD: Columna AUD_FECHA_PROCESAMIENTO (DATETIME NOT NULL) en las 4 tablas
--             │      de salida para trazabilidad de carga y auditoría operacional.
--             │ ADD: Documentación técnica completa del procedimiento.
--
-- ██████████████████████████████████████████████████████████████████████████████████████████████████
-- ====================================================================================================

ALTER PROCEDURE [Financiera].[SP_Cartera_Total]
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @err_mensaje   VARCHAR(2000)
    DECLARE @err_linea     INT
    DECLARE @err_severidad INT
    DECLARE @total_ct      DECIMAL(18,2)
    DECLARE @total_cg      DECIMAL(18,2)
    DECLARE @diferencia    DECIMAL(18,2)
    DECLARE @filas_ct      INT
    DECLARE @filas_cg      INT
    DECLARE @estado        VARCHAR(20)
    DECLARE @mensaje_log   VARCHAR(500)

    BEGIN TRY

        BEGIN TRANSACTION

        -- ==========================================================================================
        -- PASO 0 │ SNAPSHOT DE CARTERA_GESTION (foto de ayer)
        -- ==========================================================================================
        -- Antes de que el proceso reconstruya las tablas, se persiste el estado actual de
        -- Cartera_Gestion en Cartera_Foto_Ayer. Esta "foto" es la línea base para detectar
        -- cuotas que desaparecieron entre la ejecución de ayer y la de hoy (Paso 5).
        -- Solo se extraen las 7 columnas necesarias para la comparación de cuotas, más la
        -- marca de auditoría para saber a qué ejecución corresponde el snapshot.
        --
        -- ⚠ Se filtra exclusivamente DOCUMENTO = 'NDB' para aislar cartera de libranza
        --   y evitar contaminación con otros tipos de documento en la detección de pagos.
        -- ==========================================================================================
        IF OBJECT_ID('Financiera.Cartera_Gestion', 'U') IS NOT NULL
        BEGIN
            DROP TABLE IF EXISTS Financiera.Cartera_Foto_Ayer;

            SELECT
                PERIODO,
                IDENTIFICACION      AS NUMERO_DOCUMENTO,
                NOMBRE_CAUSA,
                NUMERO_CREDITO,
                NRO_CUOTA,
                TOTAL,
                FECHA_VENCIMIENTO,
                GETDATE()           AS AUD_FECHA_PROCESAMIENTO   -- Marca de cuándo se tomó el snapshot
            INTO Financiera.Cartera_Foto_Ayer
            FROM Financiera.Cartera_Gestion
            WHERE DOCUMENTO = 'NDB';
        END


        -- ==========================================================================================
        -- PASO 1 │ EXTRACCIÓN CARTERA BRUTA DESDE ORACLE ICEBERG
        -- ==========================================================================================
        -- Recarga completa de la cartera corporativa desde la vista materializada en Oracle.
        -- Financiera.Cartera actúa como tabla de staging: se destruye y recrea en cada ejecución.
        -- No es una tabla de salida final; solo sirve como insumo para los pasos 3 y 4.
        --
        -- ⚠ ADVERTENCIA: OPENQUERY delega la ejecución al motor Oracle remoto (172.16.1.175).
        --   El volumen de esta vista puede ser significativo. No agregar filtros aquí sin
        --   coordinar con el equipo de infraestructura Oracle, ya que el predicado no se
        --   envía al servidor remoto con SELECT * en OPENQUERY.
        -- ==========================================================================================
        DROP TABLE IF EXISTS Financiera.Cartera;

        SELECT *
        INTO Financiera.Cartera
        FROM OPENQUERY([172.16.1.175],
                'SELECT *
                 FROM ICEBERG.VM_CARTERA_CORPORATIVA')


        -- ==========================================================================================
        -- PASO 3 │ CONSTRUCCIÓN DE LA SABANA MAESTRA ENRIQUECIDA (Cartera_Total)
        -- ==========================================================================================
        -- Cruza la cartera bruta (Financiera.Cartera) con tres fuentes de información académica
        -- usando una jerarquía de precedencia COALESCE para garantizar que ningún estudiante
        -- quede sin datos cuando falta una fuente:
        --
        --   Prioridad 1: ESTADISTICA_DEDUP    (ESTADISTICA_ESTUDIANTE_2 — deduplicado por ciclo y estado)
        --   Prioridad 2: ZOHO_BASE            (CRM Zoho — periodo más reciente por alumno)
        --   Prioridad 3: ESTADISTICA_ACADEMICA (fallback por último semestre registrado)
        --
        -- Adicionalmente incorpora MARCA_ACADEMICA: clasificación de riesgo académico basada
        -- en el promedio y el estado del periodo (activo / perdido / gestionable), clave para
        -- priorizar la gestión de cobro.
        --
        -- Filtro de periodos: solo se procesa cartera desde 2022 en adelante (LIKE '%22%' ... '%26%').
        -- Filtro de documento: exclusivamente NDB (cartera de libranza/financiación estudiantil).
        --
        -- ⚠ Los CAST a DECIMAL(18,2) en las columnas de mora (GR1A30 ... GR360MAS, TOTAL) son
        --   necesarios porque Oracle puede retornarlas con precisión variable. No eliminarlos.
        -- ==========================================================================================
        DROP TABLE IF EXISTS Financiera.Cartera_Total;

        WITH ZOHO_BASE AS (
                SELECT
                        DOC_ALUM                AS NUM_IDENTIFICACION,
                        PERIODO                 AS COD_PERIODO,
                        NOM_PROGRAMA            AS NOM_UNIDAD,
                        SECCIONAL               AS NOM_SECCIONAL,
                        MODALIDAD,
                        NIVEL                   AS CICLO,
                        EST_MATRICULADO         AS ESTADO_ALUMNO,
                        NUEVO,
                        NULL                    AS PROMEDIO,
                        NULL                    AS SEMESTRE,
                        ROW_NUMBER() OVER (PARTITION BY DOC_ALUM, PERIODO ORDER BY DOC_ALUM) AS rn_zoho
                FROM ZOHO.BASE_PERSONAS
        ),
        ESTADISTICA_DEDUP AS (
                SELECT NUM_IDENTIFICACION, COD_PERIODO, NOM_UNIDAD, NOM_SECCIONAL,
                       MODALIDAD, CICLO, ESTADO_ALUMNO, NUEVO, PROMEDIO, SEMESTRE
                FROM (
                        SELECT NUM_IDENTIFICACION, COD_PERIODO, NOM_UNIDAD, NOM_SECCIONAL,
                               MODALIDAD, CICLO, ESTADO_ALUMNO, NUEVO, PROMEDIO, SEMESTRE,
                                ROW_NUMBER() OVER (
                                        PARTITION BY NUM_IDENTIFICACION, COD_PERIODO
                                        ORDER BY ORDEN_CICLO ASC, ORDEN_ESTADO ASC, COD_PERIODO DESC
                                ) AS rn
                        FROM (
                                SELECT *,
                                        CASE WHEN CICLO = 'Profesional'                    THEN 1
                                             WHEN CICLO = 'Tecn' + CHAR(243) + 'logo'      THEN 2
                                             WHEN CICLO = 'T' + CHAR(233) + 'cnico Profesional' THEN 3
                                             ELSE 99 END AS ORDEN_CICLO,
                                        CASE WHEN ESTADO_ALUMNO = '1-Activo'    THEN 1
                                             WHEN ESTADO_ALUMNO = '-1-Inscrito' THEN 2
                                             WHEN ESTADO_ALUMNO = '4-Traslado'  THEN 3
                                             ELSE 9 END AS ORDEN_ESTADO
                                FROM CUN.ESTADISTICA_ESTUDIANTE_2
                        ) A_sub
                ) x WHERE rn = 1
        ),
        ESTADISTICA_ACADEMICA AS (
                SELECT DISTINCT NUM_IDENTIFICACION, COD_PERIODO, NOM_UNIDAD,
                        NULL AS NOM_SECCIONAL, MODALIDAD, NIVEL_FORMACION AS CICLO,
                        CASE
                                WHEN EST_ALUMNO = 'Activo'           THEN '1-Activo'
                                WHEN EST_ALUMNO = 'Egresado'         THEN '2-Egresado'
                                WHEN EST_ALUMNO = 'Graduado'         THEN '3-Graduado'
                                WHEN EST_ALUMNO = 'Graduado Postumo' THEN '12-Graduado Postumo'
                                ELSE EST_ALUMNO
                        END AS ESTADO_ALUMNO,
                        NULL AS NUEVO, PROMEDIO, SEMESTRE,
                        ROW_NUMBER() OVER (PARTITION BY NUM_IDENTIFICACION ORDER BY SEMESTRE DESC) AS PERIODO_PRIORIDAD
                FROM CUN.ESTADISTICA_ACADEMICA
        )
        SELECT
                A.PERIODO, A.TIPO_CLIENTE, A.NOMBRE_TIPO_CLIENTE, A.IDENTIFICACION,
                A.LINEA, A.DOCUMENTO, A.NUMERO_CREDITO, A.FECHA, A.FECHA_VENCIMIENTO,
                A.CENTRO_COSTO, A.NOMBRE_CONCEPTO, A.NOMBRE_CAUSA, A.VALOR_ORIGINAL, A.CORRIENTE,
                CAST(A.GR1A30         AS DECIMAL(18,2)) AS GR1A30,
                CAST(A.GR31A60        AS DECIMAL(18,2)) AS GR31A60,
                CAST(A.GR61A90        AS DECIMAL(18,2)) AS GR61A90,
                CAST(A.GR91A120       AS DECIMAL(18,2)) AS GR91A120,
                CAST(A.GR121A150      AS DECIMAL(18,2)) AS GR121A150,
                CAST(A.GR151A360      AS DECIMAL(18,2)) AS GR151A360,
                CAST(A.GR360MAS       AS DECIMAL(18,2)) AS GR360MAS,
                CAST(A.TOTAL          AS DECIMAL(18,2)) AS TOTAL,
                COALESCE(B.ESTADO_ALUMNO, Z.ESTADO_ALUMNO, E.ESTADO_ALUMNO) AS ESTADO_ALUMNO,
                COALESCE(B.NOM_UNIDAD,    Z.NOM_UNIDAD,    E.NOM_UNIDAD)    AS NOM_UNIDAD,
                COALESCE(B.NOM_SECCIONAL, Z.NOM_SECCIONAL, E.NOM_SECCIONAL) AS NOM_SECCIONAL,
                COALESCE(B.MODALIDAD,     Z.MODALIDAD,     E.MODALIDAD)     AS MODALIDAD,
                COALESCE(B.CICLO,         Z.CICLO,         E.CICLO)         AS CICLO,
                COALESCE(B.NUEVO,         Z.NUEVO,         E.NUEVO)         AS NUEVO,
                COALESCE(B.PROMEDIO, E.PROMEDIO)                            AS PROMEDIO,
                COALESCE(B.SEMESTRE, E.SEMESTRE)                            AS SEMESTRE,
                C.ESTADO,
                CASE
                        WHEN C.ESTADO = 'ACTIVO'                   THEN 'PERIODO EN CURSO'
                        WHEN C.ESTADO = 'PERIODO NO HA INICIADO'   THEN 'PERIODO NO HA INICIADO'
                        ELSE CASE
                                WHEN C.ESTADO = 'NO ACTIVO' AND B.PROMEDIO < 1.55                 THEN 'SIN REGISTRO DE CLASE'
                                WHEN C.ESTADO = 'NO ACTIVO' AND B.PROMEDIO BETWEEN 1.56 AND 2.95  THEN 'PERIODO PERDIDO, PRIORIDAD ALTA'
                                WHEN C.ESTADO = 'NO ACTIVO' AND B.PROMEDIO > 2.95                 THEN 'GESTIONABLE'
                        END
                END AS MARCA_ACADEMICA,
                GETDATE() AS AUD_FECHA_PROCESAMIENTO   -- Marca de auditoría: instante de carga del lote
        INTO Financiera.Cartera_Total
        FROM Financiera.Cartera A
        LEFT JOIN ESTADISTICA_DEDUP B
                ON CONVERT(VARCHAR(50), A.IDENTIFICACION) = B.NUM_IDENTIFICACION
                AND A.PERIODO = B.COD_PERIODO
        LEFT JOIN (SELECT * FROM ZOHO_BASE WHERE rn_zoho = 1) Z
                ON CONVERT(VARCHAR(50), A.IDENTIFICACION) = Z.NUM_IDENTIFICACION
                AND A.PERIODO = Z.COD_PERIODO
        LEFT JOIN (SELECT * FROM ESTADISTICA_ACADEMICA WHERE PERIODO_PRIORIDAD = 1) E
                ON CONVERT(VARCHAR(50), A.IDENTIFICACION) = E.NUM_IDENTIFICACION
                AND A.PERIODO = E.COD_PERIODO
        LEFT JOIN (
                SELECT DISTINCT CONVERT(VARCHAR(10), cod_periodo) AS PERIODO,
                        CASE
                                WHEN fec_inicio > CAST(GETDATE() AS DATE)      THEN 'PERIODO NO HA INICIADO'
                                WHEN fec_inicio <= CAST(GETDATE() AS DATE) AND fec_fin >= CAST(GETDATE() AS DATE)  THEN 'ACTIVO'
                                ELSE 'NO ACTIVO'
                        END AS ESTADO
                FROM Dbo.Periodos_Calendario
        ) C ON A.PERIODO = C.PERIODO
        WHERE (A.PERIODO LIKE '%22%' OR A.PERIODO LIKE '%23%' OR
               A.PERIODO LIKE '%24%' OR A.PERIODO LIKE '%25%' OR A.PERIODO LIKE '%26%')
          AND A.DOCUMENTO = 'NDB'


        -- ==========================================================================================
        -- PASO 4 │ CARGA DE CARTERA_GESTION (tabla operativa final)
        -- ==========================================================================================
        -- Cartera_Gestion es la tabla que consumen directamente los equipos de cobranza y los
        -- reportes Power BI. Incorpora, adicionalmente a Cartera_Total:
        --   · Datos personales completos del deudor (contacto, dirección, WHATSAPP)
        --   · Último acceso a plataforma Moodle (indicador de actividad académica para cobranza)
        --   · NRO_CUOTA: extraído del campo DESCRIPCION mediante parsing de texto estructurado,
        --     permite seguimiento granular por cuota dentro de un mismo crédito.
        --
        -- Estrategia DDL: DROP TABLE IF EXISTS + SELECT INTO (full-refresh atómico).
        --   · Elimina la tabla preexistente y la recrea con el esquema exacto del SELECT.
        --   · Evita el error 207 (columna inválida) que ocurre cuando SQL Server compila
        --     un INSERT INTO contra una tabla que aún no tiene las nuevas columnas DDL.
        --
        -- ⚠ El DROP dentro de la transacción es intencional: garantiza atomicidad.
        --   Si el SELECT INTO falla, el ROLLBACK restaura la tabla en su estado anterior.
        -- ==========================================================================================

        -- Recarga completa: DROP + SELECT INTO evita conflictos de compilación al añadir columnas
        DROP TABLE IF EXISTS Financiera.Cartera_Gestion;

        -- ─────────────────────────────────────────────────────────────────────────────────────────
        -- SELECT INTO Cartera_Gestion
        -- ─────────────────────────────────────────────────────────────────────────────────────────
        -- Deduplicaciones previas:
        --   · Cartera_Total_Dedup: un registro por (IDENTIFICACION, PERIODO) para el LEFT JOIN.
        --   · Estadistica_Dedup: prioriza ciclo superior (Profesional > Tecnólogo > Técnico)
        --     y estado activo, evitando duplicar filas por múltiples programas simultáneos.
        --   · Moodle_Dedup: conserva el MAX del último acceso por cédula para evitar
        --     multiplicar filas si el estudiante tiene varios cursos registrados en Moodle.
        --
        -- NRO_CUOTA: se extrae mediante CHARINDEX + SUBSTRING sobre el campo DESCRIPCION de Oracle.
        --   El patrón esperado es: "... EN LA CUOTA: {número} POR EL ..."
        --   TRY_CAST evita fallos si el campo no contiene el patrón esperado.
        -- ─────────────────────────────────────────────────────────────────────────────────────────
        WITH
        Cartera_Total_Dedup AS (
            SELECT IDENTIFICACION, PERIODO, NOM_UNIDAD, NUEVO, PROMEDIO, SEMESTRE,
                NOM_SECCIONAL, MODALIDAD, CICLO, MARCA_ACADEMICA, ESTADO_ALUMNO,
                ROW_NUMBER() OVER (PARTITION BY IDENTIFICACION, PERIODO ORDER BY IDENTIFICACION) AS rn
            FROM Financiera.Cartera_Total
        ),
        Estadistica_Dedup AS (
            SELECT NUM_IDENTIFICACION, COD_PERIODO, PROMEDIO, SEMESTRE
            FROM (
                SELECT NUM_IDENTIFICACION, COD_PERIODO, PROMEDIO, SEMESTRE,
                    ROW_NUMBER() OVER (
                        PARTITION BY NUM_IDENTIFICACION, COD_PERIODO
                        ORDER BY
                            CASE WHEN CICLO = 'Profesional'                    THEN 1
                                 WHEN CICLO = 'Tecn' + CHAR(243) + 'logo'      THEN 2
                                 WHEN CICLO = 'T' + CHAR(233) + 'cnico Profesional' THEN 3
                                 ELSE 99 END ASC,
                            CASE WHEN ESTADO_ALUMNO = '1-Activo'    THEN 1
                                 WHEN ESTADO_ALUMNO = '-1-Inscrito' THEN 2
                                 WHEN ESTADO_ALUMNO = '4-Traslado'  THEN 3
                                 ELSE 9 END ASC,
                        COD_PERIODO DESC
                    ) AS rn
                FROM CUN.ESTADISTICA_ESTUDIANTE_2
            ) x WHERE rn = 1
        ),
        Moodle_Dedup AS (
            SELECT cedula, MAX(ultimoaccesoplataformlimpio) AS ultimoaccesoplataformlimpio
            FROM DBARON.CURSOS_MOODLE_2026
            GROUP BY cedula
        )
        SELECT
            C.PERIODO, C.TIPO_CLIENTE, C.NOMBRE_TIPO_CLIENTE, C.IDENTIFICACION,
            C.FEC_NAC, C.GENDER, C.DIRECCION_CASA, C.EMAIL, C.TEL_CASA,
            C.TEL_CELULAR, C.WHATSAPP, C.PAIS, C.DEPARTAMENTO, C.CLIENTE,
            C.NOMBRE, C.LINEA, C.TIPO_DOCUMENTO, C.DOCUMENTO, C.NUMERO_CREDITO,
            C.FECHA, C.FECHA_VENCIMIENTO, C.CENTRO_COSTO, C.NOMBRE_CENTRO,
            C.FONDO, C.NOMBRE_FONDO, C.NOMBRE_CONCEPTO, C.NOMBRE_CAUSA,
            C.VALOR_ORIGINAL, C.CORRIENTE, C.GR1A30, C.GR31A60, C.GR61A90,
            C.GR91A120, C.GR121A150, C.GR151A360, C.GR360MAS, C.TOTAL,
            C.CODIGO_CONTABLE, C.DESCRIPCION,
            CT.NOM_UNIDAD, CT.NUEVO,
            COALESCE(EE.SEMESTRE, CT.SEMESTRE) AS SEMESTRE,
            COALESCE(EE.PROMEDIO, CT.PROMEDIO) AS PROMEDIO,
            CM.ultimoaccesoplataformlimpio,
            CASE
                WHEN CHARINDEX('EN LA CUOTA: ', C.DESCRIPCION) > 0
                 AND CHARINDEX(' POR EL', C.DESCRIPCION, CHARINDEX('EN LA CUOTA: ', C.DESCRIPCION)) > 0
                THEN TRY_CAST(
                    SUBSTRING(
                        C.DESCRIPCION,
                        CHARINDEX('EN LA CUOTA: ', C.DESCRIPCION) + 13,
                        CHARINDEX(' POR EL', C.DESCRIPCION, CHARINDEX('EN LA CUOTA: ', C.DESCRIPCION))
                        - (CHARINDEX('EN LA CUOTA: ', C.DESCRIPCION) + 13)
                    ) AS INT
                )
                ELSE NULL
            END AS NRO_CUOTA,
            CT.NOM_SECCIONAL, CT.MODALIDAD, CT.CICLO, CT.MARCA_ACADEMICA, CT.ESTADO_ALUMNO,
            GETDATE() AS AUD_FECHA_PROCESAMIENTO   -- Marca de auditoría: instante de carga del lote
        INTO Financiera.Cartera_Gestion
        FROM Financiera.Cartera C
        LEFT JOIN Cartera_Total_Dedup CT
            ON CONVERT(VARCHAR(50), C.IDENTIFICACION) = CONVERT(VARCHAR(50), CT.IDENTIFICACION)
            AND C.PERIODO = CT.PERIODO AND CT.rn = 1
        LEFT JOIN Estadistica_Dedup EE
            ON CONVERT(VARCHAR(50), C.IDENTIFICACION) = EE.NUM_IDENTIFICACION
            AND C.PERIODO = EE.COD_PERIODO
        LEFT JOIN Moodle_Dedup CM
            ON CONVERT(VARCHAR(50), C.IDENTIFICACION) = CM.cedula
        WHERE C.DOCUMENTO = 'NDB'
          AND (C.PERIODO LIKE '%22%' OR C.PERIODO LIKE '%23%' OR
               C.PERIODO LIKE '%24%' OR C.PERIODO LIKE '%25%' OR C.PERIODO LIKE '%26%')


        -- ==========================================================================================
        -- PASO 5 │ DETECCIÓN DE PAGOS — Anti-Join Granular (foto ayer vs. cartera hoy)
        -- ==========================================================================================
        -- Compara la foto de Cartera_Gestion tomada al inicio del proceso (Cartera_Foto_Ayer)
        -- contra la cartera recargada (Cartera_Gestion actualizada). Si una cuota existía ayer
        -- y ya no aparece hoy, se interpreta como cancelada/pagada y se registra en
        -- Creditos_pagos_CTAYUDA con ESTADO_CUOTA = 'Cuota Cancelada'.
        --
        -- La granularidad del match es: NUMERO_DOCUMENTO + PERIODO + NUMERO_CREDITO +
        -- NRO_CUOTA + FECHA_VENCIMIENTO. ISNULL(NRO_CUOTA, 0) maneja cuotas sin número
        -- asignado (antes de implementar el parsing de DESCRIPCION).
        --
        -- Acumulación histórica (sin reset):
        --   La tabla acumula indefinidamente los pagos detectados día a día para permitir
        --   comparativos históricos. Cada fila queda estampada con FECHA_DETECCION_PAGO
        --   (DATE) y AUD_FECHA_PROCESAMIENTO (DATETIME).
        -- ==========================================================================================
        IF OBJECT_ID('Financiera.Cartera_Foto_Ayer', 'U') IS NOT NULL
        BEGIN
            -- Auto-creación de la tabla acumuladora si es la primera ejecución del mes
            IF OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA', 'U') IS NULL
            BEGIN
                CREATE TABLE Financiera.Creditos_pagos_CTAYUDA (
                    PERIODO                  VARCHAR(50),
                    NUMERO_DOCUMENTO         VARCHAR(100),
                    NOMBRE_CAUSA             VARCHAR(200),
                    NUMERO_CREDITO           VARCHAR(100),
                    NRO_CUOTA                INT,
                    TOTAL_PAGADO             DECIMAL(18,2),
                    FECHA_VENCIMIENTO        DATETIME,
                    ESTADO_CUOTA             VARCHAR(50),
                    FECHA_DETECCION_PAGO     DATE,
                    AUD_FECHA_PROCESAMIENTO  DATETIME     -- Marca de auditoría: cuándo se registró el pago detectado
                );
            END

            -- Garantía de columna AUD_FECHA_PROCESAMIENTO en tabla preexistente (migración incremental)
            IF NOT EXISTS (
                SELECT 1 FROM sys.columns
                WHERE object_id = OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA')
                  AND name = 'AUD_FECHA_PROCESAMIENTO'
            )
                ALTER TABLE Financiera.Creditos_pagos_CTAYUDA ADD AUD_FECHA_PROCESAMIENTO DATETIME NULL;

            -- Índice de soporte para comparativos históricos por fecha de detección.
            -- Se crea idempotentemente la primera vez tras este cambio.
            IF NOT EXISTS (
                SELECT 1 FROM sys.indexes
                WHERE object_id = OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA')
                  AND name = 'IX_Creditos_pagos_CTAYUDA_FECHA_DETECCION'
            )
                CREATE NONCLUSTERED INDEX IX_Creditos_pagos_CTAYUDA_FECHA_DETECCION
                    ON Financiera.Creditos_pagos_CTAYUDA (FECHA_DETECCION_PAGO)
                    INCLUDE (PERIODO, NUMERO_DOCUMENTO, NUMERO_CREDITO, NRO_CUOTA);

            -- Inserción de cuotas detectadas como pagadas por anti-join.
            -- EXEC sp_executesql difiere la compilación del INSERT a tiempo de ejecución,
            -- después del ALTER TABLE ADD AUD_FECHA_PROCESAMIENTO, evitando el error 207.
            -- TRY_CONVERT en FECHA_VENCIMIENTO resuelve conflicto de formato VARCHAR/DATETIME.
            -- Guard NOT EXISTS: garantiza idempotencia diaria si el SP se corre varias veces
            -- el mismo día (evita duplicar la misma cuota cancelada con la misma FECHA_DETECCION_PAGO).
            EXEC sp_executesql N'
            INSERT INTO Financiera.Creditos_pagos_CTAYUDA (
                PERIODO, NUMERO_DOCUMENTO, NOMBRE_CAUSA, NUMERO_CREDITO,
                NRO_CUOTA, TOTAL_PAGADO, FECHA_VENCIMIENTO,
                ESTADO_CUOTA, FECHA_DETECCION_PAGO, AUD_FECHA_PROCESAMIENTO
            )
            SELECT
                Ayer.PERIODO,
                Ayer.NUMERO_DOCUMENTO,
                Ayer.NOMBRE_CAUSA,
                Ayer.NUMERO_CREDITO,
                Ayer.NRO_CUOTA,
                Ayer.TOTAL                                         AS TOTAL_PAGADO,
                TRY_CONVERT(DATETIME, Ayer.FECHA_VENCIMIENTO, 103) AS FECHA_VENCIMIENTO,
                ''Cuota Cancelada''                                AS ESTADO_CUOTA,
                CAST(GETDATE() AS DATE)                            AS FECHA_DETECCION_PAGO,
                GETDATE()                                          AS AUD_FECHA_PROCESAMIENTO
            FROM Financiera.Cartera_Foto_Ayer Ayer
            LEFT JOIN Financiera.Cartera_Gestion Hoy
                ON  Ayer.NUMERO_DOCUMENTO     = Hoy.IDENTIFICACION
                AND Ayer.PERIODO              = Hoy.PERIODO
                AND Ayer.NUMERO_CREDITO       = Hoy.NUMERO_CREDITO
                AND ISNULL(Ayer.NRO_CUOTA, 0) = ISNULL(Hoy.NRO_CUOTA, 0)
                AND Ayer.FECHA_VENCIMIENTO    = Hoy.FECHA_VENCIMIENTO
                AND Hoy.DOCUMENTO             = ''NDB''
            WHERE Hoy.IDENTIFICACION IS NULL
              AND NOT EXISTS (
                  SELECT 1
                  FROM Financiera.Creditos_pagos_CTAYUDA H
                  WHERE H.FECHA_DETECCION_PAGO    = CAST(GETDATE() AS DATE)
                    AND H.NUMERO_DOCUMENTO        = Ayer.NUMERO_DOCUMENTO
                    AND H.PERIODO                 = Ayer.PERIODO
                    AND H.NUMERO_CREDITO          = Ayer.NUMERO_CREDITO
                    AND ISNULL(H.NRO_CUOTA, 0)    = ISNULL(Ayer.NRO_CUOTA, 0)
                    AND H.FECHA_VENCIMIENTO       = TRY_CONVERT(DATETIME, Ayer.FECHA_VENCIMIENTO, 103)
              );';
        END

        COMMIT TRANSACTION

    END TRY

    -- ==============================================================================================
    -- MANEJO DE ERRORES
    -- ==============================================================================================
    -- Ante cualquier fallo dentro del TRY: se revierte la transacción completa, preservando
    -- el estado anterior de todas las tablas Financiera.*. El error se registra en
    -- Financiera.LOG_Ejecucion_SP con línea y severidad para diagnóstico posterior,
    -- y se relanza al caller para que el orquestador (SQL Agent, ADF, etc.) detecte el fallo.
    -- ==============================================================================================
    BEGIN CATCH
        SET @err_mensaje   = ERROR_MESSAGE()
        SET @err_linea     = ERROR_LINE()
        SET @err_severidad = ERROR_SEVERITY()

        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION

        INSERT INTO Financiera.LOG_Ejecucion_SP
            (sp_nombre, total_cartera_total, total_cartera_gestion,
             diferencia, filas_cartera_total, filas_cartera_gestion, estado, mensaje)
        VALUES
            ('SP_Cartera_Total', NULL, NULL, NULL, NULL, NULL, 'ERROR',
             'Linea: '     + CAST(@err_linea     AS VARCHAR) + ' | ' +
             'Severidad: ' + CAST(@err_severidad AS VARCHAR) + ' | ' +
             'Mensaje: '   + @err_mensaje)

        RAISERROR(@err_mensaje, @err_severidad, 1)
    END CATCH


    -- ================================================================================================
    -- VALIDACIÓN FINAL DE INTEGRIDAD (fuera de transacción)
    -- ================================================================================================
    -- Auditoría de consistencia post-carga: compara la suma de TOTAL entre Cartera_Total y
    -- Cartera_Gestion (ambas filtradas por NDB). Una diferencia de $0 confirma que el INSERT
    -- en Cartera_Gestion capturó exactamente los mismos registros que Cartera_Total.
    -- Cualquier diferencia genera una alerta RAISERROR de severidad 16 para notificación.
    --
    -- El resultado se persiste en Financiera.LOG_Ejecucion_SP para historial de ejecuciones.
    -- ================================================================================================
    SELECT @total_ct = SUM(CAST(TOTAL AS DECIMAL(18,2))), @filas_ct = COUNT(*)
    FROM Financiera.Cartera_Total WHERE DOCUMENTO = 'NDB'

    SELECT @total_cg = SUM(CAST(TOTAL AS DECIMAL(18,2))), @filas_cg = COUNT(*)
    FROM Financiera.Cartera_Gestion WHERE DOCUMENTO = 'NDB'

    SET @diferencia = ISNULL(@total_ct, 0) - ISNULL(@total_cg, 0)

    IF @diferencia = 0
    BEGIN
        SET @estado      = 'OK'
        SET @mensaje_log = 'Ejecucion exitosa. Suma TOTAL coincide: $' + FORMAT(@total_ct, 'N2')
    END
    ELSE
    BEGIN
        SET @estado      = 'DIFERENCIA'
        SET @mensaje_log = 'ALERTA: Diferencia de $' + FORMAT(@diferencia, 'N2')
                         + ' | Cartera_Total: $'     + FORMAT(@total_ct,   'N2')
                         + ' | Cartera_Gestion: $'   + FORMAT(@total_cg,   'N2')
    END

    INSERT INTO Financiera.LOG_Ejecucion_SP
        (sp_nombre, total_cartera_total, total_cartera_gestion,
         diferencia, filas_cartera_total, filas_cartera_gestion, estado, mensaje)
    VALUES
        ('SP_Cartera_Total', @total_ct, @total_cg,
         @diferencia, @filas_ct, @filas_cg, @estado, @mensaje_log)

    IF @diferencia <> 0
        RAISERROR('%s', 16, 1, @mensaje_log)

END
