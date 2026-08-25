#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    按已绑定 P-11 hardware profile 启动 GPU-P VM。

.DESCRIPTION
    host-native profile 使用标准 Hyper-V 启动。需要宿主扩展的 profile 必须提供
    一个部署时固定的 artifact manifest，并走 paused cold-boot CPUID 协调器；
    禁止把普通 Start-VM 当作自定义 CPU profile 的成功路径。
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$VMName,
    [string]$StateRoot = '',
    [string]$ArtifactManifestPath = '',
    [ValidateRange(1, 120)][int]$StartupTimeoutSeconds = 15,
    [ValidateRange(0.01, 30)][double]$MaxPausedUptimeSeconds = 0.25,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'VMate.GpuP.Identity.ps1')
. (Join-Path $PSScriptRoot 'VMate.HyperV.HostIdentityExtension.ps1')
. (Join-Path $PSScriptRoot 'VMate.HyperV.HostIdentityRuntime.ps1')
. (Join-Path $PSScriptRoot 'VMate.HyperV.CpuidColdStart.ps1')

function Get-VMateGpuPStartManifestProperty {
    param(
        [Parameter(Mandatory = $true)][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or
        [String]::IsNullOrWhiteSpace([string]$property.Value)) {
        throw "artifact manifest 缺少 $Name。"
    }
    return $property.Value
}

function Resolve-VMateGpuPStartArtifactPath {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$Value
    )
    if ([IO.Path]::IsPathRooted($Value)) { return [IO.Path]::GetFullPath($Value) }
    return [IO.Path]::GetFullPath((Join-Path `
        ([IO.Path]::GetDirectoryName($ManifestPath)) $Value))
}

Import-Module Hyper-V -ErrorAction Stop
$vm = Get-VM -Name $VMName -ErrorAction Stop
if ([string]$vm.State -cne 'Off') {
    throw "P-11 启动要求 VM 为 Off；当前 $($vm.State)。"
}
$identity = Get-VMateGpuPIdentity -VMId ([Guid]$vm.Id) -StateRoot $StateRoot
if ($null -eq $identity) { throw '找不到 VMate GPU-P identity.json。' }
$profileProperty = $identity.PSObject.Properties['HardwareProfile']
if ($null -eq $profileProperty -or $null -eq $profileProperty.Value) {
    throw 'identity.json 没有 hardware profile binding。'
}
$profile = $profileProperty.Value
$gpuInstancePathProperty = $identity.PSObject.Properties['GpuInstancePath']
if ($null -eq $gpuInstancePathProperty -or
    [String]::IsNullOrWhiteSpace([string]$gpuInstancePathProperty.Value)) {
    throw 'identity.json 缺少已绑定物理 GPU 的 GpuInstancePath。'
}
$gpuInstancePath = [string]$gpuInstancePathProperty.Value
$requiresExtension = [bool]$profile.RequiresHostExtension
if (-not $requiresExtension) {
    if ($DryRun) {
        [pscustomobject][ordered]@{
            SchemaVersion = 1
            Action = 'StandardHyperVColdBoot'
            VMName = $VMName
            VMId = ([Guid]$vm.Id).ToString('D')
            ProfileId = [string]$profile.ProfileId
            RuntimeModelSwitch = $false
        }
        return
    }
    Start-VM -VM $vm -ErrorAction Stop | Out-Null
    [pscustomobject][ordered]@{
        SchemaVersion = 1
        State = [string](Get-VM -Name $VMName).State
        VMName = $VMName
        VMId = ([Guid]$vm.Id).ToString('D')
        ProfileId = [string]$profile.ProfileId
        HostIdentityExtension = 'NotRequired'
        RuntimeModelSwitch = $false
    }
    return
}

$status = Get-VMateHyperVHostIdentityExtensionStatus `
    -VMId ([Guid]$vm.Id) -StateRoot $StateRoot
if (-not [bool]$status.Integrity -or $null -eq $status.Desired -or
    [string]$status.VMId -cne ([Guid]$vm.Id).ToString('D') -or
    [string]$status.ProfileId -cne [string]$profile.ProfileId) {
    throw '宿主身份扩展期望清单缺失、漂移或与 hardware profile 不一致。'
}
if ([String]::IsNullOrWhiteSpace($ArtifactManifestPath)) {
    throw '自定义 CPU profile 启动必须提供 -ArtifactManifestPath。'
}
$manifestPath = [IO.Path]::GetFullPath($ArtifactManifestPath)
try {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 `
        -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
}
catch { throw "无法读取 artifact manifest：$($_.Exception.Message)" }
if ([int]$manifest.SchemaVersion -ne 1 -or
    [string]$manifest.ContractId -cne
        'vmate-p11-cpuid-cold-start-artifacts-v1') {
    throw 'artifact manifest schema/contract 不受支持。'
}
$partitionProbe = Get-VMateGpuPStartManifestProperty `
    $manifest 'PartitionProbe'
$vidContext = Get-VMateGpuPStartManifestProperty $manifest 'VidContextDriver'
$cpuidDriver = Get-VMateGpuPStartManifestProperty $manifest 'CpuidBrandDriver'
$inbox = Get-VMateGpuPStartManifestProperty $manifest 'Inbox'

$parameters = @{
    VM = $vm
    GpuInstancePath = $gpuInstancePath
    BrandString = [string]$status.Desired.Cpu.BrandString
    PartitionProbePath = Resolve-VMateGpuPStartArtifactPath $manifestPath `
        ([string](Get-VMateGpuPStartManifestProperty $partitionProbe 'Path'))
    ExpectedPartitionProbeSha256 = [string](
        Get-VMateGpuPStartManifestProperty $partitionProbe 'Sha256')
    VidContextRunnerPath = Join-Path $PSScriptRoot `
        'Invoke-VMateVidContextProbe.ps1'
    VidContextDriverPath = Resolve-VMateGpuPStartArtifactPath $manifestPath `
        ([string](Get-VMateGpuPStartManifestProperty $vidContext 'Path'))
    ExpectedVidContextDriverSha256 = [string](
        Get-VMateGpuPStartManifestProperty $vidContext 'Sha256')
    CpuidRunnerPath = Join-Path $PSScriptRoot `
        'Invoke-VMateCpuidBrandExtension.ps1'
    CpuidDriverPath = Resolve-VMateGpuPStartArtifactPath $manifestPath `
        ([string](Get-VMateGpuPStartManifestProperty $cpuidDriver 'Path'))
    ExpectedCpuidDriverSha256 = [string](
        Get-VMateGpuPStartManifestProperty $cpuidDriver 'Sha256')
    ExpectedVmwpSha256 = [string](
        Get-VMateGpuPStartManifestProperty $inbox 'VmwpSha256')
    ExpectedVidSha256 = [string](
        Get-VMateGpuPStartManifestProperty $inbox 'VidDllSha256')
    ExpectedVidSysSha256 = [string](
        Get-VMateGpuPStartManifestProperty $inbox 'VidSysSha256')
    StartupTimeoutSeconds = $StartupTimeoutSeconds
    MaxPausedUptimeSeconds = $MaxPausedUptimeSeconds
    DryRun = $DryRun
}
$result = Start-VMateHyperVCpuidBrandColdBoot @parameters
$identity = Get-VMateGpuPIdentity -VMId ([Guid]$vm.Id) -StateRoot $StateRoot
$record = $identity.HostIdentityExtension
$hypervisorPath = Resolve-VMateGpuPStartArtifactPath $manifestPath `
    ([string](Get-VMateGpuPStartManifestProperty $inbox 'HypervisorPath'))
$attestation = $null
$attestationStatus = $null
if (-not $DryRun) {
    try {
        $attestation = New-VMateHyperVHostIdentityColdBootAttestation `
            -VM (Get-VM -Name $VMName -ErrorAction Stop) `
            -DesiredRecord $record -ColdBoot $result `
            -ExtensionBinaryPath $parameters.CpuidDriverPath `
            -ExpectedExtensionSha256 $parameters.ExpectedCpuidDriverSha256 `
            -HypervisorPath $hypervisorPath `
            -ExpectedHypervisorSha256 ([string](
                Get-VMateGpuPStartManifestProperty $inbox 'HypervisorSha256'))
        $attestationStatus =
            Publish-VMateHyperVHostIdentityColdBootAttestation `
                -VMId ([Guid]$vm.Id) -Attestation $attestation `
                -StateRoot $StateRoot
    }
    catch {
        $attestationFailure = $_.Exception.Message
        try {
            $active = Get-VM -Name $VMName -ErrorAction Stop
            if ([string]$active.State -cne 'Off') {
                Stop-VM -VM $active -TurnOff -Force -Confirm:$false `
                    -ErrorAction Stop
            }
        }
        catch {
            throw ("冷启动证明发布失败：$attestationFailure；关闭 VM 也失败：" +
                $_.Exception.Message)
        }
        throw "冷启动证明发布失败：$attestationFailure；本次 VM 已关闭。"
    }
}
[pscustomobject][ordered]@{
    SchemaVersion = 1
    VMName = $VMName
    VMId = ([Guid]$vm.Id).ToString('D')
    ProfileId = [string]$profile.ProfileId
    ManifestSha256 = [string]$status.ManifestSha256
    HostIdentityExtension = if ($DryRun) { 'DryRun' }
        else { 'AppliedAtPausedColdBoot' }
    RuntimeModelSwitch = $false
    ColdBoot = $result
    Attestation = $attestation
    AttestationStatus = $attestationStatus
}
