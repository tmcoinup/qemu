#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317
# SC2034/SC2317: 子 shell 中的全局变量与同名函数是 setup 主流程间接读取的 mock。
# ---------------------------------------------------------------------------
# 单 br0 VLAN trunk 的上联探测、参数校验与 root-owned 安装契约回归。
#
# 测试只 source 函数或在缺少资产时执行 fail-fast 路径，不连接宿主
# NetworkManager、不调用 sudo，也不会创建或迁移真实网络接口。
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SETUP_BRIDGE="$REPO_ROOT/deploy/scripts/setup-bridge.sh"
OBSOLETE_LIB="$REPO_ROOT/deploy/scripts/lib/setup-vlan-bridge.sh"
RUNTIME_LIB="$REPO_ROOT/deploy/scripts/lib/setup-bridge-runtime.sh"
UPLINK_LIB="$REPO_ROOT/deploy/scripts/lib/uplink-detect.sh"

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

test_uplink_detection_and_validation() {
    local actual out rc sys_root

    # 现场残留状态会同时有真实物理默认路由和 br0 linkdown 路由；物理过滤后
    # 仍应唯一选择 enp3s0，并对同一接口的多条 route 去重。
    actual="$(
        ip() {
            case "$*" in
                "-4 route show default")
                    printf '%s\n' \
                        "default via 192.0.2.1 dev enp3s0 metric 100" \
                        "default via 192.0.2.1 dev enp3s0 metric 200" \
                        "default via 192.0.2.1 dev br0 metric 300 linkdown"
                    ;;
                "-6 route show default"|"-o link show master br0") ;;
                *) return 1 ;;
            esac
        }
        is_physical() { [[ "${1:-}" == "enp3s0" ]]; }
        uplink_detect_from_topology is_physical br0 /nonexistent
    )" || fail "未从唯一物理默认路由识别 enp3s0"
    [[ "$actual" == "enp3s0" ]] || fail "默认路由上联识别错误: '$actual'"

    # bridge 已成功迁移后的默认路由位于 br0；重跑需从唯一 port 反查物理口。
    actual="$(
        ip() {
            case "$*" in
                "-4 route show default") echo "default via 192.0.2.1 dev br0" ;;
                "-6 route show default") ;;
                "-o link show master br0")
                    echo "2: enp3s0: <BROADCAST,UP> mtu 1500 master br0 state UP"
                    ;;
                *) return 1 ;;
            esac
        }
        is_physical() { [[ "${1:-}" == "enp3s0" ]]; }
        uplink_detect_from_topology is_physical br0 /nonexistent
    )" || fail "未从 br0 的唯一物理 port 反查上联"
    [[ "$actual" == "enp3s0" ]] || fail "br0 port 上联识别错误: '$actual'"

    # 双有线默认路由必须 fail closed，不能按接口名或 metric 猜测。
    if (
        ip() {
            case "$*" in
                "-4 route show default")
                    printf '%s\n' \
                        "default via 192.0.2.1 dev enp3s0 metric 100" \
                        "default via 198.51.100.1 dev eno1 metric 200"
                    ;;
                "-6 route show default"|"-o link show master br0") ;;
                *) return 1 ;;
            esac
        }
        is_physical() {
            [[ "${1:-}" == "enp3s0" || "${1:-}" == "eno1" ]]
        }
        uplink_detect_from_topology is_physical br0 /nonexistent
    ); then
        fail "多个物理默认路由时仍猜测了 UPLINK"
    fi

    # 即使内核还留着物理默认路由，carrier-down 也不能作为破坏性迁移目标；
    # 非 Ethernet 的物理 netdev 同样必须拒绝自动接管。
    sys_root="$(mktemp -d)"
    mkdir -p "$sys_root/enp9s0/device"
    printf '%s\n' 1 >"$sys_root/enp9s0/type"
    printf '%s\n' 0 >"$sys_root/enp9s0/carrier"
    if (
        ip() { echo "2: enp9s0: <BROADCAST> mtu 1500 state DOWN"; }
        setup_uplink_candidate_is_physical enp9s0 br0 "$sys_root"
    ); then
        fail "carrier-down 物理默认路由仍被接受为自动上联"
    fi
    printf '%s\n' 32 >"$sys_root/enp9s0/type"
    printf '%s\n' 1 >"$sys_root/enp9s0/carrier"
    if (
        ip() { echo "2: enp9s0: <BROADCAST,UP> mtu 1500 state UP"; }
        setup_uplink_candidate_is_physical enp9s0 br0 "$sys_root"
    ); then
        fail "非 ARPHRD_ETHER 物理接口仍被接受为自动上联"
    fi
    printf '%s\n' 1 >"$sys_root/enp9s0/type"
    (
        ip() { echo "2: enp9s0: <BROADCAST,UP> mtu 1500 state UP"; }
        setup_uplink_candidate_is_physical enp9s0 br0 "$sys_root"
    ) || fail "carrier-up Ethernet 物理接口被错误拒绝"
    rm -rf "$sys_root"

    out="$(mktemp)"
    (
        VLAN_TRUNK=1
        VLAN_SETUP_AUTO=0
        UPLINK=""
        BR=br0
        HOST_IP=192.168.76.1/24
        uplink_detect_from_topology() { echo enp3s0; }
        setup_validate_inputs
        [[ "$UPLINK" == "enp3s0" ]]
    ) >"$out" || fail "trunk 未采用自动识别的 UPLINK"
    grep -F -- ">> auto-detected uplink: enp3s0" "$out" >/dev/null \
        || fail "自动识别 UPLINK 时没有明确提示"

    # VLAN_TRUNK 省略时默认开启并自动探测；显式值仍优先。
    (
        unset VLAN_TRUNK
        UPLINK=""
        BR=br0
        uplink_detect_from_topology() { echo eno1; }
        setup_validate_inputs
        [[ "$VLAN_TRUNK" == "1" && "$UPLINK" == "eno1" ]]
    ) >/dev/null || fail "省略 VLAN_TRUNK 时没有默认启用 trunk/自动上联"
    (
        VLAN_TRUNK=1
        UPLINK=enp3s0
        BR=br0
        uplink_detect_from_topology() { return 90; }
        setup_validate_inputs
        [[ "$UPLINK" == "enp3s0" ]]
    ) || fail "显式 UPLINK 未覆盖自动探测"

    # 只有显式 VLAN_TRUNK=0 才保留普通 isolated bridge。
    (
        VLAN_TRUNK=0
        UPLINK=""
        BR=br-test
        uplink_detect_from_topology() { return 90; }
        setup_validate_inputs
        [[ -z "$UPLINK" ]]
    ) || fail "普通空 UPLINK 不再保持 isolated bridge"

    set +e
    (
        VLAN_TRUNK=1
        UPLINK=""
        BR=br0
        uplink_detect_from_topology() { return 1; }
        setup_validate_inputs
    ) >"$out" 2>&1
    rc=$?
    set -e
    [[ "$rc" == "2" ]] || fail "无法唯一探测 UPLINK 时退出码错误（rc=$rc）"
    grep -F -- "请显式设置 UPLINK=<网卡>" "$out" >/dev/null \
        || fail "UPLINK 歧义时没有可操作提示"
    rm -f "$out"
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
    cp "$UPLINK_LIB" "$temp_dir/lib/uplink-detect.sh"
    chmod 0755 "$temp_dir/setup-bridge.sh"

    # 临时目录故意不放两个 helper 源。测试以普通用户执行，因此若检查顺序错误，
    # 会先报“需要 root”；正确实现应更早报告缺少固定源文件，且没有任何宿主写入。
    set +e
    UPLINK=enp5s0 VM_USER="$(id -un)" \
        bash "$temp_dir/setup-bridge.sh" >"$out" 2>&1
    rc=$?
    set -e
    rm -rf "$temp_dir"

    [[ "$rc" == "1" ]] || fail "默认 trunk 缺少 helper 时退出码错误（rc=$rc）"
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

    out="$(mktemp)"
    trap 'rm -f "${out:-}"' EXIT

    test_uplink_detection_and_validation
    test_obsolete_arguments_fail_before_root "$out"
    test_installer_contract_is_static_and_root_owned
    test_allowed_identity_resolution
    test_missing_assets_fail_before_root_or_network
    test_numeric_sudoers_is_valid
    echo "PASS: single-br0 VLAN trunk uplink/install contract"
}

main "$@"
