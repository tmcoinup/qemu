#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string]$VMName = 'P11-Lab',
    [Parameter(Mandatory = $true)]
    [ValidateSet('Sample', 'Identity')][string]$Mode,
    [ValidateRange(4096, 16777216)][int]$PlaceholderLength = 954368,
    [string]$OutputPath =
        'C:\VMateLab\p11-sample-placeholder-experiment.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$vm = Get-VM -Name $VMName -ErrorAction Stop
if ([string]$vm.State -cne 'Off') {
    throw "VM '$VMName' must be Off; current state is $($vm.State)."
}
$systemDrives = @(Get-VMHardDiskDrive -VM $vm -ErrorAction Stop |
    Where-Object ControllerLocation -eq 0)
if ($systemDrives.Count -ne 1) {
    throw 'Unable to resolve exactly one system VHD.'
}

$vhdPath = [string]$systemDrives[0].Path
$mounted = $false
try {
    $disk = Mount-VHD -Path $vhdPath -ReadOnly:$false -Passthru `
        -ErrorAction Stop
    $mounted = $true
    Set-Disk -Number $disk.DiskNumber -IsOffline $false -ErrorAction Stop
    Set-Disk -Number $disk.DiskNumber -IsReadOnly $false -ErrorAction Stop
    $esp = @(Get-Partition -DiskNumber $disk.DiskNumber -ErrorAction Stop |
        Where-Object {
            [string]$_.GptType -ieq
                '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
        })
    if ($esp.Count -ne 1) {
        throw 'Unable to resolve exactly one EFI system partition.'
    }
    $volume = $esp[0] | Get-Volume -ErrorAction Stop
    $efiRoot = Join-Path ([string]$volume.Path) 'EFI'
    $payloadPath = Join-Path $efiRoot `
        'Microsoft\Boot\ja-JP\bootmgfw.efi.mui'
    $vmateRoot = Join-Path $efiRoot 'VMate'
    $backupPath = Join-Path $vmateRoot `
        'sample-ja-JP-bootmgfw.efi.mui.original'
    $manifestPath = Join-Path $vmateRoot `
        'sample-placeholder-manifest.json'
    New-Item -ItemType Directory -Path $vmateRoot -Force | Out-Null

    if ($Mode -ceq 'Sample') {
        $existingManifest = if (Test-Path -LiteralPath $manifestPath `
                -PathType Leaf) {
            Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 |
                ConvertFrom-Json -ErrorAction Stop
        } else { $null }
        if ($null -ne $existingManifest -and
            [string]$existingManifest.State -ceq 'Staged') {
            throw 'A sample placeholder is already staged.'
        }
        $originalExists = Test-Path -LiteralPath $payloadPath -PathType Leaf
        $originalHash = if ($originalExists) {
            [string](Get-FileHash -LiteralPath $payloadPath -Algorithm SHA256 `
                    -ErrorAction Stop).Hash
        } else { '' }
        $originalLength = if ($originalExists) {
            [uint64](Get-Item -LiteralPath $payloadPath `
                    -ErrorAction Stop).Length
        } else { 0 }
        if ($originalExists) {
            if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
                $backupHash = [string](Get-FileHash -LiteralPath $backupPath `
                        -Algorithm SHA256 -ErrorAction Stop).Hash
                if ($backupHash -cne $originalHash) {
                    throw 'Existing placeholder backup does not match the current original.'
                }
            }
            else {
                Copy-Item -LiteralPath $payloadPath -Destination $backupPath `
                    -ErrorAction Stop
            }
        }
        $payloadDirectory = [IO.Path]::GetDirectoryName($payloadPath)
        [IO.Directory]::CreateDirectory($payloadDirectory) | Out-Null
        $stream = [IO.File]::Open($payloadPath, [IO.FileMode]::Create,
            [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.SetLength($PlaceholderLength) }
        finally { $stream.Dispose() }
        $placeholderHash = [string](Get-FileHash -LiteralPath $payloadPath `
                -Algorithm SHA256 -ErrorAction Stop).Hash
        $manifest = [pscustomobject][ordered]@{
            SchemaVersion = 1
            VMName = $VMName
            State = 'Staged'
            RelativePath = 'EFI\Microsoft\Boot\ja-JP\bootmgfw.efi.mui'
            OriginalExists = [bool]$originalExists
            OriginalLength = $originalLength
            OriginalSha256 = $originalHash
            PlaceholderLength = $PlaceholderLength
            PlaceholderSha256 = $placeholderHash
            StagedAtUtc = [DateTime]::UtcNow.ToString('o')
            RestoredAtUtc = ''
        }
        $manifest | ConvertTo-Json -Depth 4 |
            Set-Content -LiteralPath $manifestPath -Encoding UTF8
        $result = $manifest
    }
    else {
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            throw 'Sample placeholder manifest is missing.'
        }
        $manifest = Get-Content -LiteralPath $manifestPath -Raw `
            -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        if ([int]$manifest.SchemaVersion -ne 1 -or
            [string]$manifest.VMName -cne $VMName -or
            [string]$manifest.State -cne 'Staged') {
            throw 'Sample placeholder manifest is not in the staged state.'
        }
        if (-not (Test-Path -LiteralPath $payloadPath -PathType Leaf)) {
            throw 'Staged sample placeholder is missing.'
        }
        $currentHash = [string](Get-FileHash -LiteralPath $payloadPath `
                -Algorithm SHA256 -ErrorAction Stop).Hash
        if ($currentHash -cne [string]$manifest.PlaceholderSha256 -or
            [uint64](Get-Item -LiteralPath $payloadPath).Length -ne
                [uint64]$manifest.PlaceholderLength) {
            throw 'Staged sample placeholder failed integrity verification.'
        }
        if ([bool]$manifest.OriginalExists) {
            if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
                throw 'Original sample placeholder backup is missing.'
            }
            $backupHash = [string](Get-FileHash -LiteralPath $backupPath `
                    -Algorithm SHA256 -ErrorAction Stop).Hash
            if ($backupHash -cne [string]$manifest.OriginalSha256) {
                throw 'Original sample placeholder backup failed verification.'
            }
            Copy-Item -LiteralPath $backupPath -Destination $payloadPath `
                -Force -ErrorAction Stop
            if ([string](Get-FileHash -LiteralPath $payloadPath `
                        -Algorithm SHA256).Hash -cne
                    [string]$manifest.OriginalSha256) {
                throw 'Restored sample placeholder original failed verification.'
            }
        }
        else {
            Remove-Item -LiteralPath $payloadPath -Force -ErrorAction Stop
            if (Test-Path -LiteralPath $payloadPath) {
                throw 'Sample placeholder removal did not persist.'
            }
        }
        $manifest.State = 'Restored'
        $manifest.RestoredAtUtc = [DateTime]::UtcNow.ToString('o')
        $manifest | ConvertTo-Json -Depth 4 |
            Set-Content -LiteralPath $manifestPath -Encoding UTF8
        $result = $manifest
    }

    $result | ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath $OutputPath -Encoding UTF8
    $result
}
finally {
    if ($mounted) {
        Dismount-VHD -Path $vhdPath -ErrorAction Stop
    }
}
