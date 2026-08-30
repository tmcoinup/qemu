#!/usr/bin/env bash
# One-command, fail-closed branch-matched GRID installation for a G-11 disk.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/vm-storage.sh
source "$here/lib/vm-storage.sh"
# shellcheck source=lib/vgpu-driver-assets.sh
source "$here/lib/vgpu-driver-assets.sh"
# shellcheck source=lib/g11-python-runtime.sh
source "$here/lib/g11-python-runtime.sh"
G11_PYTHON_RUNTIME_INSTALLER="$here/host/install-g11-python-runtime.sh"
vm_storage_init

usage() {
    cat <<'EOF'
usage: ./deploy/scripts/vmctl.sh driver-install ID [--ip IPv4]
       [--gtk|--sdl|--headless] [--lab-usernet] [--winrm-port PORT]
       [--boot-timeout SEC] [--install-timeout SEC] [--start]

Boots a temporary standard-VGA console with the NVIDIA mdev present only for
PnP (display=off), installs the reviewed production package matching the exact
host branch, and fully shuts Windows down.  R535 additionally performs offline
EDID/NV_Modes convergence; R580 deliberately skips that R535-only path.
EOF
}

VM_ID=""
IP_OVERRIDE=""
BACKEND=sdl
BOOT_TIMEOUT=360
INSTALL_TIMEOUT=600
START_AFTER_SYNC=0
LAB_USERNET=0
WINRM_PORT=0
while (($#)); do
    case "$1" in
        [1-9]|[1-9][0-9]*)
            [[ -z "$VM_ID" ]] || { usage >&2; exit 2; }
            VM_ID=$1
            shift
            ;;
        --ip)
            (($# >= 2)) || { echo "--ip requires an address" >&2; exit 2; }
            IP_OVERRIDE=$2
            shift 2
            ;;
        --gtk) BACKEND=gtk; shift ;;
        --sdl) BACKEND=sdl; shift ;;
        --headless) BACKEND=headless; shift ;;
        --lab-usernet) LAB_USERNET=1; shift ;;
        --winrm-port)
            (($# >= 2)) || { echo "--winrm-port requires a port" >&2; exit 2; }
            WINRM_PORT=$2
            shift 2
            ;;
        --boot-timeout)
            (($# >= 2)) || { echo "--boot-timeout requires seconds" >&2; exit 2; }
            BOOT_TIMEOUT=$2
            shift 2
            ;;
        --install-timeout)
            (($# >= 2)) || { echo "--install-timeout requires seconds" >&2; exit 2; }
            INSTALL_TIMEOUT=$2
            shift 2
            ;;
        --start) START_AFTER_SYNC=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown arg: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ -n "$VM_ID" ]] || { usage >&2; exit 2; }
GUEST_PASS=${GUEST_PASS:-}
(( ${#GUEST_PASS} >= 6 && ${#GUEST_PASS} <= 64 )) &&
        [[ "$GUEST_PASS" != *$'\r'* && "$GUEST_PASS" != *$'\n'* ]] || {
    echo "GUEST_PASS must be supplied through a secure runtime environment (6..64 characters)" >&2
    exit 2
}
vm_storage_id_is_supported "$VM_ID" || { echo "unsupported VM ID: $VM_ID" >&2; exit 2; }
[[ "$BOOT_TIMEOUT" =~ ^[1-9][0-9]*$ && "$BOOT_TIMEOUT" -le 1800 ]] || {
    echo "--boot-timeout must be 1..1800" >&2; exit 2;
}
[[ "$INSTALL_TIMEOUT" =~ ^[1-9][0-9]*$ && "$INSTALL_TIMEOUT" -le 3600 ]] || {
    echo "--install-timeout must be 1..3600" >&2; exit 2;
}
if ((WINRM_PORT == 0)); then
    if ((LAB_USERNET)); then
        WINRM_PORT=$((15984 + VM_ID))
    else
        WINRM_PORT=5985
    fi
fi
[[ "$WINRM_PORT" =~ ^[1-9][0-9]*$ ]] && ((WINRM_PORT <= 65535)) || {
    echo "--winrm-port must be 1..65535" >&2; exit 2;
}
if ((LAB_USERNET)) && [[ -n "$IP_OVERRIDE" && "$IP_OVERRIDE" != 127.0.0.1 ]]; then
    echo "--lab-usernet only accepts localhost as an explicit WinRM endpoint" >&2
    exit 2
fi
vm_storage_require_namespace_ready "$VM_ID"
conf=$(vm_storage_config_path "$VM_ID")
disk=$(vm_storage_disk_path "$VM_ID")
[[ -f "$conf" && ! -L "$conf" && -f "$disk" && ! -L "$disk" ]] || {
    echo "[driver-install] vm${VM_ID} config/disk is missing or unsafe" >&2
    exit 1
}
if pgrep -af qemu-system-x86_64 2>/dev/null | grep -F -- "$disk" >/dev/null; then
    echo "[driver-install] vm${VM_ID} is already running; stop it cleanly first" >&2
    exit 1
fi

vgpu_verify_driver_assets exe
WINRM_PYTHON=$(g11_python_resolve pypsrp) || exit 1

# start-vm performs an offline pre-driver commit and allocates the mdev.  Give
# every later sudo call a normal timestamp before start-vm is backgrounded, so
# no background job ever reads a password from the terminal.
if ((EUID != 0)) && ! sudo -n true 2>/dev/null; then
    if [[ -n "${SUDO_PASSWORD:-}" ]]; then
        :
    elif [[ -t 0 ]]; then
        echo "[driver-install] 取得临时 sudo 票据（凭据不会写入文件或参数）"
        sudo -v
    else
        echo "[driver-install] 非交互运行缺少 sudo 票据；请先 sudo -v 或使用安全运行时环境变量 SUDO_PASSWORD" >&2
        exit 1
    fi
fi

if ! ss -tln 2>/dev/null | grep -q ':8080 '; then
    echo "[driver-install] 启动只读 staging HTTP 服务"
    nohup python3 "$here/server.py" > /tmp/g11-driver-http.log 2>&1 &
    http_pid=$!
    for _ in $(seq 1 30); do
        ss -tln 2>/dev/null | grep -q ':8080 ' && break
        kill -0 "$http_pid" 2>/dev/null || {
            echo "[driver-install] staging HTTP 服务启动失败；查看 /tmp/g11-driver-http.log" >&2
            exit 1
        }
        sleep 0.2
    done
    ss -tln 2>/dev/null | grep -q ':8080 ' || {
        echo "[driver-install] staging HTTP 服务未在 :8080 监听" >&2
        exit 1
    }
fi

launcher_pid=""
install_complete=0
cleanup() {
    local rc=$?
    trap - EXIT INT TERM
    if ((install_complete == 0)) && [[ -n "$launcher_pid" ]] &&
            kill -0 "$launcher_pid" 2>/dev/null; then
        echo "[driver-install] 流程未完成；仅请求 vm${VM_ID} 优雅关机（绝不强杀）" >&2
        "$here/scripts/stop-vm.sh" "$VM_ID" --graceful-only ||
            echo "[driver-install] WARN: 优雅关机未完成，VM 保持安全安装显示模式" >&2
    fi
    if [[ -n "$launcher_pid" ]]; then
        for _ in $(seq 1 150); do
            kill -0 "$launcher_pid" 2>/dev/null || break
            sleep 0.2
        done
        if kill -0 "$launcher_pid" 2>/dev/null; then
            echo "[driver-install] WARN: start-vm 仍在运行；不强杀，保留现场" >&2
        else
            wait "$launcher_pid" 2>/dev/null || true
        fi
    fi
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

start_args=( "$VM_ID" "--driver-install-${BACKEND}" )
((LAB_USERNET == 0)) || start_args+=( --lab-usernet )
echo "[driver-install] 启动 vm${VM_ID} 安全安装拓扑：标准 VGA + mdev display=off (${BACKEND})"
LAB_USERNET_WINRM_PORT=$WINRM_PORT \
    "$here/scripts/start-vm.sh" "${start_args[@]}" &
launcher_pid=$!

deadline=$(( $(date +%s) + BOOT_TIMEOUT ))
guest_ip=""
winrm_ready=0
echo "[driver-install] 等待 guest WinRM/NTLM（最长 ${BOOT_TIMEOUT}s）"
while (( $(date +%s) < deadline )); do
    kill -0 "$launcher_pid" 2>/dev/null || {
        echo "[driver-install] start-vm 在 guest 就绪前退出" >&2
        wait "$launcher_pid" || true
        exit 1
    }
    if ((LAB_USERNET)); then
        guest_ip=127.0.0.1
    else
        guest_ip=$(vgpu_resolve_bound_guest_ip "$VM_ID" "$IP_OVERRIDE" 2>/dev/null || true)
    fi
    if [[ -n "$guest_ip" ]] && nc -z -w 2 "$guest_ip" "$WINRM_PORT" 2>/dev/null; then
        if GUEST_USER_VALUE=${GUEST_USER:-Administrator} \
                GUEST_PASS_VALUE=$GUEST_PASS \
                "$WINRM_PYTHON" - "$guest_ip" "$WINRM_PORT" <<'PY' >/dev/null 2>&1
import os
import sys
from pypsrp.client import Client

try:
    Client(sys.argv[1], username=os.environ['GUEST_USER_VALUE'],
           password=os.environ['GUEST_PASS_VALUE'], ssl=False,
           auth='ntlm', port=int(sys.argv[2])).execute_ps('Get-Date')
except Exception:
    raise SystemExit(1)
PY
        then
            winrm_ready=1
            break
        fi
    fi
    sleep 3
done
((winrm_ready == 1)) || {
    echo "[driver-install] guest WinRM 未在时限内就绪" >&2
    exit 1
}

install_args=( "$VM_ID" --ip "$guest_ip" --timeout "$INSTALL_TIMEOUT" )
install_args+=( --winrm-port "$WINRM_PORT" )
((LAB_USERNET == 0)) || install_args+=( --lab-usernet )
((START_AFTER_SYNC == 0)) || install_args+=( --start )
"$here/install-vgpu-driver.sh" "${install_args[@]}"
install_complete=1
wait "$launcher_pid" 2>/dev/null || true
launcher_pid=""
trap - EXIT INT TERM
echo "[driver-install] 通用 GRID 首装流程完成"
