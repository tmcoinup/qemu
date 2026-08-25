#!/usr/bin/env bash
# P-11 冷启动 CPUID 协调器：状态机、唯一 VID handle、失败关闭和打包入口。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
GPUP="$REPO_ROOT/deploy/windows/gpup"
MODULE="$GPUP/VMate.HyperV.CpuidColdStart.ps1"
ISOLATION="$GPUP/VMate.HyperV.GpuPColdStartIsolation.ps1"
ENTRY="$GPUP/Start-VMateGpuPVM.ps1"
RUNTIME="$GPUP/VMate.HyperV.HostIdentityRuntime.ps1"
CONFIRM="$GPUP/Confirm-VMateGpuPVMIdentity.ps1"
PROBE_SOURCE="$GPUP/native/VMateCpuidProbe.c"
PROBE_BUILD="$REPO_ROOT/deploy/tools/build-vmate-cpuid-probe.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
require_text() {
    rg -F --quiet -- "$1" "$2" || fail "missing '$1' in $2"
}

for file in "$MODULE" "$ISOLATION" "$ENTRY" "$RUNTIME" "$CONFIRM"; do
    [[ -f "$file" ]] || fail "missing cold-start file: $file"
    [[ "$(od -An -tx1 -N3 "$file" | tr -d ' \n')" == efbbbf ]] ||
        fail "PowerShell 5.1 UTF-8 BOM missing: $file"
    (( $(wc -l < "$file") <= 500 )) ||
        fail "cold-start file exceeds 500 lines: $file"
done
[[ -f "$PROBE_SOURCE" && -x "$PROBE_BUILD" ]] ||
    fail 'direct CPUID guest probe source/build helper missing'
for text in '__get_cpuid(1' '0x80000002u' '0x80000004u' \
    'vmate_print_json_string'; do
    require_text "$text" "$PROBE_SOURCE"
done
for text in \
    'function New-VMateHyperVHostIdentityColdBootAttestation' \
    'function Publish-VMateHyperVHostIdentityColdBootAttestation' \
    'function Publish-VMateHyperVHostIdentityGuestReadback' \
    "State = 'AttestedAwaitingGuestReadback'" \
    "State = 'Verified'" \
    'FullIdentitySupported = $true' \
    'Test-VMateHyperVHostIdentityAttestation' \
    'Test-VMateHyperVHostIdentityGuestReadback'; do
    require_text "$text" "$RUNTIME"
done
for text in \
    'PowerShell Direct' \
    'ExpectedCpuidProbeSha256' \
    '-AllowHashPinnedUnsigned' \
    'in-guest-direct-cpuid-and-cim' \
    'Publish-VMateHyperVHostIdentityGuestReadback' \
    'Remove-Item -LiteralPath $Path'; do
    require_text "$text" "$CONFIRM"
done
require_text '[switch]$AllowHashPinnedUnsigned' "$RUNTIME"
require_text "SignatureStatus = if (\$signatureValid) { 'Valid' }" "$RUNTIME"
[[ "$(rg -F --count -- '-AllowHashPinnedUnsigned' "$CONFIRM")" -eq 1 ]] ||
    fail 'hash-only exception must be scoped to the direct CPUID probe'

for text in \
    'function Start-VMateHyperVCpuidBrandColdBoot' \
    'function Invoke-VMateHyperVPartitionCandidateProbe' \
    'function Start-VMateHyperVEnabledTransition' \
    'Start-VM -VM $VM -AsJob' \
    'MaxPausedUptimeSeconds = 0.25' \
    "'OffWithGpuP', 'OffWithoutGpuP'" \
    "'RunningWithoutGpuP', 'PausedForCpuidWithoutGpuP'" \
    "'RunningGuestReadyWithoutGpuP'" \
    "'PausedForGpuPAttach', 'PausedWithGpuP'" \
    "'RunningWithGpuP'" \
    'DetachedBeforeStartRestoredAfterGuestReadyPause' \
    'function Wait-VMateHyperVGuestHeartbeat' \
    'RunningWithoutAdapterWaitingForGuest' \
    'AdapterRestoredAfterGuestReadyPause' \
    'Remove-VMateHyperVGpuPColdStartAdapter' \
    'Add-VMateHyperVGpuPColdStartAdapter' \
    'Suspend-VM -VM $running' \
    'Stop-VM -VM $current -TurnOff' \
    "-cne 'AppliedWhilePaused'" \
    'RuntimeModelSwitch = $false' \
    'accessDeniedCandidateListTruncated' \
    'ExpectedPartitionProbeSha256' \
    'ExpectedVidContextDriverSha256' \
    'ExpectedCpuidDriverSha256' \
    'ExpectedVmwpSha256' \
    'ExpectedVidSha256' \
    'ExpectedVidSysSha256'; do
    require_text "$text" "$MODULE"
done
for text in \
    'function Get-VMateHyperVGpuPColdStartAdapterSnapshot' \
    'function Remove-VMateHyperVGpuPColdStartAdapter' \
    'function Add-VMateHyperVGpuPColdStartAdapter' \
    'function New-VMateHyperVGpuPColdStartTransaction' \
    'function Repair-VMateHyperVGpuPColdStartTransaction' \
    'vmate-p11-gpup-cold-start-transaction-v1' \
    "-notin @('Off', 'Paused')" \
    "-cne 'Off'" \
    'Get-VMateGpuPHostPartitionableGpu' \
    'Get-VMateHyperVGpuPQuotaNames'; do
    require_text "$text" "$ISOLATION"
done
for text in \
    'vmate-p11-cpuid-cold-start-artifacts-v1' \
    'Get-VMateHyperVHostIdentityExtensionStatus' \
    'ArtifactManifestPath' \
    'Start-VMateHyperVCpuidBrandColdBoot' \
    "HostIdentityExtension = 'NotRequired'"; do
    require_text "$text" "$ENTRY"
done
if rg -ni '\b(bcdedit|nointegritychecks|testsigning\s+on)\b' \
    "$MODULE" "$ISOLATION" "$ENTRY" "$RUNTIME" "$CONFIRM"; then
    fail 'cold-start coordinator must not alter host boot policy'
fi

powershell_bin="$(command -v pwsh || command -v powershell || true)"
if [[ -z "$powershell_bin" ]]; then
    echo 'SKIP: PowerShell not found; CPUID cold-start static contract passed'
    exit 0
fi

VMATE_CPUID_COLD_START="$MODULE" \
"$powershell_bin" -NoLogo -NoProfile -NonInteractive -Command '
$ErrorActionPreference = "Stop"
. $env:VMATE_CPUID_COLD_START

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

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("vmate-cpuid-cold-start-" + [Guid]::NewGuid().ToString("N"))
[IO.Directory]::CreateDirectory($tempRoot) | Out-Null
try {
    $probe = Join-Path $tempRoot "probe.exe"
    [IO.File]::WriteAllBytes($probe, [byte[]](1, 2, 3, 4))
    $probeHash = (Get-FileHash $probe -Algorithm SHA256).Hash
    $vidRunner = Join-Path $tempRoot "vid.ps1"
    $cpuidRunner = Join-Path $tempRoot "cpuid.ps1"
    [IO.File]::WriteAllText($vidRunner, @"
param(`$TargetProcessId, `$PartitionHandle, `$DriverPath,
    `$ExpectedDriverSha256, `$ExpectedVmwpSha256, `$ExpectedVidSha256)
[pscustomobject]@{
    QuerySucceeded = `$true
    ImageMatched = `$true
    PartitionId = [uint64]2
}
"@, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($cpuidRunner, @"
param(`$VMName, `$VMId, `$TargetProcessId, `$PartitionHandle,
    `$ExpectedPartitionId, `$BrandString, `$DriverPath,
    `$ExpectedDriverSha256, `$ExpectedVmwpSha256, `$ExpectedVidSha256,
    `$ExpectedVidSysSha256, `$MaxPausedUptimeSeconds)
[pscustomobject]@{
    Applied = `$true
    RuntimeModelSwitch = `$false
    State = "AppliedWhilePaused"
    ApplyNonce = "4a744fd1-03ab-4fc0-bcae-8bf8f37cb3e2"
}
"@, [Text.UTF8Encoding]::new($false))

    $script:Vm = [pscustomobject]@{
        Name = "mock-p11"
        Id = [Guid]"282f1a79-363d-4267-a653-994d9b5d1d19"
        State = "Off"
        Generation = 2
        Uptime = [TimeSpan]::Zero
    }
    $script:AdapterCount = 1
    $script:Calls = [Collections.Generic.List[string]]::new()
    function Enter-VMateGpuPConfigurationLock {
        [void]$script:Calls.Add("Lock")
        return [pscustomobject]@{ Acquired = $true }
    }
    function Exit-VMateGpuPConfigurationLock {
        param([object]$Mutex)
        [void]$script:Calls.Add("Unlock")
    }
    function Repair-VMateHyperVGpuPColdStartTransaction {
        param([object]$VM)
        [void]$script:Calls.Add("Repair")
        [pscustomobject]@{ Status = "NoTransaction" }
    }
    function Get-VMateHyperVGpuPColdStartAdapterSnapshot {
        param([object]$VM, [string]$GpuInstancePath)
        if ($script:AdapterCount -ne 1) { throw "mock adapter missing" }
        [pscustomobject]@{
            SchemaVersion = 1
            ContractId = "vmate-p11-gpup-adapter-snapshot-v1"
            VMName = $VM.Name
            VMId = $VM.Id.ToString("D")
            GpuInstancePath = $GpuInstancePath
            Quotas = [pscustomobject]@{}
        }
    }
    function New-VMateHyperVGpuPColdStartTransaction {
        param([object]$VM, [object]$Snapshot)
        [void]$script:Calls.Add("Journal")
        [pscustomobject]@{
            VMId = $VM.Id.ToString("D")
            Phase = "Prepared"
        }
    }
    function Set-VMateHyperVGpuPColdStartTransactionPhase {
        param([object]$Transaction, [string]$Phase)
        $Transaction.Phase = $Phase
    }
    function Remove-VMateHyperVGpuPColdStartAdapter {
        param([object]$VM, [object]$Snapshot)
        [void]$script:Calls.Add("Detach")
        $script:AdapterCount = 0
    }
    function Add-VMateHyperVGpuPColdStartAdapter {
        param([object]$VM, [object]$Snapshot)
        [void]$script:Calls.Add("Attach")
        $script:AdapterCount = 1
        [pscustomobject]@{ Id = "mock-adapter" }
    }
    function Remove-VMateHyperVGpuPColdStartTransaction {
        param([Guid]$VMId)
        [void]$script:Calls.Add("Commit")
    }
    function Get-VMGpuPartitionAdapter {
        param([object]$VM, [object]$ErrorAction)
        if ($script:AdapterCount -eq 1) {
            return [pscustomobject]@{ Id = "mock-adapter" }
        }
        return @()
    }
    function Start-VMateHyperVEnabledTransition {
        param([object]$VM)
        [void]$script:Calls.Add("Start")
        $script:Vm.State = "Running"
        [pscustomobject]@{ State = "Completed" }
    }
    function Remove-Job {
        param([object]$Job, [switch]$Force, [object]$ErrorAction)
    }
    function Get-VM {
        param([string]$Name, [object]$ErrorAction)
        return $script:Vm
    }
    function Suspend-VM {
        param([object]$VM, [switch]$Confirm, [object]$ErrorAction)
        [void]$script:Calls.Add("Suspend")
        $script:Vm.State = "Paused"
        $script:Vm.Uptime = [TimeSpan]::FromMilliseconds(38)
    }
    function Resume-VM {
        param([object]$VM, [switch]$Confirm, [object]$ErrorAction)
        [void]$script:Calls.Add("Resume")
        $script:Vm.State = "Running"
    }
    function Get-VMIntegrationService {
        param([object]$VM, [object]$ErrorAction)
        [void]$script:Calls.Add("Heartbeat")
        [pscustomobject]@{
            Id = "Microsoft:mock\\84EAAE65-2F2E-45F5-9BB5-0E857DC8EB47"
            Enabled = $true
            PrimaryStatusDescription = "OK"
        }
    }
    function Stop-VM {
        param([object]$VM, [switch]$TurnOff, [switch]$Force,
            [switch]$Confirm, [object]$ErrorAction)
        [void]$script:Calls.Add("Stop")
        $script:Vm.State = "Off"
    }
    function Get-VMateHyperVWorkerProcess {
        param([object]$VM)
        [pscustomobject]@{ ProcessId = 5416 }
    }
    function Invoke-VMateHyperVPartitionCandidateProbe {
        param($TargetProcessId, $ProbePath, $ExpectedProbeSha256)
        [pscustomobject]@{
            PartitionHandle = [uint64]0x290
            PartitionHandleHex = "0x290"
        }
    }

    $hash = [string]::new("A", 64)
    $parameters = @{
        VM = $script:Vm
        GpuInstancePath = "PCIROOT(0)#PCI(0100)#PCI(0000)"
        BrandString = "13th Gen Intel(R) Core(TM) i7-13700F"
        PartitionProbePath = $probe
        ExpectedPartitionProbeSha256 = $probeHash
        VidContextRunnerPath = $vidRunner
        VidContextDriverPath = (Join-Path $tempRoot "vid.sys")
        ExpectedVidContextDriverSha256 = $hash
        CpuidRunnerPath = $cpuidRunner
        CpuidDriverPath = (Join-Path $tempRoot "cpuid.sys")
        ExpectedCpuidDriverSha256 = $hash
        ExpectedVmwpSha256 = $hash
        ExpectedVidSha256 = $hash
        ExpectedVidSysSha256 = $hash
        GuestStabilizationSeconds = 0
    }
    $dry = Start-VMateHyperVCpuidBrandColdBoot @parameters -DryRun
    Assert-True ($dry.RuntimeModelSwitch -eq $false) "dry-run model switch"
    Assert-True ($script:Calls.Count -eq 0) "dry-run changed lifecycle"

    $result = Start-VMateHyperVCpuidBrandColdBoot @parameters
    Assert-True ($result.State -ceq "RunningAfterAppliedColdBoot") `
        "success state"
    Assert-True ($result.PartitionHandleHex -ceq "0x290") "partition handle"
    Assert-True ($result.PartitionId -eq 2) "partition id"
    Assert-True ($script:Vm.State -ceq "Running") "VM was not resumed"
    Assert-True (($script:Calls -join ",") -ceq `
        "Lock,Repair,Journal,Detach,Start,Suspend,Resume,Heartbeat,Suspend,Attach,Resume,Commit,Unlock") `
        "unexpected success lifecycle"
    Assert-True ($script:AdapterCount -eq 1) "success lost GPU-P adapter"

    $script:Vm.State = "Off"
    $script:Vm.Uptime = [TimeSpan]::Zero
    $script:Calls.Clear()
    [IO.File]::WriteAllText($cpuidRunner, @"
param(`$VMName, `$VMId, `$TargetProcessId, `$PartitionHandle,
    `$ExpectedPartitionId, `$BrandString, `$DriverPath,
    `$ExpectedDriverSha256, `$ExpectedVmwpSha256, `$ExpectedVidSha256,
    `$ExpectedVidSysSha256, `$MaxPausedUptimeSeconds)
[pscustomobject]@{
    Applied = `$false
    RuntimeModelSwitch = `$false
    State = "FailedOrRolledBack"
    ApplyNonce = ""
}
"@, [Text.UTF8Encoding]::new($false))
    Assert-Throws {
        Start-VMateHyperVCpuidBrandColdBoot @parameters
    } "本次 VM 已关闭"
    Assert-True ($script:Vm.State -ceq "Off") "failure left VM active"
    Assert-True (($script:Calls -join ",") -ceq `
        "Lock,Repair,Journal,Detach,Start,Suspend,Stop,Attach,Commit,Unlock") `
        "failure did not turn off VM"
    Assert-True ($script:AdapterCount -eq 1) "failure lost GPU-P adapter"

    $script:Vm.State = "Running"
    Assert-Throws {
        Start-VMateHyperVCpuidBrandColdBoot @parameters
    } "要求 VM 为 Off"
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force `
        -ErrorAction SilentlyContinue
}
'

echo 'PASS: Hyper-V CPUID cold-start coordinator contract'
