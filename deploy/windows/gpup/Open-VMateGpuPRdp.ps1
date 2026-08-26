#Requires -Version 5.1

<#
.SYNOPSIS
    安全复用已经配置的 P-11 动态 RDP 连接，不读取或保存 guest 密码。
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$VMName,
    [string]$StateDirectory =
        (Join-Path $env:ProgramData 'VMate\GpuP\Connections'),
    [switch]$NoLaunch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'VMate.HyperV.RdpConnection.ps1')

$result = Open-VMateGpuPExistingRdp -VMName $VMName `
    -StateDirectory $StateDirectory -NoLaunch:$NoLaunch
$result | ConvertTo-Json -Depth 8 -Compress
