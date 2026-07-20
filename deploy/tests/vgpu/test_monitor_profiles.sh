#!/usr/bin/env bash
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$HERE/../../.." && pwd)
source "$REPO_ROOT/deploy/lib/monitor-profiles.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() {
    local expected=$1 actual=$2 label=$3
    [[ $actual == "$expected" ]] || \
        fail "$label: expected '$expected', got '$actual'"
}

monitor_profiles_validate || fail "catalog validation"
# The printable-ASCII ranges must not inherit the caller's collation rules.
# These locales reproduced a false rejection of the first S24F350 row.
for test_locale in en_US.utf8 zh_CN.utf8; do
    if locale -a 2>/dev/null | grep -Fxiq "$test_locale"; then
        LC_ALL="$test_locale" monitor_profiles_validate || \
            fail "catalog validation under $test_locale"
    fi
done
mapfile -t keys < <(monitor_profile_keys)
((${#keys[@]} >= 20)) || fail "expected at least 20 real monitor profiles"

monitor_create_pool_validate || fail "mainland-China FHD creation pool validation"
mapfile -t pool_keys < <(monitor_create_pool_keys)
assert_eq 16 "${#pool_keys[@]}" "documented creation-profile count"
declare -A pool_brands=()
for key in "${pool_keys[@]}"; do
    monitor_profile_load "$key" || fail "cannot load creation profile $key"
    [[ $MONITOR_NATIVE_X == 1920 && $MONITOR_NATIVE_Y == 1080 ]] || \
        fail "$key is not a FHD/1K creation profile"
    [[ -n $MONITOR_BRAND_NAME && -n $MONITOR_MODEL_NAME ]] || \
        fail "$key has no explicit brand/model fields"
    pool_brands[$MONITOR_BRAND_NAME]=1
done
assert_eq 8 "${#pool_brands[@]}" "documented creation-brand count"
monitor_create_pool_contains redmi-rmmnt238nf || fail "Redmi FHD model missing from creation pool"
if monitor_create_pool_contains hkc-24e4; then
    fail "mismatched HKC/KOORUI 24E4 identity must not be in creation pool"
fi

QEMU_EDID=${QEMU_EDID:-$REPO_ROOT/build/qemu-edid}
[[ -x $QEMU_EDID ]] || fail "missing $QEMU_EDID"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

for key in "${keys[@]}"; do
    monitor_profile_load "$key" || fail "cannot load $key"
    serial1=$(monitor_profile_generate_serial "$MONITOR_SERIAL_PREFIX" test-vm)
    serial2=$(monitor_profile_generate_serial "$MONITOR_SERIAL_PREFIX" test-vm)
    [[ $serial1 == "$serial2" && $serial1 =~ ^[A-Z0-9]{1,12}$ ]] || \
        fail "$key unstable/invalid serial"

    QEMU_EDID=$QEMU_EDID "$REPO_ROOT/deploy/host/sync-monitor-cache.sh" \
        --monitor-profile "$key" --serial "$serial1" \
        --generate-only "$tmp/$key-vgpu.bin" >/dev/null
done

KEY_COUNT=${#keys[@]} OUT_DIR=$tmp python3 - <<'PY'
import os
from pathlib import Path

root = Path(os.environ['OUT_DIR'])
files = list(root.glob('*.bin'))
assert len(files) == int(os.environ['KEY_COUNT'])
expected_std = bytes.fromhex('d1c0b300a9c08180810081c001010101')
common_modes = {
    (1920, 1080), (1680, 1050), (1440, 900), (1360, 768),
    (1280, 1024), (1280, 960), (1280, 768), (1280, 720),
    (1024, 768), (800, 600), (640, 480),
}

def advertised_modes(edid):
    modes = set()
    if edid[35] & 0x20: modes.add((640, 480))
    if edid[35] & 0x01: modes.add((800, 600))
    if edid[36] & 0x08: modes.add((1024, 768))

    for offset in range(38, 54, 2):
        if edid[offset:offset + 2] == b'\x01\x01':
            continue
        x = (edid[offset] + 31) * 8
        aspect = edid[offset + 1] >> 6
        y = (x * 10 // 16, x * 3 // 4, x * 4 // 5, x * 9 // 16)[aspect]
        modes.add((x, y))

    dtd = edid[54:72]
    modes.add((dtd[2] | ((dtd[4] & 0xf0) << 4),
               dtd[5] | ((dtd[7] & 0xf0) << 4)))

    f7 = edid[72:90]
    assert f7[:4] == b'\x00\x00\x00\xf7' and f7[5] == 10
    assert f7[6:12] == bytes.fromhex('004aa0200000')
    modes.update({
        (1280, 1024), (1280, 960), (1280, 768),
        (1360, 768), (1440, 900), (1680, 1050),
    })

    assert edid[128:133] == bytes.fromhex('0203070042')
    vics = edid[133:128 + edid[130]]
    assert {vic & 0x7f for vic in vics} == {4, 16}, vics
    for vic in vics:
        if (vic & 0x7f) == 16: modes.add((1920, 1080))
        if (vic & 0x7f) == 4: modes.add((1280, 720))
    return modes

for path in files:
    edid = path.read_bytes()
    assert len(edid) == 256, (path, len(edid))
    assert all(sum(edid[i:i + 128]) % 256 == 0 for i in range(0, 256, 128))
    assert path.name.endswith('-vgpu.bin'), path
    assert edid[38:54] == expected_std, path
    assert advertised_modes(edid) == common_modes | {(1600, 900), (1280, 800)}, path
    assert (1920, 1200) not in advertised_modes(edid), path
PY

grep -q '^SKIP_MONITOR=1$' "$REPO_ROOT/deploy/setup-guest.sh" || \
    fail "setup-guest must keep online monitor rescue disabled by default"
[[ $(grep -c 'SKIP_MONITOR=0' "$REPO_ROOT/deploy/setup-guest.sh") == 1 ]] || \
    fail "only --online-monitor-rescue may enable guest monitor repair"
CREATE_VM="$REPO_ROOT/deploy/create-vm.sh"
IMAGE_ROOT="$tmp"
VM_ROOT="$tmp/create-vms"
export IMAGE_ROOT VM_ROOT
"$CREATE_VM" --list-monitor-profiles >"$tmp/create-list.out" || \
    fail "create-vm could not list the creation pool"
grep -Fq 'redmi-rmmnt238nf' "$tmp/create-list.out" || \
    fail "create-vm monitor list omitted an allowed Redmi profile"
if grep -Fq 'hkc-24e4' "$tmp/create-list.out"; then
    fail "create-vm monitor list exposed a profile outside the strict pool"
fi
env -u MONITOR_PROFILE "$CREATE_VM" 98101 \
    >"$tmp/create-default.out" 2>"$tmp/create-default.err" || \
    fail "create-vm default monitor selection failed"
conf="$VM_ROOT/vm98101/vm.conf"
[[ -f $conf ]] || fail "create-vm did not persist vm.conf"
[[ $(stat -c '%a' "$conf") == 444 ]] || fail "created vm.conf is not read-only"
(
    # shellcheck disable=SC1090
    source "$conf"
    actual_profile=$MONITOR_PROFILE
    actual_brand=$MONITOR_BRAND_NAME
    actual_model=$MONITOR_MODEL_NAME
    actual_display=$MONITOR_DISPLAY_NAME
    actual_native="${MONITOR_NATIVE_X}x${MONITOR_NATIVE_Y}"
    actual_serial=$MONITOR_SERIAL

    monitor_create_pool_contains "$actual_profile" || \
        fail "default create selected profile outside the creation pool: $actual_profile"
    monitor_profile_load "$actual_profile" || fail "cannot reload created profile"
    assert_eq "$MONITOR_BRAND_NAME" "$actual_brand" "created monitor brand"
    assert_eq "$MONITOR_MODEL_NAME" "$actual_model" "created monitor model"
    assert_eq "$MONITOR_DISPLAY_NAME" "$actual_display" "created display name"
    assert_eq 1920x1080 "$actual_native" "created monitor native resolution"
    [[ $actual_serial =~ ^[A-Z0-9]{1,12}$ ]] || fail "created monitor serial is invalid"
)

if env -u MONITOR_PROFILE "$CREATE_VM" 98102 --monitor-profile hkc-24e4 \
        >"$tmp/create-rejected.out" 2>"$tmp/create-rejected.err"; then
    fail "create-vm accepted a monitor outside the mainland-China FHD pool"
fi
[[ ! -e $VM_ROOT/vm98102/vm.conf ]] || \
    fail "rejected monitor profile still created vm.conf"
grep -Fq '不在中国大陆常见 FHD/1K 新建池中' "$tmp/create-rejected.err" || \
    fail "creation-pool rejection was not clear"

MONITOR_PROFILE=hkc-24e4 "$CREATE_VM" 98103 --monitor-profile redmi-rmmnt238nf \
    >"$tmp/create-explicit.out" 2>"$tmp/create-explicit.err" || \
    fail "allowed explicit monitor profile failed"
(
    # shellcheck disable=SC1090
    source "$VM_ROOT/vm98103/vm.conf"
    assert_eq redmi-rmmnt238nf "$MONITOR_PROFILE" "CLI monitor override"
    assert_eq Redmi "$MONITOR_BRAND_NAME" "explicit monitor brand"
    assert_eq RMMNT238NF "$MONITOR_MODEL_NAME" "explicit monitor model"
)

echo "OK: ${#keys[@]} catalog profiles, ${#pool_keys[@]} mainland-China FHD creation profiles; EDID/create flow validated"
