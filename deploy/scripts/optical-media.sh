#!/usr/bin/env bash
# Hot-add/remove a reviewed, read-only G-11 optical drive on a running VM.
set -euo pipefail
umask 077

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_ROOT="$(cd "$HERE/.." && pwd)"

usage() {
    cat <<'EOF'
usage:
  ./deploy/scripts/optical-media.sh ID status [storage selector]
  ./deploy/scripts/optical-media.sh ID mount /absolute/file.iso [--replace] [storage selector]
  ./deploy/scripts/optical-media.sh ID eject [storage selector]

storage selector (choose at most one):
  --vms-dir ABS | --vm-dir ABS | --instances-dir ABS

Normal VM startup has no optical drive.  mount hot-adds a read-only USB
BOT/SCSI CD-ROM; eject removes the whole device again.  Replacing a different
inserted ISO needs --replace.  This command does not restart Windows or QEMU.
EOF
}

VM_ID=${1:-}
ACTION=${2:-}
if [[ "$VM_ID" == -h || "$VM_ID" == --help || "$VM_ID" == help ]]; then
    usage
    exit 0
fi
[[ "$VM_ID" =~ ^[1-9][0-9]*$ && -n "$ACTION" ]] || {
    usage >&2
    exit 2
}
shift 2

case "$ACTION" in
    insert) ACTION=mount ;;
    unmount|remove) ACTION=eject ;;
esac
case "$ACTION" in
    status|mount|eject) ;;
    *) echo "未知光驱动作: $ACTION" >&2; usage >&2; exit 2 ;;
esac

MEDIA_INPUT=""
if [[ "$ACTION" == mount ]]; then
    (($# >= 1)) || { echo "mount 需要 ISO 路径" >&2; exit 2; }
    MEDIA_INPUT=$1
    shift
fi

REPLACE=0
VMS_DIR_CLI=""
VM_DIR_CLI=""
INSTANCES_DIR_CLI=""
while (($#)); do
    case "$1" in
        --replace)
            [[ "$ACTION" == mount ]] || {
                echo "--replace 只能与 mount 一起使用" >&2
                exit 2
            }
            ((REPLACE == 0)) || { echo "--replace 只能指定一次" >&2; exit 2; }
            REPLACE=1
            shift
            ;;
        --vms-dir|--vm-dir|--instances-dir)
            (($# >= 2)) || { echo "$1 需要一个绝对路径" >&2; exit 2; }
            option=$1
            value=$2
            shift 2
            case "$option" in
                --vms-dir)
                    [[ -z "$VMS_DIR_CLI" ]] || { echo "--vms-dir 只能指定一次" >&2; exit 2; }
                    VMS_DIR_CLI=$value
                    ;;
                --vm-dir)
                    [[ -z "$VM_DIR_CLI" ]] || { echo "--vm-dir 只能指定一次" >&2; exit 2; }
                    VM_DIR_CLI=$value
                    ;;
                --instances-dir)
                    [[ -z "$INSTANCES_DIR_CLI" ]] || { echo "--instances-dir 只能指定一次" >&2; exit 2; }
                    INSTANCES_DIR_CLI=$value
                    ;;
            esac
            ;;
        --vms-dir=*|--vm-dir=*|--instances-dir=*)
            option=${1%%=*}
            value=${1#*=}
            [[ -n "$value" ]] || { echo "$option 需要一个绝对路径" >&2; exit 2; }
            shift
            case "$option" in
                --vms-dir)
                    [[ -z "$VMS_DIR_CLI" ]] || { echo "--vms-dir 只能指定一次" >&2; exit 2; }
                    VMS_DIR_CLI=$value
                    ;;
                --vm-dir)
                    [[ -z "$VM_DIR_CLI" ]] || { echo "--vm-dir 只能指定一次" >&2; exit 2; }
                    VM_DIR_CLI=$value
                    ;;
                --instances-dir)
                    [[ -z "$INSTANCES_DIR_CLI" ]] || { echo "--instances-dir 只能指定一次" >&2; exit 2; }
                    INSTANCES_DIR_CLI=$value
                    ;;
            esac
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "未知参数: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

# shellcheck source=../lib/vm-storage.sh
source "$DEPLOY_ROOT/lib/vm-storage.sh"
selector_count=0
[[ -z "$VMS_DIR_CLI" ]] || selector_count=$((selector_count + 1))
[[ -z "$VM_DIR_CLI" ]] || selector_count=$((selector_count + 1))
[[ -z "$INSTANCES_DIR_CLI" ]] || selector_count=$((selector_count + 1))
((selector_count <= 1)) || {
    echo "--vms-dir、--vm-dir 与 --instances-dir 只能选择一个" >&2
    exit 2
}
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
    echo "实例目录带有 V-11 标记，拒绝用 G-11 光驱控制器连接" >&2
    exit 1
fi

INSTANCE_DIR=$(vm_storage_instance_dir "$VM_ID")
CONF=$(vm_storage_config_path "$VM_ID")
[[ -d "$INSTANCE_DIR" && ! -L "$INSTANCE_DIR" &&
   -f "$CONF" && ! -L "$CONF" ]] || {
    echo "vm${VM_ID} 不是完整、安全的 G-11 实例: $INSTANCE_DIR" >&2
    exit 1
}

MEDIA_PATH=""
if [[ "$ACTION" == mount ]]; then
    [[ "$MEDIA_INPUT" != *$'\n'* && "$MEDIA_INPUT" != *$'\r'* ]] || {
        echo "ISO 路径含不支持的控制字符" >&2
        exit 2
    }
    if [[ "$MEDIA_INPUT" == /* ]]; then
        media_lexical=$(realpath -ms -- "$MEDIA_INPUT")
    else
        media_lexical=$(realpath -ms -- "$PWD/$MEDIA_INPUT")
    fi
    MEDIA_PATH=$(realpath -e -- "$media_lexical" 2>/dev/null) || {
        echo "ISO 不存在: $MEDIA_INPUT" >&2
        exit 1
    }
    [[ "$MEDIA_PATH" == "$media_lexical" &&
       -f "$MEDIA_PATH" && ! -L "$MEDIA_PATH" && -r "$MEDIA_PATH" &&
       -s "$MEDIA_PATH" ]] || {
        echo "ISO 必须是非符号链接、可读且非空的普通文件: $MEDIA_INPUT" >&2
        exit 1
    }
    [[ "${MEDIA_PATH,,}" == *.iso ]] || {
        echo "只允许挂载 .iso 文件: $MEDIA_PATH" >&2
        exit 2
    }
fi

QMP_SOCK=$(vm_storage_run_path "$VM_ID" qmp)
[[ -S "$QMP_SOCK" && ! -L "$QMP_SOCK" ]] || {
    echo "vm${VM_ID} QMP socket 不存在；请先启动 VM: $QMP_SOCK" >&2
    exit 1
}
command -v python3 >/dev/null 2>&1 || {
    echo "运行期光驱控制需要 python3" >&2
    exit 1
}
command -v flock >/dev/null 2>&1 || {
    echo "运行期光驱控制需要 flock" >&2
    exit 1
}

OPTICAL_LOCK=$(vm_storage_run_path "$VM_ID" optical.lock)
[[ ! -L "$OPTICAL_LOCK" ]] || {
    echo "光驱操作锁不得是符号链接: $OPTICAL_LOCK" >&2
    exit 1
}
exec {OPTICAL_LOCK_FD}>"$OPTICAL_LOCK"
flock -w 10 "$OPTICAL_LOCK_FD" || {
    echo "等待 vm${VM_ID} 光驱操作锁超时" >&2
    exit 1
}

# shellcheck source=../lib/hardware-profiles.sh
source "$DEPLOY_ROOT/lib/hardware-profiles.sh"
optical_drive_profile_load "$OPTICAL_DRIVE_DEFAULT_PROFILE"

python3 - "$QMP_SOCK" "vm${VM_ID}" "$ACTION" "$MEDIA_PATH" "$REPLACE" \
    "$ODD_PROFILE" "$ODD_BRAND" "$ODD_MODEL" "$ODD_FIRMWARE_REV" \
    "$ODD_INTERFACE" "$ODD_FORM_FACTOR" "$ODD_SERIAL_POLICY" <<'PY'
import json
import os
import socket
import sys
import time

(
    qmp_path,
    expected_name,
    action,
    requested_media,
    replace_text,
    profile,
    brand,
    model,
    firmware,
    interface,
    form_factor,
    serial_policy,
) = sys.argv[1:]
replace = replace_text == "1"
device_id = "g11-odd"
usb_device_id = "g11-odd-usb"
backend_id = "g11-odd-media"
try:
    expected_vendor, expected_product = model.split(" ", 1)
except ValueError as exc:
    raise SystemExit(f"[optical-media] ERROR: 光驱目录型号无法分成 vendor/product: {model}") from exc
if len(expected_vendor.encode("ascii")) > 8 or len(expected_product.encode("ascii")) > 16:
    raise SystemExit("[optical-media] ERROR: 光驱目录超出 SCSI INQUIRY 字段长度")


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
            raise QMPError("QMP 在 greeting 前关闭")
        greeting = json.loads(line)
        if "QMP" in greeting:
            break

    sequence = [0]

    def command(name, arguments=None):
        sequence[0] += 1
        ident = f"g11-optical-{sequence[0]}"
        request = {"execute": name, "id": ident}
        if arguments is not None:
            request["arguments"] = arguments
        stream.write((json.dumps(request) + "\r\n").encode())
        while True:
            response_line = stream.readline()
            if not response_line:
                raise QMPError(f"QMP 在 {name} 响应前关闭")
            response = json.loads(response_line)
            if response.get("id") != ident:
                continue
            if "error" in response:
                detail = response["error"].get("desc", "QMP error")
                raise QMPError(f"{name}: {detail}")
            return response.get("return")

    command("qmp_capabilities")
    actual_name = (command("query-name") or {}).get("name")
    if actual_name != expected_name:
        raise QMPError(
            f"QMP 身份不匹配：期望 {expected_name}，实际 {actual_name!r}"
        )

    def peripheral_types():
        return {
            item.get("name"): item.get("type", "")
            for item in (command("qom-list", {"path": "/machine/peripheral"}) or [])
            if item.get("name") != "type"
        }

    def named_backend_present():
        return any(
            item.get("node-name") == backend_id
            for item in (command("query-named-block-nodes") or [])
        )

    def usb_bot_no_serial_supported():
        properties = command(
            "device-list-properties", {"typename": "usb-bot"}
        ) or []
        return any(item.get("name") == "x-no-serial" for item in properties)

    usb_no_serial_capable = usb_bot_no_serial_supported()

    def is_optical(entry):
        qdev = entry.get("qdev", "")
        inserted = entry.get("inserted") or {}
        return (
            entry.get("device") == backend_id
            or qdev == device_id
            or qdev.endswith("/" + device_id)
            or inserted.get("node-name") == backend_id
        )

    def optical_entry():
        matches = [entry for entry in (command("query-block") or []) if is_optical(entry)]
        if len(matches) > 1:
            raise QMPError("运行中的 VM 有多个 g11-odd 光驱，拒绝猜测目标")
        return matches[0] if matches else None

    def usb_bot_attached():
        path = f"/machine/peripheral/{usb_device_id}"
        return bool(command("qom-get", {"path": path, "property": "attached"}))

    def attach_usb_bot():
        path = f"/machine/peripheral/{usb_device_id}"
        command(
            "qom-set",
            {"path": path, "property": "attached", "value": True},
        )
        if not usb_bot_attached():
            raise QMPError("usb-bot 返回成功，但仍未向 Windows 发布设备")

    def validate_managed_device(allow_detached=False):
        devices = peripheral_types()
        actual_type = devices.get(device_id)
        if actual_type is None:
            raise QMPError("手动光驱设备不存在")
        if actual_type != "child<scsi-cd>":
            raise QMPError(
                f"检测到旧版开机常驻光驱 ({actual_type})；"
                "ide.0 不支持热拔，请完整关机后用新 start-vm.sh 普通启动一次"
            )
        usb_type = devices.get(usb_device_id)
        if usb_type != "child<usb-bot>":
            raise QMPError(
                f"{usb_device_id} 类型异常或缺失: {usb_type!r}"
            )
        if not usb_bot_attached() and not allow_detached:
            raise QMPError(
                "usb-bot 尚未 attached，Windows 看不到光驱；重新执行 mount 修复"
            )
        if usb_no_serial_capable:
            path = f"/machine/peripheral/{usb_device_id}"
            no_serial = command(
                "qom-get", {"path": path, "property": "x-no-serial"}
            )
            if not bool(no_serial):
                raise QMPError("usb-bot 未启用规范的无序列号描述符")
        path = f"/machine/peripheral/{device_id}"
        actual = {
            key: command("qom-get", {"path": path, "property": key})
            for key in ("vendor", "product", "ver", "serial", "hotpluggable")
        }
        expected = {
            "vendor": expected_vendor,
            "product": expected_product,
            "ver": firmware,
            "serial": "",
            "hotpluggable": True,
        }
        if actual != expected:
            raise QMPError(
                "g11-odd 设备属性与审核目录不一致，拒绝控制: "
                + json.dumps(actual, ensure_ascii=False, sort_keys=True)
            )
        entry = optical_entry()
        if entry is None:
            raise QMPError("g11-odd 设备存在但没有可控块后端")
        return entry

    def wait_device_absent(target):
        deadline = time.monotonic() + 8
        while target in peripheral_types():
            if time.monotonic() >= deadline:
                raise QMPError(f"等待热拔设备超时: {target}")
            time.sleep(0.05)

    def remove_managed_stack():
        devices = peripheral_types()
        if device_id in devices:
            validate_managed_device(allow_detached=True)
            command("device_del", {"id": device_id})
            wait_device_absent(device_id)
        devices = peripheral_types()
        if usb_device_id in devices:
            if devices[usb_device_id] != "child<usb-bot>":
                raise QMPError(
                    f"{usb_device_id} 类型异常: {devices[usb_device_id]}"
                )
            command("device_del", {"id": usb_device_id})
            wait_device_absent(usb_device_id)
        if named_backend_present():
            command("blockdev-del", {"node-name": backend_id})
        devices = peripheral_types()
        if device_id in devices or usb_device_id in devices or named_backend_present():
            raise QMPError("热拔返回成功，但手动光驱设备栈仍然存在")

    def cleanup_failed_add():
        try:
            devices = peripheral_types()
            if device_id in devices and devices[device_id] == "child<scsi-cd>":
                command("device_del", {"id": device_id})
                wait_device_absent(device_id)
        except (OSError, ValueError, QMPError):
            pass
        try:
            devices = peripheral_types()
            if usb_device_id in devices and devices[usb_device_id] == "child<usb-bot>":
                command("device_del", {"id": usb_device_id})
                wait_device_absent(usb_device_id)
        except (OSError, ValueError, QMPError):
            pass
        try:
            if named_backend_present():
                command("blockdev-del", {"node-name": backend_id})
        except (OSError, ValueError, QMPError):
            pass

    def add_managed_stack(media_path):
        devices = peripheral_types()
        if device_id in devices or usb_device_id in devices or named_backend_present():
            raise QMPError("手动光驱 ID 已被占用，拒绝覆盖")
        try:
            command(
                "blockdev-add",
                {
                    "driver": "raw",
                    "node-name": backend_id,
                    "read-only": True,
                    "file": {"driver": "file", "filename": media_path},
                },
            )
            usb_arguments = {
                "driver": "usb-bot",
                "id": usb_device_id,
                "bus": "xhci.0",
                "port": "4",
                "attached": False,
            }
            if usb_no_serial_capable:
                usb_arguments["x-no-serial"] = True
            # Compatibility for a QEMU process started before x-no-serial was
            # added: omit the property entirely. QEMU then generates a valid
            # topology serial instead of the invalid serial="" descriptor.
            command("device_add", usb_arguments)
            command(
                "device_add",
                {
                    "driver": "scsi-cd",
                    "id": device_id,
                    "drive": backend_id,
                    "bus": f"{usb_device_id}.0",
                    "vendor": expected_vendor,
                    "product": expected_product,
                    "ver": firmware,
                    "serial": "",
                    "bootindex": -1,
                },
            )
            # usb-bot hotplug is deliberately two-phase: QEMU keeps the USB
            # device hidden until all SCSI LUNs exist. Publish it only after
            # scsi-cd is complete, otherwise Windows never enumerates a drive.
            attach_usb_bot()
        except (OSError, ValueError, QMPError):
            cleanup_failed_add()
            raise
        return validate_managed_device()

    def media_filename(entry):
        inserted = entry.get("inserted") or {}
        return inserted.get("file") or (inserted.get("image") or {}).get("filename")

    devices = peripheral_types()
    current = None
    current_detached = False
    if device_id in devices:
        current = validate_managed_device(
            allow_detached=action in ("mount", "eject")
        )
        current_detached = not usb_bot_attached()
    elif usb_device_id in devices or named_backend_present():
        if action == "status":
            raise QMPError("发现不完整的手动光驱设备栈；请先执行 eject 清理")
        remove_managed_stack()

    current_media = media_filename(current) if current else None
    if action == "mount":
        if current is None:
            add_managed_stack(requested_media)
        elif current_media and os.path.realpath(current_media) == requested_media:
            if not bool((current.get("inserted") or {}).get("ro")):
                raise QMPError("当前 ISO 不是只读后端，拒绝幂等成功")
            if current_detached:
                # Repair stacks created by the pre-fix wrapper without an
                # eject/re-add cycle or guest reboot.
                attach_usb_bot()
        else:
            if current_media and not replace:
                raise QMPError(
                    "光驱已有另一张 ISO；确认要换盘时在命令末尾加 --replace"
                )
            command(
                "blockdev-change-medium",
                {
                    "id": device_id,
                    "filename": requested_media,
                    "format": "raw",
                    "read-only-mode": "read-only",
                    "force": True,
                },
            )
            # Publish only after the requested replacement is installed, so
            # Windows can never enumerate the stale medium during repair.
            if current_detached:
                attach_usb_bot()
    elif action == "eject":
        remove_managed_stack()

    final = optical_entry()
    final_media = media_filename(final) if final else None
    if action == "mount":
        if final is None:
            raise QMPError("QMP 返回成功，但手动光驱没有出现")
        validate_managed_device()
        if not final_media or os.path.realpath(final_media) != requested_media:
            raise QMPError("QMP 返回成功，但最终介质不是请求的 ISO")
        if not bool((final.get("inserted") or {}).get("ro")):
            raise QMPError("最终介质不是只读，拒绝报告成功")
    elif action == "eject" and final is not None:
        raise QMPError("QMP 返回成功，但光驱设备仍然存在")

    print(f"VM_NAME={actual_name}")
    print(f"OPTICAL_DEVICE={device_id}")
    print(f"OPTICAL_STATE={'present' if final else 'absent'}")
    print(f"OPTICAL_ATTACHED={'yes' if final and usb_bot_attached() else 'no'}")
    print(f"OPTICAL_PROFILE={profile}")
    print(f"OPTICAL_BRAND={brand}")
    print(f"OPTICAL_MODEL={model}")
    print(f"OPTICAL_FIRMWARE={firmware}")
    print(f"OPTICAL_INTERFACE={interface}")
    print("OPTICAL_TRANSPORT=usb-bot/scsi-cd")
    print(f"OPTICAL_FORM_FACTOR={form_factor}")
    print(f"OPTICAL_SERIAL_POLICY={serial_policy}")
    print(
        "OPTICAL_USB_SERIAL_POLICY="
        + ("none" if usb_no_serial_capable else "topology-generated-compat")
    )
    print(f"MEDIA_STATE={'inserted' if final_media else 'empty' if final else 'absent'}")
    print(f"MEDIA_PATH={final_media or ''}")
    print(
        "MEDIA_READ_ONLY="
        + ("yes" if final_media and bool((final.get("inserted") or {}).get("ro")) else "n/a")
    )
    tray = final.get("tray_open") if final else None
    print(
        f"TRAY_STATE={'absent' if final is None else 'open' if tray else 'closed' if tray is not None else 'unknown'}"
    )
except (OSError, ValueError, QMPError) as exc:
    print(f"[optical-media] ERROR: {exc}", file=sys.stderr)
    raise SystemExit(1)
finally:
    sock.close()
PY
