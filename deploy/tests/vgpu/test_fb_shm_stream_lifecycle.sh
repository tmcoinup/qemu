#!/usr/bin/env bash
# Exercise the standalone fb-shm streamer lifecycle without QEMU or ffmpeg.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
HELPER="$REPO_ROOT/deploy/fb-shm-stream.sh"
STOP_VM="$REPO_ROOT/deploy/scripts/stop-vm.sh"
TMP_DIR="$(mktemp -d)"
export IMAGE_ROOT="$TMP_DIR"
VM_ROOT="$TMP_DIR/vms"
VM_ID=$((980000000 + $$ % 10000000))
INSTANCE="$VM_ROOT/${VM_ID}"
SOCK="$INSTANCE/run/fb-shm.sock"
FAKE_STREAMER="$TMP_DIR/qemu-fb-shm-stream"
ARGS_FILE="$TMP_DIR/args"
SERVER_PID=""
STALE_PID=""

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

cleanup() {
    if [[ -n "$STALE_PID" ]]; then
        kill -TERM -- "-$STALE_PID" 2>/dev/null || true
        kill -TERM "$STALE_PID" 2>/dev/null || true
        wait "$STALE_PID" 2>/dev/null || true
    fi
    if [[ -n "$SERVER_PID" ]]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    VM_ROOT="$VM_ROOT" "$HELPER" stop "$VM_ID" >/dev/null 2>&1 || true
    rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$INSTANCE/run" "$INSTANCE/log"

cat >"$FAKE_STREAMER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: "${FAKE_STREAM_ARGS:?}"
printf '%s\n' "$@" >"$FAKE_STREAM_ARGS"
echo "[fb-shm] connected: 1920x1080 shm=16589056B" >&2
trap 'exit 0' TERM INT
while :; do
    sleep 0.1
done
EOF
chmod +x "$FAKE_STREAMER"

python3 - "$SOCK" <<'PY' &
import os
import signal
import socket
import sys
import time

path = sys.argv[1]
try:
    os.unlink(path)
except FileNotFoundError:
    pass
listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
listener.bind(path)
listener.listen(1)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
while True:
    time.sleep(1)
PY
SERVER_PID=$!
for _ in $(seq 1 100); do
    [[ -S "$SOCK" ]] && break
    sleep 0.02
done
[[ -S "$SOCK" ]] || fail "fake fb-shm socket was not created"

FAKE_STREAM_ARGS="$ARGS_FILE" VM_ROOT="$VM_ROOT" \
    "$HELPER" start "$VM_ID" \
    --stream-bin "$FAKE_STREAMER" \
    --sock "$SOCK" \
    --output 'rtmps://stream.example.test/app/key?token=abc&v=1' \
    --roi 100,50,1280,720 \
    --rate 60 \
    --encoder h264_nvenc \
    --bitrate 8M \
    --preset p2 \
    --gop 120 \
    --container flv \
    --mode shm \
    --start-timeout 2 >"$TMP_DIR/start.out"

grep -Fq "vm${VM_ID} ready" "$TMP_DIR/start.out" ||
    fail "helper did not report readiness"
VM_ROOT="$VM_ROOT" "$HELPER" health "$VM_ID" >"$TMP_DIR/health.out"
grep -Fq "vm${VM_ID} healthy" "$TMP_DIR/health.out" ||
    fail "health check did not pass"

for expected in \
    --sock "$SOCK" \
    --output 'rtmps://stream.example.test/app/key?token=abc&v=1' \
    --roi 100,50,1280,720 \
    --rate 60 \
    --encoder h264_nvenc \
    --bitrate 8M \
    --preset p2 \
    --gop 120 \
    --container flv \
    --mode shm; do
    grep -Fxq -- "$expected" "$ARGS_FILE" ||
        fail "streamer argv missing: $expected"
done

[[ "$(stat -c %a "$INSTANCE/run/fb-shm-stream.pid")" == 600 ]] ||
    fail "PID file is not mode 0600"
[[ "$(stat -c %a "$INSTANCE/log/fb-shm-stream.log")" == 600 ]] ||
    fail "stream log is not mode 0600"

if FAKE_STREAM_ARGS="$ARGS_FILE" VM_ROOT="$VM_ROOT" \
    "$HELPER" start "$VM_ID" --stream-bin "$FAKE_STREAMER" \
    --sock "$SOCK" --output rtmp://stream.example.test/live/key \
    >"$TMP_DIR/duplicate.out" 2>"$TMP_DIR/duplicate.err"; then
    fail "duplicate start unexpectedly succeeded"
fi
grep -Fq '已运行' "$TMP_DIR/duplicate.err" ||
    fail "duplicate start did not explain the conflict"

VM_ROOT="$VM_ROOT" "$HELPER" stop "$VM_ID" >"$TMP_DIR/stop.out"
if VM_ROOT="$VM_ROOT" "$HELPER" status "$VM_ID" >/dev/null 2>&1; then
    fail "status still reports running after stop"
fi
[[ ! -e "$INSTANCE/run/fb-shm-stream.pid" ]] ||
    fail "stop left a stale PID file"

# The functional default is CPU encoding; NVENC remains an explicit opt-in
# because a host may expose the ffmpeg encoder name without a usable libcuda.
FAKE_STREAM_ARGS="$ARGS_FILE" VM_ROOT="$VM_ROOT" \
    "$HELPER" start "$VM_ID" \
    --stream-bin "$FAKE_STREAMER" \
    --sock "$SOCK" \
    --output rtmp://stream.example.test/live/default \
    --start-timeout 2 >/dev/null
grep -Fxq -- libx264 "$ARGS_FILE" ||
    fail "default encoder is not libx264"
grep -Fxq -- veryfast "$ARGS_FILE" ||
    fail "default preset is not veryfast"
VM_ROOT="$VM_ROOT" "$STOP_VM" "$VM_ID" >"$TMP_DIR/stop-vm.out"
if VM_ROOT="$VM_ROOT" "$HELPER" status "$VM_ID" >/dev/null 2>&1; then
    fail "stop-vm did not stop the streamer sidecar"
fi
grep -Fq "no qemu-system for vm${VM_ID}" "$TMP_DIR/stop-vm.out" ||
    fail "stop-vm did not take the no-QEMU cleanup path"

assert_rejected() {
    local label=$1
    shift

    if FAKE_STREAM_ARGS="$ARGS_FILE" VM_ROOT="$VM_ROOT" \
        "$HELPER" start "$VM_ID" --stream-bin "$FAKE_STREAMER" \
        --sock "$SOCK" "$@" >"$TMP_DIR/reject.out" 2>"$TMP_DIR/reject.err"; then
        fail "$label unexpectedly succeeded"
    fi
}

assert_rejected "missing output"
assert_rejected "SRT listener" \
    --output 'srt://stream.example.test:9000?mode=listener'
assert_rejected "wildcard target" --output 'udp://0.0.0.0:9000'
assert_rejected "invalid ROI" \
    --output rtmp://stream.example.test/live/key --roi 0,0,0,720
assert_rejected "encoder injection" \
    --output rtmp://stream.example.test/live/key \
    --encoder 'h264_nvenc;touch-bad'
assert_rejected "URL injection" \
    --output 'rtmp://stream.example.test/live/$(touch-bad)'
: >"$TMP_DIR/existing.mp4"
assert_rejected "existing local output" --output "$TMP_DIR/existing.mp4"

# A reused/stale PID record must never make stop signal an unrelated process.
setsid sleep 60 &
STALE_PID=$!
printf '%s\n' "$STALE_PID" >"$INSTANCE/run/fb-shm-stream.pid"
printf '%s\n' 0 >"$INSTANCE/run/fb-shm-stream.starttime"
VM_ROOT="$VM_ROOT" "$HELPER" stop "$VM_ID" >"$TMP_DIR/stale-stop.out"
kill -0 "$STALE_PID" 2>/dev/null ||
    fail "stale PID cleanup killed an unrelated process"
[[ ! -e "$INSTANCE/run/fb-shm-stream.pid" ]] ||
    fail "stale PID record was not cleaned"

echo "PASS: fb-shm streamer lifecycle, validation and PID safety"
