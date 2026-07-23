#!/usr/bin/env python3
"""CPU pinner 对宿主完整 SMT2 物理核的硬件契约测试。"""

from __future__ import annotations

import pathlib
import sys
import unittest
from unittest import mock


TEST_DIR = pathlib.Path(__file__).resolve().parent
if str(TEST_DIR) not in sys.path:
    sys.path.insert(0, str(TEST_DIR))

from test_cpu_pinner import MODULE, core  # noqa: E402


PROFILES = (
    (2, 1, 1),  # 2C2T Guest：每颗 host SMT2 核只放一个 vCPU。
    (4, 2, 2),  # 2C4T Guest：两个 vCPU 共用一颗 host SMT2 核。
    (4, 1, 1),  # 4C4T Guest：四个 vCPU 分占四颗 host 物理核。
)


def topology_with_smt_width(width: int):
    """构造四颗物理核，逻辑 CPU 编号故意不相邻。"""

    return [
        core(0, index, *(index + lane * 8 for lane in range(width)))
        for index in range(4)
    ]


class CpuPinnerHostContractTest(unittest.TestCase):
    def test_hybrid_host_reserves_from_allocatable_smt2_pool(self):
        # 14700F：前 8 颗 P-core 为 SMT2，后 12 颗 E-core 为 SMT1。
        topology = [
            *(core(0, index, index * 2, index * 2 + 1) for index in range(8)),
            *(core(0, index + 8, index + 16) for index in range(12)),
        ]
        # VM1 已占 P3/P4；VM2 的 4C4T 仍应能使用 P2/P5/P6/P7。
        held = {6, 7, 8, 9}
        reserve = MODULE._auto_reserve(
            topology, held, 4, 0,
            guest_threads_per_core=1, host_threads_per_core=1,
        )
        placement = MODULE.choose_placement(
            topology, held, 4, 0, reserve,
            guest_threads_per_core=1, host_threads_per_core=1,
        )

        self.assertEqual(reserve, 2)
        self.assertEqual(placement.preference[:4], (4, 10, 12, 14))
        self.assertEqual(len(placement.preference), 12)
        self.assertTrue(set(placement.preference).isdisjoint(range(16, 28)))

    def test_e5_capacity_depends_on_guest_topology(self):
        topology = [core(0, index, index, index + 22) for index in range(22)]
        cpu_to_core = {
            cpu: item for item in topology for cpu in item.threads
        }

        def accepted_guests(profile: tuple[int, int, int]) -> tuple[int, int]:
            vcpus, guest_tpc, host_tpc = profile
            held: set[int] = set()
            accepted = 0
            for _attempt in range(24):
                placement = MODULE.choose_placement(
                    topology, held, vcpus, 0, 3,
                    guest_threads_per_core=guest_tpc,
                    host_threads_per_core=host_tpc,
                )
                pinned = []
                chosen = set()
                for start in range(0, len(placement.preference), host_tpc):
                    group = placement.preference[start:start + host_tpc]
                    item = cpu_to_core[group[0]]
                    if item in chosen or any(cpu in held for cpu in group):
                        continue
                    pinned.extend(group)
                    chosen.add(item)
                    if len(pinned) == vcpus:
                        break
                if len(pinned) != vcpus:
                    break
                self.assertEqual(len(chosen), vcpus // host_tpc)
                held.update(pinned)
                accepted += 1
            return accepted, len(held)

        self.assertEqual(accepted_guests(PROFILES[0]), (19, 38))
        self.assertEqual(accepted_guests(PROFILES[1]), (9, 36))
        self.assertEqual(accepted_guests(PROFILES[2]), (9, 36))

    def test_capacity_and_candidates_reject_smt1_and_smt4(self):
        for width in (1, 4):
            topology = topology_with_smt_width(width)
            for vcpus, guest_tpc, host_tpc in PROFILES:
                with self.subTest(width=width, profile=(vcpus, guest_tpc, host_tpc)):
                    capacity = MODULE._node_capacity(topology, set(), host_tpc)
                    placement = MODULE.choose_placement(
                        topology, set(), vcpus, 0, 0,
                        guest_threads_per_core=guest_tpc,
                        host_threads_per_core=host_tpc,
                    )
                    self.assertEqual(capacity, {0: (0, 0)})
                    self.assertEqual(placement.preference, ())
                    self.assertTrue(placement.spans_nodes)

    def test_strict_preflight_rejects_smt1_and_smt4_before_qmp(self):
        for width in (1, 4):
            topology = topology_with_smt_width(width)
            for vcpus, guest_tpc, host_tpc in PROFILES:
                with self.subTest(width=width, profile=(vcpus, guest_tpc, host_tpc)):
                    arguments = MODULE.parse_args([
                        "1", str(vcpus), "/tmp/test.qmp", "/helper", "0",
                        str(guest_tpc), str(host_tpc), "--abort-on-failure",
                    ])
                    with mock.patch.object(
                        MODULE, "discover_topology", return_value=topology,
                    ), mock.patch.object(MODULE, "query_vcpus") as query_mock, \
                         mock.patch.object(
                             MODULE, "emit_supervisor_status"
                         ) as status_mock:
                        outcome = MODULE.run_pinner(arguments)

                    self.assertEqual(outcome.status, 1)
                    query_mock.assert_not_called()
                    status_mock.assert_not_called()


if __name__ == "__main__":
    unittest.main()
