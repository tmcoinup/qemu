#!/usr/bin/env bash
# Hyper-V KVP 最小元数据模式：官方 integration service + guest stale-key cleanup。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
GPUP="$REPO_ROOT/deploy/windows/gpup"
MODULE="$GPUP/VMate.HyperV.MetadataExchange.ps1"
DISABLE="$GPUP/Disable-VMateGpuPMetadataExchange.ps1"
RESTORE="$GPUP/Restore-VMateGpuPMetadataExchange.ps1"

fail() { echo "FAIL: $*" >&2; exit 1; }
require_text() {
    rg -F --quiet -- "$1" "$2" || fail "missing '$1' in $2"
}

for file in "$MODULE" "$DISABLE" "$RESTORE"; do
    [[ -f "$file" ]] || fail "missing metadata exchange file: $file"
    [[ "$(od -An -tx1 -N3 "$file" | tr -d ' \n')" == efbbbf ]] ||
        fail "PowerShell 5.1 UTF-8 BOM missing: $file"
done
(( $(wc -l < "$MODULE") <= 500 )) ||
    fail 'metadata exchange module exceeds 500 lines'

for text in \
    'function Get-VMateHyperVMetadataExchangeHostSnapshot' \
    'function Disable-VMateHyperVMetadataExchange' \
    'function Restore-VMateHyperVMetadataExchange' \
    '2A34B1C2-FD73-4043-8A5B-DD2159BC743F' \
    'Disable-VMIntegrationService' \
    'Enable-VMIntegrationService' \
    'vmickvpexchange' \
    'Virtual Machine\Guest\Parameters' \
    "Status = 'RolledBack'" \
    'CredentialPersisted = $false' \
    "'vmicvmsession', 'vmicrdv', 'vmicheartbeat'"; do
    require_text "$text" "$MODULE"
done

if rg -n 'Disable-PnpDevice|ClassGUID|NoDisplayInUI|bcdedit|testsigning|'\
'SendKeys|mouse_event|keybd_event|New-Service|Register-ScheduledTask' \
        "$MODULE" "$DISABLE" "$RESTORE"; then
    fail 'metadata exchange path contains PnP/CI/input/persistence mutation'
fi
if rg -n '^\s*\$host\s*=' "$MODULE"; then
    fail 'metadata exchange module overwrites PowerShell automatic $Host variable'
fi

require_text '[PSCredential]$GuestCredential' "$DISABLE"
require_text '[string]$ReceiptPath' "$DISABLE"
require_text 'Restore-VMateHyperVMetadataExchange' "$RESTORE"

powershell_bin="$(command -v pwsh || command -v powershell || true)"
if [[ -n "$powershell_bin" ]]; then
    for file in "$MODULE" "$DISABLE" "$RESTORE"; do
        VMATE_PARSE_FILE="$file" "$powershell_bin" -NoLogo -NoProfile \
            -NonInteractive -Command '
            $errors = $null
            [void][Management.Automation.Language.Parser]::ParseFile(
                $env:VMATE_PARSE_FILE, [ref]$null, [ref]$errors)
            if ($errors.Count) { throw ($errors | Out-String) }
        '
    done
else
    echo 'SKIP: PowerShell not found; metadata exchange static contract passed'
fi

echo 'PASS: Hyper-V minimal host metadata exchange transaction contract'
