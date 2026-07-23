#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$RepoRoot = ''
)

$ErrorActionPreference = 'Stop'
if (-not $RepoRoot) {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
}

. (Join-Path $RepoRoot 'deploy/windows/lib/VMate.Common.ps1')
. (Join-Path $RepoRoot 'deploy/windows/lib/VMate.Components.ps1')
. (Join-Path $RepoRoot 'deploy/windows/lib/VMate.Profile.ps1')
. (Join-Path $RepoRoot 'deploy/windows/lib/VMate.Arguments.ps1')

function Assert-VMateTest {
    param(
        [bool]$Condition,
        [string]$Message
    )
    if (-not $Condition) {
        throw $Message
    }
}

function Assert-VMateThrows {
    param(
        [scriptblock]$Action,
        [string]$Message
    )
    try {
        & $Action
    } catch {
        return
    }
    throw $Message
}

$manifestPath = Join-Path $RepoRoot 'deploy/hardware/platforms.json'
$componentPath = Join-Path $RepoRoot 'deploy/hardware/components.json'
$platformId = 'intel-lga1151-i3-9100f-asus-prime-h310m-a-r2'
$manifest = Read-VMateHardwareManifest -Path $manifestPath
$compatibilityManifest = Read-VMateHostCompatibilityManifest `
    (Join-Path $RepoRoot 'deploy/hardware/host-compatibility.json')
$components = Read-VMateComponentManifest -Path $componentPath
$hostCpu = [pscustomobject]@{
    vendor_id = 'GenuineIntel'
    name = 'Intel(R) Core(TM) i3-9100F CPU @ 3.60GHz'
    cores = 4
    logical_processors = 4
    max_mhz = 4200
}
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) `
    ('vmate-profile-' + [Guid]::NewGuid().ToString('N'))

function New-VMateTestSelection {
    param(
        [string]$Path,
        [int]$Instance = 1,
        [int]$MemoryMiB = 8192,
        [bool]$Reroll = $false,
        [object]$ManifestObject = $null
    )
    if ($null -eq $ManifestObject) {
        $ManifestObject = $script:manifest
    }
    return Prepare-VMateHardwareProfile -Manifest $ManifestObject `
        -Components $script:components -Path $Path -PlatformId $script:platformId `
        -HostCpu $script:hostCpu -Instance $Instance -MemoryMiB $MemoryMiB `
        -Cpus 4 -AllowPlatformCompatibility $true -Reroll $Reroll
}

function Submit-VMateTestSelection {
    param(
        [object]$Selection,
        [string]$Path,
        [int]$Instance
    )
    $lock = Enter-VMateProfileCommitLock -Instance $Instance
    try {
        return Commit-VMateHardwareProfile -Selection $Selection -Path $Path `
            -Lock $lock
    } finally {
        Exit-VMateProfileCommitLock -Lock $lock
    }
}

try {
    New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
    $profilePath = Join-Path $testRoot 'vms/1/hardware-profile.json'

    # Prepare 不落盘；首次 commit 后，重复 prepare 必须复用同一身份。
    $lock = Enter-VMateProfileCommitLock -Instance 1
    try {
        $first = New-VMateTestSelection -Path $profilePath
        Assert-VMateTest (-not (Test-Path -LiteralPath $profilePath)) `
            'Prepare 在 commit 前写入了 profile。'
        $firstCommit = Commit-VMateHardwareProfile -Selection $first `
            -Path $profilePath -Lock $lock
    } finally {
        Exit-VMateProfileCommitLock -Lock $lock
    }
    Assert-VMateTest ($firstCommit.Committed -eq $true) '首次 profile 未提交。'
    Assert-VMateTest (Test-Path -LiteralPath $profilePath -PathType Leaf) `
        '首次 profile 文件不存在。'
    Assert-VMateTest `
        ($first.Profile.manifest_catalog_revision -eq $manifest.catalog_revision) `
        'manifest catalog_revision 未持久化。'
    Assert-VMateTest `
        ($first.Profile.configuration.host_cpu_platform_mismatch_allowed -eq $false) `
        'profile 仍持久化了宿主 CPU/manifest 主板不匹配模式。'
    Assert-VMateComponentSerial $components.storage `
        ([string]$first.Profile.identity.nvme_serial) 'SSD'
    Assert-VMateMonitorSerial $components.monitor `
        ([string]$first.Profile.identity.monitor_serial)

    $lock = Enter-VMateProfileCommitLock -Instance 1
    try {
        $reloaded = New-VMateTestSelection -Path $profilePath
        $reloadCommit = Commit-VMateHardwareProfile -Selection $reloaded `
            -Path $profilePath -Lock $lock
    } finally {
        Exit-VMateProfileCommitLock -Lock $lock
    }
    Assert-VMateTest (-not $reloadCommit.Committed) '未 reroll 却重写了 profile。'
    Assert-VMateTest `
        ($first.Profile.identity.uuid -eq $reloaded.Profile.identity.uuid) `
        '重复加载改变了持久 UUID。'

    # File.Replace 必须把旧 active 原子保存为唯一备份；连续同毫秒 reroll 也
    # 不得覆盖前一个备份，且每个备份内容必须等于其前一版 active。
    $activeA = Get-VMateProfileFileDigest -Path $profilePath
    $rerollB = New-VMateTestSelection -Path $profilePath -Reroll $true
    $commitB = Submit-VMateTestSelection -Selection $rerollB `
        -Path $profilePath -Instance 1
    $activeB = Get-VMateProfileFileDigest -Path $profilePath
    Assert-VMateTest ($activeA -ne $activeB) 'reroll 没有替换 active profile。'
    Assert-VMateTest ((Get-VMateProfileFileDigest $commitB.BackupPath) -eq $activeA) `
        '首次 reroll 备份不是旧 active。'
    $rerollC = New-VMateTestSelection -Path $profilePath -Reroll $true
    $commitC = Submit-VMateTestSelection -Selection $rerollC `
        -Path $profilePath -Instance 1
    Assert-VMateTest ($commitB.BackupPath -ne $commitC.BackupPath) `
        '连续 reroll 复用了备份路径。'
    Assert-VMateTest ((Get-VMateProfileFileDigest $commitC.BackupPath) -eq $activeB) `
        '第二次 reroll 备份不是前一版 active。'

    $profile = $rerollC.Profile
    $platform = $rerollC.Platform
    $profile.configuration.host_cpu_platform_mismatch_allowed = 'False'
    Assert-VMateThrows {
        Assert-VMateHardwareProfile $profile $manifest $platform $components `
            $hostCpu 1 8192 4 $true
    } '字符串 False 绕过了严格布尔校验。'
    $profile.configuration.host_cpu_platform_mismatch_allowed = $true
    Assert-VMateThrows {
        Assert-VMateHardwareProfile $profile $manifest $platform $components `
            $hostCpu 1 8192 4 $true
    } '布尔 true 仍允许持久化宿主 CPU/manifest 主板不匹配模式。'
    $profile.configuration.host_cpu_platform_mismatch_allowed = $false
    $profile.host_cpu.name = 'Fabricated CPU'
    Assert-VMateThrows {
        Assert-VMateHardwareProfile $profile $manifest $platform $components `
            $hostCpu 1 8192 4 $true
    } '伪造宿主 CPU 名称通过了绑定校验。'
    $profile.host_cpu.name = $hostCpu.name
    $profile.host_cpu.max_mhz = 99999
    Assert-VMateThrows {
        Assert-VMateHardwareProfile $profile $manifest $platform $components `
            $hostCpu 1 8192 4 $true
    } '伪造宿主 CPU 频率通过了绑定校验。'
    $profile.host_cpu.max_mhz = $hostCpu.max_mhz

    # 兼容开关不能把任意宿主 CPU 填入物理主板，只能转入同厂商的 generic Q35
    # 模板；Type 4 报告宿主字段，未知的 socket/family/part 必须省略。
    $mismatchHost = $hostCpu | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $mismatchHost.name = 'Intel(R) Core(TM) i3-8100 CPU @ 3.60GHz'
    Assert-VMateThrows {
        Select-VMatePlatform -Manifest $manifest -PlatformId $platformId `
            -CompatibilityManifest $compatibilityManifest -HostCpu $mismatchHost `
            -AllowPlatformCompatibility $true
    } '兼容开关把宿主 CPU 强行混入了物理 H310 平台。'
    $serverHost = $mismatchHost | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $serverHost.name = 'Intel(R) Xeon(R) CPU E5-2696 v4 @ 2.20GHz'
    Assert-VMateThrows {
        Select-VMatePlatform $manifest $compatibilityManifest '' $serverHost $true
    } 'WHPX generic compatibility 暴露了 Xeon/E5 服务器品牌。'
    $amdHost = [pscustomobject]@{
        vendor_id = 'AuthenticAMD'; name = 'AMD Ryzen 3 1300X Quad-Core Processor'
        cores = 4; logical_processors = 4; max_mhz = 3700
    }
    foreach ($compatHost in @($mismatchHost, $amdHost)) {
        $compat = Prepare-VMateHardwareProfile -Manifest $manifest `
            -CompatibilityManifest $compatibilityManifest -Components $components `
            -Path (Join-Path $testRoot "compat-$($compatHost.vendor_id).json") `
            -HostCpu $compatHost -Instance 99 -MemoryMiB 8192 -Cpus 4 `
            -AllowPlatformCompatibility $true -Reroll $false
        $expectedId = if ($compatHost.vendor_id -eq 'AuthenticAMD') {
            'compat-host-amd-q35'
        } else {
            'compat-host-intel-q35'
        }
        Assert-VMateTest ($compat.Platform.id -eq $expectedId -and
            $compat.Profile.cpu_policy -eq 'whpx-host-compatibility' -and
            $compat.Profile.configuration.host_cpu_platform_mismatch_allowed) `
            '显式兼容模式没有选择同厂商 Q35 模板并持久化策略。'
        $compatType4 = @(New-VMateSmbiosArguments $compat.Platform $compat.Profile |
            Where-Object { [string]$_ -match '^type=4,' })
        Assert-VMateTest ($compatType4.Count -eq 1 -and
            $compatType4[0] -match 'sock_pfx=CPU' -and
            $compatType4[0] -notmatch 'processor-family=|part=') `
            '兼容 Type 4 冒用了无法从 WHPX 宿主证明的物理字段。'
        Assert-VMateThrows {
            Assert-VMateHardwareProfile $compat.Profile $compatibilityManifest `
                $compat.Platform $components $compatHost 99 8192 4 $false
        } '兼容 profile 未要求每次启动重新显式授权。'
    }
    $type4 = @(New-VMateSmbiosArguments $platform $profile |
        Where-Object { [string]$_ -match '^type=4,' })
    Assert-VMateTest `
        ($type4.Count -eq 1 -and $type4[0] -match 'sock_pfx=LGA1151' -and
            $type4[0] -match 'processor-family=0x00CE') `
        'SMBIOS Type 4 未使用与 manifest 主板配对的平台 CPU 事实。'

    # 身份字段必须保持生成器定义的规范形态；空值、占位值、非 v4 UUID、
    # 广播/本地/错 OUI MAC 以及 DIMM 重复序列都必须在加载时拒绝。
    foreach ($identityMutation in @(
            'empty-system',
            'placeholder-board',
            'nil-uuid',
            'placeholder-v4-uuid',
            'broadcast-mac',
            'local-mac',
            'wrong-oui',
            'duplicate-memory',
            'placeholder-memory',
            'placeholder-memory-one',
            'placeholder-nvme',
            'placeholder-monitor')) {
        $badIdentity = $profile | ConvertTo-Json -Depth 64 | ConvertFrom-Json
        switch ($identityMutation) {
            'empty-system' { $badIdentity.identity.system_serial = '' }
            'placeholder-board' {
                $badIdentity.identity.board_serial = 'MB000000000000'
            }
            'nil-uuid' {
                $badIdentity.identity.uuid = '00000000-0000-0000-0000-000000000000'
            }
            'placeholder-v4-uuid' {
                $badIdentity.identity.uuid =
                    '00000000-0000-4000-8000-000000000000'
            }
            'broadcast-mac' { $badIdentity.identity.mac = 'FF:FF:FF:FF:FF:FF' }
            'local-mac' { $badIdentity.identity.mac = '02:00:00:12:34:56' }
            'wrong-oui' { $badIdentity.identity.mac = '00:1B:21:12:34:56' }
            'duplicate-memory' {
                $badIdentity.identity.memory_serials[1] =
                    $badIdentity.identity.memory_serials[0]
            }
            'placeholder-memory' {
                $badIdentity.identity.memory_serials[0] = '00000000'
            }
            'placeholder-memory-one' {
                $badIdentity.identity.memory_serials[0] = '00000001'
            }
            'placeholder-nvme' {
                $badIdentity.identity.nvme_serial = 'S000N000000000'
            }
            'placeholder-monitor' {
                $badIdentity.identity.monitor_serial = 'INVALID_SERIAL'
            }
        }
        Assert-VMateThrows {
            Assert-VMateHardwareProfile $badIdentity $manifest $platform `
                $components $hostCpu 1 8192 4 $true
        } "身份篡改 '$identityMutation' 通过了 profile 校验。"
    }

    $changedManifest = $manifest | ConvertTo-Json -Depth 64 | ConvertFrom-Json
    $changedManifest.catalog_revision = '2026-07-22.2'
    $changedPlatform = @($changedManifest.platforms | Where-Object { $_.id -eq $platformId })[0]
    Assert-VMateHardwareProfile $profile $changedManifest $changedPlatform $components $hostCpu 1 8192 4 $true
    $changedPlatform.board.product = 'rewritten-selected-platform'
    Assert-VMateThrows {
        Assert-VMateHardwareProfile $profile $changedManifest $changedPlatform `
            $components $hostCpu 1 8192 4 $true
    } '已选平台事实变化未触发 profile 摘要拒绝。'

    # 负测不能只依赖 canonical allowlist：即使篡改者把 3072 加入 allowlist，
    # 它仍无法由 2/4GiB 同型号 DIMM 和槽位组成，manifest 与请求门禁都要拒绝。
    $badManifest = $manifest | ConvertTo-Json -Depth 64 | ConvertFrom-Json
    $badPlatform = @($badManifest.platforms | Where-Object {
        $_.id -eq $platformId
    })[0]
    $badPlatform.memory.allowed_total_mib = `
        @($badPlatform.memory.allowed_total_mib) + 3072
    Assert-VMateThrows { Assert-VMatePlatformShape $badPlatform } `
        '不可组合的 allowlist 容量通过了 manifest 校验。'
    Assert-VMateThrows {
        Assert-VMateRequestedTopology $badPlatform $hostCpu 3072 4
    } '不可组合的请求容量通过了 topology gate。'

    # Windows 当前不创建 TPM 设备，但共享平台目录仍必须接受合法的动态
    # TPM 1.2/无 TPM 条目，并拒绝字段、类型、枚举及跨字段组合篡改。
    $validTpm12 = $platform | ConvertTo-Json -Depth 64 | ConvertFrom-Json
    $validTpm12.tpm.capability = 'discrete'
    $validTpm12.tpm.implementation = 'discrete-module'
    $validTpm12.tpm.version = '1.2'
    $validTpm12.tpm.emulation_frontend = 'tpm-tis'
    $validTpm12.tpm.pcr_banks = @('sha1')
    Assert-VMatePlatformShape $validTpm12

    $validNoTpm = $platform | ConvertTo-Json -Depth 64 | ConvertFrom-Json
    $validNoTpm.tpm.supported = $false
    $validNoTpm.tpm.capability = 'none'
    $validNoTpm.tpm.implementation = 'none'
    $validNoTpm.tpm.version = 'none'
    $validNoTpm.tpm.emulation_frontend = 'none'
    $validNoTpm.tpm.pcr_banks = @()
    Assert-VMatePlatformShape $validNoTpm

    $missingTpm = $platform | ConvertTo-Json -Depth 64 | ConvertFrom-Json
    $missingTpm.PSObject.Properties.Remove('tpm')
    Assert-VMateThrows {
        Assert-VMatePlatformShape $missingTpm
    } '缺少 tpm 对象的平台通过了 Windows 校验。'

    foreach ($tpmMutation in @(
            'missing-field',
            'unknown-field',
            'supported-string',
            'unknown-version',
            'scalar-pcr-banks',
            'duplicate-pcr-bank',
            'http-source',
            'untrusted-source',
            'same-sources',
            'tpm12-crb',
            'tpm12-sha256',
            'unsupported-with-device',
            'firmware-vendor-mismatch',
            'discrete-implementation-mismatch')) {
        $badTpmPlatform = $platform |
            ConvertTo-Json -Depth 64 | ConvertFrom-Json
        switch ($tpmMutation) {
            'missing-field' {
                $badTpmPlatform.tpm.PSObject.Properties.Remove('version')
            }
            'unknown-field' {
                $badTpmPlatform.tpm |
                    Add-Member -NotePropertyName unexpected -NotePropertyValue $true
            }
            'supported-string' {
                $badTpmPlatform.tpm.supported = 'true'
            }
            'unknown-version' {
                $badTpmPlatform.tpm.version = '2.1'
            }
            'scalar-pcr-banks' {
                $badTpmPlatform.tpm.pcr_banks = 'sha256'
            }
            'duplicate-pcr-bank' {
                $badTpmPlatform.tpm.pcr_banks = @('sha256', 'sha256')
            }
            'http-source' {
                $badTpmPlatform.tpm.support_source_ref =
                    'http://example.invalid/tpm'
            }
            'untrusted-source' {
                $badTpmPlatform.tpm.support_source_ref =
                    'https://example.invalid/tpm'
            }
            'same-sources' {
                $badTpmPlatform.tpm.version_source_ref =
                    $badTpmPlatform.tpm.support_source_ref
            }
            'tpm12-crb' {
                $badTpmPlatform.tpm.version = '1.2'
                $badTpmPlatform.tpm.pcr_banks = @('sha1')
            }
            'tpm12-sha256' {
                $badTpmPlatform.tpm.version = '1.2'
                $badTpmPlatform.tpm.emulation_frontend = 'tpm-tis'
            }
            'unsupported-with-device' {
                $badTpmPlatform.tpm.supported = $false
            }
            'firmware-vendor-mismatch' {
                $badTpmPlatform.tpm.implementation = 'amd-ftpm'
            }
            'discrete-implementation-mismatch' {
                $badTpmPlatform.tpm.capability = 'discrete'
            }
        }
        Assert-VMateThrows {
            Assert-VMatePlatformShape $badTpmPlatform
        } "TPM manifest 篡改 '$tpmMutation' 通过了 Windows 校验。"
    }

    # 容量拓扑固定；多态品牌的稳定 ID、料号和 SPD 几何必须来自同一目录条目。
    $expectedPlans = @{
        2048 = @(2048, 1); 4096 = @(4096, 1)
        8192 = @(4096, 2)
    }
    $planInstance = 10
    foreach ($memory in @(2048, 4096, 8192)) {
        $path = Join-Path $testRoot "plans/$memory/hardware-profile.json"
        $selection = New-VMateTestSelection -Path $path -Instance $planInstance `
            -MemoryMiB $memory
        $expected = $expectedPlans[$memory]
        $memoryFacts = Get-VMateMemoryRateFacts -Platform $selection.Platform `
            -PartNumber ([string]$selection.Profile.identity.memory_part) -Manufacturer `
            ([string]$selection.Profile.identity.memory_manufacturer) -ModuleId `
            ([string]$selection.Profile.identity.memory_module_id)
        Assert-VMateTest `
            ($selection.Profile.configuration.memory_module_mib -eq $expected[0] -and
             $selection.Profile.configuration.memory_module_count -eq $expected[1] -and
             $memoryFacts.ModuleId -eq $selection.Profile.identity.memory_module_id -and
             @($selection.Profile.identity.memory_serials).Count -eq $expected[1]) `
            "${memory}MiB 的 DIMM 物料方案不一致。"
        [void](New-VMateSmbiosArguments $selection.Platform $selection.Profile)
        $planInstance++
    }

    # 深层 PCI 校验失败时调用方尚未 commit；新路径不产生 profile，reroll 也
    # 不改变 active 或备份数。PreparedDigest 还会拒绝构参后的内存篡改。
    $latePath = Join-Path $testRoot 'vms/late/hardware-profile.json'
    $lateManifest = $manifest | ConvertTo-Json -Depth 64 | ConvertFrom-Json
    $late = New-VMateTestSelection -Path $latePath -Instance 2 `
        -ManifestObject $lateManifest
    $late.Platform.board.subsystem_device = 'bogus'
    Assert-VMateThrows { New-VMateChipsetArguments $late.Platform } `
        '非法 PCI 字段未在 commit 前失败。'
    Assert-VMateTest (-not (Test-Path -LiteralPath $latePath)) `
        '深层参数失败后写入了新 profile。'

    $beforeLateHash = Get-VMateProfileFileDigest -Path $profilePath
    $beforeBackupCount = @(Get-ChildItem (Split-Path -Parent $profilePath) `
        -Filter '*.bak').Count
    $lateRerollManifest = $manifest | ConvertTo-Json -Depth 64 | ConvertFrom-Json
    $lateReroll = New-VMateTestSelection -Path $profilePath -Reroll $true `
        -ManifestObject $lateRerollManifest
    $lateReroll.Platform.board.subsystem_device = 'bogus'
    Assert-VMateThrows { New-VMateChipsetArguments $lateReroll.Platform } `
        '非法 reroll PCI 字段未在 commit 前失败。'
    Assert-VMateTest `
        ((Get-VMateProfileFileDigest $profilePath) -eq $beforeLateHash -and
         @(Get-ChildItem (Split-Path -Parent $profilePath) -Filter '*.bak').Count -eq
            $beforeBackupCount) `
        '深层 reroll 参数失败后改变了 active 或备份。'

    $tamperPath = Join-Path $testRoot 'vms/tamper/hardware-profile.json'
    $tampered = New-VMateTestSelection -Path $tamperPath -Instance 3
    $tampered.Profile.identity.system_serial += 'X'
    $tamperLock = Enter-VMateProfileCommitLock -Instance 3
    try {
        Assert-VMateThrows {
            Commit-VMateHardwareProfile $tampered $tamperPath $tamperLock
        } '参数验证后的 profile 内存篡改仍被提交。'
    } finally {
        Exit-VMateProfileCommitLock $tamperLock
    }
    Assert-VMateTest (-not (Test-Path -LiteralPath $tamperPath)) `
        '内存篡改失败后写入了 profile。'

    # 第二个进程必须拿不到同一 Instance；释放后则可重新取得，证明无死锁残留。
    $heldLock = Enter-VMateProfileCommitLock -Instance 4
    try {
        $storePath = Join-Path $RepoRoot `
            'deploy/windows/lib/VMate.ProfileStore.ps1'
        $job = Start-Job -ScriptBlock {
            param($StorePath)
            . $StorePath
            try {
                $other = Enter-VMateProfileCommitLock -Instance 4 `
                    -TimeoutMilliseconds 300
                try { 'ACQUIRED' } finally { Exit-VMateProfileCommitLock $other }
            } catch {
                'BLOCKED'
            }
        } -ArgumentList $storePath
        [void](Wait-Job -Job $job -Timeout 10)
        $lockResult = @(Receive-Job -Job $job)
        Remove-Job -Job $job -Force
        Assert-VMateTest ($lockResult -contains 'BLOCKED') `
            '并发进程取得了同一 Instance 的生命周期锁。'
    } finally {
        Exit-VMateProfileCommitLock $heldLock
    }
    $releasedLock = Enter-VMateProfileCommitLock -Instance 4
    Exit-VMateProfileCommitLock $releasedLock

    Write-Output 'OK: Windows profile transaction/integrity checks passed'
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
