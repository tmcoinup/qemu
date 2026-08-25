#!/usr/bin/env bash
# P-11 GPU-P 冷启动隔离：十二项精确配额、状态边界与中断事务恢复。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
MODULE="$REPO_ROOT/deploy/windows/gpup/VMate.HyperV.GpuPColdStartIsolation.ps1"

fail() { echo "FAIL: $*" >&2; exit 1; }
[[ -s "$MODULE" ]] || fail "missing isolation module: $MODULE"
[[ "$(od -An -tx1 -N3 "$MODULE" | tr -d ' \n')" == efbbbf ]] ||
    fail 'PowerShell 5.1 UTF-8 BOM missing'

for text in \
    'vmate-p11-gpup-adapter-snapshot-v1' \
    'vmate-p11-gpup-cold-start-transaction-v1' \
    "@('VRAM', 'Encode', 'Decode', 'Compute')" \
    "@('Min', 'Max', 'Optimal')" \
    "-notin @('Off', 'Paused')" \
    "-cne 'Off'" \
    'Convert]::ToUInt64' \
    'cold-start-transactions'; do
    rg -F --quiet -- "$text" "$MODULE" || fail "missing contract text: $text"
done

powershell_bin="$(command -v pwsh || command -v powershell || true)"
if [[ -z "$powershell_bin" ]]; then
    echo 'SKIP: PowerShell not found; GPU-P isolation static contract passed'
    exit 0
fi

VMATE_GPUP_ISOLATION="$MODULE" \
"$powershell_bin" -NoLogo -NoProfile -NonInteractive -Command '
$ErrorActionPreference = "Stop"
. $env:VMATE_GPUP_ISOLATION

function Assert-True {
    param([bool]$Value, [string]$Message)
    if (-not $Value) { throw $Message }
}
function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern)
    try { & $Action } catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw }
        return
    }
    throw "expected failure: $Pattern"
}

$script:Vm = [pscustomobject]@{
    Name = "mock-p11"
    Id = [Guid]"282f1a79-363d-4267-a653-994d9b5d1d19"
    State = "Off"
}
$script:QuotaNames = @(Get-VMateHyperVGpuPQuotaNames)
$script:Quotas = [ordered]@{}
foreach ($name in $script:QuotaNames) {
    $script:Quotas[$name] = if ($name -like "*Encode") {
        [uint64]::MaxValue
    } else {
        [uint64]1000000000
    }
}
function New-MockAdapter {
    $values = [ordered]@{ Id = "mock-adapter" }
    foreach ($name in $script:QuotaNames) { $values[$name] = $script:Quotas[$name] }
    [pscustomobject]$values
}
$script:Adapter = New-MockAdapter
$script:Removed = $false
$script:AddParameters = $null

function Get-VM {
    param([string]$Name, [object]$ErrorAction)
    $script:Vm
}
function Get-VMGpuPartitionAdapter {
    param([object]$VM, [object]$ErrorAction)
    if ($null -ne $script:Adapter) { return $script:Adapter }
    @()
}
function Remove-VMGpuPartitionAdapter {
    param([object]$VMGpuPartitionAdapter, [switch]$Confirm, [object]$ErrorAction)
    $script:Adapter = $null
    $script:Removed = $true
}
function Add-VMGpuPartitionAdapter {
    param(
        [object]$VM, [switch]$Passthru, [switch]$Confirm,
        [object]$ErrorAction,
        [uint64]$MinPartitionVRAM, [uint64]$MaxPartitionVRAM,
        [uint64]$OptimalPartitionVRAM,
        [uint64]$MinPartitionEncode, [uint64]$MaxPartitionEncode,
        [uint64]$OptimalPartitionEncode,
        [uint64]$MinPartitionDecode, [uint64]$MaxPartitionDecode,
        [uint64]$OptimalPartitionDecode,
        [uint64]$MinPartitionCompute, [uint64]$MaxPartitionCompute,
        [uint64]$OptimalPartitionCompute
    )
    $script:AddParameters = $PSBoundParameters
    $script:Adapter = New-MockAdapter
    if ($Passthru) { $script:Adapter }
}
function Get-VMateGpuPHostPartitionableGpu {
    [pscustomobject]@{ Name = "PCIROOT(0)#PCI(0100)#PCI(0000)" }
}
function Stop-VM {
    param([object]$VM, [switch]$TurnOff, [switch]$Force,
        [switch]$Confirm, [object]$ErrorAction)
    $script:Vm.State = "Off"
}
function Get-CimInstance {
    param([string]$ClassName, [object]$ErrorAction)
    [pscustomobject]@{ LastBootUpTime = [DateTime]"2026-08-25T00:00:00Z" }
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("vmate-gpup-isolation-" + [Guid]::NewGuid().ToString("N"))
[IO.Directory]::CreateDirectory($tempRoot) | Out-Null
function Get-VMateHyperVGpuPColdStartTransactionPath {
    param([Guid]$VMId)
    Join-Path $tempRoot ($VMId.ToString("D") + ".json")
}

try {
    $gpuPath = "PCIROOT(0)#PCI(0100)#PCI(0000)"
    $snapshot = Get-VMateHyperVGpuPColdStartAdapterSnapshot `
        -VM $script:Vm -GpuInstancePath $gpuPath
    Assert-True ($snapshot.Quotas.MaxPartitionEncode -ceq
        [uint64]::MaxValue.ToString()) "UInt64.MaxValue was rounded"
    Assert-True (@($snapshot.Quotas.PSObject.Properties).Count -eq 12) `
        "snapshot did not preserve twelve quotas"

    Remove-VMateHyperVGpuPColdStartAdapter `
        -VM $script:Vm -Snapshot $snapshot
    Assert-True ($script:Removed -and $null -eq $script:Adapter) `
        "adapter was not detached while Off"
    [void](Add-VMateHyperVGpuPColdStartAdapter `
        -VM $script:Vm -Snapshot $snapshot)
    Assert-True ($script:AddParameters.MaxPartitionEncode -eq
        [uint64]::MaxValue) "restored quota lost UInt64 precision"
    Assert-True ($script:AddParameters.Count -ge 16) `
        "restore did not splat all twelve quotas"
    foreach ($name in $script:QuotaNames) {
        Assert-True ($script:AddParameters.ContainsKey($name)) `
            "restore omitted quota $name"
    }

    $script:Vm.State = "Paused"
    $script:Adapter = $null
    [void](Add-VMateHyperVGpuPColdStartAdapter `
        -VM $script:Vm -Snapshot $snapshot)
    Assert-True ($null -ne $script:Adapter) "paused hot-add was rejected"

    $script:Vm.State = "Running"
    $script:Adapter = $null
    Assert-Throws {
        Add-VMateHyperVGpuPColdStartAdapter `
            -VM $script:Vm -Snapshot $snapshot
    } "只允许在 Off/Paused"

    $script:Vm.State = "Off"
    $script:Adapter = New-MockAdapter
    $transaction = New-VMateHyperVGpuPColdStartTransaction `
        -VM $script:Vm -Snapshot $snapshot
    $transactionPath = Get-VMateHyperVGpuPColdStartTransactionPath $script:Vm.Id
    Assert-True (Test-Path -LiteralPath $transactionPath) `
        "transaction journal was not written"
    Remove-VMateHyperVGpuPColdStartAdapter `
        -VM $script:Vm -Snapshot $snapshot
    Set-VMateHyperVGpuPColdStartTransactionPhase `
        -Transaction $transaction -Phase "AdapterDetachedWhileOff"
    $script:Vm.State = "Running"
    $recovery = Repair-VMateHyperVGpuPColdStartTransaction -VM $script:Vm
    Assert-True ($recovery.Status -ceq "Recovered") "journal was not recovered"
    Assert-True ($script:Vm.State -ceq "Off") "recovery did not turn VM off"
    Assert-True ($null -ne $script:Adapter) "recovery did not restore adapter"
    Assert-True (-not (Test-Path -LiteralPath $transactionPath)) `
        "committed recovery left stale journal"
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force `
        -ErrorAction SilentlyContinue
}
'

echo 'PASS: Hyper-V GPU-P cold-start isolation contract'
