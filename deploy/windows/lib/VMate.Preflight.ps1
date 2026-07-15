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
        [string]$DryRunName = 'Intel(R) Test CPU'
    )

    if ($DryRun) {
        return [pscustomobject]@{
            vendor_id = $DryRunVendorId
            name = $DryRunName
            cores = 8
            logical_processors = 16
            max_mhz = 3600
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

function Assert-VMateQemuDeviceCapabilities {
    param([string]$Qemu)

    $required = [ordered]@{
        'pcie-root-port' = @('x-pci-vendor-id', 'x-pci-device-id', 'x-pci-revision')
        'qemu-xhci' = @('x-pci-vendor-id', 'x-pci-device-id', 'x-pci-revision')
        'intel-hda' = @('x-pci-vendor-id', 'x-pci-device-id')
        'hda-duplex' = @('x-identity-compat', 'x-codec-id',
            'x-codec-revision', 'x-codec-subsystem-id')
        'e1000e' = @('subsys_ven', 'subsys')
        'nvme' = @('use-samsung-id', 'model-number', 'firmware-rev',
            'subsys-vendor-id', 'subsys-id', 'subnqn')
        # 中文注释：Windows 启动参数默认启用 guest LED 驱动的 NumLock 策略；能力
        # 门禁必须先验证自定义 QEMU 属性，避免拼好命令后才以 unknown property 退出。
        'usb-kbd' = @('vendorid', 'productid', 'manufacturer', 'product',
            'x-force-numlock-on')
        'usb-mouse' = @('vendorid', 'productid', 'manufacturer', 'product')
        'virtio-vga' = @('edid-fixed-native', 'edid-vendor', 'edid-product-id',
            'edid-secondary-refresh-rate')
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
            if ($helpOutput -notmatch [regex]::Escape($property)) {
                throw "QEMU 设备 $($entry.Key) 缺少 patched 属性：$property"
            }
        }
    }
}

function Assert-VMateWhpxReady {
    param(
        [string]$Qemu,
        [bool]$AllowTcgFallback,
        [bool]$DryRun
    )

    if ($DryRun) {
        return
    }
    Assert-VMateQemuVersion -Qemu $Qemu
    Assert-VMateQemuDeviceCapabilities -Qemu $Qemu
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
