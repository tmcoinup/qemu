#!/usr/bin/env bash
# Validate the source-built transient UEFI helper without touching any VM.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SOURCE="$REPO_ROOT/deploy/firmware/chainloader/ChainLauncher.c"
IMAGE="$REPO_ROOT/deploy/firmware/g11-usb-install-boot.img"
BUILDER="$REPO_ROOT/deploy/host/build-usb-install-boot-helper.sh"
VERIFIER="$REPO_ROOT/deploy/host/verify-usb-install-boot-helper.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[[ -r "$SOURCE" && -r "$IMAGE" && -x "$BUILDER" && -x "$VERIFIER" ]] || \
    fail "USB install helper source/asset/build wrappers are incomplete"

"$VERIFIER"

grep -Fq 'mHelperMarker[] = L"\\HELPER.MARK"' "$SOURCE" || \
    fail "chainloader does not mark and skip its own filesystem"
grep -Fq 'mWindowsBootPath[] = L"\\EFI\\BOOT\\BOOTX64.EFI"' "$SOURCE" || \
    fail "chainloader target path is missing"
grep -Fq 'mWindowsBootWimPath[] = L"\\sources\\boot.wim"' "$SOURCE" || \
    fail "chainloader does not constrain the target to Windows install media"
grep -Fq '#define G11_DISCOVERY_ATTEMPTS      3U' "$SOURCE" || \
    fail "chainloader bounded late-USB discovery retry is missing"
grep -Fq 'BootServices->LoadImage' "$SOURCE" || \
    fail "chainloader does not use the target filesystem device path"
grep -Fq 'BootServices->StartImage' "$SOURCE" || \
    fail "chainloader does not start the verified target"
if grep -Eiq 'testsigning|nointegritychecks|bcdedit|self[- ]signed' \
        "$SOURCE" "$BUILDER"; then
    fail "helper violates the signed-driver/BCD safety boundary"
fi

edk2_dir="${EDK2_DIR:-$REPO_ROOT/deploy/host/ovmf-build/edk2-2024.02}"
build_ready=1
for dependency in x86_64-w64-mingw32-gcc mkfs.vfat mmd mcopy truncate; do
    command -v "$dependency" >/dev/null 2>&1 || build_ready=0
done
[[ -r "$edk2_dir/MdePkg/Include/Uefi.h" ]] || build_ready=0

if (( build_ready )); then
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf -- "$tmp_dir"' EXIT
    EDK2_DIR="$edk2_dir" "$BUILDER" "$tmp_dir/helper-a.img" >/dev/null
    EDK2_DIR="$edk2_dir" "$BUILDER" "$tmp_dir/helper-b.img" >/dev/null
    cmp -s "$tmp_dir/helper-a.img" "$tmp_dir/helper-b.img" || \
        fail "two clean helper builds are not byte-for-byte reproducible"
    cmp -s "$tmp_dir/helper-a.img" "$IMAGE" || \
        fail "checked-in helper asset is stale relative to source"
else
    echo "SKIP: helper rebuild toolchain/edk2 headers are unavailable; checked asset was still fully verified"
fi

echo "PASS: source-built transient USB install helper"
