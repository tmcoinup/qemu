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
        VMate.GpuP.BaseImage.ps1
        VMate.Windows.CodeIntegrity.ps1
        VMate.GpuP.HardwareProfile.ps1
        VMate.GpuP.CpuidProfile.ps1
        VMate.GpuP.HardwareReprofile.ps1
        VMate.GpuP.DetectionParity.ps1
        VMate.HyperV.FirmwareIdentity.ps1
        VMate.HyperV.NetworkIdentity.ps1
        VMate.HyperV.ComputeProfile.ps1
        VMate.GpuP.HardwareIdentity.ps1
        VMate.GpuP.GuestIdentity.ps1
        VMate.GpuP.Lifecycle.ps1
        VMate.GpuP.Guest.ps1
        VMate.GpuP.VMConfiguration.ps1
        VMate.GpuP.QuotaProfile.ps1
        VMate.HyperV.ConsoleProfile.ps1
        VMate.HyperV.HostIdentityExtension.ps1
        New-VMateGpuPVM.ps1
        Enable-VMateGpuP.ps1
        Update-VMateGpuPDriver.ps1
        Disable-VMateGpuP.ps1
        Get-VMateGpuPStatus.ps1
        Set-VMateGpuPComputeProfile.ps1
        Set-VMateGpuPHardwareProfile.ps1
        Detect-VGpuP.ps1
        Compare-VMateGpuPDetection.ps1
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
    local identity_preflight_line hardware_apply_line

    require_text "[ValidateSet('Auto', 'NVIDIA', 'AMD')]" "$new_vm"
    require_text 'Get-VMateGpuPHostPartitionableGpu' "$new_vm"
    require_text 'Resolve-VMateGpuPHostGpu' "$new_vm"
    require_text 'PartitionIdentitySeed = $seed' "$new_vm"
    require_text '[string]$PartitionIdentitySeed' "$new_vm"
    require_text 'Set-VMateGpuPIdentityBinding -VMId $created.VM.Id' "$new_vm"
    require_text 'GpuPercentage' "$new_vm"
    require_text 'WillDeferGpuProvisioning = $CreateVhd.IsPresent' "$new_vm"
    require_text 'WillCloneBaseImage' "$new_vm"
    require_text '[string]$BaseImagePath' "$new_vm"
    require_text '[switch]$FullSharedGpuQuota' "$new_vm"
    require_text 'Resolve-VMateGpuPQuotaCompatibilityRequest' "$new_vm"
    require_text '[switch]$Win10ReferenceGpuQuota' "$new_vm"
    require_text 'Get-VMateGpuPResourcePlanForRequest' "$new_vm"
    require_text 'ConfigurationVersion = $ConfigurationVersion' "$new_vm"
    require_text 'ConsoleResolutionType = $consoleProfile.ResolutionType' "$new_vm"
    require_text 'FullSharedGpuQuota = $FullSharedGpuQuota' "$new_vm"
    require_text 'FullHostVramQuota = $fullHostVramQuotaPreview' "$new_vm"
    require_text 'ResumeArguments = [pscustomobject][ordered]@{' "$new_vm"
    require_text 'Enable-VMateGpuP.ps1 -FullSharedGpuQuota -GuestCapacity' "$new_vm"
    require_text '[int]$GuestCapacity = 2' "$new_vm"
    require_text '[int]$CpuMaximumPercent = 100' "$new_vm"
    require_text '[int]$CpuReservePercent = 0' "$new_vm"
    require_text '[int]$CpuRelativeWeight = 100' "$new_vm"
    require_text '[int]$HwThreadCountPerCore = 1' "$new_vm"
    require_text '[bool]$ExposeVirtualizationExtensions = $false' "$new_vm"
    require_text "[string]\$HardwareProfileId = 'host-native'" "$new_vm"
    require_text 'Resolve-VMateGpuPHardwareProfile' "$new_vm"
    require_text 'HardwareProfile = $created.HardwareProfile' "$new_vm"
    require_text '[string]$BaseBoardSerialNumber' "$new_vm"
    require_text '[string]$StaticMacAddress' "$new_vm"
    require_text 'Get-VMateGpuPCmdletCompatibility' "$new_vm"
    require_text 'HostLockTimeoutSeconds = $HostLockTimeoutSeconds' "$new_vm"
    require_text '[string]$ArtifactManifestPath' "$new_vm"
    require_text "'P11SafePartialIdentityColdBoot'" "$new_vm"
    require_text 'RequireFullHardwareIdentity =' "$new_vm"
    require_text 'paused-CPUID 路径已停用' "$new_vm"
    require_text 'Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass' \
        "$GPUP/VMate.GpuP.Guest.ps1"
    require_text "'VMate.Windows.CodeIntegrity.ps1'" \
        "$GPUP/VMate.GpuP.Guest.ps1"
    require_text "PSObject.Properties['Execute']" \
        "$GPUP/Test-VMateGpuPGuest.ps1"
    if rg -n 'Set-ExecutionPolicy.*Scope (LocalMachine|CurrentUser)' \
        "$GPUP/VMate.GpuP.Guest.ps1"; then
        fail 'guest validation must not persist an execution-policy change'
    fi
    require_text "HardwareIdentityPolicy = 'custom-or-random-once-persisted-on-create'" \
        "$new_vm"
    require_text 'HardwareIdentity = $created.HardwareIdentity' "$new_vm"
    require_text 'IdentityBoot = $created.IdentityBoot' "$new_vm"
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
    require_text '[string]$ArtifactManifestPath' "$enable"
    require_text "'Start-VMateGpuPVM.ps1'" "$enable"
    require_text '-RequireFullHardwareIdentity:$RequireFullHardwareIdentity' "$enable"
    require_text "'P11SafePartialIdentityColdBoot'" "$enable"
    require_text '当前安全后端尚未实现启动期 direct CPUID' "$enable"
    require_text 'Test-VMateGpuPIdentityUniqueness' "$enable"
    require_text 'Invoke-VMateGpuPGuestValidation' "$enable"
    require_text 'ExpectedHardwareIdentity $hardwareIdentity.Desired' "$enable"
    require_text 'Set-VMateGpuPGuestObservedHardwareIdentity' "$enable"
    require_text 'GuestCredential/DisableHyperVVideo/RequireNvidiaSmi' "$enable"
    require_text 'VendorGpuUuid' "$enable"
    require_text '[switch]$FullSharedGpuQuota' "$enable"
    require_text 'Resolve-VMateGpuPQuotaCompatibilityRequest' "$enable"
    require_text '[switch]$Win10ReferenceGpuQuota' "$enable"
    require_text 'QuotaRequest = $quotaRequest' "$enable"
    require_text "[string]\$ConsoleResolutionType = 'Unchanged'" "$enable"
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
    require_text 'Ensure-VMateGpuPHardwareIdentity -VM $vm' "$enable"
    require_text 'Test-VMateGpuPHardwareIdentityUniqueness' "$enable"
    require_text 'HardwareIdentity = $hardwareIdentity' "$enable"
    require_text 'Install-VMateHyperVIdentityBoot -VM $vm' "$enable"
    require_text 'IdentityBoot = $identityBoot' "$enable"
    identity_preflight_line="$(rg -n 'Test-VMateGpuPIdentityUniqueness' \
        "$enable" | head -n1 | cut -d: -f1)"
    hardware_apply_line="$(rg -n 'Ensure-VMateGpuPHardwareIdentity -VM' \
        "$enable" | head -n1 | cut -d: -f1)"
    [[ "$identity_preflight_line" -lt "$hardware_apply_line" ]] \
        || fail 'core identity collision must fail before hardware identity mutation'
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
    require_text 'Get-VMateGpuPHostPartitionableGpu' "$status"
    require_text 'HostIndirectDisplayAdapters' "$status"
    require_text 'HostCodeIntegrity = $hostCodeIntegrity' "$status"
    require_text "VMate.Windows.CodeIntegrity.ps1" "$status"
    require_text 'RebootRequiredForTestSigning' \
        "$GPUP/VMate.Windows.CodeIntegrity.ps1"
    require_text 'Get-VMateGpuPHardwareIdentityStatus' "$status"
    require_text 'Get-VMateHyperVComputeSnapshot' "$status"
    require_text 'Get-VMateGpuPVMConfigurationSnapshot' "$status"
    require_text "VMate.HyperV.DisplayTopology.ps1" "$status"
    require_text 'Get-VMateHyperVDisplayTopologySnapshot' "$status"
    require_text 'DisplayTopology = $displayTopology' "$status"
    require_text 'ConsoleProfile = $displayTopology.Console' "$status"
    require_text "VMate.HyperV.MetadataExchange.ps1" "$status"
    require_text 'Get-VMateHyperVMetadataExchangeHostSnapshot' "$status"
    require_text 'MetadataExchange = $metadataExchange' "$status"
    require_text 'ConfigurationVersion = [string]$vm.Version' "$status"
    require_text 'HardwareIdentityAudit' "$status"
    require_text 'Get-VMateHyperVIdentityBootStatus -VM $vm' "$status"
    require_text 'IdentityBoot = $identityBoot' "$status"
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
                    -FullSharedGpuQuota -GpuPercentage 50 },
                { & $env:VMATE_GPUP_ENABLE -VMName test `
                    -FullSharedGpuQuota -Win10ReferenceGpuQuota }
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
    require_text '-AutomaticCheckpointsEnabled $false' "$lifecycle"
    require_text '-CheckpointType Disabled' "$lifecycle"
    require_text '-SecureBootTemplate MicrosoftWindows' "$lifecycle"
    require_text "\$newVmParameters['Version'] = \$plan.ConfigurationVersion" \
        "$lifecycle"
    require_text 'Set-VMateHyperVConsoleProfile -VM $createdVm' "$lifecycle"
    require_text 'Hyper-V GPU-P 后端只接受 .vhd 或 .vhdx' "$lifecycle"
    require_text 'if ($createdVhd -and' "$lifecycle"
    require_text '$remaining = Get-VM -Id $createdVm.Id' "$lifecycle"
    require_text '已保留身份清单与 VHD' "$lifecycle"
    require_text 'Ensure-VMateGpuPHardwareIdentity -VM $createdVm' "$lifecycle"
    require_text 'HardwareIdentity = $hardwareIdentity' "$lifecycle"
    require_text '-BlockSizeBytes $plan.VhdBlockSizeBytes' "$lifecycle"
    require_text "StorageProfile = 'interactive-dynamic-vhdx-1mib'" "$lifecycle"
    require_text 'Install-VMateHyperVIdentityBoot -VM $createdVm' "$lifecycle"
    require_text 'IdentityBoot = $identityBoot' "$lifecycle"
    reject_regex '(qemu-system|whpx|vfio|Dismount-VMHostAssignableDevice)' "$lifecycle"
    reject_regex '(?i)(qemu|whpx|vfio|Dismount-VMHostAssignableDevice)' \
        "$GPUP/VMate.HyperV.FirmwareIdentity.ps1" \
        "$GPUP/VMate.HyperV.NetworkIdentity.ps1" \
        "$GPUP/VMate.GpuP.HardwareIdentity.ps1"
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
        VMate.GpuP.VMConfiguration.ps1
        VMate.GpuP.Host.ps1
        VMate.GpuP.Partition.ps1
        VMate.GpuP.DriverDiscovery.ps1
        VMate.GpuP.DriverStore.ps1
        VMate.GpuP.OfflineDriverPackage.ps1
        VMate.GpuP.WindowsImage.ps1
        VMate.GpuP.Display.ps1
        VMate.GpuP.Identity.ps1
        VMate.GpuP.BaseImage.ps1
        VMate.Windows.CodeIntegrity.ps1
        VMate.GpuP.HardwareProfile.ps1
        VMate.GpuP.CpuidProfile.ps1
        VMate.GpuP.HardwareReprofile.ps1
        VMate.GpuP.DetectionParity.ps1
        VMate.HyperV.FirmwareIdentity.ps1
        VMate.HyperV.NetworkIdentity.ps1
        VMate.HyperV.ComputeProfile.ps1
        VMate.HyperV.EnhancedSession.ps1
        VMate.HyperV.RdpConnection.ps1
        VMate.HyperV.DisplayTopology.ps1
        VMate.HyperV.MetadataExchange.ps1
        VMate.HyperV.IdentityBoot.ps1
        VMate.HyperV.IdentityBoot.Support.ps1
        VMate.HyperV.HostIdentityExtension.ps1
        VMate.HyperV.HostIdentityRuntime.ps1
        VMate.HyperV.CpuidColdStart.ps1
        VMate.GpuP.HardwareIdentity.ps1
        VMate.GpuP.GuestIdentity.ps1
        VMate.GpuP.Lifecycle.ps1
        VMate.GpuP.Guest.ps1
        VMate.GpuP.GuestMonitor.ps1
        VMate.GpuP.GuestMonitorValidation.ps1
        VMate.GpuP.GuestDeviceReality.ps1
        VMate.GpuP.GuestValidation.ps1
        VMate.GpuP.D3DValidation.ps1
        New-VMateGpuPVM.ps1
        Enable-VMateGpuP.ps1
        Update-VMateGpuPDriver.ps1
        Disable-VMateGpuP.ps1
        Get-VMateGpuPStatus.ps1
        Test-VMateGpuPGuest.ps1
        Set-VMateGpuPComputeProfile.ps1
        Invoke-VMateVidContextProbe.ps1
        Invoke-VMateCpuidBrandExtension.ps1
        Start-VMateGpuPVM.ps1
        Confirm-VMateGpuPVMIdentity.ps1
        Enable-VMateHyperVEnhancedSession.ps1
        Connect-VMateGpuPVM.ps1
        Connect-VMateGpuPRdp.ps1
        Set-VMateGpuPDisplayTopology.ps1
        Restore-VMateGpuPDisplayTopology.ps1
        Disable-VMateGpuPMetadataExchange.ps1
        Restore-VMateGpuPMetadataExchange.ps1
        Detect-VGpuP.ps1
        Compare-VMateGpuPDetection.ps1
        firmware/bin/VMateIdentityBoot.efi
        firmware/bin/VMateIdentityBoot.efi.sha256
    )

    for runtime_file in "${runtime_files[@]}"; do
        require_text "deploy/windows/gpup/$runtime_file" "$NSIS_HELPER"
    done
    require_text 'deploy/docs/HYPERV-GPU-P.md' "$NSIS_HELPER"
    require_text 'deploy/hardware/p11-platforms.json' "$NSIS_HELPER"
    require_text 'File /r "${BINDIR}\deploy\windows\*.*"' "$NSIS_SCRIPT"
    require_text 'File /r "${BINDIR}\deploy\docs\*.*"' "$NSIS_SCRIPT"
    require_text 'Hyper-V GPU-P modules' "$NSIS_SCRIPT"
    require_text 'New-VMateGpuPVM.ps1' "$GPU_P_DOC"
    require_text 'Enable-VMateGpuP.ps1' "$GPU_P_DOC"
    require_text 'Set-VMateGpuPComputeProfile.ps1' "$GPU_P_DOC"
    require_text 'Compare-VMateGpuPDetection.ps1' "$GPU_P_DOC"
    require_text 'Enable-VMateHyperVEnhancedSession.ps1' "$GPU_P_DOC"
    require_text 'Connect-VMateGpuPVM.ps1' "$GPU_P_DOC"
    require_text 'Connect-VMateGpuPRdp.ps1' "$GPU_P_DOC"
    require_text 'Set-VMateGpuPDisplayTopology.ps1' "$GPU_P_DOC"
    require_text 'Restore-VMateGpuPDisplayTopology.ps1' "$GPU_P_DOC"
    require_text 'Disable-VMateGpuPMetadataExchange.ps1' "$GPU_P_DOC"
    require_text 'Restore-VMateGpuPMetadataExchange.ps1' "$GPU_P_DOC"
    require_text '首次随机、随后固定' "$GPU_P_DOC"
    require_text 'HostObserved.Match=True' "$GPU_P_DOC"
    require_text 'GuestObserved' "$GPU_P_DOC"
    require_text 'WindowsCimColdBootReadback' "$GPU_P_DOC"
    require_text 'stream-fb-shm.ps1' "$GPU_P_DOC"
    require_text 'test_windows_gpup_workflow.sh' \
        "$REPO_ROOT/deploy/scripts/tests/run-vmate-tests.py"
    require_text 'test_windows_hyperv_firmware_identity.sh' \
        "$REPO_ROOT/deploy/scripts/tests/run-vmate-tests.py"
    require_text 'test_windows_hyperv_compute_profile.sh' \
        "$REPO_ROOT/deploy/scripts/tests/run-vmate-tests.py"
    require_text 'test_windows_hyperv_cpuid_cold_start.sh' \
        "$REPO_ROOT/deploy/scripts/tests/run-vmate-tests.py"
    require_text 'test_windows_hyperv_display_topology.sh' \
        "$REPO_ROOT/deploy/scripts/tests/run-vmate-tests.py"
    require_text 'test_windows_hyperv_metadata_exchange.sh' \
        "$REPO_ROOT/deploy/scripts/tests/run-vmate-tests.py"
    require_text 'test_windows_hyperv_network_identity.sh' \
        "$REPO_ROOT/deploy/scripts/tests/run-vmate-tests.py"
    require_text 'test_windows_gpup_hardware_identity.sh' \
        "$REPO_ROOT/deploy/scripts/tests/run-vmate-tests.py"
    require_text 'test_windows_gpup_guest_identity.sh' \
        "$REPO_ROOT/deploy/scripts/tests/run-vmate-tests.py"
    require_text 'test_windows_gpup_vm_configuration.sh' \
        "$REPO_ROOT/deploy/scripts/tests/run-vmate-tests.py"
    require_text 'test_windows_gpup_hardware_profile.sh' \
        "$REPO_ROOT/deploy/scripts/tests/run-vmate-tests.py"
    require_text 'test_windows_gpup_detection_parity.sh' \
        "$REPO_ROOT/deploy/scripts/tests/run-vmate-tests.py"
}

test_files_and_encoding
test_dynamic_gpu_contract
test_identity_contract
test_identity_pure_functions
test_full_shared_quota_argument_contract
test_packaging_and_documentation_contract
echo 'PASS: Windows GPU-P workflow and identity contract'
