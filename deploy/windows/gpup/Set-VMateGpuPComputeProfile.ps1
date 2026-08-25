#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$VMName,
    [ValidateRange(0, 256)][int]$ProcessorCount = 0,
    [ValidateRange(-1, 100)][int]$CpuMaximumPercent = -1,
    [ValidateRange(-1, 100)][int]$CpuReservePercent = -1,
    [ValidateRange(0, 10000)][int]$CpuRelativeWeight = 0,
    [ValidateRange(0, 64)][int]$HwThreadCountPerCore = 0,
    [Nullable[bool]]$ExposeVirtualizationExtensions = $null,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'VMate.HyperV.ComputeProfile.ps1')
. (Join-Path $PSScriptRoot 'VMate.GpuP.HardwareProfile.ps1')

$vm = Get-VM -Name $VMName -ErrorAction Stop
$current = Get-VMateHyperVComputeSnapshot $vm
$profile = New-VMateHyperVComputeProfile `
    -ProcessorCount $(if ($ProcessorCount) { $ProcessorCount } else {
            $current.ProcessorCount }) `
    -CpuMaximumPercent $(if ($CpuMaximumPercent -ge 0) {
            $CpuMaximumPercent } else { $current.CpuMaximumPercent }) `
    -CpuReservePercent $(if ($CpuReservePercent -ge 0) {
            $CpuReservePercent } else { $current.CpuReservePercent }) `
    -CpuRelativeWeight $(if ($CpuRelativeWeight) { $CpuRelativeWeight } else {
            $current.CpuRelativeWeight }) `
    -HwThreadCountPerCore $(if ($HwThreadCountPerCore) {
            $HwThreadCountPerCore } else { $current.HwThreadCountPerCore }) `
    -ExposeVirtualizationExtensions $(if ($null -ne
            $ExposeVirtualizationExtensions) {
            [bool]$ExposeVirtualizationExtensions
        } else { $current.ExposeVirtualizationExtensions })

$binding = Get-VMateGpuPHardwareProfileBinding -VMId ([Guid]$vm.Id)
if ($null -ne $binding) {
    [void](Assert-VMateGpuPHardwareProfileOverrides $binding @{
            ProcessorCount = $profile.ProcessorCount
            CpuMaximumPercent = $profile.CpuMaximumPercent
            CpuReservePercent = $profile.CpuReservePercent
            CpuRelativeWeight = $profile.CpuRelativeWeight
            HwThreadCountPerCore = $profile.HwThreadCountPerCore
            ExposeVirtualizationExtensions = $profile.ExposeVirtualizationExtensions
        })
}

Set-VMateHyperVComputeProfile -VM $vm -Profile $profile -DryRun:$DryRun
