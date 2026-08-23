#!/usr/bin/env bash
# Create a new B/native VM configuration and, by default, a V-11-style
# incremental qcow2 from the portable-enabled Windows base. Private Sysprep
# clones also receive one VM-bound, read-only system-NVAPI projection ISO
# generated after vm.conf is fixed and before the instance disk is published.
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

usage() {
    cat <<'EOF'
usage: ./deploy/scripts/clone-from-base.sh BASE_NAME_OR_QCOW2 NEW_VM_ID [options]

Options:
  --list-bases               Print available managed base names
  --vms-dir DIRECTORY        VM root (also accepts --vms-dir=DIRECTORY)
  --base-dir DIRECTORY       Base directory (default: VMS_DIR/_base; also
                             accepts --base-dir=DIRECTORY)
  --linked                   V-11-style incremental qcow2 (default): pin the
                             base inode inside the VM and store only changes
  --full-copy                Create an independent standalone qcow2 (uses about
                             the same host space as the base)
  --gpu-profile PROFILE      Any atomic row printed by --list-gpu-profiles
                             (default: choose one audited row at random)
  --gpu-vram 1024|2048       Lock MB capacity, then randomize within that pool
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

The base may be selected by name from VMS_DIR/_base, by name plus --base-dir,
or by an exact .qcow2 path, matching V-11 command semantics. Prepare a private
Sysprep base once with:
  ./deploy/build-g11-private-base.sh SOURCE_VM_ID BASE_NAME

A private Sysprep clone runs its licensed VgpuPortable.exe automatically from
C:\ProgramData\VMate\G11; no licensed EXE remains on the Desktop. Legacy
non-Sysprep bases keep their explicitly attested manual workflow. GPU-Z is not
required. If --gpu-profile or --monitor-profile is omitted, create-vm.sh
selects from the corresponding audited pool and records the result in vm.conf.
Clone applies the monitor profile automatically; every normal start-vm.sh
start verifies both persisted identities again.
EOF
}

die() {
    echo "[vgpu-clone] ERROR: $*" >&2
    exit 1
}
sha256_upper() { sha256sum -- "$1" | awk '{print toupper($1)}'; }

BASE_NAME=""
BASE_ARG=""
BASE=""
BASE_EXPLICIT=0
VM_ID=""
GPU_PROFILE_REQUEST="${GPU_PROFILE:-}"
GPU_PROFILE_EXPLICIT=0
GPU_VRAM_MB_REQUEST=""
START_AFTER=0
MONITOR_SYNC=1
LIST_BASES=0
LIST_GPU_PROFILES=0
CLI_VMS_DIR=""
CLI_BASE_DIR=""
CLONE_DISK_MODE=linked
CLONE_DISK_MODE_SET=0
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
            LIST_GPU_PROFILES=1
            shift
            ;;
        --list-bases)
            LIST_BASES=1
            shift
            ;;
        --vms-dir)
            (($# >= 2)) || die "--vms-dir requires a directory"
            [[ -z "$CLI_VMS_DIR" ]] || die "--vms-dir may be specified once"
            CLI_VMS_DIR=$2
            shift 2
            ;;
        --vms-dir=*)
            [[ -z "$CLI_VMS_DIR" ]] || die "--vms-dir may be specified once"
            CLI_VMS_DIR=${1#*=}
            shift
            ;;
        --base-dir)
            (($# >= 2)) || die "--base-dir requires a directory"
            [[ -z "$CLI_BASE_DIR" ]] || die "--base-dir may be specified once"
            CLI_BASE_DIR=$2
            shift 2
            ;;
        --base-dir=*)
            [[ -z "$CLI_BASE_DIR" ]] || die "--base-dir may be specified once"
            CLI_BASE_DIR=${1#*=}
            shift
            ;;
        --linked)
            ((CLONE_DISK_MODE_SET == 0)) || die "--linked/--full-copy may be specified once"
            CLONE_DISK_MODE=linked
            CLONE_DISK_MODE_SET=1
            shift
            ;;
        --full-copy)
            ((CLONE_DISK_MODE_SET == 0)) || die "--linked/--full-copy may be specified once"
            CLONE_DISK_MODE=copy
            CLONE_DISK_MODE_SET=1
            shift
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
if [[ -n "$CLI_VMS_DIR" ]]; then
    [[ "$CLI_VMS_DIR" == /* && "$CLI_VMS_DIR" != / ]] ||
        die "--vms-dir must be a non-root absolute path"
    export VM_ROOT=${CLI_VMS_DIR%/}
    export VMS_DIR=$VM_ROOT
    export VM_INSTANCES_DIR=$VM_ROOT
fi
if [[ -n "$CLI_BASE_DIR" ]]; then
    [[ "$CLI_BASE_DIR" == /* && "$CLI_BASE_DIR" != / ]] ||
        die "--base-dir must be a non-root absolute path"
    export VM_BASE_DIR=${CLI_BASE_DIR%/}
    export VM_BASE_ARCHIVE_DIR="$VM_BASE_DIR/archive"
fi
vm_storage_init
if ((LIST_GPU_PROFILES)); then
    vgpu_profile_print_catalog
    exit 0
fi
if ((LIST_BASES)); then
    vm_storage_list_base_names
    exit 0
fi

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
BASE_ARG=${POSITIONAL[0]}
VM_ID=${POSITIONAL[1]}
if [[ "$BASE_ARG" == */* || "${BASE_ARG,,}" == *.qcow2 ]]; then
    [[ "${BASE_ARG,,}" == *.qcow2 ]] ||
        die "explicit base path must end in .qcow2"
    [[ ! -L "$BASE_ARG" ]] || die "base cannot be a symbolic link: $BASE_ARG"
    BASE=$(realpath -e -- "$BASE_ARG") || die "base does not exist: $BASE_ARG"
    [[ -f "$BASE" && ! -L "$BASE" ]] ||
        die "base must be a regular non-symlink file: $BASE"
    BASE_NAME=$(basename -- "$BASE")
    BASE_NAME=${BASE_NAME%.qcow2}
    vm_storage_validate_base_name "$BASE_NAME" || exit 2
    BASE_EXPLICIT=1
else
    BASE_NAME=$BASE_ARG
    vm_storage_validate_base_name "$BASE_NAME" || exit 2
fi
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

for dependency in jq stat date flock mktemp sha256sum awk find realpath rmdir; do
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
if (( ! BASE_EXPLICIT )); then
    BASE=$(vm_storage_base_path "$BASE_NAME")
fi
ATTESTATION="${BASE}.vgpu-portable.json"
[[ -f "$BASE" && ! -L "$BASE" ]] ||
    die "standalone Windows base is missing: $BASE"
[[ -f "$ATTESTATION" && ! -L "$ATTESTATION" ]] ||
    die "base has no portable-package attestation; run install-vgpu-portable-to-base.sh"
BASE_FILE_BYTES=$(stat -c %s -- "$BASE")
BASE_DEVICE_ID=$(stat -c %D -- "$BASE")
BASE_INODE=$(stat -c %i -- "$BASE")
OBSERVED_BASE_MTIME_NS=$(TZ=UTC stat -c %y -- "$BASE")
BASE_CTIME_NS=$(TZ=UTC stat -c %z -- "$BASE")
BASE_MTIME_NS=$(jq -er '.baseMtimeNs | strings' "$ATTESTATION") ||
    die "base portable-package attestation has no string mtime"
OBSERVED_BASE_MTIME_INSTANT=$(date -u -d "$OBSERVED_BASE_MTIME_NS" '+%s.%N') ||
    die "could not normalize the base image mtime"
ATTESTED_BASE_MTIME_INSTANT=$(date -u -d "$BASE_MTIME_NS" '+%s.%N') ||
    die "base portable-package attestation has an invalid mtime"
[[ "$OBSERVED_BASE_MTIME_INSTANT" == "$ATTESTED_BASE_MTIME_INSTANT" ]] ||
    die "base image mtime changed after portable-package installation"
# A V-11-style hard-link pin legitimately changes the base inode's ctime when
# clones are created/deleted. Content safety remains bound to path, device,
# inode, byte length and nanosecond mtime; baseCtimeNs stays an audit field but
# is deliberately not an invariant for clone eligibility.
BASE_ATTESTATION_SCHEMA=$(jq -er '.schemaVersion | numbers' "$ATTESTATION") ||
    die "base portable-package attestation has no numeric schema"
BASE_DEPLOYMENT_MODE=public-portable
BASE_GPUZ_INCLUDED=false
if [[ "$BASE_ATTESTATION_SCHEMA" == 7 ]]; then
    jq -e \
        --arg basePath "$BASE" \
        --argjson baseFileBytes "$BASE_FILE_BYTES" \
        --arg baseDeviceId "$BASE_DEVICE_ID" \
        --arg baseInode "$BASE_INODE" \
        --arg baseMtimeNs "$BASE_MTIME_NS" \
        --arg baseCtimeNs "$BASE_CTIME_NS" \
        --arg catalogSha256 "$EXPECTED_CATALOG_SHA256" '
        (keys | sort) == [
            "baseCtimeNs", "baseDeviceId", "baseFileBytes", "baseInode",
            "baseMtimeNs", "basePath", "bindingMode", "catalogSha256",
            "deploymentMode", "dlsHost", "dlsPort",
            "firstBootScriptGuestPath", "firstBootScriptSha256", "firstBootWorkflow",
            "guestPerformance", "installedUtc", "licenseDelivery", "oobeMode",
            "portableBytes", "portableGuestPath", "portableSha256",
            "retryGuestPath", "retrySha256", "schemaVersion",
            "sysprepAnswerGuestPath", "sysprepAnswerSha256",
            "systemNvapiDelivery", "systemNvapiRequired", "windowsGeneralized"
        ] and
        .schemaVersion == 7 and .bindingMode == "portable-auto" and
        .deploymentMode == "site-private-licensed-firstboot-v2" and
        .basePath == $basePath and .baseFileBytes == $baseFileBytes and
        .baseDeviceId == $baseDeviceId and .baseInode == $baseInode and
        .baseMtimeNs == $baseMtimeNs and
        (.baseCtimeNs | type) == "string" and
        .portableGuestPath == "C:\\ProgramData\\VMate\\G11\\VgpuPortable.exe" and
        (.portableSha256 | test("^[0-9A-F]{64}$")) and
        (.portableBytes | type) == "number" and
        (.portableBytes | floor) == .portableBytes and .portableBytes > 0 and
        .firstBootScriptGuestPath == "C:\\ProgramData\\VMate\\G11\\Finalize-Clone.ps1" and
        (.firstBootScriptSha256 | test("^[0-9A-F]{64}$")) and
        .retryGuestPath == "C:\\ProgramData\\VMate\\G11\\Retry-Clone-Initialization.cmd" and
        (.retrySha256 | test("^[0-9A-F]{64}$")) and
        .sysprepAnswerGuestPath == "C:\\Windows\\Panther\\unattend.xml" and
        (.sysprepAnswerSha256 | test("^[0-9A-F]{64}$")) and
        .windowsGeneralized == true and .oobeMode == "unattended-auto-finalize" and
        .licenseDelivery == "embedded-private-shared-token" and
        .firstBootWorkflow == "licensed-portable-system-nvapi-two-boot-v1" and
        .systemNvapiDelivery == "per-vm-read-only-iso" and
        .systemNvapiRequired == true and
        .dlsHost == "dls.gvmates.com" and .dlsPort == 443 and
        .guestPerformance == "embedded-recommended-native-v1" and
        .catalogSha256 == $catalogSha256 and (.installedUtc | type) == "string"
    ' "$ATTESTATION" >/dev/null ||
        die "private Sysprep base/catalog binding is invalid; re-import the .g11base package"
    BASE_DEPLOYMENT_MODE=private-sysprep-auto
elif [[ "$BASE_ATTESTATION_SCHEMA" == 6 ]]; then
    die "private schema-6 base lacks automatic system NVAPI projection; rebuild/re-import the current .g11base"
elif [[ "$BASE_ATTESTATION_SCHEMA" == 5 ]]; then
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
    .baseMtimeNs == $baseMtimeNs and
    (.baseCtimeNs | type) == "string" and
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
else
    die "unsupported base portable-package schema: $BASE_ATTESTATION_SCHEMA"
fi

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
CREATED_INIT_MARKER=""
CREATED_INIT_MARKER_ID=""
INIT_MARKER_TMP=""
CREATED_SYSTEM_PACKAGE_ROOT=""
CREATED_SYSTEM_PACKAGE_ROOT_ID=""
CREATED_SYSTEM_PACKAGE_PARENT=""
CREATED_SYSTEM_PACKAGE_PARENT_ID=""
CLONE_COMMITTED=0
cleanup_clone() {
    [[ -z "$INIT_MARKER_TMP" ]] || rm -f -- "$INIT_MARKER_TMP" || true
    if (( ! CLONE_COMMITTED )) && [[ -n "$CREATED_SYSTEM_PACKAGE_ROOT" &&
            -d "$CREATED_SYSTEM_PACKAGE_ROOT" && ! -L "$CREATED_SYSTEM_PACKAGE_ROOT" &&
            ! -e "$DISK" && ! -L "$DISK" &&
            "$CREATED_SYSTEM_PACKAGE_ROOT" == "$INSTANCE_DIR/packages/SystemNvapiProjection" &&
            "$(stat -Lc '%d:%i' -- "$CREATED_SYSTEM_PACKAGE_ROOT")" == "$CREATED_SYSTEM_PACKAGE_ROOT_ID" ]]; then
        rm -rf -- "$CREATED_SYSTEM_PACKAGE_ROOT" || true
    fi
    if (( ! CLONE_COMMITTED )) && [[ -n "$CREATED_SYSTEM_PACKAGE_PARENT" &&
            -d "$CREATED_SYSTEM_PACKAGE_PARENT" && ! -L "$CREATED_SYSTEM_PACKAGE_PARENT" &&
            ! -e "$DISK" && ! -L "$DISK" &&
            "$CREATED_SYSTEM_PACKAGE_PARENT" == "$INSTANCE_DIR/packages" &&
            "$(stat -Lc '%d:%i' -- "$CREATED_SYSTEM_PACKAGE_PARENT")" == "$CREATED_SYSTEM_PACKAGE_PARENT_ID" ]]; then
        rmdir -- "$CREATED_SYSTEM_PACKAGE_PARENT" 2>/dev/null || true
    fi
    if (( ! CLONE_COMMITTED )) && [[ -n "$CREATED_INIT_MARKER" &&
            -f "$CREATED_INIT_MARKER" && ! -L "$CREATED_INIT_MARKER" &&
            ! -e "$DISK" && ! -L "$DISK" &&
            "$(stat -Lc '%d:%i' -- "$CREATED_INIT_MARKER")" == "$CREATED_INIT_MARKER_ID" ]]; then
        rm -f -- "$CREATED_INIT_MARKER" || true
    fi
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

if [[ "$BASE_DEPLOYMENT_MODE" == private-sysprep-auto ]]; then
    SYSTEM_NVAPI_PACKAGER="$here/package-system-nvapi-projection.sh"
    [[ -x "$SYSTEM_NVAPI_PACKAGER" && ! -L "$SYSTEM_NVAPI_PACKAGER" ]] ||
        die "system NVAPI packager is missing or unsafe: $SYSTEM_NVAPI_PACKAGER"
    SYSTEM_PACKAGE_PARENT=$(vm_storage_instance_package_dir "$VM_ID") ||
        die "could not resolve the VM package directory"
    SYSTEM_PACKAGE_ROOT="$SYSTEM_PACKAGE_PARENT/SystemNvapiProjection"
    [[ ! -e "$SYSTEM_PACKAGE_ROOT" && ! -L "$SYSTEM_PACKAGE_ROOT" ]] ||
        die "private clone already has a system NVAPI package root: $SYSTEM_PACKAGE_ROOT"
    if [[ ! -e "$SYSTEM_PACKAGE_PARENT" && ! -L "$SYSTEM_PACKAGE_PARENT" ]]; then
        mkdir -m 0700 -- "$SYSTEM_PACKAGE_PARENT"
        CREATED_SYSTEM_PACKAGE_PARENT=$SYSTEM_PACKAGE_PARENT
        CREATED_SYSTEM_PACKAGE_PARENT_ID=$(stat -Lc '%d:%i' -- "$SYSTEM_PACKAGE_PARENT")
    fi
    CONF_UID=$(stat -c %u -- "$CONF")
    CONF_GID=$(stat -c %g -- "$CONF")
    [[ -d "$SYSTEM_PACKAGE_PARENT" && ! -L "$SYSTEM_PACKAGE_PARENT" &&
       "$(stat -c '%a:%u:%g' -- "$SYSTEM_PACKAGE_PARENT")" == "700:${CONF_UID}:${CONF_GID}" ]] ||
        die "private clone package directory is missing or unsafe: $SYSTEM_PACKAGE_PARENT"
    mkdir -m 0700 -- "$SYSTEM_PACKAGE_ROOT"
    CREATED_SYSTEM_PACKAGE_ROOT=$SYSTEM_PACKAGE_ROOT
    CREATED_SYSTEM_PACKAGE_ROOT_ID=$(stat -Lc '%d:%i' -- "$SYSTEM_PACKAGE_ROOT")

    SELECTED_VM_UUID=$(
        unset VM_UUID
        # shellcheck source=/dev/null
        source "$CONF"
        printf '%s' "$VM_UUID"
    )
    SELECTED_MONITOR_PROFILE=$(
        unset MONITOR_PROFILE
        # shellcheck source=/dev/null
        source "$CONF"
        printf '%s' "$MONITOR_PROFILE"
    )
    [[ "$SELECTED_VM_UUID" =~ ^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$ &&
       "$SELECTED_MONITOR_PROFILE" =~ ^[a-z0-9][a-z0-9-]{0,47}$ ]] ||
        die "new VM config lacks a packageable UUID/monitor profile"
    SELECTED_VM_UUID=${SELECTED_VM_UUID,,}
    SOURCE_CONFIG_SHA256=$(sha256_upper "$CONF")

    echo "[vgpu-clone] 为 vm${VM_ID} 生成 UUID/Profile/显示器绑定的系统 NVAPI 初始化 ISO"
    "$SYSTEM_NVAPI_PACKAGER" "$VM_ID" >/dev/null
    mapfile -d '' -t SYSTEM_PACKAGE_ISOS < <(
        find -P "$SYSTEM_PACKAGE_ROOT" -mindepth 1 -maxdepth 1 -type f \
            -name "vm${VM_ID}-*.iso" -print0
    )
    mapfile -d '' -t SYSTEM_PACKAGE_DIRS < <(
        find -P "$SYSTEM_PACKAGE_ROOT" -mindepth 1 -maxdepth 1 -type d \
            -name "vm${VM_ID}-*" -print0
    )
    ((${#SYSTEM_PACKAGE_ISOS[@]} == 1 && ${#SYSTEM_PACKAGE_DIRS[@]} == 1)) ||
        die "system NVAPI packager did not publish exactly one ISO/payload pair"
    SYSTEM_PACKAGE_ISO=${SYSTEM_PACKAGE_ISOS[0]}
    SYSTEM_PACKAGE_DIR=${SYSTEM_PACKAGE_DIRS[0]}
    SYSTEM_PACKAGE_STEM=$(basename -- "$SYSTEM_PACKAGE_DIR")
    [[ "$(basename -- "$SYSTEM_PACKAGE_ISO")" == "${SYSTEM_PACKAGE_STEM}.iso" &&
       ! -L "$SYSTEM_PACKAGE_ISO" && ! -L "$SYSTEM_PACKAGE_DIR" ]] ||
        die "system NVAPI ISO/payload names or file types are unsafe"
    SYSTEM_CONTRACT="$SYSTEM_PACKAGE_DIR/system-nvapi-contract.json"
    SYSTEM_MANIFEST="$SYSTEM_PACKAGE_DIR/system-nvapi-manifest.json"
    [[ -f "$SYSTEM_CONTRACT" && ! -L "$SYSTEM_CONTRACT" &&
       -f "$SYSTEM_MANIFEST" && ! -L "$SYSTEM_MANIFEST" ]] ||
        die "system NVAPI package lacks a safe contract/manifest"
    SYSTEM_CONTRACT_ID=$(jq -er '.contractId' "$SYSTEM_CONTRACT") ||
        die "system NVAPI contract has no contractId"
    CALCULATED_CONTRACT_ID=$(jq -cS 'del(.contractId)' "$SYSTEM_CONTRACT" |
        sha256sum | awk '{print toupper($1)}')
    [[ "$SYSTEM_CONTRACT_ID" == "$CALCULATED_CONTRACT_ID" ]] ||
        die "system NVAPI contract content hash is invalid"
    jq -e \
        --argjson vmId "$VM_ID" \
        --arg vmUuid "$SELECTED_VM_UUID" \
        --arg gpuProfile "$GPU_PROFILE_REQUEST" \
        --arg monitorProfile "$SELECTED_MONITOR_PROFILE" \
        --arg sourceConfigSha256 "$SOURCE_CONFIG_SHA256" \
        --arg contractId "$SYSTEM_CONTRACT_ID" '
        .schemaVersion == 4 and .purpose == "g11-system-nvapi-projection" and
        .contractId == $contractId and .vmId == $vmId and
        .vmUuid == $vmUuid and .profile.key == $gpuProfile and
        .monitor.key == $monitorProfile and
        .sourceConfigSha256 == $sourceConfigSha256 and
        .transport.targetPnpId == "PCI\\VEN_10DE&DEV_1E30" and
        .transport.driverVersion == "31.0.15.3833"
    ' "$SYSTEM_CONTRACT" >/dev/null ||
        die "system NVAPI contract does not match the new VM config"
    jq -e --arg contractId "$SYSTEM_CONTRACT_ID" '
        .schemaVersion == 1 and .purpose == "g11-system-nvapi-projection" and
        .contractId == $contractId and (.files | length) == 12
    ' "$SYSTEM_MANIFEST" >/dev/null ||
        die "system NVAPI manifest does not match the contract"
    SYSTEM_ISO_FILE=$(basename -- "$SYSTEM_PACKAGE_ISO")
    SYSTEM_ISO_SHA256=$(sha256_upper "$SYSTEM_PACKAGE_ISO")

    INIT_MARKER="$INSTANCE_DIR/.g11-init-required"
    [[ ! -e "$INIT_MARKER" && ! -L "$INIT_MARKER" ]] ||
        die "private clone initialization marker already exists: $INIT_MARKER"
    INIT_MARKER_TMP=$(mktemp "$INSTANCE_DIR/.g11-init-required.new.XXXXXXXX")
    jq -n \
        --argjson schemaVersion 2 \
        --arg baseName "$BASE_NAME" \
        --arg catalogSha256 "$EXPECTED_CATALOG_SHA256" \
        --arg vmUuid "$SELECTED_VM_UUID" \
        --arg gpuProfile "$GPU_PROFILE_REQUEST" \
        --arg monitorProfile "$SELECTED_MONITOR_PROFILE" \
        --arg sourceConfigSha256 "$SOURCE_CONFIG_SHA256" \
        --arg systemNvapiContractId "$SYSTEM_CONTRACT_ID" \
        --arg systemNvapiIsoFile "$SYSTEM_ISO_FILE" \
        --arg systemNvapiIsoSha256 "$SYSTEM_ISO_SHA256" \
        --arg createdUtc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        {
            schemaVersion: $schemaVersion,
            state: "guest-firstboot-required",
            baseName: $baseName,
            catalogSha256: $catalogSha256,
            createdUtc: $createdUtc,
            vmUuid: $vmUuid,
            gpuProfile: $gpuProfile,
            monitorProfile: $monitorProfile,
            sourceConfigSha256: $sourceConfigSha256,
            systemNvapiContractId: $systemNvapiContractId,
            systemNvapiIsoFile: $systemNvapiIsoFile,
            systemNvapiIsoSha256: $systemNvapiIsoSha256
        }' >"$INIT_MARKER_TMP"
    chmod 0600 "$INIT_MARKER_TMP"
    chown "$(stat -c %u -- "$INSTANCE_DIR"):$(stat -c %g -- "$INSTANCE_DIR")" \
        "$INIT_MARKER_TMP"
    mv -T -- "$INIT_MARKER_TMP" "$INIT_MARKER"
    INIT_MARKER_TMP=""
    CREATED_INIT_MARKER=$INIT_MARKER
    CREATED_INIT_MARKER_ID=$(stat -Lc '%d:%i' -- "$INIT_MARKER")
fi

DISK_BASE_ARGS=(--base-name "$BASE_NAME")
((BASE_EXPLICIT == 0)) || DISK_BASE_ARGS=(--base "$BASE")
if [[ "$CLONE_DISK_MODE" == linked ]]; then
    DISK_BASE_ARGS+=(--linked)
    CLONE_DISK_LABEL="incremental / V-11-style"
else
    DISK_BASE_ARGS+=(--full-copy)
    CLONE_DISK_LABEL="standalone full copy"
fi
if ! "$here/scripts/create-disk.sh" "$VM_ID" --from-base \
        "${DISK_BASE_ARGS[@]}"; then
    die "base cloning failed; the new configuration will be rolled back when no disk was published"
fi
[[ -f "$DISK" && ! -L "$DISK" ]] ||
    die "base cloning returned success without a regular VM disk"
CLONE_COMMITTED=1
trap - EXIT

MONITOR_SYNC_RESULT=disabled
if [[ "$BASE_DEPLOYMENT_MODE" == private-sysprep-auto ]]; then
    MONITOR_SYNC_RESULT=deferred-to-one-click-initialization
    echo "[vgpu-clone] 显示器缓存将在来宾首次完整关机后的‘初始’操作中统一刷新"
elif (( MONITOR_SYNC )); then
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

if [[ "$BASE_DEPLOYMENT_MODE" == private-sysprep-auto ]]; then
cat <<EOF
[vgpu-clone] PASS / private Sysprep clone
  VM:          vm${VM_ID}
  base name:   ${BASE_NAME}
  base image:  ${BASE}
  GPU profile: ${GPU_PROFILE_REQUEST}
  GPU VRAM:    ${GPU_VRAM_MB} MB
  config:      ${CONF}
  disk:        ${DISK}
  disk mode:   ${CLONE_DISK_MODE} (${CLONE_DISK_LABEL})
  monitor:     ${MONITOR_SYNC_RESULT}
  guest:       independent generalized Windows identity
  portable:    C:\ProgramData\VMate\G11\VgpuPortable.exe
  Guest Lite:  pinned 2.6.0 / Game Mode / Game DVR off / NVIDIA max performance / DNF High-on-launch / stale Temp cleaned / reviewed background processes stopped / audio muted / automatic
  system NVAPI: per-VM read-only ISO / ${SYSTEM_CONTRACT_ID}
  DLS:         dls.gvmates.com:443

首次启动会自动跳过 OOBE、运行一次授权版 VgpuPortable.exe、应用经过内容校验的
Guest Lite 2.6.0（母盘封装前必须手工关闭篡改防护）、安装该 VM
专属的系统 NVAPI/显示器投影并自动重启；重启后由 SYSTEM 自动验收
GRID 538.33 / DEV_1E30 / Code 0 / Licensed / x86+x64 NVAPI，以及 MpsSvc
Disabled/Stopped、BFE 保留运行、游戏模式/Game DVR、NVIDIA 最高性能、DNF High、
Temp 清理回执和 Guest Lite 回滚基线，成功后完整关机。
主机名按 V-11 规则规范为 DESKTOP-XXXXXXX（取本 VM UUID 去横线后的前 7 位）。VM-bound ISO 只在
首次初始化短暂显示为审核过的 HL-DT-ST 光驱，载荷复制后会自动弹出并热拔；
此后普通启动没有光驱。显示器 live 名称也由同一次初始化通过 SetupAPI 发布，
不需要在 Windows 设备管理器里手动“更新驱动程序”。
用户无需操作 Windows；关机后只需在 VMate 点击一次“初始”，宿主会只读校验
独立 OS 身份和全部收据、刷新显示器缓存并启动 VM。
EOF
else
cat <<EOF
[vgpu-clone] PASS
  VM:          vm${VM_ID}
  base name:   ${BASE_NAME}
  base image:  ${BASE}
  GPU profile: ${GPU_PROFILE_REQUEST}
  GPU VRAM:    ${GPU_VRAM_MB} MB
  config:      ${CONF}
  disk:        ${DISK}
  disk mode:   ${CLONE_DISK_MODE} (${CLONE_DISK_LABEL})
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
fi

if ((START_AFTER)); then
    flock -u "$START_LOCK_FD"
    exec {START_LOCK_FD}>&-
    flock -u "$STORAGE_LOCK_FD"
    exec {STORAGE_LOCK_FD}>&-
    start_args=( "$VM_ID" )
    (( MONITOR_SYNC )) || start_args+=( --no-monitor-sync )
    exec "$here/scripts/start-vm.sh" "${start_args[@]}"
fi
