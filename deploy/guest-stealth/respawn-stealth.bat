@echo off
REM ============================================================================
REM respawn-stealth.bat -- Win10 guest one-click local GPU spoof re-align.
REM
REM Double-click this file. It will:
REM   1. Self-elevate to Administrator via UAC (if not already elevated).
REM   2. Run respawn-stealth-local.ps1 (in the SAME folder).
REM      -> apply-gpu-spoof.ps1 -AutoDetect picks the spoof model from the
REM         current PCI subsys, rewrites the GPU/monitor registry overlay,
REM         installs the boot-time refresh task, then reboots.
REM
REM Fully LOCAL: no host HTTP server is contacted. Pre-bake this whole folder
REM into the base image (any path works; C:\stealth\apply-gpu-spoof.ps1 from a
REM normal install is auto-located).
REM
REM Advanced: pass args straight through, e.g.
REM   respawn-stealth.bat -NoReboot
REM ============================================================================
setlocal
cd /d "%~dp0"

REM --- self-elevate via UAC if not running as Administrator --------------------
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges via UAC...
    if "%~1"=="" (
        powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    ) else (
        powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
    )
    exit /b
)

REM --- locate the local PowerShell payload next to this .bat -------------------
set "PS1=%~dp0respawn-stealth-local.ps1"
if not exist "%PS1%" (
    echo [!] respawn-stealth-local.ps1 not found next to this .bat:
    echo     %PS1%
    pause
    exit /b 1
)

REM --- run it (it re-aligns the spoof and reboots on its own) ------------------
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
set "RC=%errorlevel%"

REM If the PS script chose not to reboot (e.g. -NoReboot or an error), keep the
REM window open so the output stays readable.
if not "%RC%"=="0" (
    echo.
    echo respawn-stealth-local.ps1 exited with code %RC%.
    pause
)
endlocal
exit /b %RC%
