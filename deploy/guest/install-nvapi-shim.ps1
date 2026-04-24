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
    [string]$ServerUrl = 'http://192.168.30.127:8080/nvapi64.dll',
    [switch]$Uninstall
)

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Must run as Administrator'
}

$ErrorActionPreference = 'Stop'
$sys = 'C:\Windows\System32'
$target = Join-Path $sys 'nvapi64.dll'
$backup = Join-Path $sys 'nvapi64_orig.dll'
$scratch = 'C:\nv\nvapi64.shim.dll'

function Take-Own($f) {
    & cmd /c takeown /f "`"$f`"" /a 2>&1 | Out-Null
    & cmd /c icacls "`"$f`"" /grant 'Administrators:(F)' 2>&1 | Out-Null
}

if ($Uninstall) {
    Write-Host '[uninstall] restoring original nvapi64.dll' -Fore Cyan
    if (Test-Path $backup) {
        Take-Own $target
        Remove-Item $target -Force -EA 0
        Move-Item $backup $target -Force
        Write-Host '  reverted. Reboot to drop cached handles.'
    } else {
        Write-Host "  no backup at $backup — nothing to do." -Fore Yellow
    }
    return
}

# ─── 1. pull shim ───────────────────────────────────────────
New-Item -Type Directory -Force 'C:\nv' | Out-Null
Write-Host "[1/4] download shim: $ServerUrl" -Fore Cyan
$ProgressPreference = 'SilentlyContinue'
Invoke-WebRequest $ServerUrl -OutFile $scratch -UseBasicParsing
"  size: $((Get-Item $scratch).Length) bytes"

# ─── 2. backup original (only if we haven't already) ────────
Write-Host '[2/4] backup original nvapi64.dll' -Fore Cyan
if (-not (Test-Path $backup)) {
    Take-Own $target
    Copy-Item $target $backup -Force
    "  backup -> $backup"
} else {
    "  $backup exists, keeping it"
}

# ─── 3. install shim ────────────────────────────────────────
Write-Host '[3/4] install shim as nvapi64.dll' -Fore Cyan
Take-Own $target
# Overwrite, keeping the usual Windows ACL untouched.
Copy-Item $scratch $target -Force
"  installed -> $target"

# ─── 4. verify DLL loads (sanity) ───────────────────────────
Write-Host '[4/4] verify shim loads OK' -Fore Cyan
$test = @'
using System;
using System.Runtime.InteropServices;
public static class T {
  [DllImport("nvapi64.dll", CallingConvention=CallingConvention.StdCall, EntryPoint="nvapi_QueryInterface")]
  public static extern IntPtr Q(uint id);
}
'@
Add-Type -TypeDefinition $test -Language CSharp
$p = [T]::Q(0xDCB616C3)
"  nvapi_QueryInterface(0xDCB616C3) -> $p (non-null = shim loaded + forwards)"

Write-Host ''
Write-Host 'Done. Reboot the guest to make long-running NVIDIA services pick up the new DLL.' -Fore Green
Write-Host 'After reboot, check 鲁大师 / GPU-Z — core clock / mem clock / ram vendor should reflect spoof.' -Fore Green
