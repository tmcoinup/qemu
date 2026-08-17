#!/usr/bin/env bash
# Rootless regression for the one-command hibernated/Fast Startup recovery
# wrapper.  The launcher and monitor synchronizer are replaced by trace shims;
# this test never opens QEMU, mounts a disk, or touches a real VM bundle.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
RECOVER="$REPO_ROOT/deploy/scripts/recover-hibernated-vm.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

require_text() {
    local needle=$1 file=$2
    grep -F -- "$needle" "$file" >/dev/null || \
        fail "missing '$needle' in $(basename "$file")"
}

reject_text() {
    local needle=$1 file=$2
    if grep -F -- "$needle" "$file" >/dev/null; then
        fail "unexpected '$needle' in $(basename "$file")"
    fi
}

[[ -f "$RECOVER" ]] || fail "hibernation recovery wrapper is missing"
bash -n "$RECOVER"
[[ -x "$RECOVER" ]] || fail "hibernation recovery wrapper is not executable"
require_text 'if (( EUID == 0 )); then' "$RECOVER"
require_text '不要用 sudo/root 运行整个恢复封装' "$RECOVER"

# Host-side recovery must not repair NTFS, throw away the saved session, alter
# BCD/signing policy, or route through the retired self-signed strict-A finish.
for forbidden in \
        remove_hiberfile ntfsfix 'bcdedit ' testsigning nointegritychecks \
        finish-vgpu-install.sh; do
    reject_text "$forbidden" "$RECOVER"
done

TMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TMP_DIR"' EXIT
HARNESS="$TMP_DIR/tree"
mkdir -p "$HARNESS/deploy/scripts" "$TMP_DIR/fake-bin"
cp -- "$RECOVER" "$HARNESS/deploy/scripts/recover-hibernated-vm.sh"
chmod +x "$HARNESS/deploy/scripts/recover-hibernated-vm.sh"

TRACE="$TMP_DIR/calls.trace"
: >"$TRACE"

cat >"$HARNESS/deploy/scripts/start-vm.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'start-begin\n' >>"$RECOVERY_TEST_TRACE"
for arg in "$@"; do
    printf 'start-arg=[%s]\n' "$arg" >>"$RECOVERY_TEST_TRACE"
done
printf 'start-end rc=%s\n' "${RECOVERY_TEST_RESCUE_RC:-0}" \
    >>"$RECOVERY_TEST_TRACE"
exit "${RECOVERY_TEST_RESCUE_RC:-0}"
EOF

cat >"$HARNESS/deploy/scripts/sync-monitor-profile.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'sync-begin\n' >>"$RECOVERY_TEST_TRACE"
printf 'sync-env-vm-instance-dir=[%s]\n' "${VM_INSTANCE_DIR:-}" \
    >>"$RECOVERY_TEST_TRACE"
printf 'sync-env-vm-instance-id=[%s]\n' "${VM_INSTANCE_ID:-}" \
    >>"$RECOVERY_TEST_TRACE"
printf 'sync-env-start-lock-held=[%s]\n' "${VM_START_LOCK_HELD:-}" \
    >>"$RECOVERY_TEST_TRACE"
for arg in "$@"; do
    printf 'sync-arg=[%s]\n' "$arg" >>"$RECOVERY_TEST_TRACE"
done
printf 'sync-end rc=%s\n' "${RECOVERY_TEST_SYNC_RC:-0}" \
    >>"$RECOVERY_TEST_TRACE"
exit "${RECOVERY_TEST_SYNC_RC:-0}"
EOF
chmod +x "$HARNESS/deploy/scripts/start-vm.sh" \
    "$HARNESS/deploy/scripts/sync-monitor-profile.sh"

# If the wrapper validates a cached sudo ticket before opening the local
# window, keep that preflight inside the harness as well.  It must never reach
# the host's real sudo implementation during this regression.
cat >"$TMP_DIR/fake-bin/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'sudo' >>"$RECOVERY_TEST_TRACE"
for arg in "$@"; do
    printf ' [%s]' "$arg" >>"$RECOVERY_TEST_TRACE"
done
printf '\n' >>"$RECOVERY_TEST_TRACE"
exit 0
EOF
chmod +x "$TMP_DIR/fake-bin/sudo"

run_recovery() {
    local name=$1 rescue_rc=$2 sync_rc=$3
    shift 3
    : >"$TRACE"
    set +e
    PATH="$TMP_DIR/fake-bin:/usr/bin:/bin" \
        DISPLAY=:99 \
        RECOVERY_TEST_TRACE="$TRACE" \
        RECOVERY_TEST_RESCUE_RC="$rescue_rc" \
        RECOVERY_TEST_SYNC_RC="$sync_rc" \
        "$HARNESS/deploy/scripts/recover-hibernated-vm.sh" "$@" \
        >"$TMP_DIR/$name.out" 2>"$TMP_DIR/$name.err"
    RUN_RC=$?
    set -e
}

assert_common_rescue_contract() {
    require_text 'start-arg=[7]' "$TRACE"
    require_text 'start-arg=[--no-monitor-sync]' "$TRACE"
    require_text 'start-arg=[--no-spoof]' "$TRACE"
    require_text 'start-arg=[--no-stream]' "$TRACE"
    require_text 'start-arg=[--no-shmem]' "$TRACE"
    require_text 'start-arg=[--extra]' "$TRACE"
    require_text 'start-arg=[]' "$TRACE"
    reject_text 'start-arg=[--rdp]' "$TRACE"
    reject_text 'start-arg=[--no-gpu]' "$TRACE"
    reject_text 'start-arg=[--vnc]' "$TRACE"
    reject_text 'start-arg=[--proxy]' "$TRACE"
    [[ $(grep -Fc 'start-begin' "$TRACE") -eq 1 ]] || \
        fail "recovery did not launch exactly one local rescue"
}

# Default recovery is local SDL.  --proxy is a preference for the printed
# normal-start command only and must never turn the rescue into a proxy/VNC/RDP
# session.  A clean QEMU exit is followed by exactly one forced offline sync.
run_recovery success 0 0 7 --proxy
[[ $RUN_RC -eq 0 ]] || fail "successful recovery returned $RUN_RC"
assert_common_rescue_contract
require_text 'start-arg=[--rescue-sdl]' "$TRACE"
reject_text 'start-arg=[--rescue-gtk]' "$TRACE"
require_text 'sync-begin' "$TRACE"
require_text 'sync-arg=[7]' "$TRACE"
require_text 'sync-arg=[--force]' "$TRACE"
require_text 'sync-env-start-lock-held=[0]' "$TRACE"
[[ $(grep -Fc 'sync-begin' "$TRACE") -eq 1 ]] || \
    fail "successful recovery did not sync exactly once"
start_end_line=$(grep -nF 'start-end rc=0' "$TRACE" | cut -d: -f1)
sync_begin_line=$(grep -nF 'sync-begin' "$TRACE" | cut -d: -f1)
[[ -n "$start_end_line" && -n "$sync_begin_line" && \
   $start_end_line -lt $sync_begin_line ]] || \
    fail "offline sync ran before the rescue QEMU exited"
require_text 'HiberbootEnabled' "$TMP_DIR/success.out"
require_text 'shutdown.exe /s /f /t 0' "$TMP_DIR/success.out"
require_text './deploy/scripts/start-vm.sh 7 --proxy' "$TMP_DIR/success.out"

# A failed/aborted rescue is not proof of a full shutdown.  Preserve the disk,
# skip all offline writes, and do not advertise a normal vGPU start.
run_recovery rescue-failed 23 0 7 --proxy
[[ $RUN_RC -eq 23 ]] || \
    fail "rescue failure rc 23 became $RUN_RC"
assert_common_rescue_contract
require_text 'start-arg=[--rescue-sdl]' "$TRACE"
reject_text 'sync-begin' "$TRACE"
reject_text './deploy/scripts/start-vm.sh 7 --proxy' \
    "$TMP_DIR/rescue-failed.out"

# Even after QEMU exits, the synchronizer is the authority on NTFS state.  A
# repeated rc 11 must remain fail-closed and must not print the normal command.
run_recovery still-hibernated 0 11 7 --proxy
[[ $RUN_RC -eq 11 ]] || \
    fail "deferred sync rc 11 became $RUN_RC"
assert_common_rescue_contract
require_text 'start-arg=[--rescue-sdl]' "$TRACE"
require_text 'sync-begin' "$TRACE"
require_text 'sync-arg=[--force]' "$TRACE"
reject_text './deploy/scripts/start-vm.sh 7 --proxy' \
    "$TMP_DIR/still-hibernated.out"

# GTK is an explicit local-window alternative; it retains the same no-sync,
# no-spoof rescue contract.  Without --proxy the printed normal command must
# not silently enable it.
run_recovery gtk 0 0 7 --rescue-gtk
[[ $RUN_RC -eq 0 ]] || fail "GTK recovery returned $RUN_RC"
assert_common_rescue_contract
require_text 'start-arg=[--rescue-gtk]' "$TRACE"
reject_text 'start-arg=[--rescue-sdl]' "$TRACE"
require_text './deploy/scripts/start-vm.sh 7' "$TMP_DIR/gtk.out"
reject_text './deploy/scripts/start-vm.sh 7 --proxy' "$TMP_DIR/gtk.out"

# An explicit storage selector must follow both halves of the operation: the
# rescue launcher receives the original CLI pair, while the offline sync is
# bound to the same exact bundle through the exported storage contract.
custom_vm_dir="$TMP_DIR/custom-instances/7"
run_recovery custom-storage 0 0 7 --vm-dir "$custom_vm_dir" --proxy
[[ $RUN_RC -eq 0 ]] || fail "custom-storage recovery returned $RUN_RC"
assert_common_rescue_contract
require_text 'start-arg=[--vm-dir]' "$TRACE"
require_text "start-arg=[$custom_vm_dir]" "$TRACE"
require_text "sync-env-vm-instance-dir=[$custom_vm_dir]" "$TRACE"
require_text 'sync-env-vm-instance-id=[7]' "$TRACE"
require_text "--vm-dir $custom_vm_dir --proxy" "$TMP_DIR/custom-storage.out"

# Reject an unresolved relative storage target before opening any VM window or
# invoking sudo/offline synchronization.
run_recovery relative-storage 0 0 7 --vm-dir relative/7
[[ $RUN_RC -eq 2 ]] || fail "relative storage path became rc $RUN_RC"
reject_text 'start-begin' "$TRACE"
reject_text 'sync-begin' "$TRACE"

echo "PASS: hibernation recovery uses local standard VGA and fails closed"
