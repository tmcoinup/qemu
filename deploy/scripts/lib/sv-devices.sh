# -------------------------------------------------------------------
# 平台一致性 (P0#3)：芯片组级设备 (PCIe 根端口 / xHCI) 的 PCI ID 必须跟随
# CPU 厂商。否则 Intel CPU profile 会暴露 AMD 300 系桥 / xHCI，SetupAPI /
# lspci / HWiNFO 跨表 walk 立刻发现 CPU、主板、南桥、USB 不属于同一平台。
#   AMD  : 根端口 = Family 17h Internal PCIe GPP 1022:1453（4 口同 ID，与真
#          实 Zen GPP 一致）；xHCI = 300 系 USB3.1 1022:43BB
#   Intel: 根端口 = 300 系 PCH Root Port 8086:A338..A33B（端口 #1-4 顺序）；
#          xHCI = 300 系 PCH USB3.1 8086:A36D
# DF stub 仅 AMD 才加（见上）；Intel 的 uncore 由 q35 的 Intel host bridge
# (00:00.0) 体现，无需补 stub。源码默认值仍是 AMD，未注入时行为不变。
# -------------------------------------------------------------------
case "$CPU_VENDOR" in
    GenuineIntel) PLATFORM_VENDOR="intel" ;;
    *)            PLATFORM_VENDOR="amd"   ;;
esac

if [[ "$PLATFORM_VENDOR" == "intel" ]]; then
    RP_VEN="0x8086"; RP_REV="0xf0"
    RP_DEV=("0xa338" "0xa339" "0xa33a" "0xa33b")
    XHCI_ID="x-pci-vendor-id=0x8086,x-pci-device-id=0xa36d,x-pci-revision=0x10"
else
    RP_VEN="0x1022"; RP_REV="0x00"
    RP_DEV=("0x1453" "0x1453" "0x1453" "0x1453")
    XHCI_ID="x-pci-vendor-id=0x1022,x-pci-device-id=0x43bb,x-pci-revision=0x01"
fi

# 4 口根端口（hotplug=off 见下方 QEMU_ARGS 处的说明），ID 按平台注入。
#
# 每口 x-speed/x-width 必须显式钉死（2026-06-02）。
# QEMU 的 pcie-root-port 默认 Gen4 16GT/s、x32。
# 不设就是“Gen4 x32 根端口”，AM4 Zen1/Zen+ /
# Intel 300·400 系平台根本没有这种链路。
# 根端口 LnkSta 会按 pcie_sync_bridge_lnk
# 同步成下游设备的协商值，
# 故必须让端口能力 = 下游真实链路：
#   rp1=NVMe   → Gen3 x4，配 hw/nvme/ctrl.c 端点 Gen3 x4
#   rp2=e1000e → Gen1 x1，真 Intel 82574L 就是 PCIe 1.1 x1
#   rp3=xHCI   → Gen1 x1，qemu-xhci 端点默认 Gen1 x1
#   rp0=空槽   → Gen1 x1，无下游，给个朴素值，别留 Gen4 x32
ROOT_PORT_ARGS=(
    -device "pcie-root-port,id=rp0,slot=0,bus=pcie.0,"\
"multifunction=on,hotplug=off,x-speed=2_5,x-width=1,"\
"x-pci-vendor-id=${RP_VEN},x-pci-device-id=${RP_DEV[0]},"\
"x-pci-revision=${RP_REV}"
    -device "pcie-root-port,id=rp1,slot=1,bus=pcie.0,"\
"hotplug=off,x-speed=8,x-width=4,x-pci-vendor-id=${RP_VEN},"\
"x-pci-device-id=${RP_DEV[1]},x-pci-revision=${RP_REV}"
    -device "pcie-root-port,id=rp2,slot=2,bus=pcie.0,"\
"hotplug=off,x-speed=2_5,x-width=1,x-pci-vendor-id=${RP_VEN},"\
"x-pci-device-id=${RP_DEV[2]},x-pci-revision=${RP_REV}"
    -device "pcie-root-port,id=rp3,slot=3,bus=pcie.0,"\
"hotplug=off,x-speed=2_5,x-width=1,x-pci-vendor-id=${RP_VEN},"\
"x-pci-device-id=${RP_DEV[3]},x-pci-revision=${RP_REV}"
)

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
# 三个独立通道，可叠加（fb-shm 默认开，GUI 三选一）：
#
# 1) fb-shm（FB_SHM=1，默认）
#    -object fb-shm,id=stealth-${INSTANCE},path=...
#    零拷贝共享内存推流。配合 scripts/qemu-fb-shm-stream.py → ffmpeg/NVENC。
#    与下面三种 GUI 通道全部可共存（独立 DCL，互不影响）。
#
# 2) GUI 通道（互斥三选一）
#    --sdl       : -display sdl,...        (本地交互窗口；DNF 调试)
#    --headless  : -display none -vnc ...  (VNC 远程)
#    --no-sdl    : -display none           (无 GUI；纯推流场景)
#
# STABLE_DISPLAY=0（默认）: 仅在 --sdl 模式下生效，启 virtio-vga-gl + virgl 3D 加速。
#   fb-shm 会作为第二个 DCL 共享 SDL 的 GL scanout，把纹理读回到 SHM 推流；
#   渲染更快但 virgl 状态机长跑会脏。
#
# STABLE_DISPLAY=1: 强制 virtio-vga，不开 -gl/virgl。用于规避 virgl 长期运行后
#   触发的 DXGKRNL TDR/BSOD（"VIDEO_DXGKRNL_FATAL_ERROR" / "VIDEO_SCHEDULER_
#   INTERNAL_ERROR"）。代价是没有 GL 加速，guest 的 DirectX 回退到 WARP。
#   (注：--no-sdl/--headless 没有窗口 GL context，仍然走 stable 路径)
STABLE_DISPLAY=${STABLE_DISPLAY:-0}

# 拼 fb-shm -object 字符串
FB_SHM_OBJ=""
if [[ "$FB_SHM" == "1" ]]; then
    FB_SHM_OBJ="fb-shm,id=stealth-${INSTANCE},path=${FB_SHM_SOCK},rate=${FB_SHM_RATE}"
    if [[ -n "$FB_SHM_ROI" ]]; then
        IFS=',' read -r _rx _ry _rw _rh <<<"$FB_SHM_ROI"
        FB_SHM_OBJ="${FB_SHM_OBJ},x=${_rx},y=${_ry},width=${_rw},height=${_rh}"
    fi
fi

# 选 virtio-vga 或 virtio-vga-gl + 注入 profile 的 EDID 字符串（patch 0009 新选项）
EDID_PROPS="edid-vendor=${EDID_VENDOR},edid-name=${EDID_NAME},edid-serial=${EDID_SERIAL},edid-width-mm=${EDID_WIDTH_MM},edid-height-mm=${EDID_HEIGHT_MM}"
if [[ "$SDL" == "1" && "$STABLE_DISPLAY" != "1" ]]; then
    VGA_DEV="virtio-vga-gl,edid=on,xres=1920,yres=1080,xmax=1920,ymax=1080,${EDID_PROPS},${GPU_STEALTH}"
else
    VGA_DEV="virtio-vga,edid=on,xres=1920,yres=1080,xmax=1920,ymax=1080,${EDID_PROPS},${GPU_STEALTH}"
fi

# GUI 通道
DISP_ARGS=()
if [[ "$HEADLESS" == "1" ]]; then
    DISP_ARGS+=(-display none -vnc 127.0.0.1:$VNC_DISPLAY)
elif [[ "$SDL" == "1" ]]; then
    if [[ "$STABLE_DISPLAY" == "1" ]]; then
        DISP_ARGS+=(-display sdl,show-cursor=off)
    else
        DISP_ARGS+=(-display sdl,gl=on,show-cursor=off)
    fi
else
    # 默认无 GUI（纯 fb-shm 推流场景），或 --no-fb-shm 时也走这条
    DISP_ARGS+=(-display none)
fi
DISP_ARGS+=(-device "$VGA_DEV")

# fb-shm 推流通道（独立 -object，与 GUI 共存）
if [[ -n "$FB_SHM_OBJ" ]]; then
    DISP_ARGS+=(-object "$FB_SHM_OBJ")
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
    # **关键背景**：Windows 10/11 ISO 的 El Torito UEFI image 描述符 Ldsiz=1
    # sector（512B），OVMF 2.70 (EDK2 stable) 因此**拒绝**把 CDROM 当 auto-boot
    # 候选，UEFI Shell 提示 "Press any key to boot from CD" 永远等不到。
    # 直接结果：bootindex=1 在 ide-cd 上无效，OVMF 跳过 CDROM、掉进 EFI Shell。
    #
    # 修复：再挂一个 16 MiB FAT helper image (deploy/firmware/uefi-shell-
    # chainload.img) 作 bootindex=1 的 virtio-blk disk。Helper 里:
    #   \EFI\BOOT\BOOTX64.EFI  ← 是 EDK2 自带的 UEFI Shell.efi
    #   \startup.nsh           ← 自动 `connect -r` + 扫 FS0..FS9，找到带
    #                            sources\install.wim 的 CDROM 就 chainload
    #                            FS%a:\EFI\BOOT\BOOTX64.EFI
    # OVMF fallback 路径 (\EFI\BOOT\BOOTX64.EFI) 对 FAT 文件系统是 work 的，
    # 所以 virtio-blk helper 总能 boot；后面 Win Setup 出现自己的 "Press any
    # key to boot from CD" prompt，guest 内按一次空格就进 Setup。
    #
    # Helper image 不存在时由 deploy/tools/build-uefi-chainload-helper.sh 现造。
    HELPER_IMG="$(dirname "$0")/../firmware/uefi-shell-chainload.img"
    if [[ ! -f "$HELPER_IMG" ]]; then
        echo ">> chainload helper image not found, building..."
        "$(dirname "$0")/../tools/build-uefi-chainload-helper.sh" 2>&1 | sed 's/^/    /'
    fi
    CDROM_ARGS=(
        # bootindex=1: virtio-blk helper image, OVMF auto-boots its
        # \EFI\BOOT\BOOTX64.EFI (UEFI Shell) → startup.nsh → chainload Win ISO
        -drive file="$HELPER_IMG",if=none,id=cdhelp,format=raw,readonly=on
        -device "virtio-blk,drive=cdhelp,bootindex=1"

        # bootindex=2: Windows install ISO on ide-cd. OVMF can't auto-boot it
        # (El Torito UEFI image broken in MS ISO), but Shell can discover it
        # via `connect -r` + `map -r` and chainload \EFI\BOOT\BOOTX64.EFI.
        -drive file="$ISO",media=cdrom,if=none,id=cd0,readonly=on
        -device ide-cd,drive=cd0,bus=ide.0,bootindex=2
    )
    echo ">> chainload:   $HELPER_IMG (UEFI Shell auto-boots and finds the Win ISO)"
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
        # STRICT_STEALTH=1：桥接失败即 fail-fast，绝不静默回退 user-mode NAT——
        # NAT 的 10.0.2.x 子网本身就是 VM 特征，对隐身验收是致命漏判。默认（兼容
        # 启动）仍回退 NAT 但打醒目标记；ALLOW_NAT_FALLBACK=1 在 strict 下显式放行。
        if [[ "${STRICT_STEALTH:-0}" == "1" && "${ALLOW_NAT_FALLBACK:-0}" != "1" ]]; then
            echo "ERROR: $_bridge_fail" >&2
            echo "       STRICT_STEALTH=1 拒绝回退 user-mode NAT（NAT 子网是 VM 特征）。" >&2
            echo "       修桥: sudo deploy/scripts/setup-bridge.sh UPLINK=<iface>；" >&2
            echo "       或显式放行: ALLOW_NAT_FALLBACK=1 deploy/scripts/start-vm.sh ..." >&2
            exit 1
        fi
        echo ">> WARN: $_bridge_fail"
        echo ">>       falling back to user-mode NAT. Run 'sudo deploy/scripts/setup-bridge.sh'"
        echo ">>       (with UPLINK=<iface> for a LAN bridge) to enable bridge mode."
        BRIDGE=""
        STEALTH_NET_FALLBACK=1
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
    if [[ "${STEALTH_NET_FALLBACK:-0}" == "1" ]]; then
        echo ">> ⚠⚠ 本次为 user-mode NAT 回退（非 stealth 桥接）：10.0.2.x 子网是 VM 特征，勿用于隐身验收。"
    fi
fi

# -------------------------------------------------------------------
# 构造 MEMORY_ARGS：根据 NUM_DIMMS 决定 1 backend 还是 2 backend，
# 对应 1 个 NUMA node（单通道）还是 2 个 NUMA node（双通道）。
#
# prealloc=off（2026-05-25）：prealloc=on 会在开机即把整块 -m 摸一遍、钉死
# host 物理内存（实测 guest 常只用一半），多 VM 并发时直接把 32G host 逼到
# OOM-kill。prealloc 是纯 host 侧分配策略，guest 看到的 RAM 容量/SMBIOS 不
# 变 → 零反检测影响。改 lazy 后未触及的 guest 页不占物理内存，配 mem-lock=off
# 还可换出，多开稳得多。（首次访问页有极微延迟，反作弊无感。）
# -------------------------------------------------------------------
MEMORY_ARGS=(-m "${RAM}M")
if (( NUM_DIMMS == 1 )); then
    # 1 条 DIMM 占满总量，单 NUMA node 把所有 vCPU 都挂上
    MEMORY_ARGS+=(
        -object "memory-backend-memfd,id=mem0,size=${RAM}M,share=on,prealloc=off"
        -numa "node,nodeid=0,memdev=mem0,cpus=0-$((CPUS-1))"
    )
else
    # 2 条 DIMM 各占一半，双 NUMA node 配对 dual-channel 拓扑
    MEMORY_ARGS+=(
        -object "memory-backend-memfd,id=mem0,size=${PER_DIMM_MB}M,share=on,prealloc=off"
        -object "memory-backend-memfd,id=mem1,size=${PER_DIMM_MB}M,share=on,prealloc=off"
        -numa "node,nodeid=0,memdev=mem0,cpus=0-$((CPUS/2-1))"
        -numa "node,nodeid=1,memdev=mem1,cpus=$((CPUS/2))-$((CPUS-1))"
    )
fi

# -------------------------------------------------------------------
# 构造 KBD_DEVICE_ARG / POINTER_DEVICE_ARG（patch 0010 新选项）
#
# QEMU `-device` 的 prop 值不接受裸逗号（逗号是 prop 分隔符）。我们 pool 里
# 的 product 字符串如 "Logitech USB Keyboard K120" 不含逗号，安全；将来若加
# 含逗号型号需用 ',,' 转义（参考 stealth_smbios_args::_e）。
#
# 不传 serial= (P0#1)：desc_mouse/desc_keyboard/desc_tablet 的 iSerialNumber=0
# （真实 OEM 鼠键不暴露 USB serial），descriptor 里没有 serial 索引槽，传
# serial= 既不会被 guest 当作设备 serial 暴露，又会让 usb_desc_create_serial()
# 走 dev->serial 分支把字符串误写到 index 0。源码侧已守卫该 assert，这里同步
# 移除 serial= 让配置与行为一致。
# -------------------------------------------------------------------
KBD_DEVICE_ARG=(
    -device "usb-kbd,bus=xhci.0,vendorid=${KBD_VID},productid=${KBD_PID},manufacturer=${KBD_MFR},product=${KBD_PRODUCT}"
)
if [[ "${USB_RELATIVE_MOUSE:-0}" == "1" ]]; then
    POINTER_DEVICE_ARG=(
        -device "usb-mouse,bus=xhci.0,vendorid=${MOUSE_VID},productid=${MOUSE_PID},manufacturer=${MOUSE_MFR},product=${MOUSE_PRODUCT}"
    )
else
    POINTER_DEVICE_ARG=(
        -device "usb-tablet,bus=xhci.0,vendorid=${TABLET_VID},productid=${TABLET_PID},manufacturer=${TABLET_MFR},product=${TABLET_PRODUCT}"
    )
fi
