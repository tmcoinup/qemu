#!/usr/bin/env python3
"""Record G-11 QMP lifecycle events without changing the VM or guest."""
import argparse
from collections import deque
import importlib.util
import json
import os
from pathlib import Path
import select
import signal
import sys
import tempfile
import time


spec = importlib.util.spec_from_file_location(
    'g11_console', Path(__file__).with_name('control-g11-console.py'))
console = importlib.util.module_from_spec(spec)
spec.loader.exec_module(console)

EVENTS = {'RESET', 'SHUTDOWN', 'STOP', 'RESUME', 'SUSPEND', 'SUSPEND_DISK',
          'WAKEUP', 'GUEST_PANICKED', 'WATCHDOG', 'BLOCK_IO_ERROR', 'MEMORY_FAILURE'}
FIELDS = {'guest', 'reason', 'action', 'status', 'operation', 'nospace',
          'recipient', 'action-required', 'recursive'}


def event_record(message):
    if not isinstance(message, dict):
        raise console.ControlError('QMP 返回了无效消息。')
    if message.get('event') not in EVENTS:
        return None
    data = message.get('data', {})
    if not isinstance(data, dict):
        raise console.ControlError('QMP 返回了无效事件。')
    return {'kind': 'event', 'observed_at': console.timestamp(),
            'qmp_timestamp': message.get('timestamp'),
            'event': message['event'],
            'data': {k: v for k, v in data.items() if k in FIELDS and
                     (isinstance(v, (bool, int)) or
                      isinstance(v, str) and len(v) <= 128)}}


class Observer(console.QMP):
    # The observer can never send input, reset, stop, cont, or shutdown.
    ALLOWED = {'qmp_capabilities', 'query-name', 'query-status'}

    def __init__(self, target):
        self.events = deque()
        super().__init__(target)

    def receive(self, deadline):
        message = super().receive(deadline)
        record = event_record(message)
        if record is not None:
            if len(self.events) >= 4096:
                raise console.ControlError('事件积压过多，记录已停止，不能保证完整覆盖。')
            self.events.append(record)
        return message


def open_report(path):
    # Refuse overwrite and symlinks, including when launched from /tmp.
    return os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                            os.O_NOFOLLOW, 0o600), 'w', encoding='utf-8')


def main(argv=None):
    parser = argparse.ArgumentParser(description='只读记录 G-11 重启/暂停/关机事件；Ctrl+C 停止记录。')
    parser.add_argument('--vm', type=int, required=True)
    parser.add_argument('--seconds', type=int, default=86400)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args(argv)
    if not 1 <= args.vm <= 2147483647 or not 1 <= args.seconds <= 604800:
        parser.error('VM ID must be positive; --seconds must be 1..604800')
    observer = None
    report = None
    stop = False
    previous_signals = {}

    def request_stop(*_):
        nonlocal stop
        stop = True

    def emit(record):
        report.write(json.dumps(record, ensure_ascii=False) + '\n')
        report.flush()
        if record['kind'] == 'event':
            print(json.dumps(record, ensure_ascii=False), flush=True)

    def drain():
        while observer.events:
            emit(observer.events.popleft())

    try:
        observer = Observer(console.find_target(args.vm))
        if args.output is None:
            args.output = Path(tempfile.mkdtemp(prefix=f'g11-exit-vm{args.vm}-')) / 'lifecycle.jsonl'
        report = open_report(args.output)
        for sig in (signal.SIGINT, signal.SIGTERM):
            previous_signals[sig] = signal.signal(sig, request_stop)
        emit({'kind': 'start', 'observed_at': console.timestamp(), 'vm': args.vm,
              'qemu_pid': observer.pid, 'qemu_start_ticks': observer.expected[1],
              'seconds': args.seconds,
              'limits': 'Observation starts now; no historical events or guest process monitoring. '
                        'RESET reason identifies a reset category, not a responsible driver or caller.'})
        print(f'REPORT={args.output.resolve()}', flush=True)
        deadline = time.monotonic() + args.seconds
        next_status = 0.0
        while not stop and time.monotonic() < deadline:
            observer.guard()
            if time.monotonic() >= next_status:
                status = observer.call('query-status')
                drain()  # Preserve events arriving between a query and its reply.
                emit({'kind': 'status', 'observed_at': console.timestamp(),
                      'running': status.get('running'), 'status': status.get('status')})
                next_status = time.monotonic() + 30
            drain()
            wait = min(1.0, max(0.0, deadline - time.monotonic()))
            if b'\n' in observer.buffer or select.select([observer.socket], [], [], wait)[0]:
                try:
                    observer.receive(time.monotonic() + 1)
                except TimeoutError:
                    # A partial JSON frame remains in the existing receive buffer.
                    pass
        drain()
        emit({'kind': 'end', 'observed_at': console.timestamp(),
              'reason': 'operator-stop' if stop else 'duration-complete'})
        return 0
    except (OSError, console.ControlError, ValueError) as exc:
        if report is not None:
            drain()
            emit({'kind': 'end', 'observed_at': console.timestamp(),
                  'reason': 'connection-or-identity-lost',
                  'detail': str(exc), 'coverage_complete': False})
        print(f'[lifecycle] stopped: {exc}', file=sys.stderr)
        return 1
    finally:
        for sig, handler in previous_signals.items():
            signal.signal(sig, handler)
        if observer is not None:
            observer.socket.close()
        if report is not None:
            report.close()


if __name__ == '__main__':
    sys.exit(main())
