#!/usr/bin/env bash
#
# install-vgpu-driver-gui.sh — GRID 538.33 driver install via AutoLogon+RunOnce。
#
# 为什么有这个：silent install (`-s -clean -noreboot`) 在 SYSTEM session
# (pypsrp) 跑永远 -436207360；pnputil /add-driver 也只注册 INF 不拷 sys 文件。
# 唯一可靠路径是让 setup.exe 在 user session 跑 — 也就是用户登录 Windows 桌面后
# 启 setup.exe。本脚本 setup AutoLogon (Administrator) + RunOnce 让 reboot 后
# 自动登录 + RunOnce 触发 silent install + 写 done flag → host 端 poll flag。
#
# 用法:
#   ./install-vgpu-driver-gui.sh              # vm1 default
#   ./install-vgpu-driver-gui.sh <vm_id>
#   ./install-vgpu-driver-gui.sh <vm_id> --ip <ip>  # IP/MAC 必须与该 VM 匹配
#   ./install-vgpu-driver-gui.sh <vm_id> --clean-existing
#
# 前置:
#   - guest WinRM 通 (Administrator/123456)
#   - $STAGE_DIR/553.24.exe 已 staged；这是兼容旧脚本的文件名，内容必须为
#     已验证的 538.33 / DriverVersion 31.0.15.3833
#   - server.py 在 8080 跑 (server 已自动 sync deploy/guest/install-driver-runonce.ps1)
#
# 成功后默认删除 guest 中的 installer/RunOnce/flag 临时文件；排障时可临时设
# KEEP_GUEST_INSTALLER=1 保留。
#
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
# shellcheck source=lib/vgpu-driver-assets.sh
source ./lib/vgpu-driver-assets.sh
# shellcheck source=lib/vm-storage.sh
source ./lib/vm-storage.sh
vm_storage_init

VM_ID=${VM_ID:-1}
IP_OVERRIDE=""
GUEST_USER=${GUEST_USER:-Administrator}
GUEST_PASS=${GUEST_PASS:-123456}
TIMEOUT_INSTALL=${TIMEOUT_INSTALL:-600}    # poll done flag 总秒数 (10 min)
CLEAN_EXISTING=0
# 成功后默认删除 guest 中的一次性安装器/arm 脚本/flag；仅排障时设 1 保留。
KEEP_GUEST_INSTALLER=${KEEP_GUEST_INSTALLER:-0}
[[ "$KEEP_GUEST_INSTALLER" == 0 || "$KEEP_GUEST_INSTALLER" == 1 ]] || {
    echo "KEEP_GUEST_INSTALLER 必须是 0 或 1" >&2
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip)         IP_OVERRIDE="$2"; shift 2 ;;
        --timeout)    TIMEOUT_INSTALL="$2"; shift 2 ;;
        --clean-existing) CLEAN_EXISTING=1; shift ;;
        -h|--help)    sed -n '3,18p' "$0"; exit 0 ;;
        *.*.*.*)      IP_OVERRIDE="$1"; shift ;;
        [0-9]*)       VM_ID="$1"; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

# A same-version NVIDIA repair can restore the INF-provided NV_Modes value
# without changing the monitor profile hash.  Invalidate the offline monitor
# completion marker immediately before the first guest write so the next full
# shutdown must re-apply the reviewed G-11 display-mode policy.
invalidate_monitor_sync_marker() {
    local instance_dir monitor_marker

    instance_dir=$(vm_storage_instance_dir "$VM_ID") || return
    vm_storage_validate_root_path "$instance_dir" "vm${VM_ID} instance directory" || return
    vm_storage_validate_instance_tree "$VM_ID" || return
    monitor_marker=$(vm_storage_run_preferred_path "$VM_ID" monitor-edid) || return
    [[ "$monitor_marker" == "$instance_dir/run/monitor-edid.sha256" ]] || {
        echo "[gui-install] refusing unexpected monitor marker path: $monitor_marker" >&2
        return 1
    }
    if [[ -L "$monitor_marker" ||
          ( -e "$monitor_marker" && ! -f "$monitor_marker" ) ]]; then
        echo "[gui-install] refusing unsafe monitor marker: $monitor_marker" >&2
        return 1
    fi
    if [[ -f "$monitor_marker" ]]; then
        rm -f -- "$monitor_marker" || {
            echo "[gui-install] failed to invalidate monitor marker: $monitor_marker" >&2
            return 1
        }
        [[ ! -e "$monitor_marker" && ! -L "$monitor_marker" ]] || {
            echo "[gui-install] monitor marker still exists after removal: $monitor_marker" >&2
            return 1
        }
    fi
    echo "[gui-install] monitor mode cache marked for resync after the next full shutdown"
}

# Fail before touching the guest if the historically misnamed asset was replaced
# by a real 553.24 (R550) installer or any other unverified package.
vgpu_require_safe_driver_install_topology "$VM_ID"
vgpu_verify_driver_assets exe

IP=$(vgpu_resolve_bound_guest_ip "$VM_ID" "$IP_OVERRIDE") || exit

HOST_IP=$(ip -4 -o addr show br0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
[[ -n "$HOST_IP" ]] || HOST_IP="192.168.30.127"
BASE_URL="http://${HOST_IP}:8080"

# server.py may already have been running when this checkout changed.  Publish
# the reviewed RunOnce source atomically before checking its URL, so a future
# base image cannot accidentally fetch an older, unguarded copy.
sync_runonce_asset() {
    local source_path="$PWD/guest/install-driver-runonce.ps1"
    local target_path="$STAGE_DIR/install-driver-runonce.ps1"
    local temporary

    [[ -d "$STAGE_DIR" && ! -L "$STAGE_DIR" &&
       -f "$source_path" && ! -L "$source_path" ]] || {
        echo "[gui-install] unsafe/missing staging directory or RunOnce source" >&2
        return 1
    }
    if [[ -L "$target_path" || ( -e "$target_path" && ! -f "$target_path" ) ]]; then
        echo "[gui-install] refusing unsafe staging target: $target_path" >&2
        return 1
    fi
    cmp -s -- "$source_path" "$target_path" 2>/dev/null && return 0
    temporary=$(mktemp "$STAGE_DIR/.install-driver-runonce.XXXXXX") || return
    if ! install -m 0644 -- "$source_path" "$temporary" ||
            ! mv -T -- "$temporary" "$target_path"; then
        rm -f -- "$temporary"
        return 1
    fi
    echo "[gui-install] published current guarded RunOnce asset"
}
sync_runonce_asset

for asset in 553.24.exe install-driver-runonce.ps1; do
    if ! curl -sfI "$BASE_URL/$asset" >/dev/null 2>&1; then
        echo "[gui-install] !! $BASE_URL/$asset not reachable — start server.py" >&2
        exit 1
    fi
done

echo "[gui-install] guest=$IP  timeout=${TIMEOUT_INSTALL}s"
echo

invalidate_monitor_sync_marker

# The compatibility installer historically repaired partial installs by
# removing every published NVIDIA package/device and stale System32 payload
# first.  Keep that behavior behind an explicit internal flag, but never run
# setup.exe or pnputil from WinRM session 0: after cleanup the guarded RunOnce
# path below remains the only installer.
if (( CLEAN_EXISTING )); then
    echo "[0/3] clean existing/partial NVIDIA packages before guarded reinstall"
    python3 - "$IP" "$GUEST_USER" "$GUEST_PASS" <<'PYEOF'
import sys
from pypsrp.client import Client

ip, user, pw = sys.argv[1:4]
c = Client(ip, username=user, password=pw, ssl=False, auth='ntlm')
ps = r'''
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Continue'
New-Item -Path C:\nv -ItemType Directory -Force | Out-Null

Write-Host '[clean 1/4] published NVIDIA driver packages' -Fore Cyan
$nvInfs = Get-CimInstance Win32_PnPSignedDriver -EA 0 |
    Where-Object { $_.Manufacturer -match 'NVIDIA' -or
                   $_.Description -match 'NVIDIA' } |
    Select-Object -ExpandProperty InfName -Unique |
    Where-Object { $_ -match '^oem\d+\.inf$' }
foreach ($inf in $nvInfs) {
    Write-Host "  delete $inf"
    pnputil /delete-driver $inf /uninstall /force 2>&1 | Out-Null
}
Write-Host "  removed $(@($nvInfs).Count) published packages"

Write-Host '[clean 2/4] present and phantom NVIDIA PCI devices' -Fore Cyan
$env:DEVMGR_SHOW_NONPRESENT_DEVICES = '1'
Get-PnpDevice -EA 0 | Where-Object { $_.InstanceId -like 'PCI\VEN_10DE*' } |
    ForEach-Object {
        Write-Host "  remove $($_.InstanceId)"
        pnputil /remove-device $_.InstanceId /force 2>&1 | Out-Null
    }

Write-Host '[clean 3/4] NVIDIA user-space packages and stale installers' -Fore Cyan
Get-Package -EA 0 | Where-Object { $_.Name -like '*NVIDIA*' } |
    ForEach-Object {
        Write-Host "  remove $($_.Name)"
        $_ | Uninstall-Package -Force -EA SilentlyContinue | Out-Null
    }
Get-Process -EA 0 | Where-Object {
    $_.Path -and ($_.Path -eq 'C:\nv\553.24.exe' -or
                  $_.Path -like 'C:\NVIDIA\*' -or
                  $_.Name -in @('setup','setup.tmp','installer','nvi'))
} | ForEach-Object {
    Write-Host "  stop stale $($_.Name) pid=$($_.Id)"
    $_ | Stop-Process -Force -EA 0
}
Start-Sleep -Seconds 2
Remove-Item C:\nv\553.24.exe -Force -EA 0

Write-Host '[clean 4/4] partial System32 payload' -Fore Cyan
$driverDirectory = 'C:\Windows\System32\drivers'
$systemDirectory = 'C:\Windows\System32'
$patterns = @(
    'nvlddmkm.sys','nvkflt.sys','nvvad*.sys','nvgpu*.sys',
    'nvapi*.dll','nvcuda*.dll','nvml*.dll','nvopencl*.dll',
    'nvwgf2um*.dll','nvd3dum*.dll','nvoptix*.dll'
)
foreach ($pattern in $patterns) {
    Get-ChildItem -Path $driverDirectory,$systemDirectory -Filter $pattern -EA 0 |
        ForEach-Object {
            try { Remove-Item $_.FullName -Force -EA Stop } catch {}
        }
}
Write-Host 'G11_NVIDIA_PRE_CLEAN_DONE'
'''
out, streams, _ = c.execute_ps(ps)
print(out)
for error in (streams.error or []):
    print(f'[clean-warning] {error}', file=sys.stderr)
if 'G11_NVIDIA_PRE_CLEAN_DONE' not in (out or ''):
    raise SystemExit('guest NVIDIA pre-clean did not return its completion marker')
PYEOF
fi

# ── Step 1: arm AutoLogon + RunOnce + trigger reboot ───────────────────
echo "[1/3] arm RunOnce + AutoLogon, then reboot guest"
python3 - "$IP" "$GUEST_USER" "$GUEST_PASS" "$BASE_URL" <<'PYEOF'
import sys
from pypsrp.client import Client
ip, user, pw, base = sys.argv[1:5]
c = Client(ip, username=user, password=pw, ssl=False, auth='ntlm')
ps = fr"""
$ProgressPreference = 'SilentlyContinue'
New-Item -Path C:\nv -ItemType Directory -Force | Out-Null

# 拉 setup.exe (如果不在)
if (-not (Test-Path 'C:\nv\553.24.exe') -or (Get-Item 'C:\nv\553.24.exe').Length -lt 500000000) {{
    Write-Host '  pulling 538.33 package (legacy asset name 553.24.exe)...'
    Invoke-WebRequest '{base}/553.24.exe' -OutFile C:\nv\553.24.exe -UseBasicParsing
}}

# 拉 RunOnce arm 脚本
Invoke-WebRequest '{base}/install-driver-runonce.ps1' `
    -OutFile C:\nv\install-driver-runonce.ps1 -UseBasicParsing

# 清掉之前 RunOnce flag (如果有)
Remove-Item 'C:\nv\drv-done.flag' -Force -EA 0
Remove-Item 'C:\nv\drv-done.flag.tmp' -Force -EA 0

# 跑 arm 脚本：会设 AutoLogon + RunOnce + shutdown /r
& powershell.exe -ExecutionPolicy Bypass -File C:\nv\install-driver-runonce.ps1 | Out-Host
"  arm script returned (guest is rebooting)"
"""
out, streams, _ = c.execute_ps(ps)
print(out)
for e in (streams.error or []): print(f'[err] {e}', file=sys.stderr)
PYEOF

# ── Step 2: wait WinRM 回来 ────────────────────────────────────────────
echo
echo "[2/3] wait guest reboot + AutoLogon + RunOnce setup.exe + flag..."

# 先等 WinRM 短暂掉线（reboot 开始）
for _ in $(seq 1 10); do
    nc -z -w 2 "$IP" 5985 2>/dev/null || break
    sleep 2
done
echo "  guest 已断线（reboot 中）"

# 等 WinRM 回来
deadline=$(( $(date +%s) + TIMEOUT_INSTALL ))
while (( $(date +%s) < deadline )); do
    if nc -z -w 2 "$IP" 5985 2>/dev/null; then
        # NTLM round-trip 才算真 ready
        if python3 -c "
from pypsrp.client import Client
import sys
try:
    Client('$IP', username='$GUEST_USER', password='$GUEST_PASS', ssl=False, auth='ntlm') \
        .execute_ps('Get-Date')
    sys.exit(0)
except Exception:
    sys.exit(1)
" 2>/dev/null; then
            echo "  WinRM ready, AutoLogon 应已触发，setup.exe 在 user session 跑"
            break
        fi
    fi
    sleep 5
done

# ── Step 3: poll guarded installer receipt ─────────────────────────────
echo
printf '%s\n' '[3/3] poll C:\nv\drv-done.flag (installer + R535 page-safe display receipt)'
RECEIPT=""
deadline=$(( $(date +%s) + TIMEOUT_INSTALL ))
while (( $(date +%s) < deadline )); do
    RECEIPT=$(python3 -c "
from pypsrp.client import Client
import sys
try:
    c = Client('$IP', username='$GUEST_USER', password='$GUEST_PASS', ssl=False, auth='ntlm')
    out, _, _ = c.execute_ps('if (Test-Path C:\\\\nv\\\\drv-done.flag) { Get-Content C:\\\\nv\\\\drv-done.flag } else { \"\" }')
    print((out or '').strip())
except Exception:
    print('')
" 2>/dev/null)
    [[ "$RECEIPT" == *'console_safe='* ]] && break
    sleep 15
    echo -n "."
done
echo

if [[ "$RECEIPT" != *'console_safe='* ]]; then
    echo "[gui-install] !! 超时 ${TIMEOUT_INSTALL}s 没等到 drv-done.flag — RunOnce 可能没触发"
    echo "  可能原因: AutoLogon 没生效 / RunOnce key 没写对 / setup.exe 卡住"
    exit 1
fi

INSTALLER_EXIT=$(sed -n 's/^installer=//p' <<<"$RECEIPT")
DISPLAY_MODE=$(sed -n 's/^display=//p' <<<"$RECEIPT")
CONSOLE_BYTES=$(sed -n 's/^console_bytes=//p' <<<"$RECEIPT")
CONSOLE_SAFE=$(sed -n 's/^console_safe=//p' <<<"$RECEIPT")
RECEIPT_VALID=1
[[ "$INSTALLER_EXIT" =~ ^-?[0-9]+$ ]] || RECEIPT_VALID=0
[[ "$DISPLAY_MODE" =~ ^[1-9][0-9]*x[1-9][0-9]*$ ]] || RECEIPT_VALID=0
[[ "$CONSOLE_BYTES" =~ ^[1-9][0-9]*$ ]] || RECEIPT_VALID=0
[[ "$CONSOLE_SAFE" == 0 || "$CONSOLE_SAFE" == 1 ]] || RECEIPT_VALID=0
echo "[gui-install] receipt: installer=${INSTALLER_EXIT:-invalid} display=${DISPLAY_MODE:-invalid} bytes=${CONSOLE_BYTES:-invalid} page_safe=${CONSOLE_SAFE:-invalid}"

# ── cleanup AutoLogon / transient files + verify ───────────────────────
python3 - "$IP" "$GUEST_USER" "$GUEST_PASS" "${INSTALLER_EXIT:-invalid}" \
    "${CONSOLE_SAFE:-0}" "$KEEP_GUEST_INSTALLER" <<'PYEOF'
import sys
from pypsrp.client import Client
ip, user, pw, exit_code, console_safe, keep_installer = sys.argv[1:7]
c = Client(ip, username=user, password=pw, ssl=False, auth='ntlm')
cleanup_transient = (exit_code == '0' and console_safe == '1' and
                     keep_installer == '0')
cleanup_ps = r"""
Write-Host 'cleaning one-shot driver installer artifacts'
Remove-Item 'C:\nv\install-driver-runonce.ps1' -Force -EA 0
Remove-Item 'C:\nv\drv-done.flag' -Force -EA 0
Remove-Item 'C:\nv\553.24.exe' -Force -EA 0
Remove-Item 'C:\nv\553.24-dd.zip' -Force -EA 0
Remove-Item 'C:\nv\553.24-dd' -Recurse -Force -EA 0
""" if cleanup_transient else r"""
Write-Host 'keeping installer artifacts (failed/non-zero install or KEEP_GUEST_INSTALLER=1)'
"""
ps = r"""
# 清 AutoLogon (RunOnce 已自动清)
$wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Remove-ItemProperty -Path $wl -Name 'AutoAdminLogon'  -EA 0
Remove-ItemProperty -Path $wl -Name 'DefaultPassword' -EA 0
Remove-ItemProperty -Path $wl -Name 'AutoLogonCount'  -EA 0

# Block Windows Update 装 driver (防止下次替换)
$wukey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
New-Item -Path $wukey -Force | Out-Null
Set-ItemProperty -Path $wukey -Name 'ExcludeWUDriversInQualityUpdate' -Type DWord -Value 1
$dskey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching'
New-Item -Path $dskey -Force | Out-Null
Set-ItemProperty -Path $dskey -Name 'SearchOrderConfig' -Type DWord -Value 0

""" + cleanup_ps + r"""

Write-Host '=== driver state ==='
'nvlddmkm.sys: ' + (Test-Path 'C:\Windows\System32\drivers\nvlddmkm.sys')
Get-CimInstance Win32_VideoController -EA 0 |
    Format-Table Name, DriverVersion, ConfigManagerErrorCode, Status -AutoSize | Out-String
"""
out, _, _ = c.execute_ps(ps)
print(out)
PYEOF

if (( RECEIPT_VALID == 0 )); then
    echo "[gui-install] !! 安装收据格式非法；已清 AutoLogon，保留安装器供排障" >&2
    exit 1
fi
if [[ "$DISPLAY_MODE" != 1920x1080 || "$CONSOLE_BYTES" != 8294400 ||
      "$CONSOLE_SAFE" != 1 ]]; then
    echo "[gui-install] !! R535 本地 console 未收敛到 page-safe 1920x1080；拒绝把黑屏状态当成功" >&2
    exit 1
fi
if [[ "$INSTALLER_EXIT" != 0 ]]; then
    echo "[gui-install] !! GRID installer 退出码非 0: $INSTALLER_EXIT" >&2
    exit 1
fi

echo "[gui-install] PASS: GRID installer=0 / display=1920x1080 / console frame=0x7e9000 (4-KiB aligned)"
