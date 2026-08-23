#!/usr/bin/env bash
# One-command build/hot-mount wrapper for G-11 Windows 10 Guest Lite 2.6.0.
set -euo pipefail
umask 077

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
deploy_root="$(cd "$here/.." && pwd)"
packager="$deploy_root/package-guest-lite.sh"
optical="$here/optical-media.sh"
shared_usb="$here/shared-usb.sh"

usage() {
    cat <<'EOF'
usage:
  ./deploy/scripts/guest-lite.sh ID prepare [--output-root ABS]
  ./deploy/scripts/guest-lite.sh ID mount [--replace] [options]
  ./deploy/scripts/guest-lite.sh ID status [storage selector]
  ./deploy/scripts/guest-lite.sh ID eject [storage selector]
  ./deploy/scripts/guest-lite.sh ID usb-mount [options]
  ./deploy/scripts/guest-lite.sh ID usb-status [storage selector]
  ./deploy/scripts/guest-lite.sh ID usb-eject [storage selector]

options:
  --output-root ABS
  --replace                 Replace a different currently inserted ISO
  --vms-dir ABS | --vm-dir ABS | --instances-dir ABS

By default, artifacts use one fixed child directory on the public tools USB:
  /home/ubuntu/images/vms/shared/usb/G11GuestLite/

usb-mount is preferred: it rebuilds only the G11GuestLite child directory,
then hot-adds shared/usb as a read-only removable USB disk. mount is the
optical compatibility path. Windows changes occur only after the user runs
G11GuestLite.exe. Version 2.6.0 covers Defender/firewall, notifications,
English-US default input, system and reviewed software updates, OneDrive/cloud
sync, consumer apps, Game Mode/Game DVR, High performance power, NVIDIA maximum
performance, DNF High priority, safe stale-temp cleanup, and VM performance.
EOF
}

die() { echo "[guest-lite] ERROR: $*" >&2; exit 1; }

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
    mount-usb) ACTION=usb-mount ;;
    status-usb) ACTION=usb-status ;;
    eject-usb) ACTION=usb-eject ;;
esac
case "$ACTION" in
    prepare|mount|status|eject|usb-mount|usb-status|usb-eject) ;;
    *) die "unknown action: $ACTION" ;;
esac

output_args=()
optical_args=()
selector_args=()
replace_seen=0
selector_count=0
selector_option=""
selector_value=""
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
            selector_option=$1
            selector_value=$2
            selector_args+=("$1" "$2")
            shift 2
            ;;
        --vms-dir=*|--vm-dir=*|--instances-dir=*)
            [[ -n "${1#*=}" ]] || die "${1%%=*} cannot be empty"
            selector_count=$((selector_count + 1))
            selector_option=${1%%=*}
            selector_value=${1#*=}
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
((selector_count <= 1)) || die 'choose at most one storage selector'
optical_args+=("${selector_args[@]}")

case "$ACTION" in
    mount)
        ;;
    *)
        ((replace_seen == 0)) || die '--replace is valid only with optical mount'
        ;;
esac

case "$ACTION" in
    prepare|mount|usb-mount) ;;
    *)
        ((${#output_args[@]} == 0)) ||
            die "$ACTION does not accept --output-root"
        ;;
esac
if [[ "$ACTION" == usb-mount && ${#output_args[@]} -ne 0 ]]; then
    die 'usb-mount always uses the public shared/usb directory; omit --output-root'
fi

set_default_shared_output() {
    ((${#output_args[@]} == 0)) || return 0

    # shellcheck source=../lib/vm-storage.sh
    source "$deploy_root/lib/vm-storage.sh"
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
        die 'the instance has a V-11 marker; refusing to publish a G-11 package'
    fi
    instance_dir=$(vm_storage_instance_dir "$VM_ID")
    config_path=$(vm_storage_config_path "$VM_ID")
    [[ -d "$instance_dir" && ! -L "$instance_dir" &&
       -f "$config_path" && ! -L "$config_path" ]] ||
        die "vm${VM_ID} is not a complete G-11 instance: $instance_dir"
    package_root="$VM_SHARED_DIR/usb"
    vm_storage_validate_root_path "$package_root" 'shared USB directory' ||
        die 'unsafe shared USB directory'
    mkdir -p -- "$package_root"
    vm_storage_validate_root_path "$package_root" 'shared USB directory' ||
        die 'unsafe shared USB directory after creation'
    package_root=$(realpath -e -- "$package_root")
    output_args=(--output-root "$package_root")
}

case "$ACTION" in
    prepare)
        set_default_shared_output
        exec "$packager" "${output_args[@]}"
        ;;
    mount)
        set_default_shared_output
        iso=$("$packager" "${output_args[@]}" --print-path)
        [[ "$iso" == /* && -f "$iso" && ! -L "$iso" ]] \
            || die "packager returned an unsafe ISO path: $iso"
        echo "[guest-lite] mounting read-only package: $iso"
        exec "$optical" "$VM_ID" mount "$iso" "${optical_args[@]}"
        ;;
    status|eject)
        exec "$optical" "$VM_ID" "$ACTION" "${selector_args[@]}"
        ;;
    usb-mount)
        set_default_shared_output
        # VVFAT inventories the directory when the backend opens. Eject first
        # so replacing the fixed package cannot leave a stale directory map.
        "$shared_usb" "$VM_ID" eject "${selector_args[@]}" >/dev/null
        package_dir=$("$packager" "${output_args[@]}" --print-dir-path)
        [[ "$package_dir" == /* && -d "$package_dir" && ! -L "$package_dir" ]] \
            || die "packager returned an unsafe directory: $package_dir"
        [[ "${package_dir%/G11GuestLite}" == "${output_args[1]}" ]] ||
            die "packager returned a directory outside the public USB root: $package_dir"
        echo "[guest-lite] mounting public read-only tools USB; package: $package_dir"
        exec "$shared_usb" "$VM_ID" mount "${selector_args[@]}"
        ;;
    usb-status)
        exec "$shared_usb" "$VM_ID" status "${selector_args[@]}"
        ;;
    usb-eject)
        exec "$shared_usb" "$VM_ID" eject "${selector_args[@]}"
        ;;
esac
