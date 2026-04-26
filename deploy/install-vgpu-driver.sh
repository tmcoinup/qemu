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
# Driver asset must be staged at /home/ubuntu/Downloads/nv-deploy/553.24.exe
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
    conf="vm-configs/vm${VM_ID}.conf"
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

# Sanity: the installer needs to be reachable
if ! curl -sfI "$BASE_URL/553.24.exe" >/dev/null 2>&1; then
    echo "[install-vgpu] $BASE_URL/553.24.exe not reachable"
    echo "                cp /home/ubuntu/Downloads/vGPU17.4/Guest_Drivers/553.24_*.exe \\"
    echo "                   /home/ubuntu/Downloads/nv-deploy/553.24.exe"
    echo "                and confirm http.server is up on 8080"
    exit 1
fi

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
$all = pnputil /enum-drivers
$matches = [regex]::Matches($all,
    'Published name\s*:\s*(oem\d+\.inf)[\s\S]*?Provider\s*:\s*NVIDIA')
foreach ($m in $matches) {{
    $oem = $m.Groups[1].Value
    Write-Host "  delete $oem"
    pnputil /delete-driver $oem /uninstall /force 2>&1 | Out-Null
}}
"  removed $($matches.Count) packages"

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

Write-Host '[4/6] Pull 553.24 installer ({base}/553.24.exe)' -Fore Cyan
Invoke-WebRequest "{base}/553.24.exe" -OutFile C:\nv\553.24.exe -UseBasicParsing
"  $((Get-Item C:\nv\553.24.exe).Length) bytes"

Write-Host '[5/6] Run silent install (-s -clean -noreboot)' -Fore Cyan
$p = Start-Process C:\nv\553.24.exe -ArgumentList '-s','-clean','-noreboot' -Wait -PassThru
"  installer exit code: $($p.ExitCode)"

Write-Host '[6/6] Verify driver bound' -Fore Cyan
Get-CimInstance Win32_VideoController | Format-Table Name, DriverVersion, Status, ConfigManagerErrorCode -AutoSize | Out-String

{reboot}
'''
out, streams, _ = c.execute_ps(ps)
print(out)
for e in (streams.error or []):
    print(f'[err] {e}', file=sys.stderr)
PYEOF
