@echo off
setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"

set "REPORT=%USERPROFILE%\Desktop\G11-D3D12-Native-Probe.txt"
>"%REPORT%" echo G-11 native D3D12 OPTIONS5 probe
>>"%REPORT%" echo.
>>"%REPORT%" echo [x86]
>>"%REPORT%" D3D12CapabilityProbe32.exe --require-tier-zero
set "EXIT32=!ERRORLEVEL!"
>>"%REPORT%" echo EXIT_CODE=!EXIT32!
>>"%REPORT%" echo.
>>"%REPORT%" echo [x64]
>>"%REPORT%" D3D12CapabilityProbe64.exe --require-tier-zero
set "EXIT64=!ERRORLEVEL!"
>>"%REPORT%" echo EXIT_CODE=!EXIT64!

type "%REPORT%"
echo.
echo Report: %REPORT%
echo.
if not "!EXIT32!"=="0" echo Native x86 capability does not match tier-zero contract.
if not "!EXIT64!"=="0" echo Native x64 capability does not match tier-zero contract.
pause
