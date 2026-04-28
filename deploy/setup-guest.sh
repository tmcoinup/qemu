#!/usr/bin/env bash
#
# setup-guest.sh — one-shot bootstrap for everything streaming-related
# inside a guest. Run this ONCE on a freshly-installed guest (after
# Windows install + WinRM enabled + initial vGPU bring-up). On every
# subsequent code update just rerun individual installers.
#
# What it does (in order):
#   1. Install vGPU GRID 553.24 driver       (install-vgpu-driver.sh)
#   2. Install ivshmem.sys driver            (install-ivshmem-driver.sh)
#   3. Install NvDisplayContainer Windows    (install-nv-service.sh)
#      service + nv_stream_relay + AudioSvcHost, set
#      DesktopWidth/Height registry keys (default 1920x1080)
#   4. patch-grid-strings.ps1 → "GeForce GT 1030"
#      (and register a RefreshGridNames Scheduled Task at boot so
#       PnP cold-start re-enum can't undo it)
#   5. spoof-monitor.ps1 → DELL P2419H (EDID injection + monitor
#      device cycle, so 设备管理器 shows real-brand monitor name)
#
# After this finishes, on the host:
#     ./connect.sh <vm_id>
#
# Skip individual steps:
#     ./setup-guest.sh 1 --skip-vgpu       # already installed
#     ./setup-guest.sh 1 --skip-ivshmem
#     ./setup-guest.sh 1 --skip-stealth    # don't rename GPU
#     ./setup-guest.sh 1 --skip-monitor    # leave monitor as Generic
#
# Customize:
#     ./setup-guest.sh 1 --gpu-name "GeForce GTX 1050"
#     ./setup-guest.sh 1 --monitor samsung-s24f350
#     ./setup-guest.sh 1 --monitor lg-27uk850
#
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

VM_ID=${VM_ID:-1}
IP_OVERRIDE=""
GPU_NAME="${GPU_NAME:-GeForce GT 1030}"
MONITOR_BRAND="${MONITOR_BRAND:-aoc-24g2}"
INPUT_BRAND="${INPUT_BRAND:-rapoo-v303}"

SKIP_VGPU=0
SKIP_LICENSE=0
SKIP_IVSHMEM=0
SKIP_SERVICE=0
SKIP_STEALTH=0
SKIP_MONITOR=0
SKIP_INPUT=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip)            IP_OVERRIDE="$2"; shift 2 ;;
        --skip-vgpu)     SKIP_VGPU=1; shift ;;
        --skip-license)  SKIP_LICENSE=1; shift ;;
        --skip-ivshmem)  SKIP_IVSHMEM=1; shift ;;
        --skip-service)  SKIP_SERVICE=1; shift ;;
        --skip-stealth)  SKIP_STEALTH=1; shift ;;
        --skip-monitor)  SKIP_MONITOR=1; shift ;;
        --skip-input)    SKIP_INPUT=1; shift ;;
        --input)         INPUT_BRAND="$2"; shift 2 ;;
        --gpu-name)      GPU_NAME="$2"; shift 2 ;;
        --monitor)       MONITOR_BRAND="$2"; shift 2 ;;
        -h|--help)       sed -n '3,28p' "$0"; exit 0 ;;
        *.*.*.*)         IP_OVERRIDE="$1"; shift ;;
        [0-9]*)          VM_ID="$1"; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

ip_arg=""
[[ -n "$IP_OVERRIDE" ]] && ip_arg="--ip $IP_OVERRIDE"

# Always make sure the host file server is up (most installers + irm|iex need it)
if ! ss -tln 2>/dev/null | grep -q ':8080 '; then
    echo "[setup-guest] starting server.py on :8080 → /home/ubuntu/images/staging"
    nohup python3 "$(dirname "$(readlink -f "$0")")/server.py" \
        > /tmp/nv-http.log 2>&1 &
    sleep 1
fi

step() { echo; echo "════════════════════ $* ════════════════════"; }

if [[ $SKIP_VGPU -eq 0 ]]; then
    step "[1/6] vGPU 17.4 driver (553.24)"
    ./install-vgpu-driver.sh "$VM_ID" $ip_arg --no-reboot || {
        echo "[setup-guest] !! vGPU driver silent install 失败"
        echo "  这是已知 NVIDIA GRID 553.24 quirk：silent + vGPU mdev 不 work，必须 GUI 装。"
        echo "  → RDP 进 guest，双击 C:\\nv\\553.24.exe 选 Express install。"
        echo "  → 装好 reboot 后 shutdown，再 cp win10-vm1.qcow2 → win10-base.qcow2 锁 baseline，"
        echo "    之后所有 fresh VM 跳过这步。"
    }
fi

if [[ $SKIP_LICENSE -eq 0 ]]; then
    step "[2/6] vGPU license token (fastapi-dls)"
    ./install-vgpu-license.sh "$VM_ID" $ip_arg || \
        echo "[setup-guest] license 步失败 — 看 host 上 fastapi-dls 是不是在跑"
fi

if [[ $SKIP_IVSHMEM -eq 0 ]]; then
    step "[3/6] ivshmem.sys driver"
    ./install-ivshmem-driver.sh "$VM_ID" $ip_arg
fi

if [[ $SKIP_SERVICE -eq 0 ]]; then
    step "[4/6] NvDisplayContainer service + nv_stream_relay + AudioSvcHost"
    ./install-nv-service.sh "$VM_ID" $ip_arg
fi

if [[ $SKIP_STEALTH -eq 0 ]]; then
    step "[5/6] GPU name spoof: '${GPU_NAME}' + RefreshGridNames task"
    cp -f guest/patch-grid-strings.ps1 /home/ubuntu/images/staging/

    HOST_IP=$(ip -4 -o addr show br0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    [[ -n "$HOST_IP" ]] || HOST_IP="192.168.30.127"

    if [[ -z "$IP_OVERRIDE" ]]; then
        conf="${VM_ROOT:-/home/ubuntu/images/vms}/configs/vm${VM_ID}.conf"
        # shellcheck source=/dev/null
        source "$conf"
        mac_lc=${VM_MAC,,}
        IP=$(ip -4 neigh show 2>/dev/null | awk -v m="$mac_lc" \
            '$3=="br0" && tolower($5)==m && $1 ~ /^[0-9]/ {print $1; exit}')
    else
        IP="$IP_OVERRIDE"
    fi

    python3 - "$IP" "$HOST_IP" "$GPU_NAME" <<'PYEOF'
import sys
from pypsrp.client import Client
ip, host, gpu = sys.argv[1:4]
c = Client(ip, username='Administrator', password='123456', ssl=False, auth='ntlm')
ps = fr'''
$ProgressPreference = 'SilentlyContinue'
Invoke-WebRequest 'http://{host}:8080/patch-grid-strings.ps1' `
    -OutFile C:\nv\patch-grid-strings.ps1 -UseBasicParsing
& powershell.exe -ExecutionPolicy Bypass -File C:\nv\patch-grid-strings.ps1 `
    -TargetName '{gpu}'

# Register a Scheduled Task that runs the patch on every boot AND
# every interactive logon, so PnP cold-start re-enumeration can't
# undo it. Runs as SYSTEM (no UI) at boot, again as Administrator
# on logon. (memory: project_approach_b_reboot_rename.md)
$tn = 'RefreshGridNames'
Unregister-ScheduledTask -TaskName $tn -Confirm:$false -EA 0
$a = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\nv\patch-grid-strings.ps1 -TargetName "{gpu}"'
# AtStartup only — running again at logon causes Device Manager to
# flicker (registry edits trigger a PnP rescan, which redraws the
# whole 设备管理器 UI). One pass at boot is enough; cold-start PnP
# enum runs before this so we land after every reboot.
$tBoot  = New-ScheduledTaskTrigger -AtStartup
$prin   = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
$set    = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::FromMinutes(2))
Register-ScheduledTask -TaskName $tn -Action $a -Trigger $tBoot `
    -Principal $prin -Settings $set -Force | Out-Null
"  RefreshGridNames task registered (Boot, SYSTEM)"

"=== final state ==="
Get-CimInstance Win32_VideoController | Format-Table Name, Status -AutoSize | Out-String
'''
out, streams, _ = c.execute_ps(ps)
print(out)
for e in (streams.error or []): print(f'[err] {e}', file=sys.stderr)
PYEOF
fi

if [[ $SKIP_MONITOR -eq 0 ]]; then
    step "[6/6] Monitor EDID spoof: brand=${MONITOR_BRAND}"
    cp -f guest/spoof-monitor.ps1 /home/ubuntu/images/staging/

    HOST_IP=$(ip -4 -o addr show br0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    [[ -n "$HOST_IP" ]] || HOST_IP="192.168.30.127"

    if [[ -z "$IP_OVERRIDE" ]]; then
        conf="${VM_ROOT:-/home/ubuntu/images/vms}/configs/vm${VM_ID}.conf"
        # shellcheck source=/dev/null
        source "$conf"
        mac_lc=${VM_MAC,,}
        IP=$(ip -4 neigh show 2>/dev/null | awk -v m="$mac_lc" \
            '$3=="br0" && tolower($5)==m && $1 ~ /^[0-9]/ {print $1; exit}')
    else
        IP="$IP_OVERRIDE"
    fi

    python3 - "$IP" "$HOST_IP" "$MONITOR_BRAND" <<'PYEOF'
import sys
from pypsrp.client import Client
ip, host, brand = sys.argv[1:4]
c = Client(ip, username='Administrator', password='123456', ssl=False, auth='ntlm')
ps = fr'''
$ProgressPreference = 'SilentlyContinue'
Invoke-WebRequest 'http://{host}:8080/spoof-monitor.ps1' `
    -OutFile C:\nv\spoof-monitor.ps1 -UseBasicParsing
& powershell.exe -ExecutionPolicy Bypass -File C:\nv\spoof-monitor.ps1 `
    -Brand '{brand}'
'''
out, streams, _ = c.execute_ps(ps)
print(out)
for e in (streams.error or []): print(f'[err] {e}', file=sys.stderr)
PYEOF
fi

if [[ $SKIP_INPUT -eq 0 ]]; then
    step "[7/7] Input device cosmetic spoof: brand=${INPUT_BRAND}"
    cp -f guest/spoof-input.ps1 /home/ubuntu/images/staging/

    HOST_IP=$(ip -4 -o addr show br0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    [[ -n "$HOST_IP" ]] || HOST_IP="192.168.30.127"

    if [[ -z "$IP_OVERRIDE" ]]; then
        conf="${VM_ROOT:-/home/ubuntu/images/vms}/configs/vm${VM_ID}.conf"
        # shellcheck source=/dev/null
        source "$conf"
        mac_lc=${VM_MAC,,}
        IP=$(ip -4 neigh show 2>/dev/null | awk -v m="$mac_lc" \
            '$3=="br0" && tolower($5)==m && $1 ~ /^[0-9]/ {print $1; exit}')
    else
        IP="$IP_OVERRIDE"
    fi

    python3 - "$IP" "$HOST_IP" "$INPUT_BRAND" <<'PYEOF'
import sys
from pypsrp.client import Client
ip, host, brand = sys.argv[1:4]
c = Client(ip, username='Administrator', password='123456', ssl=False, auth='ntlm')
ps = fr'''
$ProgressPreference = 'SilentlyContinue'
Invoke-WebRequest 'http://{host}:8080/spoof-input.ps1' `
    -OutFile C:\nv\spoof-input.ps1 -UseBasicParsing
& powershell.exe -ExecutionPolicy Bypass -File C:\nv\spoof-input.ps1 `
    -Brand '{brand}'
'''
out, streams, _ = c.execute_ps(ps)
print(out)
for e in (streams.error or []): print(f'[err] {e}', file=sys.stderr)
PYEOF
fi

echo
echo "════════════════════ done ════════════════════"
echo "Connect from host:"
echo "    ./deploy/connect.sh ${VM_ID}"
