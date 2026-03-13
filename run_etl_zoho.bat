@echo off
REM ============================================================
REM  ETL Zoho Llamadas — Lanzador
REM  Ejecutar 2 veces al dia entre semana via Programador de Tareas
REM ============================================================

SET SCRIPT_DIR=C:\Users\jefferson_patinom\Desktop\ETL_FCT_Ventas
SET PYTHON=C:\Users\JEFFER~1\ONEDRI~1\DASHBO~1\PYTHON~1\ETLS_D~1\VENV~1\Scripts\python.exe

cd /d "%SCRIPT_DIR%"

echo [%DATE% %TIME%] Iniciando ETL_Zoho_llamadas...
"%PYTHON%" ETL_Zoho_llamadas.py

IF %ERRORLEVEL% NEQ 0 (
    echo [%DATE% %TIME%] ERROR: El script termino con codigo %ERRORLEVEL%
    exit /b %ERRORLEVEL%
)

echo [%DATE% %TIME%] ETL finalizado correctamente.
exit /b 0
