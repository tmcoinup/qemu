#!/usr/bin/env bash
# 验证 guest 侧 apply-gpu-spoof.ps1 的 AutoDetect 映射与 host 侧 GPU_POOL 同步。
#
# clone 后 guest 只能从 PCI SUBSYS 反查 GPU 名称；如果 host 池新增型号但这里漏同步，
# 本地 respawn/EXE 会退回默认 GTX 1050，导致 profile.GPU_NAME 和 guest 注册表不一致。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SPOOF="$REPO_ROOT/deploy/scripts/apply-gpu-spoof.ps1"

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

declare -A expected
declare -A actual

for row in "${GPU_POOL[@]}"; do
    IFS='|' read -r vendor name ven dev ram bios _rev <<<"$row"
    key="$(hex4 "$dev")$(hex4 "$ven")"
    expected["$key"]="$name|$vendor|$bios|$ram"
done

while IFS='|' read -r key name vendor bios ram; do
    actual["${key^^}"]="$name|$vendor|$bios|$ram"
done < <(
    sed -nE "s/^[[:space:]]*'([0-9A-Fa-f]{8})'[[:space:]]*=[[:space:]]*@\\{[[:space:]]*Name='([^']*)';[[:space:]]*Vendor='([^']*)';[[:space:]]*Bios='([^']*)';[[:space:]]*RamMb=([0-9]+)[[:space:]]*\\}.*/\\1|\\2|\\3|\\4|\\5/p" "$SPOOF"
)

[[ "${#actual[@]}" -gt 0 ]] || fail "未解析到 apply-gpu-spoof.ps1 的 gpuMap"

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

echo "OK: guest GPU AutoDetect map matches GPU_POOL"
