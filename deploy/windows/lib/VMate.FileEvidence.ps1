#requires -Version 5.1
<#
.SYNOPSIS
    提供受限于固定本地磁盘的文件、系统驱动和 SetupAPI 日志证据。
.NOTES
    所有路径在读取前逐级拒绝 reparse point；模块不访问 UNC、设备路径或映射盘。
#>

$script:VMateEvidenceFixedLocalDrives = $null

function Resolve-VMateSafeLocalFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string]$LiteralPath)

    $result = [ordered]@{ safe = $false; path = $null; item = $null; error = $null }
    if ([string]::IsNullOrWhiteSpace($LiteralPath) -or
        $LiteralPath -notmatch '^[A-Za-z]:\\') {
        $result.error = '拒绝 UNC、设备路径或非绝对本地路径'
        return [pscustomobject]$result
    }
    try {
        $fullPath = [IO.Path]::GetFullPath($LiteralPath)
    } catch {
        $result.error = "路径规范化失败: $($_.Exception.Message)"
        return [pscustomobject]$result
    }
    if ($null -eq $script:VMateEvidenceFixedLocalDrives) {
        try {
            $script:VMateEvidenceFixedLocalDrives = @(
                Get-CimInstance Win32_LogicalDisk -Filter 'DriveType = 3' -ErrorAction Stop |
                    ForEach-Object { [string]$_.DeviceID })
        } catch {
            $result.error = "无法验证固定本地磁盘: $($_.Exception.Message)"
            return [pscustomobject]$result
        }
    }
    if ($script:VMateEvidenceFixedLocalDrives -notcontains $fullPath.Substring(0, 2)) {
        $result.error = '路径不在固定本地磁盘上'
        return [pscustomobject]$result
    }

    $current = [IO.Path]::GetPathRoot($fullPath)
    $item = $null
    foreach ($segment in @($fullPath.Substring($current.Length) -split '\\' |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $current = Join-Path $current $segment
        try {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        } catch {
            $result.error = "路径组件不可访问: $current"
            return [pscustomobject]$result
        }
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            $result.error = "拒绝包含 reparse point 的路径: $current"
            return [pscustomobject]$result
        }
    }
    if ($null -eq $item -or $item.PSIsContainer) {
        $result.error = '路径不是可读取的普通文件'
        return [pscustomobject]$result
    }
    $result.safe = $true
    $result.path = $fullPath
    $result.item = $item
    return [pscustomobject]$result
}

function Get-VMateFileEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$LiteralPath
    )

    $errors = [Collections.Generic.List[string]]::new()
    $result = [ordered]@{
        path = $LiteralPath
        exists = $false
        local_path_validated = $false
        is_reparse_point = $false
        length = $null
        creation_time_utc = $null
        last_write_time_utc = $null
        sha256 = $null
        signature_status = $null
        signer_subject = $null
        signer_thumbprint = $null
        company_name = $null
        product_name = $null
        file_description = $null
        file_version = $null
        changed_during_collection = $false
        collection_errors = @()
    }
    $safeFile = Resolve-VMateSafeLocalFile -LiteralPath $LiteralPath
    if (-not $safeFile.safe) {
        $errors.Add([string]$safeFile.error)
        $result.collection_errors = @($errors)
        return [pscustomobject]$result
    }
    $LiteralPath = [string]$safeFile.path
    $result.path = $LiteralPath
    $result.local_path_validated = $true

    try {
        $before = $safeFile.item
        $result.exists = $true
        $result.length = [long]$before.Length
        $result.creation_time_utc = $before.CreationTimeUtc.ToString('o')
        $result.last_write_time_utc = $before.LastWriteTimeUtc.ToString('o')
        $result.is_reparse_point = (($before.Attributes -band
                    [IO.FileAttributes]::ReparsePoint) -ne 0)
        if ($result.is_reparse_point) {
            $errors.Add('拒绝跟随 reparse point')
            $result.collection_errors = @($errors)
            return [pscustomobject]$result
        }
    } catch {
        $errors.Add("读取元数据失败: $($_.Exception.Message)")
        $result.collection_errors = @($errors)
        return [pscustomobject]$result
    }

    try {
        $result.sha256 = (Get-FileHash -Algorithm SHA256 `
                -LiteralPath $LiteralPath -ErrorAction Stop).Hash
    } catch {
        $errors.Add("计算 SHA-256 失败: $($_.Exception.Message)")
    }
    try {
        $signature = Get-AuthenticodeSignature -LiteralPath $LiteralPath -ErrorAction Stop
        $result.signature_status = $signature.Status.ToString()
        if ($null -ne $signature.SignerCertificate) {
            $result.signer_subject = $signature.SignerCertificate.Subject
            $result.signer_thumbprint = $signature.SignerCertificate.Thumbprint
        }
    } catch {
        $errors.Add("读取签名失败: $($_.Exception.Message)")
    }
    try {
        $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($LiteralPath)
        $result.company_name = $version.CompanyName
        $result.product_name = $version.ProductName
        $result.file_description = $version.FileDescription
        $result.file_version = $version.FileVersion
    } catch {
        $errors.Add("读取版本资源失败: $($_.Exception.Message)")
    }
    try {
        $after = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction Stop
        $result.changed_during_collection = (
            [long]$after.Length -ne [long]$before.Length -or
            $after.LastWriteTimeUtc -ne $before.LastWriteTimeUtc)
        if ($result.changed_during_collection) {
            $errors.Add('文件在采集过程中发生变化，哈希和签名可能不属于同一版本')
        }
    } catch {
        $errors.Add("复核元数据失败: $($_.Exception.Message)")
    }
    $result.collection_errors = @($errors)
    return [pscustomobject]$result
}

function Resolve-VMateSystemDriverPath {
    [CmdletBinding()]
    param(
        [AllowNull()] [AllowEmptyString()] [string]$PathName,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$FixedLocalDrives
    )

    if ([string]::IsNullOrWhiteSpace($PathName)) { return $null }
    $expanded = [Environment]::ExpandEnvironmentVariables($PathName.Trim())
    $options = [Text.RegularExpressions.RegexOptions]::IgnoreCase
    $match = if ($expanded.StartsWith('"')) {
        [regex]::Match($expanded, '^"([^\"]+\.sys)"', $options)
    } else {
        [regex]::Match($expanded, '^(.*?\.sys)(?:\s|$)', $options)
    }
    if (-not $match.Success) { return $null }
    $candidate = $match.Groups[1].Value
    if ($candidate.StartsWith('\\?\')) { $candidate = $candidate.Substring(4) }
    if ($candidate.StartsWith('\??\')) { $candidate = $candidate.Substring(4) }
    if ($candidate.StartsWith('\SystemRoot\', [StringComparison]::OrdinalIgnoreCase)) {
        $candidate = Join-Path $env:windir $candidate.Substring(12)
    } elseif ($candidate.StartsWith('SystemRoot\',
            [StringComparison]::OrdinalIgnoreCase)) {
        $candidate = Join-Path $env:windir $candidate.Substring(11)
    } elseif ($candidate.StartsWith('System32\',
            [StringComparison]::OrdinalIgnoreCase)) {
        $candidate = Join-Path $env:windir $candidate
    }
    if ($candidate -notmatch '^[A-Za-z]:\\') { return $null }
    try {
        $resolved = [IO.Path]::GetFullPath($candidate)
    } catch {
        return $null
    }
    if ($FixedLocalDrives -notcontains $resolved.Substring(0, 2)) { return $null }
    return $resolved
}

function Get-VMateSystemDriverEvidence {
    [CmdletBinding()]
    param()

    $errors = [Collections.Generic.List[string]]::new()
    try {
        $fixedDrives = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType = 3' `
                -ErrorAction Stop | ForEach-Object { [string]$_.DeviceID })
    } catch {
        $fixedDrives = @()
        $errors.Add("固定磁盘枚举失败: $($_.Exception.Message)")
    }
    [pscustomobject][ordered]@{
        record_type = 'metadata'
        fixed_local_drives = @($fixedDrives)
        contains_sensitive_data = $true
        collection_errors = @($errors)
    }

    foreach ($driver in @(Get-CimInstance Win32_SystemDriver -ErrorAction Stop |
            Sort-Object Name)) {
        $resolvedPath = Resolve-VMateSystemDriverPath -PathName $driver.PathName `
            -FixedLocalDrives $fixedDrives
        $file = $null
        $recordErrors = [Collections.Generic.List[string]]::new()
        if (-not [string]::IsNullOrWhiteSpace([string]$driver.PathName) -and
            [string]::IsNullOrWhiteSpace($resolvedPath)) {
            $recordErrors.Add('驱动路径无法安全解析为固定本地磁盘上的 .sys 文件')
        }
        if (-not [string]::IsNullOrWhiteSpace($resolvedPath)) {
            $file = Get-VMateFileEvidence -LiteralPath $resolvedPath
            foreach ($fileError in @($file.collection_errors)) {
                $recordErrors.Add([string]$fileError)
            }
        }
        [pscustomobject][ordered]@{
            record_type = 'driver'
            name = $driver.Name
            display_name = $driver.DisplayName
            state = $driver.State
            started = $driver.Started
            start_mode = $driver.StartMode
            service_type = $driver.ServiceType
            path_name = $driver.PathName
            resolved_local_path = $resolvedPath
            file = $file
            collection_errors = @($recordErrors)
        }
    }
}

function Get-VMateSetupApiEvidence {
    [CmdletBinding()]
    param([ValidateRange(100, 20000)] [int]$TailLines = 5000)

    $path = Join-Path $env:windir 'INF\setupapi.dev.log'
    $file = Get-VMateFileEvidence -LiteralPath $path
    $errors = [Collections.Generic.List[string]]::new()
    foreach ($fileError in @($file.collection_errors)) { $errors.Add($fileError) }
    $tail = @()
    if ($file.exists -and -not $file.is_reparse_point) {
        try {
            $tail = @(Get-Content -LiteralPath $path -Tail $TailLines -ErrorAction Stop)
        } catch {
            $errors.Add("读取 SetupAPI 日志失败: $($_.Exception.Message)")
        }
    }
    return [pscustomobject][ordered]@{
        path = $path
        file = $file
        tail_line_limit = $TailLines
        tail = $tail
        contains_sensitive_data = $true
        collection_errors = @($errors)
    }
}
