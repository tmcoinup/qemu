#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""
qemu-fb-shm-stream.py - reference consumer for the `-display fb-shm` backend.

Connects to a fb-shm control socket, receives the memfd + eventfd via
SCM_RIGHTS, mmaps the memfd, and pipes raw frames to ffmpeg for real-time
H.264 / RTMP / UDP / file output.

Pipeline (zero-copy on the QEMU side, single memcpy on the Python side):

    QEMU --pixman-> SHM[buf_idx] --memcpy-> bytes-> ffmpeg stdin
                       ^                              |
                       | seqlock                      v
                       +------- eventfd doorbell      H.264 NVENC / QSV / x264

Usage examples:

    # raw preview to a local mpv/ffplay over UDP
    qemu-fb-shm-stream.py --sock /run/qemu/fb-vm1.sock \\
        --output 'udp://127.0.0.1:5000?pkt_size=1316' \\
        --encoder h264_nvenc --bitrate 8M

    # save to local mp4 (no network)
    qemu-fb-shm-stream.py --sock /run/qemu/fb-vm1.sock \\
        --output /tmp/vm1.mp4 --encoder libx264 --preset veryfast

    # RTMP push to ingest server
    qemu-fb-shm-stream.py --sock /run/qemu/fb-vm1.sock \\
        --output 'rtmp://ingest.example/live/vm1' \\
        --encoder h264_nvenc --gop 60 --bitrate 6M

    # change ROI at runtime via SET_ROI ctl message
    qemu-fb-shm-stream.py --sock /run/qemu/fb-vm1.sock \\
        --roi 100,80,1280,720 --output ...
"""

from __future__ import annotations

import argparse
import array
import ctypes
import errno
import fcntl
import mmap
import os
import select
import shlex
import signal
import socket
import struct
import subprocess
import sys
import time
from dataclasses import dataclass

# ---------------------------------------------------------------------------
# ABI mirror — keep in sync with include/ui/fb-shm-abi.h
# ---------------------------------------------------------------------------

FB_SHM_MAGIC        = 0x46425348
FB_SHM_VERSION      = 1
FB_SHM_HEADER_SIZE  = 256
FB_SHM_BUF_COUNT    = 2

FB_SHM_FOURCC_BGR0  = 0x30524742
FB_SHM_FOURCC_BGRA  = 0x41524742

FB_SHM_CTL_HELLO    = 1
FB_SHM_CTL_SET_ROI  = 2
FB_SHM_CTL_SET_RATE = 3
FB_SHM_CTL_BYE      = 4

FB_SHM_CTL_OK       = 0

# Header struct layout (matches FbShmHeader). 256-byte slot reserved on the
# wire; the unused tail is just padding we never read.
_HDR_FMT = (
    '<'        # little-endian
    'IIII'     # magic, version, header_size, buf_count
    'Q'        # buf_size
    f'{FB_SHM_BUF_COUNT}Q'  # buf_offset[N]
    'Q'        # map_size
    'IIIIII'   # width, height, stride, fourcc, bpp, target_fps
    'II'       # src_width, src_height
    'ii'       # roi_x, roi_y
    'iiii'     # damage_x, damage_y, damage_w, damage_h
    'Q'        # frame_seq
    'Q'        # ts_ns
    'II'       # active_idx, flags
)
_HDR_SIZE = struct.calcsize(_HDR_FMT)
assert _HDR_SIZE <= FB_SHM_HEADER_SIZE, _HDR_SIZE

FOURCC_NAME = {
    FB_SHM_FOURCC_BGR0: 'bgr0',
    FB_SHM_FOURCC_BGRA: 'bgra',
}

# Control request/reply (32 bytes each).
_CTL_REQ_FMT = '<IIiiIIII'
_CTL_ACK_FMT = '<IIIIIIII'
assert struct.calcsize(_CTL_REQ_FMT) == 32
assert struct.calcsize(_CTL_ACK_FMT) == 32


@dataclass
class FbShmHeader:
    magic:       int
    version:     int
    header_size: int
    buf_count:   int
    buf_size:    int
    buf_offset:  list
    map_size:    int
    width:       int
    height:      int
    stride:      int
    fourcc:      int
    bpp:         int
    target_fps:  int
    src_width:   int
    src_height:  int
    roi_x:       int
    roi_y:       int
    damage_x:    int
    damage_y:    int
    damage_w:    int
    damage_h:    int
    frame_seq:   int
    ts_ns:       int
    active_idx:  int
    flags:       int

    @classmethod
    def parse(cls, mm: mmap.mmap) -> 'FbShmHeader':
        raw = bytes(mm[:_HDR_SIZE])
        v = struct.unpack(_HDR_FMT, raw)
        i = 0
        magic, version, header_size, buf_count = v[i:i + 4]; i += 4
        buf_size = v[i]; i += 1
        buf_offset = list(v[i:i + buf_count])
        i += FB_SHM_BUF_COUNT
        map_size = v[i]; i += 1
        width, height, stride, fourcc, bpp, target_fps = v[i:i + 6]; i += 6
        src_width, src_height = v[i:i + 2]; i += 2
        roi_x, roi_y = v[i:i + 2]; i += 2
        dx, dy, dw, dh = v[i:i + 4]; i += 4
        frame_seq, ts_ns = v[i:i + 2]; i += 2
        active_idx, flags = v[i:i + 2]
        return cls(magic, version, header_size, buf_count, buf_size,
                   buf_offset, map_size, width, height, stride, fourcc,
                   bpp, target_fps, src_width, src_height, roi_x, roi_y,
                   dx, dy, dw, dh, frame_seq, ts_ns, active_idx, flags)


# ---------------------------------------------------------------------------
# Control socket helpers
# ---------------------------------------------------------------------------

def _ctl_pack(op: int, *, x: int = 0, y: int = 0, w: int = 0, h: int = 0,
              rate_hz: int = 0) -> bytes:
    return struct.pack(_CTL_REQ_FMT, FB_SHM_MAGIC, op,
                       x, y, w, h, rate_hz, 0)


def _ctl_unpack_ack(buf: bytes):
    (magic, op, status, shm_size, width, height, fourcc, bpp) = \
        struct.unpack(_CTL_ACK_FMT, buf)
    if magic != FB_SHM_MAGIC:
        raise RuntimeError(f'bad ack magic 0x{magic:x}')
    return op, status, shm_size, width, height, fourcc, bpp


def hello(sock_path: str, *, timeout: float = 5.0):
    """Connect and exchange HELLO. Returns (memfd, eventfd, ack_tuple)."""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM | socket.SOCK_CLOEXEC)
    s.settimeout(timeout)
    s.connect(sock_path)
    s.sendall(_ctl_pack(FB_SHM_CTL_HELLO))
    fds = array.array('i')
    msglen = struct.calcsize(_CTL_ACK_FMT)
    msg, ancdata, _flags, _addr = s.recvmsg(
        msglen, socket.CMSG_SPACE(fds.itemsize * 2))
    if len(msg) != msglen:
        raise RuntimeError(f'short HELLO ack: {len(msg)} bytes')
    op, status, shm_size, width, height, fourcc, bpp = _ctl_unpack_ack(msg)
    if status != FB_SHM_CTL_OK:
        raise RuntimeError(f'HELLO failed status={status}')
    for level, type_, data in ancdata:
        if level == socket.SOL_SOCKET and type_ == socket.SCM_RIGHTS:
            fds.frombytes(data[:len(data) - (len(data) % fds.itemsize)])
    if len(fds) < 2:
        raise RuntimeError('HELLO ack missing memfd/eventfd')
    memfd, evfd = int(fds[0]), int(fds[1])
    return s, memfd, evfd, (shm_size, width, height, fourcc, bpp)


def set_roi(s: socket.socket, x: int, y: int, w: int, h: int) -> None:
    s.sendall(_ctl_pack(FB_SHM_CTL_SET_ROI, x=x, y=y, w=w, h=h))
    ack = s.recv(struct.calcsize(_CTL_ACK_FMT))
    op, status, *_ = _ctl_unpack_ack(ack)
    if status != FB_SHM_CTL_OK:
        raise RuntimeError(f'SET_ROI failed status={status}')


def set_rate(s: socket.socket, rate_hz: int) -> None:
    s.sendall(_ctl_pack(FB_SHM_CTL_SET_RATE, rate_hz=rate_hz))
    ack = s.recv(struct.calcsize(_CTL_ACK_FMT))
    op, status, *_ = _ctl_unpack_ack(ack)
    if status != FB_SHM_CTL_OK:
        raise RuntimeError(f'SET_RATE failed status={status}')


# ---------------------------------------------------------------------------
# Frame reader
# ---------------------------------------------------------------------------

class FrameReader:
    """Reads BGR0 frames from the SHM. Use as an iterator."""

    def __init__(self, memfd: int, evfd: int, shm_size: int):
        self.evfd = evfd
        self.shm_size = shm_size
        # mmap the memfd. We trust QEMU's seal; size is fixed for the
        # lifetime of this geometry.
        self.mm = mmap.mmap(memfd, shm_size, mmap.MAP_SHARED,
                            mmap.PROT_READ)
        self.last_seq = 0
        self.hdr = FbShmHeader.parse(self.mm)
        if self.hdr.magic != FB_SHM_MAGIC:
            raise RuntimeError(f'bad SHM magic 0x{self.hdr.magic:x}')
        if self.hdr.version != FB_SHM_VERSION:
            raise RuntimeError(f'unsupported SHM version {self.hdr.version}')
        os.close(memfd)   # mmap kept the mapping; fd no longer needed

    def close(self):
        try:
            self.mm.close()
        finally:
            try:
                os.close(self.evfd)
            except OSError:
                pass

    def _refresh_header(self) -> None:
        self.hdr = FbShmHeader.parse(self.mm)

    def wait_frame(self, timeout: float = 1.0) -> bool:
        """Block on the eventfd doorbell. Returns True if signaled."""
        r, _, _ = select.select([self.evfd], [], [], timeout)
        if not r:
            return False
        # drain
        try:
            os.read(self.evfd, 8)
        except BlockingIOError:
            pass
        return True

    def read_frame(self) -> bytes | None:
        """Seqlock read. Returns the latest frame as raw BGR0 bytes, or
        None if no new frame since last call."""
        # Snapshot
        for attempt in range(8):
            self._refresh_header()
            seq0 = self.hdr.frame_seq
            if seq0 == self.last_seq:
                return None
            idx = self.hdr.active_idx
            if idx >= self.hdr.buf_count:
                continue
            off = self.hdr.buf_offset[idx]
            length = self.hdr.buf_size
            chunk = bytes(self.mm[off:off + length])
            self._refresh_header()
            seq1 = self.hdr.frame_seq
            if seq0 == seq1:
                self.last_seq = seq1
                return chunk
        # Concurrent writer kept invalidating us; give up this tick.
        return None


# ---------------------------------------------------------------------------
# ffmpeg wrapper
# ---------------------------------------------------------------------------

def build_ffmpeg_cmd(*, width: int, height: int, fps: int, fourcc: str,
                     output: str, encoder: str, preset: str, bitrate: str,
                     gop: int, container: str, extra: list) -> list:
    cmd = [
        'ffmpeg', '-hide_banner', '-loglevel', 'warning',
        # input — raw pixels from stdin
        '-f', 'rawvideo',
        '-pix_fmt', fourcc,
        '-video_size', f'{width}x{height}',
        '-framerate', str(fps),
        '-i', '-',
        # encoder
        '-c:v', encoder,
        '-b:v', bitrate,
        '-g', str(gop),
        '-pix_fmt', 'yuv420p',
    ]
    if encoder in ('h264_nvenc', 'hevc_nvenc'):
        cmd += ['-preset', preset, '-tune', 'll', '-rc', 'cbr',
                '-zerolatency', '1']
    elif encoder in ('h264_qsv', 'hevc_qsv'):
        cmd += ['-preset', preset, '-look_ahead', '0']
    else:
        cmd += ['-preset', preset, '-tune', 'zerolatency']
    cmd += list(extra)
    if container:
        cmd += ['-f', container]
    cmd += [output]
    return cmd


def guess_container(output: str, explicit: str | None) -> str:
    if explicit:
        return explicit
    if output.startswith('rtmp://') or output.startswith('rtmps://'):
        return 'flv'
    if output.startswith('udp://') or output.startswith('rtp://'):
        return 'mpegts'
    if output.startswith('srt://'):
        return 'mpegts'
    if output.endswith('.mp4'):
        return 'mp4'
    if output.endswith('.mkv'):
        return 'matroska'
    return ''


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def parse_roi(s: str | None):
    if not s:
        return None
    parts = [int(p.strip()) for p in s.split(',')]
    if len(parts) != 4:
        raise ValueError('--roi must be x,y,w,h')
    return tuple(parts)


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--sock', required=True,
                   help='control socket path (e.g. /run/qemu/fb-vm1.sock)')
    p.add_argument('--output', required=True, help='ffmpeg output URL/file')
    p.add_argument('--roi', help='runtime ROI: x,y,w,h')
    p.add_argument('--rate', type=int,
                   help='ask backend to retarget this Hz at runtime')
    p.add_argument('--encoder', default='h264_nvenc',
                   help='ffmpeg video codec (default: h264_nvenc)')
    p.add_argument('--preset', default='p1',
                   help='encoder preset (NVENC: p1..p7; libx264: ultrafast..)')
    p.add_argument('--bitrate', default='6M', help='target bitrate')
    p.add_argument('--gop', type=int, default=60, help='GOP size')
    p.add_argument('--container', default=None,
                   help='ffmpeg muxer (auto-detected from output if omitted)')
    p.add_argument('--ffmpeg-extra', default='',
                   help='extra args appended to ffmpeg command')
    p.add_argument('--max-frames', type=int, default=0,
                   help='stop after N frames (0=unlimited)')
    p.add_argument('--cpu-affinity', default=None,
                   help='comma-separated CPU list to pin this process to')
    args = p.parse_args(argv)

    if args.cpu_affinity:
        cpus = [int(c) for c in args.cpu_affinity.split(',')]
        os.sched_setaffinity(0, cpus)

    sock, memfd, evfd, ack = hello(args.sock)
    shm_size, width, height, fourcc, bpp = ack
    fourcc_name = FOURCC_NAME.get(fourcc, 'bgr0')
    print(f'[fb-shm] connected: {width}x{height} {fourcc_name}/{bpp}bpp '
          f'shm={shm_size}B', file=sys.stderr)

    if args.roi:
        x, y, w, h = parse_roi(args.roi)
        set_roi(sock, x, y, w, h)
        print(f'[fb-shm] requested ROI {w}x{h}@{x},{y}', file=sys.stderr)

    if args.rate:
        set_rate(sock, args.rate)
        print(f'[fb-shm] requested rate={args.rate} Hz', file=sys.stderr)

    reader = FrameReader(memfd, evfd, shm_size)
    fps = reader.hdr.target_fps or 30
    width, height = reader.hdr.width, reader.hdr.height
    print(f'[fb-shm] header: {width}x{height} fps={fps}', file=sys.stderr)

    cmd = build_ffmpeg_cmd(
        width=width, height=height, fps=fps, fourcc=fourcc_name,
        output=args.output, encoder=args.encoder, preset=args.preset,
        bitrate=args.bitrate, gop=args.gop,
        container=guess_container(args.output, args.container),
        extra=shlex.split(args.ffmpeg_extra))
    print('[fb-shm] ffmpeg:', ' '.join(shlex.quote(x) for x in cmd),
          file=sys.stderr)

    ff = subprocess.Popen(cmd, stdin=subprocess.PIPE,
                          preexec_fn=os.setpgrp)
    stop = False
    def _sig(*_): nonlocal stop; stop = True
    signal.signal(signal.SIGINT, _sig)
    signal.signal(signal.SIGTERM, _sig)

    n = 0
    t0 = time.monotonic()
    try:
        while not stop:
            if not reader.wait_frame(timeout=1.0):
                continue
            frame = reader.read_frame()
            if frame is None:
                continue
            try:
                ff.stdin.write(frame)
            except BrokenPipeError:
                break
            n += 1
            if args.max_frames and n >= args.max_frames:
                break
            if n % 300 == 0:
                dt = time.monotonic() - t0
                print(f'[fb-shm] {n} frames in {dt:.1f}s '
                      f'({n / dt:.1f} fps)', file=sys.stderr)
    finally:
        try:
            ff.stdin.close()
        except Exception:
            pass
        try:
            ff.wait(timeout=5)
        except subprocess.TimeoutExpired:
            ff.terminate()
        try:
            sock.sendall(_ctl_pack(FB_SHM_CTL_BYE))
        except OSError:
            pass
        sock.close()
        reader.close()
        dt = time.monotonic() - t0
        print(f'[fb-shm] done: {n} frames in {dt:.1f}s '
              f'({n / max(dt, 1e-6):.1f} fps)', file=sys.stderr)


if __name__ == '__main__':
    main()
