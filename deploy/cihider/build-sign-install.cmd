@echo off
REM ============================================================================
REM cihider : build -> self-sign -> install (end-to-end, run in guest)
REM
REM Prerequisites on the guest:
REM   - Visual Studio 2022 Build Tools with "Desktop development with C++"
REM   - Windows Driver Kit 10.0.22621 (or newer) integrated with VS
REM   - PowerShell 5.1+ (stock Win10)
REM   - Admin shell (elevated cmd)
REM
REM Drop the full deploy\cihider folder onto the guest (e.g. C:\cihider\)
REM then run this script as Administrator.
REM
REM After it completes, confirm with:
REM   sc query CiHider
REM   wmic path Win32_SystemDriver where Name='CiHider' get State,StartMode
REM Reboot.  On next boot, verify with:
REM   fltmc.exe loaddriver                          (not useful for system-start)
REM   PowerShell Get-WinEvent -LogName System | Where-Object Id -eq 7036 |
REM     Where-Object Message -Match CiHider
REM   Or cat "$env:SystemRoot\inf\setupapi.dev.log" for install diag
REM ============================================================================

setlocal EnableDelayedExpansion
cd /d "%~dp0"

REM --- 0. sanity check ---------------------------------------------------------
net session >nul 2>&1 || (
    echo [!] must be run from an elevated cmd
    exit /b 1
)

REM --- 1. locate VS + WDK environment ------------------------------------------
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" (
    echo [!] vswhere.exe not found, install VS2022 Build Tools first
    exit /b 1
)

for /f "usebackq delims=" %%i in (`"%VSWHERE%" -latest -prerelease -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set VSINSTALL=%%i
if not defined VSINSTALL (
    echo [!] Visual Studio installation not detected
    exit /b 1
)

call "%VSINSTALL%\Common7\Tools\VsDevCmd.bat" -arch=amd64 -host_arch=amd64 || exit /b 1

REM --- 2. build ----------------------------------------------------------------
echo [1/6] msbuild cihider.vcxproj
msbuild cihider.vcxproj /nologo /m /p:Configuration=Release /p:Platform=x64 ^
    /p:SignMode=Off /p:EnableInf2cat=false /verbosity:minimal || exit /b 1

set "OUTDIR=%~dp0bin\x64"
if not exist "%OUTDIR%\cihider.sys" (
    echo [!] build did not produce cihider.sys
    exit /b 1
)

REM --- 3. self-signing cert ----------------------------------------------------
echo [2/6] ensure self-signing cert exists
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0sign-cert.ps1" ^
    -Subject "CN=CihSigner" -PfxPath "%~dp0cih-signer.pfx" ^
    -CerPath "%~dp0cih-signer.cer" -Password cih || exit /b 1

REM --- 4. stage INF next to sys + build catalog --------------------------------
echo [3/6] stage INF + build catalog
copy /y "%~dp0cihider.inf" "%OUTDIR%\cihider.inf" >nul
pushd "%OUTDIR%"

REM locate WDK binaries (inf2cat, signtool) -- use delayed expansion to
REM avoid issues with parentheses inside %ProgramFiles(x86)%.
set "KIT=!ProgramFiles(x86)!\Windows Kits\10"
set "KITBIN=!KIT!\bin\10.0.22621.0"
if not exist "!KITBIN!\x86\Inf2Cat.exe" set "KITBIN=!KIT!\bin\10.0.19041.0"
if not exist "!KITBIN!\x86\Inf2Cat.exe" (
    echo [!] Inf2Cat.exe not found under !KIT!\bin
    exit /b 1
)
set "INF2CAT=!KITBIN!\x86\Inf2Cat.exe"
set "SIGNTOOL=!KITBIN!\x64\signtool.exe"
if not exist "!SIGNTOOL!" set "SIGNTOOL=!KITBIN!\x86\signtool.exe"

REM Remove the MSBuild driver-package subdir that contains a duplicate INF
REM without cihider.sys -- inf2cat would otherwise choke on that incomplete
REM dir and fail signability test 22.9.1.
if exist "cihider" rmdir /s /q "cihider"

REM inf2cat requires a manifest directory; just pass the directory itself
"%INF2CAT%" /driver:. /os:10_x64 /verbose || exit /b 1

REM --- 5. sign sys + cat with test cert ---------------------------------------
echo [4/6] signtool sign cihider.sys + cihider.cat
REM Try with RFC3161 timestamp; fall back to untimestamped if the timestamp
REM server is unreachable.  For a self-signed, locally trusted driver, the
REM absence of a timestamp is harmless.
"%SIGNTOOL%" sign /fd SHA256 /f "%~dp0cih-signer.pfx" /p cih ^
    /tr http://timestamp.digicert.com /td SHA256 ^
    cihider.sys cihider.cat
if errorlevel 1 (
    echo [!] timestamp server unreachable; signing without /tr
    "%SIGNTOOL%" sign /fd SHA256 /f "%~dp0cih-signer.pfx" /p cih ^
        cihider.sys cihider.cat || exit /b 1
)

REM --- 6. trust the test cert ---------------------------------------------------
echo [5/6] import cert into Root + TrustedPublisher
certutil -f -addstore root "%~dp0cih-signer.cer" >nul
certutil -f -addstore trustedpublisher "%~dp0cih-signer.cer" >nul

REM --- 7. pnputil install ------------------------------------------------------
echo [6/6] pnputil /add-driver cihider.inf /install
pnputil /add-driver cihider.inf /install
if errorlevel 1 (
    echo [!] pnputil returned non-zero - this is OK if "driver was already installed".
    echo [!] Full log: %SystemRoot%\INF\setupapi.dev.log
)

REM Ensure the service is SYSTEM_START even if the INF was parsed differently:
sc config CiHider start= system >nul 2>&1

popd
echo.
echo === cihider install complete ===
echo Reboot to engage.  After reboot:
echo   sc query CiHider            (should be RUNNING)
echo   PowerShell Get-CimInstance Win32_OperatingSystem | Select-Object -Prop *
echo   PowerShell "[CodeIntegrity]::Query()"   (if harness present)
echo.
endlocal
exit /b 0
