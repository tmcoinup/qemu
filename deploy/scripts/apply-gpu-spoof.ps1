param(
    [string]$Subkey = "",
    [switch]$ListOnly,
    [switch]$SkipTask,                          # 仅跳过交互式显示模式任务；名称刷新始终保留
    [switch]$AutoDetect,                        # 自动按 PCI subsys 查 GPU 池映射；clone 后用
    [string]$SpoofName    = 'NVIDIA GeForce GTX 1050',
    [string]$SpoofVendor  = 'NVIDIA',           # 'NVIDIA' / 'AMD'
    [int]   $SpoofRamMb   = 2048,               # 显存 MB（注册表 HardwareInformation.MemorySize）
    [string]$SpoofBios    = 'Version 86.07.48.00.38',
    [ValidateSet('GDDR5')][string]$SpoofMemoryType = 'GDDR5', [ValidateRange(32, 1024)][ValidateScript({ ($_ -band ($_ - 1)) -eq 0 })][int]$SpoofMemoryBusWidthBits = 128,
    [ValidateRange(100000, 5000000)][int]$SpoofBaseClockKHz = 1354000, [ValidateRange(100000, 5000000)][int]$SpoofBoostClockKHz = 1455000,
    [ValidateRange(100000, 10000000)][int]$SpoofMemoryClockKHz = 3504000, [ValidateSet(0)][int]$SpoofSliSupported = 0,
    # 正式 respawn 显式传入同一受保护 payload 目录，使 NVAPI + ADL 系统投影与
    # schema-2 identity 共用下方 durable try/finally。参数名保留旧调用兼容，
    # 同时接受更准确的 -GpuApiPayloadDir 别名。
    [Alias('GpuApiPayloadDir')]
    [string]$NvapiPayloadDir = ''
)

$ErrorActionPreference = 'Stop'
# zh-CN Win10 默认 console code page = 936 (GBK)，把 Write-Host 中文当 GBK 输出 → 终端乱码。
try { chcp 65001 | Out-Null } catch {}
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new() } catch {}
$OutputEncoding = [System.Text.UTF8Encoding]::new()
$powershellExe = Join-Path $PSHOME 'powershell.exe'

# 三个辅助脚本是可独立测试、可独立分发的源码文件。主脚本只从自己的同目录
# 读取它们，避免重新引入难以做 AST 检查的超长内嵌 here-string。除只读 ListOnly 外，
# 在修改任何设备状态前先确认 payload 完整，防止安装到一半才发现辅助脚本缺失。
$refreshHelperSource = Join-Path $PSScriptRoot 'refresh-gpu-name.ps1'; $displayModeHelperSource = Join-Path $PSScriptRoot 'force-displayfreq.ps1'
$identityHelperSource = Join-Path $PSScriptRoot 'persist-gpu-profile.ps1'; $transactionHelperSource = Join-Path $PSScriptRoot 'gpu-profile-transaction.ps1'
$registryCoreSource = Join-Path $PSScriptRoot 'gpu-profile-registry-core.ps1'
$missingHelper = @($refreshHelperSource, $displayModeHelperSource, $identityHelperSource,
    $transactionHelperSource, $registryCoreSource) |
    Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
if (-not $ListOnly -and $missingHelper) {
    throw ("缺少同目录辅助脚本: " + $missingHelper)
}

# 两个厂商读取层的文件存在性要在 Stage 前检查；摘要、PE 架构和系统目标 allowlist
# 仍由统一 coordinator 的双重只读 Preflight 验证。
$gpuApiPayloadRoot = ''; $gpuApiCoordinatorSource = ''
if (-not $ListOnly -and -not [string]::IsNullOrWhiteSpace($NvapiPayloadDir)) {
    $gpuApiPayloadRoot = [IO.Path]::GetFullPath($NvapiPayloadDir)
    $gpuApiCoordinatorSource = Join-Path $gpuApiPayloadRoot 'install-gpu-api-system.ps1'
    $missingGpuApiPayload = @(
        'install-gpu-api-system.ps1', 'install-nvapi-system.ps1',
        'nvapi-system-transaction.ps1', 'install-adl-system.ps1',
        'adl-system-transaction.ps1', 'nvapi.dll', 'nvapi64.dll',
        'atiadlxy.dll', 'atiadlxx32.dll', 'atiadlxx.dll'
    ) | ForEach-Object { Join-Path $gpuApiPayloadRoot $_ } |
        Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) } |
        Select-Object -First 1
    if ($missingGpuApiPayload) {
        throw ('正式 GPU API payload 不完整：' + $missingGpuApiPayload)
    }
}

function Copy-HelperIfDifferent {
    # legacy 安装可能直接从 ProgramData 中运行主脚本，此时源和持久化目标是同一文件。
    # Windows 路径不区分大小写；先比较规范化绝对路径，相同就复用，避免 Copy-Item
    # 报“无法覆盖自身”。路径不同才原样复制，从而继续保留 helper 的 UTF-8 BOM。
    param([string]$Source, [string]$Destination)
    $sourceFullPath = [System.IO.Path]::GetFullPath($Source)
    $destinationFullPath = [System.IO.Path]::GetFullPath($Destination)
    if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals($sourceFullPath, $destinationFullPath)) {
        Copy-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop
    }
}

function Remove-ScheduledTaskIfPresent {
    # 旧实现直接调用 schtasks.exe /Delete。任务首次安装时本来就不存在，schtasks
    # 会把“找不到文件”写到 stderr；在本脚本的严格错误模式下，这条可忽略信息会被
    # PowerShell 提升为终止错误，进而错误回滚已经通过验证的 GPU identity 事务。
    # 改用 Windows 内置 ScheduledTasks API：完整枚举成功后只匹配根目录同名项，
    # 存在时才删除并复读。查询、删除或复读的真故障继续 fail-closed，不能把任务
    # 服务/CIM 故障误判成“任务不存在”，也不能在旧任务仍可见时继续身份提交。
    param([Parameter(Mandatory = $true)][string]$TaskName)

    $matches = @(Get-ScheduledTask -ErrorAction Stop | Where-Object {
            [string]$_.TaskPath -ieq '\' -and [string]$_.TaskName -ieq $TaskName
        })
    if ($matches.Count -gt 1) { throw ('根目录存在多个同名计划任务：' + $TaskName) }
    if ($matches.Count -eq 0) { return }
    Unregister-ScheduledTask -TaskName $TaskName -TaskPath '\' `
        -Confirm:$false -ErrorAction Stop
    $remaining = @(Get-ScheduledTask -ErrorAction Stop | Where-Object {
            [string]$_.TaskPath -ieq '\' -and [string]$_.TaskName -ieq $TaskName
        })
    if ($remaining.Count -ne 0) {
        throw ('计划任务删除后仍可见：' + $TaskName)
    }
}

function Get-StealthDisplayDevices {
    # 统一枚举 Display 类设备；不使用 -Status OK，因为 Code 22/已禁用设备恰好不会出现在 OK 集合里。
    try {
        return @(Get-PnpDevice -Class 'Display' -ErrorAction SilentlyContinue |
            Where-Object { $_.InstanceId -and $_.Status -ne 'Unknown' })
    } catch {
        Write-Host ("  (Get-PnpDevice unavailable: " + $_.Exception.Message + ")") -ForegroundColor DarkYellow
        return @()
    }
}

function Test-StealthDisplayNeedsEnable {
    param($Device)

    if (-not $Device) { return $false }

    $status = [string]$Device.Status
    $problem = ''
    try { $problem = [string]$Device.Problem } catch {}

    if ($status -eq 'OK') { return $false }
    # 设备管理器 Code 22 = 设备被禁用；不同 Windows/PowerShell 版本可能显示为 22 或 CM_PROB_DISABLED。
    if ($problem -eq '22' -or $problem -match 'CM_PROB_DISABLED|DISABLED') { return $true }
    # 某些 Win10 镜像只暴露 Status=Error，不暴露 Problem 数字；对 Display 类设备尝试 Enable 是幂等兜底。
    if ($status -eq 'Error' -or $status -eq 'Degraded') { return $true }

    return $false
}

function Enable-StealthDisplayDevices {
    param([string]$Reason = '恢复显示适配器启用状态')

    $changed = $false
    foreach ($dev in @(Get-StealthDisplayDevices)) {
        if (-not (Test-StealthDisplayNeedsEnable -Device $dev)) { continue }

        $label = [string]$dev.FriendlyName
        if ([string]::IsNullOrWhiteSpace($label)) { $label = [string]$dev.InstanceId }

        $problem = ''
        try { $problem = [string]$dev.Problem } catch {}
        Write-Host ("  enabling display adapter (" + $Reason + "): " + $label + " [" + $dev.Status + "/" + $problem + "]") -ForegroundColor Yellow

        try {
            Enable-PnpDevice -InstanceId $dev.InstanceId -Confirm:$false -ErrorAction Stop
            Start-Sleep -Milliseconds 800
            $changed = $true
        } catch {
            Write-Host ("  (enable failed for " + $dev.InstanceId + ": " + $_.Exception.Message + ")") -ForegroundColor DarkYellow
        }
    }

    return $changed
}

$identityTransactionId = $null; $identityTransactionCompleted = $false
$gpuApiTransactionPrepared = $false; $identityCompletionUnresolved = $false
try {
    if (-not $ListOnly) {
        # Recover helper 内含 fail-closed 旧任务屏障；屏障失败会在 Stage 前终止。
        $recovery = & $identityHelperSource -RecoverPending
        if ($null -ne $recovery) {
            Write-Host ('Recovered unfinished GPU identity transaction: ' +
                $recovery.Action + '/' + $recovery.IdentityId) -ForegroundColor Yellow
        }
        if (-not [string]::IsNullOrWhiteSpace($gpuApiCoordinatorSource)) {
            # identity journal 先裁决 CurrentIdentity，再让两套 reader receipt 按
            # 同一 pointer Finalize/Rollback。
            $recoverGpuApiArgs = @('-NoProfile', '-NonInteractive',
                '-ExecutionPolicy', 'Bypass', '-File', $gpuApiCoordinatorSource,
                '-Action', 'Recover')
            & $powershellExe @recoverGpuApiArgs
            if ($LASTEXITCODE -ne 0) {
                throw ('系统 GPU API 中断事务恢复失败，退出码=' + $LASTEXITCODE)
            }
        }
    }

# -AutoDetect：从 PnP Display 设备的 SUBSYS 串查整个 GPU bundle。显存类型/
# 位宽与三组时钟必须和名称、PCI ID 同时切换，不允许沿用上一台 clone 的值。
# 用于 clone-from-base 之后 profile reroll，PCI subsys 变了但 base 注册表覆盖还是老 GPU。
if ($AutoDetect) {
    $gpuMap = @{
        '138010DE' = @{ Name='NVIDIA GeForce GTX 750 Ti';  Vendor='NVIDIA'; Bios='Version 82.07.41.00.32';  RamMb=2048; MemoryType='GDDR5'; BusWidthBits=128; BaseClockKHz=1020000; BoostClockKHz=1085000; MemoryClockKHz=2700000; SliSupported=0 }
        '1D0110DE' = @{ Name='NVIDIA GeForce GT 1030';     Vendor='NVIDIA'; Bios='Version 86.08.46.00.81';  RamMb=2048; MemoryType='GDDR5'; BusWidthBits=64;  BaseClockKHz=1227000; BoostClockKHz=1468000; MemoryClockKHz=3004000; SliSupported=0 }
        '1C8110DE' = @{ Name='NVIDIA GeForce GTX 1050';    Vendor='NVIDIA'; Bios='Version 86.07.48.00.38';  RamMb=2048; MemoryType='GDDR5'; BusWidthBits=128; BaseClockKHz=1354000; BoostClockKHz=1455000; MemoryClockKHz=3504000; SliSupported=0 }
        '1C8210DE' = @{ Name='NVIDIA GeForce GTX 1050 Ti'; Vendor='NVIDIA'; Bios='Version 86.07.48.00.A0';  RamMb=4096; MemoryType='GDDR5'; BusWidthBits=128; BaseClockKHz=1290000; BoostClockKHz=1392000; MemoryClockKHz=3504000; SliSupported=0 }
        '699F1002' = @{ Name='AMD Radeon RX 550';          Vendor='AMD';    Bios='016.011.000.029.000000'; RamMb=2048; MemoryType='GDDR5'; BusWidthBits=128; BaseClockKHz=1100000; BoostClockKHz=1183000; MemoryClockKHz=3500000; SliSupported=0 }
        '67FF1002' = @{ Name='AMD Radeon RX 560';          Vendor='AMD';    Bios='016.011.000.029.000000'; RamMb=4096; MemoryType='GDDR5'; BusWidthBits=128; BaseClockKHz=1175000; BoostClockKHz=1275000; MemoryClockKHz=3500000; SliSupported=0 }
    }
    # RDP 登录后 Windows 会同时枚举 ROOT\RDPINDIRECTDISPLAY 一类远程显示节点。
    # 不能再取 Display 列表第一项；只允许唯一在线的 stock virtio PCI 设备参与
    # SUBSYS 映射，既避免 RDP 节点干扰，也继续对多显卡/异常物理身份 fail closed。
    $gpuDevices = @(Get-PnpDevice -Class Display -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Status -ne 'Unknown' -and [string]$_.InstanceId -match '^PCI\\VEN_1AF4&DEV_1050&SUBSYS_[0-9A-Fa-f]{8}(?:&|\\)'
        })
    if ($gpuDevices.Count -ne 1) {
        throw ('AutoDetect: 唯一在线 stock 1AF4:1050 Display 设备数=' + $gpuDevices.Count + '，拒绝继续')
    }
    if ($gpuDevices[0].InstanceId -match 'SUBSYS_([0-9A-Fa-f]{8})') {
        $subsys = $matches[1].ToUpper()
        if ($gpuMap.ContainsKey($subsys)) {
            $cfg = $gpuMap[$subsys]
            $SpoofName = $cfg.Name; $SpoofVendor = $cfg.Vendor; $SpoofBios = $cfg.Bios; $SpoofRamMb = $cfg.RamMb
            $SpoofMemoryType = $cfg.MemoryType; $SpoofMemoryBusWidthBits = $cfg.BusWidthBits; $SpoofBaseClockKHz = $cfg.BaseClockKHz
            $SpoofBoostClockKHz = $cfg.BoostClockKHz; $SpoofMemoryClockKHz = $cfg.MemoryClockKHz; $SpoofSliSupported = $cfg.SliSupported
            Write-Host "AutoDetect: subsys=$subsys -> $($cfg.Name)" -ForegroundColor Cyan
        } else {
            # 未知 SUBSYS 不能回落到默认 1050，否则名称、逻辑 PCI ID 与显存会拼成
            # 一个不存在的型号。明确失败，让外层 respawn 保留日志并停止安装 shim。
            throw "AutoDetect: subsys=$subsys 未在已知 GPU 池中，拒绝伪造默认型号"
        }
    } else {
        throw "AutoDetect: stock Display InstanceId 缺少 SUBSYS，拒绝继续"
    }
}

if (-not $ListOnly) {
    # clone 的 Class\NNNN 可能仍写着 base 上一代 profile 名。必须在 helper 提交
    # 新 SpoofName 之前先捕获旧值，后面才能把旧名加入 target needle；否则旧 GTX
    # 切到新 GTX/AMD 时会找不到 Class 目标，而配置已经先变成新型号。
    # refresh helper 的只读模式使用与 NVAPI 相同的 pointer/schema 双重校验；旧版
    # root.SpoofName 只是兼容镜像，不能再参与 target 选择，否则并发更新时会混入旧名。
    $previousIdentity = & $refreshHelperSource -ReadIdentityOnly -AllowMissing
    $previousSpoofName = if ($null -ne $previousIdentity) { $previousIdentity.SpoofName } else { $null }

    # 这是所有 PnP/显卡/监视器写入前的物理门禁。helper 会确认唯一在线设备确实由
    # stock VioGpuDod 驱动且主 ID 为 1AF4:1050，再以 schema-last 方式提交逻辑
    # 10DE:1C82 等身份。深层 10DE/1002 旧机在此即失败，不会留下半套 Class/Enum 修改。
    Write-Host "Preflighting and staging shallow user-mode PCI identity..." `
        -ForegroundColor Cyan
    $stageReceipt = & $identityHelperSource -Stage -SpoofName $SpoofName -SpoofVendor $SpoofVendor `
        -SpoofBios $SpoofBios -SpoofRamMb $SpoofRamMb -SpoofMemoryType $SpoofMemoryType -SpoofMemoryBusWidthBits $SpoofMemoryBusWidthBits -SpoofBaseClockKHz $SpoofBaseClockKHz -SpoofBoostClockKHz $SpoofBoostClockKHz -SpoofMemoryClockKHz $SpoofMemoryClockKHz -SpoofSliSupported $SpoofSliSupported
    if ($null -eq $stageReceipt -or [string]::IsNullOrWhiteSpace($stageReceipt.NewIdentityId)) {
        throw '身份写者没有返回 durable Stage receipt'
    }
    $identityTransactionId = [string]$stageReceipt.NewIdentityId
    $stagedIdentity = & $refreshHelperSource -ReadIdentityOnly -StagedIdentityId $identityTransactionId

    # 物理门禁通过后才允许修复 Code 22。禁用设备仍可被 PresentOnly/Enum 注册表识别，
    # 因而不需要为了 AutoDetect 提前改变设备状态。
    Enable-StealthDisplayDevices -Reason '浅层物理门禁通过后清理 Code 22' | Out-Null
}

# apply-gpu-spoof.ps1 - run INSIDE the Win10 guest, as Administrator.
#
# One-shot installer for the NVIDIA GTX 1050 spoof:
#
#   1) Class\{4d36e968-...}\NNNN        -> WMI VideoProcessor / AdapterRAM /
#                                           DriverDesc / HardwareInformation.*
#
#   2) Enum\PCI\VEN_...&DEV_...\<inst>  -> FriendlyName + DeviceDesc
#      (this is what Device Manager and Win32_VideoController.Name read)
#
#   3) C:\ProgramData\StealthGPU\refresh-gpu-name.ps1
#      + scheduled task "StealthGPU-RefreshName" (AtStartup + AtLogOn, SYSTEM,
#      highest privs). Windows' built-in BasicDisplay driver overwrites
#      DeviceDesc from display.inf on every init, so we re-apply the spoof
#      strings a couple of seconds after every boot. Pass -SkipTask to omit.
#
# OPTIONAL legacy diagnostic:
#   Device Manager's "驱动程序提供商 / 驱动程序说明" (Driver Provider / Desc)
#   on the Driver tab read the DEVPKEY storage under
#     Enum\PCI\<hwid>\<inst>\Properties\{a8b865dd-...}\0009|0004\00000000
#   which is locked to TrustedInstaller AND must use DEVPROP type 0xFFFF0012,
#   not REG_SZ. The shallow one-click path does not require this cosmetic field:
#   GPU-Z/WMI/SetupAPI identity and the VioGpuDod binding are verified separately.
#   Only when diagnosing that legacy Driver-tab field may an operator shut down
#   the VM and optionally run this host-side offline helper:
#     sudo deploy/scripts/host-fix-gpu-devpkey.sh <INSTANCE>
#   This helper is outside the required guest deployment and does not add 3D.
#
# Usage (PowerShell as Admin):
#   powershell -ExecutionPolicy Bypass -File .\apply-gpu-spoof.ps1
#   powershell -ExecutionPolicy Bypass -File .\apply-gpu-spoof.ps1 -Subkey 0001
#   powershell -ExecutionPolicy Bypass -File .\apply-gpu-spoof.ps1 -ListOnly
#   powershell -ExecutionPolicy Bypass -File .\apply-gpu-spoof.ps1 -SkipTask

# 参数化（来自 -SpoofName/-SpoofVendor，默认仍是 GTX 1050 兼容老调用方式）
$spoofName    = $SpoofName
$spoofVendor  = $SpoofVendor                             # Win32_VideoController.AdapterCompatibility / DxDiag 制造商
$spoofBios    = $SpoofBios                               # HardwareInformation.BiosString (随机 NVIDIA/AMD)
$spoofRamMb   = $SpoofRamMb                              # HardwareInformation.MemorySize (字节 = $spoofRamMb * 1MB)
$classGuid    = '{4d36e968-e325-11ce-bfc1-08002be10318}'   # Display adapters
$classRoot    = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\' + $classGuid

# Chinese localized needles built from char codes - keeps the source ASCII
# so Windows PowerShell 5.1 parses it correctly regardless of codepage.
$zhBasicDisplay = [string]::new([char[]](0x57fa,0x672c,0x663e,0x793a))
$zhStandardVGA1 = [string]::new([char[]](0x6807,0x51c6,0x0020,0x0056,0x0047,0x0041))
$zhStandardVGA2 = [string]::new([char[]](0x6807,0x51c6,0x0056,0x0047,0x0041))

$fakeNeedles = @(
    'virtio', 'Red Hat', 'Microsoft Basic', 'Standard VGA', 'QXL', 'Cirrus',
    $zhBasicDisplay, $zhStandardVGA1, $zhStandardVGA2
) -join '|'

# Clone 场景：base 被 sysprep 前已经跑过一次 apply-gpu-spoof，所以 Class\NNNN\DriverDesc
# 不再是 "Red Hat VirtIO GPU DOD" 而是上一代 spoof 写进去的型号名（比如 base 里抽到了
# AMD Radeon RX 560）。把"上次 spoof 名字"读出来加进 needle 池，让 clone 后的 AutoDetect
# 能识别"上一代 spoof 留下的 Class 项 = 我应该重写的目标"。
$prevSpoof = $previousSpoofName
if ($prevSpoof -and $prevSpoof.Trim()) {
    $fakeNeedles = $fakeNeedles + '|' + [regex]::Escape($prevSpoof)
}

# ---- list ------------------------------------------------------------------
Write-Host ("Adapters under " + $classRoot + " :") -ForegroundColor Cyan
Get-ChildItem $classRoot -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -match '^\d{4}$' } | ForEach-Object {
        $d = (Get-ItemProperty -Path $_.PSPath -Name DriverDesc -ErrorAction SilentlyContinue).DriverDesc
        Write-Host ("  {0}  -  {1}" -f $_.PSChildName, $d)
    }
Write-Host ""

if ($ListOnly) {
    Write-Host "ListOnly mode - exiting without changes." -ForegroundColor Yellow
    exit 0
}

# ---- pick class subkey(s) --------------------------------------------------
if ($Subkey) {
    $p = Join-Path $classRoot $Subkey
    if (-not (Test-Path $p)) {
        Write-Host ("ERROR: subkey '" + $Subkey + "' does not exist") -ForegroundColor Red
        exit 1
    }
    $dd = (Get-ItemProperty -Path $p -Name DriverDesc -ErrorAction SilentlyContinue).DriverDesc
    $targets = @([pscustomobject]@{ Path=$p; Desc=$dd; Sub=$Subkey })
} else {
    $targets = Get-ChildItem $classRoot -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^\d{4}$' } | ForEach-Object {
            $p  = $_.PSPath
            $dd = (Get-ItemProperty -Path $p -Name DriverDesc -ErrorAction SilentlyContinue).DriverDesc
            if ($dd -and ($dd -match $fakeNeedles -or $dd -eq $spoofName)) {
                [pscustomobject]@{ Path=$p; Desc=$dd; Sub=$_.PSChildName }
            }
        }
}

if (-not $targets) {
    Write-Host "No fake adapter auto-detected. Use one of the subkeys above:" -ForegroundColor Yellow
    Write-Host "    powershell -ExecutionPolicy Bypass -File .\apply-gpu-spoof.ps1 -Subkey 0001" -ForegroundColor Yellow
    exit 1
}

# ---- strict active Enum/Class projection, then pointer commit -------------
$activeEnumPath = 'HKLM:\SYSTEM\CurrentControlSet\Enum\' + $stagedIdentity.SourceInstanceId
$activeDriver = [string](Get-ItemPropertyValue -Path $activeEnumPath -Name Driver -ErrorAction Stop)
$activeDriverMatch = [regex]::Match($activeDriver,
    '^\{4d36e968-e325-11ce-bfc1-08002be10318\}\\([0-9]{4})$',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
if (-not $activeDriverMatch.Success) { throw ('active Display Driver 绑定非法：' + $activeDriver) }
$activeSubkey = $activeDriverMatch.Groups[1].Value
$targets = @($targets | Where-Object { $_.Sub -ceq $activeSubkey })
if ($targets.Count -ne 1) {
    throw ('选中的 Class target 不是 SourceInstanceId 唯一绑定子键：' + $activeSubkey)
}

# reader 必须先于 CurrentIdentity pointer 发布。coordinator 会在任何 Move 前对
# NVAPI + ADL 五个目标完成全量只读预检，再分别落 durable receipt；此后无论
# Commit/Complete 在哪里失败，outer finally 都能先恢复旧 pointer、再恢复 readers。
if (-not [string]::IsNullOrWhiteSpace($gpuApiCoordinatorSource)) {
    Write-Host 'Preparing durable NVIDIA + AMD hardware API projections...' `
        -ForegroundColor Cyan
    $gpuApiInstallArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy',
        'Bypass', '-File', $gpuApiCoordinatorSource, '-Action', 'Install',
        '-PayloadDir', $gpuApiPayloadRoot, '-TransactionId', $identityTransactionId,
        '-DeferFinalize')
    & $powershellExe @gpuApiInstallArgs
    if ($LASTEXITCODE -ne 0) {
        throw ('系统 GPU API 身份投影准备失败，退出码=' + $LASTEXITCODE)
    }
    $gpuApiTransactionPrepared = $true
    Write-Host '  -> NVIDIA/AMD readers prepared before pointer commit' `
        -ForegroundColor Green
}
Write-Host ("Committing strictly verified active Class " + $activeSubkey + "...") `
    -ForegroundColor Cyan
& $identityHelperSource -CommitIdentity $identityTransactionId
$committedIdentity = & $refreshHelperSource -ReadIdentityOnly
if ($committedIdentity.IdentityId -cne $identityTransactionId) {
    throw 'CurrentIdentity 提交后严格回读不是本事务 ID'
}
Write-Host ("  -> active Enum/Class committed as " + $spoofName) -ForegroundColor Green

# Monitor 节点统一由最终 strict refresh 处理；避免在 durable transaction 之外
# 维护第二套广扫写入。Monitor profile 固定，不参与 GPU identity commit。

# 显示模式脚本无论是否带 -SkipTask 都会在当前会话同步执行；以下状态只决定当当前
# 进程位于 Session 0 等无交互会话时，是否确实存在一个可在下次登录重试的延后任务。
$displayTaskInstalled = $displayModeDeferred = $displayModeFailed = $false
$displayModeSummary = '尚未执行显示模式验收'

# ---- install boot-time refresh task ----------------------------------------
# 名称刷新是 Red Hat/VirtIO 泄漏的系统级长期兜底，FirstLogon 也必须安装。
# -SkipTask 只控制需要交互桌面的显示模式任务，不能再关闭本 SYSTEM 任务。
Write-Host ""; Write-Host "Installing boot-time refresh task (defeats BasicDisplay clobber)..." -ForegroundColor Cyan

$taskName = 'StealthGPU-RefreshName'; $scriptDir = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $scriptDir 'refresh-gpu-name.ps1'
New-Item -Path $scriptDir -ItemType Directory -Force | Out-Null

# 原样复制带 UTF-8 BOM 的独立源码，确保 Windows PowerShell 5.1 不按本地代码页误读。
Copy-HelperIfDifferent -Source $refreshHelperSource -Destination $scriptPath

Remove-ScheduledTaskIfPresent -TaskName $taskName

$action = New-ScheduledTaskAction -Execute $powershellExe `
    -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $scriptPath + '"')
$trigBoot  = New-ScheduledTaskTrigger -AtStartup
$trigLogon = New-ScheduledTaskTrigger -AtLogOn
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -StartWhenAvailable
$task = New-ScheduledTask -Action $action -Trigger @($trigBoot, $trigLogon) `
    -Principal $principal -Settings $settings
Register-ScheduledTask -TaskName $taskName -InputObject $task -Force | Out-Null

Write-Host ("  -> installed " + $scriptPath) -ForegroundColor Green
Write-Host ("  -> task '" + $taskName + "' registered (AtStartup + AtLogOn, SYSTEM)") -ForegroundColor Green

# ---- prepare verified 1920x1080@60Hz mode switch ---------------------------
# viogpudo 若未正确填充显示模式，Windows“高级显示设置”可能显示有源信号 -1×-1、
# 刷新率 1.000Hz。ChangeDisplaySettings 只能操作当前交互桌面，Session 0 中的 SYSTEM
# 进程无法代替用户切换；因此辅助脚本用明确退出码区分“已验证”“需重启”“无交互桌面”
# 和真正失败，主脚本再依据是否安装了登录任务决定能否安全延后，绝不把未验证写成成功。
$freqTask = 'StealthGPU-ForceDisplayFreq'
if ($SkipTask) {
    # FirstLogon 会传 -SkipTask；只创建本次运行所需的临时脚本，执行后立即删除，
    # 不留下计划任务或永久辅助文件，保持“一次性执行”的原有约定。
    $freqScript = Join-Path ([System.IO.Path]::GetTempPath()) `
        ('stealth-display-mode-' + $PID + '.ps1')
    $freqLog = ''
} else {
    $freqScript = Join-Path $scriptDir 'force-displayfreq.ps1'
    $freqLog = Join-Path $scriptDir 'force-displayfreq.log'
}

# 原样复制独立显示模式 helper；临时模式与持久任务模式共用同一份受测源码。
Copy-HelperIfDifferent -Source $displayModeHelperSource -Destination $freqScript

if (-not $SkipTask) {
    Write-Host ""; Write-Host "Installing user-session task to enforce and verify 1920x1080@60Hz..." -ForegroundColor Cyan
    Remove-ScheduledTaskIfPresent -TaskName $freqTask
    $freqAction = New-ScheduledTaskAction -Execute $powershellExe `
        -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' +
            $freqScript + '" -LogPath "' + $freqLog + '"')
    $freqTrig = New-ScheduledTaskTrigger -AtLogOn -User 'Administrator'
    $freqPrincipal = New-ScheduledTaskPrincipal -UserId 'Administrator' `
        -LogonType Interactive -RunLevel Highest
    $freqSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries
    $freqSched = New-ScheduledTask -Action $freqAction -Trigger $freqTrig `
        -Principal $freqPrincipal -Settings $freqSettings
    try {
        Register-ScheduledTask -TaskName $freqTask -InputObject $freqSched `
            -Force -ErrorAction Stop | Out-Null
        $displayTaskInstalled = $true
        Write-Host ("  -> task '" + $freqTask + "' registered (AtLogOn, Administrator/Interactive)") -ForegroundColor Green
        Write-Host ("  -> task result log: " + $freqLog) -ForegroundColor Green
    } catch {
        Write-Host ("  -> display-mode task registration failed: " + $_.Exception.Message) -ForegroundColor Red
    }
} else {
    Write-Host "  -SkipTask: 不安装显示模式任务；将在当前会话同步切换并验收。" -ForegroundColor Cyan
}

# ---- nudge PnP property cache refresh --------------------------------------
# 设备管理器和 CM_GetDevNodeProperty 会缓存 DEVPKEY；光改 registry 不会立刻刷新。
# 旧逻辑通过 Disable + Enable 刷新，但如果 QEMU/guest 在中途崩溃，Windows 会把显卡永久留成
# Code 22（已禁用）。这里改为只触发设备扫描，并在扫描前后主动启用非 OK 的 Display 设备；
# 真正的属性重读交给后续 reboot 和开机自刷任务完成，避免把显示适配器留在禁用态。
Write-Host ""; Write-Host "Refreshing PnP state without disabling the display adapter..." -ForegroundColor Cyan
try {
    Enable-StealthDisplayDevices -Reason '最终收尾清理 Code 22' | Out-Null
    if (Get-Command 'pnputil.exe' -ErrorAction SilentlyContinue) {
        & pnputil.exe /scan-devices | Out-Null
        Write-Host "  requested PnP device scan" -ForegroundColor Green
        Start-Sleep -Milliseconds 800
        Enable-StealthDisplayDevices -Reason 'PnP 扫描后复查' | Out-Null
    } else {
        Write-Host "  (pnputil.exe unavailable; reboot will refresh PnP state)" -ForegroundColor DarkYellow
    }
} catch {
    Write-Host ("  (PnP refresh skipped: " + $_.Exception.Message + ")") -ForegroundColor DarkYellow
}

# 最后一次 PnP scan 可能回填 Class 安装状态，因此用同一个已提交
# CurrentIdentity 快照同步恢复 stock MatchingDeviceId 与名称镜像。
# 这一步不修改 Enum\PCI HardwareID/CompatibleIDs，也不改 PCI 配置空间。
Write-Host "Reapplying profile-derived shallow Class identity after the final device scan..." -ForegroundColor Cyan
try {
    & $refreshHelperSource
    Write-Host "  -> shallow Class identity refreshed" -ForegroundColor Green
} catch {
    Write-Host ("FAIL: shallow Class identity refresh failed: " + $_.Exception.Message) -ForegroundColor Red
    exit 25
}

# ---- synchronously apply and verify the current session mode ----------------
# 不再用 schtasks /Run 异步触发后固定 sleep 两秒：那样既拿不到任务退出码，也无法证明
# 切换发生在当前交互桌面。这里直接启动子 PowerShell 并等待结束，逐行转发原生返回码、
# 切换前模式和切换后模式；因此外层 respawn 能用本脚本退出码决定是否继续重启。
Write-Host ""; Write-Host "Applying and verifying current display mode synchronously..." -ForegroundColor Cyan
$displayArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $freqScript)
if (-not [string]::IsNullOrWhiteSpace($freqLog)) {
    $displayArgs += @('-LogPath', $freqLog)
}

$displayOutput = @()
$displayModeRc = 24
try {
    $displayOutput = @(& $powershellExe @displayArgs 2>&1)
    $displayModeRc = $LASTEXITCODE
} catch {
    $displayOutput = @('无法启动显示模式辅助脚本：' + $_.Exception.Message)
}
foreach ($line in $displayOutput) {
    Write-Host ('  ' + [string]$line)
}
Write-Host ("  -> display-mode helper exit code: " + $displayModeRc) -ForegroundColor Cyan

# -SkipTask/FirstLogon 没有后续登录任务，所以“无交互桌面”必须作为失败上抛；普通模式
# 只有在任务确实注册成功时才允许明确延后。RESTART 表示请求已持久化，外层既有重启
# 流程可以完成它，但当前会话仍标记为“尚未验证”，不伪装成即时成功。
switch ($displayModeRc) {
    0 {
        $displayModeSummary = '已同步验证：1920x1080@60Hz'
    }
    10 {
        if ($displayTaskInstalled) {
            $displayModeDeferred = $true
            $displayModeSummary = '当前无交互桌面；已明确延后到 Administrator 下次交互登录验收'
        } else {
            $displayModeFailed = $true
            $displayModeFailureCode = 10
            $displayModeSummary = '失败：当前无交互桌面，且没有已注册的登录任务可安全延后'
        }
    }
    11 {
        $displayModeFailed = $true
        $displayModeFailureCode = 11
        $displayModeSummary = 'ChangeDisplaySettings 要求重启；请求已持久化，当前模式尚未验证'
    }
    default {
        $displayModeFailed = $true
        $displayModeFailureCode = if ($displayModeRc -gt 0) { $displayModeRc } else { 24 }
        $displayModeSummary = ('失败：显示模式辅助脚本退出码=' + $displayModeRc)
    }
}

if ($SkipTask) {
    # 临时辅助脚本已完成唯一一次同步调用；清理失败不会改变刚才取得的验收结果。
    Remove-Item -LiteralPath $freqScript -Force -ErrorAction SilentlyContinue
}

# ---- verify ----------------------------------------------------------------
Write-Host ""; Write-Host "Verifying via WMI..." -ForegroundColor Cyan
Get-WmiObject Win32_VideoController |
    Select-Object Name, VideoProcessor, AdapterRAM, DriverVersion,
        CurrentHorizontalResolution, CurrentVerticalResolution, CurrentRefreshRate |
    Format-List

Write-Host ""
if ($SkipTask) {
    Write-Host "Done. -SkipTask kept this run one-shot; no refresh/display task was installed." -ForegroundColor Yellow
} else {
    Write-Host "Done. Scheduled tasks refresh the spoof at boot/logon and verify display mode at logon." -ForegroundColor Yellow
}
if ($displayModeFailed) {
    Write-Host ("DISPLAY MODE: " + $displayModeSummary) -ForegroundColor Red
} elseif ($displayModeDeferred) {
    Write-Host ("DISPLAY MODE DEFERRED: " + $displayModeSummary) -ForegroundColor Yellow
} else {
    Write-Host ("DISPLAY MODE: " + $displayModeSummary) -ForegroundColor Green
}

if ($displayModeFailed) {
    # 把辅助脚本的稳定退出码原样交给 respawn；调用方因此不会在模式验收失败后继续
    # 打印“全部成功”。退出码 11 明确交给外层执行重启后的第二阶段验收。
    exit $displayModeFailureCode
}

try {
    & $identityHelperSource -CompleteIdentity $identityTransactionId
    $identityTransactionCompleted = $true
} catch {
    $completeError = $_.Exception
    try {
        # Complete 的 durable 顺序是 State=Completed 后再清 Pending。调用异常不能
        # 直接假定“未完成”。先只读 State：Committed 交给 outer finally 严格执行
        # pointer→DLL rollback；Completed 才允许清理 Pending 并保留新 reader。
        $completeInspection = & $identityHelperSource -InspectIdentity $identityTransactionId
    } catch {
        # 无法裁决时绝不能先删 reader receipt/backup。保留兼容 schema-1/2 的新
        # readers 与 durable journals，让下次启动先恢复 identity、再按 pointer 恢复。
        $identityCompletionUnresolved = $true
        throw ('CompleteIdentity 失败且 durable 裁决失败：' + $completeError.Message +
            '；resolver=' + $_.Exception.Message)
    }
    $resolvedState = [string]$completeInspection.State
    if ($resolvedState -ceq 'Completed') {
        try {
            $completeResolution = & $identityHelperSource -RollbackIdentity `
                $identityTransactionId
            if ([string]$completeResolution.Action -cne 'Completed' -and
                [string]$completeResolution.State -cne 'Completed') {
                throw 'Completed 清理返回了非 Completed 状态'
            }
        } catch {
            $identityCompletionUnresolved = $true
            throw ('CompleteIdentity 已持久完成但 Pending 清理失败：' +
                $_.Exception.Message)
        }
        $identityTransactionCompleted = $true
        Write-Warning ('CompleteIdentity 返回异常，但 durable journal 已裁决为 Completed：' +
            $completeError.Message)
    } elseif (@('Prepared','Committed','RolledBack') -ccontains $resolvedState) {
        throw $completeError
    } else {
        $identityCompletionUnresolved = $true
        throw ('CompleteIdentity inspect 返回未知状态：' + $resolvedState)
    }
}
if ($gpuApiTransactionPrepared) {
    # Complete 已清除 PendingIdentity 并把事务标为 Completed；此后收据只负责验证
    # 两套新 reader 后删除旧备份。Finalize 失败不会倒退已完成身份，收据留待 Recover。
    $gpuApiFinalizeArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy',
        'Bypass', '-File', $gpuApiCoordinatorSource, '-Action', 'Finalize',
        '-TransactionId', $identityTransactionId)
    & $powershellExe @gpuApiFinalizeArgs
    if ($LASTEXITCODE -ne 0) {
        throw ('系统 GPU API 身份投影 Finalize 失败，退出码=' + $LASTEXITCODE)
    }
    $gpuApiTransactionPrepared = $false
    Write-Host '  -> NVAPI + ADL + identity transaction finalized' `
        -ForegroundColor Green
}

# Driver-tab DEVPKEY 只是与浅层身份验收分离的历史诊断项。只有 identity
# 和可选 GPU API readers 全部提交后才打印成功；不再用红色“必须修 host”把
# 一键流程不需要的外观字段误报为失败。
Write-Host ""
Write-Host "Shallow GPU identity completed; no host-side offline fix is required." `
    -ForegroundColor Green
Write-Host "Optional diagnostic only: if the legacy Device Manager Driver Provider field" `
    -ForegroundColor DarkCyan
Write-Host "is the specific field under investigation, inspect host-fix-gpu-devpkey.sh." `
    -ForegroundColor DarkCyan
} finally {
    if (-not [string]::IsNullOrWhiteSpace($identityTransactionId) -and
        -not $identityTransactionCompleted -and -not $identityCompletionUnresolved) {
        Write-Warning ('GPU identity transaction failed; restoring durable journal ' +
            $identityTransactionId)
        $rollbackErrors = New-Object Collections.Generic.List[string]
        $identityRollbackResolution = $null
        try {
            # 顺序不可交换：新 reader 严格兼容 schema-1/2，先把 pointer 恢复旧版；
            # 历史 old reader 未必认识 schema-2，只能在 pointer 已旧后再恢复 DLL。
            $identityRollbackResolution = & $identityHelperSource `
                -RollbackIdentity $identityTransactionId
        } catch {
            $rollbackErrors.Add($_.Exception.Message)
        }
        if ($null -eq $identityRollbackResolution -and $rollbackErrors.Count -eq 0) {
            $rollbackErrors.Add('identity Rollback 没有返回 durable 裁决结果')
        }
        if ($null -ne $identityRollbackResolution -and $gpuApiTransactionPrepared) {
            $rollbackAction = [string]$identityRollbackResolution.Action
            $rollbackState = [string]$identityRollbackResolution.State
            $gpuApiRecoveryAction = if ($rollbackAction -ceq 'Completed' -or
                $rollbackState -ceq 'Completed') { 'Finalize' } else { 'Rollback' }
            try {
                $gpuApiRecoveryArgs = @('-NoProfile', '-NonInteractive',
                    '-ExecutionPolicy', 'Bypass', '-File', $gpuApiCoordinatorSource,
                    '-Action', $gpuApiRecoveryAction, '-TransactionId',
                    $identityTransactionId)
                & $powershellExe @gpuApiRecoveryArgs
                if ($LASTEXITCODE -ne 0) {
                    throw ('GPU API ' + $gpuApiRecoveryAction +
                        ' 退出码=' + $LASTEXITCODE)
                }
                $gpuApiTransactionPrepared = $false
                if ($gpuApiRecoveryAction -ceq 'Finalize') {
                    $identityTransactionCompleted = $true
                }
            } catch { $rollbackErrors.Add($_.Exception.Message) }
        }
        if ($rollbackErrors.Count -gt 0) {
            throw ('GPU identity/API 跨组件回滚失败：' + ($rollbackErrors -join ' | '))
        }
    }
}
