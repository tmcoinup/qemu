# dnf-fix-directx.ps1 —— DirectX June 2010 完整运行库安装模块
#
# 该文件由 dnf-fix-deps.ps1 在受保护的 ProgramData payload 目录中引入。
# 旧 Web 安装器在新版核心 DirectX 已存在、legacy D3DX 仍缺失时，
# 可能生成零个安装 section 并以 -9 (DSETUPERR_INTERNAL) 退出。
# 因此这里改用官方完整包：先下载和验签/验哈希，再在唯一
# 目录解包，最后运行 DXSETUP.exe /silent。

function New-DirectXPackage {
    param(
        [Parameter(Mandatory)][string]$WindowsDir,
        [Parameter(Mandatory)][string]$System32Dir,
        [Parameter(Mandatory)][string]$SysWow64Dir
    )

    return @{
        Id          = 'directx-jun2010'
        Name        = 'DirectX End-User Runtimes (June 2010)'
        Url         = 'https://download.microsoft.com/download/8/4/A/84A35BF1-DAFE-4AE8-82AF-AD2AE20B6B14/directx_Jun2010_redist.exe'
        File        = 'directx_Jun2010_redist.exe'
        # Microsoft 2021 刷新的 SHA-256 签名版；固定哈希避免通用
        # WEXTRACT.EXE 的 OriginalFilename 无法唯一识别 DirectX 外层包。
        Sha256      = '053F76DCBB28802E23341B6A787E3B0791C0FA5C8D4D011B1044172DBF89C73B'
        InstallKind = 'DirectXRedist'
        # DirectSetup 会自行快速判断是否需要更新，每次执行也可修复损坏文件。
        AlwaysInstall = $true
        # d3dx9_43.dll 是 June 2010 redist 标志文件，DNF 使用 x86 版。
        CheckDll    = @(
            (Join-Path $SysWow64Dir 'd3dx9_43.dll'),
            (Join-Path $System32Dir 'd3dx9_43.dll')
        )
        CheckMachine = @(0x014C, 0x8664)
        MinFileVersion = '9.29.952.3111'
        NativeLogs = @(
            (Join-Path $WindowsDir 'Logs\DXError.log'),
            (Join-Path $WindowsDir 'Logs\DirectX.log'),
            (Join-Path $WindowsDir 'DXError.log'),
            (Join-Path $WindowsDir 'DirectX.log')
        )
    }
}

# DirectSetup 使用有符号返回码；-9 表示内部或不支持的错误。
function Get-DirectXExitCodeText {
    param([Parameter(Mandatory)][int]$Code)

    $name = if ($Code -eq 0) {
        'DSETUPERR_SUCCESS'
    } elseif ($Code -eq 1) {
        'DSETUPERR_SUCCESS_RESTART'
    } elseif ($Code -eq -9) {
        'DSETUPERR_INTERNAL'
    } else {
        'UNMAPPED_DSETUP_ERROR'
    }
    $unsigned = [BitConverter]::ToUInt32([BitConverter]::GetBytes($Code), 0)
    return "$Code (0x$($unsigned.ToString('X8')), $name)"
}

function Get-NativeExitCodeText {
    param([Parameter(Mandatory)][int]$Code)

    $unsigned = [BitConverter]::ToUInt32([BitConverter]::GetBytes($Code), 0)
    return ('{0} (0x{1:X8})' -f $Code, $unsigned)
}

# 将 DirectSetup 原生日志尾部同步到主日志，下次失败时无需再猜返回码。
function Write-DirectXNativeLogs {
    param([Parameter(Mandatory)][string[]]$Paths)

    foreach ($path in $Paths) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        Write-Log "  DirectX 原生日志: $path" -Level WARN
        try {
            Get-Content -LiteralPath $path -Tail 30 -ErrorAction Stop |
                ForEach-Object { Write-Log "    $_" -Level WARN }
        } catch {
            Write-Log "    无法读取: $($_.Exception.Message)" -Level WARN
        }
    }
}

# 仅删除本次在缓存目录直接创建的唯一解包目录。
function Remove-DirectXExtractDirectory {
    param(
        [Parameter(Mandatory)][string]$ExtractDir,
        [Parameter(Mandatory)][string]$CacheDir
    )

    $extractFull = [IO.Path]::GetFullPath($ExtractDir).TrimEnd('\')
    $cacheFull = [IO.Path]::GetFullPath($CacheDir).TrimEnd('\')
    $leaf = [IO.Path]::GetFileName($extractFull)
    if ([IO.Path]::GetDirectoryName($extractFull) -ine $cacheFull -or
        $leaf -notlike 'directx-extract-*') {
        Write-Log "  拒绝清理超出缓存边界的目录: $extractFull" -Level WARN
        return
    }
    if (-not (Test-Path -LiteralPath $extractFull)) { return }
    $item = Get-Item -LiteralPath $extractFull -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Write-Log "  拒绝递归清理重解析点: $extractFull" -Level WARN
        return
    }
    Remove-Item -LiteralPath $extractFull -Recurse -Force
}

function Invoke-DirectXRedist {
    param(
        [Parameter(Mandatory)][hashtable]$Package,
        [Parameter(Mandatory)][string]$ExePath,
        [Parameter(Mandatory)][string]$CacheDir
    )

    if (-not (Test-MicrosoftInstaller -Path $ExePath `
                -ExpectedSha256 $Package.Sha256)) {
        Write-Log '  拒绝执行：DirectX 完整包未通过签名/哈希复验' -Level ERROR
        return $false
    }

    $extractDir = Join-Path $CacheDir (
        'directx-extract-{0}-{1}' -f $PID, [guid]::NewGuid().ToString('N')
    )
    try {
        [void][IO.Directory]::CreateDirectory($extractDir)
        $extractItem = Get-Item -LiteralPath $extractDir -Force
        if (($extractItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "DirectX 解包目录不能是重解析点: $extractDir"
        }

        $extractArgs = '/Q /T:"{0}"' -f $extractDir
        Write-Log "  解包: $ExePath $extractArgs"
        $extractProc = Start-Process -FilePath $ExePath `
            -ArgumentList $extractArgs -Wait -PassThru -NoNewWindow
        if ($extractProc.ExitCode -ne 0) {
            $text = Get-NativeExitCodeText -Code $extractProc.ExitCode
            Write-Log "  DirectX 完整包解包失败: $text" -Level ERROR
            return $false
        }

        foreach ($leaf in 'DXSETUP.exe','dsetup.dll','dsetup32.dll','dxupdate.cab') {
            $path = Join-Path $extractDir $leaf
            if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
                ((Get-Item -LiteralPath $path -Force).Attributes -band
                    [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "DirectX 完整包缺少安全的 $leaf"
            }
        }

        $setup = Join-Path $extractDir 'DXSETUP.exe'
        if (-not (Test-MicrosoftInstaller -Path $setup `
                    -ExpectedOriginalFileName 'dxsetup.exe')) {
            throw 'DXSETUP.exe 未通过 Microsoft 签名与原始文件名校验'
        }
        Write-Log "  运行: $setup /silent"
        $setupProc = Start-Process -FilePath $setup -ArgumentList '/silent' `
            -WorkingDirectory $extractDir -Wait -PassThru -NoNewWindow
        $code = $setupProc.ExitCode
        $text = Get-DirectXExitCodeText -Code $code
        if ($code -eq 0 -or $code -eq 1) {
            if ($code -eq 1) {
                $script:RestartRequired = $true
                $script:RestartRequiredPackages += $Package.Id
            }
            Write-Log "  退出码 $text (OK)" -Level OK
            return $true
        }
        Write-Log "  退出码 $text (失败)" -Level ERROR
        Write-DirectXNativeLogs -Paths $Package.NativeLogs
        return $false
    } catch {
        Write-Log "  DirectX 安装异常: $($_.Exception.Message)" -Level ERROR
        Write-DirectXNativeLogs -Paths $Package.NativeLogs
        return $false
    } finally {
        try {
            Remove-DirectXExtractDirectory -ExtractDir $extractDir `
                -CacheDir $CacheDir
        } catch {
            Write-Log "  DirectX 临时目录清理失败: $($_.Exception.Message)" -Level WARN
        }
    }
}
