#!/usr/bin/env bash
#
# vnc-guest.sh — connect to TightVNC Server RUNNING IN GUEST (port 5900 on
# the guest's own IP, not QEMU's host-side VNC).
#
# Prereq: guest has install-tightvnc.ps1 done.
#
#   ./vnc-guest.sh                        auto-discover IP, 5900, pw 123456
#   ./vnc-guest.sh --port 5901 --password mypw
#   ./vnc-guest.sh --ip 192.168.30.191
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

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip)       IP_OVERRIDE="$2"; shift 2 ;;
        --port)     PORT="$2"; shift 2 ;;
        --password) PASSWORD="$2"; shift 2 ;;
        -h|--help)  sed -n '3,15p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1"; exit 2 ;;
    esac
done

if [[ -z "$IP_OVERRIDE" ]]; then
    conf="vm-configs/vm${VM_ID}.conf"
    [[ -f "$conf" ]] || { echo "missing $conf" >&2; exit 1; }
    # shellcheck source=/dev/null
    source "$conf"
    mac_lc=${VM_MAC,,}
    IP=$(ip -4 neigh show 2>/dev/null | awk -v m="$mac_lc" '$3=="br0" && tolower($5)==m && $1 ~ /^[0-9]/ {print $1; exit}')
    if [[ -z "$IP" ]]; then
        subnet=$(ip -4 -o addr show br0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | awk -F. '{print $1"."$2"."$3}')
        [[ -n "$subnet" ]] && for last in $(seq 1 254); do
            ping -c1 -W0.2 -q "${subnet}.${last}" >/dev/null 2>&1 &
        done
        wait 2>/dev/null || true
        IP=$(ip -4 neigh show 2>/dev/null | awk -v m="$mac_lc" '$3=="br0" && tolower($5)==m && $1 ~ /^[0-9]/ {print $1; exit}')
    fi
else
    IP="$IP_OVERRIDE"
fi
[[ -n "$IP" ]] || { echo "no IP — is guest booted?" >&2; exit 1; }

if ! nc -zv -w 2 "$IP" "$PORT" 2>/dev/null; then
    echo "[vnc-guest] $IP:$PORT not listening — did you run install-tightvnc.ps1 in the guest?"
    exit 1
fi

echo "[vnc-guest] connecting $IP:$PORT"

# TigerVNC viewer supports an interactive password prompt; for one-line
# passing we store the 8-byte VNC password hash file that the viewer can
# --passwd. Easier: just echo on stdin (-autopass) on recent versions.
if command -v xtigervncviewer >/dev/null; then
    if xtigervncviewer --help 2>&1 | grep -q autopass; then
        exec bash -c "echo '$PASSWORD' | xtigervncviewer -autopass '$IP::$PORT'"
    else
        echo "[vnc-guest] tigervnc without --autopass — will prompt for password ($PASSWORD)"
        exec xtigervncviewer "$IP::$PORT"
    fi
elif command -v remmina >/dev/null; then
    exec remmina -c "vnc://$IP:$PORT"
elif command -v vncviewer >/dev/null; then
    exec vncviewer "$IP::$PORT"
elif command -v gvncviewer >/dev/null; then
    exec gvncviewer "$IP:$((PORT-5900))"
else
    echo 'No VNC client found. sudo apt install -y tigervnc-viewer remmina' >&2
    exit 1
fi
