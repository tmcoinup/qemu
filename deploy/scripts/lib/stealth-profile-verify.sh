#!/usr/bin/env bash
# 严格 profile 与整机 manifest 的事实绑定校验。
#
# 每机序列号、UUID、MAC、内存/NVMe 物料等允许随机的字段不在此列表；
# 下列字段全部是 PLATFORM_ID 指向的客观事实，任一个被手改或删除都必须
# fail-closed。校验函数在子 shell 内重新加载 manifest，不会覆盖调用方已读取的 profile。
# shellcheck disable=SC1091

if [[ "${_STEALTH_PROFILE_VERIFY_LOADED:-0}" == "1" ]]; then
    # shellcheck disable=SC2317 # source guard 兼容直接执行诊断。
    return 0 2>/dev/null || exit 0
fi
_STEALTH_PROFILE_VERIFY_LOADED=1

_STEALTH_PROFILE_VERIFY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F stealth_platform_manifest_status >/dev/null 2>&1; then
    source "$_STEALTH_PROFILE_VERIFY_DIR/stealth-platforms.sh"
fi
if ! declare -F stealth_platform_registry_load >/dev/null 2>&1; then
    # shellcheck source=stealth-platform-registry.sh
    source "$_STEALTH_PROFILE_VERIFY_DIR/stealth-platform-registry.sh"
fi

_STEALTH_PLATFORM_BOUND_PROFILE_VARS=(
    PLATFORM_SCHEMA_VERSION PLATFORM_ID PLATFORM_STATUS PLATFORM_RELEASE_YEAR
    "${_STEALTH_PLATFORM_METADATA_VARS[@]}"
    TPM_CAPABILITY TPM_SUPPORTED TPM_IMPLEMENTATION TPM_VERSION TPM_FRONTEND TPM_PCR_BANKS
    CPU_QEMU_ARG CPU_VENDOR CPU_NAME CPU_MAX_MHZ CPU_CUR_MHZ CPU_TSC_MHZ CPU_PART CPU_PROC_FAMILY CPU_SOCKET CPU_MODEL
    CPU_CORES CPU_THREADS CPU_PHYS_BITS CPU_FEATURES CPU_SMBIOS_UPGRADE CPU_SMBIOS_VOLTAGE CPU_SMBIOS_EXT_CLOCK CPU_SMBIOS_CHARACTERISTICS
    CPU_IGPU_PRESENT CPU_IGPU_STATE CPU_IGPU_MODEL
    "${_STEALTH_HOST_CPU_BINDING_VARS[@]}"
    BOARD_MFR BOARD_PRODUCT BOARD_FAMILY BOARD_VERSION BOARD_SUBSYS_VEN BOARD_SUBSYS_DEV BOARD_DIMM_SLOTS BOARD_MAX_MEMORY_GIB PCH_MODEL PCIE_GENERATION
    SYSTEM_MFR SYSTEM_PRODUCT SYSTEM_FAMILY SYSTEM_CHASSIS_TYPE SYSTEM_VERSION BIOS_VENDOR BIOS_VERSION BIOS_DATE CHASSIS_TYPE
    NIC_VENDOR NIC_MODEL NIC_PCI_VEN NIC_PCI_DEV NIC_SUBSYSTEM_VEN NIC_SUBSYSTEM_DEV NIC_MAC_OUI NIC_ATTACHMENT BOARD_NIC_STATE
    ROOT_PORT_PCI_VEN ROOT_PORT_PCI_DEV ROOT_PORT_REV XHCI_PCI_VEN XHCI_PCI_DEV XHCI_REV
    MCH_PCI_VEN MCH_PCI_DEV MCH_REV LPC_PCI_VEN LPC_PCI_DEV LPC_REV SMBUS_PCI_VEN SMBUS_PCI_DEV SMBUS_REV AHCI_PCI_VEN AHCI_PCI_DEV AHCI_REV
    AUDIO_VENDOR AUDIO_CODEC AUDIO_CODEC_ID AUDIO_CODEC_REVISION AUDIO_CODEC_SUBSYSTEM_ID AUDIO_IDENTITY_FIDELITY AUDIO_CONTROLLER_PCI_VEN AUDIO_CONTROLLER_PCI_DEV
    NVME_MAX_PCIE_GENERATION NVME_LANES NVME_BOOT_SUPPORTED NVME_ATTACHMENT
    MEM_TYPE MEM_CHANNELS MEM_MAX_MTS MEM_ALLOWED_MTS MEM_VOLTAGE_MV MEM_RANK MEM_MODULE_MB MEM_ALLOWED_TOTAL_MB MEM_MAX_CAPACITY_MB
)

stealth_verify_profile_platform_binding() (
    local present_array_name="$1"
    local explicit_empty_array_name="${2:-}"
    local -n present_keys="$present_array_name"
    local field platform_id profile_value expected_value
    local -A profile_values=()
    if [[ -n "$explicit_empty_array_name" ]]; then
        # shellcheck disable=SC2178 # 参数明确指向调用方的关联数组。
        local -n explicit_empty_keys="$explicit_empty_array_name"
    fi

    platform_id="${PLATFORM_ID:-}"
    [[ -n "$platform_id" ]] || {
        echo "ERROR: 严格 profile 缺少 PLATFORM_ID" >&2
        return 1
    }
    if [[ -n "$explicit_empty_array_name" &&
          -n "${explicit_empty_keys[PLATFORM_CATALOG_REVISION]:-}" ]]; then
        echo "ERROR: 严格 profile 显式清空了 PLATFORM_CATALOG_REVISION" >&2
        return 1
    fi
    [[ -n "${PLATFORM_CATALOG_REVISION:-}" && -n "${present_keys[PLATFORM_CATALOG_REVISION]:-}" ]] || {
        echo "ERROR: 严格 profile 缺少 PLATFORM_CATALOG_REVISION" >&2
        return 1
    }

    for field in "${_STEALTH_PLATFORM_BOUND_PROFILE_VARS[@]}"; do
        if [[ -z "${present_keys[$field]:-}" ]] || ! [[ -v $field ]]; then
            echo "ERROR: 严格 profile 缺少平台绑定字段: $field" >&2
            return 1
        fi
        # schema-1 中显式 KEY='' 是输入，不等同于旧 profile 缺字段。即使前面的
        # legacy 迁移为了兼容读取给当前变量补了默认值，绑定仍使用原始空值；
        # 只有 registry 真值本身允许为空时才能通过。
        if [[ -n "$explicit_empty_array_name" &&
              -n "${explicit_empty_keys[$field]:-}" ]]; then
            profile_values["$field"]=
        else
            profile_values["$field"]="${!field}"
        fi
    done

    # 使用运行时请求的 CPUS 重建期望拓扑。host profile 若把 CPU_THREADS 和
    # 指纹一起改写，仍不能绕过本次启动的拓扑约束；household/manifest 则会
    # 从各自目录恢复固定 SKU 线程数。
    stealth_platform_registry_load "$platform_id" "${CPUS:-4}" || {
        echo "ERROR: profile 指向不可用的平台: $platform_id" >&2
        return 1
    }

    # 这三个文本字段由平台导出值确定，但为了避免在 JSON 重复存储，
    # 生成器中是从主板和 DMTF chassis code 派生的。
    # 变量随后通过字段名间接展开；导出可同时明确它们是校验上下文的一部分，
    # 避免静态分析把这种动态读取误判为未使用赋值。
    export SYSTEM_MFR="$BOARD_MFR"
    export SYSTEM_VERSION="$BOARD_VERSION"
    case "$SYSTEM_CHASSIS_TYPE" in
        0x03) export CHASSIS_TYPE="Desktop" ;;
        *) echo "ERROR: manifest 含不支持的 chassis type: $SYSTEM_CHASSIS_TYPE" >&2; return 1 ;;
    esac

    for field in "${_STEALTH_PLATFORM_BOUND_PROFILE_VARS[@]}"; do
        expected_value="${!field}"
        profile_value="${profile_values[$field]}"
        if [[ "$profile_value" != "$expected_value" ]]; then
            printf 'ERROR: profile 与平台 %s 事实不匹配: %s profile=%q manifest=%q\n' \
                "$platform_id" "$field" "$profile_value" "$expected_value" >&2
            return 1
        fi
    done
)
