#!/usr/bin/env bash
# Build one reviewable, unsigned Windows user-mode EXE with embedded scripts.
set -euo pipefail
umask 077
export LC_ALL=C

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_root="$(cd "$here/.." && pwd)"

usage() {
    cat <<'EOF'
usage: ./build.sh --output /absolute/path/G11GuestLite.exe

Builds an ordinary 64-bit Windows user-mode EXE. The EXE embeds the reviewed
PowerShell/CMD/README payloads and requests UAC through a standard manifest.
Compiler support is statically linked; runtime imports are Windows inbox DLLs
only. It does not sign or install a driver.
EOF
}

die() { echo "[guest-lite-exe] ERROR: $*" >&2; exit 1; }

output=""
while (($#)); do
    case "$1" in
        --output)
            (($# >= 2)) || die '--output requires an absolute .exe path'
            output=$2
            shift 2
            ;;
        --output=*)
            output=${1#*=}
            [[ -n "$output" ]] || die '--output cannot be empty'
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *) die "unknown argument: $1" ;;
    esac
done

[[ "$output" == /* && "${output,,}" == *.exe ]] \
    || die '--output must be an absolute .exe path'
for dependency in realpath install sed mktemp mv \
        x86_64-w64-mingw32-gcc x86_64-w64-mingw32-windres; do
    command -v "$dependency" >/dev/null 2>&1 \
        || die "missing build dependency: $dependency"
done

payloads=(
    G11-Guest-Lite.ps1
    01-OneClick-Apply.cmd
    02-Audit.cmd
    03-Rollback.cmd
    README.txt
)
sources=(
    "$here/guest_lite_launcher.c"
    "$here/guest_lite_launcher.rc"
    "$here/guest_lite_launcher.manifest"
)
for path in "${sources[@]}"; do
    [[ -f "$path" && ! -L "$path" && -s "$path" ]] \
        || die "missing or unsafe launcher source: $path"
done
for name in "${payloads[@]}"; do
    path="$source_root/$name"
    [[ -f "$path" && ! -L "$path" && -s "$path" ]] \
        || die "missing or unsafe embedded payload: $path"
done

output_parent=$(dirname -- "$output")
mkdir -p -- "$output_parent"
output_parent=$(realpath -e -- "$output_parent") \
    || die 'could not resolve output parent'
[[ -d "$output_parent" && ! -L "$output_parent" ]] \
    || die 'output parent must be a real directory'
output="$output_parent/$(basename -- "$output")"
[[ ! -L "$output" && ( ! -e "$output" || -f "$output" ) ]] \
    || die 'output must be a regular non-symlink path'

work=$(mktemp -d "$output_parent/.guest-lite-exe.XXXXXXXX")
cleanup() {
    [[ -n "${work:-}" && "$work" == "$output_parent"/.guest-lite-exe.* ]] \
        || return 0
    rm -rf -- "$work"
}
trap cleanup EXIT INT TERM

for path in "${sources[@]}"; do
    install -m 0600 -- "$path" "$work/$(basename -- "$path")"
done
for name in "${payloads[@]}"; do
    install -m 0600 -- "$source_root/$name" "$work/$name"
done
for launcher in "$work"/*.cmd; do
    sed -i 's/$/\r/' "$launcher"
done

(
    cd "$work"
    x86_64-w64-mingw32-windres --use-temp-file \
        -i guest_lite_launcher.rc -o guest_lite_launcher_res.o
    x86_64-w64-mingw32-gcc -std=c11 -O2 -Wall -Wextra -Werror \
        -static -s -municode -Wl,--no-insert-timestamp \
        -o G11GuestLite.exe guest_lite_launcher.c \
        guest_lite_launcher_res.o \
        -ladvapi32 -lbcrypt -lshell32 -luser32
)

staged="$output_parent/.$(basename -- "$output").new.$$.$RANDOM"
install -m 0600 -- "$work/G11GuestLite.exe" "$staged"
mv -Tf -- "$staged" "$output"
printf '%s\n' "$output"
