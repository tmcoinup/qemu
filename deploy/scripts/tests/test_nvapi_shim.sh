#!/usr/bin/env bash
# 在隔离目录重建双架构 NVAPI shim，并确认源码产物与仓库发布字节完全一致。
# 不在原目录 make clean，避免快速测试并发构建 guest EXE 时短暂读不到 DLL。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
NVAPI_DIR="$REPO_ROOT/deploy/nvapi-shim"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

for tool in i686-w64-mingw32-gcc x86_64-w64-mingw32-gcc \
        i686-w64-mingw32-objdump x86_64-w64-mingw32-objdump cc; do
    command -v "$tool" >/dev/null 2>&1 \
        || fail "缺少双架构 NVAPI 测试工具：$tool"
done

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
cp -a "$NVAPI_DIR/." "$TMP_DIR/"

expected_x86="$(sha256sum "$NVAPI_DIR/nvapi.dll" | awk '{print $1}')"
expected_x64="$(sha256sum "$NVAPI_DIR/nvapi64.dll" | awk '{print $1}')"

make -C "$TMP_DIR" clean check >/dev/null

actual_x86="$(sha256sum "$TMP_DIR/nvapi.dll" | awk '{print $1}')"
actual_x64="$(sha256sum "$TMP_DIR/nvapi64.dll" | awk '{print $1}')"
[[ "$actual_x86" == "$expected_x86" ]] \
    || fail "PE32 产物与仓库发布 DLL 不一致：$actual_x86 != $expected_x86"
[[ "$actual_x64" == "$expected_x64" ]] \
    || fail "PE32+ 产物与仓库发布 DLL 不一致：$actual_x64 != $expected_x64"

# EXE 构建器和来宾系统发布 helper 都必须锁定本次协议实现的同一对摘要；否则
# 源码测试虽通过，GPU-Z 直接双击仍可能从系统搜索目录加载上一版 DLL。
for hash in "$expected_x86" "$expected_x64"; do
    rg -F "$hash" "$REPO_ROOT/deploy/guest-stealth/build-exe.sh" >/dev/null \
        || fail "EXE 构建器未同步 NVAPI 摘要：$hash"
    rg -F "$hash" "$REPO_ROOT/deploy/guest-stealth/install-nvapi-system.ps1" >/dev/null \
        || fail "系统 NVAPI helper 未同步摘要：$hash"
done

echo "OK: NVAPI x86/x64 strict rebuild, ABI contract and reproducibility passed"
