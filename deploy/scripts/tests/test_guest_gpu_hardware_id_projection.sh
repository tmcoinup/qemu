#!/usr/bin/env bash
# 验证单一 devnode 的逻辑首项 + 物理尾项投影、回滚与正式 guest 编排。
# shellcheck disable=SC2016
# 单引号中的 `$` 属于待执行 PowerShell 或源码契约，不能由 Bash 提前展开。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PLAN="$REPO_ROOT/deploy/scripts/gpu-hardware-id-plan.ps1"
PROJECTOR="$REPO_ROOT/deploy/scripts/project-gpu-hardware-id.ps1"
PROJECTION_TRANSACTION="$REPO_ROOT/deploy/scripts/gpu-hardware-id-transaction.ps1"
TRANSACTION="$REPO_ROOT/deploy/scripts/gpu-profile-transaction.ps1"
APPLY="$REPO_ROOT/deploy/scripts/apply-gpu-spoof.ps1"
RESPAWN="$REPO_ROOT/deploy/guest-stealth/respawn-stealth-local.ps1"
RESTART_HELPER="$REPO_ROOT/deploy/guest-stealth/respawn-restart-state.ps1"
BUILD="$REPO_ROOT/deploy/guest-stealth/build-exe.sh"
PACKAGE="$REPO_ROOT/deploy/guest-stealth/package.sh"
LAUNCHER="$REPO_ROOT/deploy/guest-stealth/launcher/respawn-stealth-launcher.c"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

for path in "$PLAN" "$PROJECTOR" "$PROJECTION_TRANSACTION" "$TRANSACTION" \
        "$APPLY" "$RESPAWN" "$BUILD" \
        "$RESTART_HELPER" "$PACKAGE" "$LAUNCHER"; do
    [[ -f "$path" ]] || fail "缺少 HardwareID 投影链文件: $path"
done
for path in "$PLAN" "$PROJECTOR" "$PROJECTION_TRANSACTION" "$RESPAWN" \
        "$RESTART_HELPER"; do
    [[ "$(xxd -p -l 3 "$path")" == 'efbbbf' ]] \
        || fail "Windows PowerShell 中文脚本缺少 UTF-8 BOM: $path"
done

# 规划 helper 完全无副作用，可以直接在 Linux pwsh 中加载并覆盖精确数组契约。
PLAN="$PLAN" pwsh -NoLogo -NoProfile -NonInteractive -Command '
$ErrorActionPreference = "Stop"
. $env:PLAN

function Assert-ExactArray {
    param([string[]]$Actual, [string[]]$Expected, [string]$Label)
    if (-not (Test-StringArrayEqual $Actual $Expected)) {
        throw ($Label + ": actual=" + ($Actual -join "|") +
            "; expected=" + ($Expected -join "|"))
    }
}

$physical = @(
    "PCI\VEN_1AF4&DEV_1050&SUBSYS_A1021AF4&REV_A1",
    "PCI\VEN_1AF4&DEV_1050&SUBSYS_A1021AF4",
    "PCI\VEN_1AF4&DEV_1050&CC_030000",
    "PCI\VEN_1AF4&DEV_1050&CC_0300"
)
$nvidia = @(Get-ProjectedHardwareIds -OriginalIds $physical `
    -VendorId 0x10DE -DeviceId 0x1C82 -SubsystemVendorId 0x7377 `
    -SubsystemDeviceId 0x0000 -RevisionId 0xA1)
$expectedNvidia = @(
    "PCI\VEN_10DE&DEV_1C82&SUBSYS_00007377&REV_A1"
) + $physical
Assert-ExactArray $nvidia $expectedNvidia "A102 Colorful GTX 1050 Ti fake-first"
if ($nvidia.Count -ne $physical.Count + 1) {
    throw "projector 生成了多余 logical ID"
}

$a10cPhysical = @(
    "PCI\VEN_1AF4&DEV_1050&SUBSYS_A10C1AF4&REV_A1",
    "PCI\VEN_1AF4&DEV_1050&SUBSYS_A10C1AF4"
)
$a10c = @(Get-ProjectedHardwareIds $a10cPhysical 0x10DE 0x1C82 0x1458 0x3763 0xA1)
$expectedA10c = @("PCI\VEN_10DE&DEV_1C82&SUBSYS_37631458&REV_A1") + $a10cPhysical
Assert-ExactArray $a10c $expectedA10c "A10C Gigabyte GTX 1050 Ti fake-first"

$recovered = @(Get-OriginalIdsFromExistingProjection $nvidia 0x10DE 0x1C82 0x7377 0 0xA1)
Assert-ExactArray $recovered $physical "现场投影反推物理数组"
$legacyNvidia = @("PCI\VEN_10DE&DEV_1C82&SUBSYS_A1021AF4&REV_A1") + $physical
$recoveredLegacy = @(Get-OriginalIdsFromExistingProjection $legacyNvidia `
    0x10DE 0x1C82 0x7377 0 0xA1)
Assert-ExactArray $recoveredLegacy $physical "旧 A10x 首项迁移反推物理数组"
if (@(Get-OriginalIdsFromExistingProjection $nvidia 0x1002 0x67FF 0x1DA2 0xE348 0xCF).Count -ne 0) {
    throw "无备份时错误接管了其他 profile 的 fake-first 数组"
}

$duplicatePhysical = @($physical[0], $physical[0], $physical[1])
$duplicateProjected = @(Get-ProjectedHardwareIds $duplicatePhysical `
    0x10DE 0x1C82 0x7377 0 0xA1)
Assert-ExactArray @($duplicateProjected[1..3]) $duplicatePhysical `
    "物理数组重复项和顺序"

foreach ($bad in @(
    @("PCI\VEN_1AF4&DEV_1050&SUBSYS_1C8210DE", "PCI\CC_0300"),
    @("PCI\VEN_10DE&DEV_1C82&SUBSYS_1C8210DE"),
    @(""),
    @("PCI\VEN_1AF4&DEV_10500&SUBSYS_1C8210DE"),
    @("PCI\VEN_1AF4&DEV_1050BAD&SUBSYS_1C8210DE"),
    @("PCI\VEN_1AF4&DEV_1050" + [char]0)
)) {
    $rejected = $false
    try { Get-ProjectedHardwareIds $bad 0x10DE 0x1C82 0x7377 0 0xA1 | Out-Null }
    catch { $rejected = $true }
    if (-not $rejected) { throw ("异常物理数组未被拒绝: " + ($bad -join "|")) }
}
if (Test-StringArrayEqual @("ABC") @("abc")) {
    throw "绑定契约比较错误忽略了大小写变化"
}
' >/dev/null || fail "HardwareID 规划纯函数测试失败"

# 提取正式 Restore/Rollback 状态机，用内存 mock 覆盖无备份迁移、既有备份、
# physical no-op 与未知布局拒绝，不需要在 Linux 测试机访问 Windows 注册表。
PLAN="$PLAN" PROJECTOR="$PROJECTOR" \
PROJECTION_TRANSACTION="$PROJECTION_TRANSACTION" \
pwsh -NoLogo -NoProfile -NonInteractive -Command '
$ErrorActionPreference = "Stop"
. $env:PLAN
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $env:PROJECTOR, [ref]$tokens, [ref]$errors)
foreach ($functionName in @("Test-BackupAllowsCurrentIds",
        "Invoke-ProjectionRollback", "Invoke-RestorePhysical")) {
    $functionAst = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $functionName
    }, $true)
    if ($null -eq $functionAst) { throw ("缺少生产函数：" + $functionName) }
    . ([scriptblock]::Create($functionAst.Extent.Text))
}
$transactionAst = [Management.Automation.Language.Parser]::ParseFile(
    $env:PROJECTION_TRANSACTION, [ref]$tokens, [ref]$errors)
foreach ($functionName in @("Assert-SameProjectionIdentity",
        "Get-ExpectedProjectionIds", "Invoke-ProjectionApply",
        "Invoke-ProjectionVerify")) {
    $functionAst = $transactionAst.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $functionName
    }, $true)
    if ($null -eq $functionAst) { throw ("缺少生产事务函数：" + $functionName) }
    . ([scriptblock]::Create($functionAst.Extent.Text))
}

$physicalPattern = "^PCI\\VEN_1AF4&DEV_1050(?:&|$)"
$physical = @(
    "PCI\VEN_1AF4&DEV_1050&SUBSYS_A1021AF4&REV_A1",
    "PCI\VEN_1AF4&DEV_1050&SUBSYS_A1021AF4"
)
$canonical = @(Get-ProjectedHardwareIds $physical 0x10DE 0x1C82 0x7377 0 0xA1)
$legacy = @("PCI\VEN_10DE&DEV_1C82&SUBSYS_A1021AF4&REV_A1") + $physical
$identity = [pscustomobject]@{
    IdentityId="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    SourceInstanceId=($physical[0] + "\3&11583659&0&30")
    SpoofPciVendorId=0x10DE
    SpoofPciDeviceId=0x1C82
    SpoofSubsystemVendorId=0x7377
    SpoofSubsystemDeviceId=0
    SpoofRevisionId=0xA1
}
$backupFixture = [pscustomobject]@{
    RelativePath="SOFTWARE\StealthGPU\HardwareIdProjections\MOCK"
    OriginalHardwareIds=[string[]]@($physical)
    AppliedHardwareIds=[string[]]@($canonical)
    PendingHardwareIds=[string[]]@()
    OriginalCompatibleIds=[string[]]@("PCI\VEN_1AF4&DEV_1050")
    OriginalService="VioGpuDod"
    OriginalDriver="{4d36e968-e325-11ce-bfc1-08002be10318}\0001"
    IdentityId="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    TransactionState="Applied"
}
class MockBaseKey {
    static [int]$DeleteCalls = 0
    [void] DeleteSubKeyTree([string]$Path, [bool]$ThrowOnMissing) {
        [MockBaseKey]::DeleteCalls++
    }
}

function Reset-Scenario {
    param([string[]]$Ids, $Backup)
    $script:CurrentIds = [string[]]@($Ids)
    $script:ScenarioBackup = $Backup
    $script:HardwareWrites = 0
    $script:BackupWrites = 0
    $script:IncompleteChecks = 0
    [MockBaseKey]::DeleteCalls = 0
}
function Get-StrictIdentity { return $identity }
function Remove-IncompleteBackupIfRecoverable($BaseKey, $Target, $Identity) {
    $script:IncompleteChecks++
}
function Get-ProjectionBackup($BaseKey, $InstanceId) { return $script:ScenarioBackup }
function Assert-PresentProjectionTarget($InstanceId) {}
function Set-ProjectionBackupState {
    param($BaseKey, $Target, [string[]]$OriginalIds, [string[]]$AppliedIds,
        [string[]]$PendingIds, [string]$IdentityId, [string]$State)
    $script:BackupWrites++
}
function Get-TargetRegistryState($BaseKey, $InstanceId) {
    return [pscustomobject]@{
        InstanceId=$InstanceId
        RelativePath="mock"
        Service="VioGpuDod"
        Driver="{4d36e968-e325-11ce-bfc1-08002be10318}\0001"
        CompatibleIds=@("PCI\VEN_1AF4&DEV_1050")
        HardwareIds=[string[]]@($script:CurrentIds)
    }
}
function Assert-BindingUnchanged($Before, $After) {
    if ($Before.Service -cne $After.Service -or $Before.Driver -cne $After.Driver -or
        -not (Test-StringArrayEqual $Before.CompatibleIds $After.CompatibleIds)) {
        throw "mock binding changed"
    }
}
function Set-TargetHardwareIds($BaseKey, $Target, [string[]]$HardwareIds) {
    $script:HardwareWrites++
    $script:CurrentIds = [string[]]@($HardwareIds)
}

$dummyBaseKey = [MockBaseKey]::new()

Reset-Scenario $physical $null
Invoke-ProjectionApply $dummyBaseKey
if ($script:HardwareWrites -ne 1 -or $script:BackupWrites -ne 2 -or
    -not (Test-StringArrayEqual $script:CurrentIds $canonical)) {
    throw "physical -> canonical fake-first 事务错误"
}

Reset-Scenario $canonical $backupFixture
Invoke-ProjectionApply $dummyBaseKey
if ($script:HardwareWrites -ne 0 -or $script:BackupWrites -ne 0) {
    throw "已投影状态没有保持 HardwareID/backup 零写"
}
Invoke-ProjectionVerify $dummyBaseKey

Reset-Scenario $physical $null
Invoke-RestorePhysical $dummyBaseKey
if ($script:HardwareWrites -ne 0 -or [MockBaseKey]::DeleteCalls -ne 0 -or
    $script:IncompleteChecks -ne 1) {
    throw "physical-only 状态没有保持零写"
}

foreach ($oldProjection in @($canonical, $legacy)) {
    Reset-Scenario $oldProjection $null
    Invoke-RestorePhysical $dummyBaseKey
    if ($script:HardwareWrites -ne 1 -or [MockBaseKey]::DeleteCalls -ne 0 -or
        -not (Test-StringArrayEqual $script:CurrentIds $physical)) {
        throw "无备份旧逻辑首项没有恢复为 physical-only"
    }
}

Reset-Scenario (@("PCI\VEN_10DE&DEV_1C82&SUBSYS_DEAD1458&REV_A1") + $physical) $null
$failed = $false
try { Invoke-RestorePhysical $dummyBaseKey } catch { $failed = $true }
if (-not $failed -or $script:HardwareWrites -ne 0 -or [MockBaseKey]::DeleteCalls -ne 0) {
    throw "未知逻辑首项没有 fail-closed"
}

Reset-Scenario $canonical $backupFixture
Invoke-RestorePhysical $dummyBaseKey
if ($script:HardwareWrites -ne 1 -or [MockBaseKey]::DeleteCalls -ne 1 -or
    -not (Test-StringArrayEqual $script:CurrentIds $physical)) {
    throw ("正式备份没有通过 Rollback 恢复并删除：writes=" +
        $script:HardwareWrites + "; deletes=" + [MockBaseKey]::DeleteCalls +
        "; ids=" + ($script:CurrentIds -join "|"))
}

Reset-Scenario $physical $backupFixture
Invoke-RestorePhysical $dummyBaseKey
if ($script:HardwareWrites -ne 0 -or [MockBaseKey]::DeleteCalls -ne 1) {
    throw "已恢复的正式备份没有零写清理"
}

$thirdPartyPhysical = @(
    "PCI\VEN_1AF4&DEV_1050&SUBSYS_DEAD1AF4&REV_A1",
    "PCI\VEN_1AF4&DEV_1050&SUBSYS_DEAD1AF4"
)
Reset-Scenario $thirdPartyPhysical $backupFixture
$failed = $false
try { Invoke-RestorePhysical $dummyBaseKey } catch { $failed = $true }
if (-not $failed -or $script:HardwareWrites -ne 0 -or [MockBaseKey]::DeleteCalls -ne 0) {
    throw "备份存在时第三方 HardwareID 没有 fail-closed"
}
' >/dev/null || fail "HardwareID Restore/Rollback 状态机测试失败"

# projector 是唯一获准直接写 GPU Enum HardwareID 的文件；事务 helper 只能
# 调用唯一 writer，其他绑定字段只能读取和逐字复核。
hardware_write_count="$(rg -c -F "SetValue('HardwareID'" "$PROJECTOR")"
[[ "$hardware_write_count" -eq 1 ]] \
    || fail "projector 的 HardwareID 注册表写点不是唯一一个"
for forbidden_value in CompatibleIDs Service Driver; do
    if rg -F "SetValue('$forbidden_value'" "$PROJECTOR" >&2; then
        fail "projector 不得写 $forbidden_value"
    fi
done
rg -F 'Set-TargetHardwareIds $BaseKey $target $backup.OriginalHardwareIds' \
    "$PROJECTOR" >/dev/null || fail "正式备份回滚没有写回物理原数组"
rg -F 'Set-TargetHardwareIds $BaseKey $target $originalIds' \
    "$PROJECTOR" >/dev/null || fail "无备份迁移没有写回反推的物理原数组"
rg -F '& $identityReader -ReadIdentityOnly' "$PROJECTOR" >/dev/null \
    || fail "projector 没有使用严格 CurrentIdentity reader"
if rg -F 'AllowMissing' "$PROJECTOR" >&2; then
    fail "projector 不得回退到宽松身份读取"
fi
for mode in Apply Verify RestorePhysical Rollback; do
    rg -F "'$mode'" "$PROJECTOR" >/dev/null \
        || fail "projector 缺少模式: $mode"
done
for function_name in Invoke-ProjectionApply Invoke-ProjectionVerify \
        Set-ProjectionBackupState; do
    rg -F "function $function_name" "$PROJECTION_TRANSACTION" >/dev/null \
        || fail "投影事务 helper 缺少：$function_name"
done
# 投影工具和正式 identity writer 必须共享同名 mutex，避免投影与
# pointer/HardwareID writer 并发。
rg -F "New-Object Threading.Mutex(\$false, 'Global\StealthGPU-IdentityWriter')" \
    "$PROJECTOR" >/dev/null || fail "projector 没有使用 GPU 身份共享写锁"
rg -F "New-Object System.Threading.Mutex(\$false, 'Global\StealthGPU-IdentityWriter')" \
    "$TRANSACTION" >/dev/null || fail "identity transaction 没有使用共享写锁"
rg -F "[string]\$Mode = 'Apply'" "$PROJECTOR" >/dev/null \
    || fail "HardwareID projector 默认模式不是 Apply"
if rg -F 'StealthGPU-HardwareIdProjection' "$PROJECTOR" >&2; then
    fail "projector 仍保留独立 mutex，无法与 identity writer 串行"
fi

# 宿主离线 DEVPKEY helper 只能是特定 Driver-tab 字段的可选诊断，不得在
# guest 浅层一键成功路径中继续显示红色“必做”。同时保留可搜索的诊断入口。
rg -F 'no host-side offline fix is required' "$APPLY" >/dev/null \
    || fail "apply 没有明确浅层一键流程不需要 host 离线修复"
rg -F 'Optional diagnostic only:' "$APPLY" >/dev/null \
    || fail "apply 没有保留 legacy Driver Provider 可选诊断说明"
if rg -F 'NEXT STEP (required!)' "$APPLY" >&2; then
    fail "apply 仍把 host-fix 误报为必做后续步骤"
fi

# 用 AST 只看实际命令名，避免 block comment 中的禁止词造成误报。
PROJECTOR="$PROJECTOR" pwsh -NoLogo -NoProfile -NonInteractive -Command '
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $env:PROJECTOR, [ref]$tokens, [ref]$errors)
$forbidden = @(
    "pnputil.exe", "devcon.exe", "Enable-PnpDevice", "Disable-PnpDevice",
    "Invoke-WebRequest", "Invoke-RestMethod", "New-Service", "Start-Process"
)
foreach ($command in $ast.FindAll({
        param($node) $node -is [Management.Automation.Language.CommandAst]
    }, $true)) {
    $name = $command.GetCommandName()
    if ($null -ne $name -and $forbidden -icontains $name) {
        throw ("projector 出现禁止命令: " + $name)
    }
}
' >/dev/null || fail "projector 引入 PnP 重扫、网络、服务或应用专用命令"

# 正式顺序：驱动/PnP 前停 writer 并恢复 physical-only；GPU API Finalize 成功后，
# 再做 fake-first Apply -> 最终态 runtime probe -> Verify -> 注册持久任务。
power_line="$(rg -n -F '& $powershellExe @powerArgs' "$RESPAWN" | cut -d: -f1)"
restore_line="$(rg -n -F "'-Mode', 'RestorePhysical'" "$RESPAWN" | head -1 | cut -d: -f1)"
physical_preflight_line="$(rg -n -F 'if (Test-PhysicalDisplayHardwareIds)' \
    "$RESPAWN" | cut -d: -f1)"
physical_gate_line="$(rg -n -F '    Assert-PhysicalDisplayHardwareIds' \
    "$RESPAWN" | cut -d: -f1)"
driver_line="$(rg -n -F '& $powershellExe @driverArgs' "$RESPAWN" | cut -d: -f1)"
spoof_line="$(rg -n -F '& $powershellExe @spoofArgs' "$RESPAWN" | cut -d: -f1)"
publish_line="$(rg -n -F '$persistentProjector = Publish-GpuIdentityPayload' \
    "$RESPAWN" | cut -d: -f1)"
finalization_line="$(rg -n -F 'Invoke-GpuProjectionFinalization' \
    "$RESPAWN" | cut -d: -f1)"
[[ -n "$power_line" && -n "$physical_preflight_line" && -n "$restore_line" && \
    -n "$physical_gate_line" && -n "$driver_line" && -n "$publish_line" && \
    -n "$spoof_line" && -n "$finalization_line" ]] \
    || fail "无法定位 HardwareID 正式执行顺序"
(( power_line < physical_preflight_line && physical_preflight_line < restore_line && \
    restore_line < physical_gate_line && physical_gate_line < publish_line && \
    publish_line < driver_line && driver_line < spoof_line && \
    spoof_line < finalization_line )) \
    || fail "physical-only 门禁或最终投影顺序错误"
preflight_body="$(sed -n '/^if (Test-PhysicalDisplayHardwareIds) {/,/^try {$/p' \
    "$RESPAWN")"
[[ "$preflight_body" == *'} elseif (Test-CurrentGpuIdentityExists) {'* &&
   "$preflight_body" == *"'-Mode', 'RestorePhysical'"* ]] \
    || fail "seal/sysprep 首启没有优先接受当前 physical-only 实例"
rg -F "'-AutoDetect', '-NvapiPayloadDir', \$PSScriptRoot" "$RESPAWN" >/dev/null \
    || fail "正式 apply 没有接收同包 GPU API payload"
gpu_api_install_line="$(rg -n -F '& $powershellExe @gpuApiInstallArgs' "$APPLY" | cut -d: -f1)"
identity_complete_line="$(rg -n -F '& $identityHelperSource -CompleteIdentity' \
    "$APPLY" | cut -d: -f1)"
gpu_api_finalize_line="$(rg -n -F '& $powershellExe @gpuApiFinalizeArgs' \
    "$APPLY" | cut -d: -f1)"
host_optional_success_line="$(rg -n -F 'no host-side offline fix is required' \
    "$APPLY" | cut -d: -f1)"
[[ -n "$gpu_api_install_line" && -n "$identity_complete_line" && \
    -n "$gpu_api_finalize_line" && -n "$host_optional_success_line" && \
    "$gpu_api_install_line" -lt "$identity_complete_line" && \
    "$identity_complete_line" -lt "$gpu_api_finalize_line" && \
    "$gpu_api_finalize_line" -lt "$host_optional_success_line" ]] \
    || fail "GPU API/identity 未完整 Finalize 就误报 host-fix 可选成功"
rg -F -- "-KeyName 'DEVPKEY_Device_HardwareIds'" "$RESPAWN" >/dev/null \
    || fail "无 CurrentIdentity 场景没有用 SetupAPI 做 physical-only 门禁"
stop_projection_body="$(sed -n '/^function Stop-GpuIdentityWriterTasks {/,/^}/p' "$RESPAWN")"
for stopped_task in '$projectionTaskName' "'StealthGPU-RefreshName'"; do
    [[ "$stop_projection_body" == *"$stopped_task"* ]] \
        || fail "驱动/PnP 前的 writer 屏障缺少：$stopped_task"
done
apply_failure_body="$(sed -n '/^if (\$rc -ne 0) {/,/^}/p' "$RESPAWN")"
[[ "$apply_failure_body" == *'Stop-GpuIdentityWriterTasks'* ]] \
    || fail "apply 失败会残留刚注册的名称刷新任务"
rg -F "\$projectionTaskName = 'StealthGPU-ProjectHardwareId'" \
    "$RESPAWN" >/dev/null || fail "正式 HardwareID 任务名缺失"
publish_body="$(sed -n '/^function Publish-GpuIdentityPayload {/,/^}/p' "$RESPAWN")"
[[ "$publish_body" == *'project-gpu-hardware-id.ps1'* &&
   "$publish_body" == *'gpu-hardware-id-plan.ps1'* &&
   "$publish_body" == *'gpu-hardware-id-transaction.ps1'* ]] \
    || fail "没有完整发布 ProgramData HardwareID 投影依赖闭包"
finalization_body="$(sed -n '/^function Invoke-GpuProjectionFinalization {/,/^}/p' \
    "$RESTART_HELPER")"
for contract in "'Apply', 'Verify'" 'Invoke-NvapiRuntimeProbes' \
        'Register-GpuProjectionTask' "'-Mode', 'RestorePhysical'" \
        'Remove-ScheduledTaskVerified'; do
    [[ "$finalization_body" == *"$contract"* ]] \
        || fail "最终投影/探针/回滚编排缺少：$contract"
done
register_body="$(sed -n '/^function Register-GpuProjectionTask {/,/^}/p' \
    "$RESTART_HELPER")"
for contract in 'New-ScheduledTaskTrigger -AtStartup' \
        'New-ScheduledTaskTrigger -AtLogOn' \
        "New-ScheduledTaskPrincipal -UserId 'SYSTEM'" \
        '-LogonType ServiceAccount -RunLevel Highest' \
        '-MultipleInstances IgnoreNew'; do
    [[ "$register_body" == *"$contract"* ]] \
        || fail "HardwareID 持久任务缺少契约：$contract"
done
clear_body="$(sed -n '/^function Clear-RespawnDisplayModeTask {/,/^}/p' "$RESTART_HELPER")"
[[ "$clear_body" != *'StealthGPU-RefreshName'* ]] \
    || fail "FirstLogon 最终清理会误删必要的名称刷新 task"
[[ "$clear_body" == *'StealthGPU-ForceDisplayFreq'* ]] \
    || fail "FirstLogon 没有清理交互式显示模式 task"
[[ "$clear_body" == *'Remove-ScheduledTaskVerified'* ]] \
    || fail "FirstLogon 旧任务清理没有停止/删除/复读确认"

remove_body="$(sed -n '/^function Remove-ScheduledTaskVerified {/,/^}/p' "$RESTART_HELPER")"
for contract in 'Disable-ScheduledTask' 'Stop-ScheduledTask' \
        "'^(Running|Queued)$'" "-ine 'Disabled'" 'Unregister-ScheduledTask' \
        'Get-RootScheduledTaskExact'; do
    [[ "$remove_body" == *"$contract"* ]] \
        || fail "计划任务 fail-closed 清理缺少契约: $contract"
done
[[ "$remove_body" != *'SilentlyContinue'* ]] \
    || fail "计划任务安全清理仍会吞掉 Task Scheduler 错误"
rg -F 'Remove-RespawnResumeTask -CurrentInstance' "$RESPAWN" >/dev/null \
    || fail "二阶段恢复任务没有使用不自杀的自删除路径"
rg -F "\$trigger.Delay = 'PT15S'" "$RESTART_HELPER" >/dev/null \
    || fail "二阶段 AtLogOn 任务没有给 PnP 初始化留延迟"
rg -F 'function Wait-ResumeDisplayDeviceReady' "$RESTART_HELPER" >/dev/null \
    || fail "重启状态 helper 缺少有限等待函数"
rg -F "if (\$ResumeStage -eq 'Full' -and -not (Wait-ResumeDisplayDeviceReady))" \
        "$RESPAWN" >/dev/null \
    || fail "完整二阶段没有调用有限等待函数"
payload_lock_line="$(grep -n '^\$payloadLock = \$null' "$RESPAWN" | cut -d: -f1)"
first_stage_line="$(grep -n '^# --- 1)' "$RESPAWN" | cut -d: -f1)"
early_resume_body="$(sed -n "${payload_lock_line},${first_stage_line}p" "$RESPAWN")"
[[ "$early_resume_body" != *'Remove-RespawnResumeTask -CurrentInstance'* ]] \
    || fail "二阶段仍在全部验证之前消费掉唯一恢复任务"
success_resume_remove_line="$(grep -n -F 'Complete-RespawnResumeStage' \
    "$RESPAWN" | tail -1 | cut -d: -f1)"
no_reboot_line="$(grep -n '^if (\$NoReboot)' "$RESPAWN" | tail -1 | cut -d: -f1)"
[[ -n "$success_resume_remove_line" && -n "$no_reboot_line" && \
    "$success_resume_remove_line" -lt "$no_reboot_line" ]] \
    || fail "二阶段成功路径没有在最终返回前调用完成 helper"
completion_body="$(sed -n '/^function Complete-RespawnResumeStage {/,/^}/p' \
    "$RESTART_HELPER")"
[[ "$completion_body" == *'Remove-RespawnResumeTask -CurrentInstance'* &&
   "$completion_body" == *'exit 0'* ]] \
    || fail "二阶段完成 helper 没有删除当前恢复任务并直接退出"
for payload in gpu-hardware-id-plan.ps1 gpu-hardware-id-transaction.ps1 \
        project-gpu-hardware-id.ps1; do
    rg -F "$payload" "$BUILD" >/dev/null || fail "build 缺少 payload: $payload"
    rg -F "L\"$payload\"" "$LAUNCHER" >/dev/null \
        || fail "launcher 缺少 payload: $payload"
    rg -F "$payload" "$PACKAGE" >/dev/null \
        || fail "legacy package 缺少 payload: $payload"
done

for source_file in "$PLAN" "$PROJECTOR" "$PROJECTION_TRANSACTION" \
        "$RESPAWN" "$RESTART_HELPER"; do
    code_lines="$(awk '!/^[[:space:]]*($|#)/ { count++ } END { print count + 0 }' \
        "$source_file")"
    (( code_lines <= 500 )) \
        || fail "$source_file 非空非注释代码行=$code_lines，超过 500"
done
[[ "$(wc -l < "$LAUNCHER")" -le 500 ]] \
    || fail "launcher C 文件超过 500 行"

echo "OK: one devnode uses exact logical-first/physical-tail projection with rollback"
