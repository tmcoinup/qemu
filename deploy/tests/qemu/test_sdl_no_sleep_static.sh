#!/usr/bin/env bash
# Guard G-11's wrapped SDL host-display sleep policy.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../../.." && pwd)"
sdl_c="$repo_root/ui/sdl2.c"
start_vm="$repo_root/deploy/scripts/start-vm.sh"
guide="$repo_root/deploy/docs/G11-SDL-NO-SLEEP.md"
guest_power="$repo_root/deploy/guest/guest-performance/Optimize-Guest.ps1"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

sleep_policy="$(sed -n \
    '/^static void sdl2_apply_host_display_sleep_policy/,/^}/p' "$sdl_c")"
display_init="$(sed -n '/^static void sdl2_display_init/,/^}/p' "$sdl_c")"
cleanup="$(sed -n '/^static void sdl_cleanup/,/^}/p' "$sdl_c")"

grep -Fq 'QEMU_SDL_ALLOW_HOST_DISPLAY_SLEEP' <<<"$sleep_policy" \
    || fail "SDL host-display sleep compatibility switch is missing"
grep -Fq 'SDL_DisableScreenSaver();' <<<"$sleep_policy" \
    || fail "SDL no longer inhibits host screen blanking by default"
grep -Fq 'SDL_EnableScreenSaver();' <<<"$sleep_policy" \
    || fail "SDL host-display sleep compatibility mode is missing"
grep -Fq 'sdl2_apply_host_display_sleep_policy();' <<<"$display_init" \
    || fail "SDL display initialization does not apply the sleep policy"
grep -Fq 'sdl2_screen_saver_inhibited' <<<"$cleanup" \
    || fail "SDL cleanup does not track the active inhibitor"
grep -Fq 'SDL_EnableScreenSaver();' <<<"$cleanup" \
    || fail "SDL cleanup does not restore host screen-saver eligibility"

grep -Fq \
    'QEMU_SDL_ALLOW_HOST_DISPLAY_SLEEP="${QEMU_SDL_ALLOW_HOST_DISPLAY_SLEEP:-0}"' \
    "$start_vm" \
    || fail "wrapped SDL launch does not prevent host display sleep by default"
grep -Fq 'export QEMU_SDL_ALLOW_HOST_DISPLAY_SLEEP' "$start_vm" \
    || fail "wrapped SDL launch does not export the selected sleep policy"
grep -Fq 'SDL 宿主防息屏已启用' "$start_vm" \
    || fail "operator cannot see that SDL host-display inhibition is active"
grep -Fq "Name = 'VIDEOIDLE'" "$guest_power" \
    || fail "guest display idle timeout is not covered"
grep -Fq "Name = 'STANDBYIDLE'" "$guest_power" \
    || fail "guest automatic sleep timeout is not covered"
grep -Fq 'Restore-PowerSettings' "$guest_power" \
    || fail "guest idle policy cannot be rolled back exactly"

[[ -f "$guide" ]] || fail "foolproof SDL no-sleep guide is missing"

echo "OK: SDL host-display no-sleep static checks passed"
