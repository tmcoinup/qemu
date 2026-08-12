#!/usr/bin/env bash
# 在 Linux 主机上关闭本地 PCIe NVMe 的 APST（Autonomous Power State Transition）。
#
# 设计目标：
#   1. 不按品牌、容量或 PCIe 代际写白名单，NVMe 1.x/2.x、PCIe 3/4/5 均走标准接口。
#   2. 默认处理全部本地 PCIe NVMe 控制器；NVMe-oF、SATA、SAS 自动排除。
#   3. 先写入持久化配置，再逐控制器限时在线关闭；失败会记录并继续处理其他盘。
#   4. 不重启、不重置控制器、不卸载文件系统，运行中的虚拟机不会被脚本主动中断。
set -euo pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly APST_ARG="nvme_core.default_ps_max_latency_us=0"
readonly FEATURE_ID="0x0c"
readonly MANAGED_MARKER="VMATE_NVME_APST_MANAGED=1"

# 测试根目录只用于仓库回归测试，让所有写操作落入临时目录。
TEST_ROOT="${VMATE_APST_TEST_ROOT:-}"
if [[ -n "$TEST_ROOT" ]]; then
    [[ "$TEST_ROOT" == /* && "$TEST_ROOT" != "/" ]] || {
        echo "错误：VMATE_APST_TEST_ROOT 必须是非根绝对路径。" >&2
        exit 2
    }
    TEST_ROOT="${TEST_ROOT%/}"
    SYS_ROOT="$TEST_ROOT/sys"
    DEV_ROOT="$TEST_ROOT/dev"
    ETC_ROOT="$TEST_ROOT/etc"
    BOOT_ROOT="$TEST_ROOT/boot"
    CMDLINE_FILE="$TEST_ROOT/proc/cmdline"
    PATH="${VMATE_APST_TEST_BIN:-$TEST_ROOT/bin}:/usr/sbin:/usr/bin:/sbin:/bin"
else
    SYS_ROOT="/sys"
    DEV_ROOT="/dev"
    ETC_ROOT="/etc"
    BOOT_ROOT="/boot"
    CMDLINE_FILE="/proc/cmdline"
    PATH="/usr/sbin:/usr/bin:/sbin:/bin"
fi
export PATH

readonly MODULE_PARAM="$SYS_ROOT/module/nvme_core/parameters/default_ps_max_latency_us"
readonly MODPROBE_CONF="$ETC_ROOT/modprobe.d/99-nvme-apst-off.conf"
readonly GRUB_FRAGMENT="$ETC_ROOT/default/grub.d/99-nvme-apst-off.cfg"
readonly ADMIN_TIMEOUT="${VMATE_APST_ADMIN_TIMEOUT:-15}"

declare -a CONTROLLERS=()
FEATURE_VALUE=""
FEATURE_OUTPUT=""
FEATURE_RC=0
LIVE_PENDING=0

log() { printf '%s\n' "$*"; }
warn() { printf '警告：%s\n' "$*" >&2; }
die() { printf '错误：%s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
用法：
  $SCRIPT_NAME check   [all|/dev/nvme0 ...]   # 只读检查（默认动作）
  sudo $SCRIPT_NAME apply   [all|/dev/nvme0 ...]   # 持久化并尝试立即关闭
  sudo $SCRIPT_NAME persist [all|/dev/nvme0 ...]   # 仅配置下次启动关闭
  sudo $SCRIPT_NAME verify  [all|/dev/nvme0 ...]   # 严格验证当前状态

说明：设备参数只限制检查和在线操作；内核启动参数会作用于全部 NVMe。
EOF
}

require_root() {
    if [[ -z "$TEST_ROOT" && ${EUID:-$(id -u)} -ne 0 ]]; then
        die "此动作需要 root，请使用 sudo $SCRIPT_NAME $*"
    fi
}

validate_timeout() {
    [[ "$ADMIN_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "管理命令超时必须是正整数"
    (( ADMIN_TIMEOUT <= 60 )) || die "管理命令超时不能超过 60 秒"
}

trim_file() {
    local file="$1" value=""
    if [[ -r "$file" ]]; then
        IFS= read -r value <"$file" || true
    fi
    value="${value//$'\000'/}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

controller_transport() {
    local name="$1" transport real
    transport="$(trim_file "$SYS_ROOT/class/nvme/$name/transport")"
    if [[ -n "$transport" ]]; then
        printf '%s' "$transport"
        return
    fi
    real="$(readlink -f "$SYS_ROOT/class/nvme/$name" 2>/dev/null || true)"
    [[ "$real" == *"/pci"* ]] && printf 'pcie' || printf 'unknown'
}

add_controller() {
    local name="$1" existing
    for existing in "${CONTROLLERS[@]}"; do
        [[ "$existing" == "$name" ]] && return
    done
    CONTROLLERS+=("$name")
}

discover_controllers() {
    local requested=("$@") path name transport
    CONTROLLERS=()
    if (( ${#requested[@]} == 0 )) || [[ "${requested[0]}" == all ]]; then
        (( ${#requested[@]} <= 1 )) || die "all 不能与具体控制器同时使用"
        shopt -s nullglob
        for path in "$SYS_ROOT"/class/nvme/nvme*; do
            name="${path##*/}"
            [[ "$name" =~ ^nvme[0-9]+$ ]] || continue
            transport="$(controller_transport "$name")"
            [[ "$transport" == pcie ]] && add_controller "$name"
        done
        shopt -u nullglob
        return
    fi

    for path in "${requested[@]}"; do
        name="${path##*/}"
        [[ "$name" =~ ^nvme[0-9]+$ ]] ||
            die "仅接受 NVMe 控制器（如 /dev/nvme0），不能传命名空间或分区：$path"
        [[ -d "$SYS_ROOT/class/nvme/$name" ]] || die "控制器不存在：$path"
        transport="$(controller_transport "$name")"
        [[ "$transport" == pcie ]] ||
            die "$path 的传输类型是 $transport，不是本地 PCIe NVMe"
        add_controller "$name"
    done
}

pcie_description() {
    local name="$1" speed width generation="未知代际"
    speed="$(trim_file "$SYS_ROOT/class/nvme/$name/device/current_link_speed")"
    width="$(trim_file "$SYS_ROOT/class/nvme/$name/device/current_link_width")"
    case "$speed" in
        2.5\ GT/s*) generation="PCIe 1.0" ;;
        5.0\ GT/s*|5\ GT/s*) generation="PCIe 2.0" ;;
        8.0\ GT/s*|8\ GT/s*) generation="PCIe 3.0" ;;
        16.0\ GT/s*|16\ GT/s*) generation="PCIe 4.0" ;;
        32.0\ GT/s*|32\ GT/s*) generation="PCIe 5.0" ;;
        64.0\ GT/s*|64\ GT/s*) generation="PCIe 6.0" ;;
    esac
    [[ -n "$width" ]] && printf '%s x%s（%s）' "$generation" "$width" "$speed" ||
        printf '%s（%s）' "$generation" "${speed:-链路信息不可用}"
}

last_cmdline_value() {
    local token value=""
    local -a tokens=()
    [[ -r "$CMDLINE_FILE" ]] || return 1
    read -ra tokens <"$CMDLINE_FILE" || true
    for token in "${tokens[@]}"; do
        case "$token" in
            nvme_core.default_ps_max_latency_us=*) value="${token#*=}" ;;
        esac
    done
    printf '%s' "$value"
}

show_global_state() {
    local cmd_value module_value
    cmd_value="$(last_cmdline_value || true)"
    module_value="$(trim_file "$MODULE_PARAM")"
    if [[ "$cmd_value" == 0 ]]; then
        log "  当前启动参数：已关闭（最后一个值为 0）"
    else
        log "  当前启动参数：未生效（值：${cmd_value:-缺失}）"
    fi
    if [[ "$module_value" == 0 ]]; then
        log "  内核模块参数：0（已关闭）"
    else
        log "  内核模块参数：${module_value:-不可用}"
    fi
}

device_node() { printf '%s/%s' "$DEV_ROOT" "$1"; }
display_node() { printf '/dev/%s' "$1"; }

feature_is_unsupported() {
    [[ "$FEATURE_OUTPUT" =~ [Ii]nvalid[[:space:]_-]*[Ff]ield|[Nn]ot[[:space:]]+[Ss]upport|[Uu]nsupported ]]
}

read_feature() {
    local name="$1" node output rc value
    FEATURE_VALUE=""; FEATURE_OUTPUT=""; FEATURE_RC=0
    node="$(device_node "$name")"
    if [[ -z "$TEST_ROOT" ]]; then
        [[ -c "$node" ]] || { FEATURE_RC=66; FEATURE_OUTPUT="缺少控制器字符设备"; return; }
    else
        [[ -e "$node" ]] || { FEATURE_RC=66; FEATURE_OUTPUT="缺少测试设备"; return; }
    fi
    set +e
    output="$(timeout --signal=INT --kill-after=2s "${ADMIN_TIMEOUT}s" \
        nvme get-feature "$node" -f "$FEATURE_ID" -H 2>&1)"
    rc=$?
    set -e
    value="$(printf '%s\n' "$output" | sed -nE \
        's/.*[Cc]urrent[[:space:]]+[Vv]alue[=:][[:space:]]*(0x)?([0-9a-fA-F]+).*/\2/p' |
        head -n 1 || true)"
    FEATURE_OUTPUT="$output"; FEATURE_RC=$rc
    [[ $rc -eq 0 && -n "$value" ]] && FEATURE_VALUE=$((16#$value))
    return 0
}

short_error() {
    local text="$1" first
    first="${text%%$'\n'*}"
    printf '%s' "${first:0:180}"
}

show_controller() {
    local name="$1" inspect_feature="${2:-1}" model firmware state real part bdf="未知"
    local -a parts=()
    model="$(trim_file "$SYS_ROOT/class/nvme/$name/model")"
    firmware="$(trim_file "$SYS_ROOT/class/nvme/$name/firmware_rev")"
    state="$(trim_file "$SYS_ROOT/class/nvme/$name/state")"
    real="$(readlink -f "$SYS_ROOT/class/nvme/$name" 2>/dev/null || true)"
    IFS='/' read -ra parts <<<"$real"
    for part in "${parts[@]}"; do
        [[ "$part" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$ ]] && bdf="$part"
    done
    log "$(display_node "$name")：${model:-未知型号}，固件 ${firmware:-未知}，状态 ${state:-未知}"
    log "  总线：$(pcie_description "$name")，BDF $bdf"
    if [[ "$inspect_feature" != 1 ]]; then
        return
    elif ! command -v nvme >/dev/null 2>&1; then
        log "  APST Feature：未检查（缺少 nvme-cli）"
    elif [[ -z "$TEST_ROOT" && ${EUID:-$(id -u)} -ne 0 ]]; then
        log "  APST Feature：未检查（需要 sudo）"
    else
        read_feature "$name"
        if [[ -n "$FEATURE_VALUE" ]]; then
            if (( FEATURE_VALUE == 0 )); then
                log "  APST Feature：0（已关闭）"
            else
                log "  APST Feature：$FEATURE_VALUE（仍开启）"
            fi
        elif (( FEATURE_RC == 124 || FEATURE_RC == 137 )); then
            log "  APST Feature：读取超时（固件未响应）"
        elif feature_is_unsupported; then
            log "  APST Feature：控制器不支持（无需在线设置）"
        else
            log "  APST Feature：读取失败（$(short_error "$FEATURE_OUTPUT")）"
        fi
    fi
}

backup_if_unmanaged() {
    local target="$1" backup
    [[ -e "$target" ]] || return 0
    if grep -Fq "$MANAGED_MARKER" "$target" 2>/dev/null ||
       grep -Fq '由 qemu/deploy/scripts/host-nvme-apst.sh 管理' "$target" 2>/dev/null; then
        return 0
    fi
    backup="${target}.bak.$(date -u +%Y%m%dT%H%M%SZ).$$"
    cp -a -- "$target" "$backup"
    warn "保留了原配置备份：$backup"
}

atomic_write() {
    local target="$1" mode="$2" temp
    mkdir -p -- "${target%/*}"
    temp="$(mktemp "${target}.tmp.XXXXXX")"
    if ! cat >"$temp"; then rm -f -- "$temp"; die "无法写入 $target"; fi
    chmod "$mode" "$temp"
    mv -f -- "$temp" "$target"
}

write_common_config() {
    backup_if_unmanaged "$MODPROBE_CONF"
    atomic_write "$MODPROBE_CONF" 0644 <<EOF
# $MANAGED_MARKER
# 对以模块方式加载的 nvme_core 生效；内建驱动由启动参数覆盖。
options nvme_core default_ps_max_latency_us=0
EOF
}

write_grub_fragment() {
    backup_if_unmanaged "$GRUB_FRAGMENT"
    atomic_write "$GRUB_FRAGMENT" 0644 <<'EOF'
# VMATE_NVME_APST_MANAGED=1
# 清理两个 GRUB 变量中的冲突值，再把 APST=0 放到最终命令行末尾。
_vmate_strip_nvme_apst() {
    printf '%s\n' "$1" | sed -E \
        -e 's/(^|[[:space:]])nvme_core\.default_ps_max_latency_us=[^[:space:]]+//g' \
        -e 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g'
}
GRUB_CMDLINE_LINUX="$(_vmate_strip_nvme_apst "${GRUB_CMDLINE_LINUX-}")"
GRUB_CMDLINE_LINUX_DEFAULT="$(_vmate_strip_nvme_apst "${GRUB_CMDLINE_LINUX_DEFAULT-}")"
GRUB_CMDLINE_LINUX_DEFAULT="\
${GRUB_CMDLINE_LINUX_DEFAULT:+${GRUB_CMDLINE_LINUX_DEFAULT} }\
nvme_core.default_ps_max_latency_us=0"
unset -f _vmate_strip_nvme_apst
EOF
}

verify_generated_grub() {
    local cfg
    for cfg in "$BOOT_ROOT/grub/grub.cfg" "$BOOT_ROOT/grub2/grub.cfg"; do
        [[ -r "$cfg" ]] || continue
        grep -Fq "$APST_ARG" "$cfg" || die "已生成 $cfg，但其中没有 $APST_ARG"
        if grep -Eq 'nvme_core\.default_ps_max_latency_us=([^0[:space:]]|0[^[:space:]])' "$cfg"; then
            die "已生成 $cfg，但其中仍有与 $APST_ARG 冲突的值"
        fi
        return
    done
    warn "未找到可读取的 grub.cfg；生成命令成功，但无法二次核对"
}

persist_boot_argument() {
    local grubby_info
    if command -v update-grub >/dev/null 2>&1; then
        write_grub_fragment
        log "正在更新 GRUB（update-grub）…"
        update-grub
        verify_generated_grub
    elif command -v grubby >/dev/null 2>&1; then
        log "正在更新全部 BLS/GRUB 内核项（grubby）…"
        grubby --update-kernel=ALL \
            --remove-args="nvme_core.default_ps_max_latency_us" --args="$APST_ARG"
        grubby_info="$(grubby --info=ALL)"
        grep -Fq "$APST_ARG" <<<"$grubby_info" || die "grubby 未写入 $APST_ARG"
        if grep -Eq 'nvme_core\.default_ps_max_latency_us=([^0[:space:]]|0[^[:space:]])' \
                <<<"$grubby_info"; then
            die "grubby 输出中仍有与 $APST_ARG 冲突的值"
        fi
    else
        die "未找到 update-grub 或 grubby；未自动改动未知引导器"
    fi
}

ensure_nvme_cli() {
    command -v timeout >/dev/null 2>&1 || die "缺少 coreutils 的 timeout 命令"
    command -v nvme >/dev/null 2>&1 && return
    [[ -z "$TEST_ROOT" ]] || die "测试环境缺少 nvme 假命令"
    log "未安装 nvme-cli，正在通过系统包管理器安装…"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update && apt-get install -y nvme-cli
    elif command -v dnf >/dev/null 2>&1; then dnf install -y nvme-cli
    elif command -v yum >/dev/null 2>&1; then yum install -y nvme-cli
    elif command -v zypper >/dev/null 2>&1; then zypper --non-interactive install nvme-cli
    elif command -v pacman >/dev/null 2>&1; then pacman -S --needed --noconfirm nvme-cli
    else die "缺少 nvme-cli，且未识别到受支持的包管理器"; fi
    command -v nvme >/dev/null 2>&1 || die "nvme-cli 安装后仍不可用"
}

persist_configuration() {
    write_common_config
    persist_boot_argument
    log "持久化完成：后续启动会对全部 NVMe 使用 $APST_ARG"
}

set_runtime_parameter() {
    if [[ -e "$MODULE_PARAM" && -w "$MODULE_PARAM" ]]; then
        printf '0\n' >"$MODULE_PARAM"
        [[ "$(trim_file "$MODULE_PARAM")" == 0 ]] || die "内核参数写入后不是 0"
        log "内核运行时默认值已设为 0。"
    else
        warn "当前内核参数不可写；持久化已完成，重启后生效"
        LIVE_PENDING=1
    fi
}

disable_controller_live() {
    local name="$1" node output rc detail
    node="$(device_node "$name")"
    read_feature "$name"
    if [[ "$FEATURE_VALUE" == 0 ]]; then
        log "$(display_node "$name")：APST 已关闭，无需重复设置。"
        return
    fi
    if feature_is_unsupported; then
        log "$(display_node "$name")：不支持 APST，跳过在线设置。"
        return
    fi
    if [[ -z "$FEATURE_VALUE" ]]; then
        detail="$(short_error "$FEATURE_OUTPUT")"
        (( FEATURE_RC == 124 || FEATURE_RC == 137 )) && detail="读取管理命令超时"
        warn "$(display_node "$name") 无法确认当前 Feature（${detail:-未知错误}）；" \
            "为避免连续发送管理命令，跳过在线设置并等待重启"
        LIVE_PENDING=1
        return
    fi
    log "$(display_node "$name")：正在限时关闭 APST…"
    set +e
    output="$(timeout --signal=INT --kill-after=2s "${ADMIN_TIMEOUT}s" \
        nvme set-feature "$node" -f "$FEATURE_ID" -v 0 2>&1)"
    rc=$?
    set -e
    if (( rc != 0 )); then
        warn "$(display_node "$name") 在线设置失败/超时" \
            "（rc=$rc，$(short_error "$output")）；重启后由内核参数关闭"
        LIVE_PENDING=1
        return
    fi
    read_feature "$name"
    if [[ "$FEATURE_VALUE" == 0 ]]; then
        log "$(display_node "$name")：在线验证通过，APST=0。"
    else
        warn "$(display_node "$name") 在线设置后未验证为 0；请重启后再运行 verify"
        LIVE_PENDING=1
    fi
}

verify_current() {
    local failed=0 name module_value cmd_value
    cmd_value="$(last_cmdline_value || true)"
    module_value="$(trim_file "$MODULE_PARAM")"
    [[ "$cmd_value" == 0 ]] || { warn "当前启动参数最后值不是 0（${cmd_value:-缺失}）"; failed=1; }
    [[ "$module_value" == 0 ]] || { warn "内核模块参数不是 0（${module_value:-不可用}）"; failed=1; }
    ensure_nvme_cli
    for name in "${CONTROLLERS[@]}"; do
        read_feature "$name"
        if [[ "$FEATURE_VALUE" == 0 ]]; then
            log "$(display_node "$name")：APST=0，通过。"
        elif feature_is_unsupported; then
            log "$(display_node "$name")：控制器不支持 APST，跳过。"
        else
            warn "$(display_node "$name") 未验证为 0（$(short_error "$FEATURE_OUTPUT")）"
            failed=1
        fi
    done
    (( failed == 0 )) || die "APST 严格验证失败"
    log "验证通过：启动参数、内核默认值和全部目标控制器均已关闭 APST。"
}

main() {
    local action="${1:-check}" name
    case "$action" in
        check|apply|persist|verify)
            if (( $# > 0 )); then shift; fi
            ;;
        -h|--help|help) usage; return ;;
        *) die "未知动作：$action（使用 --help 查看用法）" ;;
    esac
    validate_timeout
    discover_controllers "$@"
    log "NVMe APST 状态："
    show_global_state
    if (( ${#CONTROLLERS[@]} == 0 )); then
        log "未发现本地 PCIe NVMe 控制器；SATA/SAS 不使用 NVMe APST，无需处理。"
        [[ "$action" == check ]] && return
        die "没有可处理的本地 PCIe NVMe 控制器"
    fi
    for name in "${CONTROLLERS[@]}"; do
        if [[ "$action" == check ]]; then
            show_controller "$name" 1
        else
            show_controller "$name" 0
        fi
    done
    case "$action" in
        check) return ;;
        persist) require_root persist; persist_configuration ;;
        apply)
            require_root apply
            persist_configuration
            ensure_nvme_cli
            set_runtime_parameter
            for name in "${CONTROLLERS[@]}"; do disable_controller_live "$name"; done
            if (( LIVE_PENDING == 0 )); then
                log "完成：当前系统与后续启动均已关闭 APST。"
            else
                log "持久化已完成；部分在线操作未响应，请正常重启后运行 verify。"
            fi
            ;;
        verify) require_root verify; verify_current ;;
    esac
}

main "$@"
