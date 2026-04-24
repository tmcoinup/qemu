<#
.SYNOPSIS
  Silent install TightVNC Server 2.x in the guest so the host can see the
  desktop without going through RDP (no Microsoft Remote Display Adapter
  in Device Manager, no vGPU IDD).

.DESCRIPTION
  TightVNC 2.x uses GDI polling — it does NOT install a mirror display
  driver, which means Device Manager stays clean. Only cost is a single
  tvnserver.exe process (hideable via service + no tray icon).

  This script:
    1. Downloads tightvnc-server.msi from http://192.168.30.127:8080/
       (same server that install-patched-driver.ps1 uses).
    2. Silent install with ADDLOCAL=Server (server only, no viewer).
    3. Writes registry config: password via rfbauth hash, no tray icon,
       port 5900, loopback-only disabled so host can actually connect.
    4. Adds firewall rule for inbound 5900 tcp.
    5. Starts the tvnserver service.

  Guest exposes port 5900 on its own IP (192.168.30.191 by default).

.EXAMPLE
  # Default password = 123456 (8 chars max for TightVNC), port 5900
  .\install-tightvnc.ps1

  # Custom password + port
  .\install-tightvnc.ps1 -Password 'mypass12' -Port 5901
#>
[CmdletBinding()]
param(
    [string]$ServerUrl = 'http://192.168.30.127:8080/tightvnc-server.msi',
    [string]$Password = '123456',
    [int]$Port = 5900,
    [switch]$Uninstall
)

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Must run as Administrator'
}

$ErrorActionPreference = 'Stop'

if ($Uninstall) {
    Write-Host '[uninstall] stopping tvnserver, uninstalling MSI, removing firewall rule' -Fore Cyan
    Stop-Service tvnserver -Force -EA 0
    $product = Get-CimInstance Win32_Product -EA 0 | Where-Object { $_.Name -like 'TightVNC*' }
    if ($product) {
        msiexec /x $product.IdentifyingNumber /qn | Out-Null
    }
    Remove-NetFirewallRule -DisplayName 'TightVNC In' -EA 0
    Write-Host 'Done.'
    return
}

# ─── 1. download installer ──────────────────────────────────────────
$nv = 'C:\nv'
New-Item -Type Directory -Force $nv | Out-Null
$msi = Join-Path $nv 'tightvnc-server.msi'
if (-not (Test-Path $msi)) {
    Write-Host "[1/5] downloading $ServerUrl -> $msi" -Fore Cyan
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest $ServerUrl -OutFile $msi -UseBasicParsing
}
"  size: $((Get-Item $msi).Length) bytes"

# ─── 2. silent install (server only) ────────────────────────────────
Write-Host '[2/5] silent MSI install (ADDLOCAL=Server only)' -Fore Cyan
$args = @(
    '/i', "`"$msi`"", '/quiet', '/norestart',
    'ADDLOCAL=Server',
    'SERVER_REGISTER_AS_SERVICE=1',
    'SERVER_ADD_FIREWALL_EXCEPTION=1',
    'SET_USEVNCAUTHENTICATION=1', 'VALUE_OF_USEVNCAUTHENTICATION=1',
    'SET_PASSWORD=1', "VALUE_OF_PASSWORD=$Password",
    'SET_RFBPORT=1', "VALUE_OF_RFBPORT=$Port"
)
$p = Start-Process msiexec.exe -ArgumentList $args -Wait -PassThru
if ($p.ExitCode -ne 0) { throw "msiexec returned $($p.ExitCode)" }

# ─── 3. registry tuning — no tray icon, allow remote ────────────────
Write-Host '[3/5] registry: hide tray icon, tune server' -Fore Cyan
$reg = 'HKLM:\SOFTWARE\TightVNC\Server'
New-Item -Path $reg -Force | Out-Null
Set-ItemProperty $reg -Name 'ShowTrayIcon' -Value 0 -Type DWord
Set-ItemProperty $reg -Name 'AcceptRfbConnections' -Value 1 -Type DWord
Set-ItemProperty $reg -Name 'RfbPort' -Value $Port -Type DWord
Set-ItemProperty $reg -Name 'UseMirrorDriver' -Value 0 -Type DWord
Set-ItemProperty $reg -Name 'GrabTransparentWindows' -Value 1 -Type DWord
Set-ItemProperty $reg -Name 'RunControlInterface' -Value 0 -Type DWord    # no control panel window
Set-ItemProperty $reg -Name 'EnableFileTransfers' -Value 1 -Type DWord
Set-ItemProperty $reg -Name 'UseVncAuthentication' -Value 1 -Type DWord
Set-ItemProperty $reg -Name 'BlockRemoteInput' -Value 0 -Type DWord
Set-ItemProperty $reg -Name 'LocalInputPriority' -Value 0 -Type DWord

# ─── 4. firewall rule (MSI already added one, but double-check) ─────
Write-Host '[4/5] firewall: allow inbound TCP/' $Port -Fore Cyan
Remove-NetFirewallRule -DisplayName 'TightVNC In' -EA 0
New-NetFirewallRule -DisplayName 'TightVNC In' -Direction Inbound `
    -Action Allow -Protocol TCP -LocalPort $Port -Program 'C:\Program Files\TightVNC\tvnserver.exe' | Out-Null

# ─── 5. restart service, verify ─────────────────────────────────────
Write-Host '[5/5] restart service + verify' -Fore Cyan
Restart-Service tvnserver -Force
Start-Sleep 2
$svc = Get-Service tvnserver -EA 0
"Service tvnserver: $($svc.Status)"

# Display-related PnP stays clean?
"`nPresent Display adapters (should not include any VNC mirror):"
Get-PnpDevice -Class Display -PresentOnly:$true | Format-Table Status,FriendlyName,InstanceId -AutoSize

"`nListening sockets:"
Get-NetTCPConnection -LocalPort $Port -EA 0 | Select-Object LocalAddress,LocalPort,State | Format-Table -AutoSize

Write-Host ''
Write-Host "Done. Connect from host:" -Fore Green
Write-Host "  xtigervncviewer 192.168.30.191::$Port   # password: $Password" -Fore Green
