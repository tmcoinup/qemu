#!/usr/bin/env bash
# 验证仅进度 EXE 是无控制台的独立发布物，且不会显示 launcher/PowerShell 细节。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BUILD_SCRIPT="$REPO_ROOT/deploy/guest-stealth/build-exe.sh"
LAUNCHER="$REPO_ROOT/deploy/guest-stealth/launcher/respawn-stealth-launcher.c"
PROGRESS_UI="$REPO_ROOT/deploy/guest-stealth/launcher/progress-only-ui.c"
MANIFEST="$REPO_ROOT/deploy/guest-stealth/launcher/respawn-stealth.exe.manifest"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
OUT_DIR="$TMP_DIR/out"
BUILD_DIR="$TMP_DIR/build"
OUT_DIR="$OUT_DIR" BUILD_DIR="$BUILD_DIR" "$BUILD_SCRIPT" >/dev/null

DETAIL_EXE="$OUT_DIR/respawn-stealth.exe"
PROGRESS_EXE="$OUT_DIR/respawn-stealth-progress.exe"
[[ -s "$DETAIL_EXE" ]] || fail "未生成详细模式 EXE"
[[ -s "$PROGRESS_EXE" ]] || fail "未生成仅进度 EXE"

file "$DETAIL_EXE" | grep -F '(console)' >/dev/null \
    || fail "原 EXE 不再是 console subsystem"
file "$PROGRESS_EXE" | grep -F '(GUI)' >/dev/null \
    || fail "仅进度 EXE 不是 GUI subsystem"
for exe in "$DETAIL_EXE" "$PROGRESS_EXE"; do
    llvm-readobj --file-headers "$exe" \
        | grep -F 'TimeDateStamp: 1970-01-01 00:00:00 (0x0)' >/dev/null \
        || fail "$(basename "$exe") 的 PE/COFF 时间戳不为 0"
    strings -a "$exe" | grep -F 'requireAdministrator' >/dev/null \
        || fail "$(basename "$exe") 缺少管理员 manifest"
    x86_64-w64-mingw32-objdump -x "$exe" \
        | grep -F 'Entry: ID: 0x000018' >/dev/null \
        || fail "$(basename "$exe") 缺少 manifest 资源"
done
for marker in 'Microsoft.Windows.Common-Controls' 'version="6.0.0.0"'; do
    strings -a "$PROGRESS_EXE" | grep -F "$marker" >/dev/null \
        || fail "仅进度 EXE manifest 未激活 Common Controls v6: $marker"
done

x86_64-w64-mingw32-objdump -p "$DETAIL_EXE" \
    | grep -F 'MessageBoxW' >/dev/null \
    || fail "原 EXE 丢失既有确认/错误弹窗"
if x86_64-w64-mingw32-objdump -p "$PROGRESS_EXE" \
        | grep -F 'MessageBoxW' >&2; then
    fail "仅进度 EXE 仍导入详细弹窗"
fi
for api in InitCommonControlsEx CreateWindowExW CreateProcessW CreateFileW; do
    x86_64-w64-mingw32-objdump -p "$PROGRESS_EXE" \
        | grep -F "$api" >/dev/null \
        || fail "仅进度 EXE 缺少 UI/隐藏子进程 API: $api"
done

grep -F 'CREATE_UNICODE_ENVIRONMENT | CREATE_NO_WINDOW' "$PROGRESS_UI" >/dev/null \
    || fail "仅进度子进程仍可能创建详细控制台"
grep -F 'STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW' "$PROGRESS_UI" >/dev/null \
    || fail "仅进度子进程没有接管标准句柄"
grep -F 'name="Microsoft.Windows.Common-Controls"' "$MANIFEST" >/dev/null \
    || fail "manifest 未声明支持动态进度条的 Common Controls"
[[ "$(grep -Fc 'L"NUL"' "$PROGRESS_UI")" -eq 2 ]] \
    || fail "仅进度子进程没有把输入输出全部定向到 NUL"
grep -F '#ifdef RESPAWN_PROGRESS_ONLY' "$LAUNCHER" >/dev/null \
    || fail "launcher 没有隔离仅进度编译路径"
grep -F 'L"-Unattended"' "$LAUNCHER" >/dev/null \
    || fail "隐藏 PowerShell 失败时仍可能等待 Read-Host"
grep -F -- '-municode -mwindows -DRESPAWN_PROGRESS_ONLY' "$BUILD_SCRIPT" >/dev/null \
    || fail "仅进度目标没有按 GUI subsystem 编译"

python3 - "$PROGRESS_EXE" "$REPO_ROOT" <<'PY'
from pathlib import Path
import sys

exe = Path(sys.argv[1]).read_bytes()
root = Path(sys.argv[2])
for message in ("正在准备，请稍候…", "正在处理，请稍候…", "已完成。",
                "未完成，请稍后重试。"):
    if message.encode("utf-16le") not in exe:
        raise SystemExit(f"FAIL: 仅进度 EXE 缺少通用状态：{message}")
for detail in ("respawn-stealth 管理员确认",
               "初始化未完成，退出码="):
    if detail.encode("utf-16le") in exe:
        raise SystemExit(f"FAIL: 仅进度 EXE 仍包含 launcher 详细弹窗：{detail}")
for payload in (
    root / "deploy/guest-stealth/respawn-stealth-local.ps1",
    root / "deploy/scripts/stock-viogpudo/viogpudo.sys",
    root / "deploy/nvapi-shim/nvapi64.dll",
    root / "deploy/adl-shim/atiadlxx.dll",
):
    if payload.read_bytes() not in exe:
        raise SystemExit(f"FAIL: 仅进度 EXE 缺少完整 payload：{payload.name}")
PY

for source_file in "$BUILD_SCRIPT" "$LAUNCHER" "$PROGRESS_UI"; do
    [[ "$(wc -l < "$source_file")" -le 500 ]] \
        || fail "生产文件超过 500 行: $source_file"
done

echo "OK: guest-stealth progress-only EXE checks passed"
