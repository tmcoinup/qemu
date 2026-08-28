#!/usr/bin/env bash
# Exercise CPU isolation against a regular-file cgroup/proc/sysfs mock.  No
# real affinity, cgroup, VM, sudoers, or host state is changed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
HELPER="$REPO_ROOT/deploy/host/cpu-isolate.sh"
INSTALLER="$REPO_ROOT/deploy/host/install-cpu-isolation.sh"
START_VM="$REPO_ROOT/deploy/scripts/start-vm.sh"
STOP_VM="$REPO_ROOT/deploy/scripts/stop-vm.sh"
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
grep -Fq '/usr/local/libexec/qemu-cpu-isolate oom-protect *' \
    "$TMP_DIR/install.out" || fail "installer sudoers rule does not scope OOM protection"

# Exercise the launcher-side QMP handshake.  required mode must query the
# vCPU native TID, call the helper, and only then issue QMP cont.
cat >"$TMP_DIR/fake-qmp.py" <<'PY'
#!/usr/bin/env python3
import json
import os
import socket
import sys
import threading

path = sys.argv[-2]
record = sys.argv[-1]
vcpu_count = int(os.environ.get("FAKE_QMP_VCPUS", "1"))
threads_per_core = int(os.environ.get("FAKE_QMP_THREADS_PER_CORE", "1"))
if vcpu_count < 1 or threads_per_core < 1 or vcpu_count % threads_per_core:
    raise SystemExit("invalid fake QMP topology")
stop_workers = threading.Event()
worker_ids = []
worker_ready = threading.Condition()

def worker():
    with worker_ready:
        worker_ids.append(threading.get_native_id())
        worker_ready.notify_all()
    stop_workers.wait()

workers = [threading.Thread(target=worker, daemon=True) for _ in range(vcpu_count)]
for thread in workers:
    thread.start()
with worker_ready:
    while len(worker_ids) != vcpu_count:
        worker_ready.wait(timeout=1)
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
            result = [
                {
                    "cpu-index": index,
                    "thread-id": worker_ids[index],
                    "props": {
                        "socket-id": 0,
                        "core-id": index // threads_per_core,
                        "thread-id": index % threads_per_core,
                        "node-id": 0,
                    },
                }
                for index in range(vcpu_count)
            ]
        else:
            result = {}
        stream.write((json.dumps({"return": result, "id": ident}) + "\r\n").encode())
        if command == "cont":
            with open(record, "w", encoding="utf-8") as output:
                output.write("cont\n")
            break
    conn.close()
server.close()
stop_workers.set()
for thread in workers:
    thread.join(timeout=1)
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

# --cpu-isolate=false must be a real fast path, not a cosmetic status string.
# In off mode the launcher neither prepares the helper nor starts the QMP
# pinner, creates isolation state, invokes taskset/cgroup apply, or consumes
# --svc-cpus.  OOM protection is a separate policy tested elsewhere.
CPU_ISOLATION_HELPER="$TMP_DIR/fake-helper"
FAKE_HELPER_LOG="$TMP_DIR/fake-helper.log"
export CPU_ISOLATION_HELPER FAKE_HELPER_LOG
: >"$FAKE_HELPER_LOG"
QEMU_SERVICE_CPUS=4
DRY_RUN=0
CPU_ISOLATION_LAUNCHED=0
CPU_ISOLATION_PINNER_PID=""
cpu_isolation_ensure_ready || fail "off mode unexpectedly required a helper"
cpu_isolation_launch 42 8 4 2 "$TMP_DIR/does-not-exist.sock" \
    "$TMP_DIR/does-not-exist.pid" "$TMP_DIR/off.state" || \
    fail "off mode did not bypass isolation launch"
[[ "$CPU_ISOLATION_LAUNCHED" == 0 && -z "$CPU_ISOLATION_PINNER_PID" ]] || \
    fail "off mode started the isolation pinner"
[[ ! -e "$TMP_DIR/off.state" && ! -s "$FAKE_HELPER_LOG" ]] || \
    fail "off mode created state or invoked the isolation helper"
[[ "$(cpu_isolation_print_plan)" == '  CPU 隔离: off' ]] || \
    fail "off mode plan is not explicit"
unset CPU_ISOLATION_HELPER

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
        # This mock cannot change EUID like real sudo.  Executing the helper
        # would make its non-root trampoline invoke this mock recursively.
        # Validate the exact non-mutating NOPASSWD readiness probe instead.
        [[ "${2:-}" == release &&
           "${3:-}" == 999999999999999999 && $# == 3 ]] || exit 1
        exit 0
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
unset QEMU_SERVICE_CPUS
HOST_RESERVE_CORES=auto
DRY_RUN=0
FAKE_HELPER_LOG="$TMP_DIR/fake-helper.log"
export CPU_ISOLATION_HELPER FAKE_HELPER_LOG
PLAN_OUTPUT=$(cpu_isolation_print_plan)
grep -Fq 'service CPUs=0' <<<"$PLAN_OUTPUT" \
    || fail "CPU isolation library default service CPU count is not zero"
cpu_isolation_launch 42 1 1 1 "$TMP_DIR/qmp.sock" "$TMP_DIR/qemu.pid" \
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

# auto must count CPUs already held by other VM cgroups.  With two eligible
# CPUs, one vCPU and one held CPU, the optional service CPU must fall back to
# zero instead of asking the root helper for impossible capacity.
AUTO_TOPOLOGY="$TMP_DIR/auto-topology"
AUTO_CGROUP="$TMP_DIR/auto-cgroup"
mkdir -p "$AUTO_TOPOLOGY" "$AUTO_CGROUP/qemu-vm-isolation/vm99"
printf '9000\n' >"$AUTO_CGROUP/qemu-vm-isolation/vm99/cgroup.procs"
printf '2\n' >"$AUTO_CGROUP/qemu-vm-isolation/vm99/cpuset.cpus"
printf '0-3\n' >"$AUTO_TOPOLOGY/online"
for cpu in 0 1 2 3; do
    mkdir -p "$AUTO_TOPOLOGY/cpu${cpu}/topology"
    printf '%s\n' "$cpu" \
        >"$AUTO_TOPOLOGY/cpu${cpu}/topology/thread_siblings_list"
done
: >"$TMP_DIR/fake-helper.log"
"$TMP_DIR/fake-qmp.py" -name vm43 "$TMP_DIR/qmp-auto.sock" \
    "$TMP_DIR/qmp-auto.record" &
FAKE_QMP_PID=$!
for _ in $(seq 1 100); do
    [[ -S "$TMP_DIR/qmp-auto.sock" ]] && break
    kill -0 "$FAKE_QMP_PID" 2>/dev/null || fail "auto fake QMP exited early"
    sleep 0.01
done
QEMU_SERVICE_CPUS=auto
CPU_ISOLATION_SYS_CPU_ROOT=$AUTO_TOPOLOGY
CPU_ISOLATION_CGROUP_ROOT=$AUTO_CGROUP
cpu_isolation_launch 43 1 1 1 "$TMP_DIR/qmp-auto.sock" "$TMP_DIR/qemu-auto.pid" \
    "$TMP_DIR/cpu-auto.state"
wait "$CPU_ISOLATION_PINNER_PID" || fail "auto QMP pinner failed"
CPU_ISOLATION_PINNER_PID=""
wait "$FAKE_QMP_PID" || fail "auto fake QMP failed"
grep -Eq '^apply 43 [0-9]+ 3 [0-9]+ 0$' "$TMP_DIR/fake-helper.log" \
    || fail "auto service CPU did not account for an existing VM allocation"
cpu_isolation_cleanup 43 "$TMP_DIR/cpu-auto.state"
unset CPU_ISOLATION_SYS_CPU_ROOT CPU_ISOLATION_CGROUP_ROOT

# A 2C/4T guest must consume two complete host SMT cores.  Seven existing
# 2C/4T VMs occupy host cores 3..16; vm8 must receive cores 17 and 18, leaving
# host cores 0..2 and 19..21 (6C/12T) outside the eight-VM allocation.
SMT_TOPOLOGY="$TMP_DIR/smt-topology"
SMT_CGROUP="$TMP_DIR/smt-cgroup"
mkdir -p "$SMT_TOPOLOGY" "$SMT_CGROUP/qemu-vm-isolation"
printf '0-43\n' >"$SMT_TOPOLOGY/online"
for cpu in $(seq 0 43); do
    if ((cpu < 22)); then sibling=$((cpu + 22)); else sibling=$((cpu - 22)); fi
    first=$cpu
    second=$sibling
    if ((first > second)); then first=$sibling; second=$cpu; fi
    mkdir -p "$SMT_TOPOLOGY/cpu${cpu}/topology"
    printf '%s,%s\n' "$first" "$second" \
        >"$SMT_TOPOLOGY/cpu${cpu}/topology/thread_siblings_list"
done
for vm in $(seq 1 7); do
    first_core=$((3 + (vm - 1) * 2))
    second_core=$((first_core + 1))
    mkdir -p "$SMT_CGROUP/qemu-vm-isolation/vm${vm}"
    printf '%s\n' "$((9000 + vm))" \
        >"$SMT_CGROUP/qemu-vm-isolation/vm${vm}/cgroup.procs"
    printf '%s,%s,%s,%s\n' \
        "$first_core" "$((first_core + 22))" \
        "$second_core" "$((second_core + 22))" \
        >"$SMT_CGROUP/qemu-vm-isolation/vm${vm}/cpuset.cpus"
done
: >"$TMP_DIR/fake-helper.log"
FAKE_QMP_VCPUS=4 FAKE_QMP_THREADS_PER_CORE=2 \
    "$TMP_DIR/fake-qmp.py" -name vm8 "$TMP_DIR/qmp-smt.sock" \
    "$TMP_DIR/qmp-smt.record" &
FAKE_QMP_PID=$!
for _ in $(seq 1 100); do
    [[ -S "$TMP_DIR/qmp-smt.sock" ]] && break
    kill -0 "$FAKE_QMP_PID" 2>/dev/null || fail "SMT fake QMP exited early"
    sleep 0.01
done
QEMU_SERVICE_CPUS=0
CPU_ISOLATION_SYS_CPU_ROOT=$SMT_TOPOLOGY
CPU_ISOLATION_CGROUP_ROOT=$SMT_CGROUP
cpu_isolation_launch 8 4 2 2 "$TMP_DIR/qmp-smt.sock" \
    "$TMP_DIR/qemu-smt.pid" "$TMP_DIR/cpu-smt.state"
wait "$CPU_ISOLATION_PINNER_PID" || fail "2C/4T topology pinner failed"
CPU_ISOLATION_PINNER_PID=""
wait "$FAKE_QMP_PID" || fail "SMT fake QMP failed"
grep -Eq '^apply 8 [0-9]+ 17,39,18,40 [0-9]+,[0-9]+,[0-9]+,[0-9]+ 0$' \
    "$TMP_DIR/fake-helper.log" \
    || fail "vm8 was not mapped to two complete host SMT cores"
cpu_isolation_cleanup 8 "$TMP_DIR/cpu-smt.state"
unset CPU_ISOLATION_SYS_CPU_ROOT CPU_ISOLATION_CGROUP_ROOT QEMU_SERVICE_CPUS

grep -Fq 'source "$here/lib/cpu-isolation.sh"' "$START_VM" \
    || fail "start-vm does not load CPU isolation"
grep -Fq -- 'false) CPU_ISOLATION=off ;;' "$START_VM" \
    || fail "start-vm no longer maps --cpu-isolate=false to off"
grep -Fq 'QEMU_SERVICE_CPUS="${QEMU_SERVICE_CPUS:-0}"' "$START_VM" \
    || fail "start-vm default service CPU count is not zero"
grep -Fq '[[ "$CPU_ISOLATION" == required ]] && QEMU_CMD+=( -S )' "$START_VM" \
    || fail "required mode does not pause guest until isolation succeeds"
grep -Fq 'cpu_isolation_launch "$VM_ID" "$CPU_VCPUS" "$CPU_CORES"' "$START_VM" \
    || fail "start-vm does not launch the QMP pinner with profile CPU topology"
grep -Fq 'export -n SUDO_PASSWORD' "$START_VM" \
    || fail "start-vm leaves a caller-exported host credential exported"
grep -Fq 'QEMU_LAUNCH=( env -u SUDO_PASSWORD )' "$START_VM" \
    || fail "start-vm does not strip the host credential from QEMU's environment"
[[ "$(grep -Fc '"${QEMU_LAUNCH[@]}" "${QEMU_EXEC_CMD[@]}"' "$START_VM")" -eq 3 ]] \
    || fail "not every QEMU launch mode uses the credential-scrubbed wrapper"
grep -Fq 'cpu_isolation_release_vm "$VM_ID"' "$STOP_VM" \
    || fail "stop-vm does not release the per-VM partition"

echo "PASS: CPU isolation apply/release/rollback/security/install integration"
