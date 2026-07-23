#!/usr/bin/env bash
# 使用普通临时文件验证 collect 的 parent/child grant 复核，不访问真实 cgroup。
# shellcheck disable=SC2034
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
RUNTIME="$REPO_ROOT/deploy/scripts/host-cpu-isolate-runtime.sh"
CGROUP="$REPO_ROOT/deploy/scripts/host-cpu-isolate-cgroup.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT

# shellcheck disable=SC2329
_die() { echo "collect-grant-test: $*" >&2; exit 1; }
# shellcheck disable=SC1090
source "$RUNTIME"
# shellcheck disable=SC1090
source "$CGROUP"

VMISO="$fixture/vmiso"
FIXTURE_CHILD="$VMISO/vm-1"
state="$fixture/1.state"
log="$fixture/grants.log"
mkdir -p "$FIXTURE_CHILD"
: > "$VMISO/cgroup.procs"
: > "$state"
printf '3,25\n' > "$VMISO/cpuset.cpus"
printf '3,25\n' > "$FIXTURE_CHILD/cpuset.cpus"

FIXTURE_PHASE=preparing
FAIL_PARENT=0
_validate_vmiso_dir() { :; }
_validate_instance_cgroup() { :; }
_scan_vmiso_children() { ISO_CHILD_PATHS=("$FIXTURE_CHILD"); }
_instance_state_path() { printf '%s\n' "$state"; }
_validate_recorded_topology() { :; }
_read_instance_state() {
    STATE_INSTANCE=1; STATE_CPUS=3,25; STATE_VCPU_CPUS=3,25
    STATE_GUEST_TPC=1; STATE_HOST_TPC=1; STATE_SERVICE_CPUS=0
    STATE_DOMAIN=0:0; STATE_MEMS=0; STATE_PHASE="$FIXTURE_PHASE"
}
_verify_instance_cpu_grant() {
    printf 'child=%s|%s|%s\n' "$1" "$2" "$3" >> "$log"
}
_verify_vmiso_cpu_grant() {
    (( FAIL_PARENT == 0 )) || _die "模拟 parent CPU grant 失效"
    printf 'parent-cpu=%s\n' "$1" >> "$log"
}
_verify_parent_memory_grant() {
    (( FAIL_PARENT == 0 )) || _die "模拟 parent memory grant 失效"
    printf 'parent-mem=%s\n' "$1" >> "$log"
}

assert_log() {
    local expected="$1" actual
    actual="$(<"$log")"
    [[ "$actual" == "$expected" ]] || fail "grant 复核调用不符: $actual"
}

# preparing child 必须验证当时继承的 parent memory union，而不是提前要求目标 node。
printf '0,1\n' > "$VMISO/cpuset.mems"
printf '0,1\n' > "$FIXTURE_CHILD/cpuset.mems"
: > "$log"
_collect_instance_allocations 1
assert_log $'child=3,25|0,1|'"$FIXTURE_CHILD"$'\nparent-cpu=3,25\nparent-mem=0,1'

# active child 已收窄到目标 node，仍逐 child 核对 CPU/memory effective grant。
FIXTURE_PHASE=active
printf '0\n' > "$VMISO/cpuset.mems"
printf '0\n' > "$FIXTURE_CHILD/cpuset.mems"
: > "$log"
_collect_instance_allocations 1
assert_log $'child=3,25|0|'"$FIXTURE_CHILD"$'\nparent-cpu=3,25\nparent-mem=0'

FAIL_PARENT=1
if (_collect_instance_allocations 1 >/dev/null 2>&1); then
    fail "collect 忽略了 parent partition/effective grant 故障"
fi

# release 的 verify_parent=0 路径不得被失效/offline parent grant 阻塞。
: > "$log"
_collect_instance_allocations 0
[[ ! -s "$log" ]] || fail "release 路径错误执行了 parent/child effective 复核"

echo "PASS: collect parent/child cpuset effective grant verification"
