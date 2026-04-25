# Steps run inside guest as Administrator:
#  1. Add C:\stealth\efiguard and the EFI System Partition mount letter to
#     Defender exclusion (Loader.efi has a Defender signature match).
#  2. Disable real-time monitoring briefly to survive the seconds between
#     network drop and exclusion taking effect.
#  3. Caller pushes Loader.efi after this script runs once.

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host '=== adding Defender exclusions ==='
Add-MpPreference -ExclusionPath 'C:\stealth\efiguard' -ErrorAction SilentlyContinue
Add-MpPreference -ExclusionPath 'C:\stealth' -ErrorAction SilentlyContinue
Add-MpPreference -ExclusionExtension '.efi' -ErrorAction SilentlyContinue
Add-MpPreference -ExclusionProcess 'cmd.exe' -ErrorAction SilentlyContinue

Write-Host '=== disabling real-time monitoring (briefly) ==='
Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue
Set-MpPreference -DisableScriptScanning $true -ErrorAction SilentlyContinue

Write-Host ''
Write-Host '=== current Defender status ==='
Get-MpPreference | Select-Object DisableRealtimeMonitoring,ExclusionPath,ExclusionExtension | Format-List
