USE [CUN_REPOSITORIO]
GO
/****** Object:  StoredProcedure [Financiera].[SP_Cartera_Total]    Script Date: 17/04/2026 3:57:21 p. m. ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
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

        --------------------- 0. RESPALDAR LA CARTERA DE AYER (LA "FOTO") ---------------------
        -- Propósito: Antes de que el proceso reconstruya las tablas, guardamos el estado de ayer.
        -- Se extraen estrictamente las 7 columnas solicitadas para evaluar el pago de cuotas.
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
                FECHA_VENCIMIENTO
            INTO Financiera.Cartera_Foto_Ayer
            FROM Financiera.Cartera_Gestion
            WHERE DOCUMENTO = 'NDB';
        END

        --------------------- 1. Crear Tabla Cartera ---------------------
        DROP TABLE IF EXISTS Financiera.Cartera;

        SELECT *
        INTO Financiera.Cartera
        FROM OPENQUERY([172.16.1.175],
                'SELECT *
                 FROM ICEBERG.VM_CARTERA_CORPORATIVA')

        --------------------- 3. Crear Tabla Cartera_Total ---------------
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
                END AS MARCA_ACADEMICA
        INTO Financiera.Cartera_Total
        FROM Financiera.CARTERA A
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
                                WHEN fec_inicio > CAST(GETDATE() AS DATE)                                                              THEN 'PERIODO NO HA INICIADO'
                                WHEN fec_inicio <= CAST(GETDATE() AS DATE) AND fec_fin >= CAST(GETDATE() AS DATE)  THEN 'ACTIVO'
                                ELSE 'NO ACTIVO'
                        END AS ESTADO
                FROM Dbo.Periodos_Calendario
        ) C ON A.PERIODO = C.PERIODO
        WHERE (A.PERIODO LIKE '%22%' OR A.PERIODO LIKE '%23%' OR
               A.PERIODO LIKE '%24%' OR A.PERIODO LIKE '%25%' OR A.PERIODO LIKE '%26%')
          AND A.DOCUMENTO = 'NDB'

        --------------------- 4. Crear / Recargar Financiera.Cartera_Gestion -----
        IF OBJECT_ID('Financiera.Cartera_Gestion', 'U') IS NULL
        BEGIN
            SELECT TOP 0
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
                CAST(NULL AS FLOAT)   AS SEMESTRE,
                CAST(NULL AS FLOAT)   AS PROMEDIO,
                CAST(NULL AS VARCHAR) AS ultimoaccesoplataformlimpio,
                CAST(NULL AS INT)     AS NRO_CUOTA
            INTO Financiera.Cartera_Gestion
            FROM Financiera.Cartera C
            LEFT JOIN Financiera.Cartera_Total CT
                ON CONVERT(VARCHAR(50), C.IDENTIFICACION) = CONVERT(VARCHAR(50), CT.IDENTIFICACION)
                AND C.PERIODO = CT.PERIODO
            WHERE 1 = 0
        END

        -- Agregar columna NRO_CUOTA si la tabla ya existe y no tiene la columna
        IF NOT EXISTS (
            SELECT 1 FROM sys.columns
            WHERE object_id = OBJECT_ID('Financiera.Cartera_Gestion')
              AND name = 'NRO_CUOTA'
        )
            ALTER TABLE Financiera.Cartera_Gestion ADD NRO_CUOTA INT NULL;

        TRUNCATE TABLE Financiera.Cartera_Gestion;

        WITH
        Cartera_Total_Dedup AS (
            SELECT IDENTIFICACION, PERIODO, NOM_UNIDAD, NUEVO, PROMEDIO, SEMESTRE,
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
        INSERT INTO Financiera.Cartera_Gestion
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
            END AS NRO_CUOTA
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

        --------------------- 5. DETECCIÓN DE PAGOS (Estrategia 2: Anti-Join Granular) ---
        -- Propósito: Compara la "foto" de ayer con la cartera fresca de hoy a nivel de cuota.
        -- Si la cuota ya no existe (es NULL en la tabla Hoy), se asume como pagada.
        IF OBJECT_ID('Financiera.Cartera_Foto_Ayer', 'U') IS NOT NULL
        BEGIN
            -- 5.1 Auto-creación de la tabla si no existe
            IF OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA', 'U') IS NULL
            BEGIN
                CREATE TABLE Financiera.Creditos_pagos_CTAYUDA (
                    PERIODO                 VARCHAR(50),
                    NUMERO_DOCUMENTO        VARCHAR(100),
                    NOMBRE_CAUSA            VARCHAR(200),
                    NUMERO_CREDITO          VARCHAR(100),
                    NRO_CUOTA               INT,
                    TOTAL_PAGADO            DECIMAL(18,2),
                    FECHA_VENCIMIENTO       DATETIME,
                    ESTADO_CUOTA            VARCHAR(50),
                    FECHA_DETECCION_PAGO    DATE
                );
            END

            -- 5.2 RESET MENSUAL AUTOMÁTICO
            -- Lógica: Si el día de ejecución es el 1ero de mes, se vacía la tabla para iniciar el nuevo ciclo.
            IF DAY(GETDATE()) = 1
            BEGIN
                TRUNCATE TABLE Financiera.Creditos_pagos_CTAYUDA;
            END

            -- 5.3 Inserción de las cuotas liquidadas/pagadas detectadas
            INSERT INTO Financiera.Creditos_pagos_CTAYUDA (
                PERIODO, 
                NUMERO_DOCUMENTO, 
                NOMBRE_CAUSA, 
                NUMERO_CREDITO, 
                NRO_CUOTA, 
                TOTAL_PAGADO, 
                FECHA_VENCIMIENTO, 
                ESTADO_CUOTA, 
                FECHA_DETECCION_PAGO
            )
            SELECT 
                Ayer.PERIODO,
                Ayer.NUMERO_DOCUMENTO,
                Ayer.NOMBRE_CAUSA,
                Ayer.NUMERO_CREDITO,
                Ayer.NRO_CUOTA,
                Ayer.TOTAL                  AS TOTAL_PAGADO,
                Ayer.FECHA_VENCIMIENTO,
                'Cuota Cancelada'           AS ESTADO_CUOTA,
                CAST(GETDATE() AS DATE)     AS FECHA_DETECCION_PAGO
            FROM Financiera.Cartera_Foto_Ayer Ayer
            LEFT JOIN Financiera.Cartera_Gestion Hoy
                ON  Ayer.NUMERO_DOCUMENTO   = Hoy.IDENTIFICACION
                AND Ayer.PERIODO            = Hoy.PERIODO
                AND Ayer.NUMERO_CREDITO     = Hoy.NUMERO_CREDITO
                AND ISNULL(Ayer.NRO_CUOTA, 0) = ISNULL(Hoy.NRO_CUOTA, 0)
                AND Ayer.FECHA_VENCIMIENTO  = Hoy.FECHA_VENCIMIENTO
                AND Hoy.DOCUMENTO           = 'NDB'
            -- REGLA ANTI-JOIN: Existía ayer, desapareció hoy
            WHERE Hoy.IDENTIFICACION IS NULL;
        END

        COMMIT TRANSACTION

    END TRY
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

    -- VALIDACION final (auditoría de integridad de datos)
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