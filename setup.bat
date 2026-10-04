@echo off
rem Creates .venv (Python 3.11+) and installs the pinned requirements into it.
rem   setup.bat        runtime dependencies only
rem   setup.bat dev    runtime + test dependencies
setlocal
cd /d "%~dp0"

set "PYCHECK=import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)"
set "PY="
where py >nul 2>&1 && py -3 -c "%PYCHECK%" >nul 2>&1 && set "PY=py -3"
if not defined PY where python >nul 2>&1 && python -c "%PYCHECK%" >nul 2>&1 && set "PY=python"

if exist ".venv\Scripts\python.exe" goto have_venv
if not defined PY (
  echo ERROR: Python 3.11 or newer was not found.
  echo Install it from https://www.python.org/downloads/ and tick "Add python.exe to PATH",
  echo then run setup.bat again.
  goto fail
)
echo Creating .venv with: %PY%
%PY% -m venv .venv
if errorlevel 1 (
  echo ERROR: could not create .venv
  goto fail
)

:have_venv
".venv\Scripts\python.exe" -c "%PYCHECK%" >nul 2>&1
if errorlevel 1 (
  echo ERROR: the existing .venv uses Python older than 3.11.
  echo Delete the .venv folder and run setup.bat again.
  goto fail
)
for /f "delims=" %%v in ('".venv\Scripts\python.exe" --version') do echo Using .venv: %%v

set "REQ=requirements.txt"
if /i "%~1"=="dev" set "REQ=requirements-dev.txt"
echo Installing %REQ% into .venv ...
".venv\Scripts\python.exe" -m pip install --disable-pip-version-check -r "%REQ%"
if errorlevel 1 (
  echo ERROR: pip install failed.
  goto fail
)

if not exist "config.toml" (
  copy /y "config.example.toml" "config.toml" >nul
  echo Created config.toml from config.example.toml. Edit it before starting the app.
)
echo.
echo Setup complete. Start the app with run.bat
exit /b 0

:fail
rem keep the window open when started by double-click
echo %cmdcmdline% | find /i "/c" >nul && pause
exit /b 1
