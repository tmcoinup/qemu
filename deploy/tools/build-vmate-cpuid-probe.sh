#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE="$DEPLOY_DIR/windows/gpup/native/VMateCpuidProbe.c"
OUTPUT_DIR="$DEPLOY_DIR/windows/gpup/native/bin"
OUTPUT="$OUTPUT_DIR/VMateCpuidProbe.exe"
CC="${VMATE_MINGW_CC:-x86_64-w64-mingw32-gcc}"

command -v "$CC" >/dev/null 2>&1 || {
    echo "missing compiler: $CC" >&2
    exit 1
}

mkdir -p "$OUTPUT_DIR"
"$CC" \
    -std=c11 \
    -O2 \
    -Wall \
    -Wextra \
    -Werror \
    -Wl,--dynamicbase \
    -Wl,--nxcompat \
    -Wl,--high-entropy-va \
    -o "$OUTPUT" \
    "$SOURCE"

sha256sum "$OUTPUT"
