#!/usr/bin/env bash
# One-command recovery for the R535 local-console page-alignment black screen.
# The only running-VM action is an ACPI shutdown; this script never escalates
# to SIGTERM/SIGKILL.  Offline repair is delegated to the authenticated G-11
# monitor synchronizer, then the VM is cold-started normally.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/vm-storage.sh
source "$here/lib/vm-storage.sh"

usage() {
    cat <<'EOF'
usage: ./deploy/scripts/recover-vgpu-black-screen.sh VM_ID [options]

Options:
  --vms-dir ABS  Select an alternate G-11 instances root
  --no-start     Repair the stopped VM but do not start it
  -h, --help     Show this help

Flow:
  1. If running, request an ACPI shutdown and refuse force-kill fallback.
  2. Rebuild the reviewed R535 page-safe EDID/NV_Modes contract offline.
  3. Delete stale GraphicsDrivers mode caches, including old 1680x1050.
  4. Cold-start normally unless --no-start was supplied.

No BCD/signing setting, INF/CAT/SYS, kernel driver, or host credential is
stored or modified.  Sudo is obtained by the normal monitor-sync prompt or a
runtime-only SUDO_PASSWORD environment variable.
EOF
}

VM_ID=""
VMS_DIR_CLI=""
START_AFTER=1
while (( $# > 0 )); do
    case "$1" in
        --vms-dir)
            (( $# >= 2 )) || { echo "--vms-dir requires a path" >&2; exit 2; }
            [[ -z "$VMS_DIR_CLI" ]] || { echo "--vms-dir may be supplied once" >&2; exit 2; }
            VMS_DIR_CLI=$2
            shift 2
            ;;
        --vms-dir=*)
            [[ -z "$VMS_DIR_CLI" ]] || { echo "--vms-dir may be supplied once" >&2; exit 2; }
            VMS_DIR_CLI=${1#*=}
            [[ -n "$VMS_DIR_CLI" ]] || { echo "--vms-dir requires a path" >&2; exit 2; }
            shift
            ;;
        --no-start)
            START_AFTER=0
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        [1-9]|[1-9][0-9]*)
            [[ -z "$VM_ID" ]] || { echo "VM_ID may be supplied once" >&2; exit 2; }
            VM_ID=$1
            shift
            ;;
        *)
            echo "unknown arg: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

[[ -n "$VM_ID" ]] || { usage >&2; exit 2; }
if [[ -n "$VMS_DIR_CLI" ]]; then
    vm_storage_select_root "$VMS_DIR_CLI"
fi
vm_storage_init
vm_storage_require_namespace_ready "$VM_ID"

conf=$(vm_storage_config_path "$VM_ID")
disk=$(vm_storage_disk_path "$VM_ID")
[[ -r "$conf" ]] || { echo "[display-recovery] missing config: $conf" >&2; exit 1; }
[[ -f "$disk" ]] || { echo "[display-recovery] missing disk: $disk" >&2; exit 1; }
grep -Eq '^VGPU_MDEV_PROFILE=nvidia-[0-9]+$' "$conf" || {
    echo "[display-recovery] vm${VM_ID} is not a G-11 NVIDIA mdev instance" >&2
    exit 2
}

storage_args=()
[[ -z "$VMS_DIR_CLI" ]] || storage_args=( --vms-dir "$VMS_DIR_CLI" )

echo "[display-recovery] vm${VM_ID}: R535 page-alignment recovery"
echo "[display-recovery] known signature: expected visible frame length != page-rounded message length"

if pgrep -af qemu-system-x86_64 2>/dev/null | grep -F -- "$disk" >/dev/null; then
    echo "[display-recovery] requesting a normal ACPI shutdown (force kill is disabled)"
    "$here/scripts/stop-vm.sh" "$VM_ID" "${storage_args[@]}" --graceful-only
else
    echo "[display-recovery] VM is already stopped"
fi

echo "[display-recovery] applying authenticated page-safe EDID/NV_Modes and clearing stale mode caches"
if [[ -n "$VMS_DIR_CLI" ]]; then
    VM_ROOT=$VMS_DIR_CLI VMS_DIR=$VMS_DIR_CLI \
        "$here/scripts/sync-monitor-profile.sh" "$VM_ID" --force
else
    "$here/scripts/sync-monitor-profile.sh" "$VM_ID" --force
fi

if (( START_AFTER )); then
    echo "[display-recovery] cold-starting vm${VM_ID}"
    "$here/scripts/start-vm.sh" "$VM_ID" "${storage_args[@]}"
else
    echo "[display-recovery] PASS: vm${VM_ID} repaired and left stopped"
fi
