#!/usr/bin/env bash
#
# setup-guest.sh — one-shot bootstrap for everything streaming-related
# inside a guest. Run this ONCE on a freshly-installed guest (after
# Windows install + WinRM enabled + initial vGPU bring-up). On every
# subsequent code update just rerun individual installers.
#
# What it does (in order):
#   1. Install vGPU GRID 538.33 driver       (install-vgpu-driver.sh)
#   2. Install ivshmem.sys driver            (install-ivshmem-driver.sh)
#   3. Install NvDisplayContainer Windows    (install-nv-service.sh)
#      service + nv_stream_relay + AudioSvcHost, set
#      DesktopWidth/Height registry keys (default 1920x1080)
#   4. Optional --with-guest-identity compatibility repair: vm.conf → guest
#      registry name/specs + RefreshGridNames task. The default host per-mdev
#      path skips this step.
#   5. 显示器默认由 QEMU/host 离线 EDID 同步负责，不向 guest 安装常驻组件。
#      只有显式 --online-monitor-rescue 时才执行一次 spoof-monitor.ps1 救援。
#
# After this finishes, on the host:
#     ./connect.sh <vm_id>
#
# Skip individual steps:
#     ./setup-guest.sh 1 --skip-vgpu       # already installed
#     ./setup-guest.sh 1 --skip-ivshmem
#     ./setup-guest.sh 1 --with-guest-identity # 可选旧 guest 注册表修复
#     ./setup-guest.sh 1 --with-nvapi-shim # 显式兼容回退；同时启用 guest identity
#     ./setup-guest.sh 1 --online-monitor-rescue --skip-vgpu --skip-license \
#       --skip-ivshmem --skip-service --skip-input  # 仅旧 WinRM guest 显示器救援
#
# Customize:
#     ./setup-guest.sh 1 --gpu-name "GeForce GTX 1050"
#     ./setup-guest.sh 1 --online-monitor-rescue --monitor samsung-s24f350 \
#       --skip-vgpu --skip-license --skip-ivshmem --skip-service --skip-input
#     # --monitor 只选择救援型号；没有 --online-monitor-rescue 时不会进 guest 执行
#
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
# shellcheck source=lib/vgpu-profiles.sh
source ./lib/vgpu-profiles.sh
# shellcheck source=lib/monitor-profiles.sh
source ./lib/monitor-profiles.sh
# shellcheck source=lib/vm-storage.sh
source ./lib/vm-storage.sh
monitor_profiles_validate
vm_storage_init

VM_ID=${VM_ID:-1}
IP_OVERRIDE=""
GPU_NAME_OVERRIDE="${GPU_NAME:-}"
MONITOR_PROFILE_OVERRIDE="${MONITOR_BRAND:-}"
INPUT_BRAND="${INPUT_BRAND:-rapoo-v303}"

SKIP_VGPU=0
SKIP_LICENSE=0
SKIP_IVSHMEM=0
SKIP_SERVICE=0
SKIP_STEALTH=1
# Guest-minimal default: per-VM NVIDIA Control Panel names come from the host
# vgpu_unlock [mdev."UUID"] override. System DLL replacement is opt-in only.
SKIP_NVAPI_SHIM=1
# 保持 guest 原始、干净：默认不复制/运行显示器脚本。virtio 从 QEMU 读 EDID；
# NVIDIA mdev 由 host 在关机状态离线刷新 Windows 自己的 EDID 缓存。
SKIP_MONITOR=1
SKIP_INPUT=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip)            IP_OVERRIDE="$2"; shift 2 ;;
        --skip-vgpu)     SKIP_VGPU=1; shift ;;
        --skip-license)  SKIP_LICENSE=1; shift ;;
        --skip-ivshmem)  SKIP_IVSHMEM=1; shift ;;
        --skip-service)  SKIP_SERVICE=1; shift ;;
        --skip-stealth)  SKIP_STEALTH=1; shift ;;
        --with-guest-identity) SKIP_STEALTH=0; shift ;;
        --skip-nvapi-shim) SKIP_NVAPI_SHIM=1; shift ;;
        --with-nvapi-shim) SKIP_NVAPI_SHIM=0; SKIP_STEALTH=0; shift ;;
        --skip-monitor)  SKIP_MONITOR=1; shift ;;
        --online-monitor-rescue) SKIP_MONITOR=0; shift ;;
        --skip-input)    SKIP_INPUT=1; shift ;;
        --input)         INPUT_BRAND="$2"; shift 2 ;;
        --gpu-name)      GPU_NAME_OVERRIDE="$2"; shift 2 ;;
        --monitor)       MONITOR_PROFILE_OVERRIDE="$2"; shift 2 ;;
        -h|--help)       sed -n '3,33p' "$0"; exit 0 ;;
        *.*.*.*)         IP_OVERRIDE="$1"; shift ;;
        [0-9]*)          VM_ID="$1"; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

# 新建 VM 的型号、PCI ID 和 advertised clocks 都从同一份 vm.conf 读取。
# 老配置缺少规格字段时按 GPU_PROFILE 从 catalog 回填；不重新随机。
conf=$(vm_storage_config_path "$VM_ID")
if [[ -r "$conf" ]]; then
    # shellcheck source=/dev/null
    source "$conf"
fi
configured_gpu_profile=${GPU_PROFILE:-gt1030_2gb}
configured_gpu_name=${GPU_NAME:-}
configured_gpu_core_mhz=${GPU_CORE_MHZ:-}
configured_gpu_boost_mhz=${GPU_BOOST_MHZ:-}
configured_gpu_memory_mhz=${GPU_MEMORY_MHZ:-}
configured_gpu_memory_bus_bits=${GPU_MEMORY_BUS_BITS:-}
configured_gpu_memory_bandwidth_mbps=${GPU_MEMORY_BANDWIDTH_MBPS:-}
configured_gpu_vram_mb=${GPU_VRAM_MB:-}
configured_gpu_vbios=${GPU_VBIOS:-}
configured_gpu_memory_type_nvapi=${GPU_MEMORY_TYPE_NVAPI:-}
configured_gpu_memory_maker_nvapi=${GPU_MEMORY_MAKER_NVAPI:-}
configured_gpu_cuda_cores=${GPU_CUDA_CORES:-}
configured_gpu_shader_subpipes=${GPU_SHADER_SUBPIPES:-}
configured_gpu_rop_count=${GPU_ROP_COUNT:-}
configured_gpu_tmu_count=${GPU_TMU_COUNT:-}
configured_gpu_architecture=${GPU_ARCHITECTURE:-}
configured_gpu_implementation=${GPU_IMPLEMENTATION:-}
configured_gpu_chip_revision=${GPU_CHIP_REVISION:-}
configured_gpu_pcie_width=${GPU_PCIE_WIDTH:-}
vgpu_profile_load "$configured_gpu_profile"
GPU_NAME=${configured_gpu_name:-$GPU_NAME}
GPU_CORE_MHZ=${configured_gpu_core_mhz:-$GPU_CORE_MHZ}
GPU_BOOST_MHZ=${configured_gpu_boost_mhz:-$GPU_BOOST_MHZ}
GPU_MEMORY_MHZ=${configured_gpu_memory_mhz:-$GPU_MEMORY_MHZ}
GPU_MEMORY_BUS_BITS=${configured_gpu_memory_bus_bits:-$GPU_MEMORY_BUS_BITS}
GPU_MEMORY_BANDWIDTH_MBPS=${configured_gpu_memory_bandwidth_mbps:-$GPU_MEMORY_BANDWIDTH_MBPS}
GPU_VRAM_MB=${configured_gpu_vram_mb:-$GPU_VRAM_MB}
GPU_VBIOS=${configured_gpu_vbios:-$GPU_VBIOS}
GPU_MEMORY_TYPE_NVAPI=${configured_gpu_memory_type_nvapi:-$GPU_MEMORY_TYPE_NVAPI}
GPU_MEMORY_MAKER_NVAPI=${configured_gpu_memory_maker_nvapi:-$GPU_MEMORY_MAKER_NVAPI}
GPU_CUDA_CORES=${configured_gpu_cuda_cores:-$GPU_CUDA_CORES}
GPU_SHADER_SUBPIPES=${configured_gpu_shader_subpipes:-$GPU_SHADER_SUBPIPES}
GPU_ROP_COUNT=${configured_gpu_rop_count:-$GPU_ROP_COUNT}
GPU_TMU_COUNT=${configured_gpu_tmu_count:-$GPU_TMU_COUNT}
GPU_ARCHITECTURE=${configured_gpu_architecture:-$GPU_ARCHITECTURE}
GPU_IMPLEMENTATION=${configured_gpu_implementation:-$GPU_IMPLEMENTATION}
GPU_CHIP_REVISION=${configured_gpu_chip_revision:-$GPU_CHIP_REVISION}
GPU_PCIE_WIDTH=${configured_gpu_pcie_width:-$GPU_PCIE_WIDTH}
[[ -n "$GPU_NAME_OVERRIDE" ]] && GPU_NAME=$GPU_NAME_OVERRIDE
: "${GPU_VRAM_MB:=2048}"
case "$GPU_VRAM_MB" in
    1024|2048) ;;
    *)
        echo "[setup-guest] vGPU identity 只允许目录中的 1024/2048MB，当前 ${GPU_VRAM_MB}MB" >&2
        exit 2
        ;;
esac
if [[ "$GPU_VBIOS" != 'Version '* ]]; then
    echo "[setup-guest] GPU_VBIOS 必须以 'Version ' 开头: $GPU_VBIOS" >&2
    exit 2
fi
GPU_VBIOS_VERSION=${GPU_VBIOS#Version }
if [[ ! "$GPU_VBIOS_VERSION" =~ ^[0-9A-Fa-f]{2}(\.[0-9A-Fa-f]{2}){4}$ ]]; then
    echo "[setup-guest] GPU_VBIOS 必须包含五段十六进制版本号: $GPU_VBIOS" >&2
    exit 2
fi

# 显示器目录是唯一规格来源。新 vm.conf 已持久化 profile + serial；老配置
# 稳定回退到 Dell P2419H，并以 VM UUID 派生 serial，重复救援不会漂移。
configured_monitor_profile="${MONITOR_PROFILE:-}"
configured_monitor_serial="${MONITOR_SERIAL:-}"
if [[ -n "$MONITOR_PROFILE_OVERRIDE" ]]; then
    monitor_profile_load "$MONITOR_PROFILE_OVERRIDE"
    if [[ "$MONITOR_PROFILE_OVERRIDE" == "$configured_monitor_profile" &&
          -n "$configured_monitor_serial" ]]; then
        MONITOR_SERIAL=$configured_monitor_serial
    else
        MONITOR_SERIAL=$(monitor_profile_generate_serial \
            "$MONITOR_SERIAL_PREFIX" "${VM_UUID:-vm${VM_ID}}-${MONITOR_PROFILE}")
    fi
else
    monitor_profile_load "${configured_monitor_profile:-dell-p2419h}"
    MONITOR_SERIAL="${configured_monitor_serial:-$(monitor_profile_generate_serial \
        "$MONITOR_SERIAL_PREFIX" "${VM_UUID:-vm${VM_ID}}-${MONITOR_PROFILE}")}"
fi

ip_arg=""
[[ -n "$IP_OVERRIDE" ]] && ip_arg="--ip $IP_OVERRIDE"

# Always make sure the host file server is up (most installers + irm|iex need it)
if ! ss -tln 2>/dev/null | grep -q ':8080 '; then
    echo "[setup-guest] starting server.py on :8080 → $STAGE_DIR"
    nohup python3 "$(dirname "$(readlink -f "$0")")/server.py" \
        > /tmp/nv-http.log 2>&1 &
    sleep 1
fi

step() { echo; echo "════════════════════ $* ════════════════════"; }

if [[ $SKIP_VGPU -eq 0 ]]; then
    step "[1/7] vGPU 16.x driver (538.33; legacy staging name 553.24)"
    ./install-vgpu-driver.sh "$VM_ID" $ip_arg --no-reboot || {
        echo "[setup-guest] !! vGPU driver silent install 失败"
        echo "  这是已知 NVIDIA GRID 538.33 quirk：silent + vGPU mdev 不 work，必须 GUI 装。"
        echo "  → RDP 进 guest，双击 C:\\nv\\553.24.exe 选 Express install。"
        echo "  → 装好 reboot 后 shutdown，再运行 ./deploy/scripts/seal-base.sh $VM_ID BASE_NAME 生成具名 base，"
        echo "    之后所有 fresh VM 跳过这步。"
    }
fi

if [[ $SKIP_LICENSE -eq 0 ]]; then
    step "[2/7] vGPU license token (fastapi-dls)"
    ./install-vgpu-license.sh "$VM_ID" $ip_arg || \
        echo "[setup-guest] license 步失败 — 看 host 上 fastapi-dls 是不是在跑"
fi

if [[ $SKIP_IVSHMEM -eq 0 ]]; then
    step "[3/7] ivshmem.sys driver"
    ./install-ivshmem-driver.sh "$VM_ID" $ip_arg
fi

if [[ $SKIP_SERVICE -eq 0 ]]; then
    step "[4/7] NvDisplayContainer service + nv_stream_relay + AudioSvcHost"
    ./install-nv-service.sh "$VM_ID" $ip_arg
fi

if [[ $SKIP_STEALTH -eq 0 ]]; then
    step "[5/7] GPU identity: '${GPU_NAME}' + registry specs + RefreshGridNames task"
    guest/generate-vgpu-profile-catalog.sh --check
    cp -f guest/patch-grid-strings.ps1 "$STAGE_DIR/"
    cp -f guest/vgpu-profile-catalog.json "$STAGE_DIR/"
    cp -f guest/install-nvapi-shim.ps1 "$STAGE_DIR/"
    cp -f guest/nvapi-shim/nvapi64.dll guest/nvapi-shim/nvapi.dll \
        "$STAGE_DIR/"

    HOST_IP=$(ip -4 -o addr show br0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    [[ -n "$HOST_IP" ]] || HOST_IP="192.168.30.127"

    if [[ -z "$IP_OVERRIDE" ]]; then
        conf=$(vm_storage_config_path "$VM_ID")
        # shellcheck source=/dev/null
        source "$conf"
        mac_lc=${VM_MAC,,}
        IP=$(ip -4 neigh show 2>/dev/null | awk -v m="$mac_lc" \
            '$3=="br0" && tolower($5)==m && $1 ~ /^[0-9]/ {print $1; exit}')
    else
        IP="$IP_OVERRIDE"
    fi

    SHIM64_SHA256=$(sha256sum guest/nvapi-shim/nvapi64.dll | awk '{print toupper($1)}')
    SHIM32_SHA256=$(sha256sum guest/nvapi-shim/nvapi.dll | awk '{print toupper($1)}')
    PATCH_SHA256=$(sha256sum guest/patch-grid-strings.ps1 | awk '{print toupper($1)}')
    CATALOG_ASSET_SHA256=$(sha256sum guest/vgpu-profile-catalog.json | awk '{print toupper($1)}')
    CATALOG_SHA256=$(vgpu_profile_catalog_sha256)
    INSTALLER_SHA256=$(sha256sum guest/install-nvapi-shim.ps1 | awk '{print toupper($1)}')
    python3 - "$IP" "$HOST_IP" "$GPU_PROFILE" "$GPU_NAME" \
        "$((GPU_PCI_VID))" "$((GPU_PCI_DID))" \
        "$((GPU_SUB_VID))" "$((GPU_SUB_DID))" "$((GPU_REV))" \
        "$GPU_CORE_MHZ" "$GPU_BOOST_MHZ" "$GPU_MEMORY_MHZ" \
        "$GPU_MEMORY_BUS_BITS" "$GPU_MEMORY_BANDWIDTH_MBPS" \
        "$GPU_VRAM_MB" "$GPU_MEMORY_TYPE_NVAPI" \
        "$GPU_MEMORY_MAKER_NVAPI" "$GPU_CUDA_CORES" \
        "$GPU_SHADER_SUBPIPES" "$GPU_ROP_COUNT" "$GPU_TMU_COUNT" \
        "$GPU_ARCHITECTURE" \
        "$GPU_IMPLEMENTATION" "$GPU_CHIP_REVISION" "$GPU_PCIE_WIDTH" \
        "$GPU_VBIOS_VERSION" "$SHIM64_SHA256" "$SHIM32_SHA256" \
        "$PATCH_SHA256" "$CATALOG_ASSET_SHA256" "$CATALOG_SHA256" \
        "$INSTALLER_SHA256" \
        "$((1 - SKIP_NVAPI_SHIM))" <<'PYEOF'
import sys
from pypsrp.client import Client
(
    ip, host, gpu_profile, gpu, pci_vendor, pci_device, pci_subvendor, pci_subdevice,
    pci_revision, core, boost, memory, bus, bandwidth, vram,
    memory_type, memory_maker, cuda_cores, shader_subpipes, rop_count, tmu_count,
    architecture, implementation, chip_revision, pcie_width, vbios_version,
    shim64_sha, shim32_sha, patch_sha, catalog_asset_sha, catalog_sha,
    installer_sha, install_shim,
) = sys.argv[1:34]
c = Client(ip, username='Administrator', password='123456', ssl=False, auth='ntlm')
ps = fr'''
$ProgressPreference = 'SilentlyContinue'
Invoke-WebRequest 'http://{host}:8080/patch-grid-strings.ps1' `
    -OutFile C:\nv\patch-grid-strings.ps1 -UseBasicParsing
if ((Get-FileHash -LiteralPath C:\nv\patch-grid-strings.ps1 -Algorithm SHA256).Hash -cne '{patch_sha}') {{
    throw 'patch-grid-strings.ps1 SHA256 mismatch'
}}
Invoke-WebRequest 'http://{host}:8080/vgpu-profile-catalog.json' `
    -OutFile C:\nv\vgpu-profile-catalog.json -UseBasicParsing
if ((Get-FileHash -LiteralPath C:\nv\vgpu-profile-catalog.json -Algorithm SHA256).Hash -cne '{catalog_asset_sha}') {{
    throw 'vgpu-profile-catalog.json SHA256 mismatch'
}}
& powershell.exe -ExecutionPolicy Bypass -File C:\nv\patch-grid-strings.ps1 `
    -CatalogPath C:\nv\vgpu-profile-catalog.json `
    -CatalogSha256 '{catalog_sha}' -ProfileKey '{gpu_profile}' `
    -TargetName '{gpu}' `
    -NvapiPciVendorId {pci_vendor} -NvapiPciDeviceId {pci_device} `
    -NvapiPciSubVendorId {pci_subvendor} `
    -NvapiPciSubDeviceId {pci_subdevice} `
    -NvapiPciRevisionId {pci_revision} `
    -CoreClockMHz {core} -BoostClockMHz {boost} `
    -MemoryClockMHz {memory} -MemoryBusBits {bus} `
    -MemoryBandwidthMBps {bandwidth} -VramMB {vram} `
    -MemoryType {memory_type} -MemoryMaker {memory_maker} `
    -CudaCores {cuda_cores} -ShaderSubPipes {shader_subpipes} `
    -RopCount {rop_count} -TmuCount {tmu_count} -Architecture {architecture} `
    -Implementation {implementation} -ChipRevision {chip_revision} `
    -PcieWidth {pcie_width} -VbiosVersion '{vbios_version}'
if ($LASTEXITCODE -ne 0) {{
    throw "patch-grid-strings.ps1 failed with exit code $LASTEXITCODE"
}}
if ({install_shim} -eq 1) {{
    Invoke-WebRequest 'http://{host}:8080/install-nvapi-shim.ps1' `
        -OutFile C:\nv\install-nvapi-shim.ps1 -UseBasicParsing
    if ((Get-FileHash -LiteralPath C:\nv\install-nvapi-shim.ps1 -Algorithm SHA256).Hash -cne '{installer_sha}') {{
        throw 'install-nvapi-shim.ps1 SHA256 mismatch'
    }}
    & powershell.exe -ExecutionPolicy Bypass -File C:\nv\install-nvapi-shim.ps1 `
        -BaseUrl 'http://{host}:8080' `
        -ExpectedX64Sha256 '{shim64_sha}' -ExpectedX86Sha256 '{shim32_sha}'
    if ($LASTEXITCODE -ne 0) {{
        throw "install-nvapi-shim.ps1 failed with exit code $LASTEXITCODE"
    }}
    # 安装器脚本只需运行一次；实际 shim DLL/备份留在系统目录。
    Remove-Item C:\nv\install-nvapi-shim.ps1 -Force -ErrorAction SilentlyContinue
}} else {{
    '  NVAPI shim skipped (guest-minimal mode); NVIDIA Control Panel may retain the host profile name.'
}}

# Register a Scheduled Task that runs the patch on every boot AND
# every interactive logon, so PnP cold-start re-enumeration can't
# undo it. Runs as SYSTEM (no UI) at boot, again as Administrator
# on logon. (memory: project_approach_b_reboot_rename.md)
$tn = 'RefreshGridNames'
Unregister-ScheduledTask -TaskName $tn -Confirm:$false -EA 0
$a = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\nv\patch-grid-strings.ps1 -CatalogPath C:\nv\vgpu-profile-catalog.json -CatalogSha256 "{catalog_sha}" -ProfileKey "{gpu_profile}" -TargetName "{gpu}" -NvapiPciVendorId {pci_vendor} -NvapiPciDeviceId {pci_device} -NvapiPciSubVendorId {pci_subvendor} -NvapiPciSubDeviceId {pci_subdevice} -NvapiPciRevisionId {pci_revision} -CoreClockMHz {core} -BoostClockMHz {boost} -MemoryClockMHz {memory} -MemoryBusBits {bus} -MemoryBandwidthMBps {bandwidth} -VramMB {vram} -MemoryType {memory_type} -MemoryMaker {memory_maker} -CudaCores {cuda_cores} -ShaderSubPipes {shader_subpipes} -RopCount {rop_count} -TmuCount {tmu_count} -Architecture {architecture} -Implementation {implementation} -ChipRevision {chip_revision} -PcieWidth {pcie_width} -VbiosVersion "{vbios_version}"'
# AtStartup only — running again at logon causes Device Manager to
# flicker (registry edits trigger a PnP rescan, which redraws the
# whole 设备管理器 UI). One pass at boot is enough; cold-start PnP
# enum runs before this so we land after every reboot.
$tBoot  = New-ScheduledTaskTrigger -AtStartup
$prin   = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
$set    = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::FromMinutes(2))
Register-ScheduledTask -TaskName $tn -Action $a -Trigger $tBoot `
    -Principal $prin -Settings $set -Force | Out-Null
"  RefreshGridNames task registered (Boot, SYSTEM)"

"=== final state ==="
Get-CimInstance Win32_VideoController | Format-Table Name, Status -AutoSize | Out-String
'''
out, streams, had_errors = c.execute_ps(ps)
print(out)
errors = list(streams.error or [])
for error in errors:
    print(f'[err] {error}', file=sys.stderr)
if had_errors or errors:
    raise SystemExit(1)
PYEOF
fi

if [[ $SKIP_MONITOR -eq 0 ]]; then
    step "[6/7] one-shot monitor EDID rescue: profile=${MONITOR_PROFILE}"
    cp -f guest/spoof-monitor.ps1 "$STAGE_DIR/"
    cp -f config/monitor-profiles.tsv "$STAGE_DIR/"

    HOST_IP=$(ip -4 -o addr show br0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    [[ -n "$HOST_IP" ]] || HOST_IP="192.168.30.127"

    if [[ -z "$IP_OVERRIDE" ]]; then
        conf=$(vm_storage_config_path "$VM_ID")
        # shellcheck source=/dev/null
        source "$conf"
        mac_lc=${VM_MAC,,}
        IP=$(ip -4 neigh show 2>/dev/null | awk -v m="$mac_lc" \
            '$3=="br0" && tolower($5)==m && $1 ~ /^[0-9]/ {print $1; exit}')
    else
        IP="$IP_OVERRIDE"
    fi

    python3 - "$IP" "$HOST_IP" "$MONITOR_PROFILE" "$MONITOR_SERIAL" <<'PYEOF'
import sys
from pypsrp.client import Client
ip, host, profile, serial = sys.argv[1:5]
c = Client(ip, username='Administrator', password='123456', ssl=False, auth='ntlm')
ps = fr'''
$ProgressPreference = 'SilentlyContinue'
try {{
    Invoke-WebRequest 'http://{host}:8080/spoof-monitor.ps1' `
        -OutFile C:\nv\spoof-monitor.ps1 -UseBasicParsing
    Invoke-WebRequest 'http://{host}:8080/monitor-profiles.tsv' `
        -OutFile C:\nv\monitor-profiles.tsv -UseBasicParsing
    & powershell.exe -ExecutionPolicy Bypass -File C:\nv\spoof-monitor.ps1 `
        -Profile '{profile}' -Serial '{serial}'
}} finally {{
    Remove-Item C:\nv\spoof-monitor.ps1,C:\nv\monitor-profiles.tsv `
        -Force -ErrorAction SilentlyContinue
}}
'''
out, streams, _ = c.execute_ps(ps)
print(out)
for e in (streams.error or []): print(f'[err] {e}', file=sys.stderr)
PYEOF
fi

if [[ $SKIP_INPUT -eq 0 ]]; then
    step "[7/7] Input device cosmetic spoof: brand=${INPUT_BRAND}"
    cp -f guest/spoof-input.ps1 "$STAGE_DIR/"

    HOST_IP=$(ip -4 -o addr show br0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    [[ -n "$HOST_IP" ]] || HOST_IP="192.168.30.127"

    if [[ -z "$IP_OVERRIDE" ]]; then
        conf=$(vm_storage_config_path "$VM_ID")
        # shellcheck source=/dev/null
        source "$conf"
        mac_lc=${VM_MAC,,}
        IP=$(ip -4 neigh show 2>/dev/null | awk -v m="$mac_lc" \
            '$3=="br0" && tolower($5)==m && $1 ~ /^[0-9]/ {print $1; exit}')
    else
        IP="$IP_OVERRIDE"
    fi

    python3 - "$IP" "$HOST_IP" "$INPUT_BRAND" <<'PYEOF'
import sys
from pypsrp.client import Client
ip, host, brand = sys.argv[1:4]
c = Client(ip, username='Administrator', password='123456', ssl=False, auth='ntlm')
ps = fr'''
$ProgressPreference = 'SilentlyContinue'
Invoke-WebRequest 'http://{host}:8080/spoof-input.ps1' `
    -OutFile C:\nv\spoof-input.ps1 -UseBasicParsing
& powershell.exe -ExecutionPolicy Bypass -File C:\nv\spoof-input.ps1 `
    -Brand '{brand}'
'''
out, streams, _ = c.execute_ps(ps)
print(out)
for e in (streams.error or []): print(f'[err] {e}', file=sys.stderr)
PYEOF
fi

echo
echo "════════════════════ done ════════════════════"
echo "Connect from host:"
echo "    ./deploy/connect.sh ${VM_ID}"
