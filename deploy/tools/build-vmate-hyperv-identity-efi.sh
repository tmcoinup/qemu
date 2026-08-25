#!/usr/bin/env bash
# Build the P-11 Hyper-V guest SMBIOS identity chainloader reproducibly.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
PACKAGE_ROOT="$REPO_ROOT/deploy/windows/gpup/firmware"
DEFAULT_EDK2="$REPO_ROOT/deploy/host/ovmf-build/edk2-2024.02"
: "${EDK2:=$DEFAULT_EDK2}"
: "${TARGET:=RELEASE}"
: "${TOOLCHAIN:=GCC5}"
: "${JOBS:=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')}"
: "${OUTPUT:=$PACKAGE_ROOT/bin/VMateIdentityBoot.efi}"

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

[[ -d "$EDK2/MdePkg" && -f "$EDK2/edksetup.sh" ]] ||
    die "EDK2 source tree is incomplete: $EDK2"
[[ -f "$PACKAGE_ROOT/VMateIdentityPkg/VMateIdentityPkg.dsc" ]] ||
    die "VMateIdentityPkg is missing from $PACKAGE_ROOT"
[[ "$TARGET" == RELEASE || "$TARGET" == DEBUG ]] ||
    die "TARGET must be RELEASE or DEBUG"
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "JOBS must be a positive integer"

BUILD_TMP="$(mktemp -d /tmp/vmate-identity-build.XXXXXX)"
cleanup() {
    if [[ "$BUILD_TMP" == /tmp/vmate-identity-build.* &&
          -d "$BUILD_TMP" ]]; then
        rm -rf -- "$BUILD_TMP"
    fi
}
trap cleanup EXIT

export WORKSPACE="$EDK2"
export PACKAGES_PATH="$PACKAGE_ROOT:$EDK2"
export EDK_TOOLS_PATH="$EDK2/BaseTools"
export CONF_PATH="$BUILD_TMP/Conf"
mkdir -p -- "$CONF_PATH"

# edksetup uses optional variables internally, so nounset is scoped off only
# while it initializes the EDK2 build environment.
set +u
# shellcheck disable=SC1090
source "$EDK2/edksetup.sh" BaseTools >/dev/null
set -u

GENFW="$EDK_TOOLS_PATH/BinWrappers/PosixLike/GenFw"
BUILD="$EDK_TOOLS_PATH/BinWrappers/PosixLike/build"
if [[ ! -x "$GENFW" || ! -x "$BUILD" ]]; then
    make -C "$EDK_TOOLS_PATH" -j "$JOBS"
fi
[[ -x "$GENFW" && -x "$BUILD" ]] ||
    die 'EDK2 BaseTools did not produce build and GenFw'

"$BUILD" -p VMateIdentityPkg/VMateIdentityPkg.dsc \
    -a X64 -b "$TARGET" -t "$TOOLCHAIN" -n "$JOBS"

BUILT="$EDK2/Build/VMateIdentity/${TARGET}_${TOOLCHAIN}/X64/VMateIdentityBoot.efi"
[[ -s "$BUILT" ]] || die "EDK2 output is missing or empty: $BUILT"
STAGED="$BUILD_TMP/VMateIdentityBoot.efi"
install -m 0644 -- "$BUILT" "$STAGED"

# EDK2's own canonicalizer clears the timestamp, debug directory and absolute
# CodeView path. This makes the packaged EFI independent of the checkout path.
"$GENFW" -z -r "$STAGED"
file "$STAGED" | grep -F 'PE32+ executable (EFI application)' >/dev/null ||
    die 'built file is not an x64 EFI application'
if strings -a "$STAGED" | grep -E '/[^ ]*/VMateIdentityBoot|[A-Za-z]:\\.*VMateIdentityBoot' \
        >/dev/null; then
    die 'canonical EFI still contains an absolute build path'
fi

install -D -m 0644 -- "$STAGED" "$OUTPUT"
HASH="$(sha256sum -- "$OUTPUT" | awk '{print toupper($1)}')"
printf '%s  %s\n' "$HASH" "$(basename -- "$OUTPUT")" >"$OUTPUT.sha256"
printf 'VMateIdentityBoot: %s\nSHA256: %s\n' "$OUTPUT" "$HASH"
