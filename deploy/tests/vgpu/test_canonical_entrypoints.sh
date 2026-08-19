#!/usr/bin/env bash
# deploy/scripts entrypoints are the only public lifecycle implementations.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
DEPLOY="$REPO_ROOT/deploy"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

CANONICAL_ENTRIES=(
    start-vm.sh
    stop-vm.sh
    create-vm.sh
    create-disk.sh
    clone-from-base.sh
    seal-base.sh
    host-clean-tencent.sh
    delete-vm.sh
    sync-monitor-profile.sh
    migrate-g11-layout.sh
    recover-hibernated-vm.sh
    report-vm-boot-timing.sh
    vmctl.sh
    ctl-vm.sh
    setup-bridge.sh
    host-nvme-apst.sh
)

COMPATIBILITY_ALIASES=(
    clone-vgpu-base.sh
    promote-base.sh
)

REMOVED_ROOT_ENTRIES=(
    start-vm.sh
    stop-vm.sh
    create-vm.sh
    create-disk.sh
    clone-vgpu-base.sh
    promote-base.sh
    clone-from-base.sh
    seal-base.sh
    delete-vm.sh
    sync-monitor-profile.sh
    migrate-g11-layout.sh
    recover-hibernated-vm.sh
    report-vm-boot-timing.sh
    vmctl.sh
)

for entry in "${CANONICAL_ENTRIES[@]}"; do
    path="$DEPLOY/scripts/$entry"
    [[ -x "$path" ]] || fail "canonical entry is not executable: $path"
    bash -n "$path"
done

for entry in "${COMPATIBILITY_ALIASES[@]}"; do
    path="$DEPLOY/scripts/$entry"
    [[ -x "$path" ]] || fail "compatibility alias is not executable: $path"
    bash -n "$path"
done

for entry in "${REMOVED_ROOT_ENTRIES[@]}"; do
    [[ ! -e "$DEPLOY/$entry" ]] ||
        fail "removed root entry still exists: $DEPLOY/$entry"
done
[[ ! -e "$DEPLOY/host/setup-bridge.sh" ]] ||
    fail "removed host bridge entry still exists"

# The primary entry must still resolve the deploy-root libraries and remain
# read-only during path inspection after being moved into deploy/scripts.
CUSTOM_ROOT="$TMP_DIR/custom vms"
unset_args=(
    env -u VM_ROOT -u VMS_DIR -u VM_INSTANCES_DIR -u VM_INSTANCE_DIR
    -u VM_INSTANCE_ID -u VM_SHARED_DIR -u VM_CONFIG_DIR -u VM_DISK_DIR
    -u VM_BASE_DIR -u VM_NVRAM_DIR -u VM_CONTROL_DIR -u VM_RUN_DIR
    -u VM_LOG_DIR -u VM_ASSET_DIR -u VM_STORAGE_COMPAT_FALLBACK
)
"${unset_args[@]}" "$DEPLOY/scripts/start-vm.sh" 71 \
    --vms-dir "$CUSTOM_ROOT" --print-paths >"$TMP_DIR/canonical.out"
grep -Fxq "VM_ROOT=$CUSTOM_ROOT" "$TMP_DIR/canonical.out" ||
    fail "canonical start-vm did not resolve the selected root"
grep -Fxq "VM_DIR=$CUSTOM_ROOT/71" "$TMP_DIR/canonical.out" ||
    fail "canonical start-vm did not resolve the numeric bundle"
[[ ! -e "$CUSTOM_ROOT" ]] ||
    fail "read-only entrypoint verification created the custom VM root"

grep -Fq 'start_vm="$here/scripts/start-vm.sh"' "$DEPLOY/scripts/vmctl.sh" ||
    fail "vmctl does not use canonical start-vm"
grep -Fq 'create_disk="$here/scripts/create-disk.sh"' "$DEPLOY/scripts/vmctl.sh" ||
    fail "vmctl does not use canonical disk entry"
grep -Fq 'clone_vm="$here/scripts/clone-from-base.sh"' "$DEPLOY/scripts/vmctl.sh" ||
    fail "vmctl does not use canonical clone-from-base entry"
grep -Fq 'seal_base="$here/scripts/seal-base.sh"' "$DEPLOY/scripts/vmctl.sh" ||
    fail "vmctl does not use canonical seal-base entry"
grep -Fq 'migrate_layout="$here/scripts/migrate-g11-layout.sh"' \
    "$DEPLOY/scripts/vmctl.sh" || fail "vmctl does not use canonical migration entry"

echo "PASS: deploy/scripts contains the only lifecycle entrypoints"
