#!/usr/bin/env bash
# 验证 GPU HardwareID fake-first 规划、唯一写入边界及 guest-stealth 正式接线。
# shellcheck disable=SC2016
# 单引号中的 `$` 属于待执行 PowerShell 或源码契约，不能由 Bash 提前展开。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PLAN="$REPO_ROOT/deploy/scripts/gpu-hardware-id-plan.ps1"
PROJECTOR="$REPO_ROOT/deploy/scripts/project-gpu-hardware-id.ps1"
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

for path in "$PLAN" "$PROJECTOR" "$TRANSACTION" "$APPLY" "$RESPAWN" "$BUILD" \
        "$RESTART_HELPER" "$PACKAGE" "$LAUNCHER"; do
    [[ -f "$path" ]] || fail "缺少 HardwareID 投影链文件: $path"
done
for path in "$PLAN" "$PROJECTOR" "$RESPAWN" "$RESTART_HELPER"; do
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
    "PCI\VEN_1AF4&DEV_1050&SUBSYS_1C8210DE&REV_A1",
    "PCI\VEN_1AF4&DEV_1050&SUBSYS_1C8210DE",
    "PCI\VEN_1AF4&DEV_1050&CC_030000",
    "PCI\VEN_1AF4&DEV_1050&CC_0300"
)
$nvidia = @(Get-ProjectedHardwareIds -OriginalIds $physical `
    -VendorId 0x10DE -DeviceId 0x1C82)
$expectedNvidia = @(
    "PCI\VEN_10DE&DEV_1C82&SUBSYS_1C8210DE&REV_A1"
) + $physical
Assert-ExactArray $nvidia $expectedNvidia "GTX 1050 Ti fake-first"
if ($nvidia.Count -ne $physical.Count + 1) {
    throw "projector 生成了多余 logical ID"
}

$amdPhysical = @(
    "PCI\VEN_1AF4&DEV_1050&SUBSYS_67FF1002&REV_CF",
    "PCI\VEN_1AF4&DEV_1050&SUBSYS_67FF1002"
)
$amd = @(Get-ProjectedHardwareIds $amdPhysical 0x1002 0x67FF)
$expectedAmd = @("PCI\VEN_1002&DEV_67FF&SUBSYS_67FF1002&REV_CF") +
    $amdPhysical
Assert-ExactArray $amd $expectedAmd "RX 560 fake-first"

$recovered = @(Get-OriginalIdsFromExistingProjection $nvidia 0x10DE 0x1C82)
Assert-ExactArray $recovered $physical "现场投影反推物理数组"
if (@(Get-OriginalIdsFromExistingProjection $nvidia 0x1002 0x67FF).Count -ne 0) {
    throw "无备份时错误接管了其他 profile 的 fake-first 数组"
}

$duplicatePhysical = @($physical[0], $physical[0], $physical[1])
$duplicateProjected = @(Get-ProjectedHardwareIds $duplicatePhysical 0x10DE 0x1C82)
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
    try { Get-ProjectedHardwareIds $bad 0x10DE 0x1C82 | Out-Null }
    catch { $rejected = $true }
    if (-not $rejected) { throw ("异常物理数组未被拒绝: " + ($bad -join "|")) }
}
if (Test-StringArrayEqual @("ABC") @("abc")) {
    throw "绑定契约比较错误忽略了大小写变化"
}
' >/dev/null || fail "HardwareID 规划纯函数测试失败"

# 提取生产 Apply 状态机并用内存 mock 注入竞态/写后故障。这样可以证明异常路径确实
# 第二次调用唯一 writer 恢复原数组，而不需要在 Linux 测试机访问 Windows 注册表。
PLAN="$PLAN" PROJECTOR="$PROJECTOR" \
pwsh -NoLogo -NoProfile -NonInteractive -Command '
$ErrorActionPreference = "Stop"
. $env:PLAN
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $env:PROJECTOR, [ref]$tokens, [ref]$errors)
$applyAst = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq "Invoke-ProjectionApply"
}, $true)
if ($null -eq $applyAst) { throw "缺少生产 Apply 状态机" }
. ([scriptblock]::Create($applyAst.Extent.Text))

$physicalPattern = "^PCI\\VEN_1AF4&DEV_1050(?:&|$)"
$physical = @(
    "PCI\VEN_1AF4&DEV_1050&SUBSYS_1C8210DE&REV_A1",
    "PCI\VEN_1AF4&DEV_1050&SUBSYS_1C8210DE"
)
$expected = @(Get-ProjectedHardwareIds $physical 0x10DE 0x1C82)
$baseIdentity = [pscustomobject]@{
    IdentityId="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    SourceInstanceId=($physical[0] + "\3&11583659&0&30")
    SpoofPciVendorId=0x10DE
    SpoofPciDeviceId=0x1C82
}
$otherIdentity = [pscustomobject]@{
    IdentityId="BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
    SourceInstanceId=$baseIdentity.SourceInstanceId
    SpoofPciVendorId=0x1002
    SpoofPciDeviceId=0x67FF
}

function Reset-Scenario {
    param([string[]]$Ids, [object[]]$Identities, [switch]$CorruptFirstWrite,
        [switch]$ThrowAfterFirstWrite)
    $script:CurrentIds = [string[]]@($Ids)
    $script:Identities = @($Identities)
    $script:IdentityReads = 0
    $script:HardwareWrites = 0
    $script:BackupWrites = 0
    $script:CorruptFirstWrite = [bool]$CorruptFirstWrite
    $script:ThrowAfterFirstWrite = [bool]$ThrowAfterFirstWrite
}
function Get-StrictIdentity {
    $index = [Math]::Min($script:IdentityReads, $script:Identities.Count - 1)
    $script:IdentityReads++
    return $script:Identities[$index]
}
function Assert-SameIdentity($Expected, $Actual) {
    if ($Expected.IdentityId -cne $Actual.IdentityId) { throw "identity switched" }
}
function Assert-PresentTarget($InstanceId) {}
function Remove-IncompleteBackupIfRecoverable($BaseKey, $Target, $Identity) {}
function Get-ProjectionBackup($BaseKey, $InstanceId) { return $null }
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
function Assert-BindingUnchanged($Before, $After) {}
function Set-BackupState {
    param($BaseKey, $Target, [string[]]$OriginalIds, [string[]]$AppliedIds,
        [AllowNull()][AllowEmptyCollection()][string[]]$PendingIds,
        [string]$IdentityId, [string]$State)
    $script:BackupWrites++
}
function Set-TargetHardwareIds($BaseKey, $Target, [string[]]$HardwareIds) {
    $script:HardwareWrites++
    if ($script:CorruptFirstWrite -and $script:HardwareWrites -eq 1) {
        $script:CurrentIds = [string[]]@("BROKEN")
    } else {
        $script:CurrentIds = [string[]]@($HardwareIds)
    }
    if ($script:ThrowAfterFirstWrite -and $script:HardwareWrites -eq 1) {
        throw "mock Flush failed after SetValue"
    }
}

$dummyBaseKey = [pscustomobject]@{}
Reset-Scenario $physical @($baseIdentity, $baseIdentity, $baseIdentity, $baseIdentity)
Invoke-ProjectionApply $dummyBaseKey
if ($script:HardwareWrites -ne 1 -or $script:BackupWrites -ne 2 -or
    -not (Test-StringArrayEqual $script:CurrentIds $expected)) {
    throw "physical -> fake-first 正常事务错误"
}

Reset-Scenario $expected @($baseIdentity, $baseIdentity)
Invoke-ProjectionApply $dummyBaseKey
if ($script:HardwareWrites -ne 0 -or $script:BackupWrites -ne 1) {
    throw "已规范状态没有保持 HardwareID 零写"
}

Reset-Scenario $physical @($baseIdentity, $otherIdentity)
$failed = $false
try { Invoke-ProjectionApply $dummyBaseKey } catch { $failed = $true }
if (-not $failed -or $script:HardwareWrites -ne 0) {
    throw "提交前身份切换没有在零写状态失败"
}

Reset-Scenario $physical @(
    $baseIdentity, $baseIdentity, $baseIdentity, $otherIdentity)
$failed = $false
try { Invoke-ProjectionApply $dummyBaseKey } catch { $failed = $true }
if (-not $failed -or $script:HardwareWrites -ne 2 -or
    -not (Test-StringArrayEqual $script:CurrentIds $physical)) {
    throw "写后身份切换没有恢复事务前数组"
}

Reset-Scenario $physical @(
    $baseIdentity, $baseIdentity, $baseIdentity, $baseIdentity) `
    -CorruptFirstWrite
$failed = $false
try { Invoke-ProjectionApply $dummyBaseKey } catch { $failed = $true }
if (-not $failed -or $script:HardwareWrites -ne 2 -or
    -not (Test-StringArrayEqual $script:CurrentIds $physical)) {
    throw "写后复核故障没有恢复事务前数组"
}

Reset-Scenario $physical @(
    $baseIdentity, $baseIdentity, $baseIdentity, $baseIdentity) `
    -ThrowAfterFirstWrite
$failed = $false
try { Invoke-ProjectionApply $dummyBaseKey } catch { $failed = $true }
if (-not $failed -or $script:HardwareWrites -ne 2 -or
    -not (Test-StringArrayEqual $script:CurrentIds $physical)) {
    throw "SetValue 后 Flush 异常没有恢复事务前数组"
}
' >/dev/null || fail "HardwareID Apply 故障注入/自动回滚测试失败"

# 提取 respawn 的真实 SetupAPI 门禁与只读包装器，用内存 PnP 结果证明 seal/sysprep
# 后的新实例为纯物理时可跳过旧回滚，而 fake-first/无设备仍进入恢复或拒绝路径。
RESPAWN="$RESPAWN" pwsh -NoLogo -NoProfile -NonInteractive -Command '
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $env:RESPAWN, [ref]$tokens, [ref]$errors)
foreach ($functionName in @("Assert-PhysicalDisplayHardwareIds",
        "Test-PhysicalDisplayHardwareIds")) {
    $functionAst = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $functionName
    }, $true)
    if ($null -eq $functionAst) { throw ("缺少生产函数：" + $functionName) }
    . ([scriptblock]::Create($functionAst.Extent.Text))
}
function Get-PnpDevice {
    param([string]$Class, [switch]$PresentOnly, $ErrorAction)
    if (-not $script:NoDevice) { [pscustomobject]@{ InstanceId=$script:InstanceId } }
}
function Get-PnpDeviceProperty {
    param([string]$InstanceId, [string]$KeyName, $ErrorAction)
    return [pscustomobject]@{ Data=[string[]]@($script:HardwareIds) }
}
$physical = @(
    "PCI\VEN_1AF4&DEV_1050&SUBSYS_1D0110DE&REV_A1",
    "PCI\VEN_1AF4&DEV_1050&SUBSYS_1D0110DE"
)
$script:InstanceId = $physical[0] + "\3&11583659&0&30"
$script:HardwareIds = $physical
$script:NoDevice = $false
if (-not (Test-PhysicalDisplayHardwareIds)) { throw "纯物理实例未通过只读预检" }
$script:HardwareIds = @("PCI\VEN_10DE&DEV_1D01&SUBSYS_1D0110DE&REV_A1") + $physical
if (Test-PhysicalDisplayHardwareIds) { throw "fake-first 被预检误报为纯物理" }
$script:NoDevice = $true
if (Test-PhysicalDisplayHardwareIds) { throw "无在线设备被预检误报为纯物理" }
' >/dev/null || fail "seal/sysprep 首启 physical-only 预检测试失败"

# 四个 PowerShell 文件都必须能由 Windows PowerShell 5.1 兼容 AST 解析器接受。
PS_FILES="$PLAN:$PROJECTOR:$RESPAWN:$RESTART_HELPER" \
pwsh -NoLogo -NoProfile -NonInteractive -Command '
$failed = $false
foreach ($path in $env:PS_FILES -split [IO.Path]::PathSeparator) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile(
        $path, [ref]$tokens, [ref]$errors)
    foreach ($errorItem in $errors) {
        $failed = $true
        [Console]::Error.WriteLine("{0}: {1}", $path, $errorItem.Message)
    }
}
if ($failed) { exit 1 }
' || fail "HardwareID 投影 PowerShell AST 解析失败"

# projector 是唯一获准写 GPU Enum HardwareID 的文件；同一函数中只有一个写点，
# 事务异常路径必须调用它恢复 beforeIds。其他绑定字段只能读取和逐字复核。
hardware_write_count="$(rg -c -F "SetValue('HardwareID'" "$PROJECTOR")"
[[ "$hardware_write_count" -eq 1 ]] \
    || fail "projector 的 HardwareID 注册表写点不是唯一一个"
for forbidden_value in CompatibleIDs Service Driver; do
    if rg -F "SetValue('$forbidden_value'" "$PROJECTOR" >&2; then
        fail "projector 不得写 $forbidden_value"
    fi
done
rg -F 'Set-TargetHardwareIds $BaseKey $target $beforeIds' "$PROJECTOR" >/dev/null \
    || fail "投影写后失败没有恢复事务前完整 HardwareID"
rg -F '& $identityReader -ReadIdentityOnly' "$PROJECTOR" >/dev/null \
    || fail "projector 没有使用严格 CurrentIdentity reader"
if rg -F 'AllowMissing' "$PROJECTOR" >&2; then
    fail "projector 不得回退到宽松身份读取"
fi
for mode in Apply Verify RestorePhysical Rollback; do
    rg -F "'$mode'" "$PROJECTOR" >/dev/null \
        || fail "projector 缺少模式: $mode"
done
# standalone 计划任务和正式 identity writer 必须共享同名 mutex。静态同时
# 核对两个独立入口，防止以后只修一边又退化为并发的 pointer/HardwareID writer。
rg -F "New-Object Threading.Mutex(\$false, 'Global\StealthGPU-IdentityWriter')" \
    "$PROJECTOR" >/dev/null || fail "projector 没有使用 GPU 身份共享写锁"
rg -F "New-Object System.Threading.Mutex(\$false, 'Global\StealthGPU-IdentityWriter')" \
    "$TRANSACTION" >/dev/null || fail "identity transaction 没有使用共享写锁"
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

# 正式执行顺序：先确认不息屏/不睡眠 -> 停旧任务 -> 先验当前 physical-only，只有
# 必要时才按旧 identity 恢复 -> 再次门禁 -> apply 内部 PnP scan、identity 与 GPU API
# 原子窗口 -> 注册 SYSTEM task -> 同步 fake-first。
# FirstLogon 的旧任务清理列表不得删除最终任务。
power_line="$(rg -n -F '& $powershellExe @powerArgs' "$RESPAWN" | cut -d: -f1)"
restore_line="$(rg -n -F "'-Mode', 'RestorePhysical'" "$RESPAWN" | head -1 | cut -d: -f1)"
physical_preflight_line="$(rg -n -F 'if (Test-PhysicalDisplayHardwareIds)' \
    "$RESPAWN" | cut -d: -f1)"
physical_gate_line="$(rg -n -F '    Assert-PhysicalDisplayHardwareIds' \
    "$RESPAWN" | tail -1 | cut -d: -f1)"
driver_line="$(rg -n -F '& $powershellExe @driverArgs' "$RESPAWN" | cut -d: -f1)"
spoof_line="$(rg -n -F '& $powershellExe @spoofArgs' "$RESPAWN" | cut -d: -f1)"
publish_line="$(rg -n -F '$persistentProjector = Publish-GpuProjectionPayload' \
    "$RESPAWN" | cut -d: -f1)"
register_line="$(rg -n -F 'Register-GpuProjectionTask -Projector $persistentProjector' \
    "$RESPAWN" | cut -d: -f1)"
apply_line="$(rg -n -F '& $powershellExe @projectionArgs' "$RESPAWN" | cut -d: -f1)"
[[ -n "$power_line" && -n "$physical_preflight_line" && -n "$restore_line" && \
    -n "$physical_gate_line" && -n "$driver_line" && -n "$publish_line" && \
    -n "$spoof_line" && -n "$register_line" && -n "$apply_line" ]] \
    || fail "无法定位 HardwareID 正式执行顺序"
(( power_line < physical_preflight_line && physical_preflight_line < restore_line && \
    restore_line < physical_gate_line && physical_gate_line < driver_line && \
    driver_line < publish_line && publish_line < spoof_line && spoof_line < register_line && \
    register_line < apply_line )) \
    || fail "HardwareID 投影没有严格位于 PnP scan/GPU API 成功之后"
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
stop_projection_body="$(sed -n '/^function Stop-GpuProjectionTask {/,/^}/p' "$RESPAWN")"
for stopped_task in '$projectionTaskName' "'StealthGPU-RefreshName'"; do
    [[ "$stop_projection_body" == *"$stopped_task"* ]] \
        || fail "驱动/PnP 前的旧投影任务屏障缺少：$stopped_task"
done
apply_failure_body="$(sed -n '/^if (\$rc -ne 0) {/,/^}/p' "$RESPAWN")"
[[ "$apply_failure_body" == *'Stop-GpuProjectionTask'* ]] \
    || fail "apply 失败会残留刚注册的名称刷新任务"

for contract in \
        "'StealthGPU-ProjectHardwareId'" \
        'New-ScheduledTaskTrigger -AtStartup' \
        'New-ScheduledTaskTrigger -AtLogOn' \
        "New-ScheduledTaskPrincipal -UserId 'SYSTEM'" \
        '-LogonType ServiceAccount -RunLevel Highest' \
        '-MultipleInstances IgnoreNew' \
        '[string]$registered.Principal.RunLevel' \
        '[string]$registered.Principal.LogonType'; do
    rg -F -- "$contract" "$RESPAWN" >/dev/null \
        || fail "HardwareID task 缺少契约: $contract"
done
clear_body="$(sed -n '/^function Clear-RespawnDisplayModeTask {/,/^}/p' "$RESTART_HELPER")"
[[ "$clear_body" != *'StealthGPU-ProjectHardwareId'* ]] \
    || fail "FirstLogon 最终清理会误删必要的 HardwareID task"
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
success_resume_remove_line="$(grep -n -F 'Remove-RespawnResumeTask -CurrentInstance' \
    "$RESPAWN" | tail -1 | cut -d: -f1)"
no_reboot_line="$(grep -n '^if (\$NoReboot)' "$RESPAWN" | tail -1 | cut -d: -f1)"
[[ -n "$success_resume_remove_line" && -n "$no_reboot_line" && \
    "$success_resume_remove_line" -lt "$no_reboot_line" ]] \
    || fail "二阶段成功路径没有在最终返回前删除恢复任务"
rg -F '$rollbackRc = $LASTEXITCODE' "$RESPAWN" >/dev/null \
    || fail "外层 HardwareID 回滚没有保存退出码"
rg -F "exit 45" "$RESPAWN" >/dev/null \
    || fail "外层 HardwareID 回滚失败没有独立退出码"

for payload in gpu-hardware-id-plan.ps1 project-gpu-hardware-id.ps1; do
    rg -F "$payload" "$BUILD" >/dev/null || fail "build 缺少 payload: $payload"
    rg -F "L\"$payload\"" "$LAUNCHER" >/dev/null \
        || fail "launcher 缺少 payload: $payload"
    rg -F "$payload" "$PACKAGE" >/dev/null \
        || fail "legacy package 缺少 payload: $payload"
done

for source_file in "$PLAN" "$PROJECTOR" "$RESPAWN" "$RESTART_HELPER"; do
    code_lines="$(awk '!/^[[:space:]]*($|#)/ { count++ } END { print count + 0 }' \
        "$source_file")"
    (( code_lines <= 500 )) \
        || fail "$source_file 非空非注释代码行=$code_lines，超过 500"
done
[[ "$(wc -l < "$LAUNCHER")" -le 500 ]] \
    || fail "launcher C 文件超过 500 行"

echo "OK: guest GPU HardwareID fake-first projection is exact, transactional and packaged"
