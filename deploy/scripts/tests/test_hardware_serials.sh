#!/usr/bin/env bash
# 验证硬件序列号 / UUID / MAC 的格式和兜底修复逻辑。
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

unset_profile_vars() {
    local var
    for var in "${_STEALTH_PROFILE_VARS[@]}"; do
        unset "$var" || true
    done
}

assert_serials_reasonable() {
    local label="$1"
    [[ "${UUID:-}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
        || fail "$label UUID 格式异常: ${UUID:-}"
    [[ "${CPU_SERIAL:-}" =~ ^[0-9]{10}$ ]] || fail "$label CPU_SERIAL 异常: ${CPU_SERIAL:-}"
    [[ "${CPU_ASSET:-}" =~ ^[0-9]{4}$ ]] || fail "$label CPU_ASSET 异常: ${CPU_ASSET:-}"
    [[ "${BOARD_SERIAL:-}" =~ ^[A-Z0-9-]{8,20}$ ]] || fail "$label BOARD_SERIAL 异常: ${BOARD_SERIAL:-}"
    [[ "${BOARD_ASSET:-}" =~ ^[0-9]{10}$ ]] || fail "$label BOARD_ASSET 异常: ${BOARD_ASSET:-}"
    [[ "${SYSTEM_SERIAL:-}" =~ ^[A-Z0-9-]{8,20}$ ]] || fail "$label SYSTEM_SERIAL 异常: ${SYSTEM_SERIAL:-}"
    [[ "${SYSTEM_SKU:-}" =~ ^SKU[0-9]{6}$ ]] || fail "$label SYSTEM_SKU 异常: ${SYSTEM_SKU:-}"
    [[ "${CHASSIS_SERIAL:-}" =~ ^[A-Z0-9-]{8,20}$ ]] || fail "$label CHASSIS_SERIAL 异常: ${CHASSIS_SERIAL:-}"
    [[ "${NIC_MAC:-}" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] || fail "$label NIC_MAC 异常: ${NIC_MAC:-}"
    [[ "${NIC_MAC:-}" != 52:54:00:* ]] || fail "$label NIC_MAC 使用了 QEMU OUI: ${NIC_MAC:-}"
    [[ "${NVME_SERIAL:-}" =~ ^S[0-9A-F]{10}N$ ]] || fail "$label NVME_SERIAL 异常: ${NVME_SERIAL:-}"
    [[ "${MEM_SERIAL:-}" =~ ^[0-9A-F]{8}$ ]] || fail "$label MEM_SERIAL 异常: ${MEM_SERIAL:-}"
    [[ "${MEM_SERIAL:-}" != "00000000" && "${MEM_SERIAL:-}" != "00000001" ]] \
        || fail "$label MEM_SERIAL 是明显占位值: ${MEM_SERIAL:-}"
    [[ "${EDID_SERIAL:-}" =~ ^[A-Z0-9]{8,13}$ ]] || fail "$label EDID_SERIAL 异常: ${EDID_SERIAL:-}"
    [[ "${KBD_SERIAL:-}" =~ ^[A-Z0-9]{4,12}$ ]] || fail "$label KBD_SERIAL 异常: ${KBD_SERIAL:-}"
    [[ "${MOUSE_SERIAL:-}" =~ ^[A-Z0-9]{4,12}$ ]] || fail "$label MOUSE_SERIAL 异常: ${MOUSE_SERIAL:-}"
    [[ "${TABLET_SERIAL:-}" =~ ^[A-Z0-9]{4,12}$ ]] || fail "$label TABLET_SERIAL 异常: ${TABLET_SERIAL:-}"

    local mem_serial2
    mem_serial2="$(printf '%s' "${MEM_SERIAL}-dimm2" | sha256sum | head -c 8 | tr '[:lower:]' '[:upper:]')"
    [[ "$mem_serial2" != "$MEM_SERIAL" ]] || fail "$label 双通道 DIMM SN 重复: $MEM_SERIAL"
}

test_random_profile_serials() {
    local i
    for i in $(seq 1 40); do
        stealth_pick_profile
        assert_serials_reasonable "random#$i"
    done
}

test_missing_serials_are_repaired_stably() {
    local profile="$TMP_DIR/missing-serials.profile"
    local first_uuid first_mac first_nvme first_mem second_uuid second_mac second_nvme second_mem

    stealth_pick_profile
    stealth_save_profile "$profile"
    grep -Ev '^(CPU_SERIAL|CPU_ASSET|BOARD_SERIAL|BOARD_ASSET|SYSTEM_SERIAL|SYSTEM_SKU|CHASSIS_SERIAL|NIC_MAC|UUID|NVME_SERIAL|MEM_SERIAL|EDID_SERIAL|KBD_SERIAL|MOUSE_SERIAL|TABLET_SERIAL)=' \
        "$profile" > "${profile}.tmp"
    mv -f "${profile}.tmp" "$profile"
    chmod 600 "$profile"

    unset_profile_vars
    stealth_load_profile "$profile"
    assert_serials_reasonable "repaired#1"
    first_uuid="$UUID"; first_mac="$NIC_MAC"; first_nvme="$NVME_SERIAL"; first_mem="$MEM_SERIAL"

    unset_profile_vars
    stealth_load_profile "$profile"
    assert_serials_reasonable "repaired#2"
    second_uuid="$UUID"; second_mac="$NIC_MAC"; second_nvme="$NVME_SERIAL"; second_mem="$MEM_SERIAL"

    [[ "$first_uuid" == "$second_uuid" ]] || fail "修复 UUID 不稳定: $first_uuid != $second_uuid"
    [[ "$first_mac" == "$second_mac" ]] || fail "修复 MAC 不稳定: $first_mac != $second_mac"
    [[ "$first_nvme" == "$second_nvme" ]] || fail "修复 NVMe SN 不稳定: $first_nvme != $second_nvme"
    [[ "$first_mem" == "$second_mem" ]] || fail "修复 DIMM SN 不稳定: $first_mem != $second_mem"
}

test_random_profile_serials
test_missing_serials_are_repaired_stably

echo "OK: hardware serial checks passed"
