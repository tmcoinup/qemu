#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE="$DEPLOY_DIR/windows/gpup/native/VMateVidContextProbe.c"
OUTPUT_DIR="$DEPLOY_DIR/windows/gpup/native/bin"
OBJECT="$OUTPUT_DIR/VMateVidContextProbe.o"
OUTPUT="$OUTPUT_DIR/VMateVidContextProbe.sys"
CC="${VMATE_MINGW_CC:-x86_64-w64-mingw32-gcc}"
DDK_INCLUDE="${VMATE_MINGW_DDK_INCLUDE:-/usr/x86_64-w64-mingw32/include/ddk}"

command -v "$CC" >/dev/null 2>&1 || {
    echo "missing compiler: $CC" >&2
    exit 1
}
[[ -f "$DDK_INCLUDE/ntddk.h" ]] || {
    echo "missing MinGW DDK headers: $DDK_INCLUDE" >&2
    exit 1
}

mkdir -p "$OUTPUT_DIR"
"$CC" \
    -std=c11 \
    -O2 \
    -Wall \
    -Wextra \
    -Werror \
    -ffreestanding \
    -fno-stack-protector \
    -mno-red-zone \
    -I"$DDK_INCLUDE" \
    -c \
    -o "$OBJECT" \
    "$SOURCE"

"$CC" \
    -nostdlib \
    -shared \
    -Wl,--entry,DriverEntry \
    -Wl,--subsystem,native:10.0 \
    -Wl,--major-os-version,10 \
    -Wl,--minor-os-version,0 \
    -Wl,--major-subsystem-version,10 \
    -Wl,--minor-subsystem-version,0 \
    -Wl,--section-alignment,0x1000 \
    -Wl,--file-alignment,0x200 \
    -Wl,--dynamicbase \
    -Wl,--nxcompat \
    -Wl,--high-entropy-va \
    -Wl,--wdmdriver \
    -Wl,--no-insert-timestamp \
    -o "$OUTPUT" \
    "$OBJECT" \
    -lntoskrnl

rm -f "$OBJECT"
sha256sum "$OUTPUT"
