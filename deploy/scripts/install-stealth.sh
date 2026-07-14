#!/usr/bin/env bash
# install-stealth.sh — host-side one-click for VM<INSTANCE>:
#
#   1. Push the full stealth bundle to the running guest (via SSH).
#   2. Run install-stealth-guest.ps1 inside the guest as Administrator.
#   3. Trigger graceful shutdown via QMP system_powerdown.
#   4. Wait for QEMU to exit, then relaunch with GPU_SELFSIGNED=1
#      so PCI VEN/DEV come up as VEN_10DE:DEV_1C81.
#   5. Wait for SSH on the bridge IP and dump the post-boot state.
#
# Pre-requisites:
#   - Guest must already be running with the bootstrap done (OpenSSH active,
#     Administrator/123456, autologin). i.e. you already did
#     `irm http://<host>:8765/vm-bootstrap.ps1 | iex` once. See USAGE.md.
#   - Host has built EfiGuard custom-build (deploy/efiguard/custom-build/)
#     and the backdated cert chain (deploy/driver-signing/{certs,out}/).
#
# Usage:
#   deploy/scripts/install-stealth.sh <INSTANCE> [<guest-ip>]
#
# Examples:
#   deploy/scripts/install-stealth.sh 1
#   deploy/scripts/install-stealth.sh 2 192.168.30.144

set -euo pipefail

INSTANCE="${1:-}"
GUEST_IP="${2:-}"
if ! [[ "$INSTANCE" =~ ^[1-9][0-9]*$ ]]; then
    echo "usage: $0 <INSTANCE> [<guest-ip>]" >&2
    exit 2
fi

cd "$(dirname "$0")/../.."   # → repo root

QMP="/tmp/qemu-stealth-${INSTANCE}.qmp"
PASS='123456'
VMS_DIR="${VMS_DIR:-/home/ubuntu/images/vms}"
PROFILE_FILE="$VMS_DIR/$INSTANCE/profile"
RELAUNCH_PLATFORM_ARGS=()

# guest 安装完成后的自动重启必须保持创建 compatibility 实例时的显式授权。
# 使用 profile 白名单读取器而不是 source/eval；最终 start-vm 仍会重新校验整个
# manifest 绑定，所以这里只负责路由参数，不把 profile 内容当成可信命令。
# shellcheck source=stealth-lib.sh
source deploy/scripts/stealth-lib.sh
# shellcheck source=lib/sv-qemu-process.sh
source deploy/scripts/lib/sv-qemu-process.sh
if [[ -r "$PROFILE_FILE" ]]; then
    _profile_schema="$(stealth_profile_get PLATFORM_SCHEMA_VERSION "$PROFILE_FILE" || true)"
    if [[ "$_profile_schema" != "1" ]]; then
        echo "ERROR: guest 安装/自动重启不支持无 manifest 绑定的 legacy profile；请先备份并迁移" >&2
        exit 1
    fi
    _profile_status="$(stealth_profile_get PLATFORM_STATUS "$PROFILE_FILE" || true)"
    if [[ "$_profile_status" == "compatibility" ]]; then
        _profile_platform="$(stealth_profile_get PLATFORM_ID "$PROFILE_FILE" || true)"
        if ! [[ "$_profile_platform" =~ ^[a-z0-9][a-z0-9-]{7,95}$ ]]; then
            echo "ERROR: compatibility profile 缺少合法 schema/platform ID: $PROFILE_FILE" >&2
            exit 1
        fi
        RELAUNCH_PLATFORM_ARGS=(
            "--platform-id=$_profile_platform"
            --allow-platform-compatibility
        )
    fi
fi

# ---- discover guest IP if not supplied ----------------------------
if [[ -z "$GUEST_IP" ]]; then
    if [[ ! -S "$QMP" ]]; then
        echo "ERROR: $QMP not found — VM${INSTANCE} not running?" >&2
        exit 1
    fi
    # 从严格匹配到的真实 QEMU 进程读取 MAC；公共匹配器同时兼容当前名称与旧名称，
    # 且不会把实例 1、实例 10 或 inhibit 包装进程混为一谈。
    _qemu_pids=()
    mapfile -t _qemu_pids < <(sv_qemu_instance_pids "$INSTANCE" || true)
    if (( ${#_qemu_pids[@]} != 1 )); then
        echo "ERROR: expected exactly one QEMU process for instance $INSTANCE, found ${#_qemu_pids[@]}" >&2
        exit 1
    fi
    _qemu_pid="${_qemu_pids[0]}"
    [[ -r "/proc/$_qemu_pid/cmdline" ]] || {
        echo "ERROR: QEMU process ${_qemu_pid} exited during MAC discovery" >&2
        exit 1
    }
    MAC="$(tr '\0' ' ' <"/proc/$_qemu_pid/cmdline" \
        | grep -oE 'mac=[a-f0-9:]+' | head -1 | cut -d= -f2 || true)"
    if [[ -z "$MAC" ]]; then
        echo "ERROR: could not find MAC for instance $INSTANCE" >&2
        exit 1
    fi
    # ARP scan to populate neigh cache, then read it
    for i in $(seq 30 220); do ping -c 1 -W 1 -n "192.168.30.$i" >/dev/null 2>&1 & done
    wait 2>/dev/null
    sleep 1
    GUEST_IP=$(ip neigh 2>/dev/null | grep "$MAC" | grep -oE '192\.168\.[0-9]+\.[0-9]+' | head -1)
    if [[ -z "$GUEST_IP" ]]; then
        echo "ERROR: ARP scan didn't find guest with MAC $MAC. Pass IP explicitly." >&2
        exit 1
    fi
fi
echo ">> guest IP = $GUEST_IP (instance $INSTANCE)"

GUEST="Administrator@$GUEST_IP"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PubkeyAuthentication=no)

# ---- create dirs on guest ------------------------------------------
echo ">> [1/5] creating C:\\stealth on guest"
sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "$GUEST" \
    'mkdir C:\stealth\driver-signing 2>nul & mkdir C:\stealth\nv-driver 2>nul & mkdir C:\stealth\efiguard 2>nul & exit /b 0'

# ---- push files ----------------------------------------------------
echo ">> [2/5] uploading stealth bundle"
sshpass -p "$PASS" scp "${SSH_OPTS[@]}" \
    deploy/driver-signing/certs/backdated-ca.der \
    deploy/driver-signing/certs/backdated-signer.der \
    "$GUEST":'C:/stealth/driver-signing/' >/dev/null

sshpass -p "$PASS" scp "${SSH_OPTS[@]}" \
    deploy/driver-signing/out/viogpudo.sys \
    deploy/driver-signing/out/viogpudo.cat \
    deploy/driver-signing/out/viogpudo-nvidia.inf \
    "$GUEST":'C:/stealth/nv-driver/' >/dev/null

sshpass -p "$PASS" scp "${SSH_OPTS[@]}" \
    deploy/nvapi-shim/nvapi64.dll \
    deploy/scripts/apply-gpu-spoof.ps1 \
    deploy/scripts/install-stealth-guest.ps1 \
    "$GUEST":'C:/stealth/' >/dev/null

sshpass -p "$PASS" scp "${SSH_OPTS[@]}" \
    deploy/efiguard/custom-build/Loader.efi \
    deploy/efiguard/custom-build/EfiGuardDxe.efi \
    "$GUEST":'C:/stealth/efiguard/' >/dev/null

# ---- run guest installer -------------------------------------------
echo ">> [3/5] running install-stealth-guest.ps1"
sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "$GUEST" \
    'powershell -NoProfile -ExecutionPolicy Bypass -File C:\stealth\install-stealth-guest.ps1'

# ---- shutdown via QMP, wait for exit -------------------------------
echo ">> [4/5] graceful shutdown via QMP (wait for QEMU to exit)"
sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "$GUEST" 'shutdown /s /t 0 /f' 2>/dev/null || true
deadline=$(( $(date +%s) + 60 ))
while sv_qemu_instance_pids "$INSTANCE" >/dev/null 2>&1; do
    if (( $(date +%s) > deadline )); then
        echo ">> WARN: QEMU still running after 60s; force-killing"
        mapfile -t _qemu_pids < <(sv_qemu_instance_pids "$INSTANCE" || true)
        (( ${#_qemu_pids[@]} == 0 )) || kill -KILL "${_qemu_pids[@]}"
        break
    fi
    sleep 2
done
sleep 3

# ---- relaunch with GPU_SELFSIGNED=1 --------------------------------
echo ">> [5/5] relaunching QEMU with GPU_SELFSIGNED=1 STABLE_DISPLAY=1"
DISPLAY=:1 BRIDGE=br0 GPU_SELFSIGNED=1 STABLE_DISPLAY=1 \
    nohup deploy/scripts/start-vm.sh "$INSTANCE" "${RELAUNCH_PLATFORM_ARGS[@]}" \
        > "/tmp/qemu-stealth-${INSTANCE}.log" 2>&1 &
disown
sleep 6

# ---- wait for SSH back, dump state ---------------------------------
echo ">> waiting for guest SSH on $GUEST_IP..."
deadline=$(( $(date +%s) + 240 ))
while ! sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" -o ConnectTimeout=3 "$GUEST" 'echo UP' 2>/dev/null | grep -q UP; do
    if (( $(date +%s) > deadline )); then
        echo "ERROR: guest didn't come back online in 4 min — check QEMU log" >&2
        exit 1
    fi
    sleep 5
done

echo ">> guest up. final state:"
sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "$GUEST" 'powershell -NoProfile -Command "
[Console]::OutputEncoding=[Text.Encoding]::UTF8
bcdedit | Select-String testsigning
Write-Host
Get-CimInstance Win32_VideoController | Select Name,Status,DriverVersion,PNPDeviceID,ConfigManagerErrorCode | Format-List"'

echo ''
echo '=== install-stealth done. Verify:'
echo '   - testsigning : No'
echo '   - Status      : OK'
echo '   - PNPDeviceID : VEN_10DE&DEV_1C81'
echo '   - DriverVersion : 100.93.0.0  (backdated viogpudo)'
echo '==='
