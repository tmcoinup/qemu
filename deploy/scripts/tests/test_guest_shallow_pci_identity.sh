#!/usr/bin/env bash
# 验证来宾浅层 PCI 身份的纯解析逻辑、配置契约和 FirstLogon 持久化接线。
# 测试只提取 PowerShell 函数 AST，不访问 Linux 上不存在的 Windows PnP/注册表。
# shellcheck disable=SC2016
# 单引号内容是传给 PowerShell 或匹配源码的字面 `$`，不能由 Bash 展开。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
IDENTITY_SCRIPT="$REPO_ROOT/deploy/scripts/persist-gpu-profile.ps1"
TRANSACTION_SCRIPT="$REPO_ROOT/deploy/scripts/gpu-profile-transaction.ps1"
APPLY_SCRIPT="$REPO_ROOT/deploy/scripts/apply-gpu-spoof.ps1"
REFRESH_SCRIPT="$REPO_ROOT/deploy/scripts/refresh-gpu-name.ps1"
PROFILE_DOC="$REPO_ROOT/deploy/docs/PROFILE-FIELDS.md"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

command -v pwsh >/dev/null 2>&1 || fail "缺少 pwsh，无法解析 PowerShell 5.1 兼容源码"
[[ "$(xxd -p -l 3 "$IDENTITY_SCRIPT")" == "efbbbf" ]] \
    || fail "persist-gpu-profile.ps1 必须保留 UTF-8 BOM"
[[ "$(xxd -p -l 3 "$TRANSACTION_SCRIPT")" == "efbbbf" ]] \
    || fail "gpu-profile-transaction.ps1 必须保留 UTF-8 BOM"
[[ "$(xxd -p -l 3 "$REFRESH_SCRIPT")" == "efbbbf" ]] \
    || fail "refresh-gpu-name.ps1 必须保留 UTF-8 BOM"

IDENTITY_SCRIPT="$IDENTITY_SCRIPT" pwsh -NoLogo -NoProfile -NonInteractive -Command '
$ErrorActionPreference = "Stop"
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $env:IDENTITY_SCRIPT, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) {
    throw ("PowerShell 语法错误：" + ($errors | ForEach-Object Message -join "; "))
}

# 只加载无副作用的解析/校验函数；脚本主体会访问 Windows 注册表，
# 不能在 Linux 执行。
$wanted = @("Get-HexWord", "Get-HexByte", "Get-ShallowPciIdentity", "Get-PciLocation",
    "Assert-GpuRuntimeProfile", "Assert-GpuIdentityStrings")
foreach ($name in $wanted) {
    $functionAst = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $name
    }, $true)
    if ($null -eq $functionAst) { throw ("缺少函数：" + $name) }
    Invoke-Expression $functionAst.Extent.Text
}

function Assert-Equal($Actual, $Expected, [string]$Label) {
    if ($Actual -ne $Expected) {
        throw ("{0}: actual={1}, expected={2}" -f $Label, $Actual, $Expected)
    }
}

$nvidia = Get-ShallowPciIdentity `
    -InstanceId "PCI\VEN_1AF4&DEV_1050&SUBSYS_1C8210DE&REV_A1\3&11583659&0&30" `
    -Vendor "NVIDIA"
Assert-Equal $nvidia.PciVendorId 0x10DE "NVIDIA vendor"
Assert-Equal $nvidia.PciDeviceId 0x1C82 "1050 Ti device"
Assert-Equal $nvidia.SubsystemVendorId 0x10DE "NVIDIA subsystem vendor"
Assert-Equal $nvidia.SubsystemDeviceId 0x1C82 "NVIDIA subsystem device"
Assert-Equal $nvidia.RevisionId 0xA1 "NVIDIA revision"

$amd = Get-ShallowPciIdentity `
    -InstanceId "PCI\VEN_1AF4&DEV_1050&SUBSYS_67FF1002&REV_CF\4&ABC&0&00" `
    -Vendor "AMD"
Assert-Equal $amd.PciVendorId 0x1002 "AMD vendor"
Assert-Equal $amd.PciDeviceId 0x67FF "RX 560 device"
Assert-Equal $amd.RevisionId 0xCF "AMD revision"

Assert-GpuIdentityStrings -Name ("NVIDIA " + ("N" * 56)) -Vendor NVIDIA `
    -Bios "Version 86.07.48.00.A0"
Assert-GpuIdentityStrings -Name "AMD Radeon RX 560" -Vendor AMD `
    -Bios "016.011.000.029.000000"
foreach ($badStrings in @(
    @{ Name="NVIDIA GeForce GTX 1050 Ti"; Vendor="nvidia"; Bios="Version 86.07.48.00.A0" },
    @{ Name="Red Hat Red Hat VirtIO GPU DOD controller"; Vendor="NVIDIA"; Bios="Version 86.07.48.00.A0" },
    @{ Name="AMD Red Hat VirtIO GPU DOD controller"; Vendor="AMD"; Bios="016.011.000.029.000000" },
    @{ Name=("N" * 64); Vendor="NVIDIA"; Bios="Version 86.07.48.00.A0" },
    @{ Name="NVIDIA GeForce GTX 1050 Ti`n"; Vendor="NVIDIA"; Bios="Version 86.07.48.00.A0" },
    @{ Name="NVIDIA 显卡"; Vendor="NVIDIA"; Bios="Version 86.07.48.00.A0" },
    @{ Name="NVIDIA GeForce GTX 1050 Ti"; Vendor="NVIDIA"; Bios="86.07.48.00.A0" },
    @{ Name="NVIDIA GeForce GTX 1050 Ti"; Vendor="NVIDIA"; Bios="Version 86.07.48.00.a0" },
    @{ Name="AMD Radeon RX 560"; Vendor="AMD"; Bios="16.011.000.029.000000" }
)) {
    $rejected = $false
    try {
        Assert-GpuIdentityStrings -Name $badStrings.Name -Vendor $badStrings.Vendor `
            -Bios $badStrings.Bios
    } catch { $rejected = $true }
    if (-not $rejected) { throw "非法 GPU identity 字符串未被拒绝" }
}

$location = Get-PciLocation -BusNumber 0 -Address 0x00060000
Assert-Equal $location.BusId 0 "PCI bus"
Assert-Equal $location.SlotId 6 "PCI slot"
Assert-Equal $location.FunctionId 0 "PCI function"
$lastLocation = Get-PciLocation -BusNumber 255 -Address 0x001F0007
Assert-Equal $lastLocation.BusId 255 "maximum PCI bus"
Assert-Equal $lastLocation.SlotId 31 "maximum PCI slot"
Assert-Equal $lastLocation.FunctionId 7 "maximum PCI function"

Assert-GpuRuntimeProfile -MemoryType GDDR5 -MemoryBusWidthBits 128 `
    -BaseClockKHz 1290000 -BoostClockKHz 1392000 -MemoryClockKHz 3504000 `
    -SliSupported 0
Assert-GpuRuntimeProfile -MemoryType GDDR5 -MemoryBusWidthBits 32 `
    -BaseClockKHz 100000 -BoostClockKHz 100000 -MemoryClockKHz 100000 `
    -SliSupported 0
Assert-GpuRuntimeProfile -MemoryType GDDR5 -MemoryBusWidthBits 1024 `
    -BaseClockKHz 5000000 -BoostClockKHz 5000000 -MemoryClockKHz 10000000 `
    -SliSupported 0
foreach ($badProfile in @(
    @{ Type="DDR4"; Width=128; Base=1290000; Boost=1392000; Memory=3504000; Sli=0 },
    @{ Type="GDDR5"; Width=31; Base=1290000; Boost=1392000; Memory=3504000; Sli=0 },
    @{ Type="GDDR5"; Width=96; Base=1290000; Boost=1392000; Memory=3504000; Sli=0 },
    @{ Type="GDDR5"; Width=2048; Base=1290000; Boost=1392000; Memory=3504000; Sli=0 },
    @{ Type="GDDR5"; Width=128; Base=99999; Boost=1392000; Memory=3504000; Sli=0 },
    @{ Type="GDDR5"; Width=128; Base=1500000; Boost=1392000; Memory=3504000; Sli=0 },
    @{ Type="GDDR5"; Width=128; Base=1290000; Boost=5000001; Memory=3504000; Sli=0 },
    @{ Type="GDDR5"; Width=128; Base=1290000; Boost=1392000; Memory=99999; Sli=0 },
    @{ Type="GDDR5"; Width=128; Base=1290000; Boost=1392000; Memory=10000001; Sli=0 },
    @{ Type="GDDR5"; Width=128; Base=1290000; Boost=1392000; Memory=3504000; Sli=1 },
    @{ Type="GDDR5"; Width=128; Base=1290000; Boost=1392000; Memory=3504000; Sli=2 }
)) {
    $rejected = $false
    try {
        Assert-GpuRuntimeProfile -MemoryType $badProfile.Type `
            -MemoryBusWidthBits $badProfile.Width -BaseClockKHz $badProfile.Base `
            -BoostClockKHz $badProfile.Boost -MemoryClockKHz $badProfile.Memory `
            -SliSupported $badProfile.Sli
    } catch { $rejected = $true }
    if (-not $rejected) { throw "非法 GPU 规格未被拒绝" }
}

foreach ($bad in @(
    @{ Id="PCI\VEN_10DE&DEV_1C82&SUBSYS_1C8210DE&REV_A1\1"; Vendor="NVIDIA" },
    @{ Id="PCI\VEN_1AF4&DEV_1050&SUBSYS_1C8210DE&REV_A1\1"; Vendor="AMD" },
    @{ Id="PCI\VEN_1AF4&DEV_1050&SUBSYS_000010DE&REV_A1\1"; Vendor="NVIDIA" },
    @{ Id="PCI\VEN_1AF4&DEV_1050&SUBSYS_1C8210DE&REV_A1\1"; Vendor="nvidia" },
    @{ Id="PCI\VEN_1AF4&DEV_1050&REV_A1\1"; Vendor="NVIDIA" }
)) {
    $rejected = $false
    try { Get-ShallowPciIdentity -InstanceId $bad.Id -Vendor $bad.Vendor | Out-Null }
    catch { $rejected = $true }
    if (-not $rejected) { throw ("非法身份未被拒绝：" + $bad.Id + "/" + $bad.Vendor) }
}

foreach ($badLocation in @(
    @{ Bus=256; Address=0x00010000 },
    @{ Bus=0; Address=0x00200000 },
    @{ Bus=0; Address=0x00010008 }
)) {
    $rejected = $false
    try { Get-PciLocation -BusNumber $badLocation.Bus -Address $badLocation.Address | Out-Null }
    catch { $rejected = $true }
    if (-not $rejected) { throw "越界 PCI location 未被拒绝" }
}
' >/dev/null

# durable transaction helper 顶层只能定义函数/常量，可在 Linux 安全 dot-source；
# 同时用纯 token 门禁覆盖拆分后最容易因漏打包或语法漂移而失效的入口。
TRANSACTION_SCRIPT="$TRANSACTION_SCRIPT" pwsh -NoLogo -NoProfile -NonInteractive -Command '
$ErrorActionPreference = "Stop"
$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    $env:TRANSACTION_SCRIPT, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) {
    throw ("PowerShell 语法错误：" + ($errors | ForEach-Object Message -join "; "))
}
. $env:TRANSACTION_SCRIPT
Assert-IdentityToken "0123456789ABCDEF0123456789ABCDEF"
foreach ($badToken in @(
    "0123456789abcdef0123456789abcdef",
    "0123456789ABCDEF0123456789ABCDE",
    "0123456789ABCDEF0123456789ABCDEFF"
)) {
    $rejected = $false
    try { Assert-IdentityToken $badToken } catch { $rejected = $true }
    if (-not $rejected) { throw ("非法 transaction token 未被拒绝：" + $badToken) }
}

# Linux 没有 ScheduledTasks 模块，因此用同名函数模拟两个旧任务。成功路径必须
# 对每个任务执行禁用/停止/删除；Stop 的注入故障必须原样上抛且禁止继续删除。
function New-MockTask([string]$Name) {
    return [pscustomobject]@{
        TaskName=$Name; TaskPath="\"; State="Running"
        Settings=[pscustomobject]@{ Enabled=$true }
    }
}
$script:mockTasks = @{
    "StealthGPU-RefreshName" = New-MockTask "StealthGPU-RefreshName"
    "StealthGPU-ForceDisplayFreq" = New-MockTask "StealthGPU-ForceDisplayFreq"
}
$script:disableCount = 0; $script:stopCount = 0; $script:unregisterCount = 0
function Get-ScheduledTask { param($ErrorAction) return @($script:mockTasks.Values) }
function Disable-ScheduledTask {
    param([string]$TaskName, [string]$TaskPath, $ErrorAction)
    $script:disableCount++
    $script:mockTasks[$TaskName].Settings.Enabled = $false
}
function Stop-ScheduledTask {
    param([string]$TaskName, [string]$TaskPath, $ErrorAction)
    $script:stopCount++
    $script:mockTasks[$TaskName].State = "Disabled"
}
function Unregister-ScheduledTask {
    param([string]$TaskName, [string]$TaskPath, [switch]$Confirm, $ErrorAction)
    $script:unregisterCount++
    [void]$script:mockTasks.Remove($TaskName)
}
Invoke-LegacyGpuTaskBarrier
if ($script:mockTasks.Count -ne 0 -or $script:disableCount -ne 2 -or
    $script:stopCount -ne 2 -or $script:unregisterCount -ne 2) {
    throw "旧任务屏障成功路径没有完整停止并删除两个任务"
}

$script:mockTasks["StealthGPU-RefreshName"] = New-MockTask "StealthGPU-RefreshName"
$script:unregisterCount = 0
function Stop-ScheduledTask {
    param([string]$TaskName, [string]$TaskPath, $ErrorAction)
    throw "injected Stop-ScheduledTask failure"
}
$barrierRejected = $false
try { Invoke-LegacyGpuTaskBarrier } catch { $barrierRejected = $true }
if (-not $barrierRejected -or $script:unregisterCount -ne 0 -or
    $script:mockTasks.Count -ne 1) {
    throw "旧任务停止故障没有 fail-closed 阻止删除/后续 Stage"
}
' >/dev/null

# refresh helper 同时承担严格只读 snapshot API；先做完整 AST 解析，防止 Windows
# PowerShell 5.1 执行前才暴露语法错误。注册表主体不在 Linux 上求值。
REFRESH_SCRIPT="$REFRESH_SCRIPT" pwsh -NoLogo -NoProfile -NonInteractive -Command '
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $env:REFRESH_SCRIPT, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) {
    throw ("PowerShell 语法错误：" + ($errors | ForEach-Object Message -join "; "))
}

# 加载 strict reader/writer 的纯函数。fake RegistryKey 用于证明 Binary/QWord
# 不会被压成 Int32，并验证错误 kind/data 会 fail-closed。
foreach ($functionName in @(
    "Get-ExactRegistryValue", "Get-LogicalMatchingDeviceId", "Set-VerifiedRegistryValue"
)) {
    $functionAst = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $functionName
    }, $true)
    if ($null -eq $functionAst) { throw ("缺少函数：" + $functionName) }
    Invoke-Expression $functionAst.Extent.Text
}
if ((Get-LogicalMatchingDeviceId -VendorId 0x10DE -DeviceId 0x1C82) -cne
        "PCI\VEN_10DE&DEV_1C82") {
    throw "GTX 1050 Ti MatchingDeviceId 错误"
}
if ((Get-LogicalMatchingDeviceId -VendorId 0x1002 -DeviceId 0x67FF) -cne
        "PCI\VEN_1002&DEV_67FF") {
    throw "RX 560 MatchingDeviceId 错误"
}
$rejected = $false
try {
    Get-LogicalMatchingDeviceId -VendorId 0 -DeviceId 0x1C82 | Out-Null
} catch { $rejected = $true }
if (-not $rejected) { throw "越界 MatchingDeviceId 没有被拒绝" }

$fakeKey = [pscustomobject]@{
    Values=@{}; Kinds=@{}; CorruptName=$null; CorruptKindName=$null
}
$fakeKey | Add-Member ScriptMethod GetValueNames { return @($this.Values.Keys) }
$fakeKey | Add-Member ScriptMethod GetValueKind {
    param($Name)
    if ($this.CorruptKindName -ceq $Name) {
        return [Microsoft.Win32.RegistryValueKind]::String
    }
    return $this.Kinds[$Name]
}
$fakeKey | Add-Member ScriptMethod SetValue {
    param($Name, $Value, $Kind)
    $this.Values[$Name] = $Value
    $this.Kinds[$Name] = $Kind
}
$fakeKey | Add-Member ScriptMethod GetValue {
    param($Name, $DefaultValue, $Options)
    $value = $this.Values[$Name]
    if ($this.CorruptName -ceq $Name) {
        if ($value -is [array]) {
            $copy = @($value); $copy[0] = ([int]$copy[0] + 1) -band 0xFF
            return [byte[]]$copy
        }
        return ([UInt64]$value + 1)
    }
    return $value
}

foreach ($binary in @(
    [byte[]](0, 0, 0, 128),
    [byte[]](0, 0, 0, 0, 1, 2, 3, 4)
)) {
    Set-VerifiedRegistryValue $fakeKey MemorySize $binary `
        ([Microsoft.Win32.RegistryValueKind]::Binary)
}
foreach ($qword in @([UInt64]2147483648, [UInt64]4294967296)) {
    Set-VerifiedRegistryValue $fakeKey qwMemorySize $qword `
        ([Microsoft.Win32.RegistryValueKind]::QWord)
}
$fakeKey.CorruptName = "MemorySize"
$rejected = $false
try {
    Set-VerifiedRegistryValue $fakeKey MemorySize ([byte[]](1,2,3,4)) `
        ([Microsoft.Win32.RegistryValueKind]::Binary)
} catch { $rejected = $true }
if (-not $rejected) { throw "Binary 写后错误数据没有 fail-closed" }
$fakeKey.CorruptName = $null; $fakeKey.CorruptKindName = "qwMemorySize"
$rejected = $false
try {
    Set-VerifiedRegistryValue $fakeKey qwMemorySize ([UInt64]4294967296) `
        ([Microsoft.Win32.RegistryValueKind]::QWord)
} catch { $rejected = $true }
if (-not $rejected) { throw "QWord 写后错误 kind 没有 fail-closed" }
' >/dev/null

for value_name in \
    IdentitySchemaVersion IdentityId SpoofPciVendorId SpoofPciDeviceId \
    SpoofSubsystemVendorId SpoofSubsystemDeviceId SpoofRevisionId \
    SpoofPciBusId SpoofPciSlotId SpoofPciFunctionId SpoofRamMb \
    SpoofMemoryType SpoofMemoryBusWidthBits SpoofBaseClockKHz \
    SpoofBoostClockKHz SpoofMemoryClockKHz SpoofSliSupported; do
    rg -F "'$value_name'" "$IDENTITY_SCRIPT" >/dev/null \
        || fail "配置写入缺少 $value_name"
done
rg -F '[Microsoft.Win32.RegistryView]::Registry64' "$TRANSACTION_SCRIPT" >/dev/null \
    || fail "身份配置没有强制写入 64 位注册表视图"
rg -F "'IdentityMode', 'shallow-user-projection'" "$IDENTITY_SCRIPT" >/dev/null \
    || fail "身份配置没有标记浅层用户态投影模式"

# 写者先完整持久化 identity 与 rollback journal，再发布 PendingIdentity；单独的
# Commit 模式才通过公共 helper 的 CAS 写 CurrentIdentity。这样 apply 任一步失败
# 都可恢复旧投影与旧 pointer，root SpoofName 仍只是提交后的兼容镜像。
create_line="$(rg -n -F '$versionKey = $identitiesKey.CreateSubKey($versionId, $true)' \
    "$IDENTITY_SCRIPT" | cut -d: -f1)"
schema_zero_line="$(rg -n -F '$versionKey.SetValue('\''IdentitySchemaVersion'\'', 0' \
    "$IDENTITY_SCRIPT" | cut -d: -f1)"
identity_id_line="$(rg -n -F '$versionKey.SetValue('\''IdentityId'\'', $versionId' \
    "$IDENTITY_SCRIPT" | cut -d: -f1)"
schema_two_line="$(rg -n -F '$versionKey.SetValue('\''IdentitySchemaVersion'\'', 2' \
    "$IDENTITY_SCRIPT" | cut -d: -f1)"
flush_line="$(rg -n -F '$versionKey.Flush()' "$IDENTITY_SCRIPT" | cut -d: -f1)"
transaction_flush_line="$(rg -n -F '$transactionKey.SetValue('\''TransactionSchemaVersion'\'', 1' \
    "$IDENTITY_SCRIPT" | cut -d: -f1)"
pending_line="$(rg -n -F '$configKey.SetValue('\''PendingIdentity'\'', $versionId' \
    "$IDENTITY_SCRIPT" | cut -d: -f1)"
commit_line="$(rg -n -F 'Set-CurrentIdentityPointer $configKey $expected $true $receipt.NewIdentityId' \
    "$IDENTITY_SCRIPT" | cut -d: -f1)"
mirror_line="$(rg -n -F '$configKey.SetValue('\''SpoofName'\'', $receipt.NewSpoofName' \
    "$IDENTITY_SCRIPT" | cut -d: -f1)"
[[ -n "$create_line" && -n "$schema_zero_line" && -n "$identity_id_line" && \
    -n "$schema_two_line" && -n "$flush_line" && -n "$transaction_flush_line" && \
    -n "$pending_line" && -n "$commit_line" && \
    -n "$mirror_line" && "$create_line" -lt "$schema_zero_line" && \
    "$schema_zero_line" -lt "$identity_id_line" && \
    "$identity_id_line" -lt "$schema_two_line" && \
    "$schema_two_line" -le "$flush_line" && \
    "$flush_line" -lt "$transaction_flush_line" && \
    "$transaction_flush_line" -lt "$pending_line" && \
    "$commit_line" -lt "$mirror_line" ]] \
    || fail "身份写者没有遵守 identity/journal/Pending/CAS 提交顺序"
[[ "$(rg -c -F '$ConfigKey.SetValue('\''CurrentIdentity'\'', $NewValue' "$TRANSACTION_SCRIPT")" -eq 1 ]] \
    || fail "durable transaction helper 中 CurrentIdentity 必须只有一个 CAS 写入点"
rg -F "Join-Path \$PSScriptRoot 'gpu-profile-transaction.ps1'" "$IDENTITY_SCRIPT" >/dev/null \
    || fail "persist 没有从同目录加载 durable transaction helper"
rg -F 'Test-Path -LiteralPath $transactionHelperPath -PathType Leaf' "$IDENTITY_SCRIPT" >/dev/null \
    || fail "persist dot-source 前没有严格检查 transaction helper 文件"
rg -F '. $transactionHelperPath' "$IDENTITY_SCRIPT" >/dev/null \
    || fail "persist 没有 dot-source transaction helper"
for moved_function in Assert-IdentityToken Get-ExactRegistryValue \
        Invoke-WithIdentityWriterLock Invoke-RecoverOrRollback; do
    rg -F "function $moved_function" "$TRANSACTION_SCRIPT" >/dev/null \
        || fail "transaction helper 缺少已拆分函数：$moved_function"
    if rg -F "function $moved_function" "$IDENTITY_SCRIPT" >&2; then
        fail "persist 仍重复定义 transaction 函数：$moved_function"
    fi
done
for old_task in StealthGPU-RefreshName StealthGPU-ForceDisplayFreq; do
    rg -F "'$old_task'" "$TRANSACTION_SCRIPT" >/dev/null \
        || fail "Recover 旧任务屏障缺少：$old_task"
done
for barrier_contract in \
        'Get-ScheduledTask -ErrorAction Stop' \
        'Stop-ScheduledTask -TaskName $taskName' \
        'Unregister-ScheduledTask -TaskName $taskName' \
        "State -imatch '^(Running|Queued)$'" \
        'Get-RootScheduledTaskExact -TaskName $taskName'; do
    rg -F "$barrier_contract" "$TRANSACTION_SCRIPT" >/dev/null \
        || fail "Recover 旧任务屏障缺少 fail-closed 契约：$barrier_contract"
done
[[ "$(rg -c -F -- '-ErrorAction Stop' "$TRANSACTION_SCRIPT")" -ge 4 ]] \
    || fail "旧任务查询/禁用/停止/删除没有全部使用 ErrorAction Stop"
barrier_line="$(rg -n -F 'if ($Recover) { Invoke-LegacyGpuTaskBarrier }' \
    "$TRANSACTION_SCRIPT" | cut -d: -f1)"
recover_lock_line="$(rg -n -F 'return Invoke-WithIdentityWriterLock {' \
    "$TRANSACTION_SCRIPT" | cut -d: -f1)"
[[ -n "$barrier_line" && -n "$recover_lock_line" && \
    "$barrier_line" -lt "$recover_lock_line" ]] \
    || fail "Recover 必须在进入身份 mutex 前通过旧任务屏障"
rg -F "@('Completed','RolledBack') -ccontains \$done.State" \
    "$TRANSACTION_SCRIPT" >/dev/null \
    || fail "已完成/已回滚事务状态集合的 -ccontains 操作数方向错误"
if rg -F "\$done.State -ccontains @('Completed','RolledBack')" \
        "$TRANSACTION_SCRIPT" >&2; then
    fail "事务恢复不能把标量放在 -ccontains 左侧"
fi
rg -F ".ToString('N').ToUpperInvariant()" "$IDENTITY_SCRIPT" >/dev/null \
    || fail "身份版本名没有固定为大写 GUID-N"
if rg -F -e 'DeleteSubKey' -e 'Remove-Item' "$IDENTITY_SCRIPT" >&2; then
    fail "身份事务不应清理旧版/失败 GUID 子键"
fi

# 所有运行时消费者必须从同一个严格 snapshot 决策；root mirror 只能兼容外部旧工具。
for contract in 'initialPointer' 'finalPointer' 'schemaBefore' 'schemaAfter' \
        "'Identities\\' + \$initialPointer" \
        "'^[0-9A-F]{32}$'"; do
    rg -F "$contract" "$REFRESH_SCRIPT" >/dev/null \
        || fail "refresh 严格 snapshot 读取缺少契约：$contract"
done
rg -F '$schemaBefore -ne 2' "$REFRESH_SCRIPT" >/dev/null \
    || fail "CurrentIdentity reader 没有 fail-closed 要求 schema 2"
rg -F '$legacySchemaBefore -ne 1' "$REFRESH_SCRIPT" >/dev/null \
    || fail "旧 root-only migration hint 不应伪装为 schema 2"
rg -F '& $refreshHelperSource -ReadIdentityOnly -AllowMissing' "$APPLY_SCRIPT" >/dev/null \
    || fail "apply previous identity 没有走严格 CurrentIdentity snapshot"
for migration_contract in legacySchemaBefore legacySchemaAfter legacyNameBefore \
        legacyNameAfter IsLegacyMigrationHint; do
    rg -F "$migration_contract" "$REFRESH_SCRIPT" >/dev/null \
        || fail "旧 root-only 升级名称缺少双读契约：$migration_contract"
done
for apply_field in SpoofMemoryType SpoofMemoryBusWidthBits SpoofBaseClockKHz \
        SpoofBoostClockKHz SpoofMemoryClockKHz SpoofSliSupported; do
    rg -F -- "-$apply_field \$$apply_field" "$APPLY_SCRIPT" >/dev/null \
        || fail "apply 没有把 $apply_field 传给身份写者"
done

# writer 参数约束、writer 运行时门禁和 reader 复核必须与 NVAPI C
# 读者使用同一范围。这些静态互锁与上方边界执行测试配合，
# 防止只改了某一层后脚本发布、DLL 却整体拒绝身份。
for writer in "$APPLY_SCRIPT" "$IDENTITY_SCRIPT"; do
    rg -F 'ValidateRange(32, 1024)' "$writer" >/dev/null \
        || fail "$writer 位宽范围未与 reader 一致"
    rg -F '($_ -band ($_ - 1)) -eq 0' "$writer" >/dev/null \
        || fail "$writer 未要求位宽为 2 次幂"
    [[ "$(rg -o -F 'ValidateRange(100000, 5000000)' "$writer" | wc -l)" -ge 2 ]] \
        || fail "$writer base/boost 范围未与 reader 一致"
    rg -F 'ValidateRange(100000, 10000000)' "$writer" >/dev/null \
        || fail "$writer memory clock 范围未与 reader 一致"
    rg -F 'ValidateSet(0)' "$writer" >/dev/null \
        || fail "$writer 仍公开单 GPU schema 不支持的 SLI=1"
done
rg -F '| `GPU_SLI_SUPPORTED` | `SpoofSliSupported` | 仅允许 `0`' "$PROFILE_DOC" >/dev/null \
    || fail "PROFILE-FIELDS 仍公开必然被单 GPU schema 拒绝的 SLI=1"
for reader_contract in \
        '$snapshot.SpoofMemoryBusWidthBits -lt 32' \
        '$snapshot.SpoofMemoryBusWidthBits -gt 1024' \
        '$snapshot.SpoofBaseClockKHz -lt 100000' \
        '$snapshot.SpoofBaseClockKHz -gt 5000000' \
        '$snapshot.SpoofBoostClockKHz -gt 5000000' \
        '$snapshot.SpoofMemoryClockKHz -lt 100000' \
        '$snapshot.SpoofMemoryClockKHz -gt 10000000'; do
    rg -F "$reader_contract" "$REFRESH_SCRIPT" >/dev/null \
        || fail "refresh 缺少边界互锁：$reader_contract"
done
if rg -F "Get-ItemProperty 'HKLM:\\SOFTWARE\\StealthGPU'" \
        "$APPLY_SCRIPT" "$REFRESH_SCRIPT" >&2; then
    fail "运行时消费者仍直接读取非原子 root mirror"
fi
if rg -F "\$ErrorActionPreference = 'SilentlyContinue'" "$REFRESH_SCRIPT" >&2; then
    fail "refresh 不得全局吞掉 active Enum/Class 写入错误"
fi
rg -F '$cfg = Invoke-WithProjectionLock {' "$REFRESH_SCRIPT" >/dev/null \
    || fail "refresh 严格读取与投影没有共用同一 mutex 临界区"
commit_projection_line="$(rg -n -F '& $refreshPath -StagedIdentityId $CommitIdentity' \
    "$IDENTITY_SCRIPT" | cut -d: -f1)"
commit_cas_line="$(rg -n -F 'Set-CurrentIdentityPointer $configKey $expected $true' \
    "$IDENTITY_SCRIPT" | cut -d: -f1)"
[[ -n "$commit_projection_line" && -n "$commit_cas_line" && \
    "$commit_projection_line" -lt "$commit_cas_line" ]] \
    || fail "Commit 必须在同一 writer mutex 内先 strict projection 再 CAS"
rg -F 'Invoke-LegacyGpuTaskBarrier' "$IDENTITY_SCRIPT" >/dev/null \
    || fail "直接 Stage 没有 fail-closed 旧任务屏障"

# 名称刷新器只能写 Display Class 软件键。GPU Enum\PCI HardwareID 的唯一例外由
# 独立 projector 以 fake-first + 完整 physical 尾部事务处理；refresh 自身仍严禁写入。
rg -F "Set-VerifiedRegistryValue \$classKey 'MatchingDeviceId' \$matchingId \$string" \
    "$REFRESH_SCRIPT" >/dev/null \
    || fail "没有恢复从 profile 派生的旧版浅层 MatchingDeviceId"
for brand_contract in \
        "Set-VerifiedRegistryValue \$enumKey 'FriendlyName' \$Config.SpoofName \$string" \
        "Set-VerifiedRegistryValue \$enumKey 'DeviceDesc' \$Config.SpoofName \$string" \
        "Set-VerifiedRegistryValue \$enumKey 'Mfg' \$Config.SpoofVendor \$string" \
        "Set-VerifiedRegistryValue \$classKey 'DriverDesc' \$Config.SpoofName \$string" \
        "Set-VerifiedRegistryValue \$classKey 'ProviderName' \$Config.SpoofVendor \$string" \
        "Set-VerifiedRegistryValue \$classKey 'HardwareInformation.AdapterString' \$Config.SpoofName \$string"; do
    rg -F "$brand_contract" "$REFRESH_SCRIPT" >/dev/null \
        || fail "GPU 显示品牌兜底缺少：$brand_contract"
done
for refresh_task_contract in \
        "\$taskName = 'StealthGPU-RefreshName'" \
        'New-ScheduledTaskTrigger -AtStartup' \
        'New-ScheduledTaskTrigger -AtLogOn' \
        "New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest"; do
    rg -F "$refresh_task_contract" "$APPLY_SCRIPT" >/dev/null \
        || fail "GPU 显示品牌开机/登录恢复缺少：$refresh_task_contract"
done
if rg -F -e '$sourceEnumPath -Name HardwareID' \
        -e '$sourceEnumPath -Name CompatibleIDs' "$REFRESH_SCRIPT" >&2; then
    fail "refresh 不得绕过专用 projector 写 Enum\\PCI HardwareID/CompatibleIDs"
fi

helper_line="$(rg -n -F '& $identityHelperSource -Stage -SpoofName' "$APPLY_SCRIPT" | cut -d: -f1)"
old_profile_line="$(rg -n -F '$previousIdentity = & $refreshHelperSource -ReadIdentityOnly' \
    "$APPLY_SCRIPT" | cut -d: -f1)"
reuse_old_profile_line="$(rg -n -F '$prevSpoof = $previousSpoofName' \
    "$APPLY_SCRIPT" | cut -d: -f1)"
enable_line="$(rg -n -F "Enable-StealthDisplayDevices -Reason '浅层物理门禁通过后清理 Code 22'" \
    "$APPLY_SCRIPT" | cut -d: -f1)"
task_line="$(rg -n -F 'if (-not $SkipTask) {' "$APPLY_SCRIPT" | tail -1 | cut -d: -f1)"
scan_line="$(rg -n -F '& pnputil.exe /scan-devices' "$APPLY_SCRIPT" | cut -d: -f1)"
projection_line="$(rg -n -F '& $refreshHelperSource' "$APPLY_SCRIPT" | tail -1 | cut -d: -f1)"
commit_pointer_line="$(rg -n -F '& $identityHelperSource -CommitIdentity $identityTransactionId' \
    "$APPLY_SCRIPT" | cut -d: -f1)"
[[ -n "$helper_line" && -n "$old_profile_line" && -n "$reuse_old_profile_line" && \
    -n "$enable_line" && -n "$task_line" && -n "$scan_line" && \
    -n "$projection_line" && -n "$commit_pointer_line" && \
    "$old_profile_line" -lt "$helper_line" && \
    "$helper_line" -lt "$reuse_old_profile_line" && "$helper_line" -lt "$enable_line" && \
    "$helper_line" -lt "$commit_pointer_line" && "$helper_line" -lt "$task_line" && \
    "$scan_line" -lt "$projection_line" ]] \
    || fail "必须先捕获旧 profile，再于设备状态和 Class/Enum 写入前执行浅层门禁"

for source_file in "$IDENTITY_SCRIPT" "$TRANSACTION_SCRIPT" "$APPLY_SCRIPT" "$REFRESH_SCRIPT"; do
    code_lines="$(awk '!/^[[:space:]]*#/ && !/^[[:space:]]*$/ { count++ } END { print count + 0 }' "$source_file")"
    (( code_lines <= 500 )) || fail "$source_file 非注释代码行数 $code_lines 超过 500"
done

echo "OK: shallow PCI identity projects 1AF4:1050 to profile VEN:DEV safely"
