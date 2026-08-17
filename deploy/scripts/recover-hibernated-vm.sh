#!/usr/bin/env bash
# Recover a Windows VM from hibernation/Fast Startup without mounting its
# offline NTFS read-write, changing drivers, or reusing the legacy vGPU finish
# package.  The only guest-side action is an explicit command typed by the
# administrator in a local standard-VGA rescue window.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
    cat >&2 <<'EOF'
usage: ./deploy/scripts/recover-hibernated-vm.sh <vm_id> [options]

  --rescue-sdl       local SDL standard-VGA rescue (default)
  --rescue-gtk       local GTK standard-VGA rescue
  --proxy            remember --proxy for the normal-start command printed
                     after recovery; rescue itself always uses --no-proxy
  --no-proxy         print the normal-start command without --proxy (default)
  --vms-dir ABS      use an alternate complete VM root
  --vm-dir ABS       use the exact numeric VM bundle directory
  --instances-dir ABS
                     use an alternate numeric-instance parent
  -h, --help         show this help

This wrapper never starts the normal vGPU automatically.  It waits for a
guest-initiated full shutdown, then performs the existing fail-closed offline
monitor sync and prints the exact normal-start command.  Run it as the desktop
VM owner; use `sudo -v` separately and never sudo the whole wrapper.
EOF
}

vm_id_is_supported() {
    local id=${1:-}
    [[ "$id" =~ ^[1-9][0-9]*$ && ${#id} -le 10 ]] || return 1
    ((10#$id <= 2147483647))
}

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
    usage
    exit 0
fi

VM_ID=${1:-}
if ! vm_id_is_supported "$VM_ID"; then
    usage
    echo "[hibernate-recovery] vm_id 必须是 1..2147483647" >&2
    exit 2
fi
shift

RESCUE_MODE=rescue-sdl
NORMAL_PROXY=0
STORAGE_SELECTOR=""
STORAGE_VALUE=""
STORAGE_ARGS=()

while (( $# > 0 )); do
    case "$1" in
        --rescue-sdl)
            RESCUE_MODE=rescue-sdl
            shift
            ;;
        --rescue-gtk)
            RESCUE_MODE=rescue-gtk
            shift
            ;;
        --proxy)
            NORMAL_PROXY=1
            shift
            ;;
        --no-proxy)
            NORMAL_PROXY=0
            shift
            ;;
        --vms-dir|--vm-dir|--instances-dir)
            option=$1
            (( $# >= 2 )) || {
                echo "[hibernate-recovery] $option 需要一个绝对路径" >&2
                exit 2
            }
            [[ -z "$STORAGE_SELECTOR" ]] || {
                echo "[hibernate-recovery] --vms-dir、--vm-dir 与 --instances-dir 只能选择一个" >&2
                exit 2
            }
            STORAGE_SELECTOR=$option
            STORAGE_VALUE=$2
            STORAGE_ARGS=( "$option" "$2" )
            shift 2
            ;;
        --vms-dir=*|--vm-dir=*|--instances-dir=*)
            option=${1%%=*}
            value=${1#*=}
            [[ -n "$value" ]] || {
                echo "[hibernate-recovery] $option 需要一个绝对路径" >&2
                exit 2
            }
            [[ -z "$STORAGE_SELECTOR" ]] || {
                echo "[hibernate-recovery] --vms-dir、--vm-dir 与 --instances-dir 只能选择一个" >&2
                exit 2
            }
            STORAGE_SELECTOR=$option
            STORAGE_VALUE=$value
            STORAGE_ARGS=( "$option" "$value" )
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "[hibernate-recovery] 未知参数: $1" >&2
            usage
            exit 2
            ;;
    esac
done
unset option value

if [[ -n "$STORAGE_SELECTOR" &&
      ( "$STORAGE_VALUE" != /* || "$STORAGE_VALUE" == / ) ]]; then
    echo "[hibernate-recovery] $STORAGE_SELECTOR 必须是非根绝对路径: $STORAGE_VALUE" >&2
    exit 2
fi

if (( EUID == 0 )); then
    echo "[hibernate-recovery] 不要用 sudo/root 运行整个恢复封装。" >&2
    echo "[hibernate-recovery] 请回到拥有 VM/桌面会话的普通用户；只需先单独执行 sudo -v。" >&2
    exit 2
fi

# sync-monitor-profile.sh selects alternate storage through the same exported
# storage contract used by start-vm.  start-vm still receives the explicit CLI
# selector and validates it before QEMU starts.
case "$STORAGE_SELECTOR" in
    --vms-dir)
        VM_ROOT=$STORAGE_VALUE
        VMS_DIR=$STORAGE_VALUE
        VM_STORAGE_COMPAT_FALLBACK=0
        unset VM_INSTANCE_DIR VM_INSTANCE_ID VM_INSTANCES_DIR
        unset VM_SHARED_DIR VM_CONFIG_DIR VM_DISK_DIR VM_BASE_DIR VM_NVRAM_DIR
        unset VM_CONTROL_DIR VM_RUN_DIR VM_LOG_DIR VM_ASSET_DIR
        unset VM_DISK_ARCHIVE_DIR VM_BASE_ARCHIVE_DIR VM_NVRAM_BACKUP_DIR
        export VM_ROOT VMS_DIR VM_STORAGE_COMPAT_FALLBACK
        ;;
    --vm-dir)
        VM_INSTANCE_DIR=$STORAGE_VALUE
        VM_INSTANCE_ID=$VM_ID
        VM_STORAGE_COMPAT_FALLBACK=0
        export VM_INSTANCE_DIR VM_INSTANCE_ID VM_STORAGE_COMPAT_FALLBACK
        ;;
    --instances-dir)
        VM_INSTANCES_DIR=$STORAGE_VALUE
        VM_STORAGE_COMPAT_FALLBACK=0
        unset VM_INSTANCE_DIR VM_INSTANCE_ID
        export VM_INSTANCES_DIR VM_STORAGE_COMPAT_FALLBACK
        ;;
esac

ensure_sudo_ticket() {
    [[ -z "${SUDO_PASSWORD:-}" ]] || return 0
    command -v sudo >/dev/null 2>&1 || {
        echo "[hibernate-recovery] 离线同步需要 sudo，但宿主没有 sudo" >&2
        return 1
    }
    sudo -n true 2>/dev/null && return 0
    echo "[hibernate-recovery] 离线同步稍后需要 sudo；现在安全缓存宿主凭据（不写入仓库）。" >&2
    sudo -v
}

ensure_sudo_ticket || exit $?

echo "[hibernate-recovery] vm${VM_ID}: 即将打开本地标准 VGA 救援窗口（不挂 vGPU）。"
echo "[hibernate-recovery] 进入 Windows 后，以管理员身份打开 CMD，只执行下面两行："
echo
echo '  reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" /v HiberbootEnabled /t REG_DWORD /d 0 /f'
echo '  shutdown.exe /s /f /t 0'
echo
echo "[hibernate-recovery] 等 Windows 自己关机、窗口自然退出；不要关闭窗口，也不要按 Ctrl+C。"
echo "[hibernate-recovery] 这会关闭 Fast Startup，但不会由宿主删除 hiberfil.sys。"

rescue_cmd=(
    "$here/scripts/start-vm.sh" "$VM_ID"
    "${STORAGE_ARGS[@]}"
    "--${RESCUE_MODE}" --no-monitor-sync --no-spoof --no-stream --no-shmem
    --no-proxy --extra ""
)
set +e
VGPU_GUEST_FINISH_TARGET= STREAM_OUTPUT= "${rescue_cmd[@]}"
rescue_rc=$?
set -e
if (( rescue_rc != 0 )); then
    echo "[hibernate-recovery] ERROR: 救援 QEMU 退出 rc=${rescue_rc}；未做任何离线同步。" >&2
    echo "[hibernate-recovery] 排除窗口被关闭/Ctrl+C 等问题后，重跑同一条恢复命令。" >&2
    exit "$rescue_rc"
fi

# The first sudo timestamp may expire while the user is in Windows.  Refresh
# it only through sudo's own prompt; no credential is read or persisted here.
ensure_sudo_ticket || exit $?

echo "[hibernate-recovery] Windows 救援窗口已正常退出；现在以只读预检开头强制刷新显示器缓存。"
set +e
VM_START_LOCK_HELD=0 "$here/scripts/sync-monitor-profile.sh" "$VM_ID" --force
sync_rc=$?
set -e
case "$sync_rc" in
    0)
        ;;
    10)
        echo "[hibernate-recovery] DEFER: Windows 尚未缓存 NVIDIA 显示器实例。" >&2
        echo "[hibernate-recovery] 可先正常启动枚举；再次完整关机后重跑显示器同步。" >&2
        exit 10
        ;;
    11)
        echo "[hibernate-recovery] ERROR: 卷仍处于休眠/Fast Startup 或未完成干净关机。" >&2
        echo "[hibernate-recovery] 未强挂载、未删除 hiberfil.sys；请重跑本恢复命令并让 Windows 自己关机。" >&2
        exit 11
        ;;
    *)
        echo "[hibernate-recovery] ERROR: 离线显示器同步失败（rc=${sync_rc}）；保持 VM 停止。" >&2
        exit "$sync_rc"
        ;;
esac

normal_cmd=( "./deploy/scripts/start-vm.sh" "$VM_ID" "${STORAGE_ARGS[@]}" )
(( NORMAL_PROXY == 0 )) || normal_cmd+=( --proxy )
printf '[hibernate-recovery] 完成。现在可正常启动：'
printf ' %q' "${normal_cmd[@]}"
printf '\n'
