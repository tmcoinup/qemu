#!/usr/bin/env bash
# 验证正常/同代池全部不可用时，显式 allow 才启用同厂商跨代家用 CPU 最末兜底。
# 每个用例故意在独立 subshell 中构造互斥宿主视图，变量不应传播到下一个用例。
# shellcheck disable=SC1091,SC2030,SC2031
set -euo pipefail
export STEALTH_HOST_PROBE_TEST_MODE=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$REPO_ROOT/deploy/scripts/stealth-lib.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

sv_validate_cpu_phys_bits() {
    [[ "${CPU_PHYS_BITS:-}" =~ ^[0-9]+$ ]]
}

# 受控替身只接受测试指定的最终 SKU；其它正常、静态和同代候选均模拟为当前
# KVM 无法 realize，迫使选择器走到跨代最后一级。
sv_validate_cpu_realize() {
    [[ "${PLATFORM_ID:-}" == "${ACCEPT_PLATFORM_ID:-never}" ]]
}

set_e5_v4_host() {
    export STEALTH_HOST_CPU_VENDOR=GenuineIntel
    export STEALTH_HOST_CPU_FAMILY=6
    export STEALTH_HOST_CPU_MODEL=79
    export STEALTH_HOST_CPU_MODEL_NAME="Intel(R) Xeon(R) CPU E5-2696 v4 @ 2.20GHz"
    export STEALTH_HOST_CPU_MAX_MHZ=3700
    export STEALTH_HOST_CPU_PHYS_BITS=46
    export CPUS=4
    export STEALTH_PLATFORM_ID=
    export STEALTH_KVM_TSC_CONTROL=1
    export STEALTH_REQUIRED_TSC_MHZ=
    export STRICT_HARDWARE=1
    export STEALTH_TSC_POLICY=auto
    export STEALTH_SEED=31
    _rng_init
}

test_allow_controls_cross_generation_fallback() (
    set_e5_v4_host
    export ACCEPT_PLATFORM_ID=compat-sandy-i5-2400-p8h61
    export ALLOW_PLATFORM_COMPATIBILITY=0
    if stealth_select_platform_bundle >/dev/null 2>&1; then
        fail "未授权时跨代选择了 Sandy 家用 CPU"
    fi

    export ALLOW_PLATFORM_COMPATIBILITY=1
    stealth_select_platform_bundle >/dev/null
    [[ "$PLATFORM_ID" == "$ACCEPT_PLATFORM_ID" &&
       "$PLATFORM_STATUS" == compatibility &&
       "$CPU_VENDOR" == GenuineIntel &&
       "$CPU_NAME" != *Xeon* ]] ||
        fail "E5 v4 空池后没有选择授权的 Intel 家用跨代兜底"
)

test_cross_generation_keeps_tsc_gate() (
    set_e5_v4_host
    export ACCEPT_PLATFORM_ID=compat-sandy-i5-2400-p8h61
    export ALLOW_PLATFORM_COMPATIBILITY=1
    export STEALTH_KVM_TSC_CONTROL=0
    export STEALTH_REQUIRED_TSC_MHZ=2195
    if stealth_select_platform_bundle >/dev/null 2>&1; then
        fail "跨代兜底绕过了不匹配的 invariant TSC 门禁"
    fi
)

test_amd_zen_can_fall_back_to_k10() (
    export STEALTH_HOST_CPU_VENDOR=AuthenticAMD
    export STEALTH_HOST_CPU_FAMILY=25
    export STEALTH_HOST_CPU_MODEL=1
    export STEALTH_HOST_CPU_MODEL_NAME="AMD Ryzen 7 5700X 8-Core Processor"
    export STEALTH_HOST_CPU_MAX_MHZ=5000
    export STEALTH_HOST_CPU_PHYS_BITS=48
    export STEALTH_KVM_TSC_CONTROL=1
    export STEALTH_REQUIRED_TSC_MHZ=
    export CPUS=4
    export STRICT_HARDWARE=1
    export STEALTH_TSC_POLICY=auto
    export STEALTH_PLATFORM_ID=
    export ALLOW_PLATFORM_COMPATIBILITY=1
    export ACCEPT_PLATFORM_ID=compat-k10-phenom-ii-x4-955-m5a78l
    export STEALTH_SEED=37
    _rng_init
    stealth_select_platform_bundle >/dev/null
    [[ "$PLATFORM_ID" == "$ACCEPT_PLATFORM_ID" &&
       "$CPU_VENDOR" == AuthenticAMD &&
       "$CPU_NAME" != *EPYC* ]] ||
        fail "AMD Zen 空池后没有选择 K10 家用兜底"
)

test_cross_generation_never_crosses_vendor() (
    set_e5_v4_host
    export ACCEPT_PLATFORM_ID=compat-k10-phenom-ii-x4-955-m5a78l
    export ALLOW_PLATFORM_COMPATIBILITY=1
    if stealth_select_platform_bundle >/dev/null 2>&1; then
        fail "Intel 宿主跨厂商选择了 AMD 家用 CPU"
    fi
)

test_cross_generation_profile_reload_requires_allow() (
    set_e5_v4_host
    export ALLOW_PLATFORM_COMPATIBILITY=1
    stealth_platform_registry_load compat-sandy-i5-2400-p8h61 4
    export ALLOW_PLATFORM_COMPATIBILITY=0
    if stealth_validate_platform_host_constraints >/dev/null 2>&1; then
        fail "跨代 compatibility profile 未经 allow 被重载"
    fi
    export ALLOW_PLATFORM_COMPATIBILITY=1
    stealth_validate_platform_host_constraints ||
        fail "已授权同厂商跨代 profile 无法通过原始宿主约束"
)

test_allow_controls_cross_generation_fallback
test_cross_generation_keeps_tsc_gate
test_amd_zen_can_fall_back_to_k10
test_cross_generation_never_crosses_vendor
test_cross_generation_profile_reload_requires_allow
echo "OK: cross-generation household fallback stays explicit and fail-closed"
