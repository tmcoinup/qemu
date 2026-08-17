#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
IDENTITY_LIB="$REPO_ROOT/deploy/lib/identity-uniqueness.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_eq() {
    local expected=$1 actual=$2 label=$3
    [[ "$actual" == "$expected" ]] ||
        fail "$label: expected '$expected', got '$actual'"
}

assert_rc() {
    local expected=$1 label=$2
    shift 2
    local actual

    if "$@"; then
        actual=0
    else
        actual=$?
    fi
    assert_eq "$expected" "$actual" "$label return code"
}

[[ -r "$IDENTITY_LIB" ]] || fail 'identity uniqueness library is missing'
source_output=$(bash -c 'source "$1"' _ "$IDENTITY_LIB") ||
    fail 'identity uniqueness library cannot be sourced in a clean shell'
assert_eq '' "$source_output" 'source-time output'

# shellcheck source=../../lib/identity-uniqueness.sh
source "$IDENTITY_LIB"

TEST_ROOT=$(mktemp -d)
case "$TEST_ROOT" in
    /tmp/*) ;;
    *) fail "mktemp returned an unsafe path: $TEST_ROOT" ;;
esac
cleanup() {
    rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

VM_ROOT="$TEST_ROOT/fleet"
mkdir -p "$VM_ROOT/1" "$VM_ROOT/2" "$VM_ROOT/3" "$VM_ROOT/4" \
    "$VM_ROOT/5"
marker="$TEST_ROOT/config-was-executed"
vm2_slot2=$(g11_hardware_serial_memory_for_slot 1234ABCD 2)
vm3_base=0BADCAFE
vm3_list=$(g11_hardware_serial_memory_list_generate "$vm3_base" 2)
vm3_slot2=${vm3_list#*,}
vm4_legacy_base=$(g11_hardware_serial_memory_stable_from_seed \
    BIK6QG9Q5A9L)
vm4_slot2=$(g11_hardware_serial_memory_for_slot "$vm4_legacy_base" 2)
vm5_slot2=$(g11_hardware_serial_memory_for_slot FACEB00C 2)

cat >"$VM_ROOT/1/vm.conf" <<EOF
# A quoted shell-looking value is data, never code.
VM_ID=1
VM_UUID=11111111-2222-3333-4444-555555555555
VM_MAC=00:1B:21:AA:BB:CC
SYS_SN="SYS-A0001"
MB_SN="BOARD-B0002"
CHASSIS_SN="CASE-C0003"
MEM_SN="ABCDEF12"
SSD_SN="SSD-ONE-0001"
MONITOR_SERIAL="MONITOR00001"
PAYLOAD="\$(touch $marker)"
EOF

cat >"$VM_ROOT/2/vm.conf" <<'EOF'
VM_ID=2
VM_UUID="AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
VM_MAC="00:24:D7:11:22:33"
SYS_SN="SYS-D0004"
MB_SN="BOARD-E0005"
CHASSIS_SN="CASE-F0006"
MEM_SN=1234ABCD
MEM_SLOTS=2
SSD_SN=SSD-TWO-0002
MONITOR_SERIAL=MONITOR00002
EOF

cat >"$VM_ROOT/3/vm.conf" <<EOF
VM_ID=3
MEM_SN=$vm3_base
MEM_SLOTS=2
MEM_SERIAL_LIST="$vm3_list"
EOF

# Historical v1/v2 configurations may carry a non-JEDEC MEM_SN.  start-vm
# normalizes that stable seed before deriving its final per-slot identities;
# the read-only collision scanner must see the exact same two values.
cat >"$VM_ROOT/4/vm.conf" <<'EOF'
VM_ID=4
MEM_SN=BIK6QG9Q5A9L
MEM_SLOTS=2
EOF

cat >"$VM_ROOT/5/vm.conf" <<'EOF'
VM_ID=5
MEM_SN=faceb00c
MEM_SLOTS=2
EOF

assert_rc 0 'unused UUID' g11_identity_candidate_is_unique \
    VM_UUID 99999999-8888-7777-6666-555555555555 '' "$VM_ROOT"
assert_eq unique "$G11_IDENTITY_UNIQUENESS_RESULT" 'unused result'
[[ ! -e $marker ]] || fail 'vm.conf command substitution was executed'

assert_conflict() {
    local candidate_field=$1 value=$2 expected_vm=$3 expected_field=$4 label=$5
    local expected_candidate_field=${6:-$candidate_field}

    assert_rc 1 "$label" g11_identity_candidate_is_unique \
        "$candidate_field" "$value" '' "$VM_ROOT"
    assert_eq conflict "$G11_IDENTITY_UNIQUENESS_RESULT" "$label result"
    assert_eq "$expected_vm" "$G11_IDENTITY_CONFLICT_VM_ID" "$label VM"
    assert_eq "$expected_candidate_field" \
        "$G11_IDENTITY_CONFLICT_CANDIDATE_FIELD" "$label candidate field"
    assert_eq "$expected_field" \
        "$G11_IDENTITY_CONFLICT_EXISTING_FIELD" "$label existing field"
    assert_eq "$VM_ROOT/$expected_vm/vm.conf" \
        "$G11_IDENTITY_CONFLICT_CONFIG" "$label config"
}

# UUID and MAC are case-insensitive; every other direct identity has its own
# namespace.  System/baseboard/chassis share one serial namespace.
assert_conflict VM_UUID aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee \
    2 VM_UUID 'case-insensitive UUID collision'
assert_conflict VM_MAC 00:1b:21:aa:bb:cc \
    1 VM_MAC 'case-insensitive MAC collision'
assert_conflict MEM_SN ABCDEF12 1 MEM_SN 'memory serial collision'
assert_conflict MEM_SN "$vm2_slot2" 2 'MEM_SN[2]' \
    'slot1 candidate versus old derived slot2'
assert_conflict MEM_SN "$vm3_slot2" 3 'MEM_SERIAL_LIST[2]' \
    'MEM_SN candidate versus persisted list slot2'
assert_conflict MEM_SN "$vm4_slot2" 4 'MEM_SN[2]' \
    'candidate versus normalized legacy slot2'
assert_conflict MEM_SN "$vm5_slot2" 5 'MEM_SN[2]' \
    'candidate versus uppercase-canonicalized legacy slot2'
assert_conflict MEM_SERIAL_LIST "DEADBEEF,$vm2_slot2" 2 'MEM_SN[2]' \
    'candidate list slot2 versus old derived slot2' 'MEM_SERIAL_LIST[2]'
assert_conflict SSD_SN SSD-TWO-0002 2 SSD_SN 'SSD serial collision'
assert_conflict MONITOR_SERIAL MONITOR00001 \
    1 MONITOR_SERIAL 'monitor serial collision'
assert_conflict SYS_SN BOARD-B0002 1 MB_SN 'system candidate versus board serial'
assert_conflict MB_SN CASE-C0003 1 CHASSIS_SN 'board candidate versus chassis serial'
assert_conflict CHASSIS_SN SYS-D0004 2 SYS_SN 'chassis candidate versus system serial'

# Serial namespaces other than SYS/MB/CHASSIS are intentionally independent.
assert_rc 0 'SSD value may equal a system serial' \
    g11_identity_candidate_is_unique SSD_SN SYS-A0001 '' "$VM_ROOT"

# --force skips the current numeric bundle before opening it.
assert_rc 0 'ignore current VM UUID' g11_identity_uniqueness_check \
    VM_UUID 11111111-2222-3333-4444-555555555555 1 "$VM_ROOT"
assert_rc 1 'ignore only current VM' g11_identity_uniqueness_check \
    VM_UUID AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE 1 "$VM_ROOT"

# The batch API expands every candidate DIMM into the shared MEMORY_SERIAL
# namespace while scanning all other identities in one pass.
unused_memory_list=$(g11_hardware_serial_memory_list_generate 89ABCDEF 2)
assert_rc 0 'unused candidate batch' g11_identity_candidates_are_unique \
    '' "$VM_ROOT" \
    VM_UUID 01234567-89AB-CDEF-0123-456789ABCDEF \
    VM_MAC 00:23:14:44:55:66 \
    SYS_SN SYS-G0007 \
    MB_SN BOARD-H0008 \
    CHASSIS_SN CASE-I0009 \
    MEM_SERIAL_LIST "$unused_memory_list" \
    SSD_SN SSD-THREE-0003 \
    MONITOR_SERIAL MONITOR00003
assert_rc 1 'candidate batch shared serial collision' \
    g11_identity_candidates_are_unique '' "$VM_ROOT" \
    SYS_SN SAME-SERIAL MB_SN SAME-SERIAL
assert_eq '' "$G11_IDENTITY_CONFLICT_CONFIG" \
    'in-batch conflict has no existing config'
assert_rc 1 'candidate memory list conflicts inside MEMORY_SERIAL namespace' \
    g11_identity_candidates_are_unique '' "$VM_ROOT" \
    MEM_SN DEADBEEF MEM_SERIAL_LIST "CAFEBABE,DEADBEEF"
assert_eq '' "$G11_IDENTITY_CONFLICT_CONFIG" \
    'in-batch memory conflict has no existing config'

# Bad API inputs are distinguished from an ordinary collision.
assert_rc 2 'unsupported candidate field' g11_identity_candidate_is_unique \
    ODD_SERIAL VALUE '' "$VM_ROOT"
assert_rc 2 'empty candidate value' g11_identity_candidate_is_unique \
    SSD_SN '' '' "$VM_ROOT"
assert_rc 2 'invalid ignore VM id' g11_identity_candidate_is_unique \
    SSD_SN VALUE ../1 "$VM_ROOT"
assert_rc 2 'relative root' g11_identity_candidate_is_unique \
    SSD_SN VALUE '' relative/root
assert_rc 2 'missing root' g11_identity_candidate_is_unique \
    SSD_SN VALUE '' "$TEST_ROOT/missing"
assert_rc 2 'odd batch argument count' g11_identity_candidates_are_unique \
    '' "$VM_ROOT" VM_UUID
assert_rc 2 'duplicate batch key' g11_identity_candidates_are_unique \
    '' "$VM_ROOT" VM_UUID ONE VM_UUID TWO
assert_rc 2 'duplicate DIMM member in candidate list' \
    g11_identity_candidate_is_unique \
    MEM_SERIAL_LIST DEADBEEF,DEADBEEF '' "$VM_ROOT"

oversized_slots_root="$TEST_ROOT/oversized-memory-slots"
mkdir -p "$oversized_slots_root/1"
printf '%s\n' 'VM_ID=1' 'MEM_SN=ABCDEF12' 'MEM_SLOTS=65' \
    >"$oversized_slots_root/1/vm.conf"
assert_rc 2 'oversized legacy MEM_SLOTS fails closed' \
    g11_identity_candidate_is_unique \
    MEM_SN DEADBEEF '' "$oversized_slots_root"

make_case() {
    local name=$1
    CASE_ROOT="$TEST_ROOT/$name"
    mkdir -p "$CASE_ROOT/1"
}

assert_malformed_root() {
    local label=$1 root=$2

    assert_rc 2 "$label" g11_identity_candidate_is_unique \
        VM_UUID FFFFFFFF-EEEE-DDDD-CCCC-BBBBBBBBBBBB '' "$root"
    assert_eq invalid "$G11_IDENTITY_UNIQUENESS_RESULT" "$label result"
}

make_case malformed-export
printf '%s\n' 'export VM_UUID=BAD' >"$CASE_ROOT/1/vm.conf"
assert_malformed_root 'export assignment rejected' "$CASE_ROOT"

make_case malformed-quote
printf '%s\n' 'VM_UUID="unterminated' >"$CASE_ROOT/1/vm.conf"
assert_malformed_root 'unterminated quote rejected' "$CASE_ROOT"

make_case malformed-inline-comment
printf '%s\n' 'VM_UUID=value # comment' >"$CASE_ROOT/1/vm.conf"
assert_malformed_root 'inline comment rejected' "$CASE_ROOT"

make_case malformed-duplicate
printf '%s\n' 'VM_ID=1' 'VM_UUID=ONE' 'VM_UUID=TWO' \
    >"$CASE_ROOT/1/vm.conf"
assert_malformed_root 'duplicate key rejected' "$CASE_ROOT"

make_case malformed-id-mismatch
printf '%s\n' 'VM_ID=2' 'VM_UUID=VALUE' >"$CASE_ROOT/1/vm.conf"
assert_malformed_root 'directory and VM_ID mismatch rejected' "$CASE_ROOT"

make_case malformed-memory-list
printf '%s\n' \
    'VM_ID=1' \
    'MEM_SN=ABCDEF12' \
    'MEM_SLOTS=2' \
    'MEM_SERIAL_LIST="ABCDEF12,DEADBEEF"' \
    >"$CASE_ROOT/1/vm.conf"
assert_malformed_root 'MEM_SERIAL_LIST derivation mismatch rejected' "$CASE_ROOT"

make_case malformed-cr
printf 'VM_ID=1\r\n' >"$CASE_ROOT/1/vm.conf"
assert_malformed_root 'CR rejected' "$CASE_ROOT"

make_case malformed-nul
printf 'VM_ID=1\nVM_UUID=AB\0CD\n' >"$CASE_ROOT/1/vm.conf"
assert_malformed_root 'NUL rejected' "$CASE_ROOT"

non_numeric_root="$TEST_ROOT/non-numeric"
mkdir -p "$non_numeric_root/vm-one"
printf '%s\n' 'VM_UUID=VALUE' >"$non_numeric_root/vm-one/vm.conf"
assert_malformed_root 'non-numeric instance directory rejected' "$non_numeric_root"

symlink_config_root="$TEST_ROOT/symlink-config"
mkdir -p "$symlink_config_root/1"
printf '%s\n' 'VM_ID=1' >"$symlink_config_root/target.conf"
ln -s ../target.conf "$symlink_config_root/1/vm.conf"
assert_malformed_root 'vm.conf symlink rejected' "$symlink_config_root"

symlink_dir_root="$TEST_ROOT/symlink-directory"
mkdir -p "$symlink_dir_root/target"
printf '%s\n' 'VM_ID=1' >"$symlink_dir_root/target/vm.conf"
ln -s target "$symlink_dir_root/1"
assert_malformed_root 'instance directory symlink rejected' "$symlink_dir_root"

# A malformed current config is intentionally skipped for --force; no bytes
# from that bundle need to be parsed to compare against other VMs.
ignored_root="$TEST_ROOT/ignored-current"
mkdir -p "$ignored_root/7"
printf '%s\n' 'this is not an assignment' >"$ignored_root/7/vm.conf"
assert_rc 0 'malformed current bundle skipped' \
    g11_identity_candidate_is_unique VM_UUID NEW-VALUE 7 "$ignored_root"

[[ ! -e $marker ]] || fail 'a scanned vm.conf executed content'
echo 'PASS: read-only vm.conf parsing and all G-11 identity namespaces are collision-safe'
