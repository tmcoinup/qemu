#!/usr/bin/env bash
# GPU-P 单显示拓扑：只移除 Hyper-V 合成显示资源，完整事务回滚。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
GPUP="$REPO_ROOT/deploy/windows/gpup"
MODULE="$GPUP/VMate.HyperV.DisplayTopology.ps1"
SETTER="$GPUP/Set-VMateGpuPDisplayTopology.ps1"
RESTORE="$GPUP/Restore-VMateGpuPDisplayTopology.ps1"
STATUS="$GPUP/Get-VMateGpuPStatus.ps1"

fail() { echo "FAIL: $*" >&2; exit 1; }
require_text() {
    rg -F --quiet -- "$1" "$2" || fail "missing '$1' in $2"
}

for file in "$MODULE" "$SETTER" "$RESTORE" "$STATUS"; do
    [[ -f "$file" ]] || fail "missing display topology file: $file"
    [[ "$(od -An -tx1 -N3 "$file" | tr -d ' \n')" == efbbbf ]] ||
        fail "PowerShell 5.1 UTF-8 BOM missing: $file"
done
(( $(wc -l < "$MODULE") <= 500 )) ||
    fail 'display topology module exceeds 500 lines'

for text in \
    'function Get-VMateHyperVDisplayTopologySnapshot' \
    'function Set-VMateHyperVDisplayTopology' \
    'function Restore-VMateHyperVDisplayTopology' \
    'Msvm_SyntheticDisplayControllerSettingData' \
    'RemoveResourceSettings' \
    'AddResourceSettings' \
    "'EnhancedSessionGpuOnly'" \
    "'VMBus'" \
    'GpuPartitionAdapterCount -ne 1' \
    "\$status = 'Prepared'" \
    "Status = 'RolledBack'" \
    'GuestPnpRegistryModified = $false' \
    'GuestDriverModified = $false' \
    'CodeIntegrityModified = $false' \
    'RuntimeModelSwitch = $false'; do
    require_text "$text" "$MODULE"
done

if rg -n '(Set|New)-ItemProperty.*(ClassGUID|Capabilities)|'\
'NoDisplayInUI|Disable-PnpDevice|Enable-PnpDevice|bcdedit|testsigning|'\
'SendKeys|mouse_event|keybd_event' \
        "$MODULE" "$SETTER" "$RESTORE"; then
    fail 'display topology path contains guest PnP/CI/input mutation'
fi

require_text '[string]$ReceiptPath' "$SETTER"
require_text '[string]$ReceiptPath' "$RESTORE"
require_text 'Restore-VMateHyperVDisplayTopology' "$RESTORE"
require_text "VMate.HyperV.DisplayTopology.ps1" "$STATUS"
require_text 'Get-VMateHyperVDisplayTopologySnapshot' "$STATUS"
require_text 'DisplayTopology = $displayTopology' "$STATUS"
require_text 'ConsoleProfile = $displayTopology.Console' "$STATUS"

powershell_bin="$(command -v pwsh || command -v powershell || true)"
if [[ -n "$powershell_bin" ]]; then
    for file in "$MODULE" "$SETTER" "$RESTORE"; do
        VMATE_PARSE_FILE="$file" "$powershell_bin" -NoLogo -NoProfile \
            -NonInteractive -Command '
            $errors = $null
            [void][Management.Automation.Language.Parser]::ParseFile(
                $env:VMATE_PARSE_FILE, [ref]$null, [ref]$errors)
            if ($errors.Count) { throw ($errors | Out-String) }
        '
    done
else
    echo 'SKIP: PowerShell not found; display topology static contract passed'
fi

echo 'PASS: Hyper-V GPU-P display topology transaction contract'
