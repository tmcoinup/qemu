#!/usr/bin/env bash
#
# build-qemu.sh — (重)编 QEMU x86_64 二进制。
#
# 用法:
#   ./deploy/host/build-qemu.sh                 # 增量编（保留 build/ 已有 .o）
#   ./deploy/host/build-qemu.sh --reconfigure   # configure 改了选项时强制重 setup
#   ./deploy/host/build-qemu.sh --clean         # 删 build/ 重新 configure + 全编
#   ./deploy/host/build-qemu.sh --jobs N        # 限制 ninja 并发数
#
# 启用的 display 后端：sdl / gtk / vnc / egl-headless / spice-app / dbus
# (start-vm.sh --install / 一条龙模式都依赖 SDL 可用)。
#
# 注意：QEMU 11 需要 meson >= 1.5；系统 apt 装的 meson 1.3 跑不动。脚本走
# QEMU 自带的 ./configure，它内部用 vendored python venv + meson，绕过这条。
#
set -euo pipefail

here=$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)
cd "$here"

JOBS=""
ACTION=incremental
while [[ $# -gt 0 ]]; do
    case "$1" in
        --reconfigure) ACTION=reconfigure; shift ;;
        --clean)       ACTION=clean; shift ;;
        --jobs|-j)     JOBS="$2"; shift 2 ;;
        -h|--help)     sed -n '3,17p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

# ───── apt 依赖检查 ──────────────────────────────────────────────
need=()
for p in libsdl2-dev libgtk-3-dev libglib2.0-dev libpixman-1-dev \
         libslirp-dev ninja-build python3-venv pkg-config; do
    dpkg -s "$p" >/dev/null 2>&1 || need+=("$p")
done
if (( ${#need[@]} )); then
    echo "[build-qemu] 缺包: ${need[*]}"
    echo "[build-qemu] 装: sudo apt install ${need[*]}"
    exit 1
fi

# ───── configure 参数 ────────────────────────────────────────────
CONFIGURE_ARGS=(
    --target-list=x86_64-softmmu
    --enable-kvm
    --enable-vhost-net
    --enable-vhost-user
    --enable-slirp
    --enable-tools
    --enable-vnc
    --enable-sdl
    --enable-gtk
    --disable-docs
    --disable-vnc-jpeg
    --prefix="$here/install"
)

# ───── 执行 ──────────────────────────────────────────────────────
case "$ACTION" in
    clean)
        echo "[build-qemu] --clean: rm -rf build/ + 重新 configure"
        rm -rf build
        mkdir -p build
        cd build
        ../configure "${CONFIGURE_ARGS[@]}"
        ;;
    reconfigure)
        echo "[build-qemu] --reconfigure: 重跑 configure (保留已编 .o)"
        mkdir -p build
        cd build
        ../configure "${CONFIGURE_ARGS[@]}"
        ;;
    incremental)
        if [[ ! -f build/build.ninja ]]; then
            echo "[build-qemu] build/build.ninja 不存在，跑 configure"
            mkdir -p build
            cd build
            ../configure "${CONFIGURE_ARGS[@]}"
        else
            cd build
        fi
        ;;
esac

NINJA_ARGS=(qemu-system-x86_64)
[[ -n "$JOBS" ]] && NINJA_ARGS=(-j "$JOBS" "${NINJA_ARGS[@]}")

echo "[build-qemu] ninja ${NINJA_ARGS[*]}"
ninja "${NINJA_ARGS[@]}"

bin="$here/build/qemu-system-x86_64"
echo
echo "[build-qemu] OK"
ls -la "$bin"
echo
echo "  display backends:"
"$bin" -display help 2>&1 | sed 's/^/    /'
