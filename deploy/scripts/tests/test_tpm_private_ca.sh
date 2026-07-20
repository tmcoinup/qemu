#!/usr/bin/env bash
# 验证 swtpm 证书签发状态完全位于私有实例目录，不接触系统 local CA。
# shellcheck disable=SC1091,SC2034
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
grep -Fx -- 'active_pcr_banks = sha256' "$config_dir/swtpm_setup.conf" >/dev/null \
    || fail "默认 TPM 2.0 PCR bank 未写入私有 setup 配置"

# TPM 1.2 profile 必须把 sha1 传到每实例 setup 配置，不能沿用固定 sha256。
tpm12_vm="$TMP_DIR/vm-tpm12"
mkdir "$tpm12_vm"
TPM_PCR_BANKS=sha1 sv_tpm_prepare_private_ca "$tpm12_vm"
grep -Fx -- 'active_pcr_banks = sha1' \
    "$tpm12_vm/tpm-config/swtpm_setup.conf" >/dev/null \
    || fail "TPM 1.2 sha1 PCR bank 未动态写入"

bad_pcr_vm="$TMP_DIR/vm-bad-pcr"
mkdir "$bad_pcr_vm"
if TPM_PCR_BANKS=sha512 sv_tpm_prepare_private_ca "$bad_pcr_vm" \
    >/dev/null 2>&1; then
    fail "非法 PCR bank 被私有 CA 配置接受"
fi

# 工具可用时做真实初始化闭环：1.2 不带 --tpm2 并生成 tpm-00.permall，
# 2.0 带 --tpm2 并生成 tpm2-00.permall。所有状态只写临时私有目录。
if command -v swtpm_setup >/dev/null 2>&1 \
    && command -v swtpm >/dev/null 2>&1; then
    tpm12_state="$tpm12_vm/tpm12-state"
    mkdir -m 700 "$tpm12_state"
    if ! swtpm_setup --tpmstate "$tpm12_state" \
        --config "$tpm12_vm/tpm-config/swtpm_setup.conf" \
        --create-ek-cert --create-platform-cert --lock-nvram \
        --not-overwrite >"$TMP_DIR/setup12.log" 2>&1; then
        tail -20 "$TMP_DIR/setup12.log" >&2
        fail "真实 swtpm_setup TPM 1.2 初始化失败"
    fi
    [[ -s "$tpm12_state/tpm-00.permall" \
        && ! -e "$tpm12_state/tpm2-00.permall" ]] \
        || fail "真实 TPM 1.2 state 文件名/内容错误"

    tpm20_state="$VM_DIR/tpm-state"
    mkdir -m 700 "$tpm20_state"
    if ! swtpm_setup --tpm2 --tpmstate "$tpm20_state" \
        --config "$config_dir/swtpm_setup.conf" \
        --create-ek-cert --create-platform-cert --lock-nvram \
        --not-overwrite >"$TMP_DIR/setup20.log" 2>&1; then
        tail -20 "$TMP_DIR/setup20.log" >&2
        fail "真实 swtpm_setup TPM 2.0 初始化失败"
    fi
    [[ -s "$tpm20_state/tpm2-00.permall" \
        && ! -e "$tpm20_state/tpm-00.permall" ]] \
        || fail "真实 TPM 2.0 state 文件名/内容错误"
else
    echo "SKIP: swtpm_setup/swtpm 不可用，跳过真实 TPM 1.2/2.0 初始化"
fi

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
