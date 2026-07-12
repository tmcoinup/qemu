#!/usr/bin/env bash
# 验证 clone 首启 GPU 重对齐只在 OOBE 后执行 D 盘 EXE 一次，不依赖固定 host HTTP/IP。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
UNATTEND="$REPO_ROOT/deploy/autounattend/autounattend.xml"
CLONE="$REPO_ROOT/deploy/scripts/clone-from-base.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

require_text() {
    local needle="$1"
    local file="$2"

    grep -F -- "$needle" "$file" >/dev/null \
        || fail "missing '$needle' in $file"
}

reject_text() {
    local needle="$1"
    local file="$2"

    if grep -F -- "$needle" "$file" >/dev/null; then
        fail "unexpected '$needle' in $file"
    fi
}

require_text 'D:\工具\respawn-stealth.exe' "$UNATTEND"
require_text "--firstlogon" "$UNATTEND"
reject_text '192.168.30.33:8765/respawn-stealth.ps1' "$UNATTEND"
reject_text 'irm http://192.168.30.33:8765/respawn-stealth.ps1 | iex' "$UNATTEND"
reject_text 'C:\stealth\respawn-stealth-local.ps1' "$UNATTEND"
reject_text 'C:\stealth\respawn-firstlogon.log' "$UNATTEND"

reject_text 'serve-stealth-http.py' "$CLONE"
reject_text '让 guest FirstLogon 能拉 respawn-stealth.ps1' "$CLONE"
require_text 'D:\\工具\\respawn-stealth.exe' "$CLONE"

echo "OK: guest stealth FirstLogon runs D drive EXE once without fixed HTTP"
