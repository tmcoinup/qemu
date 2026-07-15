#!/usr/bin/env bash
# Build both forwarding shims and enforce the per-VM product-name contract.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
SHIM_DIR="$REPO_ROOT/deploy/guest/nvapi-shim"
PATCH_SCRIPT="$REPO_ROOT/deploy/guest/patch-grid-strings.ps1"
APPLY_SCRIPT="$REPO_ROOT/deploy/guest/apply-vm-profile.ps1"
INSTALL_SCRIPT="$REPO_ROOT/deploy/guest/install-nvapi-shim.ps1"
START_SCRIPT="$REPO_ROOT/deploy/start-vm.sh"
SETUP_SCRIPT="$REPO_ROOT/deploy/setup-guest.sh"
SYNC_SCRIPT="$REPO_ROOT/deploy/sync-vgpu-profile.sh"
MDEV_LIB="$REPO_ROOT/deploy/lib/vgpu-mdev.sh"
MDEV_HELPER="$REPO_ROOT/deploy/host/update-vgpu-mdev-identity.py"
TMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TMP_DIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

require_text() {
    local needle=$1 file=$2
    grep -F -- "$needle" "$file" >/dev/null || \
        fail "missing '$needle' in ${file#$REPO_ROOT/}"
}

check_image() {
    local objdump=$1 image=$2 dump strings_dump
    dump="$TMP_DIR/$(basename "$image").exports.$RANDOM"
    strings_dump="$dump.strings"
    "$objdump" -p "$image" >"$dump"
    strings -a "$image" >"$strings_dump"
    grep -F 'Ordinal Base' "$dump" | grep -Eq '[[:space:]]1$' || \
        fail "$(basename "$image") export ordinal base is not 1"
    grep -Eq '^\s*\[\s*0\] nvapi_Direct_GetMethod$' "$dump" || \
        fail "$(basename "$image") ordinal 1 is not nvapi_Direct_GetMethod"
    grep -Eq '^\s*\[\s*1\] nvapi_QueryInterface$' "$dump" || \
        fail "$(basename "$image") ordinal 2 is not nvapi_QueryInterface"
    grep -Fx 'IdentityGpuName' "$strings_dump" >/dev/null || \
        fail "$(basename "$image") lacks the per-VM name registry marker"
    grep -Fx 'NvAPI_GPU_GetFullName' "$strings_dump" >/dev/null || \
        fail "$(basename "$image") lacks the full-name hook marker"
}

for tool in x86_64-w64-mingw32-gcc i686-w64-mingw32-gcc \
            x86_64-w64-mingw32-objdump i686-w64-mingw32-objdump strings; do
    command -v "$tool" >/dev/null || fail "missing build tool: $tool"
done

for spec in \
    'x86_64-w64-mingw32:nvapi64.dll:0x180000000' \
    'i686-w64-mingw32:nvapi.dll:0x10000000'; do
    IFS=: read -r triplet name image_base <<<"$spec"
    "$triplet-gcc" -shared -O2 -std=c99 -Wall -Wextra -Werror \
        -o "$TMP_DIR/$name" "$SHIM_DIR/nvapi_shim.c" \
        "$SHIM_DIR/nvapi_shim.def" -static -lkernel32 \
        -Wl,--no-insert-timestamp \
        -Wl,--image-base,"$image_base" \
        -Wl,--subsystem,windows
    check_image "$triplet-objdump" "$TMP_DIR/$name"
    check_image "$triplet-objdump" "$SHIM_DIR/$name"
    cmp -s "$TMP_DIR/$name" "$SHIM_DIR/$name" || \
        fail "$name is stale; run deploy/guest/nvapi-shim/build.sh"
done

require_text '0xCEEE8E9F' "$SHIM_DIR/nvapi_shim.c"
require_text 'IdentityGpuName' "$SHIM_DIR/nvapi_shim.c"
require_text 'nvapi_Direct_GetMethod @1' "$SHIM_DIR/nvapi_shim.def"
require_text 'nvapi_QueryInterface @2' "$SHIM_DIR/nvapi_shim.def"
require_text '-PropertyType String' "$PATCH_SCRIPT"
require_text '1-31 printable ASCII characters' "$PATCH_SCRIPT"
require_text 'IdentityGpuName' "$APPLY_SCRIPT"
require_text "'gpu.name' 31" "$APPLY_SCRIPT"
require_text 'Assert-ShimImage' "$INSTALL_SCRIPT"
require_text 'Installed shim hash mismatch' "$INSTALL_SCRIPT"
require_text 'SKIP_NVAPI_SHIM=1' "$SETUP_SCRIPT"
require_text '--with-nvapi-shim) SKIP_NVAPI_SHIM=0; SKIP_STEALTH=0' "$SETUP_SCRIPT"
require_text 'SKIP_STEALTH=1' "$SETUP_SCRIPT"
require_text '--with-guest-identity) SKIP_STEALTH=0' "$SETUP_SCRIPT"
require_text '--with-guest-identity' "$SYNC_SCRIPT"
require_text 'compatibility fallback' "$SYNC_SCRIPT"
require_text 'MDEV_UUID=$VM_UUID' "$START_SCRIPT"
require_text 'mdev_identity_name=$GPU_NAME' "$START_SCRIPT"
require_text 'guest_gpu_name' "$MDEV_LIB"
require_text '1-31 printable ASCII bytes' "$MDEV_HELPER"

if grep -aF 'NVIDIA GeForce GTX 750 Ti' \
        "$SHIM_DIR/nvapi64.dll" "$SHIM_DIR/nvapi.dll" >/dev/null; then
    fail 'checked-in shim hard-codes VM2 instead of reading its registry identity'
fi

echo 'PASS: per-VM NVAPI identity shim build/export contract'
