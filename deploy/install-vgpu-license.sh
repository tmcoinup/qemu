#!/usr/bin/env bash
#
# install-vgpu-license.sh — 把 fastapi-dls 颁发的 license token 推进 guest，
# 重启 NVIDIA license 服务，验证 vGPU GRID driver 切到 Licensed。
#
# 没有 license token 时 GRID 553.24 driver 会持续 ConfigManagerErrorCode=43
# (memory project_licensing_stuck)，桌面卡 std VGA 640x480。
#
# 前置:
#   - host 上 fastapi-dls 在跑 (Docker container；./deploy/host/setup-fastapi-dls.sh)
#   - guest 已装 GRID 553.24 driver (./deploy/install-vgpu-driver.sh 1)
#
# Usage:
#   ./install-vgpu-license.sh              # vm1 default
#   ./install-vgpu-license.sh <vm_id>
#   ./install-vgpu-license.sh --ip 192.168.30.191
#
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

VM_ID=${VM_ID:-1}
IP_OVERRIDE=""
GUEST_USER=${GUEST_USER:-Administrator}
GUEST_PASS=${GUEST_PASS:-123456}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip)        IP_OVERRIDE="$2"; shift 2 ;;
        -h|--help)   sed -n '3,16p' "$0"; exit 0 ;;
        *.*.*.*)     IP_OVERRIDE="$1"; shift ;;
        [0-9]*)      VM_ID="$1"; shift ;;
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
TOKEN_URL="https://${HOST_IP}/-/client-token"

echo "[license] guest=$IP host=$HOST_IP fastapi-dls=$TOKEN_URL"

# 1) host 端拉 token
TOKEN=/tmp/vm${VM_ID}-license.tok
curl -ksSf "$TOKEN_URL" -o "$TOKEN" || {
    echo "[license] 拉 token 失败 — host fastapi-dls Docker 没起？"
    echo "          docker ps | grep dls 或 ./deploy/host/setup-fastapi-dls.sh"
    exit 1
}
TOKEN_BYTES=$(stat -c%s "$TOKEN")
echo "[license] token: ${TOKEN_BYTES} bytes"

# 2) 通过 staging HTTP server 暴露给 guest 拉
DEPLOY=/home/ubuntu/images/staging
cp -f "$TOKEN" "$DEPLOY/client_configuration_token.tok"
BASE_URL="http://${HOST_IP}:8080"

# 3) guest 内拷 token + 重启 NVIDIA service + 验证
exec python3 - "$IP" "$GUEST_USER" "$GUEST_PASS" "$BASE_URL" <<'PYEOF'
import sys
from pypsrp.client import Client
ip, user, pw, base = sys.argv[1:5]
c = Client(ip, username=user, password=pw, ssl=False, auth='ntlm')

ps = fr'''
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Continue'

Write-Host '[1/4] Sync time with host (UTC) — license check is TZ-sensitive' -Fore Cyan
# memory project_licensing_stuck: guest RTC 时区跟 host 不一致就 license 失败
w32tm /resync /force 2>&1 | Out-Host
"  current guest time: $(Get-Date -Format 'u')"

Write-Host '[2/4] Drop token into NVIDIA ClientConfigToken dir' -Fore Cyan
$dst = 'C:\Program Files\NVIDIA Corporation\vGPU Licensing\ClientConfigToken'
New-Item -ItemType Directory -Force -Path $dst | Out-Null
Invoke-WebRequest "{base}/client_configuration_token.tok" `
    -OutFile "$dst\client_configuration_token.tok" -UseBasicParsing
"  $($dst)\client_configuration_token.tok = $((Get-Item "$dst\client_configuration_token.tok").Length) bytes"

Write-Host '[3/4] Restart NVDisplay.ContainerLocalSystem (license daemon)' -Fore Cyan
Restart-Service NVDisplay.ContainerLocalSystem -Force -EA 0
Start-Sleep 12

Write-Host '[4/4] Verify license + driver status' -Fore Cyan
$smi = & 'C:\Windows\System32\nvidia-smi.exe' -q 2>&1
$smi | Select-String -Pattern 'License|Driver Version|Product Name' | Out-Host

Write-Host ''
Write-Host '=== Win32_VideoController ==='
Get-CimInstance Win32_VideoController | Format-Table Name, DriverVersion, Status, ConfigManagerErrorCode -AutoSize | Out-String
'''
out, streams, _ = c.execute_ps(ps)
print(out)
for e in (streams.error or []):
    print(f'[err] {e}', file=sys.stderr)
PYEOF
