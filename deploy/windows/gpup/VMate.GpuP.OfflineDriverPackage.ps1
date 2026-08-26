#Requires -Version 5.1

<#
.SYNOPSIS
    将宿主已验证的 NVIDIA/AMD 显示驱动包登记到离线 guest DriverStore。

.DESCRIPTION
    GPU-P 仍从 HostDriverStore 取得运行时文件；这里额外使用 Windows DISM API
    登记同一官方签名 INF/CAT 包，使 guest 的 DriverDatabase、INF 发布名和签名
    证据完整。模块不创建设备节点、不强制绑定驱动，也不修改 BCD。
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Open-VMateGpuPDismWindowsPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$GuestWindowsRoot)

    $guestRoot = [IO.Path]::GetFullPath($GuestWindowsRoot)
    $volumePattern =
        '(?i)^(?<VolumeRoot>\\\\\?\\Volume\{[0-9A-Fa-f-]+\})\\Windows$'
    if ($guestRoot -notmatch $volumePattern) {
        $imageRoot = [IO.Directory]::GetParent($guestRoot).FullName
        return [pscustomobject][ordered]@{
            Temporary = $false
            WindowsRoot = $guestRoot
            ImageRoot = $imageRoot
            DiskNumber = $null
            PartitionNumber = $null
            AccessPath = ''
        }
    }
    $volumeRoot = [string]$Matches.VolumeRoot

    $matches = [Collections.Generic.List[object]]::new()
    foreach ($partition in @(Get-Partition -ErrorAction Stop)) {
        foreach ($volume in @($partition | Get-Volume `
                    -ErrorAction SilentlyContinue)) {
            if (([string]$volume.UniqueId).TrimEnd('\') -ieq
                $volumeRoot.TrimEnd('\')) {
                [void]$matches.Add($partition)
            }
        }
    }
    if ($matches.Count -ne 1) {
        throw ('DISM 卷 GUID 必须映射到唯一分区；实际：' + $matches.Count)
    }
    $partition = $matches[0]
    $usedLetters = @(Get-PSDrive -PSProvider FileSystem |
        Where-Object { [string]$_.Name -match '^[A-Za-z]$' } |
        ForEach-Object { ([string]$_.Name).ToUpperInvariant() })
    $letter = @(90..68 | ForEach-Object { [string][char]$_ } |
        Where-Object { $_ -notin $usedLetters } | Select-Object -First 1)
    if ($letter.Count -ne 1) {
        throw '没有可用于离线 DISM 的临时盘符。'
    }
    $accessPath = $letter[0] + ':\'
    $added = $false
    try {
        Add-PartitionAccessPath -DiskNumber $partition.DiskNumber `
            -PartitionNumber $partition.PartitionNumber `
            -AccessPath $accessPath -ErrorAction Stop | Out-Null
        $added = $true
        $windowsRoot = Join-Path $accessPath 'Windows'
        $systemHive = Join-Path $windowsRoot 'System32\Config\SYSTEM'
        if (-not (Test-Path -LiteralPath $systemHive -PathType Leaf)) {
            throw '临时 DISM 盘符没有指向已验证的 guest Windows 分区。'
        }
        return [pscustomobject][ordered]@{
            Temporary = $true
            WindowsRoot = (Get-Item -LiteralPath $windowsRoot `
                -Force -ErrorAction Stop).FullName
            ImageRoot = $accessPath
            DiskNumber = [uint32]$partition.DiskNumber
            PartitionNumber = [uint32]$partition.PartitionNumber
            AccessPath = $accessPath
        }
    }
    catch {
        if ($added) {
            Remove-PartitionAccessPath -DiskNumber $partition.DiskNumber `
                -PartitionNumber $partition.PartitionNumber `
                -AccessPath $accessPath -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Close-VMateGpuPDismWindowsPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Access)

    if (-not [bool]$Access.Temporary) {
        return [pscustomobject]@{ Status = 'NotRequired' }
    }
    Remove-PartitionAccessPath -DiskNumber ([uint32]$Access.DiskNumber) `
        -PartitionNumber ([uint32]$Access.PartitionNumber) `
        -AccessPath ([string]$Access.AccessPath) -ErrorAction Stop
    $partition = Get-Partition -DiskNumber ([uint32]$Access.DiskNumber) `
        -PartitionNumber ([uint32]$Access.PartitionNumber) -ErrorAction Stop
    if (@($partition.AccessPaths | Where-Object {
                [string]$_ -ieq [string]$Access.AccessPath
            }).Count -ne 0) {
        throw "临时 DISM 盘符移除后仍存在：$($Access.AccessPath)"
    }
    return [pscustomobject]@{
        Status = 'Removed'; AccessPath = [string]$Access.AccessPath
    }
}

function Get-VMateGpuPOfflineDriverPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Selection,
        [Parameter(Mandatory = $true)][object[]]$Plan
    )

    $infEntries = @($Plan | Where-Object {
            [string]$_.SystemRootRelativePath -match
                '(?i)^System32\\DriverStore\\FileRepository\\[^\\]+\\[^\\]+\.inf$'
        })
    if ($infEntries.Count -ne 1) {
        throw ('官方显示驱动必须解析到唯一原始 INF；实际：' +
            $infEntries.Count)
    }
    $inf = $infEntries[0]
    $infPath = [IO.Path]::GetFullPath([string]$inf.SourcePath)
    $packageRoot = [IO.Path]::GetDirectoryName($infPath)
    $systemRoot = [IO.Path]::GetPathRoot($infPath)
    if (-not (Test-Path -LiteralPath $infPath -PathType Leaf) -or
        [IO.Path]::GetExtension($infPath) -ine '.inf') {
        throw "官方显示驱动原始 INF 不存在：$infPath"
    }
    Assert-VMateGpuPNoReparsePoint -Path $infPath `
        -BoundaryRoot $systemRoot

    # Win32_PNPSignedDriverCIMDataFile 在 Win10 不一定把 CAT 列为关联项；
    # package root 已由唯一关联 INF 定位，因此只在该精确目录枚举普通 CAT 文件。
    Assert-VMateGpuPNoReparsePoint -Path $packageRoot `
        -BoundaryRoot $systemRoot
    $catalogEntries = @(Get-ChildItem -LiteralPath $packageRoot `
        -Filter '*.cat' -File -Force -ErrorAction Stop)
    if ($catalogEntries.Count -lt 1) {
        throw '官方显示驱动包没有可验证的 CAT。'
    }
    $catalogs = [Collections.Generic.List[object]]::new()
    $vendorPattern = if ([string]$Selection.Vendor.Vendor -ieq 'NVIDIA') {
        '(?i)(NVIDIA|Microsoft Windows Hardware Compatibility Publisher)'
    }
    elseif ([string]$Selection.Vendor.Vendor -ieq 'AMD') {
        '(?i)(AMD|Advanced Micro Devices|Microsoft Windows Hardware Compatibility Publisher)'
    }
    else { throw '离线驱动登记只接受 NVIDIA/AMD。' }
    foreach ($entry in $catalogEntries) {
        $path = [IO.Path]::GetFullPath([string]$entry.FullName)
        Assert-VMateGpuPNoReparsePoint -Path $path `
            -BoundaryRoot $systemRoot
        $signature = Get-AuthenticodeSignature -LiteralPath $path
        $subject = if ($null -eq $signature.SignerCertificate) {
            ''
        }
        else { [string]$signature.SignerCertificate.Subject }
        if ([string]$signature.Status -cne 'Valid' -or
            $subject -notmatch $vendorPattern) {
            throw "官方显示驱动 CAT 签名无效：$path / $subject"
        }
        [void]$catalogs.Add([pscustomobject][ordered]@{
                Path = $path
                SHA256 = (Get-FileHash -LiteralPath $path `
                    -Algorithm SHA256).Hash.ToUpperInvariant()
                Signer = $subject
            })
    }
    return [pscustomobject][ordered]@{
        Vendor = [string]$Selection.Vendor.Vendor
        Provider = [string]$Selection.SignedDriver.DriverProviderName
        Version = [string]$Selection.SignedDriver.DriverVersion
        HostPublishedInf = [string]$Selection.SignedDriver.InfName
        OriginalInfName = [IO.Path]::GetFileName($infPath)
        InfPath = $infPath
        InfSHA256 = (Get-FileHash -LiteralPath $infPath `
            -Algorithm SHA256).Hash.ToUpperInvariant()
        PackageRoot = $packageRoot
        Catalogs = @($catalogs)
    }
}

function Get-VMateGpuPOfflineDriverPackageState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$OfflineImageRoot,
        [Parameter(Mandatory = $true)][object]$Package
    )

    $drivers = @(Get-WindowsDriver -Path $OfflineImageRoot -All `
        -ErrorAction Stop | Where-Object {
            [string]$_.ClassName -ieq 'Display' -and
            [IO.Path]::GetFileName([string]$_.OriginalFileName) -ieq
                [string]$Package.OriginalInfName -and
            [string]$_.ProviderName -ieq [string]$Package.Provider -and
            [string]$_.Version -ieq [string]$Package.Version
        })
    if ($drivers.Count -gt 1) {
        throw ('离线 guest 有多个完全相同的显示驱动包，拒绝继续：' +
            (($drivers | ForEach-Object { [string]$_.Driver }) -join ', '))
    }
    return [pscustomobject][ordered]@{
        Present = $drivers.Count -eq 1
        Driver = if ($drivers.Count -eq 1) { [string]$drivers[0].Driver } else { '' }
        Record = if ($drivers.Count -eq 1) { $drivers[0] } else { $null }
    }
}

function Install-VMateGpuPOfflineDriverPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$GuestWindowsRoot,
        [Parameter(Mandatory = $true)][object]$Package,
        [switch]$DryRun
    )

    # Win10 的 DISM PowerShell provider 在只读挂载的 VHD 上可能阻塞；
    # DryRun 已由调用方完成映像、源包、CAT 签名及哈希验证，不打开 servicing
    # session。是否已登记只在正式可写事务中回读。
    if ($DryRun) {
        return [pscustomobject][ordered]@{
            Status = 'DryRun'
            ChangeRequired = $null
            PublishedInf = ''
            Package = $Package
            Driver = $null
            StateProbe = 'DeferredToWritableApply'
        }
    }

    $access = Open-VMateGpuPDismWindowsPath `
        -GuestWindowsRoot $GuestWindowsRoot
    $addAttempted = $false
    try {
        $dismImageRoot = [string]$access.ImageRoot
        $before = Get-VMateGpuPOfflineDriverPackageState `
            -OfflineImageRoot $dismImageRoot -Package $Package
        if ($before.Present) {
            return [pscustomobject][ordered]@{
                Status = 'AlreadyPresent'
                ChangeRequired = $false
                PublishedInf = [string]$before.Driver
                Package = $Package
                Driver = $before.Record
            }
        }
        $addAttempted = $true
        $added = @(Add-WindowsDriver -Path $dismImageRoot `
            -Driver ([string]$Package.InfPath) -ErrorAction Stop)
        $after = Get-VMateGpuPOfflineDriverPackageState `
            -OfflineImageRoot $dismImageRoot -Package $Package
        if (-not $after.Present -or
            [string]$after.Driver -notmatch '^oem[0-9]+\.inf$') {
            throw 'DISM 返回成功，但离线 guest 没有唯一回读到官方显示驱动包。'
        }
        if ($added.Count -gt 0 -and
            @($added | Where-Object {
                    [string]$_.Driver -ieq [string]$after.Driver
                }).Count -ne 1) {
            throw 'DISM 新增结果与离线 DriverStore 回读不一致。'
        }
        return [pscustomobject][ordered]@{
            Status = 'Installed'
            ChangeRequired = $true
            PublishedInf = [string]$after.Driver
            Package = $Package
            Driver = $after.Record
        }
    }
    catch {
        $installError = $_
        if (-not $addAttempted) {
            throw $installError
        }
        try {
            $partial = Get-VMateGpuPOfflineDriverPackageState `
                -OfflineImageRoot ([string]$access.ImageRoot) `
                -Package $Package
            if ($partial.Present -and
                [string]$partial.Driver -match '^oem[0-9]+\.inf$') {
                [void](Remove-WindowsDriver `
                        -Path ([string]$access.ImageRoot) `
                        -Driver ([string]$partial.Driver) -ErrorAction Stop)
            }
        }
        catch {
            throw ('离线官方驱动包登记失败且部分登记回滚失败：' +
                $installError.Exception.Message + '；回滚：' +
                $_.Exception.Message)
        }
        throw $installError
    }
    finally {
        [void](Close-VMateGpuPDismWindowsPath -Access $access)
    }
}

function Undo-VMateGpuPOfflineDriverPackageInstall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$GuestWindowsRoot,
        [Parameter(Mandatory = $true)][object]$InstallResult
    )

    if ([string]$InstallResult.Status -cne 'Installed' -or
        -not [bool]$InstallResult.ChangeRequired) {
        return [pscustomobject]@{ Status = 'NotRequired' }
    }
    $published = [string]$InstallResult.PublishedInf
    if ($published -notmatch '^oem[0-9]+\.inf$') {
        throw "拒绝回滚非 OEM 发布名：$published"
    }
    $access = Open-VMateGpuPDismWindowsPath `
        -GuestWindowsRoot $GuestWindowsRoot
    try {
        [void](Remove-WindowsDriver -Path ([string]$access.ImageRoot) `
                -Driver $published -ErrorAction Stop)
        $state = Get-VMateGpuPOfflineDriverPackageState `
            -OfflineImageRoot ([string]$access.ImageRoot) `
            -Package $InstallResult.Package
        if ($state.Present) {
            throw "离线显示驱动回滚后仍存在：$published"
        }
        return [pscustomobject]@{
            Status = 'Removed'; PublishedInf = $published
        }
    }
    finally {
        [void](Close-VMateGpuPDismWindowsPath -Access $access)
    }
}

function Invoke-VMateGpuPDriverPublishWithOfflinePackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$GuestWindowsRoot,
        [Parameter(Mandatory = $true)][object]$Selection,
        [Parameter(Mandatory = $true)][object[]]$Plan,
        [Parameter(Mandatory = $true)][object]$Package
    )

    $install = Install-VMateGpuPOfflineDriverPackage `
        -GuestWindowsRoot $GuestWindowsRoot -Package $Package
    try {
        $result = Invoke-VMateGpuPDriverPublish `
            $GuestWindowsRoot $Selection $Plan
    }
    catch {
        $publishError = $_
        try {
            [void](Undo-VMateGpuPOfflineDriverPackageInstall `
                    -GuestWindowsRoot $GuestWindowsRoot `
                    -InstallResult $install)
        }
        catch {
            throw ('HostDriverStore 发布失败且离线官方驱动包回滚失败：' +
                $publishError.Exception.Message + '；回滚：' +
                $_.Exception.Message)
        }
        throw $publishError
    }
    $result | Add-Member -NotePropertyName OfflineDriverPackage `
        -NotePropertyValue $install
    return $result
}
