#!/usr/bin/env bash
# One-command build/hot-mount wrapper for the G-11 Windows guest tuner.
set -euo pipefail
umask 077

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
deploy_root="$(cd "$here/.." && pwd)"
packager="$deploy_root/package-guest-performance.sh"
optical="$here/optical-media.sh"

usage() {
    cat <<'EOF'
usage:
  ./deploy/scripts/guest-performance.sh ID prepare [--output-root ABS]
  ./deploy/scripts/guest-performance.sh ID mount [--replace] [options]
  ./deploy/scripts/guest-performance.sh ID status [storage selector]
  ./deploy/scripts/guest-performance.sh ID eject [storage selector]

options:
  --output-root ABS
  --replace                 Replace a different currently inserted ISO
  --vms-dir ABS | --vm-dir ABS | --instances-dir ABS

prepare only builds the credential-free ISO.  mount builds/reuses it and
hot-adds it as a read-only USB CD-ROM.  Windows changes occur only after the
user double-clicks a launcher inside the guest.
EOF
}

die() { echo "[guest-performance] ERROR: $*" >&2; exit 1; }

VM_ID=${1:-}
ACTION=${2:-}
if [[ "$VM_ID" == -h || "$VM_ID" == --help || "$VM_ID" == help ]]; then
    usage
    exit 0
fi
[[ "$VM_ID" =~ ^[1-9][0-9]*$ && ${#VM_ID} -le 10 && -n "$ACTION" ]] || {
    usage >&2
    exit 2
}
((10#$VM_ID <= 2147483647)) || die "VM ID is out of range: $VM_ID"
shift 2

case "$ACTION" in
    prepare|mount|status|eject) ;;
    *) die "unknown action: $ACTION" ;;
esac

output_args=()
optical_args=()
replace_seen=0
selector_count=0
while (($#)); do
    case "$1" in
        --output-root)
            (($# >= 2)) || die '--output-root requires an absolute directory'
            output_args+=("$1" "$2")
            shift 2
            ;;
        --output-root=*)
            [[ -n "${1#*=}" ]] || die '--output-root cannot be empty'
            output_args+=("$1")
            shift
            ;;
        --replace)
            ((replace_seen == 0)) || die '--replace may be specified once'
            replace_seen=1
            optical_args+=(--replace)
            shift
            ;;
        --vms-dir|--vm-dir|--instances-dir)
            (($# >= 2)) || die "$1 requires an absolute directory"
            selector_count=$((selector_count + 1))
            optical_args+=("$1" "$2")
            shift 2
            ;;
        --vms-dir=*|--vm-dir=*|--instances-dir=*)
            [[ -n "${1#*=}" ]] || die "${1%%=*} cannot be empty"
            selector_count=$((selector_count + 1))
            optical_args+=("$1")
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *) die "unknown argument: $1" ;;
    esac
done
((selector_count <= 1)) || die 'choose at most one storage selector'

case "$ACTION" in
    prepare)
        ((replace_seen == 0 && selector_count == 0)) \
            || die 'prepare does not accept --replace or a storage selector'
        exec "$packager" "${output_args[@]}"
        ;;
    mount)
        iso=$("$packager" "${output_args[@]}" --print-path)
        [[ "$iso" == /* && -f "$iso" && ! -L "$iso" ]] \
            || die "packager returned an unsafe ISO path: $iso"
        echo "[guest-performance] mounting read-only package: $iso"
        exec "$optical" "$VM_ID" mount "$iso" "${optical_args[@]}"
        ;;
    status|eject)
        ((${#output_args[@]} == 0 && replace_seen == 0)) \
            || die "$ACTION does not accept --output-root or --replace"
        exec "$optical" "$VM_ID" "$ACTION" "${optical_args[@]}"
        ;;
esac
