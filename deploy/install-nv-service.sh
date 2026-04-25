#!/usr/bin/env bash
#
# install-nv-service.sh — one-line host-side deploy of the streaming
# stack as a Windows Service inside the guest.
#
# Pulls install-nv-service.ps1 + NvDisplayContainer.exe + ffmpeg.exe
# (renamed NvSvcStream.exe on guest) + AudioSvcHost.exe via the existing
# nv-deploy HTTP server (port 8080), then runs the .ps1 inside the guest
# as Administrator over PSRP.
#
# Usage:
#   ./install-nv-service.sh                 # vm1 default
#   ./install-nv-service.sh <vm_id>
#   ./install-nv-service.sh <ip>
#   ./install-nv-service.sh --ip 192.168.30.191
#   ./install-nv-service.sh --uninstall
#
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

VM_ID=${VM_ID:-1}
IP_OVERRIDE=""
GUEST_USER=${GUEST_USER:-Administrator}
GUEST_PASS=${GUEST_PASS:-123456}
UNINSTALL=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip)         IP_OVERRIDE="$2"; shift 2 ;;
        --uninstall)  UNINSTALL=1; shift ;;
        -h|--help)    sed -n '3,16p' "$0"; exit 0 ;;
        *.*.*.*)      IP_OVERRIDE="$1"; shift ;;
        [0-9]*)       VM_ID="$1"; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

# Discover guest IP via vm-configs
if [[ -z "$IP_OVERRIDE" ]]; then
    conf="vm-configs/vm${VM_ID}.conf"
    [[ -f "$conf" ]] || { echo "missing $conf" >&2; exit 1; }
    # shellcheck source=/dev/null
    source "$conf"
    mac_lc=${VM_MAC,,}
    IP=$(ip -4 neigh show 2>/dev/null | awk -v m="$mac_lc" \
        '$3=="br0" && tolower($5)==m && $1 ~ /^[0-9]/ {print $1; exit}')
    [[ -n "$IP" ]] || { echo "no IP for $VM_MAC in ARP" >&2; exit 1; }
else
    IP="$IP_OVERRIDE"
fi

HOST_IP=$(ip -4 -o addr show br0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
[[ -n "$HOST_IP" ]] || HOST_IP="192.168.30.127"
BASE_URL="http://${HOST_IP}:8080"

# Stage latest .ps1 + binaries to nv-deploy
DEPLOY=/home/ubuntu/Downloads/nv-deploy
cp -f guest/install-nv-service.ps1 "$DEPLOY/install-nv-service.ps1"

# Sanity: HTTP server up + all assets present
for f in install-nv-service.ps1 NvDisplayContainer.exe AudioSvcHost.exe; do
    if ! curl -sfI "$BASE_URL/$f" >/dev/null 2>&1; then
        echo "[install] $BASE_URL/$f not reachable"
        echo "[install] make sure http.server is running:"
        echo "    cd $DEPLOY && nohup python3 -m http.server 8080 &"
        exit 1
    fi
done
# stream binary: either renamed or original ffmpeg
if   curl -sfI "$BASE_URL/NvSvcStream.exe" >/dev/null 2>&1; then :;
elif curl -sfI "$BASE_URL/ffmpeg.exe"      >/dev/null 2>&1; then :;
else echo "[install] neither NvSvcStream.exe nor ffmpeg.exe served"; exit 1; fi

echo "[install] guest=$IP host=$HOST_IP base=$BASE_URL  mode=$([[ $UNINSTALL -eq 1 ]] && echo UNINSTALL || echo INSTALL)"

UNINSTALL_FLAG=""
[[ $UNINSTALL -eq 1 ]] && UNINSTALL_FLAG="-Uninstall"

exec python3 - "$IP" "$GUEST_USER" "$GUEST_PASS" "$BASE_URL" "$UNINSTALL_FLAG" <<'PYEOF'
import sys
from pypsrp.client import Client
ip, user, pw, base, uflag = sys.argv[1:6]
c = Client(ip, username=user, password=pw, ssl=False, auth='ntlm')
ps = fr'''
$ProgressPreference = 'SilentlyContinue'
New-Item -Path C:\nv -ItemType Directory -Force | Out-Null
Invoke-WebRequest "{base}/install-nv-service.ps1" `
    -OutFile C:\nv\install-nv-service.ps1 -UseBasicParsing
"  pulled $((Get-Item C:\nv\install-nv-service.ps1).Length) bytes"
& powershell.exe -ExecutionPolicy Bypass -File C:\nv\install-nv-service.ps1 -BaseUrl "{base}" {uflag}
'''
out, streams, _ = c.execute_ps(ps)
print(out)
for e in (streams.error or []):
    print(f'[err] {e}', file=sys.stderr)
PYEOF
