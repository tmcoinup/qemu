<#
.SYNOPSIS
  Prepare the guest for a TP-sensitive game launch (DNF / 地下城与勇士).
  Stops / hides every remote-control surface known to be on TP's blocklist,
  prints a "what TP would still see" report so you can judge whether to
  launch the game now.

.PARAMETER Mode
  Prep    — stop services / kill processes, close surface. Default.
  Restore — re-enable everything (tvnserver service back up, etc).
  Status  — only scan + print, don't touch anything.

.EXAMPLE
  C:\nv\dnf-prep.ps1                 # prep
  C:\nv\dnf-prep.ps1 Status          # just scan
  C:\nv\dnf-prep.ps1 Restore         # after closing the game
#>
param(
    [ValidateSet('Prep','Restore','Status')]
    [string]$Mode = 'Prep'
)

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Must run as Administrator'
}

$ErrorActionPreference = 'Continue'

# Remote tools TP is known to flag. Add here if we deploy more.
$remoteProcesses = @(
    'tvnserver', 'winvnc', 'winvnc4', 'tvncontrol', 'vncviewer',
    'TeamViewer', 'TeamViewer_Service', 'tv_w32', 'tv_x64',
    'AnyDesk',
    'parsecd', 'parsec',
    'sunshine',
    'looking-glass-host',
    'rdpwrap'
)
$remoteServices = @(
    'tvnserver',
    'TeamViewer',
    'AnyDesk',
    'Parsec',
    'SunshineService',
    # Our own streaming stack. NvDisplayContainer manages nv_stream_relay
    # (DDA capture → ivshmem ring) and AudioSvcHost (RFB input → loopback
    # 56789). Stopping the service kills both children (it's the watchdog
    # parent), which frees the GPU capture pipe and removes our only
    # listening socket — both of which DNF's TP flags as suspicious.
    'NvDisplayContainer'
)
$remoteFirewall = 'TightVNC In','TeamViewer','AnyDesk','Parsec','Sunshine',
                  'Audio Device Graph Host'

# Process names that aren't matched by service-stop alone — we kill them
# explicitly in case a stray watchdog hasn't reaped them yet.
$ourProcesses = @('nv_stream_relay', 'AudioSvcHost', 'NvDisplayContainer')

function Show-Status {
    Write-Host ''
    Write-Host '== TP-visible remote-access surface ==' -Fore Cyan

    $svcHits = Get-Service -EA 0 | Where-Object {
        $_.Name -in $remoteServices -and $_.Status -eq 'Running'
    }
    if ($svcHits) {
        Write-Host 'Services (running):' -Fore Yellow
        $svcHits | Format-Table Name,Status,StartType -AutoSize | Out-Host
    } else {
        Write-Host '  services: none running' -Fore Green
    }

    $procHits = Get-Process -EA 0 | Where-Object { $_.Name -in $remoteProcesses }
    if ($procHits) {
        Write-Host 'Processes (running):' -Fore Yellow
        $procHits | Format-Table Id,Name,Path -AutoSize | Out-Host
    } else {
        Write-Host '  processes: none running' -Fore Green
    }

    # Known VNC / TeamViewer / AnyDesk / Parsec ports + our own input
    # listener (56789, loopback only). Video is pure ivshmem so there's
    # no outbound traffic now — this is mostly to catch competitors'
    # stragglers and an unexpected loopback listener that survived stop.
    $portHits = @()
    foreach ($p in 5900,5901,5902,5800,7070,7100,7575,24800,56789) {
        $c = Get-NetTCPConnection -LocalPort $p -State Listen -EA 0
        if ($c) { $portHits += $c }
    }
    if ($portHits) {
        Write-Host 'Ports (listening):' -Fore Yellow
        $portHits | Select-Object LocalAddress,LocalPort,OwningProcess,State | Format-Table -AutoSize | Out-Host
    } else {
        Write-Host '  remote-access ports: no listeners' -Fore Green
    }

    Write-Host ''
    Write-Host '== Current session ==' -Fore Cyan
    if (-not ('TP_U32' -as [type])) {
        Add-Type -Name TP_U32 -Namespace TPProbe -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern int GetSystemMetrics(int n);
'@ | Out-Null
    }
    $smRemote = [TPProbe.TP_U32]::GetSystemMetrics(0x1000)  # SM_REMOTESESSION=0x1000
    "  GetSystemMetrics(SM_REMOTESESSION) = $smRemote $(if($smRemote){'(inside RDP — TP flags)'}else{'(local console — good)'})"

    $qwinsta = qwinsta 2>&1 | Out-String
    Write-Host '  qwinsta:' -Fore Gray
    $qwinsta.Trim() -split "`r?`n" | ForEach-Object { "    $_" }

    Write-Host ''
    Write-Host '== Display adapters ==' -Fore Cyan
    Get-PnpDevice -Class Display -PresentOnly:$true |
        Format-Table Status,FriendlyName -AutoSize | Out-Host
}

function Do-Prep {
    Write-Host '[prep] stopping remote-access services' -Fore Cyan
    foreach ($s in $remoteServices) {
        $svc = Get-Service $s -EA 0
        if ($svc -and $svc.Status -ne 'Stopped') {
            Write-Host "  stopping $s"
            Stop-Service $s -Force -EA 0
        }
    }

    Write-Host '[prep] killing stragglers' -Fore Cyan
    $killList = $remoteProcesses + $ourProcesses
    Get-Process -EA 0 | Where-Object { $_.Name -in $killList } |
        ForEach-Object {
            Write-Host "  kill $($_.Name) pid=$($_.Id)"
            Stop-Process -Id $_.Id -Force -EA 0
        }

    Write-Host '[prep] disabling firewall rules that name these tools' -Fore Cyan
    foreach ($r in $remoteFirewall) {
        Get-NetFirewallRule -DisplayName $r -EA 0 | ForEach-Object {
            "  disable $($_.DisplayName)"
            Disable-NetFirewallRule -Name $_.Name -EA 0
        }
    }

    Write-Host '[prep] disconnecting lingering RDP ghost sessions' -Fore Cyan
    # Present=True live IDD must stay (current RDP uses it); drop ghosts.
    Get-PnpDevice -PresentOnly:$false -EA 0 | Where-Object {
        (-not $_.Present) -and ($_.InstanceId -match 'REMOTEDISPLAYENUM')
    } | ForEach-Object {
        & pnputil.exe /remove-device $_.InstanceId 2>&1 | Out-Null
    }

    Show-Status

    Write-Host ''
    Write-Host 'Ready. Launch DNF. When finished, run:' -Fore Green
    Write-Host '  C:\nv\dnf-prep.ps1 Restore' -Fore Green
    Write-Host ''
    Write-Host 'NOTE: you are still in an RDP session if you ran this via WinRM/RDP.' -Fore Yellow
    Write-Host '      TP may flag SM_REMOTESESSION=1. Best practice:' -Fore Yellow
    Write-Host '      1) prep from RDP' -Fore Yellow
    Write-Host '      2) connect locally (gtk / 捕获卡) — or accept the RDP tell' -Fore Yellow
}

function Do-Restore {
    Write-Host '[restore] re-enabling firewall rules' -Fore Cyan
    foreach ($r in $remoteFirewall) {
        Get-NetFirewallRule -DisplayName $r -EA 0 | ForEach-Object {
            "  enable $($_.DisplayName)"
            Enable-NetFirewallRule -Name $_.Name -EA 0
        }
    }
    Write-Host '[restore] starting services that were off' -Fore Cyan
    foreach ($s in $remoteServices) {
        $svc = Get-Service $s -EA 0
        if ($svc -and $svc.Status -eq 'Stopped' -and $svc.StartType -ne 'Disabled') {
            Write-Host "  start $s"
            Start-Service $s -EA 0
        }
    }
    Show-Status
}

switch ($Mode) {
    'Prep'    { Do-Prep }
    'Restore' { Do-Restore }
    'Status'  { Show-Status }
}
