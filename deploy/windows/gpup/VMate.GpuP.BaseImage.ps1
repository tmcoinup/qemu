#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Wait-VMateVhdFileReleased {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 30,
        [Guid]$ManagedVMId = [Guid]::Empty
    )
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "VHDX 释放门禁找不到文件：$fullPath"
    }
    $recoveredMount = $false
    $image = Get-DiskImage -ImagePath $fullPath -ErrorAction SilentlyContinue
    if ($null -ne $image -and [bool]$image.Attached) {
        if ($ManagedVMId -eq [Guid]::Empty) {
            throw "VHDX 仍挂载，拒绝在未确认所有权时卸载：$fullPath"
        }
        $managedVm = Get-VM -Id $ManagedVMId -ErrorAction Stop
        $bindings = @(Get-VMHardDiskDrive -VM $managedVm -ErrorAction Stop |
            Where-Object {
                -not [String]::IsNullOrWhiteSpace([string]$_.Path) -and
                [IO.Path]::GetFullPath([string]$_.Path).Equals($fullPath,
                    [StringComparison]::OrdinalIgnoreCase)
            })
        if ([string]$managedVm.State -cne 'Off' -or $bindings.Count -ne 1) {
            throw "VHDX 挂载不满足唯一 Off VM 绑定，拒绝卸载：$fullPath"
        }
        Dismount-VHD -Path $fullPath -ErrorAction Stop
        $recoveredMount = $true
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastError = ''
    do {
        $handle = $null
        try {
            $handle = [IO.File]::Open($fullPath, [IO.FileMode]::Open,
                [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            return [pscustomobject]@{
                Released = $true
                RecoveredManagedMount = $recoveredMount
                Path = $fullPath
            }
        }
        catch { $lastError = $_.Exception.Message }
        finally { if ($null -ne $handle) { $handle.Dispose() } }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "VHDX 在 $TimeoutSeconds 秒内未释放独占句柄：$fullPath；$lastError"
}

function Resolve-VMateGpuPBaseImagePlan {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$BaseImagePath,
        [Parameter(Mandatory = $true)][string]$DestinationVhdPath
    )

    if ([String]::IsNullOrWhiteSpace($BaseImagePath)) { return $null }
    $source = [IO.Path]::GetFullPath($BaseImagePath)
    $destination = [IO.Path]::GetFullPath($DestinationVhdPath)
    if ([IO.Path]::GetExtension($source) -ine '.vhdx') {
        throw 'P-11 基础镜像必须是独立 .vhdx；qcow2/VHD/WIM 不能伪装成 VHDX。'
    }
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "找不到基础 VHDX：$source"
    }
    $sourceItem = Get-Item -LiteralPath $source -Force -ErrorAction Stop
    if (($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "基础 VHDX 不能是重解析点：$source"
    }
    if ($source.Equals($destination,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw '基础 VHDX 与每 VM 目标 VHDX 不能是同一文件。'
    }
    $vhd = Get-VHD -Path $source -ErrorAction Stop
    if ($vhd.Attached) { throw "基础 VHDX 已挂载，拒绝克隆：$source" }
    if (-not [String]::IsNullOrWhiteSpace([string]$vhd.ParentPath)) {
        throw '基础 VHDX 必须是无父盘的独立镜像，不能克隆 differencing disk。'
    }
    foreach ($existingVm in @(Get-VM -ErrorAction Stop)) {
        foreach ($drive in @(Get-VMHardDiskDrive -VM $existingVm `
                    -ErrorAction Stop)) {
            if (-not [String]::IsNullOrWhiteSpace([string]$drive.Path) -and
                [IO.Path]::GetFullPath([string]$drive.Path).Equals(
                    $source, [StringComparison]::OrdinalIgnoreCase)) {
                throw "基础 VHDX 仍属于 VM [$($existingVm.Name)]，请先制作独立、已泛化的基础镜像。"
            }
        }
    }
    return [pscustomobject][ordered]@{
        SourcePath = $source
        DestinationPath = $destination
        SourceFileLength = [int64]$sourceItem.Length
        SourceVirtualSize = [uint64]$vhd.Size
        GuestGeneralizationPolicy = 'source-must-be-sysprep-generalized'
        CloneIdentityPolicy = 'new-vm-id-disk-id-firmware-serial-mac-and-partition-seed'
    }
}

function Copy-VMateGpuPBaseImage {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Plan)

    $parent = [IO.Path]::GetDirectoryName([string]$Plan.DestinationPath)
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $staging = Join-Path $parent (
        '.{0}.vmate-{1}-{2}.part.vhdx' -f
        [IO.Path]::GetFileNameWithoutExtension([string]$Plan.DestinationPath),
        $PID, [Guid]::NewGuid().ToString('N'))
    $committed = $false
    try {
        # File.Copy avoids provider wildcard/hidden-file semantics and gives this
        # staging path exactly one well-defined destination on PS 5.1/7.
        [IO.File]::Copy([string]$Plan.SourcePath, $staging, $false)
        $copiedLength = (Get-Item -LiteralPath $staging -Force `
                -ErrorAction Stop).Length
        if ([int64]$Plan.SourceFileLength -ne [int64]$copiedLength) {
            throw "基础 VHDX 克隆长度不一致：$($Plan.SourceFileLength) != $copiedLength"
        }
        Move-Item -LiteralPath $staging -Force `
            -Destination ([string]$Plan.DestinationPath) -ErrorAction Stop
        $committed = $true
        # 复制系统内容，但不复制虚拟磁盘身份；客体 OS SID 则要求源镜像先 Sysprep。
        Set-VHD -Path ([string]$Plan.DestinationPath) `
            -ResetDiskIdentifier -ErrorAction Stop | Out-Null
        $cloned = Get-VHD -Path ([string]$Plan.DestinationPath) `
            -ErrorAction Stop
        if ($cloned.Attached -or
            -not [String]::IsNullOrWhiteSpace([string]$cloned.ParentPath)) {
            throw '克隆后的 VHDX 不是未挂载的独立磁盘。'
        }
        return [pscustomobject][ordered]@{
            DestinationPath = [string]$Plan.DestinationPath
            FileLength = [int64]$copiedLength
            VirtualSize = [uint64]$cloned.Size
            DiskIdentifierReset = $true
            GuestGeneralizationPolicy = [string]$Plan.GuestGeneralizationPolicy
        }
    }
    catch {
        if ($committed -and
            (Test-Path -LiteralPath ([string]$Plan.DestinationPath) `
                -PathType Leaf)) {
            Remove-Item -LiteralPath ([string]$Plan.DestinationPath) `
                -Force -ErrorAction SilentlyContinue
        }
        throw
    }
    finally {
        if (Test-Path -LiteralPath $staging -PathType Leaf) {
            Remove-Item -LiteralPath $staging -Force `
                -ErrorAction SilentlyContinue
        }
    }
}
