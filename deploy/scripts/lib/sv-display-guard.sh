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
SV_DISPLAY_CHILD_START=""
SV_DISPLAY_SIGNAL_STATUS=0
SV_DISPLAY_PENDING_SIGNAL=""
SV_DISPLAY_CONTROL_FAILED=0
SV_DISPLAY_GROUP_GUARD=""
SV_DISPLAY_GROUP_GUARDED=0
SV_DISPLAY_GROUP_ADOPTING=0
SV_DISPLAY_GROUP_ADOPTED=0

sv_display_strict_cpu_supervision() {
    [[ "${SV_CPU_STRICT_SUPERVISION_READY:-0}" == "1" \
       && "${CPU_ISOLATE:-1}" == "1" && "${STRICT_HARDWARE:-1}" == "1" ]] \
        && declare -F sv_cpu_isolate_supervise >/dev/null \
        && declare -F sv_cpu_isolate_finish >/dev/null
}

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

sv_display_cleanup_runtime() {
    sv_display_restore_xset
}

sv_display_signal_bound_guard_directly() {
    local requested="$1" raw job_pid
    local -a fields=() job_pids=()

    [[ "${SV_DISPLAY_CHILD_PID:-}" =~ ^[0-9]+$ \
       && "${SV_DISPLAY_CHILD_START:-}" =~ ^[0-9]+$ ]] || return 1
    [[ -r "/proc/$SV_DISPLAY_CHILD_PID/stat" ]] || return 1
    raw="$(<"/proc/$SV_DISPLAY_CHILD_PID/stat")" || return 1
    IFS=' ' read -r -a fields <<<"${raw##*) }"
    (( ${#fields[@]} > 19 )) || return 1
    [[ "${fields[0]}" != [XxZz] \
       && "${fields[19]}" == "$SV_DISPLAY_CHILD_START" \
       && "${fields[2]}" == "$SV_DISPLAY_CHILD_PID" \
       && "${fields[3]}" == "$SV_DISPLAY_CHILD_PID" ]] || return 1

    # Bash 仍把 guard 列为本函数创建且尚未 wait 的 running job；再结合
    # starttime、PGID=PID、SID=PID 复核后，只向 leader 本身发送内建信号。
    # leader 的 handler/sentinel 会清理 session，不直接 kill 可复用的数字 SID。
    mapfile -t job_pids < <(jobs -pr)
    for job_pid in "${job_pids[@]}"; do
        if [[ "$job_pid" == "$SV_DISPLAY_CHILD_PID" ]]; then
            kill "-$requested" -- "$SV_DISPLAY_CHILD_PID" 2>/dev/null
            return $?
        fi
    done
    return 1
}

sv_display_signal_owned_child() {
    local requested="$1" sent=1

    [[ "${SV_DISPLAY_CHILD_PID:-}" =~ ^[0-9]+$ ]] || return 1
    if [[ "${SV_DISPLAY_GROUP_GUARDED:-0}" == "1" ]]; then
        # setsid/代际尚未绑定时只能保留 pending；此刻不能用数值 SID 降级发送，
        # 否则可能命中 guard 建立 session 前所属的调用方进程组。
        [[ "${SV_DISPLAY_CHILD_START:-}" =~ ^[0-9]+$ ]] || return 2
        if [[ ! -x "${SV_DISPLAY_GROUP_GUARD:-}" ]] \
           || ! "$SV_DISPLAY_GROUP_GUARD" signal "$SV_DISPLAY_CHILD_PID" \
                "$SV_DISPLAY_CHILD_START" "$requested" 2>/dev/null; then
            if [[ "${SV_DISPLAY_GROUP_ADOPTED:-0}" == "1" \
               || ( "${SV_DISPLAY_GROUP_ADOPTING:-0}" == "1" \
                    && "$requested" != "USR1" ) ]] \
               && sv_display_signal_bound_guard_directly "$requested"; then
                echo "WARN: pidfd guard 控制失败，已向绑定的直接子进程重放 $requested" >&2
                return 0
            fi
            # check 已做实际 pidfd 探测；运行期控制仍失败时不能互相 wait。
            # 未 adopt 时调用方立即返回并由 start-vm 退出触发 PDEATHSIG/sentinel
            # 清组；已 adopt 路径必须先经过上面的代际+job 双重绑定降级。
            SV_DISPLAY_CONTROL_FAILED=1
            return 1
        fi
        return 0
    fi
    if [[ "${SV_DISPLAY_CHILD_GROUP:-0}" == "1" ]]; then
        kill "-$requested" -- "-$SV_DISPLAY_CHILD_PID" 2>/dev/null && sent=0
        kill "-$requested" -- "$SV_DISPLAY_CHILD_PID" 2>/dev/null && sent=0
        return "$sent"
    fi
    kill "-$requested" -- "$SV_DISPLAY_CHILD_PID" 2>/dev/null
}

sv_display_adopt_child_session() {
    # 外部 USR1 helper 成功送达与 Bash 进入 if-body 之间仍可执行 pending trap；
    # ADOPTING 让该命令边界也能安全使用已绑定 direct-child fallback。
    SV_DISPLAY_GROUP_ADOPTING=1
    if sv_display_signal_owned_child USR1; then
        SV_DISPLAY_GROUP_ADOPTED=1
        SV_DISPLAY_GROUP_ADOPTING=0
        return 0
    fi
    SV_DISPLAY_GROUP_ADOPTING=0
    SV_DISPLAY_GROUP_ADOPTED=0
    return 1
}

sv_display_forward_signal() {
    local signal="$1"
    local status="$2"

    SV_DISPLAY_SIGNAL_STATUS="$status"
    SV_DISPLAY_PENDING_SIGNAL="$signal"
    # guarded setsid 路径把 inhibit 与 QEMU 放进独立 session；非 guarded 的
    # setsid 回退仍按进程组转发。两者都覆盖“信号恰好早于建组”的极短竞态。
    if [[ -n "${SV_DISPLAY_CHILD_PID:-}" ]]; then
        if [[ "${SV_DISPLAY_GROUP_GUARDED:-0}" != "1" \
           || "${SV_DISPLAY_CHILD_START:-}" =~ ^[0-9]+$ ]]; then
            sv_display_signal_owned_child "$signal" || true
        fi
    fi
}

sv_display_wait_for_child_session() {
    local pid="$1" attempt state start pgid sid
    for ((attempt=0; attempt<200; attempt++)); do
        if [[ "${SV_DISPLAY_GROUP_GUARDED:-0}" == "1" ]]; then
            read -r state start pgid sid \
                < <("$SV_DISPLAY_GROUP_GUARD" identity "$pid") || true
        elif declare -F sv_proc_state_starttime_pgid_sid >/dev/null; then
            read -r state start pgid sid \
                < <(sv_proc_state_starttime_pgid_sid "$pid") || true
        fi
        if [[ "$start" =~ ^[0-9]+$ && ! "$state" =~ ^[XxZz]$ \
           && "$pgid" == "$pid" && "$sid" == "$pid" ]]; then
            printf '%s %s\n' "$start" "$sid"
            return 0
        fi
        sleep 0.01
    done
    return 1
}

sv_display_stop_child_generation() {
    local pid="$1" start="$2" sid="${3:-}" attempt _state _pgid
    if [[ ! "$start" =~ ^[0-9]+$ ]]; then
        read -r _state start _pgid < <(sv_proc_state_starttime_pgid "$pid") || true
    fi
    [[ "$sid" =~ ^[0-9]+$ ]] || sid="$pid"
    # strict guard 用 pidfd 接收 TERM，再由仍存活的 session leader 对本启动链
    # 完成 TERM→KILL；父 shell 不对可复用的数字 PID/SID 直接发信号。
    sv_proc_generation_is_live "$pid" "$start" || return 0
    [[ "$(sv_proc_sid "$pid" 2>/dev/null || true)" == "$sid" ]] || return 0
    SV_DISPLAY_CHILD_START="$start"
    sv_display_signal_owned_child TERM \
        || { sv_proc_generation_is_live "$pid" "$start" && return 1; }
    for ((attempt=0; attempt<100; attempt++)); do
        sv_proc_generation_is_live "$pid" "$start" || return 0
        sleep 0.02
    done
    return 1
}

sv_display_wait_and_restore() {
    local child_status=0 handshake_failed=0 child_start="" child_sid=""
    local _wait_state wait_start
    local parent_pid _parent_state parent_start guard guard_ready=0

    # EXIT 是最后一道保险；终端断开、Ctrl+C/Ctrl+\ 和 stop 的 TERM 都先转发
    # 给 inhibit/QEMU session，再由 wait 路径统一恢复 xset。wait 可能被 trap
    # 中断而子进程尚未退出，因此需要继续等待到 kill -0 确认进程消失，不能
    # 过早恢复后留下仍在运行的 VM。
    trap sv_display_cleanup_runtime EXIT
    trap 'sv_display_forward_signal HUP 129' HUP
    trap 'sv_display_forward_signal INT 130' INT
    trap 'sv_display_forward_signal QUIT 131' QUIT
    trap 'sv_display_forward_signal TERM 143' TERM

    guard="${SV_STRICT_GROUP_GUARD:-${BASH_SOURCE[0]%/*}/vm-strict-group-guard.py}"
    if [[ -x "$guard" ]] && "$guard" check >/dev/null 2>&1; then
        guard_ready=1
    fi
    if (( SV_DISPLAY_SIGNAL_STATUS != 0 )); then
        child_status="$SV_DISPLAY_SIGNAL_STATUS"
        sv_display_cleanup_runtime
        trap - EXIT HUP INT QUIT TERM
        return "$child_status"
    fi
    if (( guard_ready == 1 )); then
        parent_pid="$BASHPID"
        read -r _parent_state parent_start _ \
            < <("$guard" identity "$parent_pid") || parent_start=""
        if (( SV_DISPLAY_SIGNAL_STATUS != 0 )); then
            child_status="$SV_DISPLAY_SIGNAL_STATUS"
            sv_display_cleanup_runtime
            trap - EXIT HUP INT QUIT TERM
            return "$child_status"
        fi
        if [[ ! "$parent_start" =~ ^[0-9]+$ ]]; then
            echo "ERROR: 无法建立 QEMU 父代守护" >&2
            return 1
        fi
        SV_DISPLAY_GROUP_GUARD="$guard"
        SV_DISPLAY_GROUP_GUARDED=1
        "$guard" run "$parent_pid" "$parent_start" -- "$@" &
        SV_DISPLAY_CHILD_PID=$!
        SV_DISPLAY_CHILD_GROUP=1
    elif sv_display_strict_cpu_supervision; then
        echo "ERROR: 严格 CPU 隔离缺少 QEMU session 守护" >&2
        return 1
    elif command -v setsid >/dev/null 2>&1; then
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
    # 覆盖“最后一次无子进程检查”与后台启动之间的极窄信号窗：
    # 一旦 trap 已记录信号，立即重放给新建的自有进程，不得 adopt。
    if (( SV_DISPLAY_SIGNAL_STATUS != 0 \
          && SV_DISPLAY_GROUP_GUARDED == 0 )); then
        sv_display_signal_owned_child "${SV_DISPLAY_PENDING_SIGNAL:-TERM}" || true
    fi
    if [[ "${SV_DISPLAY_GROUP_GUARDED:-0}" == "1" ]]; then
        if ! read -r child_start child_sid \
                < <(sv_display_wait_for_child_session "$SV_DISPLAY_CHILD_PID"); then
            echo "ERROR: 无法建立 QEMU 独立 session" >&2
            handshake_failed=1
            read -r _parent_state SV_DISPLAY_CHILD_START _ \
                < <("$SV_DISPLAY_GROUP_GUARD" identity "$SV_DISPLAY_CHILD_PID") \
                || SV_DISPLAY_CHILD_START=""
            if [[ "$SV_DISPLAY_CHILD_START" =~ ^[0-9]+$ ]]; then
                sv_display_signal_owned_child TERM || true
            fi
        else
            SV_DISPLAY_CHILD_START="$child_start"
            if (( SV_DISPLAY_SIGNAL_STATUS != 0 )); then
                sv_display_signal_owned_child \
                    "${SV_DISPLAY_PENDING_SIGNAL:-TERM}" || true
            fi
        fi
        if ! sv_display_strict_cpu_supervision \
           && (( handshake_failed == 0 && SV_DISPLAY_SIGNAL_STATUS == 0 )); then
            if ! sv_display_adopt_child_session; then
                echo "ERROR: 无法提交 QEMU session" >&2
                handshake_failed=1
                sv_display_signal_owned_child TERM || true
            fi
        fi
    fi
    if sv_display_strict_cpu_supervision; then
        if [[ "${SV_DISPLAY_GROUP_GUARDED:-0}" != "1" ]]; then
            echo "ERROR: 无法建立严格 QEMU 独立 session" >&2
            handshake_failed=1
        fi
        if (( handshake_failed == 0 && SV_DISPLAY_SIGNAL_STATUS == 0 )); then
            if ! sv_cpu_isolate_supervise \
                    "$SV_DISPLAY_CHILD_PID" "$child_start" "$child_sid"; then
                handshake_failed=1
            elif ! sv_display_adopt_child_session; then
                echo "ERROR: 无法提交严格 QEMU session" >&2
                handshake_failed=1
            fi
        else
            handshake_failed=1
        fi
        if (( handshake_failed )); then
            sv_display_stop_child_generation \
                "$SV_DISPLAY_CHILD_PID" "$child_start" "$child_sid" \
                || true
        fi
    fi
    while (( SV_DISPLAY_CONTROL_FAILED == 0 )); do
        if wait "$SV_DISPLAY_CHILD_PID"; then
            child_status=0
            break
        else
            child_status=$?
        fi
        (( SV_DISPLAY_CONTROL_FAILED == 0 )) || break
        if [[ "${SV_DISPLAY_GROUP_GUARDED:-0}" == "1" ]]; then
            read -r _wait_state wait_start _ \
                < <("$SV_DISPLAY_GROUP_GUARD" identity "$SV_DISPLAY_CHILD_PID") \
                || break
            [[ "$wait_start" == "$SV_DISPLAY_CHILD_START" ]] || break
        else
            kill -0 "$SV_DISPLAY_CHILD_PID" 2>/dev/null || break
        fi
    done

    SV_DISPLAY_CHILD_PID=""
    SV_DISPLAY_CHILD_START=""
    SV_DISPLAY_CHILD_GROUP=0
    SV_DISPLAY_GROUP_GUARDED=0
    SV_DISPLAY_GROUP_ADOPTING=0
    SV_DISPLAY_GROUP_ADOPTED=0
    if (( SV_DISPLAY_CONTROL_FAILED == 0 )) \
       && sv_display_strict_cpu_supervision && ! sv_cpu_isolate_finish; then
        handshake_failed=1
    fi
    sv_display_cleanup_runtime
    trap - EXIT HUP INT QUIT TERM
    if (( SV_DISPLAY_SIGNAL_STATUS != 0 )); then
        return "$SV_DISPLAY_SIGNAL_STATUS"
    fi
    (( SV_DISPLAY_CONTROL_FAILED == 0 )) || return 1
    (( handshake_failed == 0 )) || return 1
    return "$child_status"
}

sv_display_guard_launch() {
    local -a command=("$@")
    local -a gnome_inhibit=()
    local -a launch_command=()
    local xset_state=""

    SV_DISPLAY_SIGNAL_STATUS=0
    SV_DISPLAY_PENDING_SIGNAL=""
    SV_DISPLAY_CONTROL_FAILED=0
    SV_DISPLAY_GROUP_ADOPTING=0
    SV_DISPLAY_GROUP_ADOPTED=0

    # 无本地 SDL 窗口时不触碰桌面状态；严格 CPU 隔离仍保留轻量父 shell，
    # 让 paused QEMU 在 RUNNING 握手前始终有精确 session 监督者。
    if [[ "${SDL:-0}" != "1" || "${HEADLESS:-0}" == "1" || -z "${DISPLAY:-}" ]]; then
        if sv_display_strict_cpu_supervision; then
            sv_display_wait_and_restore "${command[@]}"
            return $?
        fi
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
                trap sv_display_cleanup_runtime EXIT
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

    # 非严格且未修改 xset 时仍直接 exec；严格模式始终保留启动监督父 shell。
    if [[ "$SV_DISPLAY_XSET_CHANGED" != "1" ]] \
        && ! sv_display_strict_cpu_supervision; then
        exec "${launch_command[@]}"
    fi
    sv_display_wait_and_restore "${launch_command[@]}"
}
