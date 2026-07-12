#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# sv-display-guard.sh — SDL 窗口运行期的宿主显示状态守护
#
# 该文件由 start-vm.sh source，使用调用方已经生成的 CMD、INSTANCE、SDL 等变量。
# QEMU 需要保持前台运行，但不能直接 exec：bash 的 EXIT trap 不会跨 exec 保留，
# 直接替换进程会让临时关闭的 X11 DPMS/屏保永远得不到恢复。因此只有确实修改过
# xset 状态时才保留一个很轻的父 shell，异步等待 inhibit/QEMU 并负责最终还原。
# ---------------------------------------------------------------------------

SV_DISPLAY_XSET_CHANGED=0
SV_DISPLAY_CHILD_PID=""
SV_DISPLAY_SIGNAL_STATUS=0

sv_display_restore_xset() {
    [[ "${SV_DISPLAY_XSET_CHANGED:-0}" == "1" ]] || return 0

    # 原来就是 Disabled 时不必重复关闭；原来 Enabled 才重新打开。屏保 timeout
    # 为 0 表示原本已禁用，也应保持禁用。所有恢复命令均为 best effort，避免
    # X server 已退出时掩盖 QEMU 的真实退出码。
    if [[ "${SV_DISPLAY_DPMS_ORIG:-}" == "Enabled" ]]; then
        xset +dpms >/dev/null 2>&1 || true
    fi
    if [[ -n "${SV_DISPLAY_SS_ORIG:-}" && -n "${SV_DISPLAY_SS_CYCLE_ORIG:-}" ]]; then
        xset s "$SV_DISPLAY_SS_ORIG" "${SV_DISPLAY_SS_CYCLE_ORIG:-$SV_DISPLAY_SS_ORIG}" \
            >/dev/null 2>&1 || true
    fi
    SV_DISPLAY_XSET_CHANGED=0
}

sv_display_forward_signal() {
    local signal="$1"
    local status="$2"

    SV_DISPLAY_SIGNAL_STATUS="$status"
    # setsid 路径把 inhibit 与 QEMU 放进独立进程组；同时发送给整个组和直接
    # 子进程，可覆盖“信号恰好早于 setsid 建组”的极短竞态。没有 setsid 时
    # 退化为直接子进程转发，stop-vm 仍会按 QEMU PID 精确终止客机。
    if [[ -n "${SV_DISPLAY_CHILD_PID:-}" ]]; then
        if [[ "${SV_DISPLAY_CHILD_GROUP:-0}" == "1" ]]; then
            kill "-$signal" -- "-$SV_DISPLAY_CHILD_PID" 2>/dev/null || true
        fi
        kill "-$signal" "$SV_DISPLAY_CHILD_PID" 2>/dev/null || true
    fi
}

sv_display_wait_and_restore() {
    local child_status=0

    # EXIT 是最后一道保险；终端断开、Ctrl+C/Ctrl+\ 和 stop 的 TERM 都先转发
    # 给 inhibit/QEMU 进程组，再由 wait 路径统一恢复 xset。wait 可能被 trap
    # 中断而子进程尚未退出，因此需要继续等待到 kill -0 确认进程消失，不能
    # 过早恢复后留下仍在运行的 VM。
    trap sv_display_restore_xset EXIT
    trap 'sv_display_forward_signal HUP 129' HUP
    trap 'sv_display_forward_signal INT 130' INT
    trap 'sv_display_forward_signal QUIT 131' QUIT
    trap 'sv_display_forward_signal TERM 143' TERM

    if command -v setsid >/dev/null 2>&1; then
        # util-linux setsid --wait 会把被包装命令的退出码原样交回，并让 TERM/INT
        # 能一次送达 gnome-session-inhibit、systemd-inhibit 及 QEMU 全部后代。
        setsid --wait -- "$@" &
        SV_DISPLAY_CHILD_PID=$!
        SV_DISPLAY_CHILD_GROUP=1
    else
        "$@" &
        SV_DISPLAY_CHILD_PID=$!
        SV_DISPLAY_CHILD_GROUP=0
    fi
    while true; do
        if wait "$SV_DISPLAY_CHILD_PID"; then
            child_status=0
            break
        else
            child_status=$?
        fi
        kill -0 "$SV_DISPLAY_CHILD_PID" 2>/dev/null || break
    done

    SV_DISPLAY_CHILD_PID=""
    SV_DISPLAY_CHILD_GROUP=0
    sv_display_restore_xset
    trap - EXIT HUP INT QUIT TERM
    if (( SV_DISPLAY_SIGNAL_STATUS != 0 )); then
        return "$SV_DISPLAY_SIGNAL_STATUS"
    fi
    return "$child_status"
}

sv_display_guard_launch() {
    local -a command=("$@")
    local -a gnome_inhibit=()
    local -a launch_command=()
    local xset_state=""

    SV_DISPLAY_SIGNAL_STATUS=0

    # 无本地 SDL 窗口时不触碰桌面状态，维持原来的零开销 exec 路径。
    if [[ "${SDL:-0}" != "1" || "${HEADLESS:-0}" == "1" || -z "${DISPLAY:-}" ]]; then
        exec "${command[@]}"
    fi

    # 每个实例使用独立 WM_CLASS/desktop 图标；桌面集成失败不能阻断 VM。
    sv_dock_integrate || true

    if command -v xset >/dev/null 2>&1; then
        xset_state="$(xset q 2>/dev/null || true)"
        SV_DISPLAY_DPMS_ORIG="$(awk '/DPMS is/{print $NF}' <<<"$xset_state")"
        SV_DISPLAY_SS_ORIG="$(awk '/Screen Saver/{f=1;next} f&&/timeout:/{print $2;exit}' <<<"$xset_state")"
        SV_DISPLAY_SS_CYCLE_ORIG="$(awk '/Screen Saver/{f=1;next} f&&/timeout:/{print $4;exit}' <<<"$xset_state")"
        # 查询结果不完整时不冒险修改；否则一旦 X server 随后断开，就没有足够
        # 信息恢复用户原来的状态。只接受 xset q 的标准枚举/数值格式。
        if [[ "$SV_DISPLAY_DPMS_ORIG" =~ ^(Enabled|Disabled)$ ]] &&
           [[ "$SV_DISPLAY_SS_ORIG" =~ ^[0-9]+$ ]] &&
           [[ "$SV_DISPLAY_SS_CYCLE_ORIG" =~ ^[0-9]+$ ]]; then
            SV_DISPLAY_XSET_CHANGED=1
            if xset s off -dpms >/dev/null 2>&1; then
                # 从宿主状态发生变化的这一刻起就安装保险 trap；后面的桌面
                # inhibit 参数组装尚未启动子进程，但也不能留下信号恢复窗口。
                trap sv_display_restore_xset EXIT
                echo ">> host DPMS / 屏保: 已临时关闭（VM 退出后还原）"
            else
                # 组合命令可能在修改其中一项后才失败，立即按快照回滚，不能把
                # “未标记 changed”当成“宿主状态一定没变”。
                sv_display_restore_xset
            fi
        fi
    fi

    # GNOME mutter 有独立 idle 计时，需经 SessionManager inhibit；其它桌面及
    # system sleep 再由 systemd-inhibit 覆盖。数组逐项传参，避免 reason 中的
    # 空格被 shell 二次拆分。
    if [[ "${XDG_CURRENT_DESKTOP:-}" == *GNOME* ]] && \
       [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] && \
       command -v gnome-session-inhibit >/dev/null 2>&1; then
        gnome_inhibit=(gnome-session-inhibit
            --app-id "qemu-stealth-${INSTANCE}"
            --reason "保持 guest 显示活性"
            --inhibit idle:logout)
        echo ">> GNOME idle: 已 inhibit (gnome-session-inhibit)"
    fi

    if command -v systemd-inhibit >/dev/null 2>&1; then
        launch_command=("${gnome_inhibit[@]}" systemd-inhibit
            --who="qemu-stealth-${INSTANCE}"
            --why="保持 guest 显示活性"
            --what="idle:sleep:handle-lid-switch"
            --mode=block
            -- "${command[@]}")
    elif (( ${#gnome_inhibit[@]} )); then
        launch_command=("${gnome_inhibit[@]}" "${command[@]}")
    else
        launch_command=("${command[@]}")
    fi

    # 未成功修改 xset 时无需保留父 shell，仍让启动器 PID 直接变成包装器/QEMU。
    if [[ "$SV_DISPLAY_XSET_CHANGED" != "1" ]]; then
        exec "${launch_command[@]}"
    fi
    sv_display_wait_and_restore "${launch_command[@]}"
}
