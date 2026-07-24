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
TRANSACTION_FIXTURE="$SCRIPT_DIR/fixtures/gpu_identity_transaction_fixture.ps1"
GPU_CASE_HELPER="$SCRIPT_DIR/fixtures/gpu_board_catalog_cases.ps1"
GPU_BOARDS="$REPO_ROOT/deploy/hardware/gpu-boards.json"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

command -v pwsh >/dev/null 2>&1 || fail "缺少 pwsh"
[[ -f "$LOCK_PROBE_HELPER" ]] || fail "缺少 identity mutex 并发测试 helper"
[[ -f "$TRANSACTION_FIXTURE" ]] || fail "缺少 identity transaction registry fixture"
[[ -f "$GPU_CASE_HELPER" ]] || fail "缺少离线 GPU 板卡测试 helper"
[[ -f "$GPU_BOARDS" ]] || fail "缺少离线 GPU 板卡目录"

# 把行数上限本身放进 quick 回归，避免后续又把 fixture/并发探针塞回主文件。
# 按项目规则只统计非空、非注释行；中文说明不占用 500 行代码预算。
for test_source in "$0" "$LOCK_PROBE_HELPER" "$TRANSACTION_FIXTURE" \
        "$GPU_CASE_HELPER"; do
    code_lines="$(awk '!/^[[:space:]]*($|#)/ { count++ } END { print count + 0 }' \
        "$test_source")"
    (( code_lines <= 500 )) || fail "$test_source 非注释代码行=$code_lines，超过 500"
done

TRANSACTION_SCRIPT="$TRANSACTION_SCRIPT" FIXTURE_HELPER="$TRANSACTION_FIXTURE" \
    REFRESH_SCRIPT="$REFRESH_SCRIPT" GPU_CASE_HELPER="$GPU_CASE_HELPER" \
    GPU_BOARDS="$GPU_BOARDS" \
    pwsh -NoLogo -NoProfile -NonInteractive -Command '
$ErrorActionPreference = "Stop"
. $env:TRANSACTION_SCRIPT

$script:nestedLockEntered = $false
Invoke-WithIdentityWriterLock {
    Invoke-WithIdentityWriterLock { $script:nestedLockEntered = $true }
}
if (-not $script:nestedLockEntered) { throw "同线程 named mutex 不可重入" }
. $env:FIXTURE_HELPER
. $env:GPU_CASE_HELPER

# 18 个 carrier 必须在 durable reader 中还原为各自逻辑主 ID/subsystem；
# 特别覆盖合法的 subsystem device=0000。任一字段串板都必须拒绝。
$aibCases = @(Get-TestGpuBoardCases $env:GPU_BOARDS)
Assert-TestGpuBoardCoverage $aibCases
$canonicalFields = @(
    "SpoofName", "SpoofVendor", "SpoofBios", "SpoofRamMb", "SpoofMemoryType",
    "SpoofMemoryBusWidthBits", "SpoofBaseClockKHz", "SpoofBoostClockKHz",
    "SpoofMemoryClockKHz", "SpoofSliSupported", "SpoofPciVendorId",
    "SpoofPciDeviceId", "SpoofSubsystemVendorId", "SpoofSubsystemDeviceId",
    "SpoofRevisionId"
)
$caseIndex = 0
foreach ($case in $aibCases) {
    $caseIndex++
    $id = ("{0:X32}" -f ([UInt64](0x1000 + $caseIndex)))
    $key = New-FakeRegistryKey
    $source = "PCI\VEN_1AF4&DEV_1050&SUBSYS_" + $case.Carrier +
        ("&REV_{0:X2}\3&AIB&0&30" -f $case.Revision)
    Set-CompleteIdentityValues $key $id 2 $source `
        $case.Name $true
    Set-AibIdentityValues $key $case
    $snapshot = Read-ValidatedIdentitySnapshot $key $id @(2)
    if ($snapshot.SpoofSubsystemVendorId -ne $case.SubVendor -or
        $snapshot.SpoofSubsystemDeviceId -ne $case.SubDevice) {
        throw ("AIB carrier 未保留 logical subsystem：" + $case.Carrier)
    }
    foreach ($field in $canonicalFields) {
        $original = $key.Values[$field]; $kind = $key.Kinds[$field]
        $mixed = if ($original -is [string]) { [string]$original + "-MIXED" }
            else { [int]$original + 1 }
        Set-FakeValue $key $field $mixed $kind
        $rejected = $false
        try { Read-ValidatedIdentitySnapshot $key $id @(2) | Out-Null }
        catch { $rejected = $true }
        if (-not $rejected) {
            throw ("AIB canonical 字段混搭未拒绝：" + $case.Carrier + "/" + $field)
        }
        Set-FakeValue $key $field $original $kind
    }
}

# 生产 refresh 的 staged reader 是 Commit 投影的首写门禁。schema-1 已不含完整
# AIB 原子 bundle，即使处于 Prepared 也必须在碰 Enum/Class/pointer 前拒绝。
$tokens = $null; $parseErrors = $null
$refreshAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $env:REFRESH_SCRIPT, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw "refresh AST parse failed" }
$readerAst = $refreshAst.Find({ param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -ceq "Get-CurrentGpuIdentity"
}, $true)
if ($null -eq $readerAst) { throw "refresh 缺少 staged identity reader" }
. ([scriptblock]::Create($readerAst.Extent.Text))
$script:fixture = New-TransactionFixture "B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0" `
    $true Prepared 1
$mutationsBefore = Get-FixtureMutationCount $script:fixture
$schema1CommitRejected = $false
try {
    Get-CurrentGpuIdentity -StagedId $script:fixture.IdentityId `
        -BaseKeyOverride $script:fixture.Base | Out-Null
} catch {
    $schema1CommitRejected = $_.Exception.Message.Contains(
        "暂存提交只接受 transaction schema-5")
}
if (-not $schema1CommitRejected -or
    (Get-FixtureMutationCount $script:fixture) -ne $mutationsBefore) {
    throw "schema-1 Prepared Commit 未在注册表首写前 fail-closed"
}

# 新 schema-5 receipt 必须用标准芯片名/厂商做展示字段 CAS，保留 stock
# MatchingDeviceId，并用 2047 MiB legacy 值表达精确 4 GiB。identity mirror
# 继续保留完整 AIB 标签。模拟 pointer 已提交后被 kill，并凭持久 receipt 恢复。
$script:fixture = New-TransactionFixture "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB" $true Committed
function Open-StealthBaseKey { return $script:fixture.Base }
function Invoke-LegacyGpuTaskBarrier {}
$receipt = Read-TransactionReceipt $script:fixture.Config $script:fixture.IdentityId
if ([int]$receipt.PreviousIdentitySchemaVersion -ne 2) {
    throw "schema-2 PreviousIdentity 未走严格原路径"
}
if ([string]$receipt.ProjectedEnum.FriendlyName.Value -cne `
        "NVIDIA GeForce GTX 1050 Ti" -or
    [string]$receipt.ProjectedEnum.DeviceDesc.Value -cne `
        "NVIDIA GeForce GTX 1050 Ti" -or
    [string]$receipt.ProjectedEnum.Mfg.Value -cne "NVIDIA" -or
    [string]$receipt.ProjectedClass.DriverDesc.Value -cne `
        "NVIDIA GeForce GTX 1050 Ti" -or
    [string]$receipt.ProjectedClass.ProviderName.Value -cne "NVIDIA" -or
    [string]$receipt.ProjectedClass.MatchingDeviceId.Value -cne `
        "PCI\VEN_1AF4&DEV_1050" -or
    [string]$receipt.ProjectedClass["HardwareInformation.AdapterString"].Value -cne `
        "NVIDIA GeForce GTX 1050 Ti" -or
    [string]$receipt.ProjectedClass["HardwareInformation.ChipType"].Value -cne `
        "GeForce GTX 1050 Ti" -or
    [string]$receipt.NewSpoofName -cne `
        "NVIDIA GeForce GTX 1050 Ti (ASUS Phoenix)") {
    throw "schema-5 display-only hybrid 与 AIB identity mirror 没有分层"
}
$legacyMemory = [byte[]]$receipt.ProjectedClass[
    "HardwareInformation.MemorySize"].Value
if (-not (Test-RegistryDataEqual $legacyMemory ([byte[]](0,0,240,127))) -or
    [UInt64]$receipt.ProjectedClass[
        "HardwareInformation.qwMemorySize"].Value -ne [UInt64]4294967296) {
    throw "schema-5 未按 2047 MiB legacy + 精确 QWord 投影 4 GiB"
}
$result = Invoke-RecoverOrRollback -Recover
if ($result.Action -cne "RolledBack") { throw "kill 后 Recover 没有执行 rollback" }
Assert-RolledBack $script:fixture
if ($null -ne (Invoke-RecoverOrRollback -Recover)) { throw "Recover 不是幂等操作" }

# schema-4 已采用完整标准展示字段，但其 legacy MemorySize 上限为
# 4095 MiB。新版 reader 必须精确重建旧值，否则中断事务无法通过 CAS 恢复。
$script:fixture = New-TransactionFixture "B4B4B4B4B4B4B4B4B4B4B4B4B4B4B4B4" `
    $true Committed 4
$receipt = Read-TransactionReceipt $script:fixture.Config $script:fixture.IdentityId
if (-not (Test-RegistryDataEqual `
        ([byte[]]$receipt.ProjectedClass["HardwareInformation.MemorySize"].Value) `
        ([byte[]](0,0,240,255))) -or
    [UInt64]$receipt.ProjectedClass[
        "HardwareInformation.qwMemorySize"].Value -ne [UInt64]4294967296) {
    throw "schema-4 历史 4095 MiB/QWord 投影语义未保留"
}
$result = Invoke-RecoverOrRollback -Recover
if ($result.Action -cne "RolledBack") { throw "schema-4 legacy transaction 未恢复" }
Assert-RolledBack $script:fixture

# schema-3 已使用标准 FriendlyName，但其安装展示字段仍是 stock，4 GiB
# MemorySize 仍按历史 low32=0。新版恢复必须精确重建该旧投影。
$script:fixture = New-TransactionFixture "B3B3B3B3B3B3B3B3B3B3B3B3B3B3B3B3" `
    $true Committed 3
$receipt = Read-TransactionReceipt $script:fixture.Config $script:fixture.IdentityId
if ([string]$receipt.ProjectedEnum.FriendlyName.Value -cne `
        "NVIDIA GeForce GTX 1050 Ti" -or
    [string]$receipt.ProjectedEnum.DeviceDesc.Value -cne `
        "@oem3.inf,%viogpudod.devicedesc%;Red Hat VirtIO GPU DOD controller" -or
    [string]$receipt.ProjectedClass.DriverDesc.Value -cne `
        "Red Hat VirtIO GPU DOD controller" -or
    -not (Test-RegistryDataEqual `
        ([byte[]]$receipt.ProjectedClass["HardwareInformation.MemorySize"].Value) `
        ([byte[]](0,0,0,0))) -or
    [UInt64]$receipt.ProjectedClass[
        "HardwareInformation.qwMemorySize"].Value -ne [UInt64]4294967296) {
    throw "schema-3 历史显示/low32 投影语义未保留"
}
$result = Invoke-RecoverOrRollback -Recover
if ($result.Action -cne "RolledBack") { throw "schema-3 legacy transaction 未恢复" }
Assert-RolledBack $script:fixture

# schema-2 transaction 把完整 AIB 标签写进展示字段；恢复也必须保留其
# 历史 4 GiB low32=0 语义，不能按 schema-5 重建。
$script:fixture = New-TransactionFixture "B2B2B2B2B2B2B2B2B2B2B2B2B2B2B2B2" `
    $true Committed 2
$receipt = Read-TransactionReceipt $script:fixture.Config $script:fixture.IdentityId
if ([string]$receipt.ProjectedEnum.FriendlyName.Value -cne `
        "NVIDIA GeForce GTX 1050 Ti (ASUS Phoenix)" -or
    [string]$receipt.ProjectedClass["HardwareInformation.ChipType"].Value -cne `
        "GeForce GTX 1050 Ti (ASUS Phoenix)" -or
    -not (Test-RegistryDataEqual `
        ([byte[]]$receipt.ProjectedClass["HardwareInformation.MemorySize"].Value) `
        ([byte[]](0,0,0,0))) -or
    [UInt64]$receipt.ProjectedClass[
        "HardwareInformation.qwMemorySize"].Value -ne [UInt64]4294967296) {
    throw "schema-2 legacy 投影语义未保留"
}
$result = Invoke-RecoverOrRollback -Recover
if ($result.Action -cne "RolledBack") { throw "schema-2 legacy transaction 未恢复" }
Assert-RolledBack $script:fixture

# schema-1 receipt 同样必须按历史 low32=0 恢复，不能套用 schema-5 饱和值。
$script:fixture = New-TransactionFixture "B1B0B1B0B1B0B1B0B1B0B1B0B1B0B1B0" `
    $true Committed 1
$receipt = Read-TransactionReceipt $script:fixture.Config $script:fixture.IdentityId
if (-not (Test-RegistryDataEqual `
        ([byte[]]$receipt.ProjectedClass["HardwareInformation.MemorySize"].Value) `
        ([byte[]](0,0,0,0))) -or
    [UInt64]$receipt.ProjectedClass[
        "HardwareInformation.qwMemorySize"].Value -ne [UInt64]4294967296) {
    throw "schema-1 历史 low32/QWord 投影语义未保留"
}
$result = Invoke-RecoverOrRollback -Recover
if ($result.Action -cne "RolledBack") { throw "schema-1 transaction 未恢复" }
Assert-RolledBack $script:fixture

# 未知 transaction schema 必须在 pointer、journal 和投影首写前拒绝。
$script:fixture = New-TransactionFixture "B6B6B6B6B6B6B6B6B6B6B6B6B6B6B6B6" `
    $true Prepared 6
Assert-RecoveryRejectedWithoutMutation $script:fixture `
    "未知 transaction schema 未安全拒绝"

# 旧 schema-1 不再具备完整 AIB 原子 bundle，必须在 pointer/journal 首写前拒绝。
$script:fixture = New-TransactionFixture "B1B1B1B1B1B1B1B1B1B1B1B1B1B1B1B1" $true Prepared
Set-LegacyPreviousIdentity $script:fixture $true
Assert-RecoveryRejectedWithoutMutation $script:fixture `
    "完整旧 schema-1 身份未 fail-closed"

# 未知 schema、错误类型/自 ID 及 previous marker 不一致也必须拒绝。
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
$script:fixture = New-TransactionFixture "A2A2A2A2A2A2A2A2A2A2A2A2A2A2A2A2" $true Prepared
Set-FakeValue $script:fixture.Transaction PreviousIdentitySchemaVersion 1 `
    ([Microsoft.Win32.RegistryValueKind]::DWord)
Assert-RecoveryRejectedWithoutMutation $script:fixture "previous schema marker 与快照不一致未拒绝"
$script:fixture = New-TransactionFixture "A3A3A3A3A3A3A3A3A3A3A3A3A3A3A3A3" $true Prepared
Set-FakeValue $script:fixture.Transaction PreviousIdentitySchemaVersion "2" `
    ([Microsoft.Win32.RegistryValueKind]::String)
Assert-RecoveryRejectedWithoutMutation $script:fixture "previous schema marker 类型错误未拒绝"
$script:fixture = New-TransactionFixture "A5A5A5A5A5A5A5A5A5A5A5A5A5A5A5A5" $false Prepared
Set-FakeValue $script:fixture.Transaction PreviousIdentitySchemaVersion 2 `
    ([Microsoft.Win32.RegistryValueKind]::DWord)
Assert-RecoveryRejectedWithoutMutation $script:fixture "无 previous pointer 却接受 schema marker"

# schema-2 必须执行严格原路径，不能省略或放宽 IdentityId。
$script:fixture = New-TransactionFixture "ACACACACACACACACACACACACACACACAC" $true Prepared
[void]$script:fixture.OldIdentity.Values.Remove("IdentityId")
[void]$script:fixture.OldIdentity.Kinds.Remove("IdentityId")
Assert-RecoveryRejectedWithoutMutation $script:fixture "schema-2 缺少自 ID 未拒绝"
$script:fixture = New-TransactionFixture "AFAFAFAFAFAFAFAFAFAFAFAFAFAFAFAF" $true Prepared
Set-FakeValue $script:fixture.OldIdentity IdentityId `
    "BFBFBFBFBFBFBFBFBFBFBFBFBFBFBFBF" ([Microsoft.Win32.RegistryValueKind]::String)
Assert-RecoveryRejectedWithoutMutation $script:fixture "schema-2 错误自 ID 未拒绝"
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
    [string]$script:fixture.Enum.Values.FriendlyName -cne `
        "NVIDIA GeForce GTX 1050 Ti") {
    throw "Completed-before-clear 恢复语义错误"
}

# 非本事务 pointer 必须在 journal 写入前被 CAS 门禁拒绝。
$script:fixture = New-TransactionFixture "DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD" $true Committed
Set-FakeValue $script:fixture.Config CurrentIdentity "EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE" `
    ([Microsoft.Win32.RegistryValueKind]::String)
$rejected = $false
try { Invoke-RecoverOrRollback -Recover | Out-Null } catch { $rejected = $true }
if (-not $rejected -or [string]$script:fixture.Enum.Values.FriendlyName -cne `
    "NVIDIA GeForce GTX 1050 Ti") {
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
    [string]$script:fixture.Class.Values.DriverDesc -cne
        "NVIDIA GeForce GTX 1050 Ti") {
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
    [string]$script:fixture.Enum.Values.DeviceDesc -cne
        "NVIDIA GeForce GTX 1050 Ti") {
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
    "Resolve-GpuSpoofActiveClassSubkey", "-CommitIdentity", "exit 25",
    "exit `$displayModeFailureCode", "& `$powershellExe @gpuApiInstallArgs",
    "-CompleteIdentity `$identityTransactionId", "& `$powershellExe @gpuApiFinalizeArgs"
)) { if(-not $body.Contains($marker)){throw ("outer transaction 未覆盖："+$marker)} }
' >/dev/null

# 跨组件提交顺序必须是 GPU API coordinator Install(receipt 保留) → pointer Commit →
# identity Complete → reader Finalize。前三步任何失败时，finally 必须先由严格
# schema-2 reader 承接旧 pointer，再恢复 GPU API 投影。
gpu_api_install_line="$(rg -n -F '& $powershellExe @gpuApiInstallArgs' "$APPLY_SCRIPT" | cut -d: -f1)"
commit_line="$(rg -n -F '& $identityHelperSource -CommitIdentity $identityTransactionId' "$APPLY_SCRIPT" | cut -d: -f1)"
complete_line="$(rg -n -F '& $identityHelperSource -CompleteIdentity $identityTransactionId' "$APPLY_SCRIPT" | cut -d: -f1)"
gpu_api_finalize_line="$(rg -n -F '& $powershellExe @gpuApiFinalizeArgs' "$APPLY_SCRIPT" | cut -d: -f1)"
gpu_api_rollback_line="$(rg -n -F '& $powershellExe @gpuApiRecoveryArgs' "$APPLY_SCRIPT" | cut -d: -f1)"
identity_rollback_line="$(rg -n -F -- '-RollbackIdentity $identityTransactionId' \
    "$APPLY_SCRIPT" | tail -1 | cut -d: -f1)"
[[ -n "$gpu_api_install_line" && -n "$commit_line" && -n "$complete_line" && \
    -n "$gpu_api_finalize_line" && "$gpu_api_install_line" -lt "$commit_line" && \
    "$commit_line" -lt "$complete_line" && "$complete_line" -lt "$gpu_api_finalize_line" ]] \
    || fail "生产 apply 未遵守 GPU API Install → identity Commit/Complete → Finalize 顺序"
[[ -n "$gpu_api_rollback_line" && -n "$identity_rollback_line" && \
    "$identity_rollback_line" -lt "$gpu_api_rollback_line" ]] \
    || fail "apply finally 未在历史 GPU API readers 之前恢复旧 identity pointer"
rg -F "throw ('系统 GPU API 身份投影准备失败" "$APPLY_SCRIPT" >/dev/null \
    || fail "GPU API coordinator Install 非零退出没有进入跨组件 finally"
rg -F '$gpuApiCleanupDeferredExitCode = 12' "$APPLY_SCRIPT" >/dev/null \
    || fail "apply 缺少 GPU API cleanup deferred 稳定退出码"
for cleanup_code in recoverGpuApiCode gpuApiInstallCode gpuApiFinalizeCode; do
    rg -F "if (\$$cleanup_code -eq \$gpuApiCleanupDeferredExitCode)" \
        "$APPLY_SCRIPT" >/dev/null \
        || fail "apply 没有原样中继 GPU API cleanup deferred：$cleanup_code"
done

recover_line="$(rg -n -F '& $identityHelperSource -RecoverPending' "$APPLY_SCRIPT" | cut -d: -f1)"
stage_line="$(rg -n -F '& $identityHelperSource -Stage -SpoofName' "$APPLY_SCRIPT" | cut -d: -f1)"
[[ -n "$recover_line" && -n "$stage_line" && "$recover_line" -lt "$stage_line" ]] \
    || fail "生产 apply 未保证 Recover/旧任务屏障先于 Stage"
old_preflight_line="$(rg -n -F '$oldIdentity = Get-PreviousIdentitySnapshot $configKey $oldPointer.Value' \
    "$PERSIST_SCRIPT" | cut -d: -f1)"
pending_publish_line="$(rg -n -F "SetValue('PendingIdentity', \$versionId" \
    "$PERSIST_SCRIPT" | cut -d: -f1)"
[[ -n "$old_preflight_line" && -n "$pending_publish_line" && \
    "$old_preflight_line" -lt "$pending_publish_line" ]] \
    || fail "Stage 未在发布 PendingIdentity 前严格预检旧 pointer"
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
