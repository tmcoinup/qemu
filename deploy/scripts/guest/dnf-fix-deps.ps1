# dnf-fix-deps.ps1 —— 修复 DNF.exe 启动错误 0xc000007b 所需的运行库
#
# 用途：
#   一键检测并静默安装 DNF 必需的运行库，覆盖：
#     - VC++ 2010 SP1   (x86 + x64)   —— DNF 客户端主体
#     - VC++ 2013       (x86 + x64)   —— TGP / 部分子模块
#     - VC++ 2015-2022  (x86 + x64)   —— WeGame / 反外挂
#     - DirectX 9.0c End-User Runtime  —— d3dx9_*.dll / d3dcompiler_*.dll
#
# 设计取舍：
#   - 直接从微软官方域名下载（download.microsoft.com / aka.ms），不走第三方镜像
#   - VC++ 已安装项跳过；DirectSetup 每次快速复验，重复执行安全
#   - 任一包失败不阻塞后续；最后汇总报错供排查
#   - DirectX 使用 June 2010 完整包，避免旧 Web 安装器的零 section 失败
#   - 强制 TLS 1.2，避免 Windows 10 早期版本的 SChannel 默认禁用 TLS1.2
#
# 入口边界：
#   此文件只作为 dnf-fix-deps.exe 的内嵌 payload 运行，不支持独立调用。
#   EXE 会先创建受保护的 ProgramData 目录，再显式传入缓存和日志路径。
#
# 退出码：
#   0 = 全部成功（含"已装跳过"）
#   1 = 至少一项安装失败
#   2 = 缺少管理员权限
#   3010 = 全部成功，但 Windows 需要重启
#
# 注意：DNF 主进程是 32 位，x86 运行库才是核心，x64 顺手装上避免 WeGame/anti-cheat 报错。

[CmdletBinding()]
param(
    # 仅打印计划，不下载也不安装
    [switch]$DryRun,

    # 仅由 EXE 注入；外部命令行不能通过启动器参数白名单设置此开关。
    [switch]$LauncherMode,

    # 由 EXE 指定的受保护缓存目录；不提供默认值，避免脚本脱离启动器运行。
    [Parameter(Mandatory)][string]$CacheDir,

    # 由 EXE 指定的受保护日志路径；不提供默认值，避免使用可抢占目录。
    [Parameter(Mandatory)][string]$LogPath
)

# 验证脚本确实运行在 EXE 固定发布的 ProgramData 目录中。
# LauncherMode 只表示调用约束，不作为秘密令牌；真正的路径可信边界由启动器在
# 创建 PowerShell 前施加的 Owner/DACL、重解析点检查和原子 payload 发布保证。
function Test-LauncherInvocation {
    param(
        [switch]$Enabled,
        [Parameter(Mandatory)][string]$CommonAppData,
        [Parameter(Mandatory)][string]$ScriptRoot,
        [Parameter(Mandatory)][string]$CachePath,
        [Parameter(Mandatory)][string]$LogFile
    )

    if (-not $Enabled -or
        [string]::IsNullOrWhiteSpace($CommonAppData) -or
        [string]::IsNullOrWhiteSpace($ScriptRoot)) {
        return $false
    }

    try {
        $expectedRoot = [IO.Path]::GetFullPath(
            (Join-Path $CommonAppData 'VMateDnfDeps')
        )
        $expectedScriptRoot = [IO.Path]::GetFullPath(
            (Join-Path $expectedRoot 'payload')
        )
        $expectedCache = [IO.Path]::GetFullPath(
            (Join-Path $expectedRoot 'cache')
        )
        $expectedLog = [IO.Path]::GetFullPath(
            (Join-Path $expectedRoot 'install.log')
        )
        $actualScriptRoot = [IO.Path]::GetFullPath($ScriptRoot)
        $actualCache = [IO.Path]::GetFullPath($CachePath)
        $actualLog = [IO.Path]::GetFullPath($LogFile)
    } catch {
        return $false
    }

    $comparer = [StringComparer]::OrdinalIgnoreCase
    return $comparer.Equals($expectedScriptRoot, $actualScriptRoot) -and
        $comparer.Equals($expectedCache, $actualCache) -and
        $comparer.Equals($expectedLog, $actualLog)
}

$commonAppData = [Environment]::GetFolderPath(
    [Environment+SpecialFolder]::CommonApplicationData
)
if (-not (Test-LauncherInvocation -Enabled:$LauncherMode `
        -CommonAppData $commonAppData -ScriptRoot $PSScriptRoot `
        -CachePath $CacheDir -LogFile $LogPath)) {
    Write-Host 'ERROR: 该内嵌脚本只能由 dnf-fix-deps.exe 从受保护目录启动' `
        -ForegroundColor Red
    exit 87
}

$ErrorActionPreference = 'Stop'
# 关闭 Invoke-WebRequest 的进度条 —— PS 5.1 上进度条会让下载慢 10 倍以上
$ProgressPreference = 'SilentlyContinue'
$script:RestartRequired = $false
$script:RestartRequiredPackages = @()
$script:RecheckOnlyPackages = @()

# ---- 工具函数 ------------------------------------------------------

# 统一日志：同时打印到控制台和写入 $LogPath
function Write-Log {
    param(
        # AllowEmptyString —— 脚本里用 Write-Log "" 打空行，Mandatory+[string] 默认不允许空
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','OK')][string]$Level = 'INFO'
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    $color = switch ($Level) {
        'OK'    { 'Green' }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        default { 'Gray' }
    }
    Write-Host $line -ForegroundColor $color
    try {
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    } catch {
        [Console]::Error.WriteLine("无法写入日志 $LogPath：$($_.Exception.Message)")
        throw
    }
}

# 检查管理员权限（VC++ 静默安装、DirectX 装到 system32 都需要）
function Test-Admin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

# 从 PE 头读取 Machine 字段，区分 x86(0x014c) 与 x64(0x8664)。
function Get-PeMachine {
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $stream = $null
    $reader = $null
    try {
        $stream = [IO.File]::Open(
            $Path,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::ReadWrite
        )
        $reader = New-Object IO.BinaryReader($stream)
        if ($reader.ReadUInt16() -ne 0x5A4D) { return $null }
        $stream.Position = 0x3C
        $peOffset = $reader.ReadInt32()
        if ($peOffset -lt 0 -or $peOffset -gt ($stream.Length - 6)) {
            return $null
        }
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) { return $null }
        return $reader.ReadUInt16()
    } catch {
        return $null
    } finally {
        if ($null -ne $reader) {
            $reader.Dispose()
        } elseif ($null -ne $stream) {
            $stream.Dispose()
        }
    }
}

# 判定一个包是否已安装：先看必需 DLL；清单提供注册表项时再用作兜底。
function Test-PackageInstalled {
    param(
        [Parameter(Mandatory)][hashtable]$Pkg,
        [switch]$Explain
    )

    # DLL 路径检测：清单里的全部 DLL 都存在才认为已装好。
    # DirectX 同时检查 x86/x64，避免仅有 System32 文件时误判 DNF 已满足。
    if ($Pkg.ContainsKey('CheckDll')) {
        $allDllsPresent = $true
        $failureReason = ''
        for ($index = 0; $index -lt $Pkg.CheckDll.Count; $index++) {
            $dll = $Pkg.CheckDll[$index]
            if (-not (Test-Path -LiteralPath $dll -PathType Leaf)) {
                $allDllsPresent = $false
                $failureReason = "文件不存在: $dll"
                break
            }
            if ($Pkg.ContainsKey('CheckMachine') -and
                (Get-PeMachine -Path $dll) -ne $Pkg.CheckMachine[$index]) {
                $allDllsPresent = $false
                $failureReason = "PE 架构不符: $dll"
                break
            }
            if ($Pkg.ContainsKey('MinFileVersion')) {
                $versionInfo = (Get-Item -LiteralPath $dll -Force).VersionInfo
                $actualVersion = [version]::Parse((
                    '{0}.{1}.{2}.{3}' -f
                    $versionInfo.FileMajorPart,
                    $versionInfo.FileMinorPart,
                    $versionInfo.FileBuildPart,
                    $versionInfo.FilePrivatePart
                ))
                if ($actualVersion -lt [version]$Pkg.MinFileVersion) {
                    $allDllsPresent = $false
                    $failureReason = "版本过低: $dll ($actualVersion)"
                    break
                }
            }
        }
        if ($allDllsPresent) { return $true }
        if ($Explain -and -not [string]::IsNullOrWhiteSpace($failureReason)) {
            Write-Log "  检测失败 [$($Pkg.Id)]: $failureReason" -Level WARN
        }
    }

    # 注册表检测：Installed = 1
    if ($Pkg.ContainsKey('CheckRegKey') -and $Pkg.ContainsKey('CheckRegName')) {
        try {
            $val = Get-ItemProperty -Path $Pkg.CheckRegKey -Name $Pkg.CheckRegName -ErrorAction Stop
            if ($val.($Pkg.CheckRegName) -eq 1) { return $true }
        } catch { }
    }

    return $false
}

# 仅允许“返回成功但需重启”的对应包延后复检。
function Get-BlockingMissingPackages {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Missing,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$RestartPending
    )

    return @($Missing | Where-Object { $RestartPending -notcontains $_ })
}

# 下载/验签与 DirectX 完整包逻辑分开维护，主文件只负责编排。
foreach ($moduleName in 'dnf-fix-installers.ps1','dnf-fix-directx.ps1') {
    $modulePath = Join-Path $PSScriptRoot $moduleName
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
        throw "缺少安装模块: $modulePath"
    }
    . $modulePath
}

# ---- 包清单 --------------------------------------------------------
# 顺序：先装老的（2010），再装新的；同一年 x86 先于 x64（DNF 是 32 位）
#
# 检测策略：
#   CheckDll —— 该 Redist 装好后会落到 system32（x64）或 SysWOW64（x86）的标志 DLL
#   CheckRegKey/CheckRegName —— Installed=1 的注册表键，DLL 不在常见路径时兜底
if (-not (Test-Admin)) {
    Write-Host 'ERROR: 需要管理员权限运行' -ForegroundColor Red
    exit 2
}
if (-not [Environment]::Is64BitProcess) {
    Write-Host 'ERROR: 必须由 EXE 启动 64 位 System32 PowerShell' -ForegroundColor Red
    exit 1
}

$windowsDir = [Environment]::GetFolderPath(
    [Environment+SpecialFolder]::Windows
)
if ([string]::IsNullOrWhiteSpace($windowsDir)) {
    Write-Host 'ERROR: 无法定位 Windows 系统目录' -ForegroundColor Red
    exit 1
}
$system32Dir = Join-Path $windowsDir 'System32'
$sysWow64Dir = Join-Path $windowsDir 'SysWOW64'

$Packages = @(
    @{
        Id        = 'vcredist2010-x86'
        Name      = 'Visual C++ 2010 SP1 (x86)'
        Url       = 'https://download.microsoft.com/download/1/6/5/165255E7-1014-4D0A-B094-B6A430A6BFFC/vcredist_x86.exe'
        File      = 'vcredist2010_x86.exe'
        OriginalFile = 'vcredist_x86.exe'
        Args      = '/q /norestart'
        CheckDll  = @((Join-Path $sysWow64Dir 'msvcr100.dll'), (Join-Path $sysWow64Dir 'msvcp100.dll'))
        CheckMachine = @(0x014C, 0x014C)
        MinFileVersion = '10.0.40219.0'
    },
    @{
        Id        = 'vcredist2010-x64'
        Name      = 'Visual C++ 2010 SP1 (x64)'
        Url       = 'https://download.microsoft.com/download/1/6/5/165255E7-1014-4D0A-B094-B6A430A6BFFC/vcredist_x64.exe'
        File      = 'vcredist2010_x64.exe'
        OriginalFile = 'vcredist_x64.exe'
        Args      = '/q /norestart'
        CheckDll  = @((Join-Path $system32Dir 'msvcr100.dll'), (Join-Path $system32Dir 'msvcp100.dll'))
        CheckMachine = @(0x8664, 0x8664)
        MinFileVersion = '10.0.40219.0'
    },
    @{
        Id        = 'vcredist2013-x86'
        Name      = 'Visual C++ 2013 (x86)'
        Url       = 'https://aka.ms/highdpimfc2013x86enu'
        File      = 'vcredist2013_x86.exe'
        OriginalFile = 'vcredist_x86.exe'
        Args      = '/install /quiet /norestart'
        CheckDll  = @((Join-Path $sysWow64Dir 'msvcr120.dll'), (Join-Path $sysWow64Dir 'msvcp120.dll'))
        CheckMachine = @(0x014C, 0x014C)
        MinFileVersion = '12.0.21005.0'
    },
    @{
        Id        = 'vcredist2013-x64'
        Name      = 'Visual C++ 2013 (x64)'
        Url       = 'https://aka.ms/highdpimfc2013x64enu'
        File      = 'vcredist2013_x64.exe'
        OriginalFile = 'vcredist_x64.exe'
        Args      = '/install /quiet /norestart'
        CheckDll  = @((Join-Path $system32Dir 'msvcr120.dll'), (Join-Path $system32Dir 'msvcp120.dll'))
        CheckMachine = @(0x8664, 0x8664)
        MinFileVersion = '12.0.21005.0'
    },
    @{
        Id        = 'vcredist2015_2022-x86'
        Name      = 'Visual C++ 2015-2022 (x86)'
        Url       = 'https://aka.ms/vs/17/release/vc_redist.x86.exe'
        File      = 'vc_redist.x86.exe'
        OriginalFile = 'VC_redist.x86.exe'
        Args      = '/install /quiet /norestart'
        CheckDll  = @(
            (Join-Path $sysWow64Dir 'vcruntime140.dll'), (Join-Path $sysWow64Dir 'msvcp140.dll'),
            # 官方 x86 redist 不含仅供 x64 使用的 VCRUNTIME _1 变体。
            (Join-Path $sysWow64Dir 'concrt140.dll')
        )
        CheckMachine = @(0x014C, 0x014C, 0x014C)
        MinFileVersion = '14.0.23026.0'
    },
    @{
        Id        = 'vcredist2015_2022-x64'
        Name      = 'Visual C++ 2015-2022 (x64)'
        Url       = 'https://aka.ms/vs/17/release/vc_redist.x64.exe'
        File      = 'vc_redist.x64.exe'
        OriginalFile = 'VC_redist.x64.exe'
        Args      = '/install /quiet /norestart'
        CheckDll  = @(
            (Join-Path $system32Dir 'vcruntime140.dll'), (Join-Path $system32Dir 'msvcp140.dll'),
            (Join-Path $system32Dir 'vcruntime140_1.dll'), (Join-Path $system32Dir 'concrt140.dll')
        )
        CheckMachine = @(0x8664, 0x8664, 0x8664, 0x8664)
        MinFileVersion = '14.0.23026.0'
    },
    (New-DirectXPackage -WindowsDir $windowsDir `
        -System32Dir $system32Dir -SysWow64Dir $sysWow64Dir)
)

# ---- 主流程 --------------------------------------------------------

# 强制 TLS 1.2（Win10 1507 默认禁用，且微软下载链强制 https）
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {
    Write-Host "WARN: 无法设置 TLS1.2，可能下载失败" -ForegroundColor Yellow
}

# 准备日志目录
$CacheDir = [IO.Path]::GetFullPath($CacheDir)
$LogPath = [IO.Path]::GetFullPath($LogPath)
$logDir = [IO.Path]::GetDirectoryName($LogPath)
if ([string]::IsNullOrWhiteSpace($logDir)) {
    throw "日志路径必须包含父目录: $LogPath"
}
if (-not (Test-Path -LiteralPath $logDir)) {
    [void][IO.Directory]::CreateDirectory($logDir)
}
if (-not (Test-Path -LiteralPath $CacheDir)) {
    [void][IO.Directory]::CreateDirectory($CacheDir)
}

Write-Log "==== dnf-fix-deps 启动 ===="
Write-Log "DryRun=$DryRun, CacheDir=$CacheDir, LogPath=$LogPath"

# 计划 → 跳过 / 待装清单
$plan = foreach ($pkg in $Packages) {
    $installed = Test-PackageInstalled -Pkg $pkg
    [PSCustomObject]@{
        Id        = $pkg.Id
        Name      = $pkg.Name
        Installed = $installed
        Pending   = (-not $installed) -or $pkg.AlwaysInstall
        Pkg       = $pkg
    }
}

Write-Log ""
Write-Log "---- 当前状态 ----"
foreach ($p in $plan) {
    $mark = if (-not $p.Installed) { '待装' } `
        elseif ($p.Pending) { '复验' } else { '已装' }
    $lvl  = if ($p.Installed -and -not $p.Pending) { 'OK' } else { 'INFO' }
    Write-Log ("  [{0}] {1}" -f $mark, $p.Name) -Level $lvl
}
Write-Log ""

if ($DryRun) {
    Write-Log "DryRun 模式：不下载也不安装"
    exit 0
}

# 安装阶段
$failed = @()
$pending = $plan | Where-Object { $_.Pending }
if ($pending.Count -eq 0) {
    Write-Log "全部已装，无需处理" -Level OK
    exit 0
}

Write-Log "---- 开始安装 $($pending.Count) 个包 ----"
foreach ($p in $pending) {
    $pkg = $p.Pkg
    Write-Log ""
    Write-Log "→ $($pkg.Name)"

    $dest = Join-Path $CacheDir $pkg.File
    try {
        Get-Installer -Url $pkg.Url -Destination $dest `
            -ExpectedOriginalFileName $pkg.OriginalFile `
            -ExpectedSha256 $pkg.Sha256
    } catch {
        Write-Log "  下载失败: $($_.Exception.Message)" -Level ERROR
        $failed += $pkg.Id
        continue
    }

    try {
        if ($pkg.InstallKind -eq 'DirectXRedist') {
            $ok = Invoke-DirectXRedist -Package $pkg -ExePath $dest `
                -CacheDir $CacheDir
        } else {
            $ok = Invoke-Installer -ExePath $dest -Arguments $pkg.Args `
                -ExpectedOriginalFileName $pkg.OriginalFile `
                -PackageId $pkg.Id
        }
        if (-not $ok) { $failed += $pkg.Id }
    } catch {
        Write-Log "  安装异常: $($_.Exception.Message)" -Level ERROR
        $failed += $pkg.Id
    }
}

# 汇总
Write-Log ""
Write-Log "---- 安装结束 ----"
if ($failed.Count -gt 0) {
    Write-Log "失败项: $($failed -join ', ')" -Level ERROR
} else {
    Write-Log "所有安装器均未返回致命错误，最终结果以复检为准" -Level OK
}
Write-Log "日志: $LogPath"

# 再次扫描确认 —— 安装器有时退出码 0 但实际写盘失败
Write-Log ""
Write-Log "---- 安装后复检 ----"
$stillMissing = @()
foreach ($pkg in $Packages) {
    if (-not (Test-PackageInstalled -Pkg $pkg -Explain)) {
        $stillMissing += $pkg.Id
        Write-Log "  [缺失] $($pkg.Name)" -Level WARN
    }
}
if ($stillMissing.Count -gt 0) {
    Write-Log "复检发现仍缺失: $($stillMissing -join ', ')" -Level WARN
}
if ($stillMissing -contains 'directx-jun2010' -or
    $failed -contains 'directx-jun2010') {
    Write-Log "提示：DirectX 失败细节已从 DXError.log/DirectX.log 同步到上方" -Level WARN
}
$blockingMissing = @(
    Get-BlockingMissingPackages -Missing $stillMissing `
        -RestartPending $script:RestartRequiredPackages
)
if ($blockingMissing.Count -gt 0) {
    Write-Log "非重启待完成的缺失项: $($blockingMissing -join ', ')" -Level ERROR
}
if ($failed.Count -gt 0 -or $blockingMissing.Count -gt 0) {
    exit 1
}

if ($script:RestartRequired) {
    if ($stillMissing.Count -gt 0) {
        Write-Log "缺失项需在重启后再复检" -Level WARN
    }
    Write-Log "安装器要求重启 Windows 后完成配置" -Level WARN
    exit 3010
}
Write-Log "复检通过，DNF 现在应该能启动了" -Level OK
exit 0
