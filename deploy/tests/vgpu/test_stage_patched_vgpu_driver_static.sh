#!/usr/bin/env bash
# Safety invariants for the guest-side audited 538.33 GTX 1050 pre-stager.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
GUEST="$REPO_ROOT/deploy/guest/stage-patched-vgpu-driver.ps1"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[[ -f "$GUEST" ]] || fail "missing guest pre-stager: $GUEST"

require_text() {
    local pattern=$1
    grep -Fq -- "$pattern" "$GUEST" || fail "missing required text: $pattern"
}

reject_text() {
    local pattern=$1
    if grep -Fiq -- "$pattern" "$GUEST"; then
        fail "unsafe text is present: $pattern"
    fi
}

require_text 'DISABLED: the legacy pre-stager was removed'
require_text 'hash-locked, unmodified'
require_text 'never changes BCD, certificates, DriverStore, devices, or files'

reject_text 'New-SelfSignedCertificate'
reject_text 'Set-AuthenticodeSignature'
reject_text 'New-FileCatalog'
reject_text 'Import-Certificate'
reject_text 'pnputil'
reject_text '/install'
reject_text '/delete-driver'
reject_text '/uninstall'
reject_text 'testsigning'
reject_text 'nointegritychecks'
reject_text 'CN=NVIDIA Corporation'
reject_text 'CN=QEMU vGPU Guest Driver Signing'
reject_text 'CN=VM3 vGPU Test Driver Signing'

echo 'PASS: legacy self-signed vGPU pre-stager implementation is absent'
