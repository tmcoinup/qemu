#!/usr/bin/env bash
# 验证 NVAPI receipt 托管备份的严格删除与映射占用回退。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
INSTALLER="$REPO_ROOT/deploy/guest-stealth/install-nvapi-system.ps1"
VALIDATION="$REPO_ROOT/deploy/guest-stealth/nvapi-system-validation.ps1"
TRANSACTION="$REPO_ROOT/deploy/guest-stealth/nvapi-system-transaction.ps1"
NVAPI_X86="$REPO_ROOT/deploy/nvapi-shim/nvapi.dll"
NVAPI_X64="$REPO_ROOT/deploy/nvapi-shim/nvapi64.dll"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

for path in "$INSTALLER" "$VALIDATION" "$TRANSACTION" "$NVAPI_X86" "$NVAPI_X64"; do
    [[ -f "$path" ]] || fail "缺少 NVAPI managed-cleanup 测试输入: $path"
done

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

INSTALLER_PATH="$INSTALLER" VALIDATION_PATH="$VALIDATION" \
TRANSACTION_PATH="$TRANSACTION" NVAPI_X86_PATH="$NVAPI_X86" \
NVAPI_X64_PATH="$NVAPI_X64" TEST_ROOT_PATH="$TEST_ROOT" \
pwsh -NoLogo -NoProfile -NonInteractive -Command '
    $ErrorActionPreference = "Stop"

    foreach ($path in @($env:VALIDATION_PATH, $env:INSTALLER_PATH,
            $env:TRANSACTION_PATH)) {
        $source = [IO.File]::ReadAllText($path)
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput(
            $source, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { throw ("AST 不可用：" + $path) }
        $definitions = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst]
        }, $true))
        foreach ($definition in $definitions) {
            if ($path -eq $env:INSTALLER_PATH -and
                $definition.Name -ne "Remove-TransactionFile") { continue }
            . ([scriptblock]::Create($definition.Extent.Text))
        }
    }

    $x86Hash = Get-LowerSha256 $env:NVAPI_X86_PATH
    $x64Hash = Get-LowerSha256 $env:NVAPI_X64_PATH

    function New-ManagedEntry {
        param([string]$Name, [string]$Token)
        $directory = Join-Path $env:TEST_ROOT_PATH $Name
        [IO.Directory]::CreateDirectory($directory) | Out-Null
        $backup = Join-Path $directory (
            ".nvapi.dll.vmate-backup-" + $Token)
        [IO.File]::Copy($env:NVAPI_X64_PATH, $backup)
        return [pscustomobject]@{
            FileName="nvapi.dll"; Directory=$directory
            Target=(Join-Path $directory "nvapi.dll")
            Backup=$backup; ExpectedHash=$x86Hash
            HistoricalHashes=@($x64Hash); ObservedHash=$x64Hash
        }
    }

    function Initialize-FinalizeEntry {
        param($Entry, [string]$StageToken, [string]$DiscardToken)
        [IO.File]::Copy($env:NVAPI_X86_PATH, $Entry.Target)
        $Entry | Add-Member Machine 0x014C
        $Entry | Add-Member Magic 0x010B
        $Entry | Add-Member Stage (Join-Path $Entry.Directory `
            (".nvapi.dll.vmate-stage-" + $StageToken))
        $Entry | Add-Member Discard (Join-Path $Entry.Directory `
            (".nvapi.dll.vmate-rollback-" + $DiscardToken))
        $Entry | Add-Member CommitAction ""
        return $Entry
    }

    function Write-Schema2Receipt {
        param([object[]]$Entries, [string]$Path, [string]$TransactionId)
        $records = @($Entries | ForEach-Object {
            [ordered]@{
                FileName=$_.FileName; Target=$_.Target
                ExpectedHash=$_.ExpectedHash; PreviousHash=$_.ObservedHash
                Action="Replaced"; Stage=$_.Stage; Backup=$_.Backup
                Discard=$_.Discard
            }
        })
        $document = [ordered]@{
            SchemaVersion=2; TransactionId=$TransactionId; Entries=$records
        }
        [IO.File]::WriteAllText($Path,
            ($document | ConvertTo-Json -Depth 4),
            (New-Object Text.UTF8Encoding($false)))
    }

    foreach ($code in @(5, 32)) {
        $record = [pscustomobject]@{
            Exception=(New-Object ComponentModel.Win32Exception($code))
        }
        if (-not (Test-NvapiRetryableDeleteError $record)) {
            throw ("Win32 删除错误未进入回退：" + $code)
        }
    }
    $ordinaryError = [pscustomobject]@{
        Exception=(New-Object InvalidOperationException("injected"))
    }
    if (Test-NvapiRetryableDeleteError $ordinaryError) {
        throw "普通逻辑错误被错误降级为 CleanupDeferred"
    }

    $normal = New-ManagedEntry "normal" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    $normalDeferred = Remove-NvapiManagedBackupFile $normal
    if ($normalDeferred -or (Test-Path -LiteralPath $normal.Backup)) {
        throw "可立即删除的托管备份仍然存在"
    }

    $script:lockedBackup = ""
    $script:nonRetryableBackup = ""
    $originalRemove = (Get-Item Function:\Remove-TransactionFile).ScriptBlock
    function Remove-TransactionFile {
        param([string]$Path)
        if ($Path -ceq $script:nonRetryableBackup) {
            throw (New-Object InvalidOperationException("injected non-retryable"))
        }
        if ($Path -ceq $script:lockedBackup) {
            throw (New-Object UnauthorizedAccessException("injected mapped image"))
        }
        if ([string]::IsNullOrWhiteSpace($Path) -or
            -not (Test-Path -LiteralPath $Path)) { return }
        Microsoft.PowerShell.Management\Remove-Item -LiteralPath $Path -Force
    }

    $locked = New-ManagedEntry "locked" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    $script:lockedBackup = $locked.Backup
    $lockedDeferred = Remove-NvapiManagedBackupFile $locked
    if (-not $lockedDeferred -or
        -not (Test-Path -LiteralPath $locked.Backup)) {
        throw "映射占用备份没有返回 CleanupDeferred"
    }

    $tampered = New-ManagedEntry "tampered" "cccccccccccccccccccccccccccccccc"
    [IO.File]::WriteAllText($tampered.Backup, "unknown bytes")
    $tamperRejected = $false
    try { Remove-NvapiManagedBackupFile $tampered } catch { $tamperRejected = $true }
    if (-not $tamperRejected -or
        -not (Test-Path -LiteralPath $tampered.Backup)) {
        throw "未知摘要备份未 fail-closed"
    }

    $nonCanonical = New-ManagedEntry "noncanonical" "dddddddddddddddddddddddddddddddd"
    $nonCanonical.Backup = Join-Path $nonCanonical.Directory "detached.dll"
    [IO.File]::Copy($env:NVAPI_X64_PATH, $nonCanonical.Backup)
    $pathRejected = $false
    try { Remove-NvapiManagedBackupFile $nonCanonical } catch { $pathRejected = $true }
    if (-not $pathRejected) {
        throw "非 canonical receipt backup 获得了删除权限"
    }

    $ordinaryDirectory = New-ManagedEntry "directory" `
        "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath `
        $ordinaryDirectory.Backup -Force
    [IO.Directory]::CreateDirectory($ordinaryDirectory.Backup) | Out-Null
    $plainRejected = $false
    try { Remove-NvapiManagedBackupFile $ordinaryDirectory } `
        catch { $plainRejected = $true }
    if (-not $plainRejected) {
        throw "目录冒充 backup 未被普通文件检查拒绝"
    }

    $nonRetryable = New-ManagedEntry "nonretryable" `
        "ffffffffffffffffffffffffffffffff"
    $script:nonRetryableBackup = $nonRetryable.Backup
    $logicRejected = $false
    try { Remove-NvapiManagedBackupFile $nonRetryable } `
        catch { $logicRejected = $true }
    if (-not $logicRejected) {
        throw "非权限类删除错误被错误降级为 CleanupDeferred"
    }
    $script:nonRetryableBackup = ""

    # schema-2 没有 DesiredState；先让第一份备份成功清理、第二份返回 deferred，
    # Finalize 必须尝试全部条目并保留 receipt。释放占用后的同收据重试才可收口。
    $partialA = Initialize-FinalizeEntry `
        (New-ManagedEntry "partial-a" "0123456789abcdef0123456789abcdef") `
        "11111111111111111111111111111111" `
        "22222222222222222222222222222222"
    $partialB = Initialize-FinalizeEntry `
        (New-ManagedEntry "partial-b" "123456789abcdef0123456789abcdef0") `
        "44444444444444444444444444444444" `
        "55555555555555555555555555555555"
    $partialId = "33333333333333333333333333333333"
    $partialReceipt = Join-Path $env:TEST_ROOT_PATH ($partialId + ".json")
    Write-Schema2Receipt @($partialA, $partialB) $partialReceipt $partialId
    $script:lockedBackup = $partialB.Backup
    $deferredCaught = $false
    try {
        Finalize-NvapiProjectionReceipt @($partialA, $partialB) `
            $partialReceipt $partialId
    } catch {
        $deferredCaught = Test-NvapiCleanupDeferredError $_
        if (-not $deferredCaught) { throw }
    }
    if (-not $deferredCaught -or
        -not (Test-Path -LiteralPath $partialReceipt) -or
        (Test-Path -LiteralPath $partialA.Backup) -or
        -not (Test-Path -LiteralPath $partialB.Backup)) {
        throw "schema-2 部分清理没有保留 receipt/deferred backup"
    }
    $script:lockedBackup = ""
    Finalize-NvapiProjectionReceipt @($partialA, $partialB) `
        $partialReceipt $partialId
    if ((Test-Path -LiteralPath $partialReceipt) -or
        (Test-Path -LiteralPath $partialB.Backup)) {
        throw "schema-2 重启后重试没有幂等收口"
    }

    # 非 5/32 的硬失败也必须尝试另一份 backup，但不能带 deferred marker，
    # 更不能删除 durable receipt。
    $hardA = Initialize-FinalizeEntry `
        (New-ManagedEntry "hard-a" "66666666666666666666666666666666") `
        "77777777777777777777777777777777" `
        "88888888888888888888888888888888"
    $hardB = Initialize-FinalizeEntry `
        (New-ManagedEntry "hard-b" "99999999999999999999999999999999") `
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab" `
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbc"
    $hardId = "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"
    $hardReceipt = Join-Path $env:TEST_ROOT_PATH ($hardId + ".json")
    Write-Schema2Receipt @($hardA, $hardB) $hardReceipt $hardId
    $script:nonRetryableBackup = $hardA.Backup
    $hardCaught = $false
    try {
        Finalize-NvapiProjectionReceipt @($hardA, $hardB) $hardReceipt $hardId
    } catch {
        $hardCaught = -not (Test-NvapiCleanupDeferredError $_)
    }
    if (-not $hardCaught -or
        -not (Test-Path -LiteralPath $hardReceipt) -or
        -not (Test-Path -LiteralPath $hardA.Backup) -or
        (Test-Path -LiteralPath $hardB.Backup)) {
        throw "Finalize 硬失败未保留 receipt 或未尝试其余 backup"
    }
    $script:nonRetryableBackup = ""
    Finalize-NvapiProjectionReceipt @($hardA, $hardB) $hardReceipt $hardId
    if (Test-Path -LiteralPath $hardReceipt) {
        throw "硬失败解除后的重试没有收口 receipt"
    }

    Set-Item Function:\Remove-TransactionFile -Value $originalRemove
' || fail "NVAPI managed backup 删除/回退测试失败"

if rg -n 'takeown|icacls|Set-Acl|Get-Acl|SetAccessControl|GetAccessControl' \
        "$TRANSACTION" >&2; then
    fail "NVAPI managed cleanup 不得夺取所有权或修改 DACL"
fi
if rg -F 'MoveFileEx($Path, $null, [uint32]4)' "$TRANSACTION" >&2; then
    fail "CleanupDeferred 仍把未经重启复核的路径登记为延迟删除"
fi
rg -F 'Assert-NvapiManagedBackupFile -Entry $Entry' "$TRANSACTION" >/dev/null \
    || fail "CleanupDeferred 前缺少 receipt backup 严格验证"
rg -F "VmateNvapiCleanupDeferred" "$TRANSACTION" >/dev/null \
    || fail "Finalize 缺少 durable CleanupDeferred marker"
rg -F 'if ($cleanupDeferredExit) { exit 12 }' "$INSTALLER" >/dev/null \
    || fail "NVAPI installer 没有把 CleanupDeferred 映射为退出码 12"

echo "OK: NVAPI managed backup cleanup is strict and durably deferred"
