#!/usr/bin/env bash
# shellcheck shell=bash
#
# Audited variable-identity helpers for G-11 hardware profiles.
#
# Sourcing this file only defines functions.  It does not source a catalog,
# alter shell options, read credentials, generate identities, or touch host
# state.  Callers generate each value once and persist it in the VM profile.
#
# Public API:
#
#   g11_hardware_serial_board_generate VENDOR MODEL RELEASE_YEAR
#   g11_hardware_serial_board_validate VENDOR SERIAL MODEL RELEASE_YEAR
#
# MODEL is required for MSI so the MS-XXXX board code can be bound into the
# serial.  RELEASE_YEAR is required for Gigabyte so its YY/week fields are not
# invented independently from the board.  ASUS ignores those two arguments.
#
#   g11_hardware_serial_memory_generate
#   g11_hardware_serial_memory_validate SERIAL
#   g11_hardware_serial_memory_for_slot BASE_SERIAL SLOT_NUMBER
#   g11_hardware_serial_memory_stable_from_seed SEED
#   g11_hardware_serial_memory_list_generate BASE_SERIAL SLOT_COUNT
#   g11_hardware_serial_memory_list_validate BASE_SERIAL SLOT_COUNT SERIAL_LIST
#
# Slot 1 returns BASE_SERIAL.  Later slots are stable SHA-256 derivations that
# are distinct from the base and all JEDEC/SMBIOS placeholder values.
# SERIAL_LIST is the comma-delimited, guest-visible per-slot sequence.  New
# configs persist it verbatim; old configs can derive the same sequence from
# MEM_SN and MEM_SLOTS without rewriting their immutable vm.conf.
#
#   g11_hardware_serial_ssd_profile_keys
#   g11_hardware_serial_ssd_generate PROFILE
#   g11_hardware_serial_ssd_validate PROFILE SERIAL [strict|compatible]
#
# SSD generation always emits the preferred strict form.  Validation defaults
# to compatible so immutable profiles produced by the previous G-11 generator
# remain loadable.  Pass strict when accepting a newly generated identity.
#
#   g11_hardware_mac_generate OUI...
#   g11_hardware_mac_validate MAC OUI...
#
# NIC identity is its MAC address; e1000e has no separate consumer-style
# serial number.  These helpers keep the address globally administered,
# unicast, tied to one of the reviewed Intel OUIs, and reject placeholder
# suffixes.  Fleet-wide uniqueness is enforced separately before vm.conf is
# published.

_g11_hardware_serial_error() {
    printf 'hardware-serials: %s\n' "$*" >&2
    return 2
}

_g11_hardware_serial_random_chars() {
    local alphabet=${1:-} length=${2:-} result='' bytes byte index
    local alphabet_length sample_size

    [[ -n "$alphabet" && "$length" =~ ^[1-9][0-9]*$ ]] || return 2
    [[ -r /dev/urandom ]] || return 1
    alphabet_length=${#alphabet}
    (( alphabet_length > 1 )) || return 2

    while (( ${#result} < length )); do
        sample_size=$(((length - ${#result}) * 2 + 8))
        bytes=$(LC_ALL=C od -An -N "$sample_size" -tu1 /dev/urandom 2>/dev/null) \
            || return 1
        for byte in $bytes; do
            [[ "$byte" =~ ^[0-9]+$ ]] || return 1
            index=$((byte % alphabet_length))
            result+=${alphabet:index:1}
            (( ${#result} < length )) || break
        done
    done
    printf '%s\n' "$result"
}

_g11_hardware_serial_random_hex() {
    _g11_hardware_serial_random_chars 0123456789ABCDEF "$1"
}

_g11_hardware_serial_random_alnum() {
    _g11_hardware_serial_random_chars 0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ "$1"
}

_g11_hardware_serial_random_digits() {
    _g11_hardware_serial_random_chars 0123456789 "$1"
}

_g11_hardware_serial_random_bounded() {
    local upper=${1:-} value

    [[ "$upper" =~ ^[1-9][0-9]*$ ]] || return 2
    value=$(LC_ALL=C od -An -N4 -tu4 /dev/urandom 2>/dev/null) || return 1
    value=${value//[[:space:]]/}
    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$((value % upper))"
}

_g11_hardware_serial_board_vendor_token() {
    case ${1:-} in
        ASUS|'ASUSTeK COMPUTER INC.')
            printf 'asus\n'
            ;;
        MSI|'Micro-Star International Co., Ltd.')
            printf 'msi\n'
            ;;
        Gigabyte|GIGABYTE|'Gigabyte Technology Co., Ltd.')
            printf 'gigabyte\n'
            ;;
        *)
            return 2
            ;;
    esac
}

_g11_hardware_serial_msi_board_code() {
    local model=${1:-}

    if [[ "$model" =~ MS-([A-Za-z0-9]{4})([^A-Za-z0-9]|$) ]]; then
        printf '%s\n' "${BASH_REMATCH[1]^^}"
        return 0
    fi
    return 2
}

_g11_hardware_serial_release_year_yy() {
    local release_year=${1:-}

    [[ "$release_year" =~ ^20[0-9]{2}$ ]] || return 2
    printf '%s\n' "${release_year:2:2}"
}

g11_hardware_serial_board_generate() {
    local vendor=${1:-} model=${2:-} release_year=${3:-}
    local token code yy week suffix prefix

    token=$(_g11_hardware_serial_board_vendor_token "$vendor") || {
        _g11_hardware_serial_error "unsupported board vendor: ${vendor:-<empty>}"
        return
    }
    case "$token" in
        asus)
            prefix=$(_g11_hardware_serial_random_hex 2) || return
            suffix=$(_g11_hardware_serial_random_hex 9) || return
            printf '%sS%s\n' "$prefix" "$suffix"
            ;;
        msi)
            code=$(_g11_hardware_serial_msi_board_code "$model") || {
                _g11_hardware_serial_error \
                    "MSI model must contain an audited MS-XXXX board code"
                return
            }
            suffix=$(_g11_hardware_serial_random_hex 14) || return
            printf '601-%s-%s\n' "$code" "$suffix"
            ;;
        gigabyte)
            yy=$(_g11_hardware_serial_release_year_yy "$release_year") || {
                _g11_hardware_serial_error \
                    "Gigabyte release year must be a four-digit 20xx value"
                return
            }
            week=$(_g11_hardware_serial_random_bounded 53) || return
            week=$((week + 1))
            suffix=$(_g11_hardware_serial_random_digits 8) || return
            printf 'SN%s%02d%s\n' "$yy" "$week" "$suffix"
            ;;
    esac
}

g11_hardware_serial_board_validate() {
    local vendor=${1:-} serial=${2:-} model=${3:-} release_year=${4:-}
    local token code yy week

    token=$(_g11_hardware_serial_board_vendor_token "$vendor") || return 2
    case "$token" in
        asus)
            [[ "$serial" =~ ^[A-Z0-9]{2}S[A-Z0-9]{9}$ ]]
            ;;
        msi)
            code=$(_g11_hardware_serial_msi_board_code "$model") || return 2
            [[ "$serial" =~ ^601-${code}-[A-Z0-9]{14}$ ]]
            ;;
        gigabyte)
            yy=$(_g11_hardware_serial_release_year_yy "$release_year") \
                || return 2
            [[ "$serial" =~ ^SN[0-9]{12}$ ]] || return 1
            [[ "${serial:2:2}" == "$yy" ]] || return 1
            week=${serial:4:2}
            (( 10#$week >= 1 && 10#$week <= 53 ))
            ;;
    esac
}

g11_hardware_serial_memory_validate() {
    local serial=${1:-}

    [[ "$serial" =~ ^[0-9A-F]{8}$ ]] || return 1
    case "$serial" in
        00000000|00000001|FFFFFFFF) return 1 ;;
    esac
}

g11_hardware_serial_memory_generate() {
    local serial attempt

    for ((attempt = 0; attempt < 256; attempt += 1)); do
        serial=$(_g11_hardware_serial_random_hex 8) || return
        if g11_hardware_serial_memory_validate "$serial"; then
            printf '%s\n' "$serial"
            return 0
        fi
    done
    return 1
}

g11_hardware_serial_memory_for_slot() {
    local base=${1:-} slot=${2:-} attempt seed digest serial

    g11_hardware_serial_memory_validate "$base" || return 2
    [[ "$slot" =~ ^[1-9][0-9]*$ ]] || return 2
    if (( 10#$slot == 1 )); then
        printf '%s\n' "$base"
        return 0
    fi
    command -v sha256sum >/dev/null 2>&1 || return 1
    for ((attempt = 0; attempt < 256; attempt += 1)); do
        seed="${base}-dimm$((10#$slot))"
        (( attempt == 0 )) || seed+="-${attempt}"
        digest=$(printf '%s' "$seed" | sha256sum) || return 1
        serial=${digest:0:8}
        serial=${serial^^}
        if [[ "$serial" != "$base" ]] &&
                g11_hardware_serial_memory_validate "$serial"; then
            printf '%s\n' "$serial"
            return 0
        fi
    done
    return 1
}

g11_hardware_serial_memory_stable_from_seed() {
    local seed=${1-} attempt digest serial

    [[ -n "$seed" && "$seed" != *$'\n'* && "$seed" != *$'\r'* ]] || return 2
    command -v sha256sum >/dev/null 2>&1 || return 1
    for ((attempt = 0; attempt < 256; attempt += 1)); do
        digest=$(printf '%s-attempt%s' "$seed" "$attempt" | sha256sum) \
            || return 1
        serial=${digest:0:8}
        serial=${serial^^}
        if g11_hardware_serial_memory_validate "$serial"; then
            printf '%s\n' "$serial"
            return 0
        fi
    done
    return 1
}

g11_hardware_serial_memory_list_generate() {
    local base=${1:-} slot_count=${2:-} slot serial list=''
    local seen='|'

    g11_hardware_serial_memory_validate "$base" || return 2
    [[ "$slot_count" =~ ^[1-9][0-9]*$ && ${#slot_count} -le 2 ]] \
        || return 2
    slot_count=$((10#$slot_count))
    ((slot_count <= 64)) || return 2
    for ((slot = 1; slot <= slot_count; slot += 1)); do
        serial=$(g11_hardware_serial_memory_for_slot "$base" "$slot") \
            || return
        [[ "$seen" != *"|$serial|"* ]] || return 1
        [[ -z "$list" ]] || list+=,
        list+=$serial
        seen+="$serial|"
    done
    printf '%s\n' "$list"
}

g11_hardware_serial_memory_list_validate() {
    local base=${1:-} slot_count=${2:-} serial_list=${3-} expected

    (( $# == 3 )) || return 2
    expected=$(g11_hardware_serial_memory_list_generate \
        "$base" "$slot_count") || return
    [[ "$serial_list" == "$expected" ]]
}

g11_hardware_serial_ssd_profile_keys() {
    printf '%s\n' \
        samsung-840-pro-512gb \
        samsung-850-pro-512gb \
        samsung-860-pro-512gb \
        crucial-mx100-512gb \
        kingston-kc400-512gb \
        intel-545s-512gb \
        wd-pc-sa530-512gb \
        wd-black-pcie-512gb \
        samsung-970-pro-512gb
}

g11_hardware_serial_ssd_profile_supported() {
    case ${1:-} in
        samsung-840-pro-512gb|samsung-850-pro-512gb|\
        samsung-860-pro-512gb|crucial-mx100-512gb|\
        kingston-kc400-512gb|intel-545s-512gb|\
        wd-pc-sa530-512gb|wd-black-pcie-512gb|\
        samsung-970-pro-512gb)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

_g11_hardware_serial_payload_valid() {
    local payload=${1:-}

    [[ -n "$payload" ]] || return 1
    [[ ! "$payload" =~ ^0+$ && ! "$payload" =~ ^F+$ ]]
}

g11_hardware_serial_ssd_generate() {
    local profile=${1:-} prefix payload serial attempt choice

    g11_hardware_serial_ssd_profile_supported "$profile" || {
        _g11_hardware_serial_error "unsupported SSD profile: ${profile:-<empty>}"
        return
    }
    for ((attempt = 0; attempt < 256; attempt += 1)); do
        case "$profile" in
            samsung-840-pro-512gb|samsung-850-pro-512gb|\
            samsung-860-pro-512gb)
                payload=$(_g11_hardware_serial_random_hex 14) || return
                serial="S${payload}"
                ;;
            samsung-970-pro-512gb)
                prefix=$(_g11_hardware_serial_random_hex 3) || return
                payload=$(_g11_hardware_serial_random_hex 10) || return
                serial="S${prefix}N${payload}"
                payload="${prefix}${payload}"
                ;;
            crucial-mx100-512gb)
                payload=$(_g11_hardware_serial_random_hex 12) || return
                serial=$payload
                ;;
            kingston-kc400-512gb)
                payload=$(_g11_hardware_serial_random_hex 8) || return
                serial="50026B72${payload}"
                ;;
            intel-545s-512gb)
                choice=$(_g11_hardware_serial_random_bounded 2) || return
                if (( choice == 0 )); then
                    prefix=BTLA
                else
                    prefix=PHLA
                fi
                payload=$(_g11_hardware_serial_random_alnum 8) || return
                serial="${prefix}${payload}512DGN"
                ;;
            wd-pc-sa530-512gb)
                payload=$(_g11_hardware_serial_random_alnum 12) || return
                serial=$payload
                ;;
            wd-black-pcie-512gb)
                payload=$(_g11_hardware_serial_random_digits 12) || return
                serial=$payload
                ;;
        esac
        _g11_hardware_serial_payload_valid "$payload" || continue
        if g11_hardware_serial_ssd_validate "$profile" "$serial" strict; then
            printf '%s\n' "$serial"
            return 0
        fi
    done
    return 1
}

g11_hardware_serial_ssd_validate() {
    local profile=${1:-} serial=${2:-} mode=${3:-compatible} payload

    g11_hardware_serial_ssd_profile_supported "$profile" || return 2
    case "$mode" in
        strict|compatible) ;;
        *) return 2 ;;
    esac

    case "$profile" in
        samsung-840-pro-512gb|samsung-850-pro-512gb|\
        samsung-860-pro-512gb)
            if [[ "$serial" =~ ^S[0-9A-F]{14}$ ]]; then
                payload=${serial:1}
            elif [[ "$mode" == compatible &&
                    "$serial" =~ ^S[A-Z0-9]{15}$ ]]; then
                payload=${serial:1}
            else
                return 1
            fi
            ;;
        samsung-970-pro-512gb)
            if [[ "$serial" =~ ^S[A-Z0-9]{3}N[A-Z0-9]{10}$ ]]; then
                payload="${serial:1:3}${serial:5:10}"
            elif [[ "$mode" == compatible &&
                    "$serial" =~ ^S[A-Z0-9]{15}$ ]]; then
                payload=${serial:1}
            else
                return 1
            fi
            ;;
        crucial-mx100-512gb)
            [[ "$serial" =~ ^[0-9A-F]{12}$ ]] || return 1
            payload=$serial
            ;;
        kingston-kc400-512gb)
            [[ "$serial" =~ ^50026B72[0-9A-F]{8}$ ]] || return 1
            payload=${serial:8}
            ;;
        intel-545s-512gb)
            [[ "$serial" =~ ^(BTLA|PHLA)[A-Z0-9]{8}512DGN$ ]] || return 1
            payload=${serial:4:8}
            ;;
        wd-pc-sa530-512gb)
            [[ "$serial" =~ ^[A-Z0-9]{12}$ ]] || return 1
            payload=$serial
            ;;
        wd-black-pcie-512gb)
            [[ "$serial" =~ ^[0-9]{12}$ ]] || return 1
            payload=$serial
            ;;
    esac
    _g11_hardware_serial_payload_valid "$payload"
}

g11_hardware_mac_validate() {
    local mac=${1:-} mac_upper first_octet oui suffix allowed
    shift || true

    [[ "$mac" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]] || return 1
    mac_upper=${mac^^}
    first_octet=${mac_upper%%:*}
    # bit 0 = multicast, bit 1 = locally administered.  An Intel factory OUI
    # address must have both clear rather than merely looking like six bytes.
    (( (16#$first_octet & 3) == 0 )) || return 1

    oui=${mac_upper:0:8}
    suffix=${mac_upper:9}
    suffix=${suffix//:/}
    [[ "$suffix" != 000000 && "$suffix" != FFFFFF ]] || return 1

    for allowed in "$@"; do
        [[ "${allowed^^}" == "$oui" ]] && return 0
    done
    return 1
}

g11_hardware_mac_generate() {
    local -a allowed_ouis=("$@")
    local oui suffix mac index attempt

    ((${#allowed_ouis[@]} > 0)) || {
        _g11_hardware_serial_error "at least one NIC OUI is required"
        return
    }
    for ((attempt = 0; attempt < 256; attempt += 1)); do
        index=$(_g11_hardware_serial_random_bounded "${#allowed_ouis[@]}") \
            || return
        oui=${allowed_ouis[$index]^^}
        suffix=$(_g11_hardware_serial_random_hex 6) || return
        mac="${oui}:${suffix:0:2}:${suffix:2:2}:${suffix:4:2}"
        if g11_hardware_mac_validate "$mac" "${allowed_ouis[@]}"; then
            printf '%s\n' "$mac"
            return 0
        fi
    done
    return 1
}
