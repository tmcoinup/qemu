#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string]$VMName = 'P11-Lab',
    [ValidateSet('Sample', 'Identity')][string]$Mode,
    [string]$SampleLoaderPath = 'C:\VMateLab\pc01-custom-bootmgfw.efi',
    [string]$OutputPath = 'C:\VMateLab\p11-boot-experiment.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$vm = Get-VM -Name $VMName -ErrorAction Stop
if ($vm.State -ne 'Off') {
    throw "VM '$VMName' must be Off; current state is $($vm.State)."
}
$systemDrives = @(Get-VMHardDiskDrive -VM $vm | Where-Object {
        $_.ControllerLocation -eq 0
    })
if ($systemDrives.Count -ne 1) {
    throw 'Unable to resolve exactly one system VHD.'
}

$vhdPath = [string]$systemDrives[0].Path
$mounted = $false
try {
    $disk = Mount-VHD -Path $vhdPath -ReadOnly:$false -Passthru
    $mounted = $true
    Set-Disk -Number $disk.DiskNumber -IsOffline $false -ErrorAction Stop
    Set-Disk -Number $disk.DiskNumber -IsReadOnly $false -ErrorAction Stop
    $esp = @(Get-Partition -DiskNumber $disk.DiskNumber | Where-Object {
            [string]$_.GptType -ieq `
                '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
        })
    if ($esp.Count -ne 1) {
        throw 'Unable to resolve exactly one EFI system partition.'
    }
    $volume = $esp[0] | Get-Volume -ErrorAction Stop
    $efiRoot = Join-Path ([string]$volume.Path) 'EFI'
    $bootPath = Join-Path $efiRoot 'Microsoft\Boot\bootmgfw.efi'
    $vmateRoot = Join-Path $efiRoot 'VMate'
    $identityPath = Join-Path $vmateRoot 'bootmgfw.vmate-identity.efi'
    $identityManifestPath = Join-Path $vmateRoot 'identity-manifest.json'
    $experimentManifestPath = Join-Path $vmateRoot `
        'sample-loader-experiment.json'
    if (-not (Test-Path -LiteralPath $bootPath -PathType Leaf)) {
        throw 'Current EFI boot manager is missing.'
    }
    if (-not (Test-Path -LiteralPath $identityManifestPath -PathType Leaf)) {
        throw 'VMate identity manifest is missing.'
    }
    $identityManifest = Get-Content -LiteralPath $identityManifestPath `
        -Raw -Encoding UTF8 | ConvertFrom-Json
    $expectedIdentityHash = [string]$identityManifest.ExtensionSha256
    if ([String]::IsNullOrWhiteSpace($expectedIdentityHash)) {
        throw 'VMate identity manifest has no ExtensionSha256.'
    }

    $beforeHash = (Get-FileHash -LiteralPath $bootPath `
        -Algorithm SHA256).Hash
    if ($Mode -eq 'Sample') {
        if (-not (Test-Path -LiteralPath $SampleLoaderPath -PathType Leaf)) {
            throw "Sample loader is missing: $SampleLoaderPath"
        }
        if ($beforeHash -cne $expectedIdentityHash) {
            throw 'Current loader does not match the VMate identity manifest.'
        }
        New-Item -ItemType Directory -Path $vmateRoot -Force | Out-Null
        Copy-Item -LiteralPath $bootPath -Destination $identityPath -Force
        $savedHash = (Get-FileHash -LiteralPath $identityPath `
            -Algorithm SHA256).Hash
        if ($savedHash -cne $expectedIdentityHash) {
            throw 'Saved identity loader failed integrity verification.'
        }
        $targetHash = (Get-FileHash -LiteralPath $SampleLoaderPath `
            -Algorithm SHA256).Hash
        Copy-Item -LiteralPath $SampleLoaderPath -Destination $bootPath -Force
        if ((Get-FileHash -LiteralPath $bootPath -Algorithm SHA256).Hash `
                -cne $targetHash) {
            throw 'Sample loader failed post-copy verification.'
        }
        [pscustomobject][ordered]@{
            SchemaVersion = 1
            VMName = $VMName
            IdentitySha256 = $expectedIdentityHash
            SampleSha256 = $targetHash
            StagedAtUtc = [DateTime]::UtcNow.ToString('o')
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath `
            $experimentManifestPath -Encoding UTF8
    }
    else {
        if (-not (Test-Path -LiteralPath $identityPath -PathType Leaf)) {
            throw 'Saved VMate identity loader is missing.'
        }
        $savedHash = (Get-FileHash -LiteralPath $identityPath `
            -Algorithm SHA256).Hash
        if ($savedHash -cne $expectedIdentityHash) {
            throw 'Saved identity loader does not match its manifest.'
        }
        Copy-Item -LiteralPath $identityPath -Destination $bootPath -Force
        if ((Get-FileHash -LiteralPath $bootPath -Algorithm SHA256).Hash `
                -cne $expectedIdentityHash) {
            throw 'Identity loader failed post-copy verification.'
        }
    }

    $afterHash = (Get-FileHash -LiteralPath $bootPath `
        -Algorithm SHA256).Hash
    $result = [pscustomobject][ordered]@{
        SchemaVersion = 1
        VMName = $VMName
        Mode = $Mode
        BeforeSha256 = $beforeHash
        AfterSha256 = $afterHash
        ExpectedIdentitySha256 = $expectedIdentityHash
        TimestampUtc = [DateTime]::UtcNow.ToString('o')
    }
    $result | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath `
        $OutputPath -Encoding UTF8
    $result
}
finally {
    if ($mounted) {
        Dismount-VHD -Path $vhdPath -ErrorAction Stop
    }
}
