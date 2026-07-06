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
        |"AMD Ryzen 3 2300X Quad-Core Processor" \
        |"AMD Athlon(tm) II X2 250 Processor" \
        |"AMD Athlon(tm) II X4 640 Processor" \
        |"AMD Phenom(tm) II X4 955 Processor" \
        |"AMD FX(tm)-4100 Quad-Core Processor" \
        |"AMD FX(tm)-4300 Quad-Core Processor" \
        |"AMD Athlon(tm) X4 860K Quad Core Processor" \
        |"Intel(R) Core(TM) i3-9100F CPU @ 3.60GHz" \
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
        |"LGA1151|PRIME B360M-A" \
        |"LGA1151|PRIME H370-A" \
        |"LGA1151|H310M PRO-VL (MS-7B75)" \
        |"LGA1151|B360M PRO-VH (MS-7B53)" \
        |"LGA1151|H310M S2H" \
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

known_gpu() {
    case "$1|$2|$3|$4|$5" in
        "NVIDIA|NVIDIA GeForce GTX 750 Ti|0x10DE|0x1380|2048" \
        |"NVIDIA|NVIDIA GeForce GT 1030|0x10DE|0x1D01|2048" \
        |"NVIDIA|NVIDIA GeForce GTX 1050|0x10DE|0x1C81|2048" \
        |"NVIDIA|NVIDIA GeForce GTX 1050 Ti|0x10DE|0x1C82|4096" \
        |"AMD|AMD Radeon RX 550|0x1002|0x699F|2048" \
        |"AMD|AMD Radeon RX 560|0x1002|0x67FF|4096")
            return 0 ;;
        *)
            return 1 ;;
    esac
}

known_nvme() {
    case "$1|$2" in
        "Samsung SSD 970 PRO 512GB|512110190592" \
        |"Samsung SSD 970 PRO 1TB|1000204886016" \
        |"Samsung SSD 970 EVO 500GB|500107862016" \
        |"Samsung SSD 970 EVO 1TB|1000204886016" \
        |"Samsung SSD 970 EVO Plus 500GB|500107862016" \
        |"Samsung SSD 970 EVO Plus 1TB|1000204886016" \
        |"Samsung SSD 980 500GB|500107862016" \
        |"Samsung SSD 980 1TB|1000204886016" \
        |"Samsung SSD 960 EVO 500GB|500107862016" \
        |"Samsung SSD 960 PRO 512GB|512110190592")
            return 0 ;;
        *)
            return 1 ;;
    esac
}

known_memory() {
    case "$1|$2|$3|$4" in
        "Crucial|CT2G4DFS6266|CT4G4DFS8266|2666" \
        |"Samsung|M378A5644EB0-CRC|M378A5244CB0-CRC|2400" \
        |"Kingston|KVR24N17S6/2|KVR24N17S8/4|2400" \
        |"Crucial|CT2G4DFS624A|CT4G4DFS824A|2400" \
        |"SK hynix|HMA425U6AFR6N-UH|HMA851U6AFR6N-UH|2400" \
        |"Kingston|KVR16N11S6/2|KVR16N11S8/4|1600" \
        |"Crucial|CT25664BA160B|CT51264BA160B|1600" \
        |"SK hynix|HMT325U6CFR8C-PB|HMT351U6CFR8C-PB|1600" \
        |"Kingston|KVR13N9S6/2|KVR13N9S8/4|1333")
            return 0 ;;
        *)
            return 1 ;;
    esac
}

known_monitor() {
    case "$1|$2" in
        "SAM|S24F350" \
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

for row in "${BOARD_POOL[@]}"; do
    IFS='|' read -r socket _ product _ _ _ _ _ <<<"$row"
    known_board "$socket" "$product" || fail "主板未在真实发售目录中: $socket $product"
done

for row in "${GPU_POOL[@]}"; do
    IFS='|' read -r vendor name ven dev ram _ _ <<<"$row"
    known_gpu "$vendor" "$name" "$ven" "$dev" "$ram" || fail "显卡未在真实发售目录中: $row"
done

for row in "${NVME_POOL[@]}"; do
    IFS='|' read -r model _ size <<<"$row"
    known_nvme "$model" "$size" || fail "NVMe 未在真实发售目录中: $row"
done

for row in "${MEM_POOL[@]}"; do
    IFS='|' read -r mfr part_2g part_4g rated _ <<<"$row"
    known_memory "$mfr" "$part_2g" "$part_4g" "$rated" || fail "内存未在真实发售目录中: $row"
done

for row in "${MONITOR_POOL[@]}"; do
    IFS='|' read -r vendor model _ _ _ <<<"$row"
    known_monitor "$vendor" "$model" || fail "显示器未在真实发售目录中: $row"
done

for row in "${KBD_POOL[@]}"; do
    IFS='|' read -r vid pid _ product _ <<<"$row"
    known_usb KBD "$vid" "$pid" "$product" || fail "键盘未在真实发售目录中: $row"
done
for row in "${MOUSE_POOL[@]}"; do
    IFS='|' read -r vid pid _ product _ <<<"$row"
    known_usb MOUSE "$vid" "$pid" "$product" || fail "鼠标未在真实发售目录中: $row"
done
for row in "${TABLET_POOL[@]}"; do
    IFS='|' read -r vid pid _ product _ <<<"$row"
    known_usb TABLET "$vid" "$pid" "$product" || fail "数位板未在真实发售目录中: $row"
done

echo "OK: hardware pool catalog checks passed"
