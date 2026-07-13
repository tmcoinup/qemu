#!/usr/bin/env bash
# 验证 Linux/Windows 客体硬件快照工具的语法、并发机制和关键证据覆盖面。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
LINUX_COLLECTOR="$REPO_ROOT/deploy/scripts/guest/collect-hardware-snapshot.sh"
WINDOWS_COLLECTOR="$REPO_ROOT/deploy/windows/collect-hardware-snapshot.ps1"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

require_text() {
    local needle="$1" file="$2"
    grep -F -- "$needle" "$file" >/dev/null || fail "$file 缺少: $needle"
}

bash -n "$LINUX_COLLECTOR"
for marker in 'wait_for_slot' 'dmidecode --type' 'lspci -nnvv' 'nvme id-ctrl' \
              'tpm2_getcap properties-fixed' 'edid-decode' 'dmesg --level='; do
    require_text "$marker" "$LINUX_COLLECTOR"
done

for marker in 'Start-Job' 'Win32_Processor' 'Win32_PhysicalMemory' 'Get-PnpDevice' \
              'Get-PhysicalDisk' 'Get-Tpm' 'Get-WinEvent' 'dxdiag.exe' 'pnputil.exe'; do
    require_text "$marker" "$WINDOWS_COLLECTOR"
done

if command -v pwsh >/dev/null 2>&1; then
    # shellcheck disable=SC2016 # PowerShell 代码必须由 pwsh 而不是 Bash 展开 `$errors`。
    WINDOWS_COLLECTOR="$WINDOWS_COLLECTOR" pwsh -NoLogo -NoProfile -NonInteractive \
        -Command '
            $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile(
                $env:WINDOWS_COLLECTOR, [ref]$null, [ref]$errors)
            if ($errors.Count -gt 0) {
                $errors | ForEach-Object { Write-Error $_.Message }
                exit 1
            }
        '
fi

echo "OK: guest hardware snapshot static checks passed"
