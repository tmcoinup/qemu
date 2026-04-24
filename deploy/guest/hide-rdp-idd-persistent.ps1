<#
.SYNOPSIS
  Persistently hide Microsoft Remote Display Adapter (SWD\REMOTEDISPLAYENUM\...)
  from Device Manager / WMI in an RDP session.

.DESCRIPTION
  Windows recreates a fresh RDPIDD_INDIRECTDISPLAY device on every RDP
  session connect, so a one-shot Disable-PnpDevice comes back on the next
  connect. This installs a Scheduled Task that fires on EventLog event
  TerminalServices-LocalSessionManager/Operational Id=21 (session logon) —
  the task re-runs Disable-PnpDevice on every new RDP session.

  The task runs as SYSTEM so it can touch PnP regardless of who logs in.

  Idempotent: re-running this replaces the old task if present.
#>

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Must run as Administrator'
}

$scriptDir = 'C:\nv'
New-Item -Type Directory -Force $scriptDir | Out-Null

# Write the disable worker
$worker = Join-Path $scriptDir 'disable-rdp-idd.ps1'
@'
$ErrorActionPreference = 'SilentlyContinue'
# Disable any Microsoft Remote Display Adapter / BasicRender virtual monitor
# that PnP just re-enumerated. Loops for 30 s to catch late arrivals.
for ($i = 0; $i -lt 15; $i++) {
    $idds = Get-PnpDevice | Where-Object {
        $_.Status -eq 'OK' -and (
            $_.InstanceId -like 'SWD\REMOTEDISPLAYENUM*' -or
            $_.InstanceId -like 'ROOT\BASICRENDER*'
        )
    }
    if ($idds) {
        foreach ($d in $idds) {
            Disable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -EA 0
        }
    }
    Start-Sleep -Seconds 2
}
'@ | Set-Content -Path $worker -Encoding UTF8
Write-Host "wrote $worker"

# Remove old task if present
$taskName = 'HideRdpIdd'
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -EA 0

# Trigger: TerminalServices-LocalSessionManager/Operational event 21 (session logon)
$trigger = New-ScheduledTaskTrigger -AtStartup
$triggerLogon = New-ScheduledTaskTrigger -AtLogOn

# Use event-based trigger too: fires on EventID 21/25 (connect/reconnect)
$xml = @"
<QueryList>
  <Query Id="0" Path="Microsoft-Windows-TerminalServices-LocalSessionManager/Operational">
    <Select Path="Microsoft-Windows-TerminalServices-LocalSessionManager/Operational">
        *[System[(EventID=21 or EventID=25)]]
    </Select>
  </Query>
</QueryList>
"@
$cim = New-CimInstance -CimClass (Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler) -ClientOnly -Property @{
    Enabled = $true
    Subscription = $xml
}

$action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$worker`""

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::FromMinutes(2)) `
    -StartWhenAvailable

$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

$task = Register-ScheduledTask `
    -TaskName $taskName `
    -Trigger @($trigger, $triggerLogon, $cim) `
    -Action $action `
    -Settings $settings `
    -Principal $principal `
    -Description 'Hide Microsoft Remote Display Adapter on each RDP session connect'

Write-Host "Scheduled Task '$taskName' registered (SYSTEM, at startup + logon + session events 21/25)"

# Run once right now so current session is clean
Write-Host "Running worker once to clean current session..."
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $worker

# Verify
Write-Host ''
Write-Host 'After disable — display devices:'
Get-PnpDevice -Class Display | Where-Object { $_.Status -eq 'OK' } | Format-Table Status,Name,DeviceID -AutoSize
