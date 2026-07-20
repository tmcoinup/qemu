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
    EDID_PRODUCT_ID EDID_MANUFACTURE_WEEK EDID_MANUFACTURE_YEAR EDID_VIDEO_INPUT
    EDID_MIN_VFREQ_HZ EDID_MAX_VFREQ_HZ EDID_MIN_HFREQ_KHZ EDID_MAX_HFREQ_KHZ
    EDID_MAX_PIXEL_CLOCK_MHZ EDID_SECONDARY_XRES EDID_SECONDARY_YRES
    EDID_SECONDARY_REFRESH_RATE
    KBD_COMPONENT_ID KBD_VID KBD_PID KBD_MFR KBD_PRODUCT KBD_BCD_DEVICE
    KBD_DESCRIPTOR_FIDELITY
    MOUSE_COMPONENT_ID MOUSE_VID MOUSE_PID MOUSE_MFR MOUSE_PRODUCT
    MOUSE_BCD_DEVICE MOUSE_DESCRIPTOR_FIDELITY
    TABLET_COMPONENT_ID TABLET_VID TABLET_PID TABLET_MFR TABLET_PRODUCT
    TABLET_BCD_DEVICE TABLET_DESCRIPTOR_FIDELITY
)

stealth_verify_profile_component_binding() (
    local present_array_name="$1"
    local explicit_empty_array_name="${2:-}"
    local migration_kind="${3:-none}"
    local legacy_boot_serial="${4:-}"
    local -n present_keys="$present_array_name"
    local field profile_value expected_value row
    local -A profile_values=() expected=()
    if [[ -n "$explicit_empty_array_name" ]]; then
        # shellcheck disable=SC2178 # 参数明确指向调用方的关联数组。
        local -n explicit_empty_keys="$explicit_empty_array_name"
    fi

    for field in "${_STEALTH_COMPONENT_BOUND_PROFILE_VARS[@]}"; do
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
    expected[COMPONENT_CATALOG_REVISION]="$(stealth_component_validate)" || return 1
    expected[GPU_IDENTITY_FIDELITY]=label_only_out_of_scope

    row="$(stealth_component_rows storage)" || return 1
    IFS='|' read -r 'expected[NVME_COMPONENT_ID]' 'expected[NVME_MODEL]' \
        'expected[NVME_FIRMWARE]' 'expected[NVME_SIZE_BYTES]' \
        'expected[NVME_PCI_VEN]' 'expected[NVME_PCI_DEV]' \
        'expected[NVME_SUBSYS_VEN]' 'expected[NVME_SUBSYS_DEV]' \
        'expected[NVME_SUBNQN_TEMPLATE]' <<<"$row"
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
            expected[BOOT_STORAGE_MANUFACTURER]=Samsung
            expected[BOOT_STORAGE_MODEL]="${expected[NVME_MODEL]}"
            expected[BOOT_STORAGE_PART_NUMBER]=component-catalog
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

    # GPU_POOL 的 PCI VEN/DEV 是 guest SUBSYS 反查与 host profile 的共同
    # 主键。先取整行权威 bundle，再让下方逐字段比较名称、显存、
    # BIOS、位宽和时钟；不允许仅修改型号文字后继续通过严格加载。
    row="$(stealth_gpu_profile_row "${GPU_PCI_VEN:-}" "${GPU_PCI_DEV:-}")" || return 1
    IFS='|' read -r 'expected[GPU_VENDOR]' 'expected[GPU_NAME]' \
        'expected[GPU_PCI_VEN]' 'expected[GPU_PCI_DEV]' 'expected[GPU_RAM_MB]' \
        'expected[GPU_BIOS]' 'expected[GPU_REV]' 'expected[GPU_MEMORY_TYPE]' \
        'expected[GPU_MEMORY_BUS_WIDTH_BITS]' 'expected[GPU_BASE_CLOCK_KHZ]' \
        'expected[GPU_BOOST_CLOCK_KHZ]' 'expected[GPU_MEMORY_CLOCK_KHZ]' \
        'expected[GPU_SLI_SUPPORTED]' <<<"$row"

    row="$(stealth_component_rows monitor)" || return 1
    IFS='|' read -r 'expected[EDID_COMPONENT_ID]' 'expected[EDID_VENDOR]' \
        'expected[EDID_NAME]' 'expected[EDID_WIDTH_MM]' 'expected[EDID_HEIGHT_MM]' _ \
        'expected[EDID_PRODUCT_ID]' 'expected[EDID_MANUFACTURE_WEEK]' \
        'expected[EDID_MANUFACTURE_YEAR]' 'expected[EDID_VIDEO_INPUT]' \
        'expected[EDID_MIN_VFREQ_HZ]' 'expected[EDID_MAX_VFREQ_HZ]' \
        'expected[EDID_MIN_HFREQ_KHZ]' 'expected[EDID_MAX_HFREQ_KHZ]' \
        'expected[EDID_MAX_PIXEL_CLOCK_MHZ]' 'expected[EDID_SECONDARY_XRES]' \
        'expected[EDID_SECONDARY_YRES]' \
        'expected[EDID_SECONDARY_REFRESH_RATE]' <<<"$row"

    for kind in KBD:keyboards MOUSE:mice TABLET:tablets; do
        local prefix="${kind%%:*}" operation="${kind#*:}"
        row="$(stealth_component_rows "$operation")" || return 1
        IFS='|' read -r "expected[${prefix}_VID]" "expected[${prefix}_PID]" \
            "expected[${prefix}_MFR]" "expected[${prefix}_PRODUCT]" \
            "expected[${prefix}_COMPONENT_ID]" "expected[${prefix}_BCD_DEVICE]" \
            "expected[${prefix}_DESCRIPTOR_FIDELITY]" <<<"$row"
    done

    for field in "${_STEALTH_COMPONENT_BOUND_PROFILE_VARS[@]}"; do
        profile_value="${profile_values[$field]}"
        expected_value="${expected[$field]}"
        if [[ "$profile_value" != "$expected_value" ]]; then
            printf 'ERROR: profile 与部件目录事实不匹配: %s profile=%q catalog=%q\n' \
                "$field" "$profile_value" "$expected_value" >&2
            return 1
        fi
    done
)
