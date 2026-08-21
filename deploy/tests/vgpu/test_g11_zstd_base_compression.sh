#!/usr/bin/env bash
# Exercise the G-11 fast qcow2 path with a tiny credential-free image.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SEAL="$ROOT/deploy/scripts/seal-base.sh"
BUILD_G11="$ROOT/deploy/build-g11-private-base.sh"
QEMU_IMG="$ROOT/build/qemu-img"
[[ -x "$QEMU_IMG" ]] || QEMU_IMG=$(command -v qemu-img || true)

fail() { echo "FAIL: $*" >&2; exit 1; }
[[ -n "$QEMU_IMG" && -x "$QEMU_IMG" ]] || {
    echo "SKIP: qemu-img is unavailable"
    exit 0
}
command -v jq >/dev/null 2>&1 || {
    echo "SKIP: jq is unavailable"
    exit 0
}

TMP_DIR=$(mktemp -d /tmp/g11-zstd-base-test.XXXXXXXX)
cleanup() { rm -rf -- "$TMP_DIR"; }
trap cleanup EXIT
IMAGE_ROOT="$TMP_DIR/images"
VM_ROOT="$IMAGE_ROOT/vms"
VM_ID=919977
BASE_NAME=zstd-test-base
export IMAGE_ROOT VM_ROOT QEMU_IMG
export VMS_DIR="$VM_ROOT" VM_INSTANCES_DIR="$VM_ROOT"
mkdir -p "$VM_ROOT/$VM_ID" "$VM_ROOT/_base" "$VM_ROOT/control"
"$QEMU_IMG" create -q -f qcow2 "$VM_ROOT/$VM_ID/disk.qcow2" 64M

if "$SEAL" "$VM_ID" "$BASE_NAME" --no-clean \
        --compression-type invalid >"$TMP_DIR/type.out" 2>&1; then
    fail "seal-base accepted an invalid compression type"
fi
grep -Fq -- '--compression-type must be zlib or zstd' "$TMP_DIR/type.out" ||
    fail "invalid compression type did not produce a clear error"

if "$SEAL" "$VM_ID" "$BASE_NAME" --no-clean \
        --compression-parallel 17 >"$TMP_DIR/parallel.out" 2>&1; then
    fail "seal-base accepted parallelism above qemu-img's supported limit"
fi
grep -Fq -- '--compression-parallel must be an integer in 1..16' \
    "$TMP_DIR/parallel.out" ||
    fail "invalid compression parallelism did not produce a clear error"

"$SEAL" "$VM_ID" "$BASE_NAME" --yes --no-clean \
    --compression-type zstd --compression-parallel 4 --progress \
    >"$TMP_DIR/seal.out" 2>&1
BASE="$VM_ROOT/_base/$BASE_NAME.qcow2"
[[ -f "$BASE" && ! -L "$BASE" ]] || fail "zstd base was not published"
"$QEMU_IMG" check -q "$BASE"
[[ "$("$QEMU_IMG" info --output=json -- "$BASE" |
    jq -r '."format-specific".data."compression-type"')" == zstd ]] ||
    fail "published base is not qcow2 zstd"
grep -Fq 'compression=zstd, parallel=4' "$TMP_DIR/seal.out" ||
    fail "selected compressor/parallelism was not reported"
grep -Eq '\([[:space:]]*100([.]00)?/100%\)' "$TMP_DIR/seal.out" ||
    fail "qemu-img percentage progress was not shown"

# Private one-command sealing follows V-11: direct filename, no archive, and
# an existing final base is never silently replaced.
SINGLE_BASE_DIR="$IMAGE_ROOT/_base"
SINGLE_BASE_NAME=single-image-test
VM_BASE_DIR="$SINGLE_BASE_DIR" \
VM_BASE_ARCHIVE_DIR="$SINGLE_BASE_DIR/archive" \
    "$SEAL" "$VM_ID" "$SINGLE_BASE_NAME" --yes --no-clean --single-image \
    >"$TMP_DIR/single.out" 2>&1
SINGLE_BASE="$SINGLE_BASE_DIR/$SINGLE_BASE_NAME.qcow2"
[[ -f "$SINGLE_BASE" && ! -d "$SINGLE_BASE_DIR/archive" ]] ||
    fail "single-image seal created an archive directory or missed the base"
SINGLE_SHA=$(sha256sum -- "$SINGLE_BASE" | awk '{print $1}')
if VM_BASE_DIR="$SINGLE_BASE_DIR" \
        VM_BASE_ARCHIVE_DIR="$SINGLE_BASE_DIR/archive" \
        "$SEAL" "$VM_ID" "$SINGLE_BASE_NAME" --yes --no-clean --single-image \
        >"$TMP_DIR/single-existing.out" 2>&1; then
    fail "single-image seal replaced an existing V-11-style base"
fi
grep -Fq '与 V-11 一样拒绝覆盖' "$TMP_DIR/single-existing.out" ||
    fail "single-image existing-base refusal was not clear"
[[ "$(sha256sum -- "$SINGLE_BASE" | awk '{print $1}')" == "$SINGLE_SHA" ]] ||
    fail "single-image refusal changed the existing base"

grep -Fq 'COMPRESSION_TYPE=zstd' "$BUILD_G11" ||
    fail "G-11 private builder does not default to zstd"
grep -Fq 'SEAL_ARGS+=(--progress)' "$BUILD_G11" ||
    fail "G-11 private builder does not enable percentage progress"
grep -Fq -- '--compression-parallel' "$BUILD_G11" ||
    fail "G-11 private builder does not expose compression parallelism"

echo "PASS: G-11 zstd sealing validates support, parallelism and percentage progress"
