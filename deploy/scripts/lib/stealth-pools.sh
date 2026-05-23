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

