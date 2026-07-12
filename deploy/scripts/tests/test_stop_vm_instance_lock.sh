#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# stop-vm 参数安全与实例生命周期锁回归测试。
#
# 使用不存在的高位实例号和普通 stale 文件，不启动/停止任何真实 QEMU。持锁期间
# stop 必须等待，证明旧 VM 收尾不能越过新启动器的实例锁删除控制资源。
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
STOP_VM="$REPO_ROOT/deploy/scripts/stop-vm.sh"
LOCK_LIB="$REPO_ROOT/deploy/scripts/lib/sv-instance-lock.sh"
INSTANCE=9987654321

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

expect_arg_failure() {
    local out="$1"
    shift

    if "$STOP_VM" "$@" >"$out" 2>&1; then
        fail "非法 stop 参数本应失败: $*"
    fi
}

test_argument_validation() {
    local out="$1"

    expect_arg_failure "$out" '1|.*'
    grep -F -- "unknown arg" "$out" >/dev/null \
        || fail "正则注入实例号未给出参数错误"
    expect_arg_failure "$out" 0
    grep -F -- "INSTANCE 必须" "$out" >/dev/null \
        || fail "实例 0 未给出范围错误"
    expect_arg_failure "$out" 1 --wait=bad
    grep -F -- "--wait 必须" "$out" >/dev/null \
        || fail "非法 wait 未给出数值错误"
    expect_arg_failure "$out" 12345678901
}

test_cleanup_waits_for_instance_lock() {
    local out="$1" lock stop_pid
    local qmp="/tmp/qemu-stealth-${INSTANCE}.qmp"
    local mon="/tmp/qemu-stealth-${INSTANCE}.mon"

    lock="$(sv_instance_lock_path "$INSTANCE")" || fail "无法生成实例锁路径"
    printf 'stale\n' >"$qmp"
    printf 'stale\n' >"$mon"
    exec 9>"$lock"
    flock -n 9 || fail "测试进程无法持有实例锁"

    "$STOP_VM" "$INSTANCE" --wait=1 9>&- >"$out" 2>&1 &
    stop_pid=$!
    sleep 0.5
    kill -0 "$stop_pid" 2>/dev/null || fail "stop 未等待实例锁便提前退出"
    [[ -e "$qmp" && -e "$mon" ]] || fail "持锁期间 stop 删除了控制文件"

    exec 9>&-
    wait "$stop_pid"
    [[ ! -e "$qmp" && ! -e "$mon" ]] || fail "释放锁后 stop 未清理 stale 文件"
    grep -F -- "no vm instance $INSTANCE running" "$out" >/dev/null \
        || fail "stop 未走预期的无运行实例收尾路径"
    rm -f "$lock"
}

main() {
    local out

    [[ -x "$STOP_VM" && -f "$LOCK_LIB" ]] || fail "stop-vm 或锁库缺失"
    # shellcheck disable=SC1090
    source "$LOCK_LIB"
    out="$(mktemp)"
    trap 'rm -f "${out:-}" /tmp/qemu-stealth-9987654321.{qmp,mon,fb}' EXIT

    test_argument_validation "$out"
    test_cleanup_waits_for_instance_lock "$out"
    echo "PASS: stop-vm 参数校验与跨启动/收尾实例锁"
}

main "$@"
