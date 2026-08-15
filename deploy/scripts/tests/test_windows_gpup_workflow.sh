#!/usr/bin/env bash
# P-11 Hyper-V GPU-P 创建、身份和生命周期包装静态/纯函数回归。
# shellcheck disable=SC2016 # PowerShell 合同字符串必须保持字面量 $。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
GPUP="$REPO_ROOT/deploy/windows/gpup"
NSIS_HELPER="$REPO_ROOT/scripts/nsis.py"
NSIS_SCRIPT="$REPO_ROOT/qemu.nsi"
GPU_P_DOC="$REPO_ROOT/deploy/docs/HYPERV-GPU-P.md"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

require_text() {
    local needle="$1"
    local file="$2"
    rg -F --quiet -- "$needle" "$file" || fail "missing '$needle' in $file"
}

reject_regex() {
    local pattern="$1"
    shift
    if rg --quiet -- "$pattern" "$@"; then
        fail "forbidden pattern '$pattern' in $*"
    fi
}

test_files_and_encoding() {
    local file line_count bom
    local files=(
        VMate.GpuP.Identity.ps1
        VMate.GpuP.Lifecycle.ps1
        VMate.GpuP.Guest.ps1
        New-VMateGpuPVM.ps1
        Enable-VMateGpuP.ps1
        Update-VMateGpuPDriver.ps1
        Disable-VMateGpuP.ps1
        Get-VMateGpuPStatus.ps1
    )
    for file in "${files[@]}"; do
        file="$GPUP/$file"
        [[ -f "$file" ]] || fail "missing workflow file: $file"
        line_count="$(wc -l < "$file")"
        (( line_count <= 500 )) || fail "$file exceeds 500 lines: $line_count"
        bom="$(od -An -tx1 -N3 "$file" | tr -d ' \n')"
        [[ "$bom" == efbbbf ]] || fail "$file lacks UTF-8 BOM for PowerShell 5.1"
        reject_regex '\b(Read-Host|PromptForChoice)\b' "$file"
    done
}

test_dynamic_gpu_contract() {
    local new_vm="$GPUP/New-VMateGpuPVM.ps1"
    local enable="$GPUP/Enable-VMateGpuP.ps1"
    local update="$GPUP/Update-VMateGpuPDriver.ps1"
    local disable="$GPUP/Disable-VMateGpuP.ps1"
    local status="$GPUP/Get-VMateGpuPStatus.ps1"
    local sync_line configure_line preflight_line create_line

    require_text "[ValidateSet('Auto', 'NVIDIA', 'AMD')]" "$new_vm"
    require_text 'Get-VMHostPartitionableGpu -ErrorAction Stop' "$new_vm"
    require_text 'Resolve-VMateGpuPHostGpu' "$new_vm"
    require_text 'PartitionIdentitySeed = $seed' "$new_vm"
    require_text '[string]$PartitionIdentitySeed' "$new_vm"
    require_text 'Set-VMateGpuPIdentityBinding -VMId $created.VM.Id' "$new_vm"
    require_text 'GpuPercentage' "$new_vm"
    require_text 'WillDeferGpuProvisioning = $CreateVhd.IsPresent' "$new_vm"
    require_text '[switch]$FullSharedGpuQuota' "$new_vm"
    require_text 'Resolve-VMateGpuPQuotaRequest' "$new_vm"
    require_text 'FullSharedGpuQuota = $FullSharedGpuQuota' "$new_vm"
    require_text 'FullHostVramQuota = $fullHostVramQuotaPreview' "$new_vm"
    require_text 'ResumeArguments = [pscustomobject][ordered]@{' "$new_vm"
    require_text 'Enable-VMateGpuP.ps1 -FullSharedGpuQuota -GuestCapacity' "$new_vm"
    require_text '[int]$GuestCapacity = 2' "$new_vm"
    require_text 'Get-VMateGpuPCmdletCompatibility' "$new_vm"
    require_text 'HostLockTimeoutSeconds = $HostLockTimeoutSeconds' "$new_vm"
    preflight_line="$(rg -n 'Get-VMateGpuPCmdletCompatibility' "$new_vm" | \
        head -n1 | cut -d: -f1)"
    create_line="$(rg -n '^\$created = New-VMateGpuPVirtualMachine' "$new_vm" | \
        cut -d: -f1)"
    [[ "$preflight_line" -lt "$create_line" ]] \
        || fail 'old Hyper-V cmdlet compatibility must fail before VM creation'

    require_text 'Get-VMateGpuPConfigurationPlan @configurationParameters' "$enable"
    require_text 'ConvertTo-VMateGpuPInstanceId' "$enable"
    require_text 'Get-VMateGpuPDriverSelection' "$enable"
    require_text 'Sync-VMateGpuPDriverStore' "$enable"
    require_text 'Invoke-VMateGpuPConfiguration' "$enable"
    require_text 'Test-VMateGpuPIdentityUniqueness' "$enable"
    require_text 'Invoke-VMateGpuPGuestValidation' "$enable"
    require_text 'GuestCredential/DisableHyperVVideo/RequireNvidiaSmi' "$enable"
    require_text 'VendorGpuUuid' "$enable"
    require_text '[switch]$FullSharedGpuQuota' "$enable"
    require_text 'Resolve-VMateGpuPQuotaRequest' "$enable"
    require_text '$quotaRequest.Percentages.VramPercentage' "$enable"
    require_text '$quotaRequest.Percentages.EncodePercentage' "$enable"
    require_text '$quotaRequest.Percentages.DecodePercentage' "$enable"
    require_text '$quotaRequest.Percentages.ComputePercentage' "$enable"
    require_text '-FullSharedGpuQuota:$FullSharedGpuQuota.IsPresent' "$enable"
    require_text '$quotaRequest.QuotaMode' "$enable"
    require_text 'EffectiveAllowOvercommit = $effectiveAllowOvercommit' "$enable"
    require_text 'FullHostVramQuota = ([uint64]$plan.ResourcePlan.MaxPartitionVRAM -eq' \
        "$enable"
    require_text 'CapabilitySnapshot = $plan.CapabilitySnapshot' "$enable"
    require_text 'Quota = $plan.Quota' "$enable"
    require_text 'Restore-VMateGpuPHostPartitionCount' "$enable"
    require_text '[int]$GuestCapacity = 2' "$enable"
    require_text '$configurationParameters.InstancePath = [string]$plan.InstancePath' \
        "$enable"
    require_text '$configurationParameters.Vendor = [string]$plan.Vendor' "$enable"
    require_text '$effectiveVendor = [string]$identity.Vendor' "$enable"
    require_text 'Set-VMateGpuPHostPartitionCount' "$enable"
    require_text 'Enter-VMateGpuPConfigurationLock' "$enable"
    require_text 'HostPartitionCapacity = $partitionCapacity' "$enable"
    sync_line="$(rg -n 'Sync-VMateGpuPDriverStore' "$enable" | head -n1 | cut -d: -f1)"
    configure_line="$(rg -n 'Invoke-VMateGpuPConfiguration' "$enable" | head -n1 | cut -d: -f1)"
    [[ "$sync_line" -lt "$configure_line" ]] \
        || fail 'driver sync must finish before host GPU-P mutation'

    require_text 'Sync-VMateGpuPDriverStore' "$update"
    require_text 'Enter-VMateGpuPConfigurationLock' "$update"
    require_text 'Exit-VMateGpuPConfigurationLock' "$update"
    require_text 'Get-VMateGpuPAdapterOwnership' "$disable"
    require_text '拒绝删除手工 adapter' "$disable"
    require_text 'Enter-VMateGpuPConfigurationLock' "$disable"
    require_text 'Exit-VMateGpuPConfigurationLock' "$disable"
    require_text 'Get-VMHostPartitionableGpu' "$status"
    require_text 'HostIndirectDisplayAdapters' "$status"
    reject_regex '(DEV_[0-9A-Fa-f]{4}|GeForce[[:space:]]+(GTX|RTX)|Radeon[[:space:]]+PRO|4060|1060)' \
        "$new_vm" "$enable" "$update" "$status"
    reject_regex '(respawn-stealth|VioGpuDod|nvapi-shim|adl-shim)' \
        "$new_vm" "$enable" "$update" "$status" \
        "$GPUP/VMate.GpuP.Identity.ps1" "$GPUP/VMate.GpuP.Lifecycle.ps1" \
        "$GPUP/VMate.GpuP.Guest.ps1"
}

test_full_shared_quota_argument_contract() {
    local powershell_bin
    powershell_bin="$(command -v pwsh || command -v powershell || true)"
    [[ -n "$powershell_bin" ]] || return 0
    VMATE_GPUP_ENABLE="$GPUP/Enable-VMateGpuP.ps1" \
    VMATE_GPUP_NEW="$GPUP/New-VMateGpuPVM.ps1" \
        "$powershell_bin" -NoLogo -NoProfile -NonInteractive -Command '
            $ErrorActionPreference = "Stop"
            foreach ($action in @(
                { & $env:VMATE_GPUP_ENABLE -VMName test `
                    -FullSharedGpuQuota -VramPercentage 50 },
                { & $env:VMATE_GPUP_NEW -VMName test -VhdPath test.vhdx `
                    -FullSharedGpuQuota -GpuPercentage 50 }
            )) {
                try {
                    & $action
                    throw "explicit non-100 quota was accepted"
                } catch {
                    if ($_.Exception.Message -eq
                        "explicit non-100 quota was accepted" -or
                        $_.Exception.Message -notmatch "FullSharedGpuQuota.*冲突") {
                        throw
                    }
                }
            }
            exit 0
        '
}

test_identity_contract() {
    local identity="$GPUP/VMate.GpuP.Identity.ps1"
    local lifecycle="$GPUP/VMate.GpuP.Lifecycle.ps1"

    require_text '[Security.Cryptography.RandomNumberGenerator]::Create()' "$identity"
    require_text 'Enter-VMateGpuPIdentityLock -VMId $VMId' "$identity"
    require_text "ObservedVendorGpuUuidScope = 'unknown-physical-or-virtual'" \
        "$identity"
    require_text "PhysicalGpuSerialPolicy = 'vendor-managed-read-only'" "$identity"
    require_text 'PartitionIdentitySeed' "$identity"
    require_text 'GpuInstancePath' "$identity"
    require_text 'VendorGpuUuid' "$identity"
    require_text 'function Test-VMateGpuPIdentityUniqueness' "$identity"
    reject_regex '(Set-ItemProperty|New-ItemProperty|nvapi|adl|GPU_SERIAL)' "$identity"

    require_text 'Generation = 2' "$lifecycle"
    require_text '-AutomaticCheckpointsEnabled $false -CheckpointType Disabled' "$lifecycle"
    require_text '-SecureBootTemplate MicrosoftWindows' "$lifecycle"
    require_text 'Hyper-V GPU-P 后端只接受 .vhd 或 .vhdx' "$lifecycle"
    require_text 'if ($createdVhd -and' "$lifecycle"
    require_text '$remaining = Get-VM -Id $createdVm.Id' "$lifecycle"
    require_text '已保留身份清单与 VHD' "$lifecycle"
    reject_regex '(qemu-system|whpx|vfio|Dismount-VMHostAssignableDevice)' "$lifecycle"
}

test_identity_pure_functions() {
    local powershell_bin
    powershell_bin="$(command -v pwsh || command -v powershell || true)"
    if [[ -z "$powershell_bin" ]]; then
        echo 'SKIP: PowerShell not found; GPU-P workflow static contract passed'
        return
    fi

    VMATE_GPUP_IDENTITY="$GPUP/VMate.GpuP.Identity.ps1" \
        "$powershell_bin" -NoLogo -NoProfile -NonInteractive -Command '
        $ErrorActionPreference = "Stop"
        . $env:VMATE_GPUP_IDENTITY
        $root = Join-Path ([IO.Path]::GetTempPath()) `
            ("vmate-gpup-identity-test-" + [Guid]::NewGuid().ToString("N"))
        try {
            $idA = [Guid]::NewGuid()
            $idB = [Guid]::NewGuid()
            $a = Initialize-VMateGpuPIdentity -VMId $idA -Vendor NVIDIA `
                -StateRoot $root
            $b = Initialize-VMateGpuPIdentity -VMId $idB -Vendor AMD `
                -StateRoot $root
            if ($a.PartitionIdentitySeed -eq $b.PartitionIdentitySeed -or
                $a.PartitionIdentitySeed.Length -ne 64) {
                throw "random identity seeds are invalid"
            }
            $a = Set-VMateGpuPIdentityBinding -VMId $idA -Vendor NVIDIA `
                -GpuInstancePath "PCI#VEN_10DE&MOCK" -HostGpuName "Mock GPU" `
                -DriverVersion "1.2.3.4" -DriverInf "mock.inf" -StateRoot $root
            $a = Update-VMateGpuPObservedIdentity -VMId $idA `
                -PartitionId 1 -PartitionVfLuid "10-20" `
                -VendorGpuUuid "GPU-test-a" -StateRoot $root
            $b = Update-VMateGpuPObservedIdentity -VMId $idB `
                -VendorGpuUuid "GPU-test-a" -StateRoot $root
            $audit = Test-VMateGpuPIdentityUniqueness -StateRoot $root
            if (-not $audit.IsUnique -or $audit.Records -ne 2) {
                throw "identity uniqueness audit failed"
            }
            if ($audit.ObservedVendorGpuUuidCollisions.Count -ne 1) {
                throw "shared physical vendor UUID was not advisory"
            }
            try {
                Set-VMateGpuPIdentityBinding -VMId $idA -Vendor NVIDIA `
                    -GpuInstancePath "PCI#VEN_10DE&OTHER" -StateRoot $root
                throw "binding drift was accepted"
            } catch {
                if ($_.Exception.Message -eq "binding drift was accepted") { throw }
            }
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    '
}

test_packaging_and_documentation_contract() {
    local runtime_file
    local runtime_files=(
        VMate.GpuP.Common.ps1
        VMate.GpuP.Host.ps1
        VMate.GpuP.Partition.ps1
        VMate.GpuP.DriverDiscovery.ps1
        VMate.GpuP.DriverStore.ps1
        VMate.GpuP.WindowsImage.ps1
        VMate.GpuP.Display.ps1
        VMate.GpuP.Identity.ps1
        VMate.GpuP.Lifecycle.ps1
        VMate.GpuP.Guest.ps1
        VMate.GpuP.GuestValidation.ps1
        VMate.GpuP.D3DValidation.ps1
        New-VMateGpuPVM.ps1
        Enable-VMateGpuP.ps1
        Update-VMateGpuPDriver.ps1
        Disable-VMateGpuP.ps1
        Get-VMateGpuPStatus.ps1
        Test-VMateGpuPGuest.ps1
    )

    for runtime_file in "${runtime_files[@]}"; do
        require_text "deploy/windows/gpup/$runtime_file" "$NSIS_HELPER"
    done
    require_text 'deploy/docs/HYPERV-GPU-P.md' "$NSIS_HELPER"
    require_text 'File /r "${BINDIR}\deploy\windows\*.*"' "$NSIS_SCRIPT"
    require_text 'File /r "${BINDIR}\deploy\docs\*.*"' "$NSIS_SCRIPT"
    require_text 'Hyper-V GPU-P modules' "$NSIS_SCRIPT"
    require_text 'New-VMateGpuPVM.ps1' "$GPU_P_DOC"
    require_text 'Enable-VMateGpuP.ps1' "$GPU_P_DOC"
    require_text 'test_windows_gpup_workflow.sh' \
        "$REPO_ROOT/deploy/scripts/tests/run-vmate-tests.py"
}

test_files_and_encoding
test_dynamic_gpu_contract
test_identity_contract
test_identity_pure_functions
test_full_shared_quota_argument_contract
test_packaging_and_documentation_contract
echo 'PASS: Windows GPU-P workflow and identity contract'
