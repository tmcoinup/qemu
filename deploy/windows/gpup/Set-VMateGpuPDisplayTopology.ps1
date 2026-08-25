#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$VMName,
    [Parameter(Mandatory = $true)][string]$ReceiptPath,
    [ValidateSet('EnhancedSessionGpuOnly')]
    [string]$Mode = 'EnhancedSessionGpuOnly',
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'VMate.HyperV.DisplayTopology.ps1')

Set-VMateHyperVDisplayTopology -VMName $VMName `
    -ReceiptPath $ReceiptPath -Mode $Mode -DryRun:$DryRun
