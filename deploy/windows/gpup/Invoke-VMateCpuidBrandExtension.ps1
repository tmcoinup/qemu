#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    为已暂停、刚冷启动的授权 Hyper-V 实验 VM 注册三个 CPU 品牌叶。

.DESCRIPTION
    仅允许 CPUID 0x80000002..0x80000004。调用前固定校验 VM 状态、worker
    归属、driver/vmwp/vid.dll/vid.sys 的签名与 SHA-256，并要求实际代码完整性
    处于 test-signing。驱动不暴露设备接口；部分失败会在卸载前回滚。
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$VMName,
    [Parameter(Mandatory = $true)][Guid]$VMId,
    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 2147483647)]
    [int]$TargetProcessId,
    [Parameter(Mandatory = $true)]
    [ValidateScript({ $_ -ne [UInt64]0 })]
    [UInt64]$PartitionHandle,
    [Parameter(Mandatory = $true)]
    [ValidateScript({ $_ -ne [UInt64]0 })]
    [UInt64]$ExpectedPartitionId,
    [Parameter(Mandatory = $true)][string]$BrandString,
    [string]$DriverPath = '',
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$ExpectedDriverSha256,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$ExpectedVmwpSha256,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$ExpectedVidSha256,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$ExpectedVidSysSha256,
    [ValidateRange(0.01, 30)][double]$MaxPausedUptimeSeconds = 0.25
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([String]::IsNullOrWhiteSpace($DriverPath)) {
    $DriverPath = Join-Path $PSScriptRoot `
        'native\bin\VMateCpuidBrandExtension.sys'
}

function Assert-VMateCpuidBrandFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256,
        [Parameter(Mandatory = $true)][string]$Description,
        [switch]$RequireMicrosoftSigner
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Description 不存在：$Path"
    }
    $actualHash = (Get-FileHash -LiteralPath $Path `
        -Algorithm SHA256).Hash
    if ($actualHash -cne $ExpectedSha256.ToUpperInvariant()) {
        throw "$Description SHA-256 不匹配；拒绝加载。"
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ([string]$signature.Status -cne 'Valid' -or
        $null -eq $signature.SignerCertificate) {
        throw "$Description Authenticode 签名无效；拒绝加载。"
    }
    if ($RequireMicrosoftSigner -and
        [string]$signature.SignerCertificate.Subject -notmatch
            '(?i)(Microsoft Windows|Microsoft Corporation)') {
        throw "$Description 不是 Microsoft 签名；拒绝加载。"
    }
    return [pscustomobject][ordered]@{
        Path = [IO.Path]::GetFullPath($Path)
        Sha256 = $actualHash
        Signer = [string]$signature.SignerCertificate.Subject
    }
}

function Get-VMateCpuidBrandCodeIntegrityOptions {
    if ($null -eq ('VMateCpuidBrand.NativeMethods' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace VMateCpuidBrand {
    public static class NativeMethods {
        [StructLayout(LayoutKind.Sequential)]
        public struct CodeIntegrityInformation {
            public UInt32 Length;
            public UInt32 Options;
        }
        [DllImport("ntdll.dll")]
        public static extern Int32 NtQuerySystemInformation(
            Int32 informationClass,
            ref CodeIntegrityInformation information,
            UInt32 informationLength,
            out UInt32 returnLength);
    }
}
'@
    }
    $information = New-Object `
        VMateCpuidBrand.NativeMethods+CodeIntegrityInformation
    $information.Length = 8
    [UInt32]$returnLength = 0
    $status = [VMateCpuidBrand.NativeMethods]::NtQuerySystemInformation(
        103, [ref]$information, 8, [ref]$returnLength)
    if ($status -ne 0) {
        throw ('读取 SystemCodeIntegrityInformation 失败：0x{0:X8}' -f `
            [UInt32]$status)
    }
    return [UInt32]$information.Options
}

function Invoke-VMateCpuidBrandSc {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $output = & "$env:SystemRoot\System32\sc.exe" @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "sc.exe $($Arguments[0]) 失败（$exitCode）：$output"
    }
    return @($output)
}

if ($BrandString.Length -lt 1 -or $BrandString.Length -gt 48 -or
    $BrandString -match '[^\x20-\x7e]') {
    throw 'BrandString 必须是 1..48 字节可打印 ASCII。'
}
$brandBytes = New-Object byte[] 48
for ($index = 0; $index -lt 48; $index++) { $brandBytes[$index] = 0x20 }
[Text.Encoding]::ASCII.GetBytes($BrandString).CopyTo($brandBytes, 0)
$brandLeaves = [ordered]@{}
for ($leafIndex = 0; $leafIndex -lt 3; $leafIndex++) {
    $registers = [Collections.Generic.List[string]]::new()
    for ($register = 0; $register -lt 4; $register++) {
        $offset = ($leafIndex * 16) + ($register * 4)
        [void]$registers.Add(('0x{0:X8}' -f `
                    [BitConverter]::ToUInt32($brandBytes, $offset)))
    }
    $brandLeaves[('0x{0:X8}' -f (0x80000002 + $leafIndex))] =
        @($registers)
}

Import-Module Hyper-V -ErrorAction Stop
$vm = Get-VM -Name $VMName -ErrorAction Stop
if ([Guid]$vm.Id -ne $VMId) {
    throw "VM $VMName 的 ID 与显式 VMId 不匹配。"
}
if ([string]$vm.State -cne 'Paused') {
    throw "VM $VMName 必须处于 Paused；禁止运行中切换 CPU 型号。"
}
$pausedUptimeSeconds = [double]$vm.Uptime.TotalSeconds
if ($pausedUptimeSeconds -gt $MaxPausedUptimeSeconds) {
    throw ("VM 已运行/暂停 {0:N3} 秒，超过冷启动窗口 {1} 秒。" -f
        $pausedUptimeSeconds, $MaxPausedUptimeSeconds)
}

$driverFullPath = [IO.Path]::GetFullPath($DriverPath)
$vmwpPath = Join-Path $env:SystemRoot 'System32\vmwp.exe'
$vidPath = Join-Path $env:SystemRoot 'System32\vid.dll'
$vidSysPath = Join-Path $env:SystemRoot 'System32\drivers\vid.sys'
$driverEvidence = Assert-VMateCpuidBrandFile `
    -Path $driverFullPath `
    -ExpectedSha256 $ExpectedDriverSha256 `
    -Description 'VMate CPUID brand extension'
$vmwpEvidence = Assert-VMateCpuidBrandFile `
    -Path $vmwpPath `
    -ExpectedSha256 $ExpectedVmwpSha256 `
    -Description 'vmwp.exe' `
    -RequireMicrosoftSigner
$vidEvidence = Assert-VMateCpuidBrandFile `
    -Path $vidPath `
    -ExpectedSha256 $ExpectedVidSha256 `
    -Description 'vid.dll' `
    -RequireMicrosoftSigner
$vidSysEvidence = Assert-VMateCpuidBrandFile `
    -Path $vidSysPath `
    -ExpectedSha256 $ExpectedVidSysSha256 `
    -Description 'vid.sys' `
    -RequireMicrosoftSigner

$codeIntegrityOptions = Get-VMateCpuidBrandCodeIntegrityOptions
$driverIsMicrosoftSigned = [string]$driverEvidence.Signer -match
    '(?i)(Microsoft Windows|Microsoft Corporation)'
if (-not $driverIsMicrosoftSigned -and
    ($codeIntegrityOptions -band [UInt32]0x2) -eq 0) {
    throw ('非 Microsoft 实验驱动要求实际 CodeIntegrityOptions 包含 ' +
        'CODEINTEGRITY_OPTION_TESTSIGN (0x2)；当前为 0x{0:X8}。' -f
        $codeIntegrityOptions)
}

$target = Get-CimInstance Win32_Process `
    -Filter "ProcessId = $TargetProcessId"
$vmIdText = $VMId.ToString('D')
if ($null -eq $target -or [string]$target.Name -ine 'vmwp.exe' -or
    [IO.Path]::GetFullPath([string]$target.ExecutablePath) -ine
        $vmwpPath -or
    [string]$target.CommandLine -notmatch
        [regex]::Escape($vmIdText)) {
    throw "PID $TargetProcessId 不是 VM $VMName 的 inbox vmwp.exe。"
}

$serviceName = 'VMateCpuidBrand_' + [Guid]::NewGuid().ToString('N')
$serviceKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$serviceName"
$parametersKey = Join-Path $serviceKey 'Parameters'
$created = $false
$started = $false
$applyResult = $null
$cleanupFailure = ''

try {
    Invoke-VMateCpuidBrandSc @(
        'create', $serviceName,
        'type=', 'kernel',
        'start=', 'demand',
        'error=', 'normal',
        'binPath=', $driverFullPath) | Out-Null
    $created = $true
    New-Item -Path $parametersKey -Force | Out-Null
    New-ItemProperty -Path $parametersKey -Name TargetProcessId `
        -PropertyType DWord -Value $TargetProcessId -Force | Out-Null
    New-ItemProperty -Path $parametersKey -Name PartitionHandle `
        -PropertyType QWord -Value $PartitionHandle -Force | Out-Null
    New-ItemProperty -Path $parametersKey -Name ExpectedPartitionId `
        -PropertyType QWord -Value $ExpectedPartitionId -Force | Out-Null
    New-ItemProperty -Path $parametersKey -Name BrandBytes `
        -PropertyType Binary -Value $brandBytes -Force | Out-Null

    $startOutput = & "$env:SystemRoot\System32\sc.exe" `
        @('start', $serviceName) 2>&1
    $startExitCode = $LASTEXITCODE
    $started = $startExitCode -eq 0
    $result = Get-ItemProperty -LiteralPath $parametersKey
    $required = @(
        'Completed', 'ContractVersion', 'ResidentAfterApply',
        'WhitelistedLeafCount', 'AlwaysOverride', 'RuntimeModelSwitch',
        'InputNtStatus',
        'ApplyNtStatus', 'ImageMatched', 'DuplicateNtStatus',
        'ThreadCreateNtStatus', 'ThreadWaitNtStatus',
        'CurrentProcessMatched', 'PartitionQueryNtStatus',
        'BufferAllocationNtStatus', 'BufferFreeNtStatus',
        'FastIoAvailable', 'FastIoHandled', 'ObservedPartitionId',
        'RegisterLeaf80000002NtStatus',
        'RegisterLeaf80000003NtStatus',
        'RegisterLeaf80000004NtStatus',
        'RollbackLeaf80000002NtStatus',
        'RollbackLeaf80000003NtStatus',
        'RollbackLeaf80000004NtStatus',
        'MutatingCalls', 'RollbackCalls', 'Applied')
    foreach ($name in $required) {
        if ($null -eq $result.PSObject.Properties[$name]) {
            throw ("扩展没有返回 $name；sc start ($startExitCode)：" +
                ($startOutput -join ' '))
        }
    }
    if ([int]$result.Completed -ne 1 -or
        [int]$result.ContractVersion -ne 2 -or
        [int]$result.ResidentAfterApply -ne 0 -or
        [int]$result.WhitelistedLeafCount -ne 3 -or
        [int]$result.AlwaysOverride -ne 1 -or
        [int]$result.RuntimeModelSwitch -ne 0 -or
        $startExitCode -eq 0 -or
        [int]$result.MutatingCalls -gt 5 -or
        [int]$result.RollbackCalls -gt 2) {
        throw 'CPUID brand extension 的非驻留/叶白名单契约无效。'
    }
    $registerStatuses = @(
        [UInt32]$result.RegisterLeaf80000002NtStatus,
        [UInt32]$result.RegisterLeaf80000003NtStatus,
        [UInt32]$result.RegisterLeaf80000004NtStatus)
    $applied = [int]$result.Applied -eq 1
    $successProof = $applied -and
        [UInt32]$result.InputNtStatus -eq 0 -and
        [UInt32]$result.ApplyNtStatus -eq 0 -and
        [UInt32]$result.PartitionQueryNtStatus -eq 0 -and
        [UInt64]$result.ObservedPartitionId -eq $ExpectedPartitionId -and
        @($registerStatuses | Where-Object { $_ -ne 0 }).Count -eq 0 -and
        [int]$result.MutatingCalls -eq 3 -and
        [int]$result.RollbackCalls -eq 0
    if ($applied -and -not $successProof) {
        throw '驱动声称 Applied，但成功证明不完整；拒绝接受。'
    }
    $applyResult = [pscustomobject][ordered]@{
        SchemaVersion = 2
        ContractId = 'vmate-p11-cpuid-brand-paused-cold-boot-v2'
        State = if ($successProof) { 'AppliedWhilePaused' }
            else { 'FailedOrRolledBack' }
        Applied = $successProof
        RuntimeModelSwitch = $false
        VMName = $VMName
        VMId = $vmIdText
        PausedUptimeSeconds = $pausedUptimeSeconds
        TargetProcessId = $TargetProcessId
        PartitionHandleHex = ('0x{0:X}' -f $PartitionHandle)
        ExpectedPartitionId = $ExpectedPartitionId
        ObservedPartitionId = [UInt64]$result.ObservedPartitionId
        BrandString = $BrandString
        BrandLeaves = [pscustomobject]$brandLeaves
        AlwaysOverride = $true
        StartExitCode = $startExitCode
        InputNtStatusHex = ('0x{0:X8}' -f [UInt32]$result.InputNtStatus)
        ApplyNtStatusHex = ('0x{0:X8}' -f [UInt32]$result.ApplyNtStatus)
        PartitionQueryNtStatusHex = ('0x{0:X8}' -f `
            [UInt32]$result.PartitionQueryNtStatus)
        RegisterNtStatusHex = @($registerStatuses | ForEach-Object {
                '0x{0:X8}' -f $_
            })
        RollbackNtStatusHex = @(
            ('0x{0:X8}' -f [UInt32]$result.RollbackLeaf80000002NtStatus)
            ('0x{0:X8}' -f [UInt32]$result.RollbackLeaf80000003NtStatus)
            ('0x{0:X8}' -f [UInt32]$result.RollbackLeaf80000004NtStatus))
        MutatingCalls = [int]$result.MutatingCalls
        RollbackCalls = [int]$result.RollbackCalls
        CurrentProcessMatched = [int]$result.CurrentProcessMatched -eq 1
        FastIoAvailable = [int]$result.FastIoAvailable -eq 1
        FastIoHandled = [int]$result.FastIoHandled -eq 1
        CodeIntegrityOptionsHex = ('0x{0:X8}' -f $codeIntegrityOptions)
        Driver = $driverEvidence
        Vmwp = $vmwpEvidence
        Vid = $vidEvidence
        VidSys = $vidSysEvidence
        ApplyNonce = [Guid]::NewGuid().ToString('D')
        CleanupPolicy = 'driverentry-fails-after-result-delete-service'
    }
}
finally {
    $serviceStopped = -not $started
    if ($started) {
        Start-Sleep -Milliseconds 750
        try {
            Invoke-VMateCpuidBrandSc @('stop', $serviceName) | Out-Null
            $serviceStopped = $true
        }
        catch { $cleanupFailure = $_.Exception.Message }
    }
    if ($created -and $serviceStopped) {
        try {
            Invoke-VMateCpuidBrandSc @('delete', $serviceName) | Out-Null
        }
        catch { $cleanupFailure = $_.Exception.Message }
    }
    if ($created -and $serviceStopped -and
        [String]::IsNullOrWhiteSpace($cleanupFailure)) {
        Start-Sleep -Milliseconds 250
        if (Test-Path -LiteralPath $serviceKey) {
            $cleanupFailure =
                '瞬态驱动服务键在删除后仍存在；拒绝强制删除。'
        }
    }
}

if (-not [String]::IsNullOrWhiteSpace($cleanupFailure)) {
    throw ('CPUID brand extension 清理失败；保留服务键：' +
        $cleanupFailure)
}
$applyResult
