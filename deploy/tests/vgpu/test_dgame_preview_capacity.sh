#!/usr/bin/env bash
set -euo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
DEPLOY_ROOT=$(cd "$TEST_DIR/../.." && pwd)
CHECKER="$DEPLOY_ROOT/host/check-dgame-preview-capacity.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/sys/renderD128/device" "$TEST_ROOT/drivers/amdgpu" \
    "$TEST_ROOT/dev"
printf '0x1002\n' >"$TEST_ROOT/sys/renderD128/device/vendor"
printf '0x67ff\n' >"$TEST_ROOT/sys/renderD128/device/device"
ln -s "$TEST_ROOT/drivers/amdgpu" "$TEST_ROOT/sys/renderD128/device/driver"

output=$(DRM_SYSFS_ROOT="$TEST_ROOT/sys" DRI_DEV_ROOT="$TEST_ROOT/dev" \
    "$CHECKER" --instances 16 --rate 60)
grep -q '^GPU_DRIVER=amdgpu$' <<<"$output"
grep -q '^SOURCE_UPLOAD size=1920x1080 instances=16 rate=60 pixel_mib_s=7594 texture_mib=127$' \
    <<<"$output"
grep -q '^LOAD roi=800x600 instances=16 rate=60 roi_mib_s=1758 combined_mib_s=9352 texture_mib_est=186$' \
    <<<"$output"
grep -q '^LOAD roi=1067x600 instances=16 rate=60 roi_mib_s=2345 combined_mib_s=9939 texture_mib_est=205$' \
    <<<"$output"
grep -q '^RESULT=ELIGIBLE ' <<<"$output"

small_source=$(DRM_SYSFS_ROOT="$TEST_ROOT/sys" DRI_DEV_ROOT="$TEST_ROOT/dev" \
    "$CHECKER" --instances 16 --source-size 1067x600 --size 800x600 --rate 30)
grep -q '^SOURCE_UPLOAD size=1067x600 instances=16 rate=30 pixel_mib_s=1173 texture_mib=40$' \
    <<<"$small_source"

! DRM_SYSFS_ROOT="$TEST_ROOT/sys" DRI_DEV_ROOT="$TEST_ROOT/dev" \
    "$CHECKER" --size invalid >/dev/null 2>&1

echo "PASS: 16-window RX550/RX570 preview capacity sizing"
