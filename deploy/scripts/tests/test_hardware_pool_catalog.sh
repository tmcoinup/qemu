#!/usr/bin/env bash
# 验证硬件池只包含已核验过真实发售/量产的型号。
#
# 这个测试不是在线爬取器，而是把人工审计后的型号目录固化下来：后续新增硬件池
# 条目时，必须先确认真实产品和关键规格，再补进下面白名单，否则 CI 直接失败。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

source "$REPO_ROOT/deploy/scripts/stealth-lib.sh"

known_cpu() {
    case "$1" in
        "AMD Ryzen 3 1200 Quad-Core Processor" \
        |"AMD Athlon(tm) II X2 250 Processor" \
        |"AMD Athlon(tm) II X4 640 Processor" \
        |"AMD Phenom(tm) II X4 955 Processor" \
        |"AMD FX(tm)-4100 Quad-Core Processor" \
        |"AMD FX(tm)-4300 Quad-Core Processor" \
        |"AMD Athlon(tm) X4 860K Quad Core Processor" \
        |"Intel(R) Celeron(R) G4900 CPU @ 3.10GHz" \
        |"Intel(R) Pentium(R) Gold G5400 CPU @ 3.70GHz" \
        |"Intel(R) Core(TM) i3-9100F CPU @ 3.60GHz" \
        |"Intel(R) Core(TM) i5-6400T CPU @ 2.20GHz" \
        |"Intel(R) Core(TM) i5-2380P CPU @ 3.10GHz" \
        |"Intel(R) Core(TM) i5-2550K CPU @ 3.40GHz" \
        |"Intel(R) Core(TM) i5-3350P CPU @ 3.10GHz")
            return 0 ;;
        *)
            return 1 ;;
    esac
}

known_board() {
    case "$1|$2" in
        "AM4|PRIME B350-PLUS" \
        |"AM4|ROG STRIX B350-F GAMING" \
        |"AM4|PRIME X370-PRO" \
        |"AM4|PRIME B450M-A" \
        |"AM4|B350 TOMAHAWK (MS-7A34)" \
        |"AM4|X370 GAMING PRO CARBON (MS-7A32)" \
        |"AM4|GA-AB350-Gaming 3" \
        |"AM4|B450 AORUS M" \
        |"AM4|AB350 Pro4" \
        |"AM4|X370 Taichi" \
        |"AM3|M4A87TD EVO" \
        |"AM3|GA-870A-UD3" \
        |"AM3|870A-G54 (MS-7599)" \
        |"AM3|870 Extreme3" \
        |"AM3+|M5A97 R2.0" \
        |"AM3+|GA-970A-DS3P" \
        |"AM3+|970A-G43 (MS-7693)" \
        |"AM3+|970 Extreme3 R2.0" \
        |"FM2+|A88XM-A" \
        |"FM2+|GA-F2A88XM-D3H" \
        |"FM2+|A88XM-E35 (MS-7721)" \
        |"FM2+|FM2A88X Extreme4+" \
        |"LGA1155|P8P67 LE" \
        |"LGA1155|P8Z77-V LX" \
        |"LGA1155|GA-P67A-D3-B3" \
        |"LGA1155|P67A-C43 (MS-7673)" \
        |"LGA1155|P67 Pro3" \
        |"LGA1151|PRIME H310M-K" \
        |"LGA1151|PRIME H310M-K R2.0" \
        |"LGA1151|PRIME H310M-A R2.0" \
        |"LGA1151|H110M-K" \
        |"LGA1151|H110M-A/M.2" \
        |"LGA1151|PRIME B360M-A" \
        |"LGA1151|PRIME H370-A" \
        |"LGA1151|H310M PRO-VL (MS-7B75)" \
        |"LGA1151|B360M PRO-VH (MS-7B53)" \
        |"LGA1151|H310M PRO-M2 PLUS (MS-7C08)" \
        |"LGA1151|H310M S2H" \
        |"LGA1151|H310M S2H 2.0" \
        |"LGA1151|B360M D2V" \
        |"LGA1151|B360M Pro4" \
        |"LGA1151|H310CM-HDV" \
        |"LGA1200|PRIME H410M-A" \
        |"LGA1200|PRIME B460M-A" \
        |"LGA1200|H410M PRO (MS-7C89)" \
        |"LGA1200|B460M PRO-VDH WIFI (MS-7C83)" \
        |"LGA1200|H410M S2H" \
        |"LGA1200|B460M DS3H" \
        |"LGA1200|H410M-HDV" \
        |"LGA1200|B460M Pro4")
            return 0 ;;
        *)
            return 1 ;;
    esac
}

known_legacy_gpu() {
    case "$*" in
        "NVIDIA NVIDIA GeForce GTX 750 Ti 0x10DE 0x1380 2048 GDDR5 128 1020000 1085000 2700000 0" \
        |"NVIDIA NVIDIA GeForce GT 1030 0x10DE 0x1D01 2048 GDDR5 64 1227000 1468000 3004000 0" \
        |"NVIDIA NVIDIA GeForce GTX 1050 0x10DE 0x1C81 2048 GDDR5 128 1354000 1455000 3504000 0" \
        |"NVIDIA NVIDIA GeForce GTX 1050 Ti 0x10DE 0x1C82 4096 GDDR5 128 1290000 1392000 3504000 0" \
        |"AMD AMD Radeon RX 550 0x1002 0x699F 2048 GDDR5 128 1100000 1183000 3500000 0" \
        |"AMD AMD Radeon RX 560 0x1002 0x67FF 4096 GDDR5 128 1175000 1275000 3500000 0")
            return 0 ;;
        *)
            return 1 ;;
    esac
}

known_nvme() {
    case "$1|$2|$3" in
        "Samsung SSD 970 PRO 512GB|1B2QEXP7|512110190592" \
        |"INTEL SSDPEKKW512G8|001C|512110190592" \
        |"WDC PC SN730 SDBPNTY-512G-1027|11110000|512110190592" \
        |"KXG60ZNV512G KIOXIA|AGHA4101|512110190592")
            return 0 ;;
        *)
            return 1 ;;
    esac
}

known_memory() {
    case "$1|$2|$3|$4" in
        "Samsung|M378A5644EB0-CRC|M378A5244CB0-CRC|2400" \
        |"Crucial|CT2G4DFS624A|CT4G4DFS824A|2400" \
        |"Kingston|KVR16N11S6/2|KVR16N11S8/4|1600" \
        |"SK hynix|HMT325U6CFR8C-PB|HMT351U6CFR8C-PB|1600" \
        |"Kingston|KVR13N9S6/2|KVR13N9S8/4|1333")
            return 0 ;;
        *)
            return 1 ;;
    esac
}

known_memory_spd_brand() {
    # 与 hw/i2c/smbus_eeprom_spd.c 的 JEP106 映射保持同步。新增品牌时必须先
    # 补齐并单测其模组厂商码，不能只让 SMBIOS 显示字符串而留下空 SPD 身份。
    case "$1" in
        "Crucial"|"Samsung"|"Kingston"|"SK hynix")
            return 0 ;;
        *)
            return 1 ;;
    esac
}

known_monitor() {
    case "$1|$2" in
        "SAM|S24F350" \
        |"AOC|24B2W1G5" \
        |"XMI|Mi Monitor" \
        |"LEN|L24e-30" \
        |"SAM|C24F390" \
        |"AOC|24G2E5" \
        |"AOC|22B1H" \
        |"BNQ|GW2480" \
        |"DEL|SE2419HR" \
        |"HKC|SG24A1" \
        |"HKC|M24A1F" \
        |"GSM|24MK430" \
        |"PHL|246E9QJ")
            return 0 ;;
        *)
            return 1 ;;
    esac
}

known_usb() {
    case "$1|$2|$3|$4" in
        "KBD|0x045E|0x0750|Microsoft Wired Keyboard 600" \
        |"KBD|0x046D|0xC31C|Logitech USB Keyboard K120" \
        |"KBD|0x09DA|0x1F12|A4TECH USB Keyboard KK-3" \
        |"KBD|0x24AE|0x200A|Rapoo USB Keyboard N1820" \
        |"KBD|0x413C|0x2003|Dell USB Keyboard" \
        |"MOUSE|0x045E|0x00CB|Microsoft USB Optical Mouse" \
        |"MOUSE|0x046D|0xC077|Logitech USB Optical Mouse M105" \
        |"MOUSE|0x09DA|0x31AC|A4TECH USB Optical Mouse OP-720" \
        |"MOUSE|0x24AE|0x1102|Rapoo USB Mouse N1162" \
        |"MOUSE|0x413C|0x301A|Dell USB Optical Mouse" \
        |"TABLET|0x0627|0x0001|QEMU USB Tablet" \
        |"TABLET|0x256C|0x006D|HUION PenTablet" \
        |"TABLET|0x256C|0x006E|HUION H640P" \
        |"TABLET|0x2FEB|0x0001|VEIKK A30" \
        |"TABLET|0x28BD|0x0094|XP-Pen Star G640")
            return 0 ;;
        *)
            return 1 ;;
    esac
}

for row in "${CPU_POOL[@]}"; do
    IFS='|' read -r _ _ name _ _ _ _ _ <<<"$row"
    known_cpu "$name" || fail "CPU 未在真实发售目录中: $name"
    [[ "$name" != *"i3-8100F"* ]] || fail "i3-8100F 缺 Intel 官方发售规格，不得入池"
done
(( ${#CPU_POOL[@]} == 4 )) || fail "新 VM 应暴露四个 enabled Intel CPU bundle"
for row in "${CPU_POOL[@]}"; do
    IFS='|' read -r _ vendor name _ _ part family socket <<<"$row"
    [[ "$vendor" == GenuineIntel && "$socket" == LGA1151 ]] \
        || fail "unsupported/legacy CPU 泄漏到随机池: $row"
    [[ "$part" != GX80684I39100F ]] || fail "i3-9100F 使用了不存在的 GX 订购号"
    case "$name" in
        *Celeron*G4900*) [[ "$family" == 0x00C7 ]] \
            || fail "G4900 SMBIOS family 应为 Dual-Core Celeron" ;;
        *Pentium*G5400*) [[ "$family" == 0x000B ]] \
            || fail "G5400 SMBIOS family 应为 Pentium" ;;
        *i3-9100F*) [[ "$family" == 0x00CE ]] || fail "i3-9100F SMBIOS family 应为 Core i3" ;;
        *i5-6400T*) [[ "$family" == 0x00CD ]] || fail "i5-6400T SMBIOS family 应为 Core i5" ;;
    esac
done

for row in "${BOARD_POOL[@]}"; do
    IFS='|' read -r socket _ product _ _ _ _ _ <<<"$row"
    known_board "$socket" "$product" || fail "主板未在真实发售目录中: $socket $product"
done
for row in "${BOARD_POOL[@]}"; do
    [[ "${row%%|*}" == LGA1151 ]] || fail "旧 socket 主板泄漏到随机池: $row"
done

declare -A expected_gpu_rows=()
while IFS= read -r expected_row; do
    expected_gpu_rows["${expected_row%%|*}"]="$expected_row"
done < <(
    python3 - "$REPO_ROOT/deploy/hardware/gpu-boards.json" <<'PY'
import json
import sys

keys = (
    "id", "manufacturer", "model", "pci_vendor", "pci_device", "ram_mb",
    "bios", "revision", "memory_type", "memory_bus_width_bits",
    "base_clock_khz", "boost_clock_khz", "memory_clock_khz",
    "sli_supported", "board_partner", "part_number", "subsystem_vendor",
    "subsystem_device", "carrier_vendor", "carrier_device", "identity_fidelity",
)
with open(sys.argv[1], encoding="utf-8") as stream:
    for board in json.load(stream)["boards"]:
        print("|".join(str(board[key]) for key in keys))
PY
)
(( ${#expected_gpu_rows[@]} == 18 )) \
    || fail "离线 GPU 板卡目录没有精确投影 18 块板卡"

declare -A gpu_board_partners=()
declare -A gpu_carriers=()
declare -A gpu_chips=()
declare -A gpu_chip_partners=()
for row in "${GPU_POOL[@]}"; do
    IFS='|' read -r stable_id vendor name ven dev ram _bios _revision \
        memory_type bus_width base_clock boost_clock memory_clock sli_supported \
        board_partner _part_number subsystem_ven subsystem_dev carrier_ven \
        carrier_dev fidelity <<<"$row"
    [[ "${expected_gpu_rows[$stable_id]:-}" == "$row" ]] \
        || fail "AIB 显卡完整规格未在离线已审计目录中: $row"
    case "$vendor|$ven|$carrier_ven" in
        "NVIDIA|0x10DE|0x1AF4"|"AMD|0x1002|0x1AF4") ;;
        *) fail "显卡厂商、逻辑主 ID 与 virtio carrier 边界错误: $row" ;;
    esac
    [[ "$subsystem_ven|$subsystem_dev" != "$carrier_ven|$carrier_dev" ]] \
        || fail "真实 AIB subsystem 被错误复用为物理 carrier: $row"
    gpu_board_partners["$board_partner"]=1
    gpu_carriers["$carrier_ven:$carrier_dev"]=1
    chip="$ven:$dev"
    gpu_chips["$chip"]=$(( ${gpu_chips["$chip"]:-0} + 1 ))
    gpu_chip_partners["$chip|$board_partner"]=1
done
(( ${#GPU_POOL[@]} == 18 && ${#gpu_board_partners[@]} == 7 &&
   ${#gpu_carriers[@]} == 18 && ${#gpu_chips[@]} == 6 &&
   ${#gpu_chip_partners[@]} == 18 && ${#LEGACY_GPU_POOL[@]} == 6 )) \
    || fail "新池须为六芯片/每芯片三品牌的 18 块 AIB；旧六款仅供 ID 回查"
for chip in "${!gpu_chips[@]}"; do
    (( gpu_chips["$chip"] == 3 )) \
        || fail "芯片 $chip 未精确绑定三块板卡"
done
for expected_partner in ASUS Colorful GALAX MSI Gigabyte EVGA Sapphire; do
    [[ -n "${gpu_board_partners[$expected_partner]:-}" ]] \
        || fail "新 AIB 池缺少品牌: $expected_partner"
done
for (( carrier=0xA101; carrier<=0xA112; carrier++ )); do
    printf -v expected_carrier '0x1AF4:0x%04X' "$carrier"
    [[ -n "${gpu_carriers[$expected_carrier]:-}" ]] \
        || fail "新 AIB 池缺少内部 carrier: $expected_carrier"
done
[[ -z "${gpu_carriers[0x1AF4:0xA113]:-}" ]] \
    || fail "未知 carrier A113 被错误加入 AIB 池"
for row in "${LEGACY_GPU_POOL[@]}"; do
    IFS='|' read -r vendor name ven dev ram _ _ memory_type bus_width \
        base_clock boost_clock memory_clock sli_supported <<<"$row"
    known_legacy_gpu "$vendor" "$name" "$ven" "$dev" "$ram" "$memory_type" \
        "$bus_width" "$base_clock" "$boost_clock" "$memory_clock" \
        "$sli_supported" \
        || fail "旧 GPU 兼容回查目录出现未知 generic 条目: $row"
done

for row in "${NVME_POOL[@]}"; do
    IFS='|' read -r _ model firmware size _ <<<"$row"
    known_nvme "$model" "$firmware" "$size" || fail "NVMe 型号/固件/容量组合未核验: $row"
done
(( ${#NVME_POOL[@]} == 4 )) \
    || fail "NVMe 池必须包含 Samsung/Intel/Western Digital/KIOXIA 四个 512GB 原子画像"

for row in "${MEM_POOL[@]}"; do
    IFS='|' read -r mfr part_2g part_4g rated _ \
        rank_2g width_2g rank_4g width_4g <<<"$row"
    known_memory "$mfr" "$part_2g" "$part_4g" "$rated" || fail "内存未在真实发售目录中: $row"
    known_memory_spd_brand "$mfr" || fail "内存品牌缺少 SPD JEP106 映射: $mfr"
    [[ "$rank_2g" =~ ^[1-4]$ && "$rank_4g" =~ ^[1-4]$ ]] \
        || fail "内存 rank 非法: $row"
    [[ "$width_2g" == 4 || "$width_2g" == 8 || "$width_2g" == 16 ]] \
        || fail "2GB 内存 device-width 非法: $row"
    [[ "$width_4g" == 4 || "$width_4g" == 8 || "$width_4g" == 16 ]] \
        || fail "4GB 内存 device-width 非法: $row"
done
(( ${#MEM_POOL[@]} == 5 )) \
    || fail "旧双料号 ABI 应为两组 DDR4 + 三组 DDR3 已核验物料"
(( ${#MEM_DORMANT_POOL[@]} == 0 )) \
    || fail "已启用 household compatibility 后 DDR3 不应继续留在 dormant 池"
for row in "${MEM_DORMANT_POOL[@]}"; do
    IFS='|' read -r mfr part_2g part_4g rated _ \
        rank_2g width_2g rank_4g width_4g <<<"$row"
    known_memory "$mfr" "$part_2g" "$part_4g" "$rated" \
        || fail "dormant 内存未在已核验目录中: $row"
    known_memory_spd_brand "$mfr" || fail "dormant 内存品牌缺少 SPD 映射: $mfr"
    [[ "$rank_2g|$width_2g|$rank_4g|$width_4g" =~ ^[1-4]\|(4|8|16)\|[1-4]\|(4|8|16)$ ]] \
        || fail "dormant 内存几何非法: $row"
done
(( ${#MEM_QUARANTINED_POOL[@]} == 2 )) \
    || fail "证据不足的内存没有完整隔离"

for row in "${MONITOR_POOL[@]}"; do
    IFS='|' read -r _ vendor model _ <<<"$row"
    known_monitor "$vendor" "$model" || fail "显示器未在真实发售目录中: $row"
done
(( ${#MONITOR_POOL[@]} == 4 )) \
    || fail "显示器池必须包含四款受控 1080p/16:9 型号"

for row in "${KBD_POOL[@]}"; do
    IFS='|' read -r vid pid _ product _ <<<"$row"
    known_usb KBD "$vid" "$pid" "$product" || fail "键盘未在真实发售目录中: $row"
done
for row in "${MOUSE_POOL[@]}"; do
    IFS='|' read -r vid pid _ product _ <<<"$row"
    known_usb MOUSE "$vid" "$pid" "$product" || fail "鼠标未在真实发售目录中: $row"
done
for row in "${TABLET_POOL[@]}"; do
    IFS='|' read -r vid pid _ product _ _ fidelity <<<"$row"
    known_usb TABLET "$vid" "$pid" "$product" || fail "数位板未在真实发售目录中: $row"
    [[ "$fidelity" == generic_virtual_only ]] \
        || fail "虚拟 tablet 必须明确标注 fidelity 边界: $row"
done

echo "OK: hardware pool catalog checks passed"
