#!/usr/bin/env bash
# 验证仓库发布探针可由当前工具链逐字节复现，防止嵌入过期诊断程序。
set -euo pipefail
export LC_ALL=C TZ=UTC SOURCE_DATE_EPOCH=0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PROBE_DIR="$REPO_ROOT/deploy/nvapi-runtime-probe"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

for tool in i686-w64-mingw32-gcc x86_64-w64-mingw32-gcc \
        i686-w64-mingw32-objdump x86_64-w64-mingw32-objdump strings \
        python3; do
    command -v "$tool" >/dev/null 2>&1 \
        || fail "缺少双架构 NVAPI 探针测试工具：$tool"
done

tmp_root_a="$(mktemp -d)"
tmp_root_b="$(mktemp -d)"
trap 'rm -rf "$tmp_root_a" "$tmp_root_b"' EXIT
cp -a "$PROBE_DIR" "$tmp_root_a/nvapi-runtime-probe"
cp -a "$PROBE_DIR" "$tmp_root_b/nvapi-runtime-probe"

make -C "$PROBE_DIR" check >/dev/null
make -C "$tmp_root_a/nvapi-runtime-probe" clean check >/dev/null
make -C "$tmp_root_b/nvapi-runtime-probe" clean check >/dev/null

for executable in nvapi-runtime-probe-x86.exe \
        nvapi-runtime-probe-x64.exe; do
    cmp -s "$tmp_root_a/nvapi-runtime-probe/$executable" \
        "$tmp_root_b/nvapi-runtime-probe/$executable" \
        || fail "$executable 当前工具链重建不可复现"
    cmp -s "$PROBE_DIR/$executable" \
        "$tmp_root_a/nvapi-runtime-probe/$executable" \
        || fail "$executable 发布物与当前源码重建结果不一致"
done

echo "OK: NVAPI runtime probe release and reproducibility passed"
