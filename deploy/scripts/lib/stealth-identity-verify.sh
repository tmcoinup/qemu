#!/usr/bin/env bash
# 严格硬件 profile 的可变身份校验。
#
# 平台/部件校验器负责固定型号事实；本文件只验证每台实例可变的 UUID、MAC 和
# 序列号。严格模式必须在兼容修复发生前调用，避免损坏或缺失值被静默补齐后过关。

if [[ "${_STEALTH_IDENTITY_VERIFY_LOADED:-0}" == "1" ]]; then
    return 0 2>/dev/null || exit 0
fi
_STEALTH_IDENTITY_VERIFY_LOADED=1

_STEALTH_IDENTITY_VERIFY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=stealth-board-serial.sh
source "$_STEALTH_IDENTITY_VERIFY_DIR/stealth-board-serial.sh"

_stealth_identity_error() {
    printf 'ERROR: 严格 profile 身份字段非法: %s\n' "$*" >&2
    return 1
}

_stealth_identity_require_keys() {
    local present_array_name="$1"
    shift
    local -n present_keys="$present_array_name"
    local field

    for field in "$@"; do
        if [[ -z "${present_keys[$field]:-}" ]] || ! [[ -v $field ]]; then
            _stealth_identity_error "缺少 $field"
            return 1
        fi
    done
}

_stealth_identity_is_global_unicast() {
    local mac="$1" first_octet
    first_octet=$((16#${mac%%:*}))
    (( (first_octet & 3) == 0 ))
}

_stealth_memory_slot_serial() {
    local base="$1" slot="$2" attempt seed digest serial

    [[ "$base" =~ ^[0-9A-F]{8}$ && "$slot" =~ ^[1-9][0-9]*$ ]] || return 2
    for ((attempt = 0; attempt < 256; attempt++)); do
        seed="${base}-dimm${slot}"
        (( attempt == 0 )) || seed+="-${attempt}"
        digest="$(printf '%s' "$seed" | sha256sum)" || return 2
        serial="${digest:0:8}"
        serial="${serial^^}"
        if [[ "$serial" != "$base" && "$serial" != "00000000" &&
              "$serial" != "00000001" && "$serial" != "FFFFFFFF" ]]; then
            printf '%s\n' "$serial"
            return 0
        fi
    done
    return 2
}

_stealth_identity_hid_serial_is_valid() {
    local serial="$1"
    local component_id="$2"
    local prefix="${component_id^^}"
    local suffix

    # 2026-07-19 之前的生成器使用 6 位 A-Z0-9 随机后缀，之后的新身份收窄为
    # 十六进制。两者都只是在 profile 内部保存的稳定 token，USB descriptor
    # 不向 Guest 暴露 iSerialNumber，因此旧字母数字值必须继续可加载。前四位
    # 仍由组件 ID 派生，避免把 UNKNOWN 等任意占位串误当成合法历史身份。
    prefix="${prefix//[^A-Z0-9]/}"
    prefix="${prefix:0:4}"
    [[ -n "$prefix" ]] || prefix=HID
    [[ "$serial" == "$prefix"* ]] || return 1
    suffix="${serial:${#prefix}}"
    [[ "$suffix" =~ ^[A-Z0-9]{6}$ ]] || return 1
    [[ "$suffix" != "000000" && "$suffix" != "FFFFFF" ]]
}

stealth_verify_profile_identity_inputs() {
    local present_array_name="$1"
    local migration_kind="${2:-none}"
    local field value suffix
    local -A seen=()
    local required=(
        UUID CPU_SERIAL CPU_ASSET BOARD_SERIAL BOARD_ASSET SYSTEM_SERIAL
        SYSTEM_SKU CHASSIS_SERIAL NIC_MAC NIC_MAC_OUI NVME_SERIAL
        NVME_SUBNQN_TEMPLATE NVME_SUBNQN MEM_SERIAL EDID_SERIAL
        KBD_SERIAL MOUSE_SERIAL TABLET_SERIAL
    )

    _stealth_identity_require_keys "$present_array_name" "${required[@]}" ||
        return 1
    case "$migration_kind" in
        none|legacy-nvme-v1|legacy-nvme-v2|legacy-sata-v1|legacy-sata-v2|legacy-nvme-part-number-v1|samsung-970-pro-catalog-v2) ;;
        *)
            _stealth_identity_error "未知启动盘迁移身份模式 $migration_kind"
            return 1
            ;;
    esac

    [[ "$UUID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] ||
        _stealth_identity_error "UUID 不是规范的小写 RFC 4122 v4 值" || return 1
    [[ "$UUID" != "00000000-0000-4000-8000-000000000000" &&
       "$UUID" != "ffffffff-ffff-4fff-bfff-ffffffffffff" ]] ||
        _stealth_identity_error "UUID 是全零或全 F 占位值" || return 1
    [[ "$CPU_SERIAL" =~ ^[1-9][0-9]{9}$ ]] ||
        _stealth_identity_error "CPU_SERIAL 必须是非占位十位十进制值" || return 1
    [[ "$CPU_ASSET" =~ ^[1-9][0-9]{3}$ ]] ||
        _stealth_identity_error "CPU_ASSET 必须是非占位四位十进制值" || return 1
    stealth_board_serial_is_compatible "$BOARD_MFR" "$BOARD_SERIAL" ||
        _stealth_identity_error \
            "BOARD_SERIAL 不符合 $BOARD_MFR 的厂商格式" || return 1
    [[ "$BOARD_ASSET" =~ ^[1-9][0-9]{9}$ ]] ||
        _stealth_identity_error "BOARD_ASSET 必须是非占位十位十进制值" || return 1
    stealth_board_serial_is_compatible "$SYSTEM_MFR" "$SYSTEM_SERIAL" ||
        _stealth_identity_error \
            "SYSTEM_SERIAL 不符合 $SYSTEM_MFR 的厂商格式" || return 1
    [[ "$SYSTEM_SKU" =~ ^SKU[1-9][0-9]{5}$ ]] ||
        _stealth_identity_error "SYSTEM_SKU 必须是非占位 SKU 值" || return 1
    stealth_board_serial_is_compatible "$BOARD_MFR" "$CHASSIS_SERIAL" ||
        _stealth_identity_error \
            "CHASSIS_SERIAL 不符合 $BOARD_MFR 的厂商格式" || return 1

    [[ "$NIC_MAC_OUI" =~ ^([0-9a-f]{2}:){2}[0-9a-f]{2}$ ]] ||
        _stealth_identity_error "NIC_MAC_OUI 必须是小写三字节 OUI" || return 1
    [[ "$NIC_MAC" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] ||
        _stealth_identity_error "NIC_MAC 格式错误" || return 1
    [[ "$NIC_MAC" == "$NIC_MAC_OUI":* ]] ||
        _stealth_identity_error "NIC_MAC 没有使用平台绑定 OUI" || return 1
    _stealth_identity_is_global_unicast "$NIC_MAC" ||
        _stealth_identity_error "NIC_MAC 不是全局单播地址" || return 1
    suffix="${NIC_MAC#"$NIC_MAC_OUI":}"
    [[ "${suffix//:/}" != "000000" && "${suffix//:/}" != "ffffff" ]] ||
        _stealth_identity_error "NIC_MAC 使用全零或全 F 占位后缀" || return 1

    if [[ "$migration_kind" == samsung-970-pro-catalog-v2 ||
          "$migration_kind" == legacy-nvme-v2 ||
          "$migration_kind" == legacy-sata-v2 ]]; then
        [[ "$NVME_SERIAL" =~ ^S[A-Z0-9]{3}N[A-Z0-9]{9}$ &&
           "$NVME_SERIAL" != S000N000000000 &&
           "$NVME_SERIAL" != SFFFNFFFFFFFFF ]] ||
            _stealth_identity_error \
                "旧 970 PRO NVME_SERIAL 不是受支持的 14 字符目录形态" ||
            return 1
        [[ "$NVME_SUBNQN_TEMPLATE" == \
            "nqn.2014-08.org.nvmexpress:uuid:{uuid}" &&
           "$NVME_SUBNQN" == \
            "nqn.2014-08.org.nvmexpress:uuid:$UUID" ]] ||
            _stealth_identity_error "旧 970 PRO NQN 未绑定持久 UUID" ||
            return 1
    elif [[ "$migration_kind" == legacy-nvme-v1 ||
          "$migration_kind" == legacy-sata-v1 ]]; then
        [[ "$NVME_SERIAL" =~ ^S[0-9A-F]{10}N$ ]] ||
            _stealth_identity_error "旧 NVME_SERIAL 不符合 S<10 hex>N 格式" ||
            return 1
        [[ "$NVME_SERIAL" != "S0000000000N" &&
           "$NVME_SERIAL" != "SFFFFFFFFFFN" ]] ||
            _stealth_identity_error "旧 NVME_SERIAL 是占位值" || return 1
        [[ "$NVME_SUBNQN_TEMPLATE" == \
            "nqn.1994-11.com.samsung:nvme:970-PRO:M.2:{serial}" ]] ||
            _stealth_identity_error "旧 NVME_SUBNQN_TEMPLATE 不受支持" ||
            return 1
        [[ "$NVME_SUBNQN" == \
            "nqn.1994-11.com.samsung:nvme:970-PRO:M.2:$NVME_SERIAL" ]] ||
            _stealth_identity_error "旧 NVME_SUBNQN 未绑定原序号" || return 1
    else
        stealth_component_storage_serial_is_valid \
            "${NVME_COMPONENT_ID:-}" "$NVME_SERIAL" >/dev/null 2>&1 ||
            _stealth_identity_error \
                "NVME_SERIAL 与 NVME_COMPONENT_ID 的厂商格式不一致" ||
            return 1
        [[ "$NVME_SUBNQN_TEMPLATE" == \
            "nqn.2014-08.org.nvmexpress:uuid:{uuid}" ]] ||
            _stealth_identity_error "NVME_SUBNQN_TEMPLATE 不是标准 UUID NQN 模板" ||
            return 1
        [[ "$NVME_SUBNQN" == "nqn.2014-08.org.nvmexpress:uuid:$UUID" ]] ||
            _stealth_identity_error "NVME_SUBNQN 未绑定持久 UUID" || return 1
    fi
    (( ${#NVME_SUBNQN} <= 223 )) ||
        _stealth_identity_error "NVME_SUBNQN 超过 223 字节" || return 1

    [[ "$MEM_SERIAL" =~ ^[0-9A-F]{8}$ &&
       "$MEM_SERIAL" != "00000000" && "$MEM_SERIAL" != "00000001" &&
       "$MEM_SERIAL" != "FFFFFFFF" ]] ||
        _stealth_identity_error "MEM_SERIAL 格式错误或为占位值" || return 1
    value="$(_stealth_memory_slot_serial "$MEM_SERIAL" 2)" ||
        _stealth_identity_error "无法派生合法的第二条 DIMM 序列号" || return 1
    stealth_component_monitor_serial_is_valid \
        "${EDID_COMPONENT_ID:-}" "$EDID_SERIAL" >/dev/null 2>&1 ||
        _stealth_identity_error \
            "EDID_SERIAL 与显示器稳定 ID 的品牌策略不一致" || return 1
    _stealth_identity_hid_serial_is_valid \
        "$KBD_SERIAL" "${KBD_COMPONENT_ID:-}" ||
        _stealth_identity_error \
            "KBD_SERIAL 与 KBD_COMPONENT_ID 的内部格式不一致" || return 1
    _stealth_identity_hid_serial_is_valid \
        "$MOUSE_SERIAL" "${MOUSE_COMPONENT_ID:-}" ||
        _stealth_identity_error \
            "MOUSE_SERIAL 与 MOUSE_COMPONENT_ID 的内部格式不一致" || return 1
    _stealth_identity_hid_serial_is_valid \
        "$TABLET_SERIAL" "${TABLET_COMPONENT_ID:-}" ||
        _stealth_identity_error \
            "TABLET_SERIAL 与 TABLET_COMPONENT_ID 的内部格式不一致" || return 1

    # 来宾可见的不同设备不能复用同一个标识；忽略 HID 内部 token，因为当前
    # descriptor 明确不向来宾暴露 iSerialNumber。
    for field in BOARD_SERIAL SYSTEM_SERIAL CHASSIS_SERIAL CPU_SERIAL \
        BOARD_ASSET MEM_SERIAL EDID_SERIAL NVME_SERIAL; do
        value="${!field}"
        if [[ -n "${seen[$value]:-}" ]]; then
            _stealth_identity_error "$field 与 ${seen[$value]} 重复"
            return 1
        fi
        seen["$value"]="$field"
    done
}
