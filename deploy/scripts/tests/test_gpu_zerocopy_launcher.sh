#!/usr/bin/env bash
# 验证 Linux 启动器的 GPU handoff 默认策略；全程 DRY_RUN，不启动 guest。
# shellcheck disable=SC2016
# `${FB_SHM_RATE}` 是断言目标源码中的字面文本，不应在测试 shell 中展开。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
START_VM="$REPO_ROOT/deploy/scripts/start-vm.sh"

# 本用例只检查显示 argv，不应随 CI 宿主是 AMD/Intel 或是否开放 /dev/kvm 而变化。
# 显式进入兼容 dry-run，并注入一个 manifest 中真实启用的 Intel 候选。
export STRICT_HARDWARE=0
export STEALTH_KVM_AVAILABLE=1
export STEALTH_KVM_TSC_CONTROL=1
export STEALTH_KVM_GET_TSC_KHZ=1
export STEALTH_KVM_TSC_KHZ=3600000
export STEALTH_HOST_CPU_VENDOR=GenuineIntel
export STEALTH_HOST_CPU_MAX_MHZ=5000

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
        "$START_VM" --no-bridge "$@" > "$out" 2>&1
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
    [[ "$vga" == *",edid-fixed-native=on,"* ]] \
        || fail "virtio-vga-gl must explicitly fix the profile native mode"
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
    grep -F -- 'Windows VioGpuDod 仍无客体 3D' \
        "$REPO_ROOT/deploy/scripts/lib/stealth-print.sh" >/dev/null \
        || fail "profile summary must not describe host virgl as Windows guest 3D"
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
    [[ "$vga" == *",edid-fixed-native=on,"* ]] \
        || fail "virtio-vga must explicitly fix the profile native mode"

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

test_removed_selfsigned_mode_fails_closed() {
    local out="$1"
    local helper="${out}.host-helper"
    local marker="${out}.host-side-effect"

    if GPU_SELFSIGNED=1 run_dry 9919 "$out"; then
        fail "removed self-signed primary PCI mode unexpectedly launched"
    fi
    grep -F 'GPU_SELFSIGNED 深层/自签路径已移除' "$out" >/dev/null \
        || fail "removed self-signed mode did not provide migration diagnosis"

    # 再跑一次非 DRY_RUN，并注入一个只会写 marker 的 host 调优 helper。旧环境变量
    # 必须在 sv-cli 阶段退出，因此 helper 绝不能被调用；这覆盖“启动失败但宿主已被
    # 改 governor/halt_poll”的副作用回归。
    printf '%s\n' '#!/usr/bin/env bash' ': > "$SIDE_EFFECT_MARKER"' > "$helper"
    chmod 0755 "$helper"
    rm -f "$marker"
    if GPU_SELFSIGNED=1 HOST_TUNE=1 SV_HOST_PERF_HELPER="$helper" \
            SIDE_EFFECT_MARKER="$marker" "$START_VM" 9919 --no-bridge \
            > "$out" 2>&1; then
        fail "removed self-signed mode unexpectedly passed non-dry preflight"
    fi
    [[ ! -e "$marker" ]] \
        || fail "removed self-signed mode modified host state before rejection"
}

main() {
    local out

    [[ -x "$START_VM" ]] || fail "missing executable: $START_VM"
    out="$(mktemp)"
    trap 'rm -f "${out:-}" "${out:-}.host-helper" "${out:-}.host-side-effect"' EXIT

    test_default_sdl_prefers_gpu_handoff "$out"
    test_explicit_blob_preference_disable_keeps_sdl_gl "$out"
    test_environment_disable_is_honored "$out"
    test_non_gl_modes_are_safe_exceptions "$out"
    test_explicit_gpu_display_modes "$out"
    test_removed_selfsigned_mode_fails_closed "$out"
    echo "PASS: GPU zero-copy launcher policy"
}

main "$@"
