#Requires -Version 5.1

param(
    [Parameter(Mandatory = $true)][string]$IdentityBootModule,
    [Parameter(Mandatory = $true)][string]$HardwareProfileModule,
    [Parameter(Mandatory = $true)][string]$HardwareCatalog
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param([AllowNull()][object]$Actual, [AllowNull()][object]$Expected,
        [string]$Message)
    if ([string]$Actual -cne [string]$Expected) {
        throw "$Message；actual=$Actual expected=$Expected"
    }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern)
    try { & $Action } catch {
        if ($_.Exception.Message -notmatch $Pattern) {
            throw "错误不可诊断：$($_.Exception.Message)"
        }
        return
    }
    throw "预期失败但成功：$Pattern"
}

function Get-TestHash {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

. $HardwareProfileModule
. $IdentityBootModule

$profiles = @(Get-VMateGpuPHardwareProfiles -CatalogPath $HardwareCatalog)
$customProfiles = @($profiles | Where-Object { $_.Id -cne 'host-native' })
Assert-Equal $profiles.Count 22 '启用的 P-11 profile 数量错误'
Assert-Equal $customProfiles.Count 21 '自定义 P-11 组合数量错误'

$identity = [pscustomobject]@{
    Firmware = [pscustomobject]@{
        BIOSGUID = 'a12f5c6e-7b34-4d91-8a2b-9c7d5e6f1023'
        BIOSSerialNumber = 'BIOS-4E15869D8A7F4E35'
        BaseBoardSerialNumber = 'BOARD-72F84DAE901B42C8'
        ChassisSerialNumber = 'CHASSIS-19C57B2E046F'
        ChassisAssetTag = 'ASSET-8372CB4D905A'
    }
}
$vmId = [Guid]'384f91db-197c-4c64-a9f1-4655037fb955'
$boardProducts = @{}
foreach ($profile in $customProfiles) {
    $config = New-VMateHyperVIdentityBootConfig `
        -VMId $vmId -Profile $profile -HardwareIdentity $identity
    $lines = @($config.Text -split "`r`n" | Where-Object { $_.Length -gt 0 })
    Assert-Equal $config.FieldCount 31 "$($profile.Id) 字段数量错误"
    Assert-Equal $lines.Count 31 "$($profile.Id) 配置行数错误"
    Assert-Equal $config.Fields.CpuVersion $profile.Processor.Name `
        "$($profile.Id) CPU 型号未进入启动配置"
    Assert-Equal $config.Fields.BoardProduct $profile.Platform.product `
        "$($profile.Id) 主板型号未进入启动配置"
    Assert-True ($config.Text -cnotmatch '(?<!\r)\n') `
        "$($profile.Id) 不是严格 CRLF"
    foreach ($line in $lines) {
        Assert-True ($line -cmatch '^[A-Za-z][A-Za-z0-9]*=[\x20-\x7e]+$') `
            "$($profile.Id) 含无效配置行：$line"
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $calculated = ([BitConverter]::ToString($sha.ComputeHash(
                    [Text.Encoding]::UTF8.GetBytes($config.Text)))).Replace('-', '')
    }
    finally { $sha.Dispose() }
    Assert-Equal $config.Sha256 $calculated "$($profile.Id) 配置哈希错误"
    $boardProducts[[string]$profile.Platform.product] = $true
}
Assert-True ($boardProducts.Count -ge 10) '21 套组合的主板池丰富度不足'

$testRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ('vmate-identity-boot-test-' + [Guid]::NewGuid().ToString('N'))
$script:TestEfiRoot = Join-Path $testRoot 'disk\EFI'
$script:TestExtensionPath = Join-Path $testRoot 'VMateIdentityBoot.efi'
$script:SecureBoot = 'On'
$script:RemoveExtensionBeforeAction = $false
$script:LastReadOnly = $false
$script:MicrosoftSignedHashes = @{}
$vm = [pscustomobject]@{
    Id = $vmId
    State = 'Off'
    Generation = 2
}

function Initialize-TestEsp {
    $bootDirectory = Join-Path $script:TestEfiRoot 'Microsoft\Boot'
    [void](New-Item -ItemType Directory -Path $bootDirectory -Force)
    $boot = Join-Path $bootDirectory 'bootmgfw.efi'
    [IO.File]::WriteAllBytes($boot, [byte[]](0..127))
    $script:MicrosoftSignedHashes[(Get-TestHash $boot)] = $true
}

# Replace only the host/ESP boundaries; the full installer state machine and
# all real file/hash/JSON operations remain under test.
function Get-VMFirmware {
    param([object]$VM, [object]$ErrorAction)
    return [pscustomobject]@{ SecureBoot = $script:SecureBoot }
}

function Set-VMFirmware {
    param([object]$VM, [string]$EnableSecureBoot, [object]$ErrorAction)
    $script:SecureBoot = $EnableSecureBoot
}

function Get-AuthenticodeSignature {
    param([string]$LiteralPath)
    $valid = $script:MicrosoftSignedHashes.ContainsKey(
        (Get-TestHash $LiteralPath))
    return [pscustomobject]@{
        Status = if ($valid) { 'Valid' } else { 'NotSigned' }
        SignerCertificate = [pscustomobject]@{
            Subject = if ($valid) {
                'CN=Microsoft Windows Production PCA 2011'
            } else { '' }
        }
    }
}

function Invoke-VMateHyperVIdentityBootEsp {
    param([object]$VM, [scriptblock]$Action, [switch]$ReadOnly)
    $script:LastReadOnly = $ReadOnly.IsPresent
    if ($script:RemoveExtensionBeforeAction) {
        $script:RemoveExtensionBeforeAction = $false
        Remove-Item -LiteralPath $script:TestExtensionPath -Force
    }
    return & $Action $script:TestEfiRoot
}

try {
    Initialize-TestEsp
    [IO.File]::WriteAllBytes($script:TestExtensionPath,
        [byte[]](255..128))
    $boot = Join-Path $script:TestEfiRoot 'Microsoft\Boot\bootmgfw.efi'
    $stock = Join-Path $script:TestEfiRoot `
        'Microsoft\Boot\bootmgfw.vmate-stock.efi'
    $configPath = Join-Path $script:TestEfiRoot 'VMate\identity.ini'
    $manifestPath = Join-Path $script:TestEfiRoot `
        'VMate\identity-manifest.json'
    $originalHash = Get-TestHash $boot
    $extensionHash = Get-TestHash $script:TestExtensionPath
    $boundProfile = ConvertTo-VMateGpuPHardwareProfileBinding `
        $customProfiles[0]

    $first = Install-VMateHyperVIdentityBoot -VM $vm `
        -Profile $boundProfile -HardwareIdentity $identity `
        -ExtensionPath $script:TestExtensionPath -AllowDisableSecureBoot
    Assert-Equal $first.Status 'Installed' '首次安装状态错误'
    Assert-Equal $script:SecureBoot 'Off' '首次安装未显式关闭 Secure Boot'
    Assert-Equal (Get-TestHash $boot) $extensionHash '扩展未写入 boot manager'
    Assert-Equal (Get-TestHash $stock) $originalHash 'stock backup 不一致'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    Assert-Equal $manifest.State 'Installed' '首次 manifest 状态错误'
    Assert-True ([bool]$manifest.SecureBootWasEnabled) `
        '没有保存原始 Secure Boot 意图'

    # Migrate the early experiment format: BOM config plus a manifest without
    # State/ProfileId/ConfigSha256. Values must survive while BOM is removed.
    $legacyConfigText = [IO.File]::ReadAllText($configPath,
        [Text.Encoding]::UTF8)
    $legacySystemSerial = [string](($legacyConfigText -split "`r`n" |
            Where-Object { $_ -like 'SystemSerial=*' }) -replace
        '^SystemSerial=', '')
    $legacyConfigText = $legacyConfigText.Replace("`r`n", "`n")
    $legacyBytes = [Text.Encoding]::UTF8.GetPreamble() +
        [Text.Encoding]::UTF8.GetBytes($legacyConfigText)
    [IO.File]::WriteAllBytes($configPath, $legacyBytes)
    [pscustomobject][ordered]@{
        SchemaVersion = 1
        VMId = $vm.Id.ToString('D')
        StockSha256 = $manifest.StockSha256
        ExtensionSha256 = $manifest.ExtensionSha256
        SecureBootWasEnabled = $true
    } | ConvertTo-Json | Set-Content -LiteralPath $manifestPath -Encoding UTF8

    $updated = Install-VMateHyperVIdentityBoot -VM $vm `
        -Profile $customProfiles[0] -HardwareIdentity $identity `
        -ExtensionPath $script:TestExtensionPath
    Assert-Equal $updated.Status 'Updated' '幂等更新状态错误'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    Assert-True ([bool]$manifest.SecureBootWasEnabled) `
        '更新丢失原始 Secure Boot 意图'
    Assert-Equal $manifest.ProfileId $customProfiles[0].Id 'profile 更新未持久化'
    $migratedBytes = [IO.File]::ReadAllBytes($configPath)
    Assert-True (-not ($migratedBytes.Length -ge 3 -and
            $migratedBytes[0] -eq 0xef -and $migratedBytes[1] -eq 0xbb -and
            $migratedBytes[2] -eq 0xbf)) '旧版配置 BOM 未规范化'
    $migratedConfigText = [IO.File]::ReadAllText($configPath,
        [Text.Encoding]::UTF8)
    Assert-True ($migratedConfigText -cmatch
            "(?m)^SystemSerial=$([regex]::Escape($legacySystemSerial))`r$") `
        '旧版 SystemSerial 在迁移中被重新抽取'
    Assert-Throws {
        Install-VMateHyperVIdentityBoot -VM $vm `
            -Profile $customProfiles[1] -HardwareIdentity $identity `
            -ExtensionPath $script:TestExtensionPath
    } '拒绝重新抽取'

    $beforeReprofile = Import-VMateHyperVIdentityBootConfig `
        -Path $configPath -ExpectedConfig (New-VMateHyperVIdentityBootConfig `
            -VMId $vmId -Profile $customProfiles[0] `
            -HardwareIdentity $identity)
    $reprofiled = Install-VMateHyperVIdentityBoot -VM $vm `
        -Profile $customProfiles[1] -HardwareIdentity $identity `
        -ExtensionPath $script:TestExtensionPath -AllowProfileReplacement
    Assert-Equal $reprofiled.Status 'Reprofiled' '显式换型状态错误'
    $reprofileConfig = Import-VMateHyperVIdentityBootConfig `
        -Path $configPath -ExpectedConfig (New-VMateHyperVIdentityBootConfig `
            -VMId $vmId -Profile $customProfiles[1] `
            -HardwareIdentity $identity)
    Assert-Equal $reprofileConfig.Fields.BoardProduct `
        $customProfiles[1].Platform.product '显式换型未替换主板事实'
    Assert-Equal $reprofileConfig.Fields.SystemSerial `
        $beforeReprofile.Fields.SystemSerial '显式换型改变了持久系统序列'
    Assert-Equal $reprofileConfig.Fields.BoardSerial `
        $beforeReprofile.Fields.BoardSerial '显式换型改变了持久主板序列'
    $restoredProfile = Install-VMateHyperVIdentityBoot -VM $vm `
        -Profile $customProfiles[0] -HardwareIdentity $identity `
        -ExtensionPath $script:TestExtensionPath -AllowProfileReplacement
    Assert-Equal $restoredProfile.Status 'Reprofiled' '测试 profile 恢复失败'

    $status = Get-VMateHyperVIdentityBootStatus -VM $vm
    Assert-Equal $status.State 'Installed' '安装状态检查错误'
    Assert-True $script:LastReadOnly '状态读取没有使用只读 VHD 挂载'
    Assert-True $status.Integrity '安装状态完整性检查失败'
    Assert-True $status.StockSignatureValid 'stock 签名状态错误'
    Assert-True ([bool]$status.ConfigVerified) '配置哈希状态错误'

    # Windows servicing may legitimately replace the owned EFI entry with a
    # newer Microsoft-signed boot manager. Adopt it as the rollback stock and
    # reinstall the extension transactionally without accepting unsigned drift.
    [IO.File]::WriteAllBytes($boot, [byte[]](32..159))
    $servicedHash = Get-TestHash $boot
    $script:MicrosoftSignedHashes[$servicedHash] = $true
    $serviced = Install-VMateHyperVIdentityBoot -VM $vm `
        -Profile $customProfiles[0] -HardwareIdentity $identity `
        -ExtensionPath $script:TestExtensionPath
    Assert-Equal $serviced.Status 'ServicingReinstalled' `
        'Windows servicing 合法漂移未自动修复'
    Assert-Equal (Get-TestHash $stock) $servicedHash `
        'Windows servicing 后的 Microsoft boot manager 未轮换为 stock'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    Assert-Equal $manifest.StockSha256 $servicedHash `
        'Windows servicing stock 哈希未持久化'

    [IO.File]::WriteAllBytes($boot, [byte[]](1..32))
    Assert-Throws {
        Install-VMateHyperVIdentityBoot -VM $vm `
            -Profile $customProfiles[0] -HardwareIdentity $identity `
            -ExtensionPath $script:TestExtensionPath
    } '拒绝覆盖'
    [IO.File]::WriteAllBytes($boot,
        [IO.File]::ReadAllBytes($script:TestExtensionPath))

    $beforeBoot = Get-TestHash $boot
    $beforeConfig = Get-TestHash $configPath
    $beforeManifest = Get-TestHash $manifestPath
    $script:RemoveExtensionBeforeAction = $true
    Assert-Throws {
        Install-VMateHyperVIdentityBoot -VM $vm `
            -Profile $customProfiles[0] -HardwareIdentity $identity `
            -ExtensionPath $script:TestExtensionPath
    } '找不到路径|不存在|Cannot find'
    Assert-Equal (Get-TestHash $boot) $beforeBoot '失败更新未回滚 boot'
    Assert-Equal (Get-TestHash $configPath) $beforeConfig '失败更新未回滚配置'
    Assert-Equal (Get-TestHash $manifestPath) $beforeManifest `
        '失败更新未回滚 manifest'
    [IO.File]::WriteAllBytes($script:TestExtensionPath,
        [byte[]](255..128))

    $removed = Uninstall-VMateHyperVIdentityBoot -VM $vm
    Assert-Equal $removed.Status 'Uninstalled' '卸载状态错误'
    Assert-Equal (Get-TestHash $boot) $servicedHash `
        '卸载未恢复最新 Windows servicing stock boot'
    Assert-Equal $script:SecureBoot 'On' '卸载未恢复 Secure Boot'
    $again = Uninstall-VMateHyperVIdentityBoot -VM $vm
    Assert-Equal $again.Status 'AlreadyUninstalled' '重复卸载不幂等'

    $reinstalled = Install-VMateHyperVIdentityBoot -VM $vm `
        -Profile $customProfiles[0] -HardwareIdentity $identity `
        -ExtensionPath $script:TestExtensionPath -AllowDisableSecureBoot
    Assert-Equal $reinstalled.Status 'Reinstalled' '重新安装状态错误'
    Assert-Equal $script:SecureBoot 'Off' '重新安装未关闭 Secure Boot'

    # Fresh-install failure must leave the Microsoft boot file byte-exact and
    # remove every newly created ownership marker.
    $script:TestEfiRoot = Join-Path $testRoot 'failure-disk\EFI'
    Initialize-TestEsp
    [IO.File]::WriteAllBytes($script:TestExtensionPath,
        [byte[]](255..128))
    $script:SecureBoot = 'On'
    $freshBoot = Join-Path $script:TestEfiRoot `
        'Microsoft\Boot\bootmgfw.efi'
    $freshHash = Get-TestHash $freshBoot
    $script:RemoveExtensionBeforeAction = $true
    Assert-Throws {
        Install-VMateHyperVIdentityBoot -VM $vm `
            -Profile $customProfiles[0] -HardwareIdentity $identity `
            -ExtensionPath $script:TestExtensionPath -AllowDisableSecureBoot
    } '找不到路径|不存在|Cannot find'
    Assert-Equal (Get-TestHash $freshBoot) $freshHash '首次失败未恢复 boot'
    Assert-Equal $script:SecureBoot 'On' '首次失败未恢复 Secure Boot'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $script:TestEfiRoot `
                    'Microsoft\Boot\bootmgfw.vmate-stock.efi'))) `
        '首次失败遗留无 manifest 的 stock backup'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $script:TestEfiRoot `
                    'VMate\identity-manifest.json'))) `
        '首次失败遗留 manifest'
}
finally {
    if ($testRoot -like (([IO.Path]::GetTempPath()).TrimEnd('\') +
            '\vmate-identity-boot-test-*') -and
        (Test-Path -LiteralPath $testRoot)) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Host 'PASS: Hyper-V identity boot 21-profile and transaction contract'
