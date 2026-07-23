#Requires -Version 5.1

<#
.SYNOPSIS
    把已选择的部件身份投影到运行时参数与磁盘预检。
#>

function Get-VMateNvmeSubnqn {
    param(
        [object]$Components,
        [string]$Uuid
    )

    if ($Uuid -notmatch
        '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' -or
        $Uuid -in @('00000000-0000-4000-8000-000000000000',
            'ffffffff-ffff-4fff-bfff-ffffffffffff')) {
        throw 'NVMe subnqn 需要规范的小写 RFC 4122 v4 UUID。'
    }
    $value = ([string]$Components.storage.nvme.subnqn_template).
        Replace('{uuid}', $Uuid)
    if ($value -notmatch
        '^nqn\.2014-08\.org\.nvmexpress:uuid:[0-9a-f-]{36}$' -or
        [System.Text.Encoding]::UTF8.GetByteCount($value) -gt 223 -or
        $value -match '[{},\r\n]') {
        throw '由部件目录生成的 NVMe subnqn 无效。'
    }
    return $value
}

function Get-VMateMonitorEdidSuffix {
    param(
        [object]$Components,
        [object]$Profile
    )

    $monitor = $Components.monitor
    $monitorSerial = [string]$Profile.identity.monitor_serial
    Assert-VMateMonitorSerial $monitor $monitorSerial
    $binarySerial = Get-VMateMonitorBinarySerial $monitor $monitorSerial
    $range = $monitor.range
    $timing = $monitor.secondary_timing
    $fields = [ordered]@{
        'edid-managed-timing-version' = 1
        'edid-vendor' = [string]$monitor.vendor_code
        'edid-name' = [string]$monitor.name
        'edid-serial' = $monitorSerial
        'edid-binary-serial' = $binarySerial
        'edid-revision' = [int]$monitor.edid_revision
        'edid-width-mm' = [int]$monitor.width_mm
        'edid-height-mm' = [int]$monitor.height_mm
        'edid-product-id' = ([string]$monitor.product_id).ToLowerInvariant()
        'edid-manufacture-week' = [int]$monitor.manufacture_week
        'edid-manufacture-year' = [int]$monitor.manufacture_year
        'edid-video-input' = ([string]$monitor.video_input).ToLowerInvariant()
        'edid-min-vfreq-hz' = [int]$range.min_vfreq_hz
        'edid-max-vfreq-hz' = [int]$range.max_vfreq_hz
        'edid-min-hfreq-khz' = [int]$range.min_hfreq_khz
        'edid-max-hfreq-khz' = [int]$range.max_hfreq_khz
        'edid-max-pixel-clock-mhz' = [int]$range.max_pixel_clock_mhz
        'edid-secondary-xres' = [int]$timing.xres
        'edid-secondary-yres' = [int]$timing.yres
        'edid-secondary-refresh-rate' = [int]$timing.refresh_millihz
    }
    $pairs = @($fields.GetEnumerator() | ForEach-Object {
        $_.Key + '=' + (ConvertTo-VMateQemuString ([string]$_.Value))
    })
    return ',' + ($pairs -join ',')
}

function Assert-VMateQemuImgVersion {
    param([string]$VersionOutput)

    if ($VersionOutput -notmatch '^qemu-img version 11\.0\.2(?:\s|\()') {
        throw "qemu-img 必须与当前 QEMU 11.0.2 构建同版本；实际输出：$VersionOutput"
    }
}

function Assert-VMateStorageInfo {
    param(
        [object]$Info,
        [object]$ExpectedBytes = $null
    )

    if ([string]$Info.format -cne 'qcow2') {
        throw "磁盘格式 $($Info.format) 不是启动器要求的 qcow2。"
    }
    [int64]$virtualSize = 0
    if ($null -eq $Info -or
        -not [int64]::TryParse(
            [string]$Info.'virtual-size', [ref]$virtualSize) -or
        $virtualSize -lt 1) {
        throw 'qemu-img 输出缺少有效的正整数 virtual-size。'
    }
    if ($null -ne $ExpectedBytes -and
        $virtualSize -ne [int64]$ExpectedBytes) {
        throw "磁盘虚拟容量 $virtualSize bytes 与部件目录 $ExpectedBytes bytes 不一致。"
    }
}

function Get-VMateStorageInfo {
    param(
        [string]$QemuImg,
        [string]$Disk
    )

    if (-not (Test-Path -LiteralPath $QemuImg -PathType Leaf)) {
        throw "找不到同版本 qemu-img.exe，无法核验 NVMe 容量：$QemuImg"
    }
    if (-not (Test-Path -LiteralPath $Disk -PathType Leaf)) {
        throw "磁盘不存在，无法核验 NVMe 容量：$Disk"
    }
    try {
        $versionOutput = & $QemuImg '--version' 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            throw "qemu-img --version exit code=$LASTEXITCODE；$versionOutput"
        }
        Assert-VMateQemuImgVersion -VersionOutput $versionOutput
        $output = & $QemuImg 'info' '--output=json' $Disk 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            throw "qemu-img exit code=$LASTEXITCODE；$output"
        }
        $info = $output | ConvertFrom-Json -ErrorAction Stop
        Assert-VMateStorageInfo -Info $info
    } catch {
        throw "无法核验磁盘版本、格式和虚拟容量：$($_.Exception.Message)"
    }
    return $info
}

function Get-VMateStorageVirtualSize {
    param(
        [string]$QemuImg,
        [string]$Disk
    )

    $info = Get-VMateStorageInfo -QemuImg $QemuImg -Disk $Disk
    return [int64]$info.'virtual-size'
}

function Assert-VMateStorageCapacity {
    param(
        [string]$QemuImg,
        [string]$Disk,
        [int64]$ExpectedBytes,
        [bool]$DryRun
    )

    if ($DryRun) {
        return
    }
    $info = Get-VMateStorageInfo -QemuImg $QemuImg -Disk $Disk
    Assert-VMateStorageInfo -Info $info -ExpectedBytes $ExpectedBytes
}
