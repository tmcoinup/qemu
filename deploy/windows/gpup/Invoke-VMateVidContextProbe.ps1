#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    在授权实验机上运行一次只读 VID worker-process 上下文探针。

.DESCRIPTION
    调用前固定校验 driver、vmwp.exe 与 vid.dll 的 SHA-256 和签名。探针服务只在
    DriverEntry 中读取一个明确的 PID/handle，执行 VidGetHvPartitionId 对应的只读
    查询，随后由本脚本停止并删除。脚本不修改 BCD、不启用 test signing，也不提供
    CPUID 注册入口。
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 2147483647)]
    [int]$TargetProcessId,

    [Parameter(Mandatory = $true)]
    [ValidateScript({ $_ -ne [UInt64]0 })]
    [UInt64]$PartitionHandle,

    [string]$DriverPath = '',

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$ExpectedDriverSha256,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$ExpectedVmwpSha256,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$ExpectedVidSha256
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([String]::IsNullOrWhiteSpace($DriverPath)) {
    $DriverPath = Join-Path $PSScriptRoot `
        'native\bin\VMateVidContextProbe.sys'
}

function Assert-VMateVidContextProbeFile {
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
        Path = $Path
        Sha256 = $actualHash
        Signer = [string]$signature.SignerCertificate.Subject
    }
}

function Invoke-VMateVidContextProbeSc {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $output = & "$env:SystemRoot\System32\sc.exe" @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "sc.exe $($Arguments[0]) 失败（$exitCode）：$output"
    }
    return @($output)
}

function Get-VMateVidContextProbeCodeIntegrityOptions {
    if ($null -eq ('VMateVidContextProbe.NativeMethods' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace VMateVidContextProbe {
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
        VMateVidContextProbe.NativeMethods+CodeIntegrityInformation
    $information.Length = 8
    [UInt32]$returnLength = 0
    $status = [VMateVidContextProbe.NativeMethods]::NtQuerySystemInformation(
        103, [ref]$information, 8, [ref]$returnLength)
    if ($status -ne 0) {
        throw ('读取 SystemCodeIntegrityInformation 失败：0x{0:X8}' -f `
            [UInt32]$status)
    }
    return [UInt32]$information.Options
}

$driverFullPath = [IO.Path]::GetFullPath($DriverPath)
$vmwpPath = Join-Path $env:SystemRoot 'System32\vmwp.exe'
$vidPath = Join-Path $env:SystemRoot 'System32\vid.dll'

$driverEvidence = Assert-VMateVidContextProbeFile `
    -Path $driverFullPath `
    -ExpectedSha256 $ExpectedDriverSha256 `
    -Description 'VMate 只读内核探针'
$vmwpEvidence = Assert-VMateVidContextProbeFile `
    -Path $vmwpPath `
    -ExpectedSha256 $ExpectedVmwpSha256 `
    -Description 'vmwp.exe' `
    -RequireMicrosoftSigner
$vidEvidence = Assert-VMateVidContextProbeFile `
    -Path $vidPath `
    -ExpectedSha256 $ExpectedVidSha256 `
    -Description 'vid.dll' `
    -RequireMicrosoftSigner
$codeIntegrityOptions = Get-VMateVidContextProbeCodeIntegrityOptions
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
if ($null -eq $target -or [string]$target.Name -ine 'vmwp.exe' -or
    [IO.Path]::GetFullPath([string]$target.ExecutablePath) -ine $vmwpPath) {
    throw "PID $TargetProcessId 不是 System32 中的 vmwp.exe；拒绝附着。"
}

$serviceName = 'VMateVidContextProbe_' +
    [Guid]::NewGuid().ToString('N')
$serviceKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$serviceName"
$parametersKey = Join-Path $serviceKey 'Parameters'
$created = $false
$started = $false
$probeResult = $null
$cleanupFailure = ''

try {
    Invoke-VMateVidContextProbeSc @(
        'create', $serviceName,
        'type=', 'kernel',
        'start=', 'demand',
        'error=', 'normal',
        'binPath=', $driverFullPath) | Out-Null
    $created = $true
    New-Item -Path $parametersKey -Force | Out-Null
    New-ItemProperty -Path $parametersKey `
        -Name TargetProcessId -PropertyType DWord `
        -Value $TargetProcessId -Force | Out-Null
    New-ItemProperty -Path $parametersKey `
        -Name PartitionHandle -PropertyType QWord `
        -Value $PartitionHandle -Force | Out-Null

    $startOutput = & "$env:SystemRoot\System32\sc.exe" `
        @('start', $serviceName) 2>&1
    $startExitCode = $LASTEXITCODE
    $started = $startExitCode -eq 0
    $result = Get-ItemProperty -LiteralPath $parametersKey
    foreach ($name in @(
            'Completed', 'ContractVersion', 'MutatingCalls',
            'ResidentAfterProbe', 'InputNtStatus', 'ImageMatched',
            'DuplicateNtStatus', 'SystemContextQueryNtStatus',
            'KernelHandleNtStatus', 'AttachedContextQueryNtStatus',
            'TargetThreadCreateNtStatus', 'TargetThreadWaitNtStatus',
            'TargetThreadRawHandleQueryNtStatus',
            'TargetBufferAllocationNtStatus',
            'TargetFastIoQueryNtStatus', 'TargetBufferFreeNtStatus',
            'TargetCurrentProcessMatched', 'TargetFastIoAvailable',
            'TargetFastIoHandled',
            'QueryNtStatus', 'PartitionId')) {
        if ($null -eq $result.PSObject.Properties[$name]) {
            throw ("内核探针没有返回 $name；sc start ($startExitCode)：" +
                ($startOutput -join ' '))
        }
    }
    if ([int]$result.Completed -ne 1 -or
        [int]$result.ContractVersion -ne 5 -or
        [int]$result.MutatingCalls -ne 0 -or
        [int]$result.ResidentAfterProbe -ne 0 -or
        $startExitCode -eq 0) {
        throw '内核探针 v5 非驻留契约或只读证明无效。'
    }

    $queryStatus = [UInt32]$result.QueryNtStatus
    $partitionId = [UInt64]$result.PartitionId
    $probeResult = [pscustomobject][ordered]@{
        SchemaVersion = 5
        Operation = 'read-only-vid-worker-context-probe'
        MutatingCalls = $false
        ResidentAfterProbe = $false
        DriverEntryNonResident = $true
        StartExitCode = $startExitCode
        TargetProcessId = $TargetProcessId
        PartitionHandleHex = ('0x{0:X}' -f $PartitionHandle)
        ImageMatched = [int]$result.ImageMatched -eq 1
        InputNtStatusHex = ('0x{0:X8}' -f [UInt32]$result.InputNtStatus)
        DuplicateNtStatusHex = ('0x{0:X8}' -f `
            [UInt32]$result.DuplicateNtStatus)
        SystemContextQueryNtStatusHex = ('0x{0:X8}' -f `
            [UInt32]$result.SystemContextQueryNtStatus)
        KernelHandleNtStatusHex = ('0x{0:X8}' -f `
            [UInt32]$result.KernelHandleNtStatus)
        AttachedContextQueryNtStatusHex = ('0x{0:X8}' -f `
            [UInt32]$result.AttachedContextQueryNtStatus)
        TargetThreadCreateNtStatusHex = ('0x{0:X8}' -f `
            [UInt32]$result.TargetThreadCreateNtStatus)
        TargetThreadWaitNtStatusHex = ('0x{0:X8}' -f `
            [UInt32]$result.TargetThreadWaitNtStatus)
        TargetThreadRawHandleQueryNtStatusHex = ('0x{0:X8}' -f `
            [UInt32]$result.TargetThreadRawHandleQueryNtStatus)
        TargetBufferAllocationNtStatusHex = ('0x{0:X8}' -f `
            [UInt32]$result.TargetBufferAllocationNtStatus)
        TargetFastIoQueryNtStatusHex = ('0x{0:X8}' -f `
            [UInt32]$result.TargetFastIoQueryNtStatus)
        TargetBufferFreeNtStatusHex = ('0x{0:X8}' -f `
            [UInt32]$result.TargetBufferFreeNtStatus)
        TargetCurrentProcessMatched =
            [int]$result.TargetCurrentProcessMatched -eq 1
        TargetFastIoAvailable = [int]$result.TargetFastIoAvailable -eq 1
        TargetFastIoHandled = [int]$result.TargetFastIoHandled -eq 1
        QueryNtStatusHex = ('0x{0:X8}' -f $queryStatus)
        PartitionId = $partitionId
        QuerySucceeded = $queryStatus -eq 0 -and $partitionId -ne 0
        CodeIntegrityOptionsHex = ('0x{0:X8}' -f `
            $codeIntegrityOptions)
        Driver = $driverEvidence
        Vmwp = $vmwpEvidence
        Vid = $vidEvidence
        CleanupPolicy = 'driverentry-fails-after-result-delete-service'
    }
}
finally {
    $serviceStopped = -not $started
    if ($started) {
        Start-Sleep -Milliseconds 750
        try {
            Invoke-VMateVidContextProbeSc @('stop', $serviceName) |
                Out-Null
            $serviceStopped = $true
        }
        catch {
            $cleanupFailure = $_.Exception.Message
        }
    }
    if ($created -and $serviceStopped) {
        try {
            Invoke-VMateVidContextProbeSc @('delete', $serviceName) |
                Out-Null
        }
        catch {
            $cleanupFailure = $_.Exception.Message
        }
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
    throw ('只读内核探针清理失败；保留服务键以便安全重试：' +
        $cleanupFailure)
}
$probeResult
