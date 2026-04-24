<#
.SYNOPSIS
  Launch DNF (or any TP-sensitive game) with the remote-access surface
  fully closed, then auto-restore after the process exits.

.DESCRIPTION
  One-shot wrapper around dnf-prep.ps1 Prep / Restore. Flow:
    1. Prep: stop tvnserver, kill parsec/teamviewer/anydesk/etc.,
       disable their firewall rules, purge REMOTEDISPLAYENUM ghosts.
    2. Launch the game .exe.
    3. Block until the game exits (or user hits Ctrl+C).
    4. Restore: everything that was on before Prep.

.PARAMETER GamePath
  Path to the game executable. Defaults to the DNF launcher in a common
  install location; override for other games.

.EXAMPLE
  # Run DNF (launcher at default path)
  C:\nv\dnf-launch.ps1

  # Other game / installed elsewhere
  C:\nv\dnf-launch.ps1 -GamePath 'D:\Games\DNF\DNF.exe'

  # Just start DNF without prep/restore (debug)
  C:\nv\dnf-launch.ps1 -NoPrep
#>
[CmdletBinding()]
param(
    [string]$GamePath = 'C:\Program Files (x86)\DNF\DNF.exe',
    [string[]]$GameArgs = @(),
    [switch]$NoPrep,
    [switch]$StatusOnly
)

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Must run as Administrator'
}

$ErrorActionPreference = 'Continue'
$prep = 'C:\nv\dnf-prep.ps1'
if (-not (Test-Path $prep)) { throw "missing $prep — deploy it first" }

# Candidate game paths if the default doesn't exist — check before abort.
$candidates = @(
    $GamePath,
    'C:\Program Files\DNF\DNF.exe',
    'D:\DNF\DNF.exe',
    'E:\DNF\DNF.exe'
)
$found = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $found) {
    Write-Host 'Game EXE not found in:' -Fore Yellow
    $candidates | ForEach-Object { "    $_" }
    Write-Host 'Pass -GamePath <path> or put DNF.exe under one of the above.' -Fore Yellow
    exit 1
}
Write-Host "[dnf-launch] game  = $found" -Fore Cyan

if ($StatusOnly) {
    & $prep Status
    return
}

try {
    if (-not $NoPrep) {
        Write-Host '[dnf-launch] prep (closing remote tools)' -Fore Cyan
        & $prep Prep
    }

    Write-Host ''
    Write-Host "[dnf-launch] launching: $found $($GameArgs -join ' ')" -Fore Green
    $proc = Start-Process -FilePath $found -ArgumentList $GameArgs -PassThru

    # Wait for the initial launcher process + any child game process it
    # spawns (DNF has a launcher.exe that execs DNF.exe). Poll every 10 s.
    Start-Sleep -Seconds 15   # give the launcher time to spawn the real game
    $gameNamePattern = [IO.Path]::GetFileNameWithoutExtension($found)
    while ($true) {
        $running = Get-Process -Name "$gameNamePattern*", 'DNF*', 'TCls*', 'nexon*' -EA 0
        if (-not $running) {
            Write-Host '[dnf-launch] no game/launcher process detected — assuming exited' -Fore Cyan
            break
        }
        Start-Sleep -Seconds 15
    }
}
finally {
    if (-not $NoPrep) {
        Write-Host ''
        Write-Host '[dnf-launch] restoring remote tools' -Fore Cyan
        & $prep Restore
    }
}

Write-Host ''
Write-Host '[dnf-launch] done. Reconnect VNC / RDP as needed.' -Fore Green
