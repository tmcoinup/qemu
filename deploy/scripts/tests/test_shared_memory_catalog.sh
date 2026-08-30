#!/usr/bin/env bash
# 验证共享 DIMM 目录、Linux 投影、Windows 投影与 C 层 SPD 品牌码一致。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CATALOG="$REPO_ROOT/deploy/hardware/memory.json"
C_SOURCE="$REPO_ROOT/hw/i2c/smbus_eeprom_spd.c"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# shellcheck source=../lib/stealth-memory-catalog.sh
source "$REPO_ROOT/deploy/scripts/lib/stealth-memory-catalog.sh"

[[ "$(stealth_memory_catalog_validate)" == "2026-08-29-memory-r1" ]] \
    || fail "共享目录 revision 未通过 Linux 校验"

mapfile -t active_rows < <(stealth_memory_catalog_active_rows)
mapfile -t quarantine_rows < <(stealth_memory_catalog_quarantine_rows)
(( ${#active_rows[@]} == 6 )) || fail "旧 ABI 可投影的 active family 数量错误"
(( ${#quarantine_rows[@]} == 2 )) || fail "quarantine family 数量错误"

# 新 module-plans 协议按实际存在的 DIMM SKU 选型，不要求同 family 伪造
# 2GiB/4GiB 配对。这里同时锁定字段顺序、稳定排序与 Kingston 4GB 单品。
mapfile -t ddr4_module_plans < <(
    python3 "$REPO_ROOT/deploy/scripts/memory_catalog.py" "$CATALOG" \
        module-plans DDR4 LGA1151 2 1200 2 8192 \
        2048,4096 2133,2400 2400
)
expected_ddr4_module_plans=(
    "samsung-m378a5x44-ddr4-2400|samsung-m378a5244cb0-crc-ddr4-4g|Samsung|DDR4|M378A5244CB0-CRC|2400|2400|1200|AM4,LGA1151,LGA1200|1|16|4096|2|50|1"
    "kingston-kvr24n17-ddr4-2400|kingston-kvr24n17s8-4-ddr4-4g|Kingston|DDR4|KVR24N17S8/4|2400|2400|1200|AM4,LGA1151,LGA1200|1|8|4096|2|30|1"
    "crucial-ctxg4dfs-ddr4-2400|crucial-ct4g4dfs824a-ddr4-4g|Crucial|DDR4|CT4G4DFS824A|2400|2400|1200|AM4,LGA1151,LGA1200|1|8|4096|2|20|1"
)
(( ${#ddr4_module_plans[@]} == 3 )) \
    || fail "module-plans 未返回 Samsung/Kingston/Crucial 三个系列"
for index in "${!expected_ddr4_module_plans[@]}"; do
    [[ "${ddr4_module_plans[$index]}" == \
       "${expected_ddr4_module_plans[$index]}" ]] \
        || fail "module-plans 第 $index 行协议或实际 DIMM 选择错误"
done

# LGA1151 当前平台全部是 DDR4 板；即使 DDR3 速率集合看似可用，也不能仅凭
# socket/频率误选 1.5V DDR3。Kingston DDR4 只有官方可证的 4GB 单品，
# Windows 可按实际容量选择；Linux 旧双料号 ABI 暂不为凑数伪造 2GB SKU。
mapfile -t ddr4_lga1151 < <(
    stealth_memory_platform_candidate_rows \
        DDR4 LGA1151 2 1200 2 8192 2048,4096 2133,2400 2400
)
(( ${#ddr4_lga1151[@]} == 2 )) \
    || fail "Linux 旧 ABI 应得到 Samsung/Crucial 两个完整 DDR4 系列"
for row in "${ddr4_lga1151[@]}"; do
    IFS='|' read -r _ _ manufacturer type _ _ rated configured voltage \
        _ _ _ _ _ module_mib module_count _ ee1004 <<<"$row"
    [[ "$type|$rated|$configured|$voltage|$module_mib|$module_count|$ee1004" == \
       "DDR4|2400|2400|1200|4096|2|1" ]] \
        || fail "DDR4 平台候选字段矛盾: $row"
    [[ "$manufacturer" =~ ^(Samsung|Crucial)$ ]] \
        || fail "quarantine/未知品牌进入 LGA1151 DDR4 候选: $row"
done

if stealth_memory_platform_candidate_rows \
        DDR3 LGA1151 2 1500 2 8192 2048,4096 1333,1600 1600 |
        grep -q .; then
    fail "DDR3 跨代泄漏到 LGA1151 DDR4 平台"
fi
mapfile -t ddr3_lga1155 < <(
    stealth_memory_platform_candidate_rows \
        DDR3 LGA1155 2 1500 4 8192 2048,4096 1333,1600 1600
)
(( ${#ddr3_lga1155[@]} == 3 )) \
    || fail "LGA1155 DDR3 应得到三个活动系列"
for row in "${ddr3_lga1155[@]}"; do
    [[ "$row" == *"|DDR3|"* && "$row" == *"|1500|"* &&
       "$row" == *"|4096|2|"* && "$row" == *"|0" ]] \
        || fail "DDR3 候选没有关闭 EE1004 或拓扑错误: $row"
done

[[ "$(stealth_memory_catalog_family_id \
    Samsung M378A5644EB0-CRC M378A5244CB0-CRC 2400)" == \
    "samsung-m378a5x44-ddr4-2400" ]] \
    || fail "旧 profile 四元组不能解析为稳定 family ID"
[[ "$(stealth_memory_catalog_geometry \
    SK\ hynix HMT325U6CFR8C-PB HMT351U6CFR8C-PB 1600)" == \
    "1|8|2|8" ]] || fail "SK hynix DDR3 SPD 几何错误"
if stealth_memory_catalog_geometry \
        SK\ hynix HMA425U6AFR6N-UH HMA851U6AFR6N-UH 2400 >/dev/null; then
    fail "quarantine SK hynix DDR4 被严格 active 查询接受"
fi

python3 - "$CATALOG" "$C_SOURCE" <<'PY'
import json
import re
import sys

catalog = json.load(open(sys.argv[1], encoding="utf-8"))
source = open(sys.argv[2], encoding="utf-8").read()
policy = catalog["serial_policy"]
if (policy["field_bytes"], policy["pattern"]) != (4, "^[0-9A-F]{8}$"):
    raise SystemExit("SPD serial 不是 JEDEC 四字节/八位大写十六进制")
for value in ("00000000", "00000001", "FFFFFFFF"):
    if value not in policy["reserved_values"]:
        raise SystemExit(f"SPD serial 未隔离保留值 {value}")
for name, facts in catalog["manufacturers"].items():
    module = facts["module_jep106"]
    needle = (
        rf'\{{ "{re.escape(name)}",\s+\{{ {module[0].lower()}, '
        rf'{module[1].lower()} \}}'
    )
    if not re.search(needle, source.lower(), re.IGNORECASE):
        raise SystemExit(f"{name} JEP106 与 C 层不一致")
active = [item for item in catalog["modules"] if item["status"] == "active"]
if {item["manufacturer"] for item in active} != {
    "Samsung", "Kingston", "Crucial", "SK hynix"
}:
    raise SystemExit("active 目录未覆盖四个品牌")
PY

if command -v pwsh >/dev/null 2>&1; then
    linux_modules="$(
        jq -r '.modules[] | select(.status == "active") |
            [.id,.manufacturer,.part_number,.type,.module_mib,.rated_mts] |
            join("|")' "$CATALOG" | sort
    )"
    windows_modules="$(
        REPO_ROOT="$REPO_ROOT" pwsh -NoLogo -NoProfile -Command '
            . (Join-Path $env:REPO_ROOT "deploy/windows/lib/VMate.Manifest.ps1")
            . (Join-Path $env:REPO_ROOT "deploy/windows/lib/VMate.Memory.ps1")
            Get-VMateMemoryPartCatalog | ForEach-Object {
                "{0}|{1}|{2}|{3}|{4}|{5}" -f $_.id, $_.manufacturer,
                    $_.part_number, $_.type, $_.module_mib, $_.rated_mts
            }
        ' | sort
    )"
    [[ "$windows_modules" == "$linux_modules" ]] \
        || fail "Linux/Windows 活动 DIMM 投影不一致"
fi

echo "PASS: shared multi-brand memory catalog"
