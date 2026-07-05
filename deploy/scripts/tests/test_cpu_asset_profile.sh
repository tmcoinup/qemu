#!/usr/bin/env bash
# 验证 CPU asset tag 已纳入 profile，避免 SMBIOS Type 4 每次启动随机变化。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

source "$REPO_ROOT/deploy/scripts/stealth-lib.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

make_profile() {
    local path="$1"
    local omit_asset="${2:-0}"

    # 先走正式随机身份生成/保存路径，再覆盖待测 CPU 字段，保证 profile 结构完整。
    stealth_pick_profile
    CPU_SERIAL=1642844234
    CPU_ASSET=6999
    UUID=237c3804-420b-41bf-8155-1b8808de43a8
    stealth_save_profile "$path"

    if [[ "$omit_asset" == "1" ]]; then
        grep -v '^CPU_ASSET=' "$path" > "${path}.tmp"
        mv -f "${path}.tmp" "$path"
        chmod 600 "$path"
    fi
}

type4_line() {
    MEM_PER_DIMM_MB=4096 stealth_smbios_args | grep '^type=4,'
}

test_explicit_cpu_asset_is_used() {
    local profile="$TMP_DIR/explicit.profile"
    local type4

    make_profile "$profile"
    unset CPU_ASSET
    stealth_load_profile "$profile"

    [[ "${CPU_ASSET:-}" == "6999" ]] \
        || fail "profile CPU_ASSET was not loaded"

    type4="$(type4_line)"
    [[ "$type4" == *",serial=1642844234,asset=6999,"* ]] \
        || fail "SMBIOS type=4 did not use profile CPU_ASSET: $type4"
}

test_missing_cpu_asset_is_stable() {
    local profile="$TMP_DIR/missing.profile"
    local first second

    make_profile "$profile" 1

    unset CPU_ASSET
    stealth_load_profile "$profile"
    first="${CPU_ASSET:-}"

    unset CPU_ASSET
    stealth_load_profile "$profile"
    second="${CPU_ASSET:-}"

    [[ "$first" =~ ^[0-9]{4}$ ]] \
        || fail "derived CPU_ASSET is not a 4-digit tag: $first"
    [[ "$first" == "$second" ]] \
        || fail "derived CPU_ASSET changed between loads: $first != $second"
}

test_invalid_cpu_asset_is_repaired() {
    local profile="$TMP_DIR/invalid.profile"
    local type4

    make_profile "$profile"
    sed -i 's/^CPU_ASSET=.*/CPU_ASSET=bad-asset/' "$profile"

    unset CPU_ASSET
    stealth_load_profile "$profile"

    [[ "${CPU_ASSET:-}" =~ ^[0-9]{4}$ ]] \
        || fail "invalid CPU_ASSET was not repaired: ${CPU_ASSET:-}"

    type4="$(type4_line)"
    [[ "$type4" != *bad-asset* ]] \
        || fail "SMBIOS type=4 leaked invalid CPU_ASSET: $type4"
}

test_explicit_cpu_asset_is_used
test_missing_cpu_asset_is_stable
test_invalid_cpu_asset_is_repaired

echo "OK: CPU asset profile checks passed"
