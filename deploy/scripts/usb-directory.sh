#!/usr/bin/env bash
# Hot-add/remove one host directory as a read-only USB mass-storage disk.
set -euo pipefail
umask 077
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_ROOT="$(cd "$HERE/.." && pwd)"

usage() {
    cat <<'EOF'
usage:
  ./deploy/scripts/usb-directory.sh ID status [storage selector]
  ./deploy/scripts/usb-directory.sh ID mount /absolute/host/directory [--replace] [--label LABEL] [storage selector]
  ./deploy/scripts/usb-directory.sh ID eject [storage selector]

storage selector (choose at most one):
  --vms-dir ABS | --vm-dir ABS | --instances-dir ABS

The directory is exposed to Windows as a read-only, removable USB disk through
QEMU VVFAT.  No guest driver is required.  Host-side changes become visible
only after ejecting and mounting again; mount --replace forces that refresh.
LABEL accepts 1..11 ASCII letters, numbers, spaces, '_' or '-'.  The managed
public-tools wrapper additionally uses the exact Windows Chinese label 'U盘'.
EOF
}

die() {
    echo "[usb-directory] ERROR: $*" >&2
    exit 1
}

VM_ID=${1:-}
ACTION=${2:-}
if [[ "$VM_ID" == -h || "$VM_ID" == --help || "$VM_ID" == help ]]; then
    usage
    exit 0
fi
[[ "$VM_ID" =~ ^[1-9][0-9]*$ && ${#VM_ID} -le 10 && -n "$ACTION" ]] || {
    usage >&2
    exit 2
}
((10#$VM_ID <= 2147483647)) || die "VM ID is out of range: $VM_ID"
shift 2

case "$ACTION" in
    insert) ACTION=mount ;;
    unmount|remove) ACTION=eject ;;
esac
case "$ACTION" in
    status|mount|eject) ;;
    *) die "unknown action: $ACTION" ;;
esac

HOST_INPUT=""
if [[ "$ACTION" == mount ]]; then
    (($# >= 1)) || die 'mount requires an absolute host directory'
    HOST_INPUT=$1
    shift
fi

REPLACE=0
LABEL=G11_USB
LABEL_SEEN=0
VMS_DIR_CLI=""
VM_DIR_CLI=""
INSTANCES_DIR_CLI=""
while (($#)); do
    case "$1" in
        --replace)
            [[ "$ACTION" == mount ]] || die '--replace is valid only with mount'
            ((REPLACE == 0)) || die '--replace may be specified once'
            REPLACE=1
            shift
            ;;
        --label)
            [[ "$ACTION" == mount ]] || die '--label is valid only with mount'
            (($# >= 2)) || die '--label requires a value'
            ((LABEL_SEEN == 0)) || die '--label may be specified once'
            LABEL=$2
            LABEL_SEEN=1
            shift 2
            ;;
        --label=*)
            [[ "$ACTION" == mount ]] || die '--label is valid only with mount'
            ((LABEL_SEEN == 0)) || die '--label may be specified once'
            LABEL=${1#*=}
            LABEL_SEEN=1
            shift
            ;;
        --vms-dir|--vm-dir|--instances-dir)
            (($# >= 2)) || die "$1 requires an absolute directory"
            option=$1
            value=$2
            shift 2
            case "$option" in
                --vms-dir)
                    [[ -z "$VMS_DIR_CLI" ]] || die '--vms-dir may be specified once'
                    VMS_DIR_CLI=$value
                    ;;
                --vm-dir)
                    [[ -z "$VM_DIR_CLI" ]] || die '--vm-dir may be specified once'
                    VM_DIR_CLI=$value
                    ;;
                --instances-dir)
                    [[ -z "$INSTANCES_DIR_CLI" ]] || die '--instances-dir may be specified once'
                    INSTANCES_DIR_CLI=$value
                    ;;
            esac
            ;;
        --vms-dir=*|--vm-dir=*|--instances-dir=*)
            option=${1%%=*}
            value=${1#*=}
            [[ -n "$value" ]] || die "$option requires an absolute directory"
            shift
            case "$option" in
                --vms-dir)
                    [[ -z "$VMS_DIR_CLI" ]] || die '--vms-dir may be specified once'
                    VMS_DIR_CLI=$value
                    ;;
                --vm-dir)
                    [[ -z "$VM_DIR_CLI" ]] || die '--vm-dir may be specified once'
                    VM_DIR_CLI=$value
                    ;;
                --instances-dir)
                    [[ -z "$INSTANCES_DIR_CLI" ]] || die '--instances-dir may be specified once'
                    INSTANCES_DIR_CLI=$value
                    ;;
            esac
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *) die "unknown argument: $1" ;;
    esac
done

selector_count=0
[[ -z "$VMS_DIR_CLI" ]] || selector_count=$((selector_count + 1))
[[ -z "$VM_DIR_CLI" ]] || selector_count=$((selector_count + 1))
[[ -z "$INSTANCES_DIR_CLI" ]] || selector_count=$((selector_count + 1))
((selector_count <= 1)) || die 'choose only one storage selector'

# shellcheck source=../lib/vm-storage.sh
source "$DEPLOY_ROOT/lib/vm-storage.sh"
if [[ -n "$VMS_DIR_CLI" ]]; then
    vm_storage_select_root "$VMS_DIR_CLI"
elif [[ -n "$VM_DIR_CLI" ]]; then
    vm_storage_select_instance_dir "$VM_ID" "$VM_DIR_CLI"
elif [[ -n "$INSTANCES_DIR_CLI" ]]; then
    vm_storage_select_instances_dir "$INSTANCES_DIR_CLI"
elif [[ -n "${VM_INSTANCE_DIR:-}" ]]; then
    vm_storage_select_instance_dir "$VM_ID" "$VM_INSTANCE_DIR"
elif [[ -n "${VM_INSTANCES_DIR:-}" ]]; then
    vm_storage_select_instances_dir "$VM_INSTANCES_DIR"
fi
vm_storage_init
vm_storage_validate_id "$VM_ID"
vm_storage_validate_instance_tree "$VM_ID"
if vm_storage_v11_collision "$VM_ID"; then
    die 'the instance has a V-11 marker; refusing to attach a G-11 USB disk'
fi

INSTANCE_DIR=$(vm_storage_instance_dir "$VM_ID")
CONF=$(vm_storage_config_path "$VM_ID")
[[ -d "$INSTANCE_DIR" && ! -L "$INSTANCE_DIR" &&
   -f "$CONF" && ! -L "$CONF" ]] ||
    die "vm${VM_ID} is not a complete G-11 instance: $INSTANCE_DIR"

HOST_PATH=""
LABEL_CHARSET=""
if [[ "$ACTION" == mount ]]; then
    [[ "$HOST_INPUT" == /* ]] || die 'host directory must be an absolute path'
    [[ "$HOST_INPUT" != *$'\n'* && "$HOST_INPUT" != *$'\r'* ]] ||
        die 'host directory contains an unsupported control character'
    host_lexical=$(realpath -ms -- "${HOST_INPUT%/}")
    HOST_PATH=$(realpath -e -- "$host_lexical" 2>/dev/null) ||
        die "host directory does not exist: $HOST_INPUT"
    [[ "$HOST_PATH" == "$host_lexical" && "$HOST_PATH" != / &&
       -d "$HOST_PATH" && ! -L "$HOST_PATH" && -r "$HOST_PATH" ]] ||
        die "host directory must be a readable real directory below '/': $HOST_INPUT"
    if [[ -n "$(find "$HOST_PATH" -type l -print -quit)" ]]; then
        die "host directory contains a symbolic link; copy real files into it first: $HOST_PATH"
    fi
    if [[ -n "$(find "$HOST_PATH" ! -type d ! -type f -print -quit)" ]]; then
        die "host directory contains a socket/device/FIFO unsupported by a USB disk: $HOST_PATH"
    fi
    if [[ "$LABEL" == 'U盘' ]]; then
        LABEL_CHARSET=CP936
    elif [[ ! "$LABEL" =~ ^[A-Za-z0-9_\ -]{1,11}$ ]]; then
        die "label must be 'U盘' or 1..11 ASCII letters, numbers, spaces, '_' or '-': $LABEL"
    fi
fi

QMP_SOCK=$(vm_storage_run_path "$VM_ID" qmp)
[[ -S "$QMP_SOCK" && ! -L "$QMP_SOCK" ]] ||
    die "vm${VM_ID} QMP socket is missing; start the VM first: $QMP_SOCK"
command -v python3 >/dev/null 2>&1 || die 'python3 is required'
command -v flock >/dev/null 2>&1 || die 'flock is required'

USB_LOCK=$(vm_storage_run_path "$VM_ID" usb-directory.lock)
[[ ! -L "$USB_LOCK" ]] || die "USB operation lock may not be a symbolic link: $USB_LOCK"
exec {USB_LOCK_FD}>"$USB_LOCK"
flock -w 10 "$USB_LOCK_FD" || die "timed out waiting for vm${VM_ID} USB operation lock"

python3 - "$QMP_SOCK" "vm${VM_ID}" "$ACTION" "$HOST_PATH" "$REPLACE" \
    "$LABEL" "$LABEL_CHARSET" <<'PY'
import json
import os
import socket
import sys
import time

(
    qmp_path,
    expected_name,
    action,
    requested_dir,
    replace_text,
    requested_label,
    requested_label_charset,
) = sys.argv[1:]
replace = replace_text == "1"
device_id = "g11-usb-dir"
backend_id = "g11-usb-dir-media"
profile_name = "sandisk-ultra-usb3"
usb_vendor_id = 0x0781
usb_product_id = 0x5581
usb_bcd_device = 0x0100
usb_manufacturer = "SanDisk"
usb_product = "Ultra USB 3.0"
scsi_vendor = "SanDisk"
scsi_product = "Ultra USB 3.0"
scsi_version = "1.00"
usb_port = "3"


class QMPError(RuntimeError):
    pass


sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(8)
try:
    sock.connect(qmp_path)
    stream = sock.makefile("rwb", buffering=0)
    while True:
        line = stream.readline()
        if not line:
            raise QMPError("QMP closed before its greeting")
        if "QMP" in json.loads(line):
            break

    sequence = 0

    def command(name, arguments=None):
        nonlocal_sequence[0] += 1
        ident = f"g11-usbdir-{nonlocal_sequence[0]}"
        request = {"execute": name, "id": ident}
        if arguments is not None:
            request["arguments"] = arguments
        stream.write((json.dumps(request) + "\r\n").encode())
        while True:
            response_line = stream.readline()
            if not response_line:
                raise QMPError(f"QMP closed before replying to {name}")
            response = json.loads(response_line)
            if response.get("id") != ident:
                continue
            if "error" in response:
                detail = response["error"].get("desc", "QMP error")
                raise QMPError(f"{name}: {detail}")
            return response.get("return")

    nonlocal_sequence = [sequence]
    command("qmp_capabilities")
    actual_name = (command("query-name") or {}).get("name")
    if actual_name != expected_name:
        raise QMPError(
            f"QMP identity mismatch: expected {expected_name}, got {actual_name!r}"
        )

    def peripheral_types():
        return {
            item.get("name"): item.get("type", "")
            for item in (command("qom-list", {"path": "/machine/peripheral"}) or [])
            if item.get("name") != "type"
        }

    def backend_present():
        return any(
            node.get("node-name") == backend_id
            for node in (command("query-named-block-nodes") or [])
        )

    def usb_storage_properties():
        return {
            item.get("name")
            for item in (command(
                "device-list-properties", {"typename": "usb-storage"}
            ) or [])
        }

    storage_properties = usb_storage_properties()
    usb_no_serial_capable = "x-no-serial" in storage_properties
    usb_identity_capable = {
        "vendorid", "productid", "bcd-device", "manufacturer", "product",
        "scsi-vendor", "scsi-product", "scsi-version",
    }.issubset(storage_properties)

    def block_entry():
        matches = []
        for entry in command("query-block") or []:
            inserted = entry.get("inserted") or {}
            if inserted.get("node-name") == backend_id:
                matches.append(entry)
        if len(matches) > 1:
            raise QMPError("multiple block entries use the managed USB backend")
        return matches[0] if matches else None

    def parse_vvfat_options(entry):
        inserted = entry.get("inserted") or {}
        image = inserted.get("image") or {}
        sources = [inserted.get("file"), image.get("filename")]
        for source in sources:
            if not isinstance(source, str) or not source.startswith("json:"):
                continue
            try:
                options = json.loads(source[5:])
            except json.JSONDecodeError as exc:
                raise QMPError("managed VVFAT backend has malformed JSON options") from exc
            if options.get("driver") == "vvfat":
                return options
        raise QMPError("managed backend is not an inspectable VVFAT directory")

    def device_attached():
        return bool(command(
            "qom-get",
            {"path": f"/machine/peripheral/{device_id}", "property": "attached"},
        ))

    def validate_managed_device(
        expected_dir=None,
        expected_label=None,
        expected_label_charset="",
        allow_detached=False,
    ):
        devices = peripheral_types()
        actual_type = devices.get(device_id)
        if actual_type != "child<usb-storage>":
            raise QMPError(
                f"managed USB device type is missing or unexpected: {actual_type!r}"
            )
        path = f"/machine/peripheral/{device_id}"
        actual_port = command("qom-get", {"path": path, "property": "port"})
        if actual_port != usb_port:
            raise QMPError(
                f"managed USB port changed: expected {usb_port}, got {actual_port!r}"
            )
        removable = command("qom-get", {"path": path, "property": "removable"})
        if not bool(removable):
            raise QMPError(
                f"managed USB disk is no longer removable: {removable!r}"
            )
        if not device_attached() and not allow_detached:
            raise QMPError("managed USB disk is not attached to the guest")
        if usb_no_serial_capable:
            no_serial = command(
                "qom-get", {"path": path, "property": "x-no-serial"}
            )
            if not bool(no_serial):
                raise QMPError("managed USB disk does not use no-serial mode")
        if usb_identity_capable:
            actual = {
                key: command("qom-get", {"path": path, "property": key})
                for key in (
                    "vendorid", "productid", "bcd-device", "manufacturer", "product",
                    "scsi-vendor", "scsi-product", "scsi-version",
                )
            }
            expected = {
                "vendorid": usb_vendor_id,
                "productid": usb_product_id,
                "bcd-device": usb_bcd_device,
                "manufacturer": usb_manufacturer,
                "product": usb_product,
                "scsi-vendor": scsi_vendor,
                "scsi-product": scsi_product,
                "scsi-version": scsi_version,
            }
            if actual != expected:
                raise QMPError(
                    "managed USB hardware identity changed: "
                    + json.dumps(actual, ensure_ascii=False, sort_keys=True)
                )
        entry = block_entry()
        if entry is None:
            raise QMPError("managed USB device has no block backend")
        inserted = entry.get("inserted") or {}
        image = inserted.get("image") or {}
        if not bool(inserted.get("ro")) or image.get("format") != "vvfat":
            raise QMPError("managed USB backend is not read-only VVFAT")
        options = parse_vvfat_options(entry)
        actual_dir = options.get("dir")
        actual_label = options.get("label", "QEMU VVFAT")
        actual_label_charset = options.get("label-charset", "")
        if not isinstance(actual_dir, str) or bool(options.get("rw", False)):
            raise QMPError("managed VVFAT source options are invalid or writable")
        if not isinstance(actual_label_charset, str):
            raise QMPError("managed VVFAT label charset is invalid")
        actual_dir = os.path.realpath(actual_dir)
        if expected_dir is not None and actual_dir != os.path.realpath(expected_dir):
            raise QMPError(
                f"managed USB directory mismatch: expected {expected_dir}, got {actual_dir}"
            )
        if expected_label is not None and actual_label != expected_label:
            raise QMPError(
                f"managed USB label mismatch: expected {expected_label!r}, got {actual_label!r}"
            )
        if (
            expected_label is not None
            and actual_label_charset != expected_label_charset
        ):
            raise QMPError(
                "managed USB label charset mismatch: "
                f"expected {expected_label_charset!r}, "
                f"got {actual_label_charset!r}"
            )
        return entry, actual_dir, actual_label, actual_label_charset

    def wait_device_absent(target=device_id):
        deadline = time.monotonic() + 8
        while target in peripheral_types():
            if time.monotonic() >= deadline:
                raise QMPError(f"timed out waiting to unplug {target}")
            time.sleep(0.05)

    def remove_managed_stack():
        devices = peripheral_types()
        if device_id in devices:
            if devices[device_id] != "child<usb-storage>":
                raise QMPError(
                    f"refusing to remove unexpected device at {device_id}: {devices[device_id]}"
                )
            command("device_del", {"id": device_id})
            wait_device_absent()
        if backend_present():
            command("blockdev-del", {"node-name": backend_id})
        devices = peripheral_types()
        if device_id in devices or backend_present():
            raise QMPError("USB eject returned success but managed objects remain")

    def cleanup_failed_add():
        try:
            devices = peripheral_types()
            if devices.get(device_id) == "child<usb-storage>":
                command("device_del", {"id": device_id})
                wait_device_absent()
        except (OSError, ValueError, QMPError):
            pass
        try:
            if backend_present():
                command("blockdev-del", {"node-name": backend_id})
        except (OSError, ValueError, QMPError):
            pass

    def add_managed_stack(host_dir, label, label_charset):
        devices = peripheral_types()
        if device_id in devices or backend_present():
            raise QMPError("managed USB IDs are already occupied")
        try:
            vvfat_arguments = {
                "driver": "vvfat",
                "node-name": backend_id,
                "read-only": True,
                "dir": host_dir,
                "fat-type": 16,
                "floppy": False,
                "label": label,
                "rw": False,
            }
            if label_charset:
                vvfat_arguments["label-charset"] = label_charset
            command("blockdev-add", vvfat_arguments)
            usb_arguments = {
                "driver": "usb-storage",
                "id": device_id,
                "drive": backend_id,
                "bus": "xhci.0",
                "port": usb_port,
                "removable": True,
                "bootindex": -1,
            }
            if usb_no_serial_capable:
                usb_arguments["x-no-serial"] = True
            if usb_identity_capable:
                usb_arguments.update({
                    "vendorid": usb_vendor_id,
                    "productid": usb_product_id,
                    "bcd-device": usb_bcd_device,
                    "manufacturer": usb_manufacturer,
                    "product": usb_product,
                    "scsi-vendor": scsi_vendor,
                    "scsi-product": scsi_product,
                    "scsi-version": scsi_version,
                })
            command("device_add", usb_arguments)
        except (OSError, ValueError, QMPError):
            cleanup_failed_add()
            raise
        return validate_managed_device(host_dir, label, label_charset)

    devices = peripheral_types()
    current = None
    if device_id in devices:
        current = validate_managed_device(allow_detached=action in ("mount", "eject"))
    elif backend_present():
        if action == "status":
            raise QMPError("an incomplete managed USB stack exists; run eject to clean it")
        remove_managed_stack()

    if action == "mount":
        if current is None:
            add_managed_stack(
                requested_dir, requested_label, requested_label_charset
            )
        else:
            _, current_dir, current_label, current_label_charset = current
            same = (
                current_dir == os.path.realpath(requested_dir)
                and current_label == requested_label
                and current_label_charset == requested_label_charset
            )
            if replace:
                remove_managed_stack()
                add_managed_stack(
                    requested_dir, requested_label, requested_label_charset
                )
            elif not same:
                raise QMPError(
                    "another host directory or label is already mounted; add --replace to replace it"
                )
            elif not device_attached():
                remove_managed_stack()
                add_managed_stack(
                    requested_dir, requested_label, requested_label_charset
                )
    elif action == "eject":
        remove_managed_stack()

    final = None
    if device_id in peripheral_types():
        final = validate_managed_device()
    elif backend_present():
        raise QMPError("managed USB backend remains without its disk")

    if action == "mount":
        if final is None:
            raise QMPError("QMP returned success but the USB disk is absent")
        validate_managed_device(
            requested_dir, requested_label, requested_label_charset
        )
    elif action == "eject" and final is not None:
        raise QMPError("QMP returned success but the USB disk remains present")

    final_dir = ""
    final_label = ""
    final_label_charset = ""
    attached = False
    if final is not None:
        _, final_dir, final_label, final_label_charset = final
        attached = device_attached()
    print(f"VM_NAME={actual_name}")
    print(f"USB_DIRECTORY_DEVICE={device_id}")
    print(f"USB_DIRECTORY_USB_DEVICE={device_id}")
    print(f"USB_DIRECTORY_STATE={'present' if final else 'absent'}")
    print(f"USB_DIRECTORY_ATTACHED={'yes' if attached else 'no'}")
    print("USB_DIRECTORY_TRANSPORT=usb-storage/scsi-hd/vvfat")
    print("USB_DIRECTORY_MODE=read-only")
    print(f"USB_DIRECTORY_PATH={final_dir}")
    print(f"USB_DIRECTORY_LABEL={final_label}")
    print(
        "USB_DIRECTORY_LABEL_CHARSET="
        + (final_label_charset if final_label_charset else "none")
    )
    print(f"USB_DIRECTORY_HARDWARE_PROFILE={profile_name}")
    print(f"USB_DIRECTORY_USB_VID={usb_vendor_id:04x}")
    print(f"USB_DIRECTORY_USB_PID={usb_product_id:04x}")
    print(f"USB_DIRECTORY_USB_MANUFACTURER={usb_manufacturer}")
    print(f"USB_DIRECTORY_USB_PRODUCT={usb_product}")
    print(f"USB_DIRECTORY_DISK_VENDOR={scsi_vendor}")
    print(f"USB_DIRECTORY_DISK_PRODUCT={scsi_product}")
    print(f"USB_DIRECTORY_PORT={usb_port}")
    print(
        "USB_DIRECTORY_DESCRIPTOR_STATE="
        + ("projected" if usb_identity_capable else "compat-until-vm-restart")
    )
    print(
        "USB_DIRECTORY_SERIAL_POLICY="
        + ("none" if usb_no_serial_capable else "topology-generated-compat")
    )
    print("USB_DIRECTORY_REFRESH=eject-remount")
except (OSError, ValueError, QMPError) as exc:
    print(f"[usb-directory] ERROR: {exc}", file=sys.stderr)
    raise SystemExit(1)
finally:
    sock.close()
PY
