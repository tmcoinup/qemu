<#
.SYNOPSIS
  Deploy the streaming stack as a Windows Service (replaces the older
  Scheduled-Task install path from install-stream-server.ps1 +
  install-custom-vnc.ps1).

  Pieces this installer drops on the guest:

    C:\Windows\System32\NvDisplayContainer.exe
        Service launcher. Registered as a Windows Service named
        "NvDisplayContainer" (display: "NVIDIA Display Container LS"),
        runs as LocalSystem, auto-start. Service main loop:
          - WTSGetActiveConsoleSessionId / WTSQueryUserToken
          - DuplicateTokenEx + CreateProcessAsUser
          - spawns NvSvcStream.exe + AudioSvcHost.exe in the active
            console session (Session 1) so DDA / GDI capture sees
            the real desktop, not the empty Session-0 services desktop
          - watchdog: respawn on crash with backoff

    C:\Windows\System32\NvSvcStream.exe
        Renamed copy of ffmpeg 6.1.1 (NVENC SDK 12.1, compatible with
        guest driver 538.33). Runs ddagrab + h264_nvenc + raw H.264
        over TCP listen on 56790.

    C:\Windows\System32\AudioSvcHost.exe
        Our custom RFB 3.8 input listener on TCP 56789. Same binary
        as before, only the lifecycle owner changes (was Scheduled Task,
        now Windows Service spawns it).

  Also tears down any previous install:
    Scheduled Task  "VideoStream"             (legacy ffmpeg loop)
    Scheduled Task  "AudioDeviceGraphHost"    (legacy AudioSvcHost)
    Service         "NvDisplayContainer"      (so re-install is idempotent)

.PARAMETER BaseUrl
  HTTP root on host where NvDisplayContainer.exe + NvSvcStream.exe (or
  ffmpeg.exe — we accept either name) + AudioSvcHost.exe live.

.PARAMETER Uninstall
  Tear everything down: stop + delete the service, remove the executables,
  remove firewall rules.
#>
[CmdletBinding()]
param(
    [string]$BaseUrl  = 'http://192.168.30.127:8080',
    [int]$VideoPort   = 56790,
    [int]$InputPort   = 56789,
    # NVENC tuning. Defaults match the original 1080p numbers; lower
    # them for multi-VM scenarios or when the guest GPU is already busy.
    #   Bitrate "5M" + FrameRate 30 → ~5 Mbps stream, ~12 % GPU,
    #     fine for casual remote work, 10 VMs comfortably fit on
    #     gigabit (50 Mbps total) and a single mid-range GPU.
    #   Bitrate "15M" + FrameRate 60 → original "feels native" tier.
    [string]$Bitrate    = '15M',
    [int]$FrameRate     = 60,
    # 'tcp' (default) — NvDisplayContainer spawns NvSvcStream (ffmpeg)
    #     directly with a TCP listener on $VideoPort.
    # 'shmem' — NvDisplayContainer spawns nv_stream_relay.exe instead;
    #     the relay does the ivshmem ring writes. Requires the
    #     ivshmem.sys driver to already be installed in the guest
    #     (./deploy/install-ivshmem-driver.sh).
    [ValidateSet('tcp','shmem')][string]$Mode = 'tcp',
    [switch]$Uninstall
)

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Must run as Administrator'
}
$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$svcExe   = 'C:\Windows\System32\NvDisplayContainer.exe'
$strmExe  = 'C:\Windows\System32\NvSvcStream.exe'
$inputExe = 'C:\Windows\System32\AudioSvcHost.exe'

$svcName  = 'NvDisplayContainer'
$fwVideo  = 'NVIDIA Display Container LS'
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
    Get-Process -Name 'NvDisplayContainer','NvSvcStream','AudioSvcHost','ffmpeg' -EA 0 |
        Stop-Process -Force -EA 0
    Start-Sleep -Milliseconds 300
}

if ($Uninstall) {
    _StopAndDelete
    Remove-Item $svcExe   -EA 0
    Remove-Item $strmExe  -EA 0
    Remove-NetFirewallRule -DisplayName $fwVideo -EA 0
    Remove-NetFirewallRule -DisplayName $fwInput -EA 0
    Write-Host '[uninstall] done' -Fore Green
    return
}

_StopAndDelete

# ── 1) fetch binaries ───────────────────────────────────────────
Write-Host "[1/5] downloading binaries from $BaseUrl" -Fore Cyan

Invoke-WebRequest "$BaseUrl/NvDisplayContainer.exe" -OutFile $svcExe -UseBasicParsing
"  $svcExe : $((Get-Item $svcExe).Length) bytes"

# Accept either the renamed or original name on the wire — local
# write-target is always System32\NvSvcStream.exe.
$tryUrls = @("$BaseUrl/NvSvcStream.exe", "$BaseUrl/ffmpeg.exe")
$ok = $false
foreach ($u in $tryUrls) {
    try {
        Invoke-WebRequest $u -OutFile $strmExe -UseBasicParsing -EA Stop
        "  $strmExe : $((Get-Item $strmExe).Length) bytes (from $u)"
        $ok = $true; break
    } catch { }
}
if (-not $ok) { throw "could not fetch stream binary from $BaseUrl" }

Invoke-WebRequest "$BaseUrl/AudioSvcHost.exe" -OutFile $inputExe -UseBasicParsing
"  $inputExe : $((Get-Item $inputExe).Length) bytes"

# Shmem-mode also needs the relay binary (writes the ivshmem ring;
# spawns NvSvcStream as its encoder child).
$relayExe = 'C:\Windows\System32\nv_stream_relay.exe'
if ($Mode -eq 'shmem') {
    Invoke-WebRequest "$BaseUrl/nv_stream_relay.exe" -OutFile $relayExe -UseBasicParsing
    "  $relayExe : $((Get-Item $relayExe).Length) bytes"
}

# ── 1.5) write tuning to registry so the service picks it up ──
Write-Host "[1.5/5] config: bitrate=$Bitrate framerate=$FrameRate port=$VideoPort mode=$Mode" -Fore Cyan
$cfgKey = 'HKLM:\SOFTWARE\NVIDIA\DisplayContainer\Stream'
New-Item -Path $cfgKey -Force | Out-Null
Set-ItemProperty -Path $cfgKey -Name 'Bitrate'   -Value $Bitrate   -Type String
Set-ItemProperty -Path $cfgKey -Name 'FrameRate' -Value $FrameRate -Type DWord
Set-ItemProperty -Path $cfgKey -Name 'VideoPort' -Value $VideoPort -Type DWord
Set-ItemProperty -Path $cfgKey -Name 'Mode'      -Value $Mode      -Type String

# ── 2) firewall ────────────────────────────────────────────────
Write-Host "[2/5] firewall: TCP/$VideoPort + TCP/$InputPort" -Fore Cyan
Remove-NetFirewallRule -DisplayName $fwVideo -EA 0
Remove-NetFirewallRule -DisplayName $fwInput -EA 0
New-NetFirewallRule -DisplayName $fwVideo -Direction Inbound -Action Allow `
    -Protocol TCP -LocalPort $VideoPort -Program $strmExe `
    -Description 'Audio device stream relay' | Out-Null
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
Get-Process -Name 'NvDisplayContainer','NvSvcStream','AudioSvcHost' -EA 0 |
    Select-Object Id, SessionId, ProcessName, Path |
    Format-Table -AutoSize | Out-Host

Write-Host ''
Write-Host '=== layout ===' -Fore Cyan
Write-Host "  service       $svcName ($fwVideo)" -Fore Gray
Write-Host "  launcher      $svcExe" -Fore Gray
Write-Host "  video child   $strmExe -> TCP $VideoPort" -Fore Gray
Write-Host "  input child   $inputExe -> TCP $InputPort" -Fore Gray
Write-Host "  service log   C:\nv\nv-svc.log" -Fore Gray
Write-Host ''
Write-Host 'Connect from host:' -Fore Green
Write-Host "  ./deploy/stream-guest.sh 1" -Fore Green
