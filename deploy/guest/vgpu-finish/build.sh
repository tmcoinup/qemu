#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
umask 077

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat >&2 <<'EOF'
usage: build.sh --token-file FILE --output FILE.exe

Builds one universal, administrator-only Windows EXE for every VM that uses
the same DLS token. The token is embedded in the PE resource and remains
extractable; protect and delete the EXE after use.
EOF
}

die() { echo "[guest-exe] ERROR: $*" >&2; exit 1; }

TOKEN_FILE=""
OUTPUT=""
while (( $# > 0 )); do
    case "$1" in
        --token-file) TOKEN_FILE=${2:-}; shift 2 ;;
        --output) OUTPUT=${2:-}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[[ -n "$TOKEN_FILE" && -n "$OUTPUT" ]] || {
    usage
    exit 2
}

TOKEN_FILE=$(realpath -e -- "$TOKEN_FILE") || die "token file does not exist"
[[ -f "$TOKEN_FILE" && -r "$TOKEN_FILE" ]] || die "token is not a readable regular file"
token_bytes=$(stat -c %s -- "$TOKEN_FILE")
(( token_bytes >= 1024 && token_bytes <= 1048576 )) \
    || die "token size must be 1024..1048576 bytes (got $token_bytes)"
if LC_ALL=C head -c 256 -- "$TOKEN_FILE" | grep -Eiq '<[[:space:]]*(!doctype[[:space:]]+html|html)'; then
    die "token looks like an HTML error page"
fi
token_sha=$(sha256sum -- "$TOKEN_FILE" | awk '{print toupper($1)}')

CC=${CC:-x86_64-w64-mingw32-gcc}
WINDRES=${WINDRES:-x86_64-w64-mingw32-windres}
command -v "$CC" >/dev/null 2>&1 || die "missing compiler: $CC"
command -v "$WINDRES" >/dev/null 2>&1 || die "missing resource compiler: $WINDRES"

tmp=$(mktemp -d)
cleanup() { rm -rf -- "$tmp"; }
trap cleanup EXIT

install -m 0600 -- "$TOKEN_FILE" "$tmp/client_configuration_token.tok"
install -m 0600 -- "$here/vgpu_guest_finish.c" "$tmp/vgpu_guest_finish.c"
install -m 0600 -- "$here/vgpu_guest_finish.rc" "$tmp/vgpu_guest_finish.rc"
install -m 0600 -- "$here/vgpu_guest_finish.manifest" "$tmp/vgpu_guest_finish.manifest"
printf '#define VGPU_TOKEN_BYTES %su\n' "$token_bytes" >"$tmp/build_metadata.h"
printf '#define VGPU_TOKEN_SHA256 "%s"\n' "$token_sha" >>"$tmp/build_metadata.h"

(
    cd "$tmp"
    "$WINDRES" --use-temp-file \
        -i vgpu_guest_finish.rc -o vgpu_guest_finish_res.o
    "$CC" -std=c11 -O2 -Wall -Wextra -Werror -static -s -municode \
        -Wl,--no-insert-timestamp \
        -o VgpuGuestFinish.exe vgpu_guest_finish.c vgpu_guest_finish_res.o \
        -ladvapi32 -lbcrypt -lsetupapi -luser32
)

mkdir -p -- "$(dirname "$OUTPUT")"
install -m 0600 -- "$tmp/VgpuGuestFinish.exe" "$OUTPUT"
echo "[guest-exe] output=$OUTPUT"
echo "[guest-exe] token-bytes=$token_bytes token-sha256=$token_sha"
echo "[guest-exe] universal package: runtime SMBIOS UUID and host rescue target discovery"
echo "[guest-exe] WARNING: the EXE contains the token; delete it from host and guest after use"
