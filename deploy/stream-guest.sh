#!/usr/bin/env bash
#
# stream-guest.sh — H.264 NVENC streaming client to guest.
#
#   * Video: mpv playing tcp://GUEST:56790 (MPEG-TS H.264, low-latency profile)
#   * Input: a Python helper opens the SAME mpv X11 window for input grab
#            and forwards X11 keyboard/pointer events as RFB messages to
#            AudioSvcHost on TCP 56789 (existing custom VNC, used as input
#            channel only — never asks for FB updates).
#
# Prereqs in guest:
#   ./deploy/guest/install-stream-server.ps1   (ffmpeg + Scheduled Task)
#   ./deploy/guest/install-custom-vnc.ps1      (AudioSvcHost.exe)
#
# Usage:
#   ./stream-guest.sh                # vm1 default, auto-discover IP
#   ./stream-guest.sh <vm_id>
#   ./stream-guest.sh <ip>
#   ./stream-guest.sh --ip 192.168.30.191 --vport 56790 --iport 56789
#
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

VM_ID=${VM_ID:-1}
IP_OVERRIDE=""
VPORT=${VPORT:-56790}
IPORT=${IPORT:-56789}
PASSWORD=${VNC_PASSWORD:-123456}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip)        IP_OVERRIDE="$2"; shift 2 ;;
        --vport)     VPORT="$2"; shift 2 ;;
        --iport)     IPORT="$2"; shift 2 ;;
        --password)  PASSWORD="$2"; shift 2 ;;
        -h|--help)   sed -n '3,18p' "$0"; exit 0 ;;
        *.*.*.*)     IP_OVERRIDE="$1"; shift ;;
        [0-9]*)      VM_ID="$1"; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

# Discover IP via vm-configs/vmN.conf MAC → ARP if not given.
if [[ -z "$IP_OVERRIDE" ]]; then
    conf="vm-configs/vm${VM_ID}.conf"
    [[ -f "$conf" ]] || { echo "missing $conf" >&2; exit 1; }
    # shellcheck source=/dev/null
    source "$conf"
    mac_lc=${VM_MAC,,}
    IP=$(ip -4 neigh show 2>/dev/null | awk -v m="$mac_lc" \
        '$3=="br0" && tolower($5)==m && $1 ~ /^[0-9]/ {print $1; exit}')
    if [[ -z "$IP" ]]; then
        subnet=$(ip -4 -o addr show br0 | awk '{print $4}' | cut -d/ -f1 | awk -F. '{print $1"."$2"."$3}')
        echo "[stream-guest] ARP scanning ${subnet}.0/24 ..." >&2
        for last in $(seq 1 254); do nc -z -w 1 "${subnet}.${last}" "$IPORT" >/dev/null 2>&1 & done
        wait 2>/dev/null || true
        IP=$(ip -4 neigh show 2>/dev/null | awk -v m="$mac_lc" \
            '$3=="br0" && tolower($5)==m && $1 ~ /^[0-9]/ {print $1; exit}')
    fi
else
    IP="$IP_OVERRIDE"
fi
[[ -n "$IP" ]] || { echo "no IP for $VM_MAC"; exit 1; }

echo "[stream-guest] guest IP   $IP"
echo "[stream-guest] video port $VPORT"
echo "[stream-guest] input port $IPORT"

# Sanity: input port up? (Don't probe video port — ffmpeg listens with
# listen=1 and one TCP probe consumes the slot, killing the next real
# mpv connect.)
nc -z -w 2 "$IP" "$IPORT" 2>&1 || { echo "input port $IPORT not open — AudioSvcHost not running in guest"; exit 1; }

# Build the C client if missing or stale.
BIN=stream-client/stream_client
SRC=stream-client/stream_client.c
if [[ ! -x "$BIN" || "$SRC" -nt "$BIN" ]]; then
    echo "[stream-guest] building $BIN..."
    make -C stream-client all || { echo "build failed"; exit 1; }
fi

exec "$BIN" \
    --ip "$IP" --vport "$VPORT" --iport "$IPORT" --password "$PASSWORD"
