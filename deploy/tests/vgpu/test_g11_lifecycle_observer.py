#!/usr/bin/env python3
"""Exercise event/reply interleaving and read-only observer boundaries."""
from collections import deque
import importlib.util
import json
from pathlib import Path
import socket
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    'lifecycle', Path(__file__).resolve().parents[2] / 'host/watch-g11-lifecycle.py')
watch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(watch)


class LifecycleTests(unittest.TestCase):
    def test_event_during_status_query_is_preserved(self):
        client, peer = socket.socketpair()
        self.addCleanup(client.close)
        self.addCleanup(peer.close)
        observer = object.__new__(watch.Observer)
        observer.socket, observer.buffer, observer.sequence = client, b'', 0
        observer.events = deque()
        observer.guard = lambda: None
        for message in (
            {'event': 'RESET', 'data': {'guest': True, 'reason': 'guest-reset'},
             'timestamp': {'seconds': 123, 'microseconds': 456}},
            {'return': {'status': 'running', 'running': True}, 'id': 1},
        ):
            peer.sendall(json.dumps(message).encode() + b'\n')
        self.assertEqual(observer.call('query-status')['status'], 'running')
        self.assertEqual(len(observer.events), 1)
        event = observer.events.popleft()
        self.assertEqual(event['data']['reason'], 'guest-reset')
        self.assertEqual(event['qmp_timestamp']['seconds'], 123)
        request = json.loads(peer.recv(4096))
        self.assertEqual(request['execute'], 'query-status')
        with self.assertRaises(watch.console.ControlError):
            observer.call('system_reset')

    def test_reports_preserve_prior_files(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'report'
            with watch.open_report(path) as report:
                report.write('original')
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(FileExistsError):
                watch.open_report(path)
            link = Path(directory) / 'link'
            link.symlink_to(path)
            with self.assertRaises(OSError):
                watch.open_report(link)
            self.assertEqual(path.read_text(), 'original')

    def test_unneeded_payloads_are_not_saved(self):
        record = watch.event_record({'event': 'BLOCK_IO_ERROR', 'data': {
            'reason': 'io-error', 'device': '/private/path',
            'node-name': 'disk', 'operation': 'write', 'nospace': False,
            'info': {'secret': 'not-for-report'},
        }})
        self.assertEqual(record['data'], {
            'reason': 'io-error', 'operation': 'write', 'nospace': False})
        self.assertIsNone(watch.event_record({'event': 'DEVICE_DELETED', 'data': {}}))

    def test_invalid_qmp_message_fails_closed(self):
        for message in ([], {'event': 'RESET', 'data': 'bad'}):
            with self.assertRaises(watch.console.ControlError):
                watch.event_record(message)


if __name__ == '__main__':
    unittest.main()
