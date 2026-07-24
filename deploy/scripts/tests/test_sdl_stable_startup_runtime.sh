#!/usr/bin/env bash
# 用真实 X11/SDL 启动无磁盘、暂停态 QEMU，覆盖 stable 2D renderer。
# 该用例专门防止 SDL 在 `gl=off` 下仍隐式选择 GLX，并在错误回调前触发 XError。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
QEMU="${QEMU:-$REPO_ROOT/build/qemu-system-x86_64}"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[[ -x "$QEMU" ]] || fail "缺少可执行 QEMU: $QEMU"
if [[ -z "${DISPLAY:-}" ]]; then
    echo "SKIP: 当前环境没有 X11 DISPLAY，无法运行 stable SDL 启动测试"
    exit 0
fi

TMP_DIR="$(mktemp -d)"
QMP_SOCK="$TMP_DIR/qmp.sock"
FB_SHM_SOCK="$TMP_DIR/fb.sock"
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

# `SDL_RENDER_DRIVER=software` 只约束 SDL_Renderer；SDL 的 X11 window surface
# 仍可能通过 accelerated framebuffer 创建 GLX context。因此 stable 模式必须
# 同时把 SDL_FRAMEBUFFER_ACCELERATION 固定为 0。`-S` 保证 guest 不执行，
# 但完整覆盖窗口、renderer、fb-shm sidecar 与主循环初始化。
SDL_VIDEODRIVER=x11 \
SDL_FRAMEBUFFER_ACCELERATION=0 \
SDL_RENDER_DRIVER=software \
"$QEMU" \
    -machine q35,accel=tcg \
    -m 128M \
    -nodefaults \
    -device virtio-vga \
    -display sdl,gl=off,show-cursor=off \
    -object fb-shm,id=stable-fb,path="$FB_SHM_SOCK",rate=1 \
    -S \
    -qmp unix:"$QMP_SOCK",server=on,wait=off \
    -serial none \
    -monitor none \
    >/dev/null 2>"$QEMU_LOG" &
qemu_pid=$!

for _ in $(seq 1 100); do
    [[ -S "$QMP_SOCK" && -S "$FB_SHM_SOCK" ]] && break
    if ! kill -0 "$qemu_pid" 2>/dev/null; then
        sed -n '1,160p' "$QEMU_LOG" >&2
        fail "stable SDL 在控制 socket 就绪前退出"
    fi
    sleep 0.05
done
[[ -S "$QMP_SOCK" ]] || fail "stable SDL QEMU 未在期限内创建 QMP socket"
[[ -S "$FB_SHM_SOCK" ]] || fail "stable SDL 未创建 fb-shm socket"

# 通过 QMP 正常退出，确认主循环已经可用，并覆盖 SDL renderer 的析构路径。
python3 - "$QMP_SOCK" <<'PY'
import json
import socket
import sys


client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
client.settimeout(5.0)
client.connect(sys.argv[1])
stream = client.makefile("rwb", buffering=0)
assert "QMP" in json.loads(stream.readline())


def execute(command, ident):
    stream.write(json.dumps({"execute": command, "id": ident}).encode() + b"\n")
    while True:
        response = json.loads(stream.readline())
        if response.get("id") == ident:
            assert "return" in response, response
            return


execute("qmp_capabilities", "caps")
execute("quit", "quit")
stream.close()
client.close()
PY

wait "$qemu_pid"
qemu_pid=""

error_pattern='X Error|GLX|EGL|window/context creation failed|Assertion.*failed'
if grep -Eai "$error_pattern" "$QEMU_LOG" >/dev/null; then
    sed -n '1,160p' "$QEMU_LOG" >&2
    fail "stable SDL 启动日志出现隐式 GL provider 错误"
fi

echo "OK: stable SDL software renderer startup passed"
