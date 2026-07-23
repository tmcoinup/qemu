#!/usr/bin/env bash
# Windows 相邻实例的 UUID/MAC/NVMe/显示器文本序列号必须分别保持唯一。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
POWERSHELL="$(command -v pwsh || command -v powershell || true)"

if [[ -z "$POWERSHELL" ]]; then
    echo "SKIP: PowerShell not found"
    exit 0
fi

VMATE_REPO_ROOT="$REPO_ROOT" \
    "$POWERSHELL" -NoLogo -NoProfile -NonInteractive -Command '
$ErrorActionPreference = "Stop"
. "$env:VMATE_REPO_ROOT/deploy/windows/lib/VMate.ProfileStore.ps1"

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) `
    ("vmate-profile-unique-" + [Guid]::NewGuid().ToString("N"))
try {
    $firstDirectory = Join-Path $testRoot "vms/1"
    New-Item -ItemType Directory -Force -Path $firstDirectory | Out-Null
    $first = [pscustomobject]@{
        identity = [pscustomobject]@{
            uuid = "11111111-1111-4111-8111-111111111111"
            mac = "00:50:56:11:11:11"
            nvme_serial = "S4EVNX0M111111"
            monitor_serial = "H4ZMC12345"
        }
    }
    $firstPath = Join-Path $firstDirectory "hardware-profile.json"
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText(
        $firstPath, ($first | ConvertTo-Json -Depth 8), $utf8)

    # 另外三类身份刻意不同，确保拒绝结果只能由显示器序列号触发。
    $candidate = [pscustomobject]@{
        identity = [pscustomobject]@{
            uuid = "22222222-2222-4222-8222-222222222222"
            mac = "00:50:56:22:22:22"
            nvme_serial = "S4EVNX0M222222"
            monitor_serial = "H4ZMC12345"
        }
    }
    $candidatePath = Join-Path $testRoot "vms/2/hardware-profile.json"
    if (Test-VMateProfileIdentityUnique $candidate $candidatePath) {
        throw "相邻实例复用显示器文本序列号仍被判定为唯一。"
    }

    $candidate.identity.monitor_serial = "H4ZMC54321"
    if (-not (Test-VMateProfileIdentityUnique $candidate $candidatePath)) {
        throw "互不重复的四类全局身份被误判为冲突。"
    }
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
Write-Output "OK: Windows cross-instance monitor serial uniqueness passed"
'
