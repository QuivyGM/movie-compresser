@echo off
rem Starts the app with the project's .venv (never the global Python).
setlocal
cd /d "%~dp0"

if not exist ".venv\Scripts\python.exe" (
  echo ERROR: .venv not found. Run setup.bat first.
  goto fail
)
if not defined MC_CONFIG if not exist "config.toml" (
  echo ERROR: config.toml not found. Copy config.example.toml to config.toml and edit it.
  goto fail
)
".venv\Scripts\python.exe" -m app.main %*
if errorlevel 1 goto fail
exit /b 0

:fail
rem keep the window open when started by double-click
echo %cmdcmdline% | find /i "/c" >nul && pause
exit /b 1
