#Requires -Version 5.1

[CmdletBinding()]
param([string]$RepoRoot = '')

$ErrorActionPreference = 'Stop'
if (-not $RepoRoot) {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
}

. (Join-Path $RepoRoot 'deploy/windows/lib/VMate.Common.ps1')
. (Join-Path $RepoRoot 'deploy/windows/lib/VMate.Components.ps1')
. (Join-Path $RepoRoot 'deploy/windows/lib/VMate.Manifest.ps1')

function Assert-VMateMutationRejected {
    param(
        [scriptblock]$Action,
        [string]$Name
    )
    try {
        & $Action
    } catch {
        return
    }
    throw "篡改 '$Name' 通过了 Windows 严格清单校验。"
}

$manifestPath = Join-Path $RepoRoot 'deploy/hardware/platforms.json'
$componentPath = Join-Path $RepoRoot 'deploy/hardware/components.json'
$manifest = Read-VMateHardwareManifest $manifestPath
$platform = @($manifest.platforms | Where-Object {
        $_.id -eq 'intel-lga1151-i3-9100f-asus-prime-h310m-a-r2'
    })[0]

$platformMutations = @(
    @{ Name = 'release-year-type'; Apply = { param($p) $p.release_year = 'never' } },
    @{ Name = 'empty-qemu-arg'; Apply = { param($p) $p.cpu.qemu_arg = '' } },
    @{ Name = 'empty-cpu-part'; Apply = { param($p) $p.cpu.part = '' } },
    @{ Name = 'max-mhz-type'; Apply = { param($p) $p.cpu.max_mhz = 'fast' } },
    @{ Name = 'phys-bits-range'; Apply = { param($p) $p.cpu.phys_bits = 53 } },
    @{ Name = 'empty-bios-version'; Apply = { param($p) $p.bios.version = '' } },
    @{ Name = 'chipset-tuple'; Apply = { param($p) $p.devices.chipset.lpc = @('bogus') } },
    @{ Name = 'root-port-id'; Apply = {
            param($p)
            $p.devices.root_port.pci_vendor = 'bogus'
        } },
    @{ Name = 'nic-bundle'; Apply = { param($p) $p.devices.nic.pci_device = '0xFFFF' } },
    @{ Name = 'audio-bundle'; Apply = { param($p) $p.devices.audio.codec = 'ALC999' } }
)
foreach ($case in $platformMutations) {
    $bad = $platform | ConvertTo-Json -Depth 64 | ConvertFrom-Json
    & $case.Apply $bad
    Assert-VMateMutationRejected { Assert-VMatePlatformShape $bad } $case.Name
}
$h110 = @($manifest.platforms | Where-Object {
        $_.id -eq 'intel-lga1151-i5-6400t-asus-h110m-a-m2'
    })[0] | ConvertTo-Json -Depth 64 | ConvertFrom-Json
$h110.cpu.qemu_arg = 'qemu64,model-id=Intel(R) Core(TM) i5-6400T CPU @ 2.20GHz'
Assert-VMateMutationRejected {
    Assert-VMatePlatformShape $h110
} 'non-h310-generic-qemu-base'

$componentRoot = Get-Content -LiteralPath $componentPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$storagePath = Join-Path ([IO.Path]::GetDirectoryName($componentPath)) `
    ([string]$componentRoot.storage_catalog)
$storageRoot = Get-Content -LiteralPath $storagePath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$gpuBoardPath = Join-Path ([IO.Path]::GetDirectoryName($componentPath)) `
    ([string]$componentRoot.gpu_board_catalog)
$componentJson = [IO.File]::ReadAllText($componentPath)
$storageJson = [IO.File]::ReadAllText($storagePath)
$gpuBoardJson = [IO.File]::ReadAllText($gpuBoardPath)
$componentMutations = @(
    @{ Name = 'storage-catalog-traversal'; Apply = {
            param($c)
            $c.storage_catalog = '../storage.json'
        } },
    @{ Name = 'keyboard-id'; Apply = { param($c) $c.hid.keyboards[0].id = 'bogus' } },
    @{ Name = 'keyboard-evidence'; Apply = {
            param($c)
            $c.hid.keyboards[0].verification_status = 'verified'
        } },
    @{ Name = 'tablet-scope'; Apply = { param($c) $c.scope.tablet = 'physical' } }
)
$storageMutations = @(
    @{ Name = 'storage-id'; Apply = { param($s) $s.id = 'bogus' } },
    @{ Name = 'storage-year-type'; Apply = {
            param($s)
            $s.release_year = 'never'
        } },
    @{ Name = 'storage-size-type'; Apply = {
            param($s)
            $s.raw_bytes = '512110190592'
        } }
)
$testRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ('vmate-manifest-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $testRoot)
try {
    Copy-Item -LiteralPath $storagePath `
        -Destination (Join-Path $testRoot $componentRoot.storage_catalog)
    Copy-Item -LiteralPath $gpuBoardPath `
        -Destination (Join-Path $testRoot $componentRoot.gpu_board_catalog)
    foreach ($case in $componentMutations) {
        $bad = $componentRoot | ConvertTo-Json -Depth 64 | ConvertFrom-Json
        & $case.Apply $bad
        $path = Join-Path $testRoot ($case.Name + '.json')
        $bad | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $path -Encoding UTF8
        Assert-VMateMutationRejected {
            [void](Read-VMateComponentManifest $path)
        } $case.Name
    }
    foreach ($case in $storageMutations) {
        $bad = $storageRoot.storage[0] |
            ConvertTo-Json -Depth 64 | ConvertFrom-Json
        & $case.Apply $bad
        Assert-VMateMutationRejected {
            Assert-VMateStorageComponent $bad
        } $case.Name
    }

    # 重复 property 必须在 ConvertFrom-Json 覆盖值前按 JSON 结构拒绝。三个用例
    # 分别覆盖根对象、SSD 深层 nvme 对象和 AIB GPU 条目；根用例还验证转义后
    # 等价的 property 名会像 Python object_pairs_hook 一样判为重复。
    $duplicateCases = @(
        @('root', '"schema_version": 1,',
            '"schema_version": 1, "\u0073chema_version": 1,'),
        @('storage', '"pcie_generation": 3,',
            '"pcie_generation": 3, "pcie_generation": 3,'),
        @('gpu', '"base_clock_khz": 1291000,',
            '"base_clock_khz": 1291000, "base_clock_khz": 1291000,')
    )
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    foreach ($duplicateCase in $duplicateCases) {
        $caseRoot = Join-Path $testRoot ('duplicate-' + $duplicateCase[0])
        [void](New-Item -ItemType Directory -Path $caseRoot)
        $rootText = $componentJson
        $storageText = $storageJson
        $gpuText = $gpuBoardJson
        switch ($duplicateCase[0]) {
            'root' {
                $rootText = $rootText.Replace(
                    $duplicateCase[1], $duplicateCase[2])
            }
            'storage' {
                $storageText = $storageText.Replace(
                    $duplicateCase[1], $duplicateCase[2])
            }
            'gpu' {
                $gpuText = $gpuText.Replace(
                    $duplicateCase[1], $duplicateCase[2])
            }
        }
        if ($rootText -ceq $componentJson -and
            $storageText -ceq $storageJson -and
            $gpuText -ceq $gpuBoardJson) {
            throw "重复 JSON fixture '$($duplicateCase[0])' 未命中。"
        }
        $caseComponentPath = Join-Path $caseRoot 'components.json'
        [IO.File]::WriteAllText($caseComponentPath, $rootText, $utf8)
        [IO.File]::WriteAllText(
            (Join-Path $caseRoot $componentRoot.storage_catalog),
            $storageText, $utf8)
        [IO.File]::WriteAllText(
            (Join-Path $caseRoot $componentRoot.gpu_board_catalog),
            $gpuText, $utf8)
        $duplicateRejected = $false
        try {
            [void](Read-VMateComponentManifest $caseComponentPath)
        } catch {
            if ($_.Exception.Message -notmatch '重复 JSON property') {
                throw "重复 JSON '$($duplicateCase[0])' 未在结构解析层拒绝：$($_.Exception.Message)"
            }
            $duplicateRejected = $true
        }
        if (-not $duplicateRejected) {
            throw "重复 JSON '$($duplicateCase[0])' 被静默覆盖。"
        }
    }
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}

Assert-VMateMutationRejected {
    [void](Get-VMateNvmeSubnqn `
        (Read-VMateComponentManifest $componentPath) `
        '00000000-0000-4000-8000-000000000000')
} 'placeholder-nqn-uuid'

Write-Output 'OK: Windows platform/component manifest mutation checks passed'
