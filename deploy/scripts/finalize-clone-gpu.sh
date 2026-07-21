#!/usr/bin/env bash
# finalize-clone-gpu.sh — clone 首启后的一键 GPU Provider 收尾工具。
#
# 使用场景：
#   clone 阶段不写 SYSTEM hive。等 Windows 首次枚举显示设备、clone 进入过
#   桌面且 respawn-stealth 完成后，跑本脚本补齐 DriverProvider：
#
#     deploy/scripts/finalize-clone-gpu.sh 1
#
# 如果希望修完后自动重启 VM：
#
#     STABLE_DISPLAY=1 HOST_RESERVE_CORES=0 \
#       deploy/scripts/finalize-clone-gpu.sh 1 --restart -- --proxy
#
# 说明：
#   - 可普通用户运行；脚本会用 sudo 重新执行自身，并显式传递受支持的环境变量。
#   - 真正离线写 Windows hive 的动作仍由 host-fix-gpu-devpkey.sh 完成。
#   - -- 后面的参数原样传给 start-vm.sh，仅在 --restart 时生效。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SELF="$(readlink -f "$0")"

INSTANCE=""
RESTART=0
DRY_RUN=0
FIX_ARGS=()
START_ARGS=()

usage() {
    awk '
        NR == 1 { next }
        /^# ?/ { sub(/^# ?/, ""); print; next }
        /^#$/ { print ""; next }
        { exit }
    ' "$0" >&2
    exit "${1:-2}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage 0 ;;
        --restart)
            RESTART=1; shift ;;
        --no-restart)
            RESTART=0; shift ;;
        --dry-run)
            DRY_RUN=1
            FIX_ARGS+=("--dry-run"); shift ;;
        --)
            shift
            START_ARGS+=("$@")
            break ;;
        [0-9]*)
            if [[ -n "$INSTANCE" ]]; then
                echo "ERROR: instance 重复: $1" >&2
                usage 2
            fi
            INSTANCE="$1"; shift ;;
        *)
            echo "ERROR: unknown arg: $1" >&2
            usage 2 ;;
    esac
done

if [[ -z "$INSTANCE" ]]; then
    usage 2
fi

if [[ $EUID -ne 0 ]]; then
    # 需要 root 的原因是 host-fix-gpu-devpkey.sh 要 qemu-nbd + ntfs-3g
    # 挂载 Windows 系统盘。sudo -E 在部分 sudoers 策略下会被忽略；这里逐项传递
    # 离线修复和 --restart 真正支持的变量，不依赖 preserve-env 策略。
    SUDO_ARGS=("$INSTANCE")
    if [[ "$RESTART" == 1 ]]; then
        SUDO_ARGS+=("--restart")
    else
        SUDO_ARGS+=("--no-restart")
    fi
    SUDO_ARGS+=("${FIX_ARGS[@]}")
    if [[ ${#START_ARGS[@]} -gt 0 ]]; then
        SUDO_ARGS+=("--" "${START_ARGS[@]}")
    fi
    SUDO_ENV=(
        "VMS_DIR=${VMS_DIR:-}"
        "IMAGE_ROOT=${IMAGE_ROOT:-}"
        "QEMU_IMG=${QEMU_IMG:-}"
        "DISPLAY=${DISPLAY:-:1}"
        "HOST_RESERVE_CORES=${HOST_RESERVE_CORES:-auto}"
        "QEMU_SVC_CPUS=${QEMU_SVC_CPUS:-${QEMU_SERVICE_CPUS:-0}}"
        "QEMU_SERVICE_CPUS=${QEMU_SERVICE_CPUS:-${QEMU_SVC_CPUS:-0}}"
        "DISK=${DISK:-}"
        "NBD=${NBD:-}"
        "MOUNT=${MOUNT:-}"
        "PROVIDER=${PROVIDER:-}"
        "DEVICE_DESC=${DEVICE_DESC:-}"
        "SUBSYS_RE=${SUBSYS_RE:-}"
    )
    # 未设置时必须保持 unset，让转发的 --gpu-sdl-egl/--gpu-headless 仍能按
    # 启动器契约显式 opt-in GL；只有调用者确实设置过时才跨 sudo 边界传播。
    if [[ -n "${STABLE_DISPLAY+x}" ]]; then
        SUDO_ENV+=("STABLE_DISPLAY=$STABLE_DISPLAY")
    fi
    exec sudo -- /usr/bin/env \
        "${SUDO_ENV[@]}" \
        "$SELF" "${SUDO_ARGS[@]}"
fi

ORIG_USER="${SUDO_USER:-ubuntu}"
VMS_DIR="${VMS_DIR:-/home/ubuntu/images/vms}"
VMS_DIR="${VMS_DIR%/}"
[[ -n "$VMS_DIR" ]] || VMS_DIR="/"
VM_DIR="${VMS_DIR}/${INSTANCE}"
FIX_SCRIPT="$HERE/host-fix-gpu-devpkey.sh"
START_SCRIPT="$HERE/start-vm.sh"

[[ -x "$FIX_SCRIPT" ]] || { echo "ERROR: missing $FIX_SCRIPT" >&2; exit 1; }
[[ -d "$VM_DIR" ]] || { echo "ERROR: VM dir not found: $VM_DIR" >&2; exit 1; }

echo ">> instance: $INSTANCE"
echo ">> step 1/2: 离线修复 GPU Provider / Desc / 驱动签名关联"
"$FIX_SCRIPT" "$INSTANCE" "${FIX_ARGS[@]}"

# 离线修复通过 qemu-nbd 写入现有 overlay，不会改变宿主文件的 owner。这里绝不能
# 递归接管 VM_DIR：clone 的 `.base.qcow2` 是 root-owned 0444 的共享 base 硬链接，
# 对它 chown 会同时解除全局 base 和其它实例 pin 的密封状态。

if [[ "$RESTART" != 1 || "$DRY_RUN" == 1 ]]; then
    echo ">> done: 已修复。下次启动后 Provider 应显示 profile.GPU_VENDOR，"
    echo ">>       Digital Signer 应恢复为 Microsoft Windows Hardware Compatibility Publisher。"
    echo ">> 如需自动重启：deploy/scripts/finalize-clone-gpu.sh $INSTANCE --restart -- --proxy"
    exit 0
fi

echo ">> step 2/2: 以 $ORIG_USER 重新启动 VM"
if [[ ${#START_ARGS[@]} -eq 0 ]]; then
    echo ">> start args: <none>"
else
    printf '>> start args:'
    printf ' %q' "${START_ARGS[@]}"
    printf '\n'
fi

START_ENV=(
    "VMS_DIR=$VMS_DIR"
    "IMAGE_ROOT=${IMAGE_ROOT:-}"
    "QEMU_IMG=${QEMU_IMG:-}"
    "DISPLAY=${DISPLAY:-:1}"
    "HOST_RESERVE_CORES=${HOST_RESERVE_CORES:-auto}"
    "QEMU_SVC_CPUS=${QEMU_SVC_CPUS:-${QEMU_SERVICE_CPUS:-0}}"
    "QEMU_SERVICE_CPUS=${QEMU_SERVICE_CPUS:-${QEMU_SVC_CPUS:-0}}"
)
if [[ -n "${STABLE_DISPLAY+x}" ]]; then
    START_ENV+=("STABLE_DISPLAY=$STABLE_DISPLAY")
fi
sudo -u "$ORIG_USER" env \
    "${START_ENV[@]}" \
    "$START_SCRIPT" "$INSTANCE" "${START_ARGS[@]}"
