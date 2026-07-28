@echo off
setlocal

set "REPAIR_SCRIPT=%~dp0repair-sysprep.ps1"
set "REPORT_ROOT=%~dp0sysprep-report"

if not exist "%REPAIR_SCRIPT%" (
    echo ERROR: repair-sysprep.ps1 not found beside this launcher.
    pause
    exit /b 2
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass ^
    -File "%REPAIR_SCRIPT%" -RunSysprep -ExportDirectory "%REPORT_ROOT%"
set "REPAIR_RESULT=%ERRORLEVEL%"

if not "%REPAIR_RESULT%"=="0" (
    echo.
    echo Sysprep repair stopped with exit code %REPAIR_RESULT%.
    echo Review the sysprep-report directory before retrying.
    pause
)

exit /b %REPAIR_RESULT%
