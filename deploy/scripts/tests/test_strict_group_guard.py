#!/usr/bin/env python3
"""严格 session guard 的运行时能力探测与空闲开销回归。"""

from __future__ import annotations

import errno
import importlib.util
import pathlib
import signal
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[3]
GUARD_PATH = ROOT / "deploy" / "scripts" / "lib" / "vm-strict-group-guard.py"
SPEC = importlib.util.spec_from_file_location("vm_strict_group_guard", GUARD_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"无法加载 session guard: {GUARD_PATH}")
GUARD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GUARD)


class RuntimePidfdProbeTest(unittest.TestCase):
    """能力探测必须穿过当前内核/seccomp，不能只看 Python API。"""

    def test_pidfd_open_enosys_is_unsupported(self) -> None:
        with mock.patch.object(
            GUARD.os, "pidfd_open", side_effect=OSError(errno.ENOSYS, "old kernel")
        ):
            self.assertFalse(GUARD.runtime_pidfd_supported())

    def test_pidfd_signal_permission_error_is_unsupported_and_closes_fd(self) -> None:
        with mock.patch.object(GUARD.os, "getpid", return_value=123), \
             mock.patch.object(
                 GUARD, "process_identity", return_value=("S", "456", 123, 123)
             ), \
             mock.patch.object(GUARD, "generation_is_live", return_value=True), \
             mock.patch.object(GUARD.os, "pidfd_open", return_value=77), \
             mock.patch.object(GUARD.os, "close") as close_mock, \
             mock.patch.object(
                 GUARD.signal,
                 "pidfd_send_signal",
                 side_effect=PermissionError(errno.EPERM, "seccomp"),
             ):
            self.assertFalse(GUARD.runtime_pidfd_supported())
        close_mock.assert_called_once_with(77)

    def test_success_probe_sends_signal_zero_and_closes_fd(self) -> None:
        with mock.patch.object(GUARD.os, "getpid", return_value=123), \
             mock.patch.object(
                 GUARD, "process_identity", return_value=("S", "456", 123, 123)
             ), \
             mock.patch.object(GUARD, "generation_is_live", return_value=True), \
             mock.patch.object(GUARD.os, "pidfd_open", return_value=77), \
             mock.patch.object(GUARD.os, "close") as close_mock, \
             mock.patch.object(
                 GUARD.signal, "pidfd_send_signal"
             ) as signal_mock:
            self.assertTrue(GUARD.runtime_pidfd_supported())
        signal_mock.assert_called_once_with(77, 0)
        close_mock.assert_called_once_with(77)


class GuardIdleCostTest(unittest.TestCase):
    """正常客机运行期不得按轮询周期全量扫描 /proc。"""

    def test_live_direct_child_skips_group_member_scan(self) -> None:
        instance = GUARD.StrictGroupGuard(900, "100", ["fake-qemu"])
        child = mock.Mock()

        def poll_once() -> None:
            instance.termination = signal.SIGTERM
            return None

        child.poll.side_effect = poll_once
        with mock.patch.object(instance, "_install_handlers"), \
             mock.patch.object(GUARD, "set_parent_death_signal", return_value=True), \
             mock.patch.object(GUARD.os, "getppid", return_value=900), \
             mock.patch.object(GUARD, "generation_is_live", return_value=True), \
             mock.patch.object(GUARD.os, "setsid"), \
             mock.patch.object(instance, "_spawn_sentinel", return_value=True), \
             mock.patch.object(GUARD.subprocess, "Popen", return_value=child), \
             mock.patch.object(GUARD.time, "sleep"), \
             mock.patch.object(instance, "_other_session_members") as scan_mock, \
             mock.patch.object(instance, "_terminate_session", return_value=143):
            self.assertEqual(instance.run(), 143)
        scan_mock.assert_not_called()

    def test_adopted_exited_child_scans_for_surviving_descendants(self) -> None:
        instance = GUARD.StrictGroupGuard(900, "100", ["wrapper"])
        child = mock.Mock()
        child.poll.return_value = 0

        def adopt() -> bool:
            instance.adopted = True
            return True

        with mock.patch.object(instance, "_install_handlers"), \
             mock.patch.object(GUARD, "set_parent_death_signal", return_value=True), \
             mock.patch.object(GUARD.os, "getppid", return_value=900), \
             mock.patch.object(GUARD, "generation_is_live", return_value=True), \
             mock.patch.object(GUARD.os, "setsid"), \
             mock.patch.object(instance, "_spawn_sentinel", side_effect=adopt), \
             mock.patch.object(GUARD.subprocess, "Popen", return_value=child), \
             mock.patch.object(
                 instance, "_other_session_members", return_value=[]
             ) as scan_mock, \
             mock.patch.object(instance, "_disarm_sentinel", return_value=True):
            self.assertEqual(instance.run(), 0)
        scan_mock.assert_called_once_with()


if __name__ == "__main__":
    unittest.main()
