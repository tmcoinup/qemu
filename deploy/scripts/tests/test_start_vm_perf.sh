#!/usr/bin/env bash
# Validate the launcher-side storage path without booting a guest.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
START_VM="$REPO_ROOT/deploy/scripts/start-vm.sh"
QEMU="${QEMU:-$REPO_ROOT/build/qemu-system-x86_64}"
QEMU_IMG="${QEMU_IMG:-$REPO_ROOT/build/qemu-img}"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

require_executable() {
    local path="$1"
    [[ -x "$path" ]] || fail "missing executable: $path"
}

qmp_quit() {
    local sock="$1"
    python3 - "$sock" <<'PY'
import socket
import sys
import time

sock_path = sys.argv[1]
client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
for _ in range(50):
    try:
        client.connect(sock_path)
        break
    except FileNotFoundError:
        time.sleep(0.1)
else:
    raise SystemExit("QMP socket did not appear")

# QMP sends a greeting first; read it before enabling capabilities.
client.recv(4096)
client.sendall(b'{"execute":"qmp_capabilities","id":"caps"}\n')
client.recv(4096)
client.sendall(b'{"execute":"quit","id":"quit"}\n')
client.settimeout(2.0)
try:
    while True:
        data = client.recv(4096)
        if not data or b'"id":"quit"' in data or b'"id": "quit"' in data:
            break
except TimeoutError:
    pass
client.close()
PY
}

test_dry_run_has_safe_nvme_storage() {
    local out="$1"
    local nvme_line

    DRY_RUN=1 TPM=0 HOST_TUNE=0 INSTANCE=9876 \
        "$START_VM" --no-sdl --no-fb-shm --no-bridge > "$out"

    nvme_line="$(grep -F -- "nvme,id=nvmectl0" "$out" || true)"
    [[ "$nvme_line" != *"iothread=io1"* ]] \
        || fail "dry-run argv must not bind emulated nvme to iothread"
    grep -Fx -- "iothread,id=io1" "$out" >/dev/null \
        && fail "dry-run argv must not create unused nvme iothread"
    [[ "$nvme_line" == *"use-samsung-id=on"* ]] \
        || fail "dry-run argv lost Samsung NVMe identity"
    [[ "$nvme_line" == *"model-number=Samsung"* && "$nvme_line" == *"firmware-rev="* ]] \
        || fail "dry-run argv lost model/firmware spoofing"
    [[ "$nvme_line" == *"serial="* ]] \
        || fail "dry-run argv lost NVMe serial"
}

test_qemu_accepts_samsung_nvme() {
    local img="$1"
    local sock="$2"
    local err="$3"
    local qemu_pid=""

    "$QEMU_IMG" create -q -f qcow2 "$img" 64M
    "$QEMU" \
        -machine q35,accel=tcg \
        -nodefaults \
        -display none \
        -S \
        -drive file="$img",if=none,id=nvm0,format=qcow2,cache=none,aio=threads \
        -device pcie-root-port,id=rp1,bus=pcie.0,slot=1 \
        -device nvme,id=nvmectl0,bus=rp1,drive=nvm0,use-samsung-id=on,serial=test123,model-number="Samsung SSD 970 EVO 1TB",firmware-rev=1B2QEXE7 \
        -qmp unix:"$sock",server=on,wait=off \
        2> "$err" &
    qemu_pid=$!

    for _ in $(seq 1 50); do
        [[ -S "$sock" ]] && break
        kill -0 "$qemu_pid" 2>/dev/null || {
            sed -n '1,80p' "$err" >&2
            fail "qemu exited before QMP became ready"
        }
        sleep 0.1
    done

    [[ -S "$sock" ]] || fail "qemu did not create QMP socket"
    qmp_quit "$sock"
    wait "$qemu_pid"

    if [[ -s "$err" ]]; then
        sed -n '1,80p' "$err" >&2
        fail "qemu emitted stderr while accepting Samsung nvme identity"
    fi
}

test_qmp_multi_accepts_two_clients() {
    local sock="$1"
    local err="$2"
    local qemu_pid=""

    "$QEMU" \
        -machine q35,accel=tcg \
        -nodefaults \
        -display none \
        -S \
        -qmp unix:"$sock",server=on,wait=off,multi=on \
        2> "$err" &
    qemu_pid=$!

    python3 - "$sock" <<'PY'
import json
import socket
import sys
import time

sock_path = sys.argv[1]

def connect_qmp(name):
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    for _ in range(50):
        try:
            client.connect(sock_path)
            break
        except FileNotFoundError:
            time.sleep(0.1)
    else:
        raise SystemExit(f"{name}: QMP socket did not appear")
    stream = client.makefile("rwb", buffering=0)
    greeting = json.loads(stream.readline())
    assert "QMP" in greeting, greeting
    stream.write(json.dumps({
        "execute": "qmp_capabilities",
        "id": f"{name}-caps",
    }).encode() + b"\n")
    caps = json.loads(stream.readline())
    assert caps.get("id") == f"{name}-caps", caps
    assert "return" in caps, caps
    return client, stream

c1, s1 = connect_qmp("c1")
c2, s2 = connect_qmp("c2")

s1.write(b'{"execute":"query-status","id":"one"}\n')
s2.write(b'{"execute":"query-status","id":"two"}\n')
r1 = json.loads(s1.readline())
r2 = json.loads(s2.readline())
assert r1.get("id") == "one" and "return" in r1, r1
assert r2.get("id") == "two" and "return" in r2, r2

s1.write(b'{"execute":"quit","id":"quit"}\n')
c2.close()
c1.close()
PY

    wait "$qemu_pid"

    if [[ -s "$err" ]]; then
        sed -n '1,80p' "$err" >&2
        fail "qemu emitted stderr while serving multi-client QMP"
    fi
}

test_proxy_dry_run_uses_native_qmp_multi() {
    local out="$1"

    DRY_RUN=1 TPM=0 HOST_TUNE=0 INSTANCE=9878 PROXY=1 \
        "$START_VM" --no-sdl --no-fb-shm --no-bridge > "$out"

    grep -Fx -- "unix:/tmp/qemu-stealth-9878.qmp,server=on,wait=off,multi=on" "$out" >/dev/null \
        || fail "dry-run --proxy did not enable native QMP multi=on"
}

test_custom_image_root_dry_run() {
    local root="$1"
    local out="$2"
    local disk_path="$root/vms/9877/disk.qcow2"

    IMAGE_ROOT="$root" DRY_RUN=1 TPM=0 HOST_TUNE=0 INSTANCE=9877 \
        "$START_VM" --no-sdl --no-fb-shm --no-bridge > "$out"

    grep -F -- "$disk_path" "$out" >/dev/null \
        || fail "dry-run did not honor IMAGE_ROOT for disk path"
    grep -F -- "/home/ubuntu/images/vms/9877" "$out" >/dev/null \
        && fail "dry-run leaked default image root with custom IMAGE_ROOT"
    [[ ! -e "$root/vms" ]] \
        || fail "dry-run created VM directory under custom IMAGE_ROOT"
}

main() {
    require_executable "$START_VM"
    require_executable "$QEMU"
    require_executable "$QEMU_IMG"

    local out img sock err multi_sock multi_err image_root
    out="$(mktemp)"
    img="$(mktemp --suffix=.qcow2)"
    sock="$(mktemp -u)"
    err="$(mktemp)"
    multi_sock="$(mktemp -u)"
    multi_err="$(mktemp)"
    image_root="$(mktemp -d)"
    trap 'rm -f "${out:-}" "${img:-}" "${sock:-}" "${err:-}" "${multi_sock:-}" "${multi_err:-}"; rm -rf "${image_root:-}"' EXIT

    test_dry_run_has_safe_nvme_storage "$out"
    test_qemu_accepts_samsung_nvme "$img" "$sock" "$err"
    test_qmp_multi_accepts_two_clients "$multi_sock" "$multi_err"
    test_proxy_dry_run_uses_native_qmp_multi "$out"
    test_custom_image_root_dry_run "$image_root" "$out"
    echo "PASS: start-vm NVMe storage portability path"
}

main "$@"
