# Samsung NVMe serial: S<10 hex>N
_nvme_serial() { echo "S$(printf '%010X' $((RANDOM * RANDOM)))N"; }

# DIMM serial: 8 大写十六进制（Kingston / Crucial / Samsung / Hynix 都用这格式）
_mem_serial() { printf '%08X\n' $(( (RANDOM << 16) | RANDOM )); }

# 显示器 serial: prefix + 8 字符随机字母数字（Samsung "H4ZK500001VL" 风格）
_monitor_serial() {
    local prefix="$1"
    local rest
    rest=$(LC_ALL=C tr -dc 'A-Z0-9' </dev/urandom 2>/dev/null | head -c 8)
    [[ -z "$rest" ]] && rest=$(printf '%08X' $((RANDOM * RANDOM)))
    echo "${prefix}${rest}"
}

# USB HID serial: prefix + 6-8 字符。短，因为很多廉价键鼠 iSerialNumber
# 描述符只有 6~10 字符或干脆为空。
_usb_hid_serial() {
    local prefix="$1"
    local rest
    rest=$(LC_ALL=C tr -dc 'A-Z0-9' </dev/urandom 2>/dev/null | head -c 6)
    [[ -z "$rest" ]] && rest=$(printf '%06X' $RANDOM)
    echo "${prefix}${rest}"
}

# NIC OUI 池：Intel/Realtek/ASUS。永不用 52:54:00（QEMU/KVM 注册块）。
_gen_mac() {
    local ouis=(
        "00:1b:21" "00:1e:67" "00:a0:c9" "3c:fd:fe" "54:bf:64" "a0:36:9f"
        "1c:1b:0d" "00:e0:4c" "4c:cc:6a"
        "24:4b:fe" "a8:a1:59"
    )
    local n=${#ouis[@]}
    local i=$(( (RANDOM * 32768 + RANDOM) % n ))
    printf "%s:%02x:%02x:%02x\n" \
        "${ouis[$i]}" $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256))
}

_gen_uuid() {
    printf '%08x-%04x-%04x-%04x-%04x%08x\n' \
        $((RANDOM * RANDOM)) \
        $((RANDOM & 0xffff)) \
        $(((RANDOM & 0x0fff) | 0x4000)) \
        $(((RANDOM & 0x3fff) | 0x8000)) \
        $((RANDOM & 0xffff)) \
        $((RANDOM * RANDOM))
}

