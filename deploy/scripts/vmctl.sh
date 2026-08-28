#!/usr/bin/env bash
# Small, credential-free wrapper for the common G-11 VM path lifecycle.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
start_vm="$here/scripts/start-vm.sh"
stop_vm="$here/scripts/stop-vm.sh"
ctl_vm="$here/scripts/ctl-vm.sh"
create_vm="$here/scripts/create-vm.sh"
create_disk="$here/scripts/create-disk.sh"
clone_vm="$here/scripts/clone-from-base.sh"
monitor_vm="$here/scripts/sync-monitor-profile.sh"
optical_vm="$here/scripts/optical-media.sh"
seal_base="$here/scripts/seal-base.sh"
promote_base="$here/scripts/promote-base.sh"
delete_vm="$here/scripts/delete-vm.sh"
migrate_layout="$here/scripts/migrate-g11-layout.sh"
repair_init="$here/scripts/repair-clone-init.sh"
refresh_private_base="$here/scripts/refresh-g11-private-base.sh"
recover_display="$here/scripts/recover-vgpu-black-screen.sh"
install_vgpu_driver="$here/scripts/install-vgpu-driver-safe.sh"
preview_capacity="$here/host/check-dgame-preview-capacity.sh"

usage() {
    cat <<'EOF'
usage:
  ./deploy/scripts/vmctl.sh ID [start options]          # shortcut for start
  ./deploy/scripts/vmctl.sh start  ID [--vms-dir ABS|--vm-dir ABS] [options]
  ./deploy/scripts/vmctl.sh stop   ID [--vms-dir ABS|--vm-dir ABS] [--force]
  ./deploy/scripts/vmctl.sh create ID [--vms-dir ABS] [create options]
  ./deploy/scripts/vmctl.sh disk   ID [--vms-dir ABS] [--blank|--from-base] [--base-name NAME] [--linked|--full-copy]
  ./deploy/scripts/vmctl.sh clone  BASE_NAME ID [--vms-dir ABS] [clone options]  # linked default
  ./deploy/scripts/vmctl.sh monitor ID [--vms-dir ABS] [--monitor-profile PROFILE] [--force]
  ./deploy/scripts/vmctl.sh seal   SOURCE_ID BASE_NAME [--vms-dir ABS] [seal options]
  ./deploy/scripts/vmctl.sh delete ID [--vms-dir ABS] [-y]
  ./deploy/scripts/vmctl.sh repair-init ID [--vms-dir ABS]
  ./deploy/scripts/vmctl.sh refresh-base BASE_NAME [--vms-dir ABS] [options]
  ./deploy/scripts/vmctl.sh repair-display ID [--vms-dir ABS] [--no-start]
  ./deploy/scripts/vmctl.sh driver-install ID [--vms-dir ABS] [--ip IPv4] [--gtk] [--start]
  ./deploy/scripts/vmctl.sh path   ID [--vms-dir ABS|--vm-dir ABS]
  ./deploy/scripts/vmctl.sh status ID [--vms-dir ABS|--vm-dir ABS]
  ./deploy/scripts/vmctl.sh display ID ACTION [--vms-dir ABS|--vm-dir ABS]
  ./deploy/scripts/vmctl.sh preview-capacity [--instances N] [--source-size WxH]
      [--size WxH] [--rate HZ]
  ./deploy/scripts/vmctl.sh cdrom  ID status|eject [storage selector]
  ./deploy/scripts/vmctl.sh cdrom  ID mount /absolute/file.iso [--replace] [storage selector]
  ./deploy/scripts/vmctl.sh migrate [--check|--apply] [--vms-dir ABS]

Examples:
  ./deploy/scripts/vmctl.sh path 2
  ./deploy/scripts/vmctl.sh start 2
  ./deploy/scripts/vmctl.sh seal 1 win10-ltsc-v1
  ./deploy/scripts/vmctl.sh clone win10-ltsc-v1 456 --start    # GPU/monitor 随机一次并固化
  ./deploy/scripts/vmctl.sh clone win10-ltsc-v1 457 --gpu-profile gtx1050_2gb --start
  ./deploy/scripts/vmctl.sh start 2 --vms-dir /mnt/fast-vms
  ./deploy/scripts/vmctl.sh stop 2 --vm-dir /mnt/fast-vms/2
  ./deploy/scripts/vmctl.sh monitor 2 --monitor-profile benq-gw2280 --force
  ./deploy/scripts/vmctl.sh display 2 stream-only
  ./deploy/scripts/vmctl.sh display 2 window-show
  ./deploy/scripts/vmctl.sh preview-capacity --instances 16 --rate 60
  ./deploy/scripts/vmctl.sh cdrom 2 mount /path/to/package.iso
  ./deploy/scripts/vmctl.sh cdrom 2 eject
  ./deploy/scripts/vmctl.sh repair-init 2
  ./deploy/scripts/vmctl.sh refresh-base win10-base
  ./deploy/scripts/vmctl.sh repair-display 8
  ./deploy/scripts/vmctl.sh driver-install 8

When a new configuration omits --gpu-profile, create and clone choose one
audited GPU row at random and persist it in vm.conf.  Normal start and clone
also use the persisted monitor profile.  The monitor action is only for an
explicit profile switch or forced offline cache repair.

The wrapper stores no credentials. Supply any required secret only through an
approved runtime channel or environment variable.

All user-facing actions are delegated to the single deploy/scripts lifecycle.
EOF
}

# Scripts that predate the common storage CLI still accept VM_ROOT.  Consume
# one --vms-dir here, validate it with the same resolver, and forward all other
# arguments unchanged.
exec_with_vms_root() {
    local script=$1
    shift
    local selected_root=""
    local -a forwarded=()

    while (($#)); do
        case "$1" in
            --vms-dir)
                (($# >= 2)) || { echo "--vms-dir requires a path" >&2; exit 2; }
                [[ -z "$selected_root" ]] || { echo "--vms-dir may be specified once" >&2; exit 2; }
                selected_root=$2
                shift 2
                ;;
            --vms-dir=*)
                [[ -z "$selected_root" ]] || { echo "--vms-dir may be specified once" >&2; exit 2; }
                selected_root=${1#*=}
                [[ -n "$selected_root" ]] || { echo "--vms-dir requires a path" >&2; exit 2; }
                shift
                ;;
            *)
                forwarded+=( "$1" )
                shift
                ;;
        esac
    done
    if [[ -n "$selected_root" ]]; then
        # shellcheck source=lib/vm-storage.sh
        source "$here/lib/vm-storage.sh"
        vm_storage_select_root "$selected_root"
        export VM_ROOT VMS_DIR
    fi
    exec "$script" "${forwarded[@]}"
}

ACTION=${1:-}
case "$ACTION" in
    [1-9]|[1-9][0-9]*)
        exec "$start_vm" "$@"
        ;;
    start)
        shift
        exec "$start_vm" "$@"
        ;;
    stop)
        shift
        exec "$stop_vm" "$@"
        ;;
    create)
        shift
        exec_with_vms_root "$create_vm" "$@"
        ;;
    disk)
        shift
        exec_with_vms_root "$create_disk" "$@"
        ;;
    clone)
        shift
        exec_with_vms_root "$clone_vm" "$@"
        ;;
    monitor)
        shift
        exec_with_vms_root "$monitor_vm" "$@"
        ;;
    delete)
        shift
        exec "$delete_vm" "$@"
        ;;
    seal)
        shift
        exec_with_vms_root "$seal_base" "$@"
        ;;
    repair-init)
        shift
        exec_with_vms_root "$repair_init" "$@"
        ;;
    refresh-base)
        shift
        exec_with_vms_root "$refresh_private_base" "$@"
        ;;
    repair-display|recover-display)
        shift
        exec "$recover_display" "$@"
        ;;
    driver-install|prepare-driver)
        shift
        exec_with_vms_root "$install_vgpu_driver" "$@"
        ;;
    promote)
        shift
        exec_with_vms_root "$promote_base" "$@"
        ;;
    path)
        shift
        [[ $# -ge 1 ]] || { usage >&2; exit 2; }
        exec "$start_vm" "$@" --print-paths
        ;;
    status)
        shift
        [[ $# -ge 1 ]] || { usage >&2; exit 2; }
        VM_ID=$1
        [[ "$VM_ID" =~ ^[1-9][0-9]*$ ]] || { usage >&2; exit 2; }
        "$start_vm" "$@" --print-paths
        if pgrep -f \
                "qemu-system-x86_64.*-name[[:space:]]+vm${VM_ID}([,[:space:]]|$)" \
                >/dev/null 2>&1; then
            echo "VM_STATUS=running"
        else
            echo "VM_STATUS=stopped"
        fi
        ;;
    display|control)
        shift
        exec "$ctl_vm" "$@"
        ;;
    preview-capacity)
        shift
        exec "$preview_capacity" "$@"
        ;;
    cdrom|optical)
        shift
        exec "$optical_vm" "$@"
        ;;
    migrate)
        shift
        exec "$migrate_layout" "$@"
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
