# shellcheck shell=bash
# shellcheck disable=SC2034 # 数组与 revision 由后续 source 模块消费。
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
source "$_STEALTH_POOLS_LIB_DIR/stealth-memory-catalog.sh"

if ! stealth_platform_validate >/dev/null ||
   ! stealth_component_validate >/dev/null ||
   ! stealth_memory_catalog_validate >/dev/null; then
    return 1 2>/dev/null || exit 1
fi

COMPONENT_SCHEMA_VERSION=1
COMPONENT_CATALOG_REVISION="$(stealth_component_validate)"

mapfile -t PLATFORM_POOL < <(stealth_platform_index)
mapfile -t CPU_POOL < <(stealth_platform_legacy_cpu_rows)
mapfile -t BOARD_POOL < <(stealth_platform_legacy_board_rows)

# 新抽签池只含经过核验的 AIB 原子 bundle；旧 generic label 目录只用于已有
# profile 的兼容回查，绝不参与新 profile 选择。
mapfile -t GPU_POOL < <(stealth_component_rows gpu)
mapfile -t GPU_WEIGHT_ROWS < <(stealth_component_weight_rows gpu)
mapfile -t LEGACY_GPU_POOL < <(stealth_component_legacy_gpu_rows)
mapfile -t LEGACY_GPU_INDEX < <(stealth_component_legacy_gpu_index)

# NVMe 由共享目录投影；每行都是 C 层已实现的完整 PCI/固件/OUI/序列策略画像。
# 权重单独投影，避免复制常用品牌条目来制造隐式概率。
mapfile -t NVME_POOL < <(stealth_component_rows storage)
mapfile -t NVME_WEIGHT_ROWS < <(stealth_component_weight_rows storage)

# 九字段数组仅保留给旧只读工具；新 profile 必须走平台联合候选 API。
mapfile -t MEM_POOL < <(stealth_memory_catalog_active_rows)
mapfile -t MEM_QUARANTINED_POOL < <(
    stealth_memory_catalog_quarantine_rows
)
MEM_DORMANT_POOL=()

# EDID/HID 也必须与 C descriptor 同源。显示器条目统一限定为 1920x1080、
# 16:9 并携带完整 EDID 模板；键鼠和通用 tablet 仍只启用 C descriptor 可表达项。
mapfile -t MONITOR_POOL < <(stealth_component_rows monitor)
mapfile -t MONITOR_WEIGHT_ROWS < <(stealth_component_weight_rows monitor)
mapfile -t KBD_POOL < <(stealth_component_rows keyboards)
mapfile -t MOUSE_POOL < <(stealth_component_rows mice)
mapfile -t TABLET_POOL < <(stealth_component_rows tablets)
