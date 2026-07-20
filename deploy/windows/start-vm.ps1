#Requires -Version 5.1
<#
.SYNOPSIS
    在 Windows 10/11 宿主上以严格 WHPX 策略启动 patched QEMU VM。

.DESCRIPTION
    Windows 路线默认只接受 WHPX，不再静默退到 TCG。硬件事实来自共享
    deploy/hardware/platforms.json 与 components.json，随机身份写入 VM 目录的 hardware-profile.json
    后跨重启保持稳定。WHPX 在 QEMU 11 中忽略自定义 -cpu 模型，因此启动器明确
    使用宿主 CPU 面，并只把主板/设备平台从 manifest 注入，避免虚构可控 CPUID。

    -AllowPlatformCompatibility 及旧别名仅保留参数兼容，当前会在任何路径解析
    或持久化之前 fail-closed。Windows 尚不能证明共享 manifest 要求的完整宿主
    CPUID/TSC 绑定，也没有可替代 KVM realize 的 WHPX canary；因此只开放与
    manifest CPU 名称精确匹配的物理 bundle。

    Windows 原生构建目前无法提供经过验证的 TPM 2.0 + Secure Boot 组合；选择
    Windows11 会在任何文件写入前失败，不能用“能启动”冒充满足正式前置条件。
#>

[CmdletBinding()]
param(
    [ValidateRange(1, 1000)]
    [int]$Instance = 1,
    [string]$Qemu = '',
    [string]$QemuImg = '',
    [string]$VmRoot = '',
    [string]$Disk = '',
    [string]$OvmfCode = '',
    [string]$OvmfVarsTemplate = '',
    [string]$OvmfVars = '',
    [ValidateRange(2048, 262144)]
    [int]$MemoryMiB = 8192,
    [ValidateRange(1, 256)]
    [int]$Cpus = 4,
    [ValidateSet('Windows10', 'Windows11', 'Linux')]
    [string]$GuestOs = 'Windows10',
    [string]$Iso = '',
    [string]$ExtraIso = '',

    [string]$HardwareManifest = '',
    [string]$HostCompatibilityManifest = '',
    [string]$ComponentManifest = '',
    [string]$HardwareProfile = '',
    [string]$PlatformId = '',
    [switch]$RerollHardwareProfile,
    [Alias('AllowHostCpuPlatformMismatch')]
    [switch]$AllowPlatformCompatibility,

    [switch]$AllowTcgFallback,
    [switch]$ExposeHyperv,
    [switch]$RequireNestedVirtualization,

    [switch]$NoSdl,
    [switch]$Headless,
    [switch]$NoFbShm,
    [string]$FbShmPath = '',
    [ValidateRange(1, 240)]
    [int]$FbShmRate = 60,
    [string]$FbShmRoi = '',
    [switch]$NoGpuZeroCopy,
    [string]$GpuHostmem = '256M',
    [ValidateSet('Auto', 'Available', 'Unavailable')]
    [string]$GpuGlProbe = 'Auto',

    [int]$SshForwardPort = 0,
    [int]$RdpForwardPort = 0,
    [switch]$DryRun,
    [ValidateSet('GenuineIntel', 'AuthenticAMD')]
    [string]$DryRunHostVendorId = 'GenuineIntel',
    [string]$DryRunHostCpuName = 'Intel(R) Test CPU',
    [ValidateRange(1, 256)]
    [int]$DryRunHostCores = 4,
    [ValidateRange(1, 512)]
    [int]$DryRunHostLogicalProcessors = 4,
    [ValidateRange(1, 100000)]
    [int]$DryRunHostMaxMhz = 3600,
    [string[]]$ExtraQemuArgs = @()
)

$ErrorActionPreference = 'Stop'

$libraryRoot = Join-Path $PSScriptRoot 'lib'
. (Join-Path $libraryRoot 'VMate.Common.ps1')
. (Join-Path $libraryRoot 'VMate.Preflight.ps1')
. (Join-Path $libraryRoot 'VMate.Components.ps1')
. (Join-Path $libraryRoot 'VMate.Profile.ps1')
. (Join-Path $libraryRoot 'VMate.Arguments.ps1')
. (Join-Path $libraryRoot 'VMate.ExtraArguments.ps1')

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
        # GL 设备必须完整接受与普通 virtio-vga 相同的 EDID/分辨率投影。
        # 默认零拷贝还会在正式 argv 中传 blob/hostmem，因此按启动策略同步
        # 探测；任一缺失都安全回退到已通过严格门禁的普通 virtio-vga。
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

Assert-VMateGuestPolicy -GuestOs $GuestOs `
    -RequireNestedVirtualization $RequireNestedVirtualization.IsPresent
Assert-VMateExtraArguments -Arguments $ExtraQemuArgs
if ($AllowPlatformCompatibility) {
    throw 'Windows/WHPX 尚未实现 host-compatibility manifest 要求的完整宿主绑定与 WHPX realize canary；-AllowPlatformCompatibility 当前禁用，仅允许精确物理平台。'
}
if ($GpuGlProbe -ne 'Auto' -and -not $DryRun) {
    throw 'GpuGlProbe 的注入值仅允许和 -DryRun 一起用于测试。'
}

$repo = Get-VMateRepoRoot
if (-not $VmRoot) {
    $VmRoot = Join-Path $env:USERPROFILE "qemu\vms\$Instance"
}
if (-not $Disk) {
    $Disk = Join-Path $VmRoot 'disk.qcow2'
}
if (-not $HardwareManifest) {
    $HardwareManifest = Join-Path $repo 'deploy\hardware\platforms.json'
}
if (-not $ComponentManifest) {
    $ComponentManifest = Join-Path $repo 'deploy\hardware\components.json'
}
if (-not $HostCompatibilityManifest) {
    $HostCompatibilityManifest =
        Join-Path $repo 'deploy\hardware\host-compatibility.json'
}
if (-not $HardwareProfile) {
    $HardwareProfile = Join-Path $VmRoot 'hardware-profile.json'
}
if (-not $OvmfVars) {
    $OvmfVars = Join-Path $VmRoot 'OVMF_VARS.fd'
}
$runRoot = ''
if (-not $NoFbShm -and -not $FbShmPath) {
    $runRoot = 'C:\qemu-run'
    $FbShmPath = Join-Path $runRoot "fb-$Instance.sock"
}
if (-not $SshForwardPort) {
    $SshForwardPort = 2200 + $Instance
}
if (-not $RdpForwardPort) {
    $RdpForwardPort = 33890 + $Instance
}
foreach ($port in @($SshForwardPort, $RdpForwardPort, (4440 + $Instance))) {
    if ($port -lt 1 -or $port -gt 65535) {
        throw "派生端口超出 [1,65535]：$port"
    }
}

if (-not $Qemu) {
    $Qemu = Find-VMateFirstExisting @(
        (Join-Path $repo 'qemu-system-x86_64.exe'),
        (Join-Path $repo 'build-win64\qemu-system-x86_64.exe'),
        (Join-Path $repo 'build\qemu-system-x86_64.exe'),
        (Join-Path $PSScriptRoot 'qemu-system-x86_64.exe'),
        'C:\Program Files\qemu\qemu-system-x86_64.exe'
    )
}
if (-not $Qemu) {
    throw '找不到 qemu-system-x86_64.exe，请用 -Qemu 指定 11.0.2 patched QEMU。'
}
$qemuDir = Split-Path -Parent $Qemu
if (-not $QemuImg) {
    $QemuImg = Join-Path $qemuDir 'qemu-img.exe'
}
if (-not $OvmfCode) {
    $stockOvmfCandidates = @(
        (Join-Path $qemuDir 'share\edk2-x86_64-code.fd'),
        (Join-Path $qemuDir 'share\qemu\edk2-x86_64-code.fd'),
        (Join-Path $qemuDir 'edk2-x86_64-code.fd')
    )
    if ($Iso) {
        # stealth OVMF 的 ISO9660 驱动不能可靠读取 Windows hybrid ISO。
        # 安装模式与 Linux 启动器保持一致，默认只选同一 QEMU 发行物的标准
        # edk2 code；高级用户仍可通过显式 -OvmfCode 承担覆盖责任。
        $OvmfCode = Find-VMateFirstExisting $stockOvmfCandidates
    } else {
        $OvmfCode = Find-VMateFirstExisting (@(
            (Join-Path $repo 'deploy\firmware\OVMF_CODE_4M_stealth.fd')
        ) + $stockOvmfCandidates)
    }
}
if (-not $OvmfCode) {
    throw '找不到 OVMF code fd，请用 -OvmfCode 指定。'
}
if (-not $OvmfVarsTemplate) {
    $OvmfVarsTemplate = Find-VMateFirstExisting @(
        (Join-Path $qemuDir 'share\edk2-i386-vars.fd'),
        (Join-Path $qemuDir 'share\qemu\edk2-i386-vars.fd'),
        (Join-Path $qemuDir 'edk2-i386-vars.fd')
    )
}
if (-not $OvmfVarsTemplate) {
    throw '找不到 OVMF vars 模板，请用 -OvmfVarsTemplate 指定。'
}
foreach ($inputFile in ([ordered]@{
    'OVMF code' = $OvmfCode
    'OVMF vars 模板' = $OvmfVarsTemplate
}).GetEnumerator()) {
    Assert-VMateReadableNonEmptyFile -Path $inputFile.Value `
        -Label $inputFile.Key
}
foreach ($optionalImage in ([ordered]@{
    '安装 ISO' = $Iso
    '附加 ISO' = $ExtraIso
}).GetEnumerator()) {
    if ($optionalImage.Value -and
        -not (Test-Path -LiteralPath $optionalImage.Value -PathType Leaf)) {
        throw "$($optionalImage.Key) 不是可读文件：$($optionalImage.Value)"
    }
}
if (-not (Test-Path -LiteralPath $Disk -PathType Leaf)) {
    throw "磁盘不存在：$Disk"
}
if (-not $DryRun) {
    # 所有持久化目标先做无残留写探针；失败时既不会提交 profile，也不会创建
    # VM 根目录或 NVRAM。显式放在 WHPX/manifest 工作之前也让权限错误更易诊断。
    Assert-VMateWritableDirectoryTarget -Path $VmRoot -Label 'VM 根目录'
    $profileDirectory =
        Split-Path -Parent ([System.IO.Path]::GetFullPath($HardwareProfile))
    Assert-VMateWritableDirectoryTarget -Path $profileDirectory `
        -Label 'hardware profile 目标父目录'
    Assert-VMateOvmfStorageReady -Template $OvmfVarsTemplate -Vars $OvmfVars
    if ($runRoot) {
        Assert-VMateWritableDirectoryTarget -Path $runRoot -Label '运行目录'
    }
}

Assert-VMateWhpxReady -Qemu $Qemu `
    -AllowTcgFallback $AllowTcgFallback.IsPresent -DryRun $DryRun.IsPresent `
    -RequireFbShm (-not $NoFbShm.IsPresent) `
    -RequireSdl (-not ($Headless.IsPresent -or $NoSdl.IsPresent)) `
    -RequireVnc $Headless.IsPresent
$hostCpu = Get-VMateHostCpuIdentity -DryRun $DryRun.IsPresent `
    -DryRunVendorId $DryRunHostVendorId -DryRunName $DryRunHostCpuName `
    -DryRunCores $DryRunHostCores `
    -DryRunLogicalProcessors $DryRunHostLogicalProcessors `
    -DryRunMaxMhz $DryRunHostMaxMhz
$manifest = Read-VMateHardwareManifest -Path $HardwareManifest
$compatibilityManifest = $null
if ($AllowPlatformCompatibility) {
    $compatibilityManifest = Read-VMateHostCompatibilityManifest `
        -Path $HostCompatibilityManifest
}
$components = Read-VMateComponentManifest -Path $ComponentManifest
$profileLock = $null
if (-not $DryRun) {
    # 锁必须在读取已有 profile 前取得，并保持到前台 QEMU 退出。这样并发 reroll
    # 不能让“内存身份 A 启动、磁盘身份 B 持久化”，同一实例也不会抢占磁盘/端口。
    $profileLock = Enter-VMateProfileCommitLock -Instance $Instance
}
try {
Assert-VMateStorageCapacity -QemuImg $QemuImg -Disk $Disk `
    -ExpectedBytes ([int64]$components.storage.raw_bytes) -DryRun $DryRun.IsPresent
$selection = Prepare-VMateHardwareProfile -Manifest $manifest `
    -CompatibilityManifest $compatibilityManifest -Components $components `
    -Path $HardwareProfile -PlatformId $PlatformId -HostCpu $hostCpu `
    -Instance $Instance -MemoryMiB $MemoryMiB -Cpus $Cpus `
    -AllowPlatformCompatibility $AllowPlatformCompatibility.IsPresent `
    -Reroll $RerollHardwareProfile.IsPresent
$profile = $selection.Profile
$platform = $selection.Platform

$qmpPort = 4440 + $Instance
$guestCores = $Cpus
$guestThreadsPerCore = 1
if ($profile.configuration.host_cpu_platform_mismatch_allowed) {
    $guestCores = [int]$profile.host_cpu.cores
    $hostThreads = [int]$profile.host_cpu.logical_processors
    if ($guestCores -lt 1 -or $hostThreads % $guestCores -ne 0) {
        throw '兼容 profile 的宿主核心/线程拓扑无法编码进 QEMU -smp。'
    }
    $guestThreadsPerCore = [int]($hostThreads / $guestCores)
}
$arguments = [System.Collections.Generic.List[string]]::new()
Add-VMateArgument $arguments @(
    '-name', "$($GuestOs.ToLowerInvariant())-$Instance,debug-threads=on",
    '-nodefaults',
    '-machine', 'q35,vmport=off,smm=on,hpet=off',
    '-accel', (Get-VMateWhpxAccelerator -ExposeHyperv $ExposeHyperv.IsPresent)
)
if ($AllowTcgFallback) {
    Add-VMateArgument $arguments @('-accel', 'tcg,thread=multi')
}
$guestCpuArgument = if ($AllowTcgFallback) {
    # TCG 仍必须保留已审计家用 SKU；通用 max 会破坏 Guest CPU 类别不变量。
    [string]$platform.cpu.qemu_arg
} else {
    'host'
}
Add-VMateArgument $arguments @(
    '-cpu', $guestCpuArgument,
    '-uuid', ([string]$profile.identity.uuid),
    '-m', $MemoryMiB.ToString(),
    '-smp', "cpus=$Cpus,cores=$guestCores,threads=$guestThreadsPerCore,sockets=1",
    '-rtc', (Get-VMateRtcArgument -GuestOs $GuestOs),
    '-drive', "if=pflash,format=raw,readonly=on,file=$OvmfCode",
    '-drive', "if=pflash,format=raw,file=$OvmfVars",
    '-qmp', "tcp:127.0.0.1:$qmpPort,server=on,wait=off"
)
Add-VMateArgument $arguments (New-VMateSmbiosArguments `
    -Platform $platform -Profile $profile)
Add-VMateArgument $arguments (New-VMateChipsetArguments -Platform $platform)
Add-VMateArgument $arguments (New-VMatePlatformDeviceArguments `
    -Platform $platform -Profile $profile -Components $components -Disk $Disk `
    -SshForwardPort $SshForwardPort -RdpForwardPort $RdpForwardPort)

if ($Iso) {
    Add-VMateArgument $arguments @(
        '-drive', "file=$Iso,media=cdrom,if=none,id=cd0,readonly=on",
        '-device', 'ide-cd,drive=cd0,bus=ide.0,bootindex=1'
    )
}
if ($ExtraIso) {
    Add-VMateArgument $arguments @(
        '-drive', "file=$ExtraIso,media=cdrom,if=none,id=cd1,readonly=on",
        '-device', 'ide-cd,drive=cd1,bus=ide.1'
    )
}

$localSdlRequested = -not ($Headless -or $NoSdl)
$gpuGlDisplay = $false
if ($localSdlRequested) {
    switch ($GpuGlProbe) {
        'Available' { $gpuGlDisplay = $true }
        'Unavailable' { $gpuGlDisplay = $false }
        default {
            $gpuGlDisplay = Test-VMateVirtioGpuGl -Executable $Qemu `
                -RequireBlob (-not $NoGpuZeroCopy.IsPresent)
        }
    }
}
if ($Headless) {
    Add-VMateArgument $arguments @('-display', 'none', '-vnc', "127.0.0.1:$($Instance - 1)")
} elseif ($NoSdl) {
    Add-VMateArgument $arguments @('-display', 'none')
} elseif ($gpuGlDisplay) {
    Add-VMateArgument $arguments @('-display', 'sdl,gl=on,show-cursor=off')
} else {
    $fallbackLabel = if ($NoFbShm) { 'SDL + virtio-vga' } else {
        'SDL + virtio-vga + SHM'
    }
    Write-Host ">> virtio-vga-gl 不可用；自动选择 $fallbackLabel。"
    Add-VMateArgument $arguments @('-display', 'sdl,show-cursor=off')
}

$monitorEdid = Get-VMateMonitorEdidSuffix -Components $components -Profile $profile
if ($gpuGlDisplay) {
    # 本项目显式固定 profile native mode；QEMU 属性默认关闭，其他调用方不受影响。
    $vgaDevice = 'virtio-vga-gl,edid=on,edid-fixed-native=on,' +
        'xres=1920,yres=1080,xmax=1920,ymax=1080' +
        $monitorEdid
    if (-not $NoGpuZeroCopy) {
        if ($GpuHostmem -notmatch '^\d+[KkMmGgTt]?$') {
            throw "GpuHostmem 不是合法 QEMU size：$GpuHostmem"
        }
        $vgaDevice += ",blob=true,hostmem=$GpuHostmem"
    }
} else {
    $vgaDevice = 'virtio-vga,edid=on,edid-fixed-native=on,' +
        'xres=1920,yres=1080,xmax=1920,ymax=1080' +
        $monitorEdid
}
Add-VMateArgument $arguments @('-device', $vgaDevice)

if (-not $NoFbShm) {
    $roiSuffix = Split-VMateRoi $FbShmRoi
    Add-VMateArgument $arguments @(
        '-object', "fb-shm,id=vmate-$Instance,path=$FbShmPath,rate=$FbShmRate$roiSuffix"
    )
}
Add-VMateArgument $arguments $ExtraQemuArgs

if (-not $DryRun) {
    # 到这里所有会消费 manifest/profile 的 SMBIOS、PCI、GPU 与 ROI 参数均已
    # 构造并校验成功；此后才允许原子提交身份或生成 reroll 备份。
    [void](Commit-VMateHardwareProfile -Selection $selection `
        -Path $HardwareProfile -Lock $profileLock)
    New-Item -ItemType Directory -Force -Path $VmRoot | Out-Null
    if (-not (Test-Path -LiteralPath $OvmfVars)) {
        Copy-Item -LiteralPath $OvmfVarsTemplate -Destination $OvmfVars `
            -ErrorAction Stop
    }
    if ($runRoot) {
        New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
    }
}

Write-Host "QEMU:     $Qemu"
Write-Host "VM:       $VmRoot"
Write-Host "Profile:  $HardwareProfile (platform=$($platform.id))"
Write-Host "Parts:    $($components.catalog_revision) / $($components.storage.id)"
$cpuMode = if ($AllowTcgFallback) {
    'TCG named household / strict physical bundle'
} elseif ($profile.configuration.host_cpu_platform_mismatch_allowed) {
    'WHPX host / generic Q35 compatibility'
} else {
    'WHPX host / strict physical bundle'
}
$visibleCpuName = if ($AllowTcgFallback) { $platform.cpu.name } else { $hostCpu.name }
Write-Host "CPU:      $cpuMode / $visibleCpuName"
if ($profile.configuration.host_cpu_platform_mismatch_allowed) {
    Write-Warning '已显式启用 QEMU Q35 宿主透传兼容模板；该配置不声明物理 CPU/主板组合。'
}
Write-Host "Accel:    $(Get-VMateWhpxAccelerator -ExposeHyperv $ExposeHyperv.IsPresent)"
if (-not $NoFbShm) {
    Write-Host "fb-shm:   $FbShmPath configured=${FbShmRate}Hz"
}

if ($DryRun) {
    $arguments | ForEach-Object { Write-Output $_ }
} else {
    & $Qemu @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "QEMU 异常退出，exit code=$LASTEXITCODE"
    }
}
} finally {
    if ($null -ne $profileLock -and $profileLock.Acquired -eq $true) {
        Exit-VMateProfileCommitLock -Lock $profileLock
    }
}
