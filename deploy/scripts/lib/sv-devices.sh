# shellcheck shell=bash
# 本文件由 start-vm.sh source，设备参数数组会在后续 sv-assemble.sh 中消费，故
# 单文件分析得到的 SC2034 是跨模块误报。QEMU 的逗号属性串、相邻反斜线片段及
# 已严格校验为整数的端口变量也刻意保持为单个 argv，分别对应 SC2054/SC2140/
# SC2206；集中说明并抑制这些既有误报，避免真正的新 warning 淹没在历史噪声中。
# shellcheck disable=SC2034,SC2054,SC2140,SC2206
# -------------------------------------------------------------------
# 芯片组级设备身份来自同一个 platform manifest，不能再按 CPU 厂商粗略二分。
# Intel 同一组 PCH root port 的 device id 连续；AMD GPP 多个 function 共用 ID。
# -------------------------------------------------------------------
case "$CPU_VENDOR" in
    GenuineIntel) PLATFORM_VENDOR="intel" ;;
    AuthenticAMD) PLATFORM_VENDOR="amd" ;;
    *) echo "ERROR: 不支持的 CPU_VENDOR=$CPU_VENDOR" >&2; exit 2 ;;
esac

# PCH 三个设备继续使用同一平台 manifest。MCH 必须保留 Q35 原生
# 8086:29c0：EDK2 的 Q35 PlatformPei 依赖 host bridge device ID 识别 machine，
# 在固件早期把它覆盖为 H110/H310 ID 会让全部 vCPU 进入 CpuDeadLoop，helper 与
# Windows ISO 的读取量均为 0。这个约束不是显示问题，也不能靠更换 OVMF 或按键绕过。
# 因而 profile 中的目标 MCH 只作为平台证据保留，不投影到可启动 Linux argv；
# 客体枚举会诚实暴露 Q35 MCH。LPC/SMBus/AHCI 的 configuration identity 覆盖已
# 通过 OVMF + chainload smoke，不影响早期平台识别。板卡 subsystem 仍统一使用
# 平台已审计的 ASUS 标识；底层行为始终是 Q35/ICH9。
CHIPSET_GLOBAL_ARGS=(
    -global "ICH9-LPC.x-pci-vendor-id=${LPC_PCI_VEN:?platform 缺 LPC_PCI_VEN}"
    -global "ICH9-LPC.x-pci-device-id=${LPC_PCI_DEV:?platform 缺 LPC_PCI_DEV}"
    -global "ICH9-LPC.x-pci-revision=${LPC_REV:?platform 缺 LPC_REV}"
    -global "ICH9-LPC.x-pci-sub-vendor-id=${BOARD_SUBSYS_VEN}"
    -global "ICH9-LPC.x-pci-sub-device-id=${BOARD_SUBSYS_DEV}"
    -global "ICH9-SMB.x-pci-vendor-id=${SMBUS_PCI_VEN:?platform 缺 SMBUS_PCI_VEN}"
    -global "ICH9-SMB.x-pci-device-id=${SMBUS_PCI_DEV:?platform 缺 SMBUS_PCI_DEV}"
    -global "ICH9-SMB.x-pci-revision=${SMBUS_REV:?platform 缺 SMBUS_REV}"
    -global "ICH9-SMB.x-pci-sub-vendor-id=${BOARD_SUBSYS_VEN}"
    -global "ICH9-SMB.x-pci-sub-device-id=${BOARD_SUBSYS_DEV}"
    -global "ich9-ahci.x-pci-vendor-id=${AHCI_PCI_VEN:?platform 缺 AHCI_PCI_VEN}"
    -global "ich9-ahci.x-pci-device-id=${AHCI_PCI_DEV:?platform 缺 AHCI_PCI_DEV}"
    -global "ich9-ahci.x-pci-revision=${AHCI_REV:?platform 缺 AHCI_REV}"
    -global "ich9-ahci.x-pci-sub-vendor-id=${BOARD_SUBSYS_VEN}"
    -global "ich9-ahci.x-pci-sub-device-id=${BOARD_SUBSYS_DEV}"
)

RP_VEN="${ROOT_PORT_PCI_VEN:?platform 缺 ROOT_PORT_PCI_VEN}"
RP_REV="${ROOT_PORT_REV:?platform 缺 ROOT_PORT_REV}"
_rp_base="${ROOT_PORT_PCI_DEV:?platform 缺 ROOT_PORT_PCI_DEV}"
RP_DEV=("$_rp_base" "$_rp_base" "$_rp_base" "$_rp_base")
if [[ "$PLATFORM_VENDOR" == "intel" &&
      "${PLATFORM_DEVICE_IDENTITY_SCOPE:-}" != explicit_virtual_compatibility ]]; then
    for _rp_i in 0 1 2 3; do
        printf -v 'RP_DEV[_rp_i]' '0x%04x' "$(( _rp_base + _rp_i ))"
    done
fi

case "${NVME_MAX_PCIE_GENERATION:-0}" in
    1) _nvme_link_speed="2_5" ;;
    2) _nvme_link_speed="5" ;;
    3) _nvme_link_speed="8" ;;
    4) _nvme_link_speed="16" ;;
    *) echo "ERROR: NVME_MAX_PCIE_GENERATION 非法" >&2; exit 2 ;;
esac
_nvme_link_width="${NVME_LANES:-4}"

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
"hotplug=off,x-speed=${_nvme_link_speed},x-width=${_nvme_link_width},x-pci-vendor-id=${RP_VEN},"\
"x-pci-device-id=${RP_DEV[1]},x-pci-revision=${RP_REV}"
    -device "pcie-root-port,id=rp2,slot=2,bus=pcie.0,"\
"hotplug=off,x-speed=2_5,x-width=1,x-pci-vendor-id=${RP_VEN},"\
"x-pci-device-id=${RP_DEV[2]},x-pci-revision=${RP_REV}"
    -device "pcie-root-port,id=rp3,slot=3,bus=pcie.0,"\
"hotplug=off,x-speed=2_5,x-width=1,x-pci-vendor-id=${RP_VEN},"\
"x-pci-device-id=${RP_DEV[3]},x-pci-revision=${RP_REV}"
)

# -------------------------------------------------------------------
# Guest display 使用 virtio-gpu-gl 给宿主 SDL/EGL 与支持 virgl 的客体提供 GL
# 路径。当前 Windows 使用 stock VioGpuDod Display-Only 驱动，并没有 Mesa
# virgl/Direct3D 渲染栈；浅层名称与 PCI 投影也不会增加 Direct3D、CUDA 或 NVENC。
# -------------------------------------------------------------------
# GPU subsystem spoof: 主 ID 留 1AF4:1050 (virtio) 让 stock virtio-win 绑定，
# subsys 改成 profile 选定的 GPU (NVIDIA / AMD)。
# apply-gpu-spoof.ps1 与双架构系统搜索 NVAPI 在 guest 用户态把
# 可投影字段对齐到 profile.GPU_NAME；它们不会改变内核看到的物理主 ID。
GPU_STEALTH="x-pci-sub-vendor-id=${GPU_PCI_VEN},x-pci-sub-device-id=${GPU_PCI_DEV},x-pci-revision=${GPU_REV}"

# sv-cli 已在所有宿主副作用前拒绝历史深层开关。这里保留第二道门禁，防止开发者在
# 单独 source 设备模块或未来重排模块时，意外恢复主 VEN/DEV 覆盖。
if [[ "${GPU_SELFSIGNED:-0}" != "0" ]]; then
    echo "ERROR: GPU_SELFSIGNED 深层/自签路径已移除；请保持物理 PCI 1AF4:1050" >&2
    exit 2
fi

# 显示后端选择
#
# 三个独立通道，可叠加（fb-shm 默认开，GUI 三选一）：
#
# 1) fb-shm（FB_SHM=1，默认）
#    -object fb-shm,id=stealth-${INSTANCE},path=...
#    共享内存推流：consumer 直接 mmap，但源帧写入 SHM 仍可能经过 CPU/PBO
#    拷贝。配合 scripts/qemu-fb-shm-stream.py → ffmpeg/NVENC。
#    与下面三种 GUI 通道全部可共存（独立 DCL，互不影响）。
#
# 2) GUI 通道（互斥四选一）
#    --sdl       : -display sdl,...        (本地交互窗口；DNF 调试)
#    --headless  : -display none -vnc ...  (VNC 远程)
#    --no-sdl    : -display none           (无 GUI；纯推流场景)
#    --gpu-sdl-egl
#                : -display sdl,gl=on       (兼容模式名)
#                  QEMU 11 SDL 后端会自行探测 EGL；不再创建私有 X11 子窗口，
#                  普通 texture 可尝试导出；只有显式 --gpu-zerocopy
#                  才增加 blob/hostmem，为 fb-shm 提供 dma-buf 条件。
#    --gpu-headless
#                : -display egl-headless   (rendernode EGL，给 fb-shm 走 GPU 导出)
#
# STABLE_DISPLAY=0（显式 opt-in）: 在 --sdl / --gpu-headless 模式下生效，
#   启 virtio-vga-gl，给宿主显示/推流或支持 virgl 的非 Windows 客体使用 GL；
#   stock VioGpuDod 下的 Windows 客体仍是 Display-Only。
#   普通 --sdl 与兼容名 --gpu-sdl-egl 都使用 QEMU 11 官方 SDL/GL，但
#   默认是不暴露 blob/hostmem PCI BAR 的 gl-safe；只有显式 --gpu-zerocopy
#   才开启这组能力。gl-safe 仍会广告 virtio VIRGL/CONTEXT_INIT feature，
#   只是 BAR 布局不因 hostmem 重排；导出失败时仍自动走 SHM fallback。
#   --gpu-headless 则显式选择无窗口 rendernode EGL 路径。
#
# STABLE_DISPLAY=1（默认）: 强制 virtio-vga，不开宿主 -gl/virgl，规避长期运行后
#   触发的 DXGKRNL TDR/BSOD（"VIDEO_DXGKRNL_FATAL_ERROR" / "VIDEO_SCHEDULER_
#   INTERNAL_ERROR"）。它只改变 QEMU 的宿主显示/推流路径；Windows stock
#   VioGpuDod 在 0/1 两种模式下都没有客体 Direct3D，应用均只能走 WARP 等回退。
#   (注：--no-sdl/--headless 没有窗口 GL context，仍然走 stable 路径)
STABLE_DISPLAY=${STABLE_DISPLAY:-1}
case "$STABLE_DISPLAY" in
    0|1) ;;
    *)
        echo "ERROR: STABLE_DISPLAY 必须是 0 或 1 (实际: '$STABLE_DISPLAY')" >&2
        exit 2
        ;;
esac
GPU_DISPLAY_MODE=${GPU_DISPLAY:-sdl}
GPU_EGL_HEADLESS=0
if [[ "$GPU_DISPLAY_MODE" == "egl-headless" && "$STABLE_DISPLAY" != "1" ]]; then
    GPU_EGL_HEADLESS=1
fi
# 中文注释：`sdl-egl` 只保留为旧配置的兼容名字。QEMU 11 会在官方 SDL
# backend 内探测 EGL 并设置 SDL hint，因此启动器只负责生成统一的
# `-display sdl,gl=on`，不再传递私有环境变量或维护额外 X11 子窗口。
GPU_GL_DISPLAY=0
if [[ "$STABLE_DISPLAY" != "1" && ( "$SDL" == "1" || "$GPU_EGL_HEADLESS" == "1" ) ]]; then
    GPU_GL_DISPLAY=1
fi

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
# 固定 native mode 是本部署画像的显式 opt-in；普通 QEMU 调用方仍保留随
# display-info/UI resize 更新 EDID 的上游行为。
EDID_PROPS="edid-fixed-native=on,edid-vendor=${EDID_VENDOR},edid-name=${EDID_NAME},edid-serial=${EDID_SERIAL},edid-width-mm=${EDID_WIDTH_MM},edid-height-mm=${EDID_HEIGHT_MM}"
EDID_PROPS+=",edid-product-id=${EDID_PRODUCT_ID},edid-manufacture-week=${EDID_MANUFACTURE_WEEK},edid-manufacture-year=${EDID_MANUFACTURE_YEAR}"
EDID_PROPS+=",edid-video-input=${EDID_VIDEO_INPUT},edid-min-vfreq-hz=${EDID_MIN_VFREQ_HZ},edid-max-vfreq-hz=${EDID_MAX_VFREQ_HZ}"
EDID_PROPS+=",edid-min-hfreq-khz=${EDID_MIN_HFREQ_KHZ},edid-max-hfreq-khz=${EDID_MAX_HFREQ_KHZ},edid-max-pixel-clock-mhz=${EDID_MAX_PIXEL_CLOCK_MHZ}"
EDID_PROPS+=",edid-secondary-xres=${EDID_SECONDARY_XRES},edid-secondary-yres=${EDID_SECONDARY_YRES},edid-secondary-refresh-rate=${EDID_SECONDARY_REFRESH_RATE}"
if [[ "$GPU_GL_DISPLAY" == "1" ]]; then
    VGA_DEV="virtio-vga-gl,edid=on,xres=1920,yres=1080,xmax=1920,ymax=1080,${EDID_PROPS},${GPU_STEALTH}"
    if [[ "${GPU_ZEROCOPY:-0}" == "1" ]]; then
        # 中文注释：blob=true 打开 virtio-gpu resource blob，hostmem 暴露
        # host-visible window，为 Linux dma-buf 或 Windows GPU shared handle 提供
        # 必要条件。这只是能力偏好：guest/renderer 没给可共享 backing 时，fb-shm
        # 仍保留既有 SHM/CPU readback，不会因为零拷贝不可用而中断显示或推流。
        VGA_DEV="${VGA_DEV},blob=true,hostmem=${GPU_HOSTMEM:-256M}"
    fi
else
    VGA_DEV="virtio-vga,edid=on,xres=1920,yres=1080,xmax=1920,ymax=1080,${EDID_PROPS},${GPU_STEALTH}"
fi

# GUI 通道
DISP_ARGS=()
if [[ "$HEADLESS" == "1" ]]; then
    DISP_ARGS+=(-display none -vnc 127.0.0.1:$VNC_DISPLAY)
elif [[ "$GPU_EGL_HEADLESS" == "1" ]]; then
    _egl_display="egl-headless"
    if [[ -n "${GPU_RENDERNODE:-}" ]]; then
        _egl_display="${_egl_display},rendernode=${GPU_RENDERNODE}"
    fi
    DISP_ARGS+=(-display "$_egl_display")
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

# 键盘走 USB HID (usb-kbd) — DirectInput / Raw Input 类游戏 (DNF / 仿真机)
# 只读 USB keyboard, PS/2 keyboard 在它们眼里不存在 → 游戏内按键完全无响应.
# q35 i8042 控制器仍默认带, 但没东西往那里发 scancode 就是空通道, 不影响.
# opt-in QEMU 策略直接看 Windows 回传的 HID LED 位：每轮只有明确 OFF 才异步
# 送一个原子 NumLock click，并等到 ON 确认；连续 OFF 不会重复送键。这样固件、
# Welcome 和用户会话先后写 LED 时都能收敛，不使用延时猜测或盲 toggle。
KBD_NUMLOCK_PROP=""
if [[ "${GUEST_NUMLOCK:-1}" == "1" ]]; then
    KBD_NUMLOCK_PROP=',x-force-numlock-on=on'
    KBD_HINT='USB keyboard (DirectInput/Raw Input 兼容); guest NumLock 强制 ON'
else
    KBD_HINT='USB keyboard (DirectInput/Raw Input 兼容); guest NumLock 自动策略已关闭'
fi

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
# Network backend: 显式 VLAN 使用预创建 access TAP；未传 VLAN 时逐行保留
# 原 bridge/user-mode NAT 逻辑。两条路径不能共用 qemu-bridge-helper：该 helper
# 只收到 bridge 名，不知道 VID，连接后再改 PVID 还会产生首包串 VLAN 的竞态。
# -------------------------------------------------------------------
if [[ -n "${VLAN_ID:-}" ]]; then
    NET_ARGS=(
        -netdev "tap,id=net0,ifname=$VLAN_TAP_IF,script=no,downscript=$SV_VLAN_DOWNSCRIPT"
    )
    echo ">> network:     access VLAN $VLAN_ID via $VLAN_TAP_IF on br0 (guest receives untagged frames)"
else
    # 以下无 VLAN 分支保持历史行为：br0 可用则桥接；普通模式下不可用时仍按
    # STRICT_STEALTH/ALLOW_NAT_FALLBACK 的原规则决定报错或回退 NAT。
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
                echo "       修桥: sudo UPLINK=<iface> deploy/scripts/setup-bridge.sh；" >&2
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
fi

# -------------------------------------------------------------------
# 构造 MEMORY_ARGS：消费级单路平台无论插一条还是两条 DIMM，都只有一个 NUMA
# node。内存通道/DIMM 数属于 SMBIOS/SPD 拓扑，不能错误映射成 guest NUMA node。
#
# prealloc=off（2026-05-25）：prealloc=on 会在开机即把整块 -m 摸一遍、钉死
# host 物理内存（实测 guest 常只用一半），多 VM 并发时直接把 32G host 逼到
# OOM-kill。prealloc 是纯 host 侧分配策略，guest 看到的 RAM 容量/SMBIOS 不
# 变 → 零反检测影响。改 lazy 后未触及的 guest 页不占物理内存，配 mem-lock=off
# 还可换出，多开稳得多。（首次访问页有极微延迟，仿真机无感。）
# -------------------------------------------------------------------
MEMORY_ARGS=(-m "${RAM}M")
MEMORY_ARGS+=(
    -object "memory-backend-memfd,id=mem0,size=${RAM}M,share=on,prealloc=off"
    -numa "node,nodeid=0,memdev=mem0,cpus=0-$((CPUS-1))"
)

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
    -device "usb-kbd,id=kbd0,bus=xhci.0,vendorid=${KBD_VID},productid=${KBD_PID},manufacturer=${KBD_MFR},product=${KBD_PRODUCT}${KBD_NUMLOCK_PROP}"
)
if [[ "${USB_RELATIVE_MOUSE:-0}" == "1" ]]; then
    POINTER_DEVICE_ARG=(
        -device "usb-mouse,bus=xhci.0,vendorid=${MOUSE_VID},productid=${MOUSE_PID},manufacturer=${MOUSE_MFR},product=${MOUSE_PRODUCT}"
    )
else
    # usb-tablet 只实现通用绝对坐标指针，没有压力、倾角和品牌 report protocol。
    # C 层会拒绝品牌覆盖；这里显式保留通用描述，避免冒充 HUION/VEIKK/XP-Pen。
    POINTER_DEVICE_ARG=(
        -device "usb-tablet,bus=xhci.0"
    )
fi
