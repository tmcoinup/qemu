#!/usr/bin/env bash
#
# install-vgpu-driver.sh — host one-liner to (re-)install the
# NVIDIA vGPU 17.4 GRID driver (553.24 DCH) inside the guest.
#
# When the GeForce DCH driver lands via Windows Update on a vGPU
# guest, NVIDIA's anti-VM check trips and the device goes Error 43.
# The fix is to wipe every NVIDIA driver/device, push the GRID
# 553.24 .exe via HTTP, and run its silent installer.
#
# Driver asset must be staged at /home/ubuntu/images/staging/553.24.exe
# (already cp'd from ~/Downloads/vGPU17.4/Guest_Drivers/553.24_*.exe).
#
# Usage:
#   ./install-vgpu-driver.sh              # vm1 default
#   ./install-vgpu-driver.sh <vm_id>
#   ./install-vgpu-driver.sh --ip 192.168.30.191
#   ./install-vgpu-driver.sh --no-reboot  # don't reboot after install
#
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

VM_ID=${VM_ID:-1}
IP_OVERRIDE=""
GUEST_USER=${GUEST_USER:-Administrator}
GUEST_PASS=${GUEST_PASS:-123456}
NO_REBOOT=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip)         IP_OVERRIDE="$2"; shift 2 ;;
        --no-reboot)  NO_REBOOT=1; shift ;;
        -h|--help)    sed -n '3,16p' "$0"; exit 0 ;;
        *.*.*.*)      IP_OVERRIDE="$1"; shift ;;
        [0-9]*)       VM_ID="$1"; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [[ -z "$IP_OVERRIDE" ]]; then
    conf="${VM_ROOT:-/home/ubuntu/images/vms}/configs/vm${VM_ID}.conf"
    [[ -f "$conf" ]] || { echo "missing $conf" >&2; exit 1; }
    # shellcheck source=/dev/null
    source "$conf"
    mac_lc=${VM_MAC,,}
    IP=$(ip -4 neigh show 2>/dev/null | awk -v m="$mac_lc" \
        '$3=="br0" && tolower($5)==m && $1 ~ /^[0-9]/ {print $1; exit}')
    [[ -n "$IP" ]] || { echo "no IP for $VM_MAC" >&2; exit 1; }
else
    IP="$IP_OVERRIDE"
fi

HOST_IP=$(ip -4 -o addr show br0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
[[ -n "$HOST_IP" ]] || HOST_IP="192.168.30.127"
BASE_URL="http://${HOST_IP}:8080"

# Sanity: setup.exe + pnputil-fallback zip 都要可达
for asset in 553.24.exe 553.24-display-driver.zip; do
    if ! curl -sfI "$BASE_URL/$asset" >/dev/null 2>&1; then
        echo "[install-vgpu] $BASE_URL/$asset not reachable"
        if [[ "$asset" == "553.24.exe" ]]; then
            echo "  → cp ~/Downloads/vGPU17.4/Guest_Drivers/553.24_*.exe \\"
            echo "       /home/ubuntu/images/staging/553.24.exe"
        else
            echo "  → 7z x /home/ubuntu/images/staging/553.24.exe -o/tmp/553.24 -y && \\"
            echo "    cd /tmp/553.24 && \\"
            echo "    zip -qr /home/ubuntu/images/staging/553.24-display-driver.zip Display.Driver"
        fi
        echo "  确认 http server 在 8080: python3 server.py"
        exit 1
    fi
done

echo "[install-vgpu] guest=$IP  reboot=$([[ $NO_REBOOT -eq 1 ]] && echo no || echo yes)"

REBOOT_CMD=""
[[ $NO_REBOOT -eq 0 ]] && REBOOT_CMD='Write-Host "rebooting in 10s..." -Fore Yellow; Start-Sleep 10; shutdown /r /t 0'

exec python3 - "$IP" "$GUEST_USER" "$GUEST_PASS" "$BASE_URL" "$REBOOT_CMD" <<'PYEOF'
import sys
from pypsrp.client import Client
ip, user, pw, base, reboot = sys.argv[1:6]
c = Client(ip, username=user, password=pw, ssl=False, auth='ntlm')

ps = fr'''
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Continue'
New-Item -Path C:\nv -ItemType Directory -Force | Out-Null

Write-Host '[1/6] Wipe every NVIDIA oem driver package' -Fore Cyan
# 不靠 pnputil 输出 grep（中英文格式飘忽）— 直接走 CIM Win32_PnPSignedDriver
# 拿到所有 NVIDIA driver 的 InfName，pnputil /delete-driver 强卸。
$nvInfs = Get-CimInstance Win32_PnPSignedDriver -EA 0 |
    Where-Object {{ $_.Manufacturer -match 'NVIDIA' -or $_.Description -match 'NVIDIA' }} |
    Select-Object -ExpandProperty InfName -Unique |
    Where-Object {{ $_ -match '^oem\d+\.inf$' }}
foreach ($inf in $nvInfs) {{
    Write-Host "  delete $inf"
    pnputil /delete-driver $inf /uninstall /force 2>&1 | Out-Null
}}
"  removed $(@($nvInfs).Count) packages"

# memory project_grid_driver_partial：之前装一半留下 nvlddmkm.sys 缺 +
# INF 在 的状态，下次 installer 看到同版本 INF skip 拷贝，永远修不好。
# 强制把 NVIDIA system32 残留 sys/dll 全清，让 installer 必须从头来。
Write-Host '  scrub C:\Windows\System32 NVIDIA leftovers'
$drv = 'C:\Windows\System32\drivers'
$sys32 = 'C:\Windows\System32'
$pats = @('nvlddmkm.sys','nvkflt.sys','nvvad*.sys','nvgpu*.sys',
          'nvapi*.dll','nvcuda*.dll','nvml*.dll','nvopencl*.dll',
          'nvwgf2um*.dll','nvd3dum*.dll','nvoptix*.dll')
foreach ($p in $pats) {{
    Get-ChildItem -Path $drv,$sys32 -Filter $p -EA 0 | ForEach-Object {{
        try {{ Remove-Item $_.FullName -Force -EA Stop }} catch {{}}
    }}
}}

Write-Host '[2/6] Remove NVIDIA PCI devices (current + phantom)' -Fore Cyan
$env:DEVMGR_SHOW_NONPRESENT_DEVICES = '1'
Get-PnpDevice | Where-Object {{ $_.InstanceId -like 'PCI\VEN_10DE*' }} |
    ForEach-Object {{
        Write-Host "  remove $($_.InstanceId)"
        pnputil /remove-device $_.InstanceId /force 2>&1 | Out-Null
    }}

Write-Host '[3/6] Uninstall any NVIDIA user-space packages' -Fore Cyan
Get-Package | Where-Object {{ $_.Name -like '*NVIDIA*' }} |
    ForEach-Object {{
        Write-Host "  remove $($_.Name)"
        $_ | Uninstall-Package -Force -EA SilentlyContinue | Out-Null
    }}

Write-Host '[3.5/6] Kill any leftover installer / setup processes' -Fore Cyan
# 上一次跑卡死/没退干净时，C:\nv\553.24.exe 自解压器或它解到
# C:\NVIDIA\... 的 setup.exe 还会握着 553.24.exe 文件锁，导致下一步
# Invoke-WebRequest -OutFile 写不进去（"being used by another process"）。
Get-Process -EA 0 | Where-Object {{
    $_.Path -and ($_.Path -eq 'C:\nv\553.24.exe' -or
                  $_.Path -like 'C:\NVIDIA\*' -or
                  $_.Name -in @('setup','setup.tmp','installer','nvi'))
}} | ForEach-Object {{
    Write-Host "  kill $($_.Name) pid=$($_.Id)"
    $_ | Stop-Process -Force -EA 0
}}
Start-Sleep -Seconds 2
Remove-Item C:\nv\553.24.exe -Force -EA 0

Write-Host '[4/6] Pull 553.24 installer ({base}/553.24.exe)' -Fore Cyan
Invoke-WebRequest "{base}/553.24.exe" -OutFile C:\nv\553.24.exe -UseBasicParsing
"  $((Get-Item C:\nv\553.24.exe).Length) bytes"

Write-Host '[5/6] Run silent install (-s -clean -noreboot)' -Fore Cyan
$p = Start-Process C:\nv\553.24.exe -ArgumentList '-s','-clean','-noreboot' -Wait -PassThru
"  installer exit code: $($p.ExitCode)"

# 实测：GRID 553.24 silent install 在 fresh LTSC 上 self-extract 阶段
# 直接退 -436207360（连 setup.log 都不生成），原因不明（疑似 InstallShield
# runtime 缺 / SmartScreen 阻断）。用 pnputil 直接装 INF 作 fallback —
# host 端预解压 Display.Driver/ 打成 zip 给 guest 拉，绕过 setup.exe。
if ($p.ExitCode -ne 0 -or -not (Test-Path 'C:\Windows\System32\drivers\nvlddmkm.sys')) {{
    Write-Host '  !! setup.exe failed — falling back to pnputil /add-driver' -Fore Yellow
    Invoke-WebRequest "{base}/553.24-display-driver.zip" `
        -OutFile C:\nv\553.24-dd.zip -UseBasicParsing
    "  zip: $((Get-Item C:\nv\553.24-dd.zip).Length) bytes"
    Remove-Item C:\nv\553.24-dd -Recurse -Force -EA 0
    Expand-Archive C:\nv\553.24-dd.zip -DestinationPath C:\nv\553.24-dd -Force
    $infs = Get-ChildItem 'C:\nv\553.24-dd\Display.Driver\*.inf'
    "  found $($infs.Count) INF files"
    foreach ($inf in $infs) {{
        Write-Host "  pnputil /add-driver $($inf.Name) /install"
        & pnputil /add-driver $inf.FullName /install 2>&1 | Out-Host
    }}
}}

Write-Host '[5.5/6] Block Windows Update from replacing the NVIDIA driver' -Fore Cyan
# Without this, WU silently swaps GRID 553.24 → GeForce DCH 32.0.15.6094
# (post-2024-08-14 build) which trips NVIDIA anti-VM and the device goes
# back to Error 43.
#   ExcludeWUDriversInQualityUpdate=1 = WU 永不下 driver 包
#   SearchOrderConfig=0                = pnputil 也不查 WU
$wukey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
New-Item -Path $wukey -Force | Out-Null
Set-ItemProperty -Path $wukey -Name 'ExcludeWUDriversInQualityUpdate' -Type DWord -Value 1
$dskey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching'
New-Item -Path $dskey -Force | Out-Null
Set-ItemProperty -Path $dskey -Name 'SearchOrderConfig' -Type DWord -Value 0
"  policies set: ExcludeWUDriversInQualityUpdate=1, SearchOrderConfig=0"

Write-Host '[6/6] Verify driver bound' -Fore Cyan
Get-CimInstance Win32_VideoController | Format-Table Name, DriverVersion, Status, ConfigManagerErrorCode -AutoSize | Out-String

{reboot}
'''
out, streams, _ = c.execute_ps(ps)
print(out)
for e in (streams.error or []):
    print(f'[err] {e}', file=sys.stderr)
PYEOF
