#!/usr/bin/env bash
# 验证 V-11 手选 CPU 无法实现时，仍会落到同厂商的大宿主受控兜底。
# shellcheck disable=SC1091
set -euo pipefail
export STEALTH_HOST_PROBE_TEST_MODE=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=../stealth-lib.sh
source "$REPO_ROOT/deploy/scripts/stealth-lib.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_contains() {
    local text="$1" wanted="$2" message="$3"
    [[ "$text" == *"$wanted"* ]] || fail "$message: missing '$wanted'"
}

export STEALTH_HOST_CPU_VENDOR=GenuineIntel
export STEALTH_HOST_CPU_FAMILY=6
export STEALTH_HOST_CPU_MODEL=158
export STEALTH_HOST_CPU_MODEL_NAME="Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz"
export STEALTH_HOST_CPU_STEPPING=10
export STEALTH_HOST_CPU_MAX_MHZ=4500
export STEALTH_HOST_CPU_CORES=6
export STEALTH_HOST_CPU_ONLINE_THREADS=12
export STEALTH_HOST_CPU_PHYS_BITS=39
export STEALTH_KVM_TSC_CONTROL=0
export STEALTH_KVM_TSC_KHZ=2592000
export STEALTH_REQUIRED_TSC_MHZ=2592
export STRICT_HARDWARE=1
export STEALTH_TSC_POLICY=auto
export CPUS=4
export MEM_TOTAL_MB=8192
export ALLOW_PLATFORM_COMPATIBILITY=1
export STEALTH_PLATFORM_ID=intel-lga1151-i5-6400t-asus-h110m-a-m2
export STEALTH_MEMORY_ID=samsung-m378a5244cb0-crc-ddr4-4g
export STEALTH_STORAGE_ID=samsung-970-pro-512gb
export STEALTH_GPU_ID=asus-ph-gtx1050ti-4g
export STEALTH_MONITOR_ID=samsung-s24f350
export STEALTH_SEED=43
_rng_init

# 2200MHz 首选项先由 TSC 门禁拒绝；其余命名候选也模拟为无法 realize，最终
# 只允许保留宿主真值的 Q35 host-passthrough 兜底通过。
sv_validate_cpu_phys_bits() {
    [[ "${CPU_PHYS_BITS:-0}" =~ ^[0-9]+$ ]]
}

sv_validate_cpu_realize() {
    [[ "${CPU_QEMU_ARG:-}" == host ]]
}

output_log="$(mktemp)"
if ! stealth_pick_profile 2>"$output_log"; then
    output="$(sed -n '1,80p' "$output_log")"
    rm -f -- "$output_log"
    fail "9750H 首选平台失败后没有进入最终兜底: $output"
fi
output="$(sed -n '1,80p' "$output_log")"
rm -f -- "$output_log"

[[ "$PLATFORM_ID" == compat-host-intel-q35 &&
   "$CPU_CORES" == 2 && "$CPU_THREADS" == 4 ]] ||
    fail "9750H 最终兜底平台或拓扑错误: $PLATFORM_ID ${CPU_CORES}C${CPU_THREADS}T"
[[ -z "$STEALTH_MEMORY_ID" ]] || fail "切换兜底平台后仍保留首选平台 DIMM"
[[ -n "$MEM_MODULE_ID" && "$NVME_COMPONENT_ID" == "$STEALTH_STORAGE_ID" &&
   "$GPU_COMPONENT_ID" == "$STEALTH_GPU_ID" &&
   "$EDID_COMPONENT_ID" == "$STEALTH_MONITOR_ID" ]] ||
    fail "兜底后未生成容量一致的完整部件 profile"
assert_contains "$output" "正在尝试受控兜底候选" "首选平台失败没有给出兜底进度"

echo "OK: V-11 selected CPU controlled fallback checks passed"
