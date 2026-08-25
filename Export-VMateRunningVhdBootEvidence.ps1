#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$VMName,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [Parameter(Mandatory = $true)][string]$ResultPath
)

$ErrorActionPreference = 'Stop'
Import-Module Hyper-V -ErrorAction Stop

$checkpoint = $null
$mounted = $false
$parentPath = $null
$checkpointTypeChanged = $false
$originalCheckpointType = $null
$result = [ordered]@{
    VMName = $VMName
    StartedAtUtc = [DateTime]::UtcNow.ToString('o')
    InitialState = ''
    ParentPath = ''
    ActiveChildPath = ''
    CheckpointName = ''
    InitialCheckpointType = ''
    CheckpointTypeRestored = $false
    BootSha256 = ''
    BootSize = 0
    CheckpointRemoved = $false
    Error = $null
}

try {
    $vm = Get-VM -Name $VMName -ErrorAction Stop
    $result.InitialState = [string]$vm.State
    $originalCheckpointType = $vm.CheckpointType
    $result.InitialCheckpointType = [string]$originalCheckpointType
    if ($vm.State -ne 'Running') {
        throw 'This audit path requires the VM to be running.'
    }
    $existing = @(Get-VMSnapshot -VM $vm -ErrorAction Stop)
    if ($existing.Count -ne 0) {
        throw 'Existing checkpoints make the temporary parent boundary ambiguous.'
    }
    $drives = @(Get-VMHardDiskDrive -VM $vm -ErrorAction Stop |
        Where-Object Path)
    if ($drives.Count -ne 1) {
        throw "Expected one attached VHD, found $($drives.Count)."
    }
    $parentPath = [string]$drives[0].Path
    $result.ParentPath = $parentPath
    if ([string]$originalCheckpointType -eq 'Disabled') {
        Set-VM -VM $vm -CheckpointType Standard -ErrorAction Stop
        $checkpointTypeChanged = $true
    }
    $checkpointName = 'VMateReadOnlyBootAudit-' +
        [DateTime]::UtcNow.ToString('yyyyMMddHHmmss')
    $result.CheckpointName = $checkpointName
    $checkpoint = Checkpoint-VM -VM $vm -SnapshotName $checkpointName `
        -Passthru -ErrorAction Stop

    $active = @(Get-VMHardDiskDrive -VMName $VMName -ErrorAction Stop |
        Where-Object Path)
    if ($active.Count -ne 1 -or
        [string]$active[0].Path -ieq $parentPath) {
        throw 'Checkpoint did not establish a distinct active child VHD.'
    }
    $result.ActiveChildPath = [string]$active[0].Path

    Mount-VHD -Path $parentPath -ReadOnly -ErrorAction Stop | Out-Null
    $mounted = $true
    $disk = Get-DiskImage -ImagePath $parentPath -ErrorAction Stop | Get-Disk
    $efiRoots = @()
    foreach ($partition in @($disk | Get-Partition -ErrorAction Stop)) {
        $volume = $partition | Get-Volume -ErrorAction SilentlyContinue
        if ($null -eq $volume -or
            [String]::IsNullOrWhiteSpace([string]$volume.Path)) { continue }
        $candidate = Join-Path ([string]$volume.Path) `
            'EFI\Microsoft\Boot\bootmgfw.efi'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $efiRoots += $candidate
        }
    }
    if ($efiRoots.Count -ne 1) {
        throw "Expected one EFI boot manager, found $($efiRoots.Count)."
    }
    Copy-Item -LiteralPath $efiRoots[0] -Destination $OutputPath -Force
    $item = Get-Item -LiteralPath $OutputPath -ErrorAction Stop
    $result.BootSize = [uint64]$item.Length
    $result.BootSha256 = [string](Get-FileHash -LiteralPath $OutputPath `
        -Algorithm SHA256 -ErrorAction Stop).Hash
}
catch {
    $result.Error = $_.Exception.Message
}
finally {
    if ($mounted) {
        try { Dismount-VHD -Path $parentPath -ErrorAction Stop }
        catch {
            if (-not $result.Error) {
                $result.Error = "Failed to dismount parent VHD: $($_.Exception.Message)"
            }
        }
    }
    if ($null -ne $checkpoint) {
        try {
            Remove-VMSnapshot -VMSnapshot $checkpoint -ErrorAction Stop
            $deadline = [DateTime]::UtcNow.AddMinutes(5)
            do {
                Start-Sleep -Milliseconds 500
                $remaining = @(Get-VMSnapshot -VMName $VMName `
                    -ErrorAction Stop | Where-Object Name -eq
                        $result.CheckpointName)
            } while ($remaining.Count -ne 0 -and
                [DateTime]::UtcNow -lt $deadline)
            $result.CheckpointRemoved = $remaining.Count -eq 0
            if (-not $result.CheckpointRemoved -and -not $result.Error) {
                $result.Error = 'Temporary checkpoint removal timed out.'
            }
        }
        catch {
            if (-not $result.Error) {
                $result.Error = "Failed to remove temporary checkpoint: $($_.Exception.Message)"
            }
        }
    }
    if ($checkpointTypeChanged) {
        try {
            Set-VM -Name $VMName -CheckpointType $originalCheckpointType `
                -ErrorAction Stop
            $result.CheckpointTypeRestored =
                [string](Get-VM -Name $VMName -ErrorAction Stop).CheckpointType `
                    -eq [string]$originalCheckpointType
        }
        catch {
            if (-not $result.Error) {
                $result.Error = "Failed to restore checkpoint type: $($_.Exception.Message)"
            }
        }
    }
    else {
        $result.CheckpointTypeRestored = $true
    }
    $result.FinishedAtUtc = [DateTime]::UtcNow.ToString('o')
    $result | ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath $ResultPath -Encoding UTF8
}

if ($result.Error) { exit 1 }
