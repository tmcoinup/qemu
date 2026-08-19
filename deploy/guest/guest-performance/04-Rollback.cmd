@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Optimize-Guest.ps1" -Mode Rollback
set "result=%errorlevel%"
echo.
pause
exit /b %result%

