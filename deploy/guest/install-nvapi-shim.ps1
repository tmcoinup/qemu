<#
.SYNOPSIS
  Install the NVAPI shim DLL in guest. After this, NVAPI clients (鲁大师,
  GPU-Z, HWiNFO, game engines) query our override for a handful of GPU
  spec functions; we return spoofed GT 1030 values instead of the
  physical RTX 2080's.

.DESCRIPTION
  Flow:
    1. Download nvapi64.dll (our shim) from host HTTP server.
    2. Take ownership of C:\Windows\System32\nvapi64.dll (TrustedInstaller
       is default owner).
    3. Rename original → nvapi64_orig.dll; drop shim as nvapi64.dll.
    4. Verify shim loads by running a sanity check.
    5. Reboot recommended (NVIDIA service caches DLL handles).

  Rollback: .\install-nvapi-shim.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string]$BaseUrl = 'http://192.168.30.127:8080',
    [switch]$Uninstall
)

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Must run as Administrator'
}

$ErrorActionPreference = 'Stop'

# Install both 64-bit (System32\nvapi64.dll for 64-bit apps) AND 32-bit
# (SysWOW64\nvapi.dll for 32-bit apps like 鲁大师 on x64 Windows). 鲁大师
# loads SysWOW64\nvapi.dll (confirmed in-guest), so a 64-bit-only install
# leaves 鲁大师 seeing real RTX 2080 specs.
$arches = @(
    @{ label='x64'; sys='C:\Windows\System32'; name='nvapi64.dll'; backup='nvapi64_orig.dll'; scratch='C:\nv\nvapi64.shim.dll' },
    @{ label='x86'; sys='C:\Windows\SysWOW64'; name='nvapi.dll';   backup='nvapi_orig.dll';   scratch='C:\nv\nvapi.shim.dll'   }
)

function Take-Own($f) {
    & cmd /c takeown /f "`"$f`"" /a 2>&1 | Out-Null
    & cmd /c icacls "`"$f`"" /grant 'Administrators:(F)' 2>&1 | Out-Null
}

if ($Uninstall) {
    Write-Host '[uninstall] restoring original nvapi DLLs' -Fore Cyan
    foreach ($a in $arches) {
        $target = Join-Path $a.sys $a.name
        $backup = Join-Path $a.sys $a.backup
        if (Test-Path $backup) {
            Take-Own $target
            Remove-Item $target -Force -EA 0
            Move-Item $backup $target -Force
            Write-Host "  [$($a.label)] reverted $target"
        }
    }
    Write-Host 'Reboot to drop cached handles.'
    return
}

New-Item -Type Directory -Force 'C:\nv' | Out-Null
$ProgressPreference = 'SilentlyContinue'
$pending = @()
$pendKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'

foreach ($a in $arches) {
    $target = Join-Path $a.sys $a.name
    $backup = Join-Path $a.sys $a.backup
    $url    = "$BaseUrl/$($a.name)"
    Write-Host "[$($a.label)] install $target (<- $url)" -Fore Cyan

    # pull shim
    Invoke-WebRequest $url -OutFile $a.scratch -UseBasicParsing
    "  scratch size: $((Get-Item $a.scratch).Length) bytes"

    # backup original once
    if (-not (Test-Path $backup)) {
        Take-Own $target
        Copy-Item $target $backup -Force
        "  backup -> $backup"
    } else {
        "  backup $backup already exists"
    }

    # install — try direct copy, fall back to PendingFileRenameOperations
    # when NVIDIA services hold the DLL open.
    Take-Own $target
    try {
        Copy-Item $a.scratch $target -Force -ErrorAction Stop
        "  direct copy OK"
    }
    catch [System.IO.IOException] {
        Write-Host "  $target locked — scheduling swap at next boot" -Fore Yellow
        $pending += @("\??\$target", "")                       # delete live
        $pending += @("\??\$($a.scratch)", "\??\$target")       # then rename
    }
}

if ($pending.Count) {
    $existing = (Get-ItemProperty $pendKey -Name PendingFileRenameOperations -EA 0).PendingFileRenameOperations
    if ($existing) { $pending = $existing + $pending }
    Set-ItemProperty $pendKey -Name PendingFileRenameOperations -Value $pending -Type MultiString -Force
    Write-Host ''
    Write-Host 'Some files are in use. Reboot to apply:' -Fore Green
    Write-Host '  shutdown /r /t 5' -Fore Green
} else {
    Write-Host ''
    Write-Host 'All shims installed live. No reboot required (though NVIDIA services hold the old DLLs — reboot for them to pick up new ones).' -Fore Green
}
