USE CUN_REPOSITORIO;
GO

-- ==============================================================================================
-- PROCEDIMIENTO / CONSULTA: CONSOLIDADO FINANCIACIONES CTAYUDA ESTUDIANTES
-- ==============================================================================================
-- DESCRIPCIÓN: 
-- Extrae, transforma y consolida la sábana de datos de estudiantes con créditos aprobados 
-- (ESTADO_FINANCIACION = 1) en el programa CTAYUDA.
--
-- FLUJO DE DATOS (DATA FLOW):
-- 1. DRIVER: La tabla base es ICEBERG.CLTIENE_360_ESTUDIANTES (Estudiantes aprobados).
-- 2. ENRIQUECIMIENTO: Se cruza con Respuestas (demografía), V2 (contacto y RPVI), Cuotas y 
--    Zoho Base_Personas (académico/comercial).
-- 3. FINANCIERO: Se cruza con Cartera_Total (tramos de mora) y RECIBOS_CAJA (pagos reales).
--
-- CONTROL DE CALIDAD (DEDUPLICACIÓN):
-- Para evitar productos cartesianos (multiplicación de deudas), todos los CTEs periféricos 
-- utilizan ROW_NUMBER() para extraer el registro más reciente (rn=1) o SUM/GROUP BY para 
-- pre-agregar valores antes del JOIN final.
-- ==============================================================================================

WITH

-- ── CTE 1 : TABLA IZQUIERDA (DRIVER) ─────────────────────────────────────────
-- Propósito: Obtener el universo de créditos aprobados. Esta tabla dicta la granularidad 
-- final del reporte (1 fila por Orden/Estudiante).
-- Regla de Negocio: Solo se incluyen aquellos con ESTADO_FINANCIACION = 1.
-- Limpieza: Se aplican LTRIM y RTRIM a las llaves maestras para optimizar los JOINs posteriores.
ESTUDIANTES AS (
    SELECT
        LTRIM(RTRIM(CAST(NUMERO_DOCUMENTO AS NVARCHAR(100)))) AS NUMERO_DOCUMENTO,
        LTRIM(RTRIM(CAST(ORDEN_CUN AS NVARCHAR(100))))        AS ORDEN_CUN,
        CAST(REFERENCIA_PAGO AS NVARCHAR(100))                AS REFERENCIA_PAGO,
        FEC_CREACION                                          AS FECHA_CREA_ESTUDIANTE_CLTIENE,
        TRY_CAST(VALOR_AVAL AS DECIMAL(18,2))                 AS VALOR_AVAL,
        TRY_CAST(SERVICIO_MEDICO AS DECIMAL(18,2))            AS SERVICIO_MEDICO,
        TRY_CAST(VALOR_PAGADO AS DECIMAL(18,2))               AS VALOR_PAGADO,
        TRY_CAST(VALOR_MATRICULA AS DECIMAL(18,2))            AS VALOR_ORDEN,
        TRY_CAST(VALOR_FINANCIACION AS DECIMAL(18,2))         AS VALOR_FINANCIADO,
        TRY_CAST(GASTOS_TECNICOS AS DECIMAL(18,2))            AS GASTOS_TECNICOS,
        TRY_CAST(PORCENTAJE_INTERES AS DECIMAL(18,2))         AS PORCENTAJE_INTERES,
        CAST(ESTADO_PAGO_ESTUDIO AS NVARCHAR(50))             AS ESTADO_PAGO_ESTUDIO
    FROM OPENQUERY([172.16.1.175], '
        SELECT CAST(NUMERO_DOCUMENTO AS VARCHAR(100)) AS NUMERO_DOCUMENTO,
               CAST(ORDEN_CUN AS VARCHAR(100)) AS ORDEN_CUN,
               CAST(REFERENCIA_PAGO AS VARCHAR(100)) AS REFERENCIA_PAGO,
               FEC_CREACION, VALOR_AVAL, SERVICIO_MEDICO, VALOR_PAGADO, VALOR_MATRICULA,
               VALOR_FINANCIACION, GASTOS_TECNICOS, PORCENTAJE_INTERES,
               CAST(ESTADO_PAGO_ESTUDIO AS VARCHAR(50)) AS ESTADO_PAGO_ESTUDIO
        FROM ICEBERG.CLTIENE_360_ESTUDIANTES
        WHERE ESTADO_FINANCIACION = 1
    ')
),

-- ── CTE 2 : DEMOGRÁFICOS + CONDICIONES DEL CRÉDITO ────────────────────────────
-- Propósito: Traer los datos personales del estudiante y las condiciones pactadas del crédito.
-- Deduplicación: Un estudiante puede tener múltiples intentos/respuestas. Se usa ROW_NUMBER() 
-- ordenado por FEC_CREACION DESC para capturar únicamente la última respuesta válida (rn=1).
RESPUESTA AS (
    SELECT
        LTRIM(RTRIM(CAST(NUMERO_DOCUMENTO_ESTUDIANTE  AS NVARCHAR(100)))) AS NUMERO_DOCUMENTO_ESTUDIANTE,
        LTRIM(RTRIM(CAST(ORDEN_CUN                    AS NVARCHAR(100)))) AS ORDEN_CUN,
        CAST(NOMBRES_COMPLETOS_ESTUDIANTE AS NVARCHAR(500))               AS NOMBRES_COMPLETOS_ESTUDIANTE,
        CAST(TIPO_PROGRAMA_ESTUDIANTE     AS NVARCHAR(200))               AS TIPO_PROGRAMA_ESTUDIANTE,
        CAST(TIPO_DOCUMENTO_ESTUDIANTE    AS NVARCHAR(100))               AS TIPO_DOCUMENTO_ESTUDIANTE,
        CAST(GENERO_ESTUDIANTE            AS NVARCHAR(50))                AS GENERO_ESTUDIANTE,
        EDAD_ESTUDIANTE,
        TRY_CAST(VALOR_MATRICULA          AS DECIMAL(18,2))               AS VALOR_MATRICULA,
        TRY_CAST(VALOR_FINANCIACION       AS DECIMAL(18,2))               AS VALOR_FINANCIACION,
        TRY_CAST(VALOR_TOTAL_FINANCIACION AS DECIMAL(18,2))               AS VALOR_TOTAL_FINANCIACION,
        TRY_CAST(VALOR_CUOTA_INICIAL      AS DECIMAL(18,2))               AS VALOR_CUOTA_INICIAL,
        TRY_CAST(COSTO_PLATAFORMA         AS DECIMAL(18,2))               AS COSTO_PLATAFORMA,
        CUOTAS,
        TRY_CAST(VALOR_CUOTA              AS DECIMAL(18,2))               AS VALOR_CUOTA,
        FECHA_REGISTRO_ESTUDIANTE                                         AS FECHA_SOLICITUD_CREDITO,
        FEC_CREACION                                                      AS FECHA_APROBACION,
        ROW_NUMBER() OVER (PARTITION BY NUMERO_DOCUMENTO_ESTUDIANTE, ORDEN_CUN ORDER BY FEC_CREACION DESC) AS rn
    FROM OPENQUERY([172.16.1.175], '
        SELECT CAST(NUMERO_DOCUMENTO_ESTUDIANTE AS VARCHAR(100)) AS NUMERO_DOCUMENTO_ESTUDIANTE,
               CAST(ORDEN_CUN AS VARCHAR(100)) AS ORDEN_CUN, NOMBRES_COMPLETOS_ESTUDIANTE,
               TIPO_PROGRAMA_ESTUDIANTE, TIPO_DOCUMENTO_ESTUDIANTE, GENERO_ESTUDIANTE, EDAD_ESTUDIANTE,
               VALOR_MATRICULA, VALOR_FINANCIACION, VALOR_TOTAL_FINANCIACION, VALOR_CUOTA_INICIAL,
               COSTO_PLATAFORMA, CUOTAS, VALOR_CUOTA, FECHA_REGISTRO_ESTUDIANTE, FEC_CREACION
        FROM ICEBERG.CLTIENE_360_RESPUESTA
    ')
),

-- ── CTE 3 : DATOS CONTACTO Y ESTADO RPVI ──────────────────────────────────────
-- Propósito: Obtener datos de contacto actualizados (SINU) y el estado del Recibo de Pago (RPVI).
-- Riesgo mitigado: Alta probabilidad de duplicidad por múltiples órdenes previas. 
-- Solución: Se asigna 'rn=1' a la orden RPVI más reciente (FECHA_ORDEN DESC).
V2 AS (
    SELECT * FROM (
        SELECT
            LTRIM(RTRIM(CAST(IDENTIFICACION AS NVARCHAR(100)))) AS IDENTIFICACION,
            LTRIM(RTRIM(CAST(ORDEN_CUN      AS NVARCHAR(100)))) AS ORDEN_CUN,
            CAST(EMAIL_INSTITUCIONAL        AS NVARCHAR(255))  AS EMAIL_INSTITUCIONAL,
            CAST(EMAIL_PERSONAL             AS NVARCHAR(255))  AS EMAIL_PERSONAL,
            CAST(CELULAR                    AS NVARCHAR(50))   AS CELULAR,
            CAST(TELEFONO                   AS NVARCHAR(50))   AS TELEFONO,
            CAST(DOCUMENTO_RPVI             AS NVARCHAR(10))   AS DOCUMENTO_RPVI,
            CAST(ORDEN_RPVI                 AS NVARCHAR(100))  AS ORDEN_RPVI,
            CAST(DOCUMENTO_ORDEN_INI        AS NVARCHAR(10))   AS DOCUMENTO_ORDEN_INICIAL,
            CAST(ESTADO_ORDEN_RPVI          AS NVARCHAR(20))   AS ESTADO_ORDEN_RPVI,
            TRY_CAST(FECHA_ORDEN            AS DATETIME)       AS FECHA_ORDEN,
            TRY_CAST(FECHA_VENCIMIENTO      AS DATETIME)       AS FECHA_VENCIMIENTO_ORDEN,
            CAST(MENSAJE                    AS NVARCHAR(500))  AS MENSAJE,
            CAST(CENTRO_COSTO               AS NVARCHAR(50))   AS CENTRO_COSTO,
            TRY_CAST(VALOR_ORDEN_TOTAL      AS DECIMAL(18,2))  AS VALOR_ORDEN_TOTAL,
            CAST(DESCRIPCION                AS NVARCHAR(500))  AS DESCRIPCION,
            CAST(GRUPO                      AS NVARCHAR(50))   AS GRUPO,
            CAST(FONDO                      AS NVARCHAR(50))   AS FONDO,
            CAST(FUENTE_FUNCION             AS NVARCHAR(100))  AS FUENTE_FUNCION,
            TRY_CAST(FECHA_APROBACION_CUOTA_INI AS DATETIME)   AS FECHA_APROBACION_CUOTA_INI,
            TRY_CAST(FECHA_FIN_PROCESO      AS DATETIME)       AS FECHA_FIN_PROCESO_CLTIENE,
            TRY_CAST(VALOR_PAGADO_EN_ICEBERG    AS DECIMAL(18,2))  AS VALOR_PAGADO_EN_ICEBERG,
            CAST(TIENE_PROCESO_360          AS NVARCHAR(5))    AS TIENE_PROCESO_360,
            CAST(TIENE_PROCESO_LEGALIZADO       AS NVARCHAR(5))    AS TIENE_PROCESO_LEGALIZADO,
            CAST(ORDEN_RPVI_LIQUIDADA           AS NVARCHAR(5))    AS ORDEN_RPVI_LIQUIDADA,
            CAST(ORDEN_INICIAL_LIQUIDADA        AS NVARCHAR(5))    AS ORDEN_INICIAL_LIQUIDADA,
            CAST(OBSERVACION                    AS NVARCHAR(500))  AS OBSERVACION,
            ROW_NUMBER() OVER(PARTITION BY LTRIM(RTRIM(CAST(IDENTIFICACION AS NVARCHAR(100)))), LTRIM(RTRIM(CAST(ORDEN_CUN AS NVARCHAR(100)))) ORDER BY TRY_CAST(FECHA_ORDEN AS DATETIME) DESC) AS rn
        FROM OPENQUERY([172.16.1.175], '
            /* [QUERY OMITIDO EN COMENTARIOS PARA BREVEDAD - CRUZA TABLAS DE ICEBERG Y SINU] */
            SELECT CAST(B.NUM_IDENTIFICACION AS VARCHAR(100)) AS IDENTIFICACION,
                   B.DIR_EMAIL AS EMAIL_INSTITUCIONAL, B.DIR_EMAIL_PER AS EMAIL_PERSONAL,
                   B.TEL_CECULAR AS CELULAR, B.TEL_RESIDENCIA AS TELEFONO,
                   O.DOCUMENTO AS DOCUMENTO_RPVI, CAST(O.ORDEN AS VARCHAR(100)) AS ORDEN_RPVI,
                   T.DOCUMENTO AS DOCUMENTO_ORDEN_INI,
                   DECODE(ORD.ESTADO,''V'',''VIGENTE'',''A'',''ANULADA'',ORD.ESTADO) AS ESTADO_ORDEN_RPVI,
                   O.FECHA_ORDEN, O.FECHA_VENCIMIENTO, O.MENSAJE, O.CENTRO_COSTO,
                   O.VALOR_TOTAL AS VALOR_ORDEN_TOTAL, O.DESCRIPCION, O.GRUPO, O.FONDO, O.FUENTE_FUNCION,
                   C.FECHA_PAGO AS FECHA_APROBACION_CUOTA_INI, M.FEC_CREACION AS FECHA_FIN_PROCESO,
                   C.VALOR AS VALOR_PAGADO_EN_ICEBERG,
                   DECODE(E.NUMERO_DOCUMENTO,NULL,''NO'',''SI'') AS TIENE_PROCESO_360,
                   DECODE(M.ID,NULL,''NO'',''SI'') AS TIENE_PROCESO_LEGALIZADO,
                   DECODE(LR.LIQUIDACION,NULL,''NO'',''SI'') AS ORDEN_RPVI_LIQUIDADA,
                   DECODE(LM.LIQUIDACION,NULL,''NO'',''SI'') AS ORDEN_INICIAL_LIQUIDADA,
                   CASE WHEN E.NUMERO_DOCUMENTO IS NULL THEN '''' ELSE DECODE(E.ESTADO_FINANCIACION,1,''CREDITO COMPLETADO'',''CREDITO PENDIENTE CTAYUDA'') END AS OBSERVACION,
                   CAST(T.ORDEN AS VARCHAR(100)) AS ORDEN_CUN
            FROM ICEBERG.ORDEN O
              INNER JOIN SINU.BAS_TERCERO B ON B.NUM_IDENTIFICACION = TO_CHAR(O.CLIENTE_SOLICITADO)
              INNER JOIN SINU.BAS_CEN_COSTO CC ON CC.COD_CEN_COSTO = O.CENTRO_COSTO
              LEFT JOIN ICEBERG.CUNT_TRAMITE_EXTERNO T ON O.ORDEN = T.ORDEN_INICIAL
              LEFT JOIN ICEBERG.CREDITO R ON R.CLIENTE = B.NUM_IDENTIFICACION AND R.ORDEN = T.ORDEN AND OBSERVACIONES LIKE ''%CLTIENE%''
              LEFT JOIN ICEBERG.CLTIENE_360_ESTUDIANTES E ON E.NUMERO_DOCUMENTO = T.IDENTIFICACION AND E.ORDEN_CUN = T.ORDEN
              LEFT JOIN ICEBERG.CLTIENE_360_RESPUESTA M ON M.NUMERO_DOCUMENTO_ESTUDIANTE = E.NUMERO_DOCUMENTO AND M.ORDEN_CUN = E.ORDEN_CUN AND M.VALIDACION = 1
              LEFT JOIN PORTAL_PAGOS_CUN.PPT_CUN_DETALLE_RESPUESTA_PAGO D ON D.REFERENCIA = E.REFERENCIA_PAGO
              LEFT JOIN RECIBO_CAJA C ON C.NUMERO = D.RECIBO_ICEBERG AND C.ESTADO = ''V''
              LEFT JOIN ORDEN ORD ON ORD.ORDEN = T.ORDEN_INICIAL AND ORD.DOCUMENTO = T.DOCUMENTO_INICIAL
              LEFT JOIN LIQUIDACION_ORDEN LR ON LR.ORDEN = T.ORDEN_INICIAL AND LR.DOCUMENTO = T.DOCUMENTO_INICIAL
              LEFT JOIN LIQUIDACION_ORDEN LM ON LM.ORDEN = T.ORDEN AND LM.DOCUMENTO = T.DOCUMENTO
            WHERE O.DOCUMENTO = ''RPVI'' AND UPPER(O.DESCRIPCION) LIKE ''%CLTIENE%'' AND O.ESTADO = ''V''
        ')
    ) AS V2_DEDUP
    WHERE rn = 1
),

-- ── CTE 4 : DETALLE DE CUOTA ──────────────────────────────────────────────────
-- Propósito: Extraer el valor individual de la cuota.
-- Deduplicación: Se usa MAX() agrupado por ORDEN_CUN para asegurar un único valor numérico, 
-- evitando que el desglose de cuotas múltiples (ej. 3 cuotas) triplique el registro del estudiante.
CUOTAS AS (
    SELECT
        LTRIM(RTRIM(CAST(ORDEN_CUN AS NVARCHAR(100)))) AS ORDEN_CUN,
        MAX(TRY_CAST(VALOR_CUOTA AS DECIMAL(18,2)))    AS VALOR_CUOTA_detalle
    FROM OPENQUERY([172.16.1.175], '
        SELECT CAST(ORDEN_CUN AS VARCHAR(100)) AS ORDEN_CUN,
               CAST(VALOR_CUOTA AS VARCHAR(100)) AS VALOR_CUOTA
        FROM ICEBERG.CLTIENE_360_DETALLE_CUOTAS
    ')
    GROUP BY LTRIM(RTRIM(CAST(ORDEN_CUN AS NVARCHAR(100))))
),

-- ── CTE 5 : MAPA DE RIESGO / CARTERA TOTAL ────────────────────────────────────
-- Propósito: Traer los saldos adeudados y su clasificación por días de mora (Aging).
-- Riesgo mitigado: Un estudiante puede tener múltiples deudas NDB en un mismo periodo.
-- Solución: ROW_NUMBER() aísla la obligación más reciente (FECHA_VENCIMIENTO DESC) 
-- para no inflar la mora total en el dashboard.
CARTERA AS (
    SELECT * FROM (
        SELECT
            LTRIM(RTRIM(CAST(IDENTIFICACION AS NVARCHAR(100)))) AS IDENTIFICACION_CT, 
            CAST(PERIODO AS NVARCHAR(50))                  AS PERIODO_CT,
            FECHA_VENCIMIENTO,
            TRY_CAST(VALOR_ORIGINAL AS DECIMAL(18,2)) AS CT_VALOR_ORIGINAL,
            TRY_CAST(CORRIENTE      AS DECIMAL(18,2)) AS CT_CORRIENTE,
            TRY_CAST(GR1A30         AS DECIMAL(18,2)) AS CT_GR1A30,
            TRY_CAST(GR31A60        AS DECIMAL(18,2)) AS CT_GR31A60,
            TRY_CAST(GR61A90        AS DECIMAL(18,2)) AS CT_GR61A90,
            TRY_CAST(GR91A120       AS DECIMAL(18,2)) AS CT_GR91A120,
            TRY_CAST(GR121A150      AS DECIMAL(18,2)) AS CT_GR121A150,
            TRY_CAST(GR151A360      AS DECIMAL(18,2)) AS CT_GR151A360,
            TRY_CAST(GR360MAS       AS DECIMAL(18,2)) AS CT_GR360MAS,
            TRY_CAST(TOTAL          AS DECIMAL(18,2)) AS CT_TOTAL,
            ESTADO_ALUMNO                             AS CT_ESTADO_ALUMNO,
            NOM_UNIDAD                                AS CT_NOM_UNIDAD,
            NOM_SECCIONAL                             AS CT_NOM_SECCIONAL,
            MODALIDAD                                 AS CT_MODALIDAD,
            ESTADO                                    AS CT_ESTADO,
            MARCA_ACADEMICA                           AS CT_MARCA_ACADEMICA,
            ROW_NUMBER() OVER(PARTITION BY LTRIM(RTRIM(CAST(IDENTIFICACION AS NVARCHAR(100)))), CAST(PERIODO AS NVARCHAR(50)) ORDER BY FECHA_VENCIMIENTO DESC) as rn
        FROM CUN_REPOSITORIO.Financiera.Cartera_Total
        WHERE DOCUMENTO = 'NDB'
          AND (PERIODO LIKE '%25%' OR PERIODO LIKE '%26%')
    ) AS CT_DEDUP
    WHERE rn = 1
),

-- ── CTE 6 : PERFIL ACADÉMICO / COMERCIAL (ZOHO) ───────────────────────────────
-- Propósito: Agregar dimensiones de análisis (Programa, Sede, Modalidad, Lat/Lon).
-- Deduplicación: Previene duplicados históricos en el CRM tomando solo la matrícula más actual (rn=1).
BASE_PERSONAS_CLN AS (
    SELECT * FROM (
        SELECT 
            LTRIM(RTRIM(CAST(ORDEN AS NVARCHAR(100))))    AS ORDEN_BP,
            LTRIM(RTRIM(CAST(DOC_ALUM AS NVARCHAR(100)))) AS DOC_ALUM_BP,
            NOM_PROGRAMA, MODALIDAD, SECCIONAL, ESTADO_PAGO, CAST(Periodo_data AS NVARCHAR(50)) AS Periodo_data,
            Fuerza_comercial_data, EST_MATRICULADO, TIPO_ALUM_DATA, NUEVO,
            lat, lon, ciudad, departamento, localidad,
            ROW_NUMBER() OVER(PARTITION BY LTRIM(RTRIM(CAST(ORDEN AS NVARCHAR(100)))), LTRIM(RTRIM(CAST(DOC_ALUM AS NVARCHAR(100)))) ORDER BY CAST(Periodo_data AS NVARCHAR(50)) DESC) as rn
        FROM CUN_REPOSITORIO.zoho.Base_Personas
    ) AS BP_DEDUP
    WHERE rn = 1
),

-- ── CTE 7 : RECAUDO EFECTIVO (RECIBOS DE CAJA) ────────────────────────────────
-- Propósito: Calcular el dinero real ingresado a caja por estudiante/periodo.
-- Pre-Agregación: Se agrupan (SUM) todos los recibos de un estudiante en el periodo, garantizando
-- un único registro (1:1) antes de cruzarlo con el driver. Esencial para calcular el % de Recaudo.
RECIBOS_AGRUPADOS AS (
    SELECT 
        LTRIM(RTRIM(CAST(CLIENTE AS NVARCHAR(100)))) AS CLIENTE_RC,
        CAST(PERIODO AS NVARCHAR(50))                AS PERIODO_RC,
        SUM(TRY_CAST(Valor AS DECIMAL(18,2)))        AS PAGOS_REALIZADOS
    FROM CUN_REPOSITORIO.Financiera.RECIBOS_CAJA
    GROUP BY 
        LTRIM(RTRIM(CAST(CLIENTE AS NVARCHAR(100)))),
        CAST(PERIODO AS NVARCHAR(50))
)

-- =============================================================================
-- QUERY PRINCIPAL / ENSAMBLE FINAL
-- =============================================================================
SELECT
    -- 📊 BLOQUE 1: DATOS DEMOGRÁFICOS Y DE CONTACTO
    R.NOMBRES_COMPLETOS_ESTUDIANTE,
    R.TIPO_PROGRAMA_ESTUDIANTE,
    R.TIPO_DOCUMENTO_ESTUDIANTE,
    R.GENERO_ESTUDIANTE,
    R.EDAD_ESTUDIANTE,
    V2.EMAIL_INSTITUCIONAL, 
    V2.EMAIL_PERSONAL, 
    V2.CELULAR, 
    V2.TELEFONO,

    -- 🔑 BLOQUE 2: LLAVES DE IDENTIFICACIÓN Y TRAZABILIDAD
    E.NUMERO_DOCUMENTO AS NUMERO_DOCUMENTO_ESTUDIANTE,
    E.ORDEN_CUN,
    E.REFERENCIA_PAGO,
    V2.DOCUMENTO_RPVI, 
    V2.ORDEN_RPVI, 
    V2.DOCUMENTO_ORDEN_INICIAL,

    -- 💰 BLOQUE 3: ESTRUCTURA DE LA FINANCIACIÓN (CTAYUDA)
    -- Lógica: Si el valor de matrícula llega en 0 o Nulo, se recalcula sumando Total Financiado + Cuota Inicial.
    CASE
        WHEN ISNULL(R.VALOR_MATRICULA, 0) = 0
        THEN ISNULL(R.VALOR_TOTAL_FINANCIACION, 0) + ISNULL(R.VALOR_CUOTA_INICIAL, 0)
        ELSE R.VALOR_MATRICULA
    END AS VALOR_MATRICULA,
    R.VALOR_FINANCIACION,
    R.VALOR_TOTAL_FINANCIACION,
    R.VALOR_CUOTA_INICIAL,
    R.COSTO_PLATAFORMA,
    R.CUOTAS,
    R.VALOR_CUOTA,
    CD.VALOR_CUOTA_detalle,

    -- 📅 BLOQUE 4: HITOS DE TIEMPO (FECHAS CLAVE)
    -- Incluye estandarización de Años y Meses en texto para facilitar filtros en Dashboards.
    R.FECHA_SOLICITUD_CREDITO,
    R.FECHA_APROBACION,
    YEAR(R.FECHA_APROBACION) AS [AÑO_APROBACION],
    CASE MONTH(R.FECHA_APROBACION)
        WHEN 1  THEN 'Enero'       WHEN 2  THEN 'Febrero'
        WHEN 3  THEN 'Marzo'       WHEN 4  THEN 'Abril'
        WHEN 5  THEN 'Mayo'        WHEN 6  THEN 'Junio'
        WHEN 7  THEN 'Julio'       WHEN 8  THEN 'Agosto'
        WHEN 9  THEN 'Septiembre'  WHEN 10 THEN 'Octubre'
        WHEN 11 THEN 'Noviembre'   WHEN 12 THEN 'Diciembre'
    END AS MES_APROBACION,
    DAY(R.FECHA_APROBACION) AS DIA_APROBACION,
    V2.FECHA_ORDEN, 
    V2.FECHA_VENCIMIENTO_ORDEN,
    V2.FECHA_APROBACION_CUOTA_INI,
    E.FECHA_CREA_ESTUDIANTE_CLTIENE,
    V2.FECHA_FIN_PROCESO_CLTIENE,

    -- 🎓 BLOQUE 5: CONTEXTO ACADÉMICO / COMERCIAL (ZOHO)
    -- Lógica: Se normaliza la ortografía del programa "Administración de Empresas" para evitar fragmentación.
    CASE
        WHEN UPPER(BP.NOM_PROGRAMA) IN ('ADMINISTRACION DE EMPRESAS', 'ADMINISTRACIÓN DE EMPRESAS')
        THEN 'ADMINISTRACIÓN DE EMPRESAS'
        ELSE BP.NOM_PROGRAMA
    END AS PROGRAMA,
    BP.MODALIDAD,
    BP.SECCIONAL AS REGIONAL,
    BP.ESTADO_PAGO,
    BP.Periodo_data AS PERIODO,
    BP.Fuerza_comercial_data AS FUERZA_COMERCIAL,
    BP.EST_MATRICULADO,
    BP.TIPO_ALUM_DATA AS TIPO,
    BP.NUEVO,

    -- 🗺️ BLOQUE 6: GEOLOCALIZACIÓN
    BP.lat,
    BP.lon,
    BP.ciudad AS ciudad_geo,
    BP.departamento,
    BP.localidad,

    -- 💵 BLOQUE 7: COMPORTAMIENTO FINANCIERO Y MORA (CARTERA + RECAUDO)
    RC.PAGOS_REALIZADOS,  -- Valor real ingresado (Agrupado de RECIBOS_CAJA)
    CT.CT_VALOR_ORIGINAL, 
    CT.CT_CORRIENTE, 
    CT.CT_GR1A30, 
    CT.CT_GR31A60,
    CT.CT_GR61A90, 
    CT.CT_GR91A120, 
    CT.CT_GR121A150, 
    CT.CT_GR151A360,
    CT.CT_GR360MAS, 
    CT.CT_TOTAL, 
    CT.FECHA_VENCIMIENTO AS CT_FECHA_VENCIMIENTO,
    CT.CT_ESTADO_ALUMNO, 
    CT.CT_NOM_UNIDAD, 
    CT.CT_NOM_SECCIONAL,
    CT.CT_MODALIDAD, 
    CT.CT_ESTADO, 
    CT.CT_MARCA_ACADEMICA,

    -- 🛠️ BLOQUE 8: CONTROL OPERATIVO E INDICADORES ICEBERG
    E.VALOR_AVAL, 
    E.SERVICIO_MEDICO, 
    E.VALOR_PAGADO,
    E.VALOR_ORDEN, 
    E.VALOR_FINANCIADO, 
    V2.VALOR_PAGADO_EN_ICEBERG,
    E.GASTOS_TECNICOS, 
    E.PORCENTAJE_INTERES, 
    E.ESTADO_PAGO_ESTUDIO,
    V2.ESTADO_ORDEN_RPVI, 
    V2.MENSAJE, 
    V2.CENTRO_COSTO, 
    V2.VALOR_ORDEN_TOTAL, 
    V2.DESCRIPCION,
    V2.GRUPO, 
    V2.FONDO, 
    V2.FUENTE_FUNCION,
    V2.TIENE_PROCESO_360, 
    V2.TIENE_PROCESO_LEGALIZADO,
    V2.ORDEN_RPVI_LIQUIDADA, 
    V2.ORDEN_INICIAL_LIQUIDADA, 
    V2.OBSERVACION

-- ── UNIÓN DE MODELOS (JOIN OBLIGATORIAMENTE 1:1) ───────────────────────────────
FROM ESTUDIANTES E

-- Cruce por Identificación + Orden
LEFT JOIN RESPUESTA R
    ON  E.NUMERO_DOCUMENTO = R.NUMERO_DOCUMENTO_ESTUDIANTE
    AND E.ORDEN_CUN        = R.ORDEN_CUN

-- Cruce por Orden + Documento Académico
LEFT JOIN BASE_PERSONAS_CLN BP
    ON  E.ORDEN_CUN = BP.ORDEN_BP
    AND E.NUMERO_DOCUMENTO = BP.DOC_ALUM_BP

-- Cruce por Identificación + Orden RPVI
LEFT JOIN V2
    ON  E.ORDEN_CUN        = V2.ORDEN_CUN
    AND E.NUMERO_DOCUMENTO = V2.IDENTIFICACION

-- Cruce por Orden para detalle unitario
LEFT JOIN CUOTAS CD
    ON  E.ORDEN_CUN = CD.ORDEN_CUN

-- Cruce SARGable: Identificación + Periodo (Asegura correcta atribución de pagos reales)
LEFT JOIN RECIBOS_AGRUPADOS RC
    ON  E.NUMERO_DOCUMENTO = RC.CLIENTE_RC
    AND BP.Periodo_data    = RC.PERIODO_RC

-- Cruce SARGable: Identificación + Periodo (Asegura no duplicar deuda NDB)
LEFT JOIN CARTERA CT
    ON  E.NUMERO_DOCUMENTO = CT.IDENTIFICACION_CT
    AND BP.Periodo_data    = CT.PERIODO_CT;