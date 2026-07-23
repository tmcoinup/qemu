#!/usr/bin/env bash
# 验证统一平台 registry 的 profile 持久化边界。测试只操作临时文件，不启动 VM：
#   1. 旧物理目录 profile 可确定性回填新增字段，但显式篡改绝不被修复；
#   2. household/host profile 从首次创建起必须完整保存并逐字段重建绑定；
#   3. E5 v3/v4 正常池无需 allow；其余 compatibility 仍要求显式授权。
# 部分事实通过变量名数组间接写入 profile，静态分析无法看到其读取点。
# shellcheck disable=SC1091,SC2034
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

source "$REPO_ROOT/deploy/scripts/stealth-lib.sh"

export CPUS=4
export STRICT_HARDWARE=1
export ALLOW_PLATFORM_COMPATIBILITY=0
export ALLOW_STORAGE_PROFILE_MIGRATION=0

# 使用真实 registry 加载固定 ID；只替换随机选择步骤，部件生成、保存和重载仍走
# 生产代码。这样测试无需依赖当前物理宿主 CPU，也不会用 QEMU/KVM。
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

generate_profile() {
    local platform_id="$1" destination="$2"
    SELECT_ID="$platform_id"
    # catalog/schema 修订号由库加载时初始化，平台和部件生成器会覆盖具体事实；
    # 不能在 pick 前把这些只读目录常量一并 unset。
    stealth_pick_profile >/dev/null
    stealth_save_profile "$destination"
}

assert_profile_fields_present() {
    local profile="$1" field
    shift
    for field in "$@"; do
        grep -q "^${field}=" "$profile" ||
            fail "$profile 缺少持久化字段 $field"
    done
}

remove_profile_fields() {
    local source="$1" destination="$2" field
    shift 2
    cp "$source" "$destination"
    for field in "$@"; do
        sed -i "/^${field}=/d" "$destination"
    done
    chmod 0600 "$destination"
}

replace_profile_field() {
    local source="$1" destination="$2" field="$3" encoded_value="$4"
    cp "$source" "$destination"
    grep -q "^${field}=" "$destination" ||
        fail "无法构造篡改：原 profile 缺少 $field"
    sed -i "s|^${field}=.*$|${field}=${encoded_value}|" "$destination"
    chmod 0600 "$destination"
}

force_legacy_samsung_nvme_bundle() {
    local profile="$1" uuid
    uuid="$(stealth_profile_get UUID "$profile")" ||
        fail "无法读取 legacy fixture UUID"
    sed -i \
        -e 's|^NVME_COMPONENT_ID=.*|NVME_COMPONENT_ID=samsung-970-pro-512gb|' \
        -e 's|^NVME_MODEL=.*|NVME_MODEL=Samsung\\ SSD\\ 970\\ PRO\\ 512GB|' \
        -e 's|^NVME_FIRMWARE=.*|NVME_FIRMWARE=1B2QEXP7|' \
        -e 's|^NVME_SERIAL=.*|NVME_SERIAL=S123N123456789|' \
        -e 's|^NVME_SIZE_BYTES=.*|NVME_SIZE_BYTES=512110190592|' \
        -e 's|^NVME_PCI_VEN=.*|NVME_PCI_VEN=0x144D|' \
        -e 's|^NVME_PCI_DEV=.*|NVME_PCI_DEV=0xA804|' \
        -e 's|^NVME_SUBSYS_VEN=.*|NVME_SUBSYS_VEN=0x144D|' \
        -e 's|^NVME_SUBSYS_DEV=.*|NVME_SUBSYS_DEV=0xA801|' \
        -e 's|^NVME_SUBNQN_TEMPLATE=.*|NVME_SUBNQN_TEMPLATE=nqn.2014-08.org.nvmexpress:uuid:{uuid}|' \
        -e "s|^NVME_SUBNQN=.*|NVME_SUBNQN=nqn.2014-08.org.nvmexpress:uuid:$uuid|" \
        "$profile"
}

load_profile_success() {
    local profile="$1"
    unset_profile_vars
    stealth_load_profile "$profile" >/dev/null
}

failure_count=0
expect_profile_failure() {
    local profile="$1" description="$2"
    local log="$TMP_DIR/failure-$failure_count.log"
    failure_count=$((failure_count + 1))
    if (
        unset_profile_vars
        stealth_load_profile "$profile"
    ) >"$log" 2>&1; then
        fail "$description"
    fi
}

metadata_fields=(
    "${_STEALTH_PLATFORM_METADATA_VARS[@]}"
    "${_STEALTH_HOST_CPU_BINDING_VARS[@]}"
)
boot_storage_fields=(
    "${_STEALTH_BOOT_STORAGE_PROFILE_VARS[@]}"
)

# 新物理目录 profile 必须保存统一来源、启动盘语义以及空 host 绑定字段。
static_profile="$TMP_DIR/static.profile"
generate_profile intel-lga1151-i5-6400t-asus-h110m-a-m2 "$static_profile"
assert_profile_fields_present "$static_profile" "${metadata_fields[@]}"
assert_profile_fields_present "$static_profile" "${boot_storage_fields[@]}"
load_profile_success "$static_profile"
[[ "$PLATFORM_CPU_SOURCE" == manifest &&
   "$PLATFORM_BOOT_STORAGE_POOL_ID" == component-nvme &&
   "$PLATFORM_BOOT_STORAGE" == nvme &&
   "$PLATFORM_BOOT_MODEL" == component &&
   "$PLATFORM_BOOT_FIRMWARE" == component &&
   "$PLATFORM_STORAGE_SWITCH_REQUIRED" == 0 &&
   "$NVME_ROLE" == boot &&
   "$BOOT_STORAGE_COMPONENT_ID" == "$NVME_COMPONENT_ID" &&
   "$BOOT_STORAGE_MODEL" == "$NVME_MODEL" &&
   "$BOOT_STORAGE_FIRMWARE" == "$NVME_FIRMWARE" &&
   "$BOOT_STORAGE_SIZE_BYTES" == "$NVME_SIZE_BYTES" &&
   "$BOOT_STORAGE_SERIAL" == "$NVME_SERIAL" ]] ||
    fail "物理目录启动盘 metadata 未完整往返"
[[ -z "$CPU_HOST_FINGERPRINT" && -z "$CPU_HOST_MODEL" ]] ||
    fail "物理目录 profile 意外携带 host CPU 绑定"

# 发布统一 registry 之前的 schema-1 物理 profile 不含上述字段。只允许这种
# “字段缺失”的静态迁移；内存回填不能改写 profile 文件本身。
old_static_profile="$TMP_DIR/static-old.profile"
remove_profile_fields \
    "$static_profile" "$old_static_profile" \
    "${metadata_fields[@]}" "${boot_storage_fields[@]}"
force_legacy_samsung_nvme_bundle "$old_static_profile"
sed -i \
    's/^PLATFORM_CATALOG_REVISION=.*/PLATFORM_CATALOG_REVISION=2026-07-13.4/' \
    "$old_static_profile"
old_hash="$(sha256sum "$old_static_profile")"
ALLOW_STORAGE_PROFILE_MIGRATION=1
load_profile_success "$old_static_profile"
ALLOW_STORAGE_PROFILE_MIGRATION=0
[[ "$PLATFORM_CPU_SOURCE" == manifest &&
   "$PLATFORM_BOOT_STORAGE_POOL_ID" == component-nvme &&
   "$PLATFORM_BOOT_MODEL" == component &&
   "$PLATFORM_BOOT_FIRMWARE" == component &&
   "$BOOT_STORAGE_MODEL" == "$NVME_MODEL" &&
   "$BOOT_STORAGE_SERIAL" == "$NVME_SERIAL" &&
   -z "$CPU_HOST_FINGERPRINT" ]] ||
    fail "旧物理 profile 没有得到确定性 registry 回填"
[[ "$old_hash" == "$(sha256sum "$old_static_profile")" ]] ||
    fail "读取旧物理 profile 时改写了持久化文件"

# 显式值（包括显式空值）与真正缺字段语义不同，不能被 legacy 默认值修复。
tampered_static="$TMP_DIR/static-tampered.profile"
remove_profile_fields \
    "$static_profile" "$tampered_static" PLATFORM_BOOT_MODEL
expect_profile_failure "$tampered_static" \
    "当前目录版本的物理 profile 删除 metadata 后被当作旧档回填"
replace_profile_field \
    "$static_profile" "$tampered_static" PLATFORM_CPU_SOURCE host-passthrough
expect_profile_failure "$tampered_static" \
    "物理 profile 的 CPU 来源篡改被默认值修复后放行"
replace_profile_field \
    "$static_profile" "$tampered_static" PLATFORM_BOOT_MODEL "''"
expect_profile_failure "$tampered_static" \
    "物理 profile 的显式空启动盘型号被回填后放行"
replace_profile_field \
    "$static_profile" "$tampered_static" CPU_NAME "''"
expect_profile_failure "$tampered_static" \
    "物理 profile 的显式空 CPU 名称被 legacy 默认值修复后放行"
replace_profile_field \
    "$static_profile" "$tampered_static" SYSTEM_CHASSIS_TYPE "''"
expect_profile_failure "$tampered_static" \
    "物理 profile 的显式空 chassis 类型被 legacy 默认值修复后放行"
replace_profile_field \
    "$static_profile" "$tampered_static" PLATFORM_CATALOG_REVISION "''"
expect_profile_failure "$tampered_static" \
    "物理 profile 的显式空目录修订号被 legacy 默认值修复后放行"

# H81 household 路径把 NVMe 降为数据盘，并严格持久化 SATA 启动盘实物型号。
household_profile="$TMP_DIR/household.profile"
ALLOW_PLATFORM_COMPATIBILITY=0
generate_profile compat-haswell-i3-4130-h81 "$household_profile"
assert_profile_fields_present "$household_profile" "${metadata_fields[@]}"
assert_profile_fields_present "$household_profile" "${boot_storage_fields[@]}"
load_profile_success "$household_profile"
[[ "$PLATFORM_STATUS" == supported &&
   "$PLATFORM_CPU_SOURCE" == named-household-compatibility &&
   "$PLATFORM_BOOT_STORAGE_POOL_ID" == samsung-sata-pro-512gb &&
   "$PLATFORM_BOOT_STORAGE" == sata-ahci &&
   "$PLATFORM_BOOT_MODEL" == storage-compatibility-pool &&
   "$PLATFORM_BOOT_FIRMWARE" == storage-compatibility-pool &&
   "$PLATFORM_STORAGE_SWITCH_REQUIRED" == 1 &&
   "$NVME_ROLE" == data-only &&
   "$BOOT_STORAGE_COMPONENT_ID" == samsung-*-pro-512gb-sata &&
   "$BOOT_STORAGE_MODEL" == Samsung\ SSD\ *\ PRO\ 512GB &&
   "$BOOT_STORAGE_SIZE_BYTES" == 512110190592 &&
   "$BOOT_STORAGE_INTERFACE" == "SATA 6 Gb/s" &&
   "$BOOT_STORAGE_SERIAL" != "$NVME_SERIAL" ]] ||
    fail "household SATA 启动盘 metadata 未完整往返"
stealth_storage_compat_binding_is_current ||
    fail "household SATA 启动盘未按持久化 ID 重建"

# G3220 虽与 i3/i5 共用 H81 主板，但 CPU 内存控制器只允许 DDR3-1333。
# `.6` 之前持久化的 1600 档不能因旧 revision 获得静默迁移，必须重建实例身份。
g3220_profile="$TMP_DIR/household-g3220.profile"
legacy_g3220="$TMP_DIR/household-g3220-legacy.profile"
CPUS=2
generate_profile compat-haswell-g3220-h81 "$g3220_profile"
CPUS=4
if ! grep -Fx 'MEM_MAX_MTS=1333' "$g3220_profile" >/dev/null ||
   ! grep -Fx 'MEM_ALLOWED_MTS=1333' "$g3220_profile" >/dev/null; then
    fail "G3220 profile 没有锁定 DDR3-1333"
fi
cp "$g3220_profile" "$legacy_g3220"
sed -i \
    -e 's/^PLATFORM_CATALOG_REVISION=.*/PLATFORM_CATALOG_REVISION=2026-07-19.5/' \
    -e 's/^MEM_MAX_MTS=.*/MEM_MAX_MTS=1600/' \
    -e 's/^MEM_ALLOWED_MTS=.*/MEM_ALLOWED_MTS=1333,1600/' \
    "$legacy_g3220"
ALLOW_STORAGE_PROFILE_MIGRATION=1
expect_profile_failure "$legacy_g3220" \
    "旧 G3220 DDR3-1600 profile 被静默迁移到当前审计组合"
ALLOW_STORAGE_PROFILE_MIGRATION=0

# 旧 .4 profile 使用同一稳定 ID，但状态仍是 compatibility。目录升级只在
# 内存中做窄范围单向迁移，文件本身和其余硬件事实保持不变。
promoted_legacy="$TMP_DIR/household-promoted-legacy.profile"
cp "$household_profile" "$promoted_legacy"
sed -i \
    -e 's/^PLATFORM_CATALOG_REVISION=.*/PLATFORM_CATALOG_REVISION=2026-07-19.4/' \
    -e 's/^PLATFORM_STATUS=supported$/PLATFORM_STATUS=compatibility/' \
    "$promoted_legacy"
promoted_hash="$(sha256sum "$promoted_legacy")"
load_profile_success "$promoted_legacy"
[[ "$PLATFORM_STATUS" == supported ]] ||
    fail "旧 Haswell household profile 未单向提升为 supported"
[[ "$promoted_hash" == "$(sha256sum "$promoted_legacy")" ]] ||
    fail "Haswell 状态迁移改写了持久化 profile"

current_status_tamper="$TMP_DIR/household-current-status-tamper.profile"
replace_profile_field \
    "$household_profile" "$current_status_tamper" \
    PLATFORM_STATUS compatibility
expect_profile_failure "$current_status_tamper" \
    "当前 revision 的 supported 状态篡改被当作旧 profile 迁移"

# 扩池/修订目录说明不能让已持久化的合法 ID 失效；revision 保留为诊断信息，
# 型号、料号、固件、容量和接口仍由当前目录逐项重建。
older_storage_revision="$TMP_DIR/household-older-storage-revision.profile"
replace_profile_field \
    "$household_profile" "$older_storage_revision" \
    BOOT_STORAGE_CATALOG_REVISION 2026-07-18.9
load_profile_success "$older_storage_revision"
[[ "$BOOT_STORAGE_CATALOG_REVISION" == 2026-07-18.9 ]] ||
    fail "storage catalog 诊断 revision 未原样保留"

# 发布独立 SATA 字段前唯一的旧组合是 860 PRO/RVM02B6Q，且 ATA 序号曾复用
# NVME_SERIAL。只有全部新字段与 pool ID 同时缺失、旧元组精确匹配时才迁移。
legacy_household="$TMP_DIR/household-legacy-860.profile"
remove_profile_fields \
    "$household_profile" "$legacy_household" \
    PLATFORM_BOOT_STORAGE_POOL_ID "${boot_storage_fields[@]}"
# 当时唯一发布过的 NVMe 身份是 Samsung 970 PRO；先固定完整原子 bundle，
# 再伪装旧 revision，避免多品牌随机选择污染 legacy 迁移夹具。
force_legacy_samsung_nvme_bundle "$legacy_household"
sed -i \
    -e 's/^PLATFORM_CATALOG_REVISION=.*/PLATFORM_CATALOG_REVISION=2026-07-19.3/' \
    -e 's/^PLATFORM_BOOT_MODEL=.*/PLATFORM_BOOT_MODEL=Samsung\\ SSD\\ 860\\ PRO\\ 512GB/' \
    -e 's/^PLATFORM_BOOT_FIRMWARE=.*/PLATFORM_BOOT_FIRMWARE=RVM02B6Q/' \
    "$legacy_household"
ALLOW_STORAGE_PROFILE_MIGRATION=1
load_profile_success "$legacy_household"
ALLOW_STORAGE_PROFILE_MIGRATION=0
[[ "$PLATFORM_BOOT_STORAGE_POOL_ID" == samsung-sata-pro-512gb &&
   "$BOOT_STORAGE_COMPONENT_ID" == samsung-860-pro-512gb-sata &&
   "$BOOT_STORAGE_MODEL" == "Samsung SSD 860 PRO 512GB" &&
   "$BOOT_STORAGE_FIRMWARE" == RVM02B6Q &&
   "$BOOT_STORAGE_SERIAL" == S123N123456789 &&
   "${NVME_SERIAL:0:14}" == "$BOOT_STORAGE_SERIAL" &&
   ${#NVME_SERIAL} -eq 15 && "$NVME_PCI_DEV" == 0xA808 ]] ||
    fail "旧 household 860 PRO 没有精确迁移"

# 非 E5 v3/v4 正常池的 compatibility 仍是生命周期门禁。
compatibility_profile="$TMP_DIR/household-compatibility.profile"
ALLOW_PLATFORM_COMPATIBILITY=1
generate_profile compat-ivy-i3-3220-p8b75 "$compatibility_profile"
ALLOW_PLATFORM_COMPATIBILITY=0
STRICT_HARDWARE=0
expect_profile_failure "$compatibility_profile" \
    "compatibility household profile 未携带 allow 仍被重载"
ALLOW_PLATFORM_COMPATIBILITY=0
STRICT_HARDWARE=1

# household/host 从首次发布起即要求完整字段，不能借用静态 profile 的旧版回填。
incomplete_household="$TMP_DIR/household-incomplete.profile"
remove_profile_fields \
    "$household_profile" "$incomplete_household" PLATFORM_BOOT_FIRMWARE
expect_profile_failure "$incomplete_household" \
    "household profile 删除启动盘固件后仍被重载"
replace_profile_field \
    "$household_profile" "$incomplete_household" PLATFORM_BOOT_MODEL component
expect_profile_failure "$incomplete_household" \
    "household SATA 启动盘型号篡改未被 registry 绑定拒绝"
remove_profile_fields \
    "$household_profile" "$incomplete_household" BOOT_STORAGE_COMPONENT_ID
expect_profile_failure "$incomplete_household" \
    "household SATA 启动盘删除持久化 ID 后仍被重载"
for storage_field_and_value in \
    "BOOT_STORAGE_COMPONENT_ID=unknown-sata" \
    "BOOT_STORAGE_MODEL=Samsung\\ SSD\\ 970\\ PRO\\ 512GB" \
    "BOOT_STORAGE_FIRMWARE=BAD00000" \
    "BOOT_STORAGE_SIZE_BYTES=1000204886016" \
    "BOOT_STORAGE_INTERFACE=nvme"; do
    storage_field="${storage_field_and_value%%=*}"
    storage_value="${storage_field_and_value#*=}"
    replace_profile_field \
        "$household_profile" "$incomplete_household" \
        "$storage_field" "$storage_value"
    expect_profile_failure "$incomplete_household" \
        "household SATA 启动盘字段 $storage_field 篡改后仍被重载"
done
for storage_field in \
    BOOT_STORAGE_COMPONENT_ID BOOT_STORAGE_MODEL BOOT_STORAGE_FIRMWARE \
    BOOT_STORAGE_SIZE_BYTES BOOT_STORAGE_INTERFACE; do
    replace_profile_field \
        "$household_profile" "$incomplete_household" "$storage_field" "''"
    expect_profile_failure "$incomplete_household" \
        "household SATA 启动盘字段 $storage_field 显式清空后仍被重载"
done
replace_profile_field \
    "$household_profile" "$incomplete_household" CPU_NAME 'Intel\ Xeon'
expect_profile_failure "$incomplete_household" \
    "household profile 借 server Guest CPU 名称绕过目录绑定"

# 构造一个真实保存的 host-passthrough profile。随机序号和可更换部件沿用前面的
# 物理 profile，所有平台客观事实则由当前注入宿主重新导出。
export STEALTH_HOST_PROBE_TEST_MODE=1
export STEALTH_HOST_CPU_VENDOR=GenuineIntel
export STEALTH_HOST_CPU_MODEL_NAME='Intel(R) Core(TM) i3-6100 CPU @ 3.70GHz'
export STEALTH_HOST_CPU_FAMILY=6
export STEALTH_HOST_CPU_MODEL=94
export STEALTH_HOST_CPU_STEPPING=3
export STEALTH_HOST_CPU_CORES=2
export STEALTH_HOST_CPU_ONLINE_THREADS=4
export STEALTH_HOST_CPU_MAX_MHZ=3700
export STEALTH_HOST_CPU_PHYS_BITS=39
export STEALTH_KVM_TSC_KHZ=3700000

host_profile="$TMP_DIR/host.profile"
ALLOW_PLATFORM_COMPATIBILITY=0
STRICT_HARDWARE=1
generate_profile intel-lga1151-i5-6400t-asus-h110m-a-m2 "$host_profile"
ALLOW_PLATFORM_COMPATIBILITY=1
stealth_platform_registry_load compat-host-intel-q35 "$CPUS"
SYSTEM_MFR="$BOARD_MFR"
SYSTEM_VERSION="$BOARD_VERSION"
CHASSIS_TYPE=Desktop
# host-passthrough 是 QEMU generic 主板，不得沿用前一个物理 ASUS profile
# 的标签格式；三个可见序列用不同合法值，避免构造重复身份。
BOARD_SERIAL=MB123456789012
SYSTEM_SERIAL=MB123456789013
CHASSIS_SERIAL=MB123456789014
stealth_save_profile "$host_profile"
assert_profile_fields_present "$host_profile" "${metadata_fields[@]}"
load_profile_success "$host_profile"
[[ "$PLATFORM_CPU_SOURCE" == host-passthrough &&
   "$CPU_QEMU_ARG" == host &&
   "$CPU_HOST_MODEL" == 94 &&
   -n "$CPU_HOST_FINGERPRINT" &&
   "$PLATFORM_BOOT_MODEL" == component &&
   "$PLATFORM_BOOT_FIRMWARE" == component ]] ||
    fail "host profile 没有完整保存宿主 CPU/启动盘绑定"

incomplete_host="$TMP_DIR/host-incomplete.profile"
remove_profile_fields "$host_profile" "$incomplete_host" CPU_HOST_MODEL
expect_profile_failure "$incomplete_host" \
    "host profile 删除宿主 model 绑定后仍被重载"
replace_profile_field \
    "$host_profile" "$incomplete_host" CPU_NAME 'Intel\ Xeon'
expect_profile_failure "$incomplete_host" \
    "host profile 借 server Guest CPU 名称绕过重建绑定"

# 重载必须针对“当前”宿主重建指纹，而不是信任 profile 自报字段。
STEALTH_HOST_CPU_MODEL=95
expect_profile_failure "$host_profile" \
    "host profile 在不同宿主 model 上仍被重载"
STEALTH_HOST_CPU_MODEL=94
STEALTH_HOST_CPU_MODEL_NAME='Intel(R) Xeon(R) CPU E5-2690 v4 @ 2.60GHz'
expect_profile_failure "$host_profile" \
    "server 宿主借既有消费级 host profile 绕过 server CPU 禁令"
STEALTH_HOST_CPU_MODEL_NAME='Intel(R) Core(TM) i3-6100 CPU @ 3.70GHz'

ALLOW_PLATFORM_COMPATIBILITY=0
STRICT_HARDWARE=0
expect_profile_failure "$host_profile" \
    "host compatibility profile 未携带 allow 仍被重载"

echo "PASS: platform profile registry binding tests"
