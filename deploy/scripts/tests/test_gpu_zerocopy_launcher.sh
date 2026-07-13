#!/usr/bin/env bash
# 验证 Linux 启动器的 GPU handoff 默认策略；全程 DRY_RUN，不启动 guest。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
START_VM="$REPO_ROOT/deploy/scripts/start-vm.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

run_dry() {
    local instance="$1"
    local out="$2"
    shift 2

    # 中文注释：关闭与本测试无关的宿主能力检查和调优，确保用例只验证 argv
    # 组装。DISPLAY 显式给出，避免非交互测试环境触发“无 DISPLAY 自动关 SDL”。
    DISPLAY=:0 DRY_RUN=1 TPM=0 HOST_TUNE=0 CPU_ISOLATE=0 \
        QEMU_CAP_CHECK=0 INSTANCE="$instance" \
        "$START_VM" --no-bridge "$@" > "$out"
}

vga_arg() {
    local out="$1"
    grep -E '^virtio-vga(-gl)?,' "$out" | head -n 1
}

test_default_sdl_prefers_gpu_handoff() {
    local out="$1"
    local vga

    run_dry 9911 "$out"
    grep -Fx -- 'sdl,gl=on,show-cursor=off' "$out" >/dev/null \
        || fail "default SDL must keep QEMU SDL/GL"
    vga="$(vga_arg "$out")"
    [[ "$vga" == virtio-vga-gl,* ]] \
        || fail "default SDL must use virtio-vga-gl"
    [[ "$vga" == *",blob=true,"* && "$vga" == *",hostmem=256M"* ]] \
        || fail "default SDL must enable blob/hostmem capability preference"
    grep -F -- 'configured=${FB_SHM_RATE} Hz' \
        "$REPO_ROOT/deploy/scripts/lib/sv-assemble.sh" >/dev/null \
        || fail "launcher summary must label the configured fb-shm rate"
    grep -F -- 'effective 可降至 1 Hz' \
        "$REPO_ROOT/deploy/scripts/lib/sv-assemble.sh" >/dev/null \
        || fail "launcher summary must explain the idle effective rate"
    grep -F -- '不可用自动 SHM fallback' \
        "$REPO_ROOT/deploy/scripts/lib/sv-assemble.sh" >/dev/null \
        || fail "launcher summary must explain automatic SHM fallback"
}

test_explicit_blob_preference_disable_keeps_sdl_gl() {
    local out="$1"
    local vga

    run_dry 9912 "$out" --no-gpu-zerocopy
    grep -Fx -- 'sdl,gl=on,show-cursor=off' "$out" >/dev/null \
        || fail "blob/hostmem opt-out must not disable SDL/GL"
    vga="$(vga_arg "$out")"
    [[ "$vga" == virtio-vga-gl,* ]] \
        || fail "blob/hostmem opt-out must retain virtio-vga-gl"
    [[ "$vga" != *"blob=true"* && "$vga" != *"hostmem="* ]] \
        || fail "--no-gpu-zerocopy must remove blob/hostmem"
    grep -F -- 'blob/hostmem 偏好已关闭' \
        "$REPO_ROOT/deploy/scripts/lib/sv-assemble.sh" >/dev/null \
        || fail "launcher summary must distinguish property opt-out from GPU export"
}

test_environment_disable_is_honored() {
    local out="$1"
    local vga

    GPU_ZEROCOPY=0 DISPLAY=:0 DRY_RUN=1 TPM=0 HOST_TUNE=0 CPU_ISOLATE=0 \
        QEMU_CAP_CHECK=0 INSTANCE=9913 \
        "$START_VM" --no-bridge --no-fb-shm > "$out"
    vga="$(vga_arg "$out")"
    [[ "$vga" != *"blob=true"* && "$vga" != *"hostmem="* ]] \
        || fail "GPU_ZEROCOPY=0 must remove blob/hostmem"
}

test_non_gl_modes_are_safe_exceptions() {
    local out="$1"
    local vga

    STABLE_DISPLAY=1 run_dry 9914 "$out"
    grep -Fx -- 'sdl,show-cursor=off' "$out" >/dev/null \
        || fail "stable display must use non-GL SDL"
    vga="$(vga_arg "$out")"
    [[ "$vga" == virtio-vga,* && "$vga" != *"blob=true"* ]] \
        || fail "stable display must not advertise a GPU handoff path"

    run_dry 9915 "$out" --headless
    grep -Fx -- 'none' "$out" >/dev/null \
        || fail "VNC headless mode must use display none"
    vga="$(vga_arg "$out")"
    [[ "$vga" == virtio-vga,* && "$vga" != *"blob=true"* ]] \
        || fail "VNC headless mode must not inject blob/hostmem"
}

test_explicit_gpu_display_modes() {
    local out="$1"
    local vga

    run_dry 9916 "$out" --gpu-sdl-egl --no-fb-shm
    grep -Fx -- 'sdl,gl=on,show-cursor=off' "$out" >/dev/null \
        || fail "sdl-egl compatibility mode must use official SDL/GL"
    vga="$(vga_arg "$out")"
    [[ "$vga" == *"blob=true"* && "$vga" == *"hostmem=256M"* ]] \
        || fail "sdl-egl compatibility mode must enable blob/hostmem"

    run_dry 9917 "$out" --gpu-headless --no-fb-shm
    grep -Fx -- 'egl-headless' "$out" >/dev/null \
        || fail "GPU headless mode must select egl-headless"
    vga="$(vga_arg "$out")"
    [[ "$vga" == virtio-vga-gl,* && "$vga" == *"blob=true"* ]] \
        || fail "GPU headless mode must retain GPU export capability"

    run_dry 9918 "$out" --gpu-hostmem=512M --no-fb-shm
    vga="$(vga_arg "$out")"
    [[ "$vga" == *"blob=true"* && "$vga" == *"hostmem=512M"* ]] \
        || fail "default capability preference must honor --gpu-hostmem"
}

main() {
    local out

    [[ -x "$START_VM" ]] || fail "missing executable: $START_VM"
    out="$(mktemp)"
    trap 'rm -f "${out:-}"' EXIT

    test_default_sdl_prefers_gpu_handoff "$out"
    test_explicit_blob_preference_disable_keeps_sdl_gl "$out"
    test_environment_disable_is_honored "$out"
    test_non_gl_modes_are_safe_exceptions "$out"
    test_explicit_gpu_display_modes "$out"
    echo "PASS: GPU zero-copy launcher policy"
}

main "$@"
