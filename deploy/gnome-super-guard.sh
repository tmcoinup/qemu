#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -x "$here/gnome-super-guard.py" ]]; then
    exec python3 "$here/gnome-super-guard.py" "$@"
fi

# shellcheck source=lib/gnome-shortcuts.sh
source "$here/lib/gnome-shortcuts.sh"

cmd=${1:-}
state_file=${2:-}

case "$cmd" in
    tame)
        [[ -n "$state_file" ]] || { echo "usage: $0 tame <state-file>" >&2; exit 2; }
        gnome_super_shortcuts_tame_state "$state_file"
        ;;
    restore)
        [[ -n "$state_file" ]] || { echo "usage: $0 restore <state-file>" >&2; exit 2; }
        gnome_super_shortcuts_restore_state "$state_file"
        ;;
    restore-stale)
        gnome_super_shortcuts_restore_stale
        ;;
    reset-defaults)
        gnome_super_shortcuts_reset_defaults
        ;;
    *)
        echo "usage: $0 {tame <state-file>|restore <state-file>|restore-stale|reset-defaults}" >&2
        exit 2
        ;;
esac
