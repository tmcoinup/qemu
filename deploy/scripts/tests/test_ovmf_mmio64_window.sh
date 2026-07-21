#!/usr/bin/env bash
# 验证 OVMF MMIO64 稳定性护栏同时覆盖安装与日常磁盘启动。
#
# G5400 profile 向 guest 暴露 39-bit 物理地址。OVMF 默认会据此选择顶端动态
# MMIO64 窗口；曾在 Windows 安装 warm reboot 后观察到 aperture Base 污染，
# 令 PciHostBridgeDxe 卡在 GCD 校验循环。启动器必须通过 fw_cfg 固定 32 GiB
# 低位窗口，并且不能因 stock/custom OVMF 或 ISO/disk 模式不同而漏掉该参数。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
START_VM="$REPO_ROOT/deploy/scripts/start-vm.sh"
PLATFORM_ID="intel-lga1151-pentium-g5400-asus-prime-h310m-a-r2"
MMIO64_KEY="name=opt/ovmf/X-PciMmio64Mb,string="
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

run_dry() {
    local instance="$1"
    local output="$2"
    shift 2

    env \
        IMAGE_ROOT="$TMP_DIR/images" \
        DISPLAY=:0 \
        DRY_RUN=1 \
        TPM=0 \
        HOST_TUNE=0 \
        CPU_ISOLATE=0 \
        QEMU_CAP_CHECK=0 \
        STABLE_DISPLAY=0 \
        STRICT_HARDWARE=0 \
        STEALTH_KVM_AVAILABLE=1 \
        STEALTH_KVM_TSC_CONTROL=1 \
        STEALTH_KVM_GET_TSC_KHZ=1 \
        STEALTH_KVM_TSC_KHZ=3700000 \
        STEALTH_HOST_CPU_VENDOR=GenuineIntel \
        STEALTH_HOST_CPU_MAX_MHZ=5000 \
        "$START_VM" "$instance" --platform-id="$PLATFORM_ID" \
        --no-bridge "$@" >"$output" 2>&1
}

assert_guard() {
    local output="$1"
    local mode="$2"
    local value
    local gpu
    local hostmem_mb

    [[ "$(grep -Fc -- "$MMIO64_KEY" "$output")" == 1 ]] \
        || fail "$mode 启动缺少唯一的 OVMF MMIO64 配置"
    awk -v target="${MMIO64_KEY}32768" '
        previous == "-fw_cfg" && $0 == target { found++ }
        { previous = $0 }
        END { exit(found == 1 ? 0 : 1) }
    ' "$output" \
        || fail "$mode 启动没有把 OVMF MMIO64 配置作为完整 fw_cfg argv"

    value="$(
        awk -v prefix="$MMIO64_KEY" \
            'index($0, prefix) == 1 { print substr($0, length(prefix) + 1) }' \
            "$output"
    )"
    [[ "$value" =~ ^[0-9]+$ ]] \
        || fail "$mode 启动的 MMIO64 MiB 值非法: $value"
    (( value == 32768 )) \
        || fail "$mode 启动没有固定 32768 MiB 窗口: $value"

    grep -F -- "host-phys-bits-limit=39" "$output" >/dev/null \
        || fail "$mode 用例没有覆盖现场的 39-bit CPU profile"
    # 中文注释：默认显示现已不分配 hostmem BAR；本测试在 run_dry 中显式
    # opt-in GL，继续验证最坏情况下 OVMF 固定窗口能容纳该 BAR。
    gpu="$(grep -E '^virtio-vga-gl,' "$output" | head -n 1)"
    [[ "$gpu" =~ hostmem=([0-9]+)M ]] \
        || fail "$mode 用例没有覆盖 virtio-vga-gl hostmem BAR"
    hostmem_mb="${BASH_REMATCH[1]}"
    (( value > hostmem_mb )) \
        || fail "$mode 的 MMIO64 窗口不足以容纳 hostmem BAR"
}

main() {
    local disk_output="$TMP_DIR/disk.argv"
    local iso_output="$TMP_DIR/iso.argv"

    [[ -x "$START_VM" ]] || fail "missing executable: $START_VM"

    run_dry 9921 "$disk_output"
    run_dry 9922 "$iso_output" --iso="$TMP_DIR/win10.iso"

    assert_guard "$disk_output" "disk"
    assert_guard "$iso_output" "iso"
    grep -F -- "file=/usr/share/OVMF/OVMF_CODE_4M.fd" "$iso_output" >/dev/null \
        || fail "ISO 模式没有覆盖 stock OVMF"
    grep -F -- "OVMF_CODE_4M_stealth.fd" "$disk_output" >/dev/null \
        || fail "disk 模式没有覆盖 custom OVMF"

    [[ ! -e "$TMP_DIR/images/vms" ]] \
        || fail "DRY_RUN 意外创建了 VM 数据目录"
    echo "PASS: OVMF MMIO64 window guard covers disk and ISO boot"
}

main "$@"
