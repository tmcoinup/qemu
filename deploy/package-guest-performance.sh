#!/usr/bin/env bash
# Build a credential-free, read-only Windows guest startup/runtime tuning ISO.
set -euo pipefail
umask 077
export LC_ALL=C

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/vm-storage.sh
source "$here/lib/vm-storage.sh"

usage() {
    cat <<'EOF'
usage: ./deploy/package-guest-performance.sh [options]

Options:
  --output-root ABS  Artifact directory
                     (default: IMAGE_ROOT/staging/guest-performance)
  --print-path       Print only the resulting ISO path
  -h, --help         Show this help

The package contains audit/apply/verify/rollback launchers for a native
SDL/GTK G-11 guest.  It contains no VM identity or credential and makes no
guest change while it is being built.
EOF
}

die() { echo "[guest-performance-package] ERROR: $*" >&2; exit 1; }
log() {
    ((PRINT_PATH == 0)) || return 0
    echo "[guest-performance-package] $*"
}

OUTPUT_ROOT=""
PRINT_PATH=0
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
            ((PRINT_PATH == 0)) || die '--print-path may be specified once'
            PRINT_PATH=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

for dependency in xorriso sha256sum mktemp realpath install sed find sort mv awk; do
    command -v "$dependency" >/dev/null 2>&1 || die "missing host dependency: $dependency"
done

vm_storage_init
: "${OUTPUT_ROOT:=$STAGE_DIR/guest-performance}"
vm_storage_validate_root_path "$OUTPUT_ROOT" 'guest performance output root' \
    || die 'unsafe output root'
mkdir -p -- "$OUTPUT_ROOT"
vm_storage_validate_root_path "$OUTPUT_ROOT" 'guest performance output root' \
    || die 'unsafe output root after creation'
OUTPUT_ROOT=$(realpath -e -- "$OUTPUT_ROOT")

SOURCE_ROOT="$here/guest/guest-performance"
assets=(
    Optimize-Guest.ps1
    01-Audit.cmd
    02-Apply-Recommended.cmd
    03-Verify.cmd
    04-Rollback.cmd
    README.txt
)
for asset in "${assets[@]}"; do
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

published="$work/G11GuestPerformance"
install -d -m 0700 -- "$published"
for asset in "${assets[@]}"; do
    install -m 0600 -- "$SOURCE_ROOT/$asset" "$published/$asset"
done

# cmd.exe on affected Windows builds can consume a byte after a bare LF.
# Publish command launchers as canonical CRLF without changing source files.
for launcher in "$published"/*.cmd; do
    sed -i 's/$/\r/' "$launcher"
done

(
    cd "$published"
    sha256sum -- "${assets[@]}" >SHA256SUMS.txt
)
chmod 0600 "$published/SHA256SUMS.txt"
bundle_id=$(sha256sum -- "$published/SHA256SUMS.txt" | awk '{print substr($1,1,16)}')
output_name="G11GuestPerformance-$bundle_id"
output_dir="$OUTPUT_ROOT/$output_name"
output_iso="$OUTPUT_ROOT/$output_name.iso"

if [[ -e "$output_dir" || -L "$output_dir" || -e "$output_iso" || -L "$output_iso" ]]; then
    [[ -d "$output_dir" && ! -L "$output_dir" &&
       -f "$output_iso" && ! -L "$output_iso" && -s "$output_iso" &&
       -f "$output_dir/SHA256SUMS.txt" && ! -L "$output_dir/SHA256SUMS.txt" &&
       -f "$output_dir/ISO-SHA256.txt" && ! -L "$output_dir/ISO-SHA256.txt" ]] \
        || die "incomplete or unsafe existing artifact: $output_name"
    existing_id=$(sha256sum -- "$output_dir/SHA256SUMS.txt" | awk '{print substr($1,1,16)}')
    [[ "$existing_id" == "$bundle_id" ]] \
        || die "existing content-addressed artifact failed validation: $output_name"
    (cd "$output_dir" && sha256sum -c SHA256SUMS.txt >/dev/null) \
        || die "existing guest payload failed checksum validation: $output_name"
    expected_iso_sha=$(<"$output_dir/ISO-SHA256.txt")
    [[ "$expected_iso_sha" =~ ^[0-9a-f]{64}$ &&
       "$(sha256sum -- "$output_iso" | awk '{print $1}')" == "$expected_iso_sha" ]] \
        || die "existing ISO failed checksum validation: $output_name"
    log "reuse $output_iso"
    if ((PRINT_PATH)); then printf '%s\n' "$output_iso"; fi
    exit 0
fi

iso_work="$work/$output_name.iso"
xorriso -as mkisofs -quiet -iso-level 3 -J -joliet-long -r \
    -V G11_GUEST_PERF -o "$iso_work" "$published"
[[ -f "$iso_work" && ! -L "$iso_work" && -s "$iso_work" ]] \
    || die 'ISO build failed'
iso_sha=$(sha256sum -- "$iso_work" | awk '{print $1}')
printf '%s\n' "$iso_sha" >"$published/ISO-SHA256.txt"
chmod 0600 "$published/ISO-SHA256.txt"

mv -T -- "$published" "$output_dir"
mv -- "$iso_work" "$output_iso"
chmod 0700 "$output_dir"
chmod 0600 "$output_dir"/* "$output_iso"

if ((PRINT_PATH)); then
    printf '%s\n' "$output_iso"
else
    log 'PASS'
    log "directory: $output_dir"
    log "read-only ISO: $output_iso"
    log "ISO SHA256: $iso_sha"
    log 'maintenance only: run 02-Apply-Recommended.cmd; 01-Audit.cmd is optional read-only diagnostics'
fi
