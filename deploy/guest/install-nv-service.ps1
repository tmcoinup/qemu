<#
.SYNOPSIS
  Deploy the streaming stack as a Windows Service.

  Pieces this installer drops on the guest:

    C:\Windows\System32\NvDisplayContainer.exe
        Service launcher. Registered as a Windows Service named
        "NvDisplayContainer" (display: "NVIDIA Display Container LS"),
        runs as LocalSystem, auto-start. Service main loop:
          - WTSGetActiveConsoleSessionId / WTSQueryUserToken
          - DuplicateTokenEx + CreateProcessAsUser
          - spawns NvStreamSvc.exe + AudioSvcHost.exe in the active
            console session (Session 1) so DDA capture sees the real
            desktop, not the empty Session-0 services desktop
          - watchdog: respawn on crash with backoff

    C:\Windows\System32\NvStreamSvc.exe
        DDA capture → 32x32 dirty-tile diff → ivshmem ring writer.
        Also runs an input_pump thread that drains the ivshmem input
        ring and forwards RFB events to AudioSvcHost over loopback.

    C:\Windows\System32\AudioSvcHost.exe
        Custom RFB 3.8 input listener on TCP 127.0.0.1:56789.
        Translates RFB events into Win32 SendInput calls.

  Also tears down any previous install (legacy scheduled tasks +
  service) so re-install is idempotent.

.PARAMETER BaseUrl
  HTTP root on host where NvDisplayContainer.exe + NvStreamSvc.exe
  + AudioSvcHost.exe live.

.PARAMETER Uninstall
  Tear everything down: stop + delete the service, remove the
  executables, remove firewall rules.
#>
[CmdletBinding()]
param(
    [string]$BaseUrl    = 'http://192.168.30.127:8080',
    [int]$InputPort     = 56789,
    # FrameRate 默认 30。60 fps 在 1920x1200 上 nv_stream_relay (DDA capture +
    # FNV-1a tile hash + dirty-tile pack) 占 ~15% guest CPU；30 fps 大约减半 +
    # 桌面/办公场景用户感觉不到差别。游戏/视频可以 install-nv-service.sh
    # 1 --framerate 60 临时拉高。
    [int]$FrameRate     = 30,
    [int]$DesktopWidth  = 1920,
    [int]$DesktopHeight = 1080,
    [switch]$Uninstall
)

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Must run as Administrator'
}
$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$svcExe   = 'C:\Windows\System32\NvDisplayContainer.exe'
$relayExe = 'C:\Windows\System32\NvStreamSvc.exe'
# 老路径，便于卸载 / 兼容历史装机
$oldRelayExe = 'C:\Windows\System32\nv_stream_relay.exe'
$inputExe = 'C:\Windows\System32\AudioSvcHost.exe'

$svcName  = 'NvDisplayContainer'
$fwInput  = 'Audio Device Graph Host'

function _StopAndDelete {
    Write-Host '[pre] stopping any previous install' -Fore Yellow

    # Old Scheduled Task path
    foreach ($tn in @('VideoStream', 'AudioDeviceGraphHost')) {
        Stop-ScheduledTask -TaskName $tn -EA 0
        Unregister-ScheduledTask -TaskName $tn -Confirm:$false -EA 0
    }

    # Existing service of ours
    & sc.exe stop   $svcName 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
    & sc.exe delete $svcName 2>&1 | Out-Null

    # Linger processes (in case child wasn't killed by service stop)
    Get-Process -Name 'NvDisplayContainer','NvStreamSvc','nv_stream_relay','AudioSvcHost','NvSvcStream','ffmpeg' -EA 0 |
        Stop-Process -Force -EA 0
    # Old executable from before the rename — clear it so the renamed
    # binary doesn't have to coexist with a stale System32 copy.
    Remove-Item 'C:\Windows\System32\nv_stream_relay.exe' -EA 0
    Start-Sleep -Milliseconds 300
}

if ($Uninstall) {
    _StopAndDelete
    Remove-Item $svcExe      -EA 0
    Remove-Item $relayExe    -EA 0
    Remove-Item $oldRelayExe -EA 0
    Remove-Item 'C:\Windows\System32\NvSvcStream.exe' -EA 0
    Remove-NetFirewallRule -DisplayName 'NVIDIA Display Container LS' -EA 0
    Remove-NetFirewallRule -DisplayName $fwInput -EA 0
    Write-Host '[uninstall] done' -Fore Green
    return
}

_StopAndDelete

# ── 1) fetch binaries ───────────────────────────────────────────
Write-Host "[1/5] downloading binaries from $BaseUrl" -Fore Cyan

Invoke-WebRequest "$BaseUrl/NvDisplayContainer.exe" -OutFile $svcExe -UseBasicParsing
"  $svcExe : $((Get-Item $svcExe).Length) bytes"

Invoke-WebRequest "$BaseUrl/NvStreamSvc.exe" -OutFile $relayExe -UseBasicParsing
"  $relayExe : $((Get-Item $relayExe).Length) bytes"

Invoke-WebRequest "$BaseUrl/AudioSvcHost.exe" -OutFile $inputExe -UseBasicParsing
"  $inputExe : $((Get-Item $inputExe).Length) bytes"

# Drop legacy NvSvcStream.exe (renamed ffmpeg) if a previous install
# left it behind. Service no longer touches it.
Remove-Item 'C:\Windows\System32\NvSvcStream.exe' -EA 0

# ── 1.5) write tuning to registry so the relay picks it up ──
Write-Host "[1.5/5] config: framerate=$FrameRate desktop=${DesktopWidth}x${DesktopHeight}" -Fore Cyan
$cfgKey = 'HKLM:\SOFTWARE\NVIDIA\DisplayContainer\Stream'
New-Item -Path $cfgKey -Force | Out-Null
Set-ItemProperty -Path $cfgKey -Name 'FrameRate'     -Value $FrameRate     -Type DWord
Set-ItemProperty -Path $cfgKey -Name 'DesktopWidth'  -Value $DesktopWidth  -Type DWord
Set-ItemProperty -Path $cfgKey -Name 'DesktopHeight' -Value $DesktopHeight -Type DWord

# Drop stale TCP-mode keys from previous installs
Remove-ItemProperty -Path $cfgKey -Name 'Mode'      -EA 0
Remove-ItemProperty -Path $cfgKey -Name 'Bitrate'   -EA 0
Remove-ItemProperty -Path $cfgKey -Name 'VideoPort' -EA 0

# ── 2) firewall ────────────────────────────────────────────────
# Only the input loopback listener needs an explicit allow; video is
# pure ivshmem (RAM-to-RAM, no socket).
Write-Host "[2/5] firewall: TCP/$InputPort (loopback input)" -Fore Cyan
Remove-NetFirewallRule -DisplayName 'NVIDIA Display Container LS' -EA 0
Remove-NetFirewallRule -DisplayName $fwInput -EA 0
New-NetFirewallRule -DisplayName $fwInput -Direction Inbound -Action Allow `
    -Protocol TCP -LocalPort $InputPort -Program $inputExe `
    -Description 'Audio device graph control channel' | Out-Null

# ── 3) register service ────────────────────────────────────────
Write-Host "[3/5] registering Windows Service '$svcName'" -Fore Cyan
& $svcExe -install
if ($LASTEXITCODE -ne 0) {
    throw "service install returned $LASTEXITCODE"
}

# ── 4) verify ──────────────────────────────────────────────────
Write-Host "[4/5] verify service" -Fore Cyan
Start-Sleep 2
& sc.exe query $svcName | Out-Host

# ── 5) verify children spawned ─────────────────────────────────
Write-Host "[5/5] verify children spawned in Session 1 (give it ~5s)" -Fore Cyan
Start-Sleep 5
Get-Process -Name 'NvDisplayContainer','nv_stream_relay','AudioSvcHost' -EA 0 |
    Select-Object Id, SessionId, ProcessName, Path |
    Format-Table -AutoSize | Out-Host

Write-Host ''
Write-Host '=== layout ===' -Fore Cyan
Write-Host "  service       $svcName" -Fore Gray
Write-Host "  launcher      $svcExe" -Fore Gray
Write-Host "  relay         $relayExe -> ivshmem video ring" -Fore Gray
Write-Host "  input child   $inputExe -> 127.0.0.1:$InputPort" -Fore Gray
Write-Host "  service log   C:\nv\nv-svc.log" -Fore Gray
Write-Host "  relay log     C:\nv\nv-stream-relay.log" -Fore Gray
Write-Host ''
Write-Host 'Connect from host:' -Fore Green
Write-Host "  ./deploy/connect.sh 1" -Fore Green
