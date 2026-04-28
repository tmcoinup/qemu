#!/usr/bin/env bash
#
# Build nv_stream_relay.exe (Win64) — bridges between an in-guest
# ffmpeg child and the host ↔ guest ivshmem ring buffers.
#
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

SRC=nv_stream_relay.c
RC=nv_stream_relay.rc
RES=nv_stream_relay.res
# 输出名跟 NVIDIA 真实组件命名贴齐 — 任务管理器进程列表里
# 显示 "NvStreamSvc" + FileDescription "NVIDIA Streaming Service"，
# 不再裸露 nv_stream_relay 字串。
OUT=NvStreamSvc.exe
CC=x86_64-w64-mingw32-gcc
WINDRES=x86_64-w64-mingw32-windres

# nv_shmem_proto.h lives under deploy/nv-shmem/ — share it via -I
SHMEM_DIR="$(readlink -f ../../nv-shmem)"

$WINDRES "$RC" -O coff -o "$RES"

$CC -O2 -std=c99 -Wall -Wno-unused-parameter -Wno-pointer-sign \
    -I "$SHMEM_DIR" \
    -o "$OUT" "$SRC" "$RES" \
    -lsetupapi -ladvapi32 -lws2_32 -luser32 -lkernel32 \
    -ld3d11 -ldxgi \
    -static -s
rm -f "$RES"

ls -la "$OUT"
file "$OUT"

deploy=${NV_DEPLOY_DIR:-/home/ubuntu/images/staging}
mkdir -p "$deploy"
cp "$OUT" "$deploy/"
# 老二进制清掉，避免 stage 目录里两份共存被 install 脚本误抓
rm -f "$deploy/nv_stream_relay.exe"
echo "Staged at $deploy/$OUT"
