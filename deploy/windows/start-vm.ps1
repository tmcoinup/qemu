#Requires -Version 5.1
<#
.SYNOPSIS
    Windows 10 / Windows 11 宿主启动 patched QEMU VM。

.DESCRIPTION
    这个启动器对应 Linux 侧 deploy/scripts/start-vm.sh 的 Windows 宿主版本。
    它不依赖 Python/Bash/MSYS 运行时，只要求当前目录能找到 qemu-system-x86_64.exe，
    并且 Windows 已启用 Windows Hypervisor Platform。

    默认模式是 SDL 窗口 + fb-shm 推流通道并存：
      - SDL 给本机交互使用；
      - fb-shm 完全在宿主 QEMU 进程内导出帧，对 guest 不可见；
      - 外部使用 qemu-fb-shm-stream.exe --sock <path> --output <url> 拉流。
#>

[CmdletBinding()]
param(
    [int]$Instance = 1,

    [string]$Qemu = "",
    [string]$QemuImg = "",

    [string]$VmRoot = "",
    [string]$Disk = "",

    [string]$OvmfCode = "",
    [string]$OvmfVarsTemplate = "",
    [string]$OvmfVars = "",

    [int]$MemoryMiB = 8192,
    [int]$Cpus = 4,

    [string]$Iso = "",
    [string]$ExtraIso = "",

    [switch]$NoSdl,
    [switch]$Headless,
    [switch]$NoFbShm,
    [string]$FbShmPath = "",
    [int]$FbShmRate = 60,
    [string]$FbShmRoi = "",

    [int]$SshForwardPort = 0,
    [int]$RdpForwardPort = 0,

    [switch]$DryRun,
    [string[]]$ExtraQemuArgs = @()
)

$ErrorActionPreference = 'Stop'

function Resolve-RepoRoot {
    # deploy/windows/start-vm.ps1 -> repo root
    return (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}

function Find-FirstExisting {
    param([string[]]$Paths)
    foreach ($p in $Paths) {
        if ($p -and (Test-Path -LiteralPath $p)) {
            return (Resolve-Path -LiteralPath $p).Path
        }
    }
    return ""
}

function Add-Arg {
    param([System.Collections.Generic.List[string]]$List, [string[]]$Items)
    foreach ($item in $Items) {
        [void]$List.Add($item)
    }
}

function Split-Roi {
    param([string]$Value)
    if (-not $Value) { return @() }
    if ($Value -notmatch '^\d+,\d+,\d+,\d+$') {
        throw "FbShmRoi 必须是 x,y,w,h 四个非负整数，实际：$Value"
    }
    $parts = $Value.Split(',')
    return @(",x=$($parts[0]),y=$($parts[1]),width=$($parts[2]),height=$($parts[3])")
}

function Test-WhpxEnabled {
    # 只做提示，不阻断：某些 Windows 版本 Get-WindowsOptionalFeature 不可用。
    try {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -ErrorAction Stop
        if ($feature.State -ne 'Enabled') {
            Write-Warning 'Windows Hypervisor Platform 未启用。管理员 PowerShell 执行：Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform'
        }
    } catch {
        Write-Verbose "跳过 WHPX feature 检查：$($_.Exception.Message)"
    }
}

$repo = Resolve-RepoRoot
$defaultVmRoot = Join-Path $env:USERPROFILE "qemu\vms\$Instance"
if (-not $VmRoot) { $VmRoot = $defaultVmRoot }
if (-not $Disk) { $Disk = Join-Path $VmRoot 'disk.qcow2' }
if (-not $SshForwardPort) { $SshForwardPort = 2200 + $Instance }
if (-not $RdpForwardPort) { $RdpForwardPort = 33890 + $Instance }

$binCandidates = @(
    (Join-Path $repo 'build-win64\qemu-system-x86_64.exe'),
    (Join-Path $repo 'build\qemu-system-x86_64.exe'),
    (Join-Path $PSScriptRoot 'qemu-system-x86_64.exe'),
    'C:\Program Files\qemu\qemu-system-x86_64.exe'
)
if (-not $Qemu) { $Qemu = Find-FirstExisting $binCandidates }
if (-not $Qemu) { throw '找不到 qemu-system-x86_64.exe，请用 -Qemu 指定 patched QEMU 路径。' }

$qemuDir = Split-Path -Parent $Qemu
if (-not $QemuImg) {
    $QemuImg = Find-FirstExisting @(
        (Join-Path $qemuDir 'qemu-img.exe'),
        (Join-Path $repo 'build-win64\qemu-img.exe'),
        'C:\Program Files\qemu\qemu-img.exe'
    )
}

if (-not $OvmfCode) {
    $OvmfCode = Find-FirstExisting @(
        (Join-Path $repo 'deploy\firmware\OVMF_CODE_4M_stealth.fd'),
        (Join-Path $qemuDir 'share\qemu\edk2-x86_64-code.fd'),
        (Join-Path $qemuDir 'edk2-x86_64-code.fd')
    )
}
if (-not $OvmfCode) { throw '找不到 OVMF code fd，请用 -OvmfCode 指定。' }

if (-not $OvmfVarsTemplate) {
    $OvmfVarsTemplate = Find-FirstExisting @(
        (Join-Path $qemuDir 'share\qemu\edk2-i386-vars.fd'),
        (Join-Path $qemuDir 'edk2-i386-vars.fd')
    )
}
if (-not $OvmfVarsTemplate) { throw '找不到 OVMF vars 模板，请用 -OvmfVarsTemplate 指定。' }

New-Item -ItemType Directory -Force -Path $VmRoot | Out-Null
if (-not $OvmfVars) { $OvmfVars = Join-Path $VmRoot 'OVMF_VARS.fd' }
if (-not (Test-Path -LiteralPath $OvmfVars)) {
    Copy-Item -LiteralPath $OvmfVarsTemplate -Destination $OvmfVars -Force
}
if (-not (Test-Path -LiteralPath $Disk)) {
    throw "磁盘不存在：$Disk。请先创建 qcow2，或用 -Disk 指向已有镜像。"
}

if (-not $FbShmPath) {
    # Windows AF_UNIX 路径长度限制较短，默认放到短目录，避免用户目录过长。
    $runRoot = 'C:\qemu-run'
    New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
    $FbShmPath = Join-Path $runRoot "fb-$Instance.sock"
}
if ($FbShmRate -lt 1 -or $FbShmRate -gt 240) {
    throw "FbShmRate 必须在 [1,240]，实际：$FbShmRate"
}

Test-WhpxEnabled

$QmpPort = 4440 + $Instance
$argsList = [System.Collections.Generic.List[string]]::new()
Add-Arg $argsList @(
    '-name', "win10-$Instance,debug-threads=on",
    '-machine', 'q35,vmport=off,smm=on,hpet=off',
    '-accel', 'whpx',
    '-accel', 'tcg',
    '-m', $MemoryMiB.ToString(),
    '-smp', "cpus=$Cpus,cores=$Cpus,threads=1,sockets=1",
    '-drive', "if=pflash,format=raw,readonly=on,file=$OvmfCode",
    '-drive', "if=pflash,format=raw,file=$OvmfVars",
    '-device', 'pcie-root-port,id=rp1,slot=1,bus=pcie.0,hotplug=off,x-speed=8,x-width=4',
    '-device', 'pcie-root-port,id=rp2,slot=2,bus=pcie.0,hotplug=off,x-speed=2_5,x-width=1',
    '-drive', "file=$Disk,if=none,id=nvm0,format=qcow2,cache=none,aio=threads,discard=unmap",
    '-device', 'nvme,id=nvmectl0,bus=rp1,drive=nvm0,use-samsung-id=on,serial=S5H9NS0N900001,model-number=Samsung SSD 970 PRO 512GB,firmware-rev=1B2QEXP7',
    '-device', 'qemu-xhci,id=xhci,bus=rp2',
    '-device', 'usb-kbd,bus=xhci.0,vendorid=0x046d,productid=0xc31c,manufacturer=Logitech,product=USB Keyboard',
    '-device', 'usb-tablet,bus=xhci.0,vendorid=0x046d,productid=0xc077,manufacturer=Logitech,product=USB Optical Mouse',
    '-nic', "user,model=e1000e,hostfwd=tcp:127.0.0.1:$SshForwardPort-:22,hostfwd=tcp:127.0.0.1:$RdpForwardPort-:3389",
    '-qmp', "tcp:127.0.0.1:$QmpPort,server=on,wait=off"
)

if ($Iso) {
    Add-Arg $argsList @('-drive', "file=$Iso,media=cdrom,if=none,id=cd0,readonly=on", '-device', 'ide-cd,drive=cd0,bus=ide.0,bootindex=1')
}
if ($ExtraIso) {
    Add-Arg $argsList @('-drive', "file=$ExtraIso,media=cdrom,if=none,id=cd1,readonly=on", '-device', 'ide-cd,drive=cd1,bus=ide.1')
}

if ($Headless) {
    Add-Arg $argsList @('-display', 'none', '-vnc', "127.0.0.1:$($Instance - 1)")
} elseif ($NoSdl) {
    Add-Arg $argsList @('-display', 'none')
} else {
    Add-Arg $argsList @('-display', 'sdl,show-cursor=off')
}
Add-Arg $argsList @('-device', 'virtio-vga,edid=on,xres=1920,yres=1080,xmax=1920,ymax=1080')

if (-not $NoFbShm) {
    $roiSuffix = (Split-Roi $FbShmRoi) -join ''
    Add-Arg $argsList @('-object', "fb-shm,id=stealth-$Instance,path=$FbShmPath,rate=$FbShmRate$roiSuffix")
}

foreach ($item in $ExtraQemuArgs) {
    [void]$argsList.Add($item)
}

Write-Host "QEMU: $Qemu"
Write-Host "VM:   $VmRoot"
if (-not $NoFbShm) {
    Write-Host "fb-shm: $FbShmPath @ ${FbShmRate}Hz"
    Write-Host "拉流:  qemu-fb-shm-stream.exe --sock `"$FbShmPath`" --output rtmp://..."
}

if ($DryRun) {
    $argsList | ForEach-Object { Write-Output $_ }
    exit 0
}

& $Qemu @argsList
