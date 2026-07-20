#!/usr/bin/env bash
# 验证浅层 GPU 身份事务屏障和严格注册表 helper 的纯运行时逻辑。
# 测试只执行可在 Linux 安全求值的 PowerShell 函数，不访问 Windows 注册表。
# shellcheck disable=SC2016
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TRANSACTION_SCRIPT="$REPO_ROOT/deploy/scripts/gpu-profile-transaction.ps1"
REFRESH_SCRIPT="$REPO_ROOT/deploy/scripts/refresh-gpu-name.ps1"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

command -v pwsh >/dev/null 2>&1 || fail "缺少 pwsh，无法运行 PowerShell helper 测试"
[[ "$(xxd -p -l 3 "$TRANSACTION_SCRIPT")" == "efbbbf" ]] \
    || fail "gpu-profile-transaction.ps1 必须保留 UTF-8 BOM"
[[ "$(xxd -p -l 3 "$REFRESH_SCRIPT")" == "efbbbf" ]] \
    || fail "refresh-gpu-name.ps1 必须保留 UTF-8 BOM"

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
    "Get-ExactRegistryValue", "Get-StockDriverMatchingDeviceId",
    "Set-VerifiedRegistryValue"
)) {
    $functionAst = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $functionName
    }, $true)
    if ($null -eq $functionAst) { throw ("缺少函数：" + $functionName) }
    Invoke-Expression $functionAst.Extent.Text
}
foreach ($sourceId in @(
    "PCI\VEN_1AF4&DEV_1050&SUBSYS_1C8210DE&REV_A1\3&11583659&0&30",
    "PCI\VEN_1AF4&DEV_1050&SUBSYS_67FF1002&REV_CF\4&ABC&0&00"
)) {
    if ((Get-StockDriverMatchingDeviceId -SourceInstanceId $sourceId) -cne
            "PCI\VEN_1AF4&DEV_1050") {
        throw "stock VioGpuDod MatchingDeviceId 错误"
    }
}
$rejected = $false
try {
    Get-StockDriverMatchingDeviceId `
        -SourceInstanceId "PCI\VEN_1002&DEV_699F&SUBSYS_699F1002&REV_CF\1" |
        Out-Null
} catch { $rejected = $true }
if (-not $rejected) { throw "伪装设备 ID 被错误接受为驱动 MatchingDeviceId" }

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

echo "OK: shallow PCI runtime helpers preserve transaction and registry contracts"
