#!/bin/bash
# ---------------------------------------------------------------------------
# start-vm.sh ——— 一键启动隐身 QEMU/KVM Windows 客机
#
# 客机伪装成裸金属：随机 AM4 主板（ASRock/MSI/ASUS 池）+ AMD Ryzen 3 + 8GB
# DDR4 双通道 + Samsung 970 PRO 512GB NVMe + virtio-gpu 改名 GTX 1050。
#
# 用法（最简）：
#     ./start-vm.sh 1                       # 启动 instance 1，桥接 br0
#                                           # 默认 SDL 窗口 + fb-shm 推流并存
#                                           # 推流 socket: /tmp/qemu-stealth-1.fb
#     ./start-vm.sh 2 --iso=/path/x.iso     # instance 2 从 ISO 装系统
#     ./start-vm.sh 1 --no-sdl              # 后台 daemon：关 SDL，仅推流
#     ./start-vm.sh 1 --headless            # VNC 远程 + fb-shm（无本地窗口）
#     ./start-vm.sh 1 --no-fb-shm           # 关推流，仅 SDL（回历史行为）
#     ./start-vm.sh 1 --no-bridge           # 用 user-mode NAT 而不是 br0
#     ./start-vm.sh 1 --reroll              # 重新随机硬件身份
#     ./start-vm.sh 1 --fb-shm-roi=0,0,1920,1080 --fb-shm-rate=60
#     ./start-vm.sh 1 --proxy               # 同时起 qmp-proxy 让多客户端共存
#                                           # listen: /tmp/qemu-stealth-1.qmp.proxy
#     ./start-vm.sh 1 --hotkey-capture      # SDL 窗口里按 F4 -> fb-shm 抓 PNG
#                                           # 存 $VM_DIR/captures；--hotkey-capture=F2 改键
#
# 边玩边拉流到 ffmpeg / NVENC：
#     ./start-vm.sh 1                       # SDL 窗口照常出现，可直接玩
#     scripts/qemu-fb-shm-stream.py --sock /tmp/qemu-stealth-1.fb \\
#         --output 'rtmp://ingest/live/vm1' --encoder h264_nvenc --bitrate 6M
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
# 显示后端 — 两条独立通道，默认全开：
#     SDL 窗口（默认开）   本地交互窗口；DNF 等需要直接玩游戏的场景用。
#                          --no-sdl 关；--headless 自动关并启 VNC 替代。
#     fb-shm 推流（默认开）零拷贝共享内存推流，guest 完全不可见。
#                          外部进程连 unix socket 拿 memfd+eventfd，配合
#                          scripts/qemu-fb-shm-stream.py → ffmpeg/NVENC
#                          推 RTMP / UDP / SRT / 本地 mp4。--no-fb-shm 关。
#     --headless           关 SDL，开 VNC（fb-shm 仍照常）。
#
# 环境变量（不常用，默认就好）：
#     RAM=8192             客机内存 MiB（默认 8192）
#     CPUS=4               vCPU 数量（默认 4，cores=4 threads=1 sockets=1）
#     SDL=1                SDL 窗口开关（默认 1） (flag: --sdl / --no-sdl)
#     HEADLESS=1           关 SDL 启 VNC                          (flag: --headless)
#     BRIDGE=br0           桥接网卡名字                          (flag: --bridge=br0)
#     ISO=<path>           安装 ISO 路径                         (flag: --iso=<path>)
#     DISK=<path>          qcow2 磁盘路径                        (flag: --disk=<path>)
#     QEMU=<path>          qemu-system-x86_64 二进制路径         (flag: --qemu=<path>)
#     EXTRA_ISO=<path>     副 CDROM（autounattend.xml / 驱动盘 等）
#     STABLE_DISPLAY=0     SDL 模式下允许 virtio-vga-gl + virgl 3D（fb-shm 模式
#                          用不到此项；fb-shm 始终走 stable virtio-vga）
#     GPU_SELFSIGNED=1     PCI 主 ID 改成 NVIDIA 10DE:1C81。 ⚠️ 需要 patched
#                          viogpudo + 伪 NVIDIA CA 链；ACE/腾讯反作弊判异常
#                          (13-131106-0)。只用于轻反作弊场景。
#     CPU_MODEL=Ryzen3-2300X  覆盖 profile 写入的 CPU 型号（一般不用）
#     FB_SHM_SOCK=<path>   fb-shm 控制 socket 路径
#                          默认 /tmp/qemu-stealth-<N>.fb
#                          (flag: --fb-shm-sock=<path>)
#     FB_SHM_RATE=60       fb-shm 目标帧率 Hz，clamp [1,240]
#                          (flag: --fb-shm-rate=<hz>)
#     FB_SHM_ROI=x,y,w,h   只截 ROI 推流（省 CPU/带宽）。空 = 全屏
#                          (flag: --fb-shm-roi=x,y,w,h)
#     PROXY=1              同时起 qmp-proxy.py 让多个客户端共存（默认 0）
#                          (flag: --proxy / --no-proxy)
#                          代理 listen: ${QMP_SOCK}.proxy；客户端连这里
#                          就不会跟其他工具抢 QEMU 的单 QMP slot
#     HOTKEY_CAPTURE=1     SDL 窗口里按 HOTKEY_KEY 时从 fb-shm 抓 PNG（默认 0）
#                          (flag: --hotkey-capture[=KEY] / --no-hotkey-capture)
#     HOTKEY_KEY=F4        触发键名（X keysym），默认 F4
#                          PNG 存 $VM_DIR/captures；日志 ${HOTKEY_LOG}
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
        --sdl)        SDL=1 ;;
        --no-sdl)        SDL=0 ;;
        --no-fb-shm)     FB_SHM=0 ;;
        --fb-shm)        FB_SHM=1 ;;  # explicit on (already default)
        --fb-shm-sock=*) FB_SHM=1; FB_SHM_SOCK="${1#*=}" ;;
        --fb-shm-rate=*) FB_SHM=1; FB_SHM_RATE="${1#*=}" ;;
        --fb-shm-roi=*)  FB_SHM=1; FB_SHM_ROI="${1#*=}" ;;
        --proxy)         PROXY=1 ;;
        --no-proxy)      PROXY=0 ;;
        --hotkey-capture)     HOTKEY_CAPTURE=1 ;;
        --hotkey-capture=*)   HOTKEY_CAPTURE=1; HOTKEY_KEY="${1#*=}" ;;
        --no-hotkey-capture)  HOTKEY_CAPTURE=0 ;;
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

# RAM 默认值故意不在这里钉死：profile.MEM_TOTAL_MB 可能提供持久化值，
# 所以推迟到 profile 加载之后再解析（见下方 "RAM 解析" 块）。
# 显式 --ram= / 环境 RAM= 在 CLI 解析阶段已赋值，会被那里当最高优先级保留。
: "${CPUS:=4}"
: "${HEADLESS:=0}"
: "${SDL:=1}"      # 默认：SDL 窗口仍然弹出（与历史行为一致）
: "${FB_SHM:=1}"   # 默认：再额外挂一条 -object fb-shm 推流通道
: "${FB_SHM_RATE:=60}"
: "${FB_SHM_ROI:=}"
: "${FB_SHM_SOCK:=/tmp/qemu-stealth-${INSTANCE}.fb}"
# QMP fanout proxy: QEMU 的 -qmp 单 slot, 谁先连占着. PROXY=1 就在 QEMU 旁边
# 起一个 qmp-proxy.py 后台进程, listen 在 ${QMP_SOCK}.proxy, 让 dgame /
# image-search / 临时 socat 都连代理 socket → 互不竞争. proxy 在 QEMU 退出
# (upstream EOF) 时自动 exit, 不需要手动清理.
: "${PROXY:=0}"
# 热键截图: HOTKEY_CAPTURE=1 时, 后台起 hotkey-capture.py, 同时给 QEMU 导出
# QEMU_HOTKEY_TRIGGER. 用户在 SDL 窗口里按 HOTKEY_KEY(默认 F4), 守护进程从
# fb-shm 零拷贝帧抓一张 PNG 存到 $VM_DIR/captures. guest 完全无感知.
: "${HOTKEY_CAPTURE:=0}"
: "${HOTKEY_KEY:=F4}"
: "${HOTKEY_SOCK:=/tmp/qemu-stealth-${INSTANCE}.hotkey}"
: "${HOTKEY_LOG:=/tmp/qemu-stealth-${INSTANCE}.hotkey.log}"
: "${HOTKEY_OUT:=${VM_DIR:-/home/ubuntu/images/vms/${INSTANCE}}/captures}"
: "${ISO:=${_cli_iso:-/home/ubuntu/images/win10.iso}}"
[[ -n "$_cli_iso" ]] && ISO="$_cli_iso"

# 显示模式：SDL 窗口 + fb-shm 推流默认全开（互不影响）。
#   (无 flag)            -> SDL 窗口 + fb-shm        ← 默认
#   --headless           -> VNC 远程  + fb-shm（去窗口、加远程）
#   --no-sdl             -> 关窗口，仅 fb-shm（适合后台 daemon / nohup）
#   --no-fb-shm          -> 关推流，仅 SDL/VNC（回历史行为）
#   --sdl --headless     -> 冲突，按 --headless 走
if [[ "$HEADLESS" == "1" ]]; then
    SDL=0   # headless 强制无窗口（VNC 替代）
fi
if [[ "$FB_SHM" != "1" && "$SDL" != "1" && "$HEADLESS" != "1" ]]; then
    echo ">> WARN: --no-fb-shm + --no-sdl + 无 --headless，guest 无任何显示输出"
fi
# 后台 daemon 情况自动降级：DISPLAY 没设 + 不在 tty + 没显式 --headless => 关 SDL
if [[ "$SDL" == "1" && -z "${DISPLAY:-}" && ! -t 1 && "$HEADLESS" != "1" ]]; then
    echo ">> 自动降级: 无 DISPLAY 且非交互式终端 -> 关 SDL，仅 fb-shm 推流"
    SDL=0
fi

# fb-shm 校验：rate 必须在 [1,240]
if [[ "$FB_SHM" == "1" ]]; then
    if ! [[ "$FB_SHM_RATE" =~ ^[0-9]+$ ]] || (( FB_SHM_RATE < 1 || FB_SHM_RATE > 240 )); then
        echo "ERROR: FB_SHM_RATE 必须是 [1,240] 的整数 (实际: '$FB_SHM_RATE')" >&2
        exit 2
    fi
    if [[ -n "$FB_SHM_ROI" ]] && ! [[ "$FB_SHM_ROI" =~ ^[0-9]+,[0-9]+,[0-9]+,[0-9]+$ ]]; then
        echo "ERROR: FB_SHM_ROI 必须是 x,y,w,h 整数四元组 (实际: '$FB_SHM_ROI')" >&2
        exit 2
    fi
fi

# DISPLAY 默认 :0（典型本地 X11 会话）；从 SSH 终端运行时若未 export DISPLAY，
# 这里自动补上让 SDL 能找到 X server。只有 --sdl 才会真创窗口；
# 纯 fb-shm（默认）和 --headless 都不需要 DISPLAY。
if [[ "${SDL:-0}" == "1" && "${HEADLESS:-0}" != "1" ]]; then
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
#
# **重要顺序**：profile 必须在磁盘创建**之前**加载，因为 qcow2 大小
# 要按 profile.NVME_SIZE_BYTES 来——profile 抽到 "Samsung 980 1TB"
# 就建 1TB qcow2、抽到 "970 PRO 512GB" 就建 512GB，Win32_DiskDrive
# Model 和 Size 才会自洽。历史上这俩 block 顺序反了，profile 1TB +
# 实盘 512GB 的反作弊指纹隐患由此而来。
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

# -------------------------------------------------------------------
# RAM 解析（必须在 profile 加载之后）。优先级：
#   1. 显式 --ram=N / 环境 RAM=N    ← 命令行最高优先级（本次启动临时覆盖）
#   2. profile.MEM_TOTAL_MB         ← 持久化值，跨重启稳定（推荐，扩容走这里）
#   3. 4096                         ← 都没有时的历史兜底（老 profile 缺字段）
# 把内存总量当硬件身份的一部分钉在 profile 里，避免"忘带 --ram → 4GB↔8GB 漂移"
# 被反作弊当成硬件指纹变化。要把某台 VM 扩到 8GB：在它的 profile 写 MEM_TOTAL_MB=8192
# （8192=2×4GB 双通道，两条 DIMM SN 各自唯一）。
# -------------------------------------------------------------------
if [[ -z "${RAM:-}" && -n "${MEM_TOTAL_MB:-}" ]]; then
    RAM="$MEM_TOTAL_MB"
fi
: "${RAM:=4096}"

# stealth_print_profile 移到 "--- launching ---" 前，那时 VGA_DEV /
# USB_RELATIVE_MOUSE / NUM_DIMMS / PER_DIMM_MB 都已就绪，print 能反映
# 真实运行参数（不是默认 fallback）。

# -------------------------------------------------------------------
# Per-instance disk creation —— qcow2 大小**对齐 profile.NVME_SIZE_BYTES**。
# 之前硬编码 512000000000（512 GB），但 profile 抽到 "Samsung 980 1TB" 时
# Windows WMI 看 Model=1TB / Size=476 GiB 跨向量矛盾。现在按 profile 字段建。
#
# qcow2 是 thin/sparse 的——1TB 镜像首次只占 ~200KB host 空间，guest 写多少
# 实际才占多少；不必担心 1TB 镜像吃光物理盘。
#
# BASE_IMAGE 克隆模式：从 base 镜像派生增量层，size 跟 base 一致，与
# NVME_SIZE_BYTES 无关（克隆场景下用户自负 size 一致性）。
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
        # 此时 profile 已加载，NVME_SIZE_BYTES 一定有值（pick_profile 写、
        # 或 load_profile 按 NVME_MODEL 兜底推导）。再加 : 兜底防御退化路径。
        : "${NVME_SIZE_BYTES:=512000000000}"
        size_gib=$(( NVME_SIZE_BYTES / 1024 / 1024 / 1024 ))
        echo ">> creating fresh qcow2 at $DISK"
        echo ">>   model     : ${NVME_MODEL:-unknown}"
        echo ">>   raw bytes : $NVME_SIZE_BYTES  (~${size_gib} GiB Windows-side)"
        "$REPO_ROOT/build/qemu-img" create -f qcow2 -o preallocation=off,cluster_size=65536 \
            "$DISK" "$NVME_SIZE_BYTES"
    fi
fi

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
# OVMF_CODE 可被 env 覆盖：
#   OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd ./start-vm.sh 3 --iso=...
#
# **ISO 装系统模式强制走 stock OVMF**：deploy/firmware/OVMF_CODE_4M_stealth.fd
# (EDK2 master build with TPM2_ENABLE + NVIDIA-1c81 GOP whitelist) 的 ISO9660
# driver 在 Windows ISO（UDF/ISO9660 hybrid，主表只含 README.TXT）上的行为
# 退化：`if exist FS0:\sources\install.wim` 始终 false，导致 chainload 失败。
# stock Ubuntu OVMF 2.70 同样 build with TPM2_ENABLE，且没那个 ISO9660 退化，
# 装系统过得去。装好系统后 (BOOT=disk) 再用 stealth fd 也无所谓——OVMF NVRAM
# 里的 Boot#### 已指向 Windows Boot Manager，BdsDxe 不再 walk ISO9660。
if [[ -z "${OVMF_CODE:-}" ]]; then
    if [[ "$BOOT" == "iso" ]]; then
        OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd
    elif [[ -f "$STEALTH_OVMF" ]]; then
        OVMF_CODE="$(readlink -f "$STEALTH_OVMF")"
    else
        OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd
    fi
fi

# -------------------------------------------------------------------
# 伪 BGRT (Boot Graphics Resource Table)
#
# 裸金属 PC 出厂都有 BGRT（厂商启动 logo 位图描述符），反作弊扫 ACPI 表树
# 发现没有 BGRT 是弱信号"这台机器不是真 OEM"。OVMF 不提供 BGRT，所以我们
# 用 -acpitable 注入一个 status=migrated 的 20 字节末态 BGRT，OEMID 对齐
# 主板 BIOS 的 "ALASKA / A M I  "（与 aml-build.h 一致）。
#
# 注意：BGRT body 仅 20 字节，不含 logo bitmap——OS 接管后地址清零是真实
# 末态，反作弊只看 BGRT **存在**且 OEMID 一致，不会去 deref Image Address。
# 文件不存在时 ACPI_ARGS 为空数组，cmdline 拼出来等于零参数，不影响其它路径。
# -------------------------------------------------------------------
BGRT_BIN="$(dirname "$0")/../firmware/bgrt.bin"
SSDT_THERMAL_AML="$(dirname "$0")/../firmware/ssdt-thermal.aml"
ACPI_ARGS=()
if [[ -f "$BGRT_BIN" ]]; then
    ACPI_ARGS+=(
        -acpitable "sig=BGRT,rev=1,oem_id=ALASKA,oem_table_id=A M I   ,data=$BGRT_BIN"
    )
fi
# 伪 SSDT：注入一个 \_SB.TZQE 热区 + \_SB.FANE 风扇，让裸金属画像完整。
# 文件不存在时跳过；不致命（仅意味着 guest 内 Win32_TemperatureProbe 空）。
# 用 `-acpitable file=` 形式——iasl 编译出来的 AML 已含完整 SSDT 表头 +
# checksum，QEMU 直接挂上去即可，不需要重算 header。
if [[ -f "$SSDT_THERMAL_AML" ]]; then
    ACPI_ARGS+=(
        -acpitable "file=$SSDT_THERMAL_AML"
    )
fi
OVMF_VARS_SRC=/usr/share/OVMF/OVMF_VARS_4M.fd
OVMF_VARS="$VM_DIR/ovmf-vars.fd"
if [[ ! -f "$OVMF_VARS" ]]; then
    cp "$OVMF_VARS_SRC" "$OVMF_VARS"
fi

# -------------------------------------------------------------------
# TPM 2.0 emulator (swtpm)
#
# 为什么必须装：Win10 21H2+ / Win11 全面铺 TPM 2.0；裸金属 UEFI 都会探到。
# Get-Tpm 返回 "Compatible TPM not found" 或 tpm.msc 空白，配合其它指纹
# 反作弊立刻判 sandbox / VM。
#
# 实现：host 端 swtpm 后台 daemon，per-instance 状态目录在 $VM_DIR/tpm-state，
# 控制 socket 在 $VM_DIR/tpm-sock，QEMU 通过 -tpmdev emulator + -device tpm-crb
# 把 TPM 设备暴露给 guest。SecureBoot + TPM 2.0 → 现代裸金属画像完整。
#
# 缺 swtpm 时优雅降级（不致命）：跳过 TPM 设备，但打 WARN——这时反作弊会判
# "无 TPM"，建议 apt install swtpm swtpm-tools 后再启动。
# -------------------------------------------------------------------
# TPM 默认启用（2026-05 stealth OVMF 已加 -D TPM2_ENABLE=TRUE 重 build，
# Tcg2Dxe / Tcg2Pei / Tcg2ConfigDxe / Tcg2PlatformDxe 模块全在）。
# guest 看到 tpm-crb 设备，Win 加载 TPM 驱动 + tpm.msc / Get-Tpm 全部正常。
# 设 TPM=0 显式关掉（如果 OVMF 切回不支持 TPM 的旧 fd，或者想模拟"用户没在
# BIOS 启用 fTPM"的状态——B350 / H310 / H410 入门主板出厂默认就是关的）。
TPM_ARGS=()
if [[ "${TPM:-1}" == "0" ]]; then
    : # 显式禁用
elif command -v swtpm >/dev/null 2>&1; then
    TPM_STATE_DIR="$VM_DIR/tpm-state"
    TPM_SOCK="$VM_DIR/tpm-sock"
    TPM_LOG="$VM_DIR/tpm.log"
    mkdir -p "$TPM_STATE_DIR"

    # 首次启动 / state 不完整时初始化 TPM 2.0 state（manufacturer info、EK 证书）。
    # 完整初始化产出 ~6KB permall（含 RSA EK + ECC EK + Platform cert + sha256 PCR banks）；
    # 1.5KB 左右的"空 init"代表 swtpm_localca 创证书阶段失败（多半是
    # /var/lib/swtpm-localca/ 只 root 能写）—— Windows 加载 TPM 驱动时找不到 EK
    # 就报 "tpm.msc: 找不到兼容的 TPM"，必须重 init。
    _need_tpm_init=0
    if [[ ! -f "$TPM_STATE_DIR/tpm2-00.permall" ]]; then
        _need_tpm_init=1
    elif (( $(stat -c%s "$TPM_STATE_DIR/tpm2-00.permall") < 3000 )); then
        echo ">> swtpm:       permall < 3KB（空 init），强制重新创建 EK / Platform cert"
        _need_tpm_init=1
        # 备份再清，万一是 stealth 重要数据
        mv "$TPM_STATE_DIR/tpm2-00.permall" "$TPM_STATE_DIR/tpm2-00.permall.empty.bak.$(date +%s)" 2>/dev/null || true
    fi

    if (( _need_tpm_init )); then
        # 防御性：swtpm_localca statedir 默认 0750 swtpm:root；ubuntu 没权限会
        # 静默跳过证书创建。提前修一次（如果是 root 跑的就跳过，sudo 才有意义）。
        if [[ -d /var/lib/swtpm-localca && ! -w /var/lib/swtpm-localca ]]; then
            echo ">> swtpm:       /var/lib/swtpm-localca 不可写，尝试 sudo chown ubuntu"
            if command -v sudo >/dev/null && sudo -n true 2>/dev/null; then
                sudo chown -R "$(id -u):$(id -g)" /var/lib/swtpm-localca 2>/dev/null || true
            else
                echo ">> WARN: 没有免密 sudo，跑 'sudo chown -R \$(id -u):\$(id -g) /var/lib/swtpm-localca' 一次后重启"
            fi
        fi

        echo ">> swtpm:       初始化 TPM 2.0 state at $TPM_STATE_DIR"
        if ! swtpm_setup --tpm2 --tpmstate "$TPM_STATE_DIR" \
                --create-ek-cert --create-platform-cert --lock-nvram \
                --overwrite 2>&1 | tail -5; then
            echo ">> WARN: swtpm_setup 失败；guest tpm.msc 会报找不到 TPM"
        fi
        # 二次确认大小：成功 init 应该 > 3KB
        if [[ -f "$TPM_STATE_DIR/tpm2-00.permall" ]]; then
            _sz=$(stat -c%s "$TPM_STATE_DIR/tpm2-00.permall")
            echo ">> swtpm:       permall=${_sz} bytes (含 EK + Platform cert 应 > 3000)"
        fi
    fi

    # 启动 swtpm daemon；clear-socket 避免 stale unix socket 残留
    rm -f "$TPM_SOCK"
    swtpm socket \
        --tpmstate dir="$TPM_STATE_DIR" \
        --ctrl type=unixio,path="$TPM_SOCK" \
        --tpm2 \
        --log file="$TPM_LOG",level=20 \
        --daemon
    # 等 socket 出现（最多 2 秒）
    for _i in 1 2 3 4 5 6 7 8 9 10; do
        [[ -S "$TPM_SOCK" ]] && break
        sleep 0.2
    done
    if [[ ! -S "$TPM_SOCK" ]]; then
        echo ">> WARN: swtpm 启动超时（2s），跳过 TPM——guest 将看不到 TPM 设备" >&2
    else
        TPM_ARGS=(
            -chardev "socket,id=chrtpm,path=$TPM_SOCK"
            -tpmdev emulator,id=tpm0,chardev=chrtpm
            -device tpm-crb,tpmdev=tpm0
        )
        echo ">> swtpm:       TPM 2.0 ready (sock=$TPM_SOCK, log=$TPM_LOG)"
    fi
else
    echo ">> WARN: swtpm 未安装，guest 将无 TPM 2.0；反作弊会判 sandbox。建议：" >&2
    echo ">>       sudo apt install swtpm swtpm-tools && 重启此脚本" >&2
fi

# -------------------------------------------------------------------
# DIMM 拓扑决策（裸金属"双卡槽主板"画像）：
#
# - RAM ≤ 4096 MiB：1 条 DIMM 占满，**1 个卡槽空**（最常见的低端配置）；
# - RAM > 4096 MiB：2 条 DIMM 各占总量一半，双通道。
#
# SMBIOS Type 16 num-devices **固定 2**（主板物理卡槽数不变，跟 BOARD_POOL
# 的 B350/H310 入门主板真实拓扑一致）。Type 17 由 QEMU 按 `-object
# memory-backend-*` 数量自动克隆——1 backend = 1 Type 17 记录 = 1 个
# Win32_PhysicalMemory；空槽不会单独 emit。
#
# MEM_PER_DIMM_MB 影响 stealth_smbios_args 选 2GB/4GB part 号：
#   < 4096 → MEM_PART_2G   ≥ 4096 → MEM_PART_4G
# -------------------------------------------------------------------
if (( RAM <= 4096 )); then
    NUM_DIMMS=1
    PER_DIMM_MB=$RAM
else
    NUM_DIMMS=2
    PER_DIMM_MB=$(( RAM / 2 ))
fi
export MEM_PER_DIMM_MB="$PER_DIMM_MB"
export T16_NUM_DEVICES=2   # 物理双卡槽不变，即便只插 1 条

# Override default PCI subsystem IDs for devices that don't set their own.
# **2026-05 修复**：之前 hardcoded ASUS B350-PLUS (1043:8694) 无视 BOARD_MFR；
# profile 抽到 Gigabyte/MSI/ASRock 时 SMBIOS 报 X 牌但 PCI 桥子系统全报 ASUS，
# 跨表对照即矛盾。现在 stealth_pick_profile 已经把对应板厂的 SUBSYS 写进 profile。
# - ASUS     0x1043 / 0x8694 (B350-PLUS) / 0x86C7 (ROG/X370)
# - MSI      0x1462 / board model 后缀 (7A34/7B49/7C95...)
# - Gigabyte 0x1458 / 0x5001
# - ASRock   0x1849 / 0x1230 / 0x9696
# 老 profile 缺该字段时 stealth_load_profile 会兜底回 ASUS B350-PLUS 默认值。
export QEMU_PCI_SUBSYS_VEN="${QEMU_PCI_SUBSYS_VEN:-$BOARD_SUBSYS_VEN}"
export QEMU_PCI_SUBSYS_DEV="${QEMU_PCI_SUBSYS_DEV:-$BOARD_SUBSYS_DEV}"
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
#    (默认)      : -display none           (无 GUI；纯推流场景)
#
# STABLE_DISPLAY=1（默认）: virtio-vga，不开 -gl/virgl。规避 virgl 长期运行后
#   触发的 DXGKRNL TDR/BSOD（"VIDEO_DXGKRNL_FATAL_ERROR" / "VIDEO_SCHEDULER_
#   INTERNAL_ERROR"）。代价是没有 GL 加速，guest 的 DirectX 回退到 WARP
#   (软件 DX9-12)。DNF/腾讯 2D+DX9 类游戏 WARP 完全够用，性能差不大。
#   (注：fb-shm + headless 模式与 STABLE_DISPLAY 无关，永远走 stable 路径)
#
# STABLE_DISPLAY=0: 仅在 --sdl 模式下生效，启 virtio-vga-gl + virgl 3D 加速。
#   渲染更快但 virgl 状态机长跑会脏。
STABLE_DISPLAY=${STABLE_DISPLAY:-1}

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
# 构造 MEMORY_ARGS：根据 NUM_DIMMS 决定 1 backend 还是 2 backend，
# 对应 1 个 NUMA node（单通道）还是 2 个 NUMA node（双通道）。
# -------------------------------------------------------------------
MEMORY_ARGS=(-m "${RAM}M")
if (( NUM_DIMMS == 1 )); then
    # 1 条 DIMM 占满总量，单 NUMA node 把所有 vCPU 都挂上
    MEMORY_ARGS+=(
        -object "memory-backend-memfd,id=mem0,size=${RAM}M,share=on,prealloc=on"
        -numa "node,nodeid=0,memdev=mem0,cpus=0-$((CPUS-1))"
    )
else
    # 2 条 DIMM 各占一半，双 NUMA node 配对 dual-channel 拓扑
    MEMORY_ARGS+=(
        -object "memory-backend-memfd,id=mem0,size=${PER_DIMM_MB}M,share=on,prealloc=on"
        -object "memory-backend-memfd,id=mem1,size=${PER_DIMM_MB}M,share=on,prealloc=on"
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
# -------------------------------------------------------------------
KBD_DEVICE_ARG=(
    -device "usb-kbd,bus=xhci.0,vendorid=${KBD_VID},productid=${KBD_PID},manufacturer=${KBD_MFR},product=${KBD_PRODUCT},serial=${KBD_SERIAL}"
)
if [[ "${USB_RELATIVE_MOUSE:-0}" == "1" ]]; then
    POINTER_DEVICE_ARG=(
        -device "usb-mouse,bus=xhci.0,vendorid=${MOUSE_VID},productid=${MOUSE_PID},manufacturer=${MOUSE_MFR},product=${MOUSE_PRODUCT},serial=${MOUSE_SERIAL}"
    )
else
    POINTER_DEVICE_ARG=(
        -device "usb-tablet,bus=xhci.0,vendorid=${TABLET_VID},productid=${TABLET_PID},manufacturer=${TABLET_MFR},product=${TABLET_PRODUCT},serial=${TABLET_SERIAL}"
    )
fi

# -------------------------------------------------------------------
# Assemble the command line
# -------------------------------------------------------------------
CMD=(
    "$QEMU"

    # --- Machine / firmware ---
    # ACPI OEM IDs default to "ALASKA"/"A M I   " from our aml-build.h patch;
    # no need to pass x-oem-id on the cmdline. smm=on is required for OVMF S3.
    #
    # **2026-05 改名**：原来 "win10-ryzen3-${INSTANCE}" host `ps` 一眼能看出
    # stealth 设计；改成中性的 "win10-${INSTANCE}" 减少 host 端无意暴露
    # （不影响 guest——guest 看不到 QEMU 进程名）。debug-threads 仍开。
    -name "win10-${INSTANCE},debug-threads=on"
    -machine q35,accel=kvm,vmport=off,smm=on,hpet=off,kernel-irqchip=split
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE"
    -drive if=pflash,format=raw,file="$OVMF_VARS"

    # --- CPU: hidden hypervisor, hidden KVM, invtsc ---
    # CPU 完整 -cpu 串由 stealth_qemu_cpu_arg 拼出（包含 family/model/stepping
    # 覆盖、tsc-freq、vendor、AMD 专属 +topoext 等）。CPU 型号从 profile 随机，
    # 池子里有 AMD Ryzen3-1200/2300X 与 Intel i3-9100F/9100/G6400/G5400。
    -cpu "$(stealth_qemu_cpu_arg)"
    -smp cpus=$CPUS,cores=$CPUS,threads=1,sockets=1,maxcpus=$CPUS

    # --- Memory: backed by memfd, 拓扑由 MEMORY_ARGS 数组动态决定 ---
    # share=on（关键）：让 host 进程地址空间和 KVM 给 guest 的 page 是同一份。
    # 原本写 share=off 会触发 KVM 的 COW 路径，host 进程读到的是初始 prealloc 零页，
    # 与 guest 实际 RAM 分叉——VMI（memflow / LibVMI）会读到全零，无法工作。
    # share=on 对 guest 完全不可见（反作弊看不到任何差别），是 VMI 必须的前提。
    #
    # MEMORY_ARGS 在 CMD 数组之前按 NUM_DIMMS 拼好：
    #   NUM_DIMMS=1 (RAM ≤ 4GB)：1× full-size memfd + 1 NUMA node
    #   NUM_DIMMS=2 (RAM > 4GB)：2× half-size memfd + 2 NUMA node (dual-channel)
    "${MEMORY_ARGS[@]}"

    # --- Random identifiers ---
    -uuid "$UUID"
    # **2026-05 改 clock=vm**：原来 clock=host 让 guest RTC = host monotonic，
    # 配合 +invtsc + 钉死 tsc-freq 后，RDTSC 和 wall-clock 完美 ppm 级对齐，
    # 反而是 VM 特征（裸金属晶振温漂总有几十 ppm 偏移）。clock=vm 让 RTC 走
    # guest 自己的 TSC 计数器自然产生微漂移；driftfix=slew 仍保证 Windows
    # 时间服务能拉回 NTP 不出问题。
    -rtc base=localtime,clock=vm,driftfix=slew
    -global kvm-pit.lost_tick_policy=delay
    -boot "$BOOT_ORDER"
    -no-user-config
    -nodefaults

    # --- SMBIOS / DMI override ---
    "${SMBIOS_ARGS[@]}"

    # --- ACPI 补丁表（伪 BGRT，让 ACPI 表树看起来像真 OEM 机器） ---
    "${ACPI_ARGS[@]}"

    # --- PCI root complex (pcie-pci-bridge hidden; default q35) ---
    # hotplug=off：清掉 Slot Capabilities 的 HPC/HPS 位 (见 hw/pci/pcie.c
    # pcie_cap_slot_init)。否则根端口默认 hotplug=on → Windows pci.sys 把挂在
    # 端口下的 NVMe/网卡/xHCI 判为"可热插拔",托盘冒出"安全删除硬件"图标
    # (弹出 Samsung SSD / NVMe 控制器 / 82574L / USB3.0)——真实板载设备走的是
    # 非热插拔端口,不会出现该图标。冷插(开机即在)的设备不受影响,USB 设备热插拔
    # 走 usb 总线也不受影响,纯去指纹。
    -device pcie-root-port,id=rp0,slot=0,bus=pcie.0,multifunction=on,hotplug=off
    -device pcie-root-port,id=rp1,slot=1,bus=pcie.0,hotplug=off
    -device pcie-root-port,id=rp2,slot=2,bus=pcie.0,hotplug=off
    -device pcie-root-port,id=rp3,slot=3,bus=pcie.0,hotplug=off

    # --- TPM 2.0 (swtpm emulator, tpm-crb 风格——现代主板默认走 CRB 而不是 TIS) ---
    # 空数组时（swtpm 不可用）此处展开为零参数，不影响。
    "${TPM_ARGS[@]}"

    # --- AMD Zen Data Fabric PCI stubs at 00:18.0-7 (only for AMD CPUs) ---
    # Real Zen silicon exposes 8 DF config functions; HWiNFO/CPU-Z use these
    # to identify the CPU codename and derive channel topology. Intel CPUs
    # 不放 DF stub —— 否则会出现 "Intel CPU 但有 AMD DF" 的矛盾。
    "${AMD_DF_ARGS[@]}"

    # --- Storage: virtio-scsi host + 随机 Samsung NVMe (model/firmware/SN 来自 profile) ---
    -object iothread,id=io1
    -drive file="$DISK",if=none,id=nvm0,format=qcow2,cache=none,aio=threads,discard=unmap
    # bootindex=3 (装系统时 NVMe 空，让位给 helper image=1 / Win ISO=2)；
    # 装好系统后 OVMF NVRAM 把 Windows Boot Manager 推到最高，bootindex 不再决定顺序。
    -device nvme,id=nvmectl0,bus=rp1,drive=nvm0,serial="$NVME_SERIAL",use-samsung-id=on,bootindex=3,model-number="$NVME_MODEL",firmware-rev="$NVME_FIRMWARE"

    "${CDROM_ARGS[@]}"

    # --- Network: e1000e emulation (Intel 82574L) w/ random MAC ---
    "${NET_ARGS[@]}"
    -device e1000e,netdev=net0,mac=$MAC_OVERRIDE,bus=rp2

    # --- USB: xHCI + 键盘 + 鼠标 ---
    # usb-kbd: DirectInput/Raw Input 兼容 (DNF/腾讯反作弊只读 USB HID, 不读 PS/2).
    # USB_RELATIVE_MOUSE=1: usb-mouse (相对坐标，更像真鼠标，反作弊友好；
    #   SDL 抓鼠标，Ctrl+Shift+G 释放)
    # 默认 usb-tablet (绝对坐标，鼠标可自由出入 SDL 窗口)
    # 经 patch 0010 后 vendorid/productid/manufacturer/product/serial 全部从
    # profile 的 KBD/MOUSE/TABLET 字段注入，每台 VM 看到不同品牌键鼠。
    -device qemu-xhci,id=xhci,bus=rp3
    "${KBD_DEVICE_ARG[@]}"
    "${POINTER_DEVICE_ARG[@]}"

    # --- Audio: ICH9 HDA (looks like Realtek ALC). Use 'none' backend
    # unconditionally -- passes driver probe in guest without requiring
    # ALSA/PipeWire on the host. ---
    -audiodev none,id=aud0
    -device intel-hda,id=hda0
    -device hda-duplex,bus=hda0.0,cad=0,audiodev=aud0

    # --- Display ---
    "${DISP_ARGS[@]}"

    # --- Control: QMP + HMP sockets for API access ---
    # 用 -qmp shorthand 而不是 -chardev/-mon：等价语义，但 memflow 的命令行解析
    # 只认 -qmp 这种 flag。这样 dgame 调试器用 memflow 直读时能找到 socket。
    -qmp unix:$QMP_SOCK,server=on,wait=off
    -chardev socket,id=mon0,path=$MON_SOCK,server=on,wait=off
    -mon chardev=mon0,mode=readline

    # --- Misc anti-detection knobs ---
    -msg timestamp=off
    -overcommit mem-lock=off,cpu-pm=on
)

echo ">> instance:    $INSTANCE"
echo ">> VM 目录:     $VM_DIR"
echo ">> QMP socket:  $QMP_SOCK"
if [[ "$PROXY" == "1" ]]; then
    QMP_PROXY_SOCK="${QMP_SOCK}.proxy"
    QMP_PROXY_LOG="/tmp/qemu-stealth-${INSTANCE}.qmp.proxy.log"
    echo ">> QMP proxy:   $QMP_PROXY_SOCK (multi-client fanout, log: $QMP_PROXY_LOG)"
fi
echo ">> HMP socket:  $MON_SOCK"
# 显示通道
if [[ "$HEADLESS" == "1" ]]; then
    echo ">> GUI:         VNC 127.0.0.1:$((5900+VNC_DISPLAY)) (display :$VNC_DISPLAY)"
elif [[ "$SDL" == "1" ]]; then
    echo ">> GUI:         SDL 窗口 (DISPLAY=${DISPLAY:-未设})$([[ "$STABLE_DISPLAY" == "1" ]] && echo " stable" || echo " gl")"
else
    echo ">> GUI:         无（纯 fb-shm 推流模式）"
fi
if [[ "$FB_SHM" == "1" ]]; then
    echo ">> fb-shm sock: $FB_SHM_SOCK (rate=${FB_SHM_RATE} Hz${FB_SHM_ROI:+, ROI=$FB_SHM_ROI})"
    echo ">>   接消费端: scripts/qemu-fb-shm-stream.py --sock $FB_SHM_SOCK --output ..."
fi
if [[ "$HOTKEY_CAPTURE" == "1" ]]; then
    if [[ "$SDL" != "1" ]]; then
        echo ">> WARN: --hotkey-capture 需要 SDL 窗口接收按键，当前非 SDL，已忽略"
        HOTKEY_CAPTURE=0
    else
        echo ">> hotkey:      按 $HOTKEY_KEY -> fb-shm 抓 PNG 到 $HOTKEY_OUT (log: $HOTKEY_LOG)"
    fi
fi
echo ">> SSH/RDP fwd: 127.0.0.1:$SSH_FWD_PORT / 127.0.0.1:$RDP_FWD_PORT"
echo ">> boot mode:   $BOOT"
if [[ "$BOOT" == "iso" ]]; then
    # **ISO 装系统手动操作提示**：
    # Windows ISO 的 El Torito UEFI image 描述 Ldsiz=1 sector，OVMF auto-boot
    # 直接掉 UEFI Shell；ISO9660 主表也不含 \EFI\BOOT\BOOTX64.EFI（在 Joliet/
    # UDF 扩展里），所以即使 chainload helper 加了 startup.nsh 也偶尔 miss。
    # 手动路径最稳：OVMF splash 倒数 5 秒内按 ESC → Boot Manager →
    # "UEFI QEMU DVD-ROM" → Setup 起来后按空格过 "Press any key to boot from
    # CD or DVD"。SDL 窗口里直接键盘操作即可。
    echo ">>"
    echo ">> ============ 装系统手动步骤 ============"
    echo ">>   1. SDL 窗口里, OVMF 倒数 5 秒内按 ESC 进 Boot Manager"
    echo ">>   2. 选 'UEFI QEMU DVD-ROM QEMU DVD-ROM' → 回车 boot"
    echo ">>   3. Setup 起来后按空格过 'Press any key to boot from CD'"
    echo ">>   4. 进 Windows Setup 后正常装"
    echo ">> 若 chainload helper 自动 work, 上面步骤可跳, 直接进 Setup。"
    echo ">> ======================================="
fi
# 磁盘信息：现盘字节数 + profile 报的容量 + NVMe 型号——3 个值必须自洽。
echo ">> disk:        $DISK"
echo ">>   actual    : $(stat -c%s "$DISK") bytes (qcow2 sparse on-host)"
echo ">>   advertised: ${NVME_SIZE_BYTES:-?} bytes = ${NVME_MODEL:-?}"
# 内存信息：总量 + DIMM 拓扑 (1 单通道 / 2 双通道) + 厂商 + part number + memfd backend。
# memfd 是 share=on 让 VMI（memflow）能 mmap 同一份物理页。NUMA node 数 = DIMM 数。
# 主板物理 2 卡槽（T16_NUM_DEVICES=2）始终不变，4GB 时一个槽空。
if (( PER_DIMM_MB >= 4096 )); then
    _mem_part_used="$MEM_PART_4G"
else
    _mem_part_used="$MEM_PART_2G"
fi
if (( NUM_DIMMS == 1 )); then
    echo ">> 内存:        ${RAM} MiB 单通道 (1× ${PER_DIMM_MB} MiB memfd, NUMA 1 node)"
    echo ">>   卡槽布局 : 2 卡槽 / 占用 1 / 空 1"
else
    echo ">> 内存:        ${RAM} MiB 双通道 (2× ${PER_DIMM_MB} MiB memfd, NUMA 2 node)"
    echo ">>   卡槽布局 : 2 卡槽 / 全部占用"
fi
echo ">>   DIMM 厂商 : ${MEM_MFR:-?}"
echo ">>   part 号   : ${_mem_part_used:-?}"
if (( NUM_DIMMS == 2 )); then
    # 双通道：每条 DIMM 各自唯一 SN（第 2 条由 MEM_SERIAL 确定性派生），核对用
    _mem_sn2=$(printf '%s' "${MEM_SERIAL}-dimm2" | sha256sum | head -c 8 | tr '[:lower:]' '[:upper:]')
    echo ">>   SN        : ${MEM_SERIAL:-?} (DIMM_A2) / ${_mem_sn2} (DIMM_B2)  ← 两条各自唯一"
else
    echo ">>   SN        : ${MEM_SERIAL:-?}"
fi
# CPU 信息：profile 选定的型号 + 实际给 guest 的 vCPU 拓扑
echo ">> CPU:         ${CPU_NAME:-?}"
echo ">>   QEMU 串   : $(stealth_qemu_cpu_arg)"
echo ">>   拓扑      : ${CPUS} vCPU (cores=${CPUS}, threads=1, sockets=1, maxcpus=${CPUS})"

# 整份 stealth profile（含 CPU / 主板 / GPU / NVMe / 内存 / 网卡 / 声卡 /
# 键鼠 / 显示器 / UUID 等）。这里才打，因为 VGA_DEV、USB_RELATIVE_MOUSE、
# NUM_DIMMS、PER_DIMM_MB 都已就绪，print_profile 能反映真实运行参数。
stealth_print_profile

echo ">> --- launching ---"

# QMP fanout proxy: 后台起 qmp-proxy.py, --wait-upstream 让它在 QMP socket 还没
# 就绪时 retry, 而不是 race condition 立即退出. proxy 会在 upstream EOF (QEMU
# 退出) 时自己 exit, 所以不需要 trap. 重启 VM 时旧 proxy 已死, 新一轮会重新拉.
if [[ "$PROXY" == "1" ]]; then
    rm -f "$QMP_PROXY_SOCK"
    "$HERE/qmp-proxy.py" "$INSTANCE" --wait-upstream 30 \
        > "$QMP_PROXY_LOG" 2>&1 &
    QMP_PROXY_PID=$!
    echo ">> QMP proxy:   started pid=$QMP_PROXY_PID, listening on $QMP_PROXY_SOCK"
fi

# 热键截图: 给打了补丁的 QEMU 导出 QEMU_HOTKEY_TRIGGER(它在 ui/sdl2.c 收到
# F4 时往这个 DGRAM socket 戳一字节), 再后台拉起 hotkey-capture.py 守护进程.
# 守护进程同时跑触发器 A(XRecord 旁路监听同 display 的 F4) 与触发器 B(收上面
# 那个 socket), 两路都从 fb-shm 抓帧. 守护进程内置 socket-not-exist 重试,
# 可以先于 QEMU 起来; QEMU 退出后它收 SIGTERM 由 stop-vm.sh 清理.
if [[ "$HOTKEY_CAPTURE" == "1" ]]; then
    export QEMU_HOTKEY_TRIGGER="$HOTKEY_SOCK"
    rm -f "$HOTKEY_SOCK"
    "$HERE/hotkey-capture.py" "$INSTANCE" \
        --key "$HOTKEY_KEY" \
        --sock "$FB_SHM_SOCK" \
        --trigger-sock "$HOTKEY_SOCK" \
        --out-dir "$HOTKEY_OUT" \
        > "$HOTKEY_LOG" 2>&1 &
    HOTKEY_PID=$!
    echo ">> hotkey:      started pid=$HOTKEY_PID, key=$HOTKEY_KEY sock=$HOTKEY_SOCK"
fi

# ISO 装系统：BOOTX64.EFI 启动后会显示 "Press any key to boot from CD or DVD"
# prompt 5 秒。SDL 后端在 virtio-vga 切 mode 时偶发 "Display output is not
# active" 占位字遮住 prompt，用户来不及按键。后台 daemon 在启动后 18-60 秒
# 持续 QMP send-key spc 几次，确保 prompt 被吃掉、Setup 自动进入。Setup 进
# graphics 模式后 spc 不响应（Setup UI 不绑定 spc），无副作用。
if [[ "$BOOT" == "iso" ]]; then
    (
        # 等 OVMF + chainload 跑到 BOOTX64.EFI 大约要 15-18 秒
        sleep 16
        # 每 2 秒 send 一次, 共 ~22 次 = 44 秒，覆盖 BOOTX64.EFI 5 秒 prompt
        # 窗口的多个 retry。Setup 真正起来后 spc 也是 noop。
        for _i in $(seq 1 22); do
            [[ -S "$QMP_SOCK" ]] || break
            printf '{"execute":"qmp_capabilities"}{"execute":"human-monitor-command","arguments":{"command-line":"sendkey spc"}}\n' \
                | timeout 2 socat - UNIX-CONNECT:"$QMP_SOCK" >/dev/null 2>&1 || true
            sleep 2
        done
    ) &
    _AUTO_KEY_PID=$!
    echo ">> auto-key:    后台 daemon (pid=$_AUTO_KEY_PID) 跨过 BOOTX64.EFI 'Press any key' prompt"
fi

# QEMU's `-rtc base=localtime` calls libc localtime() which honours $TZ.
# Pin to Asia/Shanghai so the VM RTC reflects Beijing time regardless of
# what the host's /etc/timezone is set to. Without this an LA-host gives
# the guest LA wall-clock and Windows (set to CST) shows it 15h off.
export TZ="${TZ:-Asia/Shanghai}"
echo ">> RTC TZ:       $TZ"

# 禁用 host 端 X11 DPMS / 屏保，避免 host 屏幕休眠时 SDL 窗口被冻结导致
# guest 视为黑屏。退出时恢复原状。
# 只有真开了 SDL 窗口才需要 inhibit host 屏保 / DPMS。
# 纯 fb-shm（默认）/ --headless 都没本地窗口，跳过这段。
if [[ "${SDL:-0}" == "1" && "${HEADLESS:-0}" != "1" && -n "${DISPLAY:-}" ]]; then
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
