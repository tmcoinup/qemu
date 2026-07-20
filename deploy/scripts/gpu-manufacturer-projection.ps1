#Requires -Version 5.1

<#
.SYNOPSIS
  独立投影设备管理器“常规”页制造商，同时复核真实签名驱动未变化。

.DESCRIPTION
  stock VioGpuDod 的 Enum Mfg、Class ProviderName 与 INF/CAT 仍保持 Red Hat。
  本脚本只调用同目录的 Config Manager 小工具设置
  DEVPKEY_Device_Manufacturer，并在写入前后验证 Win32_PnPSignedDriver。
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('AMD', 'NVIDIA')]
    [string]$Vendor,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^PCI\\VEN_1AF4&DEV_1050(?:&|\\)')]
    [string]$InstanceId,

    [string]$ProjectorPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-TrustedDisplayBinding {
    param([Parameter(Mandatory = $true)][string]$ExpectedInstanceId)

    $matches = @(Get-CimInstance -ClassName Win32_PnPSignedDriver `
        -ErrorAction Stop | Where-Object {
            [string]$_.DeviceID -ieq $ExpectedInstanceId
        })
    if ($matches.Count -ne 1) {
        throw ('签名驱动匹配数不是 1：' + $matches.Count)
    }
    $binding = $matches[0]
    if ([string]$binding.InfName -notmatch '^oem[0-9]+\.inf$' -or
        [string]$binding.DriverProviderName -ine 'Red Hat, Inc.' -or
        [bool]$binding.IsSigned -ne $true -or
        [string]$binding.Signer -ine
            'Microsoft Windows Hardware Compatibility Publisher') {
        throw ('VioGpuDod 签名绑定不可信：' + [string]$binding.InfName + '/' +
            [string]$binding.DriverProviderName + '/' +
            [string]$binding.IsSigned + '/' + [string]$binding.Signer)
    }
    return [pscustomobject]@{
        InfName = [string]$binding.InfName
        Provider = [string]$binding.DriverProviderName
        IsSigned = [bool]$binding.IsSigned
        Signer = [string]$binding.Signer
    }
}

function Assert-SameBinding {
    param(
        [Parameter(Mandatory = $true)]$Before,
        [Parameter(Mandatory = $true)]$After
    )

    if ($After.InfName -cne $Before.InfName -or
        $After.Provider -cne $Before.Provider -or
        $After.IsSigned -ne $Before.IsSigned -or
        $After.Signer -cne $Before.Signer) {
        throw '制造商 UI 投影改变了真实签名驱动绑定'
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
    [string]$property.Data -cne $Vendor) {
    throw ('制造商属性回读不一致：' + [string]$property.Type + '/' +
        [string]$property.Data)
}

$after = Get-TrustedDisplayBinding -ExpectedInstanceId $InstanceId
Assert-SameBinding -Before $before -After $after
Write-Host ('设备制造商 UI 已投影为 ' + $Vendor +
    '；真实驱动仍由 Microsoft WHCP 签名。') -ForegroundColor Green
