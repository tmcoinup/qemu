#!/usr/bin/env bash
# SDL 显示生命周期回归测试：QEMU 失败退出后必须恢复宿主 DPMS/屏保原值。
# 测试刻意在两个隔离 subshell 中覆盖同名环境变量，并以动态定义的空函数替代
# 桌面集成入口；这些变量不应传播回父测试进程，函数则由被 source 的守护模块调用。
# shellcheck disable=SC2030,SC2031,SC2317
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
    chmod +x "$bin_dir/xset" "$bin_dir/systemd-inhibit" \
        "$bin_dir/fake-qemu" "$bin_dir/fake-qemu-wait"
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

test_term_reaches_process_group_and_restores() {
    local work="$1"
    local guard_pid="" vm_pid="" sleep_pid="" status

    : >"$MOCK_LOG"
    export MOCK_PID_FILE="$work/child.pids"
    rm -f "$MOCK_PID_FILE"
    (
        export PATH="$work/bin:/usr/bin:/bin"
        export SDL=1 HEADLESS=0 DISPLAY=:test INSTANCE=9987654320
        export XDG_CURRENT_DESKTOP="" DBUS_SESSION_BUS_ADDRESS=""
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
    trap cleanup_test_resources EXIT
    make_mocks "$TEST_WORK/bin"
    test_failure_restores_exact_xset_state "$TEST_WORK"
    test_term_reaches_process_group_and_restores "$TEST_WORK"
    test_sigkill_parent_keeps_lock_in_vm_chain "$TEST_WORK"
    test_headless_does_not_touch_xset "$TEST_WORK"
    echo "PASS: SDL 显示守护可靠恢复 DPMS/屏保"
}

main "$@"
