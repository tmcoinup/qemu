#!/usr/bin/env bash
# One host command after the Windows template has shut down through the G-11
# Sysprep kit: seal, build the private licensed EXE, inject, and export.
set -euo pipefail
umask 077

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"

# shellcheck source=lib/vm-storage.sh
source "$here/lib/vm-storage.sh"

usage() {
    cat <<'EOF' >&2
usage: ./deploy/build-g11-private-base.sh SOURCE_VM_ID BASE_NAME [options]

Options:
  --token-file FILE.tok  Repository-external DLS client token
                         (default: $STAGE_DIR/client_configuration_token.tok)
  --vms-dir DIRECTORY    G-11 VM root (also accepts --vms-dir=DIRECTORY)
  --base-dir DIRECTORY   Final base directory (also accepts --base-dir=DIRECTORY;
                         default: VMS_DIR/_base, matching V-11)
  --resume-sealed        Resume only after this command already completed sealing
                         but failed before portable injection/export. Validates the
                         existing qcow2 and stopped source VM; never implied.
  --replace-licensed     Rebuild the private EXE after an intentional
                         token/catalog/driver contract change
  --compression-type T   qcow2 compressor: zstd (default, faster) or zlib
  --compression-parallel N
                         qemu-img parallelism in 1..16
                         (default: online CPUs, capped at 16)
  --no-progress          Disable the compression percentage display

For compatibility, the old third positional OUTPUT_DIRECTORY is still accepted
as --base-dir. Run only after Seal-G11-Template.cmd completed Sysprep
/generalize /oobe /shutdown. The output contains a private credential.
EOF
}
die() { echo "[g11-private-base] ERROR: $*" >&2; exit 1; }

TOKEN_FILE=""
VMS_DIRECTORY=""
BASE_DIRECTORY=""
REPLACE_LICENSED=0
RESUME_SEALED=0
COMPRESSION_TYPE=zstd
COMPRESSION_PARALLEL=""
SHOW_COMPRESSION_PROGRESS=1
SEAL_TUNING_SET=0
declare -a POSITIONAL=()
while (($#)); do
    case "$1" in
        --token-file)
            (($# >= 2)) || die "--token-file requires FILE.tok"
            TOKEN_FILE=$2
            shift 2
            ;;
        --vms-dir)
            (($# >= 2)) || die "--vms-dir requires DIRECTORY"
            VMS_DIRECTORY=$2
            shift 2
            ;;
        --vms-dir=*)
            VMS_DIRECTORY=${1#*=}
            shift
            ;;
        --base-dir)
            (($# >= 2)) || die "--base-dir requires DIRECTORY"
            [[ -z "$BASE_DIRECTORY" ]] || die "--base-dir may be specified once"
            BASE_DIRECTORY=$2
            shift 2
            ;;
        --base-dir=*)
            [[ -z "$BASE_DIRECTORY" ]] || die "--base-dir may be specified once"
            BASE_DIRECTORY=${1#*=}
            shift
            ;;
        --replace-licensed)
            REPLACE_LICENSED=1
            shift
            ;;
        --resume-sealed)
            RESUME_SEALED=1
            shift
            ;;
        --compression-type)
            (($# >= 2)) || die "--compression-type requires zstd or zlib"
            COMPRESSION_TYPE=$2
            SEAL_TUNING_SET=1
            shift 2
            ;;
        --compression-parallel)
            (($# >= 2)) || die "--compression-parallel requires an integer in 1..16"
            COMPRESSION_PARALLEL=$2
            SEAL_TUNING_SET=1
            shift 2
            ;;
        --no-progress)
            SHOW_COMPRESSION_PROGRESS=0
            SEAL_TUNING_SET=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --*) die "unknown option: $1" ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done
((${#POSITIONAL[@]} == 2 || ${#POSITIONAL[@]} == 3)) || { usage; exit 2; }
SOURCE_VM_ID=${POSITIONAL[0]}
BASE_NAME=${POSITIONAL[1]}
if ((${#POSITIONAL[@]} == 3)); then
    [[ -z "$BASE_DIRECTORY" ]] ||
        die "legacy OUTPUT_DIRECTORY and --base-dir cannot be combined"
    BASE_DIRECTORY=${POSITIONAL[2]}
fi
[[ "$SOURCE_VM_ID" =~ ^[1-9][0-9]{0,9}$ ]] &&
    ((10#$SOURCE_VM_ID <= 2147483647)) ||
    die "SOURCE_VM_ID must be an integer in 1..2147483647"
vm_storage_validate_base_name "$BASE_NAME" >/dev/null ||
    die "BASE_NAME must contain only 1..128 letters, digits, '_' or '-'"
if ((RESUME_SEALED && SEAL_TUNING_SET)); then
    die "--resume-sealed cannot be combined with compression/progress options (the seal step is not rerun)"
fi
[[ "$COMPRESSION_TYPE" == zstd || "$COMPRESSION_TYPE" == zlib ]] ||
    die "--compression-type must be zstd or zlib"
if [[ -z "$COMPRESSION_PARALLEL" ]]; then
    if command -v nproc >/dev/null 2>&1; then
        COMPRESSION_PARALLEL=$(nproc)
    else
        COMPRESSION_PARALLEL=1
    fi
    [[ "$COMPRESSION_PARALLEL" =~ ^[1-9][0-9]*$ ]] ||
        COMPRESSION_PARALLEL=1
    ((COMPRESSION_PARALLEL <= 16)) || COMPRESSION_PARALLEL=16
else
    [[ "$COMPRESSION_PARALLEL" =~ ^[1-9][0-9]*$ ]] &&
        ((10#$COMPRESSION_PARALLEL <= 16)) ||
        die "--compression-parallel must be an integer in 1..16"
fi

if [[ -n "$VMS_DIRECTORY" ]]; then
    [[ "$VMS_DIRECTORY" == /* && "$VMS_DIRECTORY" != / ]] ||
        die "--vms-dir must be a non-root absolute path"
    export VM_ROOT=${VMS_DIRECTORY%/}
    export VMS_DIR=$VM_ROOT
    export VM_INSTANCES_DIR=$VM_ROOT
fi

SELECTED_VM_ROOT=${VM_ROOT:-${VMS_DIR:-${IMAGE_ROOT:-/home/ubuntu/images}/vms}}
[[ "$SELECTED_VM_ROOT" == /* && "$SELECTED_VM_ROOT" != / ]] ||
    die "selected VM root must be a non-root absolute path"
SELECTED_VM_ROOT=$(realpath -ms -- "${SELECTED_VM_ROOT%/}") ||
    die "could not normalize selected VM root"
[[ "$SELECTED_VM_ROOT" != / ]] ||
    die "selected VM root must remain non-root after normalization"
vm_storage_validate_root_path "$SELECTED_VM_ROOT" "VM root" ||
    die "selected VM root is unsafe"
export VM_ROOT=$SELECTED_VM_ROOT
export VMS_DIR=$VM_ROOT
export VM_INSTANCES_DIR=${VM_INSTANCES_DIR:-$VM_ROOT}
if [[ -z "$BASE_DIRECTORY" ]]; then
    BASE_DIRECTORY="$VM_ROOT/_base"
fi
[[ "$BASE_DIRECTORY" == /* && "$BASE_DIRECTORY" != / ]] ||
    die "--base-dir must be a non-root absolute path"
BASE_DIRECTORY=$(realpath -ms -- "${BASE_DIRECTORY%/}") ||
    die "could not normalize --base-dir"
[[ "$BASE_DIRECTORY" != / ]] ||
    die "--base-dir must remain non-root after normalization"
vm_storage_validate_root_path "$BASE_DIRECTORY" "base directory" ||
    die "--base-dir is unsafe"
export VM_BASE_DIR=$BASE_DIRECTORY
export VM_BASE_ARCHIVE_DIR="$VM_BASE_DIR/archive"
vm_storage_init

SEALED_BASE="$VM_BASE_DIR/$BASE_NAME.qcow2"
SEALED_ATTESTATION="${SEALED_BASE}.vgpu-portable.json"
SEALED_MANIFEST="$VM_BASE_DIR/$BASE_NAME.g11base"

assert_resume_incomplete_state() {
    local path nullglob_was_set=0
    local -a remnants=()

    for path in "$SEALED_ATTESTATION" "$SEALED_MANIFEST"; do
        [[ ! -e "$path" && ! -L "$path" ]] ||
            die "--resume-sealed requires a sealed-only checkpoint; move nothing automatically and inspect: $path"
    done

    # A failed installer/export transaction must be diagnosed, not mistaken
    # for the earlier package-only failure that this resume mode handles.
    shopt -q nullglob && nullglob_was_set=1
    shopt -s nullglob
    remnants=(
        "$VM_BASE_DIR/.${BASE_NAME}.qcow2.vgpu-portable."*
        "$VM_BASE_DIR/.${BASE_NAME}.qcow2.pre-vgpu-portable-"*
        "$VM_BASE_DIR/${BASE_NAME}.qcow2.vgpu-portable.json.new."*
        "$VM_BASE_DIR/.${BASE_NAME}.g11base.new."*
    )
    ((nullglob_was_set)) || shopt -u nullglob
    ((${#remnants[@]} == 0)) || {
        echo "[g11-private-base] ERROR: unfinished installer/export files exist; refusing sealed-only resume:" >&2
        printf '  %s\n' "${remnants[@]}" >&2
        exit 1
    }
}

sealed_base_state_sha256() {
    local image=$1
    TZ=UTC stat -c '%D|%i|%s|%y' -- "$image" |
        sha256sum | awk '{print toupper($1)}'
}

validate_sealed_resume() {
    local source_disk start_lock held_path holders
    local source_virtual_size source_mtime base_mtime base_links
    local qemu_process_pattern

    for dependency in jq flock lsof pgrep stat sha256sum awk; do
        command -v "$dependency" >/dev/null 2>&1 ||
            die "--resume-sealed requires host command: $dependency"
    done
    vm_storage_validate_root_path "$VM_ROOT" "VM root" ||
        die "unsafe VM root"
    vm_storage_validate_root_path "$VM_BASE_DIR" "base directory" ||
        die "unsafe base directory"
    [[ -d "$VM_BASE_DIR" && ! -L "$VM_BASE_DIR" ]] ||
        die "--resume-sealed requires an existing real base directory: $VM_BASE_DIR"
    vm_storage_require_namespace_ready "$SOURCE_VM_ID" ||
        die "source VM namespace is not safe"
    vm_storage_validate_instance_tree "$SOURCE_VM_ID" ||
        die "source VM directory is not safe"

    source_disk=$(vm_storage_disk_path "$SOURCE_VM_ID") ||
        die "could not resolve vm${SOURCE_VM_ID} disk"
    [[ -f "$source_disk" && ! -L "$source_disk" ]] ||
        die "--resume-sealed requires the original regular non-symlink source disk: $source_disk"
    [[ -f "$SEALED_BASE" && ! -L "$SEALED_BASE" ]] ||
        die "--resume-sealed requires an existing regular non-symlink base: $SEALED_BASE"
    [[ ! "$source_disk" -ef "$SEALED_BASE" ]] ||
        die "source disk and sealed base unexpectedly identify the same file"
    base_links=$(stat -c %h -- "$SEALED_BASE") ||
        die "could not inspect sealed base link count"
    [[ "$base_links" == 1 ]] ||
        die "sealed-only base already has hard-link users (links=$base_links); refusing in-place resume"
    assert_resume_incomplete_state

    start_lock=$(vm_storage_run_path "$SOURCE_VM_ID" start.lock) ||
        die "could not resolve vm${SOURCE_VM_ID} start lock"
    [[ -d "${start_lock%/*}" && ! -L "${start_lock%/*}" ]] ||
        die "source VM runtime directory is missing or unsafe: ${start_lock%/*}"
    [[ ! -L "$start_lock" && ( ! -e "$start_lock" || -f "$start_lock" ) ]] ||
        die "source VM start lock is unsafe: $start_lock"
    exec {RESUME_START_LOCK_FD}>>"$start_lock" ||
        die "could not open source VM start lock: $start_lock"
    flock -n "$RESUME_START_LOCK_FD" ||
        die "vm${SOURCE_VM_ID} is starting or running; stop it before --resume-sealed"

    qemu_process_pattern="qemu-system-x86_64.*-name[[:space:]]+vm${SOURCE_VM_ID}([,[:space:]]|$)"
    if pgrep -f "$qemu_process_pattern" >/dev/null; then
        die "vm${SOURCE_VM_ID} QEMU is still running; stop it before --resume-sealed"
    fi
    for held_path in "$source_disk" "$SEALED_BASE"; do
        holders=$(lsof -t -- "$held_path" 2>/dev/null | paste -sd, - || true)
        [[ -z "$holders" ]] ||
            die "file is still open (pids=$holders), refusing resume: $held_path"
    done

    : "${QEMU_IMG:=$here/../build/qemu-img}"
    [[ -x "$QEMU_IMG" ]] || QEMU_IMG=$(command -v qemu-img || true)
    [[ -x "$QEMU_IMG" ]] || die "qemu-img is missing; set QEMU_IMG explicitly"
    vm_storage_read_qcow2_metadata "$QEMU_IMG" "$source_disk" ||
        die "source disk is not a verifiable qcow2: $source_disk"
    source_virtual_size=$VM_STORAGE_QCOW2_VIRTUAL_SIZE
    vm_storage_read_qcow2_metadata "$QEMU_IMG" "$SEALED_BASE" ||
        die "sealed base is not a verifiable qcow2: $SEALED_BASE"
    [[ -z "$VM_STORAGE_QCOW2_BACKING" &&
       -z "$VM_STORAGE_QCOW2_DATA_FILE" ]] ||
        die "sealed base is not standalone (backing/data-file present)"
    [[ "$VM_STORAGE_QCOW2_VIRTUAL_SIZE" == "$source_virtual_size" ]] ||
        die "sealed base/source virtual sizes differ; cannot prove this checkpoint belongs to vm${SOURCE_VM_ID}"
    "$QEMU_IMG" check -q "$SEALED_BASE" ||
        die "qemu-img check failed for sealed base: $SEALED_BASE"
    "$QEMU_IMG" compare -q "$source_disk" "$SEALED_BASE" ||
        die "sealed base logical contents differ from vm${SOURCE_VM_ID} source disk; refusing resume"

    source_mtime=$(stat -c %Y -- "$source_disk") ||
        die "could not inspect source disk timestamp"
    base_mtime=$(stat -c %Y -- "$SEALED_BASE") ||
        die "could not inspect sealed base timestamp"
    ((base_mtime >= source_mtime)) ||
        die "sealed base predates the current source disk; rerun the normal build instead"

    export QEMU_IMG
    echo "[g11-private-base] resume checkpoint PASS: standalone sealed-only base, vm${SOURCE_VM_ID} stopped"
    echo "[g11-private-base] seal-base will be skipped only because --resume-sealed was explicit"
}

# These scripts independently validate IDs, paths, locks, qcow2 generations,
# private receipts, NTFS clean shutdown and the current profile catalog.
echo "[g11-private-base] source VM root: $VM_ROOT"
echo "[g11-private-base] final base dir: $VM_BASE_DIR (one qcow2, V-11 layout)"
if ((RESUME_SEALED)); then
    echo "[g11-private-base] mode: explicit sealed-checkpoint resume"
    validate_sealed_resume
else
    progress_label=off
    ((SHOW_COMPRESSION_PROGRESS == 0)) || progress_label=on
    echo "[g11-private-base] compression: ${COMPRESSION_TYPE}, parallel=${COMPRESSION_PARALLEL}, progress=${progress_label}"
    SEAL_ARGS=(
        "$SOURCE_VM_ID" "$BASE_NAME" --yes --single-image
        --compression-type "$COMPRESSION_TYPE"
        --compression-parallel "$COMPRESSION_PARALLEL"
    )
    ((SHOW_COMPRESSION_PROGRESS == 0)) || SEAL_ARGS+=(--progress)
    "$here/scripts/seal-base.sh" "${SEAL_ARGS[@]}"
fi
[[ -f "$SEALED_BASE" && ! -L "$SEALED_BASE" ]] ||
    die "seal completed without a safe base image: $SEALED_BASE"
# The next step embeds a DLS credential.  seal-base.sh also serves public
# workflows, so make the private generation owner-only before injection.
chmod 0600 -- "$SEALED_BASE"
if ((RESUME_SEALED)); then
    RESUME_BASE_STATE_SHA256=$(sealed_base_state_sha256 "$SEALED_BASE") ||
        die "could not fingerprint resumed base"
fi
PACKAGE_ARGS=(--with-license-token)
if [[ -n "$TOKEN_FILE" ]]; then
    PACKAGE_ARGS=(--token-file "$TOKEN_FILE")
fi
((REPLACE_LICENSED == 0)) || PACKAGE_ARGS+=(--replace-licensed)
"$here/package-vgpu-one-click.sh" "${PACKAGE_ARGS[@]}"
if ((RESUME_SEALED)); then
    [[ -f "$SEALED_BASE" && ! -L "$SEALED_BASE" ]] ||
        die "sealed base disappeared while packaging"
    [[ "$(sealed_base_state_sha256 "$SEALED_BASE")" == "$RESUME_BASE_STATE_SHA256" ]] ||
        die "sealed base changed while packaging; refusing offline injection"
    assert_resume_incomplete_state
fi
INSTALL_ARGS=(
    --base-name "$BASE_NAME" --site-private --sysprep-generalized
    --single-image --yes
)
if ((RESUME_SEALED)); then
    INSTALL_ARGS+=(--expect-base-state-sha256 "$RESUME_BASE_STATE_SHA256")
fi
"$here/install-vgpu-portable-to-base.sh" "${INSTALL_ARGS[@]}"
"$here/scripts/export-vgpu-base.sh" --in-place "$BASE_NAME" "$VM_BASE_DIR"
rmdir -- "$VM_BASE_ARCHIVE_DIR" 2>/dev/null || true

cat <<EOF
[g11-private-base] 全部完成：最终只保留一个 qcow2。
  image:    $VM_BASE_DIR/$BASE_NAME.qcow2
  manifest: $VM_BASE_DIR/$BASE_NAME.g11base

本机直接克隆（同一个镜像，不再复制 base）：
EOF
printf '  ./deploy/scripts/clone-from-base.sh %q NEW_VM_ID' "$BASE_NAME"
DEFAULT_VM_ROOT=${IMAGE_ROOT:-/home/ubuntu/images}/vms
DEFAULT_VM_ROOT=${DEFAULT_VM_ROOT%/}
if [[ "$VM_ROOT" != "$DEFAULT_VM_ROOT" ]]; then
    printf ' --vms-dir=%q' "$VM_ROOT"
fi
printf ' --start\n'
cat <<EOF

交付其它电脑时，只复制上面的 .qcow2 与 .g11base；本机证明 JSON 不用复制。
EOF
