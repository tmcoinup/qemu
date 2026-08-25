#!/usr/bin/env bash
# P-11 guest 冷启动固件/MAC 回读与匹配合同。
# shellcheck disable=SC2016 # PowerShell 片段必须保留字面量 $。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
MODULE="$REPO_ROOT/deploy/windows/gpup/VMate.GpuP.GuestIdentity.ps1"

fail() { echo "FAIL: $*" >&2; exit 1; }
require_text() {
    rg -F --quiet -- "$1" "$2" || fail "missing '$1' in $2"
}

[[ -f "$MODULE" ]] || fail "missing guest identity module"
[[ "$(wc -l < "$MODULE")" -le 300 ]] || fail "module exceeds 300 lines"
[[ "$(od -An -tx1 -N3 "$MODULE" | tr -d ' \n')" == efbbbf ]] || \
    fail "module lacks UTF-8 BOM"
require_text 'WindowsCimColdBootReadback' "$MODULE"
require_text 'Win32_BIOS' "$MODULE"
require_text 'Win32_BaseBoard' "$MODULE"
require_text 'Win32_SystemEnclosure' "$MODULE"
require_text 'Win32_ComputerSystemProduct' "$MODULE"
require_text 'Win32_NetworkAdapter' "$MODULE"
require_text 'Test-VMateGpuPGuestHardwareIdentityMatch' "$MODULE"
require_text 'HypervisorPresent' "$MODULE"
if rg -n 'Set-ItemProperty|New-ItemProperty|Remove-Item|Disable-PnpDevice|'\
'Enable-PnpDevice|reg(\.exe)?[[:space:]]+add|Invoke-WebRequest' "$MODULE"; then
    fail 'guest identity readback contains a mutation or download path'
fi

powershell_bin="$(command -v pwsh || command -v powershell || true)"
if [[ -z "$powershell_bin" ]]; then
    echo 'SKIP: PowerShell not found; guest identity static contract passed'
    exit 0
fi

VMATE_GPUP_GUEST_IDENTITY="$MODULE" \
    "$powershell_bin" -NoLogo -NoProfile -NonInteractive -Command '
$ErrorActionPreference = "Stop"
. $env:VMATE_GPUP_GUEST_IDENTITY

function Get-CimInstance {
    param([string]$ClassName, $ErrorAction)
    switch ($ClassName) {
        "Win32_BIOS" { return [pscustomobject]@{
                SerialNumber = "BIOS-001"; Manufacturer = "Microsoft Corporation"
            } }
        "Win32_BaseBoard" { return [pscustomobject]@{
                SerialNumber = "BOARD-001"; Manufacturer = "Microsoft Corporation"
                Product = "Virtual Machine"
            } }
        "Win32_SystemEnclosure" { return [pscustomobject]@{
                SerialNumber = "CHASSIS-001"; SMBIOSAssetTag = "ASSET-001"
            } }
        "Win32_ComputerSystemProduct" { return [pscustomobject]@{
                UUID = "12345678-1234-4234-9234-1234567890ab"
            } }
        "Win32_ComputerSystem" { return [pscustomobject]@{
                Manufacturer = "Microsoft Corporation"; Model = "Virtual Machine"
                HypervisorPresent = $true
            } }
        "Win32_NetworkAdapter" { return [pscustomobject]@{
                Name = "Microsoft Hyper-V Network Adapter"; PNPDeviceID = "VMBUS"
                PhysicalAdapter = $true; MACAddress = "02-AA-BB-CC-DD-EE"
            } }
        "Win32_Processor" { return [pscustomobject]@{
                Name = "Genuine CPU"; Manufacturer = "GenuineIntel"
                NumberOfCores = 10; NumberOfLogicalProcessors = 20
            } }
        default { throw "unexpected CIM class: $ClassName" }
    }
}

$snapshot = Get-VMateGpuPGuestHardwareIdentitySnapshot
$expected = [pscustomobject]@{
    Firmware = [pscustomobject]@{
        BIOSGUID = "{12345678-1234-4234-9234-1234567890AB}"
        BIOSSerialNumber = "BIOS-001"
        BaseBoardSerialNumber = "BOARD-001"
        ChassisSerialNumber = "CHASSIS-001"
        ChassisAssetTag = "ASSET-001"
    }
    NetworkAdapters = @([pscustomobject]@{
            StaticMacAddress = "02AABBCCDDEE"
        })
}
$match = Test-VMateGpuPGuestHardwareIdentityMatch $expected $snapshot
if (-not $match.Match -or $match.Mismatches.Count -ne 0 -or
    $match.Firmware.BIOSGUID -cne
        "{12345678-1234-4234-9234-1234567890AB}" -or
    $match.NetworkAdapters[0].MACAddress -cne "02AABBCCDDEE") {
    throw "valid guest hardware identity was rejected"
}
$wrong = $expected | Select-Object *
$wrong.Firmware = $expected.Firmware | Select-Object *
$wrong.Firmware.ChassisAssetTag = "WRONG-ASSET"
$mismatch = Test-VMateGpuPGuestHardwareIdentityMatch $wrong $snapshot
if ($mismatch.Match -or
    "Firmware.ChassisAssetTag" -notin @($mismatch.Mismatches)) {
    throw "firmware mismatch was not reported"
}
$wrongNetwork = $expected | Select-Object *
$wrongNetwork.NetworkAdapters = @([pscustomobject]@{
        StaticMacAddress = "02AABBCCDDEF"
    })
$mismatch = Test-VMateGpuPGuestHardwareIdentityMatch $wrongNetwork $snapshot
if ($mismatch.Match -or
    "NetworkAdapters.MACAddress" -notin @($mismatch.Mismatches)) {
    throw "MAC mismatch was not reported"
}
'

echo 'PASS: Windows GPU-P guest hardware identity readback contract'
