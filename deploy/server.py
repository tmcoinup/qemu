#!/usr/bin/env python3
"""
server.py — 给 guest 拉脚本/binary 的 HTTP 文件服务器。

  默认 serve  $STAGE_DIR        (默认 /home/ubuntu/images/staging)
  默认端口    8080
  UTF-8       目录列表中文不乱码
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
import http.server
import os
import shutil
import socketserver
import sys

DEFAULT_PORT = 8080
DEFAULT_DIR  = os.environ.get('STAGE_DIR', '/home/ubuntu/images/staging')
DEFAULT_BIND = '0.0.0.0'

# 项目内 PowerShell 源（git 跟踪），server 启动时 sync 到 staging。
SCRIPT_SRC   = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'guest')


class Utf8Handler(http.server.SimpleHTTPRequestHandler):
    """SimpleHTTPRequestHandler + UTF-8 让目录列表/文件名中文不乱码。"""

    def send_head(self):
        path = self.translate_path(self.path)
        if os.path.isdir(path):
            f = super().list_directory(path)
            if f:
                self.send_response(200)
                self.send_header('Content-Type', 'text/html; charset=utf-8')
                self.end_headers()
            return f
        return super().send_head()

    def end_headers(self):
        mimetype = self.guess_type(self.path)
        if mimetype:
            self.send_header('Content-Type', f'{mimetype}; charset=utf-8')
        super().end_headers()

    def log_message(self, fmt, *args):
        sys.stderr.write(f'[{self.address_string()}] {fmt % args}\n')


class ThreadedServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    """允许并发请求 — 大文件下载 + 短 ps1 同时跑不互相阻塞。"""
    daemon_threads = True
    allow_reuse_address = True


def sync_scripts(stage_dir):
    """把 deploy/guest/*.ps1 同步到 staging — 这样改 ps1 后只要重启 server，
    guest `irm` 拿的就是最新版本，无需手动 cp。"""
    if not os.path.isdir(SCRIPT_SRC):
        return
    synced = []
    for name in os.listdir(SCRIPT_SRC):
        if not name.endswith('.ps1'):
            continue
        src = os.path.join(SCRIPT_SRC, name)
        dst = os.path.join(stage_dir, name)
        if (not os.path.exists(dst) or
                os.path.getmtime(src) > os.path.getmtime(dst)):
            shutil.copy2(src, dst)
            synced.append(name)
    if synced:
        print(f'[server] synced {len(synced)} ps1 from deploy/guest/: '
              + ', '.join(synced), flush=True)


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
    os.chdir(args.dir)

    print(f'[server] serving {args.dir}  on  http://{args.bind}:{port}/',
          flush=True)
    print(f'[server] e.g.    irm http://<host>:{port}/setup-winrm.ps1 | iex',
          flush=True)
    httpd = ThreadedServer((args.bind, port), Utf8Handler)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print('\n[server] bye')


if __name__ == '__main__':
    main()
