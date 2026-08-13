#!/usr/bin/env bash
# 验证精确 Ryzen 7 5800 宿主可直接选择 4C4T 家用 Guest 正常池。
# shellcheck disable=SC1091,SC2030,SC2031,SC2317
set -euo pipefail
export STEALTH_HOST_PROBE_TEST_MODE=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$REPO_ROOT/deploy/scripts/stealth-lib.sh"

NORMAL_ID=normal-ryzen7-5800-ryzen3-1200-b350

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_equal() {
    local actual="$1" expected="$2" message="$3"
    [[ "$actual" == "$expected" ]] ||
        fail "$message: actual='$actual' expected='$expected'"
}

# 选择器必须保留真实 KVM 预检调用；本单元测试只用受控替身限定可接受 ID。
sv_validate_cpu_phys_bits() {
    [[ "${CPU_PHYS_BITS:-0}" =~ ^[0-9]+$ ]] && (( CPU_PHYS_BITS <= 48 ))
}

sv_validate_cpu_realize() {
    [[ "${PLATFORM_ID:-}" == "$NORMAL_ID" ]]
}

set_ryzen_5800_host() {
    export STEALTH_HOST_CPU_VENDOR=AuthenticAMD
    export STEALTH_HOST_CPU_FAMILY=25
    export STEALTH_HOST_CPU_MODEL=33
    export STEALTH_HOST_CPU_MODEL_NAME="AMD Ryzen 7 5800 8-Core Processor"
    export STEALTH_HOST_CPU_MAX_MHZ=4600
    export STEALTH_HOST_CPU_PHYS_BITS=48
    export STEALTH_KVM_TSC_CONTROL=1
    export STEALTH_REQUIRED_TSC_MHZ=
    export STEALTH_TSC_POLICY=auto
    export STRICT_HARDWARE=1
    export ALLOW_PLATFORM_COMPATIBILITY=0
    export STEALTH_PLATFORM_ID=
    export STEALTH_SEED=58
    _rng_init
}

test_exact_host_gets_normal_pool() (
    set_ryzen_5800_host
    export CPUS=4
    assert_equal "$(stealth_household_compat_current_host_class)" \
        amd-ryzen7-5800 "当前宿主未命中 5800 精确类"
    stealth_select_platform_bundle
    assert_equal "$PLATFORM_ID" "$NORMAL_ID" "5800 未选择专用正常池"
    assert_equal "$PLATFORM_STATUS" supported "5800 候选仍要求 compatibility"
    assert_equal "$CPU_NAME" "AMD Ryzen 3 1200 Quad-Core Processor" \
        "Guest 未保持家用 Ryzen 3 身份"
    assert_equal "$CPU_CORES:$CPU_THREADS" "4:4" "Guest 超出 4C4T 上限"
    assert_equal "$MEM_TYPE" DDR4 "Guest 内存类型错误"
    assert_equal "$MEM_MAX_MTS:$MEM_ALLOWED_MTS" "2667:2133,2400,2666" \
        "宿主 DDR4-3200 被错误投影为 Guest 内存频率"
)

test_nearby_skus_stay_generic() (
    set_ryzen_5800_host
    export STEALTH_HOST_CPU_MODEL_NAME="AMD Ryzen 7 5800X 8-Core Processor"
    assert_equal "$(stealth_household_compat_current_host_class)" amd-zen \
        "5800X 被错误归入 5800 正常类"
    [[ -z "$(stealth_household_compat_index amd-zen 4 supported)" ]] ||
        fail "通用 Zen 宿主错误获得 supported 候选"

    export CPUS=4
    export STEALTH_PLATFORM_ID="$NORMAL_ID"
    if stealth_select_platform_bundle >/dev/null 2>&1; then
        fail "5800X 可显式领取仅供 5800 的正常池"
    fi
)

test_only_complete_4c4t_sku_is_available() (
    set_ryzen_5800_host
    local cpus
    for cpus in 2 6; do
        export CPUS="$cpus"
        if stealth_select_platform_bundle >/dev/null 2>&1; then
            fail "5800 正常池错误提供 ${cpus}T Guest"
        fi
    done
)

test_production_probe_includes_brand_name() (
    _stealth_household_kernel_cpu_field() {
        case "$1" in
            vendor_id) echo AuthenticAMD ;;
            "cpu family") echo 25 ;;
            model) echo 33 ;;
            "model name") echo "AMD Ryzen 7 5800 8-Core Processor" ;;
        esac
    }
    export STEALTH_HOST_PROBE_TEST_MODE=0
    assert_equal "$(stealth_household_compat_current_host_class)" \
        amd-ryzen7-5800 "生产探测未把 model name 纳入精确分类"
)

test_exact_host_gets_normal_pool
test_nearby_skus_stay_generic
test_only_complete_4c4t_sku_is_available
test_production_probe_includes_brand_name
echo "OK: Ryzen 7 5800 exact-host 4C4T normal pool checks passed"
