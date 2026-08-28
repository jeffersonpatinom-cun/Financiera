/*===========================================================================================
  AUTOMATIZACION: Cartera_CUN enriquecida + Asesor_Unico
  -------------------------------------------------------------------------------------------
  Objeto   : [Financiera].[Usp_Cartera_CUN_Asesor_Unico] -> Financiera.Cartera_CUN_Asesor_Unico
  Autor    : Analitica financiera - Universidad CUN
  Fecha    : 2026-08-28
  Requiere : login sysadmin o miembro de SQLAgentOperatorRole. La cuenta de analitica NO
             tiene permiso de lectura sobre msdb.dbo.sysschedules, asi que este script se
             entrega para que lo corra quien administre el Agent.

  POR QUE HACE FALTA
  ------------------
  Hoy el SP se corre A MANO. Bitacora LOG_Cartera_CUN_Asesor_Unico: 10, 13, 21, 24 y 26 de
  agosto. La ultima carga dejo 305.332 filas; al 2026-08-28 ZOHO.CRM.Cartera_CUN ya tiene
  308.062, o sea la tabla vive dos dias atrasada y la brecha crece sola. Peor: los
  enriquecimientos salen de Cartera_Gestion, que se reconstruye TODOS los dias a las 6:00,
  asi que la foto envejece aunque el CRM no se mueva.

  DEPENDENCIA DE ORDEN (esto es lo que decide el diseño)
  ------------------------------------------------------
  El SP lee Financiera.Cartera_Gestion. Si corre ANTES del ETL diario, enriquece con la
  cartera de ayer y el resultado es silenciosamente viejo -- no falla, solo miente.
  Por eso la OPCION A encadena el SP como paso 2 del job que YA reconstruye la cartera,
  en vez de programar un job aparte a una hora adivinada: el orden queda garantizado por
  construccion y no por una diferencia de horas que alguien pueda romper moviendo un job.

  Medido: JOB_Cartera_Total arranca 06:00:00 y dura entre 12 y 20 minutos
  (26-ago 12m50s, 27-ago 20m18s, 28-ago 16m16s). Usp_Cartera_CUN_Asesor_Unico tarda
  entre 2m31s y 4m49s. El job encadenado quedaria en ~15-25 min.
===========================================================================================*/

USE msdb;
GO

/*===========================================================================================
  OPCION A (RECOMENDADA) -- encadenar como paso 2 de JOB_Cartera_Total
  -------------------------------------------------------------------------------------------
  TRAMPA: el paso 1 hoy tiene on_success_action = 1 ("Salir informando exito"). Si se agrega
  el paso 2 sin tocar eso, el job TERMINA en el paso 1 y el paso nuevo NO SE EJECUTA NUNCA,
  sin error ni aviso. Por eso el sp_update_jobstep de abajo no es opcional.
===========================================================================================*/

IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'JOB_Cartera_Total')
BEGIN
    RAISERROR('No existe JOB_Cartera_Total. Revisar el nombre antes de continuar.', 16, 1);
    RETURN;
END

-- Idempotente: si el paso ya existe, se elimina para recrearlo con la definicion de abajo.
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobsteps s
           JOIN msdb.dbo.sysjobs j ON j.job_id = s.job_id
           WHERE j.name = N'JOB_Cartera_Total'
             AND s.step_name = N'Cartera_CUN enriquecida + Asesor_Unico')
BEGIN
    DECLARE @sid INT = (SELECT s.step_id FROM msdb.dbo.sysjobsteps s
                        JOIN msdb.dbo.sysjobs j ON j.job_id = s.job_id
                        WHERE j.name = N'JOB_Cartera_Total'
                          AND s.step_name = N'Cartera_CUN enriquecida + Asesor_Unico');
    EXEC msdb.dbo.sp_delete_jobstep @job_name = N'JOB_Cartera_Total', @step_id = @sid;
END
GO

-- 1) El paso 1 debe CONTINUAR al siguiente, no salir. Sin esto el paso 2 es letra muerta.
EXEC msdb.dbo.sp_update_jobstep
     @job_name          = N'JOB_Cartera_Total',
     @step_id           = 1,
     @on_success_action = 3;      -- 3 = ir al siguiente paso   (antes: 1 = salir con exito)
GO

-- 2) Paso nuevo.
--    on_fail_action = 2 (salir informando error) a proposito: si esto falla se quiere ver
--    el job en rojo. Cartera_Total ya termino y quedo intacta -- el paso 2 no la toca --,
--    asi que el rojo señala "la tabla de Zoho quedo vieja", no "la cartera fallo".
--    El detalle del fallo queda ademas en Financiera.LOG_Cartera_CUN_Asesor_Unico.
EXEC msdb.dbo.sp_add_jobstep
     @job_name       = N'JOB_Cartera_Total',
     @step_name      = N'Cartera_CUN enriquecida + Asesor_Unico',
     @subsystem      = N'TSQL',
     @database_name  = N'CUN_REPOSITORIO',
     @command        = N'EXEC Financiera.Usp_Cartera_CUN_Asesor_Unico;',
     @on_success_action = 1,      -- ultimo paso: salir con exito
     @on_fail_action    = 2,      -- salir con error
     @retry_attempts    = 1,
     @retry_interval    = 5;
GO

-- 3) Asegurar que el job siga arrancando por el paso 1.
EXEC msdb.dbo.sp_update_job @job_name = N'JOB_Cartera_Total', @start_step_id = 1;
GO

/*-------------------------------------------------------------------------------------------
  Verificacion de la OPCION A
-------------------------------------------------------------------------------------------*/
SELECT s.step_id, s.step_name, s.on_success_action, s.on_fail_action, s.database_name,
       LEFT(s.command, 60) AS COMANDO
FROM msdb.dbo.sysjobsteps s
JOIN msdb.dbo.sysjobs j ON j.job_id = s.job_id
WHERE j.name = N'JOB_Cartera_Total'
ORDER BY s.step_id;
-- Esperado: paso 1 con on_success_action = 3, paso 2 con 1 / 2.
GO


/*===========================================================================================
  OPCION B -- job independiente diario (solo si NO se quiere tocar JOB_Cartera_Total)
  -------------------------------------------------------------------------------------------
  Desventaja real: la hora queda fija a las 07:00 y JOB_Cartera_Total ya se paso de ahi una
  vez -- el 27-ago arranco 06:00 y duro 20m18s. Un dia largo (o un reintento) hace que este
  job lea la cartera A MEDIO RECONSTRUIR o la de ayer. No falla: entrega datos viejos.
  Si se usa esta opcion, dejar margen amplio y revisar la bitacora del SP con frecuencia.

  Descomentar el bloque completo para usarlo.
===========================================================================================*/
/*
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'JOB_Cartera_CUN_Asesor_Unico')
    EXEC msdb.dbo.sp_delete_job @job_name = N'JOB_Cartera_CUN_Asesor_Unico',
                                @delete_unused_schedule = 1;

DECLARE @jobId BINARY(16);

EXEC msdb.dbo.sp_add_job
     @job_name    = N'JOB_Cartera_CUN_Asesor_Unico',
     @enabled     = 1,
     @description = N'Materializa Financiera.Cartera_CUN_Asesor_Unico: Cartera_CUN de Zoho enriquecida con Cartera_Gestion, meta comercial, destiempo NDB, ultima tipificacion, usuarios, calendario y Asesor_Unico. DEBE correr despues del ETL que reconstruye Cartera_Gestion.',
     @job_id      = @jobId OUTPUT;

EXEC msdb.dbo.sp_add_jobstep
     @job_name       = N'JOB_Cartera_CUN_Asesor_Unico',
     @step_name      = N'Ejecutar Usp_Cartera_CUN_Asesor_Unico',
     @subsystem      = N'TSQL',
     @database_name  = N'CUN_REPOSITORIO',
     @command        = N'EXEC Financiera.Usp_Cartera_CUN_Asesor_Unico;',
     @retry_attempts = 1,
     @retry_interval = 5;

EXEC msdb.dbo.sp_add_jobschedule
     @job_name           = N'JOB_Cartera_CUN_Asesor_Unico',
     @name               = N'Diario 07:00',
     @freq_type          = 4,          -- diario
     @freq_interval      = 1,
     @active_start_time  = 70000;      -- 07:00:00

EXEC msdb.dbo.sp_add_jobserver
     @job_name   = N'JOB_Cartera_CUN_Asesor_Unico',
     @server_name = N'(local)';
*/
GO


/*===========================================================================================
  DESPUES DE LA PRIMERA CORRIDA AUTOMATICA -- validacion
===========================================================================================*/
/*
USE CUN_REPOSITORIO;

-- 1) La bitacora del SP debe mostrar la corrida de hoy en OK.
SELECT TOP 5 * FROM Financiera.LOG_Cartera_CUN_Asesor_Unico ORDER BY id DESC;

-- 2) La tabla debe cuadrar 1:1 con el CRM (mismo filtro que usa el SP).
SELECT (SELECT COUNT(*) FROM Financiera.Cartera_CUN_Asesor_Unico) AS FILAS_TABLA,
       (SELECT COUNT(*) FROM ZOHO.CRM.Cartera_CUN
         WHERE [Número_de_identificación] IS NOT NULL
           AND [Número_de_identificación] <> '')                  AS FILAS_CRM;

-- 3) Las 12 columnas nuevas deben existir y venir pobladas.
SELECT COUNT(*) AS COLUMNAS FROM sys.columns
WHERE object_id = OBJECT_ID('Financiera.Cartera_CUN_Asesor_Unico');   -- esperado: 110

SELECT CLASIFICACION_CARTERA, COUNT(*) AS FILAS
FROM Financiera.Cartera_CUN_Asesor_Unico
GROUP BY CLASIFICACION_CARTERA ORDER BY FILAS DESC;
*/
