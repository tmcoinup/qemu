#!/usr/bin/env bash
# 独立验证旧启动盘 profile 的显式授权、真实旧序号迁移和按目录 cutoff。
# 测试只写临时 profile，不改实例目录，也不启动 QEMU。
# shellcheck disable=SC1091,SC2034
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

source "$REPO_ROOT/deploy/scripts/stealth-lib.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_equal() {
    local actual="$1" expected="$2" description="$3"
    [[ "$actual" == "$expected" ]] ||
        fail "$description: actual=$actual expected=$expected"
}

export CPUS=4
export STRICT_HARDWARE=1
export ALLOW_PLATFORM_COMPATIBILITY=1
export ALLOW_STORAGE_PROFILE_MIGRATION=0
export STEALTH_SEED=1

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
    unset MEM_TOTAL_MB
    stealth_pick_profile >/dev/null
    stealth_save_profile "$destination"
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
    LAST_FAILURE_LOG="$log"
}

remove_boot_storage_fields() {
    local source="$1" destination="$2"
    grep -Ev \
        '^(PLATFORM_BOOT_STORAGE_POOL_ID|BOOT_STORAGE_(CATALOG_REVISION|COMPONENT_ID|MANUFACTURER|MODEL|PART_NUMBER|FIRMWARE|SIZE_BYTES|INTERFACE|SERIAL))=' \
        "$source" >"$destination"
    chmod 0600 "$destination"
}

rewrite_legacy_samsung_nvme_v1() {
    sed \
        -e 's/^NVME_COMPONENT_ID=.*/NVME_COMPONENT_ID=samsung-970-pro-512gb/' \
        -e 's/^NVME_MODEL=.*/NVME_MODEL=Samsung\\ SSD\\ 970\\ PRO\\ 512GB/' \
        -e 's/^NVME_FIRMWARE=.*/NVME_FIRMWARE=1B2QEXP7/' \
        -e 's/^NVME_SERIAL=.*/NVME_SERIAL=S0123456789N/' \
        -e 's/^NVME_SIZE_BYTES=.*/NVME_SIZE_BYTES=512110190592/' \
        -e 's/^NVME_PCI_VEN=.*/NVME_PCI_VEN=0x144D/' \
        -e 's/^NVME_PCI_DEV=.*/NVME_PCI_DEV=0xA804/' \
        -e 's/^NVME_SUBSYS_VEN=.*/NVME_SUBSYS_VEN=0x144D/' \
        -e 's/^NVME_SUBSYS_DEV=.*/NVME_SUBSYS_DEV=0xA801/' \
        -e 's|^NVME_SUBNQN_TEMPLATE=.*|NVME_SUBNQN_TEMPLATE=nqn.1994-11.com.samsung:nvme:970-PRO:M.2:\\{serial\\}|' \
        -e 's|^NVME_SUBNQN=.*|NVME_SUBNQN=nqn.1994-11.com.samsung:nvme:970-PRO:M.2:S0123456789N|'
}

make_legacy_sata_v1() {
    local source="$1" destination="$2" stripped="$TMP_DIR/legacy-stripped"
    remove_boot_storage_fields "$source" "$stripped"
    sed \
        -e 's/^PLATFORM_CATALOG_REVISION=.*/PLATFORM_CATALOG_REVISION=2026-07-19.3/' \
        -e 's/^PLATFORM_BOOT_MODEL=.*/PLATFORM_BOOT_MODEL=Samsung\\ SSD\\ 860\\ PRO\\ 512GB/' \
        -e 's/^PLATFORM_BOOT_FIRMWARE=.*/PLATFORM_BOOT_FIRMWARE=RVM02B6Q/' \
        "$stripped" | rewrite_legacy_samsung_nvme_v1 >"$destination"
    chmod 0600 "$destination"
}

test_cutoffs_are_per_catalog_kind() {
    _stealth_platform_registry_revision_predates_boot_storage \
        manifest 2026-07-19.5 ||
        fail "manifest .5 应早于首次完整启动盘字段 revision"
    if _stealth_platform_registry_revision_predates_boot_storage \
            manifest 2026-07-19.6; then
        fail "当前 manifest .6 被误判为旧启动盘 profile"
    fi
    _stealth_platform_registry_revision_predates_boot_storage \
        household 2026-07-19.3 ||
        fail "household .3 应早于首次完整启动盘字段 revision"
    if _stealth_platform_registry_revision_predates_boot_storage \
            household 2026-07-19.4; then
        fail "首次完整启动盘字段 household .4 被误判为旧 profile"
    fi
    if _stealth_platform_registry_revision_predates_boot_storage \
            host 2020-01-01.1; then
        fail "host profile 不应获得推断式启动盘迁移"
    fi
}

test_real_legacy_sata_serial_migration() {
    local current="$TMP_DIR/household-current.profile"
    local legacy="$TMP_DIR/household-legacy-v1.profile"
    local before_hash

    generate_profile compat-haswell-i3-4130-h81 "$current"
    make_legacy_sata_v1 "$current" "$legacy"
    before_hash="$(sha256sum "$legacy")"

    ALLOW_STORAGE_PROFILE_MIGRATION=0
    expect_profile_failure "$legacy" \
        "当前 profile 伪改旧 revision 后无需授权完成了迁移"
    grep -F -- '--migrate-storage-profile' "$LAST_FAILURE_LOG" >/dev/null ||
        fail "缺少明确的启动盘迁移授权诊断"

    ALLOW_STORAGE_PROFILE_MIGRATION=1
    load_profile_success "$legacy"
    assert_equal "$PLATFORM_BOOT_STORAGE_POOL_ID" \
        samsung-sata-pro-512gb "旧 SATA pool"
    assert_equal "$BOOT_STORAGE_COMPONENT_ID" \
        samsung-860-pro-512gb-sata "旧 SATA 稳定 ID"
    assert_equal "$BOOT_STORAGE_MODEL" \
        "Samsung SSD 860 PRO 512GB" "旧 SATA 型号"
    assert_equal "$BOOT_STORAGE_FIRMWARE" RVM02B6Q "旧 SATA 固件"
    assert_equal "$BOOT_STORAGE_SERIAL" S0123456789N \
        "旧 ATA Identify 序号没有原样保留"
    [[ "$NVME_SERIAL" =~ ^S[A-Z0-9]{3}N[A-Z0-9]{10}$ &&
       "$NVME_SERIAL" != S0123456789N &&
       "$NVME_SUBNQN" == "nqn.2014-08.org.nvmexpress:uuid:$UUID" ]] ||
        fail "迁移后 data-only NVMe 身份没有按当前规则严格规范化"
    stealth_storage_compat_binding_is_current ||
        fail "迁移后的 860 PRO 完整组合未通过当前目录绑定"
    [[ "$before_hash" == "$(sha256sum "$legacy")" ]] ||
        fail "只读加载改写了旧 profile"
    ALLOW_STORAGE_PROFILE_MIGRATION=0
}

test_real_legacy_nvme_serial_migration() {
    local current="$TMP_DIR/nvme-current.profile"
    local stripped="$TMP_DIR/nvme-stripped.profile"
    local legacy="$TMP_DIR/nvme-legacy-v1.profile"

    generate_profile intel-lga1151-i5-6400t-asus-h110m-a-m2 "$current"
    remove_boot_storage_fields "$current" "$stripped"
    sed \
        -e 's/^PLATFORM_CATALOG_REVISION=.*/PLATFORM_CATALOG_REVISION=2026-07-19.5/' \
        "$stripped" | rewrite_legacy_samsung_nvme_v1 >"$legacy"
    chmod 0600 "$legacy"

    ALLOW_STORAGE_PROFILE_MIGRATION=1
    load_profile_success "$legacy"
    [[ "$NVME_SERIAL" =~ ^S[A-Z0-9]{3}N[A-Z0-9]{10}$ &&
       "$NVME_SUBNQN" == "nqn.2014-08.org.nvmexpress:uuid:$UUID" ]] ||
        fail "旧 NVMe v1 身份没有规范化为当前严格格式"
    assert_equal "$BOOT_STORAGE_SERIAL" "$NVME_SERIAL" \
        "迁移后的 NVMe 启动盘序号没有与 component 镜像"
    assert_equal "$BOOT_STORAGE_COMPONENT_ID" "$NVME_COMPONENT_ID" \
        "迁移后的 NVMe 启动盘 ID 没有与 component 镜像"
    ALLOW_STORAGE_PROFILE_MIGRATION=0
}

test_legacy_exception_is_narrow() {
    local current="$TMP_DIR/narrow-current.profile"
    local legacy="$TMP_DIR/narrow-legacy.profile"
    local damaged="$TMP_DIR/narrow-damaged.profile"

    generate_profile compat-haswell-i3-4130-h81 "$current"
    make_legacy_sata_v1 "$current" "$legacy"

    sed 's|^NVME_SUBNQN=.*|NVME_SUBNQN=nqn.invalid|' \
        "$legacy" >"$damaged"
    chmod 0600 "$damaged"
    ALLOW_STORAGE_PROFILE_MIGRATION=1
    expect_profile_failure "$damaged" \
        "旧序号与错误 NQN 的组合获得迁移例外"

    sed \
        -e 's/^NVME_SERIAL=.*/NVME_SERIAL=S0123456789N/' \
        -e 's|^NVME_SUBNQN_TEMPLATE=.*|NVME_SUBNQN_TEMPLATE=nqn.1994-11.com.samsung:nvme:970-PRO:M.2:\\{serial\\}|' \
        -e 's|^NVME_SUBNQN=.*|NVME_SUBNQN=nqn.1994-11.com.samsung:nvme:970-PRO:M.2:S0123456789N|' \
        "$current" >"$damaged"
    chmod 0600 "$damaged"
    expect_profile_failure "$damaged" \
        "完整当前 profile 获得了旧 NVMe 身份例外"

    sed 's/^NVME_SERIAL=.*/NVME_SERIAL=S0000000000N/' \
        "$legacy" >"$damaged"
    chmod 0600 "$damaged"
    expect_profile_failure "$damaged" \
        "旧 NVMe 占位序号获得迁移例外"
    ALLOW_STORAGE_PROFILE_MIGRATION=0
}

test_current_revisions_cannot_migrate_missing_fields() {
    local static="$TMP_DIR/static-current.profile"
    local missing="$TMP_DIR/static-current-missing.profile"
    local household="$TMP_DIR/household-current-cutoff.profile"
    local forged="$TMP_DIR/household-current-cutoff-forged.profile"
    local current_revision

    generate_profile intel-lga1151-i5-6400t-asus-h110m-a-m2 "$static"
    current_revision="$(stealth_profile_get PLATFORM_CATALOG_REVISION "$static")" ||
        fail "新 manifest profile 缺少目录 revision"
    if _stealth_platform_registry_revision_predates_boot_storage \
            manifest "$current_revision"; then
        fail "新 manifest profile 使用了早于启动盘 cutoff 的 revision"
    fi
    remove_boot_storage_fields "$static" "$missing"
    ALLOW_STORAGE_PROFILE_MIGRATION=1
    expect_profile_failure "$missing" \
        "当前 manifest revision 删除全部启动盘字段后仍被迁移"

    generate_profile compat-haswell-i3-4130-h81 "$household"
    remove_boot_storage_fields "$household" "$missing"
    sed \
        -e 's/^PLATFORM_BOOT_MODEL=.*/PLATFORM_BOOT_MODEL=Samsung\\ SSD\\ 860\\ PRO\\ 512GB/' \
        -e 's/^PLATFORM_BOOT_FIRMWARE=.*/PLATFORM_BOOT_FIRMWARE=RVM02B6Q/' \
        "$missing" >"$forged"
    chmod 0600 "$forged"
    expect_profile_failure "$forged" \
        "当前 household .5 仅伪改旧存储元组后仍被迁移"

    cp "$household" "$missing"
    sed -i '/^BOOT_STORAGE_COMPONENT_ID=/d' "$missing"
    chmod 0600 "$missing"
    expect_profile_failure "$missing" \
        "显式迁移授权放过了当前 profile 的部分字段缺失"
    ALLOW_STORAGE_PROFILE_MIGRATION=0
}

test_cli_contract_is_exposed() {
    local help_output
    local seal="$REPO_ROOT/deploy/scripts/seal-base.sh"
    local clone="$REPO_ROOT/deploy/scripts/clone-from-base.sh"
    local clone_output="$REPO_ROOT/deploy/scripts/lib/clone-postprocess.sh"

    grep -F -- \
        '--migrate-storage-profile) ALLOW_STORAGE_PROFILE_MIGRATION=1' \
        "$REPO_ROOT/deploy/scripts/lib/sv-cli.sh" >/dev/null ||
        fail "Linux CLI 没有暴露显式启动盘迁移授权"
    help_output="$("$REPO_ROOT/deploy/scripts/start-vm.sh" --help 2>&1)" ||
        fail "start-vm --help 无法执行"
    grep -F -- '--migrate-storage-profile' <<<"$help_output" >/dev/null ||
        fail "start-vm --help 没有说明启动盘迁移授权"
    grep -F -- \
        '--migrate-storage-profile) ALLOW_STORAGE_MIGRATION=1' \
        "$seal" >/dev/null ||
        fail "seal CLI 没有暴露显式启动盘迁移授权"
    grep -F -- \
        '--migrate-storage-profile) ALLOW_STORAGE_MIGRATION=1' \
        "$clone" >/dev/null ||
        fail "clone CLI 没有暴露显式启动盘迁移授权"
    grep -F 'export ALLOW_STORAGE_PROFILE_MIGRATION="$ALLOW_STORAGE_MIGRATION"' \
        "$seal" >/dev/null ||
        fail "seal 未把迁移授权传播到严格 profile 加载器"
    grep -F 'ALLOW_STORAGE_PROFILE_MIGRATION="$ALLOW_STORAGE_MIGRATION"' \
        "$clone" >/dev/null ||
        fail "clone 未把迁移授权传播到严格 profile 加载器"
    grep -F 'start_forward_args+=("--migrate-storage-profile")' \
        "$clone_output" >/dev/null ||
        fail "clone 完成提示未把只读迁移授权传播到后续 start"
    grep -F 'NEXT_CLONE_FLAGS+=("--migrate-storage-profile")' \
        "$seal" >/dev/null ||
        fail "seal 完成提示未把只读迁移授权传播到后续 clone"
}

test_cutoffs_are_per_catalog_kind
test_real_legacy_sata_serial_migration
test_real_legacy_nvme_serial_migration
test_legacy_exception_is_narrow
test_current_revisions_cannot_migrate_missing_fields
test_cli_contract_is_exposed
echo "PASS: explicit legacy storage profile migration tests"
