#!/usr/bin/env bash
# 验证 swtpm 证书签发状态完全位于私有实例目录，不接触系统 local CA。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

source "$REPO_ROOT/deploy/scripts/lib/sv-tpm-private-ca.sh"
BOARD_MFR='ASUSTeK COMPUTER INC.'
BOARD_VERSION='Rev X.0x'
BOARD_PRODUCT='H110M-A/M.2'
VM_DIR="$TMP_DIR/vm 1"
mkdir -p "$VM_DIR"

sv_tpm_prepare_private_ca "$VM_DIR"
config_dir="$VM_DIR/tpm-config"
ca_dir="$VM_DIR/tpm-ca"
[[ "$(stat -c '%a' "$config_dir")" == 700 ]] || fail "TPM config 目录不是 0700"
[[ "$(stat -c '%a' "$ca_dir")" == 700 ]] || fail "TPM CA 目录不是 0700"
for file in "$config_dir"/*; do
    [[ "$(stat -c '%a' "$file")" == 600 ]] || fail "TPM 配置不是 0600: $file"
done
grep -F -- "$ca_dir" "$config_dir/swtpm-localca.conf" >/dev/null \
    || fail "local CA statedir 未绑定实例目录"
if grep -R -F -- '/var/lib/swtpm-localca' "$config_dir" >/dev/null; then
    fail "私有配置仍引用系统 swtpm local CA"
fi
grep -F -- '--platform-manufacturer ASUSTeK_COMPUTER_INC.' \
    "$config_dir/swtpm-localca.options" >/dev/null \
    || fail "平台证书字段未安全规范化"

# 预置 symlink 时必须拒绝，不能通过实例路径改写外部 CA 或权限。
outside="$TMP_DIR/outside"
mkdir "$outside"
bad_vm="$TMP_DIR/bad"
mkdir "$bad_vm"
ln -s "$outside" "$bad_vm/tpm-ca"
if sv_tpm_prepare_private_ca "$bad_vm" >/dev/null 2>&1; then
    fail "TPM CA 符号链接未被拒绝"
fi

echo "OK: swtpm uses a per-instance private local CA"
