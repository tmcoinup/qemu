#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# root 离线显示缓存工具的实例生命周期门禁。
#
# start/stop 以最终 VM 用户运行，而 host-fix-display-cache 以 root 挂载 NBD。
# 本库先确定 VM 目录所有者，并复用 clone 已审核的降权调用：
#   目标用户 -> sv_instance_lock_path -> 0600 锁文件 -> root FD 8 flock。
# 因此不会错误落到 /run/user/0，也不会与 sv-cli 的实例锁路径分叉。
# ---------------------------------------------------------------------------

if [[ "${_HOST_DISPLAY_CACHE_GUARD_LOADED:-0}" == "1" ]]; then
    # shellcheck disable=SC2317 # source guard 兼容直接执行诊断。
    return 0 2>/dev/null || exit 0
fi
_HOST_DISPLAY_CACHE_GUARD_LOADED=1

host_display_cache_resolve_vm_user() {
    local vm_dir="${1:-}" target_user="" target_uid owner_uid

    [[ -d "$vm_dir" && ! -L "$vm_dir" ]] || {
        echo "ERROR: VM 实例目录必须是非符号链接目录: $vm_dir" >&2
        return 1
    }
    owner_uid="$(stat -c '%u' -- "$vm_dir" 2>/dev/null)" || return 1
    [[ "$owner_uid" =~ ^[0-9]+$ && "$owner_uid" != 0 ]] || {
        echo "ERROR: VM 实例目录不能由 root 或未知用户拥有: $vm_dir" >&2
        return 1
    }

    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER:-}" != root ]]; then
        target_user="$SUDO_USER"
    elif [[ "${PKEXEC_UID:-}" =~ ^[1-9][0-9]*$ ]]; then
        target_user="$(id -nu "$PKEXEC_UID" 2>/dev/null)" || return 1
    else
        target_user="$(id -nu "$owner_uid" 2>/dev/null)" || return 1
    fi
    target_uid="$(id -u "$target_user" 2>/dev/null)" || {
        echo "ERROR: 无法解析最终 VM 用户: $target_user" >&2
        return 1
    }
    [[ "$target_uid" != 0 && "$target_uid" == "$owner_uid" ]] || {
        echo "ERROR: 调用用户与 VM 实例目录所有者不一致: user=$target_user dir=$vm_dir" >&2
        return 1
    }
    printf '%s|%s\n' "$target_user" "$target_uid"
}

host_display_cache_acquire_instance_lock() {
    local instance="${1:-}" vm_dir="${2:-}" lock_library="${3:-}"
    local lifecycle_library="${4:-}" resolved

    HOST_DISPLAY_VM_USER=
    HOST_DISPLAY_VM_UID=
    HOST_DISPLAY_INSTANCE_LOCK=
    [[ "$instance" =~ ^[1-9][0-9]{0,9}$ ]] || {
        echo "ERROR: 显示缓存修复实例号必须是 1..10 位正整数" >&2
        return 1
    }
    [[ -f "$lock_library" && ! -L "$lock_library" &&
       -f "$lifecycle_library" && ! -L "$lifecycle_library" ]] || {
        echo "ERROR: 实例生命周期锁库缺失或非法" >&2
        return 1
    }
    command -v flock >/dev/null 2>&1 || {
        echo "ERROR: 显示缓存修复需要 util-linux 的 flock" >&2
        return 1
    }

    resolved="$(host_display_cache_resolve_vm_user "$vm_dir")" || return 1
    IFS='|' read -r HOST_DISPLAY_VM_USER HOST_DISPLAY_VM_UID <<<"$resolved"
    # shellcheck source=/dev/null
    source "$lifecycle_library" || return 1
    HOST_DISPLAY_INSTANCE_LOCK="$(
        clone_lifecycle_user_lock_path \
            "$HOST_DISPLAY_VM_USER" "$lock_library" "$instance"
    )" || return 1

    [[ -f "$HOST_DISPLAY_INSTANCE_LOCK" &&
       ! -L "$HOST_DISPLAY_INSTANCE_LOCK" &&
       "$(stat -c '%u' -- "$HOST_DISPLAY_INSTANCE_LOCK" 2>/dev/null)" == \
           "$HOST_DISPLAY_VM_UID" &&
       "$(stat -c '%a' -- "$HOST_DISPLAY_INSTANCE_LOCK" 2>/dev/null)" == 600 ]] ||
        return 1
    exec 8<"$HOST_DISPLAY_INSTANCE_LOCK" || return 1
    if [[ ! "$HOST_DISPLAY_INSTANCE_LOCK" -ef "/proc/$$/fd/8" ||
          "$(stat -Lc '%u' -- "/proc/$$/fd/8" 2>/dev/null)" != \
              "$HOST_DISPLAY_VM_UID" ||
          "$(stat -Lc '%a' -- "/proc/$$/fd/8" 2>/dev/null)" != 600 ]]; then
        exec 8<&-
        echo "ERROR: 实例锁在打开期间被替换或属性变化" >&2
        return 1
    fi
    if ! flock -n 8; then
        exec 8<&-
        echo "ERROR: 实例 $instance 正在启动、运行、停止或执行离线维护" >&2
        return 1
    fi
}

host_display_cache_require_profile_hash() {
    local path="${1:-}" expected="${2:-}" current

    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || return 1
    declare -F stealth_profile_sha256 >/dev/null 2>&1 || return 1
    current="$(stealth_profile_sha256 "$path")" || return 1
    [[ "$current" == "$expected" ]]
}
