#!/usr/bin/env bash
# 验证 egl-headless provider 与可热插拔 fb-shm GL sidecar 的注册/析构顺序。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
QEMU="${QEMU:-$REPO_ROOT/build/qemu-system-x86_64}"
RENDERNODE="${GPU_RENDERNODE:-/dev/dri/renderD128}"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[[ -x "$QEMU" ]] || fail "缺少可执行 QEMU: $QEMU"
[[ -r "$RENDERNODE" && -w "$RENDERNODE" ]] \
    || fail "rendernode 不可读写: $RENDERNODE"

TMP_DIR="$(mktemp -d)"
QMP_SOCK="$TMP_DIR/qmp.sock"
BOOT_FB_SOCK="$TMP_DIR/boot-fb.sock"
QEMU_LOG="$TMP_DIR/qemu.log"
qemu_pid=""

cleanup() {
    if [[ -n "$qemu_pid" ]] && kill -0 "$qemu_pid" 2>/dev/null; then
        kill "$qemu_pid" 2>/dev/null || true
        wait "$qemu_pid" 2>/dev/null || true
    fi
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

"$QEMU" \
    -machine q35,accel=tcg \
    -nodefaults \
    -device virtio-vga-gl \
    -display egl-headless,rendernode="$RENDERNODE" \
    -object fb-shm,id=boot-fb,path="$BOOT_FB_SOCK",rate=1 \
    -S \
    -qmp unix:"$QMP_SOCK",server=on,wait=off \
    > /dev/null 2> "$QEMU_LOG" &
qemu_pid=$!

for _ in $(seq 1 100); do
    [[ -S "$QMP_SOCK" && -S "$BOOT_FB_SOCK" ]] && break
    if ! kill -0 "$qemu_pid" 2>/dev/null; then
        sed -n '1,160p' "$QEMU_LOG" >&2
        fail "egl-headless + fb-shm 启动时退出"
    fi
    sleep 0.05
done
[[ -S "$BOOT_FB_SOCK" ]] || fail "命令行 fb-shm sidecar 未创建 socket"

python3 - "$QMP_SOCK" "$TMP_DIR" <<'PY'
import json
import socket
import sys


QMP_SOCK, TMP_DIR = sys.argv[1:]
client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
client.settimeout(5.0)
client.connect(QMP_SOCK)
stream = client.makefile("rwb", buffering=0)
assert "QMP" in json.loads(stream.readline())


def execute(command, ident, arguments=None):
    request = {"execute": command, "id": ident}
    if arguments is not None:
        request["arguments"] = arguments
    stream.write(json.dumps(request).encode() + b"\n")
    while True:
        response = json.loads(stream.readline())
        if response.get("id") == ident:
            assert "return" in response, response
            return response["return"]


execute("qmp_capabilities", "caps")

# 中文注释：命令行对象的 notifier 在 provider 初始化前注册；删除后再反复
# 热添加，会覆盖 machine-ready 同步 notifier、sidecar 尾插和 finalize 摘链。
execute("object-del", "delete-boot", {"id": "boot-fb"})
for index in range(16):
    object_id = f"hot-fb-{index}"
    socket_path = f"{TMP_DIR}/{object_id}.sock"
    execute("object-add", f"add-{index}", {
        "qom-type": "fb-shm",
        "id": object_id,
        "path": socket_path,
        "rate": 1,
    })
    execute("object-del", f"del-{index}", {"id": object_id})

execute("quit", "quit")
stream.close()
client.close()
PY

wait "$qemu_pid"
qemu_pid=""

error_pattern='incompatible with the GL context|GL_INVALID|use-after-free'
error_pattern+='|fb-shm: cannot (create|make|restore).*GL context'
if grep -Eai "$error_pattern" "$QEMU_LOG" >/dev/null
then
    sed -n '1,160p' "$QEMU_LOG" >&2
    fail "GL sidecar 生命周期日志出现错误"
fi

echo "OK: fb-shm egl-headless sidecar runtime checks passed"
