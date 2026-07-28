<#
.SYNOPSIS
  诊断并修复 Windows Sysprep 在验证阶段遇到的 Appx 包冲突。

.DESCRIPTION
  默认只诊断，不修改系统。指定 -RunSysprep 后，脚本会先备份 Panther 日志，
  仅清理由 Sysprep 日志明确点名、且当前仍未正确预配的 Appx 包，然后执行
  sysprep /generalize /oobe /shutdown /quiet。

  脚本刻意不修改 GeneralizationState、CleanupState 或 SysprepStatus 等状态值。
  非 Appx 错误会保留现场并停止，避免用注册表“强行成功”制造不可启动的 base。

.PARAMETER RunSysprep
  应用日志驱动的 Appx 修复，并在检查通过后运行 Sysprep。省略时只输出诊断。

.PARAMETER ExportDirectory
  可选的报告导出目录。适合传入宿主机 SMB 共享路径，方便直接查看 VM 日志。
#>
#Requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$RunSysprep,
    [string]$ExportDirectory
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

try {
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
} catch {
    # 老版本控制台不支持切换编码时继续；文件报告仍显式使用 UTF-8。
}

$script:RepairLogPath = $null

function Write-RepairLog {
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')]
        [string]$Level = 'INFO'
    )

    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    switch ($Level) {
        'WARN' { Write-Host $line -ForegroundColor Yellow }
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'OK' { Write-Host $line -ForegroundColor Green }
        default { Write-Host $line }
    }

    if ($null -ne $script:RepairLogPath) {
        Add-Content -LiteralPath $script:RepairLogPath -Value $line -Encoding UTF8
    }
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw '必须在“以管理员身份运行”的 PowerShell 或 CMD 中执行。'
    }
}

function New-RepairReportDirectory {
    $root = Join-Path $env:ProgramData 'VMate\SysprepRepair'
    [void](New-Item -ItemType Directory -Path $root -Force)

    $name = '{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $PID
    $path = Join-Path $root $name
    [void](New-Item -ItemType Directory -Path $path)
    return $path
}

function Get-SysprepLogPaths {
    $panther = Join-Path $env:WINDIR 'System32\Sysprep\Panther'
    foreach ($name in 'setupact.log', 'setuperr.log') {
        $path = Join-Path $panther $name
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $path
        }
    }
}

function Copy-SysprepLogs {
    param(
        [Parameter(Mandatory)]
        [string[]]$LogPath,
        [Parameter(Mandatory)]
        [string]$ReportDirectory,
        [Parameter(Mandatory)]
        [ValidatePattern('^[a-z0-9-]+$')]
        [string]$Phase
    )

    foreach ($path in $LogPath) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            continue
        }
        $leaf = Split-Path -Leaf $path
        $destination = Join-Path $ReportDirectory ("$Phase-$leaf")
        Copy-Item -LiteralPath $path -Destination $destination -Force
    }
}

function Get-SysprepBlockingPackages {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$LogPath
    )

    $pattern = 'SYSPRP\s+Package\s+(.+?)\s+was installed for a user'
    $packages = foreach ($path in $LogPath) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            continue
        }
        foreach ($line in Get-Content -LiteralPath $path -ErrorAction Stop) {
            $match = [regex]::Match($line, $pattern, 'IgnoreCase')
            if ($match.Success) {
                $match.Groups[1].Value.Trim()
            }
        }
    }

    @($packages | Where-Object { $_ } | Sort-Object -Unique)
}

function Get-SysprepFailureKind {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$LogPath
    )

    $text = ($LogPath | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        ForEach-Object { Get-Content -LiteralPath $_ -Raw }) -join "`n"

    if ($text -match '(?i)Package\s+.+?\s+was installed for a user') {
        return 'AppxPackage'
    }
    if ($text -match '(?i)BitLocker.+(?:is on|enabled)|0x80310039') {
        return 'BitLocker'
    }
    if ($text -match '(?i)reboot.+pending|pending.+(?:update|servicing|operation)') {
        return 'PendingServicing'
    }
    if ($text -match '(?i)(?:Error\s+SYSPRP|dwRet\s*=\s*0x|validation failed)') {
        return 'Other'
    }
    return 'None'
}

function Write-SysprepErrorTail {
    param(
        [Parameter(Mandatory)]
        [string[]]$LogPath
    )

    foreach ($path in $LogPath) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            continue
        }
        Write-RepairLog -Level WARN -Message ("最近日志：{0}" -f $path)
        foreach ($line in Get-Content -LiteralPath $path -Tail 80) {
            Write-RepairLog -Level WARN -Message $line
        }
    }
}

function Get-PendingRestartReasons {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )

    foreach ($key in $keys) {
        if (Test-Path -LiteralPath $key) {
            $key
        }
    }

    $updates = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Updates' `
        -Name 'UpdateExeVolatile' -ErrorAction SilentlyContinue
    if ($null -ne $updates -and [int]$updates.UpdateExeVolatile -ne 0) {
        'HKLM:\SOFTWARE\Microsoft\Updates\UpdateExeVolatile'
    }
}

function Get-AllUserAppxPackages {
    # Get-AppxPackage 默认不保证返回 Bundle/Resource；Sysprep 日志却可能点名它们。
    # 分类型补查后按完整包名去重，删除动作仍只会命中 Panther 指定的唯一名称。
    $packages = @(Get-AppxPackage -AllUsers)
    foreach ($packageType in 'Bundle', 'Resource') {
        try {
            $packages += @(Get-AppxPackage -AllUsers -PackageTypeFilter $packageType)
        } catch {
            Write-RepairLog -Level WARN -Message (
                '当前 Appx 模块不支持 {0} 类型补查：{1}' -f
                $packageType, $_.Exception.Message)
        }
    }

    @($packages | Sort-Object -Property PackageFullName -Unique)
}

function Remove-SysprepBlockingPackage {
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[^\\/:*?"<>|]+$')]
        [string]$PackageFullName
    )

    $displayName = ($PackageFullName -split '_', 2)[0]
    $installed = @(Get-AllUserAppxPackages |
        Where-Object { $_.PackageFullName -ceq $PackageFullName })
    $provisioned = @(Get-AppxProvisionedPackage -Online |
        Where-Object { $_.DisplayName -eq $displayName })

    if ($installed.Count -eq 0) {
        Write-RepairLog -Level OK -Message ("日志中的包已不存在：{0}" -f $PackageFullName)
        return
    }

    $exactProvision = @($provisioned |
        Where-Object { $_.PackageName -ceq $PackageFullName })
    if ($exactProvision.Count -gt 0) {
        Write-RepairLog -Level OK -Message (
            '包现在已与系统预配版本一致，保留不删：{0}' -f $PackageFullName)
        return
    }

    foreach ($package in $installed) {
        Write-RepairLog -Message ("删除所有用户的冲突包：{0}" -f $package.PackageFullName)
        Remove-AppxPackage -Package $package.PackageFullName -AllUsers `
            -Confirm:$false -ErrorAction Stop
    }

    foreach ($package in $provisioned) {
        Write-RepairLog -Message ("删除不匹配的预配版本：{0}" -f $package.PackageName)
        Remove-AppxProvisionedPackage -Online -PackageName $package.PackageName `
            -AllUsers -ErrorAction Stop | Out-Null
    }

    $remainingInstalled = @(Get-AllUserAppxPackages |
        Where-Object { $_.PackageFullName -ceq $PackageFullName })
    $remainingProvisioned = @(Get-AppxProvisionedPackage -Online |
        Where-Object { $_.DisplayName -eq $displayName })
    if ($remainingInstalled.Count -gt 0 -or $remainingProvisioned.Count -gt 0) {
        throw "Appx 包清理后仍有残留：$PackageFullName"
    }

    Write-RepairLog -Level OK -Message ("Appx 冲突已清理：{0}" -f $PackageFullName)
}

function Export-RepairReport {
    param(
        [Parameter(Mandatory)]
        [string]$ReportDirectory,
        [Parameter(Mandatory)]
        [string]$DestinationRoot
    )

    [void](New-Item -ItemType Directory -Path $DestinationRoot -Force)
    $destination = Join-Path $DestinationRoot (Split-Path -Leaf $ReportDirectory)
    [void](New-Item -ItemType Directory -Path $destination -Force)
    Get-ChildItem -LiteralPath $ReportDirectory -File |
        Copy-Item -Destination $destination -Force
    return $destination
}

function Try-ExportRepairReport {
    param(
        [string]$ReportDirectory,
        [string]$DestinationRoot
    )

    if (-not $ReportDirectory -or -not $DestinationRoot) {
        return
    }
    try {
        $destination = Export-RepairReport -ReportDirectory $ReportDirectory `
            -DestinationRoot $DestinationRoot
        Write-Host "报告已导出：$destination" -ForegroundColor Cyan
    } catch {
        Write-Warning ("报告导出失败，但本机副本仍保留：{0}" -f $_.Exception.Message)
    }
}

$exitCode = 1
$reportDirectory = $null
$logPaths = @()
$launchSysprep = $false

try {
    $exitCode = 2
    Assert-Administrator

    $exitCode = 1
    $reportDirectory = New-RepairReportDirectory
    $script:RepairLogPath = Join-Path $reportDirectory 'repair.log'
    Write-RepairLog -Message "报告目录：$reportDirectory"

    $logPaths = @(Get-SysprepLogPaths)
    if ($logPaths.Count -gt 0) {
        Copy-SysprepLogs -LogPath $logPaths -ReportDirectory $reportDirectory `
            -Phase 'before'
    }

    $blockingPackages = @(Get-SysprepBlockingPackages -LogPath $logPaths)
    $failureKind = Get-SysprepFailureKind -LogPath $logPaths
    Write-RepairLog -Message ("失败类型：{0}；日志点名 Appx 包：{1} 个" -f
        $failureKind, $blockingPackages.Count)
    foreach ($package in $blockingPackages) {
        Write-RepairLog -Level WARN -Message "阻塞包：$package"
    }

    if (-not $RunSysprep) {
        Write-RepairLog -Level OK -Message (
            '诊断完成；未指定 -RunSysprep，因此没有修改系统或启动 Sysprep。')
        if ($failureKind -ne 'None' -and $blockingPackages.Count -eq 0) {
            Write-SysprepErrorTail -LogPath $logPaths
        }
        $exitCode = 0
    } else {
        if ($failureKind -ne 'None' -and $blockingPackages.Count -eq 0) {
            $exitCode = 20
            Write-SysprepErrorTail -LogPath $logPaths
            switch ($failureKind) {
                'BitLocker' {
                    throw '系统卷仍启用了 BitLocker；先完整解密系统卷后再运行。'
                }
                'PendingServicing' {
                    throw 'Windows 正处于挂起更新/维护状态；先重启完成维护后再运行。'
                }
                default {
                    throw '当前不是可安全自动修复的 Appx 冲突，已保留完整日志。'
                }
            }
        }

        $pendingRestart = @(Get-PendingRestartReasons)
        if ($pendingRestart.Count -gt 0) {
            foreach ($reason in $pendingRestart) {
                Write-RepairLog -Level WARN -Message "等待重启：$reason"
            }
            $exitCode = 10
            throw '检测到 Windows 更新/组件维护等待重启；重启 VM 后再次运行本脚本。'
        }

        $exitCode = 21
        foreach ($package in $blockingPackages) {
            Remove-SysprepBlockingPackage -PackageFullName $package
        }

        $launchSysprep = $true
        $exitCode = 0
        Write-RepairLog -Level OK -Message '修复与前置检查通过，准备运行 Sysprep。'
    }
} catch {
    if ($null -ne $script:RepairLogPath) {
        Write-RepairLog -Level ERROR -Message $_.Exception.Message
    } else {
        Write-Error $_.Exception.Message
    }
}

Try-ExportRepairReport -ReportDirectory $reportDirectory `
    -DestinationRoot $ExportDirectory

if (-not $launchSysprep) {
    exit $exitCode
}

$sysprep = Join-Path $env:WINDIR 'System32\Sysprep\Sysprep.exe'
$sysprepErrorLog = Join-Path $env:WINDIR 'System32\Sysprep\Panther\setuperr.log'
$errorHashBefore = ''
if (Test-Path -LiteralPath $sysprepErrorLog -PathType Leaf) {
    $errorHashBefore = (Get-FileHash -LiteralPath $sysprepErrorLog `
        -Algorithm SHA256).Hash
}
try {
    Write-RepairLog -Message (
        '启动 Sysprep：/generalize /oobe /shutdown /quiet；成功后 VM 会自动关机。')
    Try-ExportRepairReport -ReportDirectory $reportDirectory `
        -DestinationRoot $ExportDirectory

    $process = Start-Process -FilePath $sysprep -ArgumentList @(
        '/generalize', '/oobe', '/shutdown', '/quiet'
    ) -Wait -PassThru

    $logPaths = @(Get-SysprepLogPaths)
    if ($logPaths.Count -gt 0) {
        Copy-SysprepLogs -LogPath $logPaths -ReportDirectory $reportDirectory `
            -Phase 'after'
    }

    $errorHashAfter = ''
    $errorLengthAfter = 0
    if (Test-Path -LiteralPath $sysprepErrorLog -PathType Leaf) {
        $errorItemAfter = Get-Item -LiteralPath $sysprepErrorLog
        $errorLengthAfter = $errorItemAfter.Length
        $errorHashAfter = (Get-FileHash -LiteralPath $sysprepErrorLog `
            -Algorithm SHA256).Hash
    }
    $newErrorWritten = $errorLengthAfter -gt 0 -and
        $errorHashAfter -cne $errorHashBefore
    if ($process.ExitCode -ne 0 -or $newErrorWritten) {
        $exitCode = 30
        Write-SysprepErrorTail -LogPath $logPaths
        throw ("Sysprep 验证失败：退出码={0}，setuperr 已更新={1}" -f
            $process.ExitCode, $newErrorWritten)
    }

    $exitCode = 0
    Write-RepairLog -Level OK -Message 'Sysprep 已接受任务，等待 Windows 自动关机。'
} catch {
    if ($exitCode -eq 0) {
        $exitCode = 30
    }
    $logPaths = @(Get-SysprepLogPaths)
    if ($null -ne $reportDirectory -and $logPaths.Count -gt 0) {
        Copy-SysprepLogs -LogPath $logPaths -ReportDirectory $reportDirectory `
            -Phase 'after'
    }
    Write-RepairLog -Level ERROR -Message $_.Exception.Message
} finally {
    Try-ExportRepairReport -ReportDirectory $reportDirectory `
        -DestinationRoot $ExportDirectory
}

exit $exitCode
