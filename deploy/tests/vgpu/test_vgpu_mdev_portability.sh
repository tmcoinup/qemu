#!/usr/bin/env bash
# Exercise host-resource discovery/capacity with a fake multi-GPU sysfs tree.
# No real mdev is created or removed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
MDEV_LIB="$REPO_ROOT/deploy/lib/vgpu-mdev.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_eq() {
    local expected=$1 actual=$2 label=$3
    [[ "$actual" == "$expected" ]] \
        || fail "$label: expected '$expected', got '$actual'"
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT

CLASS_DIR="$TMP_DIR/sys/class/mdev_bus"
DEVICES_DIR="$TMP_DIR/sys/bus/mdev/devices"
V100_PARENT="$TMP_DIR/sys/devices/pci0000:00/0000:65:00.0"
RTX_PARENT="$TMP_DIR/sys/devices/pci0000:00/0000:66:00.0"
V100D_PARENT="$TMP_DIR/sys/devices/pci0000:00/0000:68:00.0"
V100_1Q_TYPE="$V100_PARENT/mdev_supported_types/nvidia-105"
V100_TYPE="$V100_PARENT/mdev_supported_types/nvidia-106"
V100_2B_TYPE="$V100_PARENT/mdev_supported_types/nvidia-107"
V100_UNPARSEABLE_TYPE="$V100_PARENT/mdev_supported_types/nvidia-108"
V100D_TYPE="$V100D_PARENT/mdev_supported_types/nvidia-291"
RTX_TYPE="$RTX_PARENT/mdev_supported_types/nvidia-257"
RTX_1Q_TYPE="$RTX_PARENT/mdev_supported_types/nvidia-256"
mkdir -p "$CLASS_DIR" "$DEVICES_DIR" \
    "$V100_1Q_TYPE" "$V100_TYPE" "$V100_2B_TYPE" \
    "$V100_UNPARSEABLE_TYPE" "$V100D_TYPE" "$RTX_TYPE" "$RTX_1Q_TYPE"
ln -s "$V100_PARENT" "$CLASS_DIR/0000:65:00.0"
ln -s "$RTX_PARENT" "$CLASS_DIR/0000:66:00.0"
ln -s "$V100D_PARENT" "$CLASS_DIR/0000:68:00.0"
printf '%s\n' 0x10de >"$V100_PARENT/vendor"
printf '%s\n' 0x10de >"$RTX_PARENT/vendor"
printf '%s\n' 0x10de >"$V100D_PARENT/vendor"

printf '%s\n' 'GRID V100-1Q' >"$V100_1Q_TYPE/name"
printf '%s\n' 'num_heads=4, framebuffer=1024M, max_instance=16' \
    >"$V100_1Q_TYPE/description"
printf '%s\n' 16 >"$V100_1Q_TYPE/available_instances"
printf '%s\n' vfio-pci >"$V100_1Q_TYPE/device_api"
touch "$V100_1Q_TYPE/create"

printf '%s\n' 'GRID V100-2Q' >"$V100_TYPE/name"
printf '%s\n' 'num_heads=4, framebuffer=2048M, max_instance=8' \
    >"$V100_TYPE/description"
printf '%s\n' 8 >"$V100_TYPE/available_instances"
printf '%s\n' vfio-pci >"$V100_TYPE/device_api"
touch "$V100_TYPE/create"

printf '%s\n' 'GRID V100-2B' >"$V100_2B_TYPE/name"
printf '%s\n' 'num_heads=4, framebuffer=2048M, max_instance=8' \
    >"$V100_2B_TYPE/description"
printf '%s\n' 8 >"$V100_2B_TYPE/available_instances"
printf '%s\n' vfio-pci >"$V100_2B_TYPE/device_api"
touch "$V100_2B_TYPE/create"

# An active mdev whose type no longer has a parseable framebuffer contract
# must make capacity validation fail closed instead of borrowing the new
# request's framebuffer as a fallback.
printf '%s\n' 'GRID V100-unknown' >"$V100_UNPARSEABLE_TYPE/name"
printf '%s\n' 'num_heads=4, framebuffer=unknown, max_instance=8' \
    >"$V100_UNPARSEABLE_TYPE/description"
printf '%s\n' 8 >"$V100_UNPARSEABLE_TYPE/available_instances"
printf '%s\n' vfio-pci >"$V100_UNPARSEABLE_TYPE/device_api"
touch "$V100_UNPARSEABLE_TYPE/create"

printf '%s\n' 'GRID V100D-2Q' >"$V100D_TYPE/name"
printf '%s\n' 'num_heads=4, framebuffer=2G, max_instance=16' \
    >"$V100D_TYPE/description"
printf '%s\n' 16 >"$V100D_TYPE/available_instances"
printf '%s\n' vfio-pci >"$V100D_TYPE/device_api"
touch "$V100D_TYPE/create"

printf '%s\n' 'GRID RTX6000-2Q' >"$RTX_TYPE/name"
printf '%s\n' 'num_heads=4, framebuffer=2048M, max_instance=12' \
    >"$RTX_TYPE/description"
printf '%s\n' 12 >"$RTX_TYPE/available_instances"
printf '%s\n' vfio-pci >"$RTX_TYPE/device_api"
touch "$RTX_TYPE/create"

printf '%s\n' 'GRID RTX6000-1Q' >"$RTX_1Q_TYPE/name"
printf '%s\n' 'num_heads=4, framebuffer=1024M, max_instance=24' \
    >"$RTX_1Q_TYPE/description"
printf '%s\n' 24 >"$RTX_1Q_TYPE/available_instances"
printf '%s\n' vfio-pci >"$RTX_1Q_TYPE/device_api"
touch "$RTX_1Q_TYPE/create"

# Remaining V100 SKU names use deliberately arbitrary nvidia-NNN values to
# prove that discovery is name-based rather than tied to a numeric type ID.
EXTRA_V100_VARIANTS=(
    '0000:69:00.0|nvidia-701|V100X-2Q|8'
    '0000:6a:00.0|nvidia-702|V100DX-2Q|16'
    '0000:6b:00.0|nvidia-703|V100S-2Q|16'
    '0000:6c:00.0|nvidia-704|V100L-2Q|8'
)
for row in "${EXTRA_V100_VARIANTS[@]}"; do
    IFS='|' read -r bdf type_id profile max_instances <<<"$row"
    parent="$TMP_DIR/sys/devices/pci0000:00/$bdf"
    type_dir="$parent/mdev_supported_types/$type_id"
    mkdir -p "$type_dir"
    ln -s "$parent" "$CLASS_DIR/$bdf"
    printf '%s\n' 0x10de >"$parent/vendor"
    printf 'GRID %s\n' "$profile" >"$type_dir/name"
    printf 'framebuffer=2048M, max_instance=%s\n' "$max_instances" \
        >"$type_dir/description"
    printf '%s\n' "$max_instances" >"$type_dir/available_instances"
    printf '%s\n' vfio-pci >"$type_dir/device_api"
    touch "$type_dir/create"
done

VGPU_MGPU=auto
VGPU_TYPES_DIR=""
MDEV_BUS_CLASS_DIR="$CLASS_DIR"
MDEV_DEVICES_DIR="$DEVICES_DIR"
VGPU_TOTAL_FB_MB=16384
VGPU_CAPACITY_CHECK=both
VGPU_HOST_LOCK_FILE="$TMP_DIR/gpu-mode.lock"
: >"$VGPU_HOST_LOCK_FILE"
# shellcheck source=../../../lib/vgpu-mdev.sh
source "$MDEV_LIB"

# The equal-framebuffer guard must never interpret an unavailable or
# structurally unsafe mdev bus view as an empty host.
MDEV_DEVICES_DIR="$TMP_DIR/missing-mdev-devices"
if mdev_validate_active_framebuffer_tier "$V100_TYPE" 2048 2>/dev/null; then
    fail 'missing mdev devices directory did not fail closed'
fi
ln -s "$DEVICES_DIR" "$TMP_DIR/mdev-devices-link"
MDEV_DEVICES_DIR="$TMP_DIR/mdev-devices-link"
if mdev_validate_active_framebuffer_tier "$V100_TYPE" 2048 2>/dev/null; then
    fail 'symlinked mdev devices directory was accepted'
fi
MDEV_DEVICES_DIR="$DEVICES_DIR"
chmod 000 "$DEVICES_DIR"
if mdev_validate_active_framebuffer_tier "$V100_TYPE" 2048 2>/dev/null; then
    chmod 700 "$DEVICES_DIR"
    fail 'untraversable mdev devices directory did not fail closed'
fi
chmod 700 "$DEVICES_DIR"
touch "$DEVICES_DIR/not-a-symlink"
if mdev_validate_active_framebuffer_tier "$V100_TYPE" 2048 2>/dev/null; then
    fail 'non-symlink mdev bus entry was accepted'
fi
rm -f -- "$DEVICES_DIR/not-a-symlink"
ln -s "$TMP_DIR/missing-mdev-target" \
    "$DEVICES_DIR/30000000-0000-0000-0000-000000000001"
if mdev_validate_active_framebuffer_tier "$V100_TYPE" 2048 2>/dev/null; then
    fail 'unresolvable active mdev link did not fail closed'
fi
rm -f -- "$DEVICES_DIR/30000000-0000-0000-0000-000000000001"

for identity_key in gt740_1gb gt740_zotac_1gb gt730_gigabyte_1gb \
        gtx750_asus_1gb gtx750_zotac_1gb; do
    assert_eq RTX6000-1Q "$(_profile_to_keyword "$identity_key")" \
        "$identity_key legacy 1Q keyword"
    assert_eq nvidia-256 "$(_mdev_legacy_type_id "$identity_key")" \
        "$identity_key legacy 1Q type"
done

# Host recovery/mode switching must exclude mdev create/remove through the same
# advisory lock.  A held lock must fail closed instead of racing sysfs writes.
exec 8<"$VGPU_HOST_LOCK_FILE"
flock -x 8
VGPU_HOST_LOCK_WAIT_SECONDS=1
if _mdev_host_lock_acquire 2>/dev/null; then
    _mdev_host_lock_release || true
    fail 'mdev mutation ignored the shared vGPU host lock'
fi
flock -u 8
exec 8<&-
VGPU_HOST_LOCK_WAIT_SECONDS=30

VGPU_MGPU=65:00.0
if mdev_type_roots >/dev/null 2>&1; then
    fail 'short/non-domain PCI BDF was accepted'
fi
VGPU_MGPU=auto

found=$(mdev_find_type V100-2Q)
assert_eq "$(readlink -f "$V100_TYPE")" "$(readlink -f "$found")" \
    'V100 type-name discovery'
found_1q=$(mdev_find_type V100-1Q)
assert_eq "$(readlink -f "$V100_1Q_TYPE")" "$(readlink -f "$found_1q")" \
    'V100 1Q type-name discovery'
assert_eq 1024 "$(mdev_type_framebuffer_mb "$V100_1Q_TYPE")" \
    'V100 1Q framebuffer parsing'
found_v100d=$(mdev_find_type V100D-2Q)
assert_eq "$(readlink -f "$V100D_TYPE")" "$(readlink -f "$found_v100d")" \
    'V100D type-name discovery'
for selector in V100X-2Q V100DX-2Q V100S-2Q V100L-2Q; do
    found_variant=$(mdev_find_type "$selector")
    assert_eq "GRID $selector" "$(cat "$found_variant/name")" \
        "$selector type-name discovery"
    assert_eq 2048 "$(mdev_type_framebuffer_mb "$found_variant")" \
        "$selector framebuffer"
done
if mdev_find_type 'V100*-2Q' >/dev/null 2>&1; then
    fail 'cross-SKU glob silently selected one of multiple V100 parents'
fi
found_legacy=$(mdev_find_type nvidia-257)
assert_eq "$(readlink -f "$RTX_TYPE")" "$(readlink -f "$found_legacy")" \
    'legacy numeric type discovery'
assert_eq 2048 "$(mdev_type_framebuffer_mb "$V100_TYPE")" \
    'M-suffixed framebuffer parsing'
assert_eq 2048 "$(mdev_type_framebuffer_mb "$V100D_TYPE")" \
    'G-suffixed framebuffer parsing'

make_active() {
    local parent=$1 type_dir=$2 serial=$3 uuid target
    printf -v uuid '10000000-0000-0000-0000-%012d' "$serial"
    target="$parent/$uuid"
    mkdir -p "$target"
    ln -s "$type_dir" "$target/mdev_type"
    ln -s "$target" "$DEVICES_DIR/$uuid"
}

remove_active() {
    local parent=$1 serial=$2 uuid
    printf -v uuid '10000000-0000-0000-0000-%012d' "$serial"
    rm -f -- "$DEVICES_DIR/$uuid"
    rm -rf -- "$parent/$uuid"
}

# Exercise the exact cleanup state machine used by start-vm.  A signal while
# the allocator owns the host lock must use the locked release primitive for a
# newly appeared UUID, while a failed attempt to reuse an old UUID must never
# remove it.
(
    CLEANUP_UUID=35000000-0000-0000-0000-000000000001
    CLEANUP_TARGET="$V100_PARENT/$CLEANUP_UUID"
    CLEANUP_MARKER="$TMP_DIR/cleanup-new.mdev"
    LOCKED_RELEASES=0
    UNLOCKED_RELEASES=0
    mkdir -p "$CLEANUP_TARGET"
    ln -s "$V100_TYPE" "$CLEANUP_TARGET/mdev_type"
    ln -s "$CLEANUP_TARGET" "$DEVICES_DIR/$CLEANUP_UUID"
    printf '%s\n' "$CLEANUP_UUID" >"$CLEANUP_MARKER"
    _mdev_release_locked() {
        local uuid=$1
        LOCKED_RELEASES=$((LOCKED_RELEASES + 1))
        rm -f -- "$DEVICES_DIR/$uuid"
        rm -rf -- "$V100_PARENT/$uuid"
    }
    mdev_release() {
        UNLOCKED_RELEASES=$((UNLOCKED_RELEASES + 1))
        return 1
    }
    _MDEV_HOST_LOCK_STATE=held
    mdev_cleanup_allocation_state pending-new "$CLEANUP_UUID" \
        "$CLEANUP_MARKER" 2>/dev/null
    assert_eq 1 "$LOCKED_RELEASES" 'pending-new held-lock release count'
    assert_eq 0 "$UNLOCKED_RELEASES" 'pending-new unlocked release count'
    [[ ! -L "$DEVICES_DIR/$CLEANUP_UUID" ]] \
        || fail 'pending-new held-lock cleanup left the new UUID'
    [[ ! -e "$CLEANUP_MARKER" ]] \
        || fail 'successful pending-new cleanup left its recovery marker'

    # A release that reports success but leaves sysfs state is not completion;
    # preserve the marker for host recovery.
    mkdir -p "$CLEANUP_TARGET"
    ln -s "$V100_TYPE" "$CLEANUP_TARGET/mdev_type"
    ln -s "$CLEANUP_TARGET" "$DEVICES_DIR/$CLEANUP_UUID"
    printf '%s\n' "$CLEANUP_UUID" >"$CLEANUP_MARKER"
    _mdev_release_locked() { return 0; }
    if mdev_cleanup_allocation_state pending-new "$CLEANUP_UUID" \
            "$CLEANUP_MARKER" 2>/dev/null; then
        fail 'cleanup accepted remove success while UUID still existed'
    fi
    [[ -L "$DEVICES_DIR/$CLEANUP_UUID" && -f "$CLEANUP_MARKER" ]] \
        || fail 'incomplete cleanup did not preserve UUID and marker'

    PRE_CLEANUP_UUID=35000000-0000-0000-0000-000000000002
    PRE_CLEANUP_TARGET="$V100_PARENT/$PRE_CLEANUP_UUID"
    PRE_CLEANUP_MARKER="$TMP_DIR/cleanup-existing.mdev"
    mkdir -p "$PRE_CLEANUP_TARGET"
    ln -s "$V100_TYPE" "$PRE_CLEANUP_TARGET/mdev_type"
    ln -s "$PRE_CLEANUP_TARGET" "$DEVICES_DIR/$PRE_CLEANUP_UUID"
    printf '%s\n' "$PRE_CLEANUP_UUID" >"$PRE_CLEANUP_MARKER"
    LOCKED_RELEASES=0
    _mdev_release_locked() {
        LOCKED_RELEASES=$((LOCKED_RELEASES + 1))
        return 1
    }
    mdev_cleanup_allocation_state pending-existing "$PRE_CLEANUP_UUID" \
        "$PRE_CLEANUP_MARKER" 2>/dev/null
    assert_eq 0 "$LOCKED_RELEASES" 'pending-existing release count'
    [[ -L "$DEVICES_DIR/$PRE_CLEANUP_UUID" && -f "$PRE_CLEANUP_MARKER" ]] \
        || fail 'pending-existing failure removed old UUID or marker'

    rm -f -- "$DEVICES_DIR/$CLEANUP_UUID" \
        "$DEVICES_DIR/$PRE_CLEANUP_UUID" "$CLEANUP_MARKER" \
        "$PRE_CLEANUP_MARKER"
    rm -rf -- "$CLEANUP_TARGET" "$PRE_CLEANUP_TARGET"
)

# Seven V100 vGPUs plus ten vGPUs on a different parent.  Capacity accounting
# must see only 7 * 2048 MiB on the selected V100.
for i in $(seq 1 7); do
    make_active "$V100_PARENT" "$V100_TYPE" "$i"
done
for i in $(seq 101 110); do
    make_active "$RTX_PARENT" "$RTX_TYPE" "$i"
done
# A different framebuffer tier on another fully resolved physical parent is
# valid and must not influence the V100 equal-size decision.
make_active "$RTX_PARENT" "$RTX_1Q_TYPE" 111
assert_eq 7 "$(mdev_count_active "$V100_TYPE")" \
    'per-parent active count'
assert_eq 14336 "$(mdev_active_framebuffer_mb "$V100_TYPE" 2048)" \
    'per-parent framebuffer sum'

WRITE_CONTENT=""
WRITE_PATH=""
_mdev_sudo_write() {
    WRITE_CONTENT=$1
    WRITE_PATH=$2
}

# R535/Linux KVM equal-size mode may mix vGPU series, but not framebuffer
# sizes.  Seven active 2Q instances must therefore reject a 1Q allocation even
# though the raw 16 GiB framebuffer sum would still have room.
WRITE_CONTENT=""
if mdev_allocate V100-1Q 20000000-0000-0000-0000-000000000007 \
        1024 >/dev/null 2>&1; then
    fail 'mixed 1Q/2Q framebuffer sizes were accepted'
fi
[[ -z "$WRITE_CONTENT" ]] \
    || fail 'mixed-size rejection attempted a sysfs write'

# A different series with the same 2 GiB framebuffer remains valid in
# equal-size mode.
SAME_SIZE_UUID=20000000-0000-0000-0000-000000000010
WRITE_CONTENT=""
mdev_allocate V100-2B "$SAME_SIZE_UUID" 2048 >/dev/null
assert_eq "$SAME_SIZE_UUID" "$WRITE_CONTENT" \
    'same-size cross-series mdev create UUID'
assert_eq "$(readlink -f "$V100_2B_TYPE")/create" \
    "$(readlink -f "$(dirname "$WRITE_PATH")")/$(basename "$WRITE_PATH")" \
    'same-size cross-series mdev create path'

if mdev_allocate V100-1Q 20000000-0000-0000-0000-000000000008 \
        2048 >/dev/null 2>&1; then
    fail '1Q framebuffer mismatch was accepted'
fi

if mdev_allocate V100-2Q 20000000-0000-0000-0000-000000000002 \
        4096 >/dev/null 2>&1; then
    fail 'framebuffer mismatch was accepted'
fi

# A complete 16 GiB V100 admits the eighth 2Q instance, then rejects a ninth.
ALLOC_UUID=20000000-0000-0000-0000-000000000001
WRITE_CONTENT=""
mdev_allocate V100-2Q "$ALLOC_UUID" 2048 >/dev/null
assert_eq "$ALLOC_UUID" "$WRITE_CONTENT" 'eighth 2Q mdev create UUID'
assert_eq "$(readlink -f "$V100_TYPE")/create" \
    "$(readlink -f "$(dirname "$WRITE_PATH")")/$(basename "$WRITE_PATH")" \
    'eighth 2Q mdev create path'
make_active "$V100_PARENT" "$V100_TYPE" 8
assert_eq 16384 "$(mdev_active_framebuffer_mb "$V100_TYPE" 2048)" \
    'full 16 GiB 2Q framebuffer sum'
WRITE_CONTENT=""
if mdev_allocate V100-2Q 20000000-0000-0000-0000-000000000003 \
        2048 >/dev/null 2>&1; then
    fail '16 GiB hard capacity limit was not enforced'
fi
[[ -z "$WRITE_CONTENT" ]] || fail 'capacity failure attempted a sysfs write'

# sysfs capacity is independently enforced when the framebuffer cap has room.
remove_active "$V100_PARENT" 8
printf '%s\n' 0 >"$V100_TYPE/available_instances"
if mdev_allocate V100-2Q 20000000-0000-0000-0000-000000000004 \
        2048 >/dev/null 2>&1; then
    fail 'available_instances=0 was ignored'
fi
printf '%s\n' 8 >"$V100_TYPE/available_instances"

# Capacity cannot be proven while any active type on the selected parent has
# an unreadable framebuffer description.  Remove the regular fixtures first
# so no other limit can explain the expected failure.
for i in $(seq 1 7); do
    remove_active "$V100_PARENT" "$i"
done
make_active "$V100_PARENT" "$V100_UNPARSEABLE_TYPE" 9
WRITE_CONTENT=""
if mdev_allocate V100-2Q 20000000-0000-0000-0000-000000000009 \
        2048 >/dev/null 2>&1; then
    fail 'unparseable active mdev type did not fail closed'
fi
[[ -z "$WRITE_CONTENT" ]] \
    || fail 'unparseable active type attempted a sysfs write'
remove_active "$V100_PARENT" 9

# A 32 GiB V100D allows sixteen 2 GiB instances under the configured hard cap.
VGPU_TOTAL_FB_MB=32768
for i in $(seq 201 215); do
    make_active "$V100D_PARENT" "$V100D_TYPE" "$i"
done
WRITE_CONTENT=""
mdev_allocate V100D-2Q 20000000-0000-0000-0000-000000000005 \
    2048 >/dev/null
[[ -n "$WRITE_CONTENT" ]] || fail '32 GiB V100D sixteenth allocation was rejected'
make_active "$V100D_PARENT" "$V100D_TYPE" 216
WRITE_CONTENT=""
if mdev_allocate V100D-2Q 20000000-0000-0000-0000-000000000006 \
        2048 >/dev/null 2>&1; then
    fail '32 GiB V100D seventeenth allocation exceeded capacity'
fi
[[ -z "$WRITE_CONTENT" ]] || fail '32 GiB capacity failure attempted a sysfs write'
VGPU_TOTAL_FB_MB=16384

# Auto-selection must fail instead of silently choosing a GPU when the same
# profile exists on two parents.
V100_2_PARENT="$TMP_DIR/sys/devices/pci0000:00/0000:67:00.0"
V100_2_TYPE="$V100_2_PARENT/mdev_supported_types/nvidia-999"
mkdir -p "$V100_2_TYPE"
ln -s "$V100_2_PARENT" "$CLASS_DIR/0000:67:00.0"
printf '%s\n' 0x10de >"$V100_2_PARENT/vendor"
printf '%s\n' 'GRID V100-2Q' >"$V100_2_TYPE/name"
printf '%s\n' 'framebuffer=2048M' >"$V100_2_TYPE/description"
printf '%s\n' 8 >"$V100_2_TYPE/available_instances"
printf '%s\n' vfio-pci >"$V100_2_TYPE/device_api"
touch "$V100_2_TYPE/create"
if mdev_find_type V100-2Q >/dev/null 2>&1; then
    fail 'ambiguous auto-selected V100 profile was accepted'
fi

# Wrapper rollback is part of the allocation API: a helper failure after the
# kernel object appears must remove only the object created by this call.
ROLLBACK_UUID=40000000-0000-0000-0000-000000000001
ROLLBACK_TARGET="$V100_PARENT/$ROLLBACK_UUID"
ROLLBACK_RELEASES=0
_mdev_allocate_locked() {
    mkdir -p "$ROLLBACK_TARGET"
    ln -s "$V100_TYPE" "$ROLLBACK_TARGET/mdev_type"
    ln -s "$ROLLBACK_TARGET" "$DEVICES_DIR/$ROLLBACK_UUID"
    return 42
}
_mdev_release_locked() {
    local uuid=$1
    ROLLBACK_RELEASES=$((ROLLBACK_RELEASES + 1))
    rm -f -- "$DEVICES_DIR/$uuid"
    rm -rf -- "$V100_PARENT/$uuid"
}
if mdev_allocate V100-2Q "$ROLLBACK_UUID" 2048 >/dev/null 2>&1; then
    fail 'post-create allocation failure was reported as success'
else
    rollback_rc=$?
fi
assert_eq 42 "$rollback_rc" 'post-create failure return code'
assert_eq 1 "$ROLLBACK_RELEASES" 'post-create rollback count'
[[ ! -L "$DEVICES_DIR/$ROLLBACK_UUID" ]] \
    || fail 'new mdev survived a failed allocation'

# The same failure must not delete an object that was already present when the
# host lock was acquired.
PREEXISTING_UUID=40000000-0000-0000-0000-000000000002
PREEXISTING_TARGET="$V100_PARENT/$PREEXISTING_UUID"
mkdir -p "$PREEXISTING_TARGET"
ln -s "$V100_TYPE" "$PREEXISTING_TARGET/mdev_type"
ln -s "$PREEXISTING_TARGET" "$DEVICES_DIR/$PREEXISTING_UUID"
_mdev_allocate_locked() { return 43; }
ROLLBACK_RELEASES=0
if mdev_allocate V100-2Q "$PREEXISTING_UUID" 2048 >/dev/null 2>&1; then
    fail 'injected pre-existing allocation failure was reported as success'
else
    rollback_rc=$?
fi
assert_eq 43 "$rollback_rc" 'pre-existing failure return code'
assert_eq 0 "$ROLLBACK_RELEASES" 'pre-existing UUID rollback count'
[[ -L "$DEVICES_DIR/$PREEXISTING_UUID" ]] \
    || fail 'failed allocation removed a pre-existing UUID'
rm -f -- "$DEVICES_DIR/$PREEXISTING_UUID"
rm -rf -- "$PREEXISTING_TARGET"

# Even an unlock error after a successful create is returned as failure and
# triggers a re-locked rollback of a newly created UUID.
UNLOCK_UUID=40000000-0000-0000-0000-000000000003
UNLOCK_TARGET="$V100_PARENT/$UNLOCK_UUID"
HOST_RELEASE_CALLS=0
_mdev_allocate_locked() {
    mkdir -p "$UNLOCK_TARGET"
    ln -s "$V100_TYPE" "$UNLOCK_TARGET/mdev_type"
    ln -s "$UNLOCK_TARGET" "$DEVICES_DIR/$UNLOCK_UUID"
    return 0
}
_mdev_host_lock_acquire() {
    _MDEV_HOST_LOCK_STATE=held
    return 0
}
_mdev_host_lock_release() {
    HOST_RELEASE_CALLS=$((HOST_RELEASE_CALLS + 1))
    _MDEV_HOST_LOCK_STATE=none
    (( HOST_RELEASE_CALLS != 1 ))
}
ROLLBACK_RELEASES=0
if mdev_allocate V100-2Q "$UNLOCK_UUID" 2048 >/dev/null 2>&1; then
    fail 'host unlock failure after create was reported as success'
else
    rollback_rc=$?
fi
assert_eq 1 "$rollback_rc" 'host unlock failure return code'
assert_eq 2 "$HOST_RELEASE_CALLS" 'host lock release retry count'
assert_eq 1 "$ROLLBACK_RELEASES" 'host unlock failure rollback count'
[[ ! -L "$DEVICES_DIR/$UNLOCK_UUID" ]] \
    || fail 'new mdev survived a host unlock failure'

echo 'OK: portable V100/multi-parent mdev discovery and capacity checks passed'
