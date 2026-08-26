#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    安全启动已绑定 P-11 hardware profile 的 GPU-P VM。

.DESCRIPTION
    GPU-P adapter 从 Off 到 Running 始终保持绑定。P-11 不再执行已经在 Win10
    19045 实测触发 vmwp access violation / dxgkrnl BugCheck 0x3B 的
    detach -> start -> pause -> attach 序列。

    host-native profile 直接走标准 Hyper-V 冷启动。自定义 profile 会先验证 guest
    SMBIOS 启动扩展，然后安全冷启动；当前未实现的 direct CPUID 字段在返回对象中
    明确列为 UnappliedFields。传入 -RequireFullHardwareIdentity 时会在启动前失败关闭。

    旧 -ArtifactManifestPath 参数只用于识别并拒绝历史 paused-CPUID 部署清单，绝不
    加载其中的驱动，也不要求宿主 test signing。
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$VMName,
    [string]$StateRoot = '',
    [string]$ArtifactManifestPath = '',
    [switch]$RequireFullHardwareIdentity,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'VMate.GpuP.Identity.ps1')
. (Join-Path $PSScriptRoot 'VMate.HyperV.IdentityBoot.ps1')
. (Join-Path $PSScriptRoot 'VMate.P11.HostEnvironment.ps1')

function New-VMateGpuPSafeStartPlan {
    param(
        [Parameter(Mandatory = $true)][object]$VM,
        [Parameter(Mandatory = $true)][object]$Profile,
        [AllowNull()][object]$IdentityBoot,
        [Parameter(Mandatory = $true)][int]$GpuPAdapterCount
    )

    $requiresExtension = [bool]$Profile.RequiresHostExtension
    return [pscustomobject][ordered]@{
        SchemaVersion = 2
        ContractId = 'vmate-p11-safe-gpup-cold-boot-v2'
        Action = 'StandardHyperVColdBootWithGpuPAlreadyAttached'
        VMName = [string]$VM.Name
        VMId = ([Guid]$VM.Id).ToString('D')
        ProfileId = [string]$Profile.ProfileId
        GpuPAdapterCount = $GpuPAdapterCount
        GpuPAdapterLifecycle = 'attached-before-start-through-shutdown'
        IdentityBoot = $IdentityBoot
        HardwareIdentityFidelity = if ($requiresExtension) {
            'SmbiosAppliedDirectCpuidPending'
        } else { 'HyperVNative' }
        FullIdentitySupported = -not $requiresExtension
        AppliedFields = if ($requiresExtension) {
            @('smbios-platform', 'firmware-serials', 'static-mac',
                'compute-topology', 'gpu-p-quotas')
        } else {
            @('hyperv-native-profile', 'firmware-serials', 'static-mac',
                'compute-topology', 'gpu-p-quotas')
        }
        UnappliedFields = if ($requiresExtension) {
            @('direct-cpuid-brand-family-model-stepping')
        } else { @() }
        HostTestSigningRequired = $false
        RuntimeModelSwitch = $false
        PausedCpuidCoordinator = 'DisabledAfterWin10GpuPCrashReproduction'
    }
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
$adapters = @(Get-VMGpuPartitionAdapter -VM $vm -ErrorAction Stop)
if ($adapters.Count -ne 1) {
    throw "P-11 安全启动要求 VM 在 Off 状态已绑定恰好一个 GPU-P adapter；实际 $($adapters.Count)。"
}

# 标准 GPU-P 与 guest SMBIOS EFI 都不依赖宿主测试模式。每次启动前重新读取真实
# Hyper-V/BCD/ESP 状态，避免其它工具在管理器打开后改写环境。
[void](Assert-VMateP11HostEnvironment -RequireTestSigning $false)

$requiresExtension = [bool]$profile.RequiresHostExtension
$identityBoot = $null
if ($requiresExtension) {
    $identityBoot = Get-VMateHyperVIdentityBootStatus -VM $vm
    if (-not [bool]$identityBoot.Integrity -or
        [string]$identityBoot.State -cne 'Installed' -or
        [string]$identityBoot.ProfileId -cne [string]$profile.ProfileId) {
        throw 'guest SMBIOS 启动扩展缺失、漂移或与 hardware profile 不一致。'
    }
}

$plan = New-VMateGpuPSafeStartPlan -VM $vm -Profile $profile `
    -IdentityBoot $identityBoot -GpuPAdapterCount $adapters.Count
if (-not [String]::IsNullOrWhiteSpace($ArtifactManifestPath)) {
    throw ('paused-CPUID artifact manifest 已停用；它与 Win10 GPU-P 组合存在' +
        '宿主崩溃风险。请移除 -ArtifactManifestPath。')
}
if ($RequireFullHardwareIdentity -and -not $plan.FullIdentitySupported) {
    throw ('当前安全后端尚未实现启动期 direct CPUID；已在 Start-VM 前阻断，' +
        'GPU-P adapter 和宿主状态均未修改。')
}
if ($DryRun) { return $plan }

Start-VM -VM $vm -ErrorAction Stop | Out-Null
$live = Get-VM -Name $VMName -ErrorAction Stop
$liveAdapters = @(Get-VMGpuPartitionAdapter -VM $live -ErrorAction Stop)
if ([string]$live.State -cne 'Running' -or $liveAdapters.Count -ne 1) {
    if ([string]$live.State -cne 'Off') {
        Stop-VM -VM $live -TurnOff -Force -Confirm:$false `
            -ErrorAction SilentlyContinue
    }
    throw 'P-11 冷启动后状态或 GPU-P adapter 数量异常；本次 VM 已失败关闭。'
}

$plan | Add-Member -NotePropertyName State `
    -NotePropertyValue ([string]$live.State)
$plan | Add-Member -NotePropertyName StartedAtUtc `
    -NotePropertyValue ([DateTime]::UtcNow.ToString('o'))
return $plan
