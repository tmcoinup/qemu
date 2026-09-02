#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
configure="$repo_root/deploy/configure-g11-vgpu-host.sh"
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
MDEV_DEVICES_DIR="$tmp_dir/mdev-devices"
VGPU_HOST_LOCK_FILE="$tmp_dir/vgpu-host.lock"
VGPU_HOST_LOCK_WAIT_SECONDS=2
NVIDIA_MODULE_VERSION_FILE="$tmp_dir/nvidia-version"
export MDEV_DEVICES_DIR VGPU_HOST_LOCK_FILE VGPU_HOST_LOCK_WAIT_SECONDS \
    NVIDIA_MODULE_VERSION_FILE
mkdir -p "$MDEV_DEVICES_DIR"
: >"$VGPU_HOST_LOCK_FILE"
printf '%s\n' 535.161.05 >"$NVIDIA_MODULE_VERSION_FILE"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_assignment() {
    local file=$1 assignment=$2
    grep -Fxq -- "$assignment" "$file" || \
        fail "$file missing $assignment"
}

[[ -x "$configure" ]] || fail 'configure wrapper is not executable'

rtx_conf="$tmp_dir/rtx.conf"
"$configure" --output "$rtx_conf" >"$tmp_dir/rtx.out"
assert_assignment "$rtx_conf" 'VGPU_HOST_FB_TIER_MB=2048'
assert_assignment "$rtx_conf" 'VGPU_HOST_FB_MODE=equal'
assert_assignment "$rtx_conf" 'VGPU_RESOURCE_PROFILE=nvidia-257'
assert_assignment "$rtx_conf" 'VGPU_RESOURCE_FB_MB=2048'
assert_assignment "$rtx_conf" 'VGPU_TOTAL_FB_MB=16384'
assert_assignment "$rtx_conf" 'VGPU_HOST_CPU_NODE_BIND=all'
assert_assignment "$rtx_conf" 'VGPU_HOST_MEMORY_NODE_BIND=all'
assert_assignment "$rtx_conf" 'VGPU_MDEV_IDENTITY_MODE=auto'
assert_assignment "$rtx_conf" 'VGPU_RM_FB_IDENTITY_MODE=required'
assert_assignment "$rtx_conf" 'SPOOF_MODE=B'
if grep -Eq '15872|RESERVE|PASSWORD|TOKEN|CREDENTIAL' "$rtx_conf"; then
    fail 'RTX policy contains a reserve or credential-like field'
fi

printf '%s\n' 580.159.01 >"$NVIDIA_MODULE_VERSION_FILE"
v100_conf="$tmp_dir/v100.conf"
"$configure" --preset v100-pcie-32gb --tier 1024 \
    --gpu 0000:65:00.0 --output "$v100_conf" >"$tmp_dir/v100.out"
assert_assignment "$v100_conf" 'VGPU_MGPU=0000:65:00.0'
assert_assignment "$v100_conf" 'VGPU_HOST_FB_MODE=equal'
assert_assignment "$v100_conf" 'VGPU_HOST_FB_TIER_MB=1024'
assert_assignment "$v100_conf" 'VGPU_RESOURCE_PROFILE=V100D-1Q'
assert_assignment "$v100_conf" 'VGPU_RESOURCE_FB_MB=1024'
assert_assignment "$v100_conf" 'VGPU_TOTAL_FB_MB=32768'
assert_assignment "$v100_conf" 'VGPU_HOST_CPU_NODE_BIND=all'
assert_assignment "$v100_conf" 'VGPU_HOST_MEMORY_NODE_BIND=all'
assert_assignment "$v100_conf" 'VGPU_MDEV_IDENTITY_MODE=required'
assert_assignment "$v100_conf" 'VGPU_RM_FB_IDENTITY_MODE=off'
assert_assignment "$v100_conf" 'SPOOF_MODE=B'
if grep -Eq 'VGPU_RESOURCE_PROFILE_(1024|2048)' "$v100_conf"; then
    fail 'V100 policy published a mixed-size dual mapping'
fi

# With no legacy --tier request, vGPU 19 V100 defaults to the officially
# supported mixed-size mode and publishes both reviewed Q profiles.
mixed_conf="$tmp_dir/v100-mixed.conf"
"$configure" --preset v100-sxm2-16gb --gpu 0000:81:00.0 \
    --output "$mixed_conf" >"$tmp_dir/v100-mixed.out"
assert_assignment "$mixed_conf" 'VGPU_MGPU=0000:81:00.0'
assert_assignment "$mixed_conf" 'VGPU_HOST_FB_MODE=mixed'
assert_assignment "$mixed_conf" 'VGPU_RESOURCE_PROFILE_1024=V100X-1Q'
assert_assignment "$mixed_conf" 'VGPU_RESOURCE_PROFILE_2048=V100X-2Q'
assert_assignment "$mixed_conf" 'VGPU_TOTAL_FB_MB=16384'
assert_assignment "$mixed_conf" 'VGPU_HOST_CPU_NODE_BIND=all'
assert_assignment "$mixed_conf" 'VGPU_HOST_MEMORY_NODE_BIND=all'
assert_assignment "$mixed_conf" 'VGPU_RM_FB_IDENTITY_MODE=off'
if grep -Eq '^VGPU_(HOST_FB_TIER_MB|RESOURCE_PROFILE|RESOURCE_FB_MB)=' \
        "$mixed_conf"; then
    fail 'mixed-size V100 policy also published a fixed tier/static profile'
fi
if "$configure" --preset v100-sxm2-16gb --fb-mode mixed --tier 1024 \
        --output "$tmp_dir/invalid-mixed.conf" >/dev/null 2>&1; then
    fail 'mixed-size policy accepted an ambiguous --tier'
fi
if "$configure" --preset rtx2080-16gb --fb-mode mixed \
        --output "$tmp_dir/invalid-rtx-mixed.conf" >/dev/null 2>&1; then
    fail 'RTX 2080 policy accepted unverified mixed-size mode'
fi
if "$configure" --cpu-node-bind invalid \
        --output "$tmp_dir/invalid-cpu-node.conf" >/dev/null 2>&1; then
    fail 'wrapper accepted an invalid CPU NUMA policy'
fi
if "$configure" --memory-node-bind invalid \
        --output "$tmp_dir/invalid-memory-node.conf" >/dev/null 2>&1; then
    fail 'wrapper accepted an invalid memory NUMA policy'
fi
if "$configure" --cpu-node-bind local --memory-node-bind all \
        --output "$tmp_dir/invalid-mixed-numa.conf" >/dev/null 2>&1; then
    fail 'wrapper accepted a mixed CPU/RAM NUMA policy'
fi

local_v100_conf="$tmp_dir/v100-local-numa.conf"
"$configure" --preset v100-pcie-16gb --tier 1024 \
    --cpu-node-bind local --memory-node-bind local \
    --output "$local_v100_conf" >/dev/null
assert_assignment "$local_v100_conf" 'VGPU_HOST_CPU_NODE_BIND=local'
assert_assignment "$local_v100_conf" 'VGPU_HOST_MEMORY_NODE_BIND=local'

# The production V100/R535 path keeps the same dual-socket CPU policy while
# enabling the reviewed high-rate console REGION contract.
printf '%s\n' 535.161.05 >"$NVIDIA_MODULE_VERSION_FILE"
r535_v100_conf="$tmp_dir/v100-r535.conf"
"$configure" --preset v100-sxm2-16gb --tier 1024 \
    --output "$r535_v100_conf" >/dev/null
assert_assignment "$r535_v100_conf" 'VGPU_HOST_CPU_NODE_BIND=all'
assert_assignment "$r535_v100_conf" 'VGPU_HOST_MEMORY_NODE_BIND=all'
assert_assignment "$r535_v100_conf" 'VGPU_CONSOLE_INTERVAL_US=8333'
assert_assignment "$r535_v100_conf" 'VGPU_RM_FB_IDENTITY_MODE=required'
printf '%s\n' 580.159.01 >"$NVIDIA_MODULE_VERSION_FILE"

if "$configure" --preset v100-pcie-16gb --tier 2048 \
        --output "$v100_conf" >"$tmp_dir/overwrite.out" \
        2>"$tmp_dir/overwrite.err"; then
    fail 'wrapper overwrote an existing different policy without --force'
fi
grep -Fq -- '--force' "$tmp_dir/overwrite.err" || \
    fail 'overwrite refusal did not explain --force'

"$configure" --preset v100-pcie-16gb --tier 2048 --force \
    --output "$v100_conf" >"$tmp_dir/force.out"
assert_assignment "$v100_conf" 'VGPU_RESOURCE_PROFILE=V100-2Q'
assert_assignment "$v100_conf" 'VGPU_TOTAL_FB_MB=16384'

# Publishing must take the same persistent lock as mdev create/remove.  A
# competing holder blocks the scan-to-rename transaction and leaves the old
# policy untouched.
exec 8<"$VGPU_HOST_LOCK_FILE"
flock -x 8
if VGPU_HOST_LOCK_WAIT_SECONDS=1 "$configure" \
        --preset v100-pcie-32gb --tier 1024 --force \
        --output "$v100_conf" >"$tmp_dir/lock-busy.out" \
        2>"$tmp_dir/lock-busy.err"; then
    flock -u 8
    exec 8<&-
    fail 'wrapper published while the shared vGPU host lock was held'
fi
flock -u 8
exec 8<&-
grep -Fq '全局锁超时' "$tmp_dir/lock-busy.err" || \
    fail 'shared-lock contention refusal was not clear'
assert_assignment "$v100_conf" 'VGPU_RESOURCE_PROFILE=V100-2Q'

ln -s "$tmp_dir" \
    "$MDEV_DEVICES_DIR/11111111-2222-3333-4444-555555555555"
if "$configure" --preset v100-pcie-32gb --tier 1024 --force \
        --output "$v100_conf" >"$tmp_dir/active.out" \
        2>"$tmp_dir/active.err"; then
    fail 'wrapper changed the host tier while an mdev was active'
fi
grep -Fq '活动 mdev' "$tmp_dir/active.err" || \
    fail 'active-mdev refusal was not clear'
rm "$MDEV_DEVICES_DIR/11111111-2222-3333-4444-555555555555"

# Any existing unsafe lock inode is a hard refusal, not the pre-driver
# bootstrap exception.
ln -s "$VGPU_HOST_LOCK_FILE" "$tmp_dir/vgpu-host-link.lock"
if VGPU_HOST_LOCK_FILE="$tmp_dir/vgpu-host-link.lock" \
        "$configure" --preset v100-pcie-32gb --tier 1024 --force \
        --output "$v100_conf" >"$tmp_dir/unsafe-lock.out" \
        2>"$tmp_dir/unsafe-lock.err"; then
    fail 'wrapper followed a symlinked vGPU host lock'
fi
grep -Fq '全局锁缺失/不安全' "$tmp_dir/unsafe-lock.err" || \
    fail 'unsafe shared-lock refusal was not clear'

# A genuinely absent lock is allowed only for pre-driver preparation with an
# empty mdev tree.  This must not create the mode-state/lock file itself.
bootstrap_conf="$tmp_dir/bootstrap.conf"
bootstrap_lock="$tmp_dir/not-installed/vgpu-host.lock"
VGPU_HOST_LOCK_FILE="$bootstrap_lock" "$configure" \
    --preset v100-pcie-16gb --tier 2048 --output "$bootstrap_conf" \
    >"$tmp_dir/bootstrap.out"
assert_assignment "$bootstrap_conf" 'VGPU_RESOURCE_PROFILE=V100-2Q'
[[ ! -e "$bootstrap_lock" && ! -L "$bootstrap_lock" ]] || \
    fail 'pre-driver configure unexpectedly created the shared lock'

link_target="$tmp_dir/target.conf"
link_path="$tmp_dir/link.conf"
: >"$link_target"
ln -s "$link_target" "$link_path"
if "$configure" --output "$link_path" >"$tmp_dir/link.out" \
        2>"$tmp_dir/link.err"; then
    fail 'wrapper followed a symlink output'
fi
grep -Fq '符号链接' "$tmp_dir/link.err" || \
    fail 'symlink refusal was not clear'

echo 'PASS: G-11 wrapper emits equal-size RTX/V100 and mixed-size vGPU 19.5 V100 policies'
