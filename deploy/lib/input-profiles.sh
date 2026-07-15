#!/usr/bin/env bash
# Audited USB HID identity catalogs shared by both deploy launch paths.
# Sourcing this file only defines arrays/functions; it has no host side effects.

# VID|PID|manufacturer|product|legacy-serial-prefix
KBD_POOL=(
    "0x045E|0x0750|Microsoft|Microsoft Wired Keyboard 600|68"
    "0x046D|0xC31C|Logitech|Logitech USB Keyboard K120|K1"
    "0x09DA|0x1F12|A4TECH|A4TECH USB Keyboard KK-3|A4"
    "0x24AE|0x200A|Rapoo|Rapoo USB Keyboard N1820|RP"
    "0x413C|0x2003|Dell|Dell USB Keyboard|DL"
)

MOUSE_POOL=(
    "0x045E|0x00CB|Microsoft|Microsoft USB Optical Mouse|42"
    "0x046D|0xC077|Logitech|Logitech USB Optical Mouse M105|LM"
    "0x09DA|0x31AC|A4TECH|A4TECH USB Optical Mouse OP-720|A4"
    "0x24AE|0x1102|Rapoo|Rapoo USB Mouse N1162|RP"
    "0x413C|0x301A|Dell|Dell USB Optical Mouse|DL"
)

# The native SDL/GTK path intentionally uses an absolute USB tablet so the
# pointer can leave the VM window without switching to relative-mouse grab.
TABLET_POOL=(
    "0x256C|0x006D|HUION|HUION PenTablet|HU"
    "0x256C|0x006E|HUION|HUION H640P|HU"
    "0x2FEB|0x0001|VEIKK|VEIKK A30|VK"
    "0x28BD|0x0094|XP-PEN|XP-Pen Star G640|XP"
)

input_profile_validate_rows() {
    local kind=$1
    shift
    local row vid pid manufacturer product prefix seen='|'

    for row in "$@"; do
        IFS='|' read -r vid pid manufacturer product prefix <<<"$row"
        [[ "$vid" =~ ^0x[0-9A-F]{4}$ && "$pid" =~ ^0x[0-9A-F]{4}$ ]] || {
            echo "$kind USB VID/PID 非法: $row" >&2
            return 1
        }
        [[ -n "$manufacturer" && -n "$product" && -n "$prefix" ]] || {
            echo "$kind USB profile 字段不完整: $row" >&2
            return 1
        }
        [[ "$manufacturer$product" != *','* ]] || {
            echo "$kind USB 字符串含未转义逗号: $row" >&2
            return 1
        }
        [[ "$seen" != *"|$vid:$pid|"* ]] || {
            echo "$kind USB VID/PID 重复: $vid:$pid" >&2
            return 1
        }
        seen+="$vid:$pid|"
    done
}

input_profile_validate_catalog() {
    input_profile_validate_rows keyboard "${KBD_POOL[@]}" &&
        input_profile_validate_rows mouse "${MOUSE_POOL[@]}" &&
        input_profile_validate_rows tablet "${TABLET_POOL[@]}"
}

input_profile_pick_keyboard_random() {
    local row=${KBD_POOL[$((RANDOM % ${#KBD_POOL[@]}))]} _prefix
    IFS='|' read -r KBD_VID KBD_PID KBD_MFR KBD_PRODUCT _prefix <<<"$row"
}

input_profile_pick_mouse_random() {
    local row=${MOUSE_POOL[$((RANDOM % ${#MOUSE_POOL[@]}))]} _prefix
    IFS='|' read -r MOUSE_VID MOUSE_PID MOUSE_MFR MOUSE_PRODUCT _prefix <<<"$row"
}

input_profile_pick_tablet_random() {
    local row=${TABLET_POOL[$((RANDOM % ${#TABLET_POOL[@]}))]} _prefix
    IFS='|' read -r TABLET_VID TABLET_PID TABLET_MFR TABLET_PRODUCT _prefix <<<"$row"
}

input_profile_load_keyboard_default() {
    local _prefix
    IFS='|' read -r KBD_VID KBD_PID KBD_MFR KBD_PRODUCT _prefix \
        <<<"${KBD_POOL[0]}"
}

input_profile_load_tablet_default() {
    local _prefix
    IFS='|' read -r TABLET_VID TABLET_PID TABLET_MFR TABLET_PRODUCT _prefix \
        <<<"${TABLET_POOL[0]}"
}

input_profile_row_allowed() {
    local requested=$1
    shift
    local row

    for row in "$@"; do
        [[ "${row%|*}" == "$requested" ]] && return 0
    done
    return 1
}

input_keyboard_profile_allowed() {
    input_profile_row_allowed "$1|$2|$3|$4" "${KBD_POOL[@]}"
}

input_tablet_profile_allowed() {
    input_profile_row_allowed "$1|$2|$3|$4" "${TABLET_POOL[@]}"
}
