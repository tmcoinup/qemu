#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$VMName,
    [Parameter(Mandatory = $true)][PSCredential]$GuestCredential,
    [Parameter(Mandatory = $true)][string]$ReceiptPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'VMate.HyperV.MetadataExchange.ps1')

Restore-VMateHyperVMetadataExchange -VMName $VMName `
    -GuestCredential $GuestCredential -ReceiptPath $ReceiptPath
