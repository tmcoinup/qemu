#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
VMCTL="$REPO_ROOT/deploy/scripts/vmctl.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

unset_storage_env=(
    env -u VM_ROOT -u VMS_DIR -u VM_INSTANCES_DIR -u VM_INSTANCE_DIR
    -u VM_INSTANCE_ID -u VM_SHARED_DIR -u VM_CONFIG_DIR -u VM_DISK_DIR
    -u VM_BASE_DIR -u VM_NVRAM_DIR -u VM_CONTROL_DIR -u VM_RUN_DIR
    -u VM_LOG_DIR -u VM_ASSET_DIR -u VM_STORAGE_COMPAT_FALLBACK
)

# The real read-only command must resolve a numeric bundle below the complete
# custom root without creating any storage directory.
CUSTOM_ROOT="$TMP_DIR/custom vms"
"${unset_storage_env[@]}" "$VMCTL" path 17 --vms-dir "$CUSTOM_ROOT" \
    >"$TMP_DIR/path.out"
grep -Fxq "VM_ROOT=$CUSTOM_ROOT" "$TMP_DIR/path.out" \
    || fail "vmctl path did not select the custom VMS root"
grep -Fxq "VM_DIR=$CUSTOM_ROOT/17" "$TMP_DIR/path.out" \
    || fail "vmctl path did not use a numeric bundle"
grep -Fxq "VM_START_LOCK=$CUSTOM_ROOT/17/run/start.lock" "$TMP_DIR/path.out" \
    || fail "vmctl path did not keep the lifecycle lock in the bundle"
[[ ! -e "$CUSTOM_ROOT" ]] \
    || fail "vmctl path created the custom root during read-only inspection"

# The two historical source trees are migration inputs, never valid targets.
# Keep IMAGE_ROOT unset here to cover wrapper selection before storage init.
if "${unset_storage_env[@]}" "$VMCTL" path 17 \
        --vms-dir /home/ubuntu/images/vms/G-11 \
        >"$TMP_DIR/historical.out" 2>&1; then
    fail "vmctl accepted the historical G-11 source as a new VMS root"
fi
grep -Fq "old G-11 source cannot be selected" "$TMP_DIR/historical.out" \
    || fail "historical-root rejection did not report the migration boundary"

# Scripts without their own storage CLI are wrapped by exporting the validated
# root at runtime.  Use harmless stand-ins to test dispatch without creating a
# disk, VM identity, or host state.
FIXTURE="$TMP_DIR/fixture"
mkdir -p "$FIXTURE/deploy/lib" "$FIXTURE/deploy/scripts"
cp -- "$VMCTL" "$FIXTURE/deploy/scripts/vmctl.sh"
cp -- "$REPO_ROOT/deploy/lib/vm-storage.sh" \
    "$FIXTURE/deploy/lib/vm-storage.sh"

for name in start-vm.sh stop-vm.sh; do
    cat >"$FIXTURE/deploy/scripts/$name" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
    printf '%s|%s\n' "$(basename "$0")" "$*" >"$VMCTL_RESULT"
EOF
    chmod +x "$FIXTURE/deploy/scripts/$name"
done

# vmctl itself must route every user-facing lifecycle action through
# the single deploy/scripts lifecycle.
for invocation in \
        'start|start-vm.sh|23 --example-start' \
        '23|start-vm.sh|23 --numeric-shortcut' \
        'stop|stop-vm.sh|23 --force' \
        'path|start-vm.sh|23 --print-paths'; do
    IFS='|' read -r action expected_script expected_args <<<"$invocation"
    result="$TMP_DIR/vmctl-${action}.result"
    case "$action" in
        23)
            VMCTL_RESULT="$result" "$FIXTURE/deploy/scripts/vmctl.sh" \
                23 --numeric-shortcut
            ;;
        start)
            VMCTL_RESULT="$result" "$FIXTURE/deploy/scripts/vmctl.sh" \
                start 23 --example-start
            ;;
        stop)
            VMCTL_RESULT="$result" "$FIXTURE/deploy/scripts/vmctl.sh" \
                stop 23 --force
            ;;
        path)
            VMCTL_RESULT="$result" "$FIXTURE/deploy/scripts/vmctl.sh" path 23
            ;;
    esac
    [[ "$(<"$result")" == "$expected_script|$expected_args" ]] ||
        fail "vmctl $action bypassed the canonical deploy/scripts entry"
done

for name in create-vm.sh create-disk.sh clone-from-base.sh seal-base.sh \
        promote-base.sh sync-monitor-profile.sh; do
    cat >"$FIXTURE/deploy/scripts/$name" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${VM_ROOT:-}|${VMS_DIR:-}|$*" >"$VMCTL_RESULT"
EOF
    chmod +x "$FIXTURE/deploy/scripts/$name"
done

WRAPPED_ROOT="$TMP_DIR/wrapped vms"
for action in create disk clone seal promote monitor; do
    result="$TMP_DIR/$action.result"
    action_args=(23)
    expected_args='23 --example-option value'
    case "$action" in
        clone)
            action_args=(win10-ltsc-v2 23)
            expected_args='win10-ltsc-v2 23 --example-option value'
            ;;
        seal)
            action_args=(23 win10-ltsc-v2)
            expected_args='23 win10-ltsc-v2 --example-option value'
            ;;
    esac
    VMCTL_RESULT="$result" "${unset_storage_env[@]}" \
        "$FIXTURE/deploy/scripts/vmctl.sh" "$action" "${action_args[@]}" \
        --vms-dir "$WRAPPED_ROOT" --example-option value
    [[ "$(<"$result")" == \
       "$WRAPPED_ROOT|$WRAPPED_ROOT|$expected_args" ]] \
        || fail "vmctl $action did not export/forward the selected root correctly"
done
monitor_result="$TMP_DIR/monitor-profile.result"
VMCTL_RESULT="$monitor_result" "${unset_storage_env[@]}" \
    "$FIXTURE/deploy/scripts/vmctl.sh" monitor 23 \
    --vms-dir "$WRAPPED_ROOT" --monitor-profile benq-gw2280 --force
[[ "$(<"$monitor_result")" == \
   "$WRAPPED_ROOT|$WRAPPED_ROOT|23 --monitor-profile benq-gw2280 --force" ]] \
    || fail "vmctl monitor did not preserve the selected profile and force flag"
[[ ! -e "$WRAPPED_ROOT" ]] \
    || fail "fixture dispatch unexpectedly created the selected root"

if VMCTL_RESULT="$TMP_DIR/rejected.result" "${unset_storage_env[@]}" \
        "$FIXTURE/deploy/scripts/vmctl.sh" create 23 --vms-dir relative/path \
        >"$TMP_DIR/rejected.out" 2>&1; then
    fail "vmctl accepted a relative VMS root"
fi
[[ ! -e "$TMP_DIR/rejected.result" ]] \
    || fail "invalid custom root reached the lifecycle script"

echo "PASS: vmctl resolves numeric bundles and wraps custom VMS roots"
