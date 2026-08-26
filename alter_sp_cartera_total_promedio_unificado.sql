
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
--   · [172.16.1.175] (Linked Server Oracle) — ICEBERG.cartera_corporativa
--   · [CUN_REPOSITORIO].[ZOHO].[BASE_PERSONAS]          : datos CRM Zoho por periodo
--   · [CUN_REPOSITORIO].[CUN].[ESTADISTICA_ESTUDIANTE_2]: estadística académica deduplicada
--   · [CUN_REPOSITORIO].[CUN].[ESTADISTICA_ACADEMICA]   : fallback académico por semestre
--   · [CUN_STAGE].[moodle].[repli_mdl_user]             : último acceso a Moodle (lastaccess epoch UNIX → datetime)
--   · [172.16.1.175] SINU.SRC_HIS_ACADEMICA + SRC_ALUM_PERIODO : PRO_ACUMULADO vía OPENQUERY (llave: solo identificación)
--   · [CUN_REPOSITORIO].[Dbo].[Periodos_Calendario]     : fechas inicio/fin de cada periodo
--
-- ──────────────────────────────────────────────────────────────────────────────────────────────────
--  BITÁCORA DE CAMBIOS
-- ──────────────────────────────────────────────────────────────────────────────────────────────────
--  2026-04-27 │ ADD: Columna AUD_FECHA_PROCESAMIENTO (DATETIME NOT NULL) en las 4 tablas
--             │      de salida para trazabilidad de carga y auditoría operacional.
--             │ ADD: Documentación técnica completa del procedimiento.
--  2026-07-06 │ CHG: Cartera_Gestion — se reemplazan las fuentes de Moodle y promedio por
--             │      las de USP_Foto_Meta_Comercial_Mensual (dato vivo, refresco por corrida):
--             │        · ultimoaccesoplataformlimpio ← CUN_STAGE.moodle.repli_mdl_user
--             │          (username=IDENTIFICACION, lastaccess epoch → DATETIME).
--             │        · PROMEDIO ← OPENQUERY SRC_ALUM_PERIODO.PRO_ACUMULADO (solo identificación)
--             │          (ESTADO_PAGO='PAGO', por COD_PERIODO+NUM_IDENTIFICACION).
--             │      Se conservan los nombres de columna para no romper reportes.
--  2026-07-06 │ CHG: Creditos_pagos_CTAYUDA — renombrado de columnas:
--             │        · IDENTIFICACION → NUMERO_DOCUMENTO
--             │        · TOTAL          → TOTAL_PAGADO
--             │      Ajustados: CREATE TABLE, migración idempotente (dirección invertida),
--             │      índice IX_..._FECHA_DETECCION (INCLUDE) e INSERT del PASO 5.
--             │      Cartera_Gestion CONSERVA IDENTIFICACION/TOTAL; el INSERT mapea
--             │      Ayer.IDENTIFICACION → NUMERO_DOCUMENTO y Ayer.TOTAL → TOTAL_PAGADO.
--  2026-07-15 │ ADD: PASO 4.1 — Marca de notas débito cargadas a destiempo para Zoho CRM.
--             │      · Cartera_Gestion: columnas MARCA_CARGA_DESTIEMPO (bit) y
--             │        FECHA_REAL_CARGA_NDB (varchar(10), dd/MM/yyyy).
--             │      · NDB nueva = no estaba en Cartera_Foto_Ayer (llave IDENTIFICACION+
--             │        PERIODO+NUMERO_CREDITO) y FECHA nominal < día de ejecución.
--             │        Marcados: FECHA_REAL_CARGA_NDB = día anterior a la ejecución.
--             │      · ADD: Financiera.Cartera_Destiempo_ZOHO (bitácora persistente, copia
--             │        completa de las filas marcadas + FECHA_DETECCION, append diario).
--  2026-07-27 │ ADD: Columna FECHA_ELABORACION (varchar(10), dd/MM/yyyy) — ya venía en la
--             │      fuente Oracle ICEBERG y llegaba a Financiera.Cartera (staging) vía SELECT *,
--             │      pero las listas explícitas de salida la descartaban. Ahora se propaga a
--             │      Cartera_Total, Cartera_Gestion, Creditos_pagos_CTAYUDA y Cartera_Destiempo_ZOHO.
--             │      Cartera_Foto_Ayer la hereda automáticamente (SELECT * de Cartera_Gestion).
--             │      Cartera_Destiempo_ZOHO se auto-repara: como su INSERT ... SELECT H.* es
--             │      posicional, se reconstruye una vez preservando su histórico (13.7k filas)
--             │      para realinear el esquema (ver bloque PASO 4.1 (3.0)).
--  2026-07-27 │ CHG: Fuente Oracle del PASO 1 — ICEBERG.VM_CARTERA_CORPORATIVA (vista) →
--             │      ICEBERG.cartera_corporativa (tabla base). Esquema idéntico (42 columnas,
--             │      mismos nombres/orden/tipos); la tabla trae ~9 NDB adicionales del universo
--             │      activo (+~$3,2 M en SUM(TOTAL) de períodos 22–26).
--  2026-07-28 │ ADD: Guarda anti-fuente-vacía tras el PASO 1 — aborta con error real si la
--             │      extracción NDB (22–26) < 200.000, evitando materializar cartera parcial
--             │      cuando la tabla Oracle está a medio recargar. FIX: la validación final se
--             │      omite si @hubo_error=1 (ya no registra un OK engañoso sobre tablas
--             │      revertidas). Motivado por incidente 2026-07-28 (job 6am cargó 0 filas →
--             │      245k falsos pagos en CTAYUDA y 245k falsos destiempo; recuperado con backup-27).
--  2026-07-31 │ ADD: Columna ESTADO (ACTIVO / NO ACTIVO / PERIODO NO HA INICIADO) replicada a
--             │      TODAS las tablas materializadas: Cartera_Gestion (desde Cartera_Total vía
--             │      Cartera_Total_Dedup), Creditos_pagos_CTAYUDA (CREATE + guard idempotente +
--             │      INSERT/SELECT), Cartera_Foto_Ayer (SELECT * + guard de transición) y
--             │      Cartera_Destiempo_ZOHO (H.* tras auto-sanado). CHG: el auto-sanado de
--             │      Cartera_Destiempo_ZOHO (PASO 4.1 (3.0)) ahora es GENÉRICO: detecta cualquier
--             │      columna de Cartera_Gestion ausente en la bitácora (antes solo FECHA_ELABORACION).
--  2026-08-24 │ ADD: PASO 1.5 — EMAIL y WHATSAPP se toman de Financiera.Datos_contacto_estudiantes
--             │      (DIR_EMAIL_PER y TEL_CECULAR). Se aplica como UPDATE sobre el staging
--             │      Financiera.Cartera, es decir ANTES de Cartera_Total / Cartera_Gestion, para que
--             │      todas las tablas aguas abajo hereden el mismo dato sin tocar sus SELECT.
--             │      Regla: manda el dato de Datos_contacto_estudiantes; si viene NULL o vacío se
--             │      conserva el de origen (Oracle). Los nombres EMAIL y WHATSAPP NO cambian, para
--             │      no romper los enlaces con las demás tablas ni con el CRM.
--             │      WHATSAPP además se VALIDA como celular colombiano (10 dígitos empezando por 3);
--             │      lo que no cumple queda en NULL. Antes de validar se quitan separadores de
--             │      digitación y se recorta el indicativo 57 — mismo criterio que ya usa
--             │      Usp_Datos_Contacto_Estudiantes sobre este dato, para no tener dos reglas
--             │      distintas para el mismo teléfono. La validación cubre TODAS las filas de la
--             │      cartera (LEFT JOIN), no solo las que cruzan con Datos_contacto_estudiantes.
--             │      ADD: PASO 5.1 — mismo tratamiento sobre Financiera.Creditos_pagos_CTAYUDA, que
--             │      es ACUMULATIVA: sus filas históricas no se reconstruyen y se quedarían con el
--             │      contacto viejo. Corre después del INSERT del PASO 5, así corrige de una vez el
--             │      histórico y las filas recién insertadas desde la foto de ayer.
--             │      OJO semántico: el EMAIL de origen es el institucional (@cun.edu.co, 293.660
--             │      filas) y DIR_EMAIL_PER es el personal (gmail/hotmail). Tras este cambio el
--             │      91% de los correos de la cartera pasa de institucional a personal. Es el
--             │      objetivo (contactar al correo que el estudiante sí revisa), no un efecto
--             │      colateral.
--
-- ██████████████████████████████████████████████████████████████████████████████████████████████████
-- ====================================================================================================

CREATE   PROCEDURE [Financiera].[SP_Cartera_Total]
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
    DECLARE @hubo_error    BIT = 0
    DECLARE @filas_ndb_src INT

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

            -- Snapshot COMPLETO: la foto conserva todas las columnas para que
            -- Creditos_pagos_CTAYUDA pueda heredar el esquema de Cartera_Gestion.
            SELECT *
            INTO Financiera.Cartera_Foto_Ayer
            FROM Financiera.Cartera_Gestion
            WHERE DOCUMENTO = 'NDB';

            -- Transición de esquema: en la primera corrida tras agregar una columna nueva a
            -- Cartera_Gestion (aquí FECHA_ELABORACION), la foto proviene del Cartera_Gestion
            -- ANTERIOR (sin la columna). El INSERT de CTAYUDA (PASO 5) referencia
            -- Ayer.FECHA_ELABORACION, por lo que la columna debe existir en la foto o falla
            -- con error 207. Se agrega idempotente (NULL para ese lote); en corridas siguientes
            -- la foto ya la trae y este ALTER es no-op.
            IF COL_LENGTH('Financiera.Cartera_Foto_Ayer','FECHA_ELABORACION') IS NULL
                ALTER TABLE Financiera.Cartera_Foto_Ayer ADD FECHA_ELABORACION varchar(10) NULL;
            IF COL_LENGTH('Financiera.Cartera_Foto_Ayer','ESTADO') IS NULL
                ALTER TABLE Financiera.Cartera_Foto_Ayer ADD ESTADO varchar(50) NULL;
        END


        -- ==========================================================================================
        -- PASO 1 │ EXTRACCIÓN CARTERA BRUTA DESDE ORACLE ICEBERG
        -- ==========================================================================================
        -- Recarga completa de la cartera corporativa desde la tabla base en Oracle.
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
                 FROM ICEBERG.cartera_corporativa')

        -- ------------------------------------------------------------------------------------------
        -- GUARDA ANTI-FUENTE-VACÍA (crítica)
        -- ------------------------------------------------------------------------------------------
        -- ICEBERG.cartera_corporativa es una TABLA BASE que se recarga/trunca durante el día en
        -- Oracle. Si el SP corre justo en esa ventana, la extracción trae 0 o un volumen parcial,
        -- la auditoría interna (Cartera_Total vs Cartera_Gestion) igual da $0 (ambas del mismo
        -- staging) y el proceso registraría estado=OK con cartera vacía, contaminando además
        -- Creditos_pagos_CTAYUDA (anti-join marca TODO como pagado) y Cartera_Destiempo_ZOHO
        -- (marca TODO como destiempo). Para evitarlo se aborta con error real si el volumen NDB
        -- del universo activo (períodos 22–26) cae por debajo del umbral esperado (~245k).
        -- ⚠ Ajustar el umbral si el volumen base del negocio cambia estructuralmente.
        -- ------------------------------------------------------------------------------------------
        SELECT @filas_ndb_src = COUNT(*)
        FROM Financiera.Cartera
        WHERE DOCUMENTO = 'NDB'
          AND (PERIODO LIKE '%22%' OR PERIODO LIKE '%23%' OR
               PERIODO LIKE '%24%' OR PERIODO LIKE '%25%' OR PERIODO LIKE '%26%');

        IF @filas_ndb_src < 200000
            RAISERROR('ABORTO: extraccion Oracle anomala (NDB 22-26 = %d, umbral 200000). Posible recarga en curso de ICEBERG.cartera_corporativa. No se materializa la cartera.',
                      16, 1, @filas_ndb_src);


        -- ==========================================================================================
        -- PASO 1.5 │ CONTACTO VIVO — EMAIL y WHATSAPP desde Datos_contacto_estudiantes
        -- ==========================================================================================
        -- Por qué aquí y no en cada SELECT de más abajo: Financiera.Cartera es el staging del que
        -- cuelgan Cartera_Total (PASO 3), Cartera_Gestion (PASO 4), Cartera_Destiempo_ZOHO (PASO 4.1)
        -- y Creditos_pagos_CTAYUDA (PASO 5). Corrigiendo el staging, TODAS heredan el mismo dato sin
        -- tocar sus listas de columnas y sin renombrar nada: EMAIL y WHATSAPP siguen llamándose
        -- igual, así que los enlaces con las demás tablas y con el CRM quedan intactos.
        --
        -- Regla de contacto: manda Datos_contacto_estudiantes; si el campo viene NULL (o vacío, que
        -- para efectos de contacto es lo mismo) se conserva el valor de origen de Oracle.
        --   EMAIL    <- DIR_EMAIL_PER
        --   WHATSAPP <- TEL_CECULAR
        -- El COALESCE es por campo, así que una misma fila puede tomar el correo de una fuente y el
        -- celular de la otra (4.394 filas al 2026-08-24).
        --
        -- Regla adicional de WHATSAPP: debe ser un celular colombiano — 10 dígitos empezando por 3.
        -- Lo que no cumple queda en NULL, no se arrastra basura al CRM. Antes de validar:
        --   · se quitan separadores de digitación (espacios, guiones, paréntesis, puntos, +, tab);
        --   · se recorta el indicativo 57 cuando el número viene como 573XXXXXXXXX.
        -- Ese es el MISMO criterio que Usp_Datos_Contacto_Estudiantes ya aplica sobre este dato
        -- (allá con REGEXP_LIKE '^3[0-9]{9}$' del lado Oracle); se replica aquí en T-SQL puro para
        -- no dejar dos reglas distintas para el mismo teléfono.
        -- Medido 2026-08-24 sobre el origen Oracle: 273.245 cumplen tal cual, 278 se recuperan al
        -- quitar separadores, 20.621 al recortar el 57, y solo 1.089 son basura real ('0', '1',
        -- '3078180') que pasa a NULL. Del lado Datos_contacto_estudiantes no hay inválidos: sus
        -- 479.925 celulares poblados ya cumplen la regla.
        --
        -- LEFT JOIN, no INNER: la validación de WHATSAPP debe alcanzar TODAS las filas de la
        -- cartera, incluidas las 22.495 que no cruzan con Datos_contacto_estudiantes. En esas, el
        -- COALESCE del correo se queda con el valor de origen (COALESCE(NULL, A.EMAIL) = A.EMAIL),
        -- que es justo lo que se quiere.
        --
        -- Grano: Datos_contacto_estudiantes es única por NUM_IDENTIFICACION (656.187 filas =
        -- 656.187 identificaciones, verificado 2026-08-24), así que este UPDATE ... FROM no puede
        -- caer en la trampa de "varias filas candidatas y SQL Server elige una en silencio".
        -- Si algún día esa tabla deja de ser única por identificación, hay que deduplicarla ANTES.
        --
        -- Longitudes: DIR_EMAIL_PER mide máximo 71 caracteres contra EMAIL varchar(80), y el celular
        -- validado siempre mide 10 contra WHATSAPP varchar(20). Sin riesgo de truncamiento (8152).
        -- ==========================================================================================
        UPDATE A
           SET A.EMAIL    = COALESCE(NULLIF(LTRIM(RTRIM(D.DIR_EMAIL_PER)), ''), A.EMAIL),
               A.WHATSAPP = w.WA
        FROM Financiera.Cartera A
        LEFT JOIN Financiera.Datos_contacto_estudiantes D
               ON LTRIM(RTRIM(D.NUM_IDENTIFICACION)) = LTRIM(RTRIM(A.IDENTIFICACION))
        CROSS APPLY (SELECT
                N_DCE = REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                            ISNULL(D.TEL_CECULAR, ''), ' ',''), '-',''), '(',''), ')',''), '.',''), '+',''), CHAR(9),''),
                N_ORI = REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                            ISNULL(A.WHATSAPP, ''), ' ',''), '-',''), '(',''), ')',''), '.',''), '+',''), CHAR(9),'')) n
        CROSS APPLY (SELECT
                C_DCE = CASE WHEN LEN(n.N_DCE) = 12 AND LEFT(n.N_DCE, 3) = '573'
                             THEN RIGHT(n.N_DCE, 10) ELSE n.N_DCE END,
                C_ORI = CASE WHEN LEN(n.N_ORI) = 12 AND LEFT(n.N_ORI, 3) = '573'
                             THEN RIGHT(n.N_ORI, 10) ELSE n.N_ORI END) c
        CROSS APPLY (SELECT WA = COALESCE(
                CASE WHEN LEN(c.C_DCE) = 10 AND LEFT(c.C_DCE, 1) = '3'
                      AND c.C_DCE NOT LIKE '%[^0-9]%' THEN c.C_DCE END,
                CASE WHEN LEN(c.C_ORI) = 10 AND LEFT(c.C_ORI, 1) = '3'
                      AND c.C_ORI NOT LIKE '%[^0-9]%' THEN c.C_ORI END)) w;


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

        -- ─────────────────────────────────────────────────────────────────────────────────────────
        -- #MOODLE (movido aquí): último acceso a Moodle por IDENTIFICACION.
        --   Se construye ANTES de Cartera_Total porque MARCA_ACADEMICA lo usa como último fallback
        --   (acceso reciente ⇒ el alumno sigue estudiando aunque no tenga nota cargada).
        --   Persiste en tempdb todo el batch y se reutiliza en Cartera_Gestion (no se reconstruye).
        --   lastaccess = 0 en Moodle = "nunca ingresó": NULLIF evita convertirlo en 1970-01-01.
        -- ─────────────────────────────────────────────────────────────────────────────────────────
        IF OBJECT_ID('tempdb..#MOODLE') IS NOT NULL DROP TABLE #MOODLE;
        SELECT id_k, Ultimo_acceso_moodle
        INTO #MOODLE
        FROM (
            SELECT LTRIM(RTRIM(username)) AS id_k,
                   DATEADD(SECOND, NULLIF(lastaccess, 0), '1970-01-01') AS Ultimo_acceso_moodle,
                   ROW_NUMBER() OVER (PARTITION BY LTRIM(RTRIM(username)) ORDER BY lastaccess DESC) AS rn
            FROM CUN_STAGE.moodle.repli_mdl_user
        ) z WHERE rn = 1;
        CREATE CLUSTERED INDEX IX_moodle ON #MOODLE(id_k);

        -- ─────────────────────────────────────────────────────────────────────────────────────────
        -- #PROM (movido aquí desde el PASO 4): PROMEDIO ACUMULADO por IDENTIFICACION.
        --   Fuente única aprobada por Coordinación de Cartera (2026-08-26):
        --   SINU.SRC_HIS_ACADEMICA + SRC_ALUM_PERIODO, campo PRO_ACUMULADO.
        --
        --   Reemplaza a sinu.V_DEMOGRAFICO_ESTUDIANTE_VIG, que filtraba ESTADO_PAGO='PAGO' y
        --   solo cubría el 42,78% de las obligaciones. La fuente nueva cubre 81,03%.
        --   Se construye AQUÍ (antes de Cartera_Total) porque MARCA_ACADEMICA ahora lo consume:
        --   antes la marca usaba COALESCE(B.PROMEDIO, E.PROMEDIO) — un promedio DISTINTO del que
        --   la tabla mostraba — y eso producía filas GESTIONABLE con la columna PROMEDIO vacía.
        --
        --   ⚠ La llave es SOLO IDENTIFICACION, sin PERIODO. PRO_ACUMULADO es el promedio
        --     acumulado del estudiante, no la nota de un periodo: una obligación de 2022 queda
        --     evaluada con el acumulado vigente. Es la regla que definió Cartera, no un descuido.
        --
        --   Desempate (5,3 filas por estudiante en promedio):
        --     1) semestre (NUM_NIV_CURSA) más avanzado = el acumulado más completo;
        --     2) fec_inicio real del periodo (Periodos_Calendario), porque el 47% empata en
        --        semestre y COD_PERIODO NO es ordenable: sus 2 últimos caracteres son la
        --        iteración de la modalidad, no el periodo del año (26I17 es ANTERIOR a 26V05),
        --        y el 45% de las filas ni siquiera los tiene numéricos (26PI3, 2026C, 017E1);
        --     3) PRO_ACUMULADO desc como último recurso, para que el resultado sea determinista.
        -- ─────────────────────────────────────────────────────────────────────────────────────────
        IF OBJECT_ID('tempdb..#PROM') IS NOT NULL DROP TABLE #PROM;
        SELECT id_k, PROMEDIO
        INTO #PROM
        FROM (
            SELECT LTRIM(RTRIM(SRC.num_identificacion))              AS id_k,
                   TRY_CAST(SRC.PRO_ACUMULADO AS DECIMAL(9,4))       AS PROMEDIO,
                   ROW_NUMBER() OVER (
                        PARTITION BY LTRIM(RTRIM(SRC.num_identificacion))
                        ORDER BY TRY_CAST(SRC.semestre AS INT)             DESC,
                                 CAL.fec_inicio                            DESC,
                                 TRY_CAST(SRC.PRO_ACUMULADO AS DECIMAL(9,4)) DESC
                   ) AS rn
            FROM OPENQUERY([172.16.1.175],
                'select DISTINCT C.num_identificacion, A.COD_PERIODO,
                        AP.PRO_ACUMULADO, AP.NUM_NIV_CURSA as semestre
                 from SINU.SRC_HIS_ACADEMICA A
                 INNER JOIN sinu.SRC_ALUM_PROGRAMA B ON A.ID_ALUM_PROGRAMA = B.ID_ALUM_PROGRAMA
                 INNER JOIN SINU.SRC_ALUM_PERIODO AP ON A.ID_ALUM_PROGRAMA = AP.ID_ALUM_PROGRAMA
                                                    AND AP.COD_PERIODO = A.COD_PERIODO
                 INNER JOIN src_enc_matricula M ON M.id_alum_programa = B.id_alum_programa
                                               AND M.cod_periodo = A.cod_periodo
                 INNER JOIN sinu.BAS_TERCERO C ON B.ID_TERCERO = C.ID_TERCERO
                 INNER JOIN SRC_UNI_ACADEMICA E ON E.COD_UNIDAD = B.COD_UNIDAD
                 INNER JOIN bas_dependencia dep ON dep.id_dependencia = E.id_dependencia
                 INNER JOIN SRC_GENERICA D ON D.TIP_TABLA = B.COD_EST_ALUMNO
                                          AND D.COD_TABLA = B.EST_ALUMNO
                 INNER JOIN SRC_GENERICA F ON F.TIP_TABLA = E.COD_NIVEL_FOR
                                          AND F.COD_TABLA = E.NIV_FORMACION') SRC
            -- Fecha real del periodo. La llave de Periodos_Calendario es cod_periodo +
            -- descripcion_metod, así que se colapsa con MAX(fec_inicio) por cod_periodo para
            -- no multiplicar filas del lado académico.
            LEFT JOIN (
                SELECT LTRIM(RTRIM(cod_periodo)) AS cod_periodo, MAX(fec_inicio) AS fec_inicio
                FROM Dbo.Periodos_Calendario
                GROUP BY LTRIM(RTRIM(cod_periodo))
            ) CAL ON CAL.cod_periodo = LTRIM(RTRIM(SRC.COD_PERIODO))
        ) z WHERE rn = 1;
        CREATE CLUSTERED INDEX IX_prom ON #PROM(id_k);

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
        ),
        -- Riesgo financiero + datos de recaudo desde Financiaciones_CTAYUDA_V2.
        -- Grano ~1:1 por (documento, periodo): dedup dejando el PEOR perfil (Alto primero) y menor
        -- SCORE, para que el escalamiento de MARCA_ACADEMICA sea conservador con múltiples financiaciones.
        CTAYUDA_RIESGO AS (
                SELECT DR_NUMERO_DOCUMENTO_ESTUDIANTE, ZH_PERIODO,
                       RES_PERFIL_RIESGO, RES_SCORE,
                       RECAUDO_PAGOS_NOMBRE_CAJA, RECAUDO_PAGOS_NOMBRE_FRANQUICIA
                FROM (
                        SELECT DR_NUMERO_DOCUMENTO_ESTUDIANTE, ZH_PERIODO,
                               RES_PERFIL_RIESGO, RES_SCORE,
                               RECAUDO_PAGOS_NOMBRE_CAJA, RECAUDO_PAGOS_NOMBRE_FRANQUICIA,
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
        )
        SELECT
                A.PERIODO, A.TIPO_CLIENTE, A.NOMBRE_TIPO_CLIENTE, A.IDENTIFICACION,
                A.LINEA, A.DOCUMENTO, A.NUMERO_CREDITO, A.FECHA, A.FECHA_ELABORACION, A.FECHA_VENCIMIENTO,
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
                P.PROMEDIO                                                  AS PROMEDIO,
                COALESCE(B.SEMESTRE, E.SEMESTRE)                            AS SEMESTRE,
                C.ESTADO,
                -- MARCA_ACADEMICA: marca académica base (MB.MARCA_BASE, ver CROSS APPLY abajo)
                -- REFINADA con el riesgo financiero de Financiaciones_CTAYUDA_V2:
                --   Un caso académicamente 'blando' (GESTIONABLE) con perfil crediticio ADVERSO
                --   se escala a 'PERIODO PERDIDO, PRIORIDAD ALTA' para priorizar la gestión de cobro.
                --   Riesgo adverso = 'Riesgo Alto' + 'Riesgo Regular' (score < 670), que es la
                --   frontera de la propia escala del buró entre Regular (<=668) y Bueno (>=670).
                --   El resto conserva su marca académica base sin alterar.
                CASE
                        WHEN MB.MARCA_BASE = 'GESTIONABLE'
                         AND F.RES_PERFIL_RIESGO IN ('Riesgo Alto', 'Riesgo Regular')
                                THEN 'PERIODO PERDIDO, PRIORIDAD ALTA'
                        ELSE MB.MARCA_BASE
                END AS MARCA_ACADEMICA,
                -- MARCA_ACADEMICA_DETALLE: abre cada marca según el riesgo crediticio y la
                -- evidencia de conexión. NO sustituye a MARCA_ACADEMICA (el tablero sigue
                -- leyendo esa); ordena la cola de trabajo del asesor dentro de cada marca.
                CASE
                        WHEN MB.MARCA_BASE = 'CARTERA EMPRESARIAL'
                                THEN 'CARTERA EMPRESARIAL - ' + ISNULL(NULLIF(LTRIM(RTRIM(A.NOMBRE_TIPO_CLIENTE)),''),'SIN DATO')

                        WHEN MB.MARCA_BASE = 'PERIODO NO HA INICIADO'
                                THEN 'PERIODO NO HA INICIADO'

                        WHEN MB.MARCA_BASE = 'PERIODO EN CURSO'
                         AND F.RES_PERFIL_RIESGO IN ('Riesgo Alto', 'Riesgo Regular')
                                THEN 'PERIODO EN CURSO - RIESGO CREDITICIO'
                        WHEN MB.MARCA_BASE = 'PERIODO EN CURSO'
                                THEN 'PERIODO EN CURSO'

                        WHEN MB.MARCA_BASE = 'PERIODO PERDIDO, PRIORIDAD ALTA'
                         AND F.RES_PERFIL_RIESGO IN ('Riesgo Alto', 'Riesgo Regular')
                                THEN 'PERIODO PERDIDO + RIESGO CREDITICIO'
                        WHEN MB.MARCA_BASE = 'PERIODO PERDIDO, PRIORIDAD ALTA'
                                THEN 'PERIODO PERDIDO'

                        -- Aprobó, pero el buró advierte: es el caso que se escala arriba.
                        WHEN MB.MARCA_BASE = 'GESTIONABLE'
                         AND F.RES_PERFIL_RIESGO IN ('Riesgo Alto', 'Riesgo Regular')
                                THEN 'RIESGO CREDITICIO ADVERSO'
                        WHEN MB.MARCA_BASE = 'GESTIONABLE'
                                THEN 'GESTIONABLE'

                        -- Sin registro de clase: el rastro de conexión decide si es recuperable.
                        WHEN M.Ultimo_acceso_moodle IS NOT NULL
                                THEN 'SIN REGISTRO DE CLASE - CON CONEXION'
                        ELSE 'SIN REGISTRO DE CLASE - SIN CONTACTO'
                END AS MARCA_ACADEMICA_DETALLE,
                -- Enriquecimiento financiero traído de Financiaciones_CTAYUDA_V2 (dedup 1:1 por doc+periodo)
                F.RES_PERFIL_RIESGO,
                F.RES_SCORE,
                F.RECAUDO_PAGOS_NOMBRE_CAJA,
                F.RECAUDO_PAGOS_NOMBRE_FRANQUICIA,
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
        LEFT JOIN #MOODLE M
                ON M.id_k = LTRIM(RTRIM(CONVERT(VARCHAR(50), A.IDENTIFICACION)))
        -- PROMEDIO ACUMULADO: llave SOLO identificacion (PRO_ACUMULADO no es por periodo).
        LEFT JOIN #PROM P
                ON P.id_k = LTRIM(RTRIM(CONVERT(VARCHAR(50), A.IDENTIFICACION)))
        LEFT JOIN CTAYUDA_RIESGO F
                ON CONVERT(VARCHAR(50), A.IDENTIFICACION) = F.DR_NUMERO_DOCUMENTO_ESTUDIANTE
                AND CONVERT(VARCHAR(20), A.PERIODO) = CONVERT(VARCHAR(20), F.ZH_PERIODO)
        LEFT JOIN (
                SELECT DISTINCT CONVERT(VARCHAR(10), cod_periodo) AS PERIODO,
                        CASE
                                WHEN fec_inicio > CAST(GETDATE() AS DATE)      THEN 'PERIODO NO HA INICIADO'
                                WHEN fec_inicio <= CAST(GETDATE() AS DATE) AND fec_fin >= CAST(GETDATE() AS DATE)  THEN 'ACTIVO'
                                ELSE 'NO ACTIVO'
                        END AS ESTADO
                FROM Dbo.Periodos_Calendario
        ) C ON A.PERIODO = C.PERIODO
        -- Marca académica BASE (escalera con fallback, nunca NULL). Se calcula una sola vez aquí
        -- y arriba se refina con el riesgo financiero (RES_PERFIL_RIESGO). Pasos:
        --   1) Estado del periodo por calendario (activo / no ha iniciado).
        --   2) PROMEDIO coalescido (B ó E, no solo B) → cubre nota de cualquier fuente y cierra
        --      el hueco 1.55–1.56 con límites contiguos.
        --   3) Sin nota → EST_ALUMNO: egresado/graduado ya no es riesgo académico.
        --   4) Sin nota → ÚLTIMO ACCESO MOODLE ≤ 90 días: sigue estudiando (nota aún no cargada).
        --   5) Catch-all: sin nota, sin estado concluyente y sin acceso reciente.
        CROSS APPLY (VALUES (
                CASE
                        -- 0) Segmento no estudiantil (empresas, convenios, colaboradores).
                        --    Se evalua PRIMERO: un NIT no tiene notas, ni plataforma, ni periodo
                        --    academico. Aplicarle la lectura academica produce marcas sin sentido.
                        WHEN ISNULL(A.NOMBRE_TIPO_CLIENTE,'') <> 'ESTUDIANTES'
                                                                      THEN 'CARTERA EMPRESARIAL'

                        WHEN C.ESTADO = 'ACTIVO'                   THEN 'PERIODO EN CURSO'
                        WHEN C.ESTADO = 'PERIODO NO HA INICIADO'   THEN 'PERIODO NO HA INICIADO'

                        WHEN P.PROMEDIO <  1.55                    THEN 'SIN REGISTRO DE CLASE'
                        WHEN P.PROMEDIO <  3.0                     THEN 'PERIODO PERDIDO, PRIORIDAD ALTA'
                        WHEN P.PROMEDIO >= 3.0                     THEN 'GESTIONABLE'

                        WHEN COALESCE(B.ESTADO_ALUMNO, Z.ESTADO_ALUMNO, E.ESTADO_ALUMNO) LIKE '%graduad%'
                          OR COALESCE(B.ESTADO_ALUMNO, Z.ESTADO_ALUMNO, E.ESTADO_ALUMNO) LIKE '%egresad%'
                                                                      THEN 'GESTIONABLE'

                        WHEN M.Ultimo_acceso_moodle >= DATEADD(DAY, -90, CAST(GETDATE() AS DATE))
                                                                      THEN 'PERIODO EN CURSO'

                        ELSE 'SIN REGISTRO DE CLASE'
                END
        )) AS MB(MARCA_BASE)
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

        -- ─────────────────────────────────────────────────────────────────────────────────────────
        -- ENRIQUECIMIENTOS VIVOS: MOODLE + PROMEDIO (replicados de USP_Foto_Meta_Comercial_Mensual)
        -- ─────────────────────────────────────────────────────────────────────────────────────────
        --   · #MOODLE : último acceso a Moodle desde CUN_STAGE.moodle.repli_mdl_user
        --               (username = IDENTIFICACION). lastaccess (epoch UNIX en segundos) → DATETIME.
        --               ROW_NUMBER deja 1 fila por usuario, el acceso MÁS RECIENTE (lastaccess DESC).
        --   · #PROM   : promedio ACUMULADO vía OPENQUERY 172.16.1.175
        --               SINU.SRC_HIS_ACADEMICA + SRC_ALUM_PERIODO (PRO_ACUMULADO),
        --               deduplicado por NUM_IDENTIFICACION -- SIN periodo en la llave.
        --   Ambas fuentes REEMPLAZAN a DBARON.CURSOS_MOODLE_2026 y al PROMEDIO de ESTADISTICA/Zoho,
        --   pero se vuelcan sobre las MISMAS columnas (ultimoaccesoplataformlimpio, PROMEDIO) para
        --   no romper reportes que ya las consumen.
        -- ─────────────────────────────────────────────────────────────────────────────────────────
        -- #MOODLE ya se construyó en el PASO 3 (antes de Cartera_Total) con el fix NULLIF y
        -- persiste en tempdb; aquí solo se reutiliza en el JOIN de Cartera_Gestion. No se reconstruye.

        -- #PROM ya se construyó en el PASO 3 (antes de Cartera_Total), porque MARCA_ACADEMICA
        -- lo consume. Persiste en tempdb todo el batch; aquí solo se reutiliza en el JOIN de
        -- Cartera_Gestion. No se reconstruye. Ver el bloque #PROM del PASO 3.

        -- Recarga completa: DROP + SELECT INTO evita conflictos de compilación al añadir columnas
        DROP TABLE IF EXISTS Financiera.Cartera_Gestion;

        -- ─────────────────────────────────────────────────────────────────────────────────────────
        -- SELECT INTO Cartera_Gestion
        -- ─────────────────────────────────────────────────────────────────────────────────────────
        -- Deduplicaciones previas:
        --   · Cartera_Total_Dedup: un registro por (IDENTIFICACION, PERIODO) para el LEFT JOIN.
        --   · Estadistica_Dedup: prioriza ciclo superior (Profesional > Tecnólogo > Técnico)
        --     y estado activo, evitando duplicar filas por múltiples programas simultáneos.
        --     (Solo aporta SEMESTRE; el PROMEDIO ahora proviene de #PROM.)
        --   · #MOODLE / #PROM: enriquecimientos vivos replicados de
        --     USP_Foto_Meta_Comercial_Mensual (ver bloque previo). Reemplazan a
        --     DBARON.CURSOS_MOODLE_2026 y al PROMEDIO de ESTADISTICA/Zoho.
        --
        -- NRO_CUOTA: se extrae mediante CHARINDEX + SUBSTRING sobre el campo DESCRIPCION de Oracle.
        --   El patrón esperado es: "... EN LA CUOTA: {número} POR EL ..."
        --   TRY_CAST evita fallos si el campo no contiene el patrón esperado.
        -- ─────────────────────────────────────────────────────────────────────────────────────────
        WITH
        Cartera_Total_Dedup AS (
            SELECT IDENTIFICACION, PERIODO, NOM_UNIDAD, NUEVO, PROMEDIO, SEMESTRE,
                NOM_SECCIONAL, MODALIDAD, CICLO, MARCA_ACADEMICA, MARCA_ACADEMICA_DETALLE, ESTADO_ALUMNO, ESTADO,
                RES_PERFIL_RIESGO, RES_SCORE, RECAUDO_PAGOS_NOMBRE_CAJA, RECAUDO_PAGOS_NOMBRE_FRANQUICIA,
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
        )
        SELECT
            C.PERIODO, C.TIPO_CLIENTE, C.NOMBRE_TIPO_CLIENTE, C.IDENTIFICACION,
            C.FEC_NAC, C.GENDER, C.DIRECCION_CASA, C.EMAIL, C.TEL_CASA,
            C.TEL_CELULAR, C.WHATSAPP, C.PAIS, C.DEPARTAMENTO, C.CLIENTE,
            C.NOMBRE, C.LINEA, C.TIPO_DOCUMENTO, C.DOCUMENTO, C.NUMERO_CREDITO,
            C.FECHA, C.FECHA_ELABORACION, C.FECHA_VENCIMIENTO, C.CENTRO_COSTO, C.NOMBRE_CENTRO,
            C.FONDO, C.NOMBRE_FONDO, C.NOMBRE_CONCEPTO, C.NOMBRE_CAUSA,
            C.VALOR_ORIGINAL, C.CORRIENTE, C.GR1A30, C.GR31A60, C.GR61A90,
            C.GR91A120, C.GR121A150, C.GR151A360, C.GR360MAS, C.TOTAL,
            C.CODIGO_CONTABLE, C.DESCRIPCION,
            CT.NOM_UNIDAD, CT.NUEVO,
            COALESCE(EE.SEMESTRE, CT.SEMESTRE) AS SEMESTRE,
            P.PROMEDIO AS PROMEDIO,                          -- fuente unica: SRC_ALUM_PERIODO.PRO_ACUMULADO
            M.Ultimo_acceso_moodle AS ultimoaccesoplataformlimpio,  -- fuente viva: repli_mdl_user
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
            CT.NOM_SECCIONAL, CT.MODALIDAD, CT.CICLO, CT.MARCA_ACADEMICA, CT.MARCA_ACADEMICA_DETALLE, CT.ESTADO_ALUMNO,
            CT.ESTADO,   -- Estado del periodo (ACTIVO / NO ACTIVO / PERIODO NO HA INICIADO) desde Cartera_Total
            CT.RES_PERFIL_RIESGO, CT.RES_SCORE,
            CT.RECAUDO_PAGOS_NOMBRE_CAJA, CT.RECAUDO_PAGOS_NOMBRE_FRANQUICIA,
            GETDATE() AS AUD_FECHA_PROCESAMIENTO   -- Marca de auditoría: instante de carga del lote
        INTO Financiera.Cartera_Gestion
        FROM Financiera.Cartera C
        LEFT JOIN Cartera_Total_Dedup CT
            ON CONVERT(VARCHAR(50), C.IDENTIFICACION) = CONVERT(VARCHAR(50), CT.IDENTIFICACION)
            AND C.PERIODO = CT.PERIODO AND CT.rn = 1
        LEFT JOIN Estadistica_Dedup EE
            ON CONVERT(VARCHAR(50), C.IDENTIFICACION) = EE.NUM_IDENTIFICACION
            AND C.PERIODO = EE.COD_PERIODO
        LEFT JOIN #MOODLE M
            ON M.id_k = LTRIM(RTRIM(CONVERT(VARCHAR(50), C.IDENTIFICACION)))
        LEFT JOIN #PROM P
            ON P.id_k = LTRIM(RTRIM(CONVERT(VARCHAR(50), C.IDENTIFICACION)))
        WHERE C.DOCUMENTO = 'NDB'
          AND (C.PERIODO LIKE '%22%' OR C.PERIODO LIKE '%23%' OR
               C.PERIODO LIKE '%24%' OR C.PERIODO LIKE '%25%' OR C.PERIODO LIKE '%26%')


        -- ==========================================================================================
        -- PASO 4.1 │ MARCA DE NOTAS DÉBITO CARGADAS A DESTIEMPO (consumo Zoho CRM)
        -- ==========================================================================================
        -- Problema: algunas notas débito (NDB) se cargan al sistema con desfase de 10-30 días
        -- respecto a su FECHA nominal (retro-fechadas). Zoho CRM solo puede crear NDB con fecha
        -- del DÍA ANTERIOR, por lo que debe consultar UNA sola columna (FECHA_REAL_CARGA_NDB)
        -- para crear en un mismo lote las NDB habituales + las cargadas a destiempo.
        --
        -- Se pobla FECHA_REAL_CARGA_NDB = AYER (día anterior a la ejecución) para dos poblaciones:
        --   · HABITUALES : NDB cuya FECHA nominal = ayer (creadas a tiempo).      → MARCA = 0
        --   · A DESTIEMPO: NDB NUEVA (no estaba en la foto de ayer, Cartera_Foto_Ayer, por la
        --                  llave única IDENTIFICACION + PERIODO + NUMERO_CREDITO) cuya FECHA
        --                  nominal es ANTERIOR a ayer.                            → MARCA = 1
        -- Así Zoho filtra FECHA_REAL_CARGA_NDB = ayer y obtiene ambos; MARCA_CARGA_DESTIEMPO
        -- distingue las de destiempo y solo esas se acumulan en Cartera_Destiempo_ZOHO.
        --
        -- Detección de "nueva" (espejo del PASO 5): una NDB es NUEVA si está en la Cartera_Gestion
        -- de HOY y NO estaba en la foto de AYER (NUMERO_CREDITO es id único de la nota).
        --
        -- Marca DINÁMICA: como Cartera_Gestion se reconstruye cada corrida, la marca se recalcula
        -- sola; solo el lote nuevo del día queda con MARCA=1. Zoho consume filtrando
        -- FECHA_REAL_CARGA_NDB = ayer.
        --
        -- ⚠ Backfill implícito: en la primera corrida la foto de ayer ya contiene todo el
        --   histórico de créditos, por lo que nada se marca como nuevo (cero falsos positivos).
        -- ⚠ Las columnas se pueblan vía sp_executesql (compilación diferida) para evitar el
        --   error 207 al referenciar columnas recién agregadas en el mismo lote.
        -- ==========================================================================================

        -- (1) Columnas nuevas en Cartera_Gestion (la tabla se recrea cada corrida)
        IF COL_LENGTH('Financiera.Cartera_Gestion','MARCA_CARGA_DESTIEMPO') IS NULL
            ALTER TABLE Financiera.Cartera_Gestion ADD MARCA_CARGA_DESTIEMPO bit NOT NULL DEFAULT(0);
        IF COL_LENGTH('Financiera.Cartera_Gestion','FECHA_REAL_CARGA_NDB') IS NULL
            ALTER TABLE Financiera.Cartera_Gestion ADD FECHA_REAL_CARGA_NDB varchar(10) NULL;

        -- (2) Poblar FECHA_REAL_CARGA_NDB = ayer (habituales + destiempo) y marcar las de destiempo.
        --     Requiere la foto de ayer para el anti-join de "nuevas". Compilación diferida (207).
        IF OBJECT_ID('Financiera.Cartera_Foto_Ayer','U') IS NOT NULL
        BEGIN
            EXEC sp_executesql N'
            DECLARE @ayer date = DATEADD(DAY, -1, CAST(GETDATE() AS DATE));
            UPDATE H
               SET H.FECHA_REAL_CARGA_NDB  = CONVERT(varchar(10), @ayer, 103),
                   H.MARCA_CARGA_DESTIEMPO = CASE WHEN TRY_CONVERT(date, H.FECHA, 103) < @ayer
                                                  THEN 1 ELSE 0 END
            FROM Financiera.Cartera_Gestion H
            WHERE H.DOCUMENTO = ''NDB''
              AND (
                    -- HABITUALES: NDB creadas ayer
                    TRY_CONVERT(date, H.FECHA, 103) = @ayer
                 OR
                    -- A DESTIEMPO: NDB nueva (no estaba en la foto de ayer) y FECHA anterior a ayer
                    ( TRY_CONVERT(date, H.FECHA, 103) < @ayer
                      AND NOT EXISTS (
                            SELECT 1
                            FROM Financiera.Cartera_Foto_Ayer A
                            WHERE A.IDENTIFICACION = H.IDENTIFICACION
                              AND A.PERIODO        = H.PERIODO
                              AND A.NUMERO_CREDITO = H.NUMERO_CREDITO
                      )
                    )
              );';
        END

        -- (3.0) AUTO-REPARACIÓN DE ESQUEMA (drift de Cartera_Gestion → bitácora persistente)
        --   El INSERT del paso (3) es POSICIONAL (SELECT H.*). Al agregar CUALQUIER columna nueva a
        --   Cartera_Gestion (p.ej. FECHA_ELABORACION, ESTADO), el orden/conteo de H.* cambia y
        --   dejaría de alinear con la tabla persistente ya existente, corrompiendo o abortando el
        --   INSERT. Detección GENÉRICA: si alguna columna de Cartera_Gestion NO existe en la
        --   bitácora, se reconstruye UNA vez preservando TODO el histórico (copia por NOMBRE de
        --   columna); las columnas nuevas quedan NULL en las filas antiguas. Tras la corrida el
        --   esquema queda alineado y este bloque no vuelve a activarse.
        IF OBJECT_ID('Financiera.Cartera_Destiempo_ZOHO','U') IS NOT NULL
           AND EXISTS (
                SELECT 1 FROM sys.columns g
                WHERE g.object_id = OBJECT_ID('Financiera.Cartera_Gestion')
                  AND NOT EXISTS (SELECT 1 FROM sys.columns z
                                  WHERE z.object_id = OBJECT_ID('Financiera.Cartera_Destiempo_ZOHO')
                                    AND z.name = g.name)
           )
        BEGIN
            DROP TABLE IF EXISTS Financiera.Cartera_Destiempo_ZOHO_REBUILD;

            -- Estructura nueva, alineada al esquema vivo de Cartera_Gestion + FECHA_DETECCION
            EXEC('SELECT TOP 0 H.*, CAST(NULL AS date) AS FECHA_DETECCION
                  INTO Financiera.Cartera_Destiempo_ZOHO_REBUILD
                  FROM Financiera.Cartera_Gestion H;');

            -- Copia del histórico por NOMBRE de columna (intersección vieja∩nueva).
            -- Misma lista en INSERT y SELECT ⇒ el mapeo es por nombre, no posicional.
            DECLARE @cols_hist NVARCHAR(MAX);
            SELECT @cols_hist = STRING_AGG(QUOTENAME(n.name), ', ')
            FROM sys.columns n
            WHERE n.object_id = OBJECT_ID('Financiera.Cartera_Destiempo_ZOHO_REBUILD')
              AND EXISTS (SELECT 1 FROM sys.columns o
                          WHERE o.object_id = OBJECT_ID('Financiera.Cartera_Destiempo_ZOHO')
                            AND o.name = n.name);

            DECLARE @sql_hist NVARCHAR(MAX) =
                N'INSERT INTO Financiera.Cartera_Destiempo_ZOHO_REBUILD (' + @cols_hist + N') ' +
                N'SELECT ' + @cols_hist + N' FROM Financiera.Cartera_Destiempo_ZOHO;';
            EXEC sp_executesql @sql_hist;

            -- Swap dentro de la transacción del SP (atómico con el resto del proceso)
            DROP TABLE Financiera.Cartera_Destiempo_ZOHO;
            EXEC sp_rename 'Financiera.Cartera_Destiempo_ZOHO_REBUILD', 'Cartera_Destiempo_ZOHO';
        END

        -- (3) Bitácora persistente Cartera_Destiempo_ZOHO (append diario, NUNCA se dropea).
        --     Copia completa de las filas marcadas + FECHA_DETECCION, con esquema vivo de
        --     Cartera_Gestion. ⚠ Si cambia el esquema de Cartera_Gestion, elimine esta tabla
        --     para que se recree alineada.
        IF OBJECT_ID('Financiera.Cartera_Destiempo_ZOHO','U') IS NULL
            EXEC('SELECT TOP 0 H.*, CAST(NULL AS date) AS FECHA_DETECCION
                  INTO Financiera.Cartera_Destiempo_ZOHO
                  FROM Financiera.Cartera_Gestion H;');

        -- Inserción diferida de las NDB marcadas hoy, con guarda anti-duplicado por llave + día
        EXEC sp_executesql N'
        INSERT INTO Financiera.Cartera_Destiempo_ZOHO
        SELECT H.*, CAST(GETDATE() AS DATE)
        FROM Financiera.Cartera_Gestion H
        WHERE H.MARCA_CARGA_DESTIEMPO = 1
          AND NOT EXISTS (
                SELECT 1
                FROM Financiera.Cartera_Destiempo_ZOHO Z
                WHERE Z.FECHA_DETECCION = CAST(GETDATE() AS DATE)
                  AND Z.IDENTIFICACION  = H.IDENTIFICACION
                  AND Z.PERIODO         = H.PERIODO
                  AND Z.NUMERO_CREDITO  = H.NUMERO_CREDITO
          );';


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
            -- Auto-creacion de la acumuladora (entorno nuevo) con esquema alineado a Cartera_Gestion
            IF OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA', 'U') IS NULL
            BEGIN
                CREATE TABLE Financiera.Creditos_pagos_CTAYUDA (
                    PERIODO                        varchar(6),
                    TIPO_CLIENTE                   varchar(3),
                    NOMBRE_TIPO_CLIENTE            varchar(80),
                    NUMERO_DOCUMENTO               varchar(16),
                    FEC_NAC                        varchar(10),
                    GENDER                         varchar(1),
                    DIRECCION_CASA                 varchar(80),
                    EMAIL                          varchar(80),
                    TEL_CASA                       varchar(80),
                    TEL_CELULAR                    varchar(20),
                    WHATSAPP                       varchar(20),
                    PAIS                           varchar(121),
                    DEPARTAMENTO                   varchar(121),
                    CLIENTE                        varchar(16),
                    NOMBRE                         varchar(418),
                    LINEA                          varchar(84),
                    TIPO_DOCUMENTO                 varchar(1),
                    DOCUMENTO                      char(3),
                    NUMERO_CREDITO                 numeric(10,0),
                    FECHA                          varchar(10),
                    FECHA_ELABORACION              varchar(10),
                    FECHA_VENCIMIENTO              datetime,
                    CENTRO_COSTO                   varchar(8),
                    NOMBRE_CENTRO                  varchar(80),
                    FONDO                          numeric(8,0),
                    NOMBRE_FONDO                   varchar(80),
                    NOMBRE_CONCEPTO                varchar(121),
                    NOMBRE_CAUSA                   varchar(121),
                    VALOR_ORIGINAL                 float,
                    CORRIENTE                      float,
                    GR1A30                         float,
                    GR31A60                        float,
                    GR61A90                        float,
                    GR91A120                       float,
                    GR121A150                      float,
                    GR151A360                      float,
                    GR360MAS                       float,
                    TOTAL_PAGADO                   float,
                    CODIGO_CONTABLE                float,
                    DESCRIPCION                    varchar(2000),
                    NOM_UNIDAD                     varchar(MAX),
                    NUEVO                          varchar(MAX),
                    SEMESTRE                       float,
                    PROMEDIO                       float,
                    ultimoaccesoplataformlimpio    varchar(MAX),
                    NRO_CUOTA                      int,
                    AUD_FECHA_PROCESAMIENTO        datetime,
                    NOM_SECCIONAL                  varchar(MAX),
                    MODALIDAD                      varchar(MAX),
                    CICLO                          varchar(MAX),
                    MARCA_ACADEMICA                varchar(50),
                    ESTADO_ALUMNO                  varchar(MAX),
                    ESTADO                         varchar(50),
                    ESTADO_CUOTA                   varchar(50),
                    FECHA_DETECCION_PAGO           date
                );
            END

            -- Migracion incremental idempotente: CTAYUDA usa NUMERO_DOCUMENTO / TOTAL_PAGADO
            -- (1) Renombrar columnas equivalentes para conservar el historico sin duplicar
            IF (EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA') AND name='IDENTIFICACION')
                AND NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA') AND name='NUMERO_DOCUMENTO'))
                EXEC sp_rename 'Financiera.Creditos_pagos_CTAYUDA.IDENTIFICACION','NUMERO_DOCUMENTO','COLUMN';
            IF (EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA') AND name='TOTAL')
                AND NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA') AND name='TOTAL_PAGADO'))
                EXEC sp_rename 'Financiera.Creditos_pagos_CTAYUDA.TOTAL','TOTAL_PAGADO','COLUMN';

            -- (2) Agregar columnas de Cartera_Gestion que falten (filas viejas quedan NULL)
            IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA') AND name='TIPO_CLIENTE')
                ALTER TABLE Financiera.Creditos_pagos_CTAYUDA ADD TIPO_CLIENTE varchar(3) NULL;
            IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA') AND name='NOMBRE_TIPO_CLIENTE')
                ALTER TABLE Financiera.Creditos_pagos_CTAYUDA ADD NOMBRE_TIPO_CLIENTE varchar(80) NULL;
            IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA') AND name='FEC_NAC')
                ALTER TABLE Financiera.Creditos_pagos_CTAYUDA ADD FEC_NAC varchar(10) NULL;
            IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA') AND name='GENDER')
                ALTER TABLE Financiera.Creditos_pagos_CTAYUDA ADD GENDER varchar(1) NULL;
            IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA') AND name='DIRECCION_CASA')
                ALTER TABLE Financiera.Creditos_pagos_CTAYUDA ADD DIRECCION_CASA varchar(80) NULL;
            IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA') AND name='EMAIL')
                ALTER TABLE Financiera.Creditos_pagos_CTAYUDA ADD EMAIL varchar(80) NULL;
            IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA') AND name='TEL_CASA')
                ALTER TABLE Financiera.Creditos_pagos_CTAYUDA ADD TEL_CASA varchar(80) NULL;
            IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA') AND name='TEL_CELULAR')
                ALTER TABLE Financiera.Creditos_pagos_CTAYUDA ADD TEL_CELULAR varchar(20) NULL;
            IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA') AND name='WHATSAPP')
                ALTER TABLE Financiera.Creditos_pagos_CTAYUDA ADD WHATSAPP varchar(20) NULL;
            IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA') AND name='PAIS')
                ALTER TABLE Financiera.Creditos_pagos_CTAYUDA ADD PAIS varchar(121) NULL;
            IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA') AND name='DEPARTAMENTO')
                ALTER TABLE Financiera.Creditos_pagos_CTAYUDA ADD DEPARTAMENTO varchar(121) NULL;
            IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA') AND name='CLIENTE')
                ALTER TABLE Financiera.Creditos_pagos_CTAYUDA ADD CLIENTE varchar(16) NULL;
            IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA') AND name='NOMBRE')
                ALTER TABLE Financiera.Creditos_pagos_CTAYUDA ADD NOMBRE varchar(418) NULL;
            IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA') AND name='LINEA')
                ALTER TABLE Financiera.Creditos_pagos_CTAYUDA ADD LINEA varchar(84) NULL;
            IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA') AND name='TIPO_DOCUMENTO')
                ALTER TABLE Financiera.Creditos_pagos_CTAYUDA ADD TIPO_DOCUMENTO varchar(1) NULL;
            IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA') AND name='DOCUMENTO')
                ALTER TABLE Financiera.Creditos_pagos_CTAYUDA ADD DOCUMENTO char(3) NULL;
            IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA') AND name='FECHA')
                ALTER TABLE Financiera.Creditos_pagos_CTAYUDA ADD FECHA varchar(10) NULL;
            IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA') AND name='FECHA_ELABORACION')
                ALTER TABLE Financiera.Creditos_pagos_CTAYUDA ADD FECHA_ELABORACION varchar(10) NULL;
            IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA') AND name='CENTRO_COSTO')
                ALTER TABLE Financiera.Creditos_pagos_CTAYUDA ADD CENTRO_COSTO varchar(8) NULL;
            IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA') AND name='NOMBRE_CENTRO')
                ALTER TABLE Financiera.Creditos_pagos_CTAYUDA ADD NOMBRE_CENTRO varchar(80) NULL;
            IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA') AND name='FONDO')
                ALTER TABLE Financiera.Creditos_pagos_CTAYUDA ADD FONDO numeric(8,0) NULL;
            IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA') AND name='NOMBRE_FONDO')
                ALTER TABLE Financiera.Creditos_pagos_CTAYUDA ADD NOMBRE_FONDO varchar(80) NULL;
            IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA') AND name='NOMBRE_CONCEPTO')
                ALTER TABLE Financiera.Creditos_pagos_CTAYUDA ADD NOMBRE_CONCEPTO varchar(121) NULL;
            IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA') AND name='VALOR_ORIGINAL')
                ALTER TABLE Financiera.Creditos_pagos_CTAYUDA ADD VALOR_ORIGINAL float NULL;
            IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA') AND name='CORRIENTE')
                ALTER TABLE Financiera.Creditos_pagos_CTAYUDA ADD CORRIENTE float NULL;
            IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA') AND name='GR1A30')
                ALTER TABLE Financiera.Creditos_pagos_CTAYUDA ADD GR1A30 float NULL;
            IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA') AND name='GR31A60')
                ALTER TABLE Financiera.Creditos_pagos_CTAYUDA ADD GR31A60 float NULL;
            IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA') AND name='GR61A90')
                ALTER TABLE Financiera.Creditos_pagos_CTAYUDA ADD GR61A90 float NULL;
            IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA') AND name='GR91A120')
                ALTER TABLE Financiera.Creditos_pagos_CTAYUDA ADD GR91A120 float NULL;
            IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA') AND name='GR121A150')
                ALTER TABLE Financiera.Creditos_pagos_CTAYUDA ADD GR121A150 float NULL;
            IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA') AND name='GR151A360')
                ALTER TABLE Financiera.Creditos_pagos_CTAYUDA ADD GR151A360 float NULL;
            IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA') AND name='GR360MAS')
                ALTER TABLE Financiera.Creditos_pagos_CTAYUDA ADD GR360MAS float NULL;
            IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA') AND name='CODIGO_CONTABLE')
                ALTER TABLE Financiera.Creditos_pagos_CTAYUDA ADD CODIGO_CONTABLE float NULL;
            IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA') AND name='DESCRIPCION')
                ALTER TABLE Financiera.Creditos_pagos_CTAYUDA ADD DESCRIPCION varchar(2000) NULL;
            IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA') AND name='NOM_UNIDAD')
                ALTER TABLE Financiera.Creditos_pagos_CTAYUDA ADD NOM_UNIDAD varchar(MAX) NULL;
            IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA') AND name='NUEVO')
                ALTER TABLE Financiera.Creditos_pagos_CTAYUDA ADD NUEVO varchar(MAX) NULL;
            IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA') AND name='SEMESTRE')
                ALTER TABLE Financiera.Creditos_pagos_CTAYUDA ADD SEMESTRE float NULL;
            IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA') AND name='PROMEDIO')
                ALTER TABLE Financiera.Creditos_pagos_CTAYUDA ADD PROMEDIO float NULL;
            IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA') AND name='ultimoaccesoplataformlimpio')
                ALTER TABLE Financiera.Creditos_pagos_CTAYUDA ADD ultimoaccesoplataformlimpio varchar(MAX) NULL;
            IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA') AND name='NOM_SECCIONAL')
                ALTER TABLE Financiera.Creditos_pagos_CTAYUDA ADD NOM_SECCIONAL varchar(MAX) NULL;
            IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA') AND name='MODALIDAD')
                ALTER TABLE Financiera.Creditos_pagos_CTAYUDA ADD MODALIDAD varchar(MAX) NULL;
            IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA') AND name='CICLO')
                ALTER TABLE Financiera.Creditos_pagos_CTAYUDA ADD CICLO varchar(MAX) NULL;
            IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA') AND name='MARCA_ACADEMICA')
                ALTER TABLE Financiera.Creditos_pagos_CTAYUDA ADD MARCA_ACADEMICA varchar(50) NULL;
            IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA') AND name='ESTADO_ALUMNO')
                ALTER TABLE Financiera.Creditos_pagos_CTAYUDA ADD ESTADO_ALUMNO varchar(MAX) NULL;
            IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA') AND name='ESTADO')
                ALTER TABLE Financiera.Creditos_pagos_CTAYUDA ADD ESTADO varchar(50) NULL;

            -- Indice de soporte para comparativos historicos por fecha de deteccion
            IF NOT EXISTS (
                SELECT 1 FROM sys.indexes
                WHERE object_id = OBJECT_ID('Financiera.Creditos_pagos_CTAYUDA')
                  AND name = 'IX_Creditos_pagos_CTAYUDA_FECHA_DETECCION'
            )
                CREATE NONCLUSTERED INDEX IX_Creditos_pagos_CTAYUDA_FECHA_DETECCION
                    ON Financiera.Creditos_pagos_CTAYUDA (FECHA_DETECCION_PAGO)
                    INCLUDE (PERIODO, NUMERO_DOCUMENTO, NUMERO_CREDITO, NRO_CUOTA);

            -- Insercion diferida (sp_executesql) tras los ALTER, evita el error 207.
            -- CTAYUDA queda con TODAS las columnas de Cartera_Gestion (foto del credito pagado)
            -- mas ESTADO_CUOTA y FECHA_DETECCION_PAGO (seguimiento de recaudo).
            EXEC sp_executesql N'
            INSERT INTO Financiera.Creditos_pagos_CTAYUDA (
                PERIODO,
                TIPO_CLIENTE,
                NOMBRE_TIPO_CLIENTE,
                NUMERO_DOCUMENTO,
                FEC_NAC,
                GENDER,
                DIRECCION_CASA,
                EMAIL,
                TEL_CASA,
                TEL_CELULAR,
                WHATSAPP,
                PAIS,
                DEPARTAMENTO,
                CLIENTE,
                NOMBRE,
                LINEA,
                TIPO_DOCUMENTO,
                DOCUMENTO,
                NUMERO_CREDITO,
                FECHA,
                FECHA_ELABORACION,
                FECHA_VENCIMIENTO,
                CENTRO_COSTO,
                NOMBRE_CENTRO,
                FONDO,
                NOMBRE_FONDO,
                NOMBRE_CONCEPTO,
                NOMBRE_CAUSA,
                VALOR_ORIGINAL,
                CORRIENTE,
                GR1A30,
                GR31A60,
                GR61A90,
                GR91A120,
                GR121A150,
                GR151A360,
                GR360MAS,
                TOTAL_PAGADO,
                CODIGO_CONTABLE,
                DESCRIPCION,
                NOM_UNIDAD,
                NUEVO,
                SEMESTRE,
                PROMEDIO,
                ultimoaccesoplataformlimpio,
                NRO_CUOTA,
                AUD_FECHA_PROCESAMIENTO,
                NOM_SECCIONAL,
                MODALIDAD,
                CICLO,
                MARCA_ACADEMICA,
                ESTADO_ALUMNO,
                ESTADO,
                ESTADO_CUOTA,
                FECHA_DETECCION_PAGO
            )
            SELECT
                Ayer.PERIODO,
                Ayer.TIPO_CLIENTE,
                Ayer.NOMBRE_TIPO_CLIENTE,
                Ayer.IDENTIFICACION,         -- de Cartera_Gestion; carga la col NUMERO_DOCUMENTO de CTAYUDA
                Ayer.FEC_NAC,
                Ayer.GENDER,
                Ayer.DIRECCION_CASA,
                Ayer.EMAIL,
                Ayer.TEL_CASA,
                Ayer.TEL_CELULAR,
                Ayer.WHATSAPP,
                Ayer.PAIS,
                Ayer.DEPARTAMENTO,
                Ayer.CLIENTE,
                Ayer.NOMBRE,
                Ayer.LINEA,
                Ayer.TIPO_DOCUMENTO,
                Ayer.DOCUMENTO,
                Ayer.NUMERO_CREDITO,
                Ayer.FECHA,
                Ayer.FECHA_ELABORACION,
                TRY_CONVERT(DATETIME, Ayer.FECHA_VENCIMIENTO, 103),
                Ayer.CENTRO_COSTO,
                Ayer.NOMBRE_CENTRO,
                Ayer.FONDO,
                Ayer.NOMBRE_FONDO,
                Ayer.NOMBRE_CONCEPTO,
                Ayer.NOMBRE_CAUSA,
                Ayer.VALOR_ORIGINAL,
                Ayer.CORRIENTE,
                Ayer.GR1A30,
                Ayer.GR31A60,
                Ayer.GR61A90,
                Ayer.GR91A120,
                Ayer.GR121A150,
                Ayer.GR151A360,
                Ayer.GR360MAS,
                Ayer.TOTAL,                  -- de Cartera_Gestion; carga la col TOTAL_PAGADO de CTAYUDA
                Ayer.CODIGO_CONTABLE,
                Ayer.DESCRIPCION,
                Ayer.NOM_UNIDAD,
                Ayer.NUEVO,
                Ayer.SEMESTRE,
                Ayer.PROMEDIO,
                Ayer.ultimoaccesoplataformlimpio,
                Ayer.NRO_CUOTA,
                GETDATE(),
                Ayer.NOM_SECCIONAL,
                Ayer.MODALIDAD,
                Ayer.CICLO,
                Ayer.MARCA_ACADEMICA,
                Ayer.ESTADO_ALUMNO,
                Ayer.ESTADO,
                ''Cuota Cancelada'',
                CAST(GETDATE() AS DATE)
            FROM Financiera.Cartera_Foto_Ayer Ayer
            LEFT JOIN Financiera.Cartera_Gestion Hoy
                ON  Ayer.IDENTIFICACION       = Hoy.IDENTIFICACION
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
                    AND H.NUMERO_DOCUMENTO        = Ayer.IDENTIFICACION
                    AND H.PERIODO                 = Ayer.PERIODO
                    AND H.NUMERO_CREDITO          = Ayer.NUMERO_CREDITO
                    AND ISNULL(H.NRO_CUOTA, 0)    = ISNULL(Ayer.NRO_CUOTA, 0)
                    AND H.FECHA_VENCIMIENTO       = TRY_CONVERT(DATETIME, Ayer.FECHA_VENCIMIENTO, 103)
              );';
        END


        -- ==========================================================================================
        -- PASO 5.1 │ CONTACTO VIVO SOBRE EL HISTÓRICO DE PAGOS (Creditos_pagos_CTAYUDA)
        -- ==========================================================================================
        -- Creditos_pagos_CTAYUDA NO se reconstruye: es acumulativa (80.114 filas al 2026-08-24) y
        -- solo recibe INSERTs. Sus filas viejas se quedarían con el EMAIL/WHATSAPP del día en que
        -- se detectó el pago, así que el PASO 1.5 por sí solo no las alcanza. Este UPDATE las pone
        -- al día con la misma regla, incluida la validación del celular colombiano.
        --
        -- Cubre también las filas que el PASO 5 acaba de insertar: esas vienen de
        -- Cartera_Foto_Ayer, que es la foto de AYER y por tanto todavía trae el contacto anterior.
        -- Corriendo aquí, después del INSERT, quedan corregidas en la misma ejecución.
        --
        -- La llave de persona en esta tabla es NUMERO_DOCUMENTO (carga Ayer.IDENTIFICACION).
        -- ==========================================================================================
        UPDATE T
           SET T.EMAIL    = COALESCE(NULLIF(LTRIM(RTRIM(D.DIR_EMAIL_PER)), ''), T.EMAIL),
               T.WHATSAPP = w.WA
        FROM Financiera.Creditos_pagos_CTAYUDA T
        LEFT JOIN Financiera.Datos_contacto_estudiantes D
               ON LTRIM(RTRIM(D.NUM_IDENTIFICACION)) = LTRIM(RTRIM(T.NUMERO_DOCUMENTO))
        CROSS APPLY (SELECT
                N_DCE = REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                            ISNULL(D.TEL_CECULAR, ''), ' ',''), '-',''), '(',''), ')',''), '.',''), '+',''), CHAR(9),''),
                N_ORI = REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                            ISNULL(T.WHATSAPP, ''), ' ',''), '-',''), '(',''), ')',''), '.',''), '+',''), CHAR(9),'')) n
        CROSS APPLY (SELECT
                C_DCE = CASE WHEN LEN(n.N_DCE) = 12 AND LEFT(n.N_DCE, 3) = '573'
                             THEN RIGHT(n.N_DCE, 10) ELSE n.N_DCE END,
                C_ORI = CASE WHEN LEN(n.N_ORI) = 12 AND LEFT(n.N_ORI, 3) = '573'
                             THEN RIGHT(n.N_ORI, 10) ELSE n.N_ORI END) c
        CROSS APPLY (SELECT WA = COALESCE(
                CASE WHEN LEN(c.C_DCE) = 10 AND LEFT(c.C_DCE, 1) = '3'
                      AND c.C_DCE NOT LIKE '%[^0-9]%' THEN c.C_DCE END,
                CASE WHEN LEN(c.C_ORI) = 10 AND LEFT(c.C_ORI, 1) = '3'
                      AND c.C_ORI NOT LIKE '%[^0-9]%' THEN c.C_ORI END)) w;


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
        SET @hubo_error    = 1

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
    --
    -- ⚠ Si el proceso falló dentro del TRY (@hubo_error = 1), NO se ejecuta esta validación:
    --   correría sobre las tablas ya revertidas y registraría un OK engañoso encima del ERROR
    --   ya logueado. El error real ya fue relanzado al orquestador desde el CATCH.
    -- ================================================================================================
    IF @hubo_error = 1
        RETURN;

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
