#!/usr/bin/env bash
# Exercise the narrow mdev sudo helper entirely against a temporary fake host.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
ADMIN="$REPO_ROOT/deploy/host/vgpu-mdev-admin.sh"
IDENTITY="$REPO_ROOT/deploy/host/update-vgpu-mdev-identity.py"
INSTALLER="$REPO_ROOT/deploy/host/install-vgpu-mdev-admin.sh"
MDEV_LIB="$REPO_ROOT/deploy/lib/vgpu-mdev.sh"
TMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TMP_DIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

UUID=12345678-1234-1234-1234-123456789abc
BDF=0000:04:00.0
TYPE=nvidia-257
CONFIG="$TMP_DIR/profile_override.toml"
BUS="$TMP_DIR/mdev-bus"
DEVICES="$TMP_DIR/devices"
PROC="$TMP_DIR/proc"
VERSION="$TMP_DIR/nvidia-version"
LOCK="$TMP_DIR/run/mdev-admin.lock"
TYPE_DIR="$BUS/$BDF/mdev_supported_types/$TYPE"

mkdir -p "$TYPE_DIR" "$DEVICES" "$PROC" "$(dirname "$LOCK")"
printf '0x10de\n' >"$BUS/$BDF/vendor"
printf 'vfio-pci\n' >"$TYPE_DIR/device_api"
: >"$TYPE_DIR/create"
printf '535.161.05\n' >"$VERSION"
cat >"$CONFIG" <<'EOF'
[profile.nvidia-257]
framebuffer = 0x74000000
EOF

admin() {
    VGPU_MDEV_ADMIN_TEST_MODE=1 \
    VGPU_MDEV_ADMIN_IDENTITY_HELPER="$IDENTITY" \
    VGPU_MDEV_ADMIN_IDENTITY_CONFIG="$CONFIG" \
    VGPU_MDEV_ADMIN_BUS_DIR="$BUS" \
    VGPU_MDEV_ADMIN_DEVICES_DIR="$DEVICES" \
    VGPU_MDEV_ADMIN_NVIDIA_VERSION_FILE="$VERSION" \
    VGPU_MDEV_ADMIN_PROC_DIR="$PROC" \
    VGPU_MDEV_ADMIN_LOCK_FILE="$LOCK" \
        "$ADMIN" "$@"
}

bash -n "$ADMIN" "$INSTALLER" "$MDEV_LIB"
admin check | grep -Fq 'schema=1 ready'

admin identity-set "$UUID" 'NVIDIA GeForce GTX 750 Ti' \
    - - - 128 8 1 >/dev/null
grep -Fxq "[mdev.\"$UUID\"]" "$CONFIG"
grep -Fxq 'rm_fb_bus_width = 128' "$CONFIG"
grep -Fxq 'rm_fb_ram_type = 8' "$CONFIG"
grep -Fxq 'rm_fb_memory_vendor = 1' "$CONFIG"

before=$(sha256sum "$CONFIG" | awk '{print $1}')
if admin identity-set "$UUID" 'NVIDIA GeForce GTX 750 Ti' \
        - - - 127 8 1 >/dev/null 2>&1; then
    fail 'admin helper accepted an invalid RM framebuffer tuple'
fi
[[ "$(sha256sum "$CONFIG" | awk '{print $1}')" == "$before" ]] ||
    fail 'rejected identity request changed the live config'

# A running QEMU owner blocks identity changes and mdev removal.
mkdir -p "$PROC/4242"
printf '%s\0' qemu-system-x86_64 \
    "sysfsdev=/sys/bus/mdev/devices/$UUID" >"$PROC/4242/cmdline"
if admin identity-remove "$UUID" >/dev/null 2>&1; then
    fail 'admin helper changed identity while QEMU owned the UUID'
fi
rm -rf -- "$PROC/4242"
admin identity-remove "$UUID" >/dev/null
if grep -Fq "$UUID" "$CONFIG"; then
    fail 'identity-remove retained the per-mdev table'
fi

admin mdev-create "$BDF" "$TYPE" "$UUID" >/dev/null
grep -Fxq "$UUID" "$TYPE_DIR/create"
if admin mdev-create ../../etc "$TYPE" "$UUID" >/dev/null 2>&1; then
    fail 'admin helper accepted a path-like BDF'
fi

TARGET="$TMP_DIR/mdev-target"
mkdir -p "$TARGET/nvidia"
: >"$TARGET/remove"
: >"$TARGET/nvidia/vgpu_params"
ln -s "$TARGET" "$DEVICES/$UUID"
admin console-interval "$UUID" 16667 >/dev/null
grep -Fxq 'intervaltime=16667,vgaintervaltime=16667' \
    "$TARGET/nvidia/vgpu_params"
if admin console-interval "$UUID" 4999 >/dev/null 2>&1; then
    fail 'admin helper accepted an unsafe console interval'
fi
admin mdev-remove "$UUID" >/dev/null
grep -Fxq 1 "$TARGET/remove"

print_output=$($INSTALLER --print --user "$(id -un)")
grep -Fq 'NOPASSWD:NOSETENV:' <<<"$print_output" ||
    fail 'installer did not disable sudo environment injection'
for verb in check identity-set identity-remove mdev-create mdev-remove console-interval; do
    grep -Fq "/usr/local/libexec/qemu-vgpu-mdev-admin $verb" \
        <<<"$print_output" || fail "sudoers output lacks $verb"
done

grep -Fq 'sudo -n -- "$VGPU_MDEV_ADMIN_HELPER" "$@"' "$MDEV_LIB" ||
    fail 'runtime helper invocation could open an interactive password prompt'
grep -Fq '_mdev_admin_run mdev-create' "$MDEV_LIB" ||
    fail 'runtime mdev creation bypasses the narrow helper'
grep -Fq '_mdev_admin_run mdev-remove' "$MDEV_LIB" ||
    fail 'runtime mdev cleanup bypasses the narrow helper'
grep -Fq '_mdev_admin_run identity-set' "$MDEV_LIB" ||
    fail 'runtime identity update bypasses the narrow helper'

echo 'PASS: root-owned mdev admin contract is narrow, atomic and non-interactive'
