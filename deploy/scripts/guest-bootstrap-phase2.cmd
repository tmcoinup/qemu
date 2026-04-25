@echo off
REM Phase 2: fetch virtio-win iso, mount, install viogpudo driver, apply GPU spoof.
REM Runs after phase1 has already set Administrator password and enabled RDP.

setlocal enableextensions
set HOST=10.0.2.2
set PORT=8787
set TMP=C:\stealth
if not exist %TMP% mkdir %TMP%
cd /d %TMP%

echo [1/4] fetch virtio-win.iso from %HOST%:%PORT%
curl -fso %TMP%\virtio-win.iso http://%HOST%:%PORT%/virtio-win.iso
if errorlevel 1 (
  echo FAIL: curl virtio-win.iso
  exit /b 3
)
echo iso size:
dir %TMP%\virtio-win.iso | findstr virtio-win

echo [2/4] mount ISO
powershell -NoProfile -Command "$iso = Mount-DiskImage -ImagePath '%TMP%\virtio-win.iso' -PassThru; $vol = ($iso | Get-Volume).DriveLetter; Set-Content -Path '%TMP%\iso-drive.txt' -Value $vol"
for /f %%D in (%TMP%\iso-drive.txt) do set ISODRV=%%D
echo virtio-win mounted at %ISODRV%:

echo [3/4] install viogpudo driver
set INF=%ISODRV%:\viogpudo\w10\amd64\viogpudo.inf
if not exist "%INF%" set INF=%ISODRV%:\viogpudo\2k19\amd64\viogpudo.inf
if not exist "%INF%" set INF=%ISODRV%:\viogpudo\w11\amd64\viogpudo.inf
echo INF path: %INF%
if exist "%INF%" (
  pnputil /add-driver "%INF%" /install
) else (
  echo WARN: viogpudo.inf not found, listing iso root
  dir %ISODRV%:\ /b
)

echo [4/4] fetch + apply GPU spoof (registry rebrand)
curl -fso %TMP%\apply-gpu-spoof.ps1 http://%HOST%:%PORT%/apply-gpu-spoof.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File %TMP%\apply-gpu-spoof.ps1 > %TMP%\spoof.log 2>&1
type %TMP%\spoof.log

echo === phase2 done ===
endlocal
