#!/usr/bin/env bash
# Guard the operator-facing balanced/ultra SDL profiles and read-only verifier.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
WRAPPER="$REPO_ROOT/deploy/scripts/g11-sdl-performance.sh"
START_VM="$REPO_ROOT/deploy/scripts/start-vm.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

bash -n "$WRAPPER" || fail "SDL performance wrapper syntax is invalid"

balanced=$("$WRAPPER" profile balanced)
grep -Fxq 'G11_SDL_PROFILE=low-latency-v1' <<<"$balanced" \
    || fail "balanced profile name changed"
grep -Fxq 'QEMU_SDL_TARGET_FPS=60' <<<"$balanced" \
    || fail "balanced target must remain 60Hz"
grep -Fxq 'QEMU_SDL_INPUT_POLL_MS=2' <<<"$balanced" \
    || fail "balanced input poll must remain 2ms"
grep -Fxq 'QEMU_SDL_CURSOR_MODE=host' <<<"$balanced" \
    || fail "balanced profile must keep the responsive host cursor"
grep -Fxq 'VGPU_CONSOLE_INTERVAL_US=8333' <<<"$balanced" \
    || fail "balanced R535 copy interval changed"
grep -Fxq 'QEMU_SERVICE_CPUS=0' <<<"$balanced" \
    || fail "balanced profile must not silently reserve another CPU"
grep -Fxq 'G11_USB_HID_LOW_LATENCY=0' <<<"$balanced" \
    || fail "balanced profile must preserve the normal HID descriptor"

ultra=$("$WRAPPER" profile ultra)
grep -Fxq 'G11_SDL_PROFILE=ultra-responsive-v1' <<<"$ultra" \
    || fail "ultra profile name changed"
grep -Fxq 'QEMU_SDL_TARGET_FPS=60' <<<"$ultra" \
    || fail "ultra response profile must stay aligned with the 60Hz display/FRL"
grep -Fxq 'QEMU_SDL_INPUT_POLL_MS=1' <<<"$ultra" \
    || fail "ultra input poll must remain 1ms"
grep -Fxq 'VGPU_CONSOLE_INTERVAL_US=8333' <<<"$ultra" \
    || fail "ultra response profile must keep the 120Hz REGION period"
grep -Fxq 'QEMU_SERVICE_CPUS=auto' <<<"$ultra" \
    || fail "ultra profile lost the optional QEMU service CPU"
grep -Fxq 'G11_USB_HID_LOW_LATENCY=1' <<<"$ultra" \
    || fail "ultra profile lost the 1ms keyboard endpoint"

experimental=$("$WRAPPER" profile experimental-120)
grep -Fxq 'G11_SDL_PROFILE=experimental-120hz-v1' <<<"$experimental" \
    || fail "experimental 120Hz profile name changed"
grep -Fxq 'QEMU_SDL_TARGET_FPS=120' <<<"$experimental" \
    || fail "experimental target must remain 120Hz"
grep -Fxq 'QEMU_SDL_INPUT_POLL_MS=1' <<<"$experimental" \
    || fail "experimental input poll must remain 1ms"
grep -Fxq 'VGPU_CONSOLE_INTERVAL_US=8333' <<<"$experimental" \
    || fail "experimental R535 interval must remain approximately 120Hz"
grep -Fxq 'QEMU_SERVICE_CPUS=auto' <<<"$experimental" \
    || fail "experimental profile lost the optional QEMU service CPU"
grep -Fxq 'G11_USB_HID_LOW_LATENCY=1' <<<"$experimental" \
    || fail "experimental profile lost the 1ms keyboard endpoint"

for profile in balanced ultra experimental-120 multi-vm; do
    profile_values=$("$WRAPPER" profile "$profile")
    grep -Fxq 'QEMU_VFIO_REGION_UPDATE_MODE=copy' <<<"$profile_values" \
        || fail "$profile does not default to full-frame copy"
    grep -Fxq 'QEMU_VFIO_REGION_IDLE_REPORT=0' <<<"$profile_values" \
        || fail "$profile silently enables pixel-idle diagnostics"
done

if "$WRAPPER" profile unknown-profile >/dev/null 2>&1; then
    fail "unknown profile was accepted"
fi
if "$WRAPPER" start 1 --ultra-responsive --experimental-120hz \
        >/dev/null 2>&1; then
    fail "two response profiles were accepted for one launch"
fi
if "$WRAPPER" start 1 --ultra-responsive --no-low-latency-input \
        >/dev/null 2>&1; then
    fail "ultra response profile accepted a contradictory HID rollback"
fi

wrapper_help=$("$WRAPPER" --help)
grep -Fq -- '--native-wayland' <<<"$wrapper_help" \
    || fail "wrapper help lost the explicit native Wayland A/B mode"
grep -Fq '完整关机' <<<"$wrapper_help" \
    || fail "native Wayland help no longer requires a full shutdown"
grep -Fq '保留 DGame SHM fallback' <<<"$wrapper_help" \
    || fail "native Wayland help hides the DGame GPU-first fallback"

if wayland_conflict=$(env \
        XDG_SESSION_TYPE=wayland XDG_RUNTIME_DIR=/tmp \
        WAYLAND_DISPLAY=wayland-test SDL_VIDEODRIVER=x11 \
        "$WRAPPER" start 1 --native-wayland 2>&1); then
    fail "native Wayland accepted an explicitly conflicting SDL driver"
fi
grep -Fq 'SDL_VIDEODRIVER=x11 冲突' <<<"$wayland_conflict" \
    || fail "conflicting SDL driver refusal was not explicit"

if wayland_gpu_conflict=$(env \
        XDG_SESSION_TYPE=wayland XDG_RUNTIME_DIR=/tmp \
        WAYLAND_DISPLAY=wayland-test SDL_VIDEODRIVER=wayland \
        "$WRAPPER" start 1 --native-wayland --dgame-preview-gpu 2>&1); then
    fail "native Wayland accepted the X11-only DGame GPU-first path"
fi
grep -Fq -- '--native-wayland 与 --dgame-preview-gpu 冲突' \
    <<<"$wayland_gpu_conflict" \
    || fail "DGame GPU-first conflict refusal was not explicit"

if fake_wayland=$(env \
        XDG_SESSION_TYPE=wayland XDG_RUNTIME_DIR=/tmp \
        WAYLAND_DISPLAY=definitely-not-a-wayland-socket \
        SDL_VIDEODRIVER=wayland \
        "$WRAPPER" start 1 --native-wayland 2>&1); then
    fail "native Wayland accepted an environment without a real socket"
fi
grep -Fq '未找到真实 Wayland socket' <<<"$fake_wayland" \
    || fail "native Wayland no-socket refusal was not explicit"

grep -Fq 'latency_args+=(--low-latency-input)' "$WRAPPER" \
    || fail "ultra profile no longer reaches the launcher HID switch"
grep -Fq 'G11_SDL_PROFILE="$SDL_PROFILE"' "$WRAPPER" \
    || fail "runtime profile marker is not inherited by QEMU"
grep -Fq 'QEMU_SDL_CURSOR_MODE="$SDL_CURSOR_MODE"' "$WRAPPER" \
    || fail "wrapper no longer pins the packaged host cursor default"
grep -Fq 'GFX_BACKEND="${GFX_BACKEND:-sdl}"' "$START_VM" \
    || fail "native launcher no longer defaults to SDL"
grep -Fq '"${forwarded[@]}" --sdl' "$WRAPPER" \
    || fail "performance wrapper no longer forces the SDL backend"
grep -Fq 'G11_SDL_WINDOW_MODE=native-wayland-v1' "$WRAPPER" \
    || fail "native Wayland window-mode marker is not atomic with launch"
grep -Fq 'SDL_VIDEODRIVER=wayland' "$WRAPPER" \
    || fail "native Wayland launch no longer pins the SDL driver"
grep -Fq 'QEMU_SDL_NATIVE_EGL=0' "$WRAPPER" \
    || fail "native Wayland launch no longer disables X11-only native EGL"
grep -Fq 'window_args+=(--no-dgame-preview-gpu)' "$WRAPPER" \
    || fail "native Wayland launch no longer selects the DGame SHM fallback"
grep -Fq 'WINDOW_CONTRACT=native-wayland-v1' "$WRAPPER" \
    || fail "verify no longer reports the native Wayland atomic contract"
grep -Fq 'read_mdev_console_intervals' "$WRAPPER" \
    || fail "verify no longer reads the applied mdev interval"
grep -Fq '" (deleted)"' "$WRAPPER" \
    || fail "verify no longer rejects a pre-rebuild running QEMU image"
grep -Fq '/sys/bus/mdev/devices/$uuid/nvidia/vgpu_params' "$WRAPPER" \
    || fail "mdev interval verifier left the bounded sysfs path"
if grep -Fq 'env_keys=(' "$WRAPPER" &&
        sed -n '/local -a env_keys=(/,/)/p' "$WRAPPER" |
            grep -Fq VGPU_CONSOLE_INTERVAL_US; then
    fail "verify regressed to requiring a consumed launcher env value"
fi

# Exercise only the read-only resource reporter with synthetic argv; no VM,
# host environment, mdev or /proc credentials are needed by this fixture.
eval "$(sed -n '/^print_running_resource_policy() {$/,/^}$/p' "$WRAPPER")"
resource_shared=$(print_running_resource_policy off auto \
    qemu-system-x86_64 -object 'memory-backend-memfd,id=preview,prealloc=on' \
    -object 'memory-backend-memfd,size=8192M,prealloc=off,id=ram0,share=on')
grep -Fq 'RESOURCE CPU_ISOLATION=off' <<<"$resource_shared" \
    || fail "resource verifier lost the running CPU isolation mode"
grep -Fq 'RESOURCE RAM_PREALLOC=off' <<<"$resource_shared" \
    || fail "resource verifier did not read prealloc from the ram0 argv"
grep -Fq 'SERVICE_CPUS_REQUESTED=auto SERVICE_CPUS_APPLIED=no' <<<"$resource_shared" \
    || fail "shared CPU mode falsely claims the service CPU request is applied"

resource_isolated=$(print_running_resource_policy required auto \
    qemu-system-x86_64 -object 'memory-backend-memfd,id=ram0,prealloc=on')
grep -Fq 'RESOURCE RAM_PREALLOC=on' <<<"$resource_isolated" \
    || fail "resource verifier did not distinguish preallocated RAM"
grep -Fq 'SERVICE_CPUS_APPLIED=unverified' <<<"$resource_isolated" \
    || fail "isolation request must not masquerade as verified thread affinity"

resource_unknown=$(print_running_resource_policy '' '' \
    qemu-system-x86_64 -object 'memory-backend-memfd,id=preview,prealloc=on')
grep -Fq 'RESOURCE CPU_ISOLATION=unknown' <<<"$resource_unknown" \
    || fail "missing process environment must not imply CPU isolation is off"
grep -Fq 'RESOURCE RAM_PREALLOC=unknown' <<<"$resource_unknown" \
    || fail "unrelated memory object must not imply guest RAM preallocation"
grep -Fq 'SERVICE_CPUS_APPLIED=unverified' <<<"$resource_unknown" \
    || fail "missing process environment must not imply applied service CPUs"

resource_no_request=$(print_running_resource_policy required 0 \
    qemu-system-x86_64 -object 'memory-backend-memfd,id=ram0,size=8192M')
grep -Fq 'RESOURCE RAM_PREALLOC=unspecified' <<<"$resource_no_request" \
    || fail "omitted RAM prealloc must be reported without guessing a value"
grep -Fq 'SERVICE_CPUS_APPLIED=not-requested' <<<"$resource_no_request" \
    || fail "zero service CPUs must be reported as not requested"

grep -Fq 'print_running_resource_policy "$cpu_isolation" "$service_cpus" "${argv[@]}"' "$WRAPPER" \
    || fail "verify no longer reports resources from the observed process"

eval "$(sed -n '/^print_running_content_policy() {$/,/^}$/p' "$WRAPPER")"
content_copy=$(print_running_content_policy copy 0)
grep -Fq 'REGION UPDATE_MODE=copy IDLE_REPORT=0' <<<"$content_copy" \
    || fail "content verifier lost the observed default REGION policy"
grep -Fq 'Content 统计整帧提交次数，不表示游戏真实 FPS' <<<"$content_copy" \
    || fail "copy mode telemetry could be mistaken for real game FPS"
content_compare=$(print_running_content_policy compare 1)
grep -Fq 'REGION UPDATE_MODE=compare IDLE_REPORT=1' <<<"$content_compare" \
    || fail "content verifier rejected the comparison diagnostics rollback"
if print_running_content_policy copy 1 >/dev/null 2>&1; then
    fail "content verifier accepted impossible copy plus idle diagnostics"
fi
content_unknown=$(print_running_content_policy '' '')
grep -Fq 'REGION UPDATE_MODE=unknown IDLE_REPORT=unknown' <<<"$content_unknown" \
    || fail "unreadable content environment was guessed instead of reported unknown"
grep -Fq 'print_running_content_policy "$region_mode" "$content_diagnostics"' "$WRAPPER" \
    || fail "verify no longer reports REGION policy from the observed process"

echo "OK: balanced/ultra SDL wrapper profiles and applied-state verification passed"
