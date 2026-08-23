@echo off
setlocal
chcp 65001 >nul
title G-11 Windows 10 Guest Lite - Rollback
cd /d "%~dp0"
echo This restores the exact registry, firewall, power, service, and task baseline
echo and attempts to re-register every original Appx package removed by this tool.
echo NVIDIA DRS and surviving DNF process priorities are restored too.
echo Temporary files deleted during Apply cannot be recreated.
echo.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0G11-Guest-Lite.ps1" -Mode Rollback
set "result=%errorlevel%"
echo.
if "%result%"=="0" (
  echo ROLLBACK SUCCESS - restart Windows.
) else (
  echo ROLLBACK NEEDS ATTENTION - state was kept for another attempt.
)
pause
exit /b %result%
