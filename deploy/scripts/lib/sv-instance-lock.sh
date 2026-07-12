#!/bin/bash
# ---------------------------------------------------------------------------
# VM 实例生命周期锁路径
#
# start-vm 与 stop-vm 必须调用同一函数，才能串行化 QMP/TPM/TAP/socket 的创建与
# 收尾。优先使用 systemd-logind 为当前 UID 创建的私有 /run/user/<uid>；无该目录
# 的 cron/最小系统回退到 /tmp 下经过 owner/type/mode 校验的 0700 私有目录。
# ---------------------------------------------------------------------------

sv_lock_dir_is_private() {
    local directory="$1"
    local owner mode permissions

    [[ -d "$directory" && ! -L "$directory" ]] || return 1
    owner="$(stat -c '%u' -- "$directory" 2>/dev/null)" || return 1
    mode="$(stat -c '%a' -- "$directory" 2>/dev/null)" || return 1
    [[ "$owner" == "$UID" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    permissions=$((8#$mode))
    (( (permissions & 8#077) == 0 ))
}

sv_instance_lock_path() {
    local instance="$1"
    local runtime_base lock_dir lock_file

    [[ "$instance" =~ ^[0-9]{1,10}$ ]] || return 1
    runtime_base="/run/user/$UID"
    if ! sv_lock_dir_is_private "$runtime_base"; then
        runtime_base="/tmp/qemu-stealth-$UID"
        if [[ ! -e "$runtime_base" ]]; then
            ( umask 077; mkdir -- "$runtime_base" ) || return 1
        fi
        sv_lock_dir_is_private "$runtime_base" || return 1
    fi

    lock_dir="$runtime_base/qemu-stealth"
    if [[ ! -e "$lock_dir" ]]; then
        ( umask 077; mkdir -- "$lock_dir" ) || return 1
    fi
    sv_lock_dir_is_private "$lock_dir" || return 1

    lock_file="$lock_dir/instance-${instance}.lock"
    if [[ -e "$lock_file" ]]; then
        [[ -f "$lock_file" && ! -L "$lock_file" \
            && "$(stat -c '%u' -- "$lock_file" 2>/dev/null)" == "$UID" ]] \
            || return 1
    fi
    printf '%s\n' "$lock_file"
}
