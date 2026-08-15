#!/usr/bin/env bash
# P-11 固件/MAC 统一身份的持久化、唯一性和恢复回归。
# shellcheck disable=SC2016 # PowerShell 合同字符串必须保持字面量 $。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
GPUP="$REPO_ROOT/deploy/windows/gpup"
MODULE="$GPUP/VMate.GpuP.HardwareIdentity.ps1"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

require_text() {
    rg -F --quiet -- "$1" "$2" || fail "missing '$1' in $2"
}

[[ -f "$MODULE" ]] || fail "missing hardware identity module"
[[ "$(wc -l < "$MODULE")" -le 500 ]] || fail "module exceeds 500 lines"
[[ "$(od -An -tx1 -N3 "$MODULE" | tr -d ' \n')" == efbbbf ]] || \
    fail "module lacks UTF-8 BOM"
require_text "PersistencePolicy = 'generate-once-no-reroll'" "$MODULE"
require_text 'State = '\''Prepared' "$MODULE"
require_text 'Ensure-VMateGpuPHardwareIdentity' "$MODULE"
require_text 'Restore-VMateHyperVFirmwareIdentitySnapshot' "$MODULE"
require_text 'Test-VMateGpuPHardwareIdentityUniqueness' "$MODULE"
if rg -n '(qemu|vfio|nvapi|adl|Set-ItemProperty|New-ItemProperty)' "$MODULE"; then
    fail 'hardware identity module contains a forbidden legacy/projection path'
fi

powershell_bin="$(command -v pwsh || command -v powershell || true)"
if [[ -z "$powershell_bin" ]]; then
    echo 'SKIP: PowerShell not found; hardware identity static contract passed'
    exit 0
fi

VMATE_HARDWARE_IDENTITY="$MODULE" \
    "$powershell_bin" -NoLogo -NoProfile -NonInteractive -Command '
$ErrorActionPreference = "Stop"
. $env:VMATE_HARDWARE_IDENTITY

$script:adapters = @{}
function Assert-VMateHyperVNetworkIdentityHost {}
function Get-VMNetworkAdapter {
    param([object]$VM, [switch]$All, [switch]$ManagementOS,
        [string]$ErrorAction)
    if ($All -or $ManagementOS) { return @() }
    return @($script:adapters[[string]$VM.Id])
}
function New-MockAdapter([Guid]$VMId, [string]$Id) {
    [pscustomobject]@{
        Id = $Id; Name = "Network Adapter"; VMId = $VMId.ToString("D")
        MacAddress = ""; DynamicMacAddressEnabled = $true
    }
}
$script:firmwareRestoreCalls = 0
$script:expectedRestoreVmId = [Guid]::Empty
function Invoke-VMateHyperVFirmwareIdentityTransaction {
    param([Guid]$VMId, [object]$Identity, [int]$JobTimeoutSeconds)
    [pscustomobject]@{
        Status = "Applied"; Requested = $Identity
        Previous = [pscustomobject]@{
            BIOSGUID = "{00000000-0000-0000-0000-000000000001}"
            BIOSSerialNumber = "OLD-BIOS"
            BaseBoardSerialNumber = "OLD-BOARD"
            ChassisSerialNumber = "OLD-CHASSIS"
            ChassisAssetTag = "OLD-ASSET"
        }
        Observed = $Identity
    }
}
$script:failNetworkOnce = $false
function Restore-VMateHyperVFirmwareIdentitySnapshot {
    param([Guid]$VMId, [object]$Snapshot, [int]$JobTimeoutSeconds)
    if ($VMId -ne $script:expectedRestoreVmId -or
        [string]$Snapshot.BIOSSerialNumber -cne "OLD-BIOS") {
        throw "firmware compensation received the wrong snapshot"
    }
    $script:firmwareRestoreCalls++
    [pscustomobject]@{ Status = "Restored" }
}
function Set-VMateHyperVNetworkIdentity {
    param([object]$VM, [object]$NetworkIdentity, [string]$StateRoot)
    if ($script:failNetworkOnce) {
        $script:failNetworkOnce = $false
        throw "injected network identity failure"
    }
    $rows = @($NetworkIdentity.NetworkAdapters | ForEach-Object {
        [pscustomobject]@{
            AdapterId = $_.AdapterId; Expected = $_.StaticMacAddress
            Actual = $_.StaticMacAddress; Dynamic = $false; Match = $true
        }
    })
    [pscustomobject]@{
        Status = if ($rows.Count) { "Applied" } else { "NotPresent" }
        Changed = $rows.Count
        Observed = [pscustomobject]@{
            Status = if ($rows.Count) { "Observed" } else { "NotPresent" }
            NetworkAdapters = $rows; UnexpectedAdapterIds = @(); Match = $true
        }
    }
}

$root = Join-Path ([IO.Path]::GetTempPath()) `
    ("vmate-hardware-identity-" + [Guid]::NewGuid().ToString("N"))
try {
    $vmA = [pscustomobject]@{ Id = [Guid]::NewGuid(); State = "Off" }
    $vmB = [pscustomobject]@{ Id = [Guid]::NewGuid(); State = "Off" }
    $script:adapters[[string]$vmA.Id] = New-MockAdapter $vmA.Id "nic-a"
    $script:adapters[[string]$vmB.Id] = New-MockAdapter $vmB.Id "nic-b"
    Initialize-VMateGpuPIdentity $vmA.Id NVIDIA -StateRoot $root | Out-Null
    Initialize-VMateGpuPIdentity $vmB.Id AMD -StateRoot $root | Out-Null

    $first = Initialize-VMateGpuPHardwareIdentity $vmA -StateRoot $root
    $pathA = Get-VMateGpuPIdentityPath $vmA.Id $root
    $rawBefore = Get-Content -LiteralPath $pathA -Raw
    $again = Initialize-VMateGpuPHardwareIdentity $vmA -StateRoot $root
    $rawAfter = Get-Content -LiteralPath $pathA -Raw
    if ($rawBefore -cne $rawAfter -or
        $first.Firmware.BIOSGUID -cne $again.Firmware.BIOSGUID -or
        $first.NetworkAdapters[0].StaticMacAddress -cne
            $again.NetworkAdapters[0].StaticMacAddress) {
        throw "same VM rerolled hardware identity"
    }
    $second = Initialize-VMateGpuPHardwareIdentity $vmB -StateRoot $root
    if ($first.Firmware.BIOSGUID -eq $second.Firmware.BIOSGUID -or
        $first.Firmware.BIOSSerialNumber -eq
            $second.Firmware.BIOSSerialNumber -or
        $first.NetworkAdapters[0].StaticMacAddress -eq
            $second.NetworkAdapters[0].StaticMacAddress) {
        throw "different VMs received the same hardware identity"
    }
    $mac = [string]$first.NetworkAdapters[0].StaticMacAddress
    if ($mac -notmatch "^02[0-9A-F]{10}$") {
        throw "generated MAC is not local unicast"
    }
    $observed = [pscustomobject]@{
        Firmware = $first.Firmware
        Network = [pscustomobject]@{ Match = $true }
        Match = $true
    }
    $applied = Complete-VMateGpuPHardwareIdentity $vmA.Id $observed $root
    if ($applied.State -ne "Applied" -or -not $applied.HostObserved.Match) {
        throw "hardware identity was not completed"
    }
    $persisted = Get-VMateGpuPHardwareIdentity $vmA.Id -StateRoot $root
    if ($persisted.State -ne "Applied" -or
        $persisted.Firmware.BIOSGUID -ne $first.Firmware.BIOSGUID) {
        throw "applied identity was not persisted"
    }
    $audit = Test-VMateGpuPHardwareIdentityUniqueness -StateRoot $root
    if (-not $audit.IsUnique -or $audit.Records -ne 2) {
        throw "hardware identity uniqueness audit failed"
    }

    # 固件写入成功而网络阶段失败时，必须补偿固件；Prepared 清单保留原随机值，
    # 下一次 Ensure 使用同一组 GUID/serial/MAC 完成恢复，不能重新抽取。
    $vmRecovery = [pscustomobject]@{ Id = [Guid]::NewGuid(); State = "Off" }
    $script:adapters[[string]$vmRecovery.Id] =
        New-MockAdapter $vmRecovery.Id "nic-recovery"
    Initialize-VMateGpuPIdentity $vmRecovery.Id NVIDIA `
        -StateRoot $root | Out-Null
    $script:expectedRestoreVmId = $vmRecovery.Id
    $script:failNetworkOnce = $true
    $failedAsExpected = $false
    try {
        Ensure-VMateGpuPHardwareIdentity $vmRecovery `
            -StateRoot $root | Out-Null
    } catch {
        if ($_.Exception.Message -notmatch "injected network identity failure") {
            throw
        }
        $failedAsExpected = $true
    }
    if (-not $failedAsExpected -or $script:firmwareRestoreCalls -ne 1) {
        throw "cross-layer firmware compensation did not run exactly once"
    }
    $prepared = Get-VMateGpuPHardwareIdentity $vmRecovery.Id `
        -StateRoot $root
    if ($prepared.State -cne "Prepared") {
        throw "failed hardware transaction did not remain Prepared"
    }
    $preparedGuid = [string]$prepared.Firmware.BIOSGUID
    $preparedMac = [string]$prepared.NetworkAdapters[0].StaticMacAddress
    $recovered = Ensure-VMateGpuPHardwareIdentity $vmRecovery `
        -StateRoot $root
    if ($recovered.Status -cne "Applied" -or
        -not [bool]$recovered.HostObserved.Match -or
        [string]$recovered.Desired.Firmware.BIOSGUID -cne $preparedGuid -or
        [string]$recovered.Desired.NetworkAdapters[0].StaticMacAddress -cne
            $preparedMac) {
        throw "Prepared retry rerolled or failed to apply hardware identity"
    }

    $pathB = Get-VMateGpuPIdentityPath $vmB.Id $root
    $recordB = Get-Content -LiteralPath $pathB -Raw | ConvertFrom-Json
    $recordB.HardwareIdentity.Firmware.BIOSGUID =
        $first.Firmware.BIOSGUID
    Write-VMateGpuPAtomicJson $recordB $pathB | Out-Null
    $audit = Test-VMateGpuPHardwareIdentityUniqueness -StateRoot $root
    if ($audit.IsUnique -or $audit.Collisions.Count -ne 1) {
        throw "injected collision was not detected"
    }

    $vmRunning = [pscustomobject]@{ Id = $vmA.Id; State = "Running" }
    try {
        Initialize-VMateGpuPHardwareIdentity $vmRunning -StateRoot $root
        throw "running VM was accepted"
    } catch {
        if ($_.Exception.Message -eq "running VM was accepted") { throw }
    }

    $badId = [Guid]::NewGuid()
    $badPath = Get-VMateGpuPIdentityPath $badId $root
    $badRecord = [pscustomobject]@{
        SchemaVersion = 99; VMId = $badId.ToString("D"); Vendor = "NVIDIA"
        PartitionIdentitySeed = "bad"
        PhysicalGpuSerialPolicy = "bad"
    }
    Write-VMateGpuPAtomicJson $badRecord $badPath | Out-Null
    foreach ($auditAction in @(
        { Test-VMateGpuPIdentityUniqueness -StateRoot $root | Out-Null },
        { Test-VMateGpuPHardwareIdentityUniqueness -StateRoot $root | Out-Null },
        { Get-VMateHyperVReservedNetworkIdentity -StateRoot $root | Out-Null }
    )) {
        try {
            & $auditAction
            throw "damaged base identity was ignored"
        } catch {
            if ($_.Exception.Message -eq "damaged base identity was ignored") {
                throw
            }
        }
    }
    Remove-Item -LiteralPath ([IO.Path]::GetDirectoryName($badPath)) `
        -Recurse -Force

    $badHardwareId = [Guid]::NewGuid()
    Initialize-VMateGpuPIdentity $badHardwareId NVIDIA `
        -StateRoot $root | Out-Null
    $badHardwarePath = Get-VMateGpuPIdentityPath $badHardwareId $root
    $badHardware = Read-VMateGpuPIdentityManifest $badHardwarePath
    $badHardware | Add-Member -NotePropertyName HardwareIdentity `
        -NotePropertyValue $null
    Write-VMateGpuPAtomicJson $badHardware $badHardwarePath | Out-Null
    foreach ($auditAction in @(
        { Test-VMateGpuPHardwareIdentityUniqueness -StateRoot $root | Out-Null },
        { Get-VMateHyperVReservedNetworkIdentity -StateRoot $root | Out-Null }
    )) {
        try {
            & $auditAction
            throw "null hardware identity was ignored"
        } catch {
            if ($_.Exception.Message -eq "null hardware identity was ignored") {
                throw
            }
        }
    }
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
'

echo 'PASS: Windows GPU-P hardware identity persistence contract'
