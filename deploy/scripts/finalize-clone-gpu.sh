#!/usr/bin/env bash
# finalize-clone-gpu.sh — clone 首启后的一键 GPU Provider 收尾工具。
#
# 使用场景：
#   clone-from-base.sh 会在首启前预写一次 DriverProvider，但 Windows 首次
#   枚举新显示设备时会按 viogpudo.inf 把 Provider 写回 "Red Hat, Inc."。
#   等 clone 首次进过桌面/respawn-stealth 完成后，跑本脚本即可：
#
#     deploy/scripts/finalize-clone-gpu.sh 1
#
# 如果希望修完后自动重启 VM：
#
#     STABLE_DISPLAY=0 HOST_RESERVE_CORES=0 \
#       deploy/scripts/finalize-clone-gpu.sh 1 --restart -- --proxy
#
# 说明：
#   - 可普通用户运行；脚本会用 sudo -E 重新执行自身。
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
    # 挂载 Windows 系统盘。保留环境变量，方便 --restart 复用 DISPLAY /
    # STABLE_DISPLAY / HOST_RESERVE_CORES 等启动参数。
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
    exec sudo -E "$SELF" "${SUDO_ARGS[@]}"
fi

ORIG_USER="${SUDO_USER:-ubuntu}"
ORIG_GROUP="$(id -gn "$ORIG_USER" 2>/dev/null || echo "$ORIG_USER")"
VM_DIR="/home/ubuntu/images/vms/${INSTANCE}"
FIX_SCRIPT="$HERE/host-fix-gpu-devpkey.sh"
START_SCRIPT="$HERE/start-vm.sh"

[[ -x "$FIX_SCRIPT" ]] || { echo "ERROR: missing $FIX_SCRIPT" >&2; exit 1; }
[[ -d "$VM_DIR" ]] || { echo "ERROR: VM dir not found: $VM_DIR" >&2; exit 1; }

echo ">> instance: $INSTANCE"
echo ">> step 1/2: 离线修复 GPU DriverProvider / DriverDesc"
"$FIX_SCRIPT" "$INSTANCE" "${FIX_ARGS[@]}"

chown -R "${ORIG_USER}:${ORIG_GROUP}" "$VM_DIR" 2>/dev/null || true

if [[ "$RESTART" != 1 || "$DRY_RUN" == 1 ]]; then
    echo ">> done: 已修复。下一次启动后设备管理器 Provider 应显示 profile.GPU_VENDOR。"
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

sudo -u "$ORIG_USER" env \
    DISPLAY="${DISPLAY:-:1}" \
    STABLE_DISPLAY="${STABLE_DISPLAY:-0}" \
    HOST_RESERVE_CORES="${HOST_RESERVE_CORES:-auto}" \
    QEMU_SVC_CPUS="${QEMU_SVC_CPUS:-${QEMU_SERVICE_CPUS:-0}}" \
    QEMU_SERVICE_CPUS="${QEMU_SERVICE_CPUS:-${QEMU_SVC_CPUS:-0}}" \
    "$START_SCRIPT" "$INSTANCE" "${START_ARGS[@]}"
