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
$componentMutations = @(
    @{ Name = 'storage-id'; Apply = { param($c) $c.storage[0].id = 'bogus' } },
    @{ Name = 'storage-year-type'; Apply = {
            param($c)
            $c.storage[0].release_year = 'never'
        } },
    @{ Name = 'storage-size-type'; Apply = {
            param($c)
            $c.storage[0].raw_bytes = '512110190592'
        } },
    @{ Name = 'keyboard-id'; Apply = { param($c) $c.hid.keyboards[0].id = 'bogus' } },
    @{ Name = 'keyboard-evidence'; Apply = {
            param($c)
            $c.hid.keyboards[0].verification_status = 'verified'
        } },
    @{ Name = 'tablet-scope'; Apply = { param($c) $c.scope.tablet = 'physical' } }
)
$testRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ('vmate-manifest-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $testRoot)
try {
foreach ($case in $componentMutations) {
        $bad = $componentRoot | ConvertTo-Json -Depth 64 | ConvertFrom-Json
        & $case.Apply $bad
        $path = Join-Path $testRoot ($case.Name + '.json')
        $bad | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $path -Encoding UTF8
        Assert-VMateMutationRejected {
            [void](Read-VMateComponentManifest $path)
        } $case.Name
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
