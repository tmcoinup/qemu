#!/usr/bin/env bash
# Host-only production quarantine test. No VM, mdev, NBD or guest disk opens.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
START_VM="$REPO_ROOT/deploy/scripts/start-vm.sh"
WRAPPER="$REPO_ROOT/deploy/signed-consumer-production.sh"
PACKAGER="$REPO_ROOT/deploy/package-nvidia-53758-experiment.sh"
PROBE="$REPO_ROOT/deploy/probe-signed-consumer-vgpu.sh"
SYSTEM_PACKAGER="$REPO_ROOT/deploy/package-system-nvapi-projection.sh"
MONITOR_SYNC="$REPO_ROOT/deploy/scripts/sync-monitor-profile.sh"
CATALOG="$REPO_ROOT/deploy/lib/signed-consumer-catalog.sh"
DOCS="$REPO_ROOT/deploy/docs/SIGNED-CONSUMER-PRODUCTION.md"

fail() { echo "FAIL: $*" >&2; exit 1; }
require_text() { grep -F -- "$1" "$2" >/dev/null || fail "${3:-$1}"; }
TMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TMP_DIR"' EXIT

bash -n "$START_VM" "$WRAPPER" "$PACKAGER" "$PROBE" \
    "$SYSTEM_PACKAGER" "$MONITOR_SYNC" "$CATALOG"
[[ -x "$WRAPPER" && -s "$DOCS" ]] || fail 'wrapper/tutorial missing'
! rg -q '(readonly[[:space:]]+)?TARGET_VM_ID=|只允许迁移 VM9|VM10 qualification|signed-consumer-vm10' \
    "$WRAPPER" "$PACKAGER" || fail 'single-VM production hardcode remains'
! rg -q 'testsigning[[:space:]]+(on|yes)|nointegritychecks[[:space:]]+(on|yes)|bcdedit[[:space:]]+/set' \
    "$WRAPPER" "$PACKAGER" || fail 'integrity bypass appeared'
require_text 'snapshot' "$WRAPPER"
require_text 'ro,norecover' "$WRAPPER"
require_text 'signed-consumer-v2' "$CATALOG"
require_text 'quarantined-runtime-instability' "$CATALOG"
require_text 'Xid 43' "$CATALOG"
require_text 'TDR' "$CATALOG"
require_text '31.0.15.3833' "$CATALOG"
require_text 'signed_consumer_driver_assert_production_enabled' "$WRAPPER"
require_text 'signed_consumer_driver_assert_production_enabled' "$START_VM"
require_text 'signed_consumer_driver_assert_production_enabled' "$SYSTEM_PACKAGER"
require_text 'signed_consumer_driver_assert_production_enabled' "$MONITOR_SYNC"
require_text 'signed_consumer_driver_audited_default_for_profile' "$PROBE"
require_text 'signed_consumer_driver_audited_default_for_profile' "$PACKAGER"
require_text 'signed_consumer_driver_audited_default_for_profile' "$START_VM"
! grep -F 'source "$CONF"' "$PACKAGER" >/dev/null \
    || fail 'packager executes vm.conf instead of parsing literals'

# shellcheck source=../../lib/signed-consumer-catalog.sh
source "$CATALOG"
signed_consumer_catalog_validate || fail 'catalog validation failed'

mapfile -t keys < <(signed_consumer_driver_keys)
[[ ${#keys[@]} -eq 2 ]] || fail 'unexpected signed-consumer audit row count'
for key in "${keys[@]}"; do
    signed_consumer_driver_load "$key" || fail "cannot load $key"
    [[ "$SC_DRIVER_VERSION" == 31.0.15.3758 ]] \
        || fail "$key is not the isolated 537.58 route"
    [[ "$SC_PRODUCTION_STATUS" == \
        "$SIGNED_CONSUMER_PRODUCTION_STATUS_QUARANTINED" ]] \
        || fail "$key is not quarantined"
    [[ "$SC_PRODUCTION_REASON" == *'Xid 43'* &&
       "$SC_PRODUCTION_REASON" == *TDR* &&
       "$SC_PRODUCTION_REASON" == *31.0.15.3833* ]] \
        || fail "$key quarantine reason is incomplete"
    if signed_consumer_driver_assert_production_enabled \
            >"$TMP_DIR/production-enabled" 2>"$TMP_DIR/production-quarantine"; then
        fail "$key unexpectedly passed the production gate"
    fi
    require_text '已禁止进入生产路径' "$TMP_DIR/production-quarantine"
done

# The exact WHQL rows remain reproducible only through the explicitly
# disposable-clone experiment. They are never selected as production defaults.
[[ "$(signed_consumer_driver_audited_default_for_profile gtx750ti_asus_2gb)" == \
    nvidia-53758-dch-whql-gtx750ti-asus ]] \
    || fail 'GTX 750 Ti audit row is no longer reproducible'
[[ "$(signed_consumer_driver_audited_default_for_profile gtx1050_2gb)" == \
    nvidia-53758-dch-whql-gtx1050-dell ]] \
    || fail 'GTX 1050 audit row is no longer reproducible'
if signed_consumer_driver_default_for_profile gtx750ti_asus_2gb \
        >/dev/null 2>&1; then
    fail 'quarantined GTX 750 Ti route became a production default'
fi
if signed_consumer_driver_default_for_profile gtx1050_2gb >/dev/null 2>&1; then
    fail 'quarantined GTX 1050 route became a production default'
fi
if signed_consumer_driver_audited_default_for_profile gt1030_2gb \
        >/dev/null 2>&1; then
    fail 'GT 1030 unexpectedly gained an unaudited driver row'
fi

echo 'PASS: 537.58 remains audit-reproducible but is fail-closed in every production path'
