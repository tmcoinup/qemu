#!/usr/bin/env python3
"""host-passthrough 宿主事实的多实例稳定性测试。"""

from __future__ import annotations

import pathlib
import sys
import tempfile
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[3]
SCRIPTS = ROOT / "deploy" / "scripts"
sys.path.insert(0, str(SCRIPTS))
import host_platform_probe as probe  # noqa: E402


class HostPlatformProbeTest(unittest.TestCase):
    """验证 VM cpuset 不会污染后续实例的整机身份。"""

    def test_kernel_online_count_ignores_shrunk_process_affinity(self):
        with tempfile.TemporaryDirectory() as temporary:
            online = pathlib.Path(temporary) / "online"
            online.write_text("0-11\n", encoding="ascii")
            # 中文注释：模拟 VM1 已摘走两个 SMT2 核，VM2 的 clone 进程只剩
            # 8 个可调度线程；profile 仍必须绑定稳定的整机 12 线程事实。
            with mock.patch.dict(
                probe.os.environ, {"STEALTH_HOST_PROBE_TEST_MODE": "0"}
            ), mock.patch.object(
                probe.os, "sched_getaffinity", return_value=set(range(8)), create=True
            ) as affinity:
                detected = probe.detect_online_threads(online)

        self.assertEqual(detected, 12)
        affinity.assert_not_called()

    def test_discontiguous_online_cpu_list_counts_unique_threads(self):
        self.assertEqual(
            probe.parse_linux_cpu_list_count("0-3,8,10-11", "fixture"),
            7,
        )

    def test_malformed_or_overlapping_online_cpu_list_fails_closed(self):
        for value in ("", "0-3,3-4", "4-2", "0,x"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                probe.parse_linux_cpu_list_count(value, "fixture")


if __name__ == "__main__":
    unittest.main()
