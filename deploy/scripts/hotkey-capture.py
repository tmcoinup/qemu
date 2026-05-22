#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# hotkey-capture.py
#
# 宿主侧热键截图守护进程。
#
# 背景
# ----
# QEMU 不会把 guest 内的按键当成 QMP/HMP 事件抛出来，所以"订阅 guest 按键"在
# 原生接口上不存在。但按键到达 guest 之前必然先过宿主输入层（SDL 窗口跑在某个
# X display 上）。本守护进程提供两路互补的触发器，二者都汇聚到同一份"从 fb-shm
# 零拷贝帧抓一张 PNG"的实现——guest 完全无感知，符合本项目 stealth 基调：
#
#   触发器 A  X11 RECORD 扩展旁路监听 SDL 窗口所在 display 的目标键（默认 F4）。
#             RECORD 只观察、不拦截，F4 照样进 guest；无需重编译 QEMU。
#             仅 SDL 模式 + 该 display 有效。
#
#   触发器 B  一个 SOCK_DGRAM Unix socket。打了补丁的 QEMU（见 ui/sdl2.c，
#             由环境变量 QEMU_HOTKEY_TRIGGER 开关）在 handle_keydown 收到 F4
#             时往这里戳一个字节。即使 guest 抓键/全屏也有效，且与 X display
#             无关。任何外部工具也可以 `socat - UNIX-SENDTO:<path>` 手动触发。
#
# 截图源恒为 fb-shm（/tmp/qemu-stealth-<N>.fb），复用 qemu-fb-shm-stream.py 的
# HELLO 握手与 FrameReader，避免重复实现 ABI。
#
# 用法
# ----
#   ./hotkey-capture.py <INSTANCE>
#   ./hotkey-capture.py 1 --key F4 --display :1 --out-dir /path/to/shots
#   ./hotkey-capture.py 1 --no-xrecord      # 只留触发器 B
#   ./hotkey-capture.py 1 --no-trigger      # 只留触发器 A
#
# 依赖: numpy, Pillow（必需）; python-xlib（触发器 A 需要，缺了自动降级）。
# ---------------------------------------------------------------------------
import argparse
import datetime
import importlib.util
import os
import queue
import signal
import socket
import struct
import sys
import threading
import time

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))


# ---------------------------------------------------------------------------
# 复用 qemu-fb-shm-stream.py（文件名带连字符，不能 import，用 importlib 装载）
# ---------------------------------------------------------------------------
def _load_fbshm():
    """把 qemu-fb-shm-stream.py 作为模块加载，复用其 fb-shm ABI。
    该脚本在仓库 scripts/ 下（不是本目录），这里按候选路径找。"""
    candidates = [
        os.path.join(HERE, "qemu-fb-shm-stream.py"),
        os.path.join(HERE, "..", "..", "scripts", "qemu-fb-shm-stream.py"),
    ]
    path = next((c for c in candidates if os.path.exists(c)), None)
    if path is None:
        raise RuntimeError(
            "找不到 qemu-fb-shm-stream.py（已查: %s）" % candidates)
    spec = importlib.util.spec_from_file_location("fbshm", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"无法加载 fb-shm 模块: {path}")
    mod = importlib.util.module_from_spec(spec)
    # 该脚本用了 @dataclass，dataclasses 解析注解时要能在 sys.modules 找到
    # 自身模块，所以先登记再 exec。
    sys.modules["fbshm"] = mod
    spec.loader.exec_module(mod)
    return mod


fbshm = _load_fbshm()


def log(msg: str) -> None:
    """统一日志格式，与 start-vm.sh 的 '>> xxx:' 风格一致；带时间戳便于排查。"""
    ts = datetime.datetime.now().strftime("%H:%M:%S")
    print(f">> hotkey[{ts}]: {msg}", flush=True)


# ---------------------------------------------------------------------------
# 截图核心：连 fb-shm，抓当前帧，转 RGB 存 PNG
# ---------------------------------------------------------------------------
class Capturer:
    """每次截图独立完成一次 HELLO → 抓帧 → 关闭，避免长时间持有 mmap，
    也天然兼容 guest 改分辨率导致的 memfd 重分配。"""

    def __init__(self, sock_path: str, out_dir: str):
        self.sock_path = sock_path
        self.out_dir = out_dir
        os.makedirs(out_dir, exist_ok=True)

    def _grab_latest(self, reader) -> "tuple[bytes, int, int, int, int]":
        """无视 last_seq，直接按 seqlock 协议拷贝当前 active 缓冲区。

        FrameReader.read_frame() 在画面静止（frame_seq 不前进）时会返回 None，
        而热键截图要的恰恰是"此刻屏幕"，所以这里自己做一次 seqlock 快照。
        返回 (像素字节, width, height, stride, fourcc)。
        """
        for _ in range(16):
            reader._refresh_header()
            hdr = reader.hdr
            seq0 = hdr.frame_seq
            idx = hdr.active_idx
            if idx >= hdr.buf_count:
                continue
            off = hdr.buf_offset[idx]
            length = hdr.buf_size
            chunk = bytes(reader.mm[off:off + length])
            reader._refresh_header()
            if reader.hdr.frame_seq == seq0:
                return chunk, hdr.width, hdr.height, hdr.stride, hdr.fourcc
            time.sleep(0.001)
        raise RuntimeError("seqlock 连续 16 次被写者打断，放弃本次抓帧")

    @staticmethod
    def _to_rgb(buf: bytes, width: int, height: int, stride: int,
                fourcc: int) -> np.ndarray:
        """fb-shm 像素是 BGR0/BGRA（小端 x8r8g8b8，字节序 B,G,R,X）。
        按 stride 去掉行尾 padding，再把 BGR 翻成 RGB。"""
        if fourcc not in (fbshm.FB_SHM_FOURCC_BGR0, fbshm.FB_SHM_FOURCC_BGRA):
            raise RuntimeError(f"未知 fourcc 0x{fourcc:08x}")
        need = stride * height
        if len(buf) < need:
            raise RuntimeError(f"帧字节不足: 有 {len(buf)} 需 {need}")
        rows = np.frombuffer(buf, dtype=np.uint8, count=need)
        rows = rows.reshape(height, stride)[:, : width * 4]
        px = rows.reshape(height, width, 4)
        # BGR0 -> RGB：取通道 [2,1,0]，丢弃 alpha/pad。.copy() 让其连续可写。
        return px[:, :, 2::-1].copy()

    def capture(self, reason: str) -> "str | None":
        """完成一次截图，返回 PNG 路径；失败返回 None（只记日志不抛）。"""
        if not os.path.exists(self.sock_path):
            log(f"fb-shm socket 不存在，跳过本次({reason}): {self.sock_path}")
            return None
        s = None
        reader = None
        try:
            s, memfd, evfd, ack = fbshm.hello(self.sock_path)
            shm_size = ack[0]
            reader = fbshm.FrameReader(memfd, evfd, shm_size)
            buf, w, h, stride, fourcc = self._grab_latest(reader)
            rgb = self._to_rgb(buf, w, h, stride, fourcc)
            # 单次 now()，秒与毫秒来自同一时刻，避免跨秒边界错位。
            now = datetime.datetime.now()
            ts = now.strftime("%Y%m%d-%H%M%S-") + \
                f"{now.microsecond // 1000:03d}"
            out = os.path.join(self.out_dir, f"cap-{ts}.png")
            Image.fromarray(rgb, "RGB").save(out)
            log(f"已截图 {w}x{h} -> {out}  (来源 {reason})")
            return out
        except Exception as e:  # 守护进程要稳，任何异常都吞掉只记录
            log(f"截图失败({reason}): {e!r}")
            return None
        finally:
            if reader is not None:
                try:
                    reader.close()
                except Exception:
                    pass
            if s is not None:
                try:
                    s.close()
                except Exception:
                    pass


# ---------------------------------------------------------------------------
# 触发器 B：SOCK_DGRAM unix socket，收任意一个包就触发
# ---------------------------------------------------------------------------
def trigger_socket_loop(path: str, q: "queue.Queue", stop: threading.Event):
    try:
        if os.path.exists(path):
            os.unlink(path)
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        srv.bind(path)
        os.chmod(path, 0o600)
        srv.settimeout(0.5)
    except Exception as e:
        log(f"触发 socket 监听失败，触发器 B 关闭: {e!r}")
        return
    log(f"触发器 B 就绪 (DGRAM): {path}")
    while not stop.is_set():
        try:
            srv.recvfrom(64)
        except socket.timeout:
            continue
        except Exception as e:
            log(f"触发 socket 读异常: {e!r}")
            time.sleep(0.2)
            continue
        q.put("socket")
    try:
        srv.close()
        os.unlink(path)
    except Exception:
        pass


# ---------------------------------------------------------------------------
# 触发器 A：X11 RECORD 扩展旁路监听键盘
# ---------------------------------------------------------------------------
def xrecord_loop(display_name: str, key_name: str, q: "queue.Queue",
                 stop: threading.Event):
    try:
        from Xlib import display as xdisplay, X, XK
        from Xlib.ext import record
        from Xlib.protocol import rq
    except Exception as e:
        log(f"python-xlib 不可用，触发器 A 关闭（仍可用触发器 B）: {e!r}")
        return

    try:
        ctrl_dpy = xdisplay.Display(display_name)
        rec_dpy = xdisplay.Display(display_name)
    except Exception as e:
        log(f"连接 X display {display_name!r} 失败，触发器 A 关闭: {e!r}")
        return

    if not rec_dpy.has_extension("RECORD"):
        log("X server 无 RECORD 扩展，触发器 A 关闭")
        return

    keysym = XK.string_to_keysym(key_name)
    if keysym == 0:
        log(f"无法解析键名 {key_name!r}，触发器 A 关闭")
        return
    target_kc = ctrl_dpy.keysym_to_keycode(keysym)
    log(f"触发器 A 就绪 (XRecord): display={display_name} "
        f"key={key_name} keycode={target_kc}")

    def on_event(reply):
        if reply.category != record.FromServer or reply.client_swapped:
            return
        if not reply.data or reply.data[0] < 2:
            return
        data = reply.data
        while data:
            ev, data = rq.EventField(None).parse_binary_value(
                data, rec_dpy.display, None, None)
            # 只认 KeyPress，且 keycode 命中目标键。RECORD 是观察者，
            # 这里不消费事件，F4 照常派发给 SDL 窗口 -> guest。
            if ev.type == X.KeyPress and ev.detail == target_kc:
                q.put("xrecord")

    ctx = rec_dpy.record_create_context(
        0,
        [record.AllClients],
        [{
            "core_requests": (0, 0),
            "core_replies": (0, 0),
            "ext_requests": (0, 0, 0, 0),
            "ext_replies": (0, 0, 0, 0),
            "delivered_events": (0, 0),
            "device_events": (X.KeyPress, X.KeyPress),
            "errors": (0, 0),
            "client_started": False,
            "client_died": False,
        }])

    # 看门狗线程：stop 置位时用控制连接关掉 record context，
    # 让阻塞中的 record_enable_context 返回，线程干净退出。
    def watchdog():
        stop.wait()
        try:
            ctrl_dpy.record_disable_context(ctx)
            ctrl_dpy.flush()
        except Exception:
            pass

    threading.Thread(target=watchdog, daemon=True).start()

    try:
        rec_dpy.record_enable_context(ctx, on_event)
    except Exception as e:
        log(f"XRecord 监听结束: {e!r}")
    finally:
        try:
            rec_dpy.record_free_context(ctx)
        except Exception:
            pass


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
def main(argv=None) -> int:
    p = argparse.ArgumentParser(
        description="宿主热键截图守护进程（fb-shm 截图源）")
    p.add_argument("instance", help="VM 实例号，例如 1")
    p.add_argument("--key", default="F4",
                   help="触发键名（X keysym 名），默认 F4")
    p.add_argument("--display", default=os.environ.get("DISPLAY", ":1"),
                   help="SDL 窗口所在 X display，默认 $DISPLAY 或 :1")
    p.add_argument("--sock", default=None,
                   help="fb-shm 控制 socket，默认 /tmp/qemu-stealth-<N>.fb")
    p.add_argument("--trigger-sock", default=None,
                   help="触发 DGRAM socket，默认 /tmp/qemu-stealth-<N>.hotkey")
    p.add_argument("--out-dir", default=None,
                   help="PNG 输出目录，默认 /home/ubuntu/images/vms/<N>/captures")
    p.add_argument("--debounce", type=float, default=0.3,
                   help="去抖秒数，连击间隔内只截一次，默认 0.3")
    p.add_argument("--no-xrecord", action="store_true",
                   help="关闭触发器 A（X11 RECORD）")
    p.add_argument("--no-trigger", action="store_true",
                   help="关闭触发器 B（DGRAM socket）")
    args = p.parse_args(argv)

    inst = args.instance
    sock = args.sock or f"/tmp/qemu-stealth-{inst}.fb"
    trig = args.trigger_sock or f"/tmp/qemu-stealth-{inst}.hotkey"
    out_dir = args.out_dir or f"/home/ubuntu/images/vms/{inst}/captures"

    if args.no_xrecord and args.no_trigger:
        log("两个触发器都被关闭，无事可做，退出")
        return 2

    cap = Capturer(sock, out_dir)
    q: "queue.Queue" = queue.Queue()
    stop = threading.Event()

    def _sig(_signo, _frame):
        stop.set()
    signal.signal(signal.SIGINT, _sig)
    signal.signal(signal.SIGTERM, _sig)

    log(f"启动 instance={inst} fb-shm={sock} 输出={out_dir}")

    threads = []
    if not args.no_trigger:
        t = threading.Thread(target=trigger_socket_loop,
                              args=(trig, q, stop), daemon=True)
        t.start()
        threads.append(t)
    if not args.no_xrecord:
        t = threading.Thread(target=xrecord_loop,
                              args=(args.display, args.key, q, stop),
                              daemon=True)
        t.start()
        threads.append(t)

    # 消费循环：串行化截图，保证同一时刻只有一个 fb-shm 连接；带去抖。
    last = 0.0
    while not stop.is_set():
        try:
            src = q.get(timeout=0.5)
        except queue.Empty:
            continue
        now = time.monotonic()
        if now - last < args.debounce:
            continue
        last = now
        cap.capture(src)

    log("收到停止信号，退出")
    return 0


if __name__ == "__main__":
    sys.exit(main())
