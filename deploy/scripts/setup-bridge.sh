#!/bin/bash
# ---------------------------------------------------------------------------
# setup-bridge.sh
#
# 宿主侧一次性 bridge 初始化脚本。默认把唯一的 br0 配成 VLAN-aware bridge，并
# 安装普通用户启动 VM 所需的受限 TAP helper；显式 VLAN_TRUNK=0 才保留历史普通
# bridge 行为。两条路径都只在宿主执行，Windows/Linux 客机无差异。
#
# 常用命令：
#   sudo deploy/scripts/setup-bridge.sh
#   sudo UPLINK=enp3s0 deploy/scripts/setup-bridge.sh
#   sudo VLAN_TRUNK=0 UPLINK=enp3s0 deploy/scripts/setup-bridge.sh
#
# 环境变量：
#   BR=br0              普通模式可覆盖 bridge 名；trunk 模式固定只能为 br0。
#   UPLINK=enp3s0       要接入 bridge 的物理上联；trunk 模式缺省时安全自动探测。
#   HOST_IP=...         无上联时 bridge 的宿主地址，默认 192.168.76.1/24。
#   VLAN_TRUNK=0|1      1 = 单 br0 动态 access VLAN 模式（默认）；0 = 旧普通模式。
#   VM_USER=<用户名>    允许启动 VLAN VM 的普通用户；sudo 调用时默认原调用者。
#
# 旧 VLAN_ID/VLAN_IF 已被移除。每个 VID 不再创建 br-vlanN/VLAN 子接口；新 VID
# 由 start-vm.sh 在启动时交给 root-owned TAP helper 动态加入同一个 br0。
# ---------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091  # 运行时按 setup 自身目录加载，支持仓库整体迁移。
source "$HERE/lib/setup-bridge-runtime.sh"
# 安全边界使用固定路径，不能接受环境变量覆盖。sudoers 永远只授权安装后的
# root-owned helper，绝不能直接授权普通用户可写的仓库脚本。
readonly VLAN_TAP_SOURCE="$HERE/host-vlan-tap.sh"
readonly VLAN_DOWN_SOURCE="$HERE/host-vlan-down.sh"
readonly VLAN_TAP_INSTALLED="/usr/local/libexec/qemu-stealth-vlan-tap"
readonly VLAN_DOWN_INSTALLED="/usr/local/libexec/qemu-stealth-vlan-down"
readonly VLAN_CONFIG="/etc/qemu/stealth-vlan.conf"
readonly VLAN_SUDOERS="/etc/sudoers.d/qemu-stealth-vlan"
readonly NETWORK_LOCK="/run/qemu-stealth-network.lock"

# trunk 模式缺少 helper 时必须在 apt、配置文件或宿主网络发生任何变化前退出。
setup_require_vlan_assets() {
    [[ "$VLAN_TRUNK" == "1" ]] || return 0

    [[ -f "$VLAN_TAP_SOURCE" && ! -L "$VLAN_TAP_SOURCE" ]] || {
        setup_error "缺少 VLAN TAP helper 源文件: $VLAN_TAP_SOURCE"
        return 1
    }
    [[ -f "$VLAN_DOWN_SOURCE" && ! -L "$VLAN_DOWN_SOURCE" ]] || {
        setup_error "缺少 VLAN downscript 源文件: $VLAN_DOWN_SOURCE"
        return 1
    }
}
setup_require_root_and_lock() {
    if [[ "$(id -u)" -ne 0 ]]; then
        setup_error "必须以 root 运行（请使用 sudo）。"
        return 1
    fi

    # bridge ACL、NetworkManager profile 和 sudoers 都是全局状态；一把锁串行化
    # 所有 setup 实例，避免并行首次安装互相覆盖。
    exec 9>"$NETWORK_LOCK"
    flock -x 9

    if [[ -n "$UPLINK" ]] && ! ip link show dev "$UPLINK" &>/dev/null; then
        setup_error "上联接口 '$UPLINK' 不存在。"
        return 1
    fi
}

setup_install_base_dependencies() {
    local -a modules=(tun bridge)
    local mod

    if ! dpkg -s qemu-system-common >/dev/null 2>&1 \
        && ! [[ -x /usr/lib/qemu/qemu-bridge-helper \
            || -x /usr/libexec/qemu-bridge-helper ]]; then
        echo ">> installing qemu-system-common (needed for qemu-bridge-helper)"
        apt-get update -qq
        apt-get install -y qemu-system-common
    fi

    [[ "$VLAN_TRUNK" == "1" ]] && modules+=(8021q)
    for mod in "${modules[@]}"; do
        if ! lsmod | grep -q "^$mod\b"; then
            if modprobe "$mod" 2>/dev/null; then
                echo ">> modprobe $mod"
            else
                echo "WARN: modprobe $mod 失败，bridge 网络可能不可用。" >&2
            fi
        fi
    done

    install -d -o root -g root -m 0755 /etc/modules-load.d
    {
        printf 'tun\nbridge\n'
        [[ "$VLAN_TRUNK" == "1" ]] && printf '8021q\n'
    } > /etc/modules-load.d/qemu-stealth.conf
    chown root:root /etc/modules-load.d/qemu-stealth.conf
    chmod 0644 /etc/modules-load.d/qemu-stealth.conf
}

# 普通无 VLAN VM 仍使用 QEMU 自带 bridge backend，因此保留历史 helper capability
# 与 bridge.conf ACL。显式 VLAN VM 会改走预建 TAP helper，两者互不覆盖。
setup_install_qemu_bridge_helper() {
    local repo_helper
    local primary=""
    local candidate
    local -a candidates=(
        /usr/lib/qemu/qemu-bridge-helper
        /usr/libexec/qemu-bridge-helper
        /usr/local/libexec/qemu-bridge-helper
    )

    repo_helper="$(cd "$HERE/../.." && pwd)/build/qemu-bridge-helper"
    [[ -x "$repo_helper" ]] && candidates+=("$repo_helper")

    for candidate in "${candidates[@]}"; do
        if [[ -x "$candidate" && -f "$candidate" && ! -L "$candidate" ]]; then
            primary="$candidate"
            break
        fi
    done
    [[ -n "$primary" ]] || {
        setup_error "找不到 qemu-bridge-helper；请安装 qemu-system-common。"
        return 1
    }
    echo ">> primary helper: $primary"

    if [[ ! -e /usr/local/libexec/qemu-bridge-helper ]]; then
        install -d -o root -g root -m 0755 /usr/local/libexec
        ln -s "$primary" /usr/local/libexec/qemu-bridge-helper
        echo ">> linked /usr/local/libexec/qemu-bridge-helper -> $primary"
    fi

    install -d -o root -g root -m 0755 /etc/qemu
    if ! grep -Fqx -- "allow $BR" /etc/qemu/bridge.conf 2>/dev/null; then
        printf 'allow %s\n' "$BR" >> /etc/qemu/bridge.conf
        echo ">> appended 'allow $BR' to /etc/qemu/bridge.conf"
    fi
    chmod 0644 /etc/qemu/bridge.conf

    for candidate in "${candidates[@]}"; do
        [[ -x "$candidate" && -f "$candidate" && ! -L "$candidate" ]] || continue
        if command -v setcap >/dev/null 2>&1; then
            if ! getcap "$candidate" 2>/dev/null | grep -q cap_net_admin; then
                setcap cap_net_admin+ep "$candidate"
                echo ">> set cap_net_admin+ep on $candidate"
            fi
        elif [[ ! -u "$candidate" ]]; then
            chmod u+s "$candidate"
            echo ">> set suid on $candidate (setcap unavailable)"
        fi
    done
}

setup_resolve_allowed_identity() {
    local requested_user="${VM_USER:-}"

    # 管理员可显式给另一普通用户安装；否则优先采用 sudo 保存的真实调用者。
    # 直接 root 运行而未指定用户时绝不授权 UID 0，避免 downscript/helper 被迫
    # 依赖 root VM 进程，也避免 sudoers 出现过宽或无效的调用主体。
    if [[ -n "$requested_user" ]]; then
        [[ "$requested_user" =~ ^[[:alnum:]_.-]+\$?$ ]] || {
            setup_error "VM_USER 用户名 '$requested_user' 含非法字符。"
            return 1
        }
        if ! ALLOWED_UID_VALUE="$(id -u -- "$requested_user" 2>/dev/null)" \
            || ! ALLOWED_GID_VALUE="$(id -g -- "$requested_user" 2>/dev/null)"; then
            setup_error "VM_USER='$requested_user' 不存在或无法解析 UID/GID。"
            return 1
        fi
    elif [[ "${SUDO_UID:-}" =~ ^[0-9]+$ \
        && "${SUDO_GID:-}" =~ ^[0-9]+$ \
        && "${SUDO_UID:-0}" != "0" ]]; then
        ALLOWED_UID_VALUE="$SUDO_UID"
        ALLOWED_GID_VALUE="$SUDO_GID"
    elif [[ -n "${SUDO_USER:-}" && "${SUDO_USER:-}" != "root" ]]; then
        if ! ALLOWED_UID_VALUE="$(id -u -- "$SUDO_USER" 2>/dev/null)" \
            || ! ALLOWED_GID_VALUE="$(id -g -- "$SUDO_USER" 2>/dev/null)"; then
            setup_error "无法解析 sudo 调用用户 '$SUDO_USER'。"
            return 1
        fi
    else
        setup_error "无法确定普通 VM 用户；直接 root 运行时请显式设置 VM_USER=<用户名>。"
        return 1
    fi

    [[ "$ALLOWED_UID_VALUE" =~ ^[0-9]+$ ]] || {
        setup_error "无法确定启动 VM 用户的 UID。"
        return 1
    }
    [[ "$ALLOWED_GID_VALUE" =~ ^[0-9]+$ ]] || {
        setup_error "无法确定启动 VM 用户的 GID。"
        return 1
    }
}

# 安装副本而非符号链接，保证之后仓库内容被普通用户修改也不会改变 sudoers 授权
# 的 root helper。配置只含白名单标量，不含 shell 代码；helper 也必须逐项解析。
setup_install_vlan_runtime() {
    local config_tmp
    local sudoers_tmp

    [[ "$VLAN_TRUNK" == "1" ]] || return 0
    setup_resolve_allowed_identity

    install -d -o root -g root -m 0755 /usr/local/libexec /etc/qemu /etc/sudoers.d
    install -o root -g root -m 0755 "$VLAN_TAP_SOURCE" "$VLAN_TAP_INSTALLED"
    install -o root -g root -m 0755 "$VLAN_DOWN_SOURCE" "$VLAN_DOWN_INSTALLED"

    config_tmp="$(mktemp /etc/qemu/.stealth-vlan.conf.XXXXXX)"
    if ! printf 'VERSION=1\nBRIDGE=br0\nUPLINK=%s\nALLOWED_UID=%s\nALLOWED_GID=%s\n' \
        "$UPLINK" "$ALLOWED_UID_VALUE" "$ALLOWED_GID_VALUE" >"$config_tmp" \
        || ! chown root:root "$config_tmp" \
        || ! chmod 0644 "$config_tmp" \
        || ! mv -f "$config_tmp" "$VLAN_CONFIG"; then
        rm -f "$config_tmp"
        setup_error "安装 $VLAN_CONFIG 失败。"
        return 1
    fi

    sudoers_tmp="$(mktemp /etc/sudoers.d/.qemu-stealth-vlan.XXXXXX)"
    if ! {
        printf '# 仅允许 setup 时的调用用户执行严格校验过的 root-owned TAP helper。\n'
        printf '#%s ALL=(root) NOPASSWD:NOSETENV: %s\n' \
            "$ALLOWED_UID_VALUE" "$VLAN_TAP_INSTALLED"
    } >"$sudoers_tmp" \
        || ! chmod 0440 "$sudoers_tmp" \
        || ! visudo -cf "$sudoers_tmp" >/dev/null \
        || ! chown root:root "$sudoers_tmp" \
        || ! mv -f "$sudoers_tmp" "$VLAN_SUDOERS"; then
        rm -f "$sudoers_tmp"
        setup_error "生成或校验 $VLAN_SUDOERS 失败。"
        return 1
    fi

    echo ">> installed root-owned VLAN helper: $VLAN_TAP_INSTALLED"
    echo ">> installed VLAN downscript: $VLAN_DOWN_INSTALLED"
    echo ">> VLAN runtime config: $VLAN_CONFIG (UID=$ALLOWED_UID_VALUE)"
}

# NetworkManager 迁移失败时，只恢复本次确实停用的原 active profile。
setup_nm_restore_uplink() {
    local bridge_name="$1" slave="$2" names_var="$3" modes_var="$4" index
    local -n names="$names_var" modes="$modes_var"
    # 激活已经开始后，先停掉可能仍在 DHCP/linkdown 状态的 controller，避免
    # 回滚物理口后遗留第二条 br0 默认路由。
    if [[ "${SETUP_NM_BRIDGE_RESTARTED:-0}" == "1" ]]; then
        nmcli connection down "$bridge_name" >/dev/null 2>&1 || true
    fi
    if [[ "${SETUP_NM_SLAVE_CREATED:-0}" == "1" ]]; then
        nmcli connection delete "$slave" >/dev/null 2>&1 || true
    else
        nmcli connection down "$slave" >/dev/null 2>&1 || true
    fi
    for ((index=${#names[@]}-1; index>=0; index--)); do
        nmcli connection modify "${names[index]}" \
            connection.autoconnect "${modes[index]}" >/dev/null 2>&1 || true
        nmcli connection up "${names[index]}" >/dev/null 2>&1 || true
    done
}

setup_nm_activate_uplink() {
    local bridge_name="$1" uplink="$2" slave="$3" trunk="$4"
    SETUP_NM_SLAVE_CREATED=0
    SETUP_NM_BRIDGE_RESTARTED=0
    if ! nmcli -t -f NAME connection show | grep -Fxq "$slave"; then
        nmcli connection add type bridge-slave ifname "$uplink" \
            connection.master "$bridge_name" con-name "$slave" autoconnect no || return 1
        SETUP_NM_SLAVE_CREATED=1
        echo ">> created NM bridge-slave '$slave'"
    else
        echo ">> NM bridge-slave '$slave' already exists"
    fi
    # 迁移事务内先禁止 port 抢先激活；成功后再写入 late-carrier 持久契约。
    nmcli connection modify "$slave" connection.autoconnect no || return 1

    # setup 期间只从 controller 激活，避免两份 activation 互相中断。
    nmcli connection modify "$bridge_name" \
        connection.autoconnect yes \
        connection.autoconnect-slaves 1 \
        ipv4.method auto ipv4.addresses "" || return 1
    nmcli connection down "$bridge_name" 2>/dev/null || true
    SETUP_NM_BRIDGE_RESTARTED=1
    nmcli connection up "$bridge_name" || return 1
    if [[ "$trunk" == "1" ]]; then
        setup_enable_vlan_runtime "$bridge_name" "$uplink" || return 1
    fi
    setup_nm_persist_boot_contract "$bridge_name" "$uplink"
}

# NetworkManager 1.36–1.54 仍兼容 bridge-slave、旧 master/autoconnect-slaves
# 属性；使用这些别名可同时覆盖 Ubuntu 22.04 和当前新宿主。trunk 属性写入
# bridge profile，重启后由 NM 恢复。
setup_bridge_nm() {
    local bridge_name="$1" uplink="$2" host_ip="$3" trunk="$4"
    local slave connection original_autoconnect
    local -a released_names=()
    local -a released_modes=()

    if ! nmcli -t -f NAME connection show | grep -Fxq "$bridge_name"; then
        nmcli connection add type bridge ifname "$bridge_name" con-name "$bridge_name" \
            stp no connection.autoconnect-slaves 1 \
            ipv4.method manual ipv4.addresses "$host_ip" \
            ipv6.method ignore autoconnect yes
        echo ">> created NM bridge '$bridge_name' ($host_ip)"
    else
        echo ">> NM bridge '$bridge_name' already exists"
    fi

    if [[ "$trunk" == "1" ]]; then
        nmcli connection modify "$bridge_name" \
            bridge.vlan-filtering yes \
            bridge.vlan-default-pvid 1 \
            bridge.vlan-protocol 802.1Q
    fi

    if [[ -n "$uplink" ]]; then
        slave="$bridge_name-slave-$uplink"
        SETUP_NM_SLAVE_CREATED=0
        SETUP_NM_BRIDGE_RESTARTED=0
        # netplan 生成的物理口 profile 可能抢先自动激活。先停用并禁止这些冲突
        # profile，再创建 bridge-slave，避免 nmcli 表面成功但设备仍未进入 br0。
        while IFS= read -r connection; do
            [[ -n "$connection" ]] || continue
            if ! original_autoconnect="$(nmcli -g connection.autoconnect \
                connection show "$connection")"; then
                setup_nm_restore_uplink \
                    "$bridge_name" "$slave" released_names released_modes
                return 1
            fi
            released_names+=("$connection")
            released_modes+=("$original_autoconnect")
            echo ">> releasing existing connection '$connection' on $uplink"
            if ! nmcli connection modify "$connection" connection.autoconnect no; then
                setup_nm_restore_uplink \
                    "$bridge_name" "$slave" released_names released_modes
                return 1
            fi
            nmcli connection down "$connection" || true
        done < <(
            nmcli -t -f NAME,DEVICE connection show --active \
                | awk -F: -v dev="$uplink" -v own="$slave" \
                    '$2 == dev && $1 != own { print $1 }'
        )

        if ! setup_nm_activate_uplink "$bridge_name" "$uplink" "$slave" "$trunk"; then
            setup_nm_restore_uplink \
                "$bridge_name" "$slave" released_names released_modes
            return 1
        fi
        echo ">> bridge $bridge_name up with uplink $uplink (DHCP from native LAN)"
    else
        nmcli connection up "$bridge_name" || true
        echo ">> bridge $bridge_name up (isolated, host IP $host_ip)"
    fi
}

# NetworkManager profile 是持久层；这里再次设置运行态，确保 setup 返回成功时立即
# 满足启动器 preflight。VID 1 保持 PVID/untagged，故无 --vlan-id 的旧 VM 行为不变。
setup_enable_vlan_runtime() {
    local bridge_name="$1"
    local uplink="$2"

    ip link set dev "$bridge_name" type bridge \
        vlan_filtering 1 vlan_default_pvid 1 vlan_protocol 802.1Q || return 1
    # 已有非 VID1 的 native/PVID 时不能静默抢走未标记入站流量；这通常表示
    # 交换机或旧 bridge 使用另一 native VLAN，应由管理员先明确迁移方案。
    if ! setup_uplink_native_is_safe "$uplink"; then
        setup_error "上联 $uplink 已有非 VID1 的 native/untagged VLAN，拒绝自动改写。"
        return 1
    fi
    bridge vlan add dev "$uplink" vid 1 pvid untagged || return 1
    bridge vlan add dev "$bridge_name" vid 1 pvid untagged self
}

# 无 NetworkManager 时沿用旧 iproute2 非持久 fallback。trunk 只在 br0 本体开启
# bridge VLAN filtering，不创建 802.1Q 子接口或额外 bridge。
setup_bridge_iproute() {
    local bridge_name="$1"
    local uplink="$2"
    local host_ip="$3"
    local trunk="$4"
    local bridge_info
    local address
    local -a addresses=()

    if ip link show dev "$bridge_name" &>/dev/null; then
        bridge_info="$(ip -d -o link show dev "$bridge_name")"
        [[ "$bridge_info" =~ [[:space:]]bridge[[:space:]]+forward_delay[[:space:]] ]] || {
            setup_error "接口 '$bridge_name' 已存在但不是 Linux bridge。"
            return 1
        }
    else
        ip link add name "$bridge_name" type bridge
        echo ">> created bridge $bridge_name"
    fi

    if [[ "$trunk" == "1" ]]; then
        ip link set dev "$bridge_name" type bridge \
            vlan_filtering 1 vlan_default_pvid 1 vlan_protocol 802.1Q
    fi
    ip link set dev "$bridge_name" up

    if [[ -n "$uplink" ]]; then
        ip link set dev "$uplink" master "$bridge_name"
        ip link set dev "$uplink" up
        mapfile -t addresses < <(ip -4 -o address show dev "$uplink" | awk '{ print $4 }')
        for address in "${addresses[@]}"; do
            # 先把地址加入 bridge，确保新增失败时原 uplink 地址仍在。随后若删除
            # 原地址失败，只撤回本次新增项，避免同一地址留在两个接口。
            if ! ip address add "$address" dev "$bridge_name"; then
                return 1
            fi
            if ! ip address del "$address" dev "$uplink"; then
                ip address del "$address" dev "$bridge_name" >/dev/null 2>&1 || true
                return 1
            fi
        done
        [[ "$trunk" == "1" ]] && setup_enable_vlan_runtime "$bridge_name" "$uplink"
        echo ">> enslaved $uplink under $bridge_name (non-persistent; configure NM/netplan for reboot)"
    elif ! ip -4 -o address show dev "$bridge_name" \
        | awk '{ print $4 }' | grep -Fqx -- "$host_ip"; then
        ip address add "$host_ip" dev "$bridge_name"
        echo ">> bridge $bridge_name up (isolated, host IP $host_ip)"
    fi
}

setup_main() {
    local use_nm=0

    setup_validate_inputs
    setup_require_vlan_assets
    setup_require_root_and_lock

    # 启动器自动模式在 root 全局锁内再次核对目标用户。若另一个实例已先完成，
    # 后到者直接成功返回；若已有配置属于不同用户或已损坏，则拒绝自动覆盖。
    if [[ "$VLAN_TRUNK" == "1" && "$VLAN_SETUP_AUTO" == "1" ]]; then
        setup_resolve_allowed_identity
        if setup_vlan_config_path_exists \
            && ! setup_vlan_config_matches_request; then
            setup_error "已有 VLAN 配置与当前用户/上联不一致，拒绝自动覆盖；请人工审计。"
            return 1
        fi
    fi

    setup_install_base_dependencies
    setup_install_qemu_bridge_helper

    if setup_vlan_auto_is_fully_ready; then
        echo ">> single br0 VLAN trunk already initialized; skip network restart."
        return 0
    fi

    # 安装 helper/config/sudoers 放在网络迁移前：若安装失败，物理网卡仍保持原状。
    setup_install_vlan_runtime

    # helper/sudoers 缺失但 bridge 已就绪时只修复安装契约，不重启宿主网络。
    if [[ "$VLAN_TRUNK" == "1" && "$VLAN_SETUP_AUTO" == "1" ]] \
        && setup_vlan_topology_is_ready; then
        if setup_nm_is_active; then
            setup_nm_persist_boot_contract "$BR" "$UPLINK" || {
                setup_error "修复 NetworkManager bridge 启动契约失败。"
                return 1
            }
        fi
        echo ">> VLAN runtime repaired; existing br0 topology kept without restart."
        return 0
    fi

    if setup_nm_is_active; then
        use_nm=1
    fi

    if (( use_nm )); then
        echo ">> using NetworkManager to manage $BR"
        # shellcheck disable=SC2153  # HOST_IP 由已先执行的 setup_validate_inputs 赋值。
        setup_bridge_nm "$BR" "$UPLINK" "$HOST_IP" "$VLAN_TRUNK"
    else
        echo ">> NetworkManager not active; falling back to iproute2"
        setup_bridge_iproute "$BR" "$UPLINK" "$HOST_IP" "$VLAN_TRUNK"
    fi

    echo
    if [[ "$VLAN_TRUNK" == "1" ]]; then
        echo ">> done. Single br0 VLAN trunk is ready; no per-VLAN bridge is needed."
        echo "      deploy/scripts/start-vm.sh 1 --vlan-id=11"
    else
        echo ">> done. Launch a guest with:"
        echo "      BRIDGE=$BR INSTANCE=1 deploy/scripts/start-vm.sh"
    fi
}

# 被测试 source 时只注册函数；直接执行时才允许触碰宿主。
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    setup_main "$@"
fi
