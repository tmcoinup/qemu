#!/usr/bin/env bash
#
# Build NvDisplayContainer.exe (64-bit Win32 service shim) from
# nv_display_container.c via mingw-w64. Stages to ~/Downloads/nv-deploy/
# for HTTP pickup by the install script.
#
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

SRC=nv_display_container.c
OUT=NvDisplayContainer.exe
CC=x86_64-w64-mingw32-gcc

$CC -O2 -std=c99 -Wall -Wno-unused-parameter \
    -o "$OUT" "$SRC" \
    -ladvapi32 -luserenv -lwtsapi32 -lkernel32 \
    -static -s

ls -la "$OUT"
file "$OUT"

deploy=${NV_DEPLOY_DIR:-/home/ubuntu/Downloads/nv-deploy}
mkdir -p "$deploy"
cp "$OUT" "$deploy/"
echo "Staged at $deploy/$OUT"
