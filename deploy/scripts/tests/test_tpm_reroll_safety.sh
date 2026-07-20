#!/usr/bin/env bash
# 验证持久 TPM state 在 reroll 入口下不会失去旧 profile 或被另一身份接管。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
START_VM="$REPO_ROOT/deploy/scripts/start-vm.sh"
REROLL_HELPER="$REPO_ROOT/deploy/scripts/reroll-identity.sh"
PLATFORM_ID="intel-lga1151-i5-6400t-asus-h110m-a-m2"
INSTANCE=9781
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

IMAGE_ROOT="$TMP_DIR/images"
VMS_DIR="$IMAGE_ROOT/vms"
VM_DIR="$VMS_DIR/$INSTANCE"
PROFILE_FILE="$VM_DIR/profile"
STATE_FILE="$VM_DIR/tpm-state/tpm2-00.permall"
mkdir -p "$VM_DIR/tpm-state"
chmod 700 "$IMAGE_ROOT" "$VMS_DIR" "$VM_DIR" "$VM_DIR/tpm-state"

# 生成一份真实 schema-1 profile，再放入已有永久 state。
(
    export STEALTH_PLATFORM_ID="$PLATFORM_ID"
    export STEALTH_HOST_CPU_VENDOR=GenuineIntel
    export STEALTH_HOST_CPU_MAX_MHZ=5000
    export STEALTH_REQUIRED_TSC_MHZ=2200
    export CPUS=4
    unset MEM_TOTAL_MB
    # shellcheck source=../stealth-lib.sh disable=SC1091
    source "$REPO_ROOT/deploy/scripts/stealth-lib.sh"
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/fixtures/catalog-cpu-preflight-stub.sh"
    stealth_pick_profile >/dev/null
    stealth_save_profile "$PROFILE_FILE"
)
truncate -s 4096 "$STATE_FILE"
chmod 600 "$STATE_FILE"
profile_hash="$(sha256sum "$PROFILE_FILE")"
state_hash="$(sha256sum "$STATE_FILE")"

# 旧 helper 现在只能给出安全命令，不能再先删除 profile。
helper_log="$TMP_DIR/helper.log"
if VMS_DIR="$VMS_DIR" "$REROLL_HELPER" "$INSTANCE" \
    >"$helper_log" 2>&1; then
    fail "reroll-identity.sh 仍报告破坏性删除成功"
fi
grep -F '已拒绝删除' "$helper_log" >/dev/null \
    || fail "reroll helper 没有解释非破坏性门禁"
[[ "$(sha256sum "$PROFILE_FILE")" == "$profile_hash" ]] \
    || fail "reroll helper 修改了旧 profile"
[[ "$(sha256sum "$STATE_FILE")" == "$state_hash" ]] \
    || fail "reroll helper 修改了旧 TPM state"

# 正式 --reroll 也必须在选择新平台或写入任何状态前失败。
start_log="$TMP_DIR/start.log"
if env \
    IMAGE_ROOT="$IMAGE_ROOT" \
    DRY_RUN=1 \
    HOST_TUNE=0 \
    CPU_ISOLATE=0 \
    QEMU_CAP_CHECK=0 \
    STRICT_HARDWARE=0 \
    STEALTH_KVM_AVAILABLE=1 \
    STEALTH_KVM_TSC_CONTROL=1 \
    STEALTH_KVM_GET_TSC_KHZ=1 \
    STEALTH_KVM_TSC_KHZ=2200000 \
    STEALTH_HOST_CPU_PHYS_BITS=48 \
    STEALTH_HOST_CPU_VENDOR=GenuineIntel \
    STEALTH_HOST_CPU_MAX_MHZ=5000 \
    CPUS=4 \
    "$START_VM" "$INSTANCE" --reroll --no-sdl --no-fb-shm --no-bridge \
    >"$start_log" 2>&1; then
    fail "已有 TPM state 时 --reroll 被接受"
fi
grep -F '实例已有 TPM state，拒绝 reroll' "$start_log" >/dev/null \
    || fail "start-vm 没有命中 TPM reroll 门禁"
[[ "$(sha256sum "$PROFILE_FILE")" == "$profile_hash" ]] \
    || fail "start-vm reroll 失败后修改了旧 profile"
[[ "$(sha256sum "$STATE_FILE")" == "$state_hash" ]] \
    || fail "start-vm reroll 失败后修改了旧 TPM state"

echo "OK: TPM state blocks destructive identity reroll"
