#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$VMName,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()]
    [string]$HardwareProfileId,
    [string]$HardwareProfileCatalogPath = '',
    [string]$StateRoot = '',
    [switch]$AllowReprofile,
    [string]$ReprofileReason = '',
    [switch]$AllowDisableSecureBoot,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'VMate.GpuP.Lifecycle.ps1')
. (Join-Path $PSScriptRoot 'VMate.GpuP.HardwareReprofile.ps1')

Assert-VMateHyperVAdministrator
Import-Module Hyper-V -ErrorAction Stop
$matches = @(Get-VM -Name $VMName -ErrorAction Stop)
if ($matches.Count -ne 1) {
    throw "Hyper-V VM 名称无法唯一解析：$VMName"
}
Invoke-VMateGpuPHardwareReprofile -VM $matches[0] `
    -HardwareProfileId $HardwareProfileId `
    -HardwareProfileCatalogPath $HardwareProfileCatalogPath `
    -StateRoot $StateRoot -AllowReprofile:$AllowReprofile `
    -ReprofileReason $ReprofileReason `
    -AllowDisableSecureBoot:$AllowDisableSecureBoot -DryRun:$DryRun
