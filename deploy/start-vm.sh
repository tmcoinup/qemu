#!/usr/bin/env bash
# start-vm.sh — 统一 QEMU 启动脚本
#
# 用法:  ./start-vm.sh <vm_id> [options]
#   --install [iso]    安装模式 (NO_VFIO 旁路 vfio-pci，防止 OVMF PCI 枚举挂起)
#                      iso 省略时用 $DEFAULT_ISO (默认 /home/ubuntu/images/win10-ltsc.iso)
#   --rdp              默认 — 用 std-vga 给 RDP 用 (适合装完驱动后生产使用)
#   --gtk              桌面 gtk 窗口 (例外的人工交互路径，最多 2 张物理 GPU 占用)
#   --sdl              桌面 sdl 窗口 (同上)
#   --no-gpu           调试/首次启动不挂 vGPU (std-vga 唯一显示)
#   --vnc <disp>       指定 VNC display (默认 :${VM_ID})
#   --no-tame-gnome    不让 viewer 动态处理 GNOME/IBus 宿主快捷键
#   --tame-gnome       强制让鼠标在 viewer 内时临时关闭宿主 Super/Alt+Tab 快捷键
#   --extra "<args>"   透传额外 QEMU 参数
#
# 环境变量:
#   QEMU_BIN         QEMU 二进制路径 (默认 build/qemu-system-x86_64)
#   OVMF_CODE        OVMF_CODE.fd 路径
#   OVMF_VARS        OVMF_VARS.fd 模板
#   VM_DISK_DIR      VM qcow2 存放目录 (默认 /vms)
#   BR0              网桥名 (默认 br0)
#   GUEST_MEM_MB     分配内存 (默认 8192)

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"

# Default sudo password (memory: user_sudo_password.md).  Export so the
# mdev sysfs-write helper in lib/vgpu-mdev.sh sees it without prompting.
export SUDO_PASSWORD="${SUDO_PASSWORD:-123456}"

# 所有 VM 数据 (configs / qcow2 / runtime sockets / logs) 的 root。
# Env VM_ROOT 可以覆盖（多机/多盘场景）。
export VM_ROOT="${VM_ROOT:-/home/ubuntu/images/vms}"
mkdir -p "$VM_ROOT/configs" "$VM_ROOT/run" "$VM_ROOT/log"

# shellcheck source=lib/vgpu-mdev.sh
source "$here/lib/vgpu-mdev.sh"
# shellcheck source=lib/gnome-shortcuts.sh
source "$here/lib/gnome-shortcuts.sh"

VM_ID="${1:-}"
[[ -z "$VM_ID" || ! "$VM_ID" =~ ^[1-9][0-9]*$ ]] && {
    echo "usage: $0 <vm_id> [--install iso|--rdp|--gtk|--sdl|--no-gpu|--vnc :N|--tame-gnome|--no-tame-gnome|--extra \"...\"]" >&2
    exit 2
}
shift

# Source vm conf 先 — 让里面的 SPOOF / GUEST_MEM_MB / VNC_DISPLAY 等
# per-VM 默认值优先于脚本默认，但仍然能被 env / CLI 覆盖。
CONF="${VM_ROOT}/configs/vm${VM_ID}.conf"
DISK_PATH="${VM_ROOT}/win10-vm${VM_ID}.qcow2"

# Conf / disk 不存在时自动 bootstrap（首次部署 / delete-vm 后）。
# 这样 fresh 装机只需 ./start-vm.sh 1 --install 一条命令。
if [[ ! -f "$CONF" ]]; then
    echo "[start-vm] $CONF 不存在，自动 ./create-vm.sh ${VM_ID}"
    "$here/create-vm.sh" "$VM_ID"
fi
if [[ ! -f "$DISK_PATH" ]]; then
    echo "[start-vm] $DISK_PATH 不存在，自动 ./create-disk.sh ${VM_ID}"
    "$here/create-disk.sh" "$VM_ID"
fi
# shellcheck source=/dev/null
source "$CONF"

MODE=rdp             # 默认 RDP

# SPOOF_MODE:  A | B | off
#   A   = PCI subsystem ID 改成消费卡 (vfio x-pci-vendor-id 等) + 注册表 Name 改
#         反虚拟化最彻底，但 NVIDIA driver 反虚拟化检测可能给 Code 43；
#         需要 patch-grid-strings 配合，对应 memory project_dnf_stealth_stack
#   B   = 仅注册表 Name spoof，PCI 保留 RTX 6000 真身
#         driver 工作最稳；GPU-Z 看 PCI 会暴露真身但 Win32_VideoController.Name
#         显示 GeForce GT 1030
#   off = 完全无 spoof（装 GRID 驱动 / 调试时用）
#
# 优先级（高 → 低）：CLI > env > vm.conf SPOOF_MODE= > 默认 A
# 旧字段 SPOOF=0/1 仍兼容（SPOOF=1→A, SPOOF=0→off）。
SPOOF_MODE=${SPOOF_MODE:-A}
if [[ -n "${SPOOF:-}" ]]; then
    [[ "$SPOOF" == "1" ]] && SPOOF_MODE=A || SPOOF_MODE=off
fi
ISO=""
EXTRA=""
VIEWER_ARGS=()
VNC_DISPLAY=":${VM_ID}"
DEFAULT_ISO="/home/ubuntu/images/win10-ltsc.iso"
TAME_GNOME="${TAME_GNOME:-auto}"

# ivshmem (Inter-VM shared memory) — 用作 stream / 输入数据通道，替代
# TCP socket。host 后端文件 /dev/shm/nv-shmem-vm${VM_ID}，guest 端通过
# ivshmem.sys 驱动暴露为 PCI BAR2 内存映射。0=禁用，>0=启用并指定大小。
IVSHMEM_SIZE_MB=${IVSHMEM_SIZE_MB:-64}

while (( $# > 0 )); do
    case "$1" in
        --install)
            MODE=install
            # 下一个参数如果不是 --开头就当作 ISO 路径，否则走默认
            if [[ $# -ge 2 && "$2" != --* ]]; then ISO="$2"; shift 2
            else ISO="$DEFAULT_ISO"; shift
            fi ;;
        --rdp)     MODE=rdp; shift ;;
        --gtk)     MODE=gtk; shift ;;
        --sdl)     MODE=sdl; shift ;;
        --no-gpu)  MODE=no-gpu; shift ;;
        --vnc)     VNC_DISPLAY="$2"; shift 2 ;;
        --no-spoof)        SPOOF_MODE=off; shift ;;    # 装 GRID 驱动 / 调试用
        --spoof)           SPOOF_MODE=A;   shift ;;    # PCI + name spoof（彻底）
        --spoof-name-only) SPOOF_MODE=B;   shift ;;    # 仅注册表 name spoof
        --spoof-mode)      SPOOF_MODE="$2"; shift 2 ;; # 直接指定 A/B/off
        --no-shmem) IVSHMEM_SIZE_MB=0; shift ;;     # 禁用 ivshmem 通道
        --shmem)    IVSHMEM_SIZE_MB="$2"; shift 2 ;; # 指定大小 (MB)
        --tame-gnome) TAME_GNOME=1; shift ;;
        --no-tame-gnome) TAME_GNOME=0; shift ;;
        --fullscreen|--windowed) VIEWER_ARGS+=("$1"); shift ;;
        --width|--height) VIEWER_ARGS+=("$1" "$2"); shift 2 ;;
        --extra)   EXTRA="$2"; shift 2 ;;
        *) echo "未知参数: $1" >&2; exit 2 ;;
    esac
done

: "${QEMU_BIN:=$here/../build/qemu-system-x86_64}"
: "${OVMF_CODE:=/usr/share/OVMF/OVMF_CODE_4M.fd}"
: "${OVMF_VARS:=/usr/share/OVMF/OVMF_VARS_4M.fd}"
: "${VM_DISK_DIR:=$VM_ROOT}"
: "${BR0:=br0}"
: "${GUEST_MEM_MB:=8192}"

[[ -x "$QEMU_BIN" ]] || { echo "QEMU 不存在或没执行权: $QEMU_BIN" >&2; exit 1; }

# VM 私有 OVMF_VARS（保留 UEFI 变量、Boot entry 等）
VARS_PRIV="$VM_DISK_DIR/vm${VM_ID}_VARS.fd"
if [[ ! -f "$VARS_PRIV" ]]; then
    if [[ -w "$VM_DISK_DIR" ]]; then
        install -m 0644 "$OVMF_VARS" "$VARS_PRIV"
    else
        sudo install -m 0644 "$OVMF_VARS" "$VARS_PRIV"
    fi
fi
DISK="$VM_DISK_DIR/win10-vm${VM_ID}.qcow2"

# ─── 主板 PCI subsystem ID (按 BOARD_BRAND 查表) ─────────────────────────
# 未显式设 subsys 的 PCI 设备 (AHCI / NVMe / e1000e 等) 继承此全局默认值；
# QEMU 原生默认 0x1AF4:0x1100 (Red Hat/QEMU) 是典型虚拟化指纹。
case "$BOARD_BRAND" in
    ASUS|asus)                  export QEMU_PCI_SUBVENDOR_ID=0x1043; export QEMU_PCI_SUBDEVICE_ID=0x8694 ;;
    MSI|msi)                    export QEMU_PCI_SUBVENDOR_ID=0x1462; export QEMU_PCI_SUBDEVICE_ID=0x7B94 ;;
    Gigabyte|gigabyte)          export QEMU_PCI_SUBVENDOR_ID=0x1458; export QEMU_PCI_SUBDEVICE_ID=0x5001 ;;
    ASRock|asrock)              export QEMU_PCI_SUBVENDOR_ID=0x1849; export QEMU_PCI_SUBDEVICE_ID=0x2922 ;;
    *)                          export QEMU_PCI_SUBVENDOR_ID=0x1043; export QEMU_PCI_SUBDEVICE_ID=0x8694 ;;
esac

# ─── CPU 真机 part number / 频率 / brand (按 CPU 型号查表) ─────────────
case "$CPU_MODEL" in
    Core-i5-4590)
        CPU_PART=SR1QJ; CPU_BASE_MHZ=3300; CPU_MAX_MHZ=3700
        CPU_BRAND_STRING='Intel(R) Core(TM) i5-4590 CPU @ 3.30GHz'
        ;;
    Core-i5-6500)
        CPU_PART=SR2L6; CPU_BASE_MHZ=3200; CPU_MAX_MHZ=3600
        CPU_BRAND_STRING='Intel(R) Core(TM) i5-6500 CPU @ 3.20GHz'
        ;;
    Core-i3-8100)
        CPU_PART=SR3N5; CPU_BASE_MHZ=3600; CPU_MAX_MHZ=3600
        CPU_BRAND_STRING='Intel(R) Core(TM) i3-8100 CPU @ 3.60GHz'
        ;;
    *)
        CPU_PART=UNKN; CPU_BASE_MHZ=$(( TSC_FREQ / 1000000 )); CPU_MAX_MHZ=$CPU_BASE_MHZ
        CPU_BRAND_STRING='Intel(R) Core(TM) CPU'
        ;;
esac

# ─── SMBIOS 伪装字符串拼装 ───────────────────────────────────────────────────
SMBIOS=()
SMBIOS+=( -smbios "type=0,vendor=American Megatrends Inc.,version=${BIOS_VER},date=${BIOS_DATE},uefi=on" )
SMBIOS+=( -smbios "type=1,manufacturer=${BOARD_BRAND},product=${BOARD_MODEL},version=System Version,serial=${SYS_SN},uuid=${VM_UUID},sku=SKU,family=${BOARD_BRAND}" )
# Must pass version= explicitly. Without it, smbios_set_defaults() inherits
# version from mc->name, i.e. "pc-q35-11.0", which is a textbook QEMU leak.
SMBIOS+=( -smbios "type=2,manufacturer=${BOARD_BRAND},product=${BOARD_MODEL},version=1.0,serial=${MB_SN},asset=Default string,location=Default string" )
SMBIOS+=( -smbios "type=3,manufacturer=${BOARD_BRAND},version=1.0,serial=${CHASSIS_SN},asset=Default string,sku=Default string,chassis_type=3" )
# type 4 (Processor) — 真机里 wmic cpu get 的字段。serial 空是 Intel 惯例；asset
# "To Be Filled By O.E.M." 也是常见零售机主板 BIOS 默认字串。
SMBIOS+=( -smbios "type=4,sock_pfx=CPU,manufacturer=Intel(R) Corporation,version=${CPU_BRAND_STRING},max-speed=${CPU_MAX_MHZ},current-speed=${CPU_BASE_MHZ},serial=To Be Filled By O.E.M.,asset=To Be Filled By O.E.M.,part=${CPU_PART},processor-family=205" )
# type 7 (Cache) — 物理机 Win32_CacheMemory 不为空。Skylake 4c4t 典型:
#   L1: 128 KB unified, 8-way; L2: 1 MB, 4-way; L3: 6 MB, 16-way
# (Coffee Lake i3-8100 相近；Haswell i5-4590 L3=6MB/L2=1MB 也近似)
SMBIOS+=( -smbios "type=7,socket_designation=L1 Cache,level=1,installed_size=128,max_size=128,associativity=7,cache_type=5" )
SMBIOS+=( -smbios "type=7,socket_designation=L2 Cache,level=2,installed_size=1024,max_size=1024,associativity=5,cache_type=5" )
SMBIOS+=( -smbios "type=7,socket_designation=L3 Cache,level=3,installed_size=6144,max_size=6144,associativity=8,cache_type=5" )
# type 9 (System Slots) — 物理机有若干 PCIe slot entry。至少给一个 PCIe Gen3 x16
# (for GPU) + 一个 Gen2 x1 让"System Slots"列表看起来像真主板。
#   slot_type: 0xB2 = PCI Express Gen 3 x16 ; 0xA8 = PCIe Gen 2 x1
#   current_usage: 0x03 Available, 0x04 In Use
#   slot_length: 0x03 Short, 0x04 Long
#   chars1 0x0C (3.3V + shared opening); chars2 0x01 (PME)
SMBIOS+=( -smbios "type=9,slot_designation=PCIEX16_1,slot_type=178,slot_data_bus_width=13,current_usage=4,slot_length=4,slot_id=1,slot_characteristics1=12,slot_characteristics2=1" )
SMBIOS+=( -smbios "type=9,slot_designation=PCIEX1_1,slot_type=168,slot_data_bus_width=8,current_usage=3,slot_length=3,slot_id=2,slot_characteristics1=12,slot_characteristics2=1" )
# type 11 (OEM Strings) — 真机 BIOS 常有若干无意义字符串，我们塞 2-3 条像 ASUS/MSI
# 出厂机默认字符串那样。"Default string" 大量真机里会出现。
SMBIOS+=( -smbios "type=11,value=Default string" )
SMBIOS+=( -smbios "type=11,value=To Be Filled By O.E.M." )
# DIMM (speed + 真实 memtype + 64-bit data width) — QEMU 只生成一条 type 17，
# 由 -m 对应的 DIMM 容量自动填 size，我们这里只给品牌/速率/类型。
SMBIOS+=( -smbios "type=17,loc_pfx=DIMM,bank=BANK,manufacturer=${MEM_BRAND},part=${MEM_MODEL},serial=${MEM_SN},asset=9876543210,speed=${MEM_SPEED},memtype=${MEM_TYPE_BYTE},typedetail=0x80,width=${MEM_WIDTH},totalwidth=${MEM_WIDTH}" )

# ─── CPU / machine 参数 ─────────────────────────────────────────────────────
# kvm=off 关 KVM 签名；x-hv-stealth=on 关 HYPERVISOR bit；
# +invtsc 让 rdtsc 对 guest 稳定。
#
# 这里不用 `enforce`：宿主是 E5-2696 v4 Broadwell，而 Core-i5-6500/i3-8100
# 的 Skylake+ 指令 (clflushopt/xsavec/xgetbv1) 宿主 KVM 无法提供；enforce 会
# 让 QEMU 拒绝启动。让 QEMU 自动降级给 warning 即可 —— guest 里 CPUID 里这
# 几位会是 0，TP 并不逐位校验 Skylake 特有扩展。
CPU_ARGS="${CPU_MODEL},kvm=off,x-hv-stealth=on,+invtsc,vmx=off,hypervisor=off,vmware-cpuid-freq=off,tsc-freq=${TSC_FREQ}"
MACHINE_ARGS="q35,accel=kvm,vmport=off,smm=on,kernel-irqchip=split,hpet=off"
MACHINE_ARGS+=",x-oem-id=ALASKA,x-oem-table-id=A M I"  # 覆盖 QEMU ACPI OEM ID (QEMU→AMI)

# ─── 网络 ───────────────────────────────────────────────────────────────────
NET_ARGS=( -netdev "bridge,id=net0,br=${BR0}" -device "e1000e,netdev=net0,mac=${VM_MAC},bus=pcie.0,addr=0x4" )

# ─── 存储 (NVMe 呈现 SSD 品牌/型号/序列号) ─────────────────────────────────
# Windows 安装盘: AHCI CDROM 引导  +  NVMe 主盘
DRIVE_ARGS=()
DRIVE_ARGS+=( -drive "file=${DISK},if=none,id=ssd0,discard=unmap,format=qcow2,cache=none,aio=native" )
# NVMe controller 的 Identify Model Number — 没有本仓库的 model 属性支持时
# NVMe 会显示 "QEMU NVMe Ctrl"，被当成虚拟机明显线索。
# bootindex=2：CDROM (1) 优先于 NVMe (2)。Windows ISO 的 efi loader
# 会显示 "Press any key to boot from CD or DVD..." 倒计时 5s：
#   按键   → 启动 ISO 装机
#   不按键 → loader 自然退出 → OVMF fallback 到 NVMe → 进 Windows
# 这样装完后即使保持 install 模式，下次 reboot 不按键就直接进系统。
DRIVE_ARGS+=( -device "nvme,drive=ssd0,bootindex=2,serial=${SSD_SN},model=${SSD_BRAND} ${SSD_MODEL},id=nvme0" )

# ─── 光驱 stealth：任何模式都挂一个 "看起来真实" 的 ATAPI ODD  ────────────
# Q35 板载 ICH9-AHCI (VEN_8086&DEV_2922) 自动给 ide.0 挂一个空的 CDROM，
# 不显式配置时 Windows 里会看到 "QEMU QEMU DVD-ROM"。我们显式挂同一 bus
# ide.0 并给一个常见品牌 model，覆盖 QEMU default。
#   - 生产 (rdp/gtk/sdl/no-gpu): 挂空光驱 (media=cdrom, 无 file=)，无 bootindex
#   - install: 同一光驱挂 ISO，bootindex=1 (优先于 NVMe=2)
: "${ODD_MODEL:=TSSTcorp CDDVDW SH-224DB}"
: "${ODD_SERIAL:=R8PG6VCD${VM_ID}23456}"  # 每 VM 微调避免冲突
if [[ "$MODE" == "install" ]]; then
    [[ -f "$ISO" ]] || { echo "ISO 不存在: $ISO" >&2; exit 1; }
    DRIVE_ARGS+=( -drive "file=${ISO},if=none,id=odd0,media=cdrom,readonly=on" )
    DRIVE_ARGS+=( -device "ide-cd,drive=odd0,bus=ide.0,bootindex=1,model=${ODD_MODEL},serial=${ODD_SERIAL}" )
else
    # 空光驱 (壳子) — 物理机都有，让 Windows 认到 TSSTcorp 而非 QEMU
    DRIVE_ARGS+=( -drive "if=none,id=odd0,media=cdrom,readonly=on" )
    DRIVE_ARGS+=( -device "ide-cd,drive=odd0,bus=ide.0,model=${ODD_MODEL},serial=${ODD_SERIAL}" )
fi

# ─── 图形 / vGPU ──────────────────────────────────────────────────────────
GFX_ARGS=()
case "$MODE" in
    install)
        # 装机/重装/UEFI 救援：std-vga + 本地窗口直接弹（不挂 vfio-pci，
        # memory feedback_no_vfio_install: vGPU 在装机阶段会让 OVMF
        # PCI 枚举挂起）。
        #
        # 后端选择 (env GFX_BACKEND):
        #   gtk (默认)  GTK 是 Wayland 原生，渲染最稳。Ubuntu Wayland
        #               session 下 SDL2 + std-vga 实测会画面错位/重影
        #               (软件 renderer 跟 framebuffer 缩放不对齐)，
        #               GTK 没这问题。
        #   sdl         SDL2 (gl=off 软件渲染)。X11 session OK；Wayland
        #               下慎用，可能错位。
        # 两种都需要 QEMU build 带相应支持，没的话跑
        # ./deploy/host/build-qemu.sh 重编。
        GFX_ARGS+=( -vga std )
        case "${GFX_BACKEND:-gtk}" in
            sdl) GFX_ARGS+=( -display sdl,gl=off ) ;;
            gtk) GFX_ARGS+=( -display gtk,gl=off ) ;;
            *)   echo "未知 GFX_BACKEND=${GFX_BACKEND} (sdl|gtk)" >&2; exit 2 ;;
        esac
        ;;
    no-gpu)
        # 远程救援：std-vga + VNC，host 没图形/SSH 远程登录时用。
        # 用 vncviewer localhost:590${VM_ID} 接。
        GFX_ARGS+=( -vga std )
        GFX_ARGS+=( -display "vnc=${VNC_DISPLAY}" )
        ;;
    rdp)
        # 生产路径: vGPU + 侧挂 std-vga 供前期登录；进系统后由 xfreerdp 接管
        MDEV_UUID=$(uuidgen)
        mdev_allocate "${GPU_PROFILE}" "$MDEV_UUID" >/dev/null || {
            echo "mdev 分配失败 — 排查 sudo / VGPU_MGPU=${VGPU_MGPU:-?} /" >&2
            echo "  vgpu_unlock 是否就绪。一条龙模式下 guest 没 GPU 起不来 viewer，硬退" >&2
            exit 1
        }
        if [[ -n "$MDEV_UUID" ]]; then
            # enable-migration=off: NVIDIA vGPU 驱动不支持 vfio migration
            # uapi。QEMU 11 默认开 migration 会让 guest 内 HAL 读 PCI 寄存器
            # 时拿到坏数据 → Windows HAL_INITIALIZATION_FAILED BSoD。
            vfio_opts="sysfsdev=/sys/bus/mdev/devices/${MDEV_UUID},display=off,enable-migration=off,bus=pcie.0,addr=0x10"
            if [[ "$SPOOF_MODE" == "A" ]]; then
                # 方案 A：vfio 把 PCI config space 的 vendor/device/sub-* 改成消费卡 ID。
                # ⚠️ 装 GRID 驱动阶段必须 --no-spoof (SPOOF_MODE=off)，
                #    否则 INF 匹配不到消费卡 ID 导致 -436207360。
                vfio_opts+=",x-pci-vendor-id=${GPU_PCI_VID},x-pci-device-id=${GPU_PCI_DID}"
                vfio_opts+=",x-pci-sub-vendor-id=${GPU_SUB_VID},x-pci-sub-device-id=${GPU_SUB_DID}"
            fi  # B / off: 不改 PCI config，driver 看真 RTX 6000
            GFX_ARGS+=( -device "vfio-pci,${vfio_opts}" )
            # -vga none: 不挂 std-vga，Windows Device Manager 里就不会有
            # "Microsoft 基本显示适配器"。纯 vGPU + Microsoft Remote Display
            # Adapter 两张（RDP 必需）。VNC 在 rdp 模式下没 framebuffer，
            # Windows 早期启动看不到，但 RDP 起来后接管。
            GFX_ARGS+=( -vga none -display "vnc=${VNC_DISPLAY}" )
            trap 'mdev_release "'"$MDEV_UUID"'"' EXIT INT TERM
        fi
        ;;
    gtk|sdl)
        # 例外: 2 张物理 GPU 时可以用 gtk/sdl 窗口
        MDEV_UUID=$(uuidgen)
        mdev_allocate "${GPU_PROFILE}" "$MDEV_UUID" >/dev/null || exit 1
        vfio_opts="sysfsdev=/sys/bus/mdev/devices/${MDEV_UUID},display=on,enable-migration=off,bus=pcie.0,addr=0x10"
        if [[ "$SPOOF_MODE" == "A" ]]; then
            vfio_opts+=",x-pci-vendor-id=${GPU_PCI_VID},x-pci-device-id=${GPU_PCI_DID}"
            vfio_opts+=",x-pci-sub-vendor-id=${GPU_SUB_VID},x-pci-sub-device-id=${GPU_SUB_DID}"
        fi
        GFX_ARGS+=( -device "vfio-pci,${vfio_opts}" )
        GFX_ARGS+=( -display "${MODE}" )
        trap 'mdev_release "'"$MDEV_UUID"'"' EXIT INT TERM
        ;;
esac

# ─── Pidfile / monitor ──────────────────────────────────────────────────────
RUN_DIR="$VM_ROOT/run"
PIDFILE="$RUN_DIR/vm${VM_ID}.pid"
MON_SOCK="$RUN_DIR/vm${VM_ID}.mon"
QMP_SOCK="$RUN_DIR/vm${VM_ID}.qmp"

# ─── ivshmem ──────────────────────────────────────────────────────────────
# host 后端文件挂在 tmpfs (/dev/shm)，size 必须是 2 的幂次。预创建/截断到
# 指定大小，guest 一启动 QEMU 就把它 mmap 暴露为 PCI BAR2。
# guest 装 ivshmem.sys 后可以从 BAR2 直接读写这块内存 — 双方都是同一段
# host 物理 RAM (kvm 把 host page mapping 直接映射进 guest)。
IVSHMEM_ARGS=()
if [[ "${IVSHMEM_SIZE_MB:-0}" -gt 0 ]]; then
    IVSHMEM_PATH="/dev/shm/nv-shmem-vm${VM_ID}"
    IVSHMEM_BYTES=$(( IVSHMEM_SIZE_MB * 1024 * 1024 ))
    # 每次启动都重新创建——避免旧 hdr 残留 (magic + width/height 上轮还在的话
    # viewer 会立刻通过 wait_ready 进入主循环，但 ring 状态全是脏的)。
    rm -f "$IVSHMEM_PATH"
    truncate -s "${IVSHMEM_BYTES}" "$IVSHMEM_PATH"
    chmod 660 "$IVSHMEM_PATH"
    # PCI identity stealth (patched into QEMU's hw/misc/ivshmem-pci.c):
    #   - main vendor/device kept at 0x1AF4:0x1110 so the Looking Glass
    #     ivshmem.sys driver still binds (its INF matches that pair)
    #   - subsystem IDs forged to NVIDIA (0x10DE) so PCI subsystem
    #     vendor in device manager doesn't read "Red Hat" — instead it
    #     looks like an OEM NVIDIA system device (0x10DE:0x1551 is one
    #     of NVIDIA's real SMU/system device subsys IDs from MCP/Tegra
    #     SoCs, plausible to a casual eye)
    #   - class 0x05/0x80 (Memory Controller / Other) instead of the
    #     default 0x05/0x00 (RAM Controller) — "Other Memory Controller"
    #     reads as boring SoC peripheral, not "shared RAM"
    #   - revision 0xa1 — non-zero, looks shipping
    IVSHMEM_ARGS=(
        -object "memory-backend-file,id=ivshm,mem-path=${IVSHMEM_PATH},size=${IVSHMEM_BYTES},share=on"
        -device "ivshmem-plain,memdev=ivshm,bus=pcie.0,addr=0x12,x-pci-sub-vendor-id=0x10DE,x-pci-sub-device-id=0x1551,x-pci-class-id=0x058000,x-pci-revision=0xa1"
    )
    echo "  ivshmem: ${IVSHMEM_PATH} (${IVSHMEM_SIZE_MB} MB) → guest PCI 00:12.0 (stealth subsys=0x10DE:0x1551)"
fi

echo "启动 VM ${VM_ID} 模式=${MODE}"
echo "  CPU: ${CPU_MODEL}@${TSC_FREQ}Hz"
echo "  主板: ${BOARD_BRAND} ${BOARD_MODEL} / ${VM_UUID}"
echo "  GPU profile: ${GPU_PROFILE}  spoof_mode: ${SPOOF_MODE}"
[[ -n "${MDEV_UUID:-}" ]] && echo "  mdev: ${MDEV_UUID}"
echo "  VNC display: ${VNC_DISPLAY}  (hostport=$((5900 + ${VNC_DISPLAY#:})))"

# QEMU command line built once, used by both code paths below.
QEMU_CMD=(
    "$QEMU_BIN"
    -name "vm${VM_ID}"
    -machine "$MACHINE_ARGS"
    -cpu "$CPU_ARGS"
    -smp 4,sockets=1,cores=4,threads=1
    -m "$GUEST_MEM_MB"
    -object "memory-backend-memfd,id=ram0,size=${GUEST_MEM_MB}M,share=on,prealloc=on"
    -numa node,memdev=ram0
    -rtc base=utc,clock=host,driftfix=slew
    -global kvm-pit.lost_tick_policy=discard
    -global ICH9-LPC.disable_s3=1
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
    -drive "if=pflash,format=raw,file=$VARS_PRIV"
    "${SMBIOS[@]}"
    -uuid "$VM_UUID"
    "${NET_ARGS[@]}"
    "${DRIVE_ARGS[@]}"
    "${GFX_ARGS[@]}"
    -device qemu-xhci,id=xhci,bus=pcie.0,addr=0x6 -device usb-tablet
    -device intel-hda,bus=pcie.0,addr=0x7 -device hda-duplex
    "${IVSHMEM_ARGS[@]}"
    -monitor "unix:${MON_SOCK},server,nowait"
    -qmp "unix:${QMP_SOCK},server,nowait"
    -pidfile "$PIDFILE"
    $EXTRA
)

# 非 rdp 模式都是"QEMU 直接挂前台显示"——install/gtk/sdl 都让 QEMU 自己
# 弹窗（-display sdl/gtk），no-gpu 走 VNC 远程。这些路径不需要一条龙
# (setup-task + ivshmem viewer)，因为：
#   - install: guest 还没装 Windows / 在 UEFI shell，没法跑 nv_stream_relay
#   - gtk/sdl: 用户人工交互，不通过 ivshmem
#   - no-gpu: 纯远程救援，QEMU 把画面推 VNC，用户自己 vncviewer 接
if [[ "$MODE" != "rdp" ]]; then
    [[ "$MODE" == "no-gpu" ]] && \
        echo "[start-vm] no-gpu: 用 vncviewer localhost:$((5900 + ${VNC_DISPLAY#:})) 连"
    # shellcheck disable=SC2086
    exec "${QEMU_CMD[@]}"
fi

# ───────── 默认 (rdp) 模式：一条龙 = QEMU 后台 + 自动 setup + SDL2 viewer 前台
#
# 流程：
#   1. QEMU fork 到后台，stderr → $VM_ROOT/log/vm${VM_ID}.log（用 tail -f 跟）
#   2. 后台 setup-task：等 WinRM 起 → 探 NvDisplayContainer 服务，没装就跑
#      setup-guest.sh，已装但 stopped 就 Start-Service
#   3. 前台拉 stream_client_dda viewer，等 ring magic（最长 5 分钟，覆盖
#      fresh-boot + 装驱动 + 重启）
#   4. trap: Ctrl+C / viewer 关窗 / 任何退出 → kill 子任务 + 调 stop-vm.sh
#   5. watchdog: QEMU 不在了 → kill viewer 让脚本退出
#
SHMEM_PATH="${IVSHMEM_PATH:-/dev/shm/nv-shmem-vm${VM_ID}}"
VIEWER_BIN="$here/stream-client/stream_client_dda"

should_tame_gnome_super() {
    local mode=${TAME_GNOME,,}
    case "$mode" in
        1|yes|true|on) return 0 ;;
        0|no|false|off) return 1 ;;
    esac
    gnome_super_shortcuts_is_gnome && gnome_super_shortcuts_available
}

_kill_tree() {
    # kill PID 自己 + 它所有 children/孙子。setup-task 是 ( ... ) & subshell，
    # 内部还在 sleep / nc / python 时单 kill subshell 不够，sleep 子孙会跑完
    # 4 分钟然后才 echo 退出 — 必须先 pkill -P 把孩子收掉。
    local pid=$1 child
    [[ -z "$pid" ]] && return
    for child in $(pgrep -P "$pid" 2>/dev/null); do
        _kill_tree "$child"
    done
    kill -TERM "$pid" 2>/dev/null
}

cleanup_all() {
    trap '' INT TERM EXIT          # 防止递归
    echo
    echo "[start-vm] cleaning up..."
    _kill_tree "${WATCH_PID:-}"
    _kill_tree "${SETUP_PID:-}"
    _kill_tree "${VIEWER_PID:-}"
    # 优雅关→不行就 --force（fresh boot 阶段 WinRM 没起来时会走到这条）
    "$here/stop-vm.sh" "$VM_ID" || "$here/stop-vm.sh" "$VM_ID" --force || true
    gnome_super_shortcuts_restore
    "$here/gnome-super-guard.sh" restore-stale 2>/dev/null || true
    exit 0
}
trap cleanup_all INT TERM EXIT

# 1) QEMU 后台启 + 重定向 stderr 到 log（tmux 会破坏数组里的引号 — 之前
# 试过 `tmux new-session "${QEMU_CMD[*]}"`，QEMU 一启动就 crash 因为
# `-machine "q35,accel=kvm,..."` 这种逗号串被 shell 重新分词搞乱）。
if pgrep -f "qemu-system-x86_64.*-name vm${VM_ID}\b" >/dev/null; then
    echo "[start-vm] vm${VM_ID} QEMU 已在跑 — 先 ./stop-vm.sh ${VM_ID}"
    trap '' INT TERM EXIT; exit 1
fi
QEMU_LOG="${VM_ROOT}/log/vm${VM_ID}.log"
: > "$QEMU_LOG"
"${QEMU_CMD[@]}" >>"$QEMU_LOG" 2>&1 &
QEMU_PID=$!
echo "[start-vm] QEMU pid=${QEMU_PID}  (stderr: tail -f ${QEMU_LOG})"

# Sanity: 给 QEMU 1 秒起 — 立刻死的话 dump log。
sleep 1
if ! kill -0 "$QEMU_PID" 2>/dev/null; then
    echo "[start-vm] !! QEMU 启动失败，最后 30 行日志："
    tail -30 "$QEMU_LOG" | sed 's/^/  /'
    trap '' INT TERM EXIT
    "$here/stop-vm.sh" "$VM_ID" --force >/dev/null 2>&1 || true
    exit 1
fi

# 2) 后台 setup-task：等 WinRM → 检查/装服务
(
    cd "$here"
    mac_lc=${VM_MAC,,}
    guest_ip=""
    winrm_ready=0
    echo "[setup-task] 等 guest WinRM (5985)..."
    for i in $(seq 1 120); do
        guest_ip=$(ip -4 neigh show 2>/dev/null | awk -v m="$mac_lc" \
            '$3=="br0" && tolower($5)==m && $1 ~ /^[0-9]/ {print $1; exit}')
        if [[ -n "$guest_ip" ]] && nc -z -w 2 "$guest_ip" 5985 2>/dev/null; then
            echo "[setup-task] WinRM port up → ${guest_ip}"
            # WinRM TCP listener 通 ≠ pypsrp NTLM 能用。Fresh boot 阶段
            # 端口通了但 Windows 后台 service 还在 init，pypsrp connect
            # 会 connection refused / 401。等 NTLM 稳定一次再继续。
            for j in $(seq 1 30); do
                if python3 - "$guest_ip" <<'PY' >/dev/null 2>&1; then
import sys
from pypsrp.client import Client
try:
    Client(sys.argv[1], username='Administrator', password='123456', ssl=False, auth='ntlm') \
        .execute_ps('Get-Date')
    sys.exit(0)
except Exception:
    sys.exit(1)
PY
                    echo "[setup-task] WinRM ready (NTLM round-trip OK)"
                    winrm_ready=1
                    break
                fi
                sleep 3
            done
            [[ "$winrm_ready" -eq 1 ]] && break
        fi
        sleep 2
    done
    if [[ -z "$guest_ip" || "$winrm_ready" -ne 1 ]]; then
        echo "[setup-task] guest WinRM/NTLM 未稳定 (4 分钟)，跳过 auto-setup"
        exit 0
    fi
    # 一次拿齐 5 个状态信号：
    #   svc:    NvDisplayContainer service status (Running/Stopped/空=没装)
    #   grid:   nvlddmkm.sys 在不在 (memory project_grid_driver_partial)
    #   ver:    NVIDIA driver 版本，期望 31.0.15.5324 (GRID 553.24)
    #           不是这个 = 被 Windows Update 替换或没装好
    #   err:    Win32_VideoController.ConfigManagerErrorCode (43=反虚拟化/无 license)
    #   lic:    nvidia-smi License Status (Licensed/Unlicensed/N/A)
    state=""
    for k in $(seq 1 8); do
        state=$(python3 - "$guest_ip" <<'PY' 2>/dev/null || true
import sys
from pypsrp.client import Client
c = Client(sys.argv[1], username='Administrator', password='123456', ssl=False, auth='ntlm')
ps = r"""
$svc  = (Get-Service NvDisplayContainer -EA 0).Status
$grid = Test-Path 'C:\Windows\System32\drivers\nvlddmkm.sys'
$vc = Get-CimInstance Win32_VideoController -EA 0 | Select-Object -First 1
$ver = if ($vc) { $vc.DriverVersion } else { '' }
$err = if ($vc) { [int]$vc.ConfigManagerErrorCode } else { -1 }
# 检测 GPU name 是否已 spoof（B/A 模式下 patch-grid-strings 跑过的标记）
$spoofed = if ($vc -and $vc.Name -match '(GeForce|GTX|GT \d)') { 1 } else { 0 }
$lic = 'N/A'
$smi = & 'C:\Windows\System32\nvidia-smi.exe' -q 2>$null
if ($smi) {
    $m = ($smi | Select-String 'License Status\s*:\s*(\S+)' -List).Matches
    if ($m.Count -gt 0) { $lic = $m[0].Groups[1].Value }
}
"$svc|$grid|$ver|$err|$lic|$spoofed"
"""
out, _, _ = c.execute_ps(ps)
print((out or '').strip())
PY
)
        if [[ "$state" == *"|"* ]]; then
            break
        fi
        echo "[setup-task] guest 状态暂未就绪，重试 ${k}/8..."
        sleep 3
    done
    IFS='|' read -r svc grid ver err lic spoofed <<<"$state"
    echo "[setup-task] svc=${svc:-?} sys=${grid:-?} ver=${ver:-?} err=${err:-?} license=${lic:-?} name_spoofed=${spoofed:-?}"
    if [[ "$state" != *"|"* || -z "${ver:-}" || -z "${err:-}" ]]; then
        echo "[setup-task] 状态未知，跳过 auto-setup，避免误判后重装 driver"
        exit 0
    fi

    # 期望 driver 版本：GRID 16.4 / 538.33 内部版本号
    # (host vGPU driver 是 535.161.05 = vGPU 16.x，必须配 16.x guest driver
    #  才不会 "driver version mismatch" Error 43)
    EXPECT_VER="31.0.15.3833"

    # ── 决策矩阵 ──
    # 1) sys=False  或  ver != EXPECT_VER  → driver 缺/坏，重装
    # 2) sys=True 且 ver=EXPECT_VER 但 err=43 且 lic != Licensed → 装 license
    # 3) sys=True 且 lic=Licensed 但 svc != Running → start service
    # 4) sys=True 且 lic=Licensed 且 svc=Running → 完美，跳过

    # 根据 SPOOF_MODE 决定 setup-guest 跑哪几步：
    #   A / B: 跑 stealth (name spoof) + monitor (EDID spoof)
    #   off:   都跳过
    SG_ARGS=("--ip" "$guest_ip")
    [[ "${SPOOF_MODE:-A}" == "off" ]] && SG_ARGS+=("--skip-stealth" "--skip-monitor")

    # 注意：DCH driver 不再拷 nvlddmkm.sys 到 system32\drivers，而是从
    # DriverStore 加载 — sys=False 不能作 driver 缺失的判据。用 err==-1
    # (Win32_VideoController 完全找不到 NVIDIA 适配器) + ver 错 来判断。
    if [[ "$ver" != "$EXPECT_VER" || "$err" == "-1" ]]; then
        echo "[setup-task] driver 状态错: ver='${ver}' err=${err} (期望 ver=${EXPECT_VER})"
        if [[ "${SPOOF_MODE:-A}" == "A" ]]; then
            echo "[setup-task] !! 当前 SPOOF_MODE=A (PCI 消费卡 ID)，install-vgpu-driver 会"
            echo "[setup-task]    返 -436207360（GRID INF 不匹配消费卡 PCI ID）。"
            echo "[setup-task]    解决：./stop-vm.sh ${VM_ID}"
            echo "[setup-task]          ./start-vm.sh ${VM_ID} --no-spoof   # 装 driver+license"
            echo "[setup-task]          guest 装好后切回 ./start-vm.sh ${VM_ID}（默认 A）"
        else
            echo "[setup-task] SPOOF_MODE=${SPOOF_MODE} (PCI 真身)，跑 setup-guest 装 driver"
            ./setup-guest.sh "$VM_ID" "${SG_ARGS[@]}" || echo "[setup-task] setup-guest 失败"
        fi
    elif [[ "$err" == "43" && "$lic" != "Licensed" ]]; then
        echo "[setup-task] driver 完整但未授权 (Error 43) → 跑 install-vgpu-license"
        ./install-vgpu-license.sh "$VM_ID" --ip "$guest_ip" || echo "[setup-task] license 失败"
    elif [[ "$svc" != "Running" && -n "$svc" ]]; then
        echo "[setup-task] NvDisplayContainer=${svc} → Start-Service"
        python3 - "$guest_ip" <<'PY' 2>/dev/null || true
import sys
from pypsrp.client import Client
Client(sys.argv[1], username='Administrator', password='123456', ssl=False, auth='ntlm') \
    .execute_ps("Start-Service NvDisplayContainer")
PY
    elif [[ -z "$svc" ]]; then
        echo "[setup-task] NvDisplayContainer 没装 → 跑 setup-guest（仅 service 步）"
        ./setup-guest.sh "$VM_ID" --ip "$guest_ip" --skip-vgpu --skip-ivshmem --skip-stealth --skip-monitor || true
    elif [[ "${SPOOF_MODE:-A}" != "off" && "$spoofed" != "1" ]]; then
        echo "[setup-task] driver+license+service 全 OK，但 GPU name 未 spoof → 跑 patch-grid-strings"
        ./setup-guest.sh "$VM_ID" --ip "$guest_ip" --skip-vgpu --skip-license --skip-ivshmem --skip-service || true
    else
        echo "[setup-task] driver+license+service 全 OK + name spoof 已就绪 (license=${lic})"
    fi
) &
SETUP_PID=$!

# 3) 等 ivshmem 准备好
for _ in $(seq 1 50); do
    [[ -e "$SHMEM_PATH" ]] && break
    sleep 0.1
done

# 4) 启 viewer (build if missing) — 先 sanity check DISPLAY，省得用户在
# SSH 没 -X 转发的环境下静默看不到窗口。
if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
    echo "[start-vm] !! 没 DISPLAY/WAYLAND_DISPLAY — SDL viewer 起不了窗口"
    echo "[start-vm]    在 SSH 跑请用 'ssh -X'，或直接在 host 物理终端"
    echo "[start-vm]    QEMU 已起，跳过 viewer；./stop-vm.sh ${VM_ID} 关"
    wait "$QEMU_PID" 2>/dev/null || true
    cleanup_all
fi

if [[ ! -x "$VIEWER_BIN" || "$here/stream-client/stream_client_dda.c" -nt "$VIEWER_BIN" ]]; then
    make -C "$here/stream-client" all >/dev/null
fi
if should_tame_gnome_super; then
    export GNOME_SUPER_GUARD="$here/gnome-super-guard.sh"
    "$GNOME_SUPER_GUARD" restore-stale 2>/dev/null || true
    VIEWER_ARGS+=(--tame-gnome)
    echo "[start-vm] GNOME/IBus 宿主快捷键保护已启用：鼠标在 viewer 窗口内时临时关闭 Super/Alt+Tab/锁屏，离开/最小化/退出立即恢复"
fi
echo "[start-vm] 启动 SDL viewer (窗口立刻弹，黑屏等 guest 第一帧)..."
"$VIEWER_BIN" --vm "$VM_ID" --shmem "$SHMEM_PATH" "${VIEWER_ARGS[@]}" &
VIEWER_PID=$!

# Viewer sanity: 如果 SDL_Init / CreateWindow 失败 (X 不通 / GL 缺) viewer
# 会立刻退；给 1 秒看活不活，挂了就 dump SDL 错误并退出。
sleep 1
if ! kill -0 "$VIEWER_PID" 2>/dev/null; then
    echo "[start-vm] !! viewer 退出（SDL 起窗口失败，看上面的 stderr）"
    cleanup_all
fi

# 5) watchdog：QEMU 死了 → kill viewer 让脚本退出
(
    while pgrep -f "qemu-system-x86_64.*-name vm${VM_ID}" >/dev/null; do sleep 3; done
    kill "$VIEWER_PID" 2>/dev/null
) &
WATCH_PID=$!

wait "$VIEWER_PID" || true
