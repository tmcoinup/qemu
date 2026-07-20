# NVMe Identify Controller 的 SN 字段是 20 字节 ASCII，QEMU 会按规范右侧空格补齐。
# Samsung 970 PRO 规格给出的模式是 S###N#########；变量位使用大写十六进制，
# 得到 48 bit 随机空间，同时保持 N 位于官方规定的第 5 个字符。
_nvme_serial() {
    local prefix suffix
    while :; do
        prefix="$(_hex 3 | tr '[:lower:]' '[:upper:]')"
        suffix="$(_hex 9 | tr '[:lower:]' '[:upper:]')"
        if [[ "$prefix$suffix" != "000000000000" &&
              "$prefix$suffix" != "FFFFFFFFFFFF" ]]; then
            printf 'S%sN%s\n' "$prefix" "$suffix"
            return 0
        fi
    done
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

# 显示器 serial: prefix + 8 字符随机字母数字（Samsung "H4ZK500001VL" 风格）
_monitor_serial() {
    local prefix="$1"
    local rest
    while :; do
        rest="$(_hex 8 | tr '[:lower:]' '[:upper:]')"
        [[ "$rest" != "00000000" && "$rest" != "FFFFFFFF" ]] && break
    done
    printf '%s\n' "${prefix}${rest}"
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
