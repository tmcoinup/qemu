#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# CPU isolate 提权边界与 apply 事务回归测试。
#
# 测试在 user namespace 内运行 helper 的 namespace-root 副本，并把 cgroup 根定向到
# 临时普通目录；不会修改真实宿主 cgroup。真实 pthread 进程提供 QEMU 风格 vCPU TID，
# 用于验证：同名未登记 executable 被拒绝、taskset 故障完整回滚、PID 身份变化时不会
# 执行 root cgroup attach。若内核禁用 unprivileged userns，则保留静态安全断言并跳过
# 仅 userns 能完成的动态部分。
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
ISOLATE="$REPO_ROOT/deploy/scripts/host-cpu-isolate.sh"
RUNTIME="$REPO_ROOT/deploy/scripts/host-cpu-isolate-runtime.sh"
TRUSTED_SYSTEM_BINARY="/bin/true"
INSTANCE=9987654322
TMP_DIR=""
FAKE_PID=""

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
    const char *tid_file = opaque;
    FILE *stream;

    if (pthread_setname_np(pthread_self(), "CPU 0/TCG") != 0) {
        return NULL;
    }
    stream = fopen(tid_file, "w");
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
    pthread_t thread;

    (void)argv;
    if (argc < 2 || pthread_create(&thread, NULL, vcpu_main, argv[1]) != 0) {
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
    local tid_file="$TMP_DIR/fake-vcpu.tid" attempt

    rm -f -- "$tid_file"
    "$TMP_DIR/fake-bin/qemu-system-x86_64" "$tid_file" \
        -name "win10-${INSTANCE},debug-threads=on" &
    FAKE_PID=$!
    for ((attempt=0; attempt<100; attempt++)); do
        [[ -s "$tid_file" ]] && break
        sleep 0.01
    done
    [[ -s "$tid_file" ]] || fail "假 QEMU 没有创建 vCPU TID"
    FAKE_TID="$(<"$tid_file")"
    [[ "$FAKE_TID" =~ ^[0-9]+$ ]] || fail "假 vCPU TID 非法"
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
    chmod 0755 "$stage/runtime.sh"
    # unshare -Ur 内核会永久禁用 setgroups(2)，真实 setpriv --clear-groups 因而无法
    # 执行；测试副本保持 namespace-root 与目标同一映射 UID，直接运行命令以便覆盖
    # 后续事务。生产 runtime 仍由下方静态断言确保使用完整降权参数。
    sed -i '/^_run_as_caller() {/,/^}/c\_run_as_caller() { "$@"; }' \
        "$stage/runtime.sh"
    sed \
        -e "s|readonly CG_ROOT=\"/sys/fs/cgroup\"|readonly CG_ROOT=\"$cgroup_root\"|" \
        -e "s|readonly RUNTIME_DIR=\"/run/qemu-vmate-cpu-isolate\"|readonly RUNTIME_DIR=\"$stage/run\"|" \
        -e "s|readonly RUNTIME_LIB=\"/usr/local/libexec/qemu-vmate-cpu-isolate-runtime.sh\"|readonly RUNTIME_LIB=\"$stage/runtime.sh\"|" \
        -e "s|readonly TRUST_MANIFEST=\"/usr/local/libexec/qemu-vmate-cpu-isolate-qemu.conf\"|readonly TRUST_MANIFEST=\"$stage/trust.conf\"|" \
        -e '/^_precheck() {/,/^}/c\_precheck() { return 0; }' \
        "$ISOLATE" > "$stage/helper"
    chmod 0755 "$stage/helper"
    printf '%s\n' "$stage"
}

first_online_cpu() {
    local part online
    online="$(< /sys/devices/system/cpu/online)"
    part="${online%%,*}"; part="${part%%-*}"
    [[ "$part" =~ ^[0-9]+$ ]] || fail "无法选择在线 CPU"
    printf '%s\n' "$part"
}

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
    cpu="$(first_online_cpu)"
    if output="$("$stage/helper" apply "$INSTANCE" 0 \
            "$FAKE_PID" "$cpu" "$FAKE_TID" 0 2>&1)"; then
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
    cpu="$(first_online_cpu)"
    if output="$("$stage/helper" apply "$INSTANCE" 0 \
            "$FAKE_PID" "$cpu" "$FAKE_TID" 0 2>&1)"; then
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
    cpu="$(first_online_cpu)"
    if output="$("$stage/helper" apply "$INSTANCE" 0 \
            "$FAKE_PID" "$cpu" "$FAKE_TID" 0 2>&1)"; then
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
    # 模拟器故意让 helper 认为 PID 已复用，因此它按安全设计不能向该数字 PID 发 CONT；
    # 测试框架确认没有 root attach 后再显式恢复真实 fixture。
    kill -CONT "$FAKE_PID"
}

main() {
    [[ -x "$ISOLATE" && -f "$RUNTIME" && -x "$TRUSTED_SYSTEM_BINARY" ]] \
        || fail "CPU isolate 测试依赖缺失"
    grep -F '_validate_trusted_executable' "$RUNTIME" >/dev/null \
        || fail "runtime 缺少 executable trust"
    grep -F -- '--clear-groups --bounding-set=-all' "$RUNTIME" >/dev/null \
        || fail "生产 runtime 缺少调用者降权边界"
    grep -F "trap '_apply_transaction_exit" "$RUNTIME" >/dev/null \
        || fail "runtime 缺少 apply EXIT 回滚"

    if [[ "${VMATE_CPU_ISO_TEST_USERNS:-0}" != "1" ]]; then
        if ! command -v unshare >/dev/null 2>&1 || ! unshare -Ur true 2>/dev/null; then
            echo "SKIP: 内核禁用 unprivileged user namespace；静态事务断言已通过"
            return 0
        fi
        # 中文注释：fixture 与 helper 必须位于同一个 user namespace；否则某些
        # Yama/ptrace 配置会禁止 namespace-root 读取外部进程的 /proc/PID/exe，
        # 导致测试在 executable trust 之前提前失败。
        exec unshare -Ur env VMATE_CPU_ISO_TEST_USERNS=1 bash "$0" "$@"
    fi
    TMP_DIR="$(mktemp -d)"
    trap cleanup EXIT
    build_fake_qemu
    start_fake_qemu
    test_same_name_executable_is_rejected
    test_taskset_failure_rolls_back
    test_pid_identity_change_blocks_root_attach
    echo "PASS: CPU isolate executable trust、PID 身份防复用与事务故障回滚"
}

main "$@"
