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
# shellcheck source=/dev/null
source "$SCRIPT_DIR/fixtures/catalog-cpu-preflight-stub.sh"

# 序列号测试只验证格式与持久化，不应随 CI 机器是 AMD/Intel 而变化。这里显式
# 注入支持 TSC scaling 的 Intel 能力，仍然走真实 enabled bundle 选择路径。
# 选择器通过全局变量名读取这些注入值，显式导出也固定子进程测试环境。
export STEALTH_HOST_CPU_VENDOR=GenuineIntel
export STEALTH_HOST_CPU_MAX_MHZ=5000
export STEALTH_REQUIRED_TSC_MHZ=
export CPUS=4

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

unset_profile_vars() {
    local var
    for var in "${_STEALTH_PROFILE_VARS[@]}"; do
        unset "$var" || true
    done
}

# 标准层并不规定所有厂商序列号的统一样式；DMTF SMBIOS 只要求这些字段
# 是字符串。这里用 printable ASCII + 长度上限做“标准外壳”校验，再用
# 下方的厂商样式正则做“真实设备观感”校验。
assert_ascii_len() {
    local label="$1"
    local value="$2"
    local min_len="$3"
    local max_len="$4"
    local len

    LC_ALL=C grep -Eq '^[ -~]+$' <<< "$value" \
        || fail "$label 含非 printable ASCII: $value"
    len="${#value}"
    (( len >= min_len && len <= max_len )) \
        || fail "$label 长度 $len 不在 [$min_len,$max_len]: $value"
}

assert_mac_is_global_unicast() {
    local label="$1"
    local mac="$2"
    local first_octet

    first_octet=$((16#${mac%%:*}))
    (( (first_octet & 1) == 0 )) || fail "$label NIC_MAC 是 multicast: $mac"
    (( (first_octet & 2) == 0 )) || fail "$label NIC_MAC 是 locally administered: $mac"
}

assert_serials_reasonable() {
    local label="$1"
    [[ "${UUID:-}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] \
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
    [[ "${NIC_MAC:-}" == "${NIC_MAC_OUI:-}":* ]] \
        || fail "$label NIC_MAC 未使用平台 OUI: ${NIC_MAC:-}/${NIC_MAC_OUI:-}"
    assert_mac_is_global_unicast "$label" "${NIC_MAC:-}"
    [[ "${NVME_SERIAL:-}" =~ ^S[A-Z0-9]{3}N[A-Z0-9]{9}$ ]] \
        || fail "$label NVME_SERIAL 异常: ${NVME_SERIAL:-}"
    [[ "${MEM_SERIAL:-}" =~ ^[0-9A-F]{8}$ ]] || fail "$label MEM_SERIAL 异常: ${MEM_SERIAL:-}"
    [[ "${MEM_SERIAL:-}" != "00000000" && "${MEM_SERIAL:-}" != "00000001" &&
       "${MEM_SERIAL:-}" != "FFFFFFFF" ]] \
        || fail "$label MEM_SERIAL 是明显占位值: ${MEM_SERIAL:-}"
    [[ "${EDID_SERIAL:-}" =~ ^H4ZK[A-Z0-9]{8}$ ]] \
        || fail "$label EDID_SERIAL 异常: ${EDID_SERIAL:-}"
    [[ "${NVME_SUBNQN:-}" == "nqn.2014-08.org.nvmexpress:uuid:${UUID:-}" ]] \
        || fail "$label NVME_SUBNQN 未绑定 UUID: ${NVME_SUBNQN:-}"
    [[ "${KBD_SERIAL:-}" =~ ^[A-Z0-9]{4,12}$ ]] || fail "$label KBD_SERIAL 异常: ${KBD_SERIAL:-}"
    [[ "${MOUSE_SERIAL:-}" =~ ^[A-Z0-9]{4,12}$ ]] || fail "$label MOUSE_SERIAL 异常: ${MOUSE_SERIAL:-}"
    [[ "${TABLET_SERIAL:-}" =~ ^[A-Z0-9]{4,12}$ ]] || fail "$label TABLET_SERIAL 异常: ${TABLET_SERIAL:-}"

    # SMBIOS 字段是 null-terminated string 引用；这里把 guest 可见字符串限制在
    # 常见固件/工具能稳定显示的 ASCII 范围，避免空值、控制字符和超长值。
    assert_ascii_len "$label CPU_SERIAL(SMBIOS Type 4)" "${CPU_SERIAL:-}" 1 64
    assert_ascii_len "$label CPU_ASSET(SMBIOS Type 4)" "${CPU_ASSET:-}" 1 64
    assert_ascii_len "$label BOARD_SERIAL(SMBIOS Type 2)" "${BOARD_SERIAL:-}" 1 64
    assert_ascii_len "$label BOARD_ASSET(SMBIOS Type 2)" "${BOARD_ASSET:-}" 1 64
    assert_ascii_len "$label SYSTEM_SERIAL(SMBIOS Type 1)" "${SYSTEM_SERIAL:-}" 1 64
    assert_ascii_len "$label SYSTEM_SKU(SMBIOS Type 1)" "${SYSTEM_SKU:-}" 1 64
    assert_ascii_len "$label CHASSIS_SERIAL(SMBIOS Type 3)" "${CHASSIS_SERIAL:-}" 1 64
    assert_ascii_len "$label MEM_SERIAL(SMBIOS Type 17)" "${MEM_SERIAL:-}" 1 64

    # NVMe Identify Controller 的 SN 字段是 20 字节 ASCII；QEMU 会右侧空格补齐。
    assert_ascii_len "$label NVME_SERIAL(NVMe SN[20])" "${NVME_SERIAL:-}" 1 20
    # 当前生成器保留换行终止符，因此 S24F350 模板固定使用 12 个字符。
    assert_ascii_len "$label EDID_SERIAL(EDID #FF)" "${EDID_SERIAL:-}" 12 12
    # USB HID serial 当前只保存在 profile，设备参数未暴露给 guest；仍限制为短 ASCII。
    assert_ascii_len "$label KBD_SERIAL(profile)" "${KBD_SERIAL:-}" 1 64
    assert_ascii_len "$label MOUSE_SERIAL(profile)" "${MOUSE_SERIAL:-}" 1 64
    assert_ascii_len "$label TABLET_SERIAL(profile)" "${TABLET_SERIAL:-}" 1 64

    local mem_serial2
    mem_serial2="$(_stealth_memory_slot_serial "$MEM_SERIAL" 2)" ||
        fail "$label 无法派生第二条 DIMM SN"
    [[ "$mem_serial2" != "$MEM_SERIAL" &&
       "$mem_serial2" != "00000000" && "$mem_serial2" != "00000001" &&
       "$mem_serial2" != "FFFFFFFF" ]] ||
        fail "$label 双通道 DIMM SN 重复或为占位值: $mem_serial2"
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

test_strict_profile_rejects_invalid_identity() {
    local profile="$TMP_DIR/strict-identity.profile"
    local bad key value

    stealth_pick_profile
    stealth_save_profile "$profile"
    unset_profile_vars
    STRICT_HARDWARE=1 stealth_load_profile "$profile" ||
        fail "合法身份无法严格重载"

    while IFS='|' read -r key value; do
        bad="$TMP_DIR/strict-bad-$key.profile"
        sed "s|^${key}=.*|${key}=${value}|" "$profile" >"$bad"
        unset_profile_vars
        if STRICT_HARDWARE=1 stealth_load_profile "$bad" >/dev/null 2>&1; then
            fail "严格模式接受非法身份字段: $key=$value"
        fi
    done <<'CASES'
UUID|00000000-0000-4000-8000-000000000000
CPU_SERIAL|0000000000
BOARD_ASSET|0000000000
NIC_MAC|ff:ff:ff:ff:ff:ff
NVME_SERIAL|S0000000000N
NVME_SUBNQN|nqn.2014-08.org.nvmexpress:uuid:00000000-0000-4000-8000-000000000000
MEM_SERIAL|00000000
EDID_SERIAL|H4ZK123456789
KBD_SERIAL|UNKNOWN
CASES

    bad="$TMP_DIR/strict-missing-cpu-serial.profile"
    grep -v '^CPU_SERIAL=' "$profile" >"$bad"
    unset_profile_vars
    if STRICT_HARDWARE=1 stealth_load_profile "$bad" >/dev/null 2>&1; then
        fail "严格模式接受缺少 CPU_SERIAL 的 profile"
    fi
}

test_strict_profile_accepts_legacy_hid_tokens() {
    local current="$TMP_DIR/current-hid.profile"
    local legacy="$TMP_DIR/legacy-hid.profile"

    stealth_pick_profile
    stealth_save_profile "$current"
    sed \
        -e 's/^KBD_SERIAL=.*/KBD_SERIAL=MICR12GZ9Q/' \
        -e 's/^MOUSE_SERIAL=.*/MOUSE_SERIAL=MICRAB7Y2X/' \
        -e 's/^TABLET_SERIAL=.*/TABLET_SERIAL=QEMU9Z8Y7X/' \
        "$current" >"$legacy"
    chmod 600 "$legacy"

    unset_profile_vars
    STRICT_HARDWARE=1 stealth_load_profile "$legacy" ||
        fail "严格模式拒绝旧生成器的合法 HID 字母数字 token"
    [[ "$KBD_SERIAL|$MOUSE_SERIAL|$TABLET_SERIAL" == \
       "MICR12GZ9Q|MICRAB7Y2X|QEMU9Z8Y7X" ]] ||
        fail "加载旧 HID token 时发生了身份漂移"
}

test_random_profile_serials
test_missing_serials_are_repaired_stably
test_strict_profile_rejects_invalid_identity
test_strict_profile_accepts_legacy_hid_tokens

echo "OK: hardware serial checks passed"
