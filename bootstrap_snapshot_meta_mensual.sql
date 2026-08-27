/*===========================================================================================
  BACKUP MENSUAL DE LA META  --  CORRER ANTES DEL ALTER PROCEDURE
  -------------------------------------------------------------------------------------------
  Objeto      : [Financiera].[Cartera_Meta_Comercial_Snapshot_Mensual]  (tabla NUEVA)
  Autor       : Analitica financiera - Universidad CUN
  Proposito   : Guardar una foto COMPLETA de Cartera_Meta_Comercial_Historico por cada mes,
                antes de que la corrida de ese mes la refresque.

  POR QUE EXISTE
  --------------
  Hasta hoy el paso 5a solo refrescaba 6 campos y el resto quedaba congelado en el primer
  ingreso del credito a la meta. Con el refresco TOTAL, cada corrida pisa las 44 columnas
  vivas: TOTAL, CORRIENTE, los GR*, EMAIL, TEL_CELULAR, WHATSAPP, etc. Sin esta tabla, el
  valor que tenia la cartera al cierre de cada mes se perderia para siempre.

  Con el backup mes a mes, refrescar todo deja de ser destructivo: el estado vivo va en
  Cartera_Meta_Comercial_Historico y la serie historica en esta tabla.

  QUE SIGNIFICA ANIO_MES_SNAPSHOT
  -------------------------------
  Es el mes de la CORRIDA que estaba por ejecutarse, y la foto se toma ANTES de refrescar.
  O sea: la fila con ANIO_MES_SNAPSHOT = '202609' contiene el estado con el que arranco
  septiembre, que es el CIERRE de agosto. Se etiqueta con el mes de la corrida para que
  cuadre con @Periodo y con la bitacora Meta_2026 del propio SP.

  LO QUE ESTE SCRIPT SIEMBRA
  --------------------------
  La foto de HOY (mes en curso), que es el estado acumulado antes del primer refresco total.
  Es la unica copia de los valores congelados desde junio; sin ella se pierden en la corrida
  del 1 de septiembre.

  Idempotente: se puede correr las veces que haga falta. Si la foto del mes ya existe, se
  reemplaza (no se duplica).

  ORDEN DE DESPLIEGUE
  -------------------
    1. Este script
    2. deploy alter_usp_foto_meta_snapshot_mensual.sql
    3. Validar con las consultas del final
===========================================================================================*/

SET NOCOUNT ON;

DECLARE @Periodo VARCHAR(6) = FORMAT(GETDATE(), 'yyyyMM');
DECLARE @sql NVARCHAR(MAX), @cols NVARCHAR(MAX);

/*-------------------------------------------------------------------------------------------
  1) Crear la tabla si no existe. El esquema se deriva de la tabla viva, no se escribe a mano.
     ANIO_MES_SNAPSHOT encabeza (es la llave de particion logica) y la columna de auditoria
     va al final, segun la convencion del repo.
-------------------------------------------------------------------------------------------*/
IF OBJECT_ID('Financiera.Cartera_Meta_Comercial_Snapshot_Mensual', 'U') IS NULL
BEGIN
    SELECT TOP 0
        CAST(NULL AS VARCHAR(6))  AS ANIO_MES_SNAPSHOT,
        H.*,
        CAST(NULL AS DATETIME)    AS AUD_FECHA_SNAPSHOT
    INTO Financiera.Cartera_Meta_Comercial_Snapshot_Mensual
    FROM Financiera.Cartera_Meta_Comercial_Historico H;

    ALTER TABLE Financiera.Cartera_Meta_Comercial_Snapshot_Mensual
        ALTER COLUMN ANIO_MES_SNAPSHOT VARCHAR(6) NOT NULL;

    -- Clustered por mes: toda consulta de la serie filtra o agrupa por ANIO_MES_SNAPSHOT.
    -- NO es unico a proposito: NUMERO_CREDITO es nullable en la tabla origen y un indice
    -- unico abortaria la corrida si algun dia entra mas de una fila sin credito.
    CREATE CLUSTERED INDEX IX_SnapMeta_Mes_Credito
        ON Financiera.Cartera_Meta_Comercial_Snapshot_Mensual (ANIO_MES_SNAPSHOT, NUMERO_CREDITO);

    PRINT 'Cartera_Meta_Comercial_Snapshot_Mensual creada.';
END
ELSE
    PRINT 'Cartera_Meta_Comercial_Snapshot_Mensual ya existia (no-op).';

/*-------------------------------------------------------------------------------------------
  2) Sembrar la foto del mes en curso (estado PREVIO al primer refresco total).
     La lista de columnas se arma por NOMBRE desde la interseccion de las dos tablas, asi que
     una columna nueva se propaga sola y el mapeo nunca es posicional.
-------------------------------------------------------------------------------------------*/
SELECT @cols = STRING_AGG(CAST(QUOTENAME(s.name) AS NVARCHAR(MAX)), ', ')
               WITHIN GROUP (ORDER BY s.column_id)
FROM sys.columns s
WHERE s.object_id = OBJECT_ID('Financiera.Cartera_Meta_Comercial_Snapshot_Mensual')
  AND s.name NOT IN ('ANIO_MES_SNAPSHOT', 'AUD_FECHA_SNAPSHOT')
  AND EXISTS (SELECT 1 FROM sys.columns h
              WHERE h.object_id = OBJECT_ID('Financiera.Cartera_Meta_Comercial_Historico')
                AND h.name = s.name);

IF @cols IS NULL
BEGIN
    RAISERROR('No se pudo armar la lista de columnas: la tabla de snapshot no comparte columnas con Cartera_Meta_Comercial_Historico.', 16, 1);
    RETURN;
END

SET @sql = N'
    DELETE FROM Financiera.Cartera_Meta_Comercial_Snapshot_Mensual
     WHERE ANIO_MES_SNAPSHOT = @P;

    INSERT INTO Financiera.Cartera_Meta_Comercial_Snapshot_Mensual
        (ANIO_MES_SNAPSHOT, ' + @cols + N', AUD_FECHA_SNAPSHOT)
    SELECT @P, ' + @cols + N', GETDATE()
      FROM Financiera.Cartera_Meta_Comercial_Historico;';

EXEC sp_executesql @sql, N'@P VARCHAR(6)', @P = @Periodo;

PRINT 'Foto ' + @Periodo + ' sembrada: ' + CAST(@@ROWCOUNT AS VARCHAR(20)) + ' filas.';
GO

/*-------------------------------------------------------------------------------------------
  Verificacion
-------------------------------------------------------------------------------------------*/
SELECT ANIO_MES_SNAPSHOT,
       COUNT(*)                                   AS FILAS,
       COUNT(DISTINCT NUMERO_CREDITO)             AS CREDITOS,
       CAST(SUM(TOTAL)/1000000 AS DECIMAL(18,1))  AS TOTAL_MM,
       MIN(AUD_FECHA_SNAPSHOT)                    AS TOMADA
FROM Financiera.Cartera_Meta_Comercial_Snapshot_Mensual
GROUP BY ANIO_MES_SNAPSHOT
ORDER BY ANIO_MES_SNAPSHOT;

-- Cuadre contra la tabla viva: la foto del mes en curso debe coincidir fila a fila.
SELECT (SELECT COUNT(*) FROM Financiera.Cartera_Meta_Comercial_Historico)              AS FILAS_VIVAS,
       (SELECT COUNT(*) FROM Financiera.Cartera_Meta_Comercial_Snapshot_Mensual
         WHERE ANIO_MES_SNAPSHOT = FORMAT(GETDATE(), 'yyyyMM'))                        AS FILAS_FOTO;
GO
