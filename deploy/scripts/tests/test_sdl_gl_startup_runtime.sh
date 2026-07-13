#!/usr/bin/env bash
# 运行真实 SDL/GL QEMU，验证 X11 EGL 不可用时不会落入 libepoxy 无 context 断言。
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
    echo "SKIP: 当前环境没有 X11 DISPLAY，无法运行 SDL/GL 启动测试"
    exit 0
fi

# 中文注释：只在当前 X11 EGL vendor 确认是 NVIDIA 且发布了问题扩展时，
# 才要求本次启动必须留在 EGL。其它 vendor 可以按能力正常降级到 GLX。
# 探测失败不会误伤测试，而是回到通用的“成功启动且无 provider 错误”断言。
NVIDIA_PRESENT_OPAQUE=0
NVIDIA_PRESENT_OPAQUE="$(python3 <<'PY' || printf '0\n'
import ctypes
import ctypes.util


try:
    x11 = ctypes.CDLL(ctypes.util.find_library("X11"))
    egl = ctypes.CDLL(ctypes.util.find_library("EGL"))
    x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
    x11.XOpenDisplay.restype = ctypes.c_void_p
    x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
    egl.eglGetDisplay.argtypes = [ctypes.c_void_p]
    egl.eglGetDisplay.restype = ctypes.c_void_p
    egl.eglInitialize.argtypes = [ctypes.c_void_p, ctypes.c_void_p,
                                  ctypes.c_void_p]
    egl.eglInitialize.restype = ctypes.c_uint
    egl.eglQueryString.argtypes = [ctypes.c_void_p, ctypes.c_int]
    egl.eglQueryString.restype = ctypes.c_char_p
    egl.eglTerminate.argtypes = [ctypes.c_void_p]

    display = x11.XOpenDisplay(None)
    egl_display = egl.eglGetDisplay(display) if display else None
    if not egl_display or not egl.eglInitialize(egl_display, None, None):
        print(0)
    else:
        vendor = (egl.eglQueryString(egl_display, 0x3053) or b"").decode()
        extensions = (egl.eglQueryString(egl_display, 0x3055) or b"").decode()
        print(int(vendor.startswith("NVIDIA") and
                  "EGL_EXT_present_opaque" in extensions.split()))
        egl.eglTerminate(egl_display)
    if display:
        x11.XCloseDisplay(display)
except (OSError, TypeError, ValueError):
    print(0)
PY
)"

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

# 中文注释：显式把 SDL 指向 X11 并要求优先 EGL。支持 EGLWindowSurface 的宿主
# 会直接成功；仅 eglGetDisplay 成功、window surface 失败的宿主必须自动降级 GLX。
# `-S` 避免来宾执行干扰结果，但 display 初始化仍完整创建窗口、context 和 shader。
# 同时挂上用户现场中的 fb-shm sidecar，确保 provider 降级后共享 context 的注册
# 与首次 refresh 也不会再次走入“没有 current context”的 libepoxy 断言。
env -u EGL_EXT_present_opaque \
    SDL_VIDEODRIVER=x11 SDL_VIDEO_X11_FORCE_EGL=1 "$QEMU" \
    -machine q35,accel=tcg \
    -m 128M \
    -nodefaults \
    -device virtio-vga-gl \
    -display sdl,gl=on,show-cursor=off \
    -object fb-shm,id=startup-fb,path="$FB_SHM_SOCK",rate=1 \
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
        fail "SDL/GL 在 QMP socket 就绪前退出"
    fi
    sleep 0.05
done
[[ -S "$QMP_SOCK" ]] || fail "SDL/GL QEMU 未在期限内创建 QMP socket"
[[ -S "$FB_SHM_SOCK" ]] || fail "SDL/GL provider 就绪后未创建 fb-shm socket"

# 中文注释：走正常 QMP quit，既确认主循环已经启动，也让 SDL 销毁窗口/context，
# 覆盖启动成功但析构失败的回归；不能只用 timeout/SIGTERM 判断“没有立刻崩”。
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

error_pattern='epoxy_get_proc_address|Couldn.t find current GLX or EGL context'
error_pattern+='|GLX fallback failed|window/context creation failed|Assertion.*failed'
error_pattern+='|warning:'
if grep -Eai "$error_pattern" "$QEMU_LOG" >/dev/null; then
    sed -n '1,160p' "$QEMU_LOG" >&2
    fail "SDL/GL 启动日志出现 context/provider 错误"
fi

if [[ "$NVIDIA_PRESENT_OPAQUE" == "1" ]] && \
    grep -F -- "falling back to GLX" "$QEMU_LOG" >/dev/null; then
    sed -n '1,160p' "$QEMU_LOG" >&2
    fail "NVIDIA EGL_EXT_present_opaque workaround did not keep SDL on EGL"
fi
if [[ "$NVIDIA_PRESENT_OPAQUE" == "1" ]] && \
    ! grep -F -- "SDL: EGL provider active" "$QEMU_LOG" >/dev/null; then
    sed -n '1,160p' "$QEMU_LOG" >&2
    fail "NVIDIA runtime did not commit the SDL EGL provider"
fi

echo "OK: SDL GL startup and EGL-to-GLX fallback checks passed"
