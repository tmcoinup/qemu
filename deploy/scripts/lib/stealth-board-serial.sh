#!/usr/bin/env bash
# 主板序列号的单一运行时策略。
#
# 固定厂商名称和格式来自 deploy/hardware/board-vendors.json；本模块只负责
# Linux 运行时生成、校验及旧 profile 兼容。新物理身份始终使用厂商严格格式；
# generic Q35 使用明确的虚拟模板格式。兼容入口只额外接受本项目历史生成器确实
# 产生过的格式。

if [[ "${_STEALTH_BOARD_SERIAL_LOADED:-0}" == "1" ]]; then
    # shellcheck disable=SC2317 # source guard 也兼容直接执行诊断。
    return 0 2>/dev/null || exit 0
fi
_STEALTH_BOARD_SERIAL_LOADED=1

stealth_board_vendor_token() {
    local manufacturer="$1"
    case "$manufacturer" in
        "ASUSTeK COMPUTER INC."|ASUS)
            printf '%s\n' asus
            ;;
        "Micro-Star International Co., Ltd."|MSI)
            printf '%s\n' msi
            ;;
        "Gigabyte Technology Co., Ltd."|GIGABYTE)
            printf '%s\n' gigabyte
            ;;
        ASRock)
            printf '%s\n' asrock
            ;;
        QEMU)
            printf '%s\n' qemu
            ;;
        *)
            return 1
            ;;
    esac
}

_stealth_board_msi_code() {
    local subsystem_device="${1:-${BOARD_SUBSYS_DEV:-}}"
    local product="${2:-${BOARD_PRODUCT:-}}"
    local subsystem_code="" product_code=""

    if [[ "$subsystem_device" =~ ^0[xX]([0-9A-Fa-f]{4})$ ]]; then
        subsystem_code="${BASH_REMATCH[1]^^}"
    fi
    if [[ "$product" =~ [Mm][Ss]-([0-9A-Za-z]{4}) ]]; then
        product_code="${BASH_REMATCH[1]^^}"
    fi
    if [[ -n "$subsystem_code" && -n "$product_code" &&
          "$subsystem_code" != "$product_code" ]]; then
        return 1
    fi
    if [[ -n "$product_code" ]]; then
        printf '%s\n' "$product_code"
    elif [[ -n "$subsystem_code" ]]; then
        printf '%s\n' "$subsystem_code"
    else
        return 1
    fi
}

_stealth_board_release_year_yy() {
    local release_year="${1:-${PLATFORM_RELEASE_YEAR:-}}"
    [[ "$release_year" =~ ^20[0-9]{2}$ ]] || return 1
    printf '%s\n' "${release_year:2:2}"
}

stealth_board_serial_is_strict() {
    local manufacturer="$1" serial="$2"
    local subsystem_device="${3:-${BOARD_SUBSYS_DEV:-}}"
    local product="${4:-${BOARD_PRODUCT:-}}"
    local token code week

    token="$(stealth_board_vendor_token "$manufacturer")" || return 1
    case "$token" in
        asus)
            [[ "$serial" =~ ^[A-Z0-9]{2}S[A-Z0-9]{9}$ ]]
            ;;
        msi)
            [[ "$serial" =~ ^601-([A-Z0-9]{4})-[A-Z0-9]{14}$ ]] ||
                return 1
            code="${BASH_REMATCH[1]}"
            [[ "$code" == "$(_stealth_board_msi_code \
                "$subsystem_device" "$product")" ]]
            ;;
        gigabyte)
            [[ "$serial" =~ ^SN[0-9]{12}$ ]] || return 1
            week="${serial:4:2}"
            (( 10#$week >= 1 && 10#$week <= 53 ))
            ;;
        asrock)
            [[ "$serial" =~ ^[A-Z0-9]{12}$ ]]
            ;;
        qemu)
            [[ "$serial" =~ ^MB[0-9]{12}$ &&
               "${serial:2}" != "000000000000" ]]
            ;;
    esac
}

stealth_board_serial_is_legacy() {
    local manufacturer="$1" serial="$2" token
    token="$(stealth_board_vendor_token "$manufacturer")" || return 1
    case "$token" in
        asus)
            [[ "$serial" =~ ^MB-[0-9A-F]{6}[0-9]{5}$ ]]
            ;;
        msi)
            [[ "$serial" =~ ^[0-9A-F]{4}[0-9]{6}$ ]]
            ;;
        gigabyte)
            [[ "$serial" =~ ^SN[0-9]{8}$ ]]
            ;;
        asrock)
            [[ "$serial" =~ ^M80-[0-9A-F]{4}[0-9]{4}$ ]]
            ;;
        qemu)
            [[ "$serial" =~ ^QEMU-[0-9A-F]{8}[0-9]{4}$ ]]
            ;;
    esac
}

stealth_board_serial_is_compatible() {
    stealth_board_serial_is_strict "$@" ||
        stealth_board_serial_is_legacy "$1" "$2"
}

_stealth_board_random_upper_alnum() {
    local width="$1" value
    value="$(_hex "$width")" || return 1
    printf '%s\n' "${value^^}"
}

_serial_asus() {
    local prefix suffix
    prefix="$(_stealth_board_random_upper_alnum 2)" || return 1
    suffix="$(_stealth_board_random_upper_alnum 9)" || return 1
    printf '%sS%s\n' "$prefix" "$suffix"
}

_serial_msi() {
    local code suffix
    code="$(_stealth_board_msi_code)" || {
        echo "ERROR: MSI 主板缺少可审计的四位 board code" >&2
        return 1
    }
    suffix="$(_stealth_board_random_upper_alnum 14)" || return 1
    printf '601-%s-%s\n' "$code" "$suffix"
}

_serial_giga() {
    local yy week suffix
    yy="$(_stealth_board_release_year_yy)" || {
        echo "ERROR: GIGABYTE 主板缺少四位发布年份" >&2
        return 1
    }
    week="$(_rand 1 53)" || return 1
    suffix="$(_rand 0 99999999)" || return 1
    printf 'SN%s%02d%08d\n' "$yy" "$week" "$suffix"
}

_serial_asr() {
    _stealth_board_random_upper_alnum 12
}

_stealth_stable_board_serial() {
    local manufacturer="$1" key="$2"
    local token code yy week suffix prefix

    if ! declare -F _stealth_stable_hex >/dev/null 2>&1 ||
       ! declare -F _stealth_stable_dec_range >/dev/null 2>&1; then
        echo "ERROR: 稳定主板序列号派生器尚未加载" >&2
        return 1
    fi
    token="$(stealth_board_vendor_token "$manufacturer")" || {
        echo "ERROR: 不支持的主板厂商: $manufacturer" >&2
        return 1
    }
    case "$token" in
        asus)
            prefix="$(_stealth_stable_hex "$key-asus-prefix" 2)" ||
                return 1
            suffix="$(_stealth_stable_hex "$key-asus-suffix" 9)" ||
                return 1
            printf '%sS%s\n' "$prefix" "$suffix"
            ;;
        msi)
            code="$(_stealth_board_msi_code)" || {
                echo "ERROR: MSI profile 缺少可审计的四位 board code" >&2
                return 1
            }
            suffix="$(_stealth_stable_hex "$key-msi-suffix" 14)" ||
                return 1
            printf '601-%s-%s\n' "$code" "$suffix"
            ;;
        gigabyte)
            yy="$(_stealth_board_release_year_yy)" || {
                echo "ERROR: GIGABYTE profile 缺少四位发布年份" >&2
                return 1
            }
            week="$(_stealth_stable_dec_range "$key-giga-week" 1 53)" ||
                return 1
            suffix="$(_stealth_stable_dec_range \
                "$key-giga-suffix" 0 99999999)" || return 1
            printf 'SN%s%02d%08d\n' "$yy" "$week" "$suffix"
            ;;
        asrock)
            _stealth_stable_hex "$key-asrock" 12
            ;;
        qemu)
            suffix="$(_stealth_stable_dec_range \
                "$key-qemu" 1 999999999999)" || return 1
            printf 'MB%012d\n' "$suffix"
            ;;
    esac
}
