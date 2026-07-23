#Requires -Version 5.1

param([string]$RepoRoot = '')

$ErrorActionPreference = 'Stop'
if (-not $RepoRoot) {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
}

. (Join-Path $RepoRoot 'deploy/windows/lib/VMate.Common.ps1')
. (Join-Path $RepoRoot 'deploy/windows/lib/VMate.Components.ps1')
. (Join-Path $RepoRoot 'deploy/windows/lib/VMate.Profile.ps1')
. (Join-Path $RepoRoot `
    'deploy/scripts/tests/fixtures/gpu_board_catalog_cases.ps1')

function Assert-SourceSelection {
    param([bool]$Condition, [string]$Message)

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-SourceSelectionThrows {
    param(
        [scriptblock]$Action,
        [string]$Pattern,
        [string]$Message
    )

    try {
        & $Action
    } catch {
        if ($_.Exception.Message -notmatch $Pattern) {
            throw "$Message；错误不可诊断：$($_.Exception.Message)"
        }
        return
    }
    throw $Message
}

$componentPath = Join-Path $RepoRoot 'deploy/hardware/components.json'
$manifestPath = Join-Path $RepoRoot 'deploy/hardware/platforms.json'
$catalog = Read-VMateComponentManifest $componentPath
$gpuCases = @(Get-TestGpuBoardCases `
    (Join-Path $RepoRoot 'deploy/hardware/gpu-boards.json'))
Assert-TestGpuBoardCoverage $gpuCases
$gpuId = 'asus-ph-gtx1050ti-4g'
$monitorId = 'aoc-24b2xh'
$storageId = 'samsung-970-pro-512gb'
$memoryId = 'samsung-m378a5244cb0-crc-ddr4-4g'

Assert-SourceSelection ($catalog.gpu_items.Count -eq 18 -and
    (@($catalog.gpu_items.id | Sort-Object) -join ',') -ceq
        (@($gpuCases.StableId | Sort-Object) -join ',') -and
    $catalog.legacy_gpu_items.Count -eq 6 -and
    $catalog.storage_items.Count -eq 4) `
    'Windows 没有分离 18 款 AIB 新建池、六款旧 GPU 标签池和四款 SSD。'
Assert-SourceSelection `
    (@($catalog.gpu_items | Where-Object {
                $_.identity_fidelity -cne
                    'audited_aib_bundle_shallow_user_projection_no_passthrough'
            }).Count -eq 0) `
    'AIB GPU 目录没有保持浅层用户态投影边界。'
Assert-SourceSelection `
    (@($catalog.storage_items | Where-Object {
                [int64]$_.raw_bytes -ne 512110190592
            }).Count -eq 0) `
    '外置 SSD 目录仍包含非精确 512GB 条目。'

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) `
    ('vmate-source-selection-' + [Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
    $missingProfile = Join-Path $testRoot 'missing-profile.json'
    $selected = Resolve-VMateComponentsForProfile -Catalog $catalog `
        -ProfilePath $missingProfile -Reroll $false -DryRun $true `
        -StorageId $storageId -GpuId $gpuId -MonitorId $monitorId
    Assert-SourceSelection `
        ([string]$selected.storage.id -ceq $storageId -and
         [string]$selected.gpu.id -ceq $gpuId -and
         [string]$selected.monitor.id -ceq $monitorId) `
        '非空部件 ID 没有从启用源头目录精确选择。'
    Assert-SourceSelection `
        ((Get-VMateGpuLabel $selected.gpu) -ceq
            'NVIDIA GeForce GTX 1050 Ti (ASUS Phoenix)') `
        'GPU 标签没有由源头 manufacturer/model 稳定生成。'

    Assert-SourceSelectionThrows {
        Resolve-VMateComponentsForProfile $catalog $missingProfile $false `
            -DryRun $true -StorageId 'wd-blue-sn570-500gb'
    } '未在启用目录中找到' 'DryRun 接受了非统一 512G 的显式 WD 存储。'
    Assert-SourceSelectionThrows {
        Resolve-VMateComponentsForProfile $catalog $missingProfile $false `
            -DryRun $true -StorageId $storageId.ToUpperInvariant()
    } '未在启用目录中找到' 'StorageId 没有执行大小写精确匹配。'
    Assert-SourceSelectionThrows {
        Resolve-VMateComponentsForProfile $catalog $missingProfile $false `
            -DryRun $true -GpuId $gpuId.ToUpperInvariant()
    } '未在启用目录中找到' 'GPU ID 没有执行大小写精确匹配。'
    Assert-SourceSelectionThrows {
        Resolve-VMateComponentsForProfile $catalog $missingProfile $false `
            -DryRun $true -GpuId 'nvidia-geforce-gtx-1050-ti'
    } '未在启用目录中找到' '新 profile 错误选择了旧 generic GPU 标签。'
    Assert-SourceSelectionThrows {
        Resolve-VMateComponentsForProfile $catalog $missingProfile $false `
            -DryRun $true -MonitorId 'missing-monitor'
    } '未在启用目录中找到' '未知显示器 ID 没有 fail closed。'
    Assert-SourceSelectionThrows {
        Resolve-VMateComponentsForProfile $catalog $missingProfile $false `
            -DryRun $true -MonitorId $monitorId.ToUpperInvariant()
    } '未在启用目录中找到' 'MonitorId 没有执行大小写精确匹配。'

    $binding = New-VMateComponentProfileBinding $selected
    Assert-SourceSelection `
        ([int]$binding.binding_version -eq 3 -and
         [string]$binding.gpu_id -ceq $gpuId -and
         [string]$binding.gpu_digest -ceq
            (Get-VMateComponentDigest $selected.gpu) -and
         [string]$binding.gpu_label -ceq
            'NVIDIA GeForce GTX 1050 Ti (ASUS Phoenix)' -and
         [string]$binding.gpu_identity_fidelity -ceq
            'audited_aib_bundle_shallow_user_projection_no_passthrough') `
        'V3 profile 没有持久化稳定 GPU ID/标签/边界。'
    Assert-VMateComponentProfileBinding $binding $selected
    $tampered = $binding | ConvertTo-Json -Depth 16 | ConvertFrom-Json
    $tampered.gpu_label = 'Implemented Physical GPU'
    Assert-SourceSelectionThrows {
        Assert-VMateComponentProfileBinding $tampered $selected
    } 'GPU 稳定标签' 'GPU profile 标签篡改没有被拒绝。'
    $tamperedDigest = $binding | ConvertTo-Json -Depth 16 | ConvertFrom-Json
    $tamperedDigest.gpu_digest = '0' * 64
    Assert-SourceSelectionThrows {
        Assert-VMateComponentProfileBinding $tamperedDigest $selected
    } 'gpu 条目摘要' 'GPU profile 摘要篡改没有被拒绝。'

    $profilePath = Join-Path $testRoot 'hardware-profile.json'
    [pscustomobject]@{ components = $binding } |
        ConvertTo-Json -Depth 32 |
        Set-Content -LiteralPath $profilePath -Encoding UTF8
    $persisted = Resolve-VMateComponentsForProfile $catalog $profilePath `
        $false -DryRun $true -StorageId $storageId -GpuId $gpuId `
        -MonitorId $monitorId
    Assert-SourceSelection ([string]$persisted.gpu.id -ceq $gpuId) `
        '已有 profile 没有优先恢复 GPU 稳定绑定。'
    Assert-SourceSelectionThrows {
        Resolve-VMateComponentsForProfile $catalog $profilePath $false `
            -DryRun $true -StorageId 'wd-blue-sn570-500gb'
    } '不会重新抽取' '已有 profile 接受了冲突的显式 StorageId。'
    Assert-SourceSelectionThrows {
        Resolve-VMateComponentsForProfile $catalog $profilePath $false `
            -DryRun $true -GpuId 'colorful-igame-gtx1050ti-u-4gd5'
    } '不会重新抽取' '已有 profile 接受了冲突的显式 GPU ID。'
    Assert-SourceSelectionThrows {
        Resolve-VMateComponentsForProfile $catalog $profilePath $false `
            -DryRun $true -MonitorId 'samsung-s24f350'
    } '不会重新抽取' '已有 profile 接受了冲突的显式显示器 ID。'

    # 根清单与外置子目录的修订同步变化时，总摘要会变化；已选条目的内容和
    # 摘要不变，因此既有 profile 仍可按稳定 ID 恢复。
    $expandedRoot = Join-Path $testRoot 'expanded'
    New-Item -ItemType Directory -Force -Path $expandedRoot | Out-Null
    $expandedPath = Join-Path $expandedRoot 'components.json'
    $expanded = Get-Content -LiteralPath $componentPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    $expanded.catalog_revision = '2026-07-23.99'
    $expanded | ConvertTo-Json -Depth 64 |
        Set-Content -LiteralPath $expandedPath -Encoding UTF8
    foreach ($catalogName in @($expanded.storage_catalog,
            $expanded.gpu_board_catalog)) {
        $sourcePath = Join-Path ([IO.Path]::GetDirectoryName($componentPath)) `
            $catalogName
        $child = Get-Content -LiteralPath $sourcePath -Raw -Encoding UTF8 |
            ConvertFrom-Json
        $child.catalog_revision = '2026-07-23.99'
        $child | ConvertTo-Json -Depth 64 |
            Set-Content -LiteralPath (Join-Path $expandedRoot $catalogName) `
                -Encoding UTF8
    }
    $expandedCatalog = Read-VMateComponentManifest $expandedPath
    $expandedResolved = Resolve-VMateComponentsForProfile $expandedCatalog `
        $profilePath $false -DryRun $true
    Assert-VMateComponentProfileBinding $binding $expandedResolved
    Assert-SourceSelection `
        ($expandedCatalog.catalog_digest -cne $catalog.catalog_digest -and
         $expandedCatalog.gpu_items.Count -eq $catalog.gpu_items.Count) `
        '外置目录修订没有进入总摘要，或改变了受审计 AIB 集合。'

    $manifest = Read-VMateHardwareManifest $manifestPath
    $hostCpu = [pscustomobject]@{
        vendor_id = 'GenuineIntel'
        name = 'Intel(R) Core(TM) i3-9100F CPU @ 3.60GHz'
        cores = 4
        logical_processors = 4
        max_mhz = 4200
    }
    $fullProfile = Join-Path $testRoot 'full/hardware-profile.json'
    $selection = Prepare-VMateHardwareProfile -Manifest $manifest `
        -Components $selected -Path $fullProfile `
        -PlatformId 'intel-lga1151-i3-9100f-asus-prime-h310m-a-r2' `
        -HostCpu $hostCpu -Instance 91 -MemoryMiB 8192 -Cpus 4 `
        -MemoryId $memoryId -AllowPlatformCompatibility $false -Reroll $false
    Assert-SourceSelection `
        ([string]$selection.Profile.identity.memory_module_id -ceq $memoryId) `
        '非空 MemoryId 没有使用合法平台 DIMM 计划。'
    New-Item -ItemType Directory -Force `
        -Path ([System.IO.Path]::GetDirectoryName($fullProfile)) | Out-Null
    $selection.Profile | ConvertTo-Json -Depth 64 |
        Set-Content -LiteralPath $fullProfile -Encoding UTF8
    [void](Prepare-VMateHardwareProfile -Manifest $manifest `
        -Components $selected -Path $fullProfile `
        -PlatformId 'intel-lga1151-i3-9100f-asus-prime-h310m-a-r2' `
        -HostCpu $hostCpu -Instance 91 -MemoryMiB 8192 -Cpus 4 `
        -MemoryId $memoryId -AllowPlatformCompatibility $false -Reroll $false)
    Assert-SourceSelectionThrows {
        Prepare-VMateHardwareProfile -Manifest $manifest `
            -Components $selected -Path $fullProfile `
            -PlatformId 'intel-lga1151-i3-9100f-asus-prime-h310m-a-r2' `
            -HostCpu $hostCpu -Instance 91 -MemoryMiB 8192 -Cpus 4 `
            -MemoryId 'kingston-kvr24n17s8-4-ddr4-4g' `
            -AllowPlatformCompatibility $false -Reroll $false
    } '不会重新抽取' '已有 profile 接受了冲突的显式 MemoryId。'
    Assert-SourceSelectionThrows {
        Get-VMateMemoryModulePlan `
            -Platform $selection.Platform -MemoryMiB 8192 `
            -ModuleId $memoryId.ToUpperInvariant()
    } '无法唯一解析' 'MemoryId 没有执行大小写精确匹配。'
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force `
        -ErrorAction SilentlyContinue
}

Write-Output 'PASS: Windows source-driven hardware selection'
