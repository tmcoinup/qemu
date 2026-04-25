#!/usr/bin/env bash
#
# install-stream-server.sh — host-side one-liner to deploy the H.264
# streaming stack into a guest. Pulls install-stream-server.ps1 +
# ffmpeg.exe via the existing nv-deploy HTTP server (port 8080) and
# runs the .ps1 inside guest as Administrator via PSRP.
#
# Usage:
#   ./install-stream-server.sh                 # vm1 default
#   ./install-stream-server.sh <vm_id>
#   ./install-stream-server.sh <ip>
#   ./install-stream-server.sh --ip 192.168.30.191
#   ./install-stream-server.sh --uninstall
#
# Prereqs on host:
#   - python3 with pypsrp installed
#   - HTTP server serving /home/ubuntu/Downloads/nv-deploy/ on TCP 8080
#     (already running on this box; restart with:
#      `cd /home/ubuntu/Downloads/nv-deploy && nohup python3 -m http.server 8080 &`)
#   - install-stream-server.ps1 + ffmpeg.exe staged in nv-deploy/
#
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

VM_ID=${VM_ID:-1}
IP_OVERRIDE=""
GUEST_USER=${GUEST_USER:-Administrator}
GUEST_PASS=${GUEST_PASS:-123456}
UNINSTALL=0
EXTRA_PARAMS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip)         IP_OVERRIDE="$2"; shift 2 ;;
        --uninstall)  UNINSTALL=1; shift ;;
        --framerate)  EXTRA_PARAMS+=( "-FrameRate" "$2" ); shift 2 ;;
        --bitrate)    EXTRA_PARAMS+=( "-Bitrate" "$2" ); shift 2 ;;
        --videoport)  EXTRA_PARAMS+=( "-VideoPort" "$2" ); shift 2 ;;
        -h|--help)    sed -n '3,16p' "$0"; exit 0 ;;
        *.*.*.*)      IP_OVERRIDE="$1"; shift ;;
        [0-9]*)       VM_ID="$1"; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

# Discover guest IP
if [[ -z "$IP_OVERRIDE" ]]; then
    conf="vm-configs/vm${VM_ID}.conf"
    [[ -f "$conf" ]] || { echo "missing $conf" >&2; exit 1; }
    # shellcheck source=/dev/null
    source "$conf"
    mac_lc=${VM_MAC,,}
    IP=$(ip -4 neigh show 2>/dev/null | awk -v m="$mac_lc" \
        '$3=="br0" && tolower($5)==m && $1 ~ /^[0-9]/ {print $1; exit}')
    [[ -n "$IP" ]] || { echo "no IP for $VM_MAC in ARP — guest up?" >&2; exit 1; }
else
    IP="$IP_OVERRIDE"
fi

# Auto-detect host IP on br0 (for the BaseUrl param)
HOST_IP=$(ip -4 -o addr show br0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
[[ -n "$HOST_IP" ]] || HOST_IP="192.168.30.127"
BASE_URL="http://${HOST_IP}:8080"

# Sanity: HTTP server up + script + ffmpeg present
for f in install-stream-server.ps1 ffmpeg.exe; do
    if ! curl -sfI "$BASE_URL/$f" >/dev/null 2>&1; then
        echo "[install] $BASE_URL/$f not reachable — is the http.server up?"
        echo "[install] start it with:"
        echo "    cd /home/ubuntu/Downloads/nv-deploy && nohup python3 -m http.server 8080 &"
        exit 1
    fi
done

# Stage latest install-stream-server.ps1 from src to nv-deploy (in case of edits)
cp -f guest/install-stream-server.ps1 /home/ubuntu/Downloads/nv-deploy/install-stream-server.ps1

echo "[install] guest IP: $IP    host IP: $HOST_IP    BaseUrl: $BASE_URL"
echo "[install] mode    : $([[ $UNINSTALL -eq 1 ]] && echo UNINSTALL || echo INSTALL)"

UNINSTALL_FLAG=""
[[ $UNINSTALL -eq 1 ]] && UNINSTALL_FLAG="-Uninstall"

# Build the PowerShell argument list passed to the .ps1
PARAMS_PS="-BaseUrl '$BASE_URL' $UNINSTALL_FLAG ${EXTRA_PARAMS[*]:-}"

exec python3 - "$IP" "$GUEST_USER" "$GUEST_PASS" "$PARAMS_PS" <<'PYEOF'
import sys
from pypsrp.client import Client
ip, user, pw, params = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
c = Client(ip, username=user, password=pw, ssl=False, auth='ntlm')
ps = fr'''
$ProgressPreference = 'SilentlyContinue'
New-Item -Path C:\nv -ItemType Directory -Force | Out-Null
Invoke-WebRequest "{params.split(chr(39))[1]}/install-stream-server.ps1" `
    -OutFile C:\nv\install-stream-server.ps1 -UseBasicParsing
"  pulled $((Get-Item C:\nv\install-stream-server.ps1).Length) bytes"
& powershell.exe -ExecutionPolicy Bypass -File C:\nv\install-stream-server.ps1 {params}
'''
out, streams, _ = c.execute_ps(ps)
print(out)
for e in (streams.error or []):
    print(f'[err] {e}', file=sys.stderr)
PYEOF
