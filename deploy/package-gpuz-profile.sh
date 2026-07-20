#!/usr/bin/env bash
# Build one private, HTTP-free GPU-Z app-local profile bundle for a VM.
#
# This packager deliberately does not start Windows or network services, modify BCD,
# stage a display driver, or replace System32/SysWOW64 NVAPI images.  It reuses the
# stage-vm-profile whitelist generator in an isolated temporary IMAGE_ROOT,
# then adds only the app-local NVAPI assets and a hash-verified guest entry.
set -euo pipefail
umask 077

# Some host utilities fail merely because a diagnostic descriptor was already
# closed by their caller.  Keep packaging deterministic in that case; a pipe
# or filesystem that fails later is still handled after the EXE commit point.
[[ -e /proc/self/fd/1 ]] || exec 1>/dev/null
[[ -e /proc/self/fd/2 ]] || exec 2>/dev/null

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"

# shellcheck source=lib/vm-storage.sh
source "$here/lib/vm-storage.sh"
# shellcheck source=lib/vgpu-profiles.sh
source "$here/lib/vgpu-profiles.sh"
# shellcheck source=lib/gpuz-assets.sh
source "$here/lib/gpuz-assets.sh"

usage() {
    cat <<'EOF'
usage: ./deploy/package-gpuz-profile.sh VM_ID [options]
       ./deploy/package-gpuz-profile.sh --all [options]

Options:
  --all                  Build every configured VM; continue failures, then
                         return nonzero if any VM failed
  --output-root DIR      Root for automatically namespaced outputs
                         (default: $STAGE_DIR/GpuZProfile)
  --output-dir DIR       Final bundle directory
                         (advanced single-VM override)
  --output-exe FILE.exe  Final single-file Windows executable
                         (default with --output-dir: DIR.exe)
                         (must share --output-dir's trusted parent)
  --gpuz-source FILE     Host GPU-Z 2.70.0 executable to embed
                         (default: $IMAGE_ROOT/candidates/gpuz-2.70-audit/
                         GPU-Z.2.70.0.exe)
  --list-gpu-profiles    Print the current 2 GB GPU identity catalog
  -h, --help             Show this help

Normal use:
  ./deploy/package-gpuz-profile.sh 4
  ./deploy/package-gpuz-profile.sh 456
  ./deploy/package-gpuz-profile.sh --all

The normal output is:
  $STAGE_DIR/GpuZProfile/vmN-UUID/GpuZProfile.exe

Copy only GpuZProfile.exe into the matching Windows VM and double-click it.
The guest flow is local and opens no network listener.
EOF
}

die() {
    echo "[gpuz-package] ERROR: $*" >&2
    exit 1
}

log() {
    echo "[gpuz-package] $*"
}

sha256_upper() {
    sha256sum -- "$1" | awk '{print toupper($1)}'
}

vm_id_is_supported() {
    vm_storage_id_is_supported "${1:-}"
}

VM_ID=""
PACKAGE_ALL=0
OUTPUT_ROOT=""
OUTPUT_DIR=""
OUTPUT_EXE=""
OUTPUT_DIR_EXPLICIT=0
GPUZ_SOURCE=""

while (($#)); do
    case "$1" in
        --output-root)
            (($# >= 2)) || die "--output-root requires a path"
            OUTPUT_ROOT=$2
            shift 2
            ;;
        --output-dir)
            (($# >= 2)) || die "--output-dir requires a path"
            OUTPUT_DIR=$2
            OUTPUT_DIR_EXPLICIT=1
            shift 2
            ;;
        --all)
            PACKAGE_ALL=1
            shift
            ;;
        --output-exe)
            (($# >= 2)) || die "--output-exe requires a path"
            OUTPUT_EXE=$2
            shift 2
            ;;
        --gpuz-source)
            (($# >= 2)) || die "--gpuz-source requires a host file"
            GPUZ_SOURCE=$2
            shift 2
            ;;
        --list-gpu-profiles)
            vgpu_profile_print_catalog
            exit 0
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            if vm_id_is_supported "$1"; then
                [[ -z "$VM_ID" ]] || die "VM_ID was supplied more than once"
                VM_ID=$1
                shift
            else
                die "unknown argument or unsupported VM_ID (expected 1..2147483647): $1"
            fi
            ;;
    esac
done

if ((PACKAGE_ALL)); then
    [[ -z "$VM_ID" ]] || die "--all cannot be combined with VM_ID"
    [[ -z "$OUTPUT_DIR" && -z "$OUTPUT_EXE" ]] \
        || die "--all cannot be combined with --output-dir/--output-exe"
else
    [[ -n "$VM_ID" ]] || {
        usage >&2
        exit 2
    }
fi
[[ -z "$OUTPUT_ROOT" || ( -z "$OUTPUT_DIR" && -z "$OUTPUT_EXE" ) ]] \
    || die "--output-root cannot be combined with --output-dir/--output-exe"
[[ -z "$OUTPUT_ROOT" || ( "$OUTPUT_ROOT" == /* && "$OUTPUT_ROOT" != / ) ]] \
    || die "--output-root must be a non-root absolute path"
for dependency in jq sha256sum flock mktemp realpath awk install find stat \
        cmp ln sort basename dirname \
        x86_64-w64-mingw32-gcc x86_64-w64-mingw32-windres; do
    command -v "$dependency" >/dev/null 2>&1 \
        || die "missing host dependency: $dependency"
done
python3 -c 'import json' >/dev/null 2>&1 \
    || die "python3 is required"

vgpu_profile_validate_catalog \
    || die "GPU identity catalog validation failed"
vm_storage_init
GPUZ_SOURCE_RESOLVED=0
resolve_gpuz_source_once() {
    ((GPUZ_SOURCE_RESOLVED == 0)) || return 0
    if [[ -z "$GPUZ_SOURCE" ]]; then
        GPUZ_SOURCE=$(gpuz_asset_default_source) \
            || die "could not derive the canonical GPU-Z source"
    fi
    GPUZ_SOURCE=$(gpuz_asset_resolve_source "$GPUZ_SOURCE") \
        || die "invalid --gpuz-source"
    GPUZ_SOURCE_RESOLVED=1
}
if [[ -n "$OUTPUT_ROOT" ]]; then
    OUTPUT_ROOT=$(realpath -m -- "$OUTPUT_ROOT")
fi

if ((PACKAGE_ALL)); then
    declare -a configured_vm_ids=()
    shopt -s nullglob
    for configured_conf in "$VM_INSTANCES_DIR"/vm*/vm.conf; do
        configured_leaf=$(basename -- "$(dirname -- "$configured_conf")")
        [[ "$configured_leaf" =~ ^vm([1-9][0-9]*)$ ]] || continue
        configured_vm_id_match=${BASH_REMATCH[1]}
        vm_id_is_supported "$configured_vm_id_match" \
            || die "configured VM ID exceeds the supported range: $configured_vm_id_match"
        configured_vm_ids+=("$configured_vm_id_match")
    done
    for configured_conf in "$VM_CONFIG_DIR"/vm*.conf; do
        configured_leaf=$(basename -- "$configured_conf")
        [[ "$configured_leaf" =~ ^vm([1-9][0-9]*)\.conf$ ]] || continue
        configured_vm_id_match=${BASH_REMATCH[1]}
        vm_id_is_supported "$configured_vm_id_match" \
            || die "configured VM ID exceeds the supported range: $configured_vm_id_match"
        configured_vm_ids+=("$configured_vm_id_match")
    done
    shopt -u nullglob
    ((${#configured_vm_ids[@]} > 0)) \
        || die "no configured VM was found below $VM_INSTANCES_DIR"
    mapfile -t configured_vm_ids < <(
        printf '%s\n' "${configured_vm_ids[@]}" | sort -n -u
    )
    batch_failures=0
    batch_built=0
    batch_skipped=0
    for configured_vm_id in "${configured_vm_ids[@]}"; do
        if ! vm_storage_validate_instance_tree "$configured_vm_id"; then
            echo "[gpuz-package] batch: vm${configured_vm_id} instance tree is unsafe" >&2
            batch_failures=$((batch_failures + 1))
            continue
        fi
        if ! configured_conf=$(vm_storage_config_path "$configured_vm_id"); then
            echo "[gpuz-package] batch: vm${configured_vm_id} configuration path is ambiguous or unsafe" >&2
            batch_failures=$((batch_failures + 1))
            continue
        fi
        if [[ ! -r "$configured_conf" || ! -f "$configured_conf" ||
              -L "$configured_conf" ]]; then
            echo "[gpuz-package] batch: vm${configured_vm_id} configuration is not a safe regular file" >&2
            batch_failures=$((batch_failures + 1))
            continue
        fi
        if ! configured_package_enabled=$(
            awk '
                BEGIN { count = 0; value = "1" }
                /^GPUZ_PACKAGE_ENABLED=/ {
                    count++
                    value = substr($0, index($0, "=") + 1)
                }
                END {
                    if (count == 0 || (count == 1 && (value == "0" || value == "1"))) {
                        print value
                        exit 0
                    }
                    exit 2
                }
            ' "$configured_conf"
        ); then
            echo "[gpuz-package] batch: vm${configured_vm_id} has malformed/duplicate GPUZ_PACKAGE_ENABLED" >&2
            batch_failures=$((batch_failures + 1))
            continue
        fi
        case "$configured_package_enabled" in
            0)
                log "batch: skipping vm${configured_vm_id} (GPUZ_PACKAGE_ENABLED=0)"
                batch_skipped=$((batch_skipped + 1))
                continue
                ;;
            1) ;;
            *)
                echo "[gpuz-package] batch: vm${configured_vm_id} has invalid GPUZ_PACKAGE_ENABLED (expected 0 or 1)" >&2
                batch_failures=$((batch_failures + 1))
                continue
                ;;
        esac
        resolve_gpuz_source_once
        log "batch: packaging vm${configured_vm_id}"
        child_args=(
            "$here/package-gpuz-profile.sh" "$configured_vm_id"
            --gpuz-source "$GPUZ_SOURCE"
        )
        if [[ -n "$OUTPUT_ROOT" ]]; then
            child_args+=(--output-root "$OUTPUT_ROOT")
        fi
        if ! "${child_args[@]}"; then
            echo "[gpuz-package] batch: vm${configured_vm_id} FAILED" >&2
            batch_failures=$((batch_failures + 1))
        else
            batch_built=$((batch_built + 1))
        fi
    done
    ((batch_failures == 0)) \
        || die "$batch_failures configured VM package(s) failed closed"
    log "PASS: built ${batch_built} VM-bound single EXE package(s); skipped ${batch_skipped}"
    exit 0
fi

resolve_gpuz_source_once
REQUESTED_VM_ID=$VM_ID
readonly REQUESTED_VM_ID
vm_storage_prepare_instance "$VM_ID"

INSTANCE_DIR=$(vm_storage_instance_dir "$VM_ID")
CONF=$(vm_storage_config_path "$VM_ID")
DISK=$(vm_storage_disk_path "$VM_ID")
[[ -r "$CONF" && -f "$CONF" && ! -L "$CONF" ]] \
    || die "VM configuration is not a regular readable file: $CONF"
[[ -f "$DISK" && ! -L "$DISK" ]] \
    || die "VM disk is missing: $DISK"
CONFIG_SHA256=$(sha256_upper "$CONF")

# Load only the fields used by this package after clearing inherited values.
unset VM_ID VM_UUID GPU_PROFILE GPU_NAME GPU_PCI_VID GPU_PCI_DID GPU_SUB_VID \
    GPU_SUB_DID GPU_REV GPU_VRAM_MB GPU_VBIOS GPU_CORE_MHZ GPU_BOOST_MHZ \
    GPU_MEMORY_MHZ GPU_MEMORY_BUS_BITS GPU_MEMORY_BANDWIDTH_MBPS \
    GPU_MEMORY_TYPE GPU_MEMORY_MAKER GPU_MEMORY_TYPE_NVAPI \
    GPU_MEMORY_MAKER_NVAPI GPU_CUDA_CORES GPU_SHADER_SUBPIPES \
    GPU_ROP_COUNT GPU_TMU_COUNT GPU_ARCHITECTURE GPU_IMPLEMENTATION GPU_CHIP_REVISION \
    GPU_PCIE_WIDTH SPOOF_MODE VGPU_IDENTITY_TARGET \
    VGPU_MDEV_INTERNAL_PCI_IDENTITY VGPU_MDEV_FRL_ENABLED \
    VGPU_PATCHED_DRIVER_VERSION MONITOR_PROFILE MONITOR_SERIAL \
    GPUZ_PACKAGE_ENABLED
# shellcheck source=/dev/null
source "$CONF"

CONFIG_VM_ID=${VM_ID:-}
VM_ID=$REQUESTED_VM_ID
[[ "$CONFIG_VM_ID" == "$REQUESTED_VM_ID" ]] \
    || die "VM_ID in $CONF does not match requested vm${REQUESTED_VM_ID}"
[[ "${VM_UUID:-}" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] \
    || die "VM_UUID is missing or invalid in $CONF"
[[ -n "${GPU_PROFILE:-}" ]] || die "GPU_PROFILE is missing in $CONF"
configured_package_enabled=1
if [[ -v GPUZ_PACKAGE_ENABLED ]]; then
    configured_package_enabled=$GPUZ_PACKAGE_ENABLED
fi
case "$configured_package_enabled" in
    1) ;;
    0) die "GPU-Z packaging is disabled for vm${VM_ID} (GPUZ_PACKAGE_ENABLED=0)" ;;
    *) die "GPUZ_PACKAGE_ENABLED must be 0 or 1 in $CONF" ;;
esac

profile_fields=(
    GPU_NAME GPU_PCI_VID GPU_PCI_DID GPU_SUB_VID GPU_SUB_DID GPU_REV
    GPU_VRAM_MB GPU_VBIOS GPU_CORE_MHZ GPU_BOOST_MHZ GPU_MEMORY_MHZ
    GPU_MEMORY_BUS_BITS GPU_MEMORY_BANDWIDTH_MBPS GPU_MEMORY_TYPE
    GPU_MEMORY_MAKER GPU_MEMORY_TYPE_NVAPI GPU_MEMORY_MAKER_NVAPI
    GPU_CUDA_CORES GPU_SHADER_SUBPIPES GPU_ROP_COUNT GPU_TMU_COUNT GPU_ARCHITECTURE
    GPU_IMPLEMENTATION GPU_CHIP_REVISION GPU_PCIE_WIDTH
)
declare -A configured=()
declare -A configured_set=()
for field in "${profile_fields[@]}"; do
    configured["$field"]=${!field-}
    if [[ -v "$field" ]]; then
        configured_set["$field"]=1
    fi
done
configured_profile=$GPU_PROFILE
configured_uuid=$VM_UUID
configured_uuid_lower=${configured_uuid,,}
configured_mode=${SPOOF_MODE:-}
configured_identity_target=${VGPU_IDENTITY_TARGET:-}
configured_internal=${VGPU_MDEV_INTERNAL_PCI_IDENTITY:-}
configured_frl=${VGPU_MDEV_FRL_ENABLED:-}
configured_driver=${VGPU_PATCHED_DRIVER_VERSION:-}
transport_monitor_profile=${MONITOR_PROFILE:-asus-va24e}
transport_monitor_serial=${MONITOR_SERIAL:-KCLMC045CE2A}

if [[ -n "${VGPU_PACKAGE_DISPATCH_CONFIG_SHA256:-}" ||
      -n "${VGPU_PACKAGE_DISPATCH_SPOOF_MODE:-}" ]]; then
    [[ "${VGPU_PACKAGE_DISPATCH_CONFIG_SHA256:-}" =~ ^[0-9A-F]{64}$ &&
       "${VGPU_PACKAGE_DISPATCH_SPOOF_MODE:-}" =~ ^(A|B)$ ]] \
        || die "invalid one-click dispatch constraint"
    [[ "$CONFIG_SHA256" == "$VGPU_PACKAGE_DISPATCH_CONFIG_SHA256" &&
       "$configured_mode" == "$VGPU_PACKAGE_DISPATCH_SPOOF_MODE" ]] \
        || die "VM config changed after one-click mode selection; rerun the one-click packager"
fi
unset VGPU_PACKAGE_DISPATCH_CONFIG_SHA256 \
    VGPU_PACKAGE_DISPATCH_SPOOF_MODE

vgpu_profile_load "$configured_profile" \
    || die "unsupported GPU profile: $configured_profile"

case "$configured_mode" in
    B)
        # Older B configs may predate the overlay fields and may retain an
        # unrelated consumer PCI tuple.  Windows PnP keeps the native 1E30
        # endpoint; the package takes the app-local GPU-Z/NVAPI tuple from the
        # audited catalog, not an arbitrary per-VM override.  Missing overlay
        # values inherit the catalog and explicitly persisted values must
        # still match it.
        overlay_fields=(
            GPU_NAME GPU_VRAM_MB GPU_VBIOS GPU_CORE_MHZ GPU_BOOST_MHZ
            GPU_MEMORY_MHZ GPU_MEMORY_BUS_BITS GPU_MEMORY_BANDWIDTH_MBPS
            GPU_MEMORY_TYPE GPU_MEMORY_MAKER GPU_MEMORY_TYPE_NVAPI
            GPU_MEMORY_MAKER_NVAPI GPU_CUDA_CORES GPU_SHADER_SUBPIPES
            GPU_ROP_COUNT GPU_TMU_COUNT GPU_ARCHITECTURE GPU_IMPLEMENTATION
            GPU_CHIP_REVISION GPU_PCIE_WIDTH
        )
        for field in "${overlay_fields[@]}"; do
            if [[ -n "${configured_set[$field]+x}" ]]; then
                expected=${!field}
                actual=${configured[$field]}
                [[ "$actual" == "$expected" ]] \
                    || die "$field conflicts with catalog profile $configured_profile: '$actual' != '$expected'"
            fi
        done
        expected_pnp='PCI\VEN_10DE&DEV_1E30'
        ;;
    A)
        for field in "${profile_fields[@]}"; do
            expected=${!field}
            actual=${configured[$field]}
            # TMU is a newly derived, catalog-locked field.  Completed legacy
            # A configs may omit it; every other strict identity field remains
            # explicitly required.
            if [[ "$field" == GPU_TMU_COUNT &&
                  -z "${configured_set[$field]+x}" ]]; then
                continue
            fi
            [[ -n "${configured_set[$field]+x}" && -n "$actual" ]] \
                || die "A mode requires explicit $field in $CONF"
            [[ "$actual" == "$expected" ]] \
                || die "$field conflicts with strict-A catalog profile $configured_profile: '$actual' != '$expected'"
        done
        [[ "$configured_profile" == gtx1050_2gb &&
           "$GPU_NAME" == 'NVIDIA GeForce GTX 1050' &&
           "$GPU_PCI_VID" == 0x10DE && "$GPU_PCI_DID" == 0x1C81 &&
           "$GPU_SUB_VID" == 0x1028 && "$GPU_SUB_DID" == 0x11C0 ]] \
            || die "A mode is allowed only for the audited GTX 1050 PCI tuple"
        [[ "$configured_identity_target" == full-consumer ]] \
            || die "A mode requires VGPU_IDENTITY_TARGET=full-consumer; do not add it merely to bypass this gate"
        [[ "$configured_internal" == 1 && "$configured_frl" == 0 &&
           "$configured_driver" == 31.0.15.3833 ]] \
            || die "A mode requires the completed internal-identity/FRL/driver markers"
        expected_pnp='PCI\VEN_10DE&DEV_1C81&SUBSYS_11C01028&REV_A1'
        ;;
    off)
        die "SPOOF_MODE=off does not expose the configured consumer identity"
        ;;
    *)
        die "SPOOF_MODE must be B or the audited GTX 1050 A mode"
        ;;
esac

[[ "$GPU_VRAM_MB" == 2048 ]] \
    || die "only the audited 2048 MB identity catalog is supported"
[[ "$GPU_MEMORY_TYPE" == GDDR5 &&
   "$GPU_MEMORY_MAKER" == Samsung &&
   "$GPU_MEMORY_TYPE_NVAPI" == 8 &&
   "$GPU_MEMORY_MAKER_NVAPI" == 1 ]] \
    || die "the current package accepts only audited GDDR5(8)/Samsung(1) profiles"
((GPU_BOOST_MHZ >= GPU_CORE_MHZ)) \
    || die "GPU boost clock must not be lower than the core clock"
((GPU_TMU_COUNT == GPU_SHADER_SUBPIPES * 8)) \
    || die "GPU TMU count must equal shader subpipes * 8"
case "$GPU_PCIE_WIDTH" in
    1|2|4|8|16|32) ;;
    *) die "GPU PCIe width must be one of 1/2/4/8/16/32" ;;
esac
raw_memory_khz=$((GPU_MEMORY_MHZ * 2000))
derived_bandwidth_mbps=$((raw_memory_khz * 2 * GPU_MEMORY_BUS_BITS / 8000))
bandwidth_difference=$((derived_bandwidth_mbps - GPU_MEMORY_BANDWIDTH_MBPS))
((bandwidth_difference >= 0)) || bandwidth_difference=$((-bandwidth_difference))
((bandwidth_difference * 100 <= GPU_MEMORY_BANDWIDTH_MBPS)) \
    || die "GPU memory clock/bus/bandwidth exceeds the audited GDDR5 1% tolerance"

DEFAULT_LAYOUT=0
if ((OUTPUT_DIR_EXPLICIT == 0)); then
    [[ -n "$OUTPUT_ROOT" ]] || OUTPUT_ROOT="$STAGE_DIR/GpuZProfile"
    [[ "$OUTPUT_ROOT" == /* && "$OUTPUT_ROOT" != / ]] \
        || die "--output-root must be a non-root absolute path"
    OUTPUT_ROOT=$(realpath -m -- "$OUTPUT_ROOT")
    OUTPUT_DIR="$OUTPUT_ROOT/vm${VM_ID}-${configured_uuid_lower}/.host-bundle"
    DEFAULT_LAYOUT=1
fi
[[ "$OUTPUT_DIR" == /* && "$OUTPUT_DIR" != / ]] \
    || die "--output-dir must be a non-root absolute path"
[[ ! -L "$OUTPUT_DIR" ]] \
    || die "--output-dir must not be a symlink"
OUTPUT_DIR=$(realpath -m -- "$OUTPUT_DIR")

path_is_same_or_below() {
    local candidate=$1 root=$2
    [[ "$candidate" == "$root" ||
       ("$root" == / && "$candidate" == /*) ||
       "$candidate" == "$root/"* ]]
}

INSTANCE_CANON=$(realpath -m -- "$INSTANCE_DIR")
SOURCE_CANON=$(realpath -m -- "$here")
IMAGE_CANON=$(realpath -m -- "$IMAGE_ROOT")
STAGE_CANON=$(realpath -m -- "$STAGE_DIR")
[[ "$IMAGE_CANON" != / && "$STAGE_CANON" != / ]] \
    || die "IMAGE_ROOT/STAGE_DIR must not resolve to the filesystem root"
if path_is_same_or_below "$OUTPUT_DIR" "$INSTANCE_CANON" ||
   path_is_same_or_below "$INSTANCE_CANON" "$OUTPUT_DIR"; then
    die "--output-dir must neither overlap nor contain the VM instance directory"
fi
if path_is_same_or_below "$OUTPUT_DIR" "$SOURCE_CANON" ||
   path_is_same_or_below "$SOURCE_CANON" "$OUTPUT_DIR"; then
    die "--output-dir must neither overlap nor contain the deploy source directory"
fi
if path_is_same_or_below "$IMAGE_CANON" "$OUTPUT_DIR"; then
    die "--output-dir must not equal or contain IMAGE_ROOT"
fi
if path_is_same_or_below "$OUTPUT_DIR" "$IMAGE_CANON" &&
   ! path_is_same_or_below "$OUTPUT_DIR" "$STAGE_CANON"; then
    die "inside IMAGE_ROOT, --output-dir is allowed only below STAGE_DIR"
fi
[[ "$OUTPUT_DIR" != "$STAGE_CANON" ]] \
    || die "--output-dir must be a child directory, not STAGE_DIR itself"

for asset in \
        "$here/guest/apply-gpuz-profile.ps1" \
        "$here/guest/nvapi-shim/nvapi.dll" \
        "$here/guest/nvapi-shim/nvapi_profile_probe32.exe"; do
    [[ -s "$asset" && ! -L "$asset" ]] \
        || die "required app-local asset is missing or unsafe: $asset"
done

# Fail before publishing if checked-in PE images do not match their source.
bash "$here/tests/vgpu/test_nvapi_identity_shim_static.sh" >/dev/null

LOCK_DIR=$(dirname -- "$OUTPUT_DIR")
mkdir -p -- "$LOCK_DIR"
LOCK_DIR=$(realpath -e -- "$LOCK_DIR") \
    || die "could not resolve the output parent"
[[ -d "$LOCK_DIR" && ! -L "$LOCK_DIR" ]] \
    || die "output parent must be a regular directory"
[[ "$(dirname -- "$OUTPUT_DIR")" == "$LOCK_DIR" ]] \
    || die "--output-dir parent changed while it was being prepared"

assert_trusted_output_ancestry() {
    local path=$LOCK_DIR owner mode gid

    path_has_posix_acl() {
        local candidate=$1
        python3 -I -S - "$candidate" <<'PY'
import os
import sys

try:
    attributes = os.listxattr(sys.argv[1], follow_symlinks=False)
except OSError:
    # Fail closed when the filesystem will not disclose its ACL metadata.
    sys.exit(0)
if any(name in ("system.posix_acl_access", "system.posix_acl_default")
       for name in attributes):
    sys.exit(0)
sys.exit(1)
PY
    }

    group_has_untrusted_member() {
        local group_id=$1
        python3 -I -S - "$group_id" "$EUID" <<'PY'
import grp
import pwd
import sys

gid = int(sys.argv[1])
euid = int(sys.argv[2])
try:
    group = grp.getgrgid(gid)
except KeyError:
    sys.exit(0)
names = set(group.gr_mem)
for account in pwd.getpwall():
    if account.pw_gid == gid:
        names.add(account.pw_name)
for name in names:
    try:
        uid = pwd.getpwnam(name).pw_uid
    except KeyError:
        sys.exit(0)
    if uid not in (0, euid):
        sys.exit(0)
sys.exit(1)
PY
    }

    while :; do
        [[ -d "$path" && ! -L "$path" ]] \
            || die "output ancestry contains a non-directory/symlink: $path"
        ! path_has_posix_acl "$path" \
            || die "output ancestry has an extended/default POSIX ACL at $path"
        owner=$(stat -c %u -- "$path")
        [[ "$owner" == "$EUID" || "$owner" == 0 ]] \
            || die "output ancestry has an untrusted owner at $path"
        mode=$(stat -c %a -- "$path")
        if (( (8#$mode & 002) != 0 )); then
            (( (8#$mode & 01000) != 0 )) \
                || die "output ancestry is writable without sticky protection at $path"
        fi
        if (( (8#$mode & 020) != 0 &&
              (8#$mode & 01000) == 0 )); then
            gid=$(stat -c %g -- "$path")
            ! group_has_untrusted_member "$gid" \
                || die "output ancestry has an untrusted writable group at $path"
        fi
        [[ "$path" == / ]] && break
        path=$(dirname -- "$path")
    done
    [[ "$(stat -c %u -- "$LOCK_DIR")" == "$EUID" ]] \
        || die "output parent must be owned by the packager user"
    mode=$(stat -c %a -- "$LOCK_DIR")
    (( (8#$mode & 002) == 0 )) \
        || die "output parent must not be other-writable"
    if (( (8#$mode & 020) != 0 )); then
        gid=$(stat -c %g -- "$LOCK_DIR")
        ! group_has_untrusted_member "$gid" \
            || die "output parent group contains another writable user"
    fi
}
assert_trusted_output_ancestry

if [[ -z "$OUTPUT_EXE" ]]; then
    if ((DEFAULT_LAYOUT)); then
        OUTPUT_EXE="$LOCK_DIR/GpuZProfile.exe"
    else
        OUTPUT_EXE="${OUTPUT_DIR}.exe"
    fi
else
    [[ "$OUTPUT_EXE" == /* && "${OUTPUT_EXE,,}" == *.exe &&
       "$OUTPUT_EXE" != *$'\n'* && "$OUTPUT_EXE" != *$'\r'* ]] \
        || die "--output-exe must be an absolute .exe path without newlines"
    [[ ! -L "$OUTPUT_EXE" ]] \
        || die "--output-exe must not be a symlink"
    OUTPUT_EXE=$(realpath -m -- "$OUTPUT_EXE")
    [[ "$(dirname -- "$OUTPUT_EXE")" == "$LOCK_DIR" ]] \
        || die "--output-exe must be a sibling of --output-dir"
fi
[[ ! -L "$OUTPUT_EXE" ]] \
    || die "--output-exe must not be a symlink"
[[ "$OUTPUT_EXE" != "$OUTPUT_DIR" ]] \
    || die "--output-exe must not be the same path as --output-dir"
OUTPUT_RECEIPT_DIR="$LOCK_DIR/.$(basename -- "$OUTPUT_EXE").receipts"
[[ "$OUTPUT_RECEIPT_DIR" != "$OUTPUT_DIR" ]] \
    || die "--output-dir must not overlap the host EXE receipt directory"

# Lock the already-canonical output-parent inode itself.  Opening it read-only
# cannot create/truncate a path or follow a hostile lock-file symlink.
exec {PACKAGE_LOCK_FD}<"$LOCK_DIR" \
    || die "could not open the output parent for locking"
LOCK_FD_PATH="/proc/self/fd/$PACKAGE_LOCK_FD"
[[ -d "$LOCK_FD_PATH" &&
   "$(stat -Lc '%d:%i' -- "$LOCK_FD_PATH")" == \
       "$(stat -Lc '%d:%i' -- "$LOCK_DIR")" ]] \
    || die "output parent changed before locking"
flock -x "$PACKAGE_LOCK_FD"
[[ "$(stat -Lc '%d:%i' -- "$LOCK_FD_PATH")" == \
       "$(stat -Lc '%d:%i' -- "$LOCK_DIR")" ]] \
    || die "output parent changed while waiting for the package lock"
assert_trusted_output_ancestry

validate_existing_bundle_output() {
    local directory=$1
    [[ -d "$directory" && ! -L "$directory" ]] \
        || die "refusing to replace a non-directory or symlink: $directory"
    jq -e --argjson vmId "$VM_ID" '
        .schemaVersion == 1 and .vmId == $vmId
    ' "$directory/bundle-manifest.json" >/dev/null 2>&1 \
        || die "existing output manifest does not belong to vm${VM_ID}"
    jq -e \
        --argjson vmId "$VM_ID" \
        --arg vmUuid "$configured_uuid_lower" \
        --arg gpuProfile "$configured_profile" '
        .schemaVersion == 2 and .vmId == $vmId and
        (.vmUuid | ascii_downcase) == $vmUuid and
        .gpuProfile == $gpuProfile
    ' "$directory/gpuz-contract.json" >/dev/null 2>&1 \
        || die "existing output contract does not match vm${VM_ID} UUID/profile"

    local verify_root verify_exe
    verify_root=$(mktemp -d "$LOCK_DIR/.gpuz-owned-verify.XXXXXXXX")
    verify_exe="$verify_root/existing.exe"
    if ! bash "$here/guest/gpuz-launcher/build.sh" \
            --bundle-dir "$directory" --output "$verify_exe" >/dev/null; then
        rm -rf -- "$verify_root"
        die "existing output is not a complete owned GPU-Z bundle"
    fi
    rm -rf -- "$verify_root"
}

validate_receipt_directory() {
    [[ -d "$OUTPUT_RECEIPT_DIR" && ! -L "$OUTPUT_RECEIPT_DIR" ]] \
        || die "host EXE receipt path is not a regular directory"
    [[ "$(stat -c %u -- "$OUTPUT_RECEIPT_DIR")" == "$EUID" ]] \
        || die "host EXE receipt directory is not owned by the packager user"
    local receipt_mode
    receipt_mode=$(stat -c %a -- "$OUTPUT_RECEIPT_DIR")
    (( (8#$receipt_mode & 077) == 0 )) \
        || die "host EXE receipt directory is accessible by other users"
}

prepare_receipt_directory() {
    if [[ -e "$OUTPUT_RECEIPT_DIR" || -L "$OUTPUT_RECEIPT_DIR" ]]; then
        validate_receipt_directory
        return
    fi
    mkdir -m 0700 -- "$OUTPUT_RECEIPT_DIR" \
        || die "could not create the private host EXE receipt directory"
    validate_receipt_directory
}

validate_existing_exe_receipt() {
    [[ -f "$OUTPUT_EXE" && ! -L "$OUTPUT_EXE" ]] \
        || die "existing stable EXE is not a regular file"
    validate_receipt_directory
    local existing_sha existing_bytes receipt
    existing_sha=$(sha256_upper "$OUTPUT_EXE")
    existing_bytes=$(stat -c %s -- "$OUTPUT_EXE")
    receipt="$OUTPUT_RECEIPT_DIR/${existing_sha}.json"
    [[ -f "$receipt" && ! -L "$receipt" &&
       "$(stat -c %u -- "$receipt")" == "$EUID" &&
       "$(stat -c %a -- "$receipt")" == 600 ]] \
        || die "existing stable EXE has no trusted content receipt"
    jq -e \
        --argjson vmId "$VM_ID" \
        --arg vmUuid "$configured_uuid_lower" \
        --arg gpuProfile "$configured_profile" \
        --arg exeName "$(basename -- "$OUTPUT_EXE")" \
        --arg exeSha256 "$existing_sha" \
        --argjson exeBytes "$existing_bytes" '
        (keys | sort) == [
            "bundleManifestSha256", "exeBytes", "exeName", "exeSha256",
            "gpuProfile", "launcherFormat", "schemaVersion", "vmId", "vmUuid"
        ] and
        .schemaVersion == 2 and .vmId == $vmId and
        (.vmUuid | ascii_downcase) == $vmUuid and
        .gpuProfile == $gpuProfile and
        .launcherFormat == "QEMU_GPUZ_SINGLE_EXE_V1" and
        .exeName == $exeName and .exeSha256 == $exeSha256 and
        .exeBytes == $exeBytes and
        (.bundleManifestSha256 | type) == "string" and
        (.bundleManifestSha256 | test("^[0-9A-F]{64}$"))
    ' "$receipt" >/dev/null \
        || die "existing stable EXE is not authenticated by its host receipt"
}

EXISTING_BUNDLE=0
EXISTING_STABLE_EXE=0
if [[ -e "$OUTPUT_DIR" || -L "$OUTPUT_DIR" ]]; then
    validate_existing_bundle_output "$OUTPUT_DIR"
    EXISTING_BUNDLE=1
fi
if [[ -e "$OUTPUT_RECEIPT_DIR" || -L "$OUTPUT_RECEIPT_DIR" ]]; then
    validate_receipt_directory
fi
if [[ -e "$OUTPUT_EXE" || -L "$OUTPUT_EXE" ]]; then
    validate_existing_exe_receipt
    EXISTING_STABLE_EXE=1
fi

WORK_ROOT=$(mktemp -d "$LOCK_DIR/.gpuz-profile-vm${VM_ID}.XXXXXXXX")
cleanup_work() {
    [[ -z "${STABLE_EXE_STAGE:-}" ]] \
        || rm -f -- "$STABLE_EXE_STAGE"
    rm -rf -- "${WORK_ROOT:-}"
}
trap cleanup_work EXIT

# stage-vm-profile intentionally supports only B.  Generate its whitelist in
# an isolated copy of the configuration.  For strict A, only the transport
# schema is normalized to B; the separate hash-pinned contract below keeps and
# validates the real A tuple.  A legacy config may also lack monitor metadata,
# which stage-vm-profile requires even though this GPU-only package never
# enables monitor rescue.  A validated transport-only fallback is therefore
# added only to this temporary copy.  The live vm.conf is never edited.
FAKE_IMAGE_ROOT="$WORK_ROOT/image-root"
FAKE_VM_ROOT="$FAKE_IMAGE_ROOT/vms/G-11"
FAKE_CONF_DIR="$FAKE_VM_ROOT/vm${VM_ID}"
FAKE_STAGE="$FAKE_IMAGE_ROOT/staging"
STAGE_TRANSFER="$WORK_ROOT/stage-transfer"
mkdir -p "$FAKE_CONF_DIR" "$FAKE_STAGE" "$STAGE_TRANSFER"
awk \
    '!/^(SPOOF_MODE|MONITOR_PROFILE|MONITOR_SERIAL)=/' \
    "$CONF" >"$FAKE_CONF_DIR/vm.conf"
printf '\nSPOOF_MODE=B\nMONITOR_PROFILE=%q\nMONITOR_SERIAL=%q\n' \
    "$transport_monitor_profile" "$transport_monitor_serial" \
    >>"$FAKE_CONF_DIR/vm.conf"
chmod 0400 "$FAKE_CONF_DIR/vm.conf"

env -u VM_INSTANCE_DIR -u VM_INSTANCE_ID \
    -u VM_DISK_ARCHIVE_DIR -u VM_BASE_ARCHIVE_DIR \
    -u VM_NVRAM_BACKUP_DIR -u ISO_DIR \
IMAGE_ROOT="$FAKE_IMAGE_ROOT" \
VM_ROOT="$FAKE_VM_ROOT" \
VM_INSTANCES_DIR="$FAKE_VM_ROOT" \
VM_SHARED_DIR="$FAKE_VM_ROOT/shared" \
VM_CONFIG_DIR="$FAKE_VM_ROOT/legacy/configs" \
VM_DISK_DIR="$FAKE_VM_ROOT/legacy/disks" \
VM_BASE_DIR="$FAKE_VM_ROOT/shared/bases" \
VM_NVRAM_DIR="$FAKE_VM_ROOT/legacy/nvram" \
VM_CONTROL_DIR="$FAKE_VM_ROOT/control" \
VM_RUN_DIR="$FAKE_VM_ROOT/control" \
VM_LOG_DIR="$FAKE_VM_ROOT/legacy/log" \
VM_ASSET_DIR="$FAKE_VM_ROOT/shared/assets" \
VM_STORAGE_COMPAT_FALLBACK=0 \
STAGE_DIR="$FAKE_STAGE" \
    "$here/stage-vm-profile.sh" "$VM_ID" \
    --transfer-dir "$STAGE_TRANSFER" >/dev/null
STAGED_BUNDLE="$STAGE_TRANSFER/vm${VM_ID}"
[[ -s "$STAGED_BUNDLE/READY" &&
   -s "$STAGED_BUNDLE/vm${VM_ID}-profile.json" ]] \
    || die "stage-vm-profile did not produce a complete HTTP-free bundle"

BUNDLE="$WORK_ROOT/bundle"
mkdir -p "$BUNDLE"
for staged_asset in apply-vm-profile.ps1 patch-grid-strings.ps1; do
    install -m 0600 -- "$STAGED_BUNDLE/$staged_asset" "$BUNDLE/$staged_asset"
done
install -m 0600 -- "$STAGED_BUNDLE/vm${VM_ID}-profile.json" \
    "$BUNDLE/gpu-profile.json"
install -m 0600 -- "$here/guest/apply-gpuz-profile.ps1" \
    "$BUNDLE/apply-gpuz-profile.ps1"
install -m 0600 -- "$here/guest/nvapi-shim/nvapi.dll" \
    "$BUNDLE/nvapi.dll"
install -m 0600 -- "$here/guest/nvapi-shim/nvapi_profile_probe32.exe" \
    "$BUNDLE/nvapi_profile_probe32.exe"
gpuz_asset_snapshot "$GPUZ_SOURCE" "$BUNDLE/$GPUZ_ASSET_BUNDLE_NAME" \
    || die "refusing a non-locked GPU-Z source"

PROFILE_SHA256=$(sha256_upper "$BUNDLE/gpu-profile.json")
SHIM_SHA256=$(sha256_upper "$BUNDLE/nvapi.dll")
PROBE_SHA256=$(sha256_upper "$BUNDLE/nvapi_profile_probe32.exe")

jq -n \
    --argjson schemaVersion 2 \
    --argjson vmId "$VM_ID" \
    --arg vmUuid "$configured_uuid" \
    --arg spoofMode "$configured_mode" \
    --arg gpuProfile "$configured_profile" \
    --arg expectedPnpId "$expected_pnp" \
    --arg expectedDriverVersion 31.0.15.3833 \
    --arg gpuzName "$GPUZ_ASSET_BUNDLE_NAME" \
    --argjson gpuzBytes "$GPUZ_ASSET_BYTES" \
    --arg gpuzVersion "$GPUZ_ASSET_PRODUCT_VERSION" \
    --arg gpuzHash "$GPUZ_ASSET_SHA256" \
    --arg profileName "gpu-profile.json" \
    --arg profileSha256 "$PROFILE_SHA256" \
    --arg shimSha256 "$SHIM_SHA256" \
    --arg probeSha256 "$PROBE_SHA256" \
    '{
        schemaVersion: $schemaVersion,
        vmId: $vmId,
        vmUuid: $vmUuid,
        spoofMode: $spoofMode,
        gpuProfile: $gpuProfile,
        expectedPnpId: $expectedPnpId,
        expectedDriverVersion: $expectedDriverVersion,
        gpuz: {
            name: $gpuzName,
            bytes: $gpuzBytes,
            productVersion: $gpuzVersion,
            sha256: $gpuzHash
        },
        profile: {name: $profileName, sha256: $profileSha256},
        appLocal: {
            shimName: "nvapi.dll",
            shimSha256: $shimSha256,
            probeName: "nvapi_profile_probe32.exe",
            probeSha256: $probeSha256
        }
    }' >"$BUNDLE/gpuz-contract.json"
chmod 0600 "$BUNDLE/gpuz-contract.json"

cat >"$BUNDLE/RUN-GPUZ-PROFILE.cmd" <<'EOF'
@echo off
setlocal
cd /d "%~dp0"
set "GPUZ_PROFILE_SCRIPT=%~dp0apply-gpuz-profile.ps1"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Stop'; try { $q=[char]34; $ps=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'; $a='-NoProfile -ExecutionPolicy Bypass -File '+$q+$env:GPUZ_PROFILE_SCRIPT+$q; $p=Start-Process -FilePath $ps -Verb RunAs -PassThru -Wait -ArgumentList $a; if ($null -eq $p) { throw 'Elevation did not start.' }; exit [int]$p.ExitCode } catch { Write-Error $_; exit 1 }"
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" echo GPU-Z profile failed with exit code %RC%.
pause
exit /b %RC%
EOF
chmod 0600 "$BUNDLE/RUN-GPUZ-PROFILE.cmd"

manifest_tmp="$BUNDLE/bundle-manifest.json"
files_json='[]'
for name in \
        gpu-profile.json \
        apply-vm-profile.ps1 patch-grid-strings.ps1 \
        apply-gpuz-profile.ps1 \
        nvapi.dll nvapi_profile_probe32.exe \
        "$GPUZ_ASSET_BUNDLE_NAME" \
        gpuz-contract.json RUN-GPUZ-PROFILE.cmd; do
    hash=$(sha256_upper "$BUNDLE/$name")
    bytes=$(stat -c %s -- "$BUNDLE/$name")
    files_json=$(jq -c \
        --arg name "$name" --arg sha256 "$hash" --argjson bytes "$bytes" \
        '. + [{name: $name, sha256: $sha256, bytes: $bytes}]' \
        <<<"$files_json")
done
jq -n --argjson schemaVersion 1 --argjson vmId "$VM_ID" \
    --argjson files "$files_json" \
    '{schemaVersion: $schemaVersion, vmId: $vmId, files: $files}' \
    >"$manifest_tmp"
chmod 0600 "$manifest_tmp"
MANIFEST_SHA256=$(sha256_upper "$manifest_tmp")
printf 'schema_version=1\nmanifest_sha256=%s\n' "$MANIFEST_SHA256" \
    >"$BUNDLE/READY"
chmod 0600 "$BUNDLE/READY"

# The native launcher is generic; the embedded contract keeps this instance
# bound to the selected VM UUID/profile.  Build before publishing anything so
# a compiler/resource failure cannot replace a previously good stable EXE.
SINGLE_EXE_TEMP="$WORK_ROOT/GpuZProfile.exe"
bash "$here/guest/gpuz-launcher/build.sh" \
    --bundle-dir "$BUNDLE" --output "$SINGLE_EXE_TEMP" >/dev/null
[[ -f "$SINGLE_EXE_TEMP" && ! -L "$SINGLE_EXE_TEMP" ]] \
    || die "single EXE builder did not produce a regular file"
SINGLE_EXE_BUILD_SHA256=$(sha256_upper "$SINGLE_EXE_TEMP")
SINGLE_EXE_BUILD_BYTES=$(stat -c %s -- "$SINGLE_EXE_TEMP")
[[ "$(dirname -- "$OUTPUT_EXE")" == "$LOCK_DIR" ]] \
    || die "single EXE output escaped the package lock directory"
EXE_RECEIPT_TEMP="$WORK_ROOT/${SINGLE_EXE_BUILD_SHA256}.json"
jq -n \
    --argjson schemaVersion 2 \
    --argjson vmId "$VM_ID" \
    --arg vmUuid "$configured_uuid_lower" \
    --arg gpuProfile "$configured_profile" \
    --arg launcherFormat QEMU_GPUZ_SINGLE_EXE_V1 \
    --arg exeName "$(basename -- "$OUTPUT_EXE")" \
    --arg exeSha256 "$SINGLE_EXE_BUILD_SHA256" \
    --argjson exeBytes "$SINGLE_EXE_BUILD_BYTES" \
    --arg bundleManifestSha256 "$MANIFEST_SHA256" \
    '{
        schemaVersion: $schemaVersion,
        vmId: $vmId,
        vmUuid: $vmUuid,
        gpuProfile: $gpuProfile,
        launcherFormat: $launcherFormat,
        exeName: $exeName,
        exeSha256: $exeSha256,
        exeBytes: $exeBytes,
        bundleManifestSha256: $bundleManifestSha256
    }' >"$EXE_RECEIPT_TEMP"
chmod 0600 "$EXE_RECEIPT_TEMP"

# Packaging never changes vm.conf.  Recheck the pinned source hash immediately
# before publication so one build cannot mix two configuration revisions.
[[ "$(sha256_upper "$CONF")" == "$CONFIG_SHA256" ]] \
    || die "VM configuration changed while the package was being built"

# Publish the content-addressed host receipt first.  It is deliberately not a
# guest payload.  If the process stops later, an unreferenced hidden receipt is
# harmless; once the stable EXE changes, its own full hash always selects the
# matching receipt without requiring a two-file atomic update.
prepare_receipt_directory
EXE_RECEIPT_FINAL="$OUTPUT_RECEIPT_DIR/${SINGLE_EXE_BUILD_SHA256}.json"
if [[ -e "$EXE_RECEIPT_FINAL" || -L "$EXE_RECEIPT_FINAL" ]]; then
    [[ -f "$EXE_RECEIPT_FINAL" && ! -L "$EXE_RECEIPT_FINAL" &&
       "$(stat -c %u -- "$EXE_RECEIPT_FINAL")" == "$EUID" &&
       "$(stat -c %a -- "$EXE_RECEIPT_FINAL")" == 600 ]] \
        || die "existing content receipt is unsafe"
    cmp -s -- "$EXE_RECEIPT_TEMP" "$EXE_RECEIPT_FINAL" \
        || die "existing content receipt conflicts with this EXE"
elif ! ln -T -- "$EXE_RECEIPT_TEMP" "$EXE_RECEIPT_FINAL"; then
    die "could not publish the content-addressed host EXE receipt"
fi

# Revalidate current outputs after the potentially long build.  A stable EXE
# is replaceable only when its pre-existing bytes have a trusted receipt.
if ((EXISTING_STABLE_EXE)); then
    validate_existing_exe_receipt
else
    [[ ! -e "$OUTPUT_EXE" && ! -L "$OUTPUT_EXE" ]] \
        || die "an unowned stable EXE appeared during packaging"
fi

# Prepare the exact stable-EXE inode before rotating the expanded host bundle.
# From this point to the final commit, only same-filesystem rename/link
# operations remain; any earlier compiler/link/chmod failure leaves published
# outputs untouched.
STABLE_EXE_STAGE="$LOCK_DIR/.$(basename -- "$OUTPUT_EXE").new.$$.$RANDOM"
[[ ! -e "$STABLE_EXE_STAGE" && ! -L "$STABLE_EXE_STAGE" ]] \
    || die "temporary stable-EXE publication path already exists"
ln -T -- "$SINGLE_EXE_TEMP" "$STABLE_EXE_STAGE" \
    || die "could not prepare stable EXE publication"
chmod 0600 "$STABLE_EXE_STAGE"
chmod 0700 "$BUNDLE"
find "$BUNDLE" -type f -exec chmod 0600 {} +

OLD_OUTPUT=""
if ((EXISTING_BUNDLE)); then
    validate_existing_bundle_output "$OUTPUT_DIR"
    OLD_OUTPUT="${OUTPUT_DIR}.old.$$.$RANDOM"
    [[ ! -e "$OLD_OUTPUT" && ! -L "$OLD_OUTPUT" ]] \
        || die "temporary previous-bundle path already exists"
    mv -T -- "$OUTPUT_DIR" "$OLD_OUTPUT"
else
    [[ ! -e "$OUTPUT_DIR" && ! -L "$OUTPUT_DIR" ]] \
        || die "an output directory appeared during packaging"
fi
if ! mv -T -- "$BUNDLE" "$OUTPUT_DIR"; then
    [[ -z "$OLD_OUTPUT" ]] || mv -T -- "$OLD_OUTPUT" "$OUTPUT_DIR"
    die "could not publish bundle: $OUTPUT_DIR"
fi

# The stable EXE is the commit point.  Initial publication is no-replace.
# Updates use one same-filesystem rename only after authenticating the old
# stable EXE above, so guest-facing output never has two "current" filenames.
if ((EXISTING_STABLE_EXE)); then
    validate_existing_exe_receipt
    if ! mv -Tf -- "$STABLE_EXE_STAGE" "$OUTPUT_EXE"; then
        FAILED_OUTPUT="$WORK_ROOT/failed-published-bundle"
        mv -T -- "$OUTPUT_DIR" "$FAILED_OUTPUT" || true
        [[ -z "$OLD_OUTPUT" ]] || mv -T -- "$OLD_OUTPUT" "$OUTPUT_DIR"
        die "could not atomically replace the authenticated stable EXE"
    fi
    STABLE_EXE_STAGE=""
elif ! ln -T -- "$STABLE_EXE_STAGE" "$OUTPUT_EXE"; then
    FAILED_OUTPUT="$WORK_ROOT/failed-published-bundle"
    mv -T -- "$OUTPUT_DIR" "$FAILED_OUTPUT" || true
    [[ -z "$OLD_OUTPUT" ]] || mv -T -- "$OLD_OUTPUT" "$OUTPUT_DIR"
    die "could not atomically publish the initial stable EXE"
else
    if ! rm -f -- "$STABLE_EXE_STAGE"; then
        log "WARNING: stable EXE committed, but its hidden staging hardlink remains at $STABLE_EXE_STAGE" ||
            true
    fi
    STABLE_EXE_STAGE=""
fi
if [[ -n "$OLD_OUTPUT" ]] && ! rm -rf -- "$OLD_OUTPUT"; then
    log "WARNING: stable EXE committed, but previous expanded bundle remains at $OLD_OUTPUT" ||
        true
fi
BUNDLE=""
trap - EXIT
if ! rm -rf -- "$WORK_ROOT"; then
    log "WARNING: stable EXE committed, but temporary host files remain at $WORK_ROOT" ||
        true
fi
WORK_ROOT=""

SINGLE_EXE_SHA256=$SINGLE_EXE_BUILD_SHA256
OUTPUT_EXE_NAME=$(basename -- "$OUTPUT_EXE")

if ! cat <<EOF
[gpuz-package] PASS
  VM:          vm${VM_ID} / ${configured_profile} / SPOOF_MODE=${configured_mode}
  GPU:         ${GPU_NAME}
  PnP target:  ${expected_pnp}
  launcher:    1.1.0.0
  bundle:      ${OUTPUT_DIR}
  manifest:    ${MANIFEST_SHA256}
  single EXE:  ${OUTPUT_EXE}
  EXE sha256:  ${SINGLE_EXE_SHA256}
  vm.conf:     ${CONFIG_SHA256}

Windows 里只做两步：
  1. 只复制 ${OUTPUT_EXE_NAME} 到目标 VM 的本地磁盘（不要从网络共享直接运行）。
  2. 双击 ${OUTPUT_EXE_NAME}，UAC 点“是”，其余资产会校验后自动解包和清理。

EXE 内部仍绑定 vm${VM_ID} 的 UUID；默认统一文件名不会放宽防串包校验。
包不会安装/重签名驱动，不会修改 BCD、Driver Store 或系统 NVAPI DLL。
持久化注册表刷新会创建一个受保护的 Windows 启动计划任务。
它也不会修改网络服务、防火墙或清理设备节点。
EOF
then
    log "WARNING: stable EXE committed, but the success summary could not be written" ||
        true
fi
exit 0
