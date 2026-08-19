@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Optimize-Guest.ps1" -Mode Verify -StartupDelayMs 0
set "result=%errorlevel%"
echo.
pause
exit /b %result%

