#!/usr/bin/env python3
"""NUMA pinner 的纯算法测试。"""

from __future__ import annotations

import importlib.util
import pathlib
import sys
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[3]
MODULE_PATH = ROOT / "deploy" / "scripts" / "vm-cpu-pinner.py"
SPEC = importlib.util.spec_from_file_location("vm_cpu_pinner", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"无法加载 {MODULE_PATH}")
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def core(node: int, core_id: int, *threads: int):
    return MODULE.PhysicalCore(node, node, core_id, tuple(threads))


class CpuPinnerTest(unittest.TestCase):
    def test_expand_linux_cpu_list(self):
        self.assertEqual(MODULE.expand_list("0-2,8,10-11"), [0, 1, 2, 8, 10, 11])

    def test_prefers_one_numa_node(self):
        topology = [
            core(0, 0, 0, 4), core(0, 1, 1, 5),
            core(1, 0, 2, 6), core(1, 1, 3, 7), core(1, 2, 8, 9),
        ]
        placement = MODULE.choose_placement(topology, set(), 2, 1, 0)

        self.assertEqual(placement.memory_nodes, (1,))
        self.assertFalse(placement.spans_nodes)
        self.assertEqual(placement.preference[:3], (2, 3, 8))

    def test_held_cpus_change_node_choice(self):
        topology = [
            core(0, 0, 0, 4), core(0, 1, 1, 5),
            core(1, 0, 2, 6), core(1, 1, 3, 7),
        ]
        placement = MODULE.choose_placement(topology, {0, 1, 4}, 2, 0, 0)

        self.assertEqual(placement.memory_nodes, (1,))

    def test_spans_nodes_only_when_required(self):
        topology = [core(0, 0, 0, 2), core(1, 0, 1, 3)]
        placement = MODULE.choose_placement(topology, set(), 3, 0, 0)

        self.assertTrue(placement.spans_nodes)
        self.assertEqual(placement.memory_nodes, (0, 1))
        self.assertEqual(placement.preference, (0, 1, 2, 3))

    def test_reserve_removes_management_core(self):
        topology = [core(0, 0, 0, 4), core(0, 1, 1, 5), core(0, 2, 2, 6)]
        placement = MODULE.choose_placement(topology, set(), 2, 0, 1)

        self.assertNotIn(0, placement.preference)
        self.assertNotIn(4, placement.preference)
        self.assertEqual(placement.reserve_cores, 1)

    def test_strict_runtime_failure_requests_qmp_quit(self):
        arguments = [
            "1", "4", "/tmp/vmate-test.qmp", "/bin/true", "0",
            "--abort-on-failure",
        ]
        with mock.patch.object(MODULE, "run_pinner", return_value=1), \
             mock.patch.object(MODULE, "request_qmp_quit", return_value=True) as quit_mock:
            self.assertEqual(MODULE.main(arguments), 1)
            quit_mock.assert_called_once_with("/tmp/vmate-test.qmp")

    def test_compat_runtime_failure_does_not_stop_guest(self):
        arguments = ["1", "4", "/tmp/vmate-test.qmp", "/bin/true", "0"]
        with mock.patch.object(MODULE, "run_pinner", return_value=1), \
             mock.patch.object(MODULE, "request_qmp_quit") as quit_mock:
            self.assertEqual(MODULE.main(arguments), 1)
            quit_mock.assert_not_called()


if __name__ == "__main__":
    unittest.main()
