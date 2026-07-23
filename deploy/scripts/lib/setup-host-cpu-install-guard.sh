#!/usr/bin/env bash
# host helper 发布期间与旧/新 CPU isolate 共用运行态锁，封闭 ABI 切换竞态。

CPU_RUNTIME_DIR="$ROOT_PREFIX/run/qemu-vmate-cpu-isolate"
CPU_RUNTIME_LOCK="$CPU_RUNTIME_DIR/global.lock"
CPU_CGROUP_ROOT="$ROOT_PREFIX/sys/fs/cgroup"
CPU_PROC_ROOT="/proc"
# 只允许临时安装根的回归测试替换 proc；真实宿主安装始终读取内核 /proc。
if [[ -n "$ROOT_PREFIX" && -n "${VMATE_TEST_PROC_ROOT:-}" ]]; then
    CPU_PROC_ROOT="$VMATE_TEST_PROC_ROOT"
fi
declare -a LEGACY_STATE_PATHS=()
declare -a LEGACY_STATE_INSTANCES=()

acquire_cpu_runtime_lock() {
    local temporary path_inode fd_inode

    if [[ ! -e "$CPU_RUNTIME_DIR" && ! -L "$CPU_RUNTIME_DIR" ]]; then
        install -d -o "$OWNER_UID" -g "$OWNER_GID" -m 0700 "$CPU_RUNTIME_DIR"
    fi
    check_secure_directory "$CPU_RUNTIME_DIR" 700 || {
        echo "ERROR: CPU helper 运行态目录 owner/mode 非法" >&2
        return 1
    }
    if [[ ! -e "$CPU_RUNTIME_LOCK" && ! -L "$CPU_RUNTIME_LOCK" ]]; then
        temporary="$(mktemp "$CPU_RUNTIME_DIR/.global-lock.XXXXXX")"
        install -o "$OWNER_UID" -g "$OWNER_GID" -m 0600 /dev/null "$temporary"
        mv -nT -- "$temporary" "$CPU_RUNTIME_LOCK"
        rm -f -- "$temporary"
    fi
    check_regular_file "$CPU_RUNTIME_LOCK" 600 || {
        echo "ERROR: CPU helper 运行态锁 owner/mode/link 非法" >&2
        return 1
    }
    exec {CPU_RUNTIME_LOCK_FD}<>"$CPU_RUNTIME_LOCK"
    path_inode="$(stat -Lc '%d:%i' -- "$CPU_RUNTIME_LOCK")"
    fd_inode="$(stat -Lc '%d:%i' -- "/proc/$$/fd/$CPU_RUNTIME_LOCK_FD")"
    [[ "$path_inode" == "$fd_inode" ]] || return 1
    flock -x "$CPU_RUNTIME_LOCK_FD"
    check_regular_file "$CPU_RUNTIME_LOCK" 600
}

scan_legacy_cpu_states() {
    local instances="$CPU_RUNTIME_DIR/instances" state name instance metadata
    local invalid=0 nullglob_was_set=0 dotglob_was_set=0
    local -a entries=()

    LEGACY_STATE_PATHS=()
    LEGACY_STATE_INSTANCES=()
    [[ -e "$CPU_RUNTIME_DIR" || -L "$CPU_RUNTIME_DIR" ]] || return 0
    check_secure_directory "$CPU_RUNTIME_DIR" 700 || {
        printf 'ERROR: 旧 ABI CPU 运行态目录不可信: %q\n' "$CPU_RUNTIME_DIR" >&2
        return 1
    }
    [[ -e "$instances" || -L "$instances" ]] || return 0
    check_secure_directory "$instances" 700 || {
        printf 'ERROR: 旧 ABI 实例运行态路径不可信: %q\n' "$instances" >&2
        return 1
    }
    shopt -q nullglob && nullglob_was_set=1
    shopt -q dotglob && dotglob_was_set=1
    shopt -s nullglob dotglob
    entries=("$instances"/*)
    (( nullglob_was_set )) || shopt -u nullglob
    (( dotglob_was_set )) || shopt -u dotglob
    for state in "${entries[@]}"; do
        name="${state##*/}"
        if [[ -L "$state" || ! -f "$state" ||
              ! "$name" =~ ^([1-9][0-9]{0,9})\.state$ ]]; then
            printf 'ERROR: 检测到非法旧 ABI 实例运行态条目 %q；拒绝升级\n' \
                "$name" >&2
            invalid=1
            continue
        fi
        instance="${BASH_REMATCH[1]}"
        metadata="$(stat -Lc '%u:%g:%a:%h' -- "$state" 2>/dev/null || true)"
        if [[ "$metadata" != "$OWNER_UID:$OWNER_GID:600:1" ]]; then
            printf 'ERROR: 旧 ABI 实例状态 owner/mode/link 不可信: %q (%q)\n' \
                "$name" "$metadata" >&2
            invalid=1
            continue
        fi
        LEGACY_STATE_PATHS+=("$state")
        LEGACY_STATE_INSTANCES+=("$instance")
    done
    (( invalid == 0 ))
}

release_stale_legacy_cpu_isolation() {
    local index instance

    scan_legacy_cpu_states || {
        echo "       非法运行态不会自动清理，请先人工检查" >&2
        return 1
    }
    (( ${#LEGACY_STATE_INSTANCES[@]} > 0 )) || {
        refuse_active_legacy_cpu_isolation
        return
    }
    if ! check_secure_directory "$LIBEXEC_DIR" 755 ||
       ! check_regular_file "$ISO_DEST" 755; then
        echo "ERROR: 当前 CPU helper 不可信，拒绝自动清理旧状态" >&2
        return 1
    fi
    echo ">> 检测到 ${#LEGACY_STATE_INSTANCES[@]} 个旧 CPU 隔离状态，正在由旧 helper 安全回收"
    for index in "${!LEGACY_STATE_INSTANCES[@]}"; do
        instance="${LEGACY_STATE_INSTANCES[$index]}"
        if ! SUDO_UID="$TARGET_UID" "$ISO_DEST" release "$instance"; then
            echo "ERROR: 旧 helper 无法安全释放实例 $instance；安装保持原版本" >&2
            printf '       手工诊断: sudo -n %q release %q\n' \
                "$ISO_DEST" "$instance" >&2
            return 1
        fi
    done
    # 旧 helper 返回成功后重新扫描 state/vmiso；它若漏删任何凭据，安装仍 fail-closed。
    refuse_active_legacy_cpu_isolation
}

refuse_active_legacy_cpu_isolation() {
    local vmiso="$CPU_CGROUP_ROOT/vmiso" pid child name index
    local nullglob_was_set=0 dotglob_was_set=0
    local -a children=()

    scan_legacy_cpu_states || return 1
    for index in "${!LEGACY_STATE_INSTANCES[@]}"; do
        name="${LEGACY_STATE_PATHS[$index]##*/}"
        printf 'ERROR: 检测到旧 ABI 实例状态 %q；拒绝在发布窗口切换 ABI\n' \
            "$name" >&2
        printf '       清理命令: sudo -n %q release %q\n' \
            "$ISO_DEST" "${LEGACY_STATE_INSTANCES[$index]}" >&2
    done
    (( ${#LEGACY_STATE_INSTANCES[@]} == 0 )) || return 1
    [[ ! -e "$vmiso" && ! -L "$vmiso" ]] && return 0
    [[ -d "$vmiso" && ! -L "$vmiso" && -r "$vmiso/cgroup.procs" ]] || {
        echo "ERROR: vmiso 不是可验证的 cgroup 目录" >&2
        return 1
    }
    while IFS= read -r pid; do
        [[ -z "$pid" ]] && continue
        echo "ERROR: vmiso 仍有旧 ABI 活动进程 pid=$pid；请先安全关闭全部旧 VM 再安装 ABI5" >&2
        return 1
    done < "$vmiso/cgroup.procs"
    shopt -q nullglob && nullglob_was_set=1
    shopt -q dotglob && dotglob_was_set=1
    shopt -s nullglob dotglob
    children=("$vmiso"/*)
    (( nullglob_was_set )) || shopt -u nullglob
    (( dotglob_was_set )) || shopt -u dotglob
    for child in "${children[@]}"; do
        name="${child##*/}"
        if [[ -L "$child" ]]; then
            echo "ERROR: vmiso 含 symlink: $name" >&2
            return 1
        elif [[ -d "$child" && "$name" =~ ^vm-[1-9][0-9]{0,9}$ ]]; then
            echo "ERROR: 检测到旧 ABI 实例 $name；请先用旧 helper release 再安装 ABI5" >&2
            return 1
        elif [[ -d "$child" || "$name" == vm-* ]]; then
            echo "ERROR: vmiso 含未知 child: $name" >&2
            return 1
        else
            continue
        fi
    done
    echo "ERROR: 检测到未拆除的旧 ABI vmiso；请先用旧 helper 完成实例 release" >&2
    return 1
}

refuse_inflight_cpu_helpers() {
    local proc pid key effective_uid argument descriptor
    local -a arguments=()

    for proc in "$CPU_PROC_ROOT"/[0-9]*; do
        [[ -d "$proc" ]] || continue
        pid="${proc##*/}"
        [[ "$pid" == "$$" ]] && continue
        # /proc status 的 Uid 顺序是 real/effective/saved/fs；sudo 等待 exec 时
        # real 仍是调用用户，而 effective 已是 root，必须匹配第三列。
        effective_uid=""
        while read -r key _ effective_uid _; do
            [[ "$key" == "Uid:" ]] && break
            effective_uid=""
        done < "$proc/status" 2>/dev/null || true
        [[ "$effective_uid" == "$OWNER_UID" ]] || continue
        mapfile -d '' -t arguments < "$proc/cmdline" 2>/dev/null || continue
        for argument in "${arguments[@]}"; do
            case "$argument" in
            "$ISO_DEST"|host-cpu-isolate.sh|*/host-cpu-isolate.sh)
                echo "ERROR: 检测到发布前已启动的 CPU helper pid=$pid；本次安装安全回滚后请重试" >&2
                return 1
                ;;
            esac
        done
        # argv 已变化的 helper 仍会打开同一个运行锁；Bash -ef 直接比较 inode，
        # 不为数百个进程/FD fork stat，E5 多 VM 宿主安装时也保持常数级开销。
        for descriptor in "$proc"/fd/*; do
            [[ -e "$descriptor" || -L "$descriptor" ]] || continue
            if [[ "$descriptor" -ef "/proc/$$/fd/$CPU_RUNTIME_LOCK_FD" ]]; then
                echo "ERROR: 检测到等待 CPU 运行锁的旧 helper pid=$pid；本次安装安全回滚后请重试" >&2
                return 1
            fi
        done
    done
}
