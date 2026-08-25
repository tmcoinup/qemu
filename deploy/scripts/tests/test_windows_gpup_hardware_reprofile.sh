#!/usr/bin/env bash
# 显式关机态换型、绑定历史、GPU-P 配额不变与事务回滚静态契约。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
GPUP="$REPO_ROOT/deploy/windows/gpup"
MODULE="$GPUP/VMate.GpuP.HardwareReprofile.ps1"
ENTRY="$GPUP/Set-VMateGpuPHardwareProfile.ps1"
PROFILE="$GPUP/VMate.GpuP.HardwareProfile.ps1"
IDENTITY_BOOT="$GPUP/VMate.HyperV.IdentityBoot.ps1"
IDENTITY_BOOT_SUPPORT="$GPUP/VMate.HyperV.IdentityBoot.Support.ps1"

fail() { echo "FAIL: $*" >&2; exit 1; }
require_text() {
    rg -F --quiet -- "$1" "$2" || fail "missing '$1' in $2"
}

for file in "$MODULE" "$ENTRY" "$IDENTITY_BOOT_SUPPORT"; do
    [[ -f "$file" ]] || fail "missing reprofile file: $file"
    [[ "$(od -An -tx1 -N3 "$file" | tr -d ' \n')" == efbbbf ]] ||
        fail "PowerShell 5.1 UTF-8 BOM missing: $file"
    (( $(wc -l < "$file") <= 500 )) || fail "file exceeds 500 lines: $file"
    if rg -n '\b(Read-Host|PromptForChoice|Start-VM|Stop-VM)\b' "$file"; then
        fail "interactive or runtime model switch in $file"
    fi
done

for name in Get-VMateGpuPHardwareReprofilePlan \
    Invoke-VMateGpuPHardwareReprofile \
    Get-VMateGpuPHardwareGpuAdapterSnapshot \
    Restore-VMateGpuPIdentityManifestBytes; do
    require_text "function $name" "$MODULE"
done
require_text '[string]$VM.State -cne '\''Off'\''' "$MODULE"
require_text 'AllowReprofile' "$MODULE"
require_text 'ReprofileReason' "$MODULE"
require_text 'GpuPartitionSnapshotSha256' "$MODULE"
require_text 'GPU-P adapter 或 100% 配额发生了变化' "$MODULE"
require_text '已恢复原硬件 profile' "$MODULE"
require_text 'Restore-VMateGpuPIdentityManifestBytes' "$MODULE"
require_text 'AllowProfileReplacement' "$IDENTITY_BOOT"
require_text 'preserve-unique-serials-explicit-offline-profile-replacement' \
    "$IDENTITY_BOOT_SUPPORT"
require_text "ReprofilePolicy = 'explicit-vm-off-transaction-only'" "$PROFILE"
require_text '普通启动禁止重新抽取' "$PROFILE"

powershell_bin="$(command -v pwsh || command -v powershell || true)"
if [[ -z "$powershell_bin" ]]; then
    echo 'SKIP: PowerShell not found; hardware reprofile static contract passed'
    exit 0
fi

VMATE_REPROFILE="$MODULE" \
"$powershell_bin" -NoLogo -NoProfile -NonInteractive -Command '
$ErrorActionPreference = "Stop"
. $env:VMATE_REPROFILE
$vm = [pscustomobject]@{
    Id=[Guid]"384f91db-197c-4c64-a9f1-4655037fb955"
    Name="mock"; State="Running"
}
$rejected = $false
try {
    Get-VMateGpuPHardwareReprofilePlan $vm host-native
    throw "running VM accepted"
} catch {
    if ($_.Exception.Message -eq "running VM accepted") { throw }
    $rejected = $true
}
if (-not $rejected) { throw "running VM rejection was not observed" }
Write-Output "running-state-rejected"
'

echo 'PASS: GPU-P explicit offline hardware reprofile contract'
