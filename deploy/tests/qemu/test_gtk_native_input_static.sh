#!/usr/bin/env bash
# Guard GTK keyboard capture for install/rescue/native windows.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
GTK_C="$REPO_ROOT/ui/gtk.c"
GTK_H="$REPO_ROOT/include/ui/gtk.h"
START_VM="$REPO_ROOT/deploy/scripts/start-vm.sh"
SHORTCUTS="$REPO_ROOT/deploy/lib/gnome-shortcuts.sh"
GUARD_PY="$REPO_ROOT/deploy/gnome-super-guard.py"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

require_text() {
    local needle=$1 file=$2

    grep -F -- "$needle" "$file" >/dev/null \
        || fail "missing '$needle' in ${file#$REPO_ROOT/}"
}

require_function_text() {
    local function_name=$1 needle=$2

    awk -v function_name="$function_name" -v needle="$needle" '
        index($0, "static " ) && index($0, function_name "(") {
            saw_signature = 1
        }
        saw_signature && $0 ~ /{/ {
            in_func = 1
            depth = 1
            saw_signature = 0
            next
        }
        in_func {
            if (index($0, needle)) {
                found = 1
            }
            opens = gsub(/{/, "{")
            closes = gsub(/}/, "}")
            depth += opens - closes
            if (depth == 0) {
                exit found ? 0 : 1
            }
        }
        END {
            if (!in_func || !found) {
                exit 1
            }
        }
    ' "$GTK_C" || fail "$function_name lost '$needle'"
}

require_text "bool has_input_focus;" "$GTK_H"
require_text "bool has_mouse_focus;" "$GTK_H"
require_text "_XWAYLAND_MAY_GRAB_KEYBOARD" "$GTK_C"
require_text "SubstructureNotifyMask | SubstructureRedirectMask" "$GTK_C"

# V-11's XWayland permission request must precede GTK's real seat grab.
awk '
    /static void gd_grab_update/ { in_func = 1 }
    in_func && /gd_x11_request_keyboard_grab_permission/ { permission = NR }
    in_func && /gdk_seat_grab/ { grab = NR }
    in_func && /^}/ { exit !(permission && grab && permission < grab) }
    END { if (!in_func || !permission || !grab) exit 1 }
' "$GTK_C" || fail "XWayland permission must precede gdk_seat_grab"

require_function_text gd_enter_event "vc->has_mouse_focus = true;"
require_function_text gd_enter_event 'gd_grab_keyboard(vc, "grab-on-hover")'
require_function_text gd_leave_event "vc->has_mouse_focus = false;"
require_function_text gd_leave_event "qkbd_state_lift_all_keys(vc->gfx.kbd);"
require_function_text gd_leave_event "gd_ungrab_keyboard(s);"
require_function_text gd_focus_in_event "vc->has_input_focus = true;"
require_function_text gd_focus_out_event "vc->has_input_focus = false;"
require_function_text gd_focus_out_event "gd_ungrab_keyboard(s);"
require_function_text gd_button_event "gtk_widget_grab_focus(widget);"
require_text "gd_gnome_guard_update(vc);" "$GTK_C"
require_text 'gd_env_enabled("QEMU_GTK_TAME_GNOME")' "$GTK_C"
require_text 'qemu-gtk-%u-%ld.gnome-super' "$GTK_C"
require_text 'atexit(gd_gnome_guard_cleanup);' "$GTK_C"

require_text "export QEMU_GTK_TAME_GNOME=1" "$START_VM"
require_text "export QEMU_SDL_TAME_GNOME=1" "$START_VM"
require_text "gtk,gl=off,grab-on-hover=on" "$START_VM"
require_text "gtk,gl=on,show-cursor=on,grab-on-hover=on" "$START_VM"

# Native Wayland falls back to a reversible GNOME binding guard.  It must
# cover the host's default Ctrl+Alt+Delete logout key as well as stale GTK
# state left by a killed QEMU process.
require_text '<Control><Alt>Delete' "$SHORTCUTS"
require_text 'org.gnome.settings-daemon.plugins.media-keys logout' "$SHORTCUTS"
require_text 'qemu-gtk-' "$SHORTCUTS"
require_text '"<Control><Alt>Delete"' "$GUARD_PY"
require_text 'name.startswith(f"qemu-gtk-{uid}-")' "$GUARD_PY"

# Predicate-only check: do not change the live desktop settings in this test.
bash -c '
    source "$1"
    _gnome_super_value_contains_protected_shortcut \
        "['\''<Control><Alt>Delete'\'']"
' _ "$SHORTCUTS" || fail "Ctrl+Alt+Delete is not protected"

echo "OK: GTK install/native keyboard capture static checks passed"
