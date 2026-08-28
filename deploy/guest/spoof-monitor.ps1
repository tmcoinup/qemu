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

# Exact source value from the production-signed GRID 538.33 nvgridsw.inf and
# the reviewed G-11 policy written to the active NVIDIA display-adapter
# software key.  Legacy values are accepted only to migrate VMs that already
# received an older reviewed policy.  The destination contains only modes
# whose R535 128-byte-pitch scanout length is exactly 4-KiB aligned.
$NvidiaGrid53833NvModes = [string[]]@(
    '{*}SHV 1280x720x8,16,32,64 1680x1050x8,16,32,64 1920x1080x8,16,32,64 2048x1536x8,16,32,64=1; 1920x1440x8,16,32,64=1F; 640x480x8,16,32,64 800x600x8,16,32,64 1024x768x8,16,32,64=1FFF; 1920x1200x8,16,32,64=3F; 1600x900x8,16,32,64=3FF; 2560x1440x8,16,32,64 2560x1600x8,16,32,64=7B; 1600x1024x8,16,32,64 1600x1200x8,16,32,64=7F; 1280x768x8,16,32,64 1280x800x8,16,32,64 1280x960x8,16,32,64 1280x1024x8,16,32,64 1360x768x8,16,32,64 1366x768x8,16,32,64=7FF;',
    ' 1152x864x8,16,32,64 1440x1080x8,16,32,64=FFF;S 720x480x8,16,32,64=1; 720x576x8,16,32,64=8032;'
)
$NvidiaLegacyFhdNvModesPolicy = [string[]]@(
    '{*}SHV 1280x720x8,16,32,64 1920x1080x8,16,32,64=1; 640x480x8,16,32,64 800x600x8,16,32,64 1024x768x8,16,32,64=1FFF; 1600x900x8,16,32,64=3FF; 1600x1024x8,16,32,64 1600x1200x8,16,32,64=7F; 1280x768x8,16,32,64 1280x960x8,16,32,64 1280x1024x8,16,32,64 1360x768x8,16,32,64 1366x768x8,16,32,64=7FF;',
    ' 1152x864x8,16,32,64 1440x1080x8,16,32,64=FFF;'
)
$NvidiaPageUnsafeFhdNvModesPolicy = [string[]]@(
    '{*}SHV 1280x720x8,16,32,64 1920x1080x8,16,32,64=1; 640x480x8,16,32,64 800x600x8,16,32,64 1024x768x8,16,32,64=1FFF; 1600x900x8,16,32,64=3FF; 1280x768x8,16,32,64 1280x960x8,16,32,64 1280x1024x8,16,32,64 1360x768x8,16,32,64=7FF;'
)
$NvidiaFhdNvModesPolicy = [string[]]@(
    '{*}SHV 1280x720x8,16,32,64 1920x1080x8,16,32,64=1; 640x480x8,16,32,64 1024x768x8,16,32,64=1FFF; 1280x768x8,16,32,64 1280x960x8,16,32,64 1280x1024x8,16,32,64 1360x768x8,16,32,64=7FF;'
)
$NvidiaFhdModeNames = [string[]]@(
    '1920x1080', '1360x768', '1280x1024', '1280x960',
    '1280x768', '1280x720', '1024x768', '640x480'
)
$NvidiaGrid53833ProviderNames = [string[]]@('NVIDIA', 'NVIDIA Corporation')
$NvidiaGrid53833DriverVersion = '31.0.15.3833'
$NvidiaGrid53833InfSha256 = '67a240e1d464cf97dabfec1a7cecf000eaa9ddfd702f32ba2c8771f17905dc2b'

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

function Get-MonitorSerialPolicy {
    param([Parameter(Mandatory = $true)][string]$Key)

    switch -CaseSensitive ($Key) {
        'samsung-s24f350' { return 'samsung-h4zmc-decimal5' }
        'redmi-rmmnt238nf' { return 'redmi-29200-decimal8' }
        default { return 'generic-prefix-hash' }
    }
}

function Get-MonitorReservedSerials {
    param([Parameter(Mandatory = $true)][string]$Key)

    switch -CaseSensitive ($Key) {
        'samsung-s24f350' {
            return [string[]]@('H4ZMC01676', 'H4ZMC01889')
        }
        'redmi-rmmnt238nf' {
            return [string[]]@('2920000167575', '2920000116680')
        }
        default { return [string[]]@() }
    }
}

function ConvertTo-MonitorConfig {
    param([Parameter(Mandatory = $true)][object]$Row)

    $key = ([string]$Row.key).Trim()
    $vendor = ([string]$Row.vendor).Trim().ToUpperInvariant()
    $edidName = ([string]$Row.edid_name).Trim()
    $displayName = ([string]$Row.display_name).Trim()
    $manufacturer = ([string]$Row.manufacturer).Trim()
    $serialPrefix = ([string]$Row.serial_prefix).Trim()
    $serialPolicy = Get-MonitorSerialPolicy -Key $key
    $reservedSerials = [string[]]@(Get-MonitorReservedSerials -Key $key)
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
    if ($serialPrefix -cnotmatch '^[A-Z0-9]{1,8}$') {
        throw "Profile '$key' serial_prefix must be 1..8 uppercase alphanumeric characters"
    }
    switch ($serialPolicy) {
        'samsung-h4zmc-decimal5' {
            if ($serialPrefix -cne 'H4ZMC') {
                throw "Profile '$key' serial_prefix must be H4ZMC"
            }
        }
        'redmi-29200-decimal8' {
            if ($serialPrefix -cne '29200') {
                throw "Profile '$key' serial_prefix must be 29200"
            }
        }
        'generic-prefix-hash' {
            if ($serialPrefix -ceq 'H4ZMC' -or $serialPrefix -ceq '29200') {
                throw "Profile '$key' uses a serial prefix reserved by a special policy"
            }
        }
        default { throw "Profile '$key' uses unsupported serial policy '$serialPolicy'" }
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
        SerialPolicy  = $serialPolicy
        ReservedSerials = $reservedSerials
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

function Test-MonitorSerial {
    param(
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value
    )

    if ($Value -cin @($Config.ReservedSerials)) { return $false }
    switch ($Config.SerialPolicy) {
        'samsung-h4zmc-decimal5' {
            return $Value -cmatch '^H4ZMC[0-9]{5}$'
        }
        'redmi-29200-decimal8' {
            return $Value -cmatch '^29200[0-9]{8}$'
        }
        'generic-prefix-hash' {
            if ($Value.Length -ne 12 -or
                -not $Value.StartsWith($Config.SerialPrefix,
                    [StringComparison]::Ordinal)) {
                return $false
            }
            $suffix = $Value.Substring($Config.SerialPrefix.Length)
            return $suffix -cmatch '^[0-9A-F]+$'
        }
        default { return $false }
    }
}

function New-DefaultSerial {
    param([Parameter(Mandatory = $true)][object]$Config)

    $prefix = $Config.SerialPrefix
    $stable = [uint64](Get-StableUInt32 -Value ("profile:" + $Config.Key))
    switch ($Config.SerialPolicy) {
        'samsung-h4zmc-decimal5' {
            do {
                $candidate = 'H4ZMC' + ('{0:D5}' -f ($stable % 100000))
                $stable = ($stable + 1) % 100000
            } while ($candidate -cin @($Config.ReservedSerials))
            return $candidate
        }
        'redmi-29200-decimal8' {
            do {
                $candidate = '29200' + ('{0:D8}' -f ($stable % 100000000))
                $stable = ($stable + 1) % 100000000
            } while ($candidate -cin @($Config.ReservedSerials))
            return $candidate
        }
        'generic-prefix-hash' {
            $suffix = '{0:X8}' -f $stable
            $room = 12 - $prefix.Length
            if ($room -lt 4) {
                throw "Profile '$($Config.Key)' serial_prefix leaves too little room for a serial suffix"
            }
            if ($room -lt $suffix.Length) { $suffix = $suffix.Substring(0, $room) }
            return $prefix + $suffix
        }
        default {
            throw "Profile '$($Config.Key)' uses unsupported serial policy '$($Config.SerialPolicy)'"
        }
    }
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

    $edid = New-Object byte[] 256
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

    # R535 presentation rejects 800x600 because its scanout length is not a
    # 4-KiB multiple.  Keep only the page-safe established 60-Hz timings:
    # 640x480 and 1024x768.
    $edid[35] = 0x20
    $edid[36] = 0x08
    $edid[37] = 0x00

    # G-11 uses NVIDIA vGPU, whose EDID parser handles standard timings
    # correctly.  Publish the complete ordinary FHD compatibility list while
    # omitting every 16:10 aspect entry.
    for ($slot = 0; $slot -lt 8; $slot++) {
        $edid[38 + 2 * $slot] = 0x01
        $edid[39 + 2 * $slot] = 0x01
    }
    $standardModes = @(
        [pscustomobject]@{ X = 1920; Aspect = 3 }, # 1920x1080
        [pscustomobject]@{ X = 1280; Aspect = 2 }, # 1280x1024
        [pscustomobject]@{ X = 1280; Aspect = 3 }  # 1280x720
    )
    for ($slot = 0; $slot -lt $standardModes.Count; $slot++) {
        $mode = $standardModes[$slot]
        $edid[38 + 2 * $slot] = [byte](([int]$mode.X / 8) - 31)
        $edid[39 + 2 * $slot] = [byte]([int]$mode.Aspect -shl 6)
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

    # Established Timings III: 1360x768, 1280x1024/960/768.  The bits for
    # 1680x1050 and 1440x900 (both 16:10) remain clear.
    $xtra3 = New-Object byte[] 18
    $xtra3[3] = 0xF7
    $xtra3[5] = 10
    $xtra3[7] = 0x4A
    $xtra3[8] = 0x80
    Set-ByteBlock $edid 72 $xtra3

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
    Set-ByteBlock $edid 90 $range
    Set-ByteBlock $edid 108 (New-TextDescriptor 0xFC $Config.EdidName)

    # One CTA-861 extension.  Its sole data block advertises VIC 16
    # (1920x1080p60) and VIC 4 (1280x720p60); there are no CTA DTDs.
    $edid[126] = 1
    [uint32]$sum = 0
    for ($i = 0; $i -lt 127; $i++) { $sum += $edid[$i] }
    $edid[127] = [byte]((256 - ($sum % 256)) % 256)

    Set-ByteBlock $edid 128 ([byte[]]@(
        0x02, 0x03, 0x07, 0x00, 0x42, 0x10, 0x04
    ))
    Set-ByteBlock $edid 135 (New-TextDescriptor 0xFF $TextSerial)
    $sum = 0
    for ($i = 128; $i -lt 255; $i++) { $sum += $edid[$i] }
    $edid[255] = [byte]((256 - ($sum % 256)) % 256)
    return $edid
}

function Assert-FhdEdid {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Edid,
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][uint32]$BinarySerial
    )

    if ($Edid.Length -ne 256) { throw "Internal EDID error: length is not 256 bytes" }
    $header = [byte[]]@(0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00)
    for ($i = 0; $i -lt 8; $i++) {
        if ($Edid[$i] -ne $header[$i]) { throw "Internal EDID error: invalid header" }
    }
    if ($Edid[18] -ne 1 -or $Edid[19] -ne 4) {
        throw "Internal EDID error: expected EDID 1.4"
    }
    if ($Edid[126] -ne 1) {
        throw "Internal EDID error: expected exactly one CTA extension"
    }
    for ($block = 0; $block -lt 2; $block++) {
        [uint32]$sum = 0
        for ($i = $block * 128; $i -lt ($block + 1) * 128; $i++) {
            $sum += $Edid[$i]
        }
        if (($sum % 256) -ne 0) {
            throw "Internal EDID error: invalid checksum in block $block"
        }
    }

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

    $expectedStandard = [byte[]]@(
        0xD1, 0xC0, # 1920x1080
        0x81, 0x80, # 1280x1024
        0x81, 0xC0, # 1280x720
        0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
        0x01, 0x01
    )
    for ($i = 0; $i -lt $expectedStandard.Length; $i++) {
        if ($Edid[38 + $i] -ne $expectedStandard[$i]) {
            throw "Internal EDID error: unexpected standard timing list"
        }
    }
    if ($Edid[35] -ne 0x20 -or $Edid[36] -ne 0x08 -or $Edid[37] -ne 0) {
        throw "Internal EDID error: unexpected established timings"
    }
    if ($Edid[75] -ne 0xF7 -or $Edid[93] -ne 0xFD -or
        $Edid[111] -ne 0xFC -or $Edid[138] -ne 0xFF) {
        throw "Internal EDID error: descriptor layout is invalid"
    }
    $expectedXtra3 = [byte[]]@(
        0x00, 0x00, 0x00, 0xF7, 0x00, 0x0A, 0x00, 0x4A, 0x80,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    )
    for ($i = 0; $i -lt $expectedXtra3.Length; $i++) {
        if ($Edid[72 + $i] -ne $expectedXtra3[$i]) {
            throw "Internal EDID error: unexpected Established Timings III list"
        }
    }
    $expectedCta = [byte[]]@(0x02, 0x03, 0x07, 0x00, 0x42, 0x10, 0x04)
    for ($i = 0; $i -lt $expectedCta.Length; $i++) {
        if ($Edid[128 + $i] -ne $expectedCta[$i]) {
            throw "Internal EDID error: CTA must advertise only VIC 16 and VIC 4"
        }
    }
    for ($i = 153; $i -lt 255; $i++) {
        if ($Edid[$i] -ne 0) {
            throw "Internal EDID error: unexpected CTA timing or data block"
        }
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

function ConvertTo-NvModeCanonical {
    param([Parameter(Mandatory = $true)][string[]]$Values)

    return [string[]]@(
        foreach ($value in $Values) {
            ([regex]::Replace($value.Trim(), '\s+', ' '))
        }
    )
}

function Test-StringArrayEqual {
    param(
        [Parameter(Mandatory = $true)][string[]]$Left,
        [Parameter(Mandatory = $true)][string[]]$Right
    )

    if ($Left.Count -ne $Right.Count) { return $false }
    for ($i = 0; $i -lt $Left.Count; $i++) {
        if (-not [string]::Equals($Left[$i], $Right[$i],
            [StringComparison]::Ordinal)) { return $false }
    }
    return $true
}

function Get-NvModeNames {
    param([Parameter(Mandatory = $true)][string[]]$Values)

    $seen = @{}
    foreach ($value in $Values) {
        foreach ($match in [regex]::Matches(
            $value, '(?i)(?<!\d)(\d{3,4})x(\d{3,4})x\d+(?:,\d+)*(?![\d,])')) {
            $name = $match.Groups[1].Value + 'x' + $match.Groups[2].Value
            $seen[$name] = $true
        }
    }
    return [string[]]@($seen.Keys | Sort-Object)
}

function Get-R535ConsoleFrameBytes {
    param(
        [Parameter(Mandatory = $true)][int]$Width,
        [Parameter(Mandatory = $true)][int]$Height
    )

    if ($Width -le 0 -or $Height -le 0) {
        throw "Invalid display mode ${Width}x${Height}"
    }
    [int64]$rowBytes = [int64]$Width * 4
    [int64]$pitch = [int64]([Math]::Ceiling($rowBytes / 128.0) * 128)
    return [int64]($pitch * $Height)
}

function Test-R535ConsoleSafeMode {
    param(
        [Parameter(Mandatory = $true)][int]$Width,
        [Parameter(Mandatory = $true)][int]$Height
    )

    $frameBytes = Get-R535ConsoleFrameBytes -Width $Width -Height $Height
    return ($frameBytes % 4096) -eq 0
}

function Assert-NvidiaFhdModePolicy {
    param([Parameter(Mandatory = $true)][string[]]$Values)

    $actualText = ConvertTo-NvModeCanonical $Values
    $policyText = ConvertTo-NvModeCanonical $NvidiaFhdNvModesPolicy
    if (-not (Test-StringArrayEqual -Left $actualText -Right $policyText)) {
        throw 'NV_Modes is not the exact G-11 FHD policy'
    }
    $actualModes = Get-NvModeNames $Values
    $expectedModes = [string[]]@($NvidiaFhdModeNames | Sort-Object)
    if (-not (Test-StringArrayEqual -Left $actualModes -Right $expectedModes)) {
        throw "G-11 NV_Modes mode set differs: $($actualModes -join ', ')"
    }
    foreach ($name in $actualModes) {
        $parts = $name.Split('x')
        if (([int]$parts[0] * 10) -eq ([int]$parts[1] * 16)) {
            throw "G-11 NV_Modes contains forbidden 16:10 mode: $name"
        }
        if (-not (Test-R535ConsoleSafeMode `
                -Width ([int]$parts[0]) -Height ([int]$parts[1]))) {
            $frameBytes = Get-R535ConsoleFrameBytes `
                -Width ([int]$parts[0]) -Height ([int]$parts[1])
            throw ("G-11 NV_Modes contains R535 page-unsafe mode: " +
                ("{0} frame=0x{1:X}" -f $name, $frameBytes))
        }
    }
}

function Set-NvidiaFhdModePolicy {
    $instanceIds = @()
    if (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue) {
        $instanceIds = @(
            Get-PnpDevice -Class Display -PresentOnly -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty InstanceId
        )
    }
    if ($instanceIds.Count -eq 0 -and
        (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)) {
        $instanceIds = @(
            Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
                Where-Object { $_.PNPClass -eq 'Display' -and $_.Present } |
                Select-Object -ExpandProperty PNPDeviceID
        )
    }
    if ($instanceIds.Count -eq 0) {
        throw 'Get-PnpDevice or Get-CimInstance is required to locate the active display adapter'
    }

    $classGuid = '{4d36e968-e325-11ce-bfc1-08002be10318}'
    $classRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class'
    $targets = @{}
    foreach ($instanceId in $instanceIds) {
        if ($instanceId -notmatch '^PCI\\VEN_10DE&') { continue }
        $enumPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$instanceId"
        $device = Get-ItemProperty -LiteralPath $enumPath -ErrorAction Stop
        if (([string]$device.Service) -ine 'nvlddmkm') { continue }
        if ($null -ne $device.ClassGUID -and
            ([string]$device.ClassGUID) -ine $classGuid) {
            throw "Active NVIDIA display has unexpected ClassGUID: $($device.ClassGUID)"
        }
        $driver = [string]$device.Driver
        if ($driver -notmatch '^\{4d36e968-e325-11ce-bfc1-08002be10318\}\\\d{4}$') {
            throw "Active nvlddmkm device has an unexpected Driver relation: '$driver'"
        }
        $target = Join-Path $classRoot $driver
        if (-not (Test-Path -LiteralPath $target)) {
            throw "Active NVIDIA display software key was not found: $target"
        }
        $targets[$target.ToLowerInvariant()] = $target
    }
    if ($targets.Count -eq 0) {
        throw 'No present PCI VEN_10DE display device bound to nvlddmkm was found'
    }

    [string[]]$sourceText = @(ConvertTo-NvModeCanonical $NvidiaGrid53833NvModes)
    [string[]]$legacyPolicyText = @(ConvertTo-NvModeCanonical $NvidiaLegacyFhdNvModesPolicy)
    [string[]]$pageUnsafePolicyText = @(
        ConvertTo-NvModeCanonical $NvidiaPageUnsafeFhdNvModesPolicy)
    [string[]]$policyText = @(ConvertTo-NvModeCanonical $NvidiaFhdNvModesPolicy)
    Assert-NvidiaFhdModePolicy $NvidiaFhdNvModesPolicy
    $plans = @()

    # Validate every target and value before the first write.  An unknown
    # secondary adapter or driver package must not leave the first adapter
    # half-migrated.  The INF identity is locked independently of NV_Modes:
    # another NVIDIA release may publish the same value with different
    # semantics and is not an approved migration source.
    foreach ($target in $targets.Values) {
        $registryKey = Get-Item -LiteralPath $target -ErrorAction Stop
        foreach ($identityName in @('ProviderName', 'DriverVersion', 'InfPath')) {
            $identityKind = $registryKey.GetValueKind($identityName)
            if ($identityKind -ne [Microsoft.Win32.RegistryValueKind]::String) {
                throw "$identityName at $target is $identityKind, expected REG_SZ"
            }
        }
        $providerName = [string]$registryKey.GetValue(
            'ProviderName', $null,
            [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $providerAccepted = $false
        foreach ($expectedProvider in $NvidiaGrid53833ProviderNames) {
            if ([string]::Equals($providerName, $expectedProvider,
                [StringComparison]::OrdinalIgnoreCase)) {
                $providerAccepted = $true
                break
            }
        }
        if (-not $providerAccepted) {
            throw "ProviderName at $target is not an approved NVIDIA provider: '$providerName'"
        }

        $driverVersion = [string]$registryKey.GetValue(
            'DriverVersion', $null,
            [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if (-not [string]::Equals($driverVersion, $NvidiaGrid53833DriverVersion,
            [StringComparison]::Ordinal)) {
            throw "DriverVersion at $target is '$driverVersion', expected $NvidiaGrid53833DriverVersion"
        }

        $infPath = [string]$registryKey.GetValue(
            'InfPath', $null,
            [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($infPath -cnotmatch '^oem(?:0|[1-9][0-9]*)\.inf$') {
            throw "InfPath at $target is not canonical oemN.inf: '$infPath'"
        }
        if ([string]::IsNullOrEmpty($env:SystemRoot)) {
            throw 'SystemRoot is empty; cannot authenticate the published NVIDIA INF'
        }
        $publishedInf = Join-Path (Join-Path $env:SystemRoot 'INF') $infPath
        if (-not (Test-Path -LiteralPath $publishedInf -PathType Leaf)) {
            throw "Published NVIDIA INF was not found: $publishedInf"
        }
        $publishedInfHash = (Get-FileHash -LiteralPath $publishedInf -Algorithm SHA256 `
            -ErrorAction Stop).Hash
        if (-not [string]::Equals($publishedInfHash, $NvidiaGrid53833InfSha256,
            [StringComparison]::OrdinalIgnoreCase)) {
            throw "Published NVIDIA INF hash mismatch at $publishedInf"
        }

        $kind = $registryKey.GetValueKind('NV_Modes')
        if ($kind -ne [Microsoft.Win32.RegistryValueKind]::MultiString) {
            throw "NV_Modes at $target is $kind, expected REG_MULTI_SZ"
        }
        # Windows PowerShell 5.1 can stringify a REG_MULTI_SZ returned by
        # Get-ItemPropertyValue into one concatenated string.  Read it through
        # the raw RegistryKey API so the original element boundaries survive;
        # those boundaries are part of the reviewed NVIDIA migration source.
        $existing = [string[]]@($registryKey.GetValue(
            'NV_Modes', $null,
            [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames))
        [string[]]$existingText = @(ConvertTo-NvModeCanonical $existing)
        if (Test-StringArrayEqual -Left $existingText -Right $policyText) {
            Assert-NvidiaFhdModePolicy $existing
            $needsWrite = $false
        } elseif ((Test-StringArrayEqual -Left $existingText -Right $sourceText) -or
                  (Test-StringArrayEqual -Left $existingText -Right $legacyPolicyText) -or
                  (Test-StringArrayEqual -Left $existingText -Right $pageUnsafePolicyText)) {
            $needsWrite = $true
        } else {
            $existingLengths = (@($existingText | ForEach-Object { $_.Length }) -join ',')
            $sourceLengths = (@($sourceText | ForEach-Object { $_.Length }) -join ',')
            throw (("Refusing to overwrite unknown NV_Modes at {0} " +
                "(actual count/lengths={1}/{2}; approved source={3}/{4})") -f
                $target, $existingText.Count, $existingLengths,
                $sourceText.Count, $sourceLengths)
        }
        $plans += [pscustomobject]@{
            Path       = $target
            NeedsWrite = $needsWrite
            Original   = $existing
        }
    }

    $writes = 0
    $committed = @()
    try {
        foreach ($plan in $plans) {
            if (-not $plan.NeedsWrite) {
                Write-Host "  $($plan.Path) NV_Modes already matches the $($NvidiaFhdModeNames.Count)-mode R535 page-safe FHD policy"
                continue
            }
            Set-RegistryValue $plan.Path 'NV_Modes' MultiString $NvidiaFhdNvModesPolicy
            $committed += $plan
            $writtenKey = Get-Item -LiteralPath $plan.Path -ErrorAction Stop
            $writtenKind = $writtenKey.GetValueKind('NV_Modes')
            if ($writtenKind -ne [Microsoft.Win32.RegistryValueKind]::MultiString) {
                throw "NV_Modes write at $($plan.Path) produced $writtenKind"
            }
            $written = [string[]]@($writtenKey.GetValue(
                'NV_Modes', $null,
                [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames))
            Assert-NvidiaFhdModePolicy $written
            $writes++
            Write-Host "  $($plan.Path) NV_Modes -> $($NvidiaFhdModeNames.Count) reviewed R535 page-safe FHD/1K PC modes"
        }
    } catch {
        $failure = $_
        foreach ($plan in $committed) {
            try {
                Set-RegistryValue $plan.Path 'NV_Modes' MultiString $plan.Original
                Write-Warning "Rolled back NV_Modes at $($plan.Path) after a failed multi-adapter write"
            } catch {
                Write-Warning "Could not roll back NV_Modes at $($plan.Path): $($_.Exception.Message)"
            }
        }
        throw $failure
    }
    return $targets.Count
}

function Convert-ToRegExePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $result = $Path -replace '^Microsoft\.PowerShell\.Core\\Registry::', ''
    $result = $result -replace '^HKEY_LOCAL_MACHINE', 'HKLM'
    $result = $result -replace '^HKLM:', 'HKLM'
    return $result
}

function Set-MonitorRegistryValue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Binary', 'String', 'MultiString')][string]$Type,
        [Parameter(Mandatory = $true)][object]$Value
    )
    if (-not (Get-Command reg.exe -ErrorAction SilentlyContinue)) {
        throw 'reg.exe is required to update the protected monitor instance tree'
    }
    $regPath = Convert-ToRegExePath $Path
    $regType = switch ($Type) {
        'Binary' { 'REG_BINARY' }
        'String' { 'REG_SZ' }
        'MultiString' { 'REG_MULTI_SZ' }
    }
    $regData = switch ($Type) {
        'Binary' {
            -join @([byte[]]$Value | ForEach-Object { $_.ToString('X2') })
        }
        'String' { [string]$Value }
        'MultiString' { ([string[]]$Value) -join '\0' }
    }
    & reg.exe add $regPath /v $Name /t $regType /d $regData /f 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Could not write $regPath\$Name as $regType"
    }

    $writtenKey = Get-Item -LiteralPath $Path -ErrorAction Stop
    $expectedKind = switch ($Type) {
        'Binary' { [Microsoft.Win32.RegistryValueKind]::Binary }
        'String' { [Microsoft.Win32.RegistryValueKind]::String }
        'MultiString' { [Microsoft.Win32.RegistryValueKind]::MultiString }
    }
    if ($writtenKey.GetValueKind($Name) -ne $expectedKind) {
        throw "$regPath\$Name failed registry-type verification"
    }
    $actual = $writtenKey.GetValue(
        $Name, $null,
        [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    switch ($Type) {
        'Binary' {
            [byte[]]$expectedBytes = $Value
            [byte[]]$actualBytes = $actual
            if ($actualBytes.Length -ne $expectedBytes.Length) {
                throw "$regPath\$Name failed binary-length verification"
            }
            for ($index = 0; $index -lt $expectedBytes.Length; $index++) {
                if ($actualBytes[$index] -ne $expectedBytes[$index]) {
                    throw "$regPath\$Name failed binary read-back verification"
                }
            }
        }
        'String' {
            if (-not [string]::Equals([string]$actual, [string]$Value,
                [StringComparison]::Ordinal)) {
                throw "$regPath\$Name failed string read-back verification"
            }
        }
        'MultiString' {
            [string[]]$actualStrings = @($actual)
            [string[]]$expectedStrings = $Value
            if (-not (Test-StringArrayEqual -Left $actualStrings `
                -Right $expectedStrings)) {
                throw "$regPath\$Name failed multi-string read-back verification"
            }
        }
    }
}

function Set-EdidOverride {
    param(
        [Parameter(Mandatory = $true)][string]$ParametersPath,
        [Parameter(Mandatory = $true)][byte[]]$Edid
    )
    if ($Edid.Length -eq 0 -or ($Edid.Length % 128) -ne 0) {
        throw "EDID override requires non-empty 128-byte blocks; got $($Edid.Length) bytes"
    }
    $blockCount = [int]($Edid.Length / 128)
    if ($blockCount -ne ([int]$Edid[126] + 1)) {
        throw "EDID extension count does not match its $blockCount blocks"
    }
    if (-not (Get-Command reg.exe -ErrorAction SilentlyContinue)) {
        throw 'reg.exe is required to publish EDID_OVERRIDE reliably'
    }

    $overridePath = Join-Path $ParametersPath 'EDID_OVERRIDE'
    $regPath = Convert-ToRegExePath $overridePath
    # Recreate this one target-scoped key so a shorter replacement EDID cannot
    # inherit stale block 2/3 values. reg.exe is used deliberately: it is the
    # supported path that stayed responsive on the locked Enum\DISPLAY tree on
    # Windows PowerShell 5.1 in the GRID guest.
    $savedPreference = $ErrorActionPreference
    try {
        # Missing is the normal first-run state. PowerShell 5.1 otherwise
        # promotes reg.exe's expected stderr to a terminating NativeCommandError
        # before the following exact-key create can run.
        $ErrorActionPreference = 'SilentlyContinue'
        & reg.exe delete $regPath /f 2>$null | Out-Null
    } finally {
        $ErrorActionPreference = $savedPreference
    }
    # Do not issue a key-only `reg add`: on Windows 10 that materializes an
    # empty default REG_SZ. Writing block 0 directly creates the key with only
    # the Microsoft-defined numeric REG_BINARY values.
    for ($blockNumber = 0; $blockNumber -lt $blockCount; $blockNumber++) {
        $offset = $blockNumber * 128
        [byte[]]$block = $Edid[$offset..($offset + 127)]
        $hex = -join @($block | ForEach-Object { $_.ToString('X2') })
        & reg.exe add $regPath /v ([string]$blockNumber) /t REG_BINARY `
            /d $hex /f 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Could not write $regPath\$blockNumber"
        }
    }

    $writtenKey = Get-Item -LiteralPath $overridePath -ErrorAction Stop
    [string[]]$writtenNames = @($writtenKey.GetValueNames() | Sort-Object)
    [string[]]$expectedNames = @(0..($blockCount - 1) |
        ForEach-Object { [string]$_ })
    if (-not (Test-StringArrayEqual -Left $writtenNames `
        -Right $expectedNames)) {
        throw "EDID_OVERRIDE value names are not exactly 0..$($blockCount - 1)"
    }
    for ($blockNumber = 0; $blockNumber -lt $blockCount; $blockNumber++) {
        if ($writtenKey.GetValueKind([string]$blockNumber) -ne
            [Microsoft.Win32.RegistryValueKind]::Binary) {
            throw "EDID_OVERRIDE\$blockNumber is not REG_BINARY"
        }
        [byte[]]$actual = $writtenKey.GetValue([string]$blockNumber)
        if ($actual.Length -ne 128) {
            throw "EDID_OVERRIDE\$blockNumber has the wrong length"
        }
        for ($index = 0; $index -lt 128; $index++) {
            if ($actual[$index] -ne $Edid[$blockNumber * 128 + $index]) {
                throw "EDID_OVERRIDE\$blockNumber failed read-back verification"
            }
        }
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
            $deviceParametersPath = Join-Path $instance.PSPath 'Device Parameters'
            if (-not (Test-Path -LiteralPath $deviceParametersPath)) { continue }
            $parameterKey = Get-Item -LiteralPath $deviceParametersPath -ErrorAction Stop
            if (@($parameterKey.GetValueNames()) -notcontains 'EDID') { continue }
            # Invoke the exact-key override before any child function can alter
            # a dynamically scoped local under Windows PowerShell 5.1, and
            # recompute the provider path for each protected-tree write.
            Set-EdidOverride -ParametersPath `
                ([string](Join-Path $instance.PSPath 'Device Parameters')) `
                -Edid $Edid
            Set-MonitorRegistryValue `
                -Path ([string](Join-Path $instance.PSPath 'Device Parameters')) `
                -Name 'EDID' -Type Binary -Value $Edid
            Set-MonitorRegistryValue $instance.PSPath 'HardwareID' MultiString `
                ([string[]]@($hardwareId))
            Set-MonitorRegistryValue $instance.PSPath 'CompatibleIDs' MultiString `
                $compatibleIds
            Set-MonitorRegistryValue $instance.PSPath 'DeviceDesc' String `
                $Config.DisplayName
            Set-MonitorRegistryValue $instance.PSPath 'FriendlyName' String `
                $Config.DisplayName
            Set-MonitorRegistryValue $instance.PSPath 'Mfg' String `
                $Config.Manufacturer
            $count++
            Write-Host ("  DISPLAY\{0}\{1} -> {2}; EDID_OVERRIDE={3} block(s)" -f
                $device.PSChildName, $instance.PSChildName,
                $Config.DisplayName, ($Edid.Length / 128))
        }
    }
    if ($count -eq 0) { throw 'No monitor instances were found under Enum\DISPLAY' }
    return $count
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
$ErrorActionPreference = 'Stop'
Start-Sleep -Seconds 3
$edid = [Convert]::FromBase64String('__EDID__')
$displayName = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__NAME__'))
$manufacturer = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__MFG__'))
$hardwareId = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__HWID__'))
$base = 'HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY'
function To-RegPath($path) {
    $result = $path -replace '^Microsoft\.PowerShell\.Core\\Registry::', ''
    $result = $result -replace '^HKEY_LOCAL_MACHINE', 'HKLM'
    return ($result -replace '^HKLM:', 'HKLM')
}
function Set-Value($path, $name, $type, $value) {
    $regPath = To-RegPath $path
    $regType = switch ($type) {
        Binary { 'REG_BINARY' }
        String { 'REG_SZ' }
        MultiString { 'REG_MULTI_SZ' }
        default { throw "Unsupported registry type $type" }
    }
    $data = switch ($type) {
        Binary { -join @([byte[]]$value | ForEach-Object { $_.ToString('X2') }) }
        String { [string]$value }
        MultiString { ([string[]]$value) -join '\0' }
    }
    & reg.exe add $regPath /v $name /t $regType /d $data /f 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Could not write $regPath\$name as $regType"
    }
    $key = Get-Item -LiteralPath $path -ErrorAction Stop
    $expectedKind = switch ($type) {
        Binary { [Microsoft.Win32.RegistryValueKind]::Binary }
        String { [Microsoft.Win32.RegistryValueKind]::String }
        MultiString { [Microsoft.Win32.RegistryValueKind]::MultiString }
    }
    if ($key.GetValueKind($name) -ne $expectedKind) {
        throw "$regPath\$name failed registry-type verification"
    }
}
function Set-Override($deviceParametersPath, [byte[]]$bytes) {
    if ($bytes.Length -eq 0 -or ($bytes.Length % 128) -ne 0) {
        throw 'Invalid EDID block length'
    }
    $count = [int]($bytes.Length / 128)
    if ($count -ne ([int]$bytes[126] + 1)) {
        throw 'EDID extension count mismatch'
    }
    $path = Join-Path $deviceParametersPath 'EDID_OVERRIDE'
    $regPath = To-RegPath $path
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        & reg.exe delete $regPath /f 2>$null | Out-Null
    } finally {
        $ErrorActionPreference = $savedPreference
    }
    for ($blockNumber = 0; $blockNumber -lt $count; $blockNumber++) {
        $offset = $blockNumber * 128
        [byte[]]$block = $bytes[$offset..($offset + 127)]
        $hex = -join @($block | ForEach-Object { $_.ToString('X2') })
        & reg.exe add $regPath /v ([string]$blockNumber) /t REG_BINARY `
            /d $hex /f 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Could not write $regPath\$blockNumber"
        }
    }
    $key = Get-Item -LiteralPath $path -ErrorAction Stop
    if (@($key.GetValueNames()).Count -ne $count) {
        throw 'EDID_OVERRIDE retained a stale block'
    }
    for ($blockNumber = 0; $blockNumber -lt $count; $blockNumber++) {
        [byte[]]$actual = $key.GetValue([string]$blockNumber)
        if ($actual.Length -ne 128) {
            throw "EDID_OVERRIDE\$blockNumber has the wrong length"
        }
        for ($index = 0; $index -lt 128; $index++) {
            if ($actual[$index] -ne $bytes[$blockNumber * 128 + $index]) {
                throw "EDID_OVERRIDE\$blockNumber failed verification"
            }
        }
    }
}
foreach ($device in @(Get-ChildItem -LiteralPath $base)) {
    foreach ($instance in @(Get-ChildItem -LiteralPath $device.PSPath)) {
        $deviceParametersPath = Join-Path $instance.PSPath 'Device Parameters'
        if (-not (Test-Path -LiteralPath $deviceParametersPath)) { continue }
        $parameterKey = Get-Item -LiteralPath $deviceParametersPath
        if (@($parameterKey.GetValueNames()) -notcontains 'EDID') { continue }
        Set-Value $deviceParametersPath EDID Binary $edid
        Set-Override $deviceParametersPath $edid
        Set-Value $instance.PSPath HardwareID MultiString ([string[]]@($hardwareId))
        Set-Value $instance.PSPath CompatibleIDs MultiString ([string[]]@('*PNP09FF'))
        Set-Value $instance.PSPath DeviceDesc String $displayName
        Set-Value $instance.PSPath FriendlyName String $displayName
        Set-Value $instance.PSPath Mfg String $manufacturer
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
}
if (-not (Test-MonitorSerial -Config $config -Value $effectiveSerial)) {
    throw "-Serial does not match profile '$($config.Key)' policy '$($config.SerialPolicy)'"
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
    Write-Host ("Built 256-byte EDID 1.4 + CTA: {0} ({1}, serial {2}, checksums 0x{3:X2}/0x{4:X2})" -f
        $outputPath, $config.DisplayName, $effectiveSerial, $edid[127], $edid[255])
    return
}

Assert-Administrator
Write-Host ("[spoof-monitor] profile={0} monitor='{1}' PNP={2}{3:X4} serial={4}" -f
    $config.Key, $config.DisplayName, $config.Vendor, $config.ProductId, $effectiveSerial) -ForegroundColor Cyan

Write-Host '[spoof-monitor] validating and applying the locked NVIDIA FHD/1K source-mode policy' -ForegroundColor Cyan
$nvidiaModeTargets = Set-NvidiaFhdModePolicy

Write-Host '[spoof-monitor] removing old persistent monitor-refresh tasks' -ForegroundColor Cyan
Remove-LegacyMonitorTasks

Write-Host '[spoof-monitor] writing EDID, IDs, and friendly names to every DISPLAY instance' -ForegroundColor Cyan
$firstPass = Set-MonitorRegistry $edid $config

Write-Host '[spoof-monitor] clearing cached graphics mode and monitor data stores' -ForegroundColor Cyan
Clear-GraphicsModeCache

Write-Host '[spoof-monitor] cycling all present monitor devices' -ForegroundColor Cyan
Invoke-MonitorDeviceCycle

# A PnP cycle can create a fresh instance or let display.inf replace strings.
# Reapply all fields once after enumeration so the final registry state agrees.
Write-Host '[spoof-monitor] synchronizing post-cycle DISPLAY instances' -ForegroundColor Cyan
$secondPass = Set-MonitorRegistry $edid $config

if ($InstallTask) {
    Write-Host '[spoof-monitor] installing opt-in persistent refresh task' -ForegroundColor Cyan
    Install-MonitorRefreshTask $edid $config
}

Write-Host ("[spoof-monitor] complete: {0} instance(s) before cycle, {1} after cycle; NVIDIA mode targets={2}; fully restart Windows before validating the mode list." -f
    $firstPass, $secondPass, $nvidiaModeTargets) -ForegroundColor Green
