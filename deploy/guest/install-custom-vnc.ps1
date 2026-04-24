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
$svcOld   = 'AudioDeviceGraphHost'       # legacy service name (session-0 broken)
$taskName = 'AudioDeviceGraphHost'       # scheduled task in user session
$regRoot  = 'HKLM:\SOFTWARE\Microsoft\Audio\GraphHost'
$fwName   = 'Audio Device Graph Host'

if ($Uninstall) {
    Write-Host '[uninstall] stopping + removing' -Fore Cyan
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -EA 0
    & $exe -uninstall 2>&1 | Out-Null
    & sc.exe delete $svcOld 2>&1 | Out-Null
    Get-Process -Name 'AudioSvcHost' -EA 0 | Stop-Process -Force -EA 0
    Remove-Item $exe -Force -EA 0
    Remove-Item $regRoot -Recurse -Force -EA 0
    Remove-NetFirewallRule -DisplayName $fwName -EA 0
    Write-Host '[uninstall] done.'
    return
}

# Tear down any previous install (service-based AND task-based).
Write-Host '[pre] cleaning previous install' -Fore Cyan
Stop-Service $svcOld -Force -EA 0
& sc.exe delete $svcOld 2>&1 | Out-Null
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -EA 0
Get-Process -Name 'AudioSvcHost' -EA 0 | Stop-Process -Force -EA 0
Remove-NetFirewallRule -DisplayName $fwName -EA 0
# Disable vanilla TightVNC if it was there.
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

Write-Host "[3/5] firewall: inbound TCP/$Port" -Fore Cyan
New-NetFirewallRule -DisplayName $fwName -Direction Inbound -Action Allow `
    -Protocol TCP -LocalPort $Port -Program $exe `
    -Description 'Inbound WDM audio graph isolation host' | Out-Null

# Registering as Windows SERVICE puts us in Session 0, where BitBlt can
# only see the isolated services desktop (black screen). Register as a
# Scheduled Task triggered AtLogOn, running as the interactive user, so
# the process lives in the user session and GDI can actually see the
# logged-in desktop.
Write-Host "[4/5] schedule task '$taskName' at user logon (interactive)" -Fore Cyan
$action    = New-ScheduledTaskAction -Execute $exe -Argument '-console'
$trigger   = New-ScheduledTaskTrigger -AtLogOn
$principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 3 -RestartInterval ([TimeSpan]::FromMinutes(1))
Register-ScheduledTask -TaskName $taskName -Action $action `
    -Trigger $trigger -Principal $principal -Settings $settings `
    -Description 'Audio device graph isolation host' -Force | Out-Null

# Kick it off right now (so user doesn't have to log out+in).
Start-ScheduledTask -TaskName $taskName
Start-Sleep 2

Write-Host '[5/5] verify' -Fore Cyan
Get-Process -Name 'AudioSvcHost' -EA 0 |
    Format-Table Id,ProcessName,SessionId,Path -AutoSize | Out-Host
Get-NetTCPConnection -LocalPort $Port -EA 0 |
    Format-Table LocalAddress,State,OwningProcess -AutoSize | Out-Host

Write-Host ''
Write-Host '=== what TP sees ===' -Fore Cyan
Write-Host "  binary    $exe" -Fore Gray
Write-Host "  ran via   Scheduled Task $taskName  (user session — BitBlt sees real desktop)" -Fore Gray
Write-Host "  port      $Port" -Fore Gray
Write-Host "  registry  $regRoot" -Fore Gray
Write-Host ''
Write-Host 'Connect from host:' -Fore Green
Write-Host "  ./vnc-guest.sh --port $Port 1" -Fore Green
