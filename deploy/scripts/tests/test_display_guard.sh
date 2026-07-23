#!/usr/bin/env bash
# SDL 显示生命周期回归测试：QEMU 失败退出后必须恢复宿主 DPMS/屏保原值。
# 测试刻意在两个隔离 subshell 中覆盖同名环境变量，并以动态定义的空函数替代
# 桌面集成入口；这些变量不应传播回父测试进程，函数则由被 source 的守护模块调用。
# shellcheck disable=SC2030,SC2031,SC2317,SC2329
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
DISPLAY_GUARD="$REPO_ROOT/deploy/scripts/lib/sv-display-guard.sh"
TEST_WORK=""

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

cleanup_test_resources() {
    rm -rf "${TEST_WORK:-}"
}

make_mocks() {
    local bin_dir="$1"

    mkdir -p "$bin_dir"
    cat >"$bin_dir/xset" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "q" ]]; then
    cat <<'STATE'
Screen Saver:
  timeout:  600    cycle:  300
DPMS (Energy Star):
  DPMS is Enabled
STATE
    exit 0
fi
printf 'xset:%s\n' "$*" >>"$MOCK_LOG"
SH
    cat >"$bin_dir/systemd-inhibit" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'inhibit:%s\n' "$*" >>"$MOCK_LOG"
while (( $# )) && [[ "$1" != "--" ]]; do
    shift
done
(( $# )) && shift
exec "$@"
SH
    cat >"$bin_dir/fake-qemu" <<'SH'
#!/usr/bin/env bash
# 用非零退出模拟 QEMU ABRT 后包装器观察到的失败状态；无需真的生成 core。
exit 134
SH
    cat >"$bin_dir/fake-qemu-wait" <<'SH'
#!/usr/bin/env bash
# 额外的 sleep 后代用于确认 TERM 会发送给整个 inhibit/QEMU 进程组。
sleep 60 &
sleep_pid=$!
printf '%s %s\n' "$$" "$sleep_pid" >"$MOCK_PID_FILE"
wait "$sleep_pid"
SH
    cat >"$bin_dir/rejected-guard" <<'SH'
#!/usr/bin/env bash
# 模拟文件存在但当前内核不具备 pidfd 能力：只允许探测，不应进入 run。
printf '%s\n' "${1:-}" >>"$MOCK_GUARD_LOG"
[[ "${1:-}" == "check" ]] && exit 1
exit 99
SH
    cat >"$bin_dir/slow-rejected-guard" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${1:-}" >>"$MOCK_GUARD_LOG"
if [[ "${1:-}" == "check" ]]; then
    : >"$MOCK_GUARD_CHECK_READY"
    sleep 0.5
    exit 1
fi
exit 99
SH
    cat >"$bin_dir/signal-rejecting-guard" <<'SH'
#!/usr/bin/env bash
# 能力探测/身份/启动委托给真实 guard，只模拟运行期 pidfd 控制失败。
if [[ "${1:-}" == "signal" ]]; then
    sleep 0.1
    exit 1
fi
exec "$REAL_GROUP_GUARD" "$@"
SH
    cat >"$bin_dir/slow-identity-guard" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "identity" && ! -e "$MOCK_GUARD_IDENTITY_READY" ]]; then
    : >"$MOCK_GUARD_IDENTITY_READY"
    sleep 0.5
fi
exec "$REAL_GROUP_GUARD" "$@"
SH
    cat >"$bin_dir/term-rejecting-guard" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "signal" ]]; then
    requested="${!#}"
    if [[ "$requested" == "USR1" ]]; then
        "$REAL_GROUP_GUARD" "$@"
        status=$?
        (( status != 0 )) || : >"$MOCK_GUARD_ADOPTED_READY"
        sleep 0.5
        exit "$status"
    fi
    : >"$MOCK_GUARD_TERM_REJECTED"
    exit 1
fi
exec "$REAL_GROUP_GUARD" "$@"
SH
    chmod +x "$bin_dir/xset" "$bin_dir/systemd-inhibit" \
        "$bin_dir/fake-qemu" "$bin_dir/fake-qemu-wait" \
        "$bin_dir/rejected-guard" "$bin_dir/slow-rejected-guard" \
        "$bin_dir/signal-rejecting-guard" "$bin_dir/slow-identity-guard" \
        "$bin_dir/term-rejecting-guard"
}

process_is_live() {
    local pid="$1" state
    state="$(ps -o stat= -p "$pid" 2>/dev/null || true)"
    [[ -n "$state" && ! "$state" =~ ^[XxZz] ]]
}

test_failure_restores_exact_xset_state() {
    local work="$1"
    local status

    : >"$MOCK_LOG"
    set +e
    (
        export PATH="$work/bin:/usr/bin:/bin"
        export SDL=1 HEADLESS=0 DISPLAY=:test INSTANCE=9987654320
        export XDG_CURRENT_DESKTOP="" DBUS_SESSION_BUS_ADDRESS=""
        # 桌面图标不属于本测试范围，用空实现隔离外部 GNOME 状态。
        sv_dock_integrate() { :; }
        # shellcheck disable=SC1090
        source "$DISPLAY_GUARD"
        sv_display_guard_launch fake-qemu
    ) >"$work/out" 2>&1
    status=$?
    set -e

    [[ "$status" == "134" ]] || fail "显示守护丢失 QEMU 失败退出码: $status"
    grep -Fx -- "xset:s off -dpms" "$MOCK_LOG" >/dev/null \
        || fail "启动前未临时关闭 DPMS/屏保"
    grep -Fx -- "xset:+dpms" "$MOCK_LOG" >/dev/null \
        || fail "QEMU 失败退出后未恢复 DPMS"
    grep -Fx -- "xset:s 600 300" "$MOCK_LOG" >/dev/null \
        || fail "QEMU 失败退出后未精确恢复屏保 timeout/cycle"
    [[ "$(grep -c '^xset:' "$MOCK_LOG")" == "3" ]] \
        || fail "xset 恢复命令出现缺失或重复"
}

test_headless_does_not_touch_xset() {
    local work="$1"
    local status

    : >"$MOCK_LOG"
    set +e
    (
        export PATH="$work/bin:/usr/bin:/bin"
        export SDL=0 HEADLESS=0 DISPLAY=:test INSTANCE=9987654320
        sv_dock_integrate() { :; }
        # shellcheck disable=SC1090
        source "$DISPLAY_GUARD"
        sv_display_guard_launch fake-qemu
    ) >"$work/headless-out" 2>&1
    status=$?
    set -e

    [[ "$status" == "134" ]] || fail "无窗口 exec 路径丢失退出码: $status"
    [[ ! -s "$MOCK_LOG" ]] || fail "无 SDL 窗口时仍修改了桌面状态"
}

test_guard_capability_failure_falls_back_to_setsid() {
    local work="$1"
    local status

    : >"$MOCK_LOG"
    : >"$MOCK_GUARD_LOG"
    set +e
    (
        export PATH="$work/bin:/usr/bin:/bin"
        export SDL=1 HEADLESS=0 DISPLAY=:test INSTANCE=9987654320
        export XDG_CURRENT_DESKTOP="" DBUS_SESSION_BUS_ADDRESS=""
        export SV_STRICT_GROUP_GUARD="$work/bin/rejected-guard"
        sv_dock_integrate() { :; }
        # shellcheck disable=SC1090
        source "$DISPLAY_GUARD"
        sv_display_guard_launch fake-qemu
    ) >"$work/rejected-guard-out" 2>&1
    status=$?
    set -e

    [[ "$status" == "134" ]] \
        || fail "守护能力不足时 setsid 回退丢失客机退出码: $status"
    [[ "$(wc -l <"$MOCK_GUARD_LOG")" == "1" ]] \
        || fail "守护能力不足时仍调用了非探测命令"
    grep -Fx -- "check" "$MOCK_GUARD_LOG" >/dev/null \
        || fail "未执行进程组守护能力探测"
}

test_term_during_guard_check_never_launches_guest() {
    local work="$1"
    local parent_pid status

    : >"$MOCK_LOG"
    : >"$MOCK_GUARD_LOG"
    rm -f "$MOCK_GUARD_CHECK_READY" "$MOCK_PID_FILE"
    (
        export PATH="$work/bin:/usr/bin:/bin"
        export SDL=1 HEADLESS=0 DISPLAY=:test INSTANCE=9987654320
        export XDG_CURRENT_DESKTOP="" DBUS_SESSION_BUS_ADDRESS=""
        export SV_STRICT_GROUP_GUARD="$work/bin/slow-rejected-guard"
        sv_dock_integrate() { :; }
        # shellcheck disable=SC1090
        source "$DISPLAY_GUARD"
        sv_display_guard_launch fake-qemu-wait
    ) >"$work/term-during-check-out" 2>&1 &
    parent_pid=$!

    for _ in $(seq 1 100); do
        [[ -e "$MOCK_GUARD_CHECK_READY" ]] && break
        process_is_live "$parent_pid" || fail "延迟 check fixture 提前退出"
        sleep 0.01
    done
    [[ -e "$MOCK_GUARD_CHECK_READY" ]] || fail "未进入延迟 guard check"
    kill -TERM "$parent_pid"
    for _ in $(seq 1 200); do
        process_is_live "$parent_pid" || break
        sleep 0.01
    done
    if process_is_live "$parent_pid"; then
        kill -KILL "$parent_pid" 2>/dev/null || true
        wait "$parent_pid" 2>/dev/null || true
        fail "guard check 期间 TERM 后显示父进程未及时退出"
    fi
    set +e
    wait "$parent_pid"
    status=$?
    set -e

    [[ "$status" == "143" ]] || fail "guard check 期间 TERM 丢失 143: $status"
    [[ ! -e "$MOCK_PID_FILE" ]] || fail "guard check 期间 TERM 后仍启动了 guest"
    grep -Fx -- "xset:+dpms" "$MOCK_LOG" >/dev/null \
        || fail "guard check 期间 TERM 未恢复 DPMS"
}

test_term_during_guard_identity_never_launches_guest() {
    local work="$1"
    local parent_pid status

    : >"$MOCK_LOG"
    rm -f "$MOCK_GUARD_IDENTITY_READY" "$MOCK_PID_FILE"
    (
        export PATH="$work/bin:/usr/bin:/bin"
        export SDL=1 HEADLESS=0 DISPLAY=:test INSTANCE=9987654320
        export XDG_CURRENT_DESKTOP="" DBUS_SESSION_BUS_ADDRESS=""
        export SV_STRICT_GROUP_GUARD="$work/bin/slow-identity-guard"
        sv_dock_integrate() { :; }
        # shellcheck disable=SC1090
        source "$DISPLAY_GUARD"
        sv_display_guard_launch fake-qemu-wait
    ) >"$work/term-during-identity-out" 2>&1 &
    parent_pid=$!

    for _ in $(seq 1 100); do
        [[ -e "$MOCK_GUARD_IDENTITY_READY" ]] && break
        process_is_live "$parent_pid" || fail "延迟 identity fixture 提前退出"
        sleep 0.01
    done
    [[ -e "$MOCK_GUARD_IDENTITY_READY" ]] || fail "未进入延迟 guard identity"
    kill -TERM "$parent_pid"
    for _ in $(seq 1 200); do
        process_is_live "$parent_pid" || break
        sleep 0.01
    done
    if process_is_live "$parent_pid"; then
        kill -KILL "$parent_pid" 2>/dev/null || true
        wait "$parent_pid" 2>/dev/null || true
        fail "guard identity 期间 TERM 后显示父进程未及时退出"
    fi
    set +e
    wait "$parent_pid"
    status=$?
    set -e

    [[ "$status" == "143" ]] || fail "guard identity 期间 TERM 丢失 143: $status"
    [[ ! -e "$MOCK_PID_FILE" ]] || fail "guard identity 期间 TERM 后仍启动了 guest"
    grep -Fx -- "xset:+dpms" "$MOCK_LOG" >/dev/null \
        || fail "guard identity 期间 TERM 未恢复 DPMS"
}

test_runtime_signal_failure_does_not_deadlock() {
    local work="$1"
    local parent_pid status vm_pid sleep_pid

    : >"$MOCK_LOG"
    rm -f "$MOCK_PID_FILE"
    (
        export PATH="$work/bin:/usr/bin:/bin"
        export SDL=1 HEADLESS=0 DISPLAY=:test INSTANCE=9987654320
        export XDG_CURRENT_DESKTOP="" DBUS_SESSION_BUS_ADDRESS=""
        export SV_STRICT_GROUP_GUARD="$work/bin/signal-rejecting-guard"
        sv_dock_integrate() { :; }
        # shellcheck disable=SC1090
        source "$DISPLAY_GUARD"
        sv_display_guard_launch fake-qemu-wait
    ) >"$work/signal-rejecting-out" 2>&1 &
    parent_pid=$!

    for _ in $(seq 1 300); do
        process_is_live "$parent_pid" || break
        sleep 0.01
    done
    if process_is_live "$parent_pid"; then
        kill -KILL "$parent_pid" 2>/dev/null || true
        wait "$parent_pid" 2>/dev/null || true
        fail "guard signal 失败后父子互相等待"
    fi
    set +e
    wait "$parent_pid"
    status=$?
    set -e
    [[ "$status" == "1" ]] || fail "guard signal 失败未 fail closed: $status"

    if [[ -s "$MOCK_PID_FILE" ]]; then
        read -r vm_pid sleep_pid <"$MOCK_PID_FILE"
        for _ in $(seq 1 200); do
            if ! process_is_live "$vm_pid" && ! process_is_live "$sleep_pid"; then
                break
            fi
            sleep 0.01
        done
        process_is_live "$vm_pid" && fail "signal 失败返回后 guard 未清理 guest"
        process_is_live "$sleep_pid" && fail "signal 失败返回后 sentinel 未清理后代"
    fi
    return 0
}

test_term_reaches_process_group_and_restores() {
    local work="$1"
    local guard_override="${2:-}"
    local guard_pid="" vm_pid="" sleep_pid="" status

    : >"$MOCK_LOG"
    export MOCK_PID_FILE="$work/child.pids"
    rm -f "$MOCK_PID_FILE"
    (
        export PATH="$work/bin:/usr/bin:/bin"
        export SDL=1 HEADLESS=0 DISPLAY=:test INSTANCE=9987654320
        export XDG_CURRENT_DESKTOP="" DBUS_SESSION_BUS_ADDRESS=""
        [[ -z "$guard_override" ]] \
            || export SV_STRICT_GROUP_GUARD="$guard_override"
        sv_dock_integrate() { :; }
        # shellcheck disable=SC1090
        source "$DISPLAY_GUARD"
        sv_display_guard_launch fake-qemu-wait
    ) >"$work/term-out" 2>&1 &
    guard_pid=$!

    for _ in $(seq 1 50); do
        [[ -s "$MOCK_PID_FILE" ]] && break
        kill -0 "$guard_pid" 2>/dev/null || fail "信号测试的显示守护提前退出"
        sleep 0.02
    done
    [[ -s "$MOCK_PID_FILE" ]] || fail "未取得模拟 QEMU/后代 PID"
    read -r vm_pid sleep_pid <"$MOCK_PID_FILE"
    if [[ -n "$guard_override" ]]; then
        for _ in $(seq 1 100); do
            [[ -e "$MOCK_GUARD_ADOPTED_READY" ]] && break
            sleep 0.01
        done
        [[ -e "$MOCK_GUARD_ADOPTED_READY" ]] || fail "选择性 fixture 未完成 adopt"
        sleep 0.05
    fi

    kill -TERM "$guard_pid"
    set +e
    wait "$guard_pid"
    status=$?
    set -e

    [[ "$status" == "143" ]] || fail "TERM 路径未返回 143: $status"
    kill -0 "$vm_pid" 2>/dev/null && fail "TERM 后 inhibit/QEMU 进程仍存活"
    kill -0 "$sleep_pid" 2>/dev/null && fail "TERM 未到达 QEMU 后代进程组"
    grep -Fx -- "xset:+dpms" "$MOCK_LOG" >/dev/null \
        || fail "TERM 路径未恢复 DPMS"
    grep -Fx -- "xset:s 600 300" "$MOCK_LOG" >/dev/null \
        || fail "TERM 路径未恢复屏保"
    [[ -z "$guard_override" || -e "$MOCK_GUARD_TERM_REJECTED" ]] \
        || fail "未确定性触发 adopt 后 pidfd TERM 失败"
}

test_sigkill_parent_keeps_lock_in_vm_chain() {
    local work="$1"
    local guard_pid vm_pid sleep_pid pgid released=0
    local lock_file="$work/instance.lock"

    : >"$MOCK_LOG"
    export MOCK_PID_FILE="$work/sigkill-child.pids"
    rm -f "$MOCK_PID_FILE"
    (
        exec 8>"$lock_file"
        flock -n 8 || exit 90
        export PATH="$work/bin:/usr/bin:/bin"
        export SDL=1 HEADLESS=0 DISPLAY=:test INSTANCE=9987654320
        export XDG_CURRENT_DESKTOP="" DBUS_SESSION_BUS_ADDRESS=""
        sv_dock_integrate() { :; }
        # shellcheck disable=SC1090
        source "$DISPLAY_GUARD"
        sv_display_guard_launch fake-qemu-wait
    ) >"$work/sigkill-out" 2>&1 &
    guard_pid=$!

    for _ in $(seq 1 50); do
        [[ -s "$MOCK_PID_FILE" ]] && break
        kill -0 "$guard_pid" 2>/dev/null || fail "SIGKILL 测试的显示守护提前退出"
        sleep 0.02
    done
    [[ -s "$MOCK_PID_FILE" ]] || fail "SIGKILL 测试未取得客机进程链 PID"
    read -r vm_pid sleep_pid <"$MOCK_PID_FILE"
    pgid="$(ps -o pgid= -p "$vm_pid" | tr -d ' ')"
    [[ "$pgid" =~ ^[0-9]+$ ]] || fail "无法读取客机进程组"

    kill -KILL "$guard_pid"
    wait "$guard_pid" 2>/dev/null || true
    exec 9>"$lock_file"
    if flock -n 9; then
        kill -TERM -- "-$pgid" 2>/dev/null || true
        fail "显示父 shell 被 SIGKILL 后客机进程链未继续持有实例锁"
    fi

    # 清掉模拟客机后，继承的 FD8 应随整个 setsid 进程组释放。
    kill -TERM -- "-$pgid" 2>/dev/null || true
    for _ in $(seq 1 50); do
        if flock -n 9; then
            released=1
            break
        fi
        sleep 0.02
    done
    exec 9>&-
    (( released == 1 )) || fail "模拟客机退出后实例锁未释放"
    kill -0 "$vm_pid" 2>/dev/null && fail "SIGKILL 清理后模拟 QEMU 仍存活"
    kill -0 "$sleep_pid" 2>/dev/null && fail "SIGKILL 清理后 QEMU 后代仍存活"
    return 0
}

main() {
    [[ -f "$DISPLAY_GUARD" ]] || fail "缺少显示生命周期模块"
    TEST_WORK="$(mktemp -d)"
    export MOCK_LOG="$TEST_WORK/mock.log"
    export MOCK_GUARD_LOG="$TEST_WORK/guard.log"
    export MOCK_GUARD_CHECK_READY="$TEST_WORK/guard-check.ready"
    export MOCK_GUARD_IDENTITY_READY="$TEST_WORK/guard-identity.ready"
    export MOCK_GUARD_ADOPTED_READY="$TEST_WORK/guard-adopted.ready"
    export MOCK_GUARD_TERM_REJECTED="$TEST_WORK/guard-term-rejected.ready"
    export MOCK_PID_FILE="$TEST_WORK/child.pids"
    export REAL_GROUP_GUARD="$REPO_ROOT/deploy/scripts/lib/vm-strict-group-guard.py"
    trap cleanup_test_resources EXIT
    make_mocks "$TEST_WORK/bin"
    test_failure_restores_exact_xset_state "$TEST_WORK"
    test_guard_capability_failure_falls_back_to_setsid "$TEST_WORK"
    test_term_during_guard_check_never_launches_guest "$TEST_WORK"
    test_term_during_guard_identity_never_launches_guest "$TEST_WORK"
    test_runtime_signal_failure_does_not_deadlock "$TEST_WORK"
    test_term_reaches_process_group_and_restores "$TEST_WORK"
    rm -f "$MOCK_GUARD_ADOPTED_READY" "$MOCK_GUARD_TERM_REJECTED"
    test_term_reaches_process_group_and_restores \
        "$TEST_WORK" "$TEST_WORK/bin/term-rejecting-guard"
    test_sigkill_parent_keeps_lock_in_vm_chain "$TEST_WORK"
    test_headless_does_not_touch_xset "$TEST_WORK"
    echo "PASS: SDL 显示守护可靠恢复 DPMS/屏保"
}

main "$@"
