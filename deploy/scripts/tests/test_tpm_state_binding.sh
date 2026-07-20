#!/usr/bin/env bash
# 验证 swtpm 永久状态只能被创建它的平台和 TPM 画像复用。
# shellcheck disable=SC1091
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

source "$REPO_ROOT/deploy/scripts/lib/sv-swtpm-lifecycle.sh"
source "$REPO_ROOT/deploy/scripts/lib/sv-tpm-binding.sh"

PLATFORM_A="intel-lga1151-i5-6400t-asus-h110m-a-m2"
PLATFORM_B="intel-lga1151-i3-9100f-asus-prime-h310m-a-r2"

prepare_state_dir() {
    local name="$1"
    local root="$TMP_DIR/$name"

    mkdir -m 700 "$root"
    sv_swtpm_prepare_state_dir "$root/tpm-state"
}

# 新 state 可直接绑定；重复绑定幂等，平台变化不得覆盖原文件。
NEW_STATE_DIR="$(prepare_state_dir new)"
NEW_STATE_FILE="$NEW_STATE_DIR/tpm2-00.permall"
sv_tpm_bind_state "$NEW_STATE_DIR" "$NEW_STATE_FILE" \
    "$PLATFORM_A" firmware intel-ptt 2.0 tpm-crb sha256
[[ "$(stat -c '%a' "$NEW_STATE_DIR/platform-binding")" == 600 ]] \
    || fail "新绑定权限不是 0600"
grep -Fx "platform_id=$PLATFORM_A" "$NEW_STATE_DIR/platform-binding" >/dev/null \
    || fail "新绑定没有记录平台 ID"
binding_hash="$(sha256sum "$NEW_STATE_DIR/platform-binding")"
sv_tpm_bind_state "$NEW_STATE_DIR" "$NEW_STATE_FILE" \
    "$PLATFORM_A" firmware intel-ptt 2.0 tpm-crb sha256
if sv_tpm_bind_state "$NEW_STATE_DIR" "$NEW_STATE_FILE" \
    "$PLATFORM_B" firmware intel-ptt 2.0 tpm-crb sha256 2>/dev/null; then
    fail "已有 state 接受了另一平台"
fi
[[ "$(sha256sum "$NEW_STATE_DIR/platform-binding")" == "$binding_hash" ]] \
    || fail "平台不匹配时绑定文件被改写"

# 升级前的 2.0/CRB state 只有在磁盘原 profile 与当前平台相同时才可接管。
LEGACY_OK_DIR="$(prepare_state_dir legacy-ok)"
LEGACY_OK_FILE="$LEGACY_OK_DIR/tpm2-00.permall"
truncate -s 4096 "$LEGACY_OK_FILE"
chmod 640 "$LEGACY_OK_FILE"
legacy_hash="$(sha256sum "$LEGACY_OK_FILE")"
sv_tpm_bind_state "$LEGACY_OK_DIR" "$LEGACY_OK_FILE" \
    "$PLATFORM_A" firmware intel-ptt 2.0 tpm-crb sha256 "$PLATFORM_A"
[[ "$(stat -c '%a' "$LEGACY_OK_FILE")" == 600 ]] \
    || fail "旧 0640 state 未收紧为 0600"
[[ "$(sha256sum "$LEGACY_OK_FILE")" == "$legacy_hash" ]] \
    || fail "收紧旧 state 权限时改动了密钥内容"

LEGACY_BAD_DIR="$(prepare_state_dir legacy-bad)"
LEGACY_BAD_FILE="$LEGACY_BAD_DIR/tpm2-00.permall"
truncate -s 4096 "$LEGACY_BAD_FILE"
chmod 640 "$LEGACY_BAD_FILE"
if sv_tpm_bind_state "$LEGACY_BAD_DIR" "$LEGACY_BAD_FILE" \
    "$PLATFORM_B" firmware intel-ptt 2.0 tpm-crb sha256 "$PLATFORM_A" \
    2>/dev/null; then
    fail "旧 state 在原 profile 与当前平台不同时被接管"
fi
[[ ! -e "$LEGACY_BAD_DIR/platform-binding" ]] \
    || fail "拒绝旧 state 后仍写入了绑定"
[[ "$(stat -c '%a' "$LEGACY_BAD_FILE")" == 640 ]] \
    || fail "平台不匹配时仍修改了旧 state 元数据"

# 旧启动器从未创建 1.2 state，因此不能猜测一个无绑定的 1.2 文件来源。
LEGACY_12_ROOT="$TMP_DIR/legacy-12"
mkdir -m 700 "$LEGACY_12_ROOT"
LEGACY_12_DIR="$(sv_swtpm_prepare_state_dir "$LEGACY_12_ROOT/tpm12-state")"
LEGACY_12_FILE="$LEGACY_12_DIR/tpm-00.permall"
truncate -s 2048 "$LEGACY_12_FILE"
chmod 600 "$LEGACY_12_FILE"
if sv_tpm_bind_state "$LEGACY_12_DIR" "$LEGACY_12_FILE" \
    "$PLATFORM_A" discrete discrete-module 1.2 tpm-tis sha1 "$PLATFORM_A" \
    2>/dev/null; then
    fail "无绑定的既有 TPM 1.2 state 被错误推断"
fi

# 文件类型、权限和版本/PCR 组合都要在写入绑定前 fail closed。
UNSAFE_DIR="$(prepare_state_dir unsafe)"
UNSAFE_FILE="$UNSAFE_DIR/tpm2-00.permall"
ln -s /dev/null "$UNSAFE_FILE"
if sv_tpm_bind_state "$UNSAFE_DIR" "$UNSAFE_FILE" \
    "$PLATFORM_A" firmware intel-ptt 2.0 tpm-crb sha256 2>/dev/null; then
    fail "符号链接 state 被接受"
fi
[[ ! -e "$UNSAFE_DIR/platform-binding" ]] \
    || fail "拒绝符号链接后仍写入了绑定"

PCR_DIR="$(prepare_state_dir bad-pcr)"
if sv_tpm_bind_state "$PCR_DIR" "$PCR_DIR/tpm2-00.permall" \
    "$PLATFORM_A" firmware intel-ptt 1.2 tpm-tis sha256 2>/dev/null; then
    fail "TPM 1.2 接受了 sha256 PCR bank"
fi

# daemon 生命周期必须把版本映射成正确的 swtpm 参数，并拒绝版本与目录交叉。
RUNTIME_DIR="$TMP_DIR/runtime"
mkdir -m 700 "$RUNTIME_DIR"
sv_instance_lock_path() {
    local instance="$1"
    printf '%s/%s.lock\n' "$RUNTIME_DIR" "$instance"
}
swtpm() {
    printf '%s\n' "$@" >"$SWTPM_CAPTURE"
}

DAEMON_12_ROOT="$TMP_DIR/daemon12"
mkdir -m 700 "$DAEMON_12_ROOT"
DAEMON_12_DIR="$(sv_swtpm_prepare_state_dir "$DAEMON_12_ROOT/tpm12-state")"
SWTPM_CAPTURE="$TMP_DIR/swtpm12.argv"
sv_swtpm_start_daemon 9812 "$DAEMON_12_DIR" \
    "$DAEMON_12_ROOT/tpm-sock" "$DAEMON_12_ROOT/tpm.log" 1.2
if grep -Fx -- '--tpm2' "$SWTPM_CAPTURE" >/dev/null; then
    fail "TPM 1.2 daemon 错误携带 --tpm2"
fi
grep -Fx -- "dir=$DAEMON_12_DIR" "$SWTPM_CAPTURE" >/dev/null \
    || fail "TPM 1.2 daemon 未使用独立 state 目录"
sv_swtpm_unregister_state_dir 9812 "$DAEMON_12_DIR"

DAEMON_20_ROOT="$TMP_DIR/daemon20"
mkdir -m 700 "$DAEMON_20_ROOT"
DAEMON_20_DIR="$(sv_swtpm_prepare_state_dir "$DAEMON_20_ROOT/tpm-state")"
SWTPM_CAPTURE="$TMP_DIR/swtpm20.argv"
sv_swtpm_start_daemon 9820 "$DAEMON_20_DIR" \
    "$DAEMON_20_ROOT/tpm-sock" "$DAEMON_20_ROOT/tpm.log" 2.0
grep -Fx -- '--tpm2' "$SWTPM_CAPTURE" >/dev/null \
    || fail "TPM 2.0 daemon 缺少 --tpm2"
sv_swtpm_unregister_state_dir 9820 "$DAEMON_20_DIR"
if sv_swtpm_start_daemon 9821 "$DAEMON_12_DIR" \
    "$DAEMON_12_ROOT/tpm-sock" "$DAEMON_12_ROOT/tpm.log" 2.0 2>/dev/null; then
    fail "TPM 2.0 daemon 接受了 TPM 1.2 state 目录"
fi

echo "OK: TPM state binding preserves platform and key continuity"
