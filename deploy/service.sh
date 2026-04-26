#!/usr/bin/env bash
#
# nv-service.sh — host-side control of the NvDisplayContainer service
# inside the guest. Use this to toggle the streaming stack on / off
# without re-running the full installer.
#
# When playing a TP-sensitive game (DNF / 地下城与勇士), stop the
# service first: it kills NvSvcStream (~30% GPU + 15 Mbps outbound)
# and AudioSvcHost (RFB listener), so DNF's anti-cheat doesn't see
# our streaming traffic and flag it as "network instability".
#
# Usage:
#   ./nv-service.sh stop                # stop service in vm1 (default)
#   ./nv-service.sh start               # start service in vm1
#   ./nv-service.sh status              # show service + child state
#   ./nv-service.sh restart             # stop+start
#   ./nv-service.sh stop 2              # vm2
#   ./nv-service.sh stop --ip 192.168.30.191
#
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

VM_ID=${VM_ID:-1}
IP_OVERRIDE=""
GUEST_USER=${GUEST_USER:-Administrator}
GUEST_PASS=${GUEST_PASS:-123456}
ACTION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        stop|start|restart|status) ACTION="$1"; shift ;;
        --ip)        IP_OVERRIDE="$2"; shift 2 ;;
        -h|--help)   sed -n '3,16p' "$0"; exit 0 ;;
        *.*.*.*)     IP_OVERRIDE="$1"; shift ;;
        [0-9]*)      VM_ID="$1"; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

[[ -n "$ACTION" ]] || { echo "missing action (stop|start|restart|status)" >&2; exit 2; }

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

case "$ACTION" in
stop)    PS=$'sc.exe stop NvDisplayContainer\nStart-Sleep 1\nGet-Process NvSvcStream,AudioSvcHost,NvDisplayContainer -EA 0 | Format-Table Id,SessionId,Name -AutoSize | Out-String\n"=== ports ==="\nGet-NetTCPConnection -LocalPort 56789,56790 -State Listen -EA 0 | Format-Table LocalPort,State,OwningProcess -AutoSize | Out-String' ;;
start)   PS=$'sc.exe start NvDisplayContainer\nStart-Sleep 5\nGet-Process NvSvcStream,AudioSvcHost,NvDisplayContainer -EA 0 | Format-Table Id,SessionId,Name -AutoSize | Out-String\n"=== ports ==="\nGet-NetTCPConnection -LocalPort 56789,56790 -State Listen -EA 0 | Format-Table LocalPort,State,OwningProcess -AutoSize | Out-String' ;;
restart) PS=$'sc.exe stop NvDisplayContainer\nStart-Sleep 2\nsc.exe start NvDisplayContainer\nStart-Sleep 5\nGet-Process NvSvcStream,AudioSvcHost,NvDisplayContainer -EA 0 | Format-Table Id,SessionId,Name -AutoSize | Out-String' ;;
status)  PS=$'sc.exe query NvDisplayContainer\n"=== children ==="\nGet-Process NvSvcStream,AudioSvcHost,NvDisplayContainer -EA 0 | Format-Table Id,SessionId,Name -AutoSize | Out-String\n"=== ports ==="\nGet-NetTCPConnection -LocalPort 56789,56790 -EA 0 | Format-Table LocalPort,RemoteAddress,State,OwningProcess -AutoSize | Out-String\n"=== service log (last 8) ==="\nGet-Content C:\\nv\\nv-svc.log -EA 0 | Select-Object -Last 8 | Out-String' ;;
esac

echo "[nv-service] $ACTION on $IP"
exec python3 - "$IP" "$GUEST_USER" "$GUEST_PASS" "$PS" <<'PYEOF'
import sys
from pypsrp.client import Client
ip, user, pw, ps = sys.argv[1:5]
c = Client(ip, username=user, password=pw, ssl=False, auth='ntlm')
out, streams, _ = c.execute_ps(ps)
print(out)
for e in (streams.error or []):
    print(f'[err] {e}', file=sys.stderr)
PYEOF
