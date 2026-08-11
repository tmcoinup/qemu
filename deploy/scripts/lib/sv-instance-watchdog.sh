#!/usr/bin/env bash
# ---------------------------------------------------------------------------

sv_proc_state_starttime_pgid_sid() {
    local pid="$1" stat_line rest
    local -a fields=()
    [[ -r "/proc/$pid/stat" ]] || return 1
    { stat_line="$(<"/proc/$pid/stat")"; } 2>/dev/null || return 1
    rest="${stat_line##*) }"
    read -ra fields <<< "$rest"
    (( ${#fields[@]} >= 20 )) || return 1
    [[ "${fields[0]}" =~ ^[A-Za-z]$ && "${fields[19]}" =~ ^[0-9]+$ ]] || return 1
    [[ "${fields[2]}" =~ ^[0-9]+$ && "${fields[3]}" =~ ^[0-9]+$ ]] || return 1
    printf '%s %s %s %s\n' \
        "${fields[0]}" "${fields[19]}" "${fields[2]}" "${fields[3]}"
}

sv_proc_state_starttime_pgid() {
    local state start pgid _sid
    read -r state start pgid _sid \
        < <(sv_proc_state_starttime_pgid_sid "$1") || return 1
    printf '%s %s %s\n' "$state" "$start" "$pgid"
}

sv_proc_state_starttime() {
    local state start _pgid
    read -r state start _pgid < <(sv_proc_state_starttime_pgid "$1") || return 1
    printf '%s %s\n' "$state" "$start"
}

sv_proc_pgid() {
    local _state _start pgid
    read -r _state _start pgid < <(sv_proc_state_starttime_pgid "$1") || return 1
    printf '%s\n' "$pgid"
}

sv_proc_sid() {
    local _state _start _pgid sid
    read -r _state _start _pgid sid \
        < <(sv_proc_state_starttime_pgid_sid "$1") || return 1
    printf '%s\n' "$sid"
}

sv_proc_generation_is_live() {
    local pid="$1" expected_start="$2" state current_start
    read -r state current_start < <(sv_proc_state_starttime "$pid") || return 1
    [[ "$current_start" == "$expected_start" \
       && "$state" != "Z" && "$state" != "z" \
       && "$state" != "X" && "$state" != "x" ]]
}
# sv-instance-watchdog.sh — 实例锁与 VLAN TAP 的异步生命周期监督
#
# 本模块由 start-vm.sh 在 sv-vlan-preflight.sh 后 source，因此可以调用受信任
# VLAN helper。它独立于 CLI/设备组装，专门保证显示父 shell、setsid/inhibit、
# QEMU 与 TAP 的退出顺序，避免不可捕获信号留下并发启动或提前断网窗口。
# ---------------------------------------------------------------------------

sv_instance_lock_has_other_users() {
    local lock_path="$1"
    local self_pid="$2"
    local pid users=""

    [[ -n "$lock_path" && "$self_pid" =~ ^[0-9]+$ ]] || return 1
    if command -v fuser >/dev/null 2>&1; then
        # 命令替换进程会先关闭自己的 FD8，再查询文件打开者；否则查询者本身
        # 继承锁 FD，会被 fuser 错算成“仍有其它生命周期进程”。watchdog 本体
        # 继续持 FD8，并通过 self_pid 从结果中排除。
        users="$(
            exec 8>&-
            fuser "$lock_path" 2>/dev/null || true
        )"
        for pid in $users; do
            [[ "$pid" == "$self_pid" ]] || return 0
        done
        return 1
    fi

    # psmisc/fuser 缺失时使用 Bash 的 -ef inode 比较，整个扫描不 fork 外部
    # 命令，因此不会制造新的 FD8 继承者。权限不可见的进程只会被跳过；实例锁
    # 位于当前用户私有 runtime 目录，合法持有者本来就应属于同一用户。
    for proc_dir in /proc/[0-9]*; do
        pid="${proc_dir#/proc/}"
        [[ "$pid" == "$self_pid" ]] && continue
        for fd in "$proc_dir"/fd/*; do
            [[ -e "$fd" && "$fd" -ef "$lock_path" ]] && return 0
        done
    done
    return 1
}

# 生命周期 guard 跟踪当前 shell 的 PID 与 starttime，并继承实例锁 FD8。
# parent 保留同一 FD，使最终 setsid/inhibit 监督链至少有一个进程继承：即使
# 轻量父 shell 遭 SIGKILL/OOM，仍在等待 QEMU 的监督进程会继续阻止同实例
# 并发启动（systemd-inhibit 可能主动关闭传给 QEMU 本体的未知 FD）。
# pinner 也继承 FD8，并在 QEMU 退出后先归还 CPU 分区再退出；VLAN guard 会等到
# pinner 完成，随后清 TAP 并释放自己的最后一份锁，收尾次序不会留下新代插入窗口。
sv_instance_watchdog_launch() {
    local parent_pid parent_start _parent_state tap prepared lock_path
    local cpu_isolate strict_hardware cpu_helper instance

    [[ "${SV_INSTANCE_LOCKED:-0}" == "1" ]] || return 0
    # BASHPID 在测试/调用者 subshell 中仍指向当前真实进程；顶层启动器中与 $$
    # 相同。无 xset 改动时该 PID 最终 exec inhibit/QEMU；需要恢复 DPMS 时它
    # 保留为轻量显示守护父 shell。两种路径都持续到 QEMU 生命周期结束。
    parent_pid="$BASHPID"
    read -r _parent_state parent_start < <(sv_proc_state_starttime "$parent_pid") || return 1
    tap="${VLAN_TAP_IF:-}"
    prepared="${SV_VLAN_PREPARED:-0}"
    lock_path="${SV_INSTANCE_LOCK:-}"
    cpu_isolate="${CPU_ISOLATE:-1}"
    strict_hardware="${STRICT_HARDWARE:-1}"
    cpu_helper="${SV_CPU_ISO_HELPER:-/usr/local/libexec/qemu-vmate-cpu-isolate}"
    instance="${INSTANCE:-}"
    [[ -n "$parent_start" ]] || {
        echo "ERROR: 无法读取 VLAN watchdog 的父进程 starttime。" >&2
        return 1
    }

    (
        local watchdog_pid release_attempt=0

        watchdog_pid="$BASHPID"
        # watchdog 与前台 QEMU 处于同一进程组；忽略终端广播的 HUP/INT/TERM，
        # 否则 Ctrl+C 会同时杀掉清理者，只剩可能因 TAP fd 尚未关闭而失败的 downscript。
        trap '' HUP INT QUIT TERM
        while sv_proc_generation_is_live "$parent_pid" "$parent_start"; do
            sleep 1
        done
        # display guard 为可靠恢复 xset 会保留父 shell，并把 QEMU 放入独立
        # setsid/inhibit 监督链。若父 shell 遭 SIGKILL，不能立刻清 VLAN TAP；
        # 监督链仍通过同一个 FD8/open-file-description 持锁。watchdog 自己持续
        # 持锁并等待到只剩自身，随后先清 TAP 再退出释放锁，整个过程没有让新
        # 启动器插入的无锁窗口。
        while [[ -n "$lock_path" ]] && \
              sv_instance_lock_has_other_users "$lock_path" "$watchdog_pid"; do
            sleep 0.2
        done
        # pinner 正常路径会先 release 再关闭 FD8；若 pinner 自身遭 SIGKILL/OOM，
        # watchdog 是实例锁的最后持有者，必须在放锁前幂等归还 exact child。
        # 严格模式持续重试，宁可阻止同实例新启动，也不遗留错误的 CPU 分区。
        if [[ "$cpu_isolate" == "1" && "$strict_hardware" == "1" \
           && "$instance" =~ ^[0-9]{1,10}$ ]]; then
            until sudo -n "$cpu_helper" release "$instance" >/dev/null 2>&1; do
                release_attempt=$((release_attempt + 1))
                if (( release_attempt == 1 || release_attempt % 60 == 0 )); then
                    logger -t qemu-stealth-cpu \
                        "watchdog 等待归还实例 $instance 的 CPU 分区" 2>/dev/null || true
                fi
                sleep 1
            done
        fi
        if [[ "$prepared" == "1" ]] \
            && ! sv_vlan_helper_call cleanup-ifname "$tap" >/dev/null 2>&1; then
            logger -t qemu-stealth-vlan \
                "watchdog 清理 $tap 失败，请运行 stop-vm.sh" 2>/dev/null || true
        fi
    ) </dev/null >/dev/null 2>&1 &
    SV_VLAN_WATCHDOG_PID=$!
    # 逻辑所有权已交给 guard；物理 FD 仍保留到最终 display supervisor/QEMU
    # 启动，使父 shell 被不可捕获信号终止时，客机进程链仍持有同一把锁。
    SV_INSTANCE_LOCKED=0
    if [[ "$prepared" == "1" ]]; then
        echo ">> VLAN cleanup: async watchdog pid=$SV_VLAN_WATCHDOG_PID"
    fi
}
