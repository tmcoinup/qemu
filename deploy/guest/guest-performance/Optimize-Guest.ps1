#requires -Version 5.1
<#
.SYNOPSIS
  Audit, apply, verify, or roll back the G-11 native-display guest tuning.

.DESCRIPTION
  The recommended profile removes avoidable post-logon contention from old
  guest-relay/RDP display helpers, selects the built-in High performance power
  plan when available, and removes Explorer's artificial startup-app delay.

  It deliberately does not modify BCD, Windows driver signing, kernel drivers,
  Defender, Windows Update, SysMain, Windows Search, the page file, the GRID
  driver, or the official NVIDIA Display Container service.

  Apply is transactional.  Original registry values, the active power scheme,
  the exact enabled state of owned legacy tasks, and the custom relay service
  state are stored under C:\ProgramData\G11GuestPerformance.  Rollback uses
  only that state and never guesses.
#>
[CmdletBinding()]
param(
    [ValidateSet('Audit', 'Apply', 'Verify', 'Rollback')]
    [string]$Mode = 'Audit',

    [ValidateRange(0, 30000)]
    [int]$StartupDelayMs = 0
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$StateRoot = Join-Path $env:ProgramData 'G11GuestPerformance'
$StatePath = Join-Path $StateRoot 'state.json'
$ReportRoot = Join-Path $StateRoot 'reports'
$ToolRoot = Join-Path $StateRoot 'tools'
$SchemaVersion = 2
$HighPerformanceGuid = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$OfficialNvidiaServiceName = 'NVDisplay.ContainerLocalSystem'

# Disable only automatic idle blank/sleep on the dedicated VM's High
# performance plan.  Explicit user sleep/shutdown remains available.  Exact
# AC/DC values are saved in state.json and restored by 04-Rollback.cmd.
$PowerSettingPlan = @(
    [pscustomobject]@{
        SubgroupGuid = '7516b95f-f776-4464-8c53-06167f40cc99'
        SettingGuid = '3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e'
        Name = 'VIDEOIDLE'
        Purpose = 'Keep the guest display from blanking while the SDL console is idle.'
    },
    [pscustomobject]@{
        SubgroupGuid = '238c9fa8-0aad-41ed-83f4-97be242c8f20'
        SettingGuid = '29f6c1db-86da-48c5-9fdb-f2b67b1f44da'
        Name = 'STANDBYIDLE'
        Purpose = 'Keep the guest from entering automatic idle sleep.'
    }
)

$RegistryPlan = @(
    [pscustomobject]@{
        Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Serialize'
        Name = 'StartupDelayInMSec'
        Type = 'DWord'
        Value = [int]$StartupDelayMs
        Purpose = 'Explorer startup applications are released without the default artificial delay.'
    },
    [pscustomobject]@{
        Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling'
        Name = 'PowerThrottlingOff'
        Type = 'DWord'
        Value = 1
        Purpose = 'Do not throttle foreground work inside this dedicated VM.'
    },
    [pscustomobject]@{
        Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize'
        Name = 'EnableTransparency'
        Type = 'DWord'
        Value = 0
        Purpose = 'Reduce DWM work during the first desktop redraws.'
    },
    [pscustomobject]@{
        Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        Name = 'TaskbarAnimations'
        Type = 'DWord'
        Value = 0
        Purpose = 'Reduce shell animation work after logon.'
    },
    [pscustomobject]@{
        Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR'
        Name = 'AppCaptureEnabled'
        Type = 'DWord'
        Value = 0
        Purpose = 'Disable duplicate guest-side background capture; G-11 captures on the host.'
    },
    [pscustomobject]@{
        Path = 'HKCU:\System\GameConfigStore'
        Name = 'GameDVR_Enabled'
        Type = 'DWord'
        Value = 0
        Purpose = 'Disable duplicate guest-side Game DVR capture.'
    },
    [pscustomobject]@{
        Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR'
        Name = 'AllowGameDVR'
        Type = 'DWord'
        Value = 0
        Purpose = 'Keep guest Game DVR disabled for this host-captured VM.'
    }
)

# These names come from this repository's retired RDP/ivshmem display path.
# Ownership is also checked against the task action before anything is disabled.
$LegacyTaskPlan = @(
    [pscustomobject]@{
        Path = '\'; Name = 'VideoStream'
        ActionPattern = '(?i)(?:^|[" ])(?:C:\\nv\\stream_video\.ps1|C:\\Windows\\System32\\(?:NvStreamSvc|nv_stream_relay|NvSvcStream)\.exe)(?:[" ]|$)'
        Purpose = 'retired ivshmem video relay'
    },
    [pscustomobject]@{
        Path = '\'; Name = 'AudioDeviceGraphHost'
        ActionPattern = '(?i)(?:^|[" ])C:\\Windows\\System32\\AudioSvcHost\.exe(?:[" ]|$)'
        Purpose = 'retired relay input helper'
    },
    [pscustomobject]@{
        Path = '\'; Name = 'HideRdpIdd'
        ActionPattern = '(?i)(?:^|[" ])C:\\nv\\disable-rdp-idd\.ps1(?:[" ]|$)'
        Purpose = 'retired 30-second RDP PnP polling loop'
    },
    [pscustomobject]@{
        Path = '\'; Name = 'PurgeRdpGhosts'
        ActionPattern = '(?i)(?:^|[" ])C:\\nv\\purge-rdp-ghosts\.ps1(?:[" ]|$)'
        Purpose = 'retired boot/logon RDP PnP enumeration'
    },
    [pscustomobject]@{
        Path = '\'; Name = 'StealthMonitor-Refresh'
        ActionPattern = '(?i)(?:^|[" ])C:\\ProgramData\\StealthMonitor\\refresh-monitor\.ps1(?:[" ]|$)'
        Purpose = 'retired online monitor refresh; native G-11 syncs it offline'
    },
    [pscustomobject]@{
        Path = '\'; Name = 'StealthMonitor-Refresh-Logon'
        ActionPattern = '(?i)(?:^|[" ])C:\\ProgramData\\StealthMonitor\\refresh-monitor\.ps1(?:[" ]|$)'
        Purpose = 'retired logon monitor refresh; native G-11 syncs it offline'
    }
)

$LegacyServicePlan = @(
    [pscustomobject]@{
        Name = 'NvDisplayContainer'
        File = 'NvDisplayContainer.exe'
        Purpose = 'retired ivshmem video/input relay watchdog'
    },
    [pscustomobject]@{
        Name = 'AudioDeviceGraphHost'
        File = 'AudioSvcHost.exe'
        Purpose = 'retired pre-watchdog user-session input/capture service'
    }
)

$LegacyProcessPlan = @(
    [pscustomobject]@{
        Name = 'NvDisplayContainer'; Path = '%SystemRoot%\System32\NvDisplayContainer.exe'
    },
    [pscustomobject]@{
        Name = 'NvStreamSvc'; Path = '%SystemRoot%\System32\NvStreamSvc.exe'
    },
    [pscustomobject]@{
        Name = 'nv_stream_relay'; Path = '%SystemRoot%\System32\nv_stream_relay.exe'
    },
    [pscustomobject]@{
        Name = 'AudioSvcHost'; Path = '%SystemRoot%\System32\AudioSvcHost.exe'
    },
    [pscustomobject]@{ Name = 'ffmpeg'; Path = 'C:\nv\ffmpeg.exe' }
)

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Invoke-ElevatedSelf {
    $powerShell = Join-Path $env:SystemRoot `
        'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Mode {1} -StartupDelayMs {2}' -f `
        $PSCommandPath.Replace('"', '""'), $Mode, $StartupDelayMs
    $process = Start-Process -FilePath $powerShell -Verb RunAs `
        -ArgumentList $arguments -Wait -PassThru
    exit $process.ExitCode
}

function Assert-InteractiveAdministrator {
    $current = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $interactive = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName
    if ([string]::IsNullOrWhiteSpace([string]$interactive)) {
        throw 'No interactive Windows user is logged on.'
    }
    if ($current -ine $interactive) {
        throw "Elevated identity '$current' differs from interactive user '$interactive'. Log on with the Administrator account that should receive HKCU tuning, then run again."
    }
}

function Initialize-StateRoot {
    New-Item -Path $StateRoot -ItemType Directory -Force | Out-Null
    New-Item -Path $ReportRoot -ItemType Directory -Force | Out-Null
    $aclArguments = @(
        $StateRoot, '/inheritance:r', '/grant:r',
        '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F'
    )
    & icacls.exe @aclArguments | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Could not secure state directory '$StateRoot'."
    }
}

function Get-ActivePowerScheme {
    $savedPreference = $ErrorActionPreference
    $exitCode = -1
    $output = ''
    try {
        $ErrorActionPreference = 'Continue'
        $output = (& powercfg.exe /getactivescheme 2>&1 | Out-String)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedPreference
    }
    if ($exitCode -ne 0) { return $null }
    $match = [regex]::Match(
        $output,
        '(?i)([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})'
    )
    if (-not $match.Success) { return $null }
    return $match.Groups[1].Value.ToLowerInvariant()
}

function Set-ActivePowerScheme {
    param([Parameter(Mandatory = $true)][string]$Guid)

    $savedPreference = $ErrorActionPreference
    $exitCode = -1
    try {
        $ErrorActionPreference = 'Continue'
        $null = (& powercfg.exe /setactive $Guid 2>&1 | Out-String)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedPreference
    }
    return $exitCode -eq 0
}

function Get-PowerSettingSnapshot {
    param([Parameter(Mandatory = $true)][object]$Entry)

    $path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\{0}\{1}\{2}' -f `
        $HighPerformanceGuid, $Entry.SubgroupGuid, $Entry.SettingGuid
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        return [pscustomobject]@{
            SchemeGuid = $HighPerformanceGuid
            SubgroupGuid = [string]$Entry.SubgroupGuid
            SettingGuid = [string]$Entry.SettingGuid
            Name = [string]$Entry.Name
            Exists = $false
            ACValue = $null
            DCValue = $null
        }
    }
    $values = Get-ItemProperty -LiteralPath $path -ErrorAction Stop
    return [pscustomobject]@{
        SchemeGuid = $HighPerformanceGuid
        SubgroupGuid = [string]$Entry.SubgroupGuid
        SettingGuid = [string]$Entry.SettingGuid
        Name = [string]$Entry.Name
        Exists = $true
        ACValue = [uint32]$values.ACSettingIndex
        DCValue = [uint32]$values.DCSettingIndex
    }
}

function Set-PowerSettingValues {
    param(
        [Parameter(Mandatory = $true)][object]$Snapshot,
        [Parameter(Mandatory = $true)][uint32]$ACValue,
        [Parameter(Mandatory = $true)][uint32]$DCValue
    )

    $allowed = @($PowerSettingPlan | ForEach-Object {
        "$($_.SubgroupGuid)|$($_.SettingGuid)"
    })
    if ($allowed -notcontains "$($Snapshot.SubgroupGuid)|$($Snapshot.SettingGuid)" -or
        [string]$Snapshot.SchemeGuid -ne $HighPerformanceGuid) {
        throw "State contains an unexpected power setting: $($Snapshot.Name)"
    }
    $requests = @(
        [pscustomobject]@{ Mode = '/setacvalueindex'; Value = $ACValue },
        [pscustomobject]@{ Mode = '/setdcvalueindex'; Value = $DCValue }
    )
    foreach ($request in $requests) {
        $arguments = @(
            [string]$request.Mode, $HighPerformanceGuid,
            [string]$Snapshot.SubgroupGuid, [string]$Snapshot.SettingGuid,
            [string]$request.Value
        )
        $savedPreference = $ErrorActionPreference
        $exitCode = -1
        try {
            $ErrorActionPreference = 'Continue'
            $null = (& powercfg.exe @arguments 2>&1 | Out-String)
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $savedPreference
        }
        if ($exitCode -ne 0) {
            throw "powercfg failed for $($Snapshot.Name) ($($request.Mode))."
        }
    }
}

function Disable-AutomaticGuestBlanking {
    param([Parameter(Mandatory = $true)][object[]]$Snapshots)

    foreach ($snapshot in $Snapshots) {
        if (-not [bool]$snapshot.Exists) {
            Write-Warning "Power setting '$($snapshot.Name)' is unavailable; left untouched."
            continue
        }
        Set-PowerSettingValues -Snapshot $snapshot -ACValue 0 -DCValue 0
        Write-Host "  power setting: $($snapshot.Name) AC=0 DC=0 (never idle)" `
            -ForegroundColor Gray
    }
}

function Restore-PowerSettings {
    param([object[]]$Snapshots)

    foreach ($snapshot in @($Snapshots)) {
        if (-not [bool]$snapshot.Exists) { continue }
        Set-PowerSettingValues -Snapshot $snapshot `
            -ACValue ([uint32]$snapshot.ACValue) `
            -DCValue ([uint32]$snapshot.DCValue)
    }
}

function Get-RegistrySnapshot {
    param([Parameter(Mandatory = $true)][object]$Entry)

    $pathExisted = Test-Path -LiteralPath $Entry.Path
    $valueExisted = $false
    $kind = $null
    $value = $null
    if ($pathExisted) {
        $key = Get-Item -LiteralPath $Entry.Path -ErrorAction Stop
        $valueExisted = @($key.GetValueNames()) -contains [string]$Entry.Name
        if ($valueExisted) {
            $kind = $key.GetValueKind([string]$Entry.Name).ToString()
            $value = $key.GetValue(
                [string]$Entry.Name, $null,
                [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
            )
        }
    }
    return [pscustomobject]@{
        Path = [string]$Entry.Path
        Name = [string]$Entry.Name
        PathExisted = [bool]$pathExisted
        ValueExisted = [bool]$valueExisted
        Kind = $kind
        Value = $value
    }
}

function Set-PlannedRegistryValue {
    param([Parameter(Mandatory = $true)][object]$Entry)

    $target = "$($Entry.Path)\$($Entry.Name)"
    try {
        # Do not ask the registry provider to recreate an existing key.  On
        # hardened Windows keys, New-Item -Force can require create-subkey
        # access even though setting a value on the key is permitted.
        if (-not (Test-Path -LiteralPath $Entry.Path -PathType Container)) {
            New-Item -Path $Entry.Path -Force -ErrorAction Stop | Out-Null
        }
        New-ItemProperty -LiteralPath $Entry.Path -Name $Entry.Name `
            -PropertyType $Entry.Type -Value $Entry.Value -Force `
            -ErrorAction Stop | Out-Null
    } catch {
        throw "Could not apply registry target '$target': $($_.Exception.Message)"
    }
    Write-Host "  registry: $($Entry.Path)\$($Entry.Name)=$($Entry.Value)" `
        -ForegroundColor Gray
}

function Restore-RegistrySnapshot {
    param([Parameter(Mandatory = $true)][object]$Snapshot)

    $allowed = @($RegistryPlan | ForEach-Object { "$($_.Path)|$($_.Name)" })
    if ($allowed -notcontains "$($Snapshot.Path)|$($Snapshot.Name)") {
        throw "State contains an unexpected registry target: $($Snapshot.Path)\$($Snapshot.Name)"
    }
    if ([bool]$Snapshot.ValueExisted) {
        $restorePath = [string]$Snapshot.Path
        $restoreTarget = "$restorePath\$($Snapshot.Name)"
        try {
            if (-not (Test-Path -LiteralPath $restorePath `
                        -PathType Container)) {
                New-Item -Path $restorePath -Force -ErrorAction Stop |
                    Out-Null
            }
            New-ItemProperty -LiteralPath $restorePath `
                -Name ([string]$Snapshot.Name) `
                -PropertyType ([string]$Snapshot.Kind) `
                -Value $Snapshot.Value -Force -ErrorAction Stop | Out-Null
        } catch {
            throw "Could not restore registry target '$restoreTarget': $($_.Exception.Message)"
        }
    } else {
        Remove-ItemProperty -LiteralPath ([string]$Snapshot.Path) `
            -Name ([string]$Snapshot.Name) -ErrorAction SilentlyContinue
        if (-not [bool]$Snapshot.PathExisted -and
            (Test-Path -LiteralPath ([string]$Snapshot.Path))) {
            $key = Get-Item -LiteralPath ([string]$Snapshot.Path)
            if (@($key.GetValueNames()).Count -eq 0 -and
                @($key.GetSubKeyNames()).Count -eq 0) {
                Remove-Item -LiteralPath ([string]$Snapshot.Path) -Force
            }
        }
    }
}

function Get-TaskActionText {
    param([Parameter(Mandatory = $true)][object]$Task)
    return (@($Task.Actions | ForEach-Object {
        (([string]$_.Execute) + ' ' + ([string]$_.Arguments)).Trim()
    }) -join ' | ')
}

function Get-LegacyTaskSnapshot {
    param([Parameter(Mandatory = $true)][object]$Plan)

    $task = Get-ScheduledTask -TaskName $Plan.Name -TaskPath $Plan.Path `
        -ErrorAction SilentlyContinue
    if ($null -eq $task) {
        return [pscustomobject]@{
            Path = $Plan.Path; Name = $Plan.Name; Exists = $false
            Owned = $false; Enabled = $false; Action = ''; Purpose = $Plan.Purpose
        }
    }
    $action = Get-TaskActionText $task
    $owned = $action -match $Plan.ActionPattern
    return [pscustomobject]@{
        Path = $Plan.Path
        Name = $Plan.Name
        Exists = $true
        Owned = [bool]$owned
        Enabled = [bool]$task.Settings.Enabled
        Action = $action
        Purpose = $Plan.Purpose
    }
}

function Get-ServiceExecutablePath {
    param([Parameter(Mandatory = $true)][string]$CommandLine)

    $expanded = [Environment]::ExpandEnvironmentVariables($CommandLine).Trim()
    $match = [regex]::Match($expanded, '^"([^"]+)"|^(\S+)')
    if (-not $match.Success) { return $null }
    $candidate = if ($match.Groups[1].Success) {
        $match.Groups[1].Value
    } else {
        $match.Groups[2].Value
    }
    try { return [IO.Path]::GetFullPath($candidate) } catch { return $null }
}

function Get-LegacyServiceSnapshot {
    param([Parameter(Mandatory = $true)][object]$Plan)

    $service = Get-CimInstance Win32_Service `
        -Filter "Name='$($Plan.Name)'" -ErrorAction SilentlyContinue
    if ($null -eq $service) {
        return [pscustomobject]@{
            Exists = $false; Owned = $false; Name = $Plan.Name
            State = ''; StartMode = ''; PathName = ''; ExecutablePath = ''
            DelayedAutoStart = 0; Purpose = $Plan.Purpose
        }
    }
    $path = [string]$service.PathName
    $executable = Get-ServiceExecutablePath $path
    $expected = [IO.Path]::GetFullPath(
        (Join-Path (Join-Path $env:SystemRoot 'System32') $Plan.File)
    )
    $owned = $null -ne $executable -and $executable -ieq $expected
    $delayed = 0
    $serviceKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$($Plan.Name)"
    if (Test-Path -LiteralPath $serviceKey) {
        $delayed = [int](Get-ItemPropertyValue -LiteralPath $serviceKey `
            -Name DelayedAutoStart -ErrorAction SilentlyContinue)
    }
    return [pscustomobject]@{
        Exists = $true
        Owned = [bool]$owned
        Name = $Plan.Name
        State = [string]$service.State
        StartMode = [string]$service.StartMode
        PathName = $path
        ExecutablePath = [string]$executable
        DelayedAutoStart = $delayed
        Purpose = $Plan.Purpose
    }
}

function Stop-LegacyRelayProcesses {
    foreach ($plan in $LegacyProcessPlan) {
        foreach ($process in @(Get-Process -Name $plan.Name -ErrorAction SilentlyContinue)) {
            $path = $null
            try { $path = [IO.Path]::GetFullPath([string]$process.Path) } catch {}
            $expected = [IO.Path]::GetFullPath(
                [Environment]::ExpandEnvironmentVariables([string]$plan.Path)
            )
            if ($null -ne $path -and $path -ieq $expected) {
                Write-Host "  stop legacy process: $($process.ProcessName) pid=$($process.Id)" `
                    -ForegroundColor Gray
                Stop-Process -Id $process.Id -Force -ErrorAction Stop
            } elseif ($null -ne $path) {
                Write-Warning "Process '$($process.ProcessName)' has unexpected path '$path'; left untouched."
            }
        }
    }
}

function Get-OwnedLegacyProcesses {
    $rows = @()
    foreach ($plan in $LegacyProcessPlan) {
        $expected = [IO.Path]::GetFullPath(
            [Environment]::ExpandEnvironmentVariables([string]$plan.Path)
        )
        foreach ($process in @(Get-Process -Name $plan.Name -ErrorAction SilentlyContinue)) {
            $path = $null
            try { $path = [IO.Path]::GetFullPath([string]$process.Path) } catch {}
            if ($null -ne $path -and $path -ieq $expected) {
                $rows += [pscustomobject]@{
                    Name = [string]$process.ProcessName
                    Id = [int]$process.Id
                    Path = $path
                }
            }
        }
    }
    return @($rows)
}

function Disable-LegacyComponents {
    param(
        [Parameter(Mandatory = $true)][object[]]$TaskSnapshots,
        [Parameter(Mandatory = $true)][object[]]$ServiceSnapshots
    )

    foreach ($task in $TaskSnapshots) {
        if ([bool]$task.Exists -and -not [bool]$task.Owned) {
            Write-Warning "Task '$($task.Path)$($task.Name)' has an unexpected action and was left untouched: $($task.Action)"
            continue
        }
        if ([bool]$task.Exists -and [bool]$task.Owned -and [bool]$task.Enabled) {
            Stop-ScheduledTask -TaskName $task.Name -TaskPath $task.Path `
                -ErrorAction SilentlyContinue
            Disable-ScheduledTask -TaskName $task.Name -TaskPath $task.Path `
                -ErrorAction Stop | Out-Null
            Write-Host "  disabled legacy task: $($task.Path)$($task.Name) ($($task.Purpose))" `
                -ForegroundColor Gray
        }
    }

    foreach ($service in $ServiceSnapshots) {
        if ([bool]$service.Exists -and -not [bool]$service.Owned) {
            Write-Warning "Service '$($service.Name)' has an unexpected binary and was left untouched: $($service.PathName)"
        } elseif ([bool]$service.Exists -and [bool]$service.Owned) {
            Stop-Service -Name $service.Name -Force -ErrorAction SilentlyContinue
            Set-Service -Name $service.Name -StartupType Disabled -ErrorAction Stop
            Write-Host "  disabled custom legacy service: $($service.Name) ($($service.Purpose))" `
                -ForegroundColor Gray
        }
    }
    Stop-LegacyRelayProcesses
}

function Restore-LegacyService {
    param([Parameter(Mandatory = $true)][object]$Snapshot)

    if (-not [bool]$Snapshot.Exists -or -not [bool]$Snapshot.Owned) { return }
    $plan = $LegacyServicePlan | Where-Object {
        $_.Name -eq [string]$Snapshot.Name
    } | Select-Object -First 1
    if ($null -eq $plan) {
        throw "Unexpected service in state: $($Snapshot.Name)"
    }
    $current = Get-LegacyServiceSnapshot $plan
    if (-not [bool]$current.Exists -or -not [bool]$current.Owned) {
        Write-Warning "Legacy relay service is missing or changed; rollback did not recreate/enable it."
        return
    }
    switch ([string]$Snapshot.StartMode) {
        'Auto' {
            if ([int]$Snapshot.DelayedAutoStart -eq 1) {
                & sc.exe config $Snapshot.Name 'start=' 'delayed-auto' | Out-Null
                if ($LASTEXITCODE -ne 0) { throw 'Could not restore delayed-auto relay service mode.' }
            } else {
                Set-Service -Name $Snapshot.Name -StartupType Automatic
            }
        }
        'Manual' { Set-Service -Name $Snapshot.Name -StartupType Manual }
        'Disabled' { Set-Service -Name $Snapshot.Name -StartupType Disabled }
        default { throw "Unsupported saved relay service StartMode '$($Snapshot.StartMode)'." }
    }
    if ([string]$Snapshot.State -eq 'Running' -and
        [string]$Snapshot.StartMode -ne 'Disabled') {
        Start-Service -Name $Snapshot.Name -ErrorAction Stop
    }
}

function Save-StateAtomically {
    param([Parameter(Mandatory = $true)][object]$State)

    $temporary = Join-Path $StateRoot ('.state.{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
    try {
        $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temporary `
            -Encoding UTF8 -NoNewline
        Move-Item -LiteralPath $temporary -Destination $StatePath -Force
    } finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
}

function Read-State {
    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
        throw "No applied-state file exists: $StatePath"
    }
    $state = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([int]$state.SchemaVersion -ne $SchemaVersion) {
        throw "Unsupported state schema '$($state.SchemaVersion)'."
    }
    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if ([string]$state.UserSid -ne $currentSid) {
        throw "State belongs to user SID '$($state.UserSid)', current SID is '$currentSid'."
    }
    return $state
}

function Install-LocalTools {
    New-Item -Path $ToolRoot -ItemType Directory -Force | Out-Null
    foreach ($name in @(
        'Optimize-Guest.ps1', '01-Audit.cmd', '02-Apply-Recommended.cmd',
        '03-Verify.cmd', '04-Rollback.cmd', 'README.txt'
    )) {
        $source = Join-Path $PSScriptRoot $name
        $destination = Join-Path $ToolRoot $name
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            if ([IO.Path]::GetFullPath($source) -ine
                [IO.Path]::GetFullPath($destination)) {
                Copy-Item -LiteralPath $source -Destination $destination -Force
            }
        }
    }
}

function Get-EventData {
    param([Parameter(Mandatory = $true)][object]$Event)
    $result = [ordered]@{}
    try {
        [xml]$xml = $Event.ToXml()
        foreach ($data in @($xml.Event.EventData.Data)) {
            $name = [string]$data.Name
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            $result[$name] = [string]$data.'#text'
        }
    } catch {}
    return $result
}

function Get-ProcessCpuSample {
    param([int]$Seconds = 3)
    $before = @{}
    foreach ($process in @(Get-Process -ErrorAction SilentlyContinue)) {
        try {
            $before[[int]$process.Id] = [pscustomobject]@{
                Name = [string]$process.ProcessName
                CpuMs = [double]$process.TotalProcessorTime.TotalMilliseconds
            }
        } catch {}
    }
    Start-Sleep -Seconds $Seconds
    $rows = @()
    foreach ($process in @(Get-Process -ErrorAction SilentlyContinue)) {
        $old = $before[[int]$process.Id]
        if ($null -eq $old -or $old.Name -ne [string]$process.ProcessName) { continue }
        try {
            $delta = [double]$process.TotalProcessorTime.TotalMilliseconds - $old.CpuMs
            if ($delta -lt 0) { continue }
            $rows += [pscustomobject]@{
                Name = [string]$process.ProcessName
                Id = [int]$process.Id
                CorePercent = [math]::Round(($delta / ($Seconds * 1000.0)) * 100.0, 1)
                WorkingSetMB = [math]::Round($process.WorkingSet64 / 1MB, 1)
            }
        } catch {}
    }
    return @($rows | Sort-Object CorePercent -Descending | Select-Object -First 15)
}

function New-AuditReport {
    param([Parameter(Mandatory = $true)][string]$Label)

    Initialize-StateRoot
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $now = Get-Date
    $os = Get-CimInstance Win32_OperatingSystem
    $computer = Get-CimInstance Win32_ComputerSystem
    $uptime = $now - $os.LastBootUpTime
    $lines.Add('G-11 guest startup/runtime audit')
    $lines.Add("generated=$($now.ToString('o')) label=$Label")
    $lines.Add("computer=$($computer.Name) user=$([Security.Principal.WindowsIdentity]::GetCurrent().Name)")
    $lines.Add("os=$($os.Caption) build=$($os.BuildNumber) ramMB=$([math]::Round($computer.TotalPhysicalMemory / 1MB)) logicalCPUs=$($computer.NumberOfLogicalProcessors)")
    $lines.Add("lastBoot=$($os.LastBootUpTime.ToString('o')) uptime=$([math]::Round($uptime.TotalSeconds, 1))s")
    $lines.Add("activePowerScheme=$(Get-ActivePowerScheme)")
    $lines.Add('')

    $lines.Add('[native-display legacy components]')
    foreach ($plan in $LegacyServicePlan) {
        $service = Get-LegacyServiceSnapshot $plan
        $lines.Add("service=$($service.Name) exists=$($service.Exists) owned=$($service.Owned) state=$($service.State) start=$($service.StartMode) purpose=$($service.Purpose) path=$($service.PathName)")
    }
    $official = Get-Service -Name $OfficialNvidiaServiceName -ErrorAction SilentlyContinue
    if ($null -eq $official) {
        $lines.Add("officialService=$OfficialNvidiaServiceName missing")
    } else {
        $lines.Add("officialService=$OfficialNvidiaServiceName state=$($official.Status) (never modified by this tool)")
    }
    foreach ($plan in $LegacyTaskPlan) {
        $task = Get-LegacyTaskSnapshot $plan
        $lines.Add("task=$($task.Path)$($task.Name) exists=$($task.Exists) owned=$($task.Owned) enabled=$($task.Enabled) purpose=$($task.Purpose) action=$($task.Action)")
    }
    foreach ($plan in $LegacyProcessPlan) {
        foreach ($process in @(Get-Process -Name $plan.Name -ErrorAction SilentlyContinue)) {
            $path = ''
            try { $path = [string]$process.Path } catch {}
            $lines.Add("process=$($process.ProcessName) pid=$($process.Id) path=$path")
        }
    }
    $lines.Add('')

    $lines.Add('[planned registry values]')
    foreach ($entry in $RegistryPlan) {
        $snapshot = Get-RegistrySnapshot $entry
        $shown = if ($snapshot.ValueExisted) { [string]$snapshot.Value } else { '<missing>' }
        $lines.Add("$($entry.Path)\$($entry.Name) current=$shown desired=$($entry.Value) purpose=$($entry.Purpose)")
    }
    $hiberboot = Get-ItemPropertyValue `
        -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' `
        -Name HiberbootEnabled -ErrorAction SilentlyContinue
    $lines.Add("HiberbootEnabled=$hiberboot (audit only; supported G-11 value is 0)")
    $lines.Add('')

    $lines.Add('[guest idle display/sleep policy]')
    foreach ($entry in $PowerSettingPlan) {
        $snapshot = Get-PowerSettingSnapshot $entry
        $lines.Add("setting=$($snapshot.Name) exists=$($snapshot.Exists) AC=$($snapshot.ACValue) DC=$($snapshot.DCValue) desired=0 purpose=$($entry.Purpose)")
    }
    $lines.Add('')

    $lines.Add('[recent Windows boot degradation events]')
    try {
        $ids = 100, 101, 102, 103, 106, 107, 108, 109, 110
        $events = @(Get-WinEvent -FilterHashtable @{
            LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'
            Id = $ids
            StartTime = (Get-Date).AddDays(-7)
        } -MaxEvents 40 -ErrorAction Stop)
        foreach ($event in $events) {
            $data = Get-EventData $event
            $detailNames = @(
                'BootTime', 'MainPathBootTime', 'BootPostBootTime',
                'Name', 'FriendlyName', 'Path', 'TotalTime', 'DegradationTime'
            )
            $details = @()
            foreach ($name in $detailNames) {
                if ($data.Contains($name) -and -not [string]::IsNullOrWhiteSpace($data[$name])) {
                    $details += "$name=$($data[$name])"
                }
            }
            $lines.Add("event=$($event.Id) time=$($event.TimeCreated.ToString('o')) $($details -join ' ')")
        }
        if ($events.Count -eq 0) { $lines.Add('no events in the last 7 days') }
    } catch {
        $lines.Add("unavailable: $($_.Exception.Message)")
    }
    $lines.Add('')

    $lines.Add('[startup commands]')
    try {
        foreach ($item in @(Get-CimInstance Win32_StartupCommand | Sort-Object Location, Name)) {
            $lines.Add("name=$($item.Name) location=$($item.Location) user=$($item.User) command=$($item.Command)")
        }
    } catch {
        $lines.Add("unavailable: $($_.Exception.Message)")
    }
    $lines.Add('')

    $lines.Add('[top process CPU over 3 seconds; 100%=one vCPU]')
    foreach ($row in @(Get-ProcessCpuSample -Seconds 3)) {
        $lines.Add("cpu=$($row.CorePercent)% ws=$($row.WorkingSetMB)MB pid=$($row.Id) name=$($row.Name)")
    }

    $safeLabel = $Label -replace '[^A-Za-z0-9_.-]', '_'
    $path = Join-Path $ReportRoot ('{0}-{1}.txt' -f `
        (Get-Date -Format 'yyyyMMdd-HHmmss'), $safeLabel)
    $lines | Set-Content -LiteralPath $path -Encoding UTF8
    Write-Host "Audit report: $path" -ForegroundColor Cyan
    return $path
}

function New-OriginalState {
    $taskSnapshots = @($LegacyTaskPlan | ForEach-Object {
        Get-LegacyTaskSnapshot $_
    })
    $state = [ordered]@{
        SchemaVersion = $SchemaVersion
        CreatedUtc = [DateTime]::UtcNow.ToString('o')
        UserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        UserName = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        StartupDelayMs = $StartupDelayMs
        ActivePowerScheme = Get-ActivePowerScheme
        PowerSettings = @($PowerSettingPlan | ForEach-Object {
            Get-PowerSettingSnapshot $_
        })
        Registry = @($RegistryPlan | ForEach-Object { Get-RegistrySnapshot $_ })
        LegacyServices = @($LegacyServicePlan | ForEach-Object {
            Get-LegacyServiceSnapshot $_
        })
        LegacyTasks = $taskSnapshots
    }
    Save-StateAtomically $state
    return (Read-State)
}

function Ensure-PowerSettingState {
    param([Parameter(Mandatory = $true)][object]$State)

    if ($null -ne $State.PSObject.Properties['PowerSettings']) {
        return $State
    }
    # State schema 2 predates the idle-display policy.  Extend the original
    # backup before the first write so existing installations remain safely
    # upgradeable and rollback never guesses a previous value.
    $snapshots = @($PowerSettingPlan | ForEach-Object {
        Get-PowerSettingSnapshot $_
    })
    $State | Add-Member -NotePropertyName PowerSettings `
        -NotePropertyValue $snapshots
    Save-StateAtomically $State
    return (Read-State)
}

function Set-HighPerformanceIfAvailable {
    if (-not (Set-ActivePowerScheme $HighPerformanceGuid)) {
        Write-Warning 'The built-in High performance power plan is unavailable; the current plan was left active.'
    } else {
        Write-Host "  power plan: High performance ($HighPerformanceGuid)" `
            -ForegroundColor Gray
    }
}

function Invoke-RollbackInternal {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [switch]$ArchiveState
    )

    Write-Host '[rollback] restoring registry values' -ForegroundColor Cyan
    foreach ($snapshot in @($State.Registry)) {
        Restore-RegistrySnapshot $snapshot
    }
    if ($null -ne $State.PSObject.Properties['PowerSettings']) {
        Write-Host '[rollback] restoring guest idle display/sleep policy' `
            -ForegroundColor Cyan
        Restore-PowerSettings @($State.PowerSettings)
    }
    if ([string]$State.ActivePowerScheme -match `
        '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') {
        if (-not (Set-ActivePowerScheme ([string]$State.ActivePowerScheme))) {
            Write-Warning "Could not restore power scheme '$($State.ActivePowerScheme)'."
        }
    }

    Write-Host '[rollback] restoring task enabled states' -ForegroundColor Cyan
    foreach ($saved in @($State.LegacyTasks)) {
        if (-not [bool]$saved.Exists -or -not [bool]$saved.Owned -or
            -not [bool]$saved.Enabled) { continue }
        $plan = $LegacyTaskPlan | Where-Object {
            $_.Path -eq [string]$saved.Path -and $_.Name -eq [string]$saved.Name
        } | Select-Object -First 1
        if ($null -eq $plan) { throw "Unexpected task in state: $($saved.Path)$($saved.Name)" }
        $current = Get-LegacyTaskSnapshot $plan
        if ([bool]$current.Exists -and [bool]$current.Owned) {
            Enable-ScheduledTask -TaskName $current.Name -TaskPath $current.Path `
                -ErrorAction Stop | Out-Null
        } else {
            Write-Warning "Task '$($saved.Path)$($saved.Name)' is missing or changed; it was not re-enabled."
        }
    }

    Write-Host '[rollback] restoring custom relay service states' -ForegroundColor Cyan
    foreach ($service in @($State.LegacyServices)) {
        Restore-LegacyService $service
    }
    if ($ArchiveState) {
        $archive = Join-Path $StateRoot ('state.rolled-back.{0}.json' -f `
            (Get-Date -Format 'yyyyMMdd-HHmmss'))
        Move-Item -LiteralPath $StatePath -Destination $archive -Force
        Write-Host "Rollback state archived: $archive" -ForegroundColor Green
    }
}

function Invoke-Apply {
    Assert-InteractiveAdministrator
    Initialize-StateRoot
    $before = New-AuditReport 'before-apply'
    $state = if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
        Write-Host "Using existing original-state backup: $StatePath" -ForegroundColor Yellow
        Read-State
    } else {
        New-OriginalState
    }
    $state = Ensure-PowerSettingState $state

    try {
        Write-Host '[apply] registry and power policy' -ForegroundColor Cyan
        foreach ($entry in $RegistryPlan) { Set-PlannedRegistryValue $entry }
        Disable-AutomaticGuestBlanking @($state.PowerSettings)
        Set-HighPerformanceIfAvailable

        Write-Host '[apply] native display: disable only owned legacy relay/RDP helpers' `
            -ForegroundColor Cyan
        Disable-LegacyComponents @($state.LegacyTasks) @($state.LegacyServices)
        Install-LocalTools
        $after = New-AuditReport 'after-apply'
    } catch {
        $failure = $_
        Write-Warning "Apply failed; restoring the saved original state: $($failure.Exception.Message)"
        try {
            Invoke-RollbackInternal -State $state
        } catch {
            throw ("Apply failed: {0}; rollback also failed: {1}" -f `
                $failure.Exception.Message, $_.Exception.Message)
        }
        throw $failure
    }

    Write-Host ''
    Write-Host 'APPLY PASS: recommended native-display tuning is installed.' `
        -ForegroundColor Green
    Write-Host "Before report: $before" -ForegroundColor Gray
    Write-Host "After report:  $after" -ForegroundColor Gray
    Write-Host "Verify/rollback tools: $ToolRoot" -ForegroundColor Gray
    Write-Host 'Do one normal Windows Shut down (not sleep/hibernate), then cold-start the VM.' `
        -ForegroundColor Yellow
}

function Invoke-Verify {
    Assert-InteractiveAdministrator
    Initialize-StateRoot
    $issues = New-Object 'System.Collections.Generic.List[string]'
    foreach ($entry in $RegistryPlan) {
        $snapshot = Get-RegistrySnapshot $entry
        if (-not $snapshot.ValueExisted -or
            [int64]$snapshot.Value -ne [int64]$entry.Value) {
            $issues.Add("registry mismatch: $($entry.Path)\$($entry.Name)")
        }
    }
    foreach ($plan in $LegacyServicePlan) {
        $service = Get-LegacyServiceSnapshot $plan
        if ([bool]$service.Exists -and [bool]$service.Owned -and
            ($service.StartMode -ne 'Disabled' -or $service.State -eq 'Running')) {
            $issues.Add("custom legacy service '$($service.Name)' is $($service.State)/$($service.StartMode)")
        }
    }
    foreach ($plan in $LegacyTaskPlan) {
        $task = Get-LegacyTaskSnapshot $plan
        if ([bool]$task.Exists -and [bool]$task.Owned -and [bool]$task.Enabled) {
            $issues.Add("legacy task is enabled: $($task.Path)$($task.Name)")
        }
    }
    foreach ($process in @(Get-OwnedLegacyProcesses)) {
        $issues.Add("legacy process is running: $($process.Name) pid=$($process.Id)")
    }
    $activePower = Get-ActivePowerScheme
    if ($activePower -ne $HighPerformanceGuid) {
        $issues.Add("active power plan is '$activePower', not High performance")
    }
    foreach ($entry in $PowerSettingPlan) {
        $setting = Get-PowerSettingSnapshot $entry
        if (-not [bool]$setting.Exists -or
            [uint32]$setting.ACValue -ne 0 -or
            [uint32]$setting.DCValue -ne 0) {
            $issues.Add("automatic guest idle timeout is not disabled: $($entry.Name)")
        }
    }
    $hiberboot = Get-ItemPropertyValue `
        -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' `
        -Name HiberbootEnabled -ErrorAction SilentlyContinue
    if ($null -ne $hiberboot -and [int]$hiberboot -ne 0) {
        $issues.Add('Fast Startup is enabled; supported G-11 native operation requires HiberbootEnabled=0')
    }
    $report = New-AuditReport 'verify'
    if ($issues.Count -gt 0) {
        Write-Host 'VERIFY NEEDS ATTENTION:' -ForegroundColor Yellow
        foreach ($issue in $issues) { Write-Host "  - $issue" -ForegroundColor Yellow }
        Write-Host "Report: $report" -ForegroundColor Gray
        exit 10
    }
    Write-Host 'VERIFY PASS: tuning is active and no owned legacy display helper is running.' `
        -ForegroundColor Green
    Write-Host "Report: $report" -ForegroundColor Gray
}

if (-not (Test-Administrator)) { Invoke-ElevatedSelf }

switch ($Mode) {
    'Audit' {
        Assert-InteractiveAdministrator
        $null = New-AuditReport 'audit'
    }
    'Apply' { Invoke-Apply }
    'Verify' { Invoke-Verify }
    'Rollback' {
        Assert-InteractiveAdministrator
        Initialize-StateRoot
        $state = Read-State
        Invoke-RollbackInternal -State $state -ArchiveState
        $null = New-AuditReport 'after-rollback'
        Write-Host 'ROLLBACK PASS: original saved settings were restored.' `
            -ForegroundColor Green
    }
}
