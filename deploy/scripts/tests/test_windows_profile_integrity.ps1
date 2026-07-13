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
$components = Read-VMateComponentManifest -Path $componentPath
$hostCpu = [pscustomobject]@{
    vendor_id = 'GenuineIntel'
    name = 'Intel(R) Test CPU'
    cores = 8
    logical_processors = 16
    max_mhz = 3600
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
        -Cpus 4 -AllowHostCpuPlatformMismatch $true -Reroll $Reroll
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

    $changedManifest = $manifest | ConvertTo-Json -Depth 64 | ConvertFrom-Json
    $changedManifest.catalog_revision = 'tampered-revision'
    $changedPlatform = @($changedManifest.platforms | Where-Object {
        $_.id -eq $platformId
    })[0]
    Assert-VMateThrows {
        Assert-VMateHardwareProfile $profile $changedManifest $changedPlatform `
            $components $hostCpu 1 8192 4 $true
    } 'manifest catalog_revision 变化未触发 profile 拒绝。'

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

    # 2/4/8GiB 必须分别映射到 1x2G、1x4G、2x4G，并生成相同数量的序列号。
    $expectedPlans = @{
        2048 = @(2048, 1, 'M378A5644EB0-CRC')
        4096 = @(4096, 1, 'M378A5244CB0-CRC')
        8192 = @(4096, 2, 'M378A5244CB0-CRC')
    }
    $planInstance = 10
    foreach ($memory in @(2048, 4096, 8192)) {
        $path = Join-Path $testRoot "plans/$memory/hardware-profile.json"
        $selection = New-VMateTestSelection -Path $path -Instance $planInstance `
            -MemoryMiB $memory
        $expected = $expectedPlans[$memory]
        Assert-VMateTest `
            ($selection.Profile.configuration.memory_module_mib -eq $expected[0] -and
             $selection.Profile.configuration.memory_module_count -eq $expected[1] -and
             $selection.Profile.identity.memory_part -eq $expected[2] -and
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
