#!/usr/bin/env bash
# Small, credential-free wrapper for the common G-11 VM path lifecycle.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'EOF'
usage:
  vmctl.sh ID [start options]                         # shortcut for start
  vmctl.sh start  ID [--vm-dir ABS|--instances-dir ABS] [options]
  vmctl.sh stop   ID [--vm-dir ABS|--instances-dir ABS] [--force]
  vmctl.sh path   ID [--vm-dir ABS|--instances-dir ABS]
  vmctl.sh status ID [--vm-dir ABS|--instances-dir ABS]
  vmctl.sh migrate [--check|--apply]

Examples:
  ./deploy/vmctl.sh path 2
  ./deploy/vmctl.sh start 2
  ./deploy/vmctl.sh start 2 --vm-dir /mnt/g11/vm2
  ./deploy/vmctl.sh stop 2 --vm-dir /mnt/g11/vm2

The wrapper stores no credentials. Supply any required secret only through an
approved runtime channel or environment variable.
EOF
}

ACTION=${1:-}
case "$ACTION" in
    [1-9]|[1-9][0-9]*)
        exec "$here/start-vm.sh" "$@"
        ;;
    start)
        shift
        exec "$here/start-vm.sh" "$@"
        ;;
    stop)
        shift
        exec "$here/stop-vm.sh" "$@"
        ;;
    path)
        shift
        [[ $# -ge 1 ]] || { usage >&2; exit 2; }
        exec "$here/start-vm.sh" "$@" --print-paths
        ;;
    status)
        shift
        [[ $# -ge 1 ]] || { usage >&2; exit 2; }
        VM_ID=$1
        [[ "$VM_ID" =~ ^[1-9][0-9]*$ ]] || { usage >&2; exit 2; }
        "$here/start-vm.sh" "$@" --print-paths
        if pgrep -f \
                "qemu-system-x86_64.*-name[[:space:]]+vm${VM_ID}([,[:space:]]|$)" \
                >/dev/null 2>&1; then
            echo "VM_STATUS=running"
        else
            echo "VM_STATUS=stopped"
        fi
        ;;
    migrate)
        shift
        exec "$here/migrate-g11-layout.sh" "$@"
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
