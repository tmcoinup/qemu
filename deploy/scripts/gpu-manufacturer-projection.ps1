#Requires -Version 5.1

<#
.SYNOPSIS
  独立投影设备管理器“常规”页制造商，同时复核真实驱动信任链未变化。

.DESCRIPTION
  stock VioGpuDod 的 INF/CAT 与真实驱动绑定仍保持 Red Hat。本脚本只调用同目录的
  Config Manager 小工具设置
  DEVPKEY_Device_Manufacturer，并在写入前后直接验证 PnP/INF/SYS/WHCP。
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('AMD', 'NVIDIA')]
    [string]$Vendor,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^PCI\\VEN_1AF4&DEV_1050(?:&|\\)')]
    [string]$InstanceId,

    [string]$ProjectorPath = '',

    [string]$SystemDirectory = [Environment]::SystemDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$identityContract = Join-Path $PSScriptRoot 'gpu-board-identity-contract.ps1'
if (-not (Test-Path -LiteralPath $identityContract -PathType Leaf)) {
    throw ('缺少 GPU 厂商展示合同：' + $identityContract)
}
. $identityContract

$trustHelper = Join-Path $PSScriptRoot 'display-driver-trust.ps1'
if (-not (Test-Path -LiteralPath $trustHelper -PathType Leaf)) {
    throw ('缺少显示驱动信任 helper：' + $trustHelper)
}
. $trustHelper

function Get-TrustedDisplayBinding {
    param([Parameter(Mandatory = $true)][string]$ExpectedInstanceId)

    $matches = @(Get-PciDisplayState | Where-Object {
        [string]$_.InstanceId -ieq $ExpectedInstanceId
    })
    if ($matches.Count -ne 1) {
        throw ('活动显示绑定匹配数不是 1：' + $matches.Count)
    }
    $binding = $matches[0]
    $problems = @(Get-DisplayStateProblems -State $binding)
    if ($problems.Count -ne 0) {
        throw ('VioGpuDod PnP 绑定不可信：' + ($problems -join ', '))
    }
    try {
        [void] (Assert-ActiveStockDriver -States @($binding) `
            -SystemDirectory $SystemDirectory -ThrowOnFailure)
    } catch {
        throw ('VioGpuDod 直接信任校验失败：' + $_.Exception.Message)
    }
    return [pscustomobject]@{
        InstanceId = [string]$binding.InstanceId
        Service = [string]$binding.Service
        InfPath = [string]$binding.InfPath
    }
}

function Assert-SameBinding {
    param(
        [Parameter(Mandatory = $true)]$Before,
        [Parameter(Mandatory = $true)]$After
    )

    if ($After.InstanceId -cne $Before.InstanceId -or
        $After.Service -cne $Before.Service -or
        $After.InfPath -cne $Before.InfPath) {
        throw '制造商 UI 投影改变了真实驱动绑定'
    }
}

$present = @(Get-PnpDevice -Class Display -PresentOnly -ErrorAction Stop |
    Where-Object {
        [string]$_.InstanceId -ieq $InstanceId -and
        [string]$_.Status -ieq 'OK'
    })
if ($present.Count -ne 1) {
    throw ('目标显示设备未唯一在线或状态非 OK：' + $InstanceId)
}

if ([string]::IsNullOrWhiteSpace($ProjectorPath)) {
    $ProjectorPath = Join-Path $PSScriptRoot 'gpu-manufacturer-projector.exe'
}
$ProjectorPath = [IO.Path]::GetFullPath($ProjectorPath)
if (-not (Test-Path -LiteralPath $ProjectorPath -PathType Leaf)) {
    throw ('缺少制造商投影器：' + $ProjectorPath)
}
$projectorItem = Get-Item -LiteralPath $ProjectorPath -Force -ErrorAction Stop
if (($projectorItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw ('制造商投影器不能是重解析点：' + $ProjectorPath)
}

$manufacturerName = Get-GpuWindowsManufacturerName -Vendor $Vendor
$before = Get-TrustedDisplayBinding -ExpectedInstanceId $InstanceId
$projectorOutput = @(& $ProjectorPath $Vendor 2>&1)
$projectorExitCode = $LASTEXITCODE
if ($projectorExitCode -ne 0) {
    throw ('制造商投影器失败，退出码=' + $projectorExitCode + '，输出=' +
        ($projectorOutput -join ' | '))
}

$property = Get-PnpDeviceProperty -InstanceId $InstanceId `
    -KeyName 'DEVPKEY_Device_Manufacturer' -ErrorAction Stop
if ([string]$property.Type -ine 'String' -or
    [string]$property.Data -cne $manufacturerName) {
    throw ('制造商属性回读不一致：' + [string]$property.Type + '/' +
        [string]$property.Data)
}

$after = Get-TrustedDisplayBinding -ExpectedInstanceId $InstanceId
Assert-SameBinding -Before $before -After $after
Write-Host ('设备制造商 UI 已投影为 ' + $manufacturerName +
    '；活动 INF/SYS 仍通过 Microsoft WHCP 直接信任校验。') -ForegroundColor Green
