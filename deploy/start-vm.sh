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

# shellcheck source=lib/vgpu-mdev.sh
source "$here/lib/vgpu-mdev.sh"

VM_ID="${1:-}"
[[ -z "$VM_ID" || ! "$VM_ID" =~ ^[1-9][0-9]*$ ]] && {
    echo "usage: $0 <vm_id> [--install iso|--rdp|--gtk|--sdl|--no-gpu|--vnc :N|--extra \"...\"]" >&2
    exit 2
}
shift

MODE=rdp             # 默认 RDP
SPOOF=1              # 是否把 PCI vendor/device/sub-* 改成消费卡 ID
ISO=""
EXTRA=""
VNC_DISPLAY=":${VM_ID}"
DEFAULT_ISO="/home/ubuntu/images/win10-ltsc.iso"

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
        --no-spoof) SPOOF=0; shift ;;    # 装 GRID 驱动时用，暴露真 Quadro PCI ID
        --spoof)    SPOOF=1; shift ;;    # 显式打开（默认即开）
        --no-shmem) IVSHMEM_SIZE_MB=0; shift ;;     # 禁用 ivshmem 通道
        --shmem)    IVSHMEM_SIZE_MB="$2"; shift 2 ;; # 指定大小 (MB)
        --extra)   EXTRA="$2"; shift 2 ;;
        *) echo "未知参数: $1" >&2; exit 2 ;;
    esac
done

CONF="vm-configs/vm${VM_ID}.conf"
[[ -f "$CONF" ]] || { echo "未找到 $CONF，先运行 ./create-vm.sh $VM_ID" >&2; exit 1; }
# shellcheck source=/dev/null
source "$CONF"

: "${QEMU_BIN:=$here/../build/qemu-system-x86_64}"
: "${OVMF_CODE:=/usr/share/OVMF/OVMF_CODE_4M.fd}"
: "${OVMF_VARS:=/usr/share/OVMF/OVMF_VARS_4M.fd}"
: "${VM_DISK_DIR:=/home/ubuntu/images/vms}"
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
DRIVE_ARGS+=( -device "nvme,drive=ssd0,serial=${SSD_SN},model=${SSD_BRAND} ${SSD_MODEL},id=nvme0" )

# ─── 光驱 stealth：任何模式都挂一个 "看起来真实" 的 ATAPI ODD  ────────────
# Q35 板载 ICH9-AHCI (VEN_8086&DEV_2922) 自动给 ide.0 挂一个空的 CDROM，
# 不显式配置时 Windows 里会看到 "QEMU QEMU DVD-ROM"。我们显式挂同一 bus
# ide.0 并给一个常见品牌 model，覆盖 QEMU default。
#   - 生产 (rdp/gtk/sdl/no-gpu): 挂空光驱 (media=cdrom, 无 file=)
#   - install: 同一光驱挂 ISO 作为 boot 源
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
    no-gpu|install)
        # std-vga 只在装系统或调试时使用，不挂 vfio-pci 避免 OVMF PCI 枚举卡死
        GFX_ARGS+=( -vga std )
        GFX_ARGS+=( -display "vnc=${VNC_DISPLAY}" )
        ;;
    rdp)
        # 生产路径: vGPU + 侧挂 std-vga 供前期登录；进系统后由 xfreerdp 接管
        MDEV_UUID=$(uuidgen)
        mdev_allocate "${GPU_PROFILE}" "$MDEV_UUID" >/dev/null || {
            echo "mdev 分配失败，降级到 --no-gpu 模式" >&2
            GFX_ARGS+=( -vga std )
            GFX_ARGS+=( -display "vnc=${VNC_DISPLAY}" )
            MDEV_UUID=""
        }
        if [[ -n "$MDEV_UUID" ]]; then
            # enable-migration=off: NVIDIA vGPU 驱动不支持 vfio migration
            # uapi。QEMU 11 默认开 migration 会让 guest 内 HAL 读 PCI 寄存器
            # 时拿到坏数据 → Windows HAL_INITIALIZATION_FAILED BSoD。
            vfio_opts="sysfsdev=/sys/bus/mdev/devices/${MDEV_UUID},display=off,enable-migration=off,bus=pcie.0,addr=0x10"
            if (( SPOOF )); then
                # 把 PCI config space 的 vendor/device/sub-* 伪装成消费卡。
                # ⚠️  装 GRID 驱动阶段必须 --no-spoof，否则 INF 匹配不到消费卡 ID。
                vfio_opts+=",x-pci-vendor-id=${GPU_PCI_VID},x-pci-device-id=${GPU_PCI_DID}"
                vfio_opts+=",x-pci-sub-vendor-id=${GPU_SUB_VID},x-pci-sub-device-id=${GPU_SUB_DID}"
            fi
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
        if (( SPOOF )); then
            vfio_opts+=",x-pci-vendor-id=${GPU_PCI_VID},x-pci-device-id=${GPU_PCI_DID}"
            vfio_opts+=",x-pci-sub-vendor-id=${GPU_SUB_VID},x-pci-sub-device-id=${GPU_SUB_DID}"
        fi
        GFX_ARGS+=( -device "vfio-pci,${vfio_opts}" )
        GFX_ARGS+=( -display "${MODE}" )
        trap 'mdev_release "'"$MDEV_UUID"'"' EXIT INT TERM
        ;;
esac

# ─── Pidfile / monitor ──────────────────────────────────────────────────────
RUN_DIR="$here/run"
mkdir -p "$RUN_DIR"
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
    if [[ ! -f "$IVSHMEM_PATH" ]] || [[ "$(stat -c%s "$IVSHMEM_PATH" 2>/dev/null || echo 0)" -ne "$IVSHMEM_BYTES" ]]; then
        truncate -s "${IVSHMEM_BYTES}" "$IVSHMEM_PATH"
        chmod 660 "$IVSHMEM_PATH"
    fi
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
echo "  GPU profile: ${GPU_PROFILE}"
[[ -n "${MDEV_UUID:-}" ]] && echo "  mdev: ${MDEV_UUID}"
echo "  VNC display: ${VNC_DISPLAY}  (hostport=$((5900 + ${VNC_DISPLAY#:})))"

# shellcheck disable=SC2086
exec "$QEMU_BIN" \
    -name "vm${VM_ID}" \
    -machine "$MACHINE_ARGS" \
    -cpu "$CPU_ARGS" \
    -smp 4,sockets=1,cores=4,threads=1 \
    -m "$GUEST_MEM_MB" \
    -object memory-backend-memfd,id=ram0,size=${GUEST_MEM_MB}M,share=on,prealloc=on \
    -numa node,memdev=ram0 \
    -rtc base=utc,clock=host,driftfix=slew \
    -global kvm-pit.lost_tick_policy=discard \
    -global ICH9-LPC.disable_s3=1 \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$VARS_PRIV" \
    "${SMBIOS[@]}" \
    -uuid "$VM_UUID" \
    "${NET_ARGS[@]}" \
    "${DRIVE_ARGS[@]}" \
    "${GFX_ARGS[@]}" \
    -device qemu-xhci,id=xhci,bus=pcie.0,addr=0x6 -device usb-tablet \
    -device intel-hda,bus=pcie.0,addr=0x7 -device hda-duplex \
    "${IVSHMEM_ARGS[@]}" \
    -monitor "unix:${MON_SOCK},server,nowait" \
    -qmp "unix:${QMP_SOCK},server,nowait" \
    -pidfile "$PIDFILE" \
    $EXTRA
