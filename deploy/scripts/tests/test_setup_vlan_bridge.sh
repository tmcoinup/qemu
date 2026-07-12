#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317
# SC2034/SC2317: 子 shell 中的全局变量与同名函数是 setup_main 间接读取的 mock。
# ---------------------------------------------------------------------------
# 单 br0 VLAN trunk 的 NetworkManager/安装静态回归测试。
#
# 测试通过 Bash 函数替换 nmcli、ip 与 bridge，只验证命令序列和内存 profile，
# 不连接宿主 NetworkManager、不调用 sudo，也不会创建或迁移真实网络接口。
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SETUP_BRIDGE="$REPO_ROOT/deploy/scripts/setup-bridge.sh"
OBSOLETE_LIB="$REPO_ROOT/deploy/scripts/lib/setup-vlan-bridge.sh"
RUNTIME_LIB="$REPO_ROOT/deploy/scripts/lib/setup-bridge-runtime.sh"

declare -A NM_TYPE=()
declare -A NM_DEVICE=()
declare -A NM_ACTIVE=()
declare -A NM_AUTOCONNECT=()
NM_LOG=""
NET_LOG=""
NM_FAIL_MATCH=""

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

nm_reset() {
    NM_TYPE=()
    NM_DEVICE=()
    NM_ACTIVE=()
    NM_AUTOCONNECT=()
    NM_FAIL_MATCH=""
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
            local type="" name="" ifname=""
            while (( $# > 0 )); do
                case "$1" in
                    type) type="${2:-}"; shift 2 ;;
                    con-name) name="${2:-}"; shift 2 ;;
                    ifname) ifname="${2:-}"; shift 2 ;;
                    *)
                        # 生产命令的其余属性都是 key/value 对。
                        if (( $# >= 2 )); then shift 2; else shift; fi
                        ;;
                esac
            done
            [[ -n "$type" && -n "$name" && -n "$ifname" ]] || return 2
            nm_seed "$name" "$type" "$ifname"
            ;;
        "connection modify")
            local modify_name="${3:-}"
            shift 3
            while (( $# >= 2 )); do
                if [[ "$1" == "connection.autoconnect" ]]; then
                    NM_AUTOCONNECT["$modify_name"]="$2"
                fi
                shift 2
            done
            ;;
        "connection down")
            local down_name="${3:-}"
            unset "NM_ACTIVE[$down_name]"
            ;;
        "connection up")
            [[ -n "${NM_TYPE[${3:-}]:-}" ]] || return 10
            NM_ACTIVE["${3:-}"]=1
            ;;
        "connection delete")
            local delete_name="${3:-}"
            unset "NM_TYPE[$delete_name]" "NM_DEVICE[$delete_name]" \
                "NM_ACTIVE[$delete_name]" "NM_AUTOCONNECT[$delete_name]"
            ;;
        *) return 2 ;;
    esac
}

ip() {
    log_argv "$NET_LOG" ip "$@"
}

bridge() {
    log_argv "$NET_LOG" bridge "$@"
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
    assert_log_contains "$NM_LOG" "connection up br0-slave-enp5s0" \
        "幂等重跑未重新确认上联 profile"
    assert_log_contains "$NM_LOG" "connection up br0" \
        "幂等重跑未重新确认 bridge profile"
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

test_plain_bridge_does_not_enable_vlan_filtering() {
    local out="$1"

    nm_reset
    setup_bridge_nm br-test "" 192.168.76.1/24 0 >"$out"
    [[ "${NM_TYPE[br-test]:-}" == "bridge" ]] || fail "普通模式未创建 bridge"
    assert_log_not_contains "$NM_LOG" "bridge.vlan-filtering" \
        "无 VLAN_TRUNK 时不应修改历史 bridge VLAN 属性"
    [[ ! -s "$NET_LOG" ]] || fail "普通隔离 bridge 不应调用运行态 VLAN 命令"
}

test_obsolete_arguments_fail_before_root() {
    local out="$1"
    local rc

    set +e
    VLAN_ID=11 bash "$SETUP_BRIDGE" >"$out" 2>&1
    rc=$?
    set -e
    [[ "$rc" == "2" ]] || fail "旧 VLAN_ID 未以参数错误退出（rc=$rc）"
    grep -F -- "VLAN_ID/VLAN_IF 已废弃" "$out" >/dev/null \
        || fail "旧 VLAN_ID 错误没有迁移提示"

    set +e
    VLAN_IF=enp5s0.11 bash "$SETUP_BRIDGE" >"$out" 2>&1
    rc=$?
    set -e
    [[ "$rc" == "2" ]] || fail "旧 VLAN_IF 未以参数错误退出（rc=$rc）"

    set +e
    VLAN_TRUNK=1 BR=br9 UPLINK=enp5s0 bash "$SETUP_BRIDGE" >"$out" 2>&1
    rc=$?
    set -e
    [[ "$rc" == "2" ]] || fail "trunk 非 br0 未被拒绝（rc=$rc）"
    grep -F -- "固定使用单一 br0" "$out" >/dev/null \
        || fail "trunk bridge 冲突未给出单 br0 说明"

    set +e
    VLAN_TRUNK=1 bash "$SETUP_BRIDGE" >"$out" 2>&1
    rc=$?
    set -e
    [[ "$rc" == "2" ]] || fail "trunk 缺少 UPLINK 未被拒绝（rc=$rc）"
}

test_installer_contract_is_static_and_root_owned() {
    [[ ! -e "$OBSOLETE_LIB" ]] || fail "旧 per-VLAN bridge 库仍然存在"

    assert_log_contains "$SETUP_BRIDGE" \
        "readonly VLAN_TAP_SOURCE=\"\$HERE/host-vlan-tap.sh\"" \
        "setup 未固定 TAP helper 仓库源路径"
    assert_log_contains "$SETUP_BRIDGE" \
        'readonly VLAN_TAP_INSTALLED="/usr/local/libexec/qemu-stealth-vlan-tap"' \
        "setup 未固定 root-owned TAP helper 安装路径"
    assert_log_contains "$SETUP_BRIDGE" \
        'readonly VLAN_DOWN_INSTALLED="/usr/local/libexec/qemu-stealth-vlan-down"' \
        "setup 未固定 downscript 安装路径"
    assert_log_contains "$SETUP_BRIDGE" \
        'readonly VLAN_CONFIG="/etc/qemu/stealth-vlan.conf"' \
        "setup 未固定 root 配置路径"
    assert_log_contains "$SETUP_BRIDGE" \
        'NOPASSWD:NOSETENV' "sudoers 未明确禁止用户注入环境变量"
    assert_log_contains "$SETUP_BRIDGE" \
        "install -o root -g root -m 0755 \"\$VLAN_TAP_SOURCE\" \"\$VLAN_TAP_INSTALLED\"" \
        "TAP helper 未安装为 root-owned 副本"
    assert_log_not_contains "$SETUP_BRIDGE" "source \"\$HERE/lib/setup-vlan-bridge.sh\"" \
        "setup 仍引用已废弃 per-VLAN 库"
    assert_log_not_contains "$SETUP_BRIDGE" 'type vlan id' \
        "setup 不应再创建 VLAN 子接口"
}

test_allowed_identity_resolution() {
    local current_user
    local current_uid
    local current_gid

    current_user="$(id -un)"
    current_uid="$(id -u)"
    current_gid="$(id -g)"

    VM_USER="$current_user" SUDO_UID=9998 SUDO_GID=9999 \
        setup_resolve_allowed_identity
    [[ "$ALLOWED_UID_VALUE" == "$current_uid" \
        && "$ALLOWED_GID_VALUE" == "$current_gid" ]] \
        || fail "VM_USER 未覆盖 sudo 调用身份"

    VM_USER="" SUDO_UID=2345 SUDO_GID=2346 SUDO_USER=test-caller \
        setup_resolve_allowed_identity
    [[ "$ALLOWED_UID_VALUE" == "2345" && "$ALLOWED_GID_VALUE" == "2346" ]] \
        || fail "未优先采用有效 SUDO_UID/SUDO_GID"

    if VM_USER="" SUDO_UID="" SUDO_GID="" SUDO_USER=root \
        setup_resolve_allowed_identity >/dev/null 2>&1; then
        fail "直接 root 且无 VM_USER 时不应静默授权 UID 0"
    fi
}

test_missing_assets_fail_before_root_or_network() {
    local temp_dir
    local out
    local rc

    temp_dir="$(mktemp -d)"
    out="$(mktemp)"
    mkdir -p "$temp_dir/lib"
    cp "$SETUP_BRIDGE" "$temp_dir/setup-bridge.sh"
    cp "$RUNTIME_LIB" "$temp_dir/lib/setup-bridge-runtime.sh"
    chmod 0755 "$temp_dir/setup-bridge.sh"

    # 临时目录故意不放两个 helper 源。测试以普通用户执行，因此若检查顺序错误，
    # 会先报“需要 root”；正确实现应更早报告缺少固定源文件，且没有任何宿主写入。
    set +e
    VLAN_TRUNK=1 UPLINK=enp5s0 VM_USER="$(id -un)" \
        bash "$temp_dir/setup-bridge.sh" >"$out" 2>&1
    rc=$?
    set -e
    rm -rf "$temp_dir"

    [[ "$rc" == "1" ]] || fail "缺少 trunk helper 时退出码错误（rc=$rc）"
    grep -F -- "缺少 VLAN TAP helper 源文件" "$out" >/dev/null \
        || fail "trunk helper 缺失没有在 root/网络操作前 fail-fast"
    rm -f "$out"
}

test_numeric_sudoers_is_valid() {
    local sudoers

    command -v visudo >/dev/null 2>&1 || fail "测试环境缺少 visudo"
    sudoers="$(mktemp)"
    printf '#%s ALL=(root) NOPASSWD:NOSETENV: %s\n' \
        "$(id -u)" "/usr/local/libexec/qemu-stealth-vlan-tap" >"$sudoers"
    chmod 0440 "$sudoers"
    visudo -cf "$sudoers" >/dev/null \
        || fail "数字 #uid + NOPASSWD:NOSETENV sudoers 语法无效"
    rm -f "$sudoers"
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
    test_plain_bridge_does_not_enable_vlan_filtering "$out"
    test_obsolete_arguments_fail_before_root "$out"
    test_installer_contract_is_static_and_root_owned
    test_allowed_identity_resolution
    test_missing_assets_fail_before_root_or_network
    test_numeric_sudoers_is_valid
    echo "PASS: single-br0 VLAN trunk NetworkManager/install contract"
}

main "$@"
