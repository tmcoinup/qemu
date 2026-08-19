#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SOURCE="$SCRIPT_DIR/d3d12_capability_probe.c"

build_one() {
    local compiler=$1
    local output=$2

    command -v "$compiler" >/dev/null 2>&1 || {
        echo "缺少交叉编译器：$compiler" >&2
        return 1
    }
    "$compiler" \
        -std=c11 -Os -Wall -Wextra -Werror \
        -D_WIN32_WINNT=0x0A00 \
        -Wl,--strip-all,--no-insert-timestamp \
        -o "$output" "$SOURCE" \
        -ld3d12 -ldxgi -lole32
}

build_one i686-w64-mingw32-gcc \
    "$SCRIPT_DIR/D3D12CapabilityProbe32.exe"
build_one x86_64-w64-mingw32-gcc \
    "$SCRIPT_DIR/D3D12CapabilityProbe64.exe"

sha256sum \
    "$SCRIPT_DIR/D3D12CapabilityProbe32.exe" \
    "$SCRIPT_DIR/D3D12CapabilityProbe64.exe"
