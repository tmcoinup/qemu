#!/usr/bin/env bash
# 验证 guest 显示模式辅助脚本不会吞掉 ChangeDisplaySettings 返回码，并且只有在
# 重新枚举得到 1920x1080@60Hz 后才返回成功。测试用可控的 StDisp 假实现替代 Windows
# user32.dll，因此 Linux CI 也能覆盖成功、无交互桌面、驱动拒绝、重启和伪成功场景。
# shellcheck disable=SC2016
# 单引号内容是待匹配/传给 PowerShell 的字面 `$`，不能由 Bash 展开。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SPOOF="$REPO_ROOT/deploy/scripts/apply-gpu-spoof.ps1"
APPLY_SUPPORT="$REPO_ROOT/deploy/scripts/gpu-spoof-apply-support.ps1"
REFRESH_SCRIPT="$REPO_ROOT/deploy/scripts/refresh-gpu-name.ps1"
MODE_SCRIPT="$REPO_ROOT/deploy/scripts/force-displayfreq.ps1"
RESPAWN="$REPO_ROOT/deploy/guest-stealth/respawn-stealth-local.ps1"
TMP_DIR="$(mktemp -d)"
FAKE_RUNNER="$TMP_DIR/run-with-fake-display.ps1"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_contains() {
    local needle="$1"
    local path="$2"
    grep -F "$needle" "$path" >/dev/null \
        || fail "$(basename "$path") 缺少预期输出: $needle"
}

assert_not_contains() {
    local needle="$1"
    local path="$2"
    if grep -F "$needle" "$path" >&2; then
        fail "$(basename "$path") 出现不应存在的输出: $needle"
    fi
}

# 三份生产 PowerShell 源码都必须能独立通过 AST 解析。显示模式 helper 已经是独立
# 文件，测试直接执行该文件，不再依赖 SafeGetValue 解析嵌套动态 here-string。
SPOOF_PATH="$SPOOF" APPLY_SUPPORT_PATH="$APPLY_SUPPORT" \
REFRESH_SCRIPT_PATH="$REFRESH_SCRIPT" MODE_SCRIPT_PATH="$MODE_SCRIPT" \
pwsh -NoLogo -NoProfile -NonInteractive -Command '
    foreach ($path in @(
        $env:SPOOF_PATH,
        $env:APPLY_SUPPORT_PATH,
        $env:REFRESH_SCRIPT_PATH,
        $env:MODE_SCRIPT_PATH
    )) {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $path, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) {
            $errors | ForEach-Object {
                [Console]::Error.WriteLine($path + ": " + $_.Message)
            }
            exit 1
        }
    }
' || fail "GPU spoof 主脚本或独立 helper 的 PowerShell AST 解析失败"

# 生产脚本在 StDisp 类型已存在时不会重复 Add-Type；测试先注入同名假类型，并通过
# 环境变量精确模拟 EnumDisplaySettings/ChangeDisplaySettings 的原生行为。
apply_patch <<PATCH >/dev/null
*** Begin Patch
*** Add File: $FAKE_RUNNER
+param([Parameter(Mandatory=\$true)][string]\$ModeScript)
+
+Add-Type -TypeDefinition @"
+using System;
+using System.Runtime.InteropServices;
+public class StDisp {
+    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
+    public struct DEVMODE {
+        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmDeviceName;
+        public ushort dmSpecVersion;
+        public ushort dmDriverVersion;
+        public ushort dmSize;
+        public ushort dmDriverExtra;
+        public uint dmFields;
+        public int dmPositionX;
+        public int dmPositionY;
+        public uint dmDisplayOrientation;
+        public uint dmDisplayFixedOutput;
+        public short dmColor;
+        public short dmDuplex;
+        public short dmYResolution;
+        public short dmTTOption;
+        public short dmCollate;
+        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmFormName;
+        public ushort dmLogPixels;
+        public uint dmBitsPerPel;
+        public uint dmPelsWidth;
+        public uint dmPelsHeight;
+        public uint dmDisplayFlags;
+        public uint dmDisplayFrequency;
+        public uint dmICMMethod;
+        public uint dmICMIntent;
+        public uint dmMediaType;
+        public uint dmDitherType;
+        public uint dmReserved1;
+        public uint dmReserved2;
+        public uint dmPanningWidth;
+        public uint dmPanningHeight;
+    }
+
+    private static bool applied = false;
+    private static int ReadInt(string name, int fallback) {
+        int value;
+        string raw = Environment.GetEnvironmentVariable(name);
+        return Int32.TryParse(raw, out value) ? value : fallback;
+    }
+
+    public static int EnumDisplaySettings(
+        string deviceName, int modeNum, ref DEVMODE mode) {
+        int result = ReadInt("STDISP_ENUM_RESULT", 1);
+        if (result == 0) return 0;
+        string prefix = applied ? "STDISP_FINAL_" : "STDISP_INITIAL_";
+        mode.dmPelsWidth = (uint)ReadInt(prefix + "WIDTH", 1280);
+        mode.dmPelsHeight = (uint)ReadInt(prefix + "HEIGHT", 800);
+        mode.dmDisplayFrequency = (uint)ReadInt(prefix + "FREQUENCY", 60);
+        mode.dmBitsPerPel = 32;
+        return result;
+    }
+
+    public static int ChangeDisplaySettings(ref DEVMODE mode, uint flags) {
+        if (flags == 2) return ReadInt("STDISP_TEST_RESULT", 0);
+        int result = ReadInt("STDISP_CHANGE_RESULT", 0);
+        if (result == 0) applied = true;
+        return result;
+    }
+}
+"@
+
+& \$ModeScript
+exit \$LASTEXITCODE
*** End Patch
PATCH

run_case() {
    local name="$1"
    local expected_rc="$2"
    shift 2
    local output="$TMP_DIR/$name.out"

    set +e
    env \
        STDISP_ENUM_RESULT=1 \
        STDISP_INITIAL_WIDTH=1280 \
        STDISP_INITIAL_HEIGHT=800 \
        STDISP_INITIAL_FREQUENCY=60 \
        STDISP_FINAL_WIDTH=1920 \
        STDISP_FINAL_HEIGHT=1080 \
        STDISP_FINAL_FREQUENCY=60 \
        STDISP_TEST_RESULT=0 \
        STDISP_CHANGE_RESULT=0 \
        "$@" \
        pwsh -NoLogo -NoProfile -NonInteractive -File "$FAKE_RUNNER" \
            -ModeScript "$MODE_SCRIPT" >"$output" 2>&1
    local actual_rc=$?
    set -e

    [[ "$actual_rc" -eq "$expected_rc" ]] \
        || fail "$name 退出码应为 $expected_rc，实际为 $actual_rc；输出: $(tr '\n' ' ' <"$output")"
}

run_case success 0
assert_contains 'ChangeDisplaySettings(CDS_TEST) 返回码=0 [DISP_CHANGE_SUCCESSFUL]' \
    "$TMP_DIR/success.out"
assert_contains 'ChangeDisplaySettings(CDS_UPDATEREGISTRY) 返回码=0 [DISP_CHANGE_SUCCESSFUL]' \
    "$TMP_DIR/success.out"
assert_contains '切换后模式：1920x1080@60Hz/32bpp' "$TMP_DIR/success.out"
assert_contains '验收成功：当前显示模式为 1920x1080@60Hz。' "$TMP_DIR/success.out"

# 重启后二阶段若当前模式已经正确，必须在调用 ChangeDisplaySettings 前直接验收成功。
run_case already_target 0 \
    STDISP_INITIAL_WIDTH=1920 STDISP_INITIAL_HEIGHT=1080 \
    STDISP_INITIAL_FREQUENCY=60 STDISP_TEST_RESULT=-2 STDISP_CHANGE_RESULT=-1
assert_contains '当前显示模式已经是 1920x1080@60Hz，无需重复切换' \
    "$TMP_DIR/already_target.out"
assert_not_contains 'ChangeDisplaySettings(' "$TMP_DIR/already_target.out"

run_case no_interactive_display 10 STDISP_ENUM_RESULT=0
assert_contains '当前进程没有可交互桌面；未执行切换' \
    "$TMP_DIR/no_interactive_display.out"
assert_not_contains '验收成功' "$TMP_DIR/no_interactive_display.out"

run_case bad_mode 20 STDISP_TEST_RESULT=-2
assert_contains '返回码=-2 [DISP_CHANGE_BADMODE]' "$TMP_DIR/bad_mode.out"
assert_not_contains 'CDS_UPDATEREGISTRY' "$TMP_DIR/bad_mode.out"

run_case driver_failure 21 STDISP_CHANGE_RESULT=-1
assert_contains '返回码=-1 [DISP_CHANGE_FAILED]' "$TMP_DIR/driver_failure.out"
assert_not_contains '验收成功' "$TMP_DIR/driver_failure.out"

run_case restart_required 11 STDISP_CHANGE_RESULT=1
assert_contains '返回码=1 [DISP_CHANGE_RESTART]' "$TMP_DIR/restart_required.out"
assert_contains '当前会话尚未验证为目标模式' "$TMP_DIR/restart_required.out"

run_case false_success 23 STDISP_FINAL_WIDTH=1280 STDISP_FINAL_HEIGHT=800
assert_contains '切换后模式：1280x800@60Hz/32bpp' "$TMP_DIR/false_success.out"
assert_contains '验收失败：最终宽度、高度或刷新率' "$TMP_DIR/false_success.out"
assert_not_contains '验收成功' "$TMP_DIR/false_success.out"

# 主流程必须在 PnP 扫描之后同步调用辅助脚本；-SkipTask 无延后任务时的无桌面状态
# 必须传播非零退出码。以下守卫防止以后又退化成异步 schtasks /Run + 静默成功。
scan_line="$(grep -n '^Invoke-GpuSpoofPnpRefresh$' "$SPOOF" | cut -d: -f1)"
sync_line="$(grep -n '^\$displayResult = Invoke-GpuSpoofDisplayModeVerification' \
    "$SPOOF" | cut -d: -f1)"
[[ -n "$scan_line" && -n "$sync_line" && "$sync_line" -gt "$scan_line" ]] \
    || fail "显示模式同步验收没有发生在最终 PnP 扫描之后"
grep -F 'if ($DisplayTaskInstalled)' "$APPLY_SUPPORT" >/dev/null \
    || fail "无交互桌面延后语义没有检查登录任务是否实际安装"
boot_register_line="$(grep -n 'Register-ScheduledTask -TaskName $taskName' \
    "$APPLY_SUPPORT" | cut -d: -f1)"
skip_branch_line="$(grep -n 'if ($SkipDisplayTask)' "$APPLY_SUPPORT" | head -1 | cut -d: -f1)"
[[ -n "$boot_register_line" && -n "$skip_branch_line" && \
   "$boot_register_line" -lt "$skip_branch_line" ]] \
    || fail "名称刷新任务没有在 FirstLogon/-SkipTask 下无条件保留"
grep -F 'exit $displayModeFailureCode' "$SPOOF" >/dev/null \
    || fail "显示模式失败退出码没有传播给调用方"
if grep -nE '\[StDisp\]::ChangeDisplaySettings.*(Out-Null|> *\$null)' "$MODE_SCRIPT" >&2; then
    fail "ChangeDisplaySettings 返回码仍被静默丢弃"
fi

# 主脚本只负责从 PSScriptRoot 验证、复制 helper，不得重新塞回落盘 here-string。
grep -F "Join-Path \$PSScriptRoot 'refresh-gpu-name.ps1'" "$SPOOF" >/dev/null \
    || fail "主脚本没有从 PSScriptRoot 定位 refresh helper"
grep -F "Join-Path \$PSScriptRoot 'force-displayfreq.ps1'" "$SPOOF" >/dev/null \
    || fail "主脚本没有从 PSScriptRoot 定位显示模式 helper"
grep -F 'Copy-GpuSpoofHelperIfDifferent -Source $RefreshHelperSource' \
        "$APPLY_SUPPORT" >/dev/null || fail "apply support 没有安全复制 refresh helper"
grep -F 'Copy-GpuSpoofHelperIfDifferent -Source $DisplayModeHelperSource' \
        "$APPLY_SUPPORT" >/dev/null || fail "apply support 没有安全复制显示模式 helper"
grep -F '[IO.Path]::GetFullPath($Source)' "$APPLY_SUPPORT" >/dev/null \
    || fail "helper 复制逻辑没有规范化源路径"
grep -F '[StringComparer]::OrdinalIgnoreCase.Equals' "$APPLY_SUPPORT" >/dev/null \
    || fail "helper 复制逻辑没有按 Windows 规则识别同一路径"
if grep -F -e '$body = @' -e '$freqBody = @' "$SPOOF" "$APPLY_SUPPORT" >&2; then
    fail "主脚本重新引入了落盘 helper here-string"
fi

# 注释不计入 500 行限制；保留少量余量，防止后续改动悄悄把主流程重新堆成巨石文件。
main_code_lines="$(awk '!/^[[:space:]]*($|#)/ { count++ } END { print count + 0 }' "$SPOOF")"
[[ "$main_code_lines" -lt 500 ]] \
    || fail "apply-gpu-spoof.ps1 非空非注释代码行=$main_code_lines，必须小于 500"
[[ "$(wc -l <"$SPOOF")" -le 500 && "$(wc -l <"$APPLY_SUPPORT")" -le 500 ]] \
    || fail "apply 主脚本或 support helper 物理行数超过 500"

# 两个 helper 含中文字符串，必须保留 UTF-8 BOM，供 Windows PowerShell 5.1 稳定读取。
for helper in "$APPLY_SUPPORT" "$REFRESH_SCRIPT" "$MODE_SCRIPT"; do
    [[ "$(xxd -p -l 3 "$helper")" == 'efbbbf' ]] \
        || fail "$(basename "$helper") 缺少 UTF-8 BOM"
done

# helper 返回 11 表示请求已持久化但需重启；主脚本必须原样上抛给外层二阶段验收。
grep -F '$failureCode = 11' "$APPLY_SUPPORT" >/dev/null \
    || fail "apply support 吞掉了显示 helper 的重启退出码 11"
grep -F '$displayModeFailureCode = [int]$displayResult.FailureCode' "$SPOOF" >/dev/null \
    || fail "主脚本没有接收 support helper 的显示失败码"
grep -F 'exit $displayModeFailureCode' "$SPOOF" >/dev/null \
    || fail "主脚本没有统一传播显示 helper 的非零退出码"
grep -F 'Restart-RespawnForPendingWork -PendingExitCode 11' "$RESPAWN" >/dev/null \
    || fail "外层没有把显示重启码 11 接入统一二阶段流程"
grep -F -- '-RegistrationFailureCode 33 -ShutdownFailureCode 34' "$RESPAWN" >/dev/null \
    || fail "显示二阶段注册/重启失败码契约不完整"

# 旧 HTTP/SSH 入口已经退役。它们必须只给出迁移诊断，不能继续下载松散 helper、
# 修改 guest 或提供一个与统一 EXE 不同的第二套执行路径。
for legacy_entry in \
    "$REPO_ROOT/deploy/scripts/respawn-stealth.ps1" \
    "$REPO_ROOT/deploy/scripts/shallow-stealth.ps1" \
    "$REPO_ROOT/deploy/scripts/install-stealth-guest.ps1" \
    "$REPO_ROOT/deploy/scripts/destealth-revert.ps1" \
    "$REPO_ROOT/deploy/scripts/install-stealth.sh"; do
    grep -F '已退役' "$legacy_entry" >/dev/null \
        || fail "旧入口 $(basename "$legacy_entry") 缺少退役诊断"
    grep -F 'respawn-stealth.exe' "$legacy_entry" >/dev/null \
        || fail "旧入口 $(basename "$legacy_entry") 没有指向统一 EXE"
    if grep -F -e 'Invoke-WebRequest' -e 'Enable-PnpDevice' -e 'Set-ItemProperty' \
            -e 'pnputil' -e 'Start-Process' "$legacy_entry" >&2; then
        fail "旧入口 $(basename "$legacy_entry") 仍包含系统变更动作"
    fi
done

echo "OK: guest-stealth display mode return-code and final-mode verification passed"
