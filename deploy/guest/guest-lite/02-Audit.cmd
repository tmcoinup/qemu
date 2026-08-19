@echo off
setlocal
chcp 65001 >nul
title G-11 Windows 10 Guest Lite - Audit
cd /d "%~dp0"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0G11-Guest-Lite.ps1" -Mode Audit
set "result=%errorlevel%"
echo.
echo Reports are saved under C:\ProgramData\G11GuestLite\reports
pause
exit /b %result%
