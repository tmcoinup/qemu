#Requires -Version 5.1

<#
.SYNOPSIS
    校验 Windows 显示参数并探测 patched QEMU 的 virtio-vga-gl 能力。

.DESCRIPTION
    GPU 目录当前只提供稳定的品牌/型号标签，不改变虚拟显示设备。本模块只处理
    实际由启动器实现的 SDL、GL、fb-shm ROI 与 hostmem 参数，避免把目录标签
    误解为物理 GPU 直通或完整 PCI 身份实现。
#>

function Split-VMateRoi {
    param([string]$Value)

    if (-not $Value) {
        return ''
    }
    if ($Value -notmatch '^\d+,\d+,\d+,\d+$') {
        throw "FbShmRoi 必须是 x,y,w,h 四个非负整数，实际：$Value"
    }
    $parts = $Value.Split(',')
    if ([int64]$parts[2] -eq 0 -or [int64]$parts[3] -eq 0) {
        throw 'FbShmRoi 的宽和高必须大于零。'
    }
    return ",x=$($parts[0]),y=$($parts[1]),width=$($parts[2]),height=$($parts[3])"
}

function Test-VMateVirtioGpuGl {
    param(
        [string]$Executable,
        [bool]$RequireBlob
    )

    try {
        $probeOutput = & $Executable '-device' 'virtio-vga-gl,help' 2>&1
        $probeText = $probeOutput | Out-String
        if ($LASTEXITCODE -ne 0 -or $probeText -notmatch 'virtio-vga-gl') {
            return $false
        }
        # GL 设备必须接受普通 virtio-vga 相同的 EDID/分辨率投影；显式零拷贝
        # 还必须提供 blob/hostmem。任一能力缺失都由启动器 fail closed。
        $properties = @(Get-VMateMonitorEdidCapabilityProperties) +
            @('xres', 'yres', 'xmax', 'ymax')
        if ($RequireBlob) {
            $properties += @('blob', 'hostmem')
        }
        return Test-VMateQemuHelpProperties -HelpOutput $probeText `
            -Properties $properties
    } catch {
        Write-Verbose "virtio-vga-gl 能力探测失败：$($_.Exception.Message)"
        return $false
    }
}

function Test-VMateGpuHostmem {
    param([string]$Value)

    # hostmem 会成为 guest 可见的 PCI BAR；QEMU PCI 层要求其为 2 的幂。
    # UInt64 TryParse 先拦截超长整数，避免 PowerShell 隐式转换溢出。
    if ($Value -notmatch '^(?<Number>\d+)(?<Unit>[KkMmGg]?)$') {
        return $false
    }
    [uint64]$number = 0
    if (-not [uint64]::TryParse($Matches.Number, [ref]$number)) {
        return $false
    }
    $limits = switch ($Matches.Unit.ToLowerInvariant()) {
        ''  { @([uint64]268435456, [uint64]8589934592) }
        'k' { @([uint64]262144, [uint64]8388608) }
        'm' { @([uint64]256, [uint64]8192) }
        'g' { @([uint64]1, [uint64]8) }
    }
    return $number -ge $limits[0] -and $number -le $limits[1] -and
        (($number -band ($number - 1)) -eq 0)
}
