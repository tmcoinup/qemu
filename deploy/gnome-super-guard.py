#!/usr/bin/env python3
import base64
import os
import subprocess
import sys
import tempfile

from gi.repository import Gio, GLib


PROTECTED_MARKERS = (
    "<Super>",
    "Super_L",
    "Super_R",
    "<Mod4>",
    "<Meta>",
    "<Alt>Tab",
    "<Alt>Above_Tab",
)
RESET_KEYS = (
    ("org.gnome.mutter", "overlay-key"),
    ("org.gnome.desktop.wm.preferences", "mouse-button-modifier"),
)
RESET_SCHEMAS = (
    "org.freedesktop.ibus.general.hotkey",
    "org.freedesktop.ibus.panel.emoji",
    "org.gnome.desktop.wm.keybindings",
    "org.gnome.mutter.keybindings",
    "org.gnome.mutter.wayland.keybindings",
    "org.gnome.settings-daemon.plugins.media-keys",
    "org.gnome.shell.keybindings",
    "org.gnome.shell.extensions.dash-to-dock",
    "org.gnome.shell.extensions.tiling-assistant",
)


def available():
    return bool(os.environ.get("DBUS_SESSION_BUS_ADDRESS") or os.environ.get("XDG_RUNTIME_DIR"))


def contains_protected_shortcut(value_text):
    return any(marker in value_text for marker in PROTECTED_MARKERS)


def should_touch(schema_id, key, value_text):
    if not (schema_id.startswith("org.gnome.") or schema_id.startswith("org.freedesktop.ibus.")):
        return False
    if "text" in key.lower():
        return False
    return contains_protected_shortcut(value_text)


def disabled_variant(value):
    type_str = value.get_type_string()
    if type_str == "s":
        return GLib.Variant("s", "")
    if type_str == "as":
        return GLib.Variant("as", [])
    return None


def settings_for(schema_id):
    source = Gio.SettingsSchemaSource.get_default()
    schema = source.lookup(schema_id, True) if source else None
    if not schema:
        return None
    return Gio.Settings.new_full(schema, None, None)


def super_entries():
    try:
        out = subprocess.check_output(
            ["gsettings", "list-recursively"],
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except Exception:
        return

    seen = set()
    for line in out.splitlines():
        parts = line.split(" ", 2)
        if len(parts) != 3:
            continue
        schema_id, key, value_text = parts
        if (schema_id, key) in seen:
            continue
        if should_touch(schema_id, key, value_text):
            seen.add((schema_id, key))
            yield schema_id, key


def tame_state(state_file):
    if not available():
        return 1
    if os.path.exists(state_file):
        return 0

    directory = os.path.dirname(state_file) or "."
    fd, tmp = tempfile.mkstemp(prefix=os.path.basename(state_file) + ".tmp.", dir=directory)
    changed = []
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            for schema_id, key in super_entries():
                settings = settings_for(schema_id)
                if settings is None or not settings.is_writable(key):
                    continue
                try:
                    value = settings.get_value(key)
                except Exception:
                    continue
                value_text = value.print_(False)
                if not should_touch(schema_id, key, value_text):
                    continue
                disabled = disabled_variant(value)
                if disabled is None:
                    continue
                try:
                    if settings.set_value(key, disabled):
                        encoded = base64.b64encode(value_text.encode("utf-8")).decode("ascii")
                        fh.write(f"{schema_id}\t{key}\t{value.get_type_string()}\t{encoded}\n")
                        changed.append((settings, key, value))
                except Exception:
                    continue
        Gio.Settings.sync()
        os.replace(tmp, state_file)
        return 0
    except Exception:
        for settings, key, value in reversed(changed):
            try:
                settings.set_value(key, value)
            except Exception:
                pass
        Gio.Settings.sync()
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return 1


def restore_state(state_file):
    if not os.path.exists(state_file):
        return 0

    try:
        with open(state_file, "r", encoding="utf-8") as fh:
            lines = list(fh)
    except OSError:
        return 1

    for line in lines:
        parts = line.rstrip("\n").split("\t", 3)
        if len(parts) != 4:
            continue
        schema_id, key, type_str, encoded = parts
        settings = settings_for(schema_id)
        if settings is None:
            continue
        try:
            text = base64.b64decode(encoded.encode("ascii")).decode("utf-8")
            value = GLib.Variant.parse(GLib.VariantType.new(type_str), text, None, None)
            settings.set_value(key, value)
        except Exception:
            continue
    Gio.Settings.sync()
    try:
        os.unlink(state_file)
    except OSError:
        pass
    return 0


def restore_stale():
    uid = os.getuid()
    for name in os.listdir("/tmp"):
        if name.startswith(f"qemu-stream-client-{uid}-") and name.endswith(".gnome-super"):
            restore_state(os.path.join("/tmp", name))
    return 0


def reset_defaults():
    for schema_id, key in RESET_KEYS:
        subprocess.run(["gsettings", "reset", schema_id, key], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for schema_id in RESET_SCHEMAS:
        subprocess.run(["gsettings", "reset-recursively", schema_id], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return 0


def main(argv):
    cmd = argv[1] if len(argv) > 1 else ""
    state_file = argv[2] if len(argv) > 2 else ""
    if cmd == "tame":
        if not state_file:
            print(f"usage: {argv[0]} tame <state-file>", file=sys.stderr)
            return 2
        return tame_state(state_file)
    if cmd == "restore":
        if not state_file:
            print(f"usage: {argv[0]} restore <state-file>", file=sys.stderr)
            return 2
        return restore_state(state_file)
    if cmd == "restore-stale":
        return restore_stale()
    if cmd == "reset-defaults":
        return reset_defaults()

    print(f"usage: {argv[0]} {{tame <state-file>|restore <state-file>|restore-stale|reset-defaults}}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
