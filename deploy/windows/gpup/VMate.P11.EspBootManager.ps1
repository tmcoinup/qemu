#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-VMateP11Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    finally { $identity.Dispose() }
}

function Get-VMateP11FreeEspDrive {
    foreach ($letter in @('Z', 'Y', 'X', 'W', 'V', 'U', 'T', 'S')) {
        $drive = "$letter`:"
        if ($null -eq (Get-PSDrive -Name $letter `
                    -ErrorAction SilentlyContinue) -and
            -not (Test-Path -LiteralPath ("{0}\" -f $drive))) {
            return $drive
        }
    }
    throw '找不到可安全用于检查 Windows ESP 的空闲盘符。'
}

function Mount-VMateP11SystemEsp {
    if (-not (Test-VMateP11Administrator)) {
        throw '检查 Windows ESP 启动管理器需要管理员权限。'
    }
    $drive = Get-VMateP11FreeEspDrive
    $output = @(& "$env:SystemRoot\System32\mountvol.exe" $drive /S 2>&1 |
        ForEach-Object { $_.ToString() })
    if ($LASTEXITCODE -ne 0) {
        throw "挂载 Windows ESP 失败：$($output -join ' ')"
    }
    return $drive
}

function Dismount-VMateP11SystemEsp {
    param([Parameter(Mandatory = $true)][string]$Drive)

    $output = @(& "$env:SystemRoot\System32\mountvol.exe" $Drive /D 2>&1 |
        ForEach-Object { $_.ToString() })
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "卸载 Windows ESP 失败：$($output -join ' ')"
    }
}

function Get-VMateP11BootFileRecord {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        return [pscustomobject][ordered]@{
            Path = $fullPath
            Present = $false
            Sha256 = ''
            SignatureStatus = 'Missing'
            Signer = ''
            MicrosoftSigned = $false
        }
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $fullPath
    $signer = if ($null -eq $signature.SignerCertificate) { '' } else {
        [string]$signature.SignerCertificate.Subject
    }
    return [pscustomobject][ordered]@{
        Path = $fullPath
        Present = $true
        Sha256 = (Get-FileHash -LiteralPath $fullPath `
            -Algorithm SHA256).Hash
        SignatureStatus = [string]$signature.Status
        Signer = $signer
        MicrosoftSigned = [string]$signature.Status -ceq 'Valid' -and
            $signer -match '(?i)(Microsoft Windows|Microsoft Corporation)'
    }
}

function Get-VMateP11EspRecoveryCandidates {
    param(
        [Parameter(Mandatory = $true)][string]$Drive,
        [Parameter(Mandatory = $true)][string]$BootDirectory
    )

    $paths = @(
        (Join-Path $BootDirectory 'bootmgfw.efi.backup'),
        (Join-Path $env:SystemRoot 'Boot\EFI\bootmgfw.efi'),
        (Join-Path $Drive 'EFI\Boot\bootx64.efi')
    )
    return @($paths | Select-Object -Unique | ForEach-Object {
            Get-VMateP11BootFileRecord -Path $_
        } | Where-Object { $_.MicrosoftSigned })
}

function Get-VMateP11EspBootManagerStatus {
    [CmdletBinding()]
    param()

    $drive = ''
    try {
        $drive = Mount-VMateP11SystemEsp
        $bootDirectory = Join-Path $drive 'EFI\Microsoft\Boot'
        $active = Get-VMateP11BootFileRecord -Path (
            Join-Path $bootDirectory 'bootmgfw.efi')
        $candidates = @(Get-VMateP11EspRecoveryCandidates `
            -Drive $drive -BootDirectory $bootDirectory)
        return [pscustomobject][ordered]@{
            Readable = $true
            Trusted = [bool]$active.MicrosoftSigned
            Active = $active
            RecoveryCandidate = if ($candidates.Count -gt 0) {
                $candidates[0]
            }
            else { $null }
            Error = ''
        }
    }
    catch {
        return [pscustomobject][ordered]@{
            Readable = $false
            Trusted = $false
            Active = $null
            RecoveryCandidate = $null
            Error = $_.Exception.Message
        }
    }
    finally {
        if (-not [String]::IsNullOrWhiteSpace($drive)) {
            Dismount-VMateP11SystemEsp -Drive $drive
        }
    }
}

function Repair-VMateP11EspBootManager {
    [CmdletBinding()]
    param()

    if (-not (Test-VMateP11Administrator)) {
        throw '恢复 Windows ESP 启动管理器需要管理员权限。'
    }
    if (Get-Module -ListAvailable -Name Hyper-V) {
        Import-Module Hyper-V -ErrorAction Stop
        $running = @(Get-VM -ErrorAction Stop | Where-Object {
                [string]$_.State -cne 'Off'
            })
        if ($running.Count -gt 0) {
            throw ('恢复 Windows 启动管理器前所有 Hyper-V VM 必须为 Off：' +
                (($running | ForEach-Object Name) -join ', '))
        }
    }
    $drive = ''
    $stage = ''
    try {
        $drive = Mount-VMateP11SystemEsp
        $bootDirectory = Join-Path $drive 'EFI\Microsoft\Boot'
        $activePath = Join-Path $bootDirectory 'bootmgfw.efi'
        $active = Get-VMateP11BootFileRecord -Path $activePath
        if ($active.MicrosoftSigned) {
            return [pscustomobject][ordered]@{
                Changed = $false
                ActiveBefore = $active
                ActiveAfter = $active
                BackupPath = ''
            }
        }
        if (-not $active.Present) {
            throw "ESP Windows 启动管理器不存在：$activePath"
        }
        $candidates = @(Get-VMateP11EspRecoveryCandidates `
            -Drive $drive -BootDirectory $bootDirectory)
        if ($candidates.Count -eq 0) {
            throw '未找到 Microsoft 签名有效的 Windows 启动管理器恢复源。'
        }
        $source = $candidates[0]
        $backupName = 'bootmgfw.efi.vmate-untrusted-' +
            $active.Sha256.Substring(0, 16) + '.backup'
        $backupPath = Join-Path $bootDirectory $backupName
        if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
            if ((Get-FileHash -LiteralPath $backupPath `
                        -Algorithm SHA256).Hash -cne $active.Sha256) {
                throw "已有 ESP 外部加载器备份哈希漂移：$backupPath"
            }
        }
        else {
            Copy-Item -LiteralPath $activePath -Destination $backupPath
            if ((Get-FileHash -LiteralPath $backupPath `
                        -Algorithm SHA256).Hash -cne $active.Sha256) {
                throw '创建 ESP 外部加载器回滚副本后校验失败。'
            }
        }
        $stage = Join-Path $bootDirectory (
            'bootmgfw.efi.vmate-stage-' + [Guid]::NewGuid().ToString('N'))
        Copy-Item -LiteralPath $source.Path -Destination $stage
        $staged = Get-VMateP11BootFileRecord -Path $stage
        if (-not $staged.MicrosoftSigned -or
            $staged.Sha256 -cne $source.Sha256) {
            throw 'Windows 启动管理器 staging 哈希/签名复检失败。'
        }
        Copy-Item -LiteralPath $stage -Destination $activePath -Force
        $after = Get-VMateP11BootFileRecord -Path $activePath
        if (-not $after.MicrosoftSigned -or
            $after.Sha256 -cne $source.Sha256) {
            throw '写入 ESP 后 Windows 启动管理器哈希/签名复检失败。'
        }
        return [pscustomobject][ordered]@{
            Changed = $true
            ActiveBefore = $active
            ActiveAfter = $after
            BackupPath = $backupPath
        }
    }
    finally {
        if (-not [String]::IsNullOrWhiteSpace($stage) -and
            (Test-Path -LiteralPath $stage -PathType Leaf)) {
            Remove-Item -LiteralPath $stage -Force
        }
        if (-not [String]::IsNullOrWhiteSpace($drive)) {
            Dismount-VMateP11SystemEsp -Drive $drive
        }
    }
}
