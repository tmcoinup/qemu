#!/usr/bin/env bash
#
# Build nv_stream_relay.exe (Win64) — bridges between an in-guest
# ffmpeg child and the host ↔ guest ivshmem ring buffers.
#
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

SRC=nv_stream_relay.c
OUT=nv_stream_relay.exe
CC=x86_64-w64-mingw32-gcc

# nv_shmem_proto.h lives under deploy/nv-shmem/ — share it via -I
SHMEM_DIR="$(readlink -f ../../nv-shmem)"

$CC -O2 -std=c99 -Wall -Wno-unused-parameter -Wno-pointer-sign \
    -I "$SHMEM_DIR" \
    -o "$OUT" "$SRC" \
    -lsetupapi -ladvapi32 -lws2_32 -luser32 -lkernel32 \
    -ld3d11 -ldxgi \
    -static -s

ls -la "$OUT"
file "$OUT"

deploy=${NV_DEPLOY_DIR:-/home/ubuntu/Downloads/nv-deploy}
mkdir -p "$deploy"
cp "$OUT" "$deploy/"
echo "Staged at $deploy/$OUT"
