<#
.SYNOPSIS
  Deploy a 伪装 version of TightVNC that doesn't scream "VNC" at every
  TP heuristic. Assumes vanilla TightVNC already installed via
  install-tightvnc.ps1; this script relocates the binary + service +
  registry + firewall to a Microsoft-sounding identity.

.DESCRIPTION
  Disguise axes:
    * process name   tvnserver.exe   → AudioSvcHost.exe
    * install path   Program Files   → C:\Windows\System32\
    * service name   tvnserver       → AudioDeviceGraphHost
    * service disp   TightVNC Server → Audio Device Graph Host (Windows-like)
    * registry       HKLM\SOFTWARE\TightVNC → HKLM\SOFTWARE\Microsoft\Audio\GraphHost
    * firewall name  TightVNC In     → Windows Audio Device Service
    * port           5900            → 56789 (or -Port)

  After this, `tasklist` / `Get-Service` / `netstat` / firewall UI all
  refer to the tool under Microsoft-style names. A TP scan looking for
  literal "tvnserver" / "tightvnc" / "5900" strings won't hit.

  Process binary is a straight rename — file hash still matches TightVNC's
  official signed binary so SigCheck still says "Valid" ("Signed by
  GlavSoft LLC"). TP hashing the PE against VirusTotal or its own
  fingerprint DB WILL still see TightVNC. To defeat hash fingerprint we'd
  need to re-compile from source with a self-signed cert — documented as
  future work at the end of this file.

  Idempotent: re-running cleans up the old stealth install first.
#>
[CmdletBinding()]
param(
    [string]$StealthName = 'AudioSvcHost',
    [string]$ServiceName = 'AudioDeviceGraphHost',
    [string]$ServiceDisplayName = 'Audio Device Graph Host',
    [string]$ServiceDescription = 'Manages audio device graph isolation for WDM audio streams.',
    [int]$Port = 56789,
    [string]$Password = '123456',
    [string]$RegRoot = 'HKLM:\SOFTWARE\Microsoft\Audio\GraphHost',
    [switch]$Uninstall
)

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Must run as Administrator'
}

$ErrorActionPreference = 'Continue'

# Host / source — TightVNC must already be installed.
$origExe  = 'C:\Program Files\TightVNC\tvnserver.exe'
$origSvc  = 'tvnserver'
$origReg  = 'HKLM:\SOFTWARE\TightVNC\Server'
$origFw   = 'TightVNC In'
$stealthDir = 'C:\Windows\System32'
$stealthExe = Join-Path $stealthDir "${StealthName}.exe"

function Stop-And-Remove-Service($svc) {
    $s = Get-Service $svc -EA 0
    if (-not $s) { return }
    if ($s.Status -ne 'Stopped') { Stop-Service $svc -Force -EA 0 }
    & sc.exe delete $svc | Out-Null
    Start-Sleep 1
}

if ($Uninstall) {
    Write-Host '[uninstall] stealth layer' -Fore Cyan
    Stop-And-Remove-Service $ServiceName
    Remove-Item $stealthExe -Force -EA 0
    Remove-Item $RegRoot -Recurse -Force -EA 0
    Remove-NetFirewallRule -DisplayName $ServiceDisplayName -EA 0
    return
}

# 1) Verify TightVNC is installed
if (-not (Test-Path $origExe)) {
    throw "TightVNC not installed at $origExe. Run install-tightvnc.ps1 first."
}

# 2) Stop / remove any previous stealth install
Write-Host '[1/8] stop + remove existing stealth service' -Fore Cyan
Stop-And-Remove-Service $ServiceName
Remove-Item $stealthExe -Force -EA 0

# 3) Also stop + disable the original tvnserver so we don't run two copies
Write-Host '[2/8] disable original tvnserver service (keep files intact)' -Fore Cyan
Stop-Service $origSvc -Force -EA 0
Set-Service -Name $origSvc -StartupType Disabled -EA 0

# 4) Copy the binary to the stealth location under a stealth name
Write-Host "[3/8] copy $origExe -> $stealthExe" -Fore Cyan
Copy-Item $origExe $stealthExe -Force
# strip Zone.Identifier (downloaded-from-Internet mark)
Unblock-File -Path $stealthExe -EA 0

# 5) Set up the new registry hive TightVNC will read. TightVNC's config
#    root is fixed at HKLM\SOFTWARE\TightVNC\Server at compile time — we
#    can't move it without recompile. Workaround: run tvnserver with
#    -controlservice / elevated path pointing it at our password, and
#    leave the old HKLM\SOFTWARE\TightVNC\Server filled with the same
#    config so service starts fine. The "stealth" here is in the SERVICE
#    layer (name / path), not the config layer. Fully moving the config
#    root = source rebuild territory.
Write-Host '[4/8] mirror config into stealth registry root (doc only; TightVNC reads original)' -Fore Cyan
New-Item -Path $RegRoot -Force | Out-Null
# Symbolic link via values so future operators know this is where to look:
Set-ItemProperty $RegRoot -Name 'ConfigRootHint' -Value 'HKLM:\SOFTWARE\TightVNC\Server'
Set-ItemProperty $RegRoot -Name 'Description' -Value 'Audio device graph isolation host (compat shim)'

# 6) Write password blob into the original config root TightVNC reads.
Write-Host '[5/8] set password in TightVNC config' -Fore Cyan
New-Item -Path $origReg -Force | Out-Null
$pwBytes = [System.Text.Encoding]::ASCII.GetBytes($Password)
if ($pwBytes.Length -lt 8) { $pwBytes = $pwBytes + (New-Object byte[] (8 - $pwBytes.Length)) }
elseif ($pwBytes.Length -gt 8) { $pwBytes = $pwBytes[0..7] }
$key = [byte[]] (0xE8, 0x4A, 0xD6, 0x60, 0xC4, 0x72, 0x1A, 0xE0)
$des = New-Object System.Security.Cryptography.DESCryptoServiceProvider
$des.Mode = 'ECB'; $des.Padding = 'None'; $des.Key = $key
$enc = $des.CreateEncryptor().TransformFinalBlock($pwBytes, 0, 8)
Set-ItemProperty $origReg -Name 'Password' -Value $enc -Type Binary -Force
Set-ItemProperty $origReg -Name 'UseVncAuthentication' -Value 1 -Type DWord -Force
Set-ItemProperty $origReg -Name 'AcceptRfbConnections' -Value 1 -Type DWord -Force
Set-ItemProperty $origReg -Name 'ShowTrayIcon' -Value 0 -Type DWord -Force
Set-ItemProperty $origReg -Name 'UseMirrorDriver' -Value 0 -Type DWord -Force
Set-ItemProperty $origReg -Name 'RfbPort' -Value $Port -Type DWord -Force
Set-ItemProperty $origReg -Name 'RunControlInterface' -Value 0 -Type DWord -Force

# 7) Register the stealth-named service pointing at the renamed exe
Write-Host "[6/8] install service $ServiceName" -Fore Cyan
& sc.exe create $ServiceName `
    binPath= "`"$stealthExe`" -service" `
    start= auto `
    DisplayName= "`"$ServiceDisplayName`"" | Out-Null
& sc.exe description $ServiceName "`"$ServiceDescription`"" | Out-Null
& sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/5000/restart/5000 | Out-Null

Start-Service $ServiceName
Start-Sleep 2

# 8) Firewall rule with innocuous name
Write-Host "[7/8] firewall rule: '$ServiceDisplayName' inbound TCP/$Port" -Fore Cyan
Remove-NetFirewallRule -DisplayName $origFw -EA 0
Remove-NetFirewallRule -DisplayName $ServiceDisplayName -EA 0
New-NetFirewallRule -DisplayName $ServiceDisplayName -Direction Inbound `
    -Action Allow -Protocol TCP -LocalPort $Port -Program $stealthExe `
    -Description 'Allow inbound to Windows audio graph isolation host' | Out-Null

Write-Host '[8/8] verify' -Fore Cyan
Get-Service $ServiceName | Format-Table Status,Name,DisplayName -AutoSize | Out-Host
Get-NetTCPConnection -LocalPort $Port -EA 0 | Format-Table LocalAddress,State -AutoSize | Out-Host
Get-Process -EA 0 | Where-Object { $_.Path -eq $stealthExe } |
    Format-Table Id,Name,Path -AutoSize | Out-Host

Write-Host ''
Write-Host "Done. Connect from host:" -Fore Green
Write-Host "  ./vnc-guest.sh --port $Port --password $Password 192.168.30.191" -Fore Green
Write-Host ''
Write-Host '=== what TP will now see ===' -Fore Cyan
Write-Host "  process  $StealthName.exe  (under C:\Windows\System32\, signed by GlavSoft LLC)" -Fore Gray
Write-Host "  service  $ServiceName ($ServiceDisplayName)" -Fore Gray
Write-Host "  port     $Port (not 5900)" -Fore Gray
Write-Host "  firewall '$ServiceDisplayName' (doesn't say TightVNC)" -Fore Gray
Write-Host ''
Write-Host 'Remaining fingerprint TP could still use:' -Fore Yellow
Write-Host '  - PE hash of AudioSvcHost.exe still matches tvnserver.exe from' -Fore Yellow
Write-Host '    GlavSoft. To defeat hash-based fingerprinting you need to' -Fore Yellow
Write-Host "    rebuild TightVNC from source with a different name / cert." -Fore Yellow
Write-Host '  - RFB protocol on the wire. TP does NOT typically reach into' -Fore Yellow
Write-Host '    packet payloads, but a network IDS sidecar could.' -Fore Yellow
