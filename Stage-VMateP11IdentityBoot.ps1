#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$VMName = 'P11-Lab',
    [string]$ExtensionPath = 'C:\VMateLab\VMateIdentityBoot.efi',
    [string]$ConfigPath = 'C:\VMateLab\p11-identity.ini',
    [switch]$AllowDisableSecureBoot,
    [switch]$AllowNoCheckpointForGpuP
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$resultPath = 'C:\VMateLab\p11-identity-stage-result.json'
$result = [ordered]@{
    VMName = $VMName
    StartedAt = [DateTime]::Now.ToString('o')
    GracefulShutdown = $false
    CheckpointName = $null
    CheckpointTypeWas = $null
    CheckpointSkippedReason = $null
    SecureBootWasEnabled = $false
    SecureBootDisabled = $false
    Installed = $false
    Restarted = $false
    StockHash = $null
    ExtensionHash = $null
    Error = $null
}
$mounted = $false
$accessPath = $null
$bootPath = $null
$backupPath = $null
$stockCopied = $false
$disk = $null
$drives = $null
$esp = $null
$secureBootChanged = $false

try {
    foreach ($path in @($ExtensionPath, $ConfigPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "staging input missing: $path"
        }
    }
    $vm = Get-VM -Name $VMName -ErrorAction Stop
    if ($vm.Generation -ne 2) { throw 'identity boot extension requires Generation 2.' }
    $secureBootWasEnabled = [string](Get-VMFirmware -VM $vm).SecureBoot -eq 'On'
    $result.SecureBootWasEnabled = $secureBootWasEnabled
    if ($secureBootWasEnabled -and -not $AllowDisableSecureBoot) {
        throw 'Secure Boot is enabled; pass -AllowDisableSecureBoot explicitly.'
    }
    if ($vm.State -eq 'Running') {
        $computerSystem = Get-CimInstance `
            -Namespace 'root/virtualization/v2' `
            -ClassName Msvm_ComputerSystem -ErrorAction Stop |
            Where-Object ElementName -eq $VMName | Select-Object -First 1
        if ($null -eq $computerSystem) {
            throw 'unable to resolve Hyper-V computer system for shutdown.'
        }
        $shutdown = Invoke-CimMethod -InputObject $computerSystem `
            -MethodName RequestStateChange `
            -Arguments @{ RequestedState = [uint16]4 } -ErrorAction Stop
        if ($shutdown.ReturnValue -notin @(0, 4096)) {
            throw "graceful shutdown returned $($shutdown.ReturnValue)."
        }
        $deadline = [DateTime]::UtcNow.AddSeconds(60)
        do {
            Start-Sleep -Milliseconds 500
            $vm = Get-VM -Name $VMName
        } while ($vm.State -ne 'Off' -and [DateTime]::UtcNow -lt $deadline)
        if ($vm.State -ne 'Off') { throw 'graceful shutdown timed out.' }
        $result.GracefulShutdown = $true
    }
    elseif ($vm.State -ne 'Off') {
        throw "VM must be Running or Off; state=$($vm.State)."
    }

    $checkpointName = 'VMate-Before-IdentityBoot-' +
        [DateTime]::Now.ToString('yyyyMMdd-HHmmss')
    $checkpointTypeWas = [string]$vm.CheckpointType
    $result.CheckpointTypeWas = $checkpointTypeWas
    if ($checkpointTypeWas -eq 'Disabled') {
        Set-VM -VM $vm -CheckpointType Standard -ErrorAction Stop
    }
    $checkpointCreated = $false
    try {
        try {
            Checkpoint-VM -VM $vm -SnapshotName $checkpointName `
                -ErrorAction Stop
            $checkpointCreated = $true
        }
        catch {
            if (-not $AllowNoCheckpointForGpuP) { throw }
            $result.CheckpointSkippedReason = $_.Exception.Message
        }
    }
    finally {
        if ($checkpointTypeWas -eq 'Disabled') {
            Set-VM -VM $vm -CheckpointType Disabled -ErrorAction Stop
        }
    }
    if ($checkpointCreated) { $result.CheckpointName = $checkpointName }
    if ($secureBootWasEnabled) {
        Set-VMFirmware -VM $vm -EnableSecureBoot Off -ErrorAction Stop
        $secureBootChanged = $true
        $result.SecureBootDisabled = $true
    }

    $drives = @(Get-VMHardDiskDrive -VM $vm | Where-Object {
            $_.ControllerLocation -eq 0
        })
    if ($drives.Count -ne 1) { throw 'unable to resolve one system VHD.' }
    $disk = Mount-VHD -Path $drives[0].Path -ReadOnly:$false -Passthru
    $mounted = $true
    Set-Disk -Number $disk.DiskNumber -IsOffline $false -ErrorAction Stop
    Set-Disk -Number $disk.DiskNumber -IsReadOnly $false -ErrorAction Stop
    $esp = @(Get-Partition -DiskNumber $disk.DiskNumber | Where-Object {
            [string]$_.GptType -ieq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
        })
    if ($esp.Count -ne 1) { throw 'unable to resolve one EFI system partition.' }
    $espVolume = $esp[0] | Get-Volume -ErrorAction Stop
    if ([String]::IsNullOrWhiteSpace([string]$espVolume.Path)) {
        throw 'EFI system partition has no volume path.'
    }
    $efiRoot = Join-Path ([string]$espVolume.Path) 'EFI'
    $bootPath = Join-Path $efiRoot 'Microsoft\Boot\bootmgfw.efi'
    $backupPath = Join-Path $efiRoot `
        'Microsoft\Boot\bootmgfw.vmate-stock.efi'
    if (-not (Test-Path -LiteralPath $bootPath -PathType Leaf)) {
        throw 'stock Windows boot manager is missing.'
    }
    if (Test-Path -LiteralPath $backupPath) {
        throw 'identity boot backup already exists; refusing ambiguous install.'
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $bootPath
    if ($signature.Status -ne 'Valid' -or
        [string]$signature.SignerCertificate.Subject -notmatch 'Microsoft') {
        throw 'current boot manager is not a valid Microsoft-signed image.'
    }
    $stockHash = (Get-FileHash -LiteralPath $bootPath -Algorithm SHA256).Hash
    $extensionHash = (Get-FileHash -LiteralPath $ExtensionPath `
        -Algorithm SHA256).Hash
    $result.StockHash = $stockHash
    $result.ExtensionHash = $extensionHash

    Copy-Item -LiteralPath $bootPath -Destination $backupPath -ErrorAction Stop
    $stockCopied = $true
    $vmateRoot = Join-Path $efiRoot 'VMate'
    New-Item -ItemType Directory -Path $vmateRoot -Force | Out-Null
    Copy-Item -LiteralPath $ConfigPath `
        -Destination (Join-Path $vmateRoot 'identity.ini') -Force
    Copy-Item -LiteralPath $ExtensionPath -Destination $bootPath -Force
    $observedExtension = (Get-FileHash -LiteralPath $bootPath `
        -Algorithm SHA256).Hash
    $observedStock = (Get-FileHash -LiteralPath $backupPath `
        -Algorithm SHA256).Hash
    if ($observedExtension -cne $extensionHash -or
        $observedStock -cne $stockHash) {
        throw 'post-copy integrity verification failed.'
    }
    [pscustomobject][ordered]@{
        SchemaVersion = 1
        VMId = $vm.Id.ToString('D')
        StockPath = '\EFI\Microsoft\Boot\bootmgfw.vmate-stock.efi'
        StockSha256 = $stockHash
        ExtensionSha256 = $extensionHash
        SecureBootWasEnabled = $secureBootWasEnabled
        InstalledAt = [DateTime]::Now.ToString('o')
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath `
        (Join-Path $vmateRoot 'identity-manifest.json') -Encoding UTF8
    $result.Installed = $true
}
catch {
    $result.Error = $_.Exception.Message
    if ($stockCopied -and $null -ne $bootPath -and
        $null -ne $backupPath -and (Test-Path -LiteralPath $backupPath)) {
        Copy-Item -LiteralPath $backupPath -Destination $bootPath -Force
    }
    if ($secureBootChanged -and -not $result.Installed) {
        try {
            Set-VMFirmware -VMName $VMName -EnableSecureBoot On `
                -ErrorAction Stop
            $result.SecureBootDisabled = $false
        } catch {}
    }
}
finally {
    if ($null -ne $accessPath -and $null -ne $esp) {
        try {
            Remove-PartitionAccessPath -DiskNumber $disk.DiskNumber `
                -PartitionNumber $esp[0].PartitionNumber `
                -AccessPath $accessPath -ErrorAction Stop
        } catch {}
    }
    if ($mounted) {
        try { Dismount-VHD -Path $drives[0].Path -ErrorAction Stop } catch {
            if ([String]::IsNullOrWhiteSpace([string]$result.Error)) {
                $result.Error = $_.Exception.Message
            }
        }
    }
    if ($result.Installed -and
        [String]::IsNullOrWhiteSpace([string]$result.Error)) {
        try {
            Start-VM -Name $VMName -ErrorAction Stop | Out-Null
            $result.Restarted = $true
        }
        catch { $result.Error = $_.Exception.Message }
    }
    $result.FinishedAt = [DateTime]::Now.ToString('o')
    [pscustomobject]$result | ConvertTo-Json -Depth 6 |
        Set-Content -LiteralPath $resultPath -Encoding UTF8
}

[pscustomobject]$result
