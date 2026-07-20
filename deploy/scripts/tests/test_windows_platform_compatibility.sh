#!/usr/bin/env bash
# 验证 Windows/WHPX 对未闭环的宿主兼容模式 fail-closed，同时保留精确平台路线。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
LAUNCHER="$REPO_ROOT/deploy/windows/start-vm.ps1"
PLATFORMS="$REPO_ROOT/deploy/hardware/platforms.json"
COMPATIBILITY="$REPO_ROOT/deploy/hardware/host-compatibility.json"
COMPONENTS="$REPO_ROOT/deploy/hardware/components.json"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

if command -v pwsh >/dev/null 2>&1; then
    POWERSHELL="$(command -v pwsh)"
elif command -v powershell >/dev/null 2>&1; then
    POWERSHELL="$(command -v powershell)"
else
    echo "SKIP: PowerShell not found; Windows compatibility test skipped"
    exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/inputs" "$tmp/user"
touch "$tmp/inputs/disk.qcow2"
truncate -s 4096 "$tmp/inputs/code.fd" "$tmp/inputs/vars-template.fd"

run_launcher() {
    USERPROFILE="$tmp/user" "$POWERSHELL" -NoLogo -NoProfile -NonInteractive \
        -File "$LAUNCHER" -Qemu /bin/true \
        -VmRoot "$tmp/strict-vm" -Disk "$tmp/inputs/disk.qcow2" \
        -OvmfCode "$tmp/inputs/code.fd" \
        -OvmfVarsTemplate "$tmp/inputs/vars-template.fd" \
        -HardwareManifest "$PLATFORMS" \
        -HostCompatibilityManifest "$COMPATIBILITY" \
        -ComponentManifest "$COMPONENTS" -FbShmPath "$tmp/fb.sock" \
        -GpuGlProbe Unavailable -DryRun "$@"
}

assert_compatibility_rejected_before_paths() {
    local option="$1"
    local state="$tmp/state-${option#-}"
    local output="$tmp/${option#-}.out"

    if USERPROFILE="$tmp/user" "$POWERSHELL" -NoLogo -NoProfile \
        -NonInteractive -File "$LAUNCHER" \
        -Qemu "$tmp/missing-qemu.exe" \
        -VmRoot "$state/vm" -Disk "$tmp/missing-disk.qcow2" \
        -OvmfCode "$tmp/missing-code.fd" \
        -OvmfVarsTemplate "$tmp/missing-template.fd" \
        -OvmfVars "$state/OVMF_VARS.fd" \
        -HardwareProfile "$state/profile.json" \
        -HardwareManifest "$tmp/missing-platforms.json" \
        -HostCompatibilityManifest "$tmp/missing-compatibility.json" \
        -ComponentManifest "$tmp/missing-components.json" \
        -DryRun "$option" >"$output" 2>&1; then
        fail "$option unexpectedly enabled Windows host compatibility"
    fi
    grep -F -- '完整宿主绑定与 WHPX realize' "$output" >/dev/null \
        || fail "$option did not report the fail-closed compatibility boundary"
    [[ ! -e "$state" ]] \
        || fail "$option touched VM state before rejecting compatibility mode"
}

assert_compatibility_rejected_before_paths -AllowPlatformCompatibility
assert_compatibility_rejected_before_paths -AllowHostCpuPlatformMismatch

# 没有对应物理 bundle 的宿主必须给出可执行的严格拒绝，不能建议已禁用的开关。
if run_launcher -DryRunHostVendorId GenuineIntel \
    -DryRunHostCpuName 'Intel(R) Core(TM) i3-6100 CPU @ 3.70GHz' \
    -DryRunHostCores 2 -DryRunHostLogicalProcessors 4 \
    -DryRunHostMaxMhz 3700 >"$tmp/unlisted.out" 2>&1; then
    fail "unlisted CPU unexpectedly entered a physical platform"
fi
grep -F -- 'Windows 启动器当前只开放精确物理平台' \
    "$tmp/unlisted.out" >/dev/null \
    || fail "unlisted CPU rejection did not describe the strict boundary"
if grep -F -- '可显式使用 -AllowPlatformCompatibility' \
    "$tmp/unlisted.out" >/dev/null; then
    fail "strict rejection recommended an unavailable compatibility mode"
fi

# 禁用通用模板不能误伤已验证的精确物理平台。
run_launcher -PlatformId intel-lga1151-i3-9100f-asus-prime-h310m-a-r2 \
    -DryRunHostVendorId GenuineIntel \
    -DryRunHostCpuName 'Intel(R) Core(TM) i3-9100F CPU @ 3.60GHz' \
    -DryRunHostCores 4 -DryRunHostLogicalProcessors 4 \
    -DryRunHostMaxMhz 4200 >"$tmp/strict.out"
grep -F -- \
    'platform=intel-lga1151-i3-9100f-asus-prime-h310m-a-r2' \
    "$tmp/strict.out" >/dev/null \
    || fail "exact physical platform no longer launches in dry-run mode"
grep -Fx -- 'host' "$tmp/strict.out" >/dev/null \
    || fail "exact WHPX platform did not retain host CPU passthrough"

# Windows 仍解析共享格式，便于未来恢复；这不代表 launcher 当前可达。
BAD_MANIFEST="$tmp/bad-host-compatibility.json"
jq '.selection_policy.kvm_realize_required = false' \
    "$COMPATIBILITY" >"$BAD_MANIFEST"
if REPO_ROOT="$REPO_ROOT" BAD_MANIFEST="$BAD_MANIFEST" \
    "$POWERSHELL" -NoLogo -NoProfile -NonInteractive -Command '
        . "$env:REPO_ROOT/deploy/windows/lib/VMate.Common.ps1"
        . "$env:REPO_ROOT/deploy/windows/lib/VMate.Compatibility.ps1"
        [void](Read-VMateHostCompatibilityManifest $env:BAD_MANIFEST)
    ' >"$tmp/bad-manifest.out" 2>&1; then
    fail "Windows parser accepted a weakened shared compatibility manifest"
fi

echo "OK: Windows compatibility is fail-closed; exact WHPX platform remains available"
