#!/usr/bin/env bash
# Audited USB HID identity catalogs shared by deploy/scripts/create-vm.sh and
# deploy/scripts/start-vm.sh.  Sourcing this file only defines arrays/functions; it has
# no host side effects.

readonly INPUT_COMPONENT_CONTRACT_CURRENT_VERSION=2
readonly INPUT_PROFILE_CATALOG_CURRENT_REVISION=2026-08-03.1
readonly INPUT_PROFILE_SCHEMA='stable-id|brand|model|vid|pid|bcd-device|usb-version|raw-manufacturer|raw-product|serial-policy|fidelity'

# Active rows use the schema above.  Marketing brand/model and the raw USB
# strings are deliberately separate: a device such as Dell MS116 reports
# PixArt, not Dell, as iManufacturer.  The current QEMU HID implementation
# supplies a generic boot/report descriptor, so physical-device identities are
# explicitly classified as identity_only_generic_report rather than presented
# as descriptor-perfect emulation.
INPUT_KEYBOARD_ACTIVE_PROFILES=(
    'microsoft-wired-keyboard-600|Microsoft|Wired Keyboard 600|0x045E|0x0750|0x0110|2|Microsoft|Wired Keyboard 600|none|identity_only_generic_report'
    'logitech-k120-r64|Logitech|K120 revision 64.00|0x046D|0xC31C|0x6400|2|Logitech|USB Keyboard|none|identity_only_generic_report'
    'dell-sk-8115|Dell|SK-8115|0x413C|0x2003|0x0301|1|Dell|Dell USB Keyboard|none|identity_only_generic_report'
)

INPUT_RELATIVE_MOUSE_ACTIVE_PROFILES=(
    'microsoft-basic-optical-mouse-v2|Microsoft|Basic Optical Mouse v2.0|0x045E|0x00CB|0x0100|2|PixArt|Microsoft USB Optical Mouse|none|identity_only_generic_report'
    'logitech-m105-r72|Logitech|M105 revision 72.00|0x046D|0xC077|0x7200|2|Logitech|USB Optical Mouse|none|identity_only_generic_report'
    'dell-ms116|Dell|MS116|0x413C|0x301A|0x0100|2|PixArt|Dell MS116 USB Optical Mouse|none|identity_only_generic_report'
)

# usb-tablet implements one generic absolute-pointer interface.  It does not
# implement any vendor pen protocol, pressure, tilt, or composite interfaces,
# so it must retain QEMU's public identity and must not accept brand overrides.
INPUT_ABSOLUTE_POINTER_ACTIVE_PROFILES=(
    'qemu-generic-usb-tablet|virtual|QEMU USB Tablet|0x0627|0x0001|0x0000|2|QEMU|QEMU USB Tablet|none|generic_virtual_only'
)

# Historical G-11 pools are retained only as a read-only compatibility audit
# trail.  They are never candidates for active load, default selection, or
# random selection.  The first three keyboard/mouse devices also have revised,
# source-audited active rows above; these rows preserve the old projected tuple
# exactly so an old vm.conf can be identified and deliberately migrated.
INPUT_KEYBOARD_COMPAT_PROFILES=(
    'legacy-microsoft-wired-keyboard-600|Microsoft|Wired Keyboard 600 legacy tuple|0x045E|0x0750|0x0163|2|Microsoft|Microsoft Wired Keyboard 600|none|compat_legacy_identity_only'
    'legacy-logitech-k120|Logitech|K120 legacy tuple|0x046D|0xC31C|0x0163|2|Logitech|Logitech USB Keyboard K120|none|compat_legacy_identity_only'
    'legacy-a4tech-kk-3|A4Tech|KK-3 historical unverified tuple|0x09DA|0x1F12|0x0163|2|A4TECH|A4TECH USB Keyboard KK-3|none|quarantined_unverified_identity'
    'legacy-rapoo-n1820|Rapoo|N1820 historical unverified tuple|0x24AE|0x200A|0x0163|2|Rapoo|Rapoo USB Keyboard N1820|none|quarantined_unverified_identity'
    'legacy-dell-usb-keyboard|Dell|USB Keyboard legacy tuple|0x413C|0x2003|0x0163|2|Dell|Dell USB Keyboard|none|compat_legacy_identity_only'
)

INPUT_RELATIVE_MOUSE_COMPAT_PROFILES=(
    'legacy-microsoft-usb-optical-mouse|Microsoft|USB Optical Mouse legacy tuple|0x045E|0x00CB|0x0163|2|Microsoft|Microsoft USB Optical Mouse|none|compat_legacy_identity_only'
    'legacy-logitech-m105|Logitech|M105 legacy tuple|0x046D|0xC077|0x0163|2|Logitech|Logitech USB Optical Mouse M105|none|compat_legacy_identity_only'
    'legacy-a4tech-op-720|A4Tech|OP-720 historical unverified tuple|0x09DA|0x31AC|0x0163|2|A4TECH|A4TECH USB Optical Mouse OP-720|none|quarantined_unverified_identity'
    'legacy-rapoo-n1162|Rapoo|N1162 historical unverified tuple|0x24AE|0x1102|0x0163|2|Rapoo|Rapoo USB Mouse N1162|none|quarantined_unverified_identity'
    'legacy-dell-usb-optical-mouse|Dell|USB Optical Mouse legacy tuple|0x413C|0x301A|0x0163|2|Dell|Dell USB Optical Mouse|none|compat_legacy_identity_only'
)

INPUT_ABSOLUTE_POINTER_COMPAT_PROFILES=(
    'legacy-huion-pentablet|Huion|PenTablet historical branded tuple|0x256C|0x006D|0x0100|2|HUION|HUION PenTablet|none|quarantined_protocol_mismatch'
    'legacy-huion-h640p|Huion|H640P historical branded tuple|0x256C|0x006E|0x0100|2|HUION|HUION H640P|none|quarantined_protocol_and_serial_mismatch'
    'legacy-veikk-a30-wrong-tuple|VEIKK|A30 historical WRONG tuple|0x2FEB|0x0001|0x0100|2|VEIKK|VEIKK A30|none|quarantined_wrong_tuple_never_active'
    'legacy-xp-pen-star-g640|XP-Pen|Star G640 historical branded tuple|0x28BD|0x0094|0x0100|2|XP-PEN|XP-Pen Star G640|none|quarantined_protocol_mismatch'
)

# Compatibility aliases for callers that inspect the archival catalogs.
KBD_COMPAT_POOL=("${INPUT_KEYBOARD_COMPAT_PROFILES[@]}")
MOUSE_COMPAT_POOL=("${INPUT_RELATIVE_MOUSE_COMPAT_PROFILES[@]}")
TABLET_COMPAT_POOL=("${INPUT_ABSOLUTE_POINTER_COMPAT_PROFILES[@]}")
TABLET_QUARANTINE_POOL=("${INPUT_ABSOLUTE_POINTER_COMPAT_PROFILES[@]}")

_input_profile_legacy_row() {
    local row=$1 _id _brand _model vid pid _bcd _usb raw_mfr raw_product
    local _serial _fidelity
    IFS='|' read -r _id _brand _model vid pid _bcd _usb raw_mfr \
        raw_product _serial _fidelity <<<"$row"
    printf '%s|%s|%s|%s|none\n' "$vid" "$pid" "$raw_mfr" "$raw_product"
}

# Legacy five-column active projections keep old consumers working while the
# canonical catalogs above carry the full reviewed contract.  The fifth field
# used to be a made-up serial prefix; it is now the literal policy "none".
KBD_POOL=()
for _input_profile_bootstrap_row in "${INPUT_KEYBOARD_ACTIVE_PROFILES[@]}"; do
    KBD_POOL+=("$(_input_profile_legacy_row "$_input_profile_bootstrap_row")")
done
MOUSE_POOL=()
for _input_profile_bootstrap_row in "${INPUT_RELATIVE_MOUSE_ACTIVE_PROFILES[@]}"; do
    MOUSE_POOL+=("$(_input_profile_legacy_row "$_input_profile_bootstrap_row")")
done
TABLET_POOL=()
for _input_profile_bootstrap_row in "${INPUT_ABSOLUTE_POINTER_ACTIVE_PROFILES[@]}"; do
    TABLET_POOL+=("$(_input_profile_legacy_row "$_input_profile_bootstrap_row")")
done
unset _input_profile_bootstrap_row

_input_profile_normalize_kind() {
    case "${1:-}" in
        keyboard|kbd) printf 'keyboard\n' ;;
        relative-mouse|relative_mouse|mouse) printf 'relative-mouse\n' ;;
        absolute-pointer|absolute_pointer|pointer|tablet) \
            printf 'absolute-pointer\n' ;;
        *) return 1 ;;
    esac
}

_input_profile_active_rows() {
    local kind
    kind=$(_input_profile_normalize_kind "$1") || return 1
    case "$kind" in
        keyboard) printf '%s\n' "${INPUT_KEYBOARD_ACTIVE_PROFILES[@]}" ;;
        relative-mouse) \
            printf '%s\n' "${INPUT_RELATIVE_MOUSE_ACTIVE_PROFILES[@]}" ;;
        absolute-pointer) \
            printf '%s\n' "${INPUT_ABSOLUTE_POINTER_ACTIVE_PROFILES[@]}" ;;
    esac
}

_input_profile_compat_rows() {
    local kind
    kind=$(_input_profile_normalize_kind "$1") || return 1
    case "$kind" in
        keyboard) printf '%s\n' "${INPUT_KEYBOARD_COMPAT_PROFILES[@]}" ;;
        relative-mouse) \
            printf '%s\n' "${INPUT_RELATIVE_MOUSE_COMPAT_PROFILES[@]}" ;;
        absolute-pointer) \
            printf '%s\n' "${INPUT_ABSOLUTE_POINTER_COMPAT_PROFILES[@]}" ;;
    esac
}

_input_profile_find_row() {
    local scope=$1 kind=$2 requested=$3 row id
    case "$scope" in
        active)
            while IFS= read -r row; do
                id=${row%%|*}
                [[ "$id" == "$requested" ]] && {
                    printf '%s\n' "$row"
                    return 0
                }
            done < <(_input_profile_active_rows "$kind")
            ;;
        compat|quarantine)
            while IFS= read -r row; do
                id=${row%%|*}
                [[ "$id" == "$requested" ]] && {
                    printf '%s\n' "$row"
                    return 0
                }
            done < <(_input_profile_compat_rows "$kind")
            ;;
        *) return 2 ;;
    esac
    return 1
}

_input_profile_assign_prefix() {
    local row=$1 prefix=$2 scope=${3:-active}
    local id brand model vid pid bcd usb_version raw_mfr
    local raw_product serial_policy fidelity
    IFS='|' read -r id brand model vid pid bcd usb_version raw_mfr \
        raw_product serial_policy fidelity <<<"$row"

    printf -v "${prefix}_PROFILE_ID" '%s' "$id"
    printf -v "${prefix}_PROFILE" '%s' "$id"
    printf -v "${prefix}_PROFILE_SCOPE" '%s' "$scope"
    printf -v "${prefix}_BRAND" '%s' "$brand"
    printf -v "${prefix}_MODEL" '%s' "$model"
    printf -v "${prefix}_VID" '%s' "$vid"
    printf -v "${prefix}_PID" '%s' "$pid"
    printf -v "${prefix}_BCD_DEVICE" '%s' "$bcd"
    printf -v "${prefix}_USB_VERSION" '%s' "$usb_version"
    printf -v "${prefix}_MFR" '%s' "$raw_mfr"
    printf -v "${prefix}_RAW_MANUFACTURER" '%s' "$raw_mfr"
    printf -v "${prefix}_PRODUCT" '%s' "$raw_product"
    printf -v "${prefix}_RAW_PRODUCT" '%s' "$raw_product"
    printf -v "${prefix}_SERIAL_POLICY" '%s' "$serial_policy"
    printf -v "${prefix}_FIDELITY" '%s' "$fidelity"
}

input_keyboard_profile_load() {
    local requested=${1:-${INPUT_KEYBOARD_ACTIVE_PROFILES[0]%%|*}} row
    row=$(_input_profile_find_row active keyboard "$requested") || return 1
    _input_profile_assign_prefix "$row" KBD
}

input_mouse_profile_load() {
    local requested=${1:-${INPUT_RELATIVE_MOUSE_ACTIVE_PROFILES[0]%%|*}} row
    row=$(_input_profile_find_row active relative-mouse "$requested") || return 1
    _input_profile_assign_prefix "$row" MOUSE
}

input_relative_mouse_profile_load() {
    input_mouse_profile_load "$@"
}

input_pointer_profile_load() {
    local requested=${1:-${INPUT_ABSOLUTE_POINTER_ACTIVE_PROFILES[0]%%|*}} row
    row=$(_input_profile_find_row active absolute-pointer "$requested") || \
        return 1
    _input_profile_assign_prefix "$row" POINTER
    # TABLET_* is the legacy spelling consumed by current vm.conf files.
    _input_profile_assign_prefix "$row" TABLET
}

input_absolute_pointer_profile_load() {
    input_pointer_profile_load "$@"
}

input_tablet_profile_load() {
    input_pointer_profile_load "$@"
}

input_profile_load() {
    local kind
    kind=$(_input_profile_normalize_kind "${1:-}") || return 2
    case "$kind" in
        keyboard) input_keyboard_profile_load "${2:-}" ;;
        relative-mouse) input_mouse_profile_load "${2:-}" ;;
        absolute-pointer) input_pointer_profile_load "${2:-}" ;;
    esac
}

_input_profile_find_compat_tuple() {
    local kind=$1 requested_vid=$2 requested_pid=$3 requested_mfr=$4
    local requested_product=$5 row _id _brand _model vid pid _bcd _usb
    local raw_mfr raw_product _serial _fidelity match='' matches=0

    while IFS= read -r row; do
        IFS='|' read -r _id _brand _model vid pid _bcd _usb raw_mfr \
            raw_product _serial _fidelity <<<"$row"
        if [[ "$vid|$pid|$raw_mfr|$raw_product" == \
              "$requested_vid|$requested_pid|$requested_mfr|$requested_product" ]]; then
            match=$row
            matches=$((matches + 1))
        fi
    done < <(_input_profile_compat_rows "$kind")

    # A migration lookup must resolve one complete historical contract.  An
    # ambiguous or missing tuple is a hard failure, not a partial/default load.
    (( matches == 1 )) || return 1
    printf '%s\n' "$match"
}

input_keyboard_compat_tuple_load() {
    (( $# == 4 )) || return 2
    local row
    row=$(_input_profile_find_compat_tuple keyboard "$@") || return 1
    _input_profile_assign_prefix "$row" KBD compat
}

input_mouse_compat_tuple_load() {
    (( $# == 4 )) || return 2
    local row
    row=$(_input_profile_find_compat_tuple relative-mouse "$@") || return 1
    _input_profile_assign_prefix "$row" MOUSE compat
}

input_relative_mouse_compat_tuple_load() {
    input_mouse_compat_tuple_load "$@"
}

input_pointer_compat_tuple_load() {
    (( $# == 4 )) || return 2
    local row
    row=$(_input_profile_find_compat_tuple absolute-pointer "$@") || return 1
    _input_profile_assign_prefix "$row" POINTER compat
    _input_profile_assign_prefix "$row" TABLET compat
}

input_absolute_pointer_compat_tuple_load() {
    input_pointer_compat_tuple_load "$@"
}

input_tablet_compat_tuple_load() {
    input_pointer_compat_tuple_load "$@"
}

input_profile_compat_tuple_load() {
    (( $# == 5 )) || return 2
    local kind=$1
    shift
    kind=$(_input_profile_normalize_kind "$kind") || return 2
    case "$kind" in
        keyboard) input_keyboard_compat_tuple_load "$@" ;;
        relative-mouse) input_mouse_compat_tuple_load "$@" ;;
        absolute-pointer) input_pointer_compat_tuple_load "$@" ;;
    esac
}

_input_profile_keys() {
    local kind=$1 row
    while IFS= read -r row; do
        printf '%s\n' "${row%%|*}"
    done < <(_input_profile_active_rows "$kind")
}

input_keyboard_profile_keys() { _input_profile_keys keyboard; }
input_mouse_profile_keys() { _input_profile_keys relative-mouse; }
input_relative_mouse_profile_keys() { input_mouse_profile_keys; }
input_pointer_profile_keys() { _input_profile_keys absolute-pointer; }
input_absolute_pointer_profile_keys() { input_pointer_profile_keys; }
input_tablet_profile_keys() { input_pointer_profile_keys; }

input_profile_pick_keyboard_random() {
    local row=${INPUT_KEYBOARD_ACTIVE_PROFILES[
        RANDOM % ${#INPUT_KEYBOARD_ACTIVE_PROFILES[@]}
    ]}
    input_keyboard_profile_load "${row%%|*}"
}

input_profile_pick_mouse_random() {
    local row=${INPUT_RELATIVE_MOUSE_ACTIVE_PROFILES[
        RANDOM % ${#INPUT_RELATIVE_MOUSE_ACTIVE_PROFILES[@]}
    ]}
    input_mouse_profile_load "${row%%|*}"
}

input_profile_pick_relative_mouse_random() {
    input_profile_pick_mouse_random
}

input_profile_pick_pointer_random() {
    local row=${INPUT_ABSOLUTE_POINTER_ACTIVE_PROFILES[
        RANDOM % ${#INPUT_ABSOLUTE_POINTER_ACTIVE_PROFILES[@]}
    ]}
    input_pointer_profile_load "${row%%|*}"
}

input_profile_pick_absolute_pointer_random() {
    input_profile_pick_pointer_random
}

input_profile_pick_tablet_random() {
    input_profile_pick_pointer_random
}

input_profile_load_keyboard_default() { input_keyboard_profile_load; }
input_profile_load_mouse_default() { input_mouse_profile_load; }
input_profile_load_relative_mouse_default() { input_mouse_profile_load; }
input_profile_load_pointer_default() { input_pointer_profile_load; }
input_profile_load_absolute_pointer_default() { input_pointer_profile_load; }
input_profile_load_tablet_default() { input_pointer_profile_load; }

_input_profile_args_allowed() {
    local kind=$1
    shift
    local row id _brand _model vid pid _bcd _usb raw_mfr raw_product
    local _serial _fidelity requested

    case $# in
        1)
            _input_profile_find_row active "$kind" "$1" >/dev/null
            return
            ;;
        4)
            while IFS= read -r row; do
                IFS='|' read -r id _brand _model vid pid _bcd _usb raw_mfr \
                    raw_product _serial _fidelity <<<"$row"
                [[ "$vid|$pid|$raw_mfr|$raw_product" == \
                    "$1|$2|$3|$4" ]] && return 0
            done < <(_input_profile_active_rows "$kind")
            return 1
            ;;
        11)
            local IFS='|'
            requested="$*"
            while IFS= read -r row; do
                [[ "$row" == "$requested" ]] && return 0
            done < <(_input_profile_active_rows "$kind")
            return 1
            ;;
        *) return 2 ;;
    esac
}

input_keyboard_profile_allowed() {
    _input_profile_args_allowed keyboard "$@"
}

input_mouse_profile_allowed() {
    _input_profile_args_allowed relative-mouse "$@"
}

input_relative_mouse_profile_allowed() {
    input_mouse_profile_allowed "$@"
}

input_pointer_profile_allowed() {
    _input_profile_args_allowed absolute-pointer "$@"
}

input_absolute_pointer_profile_allowed() {
    input_pointer_profile_allowed "$@"
}

input_tablet_profile_allowed() {
    input_pointer_profile_allowed "$@"
}

# Old helper retained for external callers that pass a pre-built string and an
# explicit pool.  It is intentionally generic and does not grant active status
# to any row in the compatibility catalogs.
input_profile_row_allowed() {
    local requested=$1
    shift
    local row
    for row in "$@"; do
        [[ "$row" == "$requested" || "${row%|*}" == "$requested" ]] && \
            return 0
    done
    return 1
}

input_profile_compat_row_allowed() {
    local kind=$1 requested=$2 row
    while IFS= read -r row; do
        [[ "${row%%|*}" == "$requested" ]] && return 0
    done < <(_input_profile_compat_rows "$kind")
    return 1
}

_input_profile_print_rows() {
    local scope=$1 kind=$2 row
    case "$scope" in
        active)
            while IFS= read -r row; do
                printf '%s\t%s\t%s\n' "$scope" "$kind" \
                    "${row//|/$'\t'}"
            done < <(_input_profile_active_rows "$kind")
            ;;
        compat|quarantine)
            while IFS= read -r row; do
                printf 'compat\t%s\t%s\n' "$kind" "${row//|/$'\t'}"
            done < <(_input_profile_compat_rows "$kind")
            ;;
        *) return 2 ;;
    esac
}

input_profile_print_catalog() {
    local scope=${1:-active} requested_kind=${2:-all} kind
    case "$scope" in
        active|compat|quarantine|all) ;;
        *)
            printf 'input catalog scope 非法: %s\n' "$scope" >&2
            return 2
            ;;
    esac
    if [[ "$requested_kind" != all ]]; then
        requested_kind=$(_input_profile_normalize_kind "$requested_kind") || {
            printf 'input catalog kind 非法: %s\n' "$2" >&2
            return 2
        }
    fi

    printf 'SCOPE\tKIND\t%s\n' "${INPUT_PROFILE_SCHEMA//|/$'\t'}"
    for kind in keyboard relative-mouse absolute-pointer; do
        [[ "$requested_kind" == all || "$requested_kind" == "$kind" ]] || \
            continue
        if [[ "$scope" == active || "$scope" == all ]]; then
            _input_profile_print_rows active "$kind" || return
        fi
        if [[ "$scope" == compat || "$scope" == quarantine || \
              "$scope" == all ]]; then
            _input_profile_print_rows compat "$kind" || return
        fi
    done
}

input_keyboard_profile_print_catalog() {
    input_profile_print_catalog "${1:-active}" keyboard
}
input_mouse_profile_print_catalog() {
    input_profile_print_catalog "${1:-active}" relative-mouse
}
input_relative_mouse_profile_print_catalog() {
    input_mouse_profile_print_catalog "$@"
}
input_pointer_profile_print_catalog() {
    input_profile_print_catalog "${1:-active}" absolute-pointer
}
input_absolute_pointer_profile_print_catalog() {
    input_pointer_profile_print_catalog "$@"
}
input_tablet_profile_print_catalog() {
    input_pointer_profile_print_catalog "$@"
}

_input_profile_validate_rows() {
    local kind=$1 scope=$2 expected_count=$3
    shift 3
    local row id brand model vid pid bcd usb_version raw_mfr raw_product
    local serial_policy fidelity tuple field
    local count=0
    local -a fields=()
    local -A seen_id=() seen_tuple=()

    for row in "$@"; do
        IFS='|' read -r -a fields <<<"$row"
        if (( ${#fields[@]} != 11 )); then
            printf '%s/%s profile 必须恰好有 11 字段: %s\n' \
                "$scope" "$kind" "$row" >&2
            return 1
        fi
        IFS='|' read -r id brand model vid pid bcd usb_version raw_mfr \
            raw_product serial_policy fidelity <<<"$row"
        [[ "$id" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || {
            printf '%s/%s stable id 非法: %s\n' "$scope" "$kind" "$id" >&2
            return 1
        }
        for field in "$brand" "$model" "$raw_mfr" "$raw_product"; do
            [[ -n "$field" && "$field" != *','* ]] || {
                printf '%s/%s 字符串为空或含 QEMU 参数逗号: %s\n' \
                    "$scope" "$kind" "$row" >&2
                return 1
            }
        done
        [[ "$vid" =~ ^0x[0-9A-F]{4}$ && \
           "$pid" =~ ^0x[0-9A-F]{4}$ && \
           "$bcd" =~ ^0x[0-9A-F]{4}$ ]] || {
            printf '%s/%s VID/PID/bcdDevice 非法: %s\n' \
                "$scope" "$kind" "$row" >&2
            return 1
        }
        [[ "$usb_version" == 1 || "$usb_version" == 2 ]] || {
            printf '%s/%s usb-version 只允许 1 或 2: %s\n' \
                "$scope" "$kind" "$row" >&2
            return 1
        }
        [[ "$serial_policy" == none ]] || {
            printf '%s/%s serial-policy 只允许 none: %s\n' \
                "$scope" "$kind" "$row" >&2
            return 1
        }
        case "$fidelity" in
            identity_only_generic_report|generic_virtual_only|\
            compat_legacy_identity_only|quarantined_unverified_identity|\
            quarantined_protocol_mismatch|\
            quarantined_protocol_and_serial_mismatch|\
            quarantined_wrong_tuple_never_active) ;;
            *)
                printf '%s/%s fidelity 非法: %s\n' \
                    "$scope" "$kind" "$fidelity" >&2
                return 1
                ;;
        esac
        [[ -z ${seen_id[$id]+x} ]] || {
            printf '%s/%s stable id 重复: %s\n' "$scope" "$kind" "$id" >&2
            return 1
        }
        tuple="$vid:$pid"
        [[ -z ${seen_tuple[$tuple]+x} ]] || {
            printf '%s/%s VID:PID 重复: %s\n' \
                "$scope" "$kind" "$tuple" >&2
            return 1
        }
        seen_id[$id]=1
        seen_tuple[$tuple]=1
        count=$((count + 1))

        if [[ "$scope" == active ]]; then
            case "$kind" in
                keyboard|relative-mouse)
                    [[ "$fidelity" == identity_only_generic_report && \
                       "$brand" != virtual && "$raw_mfr" != not_exposed ]] || {
                        printf '%s active profile 不是明确的 generic-report identity: %s\n' \
                            "$kind" "$row" >&2
                        return 1
                    }
                    ;;
                absolute-pointer)
                    [[ "$row" == \
                      'qemu-generic-usb-tablet|virtual|QEMU USB Tablet|0x0627|0x0001|0x0000|2|QEMU|QEMU USB Tablet|none|generic_virtual_only' ]] || {
                        printf 'absolute-pointer active profile 禁止品牌覆盖: %s\n' \
                            "$row" >&2
                        return 1
                    }
                    ;;
            esac
        else
            [[ "$id" == legacy-* ]] || {
                printf '%s compatibility row 缺少 legacy- 前缀: %s\n' \
                    "$kind" "$id" >&2
                return 1
            }
        fi
    done

    (( count == expected_count )) || {
        printf '%s/%s profile 数量应为 %s，实际 %s\n' \
            "$scope" "$kind" "$expected_count" "$count" >&2
        return 1
    }
}

_input_profile_validate_active_brands() {
    local kind=$1 expected=$2 row _id brand _rest
    local -A brands=()
    while IFS= read -r row; do
        IFS='|' read -r _id brand _rest <<<"$row"
        brands[$brand]=1
    done < <(_input_profile_active_rows "$kind")
    (( ${#brands[@]} == expected )) || {
        printf '%s active brand 数量应为 %s，实际 %s\n' \
            "$kind" "$expected" "${#brands[@]}" >&2
        return 1
    }
}

input_profile_validate_catalog() {
    local veikk_wrong_tuple='legacy-veikk-a30-wrong-tuple|VEIKK|A30 historical WRONG tuple|0x2FEB|0x0001|0x0100|2|VEIKK|VEIKK A30|none|quarantined_wrong_tuple_never_active'
    _input_profile_validate_rows keyboard active 3 \
        "${INPUT_KEYBOARD_ACTIVE_PROFILES[@]}" &&
    _input_profile_validate_rows relative-mouse active 3 \
        "${INPUT_RELATIVE_MOUSE_ACTIVE_PROFILES[@]}" &&
    _input_profile_validate_rows absolute-pointer active 1 \
        "${INPUT_ABSOLUTE_POINTER_ACTIVE_PROFILES[@]}" &&
    _input_profile_validate_rows keyboard compat 5 \
        "${INPUT_KEYBOARD_COMPAT_PROFILES[@]}" &&
    _input_profile_validate_rows relative-mouse compat 5 \
        "${INPUT_RELATIVE_MOUSE_COMPAT_PROFILES[@]}" &&
    _input_profile_validate_rows absolute-pointer compat 4 \
        "${INPUT_ABSOLUTE_POINTER_COMPAT_PROFILES[@]}" &&
    _input_profile_validate_active_brands keyboard 3 &&
    _input_profile_validate_active_brands relative-mouse 3 &&
    [[ "$(_input_profile_find_row compat absolute-pointer \
        legacy-veikk-a30-wrong-tuple)" == "$veikk_wrong_tuple" ]] &&
    ! input_pointer_profile_allowed legacy-veikk-a30-wrong-tuple
}

# Historical public name retained for callers that validated one legacy pool.
input_profile_validate_rows() {
    local kind=$1
    shift
    local row vid pid manufacturer product policy seen='|'
    for row in "$@"; do
        IFS='|' read -r vid pid manufacturer product policy <<<"$row"
        [[ "$vid" =~ ^0x[0-9A-F]{4}$ && \
           "$pid" =~ ^0x[0-9A-F]{4}$ && \
           -n "$manufacturer" && -n "$product" && "$policy" == none ]] || {
            printf '%s legacy USB profile 非法: %s\n' "$kind" "$row" >&2
            return 1
        }
        [[ "$seen" != *"|$vid:$pid|"* ]] || {
            printf '%s legacy USB VID/PID 重复: %s:%s\n' \
                "$kind" "$vid" "$pid" >&2
            return 1
        }
        seen+="$vid:$pid|"
    done
}
