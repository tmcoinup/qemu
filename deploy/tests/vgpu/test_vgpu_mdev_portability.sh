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
V100D_TYPE="$V100D_PARENT/mdev_supported_types/nvidia-291"
RTX_TYPE="$RTX_PARENT/mdev_supported_types/nvidia-257"
mkdir -p "$CLASS_DIR" "$DEVICES_DIR" \
    "$V100_1Q_TYPE" "$V100_TYPE" "$V100D_TYPE" "$RTX_TYPE"
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

# Seven V100 vGPUs plus ten vGPUs on a different parent.  Capacity accounting
# must see only 7 * 2048 MiB on the selected V100.
for i in $(seq 1 7); do
    make_active "$V100_PARENT" "$V100_TYPE" "$i"
done
for i in $(seq 101 110); do
    make_active "$RTX_PARENT" "$RTX_TYPE" "$i"
done
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

ALLOC_UUID=20000000-0000-0000-0000-000000000001
mdev_allocate V100-2Q "$ALLOC_UUID" 2048 >/dev/null
assert_eq "$ALLOC_UUID" "$WRITE_CONTENT" 'mdev create UUID'
assert_eq "$(readlink -f "$V100_TYPE")/create" \
    "$(readlink -f "$(dirname "$WRITE_PATH")")/$(basename "$WRITE_PATH")" \
    'mdev create path'

ALLOC_1Q_UUID=20000000-0000-0000-0000-000000000007
mdev_allocate V100-1Q "$ALLOC_1Q_UUID" 1024 >/dev/null
assert_eq "$ALLOC_1Q_UUID" "$WRITE_CONTENT" '1Q mdev create UUID'
assert_eq "$(readlink -f "$V100_1Q_TYPE")/create" \
    "$(readlink -f "$(dirname "$WRITE_PATH")")/$(basename "$WRITE_PATH")" \
    '1Q mdev create path'
if mdev_allocate V100-1Q 20000000-0000-0000-0000-000000000008 \
        2048 >/dev/null 2>&1; then
    fail '1Q framebuffer mismatch was accepted'
fi

if mdev_allocate V100-2Q 20000000-0000-0000-0000-000000000002 \
        4096 >/dev/null 2>&1; then
    fail 'framebuffer mismatch was accepted'
fi

# Two 1 GiB vGPUs mixed with seven 2 GiB vGPUs fill a 16 GiB card.  Capacity
# accounting must inspect each active type instead of multiplying one size.
make_active "$V100_PARENT" "$V100_1Q_TYPE" 8
assert_eq 15360 "$(mdev_active_framebuffer_mb "$V100_1Q_TYPE" 1024)" \
    'mixed 1Q/2Q framebuffer sum'
WRITE_CONTENT=""
mdev_allocate V100-1Q 20000000-0000-0000-0000-000000000009 \
    1024 >/dev/null
[[ -n "$WRITE_CONTENT" ]] || fail 'final 1 GiB slot was rejected'
make_active "$V100_PARENT" "$V100_1Q_TYPE" 9
WRITE_CONTENT=""
if mdev_allocate V100-1Q 20000000-0000-0000-0000-000000000003 \
        1024 >/dev/null 2>&1; then
    fail '16 GiB hard capacity limit was not enforced'
fi
[[ -z "$WRITE_CONTENT" ]] || fail 'capacity failure attempted a sysfs write'

# sysfs capacity is independently enforced when the framebuffer cap has room.
rm -f "$DEVICES_DIR/10000000-0000-0000-0000-000000000009"
printf '%s\n' 0 >"$V100_1Q_TYPE/available_instances"
if mdev_allocate V100-1Q 20000000-0000-0000-0000-000000000004 \
        1024 >/dev/null 2>&1; then
    fail 'available_instances=0 was ignored'
fi

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

echo 'OK: portable V100/multi-parent mdev discovery and capacity checks passed'
