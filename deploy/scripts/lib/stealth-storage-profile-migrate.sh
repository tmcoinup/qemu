#!/usr/bin/env bash
# schema-1 启动盘独立 BOOT_* 字段的受限迁移与目录元数据规范化。
#
# 迁移只处理“全部 BOOT_* 与 pool ID 在原文件中都缺失”的旧 profile；部分缺失、
# 显式空值以及新 profile 删除任一字段都交给严格 verifier 拒绝。NVMe 可从已绑定
# NVME_* 唯一镜像；SATA 只承认旧版曾发布的 860 PRO/RVM02B6Q 完整元组。
# profile 是未签名文本，revision 本身不能证明它是旧档，因此匹配候选后仍要求
# ALLOW_STORAGE_PROFILE_MIGRATION=1。唯一自动路径只修复已知 revision 的内部料号
# 占位值，并要求其它 component/Guest 身份字段逐项一致；保存由启动器在全门禁后执行。

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
    local row _id _model _firmware _size _pci_ven _pci_dev _sub_ven _sub_dev
    local _nqn manufacturer part_number

    row="$(stealth_component_storage_row "$NVME_COMPONENT_ID")" || return 1
    IFS='|' read -r _id _model _firmware _size _pci_ven _pci_dev \
        _sub_ven _sub_dev _nqn manufacturer part_number _ <<<"$row"
    PLATFORM_BOOT_STORAGE_POOL_ID=component-nvme
    BOOT_STORAGE_CATALOG_REVISION="$COMPONENT_CATALOG_REVISION"
    BOOT_STORAGE_COMPONENT_ID="$NVME_COMPONENT_ID"
    BOOT_STORAGE_MANUFACTURER="$manufacturer"
    BOOT_STORAGE_MODEL="$NVME_MODEL"
    BOOT_STORAGE_PART_NUMBER="$part_number"
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
    local row catalog_id catalog_model catalog_firmware catalog_size
    local catalog_pci_ven catalog_pci_dev catalog_sub_ven catalog_sub_dev
    local catalog_nqn catalog_manufacturer catalog_part_number
    local boot_field_count=0

    migration_kind=none
    legacy_serial=

    # 2026-07-19.6 生成器已经保存完整 BOOT_*，但当时唯一的 Samsung 970 PRO
    # 仍把 PART_NUMBER 写成内部占位 `component-catalog`。它不曾作为 Guest
    # 磁盘身份曝光；只在所有其它 NVMe/BOOT 字段与这个历史 component 精确一致时，
    # 自动替换为目录中的真实料号。不能仅伪造旧 revision，就让后来加入的 WD/
    # SK hynix component 冒充从未发布过的旧 profile。
    # 这是元数据规范化，不需要允许改变磁盘身份的显式迁移开关。
    for field in "${_STEALTH_BOOT_STORAGE_PROFILE_VARS[@]}"; do
        [[ -n "${present_keys[$field]:-}" ]] &&
            ((boot_field_count += 1))
    done
    # 2026-07-22.2 以前的 970 PRO 目录误用了 SM961/PM961 系列的 A804，并把
    # 公开实机的 15 字符序列形态少算一位。只在完整旧元组、标准 UUID NQN、
    # BOOT/NVME 同序列且两个 revision 一致时识别；局部伪造不能触发自动改写。
    if [[ "${PLATFORM_SCHEMA_VERSION:-0}" == 1 &&
          "$original_pool_id_missing" == 0 &&
          "$boot_field_count" == "${#_STEALTH_BOOT_STORAGE_PROFILE_VARS[@]}" &&
          "${COMPONENT_CATALOG_REVISION:-}" =~ ^2026-07-(19|2[0-2])\.[0-9]+$ &&
          "${BOOT_STORAGE_CATALOG_REVISION:-}" == \
              "${COMPONENT_CATALOG_REVISION:-}" &&
          "${PLATFORM_BOOT_STORAGE_POOL_ID:-}" == component-nvme &&
          "${PLATFORM_BOOT_STORAGE:-}" == nvme &&
          "${NVME_COMPONENT_ID:-}" == samsung-970-pro-512gb &&
          "${BOOT_STORAGE_COMPONENT_ID:-}" == samsung-970-pro-512gb &&
          "${NVME_MODEL:-}|${NVME_FIRMWARE:-}|${NVME_SIZE_BYTES:-}" == \
              "Samsung SSD 970 PRO 512GB|1B2QEXP7|512110190592" &&
          "${NVME_PCI_VEN:-}|${NVME_PCI_DEV:-}|${NVME_SUBSYS_VEN:-}|${NVME_SUBSYS_DEV:-}" == \
              "0x144D|0xA804|0x144D|0xA801" &&
          "${NVME_SERIAL:-}" =~ ^S[A-Z0-9]{3}N[A-Z0-9]{9}$ &&
          "${NVME_SERIAL:-}" != S000N000000000 &&
          "${NVME_SERIAL:-}" != SFFFNFFFFFFFFF &&
          "${NVME_SUBNQN_TEMPLATE:-}" == \
              "nqn.2014-08.org.nvmexpress:uuid:{uuid}" &&
          "${NVME_SUBNQN:-}" == \
              "nqn.2014-08.org.nvmexpress:uuid:${UUID:-}" &&
          "${BOOT_STORAGE_MANUFACTURER:-}|${BOOT_STORAGE_MODEL:-}|${BOOT_STORAGE_FIRMWARE:-}|${BOOT_STORAGE_SIZE_BYTES:-}|${BOOT_STORAGE_INTERFACE:-}|${BOOT_STORAGE_SERIAL:-}" == \
              "Samsung|Samsung SSD 970 PRO 512GB|1B2QEXP7|512110190592|nvme|${NVME_SERIAL:-}" ]]; then
        migration_kind=samsung-970-pro-catalog-v2
        legacy_serial="$NVME_SERIAL"
        return 0
    fi
    if [[ "${PLATFORM_SCHEMA_VERSION:-0}" == 1 &&
          "$original_pool_id_missing" == 0 &&
          "$boot_field_count" == "${#_STEALTH_BOOT_STORAGE_PROFILE_VARS[@]}" &&
          "${PLATFORM_CATALOG_REVISION:-}" == 2026-07-19.6 &&
          "${COMPONENT_CATALOG_REVISION:-}" == 2026-07-19.3 &&
          "${BOOT_STORAGE_CATALOG_REVISION:-}" == 2026-07-19.3 &&
          "${PLATFORM_BOOT_STORAGE_POOL_ID:-}" == component-nvme &&
          "${PLATFORM_BOOT_STORAGE:-}" == nvme &&
          "${NVME_COMPONENT_ID:-}" == samsung-970-pro-512gb &&
          "${BOOT_STORAGE_COMPONENT_ID:-}" == samsung-970-pro-512gb &&
          "${BOOT_STORAGE_PART_NUMBER:-}" == component-catalog ]]; then
        row="$(stealth_component_storage_row \
            "${NVME_COMPONENT_ID:-}")" || return 1
        IFS='|' read -r catalog_id catalog_model catalog_firmware \
            catalog_size catalog_pci_ven catalog_pci_dev catalog_sub_ven \
            catalog_sub_dev catalog_nqn catalog_manufacturer \
            catalog_part_number _ <<<"$row"
        if [[ "$BOOT_STORAGE_COMPONENT_ID|$BOOT_STORAGE_MANUFACTURER|$BOOT_STORAGE_MODEL|$BOOT_STORAGE_FIRMWARE|$BOOT_STORAGE_SIZE_BYTES|$BOOT_STORAGE_INTERFACE|$BOOT_STORAGE_SERIAL" == \
              "$catalog_id|$catalog_manufacturer|$catalog_model|$catalog_firmware|$catalog_size|nvme|${NVME_SERIAL:-}" &&
              "$NVME_COMPONENT_ID|$NVME_MODEL|$NVME_FIRMWARE|$NVME_SIZE_BYTES|$NVME_PCI_VEN|$NVME_PCI_DEV|$NVME_SUBSYS_VEN|$NVME_SUBSYS_DEV|$NVME_SUBNQN_TEMPLATE" == \
              "$catalog_id|$catalog_model|$catalog_firmware|$catalog_size|$catalog_pci_ven|$catalog_pci_dev|$catalog_sub_ven|$catalog_sub_dev|$catalog_nqn" &&
              "$catalog_part_number" != component-catalog ]]; then
            migration_kind=legacy-nvme-part-number-v1
            return 0
        fi
    fi

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
        legacy-nvme-part-number-v1|samsung-970-pro-catalog-v2)
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
