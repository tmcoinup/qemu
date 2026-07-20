#!/usr/bin/env bash
# 验证 E5/Broadwell 无 TSC scaling 时的启动门禁，不需要真实 /dev/kvm。
# 各测试用命令替换/子 shell 构造互斥 TSC 宿主视图；同名变量在场景间重新赋值
# 是隔离设计，子 shell 赋值本就不应传播到下一场景。
# shellcheck disable=SC2030,SC2031
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=../lib/stealth-smbios.sh
source "$REPO_ROOT/deploy/scripts/lib/stealth-smbios.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

expect_equal() {
    local actual="$1"
    local expected="$2"
    local message="$3"
    [[ "$actual" == "$expected" ]] || fail "$message: '$actual' != '$expected'"
}

test_scaling_accepts_profile_frequency() {
    local actual
    actual="$(
        CPU_TSC_MHZ=3600
        STEALTH_KVM_TSC_CONTROL=1
        STEALTH_KVM_TSC_KHZ=2200000
        STRICT_HARDWARE=1
        STEALTH_TSC_POLICY=auto
        _stealth_tsc_qemu_extra
    )"
    expect_equal "$actual" ",tsc-freq=3600000000" "支持 scaling 时应使用 profile TSC"
}

test_without_scaling_requires_250ppm_match() {
    local actual
    actual="$(
        CPU_TSC_MHZ=2200
        STEALTH_KVM_TSC_CONTROL=0
        STEALTH_KVM_TSC_KHZ=2200000
        STRICT_HARDWARE=1
        STEALTH_TSC_POLICY=auto
        _stealth_tsc_qemu_extra
    )"
    expect_equal "$actual" ",tsc-freq=2200000000" "相同 TSC 应可在 E5 上启动"
}

test_strict_mode_rejects_e5_mismatch() {
    local err
    err="$(mktemp)"
    if (
        CPU_TSC_MHZ=3600
        STEALTH_KVM_TSC_CONTROL=0
        STEALTH_KVM_TSC_KHZ=2200000
        STRICT_HARDWARE=1
        STEALTH_TSC_POLICY=auto
        _stealth_tsc_qemu_extra
    ) 2>"$err"; then
        rm -f "$err"
        fail "严格模式不应接受 E5 2.2GHz -> profile 3.6GHz"
    fi
    grep -F "KVM_CAP_TSC_CONTROL 不可用" "$err" >/dev/null \
        || fail "严格模式错误缺少可操作诊断"
    rm -f "$err"
}

test_compatibility_mode_omits_impossible_frequency() {
    local actual
    actual="$(
        CPU_TSC_MHZ=3600
        STEALTH_KVM_TSC_CONTROL=0
        STEALTH_KVM_TSC_KHZ=2200000
        STRICT_HARDWARE=0
        STEALTH_TSC_POLICY=auto
        _stealth_tsc_qemu_extra 2>/dev/null
    )"
    expect_equal "$actual" "" "兼容模式应省略不可能的 tsc-freq"
}

test_cpu_arg_uses_manifest_phys_bits_and_features() {
    local actual
    # 被测构造器按全局变量名读取整套 CPU 上下文，导出可准确表达这层接口。
    export CPU_QEMU_ARG="Skylake-Client-IBRS"
    export CPU_VENDOR="GenuineIntel"
    export CPU_PHYS_BITS=39
    export CPU_FEATURES="+invtsc,-hle,-rtm"
    export CPU_TSC_MHZ=2200
    export STEALTH_KVM_TSC_CONTROL=0
    export STEALTH_KVM_TSC_KHZ=2200000
    export STRICT_HARDWARE=1
    export STEALTH_TSC_POLICY=auto
    export STEALTH_HOST_CPU_FLAGS=""

    actual="$(stealth_qemu_cpu_arg)"
    [[ "$actual" == *"host-phys-bits=on,host-phys-bits-limit=39"* ]] \
        || fail "CPU 参数没有通过 host limit 固定 manifest phys-bits"
    [[ "$actual" != *",phys-bits="* ]] \
        || fail "CPU 参数仍直接写 phys-bits，会在宿主位宽不同时产生 warning"
    [[ "$actual" == *"enforce=on"* && "$actual" == *"-hle,-rtm"* ]] \
        || fail "严格模式或 manifest 特性没有进入 CPU 参数"
}

test_intel_cpu_arg_masks_only_missing_tsx_features() {
    local actual
    export CPU_QEMU_ARG="Skylake-Client-IBRS"
    export CPU_VENDOR="GenuineIntel"
    export CPU_PHYS_BITS=39
    export CPU_FEATURES="+invtsc"
    export CPU_TSC_MHZ=2200
    export STEALTH_KVM_TSC_CONTROL=0
    export STEALTH_KVM_TSC_KHZ=2200000
    export STRICT_HARDWARE=1
    export STEALTH_TSC_POLICY=auto
    export STEALTH_HOST_CPU_FLAGS="fpu hle"

    actual="$(stealth_qemu_cpu_arg)"
    [[ "$actual" == *"-rtm"* && "$actual" != *"-hle"* ]] \
        || fail "Intel CPU 应只禁用宿主缺失的 TSX 子特性: $actual"
}

test_scaling_accepts_profile_frequency
test_without_scaling_requires_250ppm_match
test_strict_mode_rejects_e5_mismatch
test_compatibility_mode_omits_impossible_frequency
test_cpu_arg_uses_manifest_phys_bits_and_features
test_intel_cpu_arg_masks_only_missing_tsx_features
echo "PASS: TSC policy"
