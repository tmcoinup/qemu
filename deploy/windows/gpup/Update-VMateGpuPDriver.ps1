#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$VMName,

    [string]$VhdPath = '',

    [string]$StateRoot = '',

    [ValidateRange(1, 300)]
    [int]$HostLockTimeoutSeconds = 120,

    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'VMate.GpuP.Host.ps1')
. (Join-Path $PSScriptRoot 'VMate.GpuP.DriverStore.ps1')
. (Join-Path $PSScriptRoot 'VMate.GpuP.Identity.ps1')

Assert-VMateGpuPHostEnvironment
$configurationLock = Enter-VMateGpuPConfigurationLock `
    -TimeoutSeconds $HostLockTimeoutSeconds
try {
$vm = Get-VMateGpuPVirtualMachine -VMName $VMName
Assert-VMateGpuPVirtualMachine -VM $vm
$identity = Get-VMateGpuPIdentity -VMId $vm.Id -StateRoot $StateRoot
if ($null -eq $identity -or
    [String]::IsNullOrWhiteSpace([string]$identity.GpuInstancePath)) {
    throw '该 VM 没有已固定的 P-11 GPU-P 身份与物理 GPU 绑定。'
}
$adapters = @(Get-VMGpuPartitionAdapter -VM $vm -ErrorAction Stop)
if ($adapters.Count -gt 1) {
    throw '该 VM 有多个 GPU-P adapter，拒绝猜测应同步哪个厂商包。'
}
$hostGpus = @(Get-VMHostPartitionableGpu -ErrorAction Stop)
$boundHostGpus = @($hostGpus | Where-Object {
        $null -ne $_.PSObject.Properties['Name'] -and
        [string]::Equals([string]$_.Name,
            [string]$identity.GpuInstancePath,
            [StringComparison]::OrdinalIgnoreCase)
    })
if ($boundHostGpus.Count -ne 1) {
    throw '持久化物理 GPU 绑定已不在当前 partitionable GPU 集合中。'
}
$boundVendor = Get-VMateGpuPVendorInfo ([string]$boundHostGpus[0].Name)
if ([string]$boundVendor.Vendor -ine [string]$identity.Vendor) {
    throw '当前 partitionable GPU 厂商与 VM 持久化身份不一致。'
}
if ($adapters.Count -eq 1) {
    if (-not (Test-VMateGpuPAdapterForGpu -Adapter $adapters[0] `
                -InstancePath ([string]$identity.GpuInstancePath) `
                -SupportedGpuCount $hostGpus.Count)) {
        throw '当前 GPU-P adapter 与持久化物理 GPU 绑定不一致。'
    }
}

$pnpInstanceId = ConvertTo-VMateGpuPInstanceId `
    -PartitionableName ([string]$identity.GpuInstancePath)
$selection = Get-VMateGpuPDriverSelection -GpuInstanceId $pnpInstanceId
if ([string]$selection.Vendor.Vendor -ne [string]$identity.Vendor) {
    throw '当前物理 GPU 驱动厂商与 VM 持久化身份不一致。'
}
$result = Sync-VMateGpuPDriverStore -VMName $VMName `
    -VhdPath $VhdPath -GpuInstanceId $pnpInstanceId -DryRun:$DryRun

if (-not $DryRun) {
    $identity = Set-VMateGpuPIdentityBinding -VMId $vm.Id `
        -Vendor ([string]$identity.Vendor) `
        -GpuInstancePath ([string]$identity.GpuInstancePath) `
        -HostGpuName ([string]$selection.Pnp.Name) `
        -DriverVersion ([string]$selection.SignedDriver.DriverVersion) `
        -DriverInf ([string]$selection.SignedDriver.InfName) `
        -StateRoot $StateRoot
}

return [pscustomobject][ordered]@{
    Status = if ($DryRun) { 'DryRun' } else { 'Updated' }
    VMName = $VMName
    VMId = [string]$vm.Id
    Vendor = [string]$selection.Vendor.Vendor
    DeviceName = [string]$selection.Pnp.Name
    InstancePath = [string]$identity.GpuInstancePath
    DriverVersion = [string]$selection.SignedDriver.DriverVersion
    DriverInf = [string]$selection.SignedDriver.InfName
    DriverSync = $result
}
}
finally {
    Exit-VMateGpuPConfigurationLock -Mutex $configurationLock
}
