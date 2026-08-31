#!/usr/bin/env bash
# Verify a pending G-11 RTX 2080 or Tesla V100 driver branch after cold boot.
set -euo pipefail
# depmod indexes are standard system metadata and must remain readable by
# unprivileged status/repair checks.  State files use explicit install modes.
umask 022

readonly STATE_ROOT=/var/lib/vmate/g11-vgpu-branch-switch
readonly PENDING_STATE="$STATE_ROOT/pending-reboot.state"
readonly BRANCH_STATE="$STATE_ROOT/current.state"
readonly RTX2080_VENDOR_DEVICE=10de:1e82
readonly V100_SXM2_16GB_VENDOR_DEVICE=10de:1db1
POSTBOOT_BRANCH=unknown
POSTBOOT_KERNEL=unknown
POSTBOOT_GPU=unknown

log() { printf '[g11-driver-postboot] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

state_value() {
    local file=$1 key=$2
    [[ -r "$file" && ! -L "$file" ]] || return 1
    awk -F= -v wanted="$key" \
        '$1 == wanted {value=substr($0, index($0, "=")+1); count++}
         END {if (count == 1) print value; else exit 1}' "$file"
}

write_branch_state() {
    local branch=$1 status=$2 kernel=$3 gpu=$4 temp
    install -d -o root -g root -m 0755 "$STATE_ROOT"
    temp=$(mktemp "$STATE_ROOT/.current.state.XXXXXXXX")
    {
        echo 'schema=1'
        printf 'updated_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'branch=%s\n' "$branch"
        printf 'status=%s\n' "$status"
        printf 'kernel=%s\n' "$kernel"
        printf 'gpu=%s\n' "$gpu"
    } >"$temp"
    install -o root -g root -m 0644 "$temp" "$BRANCH_STATE"
    rm -f -- "$temp"
}

postboot_exit() {
    local rc=$?
    trap - EXIT
    if ((rc != 0)); then
        write_branch_state "$POSTBOOT_BRANCH" postboot-failed \
            "$POSTBOOT_KERNEL" "$POSTBOOT_GPU" || true
        log "冷启动验收失败（exit=$rc）；pending 标记已保留"
    fi
    exit "$rc"
}

assert_no_qemu() {
    local exe executable
    for exe in /proc/[0-9]*/exe; do
        [[ -L "$exe" ]] || continue
        executable=$(readlink -- "$exe" 2>/dev/null || true)
        executable=${executable% (deleted)}
        case "${executable##*/}" in
            qemu-system-x86_64|qemu-system-x86_64.g11.real)
                die '启动后验收前已出现 QEMU；保持 VM 关闭并重新启动宿主机'
                ;;
        esac
    done
}

secure_boot_must_be_disabled() {
    local state
    state=$(mokutil --sb-state 2>&1 || true)
    grep -Fqi 'SecureBoot disabled' <<<"$state" && return 0
    grep -Fqi 'EFI variables are not supported' <<<"$state" && return 0
    grep -Fqi "doesn't support Secure Boot" <<<"$state" && return 0
    printf '%s\n' "$state" >&2
    die 'Secure Boot 未确认关闭'
}

wait_for_runtime() {
    local gpu=$1 expected_version=$2 expected_policy=$3
    local types_dir="/sys/bus/pci/devices/$gpu/mdev_supported_types"
    local -i attempts_left=60
    while ((attempts_left-- > 0)); do
        if [[ "$(cat /sys/module/nvidia/version 2>/dev/null || true)" == \
                    "$expected_version" ]] && \
                systemctl is-active --quiet nvidia-vgpu-mgr.service && \
                [[ -d "$types_dir" ]] && \
                find "$types_dir" -mindepth 1 -maxdepth 1 -type d \
                    -print -quit 2>/dev/null | grep -q .; then
            grep -Fxq "$expected_policy" /etc/vgpu_unlock/g11-hook.state && return 0
        fi
        sleep 1
    done
    die "60 秒内驱动、manager、Hook 或 mdev types 未就绪：$gpu"
}

main() {
    ((EUID == 0)) || die '必须由 root 运行'
    [[ -f "$PENDING_STATE" && ! -L "$PENDING_STATE" ]] || {
        log '没有 pending-reboot 状态；无需验收'
        return 0
    }

    local branch kernel gpu gpu_id expected_version expected_package expected_policy
    local gpu_kind actual_vendor actual_device config
    branch=$(state_value "$PENDING_STATE" branch) || die 'pending 状态缺少 branch'
    kernel=$(state_value "$PENDING_STATE" kernel) || die 'pending 状态缺少 kernel'
    gpu=$(state_value "$PENDING_STATE" gpu) || die 'pending 状态缺少 gpu'
    gpu_id=$(state_value "$PENDING_STATE" gpu_vendor_device) || \
        die 'pending 状态缺少 gpu_vendor_device'
    POSTBOOT_BRANCH=$branch
    POSTBOOT_KERNEL=$kernel
    POSTBOOT_GPU=$gpu
    [[ "$kernel" == "$(uname -r)" ]] || \
        die "pending 内核为 $kernel，当前为 $(uname -r)"
    case "$gpu_id" in
        "$RTX2080_VENDOR_DEVICE") gpu_kind=rtx2080 ;;
        "$V100_SXM2_16GB_VENDOR_DEVICE") gpu_kind=v100 ;;
        *) die "pending GPU 身份不受支持：$gpu_id" ;;
    esac
    actual_vendor=$(cat "/sys/bus/pci/devices/$gpu/vendor" 2>/dev/null || true)
    actual_device=$(cat "/sys/bus/pci/devices/$gpu/device" 2>/dev/null || true)
    actual_vendor=${actual_vendor#0x}
    actual_device=${actual_device#0x}
    [[ "${actual_vendor,,}:${actual_device,,}" == "$gpu_id" ]] || \
        die "GPU 不在 pending 记录的 BDF/身份：$gpu ($gpu_id)"

    case "$branch" in
        r535)
            expected_version=535.161.05
            expected_package=nvidia-vgpu-ubuntu-535
            expected_policy=r535_unlock_policy=consumer
            ;;
        r570)
            expected_version=570.172.07
            expected_package=nvidia-vgpu-ubuntu-570
            if [[ "$gpu_kind" == v100 ]]; then
                expected_policy=r570_unlock_policy=native
            else
                expected_policy=r570_unlock_policy=consumer
            fi
            ;;
        r580-lab)
            [[ "$gpu_kind" == rtx2080 ]] || die 'V100 不允许 R580 pending 分支'
            expected_version=580.159.01
            expected_package=nvidia-vgpu-ubuntu-580
            expected_policy=r580_unlock_policy=consumer-lab
            ;;
        *) die "未知 pending 分支：$branch" ;;
    esac

    trap postboot_exit EXIT
    secure_boot_must_be_disabled
    assert_no_qemu
    depmod -a "$kernel"
    local module_index="/lib/modules/$kernel/modules.dep" module_index_mode
    module_index_mode=$(stat -c '%a' "$module_index" 2>/dev/null || true)
    if [[ ! "$module_index_mode" =~ ^[0-7]+$ ]] || \
            ! (((8#$module_index_mode & 0044) == 0044)); then
        die "模块索引权限异常：$module_index（mode=${module_index_mode:-missing}）"
    fi
    [[ "$(modinfo -F version nvidia 2>/dev/null || true)" == "$expected_version" ]] || \
        die "磁盘模块版本不是 $expected_version"
    [[ "$(modinfo -F license nvidia 2>/dev/null || true)" == NVIDIA ]] || \
        die '磁盘模块不是 NVIDIA 闭源 RM'
    [[ -z "$(modinfo -F signer nvidia 2>/dev/null || true)" ]] || \
        die '模块带签名，拒绝验收'
    [[ "$(dpkg-query -W -f='${db:Status-Status}/${Version}' \
            "$expected_package" 2>/dev/null || true)" == "installed/$expected_version" ]] || \
        die "dpkg 分支不是 $expected_package/$expected_version"
    wait_for_runtime "$gpu" "$expected_version" "$expected_policy"
    if [[ "$gpu_kind" == v100 ]]; then
        config=/etc/vmate/g11-vgpu-host.conf
        [[ -f "$config" && ! -L "$config" && -r "$config" ]] || \
            die "V100 宿主策略缺失或不安全：$config"
        if [[ "$branch" == r535 ]]; then
            grep -Fxq 'VGPU_HOST_FB_MODE=equal' "$config" || \
                die 'V100/R535 宿主策略不是 equal'
            grep -Fxq 'VGPU_HOST_FB_TIER_MB=1024' "$config" || \
                die 'V100/R535 宿主策略不是固定 1024MB'
            systemctl is-active --quiet vmate-vgpu-mixed-mode.timer && \
                die 'V100/R535 不应运行 mixed-mode timer'
        else
            grep -Fxq 'VGPU_HOST_FB_MODE=mixed' "$config" || \
                die 'V100/R570 宿主策略不是 mixed'
            grep -Fxq 'VGPU_RESOURCE_PROFILE_1024=V100X-1Q' "$config" || \
                die 'V100/R570 缺少 V100X-1Q 映射'
            grep -Fxq 'VGPU_RESOURCE_PROFILE_2048=V100X-2Q' "$config" || \
                die 'V100/R570 缺少 V100X-2Q 映射'
            systemctl is-active --quiet vmate-vgpu-mixed-mode.timer || \
                die 'V100/R570 mixed-mode timer 未运行'
            /usr/local/libexec/qemu-vgpu-mixed-mode status "$gpu"
        fi
    fi
    nvidia-smi --query-gpu=driver_version,name,memory.total --format=csv,noheader
    if journalctl -k -b --no-pager 2>/dev/null | grep -Eiq 'NVRM:.*Xid'; then
        journalctl -k -b --no-pager 2>/dev/null | grep -Ei 'NVRM:.*Xid' >&2 || true
        die '本次冷启动出现 NVIDIA XID'
    fi

    write_branch_state "$branch" ready "$kernel" "$gpu"
    rm -f -- "$PENDING_STATE"
    trap - EXIT
    log "$branch 冷启动验收完成：闭源 RM、未签名模块、manager、mdev、无 XID"
}

main "$@"
