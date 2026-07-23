#!/usr/bin/env bash
# 在可用 PowerShell 上执行共享 DIMM 目录的 Windows 选择/旧 profile 回归。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TEST_SCRIPT="$SCRIPT_DIR/test_windows_memory_catalog.ps1"

shell_bin="$(command -v pwsh || command -v powershell || true)"
if [[ -z "$shell_bin" ]]; then
    # Linux/Python/C 侧的一致性仍由 test_shared_memory_catalog.sh 强制执行。
    echo "PASS: PowerShell unavailable; Windows memory runtime test skipped"
    exit 0
fi

"$shell_bin" -NoLogo -NoProfile -NonInteractive -File "$TEST_SCRIPT" \
    -RepoRoot "$REPO_ROOT"
