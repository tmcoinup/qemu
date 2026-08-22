#!/usr/bin/env bash
# Keep the offline EDID completion marker bound to every input that can change
# Windows' DISPLAY parent/device instance without changing the monitor profile.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SYNC="$REPO_ROOT/deploy/scripts/sync-monitor-profile.sh"
START_VM="$REPO_ROOT/deploy/scripts/start-vm.sh"

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
require_marker_input '${VGPU_PATCHED_DRIVER_REQUIRED_VERSION:-}'
require_marker_input '${VGPU_PRODUCTION_MIGRATION_ID:-}'
require_marker_input '$MONITOR_DRIVER_VERSION'
require_marker_input '$MONITOR_DRIVER_INF_SHA256'
require_marker_input '$MONITOR_DRIVER_CATALOG_SHA256'
require_marker_input 'nvidia_modes.py'
require_marker_input 'windows_hive.py'
require_marker_input 'profile_override.toml'
require_marker_input 'update-vgpu-mdev-identity.py'
require_marker_input 'marker_file_digest monitor-profile-catalog'
require_marker_input 'marker_file_digest qemu-edid'
require_marker_input 'vgpu_display_contract=1:1920:1080:2073600'
require_marker_input 'host-edid-sync-v9-content-addressed'

grep -F -- 'vgpu_profile_native_grid_pnp_id' "$SYNC" >/dev/null ||
    fail "monitor sync does not map nvidia-256/257 to the native 1Q/2Q PnP ID"
grep -F -- "\${VGPU_MDEV_PROFILE:-}" "$SYNC" >/dev/null ||
    fail "monitor sync native PnP mapping is not selected from the VM profile"

if grep -E 'host-edid-sync-v(3|4|5|6|7|8)([^0-9]|$)' "$SYNC" >/dev/null; then
    fail "legacy v3..v8 marker generation remains"
fi
grep -F -- "printf 'file.%s=%s\\n'" "$SYNC" >/dev/null ||
    fail "marker file digests do not use stable logical labels"
if grep -F -- 'sha256sum "$MONITOR_PROFILE_CATALOG" "$QEMU_EDID"' "$SYNC" >/dev/null; then
    fail "marker still hashes absolute filenames emitted by sha256sum"
fi
grep -F -- '--marker-value "$spec_hash"' "$SYNC" >/dev/null ||
    fail "computed identity-bound hash is not passed to the cache helper"
grep -F -- '--driver-version "$MONITOR_DRIVER_VERSION"' "$SYNC" >/dev/null ||
    fail "locked production driver version is not passed explicitly"
grep -F -- '--driver-inf-sha256 "$MONITOR_DRIVER_INF_SHA256"' "$SYNC" >/dev/null ||
    fail "locked production INF hash is not passed explicitly"
grep -F -- 'MONITOR_SYNC_SPOOF_MODE="$SPOOF_MODE"' "$START_VM" >/dev/null ||
    fail "start-vm does not hash the effective post-CLI spoof mode"
grep -F -- '缺少 MONITOR_PROFILE；拒绝静默套用固定 Dell 身份' "$SYNC" >/dev/null ||
    fail "monitor sync still has a silent fixed-profile fallback"
if grep -F -- 'old_profile=${MONITOR_PROFILE:-dell-p2419h}' "$SYNC" >/dev/null; then
    fail "monitor sync still defaults arbitrary VMs to Dell P2419H"
fi
grep -F -- 'elif [[ -t 0 ]]; then' "$SYNC" >/dev/null ||
    fail "interactive start cannot obtain a temporary sudo ticket automatically"
grep -F -- 'sudo -v' "$SYNC" >/dev/null ||
    fail "interactive monitor sync omits secure sudo ticket acquisition"
grep -F -- '凭据不会写入仓库或参数' "$SYNC" >/dev/null ||
    fail "interactive privilege prompt does not document credential handling"
grep -F -- '非交互运行缺少 sudo 票据' "$SYNC" >/dev/null ||
    fail "non-interactive privilege failure is not explicit"

echo "OK: monitor sync v9 content marker, automatic privilege prompt, GPU, driver, EDID override, mode, and hive policies"
