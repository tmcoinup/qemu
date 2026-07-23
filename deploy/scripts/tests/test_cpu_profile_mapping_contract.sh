#!/usr/bin/env bash
# 三种 Guest 身份拓扑与宿主同拓扑映射的端到端契约。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
START_VM="$REPO_ROOT/deploy/scripts/start-vm.sh"
CPUPIN="$REPO_ROOT/deploy/scripts/lib/sv-cpupin.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

run_profile() {
    local record="$1" platform cpus cores total_threads guest_tpc host_tpc instance
    local output smp packing expected_smp expected_tuple
    IFS='|' read -r platform cpus cores total_threads guest_tpc host_tpc instance <<<"$record"
    output="$TMP_DIR/$instance.argv"
    env IMAGE_ROOT="$TMP_DIR/images" DRY_RUN=1 TPM=0 HOST_TUNE=0 CPU_ISOLATE=0 \
        QEMU_CAP_CHECK=0 STRICT_HARDWARE=0 STEALTH_HOST_PROBE_TEST_MODE=1 \
        STEALTH_KVM_AVAILABLE=1 STEALTH_KVM_TSC_CONTROL=1 \
        STEALTH_KVM_GET_TSC_KHZ=1 STEALTH_KVM_TSC_KHZ=2195000 \
        STEALTH_HOST_CPU_VENDOR=GenuineIntel STEALTH_HOST_CPU_FAMILY=6 \
        STEALTH_HOST_CPU_MODEL=79 STEALTH_HOST_CPU_MAX_MHZ=3700 \
        STEALTH_HOST_CPU_CORES=22 STEALTH_HOST_CPU_ONLINE_THREADS=44 \
        STEALTH_HOST_CPU_PHYS_BITS=46 STEALTH_PLATFORM_ID="$platform" \
        ALLOW_PLATFORM_COMPATIBILITY=0 CPUS="$cpus" \
        "$START_VM" "$instance" --no-sdl --no-fb-shm --no-bridge >"$output"

    smp="$(awk '$0 == "-smp" { getline; print; exit }' "$output")"
    expected_smp="cpus=$cpus,cores=$cores,threads=$guest_tpc,sockets=1,maxcpus=$cpus"
    [[ "$smp" == "$expected_smp" ]] \
        || fail "$platform Guest -smp 漂移: expected=$expected_smp actual=$smp"
    (( total_threads == cpus && total_threads / cores == guest_tpc )) \
        || fail "$platform 测试拓扑自相矛盾"

    # shellcheck disable=SC2016 # $1 必须由内层 bash 从位置参数展开。
    packing="$(env CPU_ISOLATE=0 DRY_RUN=0 STRICT_HARDWARE=1 \
        HERE="$REPO_ROOT/deploy/scripts" CPUS="$cpus" CPU_CORES="$cores" \
        CPU_THREADS="$total_threads" bash -c \
        'source "$1"; sv_cpu_host_threads_per_core' _ "$CPUPIN")"
    expected_tuple="$cpus/$guest_tpc/$host_tpc"
    [[ "$cpus/$guest_tpc/$packing" == "$expected_tuple" ]] \
        || fail "$platform pinner 映射漂移: expected=$expected_tuple actual=$cpus/$guest_tpc/$packing"
}

profiles=(
    'compat-haswell-g3220-h81|2|2|2|1|1|9761'
    'compat-haswell-i3-4130-h81|4|2|4|2|2|9762'
    'compat-haswell-i5-4570-h81|4|4|4|1|1|9763'
)
for profile in "${profiles[@]}"; do run_profile "$profile"; done
# shellcheck disable=SC2016 # 断言源码中的正则字面量，不能展开 $INSTANCE。
grep -F -- 'if ! [[ "$INSTANCE" =~ ^[1-9][0-9]{0,9}$ ]]' \
    "$REPO_ROOT/deploy/scripts/lib/sv-cli.sh" >/dev/null || fail "启动实例号契约未统一"
echo "PASS: 2C2T/2C4T/4C4T Guest identity and host packing contract"
