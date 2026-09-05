#!/usr/bin/env bash
# Compile the real SDL damage/update/render control flow against counted GL
# boundaries. The separate console-gl EGL regression verifies actual pixels.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../../.." && pwd)"
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

python3 - "$repo_root" "$test_dir/test.c" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
sources = {
    "policy": (root / "ui/sdl2-display-policy.c").read_text(),
    "gl": (root / "ui/sdl2-gl.c").read_text(),
}
functions = [
    ("policy", "sdl2_size_is_valid"),
    ("policy", "sdl2_surface_damage_add"),
    ("gl", "sdl2_set_scanout_mode"),
    ("gl", "sdl2_gl_surface_texture_failed"),
    ("gl", "sdl2_gl_create_surface_texture"),
    ("gl", "sdl2_gl_upload_surface_damage"),
    ("gl", "sdl2_gl_ensure_window_context"),
    ("gl", "sdl2_gl_render_surface"),
    ("gl", "sdl2_gl_update"),
    ("gl", "sdl2_gl_switch"),
    ("gl", "sdl2_gl_refresh"),
    ("gl", "sdl2_gl_redraw"),
    ("gl", "sdl2_gl_scanout_disable"),
]
definitions = []
prototypes = []
for source_name, name in functions:
    text = sources[source_name]
    match = re.search(r"^(?:static )?(?:bool|void) " + name + r"\(",
                      text, re.MULTILINE)
    if not match:
        raise SystemExit(f"Cannot extract production function: {name}")
    end = text.index("\n}", match.start()) + 2
    definition = text[match.start():end]
    prototypes.append(definition[:definition.index("\n{")] + ";")
    definitions.append(definition)

template = (root / "deploy/tests/qemu/fixtures/sdl-gl-damage.c").read_text()
template = template.replace("/* PRODUCTION PROTOTYPES */", "\n".join(prototypes))
template = template.replace("/* PRODUCTION DEFINITIONS */", "\n\n".join(definitions))
pathlib.Path(sys.argv[2]).write_text(template)
PY

"${CC:-cc}" -std=gnu11 -O2 -Wall -Werror "$test_dir/test.c" -o "$test_dir/test"
"$test_dir/test"
