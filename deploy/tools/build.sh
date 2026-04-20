#!/bin/bash
# build.sh - configure + build the patched QEMU 9.2.0 tree.
#
# Flags (也可用环境变量):
#   --clean        / CLEAN=1       先 rm -rf build/
#   --reconfig     / RECONFIG=1    强制重跑 configure（保留 build/ 里的缓存文件）
#   --debug        / DEBUG=1       打开 --enable-debug --disable-strip
#   --jobs N       / JOBS=N        ninja 并行度（默认 nproc）
#   --verify       / VERIFY=1      构建结束后自动跑 verify-stealth.sh
#
# 额外 configure 参数:
#   EXTRA_CONFIGURE="--enable-foo --disable-bar" ./build.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

CLEAN="${CLEAN:-0}"
RECONFIG="${RECONFIG:-0}"
DEBUG="${DEBUG:-0}"
JOBS="${JOBS:-$(nproc)}"
VERIFY="${VERIFY:-0}"

while (( $# )); do
    case "$1" in
        --clean)    CLEAN=1 ;;
        --reconfig) RECONFIG=1 ;;
        --debug)    DEBUG=1 ;;
        --verify)   VERIFY=1 ;;
        --jobs)     JOBS="$2"; shift ;;
        --jobs=*)   JOBS="${1#*=}" ;;
        -h|--help)  sed -n '2,14p' "$0"; exit 0 ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
    shift
done

cd "$REPO_ROOT"

# ---------- 预检 ----------
missing_bin=()
for tool in ninja pkg-config python3; do
    command -v "$tool" >/dev/null 2>&1 || missing_bin+=("$tool")
done
missing_pkg=()
for pkg in glib-2.0 pixman-1; do
    pkg-config --exists "$pkg" 2>/dev/null || missing_pkg+=("$pkg")
done
if (( ${#missing_bin[@]} + ${#missing_pkg[@]} )); then
    echo "FAIL: 缺少依赖"
    (( ${#missing_bin[@]} )) && echo "  可执行文件: ${missing_bin[*]}"
    (( ${#missing_pkg[@]} )) && echo "  pkg-config: ${missing_pkg[*]}"
    echo "  修复: sudo apt install build-essential ninja-build pkg-config \\"
    echo "         python3-venv python3-pip libglib2.0-dev libpixman-1-dev \\"
    echo "         libsdl2-dev libspice-server-dev libvirglrenderer-dev libepoxy-dev \\"
    echo "         libslirp-dev libseccomp-dev ovmf"
    exit 1
fi

# ---------- 补丁状态提示（不强制） ----------
if ! grep -q 'Ryzen3-1200' target/i386/cpu.c 2>/dev/null; then
    echo ">> NOTE: 源树里看不到 Ryzen3-1200 标记 —— 可能补丁还没打。"
    echo ">>       先跑: deploy/tools/apply-patches.sh"
    echo ""
fi

# ---------- 构建目录 ----------
if (( CLEAN )); then
    echo ">> clean build/"
    rm -rf build
fi
mkdir -p build
cd build

CFG_FLAGS=(
    --target-list=x86_64-softmmu
    --enable-kvm
    --enable-slirp
    --enable-virtfs
    --enable-spice
    --enable-virglrenderer
    --enable-opengl
    --enable-sdl
    --enable-vnc
    --disable-werror
    --disable-docs
)
if (( DEBUG )); then
    CFG_FLAGS+=(--enable-debug --disable-strip)
fi
if [[ -n "${EXTRA_CONFIGURE:-}" ]]; then
    # shellcheck disable=SC2206
    CFG_FLAGS+=($EXTRA_CONFIGURE)
fi

if (( RECONFIG )) || [[ ! -f build.ninja ]]; then
    echo ">> configure ${CFG_FLAGS[*]}"
    ../configure "${CFG_FLAGS[@]}"
fi

echo ">> ninja -j$JOBS"
ninja -j"$JOBS"

BIN="$REPO_ROOT/build/qemu-system-x86_64"
if [[ ! -x "$BIN" ]]; then
    echo "FAIL: $BIN 未生成" >&2
    exit 1
fi

echo
echo "=== build complete ==="
printf "  binary : %s\n"   "$BIN"
printf "  size   : %s\n"   "$(stat -c%s "$BIN" | numfmt --to=iec)"
printf "  sha256 : %s\n"   "$(sha256sum "$BIN" | awk '{print $1}')"
printf "  mtime  : %s\n"   "$(stat -c%y "$BIN")"

if (( VERIFY )); then
    echo
    echo "=== running verify-stealth.sh ==="
    "$HERE/../scripts/verify-stealth.sh"
fi
