#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317
# SC2034/SC2317: 子 shell 中的全局变量与同名函数是 setup_main 间接读取的 mock。
# ---------------------------------------------------------------------------
# 单 br0 VLAN trunk 的 NetworkManager 创建、幂等与回滚回归测试。
#
# 测试通过 Bash 函数替换 nmcli、ip 与 bridge，只验证命令序列和内存 profile，
# 不连接宿主 NetworkManager、不调用 sudo，也不会创建或迁移真实网络接口。
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SETUP_BRIDGE="$REPO_ROOT/deploy/scripts/setup-bridge.sh"

declare -A NM_TYPE=()
declare -A NM_DEVICE=()
declare -A NM_ACTIVE=()
declare -A NM_AUTOCONNECT=()
declare -A NM_AUTOCONNECT_PORTS=()
declare -A NM_MASTER=()
NM_LOG=""
NET_LOG=""
NM_FAIL_MATCH=""
NET_FAIL_MATCH=""

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_log_contains() {
    local file="$1"
    local needle="$2"
    local message="$3"

    grep -F -- "$needle" "$file" >/dev/null \
        || fail "$message（日志缺少: $needle）"
}

assert_log_not_contains() {
    local file="$1"
    local needle="$2"
    local message="$3"

    if grep -F -- "$needle" "$file" >/dev/null; then
        fail "$message（日志不应包含: $needle）"
    fi
}

assert_log_before() {
    local file="$1"
    local first="$2"
    local second="$3"
    local message="$4"
    local first_line second_line

    first_line="$(grep -nF -- "$first" "$file" | head -n1 | cut -d: -f1 || true)"
    second_line="$(grep -nF -- "$second" "$file" | head -n1 | cut -d: -f1 || true)"
    [[ "$first_line" =~ ^[0-9]+$ && "$second_line" =~ ^[0-9]+$ \
        && "$first_line" -lt "$second_line" ]] || fail "$message"
}

nm_reset() {
    NM_TYPE=()
    NM_DEVICE=()
    NM_ACTIVE=()
    NM_AUTOCONNECT=()
    NM_AUTOCONNECT_PORTS=()
    NM_MASTER=()
    NM_FAIL_MATCH=""
    NET_FAIL_MATCH=""
    : >"$NM_LOG"
    : >"$NET_LOG"
}

nm_seed() {
    local name="$1"
    local type="$2"
    local device="$3"
    local active="${4:-0}"

    NM_TYPE["$name"]="$type"
    NM_DEVICE["$name"]="$device"
    NM_AUTOCONNECT["$name"]="yes"
    if [[ "$active" == "1" ]]; then
        NM_ACTIVE["$name"]=1
    fi
}

log_argv() {
    local target="$1"
    shift

    {
        printf '%q' "$1"
        shift
        printf ' %q' "$@"
        printf '\n'
    } >>"$target"
}

# 只实现 setup_bridge_nm 会使用的 nmcli 子集。profile 保存于关联数组，使连续
# 两次调用能真实验证“首次创建、第二次复用”的幂等语义。
nmcli() {
    log_argv "$NM_LOG" nmcli "$@"

    # 故障注入只命中一次，使回滚阶段的 nmcli 可以正常恢复原 profile。
    if [[ -n "$NM_FAIL_MATCH" && " $* " == *" $NM_FAIL_MATCH "* ]]; then
        NM_FAIL_MATCH=""
        return 70
    fi

    if [[ "${1:-} ${2:-} ${3:-} ${4:-} ${5:-}" == "-t -f NAME connection show" ]]; then
        printf '%s\n' "${!NM_TYPE[@]}"
        return 0
    fi
    if [[ "${1:-} ${2:-} ${3:-} ${4:-} ${5:-} ${6:-}" \
        == "-t -f NAME,DEVICE connection show --active" ]]; then
        local active_name
        for active_name in "${!NM_ACTIVE[@]}"; do
            printf '%s:%s\n' "$active_name" "${NM_DEVICE[$active_name]}"
        done
        return 0
    fi
    if [[ "${1:-} ${2:-} ${3:-} ${4:-}" == "-g connection.autoconnect connection show" ]]; then
        printf '%s\n' "${NM_AUTOCONNECT[${5:-}]:-yes}"
        return 0
    fi

    case "${1:-} ${2:-}" in
        "connection add")
            shift 2
            local type="" name="" ifname="" master="" autoconnect="yes"
            local autoconnect_ports="0"
            while (( $# > 0 )); do
                case "$1" in
                    type) type="${2:-}"; shift 2 ;;
                    con-name) name="${2:-}"; shift 2 ;;
                    ifname) ifname="${2:-}"; shift 2 ;;
                    connection.master) master="${2:-}"; shift 2 ;;
                    connection.autoconnect-slaves)
                        autoconnect_ports="${2:-}"; shift 2 ;;
                    autoconnect) autoconnect="${2:-}"; shift 2 ;;
                    *)
                        # 生产命令的其余属性都是 key/value 对。
                        if (( $# >= 2 )); then shift 2; else shift; fi
                        ;;
                esac
            done
            [[ -n "$type" && -n "$name" && -n "$ifname" ]] || return 2
            nm_seed "$name" "$type" "$ifname"
            NM_AUTOCONNECT["$name"]="$autoconnect"
            NM_AUTOCONNECT_PORTS["$name"]="$autoconnect_ports"
            [[ -z "$master" ]] || NM_MASTER["$name"]="$master"
            ;;
        "connection modify")
            local modify_name="${3:-}"
            shift 3
            while (( $# >= 2 )); do
                if [[ "$1" == "connection.autoconnect" ]]; then
                    NM_AUTOCONNECT["$modify_name"]="$2"
                elif [[ "$1" == "connection.autoconnect-slaves" \
                    || "$1" == "connection.autoconnect-ports" ]]; then
                    NM_AUTOCONNECT_PORTS["$modify_name"]="$2"
                fi
                shift 2
            done
            ;;
        "connection down")
            local down_name="${3:-}"
            local port_name
            unset "NM_ACTIVE[$down_name]"
            for port_name in "${!NM_MASTER[@]}"; do
                [[ "${NM_MASTER[$port_name]}" != "$down_name" ]] \
                    || unset "NM_ACTIVE[$port_name]"
            done
            ;;
        "connection up")
            local up_name="${3:-}"
            local port_name
            [[ -n "${NM_TYPE[$up_name]:-}" ]] || return 10
            NM_ACTIVE["$up_name"]=1
            # connection.autoconnect-slaves=1 的真实语义：激活 controller 会
            # 一并激活其 port，脚本不应再从 port 反向触发第二份 master 激活。
            if [[ "${NM_AUTOCONNECT_PORTS[$up_name]:-0}" == "1" ]]; then
                for port_name in "${!NM_MASTER[@]}"; do
                    [[ "${NM_MASTER[$port_name]}" != "$up_name" ]] \
                        || NM_ACTIVE["$port_name"]=1
                done
            fi
            ;;
        "connection delete")
            local delete_name="${3:-}"
            unset "NM_TYPE[$delete_name]" "NM_DEVICE[$delete_name]" \
                "NM_ACTIVE[$delete_name]" "NM_AUTOCONNECT[$delete_name]" \
                "NM_AUTOCONNECT_PORTS[$delete_name]" "NM_MASTER[$delete_name]"
            ;;
        *) return 2 ;;
    esac
}

ip() {
    log_argv "$NET_LOG" ip "$@"
    if [[ -n "$NET_FAIL_MATCH" && " $* " == *" $NET_FAIL_MATCH "* ]]; then
        NET_FAIL_MATCH=""
        return 70
    fi
}

bridge() {
    log_argv "$NET_LOG" bridge "$@"
    if [[ -n "$NET_FAIL_MATCH" && " $* " == *" $NET_FAIL_MATCH "* ]]; then
        NET_FAIL_MATCH=""
        return 70
    fi
}

test_networkmanager_trunk_create_and_rerun() {
    local out="$1"

    nm_reset
    nm_seed netplan-enp5s0 ethernet enp5s0 1

    setup_bridge_nm br0 enp5s0 192.168.76.1/24 1 >"$out"
    [[ "${NM_TYPE[br0]:-}" == "bridge" ]] || fail "首次运行未创建 br0 profile"
    [[ "${NM_TYPE[br0-slave-enp5s0]:-}" == "bridge-slave" ]] \
        || fail "首次运行未创建上联 bridge-slave profile"
    assert_log_contains "$NM_LOG" \
        "connection modify br0 bridge.vlan-filtering yes bridge.vlan-default-pvid 1 bridge.vlan-protocol 802.1Q" \
        "trunk profile 未持久开启 VLAN filtering/default PVID"
    assert_log_contains "$NM_LOG" "connection down netplan-enp5s0" \
        "首次运行未释放冲突的 netplan 上联 profile"
    assert_log_before "$NM_LOG" \
        "connection modify netplan-enp5s0 connection.autoconnect no" \
        "connection down netplan-enp5s0" \
        "冲突 profile 未先禁止 autoconnect 就被停用，存在抢回物理口竞态"
    assert_log_contains "$NM_LOG" \
        "connection add type bridge-slave ifname enp5s0 connection.master br0 con-name br0-slave-enp5s0 autoconnect no" \
        "新 port profile 未在 controller 就绪前禁止抢先自启动"
    assert_log_contains "$NM_LOG" \
        "connection modify br0 connection.autoconnect yes connection.autoconnect-slaves 1 ipv4.method auto ipv4.addresses ''" \
        "bridge 激活前未明确启用 controller 自动 ports"
    assert_log_before "$NM_LOG" \
        "connection modify br0 connection.autoconnect yes connection.autoconnect-slaves 1" \
        "connection up br0" \
        "controller 自动 ports 属性没有在激活 br0 前生效"
    assert_log_not_contains "$NM_LOG" "connection up br0-slave-enp5s0" \
        "不应从 port 反向激活 bridge 并触发重复 activation"
    [[ "${NM_AUTOCONNECT[br0-slave-enp5s0]:-}" == "no" ]] \
        || fail "bridge port 未保持 controller-only autoconnect=no"
    [[ "${NM_ACTIVE[br0]:-}" == "1" \
        && "${NM_ACTIVE[br0-slave-enp5s0]:-}" == "1" ]] \
        || fail "controller 激活后未一并激活 bridge port"
    assert_log_contains "$NET_LOG" \
        "ip link set dev br0 type bridge vlan_filtering 1 vlan_default_pvid 1 vlan_protocol 802.1Q" \
        "trunk 运行态未开启 bridge VLAN filtering"
    assert_log_contains "$NET_LOG" \
        "bridge vlan add dev enp5s0 vid 1 pvid untagged" \
        "物理上联未保留原无 VLAN native LAN"
    assert_log_contains "$NET_LOG" \
        "bridge vlan add dev br0 vid 1 pvid untagged self" \
        "br0 self 未保留宿主 native LAN"

    # 第二次调用保留内存 profile，只清空日志。不得重复 add，也不能把自己的
    # bridge-slave 当作冲突 profile 停用。
    : >"$NM_LOG"
    : >"$NET_LOG"
    setup_bridge_nm br0 enp5s0 192.168.76.1/24 1 >"$out"
    assert_log_not_contains "$NM_LOG" "connection add" "幂等重跑重复创建 NM profile"
    assert_log_not_contains "$NM_LOG" "connection down br0-slave-enp5s0" \
        "幂等重跑误停用了自身上联 profile"
    assert_log_not_contains "$NM_LOG" "connection up br0-slave-enp5s0" \
        "幂等重跑不应单独激活上联 port"
    [[ "${NM_AUTOCONNECT[br0-slave-enp5s0]:-}" == "no" ]] \
        || fail "幂等重跑把 bridge port 改回了独立 autoconnect"
    assert_log_contains "$NM_LOG" "connection up br0" \
        "幂等重跑未重新确认 bridge profile"
    [[ "${NM_ACTIVE[br0-slave-enp5s0]:-}" == "1" ]] \
        || fail "幂等重跑后 controller 未恢复上联 port"
}

test_networkmanager_failure_restores_uplink() {
    local out="$1"
    local rc

    nm_reset
    nm_seed netplan-enp5s0 ethernet enp5s0 1
    # 使用 no 验证回滚恢复的是原值，而不是无条件改回 yes。
    NM_AUTOCONNECT[netplan-enp5s0]="no"
    NM_FAIL_MATCH="connection up br0"

    set +e
    setup_bridge_nm br0 enp5s0 192.168.76.1/24 1 >"$out" 2>&1
    rc=$?
    set -e

    (( rc != 0 )) || fail "bridge 激活故障未传递失败状态"
    [[ "${NM_ACTIVE[netplan-enp5s0]:-}" == "1" ]] \
        || fail "NM 迁移失败后未恢复原 active 上联 profile"
    [[ "${NM_AUTOCONNECT[netplan-enp5s0]:-}" == "no" ]] \
        || fail "NM 迁移失败后未恢复原 autoconnect 值"
    [[ -z "${NM_TYPE[br0-slave-enp5s0]:-}" ]] \
        || fail "NM 迁移失败后遗留了本次新建的 bridge-slave"
    [[ "$(grep -Fc -- \
        "connection modify netplan-enp5s0 connection.autoconnect no" "$NM_LOG")" == "2" ]] \
        || fail "NM 回滚未精确写回原 autoconnect=no"
    assert_log_contains "$NM_LOG" "connection up netplan-enp5s0" \
        "NM 回滚未重新激活原上联 profile"
    assert_log_contains "$NM_LOG" "connection delete br0-slave-enp5s0" \
        "NM 回滚未删除本次新建的 bridge-slave"
}

test_networkmanager_runtime_failure_stops_bridge_before_restore() {
    local out="$1"
    local rc

    nm_reset
    nm_seed netplan-enp3s0 ethernet enp3s0 1
    NET_FAIL_MATCH="vlan add dev enp3s0 vid 1 pvid untagged"

    set +e
    setup_bridge_nm br0 enp3s0 192.168.76.1/24 1 >"$out" 2>&1
    rc=$?
    set -e

    (( rc != 0 )) || fail "VLAN 运行态故障未传递失败状态"
    [[ -z "${NM_ACTIVE[br0]:-}" ]] \
        || fail "controller 激活后的故障回滚仍遗留 active br0"
    [[ -z "${NM_TYPE[br0-slave-enp3s0]:-}" ]] \
        || fail "运行态故障回滚未删除本次新建 port"
    [[ "${NM_ACTIVE[netplan-enp3s0]:-}" == "1" \
        && "${NM_AUTOCONNECT[netplan-enp3s0]:-}" == "yes" ]] \
        || fail "运行态故障回滚未恢复原物理口 profile"
    [[ "$(grep -Fc -- "connection down br0" "$NM_LOG")" == "2" ]] \
        || fail "controller 激活后失败时未再次 down br0 清除 DHCP/linkdown 路由"
    assert_log_contains "$NM_LOG" "connection delete br0-slave-enp3s0" \
        "运行态故障回滚未删除新 port"
}

test_plain_bridge_does_not_enable_vlan_filtering() {
    local out="$1"

    nm_reset
    setup_bridge_nm br-test "" 192.168.76.1/24 0 >"$out"
    [[ "${NM_TYPE[br-test]:-}" == "bridge" ]] || fail "普通模式未创建 bridge"
    assert_log_not_contains "$NM_LOG" "bridge.vlan-filtering" \
        "无 VLAN_TRUNK 时不应修改历史 bridge VLAN 属性"
    [[ ! -s "$NET_LOG" ]] || fail "普通隔离 bridge 不应调用运行态 VLAN 命令"
}

main() {
    local out

    [[ -f "$SETUP_BRIDGE" ]] || fail "缺少 setup 脚本: $SETUP_BRIDGE"
    # setup 脚本通过 BASH_SOURCE 守卫，source 只注册函数，不执行宿主操作。
    # shellcheck disable=SC1090,SC1091
    source "$SETUP_BRIDGE"

    NM_LOG="$(mktemp)"
    NET_LOG="$(mktemp)"
    out="$(mktemp)"
    trap 'rm -f "${NM_LOG:-}" "${NET_LOG:-}" "${out:-}"' EXIT

    test_networkmanager_trunk_create_and_rerun "$out"
    test_networkmanager_failure_restores_uplink "$out"
    test_networkmanager_runtime_failure_stops_bridge_before_restore "$out"
    test_plain_bridge_does_not_enable_vlan_filtering "$out"
    echo "PASS: single-br0 VLAN trunk NetworkManager runtime contract"
}

main "$@"
