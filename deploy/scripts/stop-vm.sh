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

INSTANCE=1
HARD=0
WAIT=60
for a in "$@"; do
    case "$a" in
        --hard)          HARD=1 ;;
        --wait=*)        WAIT="${a#--wait=}" ;;
        [0-9]*)          INSTANCE="$a" ;;
        -h|--help)
            sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "unknown arg: $a" >&2; exit 2 ;;
    esac
done

QMP="/tmp/qemu-stealth-${INSTANCE}.qmp"
MON="/tmp/qemu-stealth-${INSTANCE}.mon"

# 进程名兼容：新版 "win10-${INSTANCE}"（2026-05 改名）与旧版
# "win10-ryzen3-${INSTANCE}"。实例号后要求边界字符 [, ]（-name 后总跟
# ",debug-threads=on" 或后续参数），避免实例 1 误匹配实例 10。
PATTERN="qemu-system-x86_64 .*-name win10-(ryzen3-)?${INSTANCE}[, ]"

pid_of_vm() {
    pgrep -f "$PATTERN" | head -n1
}

# 发一条 QMP 命令：成功打印响应行，连不上则非零退出。
qmp_cmd() {
    local execute="$1"
    python3 - "$QMP" "$execute" <<'PY'
import json, socket, sys
sock_path, execute = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX)
s.settimeout(5)
try:
    s.connect(sock_path)
except Exception as e:
    print(f"qmp connect failed: {e}", file=sys.stderr); sys.exit(3)
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

PID="$(pid_of_vm || true)"

if [[ -z "$PID" ]]; then
    # 没匹配到进程：可能真没跑，也可能进程名又变了但 QMP 还在。
    if qmp_alive; then
        echo "⚠ 未匹配到进程名，但 QMP socket 有响应 —— VM 仍在运行，改走 QMP-only 关机"
        # 不删 socket，PID 留空，下面用 QMP 路径关机。
    else
        echo "no vm instance ${INSTANCE} running (pattern: $PATTERN)"
        # 确认 QMP 无响应，才清理 stale socket。
        rm -f "$QMP" "$MON" 2>/dev/null || true
        exit 0
    fi
else
    echo "instance=${INSTANCE} pid=${PID}"
fi

if [[ "$HARD" -eq 1 ]]; then
    echo "→ hard quit via QMP"
    if [[ -S "$QMP" ]]; then
        qmp_cmd quit >/dev/null || { [[ -n "$PID" ]] && kill "$PID" || true; }
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
        qmp_cmd system_powerdown >/dev/null || true
        for ((i=0; i<WAIT; i++)); do
            vm_alive || break
            sleep 1
        done
        if vm_alive; then
            echo "→ guest did not power off within ${WAIT}s, issuing QMP quit"
            qmp_cmd quit >/dev/null || { [[ -n "$PID" ]] && kill "$PID" || true; }
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

# 热键截图守护进程随 VM 收摊：精确匹配 "hotkey-capture.py <实例号>"
# （避免误杀其他实例），再清掉它的触发 socket。
HOTKEY_SOCK="/tmp/qemu-stealth-${INSTANCE}.hotkey"
if pkill -f "hotkey-capture\.py ${INSTANCE}\b" 2>/dev/null; then
    echo "→ hotkey-capture (instance ${INSTANCE}) 已停止"
fi

# 仅在确认 VM 已停后清 socket；若仍存活则保留 QMP socket 供重试。
if vm_alive; then
    echo "⚠ VM 仍未停止，保留 QMP socket 供重试，不做清理" >&2
    rm -f "$MON" "$HOTKEY_SOCK" 2>/dev/null || true
    exit 1
fi

# swtpm daemon 随 VM 收摊（关键：否则孤儿在源头累积）。
# swtpm 是 --daemon，PPID 已脱离 qemu，qemu 退出后它不会自己死，会一直持
# 有 vms/N/tpm-state 的 NVRAM 锁；下次 start 时新 QEMU CMD_INIT 抢不到锁
# 报 "0x9 operation failed" 秒退（详见 memory project_swtpm_orphan_lock，
# start-vm.sh 已有 preflight reaper 兜底，这里在源头清干净，二者对称）。
# 匹配 swtpm 专属调用形式 + 本实例 tpm-state：vms/N/tpm-state 是唯一串，
# N=1 不会误命中 N=10；"swtpm socket --tpmstate dir=" 前缀只出现在真 swtpm
# daemon，绝不会误匹配恰好含该路径的别的进程。
_swtpm_pat="swtpm socket --tpmstate dir=.*vms/${INSTANCE}/tpm-state"
_swtpm_pids=$(pgrep -f "$_swtpm_pat" 2>/dev/null || true)
if [[ -n "$_swtpm_pids" ]]; then
    echo "→ 停止实例 ${INSTANCE} 的 swtpm: $(echo $_swtpm_pids | tr '\n' ' ')"
    kill $_swtpm_pids 2>/dev/null || true
    for ((i=0; i<5; i++)); do
        pgrep -f "$_swtpm_pat" >/dev/null 2>&1 || break
        sleep 0.2
    done
    pgrep -f "$_swtpm_pat" 2>/dev/null | xargs -r kill -9 2>/dev/null || true
fi

# 兼容旧版 Python qmp-proxy：新版 --proxy 已改为 QEMU 原生 multi=on，这里仍清理
# 可能残留的旧代理进程和 .qmp.proxy 兼容别名，避免下次启动撞路径。
pkill -f "qmp-proxy\.py ${INSTANCE}\b" 2>/dev/null && echo "→ legacy qmp-proxy (instance ${INSTANCE}) 已停止" || true
rm -f "${QMP}.proxy" 2>/dev/null || true

rm -f "$QMP" "$MON" "$HOTKEY_SOCK" 2>/dev/null || true
echo "instance=${INSTANCE} stopped"
