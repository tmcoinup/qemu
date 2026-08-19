#requires -Version 5.1
<#
.SYNOPSIS
  Audit, apply, or roll back the G-11 Windows 10 guest lite profile.

.DESCRIPTION
  The full profile disables Microsoft Defender Antivirus, Windows Update, and
  Microsoft Store access; unregisters a reviewed list of consumer Appx apps
  for the interactive user; and disables a reviewed list of optional services
  and scheduled tasks.

  The tool does not bypass Tamper Protection, remove provisioned Appx payloads,
  modify BCD or driver-signing policy, change kernel drivers, disable Windows
  Firewall, or delete Windows component-store files. Original registry,
  service, and task state is saved under C:\ProgramData\G11GuestLite.
#>
[CmdletBinding()]
param(
    [ValidateSet('Audit', 'Apply', 'Rollback')]
    [string]$Mode = 'Audit'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$StateRoot = Join-Path $env:ProgramData 'G11GuestLite'
$StatePath = Join-Path $StateRoot 'state.json'
$ReportRoot = Join-Path $StateRoot 'reports'
$ToolRoot = Join-Path $StateRoot 'tools'
$SchemaVersion = 1

# Policy values only. The tool never changes Defender service ACLs or deletes
# Defender files. Windows 10 1903+ requires Tamper Protection to be turned off
# manually before these policies can take effect.
$RegistryPlan = @(
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'; Name = 'DisableAntiSpyware'; Type = 'DWord'; Value = 1; Group = 'Defender' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'; Name = 'DisableAntiVirus'; Type = 'DWord'; Value = 1; Group = 'Defender' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'; Name = 'ServiceKeepAlive'; Type = 'DWord'; Value = 0; Group = 'Defender' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection'; Name = 'DisableRealtimeMonitoring'; Type = 'DWord'; Value = 1; Group = 'Defender' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection'; Name = 'DisableBehaviorMonitoring'; Type = 'DWord'; Value = 1; Group = 'Defender' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection'; Name = 'DisableOnAccessProtection'; Type = 'DWord'; Value = 1; Group = 'Defender' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection'; Name = 'DisableScanOnRealtimeEnable'; Type = 'DWord'; Value = 1; Group = 'Defender' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection'; Name = 'DisableIOAVProtection'; Type = 'DWord'; Value = 1; Group = 'Defender' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection'; Name = 'DisableScriptScanning'; Type = 'DWord'; Value = 1; Group = 'Defender' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Scan'; Name = 'DisableArchiveScanning'; Type = 'DWord'; Value = 1; Group = 'Defender' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Scan'; Name = 'DisableRemovableDriveScanning'; Type = 'DWord'; Value = 1; Group = 'Defender' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Scan'; Name = 'DisableScanningMappedNetworkDrivesForFullScan'; Type = 'DWord'; Value = 1; Group = 'Defender' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Scan'; Name = 'DisableCatchupFullScan'; Type = 'DWord'; Value = 1; Group = 'Defender' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Scan'; Name = 'DisableCatchupQuickScan'; Type = 'DWord'; Value = 1; Group = 'Defender' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet'; Name = 'SpynetReporting'; Type = 'DWord'; Value = 0; Group = 'Defender' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet'; Name = 'SubmitSamplesConsent'; Type = 'DWord'; Value = 2; Group = 'Defender' },

    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; Name = 'DisableWindowsUpdateAccess'; Type = 'DWord'; Value = 1; Group = 'WindowsUpdate' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; Name = 'DoNotConnectToWindowsUpdateInternetLocations'; Type = 'DWord'; Value = 1; Group = 'WindowsUpdate' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; Name = 'SetDisableUXWUAccess'; Type = 'DWord'; Value = 1; Group = 'WindowsUpdate' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'; Name = 'NoAutoUpdate'; Type = 'DWord'; Value = 1; Group = 'WindowsUpdate' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'; Name = 'AUOptions'; Type = 'DWord'; Value = 2; Group = 'WindowsUpdate' },

    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore'; Name = 'RemoveWindowsStore'; Type = 'DWord'; Value = 1; Group = 'Store' },
    [pscustomobject]@{ Path = 'HKCU:\SOFTWARE\Policies\Microsoft\WindowsStore'; Name = 'RemoveWindowsStore'; Type = 'DWord'; Value = 1; Group = 'Store' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore'; Name = 'AutoDownload'; Type = 'DWord'; Value = 2; Group = 'Store' },

    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Name = 'AllowTelemetry'; Type = 'DWord'; Value = 0; Group = 'Privacy' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableWindowsConsumerFeatures'; Type = 'DWord'; Value = 1; Group = 'Privacy' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableTailoredExperiencesWithDiagnosticData'; Type = 'DWord'; Value = 1; Group = 'Privacy' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name = 'AllowCortana'; Type = 'DWord'; Value = 0; Group = 'Privacy' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name = 'DisableWebSearch'; Type = 'DWord'; Value = 1; Group = 'Privacy' },
    [pscustomobject]@{ Path = 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\Explorer'; Name = 'DisableSearchBoxSuggestions'; Type = 'DWord'; Value = 1; Group = 'Privacy' },
    [pscustomobject]@{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; Name = 'Enabled'; Type = 'DWord'; Value = 0; Group = 'Privacy' },
    [pscustomobject]@{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'ContentDeliveryAllowed'; Type = 'DWord'; Value = 0; Group = 'Privacy' },
    [pscustomobject]@{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'OemPreInstalledAppsEnabled'; Type = 'DWord'; Value = 0; Group = 'Privacy' },
    [pscustomobject]@{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'PreInstalledAppsEnabled'; Type = 'DWord'; Value = 0; Group = 'Privacy' },
    [pscustomobject]@{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'PreInstalledAppsEverEnabled'; Type = 'DWord'; Value = 0; Group = 'Privacy' },
    [pscustomobject]@{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SilentInstalledAppsEnabled'; Type = 'DWord'; Value = 0; Group = 'Privacy' },
    [pscustomobject]@{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SoftLandingEnabled'; Type = 'DWord'; Value = 0; Group = 'Privacy' },
    [pscustomobject]@{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SystemPaneSuggestionsEnabled'; Type = 'DWord'; Value = 0; Group = 'Privacy' },
    [pscustomobject]@{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-338388Enabled'; Type = 'DWord'; Value = 0; Group = 'Privacy' },
    [pscustomobject]@{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-338389Enabled'; Type = 'DWord'; Value = 0; Group = 'Privacy' },
    [pscustomobject]@{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-353694Enabled'; Type = 'DWord'; Value = 0; Group = 'Privacy' },
    [pscustomobject]@{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-353696Enabled'; Type = 'DWord'; Value = 0; Group = 'Privacy' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting'; Name = 'Disabled'; Type = 'DWord'; Value = 1; Group = 'Privacy' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR'; Name = 'AllowGameDVR'; Type = 'DWord'; Value = 0; Group = 'Gaming' },
    [pscustomobject]@{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR'; Name = 'AppCaptureEnabled'; Type = 'DWord'; Value = 0; Group = 'Gaming' },
    [pscustomobject]@{ Path = 'HKCU:\System\GameConfigStore'; Name = 'GameDVR_Enabled'; Type = 'DWord'; Value = 0; Group = 'Gaming' }
)

# Apply the same Defender intent through its supported live configuration
# surface so an already-running MsMpEng instance stops scanning immediately.
# Required entries exist on every supported Windows 10 Defender module;
# optional entries are feature/version dependent and are skipped if absent.
$DefenderPreferencePlan = @(
    [pscustomobject]@{ Name = 'DisableRealtimeMonitoring'; Value = $true; Required = $true },
    [pscustomobject]@{ Name = 'DisableBehaviorMonitoring'; Value = $true; Required = $true },
    [pscustomobject]@{ Name = 'DisableIOAVProtection'; Value = $true; Required = $true },
    [pscustomobject]@{ Name = 'DisableScriptScanning'; Value = $true; Required = $true },
    [pscustomobject]@{ Name = 'DisableArchiveScanning'; Value = $true; Required = $false },
    [pscustomobject]@{ Name = 'DisableRemovableDriveScanning'; Value = $true; Required = $false },
    [pscustomobject]@{ Name = 'DisableScanningMappedNetworkDrivesForFullScan'; Value = $true; Required = $false },
    [pscustomobject]@{ Name = 'DisableCatchupFullScan'; Value = $true; Required = $false },
    [pscustomobject]@{ Name = 'DisableCatchupQuickScan'; Value = $true; Required = $false },
    [pscustomobject]@{ Name = 'MAPSReporting'; Value = 0; Required = $false },
    [pscustomobject]@{ Name = 'SubmitSamplesConsent'; Value = 2; Required = $false },
    [pscustomobject]@{ Name = 'ScanAvgCPULoadFactor'; Value = 5; Required = $false },
    [pscustomobject]@{ Name = 'ThrottleForScheduledScanOnly'; Value = $false; Required = $false }
)

# Exact service names only. Core networking, audio, printing, search, BITS,
# cryptography, firewall, AppX infrastructure, and NVIDIA services are absent
# intentionally. Missing services are harmless and are reported as such.
$ServicePlan = @(
    [pscustomobject]@{ Name = 'wuauserv'; Group = 'WindowsUpdate'; Purpose = 'Windows Update' },
    [pscustomobject]@{ Name = 'UsoSvc'; Group = 'WindowsUpdate'; Purpose = 'Update Orchestrator' },
    [pscustomobject]@{ Name = 'DoSvc'; Group = 'WindowsUpdate'; Purpose = 'Delivery Optimization' },
    [pscustomobject]@{ Name = 'InstallService'; Group = 'Store'; Purpose = 'Microsoft Store Install Service' },
    [pscustomobject]@{ Name = 'PushToInstall'; Group = 'Store'; Purpose = 'Windows PushToInstall' },
    [pscustomobject]@{ Name = 'DiagTrack'; Group = 'Optional'; Purpose = 'Connected User Experiences and Telemetry' },
    [pscustomobject]@{ Name = 'dmwappushservice'; Group = 'Optional'; Purpose = 'WAP push telemetry routing' },
    [pscustomobject]@{ Name = 'MapsBroker'; Group = 'Optional'; Purpose = 'Downloaded Maps Manager' },
    [pscustomobject]@{ Name = 'RetailDemo'; Group = 'Optional'; Purpose = 'Retail Demo' },
    [pscustomobject]@{ Name = 'Fax'; Group = 'Optional'; Purpose = 'Fax' },
    [pscustomobject]@{ Name = 'lfsvc'; Group = 'Optional'; Purpose = 'Geolocation' },
    [pscustomobject]@{ Name = 'PhoneSvc'; Group = 'Optional'; Purpose = 'Phone integration' },
    [pscustomobject]@{ Name = 'wisvc'; Group = 'Optional'; Purpose = 'Windows Insider' },
    [pscustomobject]@{ Name = 'WalletService'; Group = 'Optional'; Purpose = 'Wallet' },
    [pscustomobject]@{ Name = 'WMPNetworkSvc'; Group = 'Optional'; Purpose = 'Windows Media Player sharing' },
    [pscustomobject]@{ Name = 'XblAuthManager'; Group = 'Optional'; Purpose = 'Xbox Live authentication' },
    [pscustomobject]@{ Name = 'XblGameSave'; Group = 'Optional'; Purpose = 'Xbox Live game save' },
    [pscustomobject]@{ Name = 'XboxNetApiSvc'; Group = 'Optional'; Purpose = 'Xbox Live networking' },
    [pscustomobject]@{ Name = 'WerSvc'; Group = 'Optional'; Purpose = 'Windows Error Reporting' },
    [pscustomobject]@{ Name = 'RemoteRegistry'; Group = 'Optional'; Purpose = 'Remote Registry' }
)

$TaskPlan = @(
    [pscustomobject]@{ Path = '\Microsoft\Windows\Windows Defender\'; Name = 'Windows Defender Cache Maintenance'; Group = 'Defender' },
    [pscustomobject]@{ Path = '\Microsoft\Windows\Windows Defender\'; Name = 'Windows Defender Cleanup'; Group = 'Defender' },
    [pscustomobject]@{ Path = '\Microsoft\Windows\Windows Defender\'; Name = 'Windows Defender Scheduled Scan'; Group = 'Defender' },
    [pscustomobject]@{ Path = '\Microsoft\Windows\Windows Defender\'; Name = 'Windows Defender Verification'; Group = 'Defender' },
    [pscustomobject]@{ Path = '\Microsoft\Windows\UpdateOrchestrator\'; Name = 'Schedule Scan'; Group = 'WindowsUpdate' },
    [pscustomobject]@{ Path = '\Microsoft\Windows\UpdateOrchestrator\'; Name = 'Schedule Scan Static Task'; Group = 'WindowsUpdate' },
    [pscustomobject]@{ Path = '\Microsoft\Windows\UpdateOrchestrator\'; Name = 'USO_UxBroker'; Group = 'WindowsUpdate' },
    [pscustomobject]@{ Path = '\Microsoft\Windows\UpdateOrchestrator\'; Name = 'UpdateModelTask'; Group = 'WindowsUpdate' },
    [pscustomobject]@{ Path = '\Microsoft\Windows\UpdateOrchestrator\'; Name = 'Maintenance Install'; Group = 'WindowsUpdate' },
    [pscustomobject]@{ Path = '\Microsoft\Windows\WindowsUpdate\'; Name = 'Scheduled Start'; Group = 'WindowsUpdate' },
    [pscustomobject]@{ Path = '\Microsoft\Windows\WindowsUpdate\'; Name = 'sih'; Group = 'WindowsUpdate' },
    [pscustomobject]@{ Path = '\Microsoft\Windows\WindowsUpdate\'; Name = 'sihboot'; Group = 'WindowsUpdate' },
    [pscustomobject]@{ Path = '\Microsoft\Windows\Application Experience\'; Name = 'Microsoft Compatibility Appraiser'; Group = 'Optional' },
    [pscustomobject]@{ Path = '\Microsoft\Windows\Application Experience\'; Name = 'ProgramDataUpdater'; Group = 'Optional' },
    [pscustomobject]@{ Path = '\Microsoft\Windows\Application Experience\'; Name = 'StartupAppTask'; Group = 'Optional' },
    [pscustomobject]@{ Path = '\Microsoft\Windows\Customer Experience Improvement Program\'; Name = 'Consolidator'; Group = 'Optional' },
    [pscustomobject]@{ Path = '\Microsoft\Windows\Customer Experience Improvement Program\'; Name = 'KernelCeipTask'; Group = 'Optional' },
    [pscustomobject]@{ Path = '\Microsoft\Windows\Customer Experience Improvement Program\'; Name = 'UsbCeip'; Group = 'Optional' },
    [pscustomobject]@{ Path = '\Microsoft\Windows\DiskDiagnostic\'; Name = 'Microsoft-Windows-DiskDiagnosticDataCollector'; Group = 'Optional' },
    [pscustomobject]@{ Path = '\Microsoft\Windows\Feedback\Siuf\'; Name = 'DmClient'; Group = 'Optional' },
    [pscustomobject]@{ Path = '\Microsoft\Windows\Feedback\Siuf\'; Name = 'DmClientOnScenarioDownload'; Group = 'Optional' },
    [pscustomobject]@{ Path = '\Microsoft\Windows\Maps\'; Name = 'MapsToastTask'; Group = 'Optional' },
    [pscustomobject]@{ Path = '\Microsoft\Windows\Maps\'; Name = 'MapsUpdateTask'; Group = 'Optional' },
    [pscustomobject]@{ Path = '\Microsoft\Windows\PushToInstall\'; Name = 'LoginCheck'; Group = 'Store' },
    [pscustomobject]@{ Path = '\Microsoft\Windows\PushToInstall\'; Name = 'Registration'; Group = 'Store' },
    [pscustomobject]@{ Path = '\Microsoft\Windows\Windows Error Reporting\'; Name = 'QueueReporting'; Group = 'Optional' }
)

# These are package identity names, never wildcard patterns. Provisioned
# packages are deliberately retained so rollback can re-register staged bits.
$AppPlan = @(
    'Microsoft.BingNews',
    'Microsoft.BingWeather',
    'Microsoft.GetHelp',
    'Microsoft.Getstarted',
    'Microsoft.Messaging',
    'Microsoft.Microsoft3DViewer',
    'Microsoft.MicrosoftOfficeHub',
    'Microsoft.MicrosoftSolitaireCollection',
    'Microsoft.MixedReality.Portal',
    'Microsoft.Office.OneNote',
    'Microsoft.OneConnect',
    'Microsoft.People',
    'Microsoft.Print3D',
    'Microsoft.SkypeApp',
    'Microsoft.Wallet',
    'Microsoft.WindowsFeedbackHub',
    'Microsoft.WindowsMaps',
    'Microsoft.WindowsSoundRecorder',
    'Microsoft.Xbox.TCUI',
    'Microsoft.XboxApp',
    'Microsoft.XboxGameOverlay',
    'Microsoft.XboxGamingOverlay',
    'Microsoft.XboxIdentityProvider',
    'Microsoft.XboxSpeechToTextOverlay',
    'Microsoft.YourPhone',
    'Microsoft.ZuneMusic',
    'Microsoft.ZuneVideo',
    'Microsoft.549981C3F5F10',
    'Clipchamp.Clipchamp',
    'MicrosoftTeams',
    'MSTeams',
    'SpotifyAB.SpotifyMusic',
    'king.com.CandyCrushSaga',
    'king.com.CandyCrushSodaSaga',
    'king.com.CandyCrushFriends',
    '4DF9E0F8.Netflix',
    'Disney.37853FC22B2CE',
    'Facebook.Facebook',
    'Twitter.Twitter',
    'Microsoft.StorePurchaseApp',
    'Microsoft.WindowsStore'
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
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Mode {1}' -f `
        $PSCommandPath.Replace('"', '""'), $Mode
    $process = Start-Process -FilePath $powerShell -Verb RunAs `
        -ArgumentList $arguments -Wait -PassThru
    exit $process.ExitCode
}

function Assert-Windows10 {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $build = [int]$os.BuildNumber
    if ([int]$os.ProductType -ne 1 -or $build -lt 10240 -or $build -ge 22000) {
        throw "This package supports Windows 10 client only. Detected: $($os.Caption), build $build."
    }
    return $os
}

function Assert-InteractiveAdministrator {
    $current = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $interactive = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName
    if ([string]::IsNullOrWhiteSpace([string]$interactive)) {
        throw 'No interactive Windows user is logged on.'
    }
    if ($current -ine $interactive) {
        throw "Elevated identity '$current' differs from interactive user '$interactive'. Sign in with the administrator account that should be debloated and run again."
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

function Install-LocalTools {
    New-Item -Path $ToolRoot -ItemType Directory -Force | Out-Null
    foreach ($name in @(
        'G11-Guest-Lite.ps1', '01-OneClick-Apply.cmd', '02-Audit.cmd',
        '03-Rollback.cmd', 'README.txt'
    )) {
        $source = Join-Path $PSScriptRoot $name
        $destination = Join-Path $ToolRoot $name
        if ((Test-Path -LiteralPath $source -PathType Leaf) -and
            [IO.Path]::GetFullPath($source) -ine [IO.Path]::GetFullPath($destination)) {
            Copy-Item -LiteralPath $source -Destination $destination -Force
        }
    }
}

function Get-OptionalRegistryValue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return $null
    }
    $key = Get-Item -LiteralPath $Path -ErrorAction Stop
    if (@($key.GetValueNames()) -notcontains $Name) {
        return $null
    }
    return $key.GetValue(
        $Name, $null,
        [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
    )
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

    New-Item -Path $Entry.Path -Force | Out-Null
    New-ItemProperty -Path $Entry.Path -Name $Entry.Name `
        -PropertyType $Entry.Type -Value $Entry.Value -Force | Out-Null
    Write-Host "  policy: $($Entry.Path)\$($Entry.Name)=$($Entry.Value)" `
        -ForegroundColor DarkGray
}

function Restore-RegistrySnapshot {
    param([Parameter(Mandatory = $true)][object]$Snapshot)

    $allowed = @($RegistryPlan | ForEach-Object { "$($_.Path)|$($_.Name)" })
    if ($allowed -notcontains "$($Snapshot.Path)|$($Snapshot.Name)") {
        throw "State contains an unexpected registry target: $($Snapshot.Path)\$($Snapshot.Name)"
    }
    if ([bool]$Snapshot.ValueExisted) {
        New-Item -Path ([string]$Snapshot.Path) -Force | Out-Null
        New-ItemProperty -Path ([string]$Snapshot.Path) `
            -Name ([string]$Snapshot.Name) -PropertyType ([string]$Snapshot.Kind) `
            -Value $Snapshot.Value -Force | Out-Null
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

function Get-DefenderPreferenceSnapshots {
    $result = New-Object 'System.Collections.Generic.List[object]'
    $getter = Get-Command Get-MpPreference -ErrorAction SilentlyContinue
    if ($null -eq $getter) {
        foreach ($plan in $DefenderPreferencePlan) {
            $result.Add([pscustomobject]@{
                Name = $plan.Name; Supported = $false; HasValue = $false
                Value = $null; Error = 'Get-MpPreference is unavailable'
            })
        }
        return $result.ToArray()
    }

    try {
        $preferences = & $getter -ErrorAction Stop
    } catch {
        foreach ($plan in $DefenderPreferencePlan) {
            $result.Add([pscustomobject]@{
                Name = $plan.Name; Supported = $false; HasValue = $false
                Value = $null; Error = $_.Exception.Message
            })
        }
        return $result.ToArray()
    }

    foreach ($plan in $DefenderPreferencePlan) {
        $property = $preferences.PSObject.Properties[[string]$plan.Name]
        $supported = $null -ne $property
        $value = if ($supported) { $property.Value } else { $null }
        $result.Add([pscustomobject]@{
            Name = [string]$plan.Name
            Supported = [bool]$supported
            HasValue = [bool]($supported -and $null -ne $value)
            Value = $value
            Error = ''
        })
    }
    return $result.ToArray()
}

function Test-DefenderPreferenceValue {
    param(
        [AllowNull()][object]$Actual,
        [Parameter(Mandatory = $true)][object]$Desired
    )

    if ($Desired -is [bool]) { return [bool]$Actual -eq [bool]$Desired }
    if ($Desired -is [int]) { return [int]$Actual -eq [int]$Desired }
    return $Actual -eq $Desired
}

function Get-MpCmdRunPath {
    $platformRoot = Join-Path $env:ProgramData `
        'Microsoft\Windows Defender\Platform'
    if (Test-Path -LiteralPath $platformRoot -PathType Container) {
        foreach ($directory in @(Get-ChildItem -LiteralPath $platformRoot `
            -Directory -ErrorAction SilentlyContinue | `
            Sort-Object Name -Descending)) {
            $candidate = Join-Path $directory.FullName 'MpCmdRun.exe'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return $candidate
            }
        }
    }
    $legacy = Join-Path $env:ProgramFiles 'Windows Defender\MpCmdRun.exe'
    if (Test-Path -LiteralPath $legacy -PathType Leaf) { return $legacy }
    return $null
}

function Stop-CurrentDefenderScan {
    $mpCmdRun = Get-MpCmdRunPath
    if ([string]::IsNullOrWhiteSpace([string]$mpCmdRun)) {
        Write-Warning 'MpCmdRun.exe was not found; no active scan cancellation was attempted.'
        return
    }
    & $mpCmdRun -Scan -Cancel *> $null
    $result = $LASTEXITCODE
    if ($result -eq 0) {
        Write-Host '  Defender: requested cancellation of the current on-demand scan' `
            -ForegroundColor DarkGray
    } else {
        Write-Host "  Defender: no cancellable scan, or MpCmdRun returned $result" `
            -ForegroundColor DarkGray
    }
}

function Set-DefenderRuntimePreferences {
    $failures = New-Object 'System.Collections.Generic.List[string]'
    $setter = Get-Command Set-MpPreference -ErrorAction SilentlyContinue
    if ($null -eq $setter) {
        $failures.Add('Defender runtime: Set-MpPreference is unavailable')
        return $failures.ToArray()
    }

    foreach ($plan in $DefenderPreferencePlan) {
        if (-not $setter.Parameters.ContainsKey([string]$plan.Name)) {
            if ([bool]$plan.Required) {
                $failures.Add("Defender runtime parameter is unavailable: $($plan.Name)")
            } else {
                Write-Host "  Defender: skip unsupported $($plan.Name)" `
                    -ForegroundColor DarkGray
            }
            continue
        }
        try {
            $arguments = @{ ErrorAction = 'Stop' }
            $arguments[[string]$plan.Name] = $plan.Value
            & $setter @arguments | Out-Null
            Write-Host "  Defender: $($plan.Name)=$($plan.Value)" `
                -ForegroundColor DarkGray
        } catch {
            $failures.Add("Defender runtime $($plan.Name): $($_.Exception.Message)")
        }
    }

    Stop-CurrentDefenderScan
    $getter = Get-Command Get-MpPreference -ErrorAction SilentlyContinue
    if ($null -eq $getter) {
        $failures.Add('Defender runtime state cannot be verified: Get-MpPreference is unavailable')
        return $failures.ToArray()
    }
    try {
        $current = & $getter -ErrorAction Stop
        foreach ($plan in $DefenderPreferencePlan) {
            if (-not $setter.Parameters.ContainsKey([string]$plan.Name)) {
                continue
            }
            $property = $current.PSObject.Properties[[string]$plan.Name]
            if ($null -eq $property -or
                -not (Test-DefenderPreferenceValue `
                    -Actual $property.Value -Desired $plan.Value)) {
                $shown = if ($null -eq $property) {
                    '<unavailable>'
                } else { [string]$property.Value }
                $failures.Add("Defender runtime preference was ignored: $($plan.Name) current=$shown desired=$($plan.Value)")
            }
        }
    } catch {
        $failures.Add("Defender runtime state cannot be verified: $($_.Exception.Message)")
    }
    return $failures.ToArray()
}

function Restore-DefenderPreferenceSnapshots {
    param([AllowNull()][object[]]$Snapshots)

    $failures = New-Object 'System.Collections.Generic.List[string]'
    if ($null -eq $Snapshots -or $Snapshots.Count -eq 0) {
        return $failures.ToArray()
    }
    $setter = Get-Command Set-MpPreference -ErrorAction SilentlyContinue
    if ($null -eq $setter) {
        $failures.Add('Defender rollback: Set-MpPreference is unavailable')
        return $failures.ToArray()
    }
    foreach ($snapshot in $Snapshots) {
        $name = [string]$snapshot.Name
        if ($DefenderPreferencePlan.Name -notcontains $name) {
            $failures.Add("Defender rollback state contains an unexpected preference: $name")
            continue
        }
        if (-not [bool]$snapshot.Supported -or
            -not [bool]$snapshot.HasValue) {
            continue
        }
        if (-not $setter.Parameters.ContainsKey($name)) {
            $failures.Add("Defender rollback parameter is unavailable: $name")
            continue
        }
        try {
            $arguments = @{ ErrorAction = 'Stop' }
            $arguments[$name] = $snapshot.Value
            & $setter @arguments | Out-Null
            Write-Host "  Defender restored: $name=$($snapshot.Value)" `
                -ForegroundColor DarkGray
        } catch {
            $failures.Add("Defender rollback ${name}: $($_.Exception.Message)")
        }
    }
    return $failures.ToArray()
}

function Get-ServiceSnapshot {
    param([Parameter(Mandatory = $true)][object]$Plan)

    $service = Get-CimInstance Win32_Service `
        -Filter "Name='$($Plan.Name)'" -ErrorAction SilentlyContinue
    if ($null -eq $service) {
        return [pscustomobject]@{
            Name = $Plan.Name; Exists = $false; StartMode = ''; State = ''
            DelayedAutoStart = 0
        }
    }
    $delayed = 0
    $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$($Plan.Name)"
    $saved = Get-OptionalRegistryValue -Path $key -Name DelayedAutoStart
    if ($null -ne $saved) { $delayed = [int]$saved }
    return [pscustomobject]@{
        Name = [string]$Plan.Name
        Exists = $true
        StartMode = [string]$service.StartMode
        State = [string]$service.State
        DelayedAutoStart = $delayed
    }
}

function Disable-PlannedServices {
    $failures = New-Object 'System.Collections.Generic.List[string]'
    foreach ($plan in $ServicePlan) {
        $saved = Get-ServiceSnapshot $plan
        if (-not [bool]$saved.Exists) {
            Write-Host "  service absent: $($plan.Name)" -ForegroundColor DarkGray
            continue
        }
        try {
            Stop-Service -Name $plan.Name -Force -ErrorAction SilentlyContinue
            Set-Service -Name $plan.Name -StartupType Disabled -ErrorAction Stop
            Write-Host "  service disabled: $($plan.Name) ($($plan.Purpose))" `
                -ForegroundColor DarkGray
        } catch {
            $message = "service $($plan.Name): $($_.Exception.Message)"
            $failures.Add($message)
            Write-Warning $message
        }
    }
    # Windows PowerShell 5.1 can throw "Argument types do not match" when an
    # array subexpression directly wraps System.Collections.Generic.List[T].
    return $failures.ToArray()
}

function Restore-ServiceSnapshot {
    param([Parameter(Mandatory = $true)][object]$Snapshot)

    if ($ServicePlan.Name -notcontains [string]$Snapshot.Name) {
        throw "State contains an unexpected service: $($Snapshot.Name)"
    }
    if (-not [bool]$Snapshot.Exists) { return }
    if ($null -eq (Get-Service -Name ([string]$Snapshot.Name) `
        -ErrorAction SilentlyContinue)) {
        Write-Warning "Service '$($Snapshot.Name)' no longer exists; rollback did not recreate it."
        return
    }
    switch ([string]$Snapshot.StartMode) {
        'Auto' {
            if ([int]$Snapshot.DelayedAutoStart -eq 1) {
                & sc.exe config ([string]$Snapshot.Name) 'start=' 'delayed-auto' | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    throw "Could not restore delayed-auto mode for service '$($Snapshot.Name)'."
                }
            } else {
                Set-Service -Name ([string]$Snapshot.Name) -StartupType Automatic
            }
        }
        'Manual' {
            Set-Service -Name ([string]$Snapshot.Name) -StartupType Manual
        }
        'Disabled' {
            Set-Service -Name ([string]$Snapshot.Name) -StartupType Disabled
        }
        default {
            throw "Unsupported saved StartMode '$($Snapshot.StartMode)' for service '$($Snapshot.Name)'."
        }
    }
    if ([string]$Snapshot.State -eq 'Running' -and
        [string]$Snapshot.StartMode -ne 'Disabled') {
        Start-Service -Name ([string]$Snapshot.Name) -ErrorAction Stop
    }
}

function Get-TaskSnapshot {
    param([Parameter(Mandatory = $true)][object]$Plan)

    $task = Get-ScheduledTask -TaskName $Plan.Name -TaskPath $Plan.Path `
        -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $task) {
        return [pscustomobject]@{
            Path = $Plan.Path; Name = $Plan.Name; Exists = $false
            Enabled = $false
        }
    }
    return [pscustomobject]@{
        Path = [string]$Plan.Path
        Name = [string]$Plan.Name
        Exists = $true
        Enabled = [bool]$task.Settings.Enabled
    }
}

function Disable-PlannedTasks {
    $failures = New-Object 'System.Collections.Generic.List[string]'
    foreach ($plan in $TaskPlan) {
        $saved = Get-TaskSnapshot $plan
        if (-not [bool]$saved.Exists -or -not [bool]$saved.Enabled) { continue }
        try {
            Stop-ScheduledTask -TaskName $plan.Name -TaskPath $plan.Path `
                -ErrorAction SilentlyContinue
            Disable-ScheduledTask -TaskName $plan.Name -TaskPath $plan.Path `
                -ErrorAction Stop | Out-Null
            Write-Host "  task disabled: $($plan.Path)$($plan.Name)" `
                -ForegroundColor DarkGray
        } catch {
            $message = "task $($plan.Path)$($plan.Name): $($_.Exception.Message)"
            $failures.Add($message)
            Write-Warning $message
        }
    }
    return $failures.ToArray()
}

function Restore-TaskSnapshot {
    param([Parameter(Mandatory = $true)][object]$Snapshot)

    $allowed = @($TaskPlan | ForEach-Object { "$($_.Path)|$($_.Name)" })
    if ($allowed -notcontains "$($Snapshot.Path)|$($Snapshot.Name)") {
        throw "State contains an unexpected task: $($Snapshot.Path)$($Snapshot.Name)"
    }
    if (-not [bool]$Snapshot.Exists -or -not [bool]$Snapshot.Enabled) { return }
    $task = Get-ScheduledTask -TaskName ([string]$Snapshot.Name) `
        -TaskPath ([string]$Snapshot.Path) -ErrorAction SilentlyContinue
    if ($null -eq $task) {
        Write-Warning "Task '$($Snapshot.Path)$($Snapshot.Name)' no longer exists; rollback did not recreate it."
        return
    }
    Enable-ScheduledTask -TaskName ([string]$Snapshot.Name) `
        -TaskPath ([string]$Snapshot.Path) -ErrorAction Stop | Out-Null
}

function Get-AppSnapshots {
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($name in $AppPlan) {
        foreach ($package in @(Get-AppxPackage -Name $name `
            -ErrorAction SilentlyContinue)) {
            $rows.Add([pscustomobject]@{
                Name = [string]$package.Name
                PackageFullName = [string]$package.PackageFullName
                PackageFamilyName = [string]$package.PackageFamilyName
                InstallLocation = [string]$package.InstallLocation
            })
        }
    }
    return $rows.ToArray()
}

function Remove-PlannedApps {
    param([Parameter(Mandatory = $true)][object[]]$Snapshots)

    $failures = New-Object 'System.Collections.Generic.List[string]'
    foreach ($package in $Snapshots) {
        if ($AppPlan -notcontains [string]$package.Name) {
            $message = "unexpected app identity in state: $($package.Name)"
            $failures.Add($message)
            Write-Warning $message
            continue
        }
        if ($null -eq (Get-AppxPackage -Name ([string]$package.Name) `
            -ErrorAction SilentlyContinue)) { continue }
        try {
            Remove-AppxPackage -Package ([string]$package.PackageFullName) `
                -ErrorAction Stop
            Write-Host "  app removed for current user: $($package.Name)" `
                -ForegroundColor DarkGray
        } catch {
            $message = "app $($package.Name): $($_.Exception.Message)"
            $failures.Add($message)
            Write-Warning $message
        }
    }
    return $failures.ToArray()
}

function Find-SafeAppManifest {
    param([Parameter(Mandatory = $true)][object]$Snapshot)

    if ($AppPlan -notcontains [string]$Snapshot.Name) { return $null }
    $windowsAppsRoot = [IO.Path]::GetFullPath(
        (Join-Path $env:ProgramFiles 'WindowsApps')
    ).TrimEnd('\')
    $windowsApps = $windowsAppsRoot + '\'
    $candidates = New-Object 'System.Collections.Generic.List[string]'
    if (-not [string]::IsNullOrWhiteSpace([string]$Snapshot.InstallLocation)) {
        $candidates.Add([string]$Snapshot.InstallLocation)
    }
    foreach ($package in @(Get-AppxPackage -AllUsers `
        -Name ([string]$Snapshot.Name) -ErrorAction SilentlyContinue)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$package.InstallLocation)) {
            $candidates.Add([string]$package.InstallLocation)
        }
    }
    try {
        foreach ($package in @(Get-AppxProvisionedPackage -Online `
            -ErrorAction Stop | Where-Object {
                [string]$_.DisplayName -eq [string]$Snapshot.Name
            })) {
            if (-not [string]::IsNullOrWhiteSpace([string]$package.PackageName)) {
                $candidates.Add((Join-Path $windowsAppsRoot `
                    ([string]$package.PackageName)))
            }
        }
    } catch {
        # AllUsers and the saved exact location remain valid fallbacks.
    }
    foreach ($candidate in $candidates) {
        try {
            $full = [IO.Path]::GetFullPath($candidate).TrimEnd('\')
        } catch { continue }
        if (-not $full.StartsWith($windowsApps, `
            [StringComparison]::OrdinalIgnoreCase)) { continue }
        if (-not ([IO.Path]::GetFileName($full)).StartsWith(
            ([string]$Snapshot.Name + '_'), [StringComparison]::OrdinalIgnoreCase
        )) { continue }
        $manifest = Join-Path $full 'AppxManifest.xml'
        if (Test-Path -LiteralPath $manifest -PathType Leaf) { return $manifest }
    }
    return $null
}

function Restore-PlannedApps {
    param([Parameter(Mandatory = $true)][object[]]$Snapshots)

    $failures = New-Object 'System.Collections.Generic.List[string]'
    foreach ($package in $Snapshots) {
        if ($AppPlan -notcontains [string]$package.Name) {
            $message = "unexpected app identity in state: $($package.Name)"
            $failures.Add($message)
            Write-Warning $message
            continue
        }
        if ($null -ne (Get-AppxPackage -Name ([string]$package.Name) `
            -ErrorAction SilentlyContinue)) { continue }
        $manifest = Find-SafeAppManifest $package
        if ($null -eq $manifest) {
            $message = "app $($package.Name): staged AppxManifest.xml was not found"
            $failures.Add($message)
            Write-Warning $message
            continue
        }
        try {
            Add-AppxPackage -DisableDevelopmentMode -Register $manifest `
                -ErrorAction Stop
            Write-Host "  app restored: $($package.Name)" -ForegroundColor DarkGray
        } catch {
            $message = "app $($package.Name): $($_.Exception.Message)"
            $failures.Add($message)
            Write-Warning $message
        }
    }
    return $failures.ToArray()
}

function Save-StateAtomically {
    param([Parameter(Mandatory = $true)][object]$State)

    $temporary = Join-Path $StateRoot `
        ('.state.{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
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
    $state = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | `
        ConvertFrom-Json
    if ([int]$state.SchemaVersion -ne $SchemaVersion) {
        throw "Unsupported state schema '$($state.SchemaVersion)'."
    }
    if ([string]$state.ComputerName -ine $env:COMPUTERNAME) {
        throw "State belongs to computer '$($state.ComputerName)', not '$env:COMPUTERNAME'."
    }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if ([string]$state.UserSid -ne $sid) {
        throw "State belongs to user SID '$($state.UserSid)', current SID is '$sid'."
    }
    return $state
}

function Get-TamperProtectionState {
    $command = Get-Command Get-MpComputerStatus -ErrorAction SilentlyContinue
    if ($null -eq $command) { return 'DefenderAbsent' }
    try { $status = Get-MpComputerStatus -ErrorAction Stop } catch {
        return 'Unknown'
    }
    $property = $status.PSObject.Properties['IsTamperProtected']
    if ($null -eq $property) { return 'Unknown' }
    if ([bool]$property.Value) { return 'On' }
    return 'Off'
}

function Get-DefenderStatusSummary {
    $result = [ordered]@{
        Available = $false
        Error = ''
        AMServiceEnabled = $false
        AntivirusEnabled = $false
        AntispywareEnabled = $false
        RealTimeProtectionEnabled = $false
        BehaviorMonitorEnabled = $false
        IoavProtectionEnabled = $false
        OnAccessProtectionEnabled = $false
        NISEnabled = $false
        WinDefendState = 'Absent'
        MsMpEngProcessRunning = $false
    }
    $service = Get-Service -Name WinDefend -ErrorAction SilentlyContinue
    if ($null -ne $service) { $result.WinDefendState = [string]$service.Status }
    $result.MsMpEngProcessRunning = [bool](@(Get-Process -Name MsMpEng `
        -ErrorAction SilentlyContinue).Count -gt 0)
    if ($null -eq (Get-Command Get-MpComputerStatus `
        -ErrorAction SilentlyContinue)) {
        return [pscustomobject]$result
    }
    try {
        $status = Get-MpComputerStatus -ErrorAction Stop
        $result.Available = $true
        foreach ($name in @(
            'AMServiceEnabled', 'AntivirusEnabled', 'AntispywareEnabled',
            'RealTimeProtectionEnabled', 'BehaviorMonitorEnabled',
            'IoavProtectionEnabled', 'OnAccessProtectionEnabled', 'NISEnabled'
        )) {
            $property = $status.PSObject.Properties[$name]
            if ($null -ne $property) { $result[$name] = [bool]$property.Value }
        }
    } catch {
        $result.Error = $_.Exception.Message
    }
    return [pscustomobject]$result
}

function Assert-DefenderCanBeConfigured {
    $tamper = Get-TamperProtectionState
    if ($tamper -eq 'On') {
        throw 'Tamper Protection is ON. Open Windows Security > Virus & threat protection > Manage settings, turn Tamper Protection OFF manually, then run again.'
    }
    $os = Get-CimInstance Win32_OperatingSystem
    if ($tamper -eq 'Unknown' -and [int]$os.BuildNumber -ge 18362) {
        throw 'Tamper Protection state cannot be verified. This tool will not bypass it. Check Windows Security manually, then run again.'
    }
    # On consumer Windows 10 the Status key can exist without this optional
    # value. Get-ItemPropertyValue turns that normal state into a terminating
    # error on Windows PowerShell 5.1, so inspect the value names first.
    $mde = Get-OptionalRegistryValue `
        -Path 'HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status' `
        -Name OnboardingState
    if ($null -ne $mde -and [int]$mde -eq 1) {
        throw 'Microsoft Defender for Endpoint is onboarded. Local disable policy is managed/ignored; this tool will not fight enterprise management.'
    }
}

function Confirm-FullProfile {
    $message = @'
This full Windows 10 guest profile will:

- turn off Microsoft Defender Antivirus protection
- turn off Windows Update and Microsoft Store
- remove reviewed consumer apps for this user
- disable reviewed optional services and tasks

The guest will have no built-in antivirus and will not receive security updates.
Continue?
'@
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $answer = [System.Windows.Forms.MessageBox]::Show(
            $message, 'G-11 Guest Lite - security warning',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning,
            [System.Windows.Forms.MessageBoxDefaultButton]::Button2
        )
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
            throw 'Operation cancelled by user.'
        }
    } catch [System.Management.Automation.RuntimeException] {
        throw
    } catch {
        Write-Host $message -ForegroundColor Yellow
        $answer = Read-Host 'Type YES to continue'
        if ($answer -cne 'YES') { throw 'Operation cancelled by user.' }
    }
}

function Get-AntivirusProducts {
    try {
        return @(Get-CimInstance -Namespace 'root/SecurityCenter2' `
            -ClassName AntiVirusProduct -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{
                    Name = [string]$_.displayName
                    State = ('0x{0:X6}' -f [int]$_.productState)
                    Path = [string]$_.pathToSignedProductExe
                }
            })
    } catch {
        return @()
    }
}

function Get-VerificationIssues {
    $issues = New-Object 'System.Collections.Generic.List[string]'
    foreach ($entry in $RegistryPlan) {
        try {
            $current = Get-RegistrySnapshot $entry
            if (-not [bool]$current.ValueExisted -or
                [int64]$current.Value -ne [int64]$entry.Value) {
                $shown = if ($current.ValueExisted) {
                    [string]$current.Value
                } else { '<missing>' }
                $issues.Add("policy not applied: $($entry.Path)\$($entry.Name) current=$shown desired=$($entry.Value)")
            }
        } catch {
            $issues.Add("policy unreadable: $($entry.Path)\$($entry.Name): $($_.Exception.Message)")
        }
    }
    foreach ($plan in $ServicePlan) {
        try {
            $current = Get-ServiceSnapshot $plan
            if ([bool]$current.Exists -and
                [string]$current.StartMode -ne 'Disabled') {
                $issues.Add("service still enabled: $($plan.Name) start=$($current.StartMode) state=$($current.State)")
            }
        } catch {
            $issues.Add("service unreadable: $($plan.Name): $($_.Exception.Message)")
        }
    }
    foreach ($plan in $TaskPlan) {
        try {
            $current = Get-TaskSnapshot $plan
            if ([bool]$current.Exists -and [bool]$current.Enabled) {
                $issues.Add("task still enabled: $($plan.Path)$($plan.Name)")
            }
        } catch {
            $issues.Add("task unreadable: $($plan.Path)$($plan.Name): $($_.Exception.Message)")
        }
    }
    foreach ($name in $AppPlan) {
        if ($null -ne (Get-AppxPackage -Name $name `
            -ErrorAction SilentlyContinue)) {
            $issues.Add("app still registered for current user: $name")
        }
    }

    $defender = Get-DefenderStatusSummary
    if (-not [bool]$defender.Available -and
        -not [string]::IsNullOrWhiteSpace([string]$defender.Error)) {
        $issues.Add("Defender effective state cannot be read: $($defender.Error)")
    }
    if ([bool]$defender.Available) {
        foreach ($name in @(
            'AMServiceEnabled', 'AntivirusEnabled', 'AntispywareEnabled',
            'RealTimeProtectionEnabled', 'BehaviorMonitorEnabled',
            'IoavProtectionEnabled', 'OnAccessProtectionEnabled', 'NISEnabled'
        )) {
            if ([bool]$defender.$name) {
                $issues.Add("Defender effective state remains enabled: $name")
            }
        }
    }
    if ([bool]$defender.MsMpEngProcessRunning) {
        $issues.Add('Defender process still running: MsMpEng.exe (Antimalware Service Executable)')
    }
    if ([string]$defender.WinDefendState -eq 'Running') {
        $issues.Add('Defender protected service still running: WinDefend')
    }
    return $issues.ToArray()
}

function New-AuditReport {
    param([Parameter(Mandatory = $true)][string]$Label)

    Initialize-StateRoot
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $os = Get-CimInstance Win32_OperatingSystem
    $computer = Get-CimInstance Win32_ComputerSystem
    $lines.Add('G-11 Windows 10 guest lite audit')
    $lines.Add("generated=$([DateTime]::Now.ToString('o')) label=$Label")
    $lines.Add("computer=$env:COMPUTERNAME user=$([Security.Principal.WindowsIdentity]::GetCurrent().Name)")
    $lines.Add("os=$($os.Caption) version=$($os.Version) build=$($os.BuildNumber)")
    $lines.Add("domainJoined=$($computer.PartOfDomain) tamperProtection=$(Get-TamperProtectionState)")
    $defender = Get-DefenderStatusSummary
    $lines.Add("defenderAvailable=$($defender.Available) amServiceEnabled=$($defender.AMServiceEnabled) antivirusEnabled=$($defender.AntivirusEnabled) antispywareEnabled=$($defender.AntispywareEnabled) realtimeEnabled=$($defender.RealTimeProtectionEnabled) behaviorEnabled=$($defender.BehaviorMonitorEnabled) ioavEnabled=$($defender.IoavProtectionEnabled) onAccessEnabled=$($defender.OnAccessProtectionEnabled) nisEnabled=$($defender.NISEnabled) winDefendState=$($defender.WinDefendState) msMpEngRunning=$($defender.MsMpEngProcessRunning) error=$($defender.Error)")
    foreach ($product in @(Get-AntivirusProducts)) {
        $lines.Add("antivirus=$($product.Name) state=$($product.State) path=$($product.Path)")
    }
    $lines.Add('')

    $lines.Add('[policy registry]')
    foreach ($entry in $RegistryPlan) {
        $saved = Get-RegistrySnapshot $entry
        $current = if ($saved.ValueExisted) { [string]$saved.Value } else { '<missing>' }
        $lines.Add("group=$($entry.Group) path=$($entry.Path) name=$($entry.Name) current=$current desired=$($entry.Value)")
    }
    $lines.Add('')

    $lines.Add('[defender runtime preferences]')
    $currentPreferences = @(Get-DefenderPreferenceSnapshots)
    foreach ($plan in $DefenderPreferencePlan) {
        $snapshot = @($currentPreferences | Where-Object {
            [string]$_.Name -eq [string]$plan.Name
        }) | Select-Object -First 1
        if ($null -eq $snapshot) {
            $lines.Add("name=$($plan.Name) supported=False current=<unavailable> desired=$($plan.Value)")
        } else {
            $shown = if ([bool]$snapshot.HasValue) {
                [string]$snapshot.Value
            } else { '<unavailable>' }
            $lines.Add("name=$($plan.Name) supported=$($snapshot.Supported) current=$shown desired=$($plan.Value) error=$($snapshot.Error)")
        }
    }
    $lines.Add('')

    $lines.Add('[services]')
    foreach ($plan in $ServicePlan) {
        $saved = Get-ServiceSnapshot $plan
        $lines.Add("group=$($plan.Group) name=$($plan.Name) exists=$($saved.Exists) start=$($saved.StartMode) state=$($saved.State) purpose=$($plan.Purpose)")
    }
    $lines.Add('')

    $lines.Add('[scheduled tasks]')
    foreach ($plan in $TaskPlan) {
        $saved = Get-TaskSnapshot $plan
        $lines.Add("group=$($plan.Group) task=$($plan.Path)$($plan.Name) exists=$($saved.Exists) enabled=$($saved.Enabled)")
    }
    $lines.Add('')

    $installed = @(Get-AppSnapshots)
    $lines.Add('[removable current-user apps]')
    foreach ($name in $AppPlan) {
        $found = @($installed | Where-Object { $_.Name -eq $name }).Count
        $lines.Add("name=$name installed=$([bool]($found -gt 0))")
    }
    $lines.Add('')
    $lines.Add('[protected by design]')
    $lines.Add('BCD and boot integrity; kernel and NVIDIA/vGPU drivers; Windows Firewall; audio; networking; printing; Windows Search; BITS; CryptSvc; AppXSvc; ClipSVC; Microsoft Edge/WebView2; Calculator; Photos; Paint; Notepad; DesktopAppInstaller; VCLibs/.NET/UI.Xaml dependencies.')

    $safeLabel = $Label -replace '[^A-Za-z0-9_.-]', '_'
    $path = Join-Path $ReportRoot ('{0}-{1}.txt' -f `
        (Get-Date -Format 'yyyyMMdd-HHmmss'), $safeLabel)
    $lines | Set-Content -LiteralPath $path -Encoding UTF8
    Write-Host "Audit report: $path" -ForegroundColor Cyan
    return $path
}

function New-OriginalState {
    $os = Get-CimInstance Win32_OperatingSystem
    $state = [ordered]@{
        SchemaVersion = $SchemaVersion
        CreatedUtc = [DateTime]::UtcNow.ToString('o')
        ComputerName = $env:COMPUTERNAME
        UserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        UserName = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        OsCaption = [string]$os.Caption
        OsBuild = [string]$os.BuildNumber
        DefenderPreferences = @(Get-DefenderPreferenceSnapshots)
        Registry = @($RegistryPlan | ForEach-Object { Get-RegistrySnapshot $_ })
        Services = @($ServicePlan | ForEach-Object { Get-ServiceSnapshot $_ })
        Tasks = @($TaskPlan | ForEach-Object { Get-TaskSnapshot $_ })
        Apps = @(Get-AppSnapshots)
    }
    Save-StateAtomically $state
    return (Read-State)
}

function Ensure-DefenderPreferenceBaseline {
    param([Parameter(Mandatory = $true)][object]$State)

    if ($null -ne $State.PSObject.Properties['DefenderPreferences']) {
        return $State
    }
    $baseline = @(Get-DefenderPreferenceSnapshots)
    Add-Member -InputObject $State -MemberType NoteProperty `
        -Name DefenderPreferences -Value $baseline
    Save-StateAtomically $State
    Write-Host 'Added a rollback baseline for the new Defender runtime controls.' `
        -ForegroundColor Yellow
    return $State
}

function Invoke-Apply {
    Assert-Windows10 | Out-Null
    Assert-InteractiveAdministrator
    Assert-DefenderCanBeConfigured
    Confirm-FullProfile
    Initialize-StateRoot
    Install-LocalTools

    $null = New-AuditReport 'before-apply'
    if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
        $state = Read-State
        Write-Host "Reusing original rollback baseline: $StatePath" `
            -ForegroundColor Yellow
    } else {
        $state = New-OriginalState
        Write-Host "Saved original rollback baseline: $StatePath" `
            -ForegroundColor Green
    }
    $state = Ensure-DefenderPreferenceBaseline $state

    $failures = New-Object 'System.Collections.Generic.List[string]'
    Write-Host '[1/5] Applying reviewed policy values' -ForegroundColor Cyan
    foreach ($entry in $RegistryPlan) {
        try { Set-PlannedRegistryValue $entry } catch {
            $message = "policy $($entry.Path)\$($entry.Name): $($_.Exception.Message)"
            $failures.Add($message)
            Write-Warning $message
        }
    }

    Write-Host '[2/5] Disabling live Defender scanning and cancelling current scan' `
        -ForegroundColor Cyan
    foreach ($failure in @(Set-DefenderRuntimePreferences)) {
        $failures.Add($failure)
    }

    Write-Host '[3/5] Disabling reviewed services' -ForegroundColor Cyan
    foreach ($failure in @(Disable-PlannedServices)) { $failures.Add($failure) }

    Write-Host '[4/5] Disabling reviewed scheduled tasks' -ForegroundColor Cyan
    foreach ($failure in @(Disable-PlannedTasks)) { $failures.Add($failure) }

    Write-Host '[5/5] Removing reviewed apps for the current user' `
        -ForegroundColor Cyan
    foreach ($failure in @(Remove-PlannedApps @($state.Apps))) {
        $failures.Add($failure)
    }

    $null = New-AuditReport 'after-apply'
    Write-Host ''
    if ($failures.Count -gt 0) {
        Write-Host "APPLY PARTIAL: $($failures.Count) item(s) were protected or failed." `
            -ForegroundColor Yellow
        foreach ($failure in $failures) { Write-Host "  - $failure" }
        Write-Host 'The rollback baseline is intact. Reboot, then run 02-Audit.cmd; it now verifies MsMpEng.exe and WinDefend explicitly.'
        return 3
    }
    Write-Host 'APPLY PASS: full guest-lite profile is staged.' -ForegroundColor Green
    Write-Host 'Restart Windows now. After restart, run 02-Audit.cmd to verify Defender/Update/Store, MsMpEng.exe, and WinDefend state.'
    return 0
}

function Invoke-Rollback {
    Assert-Windows10 | Out-Null
    Assert-InteractiveAdministrator
    Initialize-StateRoot
    $state = Read-State
    $failures = New-Object 'System.Collections.Generic.List[string]'

    Write-Host '[1/5] Restoring registry policy values' -ForegroundColor Cyan
    foreach ($snapshot in @($state.Registry)) {
        try { Restore-RegistrySnapshot $snapshot } catch {
            $message = "policy $($snapshot.Path)\$($snapshot.Name): $($_.Exception.Message)"
            $failures.Add($message)
            Write-Warning $message
        }
    }

    Write-Host '[2/5] Restoring Defender runtime preferences' -ForegroundColor Cyan
    $defenderSnapshots = @()
    if ($null -ne $state.PSObject.Properties['DefenderPreferences']) {
        $defenderSnapshots = @($state.DefenderPreferences)
    }
    foreach ($failure in @(
        Restore-DefenderPreferenceSnapshots $defenderSnapshots
    )) {
        $failures.Add($failure)
    }

    Write-Host '[3/5] Restoring service startup/running state' -ForegroundColor Cyan
    foreach ($snapshot in @($state.Services)) {
        try { Restore-ServiceSnapshot $snapshot } catch {
            $message = "service $($snapshot.Name): $($_.Exception.Message)"
            $failures.Add($message)
            Write-Warning $message
        }
    }

    Write-Host '[4/5] Restoring scheduled task enabled state' -ForegroundColor Cyan
    foreach ($snapshot in @($state.Tasks)) {
        try { Restore-TaskSnapshot $snapshot } catch {
            $message = "task $($snapshot.Path)$($snapshot.Name): $($_.Exception.Message)"
            $failures.Add($message)
            Write-Warning $message
        }
    }

    Write-Host '[5/5] Re-registering removed current-user apps' `
        -ForegroundColor Cyan
    foreach ($failure in @(Restore-PlannedApps @($state.Apps))) {
        $failures.Add($failure)
    }

    $null = New-AuditReport 'after-rollback'
    if ($failures.Count -gt 0) {
        Write-Host "ROLLBACK PARTIAL: $($failures.Count) item(s) need attention." `
            -ForegroundColor Yellow
        foreach ($failure in $failures) { Write-Host "  - $failure" }
        Write-Host "State was retained for retry: $StatePath"
        return 3
    }

    $archive = Join-Path $StateRoot ('state.rolled-back.{0}.json' -f `
        (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Move-Item -LiteralPath $StatePath -Destination $archive -Force
    Write-Host "ROLLBACK PASS: original state restored. Archive: $archive" `
        -ForegroundColor Green
    Write-Host 'Restart Windows now.'
    return 0
}

try {
    if (-not (Test-Administrator)) { Invoke-ElevatedSelf }
    $exitCode = switch ($Mode) {
        'Audit' {
            Assert-Windows10 | Out-Null
            Assert-InteractiveAdministrator
            $null = New-AuditReport 'manual-audit'
            if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
                $issues = @(Get-VerificationIssues)
                if ($issues.Count -eq 0) {
                    Write-Host 'VERIFY PASS: the applied profile matches the requested state.' `
                        -ForegroundColor Green
                    0
                } else {
                    Write-Host "VERIFY PARTIAL: $($issues.Count) item(s) do not match." `
                        -ForegroundColor Yellow
                    foreach ($issue in $issues) { Write-Host "  - $issue" }
                    3
                }
            } else {
                Write-Host 'AUDIT PASS: report generated; no Apply baseline exists yet.' `
                    -ForegroundColor Green
                0
            }
        }
        'Apply' { Invoke-Apply }
        'Rollback' { Invoke-Rollback }
    }
    exit [int]$exitCode
} catch {
    Write-Host ''
    Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
    if ($null -ne $_.InvocationInfo -and
        [int]$_.InvocationInfo.ScriptLineNumber -gt 0) {
        $failedCommand = [string]$_.InvocationInfo.MyCommand.Name
        if ([string]::IsNullOrWhiteSpace($failedCommand)) {
            $failedCommand = '<script>'
        }
        Write-Host ("FAILED AT: line {0}, command {1}" -f `
            [int]$_.InvocationInfo.ScriptLineNumber, $failedCommand) `
            -ForegroundColor Red
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$_.ScriptStackTrace)) {
        Write-Host "STACK: $($_.ScriptStackTrace)" -ForegroundColor DarkRed
    }
    Write-Host "No BCD, driver-signing, or kernel-driver change was attempted."
    exit 1
}
