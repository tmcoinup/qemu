#Requires -Version 5.1

<#
.SYNOPSIS
  AMD ADL 三目标系统投影与互斥移除的持久收据、崩溃恢复状态机。

.DESCRIPTION
  本文件由 install-adl-system.ps1 在定义摘要、PE 与普通文件校验函数后载入。
  receipt 必须在第一个系统目录 Move 前写穿落盘，并完整记录 DesiredState 与三个
  目标的 Target/Stage/Backup/Discard。恢复只接受规范路径和精确项目摘要；Absent
  事务也不会把未知或真实 AMD DLL 当作 VMate 历史发布物处理。
#>

function Assert-AdlTransactionId {
    param([Parameter(Mandatory = $true)][string]$Value)

    # 与 GPU identity writer 共用无连字符大写 GUID，阻断路径参数注入。
    if ($Value -cnotmatch '\A[0-9A-F]{32}\z') {
        throw ('ADL TransactionId 非法：' + $Value)
    }
}

function Initialize-AdlNativeMove {
    # WRITE_THROUGH 让目录项改名在 API 返回前请求落盘，覆盖突然断电恢复边界。
    if ($null -ne ('VmateAdlNativeMethods' -as [type])) { return }
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class VmateAdlNativeMethods {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern bool MoveFileEx(string source, string destination, uint flags);
}
"@
}

function Move-AdlFileWriteThrough {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        # Linux 只用于纯文件状态机测试；生产入口会强制 64 位 Windows。
        [IO.File]::Move($Source, $Destination)
        return
    }
    Initialize-AdlNativeMove
    if (-not [VmateAdlNativeMethods]::MoveFileEx($Source, $Destination, [uint32]8)) {
        $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw (New-Object ComponentModel.Win32Exception($code,
            ('ADL write-through Move 失败：' + $Source + ' -> ' + $Destination)))
    }
}

function Sync-AdlFileData {
    param([Parameter(Mandatory = $true)][string]$Path)

    $null = Assert-PlainFile -Path $Path
    $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Open,
        [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
    try { $stream.Flush($true) } finally { $stream.Dispose() }
}

function Test-AdlTransactionPath {
    param(
        [string]$Path,
        [string]$Directory,
        [string]$FileName,
        [ValidateSet('stage', 'backup', 'rollback')][string]$Kind
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        $sameDirectory = [StringComparer]::OrdinalIgnoreCase.Equals(
            [IO.Path]::GetFullPath([IO.Path]::GetDirectoryName($Path)),
            [IO.Path]::GetFullPath($Directory))
    } catch { return $false }
    $leaf = [IO.Path]::GetFileName($Path)
    $pattern = '^\.' + [Regex]::Escape($FileName) + '\.vmate-' +
        [Regex]::Escape($Kind) + '-[0-9a-f]{32}$'
    return $sameDirectory -and $leaf -cmatch $pattern
}

function Get-AdlOptionalFileHash {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or
        -not (Test-Path -LiteralPath $Path)) { return '' }
    $null = Assert-PlainFile -Path $Path
    return Get-LowerSha256 -Path $Path
}

function Test-AdlRetryableDeleteError {
    param([Parameter(Mandatory = $true)]$ErrorRecord)

    # Windows 分别用 AccessDenied(5) 和 SharingViolation(32) 表示 ACL 拒绝或
    # image section 仍被映射；CleanupDeferred 只接受这两个原生错误码。
    $exception = $ErrorRecord.Exception
    while ($null -ne $exception) {
        $nativeCode = if ($exception -is [ComponentModel.Win32Exception]) {
            $exception.NativeErrorCode
        } else { $exception.HResult -band 0xFFFF }
        if ($nativeCode -eq 5 -or $nativeCode -eq 32) { return $true }
        $exception = $exception.InnerException
    }
    return $false
}

function Assert-AdlManagedBackupFile {
    param([Parameter(Mandatory = $true)]$Entry)

    # 延迟清理只授权收据中目标同目录的规范 backup，且 ObservedHash 必须来自
    # 当前或历史项目发布清单；不能把未知的真实 AMD DLL 纳入托管删除范围。
    if (-not (Test-AdlTransactionPath $Entry.Backup $Entry.Directory `
            $Entry.FileName 'backup')) {
        throw ('ADL 托管备份路径非法：' + [string]$Entry.Backup)
    }
    $allowedHashes = @([string]$Entry.ExpectedHash) + @($Entry.HistoricalHashes)
    if (-not (Test-HashInAllowList ([string]$Entry.ObservedHash) $allowedHashes)) {
        throw ('ADL 托管备份摘要未被发布清单授权：' + [string]$Entry.Backup)
    }
    if (-not (Test-Path -LiteralPath $Entry.Backup)) { return $false }
    $null = Assert-PlainFile -Path $Entry.Backup
    if ((Get-LowerSha256 -Path $Entry.Backup) -cne [string]$Entry.ObservedHash) {
        throw ('ADL 托管备份摘要不匹配：' + [string]$Entry.Backup)
    }
    return $true
}

function Remove-AdlManagedBackupFile {
    param([Parameter(Mandatory = $true)]$Entry)

    if (-not (Assert-AdlManagedBackupFile -Entry $Entry)) { return $false }
    try {
        Remove-TransactionFile -Path $Entry.Backup
        return $false
    } catch {
        if (-not (Test-AdlRetryableDeleteError $_)) { throw }
    }

    # 删除失败后必须再次验证文件类型与精确摘要；若并发消失视为已完成，
    # 若字节或类型变化则硬失败，绝不把路径交给不受收据约束的延迟删除。
    if (-not (Assert-AdlManagedBackupFile -Entry $Entry)) { return $false }
    return $true
}

function Test-AdlCleanupDeferredError {
    param([Parameter(Mandatory = $true)]$ErrorRecord)

    $exception = $ErrorRecord.Exception
    while ($null -ne $exception) {
        if ($exception.Data.Contains('VmateAdlCleanupDeferred') -and
            [bool]$exception.Data['VmateAdlCleanupDeferred']) { return $true }
        $exception = $exception.InnerException
    }
    return $false
}

function Undo-AdlProjectionEntry {
    param([Parameter(Mandatory = $true)]$Entry)

    $targetHash = Get-AdlOptionalFileHash $Entry.Target
    $backupHash = Get-AdlOptionalFileHash $Entry.Backup
    $discardHash = Get-AdlOptionalFileHash $Entry.Discard
    if ([string]$Entry.DesiredState -ceq 'Absent') {
        # 原快照为缺失时，事务没有权限删除之后由 AMD 软件或其他进程创建的文件。
        # 发现并发变化应保留目标并停止收口，不能为了幂等而扩大删除范围。
        if ($Entry.CommitAction -ceq 'UnchangedAbsent') {
            if ($targetHash -or $backupHash -or $discardHash) {
                throw ('UnchangedAbsent ADL 目标在事务中发生变化：' + $Entry.Target)
            }
            return
        }
        if ($Entry.CommitAction -cne 'Removed') {
            throw ('Absent ADL 回滚动作非法：' + $Entry.CommitAction)
        }

        # Removed 只允许恢复收据精确记录的项目托管摘要。若同名目标已被重新创建，
        # 一律不覆盖、不删除，保留 backup 与 receipt 供诊断。
        if ($targetHash -ceq $Entry.ObservedHash -and -not $backupHash -and
            -not $discardHash) {
            return
        }
        if (-not $targetHash -and $backupHash -ceq $Entry.ObservedHash -and
            -not $discardHash) {
            Move-AdlFileWriteThrough $Entry.Backup $Entry.Target
            if ((Get-AdlOptionalFileHash $Entry.Target) -cne $Entry.ObservedHash) {
                throw ('Removed ADL rollback 恢复摘要非法：' + $Entry.Target)
            }
            return
        }
        throw ('Removed ADL 回滚状态非法，拒绝触碰未知目标：' + $Entry.Target)
    }
    if ($Entry.CommitAction -eq '') {
        if ($targetHash -cne $Entry.ExpectedHash) {
            throw ('Unchanged ADL 目标在事务中发生变化：' + $Entry.Target)
        }
        return
    }
    if ($Entry.CommitAction -eq 'Created') {
        if ($targetHash -ceq $Entry.ExpectedHash -and -not $discardHash) {
            Move-AdlFileWriteThrough $Entry.Target $Entry.Discard
            $targetHash = ''
            $discardHash = Get-AdlOptionalFileHash $Entry.Discard
        }
        if (-not $targetHash -and $discardHash -ceq $Entry.ExpectedHash) {
            Remove-TransactionFile -Path $Entry.Discard
            return
        }
        if (-not $targetHash -and -not $discardHash) { return }
        throw ('Created ADL 回滚状态非法：' + $Entry.Target)
    }
    if ($Entry.CommitAction -ne 'Replaced') {
        throw ('ADL 回滚动作非法：' + $Entry.CommitAction)
    }

    # 仅接受旧目标、旧目标已分离、新目标已提交或回滚中断这四类精确状态。
    if ($targetHash -ceq $Entry.ObservedHash -and -not $backupHash) {
        if ($discardHash -and $discardHash -cne $Entry.ExpectedHash) {
            throw ('ADL discard 摘要非法：' + $Entry.Discard)
        }
        Remove-TransactionFile -Path $Entry.Discard
        return
    }
    if (-not $targetHash -and $backupHash -ceq $Entry.ObservedHash -and
        (-not $discardHash -or $discardHash -ceq $Entry.ExpectedHash)) {
        Move-AdlFileWriteThrough $Entry.Backup $Entry.Target
        Remove-TransactionFile -Path $Entry.Discard
        return
    }
    if ($targetHash -ceq $Entry.ExpectedHash -and
        $backupHash -ceq $Entry.ObservedHash -and -not $discardHash) {
        Move-AdlFileWriteThrough $Entry.Target $Entry.Discard
        if ((Get-AdlOptionalFileHash $Entry.Discard) -cne $Entry.ExpectedHash) {
            throw ('ADL rollback detach 摘要非法：' + $Entry.Discard)
        }
        Move-AdlFileWriteThrough $Entry.Backup $Entry.Target
        Remove-TransactionFile -Path $Entry.Discard
        return
    }
    throw ('Replaced ADL 回滚状态非法：' + $Entry.Target)
}

function Write-AdlProjectionReceipt {
    param([object[]]$Entries, [string]$Path, [string]$TransactionId)

    Assert-AdlTransactionId $TransactionId
    if (Test-Path -LiteralPath $Path) { throw ('ADL 收据已存在：' + $Path) }
    $desiredStates = @($Entries | ForEach-Object {
        $value = [string]$_.DesiredState
        if ([string]::IsNullOrWhiteSpace($value)) { 'Present' } else { $value }
    } | Select-Object -Unique)
    if ($desiredStates.Count -ne 1 -or
        -not (@('Present', 'Absent') -ccontains [string]$desiredStates[0])) {
        throw 'ADL 收据 DesiredState 非法或条目不一致'
    }
    $desiredState = [string]$desiredStates[0]
    $records = @($Entries | ForEach-Object {
        $action = if ([string]$_.CommitAction) {
            [string]$_.CommitAction
        } elseif ($desiredState -ceq 'Absent') {
            'UnchangedAbsent'
        } else {
            'Unchanged'
        }
        [ordered]@{
            FileName=[string]$_.FileName; Target=[string]$_.Target
            ExpectedHash=[string]$_.ExpectedHash; PreviousHash=[string]$_.ObservedHash
            Action=$action
            Stage=[string]$_.Stage; Backup=[string]$_.Backup; Discard=[string]$_.Discard
        }
    })
    $document = [ordered]@{
        SchemaVersion=2; TransactionId=$TransactionId
        DesiredState=$desiredState; Entries=$records
    }
    $temporary = $Path + '.tmp-' + [Guid]::NewGuid().ToString('N')
    try {
        $encoding = New-Object Text.UTF8Encoding($false)
        $bytes = $encoding.GetBytes(($document | ConvertTo-Json -Depth 4))
        $stream = New-Object IO.FileStream($temporary, [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        } finally { $stream.Dispose() }
        Move-AdlFileWriteThrough $temporary $Path
    } finally { Remove-TransactionFile -Path $temporary }
}

function Read-AdlProjectionReceipt {
    param([object[]]$Entries, [string]$Path, [string]$TransactionId)

    Assert-AdlTransactionId $TransactionId
    $item = Assert-PlainFile -Path $Path
    if ($item.Length -lt 32 -or $item.Length -gt 64KB) { throw 'ADL 收据大小非法' }
    $document = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    $records = @($document.Entries)
    $schemaVersion = [int]$document.SchemaVersion
    if (-not (@(1, 2) -contains $schemaVersion) -or
        [string]$document.TransactionId -cne $TransactionId -or
        $records.Count -ne $Entries.Count) { throw 'ADL 收据头或条目数非法' }
    # schema-1 永远代表历史 Present 投影；只有 schema-2 才允许声明 Absent。
    # 旧收据不会因兼容解析而获得删除权限。
    $desiredState = if ($schemaVersion -eq 1) {
        'Present'
    } else {
        [string]$document.DesiredState
    }
    if (-not (@('Present', 'Absent') -ccontains $desiredState)) {
        throw 'ADL 收据 DesiredState 非法'
    }
    for ($index = 0; $index -lt $Entries.Count; $index++) {
        $entry = $Entries[$index]
        $record = $records[$index]
        $sameTarget = [StringComparer]::OrdinalIgnoreCase.Equals(
            [IO.Path]::GetFullPath([string]$record.Target),
            [IO.Path]::GetFullPath([string]$entry.Target))
        $receiptExpected = [string]$record.ExpectedHash
        $allowedExpected = @([string]$entry.ExpectedHash) + @($entry.HistoricalHashes)
        if ([string]$record.FileName -cne [string]$entry.FileName -or
            -not $sameTarget -or
            -not (Test-HashInAllowList $receiptExpected $allowedExpected)) {
            throw ('ADL 收据目标或发布摘要不匹配：' + $entry.FileName)
        }
        if ($entry.PSObject.Properties.Name -contains 'DesiredState') {
            $entry.DesiredState = $desiredState
        } else {
            # 兼容旧测试/调用方构造的 entry，只补充状态字段，不修改路径与摘要集合。
            $entry | Add-Member -NotePropertyName DesiredState `
                -NotePropertyValue $desiredState
        }
        $entry.ExpectedHash = $receiptExpected
        $action = [string]$record.Action
        $previous = [string]$record.PreviousHash
        $stage = [string]$record.Stage
        $backup = [string]$record.Backup
        $discard = [string]$record.Discard
        if ($desiredState -ceq 'Absent') {
            if ($action -ceq 'UnchangedAbsent') {
                if ($previous -or $stage -or $backup -or $discard) {
                    throw ('ADL UnchangedAbsent 收据非法：' + $entry.FileName)
                }
                $entry.CommitAction = 'UnchangedAbsent'
            } elseif ($action -ceq 'Removed') {
                if (-not (Test-HashInAllowList $previous $allowedExpected) -or
                    $stage -or $discard -or
                    -not (Test-AdlTransactionPath $backup $entry.Directory `
                        $entry.FileName 'backup')) {
                    throw ('ADL Removed 收据非法：' + $entry.FileName)
                }
                $entry.CommitAction = 'Removed'
            } else {
                throw ('Absent ADL 收据动作非法：' + $action)
            }
        } elseif ($action -eq 'Unchanged') {
            if ($previous -cne $receiptExpected -or $stage -or $backup -or $discard) {
                throw ('ADL Unchanged 收据非法：' + $entry.FileName)
            }
            $entry.CommitAction = ''
        } elseif ($action -eq 'Created') {
            if ($previous -or $backup -or
                -not (Test-AdlTransactionPath $stage $entry.Directory $entry.FileName 'stage') -or
                -not (Test-AdlTransactionPath $discard $entry.Directory $entry.FileName 'rollback')) {
                throw ('ADL Created 收据非法：' + $entry.FileName)
            }
            $entry.CommitAction = 'Created'
        } elseif ($action -eq 'Replaced') {
            if ($previous -ceq $receiptExpected -or
                -not (Test-HashInAllowList $previous $entry.HistoricalHashes) -or
                -not (Test-AdlTransactionPath $stage $entry.Directory $entry.FileName 'stage') -or
                -not (Test-AdlTransactionPath $backup $entry.Directory $entry.FileName 'backup') -or
                -not (Test-AdlTransactionPath $discard $entry.Directory $entry.FileName 'rollback')) {
                throw ('ADL Replaced 收据非法：' + $entry.FileName)
            }
            $entry.CommitAction = 'Replaced'
        } else {
            throw ('ADL 收据动作非法：' + $action)
        }
        $entry.ObservedHash = $previous
        $entry.Stage = $stage
        $entry.Backup = $backup
        $entry.Discard = $discard
    }
    return $Entries
}

function Finalize-AdlProjectionReceipt {
    param([object[]]$Entries, [string]$Path, [string]$TransactionId)

    $resolved = @(Read-AdlProjectionReceipt $Entries $Path $TransactionId)
    foreach ($entry in $resolved) {
        if ([string]$entry.DesiredState -ceq 'Absent') {
            # 新出现的同名文件可能属于真实 AMD 软件；Finalize 不拥有它，必须保留
            # 目标并失败，让收据继续存在，而不是静默扩大清理范围。
            if (Get-AdlOptionalFileHash $entry.Target) {
                throw ('Absent ADL Finalize 发现目标重新出现：' + $entry.Target)
            }
            if ($entry.CommitAction -ceq 'Removed') {
                $removedBackupHash = Get-AdlOptionalFileHash $entry.Backup
                # backup 已删而 receipt 尚存是合法的 Finalize 中断点；只在 backup
                # 仍存在时要求精确摘要，随后即可幂等清理收据。
                if ($removedBackupHash -and
                    $removedBackupHash -cne $entry.ObservedHash) {
                    throw ('Removed ADL Finalize 备份摘要不匹配：' + $entry.Backup)
                }
                $null = Assert-AdlManagedBackupFile -Entry $entry
            }
            continue
        }
        Assert-AdlBinary $entry.Target $entry.ExpectedHash $entry.Machine $entry.Magic
        if (-not [string]::IsNullOrWhiteSpace([string]$entry.Discard) -and
            (Test-Path -LiteralPath $entry.Discard)) {
            throw ('ADL Finalize 发现未完成 rollback discard：' + $entry.Discard)
        }
        if ($entry.CommitAction -ceq 'Replaced') {
            $null = Assert-AdlManagedBackupFile -Entry $entry
        }
    }
    $cleanupDeferred = New-Object Collections.Generic.List[string]
    $cleanupErrors = New-Object Collections.Generic.List[string]
    foreach ($entry in $resolved) {
        try { Remove-TransactionFile -Path $entry.Stage } catch {
            $cleanupErrors.Add($_.Exception.Message)
        }
        if ([string]$entry.DesiredState -ceq 'Absent') {
            if ($entry.CommitAction -ceq 'Removed') {
                try {
                    if (Remove-AdlManagedBackupFile -Entry $entry) {
                        $cleanupDeferred.Add([string]$entry.Backup)
                    }
                } catch { $cleanupErrors.Add($_.Exception.Message) }
            }
            continue
        }
        if ($entry.CommitAction -ne 'Replaced' -or
            -not (Test-Path -LiteralPath $entry.Backup)) { continue }
        try {
            if (Remove-AdlManagedBackupFile -Entry $entry) {
                $cleanupDeferred.Add([string]$entry.Backup)
            }
        } catch { $cleanupErrors.Add($_.Exception.Message) }
    }
    if ($cleanupErrors.Count -gt 0) {
        throw ('ADL Finalize 清理失败：' + ($cleanupErrors -join ' | '))
    }
    if ($cleanupDeferred.Count -gt 0) {
        $exception = New-Object IO.IOException(
            ('ADL 托管备份仍被占用，需重启后继续清理：' +
                ($cleanupDeferred -join ', ')))
        $exception.Data['VmateAdlCleanupDeferred'] = $true
        throw $exception
    }
    Remove-TransactionFile -Path $Path
}

function Rollback-AdlProjectionReceipt {
    param([object[]]$Entries, [string]$Path, [string]$TransactionId)

    $resolved = @(Read-AdlProjectionReceipt $Entries $Path $TransactionId)
    $errors = New-Object Collections.Generic.List[string]
    for ($index = $resolved.Count - 1; $index -ge 0; $index--) {
        try { Undo-AdlProjectionEntry $resolved[$index] } catch {
            $errors.Add($_.Exception.Message)
        }
        try { Remove-TransactionFile -Path $resolved[$index].Stage } catch {
            $errors.Add($_.Exception.Message)
        }
    }
    if ($errors.Count -gt 0) {
        throw ('ADL 收据回滚失败：' + ($errors -join ' | '))
    }
    Remove-TransactionFile -Path $Path
}

function Resolve-PendingAdlReceipts {
    param([object[]]$Entries, [string]$ReceiptRoot, [string]$CurrentIdentityId)

    foreach ($receipt in @(Get-ChildItem -LiteralPath $ReceiptRoot -Filter '*.json' -File)) {
        $id = [IO.Path]::GetFileNameWithoutExtension($receipt.Name)
        Assert-AdlTransactionId $id
        $receiptEntries = @($Entries | ForEach-Object { $_.PSObject.Copy() })
        if ($id -ceq $CurrentIdentityId) {
            Finalize-AdlProjectionReceipt $receiptEntries $receipt.FullName $id
            Write-Host ('已完成中断的 ADL/identity 事务：' + $id) -ForegroundColor Yellow
        } else {
            Rollback-AdlProjectionReceipt $receiptEntries $receipt.FullName $id
            Write-Host ('已回滚中断的 ADL/identity 事务：' + $id) -ForegroundColor Yellow
        }
    }
}
