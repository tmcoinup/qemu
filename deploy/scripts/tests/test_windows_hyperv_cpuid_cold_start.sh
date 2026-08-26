#!/usr/bin/env bash
# P-11 禁用不安全 paused-CPUID/GPU-P 重配序列并保持启动前失败关闭。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
GPUP="$REPO_ROOT/deploy/windows/gpup"
MODULE="$GPUP/VMate.HyperV.CpuidColdStart.ps1"
ISOLATION="$GPUP/VMate.HyperV.GpuPColdStartIsolation.ps1"
ENTRY="$GPUP/Start-VMateGpuPVM.ps1"

fail() { echo "FAIL: $*" >&2; exit 1; }
require_text() {
    rg -F --quiet -- "$1" "$2" || fail "missing '$1' in $2"
}

for file in "$MODULE" "$ISOLATION" "$ENTRY"; do
    [[ -f "$file" ]] || fail "missing cold-start file: $file"
    [[ "$(od -An -tx1 -N3 "$file" | tr -d ' \n')" == efbbbf ]] ||
        fail "PowerShell 5.1 UTF-8 BOM missing: $file"
    (( $(wc -l < "$file") <= 500 )) ||
        fail "cold-start file exceeds 500 lines: $file"
done

for text in \
    'vmate-p11-paused-cpuid-disabled-v1' \
    "State = 'BlockedBeforeVmStart'" \
    "RequiredReplacement = 'boot-bound-hypervisor-extension'" \
    '已在 Start-VM、Suspend-VM 或 GPU-P' \
    'RuntimeModelSwitch = $false'; do
    require_text "$text" "$MODULE"
done
for text in \
    '只用于恢复历史未完成事务' \
    '到 Running 全程保持绑定' \
    "-cne 'Off'" \
    'function Repair-VMateHyperVGpuPColdStartTransaction' \
    'vmate-p11-gpup-cold-start-transaction-v1'; do
    require_text "$text" "$ISOLATION"
done
for text in \
    'vmate-p11-safe-gpup-cold-boot-v2' \
    'StandardHyperVColdBootWithGpuPAlreadyAttached' \
    'attached-before-start-through-shutdown' \
    'SmbiosAppliedDirectCpuidPending' \
    'direct-cpuid-brand-family-model-stepping' \
    'HostTestSigningRequired = $false' \
    'Assert-VMateP11HostEnvironment -RequireTestSigning $false' \
    '[switch]$RequireFullHardwareIdentity' \
    'paused-CPUID artifact manifest 已停用'; do
    require_text "$text" "$ENTRY"
done

# 产品启动入口不得再含暂停、摘除或热加 adapter 的命令。
if rg -n -F -e 'Suspend-VM' \
        -e 'Remove-VMGpuPartitionAdapter' \
        -e 'Add-VMGpuPartitionAdapter' \
        -e 'Start-VMateHyperVCpuidBrandColdBoot' "$ENTRY"; then
    fail 'safe P-11 start entry still contains paused/hotplug lifecycle'
fi
if rg -n -F 'Remove-VMGpuPartitionAdapter' "$ISOLATION"; then
    fail 'recovery-only isolation module can still detach an adapter'
fi

powershell_bin="$(command -v pwsh || command -v powershell || true)"
if [[ -z "$powershell_bin" ]]; then
    echo 'SKIP: PowerShell not found; disabled CPUID contract passed'
    exit 0
fi

VMATE_CPUID_COLD_START="$MODULE" \
VMATE_GPU_ISOLATION="$ISOLATION" \
VMATE_SAFE_START="$ENTRY" \
    "$powershell_bin" -NoLogo -NoProfile -NonInteractive -Command '
$ErrorActionPreference = "Stop"
foreach ($file in @($env:VMATE_CPUID_COLD_START,
        $env:VMATE_GPU_ISOLATION, $env:VMATE_SAFE_START)) {
    $errors = $null
    $tokens = $null
    [void][Management.Automation.Language.Parser]::ParseFile(
        $file, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        throw (($errors | ForEach-Object Message) -join "; ")
    }
}
. $env:VMATE_CPUID_COLD_START

function Get-VMGpuPartitionAdapter {
    param([object]$VM, [object]$ErrorAction)
    return [pscustomobject]@{ Id = "mock-gpup" }
}
function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern)
    try { & $Action } catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw }
        return
    }
    throw "expected failure: $Pattern"
}

$vm = [pscustomobject]@{
    Name = "mock-p11"
    Id = [Guid]"282f1a79-363d-4267-a653-994d9b5d1d19"
    State = "Off"
    Generation = 2
}
$hash = [string]::new("A", 64)
$parameters = @{
    VM = $vm
    GpuInstancePath = "PCIROOT(0)#PCI(0100)#PCI(0000)"
    BrandString = "13th Gen Intel(R) Core(TM) i7-13700F"
    PartitionProbePath = "missing-probe.exe"
    ExpectedPartitionProbeSha256 = $hash
    VidContextRunnerPath = "missing-vid.ps1"
    VidContextDriverPath = "missing-vid.sys"
    ExpectedVidContextDriverSha256 = $hash
    CpuidRunnerPath = "missing-cpuid.ps1"
    CpuidDriverPath = "missing-cpuid.sys"
    ExpectedCpuidDriverSha256 = $hash
    ExpectedVmwpSha256 = $hash
    ExpectedVidSha256 = $hash
    ExpectedVidSysSha256 = $hash
}
$dry = Start-VMateHyperVCpuidBrandColdBoot @parameters -DryRun
if ($dry.State -cne "BlockedBeforeVmStart" -or $dry.SafeToStart -or
    $dry.GpuPAdapterCount -ne 1 -or $dry.RuntimeModelSwitch) {
    throw "disabled CPUID dry-run proof is invalid"
}
Assert-Throws {
    Start-VMateHyperVCpuidBrandColdBoot @parameters
} "Start-VM.*之前阻断"

$snapshot = [pscustomobject]@{}
Assert-Throws {
    Remove-VMateHyperVGpuPColdStartAdapter -VM $vm -Snapshot $snapshot
} "摘除路径已停用"
'

echo 'PASS: Hyper-V paused-CPUID path is disabled before GPU-P/VM mutation'
