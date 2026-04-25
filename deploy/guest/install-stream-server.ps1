<#
.SYNOPSIS
  Deploy the new H.264 streaming server stack on the guest:

    Channel 1 (port 56789, AudioSvcHost.exe)
        — existing custom VNC server, now used ONLY as input channel.
          Auth, keyboard + mouse SendInput. Framebuffer reads still work
          but the new client never asks for them.

    Channel 2 (port 56790, ffmpeg.exe wrapped in stream_video.ps1)
        — DXGI Desktop Duplication captures the active session,
          NVENC encodes H.264 (preset p1, tune ull), MPEG-TS over TCP.
          Listening, accepts one client; on disconnect the powershell
          wrapper restarts ffmpeg so the next reconnect just works.

  Both run in the user's interactive Session 1 via Scheduled Tasks
  (DDA + GDI both refuse to work in Session 0).

.PARAMETER BaseUrl
  HTTP root on host where ffmpeg.exe + AudioSvcHost.exe live.
  Default 192.168.30.127:8080 — same as install-custom-vnc.ps1.

.PARAMETER VideoPort
  TCP listen port for video stream.

.PARAMETER FrameRate
  Captured framerate. DDA hardware ceiling is the monitor refresh rate
  (60 Hz typical for vGPU virtual displays). Setting higher than the
  display's native rate just produces duplicate frames.

.PARAMETER Bitrate
  NVENC target bitrate (CBR). 15M is good for 1080p, 25M for 1440p.

.PARAMETER Uninstall
  Tear everything down.
#>
[CmdletBinding()]
param(
    [string]$BaseUrl   = 'http://192.168.30.127:8080',
    [int]$VideoPort    = 56790,
    [int]$FrameRate    = 60,
    [string]$Bitrate   = '15M',
    [switch]$Uninstall
)

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Must run as Administrator'
}
$ErrorActionPreference = 'Continue'

$nvDir    = 'C:\nv'
$ffExe    = "$nvDir\ffmpeg.exe"
$wrapper  = "$nvDir\stream_video.ps1"
$taskName = 'VideoStream'
$fwName   = 'Audio Stream'

function _Stop {
    Write-Host '[stop] killing existing stream' -Fore Yellow
    Stop-ScheduledTask -TaskName $taskName -EA 0
    Get-Process ffmpeg -EA 0 | Stop-Process -Force -EA 0
    Start-Sleep -Milliseconds 500
}

if ($Uninstall) {
    _Stop
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -EA 0
    Remove-Item $wrapper -EA 0
    Remove-NetFirewallRule -DisplayName $fwName -EA 0
    Write-Host '[uninstall] done.' -Fore Green
    return
}

_Stop
New-Item -Path $nvDir -ItemType Directory -Force | Out-Null

# 1. fetch ffmpeg.exe if missing or old
if (-not (Test-Path $ffExe) -or (Get-Item $ffExe).Length -lt 100MB) {
    Write-Host "[1/4] downloading $BaseUrl/ffmpeg.exe" -Fore Cyan
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest "$BaseUrl/ffmpeg.exe" -OutFile $ffExe -UseBasicParsing
    "  size: $((Get-Item $ffExe).Length) bytes"
} else {
    Write-Host "[1/4] reusing $ffExe ($((Get-Item $ffExe).Length) bytes)" -Fore Cyan
}

# 2. write the streaming wrapper
Write-Host '[2/4] writing stream_video.ps1' -Fore Cyan
@"
`$ff  = '$ffExe'
`$log = '$nvDir\stream.log'
'' | Out-File `$log
# Container choice: bare H.264 Annex-B over TCP. MPEG-TS adds a packet-
# alignment buffer on the demuxer side that costs 50-200 ms of latency
# for no real-world benefit on a single-stream private link.
# bufsize is one frame (~bitrate/fps) → encoder doesn't pre-buffer.
`$argList = @(
  '-y','-hide_banner','-loglevel','warning',
  '-filter_complex','ddagrab=output_idx=0:framerate=$FrameRate,hwdownload,format=bgra',
  '-c:v','h264_nvenc',
  '-preset','p1','-tune','ull','-zerolatency','1',
  '-rc','cbr','-b:v','$Bitrate','-maxrate','$Bitrate','-bufsize','500K',
  '-g','$FrameRate','-bf','0',
  '-flags','low_delay','-fflags','nobuffer',
  '-flush_packets','1',
  '-strict','experimental',
  '-f','h264','tcp://0.0.0.0:${VideoPort}?listen=1'
)
while (`$true) {
    "[`$(Get-Date -Format 'HH:mm:ss')] starting ffmpeg" | Add-Content `$log
    & `$ff @argList 2>&1 | Add-Content `$log
    "[`$(Get-Date -Format 'HH:mm:ss')] ffmpeg exited" | Add-Content `$log
    Start-Sleep -Milliseconds 200
}
"@ | Out-File $wrapper -Encoding UTF8

# 3. open firewall TCP $VideoPort
Write-Host "[3/4] firewall: inbound TCP/$VideoPort" -Fore Cyan
Remove-NetFirewallRule -DisplayName $fwName -EA 0
New-NetFirewallRule -DisplayName $fwName -Direction Inbound -Action Allow `
    -Protocol TCP -LocalPort $VideoPort -Program $ffExe `
    -Description 'Audio device stream relay' | Out-Null

# 4. (re)register Scheduled Task
Write-Host "[4/4] register + start Scheduled Task '$taskName'" -Fore Cyan
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -EA 0
$action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File $wrapper"
$trigger   = New-ScheduledTaskTrigger -AtLogOn
$principal = New-ScheduledTaskPrincipal `
    -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) `
    -RunLevel Highest -LogonType Interactive
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 3 -RestartInterval ([TimeSpan]::FromMinutes(1))
Register-ScheduledTask -TaskName $taskName -Action $action `
    -Trigger $trigger -Principal $principal -Settings $settings `
    -Description 'Audio device stream relay (DDA + NVENC)' -Force | Out-Null

Start-ScheduledTask -TaskName $taskName
Start-Sleep 2

# Verify
Write-Host ''
Write-Host '=== verify ===' -Fore Cyan
Get-Process ffmpeg -EA 0 | Format-Table Id,SessionId,Path -AutoSize | Out-Host
Get-NetTCPConnection -LocalPort $VideoPort -EA 0 |
    Format-Table LocalAddress,State,OwningProcess -AutoSize | Out-Host

Write-Host ''
Write-Host 'Connect from host:' -Fore Green
Write-Host "  ./stream-guest.sh 1" -Fore Green
Write-Host "(stream-guest.sh starts mpv on video TCP/$VideoPort + input forwarding to AudioSvcHost on TCP/56789)" -Fore Gray
