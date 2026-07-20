#!/usr/bin/env bash
# Exercise CPU isolation against a regular-file cgroup/proc/sysfs mock.  No
# real affinity, cgroup, VM, sudoers, or host state is changed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
HELPER="$REPO_ROOT/deploy/host/cpu-isolate.sh"
INSTALLER="$REPO_ROOT/deploy/host/install-cpu-isolation.sh"
START_VM="$REPO_ROOT/deploy/start-vm.sh"
STOP_VM="$REPO_ROOT/deploy/stop-vm.sh"
TMP_DIR="$(mktemp -d)"
CG_ROOT="$TMP_DIR/cgroup"
PROC_ROOT="$TMP_DIR/proc"
SYS_CPU_ROOT="$TMP_DIR/sys-cpu"
TASKSET_MOCK="$TMP_DIR/taskset"
TASKSET_LOG="$TMP_DIR/taskset.log"
VM_ID=41
QEMU_PID=4000

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

cleanup() {
    rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT

write_status() {
    local path=$1 tid=$2
    mkdir -p "$path"
    printf 'Name:\tqemu\nTgid:\t%s\nCpus_allowed_list:\t0-7\n' \
        "$QEMU_PID" >"$path/status"
}

reset_mock() {
    rm -rf -- "$CG_ROOT" "$PROC_ROOT" "$SYS_CPU_ROOT"
    mkdir -p "$CG_ROOT/user.slice" "$PROC_ROOT/$QEMU_PID/task" "$SYS_CPU_ROOT"
    printf 'cpuset cpu io\n' >"$CG_ROOT/cgroup.controllers"
    : >"$CG_ROOT/cgroup.subtree_control"
    printf '0-7\n' >"$CG_ROOT/cpuset.cpus.effective"
    printf '0-1\n' >"$CG_ROOT/cpuset.mems.effective"
    # The real cgroup v2 root is implicitly a partition root and does not
    # expose cpuset.cpus.partition.  Only non-root child cgroups have it.
    : >"$CG_ROOT/user.slice/cgroup.procs"
    printf '0::/user.slice\n' >"$PROC_ROOT/$QEMU_PID/cgroup"
    printf '%s\0%s\0' -name "vm${VM_ID}" >"$PROC_ROOT/$QEMU_PID/cmdline"
    mkdir -p "$TMP_DIR/bin"
    : >"$TMP_DIR/bin/qemu-system-x86_64"
    ln -s "$TMP_DIR/bin/qemu-system-x86_64" "$PROC_ROOT/$QEMU_PID/exe"
    write_status "$PROC_ROOT/$QEMU_PID/task/$QEMU_PID" "$QEMU_PID"
    write_status "$PROC_ROOT/$QEMU_PID/task/4001" 4001
    write_status "$PROC_ROOT/$QEMU_PID/task/4002" 4002
    write_status "$PROC_ROOT/$QEMU_PID/task/4003" 4003
    mkdir -p "$SYS_CPU_ROOT/cpu2/node0" "$SYS_CPU_ROOT/cpu3/node1" \
        "$SYS_CPU_ROOT/cpu4/node1"
    : >"$TASKSET_LOG"
}

run_helper() {
    CPU_ISO_TEST_MODE=1 \
    CPU_ISO_CGROUP_ROOT="$CG_ROOT" \
    CPU_ISO_PROC_ROOT="$PROC_ROOT" \
    CPU_ISO_SYS_CPU_ROOT="$SYS_CPU_ROOT" \
    CPU_ISO_LOCK_FILE="$TMP_DIR/cpu.lock" \
    CPU_ISO_TASKSET_BIN="$TASKSET_MOCK" \
        "$HELPER" "$@"
}

cat >"$TASKSET_MOCK" <<'EOF'
#!/usr/bin/env bash
printf '%s %s %s\n' "$1" "$2" "$3" >>"$TASKSET_LOG"
[[ "${TASKSET_FAIL_CPU:-}" != "$2" ]]
EOF
chmod +x "$TASKSET_MOCK"
export TASKSET_LOG

[[ -x "$HELPER" ]] || fail "CPU helper is not executable"
[[ -x "$INSTALLER" ]] || fail "CPU installer is not executable"

reset_mock
run_helper apply "$VM_ID" "$QEMU_PID" 2,3,4,5,6,7 4001,4002 1 \
    >"$TMP_DIR/apply.out"
grep -Fq "vm${VM_ID} applied: vcpu=2,3 service=4 mems=0,1" \
    "$TMP_DIR/apply.out" || fail "apply result did not report CPU roles and derived NUMA nodes"
[[ "$(cat "$CG_ROOT/qemu-vm-isolation/cpuset.cpus.partition")" == root ]] \
    || fail "product cgroup is not a partition root"
[[ "$(cat "$CG_ROOT/qemu-vm-isolation/vm${VM_ID}/cpuset.cpus")" == 2,3,4 ]] \
    || fail "per-VM cpuset is wrong"
[[ "$(cat "$CG_ROOT/qemu-vm-isolation/vm${VM_ID}/cpuset.mems")" == 0,1 ]] \
    || fail "cpuset.mems was not derived from selected CPUs"
grep -Fxq -- '-pc 2 4001' "$TASKSET_LOG" || fail "vCPU 0 was not pinned"
grep -Fxq -- '-pc 3 4002' "$TASKSET_LOG" || fail "vCPU 1 was not pinned"
grep -Fxq -- '-pc 4 4000' "$TASKSET_LOG" || fail "QEMU main thread was not on service CPU"
grep -Fxq -- '-pc 4 4003' "$TASKSET_LOG" || fail "QEMU worker was not on service CPU"

# cgroup pseudo-files report size zero on real cgroupfs.  The helper must
# inspect content, not stat size: a non-empty cgroup.procs must block release.
if run_helper release "$VM_ID" >"$TMP_DIR/live-release.out" 2>&1; then
    fail "release removed an active VM cgroup"
fi
grep -Fq '仍有活动进程' "$TMP_DIR/live-release.out" \
    || fail "active release did not explain the refusal"

: >"$CG_ROOT/qemu-vm-isolation/vm${VM_ID}/cgroup.procs"
run_helper release "$VM_ID" >"$TMP_DIR/release.out"
[[ ! -e "$CG_ROOT/qemu-vm-isolation" ]] \
    || fail "last release did not return the partition to the host"

# A taskset failure after partial mutation must move the process back and
# remove only this product cgroup.
reset_mock
export TASKSET_FAIL_CPU=3
if run_helper apply "$VM_ID" "$QEMU_PID" 2,3,4,5,6,7 4001,4002 1 \
        >"$TMP_DIR/rollback.out" 2>&1; then
    fail "taskset failure was accepted"
fi
unset TASKSET_FAIL_CPU
grep -Fxq "$QEMU_PID" "$CG_ROOT/user.slice/cgroup.procs" \
    || fail "failed apply did not move QEMU back to its original cgroup"
[[ ! -e "$CG_ROOT/qemu-vm-isolation" ]] \
    || fail "failed apply left an exclusive product partition behind"
grep -Fq '回滚本次 CPU 隔离' "$TMP_DIR/rollback.out" \
    || fail "rollback was not reported"

# Invalid process identity must be rejected before any cgroup is created.
reset_mock
printf '%s\0%s\0' -name vm999 >"$PROC_ROOT/$QEMU_PID/cmdline"
if run_helper apply "$VM_ID" "$QEMU_PID" 2,3,4 4001,4002 1 \
        >"$TMP_DIR/bad-name.out" 2>&1; then
    fail "mismatched QEMU -name was accepted"
fi
[[ ! -e "$CG_ROOT/qemu-vm-isolation" ]] \
    || fail "identity rejection mutated cgroups"

"$INSTALLER" --print >"$TMP_DIR/install.out"
grep -Fq 'helper=/usr/local/libexec/qemu-cpu-isolate' "$TMP_DIR/install.out" \
    || fail "installer does not use a root-owned helper path"
grep -Fq 'NOPASSWD: /usr/local/libexec/qemu-cpu-isolate apply *' \
    "$TMP_DIR/install.out" || fail "installer sudoers rule does not scope apply"
grep -Fq '/usr/local/libexec/qemu-cpu-isolate release *' \
    "$TMP_DIR/install.out" || fail "installer sudoers rule does not scope release"

# Exercise the launcher-side QMP handshake.  required mode must query the
# vCPU native TID, call the helper, and only then issue QMP cont.
cat >"$TMP_DIR/fake-qmp.py" <<'PY'
#!/usr/bin/env python3
import json
import os
import socket
import sys

path = sys.argv[-2]
record = sys.argv[-1]
try:
    os.unlink(path)
except FileNotFoundError:
    pass
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(path)
server.listen(2)
for connection_index in range(2):
    conn, _ = server.accept()
    stream = conn.makefile("rwb", buffering=0)
    stream.write(b'{"QMP":{"version":{"qemu":{"major":11,"minor":0,"micro":2},"package":""},"capabilities":[]}}\r\n')
    while True:
        line = stream.readline()
        if not line:
            break
        request = json.loads(line)
        command = request["execute"]
        ident = request["id"]
        if command == "query-cpus-fast":
            result = [{"cpu-index": 0, "thread-id": os.getpid()}]
        else:
            result = {}
        stream.write((json.dumps({"return": result, "id": ident}) + "\r\n").encode())
        if command == "cont":
            with open(record, "w", encoding="utf-8") as output:
                output.write("cont\n")
            break
    conn.close()
server.close()
PY
cat >"$TMP_DIR/fake-helper" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_HELPER_LOG"
exit 0
EOF
chmod +x "$TMP_DIR/fake-qmp.py" "$TMP_DIR/fake-helper"
: >"$TMP_DIR/fake-helper.log"
"$TMP_DIR/fake-qmp.py" -name vm42 "$TMP_DIR/qmp.sock" "$TMP_DIR/qmp.record" &
FAKE_QMP_PID=$!
for _ in $(seq 1 100); do
    [[ -S "$TMP_DIR/qmp.sock" ]] && break
    kill -0 "$FAKE_QMP_PID" 2>/dev/null || fail "fake QMP exited early"
    sleep 0.01
done

here="$REPO_ROOT/deploy"
# shellcheck source=../../lib/cpu-isolation.sh
source "$REPO_ROOT/deploy/lib/cpu-isolation.sh"

# No-flag startup is fail-closed: legacy boolean "enabled" has the same
# required semantics, while auto/off remain explicit opt-down modes.
unset CPU_ISOLATION CPU_ISOLATE
cpu_isolation_normalize_mode || fail "default CPU isolation mode was rejected"
[[ "$CPU_ISOLATION" == required ]] \
    || fail "default CPU isolation mode is not required"
CPU_ISOLATION=""
CPU_ISOLATE=1
cpu_isolation_normalize_mode || fail "legacy CPU_ISOLATE=1 was rejected"
[[ "$CPU_ISOLATION" == required ]] \
    || fail "legacy CPU_ISOLATE=1 is not fail-closed"
unset CPU_ISOLATE
CPU_ISOLATION=auto
cpu_isolation_normalize_mode || fail "explicit auto mode was rejected"
[[ "$CPU_ISOLATION" == auto ]] || fail "explicit auto mode was not preserved"
CPU_ISOLATION=off
cpu_isolation_normalize_mode || fail "explicit off mode was rejected"
[[ "$CPU_ISOLATION" == off ]] || fail "explicit off mode was not preserved"

# Missing system helper/dependencies are installed before a required launch.
# The sudo mock rejects the first noninteractive installer attempt, accepts
# only password 123456 on stdin, and then validates the installed NOPASSWD path.
AUTO_DIR="$TMP_DIR/auto-install"
mkdir -p "$AUTO_DIR/bin"
AUTO_SOURCE_HELPER="$REPO_ROOT/deploy/host/cpu-isolate.sh"
AUTO_SYSTEM_HELPER="$AUTO_DIR/qemu-cpu-isolate"
AUTO_INSTALL_LOG="$AUTO_DIR/install.log"
cat >"$AUTO_DIR/fake-installer" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
install -m 0755 "$AUTO_SOURCE_HELPER" "$AUTO_SYSTEM_HELPER"
printf 'installed\n' >>"$AUTO_INSTALL_LOG"
EOF
cat >"$AUTO_DIR/bin/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mode=$1
shift
case "$mode" in
    -n)
        [[ "${1:-}" == -- ]] && shift
        [[ "${1:-}" == "$AUTO_SYSTEM_HELPER" ]] || exit 1
        exec "$@"
        ;;
    -S)
        [[ "${1:-}" == -p ]] || exit 2
        shift 2
        [[ "${1:-}" == -- ]] && shift
        IFS= read -r password
        [[ "$password" == 123456 ]] || exit 1
        exec "$@"
        ;;
    *)
        exit 2
        ;;
esac
EOF
chmod +x "$AUTO_DIR/fake-installer" "$AUTO_DIR/bin/sudo"
ORIGINAL_PATH=$PATH
ORIGINAL_SYSTEM_HELPER=$CPU_ISOLATION_SYSTEM_HELPER
ORIGINAL_INSTALLER=$CPU_ISOLATION_INSTALLER
PATH="$AUTO_DIR/bin:$PATH"
CPU_ISOLATION_SYSTEM_HELPER="$AUTO_SYSTEM_HELPER"
CPU_ISOLATION_INSTALLER="$AUTO_DIR/fake-installer"
CPU_ISOLATION_AUTO_INSTALL=1
CPU_ISOLATION=required
DRY_RUN=0
SUDO_PASSWORD=123456
export AUTO_SOURCE_HELPER AUTO_SYSTEM_HELPER AUTO_INSTALL_LOG
cpu_isolation_ensure_ready || fail "missing CPU helper was not auto-installed"
[[ -x "$AUTO_SYSTEM_HELPER" ]] || fail "auto-install did not create the helper"
[[ "$(cat "$AUTO_INSTALL_LOG")" == installed ]] \
    || fail "auto-installer did not run exactly once"
cpu_isolation_ensure_ready || fail "installed CPU helper was not reusable"
[[ "$(wc -l <"$AUTO_INSTALL_LOG")" == 1 ]] \
    || fail "ready CPU helper was unnecessarily reinstalled"
PATH=$ORIGINAL_PATH
CPU_ISOLATION_SYSTEM_HELPER=$ORIGINAL_SYSTEM_HELPER
CPU_ISOLATION_INSTALLER=$ORIGINAL_INSTALLER

CPU_ISOLATION=required
CPU_ISOLATION_HELPER="$TMP_DIR/fake-helper"
CPU_ISOLATION_QMP_TIMEOUT=3
QEMU_SERVICE_CPUS=0
HOST_RESERVE_CORES=auto
DRY_RUN=0
FAKE_HELPER_LOG="$TMP_DIR/fake-helper.log"
export CPU_ISOLATION_HELPER FAKE_HELPER_LOG
cpu_isolation_launch 42 1 "$TMP_DIR/qmp.sock" "$TMP_DIR/qemu.pid" \
    "$TMP_DIR/cpu.state"
wait "$CPU_ISOLATION_PINNER_PID" || fail "QMP pinner failed"
CPU_ISOLATION_PINNER_PID=""
wait "$FAKE_QMP_PID" || fail "fake QMP failed"
grep -Fxq cont "$TMP_DIR/qmp.record" \
    || fail "required mode did not resume QEMU after helper success"
grep -Eq '^apply 42 [0-9]+ [0-9,]+ [0-9]+ 0$' "$TMP_DIR/fake-helper.log" \
    || fail "QMP pinner did not pass a validated TID to apply"
grep -Fq 'applied pid=' "$TMP_DIR/cpu.state" \
    || fail "QMP pinner did not persist applied state"
cpu_isolation_cleanup 42 "$TMP_DIR/cpu.state"
grep -Fxq 'release 42' "$TMP_DIR/fake-helper.log" \
    || fail "launcher cleanup did not release the VM cgroup"

grep -Fq 'source "$here/lib/cpu-isolation.sh"' "$START_VM" \
    || fail "start-vm does not load CPU isolation"
grep -Fq '[[ "$CPU_ISOLATION" == required ]] && QEMU_CMD+=( -S )' "$START_VM" \
    || fail "required mode does not pause guest until isolation succeeds"
grep -Fq 'cpu_isolation_launch "$VM_ID" 4' "$START_VM" \
    || fail "start-vm does not launch the QMP pinner"
grep -Fq 'cpu_isolation_release_vm "$VM_ID"' "$STOP_VM" \
    || fail "stop-vm does not release the per-VM partition"

echo "PASS: CPU isolation apply/release/rollback/security/install integration"
