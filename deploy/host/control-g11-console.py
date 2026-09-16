#!/usr/bin/env python3
"""Restricted QMP console operations; no window activation or guest software."""
import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import re
import shutil
import socket
import stat
import struct
import sys
import tempfile
import time


class ControlError(Exception):
    pass


def timestamp():
    return datetime.now().astimezone().isoformat(timespec='milliseconds')


def read(path):
    try:
        with open(path, 'rb') as stream:
            data = stream.read(4 * 1024 * 1024 + 1)
        return data if len(data) <= 4 * 1024 * 1024 else None
    except OSError:
        return None


def identity(pid):
    root = Path('/proc') / str(pid)
    raw = read(root / 'stat')
    try:
        name = os.readlink(root / 'exe').removesuffix(' (deleted)')
        exe = os.stat(root / 'exe')
        if raw is None or not re.fullmatch(r'qemu-system-[A-Za-z0-9_-]+(?:\.g11\.real)?', Path(name).name):
            return None
        return pid, int(raw[raw.rindex(b')') + 2:].split()[19]), exe.st_dev, exe.st_ino
    except (OSError, ValueError, IndexError):
        return None


def find_target(vm):
    found = []
    wanted = 'vm' + str(vm)
    for path in Path('/proc').iterdir():
        if not path.name.isdigit():
            continue
        pid = int(path.name)
        ident = identity(pid)
        raw = read(path / 'cmdline') if ident else None
        if raw is None:
            continue
        argv = [os.fsdecode(item) for item in raw.split(b'\0')]
        pairs = list(zip(argv, argv[1:]))
        if not any(key == '-name' and value.split(',')[0] == wanted for key, value in pairs):
            continue
        endpoints = [value[5:].split(',')[0] for key, value in pairs
                     if key == '-qmp' and value.startswith('unix:')]
        found.append((pid, ident, endpoints))
    if len(found) != 1 or len(found[0][2]) != 1 or not found[0][2][0]:
        raise ControlError('无法唯一确认 VM 和 Unix QMP 端点；请检查运行状态或 /proc 读取权限。')
    pid, ident, endpoints = found[0]
    return pid, ident, endpoints[0], wanted


class QMP:
    ALLOWED = {'qmp_capabilities', 'query-name', 'query-status',
               'send-key', 'input-send-event', 'screendump'}

    def __init__(self, target):
        self.pid, self.expected, endpoint, self.name = target
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.buffer = b''
        self.sequence = 0
        try:
            self.guard()
            if not stat.S_ISSOCK(os.stat(endpoint).st_mode):
                raise ControlError('QMP 端点不是 Unix socket。')
            self.socket.settimeout(4)
            self.socket.connect(endpoint)
            peer_pid, _, _ = struct.unpack('3i', self.socket.getsockopt(
                socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize('3i')))
            if peer_pid != self.pid:
                raise ControlError('QMP socket 的实际进程不匹配，未执行控制操作。')
            greeting = self.receive(time.monotonic() + 4)
            if not isinstance(greeting, dict) or 'QMP' not in greeting:
                raise ControlError('QMP 握手失败。')
            self.call('qmp_capabilities')
            response = self.call('query-name')
            if not isinstance(response, dict) or response.get('name') != self.name:
                raise ControlError('QMP 返回的 VM 名称不匹配，未执行控制操作。')
        except BaseException:
            self.socket.close()
            raise

    def guard(self):
        if identity(self.pid) != self.expected:
            raise ControlError('QEMU 已退出、身份变化或无法读取，操作已停止。')

    def receive(self, deadline):
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise ControlError('QMP 响应超时。')
            if b'\n' in self.buffer:
                line, self.buffer = self.buffer.split(b'\n', 1)
                try:
                    return json.loads(line)
                except ValueError:
                    raise ControlError('QMP 响应格式无效。') from None
            self.socket.settimeout(remaining)
            data = self.socket.recv(4096)
            if not data or len(self.buffer) + len(data) > 1024 * 1024:
                raise ControlError('QMP 连接关闭或响应超过大小限制。')
            self.buffer += data

    def call(self, command, arguments=None):
        if command not in self.ALLOWED:
            raise ControlError('不允许此 QMP 命令。')
        self.guard()
        self.sequence += 1
        message = {'execute': command, 'id': self.sequence}
        if arguments is not None:
            message['arguments'] = arguments
        self.socket.settimeout(4)
        self.socket.sendall(json.dumps(message).encode('utf-8') + b'\n')
        deadline = time.monotonic() + 4
        while True:
            response = self.receive(deadline)
            if not isinstance(response, dict) or response.get('id') != self.sequence:
                continue
            if 'error' in response:
                raise ControlError('QMP 拒绝操作；请检查 VM 状态、按键名称或截图写入权限。')
            if 'return' in response:
                self.guard()
                return response['return']


def screenshot(qmp, output_dir):
    destination = Path(output_dir).expanduser().absolute()
    destination.mkdir(mode=0o700)
    # QEMU writes only inside a private temporary directory. Publish a checked
    # regular PNG with an exclusive file creation; never overwrite user files.
    with tempfile.TemporaryDirectory(prefix='g11-console-') as temporary:
        source = Path(temporary) / 'capture.png'
        qmp.call('screendump', {'filename': str(source), 'format': 'png'})
        fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, 'rb') as image:
            info = os.fstat(image.fileno())
            if not stat.S_ISREG(info.st_mode) or not 24 <= info.st_size <= 512 * 1024 * 1024:
                raise ControlError('截图不是大小有效的普通文件。')
            header = image.read(24)
            if header[:16] != b'\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR':
                raise ControlError('QEMU 未生成有效 PNG 截图。')
            width, height = struct.unpack('>II', header[16:24])
            if width < 2 or height < 2:
                raise ControlError('截图尺寸无效。')
            image.seek(0)
            partial = destination / '.capture.partial'
            output = os.open(partial, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            try:
                with os.fdopen(output, 'wb') as stream:
                    shutil.copyfileobj(image, stream, 1024 * 1024)
                qmp.guard()
                os.link(partial, destination / 'screenshot.png')
            finally:
                partial.unlink(missing_ok=True)
    return {'image': 'screenshot.png', 'width': width, 'height': height}


def main():
    parser = argparse.ArgumentParser(description='G-11 受限 QMP 控制；仅 status/key/click/screenshot，不激活宿主窗口。')
    parser.add_argument('--vm', required=True, type=int, help='唯一运行的 VM 编号')
    actions = parser.add_subparsers(dest='action', required=True)
    actions.add_parser('status', help='只读查询运行状态')
    key = actions.add_parser('key', help='发送一次 QEMU qcode 按键或组合键，100ms 后释放')
    key.add_argument('keys', nargs='+', help='例如 esc、ret、f1；组合键分别传入 ctrl alt delete')
    click = actions.add_parser('click', help='按最近截图的像素坐标点击一次')
    click.add_argument('--x', required=True, type=int)
    click.add_argument('--y', required=True, type=int)
    click.add_argument('--width', required=True, type=int, help='截图宽度')
    click.add_argument('--height', required=True, type=int, help='截图高度')
    click.add_argument('--button', choices=('left', 'right', 'middle'), default='left')
    shot = actions.add_parser('screenshot', help='把 PNG 截图写入一个不存在的新目录')
    shot.add_argument('--output-dir', required=True, help='新目录；最终文件名为 screenshot.png')
    args = parser.parse_args()
    if args.vm <= 0:
        parser.error('VM 编号必须为正整数')
    if args.action == 'key' and (len(args.keys) > 8 or
                                any(not re.fullmatch(r'[a-z0-9_]{1,24}', key) for key in args.keys)):
        parser.error('只接受 1–8 个小写 QEMU qcode 按键名称')
    if args.action == 'click' and not (2 <= args.width <= 32768 and 2 <= args.height <= 32768 and
                                       0 <= args.x < args.width and 0 <= args.y < args.height):
        parser.error('点击坐标须在显式截图尺寸内，宽高范围为 2–32768')
    qmp = None
    started = timestamp()
    try:
        qmp = QMP(find_target(args.vm))
        if args.action != 'status':
            raw = read(Path('/proc') / str(qmp.pid) / 'status')
            owner = re.search(rb'^Uid:\s+\d+\s+(\d+)\s+\d+\s+\d+$', raw or b'', re.M)
            if owner is None or int(owner[1]) != os.geteuid():
                raise ControlError('输入和截图须由运行 QEMU 的同一用户执行；本脚本不提权或改变进程身份。')
        detail = {}
        if args.action == 'status':
            result = qmp.call('query-status')
            if not isinstance(result, dict):
                raise ControlError('QMP 状态响应无效。')
            value = result.get('status')
            detail = {'running': result.get('running') if isinstance(result.get('running'), bool) else None,
                      'status': value if isinstance(value, str) and re.fullmatch(r'[a-z-]{1,40}', value) else None}
        elif args.action == 'key':
            qmp.call('send-key', {'keys': [{'type': 'qcode', 'data': key} for key in args.keys], 'hold-time': 100})
            detail = {'key_count': len(args.keys), 'hold_ms': 100}
        elif args.action == 'click':
            qmp.call('input-send-event', {'events': [
                {'type': 'abs', 'data': {'axis': 'x', 'value': round(args.x * 32767 / (args.width - 1))}},
                {'type': 'abs', 'data': {'axis': 'y', 'value': round(args.y * 32767 / (args.height - 1))}}]})
            time.sleep(0.15)
            try:
                qmp.call('input-send-event', {'events': [{'type': 'btn', 'data': {'button': args.button, 'down': True}}]})
                time.sleep(0.15)
            finally:
                qmp.call('input-send-event', {'events': [{'type': 'btn', 'data': {'button': args.button, 'down': False}}]})
            detail = {'x': args.x, 'y': args.y, 'width': args.width, 'height': args.height, 'button': args.button}
        elif args.action == 'screenshot':
            detail = screenshot(qmp, args.output_dir)
        print(json.dumps({'started_at': started, 'finished_at': timestamp(), 'vm': args.vm,
                          'action': args.action, 'result': 'ok', **detail}, ensure_ascii=False), flush=True)
        return 0
    except (ControlError, OSError) as error:
        message = str(error) if isinstance(error, ControlError) else '操作失败；请检查 QMP/文件权限、输出目录是否已存在或连接是否超时。'
        print(json.dumps({'started_at': started, 'finished_at': timestamp(), 'vm': args.vm,
                          'action': args.action, 'result': 'error', 'message': message}, ensure_ascii=False), file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print('操作已中断；点击过程中会尝试释放按钮。', file=sys.stderr)
        return 130
    finally:
        if qmp is not None:
            qmp.socket.close()


if __name__ == '__main__':
    sys.exit(main())
