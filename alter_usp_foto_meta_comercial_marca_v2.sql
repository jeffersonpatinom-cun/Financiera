/* ============================================================================
   [Financiera].[USP_Foto_Meta_Comercial_Mensual]  — histórico por COLUMNA-AÑO
   ----------------------------------------------------------------------------
   BASE: FINANCIERA.CARTERA filtrada (cuota capital CLTIENE, estudiantes,
         corriente = 0, periodo del año). Grano = cuota x estudiante (1 fila
         por NUMERO_CREDITO).
   HISTÓRICO: una sola fila por crédito. Las marcas mensuales (yyyyMM) se
         acumulan en una columna POR AÑO:  Meta_2026, Meta_2027, ...
           * crédito NUEVO         -> INSERT con Meta_<año> = @AnioMes
           * crédito que SIGUE      -> concatena @AnioMes en Meta_<año> ('202607, 202608')
           * crédito que YA PAGÓ    -> desaparece del query -> se deja intacto
         La columna Meta_<año> se crea sola (ALTER dinámico) la primera vez que
         corre un año nuevo. Atributos CONGELADOS al primer ingreso.
   ENRIQUECIMIENTOS (LEFT JOIN):
         * Ultimo_acceso_moodle : CUN_STAGE.moodle.repli_mdl_user
                                  (username = IDENTIFICACION) -> lastaccess a fecha.
                                  SE REFRESCA cada mes (dato vivo, rama UPDATE).
         * Promedio_notas       : OPENQUERY 172.16.1.175 sinu.V_DEMOGRAFICO_ESTUDIANTE_VIG
                                  (COD_PERIODO + NUM_IDENTIFICACION) -> PROMEDIO.
                                  SE REFRESCA cada mes (rama UPDATE).
         * ESTADO_ALUMNO /      : marcadores académicos replicados de [Financiera].[SP_Cartera_Total]
           MARCA_ACADEMICA        (PASO 3). ESTADO_ALUMNO = COALESCE(ESTADISTICA_ESTUDIANTE_2,
                                  Zoho.BASE_PERSONAS, ESTADISTICA_ACADEMICA). MARCA_ACADEMICA se
                                  deriva del estado del periodo (Dbo.Periodos_Calendario) y el
                                  PROMEDIO de ESTADISTICA_ESTUDIANTE_2. SE REFRESCAN cada mes.
   REGLA conservada: 'Asignacion Q' por suma acumulada de TOTAL ordenada por
         FECHA_VENCIMIENTO (Q1 = más vencido ... Q4 = más reciente; venc. nulos -> Q4).
   IDEMPOTENTE por mes. PROGRAMACIÓN: día 1 de cada mes 00:30.
   ============================================================================ */
CREATE   PROCEDURE [Financiera].[USP_Foto_Meta_Comercial_Mensual]
    @AnioMes        VARCHAR(6)  = NULL,   -- yyyyMM de la marca; NULL = mes actual
    @PatronPeriodo  VARCHAR(20) = NULL    -- patrón LIKE del PERIODO; NULL = '%' + año(2díg) + '%'
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Periodo VARCHAR(6)  = COALESCE(@AnioMes, FORMAT(GETDATE(), 'yyyyMM'));
    DECLARE @Anio    VARCHAR(4)  = LEFT(@Periodo, 4);
    DECLARE @Patron  VARCHAR(20) = COALESCE(@PatronPeriodo, '%' + RIGHT(@Anio, 2) + '%');
    DECLARE @ColMeta SYSNAME     = N'Meta_' + @Anio;           -- columna del año
    DECLARE @sql     NVARCHAR(MAX);
    DECLARE @upd INT = 0, @ins INT = 0;
    DECLARE @err_mensaje VARCHAR(2000), @err_sev INT;

    BEGIN TRY
        ----------------------------------------------------------------------
        -- 1) Crear la tabla si no existe (esquema = CARTERA + meta + enriquec.)
        ----------------------------------------------------------------------
        IF OBJECT_ID('Financiera.Cartera_Meta_Comercial_Historico', 'U') IS NULL
        BEGIN
            SELECT TOP 0
                C.*,
                CAST(NULL AS VARCHAR(2))  AS [Asignacion Q],
                CAST(NULL AS DATETIME)    AS Ultimo_acceso_moodle,
                CAST(NULL AS FLOAT)       AS Promedio_notas,
                CAST(NULL AS VARCHAR(6))  AS Anio_Mes_Ingreso,
                CAST(NULL AS DATETIME)    AS AUD_FECHA_FOTO,
                CAST(NULL AS DATETIME)    AS AUD_FECHA_ACTUALIZACION
            INTO Financiera.Cartera_Meta_Comercial_Historico
            FROM FINANCIERA.CARTERA C
            WHERE 1 = 0;

            CREATE UNIQUE NONCLUSTERED INDEX UX_MetaHist_Credito
                ON Financiera.Cartera_Meta_Comercial_Historico (NUMERO_CREDITO);
        END

        -- 1.1) Asegurar columnas de enriquecimiento (si la tabla ya existía)
        IF COL_LENGTH('Financiera.Cartera_Meta_Comercial_Historico', 'Ultimo_acceso_moodle') IS NULL
            ALTER TABLE Financiera.Cartera_Meta_Comercial_Historico ADD Ultimo_acceso_moodle DATETIME NULL;
        IF COL_LENGTH('Financiera.Cartera_Meta_Comercial_Historico', 'Promedio_notas') IS NULL
            ALTER TABLE Financiera.Cartera_Meta_Comercial_Historico ADD Promedio_notas FLOAT NULL;
        -- Marcadores académicos replicados de [Financiera].[SP_Cartera_Total] (PASO 3)
        IF COL_LENGTH('Financiera.Cartera_Meta_Comercial_Historico', 'ESTADO_ALUMNO') IS NULL
            ALTER TABLE Financiera.Cartera_Meta_Comercial_Historico ADD ESTADO_ALUMNO VARCHAR(50) NULL;
        IF COL_LENGTH('Financiera.Cartera_Meta_Comercial_Historico', 'MARCA_ACADEMICA') IS NULL
            ALTER TABLE Financiera.Cartera_Meta_Comercial_Historico ADD MARCA_ACADEMICA VARCHAR(50) NULL;
        IF COL_LENGTH('Financiera.Cartera_Meta_Comercial_Historico', 'MARCA_ACADEMICA_DETALLE') IS NULL
            ALTER TABLE Financiera.Cartera_Meta_Comercial_Historico ADD MARCA_ACADEMICA_DETALLE VARCHAR(50) NULL;

        ----------------------------------------------------------------------
        -- 2) Asegurar la columna del año (DDL dinámico). Ej: Meta_2026, Meta_2027
        ----------------------------------------------------------------------
        IF COL_LENGTH('Financiera.Cartera_Meta_Comercial_Historico', @ColMeta) IS NULL
        BEGIN
            SET @sql = N'ALTER TABLE Financiera.Cartera_Meta_Comercial_Historico ADD '
                     + QUOTENAME(@ColMeta) + N' VARCHAR(2000) NULL;';
            EXEC sp_executesql @sql;
        END

        ----------------------------------------------------------------------
        -- 3) Enriquecimientos -> #MOODLE y #PROM (1 fila por llave)
        ----------------------------------------------------------------------
        IF OBJECT_ID('tempdb..#MOODLE') IS NOT NULL DROP TABLE #MOODLE;
        SELECT id_k, Ultimo_acceso_moodle
        INTO #MOODLE
        FROM (
            SELECT LTRIM(RTRIM(username)) AS id_k,
                   DATEADD(SECOND, lastaccess, '1970-01-01') AS Ultimo_acceso_moodle,
                   ROW_NUMBER() OVER (PARTITION BY LTRIM(RTRIM(username)) ORDER BY lastaccess DESC) AS rn
            FROM CUN_STAGE.moodle.repli_mdl_user
        ) z WHERE rn = 1;
        CREATE CLUSTERED INDEX IX_moodle ON #MOODLE(id_k);

        IF OBJECT_ID('tempdb..#PROM') IS NOT NULL DROP TABLE #PROM;
        SELECT COD_PERIODO, id_k, PROMEDIO
        INTO #PROM
        FROM (
            SELECT COD_PERIODO, LTRIM(RTRIM(NUM_IDENTIFICACION)) AS id_k, PROMEDIO,
                   ROW_NUMBER() OVER (PARTITION BY COD_PERIODO, LTRIM(RTRIM(NUM_IDENTIFICACION))
                                      ORDER BY (SELECT 1)) AS rn
            FROM OPENQUERY([172.16.1.175],
                'select NUM_IDENTIFICACION,COD_PERIODO,PROMEDIO
                 from sinu.V_DEMOGRAFICO_ESTUDIANTE_VIG
                 where ESTADO_PAGO = ''PAGO''')
        ) z WHERE rn = 1;
        CREATE CLUSTERED INDEX IX_prom ON #PROM(COD_PERIODO, id_k);

        ----------------------------------------------------------------------
        -- 4) Fuente del mes + Asignacion Q + enriquecimientos  ->  #SRC
        ----------------------------------------------------------------------
        IF OBJECT_ID('tempdb..#SRC') IS NOT NULL DROP TABLE #SRC;

        ;WITH SRC AS (
            SELECT
                C.*,
                SUM(CAST(C.TOTAL AS DECIMAL(18,2))) OVER (
                    ORDER BY
                        CASE WHEN TRY_CONVERT(date, C.FECHA_VENCIMIENTO, 103) IS NULL THEN 1 ELSE 0 END ASC,
                        TRY_CONVERT(date, C.FECHA_VENCIMIENTO, 103) ASC,
                        C.IDENTIFICACION, C.NUMERO_CREDITO
                    ROWS UNBOUNDED PRECEDING
                ) AS _RunTotal,
                SUM(CAST(C.TOTAL AS DECIMAL(18,2))) OVER () AS _GrandTotal
            FROM FINANCIERA.CARTERA C
            WHERE C.DOCUMENTO          = 'NDB'
              AND C.NOMBRE_TIPO_CLIENTE = 'ESTUDIANTES'
              AND C.NOMBRE_CONCEPTO     = '701-ND CARGOS FINANCIEROS A ESTUDIANTES'
              AND C.NOMBRE_CAUSA        = '715-CUOTA CAPITAL CLTIENE'
              AND C.CORRIENTE           = 0
              AND C.TOTAL               > 24000   -- solo cuotas con valor > 24000
              AND C.PERIODO LIKE @Patron
        ),
        -- ── Fuentes académicas (replicadas de [Financiera].[SP_Cartera_Total], PASO 3) ──
        -- Prioridad para ESTADO_ALUMNO: 1) ESTADISTICA_ESTUDIANTE_2  2) Zoho  3) ESTADISTICA_ACADEMICA
        ESTADISTICA_DEDUP AS (
            SELECT NUM_IDENTIFICACION, COD_PERIODO, ESTADO_ALUMNO, PROMEDIO
            FROM (
                SELECT NUM_IDENTIFICACION, COD_PERIODO, ESTADO_ALUMNO, PROMEDIO,
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
        ZOHO_BASE AS (
            SELECT DOC_ALUM AS NUM_IDENTIFICACION, PERIODO AS COD_PERIODO,
                   EST_MATRICULADO AS ESTADO_ALUMNO,
                   ROW_NUMBER() OVER (PARTITION BY DOC_ALUM, PERIODO ORDER BY DOC_ALUM) AS rn_zoho
            FROM ZOHO.BASE_PERSONAS
        ),
        ESTADISTICA_ACADEMICA AS (
            SELECT NUM_IDENTIFICACION, COD_PERIODO,
                CASE
                    WHEN EST_ALUMNO = 'Activo'           THEN '1-Activo'
                    WHEN EST_ALUMNO = 'Egresado'         THEN '2-Egresado'
                    WHEN EST_ALUMNO = 'Graduado'         THEN '3-Graduado'
                    WHEN EST_ALUMNO = 'Graduado Postumo' THEN '12-Graduado Postumo'
                    ELSE EST_ALUMNO
                END AS ESTADO_ALUMNO,
                PROMEDIO,
                ROW_NUMBER() OVER (PARTITION BY NUM_IDENTIFICACION ORDER BY SEMESTRE DESC) AS PERIODO_PRIORIDAD
            FROM CUN.ESTADISTICA_ACADEMICA
        ),
        -- Riesgo crediticio del deudor (replicado de [Financiera].[SP_Cartera_Total]).
        -- Dedup 1:1 por documento+periodo dejando el PEOR riesgo / menor score, para que
        -- el escalamiento sea conservador cuando hay varias financiaciones.
        CTAYUDA_RIESGO AS (
            SELECT DR_NUMERO_DOCUMENTO_ESTUDIANTE, ZH_PERIODO, RES_PERFIL_RIESGO
            FROM (
                SELECT DR_NUMERO_DOCUMENTO_ESTUDIANTE, ZH_PERIODO, RES_PERFIL_RIESGO,
                       ROW_NUMBER() OVER (
                           PARTITION BY DR_NUMERO_DOCUMENTO_ESTUDIANTE, ZH_PERIODO
                           ORDER BY CASE RES_PERFIL_RIESGO
                                        WHEN 'Riesgo Alto'      THEN 1
                                        WHEN 'Riesgo Regular'   THEN 2
                                        WHEN 'Riesgo Bueno'     THEN 3
                                        WHEN 'Riesgo Muy Bueno' THEN 4
                                        WHEN 'Riesgo Excelente' THEN 5
                                        ELSE 9 END ASC,
                                    TRY_CAST(RES_SCORE AS FLOAT) ASC
                       ) AS rn
                FROM Financiera.Financiaciones_CTAYUDA_V2
            ) x WHERE rn = 1
        ),
        PERIODO_CAL AS (
            SELECT DISTINCT CONVERT(VARCHAR(10), cod_periodo) AS PERIODO,
                CASE
                    WHEN fec_inicio >  CAST(GETDATE() AS DATE)                                             THEN 'PERIODO NO HA INICIADO'
                    WHEN fec_inicio <= CAST(GETDATE() AS DATE) AND fec_fin >= CAST(GETDATE() AS DATE)      THEN 'ACTIVO'
                    ELSE 'NO ACTIVO'
                END AS ESTADO
            FROM Dbo.Periodos_Calendario
        )
        SELECT
            S.*,
            CASE
                WHEN S._GrandTotal IS NULL OR S._GrandTotal = 0 THEN 'Q1'
                WHEN S._RunTotal / S._GrandTotal <= 0.25         THEN 'Q1'
                WHEN S._RunTotal / S._GrandTotal <= 0.50         THEN 'Q2'
                WHEN S._RunTotal / S._GrandTotal <= 0.75         THEN 'Q3'
                ELSE 'Q4'
            END                          AS Asignacion_Q,
            M.Ultimo_acceso_moodle       AS Ultimo_acceso_moodle,
            P.PROMEDIO                   AS Promedio_notas,
            COALESCE(B.ESTADO_ALUMNO, Z.ESTADO_ALUMNO, E.ESTADO_ALUMNO) AS ESTADO_ALUMNO,
            -- MARCA_ACADEMICA alineada con [Financiera].[SP_Cartera_Total] (V2, 2026-08-21).
            -- La escalera base vive en el CROSS APPLY MB de abajo; aqui solo se aplica el
            -- refinamiento por riesgo crediticio ADVERSO ('Riesgo Alto' + 'Riesgo Regular',
            -- score < 670): un caso academicamente blando pero con buro adverso se escala.
            CASE
                WHEN MB.MARCA_BASE = 'GESTIONABLE'
                 AND F.RES_PERFIL_RIESGO IN ('Riesgo Alto', 'Riesgo Regular')
                     THEN 'PERIODO PERDIDO, PRIORIDAD ALTA'
                ELSE MB.MARCA_BASE
            END                          AS MARCA_ACADEMICA,
            -- Subcategoria: ordena la cola de trabajo dentro de cada marca.
            CASE
                WHEN MB.MARCA_BASE = 'PERIODO NO HA INICIADO' THEN 'PERIODO NO HA INICIADO'

                WHEN MB.MARCA_BASE = 'PERIODO EN CURSO'
                 AND F.RES_PERFIL_RIESGO IN ('Riesgo Alto', 'Riesgo Regular')
                     THEN 'PERIODO EN CURSO - RIESGO CREDITICIO'
                WHEN MB.MARCA_BASE = 'PERIODO EN CURSO'      THEN 'PERIODO EN CURSO'

                WHEN MB.MARCA_BASE = 'PERIODO PERDIDO, PRIORIDAD ALTA'
                 AND F.RES_PERFIL_RIESGO IN ('Riesgo Alto', 'Riesgo Regular')
                     THEN 'PERIODO PERDIDO + RIESGO CREDITICIO'
                WHEN MB.MARCA_BASE = 'PERIODO PERDIDO, PRIORIDAD ALTA' THEN 'PERIODO PERDIDO'

                WHEN MB.MARCA_BASE = 'GESTIONABLE'
                 AND F.RES_PERFIL_RIESGO IN ('Riesgo Alto', 'Riesgo Regular')
                     THEN 'RIESGO CREDITICIO ADVERSO'
                WHEN MB.MARCA_BASE = 'GESTIONABLE'           THEN 'GESTIONABLE'

                WHEN M.Ultimo_acceso_moodle IS NOT NULL THEN 'SIN REGISTRO DE CLASE - CON CONEXION'
                ELSE 'SIN REGISTRO DE CLASE - SIN CONTACTO'
            END                          AS MARCA_ACADEMICA_DETALLE
        INTO #SRC
        FROM SRC S
        LEFT JOIN #MOODLE M ON M.id_k = LTRIM(RTRIM(S.IDENTIFICACION))
        LEFT JOIN #PROM   P ON P.COD_PERIODO = S.PERIODO
                           AND P.id_k        = LTRIM(RTRIM(S.IDENTIFICACION))
        LEFT JOIN ESTADISTICA_DEDUP B
               ON CONVERT(VARCHAR(50), S.IDENTIFICACION) = B.NUM_IDENTIFICACION
              AND S.PERIODO = B.COD_PERIODO
        LEFT JOIN (SELECT * FROM ZOHO_BASE WHERE rn_zoho = 1) Z
               ON CONVERT(VARCHAR(50), S.IDENTIFICACION) = Z.NUM_IDENTIFICACION
              AND S.PERIODO = Z.COD_PERIODO
        LEFT JOIN (SELECT * FROM ESTADISTICA_ACADEMICA WHERE PERIODO_PRIORIDAD = 1) E
               ON CONVERT(VARCHAR(50), S.IDENTIFICACION) = E.NUM_IDENTIFICACION
              AND S.PERIODO = E.COD_PERIODO
        LEFT JOIN PERIODO_CAL PC
               ON S.PERIODO = PC.PERIODO
        LEFT JOIN CTAYUDA_RIESGO F
               ON CONVERT(VARCHAR(50), S.IDENTIFICACION) = F.DR_NUMERO_DOCUMENTO_ESTUDIANTE
              AND CONVERT(VARCHAR(20), S.PERIODO) = CONVERT(VARCHAR(20), F.ZH_PERIODO)
        -- Escalera academica base, identica a la de SP_Cartera_Total salvo la rama de
        -- segmento: aqui el origen ya filtra NOMBRE_TIPO_CLIENTE = 'ESTUDIANTES', asi que
        -- 'CARTERA EMPRESARIAL' seria codigo muerto y se omite a proposito.
        CROSS APPLY (VALUES (
            CASE
                WHEN PC.ESTADO = 'ACTIVO'                 THEN 'PERIODO EN CURSO'
                WHEN PC.ESTADO = 'PERIODO NO HA INICIADO' THEN 'PERIODO NO HA INICIADO'

                WHEN COALESCE(B.PROMEDIO, E.PROMEDIO) <  1.55 THEN 'SIN REGISTRO DE CLASE'
                WHEN COALESCE(B.PROMEDIO, E.PROMEDIO) <  3.0  THEN 'PERIODO PERDIDO, PRIORIDAD ALTA'
                WHEN COALESCE(B.PROMEDIO, E.PROMEDIO) >= 3.0  THEN 'GESTIONABLE'

                WHEN COALESCE(B.ESTADO_ALUMNO, Z.ESTADO_ALUMNO, E.ESTADO_ALUMNO) LIKE '%graduad%'
                  OR COALESCE(B.ESTADO_ALUMNO, Z.ESTADO_ALUMNO, E.ESTADO_ALUMNO) LIKE '%egresad%'
                                                              THEN 'GESTIONABLE'

                WHEN M.Ultimo_acceso_moodle >= DATEADD(DAY, -90, CAST(GETDATE() AS DATE))
                                                              THEN 'PERIODO EN CURSO'

                ELSE 'SIN REGISTRO DE CLASE'
            END
        )) AS MB(MARCA_BASE);

        ----------------------------------------------------------------------
        -- 5a) Créditos que SIGUEN en la meta: concatena el mes en la col-año
        ----------------------------------------------------------------------
        SET @sql = N'
            UPDATE T
               SET T.' + QUOTENAME(@ColMeta) + N' =
                       CASE WHEN T.' + QUOTENAME(@ColMeta) + N' IS NULL THEN @Periodo
                            ELSE T.' + QUOTENAME(@ColMeta) + N' + '', '' + @Periodo END,
                   T.Ultimo_acceso_moodle    = S.Ultimo_acceso_moodle,   -- refresco mensual (dato vivo)
                   T.Promedio_notas          = S.Promedio_notas,         -- refresco mensual
                   T.ESTADO_ALUMNO           = S.ESTADO_ALUMNO,          -- refresco mensual (marcador académico)
                   T.MARCA_ACADEMICA         = S.MARCA_ACADEMICA,        -- refresco mensual
                   T.MARCA_ACADEMICA_DETALLE = S.MARCA_ACADEMICA_DETALLE,-- refresco mensual
                   T.AUD_FECHA_ACTUALIZACION = GETDATE()
              FROM Financiera.Cartera_Meta_Comercial_Historico T
              JOIN #SRC S ON T.NUMERO_CREDITO = S.NUMERO_CREDITO
             WHERE T.' + QUOTENAME(@ColMeta) + N' IS NULL
                OR T.' + QUOTENAME(@ColMeta) + N' NOT LIKE ''%'' + @Periodo + ''%'';';
        EXEC sp_executesql @sql, N'@Periodo VARCHAR(6)', @Periodo = @Periodo;
        SET @upd = @@ROWCOUNT;

        ----------------------------------------------------------------------
        -- 5b) Créditos NUEVOS: insertar con la col-año marcada + enriquecimientos
        ----------------------------------------------------------------------
        SET @sql = N'
            INSERT INTO Financiera.Cartera_Meta_Comercial_Historico
                (FECHA_CORTE, PERIODO, TIPO_CLIENTE, NOMBRE_TIPO_CLIENTE, IDENTIFICACION,
                 FEC_NAC, GENDER, DIRECCION_CASA, EMAIL, TEL_CASA, TEL_CELULAR, WHATSAPP,
                 PAIS, DEPARTAMENTO, POBLACION, CLIENTE, NOMBRE, LINEA, TIPO_DOCUMENTO,
                 DOCUMENTO, NUMERO_CREDITO, FECHA, FECHA_VENCIMIENTO, CENTRO_COSTO,
                 NOMBRE_CENTRO, FONDO, NOMBRE_FONDO, NOMBRE_CONCEPTO, NOMBRE_CAUSA,
                 VALOR_ORIGINAL, CORRIENTE, GR1A30, GR31A60, GR61A90, GR91A120, GR121A150,
                 GR151A360, GR360MAS, TOTAL, CODIGO_CONTABLE, DESCRIPCION,
                 [Asignacion Q], Ultimo_acceso_moodle, Promedio_notas,
                 ESTADO_ALUMNO, MARCA_ACADEMICA, MARCA_ACADEMICA_DETALLE,
                 Anio_Mes_Ingreso, AUD_FECHA_FOTO, AUD_FECHA_ACTUALIZACION, '
                 + QUOTENAME(@ColMeta) + N')
            SELECT
                 S.FECHA_CORTE, S.PERIODO, S.TIPO_CLIENTE, S.NOMBRE_TIPO_CLIENTE, S.IDENTIFICACION,
                 S.FEC_NAC, S.GENDER, S.DIRECCION_CASA, S.EMAIL, S.TEL_CASA, S.TEL_CELULAR, S.WHATSAPP,
                 S.PAIS, S.DEPARTAMENTO, S.POBLACION, S.CLIENTE, S.NOMBRE, S.LINEA, S.TIPO_DOCUMENTO,
                 S.DOCUMENTO, S.NUMERO_CREDITO, S.FECHA, S.FECHA_VENCIMIENTO, S.CENTRO_COSTO,
                 S.NOMBRE_CENTRO, S.FONDO, S.NOMBRE_FONDO, S.NOMBRE_CONCEPTO, S.NOMBRE_CAUSA,
                 S.VALOR_ORIGINAL, S.CORRIENTE, S.GR1A30, S.GR31A60, S.GR61A90, S.GR91A120, S.GR121A150,
                 S.GR151A360, S.GR360MAS, S.TOTAL, S.CODIGO_CONTABLE, S.DESCRIPCION,
                 S.Asignacion_Q, S.Ultimo_acceso_moodle, S.Promedio_notas,
                 S.ESTADO_ALUMNO, S.MARCA_ACADEMICA, S.MARCA_ACADEMICA_DETALLE,
                 @Periodo, GETDATE(), GETDATE(), @Periodo
              FROM #SRC S
             WHERE NOT EXISTS (
                   SELECT 1 FROM Financiera.Cartera_Meta_Comercial_Historico T
                    WHERE T.NUMERO_CREDITO = S.NUMERO_CREDITO);';
        EXEC sp_executesql @sql, N'@Periodo VARCHAR(6)', @Periodo = @Periodo;
        SET @ins = @@ROWCOUNT;

        PRINT 'Meta ' + @ColMeta + ' / mes ' + @Periodo + ' (patrón ' + @Patron + '). '
            + 'Nuevos insertados: ' + CAST(@ins AS VARCHAR(20))
            + ' | Acumulados (siguen): ' + CAST(@upd AS VARCHAR(20));
    END TRY
    BEGIN CATCH
        SET @err_mensaje = ERROR_MESSAGE();
        SET @err_sev     = ERROR_SEVERITY();
        RAISERROR(@err_mensaje, @err_sev, 1);
    END CATCH
END
