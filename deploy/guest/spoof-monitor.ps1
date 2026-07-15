# Manual Windows monitor-repair tool.
#
# Profiles are read from monitor-profiles.tsv next to this script.  The normal
# path is a one-shot registry update followed by a monitor PnP cycle.  A
# persistent startup/logon task is deliberately opt-in with -InstallTask.
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [Alias('Brand')]
    [string]$Profile = 'dell-p2419h',

    [string]$Serial,
    [switch]$ListProfiles,
    [string]$BuildOnly,
    [switch]$InstallTask
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$CatalogColumns = @(
    'key', 'vendor', 'product_id', 'edid_name', 'display_name',
    'manufacturer', 'width_mm', 'height_mm', 'native_x', 'native_y',
    'refresh_hz', 'min_v', 'max_v', 'min_h', 'max_h', 'max_clock_mhz',
    'video_input', 'year', 'week', 'serial_prefix', 'mode_set'
)

function Test-IsWindows {
    return [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
}

function Get-MonitorCatalog {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Monitor profile catalog not found: $Path"
    }

    $lines = @(
        foreach ($line in @(Get-Content -LiteralPath $Path -Encoding UTF8)) {
            $candidate = $line.TrimStart([char]0xFEFF)
            if ($candidate.Trim().Length -eq 0) { continue }
            if ($candidate.TrimStart().StartsWith('#')) { continue }
            $candidate
        }
    )
    if ($lines.Count -eq 0) {
        throw "Monitor profile catalog has no data rows: $Path"
    }
    foreach ($line in $lines) {
        $pipeCount = $line.Length - $line.Replace('|', '').Length
        if ($pipeCount -ne 20) {
            throw "Monitor profile catalog row does not have 21 pipe-separated fields: '$line'"
        }
    }

    # The catalog deliberately has no header row so it can also be sourced by
    # small POSIX helpers.  Bind its fixed schema here.
    $rows = @($lines | ConvertFrom-Csv -Delimiter ([char]124) -Header $CatalogColumns)
    if ($rows.Count -eq 0) {
        throw "Monitor profile catalog has no profiles: $Path"
    }

    $duplicates = @($rows | Group-Object -Property key | Where-Object { $_.Count -gt 1 })
    if ($duplicates.Count -gt 0) {
        $names = ($duplicates | ForEach-Object { $_.Name }) -join ', '
        throw "Monitor profile catalog has duplicate keys: $names"
    }
    return $rows
}

function ConvertTo-CatalogUInt {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string]$Field,
        [Parameter(Mandatory = $true)][uint64]$Maximum
    )

    $text = ([string]$Value).Trim()
    if ($text.Length -eq 0) {
        throw "Profile field '$Field' must not be empty"
    }
    try {
        if ($text.StartsWith('0x', [StringComparison]::OrdinalIgnoreCase)) {
            $number = [Convert]::ToUInt64($text.Substring(2), 16)
        } else {
            $number = [uint64]::Parse(
                $text,
                [Globalization.NumberStyles]::Integer,
                [Globalization.CultureInfo]::InvariantCulture
            )
        }
    } catch {
        throw "Profile field '$Field' is not a valid integer: '$text'"
    }
    if ($number -gt $Maximum) {
        throw "Profile field '$Field' is out of range (0..$Maximum): $number"
    }
    return [uint64]$number
}

function Test-PrintableAscii {
    param([Parameter(Mandatory = $true)][string]$Value)
    return $Value -match '^[\x20-\x7e]+$'
}

function ConvertTo-MonitorConfig {
    param([Parameter(Mandatory = $true)][object]$Row)

    $key = ([string]$Row.key).Trim()
    $vendor = ([string]$Row.vendor).Trim().ToUpperInvariant()
    $edidName = ([string]$Row.edid_name).Trim()
    $displayName = ([string]$Row.display_name).Trim()
    $manufacturer = ([string]$Row.manufacturer).Trim()
    $serialPrefix = ([string]$Row.serial_prefix).Trim()
    $modeSet = ([string]$Row.mode_set).Trim().ToLowerInvariant()

    if ($key -notmatch '^[a-z0-9][a-z0-9-]*$') {
        throw "Invalid profile key: '$key'"
    }
    if ($vendor -notmatch '^[A-Z]{3}$') {
        throw "Profile '$key' has invalid three-letter PNP vendor '$vendor'"
    }
    if ($edidName.Length -lt 1 -or $edidName.Length -gt 12 -or
        -not (Test-PrintableAscii -Value $edidName)) {
        throw "Profile '$key' edid_name must be 1..12 printable ASCII characters"
    }
    if ($displayName.Length -eq 0 -or $manufacturer.Length -eq 0) {
        throw "Profile '$key' must provide display_name and manufacturer"
    }
    if ($serialPrefix.Length -gt 8 -or
        ($serialPrefix.Length -gt 0 -and -not (Test-PrintableAscii -Value $serialPrefix))) {
        throw "Profile '$key' serial_prefix must be at most 8 printable ASCII characters"
    }
    if ($modeSet -ne 'fhd-standard') {
        throw "Profile '$key' uses unsupported mode_set '$modeSet'"
    }

    $config = [pscustomobject]@{
        Key           = $key
        Vendor        = $vendor
        ProductId     = [uint16](ConvertTo-CatalogUInt $Row.product_id 'product_id' 65535)
        EdidName      = $edidName
        DisplayName   = $displayName
        Manufacturer  = $manufacturer
        WidthMm       = [int](ConvertTo-CatalogUInt $Row.width_mm 'width_mm' 4095)
        HeightMm      = [int](ConvertTo-CatalogUInt $Row.height_mm 'height_mm' 4095)
        NativeX       = [int](ConvertTo-CatalogUInt $Row.native_x 'native_x' 4095)
        NativeY       = [int](ConvertTo-CatalogUInt $Row.native_y 'native_y' 4095)
        RefreshHz     = [int](ConvertTo-CatalogUInt $Row.refresh_hz 'refresh_hz' 123)
        MinV          = [int](ConvertTo-CatalogUInt $Row.min_v 'min_v' 255)
        MaxV          = [int](ConvertTo-CatalogUInt $Row.max_v 'max_v' 255)
        MinH          = [int](ConvertTo-CatalogUInt $Row.min_h 'min_h' 255)
        MaxH          = [int](ConvertTo-CatalogUInt $Row.max_h 'max_h' 255)
        MaxClockMHz   = [int](ConvertTo-CatalogUInt $Row.max_clock_mhz 'max_clock_mhz' 2550)
        VideoInput    = [byte](ConvertTo-CatalogUInt $Row.video_input 'video_input' 255)
        Year          = [int](ConvertTo-CatalogUInt $Row.year 'year' 2245)
        Week          = [int](ConvertTo-CatalogUInt $Row.week 'week' 54)
        SerialPrefix  = $serialPrefix
        ModeSet       = $modeSet
    }

    if ($config.WidthMm -eq 0 -or $config.HeightMm -eq 0) {
        throw "Profile '$key' must have a non-zero physical size"
    }
    if ($config.NativeX -ne 1920 -or $config.NativeY -ne 1080 -or
        $config.RefreshHz -ne 60) {
        throw "Profile '$key' fhd-standard must be native 1920x1080 at 60 Hz"
    }
    if ($config.Year -lt 1990) {
        throw "Profile '$key' year must be in 1990..2245"
    }
    if (($config.VideoInput -band 0x80) -eq 0) {
        throw "Profile '$key' video_input must describe a digital display"
    }
    if ($config.MinV -gt 60 -or $config.MaxV -lt 60 -or
        $config.MinH -gt 68 -or $config.MaxH -lt 68 -or
        $config.MaxClockMHz -lt 149) {
        throw "Profile '$key' range limits do not cover 1920x1080 at 60 Hz"
    }
    if ($config.MinV -gt $config.MaxV -or $config.MinH -gt $config.MaxH) {
        throw "Profile '$key' has reversed range limits"
    }
    return $config
}

function Get-StableUInt32 {
    param([Parameter(Mandatory = $true)][string]$Value)

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value))
    } finally {
        $sha256.Dispose()
    }
    [uint64]$number = [uint64]$digest[0] +
        ([uint64]$digest[1] * 256) +
        ([uint64]$digest[2] * 65536) +
        ([uint64]$digest[3] * 16777216)
    if ($number -eq 0) { $number = 1 }
    return [uint32]$number
}

function New-DefaultSerial {
    param([Parameter(Mandatory = $true)][object]$Config)

    $prefix = $Config.SerialPrefix
    if ($prefix.Length -eq 0) { $prefix = $Config.Vendor }
    $suffix = '{0:X8}' -f (Get-StableUInt32 -Value ("profile:" + $Config.Key))
    $room = 12 - $prefix.Length
    if ($room -lt 4) {
        throw "Profile '$($Config.Key)' serial_prefix leaves too little room for a serial suffix"
    }
    if ($room -lt $suffix.Length) { $suffix = $suffix.Substring(0, $room) }
    return $prefix + $suffix
}

function Set-ByteBlock {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Target,
        [Parameter(Mandatory = $true)][int]$Offset,
        [Parameter(Mandatory = $true)][byte[]]$Bytes
    )
    [Array]::Copy($Bytes, 0, $Target, $Offset, $Bytes.Length)
}

function New-TextDescriptor {
    param(
        [Parameter(Mandatory = $true)][byte]$Tag,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $descriptor = New-Object byte[] 18
    $descriptor[3] = $Tag
    for ($i = 5; $i -lt 18; $i++) { $descriptor[$i] = 0x20 }
    $encoded = [Text.Encoding]::ASCII.GetBytes($Text)
    $count = [Math]::Min(13, $encoded.Length)
    if ($count -gt 0) { [Array]::Copy($encoded, 0, $descriptor, 5, $count) }
    if ($count -lt 13) { $descriptor[5 + $count] = 0x0A }
    return $descriptor
}

function Build-FhdEdid {
    param(
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][string]$TextSerial,
        [Parameter(Mandatory = $true)][uint32]$BinarySerial
    )

    $edid = New-Object byte[] 128
    Set-ByteBlock $edid 0 ([byte[]]@(0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00))

    $a = [int][char]$Config.Vendor[0] - 64
    $b = [int][char]$Config.Vendor[1] - 64
    $c = [int][char]$Config.Vendor[2] - 64
    $manufacturerId = ($a -shl 10) -bor ($b -shl 5) -bor $c
    $edid[8] = [byte](($manufacturerId -shr 8) -band 0xFF)
    $edid[9] = [byte]($manufacturerId -band 0xFF)
    $edid[10] = [byte]($Config.ProductId -band 0xFF)
    $edid[11] = [byte](($Config.ProductId -shr 8) -band 0xFF)
    $edid[12] = [byte]($BinarySerial -band 0xFF)
    $edid[13] = [byte](($BinarySerial -shr 8) -band 0xFF)
    $edid[14] = [byte](($BinarySerial -shr 16) -band 0xFF)
    $edid[15] = [byte](($BinarySerial -shr 24) -band 0xFF)
    $edid[16] = [byte]$Config.Week
    $edid[17] = [byte]($Config.Year - 1990)
    $edid[18] = 1
    $edid[19] = 4
    $edid[20] = $Config.VideoInput
    $edid[21] = [byte][Math]::Round(
        $Config.WidthMm / 10.0, 0, [MidpointRounding]::AwayFromZero
    )
    $edid[22] = [byte][Math]::Round(
        $Config.HeightMm / 10.0, 0, [MidpointRounding]::AwayFromZero
    )
    $edid[23] = 0x78 # gamma 2.20
    $edid[24] = 0x0E # sRGB, preferred timing, and RGB/YCbCr 4:4:4

    # Standard sRGB chromaticities.
    Set-ByteBlock $edid 25 ([byte[]]@(
        0xEE, 0x91, 0xA3, 0x54, 0x4C, 0x99, 0x26, 0x0F, 0x50, 0x54
    ))

    # Established 60 Hz timings: 640x480, 800x600, and 1024x768.
    $edid[35] = 0x21
    $edid[36] = 0x08
    $edid[37] = 0x00

    # EDID 1.4 standard timings.  Keeping the native timing here as well as in
    # the preferred DTD makes Windows' fallback mode enumeration predictable.
    for ($slot = 0; $slot -lt 8; $slot++) {
        $edid[38 + 2 * $slot] = 0x01
        $edid[39 + 2 * $slot] = 0x01
    }
    $standardModes = @(
        [pscustomobject]@{ X = 1920; Y = 1080; Aspect = 3 },
        [pscustomobject]@{ X = 1680; Y = 1050; Aspect = 0 },
        [pscustomobject]@{ X = 1600; Y = 900;  Aspect = 3 },
        [pscustomobject]@{ X = 1280; Y = 1024; Aspect = 2 },
        [pscustomobject]@{ X = 1280; Y = 800;  Aspect = 0 },
        [pscustomobject]@{ X = 1280; Y = 720;  Aspect = 3 }
    )
    for ($slot = 0; $slot -lt $standardModes.Count; $slot++) {
        $mode = $standardModes[$slot]
        $edid[38 + 2 * $slot] = [byte](([int]$mode.X / 8) - 31)
        $edid[39 + 2 * $slot] = [byte](([int]$mode.Aspect -shl 6) -bor 0)
    }

    # Preferred 1920x1080p60 DTD (148.50 MHz, CEA-861 positive sync).
    $dtd = [byte[]]@(
        0x02, 0x3A, 0x80, 0x18, 0x71, 0x38, 0x2D, 0x40, 0x58,
        0x2C, 0x45, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1E
    )
    $dtd[12] = [byte]($Config.WidthMm -band 0xFF)
    $dtd[13] = [byte]($Config.HeightMm -band 0xFF)
    $dtd[14] = [byte]((($Config.WidthMm -shr 8) -shl 4) -bor
        (($Config.HeightMm -shr 8) -band 0x0F))
    Set-ByteBlock $edid 54 $dtd

    $range = New-Object byte[] 18
    $range[3] = 0xFD
    $range[5] = [byte]$Config.MinV
    $range[6] = [byte]$Config.MaxV
    $range[7] = [byte]$Config.MinH
    $range[8] = [byte]$Config.MaxH
    $range[9] = [byte][Math]::Ceiling($Config.MaxClockMHz / 10.0)
    $range[10] = 0x01 # limits only; no secondary timing formula
    $range[11] = 0x0A
    for ($i = 12; $i -lt 18; $i++) { $range[$i] = 0x20 }
    Set-ByteBlock $edid 72 $range
    Set-ByteBlock $edid 90 (New-TextDescriptor 0xFC $Config.EdidName)
    Set-ByteBlock $edid 108 (New-TextDescriptor 0xFF $TextSerial)

    $edid[126] = 0 # no extension blocks: this file is exactly 128 bytes
    [uint32]$sum = 0
    for ($i = 0; $i -lt 127; $i++) { $sum += $edid[$i] }
    $edid[127] = [byte]((256 - ($sum % 256)) % 256)
    return $edid
}

function Assert-FhdEdid {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Edid,
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][uint32]$BinarySerial
    )

    if ($Edid.Length -ne 128) { throw "Internal EDID error: length is not 128 bytes" }
    $header = [byte[]]@(0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00)
    for ($i = 0; $i -lt 8; $i++) {
        if ($Edid[$i] -ne $header[$i]) { throw "Internal EDID error: invalid header" }
    }
    if ($Edid[18] -ne 1 -or $Edid[19] -ne 4) {
        throw "Internal EDID error: expected EDID 1.4"
    }
    if ($Edid[126] -ne 0) {
        throw "Internal EDID error: a 128-byte EDID must have extension count zero"
    }
    [uint32]$sum = 0
    foreach ($value in $Edid) { $sum += $value }
    if (($sum % 256) -ne 0) { throw "Internal EDID error: invalid checksum" }

    [uint64]$encodedSerial = [uint64]$Edid[12] +
        ([uint64]$Edid[13] * 256) +
        ([uint64]$Edid[14] * 65536) +
        ([uint64]$Edid[15] * 16777216)
    if ($encodedSerial -eq 0 -or $encodedSerial -ne $BinarySerial) {
        throw "Internal EDID error: invalid binary serial"
    }

    $activeX = [int]$Edid[56] + (([int]$Edid[58] -band 0xF0) -shl 4)
    $activeY = [int]$Edid[59] + (([int]$Edid[61] -band 0xF0) -shl 4)
    $widthMm = [int]$Edid[66] + (([int]$Edid[68] -band 0xF0) -shl 4)
    $heightMm = [int]$Edid[67] + (([int]$Edid[68] -band 0x0F) -shl 8)
    if ($activeX -ne $Config.NativeX -or $activeY -ne $Config.NativeY) {
        throw "Internal EDID error: preferred DTD does not match native resolution"
    }
    if ($widthMm -ne $Config.WidthMm -or $heightMm -ne $Config.HeightMm) {
        throw "Internal EDID error: DTD physical size does not match profile"
    }
    if ($Edid[62] -ne 0x58 -or $Edid[63] -ne 0x2C -or
        $Edid[64] -ne 0x45 -or $Edid[65] -ne 0x00 -or $Edid[71] -ne 0x1E) {
        throw "Internal EDID error: preferred DTD sync encoding is invalid"
    }

    $expectedModes = @(
        [pscustomobject]@{ X = 1920; Y = 1080 },
        [pscustomobject]@{ X = 1680; Y = 1050 },
        [pscustomobject]@{ X = 1600; Y = 900 },
        [pscustomobject]@{ X = 1280; Y = 1024 },
        [pscustomobject]@{ X = 1280; Y = 800 },
        [pscustomobject]@{ X = 1280; Y = 720 }
    )
    for ($slot = 0; $slot -lt $expectedModes.Count; $slot++) {
        $xByte = [int]$Edid[38 + 2 * $slot]
        $shape = ([int]$Edid[39 + 2 * $slot] -shr 6) -band 0x03
        $refresh = ([int]$Edid[39 + 2 * $slot] -band 0x3F) + 60
        $x = ($xByte + 31) * 8
        $y = switch ($shape) {
            0 { $x * 10 / 16 }
            1 { $x * 3 / 4 }
            2 { $x * 4 / 5 }
            3 { $x * 9 / 16 }
        }
        if ($x -ne $expectedModes[$slot].X -or
            $y -ne $expectedModes[$slot].Y -or $refresh -ne 60) {
            throw "Internal EDID error: unexpected standard timing in slot $slot"
        }
        if ($x -gt $Config.NativeX -or $y -gt $Config.NativeY -or
            ($x -eq 1920 -and $y -eq 1200)) {
            throw "Internal EDID error: mode exceeds native resolution"
        }
    }
    if ($Edid[50] -ne 0x01 -or $Edid[51] -ne 0x01 -or
        $Edid[52] -ne 0x01 -or $Edid[53] -ne 0x01) {
        throw "Internal EDID error: unused standard timing slots are not empty"
    }
    if ($Edid[35] -ne 0x21 -or $Edid[36] -ne 0x08 -or $Edid[37] -ne 0) {
        throw "Internal EDID error: unexpected established timings"
    }
    if ($Edid[75] -ne 0xFD -or $Edid[93] -ne 0xFC -or $Edid[111] -ne 0xFF) {
        throw "Internal EDID error: descriptor layout is invalid"
    }
}

function Get-FullOutputPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Assert-Administrator {
    if (-not (Test-IsWindows)) {
        throw 'Registry repair can only run on Windows. Use -ListProfiles or -BuildOnly off Windows.'
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this script from an elevated PowerShell session.'
    }
}

function Set-RegistryValue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Type,
        [Parameter(Mandatory = $true)][object]$Value
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -ItemType RegistryKey -Force | Out-Null
    }
    New-ItemProperty -Path $Path -Name $Name -PropertyType $Type -Value $Value -Force | Out-Null
}

function Convert-ToRegExePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $result = $Path -replace '^Microsoft\.PowerShell\.Core\\Registry::', ''
    $result = $result -replace '^HKEY_LOCAL_MACHINE', 'HKLM'
    $result = $result -replace '^HKLM:', 'HKLM'
    return $result
}

function Set-DeviceStringProperty {
    param(
        [Parameter(Mandatory = $true)][string]$DevicePath,
        [Parameter(Mandatory = $true)][string]$PropertyId,
        [Parameter(Mandatory = $true)][string]$Value
    )
    if (-not (Get-Command reg.exe -ErrorAction SilentlyContinue)) { return }
    $formatId = '{a8b865dd-2e3d-4094-ad97-e593a70c75d6}'
    $propertyPath = Join-Path $DevicePath ("Properties\$formatId\$PropertyId")
    $regPath = Convert-ToRegExePath $propertyPath
    # Enum\DISPLAY\...\Properties is commonly owned by TrustedInstaller. The
    # normal DeviceDesc/FriendlyName/Mfg values above are sufficient for the
    # online rescue; a protected DEVPROP slot is only an optional enhancement
    # and must not abort cache clearing/device re-enumeration under PS 5.1's
    # ErrorActionPreference=Stop.
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        & reg.exe add $regPath /v 00000000 /t REG_SZ /d $Value /f 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Verbose "Protected device property was not writable: $regPath"
        }
    } finally {
        $ErrorActionPreference = $savedPreference
    }
}

function Set-MonitorRegistry {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Edid,
        [Parameter(Mandatory = $true)][object]$Config
    )

    $base = 'HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY'
    if (-not (Test-Path -LiteralPath $base)) {
        throw "Windows DISPLAY registry tree was not found: $base"
    }
    $monitorId = $Config.Vendor + ('{0:X4}' -f $Config.ProductId)
    $hardwareId = "MONITOR\$monitorId"
    $compatibleIds = [string[]]@('*PNP09FF')
    $count = 0

    foreach ($device in @(Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue)) {
        foreach ($instance in @(Get-ChildItem -LiteralPath $device.PSPath -ErrorAction SilentlyContinue)) {
            $parameters = Join-Path $instance.PSPath 'Device Parameters'
            Set-RegistryValue $parameters 'EDID' Binary $Edid
            Set-RegistryValue $instance.PSPath 'HardwareID' MultiString ([string[]]@($hardwareId))
            Set-RegistryValue $instance.PSPath 'CompatibleIDs' MultiString $compatibleIds
            Set-RegistryValue $instance.PSPath 'DeviceDesc' String $Config.DisplayName
            Set-RegistryValue $instance.PSPath 'FriendlyName' String $Config.DisplayName
            Set-RegistryValue $instance.PSPath 'Mfg' String $Config.Manufacturer
            Set-DeviceStringProperty $instance.PSPath '0004' $Config.DisplayName
            Set-DeviceStringProperty $instance.PSPath '0009' $Config.Manufacturer
            $count++
            Write-Host ("  DISPLAY\{0}\{1} -> {2}" -f
                $device.PSChildName, $instance.PSChildName, $Config.DisplayName)
        }
    }
    if ($count -eq 0) { throw 'No monitor instances were found under Enum\DISPLAY' }
    return $count
}

function Set-MonitorClassNames {
    param([Parameter(Mandatory = $true)][object]$Config)

    $root = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e96e-e325-11ce-bfc1-08002be10318}'
    if (-not (Test-Path -LiteralPath $root)) { return }
    foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^\d{4}$' })) {
        if (Get-ItemProperty -LiteralPath $key.PSPath -Name DriverDesc -ErrorAction SilentlyContinue) {
            Set-RegistryValue $key.PSPath 'DriverDesc' String $Config.DisplayName
            Set-RegistryValue $key.PSPath 'ProviderName' String $Config.Manufacturer
            Set-DeviceStringProperty $key.PSPath '0004' $Config.DisplayName
            Set-DeviceStringProperty $key.PSPath '0009' $Config.Manufacturer
        }
    }
}

function Clear-GraphicsModeCache {
    $root = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
    foreach ($name in @('Configuration', 'Connectivity', 'ScaleFactors', 'MonitorDataStore')) {
        $path = Join-Path $root $name
        if (-not (Test-Path -LiteralPath $path)) { continue }
        foreach ($entry in @(Get-ChildItem -LiteralPath $path -ErrorAction SilentlyContinue)) {
            try {
                Remove-Item -LiteralPath $entry.PSPath -Recurse -Force -ErrorAction Stop
                Write-Host "  cleared $path\$($entry.PSChildName)"
            } catch {
                Write-Warning "Could not clear graphics cache '$($entry.PSPath)': $($_.Exception.Message)"
            }
        }
    }
}

function Invoke-MonitorDeviceCycle {
    $getPnp = Get-Command Get-PnpDevice -ErrorAction SilentlyContinue
    $disablePnp = Get-Command Disable-PnpDevice -ErrorAction SilentlyContinue
    $enablePnp = Get-Command Enable-PnpDevice -ErrorAction SilentlyContinue
    $monitors = @()
    if ($getPnp) {
        $monitors = @(Get-PnpDevice -Class Monitor -PresentOnly -ErrorAction SilentlyContinue)
    }

    if ($monitors.Count -gt 0 -and $disablePnp -and $enablePnp) {
        foreach ($monitor in $monitors) {
            Write-Host "  cycling $($monitor.InstanceId)"
            Disable-PnpDevice -InstanceId $monitor.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
        }
        Start-Sleep -Milliseconds 500
        foreach ($monitor in $monitors) {
            Enable-PnpDevice -InstanceId $monitor.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
        }
    } elseif ($monitors.Count -gt 0 -and (Get-Command pnputil.exe -ErrorAction SilentlyContinue)) {
        foreach ($monitor in $monitors) {
            & pnputil.exe /disable-device $monitor.InstanceId 2>&1 | Out-Null
        }
        Start-Sleep -Milliseconds 500
        foreach ($monitor in $monitors) {
            & pnputil.exe /enable-device $monitor.InstanceId 2>&1 | Out-Null
        }
    } else {
        Write-Warning 'No present monitor device could be cycled; requesting a PnP rescan only.'
    }
    if (Get-Command pnputil.exe -ErrorAction SilentlyContinue) {
        & pnputil.exe /scan-devices 2>&1 | Out-Null
    }
    Start-Sleep -Seconds 1
}

function Remove-LegacyMonitorTasks {
    $scheduledTaskCommand = Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue
    if ($scheduledTaskCommand) {
        foreach ($task in @(Get-ScheduledTask -ErrorAction SilentlyContinue |
            Where-Object { $_.TaskName -match '^(StealthMonitor|RefreshMonitor)(?:$|[-_ ])' })) {
            Unregister-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath `
                -Confirm:$false -ErrorAction SilentlyContinue
            Write-Host "  removed legacy task $($task.TaskPath)$($task.TaskName)"
        }
    } elseif (Get-Command schtasks.exe -ErrorAction SilentlyContinue) {
        foreach ($name in @(
            'StealthMonitor-Refresh', 'StealthMonitor-Refresh-Logon',
            'RefreshMonitor', 'RefreshMonitor-Refresh', 'RefreshMonitor-Logon'
        )) {
            & schtasks.exe /Delete /TN $name /F 2>&1 | Out-Null
        }
    }
    foreach ($path in @('C:\ProgramData\StealthMonitor', 'C:\ProgramData\RefreshMonitor')) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function ConvertTo-Base64Text {
    param([Parameter(Mandatory = $true)][string]$Text)
    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text))
}

function Install-MonitorRefreshTask {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Edid,
        [Parameter(Mandatory = $true)][object]$Config
    )

    $directory = 'C:\ProgramData\StealthMonitor'
    $scriptPath = Join-Path $directory 'refresh-monitor.ps1'
    New-Item -Path $directory -ItemType Directory -Force | Out-Null

    $monitorId = $Config.Vendor + ('{0:X4}' -f $Config.ProductId)
    $template = @'
# Generated by spoof-monitor.ps1.  This task is installed only by -InstallTask.
$ErrorActionPreference = 'SilentlyContinue'
Start-Sleep -Seconds 3
$edid = [Convert]::FromBase64String('__EDID__')
$displayName = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__NAME__'))
$manufacturer = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__MFG__'))
$hardwareId = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__HWID__'))
$base = 'HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY'
$classRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e96e-e325-11ce-bfc1-08002be10318}'
$formatId = '{a8b865dd-2e3d-4094-ad97-e593a70c75d6}'
function Set-Value($path, $name, $type, $value) {
    if (-not (Test-Path -LiteralPath $path)) {
        New-Item -Path $path -ItemType RegistryKey -Force | Out-Null
    }
    New-ItemProperty -Path $path -Name $name -PropertyType $type -Value $value -Force | Out-Null
}
function To-RegPath($path) {
    $result = $path -replace '^Microsoft\.PowerShell\.Core\\Registry::', ''
    $result = $result -replace '^HKEY_LOCAL_MACHINE', 'HKLM'
    return ($result -replace '^HKLM:', 'HKLM')
}
function Set-DevProp($path, $id, $value) {
    $propertyPath = Join-Path $path ("Properties\$formatId\$id")
    & reg.exe add (To-RegPath $propertyPath) /v 00000000 /t REG_SZ /d $value /f 2>$null | Out-Null
}
foreach ($device in @(Get-ChildItem -LiteralPath $base)) {
    foreach ($instance in @(Get-ChildItem -LiteralPath $device.PSPath)) {
        Set-Value (Join-Path $instance.PSPath 'Device Parameters') EDID Binary $edid
        Set-Value $instance.PSPath HardwareID MultiString ([string[]]@($hardwareId))
        Set-Value $instance.PSPath CompatibleIDs MultiString ([string[]]@('*PNP09FF'))
        Set-Value $instance.PSPath DeviceDesc String $displayName
        Set-Value $instance.PSPath FriendlyName String $displayName
        Set-Value $instance.PSPath Mfg String $manufacturer
        Set-DevProp $instance.PSPath 0004 $displayName
        Set-DevProp $instance.PSPath 0009 $manufacturer
    }
}
foreach ($key in @(Get-ChildItem -LiteralPath $classRoot |
    Where-Object { $_.PSChildName -match '^\d{4}$' })) {
    if (Get-ItemProperty -LiteralPath $key.PSPath -Name DriverDesc) {
        Set-Value $key.PSPath DriverDesc String $displayName
        Set-Value $key.PSPath ProviderName String $manufacturer
        Set-DevProp $key.PSPath 0004 $displayName
        Set-DevProp $key.PSPath 0009 $manufacturer
    }
}
'@
    $body = $template.Replace('__EDID__', [Convert]::ToBase64String($Edid))
    $body = $body.Replace('__NAME__', (ConvertTo-Base64Text $Config.DisplayName))
    $body = $body.Replace('__MFG__', (ConvertTo-Base64Text $Config.Manufacturer))
    $body = $body.Replace('__HWID__', (ConvertTo-Base64Text ("MONITOR\$monitorId")))
    Set-Content -LiteralPath $scriptPath -Value $body -Encoding UTF8 -Force

    if (-not (Get-Command schtasks.exe -ErrorAction SilentlyContinue)) {
        throw 'schtasks.exe is required for -InstallTask'
    }
    $taskRun = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""
    & schtasks.exe /Create /TN 'StealthMonitor-Refresh' /SC ONSTART /RU SYSTEM /RL HIGHEST `
        /TR $taskRun /F 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not create startup monitor refresh task' }
    & schtasks.exe /Create /TN 'StealthMonitor-Refresh-Logon' /SC ONLOGON /RU SYSTEM /RL HIGHEST `
        /TR $taskRun /F 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not create logon monitor refresh task' }
    Write-Host '  installed opt-in startup and logon monitor refresh tasks'
}

$catalogPath = Join-Path $PSScriptRoot 'monitor-profiles.tsv'
if (-not (Test-Path -LiteralPath $catalogPath -PathType Leaf)) {
    # Source-tree convenience for -ListProfiles/-BuildOnly.  The guest rescue
    # staging path always places the catalog beside this script.
    $catalogPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'config/monitor-profiles.tsv'
}
$catalog = @(Get-MonitorCatalog -Path $catalogPath)

if ($ListProfiles) {
    Write-Output "key`tmonitor`tPNP ID`tsize (mm)`tnative`tmode set"
    foreach ($row in $catalog) {
        $item = ConvertTo-MonitorConfig $row
        Write-Output ("{0}`t{1}`t{2}{3:X4}`t{4}x{5}`t{6}x{7}@{8}`t{9}" -f
            $item.Key, $item.DisplayName, $item.Vendor, $item.ProductId,
            $item.WidthMm, $item.HeightMm, $item.NativeX, $item.NativeY,
            $item.RefreshHz, $item.ModeSet)
    }
    return
}

$matches = @($catalog | Where-Object { ([string]$_.key).Trim() -ieq $Profile.Trim() })
if ($matches.Count -ne 1) {
    $available = (($catalog | ForEach-Object { ([string]$_.key).Trim() }) -join ', ')
    throw "Unknown monitor profile '$Profile'. Available profiles: $available"
}
$config = ConvertTo-MonitorConfig $matches[0]

if ([string]::IsNullOrWhiteSpace($Serial)) {
    $effectiveSerial = New-DefaultSerial $config
} else {
    $effectiveSerial = $Serial.Trim()
    if ($effectiveSerial.Length -gt 12 -or
        -not (Test-PrintableAscii -Value $effectiveSerial)) {
        throw '-Serial must contain 1..12 printable ASCII characters'
    }
}
$binarySerial = Get-StableUInt32 -Value $effectiveSerial
[byte[]]$edid = Build-FhdEdid $config $effectiveSerial $binarySerial
Assert-FhdEdid $edid $config $binarySerial

if ($BuildOnly) {
    $outputPath = Get-FullOutputPath $BuildOnly
    $outputDirectory = Split-Path -Parent $outputPath
    if ($outputDirectory -and -not (Test-Path -LiteralPath $outputDirectory)) {
        New-Item -Path $outputDirectory -ItemType Directory -Force | Out-Null
    }
    [IO.File]::WriteAllBytes($outputPath, $edid)
    Write-Host ("Built 128-byte EDID 1.4: {0} ({1}, serial {2}, checksum 0x{3:X2})" -f
        $outputPath, $config.DisplayName, $effectiveSerial, $edid[127])
    return
}

Assert-Administrator
Write-Host ("[spoof-monitor] profile={0} monitor='{1}' PNP={2}{3:X4} serial={4}" -f
    $config.Key, $config.DisplayName, $config.Vendor, $config.ProductId, $effectiveSerial) -ForegroundColor Cyan

Write-Host '[spoof-monitor] removing old persistent monitor-refresh tasks' -ForegroundColor Cyan
Remove-LegacyMonitorTasks

Write-Host '[spoof-monitor] writing EDID, IDs, and friendly names to every DISPLAY instance' -ForegroundColor Cyan
$firstPass = Set-MonitorRegistry $edid $config
Set-MonitorClassNames $config

Write-Host '[spoof-monitor] clearing cached graphics mode and monitor data stores' -ForegroundColor Cyan
Clear-GraphicsModeCache

Write-Host '[spoof-monitor] cycling all present monitor devices' -ForegroundColor Cyan
Invoke-MonitorDeviceCycle

# A PnP cycle can create a fresh instance or let display.inf replace strings.
# Reapply all fields once after enumeration so the final registry state agrees.
Write-Host '[spoof-monitor] synchronizing post-cycle DISPLAY instances' -ForegroundColor Cyan
$secondPass = Set-MonitorRegistry $edid $config
Set-MonitorClassNames $config

if ($InstallTask) {
    Write-Host '[spoof-monitor] installing opt-in persistent refresh task' -ForegroundColor Cyan
    Install-MonitorRefreshTask $edid $config
}

Write-Host ("[spoof-monitor] complete: {0} instance(s) before cycle, {1} after cycle; restart Windows if Settings is still open." -f
    $firstPass, $secondPass) -ForegroundColor Green
