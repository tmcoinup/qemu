#!/usr/bin/env bash
#
# install-ivshmem-driver.sh — push the Looking-Glass-style ivshmem
# Windows driver into the guest and pnputil-install it.
#
# The driver itself (ivshmem.inf + ivshmem.sys + ivshmem.cat) is NOT
# tracked in this repo — it ships as a pre-signed third-party blob from
# the Looking Glass project. Place the three files under
#   /home/ubuntu/images/staging/ivshmem-driver/
# before running this script (or set IVSHMEM_DRIVER_DIR=/path).
#
# Where to get the driver:
#   - Looking Glass releases: https://looking-glass.io/artifact/B7
#     (download the host Windows MSI, extract with msiextract /
#     7z, find the driver folder)
#   - Or build from https://github.com/gnif/LookingGlass/tree/master/module
#     (needs Microsoft EV cert for production install — test mode otherwise)
#
# Usage:
#   ./install-ivshmem-driver.sh                # vm1 default
#   ./install-ivshmem-driver.sh <vm_id>
#   ./install-ivshmem-driver.sh <ip>
#   ./install-ivshmem-driver.sh --uninstall
#
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

VM_ID=${VM_ID:-1}
IP_OVERRIDE=""
GUEST_USER=${GUEST_USER:-Administrator}
GUEST_PASS=${GUEST_PASS:-123456}
UNINSTALL=0
DRIVER_DIR="${IVSHMEM_DRIVER_DIR:-/home/ubuntu/images/staging/ivshmem-driver}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip)         IP_OVERRIDE="$2"; shift 2 ;;
        --uninstall)  UNINSTALL=1; shift ;;
        --driver-dir) DRIVER_DIR="$2"; shift 2 ;;
        -h|--help)    sed -n '3,18p' "$0"; exit 0 ;;
        *.*.*.*)      IP_OVERRIDE="$1"; shift ;;
        [0-9]*)       VM_ID="$1"; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

# Find a working driver dir
if [[ $UNINSTALL -eq 0 ]]; then
    if [[ ! -d "$DRIVER_DIR" ]]; then
        cat >&2 <<EOF
[install-ivshmem-driver] $DRIVER_DIR not found.

Place the Looking-Glass ivshmem driver files there:
  $DRIVER_DIR/
    ivshmem.inf
    ivshmem.sys
    ivshmem.cat

Get them from https://looking-glass.io/artifact/B7 (Windows host MSI;
unpack and copy the 'driver' subdirectory).
EOF
        exit 1
    fi
    for f in ivshmem.inf ivshmem.sys ivshmem.cat; do
        [[ -f "$DRIVER_DIR/$f" ]] || { echo "missing $DRIVER_DIR/$f" >&2; exit 1; }
    done
fi

# Discover guest IP
if [[ -z "$IP_OVERRIDE" ]]; then
    conf="${VM_ROOT:-/home/ubuntu/images/vms}/configs/vm${VM_ID}.conf"
    [[ -f "$conf" ]] || { echo "missing $conf" >&2; exit 1; }
    # shellcheck source=/dev/null
    source "$conf"
    mac_lc=${VM_MAC,,}
    IP=$(ip -4 neigh show 2>/dev/null | awk -v m="$mac_lc" \
        '$3=="br0" && tolower($5)==m && $1 ~ /^[0-9]/ {print $1; exit}')
    [[ -n "$IP" ]] || { echo "no IP for $VM_MAC; is the VM up?" >&2; exit 1; }
else
    IP="$IP_OVERRIDE"
fi

HOST_IP=$(ip -4 -o addr show br0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
[[ -n "$HOST_IP" ]] || HOST_IP="192.168.30.127"

# Stage driver under staging/ so http.server picks it up
DEPLOY=/home/ubuntu/images/staging
if [[ $UNINSTALL -eq 0 ]]; then
    mkdir -p "$DEPLOY/ivshmem-driver"
    if [[ "$(readlink -f "$DRIVER_DIR")" != "$(readlink -f "$DEPLOY/ivshmem-driver")" ]]; then
        for f in ivshmem.inf ivshmem.sys ivshmem.cat; do
            cp -f "$DRIVER_DIR/$f" "$DEPLOY/ivshmem-driver/$f"
        done
        echo "[install-ivshmem-driver] staged 3 files at $DEPLOY/ivshmem-driver/"
    else
        echo "[install-ivshmem-driver] driver already in $DEPLOY/ivshmem-driver/"
    fi
fi

echo "[install-ivshmem-driver] guest=$IP  mode=$([[ $UNINSTALL -eq 1 ]] && echo UNINSTALL || echo INSTALL)"

if [[ $UNINSTALL -eq 1 ]]; then
    read -r -d '' PS <<'EOPS' || true
$inf = (Get-WindowsDriver -Online | Where-Object OriginalFileName -like '*ivshmem.inf*') | Select-Object -First 1
if ($inf) { pnputil.exe /delete-driver $inf.Driver /uninstall /force; "uninstalled $($inf.Driver)" }
else      { "no ivshmem driver installed" }
EOPS
else
    read -r -d '' PS <<EOPS || true
\$base = "http://${HOST_IP}:8080/ivshmem-driver"
New-Item -Path C:\\nv\\ivshmem-driver -ItemType Directory -Force | Out-Null
foreach (\$f in @('ivshmem.inf','ivshmem.sys','ivshmem.cat')) {
    Invoke-WebRequest "\$base/\$f" -OutFile "C:\\nv\\ivshmem-driver\\\$f" -UseBasicParsing
    "  pulled \$f (\$((Get-Item \"C:\\nv\\ivshmem-driver\\\$f\").Length) bytes)"
}
"=== pnputil install ==="
& pnputil.exe /add-driver C:\\nv\\ivshmem-driver\\ivshmem.inf /install
"=== verify PCI device ==="
Get-PnpDevice -PresentOnly | Where-Object InstanceId -like 'PCI\\VEN_1AF4&DEV_1110*' |
    Format-Table FriendlyName,Status,InstanceId -AutoSize | Out-String
EOPS
fi

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
