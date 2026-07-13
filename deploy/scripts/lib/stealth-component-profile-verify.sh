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
    COMPONENT_SCHEMA_VERSION NVME_COMPONENT_ID NVME_MODEL NVME_FIRMWARE
    NVME_SIZE_BYTES NVME_PCI_VEN NVME_PCI_DEV NVME_SUBSYS_VEN NVME_SUBSYS_DEV
    NVME_SUBNQN_TEMPLATE NVME_SUBNQN GPU_IDENTITY_FIDELITY
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
    local -n present_keys="$present_array_name"
    local field profile_value expected_value row serial
    local -A profile_values=() expected=()

    [[ -n "${present_keys[COMPONENT_CATALOG_REVISION]:-}" ]] || {
        echo "ERROR: 严格 profile 缺少 COMPONENT_CATALOG_REVISION" >&2
        return 1
    }
    for field in "${_STEALTH_COMPONENT_BOUND_PROFILE_VARS[@]}"; do
        if [[ -z "${present_keys[$field]:-}" ]] || ! [[ -v $field ]]; then
            echo "ERROR: 严格 profile 缺少部件绑定字段: $field" >&2
            return 1
        fi
        profile_values["$field"]="${!field}"
    done

    expected[COMPONENT_SCHEMA_VERSION]=1
    expected[GPU_IDENTITY_FIDELITY]=label_only_out_of_scope

    row="$(stealth_component_rows storage)" || return 1
    IFS='|' read -r 'expected[NVME_COMPONENT_ID]' 'expected[NVME_MODEL]' \
        'expected[NVME_FIRMWARE]' 'expected[NVME_SIZE_BYTES]' \
        'expected[NVME_PCI_VEN]' 'expected[NVME_PCI_DEV]' \
        'expected[NVME_SUBSYS_VEN]' 'expected[NVME_SUBSYS_DEV]' \
        'expected[NVME_SUBNQN_TEMPLATE]' <<<"$row"
    serial="${NVME_SERIAL:-}"
    expected[NVME_SUBNQN]="${expected[NVME_SUBNQN_TEMPLATE]//\{serial\}/$serial}"

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
