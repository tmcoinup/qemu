#!/usr/bin/env bash
# Create a new B/native VM configuration and a standalone disk copy from the
# portable-enabled Windows base.  No per-VM guest package is generated.
set -euo pipefail
umask 077

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$here"

# shellcheck source=lib/vm-storage.sh
source "$here/lib/vm-storage.sh"
# shellcheck source=lib/vgpu-profiles.sh
source "$here/lib/vgpu-profiles.sh"
# shellcheck source=lib/gpuz-assets.sh
source "$here/lib/gpuz-assets.sh"
vm_storage_init

usage() {
    cat <<'EOF'
usage: ./deploy/scripts/clone-from-base.sh BASE_NAME NEW_VM_ID [options]

Options:
  --list-bases               Print available managed base names
  --gpu-profile PROFILE      Any atomic row printed by --list-gpu-profiles
                             (default: choose one audited row at random)
  --gpu-vram 1024|2048      Lock MB capacity, then randomize within that pool
  --list-gpu-profiles        Print all audited model/AIB/VRAM-maker rows
  --platform PROFILE         Forward to create-vm.sh
  --cpu-profile PROFILE      Forward to create-vm.sh
  --board-profile PROFILE    Forward to create-vm.sh
  --memory-profile PROFILE   Forward to create-vm.sh
  --memory-size 4G|6G|8G    Lock capacity, then auto-pick an audited layout
  --allow-fallback-platform Show/authorize a legacy compatibility platform
  --ssd-profile PROFILE      Forward to create-vm.sh
  --monitor-profile PROFILE  Forward to create-vm.sh
  --monitor-sync             Apply the generated monitor profile after clone
                             (default)
  --no-monitor-sync          Skip only for explicit rescue/debugging
  --start                    Start the new VM after cloning
  -h, --help                 Show this help

The public base must first be prepared once:
  ./deploy/scripts/seal-base.sh SOURCE_VM_ID BASE_NAME
  ./deploy/package-vgpu-one-click.sh
  sudo ./deploy/install-vgpu-portable-to-base.sh --base-name BASE_NAME

The cloned guest contains the generic identity/performance VgpuPortable.exe on
the Public Desktop. GPU-Z is not required and is absent from a default-prepared
base; an explicit base opt-in is recorded in the attestation.  If --gpu-profile or
--monitor-profile is omitted, create-vm.sh selects from the corresponding
audited pool and records the result in vm.conf.  Clone applies the monitor
profile automatically; every normal start-vm.sh start verifies both persisted
identities again.
EOF
}

die() {
    echo "[vgpu-clone] ERROR: $*" >&2
    exit 1
}

BASE_NAME=""
VM_ID=""
GPU_PROFILE_REQUEST="${GPU_PROFILE:-}"
GPU_PROFILE_EXPLICIT=0
GPU_VRAM_MB_REQUEST=""
START_AFTER=0
MONITOR_SYNC=1
declare -a CREATE_ARGS=()
declare -a POSITIONAL=()
while (($#)); do
    case "$1" in
        --gpu-profile)
            (($# >= 2)) || die "--gpu-profile requires a value"
            GPU_PROFILE_REQUEST=$2
            GPU_PROFILE_EXPLICIT=1
            shift 2
            ;;
        --gpu-vram)
            (($# >= 2)) || die "--gpu-vram requires a value"
            GPU_VRAM_MB_REQUEST=$(vgpu_profile_normalize_vram_mb "$2") || exit $?
            shift 2
            ;;
        --list-gpu-profiles)
            vgpu_profile_print_catalog
            exit 0
            ;;
        --list-bases)
            vm_storage_list_base_names
            exit 0
            ;;
        --platform|--cpu-profile|--board-profile|--memory-profile|--memory-size|--ssd-profile|--monitor-profile)
            (($# >= 2)) || die "$1 requires a value"
            CREATE_ARGS+=("$1" "$2")
            shift 2
            ;;
        --allow-fallback-platform)
            CREATE_ARGS+=("$1")
            shift
            ;;
        --start)
            START_AFTER=1
            shift
            ;;
        --monitor-sync)
            MONITOR_SYNC=1
            shift
            ;;
        --no-monitor-sync)
            MONITOR_SYNC=0
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --*)
            die "unknown option: $1"
            ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done
if (( GPU_PROFILE_EXPLICIT )) && [[ -n "$GPU_VRAM_MB_REQUEST" ]]; then
    die "--gpu-profile and --gpu-vram cannot be used together"
fi
if [[ -n "$GPU_VRAM_MB_REQUEST" ]]; then
    GPU_PROFILE_REQUEST=""
fi
if ((${#POSITIONAL[@]} != 2)); then
    usage >&2
    exit 2
fi
BASE_NAME=${POSITIONAL[0]}
VM_ID=${POSITIONAL[1]}
vm_storage_validate_base_name "$BASE_NAME" || exit 2
vm_storage_validate_id "$VM_ID" || exit 2
vm_storage_require_namespace_ready "$VM_ID"
vgpu_profile_validate_catalog ||
    die "GPU profile catalog validation failed"
if [[ -n "$GPU_PROFILE_REQUEST" ]]; then
    vgpu_profile_load "$GPU_PROFILE_REQUEST" ||
        die "unsupported --gpu-profile: $GPU_PROFILE_REQUEST"
fi
EXPECTED_CATALOG_SHA256=$(vgpu_profile_catalog_sha256)
[[ "$EXPECTED_CATALOG_SHA256" =~ ^[0-9A-F]{64}$ ]] ||
    die "could not calculate the current GPU profile catalog hash"

for dependency in jq stat flock; do
    command -v "$dependency" >/dev/null 2>&1 ||
        die "missing dependency: $dependency"
done
vm_storage_prepare
exec {STORAGE_LOCK_FD}>"$VM_RUN_DIR/.storage.lock"
flock -s "$STORAGE_LOCK_FD"
vm_storage_prepare_instance "$VM_ID"
START_LOCK=$(vm_storage_run_path "$VM_ID" start.lock)
exec {START_LOCK_FD}>"$START_LOCK"
if ! flock -n -x "$START_LOCK_FD"; then
    die "vm${VM_ID} is starting, running, or being modified"
fi
BASE=$(vm_storage_base_path "$BASE_NAME")
ATTESTATION="${BASE}.vgpu-portable.json"
[[ -f "$BASE" && ! -L "$BASE" ]] ||
    die "standalone Windows base is missing: $BASE"
[[ -f "$ATTESTATION" && ! -L "$ATTESTATION" ]] ||
    die "base has no portable-package attestation; run install-vgpu-portable-to-base.sh"
BASE_FILE_BYTES=$(stat -c %s -- "$BASE")
BASE_DEVICE_ID=$(stat -c %D -- "$BASE")
BASE_INODE=$(stat -c %i -- "$BASE")
BASE_MTIME_NS=$(stat -c %y -- "$BASE")
BASE_CTIME_NS=$(stat -c %z -- "$BASE")
jq -e \
    --arg basePath "$BASE" \
    --argjson baseFileBytes "$BASE_FILE_BYTES" \
    --arg baseDeviceId "$BASE_DEVICE_ID" \
    --arg baseInode "$BASE_INODE" \
    --arg baseMtimeNs "$BASE_MTIME_NS" \
    --arg baseCtimeNs "$BASE_CTIME_NS" \
    --arg catalogSha256 "$EXPECTED_CATALOG_SHA256" \
    --arg gpuZSha256 "$GPUZ_ASSET_SHA256" \
    --argjson gpuZBytes "$GPUZ_ASSET_BYTES" '
    (keys | sort) == [
        "baseCtimeNs", "baseDeviceId", "baseFileBytes", "baseInode",
        "baseMtimeNs", "basePath", "bindingMode", "catalogSha256",
        "gpuZBytes", "gpuZDelivery", "gpuZGuestPath", "gpuZIncluded",
        "gpuZSha256", "guestPerformance",
        "installedUtc", "portableBytes", "portableGuestPath",
        "portableSha256", "schemaVersion"
    ] and
    .schemaVersion == 5 and .bindingMode == "portable-auto" and
    .basePath == $basePath and .baseFileBytes == $baseFileBytes and
    .baseDeviceId == $baseDeviceId and .baseInode == $baseInode and
    .baseMtimeNs == $baseMtimeNs and .baseCtimeNs == $baseCtimeNs and
    .portableGuestPath == "C:\\Users\\Public\\Desktop\\VgpuPortable.exe" and
    (.portableSha256 | test("^[0-9A-F]{64}$")) and
    (.portableBytes | type) == "number" and
    (.portableBytes | floor) == .portableBytes and .portableBytes > 0 and
    .gpuZDelivery == "optional-explicit-sibling" and
    .guestPerformance == "embedded-recommended-native-v1" and
    (.gpuZIncluded | type) == "boolean" and
    (if .gpuZIncluded then
        .gpuZGuestPath == "C:\\Users\\Public\\Desktop\\GPU-Z.exe" and
        .gpuZSha256 == $gpuZSha256 and .gpuZBytes == $gpuZBytes
     else
        .gpuZGuestPath == null and .gpuZSha256 == null and .gpuZBytes == null
     end) and
    .catalogSha256 == $catalogSha256 and
    (.installedUtc | type) == "string"
' "$ATTESTATION" >/dev/null ||
    die "base/catalog changed after portable installation; re-run install-vgpu-portable-to-base.sh"
BASE_GPUZ_INCLUDED=$(jq -r '.gpuZIncluded' "$ATTESTATION")

INSTANCE_DIR=$(vm_storage_instance_dir "$VM_ID")
EXISTING_CONF=$(vm_storage_config_path "$VM_ID") ||
    die "vm${VM_ID} configuration paths are ambiguous"
if [[ -e "$EXISTING_CONF" || -L "$EXISTING_CONF" ]]; then
    die "vm${VM_ID} configuration already exists"
fi
DISK=$(vm_storage_disk_path "$VM_ID")
[[ ! -e "$DISK" && ! -L "$DISK" ]] ||
    die "vm${VM_ID} disk already exists: $DISK"

CREATED_CONF=""
CREATED_CONF_ID=""
CLONE_COMMITTED=0
cleanup_clone() {
    if (( ! CLONE_COMMITTED )) && [[ -n "$CREATED_CONF" &&
            -f "$CREATED_CONF" && ! -L "$CREATED_CONF" &&
            ! -e "$DISK" && ! -L "$DISK" &&
            "$(stat -Lc '%d:%i' -- "$CREATED_CONF")" == "$CREATED_CONF_ID" ]]; then
        rm -f -- "$CREATED_CONF" || true
        echo "[vgpu-clone] rolled back the newly created VM configuration" >&2
    fi
}
trap cleanup_clone EXIT

declare -a GPU_CREATE_ARGS=()
if [[ -n "$GPU_PROFILE_REQUEST" ]]; then
    GPU_CREATE_ARGS=(--gpu-profile "$GPU_PROFILE_REQUEST")
    GPU_SELECTION_LABEL=$GPU_PROFILE_REQUEST
elif [[ -n "$GPU_VRAM_MB_REQUEST" ]]; then
    GPU_CREATE_ARGS=(--gpu-vram "$GPU_VRAM_MB_REQUEST")
    GPU_SELECTION_LABEL="${GPU_VRAM_MB_REQUEST}MB constrained random GPU"
else
    GPU_SELECTION_LABEL='random audited GPU profile'
fi
echo "[vgpu-clone] creating vm${VM_ID} / ${GPU_SELECTION_LABEL}"
VM_START_LOCK_HELD=1 "$here/scripts/create-vm.sh" "$VM_ID" \
    "${GPU_CREATE_ARGS[@]}" "${CREATE_ARGS[@]}"
CONF=$(vm_storage_config_path "$VM_ID") ||
    die "new VM configuration was not published"
[[ -f "$CONF" && ! -L "$CONF" ]] ||
    die "new VM configuration is not a regular non-symlink file"
CREATED_CONF=$CONF
CREATED_CONF_ID=$(stat -Lc '%d:%i' -- "$CONF")
if ! (
    unset SPOOF_MODE GPU_PROFILE VM_UUID
    # shellcheck source=/dev/null
    source "$CONF"
    [[ "$SPOOF_MODE" == B &&
       "$VM_UUID" =~ ^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$ ]] &&
        vgpu_profile_load "$GPU_PROFILE" &&
        [[ -z "$GPU_PROFILE_REQUEST" ||
           "$GPU_PROFILE" == "$GPU_PROFILE_REQUEST" ]] &&
        [[ -z "$GPU_VRAM_MB_REQUEST" ||
           "$GPU_VRAM_MB" == "$GPU_VRAM_MB_REQUEST" ]]
); then
    die "new VM configuration failed the B/native identity check"
fi
SELECTED_GPU_PROFILE=$(
    unset GPU_PROFILE
    # shellcheck source=/dev/null
    source "$CONF"
    printf '%s' "$GPU_PROFILE"
)
vgpu_profile_load "$SELECTED_GPU_PROFILE" ||
    die "new VM configuration selected an unknown GPU profile"
[[ -z "$GPU_VRAM_MB_REQUEST" || "$GPU_VRAM_MB" == "$GPU_VRAM_MB_REQUEST" ]] ||
    die "new VM configuration escaped the requested ${GPU_VRAM_MB_REQUEST}MB GPU pool"
GPU_PROFILE_REQUEST=$SELECTED_GPU_PROFILE

if ! "$here/scripts/create-disk.sh" "$VM_ID" --from-base \
        --base-name "$BASE_NAME"; then
    die "base cloning failed; the new configuration will be rolled back when no disk was published"
fi
[[ -f "$DISK" && ! -L "$DISK" ]] ||
    die "base cloning returned success without a regular VM disk"
CLONE_COMMITTED=1
trap - EXIT

MONITOR_SYNC_RESULT=disabled
if (( MONITOR_SYNC )); then
    echo "[vgpu-clone] applying the vm.conf monitor profile automatically"
    monitor_sync_rc=0
    VM_START_LOCK_HELD=1 \
        "$here/scripts/sync-monitor-profile.sh" "$VM_ID" || monitor_sync_rc=$?
    case "$monitor_sync_rc" in
        0)
            MONITOR_SYNC_RESULT=complete
            ;;
        10)
            MONITOR_SYNC_RESULT=first-enumeration-deferred
            echo "[vgpu-clone] Windows 尚无可更新的显示器缓存；首次启动会先枚举，完整关机后的下一次正常启动会自动完成同步"
            ;;
        11)
            echo "[vgpu-clone] ERROR: 克隆已保留，但 base 卷处于休眠/Fast Startup；未启动 vm${VM_ID}" >&2
            echo "[vgpu-clone]        请先按恢复流程完整关机，再运行 ./deploy/scripts/start-vm.sh ${VM_ID}" >&2
            exit 11
            ;;
        *)
            echo "[vgpu-clone] ERROR: 克隆已保留，但显示器自动同步失败（rc=${monitor_sync_rc}）；未启动 vm${VM_ID}" >&2
            echo "[vgpu-clone]        排障后直接运行 ./deploy/scripts/start-vm.sh ${VM_ID}，启动器会自动重试" >&2
            exit "$monitor_sync_rc"
            ;;
    esac
fi

cat <<EOF
[vgpu-clone] PASS
  VM:          vm${VM_ID}
  base name:   ${BASE_NAME}
  base image:  ${BASE}
  GPU profile: ${GPU_PROFILE_REQUEST}
  GPU VRAM:    ${GPU_VRAM_MB} MB
  config:      ${CONF}
  disk:        ${DISK}
  monitor:     vm.conf / automatic sync=${MONITOR_SYNC_RESULT}
  performance: embedded recommended-native-v1
  portable:    C:\\Users\\Public\\Desktop\\VgpuPortable.exe
  GPU-Z:       $(if [[ "$BASE_GPUZ_INCLUDED" == true ]]; then printf 'included by explicit base opt-in'; else printf 'not included (default)'; fi)

Windows 启动后直接双击 VgpuPortable.exe。默认只读取本次启动的只读
profile/UUID 声明、自动选择整行型号/板卡/显存厂商，安装查询工具并应用推荐的
登录启动/native-display 性能优化；不依赖 GPU-Z，也不需要 HTTP 或关机后再执行
host commit。看到最终 INSTALL PASS 后完整关机并正常冷启动。以后选装 GPU-Z 时，把
审核版本放在 EXE 同目录并运行 VgpuPortable.exe /with-gpuz。

显示器不由 VgpuPortable.exe 处理。显式选择或自动生成的 monitor profile
已经固定在 vm.conf；clone 已自动尝试同步，每次正常 start-vm.sh 也会在
实例盘关机时校验 Windows EDID_OVERRIDE。新 base 尚未枚举过显示器时，
第一次启动只负责枚举；完整关机后下一次启动会自动完成，无需另跑命令。
vmctl.sh monitor --force 只用于关机态切换型号或强制修复缓存。
EOF

if ((START_AFTER)); then
    flock -u "$START_LOCK_FD"
    exec {START_LOCK_FD}>&-
    flock -u "$STORAGE_LOCK_FD"
    exec {STORAGE_LOCK_FD}>&-
    start_args=( "$VM_ID" )
    (( MONITOR_SYNC )) || start_args+=( --no-monitor-sync )
    exec "$here/scripts/start-vm.sh" "${start_args[@]}"
fi
