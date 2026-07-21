#!/usr/bin/env bash
# 长任务的单次 sudo 认证与子进程监督。
#
# 所有 sudo 都由打开会话的同一个 Bash 进程直接启动，兼容按 TTY 或父 PID 绑定的
# 凭据票据。耗时命令由主 Bash 监督；每 10 秒以 `sudo -n -v` 续期，后续特权命令
# 也强制 `sudo -n`，因此任务中途不会再次读取密码。

if [[ "${_SV_SUDO_SESSION_LOADED:-0}" == 1 ]]; then
    # shellcheck disable=SC2317 # source guard 同时兼容直接执行语法检查。
    return 0 2>/dev/null || exit 0
fi
_SV_SUDO_SESSION_LOADED=1

SV_SUDO_SESSION_OPEN=0
SV_SUDO_SESSION_OWNER_BASHPID=""
SV_SUDO_SESSION_ACTIVE_PID=""
SV_SUDO_SESSION_ACTIVE_STARTTIME=""
SV_SUDO_SESSION_STARTTIME_RESULT=""

_sv_sudo_session_read_starttime() {
    local pid="${1:-}" stat_line stat_tail
    local -a stat_fields=()

    SV_SUDO_SESSION_STARTTIME_RESULT=""
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    IFS= read -r stat_line 2>/dev/null <"/proc/$pid/stat" || return 1
    stat_tail="${stat_line##*) }"
    read -r -a stat_fields <<<"$stat_tail"
    (( ${#stat_fields[@]} > 19 )) || return 1
    [[ "${stat_fields[19]}" =~ ^[0-9]+$ ]] || return 1
    SV_SUDO_SESSION_STARTTIME_RESULT="${stat_fields[19]}"
}

_sv_sudo_session_process_matches() {
    local pid="${1:-}" expected="${2:-}"

    [[ "$expected" =~ ^[0-9]+$ ]] || return 1
    _sv_sudo_session_read_starttime "$pid" || return 1
    [[ "$SV_SUDO_SESSION_STARTTIME_RESULT" == "$expected" ]]
}

_sv_sudo_session_require_owner() {
    if [[ "$SV_SUDO_SESSION_OPEN" != 1 ]]; then
        echo "ERROR: sudo 会话尚未打开" >&2
        return 1
    fi
    if [[ "$BASHPID" != "$SV_SUDO_SESSION_OWNER_BASHPID" ]]; then
        echo "ERROR: sudo 会话不能在 pipeline/命令替换子 shell 中使用" >&2
        return 1
    fi
}

sv_sudo_session_open() {
    local status=0

    if [[ "$SV_SUDO_SESSION_OPEN" == 1 ]]; then
        echo "ERROR: sudo 会话已经打开" >&2
        return 1
    fi
    sudo -v || status=$?
    if (( status != 0 )); then
        echo "ERROR: sudo 初始认证失败" >&2
        return "$status"
    fi
    # 立即以非交互模式复核一次；timestamp_timeout=0 等无法续期的策略在耗时操作前
    # 就明确失败，不会等压缩完成后才要求重新认证。
    status=0
    sudo -n -v >/dev/null 2>&1 || status=$?
    if (( status != 0 )); then
        echo "ERROR: 当前 sudo 策略不允许单次认证续期" >&2
        return "$status"
    fi
    SV_SUDO_SESSION_OPEN=1
    SV_SUDO_SESSION_OWNER_BASHPID="$BASHPID"
}

sv_sudo_session_refresh() {
    local status=0

    _sv_sudo_session_require_owner || return 1
    sudo -n -v >/dev/null 2>&1 || status=$?
    if (( status != 0 )); then
        echo "ERROR: sudo 凭据续期失败；不会再次询问密码" >&2
    fi
    return "$status"
}

# 只终止仍与记录 starttime 匹配的本次子进程，避免 PID 复用后误伤无关进程。
sv_sudo_session_cancel_active() {
    local pid="$SV_SUDO_SESSION_ACTIVE_PID"
    local starttime="$SV_SUDO_SESSION_ACTIVE_STARTTIME"
    local attempt

    SV_SUDO_SESSION_ACTIVE_PID=""
    SV_SUDO_SESSION_ACTIVE_STARTTIME=""
    if ! _sv_sudo_session_process_matches "$pid" "$starttime"; then
        [[ "$pid" =~ ^[1-9][0-9]*$ ]] && wait "$pid" 2>/dev/null || true
        return 0
    fi

    kill -TERM "$pid" 2>/dev/null || true
    for (( attempt = 0; attempt < 50; attempt++ )); do
        _sv_sudo_session_process_matches "$pid" "$starttime" || break
        sleep 0.1
    done
    if _sv_sudo_session_process_matches "$pid" "$starttime"; then
        kill -KILL "$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
}

# 后台只运行被监督命令；主 Bash 保持前台并负责续期，所以所有 sudo 子进程拥有
# 相同父 PID。调用方不得把本函数放进 pipeline、命令替换或显式后台任务。
sv_sudo_session_supervise() {
    local child_pid child_starttime status=0 refresh_ticks=0

    (( $# > 0 )) || {
        echo "ERROR: 子进程监督器缺少待执行命令" >&2
        return 2
    }
    if [[ -n "$SV_SUDO_SESSION_ACTIVE_PID" ]]; then
        echo "ERROR: 已有受监督子进程在运行" >&2
        return 1
    fi
    if [[ "$SV_SUDO_SESSION_OPEN" == 1 &&
          "$BASHPID" != "$SV_SUDO_SESSION_OWNER_BASHPID" ]]; then
        echo "ERROR: 耗时命令不能在 sudo 会话的子 shell 中监督" >&2
        return 1
    fi

    "$@" &
    child_pid=$!
    if ! _sv_sudo_session_read_starttime "$child_pid"; then
        wait "$child_pid" || status=$?
        return "$status"
    fi
    child_starttime="$SV_SUDO_SESSION_STARTTIME_RESULT"
    SV_SUDO_SESSION_ACTIVE_PID="$child_pid"
    SV_SUDO_SESSION_ACTIVE_STARTTIME="$child_starttime"

    while _sv_sudo_session_process_matches "$child_pid" "$child_starttime"; do
        sleep 1 || true
        _sv_sudo_session_process_matches "$child_pid" "$child_starttime" || break
        if [[ "$SV_SUDO_SESSION_OPEN" == 1 ]]; then
            refresh_ticks=$((refresh_ticks + 1))
            if (( refresh_ticks >= 10 )); then
                if ! sv_sudo_session_refresh; then
                    sv_sudo_session_cancel_active
                    return 1
                fi
                refresh_ticks=0
            fi
        fi
    done

    wait "$child_pid" || status=$?
    SV_SUDO_SESSION_ACTIVE_PID=""
    SV_SUDO_SESSION_ACTIVE_STARTTIME=""
    return "$status"
}

sv_sudo_session_run_supervised() {
    local status=0

    (( $# > 0 )) || {
        echo "ERROR: sudo 会话缺少待执行命令" >&2
        return 2
    }
    _sv_sudo_session_require_owner || return 1
    sv_sudo_session_supervise sudo -n -- "$@" || status=$?
    if (( status != 0 )); then
        echo "ERROR: 非交互 sudo 执行失败；不会再次询问密码" >&2
    fi
    return "$status"
}

sv_sudo_session_close() {
    sv_sudo_session_cancel_active
    SV_SUDO_SESSION_OPEN=0
    SV_SUDO_SESSION_OWNER_BASHPID=""
}
