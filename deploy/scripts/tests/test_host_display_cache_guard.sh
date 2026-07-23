#!/usr/bin/env bash
# 离线显示缓存工具必须与 start/stop 共用目标 VM 用户实例锁，并在写 hive 前复核 profile。
# shellcheck disable=SC2016 # fixture 与静态模式需要保留 $var 字面量。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
HOST_FIX="$REPO_ROOT/deploy/scripts/host-fix-display-cache.sh"
GUARD_LIB="$REPO_ROOT/deploy/scripts/lib/host-display-cache-guard.sh"
LOCK_LIB="$REPO_ROOT/deploy/scripts/lib/sv-instance-lock.sh"
LIFECYCLE_LIB="$REPO_ROOT/deploy/scripts/lib/clone-lifecycle.sh"
TMP_DIR="$(mktemp -d)"
INSTANCE="$((9900000000 + ($$ % 99999999)))"
TEST_LOCK=""

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

cleanup() {
    exec 8<&- 2>/dev/null || true
    [[ -z "${TEST_LOCK:-}" ]] || rm -f -- "$TEST_LOCK"
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# shellcheck source=/dev/null
source "$GUARD_LIB"
# shellcheck source=/dev/null
source "$LOCK_LIB"
# 只使用摘要函数，不调用 profile 保存路径。
# shellcheck source=/dev/null
source "$REPO_ROOT/deploy/scripts/lib/stealth-profile-save.sh"

VM_DIR="$TMP_DIR/vms/$INSTANCE"
mkdir -p "$VM_DIR"

# 受控 sudo fixture 保留当前 UID，但严格验证 guard 确实按 SUDO_USER 降权调用
# clone helper；该 helper 再调用生产 sv_instance_lock_path。
FAKE_BIN="$TMP_DIR/fake-bin"
mkdir -p "$FAKE_BIN"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    '[[ "${1:-}" == -u && "${3:-}" == -- ]] || exit 90' \
    '[[ "$2" == "${EXPECTED_VM_USER:?}" ]] || exit 91' \
    'shift 3' \
    'exec "$@"' >"$FAKE_BIN/sudo"
chmod 0755 "$FAKE_BIN/sudo"

EXPECTED_VM_USER="$(id -un)"
export EXPECTED_VM_USER
SUDO_USER="$EXPECTED_VM_USER"
export SUDO_USER
unset PKEXEC_UID
ORIGINAL_PATH="$PATH"
PATH="$FAKE_BIN:$PATH"
export PATH
host_display_cache_acquire_instance_lock \
    "$INSTANCE" "$VM_DIR" "$LOCK_LIB" "$LIFECYCLE_LIB" ||
    fail "无法取得测试实例生命周期锁"
PATH="$ORIGINAL_PATH"
export PATH

TEST_LOCK="$(sv_instance_lock_path "$INSTANCE")" ||
    fail "sv-cli 锁路径函数无法解析测试实例"
[[ "$HOST_DISPLAY_INSTANCE_LOCK" == "$TEST_LOCK" ]] ||
    fail "离线工具锁路径与 sv_instance_lock_path 分叉"
[[ "$HOST_DISPLAY_VM_USER" == "$EXPECTED_VM_USER" &&
   "$HOST_DISPLAY_VM_UID" == "$UID" ]] ||
    fail "离线工具没有锁定 SUDO_USER/VM 目录所有者"
[[ "$TEST_LOCK" -ef "/proc/$$/fd/8" ]] ||
    fail "FD 8 没有持有最终 VM 用户的实例锁"

CONTENDER_LOG="$TMP_DIR/contender.log"
if (
    exec 8<&-
    PATH="$FAKE_BIN:$ORIGINAL_PATH"
    export PATH
    host_display_cache_acquire_instance_lock \
        "$INSTANCE" "$VM_DIR" "$LOCK_LIB" "$LIFECYCLE_LIB"
) >"$CONTENDER_LOG" 2>&1; then
    fail "第二个离线维护进程绕过了实例生命周期 flock"
fi
grep -F "实例 $INSTANCE 正在启动、运行、停止或执行离线维护" \
        "$CONTENDER_LOG" >/dev/null ||
    fail "锁竞争失败没有给出生命周期冲突原因"

# 故障注入：读取后替换 profile，写 hive 前摘要门禁必须失败。
PROFILE="$VM_DIR/profile"
printf '%s\n' 'EDID_COMPONENT_ID=samsung-s24f350' >"$PROFILE"
PROFILE_HASH="$(stealth_profile_sha256 "$PROFILE")" ||
    fail "无法计算测试 profile 摘要"
host_display_cache_require_profile_hash "$PROFILE" "$PROFILE_HASH" ||
    fail "未变化 profile 被摘要门禁误拒绝"
printf '%s\n' 'EDID_COMPONENT_ID=aoc-24b2w1g5' >"$PROFILE"
if host_display_cache_require_profile_hash "$PROFILE" "$PROFILE_HASH"; then
    fail "profile 变化后仍通过写 hive 前摘要门禁"
fi

# 静态顺序同时约束未来重构：锁先于 disk/profile/运行检查；初始 hash 先于字段
# 读取；复核位于 SYSTEM hive 定位之后、第一次写 hive 的 Python 之前。
line_of() {
    grep -nF "$1" "$HOST_FIX" | head -n1 | cut -d: -f1
}
LOCK_LINE="$(line_of 'host_display_cache_acquire_instance_lock')"
DISK_LINE="$(line_of '[[ -f "$DISK" && ! -L "$DISK" ]]')"
RUNNING_LINE="$(line_of 'if pgrep -af "qemu-system-x86_64"')"
HASH_LINE="$(line_of 'PROFILE_HASH_BEFORE="$(stealth_profile_sha256')"
GET_LINE="$(line_of 'EDID_COMPONENT_ID="$(stealth_profile_get')"
HIVE_LINE="$(line_of 'HIVE="${MOUNT}/Windows/System32/config/SYSTEM"')"
RECHECK_LINE="$(line_of 'host_display_cache_require_profile_hash "$PROFILE"')"
WRITE_LINE="$(line_of 'python3 - "$HIVE" <<')"
[[ "$LOCK_LINE" -lt "$DISK_LINE" && "$LOCK_LINE" -lt "$RUNNING_LINE" ]] ||
    fail "离线工具在实例锁之前读取磁盘或执行运行检查"
[[ "$HASH_LINE" -lt "$GET_LINE" ]] ||
    fail "离线工具没有在 profile 字段读取前记录初始摘要"
[[ "$HIVE_LINE" -lt "$RECHECK_LINE" && "$RECHECK_LINE" -lt "$WRITE_LINE" ]] ||
    fail "profile 摘要复核不在首次 hive 写入之前"

exec 8<&-
if ! (
    exec 9<"$TEST_LOCK"
    flock -n 9
); then
    fail "主进程释放 FD 8 后生命周期锁仍被意外持有"
fi

echo "PASS: host display cache lifecycle guard"
