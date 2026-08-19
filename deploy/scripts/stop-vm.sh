#!/usr/bin/env bash
# stop-vm.sh — NVIDIA mdev/vGPU VM 停止脚本
#
# 规范用法: ./deploy/scripts/stop-vm.sh <vm_id> [--vms-dir ABS|--vm-dir ABS|--instances-dir ABS] [--force|--graceful-only]
#
#   ./deploy/scripts/stop-vm.sh 2             优雅关机 (QMP system_powerdown，WinRM 冗余)
#   ./deploy/scripts/stop-vm.sh 2 --force     guest 不响应时强杀：SIGTERM→SIGKILL→清 run/mdev/swtpm
#
# 兼容 Ctrl+C：用户在 stop-vm.sh 等 QEMU 退出那几十秒里按 Ctrl+C，脚本会退出
# 但 VM 不会被意外杀掉 —— 再次运行规范 stop 入口继续关即可。
#
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$here"

VM_ID=${VM_ID:-1}
GUEST_IP_HINT=${GUEST_IP:-}
GUEST_USER=${GUEST_USER:-Administrator}
GUEST_PASS=${GUEST_PASS:-}
FORCE=0
GRACEFUL_ONLY=0
SUDO_PW=${SUDO_PASSWORD:-}
# shellcheck source=lib/vm-storage.sh
source "$here/lib/vm-storage.sh"
# shellcheck source=lib/vlan-runtime.sh
source "$here/lib/vlan-runtime.sh"
# shellcheck source=lib/dgame-endpoints.sh
source "$here/lib/dgame-endpoints.sh"
STORAGE_SELECTION_EXPLICIT=0
if [[ -v VM_INSTANCE_DIR || -v VM_INSTANCES_DIR || -v VM_ROOT || -v VMS_DIR ]]; then
    STORAGE_SELECTION_EXPLICIT=1
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)     FORCE=1; shift ;;
        --graceful-only) GRACEFUL_ONLY=1; shift ;;
        --vms-dir)
            [[ $# -ge 2 ]] || { echo "--vms-dir 需要一个绝对路径" >&2; exit 2; }
            [[ -z "${VMS_DIR_CLI:-}" ]] || { echo "--vms-dir 只能指定一次" >&2; exit 2; }
            VMS_DIR_CLI=$2
            STORAGE_SELECTION_EXPLICIT=1
            shift 2
            ;;
        --vms-dir=*)
            [[ -z "${VMS_DIR_CLI:-}" ]] || { echo "--vms-dir 只能指定一次" >&2; exit 2; }
            VMS_DIR_CLI=${1#*=}
            [[ -n "$VMS_DIR_CLI" ]] || { echo "--vms-dir 需要一个绝对路径" >&2; exit 2; }
            STORAGE_SELECTION_EXPLICIT=1
            shift
            ;;
        --vm-dir)
            [[ $# -ge 2 ]] || { echo "--vm-dir 需要一个绝对路径" >&2; exit 2; }
            [[ -z "${VM_DIR_CLI:-}" ]] || { echo "--vm-dir 只能指定一次" >&2; exit 2; }
            VM_DIR_CLI=$2
            STORAGE_SELECTION_EXPLICIT=1
            shift 2
            ;;
        --vm-dir=*)
            [[ -z "${VM_DIR_CLI:-}" ]] || { echo "--vm-dir 只能指定一次" >&2; exit 2; }
            VM_DIR_CLI=${1#*=}
            [[ -n "$VM_DIR_CLI" ]] || { echo "--vm-dir 需要一个绝对路径" >&2; exit 2; }
            STORAGE_SELECTION_EXPLICIT=1
            shift
            ;;
        --instances-dir)
            [[ $# -ge 2 ]] || { echo "--instances-dir 需要一个绝对路径" >&2; exit 2; }
            [[ -z "${INSTANCES_DIR_CLI:-}" ]] || { echo "--instances-dir 只能指定一次" >&2; exit 2; }
            INSTANCES_DIR_CLI=$2
            STORAGE_SELECTION_EXPLICIT=1
            shift 2
            ;;
        --instances-dir=*)
            [[ -z "${INSTANCES_DIR_CLI:-}" ]] || { echo "--instances-dir 只能指定一次" >&2; exit 2; }
            INSTANCES_DIR_CLI=${1#*=}
            [[ -n "$INSTANCES_DIR_CLI" ]] || { echo "--instances-dir 需要一个绝对路径" >&2; exit 2; }
            STORAGE_SELECTION_EXPLICIT=1
            shift
            ;;
        -h|--help)   sed -n '3,10p' "$here/scripts/stop-vm.sh"; exit 0 ;;
        [0-9]*)      VM_ID="$1"; shift ;;       # bare number → vm id
        *) echo "unknown arg: $1"; exit 2 ;;
    esac
done

if (( FORCE && GRACEFUL_ONLY )); then
    echo "--force 与 --graceful-only 不能同时使用" >&2
    exit 2
fi

if ! vm_storage_id_is_supported "$VM_ID"; then
    echo "VM_ID 必须是正整数: $VM_ID" >&2
    exit 2
fi
STORAGE_SELECTOR_COUNT=0
[[ -z "${VMS_DIR_CLI:-}" ]] || STORAGE_SELECTOR_COUNT=$((STORAGE_SELECTOR_COUNT + 1))
[[ -z "${VM_DIR_CLI:-}" ]] || STORAGE_SELECTOR_COUNT=$((STORAGE_SELECTOR_COUNT + 1))
[[ -z "${INSTANCES_DIR_CLI:-}" ]] || STORAGE_SELECTOR_COUNT=$((STORAGE_SELECTOR_COUNT + 1))
if (( STORAGE_SELECTOR_COUNT > 1 )); then
    echo "--vms-dir、--vm-dir 与 --instances-dir 只能选择一个" >&2
    exit 2
elif [[ -n "${VMS_DIR_CLI:-}" ]]; then
    vm_storage_select_root "$VMS_DIR_CLI"
elif [[ -n "${VM_DIR_CLI:-}" ]]; then
    vm_storage_select_instance_dir "$VM_ID" "$VM_DIR_CLI"
elif [[ -n "${INSTANCES_DIR_CLI:-}" ]]; then
    vm_storage_select_instances_dir "$INSTANCES_DIR_CLI"
elif [[ -n "${VM_INSTANCE_DIR:-}" ]]; then
    vm_storage_select_instance_dir "$VM_ID" "$VM_INSTANCE_DIR"
elif [[ -n "${VM_INSTANCES_DIR:-}" ]]; then
    vm_storage_select_instances_dir "$VM_INSTANCES_DIR"
fi
vm_storage_init

# During the one-time namespace migration, ID-only stop must still find an
# already-running pre-namespace G-11 bundle.  Start never does this fallback.
if (( ! STORAGE_SELECTION_EXPLICIT )); then
    SELECTED_VM_DIR=$(vm_storage_instance_dir "$VM_ID")
    if [[ ! -e "$SELECTED_VM_DIR/vm.conf" ]]; then
        for LEGACY_VM_DIR in \
            "$(vm_storage_g11_namespace_instance_dir "$VM_ID")" \
            "$(vm_storage_pre_namespace_instance_dir "$VM_ID")"; do
            if [[ -e "$LEGACY_VM_DIR/vm.conf" ||
                  -e "$LEGACY_VM_DIR/disk.qcow2" ||
                  -e "$LEGACY_VM_DIR/nvram.fd" ||
                  -e "$LEGACY_VM_DIR/tpm" ]]; then
                vm_storage_select_legacy_instance_dir "$VM_ID" "$LEGACY_VM_DIR"
                vm_storage_init
                echo "[down] 使用待迁移的旧 G-11 bundle: $LEGACY_VM_DIR"
                break
            fi
        done
    fi
fi

# Stop/delete hold the global lock in shared mode to block layout migration.
# Delete separately locks the exact per-VM generation before atomic removal.
vm_storage_validate_root_path "$VM_ROOT" "VM root"
mkdir -p -- "$VM_RUN_DIR"
exec {STORAGE_LOCK_FD}>"$VM_RUN_DIR/.storage.lock"
flock -s "$STORAGE_LOCK_FD"

# A VM configuration describes guest hardware only.  Freeze every selected
# host storage path before any helper reads VM metadata.
readonly IMAGE_ROOT ISO_DIR STAGE_DIR VM_ROOT VMS_DIR VM_INSTANCES_DIR \
    VM_INSTANCE_DIR VM_INSTANCE_ID VM_STORAGE_COMPAT_FALLBACK \
    VM_SHARED_DIR VM_CONFIG_DIR VM_DISK_DIR VM_BASE_DIR VM_NVRAM_DIR \
    VM_CONTROL_DIR VM_RUN_DIR VM_LOG_DIR VM_ASSET_DIR \
    VM_DISK_ARCHIVE_DIR VM_BASE_ARCHIVE_DIR VM_NVRAM_BACKUP_DIR

# shellcheck source=lib/vm-tpm.sh
source "$here/lib/vm-tpm.sh"
# shellcheck source=lib/cpu-isolation.sh
source "$here/lib/cpu-isolation.sh"
# shellcheck source=lib/vgpu-mdev.sh
source "$here/lib/vgpu-mdev.sh"

vm_storage_validate_instance_tree "$VM_ID"

PID_FILE=$(vm_storage_run_path "$VM_ID" pid)
QMP_FILE=$(vm_storage_run_path "$VM_ID" qmp)
QMP_PROXY_FILE="${QMP_FILE}.proxy"
MON_FILE=$(vm_storage_run_path "$VM_ID" mon)
MDEV_FILE=$(vm_storage_run_path "$VM_ID" mdev)
CPU_ISOLATION_STATE_FILE="$(dirname "$QMP_FILE")/cpu-isolation.state"
STREAM_HELPER="$here/fb-shm-stream.sh"
STREAM_PID_FILE="$(dirname "$QMP_FILE")/fb-shm-stream.pid"
STREAM_STATE_PREFIX="$(dirname "$QMP_FILE")/fb-shm-stream"
DGAME_PREVIEW_SOCKET=$(dgame_preview_socket_path "$(dirname "$QMP_FILE")")
DGAME_QMP_COMPAT=$(dgame_endpoint_path "$VM_ID" qmp)
DGAME_QMP_PROXY_COMPAT=$(dgame_endpoint_path "$VM_ID" qmp.proxy)
DGAME_FB_COMPAT=$(dgame_endpoint_path "$VM_ID" fb)
DGAME_MON_COMPAT=$(dgame_endpoint_path "$VM_ID" mon)
G11_VLAN_RUNTIME_MARKER="$(g11_vlan_marker_path "$VM_ID")"
MDEV_UUID=""
VM_PATTERN="qemu-system-x86_64.*-name[[:space:]]+vm${VM_ID}([,[:space:]]|$)"

vm_is_running() {
    pgrep -f "$VM_PATTERN" >/dev/null 2>&1
}

CLEANUP_START_LOCK_ACQUIRED=0
cleanup_start_lock_acquire() {
    local expected_lock inherited_fd expected_inode inherited_inode legacy_qmp

    (( CLEANUP_START_LOCK_ACQUIRED == 0 )) || return 0
    legacy_qmp="$(vm_storage_run_legacy_path "$VM_ID" qmp)"
    if [[ "$QMP_FILE" == "$legacy_qmp" ]]; then
        expected_lock="$(vm_storage_run_legacy_path "$VM_ID" start.lock)"
    else
        expected_lock="$(vm_storage_run_preferred_path "$VM_ID" start.lock)"
    fi
    if [[ "${VM_START_LOCK_HELD:-0}" == 1 ]]; then
        inherited_fd=${VM_START_LOCK_FD:-}
        [[ "$inherited_fd" =~ ^[0-9]+$ && -e "/proc/self/fd/$inherited_fd" ]] || {
            echo "[down] VM_START_LOCK_HELD 缺少可验证的继承锁 FD" >&2
            return 1
        }
        expected_inode="$(stat -Lc '%d:%i' -- "$expected_lock" 2>/dev/null)" || return 1
        inherited_inode="$(stat -Lc '%d:%i' -- "/proc/self/fd/$inherited_fd" 2>/dev/null)" || return 1
        [[ "$expected_inode" == "$inherited_inode" ]] || {
            echo "[down] 继承的 start lock 与 vm${VM_ID} 不匹配" >&2
            return 1
        }
        flock -n "$inherited_fd" || {
            echo "[down] 无法验证继承的 vm${VM_ID} start lock" >&2
            return 1
        }
    else
        if ! exec {STOP_START_LOCK_FD}>"$expected_lock"; then
            echo "[down] 无法打开 vm${VM_ID} cleanup lock: $expected_lock" >&2
            return 1
        fi
        flock -w 15 "$STOP_START_LOCK_FD" || {
            echo "[down] vm${VM_ID} start lock 仍被占用；保留 runtime，稍后重试" >&2
            return 1
        }
    fi
    if vm_is_running; then
        echo "[down] 取得 cleanup lock 后发现 vm${VM_ID} 已重新启动；拒绝清理" >&2
        return 1
    fi
    CLEANUP_START_LOCK_ACQUIRED=1
}

cleanup_vlan_runtime() {
    local marker_status tap known=0

    if g11_vlan_marker_status "$G11_VLAN_RUNTIME_MARKER"; then
        marker_status=0
        known=1
    else
        marker_status=$?
    fi
    if (( marker_status == 2 )); then
        echo "[down] VLAN runtime marker 类型不安全: $G11_VLAN_RUNTIME_MARKER" >&2
        return 1
    fi
    tap="$(vlan_tap_name "$VM_ID")" || return 1
    if (( known == 0 )) && ! ip link show dev "$tap" >/dev/null 2>&1; then
        return 0
    fi
    g11_vlan_cleanup_instance "$VM_ID" "$known" || return 1
    g11_vlan_marker_clear "$G11_VLAN_RUNTIME_MARKER"
}

qmp_system_powerdown() {
    [[ -S "$QMP_FILE" ]] || return 1
    python3 - "$QMP_FILE" <<'PY'
import json
import socket
import sys

path = sys.argv[1]
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(3)
sock.connect(path)
stream = sock.makefile("rwb", buffering=0)

def recv_reply():
    while True:
        line = stream.readline()
        if not line:
            raise RuntimeError("QMP closed the connection")
        obj = json.loads(line)
        if "return" in obj:
            return
        if "error" in obj:
            raise RuntimeError(obj["error"].get("desc", "QMP error"))

# Consume the greeting, negotiate capabilities, then ask ACPI to power down.
while True:
    greeting = json.loads(stream.readline())
    if "QMP" in greeting:
        break
stream.write(b'{"execute":"qmp_capabilities"}\r\n')
recv_reply()
stream.write(b'{"execute":"system_powerdown"}\r\n')
recv_reply()
PY
}

remember_vm_mdev() {
    local pid arg

    # 活动 QEMU 的真实 argv 优先于可能残留的 vmN.mdev 记录。
    pid=$(pgrep -f "$VM_PATTERN" | head -1 || true)
    if [[ -n "$pid" && -r "/proc/$pid/cmdline" ]]; then
        while IFS= read -r arg; do
            case "$arg" in
                *sysfsdev=/sys/bus/mdev/devices/*)
                    MDEV_UUID=${arg#*sysfsdev=/sys/bus/mdev/devices/}
                    MDEV_UUID=${MDEV_UUID%%,*}
                    break
                    ;;
            esac
        done < <(tr '\0' '\n' <"/proc/$pid/cmdline")
    fi
    [[ "$MDEV_UUID" =~ ^[0-9A-Fa-f-]{36}$ ]] && return 0
    MDEV_UUID=""

    if [[ -f "$MDEV_FILE" ]]; then
        read -r MDEV_UUID <"$MDEV_FILE" || true
    fi
    [[ "$MDEV_UUID" =~ ^[0-9A-Fa-f-]{36}$ ]] || MDEV_UUID=""
}

mdev_in_use_by_qemu() {
    local pid proc exe arg
    local -a candidates=() argv=()

    [[ -n "$MDEV_UUID" ]] || return 1
    mapfile -t candidates < <(
        pgrep -f '^([^ ]*/)?qemu-system-x86_64([^ ]|$)' 2>/dev/null || true
    )
    for pid in "${candidates[@]}"; do
        proc=/proc/$pid
        [[ -r "$proc/cmdline" ]] || continue
        exe=$(readlink -f "$proc/exe" 2>/dev/null || true)
        [[ "${exe##*/}" == qemu-system-x86_64 ]] || continue
        argv=()
        mapfile -d '' -t argv <"$proc/cmdline" 2>/dev/null || continue
        for arg in "${argv[@]}"; do
            [[ "$arg" == *"/sys/bus/mdev/devices/$MDEV_UUID"* ]] && return 0
        done
    done
    return 1
}

find_vm_ip() {
    local conf vm_mac mac_lc bridge
    conf=$(vm_storage_config_path "$VM_ID") || return
    [[ -f "$conf" ]] || return 1
    vm_mac=$(sed -n \
        's/^[[:space:]]*VM_MAC=\([0-9A-Fa-f:][0-9A-Fa-f:]*\)[[:space:]]*$/\1/p' \
        "$conf")
    [[ "$vm_mac" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]] || {
        echo "[down] vm.conf 中缺少合法 VM_MAC，跳过 IP 探测: $conf" >&2
        return 1
    }
    mac_lc=${vm_mac,,}
    bridge=${BR0:-br0}
    ip -4 neigh show 2>/dev/null | awk -v m="$mac_lc" -v bridge="$bridge" \
        '$3==bridge && tolower($5)==m && $1 ~ /^[0-9]/ {print $1; exit}'
}

cleanup_run() {
    local mdev_dir rc=0
    cleanup_start_lock_acquire || return 1
    if [[ -e "$STREAM_PID_FILE" || -e "${STREAM_STATE_PREFIX}.starttime" ||
          -e "${STREAM_STATE_PREFIX}.ready" ||
          -e "${STREAM_STATE_PREFIX}.socket" ]]; then
        if [[ ! -x "$STREAM_HELPER" ]]; then
            echo "[down] 推流 helper 缺失，保留 sidecar 状态: ${STREAM_STATE_PREFIX}.*" >&2
            rc=1
        elif ! "$STREAM_HELPER" stop "$VM_ID"; then
            echo "[down] vm${VM_ID} 推流 sidecar 清理失败" >&2
            rc=1
        fi
    fi
    dgame_endpoint_alias_remove "$DGAME_QMP_COMPAT" "$QMP_FILE" || true
    dgame_endpoint_alias_remove "$DGAME_MON_COMPAT" "$MON_FILE" || true
    dgame_endpoint_alias_remove \
        "$DGAME_FB_COMPAT" "$DGAME_PREVIEW_SOCKET" || true
    dgame_endpoint_alias_remove "$DGAME_QMP_PROXY_COMPAT" "$QMP_FILE" || true
    rm -f "$PID_FILE" "$QMP_FILE" "$QMP_PROXY_FILE" "$MON_FILE" \
        "$DGAME_PREVIEW_SOCKET" \
        2>/dev/null || true
    if ! cleanup_vlan_runtime; then
        echo "[down] vm${VM_ID} VLAN TAP 清理失败" >&2
        rc=1
    fi
    # 只回收该 VM 记录/命令行里的 mdev，绝不遍历删除其它 VM。
    if [[ -n "$MDEV_UUID" ]]; then
        mdev_dir="/sys/bus/mdev/devices/$MDEV_UUID"
        if mdev_in_use_by_qemu; then
            echo "[down] mdev $MDEV_UUID 仍被 QEMU 使用，保留记录" >&2
            rc=1
        elif [[ -L "$mdev_dir" ]]; then
            echo "[down] releasing vm${VM_ID} mdev $MDEV_UUID"
            SUDO_PASSWORD="$SUDO_PW" mdev_release "$MDEV_UUID" || {
                    echo "[down] mdev 释放失败，保留 $MDEV_FILE" >&2
                    rc=1
                }
        fi
    fi
    (( rc )) || rm -f "$MDEV_FILE" 2>/dev/null || true
    # swtpm 是独立 daemon。只在 QEMU 已退出后，按该 VM 的 state/socket/pid
    # 三元组精确匹配并回收；持久 TPM NVRAM/EK 状态永不删除。
    if ! vm_tpm_cleanup "$VM_ID"; then
        echo "[down] vm${VM_ID} swtpm 清理失败，保留 runtime 证据" >&2
        rc=1
    fi
    if cpu_isolation_release_vm "$VM_ID"; then
        rm -f -- "$CPU_ISOLATION_STATE_FILE" \
            "$CPU_ISOLATION_STATE_FILE".tmp.* 2>/dev/null || true
    else
        echo "[down] vm${VM_ID} CPU 隔离分区清理失败" >&2
        rc=1
    fi
    return "$rc"
}

remember_vm_mdev

if ! vm_is_running; then
    echo "[down] no qemu-system for vm${VM_ID} — nothing to stop"
    cleanup_run
    exit 0
fi

# 决定走 graceful (QMP/WinRM) 还是 --force：
#   - --force 显式 → 强杀
#   - QMP 不依赖 guest 网络，优先发 ACPI system_powerdown；WinRM 作为冗余。
#   - 两者都不可用时才自动降级 --force。
GRACEFUL_SENT=0
if (( ! FORCE )); then
    if qmp_system_powerdown 2>/dev/null; then
        echo "[down] QMP → system_powerdown"
        GRACEFUL_SENT=1
    else
        echo "[down] QMP unavailable" >&2
    fi
    GUEST_IP=${GUEST_IP_HINT:-$(find_vm_ip || true)}
    if [[ -n "$GUEST_IP" && -n "$GUEST_PASS" ]]; then
        echo "[down] WinRM → ${GUEST_IP}: shutdown /s"
        export GUEST_IP GUEST_USER GUEST_PASS
        python3 - <<'PY' 2>/dev/null || echo "[down] WinRM unreachable"
import os
from pypsrp.client import Client
Client(os.environ['GUEST_IP'], username=os.environ['GUEST_USER'],
       password=os.environ['GUEST_PASS'], ssl=False, auth='ntlm') \
  .execute_ps('shutdown /s /t 3 /f /c "stop-vm.sh"')
PY
        GRACEFUL_SENT=1
    elif [[ -n "$GUEST_IP" ]]; then
        echo "[down] GUEST_PASS 未通过环境变量提供，跳过 WinRM 冗余关机"
        if (( ! GRACEFUL_SENT )); then
            if (( GRACEFUL_ONLY )); then
                echo "[down] QMP 不可用且没有 guest 凭据；--graceful-only 拒绝强杀" >&2
                exit 1
            fi
            echo "[down] QMP 不可用且没有 guest 凭据，自动 --force"
            FORCE=1
        fi
    elif (( ! GRACEFUL_SENT )); then
        if (( GRACEFUL_ONLY )); then
            echo "[down] QMP 不可用且 guest IP 未知；--graceful-only 拒绝强杀" >&2
            exit 1
        fi
        echo "[down] QMP 不可用且 guest IP 未知，自动 --force"
        FORCE=1
    fi
fi

if (( FORCE )); then
    echo "[down] --force: TERM qemu-system-x86_64"
    pkill -TERM -f "$VM_PATTERN" || true
    for _ in $(seq 1 10); do
        vm_is_running || break
        sleep 1
    done
    if vm_is_running; then
        echo "[down] --force: KILL qemu-system-x86_64"
        pkill -KILL -f "$VM_PATTERN" || true
        sleep 2
    fi
    if vm_is_running; then
        echo "[down] QEMU 在 KILL 后仍未退出；保留 mdev 记录，不做回收" >&2
        exit 1
    fi
    tmux kill-session -t "vm${VM_ID}" 2>/dev/null || true
    cleanup_run
else
    echo -n "[down] waiting QEMU exit "
    for _ in $(seq 1 60); do
        if ! vm_is_running; then
            echo " — done"
            break
        fi
        echo -n "."
        sleep 3
    done
    if vm_is_running; then
        echo
        echo "[down] still running after 3 min — 再来一次带 --force"
        exit 1
    fi
    tmux kill-session -t "vm${VM_ID}" 2>/dev/null || true
    cleanup_run
fi
