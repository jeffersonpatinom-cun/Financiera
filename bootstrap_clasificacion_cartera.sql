/*===========================================================================================
  BOOTSTRAP de CLASIFICACION_CARTERA  --  CORRER ANTES DEL ALTER PROCEDURE
  -------------------------------------------------------------------------------------------
  Objeto      : [Financiera].[Cartera_Total] / [Financiera].[Cartera_Gestion]
  Autor       : Analitica financiera - Universidad CUN
  Proposito   : Crear la columna en las tablas FISICAS antes de desplegar el SP.

  POR QUE ES OBLIGATORIO
  ----------------------
  El CTE `Cartera_Total_Dedup` de SP_Cartera_Total lee la tabla FISICA
  `Financiera.Cartera_Total`. La resolucion diferida de SQL Server valida esa columna en
  tiempo de COMPILACION, asi que el ALTER PROCEDURE falla con error 207 (Invalid column
  name) si la columna todavia no existe en la tabla.

  En runtime el DROP + SELECT INTO recrea la tabla con el tipo y el valor reales, asi que
  el ancho declarado aqui es solo para que compile: NO sobrevive a la primera corrida.
  (Ya paso antes: una columna se creo varchar(50) en el bootstrap y el SELECT INTO la dejo
  en varchar(102).)

  Idempotente: se puede correr las veces que haga falta.

  ORDEN DE DESPLIEGUE
  -------------------
    1. Este script
    2. deploy alter_sp_cartera_total_clasificacion.sql
    3. deploy alter_usp_foto_meta_calendario.sql
    4. Correr el SP (job de las 6am) y validar
===========================================================================================*/

IF COL_LENGTH('Financiera.Cartera_Total', 'CLASIFICACION_CARTERA') IS NULL
BEGIN
    ALTER TABLE Financiera.Cartera_Total ADD CLASIFICACION_CARTERA varchar(20) NULL;
    PRINT 'Cartera_Total.CLASIFICACION_CARTERA creada.';
END
ELSE
    PRINT 'Cartera_Total.CLASIFICACION_CARTERA ya existia (no-op).';
GO

IF COL_LENGTH('Financiera.Cartera_Gestion', 'CLASIFICACION_CARTERA') IS NULL
BEGIN
    ALTER TABLE Financiera.Cartera_Gestion ADD CLASIFICACION_CARTERA varchar(20) NULL;
    PRINT 'Cartera_Gestion.CLASIFICACION_CARTERA creada.';
END
ELSE
    PRINT 'Cartera_Gestion.CLASIFICACION_CARTERA ya existia (no-op).';
GO

/*-------------------------------------------------------------------------------------------
  Verificacion
-------------------------------------------------------------------------------------------*/
SELECT OBJECT_NAME(object_id) AS TABLA, name AS COLUMNA, TYPE_NAME(user_type_id) AS TIPO, max_length
FROM sys.columns
WHERE name = 'CLASIFICACION_CARTERA'
ORDER BY TABLA;
GO
