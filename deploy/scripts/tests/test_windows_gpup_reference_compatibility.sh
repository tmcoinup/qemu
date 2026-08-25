#!/usr/bin/env bash
# Win10 样例 100% 配额与 VMConnect 控制台配置的纯函数/事务回归。
# shellcheck disable=SC2016
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
COMMON="$REPO_ROOT/deploy/windows/gpup/VMate.GpuP.Common.ps1"
QUOTA="$REPO_ROOT/deploy/windows/gpup/VMate.GpuP.QuotaProfile.ps1"
CONSOLE="$REPO_ROOT/deploy/windows/gpup/VMate.HyperV.ConsoleProfile.ps1"

fail() { echo "FAIL: $*" >&2; exit 1; }
for file in "$QUOTA" "$CONSOLE"; do
    [[ -f "$file" ]] || fail "missing compatibility module: $file"
    [[ "$(od -An -tx1 -N3 "$file" | tr -d ' \n')" == efbbbf ]] || \
        fail "PowerShell 5.1 module lacks UTF-8 BOM: $file"
    (( $(wc -l < "$file") <= 250 )) || fail "module exceeds 250 lines: $file"
done
rg -F --quiet 'Win10Reference100' "$QUOTA" || fail 'missing reference quota mode'
rg -F --quiet '[uint64]::MaxValue' "$QUOTA" || fail 'missing encode sentinel guard'
rg -F --quiet 'Set-VMVideo' "$CONSOLE" || fail 'missing console mutation'
rg -F --quiet '已恢复原配置' "$CONSOLE" || fail 'missing console rollback'

powershell_bin="$(command -v pwsh || command -v powershell || true)"
if [[ -z "$powershell_bin" ]]; then
    echo 'SKIP: PowerShell not found; reference compatibility static contract passed'
    exit 0
fi

VMATE_GPUP_COMMON="$COMMON" VMATE_GPUP_QUOTA="$QUOTA" \
VMATE_HYPERV_CONSOLE="$CONSOLE" \
"$powershell_bin" -NoLogo -NoProfile -NonInteractive -Command '
$ErrorActionPreference = "Stop"
. $env:VMATE_GPUP_COMMON
. $env:VMATE_GPUP_QUOTA
. $env:VMATE_HYPERV_CONSOLE

function Assert-Fails([scriptblock]$Action, [string]$Pattern) {
    try { & $Action; throw "expected failure was accepted" } catch {
        if ($_.Exception.Message -eq "expected failure was accepted" -or
            $_.Exception.Message -notmatch $Pattern) { throw }
    }
}
$gpu = [pscustomobject]@{
    TotalVRAM=[uint64]1000000000; MinPartitionVRAM=[uint64]0
    MaxPartitionVRAM=[uint64]1000000000
    TotalEncode=[uint64]::MaxValue; MinPartitionEncode=[uint64]0
    MaxPartitionEncode=[uint64]::MaxValue
    TotalDecode=[uint64]1000000000; MinPartitionDecode=[uint64]0
    MaxPartitionDecode=[uint64]1000000000
    TotalCompute=[uint64]1000000000; MinPartitionCompute=[uint64]0
    MaxPartitionCompute=[uint64]1000000000
}
$request = Resolve-VMateGpuPQuotaCompatibilityRequest -Percentages @{
    VramPercentage=50; EncodePercentage=50
    DecodePercentage=50; ComputePercentage=50
} -Win10ReferenceGpuQuota
$plan = Get-VMateGpuPResourcePlanForRequest $gpu $request
if ($request.QuotaMode -cne "Win10Reference100" -or
    $plan.MaxPartitionVRAM -ne [uint64]1000000000 -or
    $plan.MaxPartitionEncode -ne [uint64]9223372036854775808 -or
    $plan.MaxPartitionDecode -ne [uint64]1000000000 -or
    $plan.MaxPartitionCompute -ne [uint64]1000000000) {
    throw "reference quota mapping is not exact"
}
Assert-Fails {
    Resolve-VMateGpuPQuotaCompatibilityRequest -Percentages @{
        VramPercentage=100; EncodePercentage=100
        DecodePercentage=100; ComputePercentage=100
    } -FullSharedGpuQuota -Win10ReferenceGpuQuota
} "不能同时"
Assert-Fails {
    Resolve-VMateGpuPQuotaCompatibilityRequest -Percentages @{
        VramPercentage=100; EncodePercentage=50
        DecodePercentage=100; ComputePercentage=100
    } -ExplicitNames EncodePercentage -Win10ReferenceGpuQuota
} "冲突"
$gpu.TotalEncode = [uint64]1000
$gpu.MaxPartitionEncode = [uint64]1000
Assert-Fails { Get-VMateGpuPResourcePlanForRequest $gpu $request } "能力形状"

$script:video = [pscustomobject]@{ ResolutionType="Default"
    HorizontalResolution=1920; VerticalResolution=1200 }
$script:setCalls = 0
function Get-VMVideo { param($VM, $ErrorAction); return $script:video }
function Set-VMVideo {
    param($VM, $ResolutionType, $HorizontalResolution, $VerticalResolution,
        [switch]$Confirm, $ErrorAction)
    $script:setCalls++
    $script:video = [pscustomobject]@{ ResolutionType=[string]$ResolutionType
        HorizontalResolution=[int]$HorizontalResolution
        VerticalResolution=[int]$VerticalResolution }
}
$vm = [pscustomobject]@{ Name="mock-vm"; State="Off" }
$desired = New-VMateHyperVConsoleProfile Maximum 3840 2400
$dry = Set-VMateHyperVConsoleProfile $vm $desired -DryRun
if (-not $dry.ChangeRequired -or $script:setCalls -ne 0) {
    throw "console DryRun mutated state"
}
$result = Set-VMateHyperVConsoleProfile $vm $desired
if (-not $result.Changed -or $script:setCalls -ne 1 -or
    $result.Applied.ResolutionType -cne "Maximum" -or
    $result.Applied.HorizontalResolution -ne 3840 -or
    $result.Applied.VerticalResolution -ne 2400) {
    throw "console profile was not applied exactly"
}
$again = Set-VMateHyperVConsoleProfile $vm $desired
if ($again.Changed -or $script:setCalls -ne 1) {
    throw "console profile was not idempotent"
}
'

echo 'PASS: Windows GPU-P reference quota and console compatibility contract'
