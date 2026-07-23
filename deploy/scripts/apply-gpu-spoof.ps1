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
    # 正式 respawn 传入同时携带 NVAPI/ADL 的受保护 payload；系统目录只发布 staged
    # vendor 对应的一组，并与 schema-2 identity 共用 durable try/finally。参数名保留旧调用兼容，
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
$applySupportSource = Join-Path $PSScriptRoot 'gpu-spoof-apply-support.ps1'
$boardIdentityContractSource = Join-Path $PSScriptRoot 'gpu-board-identity-contract.ps1'
$missingHelper = @($refreshHelperSource, $displayModeHelperSource, $identityHelperSource,
    $transactionHelperSource, $registryCoreSource, $applySupportSource,
    $boardIdentityContractSource) |
    Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
if (-not $ListOnly -and $missingHelper) {
    throw ("缺少同目录辅助脚本: " + $missingHelper)
}
if (Test-Path -LiteralPath $applySupportSource -PathType Leaf) {
    # helper 载入本身无副作用；所有设备、任务与显示操作仍由下方事务流程显式调用。
    . $applySupportSource
} elseif ($AutoDetect) {
    throw ('AutoDetect 缺少同目录辅助脚本: ' + $applySupportSource)
}

# 两个厂商读取层的文件存在性要在 Stage 前检查；摘要、PE 架构和系统目标 allowlist
# 仍由统一 coordinator 的双重只读 Preflight 验证。
$gpuApiPayloadRoot = ''; $gpuApiCoordinatorSource = ''
if (-not $ListOnly -and -not [string]::IsNullOrWhiteSpace($NvapiPayloadDir)) {
    $gpuApiPayloadRoot = [IO.Path]::GetFullPath($NvapiPayloadDir)
    $gpuApiCoordinatorSource = Join-Path $gpuApiPayloadRoot 'install-gpu-api-system.ps1'
    $missingGpuApiPayload = @(
        'install-gpu-api-system.ps1', 'gpu-api-identity-binding.ps1',
        'install-nvapi-system.ps1',
        'nvapi-system-validation.ps1', 'nvapi-system-transaction.ps1',
        'install-adl-system.ps1',
        'adl-system-transaction.ps1', 'nvapi.dll', 'nvapi64.dll',
        'atiadlxy.dll', 'atiadlxx32.dll', 'atiadlxx.dll'
    ) | ForEach-Object { Join-Path $gpuApiPayloadRoot $_ } |
        Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) } |
        Select-Object -First 1
    if ($missingGpuApiPayload) {
        throw ('正式 GPU API payload 不完整：' + $missingGpuApiPayload)
    }
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
                '-Action', 'Recover', '-Vendor', 'Auto')
            & $powershellExe @recoverGpuApiArgs
            if ($LASTEXITCODE -ne 0) {
                throw ('系统 GPU API 中断事务恢复失败，退出码=' + $LASTEXITCODE)
            }
        }
    }

# -AutoDetect：从 PnP Display 设备的 SUBSYS 串查整个 GPU bundle。显存类型/
# 位宽与三组时钟必须和名称、PCI ID 同时切换，不允许沿用上一台 clone 的值。
# 用于 clone-from-base 之后 profile reroll，PCI subsys 变了但 base 注册表覆盖还是老 GPU。
$detectedProfile = if ($AutoDetect -or -not $ListOnly) {
    Get-GpuSpoofAutoDetectProfile
} else { $null }
if ($AutoDetect) {
    $profile = $detectedProfile
    $SpoofName = $profile.Name; $SpoofVendor = $profile.Vendor
    $SpoofBios = $profile.Bios; $SpoofRamMb = $profile.RamMb
    $SpoofMemoryType = $profile.MemoryType
    $SpoofMemoryBusWidthBits = $profile.BusWidthBits
    $SpoofBaseClockKHz = $profile.BaseClockKHz
    $SpoofBoostClockKHz = $profile.BoostClockKHz
    $SpoofMemoryClockKHz = $profile.MemoryClockKHz
    $SpoofSliSupported = $profile.SliSupported
} elseif (-not $ListOnly) {
    $requestedProfile = @{
        Name=$SpoofName; Vendor=$SpoofVendor; Bios=$SpoofBios; RamMb=$SpoofRamMb
        MemoryType=$SpoofMemoryType; BusWidthBits=$SpoofMemoryBusWidthBits
        BaseClockKHz=$SpoofBaseClockKHz; BoostClockKHz=$SpoofBoostClockKHz
        MemoryClockKHz=$SpoofMemoryClockKHz; SliSupported=$SpoofSliSupported
    }
    Assert-GpuSpoofAibProfile -Expected $detectedProfile -Actual $requestedProfile
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
    # 厂商 API 选择只能来自已经通过 schema、VioGpuDod、SUBSYS 与 pointer 双重
    # 校验的 staged snapshot。clone 的旧 CurrentIdentity 可能仍属于 base 厂商，
    # 直接沿用它会在 AMD base -> NVIDIA clone 时继续发布错误的系统 reader。
    $gpuApiVendor = [string]$stagedIdentity.SpoofVendor
    if (@('NVIDIA', 'AMD') -cnotcontains $gpuApiVendor) {
        throw ('staged GPU identity 返回了不支持的厂商：' + $gpuApiVendor)
    }

    # 物理门禁通过后才允许修复 Code 22。禁用设备仍可被 PresentOnly/Enum 注册表识别，
    # 因而不需要为了 AutoDetect 提前改变设备状态。
    Enable-GpuSpoofDisplayDevices -Reason '浅层物理门禁通过后清理 Code 22' | Out-Null
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

# reader 必须先于 CurrentIdentity pointer 发布。coordinator 以 staged identity 的
# 厂商为唯一目标，在任何 Move 前完成目标 reader 与非目标残留的只读预检，再落
# durable receipt；此后无论 Commit/Complete 在哪里失败，outer finally 都能先恢复
# 旧 pointer、再恢复 reader。
if (-not [string]::IsNullOrWhiteSpace($gpuApiCoordinatorSource)) {
    Write-Host ('Preparing durable ' + $gpuApiVendor +
        ' hardware API projection...') `
        -ForegroundColor Cyan
    $gpuApiInstallArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy',
        'Bypass', '-File', $gpuApiCoordinatorSource, '-Action', 'Install',
        '-PayloadDir', $gpuApiPayloadRoot, '-TransactionId', $identityTransactionId,
        '-Vendor', $gpuApiVendor, '-DeferFinalize')
    & $powershellExe @gpuApiInstallArgs
    if ($LASTEXITCODE -ne 0) {
        throw ('系统 GPU API 身份投影准备失败，退出码=' + $LASTEXITCODE)
    }
    $gpuApiTransactionPrepared = $true
    Write-Host ('  -> ' + $gpuApiVendor +
        ' reader prepared before pointer commit') `
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

# Monitor 节点由 Host profile → QEMU EDID → Windows PnP 唯一负责。GPU refresh
# 不得广扫或重写显示器身份，避免覆盖当前选中的多品牌 component。

# 显示模式脚本无论是否带 -SkipTask 都会在当前会话同步执行；以下状态只决定当当前
# 进程位于 Session 0 等无交互会话时，是否确实存在一个可在下次登录重试的延后任务。
$taskSetup = Install-GpuSpoofScheduledTasks -PowerShellExe $powershellExe `
    -ApplyScriptRoot $PSScriptRoot -RefreshHelperSource $refreshHelperSource `
    -BoardIdentityContractSource $boardIdentityContractSource `
    -DisplayModeHelperSource $displayModeHelperSource -SkipDisplayTask:$SkipTask
$displayTaskInstalled = [bool]$taskSetup.DisplayTaskInstalled
$freqScript = [string]$taskSetup.FrequencyScript
$freqLog = [string]$taskSetup.FrequencyLog

# ---- nudge PnP property cache refresh --------------------------------------
# 设备管理器和 CM_GetDevNodeProperty 会缓存 DEVPKEY；光改 registry 不会立刻刷新。
# helper 只启用异常设备并请求 scan，绝不使用可能遗留 Code 22 的 Disable/Enable。
Invoke-GpuSpoofPnpRefresh

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
# helper 同步等待子进程并把稳定退出码归一为 Success/Deferred/Failed。
$displayResult = Invoke-GpuSpoofDisplayModeVerification `
    -PowerShellExe $powershellExe -FrequencyScript $freqScript `
    -FrequencyLog $freqLog -DisplayTaskInstalled $displayTaskInstalled `
    -RemoveTemporaryScript:$SkipTask
$displayModeDeferred = [bool]$displayResult.Deferred
$displayModeFailed = [bool]$displayResult.Failed
$displayModeFailureCode = [int]$displayResult.FailureCode
$displayModeSummary = [string]$displayResult.Summary

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
    # 目标 reader/非目标清理后删除旧备份。Finalize 失败不会倒退已完成身份，
    # 收据留待下一次 Vendor=Auto Recover。
    $gpuApiFinalizeArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy',
        'Bypass', '-File', $gpuApiCoordinatorSource, '-Action', 'Finalize',
        '-TransactionId', $identityTransactionId, '-Vendor', $gpuApiVendor)
    & $powershellExe @gpuApiFinalizeArgs
    if ($LASTEXITCODE -ne 0) {
        throw ('系统 GPU API 身份投影 Finalize 失败，退出码=' + $LASTEXITCODE)
    }
    $gpuApiTransactionPrepared = $false
    Write-Host ('  -> ' + $gpuApiVendor +
        ' API + identity transaction finalized') `
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
                    $identityTransactionId, '-Vendor', $gpuApiVendor)
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
