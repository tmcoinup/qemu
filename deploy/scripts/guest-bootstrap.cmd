@echo off
REM guest-bootstrap.cmd  -- pull by curl from http://10.0.2.2:8787/bootstrap.cmd
REM Runs as Administrator (elevated via Ctrl+Shift+Enter in run box).
REM
REM Purpose:
REM   1. set Administrator password to 123456 so RDP NLA allows login
REM   2. enable RDP service + firewall rule, disable NLA for self-signed
REM   3. install QEMU Guest Agent if present (optional)
REM   4. pull & mount virtio-win.iso, pnputil install viogpudo
REM   5. apply GPU name spoof via registry
REM
REM After this script finishes, the host can xfreerdp to 127.0.0.1:13390
REM as Administrator:123456 and continue automation.

setlocal enableextensions
set HOST=10.0.2.2
set PORT=8787
set TMP=C:\stealth
if not exist %TMP% mkdir %TMP%
cd /d %TMP%

echo [1/6] set Administrator password
net user Administrator 123456 /active:yes

echo [2/6] enable RDP service + firewall
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 0 /f
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" /v UserAuthentication /t REG_DWORD /d 0 /f
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" /v SecurityLayer /t REG_DWORD /d 1 /f
netsh advfirewall firewall set rule group="remote desktop" new enable=Yes
sc config TermService start= auto
net start TermService

echo [3/6] fetch virtio-win.iso
curl -sfo %TMP%\virtio-win.iso http://%HOST%:%PORT%/virtio-win.iso
if errorlevel 1 (
  echo FAIL: curl virtio-win.iso
  exit /b 3
)

echo [4/6] mount ISO
powershell -NoProfile -Command ^
  "$iso = Mount-DiskImage -ImagePath '%TMP%\virtio-win.iso' -PassThru; $vol = ($iso | Get-Volume).DriveLetter; Set-Content -Path '%TMP%\iso-drive.txt' -Value $vol"
for /f %%D in (%TMP%\iso-drive.txt) do set ISODRV=%%D
echo virtio-win mounted at %ISODRV%:

echo [5/6] install viogpudo (10 x64)
set INF=%ISODRV%:\viogpudo\w10\amd64\viogpudo.inf
if not exist "%INF%" set INF=%ISODRV%:\viogpudo\2k19\amd64\viogpudo.inf
if not exist "%INF%" set INF=%ISODRV%:\viogpudo\w11\amd64\viogpudo.inf
echo INF path: %INF%
pnputil /add-driver "%INF%" /install

echo [6/6] fetch + apply GPU spoof
curl -sfo %TMP%\apply-gpu-spoof.ps1 http://%HOST%:%PORT%/apply-gpu-spoof.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File %TMP%\apply-gpu-spoof.ps1

echo === bootstrap done ===
endlocal
