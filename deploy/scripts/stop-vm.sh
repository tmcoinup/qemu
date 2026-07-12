#!/bin/bash
# stop-vm.sh  --  shut down a stealth VM instance started by
#                 start-vm.sh.
#
# Strategy: ACPI powerdown (system_powerdown via QMP) → wait up to N seconds
# for the guest to flush + quit → fall back to `quit` (hard kill of QEMU).
# Only SIGTERM/SIGKILL the process as a last resort.
#
# 关机以 QMP 为准 (P0#2)：先看 QMP socket 是否还连得上，而不是先依赖 pgrep。
# 进程名匹配兼容新版 win10-${INSTANCE} 与旧版 win10-ryzen3-${INSTANCE}。
# 找不到 PID 但 QMP 仍有响应时，绝不删 socket 后假装停机成功——那会让
# seal-base/离线挂载误判 VM 已停，造成磁盘一致性风险。
#
# Usage:
#   ./stop-vm.sh           # defaults to instance 1
#   ./stop-vm.sh 1
#   ./stop-vm.sh 2 --hard  # skip ACPI, quit immediately
#   ./stop-vm.sh 1 --wait=120
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# 中文注释：HERE 是运行时解析出的脚本绝对目录，静态检查器无法展开；三个库
# 都由仓库固定路径提供，故仅在对应 source 处抑制动态路径误报。
# shellcheck disable=SC1091
source "$HERE/lib/sv-vlan-preflight.sh"
# shellcheck disable=SC1091
source "$HERE/lib/sv-instance-lock.sh"
# shellcheck disable=SC1091
source "$HERE/lib/sv-swtpm-lifecycle.sh"

INSTANCE=1
HARD=0
WAIT=60
for a in "$@"; do
    case "$a" in
        --hard)          HARD=1 ;;
        --wait=*)        WAIT="${a#--wait=}" ;;
        -h|--help)
            sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            if [[ "$a" =~ ^[0-9]{1,10}$ ]]; then
                INSTANCE="$a"
            else
                echo "unknown arg: $a" >&2
                exit 2
            fi ;;
    esac
done

if (( 10#$INSTANCE < 1 )); then
    echo "INSTANCE 必须是 1..10 位正整数" >&2
    exit 2
fi
if ! [[ "$WAIT" =~ ^[0-9]+$ ]] || (( 10#$WAIT < 1 || 10#$WAIT > 3600 )); then
    echo "--wait 必须是 1..3600 秒的整数" >&2
    exit 2
fi
WAIT=$((10#$WAIT))

QMP="/tmp/qemu-stealth-${INSTANCE}.qmp"
MON="/tmp/qemu-stealth-${INSTANCE}.mon"
FB="/tmp/qemu-stealth-${INSTANCE}.fb"

# 进程名兼容：新版 "win10-${INSTANCE}"（2026-05 改名）与旧版
# "win10-ryzen3-${INSTANCE}"。实例号后要求边界字符 [, ]（-name 后总跟
# ",debug-threads=on" 或后续参数），避免实例 1 误匹配实例 10。
PATTERN="^([^ ]*/)?qemu-system-x86_64 .*-name win10-(ryzen3-)?${INSTANCE}[, ]"

pid_of_vm() {
    # 中文注释：QEMU 可能由 gnome-session-inhibit/systemd-inhibit 包装启动；
    # 包装进程的参数里也包含完整 QEMU 命令。必须锚定真实 QEMU 命令行开头，
    # 否则 QEMU 已崩溃后仍会误杀/等待包装进程，并把 stale QMP 误报成关机失败。
    pgrep -f "$PATTERN" | head -n1
}

# 发一条 QMP 命令：成功打印响应行，连不上则非零退出。
qmp_cmd() {
    local execute="$1"
    python3 - "$QMP" "$execute" <<'PY'
import json, socket, sys, time
sock_path, execute = sys.argv[1], sys.argv[2]
last_error = None
s = None
for _ in range(10):
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(5)
    try:
        s.connect(sock_path)
        break
    except Exception as e:
        last_error = e
        try:
            s.close()
        except Exception:
            pass
        time.sleep(0.2)
else:
    print(f"qmp connect failed: {last_error}", file=sys.stderr); sys.exit(3)
f = s.makefile("rw")
json.loads(f.readline())   # greeting
f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n"); f.flush()
json.loads(f.readline())
f.write(json.dumps({"execute": execute}) + "\n"); f.flush()
print(f.readline().strip())
PY
}

# QMP 是否活着：socket 存在且 query-status 有响应。
qmp_alive() {
    [[ -S "$QMP" ]] || return 1
    qmp_cmd query-status >/dev/null 2>&1
}

# VM 是否还在：有 PID 用 kill -0，无 PID 退回 QMP 探活。
vm_alive() {
    if [[ -n "$PID" ]]; then
        kill -0 "$PID" 2>/dev/null
    else
        qmp_alive
    fi
}

cleanup_control_sockets() {
    rm -f "$QMP" "$MON" "${QMP}.proxy" "$FB" 2>/dev/null || true
}

acquire_instance_cleanup_lock() {
    local lock attempt

    # 旧 QEMU 退出后 watchdog 可能再持锁约一秒；旧版 swtpm 又可能继承同一个
    # open-file-description。此时第一次孤儿检查会因 watchdog 仍存在而保守跳过，
    # 但 watchdog 退出后只剩 swtpm 永久持锁。不能用单次 `flock -w`：等待期间
    # 状态会从“活跃生命周期所有者”转换为“确定孤儿”，必须周期性重新判定。
    #
    # 每轮先短暂打开 FD8 并非阻塞试锁；失败后立即关闭 FD8，再扫描持有者。
    # 若不先关闭，stop 自己会被扫描成非 swtpm 持有者，导致永远无法自愈。
    # 活跃新启动器仍持锁时，扫描会看到它并拒绝杀 swtpm；五秒截止后安全退出，
    # 防止本次旧 VM 收尾误删新启动器创建的 socket/TPM/TAP。
    command -v flock >/dev/null 2>&1 || return 1
    lock="$(sv_instance_lock_path "$INSTANCE")" || return 1
    for ((attempt=0; attempt<25; attempt++)); do
        exec 8>"$lock"
        if flock -n 8; then
            return 0
        fi
        exec 8>&-
        stop_orphan_swtpm_holding_cleanup_lock
        sleep 0.2
    done
    return 1
}

cleanup_vlan_tap() {
    # 无论本次 VM 是否使用 VLAN 都可调用：root helper 只会依据可信状态文件删除
    # 本实例的受管 TAP；没有状态时幂等成功，绝不会按名字删除未知接口。
    if ! sv_vlan_cleanup_instance "$INSTANCE" >/dev/null 2>&1; then
        echo "⚠ 清理实例 ${INSTANCE} 的 VLAN TAP 失败；请检查 root helper 日志" >&2
    fi
}

stop_swtpm_daemon() {
    # 中文注释：swtpm 是独立 daemon，QEMU 异常退出或用户直接关闭窗口时不会自动回收。
    # 它持有本实例 tpm-state 锁会让下一次启动秒退，因此只按 vms/<N>/tpm-state 精确清理。
    local -a swtpm_pids=()

    mapfile -t swtpm_pids < <(sv_swtpm_instance_pids "$INSTANCE")
    if (( ${#swtpm_pids[@]} == 0 )); then
        return 0
    fi
    echo "→ 停止实例 ${INSTANCE} 的 swtpm: ${swtpm_pids[*]}"
    sv_swtpm_stop_pids "$INSTANCE" "${swtpm_pids[@]}"
}

stop_orphan_swtpm_holding_cleanup_lock() {
    local lock
    local -a orphan_pids=()

    lock="$(sv_instance_lock_path "$INSTANCE")" || return 0
    mapfile -t orphan_pids < <(
        sv_swtpm_orphan_lock_holder_pids "$INSTANCE" "$lock"
    )
    (( ${#orphan_pids[@]} > 0 )) || return 0

    echo "→ 回收持实例锁的孤儿 swtpm: ${orphan_pids[*]}"
    sv_swtpm_stop_pids "$INSTANCE" "${orphan_pids[@]}"
}

terminate_pid_if_known() {
    if [[ -n "$PID" ]]; then
        kill "$PID" 2>/dev/null || true
    fi
}

PID="$(pid_of_vm || true)"

if [[ -z "$PID" ]]; then
    # 没匹配到进程：可能真没跑，也可能进程名又变了但 QMP 还在。
    if qmp_alive; then
        echo "⚠ 未匹配到进程名，但 QMP socket 有响应 —— VM 仍在运行，改走 QMP-only 关机"
        # 不删 socket，PID 留空，下面用 QMP 路径关机。
    else
        echo "no vm instance ${INSTANCE} running (pattern: $PATTERN)"
        # 中文注释：旧版启动器可能让 --daemon 的 swtpm 继承 FD 8，导致它在
        # QEMU 已崩溃后独占实例锁。先仅回收“锁的全部持有者都是本实例
        # swtpm”的确定孤儿，再竞争清理锁；若新启动器也持锁，此函数不会杀
        # swtpm，后面的 flock 超时会安全退出并保留新启动资源。
        if ! acquire_instance_cleanup_lock; then
            echo "⚠ 实例 $INSTANCE 正在重新启动；未取得收尾锁，跳过旧资源清理" >&2
            exit 1
        fi
        # 确认 QMP 无响应，才清理 stale socket 和本实例孤儿 swtpm。
        cleanup_control_sockets
        stop_swtpm_daemon
        cleanup_vlan_tap
        exit 0
    fi
else
    echo "instance=${INSTANCE} pid=${PID}"
fi

if [[ "$HARD" -eq 1 ]]; then
    echo "→ hard quit via QMP"
    if [[ -S "$QMP" ]]; then
        qmp_cmd quit >/dev/null || terminate_pid_if_known
    elif [[ -n "$PID" ]]; then
        kill "$PID"
    fi
else
    if [[ ! -S "$QMP" ]]; then
        if [[ -n "$PID" ]]; then
            echo "→ no QMP socket, falling back to SIGTERM"
            kill "$PID"
        else
            echo "→ 无 PID 且无 QMP socket，无法关机" >&2
            exit 1
        fi
    else
        echo "→ ACPI powerdown (system_powerdown), waiting up to ${WAIT}s"
        # QEMU 正在退出或刚重建 socket 时，QMP connect 可能瞬间 ECONNREFUSED。
        # 如果随后进程已经消失，就不要把这类瞬时错误误报给操作者。
        if ! _qmp_err="$(qmp_cmd system_powerdown 2>&1 >/dev/null)"; then
            sleep 1
            vm_alive && echo "$_qmp_err" >&2
        fi
        for ((i=0; i<WAIT; i++)); do
            vm_alive || break
            sleep 1
        done
        if vm_alive; then
            echo "→ guest did not power off within ${WAIT}s, issuing QMP quit"
            qmp_cmd quit >/dev/null || terminate_pid_if_known
        fi
    fi
fi

# 收尾等待 + 强杀（仅当有 PID 时能 SIGKILL）。
if [[ -n "$PID" ]]; then
    for ((i=0; i<10; i++)); do
        kill -0 "$PID" 2>/dev/null || break
        sleep 1
    done
    if kill -0 "$PID" 2>/dev/null; then
        echo "→ still alive, SIGKILL"
        kill -9 "$PID" || true
        sleep 1
    fi
else
    for ((i=0; i<10; i++)); do
        vm_alive || break
        sleep 1
    done
fi

# 仅在确认 VM 已停后清 socket；若仍存活则保留 QMP socket 供重试。
if vm_alive; then
    echo "⚠ VM 仍未停止，保留 QMP socket 供重试，不做清理" >&2
    rm -f "$MON" 2>/dev/null || true
    exit 1
fi

if ! acquire_instance_cleanup_lock; then
    echo "⚠ 实例 $INSTANCE 已在关机后重新启动；跳过 socket/TAP/TPM 清理" >&2
    exit 1
fi

# swtpm daemon 随 VM 收摊（关键：否则孤儿在源头累积）。
# swtpm 是 --daemon，PPID 已脱离 qemu，qemu 退出后它不会自己死，会一直持
# 有 vms/N/tpm-state 的 NVRAM 锁；下次 start 时新 QEMU CMD_INIT 抢不到锁
# 报 "0x9 operation failed" 秒退（详见 memory project_swtpm_orphan_lock，
# start-vm.sh 已有 preflight reaper 兜底，这里在源头清干净，二者对称）。
stop_swtpm_daemon
cleanup_vlan_tap

# 兼容旧版 Python qmp-proxy：新版 --proxy 已改为 QEMU 原生 multi=on，这里仍清理
# 可能残留的旧代理进程和 .qmp.proxy 兼容别名，避免下次启动撞路径。
if pkill -f "qmp-proxy\.py ${INSTANCE}\b" 2>/dev/null; then
    echo "→ legacy qmp-proxy (instance ${INSTANCE}) 已停止"
fi
rm -f "${QMP}.proxy" 2>/dev/null || true

# CPU 亲和隔离收摊: 释放本实例的 cpuset 独占分区 → 专属物理核还给宿主机。
# release 内部会判断分区里是否还有别的在跑 VM, 空了才真正拆分区还核(多 VM 安全)。
# QEMU 已死 → 它的 pid 自动从 cgroup.procs 移除, 所以现在调最干净。失败不阻断。
if [[ -x "$HERE/host-cpu-isolate.sh" ]]; then
    sudo -n "$HERE/host-cpu-isolate.sh" release "$INSTANCE" 2>/dev/null || true
fi

cleanup_control_sockets
echo "instance=${INSTANCE} stopped"
