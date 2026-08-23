#requires -Version 5.1
<#
.SYNOPSIS
  Audit, apply, or roll back the G-11 Windows 10 guest lite profile.

.DESCRIPTION
  The full profile disables Microsoft Defender Antivirus, Windows and common
  software auto-updaters, Microsoft Store, OneDrive/cloud sync, news/weather
  feeds, notifications, consumer Appx apps, background activity, and reviewed
  optional services/tasks. It also keeps the default playback endpoint muted,
  orders English (United States) - US first and Microsoft Pinyin second, enables
  Windows Game Mode while disabling Xbox background recording, selects the
  built-in High performance power plan, requests NVIDIA's global "Prefer
  maximum performance" mode through the installed driver's NVAPI DRS surface,
  gives allowlisted DNF game images High (never Realtime) priority, safely
  clears stale temporary files, and reduces desktop animation/startup delay for
  the interactive user.

  The tool does not bypass Tamper Protection, remove provisioned Appx payloads,
  modify BCD or driver-signing policy, change kernel drivers, delete firewall
  rules/service files, or delete Windows component-store files. Original
  registry, firewall, audio mute, user-language/input, power, NVIDIA DRS,
  running DNF priority, service, task, and app state is saved under
  C:\ProgramData\G11GuestLite. Deleted stale temporary files cannot be restored.
#>
[CmdletBinding()]
param(
    [ValidateSet('Audit', 'Apply', 'CloneApply', 'Rollback', 'Enforce')]
    [string]$Mode = 'Audit',
    [ValidatePattern('^$|^S-1-5-[0-9-]+$')]
    [string]$UserSid = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$StateRoot = Join-Path $env:ProgramData 'G11GuestLite'
$StatePath = Join-Path $StateRoot 'state.json'
$ReportRoot = Join-Path $StateRoot 'reports'
$ToolRoot = Join-Path $StateRoot 'tools'
$SchemaVersion = 6
$MinimumSchemaVersion = 1
$EnforcementTaskPath = '\'
$EnforcementTaskName = 'G11GuestLite-EnforceProfile'
$EnforcementLogPath = Join-Path $StateRoot 'enforce-last.txt'
$FirewallServiceName = 'MpsSvc'
$LocalPolicyRoot = Join-Path $env:SystemRoot 'System32\GroupPolicy'
$MachinePolicyPath = Join-Path $LocalPolicyRoot 'Machine\Registry.pol'
$UserPolicyPath = Join-Path $LocalPolicyRoot 'User\Registry.pol'
$PolicyMetadataPath = Join-Path $LocalPolicyRoot 'gpt.ini'
$EnglishLanguageTag = 'en-US'
$EnglishInputTip = '0409:00000409'
$PinyinLanguageTag = 'zh-CN'
$PinyinCanonicalLanguageTag = 'zh-Hans-CN'
$PinyinInputTip = '0804:{81D4E9C9-1D3B-41BC-9E6C-4B40BF79E35E}{FA550B04-5AD7-411F-A5AC-CA038EC515D7}'
$NvidiaPreferredPstateId = [uint32]0x1057EB71
$NvidiaPreferMaximumPerformance = [uint32]1
$TemporaryFileMinimumAgeHours = 24

# Policy values only. The tool never changes Defender service ACLs or deletes
# Defender files. Windows 10 1903+ requires Tamper Protection to be turned off
# manually before these policies can take effect.
$RegistryPlan = @(
    # DisableAntiSpyware is a legacy value that current Defender platforms can
    # protect or ignore even with Tamper Protection off. Keep requesting it,
    # but judge success from the supported runtime protection fields below.
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'; Name = 'DisableAntiSpyware'; Type = 'DWord'; Value = 1; Group = 'Defender'; Required = $false },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'; Name = 'DisableAntiVirus'; Type = 'DWord'; Value = 1; Group = 'Defender'; Required = $false },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'; Name = 'ServiceKeepAlive'; Type = 'DWord'; Value = 0; Group = 'Defender'; Required = $false },
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
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'; Name = 'DODownloadMode'; Type = 'DWord'; Value = 0; Group = 'WindowsUpdate' },

    # Keep installed desktop software usable while stopping the reviewed
    # vendor updaters. These are documented vendor policies; services/tasks
    # below are also disabled because consumer Windows may ignore domain-only
    # policy applicability.
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate'; Name = 'UpdateDefault'; Type = 'DWord'; Value = 0; Group = 'SoftwareUpdate' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate'; Name = 'AutoUpdateCheckPeriodMinutes'; Type = 'DWord'; Value = 0; Group = 'SoftwareUpdate' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate'; Name = 'EnableAutomaticUpdates'; Type = 'DWord'; Value = 0; Group = 'SoftwareUpdate' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Google\Update'; Name = 'UpdateDefault'; Type = 'DWord'; Value = 0; Group = 'SoftwareUpdate' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Google\Update'; Name = 'AutoUpdateCheckPeriodMinutes'; Type = 'DWord'; Value = 0; Group = 'SoftwareUpdate' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Google\Chrome'; Name = 'ComponentUpdatesEnabled'; Type = 'DWord'; Value = 0; Group = 'SoftwareUpdate' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox'; Name = 'DisableAppUpdate'; Type = 'DWord'; Value = 1; Group = 'SoftwareUpdate' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox'; Name = 'BackgroundAppUpdate'; Type = 'DWord'; Value = 0; Group = 'SoftwareUpdate' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Adobe\Acrobat Reader\DC\FeatureLockDown'; Name = 'bUpdater'; Type = 'DWord'; Value = 0; Group = 'SoftwareUpdate' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Adobe\Adobe Acrobat\DC\FeatureLockDown'; Name = 'bUpdater'; Type = 'DWord'; Value = 0; Group = 'SoftwareUpdate' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Policies\Adobe\Acrobat Reader\DC\FeatureLockDown'; Name = 'bUpdater'; Type = 'DWord'; Value = 0; Group = 'SoftwareUpdate' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Policies\Adobe\Adobe Acrobat\DC\FeatureLockDown'; Name = 'bUpdater'; Type = 'DWord'; Value = 0; Group = 'SoftwareUpdate' },

    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore'; Name = 'RemoveWindowsStore'; Type = 'DWord'; Value = 1; Group = 'Store' },
    [pscustomobject]@{ Path = 'HKCU:\SOFTWARE\Policies\Microsoft\WindowsStore'; Name = 'RemoveWindowsStore'; Type = 'DWord'; Value = 1; Group = 'Store' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore'; Name = 'AutoDownload'; Type = 'DWord'; Value = 2; Group = 'Store' },

    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive'; Name = 'DisableFileSyncNGSC'; Type = 'DWord'; Value = 1; Group = 'Cloud' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync'; Name = 'DisableSettingSync'; Type = 'DWord'; Value = 2; Group = 'Cloud' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync'; Name = 'DisableSettingSyncUserOverride'; Type = 'DWord'; Value = 1; Group = 'Cloud' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name = 'EnableActivityFeed'; Type = 'DWord'; Value = 0; Group = 'Cloud' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name = 'PublishUserActivities'; Type = 'DWord'; Value = 0; Group = 'Cloud' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name = 'UploadUserActivities'; Type = 'DWord'; Value = 0; Group = 'Cloud' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name = 'AllowCrossDeviceClipboard'; Type = 'DWord'; Value = 0; Group = 'Cloud' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds'; Name = 'EnableFeeds'; Type = 'DWord'; Value = 0; Group = 'NewsWeather' },
    [pscustomobject]@{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Feeds'; Name = 'ShellFeedsTaskbarViewMode'; Type = 'DWord'; Value = 2; Group = 'NewsWeather' },

    # Disable the per-user notification master switch, application/lock-screen
    # toast policy, Action Center UI, and Windows Security notifications. These
    # values are preserved in the exact rollback baseline and reasserted for
    # the saved clone user by the short-lived SYSTEM enforcement task.
    [pscustomobject]@{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\PushNotifications'; Name = 'ToastEnabled'; Type = 'DWord'; Value = 0; Group = 'Notifications' },
    [pscustomobject]@{ Path = 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\PushNotifications'; Name = 'NoToastApplicationNotification'; Type = 'DWord'; Value = 1; Group = 'Notifications' },
    [pscustomobject]@{ Path = 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\PushNotifications'; Name = 'NoToastApplicationNotificationOnLockScreen'; Type = 'DWord'; Value = 1; Group = 'Notifications' },
    [pscustomobject]@{ Path = 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\Explorer'; Name = 'DisableNotificationCenter'; Type = 'DWord'; Value = 1; Group = 'Notifications' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center\Notifications'; Name = 'DisableNotifications'; Type = 'DWord'; Value = 1; Group = 'Notifications' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center\Notifications'; Name = 'DisableEnhancedNotifications'; Type = 'DWord'; Value = 1; Group = 'Notifications' },

    # This is the value managed by Set-WinDefaultInputMethodOverride. It makes
    # the plain en-US US keyboard the default without deleting Chinese or any
    # other installed language/input method, so Win+Space remains available.
    [pscustomobject]@{ Path = 'HKCU:\Control Panel\International\User Profile'; Name = 'InputMethodOverride'; Type = 'String'; Value = '0409:00000409'; Group = 'Input' },

    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Name = 'AllowTelemetry'; Type = 'DWord'; Value = 0; Group = 'Privacy' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableWindowsConsumerFeatures'; Type = 'DWord'; Value = 1; Group = 'Privacy' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableTailoredExperiencesWithDiagnosticData'; Type = 'DWord'; Value = 1; Group = 'Privacy' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableWindowsSpotlightFeatures'; Type = 'DWord'; Value = 1; Group = 'Privacy' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableThirdPartySuggestions'; Type = 'DWord'; Value = 1; Group = 'Privacy' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableSoftLanding'; Type = 'DWord'; Value = 1; Group = 'Privacy' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableCloudOptimizedContent'; Type = 'DWord'; Value = 1; Group = 'Privacy' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name = 'AllowCortana'; Type = 'DWord'; Value = 0; Group = 'Privacy' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name = 'DisableWebSearch'; Type = 'DWord'; Value = 1; Group = 'Privacy' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name = 'AllowCloudSearch'; Type = 'DWord'; Value = 0; Group = 'Privacy' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'; Name = 'LetAppsRunInBackground'; Type = 'DWord'; Value = 2; Group = 'Background' },
    [pscustomobject]@{ Path = 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\Explorer'; Name = 'DisableSearchBoxSuggestions'; Type = 'DWord'; Value = 1; Group = 'Privacy' },
    [pscustomobject]@{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search'; Name = 'SearchboxTaskbarMode'; Type = 'DWord'; Value = 0; Group = 'Taskbar' },
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
    [pscustomobject]@{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications'; Name = 'GlobalUserDisabled'; Type = 'DWord'; Value = 1; Group = 'Background' },
    [pscustomobject]@{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search'; Name = 'BackgroundAppGlobalToggle'; Type = 'DWord'; Value = 0; Group = 'Background' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting'; Name = 'Disabled'; Type = 'DWord'; Value = 1; Group = 'Privacy' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR'; Name = 'AllowGameDVR'; Type = 'DWord'; Value = 0; Group = 'Gaming' },
    [pscustomobject]@{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR'; Name = 'AppCaptureEnabled'; Type = 'DWord'; Value = 0; Group = 'Gaming' },
    [pscustomobject]@{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR'; Name = 'HistoricalCaptureEnabled'; Type = 'DWord'; Value = 0; Group = 'Gaming' },
    [pscustomobject]@{ Path = 'HKCU:\System\GameConfigStore'; Name = 'GameDVR_Enabled'; Type = 'DWord'; Value = 0; Group = 'Gaming' },
    [pscustomobject]@{ Path = 'HKCU:\SOFTWARE\Microsoft\GameBar'; Name = 'AllowAutoGameMode'; Type = 'DWord'; Value = 1; Group = 'Gaming' },
    [pscustomobject]@{ Path = 'HKCU:\SOFTWARE\Microsoft\GameBar'; Name = 'AutoGameModeEnabled'; Type = 'DWord'; Value = 1; Group = 'Gaming' },

    # IFEO PerfOptions is a Windows process-creation setting, not a debugger.
    # Exact DNF image names only; High=3. Realtime priority is never requested.
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\DNF.exe\PerfOptions'; Name = 'CpuPriorityClass'; Type = 'DWord'; Value = 3; Group = 'DNF' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\DNFClient.exe\PerfOptions'; Name = 'CpuPriorityClass'; Type = 'DWord'; Value = 3; Group = 'DNF' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\DNFChina.exe\PerfOptions'; Name = 'CpuPriorityClass'; Type = 'DWord'; Value = 3; Group = 'DNF' },
    [pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\DNFLauncher.exe\PerfOptions'; Name = 'CpuPriorityClass'; Type = 'DWord'; Value = 3; Group = 'DNF' },

    [pscustomobject]@{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling'; Name = 'PowerThrottlingOff'; Type = 'DWord'; Value = 1; Group = 'Performance' },
    [pscustomobject]@{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Serialize'; Name = 'StartupDelayInMSec'; Type = 'DWord'; Value = 0; Group = 'Performance' },
    [pscustomobject]@{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'TaskbarAnimations'; Type = 'DWord'; Value = 0; Group = 'Performance' },
    [pscustomobject]@{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Name = 'EnableTransparency'; Type = 'DWord'; Value = 0; Group = 'Performance' },
    [pscustomobject]@{ Path = 'HKCU:\Control Panel\Desktop'; Name = 'MenuShowDelay'; Type = 'String'; Value = '0'; Group = 'Performance' }
)

# Values in this list are removed, not blanked, and use the same exact
# snapshot/rollback machinery as set-valued policy entries.
$RegistryRemovePlan = @(
    [pscustomobject]@{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Name = 'OneDrive'; Group = 'Cloud' }
)

# Earlier releases selected the global "best performance" visual-effects
# preset. That preset can hide the desktop background and disable font
# smoothing, so 2.2 retires it and restores the original per-user value from
# the first rollback baseline. Keep it allowlisted only for safe restoration.
$RetiredRegistryPlan = @(
    [pscustomobject]@{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'; Name = 'VisualFXSetting'; Group = 'PreservedAppearance' }
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

# Exact service names only. BFE and the rest of core networking, audio,
# printing, BITS, cryptography, AppX infrastructure, and NVIDIA services remain
# untouched. MpsSvc is the one explicit firewall exception requested for the
# controlled VM: profiles are disabled first, then its startup is disabled.
# Missing services are harmless and are reported as such.
$ServicePlan = @(
    [pscustomobject]@{ Name = 'MpsSvc'; Group = 'Firewall'; Purpose = 'Windows Defender Firewall startup and runtime' },
    [pscustomobject]@{ Name = 'wuauserv'; Group = 'WindowsUpdate'; Purpose = 'Windows Update' },
    [pscustomobject]@{ Name = 'UsoSvc'; Group = 'WindowsUpdate'; Purpose = 'Update Orchestrator' },
    # DoSvc is protected on current Windows builds. Windows Update is blocked
    # by policy and wuauserv/UsoSvc, while Delivery Optimization peer traffic
    # is disabled by DODownloadMode. A resident DoSvc is therefore inert and
    # is reported without turning a supported-access denial into Apply failure.
    [pscustomobject]@{ Name = 'DoSvc'; Group = 'WindowsUpdate'; Purpose = 'Delivery Optimization (protected/inert)'; Required = $false },
    [pscustomobject]@{ Name = 'uhssvc'; Group = 'WindowsUpdate'; Purpose = 'Microsoft Update Health Service' },
    [pscustomobject]@{ Name = 'InstallService'; Group = 'Store'; Purpose = 'Microsoft Store Install Service' },
    [pscustomobject]@{ Name = 'PushToInstall'; Group = 'Store'; Purpose = 'Windows PushToInstall' },
    [pscustomobject]@{ Name = 'edgeupdate'; Group = 'SoftwareUpdate'; Purpose = 'Microsoft Edge Update' },
    [pscustomobject]@{ Name = 'edgeupdatem'; Group = 'SoftwareUpdate'; Purpose = 'Microsoft Edge Update on demand' },
    [pscustomobject]@{ Name = 'MicrosoftEdgeElevationService'; Group = 'SoftwareUpdate'; Purpose = 'Microsoft Edge elevation/update helper' },
    [pscustomobject]@{ Name = 'gupdate'; Group = 'SoftwareUpdate'; Purpose = 'Google Update' },
    [pscustomobject]@{ Name = 'gupdatem'; Group = 'SoftwareUpdate'; Purpose = 'Google Update on demand' },
    [pscustomobject]@{ Name = 'AdobeARMservice'; Group = 'SoftwareUpdate'; Purpose = 'Adobe Acrobat Update' },
    [pscustomobject]@{ Name = 'MozillaMaintenance'; Group = 'SoftwareUpdate'; Purpose = 'Mozilla Maintenance/Update' },
    [pscustomobject]@{ Name = 'SysMain'; Group = 'Performance'; Purpose = 'SysMain prefetch background I/O' },
    [pscustomobject]@{ Name = 'WSearch'; Group = 'Performance'; Purpose = 'Windows Search indexing' },
    [pscustomobject]@{ Name = 'CDPSvc'; Group = 'Optional'; Purpose = 'Connected Devices Platform' },
    [pscustomobject]@{ Name = 'DusmSvc'; Group = 'Optional'; Purpose = 'Data Usage collection' },
    [pscustomobject]@{ Name = 'WpnService'; Group = 'Optional'; Purpose = 'Windows push notifications' },
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
    [pscustomobject]@{ Name = 'RemoteRegistry'; Group = 'Optional'; Purpose = 'Remote Registry' },
    [pscustomobject]@{ Name = 'diagnosticshub.standardcollector.service'; Group = 'Optional'; Purpose = 'Diagnostics Hub collector' },
    [pscustomobject]@{ Name = 'TrkWks'; Group = 'Optional'; Purpose = 'Distributed Link Tracking' },
    [pscustomobject]@{ Name = 'WbioSrvc'; Group = 'Optional'; Purpose = 'Windows biometric service' },
    [pscustomobject]@{ Name = 'icssvc'; Group = 'Optional'; Purpose = 'Mobile hotspot service' },
    [pscustomobject]@{ Name = 'AJRouter'; Group = 'Optional'; Purpose = 'AllJoyn router' },
    [pscustomobject]@{ Name = 'SharedRealitySvc'; Group = 'Optional'; Purpose = 'Spatial data service' }
)

# Newer vendor updater services have versioned names. Discovery is constrained
# to these anchored allowlist patterns; arbitrary "update" services are never
# touched.
$ServicePatternPlan = @(
    [pscustomobject]@{ Pattern = '^GoogleUpdater(?:Internal)?Service[0-9._-]+$'; Group = 'SoftwareUpdate'; Purpose = 'Google Updater versioned service' },
    [pscustomobject]@{ Pattern = '^OneDriveUpdaterService[0-9A-Za-z._-]*$'; Group = 'Cloud'; Purpose = 'OneDrive updater service' }
)

$TaskPlan = @(
    [pscustomobject]@{ Path = '\Microsoft\Windows\Windows Defender\'; Name = 'Windows Defender Cache Maintenance'; Group = 'Defender' },
    [pscustomobject]@{ Path = '\Microsoft\Windows\Windows Defender\'; Name = 'Windows Defender Cleanup'; Group = 'Defender' },
    [pscustomobject]@{ Path = '\Microsoft\Windows\Windows Defender\'; Name = 'Windows Defender Scheduled Scan'; Group = 'Defender' },
    [pscustomobject]@{ Path = '\Microsoft\Windows\Windows Defender\'; Name = 'Windows Defender Verification'; Group = 'Defender' },
    [pscustomobject]@{ Path = '\Microsoft\Windows\UpdateOrchestrator\'; Name = 'Schedule Scan'; Group = 'WindowsUpdate'; Required = $false },
    [pscustomobject]@{ Path = '\Microsoft\Windows\UpdateOrchestrator\'; Name = 'Schedule Scan Static Task'; Group = 'WindowsUpdate'; Required = $false },
    [pscustomobject]@{ Path = '\Microsoft\Windows\UpdateOrchestrator\'; Name = 'USO_UxBroker'; Group = 'WindowsUpdate'; Required = $false },
    [pscustomobject]@{ Path = '\Microsoft\Windows\UpdateOrchestrator\'; Name = 'UpdateModelTask'; Group = 'WindowsUpdate'; Required = $false },
    [pscustomobject]@{ Path = '\Microsoft\Windows\UpdateOrchestrator\'; Name = 'Maintenance Install'; Group = 'WindowsUpdate'; Required = $false },
    [pscustomobject]@{ Path = '\Microsoft\Windows\WindowsUpdate\'; Name = 'Scheduled Start'; Group = 'WindowsUpdate'; Required = $false },
    [pscustomobject]@{ Path = '\Microsoft\Windows\WindowsUpdate\'; Name = 'sih'; Group = 'WindowsUpdate'; Required = $false },
    [pscustomobject]@{ Path = '\Microsoft\Windows\WindowsUpdate\'; Name = 'sihboot'; Group = 'WindowsUpdate'; Required = $false },
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
    [pscustomobject]@{ Path = '\Microsoft\Windows\Windows Error Reporting\'; Name = 'QueueReporting'; Group = 'Optional' },
    [pscustomobject]@{ Path = '\Microsoft\Office\'; Name = 'Office Automatic Updates 2.0'; Group = 'SoftwareUpdate' },
    [pscustomobject]@{ Path = '\Microsoft\Office\'; Name = 'Office Feature Updates'; Group = 'SoftwareUpdate' },
    [pscustomobject]@{ Path = '\Microsoft\Office\'; Name = 'Office Feature Updates Logon'; Group = 'SoftwareUpdate' },
    [pscustomobject]@{ Path = '\'; Name = 'Adobe Acrobat Update Task'; Group = 'SoftwareUpdate' }
)

# Folder/name discovery covers version-dependent task names while remaining a
# strict allowlist. Every discovered task is persisted before it is changed.
$TaskPatternPlan = @(
    [pscustomobject]@{ PathPattern = '^\\Microsoft\\Windows\\Windows Defender\\$'; NamePattern = '^.+$'; Group = 'Defender' },
    [pscustomobject]@{ PathPattern = '^\\Microsoft\\Windows\\UpdateOrchestrator\\$'; NamePattern = '^.+$'; Group = 'WindowsUpdate'; Required = $false },
    [pscustomobject]@{ PathPattern = '^\\Microsoft\\Windows\\WindowsUpdate\\$'; NamePattern = '^.+$'; Group = 'WindowsUpdate'; Required = $false },
    [pscustomobject]@{ PathPattern = '^\\Microsoft\\Windows\\WaaSMedic\\$'; NamePattern = '^.+$'; Group = 'WindowsUpdate'; Required = $false },
    [pscustomobject]@{ PathPattern = '^\\Microsoft\\Windows\\InstallService\\$'; NamePattern = '^.+$'; Group = 'Store' },
    [pscustomobject]@{ PathPattern = '^\\Microsoft\\Windows\\PushToInstall\\$'; NamePattern = '^.+$'; Group = 'Store' },
    [pscustomobject]@{ PathPattern = '^\\Microsoft\\EdgeUpdate\\$'; NamePattern = '^MicrosoftEdgeUpdateTask.+$'; Group = 'SoftwareUpdate' },
    [pscustomobject]@{ PathPattern = '^\\Microsoft\\Office\\$'; NamePattern = '^Office (?:Automatic Updates|Feature Updates).*$'; Group = 'SoftwareUpdate' },
    [pscustomobject]@{ PathPattern = '^\\GoogleSystem\\GoogleUpdater\\$'; NamePattern = '^GoogleUpdaterTask.+$'; Group = 'SoftwareUpdate' },
    [pscustomobject]@{ PathPattern = '^\\$'; NamePattern = '^GoogleUpdateTaskMachine.+$'; Group = 'SoftwareUpdate' },
    [pscustomobject]@{ PathPattern = '^\\$'; NamePattern = '^Adobe Acrobat Update Task$'; Group = 'SoftwareUpdate' },
    [pscustomobject]@{ PathPattern = '^\\$'; NamePattern = '^OneDrive (?:Standalone Update|Reporting) Task.*$'; Group = 'Cloud' }
)

# These are package identity names, never wildcard patterns. Provisioned
# packages are deliberately retained so rollback can re-register staged bits.
$AppPlan = @(
    'Microsoft.BingNews',
    'Microsoft.BingWeather',
    'Microsoft.BingSearch',
    'Microsoft.Copilot',
    'Microsoft.GetHelp',
    'Microsoft.Getstarted',
    'Microsoft.GamingApp',
    'Microsoft.Messaging',
    'Microsoft.Microsoft3DViewer',
    'Microsoft.MicrosoftOfficeHub',
    'Microsoft.MicrosoftSolitaireCollection',
    'Microsoft.MixedReality.Portal',
    'Microsoft.Office.OneNote',
    'Microsoft.OneConnect',
    'Microsoft.OneDriveSync',
    'Microsoft.People',
    'Microsoft.Print3D',
    'Microsoft.SkypeApp',
    'Microsoft.Todos',
    'Microsoft.Wallet',
    'Microsoft.WindowsAlarms',
    'Microsoft.WindowsCamera',
    'microsoft.windowscommunicationsapps',
    'Microsoft.Windows.DevHome',
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
    'Microsoft.OutlookForWindows',
    'Microsoft.PowerAutomateDesktop',
    'MicrosoftCorporationII.MicrosoftFamily',
    'MicrosoftCorporationII.QuickAssist',
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

# Process names are exact executable base names. They are stopped only after
# the corresponding policy/service/task/app controls have been applied.
$ProcessPlan = @(
    [pscustomobject]@{ Name = 'OneDrive'; Group = 'Cloud'; Purpose = 'OneDrive sync client' },
    [pscustomobject]@{ Name = 'MicrosoftEdgeUpdate'; Group = 'SoftwareUpdate'; Purpose = 'Microsoft Edge updater' },
    [pscustomobject]@{ Name = 'GoogleUpdate'; Group = 'SoftwareUpdate'; Purpose = 'Google updater' },
    [pscustomobject]@{ Name = 'GoogleUpdater'; Group = 'SoftwareUpdate'; Purpose = 'Google updater' },
    [pscustomobject]@{ Name = 'AdobeARM'; Group = 'SoftwareUpdate'; Purpose = 'Adobe updater' },
    [pscustomobject]@{ Name = 'SearchIndexer'; Group = 'Performance'; Purpose = 'Windows Search indexer' },
    [pscustomobject]@{ Name = 'GameBar'; Group = 'Gaming'; Purpose = 'Xbox Game Bar' },
    [pscustomobject]@{ Name = 'GameBarFTServer'; Group = 'Gaming'; Purpose = 'Xbox Game Bar server' },
    [pscustomobject]@{ Name = 'XboxGameBarWidgets'; Group = 'Gaming'; Purpose = 'Xbox Game Bar widgets' },
    [pscustomobject]@{ Name = 'Teams'; Group = 'ConsumerApp'; Purpose = 'classic Teams background client' },
    [pscustomobject]@{ Name = 'ms-teams'; Group = 'ConsumerApp'; Purpose = 'new Teams background client' },
    [pscustomobject]@{ Name = 'msteams'; Group = 'ConsumerApp'; Purpose = 'Teams Appx background client' },
    [pscustomobject]@{ Name = 'Widgets'; Group = 'ConsumerApp'; Purpose = 'Windows widgets background host' },
    [pscustomobject]@{ Name = 'WidgetService'; Group = 'ConsumerApp'; Purpose = 'Windows widgets service process' },
    [pscustomobject]@{ Name = 'YourPhone'; Group = 'Cloud'; Purpose = 'Phone Link' },
    [pscustomobject]@{ Name = 'PhoneExperienceHost'; Group = 'Cloud'; Purpose = 'Phone Link host' },
    [pscustomobject]@{ Name = 'HxTsr'; Group = 'Cloud'; Purpose = 'Mail and Calendar background host' },
    [pscustomobject]@{ Name = 'Video.UI'; Group = 'ConsumerApp'; Purpose = 'Movies and TV background host' }
)

# Only these exact DNF process base names may receive High priority. This list
# is deliberately separate from the background-process termination plan.
$DnfProcessPlan = @(
    [pscustomobject]@{ Name = 'DNF'; Image = 'DNF.exe' },
    [pscustomobject]@{ Name = 'DNFClient'; Image = 'DNFClient.exe' },
    [pscustomobject]@{ Name = 'DNFChina'; Image = 'DNFChina.exe' },
    [pscustomobject]@{ Name = 'DNFLauncher'; Image = 'DNFLauncher.exe' }
)

$HighPerformanceScheme = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'

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

function Get-AllRegistryPlans {
    return @($RegistryPlan) + @($RegistryRemovePlan) + @($RetiredRegistryPlan)
}

function Test-PlanRequired {
    param([Parameter(Mandatory = $true)][object]$Plan)

    $property = $Plan.PSObject.Properties['Required']
    return $null -eq $property -or [bool]$property.Value
}

function Test-RegistryTargetAllowed {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    foreach ($entry in @(Get-AllRegistryPlans)) {
        if ([string]$entry.Path -ieq $Path -and
            [string]$entry.Name -ieq $Name) { return $true }
    }
    return $false
}

function Test-RegistryValueMatches {
    param(
        [AllowNull()][object]$Actual,
        [AllowNull()][object]$Desired,
        [Parameter(Mandatory = $true)][string]$Type
    )

    switch ($Type) {
        'DWord' { return [int64]$Actual -eq [int64]$Desired }
        'QWord' { return [uint64]$Actual -eq [uint64]$Desired }
        'String' { return [string]$Actual -ceq [string]$Desired }
        'ExpandString' { return [string]$Actual -ceq [string]$Desired }
        default { return $Actual -eq $Desired }
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

function Ensure-RegistryKey {
    param([Parameter(Mandatory = $true)][string]$Path)

    # Windows PowerShell 5.1's Registry provider can recreate an existing leaf
    # key when New-Item -Force is called, deleting sibling values already set
    # during this same profile pass. VM1 exposed the exact symptom: only the
    # last planned value under each key survived. Create only absent keys.
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
    }
}

function Set-PlannedRegistryValue {
    param([Parameter(Mandatory = $true)][object]$Entry)

    Ensure-RegistryKey -Path ([string]$Entry.Path)
    New-ItemProperty -Path $Entry.Path -Name $Entry.Name `
        -PropertyType $Entry.Type -Value $Entry.Value -Force | Out-Null
    Write-Host "  policy: $($Entry.Path)\$($Entry.Name)=$($Entry.Value)" `
        -ForegroundColor DarkGray
}

function Remove-PlannedRegistryValue {
    param([Parameter(Mandatory = $true)][object]$Entry)

    Remove-ItemProperty -LiteralPath $Entry.Path -Name $Entry.Name `
        -ErrorAction SilentlyContinue
    Write-Host "  startup disabled: $($Entry.Path)\$($Entry.Name)" `
        -ForegroundColor DarkGray
}

function Restore-RegistrySnapshot {
    param([Parameter(Mandatory = $true)][object]$Snapshot)

    if (-not (Test-RegistryTargetAllowed -Path ([string]$Snapshot.Path) `
        -Name ([string]$Snapshot.Name))) {
        throw "State contains an unexpected registry target: $($Snapshot.Path)\$($Snapshot.Name)"
    }
    if ([bool]$Snapshot.ValueExisted) {
        Ensure-RegistryKey -Path ([string]$Snapshot.Path)
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

function Restore-RetiredRegistryValues {
    param([Parameter(Mandatory = $true)][object]$State)

    $failures = New-Object 'System.Collections.Generic.List[string]'
    foreach ($plan in $RetiredRegistryPlan) {
        $snapshot = @($State.Registry | Where-Object {
            [string]$_.Path -ieq [string]$plan.Path -and
            [string]$_.Name -ieq [string]$plan.Name
        }) | Select-Object -First 1
        if ($null -eq $snapshot) {
            $failures.Add("preserved appearance baseline is missing: $($plan.Path)\$($plan.Name)")
            continue
        }
        try {
            Restore-RegistrySnapshot $snapshot
            Write-Host "  preserved appearance restored: $($plan.Name)" `
                -ForegroundColor DarkGray
        } catch {
            $failures.Add("preserved appearance $($plan.Name): $($_.Exception.Message)")
        }
    }
    return $failures.ToArray()
}

function Get-PolicyFileSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$Scope,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $exists = Test-Path -LiteralPath $Path -PathType Leaf
    $bytes = [byte[]]@()
    if ($exists) {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Local policy file is a reparse point: $Path"
        }
        $bytes = [IO.File]::ReadAllBytes($Path)
    }
    return [pscustomobject]@{
        Scope = $Scope
        Path = $Path
        Existed = [bool]$exists
        Base64 = if ($exists) { [Convert]::ToBase64String($bytes) } else { '' }
    }
}

function Test-RegistryPolHeader {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    return $Bytes.Length -ge 8 -and
        $Bytes[0] -eq 0x50 -and $Bytes[1] -eq 0x52 -and
        $Bytes[2] -eq 0x65 -and $Bytes[3] -eq 0x67 -and
        [BitConverter]::ToUInt32($Bytes, 4) -eq 1
}

function Get-RegistryPolTypeCode {
    param([Parameter(Mandatory = $true)][string]$Type)

    switch ($Type) {
        'String' { return [uint32]1 }
        'ExpandString' { return [uint32]2 }
        'Binary' { return [uint32]3 }
        'DWord' { return [uint32]4 }
        'MultiString' { return [uint32]7 }
        'QWord' { return [uint32]11 }
        default { throw "Unsupported Registry.pol value type: $Type" }
    }
}

function Get-RegistryPolData {
    param([Parameter(Mandatory = $true)][object]$Entry)

    switch ([string]$Entry.Type) {
        'DWord' {
            return [BitConverter]::GetBytes([uint32][int64]$Entry.Value)
        }
        'QWord' {
            return [BitConverter]::GetBytes([uint64]$Entry.Value)
        }
        'String' {
            return [Text.Encoding]::Unicode.GetBytes(
                ([string]$Entry.Value) + [char]0
            )
        }
        'ExpandString' {
            return [Text.Encoding]::Unicode.GetBytes(
                ([string]$Entry.Value) + [char]0
            )
        }
        'Binary' { return [byte[]]$Entry.Value }
        'MultiString' {
            $text = ((@($Entry.Value) | ForEach-Object { [string]$_ }) -join `
                ([char]0)) + [char]0 + [char]0
            return [Text.Encoding]::Unicode.GetBytes($text)
        }
        default { throw "Unsupported Registry.pol value type: $($Entry.Type)" }
    }
}

function Write-BytesToStream {
    param(
        [Parameter(Mandatory = $true)][IO.MemoryStream]$Stream,
        [Parameter(Mandatory = $true)][byte[]]$Bytes
    )

    $Stream.Write($Bytes, 0, $Bytes.Length)
}

function Write-RegistryPolText {
    param(
        [Parameter(Mandatory = $true)][IO.MemoryStream]$Stream,
        [Parameter(Mandatory = $true)][string]$Text
    )

    Write-BytesToStream -Stream $Stream `
        -Bytes ([Text.Encoding]::Unicode.GetBytes($Text))
}

function New-ManagedRegistryPolBytes {
    param(
        [Parameter(Mandatory = $true)][object]$Snapshot,
        [Parameter(Mandatory = $true)][object[]]$Entries,
        [Parameter(Mandatory = $true)][string]$HivePrefix
    )

    [byte[]]$base = if ([bool]$Snapshot.Existed) {
        [Convert]::FromBase64String([string]$Snapshot.Base64)
    } else {
        [byte[]](0x50, 0x52, 0x65, 0x67, 1, 0, 0, 0)
    }
    if (-not (Test-RegistryPolHeader $base)) {
        throw "Original local policy file has an unsupported header: $($Snapshot.Path)"
    }

    $stream = New-Object IO.MemoryStream
    try {
        Write-BytesToStream -Stream $stream -Bytes $base
        foreach ($entry in $Entries) {
            $path = [string]$entry.Path
            if (-not $path.StartsWith($HivePrefix,
                    [StringComparison]::OrdinalIgnoreCase)) {
                throw "Registry.pol entry is outside ${HivePrefix}: $path"
            }
            $key = $path.Substring($HivePrefix.Length)
            [byte[]]$data = @(Get-RegistryPolData $entry)
            Write-RegistryPolText $stream '['
            # MS-GPREG 2.2.1 requires both the key and value-name fields to be
            # null-terminated UTF-16LE strings. The semicolon delimiters follow
            # those terminators; omitting either NUL makes LocalGPO reject the
            # complete registry policy file during gpupdate.
            Write-RegistryPolText $stream ($key + [char]0)
            Write-RegistryPolText $stream ';'
            Write-RegistryPolText $stream (([string]$entry.Name) + [char]0)
            Write-RegistryPolText $stream ';'
            Write-BytesToStream $stream `
                ([BitConverter]::GetBytes((Get-RegistryPolTypeCode `
                    ([string]$entry.Type))))
            Write-RegistryPolText $stream ';'
            Write-BytesToStream $stream `
                ([BitConverter]::GetBytes([uint32]$data.Length))
            Write-RegistryPolText $stream ';'
            Write-BytesToStream $stream $data
            Write-RegistryPolText $stream ']'
        }
        return $stream.ToArray()
    } finally {
        $stream.Dispose()
    }
}

function Write-PolicyFileAtomically {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][byte[]]$Bytes
    )

    $parent = Split-Path -Parent $Path
    New-Item -Path $parent -ItemType Directory -Force | Out-Null
    $parentItem = Get-Item -LiteralPath $parent -Force -ErrorAction Stop
    if (($parentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Local policy directory is a reparse point: $parent"
    }
    $temporary = Join-Path $parent `
        ('.Registry.pol.{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllBytes($temporary, $Bytes)
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    } finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
}

function Write-ManagedPolicyFiles {
    param([Parameter(Mandatory = $true)][object]$Snapshots)

    foreach ($configuration in @(
        [pscustomobject]@{
            Scope = 'Machine'; Path = $MachinePolicyPath; Prefix = 'HKLM:\'
        },
        [pscustomobject]@{
            Scope = 'User'; Path = $UserPolicyPath; Prefix = 'HKCU:\'
        }
    )) {
        $property = $Snapshots.PSObject.Properties[[string]$configuration.Scope]
        if ($null -eq $property) {
            throw "Rollback state lacks the $($configuration.Scope) policy snapshot."
        }
        $snapshot = $property.Value
        if ([string]$snapshot.Path -ine [string]$configuration.Path) {
            throw "Unexpected local policy path in state: $($snapshot.Path)"
        }
        $entries = @($RegistryPlan | Where-Object {
            ([string]$_.Path).StartsWith(
                [string]$configuration.Prefix,
                [StringComparison]::OrdinalIgnoreCase
            )
        })
        [byte[]]$bytes = @(New-ManagedRegistryPolBytes `
            -Snapshot $snapshot -Entries $entries `
            -HivePrefix ([string]$configuration.Prefix))
        Write-PolicyFileAtomically -Path ([string]$configuration.Path) `
            -Bytes $bytes
        Write-Host "  local policy persisted: $($configuration.Scope) Registry.pol" `
            -ForegroundColor DarkGray
    }
}

function Get-NextLocalPolicyVersion {
    param([uint32]$CurrentVersion = 0)

    [uint32]$machineVersion = $CurrentVersion -band 0xffff
    [uint32]$userVersion = ($CurrentVersion -shr 16) -band 0xffff
    $machineVersion = ($machineVersion + 1) -band 0xffff
    $userVersion = ($userVersion + 1) -band 0xffff
    if ($machineVersion -eq 0) { $machineVersion = 1 }
    if ($userVersion -eq 0) { $userVersion = 1 }
    return [uint32](($userVersion -shl 16) -bor $machineVersion)
}

function New-ManagedPolicyMetadataBytes {
    param([Parameter(Mandatory = $true)][object]$Snapshot)

    if ([string]$Snapshot.Path -ine $PolicyMetadataPath) {
        throw "Unexpected local policy metadata path in state: $($Snapshot.Path)"
    }
    $text = ''
    if ([bool]$Snapshot.Existed) {
        [byte[]]$base = [Convert]::FromBase64String([string]$Snapshot.Base64)
        if ($base.Count -gt 0 -and
            [Array]::IndexOf($base, [byte]0) -ge 0) {
            throw "Local policy metadata is not an ANSI gpt.ini file: $PolicyMetadataPath"
        }
        if ($base.Count -gt 0) {
            $text = [Text.Encoding]::Default.GetString($base)
        }
    }
    $lines = New-Object 'System.Collections.Generic.List[string]'
    if (-not [string]::IsNullOrEmpty($text)) {
        foreach ($line in @($text -split '\r\n|\n|\r')) { $lines.Add($line) }
        while ($lines.Count -gt 0 -and
            [string]::IsNullOrEmpty($lines[$lines.Count - 1])) {
            $lines.RemoveAt($lines.Count - 1)
        }
    }

    $generalStart = -1
    $generalEnd = $lines.Count
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match '^\s*\[General\]\s*$') {
            $generalStart = $index
            for ($next = $index + 1; $next -lt $lines.Count; $next++) {
                if ($lines[$next] -match '^\s*\[[^]]+\]\s*$') {
                    $generalEnd = $next
                    break
                }
            }
            break
        }
    }
    if ($generalStart -lt 0) {
        if ($lines.Count -gt 0 -and
            -not [string]::IsNullOrWhiteSpace($lines[$lines.Count - 1])) {
            $lines.Add('')
        }
        $generalStart = $lines.Count
        $lines.Add('[General]')
        $generalEnd = $lines.Count
    }

    [uint32]$currentVersion = 0
    for ($index = $generalStart + 1; $index -lt $generalEnd; $index++) {
        if ($lines[$index] -notmatch '^\s*([^=]+?)\s*=(.*)$') { continue }
        $key = [string]$matches[1]
        $value = [string]$matches[2]
        switch -Regex ($key) {
            '^(?i:Version)$' {
                [uint32]$parsed = 0
                if ([uint32]::TryParse($value.Trim(), [ref]$parsed)) {
                    $currentVersion = $parsed
                }
            }
        }
    }

    $desired = @{
        Version = [string](Get-NextLocalPolicyVersion $currentVersion)
    }
    $desiredOrder = @('Version')
    # gPCMachineExtensionNames/gPCUserExtensionNames are Active Directory GPO
    # object attributes, not valid gpt.ini keys. Guest Lite 2.2 briefly wrote
    # them here; Windows then ignored the local GPO after reboot even though
    # gpupdate returned success. Remove only those retired managed-copy keys;
    # rollback still restores the original gpt.ini byte-for-byte.
    $retiredKeys = @(
        'gPCMachineExtensionNames', 'gPCUserExtensionNames'
    )
    $written = @{}
    $output = New-Object 'System.Collections.Generic.List[string]'
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($index -eq $generalEnd) {
            foreach ($key in $desiredOrder) {
                if (-not $written.ContainsKey($key)) {
                    $output.Add("$key=$($desired[$key])")
                    $written[$key] = $true
                }
            }
        }
        $line = $lines[$index]
        if ($index -gt $generalStart -and $index -lt $generalEnd -and
            $line -match '^\s*([^=]+?)\s*=') {
            $key = [string]$matches[1]
            if ($retiredKeys -icontains $key) { continue }
            if ($desired.ContainsKey($key)) {
                if (-not $written.ContainsKey($key)) {
                    $output.Add("$key=$($desired[$key])")
                    $written[$key] = $true
                }
                continue
            }
        }
        $output.Add($line)
    }
    foreach ($key in $desiredOrder) {
        if (-not $written.ContainsKey($key)) {
            $output.Add("$key=$($desired[$key])")
        }
    }
    $managedText = ($output.ToArray() -join "`r`n") + "`r`n"
    return [Text.Encoding]::Default.GetBytes($managedText)
}

function Write-ManagedPolicyMetadata {
    param([Parameter(Mandatory = $true)][object]$Snapshot)

    [byte[]]$bytes = @(New-ManagedPolicyMetadataBytes -Snapshot $Snapshot)
    Write-PolicyFileAtomically -Path $PolicyMetadataPath -Bytes $bytes
    Write-Host '  local policy metadata persisted: gpt.ini' `
        -ForegroundColor DarkGray
}

function Refresh-LocalPolicy {
    $failures = New-Object 'System.Collections.Generic.List[string]'
    try {
        & gpupdate.exe /force /wait:60 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $failures.Add("local policy refresh: gpupdate returned $LASTEXITCODE")
        } else {
            Write-Host '  local policy refresh completed' -ForegroundColor DarkGray
        }
    } catch {
        $failures.Add("local policy refresh: $($_.Exception.Message)")
    }
    return $failures.ToArray()
}

function Restore-PolicyFileSnapshots {
    param([AllowNull()][object]$Snapshots)

    $failures = New-Object 'System.Collections.Generic.List[string]'
    if ($null -eq $Snapshots) {
        return $failures.ToArray()
    }
    foreach ($configuration in @(
        [pscustomobject]@{ Scope = 'Machine'; Path = $MachinePolicyPath },
        [pscustomobject]@{ Scope = 'User'; Path = $UserPolicyPath },
        [pscustomobject]@{ Scope = 'Metadata'; Path = $PolicyMetadataPath }
    )) {
        try {
            $property = $Snapshots.PSObject.Properties[[string]$configuration.Scope]
            if ($null -eq $property) {
                throw "missing $($configuration.Scope) snapshot"
            }
            $snapshot = $property.Value
            if ([string]$snapshot.Path -ine [string]$configuration.Path) {
                throw "unexpected path '$($snapshot.Path)'"
            }
            if ([bool]$snapshot.Existed) {
                [byte[]]$bytes = [Convert]::FromBase64String(
                    [string]$snapshot.Base64
                )
                Write-PolicyFileAtomically -Path ([string]$configuration.Path) `
                    -Bytes $bytes
            } else {
                Remove-Item -LiteralPath ([string]$configuration.Path) `
                    -Force -ErrorAction SilentlyContinue
            }
        } catch {
            $failures.Add("local policy rollback $($configuration.Scope): $($_.Exception.Message)")
        }
    }
    return $failures.ToArray()
}

function Get-EnforcementTaskSnapshot {
    $task = Get-ScheduledTask -TaskPath $EnforcementTaskPath `
        -TaskName $EnforcementTaskName -ErrorAction SilentlyContinue | `
        Select-Object -First 1
    $taskState = ''
    $lastRunTime = ''
    $lastTaskResult = ''
    if ($null -ne $task) {
        $taskState = [string]$task.State
        try {
            $taskInfo = Get-ScheduledTaskInfo -TaskPath $EnforcementTaskPath `
                -TaskName $EnforcementTaskName -ErrorAction Stop
            if ($taskInfo.LastRunTime.Year -gt 1900) {
                $lastRunTime = $taskInfo.LastRunTime.ToString('o')
            }
            $lastTaskResult = [string]([int64]$taskInfo.LastTaskResult)
        } catch { }
    }
    return [pscustomobject]@{
        Path = $EnforcementTaskPath
        Name = $EnforcementTaskName
        Existed = [bool]($null -ne $task)
        Enabled = [bool]($null -ne $task -and $task.Settings.Enabled)
        State = $taskState
        LastRunTime = $lastRunTime
        LastTaskResult = $lastTaskResult
    }
}

function Register-EnforcementTask {
    param([Parameter(Mandatory = $true)][object]$State)

    $baselineProperty = $State.PSObject.Properties['EnforcementTask']
    if ($null -eq $baselineProperty) {
        throw 'Rollback state lacks the enforcement-task baseline.'
    }
    if ([bool]$baselineProperty.Value.Existed) {
        throw "A pre-existing scheduled task conflicts with $EnforcementTaskPath$EnforcementTaskName."
    }
    $script = Join-Path $ToolRoot 'G11-Guest-Lite.ps1'
    if (-not (Test-Path -LiteralPath $script -PathType Leaf)) {
        throw "Installed enforcement script is missing: $script"
    }
    $powerShell = Join-Path $env:SystemRoot `
        'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Mode Enforce -UserSid "{1}"' -f `
        $script.Replace('"', '""'), [string]$State.UserSid
    $action = New-ScheduledTaskAction -Execute $powerShell `
        -Argument $arguments -WorkingDirectory $ToolRoot
    $startup = New-ScheduledTaskTrigger -AtStartup
    $startup.Delay = 'PT45S'
    # A local account name is prefixed by the computer name and becomes stale
    # after an otherwise harmless Windows rename. The SID is stable across a
    # rename and Task Scheduler accepts it as the logon-trigger identity.
    $logon = New-ScheduledTaskTrigger -AtLogOn -User ([string]$State.UserSid)
    $logon.Delay = 'PT45S'
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' `
        -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    Register-ScheduledTask -TaskPath $EnforcementTaskPath `
        -TaskName $EnforcementTaskName -Action $action `
        -Trigger @($startup, $logon) -Principal $principal `
        -Settings $settings -Force | Out-Null
    Write-Host "  startup/logon enforcement task installed: $EnforcementTaskPath$EnforcementTaskName" `
        -ForegroundColor DarkGray
}

function Remove-EnforcementTask {
    param([AllowNull()][object]$Baseline)

    if ($null -eq $Baseline) { return }
    if ([string]$Baseline.Path -ine $EnforcementTaskPath -or
        [string]$Baseline.Name -ine $EnforcementTaskName) {
        throw 'Rollback state contains an unexpected enforcement task.'
    }
    if ([bool]$Baseline.Existed) {
        throw 'The enforcement task existed before Apply and was not owned by Guest Lite.'
    }
    Unregister-ScheduledTask -TaskPath $EnforcementTaskPath `
        -TaskName $EnforcementTaskName -Confirm:$false `
        -ErrorAction SilentlyContinue
}

function Read-EnforcementState {
    param([Parameter(Mandatory = $true)][string]$ExpectedUserSid)

    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if ($currentSid -ne 'S-1-5-18') {
        throw 'Enforce mode may run only as Local System from the installed task.'
    }
    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
        throw "No applied-state file exists: $StatePath"
    }
    $state = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | `
        ConvertFrom-Json
    if ([int]$state.SchemaVersion -lt $MinimumSchemaVersion -or
        [int]$state.SchemaVersion -gt $SchemaVersion) {
        throw "Unsupported state schema '$($state.SchemaVersion)'."
    }
    if ([string]$state.UserSid -ne $ExpectedUserSid) {
        throw "Enforcement SID '$ExpectedUserSid' does not match saved SID '$($state.UserSid)'."
    }
    $accounts = @(Get-CimInstance Win32_UserAccount `
        -Filter "SID='$ExpectedUserSid'" -ErrorAction Stop | Where-Object {
            [bool]$_.LocalAccount
        })
    if ($accounts.Count -ne 1) {
        throw "Saved enforcement SID is not one local Windows account: $ExpectedUserSid"
    }
    if (-not (Test-StateMachineGuid $state)) {
        throw 'Rollback state lacks its stable MachineGuid binding. Run Apply once to upgrade the baseline.'
    }
    return $state
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
    # Once native policy has made every effective protection field false,
    # newer Defender platforms can leave the protected WinDefend/MsMpEng shell
    # resident while rejecting Set-MpPreference with 0x800106ba. Repeating the
    # calls adds no protection change and makes a healthy boot task look failed.
    # Judge this fast path from the same effective fields used by Audit.
    try {
        $effective = Get-MpComputerStatus -ErrorAction Stop
        $effectiveNames = @(
            'RealTimeProtectionEnabled', 'BehaviorMonitorEnabled',
            'IoavProtectionEnabled', 'OnAccessProtectionEnabled', 'NISEnabled'
        )
        $allAvailable = $true
        $anyEnabled = $false
        foreach ($name in $effectiveNames) {
            $property = $effective.PSObject.Properties[$name]
            if ($null -eq $property) {
                $allAvailable = $false
                break
            }
            if ([bool]$property.Value) { $anyEnabled = $true }
        }
        if ($allAvailable -and -not $anyEnabled) {
            Write-Host '  Defender effective protections are already inactive; runtime calls skipped' `
                -ForegroundColor DarkGray
            return $failures.ToArray()
        }
    } catch { }
    $defenderService = Get-Service -Name WinDefend -ErrorAction SilentlyContinue
    $defenderEngineRunning = @(
        Get-Process -Name MsMpEng -ErrorAction SilentlyContinue
    ).Count -gt 0
    if ($null -ne $defenderService -and
        [string]$defenderService.Status -ne 'Running' -and
        -not $defenderEngineRunning) {
        Write-Host '  Defender engine is inactive; runtime preference calls are unnecessary' `
            -ForegroundColor DarkGray
        return $failures.ToArray()
    }
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

function Get-FirewallSnapshots {
    $result = New-Object 'System.Collections.Generic.List[object]'
    if ($null -eq (Get-Command Get-NetFirewallProfile `
        -ErrorAction SilentlyContinue)) {
        return $result.ToArray()
    }
    try {
        foreach ($profile in @(Get-NetFirewallProfile -ErrorAction Stop)) {
            if (@('Domain', 'Private', 'Public') -notcontains `
                [string]$profile.Name) { continue }
            $result.Add([pscustomobject]@{
                Name = [string]$profile.Name
                Enabled = [string]$profile.Enabled
            })
        }
    } catch {
        # NetSecurity can become unavailable after MpsSvc has been stopped.
        # The service startup/state is audited independently below.
        return $result.ToArray()
    }
    return $result.ToArray()
}

function Disable-FirewallProfiles {
    $failures = New-Object 'System.Collections.Generic.List[string]'
    $firewallService = Get-CimInstance Win32_Service `
        -Filter "Name='$FirewallServiceName'" -ErrorAction SilentlyContinue
    if ($null -ne $firewallService -and
        [string]$firewallService.StartMode -eq 'Disabled') {
        Write-Host '  Windows Firewall profiles inactive: MpsSvc startup is disabled' `
            -ForegroundColor DarkGray
        return $failures.ToArray()
    }
    $setter = Get-Command Set-NetFirewallProfile -ErrorAction SilentlyContinue
    if ($null -eq $setter) {
        $failures.Add('Windows Firewall: Set-NetFirewallProfile is unavailable')
        return $failures.ToArray()
    }
    try {
        Set-NetFirewallProfile -Profile Domain, Private, Public `
            -Enabled False -ErrorAction Stop
        Write-Host '  Windows Firewall profiles disabled: Domain, Private, Public' `
            -ForegroundColor DarkGray
    } catch {
        $failures.Add("Windows Firewall profiles: $($_.Exception.Message)")
    }
    foreach ($profile in @(Get-FirewallSnapshots)) {
        if ([string]$profile.Enabled -ine 'False') {
            $failures.Add("Windows Firewall profile still enabled: $($profile.Name)")
        }
    }
    return $failures.ToArray()
}

function Restore-FirewallSnapshots {
    param([AllowNull()][object[]]$Snapshots)

    $failures = New-Object 'System.Collections.Generic.List[string]'
    if ($null -eq $Snapshots -or $Snapshots.Count -eq 0) {
        return $failures.ToArray()
    }
    if ($null -eq (Get-Command Set-NetFirewallProfile `
        -ErrorAction SilentlyContinue)) {
        $failures.Add('Windows Firewall rollback: Set-NetFirewallProfile is unavailable')
        return $failures.ToArray()
    }
    foreach ($snapshot in $Snapshots) {
        $name = [string]$snapshot.Name
        if (@('Domain', 'Private', 'Public') -notcontains $name) {
            $failures.Add("Windows Firewall state contains an unexpected profile: $name")
            continue
        }
        $enabled = [string]$snapshot.Enabled
        if (@('True', 'False', 'NotConfigured') -notcontains $enabled) {
            $failures.Add("Windows Firewall state has invalid Enabled value for ${name}: $enabled")
            continue
        }
        try {
            Set-NetFirewallProfile -Profile $name `
                -Enabled $enabled -ErrorAction Stop
        } catch {
            $failures.Add("Windows Firewall rollback ${name}: $($_.Exception.Message)")
        }
    }
    return $failures.ToArray()
}

function Test-ServiceNameAllowed {
    param([Parameter(Mandatory = $true)][string]$Name)

    if ($ServicePlan.Name -icontains $Name) { return $true }
    foreach ($pattern in $ServicePatternPlan) {
        if ($Name -imatch ([string]$pattern.Pattern)) { return $true }
    }
    return $false
}

function Get-CurrentServicePlans {
    $result = New-Object 'System.Collections.Generic.List[object]'
    $seen = @{}
    foreach ($plan in $ServicePlan) {
        $key = ([string]$plan.Name).ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) {
            $result.Add($plan)
            $seen[$key] = $true
        }
    }
    foreach ($service in @(Get-CimInstance Win32_Service -ErrorAction Stop)) {
        $name = [string]$service.Name
        $key = $name.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        foreach ($pattern in $ServicePatternPlan) {
            if ($name -imatch ([string]$pattern.Pattern)) {
                $result.Add([pscustomobject]@{
                    Name = $name
                    Group = [string]$pattern.Group
                    Purpose = [string]$pattern.Purpose
                    Required = (Test-PlanRequired $pattern)
                })
                $seen[$key] = $true
                break
            }
        }
    }
    return $result.ToArray()
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
    foreach ($plan in @(Get-CurrentServicePlans)) {
        if ([string]$plan.Name -ieq $FirewallServiceName) { continue }
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
            if (Test-PlanRequired $plan) {
                $failures.Add($message)
                Write-Warning $message
            } else {
                Write-Host "  protected service retained but made inert: $($plan.Name)" `
                    -ForegroundColor DarkYellow
            }
        }
    }
    # Windows PowerShell 5.1 can throw "Argument types do not match" when an
    # array subexpression directly wraps System.Collections.Generic.List[T].
    return $failures.ToArray()
}

function Disable-FirewallService {
    $failures = New-Object 'System.Collections.Generic.List[string]'
    $plan = @($ServicePlan | Where-Object {
        [string]$_.Name -ieq $FirewallServiceName
    }) | Select-Object -First 1
    if ($null -eq $plan) {
        $failures.Add("Windows Firewall service plan is missing: $FirewallServiceName")
        return $failures.ToArray()
    }
    $saved = Get-ServiceSnapshot $plan
    if (-not [bool]$saved.Exists) {
        $failures.Add("Windows Firewall service is missing: $FirewallServiceName")
        return $failures.ToArray()
    }
    try {
        Stop-Service -Name $FirewallServiceName -Force `
            -ErrorAction SilentlyContinue
        Set-Service -Name $FirewallServiceName -StartupType Disabled `
            -ErrorAction Stop
        $current = Get-ServiceSnapshot $plan
        if ([string]$current.StartMode -ne 'Disabled') {
            throw "startup mode remained '$($current.StartMode)'"
        }
        $stateNote = if ([string]$current.State -eq 'Running') {
            ' (running instance will be absent after restart)'
        } else { '' }
        Write-Host "  firewall service startup disabled: $FirewallServiceName$stateNote" `
            -ForegroundColor DarkGray
    } catch {
        $directError = $_.Exception.Message
        $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        if ($currentSid -ne 'S-1-5-18') {
            # MpsSvc intentionally denies SERVICE_CHANGE_CONFIG to a normal
            # elevated administrator on supported Windows 10 builds.  The
            # profile's already-installed, rollback-owned task runs as Local
            # System and can apply the same documented startup-mode change
            # without deleting the service, changing its ACL, or touching a
            # driver.  Start it immediately so the first requested reboot is
            # already a true no-MpsSvc boot.
            try {
                Start-ScheduledTask -TaskPath $EnforcementTaskPath `
                    -TaskName $EnforcementTaskName -ErrorAction Stop
                $deadline = [DateTime]::UtcNow.AddMinutes(3)
                do {
                    Start-Sleep -Seconds 2
                    $current = Get-ServiceSnapshot $plan
                    if ([string]$current.StartMode -eq 'Disabled') {
                        $stateNote = if ([string]$current.State -eq 'Running') {
                            ' (running instance will be absent after restart)'
                        } else { '' }
                        Write-Host "  firewall startup disabled by the Local System enforcement task: $FirewallServiceName$stateNote" `
                            -ForegroundColor DarkGray
                        return $failures.ToArray()
                    }
                } while ([DateTime]::UtcNow -lt $deadline)
                throw 'Local System enforcement did not set Disabled within three minutes.'
            } catch {
                $failures.Add("Windows Firewall service ${FirewallServiceName}: direct=$directError; Local System=$($_.Exception.Message)")
                return $failures.ToArray()
            }
        }
        $failures.Add("Windows Firewall service ${FirewallServiceName}: $directError")
    }
    return $failures.ToArray()
}

function Restore-ServiceSnapshot {
    param([Parameter(Mandatory = $true)][object]$Snapshot)

    if (-not (Test-ServiceNameAllowed -Name ([string]$Snapshot.Name))) {
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

function Test-TaskTargetAllowed {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    foreach ($plan in $TaskPlan) {
        if ([string]$plan.Path -ieq $Path -and
            [string]$plan.Name -ieq $Name) { return $true }
    }
    foreach ($pattern in $TaskPatternPlan) {
        if ($Path -imatch ([string]$pattern.PathPattern) -and
            $Name -imatch ([string]$pattern.NamePattern)) { return $true }
    }
    return $false
}

function Get-CurrentTaskPlans {
    $result = New-Object 'System.Collections.Generic.List[object]'
    $seen = @{}
    foreach ($plan in $TaskPlan) {
        $key = ("$($plan.Path)|$($plan.Name)").ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) {
            $result.Add($plan)
            $seen[$key] = $true
        }
    }
    foreach ($task in @(Get-ScheduledTask -ErrorAction Stop)) {
        $path = [string]$task.TaskPath
        $name = [string]$task.TaskName
        $key = ("${path}|${name}").ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        foreach ($pattern in $TaskPatternPlan) {
            if ($path -imatch ([string]$pattern.PathPattern) -and
                $name -imatch ([string]$pattern.NamePattern)) {
                $result.Add([pscustomobject]@{
                    Path = $path
                    Name = $name
                    Group = [string]$pattern.Group
                    Required = (Test-PlanRequired $pattern)
                })
                $seen[$key] = $true
                break
            }
        }
    }
    return $result.ToArray()
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
    foreach ($plan in @(Get-CurrentTaskPlans)) {
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
            if (Test-PlanRequired $plan) {
                $failures.Add($message)
                Write-Warning $message
            } else {
                Write-Host "  protected task retained but made inert: $($plan.Path)$($plan.Name)" `
                    -ForegroundColor DarkYellow
            }
        }
    }
    return $failures.ToArray()
}

function Restore-TaskSnapshot {
    param([Parameter(Mandatory = $true)][object]$Snapshot)

    if (-not (Test-TaskTargetAllowed -Path ([string]$Snapshot.Path) `
        -Name ([string]$Snapshot.Name))) {
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
    $allowed = @{}
    foreach ($name in $AppPlan) {
        $allowed[([string]$name).ToLowerInvariant()] = $true
    }
    # One current-user inventory is substantially faster than issuing one
    # deployment query for every package name (VM1 measured minutes for the
    # repeated form). Exact-name filtering preserves the reviewed allowlist.
    foreach ($package in @(Get-AppxPackage -ErrorAction SilentlyContinue)) {
        $name = [string]$package.Name
        if (-not $allowed.ContainsKey($name.ToLowerInvariant())) { continue }
        $rows.Add([pscustomobject]@{
            Name = $name
            PackageFullName = [string]$package.PackageFullName
            PackageFamilyName = [string]$package.PackageFamilyName
            InstallLocation = [string]$package.InstallLocation
        })
    }
    return $rows.ToArray()
}

function Remove-PlannedApps {
    $failures = New-Object 'System.Collections.Generic.List[string]'
    # Remove what is installed now, not just what existed in the original
    # baseline. Rollback still restores only packages that the tool found
    # before its first Apply.
    foreach ($package in @(Get-AppSnapshots)) {
        if ($AppPlan -notcontains [string]$package.Name) {
            $message = "unexpected app identity in state: $($package.Name)"
            $failures.Add($message)
            Write-Warning $message
            continue
        }
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

function Stop-PlannedProcesses {
    $failures = New-Object 'System.Collections.Generic.List[string]'
    foreach ($plan in $ProcessPlan) {
        foreach ($process in @(Get-Process -Name ([string]$plan.Name) `
            -ErrorAction SilentlyContinue)) {
            try {
                Stop-Process -Id $process.Id -Force -ErrorAction Stop
                Write-Host "  process stopped: $($process.ProcessName) ($($plan.Purpose))" `
                    -ForegroundColor DarkGray
            } catch {
                $message = "process $($plan.Name): $($_.Exception.Message)"
                $failures.Add($message)
                Write-Warning $message
            }
        }
    }
    foreach ($plan in $ProcessPlan) {
        if (@(Get-Process -Name ([string]$plan.Name) `
            -ErrorAction SilentlyContinue).Count -gt 0) {
            $failures.Add("process still running: $($plan.Name)")
        }
    }
    return $failures.ToArray()
}

function Test-DnfProcessNameAllowed {
    param([Parameter(Mandatory = $true)][string]$Name)

    return $DnfProcessPlan.Name -icontains $Name
}

function Get-DnfProcessSnapshots {
    $snapshots = New-Object 'System.Collections.Generic.List[object]'
    foreach ($plan in $DnfProcessPlan) {
        foreach ($process in @(Get-Process -Name ([string]$plan.Name) `
            -ErrorAction SilentlyContinue)) {
            try {
                $snapshots.Add([pscustomobject]@{
                    Available = $true
                    Name = [string]$process.ProcessName
                    Id = [int]$process.Id
                    StartTimeUtc = $process.StartTime.ToUniversalTime().ToString('o')
                    PriorityClass = [string]$process.PriorityClass
                    Error = ''
                })
            } catch {
                $snapshots.Add([pscustomobject]@{
                    Available = $false
                    Name = [string]$process.ProcessName
                    Id = [int]$process.Id
                    StartTimeUtc = ''
                    PriorityClass = ''
                    Error = $_.Exception.Message
                })
            }
        }
    }
    return $snapshots.ToArray()
}

function Set-DnfProcessPriority {
    $failures = New-Object 'System.Collections.Generic.List[string]'
    $found = 0
    foreach ($plan in $DnfProcessPlan) {
        foreach ($process in @(Get-Process -Name ([string]$plan.Name) `
            -ErrorAction SilentlyContinue)) {
            $found++
            try {
                $process.PriorityClass = `
                    [Diagnostics.ProcessPriorityClass]::High
                $process.Refresh()
                if ([string]$process.PriorityClass -cne 'High') {
                    throw "priority verification returned $($process.PriorityClass)"
                }
                Write-Host "  DNF priority: $($process.ProcessName) pid=$($process.Id) High" `
                    -ForegroundColor DarkGray
            } catch {
                $message = "DNF process $($plan.Name) pid=$($process.Id): $($_.Exception.Message)"
                $failures.Add($message)
                Write-Warning $message
            }
        }
    }
    if ($found -eq 0) {
        Write-Host '  DNF priority: no allowlisted DNF process is running; IFEO High priority is staged for the next launch' `
            -ForegroundColor DarkGray
    }
    return $failures.ToArray()
}

function Restore-DnfProcessSnapshots {
    param([AllowNull()][object[]]$Snapshots)

    $failures = New-Object 'System.Collections.Generic.List[string]'
    foreach ($snapshot in @($Snapshots)) {
        if (-not [bool]$snapshot.Available) { continue }
        $name = [string]$snapshot.Name
        if (-not (Test-DnfProcessNameAllowed $name)) {
            $failures.Add("unexpected DNF process identity in state: $name")
            continue
        }
        $processId = [int]$snapshot.Id
        if ($processId -le 0) {
            $failures.Add("invalid DNF process id in state: $processId")
            continue
        }
        $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if ($null -eq $process -or [string]$process.ProcessName -ine $name) {
            continue
        }
        try {
            $liveStart = $process.StartTime.ToUniversalTime().ToString('o')
            if ($liveStart -cne [string]$snapshot.StartTimeUtc) { continue }
            $priority = [Diagnostics.ProcessPriorityClass][Enum]::Parse(
                [Diagnostics.ProcessPriorityClass],
                [string]$snapshot.PriorityClass, $false
            )
            $process.PriorityClass = $priority
            $process.Refresh()
            if ([string]$process.PriorityClass -cne [string]$priority) {
                throw "priority verification returned $($process.PriorityClass)"
            }
            Write-Host "  DNF priority restored: $name pid=$processId $priority" `
                -ForegroundColor DarkGray
        } catch {
            $message = "DNF process priority restore $name pid=${processId}: $($_.Exception.Message)"
            $failures.Add($message)
            Write-Warning $message
        }
    }
    return $failures.ToArray()
}

function Clear-SafeTemporaryDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][DateTime]$CutoffUtc
    )

    $deletedFiles = 0
    $deletedDirectories = 0
    [uint64]$reclaimedBytes = 0
    $skippedItems = 0
    $errors = New-Object 'System.Collections.Generic.List[string]'
    $rootItem = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not [bool]$rootItem.PSIsContainer -or
        [string]$rootItem.PSProvider.Name -cne 'FileSystem' -or
        ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "temporary root is not a plain filesystem directory: $Path"
    }
    $root = [IO.Path]::GetFullPath([string]$rootItem.FullName).TrimEnd('\')
    $allowed = @(
        [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Temp')).TrimEnd('\'),
        [IO.Path]::GetFullPath((Join-Path $env:SystemRoot 'Temp')).TrimEnd('\')
    )
    if ($allowed -inotcontains $root) {
        throw "temporary root is outside the fixed allowlist: $root"
    }
    $driveRoot = [IO.Path]::GetPathRoot($root)
    $drive = New-Object -TypeName System.IO.DriveInfo `
        -ArgumentList $driveRoot
    if ($drive.DriveType -ne [IO.DriveType]::Fixed) {
        throw "temporary root is not on a fixed local drive: $root"
    }

    $rootPrefix = $root + '\'
    $pending = New-Object 'System.Collections.Generic.Stack[object]'
    $directories = New-Object 'System.Collections.Generic.List[object]'
    $pending.Push($rootItem)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        $directories.Add($directory)
        try {
            $children = @(Get-ChildItem -LiteralPath $directory.FullName `
                -Force -ErrorAction Stop)
        } catch {
            if ($errors.Count -lt 20) {
                $errors.Add("enumerate $($directory.FullName): $($_.Exception.Message)")
            }
            $skippedItems++
            continue
        }
        foreach ($child in $children) {
            try {
                $childPath = [IO.Path]::GetFullPath([string]$child.FullName)
                if (-not $childPath.StartsWith($rootPrefix,
                        [StringComparison]::OrdinalIgnoreCase)) {
                    throw "item escaped the temporary root: $childPath"
                }
                if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    $skippedItems++
                    continue
                }
                if ([bool]$child.PSIsContainer) {
                    $pending.Push($child)
                    continue
                }
                if ($child.LastWriteTimeUtc -ge $CutoffUtc -or
                    $child.CreationTimeUtc -ge $CutoffUtc) {
                    $skippedItems++
                    continue
                }
                [uint64]$length = [uint64]$child.Length
                Remove-Item -LiteralPath $child.FullName -Force `
                    -ErrorAction Stop
                $deletedFiles++
                $reclaimedBytes += $length
            } catch {
                if ($errors.Count -lt 20) {
                    $errors.Add("skip $($child.FullName): $($_.Exception.Message)")
                }
                $skippedItems++
            }
        }
    }

    foreach ($directory in @($directories | Sort-Object {
            ([string]$_.FullName).Length
        } -Descending)) {
        $directoryPath = [IO.Path]::GetFullPath(
            [string]$directory.FullName).TrimEnd('\')
        if ($directoryPath -ieq $root -or
            $directory.LastWriteTimeUtc -ge $CutoffUtc -or
            $directory.CreationTimeUtc -ge $CutoffUtc) { continue }
        try {
            if (@(Get-ChildItem -LiteralPath $directory.FullName -Force `
                    -ErrorAction Stop).Count -eq 0) {
                Remove-Item -LiteralPath $directory.FullName -Force `
                    -ErrorAction Stop
                $deletedDirectories++
            }
        } catch {
            if ($errors.Count -lt 20) {
                $errors.Add("keep directory $($directory.FullName): $($_.Exception.Message)")
            }
            $skippedItems++
        }
    }

    return [pscustomobject]@{
        Root = $root
        DeletedFiles = $deletedFiles
        DeletedDirectories = $deletedDirectories
        ReclaimedBytes = $reclaimedBytes
        SkippedItems = $skippedItems
        Errors = $errors.ToArray()
    }
}

function Clear-SafeTemporaryFiles {
    $cutoff = [DateTime]::UtcNow.AddHours(-$TemporaryFileMinimumAgeHours)
    $roots = @(
        (Join-Path $env:LOCALAPPDATA 'Temp'),
        (Join-Path $env:SystemRoot 'Temp')
    ) | Select-Object -Unique
    $results = New-Object 'System.Collections.Generic.List[object]'
    $rootErrors = New-Object 'System.Collections.Generic.List[string]'
    foreach ($root in $roots) {
        try {
            $result = Clear-SafeTemporaryDirectory -Path $root `
                -CutoffUtc $cutoff
            $results.Add($result)
            Write-Host ("  temp cleaned: {0}; files={1} directories={2} reclaimed={3:N0} bytes skipped={4}" -f `
                $result.Root, $result.DeletedFiles, $result.DeletedDirectories,
                $result.ReclaimedBytes, $result.SkippedItems) `
                -ForegroundColor DarkGray
            foreach ($detail in @($result.Errors)) {
                Write-Host "    kept: $detail" -ForegroundColor DarkYellow
            }
        } catch {
            $message = "temporary root ${root}: $($_.Exception.Message)"
            $rootErrors.Add($message)
            Write-Warning $message
        }
    }
    [uint64]$totalBytes = 0
    $totalFiles = 0
    $totalDirectories = 0
    $totalSkipped = 0
    foreach ($result in $results) {
        $totalBytes += [uint64]$result.ReclaimedBytes
        $totalFiles += [int]$result.DeletedFiles
        $totalDirectories += [int]$result.DeletedDirectories
        $totalSkipped += [int]$result.SkippedItems
    }
    return [pscustomobject]@{
        CompletedUtc = [DateTime]::UtcNow.ToString('o')
        MinimumAgeHours = $TemporaryFileMinimumAgeHours
        RootsProcessed = $results.Count
        DeletedFiles = $totalFiles
        DeletedDirectories = $totalDirectories
        ReclaimedBytes = $totalBytes
        SkippedItems = $totalSkipped
        Roots = $results.ToArray()
        RootErrors = $rootErrors.ToArray()
    }
}

function Initialize-AudioEndpointInterop {
    if ($null -ne ('G11GuestLite.AudioEndpoint' -as [type])) { return }

    Add-Type -Language CSharp -ErrorAction Stop -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace G11GuestLite
{
    internal enum EDataFlow
    {
        Render = 0,
        Capture = 1,
        All = 2
    }

    internal enum ERole
    {
        Console = 0,
        Multimedia = 1,
        Communications = 2
    }

    [Flags]
    internal enum CLSCTX : uint
    {
        All = 23
    }

    [ComImport]
    [Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    internal class MMDeviceEnumeratorComObject
    {
    }

    [ComImport]
    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDeviceEnumerator
    {
        [PreserveSig]
        int EnumAudioEndpoints(EDataFlow dataFlow, uint stateMask,
            out IntPtr devices);

        [PreserveSig]
        int GetDefaultAudioEndpoint(EDataFlow dataFlow, ERole role,
            out IMMDevice endpoint);
    }

    [ComImport]
    [Guid("D666063F-1587-4E43-81F1-B948E807363F")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDevice
    {
        [PreserveSig]
        int Activate(ref Guid iid, CLSCTX clsctx, IntPtr activationParameters,
            [MarshalAs(UnmanagedType.IUnknown)] out object interfacePointer);
    }

    [ComImport]
    [Guid("5CDF2C82-841E-4546-9722-0CF74078229A")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioEndpointVolume
    {
        [PreserveSig] int RegisterControlChangeNotify(IntPtr notify);
        [PreserveSig] int UnregisterControlChangeNotify(IntPtr notify);
        [PreserveSig] int GetChannelCount(out uint channelCount);
        [PreserveSig] int SetMasterVolumeLevel(float levelDb,
            ref Guid eventContext);
        [PreserveSig] int SetMasterVolumeLevelScalar(float level,
            ref Guid eventContext);
        [PreserveSig] int GetMasterVolumeLevel(out float levelDb);
        [PreserveSig] int GetMasterVolumeLevelScalar(out float level);
        [PreserveSig] int SetChannelVolumeLevel(uint channel, float levelDb,
            ref Guid eventContext);
        [PreserveSig] int SetChannelVolumeLevelScalar(uint channel, float level,
            ref Guid eventContext);
        [PreserveSig] int GetChannelVolumeLevel(uint channel, out float levelDb);
        [PreserveSig] int GetChannelVolumeLevelScalar(uint channel,
            out float level);
        [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool muted,
            ref Guid eventContext);
        [PreserveSig] int GetMute([MarshalAs(UnmanagedType.Bool)] out bool muted);
    }

    public static class AudioEndpoint
    {
        private static void ThrowIfFailed(int result)
        {
            if (result < 0)
            {
                Marshal.ThrowExceptionForHR(result);
            }
        }

        private static IAudioEndpointVolume Open(
            out IMMDeviceEnumerator enumerator, out IMMDevice device)
        {
            enumerator = (IMMDeviceEnumerator)new MMDeviceEnumeratorComObject();
            ThrowIfFailed(enumerator.GetDefaultAudioEndpoint(
                EDataFlow.Render, ERole.Console, out device));
            Guid iid = typeof(IAudioEndpointVolume).GUID;
            object activated;
            ThrowIfFailed(device.Activate(ref iid, CLSCTX.All, IntPtr.Zero,
                out activated));
            return (IAudioEndpointVolume)activated;
        }

        private static void Release(object value)
        {
            if (value != null && Marshal.IsComObject(value))
            {
                Marshal.ReleaseComObject(value);
            }
        }

        public static bool GetMute()
        {
            IMMDeviceEnumerator enumerator = null;
            IMMDevice device = null;
            IAudioEndpointVolume volume = null;
            try
            {
                volume = Open(out enumerator, out device);
                bool muted;
                ThrowIfFailed(volume.GetMute(out muted));
                return muted;
            }
            finally
            {
                Release(volume);
                Release(device);
                Release(enumerator);
            }
        }

        public static void SetMute(bool muted)
        {
            IMMDeviceEnumerator enumerator = null;
            IMMDevice device = null;
            IAudioEndpointVolume volume = null;
            try
            {
                volume = Open(out enumerator, out device);
                Guid eventContext = Guid.Empty;
                ThrowIfFailed(volume.SetMute(muted, ref eventContext));
            }
            finally
            {
                Release(volume);
                Release(device);
                Release(enumerator);
            }
        }
    }
}
'@
}

function Get-AudioEndpointSnapshot {
    $result = [ordered]@{
        Available = $false
        Muted = $false
        Error = ''
    }
    try {
        Initialize-AudioEndpointInterop
        $result.Muted = [bool][G11GuestLite.AudioEndpoint]::GetMute()
        $result.Available = $true
    } catch {
        $result.Error = $_.Exception.Message
    }
    return [pscustomobject]$result
}

function Set-DefaultAudioMuted {
    param([Parameter(Mandatory = $true)][bool]$Muted)

    $failures = New-Object 'System.Collections.Generic.List[string]'
    try {
        Initialize-AudioEndpointInterop
        [G11GuestLite.AudioEndpoint]::SetMute($Muted)
        $current = Get-AudioEndpointSnapshot
        if (-not [bool]$current.Available -or
            [bool]$current.Muted -ne $Muted) {
            throw "default render endpoint mute verification failed: available=$($current.Available) muted=$($current.Muted) error=$($current.Error)"
        }
        Write-Host "  default playback endpoint muted: $Muted" `
            -ForegroundColor DarkGray
    } catch {
        $message = "default playback endpoint mute: $($_.Exception.Message)"
        $failures.Add($message)
        Write-Warning $message
    }
    return $failures.ToArray()
}

function Restore-AudioEndpointSnapshot {
    param([AllowNull()][object]$Snapshot)

    if ($null -eq $Snapshot -or -not [bool]$Snapshot.Available) { return }
    Initialize-AudioEndpointInterop
    [G11GuestLite.AudioEndpoint]::SetMute([bool]$Snapshot.Muted)
    $current = Get-AudioEndpointSnapshot
    if (-not [bool]$current.Available -or
        [bool]$current.Muted -ne [bool]$Snapshot.Muted) {
        throw "original audio mute state was not restored: $($current.Error)"
    }
}

function Test-InputTipText {
    param([AllowNull()][string]$InputTip)

    return -not [string]::IsNullOrWhiteSpace($InputTip) -and
        $InputTip -match '^[0-9A-Fa-f]{4}:(?:[0-9A-Fa-f]{8}|\{[0-9A-Fa-f-]{36}\}\{[0-9A-Fa-f-]{36}\})$'
}

function Get-UserLanguageListSnapshot {
    $result = [ordered]@{
        Available = $false
        Items = @()
        Error = ''
    }
    try {
        foreach ($commandName in @(
            'Get-WinUserLanguageList', 'New-WinUserLanguageList',
            'Set-WinUserLanguageList', 'Set-WinDefaultInputMethodOverride'
        )) {
            if ($null -eq (Get-Command $commandName -ErrorAction SilentlyContinue)) {
                throw "$commandName is unavailable"
            }
        }
        # Windows PowerShell 5.1 can emit LanguageList as one pipeline object
        # instead of enumerating its WinUserLanguage entries. Index the
        # collection explicitly so a two-language list cannot collapse into a
        # one-item snapshot whose properties contain arrays.
        $liveLanguages = Get-WinUserLanguageList -ErrorAction Stop
        $items = New-Object 'System.Collections.Generic.List[object]'
        for ($languageIndex = 0;
             $languageIndex -lt $liveLanguages.Count;
             $languageIndex++) {
            $language = $liveLanguages[$languageIndex]
            $items.Add([pscustomobject]@{
                LanguageTag = [string]$language.LanguageTag
                InputMethodTips = @($language.InputMethodTips | ForEach-Object {
                    [string]$_
                })
            })
        }
        if ($items.Count -eq 0) { throw 'the current user language list is empty' }
        $result.Items = $items.ToArray()
        $result.Available = $true
    } catch {
        $result.Error = $_.Exception.Message
    }
    return [pscustomobject]$result
}

function Test-PreferredUserLanguageList {
    param([AllowNull()][object]$Snapshot)

    if ($null -eq $Snapshot -or -not [bool]$Snapshot.Available) {
        return $false
    }
    $items = @($Snapshot.Items)
    if ($items.Count -lt 2) { return $false }
    $englishTagMatches = ([string]$items[0].LanguageTag -ieq `
        $EnglishLanguageTag)
    $englishTipMatches = $false
    foreach ($tip in @($items[0].InputMethodTips)) {
        if ([string]$tip -ieq $EnglishInputTip) {
            $englishTipMatches = $true
            break
        }
    }
    $pinyinTag = [string]$items[1].LanguageTag
    $pinyinTagMatches = ($pinyinTag -ieq $PinyinLanguageTag -or
        $pinyinTag -ieq $PinyinCanonicalLanguageTag)
    $pinyinTipMatches = $false
    foreach ($tip in @($items[1].InputMethodTips)) {
        if ([string]$tip -ieq $PinyinInputTip) {
            $pinyinTipMatches = $true
            break
        }
    }
    return $englishTagMatches -and $englishTipMatches -and
        $pinyinTagMatches -and $pinyinTipMatches
}

function Set-PreferredUserLanguageList {
    $failures = New-Object 'System.Collections.Generic.List[string]'
    try {
        $current = Get-UserLanguageListSnapshot
        if (-not [bool]$current.Available) {
            throw "current user language list cannot be read: $($current.Error)"
        }

        $desired = New-WinUserLanguageList -Language $EnglishLanguageTag `
            -ErrorAction Stop
        $desired[0].InputMethodTips.Clear()
        $null = $desired[0].InputMethodTips.Add($EnglishInputTip)

        # LanguageList.Add accepts a language tag, not a WinUserLanguage
        # object. Passing $pinyin[0] appears valid in newer PowerShell but
        # fails on Windows PowerShell 5.1 with "Cannot find an overload for
        # Add". Append by tag, then configure the newly created item.
        $null = $desired.Add($PinyinLanguageTag)
        $pinyin = $desired[$desired.Count - 1]
        $pinyin.InputMethodTips.Clear()
        $null = $pinyin.InputMethodTips.Add($PinyinInputTip)

        $liveLanguages = Get-WinUserLanguageList -ErrorAction Stop
        for ($languageIndex = 0;
             $languageIndex -lt $liveLanguages.Count;
             $languageIndex++) {
            $language = $liveLanguages[$languageIndex]
            if ([string]$language.LanguageTag -iin @(
                    $EnglishLanguageTag, $PinyinLanguageTag,
                    $PinyinCanonicalLanguageTag)) {
                continue
            }
            $languageTag = [string]$language.LanguageTag
            $null = $desired.Add($languageTag)
            $addedLanguage = $desired[$desired.Count - 1]
            $addedLanguage.InputMethodTips.Clear()
            foreach ($tip in @($language.InputMethodTips)) {
                $tipText = [string]$tip
                if (-not (Test-InputTipText $tipText)) {
                    throw "current language list contains an invalid input TIP: $tipText"
                }
                $null = $addedLanguage.InputMethodTips.Add($tipText)
            }
        }

        Set-WinUserLanguageList -LanguageList $desired -Force `
            -ErrorAction Stop
        Set-WinDefaultInputMethodOverride -InputTip $EnglishInputTip `
            -ErrorAction Stop
        $applied = Get-UserLanguageListSnapshot
        if (-not (Test-PreferredUserLanguageList $applied)) {
            $actual = @($applied.Items | ForEach-Object {
                '{0}[{1}]' -f [string]$_.LanguageTag,
                    (@($_.InputMethodTips) -join ',')
            }) -join ';'
            throw "en-US/US first and zh-CN/Microsoft Pinyin second were not applied: actual=$actual error=$($applied.Error)"
        }
        Write-Host '  input order: en-US/US first, zh-CN/Microsoft Pinyin second' `
            -ForegroundColor DarkGray
    } catch {
        $message = "user language/input order: $($_.Exception.Message)"
        $failures.Add($message)
        Write-Warning $message
    }
    return $failures.ToArray()
}

function Restore-UserLanguageListSnapshot {
    param([AllowNull()][object]$Snapshot)

    if ($null -eq $Snapshot -or -not [bool]$Snapshot.Available) { return }
    $items = @($Snapshot.Items)
    if ($items.Count -eq 0) {
        throw 'Rollback state contains an empty user language list.'
    }

    $restored = $null
    foreach ($item in $items) {
        $languageTag = [string]$item.LanguageTag
        if ($languageTag -notmatch '^[A-Za-z0-9-]{2,35}$') {
            throw "Rollback state contains an invalid language tag: $languageTag"
        }
        if ($null -eq $restored) {
            $restored = New-WinUserLanguageList -Language $languageTag `
                -ErrorAction Stop
            $target = $restored[0]
        } else {
            $null = $restored.Add($languageTag)
            $target = $restored[$restored.Count - 1]
        }
        $target.InputMethodTips.Clear()
        foreach ($tip in @($item.InputMethodTips)) {
            $tipText = [string]$tip
            if (-not (Test-InputTipText $tipText)) {
                throw "Rollback state contains an invalid input TIP: $tipText"
            }
            $null = $target.InputMethodTips.Add($tipText)
        }
    }
    Set-WinUserLanguageList -LanguageList $restored -Force -ErrorAction Stop
}

function Initialize-NvidiaDrsInterop {
    if ($null -ne ('G11GuestLite.NvidiaDrs' -as [type])) { return }

    # The public NVIDIA NVAPI SDK defines PREFERRED_PSTATE_ID=0x1057EB71 and
    # PREFERRED_PSTATE_PREFER_MAX=1. Resolve only the installed System32
    # driver's nvapi64.dll and call its documented DRS surface. No DLL, driver,
    # service, signing policy, or private nvlddmkm registry value is replaced.
    Add-Type -Language CSharp -ErrorAction Stop -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace G11GuestLite
{
    public sealed class NvidiaPowerModeSnapshot
    {
        public bool SettingFound { get; set; }
        public bool HasUserOverride { get; set; }
        public uint CurrentValue { get; set; }
        public uint SettingLocation { get; set; }
    }

    public static class NvidiaDrs
    {
        private const uint PreferredPstateId = 0x1057EB71u;
        private const uint PreferMaximumPerformance = 1u;
        private const int NvapiOk = 0;
        private const int NvapiSettingNotFound = -160;
        private const uint LoadLibrarySearchDllLoadDir = 0x00000100u;
        private const uint LoadLibrarySearchSystem32 = 0x00000800u;
        private const int DrsDwordType = 0;
        private const int DrsSettingBytes = 12320;

        [StructLayout(LayoutKind.Sequential, Pack = 4)]
        private struct DrsSetting
        {
            public uint Version;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 2048,
                ArraySubType = UnmanagedType.U2)]
            public ushort[] SettingName;
            public uint SettingId;
            public int SettingType;
            public uint SettingLocation;
            public uint IsCurrentPredefined;
            public uint IsPredefinedValid;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 4100,
                ArraySubType = UnmanagedType.U1)]
            public byte[] PredefinedValue;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 4100,
                ArraySubType = UnmanagedType.U1)]
            public byte[] CurrentValue;
        }

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private delegate IntPtr QueryInterfaceDelegate(uint interfaceId);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private delegate int StatusOnlyDelegate();
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private delegate int CreateSessionDelegate(out IntPtr session);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private delegate int SessionDelegate(IntPtr session);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private delegate int GetBaseProfileDelegate(IntPtr session,
            out IntPtr profile);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private delegate int GetSettingDelegate(IntPtr session, IntPtr profile,
            uint settingId, [In, Out] ref DrsSetting setting);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private delegate int SetSettingDelegate(IntPtr session, IntPtr profile,
            [In] ref DrsSetting setting);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private delegate int DeleteSettingDelegate(IntPtr session,
            IntPtr profile, uint settingId);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl,
            CharSet = CharSet.Ansi)]
        private delegate int ErrorMessageDelegate(int status,
            [Out] StringBuilder message);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode,
            SetLastError = true)]
        private static extern uint GetSystemDirectory(StringBuilder buffer,
            uint size);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode,
            SetLastError = true)]
        private static extern IntPtr LoadLibraryEx(string fileName,
            IntPtr file, uint flags);
        [DllImport("kernel32.dll", CharSet = CharSet.Ansi,
            SetLastError = true)]
        private static extern IntPtr GetProcAddress(IntPtr module,
            string procedureName);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool FreeLibrary(IntPtr module);

        private sealed class Context : IDisposable
        {
            private IntPtr module;
            private bool initialized;
            private QueryInterfaceDelegate queryInterface;

            internal StatusOnlyDelegate Unload;
            internal CreateSessionDelegate CreateSession;
            internal SessionDelegate DestroySession;
            internal SessionDelegate LoadSettings;
            internal SessionDelegate SaveSettings;
            internal GetBaseProfileDelegate GetBaseProfile;
            internal GetSettingDelegate GetSetting;
            internal SetSettingDelegate SetSetting;
            internal DeleteSettingDelegate DeleteSetting;
            internal ErrorMessageDelegate GetErrorMessage;

            internal Context()
            {
                try
                {
                    StringBuilder directory = new StringBuilder(32768);
                    uint length = GetSystemDirectory(directory,
                        (uint)directory.Capacity);
                    if (length == 0 || length >= (uint)directory.Capacity)
                    {
                        throw new InvalidOperationException(
                            "Windows System32 path is unavailable");
                    }
                    string path = Path.Combine(directory.ToString(),
                        "nvapi64.dll");
                    module = LoadLibraryEx(path, IntPtr.Zero,
                        LoadLibrarySearchDllLoadDir |
                        LoadLibrarySearchSystem32);
                    if (module == IntPtr.Zero)
                    {
                        throw new InvalidOperationException(
                            "the installed System32 NVIDIA NVAPI is unavailable (Win32 " +
                            Marshal.GetLastWin32Error().ToString() + ")");
                    }
                    IntPtr queryPointer = GetProcAddress(module,
                        "nvapi_QueryInterface");
                    if (queryPointer == IntPtr.Zero)
                    {
                        throw new InvalidOperationException(
                            "nvapi_QueryInterface is unavailable");
                    }
                    queryInterface = (QueryInterfaceDelegate)
                        Marshal.GetDelegateForFunctionPointer(queryPointer,
                            typeof(QueryInterfaceDelegate));
                    StatusOnlyDelegate initialize = Resolve<StatusOnlyDelegate>(
                        0x0150E828u, "NvAPI_Initialize");
                    Unload = Resolve<StatusOnlyDelegate>(0xD22BDD7Eu,
                        "NvAPI_Unload");
                    GetErrorMessage = Resolve<ErrorMessageDelegate>(0x6C2D048Cu,
                        "NvAPI_GetErrorMessage");
                    CreateSession = Resolve<CreateSessionDelegate>(0x0694D52Eu,
                        "NvAPI_DRS_CreateSession");
                    DestroySession = Resolve<SessionDelegate>(0xDAD9CFF8u,
                        "NvAPI_DRS_DestroySession");
                    LoadSettings = Resolve<SessionDelegate>(0x375DBD6Bu,
                        "NvAPI_DRS_LoadSettings");
                    SaveSettings = Resolve<SessionDelegate>(0xFCBC7E14u,
                        "NvAPI_DRS_SaveSettings");
                    GetBaseProfile = Resolve<GetBaseProfileDelegate>(0xDA8466A0u,
                        "NvAPI_DRS_GetBaseProfile");
                    GetSetting = Resolve<GetSettingDelegate>(0x73BF8338u,
                        "NvAPI_DRS_GetSetting");
                    SetSetting = Resolve<SetSettingDelegate>(0x577DD202u,
                        "NvAPI_DRS_SetSetting");
                    DeleteSetting = Resolve<DeleteSettingDelegate>(0xE4A26362u,
                        "NvAPI_DRS_DeleteProfileSetting");
                    Check(initialize(), "NvAPI_Initialize");
                    initialized = true;
                }
                catch
                {
                    if (module != IntPtr.Zero)
                    {
                        FreeLibrary(module);
                        module = IntPtr.Zero;
                    }
                    throw;
                }
            }

            private T Resolve<T>(uint id, string name) where T : class
            {
                IntPtr pointer = queryInterface(id);
                if (pointer == IntPtr.Zero)
                {
                    throw new InvalidOperationException(name +
                        " is unsupported by the installed NVIDIA driver");
                }
                return (T)(object)Marshal.GetDelegateForFunctionPointer(
                    pointer, typeof(T));
            }

            internal void Check(int status, string operation)
            {
                if (status == NvapiOk) return;
                string detail = String.Empty;
                if (GetErrorMessage != null)
                {
                    try
                    {
                        StringBuilder message = new StringBuilder(64);
                        GetErrorMessage(status, message);
                        detail = message.ToString();
                    }
                    catch { }
                }
                throw new InvalidOperationException(operation + " failed: " +
                    status.ToString() +
                    (detail.Length == 0 ? String.Empty : " (" + detail + ")"));
            }

            public void Dispose()
            {
                if (initialized && Unload != null)
                {
                    try { Unload(); } catch { }
                    initialized = false;
                }
                if (module != IntPtr.Zero)
                {
                    FreeLibrary(module);
                    module = IntPtr.Zero;
                }
            }
        }

        private static DrsSetting NewSetting()
        {
            int bytes = Marshal.SizeOf(typeof(DrsSetting));
            if (bytes != DrsSettingBytes)
            {
                throw new InvalidOperationException(
                    "unexpected NVDRS_SETTING size: " + bytes.ToString());
            }
            DrsSetting setting = new DrsSetting();
            setting.Version = (uint)bytes | 0x00010000u;
            setting.SettingName = new ushort[2048];
            setting.PredefinedValue = new byte[4100];
            setting.CurrentValue = new byte[4100];
            return setting;
        }

        private static uint ReadDword(byte[] value)
        {
            if (value == null || value.Length < 4)
            {
                throw new InvalidOperationException(
                    "NVIDIA DRS DWORD buffer is invalid");
            }
            return BitConverter.ToUInt32(value, 0);
        }

        private static void WriteDword(byte[] target, uint value)
        {
            byte[] source = BitConverter.GetBytes(value);
            Array.Copy(source, 0, target, 0, source.Length);
        }

        private static NvidiaPowerModeSnapshot ReadPowerMode(Context context)
        {
            IntPtr session = IntPtr.Zero;
            try
            {
                context.Check(context.CreateSession(out session),
                    "NvAPI_DRS_CreateSession");
                context.Check(context.LoadSettings(session),
                    "NvAPI_DRS_LoadSettings");
                IntPtr profile;
                context.Check(context.GetBaseProfile(session, out profile),
                    "NvAPI_DRS_GetBaseProfile");
                DrsSetting setting = NewSetting();
                int status = context.GetSetting(session, profile,
                    PreferredPstateId, ref setting);
                if (status == NvapiSettingNotFound)
                {
                    return new NvidiaPowerModeSnapshot {
                        SettingFound = false,
                        HasUserOverride = false,
                        CurrentValue = 0u,
                        SettingLocation = 0u
                    };
                }
                context.Check(status, "NvAPI_DRS_GetSetting");
                if (setting.SettingType != DrsDwordType)
                {
                    throw new InvalidOperationException(
                        "NVIDIA power mode is not a DWORD setting");
                }
                return new NvidiaPowerModeSnapshot {
                    SettingFound = true,
                    HasUserOverride = setting.IsCurrentPredefined == 0u,
                    CurrentValue = ReadDword(setting.CurrentValue),
                    SettingLocation = setting.SettingLocation
                };
            }
            finally
            {
                if (session != IntPtr.Zero)
                {
                    try { context.DestroySession(session); } catch { }
                }
            }
        }

        private static void WritePowerMode(Context context, uint value)
        {
            IntPtr session = IntPtr.Zero;
            try
            {
                context.Check(context.CreateSession(out session),
                    "NvAPI_DRS_CreateSession");
                context.Check(context.LoadSettings(session),
                    "NvAPI_DRS_LoadSettings");
                IntPtr profile;
                context.Check(context.GetBaseProfile(session, out profile),
                    "NvAPI_DRS_GetBaseProfile");
                DrsSetting setting = NewSetting();
                setting.SettingId = PreferredPstateId;
                setting.SettingType = DrsDwordType;
                WriteDword(setting.CurrentValue, value);
                context.Check(context.SetSetting(session, profile, ref setting),
                    "NvAPI_DRS_SetSetting");
                context.Check(context.SaveSettings(session),
                    "NvAPI_DRS_SaveSettings");
            }
            finally
            {
                if (session != IntPtr.Zero)
                {
                    try { context.DestroySession(session); } catch { }
                }
            }
        }

        private static void DeletePowerModeOverride(Context context)
        {
            IntPtr session = IntPtr.Zero;
            try
            {
                context.Check(context.CreateSession(out session),
                    "NvAPI_DRS_CreateSession");
                context.Check(context.LoadSettings(session),
                    "NvAPI_DRS_LoadSettings");
                IntPtr profile;
                context.Check(context.GetBaseProfile(session, out profile),
                    "NvAPI_DRS_GetBaseProfile");
                int status = context.DeleteSetting(session, profile,
                    PreferredPstateId);
                if (status != NvapiOk && status != NvapiSettingNotFound)
                {
                    context.Check(status,
                        "NvAPI_DRS_DeleteProfileSetting");
                }
                context.Check(context.SaveSettings(session),
                    "NvAPI_DRS_SaveSettings");
            }
            finally
            {
                if (session != IntPtr.Zero)
                {
                    try { context.DestroySession(session); } catch { }
                }
            }
        }

        public static NvidiaPowerModeSnapshot ReadPowerMode()
        {
            using (Context context = new Context())
            {
                return ReadPowerMode(context);
            }
        }

        public static void SetMaximumPerformance()
        {
            using (Context context = new Context())
            {
                WritePowerMode(context, PreferMaximumPerformance);
            }
            NvidiaPowerModeSnapshot current = ReadPowerMode();
            if (!current.SettingFound || current.CurrentValue !=
                PreferMaximumPerformance || !current.HasUserOverride)
            {
                throw new InvalidOperationException(
                    "NVIDIA maximum-performance verification failed");
            }
        }

        public static void RestorePowerMode(bool hadUserOverride,
            uint originalValue)
        {
            using (Context context = new Context())
            {
                if (hadUserOverride)
                {
                    WritePowerMode(context, originalValue);
                }
                else
                {
                    DeletePowerModeOverride(context);
                }
            }
            NvidiaPowerModeSnapshot current = ReadPowerMode();
            if (hadUserOverride)
            {
                if (!current.SettingFound || !current.HasUserOverride ||
                    current.CurrentValue != originalValue)
                {
                    throw new InvalidOperationException(
                        "original NVIDIA power-mode override was not restored");
                }
            }
            else if (current.SettingFound && current.HasUserOverride)
            {
                throw new InvalidOperationException(
                    "NVIDIA power-mode override was not removed");
            }
        }
    }
}
'@
}

function Get-NvidiaPowerModeSnapshot {
    $result = [ordered]@{
        Available = $false
        SettingFound = $false
        HasUserOverride = $false
        CurrentValue = 0
        SettingLocation = 0
        Error = ''
    }
    try {
        Initialize-NvidiaDrsInterop
        $snapshot = [G11GuestLite.NvidiaDrs]::ReadPowerMode()
        $result.SettingFound = [bool]$snapshot.SettingFound
        $result.HasUserOverride = [bool]$snapshot.HasUserOverride
        $result.CurrentValue = [uint32]$snapshot.CurrentValue
        $result.SettingLocation = [uint32]$snapshot.SettingLocation
        $result.Available = $true
    } catch {
        $result.Error = $_.Exception.Message
    }
    return [pscustomobject]$result
}

function Set-NvidiaMaximumPerformance {
    $failures = New-Object 'System.Collections.Generic.List[string]'
    try {
        Initialize-NvidiaDrsInterop
        [G11GuestLite.NvidiaDrs]::SetMaximumPerformance()
        $current = Get-NvidiaPowerModeSnapshot
        if (-not [bool]$current.Available -or
            -not [bool]$current.SettingFound -or
            -not [bool]$current.HasUserOverride -or
            [uint32]$current.CurrentValue -ne $NvidiaPreferMaximumPerformance) {
            throw "NVAPI verification failed: available=$($current.Available) found=$($current.SettingFound) override=$($current.HasUserOverride) value=$($current.CurrentValue) error=$($current.Error)"
        }
        Write-Host '  NVIDIA power management mode: Prefer maximum performance' `
            -ForegroundColor DarkGray
    } catch {
        $message = "NVIDIA maximum-performance mode: $($_.Exception.Message)"
        $failures.Add($message)
        Write-Warning $message
    }
    return $failures.ToArray()
}

function Restore-NvidiaPowerModeSnapshot {
    param([AllowNull()][object]$Snapshot)

    if ($null -eq $Snapshot -or -not [bool]$Snapshot.Available) { return }
    Initialize-NvidiaDrsInterop
    [G11GuestLite.NvidiaDrs]::RestorePowerMode(
        [bool]$Snapshot.HasUserOverride,
        [uint32]$Snapshot.CurrentValue
    )
}

function Get-PowerSnapshot {
    $result = [ordered]@{
        Available = $false
        ActiveScheme = ''
        Error = ''
    }
    try {
        $text = (& powercfg.exe /GetActiveScheme 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0) {
            $result.Error = "powercfg /GetActiveScheme returned $LASTEXITCODE"
            return [pscustomobject]$result
        }
        $match = [regex]::Match($text, `
            '(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')
        if (-not $match.Success) {
            $result.Error = 'active power scheme GUID was not found'
            return [pscustomobject]$result
        }
        $result.Available = $true
        $result.ActiveScheme = $match.Value.ToLowerInvariant()
    } catch {
        $result.Error = $_.Exception.Message
    }
    return [pscustomobject]$result
}

function Set-PerformancePowerPlan {
    $failures = New-Object 'System.Collections.Generic.List[string]'
    try {
        & powercfg.exe /SetActive SCHEME_MIN *> $null
        if ($LASTEXITCODE -ne 0) {
            throw "powercfg /SetActive SCHEME_MIN returned $LASTEXITCODE"
        }
        $current = Get-PowerSnapshot
        if (-not [bool]$current.Available -or
            [string]$current.ActiveScheme -ine $HighPerformanceScheme) {
            throw "High performance scheme was not activated: $($current.Error)"
        }
        Write-Host "  power scheme: High performance ($HighPerformanceScheme)" `
            -ForegroundColor DarkGray
    } catch {
        $message = "power scheme: $($_.Exception.Message)"
        $failures.Add($message)
        Write-Warning $message
    }
    return $failures.ToArray()
}

function Restore-PowerSnapshot {
    param([AllowNull()][object]$Snapshot)

    if ($null -eq $Snapshot -or -not [bool]$Snapshot.Available) { return }
    $scheme = [string]$Snapshot.ActiveScheme
    if ($scheme -notmatch `
        '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        throw "State contains an invalid power scheme GUID: $scheme"
    }
    & powercfg.exe /SetActive $scheme *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "powercfg could not restore scheme $scheme (exit $LASTEXITCODE)"
    }
}

function Get-CurrentMachineGuid {
    $raw = [string](Get-ItemProperty -LiteralPath `
        'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid `
        -ErrorAction Stop).MachineGuid
    try {
        return ([Guid]$raw).ToString('D').ToLowerInvariant()
    } catch {
        throw "Windows MachineGuid is invalid: $raw"
    }
}

function Test-StateMachineGuid {
    param([Parameter(Mandatory = $true)][object]$State)

    $property = $State.PSObject.Properties['MachineGuid']
    if ($null -eq $property -or
        [string]::IsNullOrWhiteSpace([string]$property.Value)) {
        return $false
    }
    try {
        $saved = ([Guid]([string]$property.Value)).ToString('D').ToLowerInvariant()
    } catch {
        throw "Rollback state contains an invalid MachineGuid: $($property.Value)"
    }
    $current = Get-CurrentMachineGuid
    if ($saved -cne $current) {
        throw "State belongs to Windows MachineGuid '$saved', not '$current'."
    }
    return $true
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
    if ([int]$state.SchemaVersion -lt $MinimumSchemaVersion -or
        [int]$state.SchemaVersion -gt $SchemaVersion) {
        throw "Unsupported state schema '$($state.SchemaVersion)'."
    }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if ([string]$state.UserSid -ne $sid) {
        throw "State belongs to user SID '$($state.UserSid)', current SID is '$sid'."
    }
    $null = Test-StateMachineGuid $state
    if ([string]$state.ComputerName -ine $env:COMPUTERNAME) {
        Write-Host "Windows was renamed from '$($state.ComputerName)' to '$env:COMPUTERNAME'; the stable SID/MachineGuid binding is retained." `
            -ForegroundColor Yellow
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
        # A previously optimized clone can no longer answer
        # Get-MpComputerStatus after WinDefend/MsMpEng have become inert.  In
        # that exact state there is no live Defender engine to bypass and the
        # runtime setter below already takes the same no-op fast path.  Keep
        # refusing an unknown Tamper state whenever either engine component is
        # still active.
        $defender = Get-DefenderStatusSummary
        $engineInactive = [bool](
            [string]$defender.WinDefendState -notin @('Running', 'StartPending') -and
            -not [bool]$defender.MsMpEngProcessRunning
        )
        if (-not $engineInactive) {
            throw 'Tamper Protection state cannot be verified while the Defender engine is active. This tool will not bypass it. Check Windows Security manually, then run again.'
        }
        Write-Host 'Tamper Protection state is unavailable because the Defender engine is already inactive; continuing without a bypass.' `
            -ForegroundColor Yellow
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
- turn off all Windows Firewall profiles and disable MpsSvc startup
- turn off Windows, Store, and reviewed software auto-updaters
- turn off OneDrive/cloud sync, news/weather, and background apps
- mute the default playback endpoint without disabling Windows Audio
- order en-US/US first and zh-CN/Microsoft Pinyin second
- remove reviewed consumer apps for this user
- enable Game Mode while disabling Xbox background recording
- disable reviewed optional services/tasks and select High performance power
- set NVIDIA global power management to Prefer maximum performance
- give exact allowlisted DNF images High (never Realtime) priority
- permanently delete plain temporary files older than 24 hours from the
  current user's LocalAppData\Temp and Windows\Temp

The guest will have no built-in antivirus/firewall and will not receive security updates.
Disabling MpsSvc startup can affect network discovery, IPsec, or Windows components.
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
                -not (Test-RegistryValueMatches -Actual $current.Value `
                    -Desired $entry.Value -Type ([string]$entry.Type))) {
                if (Test-PlanRequired $entry) {
                    $shown = if ($current.ValueExisted) {
                        [string]$current.Value
                    } else { '<missing>' }
                    $issues.Add("policy not applied: $($entry.Path)\$($entry.Name) current=$shown desired=$($entry.Value)")
                }
            }
        } catch {
            $issues.Add("policy unreadable: $($entry.Path)\$($entry.Name): $($_.Exception.Message)")
        }
    }
    foreach ($entry in $RegistryRemovePlan) {
        try {
            $current = Get-RegistrySnapshot $entry
            if ([bool]$current.ValueExisted) {
                $issues.Add("startup value still present: $($entry.Path)\$($entry.Name)")
            }
        } catch {
            $issues.Add("startup value unreadable: $($entry.Path)\$($entry.Name): $($_.Exception.Message)")
        }
    }
    foreach ($plan in @(Get-CurrentServicePlans)) {
        if ([string]$plan.Name -ieq $FirewallServiceName) { continue }
        try {
            $current = Get-ServiceSnapshot $plan
            if ([bool]$current.Exists -and
                [string]$current.StartMode -ne 'Disabled' -and
                (Test-PlanRequired $plan)) {
                $issues.Add("service still enabled: $($plan.Name) start=$($current.StartMode) state=$($current.State)")
            }
        } catch {
            $issues.Add("service unreadable: $($plan.Name): $($_.Exception.Message)")
        }
    }
    foreach ($plan in @(Get-CurrentTaskPlans)) {
        try {
            $current = Get-TaskSnapshot $plan
            if ([bool]$current.Exists -and [bool]$current.Enabled -and
                (Test-PlanRequired $plan)) {
                $issues.Add("task still enabled: $($plan.Path)$($plan.Name)")
            }
        } catch {
            $issues.Add("task unreadable: $($plan.Path)$($plan.Name): $($_.Exception.Message)")
        }
    }
    $installedAppNames = @{}
    foreach ($package in @(Get-AppSnapshots)) {
        $installedAppNames[([string]$package.Name).ToLowerInvariant()] = $true
    }
    foreach ($name in $AppPlan) {
        if ($installedAppNames.ContainsKey(
            ([string]$name).ToLowerInvariant())) {
            $issues.Add("app still registered for current user: $name")
        }
    }

    $firewallPlan = @($ServicePlan | Where-Object {
        [string]$_.Name -ieq $FirewallServiceName
    }) | Select-Object -First 1
    $firewallService = if ($null -ne $firewallPlan) {
        Get-ServiceSnapshot $firewallPlan
    } else { $null }
    $firewallServiceDisabled = [bool](
        $null -ne $firewallService -and
        [bool]$firewallService.Exists -and
        [string]$firewallService.StartMode -eq 'Disabled'
    )
    if ($null -eq $firewallService -or -not [bool]$firewallService.Exists) {
        $issues.Add("Windows Firewall service is missing: $FirewallServiceName")
    } elseif (-not $firewallServiceDisabled) {
        $issues.Add("Windows Firewall service startup is not disabled: $FirewallServiceName start=$($firewallService.StartMode)")
    } elseif ([string]$firewallService.State -eq 'Running') {
        $issues.Add("Windows Firewall service is still running after restart: $FirewallServiceName")
    }

    $firewallProfiles = @(Get-FirewallSnapshots)
    if ($firewallProfiles.Count -ne 3 -and -not $firewallServiceDisabled) {
        $issues.Add("Windows Firewall profile state is incomplete: found=$($firewallProfiles.Count) expected=3")
    }
    foreach ($profile in $firewallProfiles) {
        if ([string]$profile.Enabled -ine 'False') {
            $issues.Add("Windows Firewall profile still enabled: $($profile.Name)")
        }
    }

    $enforcement = Get-EnforcementTaskSnapshot
    if (-not [bool]$enforcement.Existed -or -not [bool]$enforcement.Enabled) {
        $issues.Add("startup/logon enforcement task is missing or disabled: $EnforcementTaskPath$EnforcementTaskName")
    } elseif (-not [string]::IsNullOrWhiteSpace(
            [string]$enforcement.LastRunTime) -and
        -not [string]::IsNullOrWhiteSpace(
            [string]$enforcement.LastTaskResult) -and
        [int64]$enforcement.LastTaskResult -ne 0) {
        $issues.Add("startup/logon enforcement task last run failed: result=$($enforcement.LastTaskResult) time=$($enforcement.LastRunTime)")
    }
    if (-not (Test-Path -LiteralPath $PolicyMetadataPath -PathType Leaf)) {
        $issues.Add("local policy metadata is missing: $PolicyMetadataPath")
    }

    $languageList = Get-UserLanguageListSnapshot
    if (-not [bool]$languageList.Available) {
        $issues.Add("user language/input order cannot be read: $($languageList.Error)")
    } elseif (-not (Test-PreferredUserLanguageList $languageList)) {
        $shownOrder = @($languageList.Items | ForEach-Object {
            [string]$_.LanguageTag
        }) -join ','
        $issues.Add("user language/input order differs: current=$shownOrder desired=en-US,zh-CN(Microsoft Pinyin)")
    }

    $audio = Get-AudioEndpointSnapshot
    if (-not [bool]$audio.Available) {
        $issues.Add("default playback endpoint mute cannot be read: $($audio.Error)")
    } elseif (-not [bool]$audio.Muted) {
        $issues.Add('default playback endpoint is not muted')
    }

    $power = Get-PowerSnapshot
    if (-not [bool]$power.Available) {
        $issues.Add("active power scheme cannot be read: $($power.Error)")
    } elseif ([string]$power.ActiveScheme -ine $HighPerformanceScheme) {
        $issues.Add("High performance power scheme is not active: $($power.ActiveScheme)")
    }
    $nvidia = Get-NvidiaPowerModeSnapshot
    if (-not [bool]$nvidia.Available) {
        $issues.Add("NVIDIA power-management mode cannot be read: $($nvidia.Error)")
    } elseif (-not [bool]$nvidia.SettingFound -or
        -not [bool]$nvidia.HasUserOverride -or
        [uint32]$nvidia.CurrentValue -ne $NvidiaPreferMaximumPerformance) {
        $issues.Add("NVIDIA global power-management mode is not Prefer maximum performance: found=$($nvidia.SettingFound) override=$($nvidia.HasUserOverride) value=$($nvidia.CurrentValue)")
    }
    foreach ($snapshot in @(Get-DnfProcessSnapshots)) {
        if (-not [bool]$snapshot.Available) {
            $issues.Add("DNF process priority cannot be read: $($snapshot.Name) pid=$($snapshot.Id) error=$($snapshot.Error)")
        } elseif ([string]$snapshot.PriorityClass -cne 'High') {
            $issues.Add("DNF process does not have High priority: $($snapshot.Name) pid=$($snapshot.Id) priority=$($snapshot.PriorityClass)")
        }
    }
    foreach ($plan in $ProcessPlan) {
        if (@(Get-Process -Name ([string]$plan.Name) `
            -ErrorAction SilentlyContinue).Count -gt 0) {
            $issues.Add("background process still running: $($plan.Name)")
        }
    }

    $defender = Get-DefenderStatusSummary
    $defenderEngineInactive = [bool](
        [string]$defender.WinDefendState -notin @('Running', 'StartPending') -and
        -not [bool]$defender.MsMpEngProcessRunning
    )
    if (-not [bool]$defender.Available -and
        -not $defenderEngineInactive -and
        -not [string]::IsNullOrWhiteSpace([string]$defender.Error)) {
        $issues.Add("Defender effective state cannot be read: $($defender.Error)")
    }
    if ([bool]$defender.Available -and -not $defenderEngineInactive) {
        foreach ($name in @(
            'RealTimeProtectionEnabled', 'BehaviorMonitorEnabled',
            'IoavProtectionEnabled', 'OnAccessProtectionEnabled', 'NISEnabled'
        )) {
            if ([bool]$defender.$name) {
                $issues.Add("Defender effective state remains enabled: $name")
            }
        }
    }
    # Modern Windows protects the WinDefend service and its engine process.
    # Their residency is informational; the effective protection fields above
    # determine whether antivirus scanning is actually active.
    return $issues.ToArray()
}

function Save-AuditReportLines {
    param(
        [Parameter(Mandatory = $true)]$Lines,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $safeLabel = $Label -replace '[^A-Za-z0-9_.-]', '_'
    $path = Join-Path $ReportRoot ('{0}-{1}.txt' -f `
        (Get-Date -Format 'yyyyMMdd-HHmmss'), $safeLabel)
    $Lines | Set-Content -LiteralPath $path -Encoding UTF8
    Write-Host "Audit report: $path" -ForegroundColor Cyan
    return $path
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
    $enforcement = Get-EnforcementTaskSnapshot
    $lines.Add("enforcementTask=$EnforcementTaskPath$EnforcementTaskName exists=$($enforcement.Existed) enabled=$($enforcement.Enabled) state=$($enforcement.State) lastRun=$($enforcement.LastRunTime) lastResult=$($enforcement.LastTaskResult) log=$EnforcementLogPath")
    $lines.Add("machinePolicyFile=$MachinePolicyPath exists=$(Test-Path -LiteralPath $MachinePolicyPath -PathType Leaf)")
    $lines.Add("userPolicyFile=$UserPolicyPath exists=$(Test-Path -LiteralPath $UserPolicyPath -PathType Leaf)")
    $lines.Add("policyMetadataFile=$PolicyMetadataPath exists=$(Test-Path -LiteralPath $PolicyMetadataPath -PathType Leaf)")
    $audio = Get-AudioEndpointSnapshot
    $lines.Add("audioEndpointAvailable=$($audio.Available) masterMuted=$($audio.Muted) desiredMuted=True error=$($audio.Error)")
    $languageList = Get-UserLanguageListSnapshot
    $languageOrder = @($languageList.Items | ForEach-Object {
        '{0}[{1}]' -f [string]$_.LanguageTag,
            (@($_.InputMethodTips) -join ',')
    }) -join ';'
    $lines.Add("userLanguageListAvailable=$($languageList.Available) order=$languageOrder desired=en-US/US,zh-CN/Microsoft-Pinyin error=$($languageList.Error)")
    $nvidia = Get-NvidiaPowerModeSnapshot
    $lines.Add("nvidiaDrsAvailable=$($nvidia.Available) settingId=0x$($NvidiaPreferredPstateId.ToString('X8')) found=$($nvidia.SettingFound) userOverride=$($nvidia.HasUserOverride) currentValue=$($nvidia.CurrentValue) desiredValue=$NvidiaPreferMaximumPerformance desired=Prefer-maximum-performance location=$($nvidia.SettingLocation) error=$($nvidia.Error)")
    $dnfSnapshots = @(Get-DnfProcessSnapshots)
    if ($dnfSnapshots.Count -eq 0) {
        $lines.Add('dnfProcessFound=False desiredPriority=High persistentImages=DNF.exe,DNFClient.exe,DNFChina.exe,DNFLauncher.exe')
    } else {
        foreach ($snapshot in $dnfSnapshots) {
            $lines.Add("dnfProcessFound=True name=$($snapshot.Name) pid=$($snapshot.Id) priority=$($snapshot.PriorityClass) desiredPriority=High available=$($snapshot.Available) error=$($snapshot.Error)")
        }
    }
    if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
        try {
            $reportState = Read-State
            $cleanupProperty = $reportState.PSObject.Properties[
                'LastTemporaryCleanup']
            if ($null -ne $cleanupProperty) {
                $cleanup = $cleanupProperty.Value
                $lines.Add("lastTemporaryCleanup=$($cleanup.CompletedUtc) minimumAgeHours=$($cleanup.MinimumAgeHours) rootsProcessed=$($cleanup.RootsProcessed) deletedFiles=$($cleanup.DeletedFiles) deletedDirectories=$($cleanup.DeletedDirectories) reclaimedBytes=$($cleanup.ReclaimedBytes) skippedItems=$($cleanup.SkippedItems) rootErrors=$(@($cleanup.RootErrors).Count) reversible=False")
                foreach ($rootResult in @($cleanup.Roots)) {
                    $lines.Add("temporaryRoot=$($rootResult.Root) deletedFiles=$($rootResult.DeletedFiles) deletedDirectories=$($rootResult.DeletedDirectories) reclaimedBytes=$($rootResult.ReclaimedBytes) skippedItems=$($rootResult.SkippedItems) errors=$(@($rootResult.Errors).Count)")
                    foreach ($detail in @($rootResult.Errors)) {
                        $lines.Add("temporaryItemKept=$detail")
                    }
                }
                foreach ($detail in @($cleanup.RootErrors)) {
                    $lines.Add("temporaryRootKept=$detail")
                }
            } else {
                $lines.Add('lastTemporaryCleanup=<not-run> reversible=False')
            }
        } catch {
            $lines.Add("lastTemporaryCleanup=<unreadable> error=$($_.Exception.Message) reversible=False")
        }
    } else {
        $lines.Add('lastTemporaryCleanup=<not-run> reversible=False')
    }
    if ($Label -in @('before-apply', 'after-apply')) {
        # Apply already builds its rollback inventory separately. Repeating
        # every scheduled-task/Appx/CIM query here used several minutes on
        # VM1 and provided no additional safety. Keep a fast security/runtime
        # checkpoint; 02-Audit.cmd remains the full measured inventory.
        $lines.Add('inventoryMode=lightweight (full inventory is manual-audit)')
        foreach ($serviceName in @('MpsSvc', 'BFE')) {
            try {
                $service = Get-CimInstance Win32_Service `
                    -Filter "Name='$serviceName'" -ErrorAction Stop
                $lines.Add("service=$serviceName start=$($service.StartMode) state=$($service.State) pid=$($service.ProcessId)")
            } catch {
                $lines.Add("service=$serviceName error=$($_.Exception.Message)")
            }
        }
        $power = Get-PowerSnapshot
        $lines.Add("powerAvailable=$($power.Available) activeScheme=$($power.ActiveScheme) desiredScheme=$HighPerformanceScheme error=$($power.Error)")
        $lines.Add('cpuSampleSkipped=True (run 02-Audit.cmd after restart for the measured sample)')
        return (Save-AuditReportLines -Lines $lines -Label $Label)
    }
    foreach ($product in @(Get-AntivirusProducts)) {
        $lines.Add("antivirus=$($product.Name) state=$($product.State) path=$($product.Path)")
    }
    foreach ($entry in $RegistryRemovePlan) {
        $saved = Get-RegistrySnapshot $entry
        $current = if ($saved.ValueExisted) { [string]$saved.Value } else { '<missing>' }
        $lines.Add("group=$($entry.Group) path=$($entry.Path) name=$($entry.Name) current=$current desired=<missing>")
    }
    $lines.Add('')

    $lines.Add('[policy registry]')
    foreach ($entry in $RegistryPlan) {
        $saved = Get-RegistrySnapshot $entry
        $current = if ($saved.ValueExisted) { [string]$saved.Value } else { '<missing>' }
        $lines.Add("group=$($entry.Group) path=$($entry.Path) name=$($entry.Name) current=$current desired=$($entry.Value) required=$(Test-PlanRequired $entry)")
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

    $lines.Add('[Windows Firewall profiles]')
    $firewallProfiles = @(Get-FirewallSnapshots)
    if ($firewallProfiles.Count -eq 0) {
        $lines.Add('state=<unavailable> desiredEnabled=False')
    } else {
        foreach ($profile in $firewallProfiles) {
            $lines.Add("name=$($profile.Name) enabled=$($profile.Enabled) desiredEnabled=False")
        }
    }
    $lines.Add('')

    $lines.Add('[services]')
    foreach ($plan in @(Get-CurrentServicePlans)) {
        $saved = Get-ServiceSnapshot $plan
        $lines.Add("group=$($plan.Group) name=$($plan.Name) exists=$($saved.Exists) start=$($saved.StartMode) state=$($saved.State) required=$(Test-PlanRequired $plan) purpose=$($plan.Purpose)")
    }
    $lines.Add('')

    $lines.Add('[scheduled tasks]')
    foreach ($plan in @(Get-CurrentTaskPlans)) {
        $saved = Get-TaskSnapshot $plan
        $lines.Add("group=$($plan.Group) task=$($plan.Path)$($plan.Name) exists=$($saved.Exists) enabled=$($saved.Enabled) required=$(Test-PlanRequired $plan)")
    }
    $lines.Add('')

    $lines.Add('[runtime and performance]')
    $power = Get-PowerSnapshot
    $lines.Add("powerAvailable=$($power.Available) activeScheme=$($power.ActiveScheme) desiredScheme=$HighPerformanceScheme error=$($power.Error)")
    foreach ($plan in $ProcessPlan) {
        $running = @(Get-Process -Name ([string]$plan.Name) `
            -ErrorAction SilentlyContinue).Count -gt 0
        $lines.Add("group=$($plan.Group) process=$($plan.Name) running=$running purpose=$($plan.Purpose)")
    }
    $lines.Add('')

    $lines.Add('[instant process CPU sample]')
    if ($Label -eq 'manual-audit') {
        try {
            $performance = @(Get-CimInstance `
                Win32_PerfFormattedData_PerfProc_Process -ErrorAction Stop)
            $mps = Get-CimInstance Win32_Service -Filter "Name='MpsSvc'" `
                -ErrorAction Stop
            $mpsCpu = if ([uint32]$mps.ProcessId -eq 0 -or
                [string]$mps.State -ne 'Running') {
                @()
            } else {
                @($performance | Where-Object {
                    [uint32]$_.IDProcess -eq [uint32]$mps.ProcessId
                } | Select-Object -First 1)
            }
            $shownMpsCpu = if ([string]$mps.State -ne 'Running') {
                0
            } elseif ($mpsCpu.Count -gt 0) {
                [uint64]$mpsCpu[0].PercentProcessorTime
            } else { '<unavailable>' }
            $lines.Add("firewallService=MpsSvc state=$($mps.State) pid=$($mps.ProcessId) hostProcessCpuPercent=$shownMpsCpu profilesDesired=False")
            foreach ($row in @($performance | Where-Object {
                $_.Name -notin @('_Total', 'Idle')
            } | Sort-Object PercentProcessorTime -Descending | `
                Select-Object -First 10)) {
                $lines.Add("process=$($row.Name) pid=$($row.IDProcess) cpuPercent=$($row.PercentProcessorTime)")
            }
        } catch {
            $lines.Add("cpuSampleError=$($_.Exception.Message)")
        }
    } else {
        $lines.Add("cpuSampleSkipped=True label=$Label (run 02-Audit.cmd after restart for the measured sample)")
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
    $lines.Add('BCD and boot integrity; kernel and NVIDIA/vGPU driver files (only the installed driver user-mode NVAPI DRS setting is changed); Defender/firewall service files and ACLs; BFE and other core networking services; protected-but-inert DoSvc/UpdateOrchestrator objects; firewall saved rules; Windows Audio service/device (only the default playback endpoint is muted); printing; BITS; CryptSvc; AppXSvc; ClipSVC; Microsoft Edge/WebView2 application binaries; Calculator; Photos; Paint; Notepad; DesktopAppInstaller; VCLibs/.NET/UI.Xaml dependencies; provisioned Appx payloads.')

    return (Save-AuditReportLines -Lines $lines -Label $Label)
}

function New-OriginalState {
    $os = Get-CimInstance Win32_OperatingSystem
    $servicePlans = @(Get-CurrentServicePlans)
    $taskPlans = @(Get-CurrentTaskPlans)
    $state = [ordered]@{
        SchemaVersion = $SchemaVersion
        CreatedUtc = [DateTime]::UtcNow.ToString('o')
        ComputerName = $env:COMPUTERNAME
        MachineGuid = Get-CurrentMachineGuid
        UserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        UserName = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        OsCaption = [string]$os.Caption
        OsBuild = [string]$os.BuildNumber
        DefenderPreferences = @(Get-DefenderPreferenceSnapshots)
        FirewallProfiles = @(Get-FirewallSnapshots)
        AudioEndpoint = Get-AudioEndpointSnapshot
        UserLanguageList = Get-UserLanguageListSnapshot
        NvidiaPowerMode = Get-NvidiaPowerModeSnapshot
        DnfProcesses = @(Get-DnfProcessSnapshots)
        Registry = @(Get-AllRegistryPlans | ForEach-Object { Get-RegistrySnapshot $_ })
        Services = @($servicePlans | ForEach-Object { Get-ServiceSnapshot $_ })
        Tasks = @($taskPlans | ForEach-Object { Get-TaskSnapshot $_ })
        Apps = @(Get-AppSnapshots)
        AppBaselineNames = @($AppPlan)
        Power = (Get-PowerSnapshot)
        PolicyFiles = [pscustomobject]@{
            Machine = Get-PolicyFileSnapshot -Scope 'Machine' `
                -Path $MachinePolicyPath
            User = Get-PolicyFileSnapshot -Scope 'User' `
                -Path $UserPolicyPath
            Metadata = Get-PolicyFileSnapshot -Scope 'Metadata' `
                -Path $PolicyMetadataPath
        }
        EnforcementTask = Get-EnforcementTaskSnapshot
    }
    Save-StateAtomically $state
    return (Read-State)
}

function Set-StateProperty {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][object]$Value
    )

    $property = $State.PSObject.Properties[$Name]
    if ($null -eq $property) {
        Add-Member -InputObject $State -MemberType NoteProperty `
            -Name $Name -Value $Value
    } else {
        $property.Value = $Value
    }
}

function Ensure-CurrentBaseline {
    param([Parameter(Mandatory = $true)][object]$State)

    $changed = [int]$State.SchemaVersion -ne $SchemaVersion
    $machineGuidProperty = $State.PSObject.Properties['MachineGuid']
    if ($null -eq $machineGuidProperty -or
        [string]::IsNullOrWhiteSpace([string]$machineGuidProperty.Value)) {
        Set-StateProperty -State $State -Name MachineGuid `
            -Value (Get-CurrentMachineGuid)
        $changed = $true
    }
    if ([string]$State.ComputerName -ine $env:COMPUTERNAME) {
        Set-StateProperty -State $State -Name ComputerName `
            -Value $env:COMPUTERNAME
        $changed = $true
    }
    $currentUserName = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    if ([string]$State.UserName -ine $currentUserName) {
        Set-StateProperty -State $State -Name UserName -Value $currentUserName
        $changed = $true
    }
    if ($null -eq $State.PSObject.Properties['DefenderPreferences']) {
        Set-StateProperty -State $State -Name DefenderPreferences `
            -Value @(Get-DefenderPreferenceSnapshots)
        $changed = $true
    }
    if ($null -eq $State.PSObject.Properties['FirewallProfiles']) {
        Set-StateProperty -State $State -Name FirewallProfiles `
            -Value @(Get-FirewallSnapshots)
        $changed = $true
    }
    if ($null -eq $State.PSObject.Properties['AudioEndpoint']) {
        Set-StateProperty -State $State -Name AudioEndpoint `
            -Value (Get-AudioEndpointSnapshot)
        $changed = $true
    }
    if ($null -eq $State.PSObject.Properties['UserLanguageList']) {
        Set-StateProperty -State $State -Name UserLanguageList `
            -Value (Get-UserLanguageListSnapshot)
        $changed = $true
    }
    if ($null -eq $State.PSObject.Properties['NvidiaPowerMode']) {
        Set-StateProperty -State $State -Name NvidiaPowerMode `
            -Value (Get-NvidiaPowerModeSnapshot)
        $changed = $true
    }
    if ($null -eq $State.PSObject.Properties['DnfProcesses']) {
        Set-StateProperty -State $State -Name DnfProcesses `
            -Value @(Get-DnfProcessSnapshots)
        $changed = $true
    }

    $registry = New-Object 'System.Collections.Generic.List[object]'
    $registrySeen = @{}
    foreach ($snapshot in @($State.Registry)) {
        $key = ("$($snapshot.Path)|$($snapshot.Name)").ToLowerInvariant()
        if (-not $registrySeen.ContainsKey($key)) {
            $registry.Add($snapshot)
            $registrySeen[$key] = $true
        }
    }
    foreach ($plan in @(Get-AllRegistryPlans)) {
        $key = ("$($plan.Path)|$($plan.Name)").ToLowerInvariant()
        if (-not $registrySeen.ContainsKey($key)) {
            $registry.Add((Get-RegistrySnapshot $plan))
            $registrySeen[$key] = $true
            $changed = $true
        }
    }
    Set-StateProperty -State $State -Name Registry -Value $registry.ToArray()

    $services = New-Object 'System.Collections.Generic.List[object]'
    $serviceSeen = @{}
    foreach ($snapshot in @($State.Services)) {
        $key = ([string]$snapshot.Name).ToLowerInvariant()
        if (-not $serviceSeen.ContainsKey($key)) {
            $services.Add($snapshot)
            $serviceSeen[$key] = $true
        }
    }
    foreach ($plan in @(Get-CurrentServicePlans)) {
        $key = ([string]$plan.Name).ToLowerInvariant()
        if (-not $serviceSeen.ContainsKey($key)) {
            $services.Add((Get-ServiceSnapshot $plan))
            $serviceSeen[$key] = $true
            $changed = $true
        }
    }
    Set-StateProperty -State $State -Name Services -Value $services.ToArray()

    $tasks = New-Object 'System.Collections.Generic.List[object]'
    $taskSeen = @{}
    foreach ($snapshot in @($State.Tasks)) {
        $key = ("$($snapshot.Path)|$($snapshot.Name)").ToLowerInvariant()
        if (-not $taskSeen.ContainsKey($key)) {
            $tasks.Add($snapshot)
            $taskSeen[$key] = $true
        }
    }
    foreach ($plan in @(Get-CurrentTaskPlans)) {
        $key = ("$($plan.Path)|$($plan.Name)").ToLowerInvariant()
        if (-not $taskSeen.ContainsKey($key)) {
            $tasks.Add((Get-TaskSnapshot $plan))
            $taskSeen[$key] = $true
            $changed = $true
        }
    }
    Set-StateProperty -State $State -Name Tasks -Value $tasks.ToArray()

    $apps = New-Object 'System.Collections.Generic.List[object]'
    $appSeen = @{}
    foreach ($snapshot in @($State.Apps)) {
        $key = ([string]$snapshot.PackageFullName).ToLowerInvariant()
        if (-not $appSeen.ContainsKey($key)) {
            $apps.Add($snapshot)
            $appSeen[$key] = $true
        }
    }
    $baselineNames = @()
    if ($null -ne $State.PSObject.Properties['AppBaselineNames']) {
        $baselineNames = @($State.AppBaselineNames)
    }
    $baselineNameSet = @{}
    foreach ($name in $baselineNames) {
        $baselineNameSet[([string]$name).ToLowerInvariant()] = $true
    }
    $currentApps = @(Get-AppSnapshots)
    foreach ($name in $AppPlan) {
        $nameKey = ([string]$name).ToLowerInvariant()
        if ($baselineNameSet.ContainsKey($nameKey)) { continue }
        foreach ($snapshot in @($currentApps | Where-Object {
            [string]$_.Name -ieq [string]$name
        })) {
            $key = ([string]$snapshot.PackageFullName).ToLowerInvariant()
            if (-not $appSeen.ContainsKey($key)) {
                $apps.Add($snapshot)
                $appSeen[$key] = $true
            }
        }
        $baselineNameSet[$nameKey] = $true
        $changed = $true
    }
    Set-StateProperty -State $State -Name Apps -Value $apps.ToArray()
    Set-StateProperty -State $State -Name AppBaselineNames `
        -Value @($AppPlan)

    if ($null -eq $State.PSObject.Properties['Power']) {
        Set-StateProperty -State $State -Name Power -Value (Get-PowerSnapshot)
        $changed = $true
    }
    if ($null -eq $State.PSObject.Properties['PolicyFiles']) {
        Set-StateProperty -State $State -Name PolicyFiles -Value `
            ([pscustomobject]@{
                Machine = Get-PolicyFileSnapshot -Scope 'Machine' `
                    -Path $MachinePolicyPath
                User = Get-PolicyFileSnapshot -Scope 'User' `
                    -Path $UserPolicyPath
                Metadata = Get-PolicyFileSnapshot -Scope 'Metadata' `
                    -Path $PolicyMetadataPath
            })
        $changed = $true
    } elseif ($null -eq $State.PolicyFiles.PSObject.Properties['Metadata']) {
        Add-Member -InputObject $State.PolicyFiles -MemberType NoteProperty `
            -Name Metadata -Value (Get-PolicyFileSnapshot -Scope 'Metadata' `
                -Path $PolicyMetadataPath)
        $changed = $true
    }
    if ($null -eq $State.PSObject.Properties['EnforcementTask']) {
        Set-StateProperty -State $State -Name EnforcementTask `
            -Value (Get-EnforcementTaskSnapshot)
        $changed = $true
    }
    Set-StateProperty -State $State -Name SchemaVersion -Value $SchemaVersion

    if ($changed) {
        Save-StateAtomically $State
        Write-Host 'Upgraded the original rollback baseline for Guest Lite 2.6.' `
            -ForegroundColor Yellow
        return (Read-State)
    }
    return $State
}

function Invoke-Apply {
    param([switch]$UnattendedClone)

    Assert-Windows10 | Out-Null
    Assert-InteractiveAdministrator
    Assert-DefenderCanBeConfigured
    if ($UnattendedClone) {
        Write-Host 'Trusted G-11 clone initialization requested the full profile; interactive confirmation is suppressed.' `
            -ForegroundColor Yellow
    } else {
        Confirm-FullProfile
    }
    Initialize-StateRoot
    Install-LocalTools

    # Clone finalization already authenticates the payload, captures the full
    # rollback baseline below, performs a measured SYSTEM enforcement run, and
    # publishes one strict host-ready receipt after reboot. Avoid two duplicate
    # full WMI/Appx audit passes in that trusted path; interactive Apply keeps
    # both human-readable reports.
    if (-not $UnattendedClone) {
        $null = New-AuditReport 'before-apply'
    }
    if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
        $state = Read-State
        Write-Host "Reusing original rollback baseline: $StatePath" `
            -ForegroundColor Yellow
    } else {
        $state = New-OriginalState
        Write-Host "Saved original rollback baseline: $StatePath" `
            -ForegroundColor Green
    }
    $state = Ensure-CurrentBaseline $state
    $failures = New-Object 'System.Collections.Generic.List[string]'

    Write-Host '[persistence] Writing native local policy and installing the SYSTEM enforcement task' `
        -ForegroundColor Cyan
    Write-ManagedPolicyFiles -Snapshots $state.PolicyFiles
    Write-ManagedPolicyMetadata -Snapshot $state.PolicyFiles.Metadata
    Register-EnforcementTask -State $state
    foreach ($failure in @(Refresh-LocalPolicy)) {
        $failures.Add($failure)
    }

    Write-Host '[1/12] Applying policy values/input order and disabling startup entries' `
        -ForegroundColor Cyan
    foreach ($failure in @(Restore-RetiredRegistryValues $state)) {
        $failures.Add($failure)
    }
    foreach ($entry in $RegistryPlan) {
        try { Set-PlannedRegistryValue $entry } catch {
            $message = "policy $($entry.Path)\$($entry.Name): $($_.Exception.Message)"
            if (Test-PlanRequired $entry) {
                $failures.Add($message)
                Write-Warning $message
            } else {
                Write-Host "  protected legacy policy retained: $($entry.Name)" `
                    -ForegroundColor DarkYellow
            }
        }
    }
    foreach ($entry in $RegistryRemovePlan) {
        try { Remove-PlannedRegistryValue $entry } catch {
            $message = "startup $($entry.Path)\$($entry.Name): $($_.Exception.Message)"
            $failures.Add($message)
            Write-Warning $message
        }
    }
    foreach ($failure in @(Set-PreferredUserLanguageList)) {
        $failures.Add($failure)
    }

    Write-Host '[2/12] Disabling live Defender scanning and cancelling current scan' `
        -ForegroundColor Cyan
    foreach ($failure in @(Set-DefenderRuntimePreferences)) {
        $failures.Add($failure)
    }

    Write-Host '[3/12] Disabling Windows Firewall profiles and MpsSvc startup' `
        -ForegroundColor Cyan
    foreach ($failure in @(Disable-FirewallProfiles)) {
        $failures.Add($failure)
    }
    foreach ($failure in @(Disable-FirewallService)) {
        $failures.Add($failure)
    }

    Write-Host '[4/12] Disabling reviewed services' -ForegroundColor Cyan
    foreach ($failure in @(Disable-PlannedServices)) { $failures.Add($failure) }

    Write-Host '[5/12] Disabling reviewed scheduled tasks' -ForegroundColor Cyan
    foreach ($failure in @(Disable-PlannedTasks)) { $failures.Add($failure) }

    Write-Host '[6/12] Removing reviewed apps for the current user' `
        -ForegroundColor Cyan
    foreach ($failure in @(Remove-PlannedApps)) {
        $failures.Add($failure)
    }

    Write-Host '[7/12] Stopping reviewed background processes' `
        -ForegroundColor Cyan
    foreach ($failure in @(Stop-PlannedProcesses)) {
        $failures.Add($failure)
    }

    Write-Host '[8/12] Muting the default playback endpoint' `
        -ForegroundColor Cyan
    foreach ($failure in @(Set-DefaultAudioMuted -Muted $true)) {
        $failures.Add($failure)
    }

    Write-Host '[9/12] Selecting the built-in High performance power plan' `
        -ForegroundColor Cyan
    foreach ($failure in @(Set-PerformancePowerPlan)) {
        $failures.Add($failure)
    }

    Write-Host '[10/12] Setting NVIDIA global power mode to Prefer maximum performance' `
        -ForegroundColor Cyan
    foreach ($failure in @(Set-NvidiaMaximumPerformance)) {
        $failures.Add($failure)
    }

    Write-Host '[11/12] Checking allowlisted DNF processes and applying High priority' `
        -ForegroundColor Cyan
    foreach ($failure in @(Set-DnfProcessPriority)) {
        $failures.Add($failure)
    }

    Write-Host '[12/12] Clearing allowlisted temporary files older than 24 hours' `
        -ForegroundColor Cyan
    $cleanup = Clear-SafeTemporaryFiles
    Set-StateProperty -State $state -Name LastTemporaryCleanup -Value $cleanup
    Save-StateAtomically $state
    if ([int]$cleanup.RootsProcessed -eq 0) {
        $failures.Add('temporary cleanup: neither fixed allowlisted root could be processed')
    }

    if (-not $UnattendedClone) {
        $null = New-AuditReport 'after-apply'
    }
    Write-Host ''
    if ($failures.Count -gt 0) {
        Write-Host "APPLY PARTIAL: $($failures.Count) item(s) were protected or failed." `
            -ForegroundColor Yellow
        foreach ($failure in $failures) { Write-Host "  - $failure" }
        Write-Host 'The rollback baseline is intact. Reboot, then run 02-Audit.cmd for the complete Defender/firewall/update/cloud/performance verification.'
        return 3
    }
    Write-Host 'APPLY PASS: full guest-lite profile is staged.' -ForegroundColor Green
    Write-Host 'Restart Windows now. After restart, run 02-Audit.cmd to verify every profile item.'
    return 0
}

function Get-EnforcementRegistryEntry {
    param(
        [Parameter(Mandatory = $true)][object]$Entry,
        [Parameter(Mandatory = $true)][string]$TargetUserSid
    )

    $path = [string]$Entry.Path
    if ($path.StartsWith('HKCU:\', [StringComparison]::OrdinalIgnoreCase)) {
        $path = 'Registry::HKEY_USERS\{0}\{1}' -f `
            $TargetUserSid, $path.Substring(6)
    }
    return [pscustomobject]@{
        Path = $path
        Name = [string]$Entry.Name
        Type = if ($null -ne $Entry.PSObject.Properties['Type']) {
            [string]$Entry.Type
        } else { '' }
        Value = if ($null -ne $Entry.PSObject.Properties['Value']) {
            $Entry.Value
        } else { $null }
        Group = [string]$Entry.Group
        Required = (Test-PlanRequired $Entry)
    }
}

function Invoke-Enforce {
    Assert-Windows10 | Out-Null
    if ([string]::IsNullOrWhiteSpace($UserSid)) {
        throw 'Enforce mode requires the saved interactive-user SID.'
    }
    $failures = New-Object 'System.Collections.Generic.List[string]'
    $log = New-Object 'System.Collections.Generic.List[string]'
    $log.Add("generated=$([DateTime]::Now.ToString('o')) mode=Enforce")
    try {
        $state = Read-EnforcementState -ExpectedUserSid $UserSid
        $log.Add("identity=validated computer=$env:COMPUTERNAME machineGuid=$(Get-CurrentMachineGuid) sid=$UserSid")
    } catch {
        $message = "state identity: $($_.Exception.Message)"
        $log.Add("failure=$message")
        $log.Add('result=failed failures=1')
        try { $log | Set-Content -LiteralPath $EnforcementLogPath -Encoding UTF8 } catch { }
        throw
    }

    try {
        Write-ManagedPolicyFiles -Snapshots $state.PolicyFiles
        Write-ManagedPolicyMetadata -Snapshot $state.PolicyFiles.Metadata
        $log.Add('localPolicy=written registryPol=True gptIni=True')
    } catch {
        $message = "local policy persistence: $($_.Exception.Message)"
        $failures.Add($message)
        $log.Add("failure=$message")
    }
    foreach ($failure in @(Refresh-LocalPolicy)) {
        $failures.Add($failure)
        $log.Add("failure=$failure")
    }

    $userHive = "Registry::HKEY_USERS\$UserSid"
    $userHiveLoaded = Test-Path -LiteralPath $userHive -PathType Container
    $log.Add("userHiveLoaded=$userHiveLoaded sid=$UserSid")
    foreach ($entry in $RegistryPlan) {
        if (([string]$entry.Path).StartsWith(
                'HKCU:\', [StringComparison]::OrdinalIgnoreCase) -and
            -not $userHiveLoaded) {
            continue
        }
        $target = Get-EnforcementRegistryEntry $entry $UserSid
        try {
            Set-PlannedRegistryValue $target
        } catch {
            $message = "policy $($entry.Path)\$($entry.Name): $($_.Exception.Message)"
            if (Test-PlanRequired $entry) {
                $failures.Add($message)
                $log.Add("failure=$message")
            } else {
                $log.Add("optional=$message")
            }
        }
    }
    foreach ($entry in $RegistryRemovePlan) {
        if (([string]$entry.Path).StartsWith(
                'HKCU:\', [StringComparison]::OrdinalIgnoreCase) -and
            -not $userHiveLoaded) {
            continue
        }
        $target = Get-EnforcementRegistryEntry $entry $UserSid
        try {
            Remove-PlannedRegistryValue $target
        } catch {
            $message = "startup $($entry.Path)\$($entry.Name): $($_.Exception.Message)"
            $failures.Add($message)
            $log.Add("failure=$message")
        }
    }

    foreach ($failure in @(Set-DefenderRuntimePreferences)) {
        $failures.Add($failure)
        $log.Add("failure=$failure")
    }
    foreach ($failure in @(Disable-FirewallProfiles)) {
        $failures.Add($failure)
        $log.Add("failure=$failure")
    }
    foreach ($failure in @(Disable-FirewallService)) {
        $failures.Add($failure)
        $log.Add("failure=$failure")
    }
    foreach ($failure in @(Disable-PlannedServices)) {
        $failures.Add($failure)
        $log.Add("failure=$failure")
    }
    $log.Add('services=reviewed-disabled')
    foreach ($failure in @(Disable-PlannedTasks)) {
        $failures.Add($failure)
        $log.Add("failure=$failure")
    }
    $log.Add('tasks=reviewed-disabled')
    foreach ($failure in @(Stop-PlannedProcesses)) {
        $failures.Add($failure)
        $log.Add("failure=$failure")
    }
    $log.Add('processes=reviewed-stopped')
    $audioFailures = @(Set-DefaultAudioMuted -Muted $true)
    foreach ($failure in $audioFailures) {
        $failures.Add($failure)
        $log.Add("failure=$failure")
    }
    if ($audioFailures.Count -eq 0) {
        $log.Add('audio=default-render-muted')
    }
    foreach ($failure in @(Set-PerformancePowerPlan)) {
        $failures.Add($failure)
        $log.Add("failure=$failure")
    }
    $log.Add('power=high-performance')
    foreach ($failure in @(Set-NvidiaMaximumPerformance)) {
        $failures.Add($failure)
        $log.Add("failure=$failure")
    }
    $log.Add('nvidiaPowerMode=prefer-maximum-performance')
    foreach ($failure in @(Set-DnfProcessPriority)) {
        $failures.Add($failure)
        $log.Add("failure=$failure")
    }
    $log.Add('dnfPriority=high-if-running')
    $log.Add("result=$(if ($failures.Count -eq 0) { 'pass' } else { 'partial' }) failures=$($failures.Count)")
    $log | Set-Content -LiteralPath $EnforcementLogPath -Encoding UTF8
    if ($failures.Count -gt 0) { return 3 }
    return 0
}

function Invoke-Rollback {
    Assert-Windows10 | Out-Null
    Assert-InteractiveAdministrator
    Initialize-StateRoot
    $state = Read-State
    $failures = New-Object 'System.Collections.Generic.List[string]'

    Write-Host '[1/13] Removing the Guest Lite enforcement task' -ForegroundColor Cyan
    try {
        Remove-EnforcementTask $state.EnforcementTask
    } catch {
        $message = "enforcement task: $($_.Exception.Message)"
        $failures.Add($message)
        Write-Warning $message
    }

    Write-Host '[2/13] Restoring native local-policy files' -ForegroundColor Cyan
    foreach ($failure in @(Restore-PolicyFileSnapshots $state.PolicyFiles)) {
        $failures.Add($failure)
        Write-Warning $failure
    }

    Write-Host '[3/13] Restoring the original user language/input order' `
        -ForegroundColor Cyan
    if ($null -ne $state.PSObject.Properties['UserLanguageList']) {
        try { Restore-UserLanguageListSnapshot $state.UserLanguageList } catch {
            $message = "user language/input order: $($_.Exception.Message)"
            $failures.Add($message)
            Write-Warning $message
        }
    }

    Write-Host '[4/13] Restoring registry policy/startup values' -ForegroundColor Cyan
    foreach ($snapshot in @($state.Registry)) {
        try { Restore-RegistrySnapshot $snapshot } catch {
            $message = "policy $($snapshot.Path)\$($snapshot.Name): $($_.Exception.Message)"
            $failures.Add($message)
            Write-Warning $message
        }
    }

    Write-Host '[5/13] Restoring the NVIDIA global power-mode baseline' `
        -ForegroundColor Cyan
    if ($null -ne $state.PSObject.Properties['NvidiaPowerMode']) {
        try { Restore-NvidiaPowerModeSnapshot $state.NvidiaPowerMode } catch {
            $message = "NVIDIA power mode: $($_.Exception.Message)"
            $failures.Add($message)
            Write-Warning $message
        }
    }

    Write-Host '[6/13] Restoring Defender runtime preferences' -ForegroundColor Cyan
    $defenderSnapshots = @()
    if ($null -ne $state.PSObject.Properties['DefenderPreferences']) {
        $defenderSnapshots = @($state.DefenderPreferences)
    }
    foreach ($failure in @(
        Restore-DefenderPreferenceSnapshots $defenderSnapshots
    )) {
        $failures.Add($failure)
    }

    Write-Host '[7/13] Restoring service startup/running state' -ForegroundColor Cyan
    foreach ($snapshot in @($state.Services)) {
        try { Restore-ServiceSnapshot $snapshot } catch {
            $message = "service $($snapshot.Name): $($_.Exception.Message)"
            $failures.Add($message)
            Write-Warning $message
        }
    }

    Write-Host '[8/13] Restoring Windows Firewall profiles' -ForegroundColor Cyan
    $firewallSnapshots = @()
    if ($null -ne $state.PSObject.Properties['FirewallProfiles']) {
        $firewallSnapshots = @($state.FirewallProfiles)
    }
    foreach ($failure in @(
        Restore-FirewallSnapshots $firewallSnapshots
    )) {
        $failures.Add($failure)
    }

    Write-Host '[9/13] Restoring scheduled task enabled state' -ForegroundColor Cyan
    foreach ($snapshot in @($state.Tasks)) {
        try { Restore-TaskSnapshot $snapshot } catch {
            $message = "task $($snapshot.Path)$($snapshot.Name): $($_.Exception.Message)"
            $failures.Add($message)
            Write-Warning $message
        }
    }

    Write-Host '[10/13] Re-registering removed current-user apps' `
        -ForegroundColor Cyan
    foreach ($failure in @(Restore-PlannedApps @($state.Apps))) {
        $failures.Add($failure)
    }

    Write-Host '[11/13] Restoring the original audio mute state' `
        -ForegroundColor Cyan
    if ($null -ne $state.PSObject.Properties['AudioEndpoint']) {
        try { Restore-AudioEndpointSnapshot $state.AudioEndpoint } catch {
            $message = "audio mute: $($_.Exception.Message)"
            $failures.Add($message)
            Write-Warning $message
        }
    }

    Write-Host '[12/13] Restoring priorities of DNF processes that survived since Apply' `
        -ForegroundColor Cyan
    if ($null -ne $state.PSObject.Properties['DnfProcesses']) {
        foreach ($failure in @(
            Restore-DnfProcessSnapshots @($state.DnfProcesses)
        )) {
            $failures.Add($failure)
        }
    }

    Write-Host '[13/13] Restoring the original power scheme' -ForegroundColor Cyan
    if ($null -ne $state.PSObject.Properties['Power']) {
        try { Restore-PowerSnapshot $state.Power } catch {
            $message = "power scheme: $($_.Exception.Message)"
            $failures.Add($message)
            Write-Warning $message
        }
    }

    Write-Host 'Temporary files deleted during Apply are not recreated by Rollback.' `
        -ForegroundColor Yellow

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
        'CloneApply' { Invoke-Apply -UnattendedClone }
        'Rollback' { Invoke-Rollback }
        'Enforce' { Invoke-Enforce }
    }
    exit [int]$exitCode
} catch {
    $caught = $_
    Write-Host ''
    Write-Host "FAILED: $($caught.Exception.Message)" -ForegroundColor Red
    $invocation = $caught.InvocationInfo
    if ($null -ne $invocation -and
        [int]$invocation.ScriptLineNumber -gt 0) {
        $failedCommand = '<script>'
        $myCommand = $invocation.MyCommand
        if ($null -ne $myCommand) {
            # A bare `throw` can report a ScriptBlock-like command object that
            # has no Name property on Windows PowerShell 5.1. StrictMode turns
            # direct MyCommand.Name access into a second, misleading failure.
            $nameProperty = $myCommand.PSObject.Properties['Name']
            if ($null -ne $nameProperty -and
                -not [string]::IsNullOrWhiteSpace([string]$nameProperty.Value)) {
                $failedCommand = [string]$nameProperty.Value
            }
        }
        Write-Host ("FAILED AT: line {0}, command {1}" -f `
            [int]$invocation.ScriptLineNumber, $failedCommand) `
            -ForegroundColor Red
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$caught.ScriptStackTrace)) {
        Write-Host "STACK: $($caught.ScriptStackTrace)" -ForegroundColor DarkRed
    }
    Write-Host "No BCD, driver-signing, or kernel-driver change was attempted."
    exit 1
}
