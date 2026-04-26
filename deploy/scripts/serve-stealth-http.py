#!/usr/bin/env python3
# serve-stealth-http.py —— 替代 `python3 -m http.server`
#
# 修原版的两个问题：
#   1) .ps1 / .sh / .txt 的 Content-Type 自动加 charset=utf-8，让 Windows
#      PowerShell 5.1 的 irm | iex 不会把 UTF-8 字节按 Latin-1 解码导致中文
#      乱码 + BOM (EF BB BF) 被当 `i»¿` 字面字符。
#   2) HEAD/GET 路径都正常，仍服 deploy/scripts/ 下的全部资源。
#
# 用法：
#     python3 deploy/scripts/serve-stealth-http.py [PORT] [BIND_IP]
#
# 默认 8765 + 192.168.30.<host_ip_on_br0>。

import http.server
import socketserver
import os
import sys
from pathlib import Path

# 哪些后缀强制 UTF-8 charset（PowerShell + bash 脚本 + 纯文本）
UTF8_EXT = {'.ps1', '.psm1', '.psd1', '.sh', '.bash', '.txt', '.json', '.xml', '.inf'}

class StealthHandler(http.server.SimpleHTTPRequestHandler):
    def guess_type(self, path):
        ext = Path(path).suffix.lower()
        if ext in UTF8_EXT:
            return 'text/plain; charset=utf-8'
        return super().guess_type(path)

    def log_message(self, format, *args):
        # 简洁日志
        sys.stderr.write("[serve] %s - %s\n" % (self.address_string(), format % args))


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    if len(sys.argv) > 2:
        bind = sys.argv[2]
    else:
        # 自动选 br0 上的 IP
        import subprocess
        try:
            out = subprocess.check_output(
                ['ip', '-4', '-o', 'addr', 'show', 'dev', 'br0'],
                stderr=subprocess.DEVNULL).decode()
            bind = out.split()[3].split('/')[0]
        except Exception:
            bind = '0.0.0.0'

    here = Path(__file__).resolve().parent
    os.chdir(str(here))

    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer((bind, port), StealthHandler) as httpd:
        sys.stderr.write(f"[serve] http://{bind}:{port}/  cwd={here}\n")
        sys.stderr.write(f"[serve] .ps1/.sh/.txt 加 charset=utf-8\n")
        httpd.serve_forever()


if __name__ == '__main__':
    main()
