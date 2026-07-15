#!/usr/bin/env bash
# Read-only boot timeline for NVIDIA mdev guests.  It correlates the stable
# per-VM mdev UUID with nvidia-vgpu-mgr journal events; no guest agent, IP or
# modification of the running VM is required.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM_ID=${1:-}
if [[ ! "$VM_ID" =~ ^[1-9][0-9]*$ || $# -ne 1 ]]; then
    echo "usage: $0 <vm_id>" >&2
    exit 2
fi

# shellcheck source=lib/vm-storage.sh
source "$here/lib/vm-storage.sh"
VM_ROOT=${VM_ROOT:-${IMAGE_ROOT:-/home/ubuntu/images}/vms}
vm_storage_init
CONF=$(vm_storage_config_path "$VM_ID")
[[ -r "$CONF" ]] || {
    echo "VM config 不存在或不可读: $CONF" >&2
    exit 1
}
# shellcheck source=/dev/null
source "$CONF"
[[ "${VM_UUID:-}" =~ ^[0-9A-Fa-f-]{36}$ ]] || {
    echo "VM_UUID 缺失或非法: ${VM_UUID:-<missing>}" >&2
    exit 1
}
command -v journalctl >/dev/null 2>&1 || {
    echo "缺少 journalctl" >&2
    exit 1
}
command -v python3 >/dev/null 2>&1 || {
    echo "缺少 python3" >&2
    exit 1
}

printf 'vm%s target=%s / %s / PCI %s:%s SUBSYS %s:%s\n' \
    "$VM_ID" "${GPU_PROFILE:-unknown}" "${GPU_NAME:-unknown}" \
    "${GPU_PCI_VID:-?}" "${GPU_PCI_DID:-?}" \
    "${GPU_SUB_VID:-?}" "${GPU_SUB_DID:-?}"
if [[ "${SPOOF_MODE:-B}" == A &&
      "${GPU_PROFILE:-}" == gtx1050_2gb &&
      "${GPU_NAME:-}" == 'NVIDIA GeForce GTX 1050' &&
      "${GPU_PCI_VID:-}" == 0x10DE && "${GPU_PCI_DID:-}" == 0x1C81 &&
      "${GPU_SUB_VID:-}" == 0x1028 && "${GPU_SUB_DID:-}" == 0x11C0 &&
      "${VGPU_MDEV_INTERNAL_PCI_IDENTITY:-0}" == 1 &&
      "${VGPU_MDEV_FRL_ENABLED:-}" == 0 &&
      "${VGPU_PATCHED_DRIVER_VERSION:-}" == 31.0.15.3833 ]]; then
    echo 'identity-contract=strict GTX1050; license-event is optional; expect host Unlicensed + Frame Rate Limit N/A'
else
    echo "identity-contract=${SPOOF_MODE:-B}; B/off should still produce a Licensed event when DLS is healthy"
fi

python3 - "$VM_ID" "$VM_UUID" \
    3< <(journalctl -b -u nvidia-vgpu-mgr.service --no-pager -o json) <<'PY'
import datetime as dt
import json
import os
import re
import sys

vm_id, target_uuid = sys.argv[1], sys.argv[2].lower()
sessions = []
active_by_pid = {}
boot_id = ""

for raw in os.fdopen(3):
    try:
        event = json.loads(raw)
        message = str(event.get("MESSAGE", ""))
        timestamp = int(event["__REALTIME_TIMESTAMP"]) / 1_000_000
    except (KeyError, TypeError, ValueError, json.JSONDecodeError):
        continue

    boot_id = boot_id or str(event.get("_BOOT_ID", ""))
    pid = str(event.get("_PID", event.get("SYSLOG_PID", "")))
    lower = message.lower()
    if "received start call" in lower and target_uuid in lower:
        session = {
            "pid": pid,
            "start": timestamp,
            "display": None,
            "drivers": [],
            "licensed": None,
            "stop": None,
        }
        sessions.append(session)
        active_by_pid[pid] = session
        continue

    session = active_by_pid.get(pid)
    if session is None:
        continue
    if "display_init" in lower and "successful" in lower:
        session["display"] = session["display"] or timestamp
    elif "guest nvidia driver information" in lower:
        session["drivers"].append(timestamp)
    elif re.search(r"vgpu license state:\s*licensed\b", message, re.I):
        session["licensed"] = session["licensed"] or timestamp
    elif "received stop call" in lower:
        session["stop"] = timestamp


def clock(value):
    if value is None:
        return "-"
    return dt.datetime.fromtimestamp(value).astimezone().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]


def elapsed(session, value):
    if value is None:
        return "-"
    return f"+{value - session['start']:.3f}s"


print(f"vm{vm_id} mdev={target_uuid}")
if boot_id:
    print(f"host boot={boot_id}")
if not sessions:
    print("本次 host boot 的 nvidia-vgpu-mgr journal 中没有该 VM 启动记录。")
    raise SystemExit(0)

print("#  QEMU/vGPU start          display_init  guest driver event(s)       licensed-event stop")
for index, session in enumerate(sessions, 1):
    drivers = "/".join(elapsed(session, value) for value in session["drivers"]) or "-"
    print(
        f"{index:<2} {clock(session['start']):<24} "
        f"{elapsed(session, session['display']):<13} "
        f"{drivers:<27} "
        f"{elapsed(session, session['licensed']):<12} "
        f"{elapsed(session, session['stop'])}"
    )

reloads = [i for i, session in enumerate(sessions, 1) if len(session["drivers"]) > 1]
if reloads:
    print("提示：第 " + ", ".join(map(str, reloads)) + " 次启动出现多次 guest driver handshake，"
          "延迟发生在 OVMF 和首次驱动加载之后。")
PY
