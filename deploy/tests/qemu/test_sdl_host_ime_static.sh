#!/usr/bin/env bash
# Guard raw SDL keyboard delivery against host IBus/Fcitx composition.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../../.." && pwd)"
sdl_c="$repo_root/ui/sdl2.c"
event_c="$repo_root/ui/sdl2-event.c"
event_test="$repo_root/tests/unit/test-sdl2-event.c"
start_vm="$repo_root/deploy/scripts/start-vm.sh"
guide="$repo_root/deploy/docs/G11-SDL-HOST-IME.md"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

display_init="$(sed -n '/^static void sdl2_display_init/,/^}/p' "$sdl_c")"
stop_line="$(grep -n -m1 'sdl2_disable_host_text_input();' <<<"$display_init" |
    cut -d: -f1)"
init_line="$(grep -n -m1 'if (SDL_Init(SDL_INIT_VIDEO))' <<<"$display_init" |
    cut -d: -f1)"

[[ -n "$stop_line" && -n "$init_line" && "$stop_line" -gt "$init_line" ]] \
    || fail "SDL host text input is not disabled immediately after video init"
grep -Fq 'SDL_StopTextInput();' "$event_c" \
    || fail "SDL text-input shutdown helper is missing"
if grep -Fq 'SDL_StartTextInput' "$repo_root"/ui/sdl2*.c; then
    fail "SDL production code can re-enable host text composition"
fi
grep -Fq '/sdl2-event/host-text-input-disabled' "$event_test" \
    || fail "compiled SDL text-input regression is missing"

grep -Fq 'QEMU_SDL_DISABLE_IBUS="${QEMU_SDL_DISABLE_IBUS:-1}"' "$start_vm" \
    || fail "SDL launcher isolation is not enabled by default"
grep -Fq 'if [[ "$LOCAL_INPUT_BACKEND" == sdl ]]' "$start_vm" \
    || fail "IME isolation does not cover every wrapped SDL mode"
for contract in \
        'export XMODIFIERS=@im=none' \
        'export SDL_IM_MODULE=none' \
        'export IBUS_ADDRESS=/nonexistent'; do
    grep -Fq "$contract" "$start_vm" \
        || fail "launcher IME isolation is incomplete: $contract"
done

[[ -f "$guide" ]] || fail "foolproof SDL host-IME guide is missing"

echo "OK: SDL host IME isolation static checks passed"
