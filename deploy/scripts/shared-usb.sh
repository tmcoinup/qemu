#!/usr/bin/env bash
# Mount the common G-11 tools directory as one read-only USB disk.
set -euo pipefail
umask 077

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_ROOT="$(cd "$HERE/.." && pwd)"
USB_DIRECTORY="$HERE/usb-directory.sh"

usage() {
    cat <<'EOF'
usage:
  ./deploy/scripts/shared-usb.sh ID mount [storage selector]
  ./deploy/scripts/shared-usb.sh ID status [storage selector]
  ./deploy/scripts/shared-usb.sh ID eject [storage selector]

storage selector (choose at most one):
  --vms-dir ABS | --vm-dir ABS | --instances-dir ABS

The default public USB root is:
  /home/ubuntu/images/vms/shared/usb

Each tool owns one child directory below that root. mount always ejects and
reopens the VVFAT view so host-side package updates are visible in Windows.
Windows sees a 128 GiB read-only FAT32 USB disk.  The capacity is virtual: no
128 GiB host image is created, and only files below the public USB root occupy
host storage.
EOF
}

die() {
    echo "[shared-usb] ERROR: $*" >&2
    exit 1
}

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
    unmount|remove) ACTION=eject ;;
esac
case "$ACTION" in
    mount|status|eject) ;;
    *) die "unknown action: $ACTION" ;;
esac

selector_args=()
selector_option=""
selector_value=""
while (($#)); do
    case "$1" in
        --vms-dir|--vm-dir|--instances-dir)
            (($# >= 2)) || die "$1 requires an absolute directory"
            [[ -z "$selector_option" ]] || die 'choose only one storage selector'
            selector_option=$1
            selector_value=$2
            selector_args+=("$1" "$2")
            shift 2
            ;;
        --vms-dir=*|--vm-dir=*|--instances-dir=*)
            [[ -z "$selector_option" ]] || die 'choose only one storage selector'
            selector_option=${1%%=*}
            selector_value=${1#*=}
            [[ -n "$selector_value" ]] || die "$selector_option requires an absolute directory"
            selector_args+=("$1")
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *) die "unknown argument: $1" ;;
    esac
done

# shellcheck source=../lib/vm-storage.sh
source "$DEPLOY_ROOT/lib/vm-storage.sh"
case "$selector_option" in
    --vms-dir) vm_storage_select_root "$selector_value" ;;
    --vm-dir) vm_storage_select_instance_dir "$VM_ID" "$selector_value" ;;
    --instances-dir) vm_storage_select_instances_dir "$selector_value" ;;
    '') ;;
    *) die "unsupported storage selector: $selector_option" ;;
esac
vm_storage_init
vm_storage_validate_id "$VM_ID"
vm_storage_validate_instance_tree "$VM_ID"
if vm_storage_v11_collision "$VM_ID"; then
    die 'the instance has a V-11 marker; refusing to attach a G-11 shared USB disk'
fi

SHARED_USB_ROOT="$VM_SHARED_DIR/usb"
if [[ "$ACTION" == mount ]]; then
    vm_storage_validate_root_path "$SHARED_USB_ROOT" 'shared USB directory' ||
        die 'unsafe shared USB directory'
    mkdir -p -- "$SHARED_USB_ROOT"
    vm_storage_validate_root_path "$SHARED_USB_ROOT" 'shared USB directory' ||
        die 'unsafe shared USB directory after creation'
    SHARED_USB_ROOT=$(realpath -e -- "$SHARED_USB_ROOT")
    echo "[shared-usb] refreshing read-only public USB: $SHARED_USB_ROOT"
    exec "$USB_DIRECTORY" "$VM_ID" mount "$SHARED_USB_ROOT" \
        --replace --label 'U盘' --size 128G "${selector_args[@]}"
fi

exec "$USB_DIRECTORY" "$VM_ID" "$ACTION" "${selector_args[@]}"
