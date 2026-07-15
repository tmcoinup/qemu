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

require_text 'c7e38910c800fc9f5e72ec4d3613594a64b3e7b0465114e81a167ead43d42e4f'
require_text '084f162bc01527da46f98525ab0e85eec0b3c3086b39f3b18949ec4985f4e72d'
require_text '67828f58171181da3b12a7b481e1251ed8255a34de78d7118fa9ac3781663c15'
require_text 'PCI\VEN_10DE&DEV_1C81&SUBSYS_11C01028'
require_text '-Type CodeSigningCert'
require_text 'CN=QEMU vGPU Guest Driver Signing'
require_text 'Test-FileCatalog -Path $driverRoot'
require_text 'Set-AuthenticodeSignature -LiteralPath $catalogTemporary'
require_text '& pnputil.exe /add-driver $infPath'
require_text 'Catalog differs from the vendor artifact without valid prior stage state.'
require_text 'QEMU_VGPU_DRIVER_STAGE_V1'
require_text 'DRIVER_INF=$($published[0].Name)'
require_text '538.33-gtx1050_2gb.receipt'

reject_text '/install'
reject_text '/delete-driver'
reject_text '/uninstall'
reject_text 'testsigning'
reject_text 'nointegritychecks'
reject_text 'CN=NVIDIA Corporation'
reject_text 'CN=VM3 vGPU Test Driver Signing'

echo 'PASS: patched vGPU guest pre-stager safety invariants'
