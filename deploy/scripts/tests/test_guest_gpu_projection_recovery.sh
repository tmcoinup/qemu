#!/usr/bin/env bash
# 覆盖 HardwareID journal 中断恢复、SetupAPI 前置门禁和单次重启组合状态。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PLAN="$REPO_ROOT/deploy/scripts/gpu-hardware-id-plan.ps1"
PROJECTOR="$REPO_ROOT/deploy/scripts/project-gpu-hardware-id.ps1"
PROJECTION_TRANSACTION="$REPO_ROOT/deploy/scripts/gpu-hardware-id-transaction.ps1"
RESPAWN="$REPO_ROOT/deploy/guest-stealth/respawn-stealth-local.ps1"
RESTART_HELPER="$REPO_ROOT/deploy/guest-stealth/respawn-restart-state.ps1"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# 所有生产投影脚本必须保持 Windows PowerShell 5.1 可解析。
PS_FILES="$PLAN:$PROJECTOR:$PROJECTION_TRANSACTION:$RESPAWN:$RESTART_HELPER" \
pwsh -NoLogo -NoProfile -NonInteractive -Command '
foreach ($path in $env:PS_FILES -split [IO.Path]::PathSeparator) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile(
        $path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        throw ($path + ": " + (($errors.Message) -join " | "))
    }
}
' >/dev/null || fail "HardwareID 投影 PowerShell AST 解析失败"

# seal/sysprep 后的新实例为纯物理时可跳过旧 identity 回滚；fake-first 和无设备
# 不能被前置门禁误报为可安全执行驱动/PnP 操作。
RESPAWN="$RESPAWN" pwsh -NoLogo -NoProfile -NonInteractive -Command '
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $env:RESPAWN, [ref]$tokens, [ref]$errors)
foreach ($name in "Assert-PhysicalDisplayHardwareIds",
        "Test-PhysicalDisplayHardwareIds") {
    $node = $ast.Find({ param($item)
        $item -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $item.Name -eq $name
    }, $true)
    if ($null -eq $node) { throw ("缺少生产函数：" + $name) }
    . ([scriptblock]::Create($node.Extent.Text))
}
function Get-PnpDevice {
    param([string]$Class, [switch]$PresentOnly, $ErrorAction)
    if (-not $script:NoDevice) {
        [pscustomobject]@{ InstanceId=$script:InstanceId }
    }
}
function Get-PnpDeviceProperty {
    param([string]$InstanceId, [string]$KeyName, $ErrorAction)
    [pscustomobject]@{ Data=[string[]]@($script:HardwareIds) }
}
$physical = @(
    "PCI\VEN_1AF4&DEV_1050&SUBSYS_1D0110DE&REV_A1",
    "PCI\VEN_1AF4&DEV_1050&SUBSYS_1D0110DE"
)
$script:InstanceId = $physical[0] + "\3&11583659&0&30"
$script:HardwareIds = $physical
$script:NoDevice = $false
if (-not (Test-PhysicalDisplayHardwareIds)) { throw "纯物理实例未通过预检" }
$script:HardwareIds = @(
    "PCI\VEN_10DE&DEV_1D01&SUBSYS_1D0110DE&REV_A1") + $physical
if (Test-PhysicalDisplayHardwareIds) { throw "fake-first 被误报为纯物理" }
$script:NoDevice = $true
if (Test-PhysicalDisplayHardwareIds) { throw "无设备被误报为纯物理" }
' >/dev/null || fail "seal/sysprep 首启 physical-only 预检测试失败"

# 使用生产 Set-ProjectionBackupState 与 Test-BackupAllowsCurrentIds，逐个注入最终
# journal 写点失败。任意中断态必须同时允许设备当前 expected 和 catch 恢复的 before。
PLAN="$PLAN" PROJECTOR="$PROJECTOR" \
PROJECTION_TRANSACTION="$PROJECTION_TRANSACTION" \
pwsh -NoLogo -NoProfile -NonInteractive -Command '
$ErrorActionPreference = "Stop"
. $env:PLAN
function Get-FunctionSource([string]$Path, [string]$Name) {
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        $Path, [ref]$tokens, [ref]$errors)
    $node = $ast.Find({ param($item)
        $item -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $item.Name -eq $Name
    }, $true)
    if ($null -eq $node) { throw ("缺少生产函数：" + $Name) }
    return $node.Extent.Text
}
. ([scriptblock]::Create((Get-FunctionSource `
    $env:PROJECTION_TRANSACTION "Set-ProjectionBackupState")))
. ([scriptblock]::Create((Get-FunctionSource `
    $env:PROJECTOR "Test-BackupAllowsCurrentIds")))

class MockJournalKey {
    [hashtable]$Values
    [int]$OperationCount
    [int]$FailAt
    MockJournalKey([hashtable]$Values) { $this.Values = $Values }
    [void] Touch() {
        $this.OperationCount++
        if ($this.FailAt -gt 0 -and $this.OperationCount -eq $this.FailAt) {
            throw ("injected journal failure " + $this.FailAt)
        }
    }
    [void] SetValue([string]$Name, [object]$Value, [object]$Kind) {
        $this.Touch()
        $this.Values[$Name] = if ($Value -is [array]) {
            [string[]]@($Value)
        } else { $Value }
    }
    [void] DeleteValue([string]$Name, [bool]$ThrowOnMissing) {
        $this.Touch()
        [void]$this.Values.Remove($Name)
    }
    [void] Flush() { $this.Touch() }
    [void] Dispose() {}
}
class MockJournalBase {
    [MockJournalKey]$Key
    MockJournalBase([MockJournalKey]$Key) { $this.Key = $Key }
    [MockJournalKey] CreateSubKey([string]$Path, [bool]$Writable) {
        return $this.Key
    }
}
function Get-BackupRelativePath([string]$InstanceId) { return "mock" }
function Get-ProjectionBackup($BaseKey, [string]$InstanceId) {
    return $script:ExistingBackup
}
$multiStringKind = [Microsoft.Win32.RegistryValueKind]::MultiString
$stringKind = [Microsoft.Win32.RegistryValueKind]::String
$dwordKind = [Microsoft.Win32.RegistryValueKind]::DWord
$original = [string[]]@("PCI\VEN_1AF4&DEV_1050")
$before = [string[]]@(
    "PCI\VEN_10DE&DEV_1C82&SUBSYS_00007377&REV_A1") + $original
$expected = [string[]]@(
    "PCI\VEN_10DE&DEV_1C82&SUBSYS_37631458&REV_A1") + $original
$target = [pscustomobject]@{
    InstanceId="PCI\VEN_1AF4&DEV_1050\MOCK"
    CompatibleIds=[string[]]@("PCI\VEN_1AF4&DEV_1050")
    Service="VioGpuDod"
    Driver="{4D36E968-E325-11CE-BFC1-08002BE10318}\0001"
}
function New-Backup([string[]]$Rollback) {
    [pscustomobject]@{
        OriginalHardwareIds=$original
        OriginalCompatibleIds=$target.CompatibleIds
        OriginalService=$target.Service
        OriginalDriver=$target.Driver
        AppliedHardwareIds=$before
        PendingHardwareIds=[string[]]@()
        RollbackHardwareIds=[string[]]@($Rollback)
        IdentityId="OLD"
        TransactionState="Applied"
    }
}
function Has-Ids([hashtable]$Values, [string[]]$Ids) {
    foreach ($name in "OriginalHardwareIds", "AppliedHardwareIds",
            "PendingHardwareIds", "RollbackHardwareIds") {
        if ($Values.ContainsKey($name) -and
            (Test-StringArrayEqual ([string[]]$Values[$name]) $Ids)) {
            return $true
        }
    }
    return $false
}
foreach ($failAt in 0..7) {
    $values = @{
        SchemaVersion=1
        InstanceId=$target.InstanceId
        OriginalHardwareIds=$original
        OriginalCompatibleIds=$target.CompatibleIds
        OriginalService=$target.Service
        OriginalDriver=$target.Driver
        AppliedHardwareIds=$before
        IdentityId="OLD"
        TransactionState="Applied"
    }
    $key = [MockJournalKey]::new($values)
    $base = [MockJournalBase]::new($key)
    $script:ExistingBackup = New-Backup @()
    Set-ProjectionBackupState $base $target $original $before $expected `
        "NEW" "Applying"
    if (-not (Test-StringArrayEqual `
            ([string[]]$values.RollbackHardwareIds) $before)) {
        throw "Applying 未先发布 durable rollback anchor"
    }
    $script:ExistingBackup = New-Backup `
        ([string[]]$values.RollbackHardwareIds)
    $key.OperationCount = 0
    $key.FailAt = $failAt
    $failed = $false
    try {
        Set-ProjectionBackupState $base $target $original $expected @() `
            "NEW" "Applied"
    } catch { $failed = $true }
    if (($failAt -eq 0) -eq $failed) {
        throw ("journal 故障注入结果错误：" + $failAt)
    }
    if (-not (Has-Ids $values $before) -or
        -not (Has-Ids $values $expected)) {
        throw ("journal 中断丢失 before/expected：" + $failAt)
    }
    $backup = New-Backup ([string[]]$values.RollbackHardwareIds)
    $backup.AppliedHardwareIds = [string[]]$values.AppliedHardwareIds
    $backup.PendingHardwareIds = if ($values.ContainsKey(
            "PendingHardwareIds")) {
        [string[]]$values.PendingHardwareIds
    } else { [string[]]@() }
    if (-not (Test-BackupAllowsCurrentIds $backup $before)) {
        throw ("reader 不接受 durable rollback anchor：" + $failAt)
    }
}
' >/dev/null || fail "HardwareID durable journal 故障注入测试失败"

# Full resume 已消费一次自动重启。若芯片组仍 pending，只能替换为手动重启后的
# 验证任务并返回 30；完全成功才删除任务并返回 0。
resume_body="$(sed -n '/^function Complete-RespawnResumeStage {/,/^}/p' \
    "$RESTART_HELPER")"
chipset_line="$(grep -n -F 'if ($ChipsetRestartRequired)' \
    <<<"$resume_body" | cut -d: -f1)"
pending_exit_line="$(grep -n -F 'exit 30' <<<"$resume_body" | cut -d: -f1)"
success_exit_line="$(grep -n -F 'exit 0' <<<"$resume_body" | cut -d: -f1)"
[[ -n "$chipset_line" && -n "$pending_exit_line" &&
    -n "$success_exit_line" && "$chipset_line" -lt "$pending_exit_line" &&
    "$pending_exit_line" -lt "$success_exit_line" ]] \
    || fail "Full resume 仍会把 chipset pending 误报为完全成功"
grep -F -- "-ResumeStage 'ChipsetVerification'" <<<"$resume_body" >/dev/null \
    || fail "chipset pending 没有保留手动重启后的只验证任务"
if grep -F 'Invoke-RespawnShutdown' <<<"$resume_body" >&2; then
    fail "Full resume completion helper 仍可能触发第二次自动重启"
fi

RESTART_HELPER="$RESTART_HELPER" \
pwsh -NoLogo -NoProfile -NonInteractive -Command '
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $env:RESTART_HELPER, [ref]$tokens, [ref]$errors)
$node = $ast.Find({ param($item)
    $item -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $item.Name -eq "Complete-RespawnResumeStage"
}, $true)
if ($null -eq $node) { throw "缺少 Complete-RespawnResumeStage" }
$body = $node.Extent.Text.Replace(
    "exit 56", "throw `"ProbeExit56`"").Replace(
    "exit 30", "throw `"ProbeExit30`"").Replace(
    "exit 47", "throw `"ProbeExit47`"").Replace(
    "exit 0", "throw `"ProbeExit0`"")
. ([scriptblock]::Create($body))
$script:RegisterCalls = 0
$script:RemoveCalls = 0
function Register-RespawnResumeTask {
    param([string]$MainScriptPath, [switch]$KeepFirstLogon,
        [string]$ResumeStage)
    if ($MainScriptPath -cne "main.ps1" -or
        $ResumeStage -cne "ChipsetVerification") {
        throw "只验证任务参数错误"
    }
    $script:RegisterCalls++
}
function Remove-RespawnResumeTask {
    param([switch]$CurrentInstance)
    if (-not $CurrentInstance) { throw "未按 CurrentInstance 删除" }
    $script:RemoveCalls++
}
$probe = ""
try {
    Complete-RespawnResumeStage -ChipsetRestartRequired $true `
        -MainScriptPath "main.ps1"
} catch { $probe = $_.Exception.Message }
if ($probe -cne "ProbeExit30" -or $script:RegisterCalls -ne 1 -or
    $script:RemoveCalls -ne 0) {
    throw "chipset pending 分支没有保留验证任务并返回 30"
}
$probe = ""
try {
    Complete-RespawnResumeStage -ChipsetRestartRequired $false `
        -MainScriptPath "main.ps1"
} catch { $probe = $_.Exception.Message }
if ($probe -cne "ProbeExit0" -or $script:RegisterCalls -ne 1 -or
    $script:RemoveCalls -ne 1) {
    throw "完全成功分支没有删除任务并返回 0"
}
' >/dev/null || fail "Full resume chipset pending 运行时路由测试失败"

echo "OK: GPU projection journal and one-reboot recovery contracts passed"
