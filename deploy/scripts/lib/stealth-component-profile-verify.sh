#!/usr/bin/env bash
# 严格 profile 与可更换部件 catalog 的事实绑定校验。序列号允许每机不同；型号、
# 固件、PCI/EDID/HID descriptor 等由目录决定的事实必须逐字段一致。

if [[ "${_STEALTH_COMPONENT_PROFILE_VERIFY_LOADED:-0}" == "1" ]]; then
    # shellcheck disable=SC2317  # 文件既可被 source，也允许直接执行做语法诊断。
    return 0 2>/dev/null || exit 0
fi
_STEALTH_COMPONENT_PROFILE_VERIFY_LOADED=1

_STEALTH_COMPONENT_VERIFY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091  # 运行时按本文件绝对目录加载，不能写死调用方 cwd。
source "$_STEALTH_COMPONENT_VERIFY_DIR/stealth-components.sh"

_STEALTH_COMPONENT_BOUND_PROFILE_VARS=(
    COMPONENT_SCHEMA_VERSION COMPONENT_CATALOG_REVISION
    NVME_COMPONENT_ID NVME_MODEL NVME_FIRMWARE
    NVME_SIZE_BYTES NVME_PCI_VEN NVME_PCI_DEV NVME_SUBSYS_VEN NVME_SUBSYS_DEV
    NVME_SUBNQN_TEMPLATE NVME_SUBNQN
    BOOT_STORAGE_CATALOG_REVISION BOOT_STORAGE_COMPONENT_ID
    BOOT_STORAGE_MANUFACTURER BOOT_STORAGE_MODEL BOOT_STORAGE_PART_NUMBER
    BOOT_STORAGE_FIRMWARE BOOT_STORAGE_SIZE_BYTES BOOT_STORAGE_INTERFACE
    BOOT_STORAGE_SERIAL
    GPU_VENDOR GPU_NAME GPU_PCI_VEN GPU_PCI_DEV GPU_RAM_MB GPU_BIOS GPU_REV
    GPU_MEMORY_TYPE GPU_MEMORY_BUS_WIDTH_BITS GPU_BASE_CLOCK_KHZ
    GPU_BOOST_CLOCK_KHZ GPU_MEMORY_CLOCK_KHZ GPU_SLI_SUPPORTED
    GPU_IDENTITY_FIDELITY
    EDID_COMPONENT_ID EDID_VENDOR EDID_NAME EDID_WIDTH_MM EDID_HEIGHT_MM
    EDID_BINARY_SERIAL EDID_REVISION
    EDID_PRODUCT_ID EDID_MANUFACTURE_WEEK EDID_MANUFACTURE_YEAR EDID_VIDEO_INPUT
    EDID_MIN_VFREQ_HZ EDID_MAX_VFREQ_HZ EDID_MIN_HFREQ_KHZ EDID_MAX_HFREQ_KHZ
    EDID_MAX_PIXEL_CLOCK_MHZ EDID_SECONDARY_XRES EDID_SECONDARY_YRES
    EDID_SECONDARY_REFRESH_RATE
    EDID_SECONDARY_PIXEL_CLOCK_KHZ EDID_SECONDARY_HFRONT
    EDID_SECONDARY_HSYNC EDID_SECONDARY_HBLANK EDID_SECONDARY_VFRONT
    EDID_SECONDARY_VSYNC EDID_SECONDARY_VBLANK
    EDID_SECONDARY_HSYNC_POSITIVE EDID_SECONDARY_VSYNC_POSITIVE
    EDID_SECONDARY_WIDTH_MM EDID_SECONDARY_HEIGHT_MM
    KBD_COMPONENT_ID KBD_VID KBD_PID KBD_MFR KBD_PRODUCT KBD_BCD_DEVICE
    KBD_DESCRIPTOR_FIDELITY
    MOUSE_COMPONENT_ID MOUSE_VID MOUSE_PID MOUSE_MFR MOUSE_PRODUCT
    MOUSE_BCD_DEVICE MOUSE_DESCRIPTOR_FIDELITY
    TABLET_COMPONENT_ID TABLET_VID TABLET_PID TABLET_MFR TABLET_PRODUCT
    TABLET_BCD_DEVICE TABLET_DESCRIPTOR_FIDELITY
)

_STEALTH_GPU_EXTENDED_PROFILE_VARS=(
    GPU_COMPONENT_ID GPU_BOARD_PARTNER GPU_PART_NUMBER
    GPU_SUBSYS_VEN GPU_SUBSYS_DEV GPU_CARRIER_VEN GPU_CARRIER_DEV
)

stealth_verify_profile_component_binding() (
    local present_array_name="$1"
    local explicit_empty_array_name="${2:-}"
    local migration_kind="${3:-none}"
    local legacy_boot_serial="${4:-}"
    local -n present_keys="$present_array_name"
    local field profile_value expected_value row
    local storage_manufacturer storage_part storage_identity_profile
    local storage_serial_kind storage_serial_pattern storage_serial_length
    local storage_weight
    local gpu_extended=0
    local -a required_fields=("${_STEALTH_COMPONENT_BOUND_PROFILE_VARS[@]}")
    local -A profile_values=() expected=()
    if [[ -n "$explicit_empty_array_name" ]]; then
        # shellcheck disable=SC2178 # 参数明确指向调用方的关联数组。
        local -n explicit_empty_keys="$explicit_empty_array_name"
    fi

    for field in "${_STEALTH_GPU_EXTENDED_PROFILE_VARS[@]}"; do
        if [[ -n "${present_keys[$field]:-}" ]]; then
            gpu_extended=1
            break
        fi
    done
    if (( gpu_extended == 1 )); then
        required_fields+=("${_STEALTH_GPU_EXTENDED_PROFILE_VARS[@]}")
    fi

    for field in "${required_fields[@]}"; do
        if [[ -z "${present_keys[$field]:-}" ]] || ! [[ -v $field ]]; then
            echo "ERROR: 严格 profile 缺少部件绑定字段: $field" >&2
            return 1
        fi
        if [[ -n "$explicit_empty_array_name" &&
              -n "${explicit_empty_keys[$field]:-}" ]]; then
            profile_values["$field"]=
        else
            profile_values["$field"]="${!field}"
        fi
    done

    expected[COMPONENT_SCHEMA_VERSION]=1
    stealth_component_validate >/dev/null || return 1
    [[ "${profile_values[COMPONENT_CATALOG_REVISION]}" =~ \
        ^[0-9]{4}-[0-9]{2}-[0-9]{2}\.[0-9]+$ ]] || {
        echo "ERROR: COMPONENT_CATALOG_REVISION 格式非法" >&2
        return 1
    }
    # revision 是生成时目录快照，仅供诊断；扩充显示器候选不能使稳定 ID 指向的
    # 旧 profile 失效。下方仍会从当前目录按 ID 重建并逐字段比较。
    expected[COMPONENT_CATALOG_REVISION]="${profile_values[COMPONENT_CATALOG_REVISION]}"

    # SSD 与显示器一样按持久化 stable ID 回查。扩充目录不会改变旧 VM，
    # 但该 ID 对应的型号/固件/PCI 字段任一变化仍会被逐项拒绝。
    row="$(stealth_component_storage_row \
        "${profile_values[NVME_COMPONENT_ID]}")" || return 1
    IFS='|' read -r 'expected[NVME_COMPONENT_ID]' 'expected[NVME_MODEL]' \
        'expected[NVME_FIRMWARE]' 'expected[NVME_SIZE_BYTES]' \
        'expected[NVME_PCI_VEN]' 'expected[NVME_PCI_DEV]' \
        'expected[NVME_SUBSYS_VEN]' 'expected[NVME_SUBSYS_DEV]' \
        'expected[NVME_SUBNQN_TEMPLATE]' storage_manufacturer storage_part \
        storage_identity_profile storage_serial_kind storage_serial_pattern \
        storage_serial_length storage_weight <<<"$row"
    [[ "${expected[NVME_COMPONENT_ID]}" == "$storage_identity_profile" ]] ||
        return 1
    stealth_component_storage_serial_is_valid \
        "${expected[NVME_COMPONENT_ID]}" "${NVME_SERIAL:-}" >/dev/null ||
        return 1
    expected[NVME_SUBNQN]="${expected[NVME_SUBNQN_TEMPLATE]//\{uuid\}/${UUID:-}}"

    # 启动盘按平台绑定的 pool 独立重建。SATA 分支绝不读取 NVME_MODEL/FIRMWARE/
    # SIZE/SERIAL；NVMe 分支则要求 BOOT_* 与同一 component 完全相同，避免两个
    # 持久化名称描述同一个 Guest 设备时发生分叉。
    case "${PLATFORM_BOOT_STORAGE_POOL_ID:-}" in
        component-nvme)
            [[ "${PLATFORM_BOOT_STORAGE:-}" == nvme ]] || {
                echo "ERROR: component-nvme 池只能用于 NVMe 启动" >&2
                return 1
            }
            [[ "${profile_values[BOOT_STORAGE_CATALOG_REVISION]}" =~ \
                ^[0-9]{4}-[0-9]{2}-[0-9]{2}\.[0-9]+$ ]] || {
                echo "ERROR: BOOT_STORAGE_CATALOG_REVISION 格式非法" >&2
                return 1
            }
            expected[BOOT_STORAGE_CATALOG_REVISION]="${profile_values[BOOT_STORAGE_CATALOG_REVISION]}"
            expected[BOOT_STORAGE_COMPONENT_ID]="${expected[NVME_COMPONENT_ID]}"
            expected[BOOT_STORAGE_MANUFACTURER]="$storage_manufacturer"
            expected[BOOT_STORAGE_MODEL]="${expected[NVME_MODEL]}"
            expected[BOOT_STORAGE_PART_NUMBER]="$storage_part"
            expected[BOOT_STORAGE_FIRMWARE]="${expected[NVME_FIRMWARE]}"
            expected[BOOT_STORAGE_SIZE_BYTES]="${expected[NVME_SIZE_BYTES]}"
            expected[BOOT_STORAGE_INTERFACE]=nvme
            [[ "${profile_values[BOOT_STORAGE_SERIAL]}" == "${NVME_SERIAL:-}" ]] || {
                echo "ERROR: NVMe BOOT_STORAGE_SERIAL 与 NVME_SERIAL 不一致" >&2
                return 1
            }
            expected[BOOT_STORAGE_SERIAL]="${profile_values[BOOT_STORAGE_SERIAL]}"
            ;;
        samsung-sata-pro-512gb)
            [[ "${PLATFORM_BOOT_STORAGE:-}" == sata-ahci ]] || {
                echo "ERROR: samsung-sata-pro-512gb 池只能用于 SATA/AHCI 启动" >&2
                return 1
            }
            stealth_storage_compat_load \
                "${profile_values[BOOT_STORAGE_COMPONENT_ID]}" >/dev/null || return 1
            [[ "${profile_values[BOOT_STORAGE_CATALOG_REVISION]}" =~ \
                ^[0-9]{4}-[0-9]{2}-[0-9]{2}\.[0-9]+$ ]] || {
                echo "ERROR: BOOT_STORAGE_CATALOG_REVISION 格式非法" >&2
                return 1
            }
            # 目录 revision 只用于诊断/迁移；扩池或修订说明不能让既有 VM
            # 失效。条目事实仍按稳定 ID 重建并逐字段严格比较。
            expected[BOOT_STORAGE_CATALOG_REVISION]="${profile_values[BOOT_STORAGE_CATALOG_REVISION]}"
            expected[BOOT_STORAGE_COMPONENT_ID]="$BOOT_STORAGE_COMPONENT_ID"
            expected[BOOT_STORAGE_MANUFACTURER]="$BOOT_STORAGE_MANUFACTURER"
            expected[BOOT_STORAGE_MODEL]="$BOOT_STORAGE_MODEL"
            expected[BOOT_STORAGE_PART_NUMBER]="$BOOT_STORAGE_PART_NUMBER"
            expected[BOOT_STORAGE_FIRMWARE]="$BOOT_STORAGE_FIRMWARE"
            expected[BOOT_STORAGE_SIZE_BYTES]="$BOOT_STORAGE_SIZE_BYTES"
            expected[BOOT_STORAGE_INTERFACE]="$BOOT_STORAGE_INTERFACE"
            if [[ "$migration_kind" == legacy-sata-v1 ]]; then
                if ! [[ "${profile_values[BOOT_STORAGE_SERIAL]}" =~ \
                        ^S[0-9A-F]{10}N$ ]] ||
                   [[ "${profile_values[BOOT_STORAGE_SERIAL]}" != \
                        "$legacy_boot_serial" ||
                      "$legacy_boot_serial" == S0000000000N ||
                      "$legacy_boot_serial" == SFFFFFFFFFFN ]]; then
                    echo "ERROR: 迁移后的 SATA BOOT_STORAGE_SERIAL 未严格保留旧序号" >&2
                    return 1
                fi
            elif ! [[ "${profile_values[BOOT_STORAGE_SERIAL]}" =~ \
                        ^S([A-Z0-9]{14}|[A-Z0-9]{3}N[A-Z0-9]{9})$ ]] ||
                 [[ "${profile_values[BOOT_STORAGE_SERIAL]}" == S00000000000000 ||
                    "${profile_values[BOOT_STORAGE_SERIAL]}" == SFFFFFFFFFFFFFF ||
                    "${profile_values[BOOT_STORAGE_SERIAL]}" == S000N000000000 ||
                    "${profile_values[BOOT_STORAGE_SERIAL]}" == SFFFNFFFFFFFFF ]]; then
                echo "ERROR: SATA BOOT_STORAGE_SERIAL 格式非法或为占位值" >&2
                return 1
            fi
            expected[BOOT_STORAGE_SERIAL]="${profile_values[BOOT_STORAGE_SERIAL]}"
            ;;
        *)
            echo "ERROR: 未知启动盘池: ${PLATFORM_BOOT_STORAGE_POOL_ID:-empty}" >&2
            return 1
            ;;
    esac

    # 新 profile 按 AIB stable ID 重建真实板卡 subsystem 与内部 virtio carrier。
    # 旧 profile 没这些字段时仍只按唯一主 ID 回查 generic label，不强迫重建实例。
    if (( gpu_extended == 1 )); then
        if row="$(stealth_component_gpu_row \
                "${profile_values[GPU_COMPONENT_ID]}" 2>/dev/null)"; then
            IFS='|' read -r 'expected[GPU_COMPONENT_ID]' \
                'expected[GPU_VENDOR]' 'expected[GPU_NAME]' \
                'expected[GPU_PCI_VEN]' 'expected[GPU_PCI_DEV]' \
                'expected[GPU_RAM_MB]' 'expected[GPU_BIOS]' 'expected[GPU_REV]' \
                'expected[GPU_MEMORY_TYPE]' 'expected[GPU_MEMORY_BUS_WIDTH_BITS]' \
                'expected[GPU_BASE_CLOCK_KHZ]' 'expected[GPU_BOOST_CLOCK_KHZ]' \
                'expected[GPU_MEMORY_CLOCK_KHZ]' 'expected[GPU_SLI_SUPPORTED]' \
                'expected[GPU_BOARD_PARTNER]' 'expected[GPU_PART_NUMBER]' \
                'expected[GPU_SUBSYS_VEN]' 'expected[GPU_SUBSYS_DEV]' \
                'expected[GPU_CARRIER_VEN]' 'expected[GPU_CARRIER_DEV]' \
                'expected[GPU_IDENTITY_FIDELITY]' <<<"$row"
        else
            row="$(stealth_component_legacy_gpu_row \
                "${profile_values[GPU_COMPONENT_ID]}")" || return 1
            expected[GPU_COMPONENT_ID]="${profile_values[GPU_COMPONENT_ID]}"
            IFS='|' read -r 'expected[GPU_VENDOR]' 'expected[GPU_NAME]' \
                'expected[GPU_PCI_VEN]' 'expected[GPU_PCI_DEV]' \
                'expected[GPU_RAM_MB]' 'expected[GPU_BIOS]' 'expected[GPU_REV]' \
                'expected[GPU_MEMORY_TYPE]' 'expected[GPU_MEMORY_BUS_WIDTH_BITS]' \
                'expected[GPU_BASE_CLOCK_KHZ]' 'expected[GPU_BOOST_CLOCK_KHZ]' \
                'expected[GPU_MEMORY_CLOCK_KHZ]' 'expected[GPU_SLI_SUPPORTED]' <<<"$row"
            expected[GPU_BOARD_PARTNER]=reference-label
            expected[GPU_PART_NUMBER]=not-exposed
            expected[GPU_SUBSYS_VEN]="${expected[GPU_PCI_VEN]}"
            expected[GPU_SUBSYS_DEV]="${expected[GPU_PCI_DEV]}"
            expected[GPU_CARRIER_VEN]="${expected[GPU_PCI_VEN]}"
            expected[GPU_CARRIER_DEV]="${expected[GPU_PCI_DEV]}"
            expected[GPU_IDENTITY_FIDELITY]=label_only_out_of_scope
        fi
    else
        row="$(stealth_gpu_legacy_profile_row \
            "${GPU_PCI_VEN:-}" "${GPU_PCI_DEV:-}")" || return 1
        IFS='|' read -r 'expected[GPU_VENDOR]' 'expected[GPU_NAME]' \
            'expected[GPU_PCI_VEN]' 'expected[GPU_PCI_DEV]' \
            'expected[GPU_RAM_MB]' 'expected[GPU_BIOS]' 'expected[GPU_REV]' \
            'expected[GPU_MEMORY_TYPE]' 'expected[GPU_MEMORY_BUS_WIDTH_BITS]' \
            'expected[GPU_BASE_CLOCK_KHZ]' 'expected[GPU_BOOST_CLOCK_KHZ]' \
            'expected[GPU_MEMORY_CLOCK_KHZ]' 'expected[GPU_SLI_SUPPORTED]' <<<"$row"
        expected[GPU_IDENTITY_FIDELITY]=label_only_out_of_scope
    fi

    # 显示器目录允许扩展，但已持久化 profile 始终按稳定 component ID 重建
    # 原条目。扩池不会让旧 Samsung profile 漂移到新型号。
    row="$(stealth_component_monitor_row \
        "${profile_values[EDID_COMPONENT_ID]}")" || return 1
    IFS='|' read -r 'expected[EDID_COMPONENT_ID]' 'expected[EDID_VENDOR]' \
        'expected[EDID_NAME]' 'expected[EDID_WIDTH_MM]' 'expected[EDID_HEIGHT_MM]' _ \
        'expected[EDID_PRODUCT_ID]' 'expected[EDID_MANUFACTURE_WEEK]' \
        'expected[EDID_MANUFACTURE_YEAR]' 'expected[EDID_VIDEO_INPUT]' \
        'expected[EDID_MIN_VFREQ_HZ]' 'expected[EDID_MAX_VFREQ_HZ]' \
        'expected[EDID_MIN_HFREQ_KHZ]' 'expected[EDID_MAX_HFREQ_KHZ]' \
        'expected[EDID_MAX_PIXEL_CLOCK_MHZ]' 'expected[EDID_SECONDARY_XRES]' \
        'expected[EDID_SECONDARY_YRES]' \
        'expected[EDID_SECONDARY_REFRESH_RATE]' <<<"$row"
    expected[EDID_BINARY_SERIAL]="$(
        stealth_component_monitor_binary_serial \
            "${profile_values[EDID_COMPONENT_ID]}" "${EDID_SERIAL:-}"
    )" || return 1
    expected[EDID_REVISION]="$(
        stealth_component_monitor_revision \
            "${profile_values[EDID_COMPONENT_ID]}"
    )" || return 1
    row="$(stealth_component_monitor_secondary_detail \
        "${profile_values[EDID_COMPONENT_ID]}")" || return 1
    IFS='|' read -r 'expected[EDID_SECONDARY_PIXEL_CLOCK_KHZ]' \
        'expected[EDID_SECONDARY_HFRONT]' 'expected[EDID_SECONDARY_HSYNC]' \
        'expected[EDID_SECONDARY_HBLANK]' 'expected[EDID_SECONDARY_VFRONT]' \
        'expected[EDID_SECONDARY_VSYNC]' 'expected[EDID_SECONDARY_VBLANK]' \
        'expected[EDID_SECONDARY_HSYNC_POSITIVE]' \
        'expected[EDID_SECONDARY_VSYNC_POSITIVE]' \
        'expected[EDID_SECONDARY_WIDTH_MM]' \
        'expected[EDID_SECONDARY_HEIGHT_MM]' \
        <<<"$row"

    for kind in KBD:keyboards MOUSE:mice TABLET:tablets; do
        local prefix="${kind%%:*}" operation="${kind#*:}"
        row="$(stealth_component_rows "$operation")" || return 1
        IFS='|' read -r "expected[${prefix}_VID]" "expected[${prefix}_PID]" \
            "expected[${prefix}_MFR]" "expected[${prefix}_PRODUCT]" \
            "expected[${prefix}_COMPONENT_ID]" "expected[${prefix}_BCD_DEVICE]" \
            "expected[${prefix}_DESCRIPTOR_FIDELITY]" <<<"$row"
    done

    for field in "${required_fields[@]}"; do
        profile_value="${profile_values[$field]}"
        expected_value="${expected[$field]}"
        if [[ "$profile_value" != "$expected_value" ]]; then
            printf 'ERROR: profile 与部件目录事实不匹配: %s profile=%q catalog=%q\n' \
                "$field" "$profile_value" "$expected_value" >&2
            return 1
        fi
    done
)
