#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=../../lib/input-profiles.sh
source "$repo_root/deploy/lib/input-profiles.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_eq() {
    local expected=$1 actual=$2 label=$3
    [[ "$actual" == "$expected" ]] || \
        fail "$label: expected '$expected', got '$actual'"
}

assert_rejected() {
    local label=$1
    shift
    if "$@" >/dev/null 2>&1; then
        fail "$label"
    fi
}

input_profile_validate_catalog || fail 'input catalog validation'
assert_eq 2 "$INPUT_COMPONENT_CONTRACT_CURRENT_VERSION" 'input component contract'
assert_eq \
    'stable-id|brand|model|vid|pid|bcd-device|usb-version|raw-manufacturer|raw-product|serial-policy|fidelity' \
    "$INPUT_PROFILE_SCHEMA" 'input profile schema'

assert_eq 3 "${#INPUT_KEYBOARD_ACTIVE_PROFILES[@]}" \
    'active keyboard count'
assert_eq 3 "${#INPUT_RELATIVE_MOUSE_ACTIVE_PROFILES[@]}" \
    'active relative mouse count'
assert_eq 1 "${#INPUT_ABSOLUTE_POINTER_ACTIVE_PROFILES[@]}" \
    'active absolute pointer count'
assert_eq 5 "${#INPUT_KEYBOARD_COMPAT_PROFILES[@]}" \
    'archived keyboard count'
assert_eq 5 "${#INPUT_RELATIVE_MOUSE_COMPAT_PROFILES[@]}" \
    'archived relative mouse count'
assert_eq 4 "${#INPUT_ABSOLUTE_POINTER_COMPAT_PROFILES[@]}" \
    'quarantined absolute pointer count'

declare -A keyboard_brands=() mouse_brands=()
while IFS= read -r profile_id; do
    input_keyboard_profile_load "$profile_id" || \
        fail "cannot load active keyboard $profile_id"
    assert_eq "$profile_id" "$KBD_PROFILE_ID" "$profile_id stable id"
    assert_eq active "$KBD_PROFILE_SCOPE" "$profile_id profile scope"
    assert_eq none "$KBD_SERIAL_POLICY" "$profile_id serial policy"
    assert_eq identity_only_generic_report "$KBD_FIDELITY" \
        "$profile_id fidelity"
    input_keyboard_profile_allowed "$profile_id" || \
        fail "$profile_id id is not active-allowed"
    input_keyboard_profile_allowed "$KBD_VID" "$KBD_PID" "$KBD_MFR" \
        "$KBD_PRODUCT" || fail "$profile_id legacy tuple is not allowed"
    input_keyboard_profile_allowed "$KBD_PROFILE_ID" "$KBD_BRAND" \
        "$KBD_MODEL" "$KBD_VID" "$KBD_PID" "$KBD_BCD_DEVICE" \
        "$KBD_USB_VERSION" "$KBD_RAW_MANUFACTURER" "$KBD_RAW_PRODUCT" \
        "$KBD_SERIAL_POLICY" "$KBD_FIDELITY" || \
        fail "$profile_id full contract is not allowed"
    keyboard_brands[$KBD_BRAND]=1
done < <(input_keyboard_profile_keys)
assert_eq 3 "${#keyboard_brands[@]}" 'active keyboard brand count'

while IFS= read -r profile_id; do
    input_mouse_profile_load "$profile_id" || \
        fail "cannot load active relative mouse $profile_id"
    assert_eq "$profile_id" "$MOUSE_PROFILE_ID" "$profile_id stable id"
    assert_eq active "$MOUSE_PROFILE_SCOPE" "$profile_id profile scope"
    assert_eq none "$MOUSE_SERIAL_POLICY" "$profile_id serial policy"
    assert_eq identity_only_generic_report "$MOUSE_FIDELITY" \
        "$profile_id fidelity"
    input_relative_mouse_profile_allowed "$profile_id" || \
        fail "$profile_id id is not active-allowed"
    input_mouse_profile_allowed "$MOUSE_VID" "$MOUSE_PID" "$MOUSE_MFR" \
        "$MOUSE_PRODUCT" || fail "$profile_id legacy tuple is not allowed"
    input_mouse_profile_allowed "$MOUSE_PROFILE_ID" "$MOUSE_BRAND" \
        "$MOUSE_MODEL" "$MOUSE_VID" "$MOUSE_PID" "$MOUSE_BCD_DEVICE" \
        "$MOUSE_USB_VERSION" "$MOUSE_RAW_MANUFACTURER" \
        "$MOUSE_RAW_PRODUCT" "$MOUSE_SERIAL_POLICY" "$MOUSE_FIDELITY" || \
        fail "$profile_id full contract is not allowed"
    mouse_brands[$MOUSE_BRAND]=1
done < <(input_relative_mouse_profile_keys)
assert_eq 3 "${#mouse_brands[@]}" 'active relative mouse brand count'

input_profile_load_tablet_default || fail 'cannot load generic pointer default'
assert_eq qemu-generic-usb-tablet "$TABLET_PROFILE_ID" \
    'generic pointer stable id'
assert_eq "$TABLET_PROFILE_ID" "$POINTER_PROFILE_ID" \
    'TABLET/POINTER compatibility aliases'
assert_eq active "$TABLET_PROFILE_SCOPE" 'generic pointer profile scope'
assert_eq virtual "$TABLET_BRAND" 'generic pointer brand classification'
assert_eq 0x0627 "$TABLET_VID" 'generic pointer VID'
assert_eq 0x0001 "$TABLET_PID" 'generic pointer PID'
assert_eq 0x0000 "$TABLET_BCD_DEVICE" 'generic pointer bcdDevice'
assert_eq QEMU "$TABLET_MFR" \
    'generic pointer manufacturer string policy'
assert_eq 'QEMU USB Tablet' "$TABLET_PRODUCT" 'generic pointer product'
assert_eq none "$TABLET_SERIAL_POLICY" 'generic pointer serial policy'
assert_eq generic_virtual_only "$TABLET_FIDELITY" \
    'generic pointer fidelity'
input_tablet_profile_allowed "$TABLET_PROFILE_ID" || \
    fail 'generic pointer id is not active-allowed'
input_pointer_profile_allowed "$TABLET_VID" "$TABLET_PID" "$TABLET_MFR" \
    "$TABLET_PRODUCT" || fail 'generic pointer tuple is not active-allowed'

# The 5/5/4 historical rows are audit/migration input only.  Their stable IDs
# cannot be loaded or selected by any active API, and every row records that no
# USB serial string may be projected.
for kind in keyboard relative-mouse absolute-pointer; do
    while IFS= read -r row; do
        IFS='|' read -r profile_id _brand _model _vid _pid _bcd _usb \
            _raw_mfr _raw_product serial_policy _fidelity <<<"$row"
        assert_eq none "$serial_policy" "$profile_id archived serial policy"
        input_profile_compat_row_allowed "$kind" "$profile_id" || \
            fail "$profile_id is missing from $kind compatibility catalog"
        case "$kind" in
            keyboard)
                assert_rejected "$profile_id became an active keyboard" \
                    input_keyboard_profile_allowed "$profile_id"
                input_keyboard_compat_tuple_load "$_vid" "$_pid" \
                    "$_raw_mfr" "$_raw_product" || \
                    fail "cannot atomically load archived keyboard $profile_id"
                assert_eq "$profile_id" "$KBD_PROFILE_ID" \
                    "$profile_id compat tuple load"
                assert_eq compat "$KBD_PROFILE_SCOPE" \
                    "$profile_id compat scope"
                assert_eq "$_bcd" "$KBD_BCD_DEVICE" \
                    "$profile_id compat bcdDevice"
                assert_eq "$_usb" "$KBD_USB_VERSION" \
                    "$profile_id compat USB version"
                ;;
            relative-mouse)
                assert_rejected "$profile_id became an active mouse" \
                    input_mouse_profile_allowed "$profile_id"
                input_mouse_compat_tuple_load "$_vid" "$_pid" \
                    "$_raw_mfr" "$_raw_product" || \
                    fail "cannot atomically load archived mouse $profile_id"
                assert_eq "$profile_id" "$MOUSE_PROFILE_ID" \
                    "$profile_id compat tuple load"
                assert_eq compat "$MOUSE_PROFILE_SCOPE" \
                    "$profile_id compat scope"
                assert_eq "$_bcd" "$MOUSE_BCD_DEVICE" \
                    "$profile_id compat bcdDevice"
                assert_eq "$_usb" "$MOUSE_USB_VERSION" \
                    "$profile_id compat USB version"
                ;;
            absolute-pointer)
                assert_rejected "$profile_id became an active pointer" \
                    input_pointer_profile_allowed "$profile_id"
                input_pointer_compat_tuple_load "$_vid" "$_pid" \
                    "$_raw_mfr" "$_raw_product" || \
                    fail "cannot atomically load quarantined pointer $profile_id"
                assert_eq "$profile_id" "$POINTER_PROFILE_ID" \
                    "$profile_id compat tuple load"
                assert_eq "$POINTER_PROFILE_ID" "$TABLET_PROFILE_ID" \
                    "$profile_id compat TABLET alias"
                assert_eq compat "$POINTER_PROFILE_SCOPE" \
                    "$profile_id compat scope"
                assert_eq "$_bcd" "$POINTER_BCD_DEVICE" \
                    "$profile_id compat bcdDevice"
                assert_eq "$_usb" "$POINTER_USB_VERSION" \
                    "$profile_id compat USB version"
                ;;
        esac
    done < <(_input_profile_compat_rows "$kind")
done

# A failed compatibility lookup is atomic: it must not replace any previously
# loaded profile with defaults or half of a requested tuple.
input_keyboard_profile_load microsoft-wired-keyboard-600
before_keyboard="$KBD_PROFILE_ID|$KBD_BCD_DEVICE|$KBD_USB_VERSION|$KBD_PROFILE_SCOPE"
assert_rejected 'unknown keyboard compatibility tuple was accepted' \
    input_keyboard_compat_tuple_load 0xFFFF 0xFFFF Unknown Unknown
assert_eq "$before_keyboard" \
    "$KBD_PROFILE_ID|$KBD_BCD_DEVICE|$KBD_USB_VERSION|$KBD_PROFILE_SCOPE" \
    'failed compatibility lookup changed keyboard state'

input_pointer_profile_load qemu-generic-usb-tablet
before_pointer="$POINTER_PROFILE_ID|$POINTER_BCD_DEVICE|$POINTER_USB_VERSION|$POINTER_PROFILE_SCOPE"
assert_rejected 'unknown pointer compatibility tuple was accepted' \
    input_pointer_compat_tuple_load 0xFFFF 0xFFFF Unknown Unknown
assert_eq "$before_pointer" \
    "$POINTER_PROFILE_ID|$POINTER_BCD_DEVICE|$POINTER_USB_VERSION|$POINTER_PROFILE_SCOPE" \
    'failed compatibility lookup changed pointer state'

veikk_row=$(_input_profile_find_row compat absolute-pointer \
    legacy-veikk-a30-wrong-tuple) || fail 'VEIKK historical error is not archived'
assert_eq \
    'legacy-veikk-a30-wrong-tuple|VEIKK|A30 historical WRONG tuple|0x2FEB|0x0001|0x0100|2|VEIKK|VEIKK A30|none|quarantined_wrong_tuple_never_active' \
    "$veikk_row" 'VEIKK wrong tuple quarantine marker'
assert_rejected 'historical VEIKK A30 2FEB:0001 tuple became active' \
    input_pointer_profile_allowed 0x2FEB 0x0001 VEIKK 'VEIKK A30'

# Legacy five-column names now project active rows only.  The old fabricated
# serial-prefix slot is always the literal non-exposure policy "none".
assert_eq 3 "${#KBD_POOL[@]}" 'legacy keyboard projection count'
assert_eq 3 "${#MOUSE_POOL[@]}" 'legacy mouse projection count'
assert_eq 1 "${#TABLET_POOL[@]}" 'legacy tablet projection count'
for row in "${KBD_POOL[@]}" "${MOUSE_POOL[@]}" "${TABLET_POOL[@]}"; do
    assert_eq none "${row##*|}" 'legacy projection serial policy'
done

# Random/default APIs must only return active IDs.  Repetition also catches an
# accidental switch back to one of the archived arrays.
for ((attempt = 0; attempt < 64; attempt += 1)); do
    input_profile_pick_keyboard_random
    input_keyboard_profile_allowed "$KBD_PROFILE_ID" || \
        fail "random keyboard escaped active pool: $KBD_PROFILE_ID"
    input_profile_pick_relative_mouse_random
    input_mouse_profile_allowed "$MOUSE_PROFILE_ID" || \
        fail "random mouse escaped active pool: $MOUSE_PROFILE_ID"
    input_profile_pick_tablet_random
    assert_eq qemu-generic-usb-tablet "$TABLET_PROFILE_ID" \
        'random absolute pointer must remain generic'
done

active_catalog=$(input_profile_print_catalog active)
all_catalog=$(input_profile_print_catalog all)
assert_eq $'SCOPE\tKIND\tstable-id\tbrand\tmodel\tvid\tpid\tbcd-device\tusb-version\traw-manufacturer\traw-product\tserial-policy\tfidelity' \
    "${active_catalog%%$'\n'*}" 'printed catalog header'
assert_eq 8 "$(wc -l <<<"$active_catalog")" \
    'printed active catalog header plus 7 rows'
assert_eq 22 "$(wc -l <<<"$all_catalog")" \
    'printed full catalog header plus 21 rows'

# Fail closed on policy drift, pool growth, a branded absolute pointer, or loss
# of the explicit VEIKK quarantine record.
if (
    INPUT_KEYBOARD_ACTIVE_PROFILES[0]=${INPUT_KEYBOARD_ACTIVE_PROFILES[0]/|none|/|synthetic|}
    input_profile_validate_catalog >/dev/null 2>&1
); then
    fail 'catalog accepted a keyboard serial policy other than none'
fi
if (
    INPUT_RELATIVE_MOUSE_ACTIVE_PROFILES+=(
        'example-extra-mouse|Example|Extra|0x1234|0x5678|0x0100|2|Example|Extra Mouse|none|identity_only_generic_report'
    )
    input_profile_validate_catalog >/dev/null 2>&1
); then
    fail 'catalog accepted more than three active relative mice'
fi
if (
    INPUT_ABSOLUTE_POINTER_ACTIVE_PROFILES=(
        'branded-tablet|Example|Branded Tablet|0x1234|0x5678|0x0100|2|Example|Branded Tablet|none|generic_virtual_only'
    )
    input_profile_validate_catalog >/dev/null 2>&1
); then
    fail 'catalog accepted a branded absolute-pointer override'
fi
if (
    INPUT_ABSOLUTE_POINTER_COMPAT_PROFILES[2]='legacy-veikk-a30-wrong-tuple|VEIKK|A30 altered tuple|0x2FEB|0x0002|0x0100|2|VEIKK|VEIKK A30|none|quarantined_wrong_tuple_never_active'
    input_profile_validate_catalog >/dev/null 2>&1
); then
    fail 'catalog accepted removal of the VEIKK wrong-tuple quarantine marker'
fi

echo 'PASS: input catalog is 3 active keyboard brands + 3 relative mouse brands + 1 generic absolute pointer; historical 5/5/4 rows stay quarantined and serial-free'
