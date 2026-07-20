#!/usr/bin/env bash
# End-to-end SHM/ROI/rawvideo/libx264 smoke test with a TCG VGA guest.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$REPO_ROOT/build}"
QEMU="$BUILD_DIR/qemu-system-x86_64"
STREAMER="$BUILD_DIR/qemu-fb-shm-stream"
TMP_DIR="$(mktemp -d)"
SOCK="$TMP_DIR/fb.sock"
OUTPUT="$TMP_DIR/roi.mkv"
QEMU_LOG="$TMP_DIR/qemu.log"
STREAM_LOG="$TMP_DIR/stream.log"
QEMU_PID=""

fail() {
    echo "FAIL: $*" >&2
    [[ ! -f "$QEMU_LOG" ]] || tail -30 "$QEMU_LOG" >&2
    [[ ! -f "$STREAM_LOG" ]] || tail -30 "$STREAM_LOG" >&2
    exit 1
}

cleanup() {
    if [[ "$QEMU_PID" =~ ^[1-9][0-9]*$ ]] &&
            kill -0 "$QEMU_PID" 2>/dev/null; then
        kill -TERM "$QEMU_PID" 2>/dev/null || true
        wait "$QEMU_PID" 2>/dev/null || true
    fi
    rm -r -- "$TMP_DIR"
}
trap cleanup EXIT

[[ -x "$QEMU" ]] || fail "QEMU target is not built: $QEMU"
[[ -x "$STREAMER" ]] || fail "streamer target is not built: $STREAMER"
command -v ffmpeg >/dev/null 2>&1 || fail "ffmpeg is required"
command -v ffprobe >/dev/null 2>&1 || fail "ffprobe is required"
command -v timeout >/dev/null 2>&1 || fail "timeout is required"

# Start with a 640x480 producer, then request a smaller offset ROI from the
# consumer.  This forces the shared header/encoder generation to change and
# verifies that a local output can restart without an interactive overwrite
# prompt or a corrupt final file.
"$QEMU" \
    -machine q35,accel=tcg -nodefaults -m 64M \
    -device VGA -display none -serial none -monitor none \
    -object "fb-shm,id=g11-e2e,path=${SOCK},rate=30,width=640,height=480" \
    >"$QEMU_LOG" 2>&1 &
QEMU_PID=$!

for _ in $(seq 1 100); do
    [[ -S "$SOCK" ]] && break
    kill -0 "$QEMU_PID" 2>/dev/null || break
    sleep 0.02
done
[[ -S "$SOCK" ]] || fail "QEMU did not create the fb-shm socket"

timeout 15 "$STREAMER" \
    --sock "$SOCK" --output "$OUTPUT" \
    --encoder libx264 --preset veryfast --bitrate 1M --gop 30 \
    --rate 30 --roi 10,10,320,240 --mode shm --max-frames 2 \
    >"$STREAM_LOG" 2>&1 ||
    fail "streamer did not encode two ROI frames"

[[ -s "$OUTPUT" ]] || fail "streamer output is empty"
probe=$(
    ffprobe -v error -select_streams v:0 \
        -show_entries stream=codec_name,width,height \
        -of default=noprint_wrappers=1 "$OUTPUT"
) || fail "ffprobe rejected the streamer output"
grep -Fxq 'codec_name=h264' <<<"$probe" ||
    fail "output codec is not H.264"
grep -Fxq 'width=320' <<<"$probe" ||
    fail "runtime ROI width was not applied"
grep -Fxq 'height=240' <<<"$probe" ||
    fail "runtime ROI height was not applied"

kill -TERM "$QEMU_PID"
wait "$QEMU_PID" 2>/dev/null || true
QEMU_PID=""

echo "PASS: fb-shm runtime ROI encoded end-to-end to a valid H.264 file"
