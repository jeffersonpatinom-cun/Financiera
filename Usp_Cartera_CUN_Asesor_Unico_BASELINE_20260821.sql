/* ============================================================================
   SP   [Financiera].[Usp_Cartera_CUN_Asesor_Unico]
   Autor: Analitica financiera — Universidad CUN

   Objetivo:
     Materializar la Cartera_CUN (ZOHO CRM) enriquecida con:
       - Gestion academica            (Financiera.Cartera_Gestion)
       - Meta comercial               (Financiera.Cartera_Meta_Comercial_Historico)
       - Marca de carga a destiempo   (Financiera.Cartera_Destiempo_ZOHO)
       - Ultima tipificacion          (ZOHO.CRM.Historico_tipificacion_contact)
       - Datos del usuario modificador (Zoho.crm.usuarios)
       - Asesor_Unico resuelto por prioridad (ver logica ASESOR_EVALUADO)

   Salida: tabla Financiera.Cartera_CUN_Asesor_Unico (DROP + SELECT INTO).
     Se usa SELECT INTO para absorber automaticamente el drift de c.* (columnas
     nuevas de Cartera_CUN en ZOHO no rompen el SP).

   Logica Asesor_Unico (prioridad ASC en el ROW_NUMBER):
     0  Hecho_por de la tipificacion (si no es CUN DIGITAL / PENAGOS)
     1  Nombre del usuario modificador (si no es CUN DIGITAL / PENAGOS)
     2  Propietario_de_Cartera_CUN_Name (asesor real por defecto)
     3  Propietario CUN DIGITAL / PENAGOS -> 'Reasignar en CRM'
     4  Todo CUN DIGITAL -> 'Sin asignar'

   LOG: cada ejecucion en Financiera.LOG_Cartera_CUN_Asesor_Unico (OK/ERROR).
        En error re-lanza con THROW para que el job de SQL Agent marque FALLO.

   Cambios 2026-08-10 (rendimiento + correccion):
     - La ultima tipificacion se materializa una sola vez en #Tipificacion_Ultima
       con ROW_NUMBER, en vez de un OUTER APPLY TOP 1 correlacionado evaluado
       283.403 veces contra un HEAP con llave nvarchar(MAX). Ese OUTER APPLY hizo
       que una ejecucion pasara de 154s a >20 min sin terminar.
     - Se corrige el campo de orden de "ultima tipificacion": se usaba
       Hora_de_la_última_actividad, poblada solo en 4.365 de 26.691 filas (16%),
       por lo que el TOP 1 devolvia una fila ARBITRARIA en el 84% de los casos.
       Ahora se usa Hora_de_creación (100% poblada, 100% parseable con style 103).
     - El CTE ASESOR_EVALUADO ya no une al historico crudo (que multiplicaba
       filas dentro del CTE) sino a la tipificacion ya deduplicada.
     - Se deduplica Cartera_Destiempo_ZOHO (4 NUMERO_CREDITO repetidos) que
       metia 4 filas de mas y sacaba la salida del grano de Id.
   ============================================================================ */
CREATE   PROCEDURE [Financiera].[Usp_Cartera_CUN_Asesor_Unico]
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @inicio DATETIME = GETDATE();
    DECLARE @filas  INT = 0;

    -- ── Crear tabla de auditoria si no existe ──────────────────────────────
    IF OBJECT_ID('Financiera.LOG_Cartera_CUN_Asesor_Unico', 'U') IS NULL
    BEGIN
        CREATE TABLE Financiera.LOG_Cartera_CUN_Asesor_Unico (
            id              INT IDENTITY(1,1) PRIMARY KEY,
            sp_nombre       VARCHAR(100),
            fecha_inicio    DATETIME,
            fecha_fin       DATETIME,
            duracion_seg    INT,
            filas_cargadas  INT,
            estado          VARCHAR(20),
            mensaje         VARCHAR(1000)
        );
    END

    BEGIN TRY

        /* ── PASO 1: ultima tipificacion, UNA fila por Cartera_CUN ────────────
           Antes esto se resolvia con un OUTER APPLY ... TOP 1 correlacionado,
           evaluado una vez por cada una de las 283.403 filas contra un HEAP de
           26.691 filas con la llave en nvarchar(MAX). Ese era el cuello de
           botella (>20 min sin terminar). Ahora se materializa una sola vez.

           Ademas se corrige el campo de orden: Hora_de_la_última_actividad solo
           esta poblada en 4.365 de 26.691 filas (16%), asi que el TOP 1 anterior
           devolvia una fila ARBITRARIA en el 84% de los casos. Se usa
           Hora_de_creación, poblada y parseable al 100% con style 103
           (formato DD/MM/YYYY confirmado: 13.529 filas con primer componente
           > 12 y cero con el segundo > 12).                                    */
        DROP TABLE IF EXISTS #Tipificacion_Ultima;

        SELECT cartera_id, Hecho_por, Tipificación_anterior, Tipificación_nueva,
               Hora_de_la_última_actividad
        INTO #Tipificacion_Ultima
        FROM (
            SELECT
                CONVERT(varchar(30), e.Cartera_CUN)  AS cartera_id,
                CONVERT(varchar(200), e.Hecho_por)              AS Hecho_por,
                CONVERT(varchar(200), e.Tipificación_anterior)  AS Tipificación_anterior,
                CONVERT(varchar(200), e.Tipificación_nueva)     AS Tipificación_nueva,
                CONVERT(varchar(40),  e.Hora_de_la_última_actividad) AS Hora_de_la_última_actividad,
                ROW_NUMBER() OVER (
                    PARTITION BY CONVERT(varchar(30), e.Cartera_CUN)
                    ORDER BY
                        TRY_CONVERT(datetime, e.Hora_de_creación, 103) DESC,
                        CONVERT(varchar(30), e.Id) DESC
                ) AS rn
            FROM [ZOHO].[CRM].[Historico_tipificacion_contact] e
            /* 1.878 filas huerfanas (Cartera_CUN NULL) que nunca harian match */
            WHERE e.Cartera_CUN IS NOT NULL
        ) x
        WHERE x.rn = 1;

        CREATE UNIQUE CLUSTERED INDEX IX_tmp_tipif ON #Tipificacion_Ultima (cartera_id);

        DROP TABLE IF EXISTS Financiera.Cartera_CUN_Asesor_Unico;

        ;WITH ASESOR_EVALUADO AS (
            SELECT
                c.[Número_de_identificación],
                CASE
                    WHEN e.Hecho_por IS NOT NULL
                     AND UPPER(e.Hecho_por) NOT LIKE '%CUN DIGITAL%'
                     AND UPPER(e.Hecho_por) NOT LIKE '%PENAGOS%'
                        THEN UPPER(e.Hecho_por)
                    WHEN u.Nombre_completo IS NOT NULL
                     AND UPPER(u.Nombre_completo) NOT LIKE '%CUN DIGITAL%'
                     AND UPPER(u.Nombre_completo) NOT LIKE '%PENAGOS%'
                        THEN UPPER(u.Nombre_completo)
                    WHEN UPPER(u.Nombre_completo) = 'CUN DIGITAL'
                     AND UPPER(c.[Propietario_de_Cartera_CUN_Name]) = 'CUN DIGITAL'
                        THEN 'Sin asignar'
                    WHEN UPPER(c.[Propietario_de_Cartera_CUN_Name]) LIKE '%CUN DIGITAL%'
                      OR UPPER(c.[Propietario_de_Cartera_CUN_Name]) LIKE '%PENAGOS%'
                        THEN 'Reasignar en CRM'
                    ELSE UPPER(c.[Propietario_de_Cartera_CUN_Name])
                END AS Nombre_Asesor_Candidato,
                ROW_NUMBER() OVER (
                    PARTITION BY c.[Número_de_identificación]
                    ORDER BY
                        CASE
                            WHEN e.Hecho_por IS NOT NULL
                             AND UPPER(e.Hecho_por) NOT LIKE '%CUN DIGITAL%'
                             AND UPPER(e.Hecho_por) NOT LIKE '%PENAGOS%'                               THEN 0
                            WHEN u.Nombre_completo IS NOT NULL
                             AND UPPER(u.Nombre_completo) NOT LIKE '%CUN DIGITAL%'
                             AND UPPER(u.Nombre_completo) NOT LIKE '%PENAGOS%'                         THEN 1
                            WHEN UPPER(u.Nombre_completo) = 'CUN DIGITAL'
                             AND UPPER(c.[Propietario_de_Cartera_CUN_Name]) = 'CUN DIGITAL'           THEN 4
                            WHEN UPPER(c.[Propietario_de_Cartera_CUN_Name]) LIKE '%CUN DIGITAL%'
                              OR UPPER(c.[Propietario_de_Cartera_CUN_Name]) LIKE '%PENAGOS%'          THEN 3
                            ELSE 2
                        END ASC,
                        TRY_CONVERT(datetime, c.[Hora_de_modificación], 103) DESC
                ) AS rn
            FROM ZOHO.CRM.Cartera_CUN c
            /* Antes era un LEFT JOIN directo al historico, que multiplicaba
               filas dentro del CTE. Ahora se une a la tipificacion ya unica. */
            LEFT JOIN #Tipificacion_Ultima e ON e.cartera_id = CONVERT(varchar(30), c.Id)
            LEFT JOIN Zoho.crm.usuarios u    ON u.Id = c.Modificado_por
            WHERE c.[Número_de_identificación] IS NOT NULL
              AND c.[Número_de_identificación] <> ''
        ),
        ASESOR_UNICO AS (
            SELECT
                [Número_de_identificación],
                Nombre_Asesor_Candidato AS Asesor_Unico
            FROM ASESOR_EVALUADO
            WHERE rn = 1
        )
        SELECT
            c.*,
            -- ESTADO_ALUMNO y PROMEDIO ya existen en Cartera_CUN (c.*); se
            -- aliasan las versiones de Cartera_Gestion para evitar colision.
            ct.ESTADO_ALUMNO               AS ESTADO_ALUMNO_GESTION,
            ct.MARCA_ACADEMICA             AS MARCA_ACADEMICA_GESTION,
            ct.PROMEDIO                    AS PROMEDIO_GESTION,
            ct.ultimoaccesoplataformlimpio AS ultimoaccesomoodle,
            m.Meta_2026,
            d.FECHA_REAL_CARGA_NDB,
            e.Hecho_por,
            e.Tipificación_anterior,
            e.Tipificación_nueva,
            -- Hora_de_la_última_actividad ya existe en Cartera_CUN (c.*); se
            -- aliasa la de la ultima tipificacion para evitar colision.
            e.Hora_de_la_última_actividad  AS Hora_ultima_actividad_tipif,
            u.Nombre_completo        AS [Usuarios.Nombre_completo],
            u.Correo_electrónico     AS [Usuarios.Correo_electrónico],
            u.Estado                 AS [Usuarios.Estado],
            u.Profile_Name           AS [Usuarios.Profile_Name],
            u.Role_Name              AS [Usuarios.Role_Name],
            a.Asesor_Unico
        INTO Financiera.Cartera_CUN_Asesor_Unico
        FROM ZOHO.CRM.Cartera_CUN c
        LEFT JOIN CUN_REPOSITORIO.Financiera.Cartera_Gestion                ct ON ct.NUMERO_CREDITO = TRY_CONVERT(numeric(18,0), c.Número_de_crédito)
        LEFT JOIN CUN_REPOSITORIO.Financiera.Cartera_Meta_Comercial_Historico m ON m.NUMERO_CREDITO = TRY_CONVERT(numeric(18,0), c.Número_de_crédito)
        /* Cartera_Destiempo_ZOHO tiene 4 NUMERO_CREDITO duplicados (8 filas).
           Sin colapsarlos, la salida traia 4 filas de mas y dejaba de estar al
           grano de Id. Se toma la fecha de carga mas reciente. */
        LEFT JOIN (
            SELECT NUMERO_CREDITO, MAX(FECHA_REAL_CARGA_NDB) AS FECHA_REAL_CARGA_NDB
            FROM CUN_REPOSITORIO.Financiera.Cartera_Destiempo_ZOHO
            GROUP BY NUMERO_CREDITO
        )                                                                      d ON d.NUMERO_CREDITO = TRY_CONVERT(numeric(18,0), c.Número_de_crédito)
        LEFT JOIN Zoho.crm.usuarios                                          u ON u.Id = c.Modificado_por
        LEFT JOIN ASESOR_UNICO                                               a ON a.[Número_de_identificación] = c.[Número_de_identificación]
        LEFT JOIN #Tipificacion_Ultima                                       e ON e.cartera_id = CONVERT(varchar(30), c.Id)
        WHERE c.[Número_de_identificación] IS NOT NULL
          AND c.[Número_de_identificación] <> '';

        DROP TABLE IF EXISTS #Tipificacion_Ultima;

        /* ---------- LOG OK -------------------------------------------------- */
        SET @filas = (SELECT COUNT(*) FROM Financiera.Cartera_CUN_Asesor_Unico);

        INSERT INTO Financiera.LOG_Cartera_CUN_Asesor_Unico
            (sp_nombre, fecha_inicio, fecha_fin, duracion_seg, filas_cargadas, estado, mensaje)
        VALUES
            ('Usp_Cartera_CUN_Asesor_Unico', @inicio, GETDATE(),
             DATEDIFF(SECOND, @inicio, GETDATE()), @filas, 'OK',
             CONCAT('Ejecucion exitosa. Filas cargadas: ', @filas));

    END TRY
    BEGIN CATCH

        INSERT INTO Financiera.LOG_Cartera_CUN_Asesor_Unico
            (sp_nombre, fecha_inicio, fecha_fin, duracion_seg, filas_cargadas, estado, mensaje)
        VALUES
            ('Usp_Cartera_CUN_Asesor_Unico', @inicio, GETDATE(),
             DATEDIFF(SECOND, @inicio, GETDATE()), NULL, 'ERROR',
             LEFT(CONCAT('Error ', ERROR_NUMBER(), ' (linea ', ERROR_LINE(), '): ', ERROR_MESSAGE()), 1000));

        -- Re-lanzar para que el job de SQL Agent tambien marque FALLO
        THROW;

    END CATCH
END;
