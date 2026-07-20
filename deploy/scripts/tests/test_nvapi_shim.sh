#!/usr/bin/env bash
# 分别验证已发布 NVAPI DLL 与源码重建，并检查当前工具链的字节可复现性。
# 不在原目录 make clean，避免快速测试并发构建 guest EXE 时短暂读不到 DLL。
set -euo pipefail
export LC_ALL=C TZ=UTC SOURCE_DATE_EPOCH=0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
NVAPI_DIR="$REPO_ROOT/deploy/nvapi-shim"
COMMON_DIR="$REPO_ROOT/deploy/gpu-api-common"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

for tool in i686-w64-mingw32-gcc x86_64-w64-mingw32-gcc \
        i686-w64-mingw32-objdump x86_64-w64-mingw32-objdump cc; do
    command -v "$tool" >/dev/null 2>&1 \
        || fail "缺少双架构 NVAPI 测试工具：$tool"
done

require_hash_assignment() {
    local expected_line="$1"
    local assignment_pattern="$2"
    local file="$3"
    local description="$4"
    local count

    count="$(grep -Ec -- "$assignment_pattern" "$file" || true)"
    [[ "$count" -eq 1 ]] \
        || fail "$description 活跃赋值必须恰好出现一次"
    count="$(grep -Fxc -- "$expected_line" "$file" || true)"
    [[ "$count" -eq 1 ]] \
        || fail "$description 未锁定仓库发布摘要"
}

TMP_ROOT_A="$(mktemp -d)"
TMP_ROOT_B="$(mktemp -d)"
TMP_A="$TMP_ROOT_A/nvapi-shim"
TMP_B="$TMP_ROOT_B/nvapi-shim"
trap 'rm -rf "$TMP_ROOT_A" "$TMP_ROOT_B"' EXIT
cp -a "$NVAPI_DIR" "$TMP_A"
cp -a "$NVAPI_DIR" "$TMP_B"
cp -a "$COMMON_DIR" "$TMP_ROOT_A/gpu-api-common"
cp -a "$COMMON_DIR" "$TMP_ROOT_B/gpu-api-common"

expected_x86="$(sha256sum "$NVAPI_DIR/nvapi.dll" | awk '{print $1}')"
expected_x64="$(sha256sum "$NVAPI_DIR/nvapi64.dll" | awk '{print $1}')"

# 发布物和两个独立重建各自通过同一套架构、导出、依赖与 ABI 契约。
(
    cd "$NVAPI_DIR"
    ./test-build.sh
) >/dev/null
make -C "$TMP_A" clean check >/dev/null
make -C "$TMP_B" clean check >/dev/null

# 不同 binutils 版本会改变 PE linker version 与布局，不能拿跨工具链哈希证明
# 源码错误；两个独立目录使用当前工具链，才是严格的逐字节可复现性检查。
for dll in nvapi.dll nvapi64.dll; do
    if ! cmp -s "$TMP_A/$dll" "$TMP_B/$dll"; then
        hash_a="$(sha256sum "$TMP_A/$dll" | awk '{print $1}')"
        hash_b="$(sha256sum "$TMP_B/$dll" | awk '{print $1}')"
        fail "$dll 当前工具链重建不可复现：$hash_a != $hash_b"
    fi
    cmp -s "$NVAPI_DIR/$dll" "$TMP_A/$dll" \
        || fail "$dll 发布物与当前源码重建结果不一致"
done

# EXE 构建器和来宾系统发布 helper 都必须锁定本次协议实现的同一对摘要；否则
# 源码测试虽通过，GPU-Z 直接双击仍可能从系统搜索目录加载上一版 DLL。
require_hash_assignment "NVAPI_X86_SHA256=\"$expected_x86\"" \
    '^NVAPI_X86_SHA256="[0-9a-f]{64}"$' \
    "$REPO_ROOT/deploy/guest-stealth/build-exe.sh" \
    "EXE 构建器 PE32 摘要锚点"
require_hash_assignment "NVAPI_X64_SHA256=\"$expected_x64\"" \
    '^NVAPI_X64_SHA256="[0-9a-f]{64}"$' \
    "$REPO_ROOT/deploy/guest-stealth/build-exe.sh" \
    "EXE 构建器 PE32+ 摘要锚点"
require_hash_assignment "\$ExpectedX86Hash = '$expected_x86'" \
    "^\\\$ExpectedX86Hash = '[0-9a-f]{64}'$" \
    "$REPO_ROOT/deploy/guest-stealth/install-nvapi-system.ps1" \
    "系统 NVAPI helper PE32 摘要锚点"
require_hash_assignment "\$ExpectedX64Hash = '$expected_x64'" \
    "^\\\$ExpectedX64Hash = '[0-9a-f]{64}'$" \
    "$REPO_ROOT/deploy/guest-stealth/install-nvapi-system.ps1" \
    "系统 NVAPI helper PE32+ 摘要锚点"

echo "OK: NVAPI release, x86/x64 ABI rebuild and reproducibility passed"
