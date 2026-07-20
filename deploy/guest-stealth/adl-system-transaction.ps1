#Requires -Version 5.1

<#
.SYNOPSIS
  AMD ADL 三目标系统投影的持久收据与崩溃恢复状态机。

.DESCRIPTION
  本文件由 install-adl-system.ps1 在定义摘要、PE 与普通文件校验函数后载入。
  receipt 必须在第一个系统目录 Move 前写穿落盘，并完整记录三个目标的
  Target/Stage/Backup/Discard。恢复只接受收据中的规范路径和精确摘要，
  不会把未知或真实 AMD DLL 当作 VMate 历史发布物处理。
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

function Undo-AdlProjectionEntry {
    param([Parameter(Mandatory = $true)]$Entry)

    $targetHash = Get-AdlOptionalFileHash $Entry.Target
    $backupHash = Get-AdlOptionalFileHash $Entry.Backup
    $discardHash = Get-AdlOptionalFileHash $Entry.Discard
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
    $records = @($Entries | ForEach-Object {
        [ordered]@{
            FileName=[string]$_.FileName; Target=[string]$_.Target
            ExpectedHash=[string]$_.ExpectedHash; PreviousHash=[string]$_.ObservedHash
            Action=if ($_.CommitAction) { [string]$_.CommitAction } else { 'Unchanged' }
            Stage=[string]$_.Stage; Backup=[string]$_.Backup; Discard=[string]$_.Discard
        }
    })
    $document = [ordered]@{
        SchemaVersion=1; TransactionId=$TransactionId; Entries=$records
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
    if ([int]$document.SchemaVersion -ne 1 -or
        [string]$document.TransactionId -cne $TransactionId -or
        $records.Count -ne $Entries.Count) { throw 'ADL 收据头或条目数非法' }
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
        $entry.ExpectedHash = $receiptExpected
        $action = [string]$record.Action
        $previous = [string]$record.PreviousHash
        $stage = [string]$record.Stage
        $backup = [string]$record.Backup
        $discard = [string]$record.Discard
        if ($action -eq 'Unchanged') {
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
        Assert-AdlBinary $entry.Target $entry.ExpectedHash $entry.Machine $entry.Magic
        if (-not [string]::IsNullOrWhiteSpace([string]$entry.Discard) -and
            (Test-Path -LiteralPath $entry.Discard)) {
            throw ('ADL Finalize 发现未完成 rollback discard：' + $entry.Discard)
        }
    }
    foreach ($entry in $resolved) {
        Remove-TransactionFile -Path $entry.Stage
        if ($entry.CommitAction -ne 'Replaced' -or
            -not (Test-Path -LiteralPath $entry.Backup)) { continue }
        if ((Get-AdlOptionalFileHash $entry.Backup) -cne $entry.ObservedHash) {
            throw ('ADL Finalize 备份摘要不匹配：' + $entry.Backup)
        }
        Remove-TransactionFile -Path $entry.Backup
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
