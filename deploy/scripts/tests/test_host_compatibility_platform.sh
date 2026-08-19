#!/usr/bin/env bash
# 验证 generic Q35 host-passthrough 清单、宿主绑定和跨厂商门禁。
# shellcheck disable=SC1091
set -euo pipefail
export STEALTH_HOST_PROBE_TEST_MODE=1
export ALLOW_PLATFORM_COMPATIBILITY=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=../lib/stealth-rng.sh
source "$REPO_ROOT/deploy/scripts/lib/stealth-rng.sh"
# shellcheck source=../lib/stealth-host-platform.sh
source "$REPO_ROOT/deploy/scripts/lib/stealth-host-platform.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_equal() {
    local actual="$1" expected="$2" message="$3"
    [[ "$actual" == "$expected" ]] \
        || fail "$message: actual='$actual' expected='$expected'"
}

set_e5_host() {
    export STEALTH_HOST_CPU_VENDOR=GenuineIntel
    export STEALTH_HOST_CPU_MODEL_NAME='Intel(R) Xeon(R) CPU E5-2696 v4 @ 2.20GHz'
    export STEALTH_HOST_CPU_FAMILY=6
    export STEALTH_HOST_CPU_MODEL=79
    export STEALTH_HOST_CPU_STEPPING=1
    export STEALTH_HOST_CPU_CORES=22
    export STEALTH_HOST_CPU_ONLINE_THREADS=44
    export STEALTH_HOST_CPU_MAX_MHZ=3700
    export STEALTH_HOST_CPU_PHYS_BITS=46
    export STEALTH_KVM_TSC_KHZ=2200000
}

test_manifest_and_index() {
    local revision rows
    revision="$(stealth_host_platform_validate)"
    assert_equal "$revision" "2026-08-19.1" "共享清单 revision 错误"
    rows="$(stealth_host_platform_index)"
    grep -Fx 'compat-host-intel-q35|GenuineIntel' <<<"$rows" >/dev/null \
        || fail "缺少 Intel host template"
    grep -Fx 'compat-host-amd-q35|AuthenticAMD' <<<"$rows" >/dev/null \
        || fail "缺少 AMD host template"
    stealth_host_platform_is_id compat-host-intel-q35 \
        || fail "保留 Intel ID 未被识别"
    if stealth_host_platform_is_id intel-lga1151-does-not-exist; then
        fail "物理平台 ID 被误识别为 host template"
    fi
}

test_household_export_is_stable_and_truthful() {
    local cpu_arg fingerprint serial
    set_e5_host
    if stealth_host_platform_load compat-host-intel-q35 4 >/dev/null 2>&1; then
        fail "Xeon/E5 服务器品牌被 host-passthrough 暴露给 Guest"
    fi
    export STEALTH_HOST_CPU_MODEL_NAME='Intel(R) Core(TM) i3-9100F CPU @ 3.60GHz'
    export STEALTH_HOST_CPU_MODEL=158
    export STEALTH_HOST_CPU_STEPPING=10
    export STEALTH_HOST_CPU_CORES=4
    export STEALTH_HOST_CPU_ONLINE_THREADS=4
    export STEALTH_HOST_CPU_MAX_MHZ=4200
    export STEALTH_HOST_CPU_PHYS_BITS=39
    export STEALTH_KVM_TSC_KHZ=3600000
    stealth_host_platform_load compat-host-intel-q35 4

    assert_equal "$PLATFORM_STATUS" compatibility "host template 状态错误"
    assert_equal "$PLATFORM_CPU_SOURCE" host-passthrough "CPU 来源标记错误"
    assert_equal "$PLATFORM_MACHINE_MODEL" q35 "machine model 错误"
    assert_equal "$CPU_QEMU_ARG" host "E5 兜底必须使用 host"
    assert_equal "$CPU_VENDOR" GenuineIntel "E5 厂商错误"
    assert_equal "$CPU_HOST_MODEL" 158 "家用 CPU CPUID model 未绑定"
    assert_equal "$CPU_HOST_CORES" 4 "家用 CPU 核心数未绑定"
    assert_equal "$CPU_HOST_TSC_KHZ" 3600000 "家用 CPU TSC 未精确绑定"
    assert_equal "$CPU_THREADS" 4 "客体拓扑未使用请求 CPUS"
    assert_equal "$BOARD_MFR" QEMU "generic 平台冒充物理板厂"
    assert_equal "$PCH_MODEL" 'QEMU Q35/ICH9' "generic PCH 身份错误"
    assert_equal "$TPM_CAPABILITY" none "generic 平台不应猜测 TPM"
    [[ -z "$CPU_PART" && -z "$BIOS_VENDOR" ]] \
        || fail "未知物理字段没有按策略留空"
    cpu_arg="$(stealth_host_platform_qemu_cpu_arg)"
    [[ "$cpu_arg" == host,* && "$cpu_arg" == *',enforce=on,'* ]] \
        || fail "host CPU 参数没有强制 enforce=on: $cpu_arg"
    [[ "$cpu_arg" != *tsc-freq* ]] \
        || fail "host CPU 参数错误携带了 tsc-freq: $cpu_arg"

    fingerprint="$CPU_HOST_FINGERPRINT"
    stealth_host_platform_load compat-host-intel-q35 4
    assert_equal "$CPU_HOST_FINGERPRINT" "$fingerprint" "同宿主指纹漂移"
    STEALTH_HOST_CPU_STEPPING=2 \
        stealth_host_platform_load compat-host-intel-q35 4
    [[ "$CPU_HOST_FINGERPRINT" != "$fingerprint" ]] \
        || fail "stepping 变化未进入宿主指纹"
    STEALTH_HOST_CPU_STEPPING=0 \
        stealth_host_platform_load compat-host-intel-q35 4
    assert_equal "$CPU_HOST_STEPPING" 0 "合法 stepping 0 被错误拒绝"

    _rng_init
    serial="$(_serial_qemu)"
    [[ "$serial" =~ ^MB[0-9]{12}$ ]] \
        || fail "generic Q35 序号格式错误: $serial"
    stealth_board_serial_is_strict QEMU "$serial" \
        || fail "generic Q35 序号没有通过共享严格策略: $serial"
}

test_vendor_and_capacity_fail_closed() {
    set_e5_host
    if stealth_host_platform_load compat-host-amd-q35 4 >/dev/null 2>&1; then
        fail "Intel 宿主跨厂商加载了 AMD template"
    fi
    export STEALTH_HOST_CPU_MODEL_NAME='Intel(R) CPU E-2288G @ 3.70GHz'
    export STEALTH_HOST_CPU_CORES=4
    export STEALTH_HOST_CPU_ONLINE_THREADS=4
    if stealth_host_platform_load compat-host-intel-q35 4 >/dev/null 2>&1; then
        fail "去掉 Xeon 前缀的 Intel E 系列进入 host-passthrough"
    fi
    export STEALTH_HOST_CPU_MODEL_NAME='Intel(R) Core(TM) i3-9100F CPU @ 3.60GHz'
    export STEALTH_HOST_CPU_MODEL=158
    export STEALTH_HOST_CPU_STEPPING=10
    export STEALTH_HOST_CPU_CORES=4
    export STEALTH_HOST_CPU_ONLINE_THREADS=1
    if stealth_host_platform_load compat-host-intel-q35 2 >/dev/null 2>&1; then
        fail "Guest 超过宿主在线容量仍被放行"
    fi
    if STEALTH_KVM_TSC_KHZ=0 \
        stealth_host_platform_load compat-host-intel-q35 4 >/dev/null 2>&1; then
        fail "未知 KVM TSC 被虚构值放行"
    fi
}

test_larger_household_host_uses_bounded_guest_subset() {
    export STEALTH_HOST_CPU_VENDOR=GenuineIntel
    export STEALTH_HOST_CPU_MODEL_NAME='Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz'
    export STEALTH_HOST_CPU_FAMILY=6
    export STEALTH_HOST_CPU_MODEL=158
    export STEALTH_HOST_CPU_STEPPING=10
    export STEALTH_HOST_CPU_CORES=6
    export STEALTH_HOST_CPU_ONLINE_THREADS=12
    export STEALTH_HOST_CPU_MAX_MHZ=4500
    export STEALTH_HOST_CPU_PHYS_BITS=39
    export STEALTH_KVM_TSC_KHZ=2592000

    stealth_host_platform_load compat-host-intel-q35 4

    assert_equal "$CPU_CORES" 2 "9750H 的 4 vCPU 没有形成 2C4T 子拓扑"
    assert_equal "$CPU_THREADS" 4 "9750H 的 Guest 线程数错误"
    assert_equal "$CPU_HOST_CORES" 6 "9750H 宿主核心事实未绑定"
    assert_equal "$CPU_HOST_ONLINE_THREADS" 12 "9750H 宿主线程事实未绑定"
    assert_equal "$CPU_TSC_MHZ" 2592 "9750H TSC 没有使用宿主真值"
}

test_amd_export() {
    export STEALTH_HOST_CPU_VENDOR=AuthenticAMD
    export STEALTH_HOST_CPU_MODEL_NAME='AMD Ryzen Threadripper 1950X 16-Core Processor'
    export STEALTH_HOST_CPU_FAMILY=23
    export STEALTH_HOST_CPU_MODEL=1
    export STEALTH_HOST_CPU_STEPPING=1
    export STEALTH_HOST_CPU_CORES=4
    export STEALTH_HOST_CPU_ONLINE_THREADS=4
    export STEALTH_HOST_CPU_MAX_MHZ=3400
    export STEALTH_HOST_CPU_PHYS_BITS=43
    export STEALTH_KVM_TSC_KHZ=3100000

    if stealth_host_platform_load compat-host-amd-q35 4 >/dev/null 2>&1; then
        fail "Threadripper 进入家用 host-passthrough"
    fi
    export STEALTH_HOST_CPU_MODEL_NAME='AMD Ryzen 3 1200 Quad-Core Processor'
    stealth_host_platform_load compat-host-amd-q35 4
    assert_equal "$PLATFORM_ID" compat-host-amd-q35 "AMD template ID 错误"
    assert_equal "$CPU_VENDOR" AuthenticAMD "AMD 厂商错误"
    assert_equal "$CPU_NAME" 'AMD Ryzen 3 1200 Quad-Core Processor' \
        "AMD host brand 未持久投影"
    assert_equal "$CPU_QEMU_ARG" host "AMD 兜底未使用 host"
}

test_manifest_and_index
test_household_export_is_stable_and_truthful
test_vendor_and_capacity_fail_closed
test_larger_household_host_uses_bounded_guest_subset
test_amd_export
echo "OK: host compatibility platform checks passed"
