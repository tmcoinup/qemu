#!/usr/bin/env bash
# start-vm.sh — NVIDIA mdev/vGPU VM 启动器
#
# 用法: ./start-vm.sh <vm_id> [options]
#   --vm-dir <abs>     当前 VM 的完整 bundle 路径（末级必须为 vm<vm_id>）
#   --instances-dir <abs>
#                      VM bundle 父目录；当前 VM 自动使用其中的 vm<vm_id>
#   --print-paths      只打印最终路径并退出，不创建目录、不启动 VM
#   --install [iso]    安装模式；缺盘时自动建空盘，不会复制公共 base
#                      (NO_VFIO 旁路 vfio-pci；iso 默认 $IMAGE_ROOT/iso/win10.iso)
#                      默认仅跳过 OOBE；密钥/版本/磁盘分区仍手动选择
#                      OOBE 使用内置 Administrator，密码为空
#   --manual-oobe      安装时不附加应答 ISO，恢复完整手动 OOBE
#   --native           默认 — NVIDIA vGPU 直显 + SDL，无 guest 抓屏代理
#   --sdl              同 --native，强制 SDL 窗口
#   --gtk              同 --native，改用 GTK 窗口
#   --vgpu-gtk         --gtk 的显式别名
#   --vgpu-sdl         --sdl 的显式别名
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
#   --proxy           启用 QEMU 原生 QMP 多客户端；并创建 .proxy 兼容别名
#   --no-proxy        关闭 QMP 多客户端（默认）
#   --cpu-isolate      CPU 隔离 required 模式（默认；保留为显式兼容参数）
#   --cpu-isolate-auto CPU 隔离 auto 模式（不可用时显式降级继续）
#   --no-cpu-isolate   关闭 CPU 隔离
#   --svc-cpus <N>     QEMU 主循环/显示/IO 专用逻辑 CPU 数（默认 1）
#   --stream <URL>      启用 fb-shm 区域推流；必须给显式目标 URL/绝对文件
#   --stream-roi X,Y,W,H  固定推流区域（默认完整主显示）
#   --stream-rate <Hz>  捕获/编码帧率 1..240（默认 30）
#   --stream-encoder <name>  ffmpeg 编码器（默认 libx264）
#   --stream-bitrate <rate>  视频码率（默认 6M）
#   --stream-preset <name>   编码器 preset（默认 veryfast）
#   --stream-gop <frames>    GOP 帧数（默认 60）
#   --stream-container <name> 显式 ffmpeg muxer
#   --stream-mode auto|shm|gpu  G-11 默认 shm；R535 拒绝严格 gpu 模式
#   --no-stream         关闭环境变量配置的推流
#   --dry-run          只打印最终 QEMU argv，不分配 mdev/不启动
#   --no-tame-gnome    不让 viewer 动态处理 GNOME/IBus 宿主快捷键
#   --tame-gnome       强制让鼠标在 viewer 内时临时关闭宿主 Super/Alt+Tab 快捷键
#   --extra "<args>"   透传额外 QEMU 参数
#
# 环境变量:
#   QEMU_BIN         QEMU 二进制路径 (默认 build/qemu-system-x86_64)
#   QEMU_IMG         qemu-img 路径（默认 build/qemu-img）
#   OVMF_CODE        OVMF_CODE.fd 路径 (默认 host/OVMF_CODE_4M_stealth.fd)
#   OVMF_VARS        OVMF_VARS.fd 模板
#   VM_ROOT          G-11 根目录 (默认 $IMAGE_ROOT/vms/G-11)
#   VM_INSTANCE_DIR  当前 VM 的完整 bundle 路径（等价于 --vm-dir）
#   VM_INSTANCES_DIR 每 VM bundle 父目录 (默认 $VM_ROOT)
#   VM_BASE_DIR      公共 base 目录 (默认 $VM_ROOT/shared/bases)
#   ISO_DIR          Windows ISO 目录 (默认 $IMAGE_ROOT/iso)
#   INSTALL_UNATTENDED  安装时自动附加 OOBE 应答 ISO (0/1，默认 1)
#   INSTALL_UNATTEND_TEMPLATE  最小应答 XML 模板
#   XORRISO          xorriso 命令/路径
#   BR0              网桥名 (默认 br0)
#   GUEST_MEM_MB     分配内存 (默认 8192)
#   GFX_BACKEND      vGPU native 窗口后端 (sdl|gtk，默认 sdl)
#   INSTALL_GFX_BACKEND  install 窗口后端 (gtk|sdl，默认 gtk)
#   QEMU_SDL_DISABLE_IBUS auto|0|1；默认 auto，在宿主 IBus 会话中隔离
#                     SDL 的宿主输入法（guest 仍接收原始键盘事件）
#   QEMU_SDL_PRESENT_MODE fixed|dynamic；默认 fixed，SDL 固定 60Hz Present；
#                     dynamic 保留旧的按画面变化 Present 行为
#   DISPLAY_WIDTH/HEIGHT  旧 external viewer 窗口大小 (默认 1920x1080)
#   VGPU_ROMBAR      vGPU ROM BAR 策略 (auto|0|1；native 默认 0)
#   VGPU_ROMFILE     可选的缓存 vGPU option ROM 文件 (诊断用)
#   VGPU_HOST_CONFIG 宿主 vGPU 资源配置（默认 host/vgpu-host.conf）
#   VGPU_RESOURCE_PROFILE  真实 mdev type id/name/glob（与 guest identity 分离）
#   VGPU_RESOURCE_FB_MB    真实 mdev framebuffer MB
#   VGPU_MDEV_IDENTITY_MODE host per-mdev 名称：auto|required|off（默认 auto）
#   VGPU_MDEV_INTERNAL_PCI_IDENTITY 实验性内部 vdev/pdev ID：0|1（默认 0）
#                     仅 SPOOF_MODE=A 时生效；其他情况仍为 name-only
#   VGPU_MDEV_FRL_ENABLED 可选的 per-mdev FRL 开关：0|1；未设置则继承 profile
#   TPM               TPM 开关（0/1）；显式环境值覆盖主板 profile
#                     新配置按 BOARD_TPM_VERSION 自动选择；旧配置仍默认 TPM 2.0
#   MEM_GUARD/MEM_FORCE  prealloc 内存护栏及显式风险旁路
#   PROXY            QMP 原生多客户端开关（0/1，默认 0）
#   CPU_ISOLATION    auto|required|off（默认 required）
#   CPU_ISOLATION_AUTO_INSTALL  缺 helper/依赖时自动安装（0/1，默认 1）
#   QEMU_SERVICE_CPUS  非 vCPU 服务线程专用逻辑 CPU 数（默认 1）
#   HOST_RESERVE_CORES auto 或宿主保留物理核数（默认 auto）
#   STREAM_OUTPUT    显式网络 URL 或绝对输出文件；非空时启用区域推流
#   STREAM_ROI       X,Y,W,H；STREAM_RATE/ENCODER/BITRATE/PRESET/GOP/CONTAINER
#   STREAM_MODE      shm|auto|gpu（默认 shm；当前 R535 产品路径拒绝 gpu）
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
# 使 `TPM=0/1 ./start-vm.sh ...` 能作为真正的运行时覆盖。
TPM_ENV_WAS_SET=0
TPM_ENV_VALUE=""
if [[ -v TPM ]]; then
    TPM_ENV_WAS_SET=1
    TPM_ENV_VALUE=$TPM
fi
VGPU_GUEST_FINISH_TARGET_ENV=${VGPU_GUEST_FINISH_TARGET-}

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"

# shellcheck source=lib/vm-storage.sh
source "$here/lib/vm-storage.sh"

VM_ID="${1:-}"
if ! vm_storage_id_is_supported "$VM_ID"; then
    echo "usage: $0 <vm_id> [--vm-dir ABS|--instances-dir ABS] [--print-paths|--install [iso]|--native|--gtk|--rdp|--rescue-sdl|--no-gpu|--production-migration-source|--proxy|--cpu-isolate|--stream URL|--stream-roi X,Y,W,H|--no-tpm|--dry-run|--extra \"...\"]" >&2
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
PRINT_PATHS=0
START_VM_ARGS=()
while (( $# > 0 )); do
    case "$1" in
        --vm-dir|--instances-dir)
            storage_option=$1
            (( $# >= 2 )) || {
                echo "$storage_option 需要一个绝对路径" >&2
                exit 2
            }
            storage_value=$2
            if [[ "$storage_option" == --vm-dir ]]; then
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
        --vm-dir=*|--instances-dir=*)
            storage_option=${1%%=*}
            storage_value=${1#*=}
            [[ -n "$storage_value" ]] || {
                echo "$storage_option 需要一个绝对路径" >&2
                exit 2
            }
            if [[ "$storage_option" == --vm-dir ]]; then
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
        --vnc|--spoof-mode|--shmem|--svc-cpus|--stream|--stream-output|\
        --stream-roi|--stream-rate|--stream-encoder|--stream-bitrate|\
        --stream-preset|--stream-gop|--stream-container|--stream-mode|\
        --stream-start-timeout|--width|--height|--extra)
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

if [[ -n "$VM_DIR_CLI" && -n "$INSTANCES_DIR_CLI" ]]; then
    echo "--vm-dir 与 --instances-dir 不能同时使用" >&2
    exit 2
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
PRE_NAMESPACE_VM_DIR=$(vm_storage_pre_namespace_instance_dir "$VM_ID")
G11_MIGRATION_REQUIRED=0
if vm_storage_namespace_migration_required "$VM_ID"; then
    G11_MIGRATION_REQUIRED=1
fi

if (( PRINT_PATHS )); then
    printf 'VM_ID=%s\n' "$VM_ID"
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
    if (( G11_MIGRATION_REQUIRED )); then
        printf 'LEGACY_G11_DIR=%s\n' "$PRE_NAMESPACE_VM_DIR"
        printf 'MIGRATION_REQUIRED=1\n'
    else
        printf 'MIGRATION_REQUIRED=0\n'
    fi
    exit 0
fi

if (( G11_MIGRATION_REQUIRED )); then
    echo "[start-vm] 发现尚未迁移的旧 G-11 bundle，拒绝创建同 ID 的第二份 VM:" >&2
    echo "  old: $PRE_NAMESPACE_VM_DIR" >&2
    echo "  new: $SELECTED_VM_DIR" >&2
    echo "[start-vm] 先停止所有 G-11 VM，再运行 ./deploy/migrate-g11-layout.sh --check/--apply" >&2
    exit 1
fi
unset PRE_NAMESPACE_VM_DIR G11_MIGRATION_REQUIRED

# vm.conf and host policy files may describe guest hardware, but they may not
# redirect storage after the CLI selection and early config lookup are fixed.
readonly IMAGE_ROOT ISO_DIR STAGE_DIR VM_ROOT VM_INSTANCES_DIR \
    VM_INSTANCE_DIR VM_INSTANCE_ID VM_STORAGE_COMPAT_FALLBACK \
    VM_SHARED_DIR VM_CONFIG_DIR VM_DISK_DIR VM_BASE_DIR VM_NVRAM_DIR \
    VM_CONTROL_DIR VM_RUN_DIR VM_LOG_DIR VM_ASSET_DIR \
    VM_DISK_ARCHIVE_DIR VM_BASE_ARCHIVE_DIR VM_NVRAM_BACKUP_DIR
readonly SELECTED_VM_DIR

# Only export credentials when the caller supplied them through the process
# environment.  This repository never supplies a host password fallback.
if [[ -v SUDO_PASSWORD ]]; then
    export SUDO_PASSWORD
fi
# shellcheck source=lib/hardware-profiles.sh
source "$here/lib/hardware-profiles.sh"
# shellcheck source=lib/input-profiles.sh
source "$here/lib/input-profiles.sh"
input_profile_validate_catalog
# shellcheck source=lib/vm-tpm.sh
source "$here/lib/vm-tpm.sh"
# shellcheck source=lib/cpu-isolation.sh
source "$here/lib/cpu-isolation.sh"
# shellcheck source=lib/windows-unattend.sh
source "$here/lib/windows-unattend.sh"

# 宿主资源配置与 vmN/vm.conf 的 guest-visible identity 分开。正版
# Tesla V100 可在这里选 V100-2Q/V100D-2Q；vm.conf 仍可保持
# GTX 750 Ti/GT 1030/GTX 1050 等身份。显式指定的配置丢失时应
# 立即报错，默认本地文件不存在则保持旧行为。
VGPU_HOST_CONFIG_WAS_SET=0
[[ -v VGPU_HOST_CONFIG ]] && VGPU_HOST_CONFIG_WAS_SET=1
VGPU_HOST_CONFIG="${VGPU_HOST_CONFIG:-$here/host/vgpu-host.conf}"
if [[ -r "$VGPU_HOST_CONFIG" ]]; then
    # shellcheck source=/dev/null
    source "$VGPU_HOST_CONFIG"
elif [[ "$VGPU_HOST_CONFIG_WAS_SET" == 1 ]]; then
    echo "[start-vm] VGPU_HOST_CONFIG 不存在或不可读: $VGPU_HOST_CONFIG" >&2
    exit 1
fi
# Host policy is sourced before vm.conf and therefore participates in the real
# shell precedence.  Capture spoof inputs only now so the pre-storage guard
# sees exactly what the later parser would inherit.
SPOOF_MODE_ENV_VALUE=${SPOOF_MODE-}
SPOOF_ENV_VALUE=${SPOOF-}

# shellcheck source=lib/vgpu-mdev.sh
source "$here/lib/vgpu-mdev.sh"
# shellcheck source=lib/vgpu-profiles.sh
source "$here/lib/vgpu-profiles.sh"
# shellcheck source=lib/gnome-shortcuts.sh
source "$here/lib/gnome-shortcuts.sh"

# --dry-run 在常规参数解析之前就要可见，避免为了“只看 argv”而 bootstrap
# VM、磁盘或 runtime 目录。已有 VM 才能 dry-run；缺 config 时不给它猜配置。
EARLY_DRY_RUN="${DRY_RUN:-0}"
EARLY_SPOOF_MODE_OVERRIDE=""
EARLY_PRODUCTION_MIGRATION_SOURCE_REQUESTED=0
EARLY_ARGS=( "$@" )
for ((early_i = 0; early_i < ${#EARLY_ARGS[@]}; early_i += 1)); do
    case "${EARLY_ARGS[$early_i]}" in
        --dry-run) EARLY_DRY_RUN=1 ;;
        --production-migration-source)
            ((EARLY_PRODUCTION_MIGRATION_SOURCE_REQUESTED == 0)) || {
                echo "[start-vm] --production-migration-source may appear only once" >&2
                exit 2
            }
            EARLY_PRODUCTION_MIGRATION_SOURCE_REQUESTED=1
            ;;
        --no-spoof) EARLY_SPOOF_MODE_OVERRIDE=off ;;
        --spoof-name-only) EARLY_SPOOF_MODE_OVERRIDE=B ;;
        --spoof) EARLY_SPOOF_MODE_OVERRIDE=A ;;
        --spoof-mode)
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
        --stream|--stream-output|--stream-roi|--stream-rate|\
        --stream-encoder|--stream-bitrate|--stream-preset|--stream-gop|\
        --stream-container|--stream-mode|--stream-start-timeout)
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
    echo "[start-vm] strict-A startup is disabled: the legacy GTX 1050 path has no production-signature attestation and may depend on a modified/self-signed driver." >&2
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

EARLY_CONF=$(vm_storage_config_path "$VM_ID") || exit $?
EARLY_CONF_PRESENT=0
EARLY_CONF_SNAPSHOT=""
EARLY_CONF_FILE_SHA256=""
if [[ -e "$EARLY_CONF" || -L "$EARLY_CONF" ]]; then
    [[ -f "$EARLY_CONF" && ! -L "$EARLY_CONF" && -r "$EARLY_CONF" ]] || {
        echo "[start-vm] vm.conf must be a readable regular non-symlink file: $EARLY_CONF" >&2
        exit 2
    }
    if ((EARLY_PRODUCTION_MIGRATION_SOURCE_REQUESTED)); then
        EARLY_CONF_STAT_BEFORE=$(stat -Lc '%d:%i:%s:%Y:%Z' -- "$EARLY_CONF")
        EARLY_CONF_SHA_BEFORE=$(start_vm_sha256_upper "$EARLY_CONF")
    fi
    EARLY_CONF_SNAPSHOT=$(<"$EARLY_CONF")
    if ((EARLY_PRODUCTION_MIGRATION_SOURCE_REQUESTED)); then
        EARLY_CONF_SHA_AFTER=$(start_vm_sha256_upper "$EARLY_CONF")
        EARLY_CONF_STAT_AFTER=$(stat -Lc '%d:%i:%s:%Y:%Z' -- "$EARLY_CONF")
        [[ "$EARLY_CONF_SHA_BEFORE" == "$EARLY_CONF_SHA_AFTER" &&
           "$EARLY_CONF_STAT_BEFORE" == "$EARLY_CONF_STAT_AFTER" ]] \
            || production_migration_source_die \
                "vm.conf changed while its immutable snapshot was captured"
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

PRODUCTION_MIGRATION_SOURCE_AUTHORIZED=0
PRODUCTION_MIGRATION_EXPECTED_CONFIG_SHA256=""
PRODUCTION_MIGRATION_EXPECTED_UUID=""
PRODUCTION_MIGRATION_EXPECTED_PROFILE=""
PRODUCTION_MIGRATION_EXPECTED_GPU_NAME=""
PRODUCTION_MIGRATION_EXPECTED_ID=""
PRODUCTION_MIGRATION_STATE_PATH=""
if ((EARLY_PRODUCTION_MIGRATION_SOURCE_REQUESTED)); then
    production_migration_source_authorize
    echo "[start-vm] production-migration-source authorized for this invocation only: migration ${PRODUCTION_MIGRATION_EXPECTED_ID}"
fi
readonly PRODUCTION_MIGRATION_SOURCE_AUTHORIZED \
    PRODUCTION_MIGRATION_EXPECTED_CONFIG_SHA256 \
    PRODUCTION_MIGRATION_EXPECTED_UUID \
    PRODUCTION_MIGRATION_EXPECTED_PROFILE \
    PRODUCTION_MIGRATION_EXPECTED_GPU_NAME \
    PRODUCTION_MIGRATION_EXPECTED_ID \
    PRODUCTION_MIGRATION_STATE_PATH

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
    EARLY_PRODUCTION_MIGRATION_SOURCE_REQUESTED

if [[ "$EARLY_DRY_RUN" != 1 ]]; then
    # Shared for the complete QEMU lifetime.  The explicit storage migrator
    # takes this lock exclusively, so a VM cannot start halfway through moves.
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
    echo "[start-vm] $CONF 不存在，自动 ./create-vm.sh ${VM_ID}"
    VM_START_LOCK_HELD=1 "$here/create-vm.sh" "$VM_ID"
    CONF=$(vm_storage_config_path "$VM_ID")
    [[ -f "$CONF" && ! -L "$CONF" && -r "$CONF" ]] || {
        echo "[start-vm] create-vm did not publish a safe readable vm.conf: $CONF" >&2
        exit 2
    }
    EARLY_CONF_SNAPSHOT=$(<"$CONF")
fi
# Guest-visible controller identity must come from vm.conf, never from a
# caller environment accidentally inherited by the launcher.
unset XHCI_PCI_VENDOR_ID XHCI_PCI_DEVICE_ID XHCI_PCI_REVISION \
    XHCI_PCI_BUS XHCI_PCI_ADDR
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
unset EARLY_CONF EARLY_CONF_PRESENT EARLY_CONF_SNAPSHOT
unset CONFIG_VM_ID_AFTER_SOURCE

[[ "${VM_UUID:-}" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || {
    echo "[start-vm] VM_UUID 缺失或非法: ${VM_UUID:-<缺失>}" >&2
    exit 2
}

# New vm.conf files persist the complete xHCI PCI tuple.  An all-missing set
# is a legacy config: retain the exact historical CPU-derived behavior rather
# than changing an existing Windows device node during a launcher upgrade.
# A partial set is corruption and must never be guessed.
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
        echo "[start-vm] WARN: 旧 vm.conf 缺少 xHCI PCI identity；保留历史按 CPU_MODEL 推导行为，不改写 guest tuple" >&2
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
for other_conf in "$VM_INSTANCES_DIR"/vm*/vm.conf "$VM_CONFIG_DIR"/vm*.conf; do
    [[ -f "$other_conf" ]] || continue
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
unset other_conf other_uuid

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
# nvidia-257 绑死。
if [[ -z "${GPU_NAME:-}" || -z "${GPU_CORE_MHZ:-}" ||
      -z "${GPU_BOOST_MHZ:-}" || -z "${GPU_MEMORY_MHZ:-}" ]]; then
    vgpu_profile_load "$GPU_PROFILE"
fi
: "${VGPU_MDEV_PROFILE:=nvidia-257}"
: "${VGPU_FB_MB:=2048}"
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

# New profiles persist audited USB HID identities.  Old immutable vm.conf files
# receive one fixed compatibility identity instead of rerolling on every boot.
if [[ -z "${KBD_VID:-}" || -z "${KBD_PID:-}" ||
      -z "${KBD_MFR:-}" || -z "${KBD_PRODUCT:-}" ]]; then
    input_profile_load_keyboard_default
fi
if [[ -z "${TABLET_VID:-}" || -z "${TABLET_PID:-}" ||
      -z "${TABLET_MFR:-}" || -z "${TABLET_PRODUCT:-}" ]]; then
    input_profile_load_tablet_default
fi
input_keyboard_profile_allowed "$KBD_VID" "$KBD_PID" "$KBD_MFR" \
    "$KBD_PRODUCT" || {
    echo "[start-vm] 键盘 USB identity 不在已审核目录中: $KBD_VID:$KBD_PID $KBD_PRODUCT" >&2
    exit 2
}
input_tablet_profile_allowed "$TABLET_VID" "$TABLET_PID" "$TABLET_MFR" \
    "$TABLET_PRODUCT" || {
    echo "[start-vm] 绝对坐标指针 USB identity 不在已审核目录中: $TABLET_VID:$TABLET_PID $TABLET_PRODUCT" >&2
    exit 2
}

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
        echo "[start-vm] 请使用 create-vm.sh --force --ssd-profile 选择兼容 profile（已有盘需先迁移）" >&2
        exit 2
    fi
    echo "[start-vm] WARN: 旧 vm.conf 缺少 SSD PCIe 链路元数据；保留历史 $PLATFORM/$SSD_INTERFACE 启动行为" >&2
    echo "[start-vm] WARN: 新建 VM 会严格匹配主板链路；现有盘请先迁移再补齐存储 profile" >&2
fi

MODE=native          # 默认 vGPU + SDL 直显；ramfb 承接早期 OVMF 画面
GFX_BACKEND="${GFX_BACKEND:-sdl}"
INSTALL_GFX_BACKEND="${INSTALL_GFX_BACKEND:-gtk}"

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
QEMU_SDL_DISABLE_IBUS="${QEMU_SDL_DISABLE_IBUS:-auto}"
QEMU_SDL_PRESENT_MODE="${QEMU_SDL_PRESENT_MODE:-fixed}"

should_tame_gnome_super() {
    local mode=${TAME_GNOME,,}
    case "$mode" in
        1|yes|true|on) return 0 ;;
        0|no|false|off) return 1 ;;
    esac
    gnome_super_shortcuts_is_gnome && gnome_super_shortcuts_available
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
QEMU_SERVICE_CPUS="${QEMU_SERVICE_CPUS:-1}"
HOST_RESERVE_CORES="${HOST_RESERVE_CORES:-auto}"
CPU_ISOLATION_QMP_TIMEOUT="${CPU_ISOLATION_QMP_TIMEOUT:-90}"
STREAM_OUTPUT="${STREAM_OUTPUT:-}"
STREAM_ROI="${STREAM_ROI:-}"
STREAM_RATE="${STREAM_RATE:-30}"
STREAM_ENCODER="${STREAM_ENCODER:-libx264}"
STREAM_BITRATE="${STREAM_BITRATE:-6M}"
STREAM_PRESET="${STREAM_PRESET:-veryfast}"
STREAM_GOP="${STREAM_GOP:-60}"
STREAM_CONTAINER="${STREAM_CONTAINER:-}"
STREAM_MODE="${STREAM_MODE:-shm}"
STREAM_START_TIMEOUT="${STREAM_START_TIMEOUT:-15}"
STREAM_ENABLED=0
[[ -n "$STREAM_OUTPUT" ]] && STREAM_ENABLED=1
NATIVE_FULLSCREEN=0
VGPU_ROMBAR="${VGPU_ROMBAR:-}"
VGPU_ROMFILE="${VGPU_ROMFILE:-}"
VGPU_CONSOLE_INTERVAL_US="${VGPU_CONSOLE_INTERVAL_US:-16667}"
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
        --rdp)     MODE=rdp; shift ;;
        --legacy-shmem) MODE=rdp; shift ;;
        --native)  MODE=native; shift ;;
        --gtk)     MODE=vgpu-gtk; shift ;;
        --sdl)     MODE=vgpu-sdl; shift ;;
        --vgpu-gtk) MODE=vgpu-gtk; shift ;;
        --vgpu-sdl) MODE=vgpu-sdl; shift ;;
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
        # Authorization was decided by the pre-storage verifier from the same
        # immutable argv/config snapshot.  The full parser only consumes the
        # process-local flag; vm.conf/environment values cannot create it.
        --production-migration-source) shift ;;
        --proxy) PROXY=1; shift ;;
        --no-proxy) PROXY=0; shift ;;
        --cpu-isolate) CPU_ISOLATION=required; shift ;;
        --cpu-isolate-auto) CPU_ISOLATION=auto; shift ;;
        --no-cpu-isolate) CPU_ISOLATION=off; shift ;;
        --svc-cpus)
            require_cli_value "$1" "$#"
            QEMU_SERVICE_CPUS="$2"; shift 2 ;;
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
        --no-stream) STREAM_ENABLED=0; STREAM_OUTPUT=""; shift ;;
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

case "$SPOOF_MODE" in
    A|B|off) ;;
    *) echo "SPOOF_MODE 必须是 A、B 或 off: $SPOOF_MODE" >&2; exit 2 ;;
esac

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
        echo "SPOOF_MODE=A 内部 PCI identity 要求 16-bit GPU_PCI_DID/GPU_SUB_DID: ${GPU_PCI_DID:-<missing>}/${GPU_SUB_DID:-<missing>}" >&2
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

if [[ "$PRODUCTION_MIGRATION_SOURCE_AUTHORIZED" == 1 ]]; then
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
    [[ "$MODE" == vgpu-gtk || "$MODE" == vgpu-sdl ]] && \
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
[[ "$PROXY" == 0 || "$PROXY" == 1 ]] || {
    echo "PROXY 必须是 0 或 1" >&2; exit 2;
}
cpu_isolation_normalize_mode || {
    echo "CPU_ISOLATION 必须是 auto、required 或 off" >&2; exit 2;
}
[[ "$QEMU_SERVICE_CPUS" =~ ^[0-9]+$ && "$QEMU_SERVICE_CPUS" -le 64 ]] || {
    echo "QEMU_SERVICE_CPUS/--svc-cpus 必须是 0..64" >&2; exit 2;
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
[[ "$INSTALL_UNATTENDED" == 0 || "$INSTALL_UNATTENDED" == 1 ]] || {
    echo "INSTALL_UNATTENDED 必须是 0 或 1" >&2; exit 2;
}
[[ "$MONITOR_SYNC" == 0 || "$MONITOR_SYNC" == 1 ]] || {
    echo "MONITOR_SYNC 必须是 0 或 1" >&2; exit 2;
}
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

# Fail before publishing a blank disk when the requested/default ISO is wrong.
if [[ "$MODE" == install && ! -f "$ISO" ]]; then
    echo "ISO 不存在: $ISO" >&2
    exit 1
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
        SIZE_BYTES="$SSD_SIZE_BYTES" "$here/create-disk.sh" "$VM_ID" --blank
        DISK_PATH=$(vm_storage_disk_path "$VM_ID")
    else
        BASE_PATH=$(vm_storage_base_path)
        if [[ ! -f "$BASE_PATH" ]]; then
            echo "[start-vm] $DISK_PATH 不存在，且没有可克隆的公共 base: $BASE_PATH" >&2
            echo "[start-vm] 首次安装请用: $0 ${VM_ID} --install [/absolute/windows.iso]" >&2
            exit 1
        fi
        echo "[start-vm] $DISK_PATH 不存在，自动从公共 base 创建实例盘"
        "$here/create-disk.sh" "$VM_ID" --from-base
        DISK_PATH=$(vm_storage_disk_path "$VM_ID")
    fi
fi

: "${QEMU_BIN:=$here/../build/qemu-system-x86_64}"
: "${QEMU_IMG:=$here/../build/qemu-img}"
[[ -x "$QEMU_IMG" ]] || QEMU_IMG=$(command -v qemu-img || true)
: "${OVMF_CODE:=$here/host/OVMF_CODE_4M_stealth.fd}"
: "${OVMF_VARS:=/usr/share/OVMF/OVMF_VARS_4M.fd}"
: "${BR0:=br0}"
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
    if [[ "$VM_STORAGE_QCOW2_VIRTUAL_SIZE" != "$SSD_SIZE_BYTES" ]]; then
        echo "[start-vm] 磁盘容量与硬件 profile 不一致，拒绝启动" >&2
        echo "  qcow2:  $VM_STORAGE_QCOW2_VIRTUAL_SIZE 字节" >&2
        echo "  profile: $SSD_SIZE_BYTES 字节 ($SSD_MODEL)" >&2
        echo "[start-vm] 请备份后迁移/扩容 qcow2，或恢复与磁盘匹配的 SSD profile" >&2
        exit 1
    fi
fi

# NVIDIA 535 mdev 没有 VFIO_GFX_EDID_REGION，不能把 EDID 直接交给 Windows。
# 默认在 QEMU 启动前、磁盘确定离线时按需刷新 Windows 自己
# 的 EDID 缓存；只改系统 hive，不向 guest 复制脚本、安装服务或创建计划任务。
if [[ "$DRY_RUN" != 1 && "$MONITOR_SYNC" == 1 ]]; then
    case "$MODE" in
        vgpu-gtk|vgpu-sdl|rdp)
            echo "[start-vm] 检查 host 侧离线显示器 EDID（guest 内不安装组件）..."
            QEMU_EDID_BIN="${QEMU_EDID:-$(dirname "$QEMU_BIN")/qemu-edid}"
            monitor_sync_rc=0
            VM_START_LOCK_HELD=1 QEMU_EDID="$QEMU_EDID_BIN" \
                MONITOR_SYNC_SPOOF_MODE="$SPOOF_MODE" \
                "$here/sync-monitor-profile.sh" "$VM_ID" || monitor_sync_rc=$?
            case "$monitor_sync_rc" in
                0) ;;
                10)
                    echo "[start-vm] WARN: Windows 尚未缓存显示器；本次先启动枚举，" >&2
                    echo "[start-vm]       正常关机后，下次启动会在 host 离线完成同步" >&2
                    ;;
                11)
                    echo "[start-vm] ERROR: Windows 处于休眠/Fast Startup；vGPU 恢复可能触发 0x10E" >&2
                    echo "[start-vm]        不要强制挂载磁盘，也不要用 VNC/RDP。运行一键恢复：" >&2
                    echo "[start-vm]          ./deploy/finish-vgpu-install.sh ${VM_ID}" >&2
                    echo "[start-vm]        它会打开本地 SDL 救援窗口，并在完整关机后自动同步 RTC/EDID。" >&2
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

# 本仓库的最新 q35 machine 以 4096 MiB 为单位生成每条 SMBIOS
# Type 17。新 profile 显式记录真实单条容量和已插条数；旧配置
# 缺字段时按同一 4 GiB 拆分规则补齐。
MEM_TOPOLOGY_LEGACY=0
if [[ -z "${MEM_MODULE_MB:-}" || -z "${MEM_SLOTS:-}" ]]; then
    MEM_TOPOLOGY_LEGACY=1
fi
if [[ -z "${MEM_MODULE_MB:-}" && -z "${MEM_SLOTS:-}" ]]; then
    MEM_MODULE_MB=4096
    (( GUEST_MEM_MB % MEM_MODULE_MB == 0 )) || {
        echo "旧配置的 GUEST_MEM_MB=$GUEST_MEM_MB 无法拆成 4096 MiB DIMM" >&2
        exit 2
    }
    MEM_SLOTS=$((GUEST_MEM_MB / MEM_MODULE_MB))
elif [[ -z "${MEM_MODULE_MB:-}" ]]; then
    [[ "$MEM_SLOTS" =~ ^[1-9][0-9]*$ ]] || {
        echo "MEM_SLOTS 必须是正整数: ${MEM_SLOTS:-<empty>}" >&2
        exit 2
    }
    (( GUEST_MEM_MB % MEM_SLOTS == 0 )) || {
        echo "GUEST_MEM_MB=$GUEST_MEM_MB 不能被 MEM_SLOTS=$MEM_SLOTS 整除" >&2
        exit 2
    }
    MEM_MODULE_MB=$((GUEST_MEM_MB / MEM_SLOTS))
elif [[ -z "${MEM_SLOTS:-}" ]]; then
    [[ "$MEM_MODULE_MB" =~ ^[1-9][0-9]*$ ]] || {
        echo "MEM_MODULE_MB 必须是正整数: ${MEM_MODULE_MB:-<empty>}" >&2
        exit 2
    }
    (( GUEST_MEM_MB % MEM_MODULE_MB == 0 )) || {
        echo "GUEST_MEM_MB=$GUEST_MEM_MB 不能被 MEM_MODULE_MB=$MEM_MODULE_MB 整除" >&2
        exit 2
    }
    MEM_SLOTS=$((GUEST_MEM_MB / MEM_MODULE_MB))
fi
[[ "$MEM_MODULE_MB" =~ ^[1-9][0-9]*$ && "$MEM_SLOTS" =~ ^[1-9][0-9]*$ ]] || {
    echo "MEM_MODULE_MB/MEM_SLOTS 必须是正整数: ${MEM_MODULE_MB:-?}/${MEM_SLOTS:-?}" >&2
    exit 2
}
(( MEM_MODULE_MB * MEM_SLOTS == GUEST_MEM_MB )) || {
    echo "内存 profile 不一致: ${MEM_SLOTS} x ${MEM_MODULE_MB} MiB != GUEST_MEM_MB ${GUEST_MEM_MB} MiB" >&2
    exit 2
}
(( MEM_MODULE_MB == 4096 )) || {
    echo "当前 q35 SMBIOS 只支持 4096 MiB DIMM，profile 给出 ${MEM_MODULE_MB} MiB" >&2
    exit 2
}
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
    echo "[start-vm] WARN: 旧 vm.conf 缺少 DIMM 容量/条数，已按 4 GiB 拆分；建议 --force 重生成以匹配真实 4 GB 料号" >&2
fi

# memory-backend-memfd 使用 prealloc=on；在分配 mdev、启动 swtpm 之前先
# 确认 host RAM + swap 至少能容纳本 VM，避免 OOM killer 连带杀掉其它 VM。
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

[[ -x "$QEMU_BIN" ]] || { echo "QEMU 不存在或没执行权: $QEMU_BIN" >&2; exit 1; }
[[ -r "$OVMF_CODE" ]] || { echo "OVMF_CODE 不存在或不可读: $OVMF_CODE" >&2; exit 1; }
[[ -r "$OVMF_VARS" ]] || { echo "OVMF_VARS 不存在或不可读: $OVMF_VARS" >&2; exit 1; }

STREAM_HELPER="$here/fb-shm-stream.sh"
STREAM_BIN="${QEMU_FB_SHM_STREAM_BIN:-$here/../build/qemu-fb-shm-stream}"
STREAM_SOCKET="$(vm_storage_instance_run_dir "$VM_ID")/fb-shm.sock"
if ((STREAM_ENABLED)); then
    [[ "$STREAM_SOCKET" == /* && ${#STREAM_SOCKET} -lt 104 &&
       "$STREAM_SOCKET" != *,* && "$STREAM_SOCKET" != *$'\n'* &&
       "$STREAM_SOCKET" != *$'\r'* ]] ||
        stream_config_error "fb-shm socket 路径必须是无逗号的短绝对路径"
    if ! "$QEMU_BIN" -object fb-shm,help 2>&1 |
            grep -q '^  path=<string>'; then
        echo "[start-vm] QEMU 未编译可并行 SDL/GTK 的 fb-shm object" >&2
        exit 1
    fi
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

VM_PATTERN="qemu-system-x86_64.*-name[[:space:]]+vm${VM_ID}([,[:space:]]|$)"
vm_is_running() {
    pgrep -f "$VM_PATTERN" >/dev/null 2>&1
}

if [[ "$DRY_RUN" != 1 ]] && vm_is_running; then
    echo "[start-vm] vm${VM_ID} QEMU 已在跑 — 先 ./stop-vm.sh ${VM_ID}" >&2
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
cleanup_started_tpm() {
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
}
trap cleanup_started_tpm EXIT

case "$MODE" in
    vgpu-gtk) WINDOW_BACKEND=gtk ;;
    vgpu-sdl) WINDOW_BACKEND=sdl ;;
    *)                  WINDOW_BACKEND="" ;;
esac
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
    rdp|vgpu-gtk|vgpu-sdl)
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
    case "${QEMU_SDL_DISABLE_IBUS,,}" in
        auto)
            [[ "${XMODIFIERS:-}" == *@im=ibus* ]] && \
                QEMU_SDL_DISABLE_IBUS_ACTIVE=1 || QEMU_SDL_DISABLE_IBUS_ACTIVE=0
            ;;
        1|yes|true|on) QEMU_SDL_DISABLE_IBUS_ACTIVE=1 ;;
        0|no|false|off) QEMU_SDL_DISABLE_IBUS_ACTIVE=0 ;;
        *)
            echo "QEMU_SDL_DISABLE_IBUS 必须是 auto 或 0/1: $QEMU_SDL_DISABLE_IBUS" >&2
            exit 2
            ;;
    esac
    if (( QEMU_SDL_DISABLE_IBUS_ACTIVE )); then
        # Ubuntu SDL 2.30's IBus cursor-location callback can dereference a
        # vanished XWayland window when a USB keyboard/mouse KVM disconnects.
        # QEMU forwards hardware key events to Windows, so host-side IME
        # composition is neither required nor desirable for this console.
        export IBUS_ADDRESS=/nonexistent
        if [[ "$DRY_RUN" != 1 ]]; then
            echo "[start-vm] SDL host IBus 已隔离（避免键鼠热拔插触发 SDL2 崩溃）"
        fi
    fi
    if [[ "$DRY_RUN" != 1 ]]; then
        if [[ "$QEMU_SDL_PRESENT_MODE" == fixed ]]; then
            echo "[start-vm] SDL Present 模式：固定 60Hz（默认）"
        else
            echo "[start-vm] SDL Present 模式：动态（仅画面变化时 Present）"
        fi
    fi

    if [[ -r "$QEMU_SDL_WINDOWS_CURSOR" ]]; then
        export QEMU_SDL_WINDOWS_CURSOR
    elif [[ "$DRY_RUN" != 1 ]]; then
        echo "[start-vm] Windows cursor 资源不可读，使用内置 fallback: $QEMU_SDL_WINDOWS_CURSOR" >&2
    fi

    if should_tame_gnome_super; then
        export GNOME_SUPER_GUARD="$here/gnome-super-guard.sh"
        export QEMU_SDL_TAME_GNOME=1
        if [[ "$DRY_RUN" != 1 ]]; then
            "$GNOME_SUPER_GUARD" restore-stale 2>/dev/null || true
            echo "[start-vm] SDL 宿主快捷键保护已启用：窗口聚焦且鼠标在窗口内时，Super/Alt+Tab 交给 guest"
        fi
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
    install|no-gpu|rescue-sdl|rescue-gtk) EXPECTED_CONOUT_DEV=02 ;;
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

# ─── CPU 真机 part number / 频率 / brand (按 CPU 型号查表) ─────────────
case "$CPU_MODEL" in
    Core-i5-4590)
        CPU_PART=SR1QJ; CPU_BASE_MHZ=3300; CPU_MAX_MHZ=3700
        CPU_SMBIOS_FAMILY=205 # DMTF: Intel Core i5
        CPU_SOCKET_UPGRADE=0x2D # SMBIOS: Socket LGA1150
        XHCI_DEVICE_ID=0x8CB1   # Intel 9 Series xHCI (H97)
        GPU_ROOT_PORT_DEVICE_ID=0x0C01 # Haswell PCIe x16 controller
        GPU_ROOT_PORT_REVISION=0x06
        CPU_L2_ASSOC=7          # SMBIOS: 8-way
        CPU_BRAND_STRING='Intel(R) Core(TM) i5-4590 CPU @ 3.30GHz'
        ;;
    Core-i5-6500)
        CPU_PART=SR2L6; CPU_BASE_MHZ=3200; CPU_MAX_MHZ=3600
        CPU_SMBIOS_FAMILY=205 # DMTF: Intel Core i5
        CPU_SOCKET_UPGRADE=0x32 # SMBIOS: Socket LGA1151
        XHCI_DEVICE_ID=0xA12F   # Intel 100 Series/C230 xHCI
        GPU_ROOT_PORT_DEVICE_ID=0x1901 # Skylake PCIe x16 controller
        GPU_ROOT_PORT_REVISION=0x07
        CPU_L2_ASSOC=5          # SMBIOS: 4-way
        CPU_BRAND_STRING='Intel(R) Core(TM) i5-6500 CPU @ 3.20GHz'
        ;;
    Core-i3-8100)
        CPU_PART=SR3N5; CPU_BASE_MHZ=3600; CPU_MAX_MHZ=3600
        CPU_SMBIOS_FAMILY=206 # DMTF: Intel Core i3
        CPU_SOCKET_UPGRADE=0x32 # SMBIOS: Socket LGA1151
        XHCI_DEVICE_ID=0xA36D   # Intel 300 Series xHCI
        GPU_ROOT_PORT_DEVICE_ID=0x1901 # 6th-10th Gen PCIe x16 controller
        GPU_ROOT_PORT_REVISION=0x07
        CPU_L2_ASSOC=5          # SMBIOS: 4-way
        CPU_BRAND_STRING='Intel(R) Core(TM) i3-8100 CPU @ 3.60GHz'
        ;;
    *)
        CPU_PART=UNKN; CPU_BASE_MHZ=$(( TSC_FREQ / 1000000 )); CPU_MAX_MHZ=$CPU_BASE_MHZ
        CPU_SMBIOS_FAMILY=1 # Other
        CPU_SOCKET_UPGRADE=0x01 # Other
        XHCI_DEVICE_ID=0xA36D
        GPU_ROOT_PORT_DEVICE_ID=0x1901
        GPU_ROOT_PORT_REVISION=0x07
        CPU_L2_ASSOC=5
        CPU_BRAND_STRING='Intel(R) Core(TM) CPU'
        ;;
esac

if [[ "$XHCI_IDENTITY_LEGACY" == 1 ]]; then
    XHCI_PCI_VENDOR_ID=0x8086
    XHCI_PCI_DEVICE_ID=$XHCI_DEVICE_ID
    XHCI_PCI_REVISION=0x01
    XHCI_PCI_BUS=pcie.0
    XHCI_PCI_ADDR=0x6
fi

# The second occupied slot represents the Intel CT desktop network adapter.
# Slot wiring differs materially between these real boards; do not describe a
# nonexistent x1 slot on GA-B150M-D3H.
case "${BOARD_MODEL:-}" in
    GA-H97-D3H)
        PCIE_MAIN_SLOT=PCIEX16
        PCIE_AUX_SLOT=PCIEX1_1
        PCIE_AUX_TYPE=171       # PCI Express Gen2
        PCIE_AUX_WIDTH=8        # x1
        PCIE_AUX_LENGTH=3       # Short
        ;;
    GA-B150M-D3H)
        PCIE_MAIN_SLOT=PCIEX16
        PCIE_AUX_SLOT=PCIEX4
        PCIE_AUX_TYPE=177       # PCI Express Gen3
        PCIE_AUX_WIDTH=10       # x4
        PCIE_AUX_LENGTH=4       # physical x16 long slot, electrical x4
        ;;
    'PRIME B360M-A')
        PCIE_MAIN_SLOT=PCIEX16
        PCIE_AUX_SLOT=PCIEX1_1
        PCIE_AUX_TYPE=177       # PCI Express Gen3
        PCIE_AUX_WIDTH=8        # x1
        PCIE_AUX_LENGTH=3       # Short
        ;;
    *)
        PCIE_MAIN_SLOT=PCIEX16_1
        PCIE_AUX_SLOT=PCIEX1_1
        PCIE_AUX_TYPE=171
        PCIE_AUX_WIDTH=8
        PCIE_AUX_LENGTH=3
        ;;
esac

case "${MEM_FAMILY:-}" in
    DDR3)  MEM_VOLTAGE_MV=1500 ;;
    DDR3L) MEM_VOLTAGE_MV=1350 ;;
    *)     MEM_VOLTAGE_MV=1200 ;;
esac
# QEMU splits q35 RAM into one SMBIOS Type 17 record per populated DIMM.  The
# patched SMBIOS layer accepts a | delimited serial list; derive a deterministic,
# distinct value for every module instead of cloning MEM_SN.
if [[ "$MEM_SN" =~ ^[0-9A-Fa-f]{8}$ ]]; then
    MEM_SERIALS=${MEM_SN^^}
else
    legacy_mem_sn=$(printf '%s' "$MEM_SN" | sha256sum)
    MEM_SERIALS=${legacy_mem_sn:0:8}
    MEM_SERIALS=${MEM_SERIALS^^}
    echo "[start-vm] WARN: 旧 MEM_SN 不是 8 位十六进制 SPD 序列号，已稳定归一化" >&2
fi
for ((mem_i = 2; mem_i <= MEM_SLOTS; mem_i += 1)); do
    mem_sn_i=$(printf '%s' "${MEM_SN}-dimm${mem_i}" | sha256sum)
    mem_sn_i=${mem_sn_i:0:8}
    MEM_SERIALS+="|${mem_sn_i^^}"
done
unset legacy_mem_sn mem_i mem_sn_i

# Four-slot consumer boards normally populate A2/B2 first.  The remaining
# Type 17 records describe the real empty A1/B1 sockets rather than inventing
# duplicate A2/B2 or CHANNEL C/D labels.
if (( MEM_BOARD_SLOTS == 4 && MEM_SLOTS == 2 )); then
    MEM_LOCATORS='DIMM_A2|DIMM_B2|DIMM_A1|DIMM_B1'
    MEM_BANKS='P0 CHANNEL A|P0 CHANNEL B|P0 CHANNEL A|P0 CHANNEL B'
else
    MEM_LOCATORS=DIMM
    MEM_BANKS='P0 CHANNEL'
fi

case "${MEM_FAMILY:-}" in
    DDR3|DDR4)
        export QEMU_SPD_TYPE=$MEM_FAMILY
        export QEMU_SPD_MODULE_MB=$MEM_MODULE_MB
        export QEMU_SPD_SPEED_MT=$MEM_SPEED
        export QEMU_SPD_SLOTS=$MEM_SLOTS
        ;;
    *)
        unset QEMU_SPD_TYPE QEMU_SPD_MODULE_MB QEMU_SPD_SPEED_MT QEMU_SPD_SLOTS
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
SMBIOS+=( -smbios "type=4,sock_pfx=CPU,manufacturer=Intel(R) Corporation,version=${CPU_BRAND_STRING},max-speed=${CPU_MAX_MHZ},current-speed=${CPU_BASE_MHZ},serial=To Be Filled By O.E.M.,asset=To Be Filled By O.E.M.,part=${CPU_PART},processor-family=${CPU_SMBIOS_FAMILY},processor-characteristics=0xEC,external-clock=100,voltage=0x8C,processor-upgrade=${CPU_SOCKET_UPGRADE}" )
# type 7 (Cache) — 一条 unified 记录表示四核合计容量：
# L1=4*(32 KiB data + 32 KiB instruction)=256 KiB，L2=4*256 KiB，
# L3=6 MiB/12-way。Haswell L2 为 8-way，Skylake/Coffee Lake 为 4-way。
SMBIOS+=( -smbios "type=7,socket_designation=L1 Cache,level=1,installed_size=256,max_size=256,associativity=7,cache_type=5" )
SMBIOS+=( -smbios "type=7,socket_designation=L2 Cache,level=2,installed_size=1024,max_size=1024,associativity=${CPU_L2_ASSOC},cache_type=5" )
SMBIOS+=( -smbios "type=7,socket_designation=L3 Cache,level=3,installed_size=6144,max_size=6144,associativity=9,cache_type=5" )
# type 9 (System Slots) — 主显卡槽是 Gen3 x16；第二个已占用槽严格
# 跟随主板实际布线，用于解释 Intel CT add-in NIC。
#   slot_type: 0xB1 = PCI Express Gen 3 (width comes from data_bus_width)
#              0xAB = PCI Express Gen 2 (width comes from data_bus_width)
#   current_usage: 0x03 Available, 0x04 In Use
#   slot_length: 0x03 Short, 0x04 Long
#   chars1 0x0C (3.3V + shared opening); chars2 0x01 (PME)
SMBIOS+=( -smbios "type=9,slot_designation=${PCIE_MAIN_SLOT},slot_type=177,slot_data_bus_width=13,current_usage=4,slot_length=4,slot_id=1,slot_characteristics1=12,slot_characteristics2=1" )
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
SMBIOS+=( -smbios "type=17,loc_pfx=${MEM_LOCATORS},bank=${MEM_BANKS},manufacturer=${MEM_BRAND},part=${MEM_MODEL},serial=${MEM_SERIALS},asset=9876543210,speed=${MEM_SPEED},memtype=${MEM_TYPE_BYTE},typedetail=0x80,width=${MEM_WIDTH},totalwidth=${MEM_WIDTH},rank=1,voltage=${MEM_VOLTAGE_MV}" )

# ─── CPU / machine 参数 ─────────────────────────────────────────────────────
# kvm=off 关 KVM 签名；x-hv-stealth=on 关 HYPERVISOR bit；
# +invtsc 让 rdtsc 对 guest 稳定。
#
# 这里不用 `enforce`：宿主是 E5-2696 v4 Broadwell，而 Core-i5-6500/i3-8100
# 的 Skylake+ 指令 (clflushopt/xsavec/xgetbv1) 宿主 KVM 无法提供；enforce 会
# 让 QEMU 拒绝启动。让 QEMU 自动降级给 warning 即可 —— guest 里 CPUID 里这
# 几位会是 0，TP 并不逐位校验 Skylake 特有扩展。
CPU_ARGS="${CPU_MODEL},kvm=off,x-hv-stealth=on,+invtsc,vmx=off,hypervisor=off,vmware-cpuid-freq=off,tsc-freq=${TSC_FREQ}"
MACHINE_ARGS="q35,accel=kvm,vmport=off,smm=on,kernel-irqchip=split,hpet=off,i8042=off"
MACHINE_ARGS+=",x-oem-id=ALASKA,x-oem-table-id=A M I"  # 覆盖 QEMU ACPI OEM ID (QEMU→AMI)

# ─── 网络 ───────────────────────────────────────────────────────────────────
NET_ARGS=( -netdev "bridge,id=net0,br=${BR0}" -device "e1000e,netdev=net0,mac=${VM_MAC},subsys_ven=0x8086,subsys=0xA01F,bus=pcie.0,addr=0x4" )

# ─── 存储 (NVMe 呈现 SSD 品牌/型号/序列号) ─────────────────────────────────
# SATA profile 挂到 Q35 板载 ICH9-AHCI；NVMe profile 使用 PCIe NVMe controller。
DRIVE_ARGS=()
DRIVE_ARGS+=( -drive "file=${DISK},if=none,id=ssd0,discard=unmap,format=qcow2,cache=none,aio=native" )
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

# ─── 安装光驱：只在 --install 模式挂载  ───────────────────────
# Q35 板载 ICH9-AHCI (VEN_8086&DEV_2922) 默认会自动创建一个空
# ide-cd；只删掉显式 -device 仍会让 Windows 看到光驱。QEMU 会在
# -global 引用某默认驱动时抑制该驱动的自动设备；普通模式因此
# 只传递一个无害的 ide-cd 全局属性，不创建任何光驱前端。
# --install 则显式挂 Windows ISO，bootindex=1（优先于系统盘=2）。
: "${ODD_MODEL:=TSSTcorp CDDVDW SH-224DB}"
: "${ODD_SERIAL:=R8PG6VCD${VM_ID}23456}"  # 每 VM 微调避免冲突
if [[ "$MODE" == "install" ]]; then
    [[ -f "$ISO" ]] || { echo "ISO 不存在: $ISO" >&2; exit 1; }
    DRIVE_ARGS+=( -drive "file=${ISO},if=none,id=odd0,media=cdrom,readonly=on" )
    DRIVE_ARGS+=( -device "ide-cd,drive=odd0,bus=ide.0,bootindex=1,model=${ODD_MODEL},serial=${ODD_SERIAL}" )
    if [[ -n "$UNATTEND_ISO" ]]; then
        DRIVE_ARGS+=( -drive "file=${UNATTEND_ISO},if=none,id=answer0,media=cdrom,readonly=on,format=raw" )
        # ide.1 may contain a SATA system disk; use a separate AHCI port.
        DRIVE_ARGS+=( -device "ide-cd,drive=answer0,bus=ide.2,model=HL-DT-ST DVDRAM GH24NSD5,serial=K9AF${VM_ID}012345" )
    fi
else
    DRIVE_ARGS+=( -global ide-cd.bootindex=-1 )
fi

# ─── 图形 / vGPU ──────────────────────────────────────────────────────────
GFX_ARGS=()

attach_vgpu_root_port() {
    local gpu_link_width

    case "$GPU_PROFILE" in
        gt1030_2gb)               gpu_link_width=4 ;;
        gtx750ti_2gb|gtx1050_2gb) gpu_link_width=16 ;;
        *)
            echo "[start-vm] GPU profile 缺少 PCIe 链路拓扑: $GPU_PROFILE" >&2
            return 1
            ;;
    esac
    # VFIO turns a PCIe endpoint directly attached to pcie.0 into an RC
    # integrated endpoint and clears its Link Capability/Status registers.
    # A real desktop GPU sits below a root port.  Keep the bridge at the old
    # 00:10.0 location and put the GPU at 01:00.0 so the endpoint retains its
    # PCIe capability.  GTX 750 Ti/1050 use x16; GT 1030 is electrically x4.
    GFX_ARGS+=(
        -device "pcie-root-port,id=gpu-root-port,bus=pcie.0,addr=0x10,port=0x10,chassis=1,slot=1,hotplug=off,x-speed=8,x-width=${gpu_link_width},x-pci-vendor-id=0x8086,x-pci-device-id=${GPU_ROOT_PORT_DEVICE_ID},x-pci-revision=${GPU_ROOT_PORT_REVISION}"
    )
}

allocate_vgpu() {
    local mdev_identity_name=""
    local identity_backend_available=0
    local -a mdev_identity_args=()
    local -a mdev_internal_pci_args=()
    [[ "$SPOOF_MODE" == B || "$SPOOF_MODE" == A ]] && \
        mdev_identity_name=$GPU_NAME
    if (( VGPU_MDEV_INTERNAL_PCI_ACTIVE )); then
        mdev_internal_pci_args=(
            "$VGPU_MDEV_INTERNAL_VDEV_ID"
            "$VGPU_MDEV_INTERNAL_PDEV_ID"
        )
    fi
    if (( VGPU_MDEV_FRL_OVERRIDE_ACTIVE )); then
        # The mdev library keeps its historical positional PCI pair.  Empty
        # placeholders mean "no internal PCI override, only FRL".
        if (( VGPU_MDEV_INTERNAL_PCI_ACTIVE == 0 )); then
            mdev_internal_pci_args=("" "")
        fi
        mdev_internal_pci_args+=("$VGPU_MDEV_FRL_ENABLED")
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
                    "${mdev_internal_pci_args[@]}"
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
                "${mdev_internal_pci_args[@]}"
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
    mdev_allocate "${VGPU_RESOURCE_PROFILE}" "$MDEV_UUID" \
        "$VGPU_RESOURCE_FB_MB" "${mdev_identity_args[@]}" >/dev/null || {
        echo "mdev 分配失败 — 排查 sudo / VGPU_MGPU=${VGPU_MGPU:-?} / host driver/profile" >&2
        return 1
    }
    MDEV_RECOVERY_FILE=$(vm_storage_run_preferred_path "$VM_ID" mdev)
    printf '%s\n' "$MDEV_UUID" >"$MDEV_RECOVERY_FILE"
    cleanup_allocated_mdev() {
        if mdev_release "$MDEV_UUID" &&
                [[ ! -L "$MDEV_DEVICES_DIR/$MDEV_UUID" ]]; then
            rm -f "$MDEV_RECOVERY_FILE"
        else
            echo "[start-vm] mdev 回收失败，保留 $MDEV_RECOVERY_FILE ($MDEV_UUID)" >&2
        fi
        cleanup_started_tpm
    }
    trap cleanup_allocated_mdev EXIT
    if [[ "$MODE" == vgpu-sdl || "$MODE" == vgpu-gtk ]]; then
        mdev_configure_console_interval \
            "$MDEV_UUID" "$VGPU_CONSOLE_INTERVAL_US" || {
            echo "mdev console 刷新周期配置失败" >&2
            return 1
        }
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
            gtk) GFX_ARGS+=( -display gtk,gl=off ) ;;
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
            rescue-gtk) GFX_ARGS+=( -display gtk,gl=off ) ;;
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
        if [[ "$SPOOF_MODE" == "A" ]]; then
            vfio_opts+=",x-pci-vendor-id=${GPU_PCI_VID},x-pci-device-id=${GPU_PCI_DID}"
            vfio_opts+=",x-pci-sub-vendor-id=${GPU_SUB_VID},x-pci-sub-device-id=${GPU_SUB_DID}"
        fi
        GFX_ARGS+=( -device "vfio-pci-nohotplug,${vfio_opts}" -vga none )
        case "$MODE" in
            vgpu-sdl)
                GFX_ARGS+=( -display "sdl,gl=on" ) ;;
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
QMP_ARGS=( -qmp "unix:${QMP_SOCK},server,nowait" )
if [[ "$PROXY" == 1 ]]; then
    # 本分支 QEMU 原生为每个连接创建独立 QMP monitor；不再启动 Python
    # 中转进程。保留 -qmp shorthand，供依赖 QEMU argv 的工具识别。
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

INPUT_ARGS=(
    -device "qemu-xhci,id=xhci,bus=${XHCI_PCI_BUS},addr=${XHCI_PCI_ADDR},x-pci-vendor-id=${XHCI_PCI_VENDOR_ID},x-pci-device-id=${XHCI_PCI_DEVICE_ID},x-pci-revision=${XHCI_PCI_REVISION}"
    -device "usb-kbd,bus=xhci.0,vendorid=${KBD_VID},productid=${KBD_PID},manufacturer=${KBD_MFR},product=${KBD_PRODUCT}"
    -device "usb-tablet,bus=xhci.0,vendorid=${TABLET_VID},productid=${TABLET_PID},manufacturer=${TABLET_MFR},product=${TABLET_PRODUCT}"
)

echo "启动 VM ${VM_ID} 模式=${MODE}"
echo "  VM 目录: $(vm_storage_instance_dir "$VM_ID")"
echo "  配置: ${CONF}"
echo "  磁盘: ${DISK}"
if [[ "$PROXY" == 1 ]]; then
    echo "  QMP multi: native multi-client on ${QMP_SOCK}"
    echo "  QMP alias: ${QMP_PROXY_SOCK}"
fi
echo "  CPU: ${CPU_MODEL}@${TSC_FREQ}Hz"
cpu_isolation_print_plan
echo "  主板: ${BOARD_BRAND} ${BOARD_MODEL} / ${VM_UUID}"
echo "  内存: ${MEM_SLOTS} x ${MEM_MODULE_MB} MiB ${MEM_MODEL} (${MEM_FAMILY:-unknown}@${MEM_SPEED})"
if [[ "$SSD_INTERFACE" == nvme ]]; then
    echo "  SSD: ${SSD_MODEL} / ${SSD_INTERFACE}:${SSD_CONTROLLER_PROFILE} / PCIe ${SSD_PCIE_GEN}.0 x${SSD_PCIE_LANES} ${SSD_FORM_FACTOR} / fw=${SSD_FIRMWARE_REV} / sector=${SSD_LOGICAL_BLOCK_SIZE}/${SSD_PHYSICAL_BLOCK_SIZE}B / ${SSD_SIZE_BYTES} bytes"
else
    echo "  SSD: ${SSD_MODEL} / ${SSD_INTERFACE}:${SSD_CONTROLLER_PROFILE} / SATA 6Gb/s ${SSD_FORM_FACTOR} / fw=${SSD_FIRMWARE_REV} / sector=${SSD_LOGICAL_BLOCK_SIZE}/${SSD_PHYSICAL_BLOCK_SIZE}B / ${SSD_SIZE_BYTES} bytes"
fi
echo "  键盘: ${KBD_PRODUCT} / usb-kbd / USB ${KBD_VID#0x}:${KBD_PID#0x}"
echo "  鼠标: ${TABLET_PRODUCT} / usb-tablet 绝对坐标 / USB ${TABLET_VID#0x}:${TABLET_PID#0x}"
echo "  GPU identity: ${GPU_PROFILE} / ${GPU_NAME} (configured target, not host PCI identity)"
case "$SPOOF_MODE" in
    A)
        echo "  GPU target: ${GPU_NAME} (name + consumer PCI ID spoof)" ;;
    B)
        echo "  GPU name target: ${GPU_NAME} (system PCI identity remains host mdev; catalog PCI tuple is app-local to GPU-Z/NVAPI)" ;;
    off)
        echo "  GPU target: disabled (profile metadata ${GPU_PROFILE} is not applied)" ;;
esac
if (( VGPU_MDEV_INTERNAL_PCI_ACTIVE )); then
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
        echo "  显示: vGPU console -> ${WINDOW_BACKEND} (ramfb early boot, 无 guest relay)" ;;
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
        RTC_ARGS=( -rtc base=localtime,clock=host,driftfix=slew )
        PIT_LOST_TICK_POLICY=delay
        echo "  RTC: host localtime (${TZ}) / clock=host"
        ;;
    utc|utc-compat)
        RTC_ARGS=( -rtc base=utc,clock=host,driftfix=slew )
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
    -smp 4,sockets=1,cores=4,threads=1
    -m "$GUEST_MEM_MB"
    -object "memory-backend-memfd,id=ram0,size=${GUEST_MEM_MB}M,share=on,prealloc=on"
    -numa node,memdev=ram0
    "${RTC_ARGS[@]}"
    -global "kvm-pit.lost_tick_policy=${PIT_LOST_TICK_POLICY}"
    -global ICH9-LPC.disable_s3=1
    "${TPM_ARGS[@]}"
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
    -drive "if=pflash,format=raw,file=$VARS_PRIV"
    "${SMBIOS[@]}"
    -uuid "$VM_UUID"
    "${NET_ARGS[@]}"
    "${DRIVE_ARGS[@]}"
    "${GFX_ARGS[@]}"
    "${STREAM_QEMU_ARGS[@]}"
    "${INPUT_ARGS[@]}"
    -device intel-hda,bus=pcie.0,addr=0x7 -device hda-duplex
    "${IVSHMEM_ARGS[@]}"
    -monitor "unix:${MON_SOCK},server,nowait"
    "${QMP_ARGS[@]}"
    -pidfile "$PIDFILE"
    $EXTRA
)

[[ "$NATIVE_FULLSCREEN" == 1 ]] && QEMU_CMD+=( -full-screen )
# required 模式从暂停状态启动；root helper 完成 cgroup + TID 绑核后
# pinner 才通过 QMP cont 放行 guest，保证 guest 不会先无隔离运行。
[[ "$CPU_ISOLATION" == required ]] && QEMU_CMD+=( -S )

if [[ "$DRY_RUN" == 1 ]]; then
    echo "[start-vm] DRY_RUN QEMU argv (每行一个参数):"
    printf '  %q\n' "${QEMU_CMD[@]}"
    exit 0
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
start_vm_timing_mark qemu-launch
printf '%s\n' "${START_VM_TIMING_LINES[@]}" >>"$QEMU_LOG"

if ! cpu_isolation_launch "$VM_ID" 4 "$QMP_SOCK" "$PIDFILE" \
        "$CPU_ISOLATION_STATE_FILE"; then
    echo "[start-vm] required CPU 隔离无法启动" >&2
    exit 1
fi

# 非 rdp 模式都是"QEMU 直接挂前台显示"——install/vgpu-gtk/vgpu-sdl 都让 QEMU 自己
# 弹窗（-display sdl/gtk），no-gpu 走旧 VNC 远程。这些路径不需要一条龙
# (setup-task + ivshmem viewer)，因为：
#   - install: guest 还没装 Windows / 在 UEFI shell，没法跑 nv_stream_relay
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
        "${QEMU_CMD[@]}" 2> >(tee -a "$QEMU_LOG" >&2) &
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
    "${QEMU_CMD[@]}" 2> >(tee -a "$QEMU_LOG" >&2)
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
    "$here/stop-vm.sh" "$VM_ID" || "$here/stop-vm.sh" "$VM_ID" --force || true
    cleanup_started_tpm
    gnome_super_shortcuts_restore
    "$here/gnome-super-guard.sh" restore-stale 2>/dev/null || true
    exit 0
}
trap cleanup_all INT TERM EXIT

# 1) QEMU 后台启 + 重定向 stderr 到 log（tmux 会破坏数组里的引号 — 之前
# 试过 `tmux new-session "${QEMU_CMD[*]}"`，QEMU 一启动就 crash 因为
# `-machine "q35,accel=kvm,..."` 这种逗号串被 shell 重新分词搞乱）。
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

    # 根据 SPOOF_MODE 决定 setup-guest 跑哪几步：
    #   A / B: 跑 stealth (name spoof) + monitor (EDID spoof)
    #   off:   都跳过
    # Automatic repair keeps the guest-minimal contract.  Product names come
    # from the host per-mdev override; registry tasks and NVAPI DLL replacement
    # remain explicit compatibility operations.
    SG_ARGS=("--ip" "$guest_ip" "--skip-stealth" "--skip-nvapi-shim" "--skip-input")
    [[ "${SPOOF_MODE:-B}" == "off" ]] && SG_ARGS+=("--skip-stealth" "--skip-monitor")

    # 注意：DCH driver 不再拷 nvlddmkm.sys 到 system32\drivers，而是从
    # DriverStore 加载 — sys=False 不能作 driver 缺失的判据。用 err==-1
    # (Win32_VideoController 完全找不到 NVIDIA 适配器) + ver 错 来判断。
    if [[ "$ver" != "$EXPECT_VER" || "$err" == "-1" ]]; then
        echo "[setup-task] driver 状态错: ver='${ver}' err=${err} (期望 ver=${EXPECT_VER})"
        if [[ "${SPOOF_MODE:-B}" == "A" ]]; then
            echo "[setup-task] !! 当前 A 模式下驱动未正确绑定；不在运行中的显示设备上重装。"
            echo "[setup-task]    恢复：./stop-vm.sh ${VM_ID}"
            echo "[setup-task]          ./start-vm.sh ${VM_ID} --no-spoof --no-monitor-sync"
            echo "[setup-task]    当前生产路径统一保持 B/name-only；不要恢复 legacy consumer-ID driver。"
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
    while pgrep -f "$VM_PATTERN" >/dev/null; do sleep 3; done
    kill "$VIEWER_PID" 2>/dev/null
) &
WATCH_PID=$!

wait "$VIEWER_PID" || true
