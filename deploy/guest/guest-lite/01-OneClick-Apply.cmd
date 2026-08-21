@echo off
setlocal
chcp 65001 >nul
title G-11 Windows 10 Guest Lite - One Click Apply
cd /d "%~dp0"
echo G-11 Windows 10 Guest Lite
echo.
echo This turns off Defender, firewall, updates, cloud/consumer background items,
echo then applies the VM performance profile. It will request UAC and one warning.
echo Do not close the window while it is working.
echo.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0G11-Guest-Lite.ps1" -Mode Apply
set "result=%errorlevel%"
echo.
if "%result%"=="0" (
  echo SUCCESS - restart Windows, then run 02-Audit.cmd.
) else if "%result%"=="3" (
  echo PARTIAL - read the messages above; rollback remains available.
) else (
  echo NOT APPLIED - fix the reported prerequisite and run again.
)
echo.
pause
exit /b %result%
