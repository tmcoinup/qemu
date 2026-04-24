#!/usr/bin/env bash
#
# Build BOTH x64 and x86 shim DLLs — x64 goes to System32\nvapi64.dll,
# x86 goes to SysWOW64\nvapi.dll (loaded by 32-bit apps like 鲁大师).
#
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

SRC=nvapi_shim.c
deploy=${NV_DEPLOY_DIR:-/home/ubuntu/Downloads/nv-deploy}
mkdir -p "$deploy"

for target in x86_64-w64-mingw32:nvapi64.dll:libnvapi64.a \
              i686-w64-mingw32:nvapi.dll:libnvapi.a ; do
    IFS=: read -r triplet out implib <<< "$target"
    if ! command -v "${triplet}-gcc" >/dev/null; then
        echo "missing ${triplet}-gcc — sudo apt install mingw-w64"; exit 1
    fi
    echo "[build] $out ($triplet)"
    "${triplet}-gcc" \
        -shared -O2 -std=c99 \
        -o "$out" "$SRC" \
        -Wl,--out-implib,"$implib" \
        -static -lkernel32 \
        -Wl,--subsystem,windows
    ls -la "$out"
    file "$out"
    cp "$out" "$deploy/"
done

echo "Staged in $deploy :"
ls -la "$deploy"/nvapi*.dll
