#!/usr/bin/env bash
# Compile a small administrator launcher and append the four hash-pinned
# migration payloads.  The 821 MiB vendor archive remains byte-for-byte
# unchanged; it is not passed through windres and is never recompressed.
set -euo pipefail
export LC_ALL=C
umask 077

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat >&2 <<'EOF'
usage: build.sh --contract FILE.json --script FILE.ps1 \
  --driver-zip FILE.zip --gpuz-exe GpuZProfile.exe --output FILE.exe
EOF
}

die() { echo "[vgpu-production-exe] ERROR: $*" >&2; exit 1; }

CONTRACT=""
SCRIPT=""
DRIVER_ZIP=""
GPUZ_EXE=""
OUTPUT=""
while (($#)); do
    case "$1" in
        --contract)
            (($# >= 2)) || die "--contract requires a JSON file"
            CONTRACT=$2
            shift 2
            ;;
        --script)
            (($# >= 2)) || die "--script requires a PowerShell file"
            SCRIPT=$2
            shift 2
            ;;
        --driver-zip)
            (($# >= 2)) || die "--driver-zip requires a host ZIP file"
            DRIVER_ZIP=$2
            shift 2
            ;;
        --gpuz-exe)
            (($# >= 2)) || die "--gpuz-exe requires a nested GPU-Z EXE"
            GPUZ_EXE=$2
            shift 2
            ;;
        --output)
            (($# >= 2)) || die "--output requires an EXE path"
            OUTPUT=$2
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done
[[ -n "$CONTRACT" && -n "$SCRIPT" && -n "$DRIVER_ZIP" &&
   -n "$GPUZ_EXE" && -n "$OUTPUT" ]] || { usage; exit 2; }
[[ "$OUTPUT" == /* && "${OUTPUT,,}" == *.exe ]] \
    || die "--output must be an absolute .exe path"

for dependency in realpath stat sha256sum python3 install \
        x86_64-w64-mingw32-gcc x86_64-w64-mingw32-windres; do
    command -v "$dependency" >/dev/null 2>&1 \
        || die "missing dependency: $dependency"
done

declare -a payloads=("$CONTRACT" "$SCRIPT" "$DRIVER_ZIP" "$GPUZ_EXE")
for payload in "${payloads[@]}"; do
    payload=$(realpath -e -- "$payload") || die "payload does not exist"
    [[ -f "$payload" && ! -L "$payload" && -r "$payload" ]] \
        || die "payload must be a readable regular non-symlink: $payload"
done
CONTRACT=$(realpath -e -- "$CONTRACT")
SCRIPT=$(realpath -e -- "$SCRIPT")
DRIVER_ZIP=$(realpath -e -- "$DRIVER_ZIP")
GPUZ_EXE=$(realpath -e -- "$GPUZ_EXE")

[[ "$(sha256sum -- "$DRIVER_ZIP" | awk '{print $1}')" == \
   a3d7ad8b8082d6ac6214565b4766b5190a819bc9b7574765b14897e0db809690 ]] \
    || die "driver ZIP is not the locked, unmodified GRID 538.33 archive"
[[ "$(stat -c %s -- "$DRIVER_ZIP")" == 860703853 ]] \
    || die "driver ZIP byte count changed"

output_parent=$(dirname -- "$OUTPUT")
mkdir -p -- "$output_parent"
output_parent=$(realpath -e -- "$output_parent")
OUTPUT="$output_parent/$(basename -- "$OUTPUT")"
[[ ! -L "$OUTPUT" && ( ! -e "$OUTPUT" || -f "$OUTPUT" ) ]] \
    || die "output is not a regular path"

tmp=$(mktemp -d "$output_parent/.vgpu-production-exe.XXXXXXXX")
cleanup() { rm -rf -- "$tmp"; }
trap cleanup EXIT
install -m 0600 -- "$here/vgpu_production_migration.c" \
    "$tmp/vgpu_production_migration.c"
install -m 0600 -- "$here/vgpu_production_migration.rc" \
    "$tmp/vgpu_production_migration.rc"
install -m 0600 -- "$here/vgpu_production_migration.manifest" \
    "$tmp/vgpu_production_migration.manifest"

(
    cd "$tmp"
    x86_64-w64-mingw32-windres --use-temp-file \
        -i vgpu_production_migration.rc \
        -o vgpu_production_migration_res.o
    x86_64-w64-mingw32-gcc -std=c11 -O2 -Wall -Wextra -Werror \
        -static -s -municode -Wl,--no-insert-timestamp \
        -o launcher.exe vgpu_production_migration.c \
        vgpu_production_migration_res.o \
        -ladvapi32 -lbcrypt -lshell32 -luser32
)

staged="$tmp/VgpuProductionMigration.exe"
python3 -I -S - "$tmp/launcher.exe" "$staged" \
        "$CONTRACT" "$SCRIPT" "$DRIVER_ZIP" "$GPUZ_EXE" <<'PY'
import hashlib
import os
import shutil
import struct
import sys

base, output, *payloads = sys.argv[1:]
magic = b"QEMU_VGPU_PRODUCTION_MIGRATION_V1"
if len(magic) > 40:
    raise SystemExit("internal footer magic is too long")
magic = magic.ljust(40, b"\0")
entries = []
with open(output, "xb") as target:
    with open(base, "rb") as source:
        shutil.copyfileobj(source, target, 1024 * 1024)
    base_bytes = target.tell()
    for path in payloads:
        digest = hashlib.sha256()
        size = 0
        with open(path, "rb") as source:
            while True:
                block = source.read(4 * 1024 * 1024)
                if not block:
                    break
                target.write(block)
                digest.update(block)
                size += len(block)
        entries.append((size, digest.digest()))
    footer = bytearray(struct.pack("<40sIIQ", magic, 1, len(entries), base_bytes))
    for size, digest in entries:
        footer.extend(struct.pack("<Q32s", size, digest))
    target.write(footer)
    target.flush()
    os.fsync(target.fileno())
os.chmod(output, 0o600)
PY

staged_sha=$(sha256sum -- "$staged" | awk '{print toupper($1)}')
staged_bytes=$(stat -c %s -- "$staged")
publish="$output_parent/.$(basename -- "$OUTPUT").new.$$.$RANDOM"
install -m 0600 -- "$staged" "$publish"
mv -Tf -- "$publish" "$OUTPUT"

echo "[vgpu-production-exe] output=$OUTPUT"
echo "[vgpu-production-exe] bytes=$staged_bytes sha256=$staged_sha"
echo "[vgpu-production-exe] driver archive is the locked original GRID 538.33 ZIP"
