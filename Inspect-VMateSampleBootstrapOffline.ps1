#Requires -Version 5.1

param(
    [Parameter(Mandatory = $true)][ValidatePattern('^pc0[12]$')]
    [string]$VMName,
    [Parameter(Mandatory = $true)][string]$VhdPath,
    [Parameter(Mandatory = $true)][string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Convert-VMateRegistryValue {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [byte[]]) {
        return ([BitConverter]::ToString($Value)).Replace('-', '')
    }
    if ($Value -is [System.Array]) { return @($Value) }
    return $Value
}

function Get-VMateMatchingRegistryChildren {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Pattern
    )
    $matches = [Collections.Generic.List[object]]::new()
    foreach ($key in @(Get-ChildItem -LiteralPath $Root -ErrorAction SilentlyContinue)) {
        $item = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
        if ($null -eq $item) { continue }
        $values = [ordered]@{}
        foreach ($property in @($item.PSObject.Properties | Where-Object {
                    $_.Name -notmatch '^PS(Path|ParentPath|ChildName|Drive|Provider)$'
                })) {
            $values[$property.Name] = Convert-VMateRegistryValue $property.Value
        }
        $text = $key.PSChildName + ' ' + (($values.GetEnumerator() |
                    ForEach-Object { $_.Key + '=' + [string]$_.Value }) -join ' ')
        if ($text -match $Pattern) {
            [void]$matches.Add([pscustomobject][ordered]@{
                    Key = $key.PSChildName
                    Path = $key.Name
                    Values = [pscustomobject]$values
                })
        }
    }
    return @($matches)
}

function Get-VMateNamedFiles {
    param(
        [Parameter(Mandatory = $true)][string]$VolumeRoot,
        [Parameter(Mandatory = $true)][string[]]$Names
    )
    $files = [Collections.Generic.List[object]]::new()
    foreach ($name in $Names) {
        $escapedRoot = $VolumeRoot.TrimEnd('\')
        $lines = @(& cmd.exe /d /c "dir /a:-d /s /b `"$escapedRoot\$name`" 2>nul")
        foreach ($line in $lines) {
            if (-not (Test-Path -LiteralPath $line -PathType Leaf)) { continue }
            $file = Get-Item -LiteralPath $line
            [void]$files.Add([pscustomobject][ordered]@{
                    Name = $file.Name
                    Path = 'C:\' + $file.FullName.Substring($VolumeRoot.Length)
                    Length = [uint64]$file.Length
                    SHA256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
                    FileVersion = [string]$file.VersionInfo.FileVersion
                    CompanyName = [string]$file.VersionInfo.CompanyName
                })
        }
    }
    return @($files)
}

$vm = Get-VM -Name $VMName -ErrorAction Stop
if ([string]$vm.State -ne 'Off') { throw "VM must be off: $VMName" }
$mounted = Mount-VHD -Path $VhdPath -ReadOnly -Passthru -ErrorAction Stop
$systemHiveName = 'VMateSampleBootstrapSystem'
$softwareHiveName = 'VMateSampleBootstrapSoftware'
$systemLoaded = $false
$softwareLoaded = $false
try {
    $disk = $mounted | Get-Disk
    $volumeRoot = $null
    foreach ($partition in @($disk | Get-Partition)) {
        $volume = $partition | Get-Volume -ErrorAction SilentlyContinue
        if ($null -eq $volume -or
            [string]::IsNullOrWhiteSpace([string]$volume.DriveLetter)) { continue }
        $candidate = [string]$volume.DriveLetter + ':\'
        if (Test-Path -LiteralPath (Join-Path $candidate 'Windows\System32\Config\SYSTEM') -PathType Leaf) {
            $volumeRoot = $candidate
            break
        }
    }
    if ($null -eq $volumeRoot) { throw "Windows volume not found: $VhdPath" }

    $files = Get-VMateNamedFiles -VolumeRoot $volumeRoot -Names @(
        'GuestCtrl.exe', 'monitor.exe', 'ets.exe', 'WinRing0x64.sys',
        'WinRing0.sys')

    $systemHive = Join-Path $volumeRoot 'Windows\System32\Config\SYSTEM'
    & reg.exe load "HKLM\$systemHiveName" $systemHive | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to load the SYSTEM hive.' }
    $systemLoaded = $true
    $select = Get-ItemProperty -LiteralPath "Registry::HKEY_LOCAL_MACHINE\$systemHiveName\Select"
    $controlSet = 'ControlSet{0:D3}' -f [int]$select.Current
    $servicesRoot = "Registry::HKEY_LOCAL_MACHINE\$systemHiveName\" +
        "$controlSet\Services"
    $services = Get-VMateMatchingRegistryChildren -Root $servicesRoot -Pattern '(?i)GuestCtrl|monitor\.exe|ets\.exe|WinRing|VMSpoofer'

    $softwareHive = Join-Path $volumeRoot 'Windows\System32\Config\SOFTWARE'
    & reg.exe load "HKLM\$softwareHiveName" $softwareHive | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to load the SOFTWARE hive.' }
    $softwareLoaded = $true
    $runEntries = [Collections.Generic.List[object]]::new()
    foreach ($relative in @(
            'Microsoft\Windows\CurrentVersion\Run',
            'Microsoft\Windows\CurrentVersion\RunOnce',
            'WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
            'WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce',
            'Microsoft\Windows NT\CurrentVersion\Winlogon')) {
        $path = "Registry::HKEY_LOCAL_MACHINE\$softwareHiveName\$relative"
        $item = Get-ItemProperty -LiteralPath $path -ErrorAction SilentlyContinue
        if ($null -eq $item) { continue }
        foreach ($property in @($item.PSObject.Properties | Where-Object {
                    $_.Name -notmatch '^PS(Path|ParentPath|ChildName|Drive|Provider)$'
                })) {
            $text = $property.Name + '=' + [string]$property.Value
            if ($text -match '(?i)GuestCtrl|monitor\.exe|ets\.exe|WinRing|VMSpoofer') {
                [void]$runEntries.Add([pscustomobject][ordered]@{
                        Path = $relative
                        Name = $property.Name
                        Value = Convert-VMateRegistryValue $property.Value
                    })
            }
        }
    }

    $tasks = [Collections.Generic.List[object]]::new()
    $tasksRoot = Join-Path $volumeRoot 'Windows\System32\Tasks'
    foreach ($task in @(Get-ChildItem -LiteralPath $tasksRoot -File -Recurse -ErrorAction SilentlyContinue)) {
        $content = Get-Content -LiteralPath $task.FullName -Raw -ErrorAction SilentlyContinue
        if ($content -match '(?i)GuestCtrl|monitor\.exe|ets\.exe|WinRing|VMSpoofer') {
            [void]$tasks.Add([pscustomobject][ordered]@{
                    Path = 'C:\' + $task.FullName.Substring($volumeRoot.Length)
                    Content = $content
                })
        }
    }

    [pscustomobject][ordered]@{
        SchemaVersion = 1
        CapturedAtUtc = [DateTime]::UtcNow.ToString('o')
        VMName = $VMName
        VhdPath = $VhdPath
        Files = @($files)
        Services = @($services)
        MachineRunEntries = @($runEntries)
        ScheduledTasks = @($tasks)
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
}
finally {
    if ($softwareLoaded) {
        [GC]::Collect(); [GC]::WaitForPendingFinalizers()
        & reg.exe unload "HKLM\$softwareHiveName" | Out-Null
    }
    if ($systemLoaded) {
        [GC]::Collect(); [GC]::WaitForPendingFinalizers()
        & reg.exe unload "HKLM\$systemHiveName" | Out-Null
    }
    Dismount-VHD -Path $VhdPath -ErrorAction SilentlyContinue
}
