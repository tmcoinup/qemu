#!/usr/bin/env bash
# Compatibility entry for a clean, host-branch-matched GRID guest reinstall.
#
# The old implementation ran setup.exe from WinRM session 0, then fell back to
# pnputil.  Besides being unreliable, that path could let an old 1680x1050
# GraphicsDrivers cache become active while R535 took over the local console.
# R535 then page-rounded the scanout message, rejected head delivery, and left
# QEMU with an all-zero REGION.  Route every supported install through the
# active-desktop RunOnce wrapper, which preserves the old partial-install
# cleanup and guards 1920x1080 before, during, and after setup.exe.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/vm-storage.sh
source "$here/lib/vm-storage.sh"
# shellcheck source=lib/vgpu-driver-assets.sh
source "$here/lib/vgpu-driver-assets.sh"
vm_storage_init
VM_ID=${VM_ID:-1}
IP_OVERRIDE=""
NO_REBOOT=0
START_AFTER_SYNC=0
TIMEOUT_INSTALL=""
WINRM_PORT=5985
LAB_USERNET=0

usage() {
    cat <<'EOF'
usage: ./deploy/install-vgpu-driver.sh [VM_ID] [--ip IPv4] [--timeout SEC]
       [--winrm-port PORT] [--lab-usernet] [--start]

Clean-reinstall wrapper for install-vgpu-driver-gui.sh.  Existing/partial
NVIDIA packages are removed first.  The VM must already be in the isolated
driver-install topology.  After the signed setup succeeds this command performs
a full guest shutdown, authenticates/writes the reviewed offline NV_Modes, and
leaves the VM stopped.  --start enters the normal vGPU display afterward.
EOF
}

while (( $# > 0 )); do
    case "$1" in
        --ip)
            (( $# >= 2 )) || { echo "--ip requires an address" >&2; exit 2; }
            IP_OVERRIDE=$2
            shift 2
            ;;
        --no-reboot)
            NO_REBOOT=1
            shift
            ;;
        --timeout)
            (( $# >= 2 )) || { echo "--timeout requires seconds" >&2; exit 2; }
            TIMEOUT_INSTALL=$2
            shift 2
            ;;
        --winrm-port)
            (( $# >= 2 )) || { echo "--winrm-port requires a port" >&2; exit 2; }
            WINRM_PORT=$2
            shift 2
            ;;
        --lab-usernet)
            LAB_USERNET=1
            shift
            ;;
        --start)
            START_AFTER_SYNC=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *.*.*.*)
            IP_OVERRIDE=$1
            shift
            ;;
        [1-9]|[1-9][0-9]*)
            VM_ID=$1
            shift
            ;;
        *)
            echo "unknown arg: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if (( NO_REBOOT )); then
    echo "[install-vgpu] --no-reboot 已停用：session-0 安装无法保护 R535 本地 console" >&2
    echo "[install-vgpu] 请直接运行本命令；完成后它会自动验收 1920x1080 再重启" >&2
    exit 2
fi
if [[ -n "$TIMEOUT_INSTALL" ]] &&
        { [[ ! "$TIMEOUT_INSTALL" =~ ^[1-9][0-9]*$ ]] ||
          ((TIMEOUT_INSTALL > 3600)); }; then
    echo "[install-vgpu] --timeout 必须是 1..3600 秒" >&2
    exit 2
fi
[[ "$WINRM_PORT" =~ ^[1-9][0-9]*$ ]] && ((WINRM_PORT <= 65535)) || {
    echo "[install-vgpu] --winrm-port 必须是 1..65535" >&2
    exit 2
}

vm_storage_require_namespace_ready "$VM_ID"
vgpu_select_driver_stack

# Offline convergence after the guest shutdown needs root for qemu-nbd.  Obtain
# only a normal sudo timestamp before the first guest write; never place the
# credential in argv, a file, or this repository.
if [[ "$VGPU_SELECTED_DRIVER_MONITOR_SYNC_MODE" != off ]] &&
        ((EUID != 0)) && ! sudo -n true 2>/dev/null; then
    if [[ -n "${SUDO_PASSWORD:-}" ]]; then
        : # sync-monitor-profile.sh consumes the approved runtime channel.
    elif [[ -t 0 ]]; then
        echo "[install-vgpu] 先取得临时 sudo 票据，供安装后的只读认证/离线同步使用"
        sudo -v
    else
        echo "[install-vgpu] 非交互运行缺少 sudo 票据；请先 sudo -v 或通过安全环境变量 SUDO_PASSWORD 提供" >&2
        exit 1
    fi
fi

args=( "$VM_ID" --clean-existing )
[[ -z "$IP_OVERRIDE" ]] || args+=( --ip "$IP_OVERRIDE" )
[[ -z "$TIMEOUT_INSTALL" ]] || args+=( --timeout "$TIMEOUT_INSTALL" )
args+=( --winrm-port "$WINRM_PORT" )
((LAB_USERNET == 0)) || args+=( --lab-usernet )
echo "[install-vgpu] 使用临时标准 VGA + mdev display=off + active-desktop 安装路径"
"$here/install-vgpu-driver-gui.sh" "${args[@]}"

echo "[install-vgpu] 官方 GRID 安装收据通过；请求 Windows 完整关机"
"$here/scripts/stop-vm.sh" "$VM_ID" --graceful-only

if [[ "$VGPU_SELECTED_DRIVER_MONITOR_SYNC_MODE" != off ]]; then
    # stop-vm returns once QEMU is gone, but start-vm may still be releasing
    # mdev/swtpm and its launch lock.  Own that lock across the reviewed
    # offline SYSTEM-hive transaction.
    start_lock=$(vm_storage_run_preferred_path "$VM_ID" start.lock)
    exec {START_LOCK_FD}>"$start_lock"
    if ! flock -w 60 "$START_LOCK_FD"; then
        echo "[install-vgpu] QEMU 已关机，但 60 秒内未取得 start lock；未离线写盘" >&2
        exit 1
    fi
    if [[ "$VGPU_SELECTED_DRIVER_MONITOR_SYNC_MODE" == locked-grid ]]; then
        echo "[install-vgpu] guest 已完整关机；认证 ${VGPU_SELECTED_DRIVER_LABEL} 并写入 R535 page-safe NV_Modes"
    else
        echo "[install-vgpu] guest 已完整关机；认证 ${VGPU_SELECTED_DRIVER_LABEL} 并同步 EDID（保留 NVIDIA NV_Modes）"
    fi
    VM_START_LOCK_HELD=1 "$here/scripts/sync-monitor-profile.sh" "$VM_ID" --force
    echo "[install-vgpu] PASS: ${VGPU_SELECTED_DRIVER_BRANCH} 驱动、完整关机、离线 monitor 收敛全部完成"
else
    echo "[install-vgpu] PASS: ${VGPU_SELECTED_DRIVER_BRANCH}/${VGPU_SELECTED_DRIVER_LABEL} 正式签名驱动和完整关机已完成；跳过未审核的离线 monitor 流程"
fi
if ((START_AFTER_SYNC)); then
    if [[ -n "${START_LOCK_FD:-}" ]]; then
        exec {START_LOCK_FD}>&-
    fi
    exec "$here/scripts/start-vm.sh" "$VM_ID"
fi
echo "[install-vgpu] VM 保持关机；正常启动: ./deploy/scripts/vmctl.sh start ${VM_ID}"
