#Requires -Version 5.1

<#
.SYNOPSIS
  NVAPI 双架构系统投影与互斥移除的持久收据、崩溃恢复状态机。

.DESCRIPTION
  本文件由 install-nvapi-system.ps1 在载入 nvapi-system-validation.ps1 后载入。
  journal 在第一个系统 DLL Move 前写入，记录 DesiredState 以及 canonical
  Target/Stage/Backup/Discard；因而安装或移除被 kill、断电时，都能仅凭文件存在性
  和精确摘要推断状态，并幂等 Finalize 或 Rollback。Absent 永远只接纳项目摘要。
#>

function Assert-NvapiTransactionId {
    param([Parameter(Mandatory = $true)][string]$Value)

    # 与 identity writer 的无连字符大写 GUID 共用 token，禁止借参数注入路径。
    if ($Value -cnotmatch '\A[0-9A-F]{32}\z') {
        throw ('NVAPI TransactionId 非法：' + $Value)
    }
}

function Initialize-NvapiNativeMove {
    # MoveFileExW + WRITE_THROUGH 是 Windows 对“目录项改名实际落盘后才返回”的公开
    # 契约；普通 File.Move 只保证进程可见原子性，不能覆盖突然断电。
    if ($null -ne ('VmateNvapiNativeMethods' -as [type])) { return }
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class VmateNvapiNativeMethods {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern bool MoveFileEx(string source, string destination, uint flags);
}
"@
}

function Move-NvapiFileWriteThrough {
    param([Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination)

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        # Linux host 的纯文件状态机测试没有 kernel32；生产安装器已在入口强制 Windows。
        [IO.File]::Move($Source, $Destination)
        return
    }
    Initialize-NvapiNativeMove
    if (-not [VmateNvapiNativeMethods]::MoveFileEx($Source, $Destination, [uint32]8)) {
        $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw (New-Object ComponentModel.Win32Exception($code,
            ('NVAPI write-through Move 失败：' + $Source + ' -> ' + $Destination)))
    }
}

function Sync-NvapiFileData {
    param([Parameter(Mandatory = $true)][string]$Path)

    $null = Assert-PlainFile -Path $Path
    $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Open,
        [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
    try { $stream.Flush($true) } finally { $stream.Dispose() }
}

function Test-NvapiTransactionPath {
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

function Get-NvapiOptionalFileHash {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $null = Assert-PlainFile -Path $Path
    return Get-LowerSha256 -Path $Path
}

function Test-NvapiRetryableDeleteError {
    param([Parameter(Mandatory = $true)]$ErrorRecord)

    # Windows 会把 ACL 拒绝和仍被进程映射的 image section 分别报告为
    # AccessDenied(5) 或 SharingViolation(32)；只允许这两个原生码延期。
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

function Assert-NvapiManagedBackupFile {
    param([Parameter(Mandatory = $true)]$Entry)

    # CleanupDeferred 资格只来自已校验 receipt：路径必须是目标同目录下的
    # 唯一 backup 名，摘要也必须是当前/历史项目发布物。任一条件不满足即拒绝。
    if (-not (Test-NvapiTransactionPath $Entry.Backup $Entry.Directory `
            $Entry.FileName 'backup')) {
        throw ('NVAPI 托管备份路径非法：' + [string]$Entry.Backup)
    }
    $allowedHashes = @([string]$Entry.ExpectedHash) + @($Entry.HistoricalHashes)
    if (-not (Test-HashInAllowList ([string]$Entry.ObservedHash) $allowedHashes)) {
        throw ('NVAPI 托管备份摘要未被发布清单授权：' + [string]$Entry.Backup)
    }
    if (-not (Test-Path -LiteralPath $Entry.Backup)) { return $false }
    $null = Assert-PlainFile -Path $Entry.Backup
    if ((Get-LowerSha256 -Path $Entry.Backup) -cne [string]$Entry.ObservedHash) {
        throw ('NVAPI 托管备份摘要不匹配：' + [string]$Entry.Backup)
    }
    return $true
}

function Remove-NvapiManagedBackupFile {
    param([Parameter(Mandatory = $true)]$Entry)

    if (-not (Assert-NvapiManagedBackupFile -Entry $Entry)) { return $false }
    try {
        Remove-TransactionFile -Path $Entry.Backup
        return $false
    } catch {
        if (-not (Test-NvapiRetryableDeleteError $_)) { throw }
    }

    # 返回 deferred 前再次核对普通文件和摘要；路径若已被并发删除则已经成功，
    # 字节或类型发生变化则硬失败。调用方必须保留 receipt，不能按路径延迟删除。
    if (-not (Assert-NvapiManagedBackupFile -Entry $Entry)) { return $false }
    return $true
}

function Test-NvapiCleanupDeferredError {
    param([Parameter(Mandatory = $true)]$ErrorRecord)

    $exception = $ErrorRecord.Exception
    while ($null -ne $exception) {
        if ($exception.Data.Contains('VmateNvapiCleanupDeferred') -and
            [bool]$exception.Data['VmateNvapiCleanupDeferred']) { return $true }
        $exception = $exception.InnerException
    }
    return $false
}

function Undo-NvapiProjectionEntry {
    param([Parameter(Mandatory = $true)]$Entry)

    $targetHash = Get-NvapiOptionalFileHash $Entry.Target
    $backupHash = Get-NvapiOptionalFileHash $Entry.Backup
    $discardHash = Get-NvapiOptionalFileHash $Entry.Discard
    if ([string]$Entry.DesiredState -ceq 'Absent') {
        # “原本不存在”不授权本事务删除后来出现的任何文件；这类并发变化只能
        # fail-closed，交给后续诊断确认来源，绝不能为了完成 rollback 强制清空目标。
        if ($Entry.CommitAction -ceq 'UnchangedAbsent') {
            if ($targetHash -or $backupHash -or $discardHash) {
                throw ('UnchangedAbsent NVAPI 目标在事务中发生变化：' + $Entry.Target)
            }
            return
        }
        if ($Entry.CommitAction -cne 'Removed') {
            throw ('Absent NVAPI 回滚动作非法：' + $Entry.CommitAction)
        }

        # Removed 的合法状态只有“托管旧文件仍在目标”或“已原子分离到收据 backup”。
        # 目标若被真实驱动或其他进程重新创建，哪怕同名，也绝不覆盖或删除。
        if ($targetHash -ceq $Entry.ObservedHash -and -not $backupHash -and
            -not $discardHash) {
            return
        }
        if (-not $targetHash -and $backupHash -ceq $Entry.ObservedHash -and
            -not $discardHash) {
            Move-NvapiFileWriteThrough $Entry.Backup $Entry.Target
            if ((Get-NvapiOptionalFileHash $Entry.Target) -cne $Entry.ObservedHash) {
                throw ('Removed NVAPI rollback 恢复摘要非法：' + $Entry.Target)
            }
            return
        }
        throw ('Removed NVAPI 回滚状态非法，拒绝触碰未知目标：' + $Entry.Target)
    }
    if ($Entry.CommitAction -eq '') {
        if ($targetHash -cne $Entry.ExpectedHash) {
            throw ('Unchanged NVAPI 目标在事务中发生变化：' + $Entry.Target)
        }
        return
    }
    if ($Entry.CommitAction -eq 'Created') {
        # Prepared/已回滚：目标和 discard 都不存在；Committed：目标为新摘要；
        # rollback 中断：新文件已原子移到 deterministic discard。
        if ($targetHash -ceq $Entry.ExpectedHash -and -not $discardHash) {
            Move-NvapiFileWriteThrough $Entry.Target $Entry.Discard
            $targetHash = ''; $discardHash = Get-NvapiOptionalFileHash $Entry.Discard
        }
        if (-not $targetHash -and $discardHash -ceq $Entry.ExpectedHash) {
            Remove-TransactionFile -Path $Entry.Discard
            return
        }
        if (-not $targetHash -and -not $discardHash) { return }
        throw ('Created NVAPI 回滚状态非法：' + $Entry.Target)
    }
    if ($Entry.CommitAction -ne 'Replaced') {
        throw ('NVAPI 回滚动作非法：' + $Entry.CommitAction)
    }

    # Replaced 的可恢复状态：旧目标尚未移动；旧目标已在 backup；新目标已提交；
    # 或 rollback 已把新目标移到 discard。每一种都只接受收据中的精确摘要组合。
    if ($targetHash -ceq $Entry.ObservedHash -and -not $backupHash) {
        if ($discardHash -and $discardHash -cne $Entry.ExpectedHash) {
            throw ('NVAPI discard 摘要非法：' + $Entry.Discard)
        }
        Remove-TransactionFile -Path $Entry.Discard
        return
    }
    if (-not $targetHash -and $backupHash -ceq $Entry.ObservedHash -and
        (-not $discardHash -or $discardHash -ceq $Entry.ExpectedHash)) {
        Move-NvapiFileWriteThrough $Entry.Backup $Entry.Target
        Remove-TransactionFile -Path $Entry.Discard
        return
    }
    if ($targetHash -ceq $Entry.ExpectedHash -and
        $backupHash -ceq $Entry.ObservedHash -and -not $discardHash) {
        Move-NvapiFileWriteThrough $Entry.Target $Entry.Discard
        if ((Get-NvapiOptionalFileHash $Entry.Discard) -cne $Entry.ExpectedHash) {
            throw ('NVAPI rollback detach 摘要非法：' + $Entry.Discard)
        }
        Move-NvapiFileWriteThrough $Entry.Backup $Entry.Target
        Remove-TransactionFile -Path $Entry.Discard
        return
    }
    throw ('Replaced NVAPI 回滚状态非法：' + $Entry.Target)
}

function Write-NvapiProjectionReceipt {
    param([object[]]$Entries, [string]$Path, [string]$TransactionId)

    Assert-NvapiTransactionId $TransactionId
    if (Test-Path -LiteralPath $Path) { throw ('NVAPI 收据已存在：' + $Path) }
    $desiredStates = @($Entries | ForEach-Object {
        $value = [string]$_.DesiredState
        if ([string]::IsNullOrWhiteSpace($value)) { 'Present' } else { $value }
    } | Select-Object -Unique)
    if ($desiredStates.Count -ne 1 -or
        -not (@('Present', 'Absent') -ccontains [string]$desiredStates[0])) {
        throw 'NVAPI 收据 DesiredState 非法或条目不一致'
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
        SchemaVersion=3; TransactionId=$TransactionId
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
            # Flush(true) 请求 Windows FlushFileBuffers；关闭文件后才原子改名为正式收据。
            $stream.Flush($true)
        } finally { $stream.Dispose() }
        Move-NvapiFileWriteThrough $temporary $Path
    } finally { Remove-TransactionFile -Path $temporary }
}

function Read-NvapiProjectionReceipt {
    param([object[]]$Entries, [string]$Path, [string]$TransactionId)

    Assert-NvapiTransactionId $TransactionId
    $item = Assert-PlainFile -Path $Path
    if ($item.Length -lt 32 -or $item.Length -gt 64KB) { throw 'NVAPI 收据大小非法' }
    $document = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    $records = @($document.Entries)
    $schemaVersion = [int]$document.SchemaVersion
    if (-not (@(2, 3) -contains $schemaVersion) -or
        [string]$document.TransactionId -cne $TransactionId -or
        $records.Count -ne $Entries.Count) { throw 'NVAPI 收据头或条目数非法' }
    # schema-2 是历史“只安装”收据；schema-3 才允许显式记录可逆删除。
    # 禁止从旧文档推断 Absent，避免篡改旧 Action 后获得删除权限。
    $desiredState = if ($schemaVersion -eq 2) {
        'Present'
    } else {
        [string]$document.DesiredState
    }
    if (-not (@('Present', 'Absent') -ccontains $desiredState)) {
        throw 'NVAPI 收据 DesiredState 非法'
    }
    for ($index = 0; $index -lt $Entries.Count; $index++) {
        $entry = $Entries[$index]; $record = $records[$index]
        $sameTarget = [StringComparer]::OrdinalIgnoreCase.Equals(
            [IO.Path]::GetFullPath([string]$record.Target),
            [IO.Path]::GetFullPath([string]$entry.Target))
        $receiptExpected = [string]$record.ExpectedHash
        $allowedExpected = @([string]$entry.ExpectedHash) + @($entry.HistoricalHashes)
        if ([string]$record.FileName -cne [string]$entry.FileName -or
            -not $sameTarget -or -not (Test-HashInAllowList $receiptExpected $allowedExpected)) {
            throw ('NVAPI 收据目标或发布摘要不匹配：' + $entry.FileName)
        }
        if ($entry.PSObject.Properties.Name -contains 'DesiredState') {
            $entry.DesiredState = $desiredState
        } else {
            # 历史单元测试与旧调用方构造的 entry 没有该属性；读取旧 schema 时补上
            # 只读状态字段即可，不改变其目标、摘要或事务路径。
            $entry | Add-Member -NotePropertyName DesiredState `
                -NotePropertyValue $desiredState
        }
        $entry.ExpectedHash = $receiptExpected
        $action = [string]$record.Action; $previous = [string]$record.PreviousHash
        $stage = [string]$record.Stage; $backup = [string]$record.Backup
        $discard = [string]$record.Discard
        if ($desiredState -ceq 'Absent') {
            if ($action -ceq 'UnchangedAbsent') {
                if ($previous -or $stage -or $backup -or $discard) {
                    throw ('NVAPI UnchangedAbsent 收据非法：' + $entry.FileName)
                }
                $entry.CommitAction = 'UnchangedAbsent'
            } elseif ($action -ceq 'Removed') {
                if (-not (Test-HashInAllowList $previous $allowedExpected) -or
                    $stage -or $discard -or
                    -not (Test-NvapiTransactionPath $backup $entry.Directory `
                        $entry.FileName 'backup')) {
                    throw ('NVAPI Removed 收据非法：' + $entry.FileName)
                }
                $entry.CommitAction = 'Removed'
            } else {
                throw ('Absent NVAPI 收据动作非法：' + $action)
            }
        } elseif ($action -eq 'Unchanged') {
            if ($previous -cne $receiptExpected -or $stage -or $backup -or $discard) {
                throw ('NVAPI Unchanged 收据非法：' + $entry.FileName)
            }
            $entry.CommitAction = ''
        } elseif ($action -eq 'Created') {
            if ($previous -or $backup -or
                -not (Test-NvapiTransactionPath $stage $entry.Directory $entry.FileName 'stage') -or
                -not (Test-NvapiTransactionPath $discard $entry.Directory $entry.FileName 'rollback')) {
                throw ('NVAPI Created 收据非法：' + $entry.FileName)
            }
            $entry.CommitAction = 'Created'
        } elseif ($action -eq 'Replaced') {
            if ($previous -ceq $receiptExpected -or
                -not (Test-HashInAllowList $previous $entry.HistoricalHashes) -or
                -not (Test-NvapiTransactionPath $stage $entry.Directory $entry.FileName 'stage') -or
                -not (Test-NvapiTransactionPath $backup $entry.Directory $entry.FileName 'backup') -or
                -not (Test-NvapiTransactionPath $discard $entry.Directory $entry.FileName 'rollback')) {
                throw ('NVAPI Replaced 收据非法：' + $entry.FileName)
            }
            $entry.CommitAction = 'Replaced'
        } else { throw ('NVAPI 收据动作非法：' + $action) }
        $entry.ObservedHash=$previous; $entry.Stage=$stage
        $entry.Backup=$backup; $entry.Discard=$discard
    }
    return $Entries
}

function Finalize-NvapiProjectionReceipt {
    param([object[]]$Entries, [string]$Path, [string]$TransactionId)

    $resolved = @(Read-NvapiProjectionReceipt $Entries $Path $TransactionId)
    foreach ($entry in $resolved) {
        if ([string]$entry.DesiredState -ceq 'Absent') {
            # Finalize 只能清理收据自己记录的 backup；目标被外部重新创建时不进行
            # 任何删除，保留收据并报错，避免误伤真实 NVIDIA 驱动文件。
            if (Get-NvapiOptionalFileHash $entry.Target) {
                throw ('Absent NVAPI Finalize 发现目标重新出现：' + $entry.Target)
            }
            if ($entry.CommitAction -ceq 'Removed') {
                $removedBackupHash = Get-NvapiOptionalFileHash $entry.Backup
                # 删除 backup 后、删除 receipt 前被中断时，backup 缺失代表上次
                # Finalize 已完成数据清理；允许本次仅删除遗留收据。存在时仍须精确匹配。
                if ($removedBackupHash -and
                    $removedBackupHash -cne $entry.ObservedHash) {
                    throw ('Removed NVAPI Finalize 备份摘要不匹配：' + $entry.Backup)
                }
                $null = Assert-NvapiManagedBackupFile -Entry $entry
            }
            continue
        }
        Assert-NvapiBinary $entry.Target $entry.ExpectedHash $entry.Machine $entry.Magic
        # Unchanged 条目没有 stage/backup/discard；只有 Created/Replaced 才会生成
        # rollback 路径。Test-Path 不接受空 LiteralPath，因此必须先判空，保证已经是
        # 当前 DLL 的重复运行也能幂等 Finalize，而不是在最后一步误报参数绑定失败。
        if (-not [string]::IsNullOrWhiteSpace([string]$entry.Discard) -and
            (Test-Path -LiteralPath $entry.Discard)) {
            throw ('Finalize 发现未完成 rollback discard：' + $entry.Discard)
        }
        if ($entry.CommitAction -ceq 'Replaced') {
            $null = Assert-NvapiManagedBackupFile -Entry $entry
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
                    if (Remove-NvapiManagedBackupFile -Entry $entry) {
                        $cleanupDeferred.Add([string]$entry.Backup)
                    }
                } catch { $cleanupErrors.Add($_.Exception.Message) }
            }
            continue
        }
        if ($entry.CommitAction -ne 'Replaced' -or
            -not (Test-Path -LiteralPath $entry.Backup)) { continue }
        try {
            if (Remove-NvapiManagedBackupFile -Entry $entry) {
                $cleanupDeferred.Add([string]$entry.Backup)
            }
        } catch { $cleanupErrors.Add($_.Exception.Message) }
    }
    if ($cleanupErrors.Count -gt 0) {
        throw ('NVAPI Finalize 清理失败：' + ($cleanupErrors -join ' | '))
    }
    if ($cleanupDeferred.Count -gt 0) {
        $exception = New-Object IO.IOException(
            ('NVAPI 托管备份仍被占用，需重启后继续清理：' +
                ($cleanupDeferred -join ', ')))
        $exception.Data['VmateNvapiCleanupDeferred'] = $true
        throw $exception
    }
    Remove-TransactionFile -Path $Path
}

function Rollback-NvapiProjectionReceipt {
    param([object[]]$Entries, [string]$Path, [string]$TransactionId)

    $resolved = @(Read-NvapiProjectionReceipt $Entries $Path $TransactionId)
    $errors = New-Object Collections.Generic.List[string]
    for ($index = $resolved.Count - 1; $index -ge 0; $index--) {
        try { Undo-NvapiProjectionEntry $resolved[$index] } catch {
            $errors.Add($_.Exception.Message)
        }
        try { Remove-TransactionFile -Path $resolved[$index].Stage } catch {
            $errors.Add($_.Exception.Message)
        }
    }
    if ($errors.Count -gt 0) { throw ('NVAPI 收据回滚失败：' + ($errors -join ' | ')) }
    Remove-TransactionFile -Path $Path
}

function Resolve-PendingNvapiReceipts {
    param([object[]]$Entries, [string]$ReceiptRoot, [string]$CurrentIdentityId)

    foreach ($receipt in @(Get-ChildItem -LiteralPath $ReceiptRoot -Filter '*.json' -File)) {
        $id = [IO.Path]::GetFileNameWithoutExtension($receipt.Name)
        Assert-NvapiTransactionId $id
        # Read 会把 receipt 当时的 expected hash 写入工作 entry，以兼容跨版本恢复；
        # 每张收据必须使用独立浅拷贝，不能让第一张历史摘要污染下一张的 canonical 集合。
        $receiptEntries = @($Entries | ForEach-Object { $_.PSObject.Copy() })
        if ($id -ceq $CurrentIdentityId) {
            Finalize-NvapiProjectionReceipt $receiptEntries $receipt.FullName $id
            Write-Host ('已完成中断的 NVAPI/identity 事务：' + $id) -ForegroundColor Yellow
        } else {
            Rollback-NvapiProjectionReceipt $receiptEntries $receipt.FullName $id
            Write-Host ('已回滚中断的 NVAPI/identity 事务：' + $id) -ForegroundColor Yellow
        }
    }
}
