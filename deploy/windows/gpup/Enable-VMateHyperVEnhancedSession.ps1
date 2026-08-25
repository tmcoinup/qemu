#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    为一台 Running GPU-P VM 启用 VMConnect Enhanced Session。
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$VMName,
    [Parameter(Mandatory = $true)][PSCredential]$GuestCredential
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'VMate.HyperV.EnhancedSession.ps1')

Enable-VMateHyperVEnhancedSession -VMName $VMName `
    -GuestCredential $GuestCredential
