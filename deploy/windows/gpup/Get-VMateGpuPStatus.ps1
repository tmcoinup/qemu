#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$VMName = '',

    [string]$StateRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'VMate.GpuP.Host.ps1')
. (Join-Path $PSScriptRoot 'VMate.GpuP.DriverStore.ps1')
. (Join-Path $PSScriptRoot 'VMate.GpuP.Identity.ps1')
. (Join-Path $PSScriptRoot 'VMate.GpuP.HardwareIdentity.ps1')
. (Join-Path $PSScriptRoot 'VMate.GpuP.HardwareProfile.ps1')
. (Join-Path $PSScriptRoot 'VMate.GpuP.Display.ps1')
. (Join-Path $PSScriptRoot 'VMate.HyperV.ComputeProfile.ps1')
. (Join-Path $PSScriptRoot 'VMate.HyperV.DisplayTopology.ps1')
. (Join-Path $PSScriptRoot 'VMate.HyperV.MetadataExchange.ps1')
. (Join-Path $PSScriptRoot 'VMate.HyperV.IdentityBoot.ps1')
. (Join-Path $PSScriptRoot 'VMate.HyperV.HostIdentityExtension.ps1')
. (Join-Path $PSScriptRoot 'VMate.Windows.CodeIntegrity.ps1')

Assert-VMateGpuPHostEnvironment
$hostCodeIntegrity = Get-VMateWindowsCodeIntegrityStatus
$hostCodeIntegrity | Add-Member -NotePropertyName Policy -NotePropertyValue `
    'default-p11-requires-production-code-integrity; paused-cpuid-extension-disabled'
$gpuStatus = @()
foreach ($gpu in @(Get-VMateGpuPHostPartitionableGpu)) {
    try {
        $vendorInfo = Get-VMateGpuPVendorInfo -InstancePath ([string]$gpu.Name)
        $instanceId = ConvertTo-VMateGpuPInstanceId -PartitionableName ([string]$gpu.Name)
        $selection = Get-VMateGpuPDriverSelection -GpuInstanceId $instanceId
        $capability = Get-VMateGpuPCapabilitySnapshot -HostGpu $gpu `
            -VendorInfo $vendorInfo
        $gpuStatus += [pscustomobject][ordered]@{
            Vendor = [string]$vendorInfo.Vendor
            VendorId = [string]$vendorInfo.VendorId
            DeviceName = [string]$selection.Pnp.Name
            InstancePath = [string]$gpu.Name
            PnpInstanceId = $instanceId
            DriverProvider = [string]$selection.SignedDriver.DriverProviderName
            DriverVersion = [string]$selection.SignedDriver.DriverVersion
            DriverInf = [string]$selection.SignedDriver.InfName
            PartitionCount = $gpu.PartitionCount
            ValidPartitionCounts = @($gpu.ValidPartitionCounts)
            TotalVRAM = $gpu.TotalVRAM
            TotalEncode = $gpu.TotalEncode
            TotalDecode = $gpu.TotalDecode
            TotalCompute = $gpu.TotalCompute
            Resources = $capability.Resources
            FullHostVramQuotaAvailable = (
                [uint64]$capability.Resources.VRAM.MaxPartition -eq
                [uint64]$capability.Resources.VRAM.Total)
            Ready = $true
            Error = ''
        }
    }
    catch {
        $gpuStatus += [pscustomobject][ordered]@{
            Vendor = ''
            VendorId = ''
            DeviceName = ''
            InstancePath = [string]$gpu.Name
            PnpInstanceId = ''
            DriverProvider = ''
            DriverVersion = ''
            DriverInf = ''
            PartitionCount = $gpu.PartitionCount
            ValidPartitionCounts = @($gpu.ValidPartitionCounts)
            TotalVRAM = $gpu.TotalVRAM
            TotalEncode = $gpu.TotalEncode
            TotalDecode = $gpu.TotalDecode
            TotalCompute = $gpu.TotalCompute
            Resources = $null
            FullHostVramQuotaAvailable = $false
            Ready = $false
            Error = $_.Exception.Message
        }
    }
}

$vmStatus = $null
if (-not [String]::IsNullOrWhiteSpace($VMName)) {
    $vm = Get-VMateGpuPVirtualMachine -VMName $VMName
    $adapters = @(Get-VMGpuPartitionAdapter -VM $vm -ErrorAction Stop)
    $identity = Get-VMateGpuPIdentity -VMId $vm.Id -StateRoot $StateRoot
    $hardwareProfile = Get-VMateGpuPHardwareProfileBinding `
        -VMId $vm.Id -StateRoot $StateRoot
    $identityBoot = if ($null -eq $hardwareProfile) {
        [pscustomobject][ordered]@{
            State = 'Unbound'; Required = $false; Integrity = $null
            Capability = 'guest-boot-smbios-only'
        }
    }
    elseif (-not [bool]$hardwareProfile.RequiresHostExtension) {
        [pscustomobject][ordered]@{
            State = 'NotRequired'; Required = $false; Integrity = $true
            ProfileId = [string]$hardwareProfile.ProfileId
            Capability = 'guest-boot-smbios-only'
        }
    }
    elseif ([string]$vm.State -cne 'Off') {
        [pscustomobject][ordered]@{
            State = 'UnavailableWhileRunning'; Required = $true
            Integrity = $null
            ProfileId = [string]$hardwareProfile.ProfileId
            SecureBoot = [string](Get-VMFirmware -VM $vm `
                -ErrorAction Stop).SecureBoot
            Capability = 'guest-boot-smbios-only'
        }
    }
    else {
        try {
            $bootStatus = Get-VMateHyperVIdentityBootStatus -VM $vm
            $bootStatus | Add-Member -NotePropertyName Required `
                -NotePropertyValue $true
            $bootStatus
        }
        catch {
            [pscustomobject][ordered]@{
                State = 'Error'; Required = $true; Integrity = $false
                ProfileId = [string]$hardwareProfile.ProfileId
                Error = $_.Exception.Message
                Capability = 'guest-boot-smbios-only'
            }
        }
    }
    $displayTopology = Get-VMateHyperVDisplayTopologySnapshot `
        -VMName ([string]$vm.Name)
    $metadataExchange = Get-VMateHyperVMetadataExchangeHostSnapshot `
        -VMName ([string]$vm.Name)
    $vmStatus = [pscustomobject][ordered]@{
        Name = [string]$vm.Name
        Id = [string]$vm.Id
        State = [string]$vm.State
        Generation = [int]$vm.Generation
        ConfigurationVersion = [string]$vm.Version
        GpuPartitionAdapters = $adapters
        GpuPVMConfiguration = Get-VMateGpuPVMConfigurationSnapshot -VM $vm
        DisplayTopology = $displayTopology
        ConsoleProfile = $displayTopology.Console
        MetadataExchange = $metadataExchange
        ComputeProfile = Get-VMateHyperVComputeSnapshot -VM $vm
        Identity = $identity
        HardwareProfile = $hardwareProfile
        HardwareIdentity = Get-VMateGpuPHardwareIdentityStatus `
            -VM $vm -StateRoot $StateRoot
        IdentityBoot = $identityBoot
        HostIdentityExtension = Get-VMateHyperVHostIdentityExtensionStatus `
            -VMId ([Guid]$vm.Id) -StateRoot $StateRoot
    }
}

$os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
$identityAudit = Test-VMateGpuPIdentityUniqueness -StateRoot $StateRoot
$hardwareIdentityAudit = Test-VMateGpuPHardwareIdentityUniqueness `
    -StateRoot $StateRoot
[pscustomobject][ordered]@{
    Backend = 'Hyper-V GPU-P'
    ComputerName = $env:COMPUTERNAME
    OperatingSystem = [string]$os.Caption
    OperatingSystemVersion = [string]$os.Version
    HostCodeIntegrity = $hostCodeIntegrity
    PartitionableGpus = $gpuStatus
    HostIndirectDisplayAdapters = @(Get-VMateGpuPHostIndirectDisplayAdapter)
    VM = $vmStatus
    IdentityAudit = $identityAudit
    HardwareIdentityAudit = $hardwareIdentityAudit
    ProductionSupportInferred = $false
    ProductionSupportNote = '是否受厂商生产支持必须按宿主 OS、服务器型号、GPU 和驱动授权矩阵核对。'
}
