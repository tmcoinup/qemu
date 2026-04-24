<#
.SYNOPSIS
  Deploy the from-scratch Win32 VNC server (AudioSvcHost.exe built by
  vnc-custom/build.sh) in the guest. Replaces any previous TightVNC
  install — this one has NO "TightVNC"/"tvnserver" strings anywhere,
  unique file hash (not in TP's fingerprint DB), registry under
  HKLM\SOFTWARE\Microsoft\Audio\GraphHost, service "AudioDeviceGraphHost",
  port 56789, and responds on the same RFB 3.8 VncAuth as TightVNC
  so deploy/vnc-guest.sh works unchanged.

.PARAMETER Port
  Listen port (default 56789).

.PARAMETER Password
  VNC password, max 8 chars (default 123456).

.PARAMETER Uninstall
  Undo install: stop + delete service + remove exe + clear registry.
#>
[CmdletBinding()]
param(
    [string]$BaseUrl = 'http://192.168.30.127:8080',
    [int]$Port = 56789,
    [string]$Password = '123456',
    [switch]$Uninstall
)

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Must run as Administrator'
}

$ErrorActionPreference = 'Continue'

$exe      = 'C:\Windows\System32\AudioSvcHost.exe'
$svc      = 'AudioDeviceGraphHost'
$regRoot  = 'HKLM:\SOFTWARE\Microsoft\Audio\GraphHost'
$fwName   = 'Audio Device Graph Host'

if ($Uninstall) {
    Write-Host '[uninstall] stopping + deleting service' -Fore Cyan
    & $exe -uninstall 2>&1 | Out-Null
    Start-Sleep 1
    & sc.exe delete $svc 2>&1 | Out-Null
    Remove-Item $exe -Force -EA 0
    Remove-Item $regRoot -Recurse -Force -EA 0
    Remove-NetFirewallRule -DisplayName $fwName -EA 0
    Write-Host '[uninstall] done.'
    return
}

# Tear down any previous stealth install (TightVNC rebrand or earlier
# version of this service).
Write-Host '[pre] removing any previous AudioDeviceGraphHost' -Fore Cyan
Stop-Service $svc -Force -EA 0
& sc.exe delete $svc 2>&1 | Out-Null
Remove-NetFirewallRule -DisplayName $fwName -EA 0

# Also disable vanilla TightVNC if it was there — we're replacing it.
Stop-Service tvnserver -Force -EA 0
Set-Service tvnserver -StartupType Disabled -EA 0

Write-Host "[1/5] download AudioSvcHost.exe from $BaseUrl" -Fore Cyan
$ProgressPreference = 'SilentlyContinue'
Invoke-WebRequest "$BaseUrl/AudioSvcHost.exe" -OutFile $exe -UseBasicParsing
"  size: $((Get-Item $exe).Length) bytes"

Write-Host '[2/5] registry: port + password' -Fore Cyan
New-Item -Path $regRoot -Force | Out-Null
Set-ItemProperty -Path $regRoot -Name 'ListenPort' -Value $Port -Type DWord -Force
Set-ItemProperty -Path $regRoot -Name 'Password' -Value $Password -Type String -Force
Set-ItemProperty -Path $regRoot -Name 'Description' -Value 'Audio device graph isolation host' -Force

Write-Host '[3/5] firewall: inbound TCP/' $Port -Fore Cyan
New-NetFirewallRule -DisplayName $fwName -Direction Inbound -Action Allow `
    -Protocol TCP -LocalPort $Port -Program $exe `
    -Description 'Inbound WDM audio graph isolation host' | Out-Null

Write-Host '[4/5] install + start service' -Fore Cyan
& $exe -install 2>&1 | Out-String

Start-Sleep 3

Write-Host '[5/5] verify' -Fore Cyan
Get-Service $svc | Format-Table Status,Name,DisplayName -AutoSize | Out-Host
Get-NetTCPConnection -LocalPort $Port -EA 0 | Format-Table LocalAddress,State -AutoSize | Out-Host

Write-Host ''
Write-Host '=== what TP sees now ===' -Fore Cyan
Write-Host "  binary   $exe  (custom self-built, no TightVNC strings, unique PE hash)" -Fore Gray
Write-Host "  service  $svc" -Fore Gray
Write-Host "  port     $Port" -Fore Gray
Write-Host "  registry $regRoot  (not HKLM\SOFTWARE\TightVNC anymore)" -Fore Gray
Write-Host ''
Write-Host 'Connect from host:' -Fore Green
Write-Host "  ./vnc-guest.sh --port $Port --password $Password 192.168.30.191" -Fore Green
