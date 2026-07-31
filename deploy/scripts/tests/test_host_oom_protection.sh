#!/usr/bin/env bash
# 验证 OOM 保护固定策略、目标进程边界、PID generation 与启动器调用契约。
# 测试会按固定文本生成 root helper 副本，并在隔离子 shell 中动态 source 被测模块。
# shellcheck disable=SC1090,SC2016,SC2030,SC2031,SC2329
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PERF="$REPO_ROOT/deploy/scripts/host-performance.sh"
MODULE="$REPO_ROOT/deploy/scripts/lib/sv-host-memory.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

tmp="$(mktemp -d)"
test_lock_fd=""
cleanup() {
    if [[ -n "$test_lock_fd" ]]; then
        flock -u "$test_lock_fd" 2>/dev/null || true
        exec {test_lock_fd}>&-
    fi
    rm -rf -- "$tmp"
}
trap cleanup EXIT

uid="$(id -u)"
pid=424242
instance=987654321
starttime=123456789
proc_root="$tmp/proc"
run_root="$tmp/run-user"
tmp_root="$tmp/locks"
proc_dir="$proc_root/$pid"
work_dir="$tmp/work"
launcher="$work_dir/start-vm.sh"
lock_base="$tmp_root/qemu-stealth-$uid"
lock_dir="$lock_base/qemu-stealth"
lock_file="$lock_dir/instance-$instance.lock"
score_file="$proc_dir/oom_score_adj"
helper="$tmp/qemu-vmate-host-performance"

mkdir -p "$proc_dir/fd" "$work_dir" "$run_root" "$lock_dir"
chmod 0700 "$tmp_root" "$lock_base" "$lock_dir"
printf '%s\n' '#!/usr/bin/env bash' 'sleep 1' >"$launcher"
chmod 0755 "$launcher"
printf '%s\n' 200 >"$score_file"
printf 'Name:\tbash\nUid:\t%s\t%s\t%s\t%s\n' "$uid" "$uid" "$uid" "$uid" \
    >"$proc_dir/status"
printf '%s (bash) S 1 1 1 0 -1 4194304 0 0 0 0 0 0 0 0 20 0 1 0 %s 0 0 0\n' \
    "$pid" "$starttime" >"$proc_dir/stat"
printf '%s\0%s\0%s\0' /usr/bin/bash "$launcher" "$instance" >"$proc_dir/cmdline"
ln -s "$(realpath -e /usr/bin/bash)" "$proc_dir/exe"
ln -s "$work_dir" "$proc_dir/cwd"
ln -s "$launcher" "$proc_dir/fd/255"
printf '\n' >"$lock_file"
ln -s "$lock_file" "$proc_dir/fd/8"

# 测试进程持有与目标 FD8 相同 inode 的独占锁，让副本执行真实 flock 复核。
exec {test_lock_fd}>"$lock_file"
flock -n "$test_lock_fd" || fail "无法建立测试实例锁"

# 仅测试副本替换固定 proc/runtime 根和提权重入；生产文件不接受环境覆盖。
sed \
    -e "s|readonly PROC_ROOT=\"/proc\"|readonly PROC_ROOT=\"$proc_root\"|" \
    -e "s|readonly RUN_USER_ROOT=\"/run/user\"|readonly RUN_USER_ROOT=\"$run_root\"|" \
    -e "s|readonly TMP_ROOT=\"/tmp\"|readonly TMP_ROOT=\"$tmp_root\"|" \
    -e 's/^if \[\[ \$EUID -ne 0 \]\]; then$/if false; then/' \
    "$PERF" >"$helper"
chmod 0755 "$helper"

output="$(SUDO_UID="$uid" "$helper" protect-launcher \
    "$instance" "$pid" "$starttime")" || fail "合法启动器未能建立 OOM 保护"
[[ "$output" == \
    "host-memory-protect: policy=oom-score-v1 score=-500 pid=$pid" ]] \
    || fail "OOM helper 成功协议不稳定: $output"
[[ "$(<"$score_file")" == "-500" ]] || fail "未写入固定 -500 策略"

# 已有更强的管理员策略必须保留，不能为了项目默认值反向提高被杀概率。
printf '%s\n' -700 >"$score_file"
output="$(SUDO_UID="$uid" "$helper" protect-launcher \
    "$instance" "$pid" "$starttime")" || fail "helper 拒绝了已有更强保护"
[[ "$output" == \
    "host-memory-protect: policy=oom-score-v1 score=-700 pid=$pid" ]] \
    || fail "helper 没有报告保留后的真实值"
[[ "$(<"$score_file")" == "-700" ]] || fail "helper 覆盖了更强的管理员策略"

# CLI 支持默认/环境实例号（cmdline 无实例位置参数）以及 flag-first；helper 的
# 实例绑定来自已持有的 FD8 锁，不能把实例号写死在 argv[2]。
printf '%s\0%s\0' /usr/bin/bash "$launcher" >"$proc_dir/cmdline"
printf '%s\n' 200 >"$score_file"
SUDO_UID="$uid" "$helper" protect-launcher \
    "$instance" "$pid" "$starttime" >/dev/null \
    || fail "helper 拒绝了默认/环境 INSTANCE 启动形态"
[[ "$(<"$score_file")" == "-500" ]] || fail "环境 INSTANCE 形态未得到保护"

printf '%s\0%s\0%s\0%s\0' \
    /usr/bin/bash "$launcher" --no-cpu-isolate "$instance" >"$proc_dir/cmdline"
printf '%s\n' 200 >"$score_file"
SUDO_UID="$uid" "$helper" protect-launcher \
    "$instance" "$pid" "$starttime" >/dev/null \
    || fail "helper 拒绝了 flag-first 启动形态"
[[ "$(<"$score_file")" == "-500" ]] || fail "flag-first 形态未得到保护"

assert_rejected_unchanged() {
    local description="$1"
    shift
    printf '%s\n' 200 >"$score_file"
    if SUDO_UID="$uid" "$helper" protect-launcher "$@" >/dev/null 2>&1; then
        fail "$description"
    fi
    [[ "$(<"$score_file")" == "200" ]] || fail "$description 修改了目标分数"
}

assert_rejected_unchanged "helper 接受了错误 starttime" \
    "$instance" "$pid" "$(( starttime + 1 ))"
assert_rejected_unchanged "helper 接受了错误实例锁" \
    "$(( instance + 1 ))" "$pid" "$starttime"
assert_rejected_unchanged "helper 接受了多余的策略参数" \
    "$instance" "$pid" "$starttime" -1000

printf 'Name:\tbash\nUid:\t%s\t%s\t%s\t%s\n' \
    "$(( uid + 1 ))" "$uid" "$uid" "$uid" >"$proc_dir/status"
assert_rejected_unchanged "helper 接受了其它 real UID 的进程" \
    "$instance" "$pid" "$starttime"
printf 'Name:\tbash\nUid:\t%s\t%s\t%s\t%s\n' "$uid" "$uid" "$uid" "$uid" \
    >"$proc_dir/status"

untrusted_launcher="$work_dir/not-start-vm.sh"
printf '%s\n' '#!/usr/bin/env bash' 'sleep 1' >"$untrusted_launcher"
chmod 0755 "$untrusted_launcher"
printf '%s\0%s\0' /usr/bin/bash "$untrusted_launcher" >"$proc_dir/cmdline"
assert_rejected_unchanged "helper 接受了非 start-vm 启动器" \
    "$instance" "$pid" "$starttime"
printf '%s\0%s\0%s\0' /usr/bin/bash "$launcher" "$instance" >"$proc_dir/cmdline"

flock -u "$test_lock_fd"
exec {test_lock_fd}>&-
test_lock_fd=""
assert_rejected_unchanged "helper 接受了未持 flock 的伪启动器" \
    "$instance" "$pid" "$starttime"

# 启动器模块必须把自身 generation 交给 helper，校验返回协议，并允许显式关闭。
fake_helper="$tmp/fake-helper"
fake_bin="$tmp/bin"
helper_log="$tmp/helper.log"
mkdir "$fake_bin"
cat >"$fake_helper" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >"${FAKE_HELPER_LOG:?}"
if [[ "${FAKE_HELPER_PROTOCOL:-ok}" == "bad" ]]; then
    printf 'host-memory-protect: policy=oom-score-v1 score=-500 pid=%s\n' "$3"
    echo "unexpected second protocol line"
    exit 0
fi
[[ "$1" == "protect-launcher" && "$2" =~ ^[1-9][0-9]*$ ]] || exit 9
printf 'host-memory-protect: policy=oom-score-v1 score=-500 pid=%s\n' "$3"
SH
cat >"$fake_bin/sudo" <<'SH'
#!/usr/bin/env bash
[[ "$1" == "-n" && "$2" == "--" ]] || exit 8
shift 2
exec "$@"
SH
chmod 0755 "$fake_helper" "$fake_bin/sudo"

module_output="$(
    export PATH="$fake_bin:$PATH"
    export INSTANCE=9 DRY_RUN=0 HOST_OOM_PROTECT=1
    export SV_HOST_PERF_HELPER="$fake_helper" FAKE_HELPER_LOG="$helper_log"
    _sv_root_helper_is_safe() { return 0; }
    sv_proc_state_starttime() { printf 'S 24680\n'; }
    source "$MODULE"
)" || fail "启动器模块没有接受合法 helper 协议"
[[ "$module_output" == *"oom_score_adj=-500"* ]] \
    || fail "启动器模块没有报告实际保护值"
grep -Eq '^protect-launcher 9 [1-9][0-9]* 24680$' "$helper_log" \
    || fail "启动器模块未传递自身 PID/starttime"

if (
    export PATH="$fake_bin:$PATH"
    export INSTANCE=9 DRY_RUN=0 HOST_OOM_PROTECT=1 FAKE_HELPER_PROTOCOL=bad
    export SV_HOST_PERF_HELPER="$fake_helper" FAKE_HELPER_LOG="$helper_log"
    _sv_root_helper_is_safe() { return 0; }
    sv_proc_state_starttime() { printf 'S 24680\n'; }
    source "$MODULE"
) >/dev/null 2>&1; then
    fail "启动器模块接受了未知 helper 协议"
fi

rm -f "$helper_log"
disabled_output="$(
    export INSTANCE=9 DRY_RUN=0 HOST_OOM_PROTECT=0
    export SV_HOST_PERF_HELPER="$fake_helper" FAKE_HELPER_LOG="$helper_log"
    source "$MODULE"
)" || fail "HOST_OOM_PROTECT=0 未正常返回"
[[ "$disabled_output" == "" && ! -e "$helper_log" ]] \
    || fail "显式关闭 OOM 保护后仍调用了 helper 或污染 stdout"

bash -n "$PERF" "$MODULE"
echo "PASS: host OOM protection"
