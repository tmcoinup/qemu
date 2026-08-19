@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Optimize-Guest.ps1" -Mode Apply -StartupDelayMs 0
set "result=%errorlevel%"
echo.
pause
exit /b %result%

