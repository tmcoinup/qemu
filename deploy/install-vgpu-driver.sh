#!/usr/bin/env bash
#
# install-vgpu-driver.sh — host one-liner to (re-)install the
# NVIDIA vGPU 16.x GRID driver (538.33 DCH) inside the guest.
#
# When the GeForce DCH driver lands via Windows Update on a vGPU
# guest, NVIDIA's anti-VM check trips and the device goes Error 43.
# The fix is to wipe every NVIDIA driver/device, push the GRID
# 538.33 .exe via HTTP, and run its silent installer.
#
# Compatibility note: the current script still requests the historical staging
# name /home/ubuntu/images/staging/553.24.exe.  That file must contain the
# verified 538.33 package (DriverVersion 31.0.15.3833), not a real 553.24 EXE.
#
# Usage:
#   ./install-vgpu-driver.sh              # vm1 default
#   ./install-vgpu-driver.sh <vm_id>
#   ./install-vgpu-driver.sh <vm_id> --ip 192.168.30.191  # IP/MAC 必须与该 VM 匹配
#   ./install-vgpu-driver.sh --no-reboot  # don't reboot after install
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
NO_REBOOT=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip)         IP_OVERRIDE="$2"; shift 2 ;;
        --no-reboot)  NO_REBOOT=1; shift ;;
        -h|--help)    sed -n '3,16p' "$0"; exit 0 ;;
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
        echo "[install-vgpu] refusing unexpected monitor marker path: $monitor_marker" >&2
        return 1
    }
    if [[ -L "$monitor_marker" ||
          ( -e "$monitor_marker" && ! -f "$monitor_marker" ) ]]; then
        echo "[install-vgpu] refusing unsafe monitor marker: $monitor_marker" >&2
        return 1
    fi
    if [[ -f "$monitor_marker" ]]; then
        rm -f -- "$monitor_marker" || {
            echo "[install-vgpu] failed to invalidate monitor marker: $monitor_marker" >&2
            return 1
        }
        [[ ! -e "$monitor_marker" && ! -L "$monitor_marker" ]] || {
            echo "[install-vgpu] monitor marker still exists after removal: $monitor_marker" >&2
            return 1
        }
    fi
    echo "[install-vgpu] monitor mode cache marked for resync after the next full shutdown"
}

# Fail before wiping the guest if either historically misnamed asset is not the
# exact 538.33 baseline verified with this host driver.
vgpu_verify_driver_assets all

IP=$(vgpu_resolve_bound_guest_ip "$VM_ID" "$IP_OVERRIDE") || exit

HOST_IP=$(ip -4 -o addr show br0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
[[ -n "$HOST_IP" ]] || HOST_IP="192.168.30.127"
BASE_URL="http://${HOST_IP}:8080"

# Sanity: setup.exe + pnputil-fallback zip 都要可达
for asset in 553.24.exe 553.24-display-driver.zip; do
    if ! curl -sfI "$BASE_URL/$asset" >/dev/null 2>&1; then
        echo "[install-vgpu] $BASE_URL/$asset not reachable"
        if [[ "$asset" == "553.24.exe" ]]; then
            echo "  → cp ~/Downloads/vGPU16.4/Guest_Drivers/538.33_*.exe \\"
            echo "       /home/ubuntu/images/staging/553.24.exe"
        else
            echo "  → 7z x /home/ubuntu/images/staging/553.24.exe -o/tmp/553.24 -y && \\"
            echo "    cd /tmp/553.24 && \\"
            echo "    zip -qr /home/ubuntu/images/staging/553.24-display-driver.zip Display.Driver"
        fi
        echo "  确认 http server 在 8080: python3 server.py"
        exit 1
    fi
done

echo "[install-vgpu] guest=$IP  reboot=$([[ $NO_REBOOT -eq 1 ]] && echo no || echo yes)"

REBOOT_CMD=""
[[ $NO_REBOOT -eq 0 ]] && REBOOT_CMD='Write-Host "rebooting in 10s..." -Fore Yellow; Start-Sleep 10; shutdown /r /t 0'

invalidate_monitor_sync_marker

exec python3 - "$IP" "$GUEST_USER" "$GUEST_PASS" "$BASE_URL" "$REBOOT_CMD" <<'PYEOF'
import sys
from pypsrp.client import Client
ip, user, pw, base, reboot = sys.argv[1:6]
c = Client(ip, username=user, password=pw, ssl=False, auth='ntlm')

ps = fr'''
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Continue'
New-Item -Path C:\nv -ItemType Directory -Force | Out-Null

Write-Host '[1/6] Wipe every NVIDIA oem driver package' -Fore Cyan
# 不靠 pnputil 输出 grep（中英文格式飘忽）— 直接走 CIM Win32_PnPSignedDriver
# 拿到所有 NVIDIA driver 的 InfName，pnputil /delete-driver 强卸。
$nvInfs = Get-CimInstance Win32_PnPSignedDriver -EA 0 |
    Where-Object {{ $_.Manufacturer -match 'NVIDIA' -or $_.Description -match 'NVIDIA' }} |
    Select-Object -ExpandProperty InfName -Unique |
    Where-Object {{ $_ -match '^oem\d+\.inf$' }}
foreach ($inf in $nvInfs) {{
    Write-Host "  delete $inf"
    pnputil /delete-driver $inf /uninstall /force 2>&1 | Out-Null
}}
"  removed $(@($nvInfs).Count) packages"

# memory project_grid_driver_partial：之前装一半留下 nvlddmkm.sys 缺 +
# INF 在 的状态，下次 installer 看到同版本 INF skip 拷贝，永远修不好。
# 强制把 NVIDIA system32 残留 sys/dll 全清，让 installer 必须从头来。
Write-Host '  scrub C:\Windows\System32 NVIDIA leftovers'
$drv = 'C:\Windows\System32\drivers'
$sys32 = 'C:\Windows\System32'
$pats = @('nvlddmkm.sys','nvkflt.sys','nvvad*.sys','nvgpu*.sys',
          'nvapi*.dll','nvcuda*.dll','nvml*.dll','nvopencl*.dll',
          'nvwgf2um*.dll','nvd3dum*.dll','nvoptix*.dll')
foreach ($p in $pats) {{
    Get-ChildItem -Path $drv,$sys32 -Filter $p -EA 0 | ForEach-Object {{
        try {{ Remove-Item $_.FullName -Force -EA Stop }} catch {{}}
    }}
}}

Write-Host '[2/6] Remove NVIDIA PCI devices (current + phantom)' -Fore Cyan
$env:DEVMGR_SHOW_NONPRESENT_DEVICES = '1'
Get-PnpDevice | Where-Object {{ $_.InstanceId -like 'PCI\VEN_10DE*' }} |
    ForEach-Object {{
        Write-Host "  remove $($_.InstanceId)"
        pnputil /remove-device $_.InstanceId /force 2>&1 | Out-Null
    }}

Write-Host '[3/6] Uninstall any NVIDIA user-space packages' -Fore Cyan
Get-Package | Where-Object {{ $_.Name -like '*NVIDIA*' }} |
    ForEach-Object {{
        Write-Host "  remove $($_.Name)"
        $_ | Uninstall-Package -Force -EA SilentlyContinue | Out-Null
    }}

Write-Host '[3.5/6] Kill any leftover installer / setup processes' -Fore Cyan
# 上一次跑卡死/没退干净时，C:\nv\553.24.exe 自解压器或它解到
# C:\NVIDIA\... 的 setup.exe 还会握着 553.24.exe 文件锁，导致下一步
# Invoke-WebRequest -OutFile 写不进去（"being used by another process"）。
Get-Process -EA 0 | Where-Object {{
    $_.Path -and ($_.Path -eq 'C:\nv\553.24.exe' -or
                  $_.Path -like 'C:\NVIDIA\*' -or
                  $_.Name -in @('setup','setup.tmp','installer','nvi'))
}} | ForEach-Object {{
    Write-Host "  kill $($_.Name) pid=$($_.Id)"
    $_ | Stop-Process -Force -EA 0
}}
Start-Sleep -Seconds 2
Remove-Item C:\nv\553.24.exe -Force -EA 0

Write-Host '[4/6] Pull 538.33 installer (legacy URL {base}/553.24.exe)' -Fore Cyan
Invoke-WebRequest "{base}/553.24.exe" -OutFile C:\nv\553.24.exe -UseBasicParsing
"  $((Get-Item C:\nv\553.24.exe).Length) bytes"

Write-Host '[5/6] Run 538.33 silent install (-s -clean -noreboot)' -Fore Cyan
$p = Start-Process C:\nv\553.24.exe -ArgumentList '-s','-clean','-noreboot' -Wait -PassThru
"  installer exit code: $($p.ExitCode)"

# 实测：GRID 538.33 silent install 在 fresh LTSC 上 self-extract 阶段
# 直接退 -436207360（连 setup.log 都不生成），原因不明（疑似 InstallShield
# runtime 缺 / SmartScreen 阻断）。用 pnputil 直接装 INF 作 fallback —
# host 端预解压 Display.Driver/ 打成 zip 给 guest 拉，绕过 setup.exe。
if ($p.ExitCode -ne 0 -or -not (Test-Path 'C:\Windows\System32\drivers\nvlddmkm.sys')) {{
    Write-Host '  !! setup.exe failed — falling back to pnputil /add-driver' -Fore Yellow
    Invoke-WebRequest "{base}/553.24-display-driver.zip" `
        -OutFile C:\nv\553.24-dd.zip -UseBasicParsing
    "  zip: $((Get-Item C:\nv\553.24-dd.zip).Length) bytes"
    Remove-Item C:\nv\553.24-dd -Recurse -Force -EA 0
    Expand-Archive C:\nv\553.24-dd.zip -DestinationPath C:\nv\553.24-dd -Force
    $infs = Get-ChildItem 'C:\nv\553.24-dd\Display.Driver\*.inf'
    "  found $($infs.Count) INF files"
    foreach ($inf in $infs) {{
        Write-Host "  pnputil /add-driver $($inf.Name) /install"
        & pnputil /add-driver $inf.FullName /install 2>&1 | Out-Host
    }}
}}

Write-Host '[5.5/6] Block Windows Update from replacing the NVIDIA driver' -Fore Cyan
# Without this, WU silently swaps GRID 538.33 → GeForce DCH 32.0.15.6094
# (post-2024-08-14 build) which trips NVIDIA anti-VM and the device goes
# back to Error 43.
#   ExcludeWUDriversInQualityUpdate=1 = WU 永不下 driver 包
#   SearchOrderConfig=0                = pnputil 也不查 WU
$wukey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
New-Item -Path $wukey -Force | Out-Null
Set-ItemProperty -Path $wukey -Name 'ExcludeWUDriversInQualityUpdate' -Type DWord -Value 1
$dskey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching'
New-Item -Path $dskey -Force | Out-Null
Set-ItemProperty -Path $dskey -Name 'SearchOrderConfig' -Type DWord -Value 0
"  policies set: ExcludeWUDriversInQualityUpdate=1, SearchOrderConfig=0"

Write-Host '[6/6] Verify driver bound' -Fore Cyan
Get-CimInstance Win32_VideoController | Format-Table Name, DriverVersion, Status, ConfigManagerErrorCode -AutoSize | Out-String

{reboot}
'''
out, streams, _ = c.execute_ps(ps)
print(out)
for e in (streams.error or []):
    print(f'[err] {e}', file=sys.stderr)
PYEOF
