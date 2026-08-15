#Requires -Version 5.1

<#
.SYNOPSIS
    发现所选 Windows Hyper-V GPU-P 设备的官方 WDDM 宿主驱动文件。

.DESCRIPTION
    从真实 partitionable PCI InstanceId 解析 PnP、签名包、服务及 CIM 文件
    关联，并生成经过 SystemRoot/reparse/hash 校验的厂商中立复制计划。
#>

function ConvertTo-VMateGpuPCanonicalRoot {
    param([Parameter(Mandatory = $true)][string]$Root)

    $full = [System.IO.Path]::GetFullPath($Root)
    $fileSystemRoot = [System.IO.Path]::GetPathRoot($full)
    if (-not $full.Equals($fileSystemRoot,
            [System.StringComparison]::OrdinalIgnoreCase)) {
        $full = $full.TrimEnd([char[]]@(
                [System.IO.Path]::DirectorySeparatorChar,
                [System.IO.Path]::AltDirectorySeparatorChar))
    }
    return $full
}

function Test-VMateGpuPPathWithinRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )

    try {
        $pathFull = [System.IO.Path]::GetFullPath($Path)
        $rootFull = ConvertTo-VMateGpuPCanonicalRoot $Root
    } catch {
        return $false
    }
    if (-not [System.IO.Path]::IsPathRooted($pathFull) -or
        -not [System.IO.Path]::IsPathRooted($rootFull)) {
        return $false
    }
    if ($pathFull.Equals($rootFull,
            [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    $prefix = $rootFull
    if (-not $prefix.EndsWith([string][System.IO.Path]::DirectorySeparatorChar)) {
        $prefix += [System.IO.Path]::DirectorySeparatorChar
    }
    return $pathFull.StartsWith($prefix,
        [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-VMateGpuPNoReparsePoint {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$BoundaryRoot
    )

    $full = [System.IO.Path]::GetFullPath($Path)
    $root = ConvertTo-VMateGpuPCanonicalRoot $BoundaryRoot
    if (-not (Test-VMateGpuPPathWithinRoot -Path $full -Root $root)) {
        throw "路径越过受信根目录：$full"
    }
    $current = $full
    while ($true) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (($item.Attributes -band
                    [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "路径包含 reparse point，拒绝访问：$current"
            }
        }
        if ($current.Equals($root,
                [System.StringComparison]::OrdinalIgnoreCase)) {
            break
        }
        $parent = [System.IO.Directory]::GetParent($current)
        if ($null -eq $parent -or
            -not (Test-VMateGpuPPathWithinRoot -Path $parent.FullName -Root $root)) {
            throw "路径父级越过受信根目录：$full"
        }
        $current = $parent.FullName
    }
}

function ConvertTo-VMateGpuPInstanceId {
    param([Parameter(Mandatory = $true)][string]$PartitionableName)

    $value = $PartitionableName.Trim()
    if ($value.StartsWith('\\?\',
            [System.StringComparison]::OrdinalIgnoreCase)) {
        $value = $value.Substring(4)
    }
    $interface = $value.IndexOf('#{',
        [System.StringComparison]::OrdinalIgnoreCase)
    if ($interface -ge 0) {
        $value = $value.Substring(0, $interface).Replace('#', '\')
    }
    if ($value -cnotmatch '(?i)^PCI\\VEN_(10DE|1002)&[A-Z0-9_&.-]+\\[A-Z0-9_&.-]+$') {
        throw "无法从 partitionable GPU 名称解析受支持的 PCI 实例：$PartitionableName"
    }
    return $value.ToUpperInvariant()
}

function Get-VMateGpuPVendor {
    param([Parameter(Mandatory = $true)][string]$InstanceId)

    if ($InstanceId -match '(?i)^PCI\\VEN_10DE&') {
        return [pscustomobject][ordered]@{
            Vendor = 'NVIDIA'; VendorId = '10DE'
            Providers = @('NVIDIA', 'NVIDIA Corporation')
        }
    }
    if ($InstanceId -match '(?i)^PCI\\VEN_1002&') {
        return [pscustomobject][ordered]@{
            Vendor = 'AMD'; VendorId = '1002'
            Providers = @('Advanced Micro Devices, Inc.',
                'Advanced Micro Devices, Inc', 'AMD', 'ATI Technologies Inc.')
        }
    }
    throw "GPU-P 只支持已审计的 PCI VEN_10DE/VEN_1002：$InstanceId"
}

function Test-VMateGpuPProvider {
    param(
        [Parameter(Mandatory = $true)][string]$ProviderName,
        [Parameter(Mandatory = $true)][object]$Vendor
    )

    foreach ($allowed in @($Vendor.Providers)) {
        if ($ProviderName.Trim().Equals([string]$allowed,
                [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function ConvertTo-VMateGpuPServiceFilePath {
    param(
        [Parameter(Mandatory = $true)][string]$PathName,
        [Parameter(Mandatory = $true)][string]$SystemRoot
    )

    $value = [Environment]::ExpandEnvironmentVariables($PathName.Trim())
    if ($value -match '(?i)^\\SystemRoot\\(.+)$') {
        $value = Join-Path $SystemRoot $Matches[1]
    } elseif ($value -match '(?i)^System32\\(.+)$') {
        $value = Join-Path $SystemRoot $value
    } elseif ($value.StartsWith('"')) {
        if ($value -notmatch '^"([^"\r\n]+)"') {
            throw "服务映像路径引号无效：$PathName"
        }
        $value = $Matches[1]
    } elseif ($value -match '(?i)^(.+?\.sys)(?:\s|$)') {
        $value = $Matches[1]
    }
    if ($value -match '%' -or -not [System.IO.Path]::IsPathRooted($value)) {
        throw "服务映像路径无法安全解析：$PathName"
    }
    return [System.IO.Path]::GetFullPath($value)
}

function Get-VMateGpuPSystemRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$SystemRoot
    )

    $source = [System.IO.Path]::GetFullPath($SourcePath)
    $root = ConvertTo-VMateGpuPCanonicalRoot $SystemRoot
    if (-not (Test-VMateGpuPPathWithinRoot -Path $source -Root $root) -or
        $source.Equals($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "驱动源文件不在规范化 SystemRoot 下：$SourcePath"
    }
    $relative = $source.Substring($root.Length).TrimStart([char[]]@('\', '/'))
    $segments = @($relative -split '[\\/]+' | Where-Object { $_ -ne '' })
    if ($segments.Count -lt 2 -or @($segments | Where-Object {
                $_ -in @('.', '..') -or $_ -match '[:*?"<>|\x00-\x1f]'
            }).Count -ne 0) {
        throw "驱动源文件的相对路径无效：$SourcePath"
    }
    return ($segments -join '\')
}

function ConvertTo-VMateGpuPGuestRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$SystemRoot
    )

    $relative = Get-VMateGpuPSystemRelativePath -SourcePath $SourcePath `
        -SystemRoot $SystemRoot
    $segments = @($relative -split '\\')
    if ($segments[0].Equals('System32',
            [System.StringComparison]::OrdinalIgnoreCase) -and
        $segments.Count -gt 2 -and $segments[1].Equals('DriverStore',
            [System.StringComparison]::OrdinalIgnoreCase)) {
        return (@('System32', 'HostDriverStore') + $segments[2..($segments.Count - 1)]) -join '\'
    }
    if ($segments[0].Equals('System32',
            [System.StringComparison]::OrdinalIgnoreCase) -or
        $segments[0].Equals('SysWOW64',
            [System.StringComparison]::OrdinalIgnoreCase)) {
        return $relative
    }
    throw "GPU-P 驱动文件不属于 DriverStore/System32/SysWOW64：$relative"
}

function Join-VMateGpuPGuestPath {
    param(
        [Parameter(Mandatory = $true)][string]$GuestWindowsRoot,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    $result = $GuestWindowsRoot
    foreach ($segment in @($RelativePath -split '\\')) {
        if (-not $segment -or $segment -in @('.', '..')) {
            throw "guest 相对路径含非法分段：$RelativePath"
        }
        $result = Join-Path $result $segment
    }
    $full = [System.IO.Path]::GetFullPath($result)
    if (-not (Test-VMateGpuPPathWithinRoot -Path $full -Root $GuestWindowsRoot)) {
        throw "guest 目标路径越界：$RelativePath"
    }
    return $full
}

function New-VMateGpuPDriverCopyPlan {
    param(
        [Parameter(Mandatory = $true)][string[]]$SourcePaths,
        [Parameter(Mandatory = $true)][string]$SystemRoot
    )

    $root = (Get-Item -LiteralPath $SystemRoot -Force -ErrorAction Stop).FullName
    Assert-VMateGpuPNoReparsePoint -Path $root -BoundaryRoot $root
    $destinations = New-Object 'System.Collections.Generic.Dictionary[string,string]' `
        ([System.StringComparer]::OrdinalIgnoreCase)
    $plan = New-Object System.Collections.Generic.List[object]
    foreach ($candidate in @($SourcePaths | Sort-Object -Unique)) {
        $source = [System.IO.Path]::GetFullPath($candidate)
        Assert-VMateGpuPNoReparsePoint -Path $source -BoundaryRoot $root
        $item = Get-Item -LiteralPath $source -Force -ErrorAction Stop
        if ($item.PSIsContainer) {
            throw "驱动关联项不是普通文件：$source"
        }
        $sourceRelative = Get-VMateGpuPSystemRelativePath $source $root
        $guestRelative = ConvertTo-VMateGpuPGuestRelativePath $source $root
        if ($destinations.ContainsKey($guestRelative) -and
            -not $destinations[$guestRelative].Equals($source,
                [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "多个源文件映射到同一 guest 路径：$guestRelative"
        }
        if (-not $destinations.ContainsKey($guestRelative)) {
            $destinations.Add($guestRelative, $source)
            $hash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
            $plan.Add([pscustomobject][ordered]@{
                    SourcePath = $source
                    SystemRootRelativePath = $sourceRelative
                    GuestWindowsRelativePath = $guestRelative
                    Length = [int64]$item.Length
                    SHA256 = $hash.ToUpperInvariant()
                })
        }
    }
    if ($plan.Count -eq 0) {
        throw '所选 GPU 没有可同步的驱动文件。'
    }
    return @($plan | Sort-Object GuestWindowsRelativePath)
}

function Get-VMateGpuPDriverSelection {
    param([string]$GpuInstanceId = '')

    $partitionable = @(Get-VMHostPartitionableGpu -ErrorAction Stop |
        Where-Object { [string]$_.Name -match '(?i)VEN_(10DE|1002)(?:&|#)' } |
        ForEach-Object {
            $id = ConvertTo-VMateGpuPInstanceId ([string]$_.Name)
            [pscustomobject]@{ InstanceId = $id; Partitionable = $_ }
        })
    if ($GpuInstanceId) {
        $wanted = $GpuInstanceId.Trim().ToUpperInvariant()
        $partitionable = @($partitionable | Where-Object {
                $_.InstanceId.Equals($wanted,
                    [System.StringComparison]::OrdinalIgnoreCase) })
    }
    if ($partitionable.Count -ne 1) {
        throw "必须明确选中唯一的 NVIDIA/AMD partitionable GPU，实际：$($partitionable.Count)"
    }
    $selected = $partitionable[0]
    $vendor = Get-VMateGpuPVendor $selected.InstanceId
    $pnp = @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop |
        Where-Object { [string]$_.DeviceID -ieq $selected.InstanceId })
    $signed = @(Get-CimInstance -ClassName Win32_PNPSignedDriver -ErrorAction Stop |
        Where-Object { [string]$_.DeviceID -ieq $selected.InstanceId })
    if ($pnp.Count -ne 1 -or $signed.Count -ne 1) {
        throw '所选 partitionable GPU 的 PnP/签名驱动记录不唯一。'
    }
    if ($signed[0].IsSigned -ne $true -or
        -not (Test-VMateGpuPProvider ([string]$signed[0].DriverProviderName) $vendor)) {
        throw "所选 GPU 的驱动不是匹配厂商的官方签名包：$($vendor.Vendor)"
    }
    $signer = [string]$signed[0].Signer
    $signerPattern = if ($vendor.Vendor -ieq 'NVIDIA') {
        '(?i)(NVIDIA|Microsoft Windows Hardware Compatibility Publisher)'
    } else {
        '(?i)(AMD|Advanced Micro Devices|Microsoft Windows Hardware Compatibility Publisher)'
    }
    if ([String]::IsNullOrWhiteSpace($signer) -or
        $signer -notmatch $signerPattern) {
        throw "所选 GPU 的签名者不属于 $($vendor.Vendor) 官方/WHCP 链：$signer"
    }
    if ([string]$signed[0].InfName -notmatch '^[A-Za-z0-9_.-]+\.inf$' -or
        [string]::IsNullOrWhiteSpace([string]$signed[0].DriverVersion)) {
        throw '所选 GPU 的 INF 或驱动版本无效。'
    }
    $serviceName = ([string]$pnp[0].Service).Trim()
    if ($serviceName -notmatch '^[A-Za-z0-9_.-]+$') {
        throw '所选 GPU 没有可安全解析的 PnP 服务。'
    }
    $services = @(Get-CimInstance -ClassName Win32_SystemDriver -ErrorAction Stop |
        Where-Object { [string]$_.Name -ieq $serviceName })
    if ($services.Count -ne 1) {
        throw "所选 GPU 的系统驱动服务不唯一：$serviceName"
    }
    return [pscustomobject][ordered]@{
        InstanceId = $selected.InstanceId
        PartitionableName = [string]$selected.Partitionable.Name
        Vendor = $vendor
        Pnp = $pnp[0]
        SignedDriver = $signed[0]
        Services = $services
    }
}

function Get-VMateGpuPDriverSourcePaths {
    param(
        [Parameter(Mandatory = $true)][object]$Selection,
        [Parameter(Mandatory = $true)][string]$SystemRoot
    )

    $files = @(Get-CimAssociatedInstance -InputObject $Selection.SignedDriver `
        -Association Win32_PNPSignedDriverCIMDataFile `
        -ResultClassName CIM_DataFile -ErrorAction Stop)
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($file in $files) {
        if ([string]::IsNullOrWhiteSpace([string]$file.Name)) {
            throw '驱动 CIM 关联包含空文件路径。'
        }
        $paths.Add([string]$file.Name)
    }
    foreach ($service in @($Selection.Services)) {
        $paths.Add((ConvertTo-VMateGpuPServiceFilePath `
                    -PathName ([string]$service.PathName) -SystemRoot $SystemRoot))
    }
    $plan = @(New-VMateGpuPDriverCopyPlan -SourcePaths $paths -SystemRoot $SystemRoot)
    if (@($plan | Where-Object {
                $_.SystemRootRelativePath -match '(?i)^System32\\DriverStore\\'
            }).Count -eq 0) {
        throw '官方驱动关联未包含 DriverStore 文件，拒绝不完整同步。'
    }
    return $plan
}

function Get-VMateGpuPFingerprint {
    param(
        [Parameter(Mandatory = $true)][object]$Selection,
        [Parameter(Mandatory = $true)][object[]]$Plan
    )

    $lines = @($Selection.InstanceId, $Selection.Vendor.VendorId,
        [string]$Selection.SignedDriver.DriverVersion,
        [string]$Selection.SignedDriver.InfName) + @($Plan | ForEach-Object {
            $_.GuestWindowsRelativePath + '|' + $_.SHA256
        })
    $bytes = [Text.Encoding]::UTF8.GetBytes(($lines -join "`n"))
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '')
    } finally {
        $sha.Dispose()
    }
}
