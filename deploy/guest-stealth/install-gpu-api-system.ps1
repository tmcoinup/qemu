#Requires -Version 5.1
# 按 staged Vendor 互斥发布 NVAPI/ADL，并用 identity-bound reservation 协调恢复。
[CmdletBinding()]
param(
    [string]$PayloadDir = '',
    [ValidateSet('Preflight', 'Install', 'Recover', 'Finalize', 'Rollback')]
    [string]$Action = 'Install',
    [ValidateSet('Auto', 'NVIDIA', 'AMD')]
    [string]$Vendor = 'Auto',
    [string]$TransactionId = '',
    [switch]$DeferFinalize
)
$ErrorActionPreference = 'Stop'
$Vendor = @{ NVIDIA='NVIDIA'; AMD='AMD'; AUTO='Auto' }[$Vendor.ToUpperInvariant()]
$GpuApiCleanupDeferredExitCode = 12
$powershellExe = Join-Path $PSHOME 'powershell.exe'
$nvapiInstaller = Join-Path $PSScriptRoot 'install-nvapi-system.ps1'
$adlInstaller = Join-Path $PSScriptRoot 'install-adl-system.ps1'
$identityBindingHelper = Join-Path $PSScriptRoot 'gpu-api-identity-binding.ps1'
function Assert-GpuApiTransactionId {
    param([Parameter(Mandatory = $true)][string]$Value)
    if ($Value -cnotmatch '\A[0-9A-F]{32}\z') {
        throw ('GPU API TransactionId 非法：' + $Value)
    }
}
function New-GpuApiCleanupDeferredException {
    param([Parameter(Mandatory = $true)][string]$Message)
    $exception = [InvalidOperationException]::new($Message)
    $exception.Data['VmateGpuApiCleanupDeferred'] = $true
    return $exception
}
function Test-GpuApiCleanupDeferredException {
    param([Parameter(Mandatory = $true)]$Exception)
    while ($null -ne $Exception) {
        if ([bool]$Exception.Data['VmateGpuApiCleanupDeferred']) { return $true }
        $Exception = $Exception.InnerException
    }
    return $false
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
    if ($item.Length -lt 33 -or $item.Length -gt 96) {
        throw ('GPU API reservation 大小非法：' + $Path)
    }
    $contents = [IO.File]::ReadAllText($Path, (New-Object Text.UTF8Encoding($false)))
    if ($contents -cmatch '\A([0-9A-F]{32})\|(NVIDIA|AMD)\n\z') {
        return [pscustomobject]@{
            TransactionId=$matches[1]; Vendor=$matches[2]; IsLegacy=$false
        }
    }
    # schema-1 只有 GUID，来自旧版固定“双厂商都 Present”的事务。
    if ($contents -cmatch '\A([0-9A-F]{32})\n\z') {
        return [pscustomobject]@{
            TransactionId=$matches[1]; Vendor='LegacyBothPresent'; IsLegacy=$true
        }
    }
    throw ('GPU API reservation 内容非法：' + $Path)
}
function New-GpuApiReservation {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$TransactionId,
        [Parameter(Mandatory = $true)]
        [ValidateSet('NVIDIA', 'AMD')][string]$Vendor
    )
    Assert-GpuApiTransactionId $TransactionId; $Vendor = $Vendor.ToUpperInvariant()
    $existing = Read-GpuApiReservation -Path $Path
    if ($null -ne $existing) {
        throw ('GPU API reservation 已由事务占用：' + $existing.TransactionId)
    }
    $directory = Split-Path -Parent $Path
    $temporary = Join-Path $directory ('.active.tmp-' + [Guid]::NewGuid().ToString('N'))
    try {
        $contents = $TransactionId + '|' + $Vendor + "`n"
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($contents)
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
    if ($owner.TransactionId -cne $TransactionId) {
        throw ('GPU API reservation 属于另一事务：' + $owner.TransactionId)
    }
    return $owner
}
function Remove-GpuApiReservation {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$TransactionId
    )
    $null = Assert-GpuApiReservationOwner -Path $Path -TransactionId $TransactionId
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
        $identityBindingHelper,
        $nvapiInstaller,
        (Join-Path $PSScriptRoot 'nvapi-system-validation.ps1'),
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
        [Parameter(Mandatory = $true)]
        [ValidateSet('Present', 'Absent')][string]$DesiredState,
        [string]$ChildTransactionId = '',
        [switch]$WithPayload,
        [switch]$Deferred
    )
    $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $Script, '-Action', $ChildAction, '-DesiredState', $DesiredState)
    if ($WithPayload) { $arguments += @('-PayloadDir', $PayloadDir) }
    $effectiveTransactionId = if ([string]::IsNullOrWhiteSpace($ChildTransactionId)) {
        $TransactionId
    } else { $ChildTransactionId }
    if (-not [string]::IsNullOrWhiteSpace($effectiveTransactionId)) {
        $arguments += @('-TransactionId', $effectiveTransactionId)
    }
    if ($Deferred) { $arguments += '-DeferFinalize' }
    & $powershellExe @arguments | Out-Host
    $exitCode = [int]$LASTEXITCODE
    if ($exitCode -eq $GpuApiCleanupDeferredExitCode -and
        @('Finalize', 'Recover') -ccontains $ChildAction) {
        throw (New-GpuApiCleanupDeferredException ($Label + ' ' + $ChildAction +
            ' 的旧 DLL 清理等待重启释放'))
    }
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
    $cleanupDeferred = $false
    foreach ($step in $Steps) {
        try {
            Invoke-GpuApiInstaller -Label $step.Label -Script $step.Script `
                -ChildAction $step.Action -DesiredState $step.DesiredState `
                -ChildTransactionId ([string]$step.TransactionId) `
                -WithPayload:$step.WithPayload `
                -Deferred:$step.Deferred
        } catch {
            if (Test-GpuApiCleanupDeferredException $_.Exception) {
                $cleanupDeferred = $true
            } else {
                $errors.Add($_.Exception.Message)
            }
        }
    }
    if ($errors.Count -gt 0) {
        throw ($FailurePrefix + '：' + ($errors -join ' | '))
    }
    if ($cleanupDeferred) {
        throw (New-GpuApiCleanupDeferredException ($FailurePrefix +
            '：旧 DLL 清理等待重启释放'))
    }
}
function New-GpuApiVendorPlan {
    param([Parameter(Mandatory = $true)]
        [ValidateSet('NVIDIA', 'AMD', 'LegacyBothPresent')][string]$TargetVendor)
    $TargetVendor = @{ NVIDIA='NVIDIA'; AMD='AMD'; LEGACYBOTHPRESENT='LegacyBothPresent' }[
        $TargetVendor.ToUpperInvariant()]
    $nvapi = [pscustomobject]@{
        Label='NVAPI'; Script=$nvapiInstaller
        DesiredState=if ($TargetVendor -ceq 'AMD') { 'Absent' } else { 'Present' }
        WithPayload=($TargetVendor -cne 'AMD')
    }
    $adl = [pscustomobject]@{
        Label='ADL'; Script=$adlInstaller
        DesiredState=if ($TargetVendor -ceq 'NVIDIA') { 'Absent' } else { 'Present' }
        WithPayload=($TargetVendor -cne 'NVIDIA')
    }
    if ($TargetVendor -ceq 'NVIDIA') { return @($adl, $nvapi) }
    return @($nvapi, $adl)
}
function Resolve-GpuApiReservation {
    param([Parameter(Mandatory = $true)][string]$ReservationPath)
    # pointer 已写但 State 未 Completed 时，必须先由 identity recovery 裁决。
    $lease = Read-GpuApiReservation -Path $ReservationPath
    if ($null -eq $lease) { return $null }
    $leasedTransactionId = [string]$lease.TransactionId
    $forward = @(New-GpuApiVendorPlan -TargetVendor ([string]$lease.Vendor))
    $reverse = @($forward[1], $forward[0])
    $settlementAction = Get-GpuApiIdentitySettlementAction $leasedTransactionId `
        ([string]$lease.Vendor)
    $ordered = if ($settlementAction -eq 'Rollback') { $Reverse } else { $Forward }
    $settlementSteps = @($ordered | ForEach-Object {
        [pscustomobject]@{
            Label=$_.Label; Script=$_.Script; Action=$settlementAction
            DesiredState=$_.DesiredState; WithPayload=$false; Deferred=$false
            TransactionId=$leasedTransactionId
        }
    })
    Invoke-GpuApiSteps $settlementSteps ('GPU API reservation ' +
        $settlementAction + ' 失败')
    Remove-GpuApiReservation -Path $ReservationPath -TransactionId $leasedTransactionId
    return [pscustomobject]@{
        TransactionId=$leasedTransactionId; Action=$settlementAction
        Vendor=[string]$lease.Vendor
    }
}
if ($Action -ne 'Install' -and $DeferFinalize) {
    throw '-DeferFinalize 只允许与 -Action Install 一起使用'
}
Assert-GpuApiCoordinatorFiles
. $identityBindingHelper
$requiresVendor = $Action -eq 'Install' -or $Action -eq 'Preflight'
if ($requiresVendor -and $Vendor -ceq 'Auto') {
    throw ($Action + ' 必须显式传入 -Vendor NVIDIA 或 AMD')
}
if ($Action -eq 'Install') {
    if (-not $DeferFinalize) {
        throw 'GPU API Install 只允许作为 identity-bound deferred 事务运行'
    }
    if ([string]::IsNullOrWhiteSpace($TransactionId)) {
        throw 'deferred GPU API Install 必须复用 identity TransactionId'
    }
    Assert-GpuApiTransactionId $TransactionId
    $Vendor = [string](Assert-GpuApiInstallIdentityBinding `
        -TransactionId $TransactionId -RequestedVendor $Vendor)
}
$planVendor = if ($Vendor -ceq 'Auto') { 'LegacyBothPresent' } else { $Vendor }
$forward = @(New-GpuApiVendorPlan -TargetVendor $planVendor)
$reverse = @($forward[1], $forward[0])
if ($Action -eq 'Install' -or $Action -eq 'Finalize' -or $Action -eq 'Rollback') {
    Assert-GpuApiTransactionId $TransactionId
}
if ($Action -eq 'Preflight') {
    # 关键跨组件门禁：两个 Preflight 都是只读分支；这里返回前没有任何 DLL Move。
    $preflightSteps = @($forward | ForEach-Object {
        [pscustomobject]@{
            Label=$_.Label; Script=$_.Script; Action='Preflight'
            DesiredState=$_.DesiredState; WithPayload=$_.WithPayload; Deferred=$false
        }
    })
    Invoke-GpuApiSteps $preflightSteps 'GPU API 全量只读预检失败'
    Write-Host ($Vendor + ' 厂商互斥计划全量只读预检通过。') -ForegroundColor Green
    return
}
$reservationDirectory = Get-GpuApiReservationDirectory
$reservationPath = Join-Path $reservationDirectory 'active'
$coordinatorLock = Open-GpuApiCoordinatorLock -Directory $reservationDirectory
try {
    if ($Action -eq 'Install') {
        # reservation 在首个 reader Preflight 前落盘，并跨越 DeferFinalize 的进程边界。
        # 因此另一个 identity 事务既不能复用当前 DLL，也不能在旧事务回滚时被误删除。
        New-GpuApiReservation -Path $reservationPath -TransactionId $TransactionId `
            -Vendor $Vendor
        try {
            $preflightSteps = @($forward | ForEach-Object {
                [pscustomobject]@{
                    Label=$_.Label; Script=$_.Script; Action='Preflight'
                    DesiredState=$_.DesiredState; WithPayload=$_.WithPayload; Deferred=$false
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
                    -ChildAction 'Install' -DesiredState $component.DesiredState `
                    -WithPayload:$component.WithPayload -Deferred
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
                        -ChildAction 'Rollback' -DesiredState $component.DesiredState
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
        Write-Host ($Vendor + ' 厂商互斥计划已 Prepare，reservation 保持至 identity 收口：' +
            $TransactionId) -ForegroundColor Green
        return
    } else {
        if ($Action -eq 'Finalize' -or $Action -eq 'Rollback') {
            $lease = Assert-GpuApiReservationOwner -Path $reservationPath `
                -TransactionId $TransactionId
            if ($Vendor -ceq 'Auto') {
                $forward = @(New-GpuApiVendorPlan -TargetVendor ([string]$lease.Vendor))
                $reverse = @($forward[1], $forward[0])
            } elseif ($lease.IsLegacy) {
                throw '旧版双 Present reservation 只允许使用 -Vendor Auto 收口'
            } elseif ($lease.Vendor -cne $Vendor) {
                throw ('GPU API reservation Vendor 不匹配：' + $lease.Vendor)
            }
            $requiredAction = Get-GpuApiIdentitySettlementAction $TransactionId `
                ([string]$lease.Vendor)
            if ($requiredAction -cne $Action) {
                throw ('GPU API ' + $Action + ' 与 identity durable 裁决冲突；只允许 ' +
                    $requiredAction)
            }
        }
    }
    if ($Action -eq 'Finalize' -or $Action -eq 'Rollback') {
        $ordered = if ($Action -eq 'Rollback') { $reverse } else { $forward }
        $steps = @($ordered | ForEach-Object {
            [pscustomobject]@{
                Label=$_.Label; Script=$_.Script; Action=$Action
                DesiredState=$_.DesiredState; WithPayload=$false; Deferred=$false
            }
        })
        Invoke-GpuApiSteps $steps ('GPU API ' + $Action + ' 收口失败')
        Remove-GpuApiReservation -Path $reservationPath -TransactionId $TransactionId
        Write-Host ('GPU API ' + $Action + ' 已收口：' + $TransactionId) `
            -ForegroundColor Green
        return
    }
    if ($Action -eq 'Recover') {
        $reservationResolution = Resolve-GpuApiReservation -ReservationPath $reservationPath
        if ($null -ne $reservationResolution) {
            Write-Host ('GPU API stale reservation 已' + $reservationResolution.Action + '：' +
                $reservationResolution.TransactionId) -ForegroundColor Yellow
        }
        $steps = @($forward | ForEach-Object {
            [pscustomobject]@{
                Label=$_.Label; Script=$_.Script; Action='Recover'
                DesiredState=$_.DesiredState; WithPayload=$false; Deferred=$false
            }
        })
        Invoke-GpuApiSteps $steps 'GPU API durable recovery 失败'
        Write-Host 'GPU API 厂商互斥事务 durable recovery completed.' -ForegroundColor Green
    }
} catch {
    if (Test-GpuApiCleanupDeferredException $_.Exception) {
        Write-Warning 'GPU API 目标状态已提交；旧 DLL 清理等待重启后继续。'
        exit $GpuApiCleanupDeferredExitCode
    }
    throw
} finally {
    $coordinatorLock.Dispose()
}
