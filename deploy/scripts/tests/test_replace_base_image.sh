#!/usr/bin/env bash
# 更换基础镜像的静态事务契约与 Guest 名称写入单元测试。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPLACE="$SCRIPT_DIR/replace-base-image.sh"
GUEST_NAME="$SCRIPT_DIR/host-preserve-guest-name.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

bash -n "$REPLACE"
bash -n "$GUEST_NAME"
# shellcheck source=/dev/null
source "$GUEST_NAME"

WINDOWS_ROOT="$TMP_DIR/windows"
TEMPLATE="$TMP_DIR/autounattend.xml"
mkdir -p "$WINDOWS_ROOT/Windows/System32/config"
printf '%s\n' \
    '<unattend><settings><component>' \
    '<ComputerName>DESKTOP-OLD0000</ComputerName>' \
    '</component></settings></unattend>' >"$TEMPLATE"
guest_name_write_windows_unattend "$WINDOWS_ROOT" DESKTOP-ABC1234 "$TEMPLATE"
for output in \
    "$WINDOWS_ROOT/Windows/Panther/Unattend/unattend.xml" \
    "$WINDOWS_ROOT/unattend.xml" \
    "$WINDOWS_ROOT/Windows/System32/Sysprep/unattend.xml"; do
    grep -qF '<ComputerName>DESKTOP-ABC1234</ComputerName>' "$output" ||
        fail "Windows answer file 没有保持指定计算机名称: $output"
done
if guest_name_validate_windows 'name_is_too_long_for_windows'; then
    fail "Windows 超长计算机名称未被拒绝"
fi

LINUX_ROOT="$TMP_DIR/linux"
mkdir -p "$LINUX_ROOT/etc"
printf 'template-name\n' >"$LINUX_ROOT/etc/hostname"
printf '127.0.0.1 localhost\n127.0.1.1 template-name\n' >"$LINUX_ROOT/etc/hosts"
[[ "$(guest_name_read_linux "$LINUX_ROOT")" == template-name ]] ||
    fail "Linux Guest 名称读取没有限定在挂载根目录内"
guest_name_write_linux "$LINUX_ROOT" workstation-07
[[ "$(tr -d '\r\n' <"$LINUX_ROOT/etc/hostname")" == workstation-07 ]] ||
    fail "Linux /etc/hostname 没有保持指定名称"
grep -qF $'127.0.1.1\tworkstation-07' "$LINUX_ROOT/etc/hosts" ||
    fail "Linux /etc/hosts 没有同步指定名称"

# shellcheck disable=SC2016 # 测试刻意匹配脚本文本，而不是在本测试进程中展开变量。
grep -qF 'PROFILE_BEFORE="$(sha256sum -- "$PROFILE"' "$REPLACE" ||
    fail "换镜像事务缺少硬件 profile 前后摘要"
# shellcheck disable=SC2016 # 同上，保持静态事务契约的字面量断言。
grep -qF 'OVMF_BEFORE="$(sha256sum -- "$OVMF_VARS"' "$REPLACE" ||
    fail "换镜像事务缺少 OVMF NVRAM 前后摘要"
# shellcheck disable=SC2016 # 同上，静态确认持久 TPM 目录摘要仍在事务边界内。
grep -qF 'TPM_BEFORE="$(replace_tpm_identity_digest "$VM_DIR")"' "$REPLACE" ||
    fail "换镜像事务缺少持久 TPM 身份前后摘要"
grep -qF 'BOOT_STORAGE_SIZE_BYTES' "$REPLACE" ||
    fail "换镜像事务缺少现有启动盘容量匹配"
# shellcheck disable=SC2016 # 同上，确保旧盘读取调用没有被误删或改参。
grep -qF '"$GUEST_NAME_HELPER" read "$DISK"' "$REPLACE" ||
    fail "换镜像事务没有从旧盘读取 Guest 名称"
# shellcheck disable=SC2016 # 同上，确保新盘注入调用使用已读取的原名称。
grep -qF '"$GUEST_NAME_HELPER" apply "$NEW_DISK" "$GUEST_NAME"' "$REPLACE" ||
    fail "换镜像事务没有把 Guest 名称写入新盘"

echo "OK: base image replacement preserves hardware files and guest computer name"
