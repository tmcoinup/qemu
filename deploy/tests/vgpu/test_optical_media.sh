#!/usr/bin/env bash
# Real-QEMU regression for default-absent, read-only optical hotplug lifecycle.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
OPTICAL="$REPO_ROOT/deploy/scripts/optical-media.sh"
VMCTL="$REPO_ROOT/deploy/scripts/vmctl.sh"
QEMU_BIN=${QEMU_BIN:-"$REPO_ROOT/build/qemu-system-x86_64"}
TMP_DIR=$(mktemp -d)
VM_ID=919901
VM_DIR="$TMP_DIR/$VM_ID"
QMP_SOCK="$VM_DIR/run/qmp.sock"
PID_FILE="$VM_DIR/run/qemu.pid"

cleanup() {
    local pid=
    if [[ -s "$PID_FILE" ]]; then
        pid=$(<"$PID_FILE")
        [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill "$pid" 2>/dev/null || true
    fi
    rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

require_text() {
    local needle=$1 file=$2
    grep -F -- "$needle" "$file" >/dev/null ||
        fail "missing '$needle' in $(basename "$file")"
}

[[ -x "$QEMU_BIN" ]] || fail "QEMU binary is missing: $QEMU_BIN"
mkdir -p "$VM_DIR/run"
touch "$VM_DIR/vm.conf"
truncate -s 4096 "$TMP_DIR/first.iso"
truncate -s 8192 "$TMP_DIR/second.iso"
ln -s -- "$TMP_DIR/first.iso" "$TMP_DIR/link.iso"

"$QEMU_BIN" \
    -name "vm${VM_ID}" \
    -machine q35,accel=tcg \
    -m 128 \
    -nodefaults \
    -display none \
    -device qemu-xhci,id=xhci \
    -qmp "unix:${QMP_SOCK},server,nowait" \
    -pidfile "$PID_FILE" \
    -S \
    -daemonize

"$OPTICAL" "$VM_ID" status --vms-dir "$TMP_DIR" >"$TMP_DIR/status.out"
require_text 'OPTICAL_MODEL=HL-DT-ST DVDRAM GH24NS50' "$TMP_DIR/status.out"
require_text 'OPTICAL_FIRMWARE=XP02' "$TMP_DIR/status.out"
require_text 'OPTICAL_SERIAL_POLICY=none' "$TMP_DIR/status.out"
require_text 'OPTICAL_STATE=absent' "$TMP_DIR/status.out"
require_text 'OPTICAL_ATTACHED=no' "$TMP_DIR/status.out"
require_text 'MEDIA_STATE=absent' "$TMP_DIR/status.out"

"$OPTICAL" "$VM_ID" mount "$TMP_DIR/first.iso" \
    --vms-dir "$TMP_DIR" >"$TMP_DIR/mount.out"
require_text 'MEDIA_STATE=inserted' "$TMP_DIR/mount.out"
require_text "MEDIA_PATH=$TMP_DIR/first.iso" "$TMP_DIR/mount.out"
require_text 'MEDIA_READ_ONLY=yes' "$TMP_DIR/mount.out"
require_text 'OPTICAL_STATE=present' "$TMP_DIR/mount.out"
require_text 'OPTICAL_ATTACHED=yes' "$TMP_DIR/mount.out"
require_text 'OPTICAL_TRANSPORT=usb-bot/scsi-cd' "$TMP_DIR/mount.out"
require_text 'OPTICAL_USB_SERIAL_POLICY=none' "$TMP_DIR/mount.out"

# Reproduce the pre-fix stack: the complete usb-bot/scsi-cd tree exists but
# usb-bot was never published to the guest. Repeating mount must repair it.
python3 - "$QMP_SOCK" <<'PY'
import json
import socket
import sys

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(5)
s.connect(sys.argv[1])
f = s.makefile("rwb", buffering=0)
while "QMP" not in json.loads(f.readline()):
    pass

counter = 0


def command(name, arguments=None):
    global counter
    counter += 1
    ident = str(counter)
    request = {"execute": name, "id": ident}
    if arguments is not None:
        request["arguments"] = arguments
    f.write((json.dumps(request) + "\r\n").encode())
    while True:
        response = json.loads(f.readline())
        if response.get("id") == ident:
            if "error" in response:
                raise RuntimeError(response["error"])
            return response.get("return")


command("qmp_capabilities")
command("qom-set", {
    "path": "/machine/peripheral/g11-odd-usb",
    "property": "attached",
    "value": False,
})
PY
"$OPTICAL" "$VM_ID" mount "$TMP_DIR/first.iso" \
    --vms-dir "$TMP_DIR" >"$TMP_DIR/repair.out"
require_text 'OPTICAL_ATTACHED=yes' "$TMP_DIR/repair.out"

# Repeating the same mount is idempotent, but a different medium needs an
# explicit operator decision.
"$OPTICAL" "$VM_ID" mount "$TMP_DIR/first.iso" \
    --vms-dir "$TMP_DIR" >"$TMP_DIR/idempotent.out"
if "$OPTICAL" "$VM_ID" mount "$TMP_DIR/second.iso" \
        --vms-dir "$TMP_DIR" >"$TMP_DIR/refuse.out" \
        2>"$TMP_DIR/refuse.err"; then
    fail 'a different inserted ISO was replaced without --replace'
fi
require_text '确认要换盘时在命令末尾加 --replace' "$TMP_DIR/refuse.err"

"$OPTICAL" "$VM_ID" mount "$TMP_DIR/second.iso" --replace \
    --vms-dir "$TMP_DIR" >"$TMP_DIR/replace.out"
require_text "MEDIA_PATH=$TMP_DIR/second.iso" "$TMP_DIR/replace.out"

if "$OPTICAL" "$VM_ID" mount "$TMP_DIR/link.iso" --replace \
        --vms-dir "$TMP_DIR" >"$TMP_DIR/symlink.out" \
        2>"$TMP_DIR/symlink.err"; then
    fail 'a symbolic-link ISO path was accepted'
fi
require_text '非符号链接' "$TMP_DIR/symlink.err"

"$VMCTL" cdrom "$VM_ID" status --vms-dir "$TMP_DIR" \
    >"$TMP_DIR/vmctl.out"
require_text "MEDIA_PATH=$TMP_DIR/second.iso" "$TMP_DIR/vmctl.out"

# Query the device properties themselves, not only the catalog text printed by
# the wrapper.  serial must be the intentional empty value, never QM0000x.
python3 - "$QMP_SOCK" >"$TMP_DIR/qom.out" <<'PY'
import json
import socket
import sys

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(5)
s.connect(sys.argv[1])
f = s.makefile("rwb", buffering=0)
while True:
    if "QMP" in json.loads(f.readline()):
        break

counter = 0


def command(name, arguments=None):
    global counter
    counter += 1
    ident = str(counter)
    request = {"execute": name, "id": ident}
    if arguments is not None:
        request["arguments"] = arguments
    f.write((json.dumps(request) + "\r\n").encode())
    while True:
        response = json.loads(f.readline())
        if response.get("id") == ident:
            if "error" in response:
                raise RuntimeError(response["error"])
            return response.get("return")


command("qmp_capabilities")
path = "/machine/peripheral/g11-odd"
usb_path = "/machine/peripheral/g11-odd-usb"
print("VENDOR=" + command("qom-get", {"path": path, "property": "vendor"}))
print("PRODUCT=" + command("qom-get", {"path": path, "property": "product"}))
print("FIRMWARE=" + command("qom-get", {"path": path, "property": "ver"}))
print("SERIAL=" + command("qom-get", {"path": path, "property": "serial"}))
print("USB_ATTACHED=" + str(command(
    "qom-get", {"path": usb_path, "property": "attached"}
)).lower())
print("USB_NO_SERIAL=" + str(command(
    "qom-get", {"path": usb_path, "property": "x-no-serial"}
)).lower())
PY
require_text 'VENDOR=HL-DT-ST' "$TMP_DIR/qom.out"
require_text 'PRODUCT=DVDRAM GH24NS50' "$TMP_DIR/qom.out"
require_text 'FIRMWARE=XP02' "$TMP_DIR/qom.out"
grep -Fx -- 'SERIAL=' "$TMP_DIR/qom.out" >/dev/null ||
    fail 'QEMU optical serial is not explicitly empty'
require_text 'USB_ATTACHED=true' "$TMP_DIR/qom.out"
require_text 'USB_NO_SERIAL=true' "$TMP_DIR/qom.out"

"$VMCTL" cdrom "$VM_ID" eject --vms-dir "$TMP_DIR" \
    >"$TMP_DIR/eject.out"
require_text 'OPTICAL_STATE=absent' "$TMP_DIR/eject.out"
require_text 'OPTICAL_ATTACHED=no' "$TMP_DIR/eject.out"
require_text 'MEDIA_STATE=absent' "$TMP_DIR/eject.out"

"$OPTICAL" "$VM_ID" status --vms-dir "$TMP_DIR" \
    >"$TMP_DIR/absent.out"
require_text 'OPTICAL_STATE=absent' "$TMP_DIR/absent.out"

# Verify that eject removed both hotplugged devices and the named block node,
# rather than leaving an empty optical drive in Windows.
python3 - "$QMP_SOCK" >"$TMP_DIR/removed.out" <<'PY'
import json
import socket
import sys

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(5)
s.connect(sys.argv[1])
f = s.makefile("rwb", buffering=0)
while "QMP" not in json.loads(f.readline()):
    pass

counter = 0


def command(name, arguments=None):
    global counter
    counter += 1
    ident = str(counter)
    request = {"execute": name, "id": ident}
    if arguments is not None:
        request["arguments"] = arguments
    f.write((json.dumps(request) + "\r\n").encode())
    while True:
        response = json.loads(f.readline())
        if response.get("id") == ident:
            if "error" in response:
                raise RuntimeError(response["error"])
            return response.get("return")


command("qmp_capabilities")
for item in command("qom-list", {"path": "/machine/peripheral"}):
    print("PERIPHERAL=" + item.get("name", ""))
for item in command("query-named-block-nodes"):
    print("NODE=" + item.get("node-name", ""))
command("quit")
PY
if grep -Eq 'g11-odd(-usb|-media)?' "$TMP_DIR/removed.out"; then
    fail 'eject left a manual optical device or backend behind'
fi

echo 'PASS: default-absent optical drive and read-only QMP hotplug lifecycle'
