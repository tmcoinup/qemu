#!/usr/bin/env bash
# shellcheck shell=bash disable=SC1091,SC2034
# 端到端验证启动器按随机平台的 TPM 能力、版本和前端动态组装 QEMU 参数。
# 测试只执行 DRY_RUN；临时 swtpm 工具替身仅用于证明完整可用性分支会被选择。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
START_VM="$REPO_ROOT/deploy/scripts/start-vm.sh"
PLATFORM_MANIFEST="$REPO_ROOT/deploy/hardware/platforms.json"
H310_PLATFORM_ID="intel-lga1151-i3-9100f-asus-prime-h310m-a-r2"
H110_PLATFORM_ID="intel-lga1151-i5-6400t-asus-h110m-a-m2"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

STUB_BIN="$TMP_DIR/stub-bin"
mkdir -p "$STUB_BIN"
for tool in swtpm swtpm_setup swtpm_localca; do
    ln -s /bin/true "$STUB_BIN/$tool"
done

COMMON_ENV=(
    "PATH=$STUB_BIN:$PATH"
    "IMAGE_ROOT=$TMP_DIR/images"
    "DRY_RUN=1"
    "HOST_TUNE=0"
    "CPU_ISOLATE=0"
    "QEMU_CAP_CHECK=0"
    "STRICT_HARDWARE=0"
    "STEALTH_KVM_AVAILABLE=1"
    "STEALTH_KVM_TSC_CONTROL=1"
    "STEALTH_KVM_GET_TSC_KHZ=1"
    "STEALTH_KVM_TSC_KHZ=3600000"
    "STEALTH_HOST_CPU_PHYS_BITS=48"
    "STEALTH_HOST_CPU_VENDOR=GenuineIntel"
    "STEALTH_HOST_CPU_MAX_MHZ=5000"
    "CPUS=4"
)

run_dry_start() {
    local platform_id="$1"
    local tpm_mode="$2"
    local instance="$3"
    local output="$4"
    env "${COMMON_ENV[@]}" \
        "STEALTH_PLATFORM_MANIFEST=$PLATFORM_MANIFEST" \
        "STEALTH_PLATFORM_ID=$platform_id" \
        "TPM=$tpm_mode" \
        "$START_VM" "$instance" --no-sdl --no-fb-shm --no-bridge \
        >"$output" 2>&1
}

assert_complete() {
    local output="$1"
    grep -Fx -- "__DRY_RUN_ARGV__" "$output" >/dev/null \
        || fail "DRY_RUN 未完成 QEMU argv 组装: $output"
}

assert_frontend() {
    local output="$1"
    local frontend="$2"
    grep -F -- "socket,id=chrtpm,path=" "$output" >/dev/null \
        || fail "缺少 swtpm chardev: $output"
    grep -Fx -- "emulator,id=tpm0,chardev=chrtpm" "$output" >/dev/null \
        || fail "缺少 swtpm emulator backend: $output"
    grep -Fx -- "$frontend,tpmdev=tpm0" "$output" >/dev/null \
        || fail "TPM frontend 不是 $frontend: $output"
}

assert_no_tpm_device() {
    local output="$1"
    if grep -F -- "socket,id=chrtpm,path=" "$output" >/dev/null ||
       grep -Fx -- "emulator,id=tpm0,chardev=chrtpm" "$output" >/dev/null ||
       grep -Ex -- 'tpm-(crb|tis),tpmdev=tpm0' "$output" >/dev/null; then
        fail "不应启用 TPM 的场景仍生成了 guest device: $output"
    fi
}

# 1.2/TIS 当前没有真实平台条目，因此只在 sv-tpm-mem 映射层构造显式输入。
# 该 fixture 先加载一份通过完整 digest 的 H310 基础硬件事实，再只覆盖模块自身
# 的六项 TPM 输入；它不生成伪造 manifest，也不会绕过 validator 启动 VM。
run_tpm12_module_fixture() (
    set -euo pipefail
    export PATH="$STUB_BIN:$PATH"
    export STEALTH_PLATFORM_MANIFEST="$PLATFORM_MANIFEST"
    export STRICT_HARDWARE=1 ALLOW_PLATFORM_COMPATIBILITY=0
    source "$REPO_ROOT/deploy/scripts/stealth-lib.sh"
    stealth_platform_load "$H310_PLATFORM_ID"

    HERE="$REPO_ROOT/deploy/scripts"
    VM_DIR="$TMP_DIR/module-vm"
    INSTANCE=9763
    DRY_RUN=1
    RAM=4096
    TPM=auto
    PLATFORM_ID="tpm12-discrete-module-fixture"
    TPM_CAPABILITY=discrete
    TPM_SUPPORTED=1
    TPM_IMPLEMENTATION=discrete-module
    TPM_VERSION=1.2
    TPM_FRONTEND=tpm-tis
    TPM_PCR_BANKS=sha1

    SYSTEM_MFR="$BOARD_MFR"
    SYSTEM_VERSION="System Version"
    SYSTEM_SERIAL="SYS123456789"
    SYSTEM_SKU="SKU1234"
    BOARD_SERIAL="MB123456789"
    BOARD_ASSET="Default string"
    CHASSIS_SERIAL="CH123456789"
    CHASSIS_TYPE=Desktop
    CPU_SERIAL="CPU123456789"
    CPU_ASSET=1234
    UUID="12345678-1234-4234-8234-123456789abc"
    MEM_MFR=Kingston
    MEM_SERIAL=A1B2C3D4
    MEM_PART_2G="KVR24N17S6/2"
    MEM_PART_4G="KVR24N17S8/4"
    MEM_RANK_2G=1
    MEM_RANK_4G=1
    MEM_DEVICE_WIDTH_2G=8
    MEM_DEVICE_WIDTH_4G=8
    MEM_RATED_MTS=2400
    MEM_CONFIGURED_MTS=2400

    source "$REPO_ROOT/deploy/scripts/lib/sv-tpm-mem.sh"
    printf '__TPM12_STATE__=%s\n' "$TPM_STATE_BASENAME"
    printf '%s\n' "${TPM_ARGS[@]}"
)

# 当前 H310 平台声明 PTT 2.0 + CRB；auto 必须消费平台事实，而非硬编码全局默认。
CURRENT_AUTO_OUT="$TMP_DIR/current-auto.out"
run_dry_start "$H310_PLATFORM_ID" auto 9761 "$CURRENT_AUTO_OUT"
assert_complete "$CURRENT_AUTO_OUT"
assert_frontend "$CURRENT_AUTO_OUT" tpm-crb

# 用户显式 TPM=0 的优先级高于主板支持能力，完整启动仍不得带 TPM 参数。
DISABLED_OUT="$TMP_DIR/disabled.out"
run_dry_start "$H310_PLATFORM_ID" 0 9762 "$DISABLED_OUT"
assert_complete "$DISABLED_OUT"
assert_no_tpm_device "$DISABLED_OUT"

# 显式模块 fixture 保留离散 TPM 1.2 到 TIS 及独立 state 文件名的覆盖。
TPM12_OUT="$TMP_DIR/tpm12-module.out"
run_tpm12_module_fixture >"$TPM12_OUT" 2>&1
assert_frontend "$TPM12_OUT" tpm-tis
grep -Fx -- "__TPM12_STATE__=tpm-00.permall" "$TPM12_OUT" >/dev/null \
    || fail "TPM 1.2 未选择独立的 tpm-00.permall state"
if grep -Fx -- "tpm-crb,tpmdev=tpm0" "$TPM12_OUT" >/dev/null; then
    fail "TPM 1.2 错误生成了 CRB 前端"
fi

# 真实 H110 平台完整声明无 TPM；auto 应自然无设备，TPM=1 必须 fail closed。
UNSUPPORTED_AUTO_OUT="$TMP_DIR/unsupported-auto.out"
run_dry_start "$H110_PLATFORM_ID" auto 9764 "$UNSUPPORTED_AUTO_OUT"
assert_complete "$UNSUPPORTED_AUTO_OUT"
assert_no_tpm_device "$UNSUPPORTED_AUTO_OUT"

UNSUPPORTED_FORCED_OUT="$TMP_DIR/unsupported-forced.out"
if run_dry_start "$H110_PLATFORM_ID" 1 9765 "$UNSUPPORTED_FORCED_OUT"; then
    fail "H110 无 TPM 平台接受了 TPM=1"
fi
if grep -Fx -- "__DRY_RUN_ARGV__" "$UNSUPPORTED_FORCED_OUT" >/dev/null; then
    fail "H110 无 TPM 平台在拒绝前仍完成了 QEMU argv"
fi

# TPM 是三态策略，只接受 auto/0/1；其它拼写不能被当成 auto 或 truthy 值。
INVALID_OUT="$TMP_DIR/invalid.out"
if run_dry_start "$H310_PLATFORM_ID" 2 9766 "$INVALID_OUT"; then
    fail "非法 TPM 值被接受"
fi

[[ ! -e "$TMP_DIR/images/vms" ]] || fail "TPM DRY_RUN 写入了实例目录"
echo "OK: TPM adapts to platform capability, version, and frontend"
