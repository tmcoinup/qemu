#!/bin/bash
# ---------------------------------------------------------------------------
# swtpm 进程生命周期公共函数
#
# swtpm 是脱离启动器运行的 daemon，不能只凭实例号或宽泛的进程正则识别。
# 启动端会把规范化后的 TPM state 目录原子登记到当前用户的私有 runtime 目录；
# stop/reaper 读取同一份登记并同时核对 executable、argv 与目录所有权，因而既支持
# 任意 VM_DIR，也不会误杀命令行里碰巧出现 “swtpm” 字样的其它进程。
# ---------------------------------------------------------------------------

sv_swtpm_path_is_plain() {
    local path="$1"

    # 换行会破坏单行 runtime 状态格式，回车和 NUL 也不应进入 Unix 路径契约。
    # Bash 变量本身不能保存 NUL，因此这里只需显式拒绝 CR/LF 和空路径。
    [[ -n "$path" && "$path" != *$'\n'* && "$path" != *$'\r'* ]]
}

sv_swtpm_private_directory() {
    local directory="$1"
    local owner mode permissions

    [[ -d "$directory" && ! -L "$directory" ]] || return 1
    owner="$(stat -c '%u' -- "$directory" 2>/dev/null)" || return 1
    mode="$(stat -c '%a' -- "$directory" 2>/dev/null)" || return 1
    [[ "$owner" == "$UID" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    permissions=$((8#$mode))
    (( (permissions & 8#077) == 0 ))
}

sv_swtpm_canonical_state_dir() {
    local requested="$1"
    local canonical parent

    sv_swtpm_path_is_plain "$requested" || return 1
    [[ "${requested##*/}" == "tpm-state" ]] || return 1
    [[ -d "$requested" && ! -L "$requested" ]] || return 1
    canonical="$(realpath -e -- "$requested" 2>/dev/null)" || return 1
    parent="${canonical%/*}"

    # state 与 VM 根目录都必须是当前用户的私有真实目录。父级挂载点可以位于
    # 任意磁盘；realpath 已消除父路径中的符号链接和 `..`，后续统一使用该值。
    sv_swtpm_private_directory "$parent" || return 1
    sv_swtpm_private_directory "$canonical" || return 1
    printf '%s\n' "$canonical"
}

sv_swtpm_prepare_state_dir() {
    local requested="$1"
    local requested_parent canonical_parent canonical

    sv_swtpm_path_is_plain "$requested" || return 1
    [[ "${requested##*/}" == "tpm-state" ]] || return 1
    requested_parent="${requested%/*}"
    [[ -n "$requested_parent" && ! -L "$requested_parent" ]] || return 1
    canonical_parent="$(realpath -e -- "$requested_parent" 2>/dev/null)" || return 1
    sv_swtpm_private_directory "$canonical_parent" || return 1
    canonical="$canonical_parent/tpm-state"

    # 不跟随既有符号链接。旧版本创建的、仍归当前用户所有的目录只收紧权限，
    # 这样升级后仍可使用原 TPM NVRAM，同时满足私钥与证书不得旁路 VM_DIR 的约束。
    [[ ! -L "$canonical" ]] || return 1
    if [[ ! -e "$canonical" ]]; then
        ( umask 077; mkdir -- "$canonical" ) || return 1
    fi
    [[ -d "$canonical" \
        && "$(stat -c '%u' -- "$canonical" 2>/dev/null)" == "$UID" ]] || return 1
    chmod 0700 -- "$canonical" || return 1
    sv_swtpm_canonical_state_dir "$canonical"
}

sv_swtpm_runtime_state_file() {
    local instance="$1"
    local lock_path

    [[ "$instance" =~ ^[0-9]{1,10}$ ]] || return 1
    # sv_instance_lock_path 同时完成 runtime 目录的 owner/type/mode 校验。
    # 生命周期库由 start/stop 在 sv-instance-lock.sh 之后加载。
    declare -F sv_instance_lock_path >/dev/null 2>&1 || return 1
    lock_path="$(sv_instance_lock_path "$instance")" || return 1
    printf '%s\n' "${lock_path%.lock}.swtpm-state"
}

sv_swtpm_runtime_file_is_safe() {
    local state_file="$1"
    local owner mode permissions links

    [[ -f "$state_file" && ! -L "$state_file" ]] || return 1
    owner="$(stat -c '%u' -- "$state_file" 2>/dev/null)" || return 1
    mode="$(stat -c '%a' -- "$state_file" 2>/dev/null)" || return 1
    links="$(stat -c '%h' -- "$state_file" 2>/dev/null)" || return 1
    [[ "$owner" == "$UID" && "$mode" =~ ^[0-7]{3,4}$ && "$links" == "1" ]] \
        || return 1
    permissions=$((8#$mode))
    (( (permissions & 8#077) == 0 ))
}

sv_swtpm_register_state_dir() {
    local instance="$1"
    local requested="$2"
    local canonical state_file temporary

    canonical="$(sv_swtpm_canonical_state_dir "$requested")" || return 1
    state_file="$(sv_swtpm_runtime_state_file "$instance")" || return 1
    if [[ -e "$state_file" || -L "$state_file" ]]; then
        sv_swtpm_runtime_file_is_safe "$state_file" || return 1
    fi
    temporary="$(mktemp -- "${state_file}.tmp.XXXXXX")" || return 1
    if ! chmod 0600 -- "$temporary" \
        || ! printf '%s\n' "$canonical" >"$temporary" \
        || ! mv -fT -- "$temporary" "$state_file"; then
        rm -f -- "$temporary"
        return 1
    fi
}

sv_swtpm_read_registered_state_dir() {
    local instance="$1"
    local state_file canonical
    local -a lines=()

    state_file="$(sv_swtpm_runtime_state_file "$instance")" || return 2
    [[ -e "$state_file" || -L "$state_file" ]] || return 1
    sv_swtpm_runtime_file_is_safe "$state_file" || return 2
    mapfile -t lines <"$state_file" || return 2
    (( ${#lines[@]} == 1 )) || return 2
    canonical="$(sv_swtpm_canonical_state_dir "${lines[0]}")" || return 2
    # runtime 文件只接受已经规范化的路径，拒绝通过 `..` 或软链表达的别名。
    [[ "$canonical" == "${lines[0]}" ]] || return 2
    printf '%s\n' "$canonical"
}

sv_swtpm_unregister_state_dir() {
    local instance="$1"
    local expected="${2:-}"
    local state_file registered canonical_expected

    state_file="$(sv_swtpm_runtime_state_file "$instance")" || return 1
    [[ -e "$state_file" || -L "$state_file" ]] || return 0
    registered="$(sv_swtpm_read_registered_state_dir "$instance")" || return 1
    if [[ -n "$expected" ]]; then
        canonical_expected="$(sv_swtpm_canonical_state_dir "$expected")" || return 1
        [[ "$registered" == "$canonical_expected" ]] || return 1
    fi
    rm -- "$state_file"
}

sv_swtpm_default_state_dir() {
    local instance="$1"
    local image_root vms_dir

    [[ "$instance" =~ ^[0-9]{1,10}$ ]] || return 1
    image_root="${IMAGE_ROOT:-/home/ubuntu/images}"
    vms_dir="${VMS_DIR:-${image_root%/}/vms}"
    realpath -m -- "${vms_dir%/}/$instance/tpm-state"
}

sv_swtpm_resolve_instance_state_dir() {
    local instance="$1"
    local explicit_vm_dir="${2:-}"
    local state_file requested parent canonical_parent

    state_file="$(sv_swtpm_runtime_state_file "$instance")" || return 2
    if [[ -e "$state_file" || -L "$state_file" ]]; then
        sv_swtpm_read_registered_state_dir "$instance"
        return
    fi

    # 没有 runtime 登记代表旧版本实例或从未启动过的实例。显式 VM_DIR 优先，
    # 否则回退历史默认路径；这条兼容路径仍会在目录存在时执行完整安全校验。
    if [[ -n "$explicit_vm_dir" ]]; then
        sv_swtpm_path_is_plain "$explicit_vm_dir" || return 2
        [[ ! -L "$explicit_vm_dir" ]] || return 2
        parent="$(realpath -e -- "$explicit_vm_dir" 2>/dev/null)" || return 2
        sv_swtpm_private_directory "$parent" || return 2
        requested="$parent/tpm-state"
    else
        requested="$(sv_swtpm_default_state_dir "$instance")" || return 2
    fi
    if [[ -e "$requested" || -L "$requested" ]]; then
        sv_swtpm_canonical_state_dir "$requested"
        return
    fi

    # 未创建 TPM 的实例也允许 stop 幂等成功。只返回规范化候选路径，不创建目录。
    parent="${requested%/*}"
    canonical_parent="$(realpath -m -- "$parent" 2>/dev/null)" || return 2
    printf '%s\n' "$canonical_parent/tpm-state"
}

sv_swtpm_peer_path() {
    local requested="$1"
    local state_dir="$2"
    local expected_name="$3"
    local canonical_state canonical_parent normalized

    sv_swtpm_path_is_plain "$requested" || return 1
    [[ "${requested##*/}" == "$expected_name" ]] || return 1
    canonical_state="$(sv_swtpm_canonical_state_dir "$state_dir")" || return 1
    canonical_parent="${canonical_state%/*}"
    normalized="$(realpath -m -- "$requested" 2>/dev/null)" || return 1
    [[ "${normalized%/*}" == "$canonical_parent" ]] || return 1
    if [[ -e "$normalized" || -L "$normalized" ]]; then
        [[ ! -L "$normalized" \
            && "$(stat -c '%u' -- "$normalized" 2>/dev/null)" == "$UID" ]] || return 1
    fi
    printf '%s\n' "$normalized"
}

sv_swtpm_start_daemon() {
    local instance="$1"
    local state_dir="$2"
    local socket_path="$3"
    local log_path="$4"
    local canonical_state canonical_socket canonical_log

    canonical_state="$(sv_swtpm_canonical_state_dir "$state_dir")" || return 1
    canonical_socket="$(sv_swtpm_peer_path "$socket_path" "$canonical_state" tpm-sock)" \
        || return 1
    canonical_log="$(sv_swtpm_peer_path "$log_path" "$canonical_state" tpm.log)" \
        || return 1
    sv_swtpm_register_state_dir "$instance" "$canonical_state" || return 1

    # start-vm 用 FD 8 持有实例生命周期锁，而 swtpm 的 --daemon 会 fork 后长期
    # 运行。仅在 swtpm 子环境关闭 FD 8；当前 shell 继续持锁，启动与 stop 仍串行。
    if ! swtpm socket \
        --tpmstate dir="$canonical_state" \
        --ctrl type=unixio,path="$canonical_socket" \
        --tpm2 \
        --log file="$canonical_log",level=20 \
        --daemon 8>&-; then
        sv_swtpm_unregister_state_dir "$instance" "$canonical_state" || true
        return 1
    fi
}

sv_swtpm_pid_matches_instance() {
    local pid="$1"
    local instance="$2"
    local expected_state="${3:-}"
    local canonical_expected exe index value actual_state match_count=0
    local -a argv=()

    [[ "$pid" =~ ^[0-9]+$ && "$instance" =~ ^[0-9]{1,10}$ ]] || return 1
    if [[ -z "$expected_state" ]]; then
        expected_state="$(sv_swtpm_resolve_instance_state_dir "$instance")" || return 1
    fi
    canonical_expected="$(sv_swtpm_canonical_state_dir "$expected_state")" || return 1
    [[ -r "/proc/$pid/cmdline" ]] || return 1
    mapfile -d '' -t argv <"/proc/$pid/cmdline" 2>/dev/null || return 1
    (( ${#argv[@]} >= 2 )) || return 1
    exe="$(readlink -- "/proc/$pid/exe" 2>/dev/null || true)"
    # 软件包升级后的运行中 inode 可能带 “(deleted)” 固定后缀。
    exe="${exe% (deleted)}"
    [[ "${exe##*/}" == "swtpm" ]] || return 1
    [[ "${argv[0]##*/}" == "swtpm" && "${argv[1]}" == "socket" ]] || return 1

    for ((index=2; index + 1 < ${#argv[@]}; index++)); do
        [[ "${argv[index]}" == "--tpmstate" ]] || continue
        value="${argv[index + 1]}"
        [[ "$value" == dir=* ]] || return 1
        actual_state="$(sv_swtpm_canonical_state_dir "${value#dir=}")" || return 1
        [[ "$actual_state" == "$canonical_expected" ]] || return 1
        ((match_count+=1))
    done
    (( match_count == 1 ))
}

sv_swtpm_instance_pids() {
    local instance="$1"
    local state_dir="$2"
    local pid

    [[ "$instance" =~ ^[0-9]{1,10}$ ]] || return 1
    while read -r pid; do
        sv_swtpm_pid_matches_instance "$pid" "$instance" "$state_dir" \
            && printf '%s\n' "$pid"
    done < <(pgrep -x swtpm 2>/dev/null || true)
}

sv_swtpm_pid_holds_file() {
    local pid="$1"
    local expected_path="$2"
    local fd target

    [[ "$pid" =~ ^[0-9]+$ && -n "$expected_path" ]] || return 1
    for fd in "/proc/$pid/fd/"*; do
        [[ -L "$fd" ]] || continue
        target="$(readlink -- "$fd" 2>/dev/null || true)"
        [[ "$target" == "$expected_path" ]] && return 0
    done
    return 1
}

sv_swtpm_file_user_pids() {
    local expected_path="$1"
    local pid proc_dir

    [[ -n "$expected_path" ]] || return 1
    if command -v fuser >/dev/null 2>&1; then
        fuser "$expected_path" 2>/dev/null | tr ' ' '\n' | awk 'NF'
        return 0
    fi
    for proc_dir in /proc/[0-9]*; do
        pid="${proc_dir#/proc/}"
        sv_swtpm_pid_holds_file "$pid" "$expected_path" && printf '%s\n' "$pid"
    done
}

sv_swtpm_orphan_lock_holder_pids() {
    local instance="$1"
    local state_dir="$2"
    local lock_path="$3"
    local pid
    local -a swtpm_pids=() swtpm_holders=()
    local -A is_instance_swtpm=()

    mapfile -t swtpm_pids < <(sv_swtpm_instance_pids "$instance" "$state_dir")
    (( ${#swtpm_pids[@]} > 0 )) || return 0
    for pid in "${swtpm_pids[@]}"; do
        is_instance_swtpm["$pid"]=1
    done

    # 只有锁的全部持有者都是目标 state 的 swtpm，才认定启动器已经消失。
    # 若新启动器或 watchdog 也持锁，保持保守并让调用方下一轮重新判定。
    while read -r pid; do
        if [[ -z "${is_instance_swtpm[$pid]+present}" ]]; then
            return 0
        fi
        swtpm_holders+=("$pid")
    done < <(sv_swtpm_file_user_pids "$lock_path")

    (( ${#swtpm_holders[@]} > 0 )) || return 0
    printf '%s\n' "${swtpm_holders[@]}"
}

sv_swtpm_stop_pids() {
    local instance="$1"
    local state_dir="$2"
    shift 2
    local -a pids=("$@") remaining=()
    local pid attempt

    (( ${#pids[@]} > 0 )) || return 0
    # PID 从发现到 TERM/SIGKILL 之间都可能被复用，每次发信号前重新核对完整身份。
    for pid in "${pids[@]}"; do
        sv_swtpm_pid_matches_instance "$pid" "$instance" "$state_dir" || continue
        kill "$pid" 2>/dev/null || true
    done
    for ((attempt=0; attempt<5; attempt++)); do
        remaining=()
        for pid in "${pids[@]}"; do
            if kill -0 "$pid" 2>/dev/null \
                && sv_swtpm_pid_matches_instance "$pid" "$instance" "$state_dir"; then
                remaining+=("$pid")
            fi
        done
        (( ${#remaining[@]} == 0 )) && return 0
        sleep 0.2
    done
    for pid in "${remaining[@]}"; do
        sv_swtpm_pid_matches_instance "$pid" "$instance" "$state_dir" || continue
        kill -9 "$pid" 2>/dev/null || true
    done
}

sv_swtpm_stop_instance() {
    local instance="$1"
    local state_dir="$2"
    local -a pids=()

    mapfile -t pids < <(sv_swtpm_instance_pids "$instance" "$state_dir")
    sv_swtpm_stop_pids "$instance" "$state_dir" "${pids[@]}"
    pids=()
    mapfile -t pids < <(sv_swtpm_instance_pids "$instance" "$state_dir")
    # 仍有精确匹配的 daemon 时保留 runtime 登记，供 stop-vm 或下次启动重试；
    # 只有确认全部退出后才删除登记，不能把仍活着的 TPM 变成不可追踪孤儿。
    (( ${#pids[@]} == 0 )) || return 1
    sv_swtpm_unregister_state_dir "$instance" "$state_dir"
}
