#!/usr/bin/env bash
# Windows 发布只能消费 VMate 托管的 QEMU，禁止回退到独立系统安装。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
LAUNCHER="$REPO_ROOT/deploy/windows/start-vm.ps1"

if grep -Fq 'C:\Program Files\qemu\qemu-system-x86_64.exe' "$LAUNCHER"; then
    echo 'FAIL: Windows 启动器仍会回退到公开 QEMU 安装目录' >&2
    exit 1
fi
grep -Fq "(Join-Path \$repo 'qemu-system-x86_64.exe')" "$LAUNCHER" \
    || { echo 'FAIL: Windows 启动器缺少 VMate 托管运行时候选' >&2; exit 1; }

echo 'PASS: Windows launcher only discovers VMate-managed QEMU candidates'
