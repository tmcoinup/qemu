#!/usr/bin/env bash
# P-11 21 套 SMBIOS 身份启动扩展、可复现 EFI 与回滚状态机回归。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
MODULE="$REPO_ROOT/deploy/windows/gpup/VMate.HyperV.IdentityBoot.ps1"
SUPPORT="$REPO_ROOT/deploy/windows/gpup/VMate.HyperV.IdentityBoot.Support.ps1"
PROFILE_MODULE="$REPO_ROOT/deploy/windows/gpup/VMate.GpuP.HardwareProfile.ps1"
CATALOG="$REPO_ROOT/deploy/hardware/p11-platforms.json"
EFI="$REPO_ROOT/deploy/windows/gpup/firmware/bin/VMateIdentityBoot.efi"
EFI_HASH="$EFI.sha256"
DYNAMIC_TEST="$SCRIPT_DIR/test_windows_hyperv_identity_boot.ps1"
BUILD="$REPO_ROOT/deploy/tools/build-vmate-hyperv-identity-efi.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
require_text() {
    rg -F --quiet -- "$1" "$2" || fail "missing '$1' in $2"
}

for path in "$MODULE" "$SUPPORT" "$PROFILE_MODULE" "$CATALOG" "$EFI" "$EFI_HASH" \
    "$DYNAMIC_TEST" "$BUILD"; do
    [[ -f "$path" ]] || fail "missing identity boot asset: $path"
done
[[ "$(od -An -tx1 -N3 "$MODULE" | tr -d ' \n')" == efbbbf ]] || \
    fail 'identity boot module lacks Windows PowerShell 5.1 UTF-8 BOM'
[[ "$(od -An -tx1 -N3 "$SUPPORT" | tr -d ' \n')" == efbbbf ]] || \
    fail 'identity boot support module lacks Windows PowerShell 5.1 UTF-8 BOM'
[[ "$(od -An -tx1 -N3 "$DYNAMIC_TEST" | tr -d ' \n')" == efbbbf ]] || \
    fail 'identity boot dynamic test lacks Windows PowerShell 5.1 UTF-8 BOM'
for path in "$MODULE" "$SUPPORT"; do
    (( $(wc -l < "$path") <= 500 )) || fail "identity boot file exceeds 500 lines: $path"
done
file "$EFI" | rg -q 'PE32\+ executable.*EFI application' || \
    fail 'identity boot payload is not an x64 EFI application'

expected_hash="$(awk 'NR == 1 { print toupper($1) }' "$EFI_HASH")"
actual_hash="$(sha256sum "$EFI" | awk '{ print toupper($1) }')"
[[ "$actual_hash" == "$expected_hash" ]] || fail 'packaged EFI hash mismatch'
[[ "$actual_hash" == \
   4D58562E0AC7E86FCA1A47392EC4B5E64B602BB870CE0922D858348D6C52563B ]] || \
    fail 'packaged EFI does not match the canonical reproducible artifact'

for name in New-VMateHyperVIdentityBootConfig \
    Import-VMateHyperVIdentityBootConfig; do
    require_text "function $name" "$SUPPORT"
done
for name in Install-VMateHyperVIdentityBoot Uninstall-VMateHyperVIdentityBoot \
    Get-VMateHyperVIdentityBootStatus; do
    require_text "function $name" "$MODULE"
done
require_text "State = 'Installed'" "$MODULE"
require_text "'Uninstalled'" "$MODULE"
require_text 'verified-file-backup-no-checkpoint' "$MODULE"
require_text 'Get-AuthenticodeSignature' "$MODULE"
require_text 'AllowDisableSecureBoot' "$MODULE"
require_text '} -ReadOnly' "$MODULE"
require_text "FieldCount = \$fields.Count" "$SUPPORT"
require_text 'guest-boot-smbios-only' "$MODULE"
require_text 'preserve-first-installed-no-reroll' "$SUPPORT"
require_text '"$GENFW" -z -r' "$BUILD"
if rg -qi 'checkpoint|snapshot' "$MODULE" &&
   ! rg -q 'no-checkpoint|不支持 checkpoint' "$MODULE"; then
    fail 'identity boot module depends on an unsafe GPU-P checkpoint'
fi

powershell_bin="$(command -v pwsh || command -v powershell || true)"
if [[ -n "$powershell_bin" ]]; then
    "$powershell_bin" -NoLogo -NoProfile -NonInteractive -File "$DYNAMIC_TEST" \
        -IdentityBootModule "$MODULE" \
        -HardwareProfileModule "$PROFILE_MODULE" \
        -HardwareCatalog "$CATALOG"
else
    echo 'SKIP: PowerShell not found; identity boot static contract passed'
fi

echo 'PASS: Windows Hyper-V identity boot static/reproducible contract'
