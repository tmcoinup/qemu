#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# 向真实 SDL 2D QEMU 注入 renderer reset。
# 确认完整上传、纹理重建和 Present。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
QEMU="${QEMU:-$REPO_ROOT/build/qemu-system-x86_64}"
INJECTOR_SRC="$SCRIPT_DIR/fixtures/sdl-render-reset-inject.c"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[[ -x "$QEMU" ]] || fail "缺少可执行 QEMU: $QEMU"
if [[ -z "${DISPLAY:-}" ]]; then
    echo "SKIP: 没有 X11 DISPLAY，无法运行 SDL reset 注入测试"
    exit 0
fi
command -v pkg-config >/dev/null || fail "缺少 pkg-config"
pkg-config --exists sdl2 || fail "缺少 SDL2 开发包"

TMP_DIR="$(mktemp -d)"
INJECTOR_SO="$TMP_DIR/sdl-render-reset-inject.so"
QMP_SOCK="$TMP_DIR/qmp.sock"
MARKER="$TMP_DIR/reset.marker"
QEMU_LOG="$TMP_DIR/qemu.log"
qemu_pid=""
read -r -a sdl_cflags <<< "$(pkg-config --cflags sdl2)"

cleanup() {
    if [[ -n "$qemu_pid" ]] && kill -0 "$qemu_pid" 2>/dev/null; then
        kill "$qemu_pid" 2>/dev/null || true
        wait "$qemu_pid" 2>/dev/null || true
    fi
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# 仅拦截本次测试进程的四个 SDL API，不改宿主或 guest 状态。
cc -shared -fPIC -Wall -Wextra -Werror \
    "${sdl_cflags[@]}" \
    -o "$INJECTOR_SO" "$INJECTOR_SRC" -ldl

SDL_VIDEODRIVER=x11 \
SDL_FRAMEBUFFER_ACCELERATION=0 \
SDL_RENDER_DRIVER=software \
VMATE_SDL_RESET_MARKER="$MARKER" \
LD_PRELOAD="$INJECTOR_SO" \
"$QEMU" \
    -machine q35,accel=tcg \
    -m 128M \
    -nodefaults \
    -device virtio-vga \
    -display sdl,gl=off,show-cursor=off \
    -S \
    -qmp unix:"$QMP_SOCK",server=on,wait=off \
    -serial none \
    -monitor none \
    >/dev/null 2>"$QEMU_LOG" &
qemu_pid=$!

for _ in $(seq 1 200); do
    if [[ -f "$MARKER" ]] &&
       grep -Fxq "target-present" "$MARKER" &&
       grep -Fxq "device-create" "$MARKER" &&
       grep -Fxq "device-present" "$MARKER"; then
        break
    fi
    if ! kill -0 "$qemu_pid" 2>/dev/null; then
        sed -n '1,160p' "$QEMU_LOG" >&2
        fail "SDL reset 恢复完成前 QEMU 已退出"
    fi
    sleep 0.025
done

for marker in target-event target-upload target-present \
              device-event device-create device-upload device-present; do
    grep -Fxq "$marker" "$MARKER" 2>/dev/null \
        || {
            sed -n '1,120p' "$MARKER" 2>/dev/null >&2 || true
            sed -n '1,160p' "$QEMU_LOG" >&2
            fail "缺少 SDL reset 恢复标记: $marker"
        }
done

# 正常 QMP quit。
# 确保 reset 后主循环、renderer 和析构仍然可用。
python3 - "$QMP_SOCK" <<'PY'
import json
import socket
import sys


client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
client.settimeout(5.0)
client.connect(sys.argv[1])
stream = client.makefile("rwb", buffering=0)
assert "QMP" in json.loads(stream.readline())
for command, ident in (("qmp_capabilities", "caps"), ("quit", "quit")):
    stream.write(json.dumps({"execute": command, "id": ident}).encode() + b"\n")
    while True:
        response = json.loads(stream.readline())
        if response.get("id") == ident:
            assert "return" in response, response
            break
stream.close()
client.close()
PY

wait "$qemu_pid"
qemu_pid=""

if grep -Eai 'Assertion.*failed|renderer texture|Segmentation fault' \
        "$QEMU_LOG" >/dev/null; then
    sed -n '1,160p' "$QEMU_LOG" >&2
    fail "SDL reset 恢复日志出现错误"
fi

echo "OK: SDL renderer reset runtime recovery passed"
