#!/usr/bin/env bash
# Guest Lite must set display/sleep idle timeouts on every installed plan while
# preserving old rollback rows exactly during an upgrade.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
script="$repo_root/deploy/guest/guest-lite/G11-Guest-Lite.ps1"
behaviour_test="$repo_root/deploy/tests/guest/guest_lite_power_state_merge.tests.ps1"
query_test="$repo_root/deploy/tests/guest/powercfg_effective_values.tests.ps1"
rollback_flags_test="$repo_root/deploy/tests/guest/power_override_rollback_flags.tests.ps1"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

for setting in VIDEOIDLE STANDBYIDLE; do
    grep -Fq "Name = '$setting'" "$script" ||
        fail "Guest Lite omitted $setting"
done
grep -Fq 'foreach ($schemeGuid in @(Get-PowerSchemeGuids))' "$script" ||
    fail 'Guest Lite does not enumerate every installed power plan'
grep -Fq '$Mode, $schemeGuid,' "$script" ||
    fail 'powercfg does not target the plan recorded in each snapshot'
grep -Fq '& powercfg.exe /List' "$script" ||
    fail 'installed plan inventory does not use authoritative powercfg /List output'
grep -Fq 'Get-PowerSettingEffectiveValues' "$script" ||
    fail 'inherited power values are not resolved through powercfg /Query'
grep -Fq 'foreach ($setting in @(Get-AllPowerSettingSnapshots))' "$script" ||
    fail 'verification does not inspect every installed plan'
grep -Fq 'Merge-PowerSettingSnapshots' "$script" ||
    fail 'append-only rollback merge is missing'
writer_body=$(sed -n \
    '/^function Set-PerformancePowerPlan {/,/^function Restore-PowerSettings {/p' \
    "$script")
grep -Fq '$currentSettings = @(Get-AllPowerSettingSnapshots)' \
    <<<"$writer_body" ||
    fail 'the writer does not refresh its installed-plan targets'
grep -Fq 'Set-PowerSettingValues -Snapshot $setting -ACValue 0 -DCValue 0' \
    <<<"$writer_body" ||
    fail 'the writer does not apply Never to each freshly enumerated pair'
if grep -Fq 'Set-PowerSettingValues -Snapshot $snapshot' <<<"$writer_body"; then
    fail 'the writer still targets stale rollback rows from removed plans'
fi
if grep -Fq 'if (-not [bool]$snapshot.Exists) { continue }' <<<"$writer_body"; then
    fail 'an inherited-value rollback baseline is still discarded'
fi
grep -Fq "Remove-ItemProperty -LiteralPath \$path" "$script" ||
    fail 'rollback cannot restore an originally inherited value'
if grep -nE 'Get-PowerSettingSnapshot[[:space:]]+\$(entry|_)' "$script"; then
    fail 'a snapshot call omitted its explicit power-plan GUID'
fi

if ! command -v pwsh >/dev/null 2>&1; then
    echo 'SKIP: pwsh unavailable; Guest Lite static power checks passed'
    exit 0
fi
pwsh -NoProfile -File "$behaviour_test" -ScriptPath "$script"
pwsh -NoProfile -File "$query_test" -ScriptPath "$script"
pwsh -NoProfile -File "$rollback_flags_test" -ScriptPath "$script"

echo 'OK: Guest Lite display/sleep Never policy covers all power plans'
