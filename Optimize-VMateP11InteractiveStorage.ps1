#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$VMName = 'P11-Lab',
    [string]$DestinationPath =
        'C:\VMateLab\P11-Lab\P11-Lab-1MiB.vhdx',
    [string]$ResultPath =
        'C:\VMateLab\p11-interactive-storage-optimization.json',
    [switch]$ReuseVerifiedDestination
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Save-Result {
    param([hashtable]$Record)
    $Record.UpdatedAtUtc = [DateTime]::UtcNow.ToString('o')
    [pscustomobject]$Record | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath $ResultPath -Encoding UTF8
}

function Request-GracefulVmShutdown {
    param([object]$VM)
    $computerSystem = Get-CimInstance `
        -Namespace 'root/virtualization/v2' `
        -ClassName Msvm_ComputerSystem -ErrorAction Stop |
        Where-Object { [string]$_.Name -ceq $VM.Id.ToString('D') -or
            [string]$_.ElementName -ceq [string]$VM.Name } |
        Select-Object -First 1
    if ($null -eq $computerSystem) {
        throw 'unable to resolve Hyper-V computer system.'
    }
    $shutdown = Invoke-CimMethod -InputObject $computerSystem `
        -MethodName RequestStateChange `
        -Arguments @{ RequestedState = [uint16]4 } -ErrorAction Stop
    if ([uint32]$shutdown.ReturnValue -notin @(0, 4096)) {
        throw "graceful shutdown returned $($shutdown.ReturnValue)."
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(90)
    do {
        Start-Sleep -Milliseconds 500
        $VM = Get-VM -Id $VM.Id -ErrorAction Stop
    } while ([string]$VM.State -cne 'Off' -and
        [DateTime]::UtcNow -lt $deadline)
    if ([string]$VM.State -cne 'Off') {
        throw 'graceful shutdown timed out; no force-off attempted.'
    }
    return $VM
}

function Wait-VMateHeartbeat {
    param([string]$Name, [int]$TimeoutSeconds = 120)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Seconds 1
        $heartbeat = Get-VMIntegrationService -VMName $Name `
            -ErrorAction SilentlyContinue |
            Where-Object { [string]$_.Id -match
                '84EAAE65-2F2E-45F5-9BB5-0E857DC8EB47$' } |
            Select-Object -First 1
    } while (($null -eq $heartbeat -or
            [uint16]$heartbeat.PrimaryOperationalStatus -ne 2) -and
        [DateTime]::UtcNow -lt $deadline)
    return $null -ne $heartbeat -and
        [uint16]$heartbeat.PrimaryOperationalStatus -eq 2
}

$vm = Get-VM -Name $VMName -ErrorAction Stop
$systemDrive = @(Get-VMHardDiskDrive -VM $vm -ErrorAction Stop |
    Where-Object { $_.ControllerNumber -eq 0 -and
        $_.ControllerLocation -eq 0 })
if ($systemDrive.Count -ne 1) { throw 'unable to resolve one system VHD.' }
$oldPath = [IO.Path]::GetFullPath([string]$systemDrive[0].Path)
$newPath = [IO.Path]::GetFullPath($DestinationPath)
if ([string]::Equals($oldPath, $newPath,
        [StringComparison]::OrdinalIgnoreCase)) {
    throw 'destination VHD must differ from the current system VHD.'
}
$destinationExists = Test-Path -LiteralPath $newPath -PathType Leaf
if ($destinationExists -and -not $ReuseVerifiedDestination) {
    throw "destination already exists; pass -ReuseVerifiedDestination after verification: $newPath"
}
$oldVhd = Get-VHD -Path $oldPath -ErrorAction Stop
if ([uint32]$oldVhd.BlockSize -eq 1MB -and [string]$vm.Version -ceq '9.2') {
    throw 'P11-Lab already has the target block size and VM version.'
}
$existingNewVhd = $null
if ($destinationExists) {
    $attachedPaths = @(Get-VM | Get-VMHardDiskDrive |
        ForEach-Object { [IO.Path]::GetFullPath([string]$_.Path) })
    if (@($attachedPaths | Where-Object { [string]::Equals($_, $newPath,
                    [StringComparison]::OrdinalIgnoreCase) }).Count -ne 0) {
        throw 'verified destination is already attached to a VM.'
    }
    $existingNewVhd = Get-VHD -Path $newPath -ErrorAction Stop
    if ([uint32]$existingNewVhd.BlockSize -ne 1MB -or
        [uint64]$existingNewVhd.Size -ne [uint64]$oldVhd.Size) {
        throw 'existing destination failed geometry verification.'
    }
}
else {
    $freeBytes = (Get-Volume -DriveLetter `
            ([IO.Path]::GetPathRoot($newPath).TrimEnd(':\'))).SizeRemaining
    if ([uint64]$freeBytes -lt ([uint64]$oldVhd.FileSize + 10GB)) {
        throw 'insufficient free space for a rollback-preserving VHD conversion.'
    }
}

$wasRunning = [string]$vm.State -ceq 'Running'
$attachedNew = $false
$result = [ordered]@{
    SchemaVersion = 1
    VMName = $VMName
    VMId = $vm.Id.ToString('D')
    StartedAtUtc = [DateTime]::UtcNow.ToString('o')
    Stage = 'Preflight'
    OldPath = $oldPath
    NewPath = $newPath
    OldVersion = [string]$vm.Version
    NewVersion = $null
    VersionUpdateStatus = 'NotAttempted'
    OldVhd = $oldVhd | Select-Object Path, VhdType, FileSize, Size,
        BlockSize, FragmentationPercentage, LogicalSectorSize,
        PhysicalSectorSize
    NewVhd = $null
    GracefulShutdown = $false
    Converted = [bool]$destinationExists
    AttachedNew = $false
    VersionUpdated = $false
    Restarted = $false
    Heartbeat = $false
    Rollback = $null
    Error = $null
}
Save-Result $result

try {
    if ($wasRunning) {
        $result.Stage = 'GracefulShutdown'
        Save-Result $result
        $vm = Request-GracefulVmShutdown $vm
        $result.GracefulShutdown = $true
    }
    elseif ([string]$vm.State -cne 'Off') {
        throw "VM state is not safe for conversion: $($vm.State)"
    }

    if (-not $destinationExists) {
        $result.Stage = 'ConvertVhd'
        Save-Result $result
        Convert-VHD -Path $oldPath -DestinationPath $newPath `
            -VHDType Dynamic -BlockSizeBytes 1MB -ErrorAction Stop
    }
    $newVhd = if ($null -ne $existingNewVhd) { $existingNewVhd } else {
        Get-VHD -Path $newPath -ErrorAction Stop
    }
    if ([uint32]$newVhd.BlockSize -ne 1MB -or
        [uint64]$newVhd.Size -ne [uint64]$oldVhd.Size) {
        throw 'converted VHD geometry verification failed.'
    }
    $result.Converted = $true
    $result.NewVhd = $newVhd | Select-Object Path, VhdType, FileSize, Size,
        BlockSize, FragmentationPercentage, LogicalSectorSize,
        PhysicalSectorSize

    $result.Stage = 'AttachAndUpgrade'
    Save-Result $result
    Set-VMHardDiskDrive -VMHardDiskDrive $systemDrive[0] `
        -Path $newPath -ErrorAction Stop
    $attachedNew = $true
    $result.AttachedNew = $true
    $vm = Get-VM -Id $vm.Id -ErrorAction Stop
    if ([string]$vm.Version -cne '9.2') {
        Update-VMVersion -VM $vm -Force -Confirm:$false `
            -ErrorAction Stop | Out-Null
    }
    $vm = Get-VM -Id $vm.Id -ErrorAction Stop
    $result.NewVersion = [string]$vm.Version
    if ($result.NewVersion -ceq '9.2') {
        $result.VersionUpdated = $result.OldVersion -cne '9.2'
        $result.VersionUpdateStatus = if ($result.VersionUpdated) {
            'UpgradedTo9.2'
        } else { 'Already9.2' }
    }
    else {
        $result.VersionUpdateStatus =
            "HostUpdateVmVersionRefusedTarget9.2; remains $($result.NewVersion)"
    }

    $result.Stage = 'RestartAndVerify'
    Save-Result $result
    Start-VM -VM $vm -ErrorAction Stop | Out-Null
    $result.Restarted = $true
    $result.Heartbeat = Wait-VMateHeartbeat -Name $VMName -TimeoutSeconds 120
    if (-not $result.Heartbeat) {
        throw 'heartbeat did not become healthy after storage conversion.'
    }
    $result.Stage = 'Complete'
}
catch {
    $result.Error = $_.Exception.Message
    if ($attachedNew) {
        try {
            $rollbackVm = Get-VM -Id $vm.Id -ErrorAction Stop
            if ([string]$rollbackVm.State -ne 'Off') {
                Stop-VM -VM $rollbackVm -TurnOff -Force -Confirm:$false `
                    -ErrorAction Stop
            }
            $rollbackDrive = Get-VMHardDiskDrive -VM $rollbackVm |
                Where-Object { $_.ControllerNumber -eq 0 -and
                    $_.ControllerLocation -eq 0 } | Select-Object -First 1
            Set-VMHardDiskDrive -VMHardDiskDrive $rollbackDrive `
                -Path $oldPath -ErrorAction Stop
            Start-VM -VM $rollbackVm -ErrorAction Stop | Out-Null
            $result.Rollback = 'Old VHD reattached and VM restarted.'
        }
        catch {
            $result.Rollback = 'FAILED: ' + $_.Exception.Message
        }
    }
    elseif ($wasRunning) {
        $rollbackVm = Get-VM -Id $vm.Id -ErrorAction SilentlyContinue
        if ($null -ne $rollbackVm -and [string]$rollbackVm.State -eq 'Off') {
            try {
                Start-VM -VM $rollbackVm -ErrorAction Stop | Out-Null
                $result.Rollback = 'Original VM restarted.'
            }
            catch { $result.Rollback = 'FAILED: ' + $_.Exception.Message }
        }
    }
    $result.Stage = 'Failed'
}
finally {
    $result.FinishedAtUtc = [DateTime]::UtcNow.ToString('o')
    Save-Result $result
}

[pscustomobject]$result
if (-not [String]::IsNullOrWhiteSpace([string]$result.Error)) { exit 1 }
