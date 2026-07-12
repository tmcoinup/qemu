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
SWTPM_LIB="$REPO_ROOT/deploy/scripts/lib/sv-swtpm-lifecycle.sh"
INSTANCE=9987654321
FAKE_SWTPM_PID=""
TRANSIENT_HOLDER_PID=""
TEST_OUT=""
TEST_TMP_DIR=""
TEST_FAKE_SWTPM=""

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

cleanup_test_resources() {
    if [[ -n "${FAKE_SWTPM_PID:-}" ]]; then
        kill "$FAKE_SWTPM_PID" 2>/dev/null || true
    fi
    if [[ -n "${TRANSIENT_HOLDER_PID:-}" ]]; then
        kill "$TRANSIENT_HOLDER_PID" 2>/dev/null || true
    fi
    rm -rf "${TEST_TMP_DIR:-}"
    rm -f "${TEST_OUT:-}" /tmp/qemu-stealth-9987654321.{qmp,mon,fb}
}

expect_arg_failure() {
    local out="$1"
    shift

    if "$STOP_VM" "$@" >"$out" 2>&1; then
        fail "非法 stop 参数本应失败: $*"
    fi
}

build_fake_swtpm() {
    local source_file="$TEST_TMP_DIR/fake-swtpm.c"
    local compiler="${CC:-cc}"

    command -v "$compiler" >/dev/null 2>&1 || fail "缺少构建假 swtpm 所需的 C 编译器"
    cat >"$source_file" <<'C'
#include <signal.h>
#include <unistd.h>

static void stop_process(int signal_number)
{
    (void)signal_number;
    _exit(0);
}

int main(int argc, char **argv)
{
    (void)argc;
    (void)argv;
    signal(SIGTERM, stop_process);
    for (;;) {
        pause();
    }
}
C
    # 中文注释：真实 ELF 名称为 swtpm，确保被测代码验证 /proc/PID/exe，
    # 而不是依赖 Python 命令行中碰巧出现的 `swtpm socket` 文本。
    mkdir -p "$TEST_TMP_DIR/fake-bin"
    TEST_FAKE_SWTPM="$TEST_TMP_DIR/fake-bin/swtpm"
    "$compiler" -Wall -Wextra -Werror -o "$TEST_FAKE_SWTPM" "$source_file"
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

test_swtpm_daemon_does_not_inherit_fd8() {
    local args_file="$1"
    local lock

    lock="$(sv_instance_lock_path "$INSTANCE")" || fail "无法生成 swtpm FD 测试锁"
    exec 8>"$lock"
    flock -n 8 || fail "无法持有 swtpm FD 测试锁"

    # 中文注释：用同名 shell 函数替代真实 swtpm，直接在被调用命令的执行环境
    # 查看 FD 8。这样无需启动 TPM，也能验证重定向确实只关闭子命令的锁 FD。
    # 该函数由被测生命周期函数按命令名间接调用，静态检查器无法跟踪此调用。
    # shellcheck disable=SC2317
    swtpm() {
        [[ ! -e "/proc/$BASHPID/fd/8" ]] || return 88
        printf '%s\n' "$*" >"$args_file"
    }
    if ! sv_swtpm_start_daemon "/tmp/vms/$INSTANCE/tpm-state" \
        "/tmp/vms/$INSTANCE/tpm-sock" "/tmp/vms/$INSTANCE/tpm.log"; then
        unset -f swtpm
        fail "swtpm 子命令仍继承实例锁 FD 8"
    fi
    unset -f swtpm

    [[ -e "/proc/$BASHPID/fd/8" ]] || fail "启动 swtpm 后父 shell 丢失实例锁"
    grep -F -- "--daemon" "$args_file" >/dev/null || fail "swtpm daemon 参数丢失"
    exec 8>&-
    rm -f "$lock"
}

test_swtpm_matcher_rejects_argument_only_lookalike() {
    local lookalike_pid matched=0

    # 中文注释：诊断进程的普通参数中包含完整 swtpm 文本，但 executable/argv0
    # 都是 Python。旧的“任意 argv 位置搜索”会误判并可能将它 TERM。
    python3 -c 'import time; time.sleep(60)' \
        swtpm socket --tpmstate "dir=/tmp/vms/$INSTANCE/tpm-state" &
    lookalike_pid=$!
    sleep 0.05
    sv_swtpm_pid_matches_instance "$lookalike_pid" "$INSTANCE" && matched=1
    kill "$lookalike_pid" 2>/dev/null || true
    wait "$lookalike_pid" 2>/dev/null || true
    (( matched == 0 )) || fail "swtpm matcher 误认仅参数含关键字的诊断进程"
}

start_fake_swtpm() {
    local state_dir="$1"

    # 中文注释：假 ELF 只等待信号，额外 argv 则精确模拟真实 swtpm daemon。
    "$TEST_FAKE_SWTPM" socket --tpmstate "dir=$state_dir" --daemon &
    FAKE_SWTPM_PID=$!
    sleep 0.1
    kill -0 "$FAKE_SWTPM_PID" 2>/dev/null || fail "无法启动假 swtpm"
}

test_stop_reaps_orphan_swtpm_lock_holder() {
    local out="$1"
    local tmp_dir="$2"
    local lock orphan_pid
    local state_dir="$tmp_dir/vms/$INSTANCE/tpm-state"
    local qmp="/tmp/qemu-stealth-${INSTANCE}.qmp"
    local mon="/tmp/qemu-stealth-${INSTANCE}.mon"

    mkdir -p "$state_dir"
    lock="$(sv_instance_lock_path "$INSTANCE")" || fail "无法生成孤儿 swtpm 测试锁"
    exec 9>"$lock"
    flock -n 9 || fail "无法持有孤儿 swtpm 测试锁"
    start_fake_swtpm "$state_dir"
    orphan_pid="$FAKE_SWTPM_PID"
    # 假 daemon 保留同一个已加锁的 open-file-description，测试父进程退出式地
    # 关闭自身 FD，精确复现旧版 start-vm 崩溃后只剩 swtpm 持锁的现场。
    exec 9>&-
    printf 'stale\n' >"$qmp"
    printf 'stale\n' >"$mon"

    "$STOP_VM" "$INSTANCE" --wait=1 >"$out" 2>&1 \
        || fail "stop-vm 未能自愈持锁的孤儿 swtpm"
    wait "$orphan_pid" 2>/dev/null || true
    FAKE_SWTPM_PID=""

    kill -0 "$orphan_pid" 2>/dev/null && fail "stop-vm 未终止孤儿 swtpm"
    [[ ! -e "$qmp" && ! -e "$mon" ]] || fail "孤儿退出后未清理 stale 控制文件"
    grep -F -- "回收持实例锁的孤儿 swtpm: $orphan_pid" "$out" >/dev/null \
        || fail "stop-vm 未报告孤儿 swtpm 锁自愈"
    rm -f "$lock"
}

test_stop_rechecks_after_transient_watchdog_exits() {
    local out="$1"
    local tmp_dir="$2"
    local lock orphan_pid holder_pid
    local state_dir="$tmp_dir/transient/vms/$INSTANCE/tpm-state"
    local qmp="/tmp/qemu-stealth-${INSTANCE}.qmp"

    mkdir -p "$state_dir"
    lock="$(sv_instance_lock_path "$INSTANCE")" || fail "无法生成状态转换测试锁"
    exec 9>"$lock"
    flock -n 9 || fail "无法持有状态转换测试锁"
    start_fake_swtpm "$state_dir"
    orphan_pid="$FAKE_SWTPM_PID"

    # 中文注释：该非 swtpm 进程模拟 QEMU ABRT 后最多再存活一轮的异步
    # watchdog/显示父进程。它与旧 swtpm 继承同一把锁，0.8 秒后自行退出；
    # stop 必须重新判定持有者，不能沿用第一次“尚非孤儿”的结论直至超时。
    python3 -c 'import time; time.sleep(0.8)' &
    TRANSIENT_HOLDER_PID=$!
    holder_pid="$TRANSIENT_HOLDER_PID"
    exec 9>&-
    printf 'stale\n' >"$qmp"

    if ! "$STOP_VM" "$INSTANCE" --wait=1 >"$out" 2>&1; then
        sed -n '1,120p' "$out" >&2
        fail "stop-vm 未在临时 watchdog 退出后重新回收 swtpm"
    fi
    wait "$holder_pid" 2>/dev/null || true
    TRANSIENT_HOLDER_PID=""
    wait "$orphan_pid" 2>/dev/null || true
    FAKE_SWTPM_PID=""

    kill -0 "$orphan_pid" 2>/dev/null && fail "状态转换后孤儿 swtpm 仍存活"
    grep -F -- "回收持实例锁的孤儿 swtpm: $orphan_pid" "$out" >/dev/null \
        || fail "stop 未报告 watchdog 退出后的二次孤儿判定"
    [[ ! -e "$qmp" ]] || fail "状态转换自愈后未清 stale QMP"
    rm -f "$lock"
}

test_stop_preserves_swtpm_owned_by_live_launcher() {
    local out="$1"
    local tmp_dir="$2"
    local lock swtpm_pid stop_pid
    local state_dir="$tmp_dir/live/vms/$INSTANCE/tpm-state"
    local qmp="/tmp/qemu-stealth-${INSTANCE}.qmp"

    mkdir -p "$state_dir"
    lock="$(sv_instance_lock_path "$INSTANCE")" || fail "无法生成并发启动测试锁"
    exec 9>"$lock"
    flock -n 9 || fail "无法持有并发启动测试锁"
    start_fake_swtpm "$state_dir"
    swtpm_pid="$FAKE_SWTPM_PID"
    printf 'stale\n' >"$qmp"

    "$STOP_VM" "$INSTANCE" --wait=1 9>&- >"$out" 2>&1 &
    stop_pid=$!
    sleep 0.5
    kill -0 "$stop_pid" 2>/dev/null || fail "stop 未等待仍活着的启动器实例锁"
    kill -0 "$swtpm_pid" 2>/dev/null || fail "stop 误杀了活跃启动器创建的 swtpm"
    [[ -e "$qmp" ]] || fail "活跃启动持锁期间 stop 删除了控制文件"

    # 模拟启动器主动取消：先收掉它创建的 daemon，再释放生命周期锁。
    kill "$swtpm_pid" 2>/dev/null || true
    wait "$swtpm_pid" 2>/dev/null || true
    FAKE_SWTPM_PID=""
    exec 9>&-
    wait "$stop_pid"

    grep -F -- "回收持实例锁的孤儿 swtpm" "$out" >/dev/null \
        && fail "stop 把活跃启动阶段的 swtpm 错报为孤儿"
    [[ ! -e "$qmp" ]] || fail "启动器释放锁后 stop 未完成收尾"
    rm -f "$lock"
}

main() {
    [[ -x "$STOP_VM" && -f "$LOCK_LIB" && -f "$SWTPM_LIB" ]] \
        || fail "stop-vm 或生命周期库缺失"
    # shellcheck disable=SC1090
    source "$LOCK_LIB"
    # shellcheck disable=SC1090
    source "$SWTPM_LIB"
    TEST_OUT="$(mktemp)"
    TEST_TMP_DIR="$(mktemp -d)"
    trap cleanup_test_resources EXIT
    build_fake_swtpm

    test_argument_validation "$TEST_OUT"
    test_cleanup_waits_for_instance_lock "$TEST_OUT"
    test_swtpm_daemon_does_not_inherit_fd8 "$TEST_TMP_DIR/swtpm-args"
    test_swtpm_matcher_rejects_argument_only_lookalike
    test_stop_preserves_swtpm_owned_by_live_launcher "$TEST_OUT" "$TEST_TMP_DIR"
    test_stop_rechecks_after_transient_watchdog_exits "$TEST_OUT" "$TEST_TMP_DIR"
    test_stop_reaps_orphan_swtpm_lock_holder "$TEST_OUT" "$TEST_TMP_DIR"
    echo "PASS: stop-vm 参数校验、实例锁与 swtpm 孤儿自愈"
}

main "$@"
