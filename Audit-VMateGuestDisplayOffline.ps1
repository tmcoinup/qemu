#Requires -Version 5.1

param(
    [Parameter(Mandatory = $true)][string]$VMName,
    [Parameter(Mandatory = $true)][string]$VhdPath,
    [string]$OutputRoot = 'C:\VMateLab\OfflineDisplayAudit',
    [switch]$CleanupAuditBootstrap
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Convert-VMateOfflineValue {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [byte[]]) {
        return [pscustomobject][ordered]@{
            Type = 'ByteArray'
            Length = $Value.Length
            Hex = ([BitConverter]::ToString($Value)).Replace('-', '')
        }
    }
    if ($Value -is [System.Array]) {
        return @($Value | ForEach-Object { Convert-VMateOfflineValue $_ })
    }
    if ($Value -is [ValueType] -or $Value -is [string]) { return $Value }
    return [string]$Value
}

function Get-VMateOfflineRegistryItem {
    param([Parameter(Mandatory = $true)][string]$LiteralPath)
    if (-not (Test-Path -LiteralPath $LiteralPath)) { return $null }
    $item = Get-ItemProperty -LiteralPath $LiteralPath -ErrorAction Stop
    $values = [ordered]@{}
    foreach ($property in @($item.PSObject.Properties | Where-Object {
                $_.Name -notmatch '^PS(Path|ParentPath|ChildName|Drive|Provider)$'
            } | Sort-Object Name)) {
        $values[$property.Name] = Convert-VMateOfflineValue $property.Value
    }
    return [pscustomobject][ordered]@{
        Path = $LiteralPath
        Values = [pscustomobject]$values
    }
}

function Get-VMateOfflineFile {
    param(
        [Parameter(Mandatory = $true)][IO.FileInfo]$File,
        [Parameter(Mandatory = $true)][string]$WindowsRoot
    )
    $relative = $File.FullName.Substring($WindowsRoot.Length)
    return [pscustomobject][ordered]@{
        Path = 'C:\' + $relative
        Length = [uint64]$File.Length
        SHA256 = (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash
        FileVersion = [string]$File.VersionInfo.FileVersion
        CompanyName = [string]$File.VersionInfo.CompanyName
    }
}

[IO.Directory]::CreateDirectory($OutputRoot) | Out-Null
$vm = Get-VM -Name $VMName -ErrorAction Stop
if ([string]$vm.State -ne 'Off') { throw "VM 必须先关机：$VMName" }
$mounted = Mount-VHD -Path $VhdPath -Passthru -ErrorAction Stop
$systemHiveName = 'VMateOfflineDisplaySystem'
$softwareHiveName = 'VMateOfflineDisplaySoftware'
$systemLoaded = $false
$softwareLoaded = $false
try {
    $disk = $mounted | Get-Disk
    $windowsRoot = $null
    foreach ($partition in @($disk | Get-Partition)) {
        $volume = $partition | Get-Volume -ErrorAction SilentlyContinue
        if ($null -eq $volume -or
            [String]::IsNullOrWhiteSpace([string]$volume.DriveLetter)) { continue }
        $candidate = ([string]$volume.DriveLetter) + ':\'
        if (Test-Path -LiteralPath (Join-Path $candidate `
                    'Windows\System32\Config\SYSTEM') -PathType Leaf) {
            $windowsRoot = $candidate
            break
        }
    }
    if ($null -eq $windowsRoot) { throw "找不到 Windows 分区：$VhdPath" }

    $systemHive = Join-Path $windowsRoot 'Windows\System32\Config\SYSTEM'
    & reg.exe load "HKLM\$systemHiveName" $systemHive | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '加载 SYSTEM hive 失败。' }
    $systemLoaded = $true
    $select = Get-ItemProperty -LiteralPath `
        "Registry::HKEY_LOCAL_MACHINE\$systemHiveName\Select"
    $controlSet = 'ControlSet{0:D3}' -f [int]$select.Current
    $controlRoot = "Registry::HKEY_LOCAL_MACHINE\$systemHiveName\$controlSet"

    $displayEnum = [Collections.Generic.List[object]]::new()
    $pciRoot = Join-Path $controlRoot 'Enum\PCI'
    foreach ($device in @(Get-ChildItem -LiteralPath $pciRoot `
            -ErrorAction SilentlyContinue)) {
        foreach ($instance in @(Get-ChildItem -LiteralPath $device.PSPath `
                -ErrorAction SilentlyContinue)) {
            $snapshot = Get-VMateOfflineRegistryItem $instance.PSPath
            $values = $snapshot.Values
            if ($device.PSChildName -match '(?i)VEN_10DE|VEN_1414' -or
                [string]$values.ClassGUID -ieq
                    '{4d36e968-e325-11ce-bfc1-08002be10318}' -or
                [string]$values.Service -match '(?i)nvlddmkm|VirtualRender') {
                [void]$displayEnum.Add([pscustomobject][ordered]@{
                        Device = $device.PSChildName
                        Instance = $instance.PSChildName
                        Registry = $snapshot
                        DeviceParameters = Get-VMateOfflineRegistryItem `
                            (Join-Path $instance.PSPath 'Device Parameters')
                    })
            }
        }
    }

    $displayClass = [Collections.Generic.List[object]]::new()
    $classRoot = Join-Path $controlRoot `
        'Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    foreach ($key in @(Get-ChildItem -LiteralPath $classRoot `
            -ErrorAction SilentlyContinue | Where-Object {
                $_.PSChildName -match '^\d{4}$'
            })) {
        [void]$displayClass.Add((Get-VMateOfflineRegistryItem $key.PSPath))
    }
    $services = @('nvlddmkm', 'VirtualRender', 'BasicDisplay', 'BasicRender',
        'NVDisplay.ContainerLocalSystem') | ForEach-Object {
        Get-VMateOfflineRegistryItem (Join-Path $controlRoot ('Services\' + $_))
    } | Where-Object { $null -ne $_ }

    $softwareHive = Join-Path $windowsRoot 'Windows\System32\Config\SOFTWARE'
    & reg.exe load "HKLM\$softwareHiveName" $softwareHive | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '加载 SOFTWARE hive 失败。' }
    $softwareLoaded = $true
    $nvidiaSoftware = [Collections.Generic.List[object]]::new()
    foreach ($path in @(
            "Registry::HKEY_LOCAL_MACHINE\$softwareHiveName\NVIDIA Corporation",
            "Registry::HKEY_LOCAL_MACHINE\$softwareHiveName\NVIDIA Corporation\Global"
        )) {
        $snapshot = Get-VMateOfflineRegistryItem $path
        if ($null -ne $snapshot) { [void]$nvidiaSoftware.Add($snapshot) }
    }

    $packages = [Collections.Generic.List[object]]::new()
    foreach ($relativeRoot in @('Windows\System32\DriverStore\FileRepository',
            'Windows\System32\HostDriverStore\FileRepository')) {
        $root = Join-Path $windowsRoot $relativeRoot
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        foreach ($directory in @(Get-ChildItem -LiteralPath $root -Directory |
                Where-Object {
                    $_.Name -match '(?i)^(nv|nvidia|vrd|wvmbusvideo|basicdisplay)'
                })) {
            $files = @(Get-ChildItem -LiteralPath $directory.FullName -File -Recurse |
                Where-Object { $_.Extension -in @('.inf', '.sys', '.dll', '.cat') } |
                Select-Object -First 800)
            [void]$packages.Add([pscustomobject][ordered]@{
                    Store = 'C:\' + $relativeRoot
                    Package = $directory.Name
                    Files = @($files | ForEach-Object {
                            Get-VMateOfflineFile $_ $windowsRoot
                        })
                })
            foreach ($inf in @($files | Where-Object Extension -EQ '.inf')) {
                Copy-Item -LiteralPath $inf.FullName -Destination `
                    (Join-Path $OutputRoot ($VMName + '-' + $directory.Name +
                            '-' + $inf.Name)) -Force
            }
        }
    }

    foreach ($relative in @('Windows\INF\setupapi.dev.log',
            'Windows\INF\setupapi.app.log')) {
        $source = Join-Path $windowsRoot $relative
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            Copy-Item -LiteralPath $source -Destination `
                (Join-Path $OutputRoot ($VMName + '-' +
                        ([IO.Path]::GetFileName($relative)))) -Force
        }
    }

    [pscustomobject][ordered]@{
        SchemaVersion = 1
        CapturedAtUtc = [DateTime]::UtcNow.ToString('o')
        VMName = $VMName
        DisplayEnum = @($displayEnum)
        DisplayClass = @($displayClass)
        Services = @($services)
        NvidiaSoftware = @($nvidiaSoftware)
        DriverPackages = @($packages)
    } | ConvertTo-Json -Depth 18 | Set-Content -LiteralPath `
        (Join-Path $OutputRoot ($VMName + '-offline-display.json')) -Encoding UTF8

    if ($CleanupAuditBootstrap) {
        Remove-Item -LiteralPath (Join-Path $controlRoot `
                'Services\VMateDisplayAuditOnce') -Recurse -Force `
            -ErrorAction SilentlyContinue
        $runOnce = "Registry::HKEY_LOCAL_MACHINE\$softwareHiveName\" +
            'Microsoft\Windows\CurrentVersion\RunOnce'
        Remove-ItemProperty -LiteralPath $runOnce -Name 'VMateDisplayAuditOnce' `
            -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $windowsRoot 'VMateAudit') `
            -Recurse -Force -ErrorAction SilentlyContinue
    }
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
