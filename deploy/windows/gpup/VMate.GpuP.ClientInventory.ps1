#Requires -Version 5.1

<#
.SYNOPSIS
    为客户端恢复缺失旁车 metadata 提供只读、失败关闭的 P-11 检查证据。
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'VMate.GpuP.HardwareProfile.ps1')

function Get-VMateGpuPClientInspection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^VMate-P11-(?:[1-9][0-9]{0,2}|1000)$')]
        [string]$VMName,
        [Parameter(Mandatory = $true)][string]$VhdPath
    )

    Import-Module Hyper-V -ErrorAction Stop
    $matches = @(Get-VM -ErrorAction Stop | Where-Object {
            [string]::Equals([string]$_.Name, $VMName,
                [StringComparison]::OrdinalIgnoreCase)
        })
    if ($matches.Count -ne 1) {
        throw "P-11 接管无法唯一解析 Hyper-V VM：$VMName"
    }
    $vm = $matches[0]
    if ([int]$vm.Generation -ne 2) {
        throw 'P-11 接管只接受 Hyper-V Generation 2 VM。'
    }
    $wanted = [IO.Path]::GetFullPath($VhdPath)
    if ([IO.Path]::GetExtension($wanted) -ine '.vhdx') {
        throw "P-11 接管只接受 VHDX：$wanted"
    }
    $drives = @(Get-VMHardDiskDrive -VM $vm -ErrorAction Stop |
        Where-Object {
            -not [String]::IsNullOrWhiteSpace([string]$_.Path)
        })
    if ($drives.Count -ne 1 -or
        -not [IO.Path]::GetFullPath([string]$drives[0].Path).Equals(
            $wanted, [StringComparison]::OrdinalIgnoreCase)) {
        throw "P-11 接管要求唯一系统 VHDX 精确匹配：$wanted"
    }
    $identity = Get-VMateGpuPIdentity -VMId ([Guid]$vm.Id)
    if ($null -eq $identity) {
        throw 'P-11 接管要求现有 VMId 身份清单，拒绝为普通 Hyper-V VM 猜测身份。'
    }
    $binding = Get-VMateGpuPHardwareProfileBinding -VMId ([Guid]$vm.Id)
    if ($null -eq $binding) {
        throw 'P-11 接管要求现有原子硬件 profile 绑定。'
    }
    [void](Assert-VMateGpuPHardwareProfileBinding $binding)
    $processor = Get-VMProcessor -VM $vm -ErrorAction Stop
    $memory = Get-VMMemory -VM $vm -ErrorAction Stop
    [void](Assert-VMateGpuPHardwareProfileOverrides $binding @{
            ProcessorCount = [int]$processor.Count
            MemoryStartupBytes = [uint64]$memory.Startup
        })
    $adapters = @(Get-VMGpuPartitionAdapter -VM $vm -ErrorAction Stop)
    if ($adapters.Count -gt 1) {
        throw 'P-11 接管发现多个 GPU-P adapter，拒绝生成健康 metadata。'
    }
    $network = @(Get-VMNetworkAdapter -VM $vm -ErrorAction Stop)
    if ($network.Count -gt 1) {
        throw 'P-11 接管发现多个 Hyper-V 网络适配器，拒绝猜测交换机绑定。'
    }
    $vhd = Get-VHD -Path $wanted -ErrorAction Stop
    $sizeGiB = [decimal]$vhd.Size / [decimal]1GB
    if ($sizeGiB -ne [decimal]::Truncate($sizeGiB) -or
        $sizeGiB -lt 20 -or $sizeGiB -gt 65536) {
        throw "P-11 VHDX 逻辑容量不能用受支持的整数 GiB 表达：$($vhd.Size)"
    }
    $quotaProfile = [string]$binding.Gpu.quota_profile
    if ($quotaProfile -notin @('operator-selected',
            'full-all-shared-resources', 'win10-reference-100')) {
        throw "P-11 profile 包含未知 GPU-P quota_profile：$quotaProfile"
    }
    return [pscustomobject][ordered]@{
        Exists = $true
        ManagedCandidate = $true
        Name = [string]$vm.Name
        Notes = [string]$vm.Notes
        VMId = ([Guid]$vm.Id).ToString('D')
        State = [string]$vm.State
        Generation = [int]$vm.Generation
        VhdPath = $wanted
        VhdSizeGiB = [uint32]$sizeGiB
        ProcessorCount = [uint32]$processor.Count
        MemoryMiB = [uint32]([uint64]$memory.Startup / 1MB)
        AdapterCount = $adapters.Count
        Vendor = [string]$identity.Vendor
        HardwareProfileId = [string]$binding.ProfileId
        IdentityFidelity = [string]$binding.IdentityFidelity
        FullIdentitySupported = [bool]$binding.FullIdentitySupported
        QuotaProfile = $quotaProfile
        SwitchName = if ($network.Count -eq 1) {
            [string]$network[0].SwitchName
        } else { '' }
        AutomaticStartSafe = [string]$vm.AutomaticStartAction -ceq 'Nothing'
        IdentityManifestPresent = $true
        RuntimeModelSwitch = $false
    }
}
