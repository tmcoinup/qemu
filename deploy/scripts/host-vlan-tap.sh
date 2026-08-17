#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# host-vlan-tap.sh —— 单 br0 VLAN-aware bridge 的动态 access TAP 管理器
#
# 本脚本以 root 身份运行，并由安装阶段复制为：
#   /usr/local/libexec/qemu-g11-vlan-tap
#
# 安全模型：
#   1. 普通 VM 用户只能通过 sudoers 执行上面的 root:root 固定副本；
#   2. bridge、uplink、调用 UID/GID 和 VLAN 白名单只从 root 管理的配置读取；
#   3. 配置绝不 source/eval，只接受六个无引号、无空白、不可重复的固定字段；
#   4. 每个实例只能操作确定性名字 g11t<实例号>，cleanup-ifname 不能删除任意网卡；
#   5. 所有检查、创建和清理共用一把 flock，避免 downscript/watchdog/stop-vm 竞态。
#
# 命令：
#   check <instance> <vid>           只读核验宿主拓扑及已有 TAP
#   prepare <instance> <vid>         创建 access/PVID/untagged persistent TAP
#   cleanup-instance <instance>      按实例幂等清理
#   cleanup-ifname <g11tN>          供 QEMU downscript/watchdog 幂等清理
#
# stdout 契约：check/prepare 成功时只输出 TAP 名；其余诊断全部写 stderr。
#
# 文件长度说明：本 root helper 的非注释逻辑略超过 500 行。这里刻意保持一个
# 自包含、一次 install 的特权安全边界；若拆成可 source 的多个脚本，就必须额外
# 安装、校验并保护每个 root 代码入口，反而扩大 sudo helper 的供应链与替换面。
# 纯参数库、启动生命周期和宿主 setup 已分别拆文件，本文件只保留必须原子审计的
# 配置/状态解析、bridge 操作及回滚逻辑。
# ---------------------------------------------------------------------------
set -euo pipefail

# root helper 不继承调用方可注入的 PATH。这里列出的目录都应由 root 管理，
# 同时兼容 Debian/Ubuntu 把 iproute2 放在 /usr/sbin 或 /usr/bin 的布局。
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 077

readonly CONFIG_FILE="/etc/qemu/g11-vlan.conf"
readonly STATE_DIR="/run/qemu-g11-vlan"
readonly LOCK_FILE="/run/qemu-g11-vlan.lock"
readonly MAINTENANCE_LOCK_FILE="/run/qemu-g11-network.lock"
readonly REQUIRED_BRIDGE="br0"

CONFIG_VERSION=""
CONFIG_BRIDGE=""
CONFIG_UPLINK=""
CONFIG_ALLOWED_UID=""
CONFIG_ALLOWED_GID=""
CONFIG_ALLOWED_VLANS=""

STATE_VERSION=""
STATE_INSTANCE=""
STATE_VLAN_ID=""
STATE_TAP=""
STATE_BRIDGE=""
STATE_OWNER_UID=""
STATE_OWNER_GID=""

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat >&2 <<'EOF'
用法：
  qemu-g11-vlan-tap check <instance> <vid>
  qemu-g11-vlan-tap prepare <instance> <vid>
  qemu-g11-vlan-tap cleanup-instance <instance>
  qemu-g11-vlan-tap cleanup-ifname <g11tN>
EOF
    exit 2
}

require_root_and_tools() {
    (( EUID == 0 )) || die "必须以 root 身份运行"

    local command_name
    for command_name in ip bridge flock stat awk mkdir chmod chown mktemp mv rm dirname; do
        command -v "$command_name" >/dev/null 2>&1 \
            || die "缺少必需命令: $command_name"
    done
}

# Linux IFNAMSIZ 为 16（含结尾 NUL），所以可见接口名最多 15 字符。只允许
# 常见安全字符，既满足 iproute2，也防止错误文本和命令参数被换行/空白污染。
validate_ifname() {
    local name="${1:-}"

    [[ -n "$name" && ${#name} -le 15 ]] || return 1
    [[ "$name" =~ ^[[:alnum:]_.-]+$ ]] || return 1
    [[ "$name" != "." && "$name" != ".." ]] || return 1
}

validate_instance() {
    local instance="${1:-}"

    [[ "$instance" =~ ^[0-9]{1,10}$ ]] || return 1
    (( 10#$instance >= 1 )) || return 1
}

tap_name_for_instance() {
    local instance="$1"
    local tap

    validate_instance "$instance" || return 1
    tap="g11t${instance}"
    validate_ifname "$tap" || return 1
    printf '%s\n' "$tap"
}

normalize_vlan_id() {
    local raw="${1:-}"
    local normalized

    [[ "$raw" =~ ^[0-9]{1,4}$ ]] || return 1
    normalized=$((10#$raw))
    (( normalized >= 1 && normalized <= 4094 )) || return 1
    printf '%d\n' "$normalized"
}

# ALLOWED_VLANS 是 root 管理的显式白名单，格式为逗号分隔的单个 VID 或闭区间，
# 例如 `11,20,30-39`。这里不接受空项、降序区间、0/4095 或任何空白；解析时
# 始终显式按十进制规范化，避免 08/09 被 Bash 当作八进制。
validate_vlan_allowlist() {
    local allowlist="${1:-}"
    local item first last
    local -a items=()

    [[ -n "$allowlist" && ${#allowlist} -le 4096 ]] || return 1
    [[ "$allowlist" =~ ^[0-9]{1,4}(-[0-9]{1,4})?(,[0-9]{1,4}(-[0-9]{1,4})?)*$ ]] \
        || return 1
    IFS=',' read -r -a items <<<"$allowlist"
    for item in "${items[@]}"; do
        if [[ "$item" == *-* ]]; then
            first="${item%%-*}"
            last="${item#*-}"
            first="$(normalize_vlan_id "$first")" || return 1
            last="$(normalize_vlan_id "$last")" || return 1
            (( first <= last )) || return 1
        else
            normalize_vlan_id "$item" >/dev/null || return 1
        fi
    done
}

vlan_id_is_allowed() {
    local requested allowlist item first last
    local -a items=()

    requested="$(normalize_vlan_id "${1:-}")" || return 1
    allowlist="${2:-}"
    validate_vlan_allowlist "$allowlist" || return 1
    IFS=',' read -r -a items <<<"$allowlist"
    for item in "${items[@]}"; do
        if [[ "$item" == *-* ]]; then
            first="$(normalize_vlan_id "${item%%-*}")" || return 1
            last="$(normalize_vlan_id "${item#*-}")" || return 1
            (( requested >= first && requested <= last )) && return 0
        else
            first="$(normalize_vlan_id "$item")" || return 1
            (( requested == first )) && return 0
        fi
    done
    return 1
}

# UID/GID 使用内核常见的非负 32 位有符号范围。允许 0 是为了 root 直接运维，
# 也让非特权 user namespace 的隔离测试可以映射到 namespace 内的 root。
validate_numeric_id() {
    local value="${1:-}"

    [[ "$value" =~ ^(0|[1-9][0-9]{0,9})$ ]] || return 1
    (( 10#$value <= 2147483647 )) || return 1
}

file_is_root_controlled() {
    local path="$1"
    local owner mode permissions

    [[ -f "$path" && ! -L "$path" ]] || return 1
    owner="$(stat -c '%u' -- "$path" 2>/dev/null)" || return 1
    mode="$(stat -c '%a' -- "$path" 2>/dev/null)" || return 1
    [[ "$owner" == "0" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    permissions=$((8#$mode))
    (( (permissions & 8#022) == 0 ))
}

directory_is_root_controlled() {
    local path="$1"
    local owner mode permissions

    [[ -d "$path" && ! -L "$path" ]] || return 1
    owner="$(stat -c '%u' -- "$path" 2>/dev/null)" || return 1
    mode="$(stat -c '%a' -- "$path" 2>/dev/null)" || return 1
    [[ "$owner" == "0" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    permissions=$((8#$mode))
    (( (permissions & 8#022) == 0 ))
}

# 严格读取 root 配置。注释和空行可用于说明，其余每行必须是 KEY=VALUE；
# 不支持 shell 引号、变量展开、行尾注释或任意额外字段。
load_config() {
    local line key value line_no=0
    local -A seen=()

    directory_is_root_controlled "$(dirname "$CONFIG_FILE")" \
        || die "配置目录必须是 root-owned 且不可被 group/other 写入: $(dirname "$CONFIG_FILE")"
    file_is_root_controlled "$CONFIG_FILE" \
        || die "配置必须是 root-owned 且不可被 group/other 写入的普通文件: $CONFIG_FILE"

    CONFIG_VERSION=""
    CONFIG_BRIDGE=""
    CONFIG_UPLINK=""
    CONFIG_ALLOWED_UID=""
    CONFIG_ALLOWED_GID=""
    CONFIG_ALLOWED_VLANS=""

    while IFS= read -r line || [[ -n "$line" ]]; do
        ((line_no += 1))
        [[ -z "$line" || "$line" == \#* ]] && continue
        if ! [[ "$line" =~ ^([A-Z_]+)=([^[:space:]]+)$ ]]; then
            die "$CONFIG_FILE:$line_no 格式非法；只允许无引号 KEY=VALUE"
        fi
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        [[ -z "${seen[$key]:-}" ]] \
            || die "$CONFIG_FILE:$line_no 字段重复: $key"
        seen[$key]=1

        case "$key" in
            VERSION)     CONFIG_VERSION="$value" ;;
            BRIDGE)      CONFIG_BRIDGE="$value" ;;
            UPLINK)      CONFIG_UPLINK="$value" ;;
            ALLOWED_UID) CONFIG_ALLOWED_UID="$value" ;;
            ALLOWED_GID) CONFIG_ALLOWED_GID="$value" ;;
            ALLOWED_VLANS) CONFIG_ALLOWED_VLANS="$value" ;;
            *) die "$CONFIG_FILE:$line_no 包含未知字段: $key" ;;
        esac
    done <"$CONFIG_FILE"

    [[ "$CONFIG_VERSION" == "1" ]] || die "配置 VERSION 必须为 1"
    [[ "$CONFIG_BRIDGE" == "$REQUIRED_BRIDGE" ]] \
        || die "配置 BRIDGE 必须固定为 $REQUIRED_BRIDGE"
    validate_ifname "$CONFIG_UPLINK" || die "配置 UPLINK 不是合法接口名"
    [[ "$CONFIG_UPLINK" != "$CONFIG_BRIDGE" ]] \
        || die "配置 UPLINK 不能与 BRIDGE 相同"
    validate_numeric_id "$CONFIG_ALLOWED_UID" || die "配置 ALLOWED_UID 非法"
    validate_numeric_id "$CONFIG_ALLOWED_GID" || die "配置 ALLOWED_GID 非法"
    validate_vlan_allowlist "$CONFIG_ALLOWED_VLANS" \
        || die "配置 ALLOWED_VLANS 非法；应为逗号分隔的 VID/范围（如 11,20,30-39）"
}

# sudo 会提供原始调用者 UID/GID。两者必须同时存在并与 root 配置完全相等；
# root 直接调用时它们都可以为空，便于 setup/人工恢复和 namespace 测试。
authorize_caller() {
    local sudo_uid="${SUDO_UID:-}"
    local sudo_gid="${SUDO_GID:-}"

    if [[ -z "$sudo_uid" && -z "$sudo_gid" ]]; then
        return 0
    fi
    [[ -n "$sudo_uid" && -n "$sudo_gid" ]] \
        || die "SUDO_UID/SUDO_GID 必须同时存在"
    validate_numeric_id "$sudo_uid" || die "SUDO_UID 非法"
    validate_numeric_id "$sudo_gid" || die "SUDO_GID 非法"
    [[ "$sudo_uid" == "$CONFIG_ALLOWED_UID" \
        && "$sudo_gid" == "$CONFIG_ALLOWED_GID" ]] \
        || die "调用者 UID/GID 未被 VLAN root 配置授权"
}

acquire_maintenance_lock_shared() {
    local lock_parent before_inode after_inode

    lock_parent="${MAINTENANCE_LOCK_FILE%/*}"
    directory_is_root_controlled "$lock_parent" \
        || die "宿主网络维护锁目录不可信: $lock_parent"
    file_is_root_controlled "$MAINTENANCE_LOCK_FILE" \
        || die "宿主网络维护锁缺失或不可信；请重跑 setup-bridge.sh"
    before_inode="$(stat -c '%d:%i' -- "$MAINTENANCE_LOCK_FILE")"
    exec 8<"$MAINTENANCE_LOCK_FILE"
    after_inode="$(stat -Lc '%d:%i' /proc/self/fd/8)"
    [[ "$before_inode" == "$after_inode" ]] \
        || die "宿主网络维护锁在打开时被替换"
    flock -s -w 10 8 || die "宿主网络正在维护，VLAN helper 拒绝并发操作"
}

# 锁路径本身是固定契约。打开前后都核验 root 所有权和 inode，避免错误部署到
# 可写目录时跟随攻击者预置的符号链接；固定父目录 /run 必须由 root 管理。
acquire_global_lock() {
    local lock_parent
    local before_inode after_inode

    # Ubuntu 的 /run/lock 可能是 1777；即使有 sticky bit，其他用户仍可抢先
    # 创建固定文件造成拒绝服务。锁直接放进 root 管理且不可写的 /run。
    lock_parent="${LOCK_FILE%/*}"
    directory_is_root_controlled "$lock_parent" \
        || die "锁目录必须由 root 独占管理: $lock_parent"

    if [[ ! -e "$LOCK_FILE" ]]; then
        # noclobber 保证并发首建时不覆盖已出现的路径；另一个进程先创建成功
        # 属于正常竞争，随后会进入同一套 owner/mode/inode 校验。
        ( set -o noclobber; umask 077; : >"$LOCK_FILE" ) 2>/dev/null || true
    fi
    file_is_root_controlled "$LOCK_FILE" \
        || die "锁文件必须是 root-owned 且不可写的普通文件: $LOCK_FILE"
    before_inode="$(stat -c '%d:%i' -- "$LOCK_FILE")"
    exec 9>>"$LOCK_FILE"
    after_inode="$(stat -Lc '%d:%i' /proc/self/fd/9)"
    [[ "$before_inode" == "$after_inode" ]] || die "锁文件在打开时被替换"
    flock -x -w 10 9 || die "等待 VLAN 全局锁超时"
}

state_file_for_instance() {
    local instance="$1"

    validate_instance "$instance" || return 1
    printf '%s/instance-%s.state\n' "$STATE_DIR" "$instance"
}

runtime_state_dir_check() {
    local owner mode permissions

    [[ -e "$STATE_DIR" ]] || return 0
    [[ -d "$STATE_DIR" && ! -L "$STATE_DIR" ]] \
        || die "状态路径不是安全目录: $STATE_DIR"
    owner="$(stat -c '%u' -- "$STATE_DIR")"
    mode="$(stat -c '%a' -- "$STATE_DIR")"
    [[ "$owner" == "0" && "$mode" =~ ^[0-7]{3,4}$ ]] \
        || die "状态目录必须由 root 管理"
    permissions=$((8#$mode))
    (( (permissions & 8#022) == 0 )) \
        || die "状态目录不能被 group/other 写入"
}

ensure_runtime_state_dir() {
    if [[ ! -e "$STATE_DIR" ]]; then
        mkdir -- "$STATE_DIR" || die "无法创建状态目录 $STATE_DIR"
    fi
    runtime_state_dir_check
    chown 0:0 -- "$STATE_DIR"
    chmod 0700 -- "$STATE_DIR"
}

reset_state_values() {
    STATE_VERSION=""
    STATE_INSTANCE=""
    STATE_VLAN_ID=""
    STATE_TAP=""
    STATE_BRIDGE=""
    STATE_OWNER_UID=""
    STATE_OWNER_GID=""
}

# 状态文件同样严格解析。它位于 root-only /run 目录，用来证明 TAP 是本 helper
# 为哪个实例/VID 创建的；cleanup 不接受调用方伪造的 bridge 或任意接口名。
load_state() {
    local instance="$1"
    local state_file line key value line_no=0 expected_tap
    local -A seen=()

    reset_state_values
    state_file="$(state_file_for_instance "$instance")" || return 2
    [[ -e "$state_file" ]] || return 1
    file_is_root_controlled "$state_file" \
        || die "状态文件权限或类型不安全: $state_file"

    while IFS= read -r line || [[ -n "$line" ]]; do
        ((line_no += 1))
        [[ "$line" =~ ^([A-Z_]+)=([^[:space:]]+)$ ]] \
            || die "$state_file:$line_no 状态格式非法"
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        [[ -z "${seen[$key]:-}" ]] || die "$state_file:$line_no 状态字段重复: $key"
        seen[$key]=1
        case "$key" in
            VERSION)   STATE_VERSION="$value" ;;
            INSTANCE)  STATE_INSTANCE="$value" ;;
            VLAN_ID)   STATE_VLAN_ID="$value" ;;
            TAP)       STATE_TAP="$value" ;;
            BRIDGE)    STATE_BRIDGE="$value" ;;
            OWNER_UID) STATE_OWNER_UID="$value" ;;
            OWNER_GID) STATE_OWNER_GID="$value" ;;
            *) die "$state_file:$line_no 包含未知状态字段: $key" ;;
        esac
    done <"$state_file"

    expected_tap="$(tap_name_for_instance "$instance")" || die "状态实例号非法"
    [[ "$STATE_VERSION" == "1" ]] || die "状态 VERSION 非法"
    [[ "$STATE_INSTANCE" == "$instance" ]] || die "状态 INSTANCE 与文件名不一致"
    normalize_vlan_id "$STATE_VLAN_ID" >/dev/null || die "状态 VLAN_ID 非法"
    [[ "$STATE_TAP" == "$expected_tap" ]] || die "状态 TAP 与实例不一致"
    [[ "$STATE_BRIDGE" == "$REQUIRED_BRIDGE" ]] || die "状态 BRIDGE 非法"
    validate_numeric_id "$STATE_OWNER_UID" || die "状态 OWNER_UID 非法"
    validate_numeric_id "$STATE_OWNER_GID" || die "状态 OWNER_GID 非法"
}

write_state() {
    local instance="$1" vlan_id="$2" tap="$3"
    local state_file temp_file

    ensure_runtime_state_dir
    state_file="$(state_file_for_instance "$instance")" || die "无法生成状态路径"
    temp_file="$(mktemp "$STATE_DIR/.state.XXXXXX")" \
        || die "无法创建临时状态文件"
    if ! printf '%s\n' \
        'VERSION=1' \
        "INSTANCE=$instance" \
        "VLAN_ID=$vlan_id" \
        "TAP=$tap" \
        "BRIDGE=$CONFIG_BRIDGE" \
        "OWNER_UID=$CONFIG_ALLOWED_UID" \
        "OWNER_GID=$CONFIG_ALLOWED_GID" >"$temp_file"; then
        rm -f -- "$temp_file"
        die "写入 TAP 状态失败"
    fi
    chown 0:0 -- "$temp_file"
    chmod 0600 -- "$temp_file"
    mv -fT -- "$temp_file" "$state_file" || {
        rm -f -- "$temp_file"
        die "提交 TAP 状态失败"
    }
}

remove_state() {
    local instance="$1"
    local state_file

    state_file="$(state_file_for_instance "$instance")" || return 1
    rm -f -- "$state_file"
    # Mutating actions hold the global VLAN lock, so removing an empty runtime
    # directory cannot race another helper's state commit.  This also prevents
    # an empty crash-hint directory from forcing cleanup on every future stop.
    rmdir -- "$STATE_DIR" 2>/dev/null || true
}

link_exists() {
    ip link show dev "$1" >/dev/null 2>&1
}

tap_is_tuntap() {
    local tap="$1"

    # 部分 iproute2 版本会忽略 `show dev NAME` 并输出全部 tuntap，不能假设
    # 目标接口位于第一行；逐行精确匹配名字、tap 类型和 persist 标志。
    ip tuntap show 2>/dev/null | awk -v wanted="${tap}:" '
        $1 == wanted && $2 == "tap" {
            for (i = 3; i <= NF; i++) if ($i == "persist") found = 1
        }
        END { exit(found ? 0 : 1) }
    '
}

link_master_is() {
    local ifname="$1" expected="$2" details

    details="$(ip -o link show dev "$ifname" 2>/dev/null)" || return 1
    [[ "$details" =~ [[:space:]]master[[:space:]]+([^[:space:]]+) ]] || return 1
    [[ "${BASH_REMATCH[1]}" == "$expected" ]]
}

link_is_admin_up() {
    local ifname="$1" details

    details="$(ip -o link show dev "$ifname" 2>/dev/null)" || return 1
    [[ "$details" =~ \<[^\>]*UP([,\>]) ]]
}

# 读取上联目标 VID 的模式。业务 VID 必须是纯 tagged；VID 1 是为了兼容原有
# native LAN，必须是 PVID/Egress Untagged。若管理员预先配置了相反 flags，helper
# 会拒绝静默改写，避免把业务 VLAN 意外变成 native VLAN。
uplink_vlan_status() {
    local ifname="$1" vlan_id="$2"

    bridge vlan show dev "$ifname" 2>/dev/null | awk \
        -v dev="$ifname" -v wanted="$vlan_id" '
        NR == 1 { next }
        NF == 0 { next }
        {
            if ($1 == dev && $2 ~ /^[0-9]+(-[0-9]+)?$/) { token = $2; flag_start = 3 }
            else { token = $1; flag_start = 2 }
            matches = 0
            if (token ~ /^[0-9]+$/ && token + 0 == wanted) matches = 1
            if (token ~ /^[0-9]+-[0-9]+$/) {
                split(token, ends, "-")
                if (wanted >= ends[1] && wanted <= ends[2]) matches = 1
            }
            if (!matches) next
            found++
            has_pvid = has_egress = has_untagged = 0
            for (i = flag_start; i <= NF; i++) {
                if ($i == "PVID") has_pvid = 1
                if ($i == "Egress") has_egress = 1
                if ($i == "Untagged") has_untagged = 1
            }
            if (wanted == 1) {
                if (!(has_pvid && has_egress && has_untagged)) bad = 1
            } else if (has_pvid || has_egress || has_untagged) {
                bad = 1
            }
        }
        END {
            if (!found) print "missing"
            else if (found != 1 || bad) print "unsafe"
            else if (wanted == 1) print "native"
            else print "tagged"
        }
    '
}

uplink_has_nondefault_native() {
    local ifname="$1"

    bridge vlan show dev "$ifname" 2>/dev/null | awk -v dev="$ifname" '
        NR == 1 { next }
        NF == 0 { next }
        {
            if ($1 == dev && $2 ~ /^[0-9]+(-[0-9]+)?$/) { token = $2; flag_start = 3 }
            else { token = $1; flag_start = 2 }
            native = 0
            for (i = flag_start; i <= NF; i++) {
                if ($i == "PVID" || $i == "Egress" || $i == "Untagged") native = 1
            }
            if (native && token != "1") bad = 1
        }
        END { exit(bad ? 0 : 1) }
    '
}

validate_uplink_native_vlan() {
    local status

    status="$(uplink_vlan_status "$CONFIG_UPLINK" 1)" \
        || die "无法读取 uplink $CONFIG_UPLINK 的 native VLAN"
    [[ "$status" == "native" ]] \
        || die "uplink $CONFIG_UPLINK 必须以 VID 1 作为唯一 native/PVID"
    ! uplink_has_nondefault_native "$CONFIG_UPLINK" \
        || die "uplink $CONFIG_UPLINK 存在 VID 1 以外的 native/untagged VLAN"
}

validate_uplink_vlan_if_present() {
    local vlan_id="$1" status expected

    status="$(uplink_vlan_status "$CONFIG_UPLINK" "$vlan_id")" \
        || die "无法读取 uplink $CONFIG_UPLINK 的 VLAN 表"
    [[ "$status" == "missing" ]] && return 0
    expected="tagged"
    [[ "$vlan_id" == "1" ]] && expected="native"
    [[ "$status" == "$expected" ]] \
        || die "uplink $CONFIG_UPLINK 的 VLAN $vlan_id flags 不安全（期望 $expected）"
}

# 白名单内的业务 VID 第一次启动时在锁内自动加入物理 trunk；后续 VM 可直接复用。
# cleanup 只删除 TAP，故不会误删管理员或其它实例仍在使用的 uplink membership。
ensure_uplink_vlan() {
    local vlan_id="$1" status expected

    status="$(uplink_vlan_status "$CONFIG_UPLINK" "$vlan_id")" \
        || die "无法读取 uplink $CONFIG_UPLINK 的 VLAN 表"
    expected="tagged"
    [[ "$vlan_id" == "1" ]] && expected="native"
    if [[ "$status" == "missing" ]]; then
        if [[ "$vlan_id" == "1" ]]; then
            bridge vlan add dev "$CONFIG_UPLINK" vid 1 pvid untagged \
                || die "无法恢复 uplink native VLAN 1"
        else
            bridge vlan add dev "$CONFIG_UPLINK" vid "$vlan_id" \
                || die "无法把 VLAN $vlan_id 加入 uplink trunk"
        fi
        status="$(uplink_vlan_status "$CONFIG_UPLINK" "$vlan_id")" \
            || die "无法复核 uplink VLAN $vlan_id"
    fi
    [[ "$status" == "$expected" ]] \
        || die "uplink $CONFIG_UPLINK 的 VLAN $vlan_id flags 不安全（期望 $expected）"
}

# VM 端口必须只有一个 VID，且同时具备 PVID 与 Egress Untagged。这样 guest
# 始终收发无标签帧，标签只存在于 br0 到物理 trunk uplink 的链路上。
bridge_port_is_exact_access() {
    local ifname="$1" vlan_id="$2"

    bridge vlan show dev "$ifname" 2>/dev/null | awk \
        -v dev="$ifname" -v wanted="$vlan_id" '
        NR == 1 { next }
        NF == 0 { next }
        {
            if ($1 == dev && $2 ~ /^[0-9]+(-[0-9]+)?$/) { token = $2; flag_start = 3 }
            else { token = $1; flag_start = 2 }
            count++
            if (token != wanted) bad = 1
            has_pvid = 0
            has_egress = 0
            has_untagged = 0
            for (i = flag_start; i <= NF; i++) {
                if ($i == "PVID") has_pvid = 1
                if ($i == "Egress") has_egress = 1
                if ($i == "Untagged") has_untagged = 1
            }
            if (token == wanted && has_pvid && has_egress && has_untagged) good = 1
        }
        END { exit(count == 1 && good && !bad ? 0 : 1) }
    '
}

validate_host_topology() {
    local bridge_details

    bridge_details="$(ip -d -o link show dev "$CONFIG_BRIDGE" 2>/dev/null)" \
        || die "bridge $CONFIG_BRIDGE 不存在"
    [[ "$bridge_details" =~ [[:space:]]bridge[[:space:]]+forward_delay[[:space:]] ]] \
        || die "$CONFIG_BRIDGE 不是 Linux bridge"
    [[ "$bridge_details" =~ [[:space:]]vlan_filtering[[:space:]]+1([[:space:]]|$) ]] \
        || die "$CONFIG_BRIDGE 未启用 vlan_filtering=1"
    link_is_admin_up "$CONFIG_BRIDGE" || die "$CONFIG_BRIDGE 未处于 UP 状态"

    link_exists "$CONFIG_UPLINK" || die "uplink $CONFIG_UPLINK 不存在"
    link_master_is "$CONFIG_UPLINK" "$CONFIG_BRIDGE" \
        || die "uplink $CONFIG_UPLINK 未连接到 $CONFIG_BRIDGE"
    link_is_admin_up "$CONFIG_UPLINK" || die "uplink $CONFIG_UPLINK 未处于 UP 状态"
    validate_uplink_native_vlan
}

validate_existing_tap() {
    local tap="$1" vlan_id="$2"

    existing_tap_is_valid "$tap" "$vlan_id" \
        || die "$tap 不是预期的 persistent VLAN $vlan_id access TAP"
}

existing_tap_is_valid() {
    local tap="$1" vlan_id="$2"

    link_exists "$tap" && tap_is_tuntap "$tap" \
        && link_master_is "$tap" "$CONFIG_BRIDGE" \
        && link_is_admin_up "$tap" \
        && bridge_port_is_exact_access "$tap" "$vlan_id"
}

validate_state_matches_request() {
    local instance="$1" vlan_id="$2" tap="$3"

    [[ "$STATE_INSTANCE" == "$instance" && "$STATE_VLAN_ID" == "$vlan_id" \
        && "$STATE_TAP" == "$tap" && "$STATE_BRIDGE" == "$CONFIG_BRIDGE" \
        && "$STATE_OWNER_UID" == "$CONFIG_ALLOWED_UID" \
        && "$STATE_OWNER_GID" == "$CONFIG_ALLOWED_GID" ]] \
        || die "实例 $instance 已有与本次 VID/owner 不一致的 VLAN TAP 状态"
}

check_action() {
    local instance="$1" vlan_id="$2" tap="$3" state_rc

    # check 由 DRY_RUN/早期 preflight 调用，只做纯读取：目标 VID 尚未加入时也
    # 合法，真正的 prepare 会在全局锁内动态添加。已有错误 flags 则提前拒绝。
    validate_host_topology
    validate_uplink_vlan_if_present "$vlan_id"
    runtime_state_dir_check
    if load_state "$instance"; then
        validate_state_matches_request "$instance" "$vlan_id" "$tap"
        if link_exists "$tap" && ! tap_is_tuntap "$tap"; then
            die "可信 state 对应的 $tap 已被同名非 TAP 接口占用"
        fi
    else
        state_rc=$?
        (( state_rc == 1 )) || die "无法读取实例 $instance 的状态"
        link_exists "$tap" \
            && die "发现无可信 state 的保留接口 $tap，拒绝继续启动"
    fi
    printf '%s\n' "$tap"
}

rollback_new_tap() {
    local tap="$1"

    ip tuntap del dev "$tap" mode tap >/dev/null 2>&1 || true
}

PENDING_TAP=""
PENDING_INSTANCE=""

rollback_pending_prepare() {
    # prepare 在 TAP 创建后遇到任意显式 exit、set -e 或信号时都会走 EXIT trap。
    # 这样状态提交失败也不会留下“无可信 state、却占用保留名字”的孤儿接口。
    [[ -n "$PENDING_TAP" ]] && rollback_new_tap "$PENDING_TAP"
    if [[ -n "$PENDING_INSTANCE" ]]; then
        remove_state "$PENDING_INSTANCE" || true
    fi
}

prepare_new_tap() {
    local instance="$1" vlan_id="$2" tap="$3"

    # 先提交 root-only intent state，再创建接口；即使 helper 被 SIGKILL，下一次
    # prepare 也能凭可信 state 回收半成品。EXIT trap 处理所有可捕获的失败。
    PENDING_TAP="$tap"
    PENDING_INSTANCE="$instance"
    trap rollback_pending_prepare EXIT
    write_state "$instance" "$vlan_id" "$tap"
    if ! ip tuntap add dev "$tap" mode tap \
        user "$CONFIG_ALLOWED_UID" group "$CONFIG_ALLOWED_GID"; then
        die "创建 persistent TAP $tap 失败"
    fi
    if ! ip link set dev "$tap" master "$CONFIG_BRIDGE"; then
        die "把 $tap 接入 $CONFIG_BRIDGE 失败"
    fi

    # vlan_filtering bridge 通常会给新 port 自动加入默认 VID 1；无论目标 VID
    # 是否为 1，都先尽力删除默认项，再精确写入唯一 access VLAN。
    bridge vlan del dev "$tap" vid 1 >/dev/null 2>&1 || true
    if ! bridge vlan add dev "$tap" vid "$vlan_id" pvid untagged; then
        die "配置 $tap 的 access VLAN $vlan_id 失败"
    fi
    if ! ip link set dev "$tap" up; then
        die "启用 TAP $tap 失败"
    fi
    if ! bridge_port_is_exact_access "$tap" "$vlan_id"; then
        die "$tap 创建后的 VLAN access 配置核验失败"
    fi

    # 接口与 intent state 都通过复核后才解除回滚；stdout 返回即代表完整 ready。
    validate_existing_tap "$tap" "$vlan_id"
    PENDING_TAP=""
    PENDING_INSTANCE=""
    trap - EXIT
}

prepare_action() {
    local instance="$1" vlan_id="$2" tap="$3"
    local state_rc state_present=0

    validate_host_topology
    runtime_state_dir_check
    if load_state "$instance"; then
        validate_state_matches_request "$instance" "$vlan_id" "$tap"
        state_present=1
    else
        state_rc=$?
        (( state_rc == 1 )) || die "无法读取实例 $instance 的状态"
        link_exists "$tap" \
            && die "接口 $tap 已存在但没有可信状态；请先执行 cleanup-instance"
    fi

    # 请求与已有 state/保留接口不冲突后才扩展 uplink，避免失败调用残留新 VID。
    ensure_uplink_vlan "$vlan_id"
    if [[ "$state_present" == "1" ]]; then
        if link_exists "$tap"; then
            if existing_tap_is_valid "$tap" "$vlan_id"; then
                printf '%s\n' "$tap"
                return 0
            fi
            # 可信 state 证明该保留名字属于本实例；回收 SIGKILL 留下的半配置 TAP。
            delete_reserved_tap_if_present "$tap"
        fi
        # TAP 缺失或已回收时移除旧 intent，随后按完整事务重新创建。
        remove_state "$instance"
    fi

    prepare_new_tap "$instance" "$vlan_id" "$tap"
    validate_existing_tap "$tap" "$vlan_id"
    printf '%s\n' "$tap"
}

delete_reserved_tap_if_present() {
    local tap="$1"

    link_exists "$tap" || return 0
    tap_is_tuntap "$tap" \
        || die "拒绝删除同名非 TAP 接口: $tap"
    # `ip tuntap del` 清除 persistence。若 QEMU 仍持有 fd，接口会在 fd 关闭后
    # 最终消失；实例级 launcher 锁会阻止这段窗口内重新 prepare。
    ip tuntap del dev "$tap" mode tap >/dev/null \
        || die "删除 TAP $tap 失败"
}

cleanup_instance_action() {
    local instance="$1" tap state_rc

    tap="$(tap_name_for_instance "$instance")" || die "实例号非法"
    runtime_state_dir_check
    if load_state "$instance"; then
        [[ "$STATE_TAP" == "$tap" ]] || die "状态 TAP 与实例不一致"
    else
        state_rc=$?
        (( state_rc == 1 )) || die "无法读取实例 $instance 的状态"
        # 无可信状态时不能仅凭可预测名字删除接口。prepare 的 EXIT trap 会回滚
        # 提交 state 前的失败，因此这里把“无状态”视为已清理，保持幂等即可。
        rmdir -- "$STATE_DIR" 2>/dev/null || true
        return 0
    fi

    delete_reserved_tap_if_present "$tap"
    remove_state "$instance"
}

cleanup_ifname_action() {
    local tap="$1" instance

    if ! [[ "$tap" =~ ^g11t([0-9]{1,10})$ ]]; then
        die "cleanup-ifname 只接受 g11t<正整数>"
    fi
    instance="${BASH_REMATCH[1]}"
    validate_instance "$instance" || die "cleanup-ifname 的实例号非法"
    [[ "$(tap_name_for_instance "$instance")" == "$tap" ]] \
        || die "TAP 名与实例映射不一致"
    cleanup_instance_action "$instance"
}

main() {
    local action="${1:-}"
    local instance vlan_id tap

    case "$action" in
        check|prepare)
            (( $# == 3 )) || usage
            instance="$2"
            validate_instance "$instance" || die "instance 必须是 1..10 位正整数"
            vlan_id="$(normalize_vlan_id "$3")" \
                || die "VLAN ID 必须位于 1..4094"
            tap="$(tap_name_for_instance "$instance")" || die "无法生成 TAP 名"
            ;;
        cleanup-instance)
            (( $# == 2 )) || usage
            instance="$2"
            validate_instance "$instance" || die "instance 必须是 1..10 位正整数"
            ;;
        cleanup-ifname)
            (( $# == 2 )) || usage
            tap="$2"
            ;;
        *) usage ;;
    esac

    require_root_and_tools
    acquire_maintenance_lock_shared
    load_config
    authorize_caller

    if [[ "$action" == "check" || "$action" == "prepare" ]]; then
        vlan_id_is_allowed "$vlan_id" "$CONFIG_ALLOWED_VLANS" \
            || die "VLAN $vlan_id 不在 ALLOWED_VLANS 白名单内"
    fi

    # `check` 是 DRY_RUN 与启动早期的纯只读探测，不创建 /run lock/state，
    # 也不阻塞正在 prepare/cleanup 的 VM。所有真正变更都会在下方独占锁内复检。
    if [[ "$action" == "check" ]]; then
        check_action "$instance" "$vlan_id" "$tap"
        return 0
    fi
    acquire_global_lock

    case "$action" in
        prepare)          prepare_action "$instance" "$vlan_id" "$tap" ;;
        cleanup-instance) cleanup_instance_action "$instance" ;;
        cleanup-ifname)   cleanup_ifname_action "$tap" ;;
    esac
}

main "$@"
