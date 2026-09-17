#!/usr/bin/env bash
# Credential-free, read-only game-exit diagnostics for G-11.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
usage() {
    cat <<'EOF'
usage:
  ./deploy/scripts/game-diagnostics.sh ID watch [--seconds 86400] [--output NEW.jsonl]
  ./deploy/scripts/game-diagnostics.sh ID usb-mount [--replace] [storage selector]
  ./deploy/scripts/game-diagnostics.sh ID status|eject [storage selector]

watch records future QMP reset/pause/shutdown events and status every 30 seconds.
Default duration is 24 hours. Ctrl+C only stops this observer. It never changes
VM state. Without --output it creates a private report directory under /tmp.
usb-mount exposes the Windows audit scripts as a read-only USB drive (G11EXIT).
Double-click 01-Audit.cmd inside Windows to create a local desktop report.
Storage selectors are --vms-dir ABS, --vm-dir ABS or --instances-dir ABS.
EOF
}
if [[ ${1:-} == -h || ${1:-} == --help ]]; then usage; exit 0; fi
id=${1:-}
action=${2:-}
[[ "$id" =~ ^[1-9][0-9]*$ && ${#id} -le 10 && -n "$action" ]] || { usage >&2; exit 2; }
((10#$id <= 2147483647)) || { echo 'VM ID out of range' >&2; exit 2; }
shift 2
case "$action" in
    watch) exec python3 "$here/host/watch-g11-lifecycle.py" --vm "$id" "$@" ;;
    usb-mount) exec "$here/scripts/usb-directory.sh" "$id" mount "$here/guest/game-diagnostics" --label G11EXIT "$@" ;;
    status|eject) exec "$here/scripts/usb-directory.sh" "$id" "$action" "$@" ;;
    *) usage >&2; exit 2 ;;
esac
