#!/usr/bin/env bash

# Temporarily disable GNOME/IBus shortcuts that steal VM input, such as
# Super/Meta and Alt+Tab. Restore as soon as the mouse leaves the viewer
# or the viewer exits.

declare -gA GNOME_SUPER_SAVED=()
declare -gi GNOME_SUPER_RESTORE_COUNT=0
declare -gi GNOME_SUPER_TAMED=0

gnome_super_shortcuts_available() {
    command -v gsettings >/dev/null 2>&1 || return 1
    [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}${XDG_RUNTIME_DIR:-}" ]]
}

gnome_super_shortcuts_is_gnome() {
    local desktop="${XDG_CURRENT_DESKTOP:-} ${DESKTOP_SESSION:-}"
    desktop=${desktop,,}
    [[ "$desktop" == *gnome* || "$desktop" == *ubuntu* ]]
}

_gnome_super_value_contains_protected_shortcut() {
    case "$1" in
        *"<Super>"*|*"Super_L"*|*"Super_R"*|*"<Mod4>"*|*"<Meta>"*|*"<Alt>Tab"*|*"<Alt>Above_Tab"*) return 0 ;;
        *) return 1 ;;
    esac
}

_gnome_super_should_touch() {
    local schema=$1 key=$2 value=$3

    case "$schema" in
        org.gnome.*|org.freedesktop.ibus.*) ;;
        *) return 1 ;;
    esac
    case "$key" in
        *text*|*Text*) return 1 ;;
    esac
    _gnome_super_value_contains_protected_shortcut "$value"
}

_gnome_super_disabled_value() {
    local value=$1

    case "$value" in
        "'"*) echo "''" ;;
        "["*) echo "[]" ;;
        @a*) echo "[]" ;;
        *) return 1 ;;
    esac
}

gnome_super_shortcuts_tame() {
    gnome_super_shortcuts_available || return 1

    local line schema rest key value disabled writable entry
    GNOME_SUPER_RESTORE_COUNT=0
    GNOME_SUPER_TAMED=1
    GNOME_SUPER_SAVED=()

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        schema=${line%% *}
        rest=${line#* }
        [[ "$rest" != "$line" ]] || continue
        key=${rest%% *}
        value=${rest#* }
        [[ "$value" != "$rest" ]] || continue

        _gnome_super_should_touch "$schema" "$key" "$value" || continue
        disabled=$(_gnome_super_disabled_value "$value") || continue
        writable=$(gsettings writable "$schema" "$key" 2>/dev/null || true)
        [[ "$writable" == "true" ]] || continue

        entry="$schema $key"
        GNOME_SUPER_SAVED["$entry"]="$value"
        if gsettings set "$schema" "$key" "$disabled" 2>/dev/null; then
            GNOME_SUPER_RESTORE_COUNT+=1
        else
            unset 'GNOME_SUPER_SAVED[$entry]'
        fi
    done < <(gsettings list-recursively 2>/dev/null || true)

    return 0
}

gnome_super_shortcuts_restore() {
    [[ ${GNOME_SUPER_TAMED:-0} -eq 1 ]] || return 0

    local entry schema key
    for entry in "${!GNOME_SUPER_SAVED[@]}"; do
        schema=${entry%% *}
        key=${entry#* }
        gsettings set "$schema" "$key" "${GNOME_SUPER_SAVED[$entry]}" 2>/dev/null || true
    done
    GNOME_SUPER_SAVED=()
    GNOME_SUPER_RESTORE_COUNT=0
    GNOME_SUPER_TAMED=0
}

gnome_super_shortcuts_candidate_entries() {
    local i

    cat <<'EOF'
org.gnome.mutter overlay-key
org.gnome.mutter.keybindings cancel-input-capture
org.gnome.mutter.keybindings switch-monitor
org.gnome.mutter.wayland.keybindings restore-shortcuts
org.gnome.desktop.wm.preferences mouse-button-modifier
org.gnome.desktop.wm.keybindings minimize
org.gnome.desktop.wm.keybindings show-desktop
org.gnome.desktop.wm.keybindings switch-applications
org.gnome.desktop.wm.keybindings switch-applications-backward
org.gnome.desktop.wm.keybindings switch-group
org.gnome.desktop.wm.keybindings switch-group-backward
org.gnome.desktop.wm.keybindings switch-panels
org.gnome.desktop.wm.keybindings switch-panels-backward
org.gnome.desktop.wm.keybindings switch-windows
org.gnome.desktop.wm.keybindings switch-windows-backward
org.gnome.desktop.wm.keybindings switch-input-source
org.gnome.desktop.wm.keybindings switch-input-source-backward
org.gnome.desktop.wm.keybindings switch-to-workspace-1
org.gnome.desktop.wm.keybindings switch-to-workspace-last
org.gnome.desktop.wm.keybindings switch-to-workspace-left
org.gnome.desktop.wm.keybindings switch-to-workspace-right
org.gnome.desktop.wm.keybindings move-to-workspace-1
org.gnome.desktop.wm.keybindings move-to-workspace-last
org.gnome.desktop.wm.keybindings move-to-workspace-left
org.gnome.desktop.wm.keybindings move-to-workspace-right
org.gnome.desktop.wm.keybindings move-to-monitor-down
org.gnome.desktop.wm.keybindings move-to-monitor-left
org.gnome.desktop.wm.keybindings move-to-monitor-right
org.gnome.desktop.wm.keybindings move-to-monitor-up
org.freedesktop.ibus.general.hotkey triggers
org.freedesktop.ibus.panel.emoji hotkey
org.gnome.settings-daemon.plugins.media-keys help
org.gnome.settings-daemon.plugins.media-keys magnifier
org.gnome.settings-daemon.plugins.media-keys magnifier-zoom-in
org.gnome.settings-daemon.plugins.media-keys magnifier-zoom-out
org.gnome.settings-daemon.plugins.media-keys rotate-video-lock-static
org.gnome.settings-daemon.plugins.media-keys screenreader
org.gnome.settings-daemon.plugins.media-keys touchpad-toggle-static
org.gnome.shell.keybindings focus-active-notification
org.gnome.shell.extensions.dash-to-dock shortcut
org.gnome.shell.extensions.tiling-assistant restore-window
org.gnome.shell.extensions.tiling-assistant tile-bottom-half
org.gnome.shell.extensions.tiling-assistant tile-bottomleft-quarter
org.gnome.shell.extensions.tiling-assistant tile-bottomright-quarter
org.gnome.shell.extensions.tiling-assistant tile-left-half
org.gnome.shell.extensions.tiling-assistant tile-maximize
org.gnome.shell.extensions.tiling-assistant tile-right-half
org.gnome.shell.extensions.tiling-assistant tile-top-half
org.gnome.shell.extensions.tiling-assistant tile-topleft-quarter
org.gnome.shell.extensions.tiling-assistant tile-topright-quarter
EOF
    for i in 1 2 3 4 5 6 7 8 9 10; do
        printf 'org.gnome.shell.extensions.dash-to-dock app-hotkey-%s\n' "$i"
        printf 'org.gnome.shell.extensions.dash-to-dock app-shift-hotkey-%s\n' "$i"
        printf 'org.gnome.shell.extensions.dash-to-dock app-ctrl-hotkey-%s\n' "$i"
        printf 'org.gnome.shell.keybindings open-new-window-application-%s\n' "$i"
    done
}

gnome_super_shortcuts_tame_state() {
    local state_file=$1 tmp line schema key value disabled writable encoded
    gnome_super_shortcuts_available || return 1
    [[ -f "$state_file" ]] && return 0

    tmp=$(mktemp "${state_file}.tmp.XXXXXX") || return 1
    while read -r schema key; do
        [[ -n "${schema:-}" && -n "${key:-}" ]] || continue
        value=$(gsettings get "$schema" "$key" 2>/dev/null || true)
        [[ -n "$value" ]] || continue

        _gnome_super_should_touch "$schema" "$key" "$value" || continue
        disabled=$(_gnome_super_disabled_value "$value") || continue
        writable=$(gsettings writable "$schema" "$key" 2>/dev/null || true)
        [[ "$writable" == "true" ]] || continue

        encoded=$(printf '%s' "$value" | base64 -w0)
        if gsettings set "$schema" "$key" "$disabled" 2>/dev/null; then
            printf '%s\t%s\t%s\n' "$schema" "$key" "$encoded" >>"$tmp"
        fi
    done < <(gnome_super_shortcuts_candidate_entries)

    mv -f "$tmp" "$state_file"
}

gnome_super_shortcuts_restore_state() {
    local state_file=$1 line schema key encoded value
    [[ -f "$state_file" ]] || return 0

    while IFS=$'\t' read -r schema key encoded; do
        [[ -n "${schema:-}" && -n "${key:-}" && -n "${encoded:-}" ]] || continue
        value=$(printf '%s' "$encoded" | base64 -d 2>/dev/null || true)
        [[ -n "$value" ]] || continue
        gsettings set "$schema" "$key" "$value" 2>/dev/null || true
    done <"$state_file"
    rm -f "$state_file"
}

gnome_super_shortcuts_restore_stale() {
    local state_file
    for state_file in /tmp/qemu-stream-client-"$(id -u)"-*.gnome-super; do
        [[ -e "$state_file" ]] || continue
        gnome_super_shortcuts_restore_state "$state_file"
    done
}

gnome_super_shortcuts_reset_defaults() {
    local entry schema key

    for entry in \
        'org.gnome.mutter overlay-key' \
        'org.gnome.desktop.wm.preferences mouse-button-modifier'
    do
        schema=${entry% *}
        key=${entry##* }
        gsettings reset "$schema" "$key" 2>/dev/null || true
    done

    for schema in \
        org.freedesktop.ibus.general.hotkey \
        org.freedesktop.ibus.panel.emoji \
        org.gnome.desktop.wm.keybindings \
        org.gnome.mutter.keybindings \
        org.gnome.mutter.wayland.keybindings \
        org.gnome.settings-daemon.plugins.media-keys \
        org.gnome.shell.keybindings \
        org.gnome.shell.extensions.dash-to-dock \
        org.gnome.shell.extensions.tiling-assistant
    do
        gsettings reset-recursively "$schema" 2>/dev/null || true
    done
}
