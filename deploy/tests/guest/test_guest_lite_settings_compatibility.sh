#!/usr/bin/env bash
# Guest Lite must not disable the Windows 10 service required by Settings >
# System, and old installations must restore only their saved original value.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
script="$repo_root/deploy/guest/guest-lite/G11-Guest-Lite.ps1"
behaviour_test="$repo_root/deploy/tests/guest/guest_lite_retired_service_restore.tests.ps1"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

active_services=$(sed -n \
    '/^\$ServicePlan = @(/,/^\$RetiredServicePlan = @(/p' "$script")
if grep -Fq "Name = 'CDPSvc'" <<<"$active_services"; then
    fail 'CDPSvc is still in the active disable plan'
fi
if grep -Fq "Name = 'NcbService'" <<<"$active_services"; then
    fail 'Network Connection Broker is in the active disable plan'
fi

retired_services=$(sed -n \
    '/^\$RetiredServicePlan = @(/,/^\$ServicePatternPlan = @(/p' "$script")
grep -Fq "Name = 'CDPSvc'" <<<"$retired_services" ||
    fail 'CDPSvc is not covered by the upgrade compatibility plan'

restore_body=$(sed -n \
    '/^function Restore-RetiredServiceSnapshots {/,/^function Test-TaskTargetAllowed {/p' \
    "$script")
grep -Fq 'Restore-ServiceSnapshot $snapshot' <<<"$restore_body" ||
    fail 'retired service migration does not restore the saved snapshot'
if grep -Eq '^[[:space:]]*(\$[^=]+=[[:space:]]*)?Get-ServiceSnapshot([[:space:]]|$)' \
        <<<"$restore_body"; then
    fail 'retired service migration re-samples the tool-modified live value'
fi

allowed_body=$(sed -n \
    '/^function Test-ServiceNameAllowed {/,/^function Get-ServiceInventoryIndex {/p' \
    "$script")
grep -Fq '$RetiredServicePlan.Name -icontains $Name' <<<"$allowed_body" ||
    fail 'rollback rejects a saved retired-service snapshot'

apply_body=$(sed -n '/^function Invoke-Apply {/,/^function Get-EnforcementRegistryEntry {/p' \
    "$script")
restore_line=$(grep -nF 'Restore-RetiredServiceSnapshots $state' <<<"$apply_body" |
    head -1 | cut -d: -f1)
disable_line=$(grep -nF 'Disable-PlannedServices' <<<"$apply_body" |
    head -1 | cut -d: -f1)
[[ -n "$restore_line" && -n "$disable_line" && "$restore_line" -lt "$disable_line" ]] ||
    fail 'Apply does not restore retired services before disabling active plans'

if ! command -v pwsh >/dev/null 2>&1; then
    echo 'SKIP: pwsh unavailable; Guest Lite Settings compatibility static checks passed'
    exit 0
fi
pwsh -NoProfile -File "$behaviour_test" -ScriptPath "$script"

echo 'OK: Guest Lite preserves Windows Settings service compatibility'
