#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string]$VMName = 'P11-Lab',
    [string]$OutputPath = 'C:\VMateLab\p11-integration-recovery.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$result = [ordered]@{
    SchemaVersion = 1
    VMName = $VMName
    StartedAtUtc = [DateTime]::UtcNow.ToString('o')
    VhdPath = ''
    SystemHive = ''
    CurrentControlSet = 0
    Services = @()
    Error = $null
    FinishedAtUtc = $null
}
$mounted = $false
$hiveLoaded = $false
$hiveName = 'VMateP11IntegrationRecovery'
try {
    $vm = Get-VM -Name $VMName -ErrorAction Stop
    if ([string]$vm.State -cne 'Off') {
        throw "VM must be Off for offline integration recovery: $($vm.State)"
    }
    $drives = @(Get-VMHardDiskDrive -VM $vm -ErrorAction Stop |
        Where-Object ControllerLocation -eq 0)
    if ($drives.Count -ne 1) { throw 'Unable to resolve one system VHD.' }
    $vhdPath = [string]$drives[0].Path
    $result.VhdPath = $vhdPath
    $disk = Mount-VHD -Path $vhdPath -Passthru -ErrorAction Stop
    $mounted = $true
    Set-Disk -Number $disk.DiskNumber -IsOffline $false -ErrorAction Stop
    Set-Disk -Number $disk.DiskNumber -IsReadOnly $false -ErrorAction Stop

    $systemHives = @()
    foreach ($partition in @(Get-Partition -DiskNumber $disk.DiskNumber)) {
        $volume = $partition | Get-Volume -ErrorAction SilentlyContinue
        if ($null -eq $volume -or [String]::IsNullOrWhiteSpace(
                [string]$volume.Path)) { continue }
        $candidate = Join-Path ([string]$volume.Path) `
            'Windows\System32\Config\SYSTEM'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $systemHives += $candidate
        }
    }
    if ($systemHives.Count -ne 1) {
        throw "Unable to resolve one guest SYSTEM hive: $($systemHives.Count)"
    }
    $systemHive = [string]$systemHives[0]
    $result.SystemHive = $systemHive
    & reg.exe load "HKLM\$hiveName" $systemHive | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'reg load SYSTEM failed.' }
    $hiveLoaded = $true

    $root = "Registry::HKEY_LOCAL_MACHINE\$hiveName"
    $current = [int](Get-ItemPropertyValue -LiteralPath `
            (Join-Path $root 'Select') -Name Current -ErrorAction Stop)
    $result.CurrentControlSet = $current
    $controlSet = 'ControlSet{0:D3}' -f $current
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($serviceName in @('vmickvpexchange', 'vmicvmsession')) {
        $servicePath = Join-Path $root `
            (Join-Path $controlSet "Services\$serviceName")
        if (-not (Test-Path -LiteralPath $servicePath -PathType Container)) {
            throw "Guest service key missing: $serviceName"
        }
        $before = [int](Get-ItemPropertyValue -LiteralPath $servicePath `
                -Name Start -ErrorAction Stop)
        New-ItemProperty -LiteralPath $servicePath -Name Start -Value 3 `
            -PropertyType DWord -Force -ErrorAction Stop | Out-Null
        $after = [int](Get-ItemPropertyValue -LiteralPath $servicePath `
                -Name Start -ErrorAction Stop)
        if ($after -ne 3) { throw "Failed to restore $serviceName Start=3." }
        [void]$rows.Add([pscustomobject][ordered]@{
                Name = $serviceName
                BeforeStart = $before
                AfterStart = $after
            })
    }
    $result.Services = @($rows)
}
catch {
    $result.Error = $_.Exception.Message
}
finally {
    if ($hiveLoaded) {
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        & reg.exe unload "HKLM\$hiveName" | Out-Null
        if ($LASTEXITCODE -ne 0 -and $null -eq $result.Error) {
            $result.Error = 'reg unload SYSTEM failed.'
        }
    }
    if ($mounted) {
        try { Dismount-VHD -Path $result.VhdPath -ErrorAction Stop }
        catch {
            if ($null -eq $result.Error) { $result.Error = $_.Exception.Message }
        }
    }
    $result.FinishedAtUtc = [DateTime]::UtcNow.ToString('o')
    $directory = Split-Path -Parent $OutputPath
    if ($directory) { [void](New-Item -ItemType Directory -Path $directory -Force) }
    [IO.File]::WriteAllText($OutputPath,
        ([pscustomobject]$result | ConvertTo-Json -Depth 6),
        (New-Object Text.UTF8Encoding($false)))
}

$output = [pscustomobject]$result
$output
if ($null -ne $output.Error) { exit 1 }
