#!/usr/bin/env bash
# Win10 Hyper-V MMIO null 回读兼容与严格 VSSD 校验合同。
# shellcheck disable=SC2016
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
MODULE="$REPO_ROOT/deploy/windows/gpup/VMate.GpuP.VMConfiguration.ps1"

fail() { echo "FAIL: $*" >&2; exit 1; }
require_text() {
    rg -F --quiet -- "$1" "$2" || fail "missing '$1' in $2"
}

[[ -f "$MODULE" ]] || fail 'missing VM configuration module'
[[ "$(wc -l < "$MODULE")" -le 250 ]] || fail 'module exceeds 250 lines'
[[ "$(od -An -tx1 -N3 "$MODULE" | tr -d ' \n')" == efbbbf ]] || \
    fail 'module lacks UTF-8 BOM'
require_text 'Msvm_VirtualSystemSettingData' "$MODULE"
require_text 'LowMmioGapSize' "$MODULE"
require_text 'HighMmioGapSize' "$MODULE"
require_text "'Microsoft:Hyper-V:System:Realized'" "$MODULE"
require_text "'HyperVCmdlet+VSSD'" "$MODULE"
require_text 'Test-VMateGpuPVMConfigurationMatch' "$MODULE"
require_text 'Assert-VMateGpuPAppliedState' "$MODULE"
if rg -n 'Set-VM|Add-VMGpu|Remove-VMGpu|Start-VM|Stop-VM' "$MODULE"; then
    fail 'readback module contains a Hyper-V mutation'
fi

powershell_bin="$(command -v pwsh || command -v powershell || true)"
if [[ -z "$powershell_bin" ]]; then
    echo 'SKIP: PowerShell not found; VM configuration static contract passed'
    exit 0
fi

VMATE_GPUP_VM_CONFIGURATION="$MODULE" \
    "$powershell_bin" -NoLogo -NoProfile -NonInteractive -Command '
$ErrorActionPreference = "Stop"
. $env:VMATE_GPUP_VM_CONFIGURATION

$vm = [pscustomobject]@{
    Id = [Guid]::NewGuid(); Name = "mock-vm"
    GuestControlledCacheTypes = $true
    LowMemoryMappedIoSpace = $null
    HighMemoryMappedIoSpace = [uint64]34359738368
    CheckpointType = "Disabled"
}
function Get-CimInstance {
    param($Namespace, $ClassName, $Filter, $ErrorAction)
    if ($ClassName -ne "Msvm_VirtualSystemSettingData") {
        throw "unexpected CIM class: $ClassName"
    }
    [pscustomobject]@{
        VirtualSystemIdentifier = $vm.Id.ToString("D")
        VirtualSystemType = "Microsoft:Hyper-V:System:Realized"
        LowMmioGapSize = [uint64]1024
        HighMmioGapSize = [uint64]32768
    }
}
$snapshot = Get-VMateGpuPVMConfigurationSnapshot $vm
$plan = [pscustomobject]@{
    LowMemoryMappedIoSpace = [uint64]1073741824
    HighMemoryMappedIoSpace = [uint64]34359738368
}
if ($snapshot.ReadbackSource -cne "HyperVCmdlet+VSSD" -or
    $snapshot.LowMemoryMappedIoSpace -ne [uint64]1073741824 -or
    -not (Test-VMateGpuPVMConfigurationMatch $snapshot $plan)) {
    throw "Win10 null MMIO fallback did not match exact VSSD bytes"
}
$plan.LowMemoryMappedIoSpace = [uint64]2147483648
if (Test-VMateGpuPVMConfigurationMatch $snapshot $plan) {
    throw "mismatched LowMMIO was accepted"
}
'

echo 'PASS: Windows GPU-P VM configuration readback contract'
