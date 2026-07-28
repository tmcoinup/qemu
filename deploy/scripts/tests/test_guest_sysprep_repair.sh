#!/usr/bin/env bash
# 验证 Sysprep 修复只依据 Panther 明确点名的 Appx 包，不用注册表状态绕过验证。
# shellcheck disable=SC2016
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
REPAIR="$REPO_ROOT/deploy/scripts/guest/repair-sysprep.ps1"
LAUNCHER="$REPO_ROOT/deploy/scripts/guest/repair-sysprep.cmd"
WORKFLOW="$REPO_ROOT/deploy/docs/VM-WORKFLOW.md"
RUNNER="$HERE/run-vmate-tests.py"
PS51_GATE="$HERE/test_windows_powershell51.ps1"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

for path in "$REPAIR" "$LAUNCHER" "$WORKFLOW" "$RUNNER" "$PS51_GATE"; do
    [[ -f "$path" ]] || fail "缺少 Sysprep 修复链文件: $path"
done
command -v pwsh >/dev/null 2>&1 || fail "缺少 PowerShell 语法测试工具 pwsh"

# Windows PowerShell 5.1 按本地 ANSI 代码页读取无 BOM 脚本，中文字符串必须带 BOM。
[[ "$(xxd -p -l 3 "$REPAIR")" == 'efbbbf' ]] \
    || fail "repair-sysprep.ps1 缺少 UTF-8 BOM"

REPAIR_SOURCE="$REPAIR" pwsh -NoLogo -NoProfile -NonInteractive -Command '
$ErrorActionPreference = "Stop"
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $env:REPAIR_SOURCE, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) {
    $errors | ForEach-Object { [Console]::Error.WriteLine($_.Message) }
    exit 1
}
' || fail "repair-sysprep.ps1 AST 解析失败"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
printf '%s\n' \
    '2026-07-26 01:00:00, Error SYSPRP Package Microsoft.Widget_1.2.3.4_x64__abc was installed for a user, but not provisioned for all users.' \
    '2026-07-26 01:00:01, Error SYSPRP unrelated error' \
    >"$TMP_DIR/setupact.log"
printf '%s\n' \
    '2026-07-26 01:00:02, Error SYSPRP Package Microsoft.Widget_1.2.3.4_x64__abc was installed for a user, but not provisioned for all users.' \
    '2026-07-26 01:00:03, Error SYSPRP Package Microsoft.Paint_9.8.7.6_neutral__def was installed for a user, but not provisioned for all users.' \
    >"$TMP_DIR/setuperr.log"

REPAIR_SOURCE="$REPAIR" FIXTURE_DIR="$TMP_DIR" \
pwsh -NoLogo -NoProfile -NonInteractive -Command '
$ErrorActionPreference = "Stop"
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $env:REPAIR_SOURCE, [ref]$tokens, [ref]$errors)
$functionAst = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq "Get-SysprepBlockingPackages"
}, $true)
if ($null -eq $functionAst) { throw "缺少日志解析函数" }
. ([scriptblock]::Create($functionAst.Extent.Text))
$logs = @(
    Join-Path $env:FIXTURE_DIR "setupact.log"
    Join-Path $env:FIXTURE_DIR "setuperr.log"
)
$actual = @(Get-SysprepBlockingPackages -LogPath $logs)
$expected = @(
    "Microsoft.Paint_9.8.7.6_neutral__def"
    "Microsoft.Widget_1.2.3.4_x64__abc"
)
if ($actual.Count -ne $expected.Count) { exit 1 }
for ($index = 0; $index -lt $expected.Count; $index++) {
    if ($actual[$index] -cne $expected[$index]) { exit 1 }
}
' || fail "Panther Appx 包提取、去重或排序失败"

# 用内存 mock 验证删除事务：Bundle 补查可命中、只删日志指定包、同名旧预配被删，
# 而当前完整包已正确预配时必须保留。测试不触碰宿主 Appx 或注册表。
REPAIR_SOURCE="$REPAIR" pwsh -NoLogo -NoProfile -NonInteractive -Command '
$ErrorActionPreference = "Stop"
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $env:REPAIR_SOURCE, [ref]$tokens, [ref]$errors)
foreach ($name in "Write-RepairLog", "Get-AllUserAppxPackages", `
        "Remove-SysprepBlockingPackage") {
    $definition = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq $name
    }, $true)
    if ($null -eq $definition) { throw "缺少函数：$name" }
    . ([scriptblock]::Create($definition.Extent.Text))
}

$script:RepairLogPath = $null
$script:Installed = @(
    [pscustomobject]@{ PackageFullName = "Vendor.Bad_2.0_x64__pub"; Type = "Bundle" }
    [pscustomobject]@{ PackageFullName = "Vendor.Keep_1.0_x64__pub"; Type = "Main" }
    [pscustomobject]@{ PackageFullName = "Vendor.Aligned_1.0_x64__pub"; Type = "Main" }
)
$script:Provisioned = @(
    [pscustomobject]@{ DisplayName = "Vendor.Bad"; PackageName = "Vendor.Bad_1.0_x64__pub" }
    [pscustomobject]@{ DisplayName = "Vendor.Aligned"; PackageName = "Vendor.Aligned_1.0_x64__pub" }
)
$script:RemovedInstalled = @()
$script:RemovedProvisioned = @()

function Get-AppxPackage {
    param([switch]$AllUsers, [string]$PackageTypeFilter)
    if ($PackageTypeFilter) {
        @($script:Installed | Where-Object Type -eq $PackageTypeFilter)
    } else {
        @($script:Installed | Where-Object Type -eq "Main")
    }
}
function Get-AppxProvisionedPackage {
    param([switch]$Online)
    @($script:Provisioned)
}
function Remove-AppxPackage {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Package, [switch]$AllUsers)
    $script:RemovedInstalled += $Package
    $script:Installed = @($script:Installed |
        Where-Object PackageFullName -cne $Package)
}
function Remove-AppxProvisionedPackage {
    [CmdletBinding()]
    param([switch]$Online, [string]$PackageName, [switch]$AllUsers)
    $script:RemovedProvisioned += $PackageName
    $script:Provisioned = @($script:Provisioned |
        Where-Object PackageName -cne $PackageName)
    [pscustomobject]@{ Online = $true; RestartNeeded = $false }
}

Remove-SysprepBlockingPackage -PackageFullName "Vendor.Bad_2.0_x64__pub"
if ($script:RemovedInstalled.Count -ne 1 -or
    $script:RemovedInstalled[0] -cne "Vendor.Bad_2.0_x64__pub") {
    throw "没有精确删除 Bundle 冲突包"
}
if ($script:RemovedProvisioned.Count -ne 1 -or
    $script:RemovedProvisioned[0] -cne "Vendor.Bad_1.0_x64__pub") {
    throw "没有精确删除同名旧预配包"
}
if (@($script:Installed | Where-Object {
        $_.PackageFullName -ceq "Vendor.Keep_1.0_x64__pub"
    }).Count -ne 1) {
    throw "误删了无关包"
}

Remove-SysprepBlockingPackage -PackageFullName "Vendor.Aligned_1.0_x64__pub"
if ($script:RemovedInstalled.Count -ne 1 -or
    $script:RemovedProvisioned.Count -ne 1) {
    throw "误删了已正确预配的完整包"
}
' || fail "Appx 精确删除、Bundle 补查或已对齐保留事务失败"

# 修复范围必须锚定完整包名；不能枚举后批量删除全部第三方或系统 Appx。
grep -F 'Where-Object { $_.PackageFullName -ceq $PackageFullName }' \
    "$REPAIR" >/dev/null || fail "Appx 清理没有锚定 Panther 完整包名"
grep -F "foreach (\$packageType in 'Bundle', 'Resource')" \
    "$REPAIR" >/dev/null || fail "Appx 查询没有覆盖 Bundle/Resource 包"
grep -F 'Remove-AppxPackage -Package $package.PackageFullName -AllUsers' \
    "$REPAIR" >/dev/null || fail "没有清理所有用户的明确冲突包"
grep -F 'Remove-AppxProvisionedPackage -Online -PackageName $package.PackageName' \
    "$REPAIR" >/dev/null || fail "没有清理同名不匹配的预配版本"

if rg -n -i \
    'Set-(Item|ItemProperty).*(GeneralizationState|CleanupState|SysprepStatus)|Remove-Item.+Sysprep|Invoke-WebRequest|Invoke-RestMethod|https?://' \
    "$REPAIR"; then
    fail "Sysprep 修复包含状态绕过、网络下载或宽泛删除"
fi

backup_line="$(grep -n -F -- "-Phase 'before'" "$REPAIR" | head -1 | cut -d: -f1)"
remove_line="$(grep -n -F 'Remove-SysprepBlockingPackage -PackageFullName' \
    "$REPAIR" | tail -1 | cut -d: -f1)"
[[ -n "$backup_line" && -n "$remove_line" && "$backup_line" -lt "$remove_line" ]] \
    || fail "脚本没有在 Appx 修改前备份 Panther 日志"

for argument in /generalize /oobe /shutdown /quiet; do
    grep -F "'$argument'" "$REPAIR" >/dev/null \
        || fail "Sysprep 调用缺少参数: $argument"
done
grep -F "Join-Path \$env:WINDIR 'System32\\Sysprep\\Sysprep.exe'" \
    "$REPAIR" >/dev/null || fail "Sysprep 没有从 WINDIR 的可信路径启动"
grep -F "\$logPaths = @(Get-SysprepLogPaths)" "$REPAIR" >/dev/null \
    || fail "Sysprep 返回后没有重新发现首次生成的 Panther 日志"
grep -F '$errorHashAfter -cne $errorHashBefore' "$REPAIR" >/dev/null \
    || fail "Sysprep 没有用 setuperr 内容变化兜底识别伪零退出码"
grep -F -- '-File "%REPAIR_SCRIPT%" -RunSysprep -ExportDirectory "%REPORT_ROOT%"' \
    "$LAUNCHER" >/dev/null || fail "CMD 启动器没有执行修复并导出报告"

grep -F 'repair-sysprep.cmd' "$WORKFLOW" >/dev/null \
    || fail "VM 工作流没有记录一键修复入口"
grep -F 'test_guest_sysprep_repair.sh' "$RUNNER" >/dev/null \
    || fail "Sysprep 回归测试没有加入 quick 测试集"
grep -F "'repair-sysprep.ps1'" "$PS51_GATE" >/dev/null \
    || fail "Sysprep 脚本没有加入原生 Windows PowerShell 5.1 门禁"

code_lines="$(awk '!/^[[:space:]]*($|#)/ { count++ } END { print count + 0 }' \
    "$REPAIR")"
[[ "$code_lines" -le 500 ]] \
    || fail "repair-sysprep.ps1 非注释代码超过 500 行: $code_lines"

echo "OK: Sysprep 修复按 Panther 精确清理 Appx，并保留诊断与验证边界"
