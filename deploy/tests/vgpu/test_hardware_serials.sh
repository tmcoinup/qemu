#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SERIAL_LIB="$REPO_ROOT/deploy/lib/hardware-serials.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_eq() {
    local expected=$1 actual=$2 label=$3
    [[ "$actual" == "$expected" ]] ||
        fail "$label: expected '$expected', got '$actual'"
}

assert_rejected() {
    local label=$1
    shift
    if "$@" >/dev/null 2>&1; then
        fail "$label was accepted"
    fi
}

[[ -r "$SERIAL_LIB" ]] || fail 'hardware serial library is missing'
source_output=$(bash -c 'source "$1"' _ "$SERIAL_LIB") ||
    fail 'hardware serial library cannot be sourced in a clean shell'
assert_eq '' "$source_output" 'source-time output'

# shellcheck source=../../lib/hardware-serials.sh
source "$SERIAL_LIB"

# Board serials are vendor-bound.  MSI additionally binds its MS-XXXX board
# code, Gigabyte binds release YY plus a real 01..53 week field, and ASRock/
# ECS follow their published label formats.
for _iteration in $(seq 1 32); do
    asus_serial=$(g11_hardware_serial_board_generate \
        'ASUSTeK COMPUTER INC.' H81M-K 2013)
    g11_hardware_serial_board_validate \
        'ASUSTeK COMPUTER INC.' "$asus_serial" H81M-K 2013 ||
        fail "generated ASUS serial is invalid: $asus_serial"
    [[ "$asus_serial" =~ ^[A-Z0-9]{2}S[A-Z0-9]{9}$ ]] ||
        fail "ASUS serial shape drifted: $asus_serial"

    msi_serial=$(g11_hardware_serial_board_generate \
        MSI 'H81M-P33 (MS-7817)' 2013)
    g11_hardware_serial_board_validate \
        MSI "$msi_serial" 'H81M-P33 (MS-7817)' 2013 ||
        fail "generated MSI serial is invalid: $msi_serial"
    [[ "$msi_serial" =~ ^601-7817-[A-Z0-9]{14}$ ]] ||
        fail "MSI serial did not bind MS-7817: $msi_serial"

    gigabyte_serial=$(g11_hardware_serial_board_generate \
        Gigabyte GA-H81M-S1 2014)
    g11_hardware_serial_board_validate \
        Gigabyte "$gigabyte_serial" GA-H81M-S1 2014 ||
        fail "generated Gigabyte serial is invalid: $gigabyte_serial"
    [[ "$gigabyte_serial" =~ ^SN14(0[1-9]|[1-4][0-9]|5[0-3])[0-9]{8}$ ]] ||
        fail "Gigabyte year/week shape drifted: $gigabyte_serial"

    asrock_serial=$(g11_hardware_serial_board_generate ASRock H81M-HDS 2013)
    g11_hardware_serial_board_validate \
        ASRock "$asrock_serial" H81M-HDS 2013 ||
        fail "generated ASRock serial is invalid: $asrock_serial"
    [[ "$asrock_serial" =~ ^[0-9A-Z]{2}M0X[A-Z][0-9]{6}$ ]] ||
        fail "ASRock serial shape drifted: $asrock_serial"

    ecs_serial=$(g11_hardware_serial_board_generate ECS H81H3-M4 2013)
    g11_hardware_serial_board_validate ECS "$ecs_serial" H81H3-M4 2013 ||
        fail "generated ECS serial is invalid: $ecs_serial"
    [[ "$ecs_serial" =~ ^[A-Z][0-9]{5}[A-Z][0-9]{8}$ ]] ||
        fail "ECS serial shape drifted: $ecs_serial"
done

# Accepted aliases match current G-11 and the canonical V-11 spellings.
g11_hardware_serial_board_validate ASUS A1S2B3C4D5E6 '' '' ||
    fail 'ASUS alias rejected a valid serial'
g11_hardware_serial_board_validate \
    'Micro-Star International Co., Ltd.' \
    601-7817-01AB23456789CD 'H81M-P33 (MS-7817)' '' ||
    fail 'canonical MSI alias rejected a valid serial'
g11_hardware_serial_board_validate \
    'Gigabyte Technology Co., Ltd.' SN141200024108 GA-H81M-S1 2014 ||
    fail 'canonical Gigabyte alias rejected a valid serial'
g11_hardware_serial_board_validate \
    'ASRock Inc.' 71M0XE001276 H81M-HDS 2013 ||
    fail 'canonical ASRock alias rejected an official-shape serial'
g11_hardware_serial_board_validate \
    'Elitegroup Computer Systems Co., Ltd.' A12345B12345678 H81H3-M4 2013 ||
    fail 'canonical ECS alias rejected an official-shape serial'

assert_rejected 'ASUS missing fixed third S' \
    g11_hardware_serial_board_validate ASUS A12B3C4D5E6F '' ''
assert_rejected 'MSI serial with another board code' \
    g11_hardware_serial_board_validate MSI \
    601-7C08-01AB23456789CD 'H81M-P33 (MS-7817)' ''
assert_rejected 'MSI model without MS code' \
    g11_hardware_serial_board_generate MSI H81M-P33 2013
assert_rejected 'Gigabyte serial with wrong release YY' \
    g11_hardware_serial_board_validate Gigabyte SN151200024108 GA-H81M-S1 2014
assert_rejected 'Gigabyte week zero' \
    g11_hardware_serial_board_validate Gigabyte SN140000024108 GA-H81M-S1 2014
assert_rejected 'Gigabyte week 54' \
    g11_hardware_serial_board_validate Gigabyte SN145400024108 GA-H81M-S1 2014
assert_rejected 'ASRock serial without fixed M0X token' \
    g11_hardware_serial_board_validate ASRock 71M1XE001276 H81M-HDS 2013
assert_rejected 'ECS serial without the second letter' \
    g11_hardware_serial_board_validate ECS A12345612345678 H81H3-M4 2013
assert_rejected 'unknown board vendor' \
    g11_hardware_serial_board_generate Example Example-H81 2014

# JEDEC module serials are exactly four bytes rendered as uppercase hex.
for _iteration in $(seq 1 64); do
    memory_serial=$(g11_hardware_serial_memory_generate)
    g11_hardware_serial_memory_validate "$memory_serial" ||
        fail "generated memory serial is invalid: $memory_serial"
done
for reserved in 00000000 00000001 FFFFFFFF; do
    assert_rejected "reserved memory serial $reserved" \
        g11_hardware_serial_memory_validate "$reserved"
done
assert_rejected 'lowercase memory serial' \
    g11_hardware_serial_memory_validate abcdef12
assert_rejected 'short memory serial' \
    g11_hardware_serial_memory_validate ABCDEF1

memory_base=89ABCDEF
memory_slot1=$(g11_hardware_serial_memory_for_slot "$memory_base" 1)
memory_slot2_a=$(g11_hardware_serial_memory_for_slot "$memory_base" 2)
memory_slot2_b=$(g11_hardware_serial_memory_for_slot "$memory_base" 2)
memory_slot3=$(g11_hardware_serial_memory_for_slot "$memory_base" 3)
assert_eq "$memory_base" "$memory_slot1" 'slot 1 base serial'
assert_eq "$memory_slot2_a" "$memory_slot2_b" 'slot 2 stable derivation'
[[ "$memory_slot2_a" != "$memory_base" &&
   "$memory_slot3" != "$memory_base" &&
   "$memory_slot3" != "$memory_slot2_a" ]] ||
    fail 'per-slot memory serials are not distinct'
g11_hardware_serial_memory_validate "$memory_slot2_a" ||
    fail 'slot 2 derivation is not a legal JEDEC serial'
g11_hardware_serial_memory_validate "$memory_slot3" ||
    fail 'slot 3 derivation is not a legal JEDEC serial'
assert_rejected 'memory slot zero' \
    g11_hardware_serial_memory_for_slot "$memory_base" 0
assert_rejected 'reserved memory base derivation' \
    g11_hardware_serial_memory_for_slot 00000000 2

memory_list=$(g11_hardware_serial_memory_list_generate "$memory_base" 2)
assert_eq "$memory_base,$memory_slot2_a" "$memory_list" \
    'complete two-slot memory serial list'
g11_hardware_serial_memory_list_validate \
    "$memory_base" 2 "$memory_list" || \
    fail 'valid per-slot memory serial list was rejected'
assert_rejected 'memory list with a cloned slot serial' \
    g11_hardware_serial_memory_list_validate \
    "$memory_base" 2 "$memory_base,$memory_base"
assert_rejected 'memory list with wrong slot count' \
    g11_hardware_serial_memory_list_validate "$memory_base" 2 "$memory_base"
assert_rejected 'memory list with lowercase slot serial' \
    g11_hardware_serial_memory_list_validate \
    "$memory_base" 2 "$memory_base,${memory_slot2_a,,}"
assert_rejected 'memory list slot count above safety limit' \
    g11_hardware_serial_memory_list_generate "$memory_base" 65
assert_rejected 'memory list pathological slot count' \
    g11_hardware_serial_memory_list_generate \
    "$memory_base" 999999999999999999999999999999

legacy_memory_seed='legacy-memory-label'
legacy_memory_base_a=$(g11_hardware_serial_memory_stable_from_seed \
    "$legacy_memory_seed")
legacy_memory_base_b=$(g11_hardware_serial_memory_stable_from_seed \
    "$legacy_memory_seed")
assert_eq "$legacy_memory_base_a" "$legacy_memory_base_b" \
    'legacy memory seed stable normalization'
g11_hardware_serial_memory_validate "$legacy_memory_base_a" || \
    fail 'legacy memory seed did not normalize to a valid JEDEC serial'
assert_rejected 'empty legacy memory seed' \
    g11_hardware_serial_memory_stable_from_seed ''

# The serial library must cover exactly the nine current G-11 SSD keys while
# remaining independent from hardware-profiles.sh at source time.
mapfile -t serial_ssd_keys < <(g11_hardware_serial_ssd_profile_keys)
# shellcheck source=../../lib/hardware-profiles.sh
source "$REPO_ROOT/deploy/lib/hardware-profiles.sh"
mapfile -t catalog_ssd_keys < <(ssd_profile_keys)
assert_eq "$(printf '%s\n' "${catalog_ssd_keys[@]}" | LC_ALL=C sort)" \
    "$(printf '%s\n' "${serial_ssd_keys[@]}" | LC_ALL=C sort)" \
    'SSD serial/catalog key sets'

for profile in "${serial_ssd_keys[@]}"; do
    serial=$(g11_hardware_serial_ssd_generate "$profile")
    g11_hardware_serial_ssd_validate "$profile" "$serial" strict ||
        fail "$profile rejected its strict generated serial: $serial"
    g11_hardware_serial_ssd_validate "$profile" "$serial" compatible ||
        fail "$profile rejected its strict serial in compatible mode: $serial"
    case "$profile" in
        samsung-840-pro-512gb|samsung-850-pro-512gb|\
        samsung-860-pro-512gb)
            [[ "$serial" =~ ^S[0-9A-F]{14}$ ]] ||
                fail "$profile strict Samsung SATA shape drifted: $serial"
            ;;
        samsung-970-pro-512gb)
            [[ "$serial" =~ ^S[A-Z0-9]{3}N[A-Z0-9]{10}$ ]] ||
                fail "$profile strict Samsung NVMe shape drifted: $serial"
            ;;
        crucial-mx100-512gb)
            [[ "$serial" =~ ^[0-9A-F]{12}$ ]] || fail "$profile shape drifted"
            ;;
        kingston-kc400-512gb)
            [[ "$serial" =~ ^50026B72[0-9A-F]{8}$ ]] || fail "$profile shape drifted"
            ;;
        intel-545s-512gb)
            [[ "$serial" =~ ^(BTLA|PHLA)[A-Z0-9]{8}512DGN$ ]] ||
                fail "$profile shape drifted"
            ;;
        wd-pc-sa530-512gb)
            [[ "$serial" =~ ^[A-Z0-9]{12}$ ]] || fail "$profile shape drifted"
            ;;
        wd-black-pcie-512gb)
            [[ "$serial" =~ ^[0-9]{12}$ ]] || fail "$profile shape drifted"
            ;;
    esac
done

# Existing G-11 used a generic 16-character Samsung form.  Compatibility mode
# accepts it for immutable profiles, while strict mode requires the reviewed
# per-family 15-character forms above.
legacy_samsung=S0123456789ABCDE
for profile in samsung-840-pro-512gb samsung-850-pro-512gb \
        samsung-860-pro-512gb samsung-970-pro-512gb; do
    g11_hardware_serial_ssd_validate \
        "$profile" "$legacy_samsung" compatible ||
        fail "$profile rejected a current G-11 Samsung serial"
    assert_rejected "$profile accepted legacy Samsung serial as strict" \
        g11_hardware_serial_ssd_validate "$profile" "$legacy_samsung" strict
done

# Current non-Samsung formats remain strict-compatible.
g11_hardware_serial_ssd_validate \
    crucial-mx100-512gb A1B2C3D4E5F6 strict || fail 'MX100 current format rejected'
g11_hardware_serial_ssd_validate \
    kingston-kc400-512gb 50026B72A1B2C3D4 strict || fail 'KC400 current format rejected'
g11_hardware_serial_ssd_validate \
    intel-545s-512gb BTLAABCDEFGH512DGN strict || fail 'Intel 545s current format rejected'
g11_hardware_serial_ssd_validate \
    wd-pc-sa530-512gb ABC123DEF456 strict || fail 'SA530 current format rejected'
g11_hardware_serial_ssd_validate \
    wd-black-pcie-512gb 123456789012 strict || fail 'WD Black current format rejected'

assert_rejected 'Samsung SATA all-zero placeholder' \
    g11_hardware_serial_ssd_validate samsung-850-pro-512gb \
    S00000000000000 strict
assert_rejected 'Samsung 970 all-zero payload' \
    g11_hardware_serial_ssd_validate samsung-970-pro-512gb \
    S000N0000000000 strict
assert_rejected 'Crucial all-F placeholder' \
    g11_hardware_serial_ssd_validate crucial-mx100-512gb FFFFFFFFFFFF strict
assert_rejected 'Kingston all-zero suffix' \
    g11_hardware_serial_ssd_validate kingston-kc400-512gb 50026B7200000000 strict
assert_rejected 'Intel all-zero payload' \
    g11_hardware_serial_ssd_validate intel-545s-512gb BTLA00000000512DGN strict
assert_rejected 'WD SA530 all-zero placeholder' \
    g11_hardware_serial_ssd_validate wd-pc-sa530-512gb 000000000000 strict
assert_rejected 'WD Black all-zero placeholder' \
    g11_hardware_serial_ssd_validate wd-black-pcie-512gb 000000000000 strict
assert_rejected 'SSD argument injection' \
    g11_hardware_serial_ssd_validate crucial-mx100-512gb \
    'A1B2C3,model=bad' compatible
assert_rejected 'unknown SSD profile generation' \
    g11_hardware_serial_ssd_generate example-ssd-512gb
assert_rejected 'unknown SSD validation mode' \
    g11_hardware_serial_ssd_validate crucial-mx100-512gb A1B2C3D4E5F6 legacy

# e1000e has no separate serial string: its stable hardware identity is an
# Intel globally administered unicast MAC.  Generation and launch validation
# share this exact policy rather than treating any six-byte string as valid.
intel_ouis=(00:1B:21 00:1E:67 00:21:6A 00:22:FA 00:23:14 00:24:D7)
for _iteration in $(seq 1 64); do
    mac=$(g11_hardware_mac_generate "${intel_ouis[@]}")
    g11_hardware_mac_validate "$mac" "${intel_ouis[@]}" ||
        fail "generated Intel MAC is invalid: $mac"
done
g11_hardware_mac_validate 00:22:FA:12:34:56 "${intel_ouis[@]}" ||
    fail 'known Intel MAC was rejected'
g11_hardware_mac_validate 00:22:fa:12:34:56 "${intel_ouis[@]}" ||
    fail 'lowercase Intel MAC was rejected'
assert_rejected 'locally administered MAC' \
    g11_hardware_mac_validate 02:22:FA:12:34:56 "${intel_ouis[@]}"
assert_rejected 'multicast MAC' \
    g11_hardware_mac_validate 01:22:FA:12:34:56 "${intel_ouis[@]}"
assert_rejected 'non-Intel OUI' \
    g11_hardware_mac_validate 00:16:3E:12:34:56 "${intel_ouis[@]}"
assert_rejected 'all-zero NIC suffix' \
    g11_hardware_mac_validate 00:22:FA:00:00:00 "${intel_ouis[@]}"
assert_rejected 'all-F NIC suffix' \
    g11_hardware_mac_validate 00:22:FA:FF:FF:FF "${intel_ouis[@]}"
assert_rejected 'MAC argument injection' \
    g11_hardware_mac_validate '00:22:FA:12:34:56,model=bad' "${intel_ouis[@]}"
assert_rejected 'MAC generation without an audited OUI' \
    g11_hardware_mac_generate

echo 'PASS: board, JEDEC memory, 9 SSD serial, and Intel MAC policies are strict and compatibility-aware'
