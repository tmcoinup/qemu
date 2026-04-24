#!/usr/bin/env bash
#
# Build the NVAPI shim DLL on the host (mingw cross-compile) + drop it
# into ~/Downloads/nv-deploy/ so install-nvapi-shim.ps1 (guest-side) can
# pull it via HTTP like every other driver component.
#
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

SRC=nvapi_shim.c
OUT=nvapi64.dll

if ! command -v x86_64-w64-mingw32-gcc >/dev/null; then
    echo 'install: sudo apt install mingw-w64' >&2
    exit 1
fi

x86_64-w64-mingw32-gcc \
    -shared -O2 -std=c99 \
    -o "$OUT" "$SRC" \
    -Wl,--out-implib,libnvapi64.a \
    -static -lkernel32 \
    -Wl,--subsystem,windows

ls -la "$OUT"
file "$OUT"

deploy=${NV_DEPLOY_DIR:-/home/ubuntu/Downloads/nv-deploy}
mkdir -p "$deploy"
cp "$OUT" "$deploy/"
echo "Staged at $deploy/$OUT (served by python3 -m http.server 8080 there)"
