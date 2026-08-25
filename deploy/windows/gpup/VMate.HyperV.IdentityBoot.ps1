#Requires -Version 5.1

<#
.SYNOPSIS
    生成、安装和回滚 P-11 的来宾启动期 SMBIOS 身份扩展。

.DESCRIPTION
    扩展只在 Generation 2 VM 关机时写入系统 VHD 的 EFI 分区。原微软启动管理器
    以 SHA-256 校验的文件级备份保留；GPU-P VM 不支持 checkpoint 时仍可离线回滚。
    本模块不宣称修改直接 CPUID、GPU PnP 路径或 Hyper-V 固有设备。
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'VMate.HyperV.IdentityBoot.Support.ps1')

function Install-VMateHyperVIdentityBoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$VM,
        [Parameter(Mandatory = $true)][object]$Profile,
        [Parameter(Mandatory = $true)][object]$HardwareIdentity,
        [string]$ExtensionPath = (Join-Path $PSScriptRoot `
            'firmware\bin\VMateIdentityBoot.efi'),
        [switch]$AllowDisableSecureBoot,
        [switch]$AllowProfileReplacement
    )

    Assert-VMateHyperVIdentityBootVm $VM
    if (-not (Test-Path -LiteralPath $ExtensionPath -PathType Leaf)) {
        throw "VMate identity EFI 不存在：$ExtensionPath"
    }
    $requestedConfig = New-VMateHyperVIdentityBootConfig `
        -VMId ([Guid]$VM.Id) -Profile $Profile `
        -HardwareIdentity $HardwareIdentity
    $profileId = Get-VMateHyperVIdentityBootProfileId $Profile
    $extensionHash = (Get-FileHash -LiteralPath $ExtensionPath `
        -Algorithm SHA256).Hash
    $firmware = Get-VMFirmware -VM $VM -ErrorAction Stop
    $secureBootWasEnabled = [string]$firmware.SecureBoot -ceq 'On'
    if ($secureBootWasEnabled -and -not $AllowDisableSecureBoot) {
        throw '扩展未受 Microsoft 签名；需显式传入 -AllowDisableSecureBoot。'
    }
    if ($secureBootWasEnabled) {
        Set-VMFirmware -VM $VM -EnableSecureBoot Off -ErrorAction Stop
    }
    $installed = $false
    try {
        $result = Invoke-VMateHyperVIdentityBootEsp $VM {
            param($EfiRoot)

            $boot = Join-Path $EfiRoot $script:VMateIdentityBootRelativePath
            $stock = Join-Path $EfiRoot `
                $script:VMateIdentityBootStockRelativePath
            $configPath = Join-Path $EfiRoot `
                $script:VMateIdentityBootConfigRelativePath
            $manifestPath = Join-Path $EfiRoot `
                $script:VMateIdentityBootManifestRelativePath
            if (-not (Test-Path -LiteralPath $boot -PathType Leaf)) {
                throw 'EFI Windows boot manager 不存在。'
            }
            $manifest = $null
            $manifestState = ''
            $isProfileReplacement = $false
            $servicingStockRefresh = $false
            $previousProfileId = ''
            if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
                $manifest = Get-Content -LiteralPath $manifestPath `
                    -Raw -Encoding UTF8 | ConvertFrom-Json
                if ([Guid]$manifest.VMId -ne [Guid]$VM.Id) {
                    throw 'identity manifest 的 VMId 不匹配。'
                }
                $manifestState = [string](
                    Get-VMateHyperVIdentityBootOptionalProperty `
                        $manifest 'State' 'Installed')
                if ($manifestState -notin @('Installed', 'Uninstalled')) {
                    throw "identity manifest 状态无效：$manifestState"
                }
            }
            $currentBootHash = (Get-FileHash -LiteralPath $boot `
                -Algorithm SHA256).Hash
            $createdStock = $false
            if ($null -eq $manifest) {
                if (Test-Path -LiteralPath $stock) {
                    throw '存在无 manifest 的 stock backup；拒绝覆盖。'
                }
                $signature = Get-AuthenticodeSignature -LiteralPath $boot
                if ($signature.Status -ne 'Valid' -or
                    [string]$signature.SignerCertificate.Subject -notmatch
                        'Microsoft') {
                    throw '首次安装要求当前 boot manager 为 Microsoft 有效签名。'
                }
                $stockHash = $currentBootHash
                Copy-Item -LiteralPath $boot -Destination $stock -ErrorAction Stop
                if ((Get-FileHash -LiteralPath $stock -Algorithm SHA256).Hash `
                        -cne $stockHash) {
                    Remove-Item -LiteralPath $stock -Force `
                        -ErrorAction SilentlyContinue
                    throw 'stock backup 写入后哈希不一致。'
                }
                $createdStock = $true
                $originalSecureBoot = $secureBootWasEnabled
            }
            else {
                $stockHash = [string]$manifest.StockSha256
                if (-not (Test-Path -LiteralPath $stock -PathType Leaf) -or
                    (Get-FileHash -LiteralPath $stock -Algorithm SHA256).Hash `
                        -cne $stockHash) {
                    throw 'stock backup 与 identity manifest 不一致。'
                }
                $boundProfileId = [string](
                    Get-VMateHyperVIdentityBootOptionalProperty `
                        $manifest 'ProfileId' '')
                if (-not [String]::IsNullOrWhiteSpace($boundProfileId) -and
                    $boundProfileId -cne $profileId) {
                    if (-not $AllowProfileReplacement) {
                        throw 'VM 已绑定不同 identity boot profile；拒绝重新抽取。'
                    }
                    $isProfileReplacement = $true
                    $previousProfileId = $boundProfileId
                }
                if ($manifestState -ceq 'Installed') {
                    $oldExtensionHash = [string](
                        Get-VMateHyperVIdentityBootProperty `
                            $manifest 'ExtensionSha256' 'identity manifest')
                    if ($currentBootHash -cne $oldExtensionHash) {
                        $currentSignature = Get-AuthenticodeSignature `
                            -LiteralPath $boot
                        if ($currentSignature.Status -ne 'Valid' -or
                            [string]$currentSignature.SignerCertificate.Subject `
                                -notmatch 'Microsoft') {
                            throw '当前 boot manager 不是已拥有扩展或 Microsoft 有效签名文件；拒绝覆盖。'
                        }
                        $servicingStockRefresh = $true
                        $stockHash = $currentBootHash
                    }
                    $originalSecureBoot = [bool](
                        Get-VMateHyperVIdentityBootOptionalProperty `
                            $manifest 'SecureBootWasEnabled' $false)
                }
                else {
                    if ($currentBootHash -cne $stockHash) {
                        throw '已卸载状态的 boot manager 不是已验证 stock 文件。'
                    }
                    $originalSecureBoot = $secureBootWasEnabled
                }
            }
            $effectiveConfig = $requestedConfig
            if ($null -ne $manifest) {
                $effectiveConfig = Import-VMateHyperVIdentityBootConfig `
                    -Path $configPath -ExpectedConfig $requestedConfig `
                    -AllowProfileReplacement:$isProfileReplacement
                $ownedConfigHash = [string](
                    Get-VMateHyperVIdentityBootOptionalProperty `
                        $manifest 'ConfigSha256' '')
                if (-not [String]::IsNullOrWhiteSpace($ownedConfigHash) -and
                    $ownedConfigHash -cne $effectiveConfig.SourceSha256) {
                    throw 'identity.ini 与 manifest 的已拥有哈希不一致。'
                }
            }
            try {
                $stockSignature = Get-AuthenticodeSignature -LiteralPath $stock
                if ($stockSignature.Status -ne 'Valid' -or
                    [string]$stockSignature.SignerCertificate.Subject -notmatch
                        'Microsoft') {
                    throw 'stock backup 不是 Microsoft 有效签名。'
                }
                $vmateRoot = Split-Path -Parent $configPath
                [void](New-Item -ItemType Directory -Path $vmateRoot -Force)
                $previousBoot = Join-Path $vmateRoot `
                    'bootmgfw.vmate-previous.efi'
                $previousConfig = Join-Path $vmateRoot `
                    'identity.vmate-previous.ini'
                $previousManifest = Join-Path $vmateRoot `
                    'identity-manifest.vmate-previous.json'
                $previousStock = Join-Path $vmateRoot `
                    'bootmgfw.vmate-stock-previous.efi'
                $hadConfig = Test-Path -LiteralPath $configPath -PathType Leaf
                $hadManifest = $null -ne $manifest
                Copy-Item -LiteralPath $boot -Destination $previousBoot -Force
                if ($servicingStockRefresh) {
                    Copy-Item -LiteralPath $stock -Destination $previousStock -Force
                }
                if ($hadConfig) {
                    Copy-Item -LiteralPath $configPath `
                        -Destination $previousConfig -Force
                }
                if ($hadManifest) {
                    Copy-Item -LiteralPath $manifestPath `
                        -Destination $previousManifest -Force
                }
                try {
                    if ($servicingStockRefresh) {
                        Copy-Item -LiteralPath $boot -Destination $stock -Force
                        if ((Get-FileHash -LiteralPath $stock -Algorithm SHA256).Hash `
                                -cne $stockHash) { throw 'Windows servicing stock 刷新后哈希不一致。' }
                    }
                    [IO.File]::WriteAllText($configPath, $effectiveConfig.Text,
                        (New-Object Text.UTF8Encoding($false)))
                    Copy-Item -LiteralPath $ExtensionPath `
                        -Destination $boot -Force
                    if ((Get-FileHash -LiteralPath $boot `
                                -Algorithm SHA256).Hash -cne $extensionHash -or
                        (Get-FileHash -LiteralPath $configPath `
                                -Algorithm SHA256).Hash -cne `
                                    $effectiveConfig.Sha256) {
                        throw 'identity boot 文件写入后哈希不一致。'
                    }
                    $newManifest = [pscustomobject][ordered]@{
                        SchemaVersion = 1
                        State = 'Installed'
                        VMId = ([Guid]$VM.Id).ToString('D')
                        StockPath = `
                            '\EFI\Microsoft\Boot\bootmgfw.vmate-stock.efi'
                        StockSha256 = $stockHash
                        ExtensionSha256 = $extensionHash
                        ConfigSha256 = $effectiveConfig.Sha256
                        ProfileId = $profileId
                        PreviousProfileId = $previousProfileId
                        SecureBootWasEnabled = [bool]$originalSecureBoot
                        RollbackPolicy = 'verified-file-backup-no-checkpoint'
                        InstalledAtUtc = [DateTime]::UtcNow.ToString('o')
                    }
                    [IO.File]::WriteAllText($manifestPath,
                        ($newManifest | ConvertTo-Json -Depth 5),
                        (New-Object Text.UTF8Encoding($false)))
                    $verifiedManifest = Get-Content -LiteralPath $manifestPath `
                        -Raw -Encoding UTF8 | ConvertFrom-Json
                    if ([string]$verifiedManifest.State -cne 'Installed' -or
                        [string]$verifiedManifest.ExtensionSha256 -cne `
                            $extensionHash -or
                        [string]$verifiedManifest.ConfigSha256 -cne `
                            $effectiveConfig.Sha256) {
                        throw 'identity manifest 写入后回读不一致。'
                    }
                }
                catch {
                    Copy-Item -LiteralPath $previousBoot `
                        -Destination $boot -Force
                    if ($servicingStockRefresh) {
                        Copy-Item -LiteralPath $previousStock -Destination $stock -Force
                    }
                    if ($hadConfig) {
                        Copy-Item -LiteralPath $previousConfig `
                            -Destination $configPath -Force
                    }
                    else {
                        Remove-Item -LiteralPath $configPath -Force `
                            -ErrorAction SilentlyContinue
                    }
                    if ($hadManifest) {
                        Copy-Item -LiteralPath $previousManifest `
                            -Destination $manifestPath -Force
                    }
                    else {
                        Remove-Item -LiteralPath $manifestPath -Force `
                            -ErrorAction SilentlyContinue
                    }
                    throw
                }
                finally {
                    foreach ($temporaryPath in @($previousBoot,
                            $previousConfig, $previousManifest, $previousStock)) {
                        Remove-Item -LiteralPath $temporaryPath -Force `
                            -ErrorAction SilentlyContinue
                    }
                }
            }
            catch {
                if ($createdStock) {
                    Remove-Item -LiteralPath $stock -Force `
                        -ErrorAction SilentlyContinue
                }
                throw
            }
            return [pscustomobject][ordered]@{
                Status = if ($null -eq $manifest) { 'Installed' }
                    elseif ($manifestState -ceq 'Uninstalled') { 'Reinstalled' }
                    elseif ($servicingStockRefresh) { 'ServicingReinstalled' }
                    elseif ($isProfileReplacement) { 'Reprofiled' }
                    else { 'Updated' }
                VMId = ([Guid]$VM.Id).ToString('D')
                ProfileId = $profileId
                ExtensionSha256 = $extensionHash
                ConfigSha256 = $effectiveConfig.Sha256
                StockSha256 = $stockHash
                SecureBoot = 'Off'
                RollbackPolicy = 'verified-file-backup-no-checkpoint'
                Capability = 'guest-boot-smbios-only'
            }
        }
        $installed = $true
        return $result
    }
    finally {
        if ($secureBootWasEnabled -and -not $installed) {
            Set-VMFirmware -VM $VM -EnableSecureBoot On `
                -ErrorAction SilentlyContinue
        }
    }
}

function Uninstall-VMateHyperVIdentityBoot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$VM)

    Assert-VMateHyperVIdentityBootVm $VM
    $result = Invoke-VMateHyperVIdentityBootEsp $VM {
        param($EfiRoot)

        $boot = Join-Path $EfiRoot $script:VMateIdentityBootRelativePath
        $stock = Join-Path $EfiRoot $script:VMateIdentityBootStockRelativePath
        $manifestPath = Join-Path $EfiRoot `
            $script:VMateIdentityBootManifestRelativePath
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            throw 'identity manifest 不存在；拒绝猜测回滚。'
        }
        $manifest = Get-Content -LiteralPath $manifestPath -Raw `
            -Encoding UTF8 | ConvertFrom-Json
        if ([Guid]$manifest.VMId -ne [Guid]$VM.Id -or
            -not (Test-Path -LiteralPath $stock -PathType Leaf) -or
            (Get-FileHash -LiteralPath $stock -Algorithm SHA256).Hash -cne
                [string]$manifest.StockSha256) {
            throw 'identity manifest/stock backup 校验失败。'
        }
        $manifestState = [string](
            Get-VMateHyperVIdentityBootOptionalProperty `
                $manifest 'State' 'Installed')
        if ($manifestState -notin @('Installed', 'Uninstalled')) {
            throw "identity manifest 状态无效：$manifestState"
        }
        $signature = Get-AuthenticodeSignature -LiteralPath $stock
        if ($signature.Status -ne 'Valid' -or
            [string]$signature.SignerCertificate.Subject -notmatch 'Microsoft') {
            throw '拒绝回滚到非 Microsoft 签名的 stock backup。'
        }
        $currentBootHash = (Get-FileHash -LiteralPath $boot `
            -Algorithm SHA256).Hash
        $restoreSecureBoot = [bool](
            Get-VMateHyperVIdentityBootOptionalProperty `
                $manifest 'SecureBootWasEnabled' $false)
        if ($manifestState -ceq 'Uninstalled') {
            if ($currentBootHash -cne [string]$manifest.StockSha256) {
                throw '已卸载状态的 boot manager 发生漂移。'
            }
            return [pscustomobject][ordered]@{
                Status = 'AlreadyUninstalled'
                VMId = ([Guid]$VM.Id).ToString('D')
                RestoredSha256 = [string]$manifest.StockSha256
                RestoreSecureBoot = $restoreSecureBoot
            }
        }
        if ($currentBootHash -cne [string]$manifest.ExtensionSha256) {
            throw '当前 boot manager 与 manifest 扩展哈希不一致；拒绝回滚。'
        }
        $vmateRoot = Split-Path -Parent $manifestPath
        $previousBoot = Join-Path $vmateRoot `
            'bootmgfw.vmate-uninstall-previous.efi'
        $previousManifest = Join-Path $vmateRoot `
            'identity-manifest.vmate-uninstall-previous.json'
        Copy-Item -LiteralPath $boot -Destination $previousBoot -Force
        Copy-Item -LiteralPath $manifestPath `
            -Destination $previousManifest -Force
        try {
            Copy-Item -LiteralPath $stock -Destination $boot -Force
            if ((Get-FileHash -LiteralPath $boot -Algorithm SHA256).Hash -cne
                [string]$manifest.StockSha256) {
                throw 'stock boot manager 回写后哈希不一致。'
            }
            $manifest | Add-Member -NotePropertyName State `
                -NotePropertyValue 'Uninstalled' -Force
            $manifest | Add-Member -NotePropertyName UninstalledAtUtc `
                -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
            [IO.File]::WriteAllText($manifestPath,
                ($manifest | ConvertTo-Json -Depth 5),
                (New-Object Text.UTF8Encoding($false)))
            $verifiedManifest = Get-Content -LiteralPath $manifestPath `
                -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string]$verifiedManifest.State -cne 'Uninstalled') {
                throw '卸载 manifest 写入后回读不一致。'
            }
        }
        catch {
            Copy-Item -LiteralPath $previousBoot -Destination $boot -Force
            Copy-Item -LiteralPath $previousManifest `
                -Destination $manifestPath -Force
            throw
        }
        finally {
            Remove-Item -LiteralPath $previousBoot -Force `
                -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $previousManifest -Force `
                -ErrorAction SilentlyContinue
        }
        return [pscustomobject][ordered]@{
            Status = 'Uninstalled'
            VMId = ([Guid]$VM.Id).ToString('D')
            RestoredSha256 = [string]$manifest.StockSha256
            RestoreSecureBoot = $restoreSecureBoot
        }
    }
    if ([bool]$result.RestoreSecureBoot) {
        Set-VMFirmware -VM $VM -EnableSecureBoot On -ErrorAction Stop
    }
    return $result
}

function Get-VMateHyperVIdentityBootStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$VM)

    Assert-VMateHyperVIdentityBootVm $VM
    $secureBoot = [string](Get-VMFirmware -VM $VM -ErrorAction Stop).SecureBoot
    return Invoke-VMateHyperVIdentityBootEsp $VM {
        param($EfiRoot)

        $boot = Join-Path $EfiRoot $script:VMateIdentityBootRelativePath
        $stock = Join-Path $EfiRoot $script:VMateIdentityBootStockRelativePath
        $configPath = Join-Path $EfiRoot `
            $script:VMateIdentityBootConfigRelativePath
        $manifestPath = Join-Path $EfiRoot `
            $script:VMateIdentityBootManifestRelativePath
        if (-not (Test-Path -LiteralPath $boot -PathType Leaf)) {
            throw 'EFI Windows boot manager 不存在。'
        }
        $currentHash = (Get-FileHash -LiteralPath $boot `
            -Algorithm SHA256).Hash
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            $stockExists = Test-Path -LiteralPath $stock -PathType Leaf
            return [pscustomobject][ordered]@{
                State = if ($stockExists) { 'Drift' } else { 'Absent' }
                VMId = ([Guid]$VM.Id).ToString('D')
                Integrity = -not $stockExists
                CurrentBootSha256 = $currentHash
                SecureBoot = $secureBoot
                Capability = 'guest-boot-smbios-only'
            }
        }
        $manifest = Get-Content -LiteralPath $manifestPath -Raw `
            -Encoding UTF8 | ConvertFrom-Json
        if ([Guid]$manifest.VMId -ne [Guid]$VM.Id) {
            throw 'identity manifest 的 VMId 不匹配。'
        }
        $state = [string](Get-VMateHyperVIdentityBootOptionalProperty `
                $manifest 'State' 'Installed')
        $knownState = $state -in @('Installed', 'Uninstalled')
        $stockExists = Test-Path -LiteralPath $stock -PathType Leaf
        $stockHash = if ($stockExists) {
            (Get-FileHash -LiteralPath $stock -Algorithm SHA256).Hash
        } else { '' }
        $stockSignatureValid = $false
        if ($stockExists) {
            $signature = Get-AuthenticodeSignature -LiteralPath $stock
            $stockSignatureValid = $signature.Status -eq 'Valid' -and
                [string]$signature.SignerCertificate.Subject -match 'Microsoft'
        }
        $expectedBootHash = if ($state -ceq 'Installed') {
            [string](Get-VMateHyperVIdentityBootOptionalProperty `
                $manifest 'ExtensionSha256' '')
        } elseif ($state -ceq 'Uninstalled') {
            [string]$manifest.StockSha256
        } else { '' }
        $expectedConfigHash = [string](
            Get-VMateHyperVIdentityBootOptionalProperty `
                $manifest 'ConfigSha256' '')
        $configExists = Test-Path -LiteralPath $configPath -PathType Leaf
        $configVerified = if ([String]::IsNullOrWhiteSpace(
                $expectedConfigHash)) {
            $null
        } else {
            $configExists -and
                (Get-FileHash -LiteralPath $configPath `
                    -Algorithm SHA256).Hash -ceq $expectedConfigHash
        }
        $integrity = $knownState -and $stockExists -and
            $stockHash -ceq [string]$manifest.StockSha256 -and
            $stockSignatureValid -and $currentHash -ceq $expectedBootHash -and
            ($null -eq $configVerified -or [bool]$configVerified)
        return [pscustomobject][ordered]@{
            State = if ($integrity) { $state } else { 'Drift' }
            ManifestState = $state
            VMId = ([Guid]$VM.Id).ToString('D')
            ProfileId = [string](Get-VMateHyperVIdentityBootOptionalProperty `
                $manifest 'ProfileId' '')
            Integrity = [bool]$integrity
            CurrentBootSha256 = $currentHash
            ExpectedBootSha256 = $expectedBootHash
            StockSha256 = $stockHash
            StockSignatureValid = [bool]$stockSignatureValid
            ConfigSha256 = if ($configExists) {
                (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash
            } else { '' }
            ConfigVerified = $configVerified
            SecureBoot = $secureBoot
            Capability = 'guest-boot-smbios-only'
        }
    } -ReadOnly
}
