#!/usr/bin/env bash
# 以纯内存 RegistryKey 替身验证 GPU durable transaction 的崩溃恢复、首次安装、
# CAS 拒绝和 journal 故障路径；Linux CI 不需要 Windows 注册表或 PnP 设备。
# shellcheck disable=SC2016
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TRANSACTION_SCRIPT="$REPO_ROOT/deploy/scripts/gpu-profile-transaction.ps1"
PERSIST_SCRIPT="$REPO_ROOT/deploy/scripts/persist-gpu-profile.ps1"
REFRESH_SCRIPT="$REPO_ROOT/deploy/scripts/refresh-gpu-name.ps1"
APPLY_SCRIPT="$REPO_ROOT/deploy/scripts/apply-gpu-spoof.ps1"
LOCK_PROBE_HELPER="$SCRIPT_DIR/fixtures/run_gpu_identity_lock_probe.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

command -v pwsh >/dev/null 2>&1 || fail "缺少 pwsh"
[[ -f "$LOCK_PROBE_HELPER" ]] || fail "缺少 identity mutex 并发测试 helper"

# 把行数上限本身放进 quick 回归，避免后续又把 fixture/并发探针塞回主文件。
# 按项目规则只统计非空、非注释行；中文说明不占用 500 行代码预算。
for test_source in "$0" "$LOCK_PROBE_HELPER"; do
    code_lines="$(awk '!/^[[:space:]]*($|#)/ { count++ } END { print count + 0 }' \
        "$test_source")"
    (( code_lines <= 500 )) || fail "$test_source 非注释代码行=$code_lines，超过 500"
done

TRANSACTION_SCRIPT="$TRANSACTION_SCRIPT" pwsh -NoLogo -NoProfile -NonInteractive -Command '
$ErrorActionPreference = "Stop"
. $env:TRANSACTION_SCRIPT

$script:nestedLockEntered = $false
Invoke-WithIdentityWriterLock {
    Invoke-WithIdentityWriterLock { $script:nestedLockEntered = $true }
}
if (-not $script:nestedLockEntered) { throw "同线程 named mutex 不可重入" }

function New-FakeRegistryKey {
    $key = [pscustomobject]@{
        Values=@{}; Kinds=@{}; Children=@{}; FailSetName=$null; FlushCount=0
    }
    $key | Add-Member ScriptMethod GetValueNames { return @($this.Values.Keys) }
    $key | Add-Member ScriptMethod GetValueKind { param($Name) return $this.Kinds[$Name] }
    $key | Add-Member ScriptMethod GetValue {
        param($Name, $DefaultValue, $Options)
        if ($this.Values.ContainsKey($Name)) { return $this.Values[$Name] }
        return $DefaultValue
    }
    $key | Add-Member ScriptMethod SetValue {
        param($Name, $Value, $Kind)
        if ($this.FailSetName -ceq $Name) { throw ("injected SetValue failure: " + $Name) }
        $this.Values[$Name] = $Value; $this.Kinds[$Name] = $Kind
    }
    $key | Add-Member ScriptMethod DeleteValue {
        param($Name, $ThrowOnMissing)
        [void]$this.Values.Remove($Name); [void]$this.Kinds.Remove($Name)
    }
    $key | Add-Member ScriptMethod OpenSubKey {
        param($Path, $Writable)
        if ($this.Children.ContainsKey($Path)) { return $this.Children[$Path] }
        return $null
    }
    $key | Add-Member ScriptMethod CreateSubKey {
        param($Path, $Writable)
        if (-not $this.Children.ContainsKey($Path)) {
            $this.Children[$Path] = New-FakeRegistryKey
        }
        return $this.Children[$Path]
    }
    $key | Add-Member ScriptMethod Flush { $this.FlushCount++ }
    $key | Add-Member ScriptMethod Dispose {}
    return $key
}

function Set-FakeValue($Key, [string]$Name, $Value, $Kind) {
    $Key.Values[$Name] = $Value; $Key.Kinds[$Name] = $Kind
}

function Set-CompleteIdentityValues {
    param(
        $Key,
        [string]$IdentityId,
        [int]$Schema,
        [string]$SourceInstanceId,
        [string]$SpoofName,
        [bool]$IncludeSchema2Extensions
    )
    $string = [Microsoft.Win32.RegistryValueKind]::String
    $dword = [Microsoft.Win32.RegistryValueKind]::DWord
    Set-FakeValue $Key IdentitySchemaVersion $Schema $dword
    Set-FakeValue $Key IdentityId $IdentityId $string
    Set-FakeValue $Key SpoofName $SpoofName $string
    Set-FakeValue $Key SpoofVendor "NVIDIA" $string
    Set-FakeValue $Key SpoofBios "Version 86.07.48.00.A0" $string
    Set-FakeValue $Key SpoofPciVendorId 0x10DE $dword
    Set-FakeValue $Key SpoofPciDeviceId 0x1C82 $dword
    Set-FakeValue $Key SpoofSubsystemVendorId 0x10DE $dword
    Set-FakeValue $Key SpoofSubsystemDeviceId 0x1C82 $dword
    Set-FakeValue $Key SpoofRevisionId 0xA1 $dword
    Set-FakeValue $Key SpoofPciBusId 0 $dword
    Set-FakeValue $Key SpoofPciSlotId 6 $dword
    Set-FakeValue $Key SpoofPciFunctionId 0 $dword
    Set-FakeValue $Key SpoofRamMb 4096 $dword
    Set-FakeValue $Key SourceInstanceId $SourceInstanceId $string
    Set-FakeValue $Key IdentityMode "shallow-user-projection" $string
    if ($IncludeSchema2Extensions) {
        Set-FakeValue $Key SpoofMemoryType "GDDR5" $string
        Set-FakeValue $Key SpoofMemoryBusWidthBits 128 $dword
        Set-FakeValue $Key SpoofBaseClockKHz 1290000 $dword
        Set-FakeValue $Key SpoofBoostClockKHz 1392000 $dword
        Set-FakeValue $Key SpoofMemoryClockKHz 3504000 $dword
        Set-FakeValue $Key SpoofSliSupported 0 $dword
    }
}

function New-TransactionFixture {
    param([string]$IdentityId, [bool]$OldPointerPresent, [string]$State)
    $string = [Microsoft.Win32.RegistryValueKind]::String
    $dword = [Microsoft.Win32.RegistryValueKind]::DWord
    $binary = [Microsoft.Win32.RegistryValueKind]::Binary
    $qword = [Microsoft.Win32.RegistryValueKind]::QWord
    $oldId = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    $source = "PCI\VEN_1AF4&DEV_1050&SUBSYS_1C8210DE&REV_A1\3&TEST&0&30"
    $enumPath = "SYSTEM\CurrentControlSet\Enum\" + $source
    $classPath = "SYSTEM\CurrentControlSet\Control\Class\" + $classGuid + "\0001"
    $base = New-FakeRegistryKey; $config = New-FakeRegistryKey
    $transaction = New-FakeRegistryKey; $identity = New-FakeRegistryKey
    $oldIdentity = New-FakeRegistryKey
    $enum = New-FakeRegistryKey; $class = New-FakeRegistryKey
    $base.Children["SOFTWARE\StealthGPU"] = $config
    $base.Children[$enumPath] = $enum; $base.Children[$classPath] = $class
    $config.Children["Transactions\" + $IdentityId] = $transaction
    $config.Children["Identities\" + $IdentityId] = $identity
    if ($OldPointerPresent) {
        $config.Children["Identities\" + $oldId] = $oldIdentity
        Set-CompleteIdentityValues $oldIdentity $oldId 2 $source "OLD GPU" $true
    }
    Set-FakeValue $transaction TransactionSchemaVersion 1 $dword
    Set-FakeValue $transaction TransactionId $IdentityId $string
    Set-FakeValue $transaction State $State $string
    Set-FakeValue $transaction PreviousPointerPresent ([int]$OldPointerPresent) $dword
    if ($OldPointerPresent) { Set-FakeValue $transaction PreviousIdentityId $oldId $string }
    Set-FakeValue $transaction PreviousSpoofNamePresent ([int]$OldPointerPresent) $dword
    if ($OldPointerPresent) { Set-FakeValue $transaction PreviousSpoofName "OLD GPU" $string }
    Set-FakeValue $transaction ClassSubkey "0001" $string
    Set-CompleteIdentityValues $identity $IdentityId 2 $source `
        "NVIDIA GeForce GTX 1050 Ti" $true
    foreach ($name in $enumJournalNames) { Set-FakeValue $enum $name ("OLD-" + $name) $string }
    foreach ($name in $classJournalNames) {
        if ($name -ceq "HardwareInformation.MemorySize") {
            Set-FakeValue $class $name ([byte[]](0,0,0,128)) $binary
        } elseif ($name -ceq "HardwareInformation.qwMemorySize") {
            Set-FakeValue $class $name ([UInt64]2147483648) $qword
        } else { Set-FakeValue $class $name ("OLD-" + $name) $string }
    }
    Write-ProjectionJournal $transaction Enum $enum $enumPath $enumJournalNames
    Write-ProjectionJournal $transaction Class $class $classPath $classJournalNames
    Set-FakeValue $enum FriendlyName "NVIDIA GeForce GTX 1050 Ti" $string
    Set-FakeValue $enum DeviceDesc "NVIDIA GeForce GTX 1050 Ti" $string
    Set-FakeValue $enum Mfg "NVIDIA" $string
    foreach ($name in $classJournalNames) {
        if ($name -ceq "HardwareInformation.MemorySize") {
            Set-FakeValue $class $name ([byte[]](0,0,0,0)) $binary
        } elseif ($name -ceq "HardwareInformation.qwMemorySize") {
            Set-FakeValue $class $name ([UInt64]4294967296) $qword
        } else {
            $projected = switch -CaseSensitive ($name) {
                DriverDesc { "NVIDIA GeForce GTX 1050 Ti"; break }
                ProviderName { "NVIDIA"; break }
                MatchingDeviceId { "PCI\VEN_10DE&DEV_1C82"; break }
                "HardwareInformation.AdapterString" { "NVIDIA GeForce GTX 1050 Ti"; break }
                "HardwareInformation.ChipType" { "GeForce GTX 1050 Ti"; break }
                "HardwareInformation.DacType" { "Integrated RAMDAC"; break }
                "HardwareInformation.BiosString" { "Version 86.07.48.00.A0"; break }
            }
            Set-FakeValue $class $name $projected $string
        }
    }
    Set-FakeValue $config PendingIdentity $IdentityId $string
    Set-FakeValue $config CurrentIdentity $IdentityId $string
    Set-FakeValue $config SpoofName "NVIDIA GeForce GTX 1050 Ti" $string
    return [pscustomobject]@{
        Base=$base; Config=$config; Transaction=$transaction; Enum=$enum; Class=$class
        Identity=$identity; OldIdentity=$oldIdentity
        IdentityId=$IdentityId; OldId=$oldId; OldPointerPresent=$OldPointerPresent
    }
}

function Set-LegacyPreviousIdentity {
    param(
        $Fixture,
        [bool]$IncludeIdentityId,
        [string]$IdentityId = $Fixture.OldId
    )
    $string = [Microsoft.Win32.RegistryValueKind]::String
    $dword = [Microsoft.Win32.RegistryValueKind]::DWord
    Set-FakeValue $Fixture.OldIdentity IdentitySchemaVersion 1 $dword
    if ($IncludeIdentityId) {
        Set-FakeValue $Fixture.OldIdentity IdentityId $IdentityId $string
    } else {
        [void]$Fixture.OldIdentity.Values.Remove("IdentityId")
        [void]$Fixture.OldIdentity.Kinds.Remove("IdentityId")
    }
    # schema-1 是完整 common snapshot，只比 schema-2 少这六个型号扩展字段。
    # 测试显式删除它们，避免把 schema 数字改小但仍保留 schema-2 内容的假 fixture。
    foreach ($name in @(
        "SpoofMemoryType", "SpoofMemoryBusWidthBits", "SpoofBaseClockKHz",
        "SpoofBoostClockKHz", "SpoofMemoryClockKHz", "SpoofSliSupported"
    )) {
        [void]$Fixture.OldIdentity.Values.Remove($name)
        [void]$Fixture.OldIdentity.Kinds.Remove($name)
    }
}

function Assert-RecoveryRejectedWithoutMutation {
    param($Fixture, [string]$Message)
    $currentBefore = [string]$Fixture.Config.Values.CurrentIdentity
    $pendingBefore = [string]$Fixture.Config.Values.PendingIdentity
    $mirrorBefore = [string]$Fixture.Config.Values.SpoofName
    $stateBefore = [string]$Fixture.Transaction.Values.State
    $enumBefore = [string]$Fixture.Enum.Values.FriendlyName
    $classBefore = [string]$Fixture.Class.Values.DriverDesc
    $rejected = $false
    try { Invoke-RecoverOrRollback -Recover | Out-Null }
    catch { $rejected = $true }
    if (-not $rejected -or
        [string]$Fixture.Config.Values.CurrentIdentity -cne $currentBefore -or
        [string]$Fixture.Config.Values.PendingIdentity -cne $pendingBefore -or
        [string]$Fixture.Config.Values.SpoofName -cne $mirrorBefore -or
        [string]$Fixture.Transaction.Values.State -cne $stateBefore -or
        [string]$Fixture.Enum.Values.FriendlyName -cne $enumBefore -or
        [string]$Fixture.Class.Values.DriverDesc -cne $classBefore) {
        throw $Message
    }
}

function Assert-RolledBack($Fixture) {
    if ($Fixture.Config.Values.ContainsKey("PendingIdentity")) { throw "PendingIdentity 未清除" }
    if ([string]$Fixture.Transaction.Values.State -cne "RolledBack") { throw "事务未标记 RolledBack" }
    if ($Fixture.OldPointerPresent) {
        if ([string]$Fixture.Config.Values.CurrentIdentity -cne $Fixture.OldId -or
            [string]$Fixture.Config.Values.SpoofName -cne "OLD GPU") {
            throw "旧 pointer/mirror 未恢复"
        }
    } elseif ($Fixture.Config.Values.ContainsKey("CurrentIdentity") -or
        $Fixture.Config.Values.ContainsKey("SpoofName")) { throw "首次安装回滚未删除 pointer/mirror" }
    if ([string]$Fixture.Enum.Values.FriendlyName -cne "OLD-FriendlyName") {
        throw "Enum journal 未恢复"
    }
    if ([UInt64]$Fixture.Class.Values["HardwareInformation.qwMemorySize"] -ne 2147483648) {
        throw "Class QWord journal 未恢复"
    }
    $bytes = [byte[]]$Fixture.Class.Values["HardwareInformation.MemorySize"]
    if ($bytes.Count -ne 4 -or $bytes[3] -ne 128) { throw "Class Binary journal 未恢复" }
}

# 模拟 pointer 已提交后进程被直接 kill：下次 Recover 必须仅凭持久 receipt 恢复。
$script:fixture = New-TransactionFixture "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB" $true Committed
function Open-StealthBaseKey { return $script:fixture.Base }
function Invoke-LegacyGpuTaskBarrier {}
$receipt = Read-TransactionReceipt $script:fixture.Config $script:fixture.IdentityId
if ([int]$receipt.PreviousIdentitySchemaVersion -ne 2) {
    throw "schema-2 PreviousIdentity 未走严格原路径"
}
$result = Invoke-RecoverOrRollback -Recover
if ($result.Action -cne "RolledBack") { throw "kill 后 Recover 没有执行 rollback" }
Assert-RolledBack $script:fixture
if ($null -ne (Invoke-RecoverOrRollback -Recover)) { throw "Recover 不是幂等操作" }

# 现场升级路径：旧 CurrentIdentity 指向带正确自 ID 的 schema-1。旧实现会在
# 这里重现“PreviousIdentityId 不是完整 schema-2 快照”；修复后 receipt 必须把
# 它视为显式 legacy rollback pointer，允许 CAS 发布字段完整的新 schema-2。
$script:fixture = New-TransactionFixture "66666666666666666666666666666666" $true Prepared
Set-LegacyPreviousIdentity $script:fixture $true
Set-FakeValue $script:fixture.Transaction PreviousIdentitySchemaVersion 1 `
    ([Microsoft.Win32.RegistryValueKind]::DWord)
Set-FakeValue $script:fixture.Config CurrentIdentity $script:fixture.OldId `
    ([Microsoft.Win32.RegistryValueKind]::String)
Set-FakeValue $script:fixture.Config SpoofName "OLD GPU" `
    ([Microsoft.Win32.RegistryValueKind]::String)
$receipt = Read-TransactionReceipt $script:fixture.Config $script:fixture.IdentityId
if ([int]$receipt.PreviousIdentitySchemaVersion -ne 1) {
    throw "schema-1 PreviousIdentity 未被显式标记为 legacy"
}
$expected = [pscustomobject]@{
    Present=$receipt.PreviousPointerPresent; Value=$receipt.PreviousIdentityId
}
Set-CurrentIdentityPointer $script:fixture.Config $expected $true $receipt.NewIdentityId
Set-FakeValue $script:fixture.Config SpoofName $receipt.NewSpoofName `
    ([Microsoft.Win32.RegistryValueKind]::String)
Set-TransactionState $script:fixture.Config $receipt.NewIdentityId Prepared Committed
Set-TransactionState $script:fixture.Config $receipt.NewIdentityId Committed Completed
Clear-PendingIdentity $script:fixture.Config $receipt.NewIdentityId
if ([string]$script:fixture.Config.Values.CurrentIdentity -cne $script:fixture.IdentityId -or
    [int]$script:fixture.Identity.Values.IdentitySchemaVersion -ne 2 -or
    $script:fixture.Config.Values.ContainsKey("PendingIdentity")) {
    throw "schema-1 CurrentIdentity 未成功迁移到完整 schema-2"
}

# legacy pointer 已 CAS 到新 schema-2 后若进程崩溃，durable receipt 仍必须恢复
# 原 schema-1 pointer、旧名称镜像和两个投影 journal。这里刻意不写新版的
# PreviousIdentitySchemaVersion marker，验证现场遗留 txn-v1 仍可恢复。
$script:fixture = New-TransactionFixture "77777777777777777777777777777777" $true Committed
Set-LegacyPreviousIdentity $script:fixture $true
$result = Invoke-RecoverOrRollback -Recover
if ($result.Action -cne "RolledBack") { throw "schema-1 提交后故障没有回滚" }
Assert-RolledBack $script:fixture

# schema-1 的必填 IdentityId 正确时应兼容。此切点位于投影完成、pointer
# CAS 之前，回滚只能保留原 legacy pointer，并恢复 journal。
$script:fixture = New-TransactionFixture "88888888888888888888888888888888" $true Prepared
Set-LegacyPreviousIdentity $script:fixture $true
Set-FakeValue $script:fixture.Config CurrentIdentity $script:fixture.OldId `
    ([Microsoft.Win32.RegistryValueKind]::String)
Set-FakeValue $script:fixture.Config SpoofName "OLD GPU" `
    ([Microsoft.Win32.RegistryValueKind]::String)
$result = Invoke-RecoverOrRollback -Recover
if ($result.Action -cne "RolledBack") { throw "schema-1 提交前故障没有回滚" }
Assert-RolledBack $script:fixture

# CAS 已把 pointer 改成新 schema-2、但事务状态仍停在 Prepared 的断电窗口也必须
# 识别为本事务状态并恢复旧 schema-1；不能只支持 Committed 的现场残留。
$script:fixture = New-TransactionFixture "89898989898989898989898989898989" $true Prepared
Set-LegacyPreviousIdentity $script:fixture $true
$result = Invoke-RecoverOrRollback -Recover
if ($result.Action -cne "RolledBack") { throw "schema-1 CAS 后 Prepared 故障没有回滚" }
Assert-RolledBack $script:fixture

# Complete 先持久化 Completed、清 Pending 前被终止时，新 schema-2 已正式生效。
# legacy previous 只用于验证 receipt，Recover 必须仅清 Pending，绝不能倒退 pointer。
$script:fixture = New-TransactionFixture "8A8A8A8A8A8A8A8A8A8A8A8A8A8A8A8A" $true Completed
Set-LegacyPreviousIdentity $script:fixture $true
$result = Invoke-RecoverOrRollback -Recover
if ($result.Action -cne "Completed" -or
    $script:fixture.Config.Values.ContainsKey("PendingIdentity") -or
    [string]$script:fixture.Config.Values.CurrentIdentity -cne $script:fixture.IdentityId -or
    [string]$script:fixture.Enum.Values.FriendlyName -cne "NVIDIA GeForce GTX 1050 Ti") {
    throw "schema-1 previous 的 Completed 恢复错误回滚了正式身份"
}

# legacy 兼容面只允许字段完整的 schema=1。半成品/未知 schema、自 ID 不一致
# 以及 marker 与实际 schema 不一致，都必须在任何 pointer/journal 写入前拒绝。
foreach ($badSchema in 0, 3) {
    $script:fixture = New-TransactionFixture "99999999999999999999999999999999" $true Prepared
    Set-LegacyPreviousIdentity $script:fixture $true
    Set-FakeValue $script:fixture.OldIdentity IdentitySchemaVersion $badSchema `
        ([Microsoft.Win32.RegistryValueKind]::DWord)
    Assert-RecoveryRejectedWithoutMutation $script:fixture `
        ("非法旧身份 schema 未安全拒绝：" + $badSchema)
}
$script:fixture = New-TransactionFixture "ABABABABABABABABABABABABABABABAB" $true Prepared
Set-LegacyPreviousIdentity $script:fixture $true "CDCDCDCDCDCDCDCDCDCDCDCDCDCDCDCD"
Assert-RecoveryRejectedWithoutMutation $script:fixture "schema-1 错误自 ID 未安全拒绝"
$script:fixture = New-TransactionFixture "ADADADADADADADADADADADADADADADAD" $true Prepared
Set-LegacyPreviousIdentity $script:fixture $true
Set-FakeValue $script:fixture.OldIdentity IdentitySchemaVersion "1" `
    ([Microsoft.Win32.RegistryValueKind]::String)
Assert-RecoveryRejectedWithoutMutation $script:fixture "schema-1 schema 类型错误未安全拒绝"
$script:fixture = New-TransactionFixture "AEAEAEAEAEAEAEAEAEAEAEAEAEAEAEAE" $true Prepared
Set-LegacyPreviousIdentity $script:fixture $true
Set-FakeValue $script:fixture.OldIdentity IdentityId 1 `
    ([Microsoft.Win32.RegistryValueKind]::DWord)
Assert-RecoveryRejectedWithoutMutation $script:fixture "schema-1 自 ID 类型错误未安全拒绝"
$schema1CommonFields = @(
    "IdentitySchemaVersion", "IdentityId", "SpoofName", "SpoofVendor", "SpoofBios",
    "SpoofPciVendorId", "SpoofPciDeviceId", "SpoofSubsystemVendorId",
    "SpoofSubsystemDeviceId", "SpoofRevisionId", "SpoofPciBusId", "SpoofPciSlotId",
    "SpoofPciFunctionId", "SpoofRamMb", "SourceInstanceId", "IdentityMode"
)
foreach ($missingField in $schema1CommonFields) {
    $script:fixture = New-TransactionFixture "A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1" $true Prepared
    Set-LegacyPreviousIdentity $script:fixture $true
    [void]$script:fixture.OldIdentity.Values.Remove($missingField)
    [void]$script:fixture.OldIdentity.Kinds.Remove($missingField)
    Assert-RecoveryRejectedWithoutMutation $script:fixture `
        ("schema-1 缺少 common 字段未安全拒绝：" + $missingField)
}
$script:fixture = New-TransactionFixture "A2A2A2A2A2A2A2A2A2A2A2A2A2A2A2A2" $true Prepared
Set-LegacyPreviousIdentity $script:fixture $true
Set-FakeValue $script:fixture.Transaction PreviousIdentitySchemaVersion 2 `
    ([Microsoft.Win32.RegistryValueKind]::DWord)
Assert-RecoveryRejectedWithoutMutation $script:fixture "previous schema marker 与快照不一致未拒绝"
$script:fixture = New-TransactionFixture "A3A3A3A3A3A3A3A3A3A3A3A3A3A3A3A3" $true Prepared
Set-LegacyPreviousIdentity $script:fixture $true
Set-FakeValue $script:fixture.Transaction PreviousIdentitySchemaVersion "1" `
    ([Microsoft.Win32.RegistryValueKind]::String)
Assert-RecoveryRejectedWithoutMutation $script:fixture "previous schema marker 类型错误未拒绝"
$script:fixture = New-TransactionFixture "A5A5A5A5A5A5A5A5A5A5A5A5A5A5A5A5" $false Prepared
Set-FakeValue $script:fixture.Transaction PreviousIdentitySchemaVersion 2 `
    ([Microsoft.Win32.RegistryValueKind]::DWord)
Assert-RecoveryRejectedWithoutMutation $script:fixture "无 previous pointer 却接受 schema marker"

# schema-2 继续执行严格原路径，不能借 legacy 分支省略或放宽 IdentityId。
$script:fixture = New-TransactionFixture "ACACACACACACACACACACACACACACACAC" $true Prepared
[void]$script:fixture.OldIdentity.Values.Remove("IdentityId")
[void]$script:fixture.OldIdentity.Kinds.Remove("IdentityId")
Assert-RecoveryRejectedWithoutMutation $script:fixture "schema-2 缺少自 ID 却回退到 legacy"
$script:fixture = New-TransactionFixture "AFAFAFAFAFAFAFAFAFAFAFAFAFAFAFAF" $true Prepared
Set-FakeValue $script:fixture.OldIdentity IdentityId `
    "BFBFBFBFBFBFBFBFBFBFBFBFBFBFBFBF" ([Microsoft.Win32.RegistryValueKind]::String)
Assert-RecoveryRejectedWithoutMutation $script:fixture "schema-2 错误自 ID 却回退到 legacy"
$schema2ExtensionFields = @(
    "SpoofMemoryType", "SpoofMemoryBusWidthBits", "SpoofBaseClockKHz",
    "SpoofBoostClockKHz", "SpoofMemoryClockKHz", "SpoofSliSupported"
)
foreach ($missingField in $schema2ExtensionFields) {
    $script:fixture = New-TransactionFixture "A4A4A4A4A4A4A4A4A4A4A4A4A4A4A4A4" $true Prepared
    [void]$script:fixture.OldIdentity.Values.Remove($missingField)
    [void]$script:fixture.OldIdentity.Kinds.Remove($missingField)
    Assert-RecoveryRejectedWithoutMutation $script:fixture `
        ("schema-2 缺少扩展字段未安全拒绝：" + $missingField)
}

# 首次安装切点 1：Prepared 后、投影前，pointer 仍不存在；Recover 必须幂等恢复。
$script:fixture = New-TransactionFixture "11111111111111111111111111111111" $false Prepared
[void]$script:fixture.Config.Values.Remove("CurrentIdentity")
[void]$script:fixture.Config.Kinds.Remove("CurrentIdentity")
$receipt = Read-TransactionReceipt $script:fixture.Config $script:fixture.IdentityId
Restore-ProjectionJournal $script:fixture.Base $receipt.EnumJournal $receipt.ProjectedEnum
Restore-ProjectionJournal $script:fixture.Base $receipt.ClassJournal $receipt.ProjectedClass
$result = Invoke-RecoverOrRollback -Recover
if ($result.Action -cne "RolledBack") { throw "首次安装投影前 crash 没有恢复" }
Assert-RolledBack $script:fixture

# 首次安装切点 2：投影已完成但 CAS 尚未发生，pointer 仍不存在。
$script:fixture = New-TransactionFixture "22222222222222222222222222222222" $false Prepared
[void]$script:fixture.Config.Values.Remove("CurrentIdentity")
[void]$script:fixture.Config.Kinds.Remove("CurrentIdentity")
$result = Invoke-RecoverOrRollback -Recover
if ($result.Action -cne "RolledBack") { throw "首次安装投影后 crash 没有恢复" }
Assert-RolledBack $script:fixture

# 首次安装切点 3：CAS 已落但 State 仍是 Prepared，必须删除 pointer 并恢复原投影。
$script:fixture = New-TransactionFixture "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC" $false Prepared
$result = Invoke-RecoverOrRollback -Recover
if ($result.Action -cne "RolledBack") { throw "首次安装 crash 没有恢复" }
Assert-RolledBack $script:fixture

# 切点 4：Complete 已先持久化 State=Completed、尚未清 Pending。Recover 只能
# 完成清理，不能回滚已经正式完成的新 pointer/投影。
$script:fixture = New-TransactionFixture "33333333333333333333333333333333" $false Completed
$result = Invoke-RecoverOrRollback -Recover
if ($result.Action -cne "Completed" -or
    $script:fixture.Config.Values.ContainsKey("PendingIdentity") -or
    [string]$script:fixture.Config.Values.CurrentIdentity -cne $script:fixture.IdentityId -or
    [string]$script:fixture.Enum.Values.FriendlyName -cne "NVIDIA GeForce GTX 1050 Ti") {
    throw "Completed-before-clear 恢复语义错误"
}

# 非本事务 pointer 必须在 journal 写入前被 CAS 门禁拒绝。
$script:fixture = New-TransactionFixture "DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD" $true Committed
Set-FakeValue $script:fixture.Config CurrentIdentity "EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE" `
    ([Microsoft.Win32.RegistryValueKind]::String)
$rejected = $false
try { Invoke-RecoverOrRollback -Recover | Out-Null } catch { $rejected = $true }
if (-not $rejected -or [string]$script:fixture.Enum.Values.FriendlyName -cne "NVIDIA GeForce GTX 1050 Ti") {
    throw "并发 pointer 没有在 journal 前 fail-closed"
}

# pointer 未变但某个投影值被第三方修改时，journal 值级 CAS 必须在首写前拒绝。
$script:fixture = New-TransactionFixture "44444444444444444444444444444444" $true Committed
Set-FakeValue $script:fixture.Enum FriendlyName "THIRD-PARTY" `
    ([Microsoft.Win32.RegistryValueKind]::String)
$rejected = $false
try { Invoke-RecoverOrRollback -Recover | Out-Null } catch { $rejected = $true }
if (-not $rejected -or [string]$script:fixture.Enum.Values.DeviceDesc -cne
    "NVIDIA GeForce GTX 1050 Ti" -or
    [string]$script:fixture.Class.Values.DriverDesc -cne "NVIDIA GeForce GTX 1050 Ti") {
    throw "journal 值级 CAS 没有在恢复首写前拒绝第三方修改"
}

# Class 侧第三方修改也必须在 Enum 首写之前被发现，验证跨 journal 预检原子性。
$script:fixture = New-TransactionFixture "55555555555555555555555555555555" $true Committed
Set-FakeValue $script:fixture.Class DriverDesc "THIRD-PARTY" `
    ([Microsoft.Win32.RegistryValueKind]::String)
$rejected = $false
try { Invoke-RecoverOrRollback -Recover | Out-Null } catch { $rejected = $true }
if (-not $rejected -or [string]$script:fixture.Enum.Values.FriendlyName -cne
    "NVIDIA GeForce GTX 1050 Ti" -or
    [string]$script:fixture.Enum.Values.DeviceDesc -cne "NVIDIA GeForce GTX 1050 Ti") {
    throw "Class CAS 失败前 Enum 已被部分恢复"
}

# journal 恢复首写故障必须保留 Pending/新 pointer，供下一次 Recover 重试。
$script:fixture = New-TransactionFixture "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF" $true Committed
$script:fixture.Enum.FailSetName = "FriendlyName"
$rejected = $false
try { Invoke-RecoverOrRollback -Recover | Out-Null } catch { $rejected = $true }
if (-not $rejected -or -not $script:fixture.Config.Values.ContainsKey("PendingIdentity") -or
    [string]$script:fixture.Config.Values.CurrentIdentity -cne $script:fixture.IdentityId) {
    throw "journal 故障没有保留可重试 durable 状态"
}
' >/dev/null

# 两个独立 PowerShell 进程验证 named mutex 确实串行化临界区。并发细节
# 拆到 helper，主文件仍由 quick runner 纳入，同时遵守单文件 500 行限制。
bash "$LOCK_PROBE_HELPER" "$TRANSACTION_SCRIPT" \
    || fail "identity mutex 跨进程串行化测试失败"

# apply 的唯一外层 try/finally 必须覆盖 no-target、Class/Commit、final refresh 与
# display 非零退出；任何路径都由同一 durable RollbackIdentity 收口。
APPLY_SCRIPT="$APPLY_SCRIPT" pwsh -NoLogo -NoProfile -NonInteractive -Command '
$tokens=$null; $errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile(
    $env:APPLY_SCRIPT,[ref]$tokens,[ref]$errors)
if($errors.Count){throw "apply AST parse failed"}
$guard=$ast.Find({param($n)
    $n -is [System.Management.Automation.Language.TryStatementAst] -and
    $null -ne $n.Finally -and $n.Finally.Extent.Text.Contains("-RollbackIdentity")
},$true)
if($null -eq $guard){throw "缺少 durable outer finally"}
$body=$guard.Body.Extent.Text
foreach($marker in @(
    "No fake adapter auto-detected", "-CommitIdentity", "exit 25",
    "exit `$displayModeFailureCode", "& `$powershellExe @nvapiInstallArgs",
    "-CompleteIdentity `$identityTransactionId", "& `$powershellExe @nvapiFinalizeArgs"
)) { if(-not $body.Contains($marker)){throw ("outer transaction 未覆盖："+$marker)} }
' >/dev/null

# 跨组件提交顺序必须是 reader Install(receipt 保留) → pointer Commit →
# identity Complete → reader Finalize。前三步任何失败时，finally 必须先由仍兼容
# schema-1/2 的新 reader 承接旧 pointer，再恢复可能只懂旧 schema 的历史 DLL。
nvapi_install_line="$(rg -n -F '& $powershellExe @nvapiInstallArgs' "$APPLY_SCRIPT" | cut -d: -f1)"
commit_line="$(rg -n -F '& $identityHelperSource -CommitIdentity $identityTransactionId' "$APPLY_SCRIPT" | cut -d: -f1)"
complete_line="$(rg -n -F '& $identityHelperSource -CompleteIdentity $identityTransactionId' "$APPLY_SCRIPT" | cut -d: -f1)"
nvapi_finalize_line="$(rg -n -F '& $powershellExe @nvapiFinalizeArgs' "$APPLY_SCRIPT" | cut -d: -f1)"
nvapi_rollback_line="$(rg -n -F '& $powershellExe @nvapiRecoveryArgs' "$APPLY_SCRIPT" | cut -d: -f1)"
identity_rollback_line="$(rg -n -F -- '-RollbackIdentity $identityTransactionId' \
    "$APPLY_SCRIPT" | tail -1 | cut -d: -f1)"
[[ -n "$nvapi_install_line" && -n "$commit_line" && -n "$complete_line" && \
    -n "$nvapi_finalize_line" && "$nvapi_install_line" -lt "$commit_line" && \
    "$commit_line" -lt "$complete_line" && "$complete_line" -lt "$nvapi_finalize_line" ]] \
    || fail "生产 apply 未遵守 NVAPI Install → identity Commit/Complete → Finalize 顺序"
[[ -n "$nvapi_rollback_line" && -n "$identity_rollback_line" && \
    "$identity_rollback_line" -lt "$nvapi_rollback_line" ]] \
    || fail "apply finally 未在历史 NVAPI reader 之前恢复旧 identity pointer"
rg -F "throw ('系统 NVAPI 身份投影准备失败" "$APPLY_SCRIPT" >/dev/null \
    || fail "NVAPI Install 非零退出没有进入跨组件 finally"

recover_line="$(rg -n -F '& $identityHelperSource -RecoverPending' "$APPLY_SCRIPT" | cut -d: -f1)"
stage_line="$(rg -n -F '& $identityHelperSource -Stage -SpoofName' "$APPLY_SCRIPT" | cut -d: -f1)"
[[ -n "$recover_line" && -n "$stage_line" && "$recover_line" -lt "$stage_line" ]] \
    || fail "生产 apply 未保证 Recover/旧任务屏障先于 Stage"
legacy_preflight_line="$(rg -n -F '$oldIdentity = Get-PreviousIdentitySnapshot $configKey $oldPointer.Value' \
    "$PERSIST_SCRIPT" | cut -d: -f1)"
pending_publish_line="$(rg -n -F "SetValue('PendingIdentity', \$versionId" \
    "$PERSIST_SCRIPT" | cut -d: -f1)"
[[ -n "$legacy_preflight_line" && -n "$pending_publish_line" && \
    "$legacy_preflight_line" -lt "$pending_publish_line" ]] \
    || fail "Stage 未在发布 PendingIdentity 前预检旧 schema-1/schema-2 pointer"
commit_refresh_line="$(rg -n -F '& $refreshPath -StagedIdentityId $CommitIdentity' "$PERSIST_SCRIPT" | cut -d: -f1)"
commit_pointer_line="$(rg -n -F 'Set-CurrentIdentityPointer $configKey $expected $true' "$PERSIST_SCRIPT" | cut -d: -f1)"
commit_preflight_line="$(rg -n -F "throw 'Commit 投影前 CurrentIdentity 已偏离事务基线'" \
    "$PERSIST_SCRIPT" | cut -d: -f1)"
[[ -n "$commit_preflight_line" && -n "$commit_refresh_line" && -n "$commit_pointer_line" && \
    "$commit_preflight_line" -lt "$commit_refresh_line" && \
    "$commit_refresh_line" -lt "$commit_pointer_line" ]] \
    || fail "Commit 未按 pointer preflight → strict projection → CAS 顺序执行"
rg -F '$cfg = Invoke-WithProjectionLock {' "$REFRESH_SCRIPT" >/dev/null \
    || fail "standalone refresh 没有把读取和投影放进同一 mutex"
rg -F '$lockedConfig = Get-CurrentGpuIdentity' "$REFRESH_SCRIPT" >/dev/null \
    || fail "refresh mutex 内缺少严格 identity 读取"
rg -F 'Set-ActiveGpuProjection -Config $lockedConfig' "$REFRESH_SCRIPT" >/dev/null \
    || fail "refresh mutex 内缺少 active projection"

echo "OK: durable GPU identity transaction recovers crashes and injected faults"
