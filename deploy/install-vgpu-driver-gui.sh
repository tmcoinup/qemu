#!/usr/bin/env bash
#
# install-vgpu-driver-gui.sh — GRID 553.24 driver install via AutoLogon+RunOnce。
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
#   ./install-vgpu-driver-gui.sh --ip <ip>
#
# 前置:
#   - guest WinRM 通 (Administrator/123456)
#   - $STAGE_DIR/553.24.exe 已 staged
#   - server.py 在 8080 跑 (server 已自动 sync deploy/guest/install-driver-runonce.ps1)
#
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

VM_ID=${VM_ID:-1}
IP_OVERRIDE=""
GUEST_USER=${GUEST_USER:-Administrator}
GUEST_PASS=${GUEST_PASS:-123456}
TIMEOUT_INSTALL=${TIMEOUT_INSTALL:-600}    # poll done flag 总秒数 (10 min)

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip)         IP_OVERRIDE="$2"; shift 2 ;;
        --timeout)    TIMEOUT_INSTALL="$2"; shift 2 ;;
        -h|--help)    sed -n '3,18p' "$0"; exit 0 ;;
        *.*.*.*)      IP_OVERRIDE="$1"; shift ;;
        [0-9]*)       VM_ID="$1"; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [[ -z "$IP_OVERRIDE" ]]; then
    conf="${VM_ROOT:-/home/ubuntu/images/vms}/configs/vm${VM_ID}.conf"
    [[ -f "$conf" ]] || { echo "missing $conf" >&2; exit 1; }
    # shellcheck source=/dev/null
    source "$conf"
    mac_lc=${VM_MAC,,}
    IP=$(ip -4 neigh show 2>/dev/null | awk -v m="$mac_lc" \
        '$3=="br0" && tolower($5)==m && $1 ~ /^[0-9]/ {print $1; exit}')
    [[ -n "$IP" ]] || { echo "no IP for $VM_MAC" >&2; exit 1; }
else
    IP="$IP_OVERRIDE"
fi

HOST_IP=$(ip -4 -o addr show br0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
[[ -n "$HOST_IP" ]] || HOST_IP="192.168.30.127"
BASE_URL="http://${HOST_IP}:8080"

for asset in 553.24.exe install-driver-runonce.ps1; do
    if ! curl -sfI "$BASE_URL/$asset" >/dev/null 2>&1; then
        echo "[gui-install] !! $BASE_URL/$asset not reachable — start server.py" >&2
        exit 1
    fi
done

echo "[gui-install] guest=$IP  timeout=${TIMEOUT_INSTALL}s"
echo

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
    Write-Host '  pulling 553.24.exe...'
    Invoke-WebRequest '{base}/553.24.exe' -OutFile C:\nv\553.24.exe -UseBasicParsing
}}

# 拉 RunOnce arm 脚本
Invoke-WebRequest '{base}/install-driver-runonce.ps1' `
    -OutFile C:\nv\install-driver-runonce.ps1 -UseBasicParsing

# 清掉之前 RunOnce flag (如果有)
Remove-Item 'C:\nv\drv-done.flag' -Force -EA 0

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

# ── Step 3: poll done flag ─────────────────────────────────────────────
echo
echo "[3/3] poll C:\\nv\\drv-done.flag (NVIDIA installer 退出码)"
EXIT_CODE=""
deadline=$(( $(date +%s) + TIMEOUT_INSTALL ))
while (( $(date +%s) < deadline )); do
    EXIT_CODE=$(python3 -c "
from pypsrp.client import Client
import sys
try:
    c = Client('$IP', username='$GUEST_USER', password='$GUEST_PASS', ssl=False, auth='ntlm')
    out, _, _ = c.execute_ps('if (Test-Path C:\\\\nv\\\\drv-done.flag) { Get-Content C:\\\\nv\\\\drv-done.flag } else { \"\" }')
    print((out or '').strip())
except Exception:
    print('')
" 2>/dev/null)
    [[ -n "$EXIT_CODE" ]] && break
    sleep 15
    echo -n "."
done
echo

if [[ -z "$EXIT_CODE" ]]; then
    echo "[gui-install] !! 超时 ${TIMEOUT_INSTALL}s 没等到 drv-done.flag — RunOnce 可能没触发"
    echo "  可能原因: AutoLogon 没生效 / RunOnce key 没写对 / setup.exe 卡住"
    exit 1
fi

echo "[gui-install] setup.exe 退出码: $EXIT_CODE"

# ── cleanup AutoLogon + verify ─────────────────────────────────────────
python3 - "$IP" "$GUEST_USER" "$GUEST_PASS" <<'PYEOF'
import sys
from pypsrp.client import Client
ip, user, pw = sys.argv[1:4]
c = Client(ip, username=user, password=pw, ssl=False, auth='ntlm')
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

Write-Host '=== driver state ==='
'nvlddmkm.sys: ' + (Test-Path 'C:\Windows\System32\drivers\nvlddmkm.sys')
Get-CimInstance Win32_VideoController -EA 0 |
    Format-Table Name, DriverVersion, ConfigManagerErrorCode, Status -AutoSize | Out-String
"""
out, _, _ = c.execute_ps(ps)
print(out)
PYEOF
