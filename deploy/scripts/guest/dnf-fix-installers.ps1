# dnf-fix-installers.ps1 —— Microsoft 安装包下载、身份校验与通用执行逻辑

# 只信任有效且签发给 Microsoft Corporation 的 PE 安装器。
# 普通 VC++ 包使用 PE OriginalFilename 限定身份；DirectX 通用
# WEXTRACT 外壳改用固定 SHA-256，两种条件可以同时使用。
function Test-MicrosoftInstaller {
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowEmptyString()][string]$ExpectedOriginalFileName = '',
        [AllowEmptyString()][string]$ExpectedSha256 = ''
    )

    try {
        if ([string]::IsNullOrWhiteSpace($ExpectedOriginalFileName) -and
            [string]::IsNullOrWhiteSpace($ExpectedSha256)) {
            return $false
        }
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($item.PSIsContainer -or
            (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
            $item.Length -le 100KB) {
            return $false
        }

        $signature = Get-AuthenticodeSignature -FilePath $item.FullName
        if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or
            $null -eq $signature.SignerCertificate) {
            return $false
        }
        $signer = $signature.SignerCertificate.GetNameInfo(
            [Security.Cryptography.X509Certificates.X509NameType]::SimpleName,
            $false
        )
        if ($signer -ne 'Microsoft Corporation') { return $false }
        if (-not [string]::IsNullOrWhiteSpace($ExpectedOriginalFileName) -and
            $item.VersionInfo.OriginalFilename -ine $ExpectedOriginalFileName) {
            return $false
        }
        if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256) -and
            (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash `
                -ine $ExpectedSha256) {
            return $false
        }
        return $true
    } catch {
        return $false
    }
}

# 下载到同目录的唯一临时文件，校验后再原子发布到缓存。
function Get-Installer {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination,
        [AllowEmptyString()][string]$ExpectedOriginalFileName = '',
        [AllowEmptyString()][string]$ExpectedSha256 = ''
    )

    if (Test-Path -LiteralPath $Destination) {
        $size = (Get-Item -LiteralPath $Destination -Force).Length
        if (Test-MicrosoftInstaller -Path $Destination `
                -ExpectedOriginalFileName $ExpectedOriginalFileName `
                -ExpectedSha256 $ExpectedSha256) {
            Write-Log "  缓存命中: $Destination ($([math]::Round($size/1MB,1)) MB)"
            return
        }
        Write-Log '  缓存文件未通过 Microsoft 身份校验，重新下载' -Level WARN
        Remove-Item -LiteralPath $Destination -Force
    }

    $partial = "$Destination.partial-$PID-$([guid]::NewGuid().ToString('N'))"
    try {
        Write-Log "  下载: $Url"
        Invoke-WebRequest -Uri $Url -OutFile $partial -UseBasicParsing -TimeoutSec 600
        if (-not (Test-MicrosoftInstaller -Path $partial `
                    -ExpectedOriginalFileName $ExpectedOriginalFileName `
                    -ExpectedSha256 $ExpectedSha256)) {
            throw '下载文件未通过 Microsoft 签名与身份校验'
        }
        $size = (Get-Item -LiteralPath $partial -Force).Length
        Move-Item -LiteralPath $partial -Destination $Destination -Force
        Write-Log "  完成并验签: $([math]::Round($size/1MB,1)) MB"
    } finally {
        if (Test-Path -LiteralPath $partial) {
            Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        }
    }
}

# VC++ 安装器的通用退出码处理；DirectSetup 在专用模块处理。
function Invoke-Installer {
    param(
        [Parameter(Mandatory)][string]$ExePath,
        [Parameter(Mandatory)][string]$Arguments,
        [Parameter(Mandatory)][string]$ExpectedOriginalFileName,
        [Parameter(Mandatory)][string]$PackageId
    )

    # 执行前再次验签，防止缓存文件在下载与启动之间被替换。
    if (-not (Test-MicrosoftInstaller -Path $ExePath `
                -ExpectedOriginalFileName $ExpectedOriginalFileName)) {
        Write-Log '  拒绝执行：安装器没有有效的 Microsoft 签名' -Level ERROR
        return $false
    }

    Write-Log "  运行: $ExePath $Arguments"
    $proc = Start-Process -FilePath $ExePath -ArgumentList $Arguments `
        -Wait -PassThru -NoNewWindow
    $code = $proc.ExitCode
    # 1638 表示系统已有另一版本。它本身不是安装成功，但主流程会无条件复检
    # DLL、架构和版本；这里只把对应包标为“仅凭复检裁决”，不提前制造假失败。
    if ($code -eq 1638) {
        $script:RecheckOnlyPackages += $PackageId
        Write-Log '  退出码 1638（已有另一版本，等待安装后复检）' -Level WARN
        return $true
    }
    # 0=成功；1641=安装成功且已启动重启；3010=成功但需要稍后重启。
    if ($code -in 0, 1641, 3010) {
        if ($code -in 1641, 3010) {
            $script:RestartRequired = $true
            $script:RestartRequiredPackages += $PackageId
        }
        Write-Log "  退出码 $code (OK)" -Level OK
        return $true
    }
    Write-Log "  退出码 $code (失败)" -Level ERROR
    return $false
}
