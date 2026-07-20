#!/usr/bin/env bash
# clone 发布后的离线客体处理与可复制命令输出。
#
# 主入口只负责事务和所有权；这里集中非致命的客体定制及用户提示，避免
# clone-from-base.sh 继续逼近项目 500 行上限。

if [[ "${_CLONE_POSTPROCESS_LOADED:-0}" == "1" ]]; then
    # shellcheck disable=SC2317 # source guard 兼容直接执行语法检查。
    return 0 2>/dev/null || exit 0
fi
_CLONE_POSTPROCESS_LOADED=1

# 返回值始终为 0：这两项处理失败不会使一个结构完整的 overlay 无法启动。
# 警告数通过 CLONE_POSTPROCESS_WARNINGS 返回，完成摘要不会再伪装成无警告成功。
clone_postprocess_guest() {
    local script_dir="${1:-}" vms_dir="${2:-}" disk="${3:-}"
    local instance="${4:-}"
    local devpkey_fix unattend_injector

    CLONE_POSTPROCESS_WARNINGS=0
    [[ -d "$script_dir" && -d "$vms_dir" &&
       -f "$disk" && ! -L "$disk" &&
       "$instance" =~ ^[1-9][0-9]{0,9}$ ]] || {
        echo "ERROR: clone 客体收尾参数非法" >&2
        return 1
    }

    devpkey_fix="$script_dir/host-fix-gpu-devpkey.sh"
    if [[ -x "$devpkey_fix" ]]; then
        echo ">> 重写 DEVPKEY DriverProvider / DeviceDesc（用新 profile.GPU_*）..."
        if ! VMS_DIR="$vms_dir" DISK="$disk" \
                "$devpkey_fix" "$instance" 2>&1 | sed 's/^/    /'; then
            echo "   WARN: host-fix-gpu-devpkey.sh 失败；首启脚本将尝试兜底。"
            echo "         若反复失败，请在 base 内执行 powercfg -h off 后完整关机。"
            CLONE_POSTPROCESS_WARNINGS=$((CLONE_POSTPROCESS_WARNINGS + 1))
        fi
    else
        echo "   WARN: 缺少可执行的 host-fix-gpu-devpkey.sh，已跳过离线 DEVPKEY 更新。"
        CLONE_POSTPROCESS_WARNINGS=$((CLONE_POSTPROCESS_WARNINGS + 1))
    fi

    unattend_injector="$script_dir/host-inject-unattend.sh"
    if [[ -x "$unattend_injector" ]]; then
        echo ">> 注入 OOBE unattend.xml（首启自动登录到桌面）..."
        if ! VMS_DIR="$vms_dir" DISK="$disk" \
                "$unattend_injector" "$instance" 2>&1 | sed 's/^/    /'; then
            echo "   WARN: host-inject-unattend.sh 失败，客体首启可能停在 OOBE。"
            CLONE_POSTPROCESS_WARNINGS=$((CLONE_POSTPROCESS_WARNINGS + 1))
        fi
    else
        echo "   WARN: 缺少可执行的 host-inject-unattend.sh，客体首启可能停在 OOBE。"
        CLONE_POSTPROCESS_WARNINGS=$((CLONE_POSTPROCESS_WARNINGS + 1))
    fi
}

clone_print_completion() {
    local instance="${1:-}" disk="${2:-}" base_name="${3:-}"
    local target_bytes="${4:-}" vms_dir="${5:-}" script_dir="${6:-}"
    local cpus="${7:-}" qemu="${8:-}" qemu_img="${9:-}"
    local allow_compatibility="${10:-0}" allow_migration="${11:-0}"
    local platform_status="${12:-}" warning_count="${13:-0}"
    local -a start_forward_args=("--cpus=$cpus" "--qemu=$qemu")

    if [[ "$allow_compatibility" == 1 || "$platform_status" == compatibility ]]; then
        start_forward_args+=("--allow-platform-compatibility")
    fi
    if [[ "$allow_migration" == 1 ]]; then
        start_forward_args+=("--migrate-storage-profile")
    fi

    echo ""
    if (( warning_count > 0 )); then
        echo "=== Done（含 $warning_count 条非致命警告）==="
    else
        echo "=== Done ==="
    fi
    echo "  instance:  $instance"
    echo "  disk:      $disk (qcow2 backed by base $base_name)"
    echo "  size:      $target_bytes bytes (Windows 可见容量)"
    printf '%s\n' \
        "  GPU 重对齐: D:\\工具\\respawn-stealth.exe 由 FirstLogonCommands 拉起一次"
    echo ""

    echo "下一步 — 启动:"
    printf '  VMS_DIR=%q QEMU_IMG=%q' "$vms_dir" "$qemu_img"
    printf ' %q' "$script_dir/start-vm.sh" "$instance" "${start_forward_args[@]}"
    printf '\n'
    echo "首启进桌面并完成一次重启/关机后，修正设备管理器 DriverProvider:"
    printf '  VMS_DIR=%q' "$vms_dir"
    printf ' %q' "$script_dir/finalize-clone-gpu.sh" "$instance"
    printf '\n'
    echo "如需修完自动重新启动:"
    printf '  VMS_DIR=%q QEMU_IMG=%q STABLE_DISPLAY=%q HOST_RESERVE_CORES=%q' \
        "$vms_dir" "$qemu_img" 0 0
    printf ' %q' "$script_dir/finalize-clone-gpu.sh" "$instance" \
        --restart -- "${start_forward_args[@]}" --proxy
    printf '\n'
    echo ""
    echo "克隆 VM 复用 base 系统盘内容，但使用新的 CPU/主板/GPU/MAC/UUID/启动盘身份。"
    echo "首次开机会按 unattend.xml 完成 OOBE，并由本地 FirstLogonCommands 做客体收尾。"
    echo ""
    echo "⚠️ 未执行 sysprep 时，Windows SID/MachineGUID 仍与 base 同源；"
    echo "   需要独立机器身份时，应先 sysprep base 再运行 seal-base.sh。"
}
