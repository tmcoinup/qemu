#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 普通 bridge 启动前物理上联健康预检回归测试
#
# 全部接口、sysfs 和 root owner 都由临时目录与 Bash mock 提供；不会读取或修改
# 宿主 NetworkManager、bridge、TAP、路由或系统配置。
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
LIB="$REPO_ROOT/deploy/scripts/lib/sv-network-preflight.sh"
VLAN_LIB="$REPO_ROOT/deploy/scripts/lib/sv-vlan-preflight.sh"
DEVICES="$REPO_ROOT/deploy/scripts/lib/sv-devices.sh"
REAL_STAT="$(command -v stat)"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_fails_with() {
    local expected="$1"
    shift
    local output rc

    set +e
    output="$("$@" 2>&1)"
    rc=$?
    set -e
    (( rc != 0 )) || fail "预期失败但命令成功: $expected"
    grep -F -- "$expected" <<<"$output" >/dev/null \
        || fail "失败诊断缺少 '$expected'，实际: $output"
}

write_valid_config() {
    local path="$1" bridge="${2:-br0}" uplink="${3:-enp3s0}"

    {
        printf 'VERSION=1\n'
        printf 'BRIDGE=%s\n' "$bridge"
        printf 'UPLINK=%s\n' "$uplink"
        printf 'ALLOWED_UID=1000\n'
        printf 'ALLOWED_GID=1000\n'
    } >"$path"
    chmod 0600 "$path"
}

# 生产配置必须 root-owned；测试进程无需 root，通过只覆盖 owner 查询模拟可信文件。
stat() {
    local format="" path="${*: -1}"

    if [[ "${1:-}" == "-c" ]]; then
        format="${2:-}"
    fi
    if [[ "$format" == "%u" && "$path" == "$TEST_ROOT"* ]]; then
        printf '%s\n' "${MOCK_OWNER:-0}"
        return 0
    fi
    "$REAL_STAT" "$@"
}

ip() {
    case "$*" in
        "-d -o link show dev br0")
            printf '%s\n' "$MOCK_BRIDGE_DETAILS"
            ;;
        "-d -o link show dev enp3s0")
            printf '%s\n' "$MOCK_UPLINK_DETAILS"
            ;;
        *)
            echo "unexpected ip call: $*" >&2
            return 90
            ;;
    esac
}

run_preflight() {
    sv_bridge_uplink_preflight br0 "$CONFIG" "$SYS_CLASS_NET"
}

reset_healthy_fixture() {
    rm -rf -- "$TEST_ROOT/config" "$SYS_CLASS_NET"
    mkdir -p "$TEST_ROOT/config" "$SYS_CLASS_NET/enp3s0/device"
    chmod 0700 "$TEST_ROOT/config"
    CONFIG="$TEST_ROOT/config/stealth-vlan.conf"
    write_valid_config "$CONFIG"
    printf '1\n' >"$SYS_CLASS_NET/enp3s0/type"
    printf '1\n' >"$SYS_CLASS_NET/enp3s0/carrier"
    MOCK_OWNER=0
    MOCK_BRIDGE_DETAILS='7: br0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 state UP bridge forward_delay 1500 vlan_filtering 1'
    MOCK_UPLINK_DETAILS='2: enp3s0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 master br0 state UP bridge_slave state forwarding'
}

test_healthy_and_l2_only_contract() {
    reset_healthy_fixture
    # ip mock 只接受两个 link 查询；若实现偷查 IPv4、默认路由或 DHCP，本测试会失败。
    run_preflight || fail "健康物理上联未通过只读预检"
}

test_bridge_failures() {
    reset_healthy_fixture
    MOCK_BRIDGE_DETAILS='7: br0: <BROADCAST,MULTICAST,UP> mtu 1500 state UP dummy'
    assert_fails_with "不是 Linux bridge" run_preflight

    reset_healthy_fixture
    MOCK_BRIDGE_DETAILS='7: br0: <BROADCAST,MULTICAST> mtu 1500 state DOWN bridge forward_delay 1500'
    assert_fails_with "未处于 UP 状态" run_preflight
}

test_uplink_topology_and_carrier_failures() {
    reset_healthy_fixture
    MOCK_UPLINK_DETAILS='2: enp3s0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 state UP'
    assert_fails_with "未连接到 'br0'" run_preflight

    reset_healthy_fixture
    MOCK_UPLINK_DETAILS='2: enp3s0: <BROADCAST,MULTICAST,LOWER_UP> mtu 1500 master br0 state DOWN'
    assert_fails_with "未处于 UP 状态" run_preflight

    reset_healthy_fixture
    MOCK_UPLINK_DETAILS='2: enp3s0: <BROADCAST,MULTICAST,UP> mtu 1500 master br0 state DOWN'
    assert_fails_with "没有 LOWER_UP/carrier" run_preflight

    reset_healthy_fixture
    printf '0\n' >"$SYS_CLASS_NET/enp3s0/carrier"
    assert_fails_with "carrier 不可用" run_preflight
}

test_physical_uplink_contract() {
    reset_healthy_fixture
    rm -rf -- "$SYS_CLASS_NET/enp3s0/device"
    assert_fails_with "不是可验证的有线物理设备" run_preflight

    reset_healthy_fixture
    printf '32\n' >"$SYS_CLASS_NET/enp3s0/type"
    assert_fails_with "不是 Ethernet 接口" run_preflight

    reset_healthy_fixture
    mkdir "$SYS_CLASS_NET/enp3s0/wireless"
    assert_fails_with "不是可验证的有线物理设备" run_preflight
}

test_untrusted_or_unrelated_config_is_non_applicable() {
    reset_healthy_fixture
    MOCK_OWNER=1000
    MOCK_BRIDGE_DETAILS='this would fail if preflight were applicable'
    run_preflight || fail "非 root 配置不应扩大 fail-closed 范围"

    reset_healthy_fixture
    chmod 0666 "$CONFIG"
    MOCK_BRIDGE_DETAILS='this would fail if preflight were applicable'
    run_preflight || fail "可被普通用户写入的配置不应扩大 fail-closed 范围"

    reset_healthy_fixture
    write_valid_config "$CONFIG" br9 enp3s0
    MOCK_BRIDGE_DETAILS='this would fail if preflight were applicable'
    run_preflight || fail "其它 bridge 的配置不应约束 br0"

    reset_healthy_fixture
    rm -f -- "$CONFIG"
    MOCK_BRIDGE_DETAILS='this would fail if preflight were applicable'
    run_preflight || fail "配置缺失时应保持历史 isolated/bridge 语义"
}

test_native_tap_fallback_contract() {
    (
        INSTANCE=7
        BRIDGE=br0
        VLAN_ID=""
        sv_vlan_trusted_executable() { return 0; }
        vlan_tap_name() { [[ "$1" == "7" ]] && printf 'svtap7\n'; }
        sv_vlan_helper_call() {
            [[ "$*" == "check 7 1" ]] && printf 'svtap7\n'
        }

        sv_vlan_enable_native_bridge_fallback \
            || fail "受信任 VID 1 helper 未接管 capability 丢失场景"
        [[ "$VLAN_ID" == "1" && "$VLAN_TAP_IF" == "svtap7" \
            && "$SV_VLAN_NATIVE_FALLBACK" == "1" ]] \
            || fail "native TAP fallback 未提交完整运行态"
    )

    (
        INSTANCE=7
        BRIDGE=br9
        VLAN_ID=""
        sv_vlan_trusted_executable() { fail "非 br0 不应探测 VLAN helper"; }
        ! sv_vlan_enable_native_bridge_fallback
    ) || fail "非 br0 错误启用了 native TAP fallback"

    (
        INSTANCE=7
        BRIDGE=br0
        VLAN_ID=11
        sv_vlan_trusted_executable() { fail "显式 VLAN 不应进入普通 bridge fallback"; }
        ! sv_vlan_enable_native_bridge_fallback
    ) || fail "显式 VLAN 被普通 bridge fallback 覆盖"

    (
        INSTANCE=7
        BRIDGE=br0
        VLAN_ID=""
        sv_vlan_trusted_executable() { return 0; }
        vlan_tap_name() { printf 'svtap7\n'; }
        sv_vlan_helper_call() { printf 'svtap8\n'; }
        ! sv_vlan_enable_native_bridge_fallback
        [[ -z "$VLAN_ID" && -z "${VLAN_TAP_IF:-}" \
            && "$SV_VLAN_NATIVE_FALLBACK" == "0" ]]
    ) || fail "helper 返回错误 TAP 时仍污染了 fallback 状态"
}

test_launcher_integration_contract() {
    # shellcheck disable=SC2016 # 静态匹配生产脚本中的变量字面量，不在测试进程展开。
    grep -F -- 'source "$HERE/lib/sv-network-preflight.sh"' "$DEVICES" >/dev/null \
        || fail "sv-devices 未加载普通 bridge 预检库"
    # shellcheck disable=SC2016 # 固定路径与变量字面量共同构成启动器接线契约。
    grep -F -- '"$BRIDGE" "/etc/qemu/stealth-vlan.conf" "/sys/class/net" || exit 1' \
        "$DEVICES" >/dev/null || fail "sv-devices 未使用固定可信配置/sysfs 路径"
    # shellcheck disable=SC2016 # DRY_RUN 条件必须保持字面形式，防止意外访问宿主拓扑。
    grep -F -- '"${DRY_RUN:-0}" != "1"' "$DEVICES" >/dev/null \
        || fail "DRY_RUN 未明确跳过宿主运行态预检"
    grep -F -- 'sv_vlan_enable_native_bridge_fallback' "$DEVICES" >/dev/null \
        || fail "普通 bridge 未接入受信任 native TAP 恢复路径"
}

main() {
    [[ -f "$LIB" ]] || fail "缺少预检库: $LIB"
    [[ -f "$VLAN_LIB" ]] || fail "缺少 VLAN 预检库: $VLAN_LIB"
    # shellcheck disable=SC1090
    source "$LIB"
    # shellcheck disable=SC1090
    source "$VLAN_LIB"
    TEST_ROOT="$(mktemp -d)"
    SYS_CLASS_NET="$TEST_ROOT/sys/class/net"
    trap 'rm -rf -- "${TEST_ROOT:-}"' EXIT

    test_healthy_and_l2_only_contract
    test_bridge_failures
    test_uplink_topology_and_carrier_failures
    test_physical_uplink_contract
    test_untrusted_or_unrelated_config_is_non_applicable
    test_native_tap_fallback_contract
    test_launcher_integration_contract
    echo "PASS: 普通 bridge 可信物理上联启动前健康预检"
}

main "$@"
