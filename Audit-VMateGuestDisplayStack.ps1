#Requires -Version 5.1

param(
    [string]$OutputPath = 'C:\VMateAudit\display-stack.json',
    [string]$Endpoint = ''
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

function Invoke-VMateSafe {
    param([Parameter(Mandatory = $true)][scriptblock]$Script)
    try { return & $Script }
    catch {
        return [pscustomobject][ordered]@{
            AuditError = $_.Exception.Message
            ErrorType = $_.Exception.GetType().FullName
        }
    }
}

function Convert-VMateAuditValue {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [byte[]]) {
        $prefix = if ($Value.Length -eq 0) { '' } else {
            ([BitConverter]::ToString(
                    $Value[0..([Math]::Min($Value.Length - 1, 31))])).Replace('-', '')
        }
        return [pscustomobject][ordered]@{
            Type = 'ByteArray'
            Length = $Value.Length
            HexPrefix = $prefix
        }
    }
    if ($Value -is [System.Array]) {
        return @($Value | ForEach-Object { Convert-VMateAuditValue $_ })
    }
    if ($Value -is [DateTime]) { return $Value.ToUniversalTime().ToString('o') }
    if ($Value -is [ValueType] -or $Value -is [string]) { return $Value }
    return [string]$Value
}

function Get-VMateRegistrySnapshot {
    param([Parameter(Mandatory = $true)][string]$LiteralPath)
    if (-not (Test-Path -LiteralPath $LiteralPath)) { return $null }
    $item = Get-ItemProperty -LiteralPath $LiteralPath -ErrorAction Stop
    $values = [ordered]@{}
    foreach ($property in @($item.PSObject.Properties | Where-Object {
                $_.Name -notmatch '^PS(Path|ParentPath|ChildName|Drive|Provider)$'
            } | Sort-Object Name)) {
        $values[$property.Name] = Convert-VMateAuditValue $property.Value
    }
    return [pscustomobject][ordered]@{
        Path = $LiteralPath
        Values = [pscustomobject]$values
    }
}

function Get-VMateFileSnapshot {
    param([Parameter(Mandatory = $true)][string]$LiteralPath)
    $item = Get-Item -LiteralPath $LiteralPath -ErrorAction Stop
    $version = $item.VersionInfo
    return [pscustomobject][ordered]@{
        Path = $item.FullName
        Length = [uint64]$item.Length
        SHA256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
        FileVersion = [string]$version.FileVersion
        ProductName = [string]$version.ProductName
        CompanyName = [string]$version.CompanyName
    }
}

$displayDevices = @(Invoke-VMateSafe {
        Get-PnpDevice -Class Display -ErrorAction Stop |
            Select-Object Status, Class, FriendlyName, InstanceId,
                Problem, ConfigManagerErrorCode
    })
$displayProperties = [Collections.Generic.List[object]]::new()
foreach ($device in @($displayDevices | Where-Object { $_.InstanceId })) {
    $properties = @(Invoke-VMateSafe {
            Get-PnpDeviceProperty -InstanceId $device.InstanceId |
                Where-Object {
                    $_.KeyName -match '(?i)(HardwareIds|CompatibleIds|Driver$|' +
                        'DriverVersion|DriverDate|Service|ClassGuid|' +
                        'Manufacturer|BusReportedDeviceDesc|LocationPaths|' +
                        'ContainerId|ProblemCode)'
                } | Sort-Object KeyName
        })
    [void]$displayProperties.Add([pscustomobject][ordered]@{
            InstanceId = $device.InstanceId
            Properties = @($properties | ForEach-Object {
                    if ($_.PSObject.Properties['AuditError']) { return $_ }
                    [pscustomobject][ordered]@{
                        KeyName = [string]$_.KeyName
                        Type = [string]$_.Type
                        Data = Convert-VMateAuditValue $_.Data
                    }
                })
        })
}

$enumSnapshots = [Collections.Generic.List[object]]::new()
foreach ($device in @($displayDevices | Where-Object { $_.InstanceId })) {
    $path = 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Enum\' +
        $device.InstanceId
    $snapshot = Invoke-VMateSafe { Get-VMateRegistrySnapshot $path }
    if ($null -ne $snapshot) { [void]$enumSnapshots.Add($snapshot) }
    $parameters = Invoke-VMateSafe {
        Get-VMateRegistrySnapshot ($path + '\Device Parameters')
    }
    if ($null -ne $parameters) { [void]$enumSnapshots.Add($parameters) }
}

$displayClassRoot = 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
$classSnapshots = @(Invoke-VMateSafe {
        Get-ChildItem -LiteralPath $displayClassRoot -ErrorAction Stop |
            Where-Object { $_.PSChildName -match '^\d{4}$' } |
            ForEach-Object { Get-VMateRegistrySnapshot $_.PSPath }
    })

$driverStoreRoots = @(
    'C:\Windows\System32\DriverStore\FileRepository',
    'C:\Windows\System32\HostDriverStore\FileRepository'
)
$driverStore = [Collections.Generic.List[object]]::new()
foreach ($root in $driverStoreRoots) {
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
    foreach ($directory in @(Get-ChildItem -LiteralPath $root -Directory |
            Where-Object { $_.Name -match '(?i)^(nv|nvidia|display|basicdisplay)' })) {
        $files = @(Get-ChildItem -LiteralPath $directory.FullName -File -Recurse |
            Where-Object { $_.Extension -in @('.inf', '.sys', '.dll', '.cat') } |
            Select-Object -First 600)
        [void]$driverStore.Add([pscustomobject][ordered]@{
                Root = $root
                Package = $directory.Name
                FileCount = $files.Count
                Files = @($files | ForEach-Object {
                        Invoke-VMateSafe { Get-VMateFileSnapshot $_.FullName }
                    })
            })
    }
}

$serviceNames = @('nvlddmkm', 'VirtualRender', 'BasicDisplay', 'BasicRender',
    'NVDisplay.ContainerLocalSystem')
$serviceRegistry = @($serviceNames | ForEach-Object {
        Invoke-VMateSafe {
            Get-VMateRegistrySnapshot (
                'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\' + $_)
        }
    } | Where-Object { $null -ne $_ })

$result = [pscustomobject][ordered]@{
    SchemaVersion = 1
    CapturedAtUtc = [DateTime]::UtcNow.ToString('o')
    ComputerName = $env:COMPUTERNAME
    OperatingSystem = Invoke-VMateSafe {
        Get-CimInstance Win32_OperatingSystem |
            Select-Object Caption, Version, BuildNumber, OSArchitecture,
                LastBootUpTime
    }
    VideoControllers = @(Invoke-VMateSafe {
            Get-CimInstance Win32_VideoController | Select-Object *
        })
    DisplayDevices = $displayDevices
    DisplayDeviceProperties = @($displayProperties)
    SignedDisplayDrivers = @(Invoke-VMateSafe {
            Get-CimInstance Win32_PnPSignedDriver | Where-Object {
                $_.DeviceClass -eq 'DISPLAY' -or
                $_.DeviceName -match '(?i)NVIDIA|Hyper-V|Virtual Render'
            } | Select-Object DeviceName, DeviceID, DeviceClass, DriverProviderName,
                DriverVersion, DriverDate, InfName, IsSigned, Manufacturer,
                DriverName
        })
    SystemDrivers = @(Invoke-VMateSafe {
            Get-CimInstance Win32_SystemDriver | Where-Object {
                $_.Name -in $serviceNames -or $_.PathName -match '(?i)nvidia|nvlddmkm|virtualrender'
            } | Select-Object Name, DisplayName, State, StartMode, PathName,
                ServiceType
        })
    ServiceRegistry = $serviceRegistry
    EnumRegistry = @($enumSnapshots)
    DisplayClassRegistry = $classSnapshots
    WindowsDisplayDrivers = @(Invoke-VMateSafe {
            Get-WindowsDriver -Online -All | Where-Object {
                $_.ClassName -eq 'Display' -or
                $_.ProviderName -match '(?i)NVIDIA'
            } | Select-Object Driver, OriginalFileName, Inbox, BootCritical,
                ProviderName, Date, Version, ClassName, ClassDescription
        })
    DriverStore = @($driverStore)
    PnpUtilDisplay = @(Invoke-VMateSafe {
            & pnputil.exe /enum-drivers /class Display /files 2>&1
        })
    RelevantFiles = @(
        'C:\Windows\System32\drivers\nvlddmkm.sys',
        'C:\Windows\System32\drivers\BasicDisplay.sys',
        'C:\Windows\System32\drivers\BasicRender.sys',
        'C:\Windows\System32\drivers\VirtualRender.sys'
    ) | ForEach-Object {
        if (Test-Path -LiteralPath $_ -PathType Leaf) {
            Invoke-VMateSafe { Get-VMateFileSnapshot $_ }
        }
    }
    ActivePowerScheme = @(Invoke-VMateSafe { & powercfg.exe /GetActiveScheme 2>&1 })
}

$directory = Split-Path -Parent $OutputPath
if (-not [String]::IsNullOrWhiteSpace($directory)) {
    [IO.Directory]::CreateDirectory($directory) | Out-Null
}
$json = $result | ConvertTo-Json -Depth 16 -Compress
[IO.File]::WriteAllText($OutputPath, $json,
    [Text.UTF8Encoding]::new($false))
if (-not [String]::IsNullOrWhiteSpace($Endpoint)) {
    $uri = [Uri]$Endpoint
    if ($uri.Scheme -cne 'http' -or $uri.Host -cne '192.168.160.1' -or
        $uri.AbsolutePath -notmatch '^/pc0[12]$') {
        throw "审计回传地址不在实验网白名单内：$Endpoint"
    }
    $response = Invoke-WebRequest -UseBasicParsing -Method Post -Uri $uri `
        -ContentType 'application/json; charset=utf-8' `
        -Body ([Text.Encoding]::UTF8.GetBytes($json))
    if ([int]$response.StatusCode -ne 200) {
        throw "审计接收器返回 HTTP $($response.StatusCode)。"
    }
}
