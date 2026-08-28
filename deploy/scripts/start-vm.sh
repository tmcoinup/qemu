#!/usr/bin/env bash
# start-vm.sh — NVIDIA mdev/vGPU VM 启动器
#
# 规范用法: ./deploy/scripts/start-vm.sh <vm_id> [options]
#   --vms-dir <abs>    整套 VM 根目录（实例、shared、control 一起切换）
#   --vm-dir <abs>     当前 VM 的完整 bundle 路径（末级必须为 <vm_id>）
#   --instances-dir <abs>
#                      选择 bundle 父目录，自动追加 <vm_id>
#   --print-paths      只打印最终路径并退出，不创建目录、不启动 VM
#   --install [iso]    安装模式；缺盘时自动建空盘，不会复制公共 base
#                      (NO_VFIO 旁路 vfio-pci；iso 默认 $IMAGE_ROOT/iso/win10.iso)
#                      默认仅跳过 OOBE；密钥/版本/磁盘分区仍手动选择
#                      OOBE 使用内置 Administrator，密码为空
#                      普通启动不创建光驱；手动 ISO 用 vmctl cdrom mount
#   --install-media usb|ide
#                      安装 ISO 传输：USB xHCI 高速光驱（默认）或 IDE 兼容回退
#   --manual-oobe      安装时不附加应答 ISO，恢复完整手动 OOBE
#   --native           默认 — NVIDIA vGPU 直显 + SDL，无 guest 抓屏代理
#   --sdl              同 --native，强制 SDL 窗口
#   --gtk              同 --native，改用 GTK 窗口
#   --vgpu-gtk         --gtk 的显式别名
#   --vgpu-sdl         --sdl 的显式别名
#   --driver-install   首次/重装 GRID 的安全 SDL 模式：标准 VGA 主显示，
#                      mdev 仅供 PnP 安装且 display=off；自动强制 spoof=off
#   --driver-install-gtk
#                      同上，使用 GTK 标准 VGA 窗口
#   --rdp              旧兼容路径：ivshmem + guest relay + 外部 SDL viewer
#   --legacy-shmem     --rdp 的语义化别名
#   --rescue-sdl       本地 SDL 标准显卡救援（不挂 vGPU，不用 VNC/RDP）
#   --rescue-gtk       本地 GTK 标准显卡救援（不挂 vGPU，不用 VNC/RDP）
#   --no-gpu           旧远程救援：不挂 vGPU，std-vga + VNC
#   --vnc <disp>       指定 VNC display (默认 :${VM_ID})
#   --repair-display-vars  备份 VARS 后强制清理旧 UEFI ConOut
#   --no-repair-display-vars  不自动修复已失效的 ConOut
#   --no-tpm           显式关闭 TPM（最高优先级）
#   --no-monitor-sync  跳过 host 离线 EDID 缓存同步（默认按需同步一次）
#   --production-migration-source
#                      仅本次启动已由精确 host-state/contract 锁定的
#                      legacy A 源 VM；不写入 vm.conf，也不放宽正常 A 护栏
#   --signed-consumer-probe outer-only|outer+internal
#                      仅供 probe-signed-consumer-vgpu.sh 使用的一次性、
#                      已消费 host attestation FD；普通入口不能建立授权
#   --proxy           创建 .proxy 兼容别名；DGame preview 默认已启用原生 multi QMP
#   --no-proxy        不创建 .proxy 别名（默认；不关闭 preview 所需的 multi QMP）
#   --cpu-isolate=true|false
#                      是否启用 CPU 隔离（默认 true）
#   --memory-prealloc=true|false
#                      是否全量预分配宿主 RAM（默认 true）；false 按 Guest 实际
#                      触页分配，Guest 容量/身份不变
#   --host-performance 启动前必须应用动态全频段宿主性能策略
#   --no-host-performance 本次不改变宿主性能策略
#   --svc-cpus <0..64|auto>
#                      QEMU 主循环/显示/IO 专用逻辑 CPU 数（默认 0，不单独分配）
#   --dgame-preview    为 DGame 创建独立本地 fb-shm 帧源（native 默认）
#   --no-dgame-preview 关闭 DGame 本地预览兼容端点
#   --dgame-preview-rate <Hz>  本地预览帧率 1..240（默认 60）
#   --dgame-preview-gpu 优先 SDL/GTK texture -> dma-buf（默认）
#   --no-dgame-preview-gpu 禁用 GPU-first/native EGL 启动，保留 SHM fallback
#                      （native Wayland A/B 必选）
#   --stream <URL>      启用 fb-shm 区域推流；必须给显式目标 URL/绝对文件
#   --stream-roi X,Y,W,H  固定推流区域（默认完整主显示）
#   --stream-rate <Hz>  捕获/编码帧率 1..240（默认 30）
#   --stream-encoder <name>  ffmpeg 编码器（默认 libx264）
#   --stream-bitrate <rate>  视频码率（默认 6M）
#   --stream-preset <name>   编码器 preset（默认 veryfast）
#   --stream-gop <frames>    GOP 帧数（默认 60）
#   --stream-container <name> 显式 ffmpeg muxer
#   --stream-mode auto|shm|gpu  G-11 默认 auto；GPU 不可用时回退 SHM
#   --no-stream         关闭环境变量配置的推流
#   --vlan-id <1..4094> 本次 VM 接入指定 access VLAN；guest 内收发无标签帧
#   --dry-run          只打印最终 QEMU argv，不分配 mdev/不启动
#   --numlock          默认；根据 Windows USB LED 回报确保小键盘数字键开启
#   --no-numlock       禁用本次启动的 NumLock 自动收敛
#   --low-latency-input 显式把 usb-kbd/usb-mouse interrupt interval 改为 1ms
#                      （会改变 endpoint descriptor 指纹；默认关闭）
#   --no-low-latency-input 恢复设备目录原始 USB interval（默认）
#   --guest-cursor     SDL 优先使用 QEMU 收到的权威 guest cursor sprite；
#                      unavailable 时自动保留 host 光标，不猜 framebuffer
#   --auto-cursor      REGION 内确认到拖窗软件箭头时隐藏 host 光标（可选）
#   --host-cursor      SDL 始终使用 host 光标兜底（默认，跟手优先）
#   --no-tame-gnome    不让本地 QEMU/viewer 动态处理 GNOME/IBus 宿主快捷键
#   --tame-gnome       鼠标在本地窗口内时临时关闭宿主 Ctrl+Alt+Del/Super/Alt+Tab
#   --extra "<args>"   透传额外 QEMU 参数
#
# 环境变量:
#   QEMU_BIN         QEMU 二进制路径 (默认 build/qemu-system-x86_64)
#   QEMU_IMG         qemu-img 路径（默认 build/qemu-img）
#   OVMF_CODE        OVMF_CODE.fd 路径 (默认 host/OVMF_CODE_4M_stealth.fd)
#   OVMF_VARS        OVMF_VARS.fd 模板
#   VM_ROOT/VMS_DIR  VM 根目录 (默认 $IMAGE_ROOT/vms)
#   VM_INSTANCE_DIR  当前 VM 的完整 bundle 路径（等价于 --vm-dir）
#   VM_INSTANCES_DIR 每 VM bundle 父目录 (默认 $VM_ROOT)
#   VM_BASE_DIR      公共 base 目录 (默认 $VM_ROOT/_base，与 V-11 相同)
#   ISO_DIR          Windows ISO 目录 (默认 $IMAGE_ROOT/iso)
#   INSTALL_UNATTENDED  安装时自动附加 OOBE 应答 ISO (0/1，默认 1)
#   INSTALL_UNATTEND_TEMPLATE  最小应答 XML 模板
#   INSTALL_MEDIA_BACKEND  usb|ide（默认 usb；CLI --install-media 优先）
#                     usb 会临时挂载仓库内可复现的 UEFI helper；普通启动
#                     不挂 helper、Windows ISO 或应答 ISO
#   XORRISO          xorriso 命令/路径
#   BR0              网桥名 (默认 br0)
#   BRIDGE_UPLINK_CHECK required|off（默认 required）；required 在创建 TAP 前
#                     要求 bridge 有唯一、UP/LOWER_UP 且有 carrier 的物理上联
#   G11_BRIDGE_CONFIG setup-bridge.sh 写入的可信 bridge 契约
#                     (默认 /etc/qemu/g11-bridge.conf)
#   G11_BRIDGE_HELPER setup 安装的固定 root-owned bridge helper
#   VLAN_ID          等价于 --vlan-id；CLI 优先，vm.conf 不得持久化 VLAN
#   GUEST_MEM_MB     分配内存 (默认 8192)
#   GFX_BACKEND      vGPU native 窗口后端 (sdl|gtk，默认 sdl)
#   INSTALL_GFX_BACKEND  install 窗口后端 (gtk|sdl，默认 gtk)
#   QEMU_SDL_DISABLE_IBUS auto|0|1；默认 1，仅为当前 SDL QEMU 子进程隔离
#                     IBus/Fcitx/XIM；0 恢复旧行为，auto 仅检测到 IME 时隔离
#   QEMU_SDL_PRESENT_MODE fixed|dynamic；默认 fixed，SDL 固定 60Hz Present；
#                     dynamic 保留旧的按画面变化 Present 行为
#   QEMU_SDL_TITLE_FPS auto|0|1；默认 auto。X11 实时更新标题；Wayland
#                     仅在启动器找到 Cairo libdecor 时启用，否则保持静态标题
#   QEMU_SDL_CURSOR_MODE auto|host|guest；默认 host，保留宿主即时光标；
#                     auto 只在左键拖动且 REGION 内严格确认配置的箭头
#                     模板时隐藏 host 光标
#   QEMU_SDL_ALLOW_HOST_DISPLAY_SLEEP 0|1；默认 0，SDL 窗口运行期间阻止
#                     宿主屏保/显示器休眠；1 恢复上游 QEMU 的自动息屏行为
#   QEMU_SDL_GNOME_ANIMATIONS off|on；默认 off。GNOME 下由可逆守护器
#                     去掉 SDL 窗口最小化/恢复/最大化的 clone 双影；
#                     最后一个 G-11 SDL 退出后恢复宿主原值
#   G11_SDL_WINDOW_MODE native-wayland-v1 仅由性能 wrapper 的显式
#                     --native-wayland A/B 设置；不是默认窗口路径
#   GUEST_NUMLOCK     1=默认按 guest LED 状态保持 NumLock 开启；0=关闭
#   G11_USB_HID_LOW_LATENCY 1=键盘及相对鼠标宣告 1ms USB poll；0=保持
#                     profile 原始 endpoint descriptor（默认 0）
#   G11_CHIPSET_PRESENTATION catalog|off；默认 catalog，把主板目录中的
#                     H81/H97/B150/B360/X79 映射到 00:1f.0；off 为兼容回退
#                     不修改 Windows 注册表，也不盲目发送切换键
#   DISPLAY_WIDTH/HEIGHT  旧 external viewer 窗口大小 (默认 1920x1080)
#   VGPU_ROMBAR      vGPU ROM BAR 策略 (auto|0|1；native 默认 0)
#   VGPU_ROMFILE     可选的缓存 vGPU option ROM 文件 (诊断用)
#   VGPU_HOST_CONFIG 宿主 vGPU 资源配置（默认 host/vgpu-host.conf）
#   VGPU_HOST_FB_TIER_MB  同一物理 GPU 的唯一 framebuffer 档：1024|2048
#   VGPU_RESOURCE_PROFILE  真实 mdev type id/name/glob（与 guest identity 分离）
#   VGPU_RESOURCE_FB_MB    真实 mdev framebuffer MB
#   VGPU_RESOURCE_PROFILE_1024/_2048  仅为旧配置读取兼容；配置了宿主固定档
#                     后只能命中其中一档，不能授权同一物理 GPU 混档
#   VGPU_MDEV_IDENTITY_MODE host per-mdev 名称：auto|required|off（默认 auto）
#   VGPU_MDEV_INTERNAL_PCI_IDENTITY 实验性内部 vdev/pdev ID：0|1（默认 0）
#                     仅 SPOOF_MODE=A 时生效；其他情况仍为 name-only
#   VGPU_MDEV_FRL_ENABLED 可选的 per-mdev FRL 开关：0|1；未设置则继承 profile
#   TPM               TPM 开关（0/1）；显式环境值覆盖主板 profile
#                     新配置按 BOARD_TPM_VERSION 自动选择；旧配置仍默认 TPM 2.0
#   MEM_GUARD/MEM_FORCE  Guest 最大容量护栏及显式风险旁路
#   HOST_OOM_PROTECT 1=将当前 VM 进程树临时设为 oom_score_adj=-500
#   G11_HOST_PERFORMANCE auto|required|off（默认 auto）；释放 CPU 硬件
#                     min/max 全频段、保持动态 governor、开启睿频，并避免 THP
#                     同步整理造成的卡顿。不会按来宾 CPU 型号设置频率上限
#   G11_RTC_CLOCK    vm|host（默认 vm）；vm 与 V-11 一致，减少 RTC/TSC 双时基
#                     在宿主调度抖动时产生的同步告警；host 为兼容回退
#   G11_TSC_POLICY   auto|profile|host|omit（默认 auto）；启动前读取真实 KVM
#                     TSC scaling 能力。支持时保持目录 TSC；不支持时显式使用
#                     宿主 invariant TSC，避免带着不可能的缩放值启动
#   PROXY            QMP `.proxy` 兼容别名开关（0/1，默认 0）
#   CPU_ISOLATION_AUTO_INSTALL  缺 helper/依赖时自动安装（0/1，默认 1）
#   QEMU_SERVICE_CPUS  非 vCPU 服务线程专用逻辑 CPU 数（默认 0；需显式指定）
#   DGAME_PREVIEW     auto|on|off；native 默认 on，使用独立 fb-shm 对象
#   DGAME_PREVIEW_RATE  DGame 本地预览帧率 1..240（默认 60）
#   DGAME_PREVIEW_GPU auto|on|off；默认 auto，优先亮机卡 EGL/dma-buf，
#                     失败时 DGame 自动改读同一对象的 SHM 帧
#   DGAME_QEMU_PTRACER 可选的进程级 ptracer wrapper；
#                     默认使用仓库内置版本，不修改 kernel.yama.ptrace_scope
#   HOST_RESERVE_CORES auto 或宿主保留物理核数（默认 auto）
#   DISK_GUARD       1=启动/建盘前检查 qcow2 文件系统余量（默认 1）
#   DISK_FORCE       1=仅紧急恢复时显式越过磁盘余量门禁
#   DISK_MIN_FREE_GIB / DISK_MIN_FREE_PERCENT / DISK_WARN_FREE_PERCENT
#                    默认 16 GiB / 5% / 10%
#   QEMU_DISK_AIO    auto|io_uring|native|threads（默认 auto；实读后选择）
#   STREAM_OUTPUT    显式网络 URL 或绝对输出文件；非空时启用区域推流
#   STREAM_ROI       X,Y,W,H；STREAM_RATE/ENCODER/BITRATE/PRESET/GOP/CONTAINER
#   STREAM_MODE      shm|auto|gpu（默认 auto；当前 R535 产品路径拒绝严格 gpu）
#   QEMU_FB_SHM_STREAM_BIN  qemu-fb-shm-stream 路径
#   VGPU_GUEST_FINISH_TARGET  finish-vgpu-install.sh 的一次性 rescue 提示；
#                     仅 rescue-sdl/gtk 接受，正常启动绝不注入 guest

set -euo pipefail

# Host-side phase timing is intentionally independent of guest networking.
# It tells a later report whether a delay happened before QEMU, rather than
# guessing from a frozen early-boot frame in the SDL window.
START_VM_T0_NS=$(date +%s%N)
START_VM_LAST_NS=$START_VM_T0_NS
START_VM_TIMING_LINES=()
start_vm_timing_mark() {
    local stage=$1 now_ns elapsed_ms delta_ms line

    [[ "${DRY_RUN:-0}" != 1 ]] || return 0
    now_ns=$(date +%s%N)
    elapsed_ms=$(( (now_ns - START_VM_T0_NS) / 1000000 ))
    delta_ms=$(( (now_ns - START_VM_LAST_NS) / 1000000 ))
    printf -v line '[start-vm] timing %-14s +%dms (total %dms)' \
        "$stage" "$delta_ms" "$elapsed_ms"
    START_VM_TIMING_LINES+=( "$line" )
    START_VM_LAST_NS=$now_ns
    printf '%s\n' "$line"
}

# vm.conf 在后面会被 source；单独记住调用者是否显式设置 TPM，
# 使 `TPM=0/1 ./deploy/scripts/start-vm.sh ...` 能作为真正的运行时覆盖。
TPM_ENV_WAS_SET=0
TPM_ENV_VALUE=""
if [[ -v TPM ]]; then
    TPM_ENV_WAS_SET=1
    TPM_ENV_VALUE=$TPM
fi
VGPU_GUEST_FINISH_TARGET_ENV=${VGPU_GUEST_FINISH_TARGET-}
VLAN_ID_ENV_VALUE=${VLAN_ID-}
INSTALL_MEDIA_BACKEND_ENV_VALUE=${INSTALL_MEDIA_BACKEND-}
readonly VLAN_ID_ENV_VALUE INSTALL_MEDIA_BACKEND_ENV_VALUE

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$here"

# shellcheck source=lib/vm-storage.sh
source "$here/lib/vm-storage.sh"
# shellcheck source=lib/disk-headroom.sh
source "$here/lib/disk-headroom.sh"
# shellcheck source=lib/storage-aio.sh
source "$here/lib/storage-aio.sh"
# shellcheck source=lib/bridge-network.sh
source "$here/lib/bridge-network.sh"
# shellcheck source=lib/vlan-runtime.sh
source "$here/lib/vlan-runtime.sh"
# shellcheck source=lib/dgame-endpoints.sh
source "$here/lib/dgame-endpoints.sh"
# shellcheck source=lib/dgame-qemu-ptracer.sh
source "$here/lib/dgame-qemu-ptracer.sh"

VM_ID="${1:-}"
if ! vm_storage_id_is_supported "$VM_ID"; then
    echo "usage: $0 <vm_id> [--vms-dir ABS|--vm-dir ABS|--instances-dir ABS] [--print-paths|--install [iso] [--install-media usb|ide]|--native|--gtk|--driver-install|--driver-install-gtk|--rdp|--rescue-sdl|--no-gpu|--production-migration-source|--proxy|--cpu-isolate=true|false|--memory-prealloc=true|false|--svc-cpus 0..64|auto|--stream URL|--stream-roi X,Y,W,H|--vlan-id VID|--no-tpm|--numlock|--no-numlock|--dry-run|--extra \"...\"]" >&2
    echo "vm_id must be in 1..2147483647" >&2
    exit 2
fi
REQUESTED_VM_ID=$VM_ID
shift

# Storage affects the first vm.conf read and every lock path, so extract these
# options before vm_storage_init.  Value-taking runtime options are copied as
# an inseparable pair so an --extra/--stream value cannot be mistaken for a
# storage selector.
VM_DIR_CLI=""
INSTANCES_DIR_CLI=""
VMS_DIR_CLI=""
PRINT_PATHS=0
START_VM_ARGS=()
while (( $# > 0 )); do
    case "$1" in
        --vms-dir|--vm-dir|--instances-dir)
            storage_option=$1
            (( $# >= 2 )) || {
                echo "$storage_option 需要一个绝对路径" >&2
                exit 2
            }
            storage_value=$2
            if [[ "$storage_option" == --vms-dir ]]; then
                [[ -z "$VMS_DIR_CLI" ]] || {
                    echo "--vms-dir 只能指定一次" >&2
                    exit 2
                }
                VMS_DIR_CLI=$storage_value
            elif [[ "$storage_option" == --vm-dir ]]; then
                [[ -z "$VM_DIR_CLI" ]] || {
                    echo "--vm-dir 只能指定一次" >&2
                    exit 2
                }
                VM_DIR_CLI=$storage_value
            else
                [[ -z "$INSTANCES_DIR_CLI" ]] || {
                    echo "--instances-dir 只能指定一次" >&2
                    exit 2
                }
                INSTANCES_DIR_CLI=$storage_value
            fi
            shift 2
            ;;
        --vms-dir=*|--vm-dir=*|--instances-dir=*)
            storage_option=${1%%=*}
            storage_value=${1#*=}
            [[ -n "$storage_value" ]] || {
                echo "$storage_option 需要一个绝对路径" >&2
                exit 2
            }
            if [[ "$storage_option" == --vms-dir ]]; then
                [[ -z "$VMS_DIR_CLI" ]] || {
                    echo "--vms-dir 只能指定一次" >&2
                    exit 2
                }
                VMS_DIR_CLI=$storage_value
            elif [[ "$storage_option" == --vm-dir ]]; then
                [[ -z "$VM_DIR_CLI" ]] || {
                    echo "--vm-dir 只能指定一次" >&2
                    exit 2
                }
                VM_DIR_CLI=$storage_value
            else
                [[ -z "$INSTANCES_DIR_CLI" ]] || {
                    echo "--instances-dir 只能指定一次" >&2
                    exit 2
                }
                INSTANCES_DIR_CLI=$storage_value
            fi
            shift
            ;;
        --print-paths)
            (( PRINT_PATHS == 0 )) || {
                echo "--print-paths 只能指定一次" >&2
                exit 2
            }
            PRINT_PATHS=1
            shift
            ;;
        --install)
            START_VM_ARGS+=( "$1" )
            shift
            if (( $# > 0 )) && [[ "$1" != --* ]]; then
                START_VM_ARGS+=( "$1" )
                shift
            fi
            ;;
        --vnc|--spoof-mode|--signed-consumer-probe|--shmem|--svc-cpus|--stream|--stream-output|\
        --dgame-preview-rate|--stream-roi|--stream-rate|--stream-encoder|--stream-bitrate|\
        --stream-preset|--stream-gop|--stream-container|--stream-mode|\
        --stream-start-timeout|--width|--height|--vlan-id|--install-media|--extra)
            storage_option=$1
            (( $# >= 2 )) || {
                echo "$storage_option 需要一个参数" >&2
                exit 2
            }
            START_VM_ARGS+=( "$1" "$2" )
            shift 2
            ;;
        *)
            START_VM_ARGS+=( "$1" )
            shift
            ;;
    esac
done
set -- "${START_VM_ARGS[@]}"
unset START_VM_ARGS storage_option storage_value

STORAGE_SELECTOR_COUNT=0
[[ -z "$VMS_DIR_CLI" ]] || STORAGE_SELECTOR_COUNT=$((STORAGE_SELECTOR_COUNT + 1))
[[ -z "$VM_DIR_CLI" ]] || STORAGE_SELECTOR_COUNT=$((STORAGE_SELECTOR_COUNT + 1))
[[ -z "$INSTANCES_DIR_CLI" ]] || STORAGE_SELECTOR_COUNT=$((STORAGE_SELECTOR_COUNT + 1))
if (( STORAGE_SELECTOR_COUNT > 1 )); then
    echo "--vms-dir、--vm-dir 与 --instances-dir 只能选择一个" >&2
    exit 2
elif [[ -n "$VMS_DIR_CLI" ]]; then
    vm_storage_select_root "$VMS_DIR_CLI"
elif [[ -n "$VM_DIR_CLI" ]]; then
    vm_storage_select_instance_dir "$VM_ID" "$VM_DIR_CLI"
elif [[ -n "$INSTANCES_DIR_CLI" ]]; then
    vm_storage_select_instances_dir "$INSTANCES_DIR_CLI"
elif [[ -n "${VM_INSTANCE_DIR:-}" ]]; then
    vm_storage_select_instance_dir "$VM_ID" "$VM_INSTANCE_DIR"
elif [[ -n "${VM_INSTANCES_DIR:-}" ]]; then
    vm_storage_select_instances_dir "$VM_INSTANCES_DIR"
fi
vm_storage_init

SELECTED_VM_DIR=$(vm_storage_instance_dir "$VM_ID")
G11_MIGRATION_REQUIRED=0
if vm_storage_namespace_migration_required "$VM_ID"; then
    G11_MIGRATION_REQUIRED=1
fi

if (( PRINT_PATHS )); then
    printf 'VM_ID=%s\n' "$VM_ID"
    printf 'VM_ROOT=%s\n' "$VM_ROOT"
    printf 'VM_DIR=%s\n' "$SELECTED_VM_DIR"
    printf 'VM_CONFIG=%s\n' "$(vm_storage_config_path "$VM_ID")"
    printf 'VM_DISK=%s\n' "$(vm_storage_disk_path "$VM_ID")"
    printf 'VM_NVRAM=%s\n' "$(vm_storage_nvram_path "$VM_ID")"
    printf 'VM_TPM=%s\n' "$SELECTED_VM_DIR/tpm"
    printf 'VM_RUN=%s\n' "$(vm_storage_instance_run_dir "$VM_ID")"
    printf 'VM_LOG=%s\n' "$(vm_storage_instance_log_dir "$VM_ID")"
    printf 'VM_BACKUPS=%s\n' "$SELECTED_VM_DIR/backups"
    printf 'VM_BASE=%s\n' "$(vm_storage_base_path)"
    printf 'VM_CONTROL=%s\n' "$VM_RUN_DIR"
    printf 'VM_START_LOCK=%s\n' "$(vm_storage_run_preferred_path "$VM_ID" start.lock)"
    printf 'VM_DISK_LOCK=%s\n' "$(vm_storage_run_preferred_path "$VM_ID" disk.lock)"
    printf 'VM_TPM_LOCK=%s\n' "$(vm_storage_run_preferred_path "$VM_ID" tpm.lock)"
    if (( G11_MIGRATION_REQUIRED )); then
        for LEGACY_G11_DIR in \
            "$(vm_storage_g11_namespace_instance_dir "$VM_ID")" \
            "$(vm_storage_pre_namespace_instance_dir "$VM_ID")"; do
            [[ -e "$LEGACY_G11_DIR" || -L "$LEGACY_G11_DIR" ]] || continue
            printf 'LEGACY_G11_DIR=%s\n' "$LEGACY_G11_DIR"
        done
        printf 'MIGRATION_REQUIRED=1\n'
    else
        printf 'MIGRATION_REQUIRED=0\n'
    fi
    exit 0
fi

if ! vm_storage_require_namespace_ready "$VM_ID"; then
    echo "[start-vm] 路径检查失败；先按上方提示迁移或换一个 --vms-dir" >&2
    exit 1
fi
unset G11_MIGRATION_REQUIRED STORAGE_SELECTOR_COUNT

# vm.conf and host policy files may describe guest hardware, but they may not
# redirect storage after the CLI selection and early config lookup are fixed.
readonly IMAGE_ROOT ISO_DIR STAGE_DIR VM_ROOT VMS_DIR VM_INSTANCES_DIR \
    VM_INSTANCE_DIR VM_INSTANCE_ID VM_STORAGE_COMPAT_FALLBACK \
    VM_SHARED_DIR VM_CONFIG_DIR VM_DISK_DIR VM_BASE_DIR VM_NVRAM_DIR \
    VM_CONTROL_DIR VM_RUN_DIR VM_LOG_DIR VM_ASSET_DIR \
    VM_DISK_ARCHIVE_DIR VM_BASE_ARCHIVE_DIR VM_NVRAM_BACKUP_DIR
readonly SELECTED_VM_DIR

# SUDO_PASSWORD is a launcher-only compatibility channel for bounded host
# privilege helpers.  Never export it: an exported shell variable would be
# inherited by the long-lived QEMU process and expose a host credential through
# /proc/<qemu-pid>/environ.  Helper functions can still read the shell variable
# and send it only to sudo stdin when a cached sudo ticket is unavailable.
if [[ -v SUDO_PASSWORD ]]; then
    export -n SUDO_PASSWORD 2>/dev/null || true
fi
# shellcheck source=lib/hardware-profiles.sh
source "$here/lib/hardware-profiles.sh"
# shellcheck source=lib/cpu-realization.sh
source "$here/lib/cpu-realization.sh"
# shellcheck source=lib/input-profiles.sh
source "$here/lib/input-profiles.sh"
input_profile_validate_catalog
# shellcheck source=lib/vm-tpm.sh
source "$here/lib/vm-tpm.sh"
# shellcheck source=lib/cpu-isolation.sh
source "$here/lib/cpu-isolation.sh"
# shellcheck source=lib/host-performance.sh
source "$here/lib/host-performance.sh"
# shellcheck source=lib/windows-unattend.sh
source "$here/lib/windows-unattend.sh"
# shellcheck source=lib/vgpu-host-config.sh
source "$here/lib/vgpu-host-config.sh"

# 宿主资源配置与 vmN/vm.conf 的 guest-visible identity 分开。正版
# Tesla V100 在这里固定为 V100-1Q 或 V100-2Q 单一 framebuffer 档；同一
# 物理 GPU 不能同时发布两档。显式指定的配置丢失时应立即报错，默认本地
# 文件不存在则保持旧行为。
VGPU_HOST_CONFIG_WAS_SET=0
[[ -v VGPU_HOST_CONFIG ]] && VGPU_HOST_CONFIG_WAS_SET=1
VGPU_HOST_CONFIG="${VGPU_HOST_CONFIG:-$here/host/vgpu-host.conf}"
VGPU_HOST_CONFIG_RC=0
if vgpu_host_config_load "$VGPU_HOST_CONFIG" '[start-vm]'; then
    VGPU_HOST_CONFIG_RC=0
else
    VGPU_HOST_CONFIG_RC=$?
    if [[ "$VGPU_HOST_CONFIG_RC" != 3 ]]; then
        exit "$VGPU_HOST_CONFIG_RC"
    fi
    if [[ "$VGPU_HOST_CONFIG_WAS_SET" == 1 ]]; then
        echo "[start-vm] VGPU_HOST_CONFIG 不存在: $VGPU_HOST_CONFIG" >&2
        exit 1
    fi
fi
unset VGPU_HOST_CONFIG_RC
# Host policy is sourced before vm.conf and therefore participates in the real
# shell precedence.  Capture spoof inputs only now so the pre-storage guard
# sees exactly what the later parser would inherit.
SPOOF_MODE_ENV_VALUE=${SPOOF_MODE-}
SPOOF_ENV_VALUE=${SPOOF-}

# shellcheck source=lib/vgpu-mdev.sh
source "$here/lib/vgpu-mdev.sh"
# shellcheck source=lib/vgpu-profiles.sh
source "$here/lib/vgpu-profiles.sh"
# shellcheck source=lib/signed-consumer-catalog.sh
source "$here/lib/signed-consumer-catalog.sh"
# shellcheck source=lib/hardware-legality.sh
source "$here/lib/hardware-legality.sh"
# shellcheck source=lib/hardware-serials.sh
source "$here/lib/hardware-serials.sh"
# shellcheck source=lib/identity-uniqueness.sh
source "$here/lib/identity-uniqueness.sh"
# shellcheck source=lib/gnome-shortcuts.sh
source "$here/lib/gnome-shortcuts.sh"

# --dry-run 在常规参数解析之前就要可见，避免为了“只看 argv”而 bootstrap
# VM、磁盘或 runtime 目录。已有 VM 才能 dry-run；缺 config 时不给它猜配置。
EARLY_DRY_RUN="${DRY_RUN:-0}"
EARLY_SPOOF_MODE_OVERRIDE=""
EARLY_SPOOF_SELECTOR_COUNT=0
EARLY_PRODUCTION_MIGRATION_SOURCE_REQUESTED=0
EARLY_SIGNED_CONSUMER_PROBE_STAGE=""
EARLY_DRIVER_INSTALL_REQUESTED=0
EARLY_ARGS=( "$@" )
for ((early_i = 0; early_i < ${#EARLY_ARGS[@]}; early_i += 1)); do
    case "${EARLY_ARGS[$early_i]}" in
        --dry-run) EARLY_DRY_RUN=1 ;;
        --driver-install|--driver-install-sdl|--driver-install-gtk)
            ((EARLY_DRIVER_INSTALL_REQUESTED == 0)) || {
                echo "[start-vm] driver-install 显示模式只能指定一次" >&2
                exit 2
            }
            EARLY_DRIVER_INSTALL_REQUESTED=1
            ;;
        --production-migration-source)
            ((EARLY_PRODUCTION_MIGRATION_SOURCE_REQUESTED == 0)) || {
                echo "[start-vm] --production-migration-source may appear only once" >&2
                exit 2
            }
            EARLY_PRODUCTION_MIGRATION_SOURCE_REQUESTED=1
            ;;
        --signed-consumer-probe)
            [[ -z "$EARLY_SIGNED_CONSUMER_PROBE_STAGE" ]] || {
                echo "[start-vm] --signed-consumer-probe may appear only once" >&2
                exit 2
            }
            if ((early_i + 1 < ${#EARLY_ARGS[@]})); then
                EARLY_SIGNED_CONSUMER_PROBE_STAGE=${EARLY_ARGS[$((early_i + 1))]}
            else
                echo "[start-vm] --signed-consumer-probe requires outer-only or outer+internal" >&2
                exit 2
            fi
            ((early_i += 1))
            ;;
        --no-spoof)
            EARLY_SPOOF_MODE_OVERRIDE=off
            EARLY_SPOOF_SELECTOR_COUNT=$((EARLY_SPOOF_SELECTOR_COUNT + 1))
            ;;
        --spoof-name-only)
            EARLY_SPOOF_MODE_OVERRIDE=B
            EARLY_SPOOF_SELECTOR_COUNT=$((EARLY_SPOOF_SELECTOR_COUNT + 1))
            ;;
        --spoof)
            EARLY_SPOOF_MODE_OVERRIDE=A
            EARLY_SPOOF_SELECTOR_COUNT=$((EARLY_SPOOF_SELECTOR_COUNT + 1))
            ;;
        --spoof-mode)
            EARLY_SPOOF_SELECTOR_COUNT=$((EARLY_SPOOF_SELECTOR_COUNT + 1))
            if ((early_i + 1 < ${#EARLY_ARGS[@]})); then
                EARLY_SPOOF_MODE_OVERRIDE=${EARLY_ARGS[$((early_i + 1))]}
            else
                echo "[start-vm] --spoof-mode requires A, B or off" >&2
                exit 2
            fi
            ((early_i += 1))
            ;;
        # These options consume their next token even when it starts with `--`.
        --vnc|--shmem|--width|--height|--svc-cpus|--extra|\
        --dgame-preview-rate|--stream|--stream-output|--stream-roi|--stream-rate|\
        --stream-encoder|--stream-bitrate|--stream-preset|--stream-gop|\
        --stream-container|--stream-mode|--stream-start-timeout|--vlan-id|\
        --install-media)
            ((early_i += 1))
            ;;
        # --install consumes only a following non-option ISO path.
        --install)
            if ((early_i + 1 < ${#EARLY_ARGS[@]})) &&
                    [[ "${EARLY_ARGS[$((early_i + 1))]}" != --* ]]; then
                ((early_i += 1))
            fi
            ;;
    esac
done
unset EARLY_ARGS early_i

strict_a_start_disabled() {
    echo "[start-vm] strict-A startup is disabled: legacy full-consumer paths have no reusable production-signature qualification and may depend on a modified/self-signed driver." >&2
    echo "[start-vm] Keep B/off. For migration, use --no-spoof --no-monitor-sync and install an unmodified NVIDIA/Microsoft production-signed driver." >&2
    exit 2
}

# Reject a persisted or CLI-requested A mode before creating runtime/storage
# paths or taking locks.  This is a deliberately small parser for the generated
# literal vm.conf assignments; the full sourced value is checked again below.
# A caller can still select B/off explicitly to enter the production-driver
# migration path.
normalize_early_spoof_value() {
    local value=$1
    value=${value%$'\r'}
    value=$(sed -E \
        's/[[:space:]]+#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//' \
        <<<"$value")
    if [[ "$value" == \"*\" && "$value" == *\" && ${#value} -ge 2 ]]; then
        value=${value:1:${#value}-2}
    elif [[ "$value" == \'*\' && "$value" == *\' && ${#value} -ge 2 ]]; then
        value=${value:1:${#value}-2}
    fi
    printf '%s\n' "$value"
}

production_migration_source_die() {
    echo "[start-vm] production-migration-source rejected: $*" >&2
    exit 2
}

start_vm_sha256_upper() {
    sha256sum -- "$1" | awk '{print toupper($1)}'
}

production_migration_literal_assignment() {
    local field=$1 value
    local -a lines=()

    mapfile -t lines < <(
        sed -n -E "s/^[[:space:]]*${field}=//p" \
            <<<"$EARLY_CONF_SNAPSHOT"
    )
    ((${#lines[@]} == 1)) \
        || production_migration_source_die \
            "vm.conf must contain exactly one simple ${field}= literal"
    value=$(normalize_early_spoof_value "${lines[0]}")
    [[ -n "$value" ]] \
        || production_migration_source_die \
            "vm.conf ${field} literal is empty"
    printf '%s\n' "$value"
}

production_migration_require_private_node() {
    local path=$1 kind=$2 expected_mode=$3 expected_uid=$4
    local actual_mode actual_uid

    case "$kind" in
        directory)
            [[ -d "$path" && ! -L "$path" ]] \
                || production_migration_source_die \
                    "package directory is missing or unsafe: $path"
            ;;
        file)
            [[ -f "$path" && ! -L "$path" &&
               "$(stat -c %h -- "$path")" == 1 ]] \
                || production_migration_source_die \
                    "package file is missing, linked or unsafe: $path"
            ;;
        *)
            production_migration_source_die \
                "internal package-node type is invalid"
            ;;
    esac
    actual_mode=$(stat -c %a -- "$path")
    actual_uid=$(stat -c %u -- "$path")
    [[ "$actual_mode" == "$expected_mode" &&
       "$actual_uid" == "$expected_uid" ]] \
        || production_migration_source_die \
            "package node owner/mode mismatch: $path"
}

production_migration_source_authorize() {
    local config_uuid config_profile config_mode uuid_lower
    local package_root package_dir state contract exe config_uid
    local root_fd_path root_inode migration_id contract_sha
    local expected_exe_sha expected_exe_bytes expected_gpu_name

    ((EARLY_CONF_PRESENT)) \
        || production_migration_source_die \
            "an existing immutable vm.conf is required"
    [[ "$EARLY_EFFECTIVE_SPOOF_MODE" == A ]] \
        || production_migration_source_die \
            "the switch is valid only for the exact legacy A source mode"
    for dependency in jq sha256sum awk stat realpath flock; do
        command -v "$dependency" >/dev/null 2>&1 \
            || production_migration_source_die \
                "missing verification dependency: $dependency"
    done

    config_uuid=$(production_migration_literal_assignment VM_UUID)
    config_profile=$(production_migration_literal_assignment GPU_PROFILE)
    config_mode=$(production_migration_literal_assignment SPOOF_MODE)
    [[ "$config_uuid" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] \
        || production_migration_source_die \
            "vm.conf VM_UUID is invalid"
    [[ "$config_profile" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]] \
        || production_migration_source_die \
            "vm.conf GPU_PROFILE is invalid"
    [[ "$config_mode" == A ]] \
        || production_migration_source_die \
            "vm.conf itself is not the captured A source"
    [[ "$EARLY_CONF_FILE_SHA256" =~ ^[0-9A-F]{64}$ ]] \
        || production_migration_source_die \
            "could not pin the source config hash"

    uuid_lower=${config_uuid,,}
    package_root="$STAGE_DIR/VgpuProductionMigration"
    package_dir="$package_root/vm${REQUESTED_VM_ID}-${uuid_lower}"
    state="$package_dir/host-state.json"
    contract="$package_dir/migration-contract.json"
    exe="$package_dir/VgpuProductionMigration.exe"
    config_uid=$(stat -c %u -- "$EARLY_CONF")

    production_migration_require_private_node \
        "$package_root" directory 700 "$config_uid"
    # The packager locks this canonical private directory inode exclusively.
    # Holding a shared lock makes every JSON/EXE check one immutable package
    # observation and prevents a concurrent --replace publication.
    exec {PRODUCTION_MIGRATION_LOCK_FD}<"$package_root" \
        || production_migration_source_die \
            "could not open the private package root"
    root_fd_path="/proc/self/fd/$PRODUCTION_MIGRATION_LOCK_FD"
    root_inode=$(stat -Lc '%d:%i' -- "$package_root")
    [[ -d "$root_fd_path" &&
       "$(stat -Lc '%d:%i' -- "$root_fd_path")" == "$root_inode" ]] \
        || production_migration_source_die \
            "package root changed before locking"
    flock -s "$PRODUCTION_MIGRATION_LOCK_FD"
    [[ "$(stat -Lc '%d:%i' -- "$package_root")" == "$root_inode" ]] \
        || production_migration_source_die \
            "package root changed while waiting for its lock"

    production_migration_require_private_node \
        "$package_dir" directory 700 "$config_uid"
    production_migration_require_private_node \
        "$state" file 600 "$config_uid"
    production_migration_require_private_node \
        "$contract" file 600 "$config_uid"
    production_migration_require_private_node \
        "$exe" file 600 "$config_uid"
    [[ "$(realpath -e -- "$package_dir")" == "$package_dir" &&
       "$(stat -c %s -- "$state")" -le 65536 &&
       "$(stat -c %s -- "$contract")" -le 65536 ]] \
        || production_migration_source_die \
            "package path or JSON size is unsafe"

    jq -e \
        --argjson vmId "$REQUESTED_VM_ID" \
        --arg vmUuid "$uuid_lower" \
        --arg gpuProfile "$config_profile" \
        --arg sourceConfigSha256 "$EARLY_CONF_FILE_SHA256" '
        (keys | sort) == [
            "archiveSha256", "exeBytes", "exeSha256", "gpuName",
            "gpuProfile", "guestContractSha256", "migrationId",
            "requiredHostModeAfterReceipt", "schemaVersion",
            "sourceCatalogSha256", "sourceConfigSha256", "sourceHostMode",
            "sourceInfSha256", "vmId", "vmUuid"
        ] and
        .schemaVersion == 1 and .vmId == $vmId and
        .vmUuid == $vmUuid and .gpuProfile == $gpuProfile and
        (.gpuName | type == "string" and
          startswith("NVIDIA ") and length >= 8 and length <= 64) and
        .sourceHostMode == "A" and
        .sourceConfigSha256 == $sourceConfigSha256 and
        .requiredHostModeAfterReceipt == "B" and
        (.migrationId | test("^[0-9A-F]{32}$")) and
        (.guestContractSha256 | test("^[0-9A-F]{64}$")) and
        (.exeSha256 | test("^[0-9A-F]{64}$")) and
        (.exeBytes | type == "number" and . > 268435456 and
          . < 2147483648 and floor == .) and
        .archiveSha256 ==
          "A3D7AD8B8082D6AC6214565B4766B5190A819BC9B7574765B14897E0DB809690" and
        .sourceInfSha256 ==
          "67A240E1D464CF97DABFEC1A7CECF000EAA9DDFD702F32BA2C8771F17905DC2B" and
        .sourceCatalogSha256 ==
          "56B07BD93280BBDA761CB5C9A3A13262C3605320D7286953989E2A5B16D5EC6F"
    ' "$state" >/dev/null \
        || production_migration_source_die \
            "host-state does not exactly match this VM/config/source mode"

    migration_id=$(jq -er .migrationId "$state")
    contract_sha=$(jq -er .guestContractSha256 "$state")
    expected_exe_sha=$(jq -er .exeSha256 "$state")
    expected_exe_bytes=$(jq -er .exeBytes "$state")
    expected_gpu_name=$(jq -er .gpuName "$state")
    [[ "$(start_vm_sha256_upper "$contract")" == "$contract_sha" ]] \
        || production_migration_source_die \
            "migration-contract hash does not match host-state"

    jq -e \
        --argjson vmId "$REQUESTED_VM_ID" \
        --arg vmUuid "${config_uuid^^}" \
        --arg gpuProfile "$config_profile" \
        --arg gpuName "$expected_gpu_name" \
        --arg migrationId "$migration_id" '
        (keys | sort) == [
            "driver", "gpuName", "gpuProfile", "gpuz", "legacyPnpId",
            "migrationId", "nativePnpId", "schemaVersion", "vmId", "vmUuid"
        ] and
        (.driver | keys | sort) == [
            "archiveBytes", "archiveName", "archiveSha256",
            "catalogRelativePath", "catalogSha256", "driverVersion",
            "infRelativePath", "infSha256"
        ] and
        (.gpuz | keys | sort) == ["name", "sha256"] and
        .schemaVersion == 1 and .vmId == $vmId and
        .vmUuid == $vmUuid and .gpuProfile == $gpuProfile and
        .gpuName == $gpuName and .migrationId == $migrationId and
        (.legacyPnpId |
          test("^PCI\\\\VEN_10DE&DEV_[0-9A-F]{4}&SUBSYS_[0-9A-F]{8}$")) and
        .nativePnpId == "PCI\\VEN_10DE&DEV_1E30" and
        .driver.archiveName == "538.33-display-driver.zip" and
        .driver.archiveBytes == 860703853 and
        .driver.archiveSha256 ==
          "A3D7AD8B8082D6AC6214565B4766B5190A819BC9B7574765B14897E0DB809690" and
        .driver.infRelativePath == "Display.Driver/nvgridsw.inf" and
        .driver.infSha256 ==
          "67A240E1D464CF97DABFEC1A7CECF000EAA9DDFD702F32BA2C8771F17905DC2B" and
        .driver.catalogRelativePath == "Display.Driver/nvgridsw.cat" and
        .driver.catalogSha256 ==
          "56B07BD93280BBDA761CB5C9A3A13262C3605320D7286953989E2A5B16D5EC6F" and
        .driver.driverVersion == "31.0.15.3833" and
        .gpuz.name == "GpuZProfile.exe" and
        (.gpuz.sha256 | test("^[0-9A-F]{64}$"))
    ' "$contract" >/dev/null \
        || production_migration_source_die \
            "migration-contract identity/production-driver tuple is invalid"

    [[ "$(stat -c %s -- "$exe")" == "$expected_exe_bytes" &&
       "$(start_vm_sha256_upper "$exe")" == "$expected_exe_sha" ]] \
        || production_migration_source_die \
            "migration EXE does not match host-state"
    [[ "$(stat -Lc '%d:%i' -- "$package_root")" == "$root_inode" ]] \
        || production_migration_source_die \
            "package root changed during verification"
    exec {PRODUCTION_MIGRATION_LOCK_FD}<&-

    PRODUCTION_MIGRATION_SOURCE_AUTHORIZED=1
    PRODUCTION_MIGRATION_EXPECTED_CONFIG_SHA256=$EARLY_CONF_FILE_SHA256
    PRODUCTION_MIGRATION_EXPECTED_UUID=$uuid_lower
    PRODUCTION_MIGRATION_EXPECTED_PROFILE=$config_profile
    PRODUCTION_MIGRATION_EXPECTED_GPU_NAME=$expected_gpu_name
    PRODUCTION_MIGRATION_EXPECTED_ID=$migration_id
    PRODUCTION_MIGRATION_STATE_PATH=$state
}

signed_consumer_probe_die() {
    echo "[start-vm] signed-consumer-probe rejected: $*" >&2
    exit 2
}

signed_consumer_probe_literal_assignment() {
    local field=$1 value
    local -a lines=()

    mapfile -t lines < <(
        sed -n -E "s/^[[:space:]]*${field}=//p" \
            <<<"$EARLY_CONF_SNAPSHOT"
    )
    ((${#lines[@]} == 1)) \
        || signed_consumer_probe_die \
            "vm.conf must contain exactly one simple ${field}= literal"
    value=$(normalize_early_spoof_value "${lines[0]}")
    [[ -n "$value" ]] \
        || signed_consumer_probe_die "vm.conf ${field} literal is empty"
    printf '%s\n' "$value"
}

signed_consumer_probe_authorize() {
    local fd=${G11_SIGNED_CONSUMER_PROBE_FD-} fd_path
    local config_vm_id config_uuid config_profile config_mode config_target
    local config_name config_vid config_did config_subvid config_subdid config_mdev
    local profile_sha driver_key expected_pci_vid expected_pci_did
    local expected_sub_vid expected_sub_did expected_internal_pci expected_internal_pdev
    local disk disk_path disk_token config_uid issued_at issued_epoch now_epoch
    local age_seconds

    [[ "$EARLY_SIGNED_CONSUMER_PROBE_STAGE" == outer-only ||
       "$EARLY_SIGNED_CONSUMER_PROBE_STAGE" == outer+internal ]] \
        || signed_consumer_probe_die \
            "stage must be outer-only or outer+internal"
    (( EARLY_CONF_PRESENT )) \
        || signed_consumer_probe_die \
            "an existing immutable B-mode vm.conf is required"
    (( EARLY_SPOOF_SELECTOR_COUNT == 0 )) \
        || signed_consumer_probe_die \
            "ordinary spoof CLI selectors cannot accompany a probe"
    [[ -z "$SPOOF_MODE_ENV_VALUE" && -z "$SPOOF_ENV_VALUE" ]] \
        || signed_consumer_probe_die \
            "SPOOF_MODE/SPOOF environment overrides are forbidden"
    [[ "$fd" == 191 ]] \
        || signed_consumer_probe_die \
            "authorization must arrive on the wrapper-owned one-shot FD"
    fd_path="/proc/self/fd/$fd"
    [[ -f "$fd_path" &&
       "$(stat -Lc %a -- "$fd_path")" == 600 &&
       "$(stat -Lc %u -- "$fd_path")" == "$(id -u)" &&
       "$(stat -Lc %h -- "$fd_path")" == 0 &&
       "$(stat -Lc %s -- "$fd_path")" -le 65536 ]] \
        || signed_consumer_probe_die \
            "authorization FD is not an unlinked caller-owned mode-0600 attestation"
    command -v jq >/dev/null 2>&1 \
        || signed_consumer_probe_die "jq is required"
    [[ "$VGPU_UNLOCK_PROFILE_OVERRIDE_CONFIG_PATH" == \
           /etc/vgpu_unlock/profile_override.toml &&
       "$VGPU_UNLOCK_PROFILE_OVERRIDE_CONFIG" == \
           /etc/vgpu_unlock/profile_override.toml &&
       "$VGPU_MDEV_IDENTITY_HELPER" == \
           "$here/host/update-vgpu-mdev-identity.py" &&
       -f /etc/vgpu_unlock/profile_override.toml &&
       ! -L /etc/vgpu_unlock/profile_override.toml &&
       -f "$here/host/update-vgpu-mdev-identity.py" &&
       ! -L "$here/host/update-vgpu-mdev-identity.py" ]] \
        || signed_consumer_probe_die \
            "host identity backend must be canonical /etc TOML + repository helper"

    config_vm_id=$(signed_consumer_probe_literal_assignment VM_ID)
    config_uuid=$(signed_consumer_probe_literal_assignment VM_UUID)
    config_profile=$(signed_consumer_probe_literal_assignment GPU_PROFILE)
    config_mode=$(signed_consumer_probe_literal_assignment SPOOF_MODE)
    config_target=$(signed_consumer_probe_literal_assignment VGPU_IDENTITY_TARGET)
    config_name=$(signed_consumer_probe_literal_assignment GPU_NAME)
    config_vid=$(signed_consumer_probe_literal_assignment GPU_PCI_VID)
    config_did=$(signed_consumer_probe_literal_assignment GPU_PCI_DID)
    config_subvid=$(signed_consumer_probe_literal_assignment GPU_SUB_VID)
    config_subdid=$(signed_consumer_probe_literal_assignment GPU_SUB_DID)
    config_mdev=$(signed_consumer_probe_literal_assignment VGPU_MDEV_PROFILE)
    [[ "$config_vm_id" == "$REQUESTED_VM_ID" &&
       "$config_uuid" =~ ^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$ &&
       "$config_mode" == B && "$config_target" == name-only ]] \
        || signed_consumer_probe_die "probe requires an exact B/name-only VM contract"
    signed_consumer_profile_assert_config "$config_profile" "$config_name" \
        "$config_vid" "$config_did" "$config_subvid" "$config_subdid" \
        "$config_mdev" || signed_consumer_probe_die \
            "vm.conf GPU fields differ from the canonical profile catalog"
    profile_sha=$(signed_consumer_profile_sha256 "$config_profile") \
        || signed_consumer_probe_die "cannot calculate canonical profile digest"
    driver_key=$(signed_consumer_driver_audited_default_for_profile "$config_profile") \
        || signed_consumer_probe_die "canonical profile has no audited driver row"
    signed_consumer_driver_load "$driver_key" \
        || signed_consumer_probe_die "driver catalog row is invalid"
    signed_consumer_driver_assert_profile \
        || signed_consumer_probe_die "driver catalog does not match canonical profile"
    printf -v expected_pci_vid '0x%04X' "$((SC_CANONICAL_PCI_VID))"
    printf -v expected_pci_did '0x%04X' "$((SC_CANONICAL_PCI_DID))"
    printf -v expected_sub_vid '0x%04X' "$((SC_CANONICAL_SUB_VID))"
    printf -v expected_sub_did '0x%04X' "$((SC_CANONICAL_SUB_DID))"
    printf -v expected_internal_pci '0x%04X%04X' \
        "$((SC_CANONICAL_PCI_DID))" "$((SC_CANONICAL_SUB_DID))"
    printf -v expected_internal_pdev '0x%04X' "$((SC_CANONICAL_PCI_DID))"
    if grep -Eq \
            '^[[:space:]]*(SPOOF=|VGPU_MDEV_INTERNAL_PCI_IDENTITY=['"'"']?1['"'"']?([[:space:]]|$)|VGPU_MDEV_FRL_ENABLED=|VGPU_PATCHED_DRIVER_(INF|VERSION)=)' \
            <<<"$EARLY_CONF_SNAPSHOT"; then
        signed_consumer_probe_die \
            "legacy A/internal/FRL/patched-driver markers are forbidden"
    fi
    [[ "$EARLY_CONF_FILE_SHA256" =~ ^[0-9A-F]{64}$ ]] \
        || signed_consumer_probe_die "could not pin vm.conf bytes"

    disk=$(vm_storage_disk_path "$REQUESTED_VM_ID") \
        || signed_consumer_probe_die "could not resolve disk path"
    [[ -f "$disk" && ! -L "$disk" && "$(stat -c %h -- "$disk")" == 1 ]] \
        || signed_consumer_probe_die \
            "disposable clone disk must be a regular non-linked file"
    disk_path=$(realpath -e -- "$disk") \
        || signed_consumer_probe_die "could not canonicalize clone disk"
    [[ "$disk_path" == "$disk" ]] \
        || signed_consumer_probe_die "clone disk path is not canonical"
    disk_token=$(stat -Lc '%d:%i:%s:%Y:%Z' -- "$disk")
    config_uid=$(stat -c %u -- "$EARLY_CONF")

    jq -e \
        --argjson vmId "$REQUESTED_VM_ID" \
        --arg vmUuid "${config_uuid,,}" \
        --arg stage "$EARLY_SIGNED_CONSUMER_PROBE_STAGE" \
        --arg configSha "$EARLY_CONF_FILE_SHA256" \
        --arg diskPath "$disk_path" \
        --arg diskToken "$disk_token" \
        --argjson issuedByUid "$config_uid" \
        --arg profile "$SC_CANONICAL_GPU_PROFILE" --arg profileSha "$profile_sha" \
        --arg gpuName "$SC_CANONICAL_GPU_NAME" \
        --arg pciVid "$expected_pci_vid" --arg pciDid "$expected_pci_did" \
        --arg subVid "$expected_sub_vid" --arg subDid "$expected_sub_did" \
        --arg internalPci "$expected_internal_pci" --arg internalPdev "$expected_internal_pdev" \
        --arg resourceProfile "$SC_CANONICAL_MDEV_PROFILE" \
        --argjson framebufferMb "$SC_CANONICAL_FB_MB" \
        --arg driverKey "$SC_DRIVER_KEY" --arg driverVersion "$SC_DRIVER_VERSION" \
        --arg infName "$SC_INF_NAME" --arg infSha "$SC_INF_SHA256" \
        --arg catalogName "$SC_CATALOG_NAME" --arg catSha "$SC_CATALOG_SHA256" \
        --arg packageSha "$SC_INSTALLER_SHA256" '
        (keys | sort) == [
          "configSha256", "diskPath", "diskStatToken", "disposableClone",
          "driverEvidence", "gpu", "issuedAtUtc", "issuedByUid", "nonce",
          "purpose", "schemaVersion", "stage", "vmId", "vmUuid"
        ] and
        .schemaVersion == 2 and
        .purpose == "g11-signed-consumer-disposable-clone" and
        .disposableClone == true and .vmId == $vmId and
        .vmUuid == $vmUuid and .stage == $stage and
        .configSha256 == $configSha and .diskPath == $diskPath and
        .diskStatToken == $diskToken and .issuedByUid == $issuedByUid and
        (.issuedAtUtc | (type == "string" and
          test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))) and
        (.nonce | test("^[0-9A-F]{32}$")) and
        (.gpu | keys | sort) == [
          "framebufferMb", "internalPciId", "internalPdevId", "name", "pciDid",
          "pciVid", "profile", "profileSha256", "resourceProfile", "subDid", "subVid"
        ] and
        .gpu == {
          profile: $profile, profileSha256: $profileSha, name: $gpuName,
          pciVid: $pciVid, pciDid: $pciDid, subVid: $subVid, subDid: $subDid,
          internalPciId: $internalPci, internalPdevId: $internalPdev,
          resourceProfile: $resourceProfile, framebufferMb: $framebufferMb
        } and
        (.driverEvidence | keys | sort) == [
          "catalog", "catalogSha256", "driverKey", "driverVersion", "inf", "infSha256",
          "packageSha256", "status"
        ] and
        .driverEvidence == {
          driverKey: $driverKey, driverVersion: $driverVersion, inf: $infName,
          infSha256: $infSha, catalog: $catalogName,
          catalogSha256: $catSha, packageSha256: $packageSha,
          status: "production-signed-pnp-match-host-audited-mdev-unproven"
        }
    ' "$fd_path" >/dev/null \
        || signed_consumer_probe_die \
            "attestation does not exactly bind this VM/disk/stage/driver evidence"
    issued_at=$(jq -er .issuedAtUtc "$fd_path") \
        || signed_consumer_probe_die "attestation issuedAtUtc is missing"
    issued_epoch=$(date -u -d "$issued_at" +%s 2>/dev/null) \
        || signed_consumer_probe_die "attestation issuedAtUtc is invalid"
    now_epoch=$(date -u +%s)
    age_seconds=$((now_epoch - issued_epoch))
    (( age_seconds >= -5 && age_seconds <= 600 )) \
        || signed_consumer_probe_die \
            "attestation is expired or from the future (10-minute TTL)"

    SIGNED_CONSUMER_PROBE_AUTHORIZED=1
    SIGNED_CONSUMER_PROBE_EXPECTED_STAGE=$EARLY_SIGNED_CONSUMER_PROBE_STAGE
    SIGNED_CONSUMER_PROBE_EXPECTED_CONFIG_SHA256=$EARLY_CONF_FILE_SHA256
    SIGNED_CONSUMER_PROBE_EXPECTED_UUID=${config_uuid,,}
    SIGNED_CONSUMER_PROBE_EXPECTED_PROFILE=$SC_CANONICAL_GPU_PROFILE
    SIGNED_CONSUMER_PROBE_EXPECTED_GPU_NAME=$SC_CANONICAL_GPU_NAME
    SIGNED_CONSUMER_PROBE_EXPECTED_PCI_VID=$expected_pci_vid
    SIGNED_CONSUMER_PROBE_EXPECTED_PCI_DID=$expected_pci_did
    SIGNED_CONSUMER_PROBE_EXPECTED_SUB_VID=$expected_sub_vid
    SIGNED_CONSUMER_PROBE_EXPECTED_SUB_DID=$expected_sub_did
    SIGNED_CONSUMER_PROBE_EXPECTED_INTERNAL_PCI=$expected_internal_pci
    SIGNED_CONSUMER_PROBE_EXPECTED_INTERNAL_PDEV=$expected_internal_pdev
    SIGNED_CONSUMER_PROBE_EXPECTED_DRIVER_KEY=$SC_DRIVER_KEY
    SIGNED_CONSUMER_PROBE_EXPECTED_DRIVER_VERSION=$SC_DRIVER_VERSION
    SIGNED_CONSUMER_PROBE_EXPECTED_RESOURCE_PROFILE=$SC_CANONICAL_MDEV_PROFILE
    SIGNED_CONSUMER_PROBE_EXPECTED_FB_MB=$SC_CANONICAL_FB_MB
}

EARLY_CONF=$(vm_storage_config_path "$VM_ID") || exit $?
EARLY_CONF_PRESENT=0
EARLY_CONF_SNAPSHOT=""
EARLY_CONF_FILE_SHA256=""
if [[ -e "$EARLY_CONF" || -L "$EARLY_CONF" ]]; then
    [[ -f "$EARLY_CONF" && ! -L "$EARLY_CONF" && -r "$EARLY_CONF" ]] || {
        echo "[start-vm] vm.conf must be a readable regular non-symlink file: $EARLY_CONF" >&2
        exit 2
    }
    if ((EARLY_PRODUCTION_MIGRATION_SOURCE_REQUESTED)) ||
            [[ -n "$EARLY_SIGNED_CONSUMER_PROBE_STAGE" ]]; then
        EARLY_CONF_STAT_BEFORE=$(stat -Lc '%d:%i:%s:%Y:%Z' -- "$EARLY_CONF")
        EARLY_CONF_SHA_BEFORE=$(start_vm_sha256_upper "$EARLY_CONF")
    fi
    EARLY_CONF_SNAPSHOT=$(<"$EARLY_CONF")
    if ((EARLY_PRODUCTION_MIGRATION_SOURCE_REQUESTED)) ||
            [[ -n "$EARLY_SIGNED_CONSUMER_PROBE_STAGE" ]]; then
        EARLY_CONF_SHA_AFTER=$(start_vm_sha256_upper "$EARLY_CONF")
        EARLY_CONF_STAT_AFTER=$(stat -Lc '%d:%i:%s:%Y:%Z' -- "$EARLY_CONF")
        [[ "$EARLY_CONF_SHA_BEFORE" == "$EARLY_CONF_SHA_AFTER" &&
           "$EARLY_CONF_STAT_BEFORE" == "$EARLY_CONF_STAT_AFTER" ]] \
            || {
                if [[ -n "$EARLY_SIGNED_CONSUMER_PROBE_STAGE" ]]; then
                    signed_consumer_probe_die \
                        "vm.conf changed while its immutable snapshot was captured"
                else
                    production_migration_source_die \
                        "vm.conf changed while its immutable snapshot was captured"
                fi
            }
        EARLY_CONF_FILE_SHA256=$EARLY_CONF_SHA_AFTER
        unset EARLY_CONF_SHA_BEFORE EARLY_CONF_SHA_AFTER \
            EARLY_CONF_STAT_BEFORE EARLY_CONF_STAT_AFTER
    fi
    EARLY_CONF_PRESENT=1
fi

# vm.conf may describe this requested instance but may never redirect storage,
# locks, QMP paths or device state to another numeric instance.
if ((EARLY_CONF_PRESENT)); then
    if ! awk '
        /^[[:space:]]*(#|$)/ { next }
        {
            if ($0 ~ /(^|[^[:alnum:]_])(VM_ID|SPOOF_MODE|SPOOF)([^[:alnum:]_]|$)/ &&
                    $0 !~ /^[[:space:]]*(VM_ID|SPOOF_MODE|SPOOF)=/) {
                exit 2
            }
        }
    ' <<<"$EARLY_CONF_SNAPSHOT"; then
        echo "[start-vm] vm.conf identity controls must use simple literal VM_ID/SPOOF_MODE/SPOOF assignments: $EARLY_CONF" >&2
        exit 2
    fi
    mapfile -t EARLY_VM_ID_LINES < <(
        sed -n -E 's/^[[:space:]]*VM_ID=//p' <<<"$EARLY_CONF_SNAPSHOT"
    )
    ((${#EARLY_VM_ID_LINES[@]} <= 1)) || {
        echo "[start-vm] duplicate VM_ID assignments in $EARLY_CONF" >&2
        exit 2
    }
    if ((${#EARLY_VM_ID_LINES[@]} == 1)); then
        EARLY_CONFIG_VM_ID=$(
            normalize_early_spoof_value "${EARLY_VM_ID_LINES[0]}"
        )
        if ! vm_storage_id_is_supported "$EARLY_CONFIG_VM_ID" ||
                [[ "$EARLY_CONFIG_VM_ID" != "$REQUESTED_VM_ID" ]]; then
            echo "[start-vm] vm.conf VM_ID must exactly match requested vm${REQUESTED_VM_ID}: ${EARLY_CONFIG_VM_ID:-<empty>}" >&2
            exit 2
        fi
    fi
fi

# Reproduce the later shell precedence against one immutable in-memory
# snapshot: caller environment, then config assignments, then legacy SPOOF,
# with the last CLI selector taking final precedence.
EARLY_EFFECTIVE_SPOOF_MODE=${SPOOF_MODE_ENV_VALUE:-B}
EARLY_EFFECTIVE_LEGACY_SPOOF=$SPOOF_ENV_VALUE
EARLY_LEGACY_STRICT_MARKER=0
if ((EARLY_CONF_PRESENT)); then
    mapfile -t EARLY_SPOOF_MODE_LINES < <(
        sed -n -E 's/^[[:space:]]*SPOOF_MODE=//p' \
            <<<"$EARLY_CONF_SNAPSHOT"
    )
    ((${#EARLY_SPOOF_MODE_LINES[@]} <= 1)) || {
        echo "[start-vm] duplicate SPOOF_MODE assignments in $EARLY_CONF" >&2
        exit 2
    }
    if ((${#EARLY_SPOOF_MODE_LINES[@]} == 1)); then
        EARLY_EFFECTIVE_SPOOF_MODE=$(
            normalize_early_spoof_value "${EARLY_SPOOF_MODE_LINES[0]}"
        )
        [[ -n "$EARLY_EFFECTIVE_SPOOF_MODE" ]] ||
            EARLY_EFFECTIVE_SPOOF_MODE=B
    fi

    mapfile -t EARLY_SPOOF_LINES < <(
        sed -n -E 's/^[[:space:]]*SPOOF=//p' \
            <<<"$EARLY_CONF_SNAPSHOT"
    )
    ((${#EARLY_SPOOF_LINES[@]} <= 1)) || {
        echo "[start-vm] duplicate legacy SPOOF assignments in $EARLY_CONF" >&2
        exit 2
    }
    if ((${#EARLY_SPOOF_LINES[@]} == 1)); then
        EARLY_EFFECTIVE_LEGACY_SPOOF=$(
            normalize_early_spoof_value "${EARLY_SPOOF_LINES[0]}"
        )
    fi

    # Completion-era fields are evidence that this disk/config may still carry
    # the disabled modified/self-signed driver flow.  A plain full-consumer
    # target or required-version field is not evidence: new safe B configs
    # intentionally record those future requirements.
    if grep -Eq \
            '^[[:space:]]*(VGPU_MDEV_INTERNAL_PCI_IDENTITY=['"'"'"]?1['"'"'"]?([[:space:]]|$)|VGPU_MDEV_FRL_ENABLED=|VGPU_PATCHED_DRIVER_(VERSION|INF)=)' \
            <<<"$EARLY_CONF_SNAPSHOT"; then
        EARLY_LEGACY_STRICT_MARKER=1
    fi
fi

if [[ -n "$EARLY_SPOOF_MODE_OVERRIDE" ]]; then
    EARLY_EFFECTIVE_SPOOF_MODE=$EARLY_SPOOF_MODE_OVERRIDE
else
    if [[ -n "$EARLY_EFFECTIVE_LEGACY_SPOOF" ]]; then
        case "$EARLY_EFFECTIVE_LEGACY_SPOOF" in
            1) EARLY_EFFECTIVE_SPOOF_MODE=A ;;
            0) EARLY_EFFECTIVE_SPOOF_MODE=off ;;
            *)
                echo "[start-vm] effective legacy SPOOF must be 0 or 1" >&2
                exit 2
                ;;
        esac
    fi
    if ((EARLY_LEGACY_STRICT_MARKER)); then
        EARLY_EFFECTIVE_SPOOF_MODE=A
    fi
fi
if ((EARLY_DRIVER_INSTALL_REQUESTED)); then
    ((EARLY_SPOOF_SELECTOR_COUNT == 0)) || {
        echo "[start-vm] --driver-install 已固定 spoof=off，不能再组合 spoof CLI" >&2
        exit 2
    }
    ((EARLY_PRODUCTION_MIGRATION_SOURCE_REQUESTED == 0)) &&
        [[ -z "$EARLY_SIGNED_CONSUMER_PROBE_STAGE" ]] || {
        echo "[start-vm] --driver-install 不能与生产迁移/probe 模式组合" >&2
        exit 2
    }
    # The installer must see the unmodified native GRID PnP endpoint.  Apply
    # this before the early strict-A gate as well as in the full parser below,
    # so an old config can be repaired without ever booting its legacy mode.
    EARLY_EFFECTIVE_SPOOF_MODE=off
fi

PRODUCTION_MIGRATION_SOURCE_AUTHORIZED=0
PRODUCTION_MIGRATION_EXPECTED_CONFIG_SHA256=""
PRODUCTION_MIGRATION_EXPECTED_UUID=""
PRODUCTION_MIGRATION_EXPECTED_PROFILE=""
PRODUCTION_MIGRATION_EXPECTED_GPU_NAME=""
PRODUCTION_MIGRATION_EXPECTED_ID=""
PRODUCTION_MIGRATION_STATE_PATH=""
SIGNED_CONSUMER_PROBE_AUTHORIZED=0
SIGNED_CONSUMER_PROBE_EXPECTED_STAGE=""
SIGNED_CONSUMER_PROBE_EXPECTED_CONFIG_SHA256=""
SIGNED_CONSUMER_PROBE_EXPECTED_UUID=""
SIGNED_CONSUMER_PROBE_EXPECTED_PROFILE=""
SIGNED_CONSUMER_PROBE_EXPECTED_GPU_NAME=""
SIGNED_CONSUMER_PROBE_EXPECTED_PCI_VID=""
SIGNED_CONSUMER_PROBE_EXPECTED_PCI_DID=""
SIGNED_CONSUMER_PROBE_EXPECTED_SUB_VID=""
SIGNED_CONSUMER_PROBE_EXPECTED_SUB_DID=""
SIGNED_CONSUMER_PROBE_EXPECTED_INTERNAL_PCI=""
SIGNED_CONSUMER_PROBE_EXPECTED_INTERNAL_PDEV=""
SIGNED_CONSUMER_PROBE_EXPECTED_DRIVER_KEY=""
SIGNED_CONSUMER_PROBE_EXPECTED_DRIVER_VERSION=""
SIGNED_CONSUMER_PROBE_EXPECTED_RESOURCE_PROFILE=""
SIGNED_CONSUMER_PROBE_EXPECTED_FB_MB=""
if ((EARLY_PRODUCTION_MIGRATION_SOURCE_REQUESTED)) &&
        [[ -n "$EARLY_SIGNED_CONSUMER_PROBE_STAGE" ]]; then
    signed_consumer_probe_die \
        "production-migration-source and signed-consumer-probe are mutually exclusive"
fi
if ((EARLY_PRODUCTION_MIGRATION_SOURCE_REQUESTED)); then
    production_migration_source_authorize
    echo "[start-vm] production-migration-source authorized for this invocation only: migration ${PRODUCTION_MIGRATION_EXPECTED_ID}"
fi
if [[ -n "$EARLY_SIGNED_CONSUMER_PROBE_STAGE" ]]; then
    signed_consumer_probe_authorize
    echo "[start-vm] signed-consumer-probe authorized for this invocation only: vm${REQUESTED_VM_ID} stage=${SIGNED_CONSUMER_PROBE_EXPECTED_STAGE}"
fi
readonly PRODUCTION_MIGRATION_SOURCE_AUTHORIZED \
    PRODUCTION_MIGRATION_EXPECTED_CONFIG_SHA256 \
    PRODUCTION_MIGRATION_EXPECTED_UUID \
    PRODUCTION_MIGRATION_EXPECTED_PROFILE \
    PRODUCTION_MIGRATION_EXPECTED_GPU_NAME \
    PRODUCTION_MIGRATION_EXPECTED_ID \
    PRODUCTION_MIGRATION_STATE_PATH
readonly SIGNED_CONSUMER_PROBE_AUTHORIZED \
    SIGNED_CONSUMER_PROBE_EXPECTED_STAGE \
    SIGNED_CONSUMER_PROBE_EXPECTED_CONFIG_SHA256 \
    SIGNED_CONSUMER_PROBE_EXPECTED_UUID \
    SIGNED_CONSUMER_PROBE_EXPECTED_PROFILE \
    SIGNED_CONSUMER_PROBE_EXPECTED_GPU_NAME \
    SIGNED_CONSUMER_PROBE_EXPECTED_PCI_VID \
    SIGNED_CONSUMER_PROBE_EXPECTED_PCI_DID \
    SIGNED_CONSUMER_PROBE_EXPECTED_SUB_VID \
    SIGNED_CONSUMER_PROBE_EXPECTED_SUB_DID \
    SIGNED_CONSUMER_PROBE_EXPECTED_INTERNAL_PCI \
    SIGNED_CONSUMER_PROBE_EXPECTED_INTERNAL_PDEV \
    SIGNED_CONSUMER_PROBE_EXPECTED_DRIVER_KEY \
    SIGNED_CONSUMER_PROBE_EXPECTED_DRIVER_VERSION \
    SIGNED_CONSUMER_PROBE_EXPECTED_RESOURCE_PROFILE \
    SIGNED_CONSUMER_PROBE_EXPECTED_FB_MB
readonly EARLY_DRIVER_INSTALL_REQUESTED

case "$EARLY_EFFECTIVE_SPOOF_MODE" in
    A)
        [[ "$PRODUCTION_MIGRATION_SOURCE_AUTHORIZED" == 1 ]] \
            || strict_a_start_disabled
        ;;
    B|off) ;;
    *)
        echo "[start-vm] early SPOOF_MODE must be A, B or off: $EARLY_EFFECTIVE_SPOOF_MODE" >&2
        exit 2
        ;;
esac
unset EARLY_VM_ID_LINES EARLY_CONFIG_VM_ID \
    EARLY_SPOOF_MODE_LINES EARLY_SPOOF_LINES \
    EARLY_EFFECTIVE_LEGACY_SPOOF EARLY_LEGACY_STRICT_MARKER \
    EARLY_EFFECTIVE_SPOOF_MODE \
    EARLY_PRODUCTION_MIGRATION_SOURCE_REQUESTED \
    EARLY_SIGNED_CONSUMER_PROBE_STAGE EARLY_SPOOF_SELECTOR_COUNT

if [[ "$EARLY_DRY_RUN" != 1 ]]; then
    # Shared for the complete QEMU lifetime.  The explicit storage migrator
    # takes this lock exclusively, so a VM cannot start halfway through moves.
    vm_storage_validate_root_path "$VM_ROOT" "VM root"
    mkdir -p "$VM_RUN_DIR"
    exec {STORAGE_LOCK_FD}>"$VM_RUN_DIR/.storage.lock"
    flock -s "$STORAGE_LOCK_FD"

    vm_storage_prepare
    vm_storage_prepare_instance "$VM_ID"

    # Serialize bootstrap, NVRAM repair, mdev allocation and QEMU for this VM.
    START_LOCK=$(vm_storage_run_path "$VM_ID" start.lock)
    exec {START_LOCK_FD}>"$START_LOCK"
    if ! flock -n "$START_LOCK_FD"; then
        echo "[start-vm] vm${VM_ID} 正在启动或运行（start lock busy）" >&2
        exit 1
    fi
    # If somebody manually removed the numeric bundle while QEMU was still
    # alive, its held lock inode no longer has a pathname.  Refuse before
    # recreating vm.conf/disk even though the new lock pathname is available.
    if pgrep -f \
            "qemu-system-x86_64.*-name[[:space:]]+vm${VM_ID}([,[:space:]]|$)" \
            >/dev/null 2>&1; then
        echo "[start-vm] vm${VM_ID} QEMU 已在运行；不要在线 rm 实例目录" >&2
        exit 1
    fi
fi

# Source vm conf 先 — 让里面的 SPOOF / GUEST_MEM_MB / VNC_DISPLAY 等
# per-VM 默认值优先于脚本默认，但仍然能被 env / CLI 覆盖。
CONF=$EARLY_CONF
DISK_PATH=$(vm_storage_disk_path "$VM_ID")

# 配置不存在时先生成并载入；磁盘必须等 CLI 完整解析出 MODE 后再创建，
# 否则 --install 会在公共 base 存在时误克隆一个已装系统的盘。
if [[ ! -f "$CONF" ]]; then
    if [[ "$EARLY_DRY_RUN" == 1 ]]; then
        echo "[start-vm] dry-run 需要已有配置: $CONF" >&2
        exit 1
    fi
    echo "[start-vm] $CONF 不存在，自动 ./deploy/scripts/create-vm.sh ${VM_ID}"
    VM_START_LOCK_HELD=1 "$here/scripts/create-vm.sh" "$VM_ID"
    CONF=$(vm_storage_config_path "$VM_ID")
    [[ -f "$CONF" && ! -L "$CONF" && -r "$CONF" ]] || {
        echo "[start-vm] create-vm did not publish a safe readable vm.conf: $CONF" >&2
        exit 2
    }
    EARLY_CONF_SNAPSHOT=$(<"$CONF")
fi
# Audited target-platform facts and controller placement must come from
# vm.conf, never from a caller environment accidentally inherited by the
# launcher.  Vendor/device/revision are validation facts only; qemu-xhci keeps
# its upstream behavior identity in every mode.
# Optical identity comes only from the reviewed hardware catalog.  Clear every
# historical/configurable name before and after vm.conf is sourced so neither
# the caller environment nor a persisted config can inject an arbitrary model,
# firmware or serial.  Installation helper/answer transports remain generic.
unset ODD_PROFILE ODD_BRAND ODD_MODEL ODD_FIRMWARE_REV ODD_INTERFACE \
    ODD_FORM_FACTOR ODD_SERIAL_POLICY ODD_SERIAL INSTALL_MEDIA_BACKEND \
    XHCI_PCI_VENDOR_ID XHCI_PCI_DEVICE_ID XHCI_PCI_REVISION \
    XHCI_PCI_BUS XHCI_PCI_ADDR G11_HARDWARE_CONTRACT_VERSION \
    HARDWARE_COMPONENT_CONTRACT_VERSION CPU_REALIZATION_POLICY \
    CPU_PROFILE BOARD_PROFILE MEMORY_PROFILE CPU_CORES \
    CPU_THREADS_PER_CORE CPU_VCPUS CPU_BASE_MHZ CPU_MAX_MHZ \
    CPU_L1_CACHE_KB CPU_L2_CACHE_KB CPU_L3_CACHE_KB CPU_L2_ASSOC \
    CPU_L3_ASSOC MEM_RANK MEM_DEVICE_WIDTH MEM_VOLTAGE_MV \
    MEM_MODEL_LIST MEM_MODULE_MB_LIST MEM_DEVICE_WIDTH_LIST MEM_CHANNEL_MODE \
    MEM_RANK_LIST MEM_MODULE_MFR_JEP106_LIST MEM_DRAM_MFR_JEP106_LIST \
    MEM_SERIAL_LIST \
    BOARD_RELEASE_YEAR BOARD_SERIAL_POLICY \
    INPUT_COMPONENT_CONTRACT_VERSION INPUT_PROFILE_CATALOG_REVISION \
    POINTER_MODE \
    KBD_PROFILE KBD_PROFILE_ID KBD_PROFILE_SCOPE KBD_BRAND KBD_MODEL \
    KBD_VID KBD_PID KBD_BCD_DEVICE KBD_USB_VERSION KBD_MFR KBD_PRODUCT \
    KBD_SERIAL_POLICY KBD_FIDELITY \
    MOUSE_PROFILE MOUSE_PROFILE_ID MOUSE_PROFILE_SCOPE MOUSE_BRAND MOUSE_MODEL \
    MOUSE_VID MOUSE_PID MOUSE_BCD_DEVICE MOUSE_USB_VERSION \
    MOUSE_MFR MOUSE_PRODUCT MOUSE_SERIAL_POLICY MOUSE_FIDELITY \
    POINTER_PROFILE POINTER_PROFILE_ID POINTER_PROFILE_SCOPE \
    POINTER_BRAND POINTER_MODEL POINTER_VID POINTER_PID POINTER_BCD_DEVICE \
    POINTER_USB_VERSION POINTER_MFR POINTER_PRODUCT POINTER_SERIAL_POLICY \
    POINTER_FIDELITY \
    TABLET_PROFILE TABLET_PROFILE_ID TABLET_PROFILE_SCOPE TABLET_BRAND \
    TABLET_MODEL TABLET_VID TABLET_PID TABLET_BCD_DEVICE TABLET_USB_VERSION \
    TABLET_MFR TABLET_PRODUCT TABLET_SERIAL_POLICY TABLET_FIDELITY \
    QEMU_SPD_TYPE QEMU_SPD_MODULE_MB QEMU_SPD_MODULE_MB_LIST \
    QEMU_SPD_SPEED_MT QEMU_SPD_SLOTS QEMU_SPD_RANK_LIST \
    QEMU_SPD_DEVICE_WIDTH_LIST QEMU_SPD_MODULE_MFR_JEP106_LIST \
    QEMU_SPD_DRAM_MFR_JEP106_LIST QEMU_SPD_SERIAL_LIST QEMU_SPD_PART_LIST
# shellcheck source=/dev/null
source /dev/stdin <<<"$EARLY_CONF_SNAPSHOT"
CONFIG_VM_ID_AFTER_SOURCE=${VM_ID-}
if [[ -n "$CONFIG_VM_ID_AFTER_SOURCE" &&
      "$CONFIG_VM_ID_AFTER_SOURCE" != "$REQUESTED_VM_ID" ]]; then
    echo "[start-vm] sourced vm.conf changed VM_ID away from requested vm${REQUESTED_VM_ID}" >&2
    exit 2
fi
VM_ID=$REQUESTED_VM_ID
readonly VM_ID
# VLAN is a per-launch network-domain choice.  A vm.conf assignment must not
# persist or inject it, so restore only the caller's pre-source environment.
VLAN_ID=$VLAN_ID_ENV_VALUE
INSTALL_MEDIA_BACKEND=${INSTALL_MEDIA_BACKEND_ENV_VALUE:-usb}
unset ODD_PROFILE ODD_BRAND ODD_MODEL ODD_FIRMWARE_REV ODD_INTERFACE \
    ODD_FORM_FACTOR ODD_SERIAL_POLICY ODD_SERIAL
unset EARLY_CONF EARLY_CONF_PRESENT EARLY_CONF_SNAPSHOT
unset CONFIG_VM_ID_AFTER_SOURCE

# Current generated profiles carry an atomic hardware contract and an
# explicit CPU realization policy.  Missing fields identify an immutable old
# config and enter the narrower legacy validator; a partial/newer contract is
# corruption rather than a reason to guess.
case "${G11_HARDWARE_CONTRACT_VERSION-}" in
    1|2|3)
        HARDWARE_LEGALITY_POLICY=strict
        if [[ "$G11_HARDWARE_CONTRACT_VERSION" =~ ^[23]$ &&
              "${HARDWARE_COMPONENT_CONTRACT_VERSION-}" != \
              "$G11_HARDWARE_CONTRACT_VERSION" ]]; then
            echo "[start-vm] G11 hardware contract v${G11_HARDWARE_CONTRACT_VERSION} requires matching component contract" >&2
            exit 2
        fi
        case "${CPU_REALIZATION_POLICY-}" in
            enforced) CPU_REALIZATION_LIFECYCLE=new ;;
            legacy-compatibility) CPU_REALIZATION_LIFECYCLE=legacy ;;
            *)
                echo "[start-vm] G11 hardware contract v${G11_HARDWARE_CONTRACT_VERSION} requires CPU_REALIZATION_POLICY=enforced or legacy-compatibility" >&2
                exit 2
                ;;
        esac
        expected_profile_lifecycle=$(hardware_profile_lifecycle_class \
            "${PLATFORM:-}") || {
            echo "[start-vm] hardware contract references an unclassified platform: ${PLATFORM:-<empty>}" >&2
            exit 2
        }
        case "$expected_profile_lifecycle" in
            new|explicit-new|archived)
                [[ "$CPU_REALIZATION_POLICY" == enforced ]] || {
                    echo "[start-vm] CPU realization policy conflicts with platform ${PLATFORM}: ${CPU_REALIZATION_POLICY}/${expected_profile_lifecycle}" >&2
                    exit 2
                }
                ;;
            legacy-compatibility)
                [[ "$CPU_REALIZATION_POLICY" == legacy-compatibility ]] || {
                    echo "[start-vm] CPU realization policy conflicts with platform ${PLATFORM}: ${CPU_REALIZATION_POLICY}/${expected_profile_lifecycle}" >&2
                    exit 2
                }
                ;;
        esac
        unset expected_profile_lifecycle
        ;;
    '')
        [[ ! -v CPU_REALIZATION_POLICY ]] || {
            echo "[start-vm] legacy vm.conf cannot carry CPU_REALIZATION_POLICY without G11_HARDWARE_CONTRACT_VERSION" >&2
            exit 2
        }
        HARDWARE_LEGALITY_POLICY=legacy
        CPU_REALIZATION_LIFECYCLE=legacy
        CPU_REALIZATION_POLICY=legacy-auto
        ;;
    *)
        echo "[start-vm] unsupported G11_HARDWARE_CONTRACT_VERSION=${G11_HARDWARE_CONTRACT_VERSION}" >&2
        exit 2
        ;;
esac

[[ "${VM_UUID:-}" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || {
    echo "[start-vm] VM_UUID 缺失或非法: ${VM_UUID:-<缺失>}" >&2
    exit 2
}

# e1000e does not expose a separate hardware serial.  Its persistent identity
# is VM_MAC, so validate the OUI, global/unicast bits and non-placeholder
# suffix before the address can reach QEMU.  The three extra Intel OUIs are
# accepted only for immutable legacy profiles; contract v3 is tied to the
# current reviewed generation pool in hardware-profiles.sh.
MAC_ALLOWED_OUIS=("${INTEL_OUIS[@]}")
if [[ -z "${G11_HARDWARE_CONTRACT_VERSION-}" ]]; then
    MAC_ALLOWED_OUIS+=(8C:8D:28 A0:36:9F A4:C3:F0)
fi
if ! g11_hardware_mac_validate "${VM_MAC-}" "${MAC_ALLOWED_OUIS[@]}"; then
    echo "[start-vm] VM_MAC 不是已审核的 Intel 全局单播地址: ${VM_MAC:-<缺失>}" >&2
    exit 2
fi
unset MAC_ALLOWED_OUIS

# New vm.conf files persist the complete physical-board xHCI fact tuple and
# the virtual controller placement.  They are never projected onto qemu-xhci.
# An all-missing set is a legacy config and can be derived from CPU_MODEL for
# validation; a partial set is corruption and must never be guessed.
XHCI_IDENTITY_FIELD_COUNT=0
for xhci_field in XHCI_PCI_VENDOR_ID XHCI_PCI_DEVICE_ID \
        XHCI_PCI_REVISION XHCI_PCI_BUS XHCI_PCI_ADDR; do
    if [[ -v $xhci_field ]]; then
        XHCI_IDENTITY_FIELD_COUNT=$((XHCI_IDENTITY_FIELD_COUNT + 1))
    fi
done
case "$XHCI_IDENTITY_FIELD_COUNT" in
    0)
        XHCI_IDENTITY_LEGACY=1
        echo "[start-vm] WARN: 旧 vm.conf 缺少 xHCI 平台事实；按 CPU_MODEL 补齐校验数据，运行时仍固定上游 qemu-xhci 身份" >&2
        ;;
    5)
        XHCI_IDENTITY_LEGACY=0
        xhci_pci_id_re='^0x[0-9A-Fa-f]{4}$'
        xhci_pci_revision_re='^0x[0-9A-Fa-f]{2}$'
        if [[ ! "$XHCI_PCI_VENDOR_ID" =~ $xhci_pci_id_re ||
              ! "$XHCI_PCI_DEVICE_ID" =~ $xhci_pci_id_re ||
              ! "$XHCI_PCI_REVISION" =~ $xhci_pci_revision_re ||
              "$XHCI_PCI_BUS" != pcie.0 || "$XHCI_PCI_ADDR" != 0x6 ]]; then
            echo "[start-vm] vm.conf 中 xHCI PCI identity 非法: ${XHCI_PCI_VENDOR_ID}:${XHCI_PCI_DEVICE_ID}:${XHCI_PCI_REVISION} ${XHCI_PCI_BUS}@${XHCI_PCI_ADDR}" >&2
            exit 2
        fi
        XHCI_EXPECTED_IDENTITY=$(hardware_xhci_identity_for_platform "${PLATFORM:-}") || exit $?
        XHCI_CONFIG_IDENTITY="${XHCI_PCI_VENDOR_ID}|${XHCI_PCI_DEVICE_ID}|${XHCI_PCI_REVISION}|${XHCI_PCI_BUS}|${XHCI_PCI_ADDR}"
        if [[ "$XHCI_CONFIG_IDENTITY" != "$XHCI_EXPECTED_IDENTITY" ]]; then
            echo "[start-vm] vm.conf 中 xHCI PCI identity 与平台 ${PLATFORM:-<empty>} 不一致" >&2
            echo "  config:   $XHCI_CONFIG_IDENTITY" >&2
            echo "  expected: $XHCI_EXPECTED_IDENTITY" >&2
            exit 2
        fi
        unset xhci_pci_id_re xhci_pci_revision_re \
            XHCI_EXPECTED_IDENTITY XHCI_CONFIG_IDENTITY
        ;;
    *)
        echo "[start-vm] XHCI_PCI_VENDOR_ID/XHCI_PCI_DEVICE_ID/XHCI_PCI_REVISION/XHCI_PCI_BUS/XHCI_PCI_ADDR 必须同时设置" >&2
        exit 2
        ;;
esac
unset XHCI_IDENTITY_FIELD_COUNT xhci_field

# Stable mdev UUIDs must be unique across every readable root-workflow config.
# Refuse before touching host identity state; the runtime in-use check in the
# mdev library closes the remaining race at allocation time.
UUID_SCAN_DIR=$VM_INSTANCES_DIR
[[ -z "${VM_INSTANCE_DIR:-}" ]] || UUID_SCAN_DIR=${VM_INSTANCE_DIR%/*}
for other_conf in "$UUID_SCAN_DIR"/*/vm.conf "$VM_CONFIG_DIR"/vm*.conf; do
    [[ -f "$other_conf" ]] || continue
    if [[ "$other_conf" == "$UUID_SCAN_DIR"/*/vm.conf ]]; then
        other_instance=${other_conf%/vm.conf}
        other_id=${other_instance##*/}
        vm_storage_id_is_supported "$other_id" || continue
        if [[ -L "$other_instance" || -L "$other_conf" ]]; then
            echo "[start-vm] UUID 扫描遇到不安全的数字实例路径: $other_conf" >&2
            exit 1
        fi
    fi
    [[ "$other_conf" -ef "$CONF" ]] && continue
    other_uuid=$(sed -n 's/^VM_UUID=//p' "$other_conf" | head -n 1)
    other_uuid=${other_uuid%$'\r'}
    if [[ "$other_uuid" == \"*\" && "$other_uuid" == *\" ]]; then
        other_uuid=${other_uuid:1:${#other_uuid}-2}
    elif [[ "$other_uuid" == \'*\' && "$other_uuid" == *\' ]]; then
        other_uuid=${other_uuid:1:${#other_uuid}-2}
    fi
    if [[ "$other_uuid" == "$VM_UUID" ]]; then
        echo "[start-vm] 重复 VM_UUID=$VM_UUID: $CONF 与 $other_conf" >&2
        exit 1
    fi
done
unset UUID_SCAN_DIR other_conf other_instance other_id other_uuid

# The PCIe generation/width fields were added after the first root-profile
# generator shipped.  Treat an all-missing set as a legacy config so historical
# H97 + NVMe guests remain bootable; a partially populated set is corruption,
# not a compatibility case.  New configs get the strict topology check below.
SSD_TOPOLOGY_METADATA_STRICT=0
if [[ -v SSD_FORM_FACTOR || -v SSD_PCIE_GEN || -v SSD_PCIE_LANES ]]; then
    if [[ -n "${SSD_FORM_FACTOR:-}" && -n "${SSD_PCIE_GEN:-}" &&
          -n "${SSD_PCIE_LANES:-}" ]]; then
        SSD_TOPOLOGY_METADATA_STRICT=1
    else
        echo "[start-vm] SSD_FORM_FACTOR/SSD_PCIE_GEN/SSD_PCIE_LANES 必须同时设置" >&2
        exit 2
    fi
fi
if [[ -v SSD_LOGICAL_BLOCK_SIZE || -v SSD_PHYSICAL_BLOCK_SIZE ]]; then
    if [[ -z "${SSD_LOGICAL_BLOCK_SIZE:-}" ||
          -z "${SSD_PHYSICAL_BLOCK_SIZE:-}" ]]; then
        echo "[start-vm] SSD_LOGICAL_BLOCK_SIZE/SSD_PHYSICAL_BLOCK_SIZE 必须同时设置" >&2
        exit 2
    fi
fi

# 保留旧 vm.conf 里显式 TPM=... 的兼容性，但调用者环境值优先。
TPM_CONFIG_WAS_SET=0
if [[ "$TPM_ENV_WAS_SET" == 0 && -v TPM ]]; then
    TPM_CONFIG_WAS_SET=1
fi
if [[ "$TPM_ENV_WAS_SET" == 1 ]]; then
    TPM=$TPM_ENV_VALUE
fi

# 老配置只有 GPU_PROFILE 时先补齐 guest identity。真实宿主
# mdev 资源由 VGPU_RESOURCE_* 覆盖，不再被 identity catalog 里的
# nvidia-256/nvidia-257 绑死。
if [[ -z "${GPU_NAME:-}" || -z "${GPU_CORE_MHZ:-}" ||
      -z "${GPU_BOOST_MHZ:-}" || -z "${GPU_MEMORY_MHZ:-}" ||
      -z "${GPU_MEMORY_BUS_BITS:-}" || -z "${GPU_MEMORY_TYPE_NVAPI:-}" ||
      -z "${GPU_MEMORY_MAKER:-}" || -z "${GPU_MEMORY_MAKER_NVAPI:-}" ]]; then
    vgpu_profile_load "$GPU_PROFILE"
fi
vgpu_profile_load_board_metadata "$GPU_PROFILE" || exit $?
vgpu_profile_load_memory_maker_metadata \
    "$GPU_MEMORY_MAKER" "$GPU_MEMORY_MAKER_NVAPI" || exit $?
if ! vgpu_profile_validate_rm_fb_identity_values \
        "$GPU_MEMORY_BUS_BITS" "$GPU_MEMORY_TYPE_NVAPI" \
        "$GPU_MEMORY_VENDOR_RM"; then
    echo "[start-vm] GPU 显存字段不能映射为安全的 NVIDIA RM FB 合同" >&2
    exit 2
fi
if [[ -z "${VGPU_MDEV_PROFILE:-}" ]]; then
    case "${GPU_VRAM_MB:-2048}" in
        1024) VGPU_MDEV_PROFILE=nvidia-256 ;;
        2048) VGPU_MDEV_PROFILE=nvidia-257 ;;
        *)
            echo "[start-vm] 无法为 ${GPU_VRAM_MB:-<missing>}MB 推导 legacy mdev profile" >&2
            exit 2
            ;;
    esac
fi
: "${VGPU_FB_MB:=${GPU_VRAM_MB:-2048}}"
# NVIDIA vGPU 16 time-sliced instances on one physical GPU must use one
# framebuffer size.  The host policy is checked before choosing the real V100
# (or other host GPU) resource; a legacy size-keyed mapping remains readable,
# but it cannot authorize a VM outside the fixed host tier.
if [[ -n "${VGPU_HOST_FB_TIER_MB:-}" && -n "${VGPU_HOST_VRAM_MB:-}" &&
      "$VGPU_HOST_FB_TIER_MB" != "$VGPU_HOST_VRAM_MB" ]]; then
    echo "[start-vm] VGPU_HOST_FB_TIER_MB 与兼容变量 VGPU_HOST_VRAM_MB 冲突" >&2
    exit 2
fi
VGPU_HOST_FB_TIER_MB=${VGPU_HOST_FB_TIER_MB:-${VGPU_HOST_VRAM_MB:-}}
if [[ -n "$VGPU_HOST_FB_TIER_MB" ]]; then
    VGPU_HOST_FB_TIER_MB=$(vgpu_profile_normalize_vram_mb \
        "$VGPU_HOST_FB_TIER_MB") || exit $?
    if [[ "$VGPU_FB_MB" != "$VGPU_HOST_FB_TIER_MB" ]]; then
        echo "[start-vm] VM 要求 ${VGPU_FB_MB}MB，但宿主固定档是 ${VGPU_HOST_FB_TIER_MB}MB" >&2
        echo "[start-vm] 先关闭该物理 GPU 上全部 VM，再统一迁移 vm.conf/宿主档位" >&2
        exit 2
    fi
fi
VGPU_RESOURCE_PROFILE_BY_FB=""
case "$VGPU_FB_MB" in
    1024) VGPU_RESOURCE_PROFILE_BY_FB=${VGPU_RESOURCE_PROFILE_1024:-} ;;
    2048) VGPU_RESOURCE_PROFILE_BY_FB=${VGPU_RESOURCE_PROFILE_2048:-} ;;
esac
if [[ -n "$VGPU_RESOURCE_PROFILE_BY_FB" ]]; then
    if [[ -n "${VGPU_RESOURCE_PROFILE:-}" &&
          "$VGPU_RESOURCE_PROFILE" != "$VGPU_RESOURCE_PROFILE_BY_FB" ]]; then
        echo "[start-vm] 静态 VGPU_RESOURCE_PROFILE=${VGPU_RESOURCE_PROFILE} 与 ${VGPU_FB_MB}MB 映射 ${VGPU_RESOURCE_PROFILE_BY_FB} 冲突" >&2
        exit 2
    fi
    VGPU_RESOURCE_PROFILE=$VGPU_RESOURCE_PROFILE_BY_FB
    : "${VGPU_RESOURCE_FB_MB:=$VGPU_FB_MB}"
fi
: "${VGPU_RESOURCE_PROFILE:=$VGPU_MDEV_PROFILE}"
: "${VGPU_RESOURCE_FB_MB:=$VGPU_FB_MB}"
if [[ ! "$VGPU_FB_MB" =~ ^[1-9][0-9]*$ ||
      ! "$VGPU_RESOURCE_FB_MB" =~ ^[1-9][0-9]*$ ]]; then
    echo "[start-vm] VGPU_FB_MB/VGPU_RESOURCE_FB_MB 必须是正整数" >&2
    exit 2
fi
if (( VGPU_RESOURCE_FB_MB != VGPU_FB_MB )); then
    echo "[start-vm] guest 显存 ${VGPU_FB_MB}MB 与宿主 mdev ${VGPU_RESOURCE_FB_MB}MB 不一致" >&2
    exit 2
fi
if [[ -n "${GPU_VRAM_MB:-}" && "$VGPU_FB_MB" != "$GPU_VRAM_MB" ]]; then
    echo "[start-vm] catalog 显存 ${GPU_VRAM_MB}MB 与 VM mdev 合同 ${VGPU_FB_MB}MB 不一致" >&2
    exit 2
fi

# Input contract v2 binds a stable profile id to every descriptor fact that
# this QEMU implementation can project.  serial-policy=none means descriptor
# iSerialNumber=0 and therefore no `serial=` property is ever constructed.
# Older immutable hardware-v3 files are matched atomically against the
# quarantine catalog: they remain bootable but are never selected for a new VM.
case "${INPUT_COMPONENT_CONTRACT_VERSION-}" in
    2)
        if ! input_keyboard_profile_allowed \
                "${KBD_PROFILE-}" "${KBD_BRAND-}" "${KBD_MODEL-}" \
                "${KBD_VID-}" "${KBD_PID-}" "${KBD_BCD_DEVICE-}" \
                "${KBD_USB_VERSION-}" "${KBD_MFR-}" "${KBD_PRODUCT-}" \
                "${KBD_SERIAL_POLICY-}" "${KBD_FIDELITY-}"; then
            echo "[start-vm] 键盘配置与 active input profile 原子合同不一致" >&2
            exit 2
        fi
        KBD_PROFILE_ID=$KBD_PROFILE
        KBD_PROFILE_SCOPE=active
        case "${POINTER_MODE-}" in
            absolute)
                if ! input_pointer_profile_allowed \
                        "${POINTER_PROFILE-}" "${POINTER_BRAND-}" \
                        "${POINTER_MODEL-}" "${POINTER_VID-}" \
                        "${POINTER_PID-}" "${POINTER_BCD_DEVICE-}" \
                        "${POINTER_USB_VERSION-}" "${POINTER_MFR-}" \
                        "${POINTER_PRODUCT-}" "${POINTER_SERIAL_POLICY-}" \
                        "${POINTER_FIDELITY-}"; then
                    echo "[start-vm] 绝对指针不是已审核的 generic virtual profile" >&2
                    exit 2
                fi
                POINTER_PROFILE_ID=$POINTER_PROFILE
                POINTER_PROFILE_SCOPE=active
                ;;
            relative)
                if ! input_mouse_profile_allowed \
                        "${MOUSE_PROFILE-}" "${MOUSE_BRAND-}" \
                        "${MOUSE_MODEL-}" "${MOUSE_VID-}" "${MOUSE_PID-}" \
                        "${MOUSE_BCD_DEVICE-}" "${MOUSE_USB_VERSION-}" \
                        "${MOUSE_MFR-}" "${MOUSE_PRODUCT-}" \
                        "${MOUSE_SERIAL_POLICY-}" "${MOUSE_FIDELITY-}"; then
                    echo "[start-vm] 相对鼠标配置与 active input profile 原子合同不一致" >&2
                    exit 2
                fi
                MOUSE_PROFILE_ID=$MOUSE_PROFILE
                MOUSE_PROFILE_SCOPE=active
                ;;
            *)
                echo "[start-vm] POINTER_MODE 必须是 absolute 或 relative" >&2
                exit 2
                ;;
        esac
        ;;
    '')
        if [[ -z "${KBD_VID:-}" || -z "${KBD_PID:-}" ||
              -z "${KBD_MFR:-}" || -z "${KBD_PRODUCT:-}" ]]; then
            KBD_VID=0x045E
            KBD_PID=0x0750
            KBD_MFR=Microsoft
            KBD_PRODUCT='Microsoft Wired Keyboard 600'
        fi
        input_keyboard_compat_tuple_load "$KBD_VID" "$KBD_PID" \
            "$KBD_MFR" "$KBD_PRODUCT" || {
            echo "[start-vm] 旧键盘 tuple 不在 compatibility 目录: $KBD_VID:$KBD_PID $KBD_PRODUCT" >&2
            exit 2
        }
        if [[ -z "${TABLET_VID:-}" || -z "${TABLET_PID:-}" ||
              -z "${TABLET_MFR:-}" || -z "${TABLET_PRODUCT:-}" ]]; then
            TABLET_VID=0x256C
            TABLET_PID=0x006D
            TABLET_MFR=HUION
            TABLET_PRODUCT='HUION PenTablet'
        fi
        input_pointer_compat_tuple_load "$TABLET_VID" "$TABLET_PID" \
            "$TABLET_MFR" "$TABLET_PRODUCT" || {
            echo "[start-vm] 旧品牌数位板 tuple 不在 compatibility 目录: $TABLET_VID:$TABLET_PID $TABLET_PRODUCT" >&2
            exit 2
        }
        POINTER_MODE=absolute
        echo "[start-vm] WARN: 旧 input tuple 仅作 compatibility 启动；新 VM 默认为 generic absolute pointer" >&2
        ;;
    *)
        echo "[start-vm] 不支持 INPUT_COMPONENT_CONTRACT_VERSION=${INPUT_COMPONENT_CONTRACT_VERSION}" >&2
        exit 2
        ;;
esac

# 新配置直接记录 SSD 协议、容量和固件。旧 vm.conf 没有这些
# 字段时，只对历史池中已知的 SATA 型号做保守推断，其余保持
# 旧行为（NVMe / 512 GB / 1.0）。
if [[ -z "${SSD_INTERFACE:-}" ]]; then
    case "${SSD_MODEL:-}" in
        *860\ EVO*|WDS*G2B0A*|CT*MX500SSD1|*SKC600*|HFS*GD9TNG*)
            SSD_INTERFACE=sata ;;
        *)  SSD_INTERFACE=nvme ;;
    esac
fi
: "${SSD_SIZE_BYTES:=512000000000}"
: "${SSD_FIRMWARE_REV:=1.0}"
: "${SSD_LOGICAL_BLOCK_SIZE:=512}"
: "${SSD_PHYSICAL_BLOCK_SIZE:=512}"
SSD_INTERFACE=${SSD_INTERFACE,,}
: "${SSD_CONTROLLER_PROFILE:=$([[ "$SSD_INTERFACE" == sata ]] && printf ahci || printf generic)}"
SSD_CONTROLLER_PROFILE=${SSD_CONTROLLER_PROFILE,,}
if [[ "$SSD_INTERFACE" == sata ]]; then
    : "${SSD_FORM_FACTOR:=2.5-inch}"
    : "${SSD_PCIE_GEN:=0}"
    : "${SSD_PCIE_LANES:=0}"
else
    : "${SSD_FORM_FACTOR:=m.2-2280}"
    : "${SSD_PCIE_GEN:=3}"
    : "${SSD_PCIE_LANES:=4}"
fi
case "$SSD_INTERFACE" in
    sata|nvme) ;;
    *) echo "SSD_INTERFACE 必须是 sata 或 nvme: $SSD_INTERFACE" >&2; exit 2 ;;
esac
[[ "$SSD_SIZE_BYTES" =~ ^[1-9][0-9]*$ ]] || {
    echo "SSD_SIZE_BYTES 必须是正整数: $SSD_SIZE_BYTES" >&2
    exit 2
}
[[ -n "$SSD_FIRMWARE_REV" && ${#SSD_FIRMWARE_REV} -le 8 ]] || {
    echo "SSD_FIRMWARE_REV 必须是 1..8 个字符: ${SSD_FIRMWARE_REV:-<empty>}" >&2
    exit 2
}
if [[ ! "$SSD_LOGICAL_BLOCK_SIZE" =~ ^[1-9][0-9]*$ ||
      ! "$SSD_PHYSICAL_BLOCK_SIZE" =~ ^[1-9][0-9]*$ ]] ||
        (( SSD_LOGICAL_BLOCK_SIZE < 512 ||
           SSD_PHYSICAL_BLOCK_SIZE < SSD_LOGICAL_BLOCK_SIZE ||
           SSD_LOGICAL_BLOCK_SIZE > 2097152 ||
           SSD_PHYSICAL_BLOCK_SIZE > 2097152 ||
           (SSD_LOGICAL_BLOCK_SIZE & (SSD_LOGICAL_BLOCK_SIZE - 1)) != 0 ||
           (SSD_PHYSICAL_BLOCK_SIZE & (SSD_PHYSICAL_BLOCK_SIZE - 1)) != 0 ||
           SSD_PHYSICAL_BLOCK_SIZE % SSD_LOGICAL_BLOCK_SIZE != 0 )); then
    echo "SSD 逻辑/物理扇区规格无效: ${SSD_LOGICAL_BLOCK_SIZE}/${SSD_PHYSICAL_BLOCK_SIZE}" >&2
    exit 2
fi
case "$SSD_CONTROLLER_PROFILE" in
    ahci|generic|samsung|intel|wd) ;;
    *)
        echo "SSD_CONTROLLER_PROFILE 必须是 ahci、generic、samsung、intel 或 wd: $SSD_CONTROLLER_PROFILE" >&2
        exit 2
        ;;
esac
if [[ "$SSD_INTERFACE" == sata && "$SSD_CONTROLLER_PROFILE" != ahci ]]; then
    echo "SATA SSD 必须使用 SSD_CONTROLLER_PROFILE=ahci: $SSD_CONTROLLER_PROFILE" >&2
    exit 2
fi
if [[ "$SSD_INTERFACE" == sata && "$SSD_LOGICAL_BLOCK_SIZE" != 512 ]]; then
    echo "IDE/AHCI SATA SSD 的逻辑扇区必须是 512 字节: $SSD_LOGICAL_BLOCK_SIZE" >&2
    exit 2
fi
if [[ "$SSD_INTERFACE" == nvme && "$SSD_CONTROLLER_PROFILE" == ahci ]]; then
    echo "NVMe SSD 不能使用 SSD_CONTROLLER_PROFILE=ahci" >&2
    exit 2
fi
if [[ "$SSD_INTERFACE" == nvme && "$SSD_CONTROLLER_PROFILE" == generic ]]; then
    echo "[start-vm] WARN: NVMe profile 未指定真实 controller identity，使用 generic PCI identity: ${SSD_MODEL}" >&2
fi
if [[ "$SSD_INTERFACE" == sata ]]; then
    [[ "$SSD_FORM_FACTOR" == 2.5-inch && "$SSD_PCIE_GEN" == 0 &&
       "$SSD_PCIE_LANES" == 0 ]] || {
        echo "SSD 形态/PCIe 链路元数据无效: $SSD_INTERFACE/$SSD_FORM_FACTOR Gen${SSD_PCIE_GEN}x${SSD_PCIE_LANES}" >&2
        exit 2
    }
elif [[ "$SSD_FORM_FACTOR" != m.2-2280 ||
        ! "$SSD_PCIE_GEN" =~ ^[1-9][0-9]*$ ||
        ! "$SSD_PCIE_LANES" =~ ^[1-9][0-9]*$ ]]; then
    echo "SSD 形态/PCIe 链路元数据无效: $SSD_INTERFACE/$SSD_FORM_FACTOR Gen${SSD_PCIE_GEN}x${SSD_PCIE_LANES}" >&2
    exit 2
fi
if hardware_profile_is_catalog_key "${PLATFORM:-}" &&
        ! hardware_storage_combination_allowed "$PLATFORM" "$SSD_INTERFACE" \
            "$SSD_PCIE_GEN" "$SSD_PCIE_LANES" "$SSD_FORM_FACTOR"; then
    if [[ "$SSD_TOPOLOGY_METADATA_STRICT" == 1 ]]; then
        echo "[start-vm] SSD 接口 $SSD_INTERFACE 与平台 $PLATFORM 的已审核拓扑不兼容" >&2
        echo "[start-vm] 请使用 ./deploy/scripts/create-vm.sh --force --ssd-profile 选择兼容 profile（已有盘需先迁移）" >&2
        exit 2
    fi
    echo "[start-vm] WARN: 旧 vm.conf 缺少 SSD PCIe 链路元数据；保留历史 $PLATFORM/$SSD_INTERFACE 启动行为" >&2
    echo "[start-vm] WARN: 新建 VM 会严格匹配主板链路；现有盘请先迁移再补齐存储 profile" >&2
fi

MODE=native          # 默认 vGPU + SDL 直显；ramfb 承接早期 OVMF 画面
GFX_BACKEND="${GFX_BACKEND:-sdl}"
INSTALL_GFX_BACKEND="${INSTALL_GFX_BACKEND:-gtk}"
INSTALL_MEDIA_CLI_SEEN=0
INSTALL_BOOT_HELPER="$here/firmware/g11-usb-install-boot.img"
INSTALL_BOOT_HELPER_SHA256="6c5201c7429874b83462f2694f7545dc4e625c8f7271df3a434d103c3525a96c"

# SPOOF_MODE:  A | B | off
#   A   = legacy 外部/内部消费卡 tuple；当前无生产签名 attestation，
#         所有带 vGPU 的 A 启动都会 fail-closed。
#   B   = 系统 PCI/PnP 保留原生 vGPU endpoint；消费卡名称/规格由目录
#         应用，GPU-Z 的消费级 PCI tuple 仅在 app-local NVAPI 中呈现。
#         所有已审计 profile 均使用这个生产签名安全模式。
#   off = 完全无 spoof（装 GRID 驱动 / 调试时用）
#
# vm.conf 在调用者环境之后载入，因此临时切换请使用优先级最高的 CLI 参数；
# 没有配置值时才回退到环境和默认 B。
# 新配置一律持久化 B/name-only，不再生成 legacy full-consumer 或 patched
# driver marker。当前 strict finisher 和 CLI --spoof 都不能建立可启动的 A。
# 旧字段 SPOOF=0/1 仍兼容（SPOOF=1→A, SPOOF=0→off）。
SPOOF_MODE=${SPOOF_MODE:-B}
if [[ -n "${SPOOF:-}" ]]; then
    [[ "$SPOOF" == "1" ]] && SPOOF_MODE=A || SPOOF_MODE=off
fi

# This is deliberately not legacy A.  A production consumer contract keeps
# the normal B/name-only host identity and may change only the outer QEMU PCI
# config-space tuple only after a content-addressed qualification for the
# canonical profile/driver/current host stack and this VM's UUID-bound staged
# receipt.  No VM number or GPU tuple is special-cased here.
SIGNED_CONSUMER_PRODUCTION_ACTIVE=0

signed_consumer_production_die() {
    echo "[start-vm] signed-consumer-production rejected: $*" >&2
    exit 2
}

signed_consumer_production_validate_file() {
    local path=$1 expected_sha=$2 label=$3 mode
    [[ -f "$path" && ! -L "$path" && "$(stat -c %h -- "$path")" == 1 ]] \
        || signed_consumer_production_die "$label is missing or unsafe: $path"
    [[ "$(stat -c %u -- "$path")" == 0 ]] \
        || signed_consumer_production_die "$label is not root-owned host proof"
    mode=$(stat -c %a -- "$path")
    (( (8#$mode & 022) == 0 )) \
        || signed_consumer_production_die "$label is group/world writable"
    [[ "$(start_vm_sha256_upper "$path")" == "$expected_sha" ]] \
        || signed_consumer_production_die "$label SHA-256 differs from vm.conf"
}

signed_consumer_production_validate() {
    local proof_dir qualification contract staged validated field profile_sha
    local qemu_path qemu_sha host_driver_sha host_stack_sha config_name config_vid config_did
    local config_subvid config_subdid config_mdev
    if [[ ! -v VGPU_SIGNED_CONSUMER_CONTRACT ]]; then
        return 0
    fi
    [[ "${VGPU_SIGNED_CONSUMER_CONTRACT:-}" == "$SIGNED_CONSUMER_CONTRACT_NAME" ]] \
        || signed_consumer_production_die \
            "unsupported legacy/single-VM consumer contract; rollback or migrate to signed-consumer-v2"
    for field in VGPU_SIGNED_CONSUMER_CONTRACT \
            VGPU_SIGNED_CONSUMER_STATE \
            VGPU_SIGNED_CONSUMER_PROFILE \
            VGPU_SIGNED_CONSUMER_PROFILE_SHA256 \
            VGPU_SIGNED_CONSUMER_DRIVER_KEY \
            VGPU_SIGNED_CONSUMER_QUALIFICATION_ID \
            VGPU_SIGNED_CONSUMER_QUALIFICATION_SHA256 \
            VGPU_SIGNED_CONSUMER_EXPERIMENT_ID \
            VGPU_SIGNED_CONSUMER_CONTRACT_SHA256 \
            VGPU_SIGNED_CONSUMER_STAGED_RECEIPT_SHA256 \
            VGPU_SIGNED_CONSUMER_SOURCE_CONFIG_SHA256; do
        [[ "$(grep -Ec "^[[:space:]]*${field}=" "$CONF")" == 1 ]] \
            || signed_consumer_production_die \
                "vm.conf must contain exactly one ${field}= literal"
    done
    [[ "$SPOOF_MODE" == B && "${VGPU_IDENTITY_TARGET:-}" == name-only ]] \
        || signed_consumer_production_die "contract requires B/name-only"
    [[ "${VGPU_SIGNED_CONSUMER_STATE:-}" == pending-validation ||
       "${VGPU_SIGNED_CONSUMER_STATE:-}" == validated ]] \
        || signed_consumer_production_die "contract state is invalid"
    case "$MODE" in
        native|vgpu-sdl|vgpu-gtk|no-gpu|rescue-sdl|rescue-gtk) ;;
        *) signed_consumer_production_die \
            "production contracts allow only normal vGPU or explicit no-gpu rescue" ;;
    esac
    [[ "${VGPU_SIGNED_CONSUMER_EXPERIMENT_ID:-}" =~ ^[0-9A-F]{32}$ &&
       "${VGPU_SIGNED_CONSUMER_PROFILE_SHA256:-}" =~ ^[0-9A-F]{64}$ &&
       "${VGPU_SIGNED_CONSUMER_QUALIFICATION_ID:-}" =~ ^[0-9A-F]{64}$ &&
       "${VGPU_SIGNED_CONSUMER_QUALIFICATION_SHA256:-}" =~ ^[0-9A-F]{64}$ &&
       "${VGPU_SIGNED_CONSUMER_CONTRACT_SHA256:-}" =~ ^[0-9A-F]{64}$ &&
       "${VGPU_SIGNED_CONSUMER_STAGED_RECEIPT_SHA256:-}" =~ ^[0-9A-F]{64}$ &&
       "${VGPU_SIGNED_CONSUMER_SOURCE_CONFIG_SHA256:-}" =~ ^[0-9A-F]{64}$ ]] \
        || signed_consumer_production_die "contract IDs/digests are invalid"
    [[ "${VGPU_MDEV_INTERNAL_PCI_IDENTITY:-0}" == 0 && ! -v VGPU_MDEV_FRL_ENABLED ]] \
        || signed_consumer_production_die "internal PCI and FRL overrides are forbidden"
    [[ ! -v VGPU_PATCHED_DRIVER_INF && ! -v VGPU_PATCHED_DRIVER_VERSION &&
       ! -v VGPU_PATCHED_DRIVER_REQUIRED_VERSION ]] \
        || signed_consumer_production_die "patched-driver markers are forbidden"

    config_name=${GPU_NAME:-}
    config_vid=${GPU_PCI_VID:-}
    config_did=${GPU_PCI_DID:-}
    config_subvid=${GPU_SUB_VID:-}
    config_subdid=${GPU_SUB_DID:-}
    config_mdev=${VGPU_MDEV_PROFILE:-}
    signed_consumer_profile_assert_config "${GPU_PROFILE:-}" "$config_name" \
        "$config_vid" "$config_did" "$config_subvid" "$config_subdid" \
        "$config_mdev" || signed_consumer_production_die \
            "vm.conf GPU fields differ from the canonical profile catalog"
    [[ "$VGPU_SIGNED_CONSUMER_PROFILE" == "$SC_CANONICAL_GPU_PROFILE" ]] \
        || signed_consumer_production_die "contract profile differs from vm.conf"
    profile_sha=$(signed_consumer_profile_sha256 "$SC_CANONICAL_GPU_PROFILE") \
        || signed_consumer_production_die "cannot calculate profile digest"
    [[ "$profile_sha" == "$VGPU_SIGNED_CONSUMER_PROFILE_SHA256" ]] \
        || signed_consumer_production_die "canonical profile digest differs"
    signed_consumer_driver_load "$VGPU_SIGNED_CONSUMER_DRIVER_KEY" \
        || signed_consumer_production_die "driver key is not in the audited catalog"
    signed_consumer_driver_assert_production_enabled \
        || signed_consumer_production_die \
            "driver catalog row is quarantined from production"
    signed_consumer_driver_assert_profile \
        || signed_consumer_production_die "driver key does not match canonical profile"
    [[ "${VGPU_RESOURCE_PROFILE:-}" == "$SC_CANONICAL_MDEV_PROFILE" &&
       "${VGPU_RESOURCE_FB_MB:-}" == "$SC_CANONICAL_FB_MB" ]] \
        || signed_consumer_production_die \
            "actual mdev resource differs from the qualified canonical profile"
    qemu_path=${QEMU_BIN:-$here/../build/qemu-system-x86_64}
    qemu_path=$(realpath -e -- "$qemu_path") \
        || signed_consumer_production_die "current QEMU binary is missing"
    qemu_sha=$(signed_consumer_qemu_sha256 "$qemu_path") \
        || signed_consumer_production_die "current QEMU binary is unsafe"
    host_driver_sha=$(signed_consumer_host_driver_sha256) \
        || signed_consumer_production_die "current NVIDIA host-driver fact is unavailable"
    host_stack_sha=$(signed_consumer_host_stack_sha256 \
        "$SC_CANONICAL_MDEV_PROFILE" "$SC_CANONICAL_FB_MB") \
        || signed_consumer_production_die \
            "current kernel/NVIDIA module/physical GPU/mdev type facts are unavailable"
    [[ "$(signed_consumer_qualification_id "$profile_sha" "$qemu_sha" "$host_driver_sha" "$host_stack_sha")" == \
       "$VGPU_SIGNED_CONSUMER_QUALIFICATION_ID" ]] \
        || signed_consumer_production_die "qualification does not match current host stack"

    proof_dir="$STAGE_DIR/SignedConsumerRuntimeProofs-v2/vm${VM_ID}-${VM_UUID,,}/$VGPU_SIGNED_CONSUMER_EXPERIMENT_ID"
    qualification="$proof_dir/qualification.json"
    contract="$proof_dir/guest-contract.json"
    staged="$proof_dir/staged.json"
    signed_consumer_production_validate_file "$qualification" \
        "$VGPU_SIGNED_CONSUMER_QUALIFICATION_SHA256" "qualification"
    signed_consumer_production_validate_file "$contract" \
        "$VGPU_SIGNED_CONSUMER_CONTRACT_SHA256" "guest contract"
    signed_consumer_production_validate_file "$staged" \
        "$VGPU_SIGNED_CONSUMER_STAGED_RECEIPT_SHA256" "per-VM staged receipt"
    command -v jq >/dev/null 2>&1 || signed_consumer_production_die "jq is required"

    jq -e --argjson vmId "$VM_ID" --arg vmUuid "${VM_UUID,,}" \
        --arg experimentId "$VGPU_SIGNED_CONSUMER_EXPERIMENT_ID" \
        --arg profile "$SC_CANONICAL_GPU_PROFILE" --arg profileSha "$profile_sha" \
        --arg driverKey "$SC_DRIVER_KEY" \
        --arg qualificationId "$VGPU_SIGNED_CONSUMER_QUALIFICATION_ID" \
        --arg qualificationSha "$VGPU_SIGNED_CONSUMER_QUALIFICATION_SHA256" \
        --arg baseline "$SC_BASELINE_PNP_PREFIX" --arg pnp "$SC_CANONICAL_TARGET_PNP" \
        --arg gpuName "$SC_CANONICAL_GPU_NAME" --arg version "$SC_DRIVER_VERSION" \
        --arg installerSha "$SC_INSTALLER_SHA256" --arg infName "$SC_INF_NAME" \
        --arg infSha "$SC_INF_SHA256" --arg modelLine "$SC_INF_MODEL_LINE" \
        --arg catalogName "$SC_CATALOG_NAME" --arg catSha "$SC_CATALOG_SHA256" \
        --arg signer "$SC_CATALOG_SIGNER_THUMBPRINT" --arg kernelName "$SC_KERNEL_NAME" \
        --arg sysSha "$SC_KERNEL_SHA256" '
        .schemaVersion == 2 and .vmId == $vmId and
        (.vmUuid | ascii_downcase) == $vmUuid and .experimentId == $experimentId and
        .sourceHostMode == "B" and .gpuProfile == $profile and
        .profileSha256 == $profileSha and .driverKey == $driverKey and
        .qualificationId == $qualificationId and .qualificationSha256 == $qualificationSha and
        .deploymentIntent == "qualified-production-staging" and
        .baselinePnpId == $baseline and .targetPnpId == $pnp and .targetGpuName == $gpuName and
        .driver.installerSha256 == $installerSha and .driver.infName == $infName and
        .driver.infSha256 == $infSha and .driver.infModelLine == $modelLine and
        .driver.catalogName == $catalogName and .driver.catalogSha256 == $catSha and
        .driver.catalogSignerThumbprint == $signer and .driver.kernelName == $kernelName and
        .driver.kernelSha256 == $sysSha and .driver.driverVersion == $version
    ' "$contract" >/dev/null || signed_consumer_production_die "guest contract is invalid"

    jq -e --arg id "$VGPU_SIGNED_CONSUMER_QUALIFICATION_ID" \
        --arg purpose "$SIGNED_CONSUMER_QUALIFICATION_PURPOSE" \
        --arg backend "$SIGNED_CONSUMER_BACKEND_ABI" --arg profile "$SC_CANONICAL_GPU_PROFILE" \
        --arg profileSha "$profile_sha" --arg gpuName "$SC_CANONICAL_GPU_NAME" \
        --arg pnp "$SC_CANONICAL_TARGET_PNP" --arg driverKey "$SC_DRIVER_KEY" \
        --arg version "$SC_DRIVER_VERSION" --arg infSha "$SC_INF_SHA256" \
        --arg catSha "$SC_CATALOG_SHA256" --arg sysSha "$SC_KERNEL_SHA256" \
        --arg installerSha "$SC_INSTALLER_SHA256" \
        --arg packageBuilder "$SC_PACKAGE_BUILDER" \
        --arg packageBuilderSha "$SC_PACKAGE_BUILDER_SHA256" \
        --arg guestValidator "$SC_GUEST_VALIDATOR" \
        --arg guestValidatorSha "$SC_GUEST_VALIDATOR_SHA256" \
        --arg signer "$SC_CATALOG_SIGNER_THUMBPRINT" --arg qemuSha "$qemu_sha" \
        --arg baseline "$SC_BASELINE_PNP_PREFIX" --arg baselineVersion "$SC_BASELINE_DRIVER_VERSION" \
        --arg hostDriverSha "$host_driver_sha" --arg hostStackSha "$host_stack_sha" \
        --arg mdev "$SC_CANONICAL_MDEV_PROFILE" \
        --argjson fb "$SC_CANONICAL_FB_MB" '
        .schemaVersion == 2 and .purpose == $purpose and .qualificationId == $id and
        .consumer == {gpuProfile:$profile,profileSha256:$profileSha,gpuName:$gpuName,exactHardwareId:$pnp} and
        .driver == {key:$driverKey,version:$version,infSha256:$infSha,catalogSha256:$catSha,
                    kernelSha256:$sysSha,catalogSignerThumbprint:$signer,
                    baselinePnpPrefix:$baseline,baselineDriverVersion:$baselineVersion,
                    installerSha256:$installerSha,packageBuilder:$packageBuilder,
                    packageBuilderSha256:$packageBuilderSha,
                    guestValidator:$guestValidator,
                    guestValidatorSha256:$guestValidatorSha} and
        .compatibility == {backendAbi:$backend,qemuSha256:$qemuSha,
                           hostDriverSha256:$hostDriverSha,hostStackSha256:$hostStackSha,
                           mdevProfile:$mdev,
                           framebufferMb:$fb,projection:"outer-only",internalIdentity:"native"} and
        .result == {displayCount:1,configManagerErrorCode:0,testsigning:false,
                    nointegritychecks:false,bcdChanged:false}
    ' "$qualification" >/dev/null \
        || signed_consumer_production_die "qualification marker is invalid"
    jq -e --argjson vmId "$VM_ID" --arg vmUuid "${VM_UUID,,}" \
        --arg experimentId "$VGPU_SIGNED_CONSUMER_EXPERIMENT_ID" \
        --arg contractSha "$VGPU_SIGNED_CONSUMER_CONTRACT_SHA256" \
        --arg baseline "$SC_BASELINE_PNP_PREFIX" --arg baselineVersion "$SC_BASELINE_DRIVER_VERSION" \
        --arg pnp "$SC_CANONICAL_TARGET_PNP" --arg version "$SC_DRIVER_VERSION" \
        --arg infSha "$SC_INF_SHA256" --arg catSha "$SC_CATALOG_SHA256" \
        --arg sysSha "$SC_KERNEL_SHA256" --arg signer "$SC_CATALOG_SIGNER_THUMBPRINT" '
        .schemaVersion == 1 and .phase == "staged" and .result == "pass" and
        .vmId == $vmId and .vmUuid == $vmUuid and .experimentId == $experimentId and
        .contractSha256 == $contractSha and (.baselinePnpId | startswith($baseline)) and
        .baselineDriverVersion == $baselineVersion and
        .activeInfAfter == .activeInfBefore and .activeDriverChanged == false and
        .targetPnpId == $pnp and .targetDriverVersion == $version and
        .driverStoreInfSha256 == $infSha and .driverStoreCatalogSha256 == $catSha and
        .driverStoreKernelSha256 == $sysSha and .catalogSignerThumbprint == $signer and
        .testsigning == false and .nointegritychecks == false and
        .bcdChanged == false and .bcdAfterSha256 == .bcdBeforeSha256
    ' "$staged" >/dev/null || signed_consumer_production_die "per-VM staged receipt is invalid"

    if [[ "$VGPU_SIGNED_CONSUMER_STATE" == pending-validation ]]; then
        [[ "$(grep -Ec '^[[:space:]]*VGPU_SIGNED_CONSUMER_VALIDATED_RECEIPT_SHA256=' "$CONF")" == 0 ]] \
            || signed_consumer_production_die "pending state may not claim a validated receipt"
    else
        [[ "$(grep -Ec '^[[:space:]]*VGPU_SIGNED_CONSUMER_VALIDATED_RECEIPT_SHA256=' "$CONF")" == 1 &&
           "${VGPU_SIGNED_CONSUMER_VALIDATED_RECEIPT_SHA256:-}" =~ ^[0-9A-F]{64}$ ]] \
            || signed_consumer_production_die "validated state requires one validated digest"
        validated="$proof_dir/validated.json"
        signed_consumer_production_validate_file "$validated" \
            "$VGPU_SIGNED_CONSUMER_VALIDATED_RECEIPT_SHA256" "per-VM validated receipt"
        jq -e --argjson vmId "$VM_ID" --arg vmUuid "${VM_UUID,,}" \
            --arg experimentId "$VGPU_SIGNED_CONSUMER_EXPERIMENT_ID" \
            --arg contractSha "$VGPU_SIGNED_CONSUMER_CONTRACT_SHA256" \
            --arg gpuName "$SC_CANONICAL_GPU_NAME" --arg pnp "$SC_CANONICAL_TARGET_PNP" \
            --arg version "$SC_DRIVER_VERSION" --arg infSha "$SC_INF_SHA256" \
            --arg catSha "$SC_CATALOG_SHA256" --arg sysSha "$SC_KERNEL_SHA256" \
            --arg signer "$SC_CATALOG_SIGNER_THUMBPRINT" '
            .schemaVersion == 1 and .phase == "validated" and .result == "pass" and
            .vmId == $vmId and .vmUuid == $vmUuid and .experimentId == $experimentId and
            .contractSha256 == $contractSha and .displayCount == 1 and
            .gpuName == $gpuName and .exactHardwareId == $pnp and
            (.pnpDeviceId | startswith($pnp)) and .configManagerErrorCode == 0 and
            .driverVersion == $version and .activeInfSha256 == $infSha and
            .activeCatalogSha256 == $catSha and .driverStoreKernelSha256 == $sysSha and
            .loadedKernelSha256 == $sysSha and .activeCatalogSignerThumbprint == $signer and
            .testsigning == false and .nointegritychecks == false and
            .bcdChanged == false and .bcdAfterSha256 == .bcdBeforeSha256
        ' "$validated" >/dev/null || signed_consumer_production_die "per-VM validated receipt is invalid"
    fi
    SIGNED_CONSUMER_PRODUCTION_ACTIVE=1
}
ISO=""
EXTRA=""
VIEWER_ARGS=()
VNC_DISPLAY=":${VM_ID}"
DEFAULT_ISO="${DEFAULT_ISO:-}"
INSTALL_UNATTENDED="${INSTALL_UNATTENDED:-1}"
INSTALL_UNATTEND_TEMPLATE="${INSTALL_UNATTEND_TEMPLATE:-$here/autounattend/autounattend.xml}"
UNATTEND_ISO=""
TAME_GNOME="${TAME_GNOME:-auto}"
QEMU_SDL_WINDOWS_CURSOR="${QEMU_SDL_WINDOWS_CURSOR:-$VM_ASSET_DIR/aero_arrow.cur}"
QEMU_SDL_DISABLE_IBUS="${QEMU_SDL_DISABLE_IBUS:-1}"
QEMU_SDL_PRESENT_MODE="${QEMU_SDL_PRESENT_MODE:-fixed}"
QEMU_SDL_TARGET_FPS="${QEMU_SDL_TARGET_FPS:-60}"
QEMU_SDL_INPUT_POLL_MS="${QEMU_SDL_INPUT_POLL_MS:-2}"
QEMU_SDL_TITLE_FPS="${QEMU_SDL_TITLE_FPS:-auto}"
QEMU_SDL_CURSOR_MODE="${QEMU_SDL_CURSOR_MODE:-host}"
QEMU_SDL_ALLOW_HOST_DISPLAY_SLEEP="${QEMU_SDL_ALLOW_HOST_DISPLAY_SLEEP:-0}"
QEMU_SDL_GNOME_ANIMATIONS="${QEMU_SDL_GNOME_ANIMATIONS:-off}"
GUEST_NUMLOCK="${GUEST_NUMLOCK:-1}"
G11_USB_HID_LOW_LATENCY="${G11_USB_HID_LOW_LATENCY:-0}"
G11_CHIPSET_PRESENTATION="${G11_CHIPSET_PRESENTATION:-catalog}"
G11_HOST_BRIDGE_PRESENTATION="${G11_HOST_BRIDGE_PRESENTATION:-catalog}"

should_tame_gnome_super() {
    local mode=${TAME_GNOME,,}
    case "$mode" in
        1|yes|true|on) return 0 ;;
        0|no|false|off) return 1 ;;
    esac
    gnome_super_shortcuts_is_gnome && gnome_super_shortcuts_available
}

find_libdecor_cairo_plugin() {
    local candidate multiarch=""

    if command -v dpkg-architecture >/dev/null 2>&1; then
        multiarch=$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || true)
    fi
    for candidate in \
            "${multiarch:+/usr/lib/$multiarch/libdecor/plugins-1/libdecor-cairo.so}" \
            /usr/lib/libdecor/plugins-1/libdecor-cairo.so \
            /usr/lib64/libdecor/plugins-1/libdecor-cairo.so; do
        [[ -n "$candidate" && -f "$candidate" ]] || continue
        printf '%s\n' "$candidate"
        return 0
    done
    while IFS= read -r candidate; do
        [[ -f "$candidate" ]] || continue
        printf '%s\n' "$candidate"
        return 0
    done < <(find /usr/lib /usr/lib64 -maxdepth 6 -type f \
        -path '*/libdecor/plugins-1/libdecor-cairo.so' -print 2>/dev/null)
    return 1
}

sdl_session_likely_wayland() {
    case "${SDL_VIDEODRIVER:-}" in
        wayland) return 0 ;;
        ?*)      return 1 ;;
    esac
    [[ "${XDG_SESSION_TYPE:-}" == wayland && -n "${WAYLAND_DISPLAY:-}" ]]
}

configure_sdl_wayland_decor() {
    local cairo_plugin plugin_dir plugin_link unexpected

    sdl_session_likely_wayland || return 0
    [[ "$QEMU_SDL_TITLE_FPS" != 0 ]] || return 0

    if [[ -n "${LIBDECOR_PLUGIN_DIR:-}" ]]; then
        if [[ "$DRY_RUN" != 1 ]]; then
            echo "[start-vm] 保留显式 LIBDECOR_PLUGIN_DIR；标题 FPS 按 QEMU_SDL_TITLE_FPS=${QEMU_SDL_TITLE_FPS} 处理"
        fi
        return 0
    fi

    cairo_plugin=$(find_libdecor_cairo_plugin 2>/dev/null || true)
    if [[ -z "$cairo_plugin" ]]; then
        if [[ "$DRY_RUN" != 1 ]]; then
            if [[ "$QEMU_SDL_TITLE_FPS" == 1 ]]; then
                echo "[start-vm] WARN: 已显式开启 Wayland 实时标题，但未找到 Cairo libdecor；libdecor-gtk 可能重复输出 GDK monitor 告警" >&2
            else
                echo "[start-vm] SDL Wayland 未找到 Cairo libdecor；使用静态标题，避免 libdecor-gtk/GDK 日志风暴" >&2
            fi
            echo "[start-vm] 可选一键安装: ./deploy/host/install-g11-sdl-wayland-decor.sh" >&2
        fi
        return 0
    fi

    plugin_dir="$INSTANCE_RUN_DIR/libdecor-cairo"
    plugin_link="$plugin_dir/libdecor-cairo.so"
    if [[ "$DRY_RUN" != 1 ]]; then
        if [[ -e "$plugin_dir" && ! -d "$plugin_dir" ]]; then
            echo "[start-vm] libdecor 私有目录被非目录占用: $plugin_dir" >&2
            return 1
        fi
        mkdir -p -- "$plugin_dir"
        chmod 0700 -- "$plugin_dir"
        unexpected=$(find "$plugin_dir" -mindepth 1 -maxdepth 1 \
            ! -name libdecor-cairo.so -print -quit 2>/dev/null || true)
        if [[ -n "$unexpected" ]]; then
            echo "[start-vm] libdecor 私有目录含未知文件，拒绝加载: $unexpected" >&2
            return 1
        fi
        if [[ -e "$plugin_link" && ! -L "$plugin_link" ]]; then
            echo "[start-vm] libdecor Cairo 入口被普通文件占用: $plugin_link" >&2
            return 1
        fi
        ln -sfn -- "$cairo_plugin" "$plugin_link"
    fi
    export LIBDECOR_PLUGIN_DIR="$plugin_dir"
    if [[ "$QEMU_SDL_TITLE_FPS" == auto ]]; then
        QEMU_SDL_TITLE_FPS=1
        export QEMU_SDL_TITLE_FPS
    fi
    if [[ "$DRY_RUN" != 1 ]]; then
        echo "[start-vm] SDL Wayland 标题装饰：Cairo（实时 Content/Present，绕开 libdecor-gtk）"
    fi
}

# ivshmem 只是旧 guest relay 的传输通道。默认 native 路径不向
# guest 挂这个 PCI 设备；rdp/legacy-shmem 兼容模式仍默认 64 MiB。
IVSHMEM_SIZE_MB="${IVSHMEM_SIZE_MB:-}"
DISPLAY_WIDTH="${DISPLAY_WIDTH:-1920}"
DISPLAY_HEIGHT="${DISPLAY_HEIGHT:-1080}"
REPAIR_DISPLAY_VARS="${REPAIR_DISPLAY_VARS:-auto}"
DRY_RUN="${DRY_RUN:-0}"
PROXY="${PROXY:-0}"
CPU_ISOLATION="${CPU_ISOLATION:-}"
# 两项都是本次启动的宿主资源策略，不写入 vm.conf。CLI 省略时分别由
# CPU required 默认和 G-11 原有的低延迟内存预分配默认接管。
CPU_ISOLATION_CLI_SEEN=0
G11_MEMORY_PREALLOC=on
MEMORY_PREALLOC_CLI_SEEN=0
HOST_OOM_PROTECT="${HOST_OOM_PROTECT:-1}"
G11_HOST_PERFORMANCE="${G11_HOST_PERFORMANCE:-auto}"
G11_RTC_CLOCK="${G11_RTC_CLOCK:-vm}"
G11_TSC_POLICY="${G11_TSC_POLICY:-auto}"
QEMU_SERVICE_CPUS="${QEMU_SERVICE_CPUS:-0}"
HOST_RESERVE_CORES="${HOST_RESERVE_CORES:-auto}"
CPU_ISOLATION_QMP_TIMEOUT="${CPU_ISOLATION_QMP_TIMEOUT:-90}"
STREAM_OUTPUT="${STREAM_OUTPUT:-}"
DGAME_PREVIEW="${DGAME_PREVIEW:-auto}"
DGAME_PREVIEW_RATE="${DGAME_PREVIEW_RATE:-60}"
DGAME_PREVIEW_GPU="${DGAME_PREVIEW_GPU:-auto}"
STREAM_ROI="${STREAM_ROI:-}"
STREAM_RATE="${STREAM_RATE:-30}"
STREAM_ENCODER="${STREAM_ENCODER:-libx264}"
STREAM_BITRATE="${STREAM_BITRATE:-6M}"
STREAM_PRESET="${STREAM_PRESET:-veryfast}"
STREAM_GOP="${STREAM_GOP:-60}"
STREAM_CONTAINER="${STREAM_CONTAINER:-}"
STREAM_MODE="${STREAM_MODE:-auto}"
STREAM_START_TIMEOUT="${STREAM_START_TIMEOUT:-15}"
VLAN_ID_CLI_SEEN=0
STREAM_ENABLED=0
[[ -n "$STREAM_OUTPUT" ]] && STREAM_ENABLED=1
NATIVE_FULLSCREEN=0
VGPU_ROMBAR="${VGPU_ROMBAR:-}"
VGPU_ROMFILE="${VGPU_ROMFILE:-}"
VGPU_CONSOLE_INTERVAL_US="${VGPU_CONSOLE_INTERVAL_US:-16667}"
# 0=禁用 vGPU 帧率限制器（scanout 跟随 guest 渲染帧率），1=保持 profile
# 的 frlConfig，空=不改动。FRL 默认锁 60 FPS，与 QEMU 60Hz 的
# QUERY_GFX_PLANE 同频不同步会拍频，实测只能接住约一半的帧。
VGPU_FRAME_RATE_LIMITER="${VGPU_FRAME_RATE_LIMITER-}"
MONITOR_SYNC="${MONITOR_SYNC:-1}"
TPM_CLI_DISABLED=0
# 正常入口沿用旧 qemu-9.2.0 生产脚本的 Windows local-RTC 契约。
# 老 vm.conf 没有 RTC_CONTRACT 字段，也必须视为 localtime；只有明确写了
# RTC_CONTRACT=utc 的短期过渡配置才允许做一次 utc-compat 迁移救援。
RTC_MODE="${RTC_MODE:-${RTC_CONTRACT:-localtime}}"
VM_RTC_TZ="${VM_RTC_TZ:-Asia/Shanghai}"

require_cli_value() {
    local option=$1 remaining=$2

    ((remaining >= 2)) || {
        echo "$option 需要一个参数" >&2
        exit 2
    }
}

while (( $# > 0 )); do
    case "$1" in
        --install)
            MODE=install
            # 下一个参数如果不是 --开头就当作 ISO 路径，否则走默认
            if [[ $# -ge 2 && "$2" != --* ]]; then
                ISO="$2"
                shift 2
            else
                [[ -n "$DEFAULT_ISO" ]] || \
                    DEFAULT_ISO=$(vm_storage_iso_path win10.iso)
                ISO="$DEFAULT_ISO"
                shift
            fi ;;
        --manual-oobe|--interactive-oobe) INSTALL_UNATTENDED=0; shift ;;
        --unattended-oobe) INSTALL_UNATTENDED=1; shift ;;
        --install-media)
            require_cli_value "$1" "$#"
            (( INSTALL_MEDIA_CLI_SEEN == 0 )) || {
                echo "--install-media 只能指定一次" >&2
                exit 2
            }
            INSTALL_MEDIA_BACKEND=$2
            INSTALL_MEDIA_CLI_SEEN=1
            shift 2
            ;;
        --install-media=*)
            (( INSTALL_MEDIA_CLI_SEEN == 0 )) || {
                echo "--install-media 只能指定一次" >&2
                exit 2
            }
            INSTALL_MEDIA_BACKEND=${1#*=}
            [[ -n "$INSTALL_MEDIA_BACKEND" ]] || {
                echo "--install-media 需要 usb 或 ide" >&2
                exit 2
            }
            INSTALL_MEDIA_CLI_SEEN=1
            shift
            ;;
        --rdp)     MODE=rdp; shift ;;
        --legacy-shmem) MODE=rdp; shift ;;
        --native)  MODE=native; shift ;;
        --gtk)     MODE=vgpu-gtk; shift ;;
        --sdl)     MODE=vgpu-sdl; shift ;;
        --vgpu-gtk) MODE=vgpu-gtk; shift ;;
        --vgpu-sdl) MODE=vgpu-sdl; shift ;;
        --driver-install|--driver-install-sdl)
            MODE=driver-install-sdl
            shift
            ;;
        --driver-install-gtk)
            MODE=driver-install-gtk
            shift
            ;;
        --rescue|--rescue-sdl) MODE=rescue-sdl; shift ;;
        --rescue-gtk) MODE=rescue-gtk; shift ;;
        --no-gpu)  MODE=no-gpu; shift ;;
        --vnc)     VNC_DISPLAY="$2"; shift 2 ;;
        --rtc-utc-compat) RTC_MODE=utc-compat; shift ;;
        --no-spoof)        SPOOF_MODE=off; shift ;;    # 装 GRID 驱动 / 调试用
        --spoof)           SPOOF_MODE=A;   shift ;;    # PCI + name spoof（彻底）
        --spoof-name-only) SPOOF_MODE=B;   shift ;;    # 仅注册表 name spoof
        --spoof-mode)      SPOOF_MODE="$2"; shift 2 ;; # 直接指定 A/B/off
        --no-shmem) IVSHMEM_SIZE_MB=0; shift ;;     # 禁用 ivshmem 通道
        --shmem)    IVSHMEM_SIZE_MB="$2"; shift 2 ;; # 指定大小 (MB)
        --repair-display-vars) REPAIR_DISPLAY_VARS=force; shift ;;
        --no-repair-display-vars) REPAIR_DISPLAY_VARS=off; shift ;;
        --no-tpm) TPM=0; TPM_CLI_DISABLED=1; shift ;;
        --monitor-sync) MONITOR_SYNC=1; shift ;;
        --no-monitor-sync) MONITOR_SYNC=0; shift ;;
        --signed-consumer-probe)
            require_cli_value "$1" "$#"
            [[ "$SIGNED_CONSUMER_PROBE_AUTHORIZED" == 1 &&
               "$2" == "$SIGNED_CONSUMER_PROBE_EXPECTED_STAGE" ]] \
                || signed_consumer_probe_die \
                    "late stage no longer matches the one-shot authorization"
            SPOOF_MODE=A
            if [[ "$2" == outer+internal ]]; then
                VGPU_MDEV_INTERNAL_PCI_IDENTITY=1
            else
                VGPU_MDEV_INTERNAL_PCI_IDENTITY=0
            fi
            VGPU_MDEV_IDENTITY_MODE=required
            shift 2
            ;;
        # Authorization was decided by the pre-storage verifier from the same
        # immutable argv/config snapshot.  The full parser only consumes the
        # process-local flag; vm.conf/environment values cannot create it.
        --production-migration-source) shift ;;
        --proxy) PROXY=1; shift ;;
        --no-proxy) PROXY=0; shift ;;
        --cpu-isolate=*)
            (( CPU_ISOLATION_CLI_SEEN == 0 )) || {
                echo "--cpu-isolate 只能指定一次" >&2
                exit 2
            }
            case "${1#*=}" in
                true) CPU_ISOLATION=required ;;
                false) CPU_ISOLATION=off ;;
                *) echo "--cpu-isolate 只接受 true 或 false" >&2; exit 2 ;;
            esac
            CPU_ISOLATION_CLI_SEEN=1
            shift
            ;;
        --memory-prealloc=*)
            (( MEMORY_PREALLOC_CLI_SEEN == 0 )) || {
                echo "--memory-prealloc 只能指定一次" >&2
                exit 2
            }
            case "${1#*=}" in
                true) G11_MEMORY_PREALLOC=on ;;
                false) G11_MEMORY_PREALLOC=off ;;
                *) echo "--memory-prealloc 只接受 true 或 false" >&2; exit 2 ;;
            esac
            MEMORY_PREALLOC_CLI_SEEN=1
            shift
            ;;
        --host-performance) G11_HOST_PERFORMANCE=required; shift ;;
        --no-host-performance) G11_HOST_PERFORMANCE=off; shift ;;
        --svc-cpus)
            require_cli_value "$1" "$#"
            QEMU_SERVICE_CPUS="$2"; shift 2 ;;
        --dgame-preview) DGAME_PREVIEW=on; shift ;;
        --no-dgame-preview) DGAME_PREVIEW=off; shift ;;
        --dgame-preview-rate)
            require_cli_value "$1" "$#"
            DGAME_PREVIEW_RATE="$2"; shift 2 ;;
        --dgame-preview-gpu) DGAME_PREVIEW_GPU=on; shift ;;
        --no-dgame-preview-gpu) DGAME_PREVIEW_GPU=off; shift ;;
        --stream|--stream-output)
            require_cli_value "$1" "$#"
            STREAM_OUTPUT="$2"; STREAM_ENABLED=1; shift 2 ;;
        --stream-roi)
            require_cli_value "$1" "$#"; STREAM_ROI="$2"; shift 2 ;;
        --stream-rate)
            require_cli_value "$1" "$#"; STREAM_RATE="$2"; shift 2 ;;
        --stream-encoder)
            require_cli_value "$1" "$#"; STREAM_ENCODER="$2"; shift 2 ;;
        --stream-bitrate)
            require_cli_value "$1" "$#"; STREAM_BITRATE="$2"; shift 2 ;;
        --stream-preset)
            require_cli_value "$1" "$#"; STREAM_PRESET="$2"; shift 2 ;;
        --stream-gop)
            require_cli_value "$1" "$#"; STREAM_GOP="$2"; shift 2 ;;
        --stream-container)
            require_cli_value "$1" "$#"; STREAM_CONTAINER="$2"; shift 2 ;;
        --stream-mode)
            require_cli_value "$1" "$#"; STREAM_MODE="$2"; shift 2 ;;
        --stream-start-timeout)
            require_cli_value "$1" "$#"; STREAM_START_TIMEOUT="$2"; shift 2 ;;
        --vlan-id)
            require_cli_value "$1" "$#"
            (( VLAN_ID_CLI_SEEN == 0 )) || {
                echo "--vlan-id 只能指定一次" >&2
                exit 2
            }
            [[ -n "$2" ]] || { echo "--vlan-id 需要一个 VLAN ID" >&2; exit 2; }
            VLAN_ID=$2
            VLAN_ID_CLI_SEEN=1
            shift 2
            ;;
        --vlan-id=*)
            (( VLAN_ID_CLI_SEEN == 0 )) || {
                echo "--vlan-id 只能指定一次" >&2
                exit 2
            }
            VLAN_ID=${1#*=}
            [[ -n "$VLAN_ID" ]] || { echo "--vlan-id 需要一个 VLAN ID" >&2; exit 2; }
            VLAN_ID_CLI_SEEN=1
            shift
            ;;
        --no-stream) STREAM_ENABLED=0; STREAM_OUTPUT=""; shift ;;
        --numlock) GUEST_NUMLOCK=1; shift ;;
        --no-numlock) GUEST_NUMLOCK=0; shift ;;
        --low-latency-input) G11_USB_HID_LOW_LATENCY=1; shift ;;
        --no-low-latency-input) G11_USB_HID_LOW_LATENCY=0; shift ;;
        --guest-cursor) QEMU_SDL_CURSOR_MODE=guest; shift ;;
        --auto-cursor) QEMU_SDL_CURSOR_MODE=auto; shift ;;
        --host-cursor) QEMU_SDL_CURSOR_MODE=host; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --tame-gnome) TAME_GNOME=1; shift ;;
        --no-tame-gnome) TAME_GNOME=0; shift ;;
        --fullscreen) NATIVE_FULLSCREEN=1; VIEWER_ARGS+=("$1"); shift ;;
        --windowed) NATIVE_FULLSCREEN=0; VIEWER_ARGS+=("$1"); shift ;;
        --width) DISPLAY_WIDTH="$2"; VIEWER_ARGS+=("$1" "$2"); shift 2 ;;
        --height) DISPLAY_HEIGHT="$2"; VIEWER_ARGS+=("$1" "$2"); shift 2 ;;
        --extra)   EXTRA="$2"; shift 2 ;;
        *) echo "未知参数: $1" >&2; exit 2 ;;
    esac
done

case "$MODE" in
    driver-install-sdl|driver-install-gtk)
        ((EARLY_DRIVER_INSTALL_REQUESTED == 1)) || {
            echo "[start-vm] driver-install early/full 解析状态不一致" >&2
            exit 2
        }
        # This is a tightly scoped production-signed GRID install topology, not
        # a general alternate display mode.  The mdev remains present for PnP,
        # while every consumer/internal identity override is disabled.
        SPOOF_MODE=off
        VGPU_MDEV_INTERNAL_PCI_IDENTITY=0
        VGPU_ROMBAR=0
        VGPU_ROMFILE=""
        ;;
    *)
        ((EARLY_DRIVER_INSTALL_REQUESTED == 0)) || {
            echo "[start-vm] --driver-install 不能与其他显示模式组合" >&2
            exit 2
        }
        ;;
esac

case "$GUEST_NUMLOCK" in
    0|1) ;;
    *) echo "GUEST_NUMLOCK 必须是 0 或 1: $GUEST_NUMLOCK" >&2; exit 2 ;;
esac
case "$G11_USB_HID_LOW_LATENCY" in
    0|1) ;;
    *)
        echo "G11_USB_HID_LOW_LATENCY 必须是 0 或 1: $G11_USB_HID_LOW_LATENCY" >&2
        exit 2
        ;;
esac
QEMU_SDL_CURSOR_MODE=${QEMU_SDL_CURSOR_MODE,,}
case "$QEMU_SDL_CURSOR_MODE" in
    auto|host|guest) ;;
    *)
        echo "QEMU_SDL_CURSOR_MODE 必须是 auto、host 或 guest: $QEMU_SDL_CURSOR_MODE" >&2
        exit 2
        ;;
esac

INSTALL_MEDIA_BACKEND=${INSTALL_MEDIA_BACKEND,,}
case "$INSTALL_MEDIA_BACKEND" in
    usb|usb-cdrom) INSTALL_MEDIA_BACKEND=usb ;;
    ide|ide-cdrom) INSTALL_MEDIA_BACKEND=ide ;;
    *)
        echo "INSTALL_MEDIA_BACKEND/--install-media 只支持 usb 或 ide: ${INSTALL_MEDIA_BACKEND}" >&2
        exit 2
        ;;
esac
if (( INSTALL_MEDIA_CLI_SEEN )) && [[ "$MODE" != install ]]; then
    echo "--install-media 只能与 --install 一起使用" >&2
    exit 2
fi

case "$SPOOF_MODE" in
    A|B|off) ;;
    *) echo "SPOOF_MODE 必须是 A、B 或 off: $SPOOF_MODE" >&2; exit 2 ;;
esac

signed_consumer_production_validate

# Internal NVIDIA vGPU identity is deliberately a second, independent opt-in
# on top of SPOOF_MODE=A.  The outer QEMU PCI tuple is useful for the patched
# INF, while changing vdev_id/pdev_id can independently affect RM/licensing.
# Keep it off unless a single-variable experiment explicitly requests it.
if [[ ! -v VGPU_MDEV_INTERNAL_PCI_IDENTITY ]]; then
    VGPU_MDEV_INTERNAL_PCI_IDENTITY=0
fi
case "$VGPU_MDEV_INTERNAL_PCI_IDENTITY" in
    0|1) ;;
    *)
        echo "VGPU_MDEV_INTERNAL_PCI_IDENTITY 必须是 0 或 1: $VGPU_MDEV_INTERNAL_PCI_IDENTITY" >&2
        exit 2
        ;;
esac

VGPU_MDEV_INTERNAL_PCI_ACTIVE=0
VGPU_MDEV_INTERNAL_VDEV_ID=""
VGPU_MDEV_INTERNAL_PDEV_ID=""
if [[ "$VGPU_MDEV_INTERNAL_PCI_IDENTITY" == 1 && "$SPOOF_MODE" == A ]]; then
    if [[ ! "${GPU_PCI_DID:-}" =~ ^0[xX][0-9A-Fa-f]{4}$ ||
          ! "${GPU_SUB_DID:-}" =~ ^0[xX][0-9A-Fa-f]{4}$ ]]; then
        echo "内部 PCI identity 要求 16-bit GPU_PCI_DID/GPU_SUB_DID: ${GPU_PCI_DID:-<missing>}/${GPU_SUB_DID:-<missing>}" >&2
        exit 2
    fi
    internal_did_hex=${GPU_PCI_DID:2}
    internal_subdid_hex=${GPU_SUB_DID:2}
    internal_did_value=$((16#$internal_did_hex))
    internal_subdid_value=$((16#$internal_subdid_hex))
    printf -v VGPU_MDEV_INTERNAL_VDEV_ID '0x%08X' \
        "$(( (internal_did_value << 16) | internal_subdid_value ))"
    printf -v VGPU_MDEV_INTERNAL_PDEV_ID '0x%04X' "$internal_did_value"
    VGPU_MDEV_INTERNAL_PCI_ACTIVE=1
    unset internal_did_hex internal_subdid_hex \
        internal_did_value internal_subdid_value
fi
if [[ "$SIGNED_CONSUMER_PRODUCTION_ACTIVE" == 1 &&
      "$VGPU_MDEV_INTERNAL_PCI_ACTIVE" != 0 ]]; then
    signed_consumer_production_die \
        "outer-only production contract activated an internal PCI override"
fi

# Unlike the consumer PCI identity, the host-side vGPU frame-rate limiter is
# still active even when NVIDIA Control Panel no longer exposes a licensing
# page.  Keep this unset by default and scope an explicit override to the
# stable per-mdev UUID instead of the shared nvidia-257 profile.
VGPU_MDEV_FRL_OVERRIDE_ACTIVE=0
if [[ -v VGPU_MDEV_FRL_ENABLED ]]; then
    case "$VGPU_MDEV_FRL_ENABLED" in
        0|1) ;;
        *)
            echo "VGPU_MDEV_FRL_ENABLED 必须是 0 或 1: $VGPU_MDEV_FRL_ENABLED" >&2
            exit 2
            ;;
    esac
    # A legacy FRL marker must not leak into the supported B/off migration
    # paths.  Only A ever requested an override; A itself is rejected below.
    if [[ "$SPOOF_MODE" == A ]]; then
        VGPU_MDEV_FRL_OVERRIDE_ACTIVE=1
    fi
fi

if [[ "$SIGNED_CONSUMER_PROBE_AUTHORIZED" == 1 ]]; then
    [[ "$SPOOF_MODE" == A &&
       "${VM_UUID,,}" == "$SIGNED_CONSUMER_PROBE_EXPECTED_UUID" &&
       "${GPU_PROFILE:-}" == "$SIGNED_CONSUMER_PROBE_EXPECTED_PROFILE" &&
       "${GPU_NAME:-}" == "$SIGNED_CONSUMER_PROBE_EXPECTED_GPU_NAME" &&
       "${GPU_PCI_VID,,}" == "${SIGNED_CONSUMER_PROBE_EXPECTED_PCI_VID,,}" &&
       "${GPU_PCI_DID,,}" == "${SIGNED_CONSUMER_PROBE_EXPECTED_PCI_DID,,}" &&
       "${GPU_SUB_VID,,}" == "${SIGNED_CONSUMER_PROBE_EXPECTED_SUB_VID,,}" &&
       "${GPU_SUB_DID,,}" == "${SIGNED_CONSUMER_PROBE_EXPECTED_SUB_DID,,}" &&
       "${VGPU_RESOURCE_PROFILE:-}" == "$SIGNED_CONSUMER_PROBE_EXPECTED_RESOURCE_PROFILE" &&
       "${VGPU_RESOURCE_FB_MB:-}" == "$SIGNED_CONSUMER_PROBE_EXPECTED_FB_MB" &&
       "${VGPU_IDENTITY_TARGET:-}" == name-only ]] \
        || signed_consumer_probe_die \
            "sourced VM identity no longer matches the attested canonical B clone"
    case "$MODE" in
        native|vgpu-sdl|vgpu-gtk) ;;
        *)
            signed_consumer_probe_die \
                "only the normal native vGPU display is allowed"
            ;;
    esac
    [[ "$MONITOR_SYNC" == 0 && -z "$EXTRA" ]] \
        || signed_consumer_probe_die \
            "offline guest writes and arbitrary QEMU --extra are forbidden"
    (( VGPU_MDEV_FRL_OVERRIDE_ACTIVE == 0 )) \
        || signed_consumer_probe_die \
            "FRL override is outside this probe"
    case "$SIGNED_CONSUMER_PROBE_EXPECTED_STAGE" in
        outer-only)
            (( VGPU_MDEV_INTERNAL_PCI_ACTIVE == 0 )) \
                || signed_consumer_probe_die \
                    "outer-only unexpectedly enabled internal PCI identity"
            ;;
        outer+internal)
            (( VGPU_MDEV_INTERNAL_PCI_ACTIVE == 1 )) &&
                [[ "${VGPU_MDEV_INTERNAL_VDEV_ID,,}" == \
                       "${SIGNED_CONSUMER_PROBE_EXPECTED_INTERNAL_PCI,,}" &&
                   "${VGPU_MDEV_INTERNAL_PDEV_ID,,}" == \
                       "${SIGNED_CONSUMER_PROBE_EXPECTED_INTERNAL_PDEV,,}" ]] \
                || signed_consumer_probe_die \
                    "internal stage differs from the attested canonical profile"
            ;;
        *) signed_consumer_probe_die "authorized stage is corrupt" ;;
    esac
    CURRENT_SIGNED_CONSUMER_CONFIG_SHA=$(start_vm_sha256_upper "$CONF") \
        || signed_consumer_probe_die "could not re-read vm.conf"
    [[ "$CURRENT_SIGNED_CONSUMER_CONFIG_SHA" == \
       "$SIGNED_CONSUMER_PROBE_EXPECTED_CONFIG_SHA256" ]] \
        || signed_consumer_probe_die \
            "vm.conf changed after one-shot authorization"
    unset CURRENT_SIGNED_CONSUMER_CONFIG_SHA
elif [[ "$PRODUCTION_MIGRATION_SOURCE_AUTHORIZED" == 1 ]]; then
    [[ "$SPOOF_MODE" == A ]] \
        || production_migration_source_die \
            "the authorized source invocation may not switch away from A"
    case "$MODE" in
        native|vgpu-sdl|vgpu-gtk) ;;
        *)
            production_migration_source_die \
                "only the normal native vGPU display may boot the A source"
            ;;
    esac
    [[ "${VM_UUID,,}" == "$PRODUCTION_MIGRATION_EXPECTED_UUID" &&
       "${GPU_PROFILE:-}" == "$PRODUCTION_MIGRATION_EXPECTED_PROFILE" &&
       "${GPU_NAME:-}" == "$PRODUCTION_MIGRATION_EXPECTED_GPU_NAME" ]] \
        || production_migration_source_die \
            "sourced VM UUID/profile/name no longer match host-state"
    CURRENT_PRODUCTION_MIGRATION_CONFIG_SHA=$(
        start_vm_sha256_upper "$CONF"
    ) || production_migration_source_die \
        "could not re-read the source config"
    [[ "$CURRENT_PRODUCTION_MIGRATION_CONFIG_SHA" == \
       "$PRODUCTION_MIGRATION_EXPECTED_CONFIG_SHA256" ]] \
        || production_migration_source_die \
            "vm.conf changed after source authorization"
    unset CURRENT_PRODUCTION_MIGRATION_CONFIG_SHA
elif [[ "$SPOOF_MODE" == A ]]; then
    strict_a_start_disabled
fi

case "$RTC_MODE" in
    localtime) ;;
    # Only an explicit RTC_CONTRACT=utc reaches this branch.  Missing fields
    # belong to the legacy local-RTC launcher and default to localtime above.
    utc) ;;
    utc-compat)
        case "$MODE" in
            rescue-sdl|rescue-gtk|no-gpu) ;;
            *)
                echo "--rtc-utc-compat 只允许用于不挂 vGPU 的一次性救援模式" >&2
                exit 2
                ;;
        esac
        ;;
    *) echo "RTC_MODE 必须是 localtime、utc 或 utc-compat: $RTC_MODE" >&2; exit 2 ;;
esac

case "$MODE" in
    native)
        case "${GFX_BACKEND,,}" in
            sdl|gtk) MODE="vgpu-${GFX_BACKEND,,}" ;;
            *) echo "未知 GFX_BACKEND=${GFX_BACKEND} (sdl|gtk)" >&2; exit 2 ;;
        esac
        ;;
esac

case "${DGAME_PREVIEW,,}" in
    auto)
        case "$MODE" in
            vgpu-sdl|vgpu-gtk) DGAME_PREVIEW_ENABLED=1 ;;
            *)                 DGAME_PREVIEW_ENABLED=0 ;;
        esac
        ;;
    1|yes|true|on) DGAME_PREVIEW_ENABLED=1 ;;
    0|no|false|off) DGAME_PREVIEW_ENABLED=0 ;;
    *)
        echo "DGAME_PREVIEW 必须是 auto、on 或 off: $DGAME_PREVIEW" >&2
        exit 2
        ;;
esac
if ((DGAME_PREVIEW_ENABLED)); then
    case "$MODE" in
        vgpu-sdl|vgpu-gtk) ;;
        *)
            echo "--dgame-preview 仅支持 G-11 native vGPU SDL/GTK 模式" >&2
            exit 2
            ;;
    esac
fi
case "${DGAME_PREVIEW_GPU,,}" in
    auto|1|yes|true|on) DGAME_PREVIEW_GPU_ENABLED=1 ;;
    0|no|false|off)     DGAME_PREVIEW_GPU_ENABLED=0 ;;
    *)
        echo "DGAME_PREVIEW_GPU 必须是 auto、on 或 off:" \
             "$DGAME_PREVIEW_GPU" >&2
        exit 2
        ;;
esac
if ((!DGAME_PREVIEW_ENABLED)); then
    DGAME_PREVIEW_GPU_ENABLED=0
fi

stream_config_error() {
    echo "[start-vm] 推流参数错误: $*" >&2
    exit 2
}

stream_validate_uint() {
    local label=$1 value=$2 min=$3 max=$4

    [[ "$value" =~ ^[0-9]+$ ]] ||
        stream_config_error "$label 必须是 ${min}..${max} 的整数"
    ((10#$value >= min && 10#$value <= max)) ||
        stream_config_error "$label 超出范围 ${min}..${max}"
}

stream_validate_token() {
    local label=$1 value=$2

    [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]] ||
        stream_config_error "$label 只能包含字母、数字、点、下划线和连字符"
}

stream_validate_output() {
    local output=$1 lower authority hostport host ch i

    (( ${#output} > 0 && ${#output} <= 1024 )) ||
        stream_config_error "output 不能为空或超过 1024 字节"
    for ((i = 0; i < ${#output}; i++)); do
        ch=${output:i:1}
        case "$ch" in
            [A-Za-z0-9]|.|_|-|~|:|/|'?'|'#'|@|'!'|+|,|%|=|'&'|'['|']')
                ;;
            *) stream_config_error "output 含空白、控制字符或不安全字符" ;;
        esac
    done

    lower=${output,,}
    if [[ "$output" == /* ]]; then
        [[ "$output" != "/" ]] ||
            stream_config_error "本地 output 不能是根目录"
        [[ ! -e "$output" && ! -L "$output" ]] ||
            stream_config_error "本地 output 已存在；拒绝覆盖"
        return
    fi
    case "$lower" in
        rtmp://*|rtmps://*|srt://*|udp://*|rtp://*) ;;
        *) stream_config_error "output 必须是显式网络 URL 或绝对本地路径" ;;
    esac
    if [[ "$lower" =~ (^|[\?\&])(listen(=(1|true))?|mode=listener)($|[\&\#]) ]]; then
        stream_config_error "禁止 listener 模式；推流只能主动连接显式目标"
    fi
    authority=${output#*://}
    authority=${authority%%/*}
    authority=${authority%%\?*}
    [[ -n "$authority" ]] ||
        stream_config_error "output URL 缺少目标主机"
    hostport=${authority##*@}
    if [[ "$hostport" == \[*\]* ]]; then
        host=${hostport#\[}
        host=${host%%\]*}
    else
        host=${hostport%%:*}
    fi
    case "${host,,}" in
        ""|"*"|"0.0.0.0"|"::"|"[::]")
            stream_config_error "禁止 wildcard/listener 目标主机"
            ;;
    esac
}

stream_validate_uint "DGame preview rate" "$DGAME_PREVIEW_RATE" 1 240

STREAM_ROI_X=""
STREAM_ROI_Y=""
STREAM_ROI_W=""
STREAM_ROI_H=""
if ((STREAM_ENABLED)); then
    case "$MODE" in
        vgpu-sdl|vgpu-gtk) ;;
        *)
            stream_config_error "--stream 仅支持 G-11 native vGPU SDL/GTK 模式"
            ;;
    esac
    stream_validate_output "$STREAM_OUTPUT"
    stream_validate_uint "rate" "$STREAM_RATE" 1 240
    stream_validate_token "encoder" "$STREAM_ENCODER"
    [[ "$STREAM_BITRATE" =~ ^[1-9][0-9]{0,8}[KkMmGg]?$ ]] ||
        stream_config_error "bitrate 格式非法"
    stream_validate_token "preset" "$STREAM_PRESET"
    stream_validate_uint "gop" "$STREAM_GOP" 1 1000
    [[ -z "$STREAM_CONTAINER" ]] ||
        stream_validate_token "container" "$STREAM_CONTAINER"
    STREAM_MODE=${STREAM_MODE,,}
    case "$STREAM_MODE" in
        auto|shm) ;;
        gpu)
            stream_config_error \
                "R535 VFIO display REGION 不导出 DMA-BUF；严格 GPU 零拷贝模式不可用，请用 shm/auto"
            ;;
        *) stream_config_error "mode 必须是 auto、shm 或 gpu" ;;
    esac
    stream_validate_uint "start-timeout" "$STREAM_START_TIMEOUT" 1 60
    if [[ -n "$STREAM_ROI" ]]; then
        IFS=, read -r STREAM_ROI_X STREAM_ROI_Y STREAM_ROI_W \
            STREAM_ROI_H stream_roi_extra <<<"$STREAM_ROI"
        [[ -z "${stream_roi_extra:-}" && -n "$STREAM_ROI_H" ]] ||
            stream_config_error "ROI 必须是 X,Y,W,H"
        stream_validate_uint "ROI X" "$STREAM_ROI_X" 0 16383
        stream_validate_uint "ROI Y" "$STREAM_ROI_Y" 0 16383
        stream_validate_uint "ROI W" "$STREAM_ROI_W" 1 16384
        stream_validate_uint "ROI H" "$STREAM_ROI_H" 1 16384
        ((10#$STREAM_ROI_X + 10#$STREAM_ROI_W <= 16384 &&
          10#$STREAM_ROI_Y + 10#$STREAM_ROI_H <= 16384)) ||
            stream_config_error "ROI 坐标和尺寸不能超过 16384x16384"
        unset stream_roi_extra
    fi
fi

# The reusable guest finisher has no per-VM data embedded in it.  During its
# one rescue boot only, pass the configured target through an SMBIOS OEM
# string.  Capture the caller value before sourcing vm.conf so a persistent
# config can neither inject this channel nor make it leak into normal boots.
VGPU_GUEST_FINISH_TARGET=$VGPU_GUEST_FINISH_TARGET_ENV
if [[ -n "$VGPU_GUEST_FINISH_TARGET" ]]; then
    case "$MODE" in
        rescue-sdl|rescue-gtk) ;;
        *)
            echo "VGPU_GUEST_FINISH_TARGET 只允许用于 rescue-sdl/gtk" >&2
            exit 2
            ;;
    esac
    guest_finish_gpu_name_re='^[A-Za-z0-9][A-Za-z0-9._+() -]{0,30}$'
    guest_finish_gpu_name_lower=${VGPU_GUEST_FINISH_TARGET,,}
    [[ "$VGPU_GUEST_FINISH_TARGET" =~ $guest_finish_gpu_name_re &&
       "$VGPU_GUEST_FINISH_TARGET" == NVIDIA\ * &&
       ${#VGPU_GUEST_FINISH_TARGET} -ge 8 &&
       "$VGPU_GUEST_FINISH_TARGET" != *' ' &&
       "${VGPU_GUEST_FINISH_TARGET:7:1}" =~ [A-Za-z0-9] &&
       "$guest_finish_gpu_name_lower" != *grid* &&
       "$guest_finish_gpu_name_lower" != *rtx6000* ]] || {
        echo "VGPU_GUEST_FINISH_TARGET 必须是安全的 NVIDIA 消费卡名称（8..31 位，拒绝 GRID/RTX6000）" >&2
        exit 2
    }
    unset guest_finish_gpu_name_re guest_finish_gpu_name_lower
fi

# A portable GPU-Z/profile EXE is deliberately not bound to one VM.  For B
# mode it still needs an authoritative way to distinguish the three consumer
# identities, because every one of them retains the same native DEV_1E30 PnP
# endpoint.  Publish the already validated host intent as one read-only SMBIOS
# Type 11 string.  The guest verifies its own SMBIOS UUID, the complete catalog
# digest, PnP tuple and driver version before making any persistent change.
#
# This is automatic on every B/native start; it is not a second host-side
# commit step.  A/off are intentionally omitted so the portable guest tool
# fails closed on legacy or disabled identity paths.
VGPU_PORTABLE_PROFILE_CLAIM=""
if [[ "$SPOOF_MODE" == B ]]; then
    VGPU_PROFILE_CATALOG_SHA256=$(vgpu_profile_catalog_sha256)
    [[ "$VGPU_PROFILE_CATALOG_SHA256" =~ ^[0-9A-F]{64}$ ]] || {
        echo "[start-vm] 无法计算 portable vGPU profile catalog 摘要" >&2
        exit 1
    }
    VGPU_PORTABLE_PROFILE_CLAIM="G11_VGPU_PROFILE_V1|${GPU_PROFILE}|${VM_UUID,,}|${VGPU_PROFILE_CATALOG_SHA256}|10DE:1E30|31.0.15.3833"
fi

if [[ -z "$VGPU_ROMBAR" ]]; then
    # native 用 ramfb 提供固件画面，不向 OVMF 暴露 NVIDIA ROM，避免 EFI
    # GOP 半初始化；Windows GRID 驱动已实测可直接接管。旧模式保持 auto。
    [[ "$MODE" == vgpu-gtk || "$MODE" == vgpu-sdl ||
       "$MODE" == driver-install-gtk || "$MODE" == driver-install-sdl ]] && \
        VGPU_ROMBAR=0 || VGPU_ROMBAR=auto
fi

[[ "$DISPLAY_WIDTH" =~ ^[1-9][0-9]*$ ]] || {
    echo "--width/DISPLAY_WIDTH 必须是正整数" >&2; exit 2;
}
[[ "$DISPLAY_HEIGHT" =~ ^[1-9][0-9]*$ ]] || {
    echo "--height/DISPLAY_HEIGHT 必须是正整数" >&2; exit 2;
}
[[ "$DRY_RUN" == 0 || "$DRY_RUN" == 1 ]] || {
    echo "DRY_RUN 必须是 0 或 1" >&2; exit 2;
}
: "${BR0:=br0}"
: "${G11_BRIDGE_CONFIG:=/etc/qemu/g11-bridge.conf}"
: "${G11_BRIDGE_HELPER:=/usr/local/libexec/qemu-g11-bridge-helper}"
VLAN_TAP_IF=""
G11_VLAN_RUNTIME_MARKER="$(g11_vlan_marker_path "$VM_ID")"
if [[ -n "$VLAN_ID" ]]; then
    VLAN_ID="$(vlan_validate_id "$VLAN_ID")" || {
        echo "VLAN_ID/--vlan-id 必须是 1..4094 的十进制整数" >&2
        exit 2
    }
    [[ "$BR0" == br0 ]] || {
        echo "显式 VLAN 固定使用 BR0=br0；当前为 $BR0" >&2
        exit 2
    }
    VLAN_TAP_IF="$(vlan_tap_name "$VM_ID")" || {
        echo "vm${VM_ID} 无法生成合法 VLAN TAP 名称" >&2
        exit 2
    }
fi
if [[ "$DRY_RUN" != 1 ]]; then
    if [[ -n "$VLAN_ID" || "${BRIDGE_UPLINK_CHECK:-required}" != off ]]; then
        g11_network_maintenance_lock_shared \
            "${G11_NETWORK_LOCK:-/run/qemu-g11-network.lock}" || exit $?
    fi
    if g11_vlan_marker_status "$G11_VLAN_RUNTIME_MARKER"; then
        marker_status=0
    else
        marker_status=$?
    fi
    if (( marker_status == 2 )); then
        echo "[start-vm] VLAN runtime marker 类型不安全: $G11_VLAN_RUNTIME_MARKER" >&2
        exit 1
    fi
    if [[ -n "$VLAN_ID" ]]; then
        g11_vlan_preflight "$VM_ID" "$VLAN_ID" "$VLAN_TAP_IF" || exit $?
    else
        if (( marker_status == 0 )) \
                || ip link show dev "$(vlan_tap_name "$VM_ID")" >/dev/null 2>&1; then
            echo "[start-vm] 清理 vm${VM_ID} 上次遗留的 VLAN runtime..."
            g11_vlan_cleanup_instance "$VM_ID" 1 || exit $?
            g11_vlan_marker_clear "$G11_VLAN_RUNTIME_MARKER" || exit $?
        fi
        g11_bridge_uplink_preflight \
            "$BR0" "$G11_BRIDGE_CONFIG" \
            "${G11_BRIDGE_SYS_CLASS_NET:-/sys/class/net}" \
            "$G11_BRIDGE_HELPER" || exit $?
    fi
    unset marker_status
fi
[[ "$PROXY" == 0 || "$PROXY" == 1 ]] || {
    echo "PROXY 必须是 0 或 1" >&2; exit 2;
}
cpu_isolation_normalize_mode || {
    echo "CPU_ISOLATION 必须是 auto、required 或 off" >&2; exit 2;
}
[[ "$QEMU_SERVICE_CPUS" == auto ||
   ( "$QEMU_SERVICE_CPUS" =~ ^[0-9]+$ && "$QEMU_SERVICE_CPUS" -le 64 ) ]] || {
    echo "QEMU_SERVICE_CPUS/--svc-cpus 必须是 auto 或 0..64" >&2; exit 2;
}
[[ "$HOST_RESERVE_CORES" == auto || "$HOST_RESERVE_CORES" =~ ^[0-9]+$ ]] || {
    echo "HOST_RESERVE_CORES 必须是 auto 或非负整数" >&2; exit 2;
}
[[ "$CPU_ISOLATION_QMP_TIMEOUT" =~ ^[1-9][0-9]*$ &&
   "$CPU_ISOLATION_QMP_TIMEOUT" -le 300 ]] || {
    echo "CPU_ISOLATION_QMP_TIMEOUT 必须是 1..300 秒" >&2; exit 2;
}
cpu_isolation_ensure_ready || {
    echo "[start-vm] 默认 required CPU 隔离准备失败；VM 未启动" >&2
    exit 1
}
g11_host_performance_normalize_mode || {
    echo "G11_HOST_PERFORMANCE 必须是 auto、required 或 off" >&2
    exit 2
}
case "${G11_RTC_CLOCK,,}" in
    vm|host) G11_RTC_CLOCK=${G11_RTC_CLOCK,,} ;;
    *) echo "G11_RTC_CLOCK 必须是 vm 或 host" >&2; exit 2 ;;
esac
case "${G11_TSC_POLICY,,}" in
    auto|profile|host|omit) G11_TSC_POLICY=${G11_TSC_POLICY,,} ;;
    *) echo "G11_TSC_POLICY 必须是 auto、profile、host 或 omit" >&2; exit 2 ;;
esac
[[ "$HOST_OOM_PROTECT" == 0 || "$HOST_OOM_PROTECT" == 1 ]] || {
    echo "HOST_OOM_PROTECT 必须是 0 或 1" >&2; exit 2;
}
[[ "$INSTALL_UNATTENDED" == 0 || "$INSTALL_UNATTENDED" == 1 ]] || {
    echo "INSTALL_UNATTENDED 必须是 0 或 1" >&2; exit 2;
}
[[ "$MONITOR_SYNC" == 0 || "$MONITOR_SYNC" == 1 ]] || {
    echo "MONITOR_SYNC 必须是 0 或 1" >&2; exit 2;
}
G11_INIT_REQUIRED="$SELECTED_VM_DIR/.g11-init-required"
G11_INIT_ISO=""
G11_INIT_CONTRACT_ID=""
if [[ -e "$G11_INIT_REQUIRED" || -L "$G11_INIT_REQUIRED" ]]; then
    [[ -f "$G11_INIT_REQUIRED" && ! -L "$G11_INIT_REQUIRED" ]] || {
        echo "[start-vm] G-11 初始化标记类型不安全，拒绝启动: $G11_INIT_REQUIRED" >&2
        exit 1
    }
    CONF_UID=$(stat -c %u -- "$CONF")
    [[ "$(stat -c '%a:%u:%h' -- "$G11_INIT_REQUIRED")" == "600:${CONF_UID}:1" ]] || {
        echo "[start-vm] G-11 初始化标记权限、owner 或链接数不安全" >&2
        exit 1
    }
    jq -e \
        --arg vmUuid "${VM_UUID,,}" \
        --arg gpuProfile "$GPU_PROFILE" \
        --arg monitorProfile "$MONITOR_PROFILE" \
        --arg sourceConfigSha256 "$(start_vm_sha256_upper "$CONF")" '
        (keys | sort) == [
            "baseName", "catalogSha256", "createdUtc", "gpuProfile",
            "monitorProfile", "schemaVersion", "sourceConfigSha256", "state",
            "systemNvapiContractId", "systemNvapiIsoFile",
            "systemNvapiIsoSha256", "vmUuid"
        ] and
        .schemaVersion == 2 and .state == "guest-firstboot-required" and
        (.baseName | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")) and
        (.catalogSha256 | test("^[0-9A-F]{64}$")) and
        .vmUuid == $vmUuid and .gpuProfile == $gpuProfile and
        .monitorProfile == $monitorProfile and
        .sourceConfigSha256 == $sourceConfigSha256 and
        (.systemNvapiContractId | test("^[0-9A-F]{64}$")) and
        (.systemNvapiIsoFile | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,191}\\.iso$")) and
        (.systemNvapiIsoSha256 | test("^[0-9A-F]{64}$")) and
        (.createdUtc | type) == "string"
    ' "$G11_INIT_REQUIRED" >/dev/null || {
        echo "[start-vm] G-11 初始化标记已过期或不匹配 vm.conf；请用当前版本重新克隆" >&2
        exit 1
    }
    G11_INIT_CONTRACT_ID=$(jq -er '.systemNvapiContractId' "$G11_INIT_REQUIRED")
    G11_INIT_ISO_FILE=$(jq -er '.systemNvapiIsoFile' "$G11_INIT_REQUIRED")
    G11_INIT_ISO_SHA256=$(jq -er '.systemNvapiIsoSha256' "$G11_INIT_REQUIRED")
    G11_INIT_PACKAGE_ROOT="$SELECTED_VM_DIR/packages/SystemNvapiProjection"
    [[ -d "$G11_INIT_PACKAGE_ROOT" && ! -L "$G11_INIT_PACKAGE_ROOT" &&
       "$(stat -c '%a:%u' -- "$G11_INIT_PACKAGE_ROOT")" == "700:${CONF_UID}" ]] || {
        echo "[start-vm] 每 VM 系统 NVAPI 包目录缺失或权限不安全" >&2
        exit 1
    }
    G11_INIT_ISO="$G11_INIT_PACKAGE_ROOT/$G11_INIT_ISO_FILE"
    G11_INIT_ISO_REAL=$(realpath -e -- "$G11_INIT_ISO" 2>/dev/null || true)
    [[ "$G11_INIT_ISO_REAL" == "$G11_INIT_ISO" &&
       -f "$G11_INIT_ISO" && ! -L "$G11_INIT_ISO" && -s "$G11_INIT_ISO" &&
       "$(stat -c '%a:%u:%h' -- "$G11_INIT_ISO")" == "600:${CONF_UID}:1" ]] || {
        echo "[start-vm] 每 VM 系统 NVAPI 初始化 ISO 缺失、越界或权限不安全" >&2
        exit 1
    }
    [[ "$(start_vm_sha256_upper "$G11_INIT_ISO")" == "$G11_INIT_ISO_SHA256" ]] || {
        echo "[start-vm] 每 VM 系统 NVAPI 初始化 ISO 摘要不匹配，拒绝自动执行" >&2
        exit 1
    }
    [[ "$G11_INIT_ISO_FILE" == "vm${VM_ID}-${VM_UUID,,}-${G11_INIT_CONTRACT_ID:0:16}.iso" ]] || {
        echo "[start-vm] 每 VM 系统 NVAPI ISO 名称与 UUID/合同不一致" >&2
        exit 1
    }
    case "$MODE" in
        install|driver-install-sdl|driver-install-gtk)
            echo "[start-vm] 私有克隆初始化期间禁止切换到 Windows/GRID 驱动安装模式" >&2
            exit 1
            ;;
    esac
    if [[ "$MONITOR_SYNC" == 1 ]]; then
        echo "[start-vm] G-11 首次启动尚未完成；将自动安装系统 NVAPI、重启验收并关机"
    fi
    MONITOR_SYNC=0
fi

case "$REPAIR_DISPLAY_VARS" in
    auto|force|off) ;;
    *) echo "REPAIR_DISPLAY_VARS 必须是 auto、force 或 off" >&2; exit 2 ;;
esac
case "$VGPU_ROMBAR" in
    auto|0|1) ;;
    *) echo "VGPU_ROMBAR 必须是 auto、0 或 1" >&2; exit 2 ;;
esac
[[ "$VGPU_CONSOLE_INTERVAL_US" =~ ^(0|[1-9][0-9]{0,6})$ ]] || {
    echo "VGPU_CONSOLE_INTERVAL_US 必须是无前导零的整数微秒（0=禁用）" >&2; exit 2;
}
if (( VGPU_CONSOLE_INTERVAL_US != 0 &&
      (VGPU_CONSOLE_INTERVAL_US < 5000 ||
       VGPU_CONSOLE_INTERVAL_US > 1000000) )); then
    echo "VGPU_CONSOLE_INTERVAL_US 必须为 0 或 5000..1000000" >&2
    exit 2
fi
if [[ -n "$VGPU_FRAME_RATE_LIMITER" &&
      "$VGPU_FRAME_RATE_LIMITER" != 0 && "$VGPU_FRAME_RATE_LIMITER" != 1 ]]; then
    echo "VGPU_FRAME_RATE_LIMITER 必须是 0、1 或留空" >&2
    exit 2
fi
if [[ -n "$VGPU_ROMFILE" && ! -r "$VGPU_ROMFILE" ]]; then
    echo "VGPU_ROMFILE 不存在或不可读: $VGPU_ROMFILE" >&2
    exit 1
fi

if [[ -z "$IVSHMEM_SIZE_MB" ]]; then
    [[ "$MODE" == rdp ]] && IVSHMEM_SIZE_MB=64 || IVSHMEM_SIZE_MB=0
fi
[[ "$IVSHMEM_SIZE_MB" =~ ^[0-9]+$ ]] || {
    echo "--shmem/IVSHMEM_SIZE_MB 必须是非负整数" >&2; exit 2;
}

# TPM 选择优先级：--no-tpm > 调用者环境 TPM > 旧配置显式
# TPM > 主板 profile。版本仍跟随主板：1.2 使用 TIS，2.0 使用 CRB。
BOARD_TPM_VERSION=${BOARD_TPM_VERSION:-legacy}
case "$BOARD_TPM_VERSION" in
    none|1.2|2.0|legacy) ;;
    *)
        echo "BOARD_TPM_VERSION 必须是 none、1.2 或 2.0: $BOARD_TPM_VERSION" >&2
        exit 2
        ;;
esac
if [[ "$TPM_CLI_DISABLED" == 1 ]]; then
    TPM=0
    TPM_EFFECTIVE_VERSION=none
    TPM_DECISION='CLI --no-tpm'
elif [[ "$TPM_ENV_WAS_SET" == 1 ]]; then
    [[ "$TPM" == 0 || "$TPM" == 1 ]] || {
        echo "TPM 环境变量必须是 0 或 1: $TPM" >&2
        exit 2
    }
    if [[ "$TPM" == 1 ]]; then
        case "$BOARD_TPM_VERSION" in
            1.2|2.0) TPM_EFFECTIVE_VERSION=$BOARD_TPM_VERSION ;;
            legacy)  TPM_EFFECTIVE_VERSION=2.0 ;;
            none)
                echo "TPM=1 不能给不支持 TPM 的主板 profile 强行添加 TPM" >&2
                exit 2
                ;;
        esac
        TPM_DECISION="environment TPM=1 (board version ${TPM_EFFECTIVE_VERSION})"
    else
        TPM_EFFECTIVE_VERSION=none
        TPM_DECISION='environment TPM=0'
    fi
elif [[ "$TPM_CONFIG_WAS_SET" == 1 ]]; then
    [[ "$TPM" == 0 || "$TPM" == 1 ]] || {
        echo "vm.conf 中 TPM 必须是 0 或 1: $TPM" >&2
        exit 2
    }
    if [[ "$TPM" == 1 ]]; then
        case "$BOARD_TPM_VERSION" in
            1.2|2.0) TPM_EFFECTIVE_VERSION=$BOARD_TPM_VERSION ;;
            legacy)  TPM_EFFECTIVE_VERSION=2.0 ;;
            none)
                echo "vm.conf 中 TPM=1 与 BOARD_TPM_VERSION=none 矛盾" >&2
                exit 2
                ;;
        esac
        TPM_DECISION="legacy vm.conf TPM=1 (version ${TPM_EFFECTIVE_VERSION})"
    else
        TPM_EFFECTIVE_VERSION=none
        TPM_DECISION='legacy vm.conf TPM=0'
    fi
else
    case "$BOARD_TPM_VERSION" in
        2.0)
            TPM=1
            TPM_EFFECTIVE_VERSION=2.0
            TPM_DECISION='board profile TPM 2.0'
            ;;
        1.2)
            TPM=1
            TPM_EFFECTIVE_VERSION=1.2
            TPM_DECISION='board profile TPM 1.2'
            ;;
        none)
            TPM=0
            TPM_EFFECTIVE_VERSION=none
            TPM_DECISION='board profile has no TPM'
            ;;
        legacy)
            TPM=1
            TPM_EFFECTIVE_VERSION=2.0
            TPM_DECISION='legacy config default TPM 2.0'
            ;;
    esac
fi
export VM_TPM_VERSION=$TPM_EFFECTIVE_VERSION

TPM_FRONTEND=$(g11_hardware_expected_tpm_frontend "$TPM_EFFECTIVE_VERSION") || {
    echo "[start-vm] TPM $TPM_EFFECTIVE_VERSION has no reviewed QEMU frontend" >&2
    exit 2
}
# The older launcher filled absent SSD link metadata with its historical NVMe
# runtime defaults before reaching this point.  Hide only that known inferred
# triplet from the legacy validator, then restore it for argv compatibility.
LEGACY_LEGALITY_SSD_TOPOLOGY_HIDDEN=0
if [[ "$HARDWARE_LEGALITY_POLICY" == legacy &&
      "$SSD_TOPOLOGY_METADATA_STRICT" == 0 ]]; then
    LEGACY_LEGALITY_SSD_TOPOLOGY_HIDDEN=1
    LEGACY_LEGALITY_SSD_FORM_FACTOR=$SSD_FORM_FACTOR
    LEGACY_LEGALITY_SSD_PCIE_GEN=$SSD_PCIE_GEN
    LEGACY_LEGALITY_SSD_PCIE_LANES=$SSD_PCIE_LANES
    unset SSD_FORM_FACTOR SSD_PCIE_GEN SSD_PCIE_LANES
fi
if g11_hardware_combination_validate "$HARDWARE_LEGALITY_POLICY"; then
    HARDWARE_LEGALITY_RC=0
else
    HARDWARE_LEGALITY_RC=$?
fi
if [[ "$LEGACY_LEGALITY_SSD_TOPOLOGY_HIDDEN" == 1 ]]; then
    SSD_FORM_FACTOR=$LEGACY_LEGALITY_SSD_FORM_FACTOR
    SSD_PCIE_GEN=$LEGACY_LEGALITY_SSD_PCIE_GEN
    SSD_PCIE_LANES=$LEGACY_LEGALITY_SSD_PCIE_LANES
    unset LEGACY_LEGALITY_SSD_FORM_FACTOR LEGACY_LEGALITY_SSD_PCIE_GEN \
        LEGACY_LEGALITY_SSD_PCIE_LANES
fi
if (( HARDWARE_LEGALITY_RC != 0 )); then
    echo "[start-vm] 硬件组合不合法 [$G11_HW_LEGALITY_CODE]: $G11_HW_LEGALITY_MESSAGE" >&2
    exit 2
fi
unset HARDWARE_LEGALITY_RC LEGACY_LEGALITY_SSD_TOPOLOGY_HIDDEN
if [[ -n "$G11_HW_LEGALITY_LEGACY_FIELDS" ]]; then
    echo "[start-vm] WARN: legacy hardware contract inferred/skipped: $G11_HW_LEGALITY_LEGACY_FIELDS" >&2
fi

# Contract v3 is the first version that binds every generated label to its
# component/vendor policy.  Older immutable profiles keep their historical
# generic strings; they are never silently rewritten on boot.
if [[ "${G11_HARDWARE_CONTRACT_VERSION-}" == 3 ]]; then
    for identity_field in SYS_SN MB_SN CHASSIS_SN; do
        identity_value=${!identity_field-}
        if ! g11_hardware_serial_board_validate "$BOARD_BRAND" \
                "$identity_value" "$BOARD_MODEL" "$BOARD_RELEASE_YEAR"; then
            echo "[start-vm] $identity_field 不符合 $BOARD_BRAND/$BOARD_SERIAL_POLICY 序列合同" >&2
            exit 2
        fi
    done
    if [[ "$SYS_SN" == "$MB_SN" || "$SYS_SN" == "$CHASSIS_SN" ||
          "$MB_SN" == "$CHASSIS_SN" ]]; then
        echo "[start-vm] system/baseboard/chassis 序列号必须各自唯一" >&2
        exit 2
    fi
    g11_hardware_serial_memory_validate "${MEM_SN-}" || {
        echo "[start-vm] MEM_SN 不是非保留 JEDEC 4-byte 序列号" >&2
        exit 2
    }
    if [[ -v MEM_SERIAL_LIST ]]; then
        g11_hardware_serial_memory_list_validate \
            "$MEM_SN" "${MEM_SLOTS-}" "$MEM_SERIAL_LIST" || {
            echo "[start-vm] MEM_SERIAL_LIST 与 MEM_SN+MEM_SLOTS 逐槽派生不一致" >&2
            exit 2
        }
    else
        MEM_SERIAL_LIST=$(g11_hardware_serial_memory_list_generate \
            "$MEM_SN" "${MEM_SLOTS-}") || {
            echo "[start-vm] 无法从旧 v3 MEM_SN+MEM_SLOTS 稳定派生逐槽序列" >&2
            exit 2
        }
        echo "[start-vm] WARN: 旧 v3 配置缺少 MEM_SERIAL_LIST，已按 MEM_SN+slot 稳定派生（未改写 vm.conf）" >&2
    fi
    g11_hardware_serial_ssd_validate "${SSD_PROFILE-}" "${SSD_SN-}" strict || {
        echo "[start-vm] SSD_SN 不符合 ${SSD_PROFILE-<missing>} 严格序列合同" >&2
        exit 2
    }
    if ! g11_identity_candidates_are_unique "$VM_ID" "$VM_ROOT" \
            VM_UUID "$VM_UUID" \
            VM_MAC "$VM_MAC" \
            SYS_SN "$SYS_SN" \
            MB_SN "$MB_SN" \
            CHASSIS_SN "$CHASSIS_SN" \
            MEM_SERIAL_LIST "$MEM_SERIAL_LIST" \
            SSD_SN "$SSD_SN" \
            MONITOR_SERIAL "${MONITOR_SERIAL-}"; then
        echo "[start-vm] 硬件身份全局唯一性检查失败: ${G11_IDENTITY_UNIQUENESS_MESSAGE}" >&2
        [[ -z "$G11_IDENTITY_CONFLICT_CONFIG" ]] || \
            echo "  冲突配置: $G11_IDENTITY_CONFLICT_CONFIG" >&2
        exit 2
    fi
    unset identity_field identity_value
fi

# Runtime topology/cache/SPD facts are always reloaded from the reviewed
# PLATFORM combination after the persisted identity has passed legality.  Old
# vm.conf files therefore gain the correct dynamic topology without rewriting
# their immutable file; current files additionally carry a component contract
# that made any tampering fail above.
hardware_profile_load "$PLATFORM" || exit $?

# Every board in the current catalog has one closed, reviewed LPC identity.
# `off` is an explicit recovery escape hatch for an existing Windows image;
# arbitrary PCI IDs are never accepted from vm.conf or the environment.
CHIPSET_PRESENTATION_ARGS=()
case "${G11_CHIPSET_PRESENTATION,,}" in
    catalog)
        CHIPSET_PRESENTATION_ARGS=(
            -global "ICH9-LPC.x-g11-chipset=${CHIPSET_QEMU_PRESENTATION_KEY}"
        )
        ;;
    off)
        echo "[start-vm] WARN: 芯片组 PCI identity 投影已关闭；来宾会重新看到默认 ICH9" >&2
        ;;
    *)
        echo "[start-vm] G11_CHIPSET_PRESENTATION 必须是 catalog 或 off" >&2
        exit 2
        ;;
esac

# The active X79 catalog also has a CPU-side DMI2 inventory identity.  This is
# selected by CPU profile rather than VM ID, so VM3 is only an acceptance
# machine and every legal i7-3820/i7-4820K instance gets the same mapping.
# The functional 00:00.0 device remains q35 throughout: OVMF first sees its
# required 29c0 ID, then the reviewed DMI2 ID becomes visible at the standard
# UEFI ExitBootServices boundary, before operating-system PCI inventory.
HOST_BRIDGE_PRESENTATION_ARGS=()
case "${G11_HOST_BRIDGE_PRESENTATION,,}" in
    catalog)
        if [[ -n "${CPU_HOST_BRIDGE_PRESENTATION_KEY:-}" ]]; then
            HOST_BRIDGE_PRESENTATION_ARGS=(
                -global "mch.x-g11-host-bridge=${CPU_HOST_BRIDGE_PRESENTATION_KEY}"
            )
        elif [[ "$BOARD_CHIPSET" == X79 ]]; then
            echo "[start-vm] X79 CPU 缺少已审核的 DMI2 host bridge identity: ${CPU_PROFILE}" >&2
            exit 2
        fi
        ;;
    off)
        if [[ -n "${CPU_HOST_BRIDGE_PRESENTATION_KEY:-}" ]]; then
            echo "[start-vm] WARN: CPU DMI2 inventory identity 已关闭；来宾只看到默认 P35 MCH" >&2
        fi
        ;;
    *)
        echo "[start-vm] G11_HOST_BRIDGE_PRESENTATION 必须是 catalog 或 off" >&2
        exit 2
        ;;
esac

: "${QEMU_BIN:=$here/../build/qemu-system-x86_64}"
: "${QEMU_IMG:=$here/../build/qemu-img}"

# Probe the exact catalog CPU against KVM before creating a disk, changing
# offline guest state, allocating a TAP/mdev or starting swtpm.  Dry-run stays
# side-effect free and merely renders the policy's enforce mode; every real
# launch performs the bounded QMP realization probe.
if [[ "$DRY_RUN" == 1 ]]; then
    if [[ "$CPU_REALIZATION_LIFECYCLE" == new ]]; then
        CPU_ENFORCE_MODE=on
    else
        CPU_ENFORCE_MODE=off
    fi
    G11_CPU_CAPABILITY_CLASS=not-probed-dry-run
    G11_CPU_CAPABILITY_REASON=G11_CPU_CAP_DRY_RUN
else
    if ! g11_cpu_realization_gate "$QEMU_BIN" "$CPU_MODEL" \
            "$CPU_REALIZATION_LIFECYCLE"; then
        echo "[start-vm] CPU 无法按当前硬件合同启动: class=$G11_CPU_CAPABILITY_CLASS reason=$G11_CPU_CAPABILITY_REASON gate=$G11_CPU_GATE_REASON" >&2
        if [[ "$CPU_REALIZATION_LIFECYCLE" == new ]]; then
            echo "[start-vm] 新 VM 必须通过 KVM enforce=on；请从 --list-platforms 选择宿主可实现平台" >&2
        else
            echo "[start-vm] 旧 VM 也未通过受控 compatibility realization，拒绝继续" >&2
        fi
        exit 1
    fi
    case "$G11_CPU_CAPABILITY_CLASS" in
        supported) CPU_ENFORCE_MODE=on ;;
        compatibility) CPU_ENFORCE_MODE=off ;;
        *)
            echo "[start-vm] CPU probe returned unexpected class: $G11_CPU_CAPABILITY_CLASS" >&2
            exit 1
            ;;
    esac
fi

if ! g11_tsc_policy_resolve "$here/scripts/kvm-capabilities.py" \
        "$TSC_FREQ" "$G11_TSC_POLICY"; then
    echo "[start-vm] TSC 策略无法实现: policy=${G11_TSC_POLICY} profile=${TSC_FREQ}Hz host=${G11_KVM_TSC_KHZ:-unknown}kHz error=${G11_KVM_ERROR:-unknown}" >&2
    exit 1
fi

# 与 guest 磁盘无关地读取 QEMU 自身 ELF，先验证 host file AIO 后端。
# auto 只有 active-read 成功才选择内核后端；否则安全回退 threads。
# 显式 native/io_uring 失败关闭，不接受 QEMU 的静默线程池回退。
g11_storage_select_aio || exit $?

# Fail before publishing a blank disk when the requested/default ISO is wrong.
if [[ "$MODE" == install && ! -f "$ISO" ]]; then
    echo "ISO 不存在: $ISO" >&2
    exit 1
fi

# OVMF can read a USB BOT CD-ROM efficiently but does not create a persistent
# boot option for this El Torito layout on fresh NVRAM.  The reviewed helper is
# a tiny read-only FAT volume that chainloads only a Windows ISO containing both
# EFI/BOOT/BOOTX64.EFI and sources/boot.wim.  Verify the exact generated asset
# before xorriso, blank-disk publication, TPM/TAP/mdev allocation or full VM launch.
# IDE fallback and every non-install mode deliberately have no helper dependency.
if [[ "$MODE" == install && "$INSTALL_MEDIA_BACKEND" == usb ]]; then
    if [[ ! -f "$INSTALL_BOOT_HELPER" || -L "$INSTALL_BOOT_HELPER" ||
          ! -r "$INSTALL_BOOT_HELPER" ]]; then
        echo "[start-vm] 高速安装引导 helper 缺失或不安全: $INSTALL_BOOT_HELPER" >&2
        echo "[start-vm] 运行 ./deploy/host/build-usb-install-boot-helper.sh 后重试，" >&2
        echo "[start-vm] 或临时使用 --install-media ide。" >&2
        exit 1
    fi
    command -v sha256sum >/dev/null 2>&1 || {
        echo "[start-vm] 校验高速安装 helper 需要 sha256sum" >&2
        exit 1
    }
    INSTALL_BOOT_HELPER_ACTUAL_SHA256=$(sha256sum "$INSTALL_BOOT_HELPER")
    INSTALL_BOOT_HELPER_ACTUAL_SHA256=${INSTALL_BOOT_HELPER_ACTUAL_SHA256%% *}
    if [[ "$INSTALL_BOOT_HELPER_ACTUAL_SHA256" != "$INSTALL_BOOT_HELPER_SHA256" ]]; then
        echo "[start-vm] 高速安装 helper 哈希不匹配，拒绝启动" >&2
        echo "  expected: $INSTALL_BOOT_HELPER_SHA256" >&2
        echo "  actual:   $INSTALL_BOOT_HELPER_ACTUAL_SHA256" >&2
        echo "[start-vm] 请运行 ./deploy/host/build-usb-install-boot-helper.sh，" >&2
        echo "[start-vm] 或临时使用 --install-media ide。" >&2
        exit 1
    fi
    unset INSTALL_BOOT_HELPER_ACTUAL_SHA256
fi

# Windows Setup 会从第二张只读光盘根目录自动读取 Autounattend.xml。
# 模板只处理 locale/OOBE/内置 Administrator/NumLock；产品密钥、版本和
# 磁盘分区仍由安装界面确认，因此给已有系统盘挂安装 ISO 也不会静默擦盘。
# answer ISO 在建空系统盘之前生成：模板或 xorriso 有问题时可安全重试，
# 不会留下一个看似已准备好、实际无法按预期安装的 blank disk。
if [[ "$MODE" == install && "$INSTALL_UNATTENDED" == 1 ]]; then
    computer_suffix=${VM_UUID//-/}
    computer_suffix=${computer_suffix^^}
    INSTALL_COMPUTER_NAME="DESKTOP-${computer_suffix:0:7}"
    UNATTEND_ISO="$(vm_storage_instance_run_dir "$VM_ID")/autounattend.iso"
    if [[ "$DRY_RUN" != 1 ]]; then
        windows_unattend_build_iso \
            "$INSTALL_UNATTEND_TEMPLATE" "$UNATTEND_ISO" \
            "$INSTALL_COMPUTER_NAME"
    fi
    echo "[start-vm] 自动 OOBE: Administrator 空密码 / China Standard Time / NumLock on"
    echo "[start-vm] 手动安装: 产品密钥 / Windows 版本 / 目标磁盘与分区"
    echo "[start-vm] 应答介质: $UNATTEND_ISO  (ComputerName=$INSTALL_COMPUTER_NAME)"
elif [[ "$MODE" == install ]]; then
    echo "[start-vm] 手动 OOBE: 未附加 Autounattend.xml"
fi

# 参数已经完整解析，可以安全地按启动意图 bootstrap 磁盘：安装模式只建
# 空盘；普通模式只克隆公共 base。普通模式没有 base 时拒绝静默创建一个
# 无法启动的空 NVMe，明确引导用户改用 --install。
if [[ ! -f "$DISK_PATH" ]]; then
    if [[ "$DRY_RUN" == 1 ]]; then
        echo "[start-vm] DRY_RUN: 实际启动前将创建磁盘: $DISK_PATH"
    elif [[ "$MODE" == install ]]; then
        echo "[start-vm] $DISK_PATH 不存在，安装模式自动创建空盘"
        SIZE_BYTES="$SSD_SIZE_BYTES" "$here/scripts/create-disk.sh" "$VM_ID" --blank
        DISK_PATH=$(vm_storage_disk_path "$VM_ID")
    else
        BASE_PATH=$(vm_storage_base_path)
        if [[ ! -f "$BASE_PATH" ]]; then
            echo "[start-vm] $DISK_PATH 不存在，且没有可克隆的公共 base: $BASE_PATH" >&2
            echo "[start-vm] 首次安装请用: $0 ${VM_ID} --install [/absolute/windows.iso]" >&2
            exit 1
        fi
        echo "[start-vm] $DISK_PATH 不存在，自动从公共 base 创建实例盘"
        "$here/scripts/create-disk.sh" "$VM_ID" --from-base --linked
        DISK_PATH=$(vm_storage_disk_path "$VM_ID")
    fi
fi

[[ -x "$QEMU_IMG" ]] || QEMU_IMG=$(command -v qemu-img || true)
: "${OVMF_CODE:=$here/host/OVMF_CODE_4M_stealth.fd}"
: "${OVMF_VARS:=/usr/share/OVMF/OVMF_VARS_4M.fd}"
: "${GUEST_MEM_MB:=8192}"

# vm.conf 的厂标容量是 guest-visible 硬件身份的一部分。对已有盘也
# 严格比较 qcow2 virtual-size，避免 --force 改 profile 后型号/容量互相打架。
if [[ "$DRY_RUN" != 1 ]]; then
    [[ -x "$QEMU_IMG" ]] || {
        echo "[start-vm] 校验实例盘需要 qemu-img（QEMU_IMG）" >&2
        exit 1
    }
    if ! vm_storage_read_qcow2_metadata "$QEMU_IMG" "$DISK_PATH"; then
        echo "[start-vm] 无法安全校验 VM 磁盘: $DISK_PATH" >&2
        exit 1
    fi
    INSTANCE_DISK_VIRTUAL_SIZE=$VM_STORAGE_QCOW2_VIRTUAL_SIZE
    INSTANCE_DISK_MODE=standalone
    if [[ -n "$VM_STORAGE_QCOW2_DATA_FILE" ]]; then
        echo "[start-vm] 实例盘不能使用 external data file: $DISK_PATH" >&2
        exit 1
    fi
    if [[ -n "$VM_STORAGE_QCOW2_BACKING" ]]; then
        INSTANCE_BASE_PIN=$(vm_storage_instance_base_pin_path "$VM_ID") || exit 1
        if [[ "$VM_STORAGE_QCOW2_BACKING" != "$(basename "$INSTANCE_BASE_PIN")" ]]; then
            echo "[start-vm] 增量盘必须使用实例内固定相对母盘 pin: $INSTANCE_BASE_PIN" >&2
            exit 1
        fi
        RESOLVED_INSTANCE_BASE_PIN=$(vm_storage_resolved_backing_path "$DISK_PATH") || {
            echo "[start-vm] 无法安全解析增量盘 backing" >&2
            exit 1
        }
        if [[ "$RESOLVED_INSTANCE_BASE_PIN" != "$INSTANCE_BASE_PIN" ||
              ! -f "$INSTANCE_BASE_PIN" || -L "$INSTANCE_BASE_PIN" ||
              "$DISK_PATH" -ef "$INSTANCE_BASE_PIN" ]]; then
            echo "[start-vm] 增量盘 backing 不是安全的实例内 .base.qcow2" >&2
            exit 1
        fi
        if ! vm_storage_read_qcow2_metadata "$QEMU_IMG" "$INSTANCE_BASE_PIN" ||
                [[ -n "$VM_STORAGE_QCOW2_BACKING" ||
                   -n "$VM_STORAGE_QCOW2_DATA_FILE" ]]; then
            echo "[start-vm] 实例内母盘 pin 必须是 standalone qcow2" >&2
            exit 1
        fi
        INSTANCE_DISK_MODE=linked
    fi
    if [[ "$INSTANCE_DISK_VIRTUAL_SIZE" != "$SSD_SIZE_BYTES" ]]; then
        echo "[start-vm] 磁盘容量与硬件 profile 不一致，拒绝启动" >&2
        echo "  qcow2:  $INSTANCE_DISK_VIRTUAL_SIZE 字节" >&2
        echo "  profile: $SSD_SIZE_BYTES 字节 ($SSD_MODEL)" >&2
        echo "[start-vm] 请备份后迁移/扩容 qcow2，或恢复与磁盘匹配的 SSD profile" >&2
        exit 1
    fi
    if [[ "$INSTANCE_DISK_MODE" == linked ]]; then
        echo "[start-vm] 实例盘: V-11 式增量盘 / backing=.base.qcow2"
    fi
fi
disk_headroom_guard "$DISK_PATH"

# NVIDIA 535 mdev 没有 VFIO_GFX_EDID_REGION，不能把 QEMU EDID region
# 直接交给 Windows。默认在 QEMU 启动前、磁盘确定离线时按需刷新
# Windows 标准 Device Parameters\EDID_OVERRIDE（每 128B 一块）、raw EDID
# 和模式缓存；只改系统 hive，不向 guest 复制脚本、安装服务或创建计划任务。
if [[ "$DRY_RUN" != 1 && "$MONITOR_SYNC" == 1 ]]; then
    case "$MODE" in
        vgpu-gtk|vgpu-sdl|driver-install-gtk|driver-install-sdl|rdp)
            echo "[start-vm] 检查 host 侧 Windows EDID_OVERRIDE/EDID（guest 内不安装组件）..."
            QEMU_EDID_BIN="${QEMU_EDID:-$(dirname "$QEMU_BIN")/qemu-edid}"
            monitor_sync_rc=0
            VM_START_LOCK_HELD=1 QEMU_EDID="$QEMU_EDID_BIN" \
                MONITOR_SYNC_SPOOF_MODE="$SPOOF_MODE" \
                "$here/scripts/sync-monitor-profile.sh" "$VM_ID" || monitor_sync_rc=$?
            case "$monitor_sync_rc" in
                0) ;;
                10)
                    case "$MODE" in
                        driver-install-sdl|driver-install-gtk)
                            echo "[start-vm] GRID 首装：认证驱动已存在但尚无显示器缓存；标准 VGA 将安全完成枚举"
                            ;;
                        *)
                            echo "[start-vm] ERROR: Windows 尚未缓存显示器；拒绝在 NVIDIA native console 上做首次枚举" >&2
                            echo "[start-vm]        请运行通用安全入口：./deploy/scripts/vmctl.sh driver-install ${VM_ID}" >&2
                            exit 10
                            ;;
                    esac
                    ;;
                12)
                    case "$MODE" in
                        driver-install-sdl|driver-install-gtk)
                            echo "[start-vm] GRID 首装基线已落盘：安全 EDID/缓存完成，NV_Modes 待驱动安装后补齐"
                            ;;
                        *)
                            echo "[start-vm] ERROR: Windows 尚未安装认证 GRID 驱动；拒绝让 R535 在 native console 上首次接管" >&2
                            echo "[start-vm]        请运行通用安全入口：./deploy/scripts/vmctl.sh driver-install ${VM_ID}" >&2
                            exit 12
                            ;;
                    esac
                    ;;
                13)
                    case "$MODE" in
                        driver-install-sdl|driver-install-gtk)
                            echo "[start-vm] GRID 首装：尚无 EDID/NVIDIA 缓存；标准 VGA 将先完成枚举，mdev console 保持隔离"
                            ;;
                        *)
                            echo "[start-vm] ERROR: 新 Windows 尚无 EDID 和认证 GRID 驱动；禁止直接 native 首装" >&2
                            echo "[start-vm]        请运行通用安全入口：./deploy/scripts/vmctl.sh driver-install ${VM_ID}" >&2
                            exit 13
                            ;;
                    esac
                    ;;
                11)
                    echo "[start-vm] ERROR: Windows 处于休眠/Fast Startup；vGPU 恢复可能触发 0x10E" >&2
                    echo "[start-vm]        不要强制挂载磁盘，也不要用 VNC/RDP。运行一键恢复：" >&2
                    recovery_cmd=( "./deploy/scripts/recover-hibernated-vm.sh" "$VM_ID" )
                    [[ -z "${VMS_DIR_CLI:-}" ]] || \
                        recovery_cmd+=( --vms-dir "$VMS_DIR_CLI" )
                    [[ -z "${VM_DIR_CLI:-}" ]] || \
                        recovery_cmd+=( --vm-dir "$VM_DIR_CLI" )
                    [[ -z "${INSTANCES_DIR_CLI:-}" ]] || \
                        recovery_cmd+=( --instances-dir "$INSTANCES_DIR_CLI" )
                    [[ "${PROXY:-0}" != 1 ]] || recovery_cmd+=( --proxy )
                    printf '[start-vm]         ' >&2
                    printf ' %q' "${recovery_cmd[@]}" >&2
                    printf '\n' >&2
                    echo "[start-vm]        它会打开本地标准 VGA 窗口；完整关机后只离线同步 EDID/NV_Modes。" >&2
                    exit 11
                    ;;
                *)
                    echo "[start-vm] ERROR: host 离线 EDID 同步失败（rc=$monitor_sync_rc），拒绝在未知挂载状态下启动" >&2
                    echo "[start-vm]        排障后重试；确认要跳过可显式加 --no-monitor-sync" >&2
                    exit "$monitor_sync_rc"
                    ;;
            esac
            ;;
    esac
fi
start_vm_timing_mark host-checks

[[ "$GUEST_MEM_MB" =~ ^[1-9][0-9]*$ ]] || {
    echo "GUEST_MEM_MB 必须是正整数: $GUEST_MEM_MB" >&2
    exit 2
}

# 最新 q35 按逐槽列表生成 SPD 与 SMBIOS Type 17；它既能准确表示
# 2x2/2x4，也能表示 4+2 GiB。标量字段只是旧 vm.conf 的第一条 DIMM
# 兼容别名，绝不能再用“单条容量 x 条数”推导混搭总量。
MEM_TOPOLOGY_LEGACY=0
if [[ -z "${MEM_MODULE_MB_LIST:-}" ]]; then
    MEM_TOPOLOGY_LEGACY=1
    [[ "${MEM_MODULE_MB:-}" =~ ^(2048|4096)$ &&
       "${MEM_SLOTS:-}" =~ ^[1-9][0-9]*$ ]] || {
        echo "旧内存配置缺少可推导的 MEM_MODULE_MB/MEM_SLOTS" >&2
        exit 2
    }
    MEM_MODULE_MB_LIST=$MEM_MODULE_MB
    for ((mem_i = 2; mem_i <= MEM_SLOTS; mem_i += 1)); do
        MEM_MODULE_MB_LIST+=",$MEM_MODULE_MB"
    done
fi
[[ "${MEM_SLOTS:-}" =~ ^[1-9][0-9]*$ ]] || {
    echo "MEM_SLOTS 必须是正整数: ${MEM_SLOTS:-<empty>}" >&2
    exit 2
}
IFS=',' read -r -a MEM_MODULE_SIZES <<<"$MEM_MODULE_MB_LIST"
(( ${#MEM_MODULE_SIZES[@]} == MEM_SLOTS )) || {
    echo "MEM_MODULE_MB_LIST 条目数 ${#MEM_MODULE_SIZES[@]} 与 MEM_SLOTS=$MEM_SLOTS 不一致" >&2
    exit 2
}
MEM_MODULE_TOTAL_MB=0
for mem_module_size in "${MEM_MODULE_SIZES[@]}"; do
    [[ "$mem_module_size" == 2048 || "$mem_module_size" == 4096 ]] || {
        echo "Q35 逐槽内存只允许审核过的 2048/4096 MiB，收到: $mem_module_size" >&2
        exit 2
    }
    MEM_MODULE_TOTAL_MB=$((MEM_MODULE_TOTAL_MB + mem_module_size))
done
(( MEM_MODULE_TOTAL_MB == GUEST_MEM_MB )) || {
    echo "内存逐槽总量 $MEM_MODULE_TOTAL_MB MiB != GUEST_MEM_MB $GUEST_MEM_MB MiB" >&2
    exit 2
}
: "${MEM_MODULE_MB:=${MEM_MODULE_SIZES[0]}}"
[[ "$MEM_MODULE_MB" == "${MEM_MODULE_SIZES[0]}" ]] || {
    echo "MEM_MODULE_MB=$MEM_MODULE_MB 必须等于逐槽列表第一项 ${MEM_MODULE_SIZES[0]}" >&2
    exit 2
}
IFS=',' read -r -a MEM_MODEL_PARTS <<<"${MEM_MODEL_LIST:-${MEM_MODEL:-}}"
IFS=',' read -r -a MEM_DEVICE_WIDTHS <<<"${MEM_DEVICE_WIDTH_LIST:-${MEM_DEVICE_WIDTH:-}}"
IFS=',' read -r -a MEM_RANKS <<<"${MEM_RANK_LIST:-${MEM_RANK:-}}"
IFS=',' read -r -a MEM_MODULE_JEP106_IDS <<<"${MEM_MODULE_MFR_JEP106_LIST:-}"
IFS=',' read -r -a MEM_DRAM_JEP106_IDS <<<"${MEM_DRAM_MFR_JEP106_LIST:-}"
(( ${#MEM_MODEL_PARTS[@]} == MEM_SLOTS &&
   ${#MEM_DEVICE_WIDTHS[@]} == MEM_SLOTS &&
   ${#MEM_RANKS[@]} == MEM_SLOTS &&
   ${#MEM_MODULE_JEP106_IDS[@]} == MEM_SLOTS &&
   ${#MEM_DRAM_JEP106_IDS[@]} == MEM_SLOTS )) || {
    echo "内存料号/rank/device-width/JEP106 逐槽列表与 MEM_SLOTS=$MEM_SLOTS 不一致" >&2
    exit 2
}
for ((mem_i = 0; mem_i < MEM_SLOTS; mem_i += 1)); do
    [[ -n "${MEM_MODEL_PARTS[mem_i]}" &&
       ${#MEM_MODEL_PARTS[mem_i]} -le 18 &&
       "${MEM_MODULE_JEP106_IDS[mem_i]}" =~ ^[0-9A-F]{4}$ &&
       "${MEM_MODULE_JEP106_IDS[mem_i]}" != 0000 &&
       "${MEM_DRAM_JEP106_IDS[mem_i]}" =~ ^[0-9A-F]{4}$ ]] || {
        echo "内存 slot $mem_i 缺少料号" >&2
        exit 2
    }
    case "${MEM_MODULE_SIZES[mem_i]}:${MEM_RANKS[mem_i]}:${MEM_DEVICE_WIDTHS[mem_i]}" in
        2048:1:16|2048:1:8|4096:1:8|4096:2:8) ;;
        *)
            echo "内存 slot $mem_i 容量/rank/device-width 未经审核: ${MEM_MODULE_SIZES[mem_i]}/${MEM_RANKS[mem_i]}/${MEM_DEVICE_WIDTHS[mem_i]}" >&2
            exit 2
            ;;
    esac
done
case "${MEM_CHANNEL_MODE:-}" in
    dual-channel|triple-channel|quad-channel)
        case "${MEM_CHANNEL_MODE}:${MEM_SLOTS}" in
            dual-channel:2|triple-channel:3|quad-channel:4) ;;
            *)
                echo "内存通道数必须等于已安装条数: ${MEM_CHANNEL_MODE}/${MEM_SLOTS}" >&2
                exit 2
                ;;
        esac
        for ((mem_i = 1; mem_i < MEM_SLOTS; mem_i += 1)); do
            [[ "${MEM_MODULE_SIZES[0]}" == "${MEM_MODULE_SIZES[mem_i]}" &&
               "${MEM_MODEL_PARTS[0]}" == "${MEM_MODEL_PARTS[mem_i]}" &&
               "${MEM_RANKS[0]}" == "${MEM_RANKS[mem_i]}" &&
               "${MEM_DEVICE_WIDTHS[0]}" == "${MEM_DEVICE_WIDTHS[mem_i]}" &&
               "${MEM_MODULE_JEP106_IDS[0]}" == "${MEM_MODULE_JEP106_IDS[mem_i]}" &&
               "${MEM_DRAM_JEP106_IDS[0]}" == "${MEM_DRAM_JEP106_IDS[mem_i]}" ]] || {
                echo "多通道内存必须逐条同容量、同料号、同几何 DIMM" >&2
                exit 2
            }
        done
        ;;
    flex)
        [[ "$MEM_MODULE_MB_LIST" == 4096,2048 &&
           "$GUEST_MEM_MB" == 6144 ]] || {
            echo "Flex 模式只允许审核过的 4+2 GiB 两条布局" >&2
            exit 2
        }
        ;;
    *)
        echo "MEM_CHANNEL_MODE 必须是 dual/triple/quad-channel 或归档 flex: ${MEM_CHANNEL_MODE:-<empty>}" >&2
        exit 2
        ;;
esac
: "${MEM_BOARD_SLOTS:=$MEM_SLOTS}"
: "${MEM_MAX_CAPACITY_GB:=$(((GUEST_MEM_MB + 1023) / 1024))}"
[[ "$MEM_BOARD_SLOTS" =~ ^[1-9][0-9]*$ &&
   "$MEM_MAX_CAPACITY_GB" =~ ^[1-9][0-9]*$ ]] || {
    echo "MEM_BOARD_SLOTS/MEM_MAX_CAPACITY_GB 必须是正整数: ${MEM_BOARD_SLOTS:-?}/${MEM_MAX_CAPACITY_GB:-?}" >&2
    exit 2
}
(( MEM_BOARD_SLOTS >= MEM_SLOTS )) || {
    echo "内存 profile 不一致: 已安装 $MEM_SLOTS 条，主板只有 $MEM_BOARD_SLOTS 个插槽" >&2
    exit 2
}
(( MEM_MAX_CAPACITY_GB * 1024 >= GUEST_MEM_MB )) || {
    echo "内存 profile 超过主板上限: ${GUEST_MEM_MB} MiB > ${MEM_MAX_CAPACITY_GB} GiB" >&2
    exit 2
}
if [[ -n "${MEM_TOTAL_MB:-}" ]]; then
    [[ "$MEM_TOTAL_MB" =~ ^[1-9][0-9]*$ ]] || {
        echo "MEM_TOTAL_MB 必须是正整数: $MEM_TOTAL_MB" >&2
        exit 2
    }
    (( MEM_TOTAL_MB == GUEST_MEM_MB )) || {
        echo "内存 profile 不一致: MEM_TOTAL_MB=$MEM_TOTAL_MB, GUEST_MEM_MB=$GUEST_MEM_MB" >&2
        exit 2
    }
fi
if [[ -n "${MEM_FORM_FACTOR:-}" && "$MEM_FORM_FACTOR" != DIMM ]]; then
    echo "桌面主板 profile 必须使用 DIMM，不能是: $MEM_FORM_FACTOR" >&2
    exit 2
fi
if [[ "$MEM_TOPOLOGY_LEGACY" == 1 ]]; then
    echo "[start-vm] WARN: 旧 vm.conf 缺少逐槽 DIMM 列表，已按审核平台的等容量布局补齐" >&2
fi
unset mem_i mem_module_size MEM_MODULE_TOTAL_MB

# 即使使用按需触页，Guest 后续仍可能用满固定上限；在分配 mdev、启动 swtpm
# 之前先确认 host RAM + swap 至少能容纳本 VM，避免 OOM killer 连带杀掉其它 VM。
# MEM_GUARD=0 可关闭；确知风险时可用 MEM_FORCE=1 越过硬拒绝。
check_memory_capacity() {
    local avail_kb swap_kb required_kb margin_mb margin_kb total_kb

    [[ "$DRY_RUN" != 1 && "${MEM_GUARD:-1}" != 0 ]] || return 0
    avail_kb=$(awk '/^MemAvailable:/{print $2; exit}' /proc/meminfo 2>/dev/null || true)
    swap_kb=$(awk '/^SwapFree:/{print $2; exit}' /proc/meminfo 2>/dev/null || true)
    if [[ ! "$avail_kb" =~ ^[0-9]+$ || ! "$swap_kb" =~ ^[0-9]+$ ]]; then
        echo "[start-vm] WARN: 无法读取 /proc/meminfo，跳过内存护栏" >&2
        return 0
    fi
    margin_mb=${MEM_GUARD_MARGIN_MB:-2048}
    [[ "$margin_mb" =~ ^[0-9]+$ ]] || {
        echo "MEM_GUARD_MARGIN_MB 必须是非负整数: $margin_mb" >&2
        return 2
    }
    required_kb=$(( GUEST_MEM_MB * 1024 ))
    margin_kb=$(( margin_mb * 1024 ))
    total_kb=$(( avail_kb + swap_kb ))
    if (( total_kb < required_kb )); then
        if [[ "${MEM_FORCE:-0}" == 1 ]]; then
            echo "[start-vm] WARN: 可用内存+swap $((total_kb / 1024))MiB < guest ${GUEST_MEM_MB}MiB；MEM_FORCE=1，继续" >&2
        else
            echo "[start-vm] 可用内存+swap $((total_kb / 1024))MiB < guest ${GUEST_MEM_MB}MiB，拒绝启动" >&2
            echo "[start-vm] 请先停一台 VM；确认可承受 OOM 风险时可设 MEM_FORCE=1" >&2
            return 1
        fi
    elif (( total_kb < required_kb + margin_kb )); then
        echo "[start-vm] WARN: 启动后 host 余量将少于 ${margin_mb}MiB" >&2
    fi
}

check_memory_capacity
host_oom_protect_launcher "$VM_ID" || {
    echo "[start-vm] 宿主 OOM 保护失败；VM 未启动" >&2
    exit 1
}

[[ -x "$QEMU_BIN" ]] || { echo "QEMU 不存在或没执行权: $QEMU_BIN" >&2; exit 1; }
[[ -r "$OVMF_CODE" ]] || { echo "OVMF_CODE 不存在或不可读: $OVMF_CODE" >&2; exit 1; }
[[ -r "$OVMF_VARS" ]] || { echo "OVMF_VARS 不存在或不可读: $OVMF_VARS" >&2; exit 1; }
if [[ "$DRY_RUN" != 1 &&
      "${G11_HOST_BRIDGE_PRESENTATION,,}" == catalog &&
      -n "${CPU_HOST_BRIDGE_PRESENTATION_KEY:-}" ]]; then
    # The QEMU property alone is insufficient: OVMF must issue the matching
    # ExitBootServices APM handoff.  The builder publishes a hash-bound sidecar
    # so a stale/custom firmware fails before any VM resources are allocated.
    OVMF_FEATURES="${OVMF_CODE}.features"
    [[ -r "$OVMF_FEATURES" ]] || {
        echo "[start-vm] OVMF 缺少 G-11 CPU DMI2 功能清单: $OVMF_FEATURES" >&2
        echo "[start-vm] 运行 ./deploy/host/build-stealth-ovmf.sh，或仅诊断时设 G11_HOST_BRIDGE_PRESENTATION=off" >&2
        exit 1
    }
    OVMF_FEATURE_SCHEMA=$(sed -n 's/^schema=//p' "$OVMF_FEATURES")
    OVMF_FEATURE_SHA=$(sed -n 's/^sha256=//p' "$OVMF_FEATURES")
    OVMF_HANDOFF_FEATURE=$(
        sed -n 's/^g11_host_bridge_handoff=//p' "$OVMF_FEATURES"
    )
    if [[ "$OVMF_FEATURE_SCHEMA" != 1 ||
          "$OVMF_HANDOFF_FEATURE" != exit-boot-services-apm-0x47 ||
          ! "$OVMF_FEATURE_SHA" =~ ^[0-9a-f]{64}$ ]]; then
        echo "[start-vm] OVMF G-11 CPU DMI2 功能清单非法: $OVMF_FEATURES" >&2
        exit 1
    fi
    OVMF_ACTUAL_SHA=$(sha256sum -- "$OVMF_CODE" | awk '{print $1}')
    if [[ "$OVMF_ACTUAL_SHA" != "$OVMF_FEATURE_SHA" ]]; then
        echo "[start-vm] OVMF 与 G-11 CPU DMI2 功能清单不匹配" >&2
        echo "[start-vm] 运行 ./deploy/host/build-stealth-ovmf.sh 后重试" >&2
        exit 1
    fi
    unset OVMF_FEATURES OVMF_FEATURE_SCHEMA OVMF_FEATURE_SHA \
        OVMF_HANDOFF_FEATURE OVMF_ACTUAL_SHA
fi
dgame_qemu_ptracer_preflight || {
    echo "[start-vm] DGame/QEMU 内存读取兼容预检失败；VM 未启动" >&2
    exit 1
}

# Fail closed when the launcher has been updated but the local QEMU binary is
# still an older G-11 build that allows qemu-xhci to impersonate a physical
# PCH.  This catches the exact mixed source/binary state that can make Windows
# USBXHCI.SYS enable hardware-specific workarounds against the virtual model.
if [[ "$DRY_RUN" != 1 ]]; then
    if [[ "${G11_CHIPSET_PRESENTATION,,}" == catalog ]]; then
        if ! QEMU_LPC_HELP=$("$QEMU_BIN" -device ICH9-LPC,help 2>&1) ||
                ! grep -Eq '^  x-g11-chipset=<(str|string)>' \
                    <<<"$QEMU_LPC_HELP"; then
            echo "[start-vm] 当前 QEMU 缺少 G-11 芯片组 identity 白名单" >&2
            echo "[start-vm] 先运行 ./deploy/host/build-qemu.sh 增量重编，再重试" >&2
            exit 1
        fi
        unset QEMU_LPC_HELP
    fi
    if [[ "${G11_HOST_BRIDGE_PRESENTATION,,}" == catalog &&
          -n "${CPU_HOST_BRIDGE_PRESENTATION_KEY:-}" ]]; then
        if ! QEMU_MCH_HELP=$("$QEMU_BIN" -device mch,help 2>&1) ||
                ! grep -Eq '^  x-g11-host-bridge=<(str|string)>' \
                    <<<"$QEMU_MCH_HELP"; then
            echo "[start-vm] 当前 QEMU 缺少 G-11 CPU DMI2 inventory 白名单" >&2
            echo "[start-vm] 先运行 ./deploy/host/build-qemu.sh 增量重编，再重试" >&2
            exit 1
        fi
        unset QEMU_MCH_HELP
    fi
    if ! QEMU_XHCI_HELP=$("$QEMU_BIN" -device qemu-xhci,help 2>&1); then
        echo "[start-vm] QEMU 缺 qemu-xhci 支持" >&2
        exit 1
    fi
    if grep -Eq '^  x-pci-(vendor-id|device-id|revision)=' \
            <<<"$QEMU_XHCI_HELP"; then
        echo "[start-vm] 拒绝旧 G-11 QEMU：qemu-xhci 仍允许危险的 PCI ID 覆盖" >&2
        echo "[start-vm] 先运行 ./deploy/host/build-qemu.sh 增量重编，再重试" >&2
        exit 1
    fi
    unset QEMU_XHCI_HELP
    if [[ "$GUEST_NUMLOCK" == 1 || "$G11_USB_HID_LOW_LATENCY" == 1 ]]; then
        QEMU_KBD_EXTENSIONS_OK=1
        QEMU_KBD_HELP=""
        if ! QEMU_KBD_HELP=$("$QEMU_BIN" -device usb-kbd,help 2>&1); then
            QEMU_KBD_EXTENSIONS_OK=0
        fi
        if [[ "$GUEST_NUMLOCK" == 1 ]] &&
                { ! grep -q '^  x-force-numlock-on=<bool>' \
                      <<<"$QEMU_KBD_HELP" ||
                  ! grep -q '^  x-numlock-on-confirmed=<bool>' \
                      <<<"$QEMU_KBD_HELP"; }; then
            QEMU_KBD_EXTENSIONS_OK=0
        fi
        if [[ "$G11_USB_HID_LOW_LATENCY" == 1 ]] &&
                ! grep -q '^  x-low-latency=<bool>' \
                    <<<"$QEMU_KBD_HELP"; then
            QEMU_KBD_EXTENSIONS_OK=0
        fi
        if [[ "$QEMU_KBD_EXTENSIONS_OK" != 1 ]]; then
            echo "[start-vm] 当前 QEMU 缺少所请求的 G-11 USB HID 扩展" >&2
            echo "[start-vm] 先运行 ./deploy/host/build-qemu.sh 增量重编，再重试" >&2
            exit 1
        fi
        unset QEMU_KBD_HELP QEMU_KBD_EXTENSIONS_OK
    fi
    if [[ "$MODE" == install && "$INSTALL_MEDIA_BACKEND" == usb ]] &&
            ! "$QEMU_BIN" -device usb-storage,help >/dev/null 2>&1; then
        echo "[start-vm] QEMU 缺 usb-storage；无法使用默认高速安装光驱" >&2
        echo "[start-vm] 请重编 QEMU，或临时追加 --install-media ide" >&2
        exit 1
    fi
    if [[ -n "$G11_INIT_ISO" ]]; then
        if ! QEMU_USB_BOT_HELP=$("$QEMU_BIN" -device usb-bot,help 2>&1) ||
                ! grep -q '^  x-no-serial=<bool>' <<<"$QEMU_USB_BOT_HELP"; then
            echo "[start-vm] 当前 QEMU 缺少无虚构序列号的 usb-bot 初始化传输" >&2
            echo "[start-vm] 先运行 ./deploy/host/build-qemu.sh 增量重编，再重试" >&2
            exit 1
        fi
        unset QEMU_USB_BOT_HELP
        if ! QEMU_SCSI_CD_HELP=$("$QEMU_BIN" -device scsi-cd,help 2>&1) ||
                ! grep -q '^  vendor=<str>' <<<"$QEMU_SCSI_CD_HELP" ||
                ! grep -q '^  product=<str>' <<<"$QEMU_SCSI_CD_HELP" ||
                ! grep -q '^  ver=<str>' <<<"$QEMU_SCSI_CD_HELP"; then
            echo "[start-vm] 当前 QEMU 缺少可审核身份的 scsi-cd 初始化光驱" >&2
            exit 1
        fi
        unset QEMU_SCSI_CD_HELP
    fi
fi

STREAM_HELPER="$here/fb-shm-stream.sh"
STREAM_BIN="${QEMU_FB_SHM_STREAM_BIN:-$here/../build/qemu-fb-shm-stream}"
INSTANCE_RUN_DIR=$(vm_storage_instance_run_dir "$VM_ID")
DGAME_PREVIEW_SOCKET=$(dgame_preview_socket_path "$INSTANCE_RUN_DIR")
STREAM_SOCKET="$INSTANCE_RUN_DIR/fb-shm.sock"
if ((DGAME_PREVIEW_ENABLED)); then
    [[ "$DGAME_PREVIEW_SOCKET" == /* && ${#DGAME_PREVIEW_SOCKET} -lt 104 &&
       "$DGAME_PREVIEW_SOCKET" != *,* &&
       "$DGAME_PREVIEW_SOCKET" != *$'\n'* &&
       "$DGAME_PREVIEW_SOCKET" != *$'\r'* ]] ||
        stream_config_error \
            "DGame preview socket 路径必须是无逗号的短绝对路径"
fi
if ((STREAM_ENABLED)); then
    [[ "$STREAM_SOCKET" == /* && ${#STREAM_SOCKET} -lt 104 &&
       "$STREAM_SOCKET" != *,* && "$STREAM_SOCKET" != *$'\n'* &&
       "$STREAM_SOCKET" != *$'\r'* ]] ||
        stream_config_error "fb-shm socket 路径必须是无逗号的短绝对路径"
    if [[ "$DRY_RUN" != 1 ]]; then
        [[ -x "$STREAM_HELPER" ]] || {
            echo "[start-vm] 推流生命周期 helper 不可执行: $STREAM_HELPER" >&2
            exit 1
        }
        [[ -x "$STREAM_BIN" && -f "$STREAM_BIN" ]] || {
            echo "[start-vm] streamer 不可执行: $STREAM_BIN" >&2
            echo "[start-vm] 先构建: ninja -C build qemu-fb-shm-stream" >&2
            exit 1
        }
        command -v ffmpeg >/dev/null 2>&1 || {
            echo "[start-vm] 推流需要 ffmpeg: sudo apt install ffmpeg" >&2
            exit 1
        }
        if ! ffmpeg -hide_banner -encoders 2>/dev/null |
                awk -v encoder="$STREAM_ENCODER" \
                    '$2 == encoder { found = 1 } END { exit !found }'; then
            echo "[start-vm] 当前 ffmpeg 不提供编码器: $STREAM_ENCODER" >&2
            exit 1
        fi
        if ! STREAM_ENCODER_PROBE=$(
            timeout 10 ffmpeg -v error -nostdin \
                -f lavfi -i color=size=128x128:rate=1 \
                -frames:v 1 -an \
                -c:v "$STREAM_ENCODER" -b:v "$STREAM_BITRATE" \
                -g "$STREAM_GOP" -pix_fmt yuv420p \
                -preset "$STREAM_PRESET" -f null - 2>&1
        ); then
            echo "[start-vm] 编码器运行时自检失败: $STREAM_ENCODER" >&2
            printf '%s\n' "$STREAM_ENCODER_PROBE" | tail -5 >&2
            exit 1
        fi
        unset STREAM_ENCODER_PROBE
        [[ ! -L "$STREAM_SOCKET" ]] || {
            echo "[start-vm] 拒绝符号链接 fb-shm socket: $STREAM_SOCKET" >&2
            exit 1
        }
    fi
fi
if ((DGAME_PREVIEW_ENABLED || STREAM_ENABLED)); then
    if ! "$QEMU_BIN" -object fb-shm,help 2>&1 |
            grep -q '^  path=<string>'; then
        echo "[start-vm] QEMU 未编译可并行 SDL/GTK 的 fb-shm object" >&2
        exit 1
    fi
fi
if ((DGAME_PREVIEW_ENABLED)) && [[ "$DRY_RUN" != 1 ]] &&
        [[ -L "$DGAME_PREVIEW_SOCKET" ]]; then
    echo "[start-vm] 拒绝符号链接 DGame preview socket:" \
         "$DGAME_PREVIEW_SOCKET" >&2
    exit 1
fi

VM_PATTERN="qemu-system-x86_64.*-name[[:space:]]+vm${VM_ID}([,[:space:]]|$)"
vm_is_running() {
    pgrep -f "$VM_PATTERN" >/dev/null 2>&1
}

if [[ "$DRY_RUN" != 1 ]] && vm_is_running; then
    echo "[start-vm] vm${VM_ID} QEMU 已在跑 — 先 ./deploy/scripts/stop-vm.sh ${VM_ID}" >&2
    exit 1
fi

# TPM 默认 fail-closed：QEMU 有 TPM backend/device 还不够，host 还必须有
# swtpm + swtpm_setup，并成功启动该 VM 对应版本的独立 state/socket。
# dry-run 只规划完整 argv，不创建 state、socket、log 或 daemon。
export VM_TPM_ENABLED="${TPM:-1}"
export VM_TPM_PLATFORM_MANUFACTURER="${BOARD_BRAND:-OEM}"
export VM_TPM_PLATFORM_MODEL="${BOARD_MODEL:-Desktop}"
export VM_TPM_PLATFORM_VERSION="${BIOS_VER:-1.0}"
if ! vm_tpm_start "$VM_ID" "$QEMU_BIN" "$DRY_RUN"; then
    echo "[start-vm] TPM ${TPM_EFFECTIVE_VERSION} 初始化失败；安装: sudo apt install swtpm swtpm-tools" >&2
    echo "[start-vm] 仅在确实需要无 TPM 诊断时使用 --no-tpm" >&2
    exit 1
fi
start_vm_timing_mark tpm-ready
TPM_ARGS=( "${VM_TPM_QEMU_ARGS[@]}" )
TPM_LIFECYCLE_STARTED=0
if [[ "$DRY_RUN" != 1 && ${#TPM_ARGS[@]} -gt 0 ]]; then
    TPM_LIFECYCLE_STARTED=1
fi
STREAM_SIDECAR_OWNED=0
QMP_PROXY_ALIAS_OWNED=0
DGAME_COMPAT_ENDPOINTS_INSTALLED=0
G11_INIT_MEDIA_WATCH_PID=""

cleanup_dgame_compat_endpoints() {
    [[ "${DGAME_COMPAT_ENDPOINTS_INSTALLED:-0}" == 1 ]] || return 0
    DGAME_COMPAT_ENDPOINTS_INSTALLED=0
    dgame_endpoint_alias_remove "${DGAME_QMP_COMPAT:-}" "${QMP_SOCK:-}" || true
    dgame_endpoint_alias_remove "${DGAME_MON_COMPAT:-}" "${MON_SOCK:-}" || true
    dgame_endpoint_alias_remove \
        "${DGAME_FB_COMPAT:-}" "${DGAME_PREVIEW_SOCKET:-}" || true
    dgame_endpoint_alias_remove \
        "${DGAME_QMP_PROXY_COMPAT:-}" "${QMP_SOCK:-}" || true
}

install_dgame_compat_endpoints() {
    DGAME_COMPAT_ENDPOINTS_INSTALLED=1
    if ! dgame_endpoint_alias_install "$DGAME_QMP_COMPAT" "$QMP_SOCK" ||
       ! dgame_endpoint_alias_install "$DGAME_MON_COMPAT" "$MON_SOCK"; then
        cleanup_dgame_compat_endpoints
        return 1
    fi
    if ((DGAME_PREVIEW_ENABLED)) &&
            ! dgame_endpoint_alias_install \
                "$DGAME_FB_COMPAT" "$DGAME_PREVIEW_SOCKET"; then
        cleanup_dgame_compat_endpoints
        return 1
    fi
    if [[ "$PROXY" == 1 ]] &&
            ! dgame_endpoint_alias_install \
                "$DGAME_QMP_PROXY_COMPAT" "$QMP_SOCK"; then
        echo "[start-vm] DGame QMP broker 已占用或保留 proxy endpoint:" \
             "$DGAME_QMP_PROXY_COMPAT" >&2
    fi
}

cleanup_started_tpm() {
    if [[ "${G11_INIT_MEDIA_WATCH_PID:-}" =~ ^[1-9][0-9]*$ ]]; then
        if kill -0 "$G11_INIT_MEDIA_WATCH_PID" 2>/dev/null; then
            kill -TERM "$G11_INIT_MEDIA_WATCH_PID" 2>/dev/null || true
        fi
        wait "$G11_INIT_MEDIA_WATCH_PID" 2>/dev/null || true
        G11_INIT_MEDIA_WATCH_PID=""
    fi
    cleanup_dgame_compat_endpoints
    if [[ "${QMP_PROXY_ALIAS_OWNED:-0}" == 1 ]]; then
        QMP_PROXY_ALIAS_OWNED=0
        if [[ -L "${QMP_PROXY_SOCK:-}" &&
              "$(readlink -- "$QMP_PROXY_SOCK" 2>/dev/null || true)" == "${QMP_SOCK:-}" ]]; then
            rm -f -- "$QMP_PROXY_SOCK" 2>/dev/null || \
                echo "[start-vm] WARN: QMP alias 清理失败: $QMP_PROXY_SOCK" >&2
        fi
    fi
    if [[ "${STREAM_SIDECAR_OWNED:-0}" == 1 ]]; then
        STREAM_SIDECAR_OWNED=0
        "$STREAM_HELPER" stop "$VM_ID" >/dev/null 2>&1 || \
            echo "[start-vm] WARN: vm${VM_ID} 推流 sidecar 未能安全回收" >&2
    fi
    cpu_isolation_cleanup "$VM_ID" "${CPU_ISOLATION_STATE_FILE:-}"
    if [[ "${TPM_LIFECYCLE_STARTED:-0}" == 1 ]]; then
        TPM_LIFECYCLE_STARTED=0
        vm_tpm_cleanup "$VM_ID" || \
            echo "[start-vm] WARN: vm${VM_ID} swtpm 未能安全回收" >&2
    fi
    if [[ "${G11_VLAN_PREPARED:-0}" == 1 ]]; then
        if vm_is_running; then
            echo "[start-vm] vm${VM_ID} QEMU 仍运行，保留 ${VLAN_TAP_IF:-VLAN TAP}" >&2
        elif g11_vlan_cleanup_instance "$VM_ID" 1; then
            if g11_vlan_marker_clear "$G11_VLAN_RUNTIME_MARKER"; then
                G11_VLAN_PREPARED=0
            else
                echo "[start-vm] WARN: vm${VM_ID} VLAN marker 未能安全清理" >&2
            fi
        else
            echo "[start-vm] WARN: vm${VM_ID} VLAN TAP 清理失败，交由 downscript/stop-vm 重试" >&2
        fi
    fi
}
trap cleanup_started_tpm EXIT

case "$MODE" in
    vgpu-gtk|driver-install-gtk) WINDOW_BACKEND=gtk ;;
    vgpu-sdl|driver-install-sdl) WINDOW_BACKEND=sdl ;;
    *)                              WINDOW_BACKEND="" ;;
esac

# Keyboard ownership applies to every local QEMU window, including the GTK
# installer shown before a vGPU is attached.  Keep this separate from
# WINDOW_BACKEND, whose capability probes historically apply only to native
# vGPU mode.
case "$MODE" in
    install)    LOCAL_INPUT_BACKEND=${INSTALL_GFX_BACKEND,,} ;;
    rescue-gtk|vgpu-gtk|driver-install-gtk) LOCAL_INPUT_BACKEND=gtk ;;
    rescue-sdl|vgpu-sdl|driver-install-sdl) LOCAL_INPUT_BACKEND=sdl ;;
    *)          LOCAL_INPUT_BACKEND="" ;;
esac

# A graphic guest needs physical SDL scancodes, never host-side composition.
# Keep this in the launcher as a second layer for SDL 2.30 Wayland/XWayland
# implementations that can hand a key to IBus/Fcitx before QEMU sees the SDL
# event.  The environment changes are inherited only by this start-vm process
# tree; they do not change the desktop's global input-source setting.
if [[ "$LOCAL_INPUT_BACKEND" == sdl ]]; then
    # DGame 的 G-11 窗口发现合同使用 win10-N；QEMU 进程名继续保留 vmN，
    # 避免改变 ctl/stop 生命周期。X11 用 WM_CLASS，native Wayland
    # 用 xdg_toplevel app_id；SDL 2.30 对两者分别读取下列环境变量。
    export SDL_VIDEO_X11_WMCLASS="win10-${VM_ID}"
    export SDL_VIDEO_WAYLAND_WMCLASS="win10-${VM_ID}"
    QEMU_SDL_TITLE_FPS=${QEMU_SDL_TITLE_FPS,,}
    case "$QEMU_SDL_TITLE_FPS" in
        auto) ;;
        1|yes|true|on) QEMU_SDL_TITLE_FPS=1 ;;
        0|no|false|off) QEMU_SDL_TITLE_FPS=0 ;;
        *)
            echo "QEMU_SDL_TITLE_FPS 必须是 auto 或 0/1: $QEMU_SDL_TITLE_FPS" >&2
            exit 2
            ;;
    esac
    export QEMU_SDL_TITLE_FPS
    export QEMU_SDL_CURSOR_MODE
    case "${QEMU_SDL_ALLOW_HOST_DISPLAY_SLEEP,,}" in
        0|no|false|off)
            QEMU_SDL_ALLOW_HOST_DISPLAY_SLEEP=0
            ;;
        1|yes|true|on)
            QEMU_SDL_ALLOW_HOST_DISPLAY_SLEEP=1
            ;;
        *)
            echo "QEMU_SDL_ALLOW_HOST_DISPLAY_SLEEP 必须是 0 或 1: $QEMU_SDL_ALLOW_HOST_DISPLAY_SLEEP" >&2
            exit 2
            ;;
    esac
    export QEMU_SDL_ALLOW_HOST_DISPLAY_SLEEP
    if [[ "$DRY_RUN" != 1 ]]; then
        if [[ "$QEMU_SDL_ALLOW_HOST_DISPLAY_SLEEP" == 0 ]]; then
            echo "[start-vm] SDL 宿主防息屏已启用：窗口空闲不会触发宿主屏保/显示器休眠"
        else
            echo "[start-vm] SDL 允许宿主自动息屏（显式兼容模式）"
        fi
    fi
    if ((DGAME_PREVIEW_GPU_ENABLED)); then
        # 当前宿主的 DISPLAY/DRM provider 是 RX570；以后换 RX550 时仍由
        # 活跃 provider 自动选择，不按 PCI 地址或 GPU 型号写分支。
        # native EGL 失败时 QEMU 退回 SDL GL，DGame 随后退回 SHM。
        export QEMU_SDL_NATIVE_EGL=1
        if [[ -n "${DISPLAY:-}" && -z "${SDL_VIDEODRIVER:-}" ]]; then
            export SDL_VIDEODRIVER=x11
        fi
    fi
    configure_sdl_wayland_decor
    case "${QEMU_SDL_GNOME_ANIMATIONS,,}" in
        off|on)
            QEMU_SDL_GNOME_ANIMATIONS="${QEMU_SDL_GNOME_ANIMATIONS,,}"
            export QEMU_SDL_GNOME_ANIMATIONS
            ;;
        *)
            echo "QEMU_SDL_GNOME_ANIMATIONS 必须是 off 或 on: $QEMU_SDL_GNOME_ANIMATIONS" >&2
            exit 2
            ;;
    esac
    case "${QEMU_SDL_DISABLE_IBUS,,}" in
        auto)
            QEMU_SDL_IME_ENV="${XMODIFIERS:-} ${SDL_IM_MODULE:-} ${GTK_IM_MODULE:-}"
            case "${QEMU_SDL_IME_ENV,,}" in
                *ibus*|*fcitx*) QEMU_SDL_DISABLE_IBUS_ACTIVE=1 ;;
                *)              QEMU_SDL_DISABLE_IBUS_ACTIVE=0 ;;
            esac
            unset QEMU_SDL_IME_ENV
            ;;
        1|yes|true|on) QEMU_SDL_DISABLE_IBUS_ACTIVE=1 ;;
        0|no|false|off) QEMU_SDL_DISABLE_IBUS_ACTIVE=0 ;;
        *)
            echo "QEMU_SDL_DISABLE_IBUS 必须是 auto 或 0/1: $QEMU_SDL_DISABLE_IBUS" >&2
            exit 2
            ;;
    esac
    if (( QEMU_SDL_DISABLE_IBUS_ACTIVE )); then
        export XMODIFIERS=@im=none
        export SDL_IM_MODULE=none
        export IBUS_ADDRESS=/nonexistent
        if [[ "$DRY_RUN" != 1 ]]; then
            echo "[start-vm] SDL 宿主输入法已隔离：host 拼音/Fcitx 状态不会吞 guest 按键"
        fi
    fi
fi

if [[ "$LOCAL_INPUT_BACKEND" == sdl || "$LOCAL_INPUT_BACKEND" == gtk ]] &&
        should_tame_gnome_super; then
    export GNOME_SUPER_GUARD="$here/gnome-super-guard.sh"
    case "$LOCAL_INPUT_BACKEND" in
        sdl) export QEMU_SDL_TAME_GNOME=1 ;;
        gtk) export QEMU_GTK_TAME_GNOME=1 ;;
    esac
    if [[ "$DRY_RUN" != 1 ]]; then
        "$GNOME_SUPER_GUARD" restore-stale 2>/dev/null || true
        echo "[start-vm] ${LOCAL_INPUT_BACKEND^^} 宿主快捷键保护已启用：窗口聚焦且鼠标在窗口内时，Ctrl+Alt+Del/Super/Alt+Tab 交给 guest"
    fi
fi

if [[ -n "$WINDOW_BACKEND" ]]; then
    if [[ "$DRY_RUN" != 1 && -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
        echo "[start-vm] ${WINDOW_BACKEND} 原生窗口需要 DISPLAY 或 WAYLAND_DISPLAY" >&2
        exit 1
    fi
    if ! "$QEMU_BIN" -display help 2>&1 | grep -qx "$WINDOW_BACKEND"; then
        echo "[start-vm] QEMU 未编译 ${WINDOW_BACKEND} display backend" >&2
        exit 1
    fi
fi
if [[ "$MODE" == vgpu-gtk || "$MODE" == vgpu-sdl ]]; then
    if ! "$QEMU_BIN" -device vfio-pci-nohotplug,help 2>&1 | grep -q '^  ramfb='; then
        echo "[start-vm] QEMU 缺 vfio-pci-nohotplug,ramfb=on 支持" >&2
        exit 1
    fi
fi
case "$MODE" in
    rdp|vgpu-gtk|vgpu-sdl|driver-install-gtk|driver-install-sdl)
        if ! VGPU_ROOT_PORT_HELP=$(
                "$QEMU_BIN" -device pcie-root-port,help 2>&1
            ); then
            echo "[start-vm] QEMU 缺 pcie-root-port 支持" >&2
            exit 1
        fi
        for root_port_prop in x-speed x-width x-pci-vendor-id \
                x-pci-device-id x-pci-revision; do
            if ! grep -q "^  ${root_port_prop}=" <<<"$VGPU_ROOT_PORT_HELP"; then
                echo "[start-vm] QEMU pcie-root-port 缺 ${root_port_prop} 支持" >&2
                exit 1
            fi
        done
        unset VGPU_ROOT_PORT_HELP root_port_prop
        ;;
esac

if [[ "$MODE" == vgpu-sdl ]]; then
    if [[ ! "$QEMU_SDL_TARGET_FPS" =~ ^[0-9]+$ ]] ||
            (( 10#$QEMU_SDL_TARGET_FPS < 30 ||
               10#$QEMU_SDL_TARGET_FPS > 240 )); then
        echo "QEMU_SDL_TARGET_FPS 必须是 30..240: $QEMU_SDL_TARGET_FPS" >&2
        exit 2
    fi
    if [[ ! "$QEMU_SDL_INPUT_POLL_MS" =~ ^[0-9]+$ ]] ||
            (( 10#$QEMU_SDL_INPUT_POLL_MS < 1 ||
               10#$QEMU_SDL_INPUT_POLL_MS > 16 )); then
        echo "QEMU_SDL_INPUT_POLL_MS 必须是 1..16: $QEMU_SDL_INPUT_POLL_MS" >&2
        exit 2
    fi
    QEMU_SDL_TARGET_FPS=$((10#$QEMU_SDL_TARGET_FPS))
    QEMU_SDL_INPUT_POLL_MS=$((10#$QEMU_SDL_INPUT_POLL_MS))
    export QEMU_SDL_TARGET_FPS QEMU_SDL_INPUT_POLL_MS
    case "${QEMU_SDL_PRESENT_MODE,,}" in
        fixed|dynamic)
            QEMU_SDL_PRESENT_MODE="${QEMU_SDL_PRESENT_MODE,,}"
            export QEMU_SDL_PRESENT_MODE
            ;;
        *)
            echo "QEMU_SDL_PRESENT_MODE 必须是 fixed 或 dynamic: $QEMU_SDL_PRESENT_MODE" >&2
            exit 2
            ;;
    esac
    if [[ "$DRY_RUN" != 1 ]]; then
        if [[ "$QEMU_SDL_PRESENT_MODE" == fixed ]]; then
            echo "[start-vm] SDL Present 模式：固定 ${QEMU_SDL_TARGET_FPS}Hz（默认）"
        else
            echo "[start-vm] SDL Present 模式：动态（仅画面变化时 Present）"
        fi
        case "$QEMU_SDL_TITLE_FPS" in
            1)
                echo "[start-vm] SDL 输入轮询：${QEMU_SDL_INPUT_POLL_MS}ms；标题实时显示 Content/Present"
                ;;
            0)
                echo "[start-vm] SDL 输入轮询：${QEMU_SDL_INPUT_POLL_MS}ms；标题 FPS 已显式关闭"
                ;;
            auto)
                echo "[start-vm] SDL 输入轮询：${QEMU_SDL_INPUT_POLL_MS}ms；标题 FPS 自动策略（Wayland 静态、X11 实时）"
                ;;
        esac
        case "$QEMU_SDL_CURSOR_MODE" in
            auto)
                echo "[start-vm] SDL 光标策略：自动；仅确认 REGION 已合成拖窗箭头时隐藏 host fallback（显式模式）"
                ;;
            guest)
                echo "[start-vm] SDL 光标策略：guest sprite 优先；不可用时自动保留 host fallback"
                ;;
            host)
                echo "[start-vm] SDL 光标策略：始终使用 host fallback（默认，跟手优先）"
                ;;
        esac
    fi

    if [[ -r "$QEMU_SDL_WINDOWS_CURSOR" ]]; then
        export QEMU_SDL_WINDOWS_CURSOR
    elif [[ "$DRY_RUN" != 1 ]]; then
        echo "[start-vm] Windows cursor 资源不可读，使用内置 fallback: $QEMU_SDL_WINDOWS_CURSOR" >&2
    fi

fi

# VM 私有 OVMF_VARS（保留 UEFI 变量、Boot entry 等）
VARS_PRIV=$(vm_storage_nvram_path "$VM_ID")
if [[ ! -f "$VARS_PRIV" ]]; then
    if [[ "$DRY_RUN" == 1 ]]; then
        echo "[start-vm] DRY_RUN: 将创建私有 OVMF VARS: $VARS_PRIV"
    elif [[ -w "$(dirname "$VARS_PRIV")" ]]; then
        install -m 0644 "$OVMF_VARS" "$VARS_PRIV"
    else
        sudo install -m 0644 "$OVMF_VARS" "$VARS_PRIV"
    fi
fi

# 旧 install/std-vga 拓扑会把 ConOut 持久化成 00:01.0/GOP；生产拓扑里
# 00:01.0 已是 NVMe。native 用 ramfb 接管固件期输出，不保留直连
# mdev 的 PCI/GOP ConOut，避免 BDS 绕过 ramfb 提前 ConnectController(vGPU)。
# install/rescue 的标准 VGA 固定在 00:02.0，只保留该拓扑。
# 先留完整备份，BootOrder/安全启动等其它变量不动。--repair-display-vars
# 则强制只删 ConOut。
repair_ovmf_conout() {
    local expected_dev=$1 console_vars="" line="" pci_dev="" pci_num=0 stale=0
    local backup tmp

    [[ "$REPAIR_DISPLAY_VARS" != off ]] || return 0
    # dry-run 时私有 VARS 可能尚未创建；这种 fresh VARS 没有旧 PCI ConOut。
    [[ -f "$VARS_PRIV" ]] || return 0
    if ! command -v virt-fw-vars >/dev/null 2>&1; then
        [[ "$REPAIR_DISPLAY_VARS" == force ]] && {
            echo "[start-vm] --repair-display-vars 需要 virt-fw-vars" >&2
            return 1
        }
        echo "[start-vm] WARN: 没有 virt-fw-vars，跳过 UEFI ConOut 检查" >&2
        return 0
    fi

    if ! console_vars=$(LC_ALL=C virt-fw-vars -i "$VARS_PRIV" -p 2>/dev/null | \
        sed -n -E '/^ConOut(Dev)?[[:space:]]*:/p'); then
        echo "[start-vm] 无法解析 OVMF VARS: $VARS_PRIV" >&2
        return 1
    fi
    [[ -n "$console_vars" ]] || return 0

    if [[ "$REPAIR_DISPLAY_VARS" == force ]]; then
        stale=1
    else
        while IFS= read -r line; do
            # GetGopDevicePath() 成功时会写 PCI(...)/GOP，失败时也可能
            # 持久化 raw PCI(...)。两种都必须识别，否则旧路径仍会在
            # BmConsole 阶段绕过 ramfb，重新 ConnectController(vGPU)。
            if [[ "$line" =~ PCI\(dev=([0-9A-Fa-f]+):[0-9A-Fa-f]+\) ]]; then
                pci_dev="${BASH_REMATCH[1],,}"
                pci_num=$(( 16#$pci_dev ))
                # Serial ConOut 也会经过 00:1f.0/LPC，不能把所有 PCI
                # 路径都删掉。只处理明确的 /GOP，或本项目曾使用过的
                # 三个 raw display slot（01/02/10）。
                if [[ "$line" != *"/GOP"* ]] &&
                   (( pci_num != 0x01 && pci_num != 0x02 && pci_num != 0x10 )); then
                    continue
                fi
                if [[ -z "$expected_dev" ]] ||
                   (( pci_num != 16#$expected_dev )); then
                    stale=1
                    break
                fi
            fi
        done <<<"$console_vars"
    fi
    (( stale )) || return 0

    if [[ "$DRY_RUN" == 1 ]]; then
        echo "[start-vm] DRY_RUN: 将备份 VARS 并删除错位 ConOut/ConOutDev"
        return 0
    fi

    backup_dir=$(vm_storage_instance_nvram_backup_dir "$VM_ID")
    mkdir -p "$backup_dir"
    backup="$backup_dir/nvram.fd.bak-display-$(date +%Y%m%d-%H%M%S)-$$"
    tmp=$(mktemp "${VARS_PRIV}.tmp.XXXXXX") || return 1
    if ! cp -p --reflink=auto "$VARS_PRIV" "$backup"; then
        rm -f "$tmp"
        return 1
    fi
    if ! LC_ALL=C virt-fw-vars -i "$VARS_PRIV" -d ConOut -d ConOutDev -o "$tmp" \
            >/dev/null 2>&1; then
        rm -f "$tmp"
        return 1
    fi
    if ! chmod --reference="$VARS_PRIV" "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if ! mv -f "$tmp" "$VARS_PRIV"; then
        rm -f "$tmp"
        return 1
    fi
    echo "[start-vm] 已清理旧 UEFI ConOut；备份: $backup"
}

EXPECTED_CONOUT_DEV=""
case "$MODE" in
    # native 用 ramfb 做固件期 ConOut；旧拓扑持久化的 PCI/GOP 路径
    # 会让 BDS 直连 mdev，清掉后才能稳定走 ramfb。
    vgpu-gtk|vgpu-sdl) EXPECTED_CONOUT_DEV="" ;;
    install|no-gpu|rescue-sdl|rescue-gtk|driver-install-sdl|driver-install-gtk)
        EXPECTED_CONOUT_DEV=02
        ;;
esac
if ! repair_ovmf_conout "$EXPECTED_CONOUT_DEV"; then
    if [[ "$REPAIR_DISPLAY_VARS" == force ]]; then
        exit 1
    fi
    echo "[start-vm] WARN: UEFI ConOut 自动修复失败，继续启动" >&2
fi
start_vm_timing_mark nvram-ready

DISK=$(vm_storage_disk_path "$VM_ID")
if [[ "$DRY_RUN" != 1 && ! -r "$DISK" ]]; then
    echo "VM 磁盘不存在或不可读: $DISK" >&2
    exit 1
fi

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

# ─── CPU/主板运行时事实（来自已审核组件目录） ────────────────────────────
[[ "$CPU_CORES" =~ ^[1-9][0-9]*$ &&
   "$CPU_THREADS_PER_CORE" =~ ^[1-9][0-9]*$ &&
   "$CPU_VCPUS" =~ ^[1-9][0-9]*$ &&
   "$CPU_BASE_MHZ" =~ ^[1-9][0-9]*$ &&
   "$CPU_MAX_MHZ" =~ ^[1-9][0-9]*$ &&
   "$CPU_L1_CACHE_KB" =~ ^[1-9][0-9]*$ &&
   "$CPU_L2_CACHE_KB" =~ ^[1-9][0-9]*$ &&
   "$CPU_L3_CACHE_KB" =~ ^[1-9][0-9]*$ ]] || {
    echo "平台 CPU topology/cache 合同非法: ${PLATFORM}" >&2
    exit 2
}
(( CPU_VCPUS == CPU_CORES * CPU_THREADS_PER_CORE &&
   CPU_MAX_MHZ >= CPU_BASE_MHZ )) || {
    echo "平台 CPU 核心/线程/频率合同不一致: ${PLATFORM}" >&2
    exit 2
}
XHCI_DEVICE_ID=$BOARD_XHCI_DEVICE_ID

if [[ "$XHCI_IDENTITY_LEGACY" == 1 ]]; then
    XHCI_PCI_VENDOR_ID=$BOARD_XHCI_VENDOR_ID
    XHCI_PCI_DEVICE_ID=$XHCI_DEVICE_ID
    XHCI_PCI_REVISION=0x01
    XHCI_PCI_BUS=pcie.0
    XHCI_PCI_ADDR=0x6
fi

# The second occupied slot represents the Intel CT desktop network adapter;
# slot wiring and memory voltage/rank are board/memory catalog facts.
[[ -n "$PCIE_MAIN_SLOT" && -n "$PCIE_AUX_SLOT" &&
   "$PCIE_AUX_TYPE" =~ ^[0-9]+$ && "$PCIE_AUX_WIDTH" =~ ^[0-9]+$ &&
   "$PCIE_AUX_LENGTH" =~ ^[0-9]+$ &&
   "$MEM_VOLTAGE_MV" =~ ^[1-9][0-9]*$ && "$MEM_RANK" =~ ^[1-9][0-9]*$ ]] || {
    echo "平台 PCIe/内存运行时合同非法: ${PLATFORM}" >&2
    exit 2
}
# QEMU splits q35 RAM into one SMBIOS Type 17 record per populated DIMM.  The
# patched SMBIOS layer accepts a | delimited serial list.  New configs persist
# the exact comma-delimited guest sequence; old configs derive the same values
# from MEM_SN+slot without rewriting vm.conf.  Contract-v1 configs may predate
# MEM_SN; use the VM UUID as a stable seed instead of inventing a new identity
# on every boot.
MEM_SN_SOURCE=${MEM_SN-}
MEM_SN_SOURCE=${MEM_SN_SOURCE^^}
if g11_hardware_serial_memory_validate "$MEM_SN_SOURCE"; then
    if [[ -v MEM_SERIAL_LIST ]]; then
        g11_hardware_serial_memory_list_validate \
            "$MEM_SN_SOURCE" "$MEM_SLOTS" "$MEM_SERIAL_LIST" || {
            echo "[start-vm] MEM_SERIAL_LIST 与 MEM_SN+MEM_SLOTS 逐槽派生不一致" >&2
            exit 2
        }
    else
        MEM_SERIAL_LIST=$(g11_hardware_serial_memory_list_generate \
            "$MEM_SN_SOURCE" "$MEM_SLOTS") || {
            echo "[start-vm] 无法从旧 MEM_SN+MEM_SLOTS 稳定派生逐槽序列" >&2
            exit 2
        }
        echo "[start-vm] WARN: 旧配置缺少 MEM_SERIAL_LIST，已按 MEM_SN+slot 稳定派生（未改写 vm.conf）" >&2
    fi
else
    if [[ -v MEM_SERIAL_LIST ]]; then
        echo "[start-vm] 旧配置提供 MEM_SERIAL_LIST 但缺少可验证的 MEM_SN" >&2
        exit 2
    fi
    if [[ -z "$MEM_SN_SOURCE" ]]; then
        MEM_SN_SOURCE="${VM_UUID}:memory"
        echo "[start-vm] WARN: 旧配置缺少 MEM_SN，已用 VM_UUID 稳定派生" >&2
    else
        echo "[start-vm] WARN: 旧 MEM_SN 不是有效非保留 JEDEC 序列号，已稳定归一化" >&2
    fi
    legacy_mem_sn=$(g11_hardware_serial_memory_stable_from_seed \
        "$MEM_SN_SOURCE") || {
        echo "[start-vm] 无法为旧配置稳定派生合法 DIMM 序列号" >&2
        exit 2
    }
    MEM_SERIAL_LIST=$(g11_hardware_serial_memory_list_generate \
        "$legacy_mem_sn" "$MEM_SLOTS") || {
        echo "[start-vm] 无法为旧配置稳定派生完整逐槽 DIMM 序列" >&2
        exit 2
    }
fi
MEM_SERIALS=${MEM_SERIAL_LIST//,/|}
unset MEM_SN_SOURCE legacy_mem_sn

# X79 is quad-channel-capable at every capacity.  Two, three and four matching
# sticks truthfully occupy channels A/B, A/B/C and A/B/C/D.  Any second socket
# per channel is emitted as empty after the populated records.  Older archived
# four-slot boards retain their historical A2/B2 population order.
if [[ "$BOARD_CHIPSET" == X79 && "$MEM_BOARD_SLOTS" == 8 && "$MEM_SLOTS" == 2 ]]; then
    MEM_LOCATORS='DIMM_A1|DIMM_B1|DIMM_C1|DIMM_D1|DIMM_A2|DIMM_B2|DIMM_C2|DIMM_D2'
    MEM_BANKS='P0 CHANNEL A|P0 CHANNEL B|P0 CHANNEL C|P0 CHANNEL D|P0 CHANNEL A|P0 CHANNEL B|P0 CHANNEL C|P0 CHANNEL D'
elif [[ "$BOARD_CHIPSET" == X79 && "$MEM_BOARD_SLOTS" == 8 && "$MEM_SLOTS" == 3 ]]; then
    MEM_LOCATORS='DIMM_A1|DIMM_B1|DIMM_C1|DIMM_D1|DIMM_A2|DIMM_B2|DIMM_C2|DIMM_D2'
    MEM_BANKS='P0 CHANNEL A|P0 CHANNEL B|P0 CHANNEL C|P0 CHANNEL D|P0 CHANNEL A|P0 CHANNEL B|P0 CHANNEL C|P0 CHANNEL D'
elif [[ "$BOARD_CHIPSET" == X79 && "$MEM_BOARD_SLOTS" == 8 && "$MEM_SLOTS" == 4 ]]; then
    MEM_LOCATORS='DIMM_A1|DIMM_B1|DIMM_C1|DIMM_D1|DIMM_A2|DIMM_B2|DIMM_C2|DIMM_D2'
    MEM_BANKS='P0 CHANNEL A|P0 CHANNEL B|P0 CHANNEL C|P0 CHANNEL D|P0 CHANNEL A|P0 CHANNEL B|P0 CHANNEL C|P0 CHANNEL D'
elif [[ "$BOARD_CHIPSET" == X79 && "$MEM_BOARD_SLOTS" == 4 &&
        ( "$MEM_SLOTS" == 2 || "$MEM_SLOTS" == 3 || "$MEM_SLOTS" == 4 ) ]]; then
    MEM_LOCATORS='DIMM_A1|DIMM_B1|DIMM_C1|DIMM_D1'
    MEM_BANKS='P0 CHANNEL A|P0 CHANNEL B|P0 CHANNEL C|P0 CHANNEL D'
elif (( MEM_BOARD_SLOTS == 4 && MEM_SLOTS == 2 )); then
    MEM_LOCATORS='DIMM_A2|DIMM_B2|DIMM_A1|DIMM_B1'
    MEM_BANKS='P0 CHANNEL A|P0 CHANNEL B|P0 CHANNEL A|P0 CHANNEL B'
elif (( MEM_BOARD_SLOTS == 4 && MEM_SLOTS == 4 )); then
    MEM_LOCATORS='DIMM_A1|DIMM_A2|DIMM_B1|DIMM_B2'
    MEM_BANKS='P0 CHANNEL A|P0 CHANNEL A|P0 CHANNEL B|P0 CHANNEL B'
elif (( MEM_BOARD_SLOTS == 2 && MEM_SLOTS == 2 )); then
    MEM_LOCATORS='DIMM_A1|DIMM_B1'
    MEM_BANKS='P0 CHANNEL A|P0 CHANNEL B'
else
    MEM_LOCATORS=DIMM
    MEM_BANKS='P0 CHANNEL'
fi

case "${MEM_FAMILY:-}" in
    DDR3)
        export QEMU_SPD_TYPE=$MEM_FAMILY
        export QEMU_SPD_MODULE_MB_LIST=$MEM_MODULE_MB_LIST
        unset QEMU_SPD_MODULE_MB
        export QEMU_SPD_SPEED_MT=$MEM_SPEED
        export QEMU_SPD_SLOTS=$MEM_SLOTS
        export QEMU_SPD_RANK_LIST=$MEM_RANK_LIST
        export QEMU_SPD_DEVICE_WIDTH_LIST=$MEM_DEVICE_WIDTH_LIST
        export QEMU_SPD_MODULE_MFR_JEP106_LIST=$MEM_MODULE_MFR_JEP106_LIST
        export QEMU_SPD_DRAM_MFR_JEP106_LIST=$MEM_DRAM_MFR_JEP106_LIST
        export QEMU_SPD_SERIAL_LIST=$MEM_SERIAL_LIST
        export QEMU_SPD_PART_LIST=$MEM_MODEL_LIST
        ;;
    DDR4)
        export QEMU_SPD_TYPE=$MEM_FAMILY
        export QEMU_SPD_MODULE_MB_LIST=$MEM_MODULE_MB_LIST
        unset QEMU_SPD_MODULE_MB
        export QEMU_SPD_SPEED_MT=$MEM_SPEED
        export QEMU_SPD_SLOTS=$MEM_SLOTS
        unset QEMU_SPD_RANK_LIST QEMU_SPD_DEVICE_WIDTH_LIST \
            QEMU_SPD_MODULE_MFR_JEP106_LIST \
            QEMU_SPD_DRAM_MFR_JEP106_LIST QEMU_SPD_SERIAL_LIST \
            QEMU_SPD_PART_LIST
        ;;
    *)
        unset QEMU_SPD_TYPE QEMU_SPD_MODULE_MB QEMU_SPD_MODULE_MB_LIST \
            QEMU_SPD_SPEED_MT QEMU_SPD_SLOTS QEMU_SPD_RANK_LIST \
            QEMU_SPD_DEVICE_WIDTH_LIST QEMU_SPD_MODULE_MFR_JEP106_LIST \
            QEMU_SPD_DRAM_MFR_JEP106_LIST QEMU_SPD_SERIAL_LIST \
            QEMU_SPD_PART_LIST
        ;;
esac

# ─── SMBIOS 伪装字符串拼装 ───────────────────────────────────────────────────
SMBIOS=()
SMBIOS+=( -smbios "type=0,vendor=American Megatrends Inc.,version=${BIOS_VER},date=${BIOS_DATE},uefi=on" )
SMBIOS+=( -smbios "type=1,manufacturer=${BOARD_BRAND},product=${BOARD_MODEL},version=System Version,serial=${SYS_SN},uuid=${VM_UUID},sku=SKU,family=${BOARD_BRAND}" )
# Must pass version= explicitly. Without it, smbios_set_defaults() inherits
# version from mc->name, i.e. "pc-q35-11.0", which is a textbook QEMU leak.
BOARD_RUNTIME_REVISION=${BOARD_REVISION:-${BOARD_VERSION:-1.0}}
SMBIOS+=( -smbios "type=2,manufacturer=${BOARD_BRAND},product=${BOARD_MODEL},version=${BOARD_RUNTIME_REVISION},serial=${MB_SN},asset=Default string,location=Default string" )
SMBIOS+=( -smbios "type=3,manufacturer=${BOARD_BRAND},version=1.0,serial=${CHASSIS_SN},asset=Default string,sku=Default string,chassis_type=3" )
# type 4 (Processor) — 真机里 wmic cpu get 的字段。serial 空是 Intel 惯例；asset
# "To Be Filled By O.E.M." 也是常见零售机主板 BIOS 默认字串。
SMBIOS+=( -smbios "type=4,sock_pfx=CPU,manufacturer=Intel(R) Corporation,version=${CPU_BRAND_STRING},max-speed=${CPU_MAX_MHZ},current-speed=${CPU_BASE_MHZ},serial=To Be Filled By O.E.M.,asset=To Be Filled By O.E.M.,part=${CPU_PART},processor-family=${CPU_SMBIOS_FAMILY},processor-characteristics=${CPU_PROCESSOR_CHARACTERISTICS},external-clock=100,voltage=0x8C,processor-upgrade=${CPU_SOCKET_UPGRADE}" )
# type 7 (Cache) follows the selected SKU: Pentium/i3 are 2-core with
# 128 KiB aggregate L1, 512 KiB L2 and 3 MiB LLC; i5 profiles are 4-core with
# 256 KiB L1, 1 MiB L2 and 6 MiB LLC.
SMBIOS+=( -smbios "type=7,socket_designation=L1 Cache,level=1,installed_size=${CPU_L1_CACHE_KB},max_size=${CPU_L1_CACHE_KB},associativity=7,cache_type=5" )
SMBIOS+=( -smbios "type=7,socket_designation=L2 Cache,level=2,installed_size=${CPU_L2_CACHE_KB},max_size=${CPU_L2_CACHE_KB},associativity=${CPU_L2_ASSOC},cache_type=5" )
SMBIOS+=( -smbios "type=7,socket_designation=L3 Cache,level=3,installed_size=${CPU_L3_CACHE_KB},max_size=${CPU_L3_CACHE_KB},associativity=${CPU_L3_ASSOC},cache_type=5" )
# type 9 (System Slots) — 主显卡槽代际跟随 CPU PCIe 控制器；第二个已占用槽严格
# 跟随主板实际布线，用于解释 Intel CT add-in NIC。
#   slot_type: 0xB1 = PCI Express Gen 3 (width comes from data_bus_width)
#              0xAB = PCI Express Gen 2 (width comes from data_bus_width)
#   current_usage: 0x03 Available, 0x04 In Use
#   slot_length: 0x03 Short, 0x04 Long
#   chars1 0x0C (3.3V + shared opening); chars2 0x01 (PME)
case "$CPU_PCIE_GENERATION" in
    2)
        PCIE_MAIN_SLOT_TYPE=171
        GPU_ROOT_PORT_SPEED=5
        ;;
    3)
        PCIE_MAIN_SLOT_TYPE=177
        GPU_ROOT_PORT_SPEED=8
        ;;
    *)
        echo "CPU PCIe 代际未经审核: ${CPU_PCIE_GENERATION:-<empty>}" >&2
        exit 2
        ;;
esac
SMBIOS+=( -smbios "type=9,slot_designation=${PCIE_MAIN_SLOT},slot_type=${PCIE_MAIN_SLOT_TYPE},slot_data_bus_width=13,current_usage=4,slot_length=4,slot_id=1,slot_characteristics1=12,slot_characteristics2=1" )
SMBIOS+=( -smbios "type=9,slot_designation=${PCIE_AUX_SLOT},slot_type=${PCIE_AUX_TYPE},slot_data_bus_width=${PCIE_AUX_WIDTH},current_usage=4,slot_length=${PCIE_AUX_LENGTH},slot_id=2,slot_characteristics1=12,slot_characteristics2=1" )
# type 11 (OEM Strings) — 真机 BIOS 常有若干无意义字符串，我们塞 2-3 条像 ASUS/MSI
# 出厂机默认字符串那样。"Default string" 大量真机里会出现。
SMBIOS+=( -smbios "type=11,value=Default string" )
SMBIOS+=( -smbios "type=11,value=To Be Filled By O.E.M." )
if [[ -n "$VGPU_GUEST_FINISH_TARGET" ]]; then
    SMBIOS+=( -smbios "type=11,value=QEMU_VGPU_TARGET=${VGPU_GUEST_FINISH_TARGET}" )
fi
if [[ -n "$VGPU_PORTABLE_PROFILE_CLAIM" ]]; then
    SMBIOS+=( -smbios "type=11,value=${VGPU_PORTABLE_PROFILE_CLAIM}" )
fi
# Type 16 报告物理主板的全部插槽/最大容量；Type 17 另外报告
# 两条已安装 DIMM 及其余空槽。定位器、bank 和 serial 都用 | 分隔。
SMBIOS+=( -smbios "type=16,max-capacity=${MEM_MAX_CAPACITY_GB}G,num-devices=${MEM_BOARD_SLOTS}" )
SMBIOS+=( -smbios "type=17,loc_pfx=${MEM_LOCATORS},bank=${MEM_BANKS},manufacturer=${MEM_BRAND},part=${MEM_MODEL_LIST//,/|},serial=${MEM_SERIALS},speed=${MEM_SPEED},memtype=${MEM_TYPE_BYTE},typedetail=0x80,width=${MEM_WIDTH},totalwidth=${MEM_WIDTH},rank=${MEM_RANK},rank-list=${MEM_RANK_LIST//,/|},voltage=${MEM_VOLTAGE_MV}" )

# ─── CPU / machine 参数 ─────────────────────────────────────────────────────
# kvm=off 关 KVM 签名；x-hv-stealth=on 关 HYPERVISOR bit；
# +invtsc 让 rdtsc 对 guest 稳定。
#
# New profiles always use enforce=on.  Immutable older Skylake/Coffee Lake
# profiles may use enforce=off only after the bounded preflight proved that
# the failure is a host-feature gap and that compatibility realization works.
CPU_ARGS="${CPU_MODEL},enforce=${CPU_ENFORCE_MODE},kvm=off,x-hv-stealth=on,+invtsc,vmx=off,hypervisor=off,vmware-cpuid-freq=off"
[[ -z "$G11_TSC_QEMU_OPTION" ]] || CPU_ARGS+=",${G11_TSC_QEMU_OPTION}"
MACHINE_ARGS="q35,accel=kvm,vmport=off,smm=on,kernel-irqchip=split,hpet=off,i8042=off"
MACHINE_ARGS+=",x-oem-id=ALASKA,x-oem-table-id=A M I"  # 覆盖 QEMU ACPI OEM ID (QEMU→AMI)

# ─── 网络 ───────────────────────────────────────────────────────────────────
NIC_ARG="e1000e,netdev=net0,mac=${VM_MAC},subsys_ven=0x8086,subsys=0xA01F,bus=pcie.0,addr=0x4"
if [[ -n "$VLAN_ID" ]]; then
    NET_ARGS=(
        -netdev "tap,id=net0,ifname=${VLAN_TAP_IF},script=no,downscript=${G11_VLAN_DOWNSCRIPT}"
        -device "$NIC_ARG"
    )
else
    NET_ARGS=(
        -netdev "bridge,id=net0,br=${BR0},helper=${G11_BRIDGE_HELPER}"
        -device "$NIC_ARG"
    )
fi

# ─── 存储 (NVMe 呈现 SSD 品牌/型号/序列号) ─────────────────────────────────
# SATA profile 挂到 Q35 板载 ICH9-AHCI；NVMe profile 使用 PCIe NVMe controller。
DRIVE_ARGS=()
DRIVE_ARGS+=( -drive "file=${DISK},if=none,id=ssd0,discard=unmap,detect-zeroes=unmap,format=qcow2,cache=none,aio=${QEMU_DISK_AIO_SELECTED}" )
# SSD_MODEL 就是 profile 的最终 Identify model，不再额外拼接品牌。
# bootindex=2：CDROM (1) 优先于 NVMe (2)。Windows ISO 的 efi loader
# 会显示 "Press any key to boot from CD or DVD..." 倒计时 5s：
#   按键   → 启动 ISO 装机
#   不按键 → loader 自然退出 → OVMF fallback 到 NVMe → 进 Windows
# 这样装完后即使保持 install 模式，下次 reboot 不按键就直接进系统。
# 固定 00:01.0：避免在 std-vga/vGPU 模式间切换时自动分配漂移，
# 使已持久化的 NVMe Boot#### device path 继续有效。
: "${SSD_FIRMWARE_REV:=1.0}"
case "$SSD_INTERFACE" in
    sata)
        DRIVE_ARGS+=( -device "ide-hd,drive=ssd0,bus=ide.1,unit=0,bootindex=2,serial=${SSD_SN},model=${SSD_MODEL},ver=${SSD_FIRMWARE_REV},logical_block_size=${SSD_LOGICAL_BLOCK_SIZE},physical_block_size=${SSD_PHYSICAL_BLOCK_SIZE},rotation_rate=1" )
        ;;
    nvme)
        NVME_DEVICE="nvme,drive=ssd0,bootindex=2,serial=${SSD_SN},model-number=${SSD_MODEL},firmware-rev=${SSD_FIRMWARE_REV},logical_block_size=${SSD_LOGICAL_BLOCK_SIZE},physical_block_size=${SSD_PHYSICAL_BLOCK_SIZE},id=nvme0,bus=pcie.0,addr=0x1"
        case "$SSD_CONTROLLER_PROFILE" in
            samsung) NVME_DEVICE+=",use-samsung-id=on" ;;
            intel)   NVME_DEVICE+=",use-intel-id=on" ;;
            wd)      NVME_DEVICE+=",use-wd-id=on" ;;
        esac
        DRIVE_ARGS+=( -device "$NVME_DEVICE" )
        ;;
esac

# ─── 安装光驱：普通启动默认零光驱  ─────────────────────
# Q35 的默认 ide-cd 也必须被抑制；否则即使没有 ISO，Windows 仍会看到
# 一台空光驱。所有模式先传递一个无害的全局属性来阻止默认设备，只有
# --install 才会在启动 argv 里创建光驱。日常 ISO 由 optical-media.sh
# 在已运行 VM 上热插 usb-bot + scsi-cd；eject 会删除整台手动光驱。
# --install 默认把 Windows ISO 作为临时 xHCI USB BOT 介质挂载。OVMF/WinPE 会把
# READ(10) 合并到约 64 KiB，避免 ICH9-AHCI ATAPI PIO 每 2048B 一次的线程池
# 往返；VM10 实测 boot.wim 请求从 367914 次降到 12090 次。`ide` 仅保留为
# 显式兼容回退。USB 默认路径由 helper=bootindex 1 引导，系统盘固定为 2，
# Windows USB 光盘使用 3 让 OVMF 主动连接其文件系统；IDE 回退光驱=1
# 引导。helper、Windows ISO 和应答 ISO 只存在于 install 模式。默认 USB
# 传输与 helper/应答盘保持 generic；显式 IDE 回退才使用审核的 ODD 目录身份。
INSTALL_MEDIA_DEVICE_ARGS=()
DRIVE_ARGS+=( -global ide-cd.bootindex=-1 )
if [[ "$MODE" == "install" ]]; then
    [[ -f "$ISO" ]] || { echo "ISO 不存在: $ISO" >&2; exit 1; }
    case "$INSTALL_MEDIA_BACKEND" in
        usb)
            DRIVE_ARGS+=( -drive "file=${ISO},if=none,id=odd0,media=cdrom,readonly=on,format=raw" )
            # qemu-xhci is created later in INPUT_ARGS, so only the backend
            # belongs in DRIVE_ARGS.  A small source-built FAT helper is the
            # firmware boot target; it then chainloads the Windows USB CD-ROM
            # after confirming sources/boot.wim.  Frontends are appended after
            # xHCI exists, on stable ports 3 and 4.
            DRIVE_ARGS+=( -drive "file=${INSTALL_BOOT_HELPER},if=none,id=installboot,format=raw,readonly=on" )
            # Keep the ISO frontend before the helper frontend.  Combined
            # with ISO bootindex=3 this makes OVMF connect its SimpleFS before
            # launching helper=1; reversing the device order reproduces a
            # fresh-NVRAM Shell fallback with zero odd0 reads.
            INSTALL_MEDIA_DEVICE_ARGS+=(
                -device "usb-storage,id=odd0-usb,drive=odd0,bus=xhci.0,port=3,bootindex=3,removable=on"
                -device "usb-storage,id=installboot-usb,drive=installboot,bus=xhci.0,port=4,bootindex=1,removable=on"
            )
            ;;
        ide)
            DRIVE_ARGS+=( -drive "file=${ISO},if=none,id=install-odd-media,media=cdrom,readonly=on,format=raw" )
            DRIVE_ARGS+=( -device "ide-cd,id=install-odd-ide,drive=install-odd-media,bus=ide.0,unit=0,model=${ODD_MODEL},ver=${ODD_FIRMWARE_REV},serial=,bootindex=1" )
            ;;
    esac
    if [[ -n "$UNATTEND_ISO" ]]; then
        DRIVE_ARGS+=( -drive "file=${UNATTEND_ISO},if=none,id=answer0,media=cdrom,readonly=on,format=raw" )
        # ide.1 may contain a SATA system disk; use a separate AHCI port.
        DRIVE_ARGS+=( -device "ide-cd,drive=answer0,bus=ide.2" )
    fi
elif [[ -n "$G11_INIT_ISO" ]]; then
    # Private Sysprep clones receive their exact UUID/profile-bound payload on
    # a reviewed USB-BOT/SCSI optical stack.  It is not a normal-mode device:
    # after the coordinator copies and ejects the manifest-pinned payload, a
    # host QMP watcher hot-removes both the SCSI device and its USB transport
    # before the internal verification reboot.
    G11_INIT_ODD_VENDOR=${ODD_MODEL%% *}
    G11_INIT_ODD_PRODUCT=${ODD_MODEL#* }
    [[ "$G11_INIT_ODD_VENDOR" != "$ODD_MODEL" &&
       ${#G11_INIT_ODD_VENDOR} -le 8 && ${#G11_INIT_ODD_PRODUCT} -le 16 ]] || {
        echo "[start-vm] 光驱目录型号无法映射到 SCSI INQUIRY: $ODD_MODEL" >&2
        exit 1
    }
    DRIVE_ARGS+=( -drive "file=${G11_INIT_ISO},if=none,id=g11-init-odd-media,media=cdrom,readonly=on,format=raw" )
    INSTALL_MEDIA_DEVICE_ARGS+=(
        -device "usb-bot,id=g11-init-odd-usb,bus=xhci.0,port=3,x-no-serial=on"
        -device "scsi-cd,id=g11-init-odd,drive=g11-init-odd-media,bus=g11-init-odd-usb.0,vendor=${G11_INIT_ODD_VENDOR},product=${G11_INIT_ODD_PRODUCT},ver=${ODD_FIRMWARE_REV},serial=,bootindex=-1"
    )
fi

# ─── 图形 / vGPU ──────────────────────────────────────────────────────────
GFX_ARGS=()

attach_vgpu_root_port() {
    local gpu_link_width=${GPU_PCIE_WIDTH:-}
    case "$gpu_link_width" in
        1|2|4|8|16|32) ;;
        *)
            echo "[start-vm] canonical GPU profile 缺少合法 PCIe 链路宽度: $GPU_PROFILE/${gpu_link_width:-missing}" >&2
            return 1
            ;;
    esac
    # VFIO turns a PCIe endpoint directly attached to pcie.0 into an RC
    # integrated endpoint and clears its Link Capability/Status registers.
    # A real desktop GPU sits below a root port.  Keep the bridge at the old
    # 00:10.0 location and put the GPU at 01:00.0 so the endpoint retains its
    # PCIe capability.  GTX 750 Ti/1050 use x16; GT 1030 is electrically x4.
    GFX_ARGS+=(
        -device "pcie-root-port,id=gpu-root-port,bus=pcie.0,addr=0x10,port=0x10,chassis=1,slot=1,hotplug=off,x-speed=${GPU_ROOT_PORT_SPEED},x-width=${gpu_link_width},x-pci-vendor-id=0x8086,x-pci-device-id=${GPU_ROOT_PORT_DEVICE_ID},x-pci-revision=${GPU_ROOT_PORT_REVISION}"
    )
}

allocate_vgpu() {
    local mdev_identity_name=""
    local identity_backend_available=0
    local -a mdev_identity_args=()
    local -a mdev_identity_contract_args=()
    [[ "$SPOOF_MODE" == B || "$SPOOF_MODE" == A ]] && \
        mdev_identity_name=$GPU_NAME
    if [[ -n "$mdev_identity_name" ]]; then
        # Fixed placeholders make this one atomic per-VM contract:
        # optional internal PCI pair, optional FRL, the always-complete RM
        # framebuffer tuple. Outer QEMU PCI identity stays separate.
        mdev_identity_contract_args=("" "" "")
        if (( VGPU_MDEV_INTERNAL_PCI_ACTIVE )); then
            mdev_identity_contract_args[0]=$VGPU_MDEV_INTERNAL_VDEV_ID
            mdev_identity_contract_args[1]=$VGPU_MDEV_INTERNAL_PDEV_ID
        fi
        if (( VGPU_MDEV_FRL_OVERRIDE_ACTIVE )); then
            mdev_identity_contract_args[2]=$VGPU_MDEV_FRL_ENABLED
        fi
        mdev_identity_contract_args+=(
            "$GPU_MEMORY_BUS_BITS"
            "$GPU_MEMORY_TYPE_NVAPI"
            "$GPU_MEMORY_VENDOR_RM"
        )
    fi
    if [[ "$DRY_RUN" == 1 ]]; then
        MDEV_UUID=$VM_UUID
        return 0
    fi
    # A stable mdev UUID lets vgpu_unlock-rs apply [mdev."UUID"] names on the
    # host.  This keeps NVIDIA Control Panel per-VM without guest DLLs/services.
    MDEV_UUID=$VM_UUID
    if [[ -f "$VGPU_UNLOCK_PROFILE_OVERRIDE_CONFIG" &&
          ! -L "$VGPU_UNLOCK_PROFILE_OVERRIDE_CONFIG" &&
          -r "$VGPU_UNLOCK_PROFILE_OVERRIDE_CONFIG" &&
          -f "$VGPU_MDEV_IDENTITY_HELPER" &&
          -r "$VGPU_MDEV_IDENTITY_HELPER" ]]; then
        identity_backend_available=1
    fi
    if (( VGPU_MDEV_INTERNAL_PCI_ACTIVE || VGPU_MDEV_FRL_OVERRIDE_ACTIVE )); then
        if [[ "$VGPU_MDEV_IDENTITY_MODE" == off ]]; then
            echo "[start-vm] per-mdev PCI/FRL override 已显式启用，但 VGPU_MDEV_IDENTITY_MODE=off" >&2
            return 1
        fi
        if (( identity_backend_available == 0 )); then
            echo "[start-vm] per-mdev PCI/FRL override 已显式启用，但 host identity 后端不可用" >&2
            return 1
        fi
    fi
    case "$VGPU_MDEV_IDENTITY_MODE" in
        auto)
            if (( identity_backend_available )); then
                mdev_identity_args=(
                    "$mdev_identity_name"
                    "${mdev_identity_contract_args[@]}"
                )
            elif [[ -n "$mdev_identity_name" ]]; then
                echo "[start-vm] 警告: host per-mdev 名称后端不可用；保留 driver/type 产品名" >&2
            elif [[ -e "$VGPU_UNLOCK_PROFILE_OVERRIDE_CONFIG" ]]; then
                echo "[start-vm] 警告: 无法清理该 VM 的旧 per-mdev 名称项" >&2
            fi
            ;;
        required)
            # Passing an empty fourth argument in SPOOF_MODE=off also removes
            # a stale override; the library fails closed if the backend is absent.
            mdev_identity_args=(
                "$mdev_identity_name"
                "${mdev_identity_contract_args[@]}"
            )
            ;;
        off)
            # On an unlock host, disabling identity also removes a stale
            # generated section.  Official V100 hosts have no backend and skip it.
            (( identity_backend_available == 0 )) || mdev_identity_args=("")
            ;;
        *)
            echo "[start-vm] VGPU_MDEV_IDENTITY_MODE 必须是 auto|required|off: $VGPU_MDEV_IDENTITY_MODE" >&2
            return 1
            ;;
    esac
    # Install the EXIT guard before allocation.  pending-new protects the
    # create-to-return window inside mdev_allocate; pending-existing prevents
    # an API failure or signal from deleting a stale UUID that predated this
    # launch.  Only a successful allocation promotes either state to active.
    MDEV_RECOVERY_FILE=""
    if [[ -L "$MDEV_DEVICES_DIR/$MDEV_UUID" ]]; then
        MDEV_ALLOCATION_STATE=pending-existing
    else
        MDEV_ALLOCATION_STATE=pending-new
    fi
    cleanup_allocated_mdev() {
        mdev_cleanup_allocation_state "$MDEV_ALLOCATION_STATE" \
            "$MDEV_UUID" "$MDEV_RECOVERY_FILE" || true
        cleanup_started_tpm
    }
    trap cleanup_allocated_mdev EXIT
    # Prewrite the marker only for a new UUID.  A hard interruption after the
    # kernel create then always leaves enough information for host recovery.
    if [[ "$MDEV_ALLOCATION_STATE" == pending-new ]]; then
        if ! MDEV_RECOVERY_FILE=$(vm_storage_run_preferred_path "$VM_ID" mdev); then
            echo "mdev recovery 路径解析失败" >&2
            return 1
        fi
        if ! printf '%s\n' "$MDEV_UUID" >"$MDEV_RECOVERY_FILE"; then
            echo "mdev recovery 记录写入失败: $MDEV_RECOVERY_FILE" >&2
            return 1
        fi
    fi
    if ! mdev_allocate "${VGPU_RESOURCE_PROFILE}" "$MDEV_UUID" \
            "$VGPU_RESOURCE_FB_MB" "${mdev_identity_args[@]}" >/dev/null; then
        echo "mdev 分配失败 — 排查 sudo / VGPU_MGPU=${VGPU_MGPU:-?} / host driver/profile" >&2
        return 1
    fi
    MDEV_ALLOCATION_STATE=active
    if [[ -z "$MDEV_RECOVERY_FILE" ]]; then
        if ! MDEV_RECOVERY_FILE=$(vm_storage_run_preferred_path "$VM_ID" mdev); then
            echo "mdev recovery 路径解析失败" >&2
            return 1
        fi
        if ! printf '%s\n' "$MDEV_UUID" >"$MDEV_RECOVERY_FILE"; then
            echo "mdev recovery 记录写入失败: $MDEV_RECOVERY_FILE" >&2
            return 1
        fi
    fi
    if [[ "$MODE" == vgpu-sdl || "$MODE" == vgpu-gtk ]]; then
        mdev_configure_console_interval \
            "$MDEV_UUID" "$VGPU_CONSOLE_INTERVAL_US" \
            ${VGPU_FRAME_RATE_LIMITER:+"$VGPU_FRAME_RATE_LIMITER"} || {
            echo "mdev console 刷新周期配置失败" >&2
            return 1
        }
        mdev_lock_gpu_clocks "${VGPU_MGPU:-}"
    fi
}

case "$MODE" in
    install)
        # 装机/重装/UEFI 救援：std-vga + 本地窗口直接弹（不挂 vfio-pci，
        # memory feedback_no_vfio_install: vGPU 在装机阶段会让 OVMF
        # PCI 枚举挂起）。
        #
        # 后端选择 (env INSTALL_GFX_BACKEND):
        #   gtk (默认)  GTK 是 Wayland 原生，渲染最稳。Ubuntu Wayland
        #               session 下 SDL2 + std-vga 实测会画面错位/重影
        #               (软件 renderer 跟 framebuffer 缩放不对齐)，
        #               GTK 没这问题。
        #   sdl         SDL2 (gl=off 软件渲染)。X11 session OK；Wayland
        #               下慎用，可能错位。
        # 两种都需要 QEMU build 带相应支持，没的话跑
        # ./deploy/host/build-qemu.sh 重编。
        GFX_ARGS+=( -vga none -device "VGA,id=bootstrap-vga,bus=pcie.0,addr=0x2" )
        case "$INSTALL_GFX_BACKEND" in
            sdl) GFX_ARGS+=( -display sdl,gl=off ) ;;
            gtk) GFX_ARGS+=( -display gtk,gl=off,grab-on-hover=on ) ;;
            *)   echo "未知 INSTALL_GFX_BACKEND=${INSTALL_GFX_BACKEND} (gtk|sdl)" >&2; exit 2 ;;
        esac
        ;;
    no-gpu)
        # 远程救援：std-vga + VNC，host 没图形/SSH 远程登录时用。
        # 用 vncviewer localhost:590${VM_ID} 接。
        GFX_ARGS+=( -vga none -device "VGA,id=rescue-vga,bus=pcie.0,addr=0x2" )
        GFX_ARGS+=( -display "vnc=${VNC_DISPLAY}" )
        ;;
    rescue-sdl|rescue-gtk)
        # 本地、无网络依赖的标准显卡救援。它不挂 vGPU，也不附加安装
        # ISO；仅供修复休眠/Fast Startup 等必须先进 Windows 的状态。
        GFX_ARGS+=( -vga none -device "VGA,id=rescue-vga,bus=pcie.0,addr=0x2" )
        case "$MODE" in
            rescue-sdl) GFX_ARGS+=( -display sdl,gl=off ) ;;
            rescue-gtk) GFX_ARGS+=( -display gtk,gl=off,grab-on-hover=on ) ;;
        esac
        ;;
    driver-install-sdl|driver-install-gtk)
        # Safe first/reinstall topology for the production-signed GRID package:
        # Windows keeps a temporary standard VGA as the only host-visible
        # console while the real mdev remains enumerated for PnP.  QEMU never
        # polls NVIDIA's R535 display REGION during setup, so an INF-provided
        # page-unsafe mode cannot turn the installation window black.
        allocate_vgpu || exit 1
        attach_vgpu_root_port || exit 1
        vfio_opts="sysfsdev=/sys/bus/mdev/devices/${MDEV_UUID},display=off,enable-migration=off,bus=gpu-root-port,addr=0x0,rombar=0"
        GFX_ARGS+=(
            -device "vfio-pci-nohotplug,${vfio_opts}"
            -vga none
            -device "VGA,id=driver-install-vga,bus=pcie.0,addr=0x2"
        )
        case "$MODE" in
            driver-install-sdl)
                GFX_ARGS+=( -display "sdl,gl=off,title=win10-${VM_ID}-driver-install" )
                ;;
            driver-install-gtk)
                GFX_ARGS+=( -display "gtk,gl=off,grab-on-hover=on" )
                ;;
        esac
        ;;
    rdp)
        # 旧兼容路径: vGPU + 侧挂 std-vga 供前期登录；进系统后由 relay/viewer 接管
        allocate_vgpu || exit 1
        if [[ -n "$MDEV_UUID" ]]; then
            attach_vgpu_root_port || exit 1
            # enable-migration=off: NVIDIA vGPU 驱动不支持 vfio migration
            # uapi。QEMU 11 默认开 migration 会让 guest 内 HAL 读 PCI 寄存器
            # 时拿到坏数据 → Windows HAL_INITIALIZATION_FAILED BSoD。
            vfio_opts="sysfsdev=/sys/bus/mdev/devices/${MDEV_UUID},display=off,enable-migration=off,bus=gpu-root-port,addr=0x0"
            [[ "$VGPU_ROMBAR" != auto ]] && vfio_opts+=",rombar=${VGPU_ROMBAR}"
            [[ -n "$VGPU_ROMFILE" ]] && vfio_opts+=",romfile=${VGPU_ROMFILE}"
            if [[ "$SPOOF_MODE" == "A" ||
                  "$SIGNED_CONSUMER_PRODUCTION_ACTIVE" == 1 ]]; then
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
        fi
        ;;
    vgpu-gtk|vgpu-sdl)
        # NVIDIA mdev 直接暴露 QEMU console region。ramfb 只承接 OVMF/Windows
        # 驱动起来前的画面；驱动就绪后自动切到 vGPU framebuffer。
        # guest 不再需要 ivshmem.sys / NvStreamSvc / AudioSvcHost。
        allocate_vgpu || exit 1
        attach_vgpu_root_port || exit 1
        vfio_opts="sysfsdev=/sys/bus/mdev/devices/${MDEV_UUID},display=on,ramfb=on,enable-migration=off"
        # NVIDIA 535 mdev 没有 VFIO_GFX_EDID_REGION；传 xres/yres 会让
        # QEMU 直接报 "need edid support"。native 窗口跟随 guest scanout
        # 分辨率，--width/--height 只保留给旧 external viewer。
        vfio_opts+=",bus=gpu-root-port,addr=0x0"
        [[ "$VGPU_ROMBAR" != auto ]] && vfio_opts+=",rombar=${VGPU_ROMBAR}"
        [[ -n "$VGPU_ROMFILE" ]] && vfio_opts+=",romfile=${VGPU_ROMFILE}"
        if [[ "$SPOOF_MODE" == "A" ||
              "$SIGNED_CONSUMER_PRODUCTION_ACTIVE" == 1 ]]; then
            vfio_opts+=",x-pci-vendor-id=${GPU_PCI_VID},x-pci-device-id=${GPU_PCI_DID}"
            vfio_opts+=",x-pci-sub-vendor-id=${GPU_SUB_VID},x-pci-sub-device-id=${GPU_SUB_DID}"
        fi
        GFX_ARGS+=( -device "vfio-pci-nohotplug,${vfio_opts}" -vga none )
        case "$MODE" in
            vgpu-sdl)
                GFX_ARGS+=( -display "sdl,gl=on,title=win10-${VM_ID},single-console=on" ) ;;
            vgpu-gtk)
                GFX_ARGS+=( -display "gtk,gl=on,show-cursor=on,grab-on-hover=on,show-tabs=off,show-menubar=off" ) ;;
        esac
        ;;
esac
start_vm_timing_mark devices-ready

# ─── Pidfile / monitor ──────────────────────────────────────────────────────
PIDFILE=$(vm_storage_run_preferred_path "$VM_ID" pid)
MON_SOCK=$(vm_storage_run_preferred_path "$VM_ID" mon)
QMP_SOCK=$(vm_storage_run_preferred_path "$VM_ID" qmp)
QMP_PROXY_SOCK="${QMP_SOCK}.proxy"
DGAME_QMP_COMPAT=$(dgame_endpoint_path "$VM_ID" qmp)
DGAME_QMP_PROXY_COMPAT=$(dgame_endpoint_path "$VM_ID" qmp.proxy)
DGAME_FB_COMPAT=$(dgame_endpoint_path "$VM_ID" fb)
DGAME_MON_COMPAT=$(dgame_endpoint_path "$VM_ID" mon)
QMP_ARGS=( -qmp "unix:${QMP_SOCK},server,nowait" )
QMP_MULTI_CLIENT=0
if [[ "$PROXY" == 1 || "$DGAME_PREVIEW_ENABLED" == 1 ||
      -n "$G11_INIT_ISO" ]]; then
    QMP_MULTI_CLIENT=1
    # 本分支 QEMU 原生为每个连接创建独立 QMP monitor；不再启动 Python
    # 中转进程。DGame broker、CPU 隔离器和运行期控制可能同时连接，
    # native preview 因此也必须启用 multi。保留 shorthand 供工具识别。
    QMP_ARGS=( -qmp "unix:${QMP_SOCK},server,nowait,multi=on" )
fi
MDEV_FILE=$(vm_storage_run_preferred_path "$VM_ID" mdev)
CPU_ISOLATION_STATE_FILE="$(dirname "$QMP_SOCK")/cpu-isolation.state"
if [[ -n "${MDEV_UUID:-}" && "$DRY_RUN" != 1 ]]; then
    printf '%s\n' "$MDEV_UUID" >"$MDEV_FILE"
    cleanup_native_mdev() {
        if [[ -n "${GNOME_SUPER_GUARD:-}" ]]; then
            "$GNOME_SUPER_GUARD" restore-stale 2>/dev/null || true
        fi
        if mdev_release "$MDEV_UUID" && \
                [[ ! -L "/sys/bus/mdev/devices/$MDEV_UUID" ]]; then
            rm -f "$MDEV_FILE"
        else
            echo "[start-vm] mdev $MDEV_UUID 释放失败，保留 $MDEV_FILE" >&2
        fi
        cleanup_started_tpm
    }
    trap cleanup_native_mdev EXIT
fi

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
    if [[ "$DRY_RUN" != 1 ]]; then
        rm -f "$IVSHMEM_PATH"
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

DGAME_PREVIEW_QEMU_ARGS=()
if ((DGAME_PREVIEW_ENABLED)); then
    DGAME_PREVIEW_RATE=$((10#$DGAME_PREVIEW_RATE))
    DGAME_PREVIEW_OBJECT_ARG="fb-shm,id=dgame-preview-vm${VM_ID}"
    DGAME_PREVIEW_OBJECT_ARG+=",path=${DGAME_PREVIEW_SOCKET}"
    DGAME_PREVIEW_OBJECT_ARG+=",rate=${DGAME_PREVIEW_RATE}"
    DGAME_PREVIEW_QEMU_ARGS=(
        -object "$DGAME_PREVIEW_OBJECT_ARG"
    )
    unset DGAME_PREVIEW_OBJECT_ARG
fi

STREAM_QEMU_ARGS=()
STREAM_HELPER_ARGS=()
if ((STREAM_ENABLED)); then
    STREAM_RATE=$((10#$STREAM_RATE))
    STREAM_GOP=$((10#$STREAM_GOP))
    STREAM_START_TIMEOUT=$((10#$STREAM_START_TIMEOUT))
    stream_object="fb-shm,id=stream-vm${VM_ID},path=${STREAM_SOCKET},rate=${STREAM_RATE}"
    if [[ -n "$STREAM_ROI" ]]; then
        STREAM_ROI_X=$((10#$STREAM_ROI_X))
        STREAM_ROI_Y=$((10#$STREAM_ROI_Y))
        STREAM_ROI_W=$((10#$STREAM_ROI_W))
        STREAM_ROI_H=$((10#$STREAM_ROI_H))
        stream_object+=",x=${STREAM_ROI_X},y=${STREAM_ROI_Y},width=${STREAM_ROI_W},height=${STREAM_ROI_H}"
    fi
    STREAM_QEMU_ARGS=( -object "$stream_object" )
    STREAM_HELPER_ARGS=(
        start "$VM_ID"
        --sock "$STREAM_SOCKET"
        --output "$STREAM_OUTPUT"
        --rate "$STREAM_RATE"
        --encoder "$STREAM_ENCODER"
        --bitrate "$STREAM_BITRATE"
        --preset "$STREAM_PRESET"
        --gop "$STREAM_GOP"
        --mode "$STREAM_MODE"
        --start-timeout "$STREAM_START_TIMEOUT"
        --stream-bin "$STREAM_BIN"
    )
    [[ -z "$STREAM_ROI" ]] ||
        STREAM_HELPER_ARGS+=( --roi "$STREAM_ROI" )
    [[ -z "$STREAM_CONTAINER" ]] ||
        STREAM_HELPER_ARGS+=( --container "$STREAM_CONTAINER" )
    unset stream_object
fi

KBD_NUMLOCK_PROP=""
[[ "$GUEST_NUMLOCK" == 0 ]] || \
    KBD_NUMLOCK_PROP=',x-force-numlock-on=on'
HID_LOW_LATENCY_PROP=""
[[ "$G11_USB_HID_LOW_LATENCY" == 0 ]] || \
    HID_LOW_LATENCY_PROP=',x-low-latency=on'
INPUT_ARGS=(
    -device "qemu-xhci,id=xhci,bus=${XHCI_PCI_BUS},addr=${XHCI_PCI_ADDR}"
    -device "usb-kbd,id=kbd0,bus=xhci.0,usb_version=${KBD_USB_VERSION},vendorid=${KBD_VID},productid=${KBD_PID},bcd-device=${KBD_BCD_DEVICE},manufacturer=${KBD_MFR},product=${KBD_PRODUCT}${KBD_NUMLOCK_PROP}${HID_LOW_LATENCY_PROP}"
)
if [[ "$POINTER_MODE" == absolute ]]; then
    INPUT_ARGS+=(
        -device "usb-tablet,bus=xhci.0,usb_version=${POINTER_USB_VERSION},vendorid=${POINTER_VID},productid=${POINTER_PID},bcd-device=${POINTER_BCD_DEVICE},manufacturer=${POINTER_MFR},product=${POINTER_PRODUCT}"
    )
else
    INPUT_ARGS+=(
        -device "usb-mouse,bus=xhci.0,usb_version=${MOUSE_USB_VERSION},vendorid=${MOUSE_VID},productid=${MOUSE_PID},bcd-device=${MOUSE_BCD_DEVICE},manufacturer=${MOUSE_MFR},product=${MOUSE_PRODUCT}${HID_LOW_LATENCY_PROP}"
    )
fi

# Apply the global host policy only after platform/device validation has
# succeeded.  Any required-mode failure is still before the QEMU process is
# launched; existing cleanup traps release a prepared TPM or mdev. Shared CPU
# mode deliberately has no process-count/vCPU-capacity gate: Linux schedules
# idle guest vCPUs normally, while simultaneous saturation remains an operator
# performance decision rather than a launcher warning.
g11_host_performance_apply || {
    echo "[start-vm] required 宿主性能策略未能应用；VM 未启动" >&2
    exit 1
}

echo "启动 VM ${VM_ID} 模式=${MODE}"
echo "  VM 目录: $(vm_storage_instance_dir "$VM_ID")"
echo "  配置: ${CONF}"
echo "  磁盘: ${DISK}"
if [[ "$QMP_MULTI_CLIENT" == 1 ]]; then
    echo "  QMP multi: native multi-client on ${QMP_SOCK}"
fi
if [[ "$PROXY" == 1 ]]; then
    echo "  QMP alias: ${QMP_PROXY_SOCK}"
fi
if ((DGAME_PREVIEW_ENABLED)); then
    echo "  DGame preview: ${DGAME_PREVIEW_RATE}Hz ${DGAME_PREVIEW_SOCKET}"
    if ((DGAME_PREVIEW_GPU_ENABLED)); then
        echo "  DGame transport: GPU first (active display EGL/dma-buf)"
        echo "  DGame fallback: per-client SHM"
    else
        echo "  DGame transport: GPU-first disabled; SHM fallback retained"
    fi
    echo "  DGame compatibility: $(dgame_endpoint_path "$VM_ID" fb)"
fi
echo "  CPU: ${CPU_MODEL}@${TSC_FREQ}Hz identity (${CPU_CORES}C/${CPU_VCPUS}T)"
echo "  CPU realization: policy=${CPU_REALIZATION_POLICY} class=${G11_CPU_CAPABILITY_CLASS} enforce=${CPU_ENFORCE_MODE}"
echo "  TSC: policy=${G11_TSC_POLICY} source=${G11_TSC_RUNTIME_SOURCE} effective=${G11_TSC_EFFECTIVE_HZ:-host-implicit}Hz / host-dynamic-frequency-independent"
echo "  硬件合法性: ${HARDWARE_LEGALITY_POLICY}/${G11_HW_LEGALITY_CODE}"
cpu_isolation_print_plan
g11_host_performance_print_plan
echo "  主板: ${BOARD_BRAND} ${BOARD_MODEL} / ${VM_UUID}"
if [[ "${G11_CHIPSET_PRESENTATION,,}" == catalog ]]; then
    echo "  芯片组: ${CHIPSET_PRESENTATION_NAME} / LPC ${BOARD_LPC_PCI_VENDOR_ID}:${BOARD_LPC_PCI_DEVICE_ID} rev ${BOARD_LPC_PCI_REVISION}（q35/ICH9 行为实现）"
else
    echo "  芯片组: ICH9（G11_CHIPSET_PRESENTATION=off 兼容回退）"
fi
if [[ "${G11_HOST_BRIDGE_PRESENTATION,,}" == catalog &&
      -n "${CPU_HOST_BRIDGE_PRESENTATION_KEY:-}" ]]; then
    echo "  CPU DMI2 inventory: ${CPU_HOST_BRIDGE_PRESENTATION_KEY} / ${CPU_HOST_BRIDGE_PCI_VENDOR_ID}:${CPU_HOST_BRIDGE_PCI_DEVICE_ID} rev ${CPU_HOST_BRIDGE_PCI_REVISION}（00:00.0 UEFI 退出后呈现；固件阶段 P35 MCH；行为仍为 q35）"
else
    echo "  CPU DMI2 inventory: off（仅保留 P35 MCH）"
fi
echo "  内存: ${MEM_MODULE_MB_LIST//,/+} MiB ${MEM_MODEL_LIST//,/ + } (${MEM_FAMILY:-unknown}@${MEM_SPEED} 身份；运行带宽=host-native/unthrottled，${MEM_CHANNEL_MODE})"
if [[ "$G11_MEMORY_PREALLOC" == off ]]; then
    echo "  宿主内存: 按需触页（Guest 上限 ${GUEST_MEM_MB} MiB 与 DIMM/SMBIOS 身份不变；工作集仍可能增长到上限）"
else
    echo "  宿主内存: 全量预分配（默认，Guest 上限 ${GUEST_MEM_MB} MiB）"
fi
echo "  睡眠: ACPI S3 已暴露（空闲自动睡眠由 Guest 设为从不；手动睡眠可用 vmctl.sh wake ${VM_ID} 唤醒）"
if [[ "$SSD_INTERFACE" == nvme ]]; then
    echo "  SSD: ${SSD_MODEL} / ${SSD_INTERFACE}:${SSD_CONTROLLER_PROFILE} / PCIe ${SSD_PCIE_GEN}.0 x${SSD_PCIE_LANES} ${SSD_FORM_FACTOR} / fw=${SSD_FIRMWARE_REV} / sector=${SSD_LOGICAL_BLOCK_SIZE}/${SSD_PHYSICAL_BLOCK_SIZE}B / ${SSD_SIZE_BYTES} bytes"
else
    echo "  SSD: ${SSD_MODEL} / ${SSD_INTERFACE}:${SSD_CONTROLLER_PROFILE} / SATA 6Gb/s ${SSD_FORM_FACTOR} / fw=${SSD_FIRMWARE_REV} / sector=${SSD_LOGICAL_BLOCK_SIZE}/${SSD_PHYSICAL_BLOCK_SIZE}B / ${SSD_SIZE_BYTES} bytes"
fi
echo "  xHCI: qemu-xhci 1B36:000D rev01 / SUBSYS 1AF4:1100（行为身份固定；目标平台 ${XHCI_PCI_VENDOR_ID}:${XHCI_PCI_DEVICE_ID} 仅作事实校验）"
if [[ "$MODE" == install ]]; then
    if [[ "$INSTALL_MEDIA_BACKEND" == usb ]]; then
        echo "  光驱: 安装模式临时 xHCI USB BOT CD-ROM"
        echo "  安装介质: UEFI helper -> xHCI USB BOT CD-ROM（64 KiB 合并读取高速路径）"
        echo "  安装期附加设备: helper + Windows ISO${UNATTEND_ISO:+ + OOBE answer ISO}（普通启动全部不挂载）"
    else
        echo "  光驱: 安装模式临时 ${ODD_MODEL} / fw=${ODD_FIRMWARE_REV} / SN=${ODD_SERIAL_POLICY}"
        echo "  安装介质: ICH9-AHCI IDE CD-ROM（兼容回退，可能较慢）"
    fi
elif [[ -n "$G11_INIT_ISO" ]]; then
    echo "  光驱: 首次初始化临时 ${ODD_MODEL} / ${ODD_FIRMWARE_REV}（载荷复制后自动热拔）"
    echo "  系统 NVAPI: VM-bound contract ${G11_INIT_CONTRACT_ID}"
else
    echo "  光驱: 未挂载（默认；仅 --install 或 vmctl.sh cdrom mount 时创建）"
fi
echo "  键盘: ${KBD_BRAND} ${KBD_MODEL} / usb-kbd / USB ${KBD_VID#0x}:${KBD_PID#0x} / SN=${KBD_SERIAL_POLICY} / ${KBD_FIDELITY}"
if [[ "$G11_USB_HID_LOW_LATENCY" == 1 ]]; then
    if [[ "$POINTER_MODE" == absolute ]]; then
        echo "  USB 输入延迟: keyboard=1ms opt-in；absolute tablet 已是 1ms（descriptor 指纹权衡）"
    else
        echo "  USB 输入延迟: keyboard=1ms / relative mouse=1ms opt-in（descriptor 指纹权衡）"
    fi
fi
if [[ "$GUEST_NUMLOCK" == 1 ]]; then
    echo "  NumLock: guest LED 驱动，明确 OFF 时单次开启（QOM: kbd0）"
else
    echo "  NumLock: 本次禁用（--no-numlock）"
fi
if [[ "$POINTER_MODE" == absolute ]]; then
    echo "  绝对指针: ${POINTER_MODEL} / usb-tablet / USB ${POINTER_VID#0x}:${POINTER_PID#0x} / SN=${POINTER_SERIAL_POLICY} / ${POINTER_FIDELITY}"
else
    echo "  相对鼠标: ${MOUSE_BRAND} ${MOUSE_MODEL} / usb-mouse / USB ${MOUSE_VID#0x}:${MOUSE_PID#0x} / SN=${MOUSE_SERIAL_POLICY} / ${MOUSE_FIDELITY}"
fi
if [[ -n "$VLAN_ID" ]]; then
    echo "  网络: access VLAN ${VLAN_ID} / ${VLAN_TAP_IF} -> br0（guest untagged）"
else
    echo "  网络: br0 默认/native LAN"
fi
echo "  GPU identity: ${GPU_PROFILE} / ${GPU_NAME} (configured target, not host PCI identity)"
echo "  GPU board: ${GPU_BOARD_BRAND} / ${GPU_BOARD_IDENTITY} / serial=${GPU_SERIAL_POLICY}"
case "$SPOOF_MODE" in
    A)
        if [[ "$SIGNED_CONSUMER_PROBE_AUTHORIZED" == 1 ]]; then
            echo "  GPU probe: one-shot ${SIGNED_CONSUMER_PROBE_EXPECTED_STAGE} / ${SIGNED_CONSUMER_PROBE_EXPECTED_PROFILE} / outer ${SIGNED_CONSUMER_PROBE_EXPECTED_PCI_VID#0x}:${SIGNED_CONSUMER_PROBE_EXPECTED_PCI_DID#0x} SUBSYS ${SIGNED_CONSUMER_PROBE_EXPECTED_SUB_DID#0x}:${SIGNED_CONSUMER_PROBE_EXPECTED_SUB_VID#0x} / ${SIGNED_CONSUMER_PROBE_EXPECTED_DRIVER_KEY} ${SIGNED_CONSUMER_PROBE_EXPECTED_DRIVER_VERSION}"
        else
            echo "  GPU target: ${GPU_NAME} (name + consumer PCI ID spoof)"
        fi ;;
    B)
        if [[ "$SIGNED_CONSUMER_PRODUCTION_ACTIVE" == 1 ]]; then
            echo "  GPU signed consumer: persistent outer-only ${GPU_PCI_VID#0x}:${GPU_PCI_DID#0x} SUBSYS ${GPU_SUB_DID#0x}:${GPU_SUB_VID#0x} / ${SC_DRIVER_KEY} ${SC_DRIVER_VERSION}"
            echo "  GPU signed consumer state: ${VGPU_SIGNED_CONSUMER_STATE} / experiment ${VGPU_SIGNED_CONSUMER_EXPERIMENT_ID}"
        else
            echo "  GPU name target: ${GPU_NAME} (system PCI identity remains host mdev; catalog PCI tuple is app-local to GPU-Z/NVAPI)"
        fi ;;
    off)
        echo "  GPU target: disabled (profile metadata ${GPU_PROFILE} is not applied)" ;;
esac
if (( VGPU_MDEV_INTERNAL_PCI_ACTIVE )) &&
        [[ "$SIGNED_CONSUMER_PROBE_AUTHORIZED" == 1 ]]; then
    echo "  vGPU internal PCI identity: one-shot pci_id=${SIGNED_CONSUMER_PROBE_EXPECTED_INTERNAL_PCI} / pdev=${SIGNED_CONSUMER_PROBE_EXPECTED_INTERNAL_PDEV}（wrapper 退出回 B）"
elif [[ "$SIGNED_CONSUMER_PROBE_AUTHORIZED" == 1 ]]; then
    echo "  vGPU internal PCI identity: native（outer-only stage）"
elif [[ "$SIGNED_CONSUMER_PRODUCTION_ACTIVE" == 1 ]]; then
    echo "  vGPU internal PCI identity: native（production outer-only contract）"
elif (( VGPU_MDEV_INTERNAL_PCI_ACTIVE )); then
    echo "  vGPU internal PCI identity: unexpected legacy state (strict-A guard should have rejected it)"
elif [[ "$VGPU_MDEV_INTERNAL_PCI_IDENTITY" == 1 ]]; then
    echo "  vGPU internal PCI identity: inactive (requires SPOOF_MODE=A; name-only cleanup remains active)"
else
    echo "  vGPU internal PCI identity: disabled (default; name-only cleanup remains active)"
fi
if (( VGPU_MDEV_FRL_OVERRIDE_ACTIVE )); then
    echo "  vGPU frame-rate limiter: per-mdev frl_enabled=${VGPU_MDEV_FRL_ENABLED}"
else
    echo "  vGPU frame-rate limiter: inherited from resource profile"
fi
echo "  vGPU resource: ${VGPU_RESOURCE_PROFILE}/${VGPU_RESOURCE_FB_MB}MB (host mdev)"
if (( ${#TPM_ARGS[@]} )); then
    if [[ "$TPM_EFFECTIVE_VERSION" == 1.2 ]]; then
        echo "  TPM: 1.2 / TIS (${TPM_DECISION}; socket=${VM_TPM_SOCKET})"
    else
        echo "  TPM: 2.0 / CRB (${TPM_DECISION}; socket=${VM_TPM_SOCKET})"
    fi
elif [[ "$TPM_CLI_DISABLED" == 1 ]]; then
    echo "  TPM: disabled (explicit) -- CLI --no-tpm; board=${BOARD_TPM_VERSION}"
else
    echo "  TPM: disabled (${TPM_DECISION}; board=${BOARD_TPM_VERSION})"
fi
[[ -n "${MDEV_UUID:-}" ]] && echo "  mdev: ${MDEV_UUID}"
case "$MODE" in
    vgpu-gtk|vgpu-sdl)
        echo "  显示: vGPU console -> ${WINDOW_BACKEND} (ramfb early boot, 无 guest relay)"
        echo "  显示能力: 1 head / 1920x1080 / max_pixels=2073600"
        echo "  Windows 有效显示器目标: ${MONITOR_DISPLAY_NAME:-${MONITOR_PROFILE:-legacy/unknown}} (${MONITOR_VENDOR:-???}:${MONITOR_PRODUCT_ID:-???}; EDID_OVERRIDE + raw cache)" ;;
    driver-install-sdl|driver-install-gtk)
        echo "  显示: 临时标准 VGA -> ${WINDOW_BACKEND}；NVIDIA mdev display=off（仅供生产 GRID PnP 安装）"
        echo "  安装保护: spoof=off / rombar=0 / 无 ramfb / 无 NVIDIA console REGION 读取"
        echo "  安装后要求: 完整关机 -> host 认证 NV_Modes -> 再以正常 vGPU 模式启动" ;;
    rescue-sdl)
        echo "  显示: 标准显卡 -> SDL 本地救援（无 vGPU/VNC/RDP）" ;;
    rescue-gtk)
        echo "  显示: 标准显卡 -> GTK 本地救援（无 vGPU/VNC/RDP）" ;;
    rdp|no-gpu)
        echo "  VNC display: ${VNC_DISPLAY}  (hostport=$((5900 + ${VNC_DISPLAY#:})))" ;;
esac
if ((STREAM_ENABLED)); then
    if [[ "$STREAM_OUTPUT" == /* ]]; then
        STREAM_TARGET_LABEL=local-file
    else
        STREAM_TARGET_LABEL="${STREAM_OUTPUT%%:*}://..."
    fi
    echo "  推流: fb-shm ${STREAM_RATE}Hz mode=${STREAM_MODE} encoder=${STREAM_ENCODER} target=${STREAM_TARGET_LABEL}"
    if [[ -n "$STREAM_ROI" ]]; then
        echo "  推流 ROI: ${STREAM_ROI_W}x${STREAM_ROI_H}@${STREAM_ROI_X},${STREAM_ROI_Y}"
    else
        echo "  推流 ROI: full primary display"
    fi
    [[ "$STREAM_ENCODER" != *nvenc* ]] ||
        echo "  推流说明: NVENC 接收 SHM rawvideo 后仍有 GPU upload，不是零拷贝"
fi

case "$RTC_MODE" in
    localtime)
        export TZ="$VM_RTC_TZ"
        RTC_ARGS=( -rtc "base=localtime,clock=${G11_RTC_CLOCK},driftfix=slew" )
        PIT_LOST_TICK_POLICY=delay
        echo "  RTC: host localtime (${TZ}) / clock=${G11_RTC_CLOCK}"
        ;;
    utc|utc-compat)
        RTC_ARGS=( -rtc "base=utc,clock=${G11_RTC_CLOCK},driftfix=slew" )
        PIT_LOST_TICK_POLICY=discard
        if [[ "$RTC_MODE" == utc-compat ]]; then
            echo "  RTC: UTC compatibility rescue (one boot only)"
        else
            echo "  RTC: legacy UTC contract (run finish-vgpu-install.sh once to migrate)"
        fi
        ;;
esac

# QEMU command line built once, used by both code paths below.
QEMU_CMD=(
    "$QEMU_BIN"
    -name "vm${VM_ID}"
    -machine "$MACHINE_ARGS"
    -cpu "$CPU_ARGS"
    -smp "${CPU_VCPUS},sockets=1,cores=${CPU_CORES},threads=${CPU_THREADS_PER_CORE}"
    -m "$GUEST_MEM_MB"
    -object "memory-backend-memfd,id=ram0,size=${GUEST_MEM_MB}M,share=on,prealloc=${G11_MEMORY_PREALLOC},merge=off"
    -numa node,memdev=ram0
    "${RTC_ARGS[@]}"
    -global "kvm-pit.lost_tick_policy=${PIT_LOST_TICK_POLICY}"
    # Expose the q35/ICH9 ACPI S3 state just like a physical desktop. Guest
    # policy keeps automatic idle sleep at Never; an explicit user Sleep can
    # be resumed through QMP with `vmctl.sh wake ID` if local USB wake is not
    # delivered by the host desktop stack.
    -global ICH9-LPC.disable_s3=0
    "${HOST_BRIDGE_PRESENTATION_ARGS[@]}"
    "${CHIPSET_PRESENTATION_ARGS[@]}"
    "${TPM_ARGS[@]}"
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
    -drive "if=pflash,format=raw,file=$VARS_PRIV"
    "${SMBIOS[@]}"
    -uuid "$VM_UUID"
    "${NET_ARGS[@]}"
    "${DRIVE_ARGS[@]}"
    "${GFX_ARGS[@]}"
    "${DGAME_PREVIEW_QEMU_ARGS[@]}"
    "${STREAM_QEMU_ARGS[@]}"
    "${INPUT_ARGS[@]}"
    "${INSTALL_MEDIA_DEVICE_ARGS[@]}"
    -device intel-hda,bus=pcie.0,addr=0x7 -device hda-duplex
    "${IVSHMEM_ARGS[@]}"
    -monitor "unix:${MON_SOCK},server,nowait"
    "${QMP_ARGS[@]}"
    -pidfile "$PIDFILE"
    $EXTRA
)

# Defense in depth for callers that exported a runtime credential before
# entering this script.  QEMU never needs it, and env -u also covers every
# launch mode below without changing the reviewed QEMU argv.
QEMU_LAUNCH=( env -u SUDO_PASSWORD )
if [[ "$LOCAL_INPUT_BACKEND" == sdl &&
      "$QEMU_SDL_GNOME_ANIMATIONS" == off ]] &&
        gnome_super_shortcuts_is_gnome &&
        gnome_super_shortcuts_available; then
    GNOME_ANIMATION_GUARD="$here/host/gnome-animation-guard.py"
    if [[ ! -x "$GNOME_ANIMATION_GUARD" ]]; then
        echo "[start-vm] GNOME 动画守护器不可执行: $GNOME_ANIMATION_GUARD" >&2
        exit 1
    fi
    # The wrapper owns the reversible setting journal and forwards signals to
    # QEMU.  Multiple G-11 SDL VMs share a refcount; the final exit restores
    # the exact pre-launch value, including an originally disabled setting.
    QEMU_LAUNCH+=( python3 "$GNOME_ANIMATION_GUARD" run -- )
    if [[ "$DRY_RUN" != 1 ]]; then
        echo "[start-vm] GNOME 窗口动画保护：已去掉 SDL 最小化/恢复/最大化双影；QEMU 退出自动恢复"
    fi
elif [[ "$LOCAL_INPUT_BACKEND" == sdl && "$DRY_RUN" != 1 ]]; then
    echo "[start-vm] SDL 使用桌面原生窗口动画（GNOME 下可能显示旧窗口 clone）"
fi

[[ "$NATIVE_FULLSCREEN" == 1 ]] && QEMU_CMD+=( -full-screen )
# required 模式从暂停状态启动；root helper 完成 cgroup + TID 绑核后
# pinner 才通过 QMP cont 放行 guest，保证 guest 不会先无隔离运行。
[[ "$CPU_ISOLATION" == required ]] && QEMU_CMD+=( -S )

if [[ "$DRY_RUN" == 1 ]]; then
    echo "[start-vm] DRY_RUN QEMU SPD env (逐槽合同):"
    printf '  QEMU_SPD_TYPE=%q\n' "$QEMU_SPD_TYPE"
    printf '  QEMU_SPD_SPEED_MT=%q\n' "$QEMU_SPD_SPEED_MT"
    printf '  QEMU_SPD_SLOTS=%q\n' "$QEMU_SPD_SLOTS"
    printf '  QEMU_SPD_MODULE_MB_LIST=%q\n' "$QEMU_SPD_MODULE_MB_LIST"
    for spd_detail_var in QEMU_SPD_RANK_LIST QEMU_SPD_DEVICE_WIDTH_LIST \
            QEMU_SPD_MODULE_MFR_JEP106_LIST \
            QEMU_SPD_DRAM_MFR_JEP106_LIST QEMU_SPD_SERIAL_LIST \
            QEMU_SPD_PART_LIST; do
        if [[ -v $spd_detail_var ]]; then
            printf '  %s=%q\n' "$spd_detail_var" "${!spd_detail_var}"
        fi
    done
    unset spd_detail_var
    echo "[start-vm] DRY_RUN QEMU argv (每行一个参数):"
    printf '  %q\n' "${QEMU_CMD[@]}"
    exit 0
fi

dgame_qemu_ptracer_build_leaf "${QEMU_CMD[@]}" || {
    echo "[start-vm] 无法构造带 DGame 内存授权的 QEMU 叶命令" >&2
    exit 1
}
QEMU_EXEC_CMD=("${DGAME_QEMU_LEAF_CMD[@]}")
echo "[start-vm] DGame memory: process-local Yama exception "\
     "(${DGAME_QEMU_PTRACER_DESCRIPTION})"

G11_VLAN_PREPARED=0
if [[ -n "$VLAN_ID" ]]; then
    g11_vlan_prepare "$VM_ID" "$VLAN_ID" "$VLAN_TAP_IF" || exit $?
    G11_VLAN_PREPARED=1
    g11_vlan_marker_write "$G11_VLAN_RUNTIME_MARKER" \
        "$VM_ID" "$VLAN_ID" "$VLAN_TAP_IF" || {
        echo "[start-vm] 无法提交 VLAN runtime marker；VM 未启动" >&2
        exit 1
    }
    start_vm_timing_mark vlan-ready
fi

if ! install_dgame_compat_endpoints; then
    echo "[start-vm] 无法安全创建 DGame 发现端点；VM 未启动" >&2
    exit 1
fi
if ((DGAME_PREVIEW_ENABLED)); then
    echo "[start-vm] DGame endpoints: $DGAME_QMP_COMPAT, $DGAME_FB_COMPAT"
else
    echo "[start-vm] DGame endpoint: $DGAME_QMP_COMPAT"
fi

# 兼容旧工具写死的 `.proxy` 路径。真正的并发由主 QMP listener 的
# multi=on 提供；软链接创建失败不影响主 socket。无论本次是否启用，都先
# 清掉可能残留的旧别名，避免 --no-proxy 后仍误导工具使用单客户端 socket。
if ! rm -f -- "$QMP_PROXY_SOCK" 2>/dev/null; then
    echo "[start-vm] WARN: 无法清理旧 QMP alias: $QMP_PROXY_SOCK" >&2
elif [[ "$PROXY" == 1 ]]; then
    if ln -s -- "$QMP_SOCK" "$QMP_PROXY_SOCK" 2>/dev/null; then
        QMP_PROXY_ALIAS_OWNED=1
        echo "[start-vm] QMP alias: $QMP_PROXY_SOCK -> $QMP_SOCK"
    else
        echo "[start-vm] WARN: QMP alias 创建失败: $QMP_PROXY_SOCK" >&2
    fi
fi

QEMU_LOG=$(vm_storage_log_path "$VM_ID")
mkdir -p "$(dirname "$QEMU_LOG")"
: > "$QEMU_LOG"
if [[ -n "$VLAN_ID" ]]; then
    printf '[start-vm] network access-vlan=%s tap=%s bridge=br0 guest-tagging=untagged\n' \
        "$VLAN_ID" "$VLAN_TAP_IF" >>"$QEMU_LOG"
else
    printf '[start-vm] network bridge=%s mode=native-default\n' "$BR0" >>"$QEMU_LOG"
fi
start_vm_timing_mark qemu-launch
printf '%s\n' "${START_VM_TIMING_LINES[@]}" >>"$QEMU_LOG"

if ! cpu_isolation_launch "$VM_ID" "$CPU_VCPUS" "$CPU_CORES" \
        "$CPU_THREADS_PER_CORE" "$QMP_SOCK" "$PIDFILE" \
        "$CPU_ISOLATION_STATE_FILE"; then
    echo "[start-vm] required CPU 隔离无法启动" >&2
    exit 1
fi

if [[ -n "$G11_INIT_ISO" ]]; then
    G11_INIT_MEDIA_WATCHER="$here/host/watch-g11-init-media.py"
    [[ -f "$G11_INIT_MEDIA_WATCHER" && ! -L "$G11_INIT_MEDIA_WATCHER" ]] || {
        echo "[start-vm] 初始化光驱自动热拔器缺失或类型不安全: $G11_INIT_MEDIA_WATCHER" >&2
        exit 1
    }
    python3 "$G11_INIT_MEDIA_WATCHER" \
        "$QMP_SOCK" "vm${VM_ID}" "$G11_INIT_ISO" \
        "$G11_INIT_ODD_VENDOR" "$G11_INIT_ODD_PRODUCT" \
        "$ODD_FIRMWARE_REV" >>"$QEMU_LOG" 2>&1 &
    G11_INIT_MEDIA_WATCH_PID=$!
    echo "[start-vm] 初始化光驱将在载荷复制完成后自动热拔"
fi

# 非 rdp 模式都是"QEMU 直接挂前台显示"——install/driver-install/vgpu-* 都让 QEMU 自己
# 弹窗（-display sdl/gtk），no-gpu 走旧 VNC 远程。这些路径不需要一条龙
# (setup-task + ivshmem viewer)，因为：
#   - install: guest 还没装 Windows / 在 UEFI shell，没法跑 nv_stream_relay
#   - driver-install-*: 临时标准 VGA 显示，NVIDIA mdev 只做 PnP、display=off
#   - vgpu-gtk/vgpu-sdl: QEMU 直读 vGPU console region，不通过 ivshmem
#   - rescue-*: 本地标准显卡救援，不依赖任何 guest 网络
#   - no-gpu: 旧纯远程救援，QEMU 把画面推 VNC
if [[ "$MODE" != "rdp" ]]; then
    [[ "$MODE" == "no-gpu" ]] && \
        echo "[start-vm] no-gpu: 用 vncviewer localhost:$((5900 + ${VNC_DISPLAY#:})) 连"
    if ((STREAM_ENABLED)); then
        STREAM_QEMU_PID=""
        terminate_stream_qemu() {
            local pid=${STREAM_QEMU_PID:-} i

            [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 0
            if kill -0 "$pid" 2>/dev/null; then
                kill -TERM "$pid" 2>/dev/null || true
                for ((i = 0; i < 50; i++)); do
                    kill -0 "$pid" 2>/dev/null || break
                    sleep 0.1
                done
            fi
            if kill -0 "$pid" 2>/dev/null; then
                echo "[start-vm] QEMU 未在 TERM 后退出，发送 KILL" >&2
                kill -KILL "$pid" 2>/dev/null || true
            fi
            wait "$pid" 2>/dev/null || true
            STREAM_QEMU_PID=""
        }
        stream_signal_exit() {
            local rc=$1 signal_name=$2

            trap - INT TERM
            echo "[start-vm] 收到 ${signal_name}，停止 vm${VM_ID} 推流和 QEMU" >&2
            terminate_stream_qemu
            exit "$rc"
        }

        # sidecar 要等 fb-shm socket，因此 QEMU 必须先后台启动；本脚本仍
        # wait QEMU，保持原来“关闭窗口即退出并回收资源”的前台生命周期。
        "${QEMU_LAUNCH[@]}" "${QEMU_EXEC_CMD[@]}" 2> >(tee -a "$QEMU_LOG" >&2) &
        STREAM_QEMU_PID=$!
        trap 'stream_signal_exit 130 INT' INT
        trap 'stream_signal_exit 143 TERM' TERM
        echo "[start-vm] QEMU pid=${STREAM_QEMU_PID}；等待 fb-shm sidecar"

        sleep 0.1
        if ! kill -0 "$STREAM_QEMU_PID" 2>/dev/null; then
            set +e
            wait "$STREAM_QEMU_PID"
            qemu_rc=$?
            set -e
            STREAM_QEMU_PID=""
            echo "[start-vm] QEMU 在推流连接前退出 (rc=${qemu_rc})" >&2
            tail -30 "$QEMU_LOG" | sed 's/^/  /' >&2
            exit "$qemu_rc"
        fi

        STREAM_SIDECAR_OWNED=1
        if "$STREAM_HELPER" "${STREAM_HELPER_ARGS[@]}"; then
            :
        else
            stream_rc=$?
            echo "[start-vm] 推流 sidecar 启动失败 (rc=${stream_rc})；停止本次 QEMU" >&2
            terminate_stream_qemu
            exit "$stream_rc"
        fi

        echo "[start-vm] vm${VM_ID} 推流已连接；status: ${STREAM_HELPER} status ${VM_ID}"
        set +e
        wait "$STREAM_QEMU_PID"
        qemu_rc=$?
        set -e
        STREAM_QEMU_PID=""
        trap - INT TERM
        if "$STREAM_HELPER" stop "$VM_ID"; then
            STREAM_SIDECAR_OWNED=0
        else
            echo "[start-vm] WARN: vm${VM_ID} 推流 sidecar 停止失败" >&2
        fi
        exit "$qemu_rc"
    fi

    # 不能 exec：EXIT trap 负责回收 mdev 与独立 swtpm daemon。
    set +e
    "${QEMU_LAUNCH[@]}" "${QEMU_EXEC_CMD[@]}" 2> >(tee -a "$QEMU_LOG" >&2)
    qemu_rc=$?
    set -e
    exit "$qemu_rc"
fi

# ───────── 旧 rdp/legacy-shmem 兼容模式：QEMU 后台 + setup + viewer
#
# 流程：
#   1. QEMU fork 到后台，stderr → vmN/log/qemu.log（用 tail -f 跟）
#   2. 后台 setup-task：等 WinRM 起 → 探 NvDisplayContainer 服务，没装就跑
#      setup-guest.sh，已装但 stopped 就 Start-Service
#   3. 前台拉 stream_client_dda viewer，等 ring magic（最长 5 分钟，覆盖
#      fresh-boot + 装驱动 + 重启）
#   4. trap: Ctrl+C / viewer 关窗 / 任何退出 → kill 子任务 + 调 stop-vm.sh
#   5. watchdog: QEMU 不在了 → kill viewer 让脚本退出
#
SHMEM_PATH="${IVSHMEM_PATH:-/dev/shm/nv-shmem-vm${VM_ID}}"
VIEWER_BIN="$here/stream-client/stream_client_dda"

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
    VM_START_LOCK_HELD=1 VM_START_LOCK_FD="$START_LOCK_FD" \
        "$here/scripts/stop-vm.sh" "$VM_ID" \
        || VM_START_LOCK_HELD=1 VM_START_LOCK_FD="$START_LOCK_FD" \
            "$here/scripts/stop-vm.sh" "$VM_ID" --force || true
    cleanup_started_tpm
    gnome_super_shortcuts_restore
    "$here/gnome-super-guard.sh" restore-stale 2>/dev/null || true
    exit 0
}
trap cleanup_all INT TERM EXIT

# 1) QEMU 后台启 + 重定向 stderr 到 log（tmux 会破坏数组里的引号 — 之前
# 试过 `tmux new-session "${QEMU_CMD[*]}"`，QEMU 一启动就 crash 因为
# `-machine "q35,accel=kvm,..."` 这种逗号串被 shell 重新分词搞乱）。
"${QEMU_LAUNCH[@]}" "${QEMU_EXEC_CMD[@]}" >>"$QEMU_LOG" 2>&1 &
QEMU_PID=$!
echo "[start-vm] QEMU pid=${QEMU_PID}  (stderr: tail -f ${QEMU_LOG})"

# Sanity: 给 QEMU 1 秒起 — 立刻死的话 dump log。
sleep 1
if ! kill -0 "$QEMU_PID" 2>/dev/null; then
    echo "[start-vm] !! QEMU 启动失败，最后 30 行日志："
    tail -30 "$QEMU_LOG" | sed 's/^/  /'
    trap '' INT TERM EXIT
    VM_START_LOCK_HELD=1 VM_START_LOCK_FD="$START_LOCK_FD" \
        "$here/scripts/stop-vm.sh" "$VM_ID" --force >/dev/null 2>&1 || true
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
        guest_ip=$(ip -4 neigh show 2>/dev/null | awk -v m="$mac_lc" -v bridge="$BR0" \
            '$3==bridge && tolower($5)==m && $1 ~ /^[0-9]/ {print $1; exit}')
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
    # 一次拿齐 driver/license 和基础 per-VM identity 状态：
    #   svc:    NvDisplayContainer service status (Running/Stopped/空=没装)
    #   grid:   nvlddmkm.sys 在不在 (memory project_grid_driver_partial)
    #   ver:    NVIDIA driver 版本，期望 31.0.15.3833 (GRID 538.33)
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
$gpuName = if ($vc) { [string]$vc.Name } else { '' }
$lic = 'N/A'
$smi = & 'C:\Windows\System32\nvidia-smi.exe' -q 2>$null
if ($smi) {
    $m = ($smi | Select-String 'License Status\s*:\s*(\S+)' -List).Matches
    if ($m.Count -gt 0) { $lic = $m[0].Groups[1].Value }
}
"$svc|$grid|$ver|$err|$lic|$spoofed|$gpuName"
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
    IFS='|' read -r svc grid ver err lic spoofed guest_gpu_name <<<"$state"
    echo "[setup-task] svc=${svc:-?} sys=${grid:-?} ver=${ver:-?} err=${err:-?} license=${lic:-?} gpu='${guest_gpu_name:-?}' expected='${GPU_NAME}'"
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

    # 注意：DCH driver 不再拷 nvlddmkm.sys 到 system32\drivers，而是从
    # DriverStore 加载 — sys=False 不能作 driver 缺失的判据。用 err==-1
    # (Win32_VideoController 完全找不到 NVIDIA 适配器) + ver 错 来判断。
    if [[ "$ver" != "$EXPECT_VER" || "$err" == "-1" ]]; then
        echo "[setup-task] driver 状态错: ver='${ver}' err=${err} (期望 ver=${EXPECT_VER})"
        if [[ "${SPOOF_MODE:-B}" == "A" ]]; then
            echo "[setup-task] !! 当前 A 模式下驱动未正确绑定；不在运行中的显示设备上重装。"
            echo "[setup-task]    恢复：完整关机后运行 ./deploy/scripts/vmctl.sh driver-install ${VM_ID}"
            echo "[setup-task]    当前生产路径统一保持 B/name-only；不要恢复 legacy consumer-ID driver。"
        else
            echo "[setup-task] driver 缺失/版本错误；运行中的 rdp/native console 禁止自动重装"
            echo "[setup-task] 请完整关机后运行：./deploy/scripts/vmctl.sh driver-install ${VM_ID}"
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
        ./setup-guest.sh "$VM_ID" --ip "$guest_ip" --skip-vgpu --skip-ivshmem \
            --skip-stealth --skip-nvapi-shim --skip-monitor --skip-input || true
    else
        echo "[setup-task] driver+license+service 全 OK；GPU 产品名由 host per-mdev 提供 (license=${lic})"
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
    echo "[start-vm]    QEMU 已起，跳过 viewer；./deploy/scripts/stop-vm.sh ${VM_ID} 关"
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
    while pgrep -f "$VM_PATTERN" >/dev/null; do sleep 3; done
    kill "$VIEWER_PID" 2>/dev/null
) &
WATCH_PID=$!

wait "$VIEWER_PID" || true
