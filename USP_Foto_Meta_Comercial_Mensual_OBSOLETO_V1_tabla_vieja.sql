CREATE OR ALTER PROCEDURE [Financiera].[USP_Foto_Meta_Comercial_Mensual]
    @Reproceso BIT = 0   -- 0 = no duplica si ya existe foto del mes; 1 = regenera el mes actual
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @PeriodoFoto VARCHAR(6) = FORMAT(GETDATE(), 'yyyyMM');
    DECLARE @FechaFoto   DATE       = DATEFROMPARTS(YEAR(GETDATE()), MONTH(GETDATE()), 1);
    DECLARE @err_mensaje VARCHAR(2000), @err_sev INT;

    BEGIN TRY
        -- 1) Crear la tabla historica acumulada si no existe (esquema = Cartera_Gestion + columnas de meta)
        IF OBJECT_ID('Financiera.Cartera_Gestion_Meta_Comercial', 'U') IS NULL
        BEGIN
            SELECT TOP 0
                CG.*,
                CAST(NULL AS VARCHAR(6))  AS PERIODO_FOTO,
                CAST(NULL AS DATE)        AS FECHA_FOTO,
                CAST(NULL AS VARCHAR(2))  AS [Asignacion Q],
                CAST(NULL AS DATETIME)    AS AUD_FECHA_FOTO
            INTO Financiera.Cartera_Gestion_Meta_Comercial
            FROM Financiera.Cartera_Gestion CG
            WHERE 1 = 0;

            CREATE NONCLUSTERED INDEX IX_Meta_Comercial_Periodo
                ON Financiera.Cartera_Gestion_Meta_Comercial (PERIODO_FOTO)
                INCLUDE ([Asignacion Q]);
        END

        -- 2) Idempotencia por mes: la meta queda FIJA con la foto del dia 1
        IF EXISTS (SELECT 1 FROM Financiera.Cartera_Gestion_Meta_Comercial WHERE PERIODO_FOTO = @PeriodoFoto)
        BEGIN
            IF @Reproceso = 0
            BEGIN
                PRINT 'Ya existe foto para el periodo ' + @PeriodoFoto + '. Use @Reproceso = 1 para regenerarla.';
                RETURN;
            END
            DELETE FROM Financiera.Cartera_Gestion_Meta_Comercial WHERE PERIODO_FOTO = @PeriodoFoto;
        END

        -- 3) Foto del mes + Asignacion Q por SUMA ACUMULADA de TOTAL ordenada por vencimiento.
        --    Q1 = lo mas vencido (fecha mas antigua) ... Q4 = lo mas reciente.
        --    Cada Q acumula ~25% del SUM(TOTAL). Los vencimientos NULL/invalidos van al final (Q4).
        ;WITH Calc AS (
            SELECT
                CG.*,
                SUM(CAST(CG.TOTAL AS DECIMAL(18,2))) OVER (
                    ORDER BY
                        CASE WHEN TRY_CONVERT(date, CG.FECHA_VENCIMIENTO, 103) IS NULL THEN 1 ELSE 0 END ASC,
                        TRY_CONVERT(date, CG.FECHA_VENCIMIENTO, 103) ASC,
                        CG.IDENTIFICACION, CG.NUMERO_CREDITO, CG.NRO_CUOTA
                    ROWS UNBOUNDED PRECEDING
                ) AS _RunTotal,
                SUM(CAST(CG.TOTAL AS DECIMAL(18,2))) OVER () AS _GrandTotal
            FROM Financiera.Cartera_Gestion CG
        )
        INSERT INTO Financiera.Cartera_Gestion_Meta_Comercial
            ([PERIODO], [TIPO_CLIENTE], [NOMBRE_TIPO_CLIENTE], [IDENTIFICACION], [FEC_NAC], [GENDER], [DIRECCION_CASA], [EMAIL], [TEL_CASA], [TEL_CELULAR], [WHATSAPP], [PAIS], [DEPARTAMENTO], [CLIENTE], [NOMBRE], [LINEA], [TIPO_DOCUMENTO], [DOCUMENTO], [NUMERO_CREDITO], [FECHA], [FECHA_VENCIMIENTO], [CENTRO_COSTO], [NOMBRE_CENTRO], [FONDO], [NOMBRE_FONDO], [NOMBRE_CONCEPTO], [NOMBRE_CAUSA], [VALOR_ORIGINAL], [CORRIENTE], [GR1A30], [GR31A60], [GR61A90], [GR91A120], [GR121A150], [GR151A360], [GR360MAS], [TOTAL], [CODIGO_CONTABLE], [DESCRIPCION], [NOM_UNIDAD], [NUEVO], [SEMESTRE], [PROMEDIO], [ultimoaccesoplataformlimpio], [NRO_CUOTA], [NOM_SECCIONAL], [MODALIDAD], [CICLO], [MARCA_ACADEMICA], [ESTADO_ALUMNO], [AUD_FECHA_PROCESAMIENTO], PERIODO_FOTO, FECHA_FOTO, [Asignacion Q], AUD_FECHA_FOTO)
        SELECT
            CG.[PERIODO],
            CG.[TIPO_CLIENTE],
            CG.[NOMBRE_TIPO_CLIENTE],
            CG.[IDENTIFICACION],
            CG.[FEC_NAC],
            CG.[GENDER],
            CG.[DIRECCION_CASA],
            CG.[EMAIL],
            CG.[TEL_CASA],
            CG.[TEL_CELULAR],
            CG.[WHATSAPP],
            CG.[PAIS],
            CG.[DEPARTAMENTO],
            CG.[CLIENTE],
            CG.[NOMBRE],
            CG.[LINEA],
            CG.[TIPO_DOCUMENTO],
            CG.[DOCUMENTO],
            CG.[NUMERO_CREDITO],
            CG.[FECHA],
            CG.[FECHA_VENCIMIENTO],
            CG.[CENTRO_COSTO],
            CG.[NOMBRE_CENTRO],
            CG.[FONDO],
            CG.[NOMBRE_FONDO],
            CG.[NOMBRE_CONCEPTO],
            CG.[NOMBRE_CAUSA],
            CG.[VALOR_ORIGINAL],
            CG.[CORRIENTE],
            CG.[GR1A30],
            CG.[GR31A60],
            CG.[GR61A90],
            CG.[GR91A120],
            CG.[GR121A150],
            CG.[GR151A360],
            CG.[GR360MAS],
            CG.[TOTAL],
            CG.[CODIGO_CONTABLE],
            CG.[DESCRIPCION],
            CG.[NOM_UNIDAD],
            CG.[NUEVO],
            CG.[SEMESTRE],
            CG.[PROMEDIO],
            CG.[ultimoaccesoplataformlimpio],
            CG.[NRO_CUOTA],
            CG.[NOM_SECCIONAL],
            CG.[MODALIDAD],
            CG.[CICLO],
            CG.[MARCA_ACADEMICA],
            CG.[ESTADO_ALUMNO],
            CG.[AUD_FECHA_PROCESAMIENTO],
            @PeriodoFoto,
            @FechaFoto,
            CASE
                WHEN _GrandTotal IS NULL OR _GrandTotal = 0           THEN 'Q1'
                WHEN _RunTotal / _GrandTotal <= 0.25                  THEN 'Q1'
                WHEN _RunTotal / _GrandTotal <= 0.50                  THEN 'Q2'
                WHEN _RunTotal / _GrandTotal <= 0.75                  THEN 'Q3'
                ELSE 'Q4'
            END AS [Asignacion Q],
            GETDATE()
        FROM Calc CG;

        PRINT 'Foto generada para ' + @PeriodoFoto + '. Filas: ' + CAST(@@ROWCOUNT AS VARCHAR(20));
    END TRY
    BEGIN CATCH
        SET @err_mensaje = ERROR_MESSAGE();
        SET @err_sev     = ERROR_SEVERITY();
        RAISERROR(@err_mensaje, @err_sev, 1);
    END CATCH
END
