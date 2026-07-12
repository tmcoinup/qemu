#!/usr/bin/env bash
# 验证 guest-stealth 单文件 EXE 可在当前 host 上交叉编译，并带上必要 payload。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

OUT_DIR="$TMP_DIR/out"
BUILD_DIR="$TMP_DIR/build"

OUT_DIR="$OUT_DIR" \
BUILD_DIR="$BUILD_DIR" \
    "$REPO_ROOT/deploy/guest-stealth/build-exe.sh" >/dev/null

EXE="$OUT_DIR/respawn-stealth.exe"
[[ -s "$EXE" ]] || fail "未生成 respawn-stealth.exe"

file "$EXE" | grep -F 'PE32+ executable' >/dev/null \
    || fail "输出不是 Windows PE64 EXE: $(file "$EXE")"

strings -a "$EXE" | grep -F 'requireAdministrator' >/dev/null \
    || fail "EXE 未嵌入 requireAdministrator manifest"
x86_64-w64-mingw32-objdump -x "$EXE" | grep -F 'Entry: ID: 0x000018' >/dev/null \
    || fail "EXE 资源表缺少 RT_MANIFEST(type 24)"
x86_64-w64-mingw32-objdump -x "$EXE" | grep -F 'Entry: ID: 0x000001' >/dev/null \
    || fail "EXE 资源表缺少 manifest id 1"
strings -a "$EXE" | grep -F 'respawn-stealth-local.ps1' >/dev/null \
    || fail "EXE 未包含 respawn payload 文件名"
strings -a "$EXE" | grep -F 'apply-gpu-spoof.ps1' >/dev/null \
    || fail "EXE 未包含 apply-gpu-spoof payload 文件名"
strings -a "$EXE" | grep -F 'MessageBoxW' >/dev/null \
    || fail "EXE 未导入运行前确认弹窗"
strings -a -el "$EXE" | grep -F -- '--firstlogon' >/dev/null \
    || fail "EXE 缺少 FirstLogon 无人值守参数"
strings -a -el "$EXE" | grep -F -- '--no-confirm' >/dev/null \
    || fail "EXE 缺少跳过确认弹窗参数"
strings -a "$EXE" | grep -F 'Enable-RespawnDisplayDevices' >/dev/null \
    || fail "EXE 未包含 Code 22 外层启用兜底"
strings -a "$EXE" | grep -F 'Enable-StealthDisplayDevices' >/dev/null \
    || fail "EXE 未包含 Code 22 apply 启用兜底"
strings -a -el "$EXE" | grep -F -- '-FirstLogon' >/dev/null \
    || fail "EXE 未把 FirstLogon 模式传给内嵌脚本"
strings -a "$EXE" | grep -F -- '-SkipTask' >/dev/null \
    || fail "EXE 内嵌脚本 FirstLogon 模式未使用 -SkipTask"
strings -a "$EXE" | grep -F 'StealthGPU-RefreshName' >/dev/null \
    || fail "EXE 内嵌脚本缺少清理 StealthGPU-RefreshName 的逻辑"

echo "OK: guest-stealth single EXE build checks passed"
