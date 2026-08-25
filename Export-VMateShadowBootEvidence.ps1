#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$VMName,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [Parameter(Mandatory = $true)][string]$ResultPath,
    [ValidatePattern('^[A-Za-z0-9_.\\-]+$')]
    [string]$RelativePath = 'EFI\Microsoft\Boot\bootmgfw.efi'
)

$ErrorActionPreference = 'Stop'
Import-Module Hyper-V -ErrorAction Stop

$shadow = $null
$mounted = $false
$shadowVhdPath = ''
$shadowLinkPath = ''
$temporaryVhdPath = ''
$result = [ordered]@{
    SchemaVersion = 1
    VMName = $VMName
    StartedAtUtc = [DateTime]::UtcNow.ToString('o')
    InitialState = ''
    LiveVhdPath = ''
    ShadowId = ''
    ShadowDevice = ''
    ShadowVhdPath = ''
    ShadowLinkPath = ''
    TemporaryVhdPath = ''
    TemporaryVhdDeleted = $false
    RelativePath = $RelativePath
    BootSize = 0
    BootSha256 = ''
    ShadowDeleted = $false
    Error = $null
}

try {
    $vm = Get-VM -Name $VMName -ErrorAction Stop
    $result.InitialState = [string]$vm.State
    if ($vm.State -ne 'Running') {
        throw 'Shadow-copy audit expects the sample VM to remain running.'
    }
    $drives = @(Get-VMHardDiskDrive -VM $vm -ErrorAction Stop |
        Where-Object Path)
    if ($drives.Count -ne 1) {
        throw "Expected one attached VHD, found $($drives.Count)."
    }
    $livePath = [IO.Path]::GetFullPath([string]$drives[0].Path)
    $result.LiveVhdPath = $livePath
    $volumeRoot = [IO.Path]::GetPathRoot($livePath)
    if ([String]::IsNullOrWhiteSpace($volumeRoot)) {
        throw 'Could not resolve the VHD host volume.'
    }

    $shadowClass = Get-WmiObject -List Win32_ShadowCopy -ErrorAction Stop
    $created = $shadowClass.Create($volumeRoot, 'ClientAccessible')
    if ([uint32]$created.ReturnValue -ne 0 -or
        [String]::IsNullOrWhiteSpace([string]$created.ShadowID)) {
        throw "VSS shadow creation returned $($created.ReturnValue)."
    }
    $result.ShadowId = [string]$created.ShadowID
    $shadow = Get-WmiObject Win32_ShadowCopy -Filter (
        "ID='" + [string]$created.ShadowID + "'") -ErrorAction Stop
    if ($null -eq $shadow) { throw 'Created VSS shadow was not found.' }
    $result.ShadowDevice = [string]$shadow.DeviceObject
    $shadowLinkPath = Join-Path 'C:\VMateLab' (
        'vmate-shadow-' + ([Guid]$created.ShadowID).ToString('N'))
    $result.ShadowLinkPath = $shadowLinkPath
    if (Test-Path -LiteralPath $shadowLinkPath) {
        throw 'Refusing to replace an existing VSS shadow link.'
    }
    $mklink = Start-Process -FilePath $env:ComSpec -ArgumentList @(
        '/d', '/c', 'mklink', '/d', $shadowLinkPath,
        ([string]$shadow.DeviceObject + '\')) -Wait -PassThru `
        -WindowStyle Hidden
    if ($mklink.ExitCode -ne 0 -or
        -not (Test-Path -LiteralPath $shadowLinkPath -PathType Container)) {
        throw "VSS shadow link creation failed with $($mklink.ExitCode)."
    }
    $relative = $livePath.Substring($volumeRoot.Length).TrimStart('\')
    $shadowVhdPath = Join-Path $shadowLinkPath $relative
    $result.ShadowVhdPath = $shadowVhdPath
    if (-not (Test-Path -LiteralPath $shadowVhdPath -PathType Leaf)) {
        throw 'VHD file is not visible in the VSS shadow.'
    }

    $temporaryVhdPath = Join-Path 'C:\VMateLab' (
        'vmate-shadow-copy-' + ([Guid]$created.ShadowID).ToString('N') +
        [IO.Path]::GetExtension($livePath))
    $result.TemporaryVhdPath = $temporaryVhdPath
    if (Test-Path -LiteralPath $temporaryVhdPath) {
        throw 'Refusing to replace an existing temporary shadow VHD copy.'
    }
    Copy-Item -LiteralPath $shadowVhdPath -Destination $temporaryVhdPath `
        -ErrorAction Stop
    $image = Mount-VHD -Path $temporaryVhdPath -Passthru -ErrorAction Stop
    $mounted = $true
    $disk = $image | Get-Disk -ErrorAction Stop
    $bootManagers = @()
    foreach ($partition in @($disk | Get-Partition -ErrorAction Stop)) {
        $volume = $partition | Get-Volume -ErrorAction SilentlyContinue
        if ($null -eq $volume -or
            [String]::IsNullOrWhiteSpace([string]$volume.Path)) { continue }
        $candidate = Join-Path ([string]$volume.Path) $RelativePath
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $bootManagers += $candidate
        }
    }
    if ($bootManagers.Count -ne 1) {
        throw "Expected one $RelativePath file, found $($bootManagers.Count)."
    }
    Copy-Item -LiteralPath $bootManagers[0] -Destination $OutputPath -Force
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
        try { Dismount-VHD -Path $temporaryVhdPath -ErrorAction Stop }
        catch {
            if (-not $result.Error) {
                $result.Error = "Failed to dismount shadow VHD: $($_.Exception.Message)"
            }
        }
    }
    if (-not [String]::IsNullOrWhiteSpace($temporaryVhdPath) -and
        (Test-Path -LiteralPath $temporaryVhdPath -PathType Leaf)) {
        try {
            Remove-Item -LiteralPath $temporaryVhdPath -Force `
                -ErrorAction Stop
            $result.TemporaryVhdDeleted =
                -not (Test-Path -LiteralPath $temporaryVhdPath)
        }
        catch {
            if (-not $result.Error) {
                $result.Error = "Failed to delete temporary shadow VHD: $($_.Exception.Message)"
            }
        }
    }
    if (-not [String]::IsNullOrWhiteSpace($shadowLinkPath) -and
        (Test-Path -LiteralPath $shadowLinkPath)) {
        try {
            $removeLink = Start-Process -FilePath $env:ComSpec `
                -ArgumentList @('/d', '/c', 'rmdir', $shadowLinkPath) `
                -Wait -PassThru -WindowStyle Hidden
            if ($removeLink.ExitCode -ne 0) {
                throw "rmdir returned $($removeLink.ExitCode)."
            }
        }
        catch {
            if (-not $result.Error) {
                $result.Error = "Failed to remove VSS shadow link: $($_.Exception.Message)"
            }
        }
    }
    if ($null -ne $shadow) {
        try {
            $deleted = $shadow.Delete()
            $result.ShadowDeleted = [uint32]$deleted.ReturnValue -eq 0
            if (-not $result.ShadowDeleted -and -not $result.Error) {
                $result.Error = "VSS shadow delete returned $($deleted.ReturnValue)."
            }
        }
        catch {
            if (-not $result.Error) {
                $result.Error = "Failed to delete VSS shadow: $($_.Exception.Message)"
            }
        }
    }
    $result.FinishedAtUtc = [DateTime]::UtcNow.ToString('o')
    $result | ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath $ResultPath -Encoding UTF8
}

if ($result.Error) { exit 1 }
