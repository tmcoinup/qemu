#Requires -Version 5.1

<#
.SYNOPSIS
  协调 NVIDIA NVAPI 与 AMD ADL 系统读取层的跨组件事务。

.DESCRIPTION
  Install 会先对两套 payload、PE 架构、固定摘要和全部五个系统目标执行只读
  Preflight。只有两者都通过后才依次 Prepare；任一 Prepare 失败会反向回滚所有
  已尝试组件。正式 apply 链传入 identity 的同一大写 GUID 并使用 DeferFinalize，
  由 identity pointer 提交/回滚顺序裁决两个 reader receipt。
#>

[CmdletBinding()]
param(
    [string]$PayloadDir = '',
    [ValidateSet('Preflight', 'Install', 'Recover', 'Finalize', 'Rollback')]
    [string]$Action = 'Install',
    [string]$TransactionId = '',
    [switch]$DeferFinalize
)

$ErrorActionPreference = 'Stop'
$powershellExe = Join-Path $PSHOME 'powershell.exe'
$nvapiInstaller = Join-Path $PSScriptRoot 'install-nvapi-system.ps1'
$adlInstaller = Join-Path $PSScriptRoot 'install-adl-system.ps1'

function Assert-GpuApiTransactionId {
    param([Parameter(Mandatory = $true)][string]$Value)

    if ($Value -cnotmatch '\A[0-9A-F]{32}\z') {
        throw ('GPU API TransactionId 非法：' + $Value)
    }
}

function Assert-GpuApiPlainFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or
        (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw ('GPU API reservation 拒绝目录或重解析点：' + $Path)
    }
    return $item
}

function Assert-GpuApiPlainDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or
        (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw ('GPU API reservation 拒绝非普通目录或重解析点：' + $Path)
    }
}

function Initialize-GpuApiReservationDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        $null = [IO.Directory]::CreateDirectory($Path)
    }
    Assert-GpuApiPlainDirectory -Path $Path
}

function Initialize-GpuApiNativeMove {
    if ($null -ne ('VmateGpuApiNativeMethods' -as [type])) { return }
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class VmateGpuApiNativeMethods {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern bool MoveFileEx(string source, string destination, uint flags);
}
"@
}

function Move-GpuApiReservationFile {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        [IO.File]::Move($Source, $Destination)
        return
    }
    Initialize-GpuApiNativeMove
    if (-not [VmateGpuApiNativeMethods]::MoveFileEx($Source, $Destination, [uint32]8)) {
        $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw (New-Object ComponentModel.Win32Exception($code,
            ('GPU API reservation Move 失败：' + $Source + ' -> ' + $Destination)))
    }
}

function Remove-GpuApiReservationFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return }
    $null = Assert-GpuApiPlainFile -Path $Path
    Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
}

function Read-GpuApiReservation {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $item = Assert-GpuApiPlainFile -Path $Path
    if ($item.Length -lt 33 -or $item.Length -gt 64) {
        throw ('GPU API reservation 大小非法：' + $Path)
    }
    $contents = [IO.File]::ReadAllText($Path, (New-Object Text.UTF8Encoding($false)))
    if ($contents -cnotmatch '\A([0-9A-F]{32})\n\z') {
        throw ('GPU API reservation 内容非法：' + $Path)
    }
    return $matches[1]
}

function New-GpuApiReservation {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$TransactionId
    )

    Assert-GpuApiTransactionId $TransactionId
    $existing = Read-GpuApiReservation -Path $Path
    if ($null -ne $existing) {
        throw ('GPU API reservation 已由事务占用：' + $existing)
    }
    $directory = Split-Path -Parent $Path
    $temporary = Join-Path $directory ('.active.tmp-' + [Guid]::NewGuid().ToString('N'))
    try {
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($TransactionId + "`n")
        $stream = New-Object IO.FileStream($temporary, [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        } finally { $stream.Dispose() }
        Move-GpuApiReservationFile -Source $temporary -Destination $Path
    } finally {
        Remove-GpuApiReservationFile -Path $temporary
    }
}

function Assert-GpuApiReservationOwner {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$TransactionId
    )

    Assert-GpuApiTransactionId $TransactionId
    $owner = Read-GpuApiReservation -Path $Path
    if ($null -eq $owner) { throw 'GPU API reservation 不存在；请先 Recover 或重新 Prepare' }
    if ($owner -cne $TransactionId) {
        throw ('GPU API reservation 属于另一事务：' + $owner)
    }
}

function Remove-GpuApiReservation {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$TransactionId
    )

    Assert-GpuApiReservationOwner -Path $Path -TransactionId $TransactionId
    Remove-GpuApiReservationFile -Path $Path
}

function Open-GpuApiCoordinatorLock {
    param([Parameter(Mandatory = $true)][string]$Directory)

    $path = Join-Path $Directory '.coordinator.lock'
    try {
        $lock = New-Object IO.FileStream($path, [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch {
        throw ('另一个 GPU API coordinator 正在运行：' + $_.Exception.Message)
    }
    try {
        $null = Assert-GpuApiPlainFile -Path $path
        return $lock
    } catch {
        $lock.Dispose()
        throw
    }
}

function Get-GpuApiCurrentIdentityToken {
    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        [Microsoft.Win32.RegistryView]::Registry64)
    $key = $null
    try {
        $key = $baseKey.OpenSubKey('SOFTWARE\StealthGPU', $false)
        if ($null -eq $key -or -not (@($key.GetValueNames()) -ccontains 'CurrentIdentity')) {
            return ''
        }
        if ($key.GetValueKind('CurrentIdentity') -ne
            [Microsoft.Win32.RegistryValueKind]::String) {
            throw 'CurrentIdentity 注册表类型非法'
        }
        $value = [string]$key.GetValue('CurrentIdentity', $null,
            [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        Assert-GpuApiTransactionId $value
        return $value
    } finally {
        if ($null -ne $key) { $key.Dispose() }
        $baseKey.Dispose()
    }
}

function Get-GpuApiReservationDirectory {
    $programData = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::CommonApplicationData)
    if ([string]::IsNullOrWhiteSpace($programData)) {
        throw 'GPU API reservation 的 ProgramData 为空'
    }
    Assert-GpuApiPlainDirectory -Path $programData
    $stealthRoot = Join-Path $programData 'StealthGPU'
    Initialize-GpuApiReservationDirectory -Path $stealthRoot
    $directory = Join-Path $stealthRoot 'GpuApiTransactions'
    Initialize-GpuApiReservationDirectory -Path $directory
    return $directory
}

function Assert-GpuApiCoordinatorFiles {
    $required = @(
        $nvapiInstaller,
        (Join-Path $PSScriptRoot 'nvapi-system-transaction.ps1'),
        $adlInstaller,
        (Join-Path $PSScriptRoot 'adl-system-transaction.ps1')
    )
    if ($Action -eq 'Install' -or $Action -eq 'Preflight') {
        if ([string]::IsNullOrWhiteSpace($PayloadDir)) {
            throw ($Action + ' 缺少 -PayloadDir')
        }
        $required += @(
            (Join-Path $PayloadDir 'nvapi.dll'),
            (Join-Path $PayloadDir 'nvapi64.dll'),
            (Join-Path $PayloadDir 'atiadlxy.dll'),
            (Join-Path $PayloadDir 'atiadlxx32.dll'),
            (Join-Path $PayloadDir 'atiadlxx.dll')
        )
    }
    $missing = $required | Where-Object {
        -not (Test-Path -LiteralPath $_ -PathType Leaf)
    } | Select-Object -First 1
    if ($missing) { throw ('GPU API payload 不完整：' + $missing) }
}

function Invoke-GpuApiInstaller {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$Script,
        [Parameter(Mandatory = $true)][string]$ChildAction,
        [switch]$WithPayload,
        [switch]$Deferred
    )

    $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $Script, '-Action', $ChildAction)
    if ($WithPayload) { $arguments += @('-PayloadDir', $PayloadDir) }
    if (-not [string]::IsNullOrWhiteSpace($TransactionId)) {
        $arguments += @('-TransactionId', $TransactionId)
    }
    if ($Deferred) { $arguments += '-DeferFinalize' }
    & $powershellExe @arguments | Out-Host
    $exitCode = [int]$LASTEXITCODE
    if ($exitCode -ne 0) {
        throw ($Label + ' ' + $ChildAction + ' 失败，退出码=' + $exitCode)
    }
}

function Invoke-GpuApiSteps {
    # 聚合两个组件错误，避免第一个异常遮蔽第二个组件需要收口的状态。
    param(
        [Parameter(Mandatory = $true)][object[]]$Steps,
        [Parameter(Mandatory = $true)][string]$FailurePrefix
    )

    $errors = New-Object Collections.Generic.List[string]
    foreach ($step in $Steps) {
        try {
            Invoke-GpuApiInstaller -Label $step.Label -Script $step.Script `
                -ChildAction $step.Action -WithPayload:$step.WithPayload `
                -Deferred:$step.Deferred
        } catch {
            $errors.Add($_.Exception.Message)
        }
    }
    if ($errors.Count -gt 0) {
        throw ($FailurePrefix + '：' + ($errors -join ' | '))
    }
}

function Resolve-GpuApiReservation {
    param(
        [Parameter(Mandatory = $true)][string]$ReservationPath,
        [Parameter(Mandatory = $true)][object[]]$Forward,
        [Parameter(Mandatory = $true)][object[]]$Reverse
    )

    # reservation 是跨进程的唯一 owner。只在 identity pointer 已指向它时 Finalize；
    # 其余中断点一律 Rollback，再由调用方清理更早版本遗留的孤儿 receipt。
    $leasedTransactionId = Read-GpuApiReservation -Path $ReservationPath
    if ($null -eq $leasedTransactionId) { return $null }
    $currentIdentity = Get-GpuApiCurrentIdentityToken
    $settlementAction = if ($currentIdentity -ceq $leasedTransactionId) {
        'Finalize'
    } else {
        'Rollback'
    }
    $ordered = if ($settlementAction -eq 'Rollback') { $Reverse } else { $Forward }
    $settlementSteps = @($ordered | ForEach-Object {
        [pscustomobject]@{
            Label=$_.Label; Script=$_.Script; Action=$settlementAction
            WithPayload=$false; Deferred=$false
        }
    })
    Invoke-GpuApiSteps $settlementSteps ('GPU API reservation ' +
        $settlementAction + ' 失败')
    Remove-GpuApiReservation -Path $ReservationPath -TransactionId $leasedTransactionId
    return [pscustomobject]@{
        TransactionId=$leasedTransactionId; Action=$settlementAction
    }
}

if ($Action -ne 'Install' -and $DeferFinalize) {
    throw '-DeferFinalize 只允许与 -Action Install 一起使用'
}
Assert-GpuApiCoordinatorFiles

$forward = @(
    [pscustomobject]@{ Label='NVAPI'; Script=$nvapiInstaller },
    [pscustomobject]@{ Label='ADL'; Script=$adlInstaller }
)
$reverse = @($forward[1], $forward[0])

if ($Action -eq 'Install' -and [string]::IsNullOrWhiteSpace($TransactionId)) {
    if ($DeferFinalize) {
        throw 'deferred GPU API Install 必须复用 identity TransactionId'
    }
    $TransactionId = [Guid]::NewGuid().ToString('N').ToUpperInvariant()
}
if ($Action -eq 'Install' -or $Action -eq 'Finalize' -or $Action -eq 'Rollback') {
    Assert-GpuApiTransactionId $TransactionId
}

if ($Action -eq 'Preflight') {
    # 关键跨组件门禁：两个 Preflight 都是只读分支；这里返回前没有任何 DLL Move。
    $preflightSteps = @($forward | ForEach-Object {
        [pscustomobject]@{
            Label=$_.Label; Script=$_.Script; Action='Preflight'
            WithPayload=$true; Deferred=$false
        }
    })
    Invoke-GpuApiSteps $preflightSteps 'GPU API 全量只读预检失败'
    Write-Host 'NVAPI + ADL 全量只读预检通过。' -ForegroundColor Green
    return
}

$reservationDirectory = Get-GpuApiReservationDirectory
$reservationPath = Join-Path $reservationDirectory 'active'
$coordinatorLock = Open-GpuApiCoordinatorLock -Directory $reservationDirectory
try {
    if ($Action -eq 'Install') {
        # reservation 在首个 reader Preflight 前落盘，并跨越 DeferFinalize 的进程边界。
        # 因此另一个 identity 事务既不能复用当前 DLL，也不能在旧事务回滚时被误删除。
        New-GpuApiReservation -Path $reservationPath -TransactionId $TransactionId
        try {
            $preflightSteps = @($forward | ForEach-Object {
                [pscustomobject]@{
                    Label=$_.Label; Script=$_.Script; Action='Preflight'
                    WithPayload=$true; Deferred=$false
                }
            })
            Invoke-GpuApiSteps $preflightSteps 'GPU API 全量只读预检失败'
        } catch {
            $preflightError = $_.Exception
            try {
                Remove-GpuApiReservation -Path $reservationPath -TransactionId $TransactionId
            } catch {
                throw ('GPU API 预检失败且 reservation 清理失败：' +
                    $preflightError.Message + '；' + $_.Exception.Message)
            }
            throw $preflightError
        }

        $attempted = New-Object Collections.Generic.List[object]
        $prepareError = $null
        foreach ($component in $forward) {
            $attempted.Add($component)
            try {
                Invoke-GpuApiInstaller -Label $component.Label -Script $component.Script `
                    -ChildAction 'Install' -WithPayload -Deferred
            } catch {
                $prepareError = $_.Exception
                break
            }
        }
        if ($null -ne $prepareError) {
            $rollbackErrors = New-Object Collections.Generic.List[string]
            for ($index = $attempted.Count - 1; $index -ge 0; $index--) {
                $component = $attempted[$index]
                try {
                    Invoke-GpuApiInstaller -Label $component.Label -Script $component.Script `
                        -ChildAction 'Rollback'
                } catch { $rollbackErrors.Add($_.Exception.Message) }
            }
            if ($rollbackErrors.Count -eq 0) {
                try {
                    Remove-GpuApiReservation -Path $reservationPath -TransactionId $TransactionId
                } catch { $rollbackErrors.Add('reservation 清理失败：' + $_.Exception.Message) }
            }
            $message = 'GPU API Prepare 失败：' + $prepareError.Message
            if ($rollbackErrors.Count -gt 0) {
                $message += '；reader 回滚也失败：' + ($rollbackErrors -join ' | ')
            }
            throw $message
        }
        if ($DeferFinalize) {
            Write-Host ('NVAPI + ADL 已 Prepare，reservation 保持至 identity 收口：' +
                $TransactionId) -ForegroundColor Green
            return
        }
        $Action = 'Finalize'
    } else {
        if ($Action -eq 'Finalize' -or $Action -eq 'Rollback') {
            Assert-GpuApiReservationOwner -Path $reservationPath -TransactionId $TransactionId
        }
    }

    if ($Action -eq 'Finalize' -or $Action -eq 'Rollback') {
        $ordered = if ($Action -eq 'Rollback') { $reverse } else { $forward }
        $steps = @($ordered | ForEach-Object {
            [pscustomobject]@{
                Label=$_.Label; Script=$_.Script; Action=$Action
                WithPayload=$false; Deferred=$false
            }
        })
        Invoke-GpuApiSteps $steps ('GPU API ' + $Action + ' 收口失败')
        Remove-GpuApiReservation -Path $reservationPath -TransactionId $TransactionId
        Write-Host ('GPU API ' + $Action + ' 已收口：' + $TransactionId) `
            -ForegroundColor Green
        return
    }

    if ($Action -eq 'Recover') {
        $reservationResolution = Resolve-GpuApiReservation -ReservationPath $reservationPath `
            -Forward $forward -Reverse $reverse
        if ($null -ne $reservationResolution) {
            Write-Host ('GPU API stale reservation 已' + $reservationResolution.Action + '：' +
                $reservationResolution.TransactionId) -ForegroundColor Yellow
        }
        $steps = @($forward | ForEach-Object {
            [pscustomobject]@{
                Label=$_.Label; Script=$_.Script; Action='Recover'
                WithPayload=$false; Deferred=$false
            }
        })
        Invoke-GpuApiSteps $steps 'GPU API durable recovery 失败'
        Write-Host 'NVAPI + ADL durable recovery completed.' -ForegroundColor Green
    }
} finally {
    $coordinatorLock.Dispose()
}
