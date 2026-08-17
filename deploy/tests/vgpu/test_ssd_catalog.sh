#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=../../lib/hardware-profiles.sh
source "$repo_root/deploy/lib/hardware-profiles.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_eq() {
    local expected=$1 actual=$2 label=$3
    [[ "$actual" == "$expected" ]] || \
        fail "$label: expected '$expected', got '$actual'"
}

hardware_profile_validate_catalog || fail 'base hardware/SSD catalog validation'
assert_eq 512110190592 "$SSD_REQUIRED_SIZE_BYTES" 'fixed SSD byte contract'

mapfile -t profile_keys < <(ssd_profile_keys)
mapfile -t default_keys < <(ssd_default_profile_keys)
assert_eq 9 "${#profile_keys[@]}" 'active SSD profile count'
assert_eq 9 "${#default_keys[@]}" 'default SSD key count'
assert_eq "$(printf '%s\n' "${profile_keys[@]}" | LC_ALL=C sort)" \
    "$(printf '%s\n' "${default_keys[@]}" | LC_ALL=C sort)" \
    'active/default SSD key sets'

declare -A seen=()
sata_count=0
nvme_count=0
for key in "${profile_keys[@]}"; do
    [[ -z ${seen[$key]+x} ]] || fail "duplicate SSD key: $key"
    seen[$key]=1
    ssd_profile_load "$key" || fail "cannot load SSD profile $key"
    assert_eq "$SSD_REQUIRED_SIZE_BYTES" "$SSD_SIZE_BYTES" "$key exact capacity"
    [[ "$key" == *-512gb ]] || fail "$key does not carry the reviewed 512gb suffix"
    case "$SSD_INTERFACE" in
        sata) sata_count=$((sata_count + 1)) ;;
        nvme) nvme_count=$((nvme_count + 1)) ;;
        *) fail "$key has unsupported interface $SSD_INTERFACE" ;;
    esac
done
assert_eq 7 "$sata_count" 'SATA SSD count'
assert_eq 2 "$nvme_count" 'NVMe SSD count'

listed=0
while IFS=$'\t' read -r key _brand _interface size _rest; do
    [[ -n "$key" ]] || continue
    assert_eq "$SSD_REQUIRED_SIZE_BYTES" "$size" "$key listed capacity"
    listed=$((listed + 1))
done < <(ssd_profile_print_catalog)
assert_eq 9 "$listed" 'printed SSD catalog count'

# Fail closed if a future edit introduces a 500 GB/other-capacity row, even
# when it is also added to the default list.  Direct loads must reject it too.
bad_row='retired-500gb|Example|Example SSD 500GB|sata|500107862016|BAD1|ahci|2.5-inch|0|0|512|512'
if (
    SSD_PROFILES+=("$bad_row")
    SSD_DEFAULT_PROFILE_KEYS+=(retired-500gb)
    hardware_profile_validate_catalog >/dev/null 2>&1
); then
    fail 'catalog accepted a non-512110190592 SSD row/default key'
fi
if (
    SSD_PROFILES=("$bad_row")
    ssd_profile_load retired-500gb >/dev/null 2>&1
); then
    fail 'direct SSD load accepted a non-512110190592 profile'
fi

# Every active profile must be represented exactly once in the reviewed
# default-key set; omissions and duplicate defaults are both configuration
# errors rather than silent selection changes.
if (
    SSD_DEFAULT_PROFILE_KEYS=("${SSD_DEFAULT_PROFILE_KEYS[@]:0:8}")
    hardware_profile_validate_catalog >/dev/null 2>&1
); then
    fail 'catalog accepted an active SSD omitted from default keys'
fi
if (
    SSD_DEFAULT_PROFILE_KEYS+=("${SSD_DEFAULT_PROFILE_KEYS[0]}")
    hardware_profile_validate_catalog >/dev/null 2>&1
); then
    fail 'catalog accepted a duplicate default SSD key'
fi

echo 'PASS: all 9 active/default SSD profiles are exactly 512110190592 bytes (7 SATA, 2 NVMe)'
