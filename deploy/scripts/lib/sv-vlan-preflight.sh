#!/bin/bash
# shellcheck disable=SC2153  # INSTANCE/VLAN_ID 由已先执行的 sv-cli.sh 提供。
# ---------------------------------------------------------------------------
# 显式 VLAN 的宿主预检、TAP 准备与异步清理
#
# 安全边界必须是 setup-bridge.sh 安装的 root:root 固定副本，不能把 sudoers
# 指向普通用户可修改的仓库脚本。无 VLAN 时本文件所有函数都立即返回，确保原有
# qemu-bridge-helper 启动路径、输出和回退策略不受影响。
# ---------------------------------------------------------------------------

SV_VLAN_HELPER="/usr/local/libexec/qemu-stealth-vlan-tap"
SV_VLAN_DOWNSCRIPT="/usr/local/libexec/qemu-stealth-vlan-down"
SV_VLAN_CONFIG="/etc/qemu/stealth-vlan.conf"
SV_VLAN_STATE_DIR="/run/qemu-stealth-vlan"
SV_VLAN_LOCK_FILE="/run/qemu-stealth-vlan.lock"
SV_VLAN_SYS_CLASS_NET="/sys/class/net"
SV_VLAN_PREPARED=0
SV_VLAN_WATCHDOG_PID=""
SV_VLAN_PREFLIGHT_CODE=""
SV_VLAN_SETUP_ATTEMPTED=0
SV_VLAN_RUNTIME_CONFLICT=""

# 检查安装文件确实由 root 控制，防止管理员误把 sudoers 放行到用户可写副本。
sv_vlan_trusted_executable() {
    local path="$1"
    local owner mode

    [[ -f "$path" && -x "$path" && ! -L "$path" ]] || return 1
    owner="$(stat -c '%u' "$path" 2>/dev/null)" || return 1
    mode="$(stat -c '%a' "$path" 2>/dev/null)" || return 1
    [[ "$owner" == "0" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 8#22) == 0 ))
}

# root 直接运行 setup/测试时无需 sudo；普通 VM 用户只允许执行固定安装路径。
# `sudo -n` 禁止启动流程卡在密码提示上，权限未配置时立即给出可操作错误。
sv_vlan_helper_call() {
    if (( EUID == 0 )); then
        "$SV_VLAN_HELPER" "$@"
    else
        sudo -n "$SV_VLAN_HELPER" "$@"
    fi
}

# 早期预检只读宿主拓扑，不创建 TAP。它在 VM 目录、profile、TPM 等副作用前
# 执行；显式 VLAN 无法兑现时 fail closed，绝不悄悄回退 user-mode NAT。
sv_vlan_preflight_once() {
    local actual

    [[ -n "${VLAN_ID:-}" ]] || return 0
    SV_VLAN_PREFLIGHT_CODE=""
    if ! sv_vlan_trusted_executable "$SV_VLAN_HELPER"; then
        if [[ -e "$SV_VLAN_HELPER" ]]; then
            SV_VLAN_PREFLIGHT_CODE="helper_unsafe"
        else
            SV_VLAN_PREFLIGHT_CODE="helper_missing"
        fi
        echo "ERROR: VLAN helper 未安装或不是 root-owned 只读副本: $SV_VLAN_HELPER" >&2
        echo "       请先运行: sudo VLAN_TRUNK=1 UPLINK=<物理网卡> deploy/scripts/setup-bridge.sh" >&2
        return 1
    fi
    if ! sv_vlan_trusted_executable "$SV_VLAN_DOWNSCRIPT"; then
        if [[ -e "$SV_VLAN_DOWNSCRIPT" ]]; then
            SV_VLAN_PREFLIGHT_CODE="downscript_unsafe"
        else
            SV_VLAN_PREFLIGHT_CODE="downscript_missing"
        fi
        echo "ERROR: VLAN downscript 未安装或权限不安全: $SV_VLAN_DOWNSCRIPT" >&2
        echo "       请重新运行单 br0 VLAN_TRUNK 初始化。" >&2
        return 1
    fi
    if ! actual="$(sv_vlan_helper_call check "$INSTANCE" "$VLAN_ID")"; then
        SV_VLAN_PREFLIGHT_CODE="helper_check_failed"
        echo "ERROR: VLAN $VLAN_ID 的单 br0 宿主预检失败。" >&2
        echo "       请先运行: sudo VLAN_TRUNK=1 UPLINK=<物理网卡> deploy/scripts/setup-bridge.sh" >&2
        return 1
    fi
    if [[ "$actual" != "$VLAN_TAP_IF" ]]; then
        SV_VLAN_PREFLIGHT_CODE="tap_mismatch"
        echo "ERROR: VLAN helper 返回了非预期 TAP '$actual'（期望 '$VLAN_TAP_IF'）。" >&2
        return 1
    fi
}

# 自动初始化只接受与 root helper 相同的五字段配置。已有但权限/格式异常的配置
# 不能被交互流程直接覆盖，应由管理员先审计；配置不存在则属于正常首次安装。
sv_vlan_load_safe_config() {
    local line key value mode owner
    local -A seen=()

    SV_VLAN_CONFIG_UPLINK=""
    SV_VLAN_CONFIG_UID=""
    [[ -f "$SV_VLAN_CONFIG" && ! -L "$SV_VLAN_CONFIG" ]] || return 1
    owner="$(stat -c '%u' "$SV_VLAN_CONFIG" 2>/dev/null)" || return 1
    mode="$(stat -c '%a' "$SV_VLAN_CONFIG" 2>/dev/null)" || return 1
    [[ "$owner" == "0" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 8#22) == 0 )) || return 1

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        [[ "$line" =~ ^([A-Z_]+)=([^[:space:]]+)$ ]] || return 1
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        [[ -z "${seen[$key]:-}" ]] || return 1
        seen[$key]=1
        case "$key" in
            VERSION)     [[ "$value" == "1" ]] || return 1 ;;
            BRIDGE)      [[ "$value" == "br0" ]] || return 1 ;;
            UPLINK)      SV_VLAN_CONFIG_UPLINK="$value" ;;
            ALLOWED_UID) SV_VLAN_CONFIG_UID="$value" ;;
            ALLOWED_GID) [[ "$value" =~ ^[0-9]+$ ]] || return 1 ;;
            *) return 1 ;;
        esac
    done <"$SV_VLAN_CONFIG"
    [[ "${seen[VERSION]:-}" == "1" && "${seen[BRIDGE]:-}" == "1" \
        && "${seen[UPLINK]:-}" == "1" && "${seen[ALLOWED_UID]:-}" == "1" \
        && "${seen[ALLOWED_GID]:-}" == "1" \
        && "$SV_VLAN_CONFIG_UID" =~ ^[0-9]+$ ]] || return 1
    sv_vlan_candidate_valid "$SV_VLAN_CONFIG_UPLINK"
}

sv_vlan_candidate_valid() {
    local candidate="$1" details

    [[ -n "$candidate" && ${#candidate} -le 15 \
        && "$candidate" =~ ^[[:alnum:]_][[:alnum:]_.-]*$ ]] || return 1
    [[ "$candidate" != "." && "$candidate" != ".." \
        && "$candidate" != "lo" && "$candidate" != "br0" ]] || return 1
    [[ "$candidate" != svtap* && "$candidate" != tap* \
        && "$candidate" != vnet* ]] || return 1
    details="$(ip -o link show dev "$candidate" 2>/dev/null)" || return 1
    if [[ "$details" =~ [[:space:]]master[[:space:]]+([^[:space:]]+) \
        && "${BASH_REMATCH[1]}" != "br0" ]]; then
        return 1
    fi
    [[ ! -d "/sys/class/net/$candidate/wireless" ]]
}

sv_vlan_candidate_is_physical() {
    local candidate="$1" details

    sv_vlan_candidate_valid "$candidate" || return 1
    [[ -e "/sys/class/net/$candidate/device" ]] || return 1
    details="$(ip -d -o link show dev "$candidate" 2>/dev/null)" || return 1
    [[ ! "$details" =~ [[:space:]]vlan[[:space:]]+protocol[[:space:]] \
        && ! "$details" =~ [[:space:]]macvlan[[:space:]] \
        && ! "$details" =~ [[:space:]]macvtap[[:space:]] ]]
}

# 只在能唯一确定时返回候选：显式覆盖 → root 配置 → 唯一默认路由物理口 →
# br0 下唯一物理口 → 唯一 carrier-up 物理口。Wi-Fi、TAP/veth/VLAN 等不猜测。
sv_vlan_detect_uplink() {
    local candidate line
    local -a candidates=()

    if [[ -n "${VLAN_SETUP_UPLINK:-}" ]]; then
        # 显式覆盖只省略“唯一候选”推断，不放宽物理口/Wi-Fi/link-kind 校验。
        # 这样 veth、dummy 或 VLAN 子接口即使名字合法，也不能被确认流程接管。
        sv_vlan_candidate_is_physical "$VLAN_SETUP_UPLINK" || return 1
        printf '%s\n' "$VLAN_SETUP_UPLINK"
        return 0
    fi
    if sv_vlan_load_safe_config; then
        printf '%s\n' "$SV_VLAN_CONFIG_UPLINK"
        return 0
    fi

    while IFS= read -r candidate; do
        sv_vlan_candidate_is_physical "$candidate" && candidates+=("$candidate")
    done < <(ip -4 route show default 2>/dev/null | awk '
        { for (i=1; i<NF; i++) if ($i == "dev") print $(i+1) }
    ' | sort -u)
    if (( ${#candidates[@]} == 1 )); then
        printf '%s\n' "${candidates[0]}"
        return 0
    elif (( ${#candidates[@]} > 1 )); then
        return 1
    fi

    candidates=()
    while IFS= read -r line; do
        candidate="${line#*: }"
        candidate="${candidate%%:*}"
        candidate="${candidate%%@*}"
        sv_vlan_candidate_is_physical "$candidate" && candidates+=("$candidate")
    done < <(ip -o link show master br0 2>/dev/null || true)
    if (( ${#candidates[@]} == 1 )); then
        printf '%s\n' "${candidates[0]}"
        return 0
    elif (( ${#candidates[@]} > 1 )); then
        return 1
    fi

    candidates=()
    for line in /sys/class/net/*/device; do
        [[ -e "$line" ]] || continue
        candidate="${line%/device}"
        candidate="${candidate##*/}"
        [[ "$(cat "/sys/class/net/$candidate/carrier" 2>/dev/null || true)" == "1" ]] \
            && sv_vlan_candidate_is_physical "$candidate" \
            && candidates+=("$candidate")
    done
    (( ${#candidates[@]} == 1 )) || return 1
    printf '%s\n' "${candidates[0]}"
}

sv_vlan_uplink_has_native_conflict() {
    local uplink="$1"

    bridge vlan show dev "$uplink" 2>/dev/null | awk -v dev="$uplink" '
        NR > 1 {
            token = ($1 == dev && $2 ~ /^[0-9]+(-[0-9]+)?$/) ? $2 : $1
            for (i=2; i<=NF; i++)
                if (token != "1" && ($i == "PVID" || $i == "Egress" || $i == "Untagged")) bad=1
        }
        END { exit(bad ? 0 : 1) }
    '
}

# 自动 setup 会迁移宿主上联并重写全局 VLAN runtime 配置，因此它只能用于真正
# 的“从未启用过动态 TAP”的干净首次安装。host-vlan-tap.sh 用 root-only state
# 证明 svtapN 的归属；普通 VM 用户既不能安全枚举该目录，也不能判断其中 state
# 是否完整、是否属于仍在运行的其它实例。这里刻意采用只读、保守判定：
#
#   * 任意 svtap<数字> 都可能是正在使用或遗留的保留接口；
#   * state 目录即使看似为空，也可能因无读取权限或并发而无法可靠证明为空；
#   * 全局 helper lock 的存在说明 helper 曾开始过受保护的生命周期操作。
#
# 遇到任一痕迹都拒绝“自动修复”，交给管理员结合 root state/helper 人工清理。
# 函数返回 0 表示存在冲突，返回 1 才表示未发现冲突；全程不创建/删除任何路径。
sv_vlan_runtime_has_conflict() {
    local path ifname

    SV_VLAN_RUNTIME_CONFLICT=""
    if [[ ! -d "$SV_VLAN_SYS_CLASS_NET" || ! -r "$SV_VLAN_SYS_CLASS_NET" ]]; then
        SV_VLAN_RUNTIME_CONFLICT="无法只读审计网络接口目录 $SV_VLAN_SYS_CLASS_NET"
        return 0
    fi
    for path in "$SV_VLAN_SYS_CLASS_NET"/svtap*; do
        [[ -e "$path" || -L "$path" ]] || continue
        ifname="${path##*/}"
        if [[ "$ifname" =~ ^svtap[0-9]+$ ]]; then
            SV_VLAN_RUNTIME_CONFLICT="发现保留接口 $ifname（可能仍在使用或没有可信 state）"
            return 0
        fi
    done

    # `-L` 同时拦截断裂符号链接；这些固定 root runtime 路径只要类型异常，
    # 就更不能由普通用户启动器推测为安全的首次安装。
    if [[ -e "$SV_VLAN_STATE_DIR" || -L "$SV_VLAN_STATE_DIR" ]]; then
        SV_VLAN_RUNTIME_CONFLICT="发现既有 VLAN state 路径 $SV_VLAN_STATE_DIR"
        return 0
    fi
    if [[ -e "$SV_VLAN_LOCK_FILE" || -L "$SV_VLAN_LOCK_FILE" ]]; then
        SV_VLAN_RUNTIME_CONFLICT="发现既有 VLAN helper 锁 $SV_VLAN_LOCK_FILE"
        return 0
    fi
    return 1
}

# 返回 0 表示“明确属于首次 setup 可修复”；任何不可信文件、冲突接口、错误
# state/TAP 或授权用户不一致都返回非零，禁止用自动 setup 掩盖真实故障。
sv_vlan_setup_required() {
    local bridge_info uplink_info config_present=0

    case "$SV_VLAN_PREFLIGHT_CODE" in
        helper_unsafe|downscript_unsafe|tap_mismatch) return 1 ;;
        helper_missing|downscript_missing|helper_check_failed) ;;
        *) return 1 ;;
    esac
    if sv_vlan_runtime_has_conflict; then
        echo "ERROR: $SV_VLAN_RUNTIME_CONFLICT；拒绝自动初始化宿主网络。" >&2
        return 1
    fi
    if [[ -e "$SV_VLAN_CONFIG" ]]; then
        sv_vlan_load_safe_config || return 1
        config_present=1
        if (( EUID != 0 )) && [[ "$SV_VLAN_CONFIG_UID" != "$UID" ]]; then
            return 1
        fi
    fi

    bridge_info="$(ip -d -o link show dev br0 2>/dev/null || true)"
    if [[ -n "$bridge_info" \
        && ! "$bridge_info" =~ [[:space:]]bridge[[:space:]]+forward_delay[[:space:]] ]]; then
        return 1
    fi
    if (( config_present )); then
        uplink_info="$(ip -o link show dev "$SV_VLAN_CONFIG_UPLINK" 2>/dev/null || true)"
        [[ -n "$uplink_info" ]] || return 1
        sv_vlan_uplink_has_native_conflict "$SV_VLAN_CONFIG_UPLINK" && return 1
    fi

    [[ "$SV_VLAN_PREFLIGHT_CODE" != "helper_check_failed" ]] && return 0
    (( config_present )) || return 0
    [[ -n "$bridge_info" ]] || return 0
    [[ "$bridge_info" =~ [[:space:]]vlan_filtering[[:space:]]+1([[:space:]]|$) ]] \
        || return 0
    [[ "$uplink_info" =~ [[:space:]]master[[:space:]]+br0([[:space:]]|$) ]] \
        || return 0
    return 1
}

sv_vlan_can_offer_setup() {
    [[ "${DRY_RUN:-0}" != "1" && -z "${CI:-}" ]] || return 1
    (( EUID != 0 )) || return 1
    if [[ -n "${SSH_CONNECTION:-}${SSH_CLIENT:-}${SSH_TTY:-}" \
        && "${VLAN_SETUP_ALLOW_SSH:-0}" != "1" ]]; then
        return 1
    fi
    exec 6<>/dev/tty 2>/dev/null || return 1
    if [[ ! -t 6 ]]; then
        exec 6>&-
        return 1
    fi
    exec 6>&-
}

# 单独抽出读取函数，测试可覆写；生产始终从控制终端读取，不消费管道/stdin。
sv_vlan_read_answer() {
    local uplink="$1" answer

    printf '请输入 SETUP %s 确认一次性初始化，其他输入均取消: ' "$uplink" >/dev/tty
    IFS= read -r answer </dev/tty || return 1
    [[ "$answer" == "SETUP $uplink" ]]
}

sv_vlan_run_setup() {
    local uplink="$1" vm_user setup_script
    local -a command

    (( EUID != 0 )) || return 1
    vm_user="$(id -un)" || return 1
    [[ "$vm_user" =~ ^[[:alnum:]_.-]+\$?$ ]] || return 1
    setup_script="$HERE/setup-bridge.sh"
    [[ -x "$setup_script" && -x /usr/bin/sudo && -x /usr/bin/env ]] || return 1
    command=(/usr/bin/env -i
        PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root USER=root LOGNAME=root
        VLAN_TRUNK=1 VLAN_SETUP_AUTO=1 UPLINK="$uplink" VM_USER="$vm_user"
        "$setup_script")
    /usr/bin/sudo -H -- "${command[@]}"
}

sv_vlan_preflight() {
    local uplink mac

    sv_vlan_preflight_once && return 0
    [[ "${SV_VLAN_SETUP_ATTEMPTED:-0}" == "0" ]] || return 1
    if ! sv_vlan_setup_required; then
        echo "       当前故障不属于安全的一次性初始化场景，请按上方信息人工检查。" >&2
        return 1
    fi
    if ! sv_vlan_can_offer_setup; then
        echo "       当前为 DRY_RUN/非交互/root/CI，或 SSH 未显式允许；不会自动修改网络。" >&2
        echo "       手动执行: sudo VLAN_TRUNK=1 UPLINK=<物理网卡> deploy/scripts/setup-bridge.sh" >&2
        return 1
    fi
    if ! uplink="$(sv_vlan_detect_uplink)"; then
        echo "ERROR: 无法唯一识别安全的物理上联；可设置 VLAN_SETUP_UPLINK=<网卡> 后重试。" >&2
        return 1
    fi
    if sv_vlan_uplink_has_native_conflict "$uplink"; then
        echo "ERROR: 候选上联 $uplink 已有非 VID1 native/untagged 配置，拒绝自动初始化。" >&2
        return 1
    fi
    mac="$(cat "/sys/class/net/$uplink/address" 2>/dev/null || echo unknown)"
    echo >&2
    echo ">> 检测到 VLAN 宿主网络尚未完成一次性初始化。" >&2
    echo ">> 候选上联: $uplink (MAC $mac)" >&2
    echo ">> 将安装 root helper/sudoers、启用 br0 VLAN filtering，并迁移宿主网络。" >&2
    echo ">> 交换机必须已配置 VID 1 native/untagged，VLAN $VLAN_ID tagged。" >&2
    [[ -z "${SSH_CONNECTION:-}${SSH_CLIENT:-}${SSH_TTY:-}" ]] \
        || echo ">> 警告: 当前为 SSH，会话可能立即中断。" >&2
    if ! sv_vlan_read_answer "$uplink"; then
        echo ">> 已取消宿主网络初始化；VM 未启动。" >&2
        return 1
    fi

    SV_VLAN_SETUP_ATTEMPTED=1
    echo ">> 执行一次性初始化: VLAN_TRUNK=1 UPLINK=$uplink" >&2
    if ! sv_vlan_run_setup "$uplink"; then
        echo "ERROR: setup-bridge.sh 执行失败；VM 未启动。" >&2
        return 1
    fi
    echo ">> 初始化完成，重新检查 VLAN $VLAN_ID..." >&2
    sv_vlan_preflight_once
}

# CMD 已组装且 DRY_RUN 已退出后才真正创建 persistent TAP。prepare 内部先把
# TAP 设为 access/PVID untagged，再交给 QEMU，避免 VM 首包进入错误广播域。
sv_vlan_prepare() {
    local actual

    [[ -n "${VLAN_ID:-}" ]] || return 0
    if ! actual="$(sv_vlan_helper_call prepare "$INSTANCE" "$VLAN_ID")"; then
        echo "ERROR: 创建实例 $INSTANCE 的 VLAN $VLAN_ID TAP 失败。" >&2
        return 1
    fi
    if [[ "$actual" != "$VLAN_TAP_IF" ]]; then
        echo "ERROR: VLAN helper 创建了非预期 TAP '$actual'（期望 '$VLAN_TAP_IF'）。" >&2
        sv_vlan_helper_call cleanup-instance "$INSTANCE" >/dev/null 2>&1 || true
        return 1
    fi
    SV_VLAN_PREPARED=1
    echo ">> VLAN TAP:    $VLAN_TAP_IF (VID $VLAN_ID, guest access/untagged)"
}

# stop-vm.sh 使用的公共清理入口。helper 按 root-only 状态文件验证归属，因此
# 即使实例从未使用 VLAN 或已被 downscript 清理，也只会幂等返回成功。
sv_vlan_cleanup_instance() {
    local instance="$1"
    local tap

    [[ "$instance" =~ ^[0-9]{1,10}$ ]] || return 1
    tap="svtap${instance}"
    # 普通无 VLAN VM 没有该 TAP：直接返回，既不 sudo，也不改变原停机路径。
    ip link show dev "$tap" >/dev/null 2>&1 || return 0
    if ! sv_vlan_trusted_executable "$SV_VLAN_HELPER"; then
        echo "ERROR: 检测到 $tap，但 VLAN helper 缺失或权限不安全，无法清理。" >&2
        return 1
    fi
    sv_vlan_helper_call cleanup-instance "$instance"
}
