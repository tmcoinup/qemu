#!/usr/bin/env bash
# Runtime display-channel control for a running G-11 VM.
# Uses the per-instance QMP socket and never stores credentials.
set -euo pipefail
umask 077

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_ROOT="$(cd "$HERE/.." && pwd)"

usage() {
    cat <<'EOF'
usage:
  ctl-vm.sh ID ACTION [--vms-dir ABS|--vm-dir ABS|--instances-dir ABS]

Actions:
  status          show the QMP/display/stream endpoints
  window-hide     hide the native SDL window without stopping the VM
  window-show     show and redraw the native SDL window
  stream-pause    pause the fb-shm display listener (sidecar stays alive)
  stream-resume   resume the fb-shm display listener
  stream-only     resume fb-shm first, then hide the SDL window
  window-only     show SDL first, then pause fb-shm when it exists

V-11 compatibility aliases: sdl-hide, sdl-show, fb-pause, fb-resume,
sdl-only.  Window actions target G-11's default SDL backend; GTK does not
provide a safe hide/show hook.
EOF
}

VM_ID=${1:-}
if [[ "$VM_ID" == -h || "$VM_ID" == --help ]]; then
    usage
    exit 0
fi
[[ "$VM_ID" =~ ^[1-9][0-9]*$ ]] || {
    usage >&2
    exit 2
}
shift

ACTION=""
VMS_DIR_CLI=""
VM_DIR_CLI=""
INSTANCES_DIR_CLI=""
while (($#)); do
    case "$1" in
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
            [[ -z "$ACTION" ]] || { echo "未知参数: $1" >&2; exit 2; }
            ACTION=$1
            shift
            ;;
    esac
done
ACTION=${ACTION:-status}
case "$ACTION" in
    sdl-hide) ACTION=window-hide ;;
    sdl-show) ACTION=window-show ;;
    fb-pause) ACTION=stream-pause ;;
    fb-resume) ACTION=stream-resume ;;
    sdl-only) ACTION=window-only ;;
esac
case "$ACTION" in
    status|window-hide|window-show|stream-pause|stream-resume|stream-only|window-only) ;;
    *) echo "未知动作: $ACTION" >&2; usage >&2; exit 2 ;;
esac

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
vm_storage_validate_instance_tree "$VM_ID"
if vm_storage_v11_collision "$VM_ID"; then
    echo "实例目录带有 V-11 标记，拒绝用 G-11 控制器连接" >&2
    exit 1
fi

RUN_DIR=$(vm_storage_instance_run_dir "$VM_ID")
QMP_SOCK=$(vm_storage_run_path "$VM_ID" qmp)
STREAM_SOCKET="$RUN_DIR/fb-shm.sock"
[[ -d "$RUN_DIR" && ! -L "$RUN_DIR" ]] || {
    echo "vm${VM_ID} runtime 目录不存在或不安全: $RUN_DIR" >&2
    exit 1
}
[[ -S "$QMP_SOCK" && ! -L "$QMP_SOCK" ]] || {
    echo "vm${VM_ID} QMP socket 不存在；VM 可能没有运行: $QMP_SOCK" >&2
    exit 1
}
command -v python3 >/dev/null 2>&1 || {
    echo "运行期显示控制需要 python3" >&2
    exit 1
}

python3 - "$QMP_SOCK" "vm${VM_ID}" "$ACTION" <<'PY'
import json
import socket
import sys

qmp_path, expected_name, action = sys.argv[1:]


class QMPError(RuntimeError):
    pass


sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(5)
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

    sequence = 0

    def command(name, arguments=None):
        global sequence
        sequence += 1
        ident = f"g11-display-{sequence}"
        request = {"execute": name, "id": ident}
        if arguments is not None:
            request["arguments"] = arguments
        stream.write((json.dumps(request) + "\r\n").encode())
        while True:
            line = stream.readline()
            if not line:
                raise QMPError(f"QMP 在 {name} 响应前关闭")
            response = json.loads(line)
            if response.get("id") != ident:
                continue
            if "error" in response:
                detail = response["error"].get("desc", "QMP error")
                raise QMPError(f"{name}: {detail}")
            return response.get("return")

    command("qmp_capabilities")
    identity = command("query-name") or {}
    actual_name = identity.get("name")
    if actual_name != expected_name:
        raise QMPError(
            f"QMP 身份不匹配：期望 {expected_name}，实际 {actual_name!r}"
        )

    if action == "status":
        display = command("query-display-options") or {}
        print(f"VM_NAME={actual_name}")
        print(f"DISPLAY_BACKEND={display.get('type', 'unknown')}")
        print("PAUSE_STATE=not-exposed-by-qmp")
    elif action == "window-hide":
        command("display-pause", {"name": "sdl2"})
        print("OK: SDL window hidden")
    elif action == "window-show":
        command("display-resume", {"name": "sdl2"})
        print("OK: SDL window shown and redraw requested")
    elif action == "stream-pause":
        command("display-pause", {"name": "fb-shm"})
        print("OK: fb-shm listener paused")
    elif action == "stream-resume":
        command("display-resume", {"name": "fb-shm"})
        print("OK: fb-shm listener resumed")
    elif action == "stream-only":
        # Do not hide the only usable window until the stream listener exists.
        command("display-resume", {"name": "fb-shm"})
        command("display-pause", {"name": "sdl2"})
        print("OK: stream-only mode requested")
    elif action == "window-only":
        command("display-resume", {"name": "sdl2"})
        try:
            command("display-pause", {"name": "fb-shm"})
            print("OK: window-only mode requested")
        except QMPError as exc:
            if "no DisplayChangeListener" not in str(exc):
                raise
            print("OK: SDL window shown (this VM has no fb-shm listener)")
except (QMPError, OSError, ValueError, json.JSONDecodeError) as exc:
    print(f"显示控制失败: {exc}", file=sys.stderr)
    raise SystemExit(1)
finally:
    sock.close()
PY

if [[ "$ACTION" == status ]]; then
    printf 'QMP_SOCKET=%s\n' "$QMP_SOCK"
    if [[ -S "$STREAM_SOCKET" && ! -L "$STREAM_SOCKET" ]]; then
        printf 'FB_SHM_SOCKET=ready:%s\n' "$STREAM_SOCKET"
    else
        printf 'FB_SHM_SOCKET=absent:%s\n' "$STREAM_SOCKET"
    fi
    if [[ -x "$DEPLOY_ROOT/fb-shm-stream.sh" ]]; then
        "$DEPLOY_ROOT/fb-shm-stream.sh" status "$VM_ID" || true
    fi
fi
