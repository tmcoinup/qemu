#!/bin/bash
# stop-vm.sh  --  shut down a stealth VM instance started by
#                 start-vm.sh.
#
# Strategy: ACPI powerdown (system_powerdown via QMP) → wait up to N seconds
# for the guest to flush + quit → fall back to `quit` (hard kill of QEMU).
# Only SIGTERM/SIGKILL the process as a last resort.
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
            sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "unknown arg: $a" >&2; exit 2 ;;
    esac
done

QMP="/tmp/qemu-stealth-${INSTANCE}.qmp"
MON="/tmp/qemu-stealth-${INSTANCE}.mon"
PATTERN="qemu-system-x86_64 -name win10-ryzen3-${INSTANCE}"

pid_of_vm() {
    pgrep -f "$PATTERN" | head -n1
}

qmp_cmd() {
    local execute="$1"
    python3 - "$QMP" "$execute" <<'PY'
import json, socket, sys, time
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

PID="$(pid_of_vm || true)"
if [[ -z "$PID" ]]; then
    echo "no vm instance ${INSTANCE} running (pattern: $PATTERN)"
    # still clean up stale sockets if any
    rm -f "$QMP" "$MON" 2>/dev/null || true
    exit 0
fi
echo "instance=${INSTANCE} pid=${PID}"

if [[ "$HARD" -eq 1 ]]; then
    echo "→ hard quit via QMP"
    [[ -S "$QMP" ]] && qmp_cmd quit || kill "$PID"
else
    if [[ ! -S "$QMP" ]]; then
        echo "→ no QMP socket, falling back to SIGTERM"
        kill "$PID"
    else
        echo "→ ACPI powerdown (system_powerdown), waiting up to ${WAIT}s"
        qmp_cmd system_powerdown >/dev/null || true
        for ((i=0; i<WAIT; i++)); do
            if ! kill -0 "$PID" 2>/dev/null; then
                break
            fi
            sleep 1
        done
        if kill -0 "$PID" 2>/dev/null; then
            echo "→ guest did not power off within ${WAIT}s, issuing QMP quit"
            qmp_cmd quit >/dev/null || kill "$PID"
        fi
    fi
fi

for ((i=0; i<10; i++)); do
    kill -0 "$PID" 2>/dev/null || break
    sleep 1
done
if kill -0 "$PID" 2>/dev/null; then
    echo "→ still alive, SIGKILL"
    kill -9 "$PID" || true
    sleep 1
fi

# 热键截图守护进程随 VM 收摊：精确匹配 "hotkey-capture.py <实例号>"
# （避免误杀其他实例），再清掉它的触发 socket。
HOTKEY_SOCK="/tmp/qemu-stealth-${INSTANCE}.hotkey"
if pkill -f "hotkey-capture\.py ${INSTANCE}\b" 2>/dev/null; then
    echo "→ hotkey-capture (instance ${INSTANCE}) 已停止"
fi
rm -f "$QMP" "$MON" "$HOTKEY_SOCK" 2>/dev/null || true
echo "instance=${INSTANCE} stopped"
