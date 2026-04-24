#!/usr/bin/env bash
#
# vnc-guest.sh — connect to TightVNC Server RUNNING IN GUEST (port 5900 on
# the guest's own IP, not QEMU's host-side VNC).
#
# Prereq: guest has install-tightvnc.ps1 done.
#
# Usage:
#   ./vnc-guest.sh                        auto-discover IP, 5900, pw 123456
#   ./vnc-guest.sh <vm_id>                as above, use vmN.conf
#   ./vnc-guest.sh <ip>                   skip discovery, use that IP
#   ./vnc-guest.sh --ip 192.168.30.191    same
#   ./vnc-guest.sh --port 5901 --password mypw
#
# Unlike xfreerdp3, the VNC path doesn't add a Remote Display Adapter in
# guest's Device Manager — TightVNC 2.x uses GDI polling, no mirror driver.
#
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

VM_ID=${VM_ID:-1}
IP_OVERRIDE=""
PORT=${VNC_PORT:-5900}
PASSWORD=${VNC_PASSWORD:-123456}
SCALE=${VNC_SCALE:-}     # e.g. 50 for half, 75 for 3/4. Empty = client native.
CLIENT=${VNC_CLIENT:-auto}  # auto | tiger | remmina | gvnc

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip)       IP_OVERRIDE="$2"; shift 2 ;;
        --port)     PORT="$2"; shift 2 ;;
        --password) PASSWORD="$2"; shift 2 ;;
        --scale)    SCALE="$2"; shift 2 ;;
        --remmina)  CLIENT=remmina; shift ;;
        --tiger)    CLIENT=tiger; shift ;;
        --client)   CLIENT="$2"; shift 2 ;;
        -h|--help)  sed -n '3,17p' "$0"; exit 0 ;;
        # positional: IP 优先判（带点）。 bash case glob 里 * 会吃任意字符（含点），
        # 所以必须先匹配带点模式，再匹配纯数字。
        *.*.*.*)   IP_OVERRIDE="$1"; shift ;;
        [0-9]*)    VM_ID="$1"; shift ;;
        *) echo "unknown arg: $1" >&2
           echo "usage: $0 [<vm_id>|<ip>] [--port N] [--password X]" >&2
           exit 2 ;;
    esac
done

if [[ -z "$IP_OVERRIDE" ]]; then
    conf="vm-configs/vm${VM_ID}.conf"
    [[ -f "$conf" ]] || { echo "missing $conf" >&2; exit 1; }
    # shellcheck source=/dev/null
    source "$conf"
    mac_lc=${VM_MAC,,}

    _by_mac() {
        ip -4 neigh show 2>/dev/null | awk -v m="$mac_lc" \
            '$3=="br0" && tolower($5)==m && $1 ~ /^[0-9]/ {print $1; exit}'
    }

    IP=$(_by_mac)
    if [[ -z "$IP" ]]; then
        subnet=$(ip -4 -o addr show br0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | awk -F. '{print $1"."$2"."$3}')
        if [[ -n "$subnet" ]]; then
            echo "[vnc-guest] ARP 扫 ${subnet}.0/24..." >&2
            # ICMP probe first (fast, parallel). Guest firewall may block
            # ICMP — fall through to TCP probe.
            for last in $(seq 1 254); do
                ping -c1 -W0.2 -q "${subnet}.${last}" >/dev/null 2>&1 &
            done
            wait 2>/dev/null || true
            IP=$(_by_mac)

            # Still nothing? TCP SYN to port 3389/5985/5900 still forces an
            # ARP resolution even if ICMP is blocked.
            if [[ -z "$IP" ]]; then
                for last in $(seq 1 254); do
                    nc -z -w 1 "${subnet}.${last}" 3389 >/dev/null 2>&1 &
                done
                wait 2>/dev/null || true
                IP=$(_by_mac)
            fi
        fi
    fi
else
    IP="$IP_OVERRIDE"
fi
if [[ -z "$IP" ]]; then
    echo "[vnc-guest] no IP for MAC $VM_MAC in ARP table." >&2
    echo "            guest boot slow / network not up yet?" >&2
    echo "            workarounds:" >&2
    echo "              1) wait 30 s and try again" >&2
    echo "              2) tmux attach -t vm${VM_ID}       # see QEMU log" >&2
    echo "              3) ./vnc-guest.sh 192.168.30.191   # explicit IP" >&2
    echo "              4) ./up.sh --connect-only          # RDP 3389 has the same hint for when guest boots" >&2
    exit 1
fi

if ! nc -zv -w 2 "$IP" "$PORT" 2>/dev/null; then
    echo "[vnc-guest] $IP:$PORT not listening — did you run install-tightvnc.ps1 in the guest?"
    exit 1
fi

echo "[vnc-guest] connecting $IP:$PORT"

# TigerVNC viewer supports an interactive password prompt; for one-line
# passing we store the 8-byte VNC password hash file that the viewer can
# --passwd. Easier: just echo on stdin (-autopass) on recent versions.
scale_opt=()
[[ -n "$SCALE" ]] && scale_opt=( "-Scaling=$SCALE%" )

# Generate the 8-byte DES-encrypted VNC password file that -PasswordFile
# expects. Also usable from Remmina profile.
passwd_file="/tmp/.vnc-vm${VM_ID}.pass"
python3 - "$PASSWORD" "$passwd_file" <<'PYEOF'
import sys
try:
    from Crypto.Cipher import DES
except ImportError:
    import subprocess
    subprocess.check_call([sys.executable, '-m', 'pip', 'install', '--quiet',
                           '--break-system-packages', '--user', 'pycryptodome'])
    from Crypto.Cipher import DES
pw, out = sys.argv[1], sys.argv[2]
pw_bytes = pw.encode('ascii')[:8].ljust(8, b'\x00')
key = bytes([0xE8, 0x4A, 0xD6, 0x60, 0xC4, 0x72, 0x1A, 0xE0])
enc = DES.new(key, DES.MODE_ECB).encrypt(pw_bytes)
with open(out, 'wb') as f: f.write(enc)
import os; os.chmod(out, 0o600)
PYEOF

# Auto-pick client if user didn't override.
if [[ "$CLIENT" == auto ]]; then
    if command -v xtigervncviewer >/dev/null; then CLIENT=tiger
    elif command -v remmina >/dev/null;        then CLIENT=remmina
    elif command -v gvncviewer >/dev/null;     then CLIENT=gvnc
    else echo 'No VNC client found. sudo apt install -y tigervnc-viewer remmina' >&2; exit 1
    fi
fi

case "$CLIENT" in
    tiger)
        exec xtigervncviewer "${scale_opt[@]}" -PasswordFile="$passwd_file" "$IP::$PORT"
        ;;
    remmina)
        # Build a one-shot .remmina profile so we can pre-fill password + port.
        prof="/tmp/vm${VM_ID}-vnc.remmina"
        # Remmina wants base64 of DES-encoded password, same blob we wrote.
        pw_b64=$(base64 -w0 < "$passwd_file")
        cat > "$prof" <<EOF
[remmina]
name=vm${VM_ID} VNC
protocol=VNC
server=${IP}:${PORT}
password=${pw_b64}
viewmode=4
quality=2
colordepth=24
EOF
        exec remmina -c "$prof"
        ;;
    gvnc)
        exec gvncviewer "$IP:$((PORT-5900))"
        ;;
    *)
        echo "unknown --client $CLIENT (auto|tiger|remmina|gvnc)" >&2; exit 2 ;;
esac
