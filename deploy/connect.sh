#!/usr/bin/env bash
#
# connect.sh — connect host viewer to guest.
#
# Default transport (--dda): native DXGI Desktop Duplication →
# 32×32 dirty-tile raw BGRA → ivshmem ring → host SDL2 viewer
# (stream-client/stream_client_dda). No mpv, no codec, no network
# packets in steady state.
#
# Fallback transport (--tcp): the older H.264-over-TCP path that
# spawns ffmpeg + NvSvcStream in the guest. Kept for environments
# without ivshmem.
#
# Prereqs in guest (one-time):
#   ./deploy/setup-guest.sh <vm_id>
#
# Usage:
#   ./connect.sh                  # vm1 default, --dda transport
#   ./connect.sh <vm_id>
#   ./connect.sh <ip>
#   ./connect.sh --ip 192.168.30.191
#   ./connect.sh --tcp            # fallback to TCP H.264
#
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

VM_ID=${VM_ID:-1}
IP_OVERRIDE=""
IPORT=${IPORT:-56789}
PASSWORD=${VNC_PASSWORD:-123456}
TRANSPORT=${STREAM_TRANSPORT:-dda}   # dda (default, ivshmem dirty-tile)
                                     # tcp (legacy h.264 over network, fallback)
SHMEM_PATH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip)        IP_OVERRIDE="$2"; shift 2 ;;
        --iport)     IPORT="$2"; shift 2 ;;
        --password)  PASSWORD="$2"; shift 2 ;;
        --dda)       TRANSPORT=dda; shift ;;
        --tcp)       TRANSPORT=tcp; shift ;;
        --shmem-path) SHMEM_PATH="$2"; shift 2 ;;
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
        echo "[connect] ARP scanning ${subnet}.0/24 ..." >&2
        for last in $(seq 1 254); do nc -z -w 1 "${subnet}.${last}" "$IPORT" >/dev/null 2>&1 & done
        wait 2>/dev/null || true
        IP=$(ip -4 neigh show 2>/dev/null | awk -v m="$mac_lc" \
            '$3=="br0" && tolower($5)==m && $1 ~ /^[0-9]/ {print $1; exit}')
    fi
else
    IP="$IP_OVERRIDE"
fi
[[ -n "$IP" ]] || { echo "no IP for $VM_MAC"; exit 1; }

echo "[connect] guest IP   $IP"
echo "[connect] transport  $TRANSPORT"

# DDA mode doesn't talk to TCP; only the legacy TCP path needs the
# probe (and the input listener at all).
if [[ "$TRANSPORT" == "tcp" ]]; then
    echo "[connect] input port $IPORT"
    nc -z -w 2 "$IP" "$IPORT" 2>&1 || { echo "input port $IPORT not open — AudioSvcHost not running in guest"; exit 1; }
fi

# Build the C client if missing or stale.
case "$TRANSPORT" in
dda)
    # DEFAULT: native DDA dirty-tile raw BGRA via ivshmem → SDL2.
    BIN=stream-client/stream_client_dda
    SRC=stream-client/stream_client_dda.c
    [[ -n "$SHMEM_PATH" ]] || SHMEM_PATH="/dev/shm/nv-shmem-vm${VM_ID}"
    [[ -e "$SHMEM_PATH" ]] || {
        echo "[connect] $SHMEM_PATH missing — start the VM (./start-vm.sh $VM_ID) first"
        exit 1
    }
    echo "[connect] transport: dda ($SHMEM_PATH)"
    ;;
tcp)
    # Legacy fallback: TCP h.264 from NvSvcStream (ffmpeg). Requires
    # vGPU + NVENC, no ivshmem.
    BIN=stream-client/stream_client
    SRC=stream-client/stream_client.c
    VPORT=${VPORT:-56790}
    echo "[connect] transport: tcp ($IP:$VPORT video / $IP:$IPORT input) [legacy]"
    ;;
esac

if [[ ! -x "$BIN" || "$SRC" -nt "$BIN" ]]; then
    echo "[connect] building $BIN..."
    make -C stream-client all || { echo "build failed"; exit 1; }
fi

case "$TRANSPORT" in
dda) exec "$BIN" --shmem "$SHMEM_PATH" ;;
tcp) exec "$BIN" --ip "$IP" --vport "$VPORT" --iport "$IPORT" --password "$PASSWORD" ;;
esac
