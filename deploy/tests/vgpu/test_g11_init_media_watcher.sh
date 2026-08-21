#!/usr/bin/env bash
# Real-QEMU regression for the one-shot private-clone optical lifecycle.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
WATCHER="$REPO_ROOT/deploy/host/watch-g11-init-media.py"
QEMU_BIN=${QEMU_BIN:-"$REPO_ROOT/build/qemu-system-x86_64"}
TMP_DIR=$(mktemp -d)
QMP_SOCK="$TMP_DIR/qmp.sock"
PID_FILE="$TMP_DIR/qemu.pid"
MEDIA="$TMP_DIR/private-init.iso"

cleanup() {
    local pid=
    if [[ -s "$PID_FILE" ]]; then
        pid=$(<"$PID_FILE")
        [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill "$pid" 2>/dev/null || true
    fi
    rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
[[ -x "$QEMU_BIN" ]] || fail "QEMU binary is missing: $QEMU_BIN"
[[ -s "$WATCHER" && ! -L "$WATCHER" ]] || fail "watcher is missing or unsafe"
truncate -s 4096 "$MEDIA"

"$QEMU_BIN" \
    -name vm919902 \
    -machine q35,accel=tcg \
    -m 128 \
    -nodefaults \
    -display none \
    -device qemu-xhci,id=xhci \
    -drive "file=${MEDIA},if=none,id=g11-init-odd-media,media=cdrom,readonly=on,format=raw" \
    -device 'usb-bot,id=g11-init-odd-usb,bus=xhci.0,port=3,x-no-serial=on' \
    -device 'scsi-cd,id=g11-init-odd,drive=g11-init-odd-media,bus=g11-init-odd-usb.0,vendor=HL-DT-ST,product=DVDRAM GH24NS50,ver=XP02,serial=,bootindex=-1' \
    -qmp "unix:${QMP_SOCK},server,nowait,multi=on" \
    -pidfile "$PID_FILE" \
    -S \
    -daemonize
QEMU_PID=$(<"$PID_FILE")
[[ "$QEMU_PID" =~ ^[1-9][0-9]*$ ]] || fail 'QEMU did not publish a valid PID'

python3 "$WATCHER" "$QMP_SOCK" vm919902 "$MEDIA" \
    HL-DT-ST 'DVDRAM GH24NS50' XP02 >"$TMP_DIR/watcher.out" 2>&1 &
WATCH_PID=$!

# The real guest uses IOCTL_STORAGE_EJECT_MEDIA.  This QMP command creates the
# same tray-open state so the test can exercise only the host observer/remover.
python3 - "$QMP_SOCK" <<'PY'
import json
import socket
import sys
import time

time.sleep(0.25)
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(5)
sock.connect(sys.argv[1])
stream = sock.makefile("rwb", buffering=0)
while "QMP" not in json.loads(stream.readline()):
    pass


def command(name, arguments=None):
    request = {"execute": name, "id": name}
    if arguments is not None:
        request["arguments"] = arguments
    stream.write((json.dumps(request) + "\r\n").encode())
    while True:
        response = json.loads(stream.readline())
        if response.get("id") == name:
            if "error" in response:
                raise RuntimeError(response["error"])
            return response.get("return")


command("qmp_capabilities")
command("blockdev-open-tray", {
    "device": "g11-init-odd-media",
    "force": True,
})
PY

wait "$WATCH_PID" || {
    sed 's/^/watcher: /' "$TMP_DIR/watcher.out" >&2 || true
    fail 'watcher rejected or failed to remove the reviewed stack'
}
grep -Fq 'PASS: payload ejected; temporary optical device and USB transport removed' \
    "$TMP_DIR/watcher.out" || fail 'watcher did not report a complete hot-remove'

python3 - "$QMP_SOCK" >"$TMP_DIR/final.out" <<'PY'
import json
import socket
import sys

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(5)
sock.connect(sys.argv[1])
stream = sock.makefile("rwb", buffering=0)
while "QMP" not in json.loads(stream.readline()):
    pass


def command(name, arguments=None):
    request = {"execute": name, "id": name}
    if arguments is not None:
        request["arguments"] = arguments
    stream.write((json.dumps(request) + "\r\n").encode())
    while True:
        response = json.loads(stream.readline())
        if response.get("id") == name:
            if "error" in response:
                raise RuntimeError(response["error"])
            return response.get("return")


command("qmp_capabilities")
for item in command("qom-list", {"path": "/machine/peripheral"}):
    print(item.get("name", ""))
command("quit")
PY
if grep -Eq '^g11-init-odd(-usb)?$' "$TMP_DIR/final.out"; then
    fail 'temporary optical frontend remained visible after guest eject'
fi
wait "$QEMU_PID" 2>/dev/null || true

echo 'PASS: private initialization optical identity and automatic hot-remove'
