@echo off
REM Crear entorno virtual en esta misma carpeta
python -m venv .venv
call .venv\Scripts\activate.bat
pip install --upgrade pip
pip install -r requirements.txt
echo.
echo Entorno listo. Para activarlo manualmente:
echo   .venv\Scripts\activate.bat
pause
