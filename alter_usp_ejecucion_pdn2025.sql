ALTER PROCEDURE [Financiera].[Usp_Ejecucion_PDN2025]
AS
BEGIN
-- ============================================================
-- Cambios implementados:
--   C1: TRY/CATCH + BEGIN TRANSACTION / COMMIT / ROLLBACK
--   C3: TRUNCATE+INSERT en lugar de DROP TABLE+SELECT INTO
--   C5: TRY_CAST en lugar de CAST para columna ORDEN
--   M1: Eliminado WITH(NOLOCK) en Zoho.Base_Personas
--   M2: Indice en tabla temporal #VENTAS_CON_ORDENES_FINAL
--   M5: Correccion NCR_ANULACION = '0' (tipo mixto)
--   B3: Tabla de auditoria LOG_Comparativo_PDN2025 + logging con comparativo FINANCIERA vs ZOHO
--   B4: Eliminado double CAST en IDENTIFICACION
-- ============================================================

    DECLARE @inicio        DATETIME = GETDATE()
    DECLARE @err_mensaje   VARCHAR(2000)
    DECLARE @err_linea     INT
    DECLARE @err_severidad INT
    DECLARE @duracion_seg  INT

    -- ── B3: Crear tabla de auditoria si no existe ──────────────────────────
    IF OBJECT_ID('Financiera.LOG_Comparativo_PDN2025', 'U') IS NULL
    BEGIN
        CREATE TABLE Financiera.LOG_Comparativo_PDN2025 (
            id                     INT IDENTITY(1,1) PRIMARY KEY,
            fecha_ejecucion        DATETIME     DEFAULT GETDATE(),
            sp_nombre              VARCHAR(100),
            duracion_seg           INT,
            estado                 VARCHAR(20),
            mensaje                VARCHAR(2000),
            PERIODO                VARCHAR(20),
            NUEVO                  VARCHAR(20),
            ESTUDIANTES_FINANCIERA INT,
            ESTUDIANTES_ZOHO       INT,
            DIFERENCIA             INT
        )
    END

    -- ── C1: Bloque transaccional ───────────────────────────────────────────
    BEGIN TRY

        BEGIN TRANSACTION

        -------------1. TRAER INFORMACIÓN DE ORDENES FINANCIERAS DE ICEBERG -------
        DELETE FROM Financiera.Ordenes_Financieras_con_descuento
        WHERE PERIODO LIKE '%26%';

        INSERT INTO Financiera.Ordenes_Financieras_con_descuento (
            IDENTIFICACION, NOMBRE, PERIODO, ORDEN, DOCUMENTO,
            CONCEPTO_MAT, VALOR_MAT, CONCEPTO_IDIOMAS, VALOR_IDIOMAS,
            CONCEPTO_SERVICIO_MED, VALOR_SERVICIO_MED, CONCEPTO_BONO_SOL,
            VALOR_BONO_SOL, OTROS_DESCUENTOS, GRUPO, DESCRIPCION_GRUPO,
            DESCUENTO_PRONTO_PAGO, ORDEN_NETA, VAL_BECDTOS
        )
        SELECT
            IDENTIFICACION, NOMBRE, PERIODO, ORDEN, DOCUMENTO,
            CONCEPTO_MAT, VALOR_MAT, CONCEPTO_IDIOMAS, VALOR_IDIOMAS,
            CONCEPTO_SERVICIO_MED, VALOR_SERVICIO_MED, CONCEPTO_BONO_SOL,
            VALOR_BONO_SOL, OTROS_DESCUENTOS, GRUPO, DESCRIPCION_GRUPO,
            DESCUENTO_PRONTO_PAGO,
            (ISNULL(VALOR_MAT, 0) + ISNULL(VALOR_IDIOMAS, 0) + ISNULL(VAL_BECDTOS, 0) - ISNULL(VALOR_2x1, 0)) AS ORDEN_NETA,
            VAL_BECDTOS
        FROM OPENQUERY([172.16.1.175],
            'SELECT *
             FROM ICEBERG.V_ccrecibopagoantcod_2
             WHERE PERIODO LIKE ''%26%''
             ')

        ------------------------1.1 DESCUENTOS -----------------------------------------------
        DELETE FROM Financiera.DESCUENTOS
        WHERE PERIODO LIKE '%26%';

        INSERT INTO FINANCIERA.DESCUENTOS
        SELECT *
        FROM OPENQUERY([172.16.1.175], '
            SELECT
                cun.PERIODO,
                B.TIP_IDENTIFICACION,
                cun.DOC_ALUM,
                CUN.ID_TERCERO,
                B.NOM_TERCERO,
                B.SEG_NOMBRE,
                B.PRI_APELLIDO,
                B.SEG_APELLIDO,
                cun.CLIENTE,
                CASE WHEN liq.est_liquidacion = 2 THEN ''PAGO'' ELSE ''NO PAGO'' END EST_PAG_ACA,
                FEC_CRE_ACAD,
                TO_CHAR(FEC_FINAN, ''DD/MM/YYYY'') fec_finan,
                FEC_NAC,
                TO_CHAR(b.fec_exp_documento, ''DD/MM/YYYY'') fec_exp,
                b.gen_tercero,
                DIRECCION_CASA,
                B.DIR_EMAIL AS EMAIL,
                NVL(cun.EMAIL_PER, dir_email) email_per,
                TEL_CASA,
                TEL_CELULAR,
                COD_SEDE,
                SEDE,
                COD_SECC,
                SECCIONAL,
                COD_MODA,
                MODALIDAD,
                COD_UNI,
                nom_unidad,
                COD_PROGRAMA,
                NOM_PROGRAMA,
                PENSUM,
                COD_NIVEL,
                Nivel,
                COD_TIPO,
                tipo,
                ID_JORNADA,
                nom_jornada,
                NUEVO,
                TIP_INSCR,
                CLASE_ACTUAL,
                PERIODO_ULT_PAGO,
                NomCencos,
                FONDO,
                nombre_fondo,
                DOCUMENTO,
                ORDEN,
                (SELECT O.GRUPO
                    FROM ORDEN O
                WHERE O.CLIENTE_SOLICITADO = CUN.CLIENTE
                    AND O.ORDEN = CUN.ORDEN
                    AND O.DOCUMENTO = CUN.DOCUMENTO
                    AND O.PERIODO = CUN.PERIODO) AS grupo_facturacion,
                PRODUCTO,
                FUENTE,
                REF_LIQUIDACION,
                TO_CHAR(cun.VALOR_ORDEN, ''9999999999.99'') VALOR_ORDEN,
                TO_CHAR(cun.VAL_LIQUIDADO, ''9999999999.99'') val_liquidado,
                TO_CHAR(cun.VAL_PAGADO, ''9999999999.99'') VAL_PAGADO,
                TO_CHAR(cun.RECARGO, ''9999999999.99'') RECARGO,
                TO_CHAR(cun.ADICIONALES, ''9999999999.99'') ADICIONALES,
                TO_CHAR(cun.VAL_PAGO_DIRECTO, ''9999999999.99'') VAL_PAGO_DIRECTO,
                TO_CHAR(cun.SALDO_FAVOR, ''9999999999.99'') SALDO_FAVOR,
                TO_CHAR(cun.VAL_CREDITO, ''9999999999.99'') VAL_CREDITO,
                TO_CHAR(cun.VAL_ICETEX, ''9999999999.99'') VAL_ICETEX,
                TO_CHAR(cun.VAL_CONTRATOS, ''9999999999.99'') VAL_CONTRATOS,
                TO_CHAR(cun.VAL_BECDTOS, ''9999999999.99'') VAL_BECDTOS,
                TO_CHAR(cun.VAL_OTRAS_NCR, ''9999999999.99'') VAL_OTRAS_NCR,
                TO_CHAR(cun.FEC_PAGO_LIQ, ''DD/MM/YYYY'') fec_pago_liq,
                CASE
                WHEN es_numero(SUBSTR(cun.fuente,1,4)) = ''S'' THEN
                    -1 * cunp_indicadores_financieros.retorna_devolucion_x_rev_orden(
                    cun.cliente,
                    cun.periodo,
                    cun.documento,
                    cun.orden,
                    SUBSTR(cun.fuente,1,4)
                    )
                ELSE 0
                END ncr_anulacion,
                SEMESTRE semestre_sinu,
                CASE
                WHEN fuente LIKE ''2100%'' THEN
                    cup_cunt_control_tarifas_icb.retorna_nivel_alumno(cun.doc_alum)
                ELSE NULL
                END semestre_calculado,
                (SELECT creditos_academicos
                    FROM orden o
                WHERE o.documento = cun.documento
                    AND o.orden = cun.orden) creditos_orden,
                UBICACION,
                USU_CREA,
                USU_ACTU,
                GRU_EDUCONT,
                TO_CHAR(FEC_RECIBO, ''DD/MM/YYYY'') fec_recibo,
                TO_CHAR(FEC_SIGUIENTE, ''DD/MM/YYYY'') fec_siguiente,
                TO_CHAR(FEC_ANTERIOR, ''DD/MM/YYYY'') fec_anterior,
                cup_reportes_matriculas.retorna_datos_formulario(
                cun.documento,
                cun.orden
                ) formulario,
                TO_CHAR(VAL_TARJETA_DEBITO, ''99999999999.99'') VAL_TARJETA_DEBITO,
                TO_CHAR(VAL_TARJETA_CREDITO, ''99999999999.99'') VAL_TARJETA_CREDITO,
                TO_CHAR(VAL_PAGO_BANCO, ''99999999999.99'') VAL_PAGO_BANCO,
                TO_CHAR(VAL_EFECTIVO, ''99999999999.99'') VAL_EFECTIVO,
                TO_CHAR(VAL_PLACE, ''99999999999.99'') VAL_PLACE
            FROM
                CUNT_ALUMNOS_ORDENES_X_PERIODO cun,
                BAS_TERCERO B,
                src_enc_liquidacion liq
            WHERE
                (PERIODO LIKE ''%26%'')
                AND b.id_tercero = cun.id_tercero
                AND liq.cod_periodo(+) = cun.periodo
                AND liq.num_documento(+) = cun.ref_liquidacion
                AND DOCUMENTO NOT IN (''RPVI'')
        ')

        --------2. UNION DE INFORMACION FINANCIERA DE ORDENES CON VENTAS ----------------
        SELECT DISTINCT
            A.DOC_ALUM AS Documento_Estudiante_zoho,
            A.PERIODO AS PERIODO_ORIGEN,
            A.PERIODO_DATA AS PERIODO,
            A.TIPO_ALUM_DATA AS NUEVO,
            DBO.NORMALIZAR(
            CASE
                WHEN TIPO_ALUM_DATA = 'ANTIGUO'
                    THEN 'PERMANENCIA'
                ELSE A.Fuerza_Comercial_data
            END
            ) AS FuerzaComercialFinal,
            A.ESTADO_PAGO_DATA AS ESTADO_PAGO,
            A.EST_MATRICULADO,
            A.seccional AS SECCIONAL,
            A.SEDE,
            A.COD_UNI,
            A.PROGRAMA,
            A.NOM_PROGRAMA,
            A.DOCUMENTO,
            A.MODALIDAD,
            A.Ciudad,
            A.ORDEN,
            A.NIVEL,
            A.CONVENIO AS NOMBRE_DE_CONVENIO,
            A.CLASE_ACTUAL,
            A.TIPO_PRODUCTO,
            A.Clase_actual_data,
            A.Usuario_crea,
            A.usuarioorigen,
            A.nomusuarioorigen,
            A.Campaña,
            B.CONCEPTO_MAT AS CONCEPTO_ORDEN,
            B.VALOR_MAT AS VALOR_ORDEN,
            B.CONCEPTO_IDIOMAS,
            B.VALOR_IDIOMAS AS Valor_ingles,
            B.CONCEPTO_SERVICIO_MED,
            B.VALOR_SERVICIO_MED AS VALOR_SERVICIO_MEDICO,
            B.CONCEPTO_BONO_SOL AS CONCEPTO_BONO_SOL,
            B.VALOR_BONO_SOL,
            B.OTROS_DESCUENTOS,
            B.DESCUENTO_PRONTO_PAGO,
            D.VAL_BECDTOS,
            (ISNULL(D.VALOR_ORDEN, 0) + ISNULL(B.VALOR_IDIOMAS, 0) + ISNULL(D.VAL_BECDTOS, 0)) AS ORDEN_NETO,
            A.lat AS LATITUD,
            A.lon AS LONGITUD,
            A.ciudad AS CIUDAD_GEOLOCALIZADA,
            A.departamento AS DEPARTAMENTO_GEOLOCALIZADO,
            A.localidad AS LOCALIDAD_GEOLOCALIZADA,
            C.CARTERA_ESTUDIANTE
        INTO #VENTAS_CON_ORDENES_FINAL
        FROM Zoho.Base_Personas A
        LEFT JOIN Financiera.Ordenes_Financieras_con_descuento B
            ON TRY_CAST(A.DOC_ALUM AS BIGINT) = B.IDENTIFICACION
           AND A.PERIODO = B.PERIODO
           AND A.DOCUMENTO = B.DOCUMENTO
           AND TRY_CAST(A.ORDEN AS BIGINT) = B.ORDEN
        LEFT JOIN Financiera.DESCUENTOS D
            ON TRY_CAST(A.DOC_ALUM AS BIGINT) = D.DOC_ALUM
           AND A.PERIODO = D.PERIODO
           AND A.DOCUMENTO = D.DOCUMENTO
           AND TRY_CAST(A.ORDEN AS BIGINT) = D.ORDEN
        LEFT JOIN (
            SELECT
                IDENTIFICACION,
                PERIODO,
                SUM(TRY_CAST(TOTAL AS DECIMAL(18, 2))) AS CARTERA_ESTUDIANTE
            FROM Financiera.Cartera_Total
            WHERE DOCUMENTO = 'NDB'
            GROUP BY IDENTIFICACION, PERIODO
        ) C
            ON TRY_CAST(A.DOC_ALUM AS BIGINT) = C.IDENTIFICACION
           AND A.PERIODO = C.PERIODO
        WHERE
            A.PERIODO LIKE '%26%'
            AND A.ESTADO_PAGO_DATA = 'PAGO'
            AND (A.EST_MATRICULADO = '1-Activo'
                OR A.EST_MATRICULADO = '2-Egresado'
                OR A.EST_MATRICULADO = '3-Graduado')
            AND A.DOCUMENTO IN ('FAMA', 'FECO')
            AND ISNULL(TRY_CAST(A.NCR_ANULACION AS DECIMAL(18,2)), 0) = 0
        ;

        IF EXISTS (
            SELECT 1 FROM tempdb.sys.columns c
            JOIN tempdb.sys.tables t ON c.object_id = t.object_id
            WHERE t.name LIKE '#VENTAS_CON_ORDENES_FINAL%'
              AND c.name = 'Documento_Estudiante_zoho'
              AND c.max_length <> -1
              AND c.system_type_id NOT IN (34, 35, 99)
        )
        BEGIN
            CREATE INDEX IX_VENTAS_JOIN
                ON #VENTAS_CON_ORDENES_FINAL (Documento_Estudiante_zoho);
        END

        -------4. RECIBOS DE CAJA GENERAL ------
        IF OBJECT_ID('FINANCIERA.RECIBOS_CAJA_GENERAL', 'U') IS NULL
        BEGIN
            CREATE TABLE FINANCIERA.RECIBOS_CAJA_GENERAL (
                CLIENTE       VARCHAR(50),
                PERIODO       VARCHAR(20),
                NUMERO        VARCHAR(50),
                FECHA_DE_PAGO VARCHAR(30),
                VALOR         DECIMAL(18,2),
                CAJA          VARCHAR(100)
            )
        END
        ELSE
            TRUNCATE TABLE FINANCIERA.RECIBOS_CAJA_GENERAL;

        INSERT INTO FINANCIERA.RECIBOS_CAJA_GENERAL
        SELECT *
        FROM OPENQUERY([172.16.1.175],'
            SELECT DISTINCT
                rp.DOC_ALUM AS CLIENTE,
                rp.PERIODO,
                rp.NUMERO,
                rp.FECHA_DE_PAGO,
                rp.VALOR_INGRESO_DIRECTO AS VALOR,
                rc.CAJA
            FROM ICEBERG.R_RECAUDO_PAGOS rp
            LEFT JOIN ICEBERG.RECIBO_CAJA rc
                ON TO_CHAR(rc.NUMERO) = TO_CHAR(rp.NUMERO)
            WHERE TO_DATE(rp.FECHA_DE_PAGO, ''DD/MM/YYYY'') >= ADD_MONTHS(TRUNC(SYSDATE, ''MM''), -1)
        ')

        ------------------------- 4.1 RECIBOS CAJA MEDIOS PAGO -------------------------
        IF OBJECT_ID('Financiera.Recibos_Caja_Medios_Pago', 'U') IS NULL
        BEGIN
            CREATE TABLE Financiera.Recibos_Caja_Medios_Pago (
                IDENTIFICACION VARCHAR(20),
                PERIODO        VARCHAR(50),
                RECIBOS_CAJA   DECIMAL(18,2),
                ICETEX         DECIMAL(18,2),
                FINCOMERCIO    DECIMAL(18,2),
                CREDITY        DECIMAL(18,2),
                JAC            DECIMAL(18,2),
                CONVENIOV      DECIMAL(18,2)
            )
        END
        ELSE
            TRUNCATE TABLE Financiera.Recibos_Caja_Medios_Pago;

        INSERT INTO Financiera.Recibos_Caja_Medios_Pago
        SELECT
            CAST(TRY_CAST(IDENTIFICACION AS BIGINT) AS VARCHAR(20)) AS IDENTIFICACION,
            PERIODO,
            SUM(RECIBOS_CAJA)   AS RECIBOS_CAJA,
            SUM(ICETEX)         AS ICETEX,
            SUM(FINCOMERCIO)    AS FINCOMERCIO,
            SUM(CREDITY)        AS CREDITY,
            SUM(JAC)            AS JAC,
            SUM(CONVENIOV)      AS CONVENIOV
        FROM OPENQUERY([172.16.1.175], '
            SELECT
                IDENTIFICACION, PERIODO,
                RECIBOS_CAJA, ICETEX, FINCOMERCIO,
                CREDITY, JAC, CONVENIOV
            FROM iceberg.v_recibo_caja_pagos_descuentos
        ') AS src
        GROUP BY
            CAST(TRY_CAST(IDENTIFICACION AS BIGINT) AS VARCHAR(20)),
            PERIODO;

        ------------------------- 5. RESULTADO INGRESOXPERIODO FINAL -------------------------
        DELETE FROM FINANCIERA.RESULTADO_INGRESOXPERIODO_FINAL
        WHERE PERIODO LIKE '%26%';

        WITH Recibos_Agrupados AS (
            SELECT
                CAST(TRY_CAST(IDENTIFICACION AS BIGINT) AS VARCHAR(20)) AS IDENTIFICACION,
                PERIODO,
                SUM(RECIBOS_CAJA) AS RECIBOS_CAJA,
                SUM(ICETEX + FINCOMERCIO + CREDITY + JAC + CONVENIOV) AS OTROS_MEDIOS_PAGO
            FROM Financiera.Recibos_Caja_Medios_Pago
            GROUP BY
                CAST(TRY_CAST(IDENTIFICACION AS BIGINT) AS VARCHAR(20)),
                PERIODO
        )
        INSERT INTO FINANCIERA.RESULTADO_INGRESOXPERIODO_FINAL
        SELECT
            a.*,
            b.RECIBOS_CAJA,
            b.OTROS_MEDIOS_PAGO
        FROM #VENTAS_CON_ORDENES_FINAL a
        LEFT JOIN Recibos_Agrupados b
            ON a.PERIODO                  = b.PERIODO
           AND a.Documento_Estudiante_zoho = b.IDENTIFICACION;

        COMMIT TRANSACTION

    END TRY
    BEGIN CATCH
        SET @err_mensaje   = ERROR_MESSAGE()
        SET @err_linea     = ERROR_LINE()
        SET @err_severidad = ERROR_SEVERITY()

        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION

        DROP TABLE IF EXISTS #VENTAS_CON_ORDENES_FINAL

        INSERT INTO Financiera.LOG_Comparativo_PDN2025
            (sp_nombre, duracion_seg, estado, mensaje,
             PERIODO, NUEVO, ESTUDIANTES_FINANCIERA, ESTUDIANTES_ZOHO, DIFERENCIA)
        VALUES
            ('Usp_Ejecucion_PDN2025',
             DATEDIFF(SECOND, @inicio, GETDATE()),
             'ERROR',
             'Linea: '     + CAST(@err_linea     AS VARCHAR) + ' | ' +
             'Severidad: ' + CAST(@err_severidad AS VARCHAR) + ' | ' +
             'Mensaje: '   + @err_mensaje,
             NULL, NULL, NULL, NULL, NULL)

        RAISERROR(@err_mensaje, @err_severidad, 1)
    END CATCH

    -- ── B3: Log de exito con comparativo FINANCIERA vs ZOHO ───────────────
    SET @duracion_seg = DATEDIFF(SECOND, @inicio, GETDATE())

    ;WITH COMPARATIVO AS (
        SELECT
            R.PERIODO,
            R.NUEVO,
            COUNT(DISTINCT R.Documento_Estudiante_zoho)                              AS ESTUDIANTES_FINANCIERA,
            COUNT(DISTINCT Z.DOC_ALUM)                                               AS ESTUDIANTES_ZOHO,
            COUNT(DISTINCT R.Documento_Estudiante_zoho) - COUNT(DISTINCT Z.DOC_ALUM) AS DIFERENCIA
        FROM (
            SELECT PERIODO, PERIODO_ORIGEN, Documento_Estudiante_zoho, ORDEN, NUEVO
            FROM FINANCIERA.RESULTADO_INGRESOXPERIODO_FINAL
            WHERE ESTADO_PAGO    = 'PAGO'
              AND EST_MATRICULADO = '1-Activo'
              AND PERIODO LIKE '%26%'
        ) R
        LEFT JOIN (
            SELECT PERIODO, PERIODO_ULT_PAGO, PERIODO_INGRESO, Periodo_data, DOC_ALUM, ORDEN
            FROM ZOHO.BASE_PERSONAS
            WHERE (ESTADO_PAGO = 'PAGO' OR Estado_pago_data = 'PAGO')
        ) Z
            ON  R.ORDEN = Z.ORDEN
            AND (
                R.PERIODO        = Z.PERIODO          OR R.PERIODO        = Z.PERIODO_ULT_PAGO
                OR R.PERIODO        = Z.PERIODO_INGRESO OR R.PERIODO        = Z.Periodo_data
                OR R.PERIODO_ORIGEN = Z.PERIODO          OR R.PERIODO_ORIGEN = Z.PERIODO_ULT_PAGO
                OR R.PERIODO_ORIGEN = Z.PERIODO_INGRESO  OR R.PERIODO_ORIGEN = Z.Periodo_data
            )
        GROUP BY R.PERIODO, R.NUEVO
    ),
    RESUMEN AS (
        SELECT
            SUM(ABS(DIFERENCIA))                              AS TOTAL_DIF,
            SUM(CASE WHEN DIFERENCIA <> 0 THEN 1 ELSE 0 END) AS PERIODOS_CON_DIF
        FROM COMPARATIVO
    )
    INSERT INTO Financiera.LOG_Comparativo_PDN2025
        (sp_nombre, duracion_seg, estado, mensaje,
         PERIODO, NUEVO, ESTUDIANTES_FINANCIERA, ESTUDIANTES_ZOHO, DIFERENCIA)
    SELECT
        'Usp_Ejecucion_PDN2025',
        @duracion_seg,
        'OK',
        'Duracion: '                 + CAST(@duracion_seg         AS VARCHAR) + 's' +
        ' | Periodos con diferencia: ' + CAST(RES.PERIODOS_CON_DIF AS VARCHAR) +
        ' | Diferencia total: '        + CAST(RES.TOTAL_DIF        AS VARCHAR),
        C.PERIODO,
        C.NUEVO,
        C.ESTUDIANTES_FINANCIERA,
        C.ESTUDIANTES_ZOHO,
        C.DIFERENCIA
    FROM COMPARATIVO C
    CROSS JOIN RESUMEN RES

    DROP TABLE IF EXISTS #VENTAS_CON_ORDENES_FINAL

END
