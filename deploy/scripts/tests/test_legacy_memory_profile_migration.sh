#!/usr/bin/env bash
# 验证 2026-07-19.6 旧 profile 可在不改变 Guest 实际硬件身份的前提下迁移：
#   - 只保留真实安装的 Kingston KVR24N17S8/4（2×4GiB）；
#   - 删除从未曝光且无官方证据的 KVR24N17S6/2 候选；
#   - 把旧 NVMe 内部占位 part number、A804 误标和 14 位序列规范化为当前
#     A808、真实料号与 15 位样本形态。
# shellcheck disable=SC1091,SC2016,SC2034,SC2153
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# shellcheck source=../stealth-lib.sh
source "$REPO_ROOT/deploy/scripts/stealth-lib.sh"

export CPUS=4
export STRICT_HARDWARE=1
export ALLOW_PLATFORM_COMPATIBILITY=0
export ALLOW_STORAGE_PROFILE_MIGRATION=0

SELECT_ID=
stealth_select_platform_bundle() {
    stealth_platform_registry_load "$SELECT_ID" "${CPUS:-4}"
}

unset_profile_vars() {
    local field
    for field in "${_STEALTH_PROFILE_VARS[@]}"; do
        unset "$field"
    done
}

expect_profile_failure() {
    local profile="$1"
    local description="$2"
    if (
        unset_profile_vars
        stealth_load_profile "$profile"
    ) >"$TMP_DIR/expected-failure.log" 2>&1; then
        fail "$description"
    fi
}

configure_legacy_kingston_memory() {
    local configured_mts="$1"

    # 实际拓扑始终是 2×4096MiB，因此 Guest 只看见 KVR24N17S8/4；
    # 2GiB 字段只是旧选择器的候选 ABI。
    PLATFORM_CATALOG_REVISION=2026-07-19.6
    MEM_MFR=Kingston
    MEM_PART_2G=KVR24N17S6/2
    MEM_PART_4G=KVR24N17S8/4
    MEM_RATED=2400
    MEM_RATED_MTS=2400
    MEM_CONFIGURED_MTS="$configured_mts"
    MEM_TOTAL_MB=8192
    MEM_TYPE=DDR4
    MEM_CHANNELS=2
    MEM_VOLTAGE_MV=1200
    MEM_RANK=1
    MEM_RANK_2G=1
    MEM_DEVICE_WIDTH_2G=16
    MEM_RANK_4G=1
    MEM_DEVICE_WIDTH_4G=8
    MEM_MODULE_MB=2048,4096
    MEM_ALLOWED_TOTAL_MB=2048,4096,8192
}

legacy_storage_part_number=
configure_legacy_samsung_storage() {
    local storage_row storage_manufacturer

    storage_row="$(stealth_component_storage_row samsung-970-pro-512gb)"
    IFS='|' read -r NVME_COMPONENT_ID NVME_MODEL NVME_FIRMWARE \
        NVME_SIZE_BYTES NVME_PCI_VEN NVME_PCI_DEV NVME_SUBSYS_VEN \
        NVME_SUBSYS_DEV NVME_SUBNQN_TEMPLATE storage_manufacturer \
        legacy_storage_part_number _ <<<"$storage_row"
    NVME_SERIAL=S123N123456789
    NVME_PCI_DEV=0xA804
    NVME_SUBNQN="${NVME_SUBNQN_TEMPLATE//\{uuid\}/$UUID}"
    COMPONENT_CATALOG_REVISION=2026-07-19.3
    BOOT_STORAGE_CATALOG_REVISION=2026-07-19.3
    BOOT_STORAGE_COMPONENT_ID="$NVME_COMPONENT_ID"
    BOOT_STORAGE_MANUFACTURER="$storage_manufacturer"
    BOOT_STORAGE_MODEL="$NVME_MODEL"
    BOOT_STORAGE_PART_NUMBER=component-catalog
    BOOT_STORAGE_FIRMWARE="$NVME_FIRMWARE"
    BOOT_STORAGE_SIZE_BYTES="$NVME_SIZE_BYTES"
    BOOT_STORAGE_INTERFACE=nvme
    BOOT_STORAGE_SERIAL="$NVME_SERIAL"
}

save_legacy_profile() {
    local profile="$1"

    stealth_save_profile "$profile"
    sed -i \
        -e '/^MEM_FAMILY_ID=/d' \
        -e '/^MEM_MODULE_ID=/d' \
        -e '/^MEM_SELECTED_MODULE_MB=/d' \
        -e '/^MEM_MODULE_COUNT=/d' \
        -e '/^MEM_SPD_EE1004=/d' \
        "$profile"
}

write_forged_later_nvme_profile() {
    local component_id="$1" profile="$2"
    local storage_row storage_manufacturer storage_part_number

    storage_row="$(stealth_component_storage_row "$component_id")"
    IFS='|' read -r NVME_COMPONENT_ID NVME_MODEL NVME_FIRMWARE \
        NVME_SIZE_BYTES NVME_PCI_VEN NVME_PCI_DEV NVME_SUBSYS_VEN \
        NVME_SUBSYS_DEV NVME_SUBNQN_TEMPLATE storage_manufacturer \
        storage_part_number _ <<<"$storage_row"
    NVME_SERIAL="$(_nvme_serial "$component_id")"
    NVME_SUBNQN="${NVME_SUBNQN_TEMPLATE//\{uuid\}/$UUID}"
    COMPONENT_CATALOG_REVISION=2026-07-19.3
    BOOT_STORAGE_CATALOG_REVISION=2026-07-19.3
    BOOT_STORAGE_COMPONENT_ID="$component_id"
    BOOT_STORAGE_MANUFACTURER="$storage_manufacturer"
    BOOT_STORAGE_MODEL="$NVME_MODEL"
    BOOT_STORAGE_PART_NUMBER=component-catalog
    BOOT_STORAGE_FIRMWARE="$NVME_FIRMWARE"
    BOOT_STORAGE_SIZE_BYTES="$NVME_SIZE_BYTES"
    BOOT_STORAGE_INTERFACE=nvme
    BOOT_STORAGE_SERIAL="$NVME_SERIAL"
    stealth_save_profile "$profile"
}

legacy_profile="$TMP_DIR/legacy.profile"
normalized_profile="$TMP_DIR/normalized.profile"
SELECT_ID=intel-lga1151-pentium-g5400-asus-prime-h310m-a-r2
stealth_pick_profile >/dev/null
configure_legacy_kingston_memory 2400
configure_legacy_samsung_storage
save_legacy_profile "$legacy_profile"
legacy_hash="$(sha256sum "$legacy_profile" | cut -d' ' -f1)"

unset_profile_vars
stealth_load_profile "$legacy_profile" >/dev/null
[[ "$_STEALTH_MEMORY_PROFILE_MIGRATION_KIND" == legacy-kingston-4g ]] ||
    fail "旧 Kingston profile 未命中窄范围内存迁移"
[[ "$_STEALTH_STORAGE_PROFILE_MIGRATION_KIND" == \
   samsung-970-pro-catalog-v2 ]] ||
    fail "旧 NVMe A804/14 位序列/part number 未命中窄迁移"
[[ "$NVME_PCI_DEV" == 0xA808 && ${#NVME_SERIAL} -eq 15 ]] ||
    fail "旧 Samsung NVMe 身份未规范化为 A808/15 位序列"
[[ "$MEM_FAMILY_ID|$MEM_MODULE_ID|$MEM_MFR|$MEM_PART_2G|$MEM_PART_4G" == \
   "kingston-kvr24n17-ddr4-2400|kingston-kvr24n17s8-4-ddr4-4g|Kingston||KVR24N17S8/4" ]] ||
    fail "迁移改变了实际 Kingston 品牌/4GiB 料号"
[[ "$MEM_SELECTED_MODULE_MB|$MEM_MODULE_COUNT|$MEM_RANK_4G|$MEM_DEVICE_WIDTH_4G" == \
   "4096|2|1|8" ]] ||
    fail "迁移后的实际 DIMM 容量、数量或几何错误"
[[ "$BOOT_STORAGE_PART_NUMBER" == "$legacy_storage_part_number" ]] ||
    fail "NVMe part number 没有回查稳定组件目录"
[[ "$(sha256sum "$legacy_profile" | cut -d' ' -f1)" == "$legacy_hash" ]] ||
    fail "只读加载阶段提前改写了旧 profile"

identity_before="$UUID|$BOARD_SERIAL|$SYSTEM_SERIAL|$CHASSIS_SERIAL|$MEM_SERIAL|$NVME_SERIAL"
backup_profile="$(stealth_backup_profile_for_migration "$legacy_profile")"
[[ "$(sha256sum "$backup_profile" | cut -d' ' -f1)" == "$legacy_hash" ]] ||
    fail "迁移前恢复副本与旧 profile 不一致"
[[ "$backup_profile" == \
   "$legacy_profile.pre-catalog-migration.$legacy_hash" ]] ||
    fail "恢复副本没有按加载摘要隔离命名"
[[ "$(stat -c '%u|%a' "$backup_profile")" == "$UID|400" ]] ||
    fail "恢复副本 owner/mode 不安全"
stealth_save_profile "$normalized_profile"
unset_profile_vars
stealth_load_profile "$normalized_profile" >/dev/null
identity_after="$UUID|$BOARD_SERIAL|$SYSTEM_SERIAL|$CHASSIS_SERIAL|$MEM_SERIAL|$NVME_SERIAL"
[[ "$identity_after" == "$identity_before" ]] ||
    fail "持久化迁移改变了整机或 DIMM/NVMe 序列身份"
[[ "$_STEALTH_MEMORY_PROFILE_MIGRATION_KIND" == none &&
   "$_STEALTH_STORAGE_PROFILE_MIGRATION_KIND" == none ]] ||
    fail "规范化 profile 重载后仍重复触发迁移"
grep -Fx "MEM_PART_2G=''" "$normalized_profile" >/dev/null ||
    fail "规范化 profile 没有清除无证据的 2GiB 候选"
grep -Fx "BOOT_STORAGE_PART_NUMBER=$legacy_storage_part_number" \
    "$normalized_profile" >/dev/null ||
    fail "规范化 profile 没有保存真实 NVMe 料号"

bad_profile="$TMP_DIR/bad.profile"
cp "$legacy_profile" "$bad_profile"
sed -i 's/^MEM_TOTAL_MB=.*/MEM_TOTAL_MB=2048/' "$bad_profile"
expect_profile_failure "$bad_profile" \
    "2GiB 拓扑错误复用了仅适用于 2×4GiB 的历史别名"

cp "$legacy_profile" "$bad_profile"
sed -i 's/^MEM_DEVICE_WIDTH_4G=.*/MEM_DEVICE_WIDTH_4G=16/' "$bad_profile"
expect_profile_failure "$bad_profile" \
    "篡改后的 Kingston 4GiB SPD 几何仍被迁移"

cp "$legacy_profile" "$bad_profile"
sed -i 's/^PLATFORM_CATALOG_REVISION=.*/PLATFORM_CATALOG_REVISION=2026-07-22.1/' \
    "$bad_profile"
expect_profile_failure "$bad_profile" \
    "新 revision 冒充历史 Kingston 别名仍被迁移"

cp "$legacy_profile" "$bad_profile"
sed -i 's/^BOOT_STORAGE_MODEL=.*/BOOT_STORAGE_MODEL=Tampered\\ SSD/' \
    "$bad_profile"
expect_profile_failure "$bad_profile" \
    "NVMe 元组不完整匹配时仍修复了 part number 占位"

cp "$legacy_profile" "$bad_profile"
sed -i '$aMEM_FAMILY_ID=kingston-kvr24n17-ddr4-2400' "$bad_profile"
expect_profile_failure "$bad_profile" \
    "部分 DIMM 稳定绑定字段被默认值掩盖"

write_forged_later_nvme_profile intel-760p-512gb "$bad_profile"
expect_profile_failure "$bad_profile" \
    "后来加入的 Intel NVMe 伪造旧 revision 后命中了 Samsung 占位迁移"

write_forged_later_nvme_profile wd-pc-sn730-512gb "$bad_profile"
expect_profile_failure "$bad_profile" \
    "后来加入的 WD NVMe 伪造旧 revision 后命中了 Samsung 占位迁移"

# 历史选择器也可能在 H110 上选到同一 Kingston DDR4-2400；实际工作速率会
# 合法降到 2133，迁移不能只覆盖 H310 的 2400 MT/s。
h110_profile="$TMP_DIR/h110-legacy.profile"
unset_profile_vars
COMPONENT_SCHEMA_VERSION=1
COMPONENT_CATALOG_REVISION="$(stealth_component_validate)"
SELECT_ID=intel-lga1151-i5-6400t-asus-h110m-a-m2
stealth_pick_profile >/dev/null
configure_legacy_kingston_memory 2133
configure_legacy_samsung_storage
save_legacy_profile "$h110_profile"
unset_profile_vars
stealth_load_profile "$h110_profile" >/dev/null
[[ "$_STEALTH_MEMORY_PROFILE_MIGRATION_KIND|$MEM_CONFIGURED_MTS" == \
   "legacy-kingston-4g|2133" ]] ||
    fail "合法 H110/2133 Kingston 历史 profile 未迁移"
cp "$h110_profile" "$bad_profile"
sed -i 's/^MEM_CONFIGURED_MTS=.*/MEM_CONFIGURED_MTS=2400/' "$bad_profile"
expect_profile_failure "$bad_profile" \
    "H110 profile 接受了超过平台上限的内存配置速率"

# 恢复副本必须与本次加载摘要严格对应；预置垃圾文件或加载后的源文件变化
# 都不能被静默复用/覆盖。
race_profile="$TMP_DIR/race.profile"
cp "$legacy_profile" "$race_profile"
unset_profile_vars
stealth_load_profile "$race_profile" >/dev/null
race_hash="$_STEALTH_LOADED_PROFILE_HASH"
garbage_backup="$race_profile.pre-catalog-migration.$race_hash"
printf 'garbage\n' >"$garbage_backup"
chmod 0666 "$garbage_backup"
if stealth_backup_profile_for_migration \
        "$race_profile" "$race_hash" >/dev/null 2>&1; then
    fail "预置的可写垃圾文件被当成有效迁移恢复副本"
fi
rm -f -- "$garbage_backup"
stealth_backup_profile_for_migration \
    "$race_profile" "$race_hash" >/dev/null
sed -i 's/^MEM_SERIAL=.*/MEM_SERIAL=DEADBEEF/' "$race_profile"
if stealth_save_profile "$race_profile" "$race_hash"; then
    fail "迁移提交静默覆盖了加载后被修改的 profile"
fi

symlink_profile="$TMP_DIR/profile-link"
ln -s "$legacy_profile" "$symlink_profile"
expect_profile_failure "$symlink_profile" \
    "profile 叶路径符号链接未被拒绝"

empty_profile="$TMP_DIR/empty.profile"
: >"$empty_profile"
stealth_have_profile "$empty_profile" ||
    fail "空 profile 节点被误判为首次创建"
expect_profile_failure "$empty_profile" \
    "空 profile 会触发自动重抽身份"

dangling_profile="$TMP_DIR/dangling.profile"
ln -s "$TMP_DIR/missing-target" "$dangling_profile"
stealth_have_profile "$dangling_profile" ||
    fail "断裂 profile 链接被误判为首次创建"
expect_profile_failure "$dangling_profile" \
    "断裂 profile 链接会触发自动重抽身份"

echo "PASS: legacy profiles migrate exact installed DIMMs without identity drift"
