#!/usr/bin/env bash
# 验证正式单 EXE 会在任何 GPU/PnP 修改前把屏幕/睡眠设为“从不”，同时保留桌面 S3。
# shellcheck disable=SC2016
# 单引号中的 `$` 属于待匹配 PowerShell 源码，不能由 Bash 提前展开。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

POWER_HELPER="$REPO_ROOT/deploy/guest-stealth/configure-power-policy.ps1"
RESPAWN="$REPO_ROOT/deploy/guest-stealth/respawn-stealth-local.ps1"
BUILD="$REPO_ROOT/deploy/guest-stealth/build-exe.sh"
PACKAGE="$REPO_ROOT/deploy/guest-stealth/package.sh"
LAUNCHER="$REPO_ROOT/deploy/guest-stealth/launcher/respawn-stealth-launcher.c"
PAYLOADS_HEADER="$REPO_ROOT/deploy/guest-stealth/launcher/respawn-stealth-payloads.h"
README="$REPO_ROOT/deploy/guest-stealth/README.md"
QUICKSTART="$REPO_ROOT/deploy/guest-stealth/QUICKSTART.zh-CN.md"
RUNNER="$SCRIPT_DIR/run-vmate-tests.py"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

for path in "$POWER_HELPER" "$RESPAWN" "$BUILD" "$PACKAGE" "$LAUNCHER" \
        "$PAYLOADS_HEADER" "$README" "$QUICKSTART" "$RUNNER"; do
    [[ -f "$path" ]] || fail "缺少 guest 电源策略链文件: $path"
done

# Windows PowerShell 5.1 会按本地 ANSI 代码页读取无 BOM 的脚本；中文报错和注释可能
# 因而变成乱码甚至破坏引号。正式 payload 必须保留 UTF-8 BOM，并通过真实 AST 解析。
[[ "$(xxd -p -l 3 "$POWER_HELPER")" == 'efbbbf' ]] \
    || fail "configure-power-policy.ps1 缺少 UTF-8 BOM"
POWER_FILES="$POWER_HELPER:$RESPAWN" \
pwsh -NoLogo -NoProfile -NonInteractive -Command '
    $failed = $false
    foreach ($path in $env:POWER_FILES -split [IO.Path]::PathSeparator) {
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
' || fail "guest 电源策略 PowerShell AST 解析失败"

# 只抽取跨平台可执行的函数：P/Invoke 类型在 Linux 上编译但不调用 PowrProf，设置
# 矩阵和原生命令退出码则做真实动态测试。正式验收不解析任何本地化 query 文本。
POWER_HELPER="$POWER_HELPER" \
pwsh -NoLogo -NoProfile -NonInteractive -Command '
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        $env:POWER_HELPER, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "helper AST 不可用" }
    foreach ($name in "Invoke-PowerCfgChecked", "Initialize-PowerPolicyNativeApi",
            "New-DesktopPowerSettings") {
        $definition = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq $name
        }, $true)
        if ($null -eq $definition) { throw ("缺少函数：" + $name) }
        . ([scriptblock]::Create($definition.Extent.Text))
    }

    foreach ($attempt in 1..2) {
        Initialize-PowerPolicyNativeApi
        if ($null -eq ("StealthPowerPolicyNative" -as [type])) {
            throw "PowrProf P/Invoke 桥没有成功编译"
        }
        $settings = @(New-DesktopPowerSettings)
        if ($settings.Count -ne 6 -or
            @($settings.Setting | Select-Object -Unique).Count -ne 6) {
            throw "桌面电源矩阵不是六项唯一设置"
        }
        $allowStandbyGuid = [guid]"abfc2519-3608-4c2a-94ea-171b0ed546ab"
        $allowStandby = @($settings | Where-Object Setting -eq $allowStandbyGuid)
        if ($allowStandby.Count -ne 1 -or $allowStandby[0].Value -ne 1) {
            throw "ALLOWSTANDBY 必须为 1，以保留正常桌面 S3 和睡眠区块"
        }
        $disabled = @($settings | Where-Object Setting -ne $allowStandbyGuid)
        if (@($disabled | Where-Object { $_.Value -ne 0 }).Count -ne 0) {
            throw "屏幕、自动睡眠和混合睡眠设置必须保持为 0（从不）"
        }
    }

    $ok = @(Invoke-PowerCfgChecked -Executable "/bin/sh" `
        -Arguments @("-c", "printf success"))
    if (($ok -join "") -cne "success") { throw "成功原生命令输出丢失" }
    try {
        $null = Invoke-PowerCfgChecked -Executable "/bin/sh" `
            -Arguments @("-c", "printf denied >&2; exit 7")
        throw "非零 powercfg 退出码被错误放行"
    } catch {
        if ($_.Exception.Message -ceq "非零 powercfg 退出码被错误放行") { throw }
        if ($_.Exception.Message -notmatch "退出码=7") {
            throw "失败信息没有保留原生命令退出码"
        }
    }
    exit 0
' || fail "电源策略 P/Invoke/矩阵/退出码动态测试失败"

# 高权限 helper 只能执行 System32 的 inbox 工具，并拒绝重解析点。禁止新增网络、
# 服务或计划任务，保证电源页面修复不会扩大正式 guest 的安装面。
grep -F '[Environment]::SystemDirectory' "$POWER_HELPER" >/dev/null \
    || fail "helper 没有从可信 System32 定位 powercfg"
grep -F "Join-Path \$systemDirectory 'powercfg.exe'" "$POWER_HELPER" >/dev/null \
    || fail "helper 没有构造绝对 powercfg.exe 路径"
grep -F '[IO.FileAttributes]::ReparsePoint' "$POWER_HELPER" >/dev/null \
    || fail "helper 没有拒绝 powercfg 重解析点"
for native_contract in PowerGetActiveScheme PowerSetActiveScheme \
        PowerSettingAccessCheck PowerWriteACValueIndex PowerWriteDCValueIndex \
        PowerReadACValueIndex PowerReadDCValueIndex GetPwrCapabilities \
        HiberFilePresent; do
    grep -F "$native_contract" "$POWER_HELPER" >/dev/null \
        || fail "helper 缺少 PowrProf 严格契约: $native_contract"
done
for setting_guid in \
        3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e \
        8ec4b3a5-6868-48c2-be75-4f3044be88a7 \
        29f6c1db-86da-48c5-9fdb-f2b67b1f44da \
        7bc4a2f9-d8fc-4469-b07b-33eb785aaca0 \
        abfc2519-3608-4c2a-94ea-171b0ed546ab \
        94ac6d29-73ce-41a6-809f-6363ba21b47e; do
    grep -Fi "$setting_guid" "$POWER_HELPER" >/dev/null \
        || fail "helper 缺少严格电源设置 GUID: $setting_guid"
done
grep -F -- "-Arguments @('/hibernate', 'off')" "$POWER_HELPER" >/dev/null \
    || fail "helper 没有关闭 Windows 休眠"
grep -F -- "-Name 'HiberbootEnabled'" "$POWER_HELPER" >/dev/null \
    || fail "helper 没有关闭并复核快速启动"
unsupported_query_logic="$(rg -v '^[[:space:]]*#' "$POWER_HELPER" | \
    rg -i 'Get-PowerSettingIndices|powercfg[^\n]*/query|HIBERNATEIDLE' || true)"
if [[ -n "$unsupported_query_logic" ]]; then
    printf '%s\n' "$unsupported_query_logic" >&2
    fail "正式验收仍依赖本地化 query 或错误的 HIBERNATEIDLE=0 语义"
fi
if rg -i 'Invoke-WebRequest|Invoke-RestMethod|https?://|New-Service|Register-ScheduledTask|New-NetFirewallRule|Start-Process' \
        "$POWER_HELPER" >&2; then
    fail "电源 helper 引入了网络、服务、任务、外部进程入口或额外提权链"
fi

# helper 必须是原子 bundle 的真实释放成员：源文件存在性、xxd 数组、launcher include
# 与 embedded_payloads 条目四者缺一不可；legacy 调试包也要精确复制同一源文件。
grep -F 'POWER_POLICY_SRC="$HERE/configure-power-policy.ps1"' "$BUILD" >/dev/null \
    || fail "build-exe.sh 没有固定 power helper 源"
grep -F 'payload_configure_power_policy_ps1 "$POWER_POLICY_SRC"' "$BUILD" >/dev/null \
    || fail "build-exe.sh 没有生成 power helper 字节数组"
grep -F '#include "payload_configure_power_policy_ps1.h"' \
    "$PAYLOADS_HEADER" >/dev/null \
    || fail "launcher 没有 include power helper 数组"
grep -F '{ L"configure-power-policy.ps1", payload_configure_power_policy_ps1,' \
    "$PAYLOADS_HEADER" >/dev/null || fail "launcher 没有释放 power helper"
grep -F 'cp "$POWER_POLICY_SRC"' "$PACKAGE" >/dev/null \
    || fail "legacy 调试包没有复制 power helper"

# 主脚本必须无条件先配电源，再触碰 writer、驱动和 spoof。缺文件与执行失败使用
# 独立退出码，避免与驱动 30、显示模式 11 等既有重启协议混淆。
power_line="$(grep -n -F '& $powershellExe @powerArgs' "$RESPAWN" | cut -d: -f1)"
stop_line="$(grep -n -x 'Stop-GpuIdentityWriterTasks' "$RESPAWN" | head -1 | cut -d: -f1)"
driver_line="$(grep -n -F '& $powershellExe @driverArgs' "$RESPAWN" | cut -d: -f1)"
spoof_line="$(grep -n -F '& $powershellExe @spoofArgs' "$RESPAWN" | cut -d: -f1)"
[[ -n "$power_line" && -n "$stop_line" && -n "$driver_line" && -n "$spoof_line" ]] \
    || fail "无法定位电源、writer 屏障、驱动和 spoof 调用顺序"
(( power_line < stop_line && stop_line < driver_line && driver_line < spoof_line )) \
    || fail "电源策略没有位于所有 GPU/PnP 修改之前"
grep -F "exit 48" "$RESPAWN" >/dev/null || fail "缺 power payload 没有专用退出码"
grep -F "exit 49" "$RESPAWN" >/dev/null || fail "power helper 失败没有专用退出码"
grep -F 'power-policy.log' "$RESPAWN" >/dev/null || fail "主脚本没有电源策略日志"

for doc in "$README" "$QUICKSTART"; do
    rg -i '屏幕' "$doc" >/dev/null && rg -i '睡眠' "$doc" >/dev/null && \
        rg -i '从不' "$doc" >/dev/null \
        || fail "教程缺少屏幕/睡眠均为“从不”的说明: $doc"
    rg -i '保留.*S[123]|保留.*S1.S3|ALLOWSTANDBY' "$doc" >/dev/null \
        || fail "教程缺少保留桌面睡眠能力的说明: $doc"
done
grep -F 'test_guest_stealth_power_policy.sh' "$RUNNER" >/dev/null \
    || fail "新电源策略测试没有加入 quick 并发测试集"

helper_code_lines="$(awk '!/^[[:space:]]*($|#)/ { count++ } END { print count + 0 }' \
    "$POWER_HELPER")"
respawn_code_lines="$(awk '!/^[[:space:]]*($|#)/ { count++ } END { print count + 0 }' \
    "$RESPAWN")"
[[ "$helper_code_lines" -le 500 ]] \
    || fail "configure-power-policy.ps1 非注释代码超过 500 行: $helper_code_lines"
[[ "$respawn_code_lines" -le 500 ]] \
    || fail "respawn-stealth-local.ps1 非注释代码超过 500 行: $respawn_code_lines"
[[ "$(wc -l < "$LAUNCHER")" -le 500 ]] \
    || fail "respawn-stealth-launcher.c 超过 500 行"
[[ "$(wc -l < "$PAYLOADS_HEADER")" -le 500 ]] \
    || fail "respawn-stealth-payloads.h 超过 500 行"

echo "OK: guest-stealth 在 GPU/PnP 前将屏幕/睡眠设为从不并保留桌面 S3"
