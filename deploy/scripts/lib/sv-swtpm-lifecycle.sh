#!/bin/bash
# ---------------------------------------------------------------------------
# swtpm 进程生命周期公共函数
#
# start-vm 与 stop-vm 都要处理独立 daemon 化的 swtpm。这里集中维护进程识别、
# 锁继承隔离和温和停止逻辑，避免两端分别使用宽泛的 pgrep 正则而误伤其它实例。
# ---------------------------------------------------------------------------

sv_swtpm_start_daemon() {
    local state_dir="$1"
    local socket_path="$2"
    local log_path="$3"

    # 中文注释：start-vm 用 FD 8 持有实例生命周期锁，而 swtpm 的 --daemon 会
    # fork 后长期运行。若子进程继承 FD 8，即便启动器和 QEMU 都退出，实例锁也
    # 不会释放，stop-vm 就无法取得清理锁。只在执行 swtpm 的子环境关闭 FD 8；
    # 当前 shell 仍继续持锁，因此启动阶段与并发 stop 之间的串行保证不受影响。
    swtpm socket \
        --tpmstate dir="$state_dir" \
        --ctrl type=unixio,path="$socket_path" \
        --tpm2 \
        --log file="$log_path",level=20 \
        --daemon 8>&-
}

sv_swtpm_pid_matches_instance() {
    local pid="$1"
    local instance="$2"
    local -a argv=()
    local exe index

    [[ "$pid" =~ ^[0-9]+$ && "$instance" =~ ^[0-9]{1,10}$ ]] || return 1
    [[ -r "/proc/$pid/cmdline" ]] || return 1
    mapfile -d '' -t argv <"/proc/$pid/cmdline" 2>/dev/null || return 1
    (( ${#argv[@]} >= 2 )) || return 1
    exe="$(readlink -- "/proc/$pid/exe" 2>/dev/null || true)"
    # 软件包升级可能把仍运行的旧 inode 显示为 `/usr/bin/swtpm (deleted)`；
    # 这仍是同一个已验证 executable，只剥内核固定后缀，后续 argv/state 路径
    # 校验保持不变，避免升级后 stop 对真实 daemon 产生 false-negative。
    exe="${exe% (deleted)}"

    # 中文注释：必须同时验证真实 executable、argv[0] 和第一个子命令。
    # 不能在 argv 任意位置搜索 `swtpm socket`，否则诊断脚本只要把这几个词
    # 当普通参数传给 Python/Java，也会被 stop 误杀。
    [[ "${exe##*/}" == "swtpm" ]] || return 1
    [[ "${argv[0]##*/}" == "swtpm" && "${argv[1]}" == "socket" ]] || return 1

    for ((index=2; index + 1 < ${#argv[@]}; index++)); do
        if [[ "${argv[index]}" == "--tpmstate" \
            && "${argv[index + 1]}" == dir=*/vms/"$instance"/tpm-state ]]; then
            return 0
        fi
    done
    return 1
}

sv_swtpm_instance_pids() {
    local instance="$1"
    local pid

    [[ "$instance" =~ ^[0-9]{1,10}$ ]] || return 1
    while read -r pid; do
        sv_swtpm_pid_matches_instance "$pid" "$instance" && printf '%s\n' "$pid"
    done < <(pgrep -f swtpm 2>/dev/null || true)
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
        # 中文注释：fuser 通过内核文件表一次取得所有打开者，比逐个扫描大型
        # /proc 快几个数量级。tr 同时兼容多个 PID 的空格分隔输出。
        fuser "$expected_path" 2>/dev/null | tr ' ' '\n' | awk 'NF'
        return 0
    fi

    # 最小系统未安装 psmisc/fuser 时保留纯 /proc 兼容路径；该路径只影响
    # 崩溃后的 stop 自愈，不进入正常 QEMU 刷新或启动热路径。
    for proc_dir in /proc/[0-9]*; do
        pid="${proc_dir#/proc/}"
        sv_swtpm_pid_holds_file "$pid" "$expected_path" && printf '%s\n' "$pid"
    done
}

sv_swtpm_orphan_lock_holder_pids() {
    local instance="$1"
    local lock_path="$2"
    local pid
    local -a swtpm_pids=() swtpm_holders=()
    local -A is_instance_swtpm=()

    mapfile -t swtpm_pids < <(sv_swtpm_instance_pids "$instance")
    (( ${#swtpm_pids[@]} > 0 )) || return 0
    for pid in "${swtpm_pids[@]}"; do
        is_instance_swtpm["$pid"]=1
    done

    # 中文注释：仅凭“swtpm 持锁”还不能判定孤儿。新启动器在启动 QEMU 前也
    # 会与刚创建的 swtpm 同时持有这把锁；若此时 stop 抢先杀 daemon，会破坏
    # 正常启动。扫描所有可见 FD，只有锁的持有者全部属于本实例 swtpm 时，才
    # 认定启动器已经消失，输出可以安全终止的孤儿 PID。
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
    shift
    local -a pids=("$@") remaining=()
    local pid attempt

    (( ${#pids[@]} > 0 )) || return 0
    # 中文注释：PID 从 pgrep 返回到 TERM 之间可能退出并被复用；首次温和停止
    # 也必须逐个重验 executable/argv，不能只在最后 SIGKILL 前防 PID 复用。
    for pid in "${pids[@]}"; do
        sv_swtpm_pid_matches_instance "$pid" "$instance" || continue
        kill "$pid" 2>/dev/null || true
    done
    for ((attempt=0; attempt<5; attempt++)); do
        remaining=()
        for pid in "${pids[@]}"; do
            if kill -0 "$pid" 2>/dev/null \
                && sv_swtpm_pid_matches_instance "$pid" "$instance"; then
                remaining+=("$pid")
            fi
        done
        (( ${#remaining[@]} == 0 )) && return 0
        sleep 0.2
    done

    # 中文注释：重新校验 PID 的命令行后才 SIGKILL，防止退出后的 PID 被快速
    # 复用时误杀不相关进程。
    for pid in "${remaining[@]}"; do
        sv_swtpm_pid_matches_instance "$pid" "$instance" || continue
        kill -9 "$pid" 2>/dev/null || true
    done
}

sv_swtpm_stop_instance() {
    local instance="$1"
    local -a pids=()

    mapfile -t pids < <(sv_swtpm_instance_pids "$instance")
    sv_swtpm_stop_pids "$instance" "${pids[@]}"
}
