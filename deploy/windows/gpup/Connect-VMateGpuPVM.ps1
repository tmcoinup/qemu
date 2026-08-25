#Requires -Version 5.1

<#
.SYNOPSIS
    以固定 Enhanced Session 路径打开 GPU-P VM 控制台。
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$VMName,
    [switch]$Edit,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module Hyper-V -ErrorAction Stop
if ($VMName -match '["\r\n]') { throw 'VMName 含无效字符。' }
$vm = Get-VM -Name $VMName -ErrorAction Stop
$hostState = Get-VMHost -ErrorAction Stop
if ([string]$vm.State -cne 'Running' -or
    [string]$vm.EnhancedSessionTransportType -cne 'VMBus' -or
    -not [bool]$hostState.EnableEnhancedSessionMode) {
    throw 'VMConnect Enhanced Session 尚未就绪。'
}
$vmConnect = Join-Path $env:SystemRoot 'System32\vmconnect.exe'
if (-not (Test-Path -LiteralPath $vmConnect -PathType Leaf)) {
    throw "找不到 inbox VMConnect：$vmConnect"
}
$signature = Get-AuthenticodeSignature -LiteralPath $vmConnect
if ([string]$signature.Status -cne 'Valid' -or
    $null -eq $signature.SignerCertificate -or
    [string]$signature.SignerCertificate.Subject -notmatch
        '(?i)(Microsoft Windows|Microsoft Corporation)') {
    throw 'VMConnect 不是有效的 Microsoft 签名文件。'
}
$arguments = @('localhost', ('"{0}"' -f $VMName))
if ($Edit) { $arguments += '/edit' }
$plan = [pscustomobject][ordered]@{
    VMName = [string]$vm.Name
    VMId = ([Guid]$vm.Id).ToString('D')
    Transport = 'VMBus'
    FilePath = $vmConnect
    Arguments = $arguments
    RuntimeModelSwitch = $false
}
if ($DryRun) { return $plan }
$process = Start-Process -FilePath $vmConnect -ArgumentList $arguments `
    -PassThru -ErrorAction Stop
$plan | Add-Member -NotePropertyName ProcessId `
    -NotePropertyValue ([int]$process.Id)
return $plan
