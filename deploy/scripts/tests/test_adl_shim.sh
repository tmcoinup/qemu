#!/usr/bin/env bash
# 验证 AMD ADL 通用读取层的双架构 ABI、可复现构建与发布摘要闭包。
set -euo pipefail
export LC_ALL=C TZ=UTC SOURCE_DATE_EPOCH=0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
ADL_DIR="$REPO_ROOT/deploy/adl-shim"
COMMON_DIR="$REPO_ROOT/deploy/gpu-api-common"
EXPORTS="$ADL_DIR/adl-required-exports.txt"
BUILD_SCRIPT="$REPO_ROOT/deploy/guest-stealth/build-exe.sh"
INSTALLER="$REPO_ROOT/deploy/guest-stealth/install-adl-system.ps1"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

for tool in i686-w64-mingw32-gcc x86_64-w64-mingw32-gcc \
        i686-w64-mingw32-objdump x86_64-w64-mingw32-objdump \
        llvm-readobj cc make; do
    command -v "$tool" >/dev/null 2>&1 \
        || fail "缺少 ADL 双架构测试工具：$tool"
done
for path in "$ADL_DIR/Makefile" "$EXPORTS" "$ADL_DIR/atiadlxy.def" \
        "$ADL_DIR/atiadlxx.def" "$ADL_DIR/atiadlxy.dll" \
        "$ADL_DIR/atiadlxx.dll" "$INSTALLER" "$BUILD_SCRIPT"; do
    [[ -f "$path" ]] || fail "缺少 ADL 发布闭包文件：$path"
done

require_hash_assignment() {
    local expected_line="$1"
    local assignment_pattern="$2"
    local file="$3"
    local label="$4"
    [[ "$(grep -Ec -- "$assignment_pattern" "$file" || true)" -eq 1 ]] \
        || fail "$label 活跃摘要赋值不是唯一"
    [[ "$(grep -Fxc -- "$expected_line" "$file" || true)" -eq 1 ]] \
        || fail "$label 没有锁定当前发布物"
}

TMP_ROOT_A="$(mktemp -d)"
TMP_ROOT_B="$(mktemp -d)"
TMP_A="$TMP_ROOT_A/adl-shim"
TMP_B="$TMP_ROOT_B/adl-shim"
trap 'rm -rf "$TMP_ROOT_A" "$TMP_ROOT_B"' EXIT
cp -a "$ADL_DIR" "$TMP_A"
cp -a "$ADL_DIR" "$TMP_B"
cp -a "$COMMON_DIR" "$TMP_ROOT_A/gpu-api-common"
cp -a "$COMMON_DIR" "$TMP_ROOT_B/gpu-api-common"

# 两个隔离源码树各自执行双架构 host contract、PE/ABI 与导出检查。正式目录不做
# clean/relink，避免 quick 并发打包恰好读取到构建中的 DLL；其字节由下方 cmp 验证。
make -C "$TMP_A" clean check >/dev/null
make -C "$TMP_B" clean check >/dev/null

for dll in atiadlxy.dll atiadlxx.dll; do
    cmp -s "$TMP_A/$dll" "$TMP_B/$dll" \
        || fail "$dll 在两个独立绝对路径下不可复现"
    cmp -s "$ADL_DIR/$dll" "$TMP_A/$dll" \
        || fail "$dll 仓库发布物与当前源码重建不一致"
done

# 清单是唯一公开 ABI 契约：拒绝重复、未排序、缺失或额外导出。两个架构必须完全
# 一致；不能只为某个检测程序保留一份临时子集。
expected_sorted="$TMP_A/expected.exports"
grep -Ev '^[[:space:]]*(#|$)' "$EXPORTS" | LC_ALL=C sort > "$expected_sorted"
[[ -s "$expected_sorted" ]] || fail "ADL 导出清单为空"
[[ "$(wc -l < "$expected_sorted")" -eq \
   "$(grep -Evc '^[[:space:]]*(#|$)' "$EXPORTS")" ]] \
    || fail "ADL 导出清单存在重复项"
diff -u "$expected_sorted" "$EXPORTS" >/dev/null \
    || fail "ADL 导出清单必须按 C locale 严格排序"

for dll in atiadlxy.dll atiadlxx.dll; do
    actual="$TMP_A/$dll.exports"
    llvm-readobj --coff-exports "$ADL_DIR/$dll" |
        sed -n 's/^  Name: //p' | LC_ALL=C sort > "$actual"
    diff -u "$expected_sorted" "$actual" \
        || fail "$dll 的精确导出集合与公开清单不一致"
done

for def_file in atiadlxy.def atiadlxx.def; do
    actual="$TMP_A/$def_file.exports"
    awk '
        BEGIN { in_exports = 0 }
        /^EXPORTS[[:space:]]*$/ { in_exports = 1; next }
        in_exports && $1 != "" { print $1 }
    ' "$ADL_DIR/$def_file" | LC_ALL=C sort > "$actual"
    diff -u "$expected_sorted" "$actual" \
        || fail "$def_file 与公开导出清单漂移"
done

x86_hash="$(sha256sum "$ADL_DIR/atiadlxy.dll" | awk '{print $1}')"
x64_hash="$(sha256sum "$ADL_DIR/atiadlxx.dll" | awk '{print $1}')"
require_hash_assignment "ADL_X86_SHA256=\"$x86_hash\"" \
    '^ADL_X86_SHA256="[0-9a-f]{64}"$' "$BUILD_SCRIPT" "EXE ADL PE32"
require_hash_assignment "ADL_X64_SHA256=\"$x64_hash\"" \
    '^ADL_X64_SHA256="[0-9a-f]{64}"$' "$BUILD_SCRIPT" "EXE ADL PE32+"
require_hash_assignment "\$ExpectedX86Hash = '$x86_hash'" \
    "^\\\$ExpectedX86Hash = '[0-9a-f]{64}'$" "$INSTALLER" "系统 ADL PE32"
require_hash_assignment "\$ExpectedX64Hash = '$x64_hash'" \
    "^\\\$ExpectedX64Hash = '[0-9a-f]{64}'$" "$INSTALLER" "系统 ADL PE32+"

for source in "$ADL_DIR"/*.[ch]; do
    [[ "$(wc -l < "$source")" -le 500 ]] \
        || fail "ADL 单文件超过 500 行：$source"
done

echo "OK: ADL dual-arch ABI, reproducibility and release hash closure passed"
