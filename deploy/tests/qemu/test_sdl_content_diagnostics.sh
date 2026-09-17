#!/usr/bin/env bash
# Exercise the operator wrapper with an isolated launcher and binary fixture.
# No VM, mdev, host settings or credentials are accessed.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../../.." && pwd)"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

tmp_dir="$(mktemp -d /tmp/g11-content-diagnostics-test.XXXXXX)"
trap 'rm -rf -- "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/deploy/scripts" "$tmp_dir/ui" "$tmp_dir/bin"
wrapper="$tmp_dir/deploy/scripts/g11-sdl-performance.sh"
cp "$repo_root/deploy/scripts/g11-sdl-performance.sh" "$wrapper"
ln -s "$repo_root/ui/sdl2.c" "$tmp_dir/ui/sdl2.c"

cat >"$tmp_dir/deploy/scripts/start-vm.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# VGPU_CONSOLE_INTERVAL_US is consumed by the real launcher.
{
    printf 'QEMU_VFIO_REGION_IDLE_REPORT=%s\n' "${QEMU_VFIO_REGION_IDLE_REPORT:-<unset>}"
    printf 'QEMU_VFIO_REGION_UPDATE_MODE=%s\n' "${QEMU_VFIO_REGION_UPDATE_MODE:-<unset>}"
    printf 'G11_SDL_PROFILE=%s\n' "${G11_SDL_PROFILE:-<unset>}"
    printf 'QEMU_SERVICE_CPUS=%s\n' "${QEMU_SERVICE_CPUS:-<unset>}"
    printf 'QEMU_SDL_BACKGROUND_FPS=%s\n' "${QEMU_SDL_BACKGROUND_FPS:-<unset>}"
    printf 'VGPU_CONSOLE_INTERVAL_US=%s\n' "${VGPU_CONSOLE_INTERVAL_US:-<unset>}"
    printf 'ARG=%s\n' "$@"
} >"$G11_SDL_TEST_CAPTURE"
EOF

# This older fixture supports the profiles, but has no REGION mode controls.
cat >"$tmp_dir/bin/qemu-system-x86_64" <<'EOF'
#!/usr/bin/env bash
# QEMU_SDL_TARGET_FPS QEMU_SDL_INPUT_POLL_MS QEMU_SDL_PRESENT_MODE
# QEMU_SDL_TITLE_FPS QEMU_SDL_CURSOR_MODE QEMU_SDL_ALLOW_HOST_DISPLAY_SLEEP
# QEMU_SDL_BACKGROUND_FPS
[[ "$*" == '-display help' ]] || exit 2
echo sdl
EOF
chmod +x "$wrapper" "$tmp_dir/deploy/scripts/start-vm.sh" \
    "$tmp_dir/bin/qemu-system-x86_64"
export QEMU_BIN="$tmp_dir/bin/qemu-system-x86_64"
export G11_SDL_TEST_CAPTURE="$tmp_dir/launch.txt"

profile=$("$wrapper" profile)
grep -Fxq 'QEMU_VFIO_REGION_IDLE_REPORT=0' <<<"$profile" \
    || fail "profile does not report diagnostics disabled by default"
grep -Fxq 'QEMU_VFIO_REGION_UPDATE_MODE=copy' <<<"$profile" \
    || fail "profile does not use full-frame REGION copy by default"
wrapper_help=$("$wrapper" --help)
grep -Fq -- '--content-diagnostics' <<<"$wrapper_help" \
    || fail "wrapper help does not explain the diagnostics switch"
grep -Fq -- '--game-content-copy' <<<"$wrapper_help" \
    || fail "wrapper help does not explain the game copy switch"
grep -Fq -- '--game-content-compare' <<<"$wrapper_help" \
    || fail "wrapper help does not explain how to restore pixel comparison"

# Older builds must fail before launch when the default copy is unavailable;
# an explicit compare rollback remains usable with those builds.
if "$wrapper" start 1 >"$tmp_dir/old-default-binary.log" 2>&1; then
    fail "default copy accepted an older binary without mode control"
fi
[[ ! -e "$G11_SDL_TEST_CAPTURE" ]] \
    || fail "the launcher ran despite unsupported default copy mode"
grep -Fq 'QEMU 不支持 --game-content-copy' "$tmp_dir/old-default-binary.log" \
    || fail "unsupported default copy did not produce an actionable refusal"
"$wrapper" start 1 --game-content-compare >"$tmp_dir/old-compare.log" 2>&1 \
    || fail "explicit comparison should remain compatible with the older binary"
grep -Fxq 'QEMU_VFIO_REGION_IDLE_REPORT=0' "$G11_SDL_TEST_CAPTURE" \
    || fail "comparison rollback unexpectedly enables idle diagnostics"
grep -Fxq 'QEMU_VFIO_REGION_UPDATE_MODE=compare' "$G11_SDL_TEST_CAPTURE" \
    || fail "comparison rollback did not select pixel comparison"
expected_args=$'ARG=1\nARG=--sdl'
actual_args=$(grep '^ARG=' "$G11_SDL_TEST_CAPTURE")
[[ "$actual_args" == "$expected_args" ]] \
    || fail "comparison rollback was forwarded to the launcher as an argument"

rm "$G11_SDL_TEST_CAPTURE"
if "$wrapper" start 1 --content-diagnostics >"$tmp_dir/old-binary.log" 2>&1; then
    fail "explicit diagnostics accepted an older binary without the reporter"
fi
[[ ! -e "$G11_SDL_TEST_CAPTURE" ]] \
    || fail "the launcher ran despite unsupported diagnostics"
grep -Fq 'QEMU 不支持 --content-diagnostics' "$tmp_dir/old-binary.log" \
    || fail "unsupported diagnostics did not produce an actionable refusal"
if "$wrapper" start 1 --game-content-copy >"$tmp_dir/old-copy-binary.log" 2>&1; then
    fail "explicit copy accepted an older binary without mode control"
fi
[[ ! -e "$G11_SDL_TEST_CAPTURE" ]] \
    || fail "the launcher ran despite unsupported copy mode"
grep -Fq 'QEMU 不支持 --game-content-copy' "$tmp_dir/old-copy-binary.log" \
    || fail "unsupported copy mode did not produce an actionable refusal"

# Add the feature markers to exercise a compatible QEMU build.
printf '\n# QEMU_VFIO_REGION_IDLE_REPORT QEMU_VFIO_REGION_UPDATE_MODE\n' >>"$QEMU_BIN"
# An inherited debug environment must not silently change an ordinary start.
env QEMU_VFIO_REGION_IDLE_REPORT=1 QEMU_VFIO_REGION_UPDATE_MODE=compare \
    "$wrapper" start 1 >"$tmp_dir/default.log" 2>&1 \
    || fail "ordinary start did not launch with a supported binary"
for expected in QEMU_VFIO_REGION_IDLE_REPORT=0 QEMU_VFIO_REGION_UPDATE_MODE=copy \
        G11_SDL_PROFILE=low-latency-v1 QEMU_SERVICE_CPUS=0 \
        QEMU_SDL_BACKGROUND_FPS=0 VGPU_CONSOLE_INTERVAL_US=8333; do
    grep -Fxq "$expected" "$G11_SDL_TEST_CAPTURE" \
        || fail "ordinary start did not preserve its default configuration: $expected"
done
expected_args=$'ARG=1\nARG=--sdl'
actual_args=$(grep '^ARG=' "$G11_SDL_TEST_CAPTURE")
[[ "$actual_args" == "$expected_args" ]] \
    || fail "ordinary start must allow the launcher to apply its resource defaults"
grep -Fq 'binary QEMU_VFIO_REGION_UPDATE_MODE=yes' "$tmp_dir/default.log" \
    || fail "default copy support was not audited before launch"

# Existing explicit CPU and memory choices must pass through unchanged.
"$wrapper" start 2 --cpu-isolate=true --memory-prealloc=true \
    >"$tmp_dir/resource-override.log" 2>&1 \
    || fail "explicit resource overrides were refused"
expected_args=$'ARG=2\nARG=--cpu-isolate=true\nARG=--memory-prealloc=true\nARG=--sdl'
actual_args=$(grep '^ARG=' "$G11_SDL_TEST_CAPTURE")
[[ "$actual_args" == "$expected_args" ]] \
    || fail "explicit resource overrides did not reach the launcher unchanged"

"$wrapper" start 7 --content-diagnostics --ultra-responsive --svc-cpus 2 \
    >"$tmp_dir/ultra.log" 2>&1 || fail "diagnostics did not launch with a supported binary"
grep -Fxq 'QEMU_VFIO_REGION_IDLE_REPORT=1' "$G11_SDL_TEST_CAPTURE" \
    || fail "explicit diagnostics did not reach the launcher environment"
grep -Fxq 'QEMU_VFIO_REGION_UPDATE_MODE=compare' "$G11_SDL_TEST_CAPTURE" \
    || fail "diagnostics must retain REGION pixel comparison"
grep -Fxq 'G11_SDL_PROFILE=ultra-responsive-v1' "$G11_SDL_TEST_CAPTURE" \
    || fail "diagnostics changed the selected response profile"
grep -Fxq 'QEMU_SERVICE_CPUS=auto' "$G11_SDL_TEST_CAPTURE" \
    || fail "diagnostics changed the ultra service CPU policy"
expected_args=$'ARG=7\nARG=--low-latency-input\nARG=--svc-cpus\nARG=2\nARG=--sdl'
actual_args=$(grep '^ARG=' "$G11_SDL_TEST_CAPTURE")
[[ "$actual_args" == "$expected_args" ]] \
    || fail "diagnostics was forwarded as a launcher argument or disturbed other arguments"
grep -Fq 'binary QEMU_VFIO_REGION_IDLE_REPORT=yes' "$tmp_dir/ultra.log" \
    || fail "diagnostics support was not audited before launch"

"$wrapper" start 8 --multi-vm --content-diagnostics >"$tmp_dir/multi-vm.log" 2>&1 \
    || fail "diagnostics did not compose with the multi-VM profile"
for expected in QEMU_VFIO_REGION_IDLE_REPORT=1 QEMU_VFIO_REGION_UPDATE_MODE=compare \
        G11_SDL_PROFILE=multi-vm-v1 \
        QEMU_SERVICE_CPUS=0 QEMU_SDL_BACKGROUND_FPS=15 VGPU_CONSOLE_INTERVAL_US=16667; do
    grep -Fxq "$expected" "$G11_SDL_TEST_CAPTURE" \
        || fail "diagnostics disturbed multi-VM configuration: $expected"
done
expected_args=$'ARG=8\nARG=--shared-performance\nARG=--dgame-preview-rate\nARG=15\nARG=--sdl'
actual_args=$(grep '^ARG=' "$G11_SDL_TEST_CAPTURE")
[[ "$actual_args" == "$expected_args" ]] \
    || fail "diagnostics disturbed the multi-VM launcher arguments"

"$wrapper" start 9 --game-content-copy --svc-cpus 2 >"$tmp_dir/copy.log" 2>&1 \
    || fail "game copy did not launch with a supported binary"
for expected in QEMU_VFIO_REGION_IDLE_REPORT=0 QEMU_VFIO_REGION_UPDATE_MODE=copy \
        G11_SDL_PROFILE=low-latency-v1 QEMU_SERVICE_CPUS=0 \
        QEMU_SDL_BACKGROUND_FPS=0 VGPU_CONSOLE_INTERVAL_US=8333; do
    grep -Fxq "$expected" "$G11_SDL_TEST_CAPTURE" \
        || fail "game copy did not preserve its expected configuration: $expected"
done
expected_args=$'ARG=9\nARG=--svc-cpus\nARG=2\nARG=--sdl'
actual_args=$(grep '^ARG=' "$G11_SDL_TEST_CAPTURE")
[[ "$actual_args" == "$expected_args" ]] \
    || fail "game copy was forwarded as a launcher argument or disturbed other arguments"
grep -Fq 'binary QEMU_VFIO_REGION_UPDATE_MODE=yes' "$tmp_dir/copy.log" \
    || fail "game copy support was not audited before launch"

# Compare and diagnostics compose regardless of argument order.
for first in --game-content-compare --content-diagnostics; do
    second=--content-diagnostics
    [[ "$first" != --content-diagnostics ]] || second=--game-content-compare
    "$wrapper" start 10 "$first" "$second" >"$tmp_dir/compare-diagnostics.log" 2>&1 \
        || fail "comparison and diagnostics could not be combined: $first $second"
    grep -Fxq 'QEMU_VFIO_REGION_UPDATE_MODE=compare' "$G11_SDL_TEST_CAPTURE" \
        || fail "comparison and diagnostics did not select comparison mode"
    grep -Fxq 'QEMU_VFIO_REGION_IDLE_REPORT=1' "$G11_SDL_TEST_CAPTURE" \
        || fail "comparison and diagnostics did not enable idle reports"
done

rm "$G11_SDL_TEST_CAPTURE"
for flag in --content-diagnostics --game-content-copy --game-content-compare; do
    if "$wrapper" start 1 "$flag" "$flag" >"$tmp_dir/duplicate.log" 2>&1; then
        fail "a duplicate switch was accepted: $flag"
    fi
    [[ ! -e "$G11_SDL_TEST_CAPTURE" ]] \
        || fail "the launcher ran after a duplicate switch: $flag"
done

for flag in --content-diagnostics --game-content-copy; do
    other=--game-content-copy
    [[ "$flag" != --game-content-copy ]] || other=--content-diagnostics
    if "$wrapper" start 1 "$flag" "$other" >"$tmp_dir/conflict.log" 2>&1; then
        fail "conflicting copy and diagnostics switches were accepted: $flag $other"
    fi
    [[ ! -e "$G11_SDL_TEST_CAPTURE" ]] \
        || fail "the launcher ran with conflicting copy and diagnostics switches"
    grep -Fq '复制模式不比较像素，无法进行静止诊断' "$tmp_dir/conflict.log" \
        || fail "the copy/diagnostics conflict did not explain the missing comparison"
done

for flag in --game-content-copy --game-content-compare; do
    other=--game-content-copy
    [[ "$flag" != --game-content-copy ]] || other=--game-content-compare
    if "$wrapper" start 1 "$flag" "$other" >"$tmp_dir/mode-conflict.log" 2>&1; then
        fail "contradictory REGION update modes were accepted: $flag $other"
    fi
    [[ ! -e "$G11_SDL_TEST_CAPTURE" ]] \
        || fail "the launcher ran with contradictory REGION update modes"
done

echo "OK: SDL defaults to audited full-frame copy, with explicit comparison and idle diagnostics"
