#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    解析 GPU-P guest 当前地址并以无密码 RDP 配置连接。
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$VMName,
    [Parameter(Mandatory = $true)][PSCredential]$GuestCredential,
    [string]$StateDirectory =
        (Join-Path $env:ProgramData 'VMate\GpuP\Connections'),
    [ValidateRange(800, 7680)][int]$Width = 2560,
    [ValidateRange(600, 4320)][int]$Height = 1440,
    [switch]$FullScreen,
    [switch]$NoLaunch,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'VMate.HyperV.EnhancedSession.ps1')
. (Join-Path $PSScriptRoot 'VMate.HyperV.RdpConnection.ps1')

Connect-VMateGpuPRdp -VMName $VMName -GuestCredential $GuestCredential `
    -StateDirectory $StateDirectory -Width $Width -Height $Height `
    -FullScreen:$FullScreen -NoLaunch:$NoLaunch -DryRun:$DryRun
