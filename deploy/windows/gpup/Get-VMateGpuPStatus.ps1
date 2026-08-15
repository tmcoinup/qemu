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
. (Join-Path $PSScriptRoot 'VMate.GpuP.Display.ps1')

Assert-VMateGpuPHostEnvironment
$gpuStatus = @()
foreach ($gpu in @(Get-VMHostPartitionableGpu -ErrorAction Stop)) {
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
    $vmStatus = [pscustomobject][ordered]@{
        Name = [string]$vm.Name
        Id = [string]$vm.Id
        State = [string]$vm.State
        Generation = [int]$vm.Generation
        GpuPartitionAdapters = $adapters
        Identity = $identity
        HardwareIdentity = Get-VMateGpuPHardwareIdentityStatus `
            -VM $vm -StateRoot $StateRoot
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
    PartitionableGpus = $gpuStatus
    HostIndirectDisplayAdapters = @(Get-VMateGpuPHostIndirectDisplayAdapter)
    VM = $vmStatus
    IdentityAudit = $identityAudit
    HardwareIdentityAudit = $hardwareIdentityAudit
    ProductionSupportInferred = $false
    ProductionSupportNote = '是否受厂商生产支持必须按宿主 OS、服务器型号、GPU 和驱动授权矩阵核对。'
}
