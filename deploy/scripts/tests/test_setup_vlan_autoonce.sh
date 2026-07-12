#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317
# SC2034/SC2317: 全局契约变量与同名函数由 setup_main 间接读取，是刻意的 mock。
# ---------------------------------------------------------------------------
# start-vm 自动触发 setup-bridge.sh 时的宿主级“一次初始化”回归测试。
#
# 测试在用户命名空间内构造 root-owned 临时安装契约，并通过函数边界替换网络
# 操作；不会修改 /etc、/run、NetworkManager 或真实接口。覆盖锁内复检、并发后到
# 者跳过网络重启、身份冲突 fail closed，以及 VID 1 native 拓扑解析。
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SETUP_BRIDGE="$REPO_ROOT/deploy/scripts/setup-bridge.sh"
RUNTIME_LIB="$REPO_ROOT/deploy/scripts/lib/setup-bridge-runtime.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_not_contains() {
    local file="$1" needle="$2" message="$3"

    if grep -F -- "$needle" "$file" >/dev/null; then
        fail "$message（不应出现: $needle）"
    fi
}

test_runtime_contract_exact_match() {
    local root="$TEST_ROOT/contract"

    mkdir -p "$root/source" "$root/libexec" "$root/etc/qemu" "$root/etc/sudoers.d"
    chmod 0755 "$root/libexec" "$root/etc/qemu" "$root/etc/sudoers.d"
    printf '#!/bin/bash\nexit 0\n' >"$root/source/tap"
    printf '#!/bin/bash\nexit 0\n' >"$root/source/down"
    chmod 0755 "$root/source/tap" "$root/source/down"
    cp "$root/source/tap" "$root/libexec/tap"
    cp "$root/source/down" "$root/libexec/down"
    chmod 0755 "$root/libexec/tap" "$root/libexec/down"

    (
        VLAN_TAP_SOURCE="$root/source/tap"
        VLAN_DOWN_SOURCE="$root/source/down"
        VLAN_TAP_INSTALLED="$root/libexec/tap"
        VLAN_DOWN_INSTALLED="$root/libexec/down"
        VLAN_CONFIG="$root/etc/qemu/config"
        VLAN_SUDOERS="$root/etc/sudoers.d/vlan"
        UPLINK=enp5s0
        ALLOWED_UID_VALUE=1000
        ALLOWED_GID_VALUE=1000
        setup_vlan_expected_config >"$VLAN_CONFIG"
        setup_vlan_expected_sudoers >"$VLAN_SUDOERS"
        chmod 0644 "$VLAN_CONFIG"
        chmod 0440 "$VLAN_SUDOERS"
        setup_vlan_runtime_contract_matches
    ) || fail "逐字匹配的 root-owned runtime 契约未被识别为已安装"

    # UID 被改写后即使其余文件仍可信，也不能把另一用户的授权当作本次初始化。
    sed -i 's/ALLOWED_UID=1000/ALLOWED_UID=1001/' "$root/etc/qemu/config"
    if (
        VLAN_TAP_SOURCE="$root/source/tap"
        VLAN_DOWN_SOURCE="$root/source/down"
        VLAN_TAP_INSTALLED="$root/libexec/tap"
        VLAN_DOWN_INSTALLED="$root/libexec/down"
        VLAN_CONFIG="$root/etc/qemu/config"
        VLAN_SUDOERS="$root/etc/sudoers.d/vlan"
        UPLINK=enp5s0
        ALLOWED_UID_VALUE=1000
        ALLOWED_GID_VALUE=1000
        setup_vlan_runtime_contract_matches
    ); then
        fail "不同 UID 的既有 runtime 契约被错误接受"
    fi
}

# 两个不同 instance 可以同时完成用户确认。第二个 setup 在拿到 root 全局锁后
# 若发现第一个已完成，只做幂等基础检查，不再进入 down/up bridge 的代码。
test_second_initializer_skips_network_restart() {
    local trace="$TEST_ROOT/second.trace" out="$TEST_ROOT/second.out"

    : >"$trace"
    if ! (
        VLAN_TRUNK=1
        VLAN_SETUP_AUTO=1
        UPLINK=enp5s0
        setup_validate_inputs() { printf 'validate\n' >>"$trace"; }
        setup_require_vlan_assets() { printf 'assets\n' >>"$trace"; }
        setup_require_root_and_lock() { printf 'root_lock\n' >>"$trace"; }
        setup_resolve_allowed_identity() {
            ALLOWED_UID_VALUE=1000
            ALLOWED_GID_VALUE=1000
            printf 'identity\n' >>"$trace"
        }
        setup_vlan_config_path_exists() { return 0; }
        setup_vlan_config_matches_request() { return 0; }
        setup_install_base_dependencies() { printf 'base\n' >>"$trace"; }
        setup_install_qemu_bridge_helper() { printf 'qemu_helper\n' >>"$trace"; }
        setup_vlan_auto_is_fully_ready() { printf 'ready\n' >>"$trace"; return 0; }
        setup_install_vlan_runtime() { printf 'runtime_forbidden\n' >>"$trace"; return 91; }
        setup_bridge_nm() { printf 'network_forbidden\n' >>"$trace"; return 92; }
        setup_bridge_iproute() { printf 'network_forbidden\n' >>"$trace"; return 93; }
        setup_main >"$out" 2>&1
    ); then
        fail "并发后到的自动 setup 未幂等成功"
    fi
    [[ "$(<"$trace")" == $'validate\nassets\nroot_lock\nidentity\nbase\nqemu_helper\nready' ]] \
        || fail "锁内复检调用顺序不正确"
    assert_not_contains "$trace" runtime_forbidden "已就绪仍重复安装 VLAN runtime"
    assert_not_contains "$trace" network_forbidden "已就绪仍重启 bridge 网络"
}

test_runtime_repair_keeps_ready_network() {
    local trace="$TEST_ROOT/repair.trace" out="$TEST_ROOT/repair.out"

    : >"$trace"
    if ! (
        VLAN_TRUNK=1
        VLAN_SETUP_AUTO=1
        UPLINK=enp5s0
        setup_validate_inputs() { :; }
        setup_require_vlan_assets() { :; }
        setup_require_root_and_lock() { printf 'root_lock\n' >>"$trace"; }
        setup_resolve_allowed_identity() { ALLOWED_UID_VALUE=1000; ALLOWED_GID_VALUE=1000; }
        setup_vlan_config_path_exists() { return 1; }
        setup_install_base_dependencies() { :; }
        setup_install_qemu_bridge_helper() { :; }
        setup_vlan_auto_is_fully_ready() { return 1; }
        setup_install_vlan_runtime() { printf 'runtime_repaired\n' >>"$trace"; }
        setup_vlan_topology_is_ready() { printf 'topology_ready\n' >>"$trace"; return 0; }
        setup_bridge_nm() { printf 'network_forbidden\n' >>"$trace"; return 92; }
        setup_bridge_iproute() { printf 'network_forbidden\n' >>"$trace"; return 93; }
        setup_main >"$out" 2>&1
    ); then
        fail "仅 runtime 缺失时自动修复失败"
    fi
    grep -F -- runtime_repaired "$trace" >/dev/null || fail "未修复缺失 runtime"
    grep -F -- topology_ready "$trace" >/dev/null || fail "runtime 修复后未复检拓扑"
    assert_not_contains "$trace" network_forbidden "拓扑已就绪仍重启 bridge"
}

test_identity_conflict_fails_before_mutation() {
    local trace="$TEST_ROOT/conflict.trace" out="$TEST_ROOT/conflict.out" rc

    : >"$trace"
    set +e
    (
        VLAN_TRUNK=1
        VLAN_SETUP_AUTO=1
        UPLINK=enp5s0
        setup_validate_inputs() { :; }
        setup_require_vlan_assets() { :; }
        setup_require_root_and_lock() { printf 'root_lock\n' >>"$trace"; }
        setup_resolve_allowed_identity() { ALLOWED_UID_VALUE=1000; ALLOWED_GID_VALUE=1000; }
        setup_vlan_config_path_exists() { return 0; }
        setup_vlan_config_matches_request() { return 1; }
        setup_install_base_dependencies() { printf 'mutation_forbidden\n' >>"$trace"; }
        setup_main >"$out" 2>&1
    )
    rc=$?
    set -e
    (( rc != 0 )) || fail "自动 setup 覆盖了不同用户/上联的既有配置"
    grep -F -- root_lock "$trace" >/dev/null || fail "身份冲突检查未在全局锁内执行"
    assert_not_contains "$trace" mutation_forbidden "身份冲突后仍开始宿主安装"
    grep -F -- "拒绝自动覆盖" "$out" >/dev/null || fail "身份冲突缺少人工审计提示"
}

test_topology_readiness_parser() {
    if ! (
        UPLINK=enp5s0
        ip() {
            case "$*" in
                "-d -o link show dev br0")
                    echo '7: br0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 bridge forward_delay 1500 vlan_filtering 1' ;;
                "-o link show dev enp5s0")
                    echo '2: enp5s0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 master br0 state UP' ;;
                *) return 1 ;;
            esac
        }
        bridge() { printf 'port vlan-id\nenp5s0 1 PVID Egress Untagged\n        11\n'; }
        setup_vlan_topology_is_ready
    ); then
        fail "合法单 br0/native VID1 拓扑未被识别为已就绪"
    fi

    if (
        UPLINK=enp5s0
        ip() { echo '2: dev: <UP> master br0 bridge forward_delay 1 vlan_filtering 1'; }
        bridge() { printf 'port vlan-id\nenp5s0 1\n        11 PVID Egress Untagged\n'; }
        setup_vlan_topology_is_ready
    ); then
        fail "非 VID1 native 拓扑被错误识别为可跳过初始化"
    fi
}

main() {
    command -v visudo >/dev/null 2>&1 || fail "缺少 visudo"
    if (( EUID != 0 )); then
        command -v unshare >/dev/null 2>&1 || fail "缺少 unshare"
        [[ "${SV_AUTOONCE_USERNS:-0}" == "1" ]] \
            || exec unshare -Ur -- env SV_AUTOONCE_USERNS=1 bash "$0"
    fi

    TEST_ROOT="$(mktemp -d)"
    trap 'rm -rf -- "${TEST_ROOT:-}"' EXIT
    # shellcheck disable=SC1090
    source "$RUNTIME_LIB"
    test_runtime_contract_exact_match

    [[ -f "$SETUP_BRIDGE" ]] || fail "缺少 setup-bridge.sh"
    # BASH_SOURCE 守卫保证 source 只注册函数，不执行任何宿主操作。
    # shellcheck disable=SC1090,SC1091
    source "$SETUP_BRIDGE"
    test_second_initializer_skips_network_restart
    test_runtime_repair_keeps_ready_network
    test_identity_conflict_fails_before_mutation
    test_topology_readiness_parser
    echo "PASS: setup-bridge 自动初始化全局一次/锁内复检"
}

main "$@"
