#!/usr/bin/env bash
# CPU isolate 提权边界与 apply 事务回归测试。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
ISOLATE="$REPO_ROOT/deploy/scripts/host-cpu-isolate.sh"
RUNTIME="$REPO_ROOT/deploy/scripts/host-cpu-isolate-runtime.sh"
CGROUP="$REPO_ROOT/deploy/scripts/host-cpu-isolate-cgroup.sh"
COLLECT_TEST="$SCRIPT_DIR/test_host_cpu_isolate_collect_grants.sh"
TRUSTED_SYSTEM_BINARY="/bin/true"
INSTANCE=9987654322
TMP_DIR=""
FAKE_PID=""
FAKE_TIDS=""
fail() {
    echo "FAIL: $*" >&2
    exit 1
}
cleanup() {
    if [[ -n "${FAKE_PID:-}" ]]; then
        kill -CONT "$FAKE_PID" 2>/dev/null || true
        kill "$FAKE_PID" 2>/dev/null || true
        wait "$FAKE_PID" 2>/dev/null || true
    fi
    rm -rf -- "${TMP_DIR:-}"
}
proc_start_time() {
    local pid="$1" line rest
    local -a fields=()
    line="$(<"/proc/$pid/stat")"
    rest="${line##*) }"
    read -ra fields <<<"$rest"
    printf '%s\n' "${fields[19]}"
}
write_trust_manifest() {
    local executable="$1" destination="$2" metadata digest device inode
    executable="$(realpath -e -- "$executable")"
    metadata="$(stat -Lc '%d %i' -- "$executable")"
    read -r device inode <<<"$metadata"
    digest="$(sha256sum -- "$executable")"; digest="${digest%% *}"
    {
        printf 'path=%s\n' "$executable"
        printf 'sha256=%s\n' "$digest"
        printf 'device=%s\n' "$device"
        printf 'inode=%s\n' "$inode"
    } > "$destination"
    chmod 0644 "$destination"
}
build_fake_qemu() {
    local source_file="$TMP_DIR/fake-qemu.c" compiler="${CC:-cc}"
    command -v "$compiler" >/dev/null 2>&1 || fail "缺少 C 编译器"
    cat > "$source_file" <<'C'
#define _GNU_SOURCE
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/syscall.h>
#include <unistd.h>
static void *vcpu_main(void *opaque)
{
    const char **config = opaque;
    FILE *stream;
    if (pthread_setname_np(pthread_self(), config[1]) != 0) {
        return NULL;
    }
    stream = fopen(config[0], "w");
    if (stream == NULL) {
        return NULL;
    }
    fprintf(stream, "%ld\n", (long)syscall(SYS_gettid));
    fclose(stream);
    for (;;) {
        pause();
    }
    return NULL;
}
int main(int argc, char **argv)
{
    pthread_t threads[2];
    const char *vcpu0[] = {argv[1], "CPU 0/TCG"};
    const char *vcpu1[] = {argv[2], "CPU 1/TCG"};
    if (argc < 3 || pthread_create(&threads[0], NULL, vcpu_main, vcpu0) != 0 ||
        pthread_create(&threads[1], NULL, vcpu_main, vcpu1) != 0) {
        return EXIT_FAILURE;
    }
    for (;;) {
        pause();
    }
    return EXIT_SUCCESS;
}
C
    mkdir -p "$TMP_DIR/fake-bin"
    "$compiler" -std=c11 -Wall -Wextra -Werror -pthread \
        -o "$TMP_DIR/fake-bin/qemu-system-x86_64" "$source_file"
}
start_fake_qemu() {
    local tid0="$TMP_DIR/fake-vcpu0.tid" tid1="$TMP_DIR/fake-vcpu1.tid" attempt
    rm -f -- "$tid0" "$tid1"
    "$TMP_DIR/fake-bin/qemu-system-x86_64" "$tid0" "$tid1" \
        -name "win10-${INSTANCE},debug-threads=on" &
    FAKE_PID=$!
    for ((attempt=0; attempt<100; attempt++)); do
        [[ -s "$tid0" && -s "$tid1" ]] && break
        sleep 0.01
    done
    [[ -s "$tid0" && -s "$tid1" ]] || fail "假 QEMU 没有创建两个 vCPU TID"
    FAKE_TIDS="$(<"$tid0"),$(<"$tid1")"; FAKE_TID="${FAKE_TIDS%%,*}"
    [[ "$FAKE_TIDS" =~ ^[0-9]+,[0-9]+$ ]] || fail "假 vCPU TID 非法"
}
stage_helper() {
    local name="$1" runtime_source="$2"
    local stage="$TMP_DIR/$name"
    local cgroup_root="$stage/cgroup"
    local target_cgroup
    mkdir -p "$cgroup_root"
    chmod 0755 "$stage"
    chmod 0755 "$cgroup_root"
    target_cgroup="$(awk -F: '$1 == "0" {print $3; exit}' "/proc/$FAKE_PID/cgroup")"
    [[ "$target_cgroup" == /* ]] || fail "无法读取 fixture 原 cgroup"
    mkdir -p "$cgroup_root$target_cgroup"
    chmod 0755 "$cgroup_root$target_cgroup"
    printf '%s\n' "$target_cgroup" > "$stage/original-cgroup"
    printf 'ORIGINAL\n' > "$cgroup_root$target_cgroup/cgroup.procs"
    cp "$runtime_source" "$stage/runtime.sh"
    cp "$CGROUP" "$stage/cgroup-runtime.sh"
    chmod 0755 "$stage/runtime.sh"
    chmod 0755 "$stage/cgroup-runtime.sh"
    sed -i '/^_run_as_caller() {/,/^}/c\_run_as_caller() { "$@"; }' \
        "$stage/runtime.sh"
    sed -i '/^_verify_vmiso_cpu_grant() {/,/^}/c\_verify_vmiso_cpu_grant() { return 0; }' \
        "$stage/runtime.sh"
    sed -i \
        -e '/^_verify_instance_cpu_grant() {/,/^}/c\_verify_instance_cpu_grant() { return 0; }' \
        -e '/^_verify_parent_memory_grant() {/,/^}/c\_verify_parent_memory_grant() { return 0; }' \
        "$stage/cgroup-runtime.sh"
    sed -i 's|readonly RMDIR="/usr/bin/rmdir"|readonly RMDIR="/bin/true"|' \
        "$stage/runtime.sh"
    sed -i 's|readonly MIGRATEPAGES="/usr/bin/migratepages"|readonly MIGRATEPAGES="/bin/true"|' \
        "$stage/runtime.sh"
    sed \
        -e "s|readonly CG_ROOT=\"/sys/fs/cgroup\"|readonly CG_ROOT=\"$cgroup_root\"|" \
        -e "s|readonly RUNTIME_DIR=\"/run/qemu-vmate-cpu-isolate\"|readonly RUNTIME_DIR=\"$stage/run\"|" \
        -e "s|readonly RUNTIME_LIB=\"/usr/local/libexec/qemu-vmate-cpu-isolate-runtime-v5.sh\"|readonly RUNTIME_LIB=\"$stage/runtime.sh\"|" \
        -e "s|readonly CGROUP_LIB=\"/usr/local/libexec/qemu-vmate-cpu-isolate-cgroup-v5.sh\"|readonly CGROUP_LIB=\"$stage/cgroup-runtime.sh\"|" \
        -e "s|readonly TRUST_MANIFEST=\"/usr/local/libexec/qemu-vmate-cpu-isolate-qemu.conf\"|readonly TRUST_MANIFEST=\"$stage/trust.conf\"|" \
        -e '/^_precheck() {/,/^}/c\_precheck() { return 0; }' \
        "$ISOLATE" > "$stage/helper"
    chmod 0755 "$stage/helper"
    printf '%s\n' "$stage"
}
expand_cpu_list_csv() {
    local value="$1" part start end cpu
    local -a output=() parts=()
    IFS=',' read -ra parts <<< "$value"
    for part in "${parts[@]}"; do
        if [[ "$part" == *-* ]]; then
            start="${part%-*}"; end="${part#*-}"
            for ((cpu=start; cpu<=end; cpu++)); do
                output+=("$cpu")
            done
        else
            output+=("$part")
        fi
    done
    printf '%s\n' "${output[@]}" | sort -n -u | paste -sd, -
}
first_two_host_cpus() {
    local cpu key sibling first="" first_key="" online
    online="$(awk '/^Cpus_allowed_list:/{print $2; exit}' /proc/self/status)"; online="$(expand_cpu_list_csv "$online")"
    for cpu in ${online//,/ }; do
        key="$(expand_cpu_list_csv "$(<"/sys/devices/system/cpu/cpu${cpu}/topology/thread_siblings_list")")"
        [[ "$key" =~ ^[0-9]+,[0-9]+$ ]] || continue
        sibling="${key%%,*}"; [[ "$sibling" == "$cpu" ]] && sibling="${key#*,}"
        [[ ! -r "/sys/devices/system/cpu/cpu${sibling}/online" || "$(<"/sys/devices/system/cpu/cpu${sibling}/online")" == "1" ]] || continue
        if [[ -z "$first" ]]; then first="$cpu"; first_key="$key"
        elif [[ "$key" != "$first_key" ]]; then printf '%s,%s\n' "$first" "$cpu"; return; fi
    done
    return 1
}
test_unknown_cgroup_child_is_rejected() (
    local fixture abnormal
    fixture="$(mktemp -d)"
    trap 'rm -rf -- "$fixture"' EXIT
    # shellcheck disable=SC2329
    _die() { echo "unknown-child-test: $*" >&2; exit 1; }
    # shellcheck disable=SC1090
    source "$RUNTIME"
    # shellcheck disable=SC1090
    source "$CGROUP"
    VMISO="$fixture/vmiso"
    mkdir -p "$VMISO/vm-1"
    : > "$VMISO/cgroup.procs"
    _scan_vmiso_children
    [[ ${#ISO_CHILD_PATHS[@]} == 1 && "${ISO_CHILD_PATHS[0]##*/}" == "vm-1" ]] \
        || fail "cgroup 扫描没有精确返回合法 child"
    for abnormal in foo .foo vm-0 vm-x; do
        mkdir "$VMISO/$abnormal"
        if (_scan_vmiso_children >/dev/null 2>&1); then
            fail "cgroup 扫描忽略异常目录: $abnormal"
        fi
        rmdir "$VMISO/$abnormal"
    done
    for abnormal in foo vm-2; do
        ln -s "$fixture" "$VMISO/$abnormal"
        if (_scan_vmiso_children >/dev/null 2>&1); then
            fail "cgroup 扫描忽略 symlink: $abnormal"
        fi
        rm -f "$VMISO/$abnormal"
    done
    printf 'collision\n' > "$VMISO/vm-2"
    if (_scan_vmiso_children >/dev/null 2>&1); then
        fail "cgroup 扫描接受了 vm-* 普通文件"
    fi
)
# shellcheck disable=SC2154,SC2329
test_e5_stale_snapshot_selector() (
    local cpu vm preference preference_tpc1 allocated first_instance_cpus=""
    local host_smt_width=2 offline_cpu=""
    # shellcheck disable=SC2329
    _die() { echo "selector-test: $*" >&2; exit 1; }
    _validate_topology_policy() {
        case "$1:$2:$3" in 2:1:1|4:2:2|4:1:1) return 0 ;; *) _die "非法拓扑策略" ;; esac
    }
    # shellcheck disable=SC1090
    source "$RUNTIME"
    # shellcheck disable=SC1090
    source "$CGROUP"
    _host_core_key() {
        local logical="$1" physical="$1"
        (( physical >= 22 )) && physical=$((physical - 22))
        case "$host_smt_width" in
            1) printf '%s\n' "$physical" ;;
            2) printf '%s,%s\n' "$physical" "$((physical + 22))" ;;
            4) printf '%s,%s,%s,%s\n' "$physical" "$((physical + 22))" \
                "$((physical + 44))" "$((physical + 66))" ;;
        esac
    }
    _cpu_numa_node() { printf '0\n'; }
    _cpu_package() { printf '0\n'; }
    _cpu_is_online() { [[ "$1" != "$offline_cpu" ]]; }
    _validate_host_locality_visibility() { return 0; }
    declare -A ISO_HELD=()
    preference=""
    for ((cpu=3; cpu<22; cpu++)); do
        preference="${preference:+$preference,}$cpu,$((cpu + 22))"
    done
    for ((vm=1; vm<=9; vm++)); do
        _select_instance_cpus "$preference" 0 4 0 2 2
        (( vm == 1 )) && first_instance_cpus="$_instance_cpus_csv"
        [[ "$_selected_domain" == "0:0" && ${#_vcpu_mine[@]} == 4 ]] \
            || fail "E5 VM$vm 没有保持单 locality domain 的 2C/4T"
        while IFS= read -r allocated; do
            [[ -z "${ISO_HELD[$allocated]:-}" ]] \
                || fail "E5 stale snapshot 重复分配 CPU $allocated"
            ISO_HELD[$allocated]=1
        done < <(_strict_cpu_list_to_lines "$_instance_cpus_csv")
    done
    [[ ${#ISO_HELD[@]} == 36 ]] || fail "E5 第九台 VM 应成功并累计占 18C/36T"
    [[ $((44 - ${#ISO_HELD[@]})) == 8 ]] || fail "E5 九台后应余 4C/8T"
    if (_select_instance_cpus "$preference" 0 4 0 2 2 >/dev/null 2>&1); then fail "E5 第十台应因完整核容量不足而拒绝"; fi
    while IFS= read -r allocated; do unset 'ISO_HELD[$allocated]'; done \
        < <(_strict_cpu_list_to_lines "$first_instance_cpus")
    _select_instance_cpus "$preference" 0 4 0 2 2
    [[ "$_instance_cpus_csv" == "$first_instance_cpus" ]] \
        || fail "release 后的完整物理核未被锁内 selector 重新使用"
    declare -A ISO_HELD=() service_cores=()
    for vm in {1..7}; do
        _select_instance_cpus "$preference" 0 4 1 2 2
        [[ ${#_vcpu_mine[@]} == 4 && ${#_service_mine[@]} == 1 && ${#_mine[@]} == 5 ]] \
            || fail "2C4T service=1 的 exact 预算不是 4+1"
        _validate_recorded_topology "$_vcpu_cpus_csv" 2 2 1 0:0 "$_instance_cpus_csv"
        service_cores["$(_host_core_key "${_service_mine[0]}")"]=1
        while IFS= read -r allocated; do
            [[ -z "${ISO_HELD[$allocated]:-}" ]] || fail "service packing 重复逻辑 CPU $allocated"
            ISO_HELD[$allocated]=1
        done < <(_strict_cpu_list_to_lines "$_instance_cpus_csv")
    done
    [[ ${#ISO_HELD[@]} == 35 && ${#service_cores[@]} == 4 ]] \
        || fail "E5 七台 2C4T+service1 应占 35T/18C"
    if (_select_instance_cpus "$preference" 0 4 1 2 2 >/dev/null 2>&1); then fail "E5 第八台 2C4T+service1 应拒绝"; fi
    _validate_recorded_topology "3,25,4,26" 2 2 2 0:0 "3,4,5,25,26,27"
    if (_validate_recorded_topology "3,25,4,26" 2 2 2 0:0 "3,4,5,6,25,26" >/dev/null 2>&1); then
        fail "service2 跨两颗物理核应被拒绝"
    fi
    declare -A ISO_HELD=()
    preference_tpc1=""
    for ((cpu=3; cpu<22; cpu++)); do
        preference_tpc1="${preference_tpc1:+$preference_tpc1,}$cpu"
    done
    for ((cpu=25; cpu<44; cpu++)); do
        preference_tpc1="$preference_tpc1,$cpu"
    done
    _select_instance_cpus "$preference_tpc1" 0 2 0 1 1
    [[ "$_vcpu_cpus_csv" == "3,4" && "$_instance_cpus_csv" == "3,4" ]] \
        || fail "2C2T 没有按 1:1 映射两个不同 host 物理核"
    declare -A ISO_HELD=()
    for vm in {1..9}; do
        _select_instance_cpus "$preference_tpc1" 0 4 0 1 1
        if (( vm == 1 )); then
            [[ "$_vcpu_cpus_csv" == "3,4,5,6" && "$_instance_cpus_csv" == "3,4,5,6" ]] \
                || fail "4C4T 没有按 1:1 映射四颗不同 host 物理核"
            _validate_recorded_topology "$_vcpu_cpus_csv" 1 1 0 0:0 "$_instance_cpus_csv"
        fi
        while IFS= read -r allocated; do ISO_HELD[$allocated]=1; done \
            < <(_strict_cpu_list_to_lines "$_instance_cpus_csv")
    done
    [[ ${#ISO_HELD[@]} == 36 ]] || fail "九台 4C4T 应占 36 条唯一逻辑 CPU"
    if (_select_instance_cpus "$preference_tpc1" 0 4 0 1 1 >/dev/null 2>&1); then fail "第十台 4C4T 应因只余 2 条线程而拒绝"; fi
    ISO_HELD=()
    _select_instance_cpus "$preference_tpc1" 0 4 1 1 1
    [[ "${_service_mine[*]}" == "7" && "$_instance_cpus_csv" == "3,4,5,6,7" ]] \
        || fail "4C4T service=1 没有保持五条逻辑 CPU 的 1:1 exact"
    for host_smt_width in 1 4; do
        if (_select_instance_cpus "$preference_tpc1" 0 2 0 1 1 >/dev/null 2>&1); then
            fail "selector 接受了 SMT${host_smt_width} host core"
        fi
    done
    host_smt_width=2; offline_cpu=""
    _select_instance_cpus "$preference_tpc1" 0 2 0 1 1
    offline_cpu=25
    _validate_recorded_topology "3,4" 1 1 0 0:0 "3,4" 1
    offline_cpu=3
    if (_validate_recorded_topology "3,4" 1 1 0 0:0 "3,4" 1 >/dev/null 2>&1); then
        fail "状态重验接受了实际选中的 offline CPU"
    fi
    _validate_recorded_topology "3,4" 1 1 0 0:0 "3,4" 0
    offline_cpu=""; host_smt_width=4
    if (_validate_recorded_topology "3,4,5,6" 1 1 0 0:0 "3,4,5,6" 0 >/dev/null 2>&1); then
        fail "状态重验接受了 SMT4 host core"
    fi
)
original_procs_path() {
    local stage="$1" relative
    relative="$(<"$stage/original-cgroup")"
    printf '%s/cgroup%s/cgroup.procs\n' "$stage" "$relative"
}
assert_process_resumed() {
    local state attempt
    for ((attempt=0; attempt<100; attempt++)); do
        state="$(awk '/^State:/{print $2; exit}' "/proc/$FAKE_PID/status")"
        [[ "$state" != "T" && "$state" != "t" ]] && return 0
        sleep 0.01
    done
    fail "事务失败后假 QEMU 仍处于停止态"
}
test_same_name_executable_is_rejected() {
    local stage output cpu
    stage="$(stage_helper untrusted "$RUNTIME")"
    write_trust_manifest "$TRUSTED_SYSTEM_BINARY" "$stage/trust.conf"
    cpu="$(first_two_host_cpus)"
    if output="$("$stage/helper" apply "$INSTANCE" 0 \
            "$FAKE_PID" "$cpu" "$FAKE_TIDS" 0 1 1 2>&1)"; then
        fail "helper 接受了仅 basename 相同的未登记 executable"
    fi
    [[ "$output" == *"未在 root-owned 信任清单中"* ]] \
        || fail "同名伪进程没有在 executable trust 边界被拒绝: $output"
    [[ ! -e "$stage/cgroup/vmiso" ]] || fail "拒绝同名伪进程前已修改 cpuset"
}
test_taskset_failure_rolls_back() {
    local stage output cpu original_affinity partition
    stage="$(stage_helper taskset-fault "$RUNTIME")"
    write_trust_manifest "$TMP_DIR/fake-bin/qemu-system-x86_64" "$stage/trust.conf"
    cat > "$stage/fail-taskset" <<'SH'
#!/bin/sh
exit 73
SH
    chmod 0755 "$stage/fail-taskset"
    sed -i "s|readonly TASKSET=\"/usr/bin/taskset\"|readonly TASKSET=\"$stage/fail-taskset\"|" \
        "$stage/runtime.sh"
    original_affinity="$(awk '/^Cpus_allowed_list:/{print $2; exit}' "/proc/$FAKE_TID/status")"
    cpu="$(first_two_host_cpus)"
    if output="$("$stage/helper" apply "$INSTANCE" 0 \
            "$FAKE_PID" "$cpu" "$FAKE_TIDS" 0 1 1 2>&1)"; then
        fail "注入 taskset 故障后 helper 仍返回成功"
    fi
    [[ "$output" == *"taskset vCPU"* ]] || fail "未命中 taskset 故障点: $output"
    [[ ! -e "$stage/run/instances/$INSTANCE.state" ]] \
        || fail "事务失败后残留可信实例登记"
    [[ "$(<"$(original_procs_path "$stage")")" == "$FAKE_PID" ]] \
        || fail "事务失败后未把 PID 写回原 cgroup"
    partition="$(<"$stage/cgroup/vmiso/cpuset.cpus.partition")"
    [[ "$partition" == "member" ]] || fail "事务失败后 partition 未退出 root: $partition"
    [[ "$(awk '/^Cpus_allowed_list:/{print $2; exit}' "/proc/$FAKE_TID/status")" == \
       "$original_affinity" ]] || fail "事务失败后 vCPU affinity 未恢复"
    assert_process_resumed
}
test_pid_identity_change_blocks_root_attach() {
    local stage runtime_override counter start output cpu
    runtime_override="$TMP_DIR/pid-runtime-source.sh"
    cp "$RUNTIME" "$runtime_override"
    counter="$TMP_DIR/pid-start-counter"
    printf '0\n' > "$counter"
    start="$(proc_start_time "$FAKE_PID")"
    cat >> "$runtime_override" <<EOF
# 中文注释：前三次读取返回原 starttime；第四次模拟同一数字 PID 已被复用。
_proc_start_time() {
    local count
    count="\$(<"$counter")"
    count=\$((count + 1))
    printf '%s\\n' "\$count" > "$counter"
    if (( count <= 3 )); then
        printf '%s\\n' "$start"
    else
        printf '%s\\n' "$((10#$start + 1))"
    fi
}
EOF
    stage="$(stage_helper pid-reuse "$runtime_override")"
    write_trust_manifest "$TMP_DIR/fake-bin/qemu-system-x86_64" "$stage/trust.conf"
    cpu="$(first_two_host_cpus)"
    if output="$("$stage/helper" apply "$INSTANCE" 0 \
            "$FAKE_PID" "$cpu" "$FAKE_TIDS" 0 1 1 2>&1)"; then
        fail "PID 身份变化后 helper 仍返回成功"
    fi
    [[ "$output" == *"pid 在隔离前被复用"* ]] \
        || fail "PID 身份变化未在 root attach 前被拒绝: $output"
    [[ "$(<"$(original_procs_path "$stage")")" == "ORIGINAL" ]] \
        || fail "PID 身份变化后仍执行了 root cgroup attach"
    [[ ! -e "$stage/run/instances/$INSTANCE.state" ]] \
        || fail "PID 身份变化后残留实例登记"
    [[ "$(<"$stage/cgroup/vmiso/cpuset.cpus.partition")" == "member" ]] \
        || fail "PID 身份变化后 partition 未回滚"
    kill -CONT "$FAKE_PID"
}
test_exact_logical_cpus_are_reserved() {
    local stage output cpu expected actual state
    stage="$(stage_helper smt-siblings "$RUNTIME")"
    write_trust_manifest "$TMP_DIR/fake-bin/qemu-system-x86_64" "$stage/trust.conf"
    cpu="$(first_two_host_cpus)"
    expected="$(expand_cpu_list_csv "$cpu")"
    if ! output="$("$stage/helper" apply "$INSTANCE" 0 \
            "$FAKE_PID" "$cpu" "$FAKE_TIDS" 0 1 1 2>&1)"; then
        fail "1:1 逻辑 CPU 隔离 apply 失败: $output"
    fi
    actual="$(<"$stage/cgroup/vmiso/cpuset.cpus")"
    [[ "$actual" == "$expected" ]] \
        || fail "cpuset 不是实际选中逻辑 CPU: expected=$expected actual=$actual"
    state="$stage/run/instances/$INSTANCE.state"
    grep -Fx 'abi=5' "$state" >/dev/null || fail "实例状态没有 ABI5 标记"
    sed -i 's/^host_threads_per_core=1$/host_threads_per_core=2/' "$state"
    if output="$("$stage/helper" status 2>&1)"; then
        fail "status 接受了被篡改为非法 packing 组合的实例状态"
    fi
    [[ "$output" == *"不支持的 vCPU/guest_tpc/host_tpc 组合"* ]] \
        || fail "非法实例状态没有命中 topology policy: $output"
}
main() {
    [[ -x "$ISOLATE" && -f "$RUNTIME" && -f "$CGROUP" && -x "$COLLECT_TEST" && -x "$TRUSTED_SYSTEM_BINARY" ]] \
        || fail "CPU isolate 测试依赖缺失"
    grep -F '_validate_trusted_executable' "$RUNTIME" >/dev/null \
        || fail "runtime 缺少 executable trust"
    grep -F -- '--clear-groups --bounding-set=-all' "$RUNTIME" >/dev/null \
        || fail "生产 runtime 缺少调用者降权边界"
    grep -F "trap '_apply_transaction_exit" "$RUNTIME" >/dev/null \
        || fail "runtime 缺少 apply EXIT 回滚"
    test_unknown_cgroup_child_is_rejected
    test_e5_stale_snapshot_selector
    if [[ "${VMATE_CPU_ISO_TEST_USERNS:-0}" != "1" ]]; then
        "$COLLECT_TEST"
        if ! command -v unshare >/dev/null 2>&1 || ! unshare -Ur true 2>/dev/null; then
            echo "SKIP: 内核禁用 unprivileged user namespace；静态事务断言已通过"
            return 0
        fi
        exec unshare -Ur env VMATE_CPU_ISO_TEST_USERNS=1 bash "$0" "$@"
    fi
    if ! first_two_host_cpus >/dev/null; then
        echo "SKIP: 动态事务测试需要至少两颗在线 SMT2 host core"
        return 0
    fi
    TMP_DIR="$(mktemp -d)"
    trap cleanup EXIT
    build_fake_qemu
    start_fake_qemu
    test_same_name_executable_is_rejected
    test_taskset_failure_rolls_back
    test_pid_identity_change_blocks_root_attach
    test_exact_logical_cpus_are_reserved
    echo "PASS: CPU isolate executable trust、PID 身份防复用、1:1 exact 与事务故障回滚"
}
main "$@"
