#!/usr/bin/env bash
#
# Build NvDisplayContainer.exe (64-bit Win32 service shim) from
# nv_display_container.c via mingw-w64. Stages to /home/ubuntu/images/staging/
# for HTTP pickup by the install script.
#
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

SRC=nv_display_container.c
RC=nv_display_container.rc
RES=nv_display_container.res
OUT=NvDisplayContainer.exe
CC=x86_64-w64-mingw32-gcc
WINDRES=x86_64-w64-mingw32-windres

# 编译 VERSIONINFO 资源 (任务管理器 / Get-Process 都看这个块)
$WINDRES "$RC" -O coff -o "$RES"

$CC -O2 -std=c99 -Wall -Wno-unused-parameter \
    -o "$OUT" "$SRC" "$RES" \
    -ladvapi32 -luserenv -lwtsapi32 -lkernel32 \
    -static -s
rm -f "$RES"

ls -la "$OUT"
file "$OUT"

deploy=${NV_DEPLOY_DIR:-/home/ubuntu/images/staging}
mkdir -p "$deploy"
cp "$OUT" "$deploy/"
echo "Staged at $deploy/$OUT"
