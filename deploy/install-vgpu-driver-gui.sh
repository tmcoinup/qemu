#!/usr/bin/env bash
#
# install-vgpu-driver-gui.sh — branch-matched GRID driver via AutoLogon+RunOnce。
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
#   - guest WinRM 通；凭据仅通过运行时环境提供
#   - host/guest 版本必须命中 lib/vgpu-driver-assets.sh 的精确审核映射
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
# shellcheck source=lib/g11-python-runtime.sh
source ./lib/g11-python-runtime.sh
export G11_PYTHON_RUNTIME_INSTALLER="$PWD/host/install-g11-python-runtime.sh"
vm_storage_init

VM_ID=${VM_ID:-1}
IP_OVERRIDE=""
GUEST_USER=${GUEST_USER:-Administrator}
GUEST_PASS=${GUEST_PASS:-}
WINRM_PORT=5985
LAB_USERNET=0
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
        --winrm-port) WINRM_PORT="$2"; shift 2 ;;
        --lab-usernet) LAB_USERNET=1; shift ;;
        --clean-existing) CLEAN_EXISTING=1; shift ;;
        -h|--help)    sed -n '3,18p' "$0"; exit 0 ;;
        *.*.*.*)      IP_OVERRIDE="$1"; shift ;;
        [0-9]*)       VM_ID="$1"; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [[ ! "$WINRM_PORT" =~ ^[1-9][0-9]*$ ]] || ((WINRM_PORT > 65535)); then
    echo "--winrm-port 必须是 1..65535" >&2
    exit 2
fi
(( ${#GUEST_PASS} >= 6 && ${#GUEST_PASS} <= 64 )) &&
        [[ "$GUEST_PASS" != *$'\r'* && "$GUEST_PASS" != *$'\n'* ]] || {
    echo "GUEST_PASS 必须通过安全运行时环境提供（6..64 字符）" >&2
    exit 2
}

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
VGPU_DRIVER_INSTALL_BACKEND=""
vgpu_require_safe_driver_install_topology "$VM_ID"
case "$VGPU_DRIVER_INSTALL_BACKEND" in
    windowed) CONSOLE_GUARD_POLICY=Required ;;
    headless) CONSOLE_GUARD_POLICY=Offline ;;
    *)
        echo "[gui-install] unsafe/unknown driver-install backend" >&2
        exit 1
        ;;
esac
vgpu_verify_driver_assets exe

DRIVER_ASSET=$VGPU_SELECTED_DRIVER_EXE_NAME
DRIVER_SHA256=${VGPU_SELECTED_DRIVER_EXE_SHA256^^}
DRIVER_VERSION=$VGPU_SELECTED_DRIVER_VERSION
DRIVER_BRANCH=$VGPU_SELECTED_DRIVER_BRANCH
DRIVER_LABEL=$VGPU_SELECTED_DRIVER_LABEL
RUNONCE_INSTALLER_SHA256=${VGPU_SELECTED_DRIVER_SETUP_SHA256^^}
PAYLOAD_ASSET=""
PAYLOAD_SHA256=""
if [[ "$DRIVER_BRANCH" == R580 ]]; then
    payload_info=$(vgpu_prepare_selected_driver_payload) || exit
    IFS=$'\t' read -r payload_path PAYLOAD_SHA256 <<<"$payload_info"
    PAYLOAD_ASSET=${payload_path##*/}
    PAYLOAD_SHA256=${PAYLOAD_SHA256^^}
    [[ "$PAYLOAD_ASSET" == "$VGPU_SELECTED_DRIVER_PAYLOAD_ARCHIVE_NAME" &&
       "$PAYLOAD_SHA256" =~ ^[0-9A-F]{64}$ ]] || {
        echo "[gui-install] invalid prepared R580 payload metadata" >&2
        exit 1
    }
fi

if ((LAB_USERNET)); then
    [[ -z "$IP_OVERRIDE" || "$IP_OVERRIDE" == 127.0.0.1 ]] || {
        echo "[gui-install] --lab-usernet 只接受 localhost WinRM endpoint" >&2
        exit 2
    }
    IP=127.0.0.1
    HOST_BASE_URL=http://127.0.0.1:8080
    BASE_URL=http://10.0.2.2:8080
else
    IP=$(vgpu_resolve_bound_guest_ip "$VM_ID" "$IP_OVERRIDE") || exit
    HOST_IP=$(ip -4 -o addr show br0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    [[ -n "$HOST_IP" ]] || HOST_IP="192.168.30.127"
    HOST_BASE_URL="http://${HOST_IP}:8080"
    BASE_URL=$HOST_BASE_URL
fi

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
RUNONCE_SHA256=$(sha256sum "$PWD/guest/install-driver-runonce.ps1" | awk '{print toupper($1)}')

http_assets=( "$DRIVER_ASSET" install-driver-runonce.ps1 )
[[ -z "$PAYLOAD_ASSET" ]] || http_assets+=( "$PAYLOAD_ASSET" )
for asset in "${http_assets[@]}"; do
    if ! curl -sfI "$HOST_BASE_URL/$asset" >/dev/null 2>&1; then
        echo "[gui-install] !! $HOST_BASE_URL/$asset not reachable — start server.py" >&2
        exit 1
    fi
done

echo "[gui-install] stack=${DRIVER_BRANCH}/${DRIVER_LABEL} guest=${IP}:${WINRM_PORT} timeout=${TIMEOUT_INSTALL}s console=${CONSOLE_GUARD_POLICY}"
echo
WINRM_PYTHON=$(g11_python_resolve pypsrp) || exit 1

if [[ "$VGPU_SELECTED_DRIVER_NEEDS_R535_MONITOR" == 1 ]]; then
    invalidate_monitor_sync_marker
else
    echo "[gui-install] R580: skip R535 monitor/NV_Modes marker invalidation"
fi

# The compatibility installer historically repaired partial installs by
# removing every published NVIDIA package/device and stale System32 payload
# first.  Keep that behavior behind an explicit internal flag, but never run
# setup.exe or pnputil /add-driver from WinRM session 0: pnputil is used here
# only to remove stale packages/devices, and guarded RunOnce remains the only
# install path.
if (( CLEAN_EXISTING )); then
    echo "[0/3] clean existing/partial NVIDIA packages before guarded reinstall"
    GUEST_PASS_VALUE=$GUEST_PASS "$WINRM_PYTHON" - "$IP" "$GUEST_USER" "$WINRM_PORT" <<'PYEOF'
import os
import sys
from pypsrp.client import Client

ip, user, port = sys.argv[1:4]
c = Client(ip, username=user, password=os.environ['GUEST_PASS_VALUE'],
           ssl=False, auth='ntlm', port=int(port))
ps = r'''
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Continue'
New-Item -Path C:\nv -ItemType Directory -Force | Out-Null

Write-Host '[clean 1/4] published and offline NVIDIA display packages' -Fore Cyan
$activeNvInfs = @(Get-CimInstance Win32_PnPSignedDriver -EA 0 |
    Where-Object { $_.Manufacturer -match 'NVIDIA' -or
                   $_.Description -match 'NVIDIA' } |
    Select-Object -ExpandProperty InfName -Unique |
    Where-Object { $_ -match '^oem\d+\.inf$' })
# Win32_PnPSignedDriver only reports packages bound to a current/phantom
# device.  A previous GRID package can remain unused in Driver Store and later
# win rank selection after reboot, so enumerate DISM's complete online store as
# well.  This is the exact case seen during the R535 -> R580 migration test.
$offlineNvInfs = @(Get-WindowsDriver -Online -All -EA 0 |
    Where-Object { $_.ProviderName -match '^NVIDIA' -and
                   $_.ClassName -eq 'Display' } |
    ForEach-Object { [IO.Path]::GetFileName([string]$_.Driver) } |
    Where-Object { $_ -match '^oem\d+\.inf$' })
$nvInfs = @($activeNvInfs + $offlineNvInfs | Sort-Object -Unique)
foreach ($inf in $nvInfs) {
    Write-Host "  delete $inf"
    pnputil /delete-driver $inf /uninstall /force 2>&1 | Out-Null
}
$remainingNvInfs = @(Get-WindowsDriver -Online -All -EA 0 |
    Where-Object { $_.ProviderName -match '^NVIDIA' -and
                   $_.ClassName -eq 'Display' } |
    ForEach-Object { [IO.Path]::GetFileName([string]$_.Driver) } |
    Where-Object { $_ -match '^oem\d+\.inf$' } |
    Sort-Object -Unique)
if ($remainingNvInfs.Count -ne 0) {
    throw "NVIDIA display packages remain in Driver Store: $($remainingNvInfs -join ',')"
}
Write-Host "  removed $(@($nvInfs).Count) active/offline packages"

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
    $_.Path -and ($_.Path -eq 'C:\nv\g11-grid-driver.exe' -or
                  $_.Path -eq 'C:\nv\r580-payload\setup.exe' -or
                  $_.Path -eq 'C:\nv\553.24.exe' -or
                  $_.Path -like 'C:\NVIDIA\*' -or
                  $_.Name -in @('setup','setup.tmp','installer','nvi'))
} | ForEach-Object {
    Write-Host "  stop stale $($_.Name) pid=$($_.Id)"
    $_ | Stop-Process -Force -EA 0
}
Start-Sleep -Seconds 2
Remove-Item C:\nv\553.24.exe -Force -EA 0
Remove-Item C:\nv\g11-grid-driver.exe -Force -EA 0
Remove-Item C:\nv\r580-payload -Recurse -Force -EA 0
Remove-Item C:\nv\installer-logs -Recurse -Force -EA 0
Remove-Item C:\nv\drv-stage.flag -Force -EA 0

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
Write-Output 'G11_NVIDIA_PRE_CLEAN_DONE'
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
GUEST_PASS_VALUE=$GUEST_PASS "$WINRM_PYTHON" - \
    "$IP" "$GUEST_USER" "$WINRM_PORT" "$BASE_URL" "$DRIVER_ASSET" \
    "$DRIVER_SHA256" "$DRIVER_VERSION" "$DRIVER_BRANCH" "$RUNONCE_SHA256" \
    "$PAYLOAD_ASSET" "$PAYLOAD_SHA256" "$RUNONCE_INSTALLER_SHA256" \
    "$CONSOLE_GUARD_POLICY" "$TIMEOUT_INSTALL" <<'PYEOF'
import os
import sys
from pypsrp.client import Client

ip, user, port, base, asset, source_sha, expected_version, branch, runonce_sha, \
    payload_asset, payload_sha, installer_sha, console_policy, timeout = sys.argv[1:15]
if console_policy not in ('Required', 'Offline'):
    raise SystemExit('invalid console guard policy')
pw = os.environ['GUEST_PASS_VALUE']
c = Client(ip, username=user, password=pw, ssl=False, auth='ntlm',
           port=int(port), operation_timeout=int(timeout),
           read_timeout=int(timeout) + 120)
ps = fr"""
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'
New-Item -Path C:\nv -ItemType Directory -Force | Out-Null

$payloadArchive = ''
if ('{branch}' -eq 'R580') {{
    $payloadArchive = 'C:\nv\g11-grid-payload.zip'
    if (-not (Test-Path -LiteralPath $payloadArchive) -or
            (Get-FileHash -LiteralPath $payloadArchive -Algorithm SHA256).Hash -cne '{payload_sha}') {{
        Write-Host '  pulling reviewed R580 inner payload cache...'
        Invoke-WebRequest '{base}/{payload_asset}' -OutFile $payloadArchive -UseBasicParsing
    }}
    $actualPayloadSha = (Get-FileHash -LiteralPath $payloadArchive -Algorithm SHA256).Hash
    if ($actualPayloadSha -cne '{payload_sha}') {{
        throw "downloaded R580 payload SHA-256 mismatch: $actualPayloadSha"
    }}
    $payloadRoot = 'C:\nv\r580-payload'
    Remove-Item -LiteralPath $payloadRoot -Recurse -Force -EA 0
    Write-Host '  expanding reviewed R580 inner setup payload...'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($payloadArchive, $payloadRoot)
    $installer = Join-Path $payloadRoot 'setup.exe'
}} else {{
    $installer = 'C:\nv\g11-grid-driver.exe'
    if (-not (Test-Path -LiteralPath $installer) -or
            (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash -cne '{source_sha}') {{
        Write-Host '  pulling reviewed R535 package...'
        Invoke-WebRequest '{base}/{asset}' -OutFile $installer -UseBasicParsing
    }}
}}
$actualInstallerSha = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash
if ($actualInstallerSha -cne '{installer_sha}') {{
    throw "selected GRID setup.exe SHA-256 mismatch: $actualInstallerSha"
}}
$installerSignature = Get-AuthenticodeSignature -LiteralPath $installer
if ($installerSignature.Status -ne 'Valid' -or
        $null -eq $installerSignature.SignerCertificate -or
        $installerSignature.SignerCertificate.Subject -notmatch 'NVIDIA Corporation') {{
    throw "selected GRID setup.exe production signature is invalid"
}}

Invoke-WebRequest '{base}/install-driver-runonce.ps1' `
    -OutFile C:\nv\install-driver-runonce.ps1 -UseBasicParsing
$actualRunOnceSha = (Get-FileHash -LiteralPath C:\nv\install-driver-runonce.ps1 `
    -Algorithm SHA256).Hash
if ($actualRunOnceSha -cne '{runonce_sha}') {{
    throw "RunOnce source SHA-256 mismatch: $actualRunOnceSha"
}}

Remove-Item 'C:\nv\drv-done.flag' -Force -EA 0
Remove-Item 'C:\nv\drv-done.flag.tmp' -Force -EA 0
Remove-Item 'C:\nv\drv-stage.flag' -Force -EA 0

$adminPass = [Environment]::GetEnvironmentVariable(
    'G11_ARM_ADMIN_PASS', 'Process')
$runOnce = [ScriptBlock]::Create(
    [IO.File]::ReadAllText('C:\nv\install-driver-runonce.ps1'))
& $runOnce -InstallerPath $installer -AdminPass $adminPass `
    -DriverBranch '{branch}' -ExpectedInstallerSha256 '{installer_sha}' `
    -ExpectedSourcePackageSha256 '{source_sha}' `
    -PayloadArchivePath $payloadArchive -ExpectedPayloadSha256 '{payload_sha}' `
    -ExpectedDriverVersion '{expected_version}' `
    -ConsoleGuardPolicy '{console_policy}' | Out-Host
$adminPass = $null
"  arm script returned (guest is rebooting)"
"""
out, streams, had_errors = c.execute_ps(
    ps, environment={'G11_ARM_ADMIN_PASS': pw})
print(out)
for e in (streams.error or []): print(f'[err] {e}', file=sys.stderr)
if had_errors or streams.error:
    raise SystemExit('guest refused to arm the guarded GRID RunOnce')
PYEOF

# ── Step 2: wait WinRM 回来 ────────────────────────────────────────────
echo
echo "[2/3] wait guest reboot + AutoLogon + RunOnce setup.exe + flag..."

# 先等 WinRM 短暂掉线（reboot 开始）
for _ in $(seq 1 10); do
    nc -z -w 2 "$IP" "$WINRM_PORT" 2>/dev/null || break
    sleep 2
done
echo "  guest 已断线（reboot 中）"

# 等 WinRM 回来
deadline=$(( $(date +%s) + TIMEOUT_INSTALL ))
while (( $(date +%s) < deadline )); do
    if nc -z -w 2 "$IP" "$WINRM_PORT" 2>/dev/null; then
        # NTLM round-trip 才算真 ready
        if GUEST_PASS_VALUE=$GUEST_PASS "$WINRM_PYTHON" - \
                "$IP" "$GUEST_USER" "$WINRM_PORT" <<'PYEOF' >/dev/null 2>&1
import os
from pypsrp.client import Client
import sys
try:
    Client(sys.argv[1], username=sys.argv[2],
           password=os.environ['GUEST_PASS_VALUE'], ssl=False, auth='ntlm',
           port=int(sys.argv[3])) \
        .execute_ps('Get-Date')
    sys.exit(0)
except Exception:
    sys.exit(1)
PYEOF
        then
            echo "  WinRM ready, AutoLogon 应已触发，setup.exe 在 user session 跑"
            break
        fi
    fi
    sleep 5
done

# ── Step 3: poll guarded installer receipt ─────────────────────────────
echo
printf '[3/3] poll C:\\nv\\drv-done.flag (%s signed installer receipt)\n' "$DRIVER_BRANCH"
RECEIPT=""
deadline=$(( $(date +%s) + TIMEOUT_INSTALL ))
while (( $(date +%s) < deadline )); do
    RECEIPT=$(GUEST_PASS_VALUE=$GUEST_PASS "$WINRM_PYTHON" - \
        "$IP" "$GUEST_USER" "$WINRM_PORT" <<'PYEOF'
import os
from pypsrp.client import Client
import sys
try:
    c = Client(sys.argv[1], username=sys.argv[2],
               password=os.environ['GUEST_PASS_VALUE'], ssl=False, auth='ntlm',
               port=int(sys.argv[3]))
    out, _, _ = c.execute_ps('if (Test-Path C:\\\\nv\\\\drv-done.flag) { Get-Content C:\\\\nv\\\\drv-done.flag } else { \"\" }')
    print((out or '').strip())
except Exception:
    print('')
PYEOF
)
    [[ "$RECEIPT" == *'package_signature='* && "$RECEIPT" == *'console_safe='* ]] && break
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
RECEIPT_BRANCH=$(sed -n 's/^branch=//p' <<<"$RECEIPT")
RECEIPT_DRIVER=$(sed -n 's/^expected_driver=//p' <<<"$RECEIPT")
SOURCE_PACKAGE_SHA256=$(sed -n 's/^source_package_sha256=//p' <<<"$RECEIPT")
INSTALLER_SHA256=$(sed -n 's/^installer_sha256=//p' <<<"$RECEIPT")
RECEIPT_PAYLOAD_SHA256=$(sed -n 's/^payload_sha256=//p' <<<"$RECEIPT")
PACKAGE_SIGNATURE=$(sed -n 's/^package_signature=//p' <<<"$RECEIPT")
DISPLAY_MODE=$(sed -n 's/^display=//p' <<<"$RECEIPT")
CONSOLE_BYTES=$(sed -n 's/^console_bytes=//p' <<<"$RECEIPT")
CONSOLE_REQUIRED=$(sed -n 's/^console_required=//p' <<<"$RECEIPT")
CONSOLE_SAFE=$(sed -n 's/^console_safe=//p' <<<"$RECEIPT")
RECEIPT_VALID=1
[[ "$INSTALLER_EXIT" =~ ^-?[0-9]+$ ]] || RECEIPT_VALID=0
[[ "$RECEIPT_BRANCH" == "$DRIVER_BRANCH" ]] || RECEIPT_VALID=0
[[ "$RECEIPT_DRIVER" == "$DRIVER_VERSION" ]] || RECEIPT_VALID=0
[[ "$SOURCE_PACKAGE_SHA256" == "$DRIVER_SHA256" ]] || RECEIPT_VALID=0
[[ "$INSTALLER_SHA256" == "$RUNONCE_INSTALLER_SHA256" ]] || RECEIPT_VALID=0
[[ "$PACKAGE_SIGNATURE" == Valid ]] || RECEIPT_VALID=0
[[ "$DISPLAY_MODE" =~ ^[0-9]+x[0-9]+$ ]] || RECEIPT_VALID=0
[[ "$CONSOLE_BYTES" =~ ^[0-9]+$ ]] || RECEIPT_VALID=0
[[ "$CONSOLE_REQUIRED" == 0 || "$CONSOLE_REQUIRED" == 1 ]] || RECEIPT_VALID=0
[[ "$CONSOLE_SAFE" == 0 || "$CONSOLE_SAFE" == 1 ]] || RECEIPT_VALID=0
if [[ "$DRIVER_BRANCH" == R535 ]]; then
    if [[ "$VGPU_DRIVER_INSTALL_BACKEND" == headless ]]; then
        [[ "$RECEIPT_PAYLOAD_SHA256" == none && "$INSTALLER_EXIT" == 0 &&
           "$DISPLAY_MODE" == 0x0 && "$CONSOLE_BYTES" == 0 &&
           "$CONSOLE_REQUIRED" == 0 && "$CONSOLE_SAFE" == 1 ]] || RECEIPT_VALID=0
    else
        [[ "$RECEIPT_PAYLOAD_SHA256" == none && "$INSTALLER_EXIT" == 0 &&
           "$DISPLAY_MODE" == 1920x1080 && "$CONSOLE_BYTES" == 8294400 &&
           "$CONSOLE_REQUIRED" == 1 && "$CONSOLE_SAFE" == 1 ]] || RECEIPT_VALID=0
    fi
else
    [[ "$RECEIPT_PAYLOAD_SHA256" == "$PAYLOAD_SHA256" &&
       ( "$INSTALLER_EXIT" == 0 || "$INSTALLER_EXIT" == 1 ) &&
       "$DISPLAY_MODE" == 0x0 && "$CONSOLE_BYTES" == 0 &&
       "$CONSOLE_REQUIRED" == 0 && "$CONSOLE_SAFE" == 1 ]] || RECEIPT_VALID=0
fi
echo "[gui-install] receipt: branch=${RECEIPT_BRANCH:-invalid} installer=${INSTALLER_EXIT:-invalid} signature=${PACKAGE_SIGNATURE:-invalid} display=${DISPLAY_MODE:-invalid} page_safe=${CONSOLE_SAFE:-invalid} console=${CONSOLE_GUARD_POLICY}"

# ── verify active signed PnP driver and runtime code-integrity state ────
CLEANUP_ALLOWED=0
if ((RECEIPT_VALID)); then
    CLEANUP_ALLOWED=1
fi
GUEST_PASS_VALUE=$GUEST_PASS "$WINRM_PYTHON" - \
    "$IP" "$GUEST_USER" "$WINRM_PORT" "$DRIVER_VERSION" "$DRIVER_BRANCH" \
    "$CLEANUP_ALLOWED" "$KEEP_GUEST_INSTALLER" "$TIMEOUT_INSTALL" <<'PYEOF'
import json
import os
import sys
import time
from pypsrp.client import Client
ip, user, port, expected_version, branch, cleanup_allowed, keep_installer, \
    verification_timeout_text = sys.argv[1:9]
cleanup = cleanup_allowed == '1' and keep_installer == '0'
verification_timeout = int(verification_timeout_text)
if not 1 <= verification_timeout <= 3600:
    raise SystemExit('invalid signed-driver verification timeout')

ps = rf"""
$ErrorActionPreference = 'Stop'
$verified = $false
try {{
if (-not ('G11.RuntimeCodeIntegrity' -as [type])) {{
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace G11 {{
    public static class RuntimeCodeIntegrity {{
        [StructLayout(LayoutKind.Sequential)]
        private struct Info {{ public UInt32 Length; public UInt32 Options; }}
        [DllImport("ntdll.dll")]
        private static extern Int32 NtQuerySystemInformation(
            Int32 kind, ref Info value, UInt32 length, out UInt32 returned);
        public static UInt32 Query() {{
            Info value = new Info();
            value.Length = (UInt32)Marshal.SizeOf(typeof(Info));
            UInt32 returned;
            Int32 status = NtQuerySystemInformation(
                103, ref value, value.Length, out returned);
            if (status < 0) {{ throw new InvalidOperationException(
                "NtQuerySystemInformation status=" + status); }}
            return value.Options;
        }}
    }}
}}
'@
}}

$video = @(Get-CimInstance Win32_VideoController -ErrorAction Stop |
    Where-Object {{ $_.PNPDeviceID -like 'PCI\VEN_10DE*' }})
if ($video.Count -ne 1) {{ throw "expected one NVIDIA display, got $($video.Count)" }}
$signed = @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop |
    Where-Object {{ $_.DeviceID -eq $video[0].PNPDeviceID }})
if ($signed.Count -ne 1) {{ throw "expected one NVIDIA signed-driver record, got $($signed.Count)" }}
$kernelService = @(Get-CimInstance Win32_SystemDriver -ErrorAction Stop |
    Where-Object {{ $_.Name -eq 'nvlddmkm' }})
if ($kernelService.Count -ne 1) {{
    throw "expected one nvlddmkm service, got $($kernelService.Count)"
}}
$kernelDriverPath = ([string]$kernelService[0].PathName).Trim('"')
$kernelDriverPath = $kernelDriverPath -replace '^\\SystemRoot', $env:SystemRoot
$kernelDriverPath = $kernelDriverPath -replace '^\\\?\?\\', ''
if (-not (Test-Path -LiteralPath $kernelDriverPath -PathType Leaf)) {{
    throw "active nvlddmkm service image is missing: $kernelDriverPath"
}}
$kernelSignature = Get-AuthenticodeSignature -LiteralPath $kernelDriverPath
if ($kernelSignature.Status -ne [Management.Automation.SignatureStatus]::Valid -or
        $null -eq $kernelSignature.SignerCertificate -or
        $kernelSignature.SignerCertificate.Subject -notmatch
            'NVIDIA Corporation|Microsoft Windows Hardware Compatibility Publisher') {{
    throw ("active nvlddmkm production signature is invalid: status={{0}} signer={{1}}" -f
        $kernelSignature.Status, $kernelSignature.SignerCertificate.Subject)
}}
$options = [G11.RuntimeCodeIntegrity]::Query()
$state = [ordered]@{{
    branch = '{branch}'
    name = [string]$video[0].Name
    version = [string]$video[0].DriverVersion
    error_code = [int]$video[0].ConfigManagerErrorCode
    driver_signed = [bool]$signed[0].IsSigned
    inf = [string]$signed[0].InfName
    signed_version = [string]$signed[0].DriverVersion
    kernel_driver_path = $kernelDriverPath
    kernel_driver_present = $true
    kernel_driver_running = ([string]$kernelService[0].State -eq 'Running')
    kernel_signature = [string]$kernelSignature.Status
    kernel_signer = [string]$kernelSignature.SignerCertificate.Subject
    code_integrity = [bool](($options -band 0x01) -ne 0)
    development_signatures = [bool](($options -band 0x02) -ne 0)
}}
if ($state.version -cne '{expected_version}' -or
        $state.signed_version -cne '{expected_version}') {{
    throw "active driver version mismatch: video=$($state.version) signed=$($state.signed_version)"
}}
if ($state.error_code -ne 0) {{ throw "NVIDIA ConfigManager error $($state.error_code)" }}
if (-not $state.driver_signed -or -not $state.kernel_driver_present -or
        -not $state.kernel_driver_running -or $state.kernel_signature -cne 'Valid') {{
    throw 'active NVIDIA package is not signed/complete'
}}
if (-not $state.code_integrity -or $state.development_signatures) {{
    throw "runtime kernel code-integrity state is unsafe: options=0x$($options.ToString('X'))"
}}
$verified = $true
}} finally {{
function Remove-G11RegistryValueIfPresent {{
    param([string]$LiteralPath, [string]$Name)
    if (-not (Test-Path -LiteralPath $LiteralPath)) {{ return }}
    $valueNames = @((Get-ItemProperty -LiteralPath $LiteralPath).PSObject.Properties.Name)
    if ($valueNames -contains $Name) {{
        # A timed-out WSMan request can still finish remotely while the host
        # opens its next verification runspace.  Treat an already-removed
        # value as success so concurrent cleanup remains idempotent.
        Remove-ItemProperty -LiteralPath $LiteralPath -Name $Name -Force `
            -ErrorAction SilentlyContinue
        $remainingNames = @((Get-ItemProperty -LiteralPath $LiteralPath).PSObject.Properties.Name)
        if ($remainingNames -contains $Name) {{
            throw "could not remove sensitive Winlogon value: $Name"
        }}
    }}
}}
function Remove-G11PathIfPresent {{
    param([string]$LiteralPath, [switch]$Recurse)
    if (-not (Test-Path -LiteralPath $LiteralPath)) {{ return }}
    if ($Recurse) {{
        Remove-Item -LiteralPath $LiteralPath -Recurse -Force `
            -ErrorAction SilentlyContinue
    }} else {{
        Remove-Item -LiteralPath $LiteralPath -Force `
            -ErrorAction SilentlyContinue
    }}
}}
$wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Remove-G11RegistryValueIfPresent $wl 'AutoAdminLogon'
Remove-G11RegistryValueIfPresent $wl 'DefaultUserName'
Remove-G11RegistryValueIfPresent $wl 'DefaultDomainName'
Remove-G11RegistryValueIfPresent $wl 'DefaultPassword'
Remove-G11RegistryValueIfPresent $wl 'AutoLogonCount'
if ($verified -and {'$true' if cleanup else '$false'}) {{
    Remove-G11PathIfPresent 'C:\nv\install-driver-runonce.ps1'
    Remove-G11PathIfPresent 'C:\nv\install-driver-runonce.cmd'
    Remove-G11PathIfPresent 'C:\nv\runonce-console.log'
    Remove-G11PathIfPresent 'C:\nv\drv-done.flag'
    Remove-G11PathIfPresent 'C:\nv\g11-grid-driver.exe'
    Remove-G11PathIfPresent 'C:\nv\g11-grid-payload.zip'
    Remove-G11PathIfPresent 'C:\nv\r580-payload' -Recurse
    Remove-G11PathIfPresent 'C:\nv\installer-logs' -Recurse
    Remove-G11PathIfPresent 'C:\nv\drv-stage.flag'
    Remove-G11PathIfPresent 'C:\nv\553.24.exe'
    Remove-G11PathIfPresent 'C:\nv\553.24-dd.zip'
    Remove-G11PathIfPresent 'C:\nv\553.24-dd' -Recurse
}}
}}

$wukey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
if (-not (Test-Path -LiteralPath $wukey)) {{
    New-Item -Path $wukey -Force -ErrorAction SilentlyContinue | Out-Null
}}
if (-not (Test-Path -LiteralPath $wukey)) {{
    throw 'could not create the Windows Update driver policy key'
}}
Set-ItemProperty -Path $wukey -Name 'ExcludeWUDriversInQualityUpdate' -Type DWord -Value 1
$dskey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching'
if (-not (Test-Path -LiteralPath $dskey)) {{
    New-Item -Path $dskey -Force -ErrorAction SilentlyContinue | Out-Null
}}
if (-not (Test-Path -LiteralPath $dskey)) {{
    throw 'could not create the driver-search policy key'
}}
Set-ItemProperty -Path $dskey -Name 'SearchOrderConfig' -Type DWord -Value 0
$state | ConvertTo-Json -Compress
"""

deadline = time.monotonic() + verification_timeout
last = ''
while time.monotonic() < deadline:
    try:
        # The guarded installer writes its receipt and then reboots.  A host
        # can observe the receipt during the five-second window immediately
        # before WinRM closes, so every verification attempt must tolerate a
        # transport reset and establish a fresh runspace after Windows returns.
        c = Client(ip, username=user,
                   password=os.environ['GUEST_PASS_VALUE'],
                   ssl=False, auth='ntlm', port=int(port),
                   operation_timeout=90, read_timeout=120)
        out, streams, had_errors = c.execute_ps(ps)
    except Exception as exc:
        last = f'{type(exc).__name__}: {exc}'
        time.sleep(5)
        continue
    last = (out or '').strip()
    if had_errors:
        errors = '; '.join(str(item) for item in streams.error)
        last = 'PowerShell: ' + (errors or 'reported an error without details')
        time.sleep(5)
        continue
    for line in reversed(last.splitlines()):
        line = line.strip()
        if line.startswith('{') and line.endswith('}'):
            state = json.loads(line)
            print('[gui-install] active: '
                  f"{state['branch']} {state['version']} Code {state['error_code']} "
                  f"signed={int(state['driver_signed'])} ci={int(state['code_integrity'])} "
                  f"development={int(state['development_signatures'])} inf={state['inf']}")
            raise SystemExit(0)
    time.sleep(5)
raise SystemExit('post-reboot signed driver verification failed: ' + last[-500:])
PYEOF

if (( RECEIPT_VALID == 0 )); then
    echo "[gui-install] !! 安装收据格式非法；已清 AutoLogon，保留安装器供排障" >&2
    exit 1
fi
if [[ "$DRIVER_BRANCH" == R535 && "$INSTALLER_EXIT" != 0 ]] ||
        [[ "$DRIVER_BRANCH" == R580 && "$INSTALLER_EXIT" != 0 &&
           "$INSTALLER_EXIT" != 1 ]]; then
    echo "[gui-install] !! GRID installer 退出码不在允许集合: $INSTALLER_EXIT" >&2
    exit 1
fi

if [[ "$DRIVER_BRANCH" == R535 ]]; then
    if [[ "$VGPU_DRIVER_INSTALL_BACKEND" == headless ]]; then
        echo "[gui-install] PASS: R535/GRID 538.33 signed / Code 0 / headless console isolated; offline page-safe sync required"
    else
        echo "[gui-install] PASS: R535/GRID 538.33 signed / Code 0 / page-safe 1920x1080"
    fi
else
    echo "[gui-install] PASS: R580/${DRIVER_LABEL} signed / Code 0 / runtime code integrity enforced"
fi
