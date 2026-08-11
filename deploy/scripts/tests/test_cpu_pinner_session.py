#!/usr/bin/env python3
"""严格 pinner 的 session 所有权与内层进程组兼容性测试。"""

from __future__ import annotations

import unittest
from unittest import mock

from test_cpu_pinner import MODULE, core


class CpuPinnerSessionTest(unittest.TestCase):
    def _arguments(self):
        return MODULE.parse_args([
            "1", "2", "/tmp/vmate-test.qmp", "/bin/true", "0", "1",
            "--launcher-pid", "999", "--launcher-starttime", "111",
            "--launcher-sid", "999", "--status-fd", "1",
            "--abort-on-failure",
        ])

    def test_foreign_qmp_session_is_never_returned_as_owned_pid(self):
        topology = [core(0, 0, 0, 2), core(0, 1, 1, 3)]
        with mock.patch.object(MODULE, "discover_topology", return_value=topology), \
             mock.patch.object(MODULE, "emit_supervisor_status", return_value=True), \
             mock.patch.object(
                 MODULE, "query_vcpus", return_value=[(0, 100), (1, 101)]
             ), \
             mock.patch.object(MODULE, "tgid_of", return_value=123), \
             mock.patch.object(MODULE, "process_starttime", return_value="456"), \
             mock.patch.object(MODULE, "process_matches", return_value=True), \
             mock.patch.object(
                 MODULE,
                 "process_sid",
                 side_effect=lambda pid: 999 if pid == 999 else 888,
             ), \
             mock.patch.object(MODULE.subprocess, "run") as helper_mock:
            outcome = MODULE.run_pinner(self._arguments())

        self.assertEqual((outcome.status, outcome.pid), (1, None))
        helper_mock.assert_not_called()

    def test_qemu_nested_process_group_in_guard_session_is_owned(self):
        topology = [core(0, 0, 0, 2), core(0, 1, 1, 3)]
        completed = MODULE.subprocess.CompletedProcess([], 0, "", "")
        with mock.patch.dict(MODULE.os.environ, {"HOST_RESERVE_CORES": "0"}), \
             mock.patch.object(MODULE, "discover_topology", return_value=topology), \
             mock.patch.object(MODULE, "emit_supervisor_status", return_value=True), \
             mock.patch.object(
                 MODULE, "query_vcpus", return_value=[(0, 100), (1, 101)]
             ), \
             mock.patch.object(MODULE, "tgid_of", return_value=123), \
             mock.patch.object(MODULE, "process_starttime", return_value="456"), \
             mock.patch.object(MODULE, "process_matches", return_value=True), \
             mock.patch.object(MODULE, "process_sid", return_value=999), \
             mock.patch.object(MODULE, "read_held_cpus", return_value=set()), \
             mock.patch.object(
                 MODULE.subprocess, "run", return_value=completed
             ) as helper_mock:
            outcome = MODULE.run_pinner(self._arguments())

        self.assertEqual((outcome.status, outcome.pid), (0, 123))
        helper_mock.assert_called_once()


if __name__ == "__main__":
    unittest.main()
