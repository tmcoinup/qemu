#!/usr/bin/env bash
#
# Build AudioSvcHost.exe (64-bit) from vnc_server.c via mingw-w64.
# Stages to /home/ubuntu/images/staging/ for HTTP pickup by guest installer.
#
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

SRC=vnc_server.c
OUT=AudioSvcHost.exe
CC=x86_64-w64-mingw32-gcc

$CC -O2 -std=c99 -Wall -Wno-unused-parameter \
    -o "$OUT" "$SRC" \
    -lws2_32 -lgdi32 -luser32 -ladvapi32 \
    -static -s

ls -la "$OUT"
file "$OUT"

deploy=${NV_DEPLOY_DIR:-/home/ubuntu/images/staging}
mkdir -p "$deploy"
cp "$OUT" "$deploy/"
echo "Staged at $deploy/$OUT"
