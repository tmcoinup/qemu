#!/usr/bin/env bash
# Build a credential-free, read-only G-11 Windows 10 guest-lite ISO.
set -euo pipefail
umask 077
export LC_ALL=C

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/vm-storage.sh
source "$here/lib/vm-storage.sh"

usage() {
    cat <<'EOF'
usage: ./deploy/package-guest-lite.sh [options]

Options:
  --output-root ABS  Artifact directory
                     (default: IMAGE_ROOT/staging/guest-lite)
  --print-path       Print only the resulting ISO path
  --print-exe-path   Print only the standalone EXE path
  --print-dir-path   Print only the directory that can be mounted as a USB disk
  -h, --help         Show this help

The output contains standalone 64-bit Guest Lite 2.5.2 plus reviewable Windows 10
audit/apply/rollback sources. Runtime imports are Windows inbox components only.
It has no credential or VM identity and makes no Windows change until the user
explicitly runs it in the guest.
EOF
}

die() { echo "[guest-lite-package] ERROR: $*" >&2; exit 1; }
log() {
    ((PRINT_PATH == 0 && PRINT_EXE_PATH == 0 && PRINT_DIR_PATH == 0)) || return 0
    echo "[guest-lite-package] $*"
}

OUTPUT_ROOT=""
PRINT_PATH=0
PRINT_EXE_PATH=0
PRINT_DIR_PATH=0
while (($#)); do
    case "$1" in
        --output-root)
            (($# >= 2)) || die '--output-root requires an absolute directory'
            OUTPUT_ROOT=$2
            shift 2
            ;;
        --output-root=*)
            OUTPUT_ROOT=${1#*=}
            [[ -n "$OUTPUT_ROOT" ]] || die '--output-root cannot be empty'
            shift
            ;;
        --print-path)
            ((PRINT_PATH == 0 && PRINT_EXE_PATH == 0 && PRINT_DIR_PATH == 0)) \
                || die 'choose only one print-path option'
            PRINT_PATH=1
            shift
            ;;
        --print-exe-path)
            ((PRINT_PATH == 0 && PRINT_EXE_PATH == 0 && PRINT_DIR_PATH == 0)) \
                || die 'choose only one print-path option'
            PRINT_EXE_PATH=1
            shift
            ;;
        --print-dir-path)
            ((PRINT_PATH == 0 && PRINT_EXE_PATH == 0 && PRINT_DIR_PATH == 0)) \
                || die 'choose only one print-path option'
            PRINT_DIR_PATH=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *) die "unknown argument: $1" ;;
    esac
done

for dependency in xorriso mktemp realpath install sed mv \
        x86_64-w64-mingw32-gcc x86_64-w64-mingw32-windres; do
    command -v "$dependency" >/dev/null 2>&1 \
        || die "missing host dependency: $dependency"
done

vm_storage_init
: "${OUTPUT_ROOT:=$STAGE_DIR/guest-lite}"
vm_storage_validate_root_path "$OUTPUT_ROOT" 'guest lite output root' \
    || die 'unsafe output root'
mkdir -p -- "$OUTPUT_ROOT"
vm_storage_validate_root_path "$OUTPUT_ROOT" 'guest lite output root' \
    || die 'unsafe output root after creation'
OUTPUT_ROOT=$(realpath -e -- "$OUTPUT_ROOT")

SOURCE_ROOT="$here/guest/guest-lite"
EXE_BUILDER="$SOURCE_ROOT/exe/build.sh"
source_assets=(
    G11-Guest-Lite.ps1
    01-OneClick-Apply.cmd
    02-Audit.cmd
    03-Rollback.cmd
    README.txt
)
[[ -f "$EXE_BUILDER" && ! -L "$EXE_BUILDER" && -x "$EXE_BUILDER" ]] \
    || die "missing or unsafe EXE builder: $EXE_BUILDER"
for asset in "${source_assets[@]}"; do
    path="$SOURCE_ROOT/$asset"
    [[ -f "$path" && ! -L "$path" && -s "$path" ]] \
        || die "missing or unsafe guest asset: $path"
done

work=$(mktemp -d "$OUTPUT_ROOT/.build.XXXXXXXX")
cleanup() {
    [[ -n "${work:-}" && "$work" == "$OUTPUT_ROOT"/.build.* ]] || return 0
    rm -rf -- "$work"
}
trap cleanup EXIT INT TERM

published="$work/G11GuestLite"
install -d -m 0700 -- "$published"
for asset in "${source_assets[@]}"; do
    install -m 0600 -- "$SOURCE_ROOT/$asset" "$published/$asset"
done

# cmd.exe requires canonical CRLF on affected Windows 10 builds. Keep the
# reviewed source LF-only and convert only the published launchers.
for launcher in "$published"/*.cmd; do
    sed -i 's/$/\r/' "$launcher"
done

"$EXE_BUILDER" --output "$published/G11GuestLite.exe" >/dev/null
[[ -f "$published/G11GuestLite.exe" &&
   ! -L "$published/G11GuestLite.exe" &&
   -s "$published/G11GuestLite.exe" ]] \
    || die 'standalone EXE build failed'

output_name="G11GuestLite"
output_dir="$OUTPUT_ROOT/$output_name"
output_iso="$output_dir/$output_name.iso"

if [[ -e "$output_dir" || -L "$output_dir" ]]; then
    [[ -d "$output_dir" && ! -L "$output_dir" ]] \
        || die "fixed output directory is unsafe: $output_dir"
fi
iso_work="$work/$output_name.iso"
xorriso -as mkisofs -quiet -iso-level 3 -J -joliet-long -r \
    -V G11_GUEST_LITE -o "$iso_work" "$published"
[[ -f "$iso_work" && ! -L "$iso_work" && -s "$iso_work" ]] \
    || die 'ISO build failed'
mv -T -- "$iso_work" "$published/$output_name.iso"

# Fixed names intentionally replace the previous unpublished copy.  Callers
# that expose the directory through VVFAT must eject it before rebuilding.
rm -rf -- "$output_dir"
mv -T -- "$published" "$output_dir"
chmod 0700 "$output_dir"
chmod 0600 "$output_dir"/*

if ((PRINT_PATH)); then
    printf '%s\n' "$output_iso"
elif ((PRINT_EXE_PATH)); then
    printf '%s\n' "$output_dir/G11GuestLite.exe"
elif ((PRINT_DIR_PATH)); then
    printf '%s\n' "$output_dir"
else
    log 'PASS'
    log "directory: $output_dir"
    log "read-only ISO: $output_iso"
    log "standalone EXE: $output_dir/G11GuestLite.exe"
    log 'inside Windows 10: turn off Tamper Protection, then run G11GuestLite.exe'
fi
