#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$identityModule = Join-Path $PSScriptRoot 'VMate.GpuP.Identity.ps1'
. $identityModule

function Assert-VMateHyperVAdministrator {
    [CmdletBinding()]
    param()

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'P-11 GPU-P 后端只能在 Windows Hyper-V 宿主运行。'
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        $administrator = [Security.Principal.WindowsBuiltInRole]::Administrator
        if (-not $principal.IsInRole($administrator)) {
            throw '请使用管理员 PowerShell 运行 P-11 GPU-P 命令。'
        }
    }
    finally {
        $identity.Dispose()
    }
    if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
        throw '未安装 Hyper-V PowerShell 模块。请先启用完整 Hyper-V 角色，而不是仅启用 WHPX。'
    }
}

function Get-VMateGpuPVirtualMachinePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$VMName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$VhdPath,

        [ValidateRange(1, 256)]
        [int]$ProcessorCount = 4,

        [ValidateRange(1073741824, 1099511627776)]
        [UInt64]$MemoryStartupBytes = 8GB,

        [ValidateSet('NVIDIA', 'AMD')]
        [string]$Vendor,

        [string]$PartitionIdentitySeed = '',

        [string]$SwitchName = '',

        [string]$IsoPath = '',

        [switch]$CreateVhd,

        [ValidateRange(21474836480, 70368744177664)]
        [UInt64]$VhdSizeBytes = 127GB
    )

    $resolvedVhd = [IO.Path]::GetFullPath($VhdPath)
    if ([String]::IsNullOrWhiteSpace($VMName)) {
        throw 'VMName 不能只包含空白。'
    }
    if (-not [String]::IsNullOrWhiteSpace($PartitionIdentitySeed) -and
        $PartitionIdentitySeed -notmatch '^[0-9a-fA-F]{64}$') {
        throw 'PartitionIdentitySeed 必须是 64 位十六进制字符串。'
    }
    if ([IO.Path]::GetExtension($resolvedVhd) -notin @('.vhd', '.vhdx')) {
        throw 'Hyper-V GPU-P 后端只接受 .vhd 或 .vhdx，不能直接使用 qcow2。'
    }
    if ($CreateVhd -and (Test-Path -LiteralPath $resolvedVhd)) {
        throw "-CreateVhd 不会覆盖已有磁盘：$resolvedVhd"
    }
    if (-not $CreateVhd -and -not (Test-Path -LiteralPath $resolvedVhd -PathType Leaf)) {
        throw "找不到现有 Windows 系统盘：$resolvedVhd"
    }
    if (-not $CreateVhd) {
        $vhd = Get-VHD -Path $resolvedVhd -ErrorAction Stop
        if ($vhd.Attached) {
            throw "现有 VHD 已挂载，拒绝复用：$resolvedVhd"
        }
        $owners = [System.Collections.Generic.List[string]]::new()
        foreach ($existingVm in @(Get-VM -ErrorAction Stop)) {
            foreach ($drive in @(Get-VMHardDiskDrive -VM $existingVm `
                        -ErrorAction Stop)) {
                if (-not [String]::IsNullOrWhiteSpace([string]$drive.Path) -and
                    [IO.Path]::GetFullPath([string]$drive.Path).Equals(
                        $resolvedVhd, [StringComparison]::OrdinalIgnoreCase)) {
                    [void]$owners.Add([string]$existingVm.Name)
                }
            }
        }
        if ($owners.Count -ne 0) {
            throw "现有 VHD 已属于 VM [$($owners -join ', ')]，拒绝重复挂载。"
        }
    }

    $resolvedIso = ''
    if (-not [String]::IsNullOrWhiteSpace($IsoPath)) {
        $resolvedIso = [IO.Path]::GetFullPath($IsoPath)
        if (-not (Test-Path -LiteralPath $resolvedIso -PathType Leaf)) {
            throw "找不到安装 ISO：$resolvedIso"
        }
    }
    if ($CreateVhd -and [String]::IsNullOrWhiteSpace($resolvedIso)) {
        throw '创建空 VHDX 时必须提供 -IsoPath；系统安装完成后再执行 GPU-P 驱动同步。'
    }

    if (-not [String]::IsNullOrWhiteSpace($SwitchName)) {
        $null = Get-VMSwitch -Name $SwitchName -ErrorAction Stop
    }

    return [pscustomobject][ordered]@{
        Action = 'CreateHyperVGeneration2VM'
        VMName = $VMName
        VhdPath = $resolvedVhd
        CreateVhd = [bool]$CreateVhd
        VhdSizeBytes = $VhdSizeBytes
        IsoPath = $resolvedIso
        ProcessorCount = $ProcessorCount
        MemoryStartupBytes = $MemoryStartupBytes
        SwitchName = $SwitchName
        Vendor = $Vendor
        PartitionIdentitySeed = $PartitionIdentitySeed
        AutomaticCheckpoints = $false
        SecureBootTemplate = 'MicrosoftWindows'
        PhysicalGpuSerialPolicy = 'vendor-managed-read-only'
    }
}

function New-VMateGpuPVirtualMachine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VMName,

        [Parameter(Mandatory = $true)]
        [string]$VhdPath,

        [ValidateRange(1, 256)]
        [int]$ProcessorCount = 4,

        [ValidateRange(1073741824, 1099511627776)]
        [UInt64]$MemoryStartupBytes = 8GB,

        [Parameter(Mandatory = $true)]
        [ValidateSet('NVIDIA', 'AMD')]
        [string]$Vendor,

        [string]$PartitionIdentitySeed = '',

        [string]$SwitchName = '',

        [string]$IsoPath = '',

        [switch]$CreateVhd,

        [ValidateRange(21474836480, 70368744177664)]
        [UInt64]$VhdSizeBytes = 127GB,

        [string]$StateRoot = '',

        [switch]$DryRun
    )

    Assert-VMateHyperVAdministrator
    Import-Module Hyper-V -ErrorAction Stop
    if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
        throw "Hyper-V VM 已存在：$VMName"
    }

    $planParameters = @{
        VMName = $VMName
        VhdPath = $VhdPath
        ProcessorCount = $ProcessorCount
        MemoryStartupBytes = $MemoryStartupBytes
        Vendor = $Vendor
        PartitionIdentitySeed = $PartitionIdentitySeed
        SwitchName = $SwitchName
        IsoPath = $IsoPath
        CreateVhd = $CreateVhd
        VhdSizeBytes = $VhdSizeBytes
    }
    $plan = Get-VMateGpuPVirtualMachinePlan @planParameters
    if ($DryRun) {
        return $plan
    }

    $createdVhd = $false
    $createdVm = $null
    $identityPath = $null
    try {
        if ($plan.CreateVhd) {
            $parent = [IO.Path]::GetDirectoryName($plan.VhdPath)
            [IO.Directory]::CreateDirectory($parent) | Out-Null
            New-VHD -Path $plan.VhdPath -Dynamic -SizeBytes $plan.VhdSizeBytes -ErrorAction Stop | Out-Null
            $createdVhd = $true
        }

        $newVmParameters = @{
            Name = $plan.VMName
            Generation = 2
            MemoryStartupBytes = $plan.MemoryStartupBytes
            VHDPath = $plan.VhdPath
            ErrorAction = 'Stop'
        }
        if (-not [String]::IsNullOrWhiteSpace($plan.SwitchName)) {
            $newVmParameters['SwitchName'] = $plan.SwitchName
        }
        $createdVm = New-VM @newVmParameters

        Set-VMProcessor -VM $createdVm -Count $plan.ProcessorCount -ErrorAction Stop
        Set-VMMemory -VM $createdVm -DynamicMemoryEnabled $false -ErrorAction Stop
        Set-VM -VM $createdVm -AutomaticCheckpointsEnabled $false -CheckpointType Disabled -ErrorAction Stop
        Set-VMFirmware -VM $createdVm -EnableSecureBoot On `
            -SecureBootTemplate MicrosoftWindows -ErrorAction Stop

        if (-not [String]::IsNullOrWhiteSpace($plan.IsoPath)) {
            $dvd = Add-VMDvdDrive -VM $createdVm -Path $plan.IsoPath -Passthru -ErrorAction Stop
            Set-VMFirmware -VM $createdVm -FirstBootDevice $dvd -ErrorAction Stop
        }

        $identityPath = Get-VMateGpuPIdentityPath -VMId $createdVm.Id `
            -StateRoot $StateRoot
        $identity = Initialize-VMateGpuPIdentity -VMId $createdVm.Id `
            -Vendor $plan.Vendor `
            -PartitionIdentitySeed $plan.PartitionIdentitySeed `
            -StateRoot $StateRoot
        return [pscustomobject][ordered]@{
            VM = $createdVm
            Plan = $plan
            Identity = $identity
            IdentityPath = $identityPath
        }
    }
    catch {
        $failure = $_.Exception.Message
        $rollbackErrors = [System.Collections.Generic.List[string]]::new()
        $vmUnregistered = $null -eq $createdVm
        if ($null -ne $createdVm) {
            try {
                Remove-VM -VM $createdVm -Force -Confirm:$false `
                    -ErrorAction Stop
                $remaining = Get-VM -Id $createdVm.Id -ErrorAction SilentlyContinue
                if ($null -ne $remaining) {
                    [void]$rollbackErrors.Add(
                        '回读发现本次 VM 仍在 Hyper-V 注册。')
                }
                else {
                    $vmUnregistered = $true
                }
            }
            catch {
                [void]$rollbackErrors.Add(
                    "注销本次 VM 失败：$($_.Exception.Message)")
            }
        }
        # VM 未确认注销时，VHD 与身份清单都是恢复/诊断材料，
        # 绝不继续删除。只有回读确认 VM 已消失才清理本事务产物。
        if ($vmUnregistered) {
            if (-not [String]::IsNullOrWhiteSpace([string]$identityPath) -and
                (Test-Path -LiteralPath $identityPath -PathType Leaf)) {
                try {
                    Remove-Item -LiteralPath $identityPath -Force `
                        -ErrorAction Stop
                }
                catch {
                    [void]$rollbackErrors.Add(
                        "删除本次身份清单失败：$($_.Exception.Message)")
                }
            }
            if ($createdVhd -and
                (Test-Path -LiteralPath $plan.VhdPath -PathType Leaf)) {
                try {
                    Remove-Item -LiteralPath $plan.VhdPath -Force `
                        -ErrorAction Stop
                }
                catch {
                    [void]$rollbackErrors.Add(
                        "删除本次 VHD 失败：$($_.Exception.Message)")
                }
            }
        }
        else {
            [void]$rollbackErrors.Add(
                '已保留身份清单与 VHD，避免破坏仍注册 VM 的恢复材料。')
        }
        $rollback = if ($rollbackErrors.Count -eq 0) {
            '已完整回滚本次创建。'
        }
        else { $rollbackErrors -join '；' }
        throw "创建 GPU-P VM 失败：$failure；$rollback"
    }
}
