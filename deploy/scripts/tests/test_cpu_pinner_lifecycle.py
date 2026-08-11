#!/usr/bin/env python3
"""CPU pinner 的 QMP 丢响应、PID 代际与自动 release 回归测试。"""

from __future__ import annotations

import contextlib
import io
import json
import pathlib
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[3]
SCRIPT_DIR = ROOT / "deploy" / "scripts"
sys.path.insert(0, str(SCRIPT_DIR))
import vm_cpu_pinner_lifecycle as LIFECYCLE  # noqa: E402


class FakeQmpServer:
    """只实现 pinner 所需命令，并可模拟命令生效但响应丢失。"""

    def __init__(
        self,
        path: pathlib.Path,
        qemu: subprocess.Popen[bytes],
        *,
        drop_cont_response: bool = False,
        drop_quit_response: bool = False,
    ) -> None:
        self.path = path
        self.qemu = qemu
        self.drop_cont_response = drop_cont_response
        self.drop_quit_response = drop_quit_response
        self.status = "prelaunch"
        self.cont_count = 0
        self.quit_count = 0
        self._dropped_cont = False
        self._stop = threading.Event()
        self._ready = threading.Event()
        self._thread = threading.Thread(target=self._serve, daemon=True)

    def start(self) -> None:
        self._thread.start()
        if not self._ready.wait(2):
            raise RuntimeError("fake QMP 未就绪")

    def stop(self) -> None:
        self._stop.set()
        self._thread.join(timeout=2)
        self.path.unlink(missing_ok=True)

    @staticmethod
    def _reply(stream, ident: str, value) -> None:
        stream.write(json.dumps({"return": value, "id": ident}) + "\n")
        stream.flush()

    def _handle(self, connection: socket.socket) -> None:
        stream = connection.makefile("rw", encoding="utf-8")
        stream.write(json.dumps({"QMP": {"version": {}}}) + "\n")
        stream.flush()
        while not self._stop.is_set():
            line = stream.readline()
            if not line:
                return
            request = json.loads(line)
            command = request["execute"]
            ident = request["id"]
            if command == "qmp_capabilities":
                self._reply(stream, ident, {})
            elif command == "query-cpus-fast":
                self._reply(stream, ident, [
                    {"cpu-index": 0, "thread-id": self.qemu.pid},
                ])
            elif command == "query-status":
                self._reply(stream, ident, {"status": self.status})
            elif command == "cont":
                self.status = "running"
                self.cont_count += 1
                if self.drop_cont_response and not self._dropped_cont:
                    self._dropped_cont = True
                    return
                self._reply(stream, ident, {})
            elif command == "quit":
                self.quit_count += 1
                self.qemu.terminate()
                self.qemu.wait(timeout=2)
                self._stop.set()
                if self.drop_quit_response:
                    return
                self._reply(stream, ident, {})

    def _serve(self) -> None:
        self.path.unlink(missing_ok=True)
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            listener.bind(str(self.path))
            listener.listen(4)
            listener.settimeout(0.1)
            self._ready.set()
            while not self._stop.is_set():
                try:
                    connection, _address = listener.accept()
                except TimeoutError:
                    continue
                try:
                    self._handle(connection)
                except (BrokenPipeError, ConnectionError, OSError, ValueError):
                    pass
                finally:
                    connection.close()
        finally:
            listener.close()
            self.path.unlink(missing_ok=True)


class CpuPinnerLifecycleTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.socket_path = pathlib.Path(self.temporary.name) / "qmp.sock"
        self.processes: list[subprocess.Popen[bytes]] = []
        self.servers: list[FakeQmpServer] = []

    def tearDown(self) -> None:
        for server in self.servers:
            server.stop()
        for process in self.processes:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=2)
        self.temporary.cleanup()

    def start_process(self) -> subprocess.Popen[bytes]:
        process = subprocess.Popen(
            ["sleep", "30"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        self.processes.append(process)
        return process

    def start_server(self, process, **options) -> FakeQmpServer:
        server = FakeQmpServer(self.socket_path, process, **options)
        self.servers.append(server)
        server.start()
        return server

    def test_lifecycle_diagnostics_never_pollute_status_stdout(self) -> None:
        stdout = io.StringIO()
        stderr = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            LIFECYCLE.log("lifecycle diagnostic")
        self.assertEqual(stdout.getvalue(), "")
        self.assertIn("lifecycle diagnostic", stderr.getvalue())

    def test_cont_response_loss_recovers_via_query_status(self) -> None:
        process = self.start_process()
        server = self.start_server(process, drop_cont_response=True)
        starttime = LIFECYCLE.process_starttime(process.pid)

        resumed = LIFECYCLE.request_qmp_command(
            str(self.socket_path), "cont", process.pid, starttime, timeout=3,
        )

        self.assertTrue(resumed)
        self.assertEqual(server.status, "running")
        self.assertEqual(server.cont_count, 1)
        self.assertIsNone(process.poll())

    def test_quit_socket_disappearance_is_success_after_bound_process_exits(self) -> None:
        process = self.start_process()
        server = self.start_server(process, drop_quit_response=True)
        starttime = LIFECYCLE.process_starttime(process.pid)

        stopped = LIFECYCLE.request_qmp_quit(
            str(self.socket_path), process.pid, starttime, timeout=3,
        )

        self.assertTrue(stopped)
        self.assertEqual(server.quit_count, 1)
        self.assertIsNotNone(process.poll())

    def test_qmp_async_event_flood_still_has_absolute_command_deadline(self) -> None:
        session = LIFECYCLE._QmpSession("unused", timeout=0.02)
        session.client = mock.Mock()
        session.stream = mock.Mock()
        with mock.patch.object(
            session, "_read_json", return_value={"event": "SPAM"}
        ):
            started = time.monotonic()
            with self.assertRaises(TimeoutError):
                session.execute("query-status")
        self.assertLess(time.monotonic() - started, 0.5)

    def test_pid_starttime_mismatch_never_sends_signal(self) -> None:
        process = self.start_process()
        with mock.patch.object(LIFECYCLE, "request_qmp_quit"), \
             mock.patch.object(
                 LIFECYCLE.signal, "pidfd_send_signal"
             ) as signal_mock:
            self.assertTrue(LIFECYCLE.stop_bound_qemu(
                str(self.socket_path), process.pid, "wrong-generation"
            ))
        signal_mock.assert_not_called()

    def test_pidfd_rechecks_generation_after_open_before_signal(self) -> None:
        with mock.patch.object(LIFECYCLE.os, "pidfd_open", return_value=77), \
             mock.patch.object(LIFECYCLE.os, "close"), \
             mock.patch.object(LIFECYCLE, "process_matches", return_value=False), \
             mock.patch.object(
                 LIFECYCLE.signal, "pidfd_send_signal"
             ) as signal_mock:
            self.assertTrue(LIFECYCLE._send_bound_signal(
                123, "old-generation", LIFECYCLE.signal.SIGTERM
            ))
        signal_mock.assert_not_called()

    def test_zombie_is_exit_for_identity_and_pidfd_wait(self) -> None:
        process = subprocess.Popen(["sleep", "0.05"])
        self.processes.append(process)
        starttime = LIFECYCLE.process_starttime(process.pid)
        time.sleep(0.1)

        identity = LIFECYCLE._process_state_and_starttime(process.pid)
        self.assertIsNotNone(identity)
        self.assertEqual(identity[0], "Z")
        self.assertFalse(LIFECYCLE.process_matches(process.pid, starttime))
        self.assertTrue(LIFECYCLE._wait_until_gone(process.pid, starttime, 0.1))

    def test_orphan_grace_can_still_bind_delayed_wrapper_child(self) -> None:
        process = self.start_process()
        self.start_server(process)

        vcpus = LIFECYCLE.query_vcpus(
            str(self.socket_path), 1, timeout=1,
            launcher_pid=999_999_999, launcher_starttime="1", orphan_grace=0.2,
        )

        self.assertEqual(vcpus, [(0, process.pid)])

    def test_orphan_grace_is_bounded_when_no_qemu_survives(self) -> None:
        started = time.monotonic()
        vcpus = LIFECYCLE.query_vcpus(
            str(self.socket_path), 1, timeout=5,
            launcher_pid=999_999_999, launcher_starttime="1", orphan_grace=0.05,
        )
        elapsed = time.monotonic() - started

        self.assertEqual(vcpus, [])
        self.assertLess(elapsed, 0.5)

    def test_failed_post_apply_cleanup_stops_before_release(self) -> None:
        order: list[str] = []
        with mock.patch.object(
                 LIFECYCLE, "stop_bound_qemu",
                 side_effect=lambda *_args: order.append("stop") or True,
             ), mock.patch.object(
                 LIFECYCLE, "release_instance",
                 side_effect=lambda *_args: order.append("release") or True,
             ):
            result = LIFECYCLE.cleanup_applied_failure(
                str(self.socket_path), "/helper", "1", 123, "456"
            )
        self.assertTrue(result)
        self.assertEqual(order, ["stop", "release"])

    def test_watchdog_releases_after_process_disappears(self) -> None:
        process = subprocess.Popen(["sleep", "0.05"])
        self.processes.append(process)
        starttime = LIFECYCLE.process_starttime(process.pid)
        reaper = threading.Thread(target=process.wait)
        reaper.start()
        with mock.patch.object(LIFECYCLE, "ignore_lifecycle_signals"), \
             mock.patch.object(
                 LIFECYCLE, "release_instance", return_value=True
             ) as release_mock:
            self.assertTrue(LIFECYCLE.watch_and_release(
                "/helper", "1", process.pid, starttime
            ))
        reaper.join(timeout=2)
        release_mock.assert_called_once_with("/helper", "1")

    def test_release_never_hard_kills_helper_waiting_for_global_lock(self) -> None:
        completed = subprocess.CompletedProcess([], 0, stdout="", stderr="")
        with mock.patch.object(
            LIFECYCLE.subprocess, "run", return_value=completed
        ) as run_mock:
            self.assertTrue(LIFECYCLE.release_instance("/helper", "1"))
        self.assertNotIn("timeout", run_mock.call_args.kwargs)

    def test_shell_wrapper_keeps_instance_lock_for_watchdog(self) -> None:
        wrapper = (SCRIPT_DIR / "lib" / "sv-cpupin.sh").read_text()
        self.assertNotIn("python3 8>&-", wrapper)
        self.assertIn('python3 "$pinner"', wrapper)
        self.assertIn('python3 "$pinner" --help', wrapper)
        self.assertIn('--launcher-sid "$launcher_sid" --status-fd 1', wrapper)
        self.assertIn('sv_cpu_isolate_supervise()', wrapper)


if __name__ == "__main__":
    unittest.main()
