#!/usr/bin/env bash
# P-11 客户端接管：只读核对稳定 VM/VHD/identity/profile，不猜测普通 Hyper-V VM。
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
repo=$(cd -- "$script_dir/../../.." && pwd)
module="$repo/deploy/windows/gpup/VMate.GpuP.ClientInventory.ps1"

fail() { echo "FAIL: $*" >&2; exit 1; }
contains() { rg -F --quiet -- "$1" "$module" || fail "missing '$1'"; }
rejects() { ! rg -n -- "$1" "$module" || fail "unexpected mutation '$1'"; }

[[ -s "$module" ]] || fail "missing client inventory module"
[[ "$(od -An -tx1 -N3 "$module" | tr -d ' \n')" == efbbbf ]] ||
    fail "PowerShell 5.1 UTF-8 BOM missing"
(( $(wc -l < "$module") <= 180 )) || fail "client inventory module is too large"

for text in \
    'function Get-VMateGpuPClientInspection' \
    "ValidatePattern('^VMate-P11-" \
    'Get-VMHardDiskDrive -VM $vm' \
    'Get-VMateGpuPIdentity -VMId' \
    'Get-VMateGpuPHardwareProfileBinding -VMId' \
    'Assert-VMateGpuPHardwareProfileOverrides' \
    'ManagedCandidate = $true' \
    'FullIdentitySupported = [bool]$binding.FullIdentitySupported' \
    'RuntimeModelSwitch = $false'; do
    contains "$text"
done

rejects '(^|[^A-Za-z])(New-VM|Set-VM|Remove-VM|Start-VM|Stop-VM|Add-VM|Remove-Item|Set-Content|New-Item)([^A-Za-z]|$)'

powershell_bin=$(command -v pwsh || command -v powershell || true)
if [[ -n "$powershell_bin" ]]; then
    VMATE_P11_INVENTORY="$module" "$powershell_bin" -NoLogo -NoProfile \
        -NonInteractive -Command '
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile(
            $env:VMATE_P11_INVENTORY, [ref]$null, [ref]$errors)
        if ($errors.Count) { throw ($errors | Out-String) }
        '
fi

echo 'PASS: P-11 read-only client inventory contract'
