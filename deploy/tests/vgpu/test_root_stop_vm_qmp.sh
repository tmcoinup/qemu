#!/usr/bin/env bash
# Verify that the root stop path uses QMP system_powerdown without needing a
# guest IP or WinRM, then cleans only this VM's runtime files.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
STOP_VM="$REPO_ROOT/deploy/stop-vm.sh"
TMP_DIR="$(mktemp -d)"
VM_ID=$((970000000 + $$ % 10000000))
INSTANCE="$TMP_DIR/vm${VM_ID}"
QMP_SOCK="$INSTANCE/run/qmp.sock"
QMP_RECORD="$TMP_DIR/qmp.record"
FAKE_QEMU="$TMP_DIR/qemu-system-x86_64"
FAKE_PID=""

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

cleanup() {
    if [[ -n "$FAKE_PID" ]]; then
        kill "$FAKE_PID" 2>/dev/null || true
        wait "$FAKE_PID" 2>/dev/null || true
    fi
    rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$INSTANCE/run"

cat >"$FAKE_QEMU" <<'PY'
#!/usr/bin/env python3
import json
import os
import socket
import sys

path = sys.argv[sys.argv.index("--qmp-path") + 1]
record = os.environ["QMP_RECORD"]
try:
    os.unlink(path)
except FileNotFoundError:
    pass
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(path)
server.listen(1)
conn, _ = server.accept()
stream = conn.makefile("rwb", buffering=0)
stream.write(b'{"QMP":{"version":{"qemu":{"major":11,"minor":0,"micro":2},"package":""},"capabilities":[]}}\r\n')
while True:
    line = stream.readline()
    if not line:
        raise SystemExit(2)
    request = json.loads(line)
    command = request.get("execute")
    stream.write(b'{"return":{}}\r\n')
    if command == "system_powerdown":
        with open(record, "w", encoding="utf-8") as output:
            output.write(command + "\n")
        break
conn.close()
server.close()
PY
chmod +x "$FAKE_QEMU"

QMP_RECORD="$QMP_RECORD" "$FAKE_QEMU" -name "vm${VM_ID}" \
    --qmp-path "$QMP_SOCK" &
FAKE_PID=$!
for _ in $(seq 1 100); do
    [[ -S "$QMP_SOCK" ]] && break
    kill -0 "$FAKE_PID" 2>/dev/null || fail "fake QEMU exited before QMP was ready"
    sleep 0.02
done
[[ -S "$QMP_SOCK" ]] || fail "fake QMP socket was not created"
ln -s "$QMP_SOCK" "${QMP_SOCK}.proxy"

VM_ROOT="$TMP_DIR" "$STOP_VM" "$VM_ID" >"$TMP_DIR/stop.out" 2>"$TMP_DIR/stop.err"
wait "$FAKE_PID"
FAKE_PID=""

grep -Fq '[down] QMP → system_powerdown' "$TMP_DIR/stop.out" \
    || fail "stop-vm did not report the QMP powerdown path"
grep -Fxq system_powerdown "$QMP_RECORD" \
    || fail "fake QEMU did not receive system_powerdown"
if grep -Fq '自动 --force' "$TMP_DIR/stop.out"; then
    fail "QMP-capable VM was unnecessarily force-killed"
fi
[[ ! -e "$QMP_SOCK" ]] || fail "stale QMP socket was not removed"
[[ ! -L "${QMP_SOCK}.proxy" ]] || fail "stale QMP compatibility alias was not removed"

echo "PASS: root stop-vm uses QMP powerdown without guest networking"
