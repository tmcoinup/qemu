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
mapfile -t explicit_keys < <(ssd_explicit_profile_keys)
assert_eq 10 "${#profile_keys[@]}" 'selectable SSD profile count'
assert_eq 7 "${#default_keys[@]}" 'H81-compatible default SSD key count'
assert_eq 3 "${#explicit_keys[@]}" 'explicit NVMe SSD key count'
assert_eq "$(printf '%s\n' "${profile_keys[@]}" | LC_ALL=C sort)" \
    "$(printf '%s\n' "${default_keys[@]}" "${explicit_keys[@]}" | LC_ALL=C sort)" \
    'selectable/default+explicit SSD key sets'
assert_eq wd-black-pcie-512gb "${explicit_keys[0]}" \
    'WD Black moved to explicit NVMe SSD profile'
assert_eq samsung-970-pro-512gb "${explicit_keys[1]}" \
    'Samsung 970 Pro moved to explicit NVMe SSD profile'
assert_eq samsung-960-pro-512gb "${explicit_keys[2]}" \
    'Samsung 960 Pro explicit NVMe SSD profile'

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
assert_eq 3 "$nvme_count" 'NVMe SSD count'

listed=0
listed_default=0
listed_explicit=0
while IFS=$'\t' read -r key _brand _interface size _firmware _controller \
        _form _gen _lanes _model _logical _physical auto_random; do
    [[ -n "$key" ]] || continue
    assert_eq "$SSD_REQUIRED_SIZE_BYTES" "$size" "$key listed capacity"
    case "$auto_random" in
        1) listed_default=$((listed_default + 1)) ;;
        0) listed_explicit=$((listed_explicit + 1)) ;;
        *) fail "$key has invalid AUTO_RANDOM=$auto_random" ;;
    esac
    listed=$((listed + 1))
done < <(ssd_profile_print_catalog)
assert_eq 10 "$listed" 'printed SSD catalog count'
assert_eq 7 "$listed_default" 'printed default SSD count'
assert_eq 3 "$listed_explicit" 'printed explicit SSD count'

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

# Every selectable profile must be represented exactly once in the reviewed
# default or explicit set; omissions, duplicates and cross-tier overlap are
# configuration errors rather than silent selection changes.
if (
    SSD_DEFAULT_PROFILE_KEYS=("${SSD_DEFAULT_PROFILE_KEYS[@]:0:6}")
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
if (
    SSD_EXPLICIT_PROFILE_KEYS+=("${SSD_DEFAULT_PROFILE_KEYS[0]}")
    hardware_profile_validate_catalog >/dev/null 2>&1
); then
    fail 'catalog accepted a default/explicit SSD overlap'
fi

echo 'PASS: 10 exact-size SSD profiles; 7 H81-safe defaults and 3 explicit NVMe rows'
