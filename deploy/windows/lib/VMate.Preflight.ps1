#Requires -Version 5.1

<#
.SYNOPSIS
    Windows/WHPX 宿主能力探测与客体策略门禁。

.DESCRIPTION
    真正启动前必须证明 QEMU 版本、WHPX 构建能力和 Windows hypervisor 状态。
    DryRun 使用显式测试身份，不读取或改变宿主功能；TCG 只有用户传入
    -AllowTcgFallback 后才进入加速器列表，避免性能和 CPU 表面被静默替换。
#>

function Get-VMateHostCpuIdentity {
    param(
        [bool]$DryRun,
        [string]$DryRunVendorId = 'GenuineIntel',
        [string]$DryRunName = 'Intel(R) Test CPU',
        [int]$DryRunCores = 4,
        [int]$DryRunLogicalProcessors = 4,
        [int]$DryRunMaxMhz = 3600
    )

    if ($DryRun) {
        return [pscustomobject]@{
            vendor_id = $DryRunVendorId
            name = $DryRunName
            cores = $DryRunCores
            logical_processors = $DryRunLogicalProcessors
            max_mhz = $DryRunMaxMhz
        }
    }
    if ($env:OS -ne 'Windows_NT') {
        throw 'WHPX 启动器只能在 Windows 宿主运行；跨平台检查请使用 -DryRun。'
    }

    try {
        $processors = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop)
    } catch {
        throw "无法读取 Win32_Processor：$($_.Exception.Message)"
    }
    if ($processors.Count -lt 1) {
        throw 'Win32_Processor 没有返回任何 CPU。'
    }
    $vendor = [string]$processors[0].Manufacturer
    if ($vendor -notin @('GenuineIntel', 'AuthenticAMD')) {
        throw "当前共享平台只支持 GenuineIntel/AuthenticAMD，实际：$vendor"
    }
    return [pscustomobject]@{
        vendor_id = $vendor
        name = ([string]$processors[0].Name).Trim()
        cores = [int](($processors | Measure-Object NumberOfCores -Sum).Sum)
        logical_processors = [int](
            ($processors | Measure-Object NumberOfLogicalProcessors -Sum).Sum)
        max_mhz = [int](($processors | Measure-Object MaxClockSpeed -Maximum).Maximum)
    }
}

function Get-VMateWindowsBuild {
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $parts = ([string]$os.Version).Split('.')
        if ($parts.Count -lt 3) {
            throw "无法解析版本：$($os.Version)"
        }
        return [int]$parts[2]
    } catch {
        throw "无法读取 Windows build：$($_.Exception.Message)"
    }
}

function Get-VMateWhpxProblems {
    param([string]$Qemu)

    $problems = [System.Collections.Generic.List[string]]::new()
    try {
        $system = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        if ($system.HypervisorPresent -ne $true) {
            [void]$problems.Add('Windows hypervisor 尚未运行，请启用虚拟化并重启宿主。')
        }
    } catch {
        [void]$problems.Add("无法确认 HypervisorPresent：$($_.Exception.Message)")
    }

    # OptionalFeature 查询在非管理员会话可能拒绝访问，所以只有成功读取时才把
    # Disabled 作为确定性错误；查询失败不覆盖上面的 HypervisorPresent 事实。
    try {
        $feature = Get-WindowsOptionalFeature -Online `
            -FeatureName HypervisorPlatform -ErrorAction Stop
        if ($feature.State -ne 'Enabled') {
            [void]$problems.Add('Windows Hypervisor Platform 功能未启用。')
        }
    } catch {
        Write-Verbose "无法读取 HypervisorPlatform feature 状态：$($_.Exception.Message)"
    }

    try {
        $accelOutput = & $Qemu '-accel' 'help' 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0 -or $accelOutput -notmatch '(?m)^whpx\s*$') {
            [void]$problems.Add('当前 qemu-system-x86_64.exe 未构建 WHPX。')
        }
    } catch {
        [void]$problems.Add("WHPX 构建能力探测失败：$($_.Exception.Message)")
    }
    return $problems
}

function Assert-VMateQemuVersion {
    param([string]$Qemu)

    try {
        $versionOutput = & $Qemu '--version' 2>&1 | Out-String
    } catch {
        throw "QEMU 版本探测失败：$($_.Exception.Message)"
    }
    if ($LASTEXITCODE -ne 0 -or $versionOutput -notmatch
        'QEMU emulator version 11\.0\.2(?:\s|$)') {
        throw 'QEMU 必须是当前源码对应的 11.0.2 构建；TCG 授权不会绕过版本门禁。'
    }
}

function Assert-VMateQemuSmbiosCapabilities {
    param([string]$Qemu)

    # 中文注释：-smbios 没有独立 help 接口，且上游帮助文本不会列出本分支的
    # 深层字段。用临时 vmstate dump 让 QEMU 的真实 QemuOpts 解析器消费与启动器
    # 同构的 Type 4/17 canary；-dump-vmstate 在客体执行前退出，不创建 NVRAM。
    $type4 = 'type=4,sock_pfx=LGA1151,manufacturer=Intel(R) Corporation,' +
        'version=VMate Canary,serial=CPU-CANARY,part=CPU-PART,' +
        'max-speed=3600,current-speed=3600,processor-family=0x00CE,' +
        'voltage=140,external-clock=100,processor-upgrade=0x31,' +
        'processor-characteristics=0x00EC'
    $type17 = 'type=17,loc_pfx=DIMM_%C2,bank=P0 CHANNEL %C,' +
        'manufacturer=Samsung,serial=CANARY01|CANARY02,part=DDR4-CANARY,' +
        'speed=2400,configured-speed=2133,memory-type=0x1a,' +
        'type-detail=0x80,rank=1,voltage=1200,device-width=16,' +
        'spd-ee1004=on'
    $dumpPath = [System.IO.Path]::GetTempFileName()
    try {
        try {
            $output = & $Qemu '-nodefaults' '-machine' 'q35,accel=tcg' `
                '-display' 'none' '-smbios' $type4 '-smbios' $type17 `
                '-dump-vmstate' $dumpPath 2>&1 | Out-String
            $exitCode = $LASTEXITCODE
        } catch {
            throw "QEMU SMBIOS Type 4/17 能力探测失败：$($_.Exception.Message)"
        }
        if ($exitCode -ne 0) {
            throw "QEMU 无法解析完整 SMBIOS Type 4/17 参数（exit code=$exitCode）：$($output.Trim())"
        }
        if (-not (Test-Path -LiteralPath $dumpPath -PathType Leaf) -or
            (Get-Item -LiteralPath $dumpPath).Length -eq 0) {
            throw 'QEMU SMBIOS Type 4/17 探针未生成 vmstate 输出。'
        }
    } finally {
        if (Test-Path -LiteralPath $dumpPath) {
            Remove-Item -LiteralPath $dumpPath -Force
        }
    }
}

function Assert-VMateWritableDirectoryTarget {
    param(
        [string]$Path,
        [string]$Label
    )

    try {
        $target = [System.IO.Path]::GetFullPath($Path)
        $probeRoot = $target
        while (-not (Test-Path -LiteralPath $probeRoot)) {
            $parent = Split-Path -Parent $probeRoot
            if (-not $parent -or $parent -eq $probeRoot) {
                throw '找不到已存在的父目录。'
            }
            $probeRoot = $parent
        }
        if (-not (Test-Path -LiteralPath $probeRoot -PathType Container)) {
            throw "父路径不是目录：$probeRoot"
        }
        $probe = Join-Path $probeRoot `
            ('.vmate-write-' + [Guid]::NewGuid().ToString('N') + '.tmp')
        try {
            $stream = [System.IO.File]::Open(
                $probe, [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            $stream.Dispose()
        } finally {
            if (Test-Path -LiteralPath $probe) {
                Remove-Item -LiteralPath $probe -Force
            }
        }
    } catch {
        throw "$Label 不可写：$Path；$($_.Exception.Message)"
    }
}

function Assert-VMateReadableNonEmptyFile {
    param(
        [string]$Path,
        [string]$Label
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label 不是可读文件：$Path"
    }
    $stream = $null
    try {
        $stream = [System.IO.File]::Open(
            [System.IO.Path]::GetFullPath($Path), [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        $length = $stream.Length
    } catch {
        throw "$Label 不可读：$Path；$($_.Exception.Message)"
    } finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
    if ($length -eq 0) {
        throw "$Label 为空文件：$Path"
    }
}

function Assert-VMateOvmfStorageReady {
    param(
        [string]$Template,
        [string]$Vars
    )

    $templatePath = [System.IO.Path]::GetFullPath($Template)
    $varsPath = [System.IO.Path]::GetFullPath($Vars)
    if ($templatePath.Equals(
            $varsPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'OVMF vars 目标不能与只读模板使用同一个文件。'
    }
    Assert-VMateReadableNonEmptyFile -Path $templatePath `
        -Label 'OVMF vars 模板'
    $templateLength = (Get-Item -LiteralPath $templatePath).Length
    if (Test-Path -LiteralPath $varsPath) {
        if (-not (Test-Path -LiteralPath $varsPath -PathType Leaf)) {
            throw "已有 OVMF vars 不是文件：$Vars"
        }
        try {
            $varsStream = [System.IO.File]::Open(
                $varsPath, [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::Read)
            $varsLength = $varsStream.Length
            $varsStream.Dispose()
        } catch {
            throw "已有 OVMF vars 不可读写：$Vars；$($_.Exception.Message)"
        }
        if ($varsLength -ne $templateLength) {
            throw "已有 OVMF vars 与模板长度不同：$varsLength != $templateLength"
        }
        return
    }
    Assert-VMateWritableDirectoryTarget -Path (Split-Path -Parent $varsPath) `
        -Label 'OVMF vars 目标父目录'
}

function Get-VMateMonitorEdidCapabilityProperties {
    # 中文注释：此列表是 Windows 显示器目录投影与 QEMU 能力门禁之间的单一
    # 契约。普通 virtio-vga 严格预检和可选 virtio-vga-gl 探针必须复用它，
    # 防止新增 EDID 字段时只更新正式 argv 而遗漏其中一条显示路径。
    return @(
        'edid-fixed-native',
        'edid-managed-timing-version',
        'edid-vendor',
        'edid-name',
        'edid-serial',
        'edid-binary-serial',
        'edid-revision',
        'edid-width-mm',
        'edid-height-mm',
        'edid-product-id',
        'edid-manufacture-week',
        'edid-manufacture-year',
        'edid-video-input',
        'edid-min-vfreq-hz',
        'edid-max-vfreq-hz',
        'edid-min-hfreq-khz',
        'edid-max-hfreq-khz',
        'edid-max-pixel-clock-mhz',
        'edid-secondary-xres',
        'edid-secondary-yres',
        'edid-secondary-refresh-rate'
    )
}

function Test-VMateQemuHelpProperties {
    param(
        [string]$HelpOutput,
        [string[]]$Properties
    )

    foreach ($property in $Properties) {
        $propertyPattern = '(?m)^\s*{0}\s*=' -f [regex]::Escape($property)
        if ($HelpOutput -notmatch $propertyPattern) {
            return $false
        }
    }
    return $true
}

function Assert-VMateQemuDeviceCapabilities {
    param([string]$Qemu)

    $chipsetIdentityProperties = @(
        'x-pci-vendor-id',
        'x-pci-device-id',
        'x-pci-revision',
        'x-pci-sub-vendor-id',
        'x-pci-sub-device-id'
    )
    $monitorEdidProperties = @(Get-VMateMonitorEdidCapabilityProperties)
    $required = [ordered]@{
        # 中文注释：物理平台会通过 -global 覆盖 Q35 南桥三类功能的完整 PCI
        # 身份。三个 QOM type 必须逐一证明五项 patched 属性，不能只因机器能
        # 创建默认 ICH9 设备就判定当前二进制兼容。
        'ICH9-LPC' = $chipsetIdentityProperties
        'ICH9-SMB' = $chipsetIdentityProperties
        'ich9-ahci' = $chipsetIdentityProperties
        'pcie-root-port' = @('x-pci-vendor-id', 'x-pci-device-id',
            'x-pci-revision', 'x-speed', 'x-width')
        'intel-hda' = @('x-pci-vendor-id', 'x-pci-device-id')
        'hda-duplex' = @('x-identity-compat', 'x-codec-id',
            'x-codec-revision', 'x-codec-subsystem-id')
        'e1000e' = @('subsys_ven', 'subsys')
        'nvme' = @('x-identity-profile', 'model-number', 'firmware-rev',
            'subsys-vendor-id', 'subsys-id', 'subnqn')
        # 中文注释：Windows 启动参数默认启用 guest LED 驱动的 NumLock 策略；能力
        # 门禁必须先验证自定义 QEMU 属性，避免拼好命令后才以 unknown property 退出。
        'usb-kbd' = @('vendorid', 'productid', 'manufacturer', 'product',
            'x-force-numlock-on')
        'usb-mouse' = @('vendorid', 'productid', 'manufacturer', 'product')
        # 中文注释：Get-VMateMonitorEdidSuffix 会把目录中的完整显示器身份与
        # 时序投影到 virtio-vga。门禁必须与该函数字段集合保持一致，不能仅
        # 验证少量代表字段后让 unknown property 延迟到正式启动。
        'virtio-vga' = @($monitorEdidProperties + @(
                'xres', 'yres', 'xmax', 'ymax'))
    }
    foreach ($entry in $required.GetEnumerator()) {
        try {
            $helpOutput = & $Qemu '-device' "$($entry.Key),help" 2>&1 | Out-String
        } catch {
            throw "QEMU 设备能力探测失败：$($entry.Key)；$($_.Exception.Message)"
        }
        if ($LASTEXITCODE -ne 0) {
            throw "QEMU 不提供所需设备：$($entry.Key)"
        }
        foreach ($property in $entry.Value) {
            $propertyPattern = '(?m)^\s*{0}\s*=' -f [regex]::Escape($property)
            if ($helpOutput -notmatch $propertyPattern) {
                throw "QEMU 设备 $($entry.Key) 缺少 patched 属性：$property"
            }
        }
    }
}

function Get-VMateQemuCapabilityOutput {
    param(
        [string]$Qemu,
        [string[]]$Arguments,
        [string]$Capability,
        [int[]]$AllowedExitCodes = @(0)
    )

    try {
        $output = & $Qemu @Arguments 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
    } catch {
        throw "QEMU $Capability 能力探测失败：$($_.Exception.Message)"
    }
    if ($exitCode -notin $AllowedExitCodes) {
        throw "QEMU 不提供所需 $Capability 能力（探测 exit code=$exitCode）。"
    }
    return $output
}

function Assert-VMateQemuRuntimeCapabilities {
    param(
        [string]$Qemu,
        [bool]$RequireFbShm,
        [bool]$RequireSdl,
        [bool]$RequireVnc
    )

    # 中文注释：Windows 启动器当前固定使用 user netdev；这不是可选回退。
    # 在创建 profile/NVRAM 前证明 backend 存在，避免裁剪版 QEMU 到启动末段
    # 才因 “invalid backend type” 失败。
    $netdevOutput = Get-VMateQemuCapabilityOutput -Qemu $Qemu `
        -Arguments @('-netdev', 'help') -Capability 'user netdev'
    if ($netdevOutput -notmatch '(?m)^\s*user\s*$') {
        throw 'QEMU 缺少 Windows 启动器所需的 user netdev backend。'
    }

    if ($RequireFbShm) {
        $fbShmOutput = Get-VMateQemuCapabilityOutput -Qemu $Qemu `
            -Arguments @('-object', 'fb-shm,help') -Capability 'fb-shm object'
        foreach ($property in @('path', 'rate', 'x', 'y', 'width', 'height')) {
            $propertyPattern = '(?m)^\s*{0}\s*=' -f [regex]::Escape($property)
            if ($fbShmOutput -notmatch $propertyPattern) {
                throw "QEMU fb-shm object 缺少所需属性：$property"
            }
        }
    }

    if ($RequireSdl) {
        $displayOutput = Get-VMateQemuCapabilityOutput -Qemu $Qemu `
            -Arguments @('-display', 'help') -Capability 'SDL display'
        if ($displayOutput -notmatch '(?m)^\s*sdl\s*$') {
            throw 'QEMU 缺少 Windows 本地显示所需的 SDL display backend。'
        }
    }

    if ($RequireVnc) {
        # 中文注释：VNC 不是 -display backend，必须通过独立的 -vnc help
        # 探针验证。只查顶层 -help 文本容易把文档占位符误判成已编译能力。
        $vncOutput = Get-VMateQemuCapabilityOutput -Qemu $Qemu `
            -Arguments @('-vnc', 'help') -Capability 'headless VNC' `
            -AllowedExitCodes @(1)
        if ($vncOutput -notmatch '(?im)^\s*vnc options:\s*$') {
            throw 'QEMU 缺少 Windows headless 模式所需的 VNC server。'
        }
    }
}

function Assert-VMateWhpxReady {
    param(
        [string]$Qemu,
        [bool]$AllowTcgFallback,
        [bool]$DryRun,
        [bool]$RequireFbShm = $false,
        [bool]$RequireSdl = $false,
        [bool]$RequireVnc = $false
    )

    if ($DryRun) {
        return
    }
    Assert-VMateQemuVersion -Qemu $Qemu
    Assert-VMateQemuSmbiosCapabilities -Qemu $Qemu
    Assert-VMateQemuDeviceCapabilities -Qemu $Qemu
    Assert-VMateQemuRuntimeCapabilities -Qemu $Qemu `
        -RequireFbShm $RequireFbShm -RequireSdl $RequireSdl `
        -RequireVnc $RequireVnc
    $build = Get-VMateWindowsBuild
    if ($build -lt 19041) {
        throw "WHPX x86_64 要求 Windows 10 2004/build 19041 或更新版本，实际：$build"
    }
    $problems = @(Get-VMateWhpxProblems -Qemu $Qemu)
    if ($problems.Count -eq 0) {
        return
    }
    $detail = $problems -join ' '
    if (-not $AllowTcgFallback) {
        throw "WHPX 严格预检失败：$detail 如确实接受软件模拟，请显式使用 -AllowTcgFallback。"
    }
    Write-Host ">> WHPX 当前不可用；已由 -AllowTcgFallback 明确授权 TCG：$detail"
}

function Assert-VMateGuestPolicy {
    param(
        [string]$GuestOs,
        [bool]$RequireNestedVirtualization
    )

    if ($RequireNestedVirtualization) {
        # QEMU 11 WHPX 没有向客体提供可用的嵌套虚拟化能力。提前拒绝比启动后让
        # Hyper-V/WSL2 安装到一半失败更可诊断，也避免把 hyperv=off 与嵌套需求混用。
        throw 'QEMU 11 WHPX 路线不支持嵌套虚拟化；请改用 Linux/KVM nested。'
    }
    if ($GuestOs -eq 'Windows11') {
        # Windows 原生构建没有本项目 Linux/swtpm 路线，且无法证明所选 OVMF vars
        # 已进入 Secure Boot operational mode。两项任一缺失都不能宣称 Win11 就绪。
        throw 'Windows/WHPX 路线尚无可验证的 TPM 2.0 + Secure Boot，拒绝启动 Windows 11；请使用 Linux/KVM 路线。'
    }
}

function Get-VMateWhpxAccelerator {
    param([bool]$ExposeHyperv)

    if ($ExposeHyperv) {
        return 'whpx,hyperv=auto'
    }
    # 默认关闭 synthetic Hyper-V enlightenments 与内核 irqchip；这与仓库 WHPX
    # 文档给出的兼容策略一致，也避免 HypervisorPresent 作为默认客体 CPU 表面。
    return 'whpx,hyperv=off,kernel-irqchip=off'
}
