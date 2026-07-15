#!/usr/bin/env python3
"""
server.py — 给 guest 拉脚本/binary 的 HTTP 文件服务器。

  默认 serve  $STAGE_DIR        (默认 /home/ubuntu/images/staging)
  默认端口    8080
  仅下载      禁止目录列表和私密 staging 资产
  并发        多线程，长下载不阻塞短脚本

启动时自动 sync deploy/guest/*.ps1 → staging/，把 git 跟踪的源同步到
HTTP staging 区，guest 内 `irm | iex` 就能拉到最新版本。

用法:
    python3 server.py                     # default port 8080, default dir
    python3 server.py 9000                # 位置参数 = port
    python3 server.py --port 9000
    python3 server.py --dir /tmp --port 9000
    python3 server.py --bind 127.0.0.1
"""
import argparse
import functools
import http.server
import os
import shutil
import socketserver
import sys
import tempfile
import urllib.parse
from http import HTTPStatus

DEFAULT_PORT = 8080
DEFAULT_IMAGE_ROOT = os.environ.get('IMAGE_ROOT', '/home/ubuntu/images')
DEFAULT_DIR  = os.environ.get('STAGE_DIR', os.path.join(DEFAULT_IMAGE_ROOT, 'staging'))
DEFAULT_BIND = '0.0.0.0'

# 项目内 PowerShell 源（git 跟踪），server 启动时 sync 到 staging。
SCRIPT_SRC   = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'guest')


class Utf8Handler(http.server.SimpleHTTPRequestHandler):
    """A download-only handler that keeps private staging files private."""

    @staticmethod
    def _has_protected_component(parts):
        for part in parts:
            lowered = part.lower()
            if part.startswith('.'):
                return True
            if lowered.endswith('.tok'):
                return True
            if lowered.startswith('vgpuguestfinish'):
                return True
        return False

    def _request_is_protected(self):
        """Reject private names before and after filesystem resolution.

        Checking both forms prevents URL encoding and an in-tree symlink with a
        harmless-looking name from exposing a token or the token-bearing guest
        finisher.
        """
        request_path = urllib.parse.urlsplit(self.path).path
        decoded = urllib.parse.unquote(request_path, errors='replace')
        request_parts = [part for part in decoded.split('/') if part]
        if self._has_protected_component(request_parts):
            return True

        root = os.path.realpath(self.directory or os.getcwd())
        translated = self.translate_path(self.path)
        resolved = os.path.realpath(translated)
        try:
            if os.path.commonpath((root, resolved)) != root:
                return True
        except ValueError:
            return True

        relative = os.path.relpath(resolved, root)
        if relative == os.curdir:
            return False
        return self._has_protected_component(relative.split(os.sep))

    def send_head(self):
        if self._request_is_protected():
            self.send_error(HTTPStatus.FORBIDDEN, 'Protected staging asset')
            return None
        path = self.translate_path(self.path)
        if os.path.isdir(path):
            self.send_error(HTTPStatus.FORBIDDEN, 'Directory listing is disabled')
            return None
        return super().send_head()

    def list_directory(self, path):
        self.send_error(HTTPStatus.FORBIDDEN, 'Directory listing is disabled')
        return None

    def log_message(self, fmt, *args):
        sys.stderr.write(f'[{self.address_string()}] {fmt % args}\n')


class ThreadedServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    """允许并发请求 — 大文件下载 + 短 ps1 同时跑不互相阻塞。"""
    daemon_threads = True
    allow_reuse_address = True


def _same_content(first, second):
    try:
        if os.path.getsize(first) != os.path.getsize(second):
            return False
        with open(first, 'rb') as left, open(second, 'rb') as right:
            while True:
                left_chunk = left.read(1024 * 1024)
                right_chunk = right.read(1024 * 1024)
                if left_chunk != right_chunk:
                    return False
                if not left_chunk:
                    return True
    except OSError:
        return False


def _copy_atomically(src, dst):
    stage_dir = os.path.dirname(dst)
    descriptor, temporary = tempfile.mkstemp(
        prefix=f'.{os.path.basename(dst)}.', suffix='.tmp', dir=stage_dir)
    os.close(descriptor)
    try:
        shutil.copy2(src, temporary)
        with open(temporary, 'rb') as stream:
            os.fsync(stream.fileno())
        os.replace(temporary, dst)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def sync_scripts(stage_dir):
    """把 deploy/guest/*.ps1 同步到 staging — 这样改 ps1 后只要重启 server，
    guest `irm` 拿的就是最新版本，无需手动 cp。"""
    if not os.path.isdir(SCRIPT_SRC):
        return []
    synced = []
    for name in sorted(os.listdir(SCRIPT_SRC)):
        if not name.endswith('.ps1'):
            continue
        src = os.path.join(SCRIPT_SRC, name)
        dst = os.path.join(stage_dir, name)
        if not os.path.isfile(src) or os.path.islink(src):
            continue
        if (os.path.isfile(dst) and not os.path.islink(dst) and
                _same_content(src, dst)):
            continue
        _copy_atomically(src, dst)
        synced.append(name)
    if synced:
        print(f'[server] synced {len(synced)} ps1 from deploy/guest/: '
              + ', '.join(synced), flush=True)
    return synced


def main():
    ap = argparse.ArgumentParser(
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description=__doc__.strip())
    ap.add_argument('port_pos', nargs='?', type=int, default=None,
                    help='端口（位置参数；与 --port 二选一）')
    ap.add_argument('-p', '--port', type=int, default=DEFAULT_PORT,
                    help=f'端口（默认 {DEFAULT_PORT}）')
    ap.add_argument('-d', '--dir', default=DEFAULT_DIR,
                    help=f'serve 目录（默认 {DEFAULT_DIR}）')
    ap.add_argument('-b', '--bind', default=DEFAULT_BIND,
                    help=f'bind 地址（默认 {DEFAULT_BIND}）')
    ap.add_argument('--no-sync', action='store_true',
                    help='跳过启动时 deploy/guest/*.ps1 自动 sync')
    args = ap.parse_args()

    port = args.port_pos if args.port_pos is not None else args.port

    os.makedirs(args.dir, exist_ok=True)
    if not args.no_sync:
        sync_scripts(args.dir)
    print(f'[server] serving {args.dir}  on  http://{args.bind}:{port}/',
          flush=True)
    print(f'[server] e.g.    irm http://<host>:{port}/setup-winrm.ps1 | iex',
          flush=True)
    handler = functools.partial(Utf8Handler, directory=args.dir)
    httpd = ThreadedServer((args.bind, port), handler)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print('\n[server] bye')


if __name__ == '__main__':
    main()
