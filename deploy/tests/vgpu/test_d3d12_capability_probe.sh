#!/usr/bin/env bash
# Rebuild and audit the process-agnostic native D3D12 OPTIONS5 probes.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
PROBE_DIR="$REPO_ROOT/deploy/guest/d3d12-capability-probe"
SOURCE="$PROBE_DIR/d3d12_capability_probe.c"
BUILDER="$PROBE_DIR/build.sh"
RUNNER="$PROBE_DIR/Run-Native-D3D12-Probe.cmd"
COORDINATOR="$REPO_ROOT/deploy/guest/install-system-nvapi-projection.ps1"
PACKAGER="$REPO_ROOT/deploy/package-system-nvapi-projection.sh"
TMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TMP_DIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

for tool in i686-w64-mingw32-gcc x86_64-w64-mingw32-gcc \
        i686-w64-mingw32-objdump x86_64-w64-mingw32-objdump strings; do
    command -v "$tool" >/dev/null || fail "missing build tool: $tool"
done
for file in "$SOURCE" "$BUILDER" "$RUNNER" "$COORDINATOR" "$PACKAGER"; do
    [[ -r "$file" && ! -L "$file" ]] || fail "missing or unsafe input: $file"
done
bash -n "$BUILDER"

for marker in \
        'CreateDXGIFactory1' \
        'D3D12CreateDevice' \
        'D3D12_FEATURE_D3D12_OPTIONS5' \
        'D3D12_RAYTRACING_TIER_NOT_SUPPORTED' \
        '--require-tier-zero' \
        'D3D12_NATIVE_VERIFY PASS'; do
    grep -Fq -- "$marker" "$SOURCE" || fail "source lacks $marker"
done
if grep -Eiq 'ludashi|鲁大师|gpu-z|gpuz|hwinfo|aida' \
        "$SOURCE" "$BUILDER" "$RUNNER"; then
    fail 'native capability probe contains an application-specific branch'
fi
if grep -Eiq 'testsigning|nointegritychecks|bcdedit|\.sys([^-A-Za-z0-9]|$)|certutil' \
        "$SOURCE" "$BUILDER" "$RUNNER"; then
    fail 'native capability probe crosses the BCD/driver safety boundary'
fi

build_one() {
    local compiler=$1 output=$2
    "$compiler" \
        -std=c11 -Os -Wall -Wextra -Werror \
        -D_WIN32_WINNT=0x0A00 \
        -Wl,--strip-all,--no-insert-timestamp \
        -o "$output" "$SOURCE" \
        -ld3d12 -ldxgi -lole32
}

for spec in \
        'i686-w64-mingw32:D3D12CapabilityProbe32.exe:pei-i386' \
        'x86_64-w64-mingw32:D3D12CapabilityProbe64.exe:pei-x86-64'; do
    IFS=: read -r compiler name format <<<"$spec"
    build_one "$compiler-gcc" "$TMP_DIR/a-$name"
    build_one "$compiler-gcc" "$TMP_DIR/b-$name"
    cmp -s "$TMP_DIR/a-$name" "$TMP_DIR/b-$name" || \
        fail "$name is not reproducible"
    cmp -s "$TMP_DIR/a-$name" "$PROBE_DIR/$name" || \
        fail "$name is stale; run $BUILDER"
    "$compiler-objdump" -f "$PROBE_DIR/$name" >"$TMP_DIR/$name.file"
    "$compiler-objdump" -p "$PROBE_DIR/$name" >"$TMP_DIR/$name.pe"
    strings -a "$PROBE_DIR/$name" >"$TMP_DIR/$name.strings"
    grep -Fq "file format $format" "$TMP_DIR/$name.file" || \
        fail "$name has the wrong PE architecture"
    grep -Eq 'Time/Date[[:space:]]+.*(1969|1970)' "$TMP_DIR/$name.pe" || \
        fail "$name contains a nonzero PE timestamp"
    grep -Fq 'D3D12_NATIVE_VERIFY PASS' "$TMP_DIR/$name.strings" || \
        fail "$name lacks the runtime PASS marker"
done

install_line=$(grep -nF 'Invoke-NativeD3D12Probes $payload' "$COORDINATOR" |
    head -n 1 | cut -d: -f1)
write_line=$(grep -nF 'Copy-PayloadDurably $payload' "$COORDINATOR" |
    head -n 1 | cut -d: -f1)
[[ -n "$install_line" && -n "$write_line" && "$install_line" -lt "$write_line" ]] || \
    fail 'native D3D12 gate is not before the first durable payload write'
[[ $(grep -Fc 'Invoke-NativeD3D12Probes $payload' "$COORDINATOR") -eq 2 ]] || \
    fail 'native D3D12 gate must run during both Install and Verify'
for name in D3D12CapabilityProbe32.exe D3D12CapabilityProbe64.exe; do
    grep -Fq "$name" "$PACKAGER" || fail "system package omits $name"
done

echo 'PASS: native x86/x64 D3D12 OPTIONS5 probes are generic, reproducible and fail-closed'
