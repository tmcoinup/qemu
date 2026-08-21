#!/usr/bin/env bash
# Real-QEMU regression for a host directory exposed as a read-only USB disk.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
USB_DIRECTORY="$REPO_ROOT/deploy/scripts/usb-directory.sh"
SHARED_USB="$REPO_ROOT/deploy/scripts/shared-usb.sh"
QEMU_BIN=${QEMU_BIN:-"$REPO_ROOT/build/qemu-system-x86_64"}
QEMU_IMG=${QEMU_IMG:-"$REPO_ROOT/build/qemu-img"}
TMP_DIR=$(mktemp -d)
VM_ID=919905
VM_DIR="$TMP_DIR/$VM_ID"
QMP_SOCK="$VM_DIR/run/qmp.sock"
PID_FILE="$VM_DIR/run/qemu.pid"

cleanup() {
    local pid=""
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

for dependency in "$QEMU_BIN" "$QEMU_IMG" mdir mtype python3; do
    [[ -x "$dependency" ]] || command -v "$dependency" >/dev/null 2>&1 ||
        fail "missing dependency: $dependency"
done
[[ -x "$USB_DIRECTORY" ]] || fail "USB directory wrapper is not executable"
[[ -x "$SHARED_USB" ]] || fail "shared USB wrapper is not executable"

mkdir -p "$VM_DIR/run" "$TMP_DIR/first/sub" "$TMP_DIR/second"
touch "$VM_DIR/vm.conf"
printf 'hello-g11-usb\n' >"$TMP_DIR/first/sub/readme.txt"
printf 'replacement\n' >"$TMP_DIR/second/next.txt"
ln -s -- "$TMP_DIR/first" "$TMP_DIR/directory-link"
ln -s -- "$TMP_DIR/second/next.txt" "$TMP_DIR/first/nested-link"

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

"$USB_DIRECTORY" "$VM_ID" status --vms-dir "$TMP_DIR" \
    >"$TMP_DIR/absent.out"
require_text 'USB_DIRECTORY_STATE=absent' "$TMP_DIR/absent.out"
require_text 'USB_DIRECTORY_ATTACHED=no' "$TMP_DIR/absent.out"
require_text 'USB_DIRECTORY_MODE=read-only' "$TMP_DIR/absent.out"

if "$USB_DIRECTORY" "$VM_ID" mount "$TMP_DIR/directory-link" \
        --vms-dir "$TMP_DIR" >"$TMP_DIR/root-link.out" \
        2>"$TMP_DIR/root-link.err"; then
    fail 'a symbolic-link host directory was accepted'
fi
require_text 'readable real directory' "$TMP_DIR/root-link.err"

if "$USB_DIRECTORY" "$VM_ID" mount "$TMP_DIR/first" \
        --vms-dir "$TMP_DIR" >"$TMP_DIR/nested-link.out" \
        2>"$TMP_DIR/nested-link.err"; then
    fail 'a host directory containing a symbolic link was accepted'
fi
require_text 'contains a symbolic link' "$TMP_DIR/nested-link.err"
rm -- "$TMP_DIR/first/nested-link"

if "$USB_DIRECTORY" "$VM_ID" mount "$TMP_DIR/first" \
        --label 'LABEL_TOO_LONG' --vms-dir "$TMP_DIR" \
        >"$TMP_DIR/label.out" 2>"$TMP_DIR/label.err"; then
    fail 'an oversized VVFAT label was accepted'
fi
require_text "label must be 'U盘' or 1..11 ASCII" "$TMP_DIR/label.err"

"$USB_DIRECTORY" "$VM_ID" mount "$TMP_DIR/first" \
    --label G11_TEST --vms-dir "$TMP_DIR" >"$TMP_DIR/mount.out"
require_text 'USB_DIRECTORY_STATE=present' "$TMP_DIR/mount.out"
require_text 'USB_DIRECTORY_ATTACHED=yes' "$TMP_DIR/mount.out"
require_text 'USB_DIRECTORY_TRANSPORT=usb-storage/scsi-hd/vvfat' "$TMP_DIR/mount.out"
require_text 'USB_DIRECTORY_MODE=read-only' "$TMP_DIR/mount.out"
require_text 'USB_DIRECTORY_BACKING=host-directory-no-image' "$TMP_DIR/mount.out"
require_text 'USB_DIRECTORY_CAPACITY_BYTES=528482304' "$TMP_DIR/mount.out"
require_text 'USB_DIRECTORY_FAT_TYPE=16' "$TMP_DIR/mount.out"
require_text "USB_DIRECTORY_PATH=$TMP_DIR/first" "$TMP_DIR/mount.out"
require_text 'USB_DIRECTORY_LABEL=G11_TEST' "$TMP_DIR/mount.out"
require_text 'USB_DIRECTORY_LABEL_CHARSET=none' "$TMP_DIR/mount.out"
require_text 'USB_DIRECTORY_HARDWARE_PROFILE=sandisk-ultra-usb3' "$TMP_DIR/mount.out"
require_text 'USB_DIRECTORY_USB_VID=0781' "$TMP_DIR/mount.out"
require_text 'USB_DIRECTORY_USB_PID=5581' "$TMP_DIR/mount.out"
require_text 'USB_DIRECTORY_USB_MANUFACTURER=SanDisk' "$TMP_DIR/mount.out"
require_text 'USB_DIRECTORY_USB_PRODUCT=Ultra USB 3.0' "$TMP_DIR/mount.out"
require_text 'USB_DIRECTORY_DISK_VENDOR=SanDisk' "$TMP_DIR/mount.out"
require_text 'USB_DIRECTORY_DISK_PRODUCT=Ultra USB 3.0' "$TMP_DIR/mount.out"
require_text 'USB_DIRECTORY_PORT=3' "$TMP_DIR/mount.out"
require_text 'USB_DIRECTORY_DESCRIPTOR_STATE=projected' "$TMP_DIR/mount.out"
require_text 'USB_DIRECTORY_SERIAL_POLICY=none' "$TMP_DIR/mount.out"

# Independently materialize the same VVFAT source and read a nested file. This
# proves the directory produces a Windows-readable partition, not merely that
# QMP accepted opaque options.
vvfat_json=$(python3 - "$TMP_DIR/first" <<'PY'
import json
import sys

print("json:" + json.dumps({
    "driver": "vvfat",
    "dir": sys.argv[1],
    "fat-type": 16,
    "floppy": False,
    "label": "G11_TEST",
    "rw": False,
}, separators=(",", ":")))
PY
)
"$QEMU_IMG" convert -f vvfat -O raw "$vvfat_json" "$TMP_DIR/usb.raw"
mdir -i "$TMP_DIR/usb.raw@@32256" ::sub >"$TMP_DIR/mdir.out"
require_text 'README' "$TMP_DIR/mdir.out"
[[ "$(mtype -i "$TMP_DIR/usb.raw@@32256" ::sub/readme.txt)" == \
   'hello-g11-usb' ]] || fail 'VVFAT file content did not round-trip'

python3 - "$QMP_SOCK" >"$TMP_DIR/qmp.out" <<'PY'
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
path = "/machine/peripheral/g11-usb-dir"
print("ATTACHED=" + str(command(
    "qom-get", {"path": path, "property": "attached"}
)).lower())
print("PORT=" + command(
    "qom-get", {"path": path, "property": "port"}
))
for key in (
    "vendorid", "productid", "bcd-device", "manufacturer", "product",
    "scsi-vendor", "scsi-product", "scsi-version",
):
    print("USB_" + key.upper().replace("-", "_") + "=" + str(command(
        "qom-get", {"path": path, "property": key}
    )))
print("USB_NO_SERIAL=" + str(command(
    "qom-get", {"path": path, "property": "x-no-serial"}
)).lower())
print("REMOVABLE=" + str(command(
    "qom-get", {"path": path, "property": "removable"}
)).lower())
entries = [
    entry for entry in command("query-block")
    if (entry.get("inserted") or {}).get("node-name") == "g11-usb-dir-media"
]
assert len(entries) == 1
inserted = entries[0]["inserted"]
print("READ_ONLY=" + str(inserted["ro"]).lower())
print("FORMAT=" + inserted["image"]["format"])
options = json.loads(inserted["file"][5:])
print("DRIVER=" + options["driver"])
print("RW=" + str(options["rw"]).lower())
print("LABEL=" + options["label"])
PY
require_text 'ATTACHED=true' "$TMP_DIR/qmp.out"
require_text 'PORT=3' "$TMP_DIR/qmp.out"
require_text 'USB_VENDORID=1921' "$TMP_DIR/qmp.out"
require_text 'USB_PRODUCTID=21889' "$TMP_DIR/qmp.out"
require_text 'USB_BCD_DEVICE=256' "$TMP_DIR/qmp.out"
require_text 'USB_MANUFACTURER=SanDisk' "$TMP_DIR/qmp.out"
require_text 'USB_PRODUCT=Ultra USB 3.0' "$TMP_DIR/qmp.out"
require_text 'USB_NO_SERIAL=true' "$TMP_DIR/qmp.out"
require_text 'USB_SCSI_VENDOR=SanDisk' "$TMP_DIR/qmp.out"
require_text 'USB_SCSI_PRODUCT=Ultra USB 3.0' "$TMP_DIR/qmp.out"
require_text 'USB_SCSI_VERSION=1.00' "$TMP_DIR/qmp.out"
require_text 'REMOVABLE=true' "$TMP_DIR/qmp.out"
require_text 'READ_ONLY=true' "$TMP_DIR/qmp.out"
require_text 'FORMAT=vvfat' "$TMP_DIR/qmp.out"
require_text 'DRIVER=vvfat' "$TMP_DIR/qmp.out"
require_text 'RW=false' "$TMP_DIR/qmp.out"
require_text 'LABEL=G11_TEST' "$TMP_DIR/qmp.out"
grep -Fq 'usb_arguments["x-no-serial"] = True' "$USB_DIRECTORY" ||
    fail 'USB directory wrapper does not request USB-standard no-serial mode'

# Same directory/label is idempotent. A changed source requires an explicit
# refresh decision and --replace fully rebuilds the device/backend pair.
"$USB_DIRECTORY" "$VM_ID" mount "$TMP_DIR/first" \
    --label G11_TEST --vms-dir "$TMP_DIR" >"$TMP_DIR/idempotent.out"
if "$USB_DIRECTORY" "$VM_ID" mount "$TMP_DIR/second" \
        --label G11_NEXT --vms-dir "$TMP_DIR" \
        >"$TMP_DIR/refuse.out" 2>"$TMP_DIR/refuse.err"; then
    fail 'a different host directory was replaced without --replace'
fi
require_text 'add --replace' "$TMP_DIR/refuse.err"

"$USB_DIRECTORY" "$VM_ID" mount "$TMP_DIR/second" --replace \
    --label G11_NEXT --vms-dir "$TMP_DIR" >"$TMP_DIR/replace.out"
require_text "USB_DIRECTORY_PATH=$TMP_DIR/second" "$TMP_DIR/replace.out"
require_text 'USB_DIRECTORY_LABEL=G11_NEXT' "$TMP_DIR/replace.out"

"$USB_DIRECTORY" "$VM_ID" eject --vms-dir "$TMP_DIR" \
    >"$TMP_DIR/eject.out"
require_text 'USB_DIRECTORY_STATE=absent' "$TMP_DIR/eject.out"
require_text 'USB_DIRECTORY_ATTACHED=no' "$TMP_DIR/eject.out"

# The public wrapper mounts one common root while tools retain separate child
# directories below it.
mkdir -p "$TMP_DIR/shared/usb/ToolA" "$TMP_DIR/shared/usb/ToolB"
printf 'tool-a\n' >"$TMP_DIR/shared/usb/ToolA/a.txt"
printf 'tool-b\n' >"$TMP_DIR/shared/usb/ToolB/b.txt"
"$SHARED_USB" "$VM_ID" mount --vms-dir "$TMP_DIR" \
    >"$TMP_DIR/shared-mount.out"
require_text "USB_DIRECTORY_PATH=$TMP_DIR/shared/usb" \
    "$TMP_DIR/shared-mount.out"
require_text 'USB_DIRECTORY_LABEL=U盘' "$TMP_DIR/shared-mount.out"
require_text 'USB_DIRECTORY_LABEL_CHARSET=CP936' "$TMP_DIR/shared-mount.out"
require_text 'USB_DIRECTORY_BACKING=host-directory-no-image' \
    "$TMP_DIR/shared-mount.out"
require_text 'USB_DIRECTORY_CAPACITY_BYTES=137438953472' \
    "$TMP_DIR/shared-mount.out"
require_text 'USB_DIRECTORY_FAT_TYPE=32' "$TMP_DIR/shared-mount.out"
[[ ! -e "$TMP_DIR/shared/usb/autorun.inf" ]] ||
    fail 'shared wrapper still created an autorun.inf display-name override'

# A smaller sized image exercises the same FAT32 layout without scanning the
# full 128 GiB public capacity during this regression.
fat32_vvfat_json=$(python3 - "$TMP_DIR/shared/usb" <<'PY'
import json
import sys

print("json:" + json.dumps({
    "driver": "vvfat",
    "dir": sys.argv[1],
    "fat-type": 32,
    "size": 512 * 1024 * 1024,
    "floppy": False,
    "label": "U盘",
    "label-charset": "CP936",
    "rw": False,
}, ensure_ascii=False, separators=(",", ":")))
PY
)
"$QEMU_IMG" convert -S 4k -f vvfat -O raw \
    "$fat32_vvfat_json" "$TMP_DIR/fat32.raw"
[[ "$(stat -c %s "$TMP_DIR/fat32.raw")" == 536870912 ]] ||
    fail 'sized FAT32 VVFAT did not expose the requested virtual capacity'
python3 - "$TMP_DIR/fat32.raw" <<'PY'
import struct
import sys

expected = b"U\xc5\xcc" + b" " * 8
with open(sys.argv[1], "rb") as image:
    image.seek(454)
    partition_lba = struct.unpack("<I", image.read(4))[0]
    boot_offset = partition_lba * 512
    image.seek(boot_offset)
    boot = image.read(512)
    if boot[71:82] != expected or boot[82:90] != b"FAT32   ":
        raise SystemExit("sized FAT32 boot label or type is invalid")
    sectors_per_cluster = boot[13]
    reserved = struct.unpack_from("<H", boot, 14)[0]
    fat_count = boot[16]
    sectors_per_fat = struct.unpack_from("<I", boot, 36)[0]
    root_cluster = struct.unpack_from("<I", boot, 44)[0]
    root_lba = (
        partition_lba + reserved + fat_count * sectors_per_fat
        + (root_cluster - 2) * sectors_per_cluster
    )
    image.seek(root_lba * 512)
    if image.read(11) != expected:
        raise SystemExit("sized FAT32 root label is invalid")
PY
mdir -i "$TMP_DIR/fat32.raw@@32256" ::ToolA >"$TMP_DIR/fat32-mdir.out"
require_text 'TXT' "$TMP_DIR/fat32-mdir.out"
[[ "$(mtype -i "$TMP_DIR/fat32.raw@@32256" ::ToolA/a.txt)" == 'tool-a' ]] ||
    fail 'sized FAT32 VVFAT file content did not round-trip'

# The public label must be the real FAT label, encoded for a Simplified
# Chinese Windows guest.  It must not depend on AutoRun shell decoration.
chinese_vvfat_json=$(python3 - "$TMP_DIR/shared/usb" <<'PY'
import json
import sys

print("json:" + json.dumps({
    "driver": "vvfat",
    "dir": sys.argv[1],
    "fat-type": 16,
    "floppy": False,
    "label": "U盘",
    "label-charset": "CP936",
    "rw": False,
}, ensure_ascii=False, separators=(",", ":")))
PY
)
"$QEMU_IMG" convert -f vvfat -O raw \
    "$chinese_vvfat_json" "$TMP_DIR/chinese-label.raw"
python3 - "$TMP_DIR/chinese-label.raw" <<'PY'
import struct
import sys

expected = b"U\xc5\xcc" + b" " * 8
with open(sys.argv[1], "rb") as image:
    image.seek(454)
    partition_lba = struct.unpack("<I", image.read(4))[0]
    boot_offset = partition_lba * 512
    image.seek(boot_offset)
    boot = image.read(64)
    if boot[43:54] != expected:
        raise SystemExit(
            f"boot label mismatch: {boot[43:54].hex()} != {expected.hex()}"
        )
    reserved = struct.unpack_from("<H", boot, 14)[0]
    fat_count = boot[16]
    sectors_per_fat = struct.unpack_from("<H", boot, 22)[0]
    root_offset = boot_offset + (reserved + fat_count * sectors_per_fat) * 512
    image.seek(root_offset)
    root_label = image.read(11)
    if root_label != expected:
        raise SystemExit(
            f"root label mismatch: {root_label.hex()} != {expected.hex()}"
        )
PY
"$SHARED_USB" "$VM_ID" status --vms-dir "$TMP_DIR" \
    >"$TMP_DIR/shared-status.out"
require_text 'USB_DIRECTORY_STATE=present' "$TMP_DIR/shared-status.out"
"$SHARED_USB" "$VM_ID" eject --vms-dir "$TMP_DIR" \
    >"$TMP_DIR/shared-eject.out"
require_text 'USB_DIRECTORY_STATE=absent' "$TMP_DIR/shared-eject.out"

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
f.write(b'{"execute":"qmp_capabilities","id":"c"}\r\n')
while json.loads(f.readline()).get("id") != "c":
    pass
f.write(b'{"execute":"qom-list","arguments":{"path":"/machine/peripheral"},"id":"p"}\r\n')
while True:
    response = json.loads(f.readline())
    if response.get("id") == "p":
        for item in response["return"]:
            print("PERIPHERAL=" + item.get("name", ""))
        break
f.write(b'{"execute":"query-named-block-nodes","id":"b"}\r\n')
while True:
    response = json.loads(f.readline())
    if response.get("id") == "b":
        for item in response["return"]:
            print("NODE=" + item.get("node-name", ""))
        break
f.write(b'{"execute":"quit","id":"q"}\r\n')
PY
if grep -Eq 'g11-usb-dir(-media)?' "$TMP_DIR/removed.out"; then
    fail 'eject left a managed USB device or backend behind'
fi

echo 'PASS: read-only host-directory USB hotplug lifecycle'
