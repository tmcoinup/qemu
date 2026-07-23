# NVMe Identify Controller 的 SN 字段是 20 字节 ASCII，QEMU 会按规范右侧空格
# 补齐。每个身份 profile 使用自己的厂商格式；生成值只模拟格式，不复制真实序号。
_nvme_serial() {
    local component_id="${1:-samsung-970-pro-512gb}"
    local prefix suffix serial

    case "$component_id" in
        samsung-970-pro-512gb)
            while :; do
                prefix="$(_hex 3 | tr '[:lower:]' '[:upper:]')"
                suffix="$(_hex 10 | tr '[:lower:]' '[:upper:]')"
                serial="S${prefix}N${suffix}"
                [[ "$prefix$suffix" != "0000000000000" &&
                   "$prefix$suffix" != "FFFFFFFFFFFFF" ]] && break
            done
            ;;
        intel-760p-512gb)
            while :; do
                suffix="$(_hex 8 | tr '[:lower:]' '[:upper:]')"
                serial="BTHH${suffix}512D"
                [[ "$suffix" != "00000000" &&
                   "$suffix" != "FFFFFFFF" ]] && break
            done
            ;;
        wd-pc-sn730-512gb|kioxia-xg6-512gb)
            while :; do
                serial="$(_hex 12 | tr '[:lower:]' '[:upper:]')"
                [[ "$serial" != "000000000000" &&
                   "$serial" != "FFFFFFFFFFFF" ]] && break
            done
            ;;
        *)
            echo "ERROR: 未知 NVMe 序列号策略: $component_id" >&2
            return 2
            ;;
    esac
    printf '%s\n' "$serial"
}

# SATA ATA Identify serial 与 NVMe Identify serial 是两个不同设备身份。老实现
# 在 SATA 分支复用 NVME_SERIAL，会把 970 PRO 部件身份投影到 840/850/860 PRO。
# 新建 profile 为独立 SATA 启动盘生成 15 字符 Samsung 风格序号并持久化。
_boot_storage_serial() {
    local serial
    while :; do
        serial="S$(_hex 14 | tr '[:lower:]' '[:upper:]')"
        if [[ "$serial" != S00000000000000 &&
              "$serial" != SFFFFFFFFFFFFFF ]]; then
            printf '%s\n' "$serial"
            return 0
        fi
    done
}

# DIMM serial: 8 大写十六进制。排除 SMBIOS/工具常用的未提供占位值。
_mem_serial() {
    local serial
    while :; do
        serial="$(_hex 8 | tr '[:lower:]' '[:upper:]')"
        if [[ "$serial" != "00000000" && "$serial" != "00000001" &&
              "$serial" != "FFFFFFFF" ]]; then
            printf '%s\n' "$serial"
            return 0
        fi
    done
}

# 显示器 serial 只沿用实机 EDID 中已观察到的厂商格式；具体值重新生成，并由
# 目录校验器拒绝证据样本，避免复制某台实机身份。EDID 文本描述符最多 13 字节。
_monitor_serial() {
    local component_id="$1"
    local spec kind length serial decimal letters digit alnum

    spec="$(stealth_component_monitor_serial_spec "$component_id")" || return 1
    IFS='|' read -r kind length <<<"$spec"
    [[ "$length" =~ ^[1-9][0-9]*$ ]] || return 2
    while :; do
        case "$kind" in
            samsung_h4zmc_decimal5)
                printf -v decimal '%05d' "$(_rand 0 99999)"
                serial="H4ZMC${decimal}"
                ;;
            aoc_upper_alnum7_decimal6)
                printf -v decimal '%06d' "$(_rand 0 999999)"
                letters="$(_hex 4 |
                    tr '0123456789abcdef' 'GHIJKLMNOPABCDEF')"
                digit="$(_rand 0 9)"
                alnum="$(_hex 1 | tr '[:lower:]' '[:upper:]')"
                serial="${letters}${digit}${alnum}A${decimal}"
                ;;
            xiaomi_29200_label_slash_removed_decimal)
                printf -v decimal '%08d' "$(_rand 0 99999999)"
                serial="29200${decimal}"
                ;;
            lenovo_urb_upper_alnum)
                serial="URB$(_hex 5 | tr '[:lower:]' '[:upper:]')"
                ;;
            *)
                echo "ERROR: 未知显示器序列号策略: $kind" >&2
                return 2
                ;;
        esac
        [[ ${#serial} -eq length ]] || return 2
        if stealth_component_monitor_serial_is_valid \
                "$component_id" "$serial" >/dev/null 2>&1; then
            printf '%s\n' "$serial"
            return 0
        fi
    done
}

# USB HID serial 只用于 profile 内部稳定标识，当前 C descriptor 明确不向 guest
# 暴露 iSerialNumber。组件 ID 可能包含长横线和小写字母，不能直接拼入序列号；
# 先压成最多 4 位大写字母数字前缀，再追加 6 位随机值，保持短且可读。
_usb_hid_serial() {
    local prefix="${1^^}"
    local rest
    prefix="${prefix//[^A-Z0-9]/}"
    prefix="${prefix:0:4}"
    [[ -n "$prefix" ]] || prefix="HID"
    while :; do
        rest="$(_hex 6 | tr '[:lower:]' '[:upper:]')"
        [[ "$rest" != "000000" && "$rest" != "FFFFFF" ]] && break
    done
    printf '%s\n' "${prefix}${rest}"
}

_gen_uuid() {
    local hex variant
    while :; do
        hex="$(_hex 32)"
        [[ "$hex" != "00000000000000000000000000000000" &&
           "$hex" != "ffffffffffffffffffffffffffffffff" ]] && break
    done
    variant=$(( 8 + (16#${hex:16:1} % 4) ))
    printf '%s-%s-4%s-%x%s-%s\n' \
        "${hex:0:8}" "${hex:8:4}" "${hex:13:3}" \
        "$variant" "${hex:17:3}" "${hex:20:12}"
}
