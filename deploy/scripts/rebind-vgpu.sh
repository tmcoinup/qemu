#!/usr/bin/env bash
# Re-enumerate a changed native GRID profile using the existing Driver Store.
# Keep the R535 console isolated until the normal offline driver/mode checks pass.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/vm-storage.sh
source "$here/lib/vm-storage.sh"
# shellcheck source=lib/identity-uniqueness.sh
source "$here/lib/identity-uniqueness.sh"

usage() {
    cat <<'EOF'
usage: ./deploy/scripts/vmctl.sh gpu-rebind ID [options]

  --sdl | --gtk          local window backend (default: SDL)
  --proxy | --no-proxy   proxy preference for the normal start
  --cpu-isolate=true|false
  --memory-prealloc=true|false
                        retain these preferences in both boots
  --vms-dir ABS | --vm-dir ABS | --instances-dir ABS
                        select the existing VM storage
  --no-start            stop after successful offline validation
  --dry-run             print the sequence without starting or mounting a VM

Run as the desktop VM owner. The temporary standard VGA window keeps the new
NVIDIA device present with display=off. Let Windows bind its existing signed
driver, then run shutdown.exe /s /t 0 inside Windows and wait for the window to
exit. Offline validation must pass before the normal vGPU window can start.
This wrapper does not run a driver installer or a guest identity package.
EOF
}

die() { echo "[gpu-rebind] $*" >&2; exit 2; }
if [[ ${1:-} == -h || ${1:-} == --help ]]; then usage; exit 0; fi
VM_ID=${1:-}
vm_storage_validate_id "$VM_ID" || exit 2
shift
BACKEND=sdl
NORMAL_PROXY=()
CPU_ARG=()
MEMORY_ARG=()
STORAGE_ARGS=()
NORMAL_START=1
DRY_RUN=0
while (($#)); do
    case "$1" in
        --sdl|--gtk) BACKEND=${1#--}; shift ;;
        --proxy|--no-proxy) NORMAL_PROXY=( "$1" ); shift ;;
        --cpu-isolate=true|--cpu-isolate=false)
            ((${#CPU_ARG[@]} == 0)) || die '--cpu-isolate 只能指定一次'
            CPU_ARG=( "$1" ); shift ;;
        --memory-prealloc=true|--memory-prealloc=false)
            ((${#MEMORY_ARG[@]} == 0)) || die '--memory-prealloc 只能指定一次'
            MEMORY_ARG=( "$1" ); shift ;;
        --vms-dir|--vm-dir|--instances-dir)
            (($# >= 2)) || die "$1 需要绝对路径"
            ((${#STORAGE_ARGS[@]} == 0)) || die '存储路径只能指定一次'
            STORAGE_ARGS=( "$1" "$2" ); shift 2 ;;
        --vms-dir=*|--vm-dir=*|--instances-dir=*)
            ((${#STORAGE_ARGS[@]} == 0)) || die '存储路径只能指定一次'
            STORAGE_ARGS=( "${1%%=*}" "${1#*=}" ); shift ;;
        --no-start) NORMAL_START=0; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "不支持的参数: $1" ;;
    esac
done

case "${STORAGE_ARGS[0]:-}" in
    --vms-dir) vm_storage_select_root "${STORAGE_ARGS[1]}" ;;
    --vm-dir) vm_storage_select_instance_dir "$VM_ID" "${STORAGE_ARGS[1]}" ;;
    --instances-dir) vm_storage_select_instances_dir "${STORAGE_ARGS[1]}" ;;
esac
vm_storage_init
vm_storage_require_namespace_ready "$VM_ID"
CONF=$(vm_storage_config_path "$VM_ID")
[[ -f "$CONF" && -r "$CONF" ]] || die "已有 VM 配置不存在或不可读: $CONF"
[[ -f "$(vm_storage_disk_path "$VM_ID")" ]] || die '已有系统盘不存在'
declare -A rebind_config=()
_g11_identity_uniqueness_parse_config "$CONF" rebind_config ||
    die "$G11_IDENTITY_UNIQUENESS_MESSAGE"
PERSISTED_MODE=${rebind_config[SPOOF_MODE]:-B}
case "$PERSISTED_MODE" in
    B|off) ;;
    *) die '此入口仅用于 B/off 的原生 GRID 档位重新绑定' ;;
esac
CONF_HASH=$(sha256sum <"$CONF")
check_config_unchanged() {
    [[ -r "$CONF" && $(sha256sum <"$CONF") == "$CONF_HASH" ]] ||
        die 'vm.conf 在流程中发生变化；停止后续操作，请检查配置'
}

safe_cmd=( "$here/scripts/start-vm.sh" "$VM_ID" "${STORAGE_ARGS[@]}"
    "--driver-install-${BACKEND}" "${CPU_ARG[@]}" "${MEMORY_ARG[@]}"
    --monitor-sync --no-proxy --no-stream )
sync_cmd=( "$here/scripts/sync-monitor-profile.sh" "$VM_ID" --force )
normal_cmd=( "$here/scripts/start-vm.sh" "$VM_ID" "${STORAGE_ARGS[@]}"
    "--${BACKEND}" "${NORMAL_PROXY[@]}" "${CPU_ARG[@]}" "${MEMORY_ARG[@]}"
    --monitor-sync )

print_command() { printf ' %q' "$@"; printf '\n'; }
if ((DRY_RUN)); then
    echo '[gpu-rebind] 只读预览：以下步骤尚未执行。'
    print_command "${safe_cmd[@]}"
    echo '[gpu-rebind] 等 Windows 完整关机，再验证新 PnP 对应的正式驱动和显示模式：'
    print_command "${sync_cmd[@]}"
    if ((NORMAL_START)); then
        echo '[gpu-rebind] 仅验证返回 0 才启动：'
        print_command "${normal_cmd[@]}"
    fi
    exit 0
fi
((EUID != 0)) || die '请用拥有 VM/桌面的普通用户运行；不要 sudo 整个封装'

ensure_sudo_ticket() {
    [[ -z ${SUDO_PASSWORD:-} ]] || return 0
    sudo -n true 2>/dev/null && return 0
    echo '[gpu-rebind] 离线校验需要宿主 sudo 票据；请在当前终端输入（不保存密码）。'
    sudo -v
}
ensure_sudo_ticket
check_config_unchanged
echo "[gpu-rebind] vm${VM_ID}: 打开临时标准 VGA 窗口，新 NVIDIA 显卡仍挂载供 Windows 枚举。"
echo '[gpu-rebind] 登录 Windows，等待设备管理器中 NVIDIA 显卡完成识别。'
echo '[gpu-rebind] 若尚未出现，设备管理器 → 操作 → 扫描检测硬件改动。'
echo '[gpu-rebind] 保存工作后，在 Windows 的 CMD 执行：'
echo '  shutdown.exe /s /t 0'
echo '[gpu-rebind] 等窗口随关机自然退出；不要直接关窗口或按 Ctrl+C。'
echo '[gpu-rebind] 此阶段只让 Windows 绑定现有驱动；客体身份包在正常启动后更新。'

safe_rc=0
VGPU_GUEST_FINISH_TARGET='' STREAM_OUTPUT='' "${safe_cmd[@]}" || safe_rc=$?
if ((safe_rc != 0)); then
    echo "[gpu-rebind] 安全窗口退出 rc=${safe_rc}；停止，不执行后续离线写入。" >&2
    exit "$safe_rc"
fi
check_config_unchanged
ensure_sudo_ticket
check_config_unchanged
echo '[gpu-rebind] 窗口已退出；检查磁盘是否干净关闭，并认证新显卡的驱动/NV_Modes。'
sync_rc=0
VM_START_LOCK_HELD=0 MONITOR_SYNC_SPOOF_MODE="$PERSISTED_MODE" \
    "${sync_cmd[@]}" || sync_rc=$?
check_config_unchanged
case "$sync_rc" in
    0) ;;
    12|13)
        echo '[gpu-rebind] 新显卡仍未通过驱动绑定认证，保持 VM 停止。' >&2
        echo '[gpu-rebind] 若现有 Driver Store 没有匹配驱动，请用正式 GRID 安装入口修复：' >&2
        printf '[gpu-rebind] ' >&2
        print_command env "VM_ROOT=$VM_ROOT" "VMS_DIR=$VMS_DIR" \
            "VM_INSTANCES_DIR=$VM_INSTANCES_DIR" "VM_INSTANCE_DIR=${VM_INSTANCE_DIR:-}" \
            "VM_INSTANCE_ID=${VM_INSTANCE_ID:-}" \
            "$here/scripts/vmctl.sh" driver-install "$VM_ID" >&2
        echo '[gpu-rebind] 该安装入口需要通过安全运行时环境提供 GUEST_PASS；请勿使用旧显卡 PnP 记录替代认证。' >&2
        exit "$sync_rc" ;;
    10)
        echo '[gpu-rebind] 驱动已认证，但新显卡还没有显示器缓存；保持停止，请重跑本入口完成枚举。' >&2
        exit 10 ;;
    11)
        echo '[gpu-rebind] Windows 仍处于休眠或未干净关机；保持停止，请先按休眠恢复教程处理。' >&2
        exit 11 ;;
    *)
        echo "[gpu-rebind] 离线认证失败 rc=${sync_rc}，保持停止；不要跳过显示同步。" >&2
        exit "$sync_rc" ;;
esac
echo '[gpu-rebind] 新显卡驱动及显示模式认证通过；vm.conf 全部字段保持原值。'
if ((NORMAL_START)); then
    echo '[gpu-rebind] 恢复正常 vGPU 窗口。'
    exec "${normal_cmd[@]}"
fi
echo '[gpu-rebind] 已完成绑定，按 --no-start 保持关机。下次启动：'
print_command "${normal_cmd[@]}"
