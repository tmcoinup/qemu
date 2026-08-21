<#
.SYNOPSIS
  Install the NVAPI shim DLL in guest, either system-wide or beside one
  explicitly selected application executable.

.DESCRIPTION
  System-wide flow (the backward-compatible default):
    1. Download nvapi64.dll (our shim) from host HTTP server.
    2. Take ownership of C:\Windows\System32\nvapi64.dll (TrustedInstaller
       is default owner).
    3. Rename original → nvapi64_orig.dll; drop shim as nvapi64.dll.
    4. Validate PE architecture and required shim markers before replacing.
    5. Reboot recommended (NVIDIA service caches DLL handles).

  App-local flow (-ApplicationExe):
    1. Detect the selected executable's PE architecture.
    2. Validate and stage only the matching shim.
    3. Copy the matching, Authenticode-verified NVIDIA system NVAPI DLL
       beside the application as nvapi64_orig.dll or nvapi_orig.dll.
    4. Install the shim beside the application without modifying System32
       or SysWOW64. Existing local DLLs are never adopted unless they form
       a complete, validated pair from an earlier app-local installation.

  Rollback:
    .\install-nvapi-shim.ps1 -ApplicationExe C:\Tools\App.exe -Uninstall
    .\install-nvapi-shim.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string]$BaseUrl = 'http://192.168.30.127:8080',
    [string]$X64Path = '',
    [string]$X86Path = '',
    [string]$ExpectedX64Sha256 = '',
    [string]$ExpectedX86Sha256 = '',
    [string[]]$TrustedPriorX64Sha256 = @(),
    [string[]]$TrustedPriorX86Sha256 = @(),
    [string]$ApplicationExe = '',
    [switch]$Uninstall
)

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Must run as Administrator'
}

$ErrorActionPreference = 'Stop'

# Install both 64-bit (System32\nvapi64.dll for 64-bit callers) and 32-bit
# (SysWOW64\nvapi.dll for 32-bit callers on x64 Windows).  Both search paths
# are part of the system contract; no process name is used to select identity.
$arches = @(
    @{ label='x64'; machine=0x8664; sys='C:\Windows\System32'; name='nvapi64.dll'; backup='nvapi64_orig.dll'; scratch='C:\nv\nvapi64.shim.dll'; source=$X64Path; expected=$ExpectedX64Sha256; trustedPrior=@($TrustedPriorX64Sha256) },
    @{ label='x86'; machine=0x014c; sys='C:\Windows\SysWOW64'; name='nvapi.dll';   backup='nvapi_orig.dll';   scratch='C:\nv\nvapi.shim.dll'; source=$X86Path; expected=$ExpectedX86Sha256; trustedPrior=@($TrustedPriorX86Sha256) }
)

function Take-Own($f) {
    $takeown = Join-Path $env:SystemRoot 'System32\takeown.exe'
    $icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'
    foreach ($tool in @($takeown, $icacls)) {
        if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) {
            throw "Required Windows ACL tool is missing: $tool"
        }
    }

    $takeownOutput = (& $takeown /f $f /a 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) {
        throw "takeown failed for '$f': $($takeownOutput.Trim())"
    }

    # Built-in group names are localized (for example 管理员 on zh-CN).
    # icacls accepts a leading-* SID, so use the invariant Administrators SID
    # and fail immediately if the ACL was not actually granted.
    $icaclsOutput = (& $icacls $f /grant '*S-1-5-32-544:(F)' 2>&1 |
        Out-String)
    if ($LASTEXITCODE -ne 0) {
        throw "icacls failed for '$f': $($icaclsOutput.Trim())"
    }
}

function Get-PeMachine($Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "PE image is missing: $Path"
    }
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 64 -or $bytes[0] -ne 0x4d -or $bytes[1] -ne 0x5a) {
        throw "File is not a valid PE image: $Path"
    }
    $peOffset = [BitConverter]::ToInt32($bytes, 0x3c)
    if ($peOffset -lt 0x40 -or $peOffset + 6 -gt $bytes.Length -or
        $bytes[$peOffset] -ne 0x50 -or $bytes[$peOffset + 1] -ne 0x45 -or
        $bytes[$peOffset + 2] -ne 0 -or $bytes[$peOffset + 3] -ne 0) {
        throw "File has an invalid PE header: $Path"
    }
    return [int][BitConverter]::ToUInt16($bytes, $peOffset + 4)
}

function Assert-ShimImage($Path, [int]$ExpectedMachine) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 4096) {
        throw "Downloaded shim is not a valid PE image: $Path"
    }
    $machine = Get-PeMachine $Path
    if ($machine -ne $ExpectedMachine) {
        throw ('Downloaded shim machine 0x{0:x4} does not match expected 0x{1:x4}: {2}' `
            -f $machine, $ExpectedMachine, $Path)
    }
    $ascii = [Text.Encoding]::ASCII.GetString($bytes)
    foreach ($marker in @(
        'IdentityGpuName', 'nvapi_Direct_GetMethod', 'nvapi_QueryInterface'
    )) {
        if (-not $ascii.Contains($marker)) {
            throw "Downloaded shim is missing required marker '$marker': $Path"
        }
    }
}

function Assert-OriginalNvidiaImage($Path, [int]$ExpectedMachine = 0) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Original NVIDIA NVAPI image is missing: $Path"
    }
    if ($ExpectedMachine -and (Get-PeMachine $Path) -ne $ExpectedMachine) {
        throw ('Original NVAPI machine does not match expected 0x{0:x4}: {1}' `
            -f $ExpectedMachine, $Path)
    }
    $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    $signerSubject = if ($null -ne $signature.SignerCertificate) {
        [string]$signature.SignerCertificate.Subject
    } else {
        ''
    }
    $isSelfIssued = $null -ne $signature.SignerCertificate -and
        $signerSubject -ceq [string]$signature.SignerCertificate.Issuer
    # Production NVIDIA display-driver binaries can carry either NVIDIA's
    # own Authenticode signature or Microsoft's WHCP signature after driver
    # attestation.  Both are valid originals when the signed image also has
    # NVIDIA's exact CompanyName and the expected PE architecture.
    $trustedSigner = $signerSubject -match 'NVIDIA' -or
        $signerSubject -match '\ACN=Microsoft Windows Hardware Compatibility Publisher(?:,|$)'
    if ($version.CompanyName -notmatch '\ANVIDIA(?: Corporation)?\z' -or
        [string]$signature.Status -cne 'Valid' -or
        $null -eq $signature.SignerCertificate -or
        $isSelfIssued -or
        -not $trustedSigner) {
        throw "Original NVAPI image does not have a valid NVIDIA/WHCP signature: $Path"
    }
    $ascii = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($Path))
    if ($ascii.Contains('IdentityGpuName')) {
        throw "Refusing to use another identity shim as the original NVAPI image: $Path"
    }
}

function Get-SystemNvapiPath($Arch) {
    if ([string]::IsNullOrWhiteSpace($env:windir)) {
        throw 'The Windows directory is unavailable.'
    }
    if ($Arch.label -eq 'x64') {
        if (-not [Environment]::Is64BitOperatingSystem) {
            throw 'A 64-bit application requires 64-bit Windows.'
        }
        if ([Environment]::Is64BitProcess) {
            $systemDirectory = Join-Path $env:windir 'System32'
        } else {
            # Sysnative bypasses WOW64 file-system redirection when a caller
            # intentionally launches this script in 32-bit PowerShell.
            $systemDirectory = Join-Path $env:windir 'Sysnative'
        }
    } elseif ([Environment]::Is64BitOperatingSystem) {
        $systemDirectory = Join-Path $env:windir 'SysWOW64'
    } else {
        $systemDirectory = Join-Path $env:windir 'System32'
    }
    return Join-Path $systemDirectory $Arch.name
}

function Get-SystemPairState($Arch) {
    $target = Join-Path $Arch.sys $Arch.name
    $backup = Join-Path $Arch.sys $Arch.backup
    $targetExists = Test-Path -LiteralPath $target -PathType Leaf
    $backupExists = Test-Path -LiteralPath $backup -PathType Leaf
    if (-not $targetExists) {
        throw "System NVAPI target is missing: $target"
    }

    $targetHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
    $expectedHash = ([string]$Arch.expected).ToUpperInvariant()
    if ($targetHash -ceq $expectedHash) {
        if (-not $backupExists) {
            throw "Managed system NVAPI shim has no original backup: $target"
        }
        Assert-ShimImage $target $Arch.machine
        Assert-OriginalNvidiaImage $backup $Arch.machine
        return 'installed'
    }

    if (@($Arch.trustedPrior) -ccontains $targetHash) {
        if (-not $backupExists) {
            throw "Trusted prior system NVAPI shim has no original backup: $target"
        }
        Assert-ShimImage $target $Arch.machine
        Assert-OriginalNvidiaImage $backup $Arch.machine
        return 'trusted-prior'
    }

    # A target that is neither this exact manifest-pinned shim nor an exact
    # coordinator-authorized prior hash must still be the validly signed
    # NVIDIA/WHCP original.  This rejects an unknown shim, a partially copied
    # file and any third-party DLL before either architecture is mutated.
    Assert-OriginalNvidiaImage $target $Arch.machine
    if ($backupExists) {
        Assert-OriginalNvidiaImage $backup $Arch.machine
    }
    return 'original'
}

function Get-PendingFileRenameOperations {
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    # A clean Windows installation commonly has no value yet.  Under
    # Set-StrictMode, dereferencing the missing property throws even when
    # Get-ItemProperty used SilentlyContinue.  Inspect PSObject.Properties so
    # absence is the normal empty-list case, while a real registry read error
    # still fails closed.
    $values = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
    $property = $values.PSObject.Properties['PendingFileRenameOperations']
    if ($null -eq $property -or $null -eq $property.Value) {
        return @()
    }
    return @($property.Value)
}

function Set-PendingFileRenameOperations([string[]]$AdditionalPairs) {
    if ($AdditionalPairs.Count -eq 0) { return }
    if (($AdditionalPairs.Count % 2) -ne 0) {
        throw 'Pending file-rename operations must contain source/destination pairs.'
    }
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    $existing = @(Get-PendingFileRenameOperations)
    $combined = @($existing | Where-Object { $null -ne $_ }) + $AdditionalPairs
    Set-ItemProperty $key -Name PendingFileRenameOperations -Value $combined `
        -Type MultiString -Force
}

function Assert-ApplicationStopped($ApplicationPath) {
    foreach ($process in Get-Process -ErrorAction SilentlyContinue) {
        $processPath = $null
        try {
            $processPath = $process.Path
        } catch {
            continue
        }
        if (-not [string]::IsNullOrWhiteSpace($processPath) -and
            [string]::Equals(
                [IO.Path]::GetFullPath($processPath),
                [IO.Path]::GetFullPath($ApplicationPath),
                [StringComparison]::OrdinalIgnoreCase
            )) {
            throw "Close the selected application before changing its local NVAPI files: $ApplicationPath"
        }
    }
}

function Assert-AppLocalPathIsRegular($ApplicationItem) {
    if ($ApplicationItem.PSProvider.Name -cne 'FileSystem') {
        throw "ApplicationExe must use the file-system provider: $($ApplicationItem.PSPath)"
    }
    if (($ApplicationItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "ApplicationExe must not be a reparse point: $($ApplicationItem.FullName)"
    }
    $directory = $ApplicationItem.Directory
    while ($null -ne $directory) {
        if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "ApplicationExe must not be below a reparse-point directory: $($directory.FullName)"
        }
        $directory = $directory.Parent
    }
}

function Get-AppLocalPairState($Target, $Backup, [int]$ExpectedMachine) {
    $targetExists = Test-Path -LiteralPath $Target
    $backupExists = Test-Path -LiteralPath $Backup
    if ($targetExists -xor $backupExists) {
        throw "Conflicting pre-existing local NVAPI files; expected both or neither: $Target, $Backup"
    }
    if (-not $targetExists) {
        return 'absent'
    }
    if (-not (Test-Path -LiteralPath $Target -PathType Leaf) -or
        -not (Test-Path -LiteralPath $Backup -PathType Leaf)) {
        throw "Conflicting pre-existing local NVAPI path is not a regular file: $Target, $Backup"
    }
    foreach ($path in @($Target, $Backup)) {
        $attributes = (Get-Item -LiteralPath $path).Attributes
        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Conflicting pre-existing local NVAPI file is a reparse point: $path"
        }
    }
    try {
        Assert-ShimImage $Target $ExpectedMachine
        Assert-OriginalNvidiaImage $Backup $ExpectedMachine
    } catch {
        throw "Conflicting pre-existing local NVAPI pair was not installed by this shim: $($_.Exception.Message)"
    }
    return 'installed'
}

function Stage-VerifiedShim($Arch, $Destination) {
    if ([string]$Arch.expected -notmatch '\A[0-9A-Fa-f]{64}\z') {
        throw "Expected$($Arch.label)Sha256 must be supplied as 64 hexadecimal characters."
    }
    $expectedHash = ([string]$Arch.expected).ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace([string]$Arch.source)) {
        $url = "$BaseUrl/$($Arch.name)"
        Invoke-WebRequest $url -OutFile $Destination -UseBasicParsing | Out-Null
    } else {
        Copy-Item -LiteralPath ([string]$Arch.source) -Destination $Destination
    }
    Assert-ShimImage $Destination $Arch.machine
    $actualHash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
    if ($actualHash -cne $expectedHash) {
        throw "Downloaded/local shim SHA256 mismatch for $($Arch.label): actual $actualHash, expected $expectedHash"
    }
    return $actualHash
}

function Assert-AppLocalPairContent(
    $Target,
    $Backup,
    [int]$ExpectedMachine,
    $ExpectedShimHash,
    $ExpectedOriginalHash
) {
    $null = Get-AppLocalPairState $Target $Backup $ExpectedMachine
    if ((Get-FileHash -LiteralPath $Target -Algorithm SHA256).Hash -cne $ExpectedShimHash -or
        (Get-FileHash -LiteralPath $Backup -Algorithm SHA256).Hash -cne $ExpectedOriginalHash) {
        throw 'Installed app-local NVAPI pair failed final hash verification.'
    }
}

function Install-NewAppLocalPair(
    $Target,
    $Backup,
    $StagedShim,
    $StagedOriginal,
    [int]$ExpectedMachine,
    $ExpectedShimHash,
    $ExpectedOriginalHash
) {
    $backupInstalled = $false
    $targetInstalled = $false
    try {
        Move-Item -LiteralPath $StagedOriginal -Destination $Backup -ErrorAction Stop
        $backupInstalled = $true
        Move-Item -LiteralPath $StagedShim -Destination $Target -ErrorAction Stop
        $targetInstalled = $true
        Assert-AppLocalPairContent `
            $Target $Backup $ExpectedMachine $ExpectedShimHash $ExpectedOriginalHash
    } catch {
        $installError = $_.Exception.Message
        $rollbackErrors = @()
        if ($targetInstalled -and (Test-Path -LiteralPath $Target)) {
            try {
                Remove-Item -LiteralPath $Target -Force -ErrorAction Stop
            } catch {
                $rollbackErrors += $_.Exception.Message
            }
        }
        if ($backupInstalled -and (Test-Path -LiteralPath $Backup)) {
            try {
                Remove-Item -LiteralPath $Backup -Force -ErrorAction Stop
            } catch {
                $rollbackErrors += $_.Exception.Message
            }
        }
        if ($rollbackErrors.Count) {
            throw "App-local NVAPI installation failed ($installError); rollback also failed: $($rollbackErrors -join '; ')"
        }
        throw "App-local NVAPI installation failed; newly created files were rolled back: $installError"
    }
}

function Update-AppLocalPair(
    $Target,
    $Backup,
    $StagedShim,
    $StagedOriginal,
    [int]$ExpectedMachine,
    $ExpectedShimHash,
    $ExpectedOriginalHash
) {
    $token = [Guid]::NewGuid().ToString('N')
    $oldTarget = "$Target.$token.rollback"
    $oldBackup = "$Backup.$token.rollback"
    $targetMoved = $false
    $backupMoved = $false
    $newTargetInstalled = $false
    $newBackupInstalled = $false
    try {
        Move-Item -LiteralPath $Target -Destination $oldTarget -ErrorAction Stop
        $targetMoved = $true
        Move-Item -LiteralPath $Backup -Destination $oldBackup -ErrorAction Stop
        $backupMoved = $true
        Move-Item -LiteralPath $StagedOriginal -Destination $Backup -ErrorAction Stop
        $newBackupInstalled = $true
        Move-Item -LiteralPath $StagedShim -Destination $Target -ErrorAction Stop
        $newTargetInstalled = $true
        Assert-AppLocalPairContent `
            $Target $Backup $ExpectedMachine $ExpectedShimHash $ExpectedOriginalHash
    } catch {
        $installError = $_.Exception.Message
        $rollbackErrors = @()
        if ($newTargetInstalled -and (Test-Path -LiteralPath $Target)) {
            try {
                Remove-Item -LiteralPath $Target -Force -ErrorAction Stop
            } catch {
                $rollbackErrors += $_.Exception.Message
            }
        }
        if ($newBackupInstalled -and (Test-Path -LiteralPath $Backup)) {
            try {
                Remove-Item -LiteralPath $Backup -Force -ErrorAction Stop
            } catch {
                $rollbackErrors += $_.Exception.Message
            }
        }
        if ($backupMoved -and -not (Test-Path -LiteralPath $Backup)) {
            try {
                Move-Item -LiteralPath $oldBackup -Destination $Backup -ErrorAction Stop
            } catch {
                $rollbackErrors += $_.Exception.Message
            }
        }
        if ($targetMoved -and -not (Test-Path -LiteralPath $Target)) {
            try {
                Move-Item -LiteralPath $oldTarget -Destination $Target -ErrorAction Stop
            } catch {
                $rollbackErrors += $_.Exception.Message
            }
        }
        if ($rollbackErrors.Count) {
            throw "App-local NVAPI update failed ($installError); rollback also failed: $($rollbackErrors -join '; ')"
        }
        throw "App-local NVAPI update failed; prior files were restored: $installError"
    }
    foreach ($path in @($oldTarget, $oldBackup)) {
        try {
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
        } catch {
            Write-Warning "App-local NVAPI was updated, but a rollback file remains: $path"
        }
    }
}

function Remove-AppLocalPair($Target, $Backup) {
    $token = [Guid]::NewGuid().ToString('N')
    $removedTarget = "$Target.$token.remove"
    $removedBackup = "$Backup.$token.remove"
    Move-Item -LiteralPath $Target -Destination $removedTarget -ErrorAction Stop
    try {
        Move-Item -LiteralPath $Backup -Destination $removedBackup -ErrorAction Stop
    } catch {
        $removeError = $_.Exception.Message
        Move-Item -LiteralPath $removedTarget -Destination $Target -ErrorAction Stop
        throw "App-local NVAPI uninstall failed; the installed pair was restored: $removeError"
    }
    foreach ($path in @($removedTarget, $removedBackup)) {
        try {
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
        } catch {
            Write-Warning "App-local NVAPI is disabled, but a renamed cleanup file remains: $path"
        }
    }
}

function Invoke-AppLocalMode($ApplicationPath, [switch]$Remove) {
    if (-not (Test-Path -LiteralPath $ApplicationPath -PathType Leaf)) {
        throw "Application executable is missing: $ApplicationPath"
    }
    $applicationItem = Get-Item -LiteralPath $ApplicationPath
    Assert-AppLocalPathIsRegular $applicationItem
    if ($applicationItem.Extension -ine '.exe') {
        throw "ApplicationExe must identify an .exe file: $ApplicationPath"
    }
    $resolvedApplication = $applicationItem.FullName
    $applicationMachine = Get-PeMachine $resolvedApplication
    $arch = @($arches | Where-Object {
        [int]$_.machine -eq $applicationMachine
    })
    if ($arch.Count -ne 1) {
        throw ('Unsupported application PE machine 0x{0:x4}: {1}' `
            -f $applicationMachine, $resolvedApplication)
    }
    $arch = $arch[0]
    $applicationDirectory = $applicationItem.DirectoryName
    $windowsDirectory = [IO.Path]::GetFullPath($env:windir).TrimEnd('\')
    $fullApplicationDirectory = [IO.Path]::GetFullPath($applicationDirectory).TrimEnd('\')
    if ($fullApplicationDirectory.Equals(
            $windowsDirectory,
            [StringComparison]::OrdinalIgnoreCase
        ) -or $fullApplicationDirectory.StartsWith(
            "$windowsDirectory\",
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw 'ApplicationExe must not be inside the Windows directory in app-local mode.'
    }

    $target = Join-Path $applicationDirectory $arch.name
    $backup = Join-Path $applicationDirectory $arch.backup
    Assert-ApplicationStopped $resolvedApplication
    $state = Get-AppLocalPairState $target $backup $arch.machine

    if ($Remove) {
        Write-Host "[app-local/$($arch.label)] uninstall beside $resolvedApplication" -Fore Cyan
        if ($state -eq 'absent') {
            Write-Host '  no managed app-local NVAPI pair is installed'
            return
        }
        Remove-AppLocalPair $target $backup
        Write-Host '  removed the validated app-local shim and original DLL'
        return
    }

    $systemOriginal = Get-SystemNvapiPath $arch
    Assert-OriginalNvidiaImage $systemOriginal $arch.machine
    $token = [Guid]::NewGuid().ToString('N')
    $stagedShim = Join-Path $applicationDirectory ".$($arch.name).$token.new"
    $stagedOriginal = Join-Path $applicationDirectory ".$($arch.backup).$token.new"
    Write-Host "[app-local/$($arch.label)] install beside $resolvedApplication" -Fore Cyan
    try {
        $shimHash = Stage-VerifiedShim $arch $stagedShim
        Copy-Item -LiteralPath $systemOriginal -Destination $stagedOriginal
        Assert-OriginalNvidiaImage $stagedOriginal $arch.machine
        $originalHash = (Get-FileHash -LiteralPath $stagedOriginal -Algorithm SHA256).Hash

        # Recheck after staging so a concurrent file creation becomes a
        # conflict rather than an overwrite.
        $currentState = Get-AppLocalPairState $target $backup $arch.machine
        if ($currentState -cne $state) {
            throw 'App-local NVAPI files changed while the installation was being staged.'
        }
        if ($state -eq 'installed' -and
            (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ceq $shimHash -and
            (Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash -ceq $originalHash) {
            Write-Host '  matching app-local NVAPI pair is already installed'
            return
        }
        if ($state -eq 'absent') {
            Install-NewAppLocalPair `
                $target $backup $stagedShim $stagedOriginal `
                $arch.machine $shimHash $originalHash
        } else {
            Update-AppLocalPair `
                $target $backup $stagedShim $stagedOriginal `
                $arch.machine $shimHash $originalHash
        }
        Write-Host "  installed $target"
        Write-Host "  original  $backup"
    } finally {
        Remove-Item -LiteralPath $stagedShim, $stagedOriginal -Force -ErrorAction SilentlyContinue
    }
}

# App-local mode returns before all system-wide mutation code below.
if (-not [string]::IsNullOrWhiteSpace($ApplicationExe)) {
    Invoke-AppLocalMode $ApplicationExe -Remove:$Uninstall
    return
}

foreach ($a in $arches) {
    if ([string]$a.expected -notmatch '\A[0-9A-Fa-f]{64}\z') {
        throw "Expected$($a.label)Sha256 must be supplied as 64 hexadecimal characters."
    }
    $a.expected = ([string]$a.expected).ToUpperInvariant()
    $trusted = @{}
    foreach ($hash in @($a.trustedPrior)) {
        if ([string]$hash -cnotmatch '\A[0-9A-Fa-f]{64}\z') {
            throw "TrustedPrior$($a.label)Sha256 contains an invalid SHA256 value."
        }
        $normalized = ([string]$hash).ToUpperInvariant()
        if ($normalized -cne $a.expected) {
            $trusted[$normalized] = $true
        }
    }
    $a.trustedPrior = @($trusted.Keys | Sort-Object)
}

# Classify both architecture pairs before changing either one.  The system
# flow accepts only the exact requested shim, a coordinator-authorized prior
# hash with a signed original backup, or an Authenticode-valid NVIDIA original;
# an unknown/partial pair stops the whole operation fail-closed.
$systemStates = @{}
foreach ($a in $arches) {
    $systemStates[$a.label] = Get-SystemPairState $a
}

if ($Uninstall) {
    Write-Host '[uninstall] restoring original nvapi DLLs' -Fore Cyan
    $pendingRestore = @()
    foreach ($a in $arches) {
        $target = Join-Path $a.sys $a.name
        $backup = Join-Path $a.sys $a.backup
        if ($systemStates[$a.label] -eq 'original') {
            if (Test-Path -LiteralPath $backup -PathType Leaf) {
                $targetHash = (Get-FileHash -LiteralPath $target `
                    -Algorithm SHA256).Hash
                $backupHash = (Get-FileHash -LiteralPath $backup `
                    -Algorithm SHA256).Hash
                if ($targetHash -cne $backupHash) {
                    throw "[$($a.label)] original target and redundant backup differ; refusing to delete either file"
                }
                Take-Own $backup
                Remove-Item -LiteralPath $backup -Force -ErrorAction Stop
                Write-Host "  [$($a.label)] removed byte-identical redundant backup"
            }
            Write-Host "  [$($a.label)] original already active"
            continue
        }
        Take-Own $target
        try {
            Copy-Item -LiteralPath $backup -Destination $target -Force `
                -ErrorAction Stop
            Assert-OriginalNvidiaImage $target $a.machine
            Remove-Item -LiteralPath $backup -Force -ErrorAction Stop
            Write-Host "  [$($a.label)] reverted $target"
        } catch [System.IO.IOException] {
            # Session Manager performs these ordered pairs before user-mode
            # NVAPI clients start.  The signed backup remains beside the live
            # shim until the move succeeds, so rollback never depends on the
            # removable installation media.
            Write-Host "  [$($a.label)] target is in use — scheduling signed-original restore" -Fore Yellow
            $pendingRestore += @("\??\$target", '')
            $pendingRestore += @("\??\$backup", "\??\$target")
        }
    }
    Set-PendingFileRenameOperations $pendingRestore
    Write-Host 'Reboot to drop cached handles and complete any scheduled restore.'
    return
}

New-Item -Type Directory -Force 'C:\nv' | Out-Null
$ProgressPreference = 'SilentlyContinue'
$pending = @()

foreach ($a in $arches) {
    $target = Join-Path $a.sys $a.name
    $backup = Join-Path $a.sys $a.backup
    $url    = "$BaseUrl/$($a.name)"
    Write-Host "[$($a.label)] install $target (<- $url)" -Fore Cyan

    if ($systemStates[$a.label] -eq 'installed') {
        Write-Host '  exact manifest-pinned shim/original pair is already installed'
        continue
    }

    # Pull the compatibility-path asset or copy the already manifest-verified
    # immutable asset supplied by apply-vm-profile.ps1.
    if ([string]::IsNullOrWhiteSpace([string]$a.source)) {
        Invoke-WebRequest $url -OutFile $a.scratch -UseBasicParsing
    } else {
        Copy-Item -LiteralPath ([string]$a.source) -Destination $a.scratch -Force
    }
    Assert-ShimImage $a.scratch $a.machine
    $scratchHash = (Get-FileHash -LiteralPath $a.scratch -Algorithm SHA256).Hash
    if ($scratchHash -cne $a.expected) {
        throw "Downloaded/local shim SHA256 mismatch for $($a.label): actual $scratchHash, expected $($a.expected)"
    }
    "  scratch size: $((Get-Item $a.scratch).Length) bytes"

    # backup original once
    if (-not (Test-Path $backup)) {
        Assert-OriginalNvidiaImage $target $a.machine
        Take-Own $target
        Copy-Item -LiteralPath $target -Destination $backup -Force
        Assert-OriginalNvidiaImage $backup $a.machine
        "  backup -> $backup"
    } else {
        Assert-OriginalNvidiaImage $backup $a.machine
        "  backup $backup already exists"
    }

    # install — try direct copy, fall back to PendingFileRenameOperations
    # when NVIDIA services hold the DLL open.
    Take-Own $target
    try {
        Copy-Item -LiteralPath $a.scratch -Destination $target -Force `
            -ErrorAction Stop
        Assert-ShimImage $target $a.machine
        $targetHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
        if ($targetHash -cne $scratchHash) {
            throw "Installed shim hash mismatch: $target"
        }
        "  direct copy OK"
    }
    catch [System.IO.IOException] {
        Write-Host "  $target locked — scheduling swap at next boot" -Fore Yellow
        $pending += @("\??\$target", "")                       # delete live
        $pending += @("\??\$($a.scratch)", "\??\$target")       # then rename
    }
}

if ($pending.Count) {
    Set-PendingFileRenameOperations $pending
    Write-Host ''
    Write-Host 'Some files are in use. Reboot to apply:' -Fore Green
    Write-Host '  shutdown /r /t 5' -Fore Green
} else {
    Write-Host ''
    Write-Host 'All shims installed live. No reboot required (though NVIDIA services hold the old DLLs — reboot for them to pick up new ones).' -Fore Green
}
