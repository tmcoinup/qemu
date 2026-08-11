#!/usr/bin/env bash
# 严格 CPU 隔离的 ARMED/RUNNING 管道与 paused QEMU session 监督回归。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
WATCHDOG="$REPO_ROOT/deploy/scripts/lib/sv-instance-watchdog.sh"
CPUPIN="$REPO_ROOT/deploy/scripts/lib/sv-cpupin.sh"
DISPLAY_GUARD="$REPO_ROOT/deploy/scripts/lib/sv-display-guard.sh"
GROUP_GUARD="$REPO_ROOT/deploy/scripts/lib/vm-strict-group-guard.py"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/fake-bin"

# stdout 只承载监督协议；stderr/其它行为在生产实现中保持独立。
cat > "$tmp/vm-cpu-pinner.py" <<'PY'
import os
import pathlib
import sys
import time


def option(name: str) -> str:
    index = sys.argv.index(name)
    return sys.argv[index + 1]


mode = os.environ["FAKE_PINNER_MODE"]
if mode == "eof":
    raise SystemExit(7)
print("ARMED", flush=True)
print("ordinary pinner diagnostic", file=sys.stderr, flush=True)
if mode == "delayed-fail":
    time.sleep(0.7)
    print("FAIL qmp 1", flush=True)
    raise SystemExit(1)
if mode == "malformed":
    print("RUNNING invalid identity", flush=True)
    raise SystemExit(1)
if mode not in {"running", "running-subgroup"}:
    raise SystemExit(8)

launcher_pid = int(option("--launcher-pid"))
launcher_start = option("--launcher-starttime")
reported_pid = launcher_pid
reported_start = launcher_start
if mode == "running-subgroup":
    pidfile = pathlib.Path(os.environ["FAKE_GUEST_PIDFILE"])
    for _attempt in range(100):
        if pidfile.exists() and pidfile.read_text().strip():
            break
        time.sleep(0.01)
    reported_pid = int(pidfile.read_text().split()[0])
    stat = pathlib.Path(f"/proc/{reported_pid}/stat").read_text()
    fields = stat.rpartition(")")[2].split()
    reported_start = fields[19]
print(f"RUNNING {reported_pid} {reported_start}", flush=True)
while pathlib.Path(f"/proc/{reported_pid}").exists():
    time.sleep(0.02)
PY

cat > "$tmp/fake-bin/sudo" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_SUDO_LOG"
exit 0
SH

cat > "$tmp/fake-guest" <<'SH'
#!/usr/bin/env bash
exec python3 -c 'import os, pathlib, time; pathlib.Path(os.environ["FAKE_GUEST_PIDFILE"]).write_text(str(os.getpid())); time.sleep(30)'
SH
cat > "$tmp/fake-subgroup-guest" <<'PY'
#!/usr/bin/env python3
import os
import pathlib
import time

os.setpgid(0, 0)
pathlib.Path(os.environ["FAKE_GUEST_PIDFILE"]).write_text(
    f"{os.getpid()} {os.getpgrp()} {os.getsid(0)}\n"
)
time.sleep(float(os.environ.get("FAKE_GUEST_DURATION", "0.4")))
PY
cat > "$tmp/fake-stubborn-group" <<'SH'
#!/usr/bin/env bash
set -m
trap '' HUP INT QUIT TERM
sleep 30 &
descendant=$!
printf '%s %s\n' "$BASHPID" "$descendant" >"$FAKE_STUBBORN_PIDFILE"
wait "$descendant"
SH
chmod 0755 "$tmp/fake-bin/sudo" "$tmp/fake-guest" \
    "$tmp/fake-subgroup-guest" "$tmp/fake-stubborn-group"

export PATH="$tmp/fake-bin:$PATH"
export FAKE_SUDO_LOG="$tmp/sudo.log"
: > "$FAKE_SUDO_LOG"

# source 阶段关闭功能，避免测试触碰真实 helper；随后只调用纯用户态监督函数。
export CPU_ISOLATE=0 STRICT_HARDWARE=1 DRY_RUN=0 HERE="$tmp"
# shellcheck disable=SC1090
source "$WATCHDOG"
# shellcheck disable=SC1090
source "$CPUPIN"
# shellcheck disable=SC1090
source "$DISPLAY_GUARD"

export CPU_ISOLATE=1 INSTANCE=987654321 CPUS=2 CPU_CORES=2 CPU_THREADS=2
export QMP_SOCK="$tmp/qmp.sock" QEMU_SERVICE_CPUS=0
export SV_CPU_ISO_HELPER=/fake/qemu-vmate-cpu-isolate
export SV_STRICT_GROUP_GUARD="$GROUP_GUARD"
exec 8>"$tmp/instance.lock"
flock 8

reset_supervisor() {
    export SV_CPU_PINNER_PID="" SV_CPU_PINNER_START="" SV_CPU_PINNER_ABORT=0
    export SV_DISPLAY_CHILD_PID="" SV_DISPLAY_CHILD_START="" SV_DISPLAY_CHILD_GROUP=0
    export SV_DISPLAY_SIGNAL_STATUS=0 SV_DISPLAY_PENDING_SIGNAL=""
    export SV_DISPLAY_CONTROL_FAILED=0 SV_DISPLAY_XSET_CHANGED=0
    export SV_DISPLAY_GROUP_ADOPTING=0 SV_DISPLAY_GROUP_ADOPTED=0
}

assert_guest_gone() {
    local pid="$1" state
    if [[ -r "/proc/$pid/stat" ]]; then
        read -r state _ < <(sv_proc_state_starttime "$pid") || return 0
        [[ "$state" =~ ^[XxZz]$ ]] || fail "暂停态 guest 仍存活: pid=$pid state=$state"
    fi
}

assert_generation_live() {
    local pid="$1" start="$2"
    sv_proc_generation_is_live "$pid" "$start" \
        || fail "期望存活的进程代际已消失: pid=$pid start=$start"
}

reset_supervisor
export FAKE_PINNER_MODE=running
sv_display_wait_and_restore sleep 0.2 \
    || fail "合法 ARMED→RUNNING 握手没有进入正常等待/收尾"

# Ubuntu 24.04 的 GNOME/systemd inhibit 会在 guard session 内新建 PGID；该合法
# 子组仍应通过严格所有权校验，不能因 wrapper 的实现细节把 paused guest 误杀。
reset_supervisor
export FAKE_PINNER_MODE=running-subgroup
export FAKE_GUEST_PIDFILE="$tmp/guest-running-subgroup.pid"
export FAKE_GUEST_DURATION=0.4
sv_display_wait_and_restore "$tmp/fake-subgroup-guest" \
    || fail "同 session 的内层 PGID 未通过 RUNNING 握手"
read -r subgroup_pid subgroup_pgid subgroup_sid <"$FAKE_GUEST_PIDFILE"
[[ "$subgroup_pgid" == "$subgroup_pid" && "$subgroup_sid" != "$subgroup_pid" ]] \
    || fail "nested PGID fixture 未建立独立子组"

# 握手失败时必须按 session 清掉内层 PGID；旧的 killpg(guard) 会漏掉这里的 guest。
reset_supervisor
export FAKE_PINNER_MODE=delayed-fail
export FAKE_GUEST_PIDFILE="$tmp/guest-failed-subgroup.pid"
export FAKE_GUEST_DURATION=30
if sv_display_wait_and_restore "$tmp/fake-subgroup-guest"; then
    fail "内层 PGID 的握手失败未使严格启动失败"
fi
read -r failed_subgroup_pid failed_subgroup_pgid failed_subgroup_sid \
    <"$FAKE_GUEST_PIDFILE"
[[ "$failed_subgroup_pgid" == "$failed_subgroup_pid" \
   && "$failed_subgroup_sid" != "$failed_subgroup_pid" ]] \
    || fail "失败清理 fixture 未建立独立子组"
assert_guest_gone "$failed_subgroup_pid"

for mode in delayed-fail eof malformed; do
    reset_supervisor
    export FAKE_PINNER_MODE="$mode"
    export FAKE_GUEST_PIDFILE="$tmp/guest-$mode.pid"
    if sv_display_wait_and_restore "$tmp/fake-guest"; then
        fail "$mode 协议错误没有使严格启动失败"
    fi
    [[ -s "$FAKE_GUEST_PIDFILE" ]] || fail "$mode fixture 没有启动 guest 进程组"
    assert_guest_gone "$(<"$FAKE_GUEST_PIDFILE")"
done

# 组长先退出也不能让同 PGID 的 paused 后代逃过失败清理。
reset_supervisor
export FAKE_PINNER_MODE=delayed-fail
descendant_pidfile="$tmp/descendant.pid"
# shellcheck disable=SC2016  # $!/$1 必须由内层 bash 展开。
if sv_display_wait_and_restore bash -c \
        'sleep 30 & printf "%s\n" "$!" > "$1"; sleep 0.2' _ "$descendant_pidfile"; then
    fail "组长退出后的 paused 后代没有使严格启动失败"
fi
[[ -s "$descendant_pidfile" ]] || fail "未创建组长先退 fixture"
assert_guest_gone "$(<"$descendant_pidfile")"

# 直接 SIGKILL session leader；sentinel 必须跨内层 PGID 清掉忽略 TERM 的后代。
export FAKE_STUBBORN_PIDFILE="$tmp/stubborn-group.pids"
outer_pid="$BASHPID"
read -r _outer_state outer_start < <(sv_proc_state_starttime "$outer_pid") \
    || fail "无法绑定 sentinel fixture 父代"
"$GROUP_GUARD" run "$outer_pid" "$outer_start" -- "$tmp/fake-stubborn-group" &
leader_pid=$!
leader_start=""
leader_pgid=""
for _ in $(seq 1 100); do
    read -r _leader_state leader_start leader_pgid \
        < <(sv_proc_state_starttime_pgid "$leader_pid") 2>/dev/null || true
    [[ "$leader_pgid" == "$leader_pid" && -s "$FAKE_STUBBORN_PIDFILE" ]] && break
    sleep 0.02
done
[[ -s "$FAKE_STUBBORN_PIDFILE" ]] || fail "未建立 PGID leader SIGKILL fixture"
read -r stubborn_pid stubborn_descendant <"$FAKE_STUBBORN_PIDFILE"
read -r _stubborn_state stubborn_start \
    < <(sv_proc_state_starttime "$stubborn_pid") || fail "无法绑定 stubborn command"
read -r _descendant_state stubborn_descendant_start \
    < <(sv_proc_state_starttime "$stubborn_descendant") || fail "无法绑定 stubborn descendant"
"$GROUP_GUARD" signal "$leader_pid" "$leader_start" KILL \
    || fail "无法 SIGKILL strict PGID leader"
wait "$leader_pid" 2>/dev/null || true
for _ in $(seq 1 100); do
    if ! sv_proc_generation_is_live "$stubborn_pid" "$stubborn_start" \
        && ! sv_proc_generation_is_live \
            "$stubborn_descendant" "$stubborn_descendant_start"; then
        break
    fi
    sleep 0.02
done
if sv_proc_generation_is_live "$stubborn_pid" "$stubborn_start" \
    || sv_proc_generation_is_live "$stubborn_descendant" "$stubborn_descendant_start"; then
    kill -KILL -- "-$leader_pid" 2>/dev/null || true
    fail "sentinel 未清理 leader SIGKILL 后的 session"
fi

# 错误的 pinner starttime 不得向复用后的数值 PID 发信号或 wait。
sleep 30 &
unrelated_pid=$!
read -r _unrelated_state unrelated_start \
    < <(sv_proc_state_starttime "$unrelated_pid") || fail "无法建立 stale PID fixture"
SV_CPU_PINNER_PID="$unrelated_pid"
SV_CPU_PINNER_START="$((10#$unrelated_start + 1))"
SV_CPU_PINNER_ABORT=1
sv_cpu_isolate_finish || fail "stale pinner 代际的幂等 release 失败"
assert_generation_live "$unrelated_pid" "$unrelated_start"
"$GROUP_GUARD" signal "$unrelated_pid" "$unrelated_start" TERM \
    || fail "无法清理 stale PID fixture"
wait "$unrelated_pid" 2>/dev/null || true

# QEMU session 建立后、pinner 尚未启动时父 shell 遭 SIGKILL，guard 必须独立清理。
parent_pidfile="$tmp/killed-parent.pid"
export FAKE_GUEST_PIDFILE="$tmp/guest-parent-kill.pid"
(
    reset_supervisor
    # shellcheck disable=SC2329  # display guard 在该隔离 subshell 内按名称调用覆盖函数。
    sv_cpu_isolate_supervise() { sleep 30; }
    printf '%s\n' "$BASHPID" >"$parent_pidfile"
    sv_display_wait_and_restore "$tmp/fake-guest"
) >"$tmp/parent-kill.out" 2>&1 &
killed_parent=$!
for _ in $(seq 1 100); do
    [[ -s "$FAKE_GUEST_PIDFILE" && -s "$parent_pidfile" ]] && break
    sleep 0.02
done
[[ -s "$FAKE_GUEST_PIDFILE" ]] || fail "父代 SIGKILL fixture 未启动 guest"
parent_kill_guest="$(<"$FAKE_GUEST_PIDFILE")"
read -r _parent_kill_state parent_kill_start \
    < <(sv_proc_state_starttime "$parent_kill_guest") \
    || fail "无法绑定父代 SIGKILL guest 代际"
kill -KILL "$killed_parent"
wait "$killed_parent" 2>/dev/null || true
for _ in $(seq 1 100); do
    sv_proc_generation_is_live "$parent_kill_guest" "$parent_kill_start" || break
    sleep 0.02
done
sv_proc_generation_is_live "$parent_kill_guest" "$parent_kill_start" \
    && fail "父 shell SIGKILL 后 strict group guard 未清理 paused guest"

# RUNNING 已由父 shell 接收并完成 adopt 后，父 shell SIGKILL 不应误杀已隔离 guest。
reset_supervisor
export FAKE_PINNER_MODE=running
export FAKE_GUEST_PIDFILE="$tmp/guest-adopted-parent-kill.pid"
adopted_log="$tmp/adopted-parent-kill.out"
(
    reset_supervisor
    sv_display_wait_and_restore "$tmp/fake-guest"
) >"$adopted_log" 2>&1 &
adopted_parent=$!
for _ in $(seq 1 150); do
    if [[ -s "$FAKE_GUEST_PIDFILE" ]] \
        && grep -F "RUNNING 已确认" "$adopted_log" >/dev/null 2>&1; then
        break
    fi
    sleep 0.02
done
[[ -s "$FAKE_GUEST_PIDFILE" ]] || fail "RUNNING adopt fixture 未启动 guest"
sleep 0.3
adopted_guest="$(<"$FAKE_GUEST_PIDFILE")"
read -r _adopted_state adopted_start adopted_guard \
    < <(sv_proc_state_starttime_pgid "$adopted_guest") \
    || fail "无法绑定已 adopt guest"
read -r _adopted_guard_state adopted_guard_start \
    < <(sv_proc_state_starttime "$adopted_guard") \
    || fail "无法绑定已 adopt group guard"
kill -KILL "$adopted_parent"
wait "$adopted_parent" 2>/dev/null || true
sleep 0.2
assert_generation_live "$adopted_guest" "$adopted_start"
assert_generation_live "$adopted_guard" "$adopted_guard_start"
"$GROUP_GUARD" signal "$adopted_guard" "$adopted_guard_start" TERM \
    || fail "无法清理已 adopt guest fixture"
for _ in $(seq 1 100); do
    sv_proc_generation_is_live "$adopted_guest" "$adopted_start" || break
    sleep 0.02
done
sv_proc_generation_is_live "$adopted_guest" "$adopted_start" \
    && fail "已 adopt guest 的测试清理失败"

# pinner 若异常消失，最后持有实例锁的 watchdog 仍须先 release CPU 再放锁。
watchdog_lock="$tmp/watchdog-instance.lock"
watchdog_sudo_log="$tmp/watchdog-sudo.log"
: >"$watchdog_sudo_log"
(
    export FAKE_SUDO_LOG="$watchdog_sudo_log"
    exec 8>"$watchdog_lock"
    flock -n 8 || exit 91
    # shellcheck disable=SC2034  # 由 source 进来的 watchdog 按变量名读取。
    SV_INSTANCE_LOCKED=1
    # shellcheck disable=SC2034
    SV_INSTANCE_LOCK="$watchdog_lock"
    CPU_ISOLATE=1
    STRICT_HARDWARE=1
    INSTANCE=987654322
    SV_CPU_ISO_HELPER=/fake/qemu-vmate-cpu-isolate
    # shellcheck disable=SC2034
    SV_VLAN_PREPARED=0
    sv_instance_watchdog_launch
    ( sleep 0.4 ) &
) &
watchdog_parent=$!
wait "$watchdog_parent"
sleep 0.15
[[ ! -s "$watchdog_sudo_log" ]] || fail "watchdog 在 VM 链持锁时过早 release CPU"
for _ in $(seq 1 100); do
    [[ -s "$watchdog_sudo_log" ]] && break
    sleep 0.02
done
grep -Fx -- "-n /fake/qemu-vmate-cpu-isolate release 987654322" \
    "$watchdog_sudo_log" >/dev/null || fail "watchdog 未执行 CPU release 兜底"
exec 9>"$watchdog_lock"
for _ in $(seq 1 100); do
    flock -n 9 && break
    sleep 0.02
done
flock -n 9 || fail "watchdog release 后未释放实例锁"
exec 9>&-

[[ "$(wc -l < "$FAKE_SUDO_LOG")" == "8" ]] \
    || fail "每条严格监督路径都必须执行一次幂等 release"
bash -n "$CPUPIN" "$DISPLAY_GUARD" "$WATCHDOG" "$0"
echo "PASS: strict CPU pinner ARMED/RUNNING session supervision"
