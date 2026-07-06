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
    # AMD DDR3 家用平台：只收无核显消费级型号；2C/2T 或 4C/4T，总线程不超过 4。
    "phenom,model-id=AMD Athlon(tm) II X2 250 Processor|AuthenticAMD|AMD Athlon(tm) II X2 250 Processor|3000|3000|ADX250OCK23GQ|0x83|AM3"
    "phenom,model-id=AMD Athlon(tm) II X4 640 Processor|AuthenticAMD|AMD Athlon(tm) II X4 640 Processor|3000|3000|ADX640WFK42GM|0x83|AM3"
    "phenom,model-id=AMD Phenom(tm) II X4 955 Processor|AuthenticAMD|AMD Phenom(tm) II X4 955 Processor|3200|3200|HDZ955FBK4DGM|0x83|AM3"
    "Opteron_G5,model-id=AMD FX(tm)-4100 Quad-Core Processor|AuthenticAMD|AMD FX(tm)-4100 Quad-Core Processor|3800|3600|FD4100WMW4KGU|0x8F|AM3+"
    "Opteron_G5,model-id=AMD FX(tm)-4300 Quad-Core Processor|AuthenticAMD|AMD FX(tm)-4300 Quad-Core Processor|4000|3800|FD4300WMW4MHK|0x8F|AM3+"
    "Opteron_G5,model-id=AMD Athlon(tm) X4 860K Quad Core Processor|AuthenticAMD|AMD Athlon(tm) X4 860K Quad Core Processor|4000|3700|AD860KXBJABOX|0x8F|FM2+"
    # Intel LGA1151 Coffee Lake，"F" 后缀 = 无 UHD 630 iGPU（本池硬约束：排除核显，
    # 见 stealth_pick_profile 的 host-aware 选择——AMD 宿主机不会挑到这些 Intel）。
    # 都是 4C/4T 无 HT：桌面 2C/4T 全部带核显，且把无 HT 的 i3 谎报成 2C/4T+HT 本身
    # 是破绽，故无核显约束下只做 4H4C（4 核 4 线程）。current-speed 贴近常见
    # 睿频/基频区间，max-speed 保留官方最大值，避免把已发售 SKU 报成不存在规格。
    "Skylake-Client-IBRS,family=6,model=158,stepping=10,model-id=Intel(R) Core(TM) i3-9100F CPU @ 3.60GHz|GenuineIntel|Intel(R) Core(TM) i3-9100F CPU @ 3.60GHz|4200|3600|GX80684I39100F|0xCD|LGA1151"
    # Intel DDR3 家用平台：P/K 中无核显 SKU，全部 4C/4T；不使用 Xeon E3 / E 系列。
    "SandyBridge-IBRS,model-id=Intel(R) Core(TM) i5-2380P CPU @ 3.10GHz|GenuineIntel|Intel(R) Core(TM) i5-2380P CPU @ 3.10GHz|3400|3100|BX80623I52380P|0xCD|LGA1155"
    "SandyBridge-IBRS,model-id=Intel(R) Core(TM) i5-2550K CPU @ 3.40GHz|GenuineIntel|Intel(R) Core(TM) i5-2550K CPU @ 3.40GHz|3800|3400|BX80623I52550K|0xCD|LGA1155"
    "IvyBridge-IBRS,model-id=Intel(R) Core(TM) i5-3350P CPU @ 3.10GHz|GenuineIntel|Intel(R) Core(TM) i5-3350P CPU @ 3.10GHz|3300|3100|BX80637I53350P|0xCD|LGA1155"
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
    # DDR3 AMD 家用平台：870/970/A88X，无 CPU 核显；显卡仍走独显池。
    "AM3|ASUSTeK COMPUTER INC.|M4A87TD EVO|M4A87TD EVO|Rev 1.xx|_serial_asus|0x1043|0x843E"
    "AM3|Gigabyte Technology Co., Ltd.|GA-870A-UD3|GA-870A-UD3|x.x|_serial_giga|0x1458|0x5001"
    "AM3|Micro-Star International Co., Ltd.|870A-G54 (MS-7599)|MSI|1.0|_serial_msi|0x1462|0x7599"
    "AM3|ASRock|870 Extreme3|870 Extreme3|Default string|_serial_asr|0x1849|0x0870"
    "AM3+|ASUSTeK COMPUTER INC.|M5A97 R2.0|M5A97|Rev 1.xx|_serial_asus|0x1043|0x84EF"
    "AM3+|Gigabyte Technology Co., Ltd.|GA-970A-DS3P|GA-970A-DS3P|x.x|_serial_giga|0x1458|0x5001"
    "AM3+|Micro-Star International Co., Ltd.|970A-G43 (MS-7693)|MSI|3.0|_serial_msi|0x1462|0x7693"
    "AM3+|ASRock|970 Extreme3 R2.0|970 Extreme3|Default string|_serial_asr|0x1849|0x0970"
    "FM2+|ASUSTeK COMPUTER INC.|A88XM-A|A88XM-A|Rev X.0x|_serial_asus|0x1043|0x85CB"
    "FM2+|Gigabyte Technology Co., Ltd.|GA-F2A88XM-D3H|GA-F2A88XM-D3H|x.x|_serial_giga|0x1458|0x5001"
    "FM2+|Micro-Star International Co., Ltd.|A88XM-E35 (MS-7721)|MSI|6.0|_serial_msi|0x1462|0x7721"
    "FM2+|ASRock|FM2A88X Extreme4+|FM2A88X Extreme4+|Default string|_serial_asr|0x1849|0xA88A"
    # DDR3 Intel 家用平台：P67/Z77 搭配无核显 Core i5 P/K 型号。
    "LGA1155|ASUSTeK COMPUTER INC.|P8P67 LE|P8P67|Rev 3.0|_serial_asus|0x1043|0x844D"
    "LGA1155|ASUSTeK COMPUTER INC.|P8Z77-V LX|P8Z77|Rev X.0x|_serial_asus|0x1043|0x84CA"
    "LGA1155|Gigabyte Technology Co., Ltd.|GA-P67A-D3-B3|GA-P67A-D3-B3|x.x|_serial_giga|0x1458|0x5001"
    "LGA1155|Micro-Star International Co., Ltd.|P67A-C43 (MS-7673)|MSI|1.0|_serial_msi|0x1462|0x7673"
    "LGA1155|ASRock|P67 Pro3|P67 Pro3|Default string|_serial_asr|0x1849|0x7673"
    # LGA1151 v2 (H310/B360/H370 入门)
    "LGA1151|ASUSTeK COMPUTER INC.|PRIME H310M-K|PRIME|Rev 1.xx|_serial_asus|0x1043|0x8694"
    "LGA1151|ASUSTeK COMPUTER INC.|PRIME B360M-A|PRIME|Rev 1.xx|_serial_asus|0x1043|0x8694"
    "LGA1151|ASUSTeK COMPUTER INC.|PRIME H370-A|PRIME|Rev 1.xx|_serial_asus|0x1043|0x8694"
    "LGA1151|Micro-Star International Co., Ltd.|H310M PRO-VL (MS-7B75)|MSI|1.0|_serial_msi|0x1462|0x7B75"
    "LGA1151|Micro-Star International Co., Ltd.|B360M PRO-VH (MS-7B53)|MSI|1.0|_serial_msi|0x1462|0x7B53"
    "LGA1151|Gigabyte Technology Co., Ltd.|H310M S2H|H310M|x.x|_serial_giga|0x1458|0x5001"
    "LGA1151|Gigabyte Technology Co., Ltd.|B360M D2V|B360M|x.x|_serial_giga|0x1458|0x5001"
    "LGA1151|ASRock|B360M Pro4|B360M Pro4|Default string|_serial_asr|0x1849|0x1230"
    "LGA1151|ASRock|H310CM-HDV|H310CM-HDV|Default string|_serial_asr|0x1849|0x9696"
    # LGA1200 (H410/B460/H470 入门)
    "LGA1200|ASUSTeK COMPUTER INC.|PRIME H410M-A|PRIME|Rev 1.xx|_serial_asus|0x1043|0x8694"
    "LGA1200|ASUSTeK COMPUTER INC.|PRIME B460M-A|PRIME|Rev 1.xx|_serial_asus|0x1043|0x8694"
    "LGA1200|Micro-Star International Co., Ltd.|H410M PRO (MS-7C89)|MSI|1.0|_serial_msi|0x1462|0x7C89"
    "LGA1200|Micro-Star International Co., Ltd.|B460M PRO-VDH WIFI (MS-7C83)|MSI|1.0|_serial_msi|0x1462|0x7C83"
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
# **全部限定 PCIe 3.0 x4**（2026-05-26）：本套主板池是 AM4 Zen1/Zen+
# (B350/X370/B450) + Intel LGA1151(300系) / LGA1200(400系) 入门平台，这些 CPU
# 直连 lane 都是 PCIe 3.0。原来的 980 PRO / 990 PRO 是 PCIe 4.0 盘——装在这些
# 老平台上要么协商降到 Gen3(link speed 与型号宣称不符)，要么型号本身对 Zen1
# 时代的整机就过于超前(时间线矛盾)。故移除 Gen4 盘，只留 Gen3：
#   970 PRO / 970 EVO / 970 EVO Plus / 980(非PRO) / 960 EVO / 960 PRO，均 Gen3 x4。
# ⚠ 受 use-samsung-id=on 约束(PCI 厂商 ID 锁 Samsung 144D)，本池只能放 Samsung；
#   要上 WD/Crucial/海康等多品牌须先让 nvme 设备按品牌切 PCI vendor-id(另议)。
#
# **RAW_BYTES 列**：之前一律建 512GB qcow2，但池里有 1TB/500GB 多规格——抽到
# "980 1TB" 时 WMI 看到 Model=1TB 但 Size=476GiB(512×10⁹) 即矛盾。按真实
# advertised capacity 填字节：
#   500GB = 500,107,862,016 B (~465.7 GiB)
#   512GB = 512,110,190,592 B (~476.9 GiB)
#   1TB   = 1,000,204,886,016 B (~931.5 GiB)
# qcow2 是 sparse 的，1TB 镜像不会立即占 host 1TB（只占实际写入）。
# ------------------------------------------------------------------
NVME_POOL=(
    # Samsung 970 PRO (MLC, Gen3 x4)
    "Samsung SSD 970 PRO 512GB|1B2QEXM7|512110190592"
    "Samsung SSD 970 PRO 1TB|1B2QEXM7|1000204886016"
    # Samsung 970 EVO (TLC, Gen3 x4)
    "Samsung SSD 970 EVO 500GB|1B2QEXE7|500107862016"
    "Samsung SSD 970 EVO 1TB|1B2QEXE7|1000204886016"
    # Samsung 970 EVO Plus (TLC, Gen3 x4)
    "Samsung SSD 970 EVO Plus 500GB|2B2QEXM7|500107862016"
    "Samsung SSD 970 EVO Plus 1TB|2B2QEXM7|1000204886016"
    # Samsung 980 (非 PRO, DRAM-less TLC, Gen3 x4)
    "Samsung SSD 980 500GB|3B4QFXO7|500107862016"
    "Samsung SSD 980 1TB|3B4QFXO7|1000204886016"
    # Samsung 960 EVO / 960 PRO (Polaris, Gen3 x4, M.2 2280)
    "Samsung SSD 960 EVO 500GB|3B7QCXE7|500107862016"
    "Samsung SSD 960 PRO 512GB|4B6QCXP7|512110190592"
)

# ------------------------------------------------------------------
# 内存 part / 厂商池 —— 低端 4G 总量典型搭配。
# Format: MFR|PART_2G|PART_4G|RATED_MTS|SOCKETS
# ------------------------------------------------------------------
# 增 RATED_MTS 列(2026-05-26)：颗粒额定速率(JEDEC/型号编码)。**报告速率 = min(本列,
# CPU 平台内存上限)** —— 见 stealth-smbios.sh::_cpu_max_mem。这样既不会出现"i3-9100F
# (官方 DDR4-2400)却报 2666"、也不会"2400 颗粒报 2666"，CPU/主板/内存频率三者配套。
# 速率随颗粒(随机)+CPU(随机)而变 = 规格随机但永不超平台。
MEM_POOL=(
    # DDR4：AM4 / LGA1151 / LGA1200
    "Crucial|CT2G4DFS6266|CT4G4DFS8266|2666|AM4,LGA1151,LGA1200"
    "Samsung|M378A5644EB0-CRC|M378A5244CB0-CRC|2400|AM4,LGA1151,LGA1200"
    "Kingston|KVR24N17S6/2|KVR24N17S8/4|2400|AM4,LGA1151,LGA1200"
    "Crucial|CT2G4DFS624A|CT4G4DFS824A|2400|AM4,LGA1151,LGA1200"
    "SK hynix|HMA425U6AFR6N-UH|HMA851U6AFR6N-UH|2400|AM4,LGA1151,LGA1200"
    # DDR3：只保留能核验到 2G/4G 成对真实型号的 1333/1600 桌面 UDIMM。
    # AM3 / Sandy Bridge 这类 CPU 上限为 1333，选择阶段会按 _cpu_max_mem 自动过滤。
    "Kingston|KVR16N11S6/2|KVR16N11S8/4|1600|AM3+,FM2+,LGA1155"
    "Crucial|CT25664BA160B|CT51264BA160B|1600|AM3+,FM2+,LGA1155"
    "SK hynix|HMT325U6CFR8C-PB|HMT351U6CFR8C-PB|1600|AM3+,FM2+,LGA1155"
    "Kingston|KVR13N9S6/2|KVR13N9S8/4|1333|AM3,AM3+,FM2+,LGA1155"
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
