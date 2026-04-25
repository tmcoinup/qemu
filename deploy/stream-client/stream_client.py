#!/usr/bin/env python3
"""
stream_client.py — host-side client for the H.264 streaming stack.

What it does:
  1. Creates a top-level X11 window sized to the guest's reported desktop.
  2. Spawns mpv as a child with --wid=<this_window>; mpv decodes the
     tcp://GUEST:VPORT MPEG-TS stream and renders into our window.
  3. Connects to TCP IPORT (AudioSvcHost) and walks the RFB 3.8 handshake
     (VncAuth) to authenticate. We never ask for framebuffer updates —
     the server keeps state but the input dispatcher is what we want.
  4. Runs an X11 event loop on our window: KeyPress/Release,
     MotionNotify, ButtonPress/Release → translated to RFB MSG_KEYEVENT
     and MSG_POINTEREVENT and shipped over the input socket.

mpv runs with --no-input-default-bindings/--no-input-cursor/--input-conf=
so it does not steal events; everything goes to the wrapper's window.

Usage (called by stream-guest.sh):
    stream_client.py --ip <guest> --vport 56790 --iport 56789 --password 123456
"""
import argparse, os, signal, socket, struct, subprocess, sys, time
from Xlib import display, X, XK, error
from Xlib.protocol import event as xevent

# ───────────────── DES (VNC bit-reversed key) ─────────────────────────
# We only need DES *encryption* for VncAuth. pycryptodome may or may not
# be available system-wide — try import, fall back to pip install.
try:
    from Crypto.Cipher import DES
except ImportError:
    subprocess.check_call([sys.executable, '-m', 'pip', 'install',
                           '--quiet', '--break-system-packages', '--user',
                           'pycryptodome'])
    from Crypto.Cipher import DES

def vnc_password_key(pw: str) -> bytes:
    raw = pw.encode('ascii')[:8].ljust(8, b'\x00')
    return bytes(int(f'{b:08b}'[::-1], 2) for b in raw)

# ───────────────── RFB input client ───────────────────────────────────
class InputChannel:
    def __init__(self, ip, port, password):
        self.s = socket.create_connection((ip, port), timeout=5)
        self.s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self._handshake(password)
        # Pixel format: don't care, server sends what it sends.
        self.w, self.h = self._read_server_init()
        # We never request FB updates. But to keep the server happy
        # (if it expects a SetEncodings from a "real" RFB client) we
        # send an empty SetEncodings list once.
        self.s.sendall(struct.pack('>BBH', 2, 0, 0))

    def _read_exact(self, n):
        buf = b''
        while len(buf) < n:
            d = self.s.recv(n - len(buf))
            if not d:
                raise RuntimeError(f'input socket closed at {len(buf)}/{n}')
            buf += d
        return buf

    def _handshake(self, password):
        # 1) protocol
        self._read_exact(12)
        self.s.sendall(b'RFB 003.008\n')
        # 2) sec types
        n = self._read_exact(1)[0]
        types = self._read_exact(n)
        if 2 not in types:
            raise RuntimeError(f'server does not offer VncAuth: {list(types)}')
        self.s.sendall(b'\x02')
        # 3) challenge → encrypted response
        challenge = self._read_exact(16)
        key = vnc_password_key(password)
        cipher = DES.new(key, DES.MODE_ECB)
        resp = cipher.encrypt(challenge[:8]) + cipher.encrypt(challenge[8:])
        self.s.sendall(resp)
        result = struct.unpack('>I', self._read_exact(4))[0]
        if result != 0:
            raise RuntimeError(f'VncAuth failed result={result}')
        # 4) ClientInit shared=1
        self.s.sendall(b'\x01')

    def _read_server_init(self):
        raw = self._read_exact(24)
        w, h = struct.unpack('>HH', raw[:4])
        namelen = struct.unpack('>I', raw[20:24])[0]
        self._read_exact(namelen)
        return w, h

    def send_pointer(self, mask, x, y):
        x = max(0, min(0xFFFF, int(x)))
        y = max(0, min(0xFFFF, int(y)))
        self.s.sendall(struct.pack('>BBHH', 5, mask & 0xFF, x, y))

    def send_key(self, down, keysym):
        self.s.sendall(struct.pack('>BBHI', 4, 1 if down else 0, 0, keysym & 0xFFFFFFFF))

    def close(self):
        try: self.s.close()
        except: pass

# ───────────────── X11 keysym translation ────────────────────────────
# python-Xlib uses XK_* keysym values that match RFB keysym values
# (both are X Window keysyms). KeyPress event has keycode; we convert
# to keysym via XKeyEvent state for shift handling.
def x_keysym_to_rfb(disp, keycode, state):
    # XKeysymToKeycode-style lookup the other way:
    ks = disp.keycode_to_keysym(keycode, 0)
    # If shift is held, prefer the shifted symbol (index 1)
    if state & X.ShiftMask:
        shifted = disp.keycode_to_keysym(keycode, 1)
        if shifted:
            ks = shifted
    return ks

# ───────────────── main ──────────────────────────────────────────────
def parse_args():
    ap = argparse.ArgumentParser()
    ap.add_argument('--ip', required=True)
    ap.add_argument('--vport', type=int, default=56790)
    ap.add_argument('--iport', type=int, default=56789)
    ap.add_argument('--password', default='123456')
    ap.add_argument('--width',  type=int, default=0, help='override window width (0=auto from server)')
    ap.add_argument('--height', type=int, default=0, help='override window height')
    return ap.parse_args()

def main():
    args = parse_args()

    # 1) connect input channel first (cheap; gives us guest desktop size)
    print(f'[stream] connecting input ch to {args.ip}:{args.iport}')
    inp = InputChannel(args.ip, args.iport, args.password)
    print(f'[stream] guest desktop reports {inp.w}x{inp.h}')
    win_w = args.width or inp.w
    win_h = args.height or inp.h
    # cap window to current monitor
    disp = display.Display()
    screen = disp.screen()
    max_w = screen.width_in_pixels - 50
    max_h = screen.height_in_pixels - 100
    if win_w > max_w: win_w = max_w
    if win_h > max_h: win_h = max_h
    print(f'[stream] window size {win_w}x{win_h}')

    # 2) X11 window
    bg = screen.black_pixel
    fg = screen.white_pixel
    win = screen.root.create_window(
        0, 0, win_w, win_h, 0,
        screen.root_depth,
        background_pixel=bg,
        event_mask=(X.KeyPressMask | X.KeyReleaseMask |
                    X.ButtonPressMask | X.ButtonReleaseMask |
                    X.PointerMotionMask | X.EnterWindowMask |
                    X.LeaveWindowMask | X.FocusChangeMask |
                    X.StructureNotifyMask | X.ExposureMask),
    )
    win.set_wm_name(f'Audio Stream - {args.ip}')
    win.set_wm_class('audiostream', 'AudioStream')
    # Ask WM to keep us at the size we want
    win.set_wm_normal_hints(flags=(8 | 16 | 32),  # PMinSize | PMaxSize | PResizeInc
                            min_width=win_w, min_height=win_h,
                            max_width=win_w, max_height=win_h)
    WM_DELETE_WINDOW = disp.intern_atom('WM_DELETE_WINDOW')
    WM_PROTOCOLS     = disp.intern_atom('WM_PROTOCOLS')
    win.set_wm_protocols([WM_DELETE_WINDOW])
    win.map()
    disp.sync()
    # wait for MapNotify
    while True:
        ev = disp.next_event()
        if ev.type == X.MapNotify:
            break

    # Window ID for mpv
    wid = int(win.id)
    print(f'[stream] X11 window id 0x{wid:x}')

    # 3) spawn mpv as child rendering into our window
    #
    # Important: --vo=xv is the *only* VO that reliably stays inside a wid
    # parent. vo=gpu (the default) creates a fresh GLX/EGL X11 window with
    # an OpenGL-compatible visual; the WM (openbox, mutter) often re-parents
    # it to root and decorates it as a top-level — the symptom is that the
    # video drifts out of the container window. xv is X-Video Extension v2,
    # purely 2D YUV blits to whatever drawable we hand it, no GL context,
    # no reparenting. Plenty fast for 1280×720@60 (it's hardware-accelerated
    # by glamor on every modern GPU).
    #
    # If xv is not available (no /etc/X11 driver shipping it), the user can
    # set STREAM_VO=vaapi (also embed-stable) or =gpu (best quality, may
    # detach), and STREAM_HWDEC=vaapi/cuda for the decode path.
    vo     = os.environ.get('STREAM_VO',     'xv')
    hwdec  = os.environ.get('STREAM_HWDEC',  'auto-safe')
    mpv_cmd = [
        'mpv',
        f'--wid={wid}',
        '--profile=low-latency',
        '--no-osc', '--no-osd-bar',
        '--no-input-default-bindings',
        '--no-input-cursor',
        '--input-conf=/dev/null',
        '--cursor-autohide=no',
        '--cache=no',
        '--demuxer-readahead-secs=0',
        '--demuxer-lavf-o-set=fflags=+nobuffer+discardcorrupt',
        '--demuxer-lavf-probesize=32',
        '--demuxer-lavf-analyzeduration=0',
        '--vd-lavc-threads=2',
        '--video-sync=audio',
        '--no-audio',
        '--keepaspect=yes',
        '--no-border',                 # don't ever decorate (in case wid path lapses)
        '--ontop=no',                  # never raise above our parent
        f'--geometry={win_w}x{win_h}+0+0',  # pin to (0,0) inside parent
        f'--autofit={win_w}x{win_h}',
        f'--hwdec={hwdec}',
        f'--vo={vo}',
        f'tcp://{args.ip}:{args.vport}',
    ]
    print('[stream] spawning mpv:', ' '.join(mpv_cmd))
    mpv_log = open('/tmp/stream-mpv.log', 'w')
    mpv_proc = subprocess.Popen(mpv_cmd,
                                stdout=mpv_log, stderr=mpv_log,
                                preexec_fn=os.setsid)

    # Cleanup at exit
    def cleanup(*a):
        try: mpv_proc.send_signal(signal.SIGTERM)
        except: pass
        try: inp.close()
        except: pass
        try: disp.close()
        except: pass
    signal.signal(signal.SIGINT,  cleanup)
    signal.signal(signal.SIGTERM, cleanup)

    # 4) X11 event loop
    button_mask = 0
    last_send = 0
    pos_x = pos_y = 0
    dirty = False
    try:
        while True:
            # If mpv died, exit
            if mpv_proc.poll() is not None:
                print('[stream] mpv exited, shutting down')
                break

            # Drain X events. Use a tight loop so we don't lag.
            while disp.pending_events():
                ev = disp.next_event()
                t = ev.type

                if t == X.KeyPress or t == X.KeyRelease:
                    ks = x_keysym_to_rfb(disp, ev.detail, ev.state)
                    if ks:
                        inp.send_key(t == X.KeyPress, ks)

                elif t == X.MotionNotify:
                    # Map our window-local coords (ev.event_x/y, 0..win_w/h)
                    # to guest absolute coords (0..inp.w/h).
                    pos_x = int(ev.event_x * inp.w / win_w)
                    pos_y = int(ev.event_y * inp.h / win_h)
                    dirty = True

                elif t == X.ButtonPress or t == X.ButtonRelease:
                    bit = {1:1, 2:2, 3:4, 4:8, 5:16}.get(ev.detail, 0)
                    if t == X.ButtonPress:
                        button_mask |= bit
                    else:
                        if bit in (8, 16):  # wheel: edge-trigger only
                            pass
                        else:
                            button_mask &= ~bit
                    pos_x = int(ev.event_x * inp.w / win_w)
                    pos_y = int(ev.event_y * inp.h / win_h)
                    inp.send_pointer(button_mask, pos_x, pos_y)
                    if bit in (8, 16):  # wheel — clear after pulse
                        button_mask &= ~bit
                        inp.send_pointer(button_mask, pos_x, pos_y)
                    dirty = False  # already sent pointer

                elif t == X.ClientMessage:
                    if ev.client_type == WM_PROTOCOLS:
                        # WM close
                        print('[stream] window close requested')
                        break

            # Coalesce pointer-motion: send at most every 4 ms.
            now = time.monotonic()
            if dirty and (now - last_send) > 0.004:
                inp.send_pointer(button_mask, pos_x, pos_y)
                last_send = now
                dirty = False

            # Throttle event loop just enough not to hot-spin.
            if not disp.pending_events():
                # 1 ms timeout via select on display fd
                import select
                select.select([disp.fileno()], [], [], 0.001)
    finally:
        cleanup()

if __name__ == '__main__':
    main()
