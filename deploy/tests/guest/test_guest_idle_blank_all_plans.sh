#!/usr/bin/env bash
# Guest idle-blank policy must cover every installed power plan, and upgrading
# an older installation must never overwrite the original values that rollback
# depends on.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
script="$repo_root/deploy/guest/guest-performance/Optimize-Guest.ps1"
query_test="$repo_root/deploy/tests/guest/powercfg_effective_values.tests.ps1"
rollback_flags_test="$repo_root/deploy/tests/guest/power_override_rollback_flags.tests.ps1"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[[ -f "$script" ]] || fail "missing $script"

# Static guarantees: the writer must target the snapshot's own plan, and the
# verifier must inspect every plan rather than only the active one.
grep -Fq '$Mode, [string]$Snapshot.SchemeGuid,' "$script" || \
    fail 'powercfg no longer writes to the plan recorded in the snapshot'
grep -Fq '& powercfg.exe /list' "$script" || \
    fail 'installed plan inventory does not use authoritative powercfg /list output'
grep -Fq 'Get-PowerSettingEffectiveValues' "$script" || \
    fail 'inherited power values are not resolved through powercfg /query'
grep -Fq 'foreach ($setting in (Get-AllPowerSettingSnapshots))' "$script" || \
    fail 'verify no longer checks every installed power plan'
grep -q 'function Get-PowerSchemeGuids' "$script" || \
    fail 'power plan enumeration helper is gone'
if grep -nE 'Get-PowerSettingSnapshot[[:space:]]+\$(entry|_)' "$script"; then
    fail 'a power-setting snapshot call omitted its explicit plan GUID'
fi
grep -Fq 'PowerSettings = @(Get-AllPowerSettingSnapshots)' "$script" || \
    fail 'fresh state does not capture every installed (plan, setting) pair'
grep -Fq 'foreach ($snapshot in (Get-AllPowerSettingSnapshots))' "$script" || \
    fail 'audit report does not enumerate every installed power plan'
writer_body=$(sed -n \
    '/^function Disable-AutomaticGuestBlanking {/,/^function Restore-PowerSettings {/p' \
    "$script")
grep -Fq '$current = @(Get-AllPowerSettingSnapshots)' <<<"$writer_body" || \
    fail 'writer targets are not refreshed from currently installed plans'
grep -Fq 'Rollback state does not cover' <<<"$writer_body" || \
    fail 'writer can change a newly installed plan without a saved original'
grep -Fq 'foreach ($snapshot in $current)' <<<"$writer_body" || \
    fail 'writer still walks stale rollback rows instead of current plans'
if grep -Fq 'if (-not [bool]$snapshot.Exists) { continue }' <<<"$writer_body"; then
    fail 'an inherited-value rollback baseline is still discarded'
fi
grep -Fq "Remove-ItemProperty -LiteralPath \$path" "$script" || \
    fail 'rollback cannot restore an originally inherited value'
grep -Fq 'automatic guest idle setting is unavailable' "$script" || \
    fail 'verification silently accepts a missing per-plan idle setting'

command -v pwsh >/dev/null 2>&1 || {
    echo "SKIP: pwsh unavailable; static checks passed"
    exit 0
}

pwsh -NoProfile -File "$(dirname "${BASH_SOURCE[0]}")/optimize_guest_state_merge.tests.ps1" \
    -ScriptPath "$script" || fail 'state-merge behaviour tests failed'
pwsh -NoProfile -File "$query_test" -ScriptPath "$script" || \
    fail 'localized powercfg query behaviour test failed'
pwsh -NoProfile -File "$rollback_flags_test" -ScriptPath "$script" || \
    fail 'power override-presence migration test failed'

echo "OK: guest idle-blank policy covers all power plans"
