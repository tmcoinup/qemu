#!/usr/bin/env bash
# Hyper-V CPU 资源/拓扑 profile、关机门禁、回读和事务回滚。
# shellcheck disable=SC2016
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
MODULE="$REPO_ROOT/deploy/windows/gpup/VMate.HyperV.ComputeProfile.ps1"
ENTRY="$REPO_ROOT/deploy/windows/gpup/Set-VMateGpuPComputeProfile.ps1"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

require_text() {
    rg -F --quiet -- "$1" "$2" || fail "missing '$1' in $2"
}

for file in "$MODULE" "$ENTRY"; do
    [[ -f "$file" ]] || fail "missing CPU profile file: $file"
    [[ "$(od -An -tx1 -N3 "$file" | tr -d ' \n')" == efbbbf ]] ||
        fail "PowerShell 5.1 UTF-8 BOM missing: $file"
    [[ "$(wc -l < "$file")" -le 500 ]] ||
        fail "CPU profile file exceeds 500 lines: $file"
    if rg -n '\b(Read-Host|PromptForChoice|Start-VM|Stop-VM)\b' "$file"; then
        fail "interactive/runtime CPU mutation path in $file"
    fi
done

for name in New-VMateHyperVComputeProfile ConvertTo-VMateHyperVComputeProfile Get-VMateHyperVComputeSnapshot Test-VMateHyperVComputeProfileMatch Set-VMateHyperVComputeProfile; do
    require_text "function $name" "$MODULE"
done
require_text "[string]\$VM.State -cne 'Off'" "$MODULE"
require_text '-ExposeVirtualizationExtensions' "$MODULE"
require_text '-HwThreadCountPerCore' "$MODULE"
require_text 'CPU profile 写入后的回读不一致' "$MODULE"
require_text '已回滚原值' "$MODULE"
require_text "CpuIdentityPolicy = 'host-managed-read-only'" "$MODULE"
if rg -n '(ProcessorNameString|CPUID|Win32_Processor|Set-ItemProperty)' "$ENTRY"; then
    fail 'public CPU profile command attempts identity projection'
fi

powershell_bin="$(command -v pwsh || command -v powershell || true)"
if [[ -z "$powershell_bin" ]]; then
    echo 'SKIP: PowerShell not found; static compute profile contract passed'
    exit 0
fi

VMATE_COMPUTE_PROFILE="$MODULE" "$powershell_bin" -NoLogo -NoProfile -NonInteractive -Command '
$ErrorActionPreference = "Stop"
. $env:VMATE_COMPUTE_PROFILE

function Assert-Equal {
    param([object]$Actual, [object]$Expected, [string]$Message)
    if ([string]$Actual -cne [string]$Expected) {
        throw "$Message actual=$Actual expected=$Expected"
    }
}
function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern)
    try { & $Action } catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw }
        return
    }
    throw "expected failure: $Pattern"
}

$script:Processor = [pscustomobject]@{
    Count = 2; Maximum = 100; Reserve = 0; RelativeWeight = 100
    HwThreadCountPerCore = 1; ExposeVirtualizationExtensions = $false
}
$script:Mutations = 0
$script:FailAfterMutation = $false
function Get-Command {
    param([string]$Name, [object]$ErrorAction)
    $parameters = @{}
    foreach ($key in "Count", "Maximum", "Reserve", "RelativeWeight",
        "HwThreadCountPerCore", "ExposeVirtualizationExtensions") {
        $parameters[$key] = $true
    }
    [pscustomobject]@{ Name = $Name; Parameters = $parameters }
}
function Get-VMProcessor {
    param([object]$VM, [object]$ErrorAction)
    return $script:Processor
}
function Set-VMProcessor {
    param(
        [object]$VM, [int]$Count, [int]$Maximum, [int]$Reserve,
        [int]$RelativeWeight, [int]$HwThreadCountPerCore,
        [Nullable[bool]]$ExposeVirtualizationExtensions,
        [switch]$Confirm, [object]$ErrorAction
    )
    $script:Mutations++
    $script:Processor.Count = $Count
    $script:Processor.Maximum = $Maximum
    $script:Processor.Reserve = $Reserve
    $script:Processor.RelativeWeight = $RelativeWeight
    $script:Processor.HwThreadCountPerCore = $HwThreadCountPerCore
    $script:Processor.ExposeVirtualizationExtensions =
        [bool]$ExposeVirtualizationExtensions
    if ($script:FailAfterMutation -and $script:Mutations -eq 1) {
        throw "injected setter failure"
    }
}

$oldOs = $env:OS
$env:OS = "Windows_NT"
try {
    $vm = [pscustomobject]@{ Name = "test"; State = "Off" }
    $profile = New-VMateHyperVComputeProfile -ProcessorCount 8 -CpuMaximumPercent 80 -CpuReservePercent 10 -CpuRelativeWeight 200 -HwThreadCountPerCore 2 -ExposeVirtualizationExtensions $true
    $dry = Set-VMateHyperVComputeProfile $vm $profile -DryRun
    Assert-Equal $dry.Status DryRun "DryRun status"
    Assert-Equal $script:Mutations 0 "DryRun mutated state"
    $applied = Set-VMateHyperVComputeProfile $vm $profile
    Assert-Equal $applied.Status Applied "apply status"
    Assert-Equal $script:Processor.Count 8 "processor count"
    Assert-Equal $script:Processor.Maximum 80 "maximum"
    Assert-Equal $script:Processor.HwThreadCountPerCore 2 "SMT topology"
    Assert-Equal $script:Processor.ExposeVirtualizationExtensions $true "nested virtualization"
    $unchanged = Set-VMateHyperVComputeProfile $vm $profile
    Assert-Equal $unchanged.Status Unchanged "idempotent status"
    Assert-Equal $script:Mutations 1 "idempotent path mutated"

    $beforeFailure = New-VMateHyperVComputeProfile -ProcessorCount 8 -CpuMaximumPercent 80 -CpuReservePercent 10 -CpuRelativeWeight 200 -HwThreadCountPerCore 2 -ExposeVirtualizationExtensions $true
    $failureProfile = New-VMateHyperVComputeProfile -ProcessorCount 4
    $script:FailAfterMutation = $true
    $script:Mutations = 0
    Assert-Throws {
        Set-VMateHyperVComputeProfile $vm $failureProfile
    } "已回滚原值"
    $restored = Get-VMateHyperVComputeSnapshot $vm
    if (-not (Test-VMateHyperVComputeProfileMatch $restored $beforeFailure)) {
        throw "failure path did not restore CPU snapshot"
    }
    $vm.State = "Running"
    Assert-Throws {
        Set-VMateHyperVComputeProfile $vm $profile
    } "必须为 Off"
    Assert-Throws {
        New-VMateHyperVComputeProfile -CpuMaximumPercent 20 -CpuReservePercent 30
    } "Reserve"
} finally {
    $env:OS = $oldOs
}
'

echo 'PASS: Hyper-V compute profile contract'
