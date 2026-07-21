#!/usr/bin/env bash
# 验证 guest 侧 apply-gpu-spoof.ps1 的 AutoDetect 映射与 host 侧 GPU_POOL 同步。
#
# clone 后 guest 只能从 PCI SUBSYS 反查 GPU 名称；如果 host 池新增型号但这里漏同步，
# 本地 respawn/EXE 会退回默认 GTX 1050，导致 profile.GPU_NAME 和 guest 注册表不一致。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SPOOF="$REPO_ROOT/deploy/scripts/apply-gpu-spoof.ps1"
APPLY_SUPPORT="$REPO_ROOT/deploy/scripts/gpu-spoof-apply-support.ps1"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

hex4() {
    local value="${1#0x}"
    value="${value#0X}"
    value="${value^^}"
    printf '%04X' "$((16#$value))"
}

source "$REPO_ROOT/deploy/scripts/stealth-lib.sh"
[[ -f "$APPLY_SUPPORT" ]] || fail "缺少 apply AutoDetect helper: $APPLY_SUPPORT"
grep -F "Join-Path \$PSScriptRoot 'gpu-spoof-apply-support.ps1'" "$SPOOF" >/dev/null \
    || fail "apply 没有从同目录加载 AutoDetect helper"

declare -A expected
declare -A actual

for row in "${GPU_POOL[@]}"; do
    IFS='|' read -r vendor name ven dev ram bios _rev memory_type bus_width \
        base_clock boost_clock memory_clock sli_supported <<<"$row"
    key="$(hex4 "$dev")$(hex4 "$ven")"
    expected["$key"]="$name|$vendor|$bios|$ram|$memory_type|$bus_width|$base_clock|$boost_clock|$memory_clock|$sli_supported"
done

while IFS='|' read -r key name vendor bios ram memory_type bus_width base_clock \
        boost_clock memory_clock sli_supported; do
    actual["${key^^}"]="$name|$vendor|$bios|$ram|$memory_type|$bus_width|$base_clock|$boost_clock|$memory_clock|$sli_supported"
done < <(
    # sed 的反向引用只保证 \1..\9，字段扩展后用 Perl 的 $10/$11
    # 明确取值，避免把它们错解为“$1 后跟字面 0/1”。
    perl -ne 'if (/^\s*'"'"'([0-9A-Fa-f]{8})'"'"'\s*=\s*\@\{\s*Name='"'"'([^'"'"']*)'"'"';\s*Vendor='"'"'([^'"'"']*)'"'"';\s*Bios='"'"'([^'"'"']*)'"'"';\s*RamMb=([0-9]+);\s*MemoryType='"'"'([^'"'"']*)'"'"';\s*BusWidthBits=([0-9]+);\s*BaseClockKHz=([0-9]+);\s*BoostClockKHz=([0-9]+);\s*MemoryClockKHz=([0-9]+);\s*SliSupported=([01])\s*\}/) { print "$1|$2|$3|$4|$5|$6|$7|$8|$9|$10|$11\n"; }' "$APPLY_SUPPORT"
)

[[ "${#actual[@]}" -gt 0 ]] || fail "未解析到 apply support helper 的 gpuMap"

for key in "${!expected[@]}"; do
    [[ "${actual[$key]+set}" == "set" ]] \
        || fail "guest gpuMap 缺少 SUBSYS_$key (${expected[$key]})"
    [[ "${actual[$key]}" == "${expected[$key]}" ]] \
        || fail "SUBSYS_$key 不一致: actual='${actual[$key]}' expected='${expected[$key]}'"
done

for key in "${!actual[@]}"; do
    [[ "${expected[$key]+set}" == "set" ]] \
        || fail "guest gpuMap 含 host GPU_POOL 没有的 SUBSYS_$key (${actual[$key]})"
done

# VM2 的验收型号是 GTX 1050 Ti；把用户明确给出的 NVAPI clock
# 口径固定为单独断言，避免 host 池与 guest map 同时被误改后仍“一致”。
[[ "${actual[1C8210DE]}" == \
   'NVIDIA GeForce GTX 1050 Ti|NVIDIA|Version 86.07.48.00.A0|4096|GDDR5|128|1290000|1392000|3504000|0' ]] \
    || fail "VM2 GTX 1050 Ti 完整 GPU bundle 发生偏移: ${actual[1C8210DE]}"

echo "OK: guest GPU AutoDetect map matches GPU_POOL"
