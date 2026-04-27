#!/bin/bash
# ---------------------------------------------------------------------------
# start-vm.sh ——— 一键启动隐身 QEMU/KVM Windows 客机
#
# 客机伪装成裸金属：随机 AM4 主板（ASRock/MSI/ASUS 池）+ AMD Ryzen 3 + 8GB
# DDR4 双通道 + Samsung 970 PRO 512GB NVMe + virtio-gpu 改名 GTX 1050。
#
# 用法（最简）：
#     ./start-vm.sh 1                       # 启动 instance 1，桥接 br0，SDL 窗口
#     ./start-vm.sh 2 --iso=/path/x.iso     # instance 2 从 ISO 装系统
#     ./start-vm.sh 1 --headless            # 无 SDL，VNC only
#     ./start-vm.sh 1 --no-bridge           # 用 user-mode NAT 而不是 br0
#     ./start-vm.sh 1 --reroll              # 重新随机硬件身份
#
# 默认值（90% 情况都不用改）：
#     BRIDGE=br0           桥接 br0（不存在自动回退到 user-mode NAT）
#     STABLE_DISPLAY=1     virtio-vga（无 GL，规避 virgl BSOD；ACE/腾讯反作弊友好）
#     GPU_SELFSIGNED=0     PCI 主 ID 留 1AF4:1050 + subsys 改 NVIDIA 1C8110DE
#                          (子系统级 NVIDIA 改名，搭配 stock virtio-win 0.1.266
#                          + apply-gpu-spoof.ps1 注册表覆盖 = 通过 ACE 13-131106-0)
#     CPU_MODEL            读 profile，首次生成默认 Ryzen3-1200
#
# 硬件身份只在首次启动时随机一次，写到
#     /home/ubuntu/images/vms/<N>/profile
# 之后所有启动复用，让 Windows / 反作弊看见永远同一台机器。
# 想换身份: deploy/scripts/reroll-identity.sh <N>  或者直接删 profile 文件。
#
# 环境变量（不常用，默认就好）：
#     RAM=8192             客机内存 MiB（默认 8192）
#     CPUS=4               vCPU 数量（默认 4，cores=4 threads=1 sockets=1）
#     HEADLESS=1           关 SDL，只开 VNC                    (flag: --headless)
#     BRIDGE=br0           桥接网卡名字                         (flag: --bridge=br0)
#     ISO=<path>           安装 ISO 路径                        (flag: --iso=<path>)
#     DISK=<path>          qcow2 磁盘路径                       (flag: --disk=<path>)
#     QEMU=<path>          qemu-system-x86_64 二进制路径        (flag: --qemu=<path>)
#     EXTRA_ISO=<path>     副 CDROM（autounattend.xml / 驱动盘 等）
#     STABLE_DISPLAY=0     允许 virtio-vga-gl + virgl 3D 加速（更快但偶发 BSOD）
#     GPU_SELFSIGNED=1     PCI 主 ID 改成 NVIDIA 10DE:1C81。 ⚠️ 需要 patched
#                          viogpudo + 伪 NVIDIA CA 链；ACE/腾讯反作弊判异常
#                          (13-131106-0)。只用于轻反作弊场景。
#     CPU_MODEL=Ryzen3-2300X  覆盖 profile 写入的 CPU 型号（一般不用）
# ---------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# When running from deploy/scripts/, the QEMU repo root is two levels up.
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
source "$HERE/stealth-lib.sh"

_usage() {
    sed -n '2,/^# --*$/p' "$0" | sed -e 's/^# *//' -e 's/^#$//' >&2
    exit "${1:-2}"
}

# ---------------------- CLI parsing ----------------------
# First positional arg = INSTANCE. Everything else is --flag=value or --flag.
_cli_instance=""
_cli_iso=""
_cli_reroll=0
while (( $# > 0 )); do
    case "$1" in
        -h|--help) _usage 0 ;;
        --iso=*)      _cli_iso="${1#*=}" ;;
        --disk=*)     DISK="${1#*=}" ;;
        --bridge=*)   BRIDGE="${1#*=}" ;;
        --no-bridge)  NO_BRIDGE=1 ;;
        --qemu=*)     QEMU="${1#*=}" ;;
        --ram=*)      RAM="${1#*=}" ;;
        --cpus=*)     CPUS="${1#*=}" ;;
        --headless)   HEADLESS=1 ;;
        --reroll)     _cli_reroll=1 ;;
        --)           shift; break ;;
        -*)
            echo "ERROR: unknown flag '$1'" >&2
            _usage ;;
        *)
            if [[ -z "$_cli_instance" ]]; then
                _cli_instance="$1"
            else
                echo "ERROR: unexpected positional argument '$1'" >&2
                _usage
            fi ;;
    esac
    shift
done

# ---------------- defaults ----------------
# INSTANCE 来源优先级:
#   1. 命令行位置参数  ./start-vm.sh 2
#   2. 环境变量 INSTANCE=2 ./start-vm.sh
#   3. 默认 1
# 如果同时给了位置参数和环境变量但不一致，警告并用位置参数（命令行更显式）。
if [[ -n "$_cli_instance" ]]; then
    if [[ -n "${INSTANCE:-}" && "$INSTANCE" != "$_cli_instance" ]]; then
        echo ">> WARN: INSTANCE env=$INSTANCE 与位置参数 $_cli_instance 不一致，用位置参数" >&2
    fi
    INSTANCE="$_cli_instance"
fi
: "${INSTANCE:=1}"
if ! [[ "$INSTANCE" =~ ^[0-9]+$ ]] || (( INSTANCE < 1 )); then
    echo "ERROR: INSTANCE 必须是正整数 (实际: '$INSTANCE')" >&2
    exit 2
fi

: "${RAM:=4096}"
: "${CPUS:=4}"
: "${HEADLESS:=0}"
: "${ISO:=${_cli_iso:-/home/ubuntu/images/win10.iso}}"
[[ -n "$_cli_iso" ]] && ISO="$_cli_iso"

# DISPLAY 默认 :0（典型本地 X11 会话）；从 SSH 终端运行时若未 export DISPLAY，
# 这里自动补上让 SDL 能找到 X server。HEADLESS=1 时 SDL 不启用，DISPLAY 不影响。
if [[ "$HEADLESS" != "1" ]]; then
    : "${DISPLAY:=:0}"
    export DISPLAY
fi

# 新版目录结构：所有 per-instance 文件都归在 /home/ubuntu/images/vms/<N>/
# 老版（直接放在 /home/ubuntu/images/）会被自动迁移到新位置。
VM_DIR="/home/ubuntu/images/vms/${INSTANCE}"
mkdir -p "$VM_DIR"
: "${DISK:=$VM_DIR/disk.qcow2}"
: "${QEMU:=$REPO_ROOT/build/qemu-system-x86_64}"
# Bridge is the default network backend. Pass BRIDGE= (empty) or NO_BRIDGE=1
# to opt out and fall back to user-mode NAT. Reason: a real LAN IP is the
# whole point of the stealth bundle for DNF — user mode's 10.0.2.x subnet
# is itself a VM signal.
: "${BRIDGE:=br0}"
[[ "${NO_BRIDGE:-0}" == "1" ]] && BRIDGE=""
PROFILE_FILE="$VM_DIR/profile"

# 兼容老布局：把旧路径文件迁到新目录
for _legacy_pair in \
    "/home/ubuntu/images/win10-inst${INSTANCE}.qcow2|$VM_DIR/disk.qcow2" \
    "/home/ubuntu/images/stealth-inst${INSTANCE}.profile|$VM_DIR/profile" \
    "/home/ubuntu/images/ovmf-vars-${INSTANCE}.fd|$VM_DIR/ovmf-vars.fd"
do
    _src="${_legacy_pair%|*}"
    _dst="${_legacy_pair##*|}"
    if [[ -f "$_src" && ! -f "$_dst" ]]; then
        mv "$_src" "$_dst"
        echo ">> migrated legacy: $_src -> $_dst"
    fi
done

# Low-entropy bash RANDOM seed only used when we re-roll identity; the saved
# profile pins the final values, so reseed quality doesn't matter for steady
# state.
RANDOM=$((INSTANCE * 13 + $(date +%s) % 32768))

# -------------------------------------------------------------------
# Per-instance disk creation (thin 512GB qcow2 on first run — Samsung 970 PRO)
# 如果 BASE_IMAGE=<path> 被设置，新盘以 base 为 backing-file 创建（克隆模式）
# 这样多个 instance 共享同一份基础镜像，每台只存增量。
# -------------------------------------------------------------------
if [[ ! -f "$DISK" ]]; then
    if [[ -n "${BASE_IMAGE:-}" ]]; then
        if [[ ! -f "$BASE_IMAGE" ]]; then
            echo "ERROR: BASE_IMAGE='$BASE_IMAGE' 不存在" >&2
            exit 1
        fi
        echo ">> 从 base 镜像克隆: $BASE_IMAGE"
        echo ">>   -> $DISK (qcow2 增量层)"
        "$REPO_ROOT/build/qemu-img" create -f qcow2 \
            -F qcow2 -b "$BASE_IMAGE" "$DISK" >/dev/null
    else
        echo ">> creating fresh 512GB qcow2 at $DISK"
        "$REPO_ROOT/build/qemu-img" create -f qcow2 -o preallocation=off,cluster_size=65536 \
            "$DISK" 512000000000
    fi
fi

# -------------------------------------------------------------------
# Boot source:
#   --iso=<path>  -> boot from that ISO (install media)
#   (no flag)     -> boot from the qcow2 disk
# -------------------------------------------------------------------
if [[ -n "$_cli_iso" ]]; then
    BOOT="iso"
else
    BOOT="disk"
fi

# -------------------------------------------------------------------
# Hardware identity — random on creation, stable afterwards.
#
# First launch (profile file missing) or --reroll: randomize + save.
# Subsequent launches: source the saved profile. This is what keeps
# Windows from re-activating every boot and what stops XignCode3 from
# noticing the motherboard serial flipping between sessions.
# -------------------------------------------------------------------
if (( _cli_reroll )); then
    echo ">> --reroll: regenerating hardware identity for instance $INSTANCE"
    rm -f "$PROFILE_FILE"
fi

if stealth_have_profile "$PROFILE_FILE"; then
    stealth_load_profile "$PROFILE_FILE"
    echo ">> profile:     loaded from $PROFILE_FILE"
else
    stealth_pick_profile
    stealth_save_profile "$PROFILE_FILE"
    echo ">> profile:     NEW identity saved to $PROFILE_FILE"
fi
stealth_print_profile

# -------------------------------------------------------------------
# Port/socket allocation (offset by INSTANCE)
# -------------------------------------------------------------------
QMP_SOCK="/tmp/qemu-stealth-${INSTANCE}.qmp"
MON_SOCK="/tmp/qemu-stealth-${INSTANCE}.mon"
: "${VNC_DISPLAY:=$(( INSTANCE - 1 ))}"      # VNC port 5900 + display (env-overridable)
SPICE_PORT=$(( 5930 + INSTANCE ))
SSH_FWD_PORT=$(( 10022 + INSTANCE ))
RDP_FWD_PORT=$(( 13389 + INSTANCE ))
# MAC: use the NIC_MAC already picked by stealth_pick_profile (Realtek/Intel/ASUS
# OUI pool). Do NOT reuse the 52:54:00 QEMU/KVM OUI — that's a one-line tell.
MAC_OVERRIDE="$NIC_MAC"

rm -f "$QMP_SOCK" "$MON_SOCK"

# -------------------------------------------------------------------
# OVMF firmware (UEFI SecureBoot-capable -> looks like modern PC).
# Per-instance VARS copy so each VM has its own NVRAM.
#
# Stealth build: the custom OVMF_CODE_4M_stealth.fd at deploy/firmware/
# adds PCI VEN_10DE:DEV_1C81 to QemuVideoDxe's whitelist so UEFI boot
# display still works when virtio-vga is spoofed as NVIDIA GTX 1050
# (GPU_SELFSIGNED=1 path). Without it OVMF can't find a matching GOP
# driver and you stare at "Display output is not active" until
# viogpudo.sys loads inside Windows. Falls back to Ubuntu's stock
# OVMF_CODE_4M.fd if the stealth build is missing.
# -------------------------------------------------------------------
STEALTH_OVMF="$(dirname "$0")/../firmware/OVMF_CODE_4M_stealth.fd"
if [[ -f "$STEALTH_OVMF" ]]; then
    OVMF_CODE="$(readlink -f "$STEALTH_OVMF")"
else
    OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd
fi
OVMF_VARS_SRC=/usr/share/OVMF/OVMF_VARS_4M.fd
OVMF_VARS="$VM_DIR/ovmf-vars.fd"
if [[ ! -f "$OVMF_VARS" ]]; then
    cp "$OVMF_VARS_SRC" "$OVMF_VARS"
fi

# -------------------------------------------------------------------
# SMBIOS arg list. Tell stealth_smbios_args what per-DIMM capacity to
# declare (so the part# picked matches the actual memory backend size).
# -------------------------------------------------------------------
export MEM_PER_DIMM_MB=$(( RAM / 2 ))

# Override default PCI subsystem IDs for devices that don't set their own.
# ASUS PRIME B350-PLUS uses 1043:8694 on many platform devices — keeps the
# Red Hat/QEMU leak (1AF4:1100) off of xHCI, LPC, HDA, bridges, etc.
export QEMU_PCI_SUBSYS_VEN=${QEMU_PCI_SUBSYS_VEN:-0x1043}
export QEMU_PCI_SUBSYS_DEV=${QEMU_PCI_SUBSYS_DEV:-0x8694}
SMBIOS_ARGS=()
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    SMBIOS_ARGS+=("-smbios" "$line")
done < <(stealth_smbios_args)

# AMD DF stubs only for AMD CPUs
AMD_DF_ARGS=()
if [[ "$CPU_VENDOR" == "AuthenticAMD" ]]; then
    AMD_DF_ARGS=(
        -device amd-df-stub,bus=pcie.0,addr=0x18.0x0,multifunction=on,device-id=0x1460
        -device amd-df-stub,bus=pcie.0,addr=0x18.0x1,device-id=0x1461
        -device amd-df-stub,bus=pcie.0,addr=0x18.0x2,device-id=0x1462
        -device amd-df-stub,bus=pcie.0,addr=0x18.0x3,device-id=0x1463
        -device amd-df-stub,bus=pcie.0,addr=0x18.0x4,device-id=0x1464
        -device amd-df-stub,bus=pcie.0,addr=0x18.0x5,device-id=0x1465
        -device amd-df-stub,bus=pcie.0,addr=0x18.0x6,device-id=0x1466
        -device amd-df-stub,bus=pcie.0,addr=0x18.0x7,device-id=0x1467
    )
fi

# -------------------------------------------------------------------
# Guest display: virtio-gpu-gl for 3D accel (DNF needs DirectX).
# We label it as a GTX 1050-class adapter only at the SMBIOS level;
# real GPU driver spoofing requires guest-side INF tweak documented in
# NOTES-GPU.md. virtio-gpu accepts OpenGL via VirGL and Mesa d3d->gl.
# Fallback to qxl-vga if HEADLESS is set.
# -------------------------------------------------------------------
# GPU subsystem spoof: 主 ID 留 1AF4:1050 (virtio) 让 stock virtio-win 绑定，
# subsys 改成 profile 选定的 GPU (NVIDIA / AMD)。
# apply-gpu-spoof.ps1 + nvapi64.dll shim 在 guest 里把 WMI / Device Manager 的
# 显示名也对齐到 profile.GPU_NAME。
GPU_STEALTH="x-pci-sub-vendor-id=${GPU_PCI_VEN},x-pci-sub-device-id=${GPU_PCI_DEV},x-pci-revision=${GPU_REV}"

# GPU_SELFSIGNED=1：把 PCI 主 ID 也改成 NVIDIA / AMD（深层 stealth，
# ⚠️ ACE 反作弊会判异常 13-131106-0；只用于无 ACE 类反作弊场景）。
# 需要 guest 里事先装好 patched viogpudo.sys + 伪 NVIDIA/AMD CA 链。
if [[ "${GPU_SELFSIGNED:-0}" == "1" ]]; then
    GPU_STEALTH="${GPU_STEALTH},x-pci-vendor-id=${GPU_PCI_VEN},x-pci-device-id=${GPU_PCI_DEV}"
fi

# 显示后端选择
#
# STABLE_DISPLAY=1（默认）: virtio-vga，不开 -gl/virgl。规避 virgl 长期运行后
#   触发的 DXGKRNL TDR/BSOD（"VIDEO_DXGKRNL_FATAL_ERROR" / "VIDEO_SCHEDULER_
#   INTERNAL_ERROR"）。代价是没有 GL 加速，guest 的 DirectX 回退到 WARP
#   (软件 DX9-12)。DNF/腾讯 2D+DX9 类游戏 WARP 完全够用，性能差不大。
#
# STABLE_DISPLAY=0: virtio-vga-gl + virgl 3D 加速。渲染更快，但 virgl 状态机
#   脆弱，长时间会话或 DWM 3D 使用会污染并最终 BSOD。
#
# HEADLESS=1: 强制 VNC-only，始终 virtio-vga（不开 GL）。
STABLE_DISPLAY=${STABLE_DISPLAY:-1}

if [[ "$HEADLESS" == "1" ]]; then
    # Headless: VNC only. virtio-vga (no GL) because SPICE GL is local-only
    # and VNC doesn't render OpenGL output.
    DISP_ARGS=(
        -display none
        -vnc 127.0.0.1:$VNC_DISPLAY
        -device "virtio-vga,edid=on,xres=1920,yres=1080,xmax=1920,ymax=1080,${GPU_STEALTH}"
    )
elif [[ "$STABLE_DISPLAY" == "1" ]]; then
    # Stability mode: SDL window for local control, no GL passthrough.
    # Use this for long DNF sessions or anti-cheat-stable runs.
    # SDL grab-mod 默认是 lshift-lctrl-lalt（Ctrl+Shift+Alt+G 切换抓取），保持默认。
    DISP_ARGS=(
        -display sdl,show-cursor=off
        -device "virtio-vga,edid=on,xres=1920,yres=1080,xmax=1920,ymax=1080,${GPU_STEALTH}"
    )
else
    DISP_ARGS=(
        -display sdl,gl=on,show-cursor=off
        -device "virtio-vga-gl,edid=on,xres=1920,yres=1080,xmax=1920,ymax=1080,${GPU_STEALTH}"
    )
fi

# 键盘走 USB HID (usb-kbd) — DirectInput / Raw Input 类游戏 (DNF / 腾讯反作弊)
# 只读 USB keyboard, PS/2 keyboard 在它们眼里不存在 → 游戏内按键完全无响应.
# q35 i8042 控制器仍默认带, 但没东西往那里发 scancode 就是空通道, 不影响.
# NumLock 状态由 hive 的 InitialKeyboardIndicators=2147483650 在 Welcome 阶段
# 钉 ON (vm-bootstrap.ps1 / host-fix-numlock.sh 保证), 不依赖 SDL LED 双向同步.
KBD_HINT='USB keyboard (DirectInput/Raw Input 兼容); NumLock 由 hive 钉 ON'

# -------------------------------------------------------------------
# Boot order
#
# UEFI ignores `-boot order=...` (that's a BIOS directive) and `strict=on`
# can stop OVMF from walking the El Torito UEFI entry when bootindex=
# is set on devices. We rely purely on bootindex= on the -device lines
# and keep -boot minimal: menu + a visible splash window so you can hit
# ESC/F12 and enter the OVMF Boot Manager if auto-boot ever misses.
# -------------------------------------------------------------------
BOOT_ORDER="menu=on,splash-time=5000,reboot-timeout=5000"
if [[ "$BOOT" == "iso" ]]; then
    CDROM_ARGS=(
        -drive file="$ISO",media=cdrom,if=none,id=cd0,readonly=on
        -device ide-cd,drive=cd0,bus=ide.0,bootindex=1
    )
else
    CDROM_ARGS=()
fi

# Optional second CDROM (autounattend.xml ISO, virtio-win driver disk, etc).
# Windows Setup auto-discovers autounattend.xml on any attached removable
# media, so this is the "OOBE bypass" hook without rebuilding the OS ISO.
# Mounted with non-bootable bus index so it doesn't fight the install ISO.
if [[ -n "${EXTRA_ISO:-}" ]]; then
    if [[ ! -f "$EXTRA_ISO" ]]; then
        echo "ERROR: EXTRA_ISO='$EXTRA_ISO' does not exist" >&2
        exit 1
    fi
    CDROM_ARGS+=(
        -drive file="$EXTRA_ISO",media=cdrom,if=none,id=cd1,readonly=on
        -device ide-cd,drive=cd1,bus=ide.1
    )
    echo ">> extra ISO:   $EXTRA_ISO (autounattend / driver disk)"
fi

# -------------------------------------------------------------------
# Network backend: bridge (LAN-attached) vs user-mode NAT.
#
# Bridge mode puts the guest on the host's LAN with its own DHCP lease,
# which matters for DNF because anti-cheat treats 10.0.2.x / 192.168.76.x
# NAT subnets as virtual-machine signals. User mode is kept as the default
# fallback for hosts without bridge setup.
# -------------------------------------------------------------------
if [[ -n "${BRIDGE:-}" ]]; then
    _bridge_fail=""
    if ! ip link show "$BRIDGE" &>/dev/null; then
        _bridge_fail="bridge '$BRIDGE' does not exist"
    elif ! grep -q "^allow $BRIDGE" /etc/qemu/bridge.conf 2>/dev/null; then
        _bridge_fail="/etc/qemu/bridge.conf missing 'allow $BRIDGE'"
    fi
    if [[ -n "$_bridge_fail" ]]; then
        echo ">> WARN: $_bridge_fail"
        echo ">>       falling back to user-mode NAT. Run 'sudo deploy/scripts/setup-bridge.sh'"
        echo ">>       (with UPLINK=<iface> for a LAN bridge) to enable bridge mode."
        BRIDGE=""
    fi
fi
if [[ -n "${BRIDGE:-}" ]]; then
    # Pick the first qemu-bridge-helper we find with cap_net_admin (or suid).
    # The source-built QEMU defaults to /usr/local/libexec/qemu-bridge-helper
    # which won't exist on a stock Ubuntu host — passing helper= explicitly
    # removes that entire class of "-netdev bridge: failed to launch helper"
    # errors. setup-bridge.sh also symlinks that path for safety.
    BRIDGE_HELPER=""
    for h in /usr/lib/qemu/qemu-bridge-helper \
             /usr/libexec/qemu-bridge-helper \
             /usr/local/libexec/qemu-bridge-helper \
             "$REPO_ROOT/build/qemu-bridge-helper"; do
        if [[ -x "$h" ]] && { getcap "$h" 2>/dev/null | grep -q cap_net_admin || [[ -u "$h" ]]; }; then
            BRIDGE_HELPER="$h"; break
        fi
    done
    if [[ -z "$BRIDGE_HELPER" ]]; then
        echo "ERROR: no qemu-bridge-helper with cap_net_admin/suid found." >&2
        echo "       Run 'sudo deploy/scripts/setup-bridge.sh' (it installs the apt package + grants caps)." >&2
        exit 1
    fi
    NET_ARGS=(
        -netdev "bridge,id=net0,br=$BRIDGE,helper=$BRIDGE_HELPER"
    )
    echo ">> network:     bridge=$BRIDGE via $BRIDGE_HELPER (guest gets LAN IP via DHCP)"
else
    NET_ARGS=(
        -netdev user,id=net0,hostfwd=tcp:127.0.0.1:$SSH_FWD_PORT-:22,hostfwd=tcp:127.0.0.1:$RDP_FWD_PORT-:3389
    )
    echo ">> network:     user-mode NAT (SSH 127.0.0.1:$SSH_FWD_PORT, RDP 127.0.0.1:$RDP_FWD_PORT)"
fi

# -------------------------------------------------------------------
# Assemble the command line
# -------------------------------------------------------------------
CMD=(
    "$QEMU"

    # --- Machine / firmware ---
    # ACPI OEM IDs default to "ALASKA"/"A M I   " from our aml-build.h patch;
    # no need to pass x-oem-id on the cmdline. smm=on is required for OVMF S3.
    -name "win10-ryzen3-${INSTANCE},debug-threads=on"
    -machine q35,accel=kvm,vmport=off,smm=on,hpet=off,kernel-irqchip=split
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE"
    -drive if=pflash,format=raw,file="$OVMF_VARS"

    # --- CPU: hidden hypervisor, hidden KVM, invtsc ---
    # CPU 完整 -cpu 串由 stealth_qemu_cpu_arg 拼出（包含 family/model/stepping
    # 覆盖、tsc-freq、vendor、AMD 专属 +topoext 等）。CPU 型号从 profile 随机，
    # 池子里有 AMD Ryzen3-1200/2300X 与 Intel i3-9100F/9100/G6400/G5400。
    -cpu "$(stealth_qemu_cpu_arg)"
    -smp cpus=$CPUS,cores=$CPUS,threads=1,sockets=1,maxcpus=$CPUS

    # --- Memory: backed by memfd for prealloc, dual-channel via 2 NUMA nodes ---
    -m "${RAM}M"
    -object memory-backend-memfd,id=mem0,size=$((RAM/2))M,share=off,prealloc=on
    -object memory-backend-memfd,id=mem1,size=$((RAM/2))M,share=off,prealloc=on
    -numa node,nodeid=0,memdev=mem0,cpus=0-$((CPUS/2-1))
    -numa node,nodeid=1,memdev=mem1,cpus=$((CPUS/2))-$((CPUS-1))

    # --- Random identifiers ---
    -uuid "$UUID"
    -rtc base=localtime,clock=host,driftfix=slew
    -global kvm-pit.lost_tick_policy=delay
    -boot "$BOOT_ORDER"
    -no-user-config
    -nodefaults

    # --- SMBIOS / DMI override ---
    "${SMBIOS_ARGS[@]}"

    # --- PCI root complex (pcie-pci-bridge hidden; default q35) ---
    -device pcie-root-port,id=rp0,slot=0,bus=pcie.0,multifunction=on
    -device pcie-root-port,id=rp1,slot=1,bus=pcie.0
    -device pcie-root-port,id=rp2,slot=2,bus=pcie.0
    -device pcie-root-port,id=rp3,slot=3,bus=pcie.0

    # --- AMD Zen Data Fabric PCI stubs at 00:18.0-7 (only for AMD CPUs) ---
    # Real Zen silicon exposes 8 DF config functions; HWiNFO/CPU-Z use these
    # to identify the CPU codename and derive channel topology. Intel CPUs
    # 不放 DF stub —— 否则会出现 "Intel CPU 但有 AMD DF" 的矛盾。
    "${AMD_DF_ARGS[@]}"

    # --- Storage: virtio-scsi host + 随机 Samsung NVMe (model/firmware/SN 来自 profile) ---
    -object iothread,id=io1
    -drive file="$DISK",if=none,id=nvm0,format=qcow2,cache=none,aio=threads,discard=unmap
    -device nvme,id=nvmectl0,bus=rp1,drive=nvm0,serial="$NVME_SERIAL",use-samsung-id=on,bootindex=2,model-number="$NVME_MODEL",firmware-rev="$NVME_FIRMWARE"

    "${CDROM_ARGS[@]}"

    # --- Network: e1000e emulation (Intel 82574L) w/ random MAC ---
    "${NET_ARGS[@]}"
    -device e1000e,netdev=net0,mac=$MAC_OVERRIDE,bus=rp2

    # --- USB: xHCI + 键盘 + 鼠标 ---
    # usb-kbd: DirectInput/Raw Input 兼容 (DNF/腾讯反作弊只读 USB HID, 不读 PS/2).
    # USB_RELATIVE_MOUSE=1: usb-mouse (相对坐标，更像真鼠标，反作弊友好；
    #   SDL 抓鼠标，Ctrl+Shift+G 释放)
    # 默认 usb-tablet (绝对坐标，鼠标可自由出入 SDL 窗口)
    -device qemu-xhci,id=xhci,bus=rp3
    -device usb-kbd,bus=xhci.0
    $([[ "${USB_RELATIVE_MOUSE:-0}" == "1" ]] && echo "-device usb-mouse,bus=xhci.0" || echo "-device usb-tablet,bus=xhci.0")

    # --- Audio: ICH9 HDA (looks like Realtek ALC). Use 'none' backend
    # unconditionally -- passes driver probe in guest without requiring
    # ALSA/PipeWire on the host. ---
    -audiodev none,id=aud0
    -device intel-hda,id=hda0
    -device hda-duplex,bus=hda0.0,cad=0,audiodev=aud0

    # --- Display ---
    "${DISP_ARGS[@]}"

    # --- Control: QMP + HMP sockets for API access ---
    -chardev socket,id=qmp0,path=$QMP_SOCK,server=on,wait=off
    -mon chardev=qmp0,mode=control
    -chardev socket,id=mon0,path=$MON_SOCK,server=on,wait=off
    -mon chardev=mon0,mode=readline

    # --- Misc anti-detection knobs ---
    -msg timestamp=off
    -overcommit mem-lock=off,cpu-pm=on
)

echo ">> instance:    $INSTANCE"
echo ">> VM 目录:     $VM_DIR"
echo ">> QMP socket:  $QMP_SOCK"
echo ">> HMP socket:  $MON_SOCK"
echo ">> VNC display: :$VNC_DISPLAY (port $((5900+VNC_DISPLAY)))"
echo ">> SSH/RDP fwd: 127.0.0.1:$SSH_FWD_PORT / 127.0.0.1:$RDP_FWD_PORT"
echo ">> boot mode:   $BOOT"
echo ">> disk:        $DISK ($(stat -c%s "$DISK") bytes)"
echo ">> 键盘:        $KBD_HINT"
echo ">> --- launching ---"

# QEMU's `-rtc base=localtime` calls libc localtime() which honours $TZ.
# Pin to Asia/Shanghai so the VM RTC reflects Beijing time regardless of
# what the host's /etc/timezone is set to. Without this an LA-host gives
# the guest LA wall-clock and Windows (set to CST) shows it 15h off.
export TZ="${TZ:-Asia/Shanghai}"
echo ">> RTC TZ:       $TZ"

# 禁用 host 端 X11 DPMS / 屏保，避免 host 屏幕休眠时 SDL 窗口被冻结导致
# guest 视为黑屏。退出时恢复原状。
if [[ "${HEADLESS:-0}" != "1" && -n "${DISPLAY:-}" ]]; then
    if command -v xset >/dev/null 2>&1; then
        # 记录原值，trap 退出还原
        _xset_dpms_orig=$(xset q 2>/dev/null | awk '/DPMS is/{print $NF}')
        _xset_ss_orig=$(xset q 2>/dev/null | awk '/Screen Saver/{f=1;next} f&&/timeout:/{print $2;exit}')
        xset s off -dpms 2>/dev/null || true
        echo ">> host DPMS / 屏保: 已临时关闭（VM 退出后还原）"
        _restore_xset() {
            [[ "${_xset_dpms_orig:-}" == "Enabled" ]] && xset +dpms 2>/dev/null || true
            [[ -n "${_xset_ss_orig:-}" && "${_xset_ss_orig}" != "0" ]] && \
                xset s "${_xset_ss_orig}" 2>/dev/null || true
        }
        trap _restore_xset EXIT INT TERM
    fi

    # GNOME mutter 自己跑 idle 计时（org.gnome.desktop.session idle-delay）,
    # 不看 systemd-logind 的 idle hint, 所以 systemd-inhibit 拦不住 GNOME blank.
    # gnome-session-inhibit 调 D-Bus org.gnome.SessionManager.Inhibit, mutter
    # 会 honor 它. 链式包: gnome-session-inhibit → systemd-inhibit → qemu.
    GNOME_INHIBIT=()
    if [[ "${XDG_CURRENT_DESKTOP:-}" == *GNOME* ]] && command -v gnome-session-inhibit >/dev/null 2>&1; then
        # gnome-session-inhibit 选项必须空格分开, 不接受 --key=value 写法.
        GNOME_INHIBIT=(gnome-session-inhibit
            --app-id "qemu-stealth-${INSTANCE}"
            --reason "保持 guest 显示活性"
            --inhibit idle:logout)
        echo ">> GNOME idle: 已 inhibit (gnome-session-inhibit)"
    fi

    # 避免桌面环境 (GNOME/KDE/XFCE) 自身的待机/锁屏 — systemd-inhibit 拦截一下。
    # 没有 systemd-inhibit 时退化成裸 exec。
    if command -v systemd-inhibit >/dev/null 2>&1; then
        exec "${GNOME_INHIBIT[@]}" systemd-inhibit \
            --who="qemu-stealth-${INSTANCE}" \
            --why="保持 guest 显示活性" \
            --what="idle:sleep:handle-lid-switch" \
            --mode=block \
            -- "${CMD[@]}"
    fi

    if (( ${#GNOME_INHIBIT[@]} )); then
        exec "${GNOME_INHIBIT[@]}" "${CMD[@]}"
    fi
fi

exec "${CMD[@]}"
