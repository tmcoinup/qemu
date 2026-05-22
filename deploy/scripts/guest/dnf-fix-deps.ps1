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
#   - 已安装的包跳过（DLL 检测 + 注册表双重判定），重复执行安全
#   - 任一包失败不阻塞后续；最后汇总报错供排查
#   - 强制 TLS 1.2，避免 Windows 10 早期版本的 SChannel 默认禁用 TLS1.2
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File C:\dnf-fix\dnf-fix-deps.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File C:\dnf-fix\dnf-fix-deps.ps1 -DryRun
#
# 退出码：
#   0 = 全部成功（含"已装跳过"）
#   1 = 至少一项安装失败
#   2 = 缺少管理员权限
#
# 注意：DNF 主进程是 32 位，x86 运行库才是核心，x64 顺手装上避免 WeGame/anti-cheat 报错。

[CmdletBinding()]
param(
    # 仅打印计划，不下载也不安装
    [switch]$DryRun,

    # 下载缓存目录（重复执行可复用已下载的安装包）
    [string]$CacheDir = 'C:\dnf-fix\cache',

    # 日志路径
    [string]$LogPath = 'C:\dnf-fix\install.log'
)

$ErrorActionPreference = 'Stop'
# 关闭 Invoke-WebRequest 的进度条 —— PS 5.1 上进度条会让下载慢 10 倍以上
$ProgressPreference = 'SilentlyContinue'

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
    try { Add-Content -Path $LogPath -Value $line -Encoding UTF8 } catch { }
}

# 检查管理员权限（VC++ 静默安装、DirectX 装到 system32 都需要）
function Test-Admin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

# 判定一个包是否已安装：先看 DLL，再看注册表（双保险）
function Test-PackageInstalled {
    param(
        [Parameter(Mandatory)][hashtable]$Pkg
    )

    # DLL 路径检测：DLL 存在即认为已装好
    if ($Pkg.ContainsKey('CheckDll')) {
        foreach ($dll in $Pkg.CheckDll) {
            if (Test-Path $dll) { return $true }
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

# 下载到缓存，已存在则跳过
function Get-Installer {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination
    )

    if (Test-Path $Destination) {
        $size = (Get-Item $Destination).Length
        # 防御：偶发下载到一半就被中断，文件大小过小直接重下
        if ($size -gt 100KB) {
            Write-Log "  缓存命中: $Destination ($([math]::Round($size/1MB,1)) MB)"
            return
        }
        Write-Log "  缓存文件过小($size B)，重新下载" -Level WARN
        Remove-Item $Destination -Force
    }

    Write-Log "  下载: $Url"
    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -TimeoutSec 600
    $size = (Get-Item $Destination).Length
    Write-Log "  完成: $([math]::Round($size/1MB,1)) MB"
}

# 静默执行一个安装包；返回 $true 表示退出码可接受
function Invoke-Installer {
    param(
        [Parameter(Mandatory)][string]$ExePath,
        [Parameter(Mandatory)][string]$Arguments
    )

    Write-Log "  运行: $ExePath $Arguments"
    $proc = Start-Process -FilePath $ExePath -ArgumentList $Arguments -Wait -PassThru -NoNewWindow
    $code = $proc.ExitCode

    # 微软安装器的可接受退出码：
    #   0    成功
    #   1638 已安装更新版本（VC++ Redist 经典码）
    #   3010 成功，需要重启
    if ($code -in 0, 1638, 3010) {
        Write-Log "  退出码 $code (OK)" -Level OK
        return $true
    } else {
        Write-Log "  退出码 $code (失败)" -Level ERROR
        return $false
    }
}

# ---- 包清单 --------------------------------------------------------
# 顺序：先装老的（2010），再装新的；同一年 x86 先于 x64（DNF 是 32 位）
#
# 检测策略：
#   CheckDll —— 该 Redist 装好后会落到 system32（x64）或 SysWOW64（x86）的标志 DLL
#   CheckRegKey/CheckRegName —— Installed=1 的注册表键，DLL 不在常见路径时兜底
$Packages = @(
    @{
        Id        = 'vcredist2010-x86'
        Name      = 'Visual C++ 2010 SP1 (x86)'
        Url       = 'https://download.microsoft.com/download/1/6/5/165255E7-1014-4D0A-B094-B6A430A6BFFC/vcredist_x86.exe'
        File      = 'vcredist2010_x86.exe'
        Args      = '/q /norestart'
        CheckDll  = @('C:\Windows\SysWOW64\msvcr100.dll')
    },
    @{
        Id        = 'vcredist2010-x64'
        Name      = 'Visual C++ 2010 SP1 (x64)'
        Url       = 'https://download.microsoft.com/download/1/6/5/165255E7-1014-4D0A-B094-B6A430A6BFFC/vcredist_x64.exe'
        File      = 'vcredist2010_x64.exe'
        Args      = '/q /norestart'
        CheckDll  = @('C:\Windows\System32\msvcr100.dll')
    },
    @{
        Id        = 'vcredist2013-x86'
        Name      = 'Visual C++ 2013 (x86)'
        Url       = 'https://aka.ms/highdpimfc2013x86enu'
        File      = 'vcredist2013_x86.exe'
        Args      = '/install /quiet /norestart'
        CheckDll  = @('C:\Windows\SysWOW64\msvcr120.dll')
    },
    @{
        Id        = 'vcredist2013-x64'
        Name      = 'Visual C++ 2013 (x64)'
        Url       = 'https://aka.ms/highdpimfc2013x64enu'
        File      = 'vcredist2013_x64.exe'
        Args      = '/install /quiet /norestart'
        CheckDll  = @('C:\Windows\System32\msvcr120.dll')
    },
    @{
        Id        = 'vcredist2015_2022-x86'
        Name      = 'Visual C++ 2015-2022 (x86)'
        Url       = 'https://aka.ms/vs/17/release/vc_redist.x86.exe'
        File      = 'vc_redist.x86.exe'
        Args      = '/install /quiet /norestart'
        CheckDll  = @('C:\Windows\SysWOW64\vcruntime140.dll')
    },
    @{
        Id        = 'vcredist2015_2022-x64'
        Name      = 'Visual C++ 2015-2022 (x64)'
        Url       = 'https://aka.ms/vs/17/release/vc_redist.x64.exe'
        File      = 'vc_redist.x64.exe'
        Args      = '/install /quiet /norestart'
        CheckDll  = @('C:\Windows\System32\vcruntime140.dll')
    },
    @{
        Id        = 'directx-web'
        Name      = 'DirectX 9.0c End-User Runtime (Web)'
        Url       = 'https://download.microsoft.com/download/1/7/1/1718CCC4-6315-4D8E-9543-8E28A4E18C4C/dxwebsetup.exe'
        File      = 'dxwebsetup.exe'
        Args      = '/Q'
        # d3dx9_43.dll 是 June 2010 redist 的标志文件；DNF 启动时实际依赖它
        CheckDll  = @('C:\Windows\SysWOW64\d3dx9_43.dll', 'C:\Windows\System32\d3dx9_43.dll')
    }
)

# ---- 主流程 --------------------------------------------------------

# 强制 TLS 1.2（Win10 1507 默认禁用，且微软下载链强制 https）
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {
    Write-Host "WARN: 无法设置 TLS1.2，可能下载失败" -ForegroundColor Yellow
}

# 准备日志目录
$logDir = Split-Path -Parent $LogPath
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null }

Write-Log "==== dnf-fix-deps 启动 ===="
Write-Log "DryRun=$DryRun, CacheDir=$CacheDir, LogPath=$LogPath"

if (-not (Test-Admin)) {
    Write-Log "需要管理员权限运行" -Level ERROR
    exit 2
}

# 计划 → 跳过 / 待装清单
$plan = foreach ($pkg in $Packages) {
    $installed = Test-PackageInstalled -Pkg $pkg
    [PSCustomObject]@{
        Id        = $pkg.Id
        Name      = $pkg.Name
        Installed = $installed
        Pkg       = $pkg
    }
}

Write-Log ""
Write-Log "---- 当前状态 ----"
foreach ($p in $plan) {
    $mark = if ($p.Installed) { '已装' } else { '待装' }
    $lvl  = if ($p.Installed) { 'OK' } else { 'INFO' }
    Write-Log ("  [{0}] {1}" -f $mark, $p.Name) -Level $lvl
}
Write-Log ""

if ($DryRun) {
    Write-Log "DryRun 模式：不下载也不安装"
    exit 0
}

# 安装阶段
$failed = @()
$pending = $plan | Where-Object { -not $_.Installed }
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
        Get-Installer -Url $pkg.Url -Destination $dest
    } catch {
        Write-Log "  下载失败: $($_.Exception.Message)" -Level ERROR
        $failed += $pkg.Id
        continue
    }

    try {
        $ok = Invoke-Installer -ExePath $dest -Arguments $pkg.Args
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
    Write-Log "日志: $LogPath"
    exit 1
}

Write-Log "全部成功" -Level OK
Write-Log "日志: $LogPath"

# 再次扫描确认 —— 安装器有时退出码 0 但实际写盘失败
Write-Log ""
Write-Log "---- 安装后复检 ----"
$stillMissing = @()
foreach ($pkg in $Packages) {
    if (-not (Test-PackageInstalled -Pkg $pkg)) {
        $stillMissing += $pkg.Id
        Write-Log "  [缺失] $($pkg.Name)" -Level WARN
    }
}
if ($stillMissing.Count -gt 0) {
    Write-Log "复检发现仍缺失: $($stillMissing -join ', ')" -Level WARN
    Write-Log "提示：DirectX dxwebsetup 是在线安装，未联网时可能没真正落地" -Level WARN
    exit 1
}

Write-Log "复检通过，DNF 现在应该能启动了" -Level OK
exit 0
