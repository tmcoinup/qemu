#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Convenience wrapper to launch a QEMU instance with `-display fb-shm`
# (and nothing else GUI-side).  Designed to compose with the multi-VM
# orchestrator in qemu-fb-shm-multivm.py - each invocation produces one
# VM with a deterministic socket path /run/qemu/fb-${ID}.sock.
#
# Required env / args:
#   ID           : VM short name (used in the socket path)
#   QEMU         : path to qemu-system-x86_64 (default: ./build/qemu-system-x86_64)
#   ROI          : "x,y,w,h" or empty for full frame
#   RATE         : target Hz (default 30)
#   EXTRA_QEMU   : extra args passed verbatim to qemu (e.g. drive image)
#
# Example:
#   ID=vm1 ROI=0,0,1920,1080 RATE=60 \
#     EXTRA_QEMU="-cdrom /isos/ubuntu.iso -m 4G -accel kvm" \
#     scripts/qemu-fb-shm-spawn.sh
#
# Important: -display fb-shm is the ONLY display backend on the QEMU side.
# There is no SDL/GTK window.  Combine with -vga none + GPU passthrough or
# with virtio-gpu (anti-detect bundle handles the in-guest masking).

set -euo pipefail

: "${ID:?ID required}"
: "${QEMU:=$(dirname "$0")/../build/qemu-system-x86_64}"
: "${RATE:=30}"
: "${RUN_DIR:=/run/qemu}"
: "${EXTRA_QEMU:=}"

mkdir -p "$RUN_DIR"

ROI_OPT=""
if [[ -n "${ROI:-}" ]]; then
    IFS=',' read -r RX RY RW RH <<<"$ROI"
    ROI_OPT=",x=${RX},y=${RY},width=${RW},height=${RH}"
fi

SOCK="${RUN_DIR}/fb-${ID}.sock"

# CPU pinning is left to the caller (taskset/numactl). We deliberately
# don't `exec` taskset here to keep the script composable with systemd
# units that already declare CPUAffinity=.
exec "$QEMU" \
    -name "qemu-fb-${ID},debug-threads=on" \
    -display "fb-shm,id=${ID},path=${SOCK},rate=${RATE}${ROI_OPT}" \
    -monitor "unix:${RUN_DIR}/mon-${ID}.sock,server,nowait" \
    -qmp     "unix:${RUN_DIR}/qmp-${ID}.sock,server,nowait" \
    ${EXTRA_QEMU}
