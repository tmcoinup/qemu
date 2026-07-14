#!/usr/bin/env bash
# 验证严格模式会真实 realize 选定 CPU，并拒绝缺特性 warning 或伪成功进程。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

HERE="$REPO_ROOT/deploy/scripts"
STRICT_HARDWARE=1
STEALTH_KVM_AVAILABLE=1
STEALTH_KVM_TSC_CONTROL=1
STEALTH_KVM_GET_TSC_KHZ=1
STEALTH_KVM_TSC_KHZ=2200000
STEALTH_KVM_ERROR=
STEALTH_HOST_CPU_PHYS_BITS=48
source "$REPO_ROOT/deploy/scripts/lib/sv-host-capabilities.sh"

# host-phys-bits-limit 只有在物理宿主位宽不少于 profile 目标时才会精确得到
# 目标 CPUID；不足或严格模式下无法探测都必须早于 QEMU/磁盘写入失败。
CPU_PHYS_BITS=43
sv_validate_cpu_phys_bits || fail "48-bit 宿主应能实现 43-bit profile"
STEALTH_HOST_CPU_PHYS_BITS=42
if sv_validate_cpu_phys_bits >/dev/null 2>&1; then
    fail "宿主物理地址位宽不足时未拒绝"
fi
STEALTH_HOST_CPU_PHYS_BITS=0
if sv_validate_cpu_phys_bits >/dev/null 2>&1; then
    fail "严格模式无法探测宿主地址位宽时未拒绝"
fi
STRICT_HARDWARE=0
sv_validate_cpu_phys_bits >/dev/null 2>&1 \
    || fail "非严格诊断模式应允许未知宿主地址位宽"
STRICT_HARDWARE=1
STEALTH_HOST_CPU_PHYS_BITS=48

PLATFORM_ID=test-platform
CPU_NAME='Test CPU'
CPU_CORES=4
CPU_THREADS=4
CPUS=4
stealth_qemu_cpu_arg() { printf '%s' 'test-cpu,enforce=on'; }

# 固定 fixture 根据 VMATE_QEMU_STUB_MODE 输出协议，复制后可作为含空格路径的 QEMU。
QEMU="$TMP_DIR/qemu good"
cp "$SCRIPT_DIR/fixtures/qemu-cpu-preflight-stub.sh" "$QEMU"
chmod +x "$QEMU"

VMATE_QEMU_STUB_MODE=good sv_validate_cpu_realize \
    || fail "合法 QMP/vCPU 烟测被拒绝"

if VMATE_QEMU_STUB_MODE=warning sv_validate_cpu_realize >/dev/null 2>&1; then
    fail "CPU 缺特性 warning 未被拒绝"
fi

if VMATE_QEMU_STUB_MODE=silent sv_validate_cpu_realize >/dev/null 2>&1; then
    fail "未返回 QMP quit 的伪成功进程未被拒绝"
fi

STRICT_HARDWARE=0
VMATE_QEMU_STUB_MODE=warning sv_validate_cpu_realize \
    || fail "兼容模式不应执行严格 CPU 烟测"

# reroll 先生成内存候选、通过 smoke 后才原子替换。用完整启动器证明 smoke 失败时
# 旧 profile 既不会被删除，也不会被未实现的新身份覆盖。
IMAGE_ROOT="$TMP_DIR/images"
PROFILE_DIR="$IMAGE_ROOT/vms/9751"
PROFILE_FILE="$PROFILE_DIR/profile"
mkdir -p "$PROFILE_DIR"
(
    source "$REPO_ROOT/deploy/scripts/stealth-lib.sh"
    # 选择器按全局变量名读取宿主能力，导出后语义对 shell/子进程一致。
    export STEALTH_HOST_CPU_VENDOR=GenuineIntel
    export STEALTH_HOST_CPU_MAX_MHZ=5000
    STEALTH_REQUIRED_TSC_MHZ=
    CPUS=4
    stealth_pick_profile
    stealth_save_profile "$PROFILE_FILE"
)
profile_hash_before="$(sha256sum "$PROFILE_FILE")"
if env \
    IMAGE_ROOT="$IMAGE_ROOT" \
    DRY_RUN=1 \
    TPM=0 \
    HOST_TUNE=0 \
    CPU_ISOLATE=0 \
    QEMU_CAP_CHECK=0 \
    STRICT_HARDWARE=1 \
    STEALTH_KVM_AVAILABLE=1 \
    STEALTH_KVM_TSC_CONTROL=1 \
    STEALTH_KVM_GET_TSC_KHZ=1 \
    STEALTH_KVM_TSC_KHZ=2200000 \
    STEALTH_HOST_CPU_VENDOR=GenuineIntel \
    STEALTH_HOST_CPU_MAX_MHZ=5000 \
    VMATE_QEMU_STUB_MODE=warning \
    QEMU="$QEMU" \
    QEMU_IMG=/bin/true \
    "$HERE/start-vm.sh" 9751 --reroll --no-sdl --no-fb-shm --no-bridge \
        >"$TMP_DIR/reroll.out" 2>&1
then
    fail "CPU smoke warning 场景意外启动成功"
fi
[[ -f "$PROFILE_FILE" ]] || fail "reroll smoke 失败删除了旧 profile"
profile_hash_after="$(sha256sum "$PROFILE_FILE")"
[[ "$profile_hash_before" == "$profile_hash_after" ]] \
    || fail "reroll smoke 失败覆盖了旧 profile"

echo "OK: CPU realize preflight checks passed"
