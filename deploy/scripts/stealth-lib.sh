#!/bin/bash
# stealth-lib.sh —— 共享的 SMBIOS / 磁盘 / MAC / GPU 随机化库，被 start-vm.sh
# 等启动脚本 source。
#
# 使用：source 之后调用：
#   stealth_pick_profile        生成一份新身份并 export 全部字段
#   stealth_load_profile <path> 从文件载入并 export
#   stealth_save_profile <path> 持久化到文件
#   stealth_print_profile       打印身份
#   stealth_smbios_args         输出 -smbios 行（每行一条，commas 已转义）
#   stealth_qemu_cpu_arg        输出 -cpu 后的完整字符串

# ------------------------------------------------------------------
# PRNG helpers. STEALTH_SEED=integer 可启用确定性重放。
# ------------------------------------------------------------------
_rng_init() {
    if [[ -n "${STEALTH_SEED:-}" ]]; then
        RANDOM="$STEALTH_SEED"
    fi
}
_rand() {
    local lo=$1 hi=$2
    echo $(( (RANDOM * 32768 + RANDOM) % (hi - lo + 1) + lo ))
}
_pick_array() {
    # _pick_array <array_name>  从 array 里随机取一个元素，stdout 输出
    local -n _arr=$1
    local n=${#_arr[@]}
    local i=$(( (RANDOM * 32768 + RANDOM) % n ))
    echo "${_arr[$i]}"
}
_hex() {
    local w=$1 out=""
    while (( ${#out} < w )); do
        out+=$(printf "%04x" $((RANDOM ^ (RANDOM<<8) ^ (RANDOM<<16) )) )
    done
    echo "${out:0:$w}"
}
_serial_asus() { echo "MB-$(_hex 6 | tr a-f A-F)$(_rand 10000 99999)"; }
_serial_msi()  { echo "$(_hex 4 | tr a-f A-F)$(_rand 100000 999999)"; }
_serial_giga() { echo "SN$(_rand 10000000 99999999)"; }
_serial_asr()  { echo "M80-$(_hex 4 | tr a-f A-F)$(_rand 1000 9999)"; }

# ------------------------------------------------------------------
# CPU 池
#
# 每条格式：
#   QEMU_CPU_ARG|VENDOR|DISPLAY_NAME|MAX_MHZ|CUR_MHZ|PART|PROC_FAMILY|SOCKET
#
# - QEMU_CPU_ARG: 给 -cpu 用的"型号 + family/model/stepping/model-id 覆盖"，
#   常用旁路 (kvm=off,hypervisor=off,+invtsc 等) 不在此处；由 stealth_qemu_cpu_arg 拼接。
# - VENDOR: AuthenticAMD / GenuineIntel
# - SOCKET: AM4 / LGA1151 / LGA1200，board 池据此对齐
# - PROC_FAMILY: SMBIOS Type 4 processor-family，0x139=Zen，0xCD=Intel Core i3 9th+
# - 全部为**无 iGPU**的低端配置（裸金属用独显 VGA_DEV 时，多一个 iGPU 适配器
#   就跟 GPU 池矛盾——历史曾收录 G5400/G6400/i3-9100 这类带 UHD 6xx 的 SKU，
#   反作弊 Get-CimInstance Win32_VideoController 看到 1 个独显但 CPU 该有 iGPU
#   会判异常。统一只留无 iGPU 型号；Intel 端 "F" 后缀 = 物理屏蔽 iGPU 版本）。
# ------------------------------------------------------------------
CPU_POOL=(
    # AMD AM4 — Zen 1 / Zen+（桌面 Ryzen 3 全系无 iGPU；带 iGPU 的是 APU 2200G/3200G 系，本池排除）
    "Ryzen3-1200|AuthenticAMD|AMD Ryzen 3 1200 Quad-Core Processor|3400|3100|YD1200BBM4KAE|0x139|AM4"
    "Ryzen3-2300X|AuthenticAMD|AMD Ryzen 3 2300X Quad-Core Processor|4000|3500|YD230XBBM4KAF|0x139|AM4"
    # Intel LGA1151 v2 — Coffee Lake R，"F" 后缀 = 无 UHD 630 iGPU
    "Skylake-Client-IBRS,family=6,model=158,stepping=10,model-id=Intel(R) Core(TM) i3-9100F CPU @ 3.60GHz|GenuineIntel|Intel(R) Core(TM) i3-9100F CPU @ 3.60GHz|4200|3600|GX80684I39100F|0xCD|LGA1151"
)

# ------------------------------------------------------------------
# 主板池 —— 按 SOCKET 字段过滤匹配 CPU 平台。低端 H/B 系芯片组为主。
# 格式：SOCKET|MFR|PRODUCT|FAMILY|VERSION|SERIAL_FN|SUBSYS_VEN|SUBSYS_DEV
#
# **新增 SUBSYS 字段（2026-05）**：
# 历史问题：start-vm.sh hardcoded `QEMU_PCI_SUBSYS_VEN=0x1043,DEV=0x8694`
# （ASUS B350-PLUS）无视 BOARD_MFR——若 profile 抽到 Gigabyte / MSI / ASRock，
# 主板 SMBIOS 报 Gigabyte 而 PCI 树所有桥接 / 控制器都报 ASUS，跨表对照即矛盾。
# 现按板厂分配真实 PCI 子系统供应商 ID（来自实机 lspci -nn 抽样）：
#   ASUS     0x1043 / DEV 看具体板：B350-PLUS=0x8694, H370=0x8694, X370=0x86C7
#   MSI      0x1462 / DEV ≈ board model 后缀（7A34/7B49 等）
#   Gigabyte 0x1458 / DEV 0x5001 (最常见 generic)
#   ASRock   0x1849 / DEV 0x1230 / 0x9696
# ------------------------------------------------------------------
BOARD_POOL=(
    # AM4 (B350/X370/B450 主流入门)
    "AM4|ASUSTeK COMPUTER INC.|PRIME B350-PLUS|PRIME|Rev X.0x|_serial_asus|0x1043|0x8694"
    "AM4|ASUSTeK COMPUTER INC.|ROG STRIX B350-F GAMING|ROG STRIX|Rev X.0x|_serial_asus|0x1043|0x86C7"
    "AM4|ASUSTeK COMPUTER INC.|PRIME X370-PRO|PRIME|Rev X.0x|_serial_asus|0x1043|0x86C7"
    "AM4|ASUSTeK COMPUTER INC.|PRIME B450M-A|PRIME|Rev X.0x|_serial_asus|0x1043|0x8753"
    "AM4|Micro-Star International Co., Ltd.|B350 TOMAHAWK (MS-7A34)|MSI|3.0|_serial_msi|0x1462|0x7A34"
    "AM4|Micro-Star International Co., Ltd.|X370 GAMING PRO CARBON (MS-7A32)|MSI|2.0|_serial_msi|0x1462|0x7A32"
    "AM4|Gigabyte Technology Co., Ltd.|GA-AB350-Gaming 3|X.x|Default string|_serial_giga|0x1458|0x5001"
    "AM4|Gigabyte Technology Co., Ltd.|B450 AORUS M|B450 AORUS M|x.x|_serial_giga|0x1458|0x5001"
    "AM4|ASRock|AB350 Pro4|AB350 Pro4|Default string|_serial_asr|0x1849|0x1230"
    "AM4|ASRock|X370 Taichi|X370 Taichi|Default string|_serial_asr|0x1849|0x9696"
    # LGA1151 v2 (H310/B360/H370 入门)
    "LGA1151|ASUSTeK COMPUTER INC.|PRIME H310M-K|PRIME|Rev 1.xx|_serial_asus|0x1043|0x8694"
    "LGA1151|ASUSTeK COMPUTER INC.|PRIME B360M-A|PRIME|Rev 1.xx|_serial_asus|0x1043|0x8694"
    "LGA1151|ASUSTeK COMPUTER INC.|PRIME H370-A|PRIME|Rev 1.xx|_serial_asus|0x1043|0x8694"
    "LGA1151|Micro-Star International Co., Ltd.|H310M PRO-VL (MS-7B24)|MSI|1.0|_serial_msi|0x1462|0x7B24"
    "LGA1151|Micro-Star International Co., Ltd.|B360M PRO-VH (MS-7B49)|MSI|1.0|_serial_msi|0x1462|0x7B49"
    "LGA1151|Gigabyte Technology Co., Ltd.|H310M S2H|H310M|x.x|_serial_giga|0x1458|0x5001"
    "LGA1151|Gigabyte Technology Co., Ltd.|B360M D2V|B360M|x.x|_serial_giga|0x1458|0x5001"
    "LGA1151|ASRock|B360M Pro4|B360M Pro4|Default string|_serial_asr|0x1849|0x1230"
    "LGA1151|ASRock|H310CM-HDV|H310CM-HDV|Default string|_serial_asr|0x1849|0x9696"
    # LGA1200 (H410/B460/H470 入门)
    "LGA1200|ASUSTeK COMPUTER INC.|PRIME H410M-A|PRIME|Rev 1.xx|_serial_asus|0x1043|0x8694"
    "LGA1200|ASUSTeK COMPUTER INC.|PRIME B460M-A|PRIME|Rev 1.xx|_serial_asus|0x1043|0x8694"
    "LGA1200|Micro-Star International Co., Ltd.|H410M PRO (MS-7C95)|MSI|1.0|_serial_msi|0x1462|0x7C95"
    "LGA1200|Micro-Star International Co., Ltd.|B460M PRO-VDH (MS-7C82)|MSI|1.0|_serial_msi|0x1462|0x7C82"
    "LGA1200|Gigabyte Technology Co., Ltd.|H410M S2H|H410M|x.x|_serial_giga|0x1458|0x5001"
    "LGA1200|Gigabyte Technology Co., Ltd.|B460M DS3H|B460M|x.x|_serial_giga|0x1458|0x5001"
    "LGA1200|ASRock|H410M-HDV|H410M-HDV|Default string|_serial_asr|0x1849|0x1230"
    "LGA1200|ASRock|B460M Pro4|B460M Pro4|Default string|_serial_asr|0x1849|0x1230"
)

# ------------------------------------------------------------------
# GPU 池 —— 低端入门为主，NVIDIA + AMD 都覆盖。
# 格式：VENDOR|NAME|PCI_VEN|PCI_DEV|RAM_MB|BIOS_STRING|REV
# ------------------------------------------------------------------
GPU_POOL=(
    # NVIDIA (Pascal/Maxwell 低端)
    "NVIDIA|NVIDIA GeForce GTX 750 Ti|0x10DE|0x1380|2048|Version 82.07.41.00.32|0xA2"
    "NVIDIA|NVIDIA GeForce GT 1030|0x10DE|0x1D01|2048|Version 86.08.46.00.81|0xA1"
    "NVIDIA|NVIDIA GeForce GTX 1050|0x10DE|0x1C81|2048|Version 86.07.48.00.38|0xA1"
    "NVIDIA|NVIDIA GeForce GTX 1050 Ti|0x10DE|0x1C82|4096|Version 86.07.48.00.A0|0xA1"
    # AMD Polaris 低端
    "AMD|AMD Radeon RX 550|0x1002|0x699F|2048|016.011.000.029.000000|0xCF"
    "AMD|AMD Radeon RX 560|0x1002|0x67FF|4096|016.011.000.029.000000|0xCF"
)

# ------------------------------------------------------------------
# NVMe 池 —— 全部 Samsung 系列，搭配 use-samsung-id=on 保证 IEEE OUI 一致。
# 格式：MODEL|FIRMWARE|RAW_BYTES
#
# **2026-05 增 RAW_BYTES 列**：之前 start-vm.sh 一律建 512 GB qcow2，但 NVMe
# 池里有 1TB / 500GB 多种规格——profile 抽到 "Samsung 980 1TB" 时 Windows
# WMI 看到 Model=1TB 但 Size=476 GiB（512×10⁹ B），跨向量矛盾。
# 现在按各厂商 NVMe 真实 advertised capacity 填字节数：
#   500GB SSD = 500,107,862,016 B (~465.7 GiB)
#   512GB SSD = 512,110,190,592 B (~476.9 GiB)
#   1TB   SSD = 1,000,204,886,016 B (~931.5 GiB)
# qcow2 是 sparse 的，1TB 镜像不会立即占 host 1TB（只占实际写入）。
# ------------------------------------------------------------------
NVME_POOL=(
    "Samsung SSD 970 PRO 512GB|1B2QEXM7|512110190592"
    "Samsung SSD 970 EVO Plus 500GB|2B2QEXM7|500107862016"
    "Samsung SSD 980 PRO 500GB|5B2QGXA7|500107862016"
    "Samsung SSD 980 1TB|3B4QFXO7|1000204886016"
    "Samsung SSD 990 PRO 1TB|3B2QJXD7|1000204886016"
)

# ------------------------------------------------------------------
# 内存 part / 厂商池 —— 低端 4G 总量典型搭配。
# Format: MFR|PART_2G|PART_4G
# ------------------------------------------------------------------
MEM_POOL=(
    "Kingston|KVR26N19S6/2|HX426C16FB3A/4"
    "Crucial|CT2G4DFS6266|CT4G4DFS8266"
    "Samsung|M378A5644EB0-CRC|M378A5244CB0-CRC"
    "SK hynix|HMA425S6BJR8N-V8|HMA851S6CJR6N-VK"
)

# ------------------------------------------------------------------
# 显示器（EDID）池
#
# 真实 EDID 三大要素：
#   - 3 字符 EISA vendor code（SAM/AOC/BNQ/DEL/HKC/LEN/...）
#   - product name（最长 13 字符，detailed descriptor 0xFC 块）
#   - 12 字符 serial（0xFF 块）
# 24"/1920×1080@60Hz 是国内入门 / 网吧最普遍配置——width=530mm, height=300mm。
# 16:9 比例和现实一致；不要混 4:3 / 16:10 老型号（裸金属还在用的极少）。
# 格式：VENDOR3|MODEL|WIDTH_MM|HEIGHT_MM|SERIAL_PREFIX
# ------------------------------------------------------------------
MONITOR_POOL=(
    # Samsung 三星：S24F350F 是 QEMU 历史默认，淘宝二手 24" 一抓一大把
    "SAM|S24F350|530|300|H4ZK"
    "SAM|C24F390|530|300|H4VW"
    # AOC 冠捷：国内出货量第一的低端显示器品牌
    "AOC|24G2E5|530|300|CNV"
    "AOC|22B1H|485|275|CMR"
    # BenQ 明基：GW2480 是入门商务款
    "BNQ|GW2480|530|300|ETK"
    # Dell：OEM 主机捆绑款
    "DEL|SE2419HR|527|296|CN0"
    # HKC 惠科：国产入门
    "HKC|SG24A1|530|300|HKC"
    "HKC|M24A1F|530|300|HKC"
    # LG 乐金：24MK430H
    "GSM|24MK430|527|296|902N"
    # 飞利浦
    "PHL|246E9QJ|530|300|UK02"
)

# ------------------------------------------------------------------
# 键盘池 —— 低端 / 国产 / 捆绑款。
# 格式：VENDOR_ID|PRODUCT_ID|MANUFACTURER|PRODUCT_NAME|SERIAL_PREFIX
#
# - Microsoft 045E:0750 Wired Keyboard 600：QEMU 历史默认，OEM 捆绑款
# - Logitech 046D:C31C K120：国内 30 块入门有线，办公室最普遍
# - A4Tech 双飞燕 09DA:1F12 KK-3 / KK-5 系列：网吧入门
# - Rapoo 雷柏 24AE:200A N1820：京东学生款
# - Dell 413C:2003 USB Wired Keyboard：戴尔 OEM 捆绑
# ------------------------------------------------------------------
KBD_POOL=(
    "0x045E|0x0750|Microsoft|Microsoft Wired Keyboard 600|68"
    "0x046D|0xC31C|Logitech|Logitech USB Keyboard K120|K1"
    "0x09DA|0x1F12|A4TECH|A4TECH USB Keyboard KK-3|A4"
    "0x24AE|0x200A|Rapoo|Rapoo USB Keyboard N1820|RP"
    "0x413C|0x2003|Dell|Dell USB Keyboard|DL"
)

# ------------------------------------------------------------------
# 鼠标池 —— 同样的低端 / 国产 / 捆绑路线（相对坐标 usb-mouse）。
# ------------------------------------------------------------------
MOUSE_POOL=(
    "0x045E|0x00CB|Microsoft|Microsoft USB Optical Mouse|42"
    "0x046D|0xC077|Logitech|Logitech USB Optical Mouse M105|LM"
    "0x09DA|0x31AC|A4TECH|A4TECH USB Optical Mouse OP-720|A4"
    "0x24AE|0x1102|Rapoo|Rapoo USB Mouse N1162|RP"
    "0x413C|0x301A|Dell|Dell USB Optical Mouse|DL"
)

# ------------------------------------------------------------------
# 数位板池 —— usb-tablet（绝对坐标）。自动化场景默认走这条。
# 反作弊看到的是"普通家用数位板"，而不是"虚拟绝对指针"——后者是 VM 强信号。
# ------------------------------------------------------------------
TABLET_POOL=(
    "0x256C|0x006D|HUION|HUION PenTablet|HU"
    "0x256C|0x006E|HUION|HUION H640P|HU"
    "0x2FEB|0x0001|VEIKK|VEIKK A30|VK"
    "0x28BD|0x0094|XP-PEN|XP-Pen Star G640|XP"
)

# BIOS / Chassis 池
BIOS_VENDOR="American Megatrends Inc."
BIOS_VERSION_POOL=("6203" "6204" "6301" "6042" "5601" "5406" "4012" "3805" "2401")
BIOS_DATE_POOL=("11/23/2020" "03/17/2021" "08/04/2021" "12/09/2021" "06/22/2022" "01/14/2023")
CHASSIS_POOL=("Desktop" "Tower" "Mini Tower")
SYSTEM_PRODUCT_POOL=(
    "System Product Name"
    "To Be Filled By O.E.M."
    "Default string"
    "All Series"
)
SYSTEM_FAMILY_POOL=(
    "To be filled by O.E.M."
    "Default string"
    "Desktop"
)

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

# ------------------------------------------------------------------
# 公开：随机生成一份完整 profile 并 export
# ------------------------------------------------------------------
stealth_pick_profile() {
    _rng_init

    # 1. 先选 CPU
    local cpu_n=${#CPU_POOL[@]}
    local cpu_i=$(( (RANDOM * 32768 + RANDOM) % cpu_n ))
    IFS='|' read -r CPU_QEMU_ARG CPU_VENDOR CPU_NAME CPU_MAX_MHZ CPU_CUR_MHZ CPU_PART CPU_PROC_FAMILY CPU_SOCKET <<<"${CPU_POOL[$cpu_i]}"
    # 兼容老 profile 的 CPU_MODEL 字段：保留它指向 QEMU 模型主名（不带 family/model 覆盖）
    CPU_MODEL="${CPU_QEMU_ARG%%,*}"

    # 2. 主板：从 BOARD_POOL 里挑 socket 匹配的
    local matched=()
    local entry
    for entry in "${BOARD_POOL[@]}"; do
        local sock="${entry%%|*}"
        if [[ "$sock" == "$CPU_SOCKET" ]]; then
            matched+=("$entry")
        fi
    done
    if (( ${#matched[@]} == 0 )); then
        echo "ERROR: 没有 socket=$CPU_SOCKET 的主板可选" >&2
        return 1
    fi
    local b_i=$(( (RANDOM * 32768 + RANDOM) % ${#matched[@]} ))
    IFS='|' read -r _ BOARD_MFR BOARD_PRODUCT BOARD_FAMILY BOARD_VERSION SERIAL_FN BOARD_SUBSYS_VEN BOARD_SUBSYS_DEV <<<"${matched[$b_i]}"
    BOARD_SERIAL="$($SERIAL_FN)"
    BOARD_ASSET="$(_rand 1000000000 9999999999)"

    SYSTEM_MFR="$BOARD_MFR"
    local m=${#SYSTEM_PRODUCT_POOL[@]}
    SYSTEM_PRODUCT="${SYSTEM_PRODUCT_POOL[$((RANDOM % m))]}"
    local f=${#SYSTEM_FAMILY_POOL[@]}
    SYSTEM_FAMILY="${SYSTEM_FAMILY_POOL[$((RANDOM % f))]}"
    SYSTEM_VERSION="$BOARD_VERSION"
    SYSTEM_SERIAL="$($SERIAL_FN)"
    SYSTEM_SKU="SKU$(_rand 100000 999999)"

    local v=${#BIOS_VERSION_POOL[@]}
    BIOS_VERSION="${BIOS_VERSION_POOL[$((RANDOM % v))]}"
    local d=${#BIOS_DATE_POOL[@]}
    BIOS_DATE="${BIOS_DATE_POOL[$((RANDOM % d))]}"

    local c=${#CHASSIS_POOL[@]}
    CHASSIS_TYPE="${CHASSIS_POOL[$((RANDOM % c))]}"
    CHASSIS_SERIAL="$($SERIAL_FN)"

    NIC_MAC="$(_gen_mac)"
    UUID="$(_gen_uuid)"
    CPU_SERIAL="$(_rand 1000000000 9999999999)"

    # 3. GPU
    local gpu_n=${#GPU_POOL[@]}
    local gpu_i=$(( (RANDOM * 32768 + RANDOM) % gpu_n ))
    IFS='|' read -r GPU_VENDOR GPU_NAME GPU_PCI_VEN GPU_PCI_DEV GPU_RAM_MB GPU_BIOS GPU_REV <<<"${GPU_POOL[$gpu_i]}"

    # 4. NVMe
    local nv_n=${#NVME_POOL[@]}
    local nv_i=$(( (RANDOM * 32768 + RANDOM) % nv_n ))
    IFS='|' read -r NVME_MODEL NVME_FIRMWARE NVME_SIZE_BYTES <<<"${NVME_POOL[$nv_i]}"
    NVME_SERIAL="$(_nvme_serial)"

    # 5. 内存厂家 / part / 持久化序列号
    local mp_n=${#MEM_POOL[@]}
    local mp_i=$(( (RANDOM * 32768 + RANDOM) % mp_n ))
    IFS='|' read -r MEM_MFR MEM_PART_2G MEM_PART_4G <<<"${MEM_POOL[$mp_i]}"
    # DIMM serial 在 pick 阶段一次性生成，写到 profile 持久化——避免之前每次
    # 启动 stealth_smbios_args 里 _rand 一遍导致 Win32_PhysicalMemory.SerialNumber
    # 重启就变（反作弊"硬件指纹漂移"检测的明显信号）。
    MEM_SERIAL="$(_mem_serial)"

    # 内存总量 (MiB) 也钉进 profile，跟其它硬件身份一样跨重启稳定——否则启动时
    # 忘了带 --ram 就回退脚本默认值，"内存 4GB↔8GB 来回漂移"本身就是反作弊判定
    # 硬件指纹变化的信号。新 VM 默认 8192 (8GB 双通道 2×4GB)——start-vm.sh 见
    # RAM>4096 自动拆成 2 条 4GB DIMM 走双通道，两条 SN 各自唯一。老 profile 缺
    # 字段仍退回 4096 (见 stealth_load_profile)，不擅自升级既有 VM 的硬件画像；
    # 个别 VM 要改容量：deploy/scripts/set-vm-memory.sh <N> <size>，启动命令不变。
    MEM_TOTAL_MB="${MEM_TOTAL_MB:-8192}"

    # 6. 显示器（EDID）
    local mo_n=${#MONITOR_POOL[@]}
    local mo_i=$(( (RANDOM * 32768 + RANDOM) % mo_n ))
    local mo_prefix
    IFS='|' read -r EDID_VENDOR EDID_NAME EDID_WIDTH_MM EDID_HEIGHT_MM mo_prefix <<<"${MONITOR_POOL[$mo_i]}"
    EDID_SERIAL="$(_monitor_serial "$mo_prefix")"

    # 7. 键盘 USB HID
    local kbd_n=${#KBD_POOL[@]}
    local kbd_i=$(( (RANDOM * 32768 + RANDOM) % kbd_n ))
    local kbd_prefix
    IFS='|' read -r KBD_VID KBD_PID KBD_MFR KBD_PRODUCT kbd_prefix <<<"${KBD_POOL[$kbd_i]}"
    KBD_SERIAL="$(_usb_hid_serial "$kbd_prefix")"

    # 8. 鼠标 USB HID（相对坐标场景）
    local mou_n=${#MOUSE_POOL[@]}
    local mou_i=$(( (RANDOM * 32768 + RANDOM) % mou_n ))
    local mou_prefix
    IFS='|' read -r MOUSE_VID MOUSE_PID MOUSE_MFR MOUSE_PRODUCT mou_prefix <<<"${MOUSE_POOL[$mou_i]}"
    MOUSE_SERIAL="$(_usb_hid_serial "$mou_prefix")"

    # 9. 数位板 USB HID（绝对坐标场景，自动化默认）
    local tab_n=${#TABLET_POOL[@]}
    local tab_i=$(( (RANDOM * 32768 + RANDOM) % tab_n ))
    local tab_prefix
    IFS='|' read -r TABLET_VID TABLET_PID TABLET_MFR TABLET_PRODUCT tab_prefix <<<"${TABLET_POOL[$tab_i]}"
    TABLET_SERIAL="$(_usb_hid_serial "$tab_prefix")"

    export CPU_QEMU_ARG CPU_VENDOR CPU_NAME CPU_MAX_MHZ CPU_CUR_MHZ CPU_PART CPU_PROC_FAMILY CPU_SOCKET CPU_MODEL CPU_SERIAL
    export BOARD_MFR BOARD_PRODUCT BOARD_FAMILY BOARD_VERSION BOARD_SERIAL BOARD_ASSET BOARD_SUBSYS_VEN BOARD_SUBSYS_DEV
    export SYSTEM_MFR SYSTEM_PRODUCT SYSTEM_FAMILY SYSTEM_VERSION SYSTEM_SERIAL SYSTEM_SKU
    export BIOS_VENDOR BIOS_VERSION BIOS_DATE
    export CHASSIS_TYPE CHASSIS_SERIAL
    export NIC_MAC UUID
    export GPU_VENDOR GPU_NAME GPU_PCI_VEN GPU_PCI_DEV GPU_RAM_MB GPU_BIOS GPU_REV
    export NVME_MODEL NVME_FIRMWARE NVME_SERIAL NVME_SIZE_BYTES
    export MEM_MFR MEM_PART_2G MEM_PART_4G MEM_SERIAL MEM_TOTAL_MB
    export EDID_VENDOR EDID_NAME EDID_WIDTH_MM EDID_HEIGHT_MM EDID_SERIAL
    export KBD_VID KBD_PID KBD_MFR KBD_PRODUCT KBD_SERIAL
    export MOUSE_VID MOUSE_PID MOUSE_MFR MOUSE_PRODUCT MOUSE_SERIAL
    export TABLET_VID TABLET_PID TABLET_MFR TABLET_PRODUCT TABLET_SERIAL
}

# ------------------------------------------------------------------
# 持久化 / 载入
# ------------------------------------------------------------------
_STEALTH_PROFILE_VARS=(
    CPU_QEMU_ARG CPU_VENDOR CPU_NAME CPU_MAX_MHZ CPU_CUR_MHZ CPU_PART CPU_PROC_FAMILY CPU_SOCKET CPU_MODEL CPU_SERIAL
    BOARD_MFR BOARD_PRODUCT BOARD_FAMILY BOARD_VERSION BOARD_SERIAL BOARD_ASSET BOARD_SUBSYS_VEN BOARD_SUBSYS_DEV
    SYSTEM_MFR SYSTEM_PRODUCT SYSTEM_FAMILY SYSTEM_VERSION SYSTEM_SERIAL SYSTEM_SKU
    BIOS_VENDOR BIOS_VERSION BIOS_DATE
    CHASSIS_TYPE CHASSIS_SERIAL
    NIC_MAC UUID
    GPU_VENDOR GPU_NAME GPU_PCI_VEN GPU_PCI_DEV GPU_RAM_MB GPU_BIOS GPU_REV
    NVME_MODEL NVME_FIRMWARE NVME_SERIAL NVME_SIZE_BYTES
    MEM_MFR MEM_PART_2G MEM_PART_4G MEM_SERIAL MEM_TOTAL_MB
    EDID_VENDOR EDID_NAME EDID_WIDTH_MM EDID_HEIGHT_MM EDID_SERIAL
    KBD_VID KBD_PID KBD_MFR KBD_PRODUCT KBD_SERIAL
    MOUSE_VID MOUSE_PID MOUSE_MFR MOUSE_PRODUCT MOUSE_SERIAL
    TABLET_VID TABLET_PID TABLET_MFR TABLET_PRODUCT TABLET_SERIAL
)

stealth_have_profile() { [[ -s "$1" ]]; }

stealth_save_profile() {
    local path="$1"
    local tmp="${path}.tmp.$$"
    mkdir -p "$(dirname "$path")"
    {
        echo "# stealth hardware profile — generated $(date -Iseconds)"
        echo "# 删除此文件 (或运行 reroll-identity.sh) 重新随机化"
        local v
        for v in "${_STEALTH_PROFILE_VARS[@]}"; do
            printf '%s=%q\n' "$v" "${!v}"
        done
    } > "$tmp"
    mv -f "$tmp" "$path"
}

stealth_load_profile() {
    local path="$1"
    # shellcheck disable=SC1090
    source "$path"

    # 老 profile 兼容：缺字段补默认（AMD Ryzen3-1200 + GTX 1050 + Samsung 970 PRO）
    : "${CPU_QEMU_ARG:=Ryzen3-1200}"
    : "${CPU_VENDOR:=AuthenticAMD}"
    : "${CPU_NAME:=AMD Ryzen 3 1200 Quad-Core Processor}"
    : "${CPU_MAX_MHZ:=3400}"
    : "${CPU_CUR_MHZ:=3100}"
    : "${CPU_PART:=YD1200BBM4KAE}"
    : "${CPU_PROC_FAMILY:=0x139}"
    : "${CPU_SOCKET:=AM4}"
    : "${CPU_MODEL:=Ryzen3-1200}"

    # PCI 子系统 ID 老 profile 缺失：按 BOARD_MFR 智能推导每家典型 vendor ID，
    # 避免一律兜回 ASUS 导致"主板是 MSI 但 PCI 子系统报 ASUS"的遗留矛盾。
    # 这样老 VM 不用 reroll 整身份也能修好 PCI 不一致。
    # 新 profile 由 stealth_pick_profile 直接写板厂真实对应值。
    if [[ -z "${BOARD_SUBSYS_VEN:-}" || -z "${BOARD_SUBSYS_DEV:-}" ]]; then
        case "${BOARD_MFR:-}" in
            *Micro-Star*|*MSI*)
                BOARD_SUBSYS_VEN=0x1462; BOARD_SUBSYS_DEV=0x7B49 ;;
            *Gigabyte*)
                BOARD_SUBSYS_VEN=0x1458; BOARD_SUBSYS_DEV=0x5001 ;;
            ASRock*)
                BOARD_SUBSYS_VEN=0x1849; BOARD_SUBSYS_DEV=0x1230 ;;
            *) # ASUS / 未知一律走 ASUS B350-PLUS 默认
                BOARD_SUBSYS_VEN=0x1043; BOARD_SUBSYS_DEV=0x8694 ;;
        esac
    fi

    : "${GPU_VENDOR:=NVIDIA}"
    : "${GPU_NAME:=NVIDIA GeForce GTX 1050}"
    : "${GPU_PCI_VEN:=0x10DE}"
    : "${GPU_PCI_DEV:=0x1C81}"
    : "${GPU_RAM_MB:=2048}"
    : "${GPU_BIOS:=Version 86.07.48.00.38}"
    : "${GPU_REV:=0xA1}"

    : "${NVME_MODEL:=Samsung SSD 970 PRO 512GB}"
    : "${NVME_FIRMWARE:=1B2QEXM7}"

    # 老 profile 没 NVME_SIZE_BYTES 字段：按 NVME_MODEL 名字智能推导，
    # 让历史磁盘容量跟广告容量自洽，避免再次出现 1TB 型号 + 512GB 实盘的 stealth 矛盾。
    # 匹配关键词不命中时兜底 512GB（老 start-vm.sh 行为）。
    if [[ -z "${NVME_SIZE_BYTES:-}" ]]; then
        case "$NVME_MODEL" in
            *1TB*)   NVME_SIZE_BYTES=1000204886016 ;;
            *2TB*)   NVME_SIZE_BYTES=2000398934016 ;;
            *500GB*) NVME_SIZE_BYTES=500107862016 ;;
            *512GB*) NVME_SIZE_BYTES=512110190592 ;;
            *256GB*) NVME_SIZE_BYTES=256060514304 ;;
            *)       NVME_SIZE_BYTES=512000000000 ;;
        esac
    fi

    : "${MEM_MFR:=Kingston}"
    : "${MEM_PART_2G:=KVR26N19S6/2}"
    : "${MEM_PART_4G:=HX426C16FB3A/4}"

    # MEM_SERIAL 老 profile 没这字段：用 UUID 派生 8 字符十六进制，
    # 保证**同一 VM 跨重启 SN 不变**（即便没 reroll，老 VM 也不再每次启动漂移）。
    # 不用纯随机回填——那会让升级后第一次启动仍然换 SN，与"持久化"语义不符。
    # 用 UUID 的 sha256 前 8 字符做确定性派生：UUID 跨 VM 唯一，SN 自然也唯一。
    if [[ -z "${MEM_SERIAL:-}" ]]; then
        if [[ -n "${UUID:-}" ]]; then
            MEM_SERIAL=$(printf '%s' "${UUID}-mem" | sha256sum | head -c 8 | tr '[:lower:]' '[:upper:]')
        else
            # UUID 也没——彻底退化（不应该发生，UUID 是必填字段）
            MEM_SERIAL="00000001"
        fi
    fi

    # MEM_TOTAL_MB 老 profile 没有：留空 → start-vm.sh 退回历史默认 4096 MiB。
    # 不擅自把老 VM 升到 8GB（改内存总量 = 改硬件画像，需用户显式 --ram= 或在
    # profile 里写 MEM_TOTAL_MB）。新 profile 由 stealth_pick_profile 写 8192。
    : "${MEM_TOTAL_MB:=}"

    # 显示器 / 键盘 / 鼠标 / 数位板：老 profile 退化为 QEMU patch 历史默认值
    # （Samsung S24F350F / Microsoft Wired Keyboard 600 / Microsoft USB Optical
    # Mouse / HUION PenTablet）。配合 patch 0009/0010 后默认仍然生效。
    : "${EDID_VENDOR:=SAM}"
    : "${EDID_NAME:=S24F350}"
    : "${EDID_WIDTH_MM:=530}"
    : "${EDID_HEIGHT_MM:=300}"
    : "${EDID_SERIAL:=H4ZK500001VL}"

    : "${KBD_VID:=0x045E}"
    : "${KBD_PID:=0x0750}"
    : "${KBD_MFR:=Microsoft}"
    : "${KBD_PRODUCT:=Microsoft Wired Keyboard 600}"
    : "${KBD_SERIAL:=68284}"

    : "${MOUSE_VID:=0x045E}"
    : "${MOUSE_PID:=0x00CB}"
    : "${MOUSE_MFR:=Microsoft}"
    : "${MOUSE_PRODUCT:=Microsoft USB Optical Mouse}"
    : "${MOUSE_SERIAL:=42}"

    : "${TABLET_VID:=0x256C}"
    : "${TABLET_PID:=0x006D}"
    : "${TABLET_MFR:=HUION}"
    : "${TABLET_PRODUCT:=HUION PenTablet}"
    : "${TABLET_SERIAL:=HU000001}"

    local v
    for v in "${_STEALTH_PROFILE_VARS[@]}"; do
        export "$v"
    done
}

stealth_print_profile() {
    # ---- 内存 ----
    # 取 NUM_DIMMS / PER_DIMM_MB（由 start-vm.sh 按 "RAM≤4096→1条 / >4096→2条" 决策）。
    # 库独立 source 时退化为列出 2G/4G 候选 part。
    local mem_line
    if [[ -n "${RAM:-}" && -n "${NUM_DIMMS:-}" && -n "${PER_DIMM_MB:-}" ]]; then
        local part_used
        if (( PER_DIMM_MB >= 4096 )); then
            part_used="$MEM_PART_4G"
        else
            part_used="$MEM_PART_2G"
        fi
        local slot_layout
        if (( NUM_DIMMS == 1 )); then
            slot_layout="单通道, 2 卡槽占 1 空 1"
        else
            slot_layout="双通道, 2 卡槽全占"
        fi
        local sn_disp="${MEM_SERIAL:-?}"
        if (( NUM_DIMMS == 2 )); then
            # 双通道时两条 DIMM 各自唯一 SN（第 2 条由 MEM_SERIAL 确定性派生），打印出来便于核对
            sn_disp="${MEM_SERIAL:-?}+$(printf '%s' "${MEM_SERIAL}-dimm2" | sha256sum | head -c 8 | tr '[:lower:]' '[:upper:]')"
        fi
        mem_line="${MEM_MFR}  ${RAM} MiB = ${NUM_DIMMS}× $(( PER_DIMM_MB / 1024 )).$(( (PER_DIMM_MB % 1024) * 10 / 1024 )) GiB  part=${part_used}  SN=${sn_disp}  (${slot_layout})"
    else
        mem_line="${MEM_MFR}  (候选: 2G=${MEM_PART_2G} / 4G=${MEM_PART_4G})  SN=${MEM_SERIAL:-?}"
    fi

    # ---- 显卡 / 显示器 ----
    # virtio-vga 主 ID 留 1AF4:1050（virtio），subsys 改成 GPU_PCI_VEN:DEV 让 PCI
    # 树看见 NVIDIA / AMD 子系统；nvapi64.dll shim 把 WMI 名也对齐。
    # EDID 由 patch 0009 加的 edid-vendor/edid-name/edid-serial cmdline 选项从 profile 注入。
    local vga_kind
    if [[ "${VGA_DEV:-virtio-vga}" == virtio-vga-gl* ]]; then
        vga_kind="virtio-vga-gl (virgl 3D)"
    else
        vga_kind="virtio-vga (stable, 无 GL)"
    fi
    # 显示器对角线：sqrt(w²+h²) 毫米 → 英寸（÷25.4）
    local diag_inch
    if [[ -n "${EDID_WIDTH_MM:-}" && -n "${EDID_HEIGHT_MM:-}" ]]; then
        diag_inch=$(echo "scale=1; sqrt(${EDID_WIDTH_MM}^2 + ${EDID_HEIGHT_MM}^2) / 25.4" | bc -l 2>/dev/null || echo "?")
    else
        diag_inch="?"
    fi

    # ---- 网卡 / 声卡 ----
    local nic_line="e1000e (Intel 82574L PCIe Gigabit)  MAC=${NIC_MAC}"
    local audio_line="Intel ICH9 HDA + hda-duplex codec (audiodev=none, 类 Realtek ALC892)"

    # ---- 键盘 / 鼠标 ----
    # 从 profile 读 VID/PID/manufacturer/product/serial，配合 patch 0010
    # 让 -device usb-kbd vendorid= productid= manufacturer= product= serialnumber=
    # 把这些值实际注入 USB 描述符（不再编译期写死 Microsoft）。
    local kbd_line="usb-kbd → ${KBD_PRODUCT} (USB ${KBD_VID/0x/}:${KBD_PID/0x/})"
    local mouse_line
    if [[ "${USB_RELATIVE_MOUSE:-0}" == "1" ]]; then
        mouse_line="usb-mouse → ${MOUSE_PRODUCT} (USB ${MOUSE_VID/0x/}:${MOUSE_PID/0x/}, 相对坐标)"
    else
        mouse_line="usb-tablet → ${TABLET_PRODUCT} (USB ${TABLET_VID/0x/}:${TABLET_PID/0x/}, 绝对坐标)"
    fi

    cat >&2 <<EOF
=== stealth profile ===
  CPU      : $CPU_NAME ($CPU_VENDOR, socket $CPU_SOCKET, QEMU=$CPU_QEMU_ARG)
  Board    : $BOARD_MFR / $BOARD_PRODUCT ($BOARD_VERSION)
  Board SN : $BOARD_SERIAL
  PCI subs : $BOARD_SUBSYS_VEN:$BOARD_SUBSYS_DEV
  System   : $SYSTEM_MFR / $SYSTEM_PRODUCT / $SYSTEM_FAMILY
  System SN: $SYSTEM_SERIAL   SKU=$SYSTEM_SKU
  BIOS     : $BIOS_VENDOR $BIOS_VERSION ($BIOS_DATE)
  Chassis  : $CHASSIS_TYPE  SN=$CHASSIS_SERIAL
  GPU      : $GPU_NAME ($GPU_VENDOR, ${GPU_PCI_VEN}:${GPU_PCI_DEV} rev=${GPU_REV}, ${GPU_RAM_MB}MB, BIOS=$GPU_BIOS)
  Display  : ${vga_kind}, EDID 1920×1080
  显示器   : ${EDID_VENDOR} ${EDID_NAME}  ~${diag_inch}\" (${EDID_WIDTH_MM}×${EDID_HEIGHT_MM} mm)  SN=${EDID_SERIAL}
  NVMe     : $NVME_MODEL  fw=$NVME_FIRMWARE  SN=$NVME_SERIAL  size=$(printf '%.1f' "$(echo "$NVME_SIZE_BYTES / 1024^3" | bc -l 2>/dev/null || echo 0)") GiB ($NVME_SIZE_BYTES B)
  Memory   : ${mem_line}
  网卡     : ${nic_line}
  声卡     : ${audio_line}
  键盘     : ${kbd_line}
  鼠标     : ${mouse_line}
  UUID     : $UUID
=======================
EOF
}

# 给 -cpu 拼出完整字符串（含 stealth 共用旁路 + tsc-freq + vendor）
stealth_qemu_cpu_arg() {
    local tsc_hz=$(( CPU_CUR_MHZ * 1000000 ))
    local extras="kvm=off,hypervisor=off,+invtsc,+tsc-deadline,enforce=off,host-phys-bits=on,tsc-freq=${tsc_hz},vendor=${CPU_VENDOR}"
    # +topoext 是 AMD 专属（CPUID leaf 0x8000001E），Intel 不能加
    if [[ "$CPU_VENDOR" == "AuthenticAMD" ]]; then
        extras="${extras},+topoext"
    fi
    echo "${CPU_QEMU_ARG},${extras}"
}

# Escape commas in SMBIOS string values (QEMU uses ',,' to encode a literal ','
# inside option values).
_e() { echo "${1//,/,,}"; }

# ------------------------------------------------------------------
# SMBIOS 参数构造器，每行一个完整 -smbios option (commas 已转义)
# ------------------------------------------------------------------
stealth_smbios_args() {
    local t0 t1 t2 t3 t4 t11 t16 t17
    local mem_per_dimm_mb="${MEM_PER_DIMM_MB:-2048}"
    local mem_speed="${MEM_SPEED:-2666}"
    local mem_part="$MEM_PART_2G"
    (( mem_per_dimm_mb >= 4096 )) && mem_part="$MEM_PART_4G"

    t0="type=0,vendor=$(_e "$BIOS_VENDOR"),version=$(_e "$BIOS_VERSION"),date=$(_e "$BIOS_DATE"),release=5.14,uefi=on"
    t1="type=1,manufacturer=$(_e "$SYSTEM_MFR"),product=$(_e "$SYSTEM_PRODUCT"),version=$(_e "$SYSTEM_VERSION"),serial=$(_e "$SYSTEM_SERIAL"),uuid=$UUID,sku=$(_e "$SYSTEM_SKU"),family=$(_e "$SYSTEM_FAMILY")"
    t2="type=2,manufacturer=$(_e "$BOARD_MFR"),product=$(_e "$BOARD_PRODUCT"),version=$(_e "$BOARD_VERSION"),serial=$(_e "$BOARD_SERIAL"),asset=$BOARD_ASSET,location=Default string"
    t3="type=3,manufacturer=$(_e "$BOARD_MFR"),version=$(_e "$BOARD_VERSION"),serial=$(_e "$CHASSIS_SERIAL"),asset=$BOARD_ASSET,sku=$(_e "$SYSTEM_SKU")"

    # processor manufacturer 跟 CPU vendor 走
    local cpu_smbios_mfr
    if [[ "$CPU_VENDOR" == "AuthenticAMD" ]]; then
        cpu_smbios_mfr="Advanced Micro Devices Inc."
    else
        cpu_smbios_mfr="Intel(R) Corporation"
    fi

    t4="type=4,sock_pfx=${CPU_SOCKET},manufacturer=$(_e "$cpu_smbios_mfr"),version=$(_e "$CPU_NAME"),serial=$CPU_SERIAL,asset=$(_rand 1000 9999),part=$CPU_PART,max-speed=$CPU_MAX_MHZ,current-speed=$CPU_CUR_MHZ,processor-family=$CPU_PROC_FAMILY"

    case "$BOARD_MFR" in
        ASUS*|*ASUSTeK*)
            local cpu_oem_tag="AMD_Ryzen"
            [[ "$CPU_VENDOR" == "GenuineIntel" ]] && cpu_oem_tag="Intel_Core"
            t11="type=11,value=Default string,value=ASUS_MB_RSVD,value=ASUS_MB_CPU=${cpu_oem_tag},value=ASUS_MB_LINK_URL=http://www.asus.com" ;;
        *Micro-Star*|*MSI*)
            t11="type=11,value=Default string,value=MSI_A_1,value=MSI_OEM_A,value=MSI_OEM_B" ;;
        *Gigabyte*)
            t11="type=11,value=Default string,value=Gigabyte Technology Co.,,Ltd.,value=GBT_OEM_A" ;;
        ASRock*)
            t11="type=11,value=Default string,value=ASRock_Default,value=ASRockName" ;;
        *)
            t11="type=11,value=Default string,value=OEM_Default" ;;
    esac
    # MEM_SERIAL 已经从 profile load 出来（持久化），不再用 _rand 每启动随机。
    # asset 留 9876543210 不动——消费级 DIMM 的 asset tag 真实世界里就是这种
    # 厂商占位字符串或空（Win10 dmidecode 也常报 9876543210 / "Not Specified"）。
    #
    # 每条 DIMM 必须有唯一序列号：真实主板两条内存 SN 必不同。QEMU 单条 type=17
    # 模板原本对所有 DIMM instance 套同一 serial → 双通道时"两条内存同 SN"，是
    # 一眼假的 SMBIOS 伪造特征（Win32_PhysicalMemory.SerialNumber 重复）。已给
    # smbios.c 打补丁：serial 支持 '|' 分隔的 per-DIMM 列表，loc_pfx 支持 %C 通道
    # 替换。第 2 条 SN 由 MEM_SERIAL 确定性派生（sha256 前 8 hex、大写），跨重启
    # 稳定、跨 VM 唯一，无需再往 profile 多存字段；单条 DIMM 时 QEMU 只取 SN1。
    local mem_serial2
    mem_serial2=$(printf '%s' "${MEM_SERIAL}-dimm2" | sha256sum | head -c 8 | tr '[:lower:]' '[:upper:]')
    # loc_pfx=DIMM_%C2 → DIMM_A2 / DIMM_B2（ASUS/AMI 双通道槽位命名）；bank %C → CHANNEL A/B。
    t17="type=17,loc_pfx=DIMM_%C2,bank=P0 CHANNEL %C,manufacturer=$(_e "$MEM_MFR"),serial=${MEM_SERIAL}|${mem_serial2},asset=9876543210,part=$(_e "$mem_part"),speed=$mem_speed"
    t16="type=16,max-capacity=${T16_MAX_CAPACITY:-64G},num-devices=${T16_NUM_DEVICES:-2}"
    printf '%s\n' "$t0" "$t1" "$t2" "$t3" "$t4" "$t11" "$t16" "$t17"
}
