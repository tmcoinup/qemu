#!/usr/bin/env bash
#
# Build BOTH x64 and x86 shim DLLs — x64 goes to System32\nvapi64.dll,
# x86 goes to SysWOW64\nvapi.dll (loaded by 32-bit apps like 鲁大师).
#
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

SRC=nvapi_shim.c
DEF=nvapi_shim.def
deploy=${NV_DEPLOY_DIR:-/home/ubuntu/images/staging}
mkdir -p "$deploy"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

targets=(
    x86_64-w64-mingw32:nvapi64.dll:libnvapi64.a:0x180000000
    i686-w64-mingw32:nvapi.dll:libnvapi.a:0x10000000
)

# Build and validate both architectures before replacing either checked-in or
# staged image.  --no-insert-timestamp keeps the result reproducible so the
# static contract test can prove that the binaries match this source.
for target in "${targets[@]}"; do
    IFS=: read -r triplet out implib image_base <<< "$target"
    if ! command -v "${triplet}-gcc" >/dev/null; then
        echo "missing ${triplet}-gcc — sudo apt install mingw-w64"; exit 1
    fi
    echo "[build] $out ($triplet)"
    "${triplet}-gcc" \
        -shared -O2 -std=c99 -Wall -Wextra -Werror \
        -o "$tmp/$out" "$SRC" "$DEF" \
        -Wl,--out-implib,"$tmp/$implib" \
        -Wl,--no-insert-timestamp \
        -Wl,--image-base,"$image_base" \
        -static -lkernel32 \
        -Wl,--subsystem,windows
    file "$tmp/$out"
done

for target in "${targets[@]}"; do
    IFS=: read -r _ out implib _ <<< "$target"
    install -m 0644 "$tmp/$out" "$out"
    install -m 0644 "$tmp/$implib" "$implib"
    install -m 0644 "$tmp/$out" "$deploy/$out"
done

echo "Staged in $deploy :"
ls -la "$deploy"/nvapi*.dll
