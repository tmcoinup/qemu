#!/usr/bin/env bash
# schema-1 启动盘独立 BOOT_* 字段的受限、显式授权内存迁移。
#
# 迁移只处理“全部 BOOT_* 与 pool ID 在原文件中都缺失”的旧 profile；部分缺失、
# 显式空值以及新 profile 删除任一字段都交给严格 verifier 拒绝。NVMe 可从已绑定
# NVME_* 唯一镜像；SATA 只承认旧版曾发布的 860 PRO/RVM02B6Q 完整元组。
# profile 是未签名文本，revision 本身不能证明它是旧档，因此匹配候选后仍要求
# ALLOW_STORAGE_PROFILE_MIGRATION=1，普通加载绝不自动改写当前身份。

if [[ "${_STEALTH_STORAGE_PROFILE_MIGRATE_LOADED:-0}" == "1" ]]; then
    # shellcheck disable=SC2317 # source guard 兼容直接执行诊断。
    return 0 2>/dev/null || exit 0
fi
_STEALTH_STORAGE_PROFILE_MIGRATE_LOADED=1

_STEALTH_BOOT_STORAGE_PROFILE_VARS=(
    BOOT_STORAGE_CATALOG_REVISION
    BOOT_STORAGE_COMPONENT_ID
    BOOT_STORAGE_MANUFACTURER
    BOOT_STORAGE_MODEL
    BOOT_STORAGE_PART_NUMBER
    BOOT_STORAGE_FIRMWARE
    BOOT_STORAGE_SIZE_BYTES
    BOOT_STORAGE_INTERFACE
    BOOT_STORAGE_SERIAL
)

_stealth_mark_migrated_boot_storage_present() {
    local present_array_name="$1" field
    local -n present_keys="$present_array_name"
    present_keys[PLATFORM_BOOT_STORAGE_POOL_ID]=1
    present_keys[PLATFORM_BOOT_MODEL]=1
    present_keys[PLATFORM_BOOT_FIRMWARE]=1
    for field in "${_STEALTH_BOOT_STORAGE_PROFILE_VARS[@]}"; do
        present_keys["$field"]=1
    done
}

_stealth_migrate_nvme_boot_storage() {
    PLATFORM_BOOT_STORAGE_POOL_ID=component-nvme
    BOOT_STORAGE_CATALOG_REVISION="$COMPONENT_CATALOG_REVISION"
    BOOT_STORAGE_COMPONENT_ID="$NVME_COMPONENT_ID"
    BOOT_STORAGE_MANUFACTURER=Samsung
    BOOT_STORAGE_MODEL="$NVME_MODEL"
    BOOT_STORAGE_PART_NUMBER=component-catalog
    BOOT_STORAGE_FIRMWARE="$NVME_FIRMWARE"
    BOOT_STORAGE_SIZE_BYTES="$NVME_SIZE_BYTES"
    BOOT_STORAGE_INTERFACE=nvme
    BOOT_STORAGE_SERIAL="$NVME_SERIAL"
    export BOOT_STORAGE_CATALOG_REVISION BOOT_STORAGE_COMPONENT_ID
    export BOOT_STORAGE_MANUFACTURER BOOT_STORAGE_MODEL BOOT_STORAGE_PART_NUMBER
    export BOOT_STORAGE_FIRMWARE BOOT_STORAGE_SIZE_BYTES BOOT_STORAGE_INTERFACE
    export BOOT_STORAGE_SERIAL
}

_stealth_migrate_legacy_sata_boot_storage() {
    local legacy_serial="$1"
    PLATFORM_BOOT_STORAGE_POOL_ID=samsung-sata-pro-512gb
    PLATFORM_BOOT_MODEL=storage-compatibility-pool
    PLATFORM_BOOT_FIRMWARE=storage-compatibility-pool
    stealth_storage_compat_load samsung-860-pro-512gb-sata || return 1
    # 旧运行时曾把 NVME_SERIAL 直接写入 ATA Identify；保留该 Guest 可见序号，
    # 避免升级后已安装系统的磁盘指纹无故改变。
    BOOT_STORAGE_SERIAL="$legacy_serial"
    export BOOT_STORAGE_SERIAL
}

_stealth_legacy_nvme_identity_version() {
    local serial="${NVME_SERIAL:-}"
    local template="${NVME_SUBNQN_TEMPLATE:-}"
    local nqn="${NVME_SUBNQN:-}"
    local expected

    if [[ "$serial" =~ ^S[0-9A-F]{10}N$ &&
          "$serial" != S0000000000N &&
          "$serial" != SFFFFFFFFFFN &&
          "$template" == "nqn.1994-11.com.samsung:nvme:970-PRO:M.2:{serial}" ]]; then
        expected="${template//\{serial\}/$serial}"
        [[ "$nqn" == "$expected" ]] || return 1
        printf '%s\n' v1
        return 0
    fi
    if [[ "$serial" =~ ^S[A-Z0-9]{3}N[A-Z0-9]{9}$ &&
          "$serial" != S000N000000000 &&
          "$serial" != SFFFNFFFFFFFFF &&
          "$template" == "nqn.2014-08.org.nvmexpress:uuid:{uuid}" ]]; then
        expected="${template//\{uuid\}/${UUID:-}}"
        [[ "$nqn" == "$expected" ]] || return 1
        printf '%s\n' v2
        return 0
    fi
    return 1
}

_stealth_storage_migration_authorized() {
    [[ "${ALLOW_STORAGE_PROFILE_MIGRATION:-0}" == 1 ]] || {
        echo "ERROR: 旧启动盘 profile 迁移必须显式追加 --migrate-storage-profile" >&2
        return 1
    }
}

stealth_classify_boot_storage_profile_migration() {
    local present_array_name="$1"
    local original_pool_id_missing="$2"
    local kind_output_name="$3"
    local serial_output_name="$4"
    # shellcheck disable=SC2178 # 参数明确指向调用方的关联数组。
    local -n present_keys="$present_array_name"
    local -n migration_kind="$kind_output_name"
    local -n legacy_serial="$serial_output_name"
    local field platform_kind="" identity_version=""

    migration_kind=none
    legacy_serial=

    [[ "${PLATFORM_SCHEMA_VERSION:-0}" == 1 &&
       "$original_pool_id_missing" == 1 ]] || return 0
    for field in "${_STEALTH_BOOT_STORAGE_PROFILE_VARS[@]}"; do
        [[ -z "${present_keys[$field]:-}" ]] || return 0
    done
    platform_kind="$(
        stealth_platform_registry_kind "${PLATFORM_ID:-}" 2>/dev/null || true
    )"

    if [[ "$platform_kind" =~ ^(manifest|household)$ &&
          "${PLATFORM_BOOT_STORAGE:-}" == nvme &&
          "${PLATFORM_BOOT_MODEL:-}" == component &&
          "${PLATFORM_BOOT_FIRMWARE:-}" == component &&
          "${PLATFORM_STORAGE_SWITCH_REQUIRED:-}" == 0 &&
          "${NVME_ROLE:-}" == boot &&
          "$NVME_MODEL|$NVME_FIRMWARE|$NVME_SIZE_BYTES" == \
              "Samsung SSD 970 PRO 512GB|1B2QEXP7|512110190592" ]] &&
       _stealth_platform_registry_revision_predates_boot_storage \
           "$platform_kind" "${PLATFORM_CATALOG_REVISION:-}"; then
        identity_version="$(_stealth_legacy_nvme_identity_version)" || {
            echo "ERROR: 旧 NVMe 启动盘 profile 的序号/NQN 组合不受支持" >&2
            return 1
        }
        _stealth_storage_migration_authorized || return 1
        migration_kind="legacy-nvme-$identity_version"
    elif [[ "$platform_kind" == household &&
            "${PLATFORM_BOOT_STORAGE:-}" == sata-ahci &&
            "${PLATFORM_BOOT_MODEL:-}" == "Samsung SSD 860 PRO 512GB" &&
            "${PLATFORM_BOOT_FIRMWARE:-}" == RVM02B6Q &&
            "${PLATFORM_STORAGE_SWITCH_REQUIRED:-}" == 1 &&
            "${NVME_ROLE:-}" == data-only &&
            "$NVME_SIZE_BYTES" == 512110190592 ]] &&
         _stealth_platform_registry_revision_predates_boot_storage \
             "$platform_kind" "${PLATFORM_CATALOG_REVISION:-}"; then
        identity_version="$(_stealth_legacy_nvme_identity_version)" || {
            echo "ERROR: 旧 SATA profile 复用的 NVMe 序号/NQN 组合不受支持" >&2
            return 1
        }
        _stealth_storage_migration_authorized || return 1
        migration_kind="legacy-sata-$identity_version"
        legacy_serial="$NVME_SERIAL"
    fi
}

stealth_apply_boot_storage_profile_migration() {
    local present_array_name="$1"
    local migration_kind="$2"
    local legacy_serial="${3:-}"

    case "$migration_kind" in
        none)
            return 0
            ;;
        legacy-nvme-v1|legacy-nvme-v2)
            _stealth_migrate_nvme_boot_storage
            ;;
        legacy-sata-v1|legacy-sata-v2)
            _stealth_migrate_legacy_sata_boot_storage "$legacy_serial" ||
                return 1
            ;;
        *)
            echo "ERROR: 未知启动盘 profile 迁移类型: $migration_kind" >&2
            return 1
            ;;
    esac
    _stealth_mark_migrated_boot_storage_present "$present_array_name"
    echo ">> profile:     已在内存迁移旧启动盘字段（$migration_kind）" >&2
}
