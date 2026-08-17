#!/usr/bin/env bash
#
# Build both x64 and x86 forwarding shim DLLs.  The same validated images can
# be installed app-locally or, through the explicit system projection package,
# into the two Windows NVAPI search paths with signed originals beside them.
#
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

SRC=nvapi_shim.c
DEF=nvapi_shim.def
PROBE_SRC=nvapi_profile_probe.c
QUERY_SRC=vgpu_identity_query.c
SYSTEM_PROBE_SRC=system_nvapi_probe.c
deploy=${NV_DEPLOY_DIR:-/home/ubuntu/images/staging}
mkdir -p "$deploy"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

./generate-profile-catalog.sh --check
../generate-vgpu-profile-catalog.sh --check

targets=(
    x86_64-w64-mingw32:nvapi64.dll:libnvapi64.a:0x180000000
    i686-w64-mingw32:nvapi.dll:libnvapi.a:0x10000000
)
probes=(
    x86_64-w64-mingw32:nvapi_profile_probe64.exe:0x140000000
    i686-w64-mingw32:nvapi_profile_probe32.exe:0x00400000
)
system_probes=(
    x86_64-w64-mingw32:SystemNvapiProbe64.exe:0x140000000
    i686-w64-mingw32:SystemNvapiProbe32.exe:0x00400000
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

for probe in "${system_probes[@]}"; do
    IFS=: read -r triplet out image_base <<< "$probe"
    echo "[build] $out ($triplet, system-search runtime verification)"
    "${triplet}-gcc" \
        -O2 -std=c99 -Wall -Wextra -Werror \
        -o "$tmp/$out" "$SYSTEM_PROBE_SRC" \
        -Wl,--no-insert-timestamp \
        -Wl,--image-base,"$image_base" \
        -static \
        -Wl,--subsystem,console
    file "$tmp/$out"
done

for probe in "${probes[@]}"; do
    IFS=: read -r triplet out image_base <<< "$probe"
    echo "[build] $out ($triplet, test-only)"
    "${triplet}-gcc" \
        -O2 -std=c99 -Wall -Wextra -Werror \
        -o "$tmp/$out" "$PROBE_SRC" \
        -Wl,--no-insert-timestamp \
        -Wl,--image-base,"$image_base" \
        -static \
        -Wl,--subsystem,console
    file "$tmp/$out"
done
for probe in "${system_probes[@]}"; do
    IFS=: read -r _ out _ <<< "$probe"
    install -m 0755 "$tmp/$out" "$out"
    install -m 0644 "$tmp/$out" "$deploy/$out"
done

echo "[build] VgpuIdentityQuery.exe (i686-w64-mingw32, installed query)"
i686-w64-mingw32-gcc \
    -O2 -std=c99 -Wall -Wextra -Werror \
    -o "$tmp/VgpuIdentityQuery.exe" "$QUERY_SRC" \
    -Wl,--no-insert-timestamp \
    -Wl,--image-base,0x00400000 \
    -static -lsetupapi -ladvapi32 \
    -Wl,--subsystem,console
file "$tmp/VgpuIdentityQuery.exe"

for target in "${targets[@]}"; do
    IFS=: read -r _ out implib _ <<< "$target"
    install -m 0644 "$tmp/$out" "$out"
    install -m 0644 "$tmp/$implib" "$implib"
    install -m 0644 "$tmp/$out" "$deploy/$out"
done
for probe in "${probes[@]}"; do
    IFS=: read -r _ out _ <<< "$probe"
    install -m 0755 "$tmp/$out" "$out"
    install -m 0644 "$tmp/$out" "$deploy/$out"
done
install -m 0755 "$tmp/VgpuIdentityQuery.exe" VgpuIdentityQuery.exe
install -m 0644 "$tmp/VgpuIdentityQuery.exe" \
    "$deploy/VgpuIdentityQuery.exe"

echo "Staged in $deploy :"
ls -la "$deploy"/nvapi*.dll "$deploy"/nvapi_profile_probe*.exe \
    "$deploy"/SystemNvapiProbe*.exe "$deploy"/VgpuIdentityQuery.exe
