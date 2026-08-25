#Requires -Version 5.1

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$VMName,

    [string]$StateRoot = '',

    [ValidateRange(1, 300)]
    [int]$HostLockTimeoutSeconds = 120,

    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'VMate.GpuP.Host.ps1')
. (Join-Path $PSScriptRoot 'VMate.GpuP.Identity.ps1')

Assert-VMateGpuPHostEnvironment
$configurationLock = Enter-VMateGpuPConfigurationLock `
    -TimeoutSeconds $HostLockTimeoutSeconds
try {
$vm = Get-VMateGpuPVirtualMachine -VMName $VMName
Assert-VMateGpuPVirtualMachine -VM $vm
$adapters = @(Get-VMGpuPartitionAdapter -VM $vm -ErrorAction Stop)
$identity = Get-VMateGpuPIdentity -VMId $vm.Id -StateRoot $StateRoot
if ($adapters.Count -gt 1) {
    throw '该 VM 有多个 GPU-P adapter；P-11 不会猜测应删除哪一个。'
}
if ($adapters.Count -eq 1) {
    if ($null -eq $identity -or
        [String]::IsNullOrWhiteSpace([string]$identity.GpuInstancePath)) {
        throw '唯一 GPU-P adapter 没有有效 P-11 身份绑定；拒绝删除手工 adapter。'
    }
    $hostGpus = @(Get-VMateGpuPHostPartitionableGpu)
    $ownership = Get-VMateGpuPAdapterOwnership $adapters[0] `
        ([string]$identity.GpuInstancePath) `
        @($hostGpus | ForEach-Object { [string]$_.Name })
    if ($ownership.Ownership -cne 'SelectedGpu') {
        throw 'GPU-P adapter 路径与 P-11 身份不唯一匹配；拒绝删除。'
    }
    $vendor = Get-VMateGpuPVendorInfo ([string]$identity.GpuInstancePath)
    if ([string]$vendor.Vendor -ine [string]$identity.Vendor) {
        throw 'P-11 身份的 GPU 路径与厂商不一致；拒绝删除 adapter。'
    }
}

$plan = [pscustomobject][ordered]@{
    Action = if ($adapters.Count -eq 0) { 'None' } else { 'RemoveGpuPartitionAdapter' }
    VMName = $VMName
    VMId = [string]$vm.Id
    AdapterCount = $adapters.Count
    DriverFilesPreserved = $true
    IdentityPreserved = $true
}
if ($DryRun) {
    return $plan
}

if ($adapters.Count -eq 0) {
    if ($null -ne $identity) {
        [void](Update-VMateGpuPObservedIdentity -VMId $vm.Id `
                -PartitionId $null -PartitionVfLuid $null `
                -StateRoot $StateRoot)
    }
    return $plan
}

if ($PSCmdlet.ShouldProcess($VMName, '删除唯一 GPU-P adapter')) {
    Remove-VMGpuPartitionAdapter -VMGpuPartitionAdapter $adapters[0] `
        -Confirm:$false -ErrorAction Stop
}
else {
    return $plan
}
$remaining = @(Get-VMGpuPartitionAdapter -VM $vm -ErrorAction Stop)
if ($remaining.Count -ne 0) {
    throw 'GPU-P adapter 删除后的回读不为空。'
}
if ($null -ne $identity) {
    [void](Update-VMateGpuPObservedIdentity -VMId $vm.Id `
            -PartitionId $null -PartitionVfLuid $null `
            -StateRoot $StateRoot)
}
return $plan
}
finally {
    Exit-VMateGpuPConfigurationLock -Mutex $configurationLock
}
