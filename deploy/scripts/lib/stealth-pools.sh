# ------------------------------------------------------------------
# CPU/主板兼容视图
#
# 权威数据已经迁移到 deploy/hardware/platforms.json。这里保留 CPU_POOL 和
# BOARD_POOL 两个数组只是为了兼容尚未迁移的只读工具与测试；数组由同一个 JSON
# 自动投影，不允许手工追加条目。随机选择本身直接按 PLATFORM_POOL 选整机 bundle。
# ------------------------------------------------------------------
_STEALTH_POOLS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_STEALTH_POOLS_LIB_DIR/stealth-platforms.sh"
source "$_STEALTH_POOLS_LIB_DIR/stealth-components.sh"

if ! stealth_platform_validate >/dev/null || ! stealth_component_validate >/dev/null; then
    return 1 2>/dev/null || exit 1
fi

COMPONENT_SCHEMA_VERSION=1
COMPONENT_CATALOG_REVISION="$(stealth_component_validate)"

mapfile -t PLATFORM_POOL < <(stealth_platform_index)
mapfile -t CPU_POOL < <(stealth_platform_legacy_cpu_rows)
mapfile -t BOARD_POOL < <(stealth_platform_legacy_board_rows)

# ------------------------------------------------------------------
# GPU 池 —— 低端入门为主，NVIDIA + AMD 都覆盖。
# 格式：VENDOR|NAME|PCI_VEN|PCI_DEV|RAM_MB|BIOS_STRING|REV|
#       MEMORY_TYPE|MEMORY_BUS_WIDTH_BITS|BASE_CLOCK_KHZ|BOOST_CLOCK_KHZ|
#       MEMORY_CLOCK_KHZ|SLI_SUPPORTED
#
# MEMORY_CLOCK_KHZ 按 NVAPI clock-domain 口径保存，不是包装上的 GDDR
# 有效传输率。例如 GTX 1050 Ti 的 3504000 kHz 会被 GPU-Z 显示为
# 1752 MHz memory clock；不能把 7 Gbps 误填成 7000000 kHz。
# ------------------------------------------------------------------
GPU_POOL=(
    # NVIDIA (Pascal/Maxwell 低端)
    "NVIDIA|NVIDIA GeForce GTX 750 Ti|0x10DE|0x1380|2048|Version 82.07.41.00.32|0xA2|GDDR5|128|1020000|1085000|2700000|0"
    "NVIDIA|NVIDIA GeForce GT 1030|0x10DE|0x1D01|2048|Version 86.08.46.00.81|0xA1|GDDR5|64|1227000|1468000|3004000|0"
    "NVIDIA|NVIDIA GeForce GTX 1050|0x10DE|0x1C81|2048|Version 86.07.48.00.38|0xA1|GDDR5|128|1354000|1455000|3504000|0"
    "NVIDIA|NVIDIA GeForce GTX 1050 Ti|0x10DE|0x1C82|4096|Version 86.07.48.00.A0|0xA1|GDDR5|128|1290000|1392000|3504000|0"
    # AMD Polaris 低端
    "AMD|AMD Radeon RX 550|0x1002|0x699F|2048|016.011.000.029.000000|0xCF|GDDR5|128|1100000|1183000|3500000|0"
    "AMD|AMD Radeon RX 560|0x1002|0x67FF|4096|016.011.000.029.000000|0xCF|GDDR5|128|1175000|1275000|3500000|0"
)

# NVMe 不再维护手写多型号池。C 层只实现了 970 PRO 512GB 的完整 PCI/固件
# bundle；目录会拒绝 960/EVO/980 和错误 subsystem，避免型号随机但控制器不变。
mapfile -t NVME_POOL < <(stealth_component_rows storage)

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

# EDID/HID 也必须与 C descriptor 同源。当前仅启用完整 Samsung EDID、Microsoft
# 键鼠模板和明确标为虚拟通用绝对指针的 tablet；未实现深层 descriptor 的品牌不随机。
mapfile -t MONITOR_POOL < <(stealth_component_rows monitor)
mapfile -t KBD_POOL < <(stealth_component_rows keyboards)
mapfile -t MOUSE_POOL < <(stealth_component_rows mice)
mapfile -t TABLET_POOL < <(stealth_component_rows tablets)
