#!/usr/bin/env bash
# V-11 继承的 4C/8T、6C/12T X79 正常池与一键封装回归。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
MANIFEST="$REPO_ROOT/deploy/hardware/platforms.json"
MEMORY="$REPO_ROOT/deploy/hardware/memory.json"
WRAPPER="$REPO_ROOT/deploy/scripts/start-home-vm.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

PYTHONPATH="$REPO_ROOT/deploy/scripts" python3 - "$MANIFEST" "$MEMORY" <<'PY'
import json
import pathlib
import sys

from memory_catalog import load_catalog, platform_plans
from platform_manifest import load_manifest

manifest = load_manifest(pathlib.Path(sys.argv[1]))
catalog = load_catalog(pathlib.Path(sys.argv[2]))
x79 = [item for item in manifest["platforms"] if item["board"]["pch"] == "Intel X79"]
if len(x79) != 15:
    raise SystemExit(f"X79 原子组合应为 15，实际 {len(x79)}")

cpus = {
    "Core-i7-3820": (4, 8, "BX80619I73820", 1600),
    "Core-i7-4820K": (4, 8, "BX80633I74820K", 1866),
    "Core-i7-3930K": (6, 12, "BX80619I73930K", 1600),
    "Core-i7-4930K": (6, 12, "BX80633I74930K", 1866),
    "Core-i7-4960X": (6, 12, "BX80633I74960X", 1866),
}
boards = {
    "P9X79": ("ASUSTeK COMPUTER INC.", 8, 1866),
    "GA-X79-UP4": ("Gigabyte Technology Co., Ltd.", 8, 1866),
    "X79 Extreme4": ("ASRock", 4, 1600),
}
if {item["cpu"]["qemu_arg"] for item in x79} != set(cpus):
    raise SystemExit("五款 X79 CPU 型号不完整")
if {item["board"]["product"] for item in x79} != set(boards):
    raise SystemExit("三款 X79 主板型号不完整")

for item in x79:
    cpu = item["cpu"]
    board = item["board"]
    cores, threads, part, cpu_max = cpus[cpu["qemu_arg"]]
    manufacturer, slots, board_max = boards[board["product"]]
    expected_rate = min(cpu_max, board_max)
    if (cpu["cores"], cpu["threads"], cpu["part"]) != (cores, threads, part):
        raise SystemExit(f"{item['id']}: CPU 拓扑/料号错误")
    if (board["manufacturer"], board["dimm_slots"]) != (manufacturer, slots):
        raise SystemExit(f"{item['id']}: 主板厂商/槽位错误")
    if item["memory"]["max_mts"] != expected_rate:
        raise SystemExit(f"{item['id']}: 内存频率超过 CPU/主板共同上限")
    if item["memory"]["allowed_total_mib"] != [4096, 8192, 12288, 16384]:
        raise SystemExit(f"{item['id']}: 4/8/12/16G 容量不完整")
    nvme = item["devices"]["nvme"]
    if nvme["boot_supported"] or nvme["attachment"] != "pcie_add_in":
        raise SystemExit(f"{item['id']}: X79 错误冒充原生 M.2/NVMe 启动")

if sum(item["memory"]["max_mts"] == 1866 for item in x79) != 6:
    raise SystemExit("应只有三款 Ivy Bridge-E × 两款 1866 主板进入 DDR3-1866")

modules = [
    module for module in catalog["modules"]
    if module["status"] == "active"
    and "LGA2011" in module["allowed_sockets"]
    and 4 in module["allowed_platform_channel_counts"]
]
families = {module["family_id"] for module in modules}
brands = {module["manufacturer"] for module in modules}
if len(families) != 3 or brands != {"Samsung", "Kingston", "SK hynix"}:
    raise SystemExit(f"LGA2011 内存应为三个真实品牌系列，实际 {brands}")
for family in families:
    if {m["module_mib"] for m in modules if m["family_id"] == family} != {2048, 4096}:
        raise SystemExit(f"{family}: 缺少 2G/4G 配对料号")
samsung = [m for m in modules if m["manufacturer"] == "Samsung"]
if {m["rated_mts"] for m in samsung} != {1866} or min(m["selection_weight"] for m in samsung) <= max(
    m["selection_weight"] for m in modules if m["manufacturer"] != "Samsung"
):
    raise SystemExit("Samsung DDR3-1866 没有成为合法组合中的最高优先级")

for total in (4096, 8192, 12288, 16384):
    plans = platform_plans(
        catalog, "DDR3", "LGA2011", 4, 1500, 4, total,
        {2048, 4096}, {1600, 1866}, 1866, "x79-test", False,
    )
    if not plans:
        raise SystemExit(f"{total}MiB 没有合法 LGA2011 内存方案")
PY

# registry 必须把无原生 M.2 的 X79 映射成 SATA 启动 + PCIe NVMe 数据盘。
# shellcheck source=../stealth-lib.sh
source "$REPO_ROOT/deploy/scripts/stealth-lib.sh"
stealth_platform_registry_load intel-lga2011-i7-4820k-asus-p9x79 8
[[ "$PLATFORM_BOOT_STORAGE" == sata-ahci &&
   "$PLATFORM_BOOT_STORAGE_POOL_ID" == samsung-sata-pro-512gb &&
   "$PLATFORM_STORAGE_SWITCH_REQUIRED" == 1 && "$NVME_ROLE" == data-only ]] \
    || fail "X79 启动盘/数据盘角色没有诚实分离"
[[ "$PLATFORM_DEFAULT_MEMORY_MIB" == 8192 ]] || fail "默认内存不是 8G"

# 在临时目录放同目录 fake start-vm，验证封装参数，不启动 QEMU、不写真实实例。
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
cp "$WRAPPER" "$tmp_dir/start-home-vm.sh"
cat >"$tmp_dir/start-vm.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$CAPTURE"
SH
chmod +x "$tmp_dir/start-home-vm.sh" "$tmp_dir/start-vm.sh"

capture="$tmp_dir/4c8t.args"
CAPTURE="$capture" IMAGE_ROOT="$tmp_dir/images" \
    "$tmp_dir/start-home-vm.sh" 31 --spec 4c8t
grep -Fx '31' "$capture" >/dev/null || fail "封装丢失实例号"
grep -Fx -- '--cpus=8' "$capture" >/dev/null || fail "4C/8T 没映射成 8 vCPU"
grep -Fx -- '--ram=8192' "$capture" >/dev/null || fail "默认内存不是 8G"
grep -Fx -- '--platform-id=intel-lga2011-i7-4820k-asus-p9x79' "$capture" >/dev/null \
    || fail "4C/8T 没优先选择 DDR3-1866 平台"

capture="$tmp_dir/6c12t.args"
CAPTURE="$capture" IMAGE_ROOT="$tmp_dir/images" \
    "$tmp_dir/start-home-vm.sh" 32 --spec=6c12t --memory-size=16G --headless
grep -Fx -- '--cpus=12' "$capture" >/dev/null || fail "6C/12T 没映射成 12 vCPU"
grep -Fx -- '--ram=16384' "$capture" >/dev/null || fail "16G 没映射成 16384MiB"
grep -Fx -- '--platform-id=intel-lga2011-i7-4960x-asus-p9x79' "$capture" >/dev/null \
    || fail "6C/12T 没优先选择 DDR3-1866 平台"
grep -Fx -- '--headless' "$capture" >/dev/null || fail "透传参数丢失"

if CAPTURE="$tmp_dir/bad.args" IMAGE_ROOT="$tmp_dir/images" \
    "$tmp_dir/start-home-vm.sh" 33 --spec 4c8t \
    --platform-id=intel-lga2011-i7-4960x-asus-p9x79 >/dev/null 2>&1; then
    fail "封装接受了规格与平台不一致的组合"
fi
if CAPTURE="$tmp_dir/bad-memory.args" IMAGE_ROOT="$tmp_dir/images" \
    "$tmp_dir/start-home-vm.sh" 34 --spec 6c12t --memory-size 6G >/dev/null 2>&1; then
    fail "封装接受了未授权内存容量"
fi
if CAPTURE="$tmp_dir/bad-platform.args" IMAGE_ROOT="$tmp_dir/images" \
    "$tmp_dir/start-home-vm.sh" 35 --spec 4c8t \
    --platform-id=intel-lga2011-i7-4820k-not-a-real-board >/dev/null 2>&1; then
    fail "封装接受了只匹配前缀的未知主板"
fi

# 已有实例在未显式指定容量/平台时必须沿用 profile，不能被封装默认 8G/ASUS 覆盖。
mkdir -p "$tmp_dir/images/vms/36"
printf 'PLATFORM_ID=intel-lga2011-i7-3820-asrock-x79-extreme4\n' \
    >"$tmp_dir/images/vms/36/profile"
capture="$tmp_dir/existing.args"
CAPTURE="$capture" IMAGE_ROOT="$tmp_dir/images" \
    "$tmp_dir/start-home-vm.sh" 36 --spec 4c8t
if grep -Eq -- '^--ram=|^--platform-id=' "$capture"; then
    fail "已有实例被默认内存或平台覆盖"
fi

# reroll 是新身份，未指定容量/平台时应重新采用本规格的 8G/1866 首选组合。
capture="$tmp_dir/reroll.args"
CAPTURE="$capture" IMAGE_ROOT="$tmp_dir/images" \
    "$tmp_dir/start-home-vm.sh" 36 --spec 4c8t --reroll
grep -Fx -- '--ram=8192' "$capture" >/dev/null || fail "reroll 没恢复新身份 8G 默认值"
grep -Fx -- '--platform-id=intel-lga2011-i7-4820k-asus-p9x79' "$capture" >/dev/null \
    || fail "reroll 没恢复 4C/8T 的 1866 首选平台"

echo "PASS: V-11 home X79 pool"
