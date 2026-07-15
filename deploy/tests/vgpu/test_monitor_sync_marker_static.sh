#!/usr/bin/env bash
# Keep the offline EDID completion marker bound to every input that can change
# Windows' DISPLAY parent/device instance without changing the monitor profile.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SYNC="$REPO_ROOT/deploy/sync-monitor-profile.sh"
START_VM="$REPO_ROOT/deploy/start-vm.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[[ -r "$SYNC" ]] || fail "missing sync-monitor-profile.sh"

marker_block=$(
    awk '
        /^spec_hash=\$\(\{/ { copy = 1 }
        copy { print }
        copy && /^} \| sha256sum / { exit }
    ' "$SYNC"
)
[[ -n "$marker_block" ]] || fail "cannot locate marker hash block"

require_marker_input() {
    local expected=$1
    grep -F -- "$expected" <<<"$marker_block" >/dev/null ||
        fail "marker hash omits $expected"
}

require_marker_input '${SPOOF_MODE:-B}'
require_marker_input '${VGPU_MDEV_PROFILE:-nvidia-257}'
require_marker_input '${GPU_PCI_VID:-}'
require_marker_input '${GPU_PCI_DID:-}'
require_marker_input '${GPU_SUB_VID:-}'
require_marker_input '${GPU_SUB_DID:-}'
require_marker_input '${VGPU_PATCHED_DRIVER_INF:-}'
require_marker_input '${VGPU_PATCHED_DRIVER_VERSION:-}'
require_marker_input 'host-edid-sync-v4'

if grep -F 'host-edid-sync-v3' "$SYNC" >/dev/null; then
    fail "legacy v3 marker generation remains"
fi
grep -F -- '--marker-value "$spec_hash"' "$SYNC" >/dev/null ||
    fail "computed identity-bound hash is not passed to the cache helper"
grep -F -- 'MONITOR_SYNC_SPOOF_MODE="$SPOOF_MODE"' "$START_VM" >/dev/null ||
    fail "start-vm does not hash the effective post-CLI spoof mode"

echo "OK: monitor sync v4 marker includes GPU parent and patched-driver identity"
