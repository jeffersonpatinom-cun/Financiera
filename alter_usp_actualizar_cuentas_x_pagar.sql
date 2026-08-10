/* ============================================================================
   FIX  [Financiera].[usp_Actualizar_Cuentas_x_pagar]
   Problema: el SP hacia ALTER TABLE ADD <col> y en el MISMO lote un UPDATE
             que referenciaba esa columna. SQL Server compila el UPDATE antes
             de ejecutar el ALTER -> error 207 "Invalid column name" y aborta
             ANTES de reconstruir la tabla, dejandola vacia de forma permanente.
   Solucion: 1) materializar (DROP + SELECT INTO) igual que antes
             2) agregar TODAS las columnas de enriquecimiento (idempotente)
             3) ejecutar cada UPDATE dentro de EXEC(N'...') para que se compile
                despues de que las columnas ya existen.
   Nota: los #temp locales SI son visibles dentro de EXEC en la misma sesion.

   LOG: registra cada ejecucion en Financiera.LOG_Cuentas_x_pagar (OK/ERROR).
        En error captura ERROR_MESSAGE() (incl. ORA-01555) y re-lanza con THROW
        para que el job de SQL Agent tambien marque FALLO.
   ============================================================================ */
ALTER PROCEDURE [Financiera].[usp_Actualizar_Cuentas_x_pagar]
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @inicio DATETIME = GETDATE();
    DECLARE @filas  INT = 0;

    BEGIN TRY

    /* ---------- 1) MATERIALIZACION DESDE ORACLE (sin cambios) ------------- */
    DROP TABLE IF EXISTS Financiera.Cuentas_x_pagar;

    SELECT *
    INTO Financiera.Cuentas_x_pagar
    FROM OPENQUERY([172.16.1.175], '

SELECT
	TO_CHAR(SYSDATE, ''DD/MM/YYYY'') fecha_corte
	, SUBSTR(dato.fecha, 7, 4)||SUBSTR(dato.fecha, 4, 2) periodo
	, dato.transaccion
	, dato.documento
	, dato.organizacion
	, dato.secuencia
	, dato.radicacion
	, dato.organizacion_realizado
	, dato.documento_realizado
	, dato.numero_documento
	, dato.fecha_ppto
	, dato.doc_ppto
	, (
		SELECT
			TO_CHAR(fecha_radicacion, ''DD/MM/YYYY'')
		FROM	radicacion_cuentas rc
		WHERE	rc.radicacion = dato.radicacion
	) fecha_recibo_doc
	, (
		SELECT 	MAX(''Doc:''||documento||''-''||numero_documento||'' Fecha:''||TO_CHAR(fecha_documento, ''DD-MON-YYYY''))
		FROM	cumplimiento_requisito cr
		WHERE	cr.secuencia_necesario = dato.secuencia
		AND	cr.documento_cuenta = dato.documento
		AND	cr.organizacion_cuenta = dato.organizacion
		AND	cr.transaccion_cuenta = dato.transaccion
		AND	cr.documento_necesario = dato.documento_realizado
		AND	cr.organizacion_necesario = dato.organizacion_realizado
		AND	cr.numero_documento_cuenta = dato.numero_documento
		AND	TRUNC(cr.fecha_documento) IS NOT NULL
	) doc_soporte
	, (
		SELECT	MAX(conc.concepto||''-''||nombre_concepto)
		FROM	concepto_transaccion_cuenta conc
			, concepto_egreso conegr
		WHERE	conc.secuencia = dato.secuencia
		AND	conc.documento = dato.documento
		AND	conc.organizacion = dato.organizacion
		AND	conc.transaccion = dato.transaccion
		AND	conc.documento_realizado = dato.documento_realizado
		AND	conc.organizacion_realizado = dato.organizacion_realizado
		AND	conc.numero_documento = dato.numero_documento
		AND	conegr.concepto = conc.concepto
		AND	conegr.tipo_valor = ''B'' -- Base
	) concepto
	, dato.fecha fecha_contable
	, dato.fecha_vencimiento
	, dato.fecha_programada
	, dato.identificacion_beneficiario
	, dato.nombre_beneficiario
	, dato.tercero
	, dato.nombre_tercero
	, dato.valor_bruto
	, dato.valor_iva
	, dato.valor_neto
	, dato.valor_girado_fecha
	, dato.saldo
	, (
		SELECT 	centro_costo||''-''||nombre_centro_costo
		FROM	centro_costo
		WHERE	centro_costo =
			cpp_kardex_movimiento_cxp.centro_costo_cxp (
				dato.documento_realizado
				, dato.organizacion_realizado
				, dato.numero_documento
			)
	) centro_cxp
	, (
		SELECT 	fondo||''-''||nombre_fondo
		FROM	fondo
		WHERE	fondo =
			cpp_kardex_movimiento_cxp.fondo_cxp (
				dato.documento_realizado
				, dato.organizacion_realizado
				, dato.numero_documento
			)
	) fondo_cxp
	, (
		SELECT	rubro||''-''||nombre_rubro
		FROM	rubro
		WHERE	catalogo_rubro = ''CAT''
		AND	jerarquia_rubro =
			cpp_kardex_movimiento_cxp.rubro_cxp (
				dato.documento_realizado
				, dato.organizacion_realizado
				, dato.numero_documento
			)
	) rubro_cxp
	, (
		SELECT	codigo_contable||''-''||nombre_cuenta
		FROM	plan_contable
		WHERE	codigo_contable =
			cpp_kardex_movimiento_cxp.cuenta_cxp (
				dato.documento_realizado
				, dato.organizacion_realizado
				, dato.numero_documento
			)
	) cuenta_cxp
	, cpp_kardex_movimiento_cxp.cuenta_de_pago_cxp (
		dato.transaccion
		, dato.documento
		, dato.organizacion
		, dato.secuencia
	) cuenta_pago_cxp
	, dato.descripcion
FROM	(
		SELECT
			tg.transaccion
			, tg.documento
			, tg.organizacion
			, tg.secuencia
			, tg.radicacion
			, cxp.organizacion_realizado
			, cxp.documento_realizado
			, cxp.numero_documento
			, cxp.estado_vigencia
			, TO_CHAR(cxp.fecha, ''DD/MM/YYYY'') fecha
			, TO_CHAR(cxp.fecha_vencimiento, ''DD/MM/YYYY'') fecha_vencimiento
			, TO_CHAR(sal.fecha_documento, ''DD/MM/YYYY'') fecha_ppto
			, sal.documento||''-''||sal.numero_documento_externo doc_ppto
			, TO_CHAR(cxp.fecha_programada, ''DD/MM/YYYY'') fecha_programada
			, cxp.valor_bruto
			, cxp.valor_iva
			, cxp.valor_neto
			, cxp.valor_girado
			, cpp_kardex_movimiento_cxp.saldo_x_pagar (
				tg.documento
				, tg.organizacion
				, tg.transaccion
				, tg.secuencia
				, cxp.documento_realizado
				, cxp.organizacion_realizado
				, cxp.numero_documento
				, TO_DATE(TO_CHAR(SYSDATE, ''DD/MM/YYYY''), ''DD/MM/YYYY'')
			) saldo
			, (
				SELECT	SUM(valor_girado)
				FROM	cpt_kardex_movimiento_cxp anu
				WHERE	TRUNC(anu.fecha_evento) <= TO_DATE(TO_CHAR(SYSDATE, ''DD/MM/YYYY''), ''DD/MM/YYYY'')
				AND 	anu.evento IN (''GIA'', ''GIR'')
				AND 	anu.transaccion = cxp.transaccion
				AND	anu.documento = cxp.documento
				AND	anu.organizacion = cxp.organizacion
				AND	anu.secuencia = cxp.secuencia
				AND	anu.organizacion_realizado = cxp.organizacion_realizado
				AND 	anu.documento_realizado = cxp.documento_realizado
				AND 	anu.numero_documento = cxp.numero_documento
			) valor_girado_fecha
			, cxp.identificacion_beneficiario
			, cxp.nombre_beneficiario
			, rc.secuencia_persona
			, p.identificacion tercero
			, p.nombre_razon_social||'' ''||p.primer_apellido||'' ''||p.segundo_apellido nombre_tercero
			, cxp.descripcion
		FROM	cuentas_x_pagar cxp
			, transaccion_grupo tg
			, persona p
			, saldo_documento sal
			, radicacion_cuentas rc
		WHERE	tg.transaccion = cxp.transaccion
		AND	tg.documento = cxp.documento
		AND	tg.organizacion = cxp.organizacion
		AND	tg.secuencia = cxp.secuencia
		AND	tg.estado = ''A'' -- Aplicado
		AND	sal.organizacion = cxp.organizacion_realizado
		AND	sal.documento = cxp.documento_realizado
		AND	sal.numero_documento = cxp.numero_documento
		AND	TRUNC(cxp.fecha) <= TO_DATE(TO_CHAR(SYSDATE, ''DD/MM/YYYY''), ''DD/MM/YYYY'')
		AND	rc.radicacion = tg.radicacion
		AND	p.secuencia_persona = rc.secuencia_persona
		AND EXISTS (
			SELECT 	*
			FROM	afectacion_pago afec
			WHERE	afec.secuencia_para = cxp.secuencia
			AND	afec.documento = cxp.documento
			AND	afec.organizacion = cxp.organizacion
			AND	afec.transaccion = cxp.transaccion
			AND	afec.estado_vigencia = ''CAU'' -- Causado
			AND EXISTS (
				SELECT	*
				FROM	concepto_egreso conegr
				WHERE	conegr.concepto = afec.concepto_deduccion
				AND	conegr.tipo_valor = ''N'' -- Neto
			)
		)
		AND NOT EXISTS (
			SELECT	*
			FROM	cpt_kardex_cxp_excluidas excl
			WHERE 	excl.transaccion = cxp.transaccion
			AND 	excl.documento = cxp.documento
			AND 	excl.organizacion = cxp.organizacion
			AND 	excl.secuencia = cxp.secuencia
			AND 	excl.organizacion_realizado = cxp.organizacion_realizado
			AND 	excl.documento_realizado = cxp.documento_realizado
			AND 	excl.numero_documento = cxp.numero_documento
		)
	) dato
WHERE saldo > 0') a
    LEFT JOIN [Financiera].[Homologacion_cxp] b
        ON b.cuenta_cont = a.cuenta_pago_cxp;

    /* ---------- 2) ORIGEN COMPRAS ODC (temp, sin cambios) ---------------- */
    DROP TABLE IF EXISTS #ODC;

    SELECT *
    INTO #ODC
    FROM OPENQUERY([172.16.1.175], '
select
C.ORGANIZACION
,C.COMPRA
,TO_CHAR (C.FECHA_ELABORACION, ''DD/MM/YYYY'') AS FECHA_ELABORACION
,C.ESTADO
,C.TIPO_COMPRA
,C.VALOR_BRUTO
,C.VALOR_IVA
,C.VALOR_TOTAL
,C.FORMA_PAGO
,C.MONEDA
,C.MONEDA_PAGADA
,P.PROVEEDOR
,PE.TIPO_IDENTIFICACION
,PE.IDENTIFICACION
,PE.NOMBRE_RAZON_SOCIAL
,C.DESCRIPCION
from COMPRA C
LEFT JOIN PROVEEDOR P ON P.PROVEEDOR = C.PROVEEDOR
LEFT JOIN PERSONA PE ON PE.SECUENCIA_PERSONA = P.SECUENCIA_PERSONA
WHERE TO_CHAR (C.FECHA_ELABORACION, ''YYYY'') LIKE ''%25%'' OR TO_CHAR (C.FECHA_ELABORACION, ''YYYY'') LIKE ''%24%'' OR TO_CHAR (C.FECHA_ELABORACION, ''YYYY'') LIKE ''%26%''
');

    /* ---------- 3) AGREGAR TODAS LAS COLUMNAS (idempotente) --------------- */
    IF COL_LENGTH('Financiera.Cuentas_x_pagar','compra') IS NULL
        ALTER TABLE Financiera.Cuentas_x_pagar ADD compra VARCHAR(200);
    IF COL_LENGTH('Financiera.Cuentas_x_pagar','Condicion_de_Pago') IS NULL
        ALTER TABLE Financiera.Cuentas_x_pagar ADD Condicion_de_Pago VARCHAR(50);
    IF COL_LENGTH('Financiera.Cuentas_x_pagar','forma_pago_calculada') IS NULL
        ALTER TABLE Financiera.Cuentas_x_pagar ADD forma_pago_calculada DATE;
    IF COL_LENGTH('Financiera.Cuentas_x_pagar','fecha_programa_calculada') IS NULL
        ALTER TABLE Financiera.Cuentas_x_pagar ADD fecha_programa_calculada DATE;

    /* ---------- 4) ENRIQUECIMIENTO (cada UPDATE en su propio EXEC) -------- */

    -- 4.1 COMPRA: numero de orden desde doc_ppto
    EXEC(N'
        UPDATE cp
        SET compra = CASE
                         WHEN cp.documento = ''ODC'' AND CHARINDEX(''-'', cp.doc_ppto) > 0
                         THEN SUBSTRING(cp.doc_ppto, CHARINDEX(''-'', cp.doc_ppto) + 1, LEN(cp.doc_ppto))
                         ELSE cp.doc_ppto
                     END
        FROM Financiera.Cuentas_x_pagar cp;');

    -- 4.2 CONDICION DE PAGO (traduce FORMA_PAGO del modulo de compras)
    EXEC(N'
        UPDATE cxp
        SET cxp.Condicion_de_Pago =
            CASE
                WHEN cxp.Documento = ''ODC'' THEN
                    CASE odc.FORMA_PAGO
                        WHEN 1 THEN ''45 días''
                        WHEN 2 THEN ''30 días''
                        WHEN 3 THEN ''Anticipo 50%''
                        WHEN 4 THEN ''Contraentrega''
                        WHEN 5 THEN ''60 días''
                        WHEN 6 THEN ''Contado''
                        WHEN 7 THEN ''Anticipo 30 días''
                        WHEN 9 THEN ''90 días''
                        ELSE ''Otra forma''
                    END
                ELSE ''''
            END
        FROM [Financiera].[Cuentas_x_pagar] cxp
        LEFT JOIN #ODC odc ON cxp.COMPRA = CAST(odc.COMPRA AS VARCHAR(200));');

    -- 4.3 FORMA_PAGO_CALCULADA (fecha de pago estimada)
    EXEC(N'
        UPDATE cxp
        SET cxp.forma_pago_calculada =
            CASE
                WHEN cxp.Documento = ''ODC'' AND ISDATE(cxp.Fecha_Contable) = 1 THEN
                    DATEADD(DAY,
                        CASE odc.FORMA_PAGO
                            WHEN ''1'' THEN 45
                            WHEN ''2'' THEN 30
                            WHEN ''3'' THEN 0
                            WHEN ''4'' THEN 0
                            WHEN ''5'' THEN 60
                            WHEN ''6'' THEN 0
                            WHEN ''7'' THEN 30
                            WHEN ''9'' THEN 90
                            ELSE 0
                        END,
                        CAST(cxp.Fecha_Contable AS DATE))
                ELSE NULL
            END
        FROM [Financiera].[Cuentas_x_pagar] cxp
        LEFT JOIN #ODC odc ON cxp.COMPRA = CAST(odc.COMPRA AS VARCHAR(200));');

    -- 4.4 FECHA_PROGRAMA_CALCULADA (definitiva: extrae dias de la condicion de pago)
    EXEC(N'
        ;WITH datos AS (
            SELECT
                cxp.Documento, cxp.Fecha_Contable, cxp.Fecha_Programada, cxp.Condicion_de_Pago,
                cxp.fecha_programa_calculada,
                CASE
                    WHEN cxp.Condicion_de_Pago IS NULL THEN NULL
                    WHEN cxp.Condicion_de_Pago LIKE ''%Contado%'' THEN 0
                    WHEN cxp.Condicion_de_Pago LIKE ''%Contraentrega%'' THEN 0
                    WHEN PATINDEX(''%[0-9]%'', cxp.Condicion_de_Pago) > 0 THEN
                        TRY_CAST(
                            LEFT(
                                SUBSTRING(cxp.Condicion_de_Pago, PATINDEX(''%[0-9]%'', cxp.Condicion_de_Pago), 10),
                                CASE
                                    WHEN PATINDEX(''%[^0-9]%'', SUBSTRING(cxp.Condicion_de_Pago, PATINDEX(''%[0-9]%'', cxp.Condicion_de_Pago), 10)) = 0
                                    THEN 10
                                    ELSE PATINDEX(''%[^0-9]%'', SUBSTRING(cxp.Condicion_de_Pago, PATINDEX(''%[0-9]%'', cxp.Condicion_de_Pago), 10)) - 1
                                END
                            ) AS INT)
                    ELSE NULL
                END AS dias_extraidos
            FROM Financiera.Cuentas_x_pagar cxp
        )
        UPDATE d
        SET d.fecha_programa_calculada =
            CASE
                WHEN d.Documento = ''ODC''
                     AND TRY_CONVERT(date, d.Fecha_Contable, 103) IS NOT NULL
                     AND d.dias_extraidos IS NOT NULL
                THEN DATEADD(DAY, d.dias_extraidos, TRY_CONVERT(date, d.Fecha_Contable, 103))
                ELSE TRY_CONVERT(date, d.Fecha_Programada, 103)
            END
        FROM datos d;');

    DROP TABLE IF EXISTS #ODC;

    /* ---------- 5) LOG OK ------------------------------------------------- */
    SET @filas = (SELECT COUNT(*) FROM Financiera.Cuentas_x_pagar);

    INSERT INTO Financiera.LOG_Cuentas_x_pagar
        (sp_nombre, fecha_inicio, fecha_fin, duracion_seg, filas_cargadas, estado, mensaje)
    VALUES
        ('usp_Actualizar_Cuentas_x_pagar', @inicio, GETDATE(),
         DATEDIFF(SECOND, @inicio, GETDATE()), @filas, 'OK',
         CONCAT('Ejecucion exitosa. Filas cargadas: ', @filas));

    END TRY
    BEGIN CATCH

        DROP TABLE IF EXISTS #ODC;

        INSERT INTO Financiera.LOG_Cuentas_x_pagar
            (sp_nombre, fecha_inicio, fecha_fin, duracion_seg, filas_cargadas, estado, mensaje)
        VALUES
            ('usp_Actualizar_Cuentas_x_pagar', @inicio, GETDATE(),
             DATEDIFF(SECOND, @inicio, GETDATE()), NULL, 'ERROR',
             LEFT(CONCAT('Error ', ERROR_NUMBER(), ' (linea ', ERROR_LINE(), '): ', ERROR_MESSAGE()), 500));

        -- Re-lanzar para que el job de SQL Agent tambien marque FALLO
        THROW;

    END CATCH
END;
