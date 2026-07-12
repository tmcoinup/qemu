#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016
# SC2034: 这些全局契约变量由 source 后的生产函数按名字读取。
# SC2016: 静态契约断言需要按字面匹配生产脚本中的 $uplink/$vm_user。
# ---------------------------------------------------------------------------
# start-vm 自动初始化前的遗留 TAP/root state 冲突门禁测试。
#
# 测试把固定运行态路径切换到一次性目录，并 mock 只读拓扑查询；不会调用 sudo、
# setup-bridge.sh，也不会创建真实 TAP。重点保证任何 svtapN/state/lock 痕迹都会
# 在显示确认提示之前 fail closed，且审计自身不删除管理员需要检查的证据。
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
RUNTIME_LIB="$REPO_ROOT/deploy/scripts/lib/sv-vlan-preflight.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

reset_fixture() {
    rm -rf -- "$TEST_ROOT"
    mkdir -p -- "$TEST_ROOT/sys-class-net"
    SV_VLAN_SYS_CLASS_NET="$TEST_ROOT/sys-class-net"
    SV_VLAN_STATE_DIR="$TEST_ROOT/qemu-stealth-vlan"
    SV_VLAN_LOCK_FILE="$TEST_ROOT/qemu-stealth-vlan.lock"
    SV_VLAN_CONFIG="$TEST_ROOT/stealth-vlan.conf"
    SV_VLAN_PREFLIGHT_CODE="helper_missing"
    SV_VLAN_RUNTIME_CONFLICT=""
}

assert_setup_rejected() {
    local expected="$1"

    if sv_vlan_setup_required >"$TEST_ROOT/out" 2>&1; then
        fail "$expected 时仍被判定为可自动 setup"
    fi
    grep -F -- "$expected" "$TEST_ROOT/out" >/dev/null \
        || fail "拒绝信息未说明冲突来源: $expected"
}

test_clean_first_install_is_still_allowed() {
    reset_fixture
    sv_vlan_setup_required >/dev/null 2>&1 \
        || fail "无 TAP/state/lock 的干净首次安装被错误拒绝"
}

test_reserved_tap_blocks_setup() {
    reset_fixture
    touch -- "$SV_VLAN_SYS_CLASS_NET/svtap37"

    assert_setup_rejected "保留接口 svtap37"
    [[ -e "$SV_VLAN_SYS_CLASS_NET/svtap37" ]] \
        || fail "只读门禁错误删除了遗留 TAP 证据"
}

test_root_state_path_blocks_setup() {
    reset_fixture
    mkdir -p -- "$SV_VLAN_STATE_DIR"
    printf '%s\n' 'VERSION=1' 'INSTANCE=37' 'VLAN_ID=11' \
        'TAP=svtap37' 'BRIDGE=br0' 'OWNER_UID=1000' 'OWNER_GID=1000' \
        >"$SV_VLAN_STATE_DIR/instance-37.state"

    # 看似格式正确的文件也不能由普通启动器自行背书；helper 的 root 配置、
    # owner 与真实 TAP 必须由管理员在特权边界内联合核验。
    assert_setup_rejected "既有 VLAN state 路径"
    [[ -f "$SV_VLAN_STATE_DIR/instance-37.state" ]] \
        || fail "只读门禁错误删除了 state 证据"
}

test_runtime_lock_blocks_setup() {
    reset_fixture
    touch -- "$SV_VLAN_LOCK_FILE"

    assert_setup_rejected "既有 VLAN helper 锁"
    [[ -e "$SV_VLAN_LOCK_FILE" ]] || fail "只读门禁错误删除了 helper 锁"
}

test_conflict_stops_before_confirmation() {
    reset_fixture
    touch -- "$SV_VLAN_SYS_CLASS_NET/svtap88"
    : >"$TEST_ROOT/trace"

    # 使用真实 setup_required；其余边界只记录调用，验证冲突在 TTY/确认/sudo
    # 之前结束，未来重排编排代码也不能把该门禁放到网络修改之后。
    sv_vlan_preflight_once() {
        SV_VLAN_PREFLIGHT_CODE="helper_check_failed"
        return 1
    }
    sv_vlan_can_offer_setup() { echo can_offer >>"$TEST_ROOT/trace"; return 0; }
    sv_vlan_read_answer() { echo read_answer >>"$TEST_ROOT/trace"; return 0; }
    sv_vlan_run_setup() { echo run_setup >>"$TEST_ROOT/trace"; return 0; }

    if sv_vlan_preflight >"$TEST_ROOT/out" 2>&1; then
        fail "遗留 TAP 冲突时 preflight 错误成功"
    fi
    [[ ! -s "$TEST_ROOT/trace" ]] \
        || fail "遗留 TAP 冲突后仍进入确认或 setup 流程"
}

main() {
    [[ -f "$RUNTIME_LIB" ]] || fail "缺少 VLAN 预检库: $RUNTIME_LIB"
    TEST_ROOT="$(mktemp -d)"
    trap 'rm -rf -- "${TEST_ROOT:-}"' EXIT

    HERE="$REPO_ROOT/deploy/scripts"
    INSTANCE=9988
    VLAN_ID=11
    VLAN_TAP_IF=svtap9988
    DRY_RUN=0
    # shellcheck disable=SC1090
    source "$RUNTIME_LIB"

    # 自动调用标记必须位于 env -i 后的白名单环境中；setup-bridge.sh 依靠它在
    # 全局锁内复检“是否已由并发启动完成初始化”，避免第二次迁移宿主网络。
    grep -F -- 'VLAN_TRUNK=1 VLAN_SETUP_AUTO=1 UPLINK="$uplink" VM_USER="$vm_user"' \
        "$RUNTIME_LIB" >/dev/null || fail "sudo setup 命令缺少 VLAN_SETUP_AUTO=1 契约"

    # 测试不关心 br0 是否存在；mock 仅返回“尚未初始化”的空拓扑。
    ip() { return 1; }

    test_clean_first_install_is_still_allowed
    test_reserved_tap_blocks_setup
    test_root_state_path_blocks_setup
    test_runtime_lock_blocks_setup
    test_conflict_stops_before_confirmation
    echo "PASS: start-vm VLAN 遗留 TAP/state 自动初始化门禁"
}

main "$@"
