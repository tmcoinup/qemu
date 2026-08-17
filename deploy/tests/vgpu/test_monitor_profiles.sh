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

write_bad_preferred_catalog() {
    local output=$1 x=$2 y=$3 refresh=$4
    awk -F '|' -v OFS='|' -v x="$x" -v y="$y" -v refresh="$refresh" '
        !/^#/ && NF && !changed {
            $9 = x
            $10 = y
            $11 = refresh
            changed = 1
        }
        { print }
    ' "$MONITOR_PROFILE_CATALOG" >"$output"
}

write_bad_serial_prefix_catalog() {
    local output=$1 key=$2 prefix=$3
    awk -F '|' -v OFS='|' -v key="$key" -v prefix="$prefix" '
        !/^#/ && NF && $1 == key { $20 = prefix }
        { print }
    ' "$MONITOR_PROFILE_CATALOG" >"$output"
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
assert_eq 35 "${#keys[@]}" "documented monitor-catalog count"
assert_eq 35 "$(grep -c '^# source: ' "$MONITOR_PROFILE_CATALOG")" \
    "one reviewed source marker per full-catalog profile"
for key in "${keys[@]}"; do
    monitor_profile_load "$key" || fail "cannot load full-catalog profile $key"
    assert_eq 1920 "$MONITOR_NATIVE_X" "$key full-catalog preferred width"
    assert_eq 1080 "$MONITOR_NATIVE_Y" "$key full-catalog preferred height"
    assert_eq 60 "$MONITOR_REFRESH_HZ" "$key full-catalog preferred refresh"
    assert_eq fhd-standard "$MONITOR_MODE_SET" "$key full-catalog mode contract"
done

monitor_create_pool_validate || fail "mainland-China FHD creation pool validation"
mapfile -t pool_keys < <(monitor_create_pool_keys)
assert_eq 28 "${#pool_keys[@]}" "documented creation-profile count"
declare -A pool_brands=()
declare -A pool_size_classes=()
declare -A pool_range_classes=()
for key in "${pool_keys[@]}"; do
    monitor_profile_load "$key" || fail "cannot load creation profile $key"
    [[ $MONITOR_NATIVE_X == 1920 && $MONITOR_NATIVE_Y == 1080 ]] || \
        fail "$key is not a FHD/1K creation profile"
    # The current NVIDIA/Windows path has only validated a 60 Hz preferred
    # timing.  max_v=72/75/76 describes a real monitor range; it must not be
    # promoted into an unverified advertised mode.
    assert_eq 60 "$MONITOR_REFRESH_HZ" "$key preferred refresh"
    [[ -n $MONITOR_BRAND_NAME && -n $MONITOR_MODEL_NAME ]] || \
        fail "$key has no explicit brand/model fields"
    pool_brands[$MONITOR_BRAND_NAME]=1
    if ((MONITOR_WIDTH_MM < 500)); then
        pool_size_classes[21.5]=1
    elif ((MONITOR_WIDTH_MM < 570)); then
        pool_size_classes[23.8-24]=1
    else
        pool_size_classes[27]=1
    fi
    pool_range_classes[$MONITOR_MAX_V]=1
done
assert_eq 8 "${#pool_brands[@]}" "documented creation-brand count"
assert_eq 3 "${#pool_size_classes[@]}" "documented creation-size-class count"
(( ${#pool_range_classes[@]} >= 3 )) || \
    fail "expected distinct 72/75/76 Hz monitor range classes"
monitor_create_pool_contains redmi-rmmnt238nf || fail "Redmi FHD model missing from creation pool"
if monitor_create_pool_contains hkc-24e4; then
    fail "mismatched HKC/KOORUI 24E4 identity must not be in creation pool"
fi
for key in samsung-s22f350 samsung-s27f350 dell-p2219h dell-p2719h \
        benq-gw2280 benq-gw2780 philips-223v7 philips-273v7 \
        lenovo-d22-20 lenovo-d27-30 asus-va229 asus-va27ehe; do
    monitor_create_pool_contains "$key" || fail "expanded real-EDID profile missing: $key"
done

monitor_profile_load lenovo-d27-30 || fail "cannot load Lenovo D27-30"
assert_eq 597 "$MONITOR_WIDTH_MM" "Lenovo D27-30 DTD width"
assert_eq 336 "$MONITOR_HEIGHT_MM" "Lenovo D27-30 DTD height"
assert_eq 0x66B8 "$MONITOR_PRODUCT_ID" "Lenovo D27-30 PNP product"
monitor_profile_load samsung-s22f350 || fail "cannot load Samsung S22F350"
assert_eq 477 "$MONITOR_WIDTH_MM" "Samsung S22F350 DTD width"
assert_eq 268 "$MONITOR_HEIGHT_MM" "Samsung S22F350 DTD height"
assert_eq 0x0D1A "$MONITOR_PRODUCT_ID" "Samsung S22F350 PNP product"

# Serial identity is profile-policy based.  The two source-backed decimal
# formats have exact lengths, while every other row keeps the legacy stable
# 12-character prefix + hexadecimal hash behavior.
monitor_profile_load samsung-s24f350 || fail "cannot load Samsung S24F350"
assert_eq H4ZMC "$MONITOR_SERIAL_PREFIX" "Samsung S24F350 serial prefix"
assert_eq samsung-h4zmc-decimal5 "$MONITOR_SERIAL_POLICY" \
    "Samsung S24F350 serial policy"
samsung_serial=$(monitor_profile_generate_serial "$MONITOR_SERIAL_PREFIX" serial-policy-test)
assert_eq "$samsung_serial" \
    "$(monitor_profile_generate_serial "$MONITOR_SERIAL_PREFIX" serial-policy-test)" \
    "Samsung S24F350 stable serial"
[[ ${#samsung_serial} -eq 10 && $samsung_serial =~ ^H4ZMC[0-9]{5}$ ]] || \
    fail "Samsung S24F350 serial has the wrong format: $samsung_serial"
monitor_profile_serial_validate "$samsung_serial" || fail "Samsung serial validation"
for bad in H4ZMC1234 H4ZMC123456 H4ZMC12A45 H4ZMK12345 \
        H4ZMC01676 H4ZMC01889; do
    if monitor_profile_serial_validate "$bad"; then
        fail "Samsung S24F350 accepted invalid serial: $bad"
    fi
done

monitor_profile_load redmi-rmmnt238nf || fail "cannot load Redmi RMMNT238NF"
assert_eq 29200 "$MONITOR_SERIAL_PREFIX" "Redmi RMMNT238NF serial prefix"
assert_eq redmi-29200-decimal8 "$MONITOR_SERIAL_POLICY" \
    "Redmi RMMNT238NF serial policy"
redmi_serial=$(monitor_profile_generate_serial "$MONITOR_SERIAL_PREFIX" serial-policy-test)
assert_eq "$redmi_serial" \
    "$(monitor_profile_generate_serial "$MONITOR_SERIAL_PREFIX" serial-policy-test)" \
    "Redmi RMMNT238NF stable serial"
[[ ${#redmi_serial} -eq 13 && $redmi_serial =~ ^29200[0-9]{8}$ ]] || \
    fail "Redmi RMMNT238NF serial has the wrong format: $redmi_serial"
monitor_profile_serial_validate "$redmi_serial" || fail "Redmi serial validation"
for bad in 292001234567 29200123456789 29200123A5678 2921012345678 \
        2920000167575 2920000116680; do
    if monitor_profile_serial_validate "$bad"; then
        fail "Redmi RMMNT238NF accepted invalid serial: $bad"
    fi
done

monitor_profile_load dell-p2419h || fail "cannot load generic Dell profile"
assert_eq generic-prefix-hash "$MONITOR_SERIAL_POLICY" "generic serial policy"
generic_serial=$(monitor_profile_generate_serial "$MONITOR_SERIAL_PREFIX" serial-policy-test)
assert_eq "$generic_serial" \
    "$(monitor_profile_generate_serial "$MONITOR_SERIAL_PREFIX" serial-policy-test)" \
    "generic stable serial"
[[ ${#generic_serial} -eq 12 && ${generic_serial:0:${#MONITOR_SERIAL_PREFIX}} == "$MONITOR_SERIAL_PREFIX" ]] || \
    fail "generic serial has the wrong prefix/length: $generic_serial"
[[ ${generic_serial:${#MONITOR_SERIAL_PREFIX}} =~ ^[0-9A-F]+$ ]] || \
    fail "generic serial suffix is not an uppercase hexadecimal hash: $generic_serial"
monitor_profile_serial_validate "$generic_serial" || fail "generic serial validation"
for bad in CC3P1234567 CC3P123456789 CC3P12345G78 XX3P12345678; do
    if monitor_profile_serial_validate "$bad"; then
        fail "generic profile accepted invalid serial: $bad"
    fi
done

QEMU_EDID=${QEMU_EDID:-$REPO_ROOT/build/qemu-edid}
[[ -x $QEMU_EDID ]] || fail "missing $QEMU_EDID"
tmp=$(mktemp -d)
negative_instance="monitor-contract-test-$$"
cleanup() {
    rm -rf -- "$tmp"
    rm -f -- "/tmp/vgpu-edid-${negative_instance}.bin"
}
trap cleanup EXIT

# Force the deterministic hash material to land exactly on an observed
# evidence-sample serial.  Generation must advance to a synthetic value while
# remaining deterministic; a format-only validator would miss this case.
fake_hash_bin="$tmp/fake-hash-bin"
mkdir -p "$fake_hash_bin"
cat >"$fake_hash_bin/sha256sum" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
IFS= read -r _input || true
: "${MONITOR_TEST_HASH_VALUE:?}"
printf '%015X%049d  -\n' "$MONITOR_TEST_HASH_VALUE" 0
EOF
chmod +x "$fake_hash_bin/sha256sum"

monitor_profile_load samsung-s24f350
samsung_collision=$(PATH="$fake_hash_bin:$PATH" MONITOR_TEST_HASH_VALUE=1676 \
    monitor_profile_generate_serial "$MONITOR_SERIAL_PREFIX" reserved-collision)
assert_eq H4ZMC01677 "$samsung_collision" \
    "Samsung generator skips reserved evidence serial"
monitor_profile_serial_validate "$samsung_collision" || \
    fail "Samsung collision replacement did not validate"

monitor_profile_load redmi-rmmnt238nf
redmi_collision=$(PATH="$fake_hash_bin:$PATH" MONITOR_TEST_HASH_VALUE=167575 \
    monitor_profile_generate_serial "$MONITOR_SERIAL_PREFIX" reserved-collision)
assert_eq 2920000167576 "$redmi_collision" \
    "Redmi generator skips reserved evidence serial"
monitor_profile_serial_validate "$redmi_collision" || \
    fail "Redmi collision replacement did not validate"

# Explicit external inputs must fail closed on the host instead of being
# silently replaced, otherwise a copied evidence serial could enter vm.conf
# and differ from the EDID that the helper happened to regenerate.
for reserved_case in \
        'samsung-s24f350 H4ZMC01676' \
        'samsung-s24f350 H4ZMC01889' \
        'redmi-rmmnt238nf 2920000167575' \
        'redmi-rmmnt238nf 2920000116680'; do
    read -r reserved_profile reserved_serial <<<"$reserved_case"
    reserved_output="$tmp/rejected-reserved-${reserved_serial}.bin"
    if QEMU_EDID="$QEMU_EDID" "$REPO_ROOT/deploy/host/sync-monitor-cache.sh" \
            --monitor-profile "$reserved_profile" --serial "$reserved_serial" \
            --instance "reserved-contract-test-$$" \
            --generate-only "$reserved_output" \
            >"$tmp/reserved-${reserved_serial}.out" \
            2>"$tmp/reserved-${reserved_serial}.err"; then
        fail "host monitor sync accepted reserved serial: $reserved_serial"
    fi
    grep -Fq '命中证据样本保留值' "$tmp/reserved-${reserved_serial}.err" || \
        fail "host rejection did not identify reserved serial: $reserved_serial"
    [[ ! -e $reserved_output ]] || \
        fail "host wrote EDID after rejecting reserved serial: $reserved_serial"
done

# The full compatibility catalog and the new-VM pool must both fail closed if
# even one preferred timing is changed to a common laptop HD mode, QHD, or an
# unreviewed 75 Hz timing.  This is deliberately stronger than checking only
# the 28-key creation pool.
for mutation in '1366 768 60' '2560 1440 60' '1920 1080 75'; do
    read -r bad_x bad_y bad_refresh <<<"$mutation"
    bad_catalog="$tmp/bad-${bad_x}x${bad_y}-${bad_refresh}.tsv"
    write_bad_preferred_catalog "$bad_catalog" "$bad_x" "$bad_y" "$bad_refresh"
    if monitor_profiles_validate "$bad_catalog" 2>"$bad_catalog.err"; then
        fail "full catalog accepted preferred timing ${bad_x}x${bad_y}@${bad_refresh}"
    fi
    grep -Fq 'every full-catalog preferred timing must be 1920x1080@60' \
        "$bad_catalog.err" || fail "full-catalog rejection was not explicit"
    if monitor_create_pool_validate "$MONITOR_CREATE_PROFILE_POOL" \
            "$bad_catalog" >/dev/null 2>&1; then
        fail "creation pool accepted bad full catalog ${bad_x}x${bad_y}@${bad_refresh}"
    fi
done

for mutation in \
        'samsung-s24f350 H4ZK' \
        'redmi-rmmnt238nf 2920' \
        'dell-p2419h H4ZMC'; do
    read -r bad_key bad_prefix <<<"$mutation"
    bad_catalog="$tmp/bad-serial-${bad_key}.tsv"
    write_bad_serial_prefix_catalog "$bad_catalog" "$bad_key" "$bad_prefix"
    if monitor_profiles_validate "$bad_catalog" >/dev/null 2>&1; then
        fail "catalog accepted serial prefix $bad_prefix for $bad_key"
    fi
done

for key in "${keys[@]}"; do
    monitor_profile_load "$key" || fail "cannot load $key"
    serial1=$(monitor_profile_generate_serial "$MONITOR_SERIAL_PREFIX" test-vm)
    serial2=$(monitor_profile_generate_serial "$MONITOR_SERIAL_PREFIX" test-vm)
    [[ $serial1 == "$serial2" ]] && monitor_profile_serial_validate "$serial1" || \
        fail "$key unstable/invalid serial"

    QEMU_EDID=$QEMU_EDID "$REPO_ROOT/deploy/host/sync-monitor-cache.sh" \
        --monitor-profile "$key" --serial "$serial1" \
        --generate-only "$tmp/$key-vgpu.bin" >/dev/null
done

KEY_COUNT=${#keys[@]} OUT_DIR=$tmp python3 - <<'PY'
import os
import re
from pathlib import Path

root = Path(os.environ['OUT_DIR'])
files = list(root.glob('*.bin'))
assert len(files) == int(os.environ['KEY_COUNT'])
expected_std = bytes.fromhex('d1c0a9c0818081c00101010101010101')
expected_modes = {
    (1920, 1080), (1600, 900), (1360, 768),
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
    preferred = (dtd[2] | ((dtd[4] & 0xf0) << 4),
                 dtd[5] | ((dtd[7] & 0xf0) << 4))
    assert edid[24] & 0x02, (path, 'preferred-timing feature bit is clear')
    assert preferred == (1920, 1080), (path, preferred)
    modes.add(preferred)

    # A range descriptor that reaches 75/76 Hz is not itself a 75 Hz mode.
    # Keep the generated preferred DTD at the sample-backed 1080p60 timing.
    pixel_clock_hz = int.from_bytes(dtd[0:2], 'little') * 10_000
    h_active = dtd[2] | ((dtd[4] & 0xf0) << 4)
    h_blank = dtd[3] | ((dtd[4] & 0x0f) << 8)
    v_active = dtd[5] | ((dtd[7] & 0xf0) << 4)
    v_blank = dtd[6] | ((dtd[7] & 0x0f) << 8)
    dtd_refresh = pixel_clock_hz / ((h_active + h_blank) * (v_active + v_blank))
    assert abs(dtd_refresh - 60.0) < 0.01, (path, dtd_refresh)

    xtra3 = edid[72:90]
    assert xtra3 == (bytes.fromhex('000000f7000a004a80') + b'\x00' * 9), path
    modes.update({(1360, 768), (1280, 1024), (1280, 960), (1280, 768)})

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
    assert edid[135:140] == bytes.fromhex('000000ff00'), path
    serial_text = edid[140:153]
    key = path.name[:-len('-vgpu.bin')]
    if key == 'samsung-s24f350':
        assert re.fullmatch(rb'H4ZMC[0-9]{5}\n  ', serial_text), (path, serial_text)
    elif key == 'redmi-rmmnt238nf':
        # An exact 13-byte EDID descriptor has no newline terminator.  This is
        # the regression guard against qemu-edid silently dropping digit 8.
        assert re.fullmatch(rb'29200[0-9]{8}', serial_text), (path, serial_text)
    else:
        assert re.fullmatch(rb'[A-Z0-9]{12}\n', serial_text), (path, serial_text)
    modes = advertised_modes(edid)
    assert modes == expected_modes, (path, modes)
    assert not any(x * 10 == y * 16 for x, y in modes), (path, modes)
PY

# Exercise the host fail-closed gate with structurally valid checksums but an
# extra CTA VIC, a CTA DTD, or an extra Established Timing bit.  Run with
# Python optimization enabled so the test also proves validation does not rely
# on removable assert statements.
cat >"$tmp/fake-qemu-edid" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=""
while (( $# > 0 )); do
    case "$1" in
        -o) out=$2; shift 2 ;;
        *) shift ;;
    esac
done
[[ -n $out && -n ${GOOD_EDID:-} && -n ${EDID_MUTATION:-} ]]
python3 - "$GOOD_EDID" "$out" "$EDID_MUTATION" <<'PY'
import sys
from pathlib import Path

source, output, mutation = sys.argv[1:]
e = bytearray(Path(source).read_bytes())
# The saved good blob is post-sync; reconstruct qemu-edid's intentionally
# empty source standard-timing slots before applying each malformed mutation.
e[38:54] = b'\x01\x01' * 8
if mutation == 'extra-cta-vic':
    e[130] = 8
    e[132:136] = bytes((0x43, 16, 4, 5))
elif mutation == 'cta-dtd':
    e[135:153] = e[54:72]
elif mutation == 'extra-established':
    e[35] |= 0x02
elif mutation == 'xtra3-16-10':
    e[81] |= 0x20
elif mutation == 'standard-16-10':
    e[38:40] = bytes((0xb3, 0x00))  # 1680x1050
elif mutation == 'base-dtd-16-10':
    e[56] = 0x00
    e[58] = (e[58] & 0x0f) | 0x50  # 1280 active pixels
    e[59] = 0x20
    e[61] = (e[61] & 0x0f) | 0x30  # 800 active lines
elif mutation == 'cta-flags':
    e[131] = 1
elif mutation != 'none':
    raise SystemExit(f'unknown mutation: {mutation}')
e[127] = (-sum(e[:127])) & 0xff
e[255] = (-sum(e[128:255])) & 0xff
Path(output).write_bytes(e)
PY
EOF
chmod +x "$tmp/fake-qemu-edid"

good_edid="$tmp/dell-p2419h-vgpu.bin"
for mutation in extra-cta-vic cta-dtd extra-established xtra3-16-10 \
        standard-16-10 base-dtd-16-10 cta-flags; do
    rejected_output="$tmp/rejected-${mutation}.bin"
    if env PYTHONOPTIMIZE=1 GOOD_EDID="$good_edid" EDID_MUTATION="$mutation" \
            QEMU_EDID="$tmp/fake-qemu-edid" \
            "$REPO_ROOT/deploy/host/sync-monitor-cache.sh" \
            --monitor-profile dell-p2419h --serial CC3P12345678 \
            --instance "$negative_instance" --generate-only "$rejected_output" \
            >"$tmp/$mutation.out" 2>"$tmp/$mutation.err"; then
        fail "host EDID gate accepted $mutation under PYTHONOPTIMIZE=1"
    fi
    grep -Fq 'FHD EDID contract violation:' "$tmp/$mutation.err" || \
        fail "host EDID gate did not explain rejection of $mutation"
    [[ ! -e $rejected_output ]] || \
        fail "host EDID gate wrote output after rejecting $mutation"
done

env PYTHONOPTIMIZE=1 GOOD_EDID="$good_edid" EDID_MUTATION=none \
    QEMU_EDID="$tmp/fake-qemu-edid" \
    "$REPO_ROOT/deploy/host/sync-monitor-cache.sh" \
    --monitor-profile dell-p2419h --serial CC3P12345678 \
    --instance "$negative_instance" \
    --generate-only "$tmp/optimized-valid.bin" >/dev/null

GUEST_MONITOR="$REPO_ROOT/deploy/guest/spoof-monitor.ps1"
GUEST_APPLY="$REPO_ROOT/deploy/guest/apply-vm-profile.ps1"
for reserved_serial in H4ZMC01676 H4ZMC01889 2920000167575 2920000116680; do
    grep -Fq "$reserved_serial" "$GUEST_MONITOR" || \
        fail "online monitor helper omits reserved serial $reserved_serial"
    grep -Fq "$reserved_serial" "$GUEST_APPLY" || \
        fail "guest profile validator omits reserved serial $reserved_serial"
done
grep -Fq '[pscustomobject]@{ X = 1600; Aspect = 3 }, # 1600x900' \
    "$GUEST_MONITOR" || fail "online monitor rescue omits 1600x900"
if grep -Eq 'X = (1680|1440).*16:10|X = 1280; Aspect = 0' "$GUEST_MONITOR"; then
    fail "online monitor rescue publishes a 16:10 standard timing"
fi
grep -Fq '$edid = New-Object byte[] 256' "$GUEST_MONITOR" || \
    fail "online monitor rescue does not build a 256-byte EDID"
for required_override_text in \
        'function Set-EdidOverride' \
        "Join-Path \$ParametersPath 'EDID_OVERRIDE'" \
        '/t REG_BINARY' \
        '($Edid.Length / 128)' \
        'Set-EdidOverride -ParametersPath' \
        "([string](Join-Path \$instance.PSPath 'Device Parameters'))"; do
    grep -Fq -- "$required_override_text" "$GUEST_MONITOR" || \
        fail "online monitor rescue omits standard block EDID override: $required_override_text"
done
# Windows PowerShell 5.1 can collapse a REG_MULTI_SZ returned by
# Get-ItemPropertyValue into one concatenated string.  The reviewed two-part
# GRID source value must retain its element boundaries or the fail-closed
# comparison rejects an otherwise exact production value.
grep -Fq "\$registryKey.GetValue(" "$GUEST_MONITOR" || \
    fail "online monitor rescue does not use raw RegistryKey NV_Modes reads"
grep -Fq '[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames' \
    "$GUEST_MONITOR" || \
    fail "online monitor rescue does not preserve raw NV_Modes strings"
if grep -Fq "Get-ItemPropertyValue -LiteralPath \$target -Name 'NV_Modes'" \
        "$GUEST_MONITOR"; then
    fail "online monitor rescue uses the PowerShell 5.1-unsafe NV_Modes reader"
fi
HOST_MONITOR="$REPO_ROOT/deploy/host/sync-monitor-cache.sh"
for required_override_text in \
        "child(dp, 'EDID_OVERRIDE')" \
        "h.node_add_child(dp, 'EDID_OVERRIDE')" \
        "'key': str(block_number), 't': 3, 'value': block" \
        "current_stats['override'] != current_stats['edid']"; do
    grep -Fq -- "$required_override_text" "$HOST_MONITOR" || \
        fail "offline monitor sync omits standard block EDID override: $required_override_text"
done
grep -Fq '0x02, 0x03, 0x07, 0x00, 0x42, 0x10, 0x04' "$GUEST_MONITOR" || \
    fail "online monitor rescue CTA does not contain exact VIC 16/VIC 4 list"

if command -v pwsh >/dev/null 2>&1; then
    ps_edid="$tmp/powershell-vgpu.bin"
    pwsh -NoProfile -File "$GUEST_MONITOR" -Profile dell-p2419h \
        -Serial CC3P12345678 -BuildOnly "$ps_edid" >/dev/null
    PS_EDID="$ps_edid" python3 - <<'PY'
import os
from pathlib import Path

e = Path(os.environ['PS_EDID']).read_bytes()
assert len(e) == 256
assert [sum(e[i:i + 128]) & 0xff for i in (0, 128)] == [0, 0]
assert e[35:38] == bytes.fromhex('210800')
assert e[38:54] == bytes.fromhex('d1c0a9c0818081c00101010101010101')
assert e[72:90] == bytes.fromhex('000000f7000a004a80000000000000000000')
assert e[128:135] == bytes.fromhex('02030700421004')
assert e[135:139] == bytes.fromhex('000000ff')
assert not any(e[153:255])
dtd = e[54:72]
assert (dtd[2] | ((dtd[4] & 0xf0) << 4),
        dtd[5] | ((dtd[7] & 0xf0) << 4)) == (1920, 1080)
PY

    ps_redmi_edid="$tmp/powershell-redmi-vgpu.bin"
    ps_redmi_repeat="$tmp/powershell-redmi-repeat-vgpu.bin"
    pwsh -NoProfile -File "$GUEST_MONITOR" -Profile redmi-rmmnt238nf \
        -BuildOnly "$ps_redmi_edid" >/dev/null
    pwsh -NoProfile -File "$GUEST_MONITOR" -Profile redmi-rmmnt238nf \
        -BuildOnly "$ps_redmi_repeat" >/dev/null
    cmp -s "$ps_redmi_edid" "$ps_redmi_repeat" || \
        fail "PowerShell Redmi default serial is not stable"
    PS_EDID="$ps_redmi_edid" python3 - <<'PY'
import os
import re
from pathlib import Path

e = Path(os.environ['PS_EDID']).read_bytes()
assert re.fullmatch(rb'29200[0-9]{8}', e[140:153]), e[140:153]
PY
    if pwsh -NoProfile -File "$GUEST_MONITOR" -Profile redmi-rmmnt238nf \
            -Serial 292001234567 -BuildOnly "$tmp/powershell-bad-redmi.bin" \
            >/dev/null 2>&1; then
        fail "PowerShell monitor helper accepted a 12-character Redmi serial"
    fi
    for reserved_case in \
            'samsung-s24f350 H4ZMC01676' \
            'samsung-s24f350 H4ZMC01889' \
            'redmi-rmmnt238nf 2920000167575' \
            'redmi-rmmnt238nf 2920000116680'; do
        read -r reserved_profile reserved_serial <<<"$reserved_case"
        if pwsh -NoProfile -File "$GUEST_MONITOR" \
                -Profile "$reserved_profile" -Serial "$reserved_serial" \
                -BuildOnly "$tmp/powershell-reserved-${reserved_serial}.bin" \
                >/dev/null 2>&1; then
            fail "PowerShell monitor helper accepted reserved serial: $reserved_serial"
        fi
    done
fi

grep -q '^SKIP_MONITOR=1$' "$REPO_ROOT/deploy/setup-guest.sh" || \
    fail "setup-guest must keep online monitor rescue disabled by default"
[[ $(grep -c 'SKIP_MONITOR=0' "$REPO_ROOT/deploy/setup-guest.sh") == 1 ]] || \
    fail "only --online-monitor-rescue may enable guest monitor repair"
CREATE_VM="$REPO_ROOT/deploy/scripts/create-vm.sh"
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
conf="$VM_ROOT/98101/vm.conf"
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
    monitor_profile_serial_validate "$actual_serial" || \
        fail "created monitor serial is invalid for $actual_profile"
)

if env -u MONITOR_PROFILE "$CREATE_VM" 98102 --monitor-profile hkc-24e4 \
        >"$tmp/create-rejected.out" 2>"$tmp/create-rejected.err"; then
    fail "create-vm accepted a monitor outside the mainland-China FHD pool"
fi
[[ ! -e $VM_ROOT/98102/vm.conf ]] || \
    fail "rejected monitor profile still created vm.conf"
grep -Fq '不在中国大陆常见 FHD/1K 新建池中' "$tmp/create-rejected.err" || \
    fail "creation-pool rejection was not clear"

MONITOR_PROFILE=hkc-24e4 "$CREATE_VM" 98103 --monitor-profile redmi-rmmnt238nf \
    >"$tmp/create-explicit.out" 2>"$tmp/create-explicit.err" || \
    fail "allowed explicit monitor profile failed"
(
    # shellcheck disable=SC1090
    source "$VM_ROOT/98103/vm.conf"
    assert_eq redmi-rmmnt238nf "$MONITOR_PROFILE" "CLI monitor override"
    assert_eq Redmi "$MONITOR_BRAND_NAME" "explicit monitor brand"
    assert_eq RMMNT238NF "$MONITOR_MODEL_NAME" "explicit monitor model"
    [[ ${#MONITOR_SERIAL} -eq 13 && $MONITOR_SERIAL =~ ^29200[0-9]{8}$ ]] || \
        fail "explicit Redmi profile did not persist its exact serial format"
)

echo "OK: ${#keys[@]} catalog profiles, ${#pool_keys[@]} mainland-China FHD creation profiles across 3 size classes; EDID/create flow validated"
