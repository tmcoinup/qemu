#!/usr/bin/env bash
# 验证 Windows 启动器的 stable、GL-safe 与显式 GPU zero-copy 策略。
# 全程使用 PowerShell DryRun，不启动 QEMU 或写入 VM/profile 状态。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
LAUNCHER="$REPO_ROOT/deploy/windows/start-vm.ps1"
DISPLAY_POLICY_TMP=""

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

cleanup() {
    if [[ -n "$DISPLAY_POLICY_TMP" && -d "$DISPLAY_POLICY_TMP" ]]; then
        rm -rf -- "$DISPLAY_POLICY_TMP"
    fi
}

vga_arg() {
    grep -E '^virtio-vga(-gl)?,' "$1" | head -n 1
}

main() {
    local pwsh_bin out vga value bad

    pwsh_bin="$(command -v pwsh || command -v powershell || true)"
    if [[ -z "$pwsh_bin" ]]; then
        echo "SKIP: PowerShell not found for Windows display policy"
        return
    fi

    DISPLAY_POLICY_TMP="$(mktemp -d)"
    trap cleanup EXIT
    out="$DISPLAY_POLICY_TMP/out.txt"
    mkdir -p "$DISPLAY_POLICY_TMP/user"
    touch "$DISPLAY_POLICY_TMP/disk.qcow2"
    printf 'firmware-code' >"$DISPLAY_POLICY_TMP/code.fd"
    printf 'firmware-vars' >"$DISPLAY_POLICY_TMP/vars.fd"

    run_windows_dry() {
        USERPROFILE="$DISPLAY_POLICY_TMP/user" "$pwsh_bin" \
            -NoLogo -NoProfile -NonInteractive -File "$LAUNCHER" \
            -Qemu /bin/true -VmRoot "$DISPLAY_POLICY_TMP/vm" \
            -Disk "$DISPLAY_POLICY_TMP/disk.qcow2" \
            -OvmfCode "$DISPLAY_POLICY_TMP/code.fd" \
            -OvmfVarsTemplate "$DISPLAY_POLICY_TMP/vars.fd" \
            -FbShmPath "$DISPLAY_POLICY_TMP/fb.sock" \
            -DryRunHostCpuName 'Intel(R) Core(TM) i3-9100F CPU @ 3.60GHz' \
            -DryRun "$@" >"$out" 2>&1
    }

    # 即使 CI 注入“GL 可用”，未传 -GpuGl 时也不得探测后自动扩大 PCI 面。
    run_windows_dry -GpuGlProbe Available
    grep -Fx -- 'sdl,show-cursor=off' "$out" >/dev/null \
        || fail "Windows default must stay on stable SDL"
    vga="$(vga_arg "$out")"
    [[ "$vga" == virtio-vga,* && "$vga" != *"blob=true"* &&
       "$vga" != *"hostmem="* ]] \
        || fail "Windows default must omit GL/blob/hostmem"

    run_windows_dry -GpuGl -GpuGlProbe Available
    grep -Fx -- 'sdl,gl=on,show-cursor=off' "$out" >/dev/null \
        || fail "Windows -GpuGl must enable SDL/GL"
    vga="$(vga_arg "$out")"
    [[ "$vga" == virtio-vga-gl,* && "$vga" != *"blob=true"* &&
       "$vga" != *"hostmem="* ]] \
        || fail "Windows -GpuGl must default to gl-safe"

    # 覆盖最小值的 M/K/裸字节等价形式及最大值；argv 应保留用户原值。
    for value in 256M 262144K 268435456 8G; do
        run_windows_dry -GpuGl -GpuZeroCopy -GpuHostmem "$value" \
            -GpuGlProbe Available
        vga="$(vga_arg "$out")"
        [[ "$vga" == virtio-vga-gl,* && "$vga" == *"blob=true"* &&
           "$vga" == *"hostmem=$value"* ]] \
            || fail "Windows rejected or rewrote valid hostmem: $value"
    done

    run_windows_dry -GpuGl -NoGpuZeroCopy -GpuGlProbe Available
    vga="$(vga_arg "$out")"
    [[ "$vga" == virtio-vga-gl,* && "$vga" != *"blob=true"* &&
       "$vga" != *"hostmem="* ]] \
        || fail "Windows -NoGpuZeroCopy must retain GL-safe mode"

    if run_windows_dry -GpuGl -GpuGlProbe Unavailable; then
        fail "explicit Windows -GpuGl silently fell back after a failed probe"
    fi
    grep -F -- '已显式请求 -GpuGl，但 virtio-vga-gl 所需能力探测失败' \
        "$out" >/dev/null \
        || fail "failed explicit GL probe lacks fail-closed diagnosis"

    if run_windows_dry -GpuZeroCopy -NoGpuZeroCopy; then
        fail "Windows accepted conflicting zero-copy switches"
    fi
    grep -F -- '-GpuZeroCopy 与兼容参数 -NoGpuZeroCopy 不能同时使用' \
        "$out" >/dev/null || fail "zero-copy conflict lacks diagnosis"

    if run_windows_dry -GpuZeroCopy; then
        fail "Windows accepted -GpuZeroCopy without -GpuGl"
    fi
    grep -F -- '-GpuZeroCopy 依赖显式 -GpuGl' "$out" >/dev/null \
        || fail "zero-copy/GL dependency lacks diagnosis"

    if run_windows_dry -GpuGl -GpuZeroCopy -NoFbShm; then
        fail "Windows accepted -GpuZeroCopy with fb-shm disabled"
    fi
    grep -F -- '-GpuZeroCopy 仅服务 fb-shm GPU handle' "$out" >/dev/null \
        || fail "zero-copy/fb-shm conflict lacks diagnosis"

    if run_windows_dry -GpuHostmem 512M; then
        fail "Windows accepted -GpuHostmem without -GpuZeroCopy"
    fi
    grep -F -- '显式 -GpuHostmem 需要同时启用 -GpuZeroCopy' "$out" >/dev/null \
        || fail "hostmem/zero-copy dependency lacks diagnosis"

    if run_windows_dry -GpuGl -NoSdl; then
        fail "Windows accepted -GpuGl with -NoSdl"
    fi
    grep -F -- '-GpuGl 需要本地 SDL 窗口' "$out" >/dev/null \
        || fail "GL/NoSdl conflict lacks diagnosis"

    for bad in 255M 300M 9G 1T 268435455 invalid; do
        if run_windows_dry -GpuGl -GpuZeroCopy -GpuHostmem "$bad"; then
            fail "Windows accepted invalid hostmem: $bad"
        fi
        grep -F -- 'GpuHostmem 必须是 256M..8G 内 2 的幂' "$out" >/dev/null \
            || fail "invalid hostmem lacks bounded power-of-two diagnosis: $bad"
    done

    [[ ! -e "$DISPLAY_POLICY_TMP/vm" ]] \
        || fail "Windows display DryRun wrote VM/profile state"
    echo "PASS: Windows stable/GL/zero-copy display policy"
}

main "$@"
