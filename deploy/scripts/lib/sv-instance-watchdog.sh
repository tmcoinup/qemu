#!/usr/bin/env bash
# ---------------------------------------------------------------------------
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
# pinner 在调用点显式关闭 FD8，不能意外延长生命周期。VLAN 模式
# 仍由 guard 在释放自己那一份锁前清 TAP。
sv_instance_watchdog_launch() {
    local parent_pid parent_start tap prepared lock_path

    [[ "${SV_INSTANCE_LOCKED:-0}" == "1" ]] || return 0
    # BASHPID 在测试/调用者 subshell 中仍指向当前真实进程；顶层启动器中与 $$
    # 相同。无 xset 改动时该 PID 最终 exec inhibit/QEMU；需要恢复 DPMS 时它
    # 保留为轻量显示守护父 shell。两种路径都持续到 QEMU 生命周期结束。
    parent_pid="$BASHPID"
    parent_start="$(awk '{ print $22 }' "/proc/$parent_pid/stat" 2>/dev/null)"
    tap="${VLAN_TAP_IF:-}"
    prepared="${SV_VLAN_PREPARED:-0}"
    lock_path="${SV_INSTANCE_LOCK:-}"
    [[ -n "$parent_start" ]] || {
        echo "ERROR: 无法读取 VLAN watchdog 的父进程 starttime。" >&2
        return 1
    }

    (
        local watchdog_pid

        watchdog_pid="$BASHPID"
        # watchdog 与前台 QEMU 处于同一进程组；忽略终端广播的 HUP/INT/TERM，
        # 否则 Ctrl+C 会同时杀掉清理者，只剩可能因 TAP fd 尚未关闭而失败的 downscript。
        trap '' HUP INT TERM
        while [[ -r "/proc/$parent_pid/stat" ]]; do
            [[ "$(awk '{ print $22 }' "/proc/$parent_pid/stat" 2>/dev/null)" == "$parent_start" ]] || break
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
