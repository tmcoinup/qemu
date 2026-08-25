#Requires -Version 5.1

<#
.SYNOPSIS
    将 Windows Hyper-V 宿主的官方 WDDM 驱动事务化同步到离线 Windows guest。

.DESCRIPTION
    入口只接受发现模块按最终 PnP InstanceId 解析出的签名厂商包；发布过程不
    安装或修改驱动，也不增删 GPU partition adapter。
#>

. (Join-Path $PSScriptRoot 'VMate.GpuP.DriverDiscovery.ps1')
. (Join-Path $PSScriptRoot 'VMate.GpuP.WindowsImage.ps1')
. (Join-Path $PSScriptRoot 'VMate.GpuP.GuestMonitor.ps1')

function New-VMateGpuPManifest {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Before', 'After')][string]$Phase,
        [Parameter(Mandatory = $true)][string]$TransactionId,
        [Parameter(Mandatory = $true)][string]$Fingerprint,
        [Parameter(Mandatory = $true)][object]$Selection,
        [Parameter(Mandatory = $true)][object[]]$Files
    )

    return [pscustomobject][ordered]@{
        SchemaVersion = 1
        Phase = $Phase
        TransactionId = $TransactionId
        PackageFingerprint = $Fingerprint
        GeneratedUtc = [DateTime]::UtcNow.ToString('o')
        HostDevice = [pscustomobject][ordered]@{
            Vendor = [string]$Selection.Vendor.Vendor
            VendorId = [string]$Selection.Vendor.VendorId
            InstanceId = [string]$Selection.InstanceId
            Name = [string]$Selection.Pnp.Name
            PartitionableName = [string]$Selection.PartitionableName
        }
        Driver = [pscustomobject][ordered]@{
            Provider = [string]$Selection.SignedDriver.DriverProviderName
            Version = [string]$Selection.SignedDriver.DriverVersion
            Inf = [string]$Selection.SignedDriver.InfName
            Signer = [string]$Selection.SignedDriver.Signer
            Services = @($Selection.Services | ForEach-Object { [string]$_.Name })
        }
        Files = @($Files)
    }
}

function Write-VMateGpuPJson {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $json = $Value | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($Path, $json + [Environment]::NewLine,
        (New-Object System.Text.UTF8Encoding($false)))
}

function Ensure-VMateGpuPDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    $current = $Root
    Assert-VMateGpuPNoReparsePoint -Path $current -BoundaryRoot $Root
    foreach ($segment in @($RelativePath -split '\\')) {
        if (-not $segment -or $segment -in @('.', '..')) {
            throw "目录相对路径无效：$RelativePath"
        }
        $current = Join-Path $current $segment
        if (-not (Test-Path -LiteralPath $current)) {
            New-Item -ItemType Directory -Path $current -ErrorAction Stop | Out-Null
        }
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (-not $item.PSIsContainer) {
            throw "目标目录被普通文件占用：$current"
        }
        Assert-VMateGpuPNoReparsePoint -Path $current -BoundaryRoot $Root
    }
    return [System.IO.Path]::GetFullPath($current)
}

function Get-VMateGpuPWindowsVolume {
    param([Parameter(Mandatory = $true)][uint32]$DiskNumber)

    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($partition in @(Get-Partition -DiskNumber $DiskNumber -ErrorAction Stop)) {
        foreach ($volume in @($partition | Get-Volume -ErrorAction SilentlyContinue)) {
            if ([string]$volume.FileSystemType -ine 'NTFS') { continue }
            $volumeRoot = [string]$volume.UniqueId
            if ($volumeRoot -notmatch '^\\\\\?\\Volume\{[0-9A-Fa-f-]+\}\\$') { continue }
            $windows = Join-Path $volumeRoot 'Windows'
            if ((Test-Path -LiteralPath (Join-Path $windows 'System32\Config\SYSTEM')) -and
                (Test-Path -LiteralPath (Join-Path $windows 'System32\DriverStore'))) {
                Assert-VMateGpuPNoReparsePoint -Path (Join-Path $windows 'System32') `
                    -BoundaryRoot $volumeRoot
                $roots.Add([System.IO.Path]::GetFullPath($windows))
            }
        }
    }
    $unique = @($roots | Sort-Object -Unique)
    if ($unique.Count -ne 1) {
        throw "VHD 必须包含唯一且无 reparse 的 Windows 卷，实际：$($unique.Count)"
    }
    return $unique[0]
}

function Resolve-VMateGpuPVhdPath {
    param(
        [Parameter(Mandatory = $true)][string]$VMName,
        [string]$VhdPath = ''
    )

    $escapedName = [System.Management.Automation.WildcardPattern]::Escape($VMName)
    $vms = @(Get-VM -Name $escapedName -ErrorAction Stop | Where-Object {
            [string]::Equals([string]$_.Name, $VMName,
                [StringComparison]::OrdinalIgnoreCase)
        })
    if ($vms.Count -ne 1) {
        throw "Hyper-V VM 名称无法唯一解析：$VMName"
    }
    $vm = $vms[0]
    if ([string]$vm.State -cne 'Off') {
        throw "GPU-P 驱动同步要求 VM 处于 Off：$VMName ($($vm.State))"
    }
    $attached = @(Get-VMHardDiskDrive -VMName $VMName -ErrorAction Stop |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Path) })
    if ($VhdPath) {
        $wanted = [System.IO.Path]::GetFullPath($VhdPath)
        $attached = @($attached | Where-Object {
                [System.IO.Path]::GetFullPath([string]$_.Path).Equals($wanted,
                    [System.StringComparison]::OrdinalIgnoreCase) })
    }
    if ($attached.Count -ne 1) {
        throw "必须指定该 VM 唯一的 Windows VHD，匹配数：$($attached.Count)"
    }
    $path = [System.IO.Path]::GetFullPath([string]$attached[0].Path)
    if ([System.IO.Path]::GetExtension($path) -notin @('.vhd', '.vhdx') -or
        -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "VM 磁盘不是有效 VHD/VHDX：$path"
    }
    $volumeRoot = [System.IO.Path]::GetPathRoot($path)
    Assert-VMateGpuPNoReparsePoint -Path $path -BoundaryRoot $volumeRoot
    if ((Get-VHD -Path $path -ErrorAction Stop).Attached) {
        throw "VHD 已被其他操作挂载，拒绝接管：$path"
    }
    return $path
}

function Install-VMateGpuPFileAtomically {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$ExpectedSHA256,
        [Parameter(Mandatory = $true)][string]$TransactionId
    )

    $temporary = $Destination + '.vmate-' + $TransactionId + '.tmp'
    $replaceBackup = $Destination + '.vmate-' + $TransactionId + `
        '.replace-backup'
    try {
        if ((Test-Path -LiteralPath $temporary) -or
            (Test-Path -LiteralPath $replaceBackup)) {
            throw "原子发布临时路径已被占用：$Destination"
        }
        Copy-Item -LiteralPath $Source -Destination $temporary -ErrorAction Stop
        if ((Get-FileHash -LiteralPath $temporary `
                    -Algorithm SHA256).Hash -ine $ExpectedSHA256) {
            throw "待发布临时文件哈希不一致：$Destination"
        }
        if (Test-Path -LiteralPath $Destination) {
            # Windows PowerShell 5.1/.NET Framework 不接受空 backupFileName。
            # 使用同目录事务唯一备份保持 Replace 原子性；跨文件回滚材料由
            # 调用方的 previous 目录独立持有。
            [System.IO.File]::Replace(
                $temporary, $Destination, $replaceBackup)
            Remove-Item -LiteralPath $replaceBackup -Force -ErrorAction Stop
        } else {
            [System.IO.File]::Move($temporary, $Destination)
        }
    } finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction Stop
        }
        if (Test-Path -LiteralPath $replaceBackup) {
            Remove-Item -LiteralPath $replaceBackup -Force -ErrorAction Stop
        }
    }
}

function Find-VMateGpuPCurrentPackage {
    param(
        [Parameter(Mandatory = $true)][string]$GuestWindowsRoot,
        [Parameter(Mandatory = $true)][string]$PackagesRoot,
        [Parameter(Mandatory = $true)][object]$Selection,
        [Parameter(Mandatory = $true)][object[]]$Plan,
        [Parameter(Mandatory = $true)][string]$Fingerprint
    )

    $prefix = $Selection.Vendor.Vendor.ToLowerInvariant() + '-' +
        $Fingerprint.Substring(0, 16).ToLowerInvariant() + '-'
    foreach ($package in @(Get-ChildItem -LiteralPath $PackagesRoot `
            -Directory -Force -ErrorAction Stop | Where-Object {
                $_.Name.StartsWith($prefix,
                    [System.StringComparison]::OrdinalIgnoreCase) })) {
        Assert-VMateGpuPNoReparsePoint $package.FullName $PackagesRoot
        $manifestPath = Join-Path $package.FullName 'manifest.after.json'
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { continue }
        Assert-VMateGpuPNoReparsePoint $manifestPath $PackagesRoot
        try {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw `
                -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        } catch {
            continue
        }
        if ([string]$manifest.PackageFingerprint -cne $Fingerprint -or
            [string]$manifest.Phase -cne 'After') { continue }
        $current = $true
        foreach ($entry in $Plan) {
            $destination = Join-VMateGpuPGuestPath $GuestWindowsRoot `
                $entry.GuestWindowsRelativePath
            if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
                $current = $false; break
            }
            Assert-VMateGpuPNoReparsePoint $destination $GuestWindowsRoot
            if ((Get-FileHash -LiteralPath $destination `
                        -Algorithm SHA256).Hash -ine $entry.SHA256) {
                $current = $false; break
            }
        }
        if ($current) { return $package.FullName }
    }
    return ''
}

function Invoke-VMateGpuPDriverPublish {
    param(
        [Parameter(Mandatory = $true)][string]$GuestWindowsRoot,
        [Parameter(Mandatory = $true)][object]$Selection,
        [Parameter(Mandatory = $true)][object[]]$Plan
    )

    $fingerprint = Get-VMateGpuPFingerprint $Selection $Plan
    $auditRelative = 'System32\HostDriverStore\VMate'
    $auditRoot = Ensure-VMateGpuPDirectory $GuestWindowsRoot $auditRelative
    $stagingParent = Ensure-VMateGpuPDirectory $auditRoot '.staging'
    $packages = Ensure-VMateGpuPDirectory $auditRoot 'Packages'
    $currentPackage = Find-VMateGpuPCurrentPackage $GuestWindowsRoot $packages `
        $Selection $Plan $fingerprint
    if ($currentPackage) {
        return [pscustomobject]@{ Status = 'UpToDate'; Fingerprint = $fingerprint
            Package = $currentPackage; Files = $Plan }
    }
    $transaction = [Guid]::NewGuid().ToString('N')
    $stage = Join-Path $stagingParent $transaction
    $published = New-Object System.Collections.Generic.List[object]
    $rollbackFailed = $false
    try {
        New-Item -ItemType Directory -Path $stage -ErrorAction Stop | Out-Null
        $payload = Ensure-VMateGpuPDirectory $stage 'payload'
        $previous = Ensure-VMateGpuPDirectory $stage 'previous'
        $beforeFiles = New-Object System.Collections.Generic.List[object]
        foreach ($entry in $Plan) {
            $destination = Join-VMateGpuPGuestPath $GuestWindowsRoot `
                $entry.GuestWindowsRelativePath
            $existingHash = $null
            if (Test-Path -LiteralPath $destination) {
                Assert-VMateGpuPNoReparsePoint $destination $GuestWindowsRoot
                $existingHash = (Get-FileHash -LiteralPath $destination `
                    -Algorithm SHA256).Hash.ToUpperInvariant()
            }
            $beforeFiles.Add([pscustomobject][ordered]@{
                    SystemRootRelativePath = $entry.SystemRootRelativePath
                    GuestWindowsRelativePath = $entry.GuestWindowsRelativePath
                    SHA256 = $entry.SHA256; DestinationSHA256 = $existingHash
                })
        }
        Write-VMateGpuPJson (New-VMateGpuPManifest 'Before' $transaction `
                $fingerprint $Selection $beforeFiles) (Join-Path $stage 'manifest.before.json')
        foreach ($entry in $Plan) {
            $stagedFile = Join-VMateGpuPGuestPath $payload $entry.GuestWindowsRelativePath
            [void](Ensure-VMateGpuPDirectory $payload `
                    ([System.IO.Path]::GetDirectoryName($entry.GuestWindowsRelativePath).Replace('/', '\')))
            Copy-Item -LiteralPath $entry.SourcePath -Destination $stagedFile -ErrorAction Stop
            if ((Get-FileHash -LiteralPath $stagedFile `
                        -Algorithm SHA256).Hash -ine $entry.SHA256) {
                throw "暂存文件哈希与复制计划不一致：$($entry.GuestWindowsRelativePath)"
            }
        }
        foreach ($entry in $Plan) {
            $destination = Join-VMateGpuPGuestPath $GuestWindowsRoot `
                $entry.GuestWindowsRelativePath
            [void](Ensure-VMateGpuPDirectory $GuestWindowsRoot `
                    ([System.IO.Path]::GetDirectoryName($entry.GuestWindowsRelativePath).Replace('/', '\')))
            $hadExisting = Test-Path -LiteralPath $destination
            if ($hadExisting -and (Get-FileHash -LiteralPath $destination `
                        -Algorithm SHA256).Hash -ieq $entry.SHA256) {
                continue
            }
            $backup = $null
            $oldHash = $null
            if ($hadExisting) {
                Assert-VMateGpuPNoReparsePoint $destination $GuestWindowsRoot
                $oldHash = (Get-FileHash -LiteralPath $destination `
                    -Algorithm SHA256).Hash.ToUpperInvariant()
                $backup = Join-VMateGpuPGuestPath $previous $entry.GuestWindowsRelativePath
                [void](Ensure-VMateGpuPDirectory $previous `
                        ([System.IO.Path]::GetDirectoryName($entry.GuestWindowsRelativePath).Replace('/', '\')))
                Copy-Item -LiteralPath $destination -Destination $backup -ErrorAction Stop
                if ((Get-FileHash -LiteralPath $backup `
                            -Algorithm SHA256).Hash -ine $oldHash) {
                    throw "旧版本备份哈希不一致：$destination"
                }
            }
            $source = Join-VMateGpuPGuestPath $payload $entry.GuestWindowsRelativePath
            Install-VMateGpuPFileAtomically $source $destination `
                $entry.SHA256 $transaction
            $published.Add([pscustomobject]@{
                    Destination = $destination; Backup = $backup
                    HadExisting = $hadExisting; OldSHA256 = $oldHash
                    NewSHA256 = $entry.SHA256
                })
        }
        $afterFiles = @($Plan | ForEach-Object {
                $destination = Join-VMateGpuPGuestPath $GuestWindowsRoot `
                    $_.GuestWindowsRelativePath
                $actual = (Get-FileHash -LiteralPath $destination `
                    -Algorithm SHA256).Hash.ToUpperInvariant()
                if ($actual -ine $_.SHA256) { throw "发布后哈希不一致：$destination" }
                [pscustomobject][ordered]@{
                    SystemRootRelativePath = $_.SystemRootRelativePath
                    GuestWindowsRelativePath = $_.GuestWindowsRelativePath
                    SHA256 = $_.SHA256; DestinationSHA256 = $actual
                }
            })
        Write-VMateGpuPJson (New-VMateGpuPManifest 'After' $transaction `
                $fingerprint $Selection $afterFiles) (Join-Path $stage 'manifest.after.json')
        $packageName = $Selection.Vendor.Vendor.ToLowerInvariant() + '-' +
            $fingerprint.Substring(0, 16).ToLowerInvariant() + '-' + $transaction
        $packagePath = Join-Path $packages $packageName
        if ([IO.Directory]::Exists($packagePath)) {
            throw "驱动发布包目标已存在：$packagePath"
        }
        # PowerShell 5.1 Move-Item 会拒绝离线 VHD 的 \\?\Volume{GUID}
        # 目录；同卷 Directory.Move 保持原子重命名并已在 Win10 验证。
        [IO.Directory]::Move($stage, $packagePath)
        return [pscustomobject]@{ Status = 'Published'; Fingerprint = $fingerprint
            Package = $packagePath; Files = $afterFiles }
    } catch {
        $publishError = $_
        for ($index = $published.Count - 1; $index -ge 0; $index--) {
            $change = $published[$index]
            try {
                if (-not (Test-Path -LiteralPath $change.Destination -PathType Leaf) -or
                    (Get-FileHash -LiteralPath $change.Destination `
                        -Algorithm SHA256).Hash -ine $change.NewSHA256) {
                    throw "发布目标在回滚前发生并发变化：$($change.Destination)"
                }
                if ($change.HadExisting) {
                    Install-VMateGpuPFileAtomically $change.Backup `
                        $change.Destination $change.OldSHA256 $transaction
                    if ((Get-FileHash -LiteralPath $change.Destination `
                                -Algorithm SHA256).Hash -ine $change.OldSHA256) {
                        throw "旧版本回滚哈希不一致：$($change.Destination)"
                    }
                } elseif (Test-Path -LiteralPath $change.Destination) {
                    Remove-Item -LiteralPath $change.Destination -Force -ErrorAction Stop
                }
            } catch { $rollbackFailed = $true }
        }
        if (-not $rollbackFailed -and (Test-Path -LiteralPath $stage)) {
            try {
                Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction Stop
            } catch { $rollbackFailed = $true }
        }
        if ($rollbackFailed) {
            throw "驱动发布失败且回滚未完成；恢复材料保留于 $stage。原错误：$($publishError.Exception.Message)"
        }
        throw $publishError
    }
}

function Sync-VMateGpuPDriverStore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$VMName,
        [string]$VhdPath = '',
        [string]$GpuInstanceId = '',
        [switch]$DryRun
    )

    if ($env:OS -cne 'Windows_NT') {
        throw 'GPU-P DriverStore 同步只接受 Windows Hyper-V 宿主；Linux 驱动不能用于 Windows guest。'
    }
    foreach ($command in @('Get-VM', 'Get-VMHardDiskDrive', 'Get-VHD',
            'Mount-VHD', 'Dismount-VHD', 'Get-Disk', 'Get-Partition',
            'Get-Volume')) {
        if (-not (Get-Command -Name $command -ErrorAction SilentlyContinue)) {
            throw "缺少 Hyper-V 驱动同步 cmdlet：$command"
        }
    }
    $resolvedVhd = Resolve-VMateGpuPVhdPath -VMName $VMName -VhdPath $VhdPath
    $systemRoot = (Get-Item -LiteralPath $env:SystemRoot -Force -ErrorAction Stop).FullName
    $selection = Get-VMateGpuPDriverSelection -GpuInstanceId $GpuInstanceId
    $plan = @(Get-VMateGpuPDriverSourcePaths $selection $systemRoot)
    $mountedByThisCall = $false
    $result = $null
    $operationError = $null
    $dismountError = $null
    try {
        $image = Mount-VHD -Path $resolvedVhd -NoDriveLetter -ReadOnly:$DryRun `
            -PassThru -ErrorAction Stop
        $mountedByThisCall = $true
        $disks = @($image | Get-Disk -ErrorAction Stop)
        if ($disks.Count -ne 1) {
            throw "VHD 必须映射到唯一磁盘，实际：$($disks.Count)"
        }
        $guestWindows = Get-VMateGpuPWindowsVolume -DiskNumber $disks[0].Number
        # 先验证离线系统卷为完整 x64 Windows，再执行任何目录创建或文件写入。
        $guestImage = Assert-VMateGpuPGuestWindowsImage `
            -GuestWindowsRoot $guestWindows
        if ($DryRun) {
            $result = [pscustomobject][ordered]@{
                Status = 'DryRun'; VMName = $VMName; VhdPath = $resolvedVhd
                GuestWindowsRoot = $guestWindows
                Vendor = $selection.Vendor.Vendor
                VendorId = $selection.Vendor.VendorId
                InstanceId = $selection.InstanceId
                DriverVersion = [string]$selection.SignedDriver.DriverVersion
                Inf = [string]$selection.SignedDriver.InfName
                GuestImage = $guestImage
                Files = $plan
            }
            $guestMonitor = Install-VMateGpuPGuestMonitorProvisioner `
                -GuestWindowsRoot $guestWindows -DryRun
            $result | Add-Member -NotePropertyName GuestMonitor `
                -NotePropertyValue $guestMonitor
        }
        else {
            $result = Invoke-VMateGpuPDriverPublish $guestWindows $selection $plan
            $result | Add-Member -NotePropertyName GuestImage `
                -NotePropertyValue $guestImage
            $guestMonitor = Install-VMateGpuPGuestMonitorProvisioner `
                -GuestWindowsRoot $guestWindows
            $result | Add-Member -NotePropertyName GuestMonitor `
                -NotePropertyValue $guestMonitor
        }
    }
    catch {
        $operationError = $_
    }
    finally {
        if ($mountedByThisCall) {
            try {
                Dismount-VHD -Path $resolvedVhd -ErrorAction Stop
            }
            catch {
                $dismountError = $_
            }
        }
    }
    if ($null -ne $operationError) {
        if ($null -ne $dismountError) {
            throw ('GPU-P 驱动同步失败且 VHD 卸载也失败：' +
                $operationError.Exception.Message + '；卸载：' +
                $dismountError.Exception.Message)
        }
        throw $operationError
    }
    if ($null -ne $dismountError) {
        throw "GPU-P 驱动已处理，但 VHD 卸载失败：$($dismountError.Exception.Message)"
    }
    return $result
}
