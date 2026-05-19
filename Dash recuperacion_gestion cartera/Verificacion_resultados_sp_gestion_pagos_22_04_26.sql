USE [CUN_REPOSITORIO]
GO

DECLARE	@return_value int

EXEC	@return_value = [Financiera].[SP_Cartera_Total]

SELECT	'Return Value' = @return_value

GO
---------------------VERIFICACION TABLAS --------------------------

SELECT *
FROM [Financiera].[Creditos_pagos_CTAYUDA]

SELECT *
FROM Financiera.Cartera_Total

SELECT  *
FROM Financiera.Cartera_Gestion

SELECT *
FROM Financiera.Cartera_Foto_Ayer

SELECT *
FROM Financiera.Cartera

SELECT * 
FROM Financiera.LOG_Ejecucion_SP