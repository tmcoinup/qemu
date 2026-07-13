#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# start-vm VLAN 参数与“无 VLAN 保持原默认”回归测试。
#
# 本文件只覆盖纯函数和失败/无 VLAN 路径，不要求宿主已执行 setup-bridge.sh，
# 也不会创建接口。真实单 br0 + TAP argv 由 namespace 集成测试覆盖。
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
START_VM="$REPO_ROOT/deploy/scripts/start-vm.sh"
VLAN_LIB="$REPO_ROOT/deploy/scripts/lib/vlan-network.sh"
LOCK_LIB="$REPO_ROOT/deploy/scripts/lib/sv-instance-lock.sh"
RUNTIME_LIB="$REPO_ROOT/deploy/scripts/lib/sv-vlan-preflight.sh"
WATCHDOG_LIB="$REPO_ROOT/deploy/scripts/lib/sv-instance-watchdog.sh"
TEST_OUT=""
TEST_GUARD_PARENT=""
TEST_GUARD_CHILD=""

# 网络回归不验证 CPU 选型；固定兼容 dry-run 平台，避免测试结果依赖 runner 厂商。
export STRICT_HARDWARE=0
export STEALTH_KVM_AVAILABLE=1
export STEALTH_KVM_TSC_CONTROL=1
export STEALTH_KVM_GET_TSC_KHZ=1
export STEALTH_KVM_TSC_KHZ=3600000
export STEALTH_HOST_CPU_VENDOR=GenuineIntel
export STEALTH_HOST_CPU_MAX_MHZ=5000

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

cleanup_test_resources() {
    if [[ -n "${TEST_GUARD_PARENT:-}" ]]; then
        kill "$TEST_GUARD_PARENT" 2>/dev/null || true
    fi
    if [[ -n "${TEST_GUARD_CHILD:-}" ]]; then
        kill "$TEST_GUARD_CHILD" 2>/dev/null || true
    fi
    rm -f "${TEST_OUT:-}"
    rm -rf "${TEST_IMAGE_ROOT:-}"
}

assert_contains() {
    local needle="$1" file="$2"
    grep -F -- "$needle" "$file" >/dev/null || fail "未找到 '$needle'"
}

assert_contains_ci() {
    local needle="$1" file="$2"
    grep -Fi -- "$needle" "$file" >/dev/null || fail "未找到 '$needle'（忽略大小写）"
}

assert_not_contains() {
    local needle="$1" file="$2"
    ! grep -F -- "$needle" "$file" >/dev/null || fail "不应出现 '$needle'"
}

run_expect_failure() {
    local out="$1"
    shift
    if DRY_RUN=1 TPM=0 HOST_TUNE=0 CPU_ISOLATE=0 QEMU_CAP_CHECK=0 \
        IMAGE_ROOT="$TEST_IMAGE_ROOT" "$START_VM" "$@" >"$out" 2>&1; then
        fail "命令本应失败却成功: $*"
    fi
}

test_vlan_id_and_tap_validation() {
    local raw actual

    for raw in 1 11 4094 0001 0011; do
        actual="$(vlan_validate_id "$raw")" || fail "合法 VID '$raw' 被拒绝"
        [[ "$actual" == "$((10#$raw))" ]] || fail "VID '$raw' 未规范化"
    done
    for raw in "" 0 4095 -1 +1 1.0 " 11" abc; do
        ! vlan_validate_id "$raw" >/dev/null 2>&1 || fail "非法 VID '$raw' 被接受"
    done

    [[ "$(vlan_tap_name 1)" == "svtap1" ]] || fail "实例 1 TAP 名错误"
    [[ "$(vlan_tap_name 1234567890)" == "svtap1234567890" ]] \
        || fail "十位实例号 TAP 名错误"
    for raw in "" 0 12345678901 abc '1,script=x'; do
        ! vlan_tap_name "$raw" >/dev/null 2>&1 || fail "非法实例 '$raw' 被接受"
    done
}

test_vlan_cli_rejections() {
    local out="$1" raw

    for raw in "" 0 4095 -1 abc; do
        : >"$out"
        run_expect_failure "$out" 9911 --no-sdl --no-fb-shm "--vlan-id=$raw"
        assert_contains_ci "VLAN" "$out"
        assert_not_contains "__DRY_RUN_ARGV__" "$out"
    done

    : >"$out"
    run_expect_failure "$out" 9912 --no-sdl --no-fb-shm --vlan-id=11 --no-bridge
    assert_contains "--no-bridge" "$out"

    : >"$out"
    run_expect_failure "$out" 9913 --no-sdl --no-fb-shm --vlan-id=11 --bridge=br11
    assert_contains "只支持单一 br0" "$out"
    assert_not_contains "__DRY_RUN_ARGV__" "$out"
}

test_missing_setup_fails_before_side_effects() {
    local out="$1"

    # 固定 helper 未安装时必须在创建 VM_DIR/profile 之前失败。若开发机已经完成
    # 宿主安装，则跳过这个环境相关断言，隔离集成测试仍会覆盖成功路径。
    if [[ -e /usr/local/libexec/qemu-stealth-vlan-tap ]]; then
        echo "SKIP: 宿主已安装 VLAN helper，跳过 missing-helper 断言"
        return 0
    fi
    if TPM=0 HOST_TUNE=0 CPU_ISOLATE=0 QEMU_CAP_CHECK=0 \
        IMAGE_ROOT="$TEST_IMAGE_ROOT" "$START_VM" 9914 --no-sdl --no-fb-shm \
        --vlan-id=11 >"$out" 2>&1; then
        fail "缺失 helper 时 VLAN 启动本应失败"
    fi
    assert_contains "VLAN helper 未安装" "$out"
    ! find "$TEST_IMAGE_ROOT" -mindepth 1 -print -quit | grep -q . \
        || fail "早期预检失败后仍产生 VM 文件"
}

test_vlan_instance_lock() {
    local out="$1"
    local lock

    lock="$(sv_instance_lock_path 9916)" || fail "无法生成测试实例锁路径"

    # 模拟同一实例已有启动器/QEMU 持锁。冲突必须早于 helper、VM_DIR 和 socket
    # 副作用失败，避免第二次启动清掉第一台 VM 的控制面或 TAP。
    exec 9>"$lock"
    flock -n 9 || fail "测试进程无法获取实例锁"
    if TPM=0 HOST_TUNE=0 CPU_ISOLATE=0 QEMU_CAP_CHECK=0 \
        IMAGE_ROOT="$TEST_IMAGE_ROOT" "$START_VM" 9916 --no-sdl --no-fb-shm \
        --vlan-id=11 >"$out" 2>&1; then
        fail "同实例 VLAN 锁冲突时启动器仍成功"
    fi
    assert_contains "已在启动或运行" "$out"

    if TPM=0 HOST_TUNE=0 CPU_ISOLATE=0 QEMU_CAP_CHECK=0 \
        IMAGE_ROOT="$TEST_IMAGE_ROOT" "$START_VM" 9916 --no-sdl --no-fb-shm \
        --no-bridge >"$out" 2>&1; then
        fail "无 VLAN 的同实例锁冲突时启动器仍成功"
    fi
    assert_contains "已在启动或运行" "$out"
    exec 9>&-
    rm -f "$lock"
}

test_instance_guard_holds_lock_across_parent() {
    local lock guard_parent

    lock="$(sv_instance_lock_path 9917)" || fail "无法生成 guard 测试锁路径"
    (
        exec 8>"$lock"
        flock -n 8
        # shellcheck disable=SC2034  # 被 source 的 guard 函数按变量名读取。
        SV_INSTANCE_LOCKED=1
        sv_instance_watchdog_launch
        sleep 1
    ) &
    guard_parent=$!
    sleep 0.2

    exec 7>"$lock"
    if flock -n 7; then
        fail "实例 guard 未在 parent 运行期间持锁"
    fi
    wait "$guard_parent"
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        flock -n 7 && break
        sleep 0.2
    done
    flock -n 7 || fail "parent 结束后实例 guard 未释放锁"
    exec 7>&-
    rm -f "$lock"
}

test_watchdog_waits_for_supervisor_before_vlan_cleanup() {
    local lock log pid_file

    lock="$(sv_instance_lock_path 9918)" || fail "无法生成监督链测试锁路径"
    log="$TEST_IMAGE_ROOT/watchdog-cleanup.log"
    pid_file="$TEST_IMAGE_ROOT/watchdog-child.pid"
    : >"$log"
    (
        # watchdog 子 shell 会继承该 mock，只记录 cleanup 调用，不触碰宿主网络。
        # shellcheck disable=SC2317  # 由异步 watchdog 按函数名间接调用。
        sv_vlan_helper_call() {
            printf '%s\n' "$*" >>"$log"
        }
        exec 8>"$lock"
        flock -n 8 || exit 91
        # 以下变量由被 source 的 watchdog 函数按名称读取。
        # shellcheck disable=SC2034
        SV_INSTANCE_LOCKED=1
        # shellcheck disable=SC2034
        SV_INSTANCE_LOCK="$lock"
        # shellcheck disable=SC2034
        SV_VLAN_PREPARED=1
        # shellcheck disable=SC2034
        VLAN_TAP_IF=svtap9918
        sv_instance_watchdog_launch
        # 模拟父 shell 被 SIGKILL 后仍运行的 setsid/inhibit 监督进程；它继承
        # FD8 并在 1.2 秒后退出。TAP 清理必须晚于这个时刻。
        ( sleep 1.2 ) &
        printf '%s\n' "$!" >"$pid_file"
        sleep 60
    ) &
    TEST_GUARD_PARENT=$!

    for _ in $(seq 1 50); do
        [[ -s "$pid_file" ]] && break
        kill -0 "$TEST_GUARD_PARENT" 2>/dev/null \
            || fail "VLAN watchdog 监督链测试父进程提前退出"
        sleep 0.02
    done
    [[ -s "$pid_file" ]] || fail "未取得模拟监督进程 PID"
    TEST_GUARD_CHILD="$(<"$pid_file")"

    kill -KILL "$TEST_GUARD_PARENT"
    wait "$TEST_GUARD_PARENT" 2>/dev/null || true
    TEST_GUARD_PARENT=""
    sleep 0.3
    [[ ! -s "$log" ]] || fail "父 shell 退出后 watchdog 过早清理运行中 VM 的 TAP"

    for _ in $(seq 1 30); do
        [[ -s "$log" ]] && break
        sleep 0.1
    done
    TEST_GUARD_CHILD=""
    grep -Fx -- "cleanup-ifname svtap9918" "$log" >/dev/null \
        || fail "监督链退出后 watchdog 未清理 VLAN TAP"
    rm -f "$lock"
}

test_no_vlan_keeps_original_path() {
    local out="$1"

    # 不传 VLAN 参数时完全绕过新 helper。--no-bridge 是原有显式 NAT 路径，
    # DRY_RUN 必须继续成功并生成原来的 user backend。
    DRY_RUN=1 TPM=0 HOST_TUNE=0 CPU_ISOLATE=0 QEMU_CAP_CHECK=0 \
        IMAGE_ROOT="$TEST_IMAGE_ROOT" "$START_VM" 9915 --no-sdl --no-fb-shm \
        --no-bridge >"$out" 2>&1
    assert_contains "__DRY_RUN_ARGV__" "$out"
    assert_contains "user,id=net0,hostfwd=" "$out"
    assert_not_contains "svtap" "$out"
    assert_not_contains "qemu-stealth-vlan-down" "$out"
    assert_not_contains "VLAN helper" "$out"
}

main() {
    [[ -x "$START_VM" && -f "$VLAN_LIB" && -f "$LOCK_LIB" \
        && -f "$RUNTIME_LIB" && -f "$WATCHDOG_LIB" ]] \
        || fail "启动器或网络/实例锁库缺失"
    # shellcheck disable=SC1090
    source "$VLAN_LIB"
    # shellcheck disable=SC1090
    source "$LOCK_LIB"
    # shellcheck disable=SC1090
    source "$RUNTIME_LIB"
    # shellcheck disable=SC1090
    source "$WATCHDOG_LIB"
    TEST_OUT="$(mktemp)"
    TEST_IMAGE_ROOT="$(mktemp -d)"
    export TEST_IMAGE_ROOT
    trap cleanup_test_resources EXIT

    test_vlan_id_and_tap_validation
    test_vlan_cli_rejections "$TEST_OUT"
    test_missing_setup_fails_before_side_effects "$TEST_OUT"
    test_vlan_instance_lock "$TEST_OUT"
    test_instance_guard_holds_lock_across_parent
    test_watchdog_waits_for_supervisor_before_vlan_cleanup
    test_no_vlan_keeps_original_path "$TEST_OUT"
    echo "PASS: start-vm VLAN 参数与无 VLAN 兼容路径"
}

main "$@"
