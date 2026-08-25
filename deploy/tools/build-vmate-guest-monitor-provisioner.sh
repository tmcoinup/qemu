#!/usr/bin/env bash
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd -- "$here/../.." && pwd)
source_file="$repo/deploy/windows/gpup/native/VMateGuestMonitorProvisioner.c"
output_dir="$repo/deploy/windows/gpup/native/bin"
output_file="$output_dir/VMateGuestMonitorProvisioner.exe"
compiler=${VMATE_MINGW_CC:-x86_64-w64-mingw32-gcc}

command -v "$compiler" >/dev/null 2>&1 || {
    echo "缺少 Windows x64 交叉编译器：$compiler" >&2
    exit 1
}
[[ -f "$source_file" ]] || {
    echo "缺少 Guest Monitor 源码：$source_file" >&2
    exit 1
}

mkdir -p -- "$output_dir"
temporary=$(mktemp --tmpdir="$output_dir" .VMateGuestMonitorProvisioner.XXXXXX.exe)
trap 'rm -f -- "$temporary"' EXIT

"$compiler" -std=c11 -O2 -Wall -Wextra -Werror -municode \
    -Wl,--no-insert-timestamp \
    -o "$temporary" "$source_file" \
    -lsetupapi -lcfgmgr32 -ladvapi32
mv -f -- "$temporary" "$output_file"
trap - EXIT

sha256sum -- "$output_file"
