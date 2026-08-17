#!/usr/bin/env bash
# Exercise ctl-vm against a fake QMP socket; no VM or display is touched.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CTL="$REPO_ROOT/deploy/scripts/ctl-vm.sh"
VMCTL="$REPO_ROOT/deploy/scripts/vmctl.sh"
TMP_DIR="$(mktemp -d)"
VMS_DIR="$TMP_DIR/vms"
RUN_DIR="$VMS_DIR/42/run"
QMP_SOCK="$RUN_DIR/qmp.sock"
trap 'rm -rf -- "$TMP_DIR"' EXIT
mkdir -p "$RUN_DIR" "$VMS_DIR/42/log" "$VMS_DIR/42/backups/disks" \
    "$VMS_DIR/42/backups/nvram" "$VMS_DIR/shared/bases" "$VMS_DIR/control"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

cat >"$TMP_DIR/fake-qmp.py" <<'PY'
#!/usr/bin/env python3
import json
import os
import socket
import sys

path, record, vm_name, has_fb = sys.argv[1:]
try:
    os.unlink(path)
except FileNotFoundError:
    pass
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(path)
server.listen(1)
conn, _ = server.accept()
stream = conn.makefile("rwb", buffering=0)
stream.write(b'{"QMP":{"version":{"qemu":{"major":11,"minor":0,"micro":0},"package":""},"capabilities":[]}}\r\n')
with open(record, "w", encoding="utf-8") as output:
    while True:
        line = stream.readline()
        if not line:
            break
        request = json.loads(line)
        command = request["execute"]
        arguments = request.get("arguments", {})
        output.write(f"{command} {arguments.get('name', '')}\n")
        output.flush()
        if command == "query-name":
            result = {"name": vm_name}
            response = {"return": result, "id": request.get("id")}
        elif command == "query-display-options":
            response = {"return": {"type": "sdl"}, "id": request.get("id")}
        elif arguments.get("name") == "fb-shm" and has_fb != "1":
            response = {
                "error": {
                    "class": "GenericError",
                    "desc": "no DisplayChangeListener whose dpy_name starts with 'fb-shm'",
                },
                "id": request.get("id"),
            }
        else:
            response = {"return": {}, "id": request.get("id")}
        stream.write((json.dumps(response) + "\r\n").encode())
conn.close()
server.close()
PY
chmod +x "$TMP_DIR/fake-qmp.py"

start_fake() {
    local record=$1 name=${2:-vm42} has_fb=${3:-1}
    "$TMP_DIR/fake-qmp.py" "$QMP_SOCK" "$record" "$name" "$has_fb" &
    FAKE_PID=$!
    for _ in $(seq 1 100); do
        [[ -S "$QMP_SOCK" ]] && return 0
        kill -0 "$FAKE_PID" 2>/dev/null || fail "fake QMP exited early"
        sleep 0.01
    done
    fail "fake QMP socket did not appear"
}

start_fake "$TMP_DIR/status.record"
status_output=$("$CTL" 42 status --vms-dir "$VMS_DIR")
wait "$FAKE_PID"
grep -Fq 'VM_NAME=vm42' <<<"$status_output" || fail "status did not verify VM name"
grep -Fq 'DISPLAY_BACKEND=sdl' <<<"$status_output" || fail "status omitted backend"

start_fake "$TMP_DIR/hide.record"
"$VMCTL" display 42 window-hide --vms-dir "$VMS_DIR" >"$TMP_DIR/hide.out"
wait "$FAKE_PID"
grep -Fxq 'display-pause sdl2' "$TMP_DIR/hide.record" ||
    fail "vmctl display did not pause the SDL listener"

start_fake "$TMP_DIR/stream.record"
"$CTL" 42 stream-only --vms-dir "$VMS_DIR" >"$TMP_DIR/stream.out"
wait "$FAKE_PID"
resume_line=$(grep -nFx 'display-resume fb-shm' "$TMP_DIR/stream.record" | cut -d: -f1)
hide_line=$(grep -nFx 'display-pause sdl2' "$TMP_DIR/stream.record" | cut -d: -f1)
[[ -n "$resume_line" && -n "$hide_line" && "$resume_line" -lt "$hide_line" ]] ||
    fail "stream-only did not validate/resume fb-shm before hiding SDL"

start_fake "$TMP_DIR/no-stream.record" vm42 0
if "$CTL" 42 stream-only --vms-dir "$VMS_DIR" >"$TMP_DIR/no-stream.out" 2>&1; then
    fail "stream-only succeeded without an fb-shm listener"
fi
wait "$FAKE_PID"
! grep -Fq 'display-pause sdl2' "$TMP_DIR/no-stream.record" ||
    fail "stream-only hid SDL after fb-shm validation failed"

start_fake "$TMP_DIR/wrong-vm.record" vm99
if "$CTL" 42 window-hide --vms-dir "$VMS_DIR" >"$TMP_DIR/wrong-vm.out" 2>&1; then
    fail "controller accepted the wrong QMP VM identity"
fi
wait "$FAKE_PID"
grep -Fq 'QMP 身份不匹配' "$TMP_DIR/wrong-vm.out" ||
    fail "identity rejection did not explain the mismatch"

echo "PASS: safe runtime SDL/fb-shm display control"
