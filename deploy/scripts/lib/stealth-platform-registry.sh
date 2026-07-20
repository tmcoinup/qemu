#!/usr/bin/env bash
# 统一路由默认整机清单、家用 CPU compatibility 清单与受限 host 模板。
#
# 三类清单保持独立，避免把“默认支持”“显式家用兼容”“宿主原样透传”混成一个
# enabled 开关。调用方只通过本注册表查询状态或加载，profile 校验也使用同一路由。
# shellcheck disable=SC1091,SC2034

if [[ "${_STEALTH_PLATFORM_REGISTRY_LOADED:-0}" == "1" ]]; then
    # shellcheck disable=SC2317 # source guard 兼容直接执行诊断。
    return 0 2>/dev/null || exit 0
fi
_STEALTH_PLATFORM_REGISTRY_LOADED=1

_STEALTH_PLATFORM_REGISTRY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=stealth-host-platform.sh
source "$_STEALTH_PLATFORM_REGISTRY_DIR/stealth-host-platform.sh"
if [[ -r "$_STEALTH_PLATFORM_REGISTRY_DIR/stealth-household-compat.sh" ]]; then
    # shellcheck source=stealth-household-compat.sh
    source "$_STEALTH_PLATFORM_REGISTRY_DIR/stealth-household-compat.sh"
fi
# shellcheck source=stealth-storage-compat.sh
source "$_STEALTH_PLATFORM_REGISTRY_DIR/stealth-storage-compat.sh"

# 这些字段把 profile 的 CPU 来源和 Q35 语义固定下来。host 模板会自行导出；
# 默认/家用目录由本层补齐，使安全持久化可以使用一份统一白名单。
_STEALTH_PLATFORM_METADATA_VARS=(
    PLATFORM_CPU_SOURCE
    PLATFORM_MACHINE_MODEL
    PLATFORM_IDENTITY_SCOPE
    PLATFORM_DEVICE_IDENTITY_SCOPE
    PLATFORM_SMBIOS_POLICY
    PLATFORM_TEMPLATE_DIGEST
    PLATFORM_HOST_CLASSES
    PLATFORM_BOOT_STORAGE_POOL_ID
    PLATFORM_BOOT_STORAGE
    PLATFORM_BOOT_MODEL
    PLATFORM_BOOT_FIRMWARE
    PLATFORM_STORAGE_SWITCH_REQUIRED
    NVME_ROLE
)

_STEALTH_HOST_CPU_BINDING_VARS=(
    CPU_HOST_FAMILY
    CPU_HOST_MODEL
    CPU_HOST_STEPPING
    CPU_HOST_CORES
    CPU_HOST_ONLINE_THREADS
    CPU_HOST_PHYS_BITS
    CPU_HOST_TSC_KHZ
    CPU_HOST_FINGERPRINT
)

# 统一来源、host 指纹和启动盘 metadata 从各自目录版本起成为强制持久化字段。
# 更老的 schema-1 profile 只能在显式授权后做内存迁移；该版本及以后删除字段
# 必须拒绝。三个目录的 revision 序列彼此独立，不能拿 physical 的 cutoff
# 比较 household/host revision。
_STEALTH_PLATFORM_METADATA_CATALOG_REVISION=2026-07-19.4
_STEALTH_MANIFEST_BOOT_STORAGE_CATALOG_REVISION=2026-07-19.6
_STEALTH_HOUSEHOLD_BOOT_STORAGE_CATALOG_REVISION=2026-07-19.4

_stealth_platform_registry_revision_predates_metadata() {
    local revision="$1" revision_date revision_sequence
    local cutoff="$_STEALTH_PLATFORM_METADATA_CATALOG_REVISION"
    local cutoff_date="${cutoff%.*}" cutoff_sequence="${cutoff##*.}"
    [[ "$revision" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})\.([0-9]+)$ ]] ||
        return 1
    revision_date="${BASH_REMATCH[1]}"
    revision_sequence="${BASH_REMATCH[2]}"
    [[ "$revision_date" < "$cutoff_date" ]] && return 0
    [[ "$revision_date" == "$cutoff_date" ]] &&
        (( 10#$revision_sequence < 10#$cutoff_sequence ))
}

_stealth_platform_registry_revision_predates_cutoff() {
    local revision="$1" cutoff="$2" revision_date revision_sequence
    local cutoff_date="${cutoff%.*}" cutoff_sequence="${cutoff##*.}"
    [[ "$revision" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})\.([0-9]+)$ ]] ||
        return 1
    revision_date="${BASH_REMATCH[1]}"
    revision_sequence="${BASH_REMATCH[2]}"
    [[ "$revision_date" < "$cutoff_date" ]] && return 0
    [[ "$revision_date" == "$cutoff_date" ]] &&
        (( 10#$revision_sequence < 10#$cutoff_sequence ))
}

_stealth_platform_registry_revision_predates_boot_storage() {
    local kind="$1" revision="$2" cutoff
    case "$kind" in
        manifest)
            cutoff="$_STEALTH_MANIFEST_BOOT_STORAGE_CATALOG_REVISION"
            ;;
        household)
            cutoff="$_STEALTH_HOUSEHOLD_BOOT_STORAGE_CATALOG_REVISION"
            ;;
        host)
            # host compatibility 从首次发布就要求完整启动盘字段；不存在可自动
            # 推断的历史格式，缺失字段始终 fail closed。
            return 1
            ;;
        *)
            return 1
            ;;
    esac
    _stealth_platform_registry_revision_predates_cutoff "$revision" "$cutoff"
}

stealth_platform_registry_kind() {
    local platform_id="$1"
    if declare -F stealth_household_compat_is_id >/dev/null 2>&1 &&
       stealth_household_compat_is_id "$platform_id"; then
        printf '%s\n' household
    elif stealth_host_platform_is_id "$platform_id"; then
        printf '%s\n' host
    elif stealth_platform_manifest_status "$platform_id" >/dev/null 2>&1; then
        printf '%s\n' manifest
    else
        return 1
    fi
}

stealth_platform_registry_is_id() {
    stealth_platform_registry_kind "$1" >/dev/null
}

stealth_platform_registry_status() {
    local platform_id="$1" kind
    kind="$(stealth_platform_registry_kind "$platform_id")" || {
        echo "ERROR: 整机平台不存在: $platform_id" >&2
        return 1
    }
    case "$kind" in
        household) stealth_household_compat_status "$platform_id" ;;
        host)      stealth_host_platform_status "$platform_id" ;;
        manifest)  stealth_platform_manifest_status "$platform_id" ;;
    esac
}

_stealth_platform_registry_apply_metadata() {
    local kind="$1" field
    case "$kind" in
        manifest)
            PLATFORM_CPU_SOURCE=manifest
            PLATFORM_MACHINE_MODEL=q35
            PLATFORM_IDENTITY_SCOPE=physical-platform-catalog
            PLATFORM_DEVICE_IDENTITY_SCOPE=pci-configuration-identity
            PLATFORM_SMBIOS_POLICY=physical-platform-projection
            PLATFORM_TEMPLATE_DIGEST=
            PLATFORM_HOST_CLASSES=
            PLATFORM_BOOT_STORAGE_POOL_ID=component-nvme
            PLATFORM_BOOT_STORAGE=nvme
            PLATFORM_BOOT_MODEL=component
            PLATFORM_BOOT_FIRMWARE=component
            PLATFORM_STORAGE_SWITCH_REQUIRED=0
            NVME_ROLE=boot
            ;;
        household)
            # CPU source、宿主类和启动盘策略必须由 household loader 明确导出。
            # 这里使用直接赋值而非 :=，防止 profile 中继承的篡改值成为 expected。
            [[ "${PLATFORM_CPU_SOURCE:-}" == named-household-compatibility &&
               -n "${PLATFORM_HOST_CLASSES:-}" &&
               "${PLATFORM_BOOT_STORAGE:-}" =~ ^(nvme|sata-ahci)$ &&
               -n "${PLATFORM_BOOT_MODEL:-}" &&
               -n "${PLATFORM_BOOT_FIRMWARE:-}" &&
               "${PLATFORM_STORAGE_SWITCH_REQUIRED:-}" =~ ^[01]$ &&
               "${NVME_ROLE:-}" =~ ^(boot|data-only)$ ]] || {
                echo "ERROR: household compatibility 缺少受控来源/存储 metadata" >&2
                return 1
            }
            case "$PLATFORM_BOOT_STORAGE" in
                nvme)
                    [[ "$PLATFORM_BOOT_MODEL" == component &&
                       "$PLATFORM_BOOT_FIRMWARE" == component &&
                       "$PLATFORM_STORAGE_SWITCH_REQUIRED" == 0 &&
                       "$NVME_ROLE" == boot ]] || {
                        echo "ERROR: household NVMe 启动策略与目录不一致" >&2
                        return 1
                    }
                    PLATFORM_BOOT_STORAGE_POOL_ID=component-nvme
                    ;;
                sata-ahci)
                    [[ "$PLATFORM_BOOT_MODEL" == storage-compatibility-pool &&
                       "$PLATFORM_BOOT_FIRMWARE" == storage-compatibility-pool &&
                       "$PLATFORM_STORAGE_SWITCH_REQUIRED" == 1 &&
                       "$NVME_ROLE" == data-only ]] || {
                        echo "ERROR: household SATA 启动策略与目录不一致" >&2
                        return 1
                    }
                    PLATFORM_BOOT_STORAGE_POOL_ID=samsung-sata-pro-512gb
                    ;;
            esac
            PLATFORM_MACHINE_MODEL=q35
            PLATFORM_IDENTITY_SCOPE=household-full-bundle-compatibility
            PLATFORM_DEVICE_IDENTITY_SCOPE=pci-configuration-identity
            PLATFORM_SMBIOS_POLICY=physical-platform-projection
            PLATFORM_TEMPLATE_DIGEST=
            PLATFORM_DEFAULT_VCPUS="$CPU_THREADS"
            PLATFORM_DEFAULT_MEMORY_MIB=8192
            ;;
        host)
            [[ "${PLATFORM_CPU_SOURCE:-}" == host-passthrough &&
               -n "${PLATFORM_TEMPLATE_DIGEST:-}" ]] || {
                echo "ERROR: host compatibility 缺少受控来源或模板摘要" >&2
                return 1
            }
            PLATFORM_HOST_CLASSES=
            PLATFORM_BOOT_STORAGE_POOL_ID=component-nvme
            PLATFORM_BOOT_STORAGE=nvme
            PLATFORM_BOOT_MODEL=component
            PLATFORM_BOOT_FIRMWARE=component
            PLATFORM_STORAGE_SWITCH_REQUIRED=0
            NVME_ROLE=boot
            ;;
        *)
            echo "ERROR: 未知平台来源: $kind" >&2
            return 1
            ;;
    esac
    if [[ "$kind" != host ]]; then
        for field in "${_STEALTH_HOST_CPU_BINDING_VARS[@]}"; do
            printf -v "$field" '%s' ""
        done
    fi
    for field in \
        "${_STEALTH_PLATFORM_METADATA_VARS[@]}" \
        "${_STEALTH_HOST_CPU_BINDING_VARS[@]}"; do
        export "${field?}"
    done
    export PLATFORM_DEFAULT_VCPUS PLATFORM_DEFAULT_MEMORY_MIB
}

_stealth_platform_registry_clear_derived() {
    # profile loader 会在同一个 shell 中保留刚解析的变量。重建 expected 前必须
    # 清空全部派生字段，否则 household/host helper 若漏导出一个字段，旧的
    # profile 值会被误当成目录真值。
    local field
    for field in \
        "${_STEALTH_PLATFORM_METADATA_VARS[@]}" \
        "${_STEALTH_HOST_CPU_BINDING_VARS[@]}"; do
        unset "$field"
    done
}

stealth_platform_registry_load() {
    local platform_id="$1"
    local guest_cpus="${2:-${CPUS:-4}}"
    local kind
    kind="$(stealth_platform_registry_kind "$platform_id")" || {
        echo "ERROR: 整机平台不存在: $platform_id" >&2
        return 1
    }
    _stealth_platform_registry_clear_derived
    case "$kind" in
        household) stealth_household_compat_load "$platform_id" ;;
        host)      stealth_host_platform_load "$platform_id" "$guest_cpus" ;;
        manifest)  stealth_platform_load "$platform_id" ;;
    esac || return 1
    _stealth_platform_registry_apply_metadata "$kind"
}

stealth_platform_registry_backfill_manifest_profile() {
    # 2026-07-19 以前的 schema-1 物理目录 profile 没有统一来源、host 指纹和
    # 启动总线字段。仅对 registry kind=manifest 的缺失字段做确定性内存迁移；
    # 已显式存在的值绝不覆盖，稍后的逐字段绑定会拒绝任何篡改。household/host
    # 从发布第一天就要求完整字段，删除其中任何一项都必须 fail-closed。
    local present_array_name="$1" kind field
    local -n present_keys="$present_array_name"
    [[ "${PLATFORM_SCHEMA_VERSION:-0}" == 1 ]] || return 0
    kind="$(stealth_platform_registry_kind "${PLATFORM_ID:-}")" || return 0
    [[ "$kind" == manifest ]] || return 0
    local -A metadata_defaults=(
        [PLATFORM_CPU_SOURCE]=manifest
        [PLATFORM_MACHINE_MODEL]=q35
        [PLATFORM_IDENTITY_SCOPE]=physical-platform-catalog
        [PLATFORM_DEVICE_IDENTITY_SCOPE]=pci-configuration-identity
        [PLATFORM_SMBIOS_POLICY]=physical-platform-projection
        [PLATFORM_TEMPLATE_DIGEST]=""
        [PLATFORM_HOST_CLASSES]=""
        [PLATFORM_BOOT_STORAGE_POOL_ID]=component-nvme
        [PLATFORM_BOOT_STORAGE]=nvme
        [PLATFORM_BOOT_MODEL]=component
        [PLATFORM_BOOT_FIRMWARE]=component
        [PLATFORM_STORAGE_SWITCH_REQUIRED]=0
        [NVME_ROLE]=boot
    )
    for field in "${_STEALTH_HOST_CPU_BINDING_VARS[@]}"; do
        metadata_defaults["$field"]=
    done
    if _stealth_platform_registry_revision_predates_metadata \
            "${PLATFORM_CATALOG_REVISION:-}"; then
        for field in "${!metadata_defaults[@]}"; do
            if [[ -z "${present_keys[$field]:-}" ]]; then
                printf -v "$field" '%s' "${metadata_defaults[$field]}"
                present_keys["$field"]=1
            fi
        done
    fi

    # storage pool 字段属于可更换启动盘部件，不在平台 registry 中迁移。旧版
    # household 860 PRO 的精确迁移由 profile loader 在核对旧型号/固件后执行。
}

# 统一承载只读 profile 的确定性目录迁移：manifest 可回填历史缺失字段，
# household 只允许三个既有 Haswell ID 做 compatibility→supported 单向提升。
stealth_platform_registry_migrate_profile() {
    local present_array_name="$1" kind
    [[ "${PLATFORM_SCHEMA_VERSION:-0}" == 1 ]] || return 0
    kind="$(stealth_platform_registry_kind "${PLATFORM_ID:-}")" || return 0
    if [[ "$kind" == household ]] &&
       declare -F stealth_household_compat_promote_profile_status \
           >/dev/null 2>&1; then
        stealth_household_compat_promote_profile_status "$present_array_name"
        return
    fi
    stealth_platform_registry_backfill_manifest_profile "$present_array_name"
}
