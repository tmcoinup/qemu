@echo off
setlocal EnableExtensions
title VMate G-11 Sysprep Template Seal

fltmc >nul 2>&1
if errorlevel 1 (
  powershell.exe -NoLogo -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

set "ANSWER=%~dp0g11-sysprep-clone.xml"
if not exist "%ANSWER%" (
  echo [ERROR] Missing %ANSWER%
  pause
  exit /b 2
)

echo This will generalize Windows, skip interactive OOBE in every clone,
echo and fully shut down this template. Do not boot this source again after success.
echo.
choice /C YN /N /M "Continue? [Y/N] "
if errorlevel 2 exit /b 0

powercfg.exe /hibernate off
if errorlevel 1 (
  echo [ERROR] Could not disable hibernation/Fast Startup.
  pause
  exit /b 1
)

"%SystemRoot%\System32\Sysprep\Sysprep.exe" /generalize /oobe /shutdown /unattend:"%ANSWER%"
if errorlevel 1 (
  echo [ERROR] Sysprep failed. Check %%WINDIR%%\System32\Sysprep\Panther\setuperr.log
  pause
  exit /b 1
)
