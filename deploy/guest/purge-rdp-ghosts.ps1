<#
.SYNOPSIS
  Remove only ghost (Present=False) Microsoft Remote Display Adapter
  entries from PnP. Never touches the live session's IDD.

.DESCRIPTION
  Every RDP reconnect spawns a NEW SWD\REMOTEDISPLAYENUM\RDPIDD_...
  device node (SESSIONID_NNN), and the previous session's node is kept
  in the PnP database as Present=False ghost. Over time Device Manager
  accumulates 3+ "Microsoft Remote Display Adapter" entries even though
  only one is actually mapped to a live session.

  This script drops the ghosts via `pnputil /remove-device`. The live
  IDD (Present=True) stays — that's what the current RDP session uses
  for desktop rendering, killing it would either black-screen the session
  or force Windows to fall back to 800x600 XDDM mode.

  Strategy inspired by qemu2/deploy/guest-scripts/purge-display-ghosts.ps1
  from the earlier 553.24 stealth stack — the "disable on connect" path
  (old hide-rdp-idd.ps1 + HideRdpIdd scheduled task) turned out to break
  RDP resolution and has been replaced by this ghost-only cleanup.

.EXAMPLE
  # One-shot
  powershell -ExecutionPolicy Bypass -File .\purge-rdp-ghosts.ps1

  # Install as scheduled task that fires on RDP disconnect events
  .\purge-rdp-ghosts.ps1 -Install
#>
[CmdletBinding()]
param(
    [switch]$Install
)

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Must run as Administrator'
}

function Purge-Once {
    $ErrorActionPreference = 'SilentlyContinue'

    # Collect ghost entries we want to remove:
    #   - DISPLAY class devices that are Present=False (dead driver bindings)
    #   - Anything under SWD\REMOTEDISPLAYENUM that's Present=False (old RDP
    #     IDD sessions)
    #   - ROOT\BASICRENDER Present=False ghost
    $targets = @()
    $targets += Get-PnpDevice -Class Display -PresentOnly:$false -EA 0 |
        Where-Object { -not $_.Present }
    $targets += Get-PnpDevice -PresentOnly:$false -EA 0 | Where-Object {
        (-not $_.Present) -and
        ($_.InstanceId -match 'REMOTEDISPLAYENUM' -or
         $_.InstanceId -match 'ROOT\\BASICRENDER')
    }

    $targets = $targets | Sort-Object InstanceId -Unique

    Write-Host "[purge] ghosts found: $($targets.Count)"
    foreach ($t in $targets) {
        Write-Host "  remove  $($t.FriendlyName)  $($t.InstanceId)"
        $r = & pnputil.exe /remove-device $t.InstanceId 2>&1 | Out-String
        Write-Host "    $($r.Trim())"
    }

    Write-Host ''
    Write-Host '[purge] live Display devices now:'
    Get-PnpDevice -Class Display -PresentOnly:$true | Format-Table Status, FriendlyName, InstanceId -AutoSize
}

if (-not $Install) {
    Purge-Once
    return
}

# ─── Install as scheduled task ─────────────────────────────────────────
$dst = 'C:\nv\purge-rdp-ghosts.ps1'
# Avoid self-copy error when we're already running from $dst.
$src = $MyInvocation.MyCommand.Path
if ($src -and (Resolve-Path -LiteralPath $src -EA 0).Path -ne (Resolve-Path -LiteralPath $dst -EA 0).Path) {
    Copy-Item -Path $src -Destination $dst -Force
}

$taskName = 'PurgeRdpGhosts'
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -EA 0

# Fire on RDP session connect + disconnect (event IDs 21, 23, 24, 25 from
# TerminalServices-LocalSessionManager/Operational). 23 = logoff, 24 = session
# disconnected — that's when new ghosts appear.
$xml = @"
<QueryList>
  <Query Id="0" Path="Microsoft-Windows-TerminalServices-LocalSessionManager/Operational">
    <Select Path="Microsoft-Windows-TerminalServices-LocalSessionManager/Operational">
        *[System[(EventID=21 or EventID=23 or EventID=24 or EventID=25)]]
    </Select>
  </Query>
</QueryList>
"@
$evtTrigger = New-CimInstance -CimClass (Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler) -ClientOnly -Property @{
    Enabled = $true
    Subscription = $xml
}
$bootTrigger = New-ScheduledTaskTrigger -AtStartup
$logonTrigger = New-ScheduledTaskTrigger -AtLogOn

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$dst`""
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::FromMinutes(1)) `
    -StartWhenAvailable
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask -TaskName $taskName `
    -Trigger @($evtTrigger, $bootTrigger, $logonTrigger) `
    -Action $action -Settings $settings -Principal $principal `
    -Description 'Remove ghost RDP/Display PnP entries on session events' | Out-Null

Write-Host "[purge] scheduled task '$taskName' installed (SYSTEM)."
Write-Host '[purge] running once now to clear the current backlog:'
Purge-Once
