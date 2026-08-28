#!/usr/bin/env bash
# One host command after the Windows template has shut down through the G-11
# Sysprep kit: seal, build the private licensed EXE, inject, and export.
set -euo pipefail
umask 077

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"

usage() {
    cat <<'EOF' >&2
usage: ./deploy/build-g11-private-base.sh SOURCE_VM_ID BASE_NAME [options]

Options:
  --token-file FILE.tok  Repository-external DLS client token
                         (default: $STAGE_DIR/client_configuration_token.tok)
  --vms-dir DIRECTORY    G-11 VM root (also accepts --vms-dir=DIRECTORY)
  --base-dir DIRECTORY   Final base directory (also accepts --base-dir=DIRECTORY;
                         default: VMS_DIR/_base, matching V-11)
  --replace-licensed     Rebuild the private EXE after an intentional token change
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
COMPRESSION_TYPE=zstd
COMPRESSION_PARALLEL=""
SHOW_COMPRESSION_PROGRESS=1
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
        --compression-type)
            (($# >= 2)) || die "--compression-type requires zstd or zlib"
            COMPRESSION_TYPE=$2
            shift 2
            ;;
        --compression-parallel)
            (($# >= 2)) || die "--compression-parallel requires an integer in 1..16"
            COMPRESSION_PARALLEL=$2
            shift 2
            ;;
        --no-progress)
            SHOW_COMPRESSION_PROGRESS=0
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
SELECTED_VM_ROOT=${SELECTED_VM_ROOT%/}
export VM_ROOT=$SELECTED_VM_ROOT
export VMS_DIR=$VM_ROOT
export VM_INSTANCES_DIR=${VM_INSTANCES_DIR:-$VM_ROOT}
if [[ -z "$BASE_DIRECTORY" ]]; then
    BASE_DIRECTORY="$VM_ROOT/_base"
fi
[[ "$BASE_DIRECTORY" == /* && "$BASE_DIRECTORY" != / ]] ||
    die "--base-dir must be a non-root absolute path"
BASE_DIRECTORY=${BASE_DIRECTORY%/}
export VM_BASE_DIR=$BASE_DIRECTORY
export VM_BASE_ARCHIVE_DIR="$VM_BASE_DIR/archive"

# These scripts independently validate IDs, paths, locks, qcow2 generations,
# private receipts, NTFS clean shutdown and the current profile catalog.
echo "[g11-private-base] source VM root: $VM_ROOT"
echo "[g11-private-base] final base dir: $VM_BASE_DIR (one qcow2, V-11 layout)"
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
SEALED_BASE="$VM_BASE_DIR/$BASE_NAME.qcow2"
[[ -f "$SEALED_BASE" && ! -L "$SEALED_BASE" ]] ||
    die "seal completed without a safe base image: $SEALED_BASE"
# The next step embeds a DLS credential.  seal-base.sh also serves public
# workflows, so make the private generation owner-only before injection.
chmod 0600 -- "$SEALED_BASE"
PACKAGE_ARGS=(--with-license-token)
if [[ -n "$TOKEN_FILE" ]]; then
    PACKAGE_ARGS=(--token-file "$TOKEN_FILE")
fi
((REPLACE_LICENSED == 0)) || PACKAGE_ARGS+=(--replace-licensed)
"$here/package-vgpu-one-click.sh" "${PACKAGE_ARGS[@]}"
"$here/install-vgpu-portable-to-base.sh" \
    --base-name "$BASE_NAME" --site-private --sysprep-generalized \
    --single-image --yes
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
