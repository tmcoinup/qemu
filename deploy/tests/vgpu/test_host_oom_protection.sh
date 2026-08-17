#!/usr/bin/env bash
# Validate the fixed, per-launcher OOM policy with proc fixtures and a fake
# integration helper. No real /proc entry, sudoers file, or VM is modified.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
HELPER="$REPO_ROOT/deploy/host/cpu-isolate.sh"
START_VM="$REPO_ROOT/deploy/scripts/start-vm.sh"
TMP_DIR="$(mktemp -d)"
PROC_ROOT="$TMP_DIR/proc"
CG_ROOT="$TMP_DIR/cgroup"
SYS_CPU_ROOT="$TMP_DIR/sys-cpu"
PID=7100
VM_ID=77
STARTTIME=123456

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

cleanup() {
    rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$PROC_ROOT/$PID" "$CG_ROOT" "$SYS_CPU_ROOT"
{
    printf '%s (bash launcher) S' "$PID"
    for _ in $(seq 1 18); do printf ' 0'; done
    printf ' %s\n' "$STARTTIME"
} >"$PROC_ROOT/$PID/stat"
printf 'Name:\tbash\nUid:\t1000\t1000\t1000\t1000\n' \
    >"$PROC_ROOT/$PID/status"
printf 'bash\0%s\0%s\0' "$REPO_ROOT/deploy/scripts/start-vm.sh" "$VM_ID" \
    >"$PROC_ROOT/$PID/cmdline"
printf '0\n' >"$PROC_ROOT/$PID/oom_score_adj"

run_helper() {
    CPU_ISO_TEST_MODE=1 \
    CPU_ISO_CGROUP_ROOT="$CG_ROOT" \
    CPU_ISO_PROC_ROOT="$PROC_ROOT" \
    CPU_ISO_SYS_CPU_ROOT="$SYS_CPU_ROOT" \
    CPU_ISO_LOCK_FILE="$TMP_DIR/cpu.lock" \
    CPU_ISO_TASKSET_BIN=true \
        "$HELPER" "$@"
}

run_helper oom-protect "$VM_ID" "$PID" "$STARTTIME" >"$TMP_DIR/protect.out"
grep -Fxq "host-oom-protect: policy=oom-score-v1 score=-500 pid=$PID" \
    "$TMP_DIR/protect.out" || fail "helper did not return the fixed OOM protocol"
[[ "$(cat "$PROC_ROOT/$PID/oom_score_adj")" == -500 ]] \
    || fail "helper did not apply oom_score_adj=-500"

# A stronger trusted parent policy must never be weakened.
printf '%s\n' -750 >"$PROC_ROOT/$PID/oom_score_adj"
run_helper oom-protect "$VM_ID" "$PID" "$STARTTIME" >"$TMP_DIR/strong.out"
grep -Fq 'score=-750' "$TMP_DIR/strong.out" \
    || fail "helper weakened an inherited OOM policy"

if run_helper oom-protect "$VM_ID" "$PID" 999999 \
        >"$TMP_DIR/wrong-generation.out" 2>&1; then
    fail "helper accepted a replaced launcher generation"
fi
grep -Fq '已换代' "$TMP_DIR/wrong-generation.out" \
    || fail "generation rejection was not explained"

if run_helper oom-protect 78 "$PID" "$STARTTIME" \
        >"$TMP_DIR/wrong-vm.out" 2>&1; then
    fail "helper accepted a launcher belonging to another VM"
fi

# Exercise launcher-side generation parsing and strict response validation
# against an unprivileged fake helper.
cat >"$TMP_DIR/fake-helper" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$OOM_HELPER_LOG"
[[ "$1" == oom-protect && "$2" =~ ^[1-9][0-9]*$ &&
   "$3" =~ ^[1-9][0-9]*$ && "$4" =~ ^[1-9][0-9]*$ ]] || exit 2
printf 'host-oom-protect: policy=oom-score-v1 score=-500 pid=%s\n' "$3"
EOF
chmod +x "$TMP_DIR/fake-helper"

here="$REPO_ROOT/deploy"
# shellcheck source=../../lib/cpu-isolation.sh
source "$REPO_ROOT/deploy/lib/cpu-isolation.sh"
CPU_ISOLATION_HELPER="$TMP_DIR/fake-helper"
CPU_ISOLATION_AUTO_INSTALL=0
HOST_OOM_PROTECT=1
DRY_RUN=0
OOM_HELPER_LOG="$TMP_DIR/oom-helper.log"
export CPU_ISOLATION_HELPER OOM_HELPER_LOG
host_oom_protect_launcher "$VM_ID" >"$TMP_DIR/library.out" \
    || fail "launcher-side OOM integration failed"
grep -Fq "vm${VM_ID} 进程树 oom_score_adj=-500" "$TMP_DIR/library.out" \
    || fail "launcher did not report the applied transient policy"
grep -Eq "^oom-protect ${VM_ID} [1-9][0-9]* [1-9][0-9]*$" \
    "$OOM_HELPER_LOG" || fail "launcher did not bind helper call to PID generation"

: >"$OOM_HELPER_LOG"
HOST_OOM_PROTECT=0
host_oom_protect_launcher "$VM_ID" >/dev/null \
    || fail "explicit OOM opt-out was rejected"
[[ ! -s "$OOM_HELPER_LOG" ]] || fail "OOM opt-out still called the helper"

grep -Fq 'host_oom_protect_launcher "$VM_ID"' "$START_VM" \
    || fail "start-vm does not protect the instance process tree"
grep -Fq 'HOST_OOM_PROTECT="${HOST_OOM_PROTECT:-1}"' "$START_VM" \
    || fail "start-vm does not default OOM protection on"

echo "PASS: transient per-instance host OOM protection"
