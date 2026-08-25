#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    在授权实验宿主上按固定哈希切换现有自定义/微软原版 bootmgfw。

.DESCRIPTION
    本脚本不携带任何 boot payload，只在 ESP 上已有、哈希明确的文件之间切换。
    所有 VM 必须为 Off；原文件会保留独立回滚副本，每次复制后重新校验 SHA-256。
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('MicrosoftStock', 'ExistingLabCustom')]
    [string]$Mode,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$ExpectedCustomSha256,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$ExpectedStockSha256,

    [string]$ResultPath = 'C:\VMateLab\host-boot-mode-switch.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ExpectedCustomSha256 = $ExpectedCustomSha256.ToUpperInvariant()
$ExpectedStockSha256 = $ExpectedStockSha256.ToUpperInvariant()
$running = @(Get-VM | Where-Object State -ne 'Off')
if ($running.Count -ne 0) {
    throw ('切换宿主 boot manager 前所有 VM 必须为 Off：' +
        (($running | ForEach-Object Name) -join ', '))
}
if (Confirm-SecureBootUEFI) {
    throw 'Secure Boot 已启用；拒绝切换实验 boot manager。'
}

$mount = $null
foreach ($letter in @('Z', 'Y', 'X', 'W', 'V', 'U', 'T', 'S')) {
    $candidate = "$letter`:"
    if (-not (Test-Path "$candidate\")) {
        $mount = $candidate
        break
    }
}
if ($null -eq $mount) { throw '找不到空闲 ESP 挂载盘符。' }

$mounted = $false
$stage = ''
try {
    & "$env:SystemRoot\System32\mountvol.exe" $mount /S | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '挂载 ESP 失败。' }
    $mounted = $true

    $bootDir = Join-Path $mount 'EFI\Microsoft\Boot'
    $active = Join-Path $bootDir 'bootmgfw.efi'
    $stock = Join-Path $bootDir 'bootmgfw.efi.backup'
    $custom = Join-Path $bootDir 'bootmgfw.efi.vmate-lab-custom.backup'
    foreach ($path in @($active, $stock)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "ESP 文件不存在：$path"
        }
    }
    $activeBefore = (Get-FileHash $active -Algorithm SHA256).Hash
    $stockHash = (Get-FileHash $stock -Algorithm SHA256).Hash
    $stockSignature = Get-AuthenticodeSignature $stock
    if ($stockHash -cne $ExpectedStockSha256 -or
        [string]$stockSignature.Status -cne 'Valid' -or
        [string]$stockSignature.SignerCertificate.Subject -notmatch
            '(?i)(Microsoft Windows|Microsoft Corporation)') {
        throw 'ESP 上微软原版备份的哈希或签名不匹配。'
    }

    $target = ''
    $targetHash = ''
    if ($Mode -ceq 'MicrosoftStock') {
        if ($activeBefore -cne $ExpectedCustomSha256 -and
            $activeBefore -cne $ExpectedStockSha256) {
            throw '当前 bootmgfw 既不是期望自定义版本，也不是期望微软原版。'
        }
        if ($activeBefore -ceq $ExpectedCustomSha256) {
            if (Test-Path -LiteralPath $custom) {
                if ((Get-FileHash $custom -Algorithm SHA256).Hash -cne
                    $ExpectedCustomSha256) {
                    throw '已有自定义回滚副本哈希不匹配。'
                }
            }
            else {
                Copy-Item -LiteralPath $active -Destination $custom
                if ((Get-FileHash $custom -Algorithm SHA256).Hash -cne
                    $ExpectedCustomSha256) {
                    throw '创建自定义回滚副本后校验失败。'
                }
            }
        }
        $target = $stock
        $targetHash = $ExpectedStockSha256
    }
    else {
        if (-not (Test-Path -LiteralPath $custom -PathType Leaf) -or
            (Get-FileHash $custom -Algorithm SHA256).Hash -cne
                $ExpectedCustomSha256) {
            throw '自定义 bootmgfw 回滚副本不存在或哈希不匹配。'
        }
        if ($activeBefore -cne $ExpectedStockSha256 -and
            $activeBefore -cne $ExpectedCustomSha256) {
            throw '当前 bootmgfw 不属于已固定的两种版本。'
        }
        $target = $custom
        $targetHash = $ExpectedCustomSha256
    }

    $stage = Join-Path $bootDir (
        'bootmgfw.efi.vmate-stage-' + [Guid]::NewGuid().ToString('N'))
    Copy-Item -LiteralPath $target -Destination $stage
    if ((Get-FileHash $stage -Algorithm SHA256).Hash -cne $targetHash) {
        throw 'ESP staging 文件校验失败。'
    }
    Copy-Item -LiteralPath $stage -Destination $active -Force
    $activeAfter = (Get-FileHash $active -Algorithm SHA256).Hash
    if ($activeAfter -cne $targetHash) {
        throw '写入 active bootmgfw 后校验失败。'
    }
    $activeSignature = Get-AuthenticodeSignature $active

    $result = [pscustomobject][ordered]@{
        SchemaVersion = 1
        Mode = $Mode
        ActiveBeforeSha256 = $activeBefore
        ActiveAfterSha256 = $activeAfter
        ActiveSignatureStatus = [string]$activeSignature.Status
        StockSha256 = $stockHash
        CustomBackupPath = 'EFI\Microsoft\Boot\' +
            [IO.Path]::GetFileName($custom)
        CustomBackupSha256 = if (Test-Path $custom) {
            (Get-FileHash $custom -Algorithm SHA256).Hash
        } else { '' }
        AllVMsOff = $true
        RuntimeModelSwitch = 'not-applicable-host-reboot-required'
        RebootRequired = $activeBefore -cne $activeAfter
        ChangedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    $result | ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath $ResultPath -Encoding UTF8
    $result
}
finally {
    if (-not [String]::IsNullOrWhiteSpace($stage) -and
        (Test-Path -LiteralPath $stage)) {
        Remove-Item -LiteralPath $stage -Force
    }
    if ($mounted) {
        & "$env:SystemRoot\System32\mountvol.exe" $mount /D | Out-Null
    }
}
