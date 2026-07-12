#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 单 br0 VLAN trunk 的 iproute2 隔离集成测试。
#
# 测试在一次性 user/network namespace 中创建 dummy 上联和真实 Linux bridge，
# 验证首建、幂等重跑、native VID 1 与普通无 trunk 分支。namespace 退出后所有
# 接口自动销毁，绝不读取或修改宿主真实网络。
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SETUP_BRIDGE="$REPO_ROOT/deploy/scripts/setup-bridge.sh"

[[ -f "$SETUP_BRIDGE" ]] || {
    echo "FAIL: 缺少 setup 脚本: $SETUP_BRIDGE" >&2
    exit 1
}

if ! command -v unshare >/dev/null 2>&1 || ! unshare -Urn true 2>/dev/null; then
    echo "SKIP: 当前内核未开放非特权 user/network namespace"
    exit 0
fi

# 单引号内容由 namespace 内 Bash 展开，外层只通过 $1 传入已验证的脚本路径。
# shellcheck disable=SC2016
unshare -Urn bash -euo pipefail -c '
    setup_script="$1"
    # shellcheck disable=SC1090,SC1091
    source "$setup_script"

    fail() {
        echo "FAIL: $*" >&2
        exit 1
    }

    assert_native_vlan() {
        local device="$1"
        local output

        output="$(bridge vlan show dev "$device" vid 1)"
        grep -F -- "1 PVID Egress Untagged" <<<"$output" >/dev/null \
            || fail "$device 缺少 VID 1 PVID/untagged"
    }

    ip link add enp5s0 type dummy
    ip address add 198.51.100.2/24 dev enp5s0
    ip link set dev enp5s0 up

    # 连续运行两次：第二次必须复用 br0 和 master 关系，bridge vlan add 也必须
    # 保持幂等，不能生成任何 enp5s0.<VID> 子接口或额外 bridge。
    setup_bridge_iproute br0 enp5s0 192.168.76.1/24 1 >/dev/null
    setup_bridge_iproute br0 enp5s0 192.168.76.1/24 1 >/dev/null

    bridge_info="$(ip -d -o link show dev br0)"
    grep -Eq "bridge[[:space:]].*vlan_filtering[[:space:]]+1" <<<"$bridge_info" \
        || fail "br0 未开启 vlan_filtering"
    grep -Eq "vlan_protocol[[:space:]]+802\.1Q" <<<"$bridge_info" \
        || fail "br0 VLAN protocol 不是 802.1Q"
    grep -Eq "vlan_default_pvid[[:space:]]+1" <<<"$bridge_info" \
        || fail "br0 default PVID 不是 1"
    ip -o link show dev enp5s0 | grep -Eq "master[[:space:]]+br0" \
        || fail "上联未加入 br0"
    ip -4 -o address show dev br0 | awk "{ print \$4 }" \
        | grep -Fqx -- 198.51.100.2/24 \
        || fail "上联 IPv4 地址未按旧 fallback 语义迁移到 br0"
    assert_native_vlan enp5s0
    assert_native_vlan br0

    # 既有非 VID1 native 配置必须 fail closed，不能被 setup 静默夺走 PVID。
    bridge vlan del dev enp5s0 vid 1
    bridge vlan add dev enp5s0 vid 100 pvid untagged
    if setup_enable_vlan_runtime br0 enp5s0 >/dev/null 2>&1; then
        fail "setup 接受并改写了既有 VID100 native VLAN"
    fi
    bridge vlan show dev enp5s0 | grep -F -- "100 PVID Egress Untagged" >/dev/null \
        || fail "setup 失败后破坏了原 VID100 native flags"
    bridge vlan del dev enp5s0 vid 100
    bridge vlan add dev enp5s0 vid 1 pvid untagged

    if ip -o link show | grep -Eq "enp5s0\.[0-9]+"; then
        fail "单 br0 模式错误创建了 per-VLAN 子接口"
    fi
    bridge link show | grep -F -- "master br-vlan" >/dev/null \
        && fail "单 br0 模式错误创建了 per-VLAN bridge"

    # 普通无 trunk 模式仍可创建独立 bridge，且不应自动打开 VLAN filtering。
    setup_bridge_iproute br-test "" 192.0.2.1/24 0 >/dev/null
    plain_info="$(ip -d -o link show dev br-test)"
    grep -Eq "bridge[[:space:]].*vlan_filtering[[:space:]]+0" <<<"$plain_info" \
        || fail "普通 bridge 的 vlan_filtering 历史默认值被改变"
    ip -4 -o address show dev br-test | awk "{ print \$4 }" \
        | grep -Fqx -- 192.0.2.1/24 \
        || fail "普通隔离 bridge 未配置 HOST_IP"

    # 同名非 bridge 接口必须 fail-fast，且不得被删除或替换。
    ip link add br-conflict type dummy
    if setup_bridge_iproute br-conflict "" 192.0.2.2/24 0 >/dev/null 2>&1; then
        fail "同名非 bridge 接口冲突未被拒绝"
    fi
    ip -d -o link show dev br-conflict | grep -F -- "dummy" >/dev/null \
        || fail "冲突接口被破坏"

    # 注入 bridge 地址新增失败；迁移必须在删除 uplink 原地址之前停止。
    ip link add enp6s0 type dummy
    ip address add 203.0.113.2/24 dev enp6s0
    ip link set dev enp6s0 up
    real_ip="$(command -v ip)"
    migration_delete_seen=0
    ip() {
        if [[ "${1:-} ${2:-} ${4:-} ${5:-}" == "address del dev enp6s0" ]]; then
            migration_delete_seen=1
        fi
        if [[ "${1:-} ${2:-} ${4:-} ${5:-}" == "address add dev br-fail" ]]; then
            return 70
        fi
        "$real_ip" "$@"
    }

    if setup_bridge_iproute br-fail enp6s0 192.0.2.3/24 0 >/dev/null 2>&1; then
        fail "iproute 地址新增故障未传递失败状态"
    fi
    [[ "$migration_delete_seen" == "0" ]] \
        || fail "iproute 迁移在 bridge 地址新增成功前删除了原地址"
    ip -4 -o address show dev enp6s0 | awk "{ print \$4 }" \
        | grep -Fqx -- 203.0.113.2/24 \
        || fail "iproute 迁移失败后 uplink 原地址丢失"
    if ip -4 -o address show dev br-fail | awk "{ print \$4 }" \
        | grep -Fqx -- 203.0.113.2/24; then
        fail "iproute 迁移失败后 bridge 遗留地址"
    fi
' bash "$SETUP_BRIDGE"

echo "PASS: single-br0 VLAN trunk iproute2 create/idempotency/native VLAN"
