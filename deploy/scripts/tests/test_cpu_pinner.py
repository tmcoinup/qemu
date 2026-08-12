#!/usr/bin/env python3
"""NUMA pinner 的纯算法测试。"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import pathlib
import sys
import tempfile
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


def cpu_core_keys(topology):
    """建立逻辑 CPU 到物理核身份的映射，避免测试依赖 CPU 编号是否连续。"""

    return {
        thread: (item.node, item.package, item.core_id)
        for item in topology
        for thread in item.threads
    }


class CpuPinnerTest(unittest.TestCase):
    def test_diagnostics_never_pollute_strict_status_stdout(self):
        stdout = io.StringIO()
        stderr = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            MODULE.log("diagnostic")
        self.assertEqual(stdout.getvalue(), "")
        self.assertIn("diagnostic", stderr.getvalue())

    def test_expand_linux_cpu_list(self):
        self.assertEqual(MODULE.expand_list("0-2,8,10-11"), [0, 1, 2, 8, 10, 11])

    def test_held_scan_uses_exact_abi4_child_names_without_following_symlinks(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            vmiso = root / "vmiso"
            vmiso.mkdir()
            for name, cpus in (("vm-1", "1"), ("vm-9", "9"), ("vm-10", "10")):
                child = vmiso / name
                child.mkdir()
                (child / "cpuset.cpus").write_text(cpus, encoding="ascii")
            invalid = vmiso / "vm-12junk"
            invalid.mkdir()
            (invalid / "cpuset.cpus").write_text("12", encoding="ascii")
            (vmiso / "vm-2").symlink_to(vmiso / "vm-10", target_is_directory=True)

            held = MODULE.read_held_cpus(123, cgroup_root=root)

        self.assertEqual(held, {1, 9, 10})

    def test_strict_supervisor_is_armed_only_after_topology_preflight(self):
        arguments = MODULE.parse_args([
            "1", "2", "/tmp/vmate-test.qmp", "/bin/true", "0", "1",
            "--status-fd", "1", "--abort-on-failure",
        ])
        topology = [core(0, 0, 0, 2), core(0, 1, 1, 3)]
        with mock.patch.object(MODULE, "discover_topology", return_value=topology), \
             mock.patch.object(MODULE, "query_vcpus", return_value=[]), \
             mock.patch.object(
                 MODULE, "emit_supervisor_status", return_value=True
             ) as status_mock:
            outcome = MODULE.run_pinner(arguments)

        self.assertEqual(outcome.status, 1)
        status_mock.assert_called_once_with(1, "ARMED")

    def test_discovery_filters_offline_smt_sibling(self):
        with tempfile.TemporaryDirectory() as temporary:
            cpu_root = pathlib.Path(temporary) / "cpu"
            node_root = pathlib.Path(temporary) / "node"
            node_root.mkdir(parents=True)
            cpu_root.mkdir()
            (cpu_root / "online").write_text("0\n", encoding="ascii")
            for cpu in (0, 1):
                topology = cpu_root / f"cpu{cpu}" / "topology"
                topology.mkdir(parents=True)
                (topology / "physical_package_id").write_text("0\n")
                (topology / "core_id").write_text("0\n")
                (topology / "thread_siblings_list").write_text("0-1\n")

            discovered = MODULE.discover_topology(cpu_root, node_root)

        self.assertEqual(len(discovered), 1)
        self.assertEqual(discovered[0].threads, (0,))

    def test_prefers_one_numa_node(self):
        topology = [
            core(0, 0, 0, 4), core(0, 1, 1, 5),
            core(1, 0, 2, 6), core(1, 1, 3, 7), core(1, 2, 8, 9),
        ]
        placement = MODULE.choose_placement(topology, set(), 2, 1, 0)

        # 所有 node 都作为 helper 锁内重选时的后备项，但容量最大的 node 必须在前。
        self.assertEqual(placement.memory_nodes, (1, 0))
        self.assertEqual(placement.preference[:3], (2, 3, 8))

    def test_held_cpus_change_node_choice(self):
        topology = [
            core(0, 0, 0, 4), core(0, 1, 1, 5),
            core(1, 0, 2, 6), core(1, 1, 3, 7),
        ]
        placement = MODULE.choose_placement(topology, {0, 1, 4}, 2, 0, 0)

        self.assertEqual(placement.memory_nodes, (1, 0))

    def test_flags_cross_numa_when_no_node_can_fit_guest(self):
        topology = [core(0, 0, 0, 2), core(1, 0, 1, 3)]
        placement = MODULE.choose_placement(topology, set(), 3, 0, 0)

        # 上层看到 spans_nodes 后必须 fail-closed；这里仍保留候选供诊断输出。
        self.assertTrue(placement.spans_nodes)
        self.assertEqual(placement.memory_nodes, (0, 1))
        self.assertEqual(placement.preference, (0, 1, 2, 3))

    def test_keeps_smt_siblings_together(self):
        topology = [
            core(0, 0, 0, 1), core(0, 1, 2, 3), core(0, 2, 4),
        ]
        placement = MODULE.choose_placement(
            topology, set(), 2, 0, 1, guest_threads_per_core=2
        )

        self.assertEqual(placement.preference[:2], (2, 3))

    def test_partial_held_core_exposes_free_sibling_first(self):
        topology = [core(0, 0, 0, 1), core(0, 1, 2, 3)]
        placement = MODULE.choose_placement(topology, {0}, 2, 0, 0)

        # 完全空闲核优先；半占核的空 sibling 与已占线程仍保留为锁内后备。
        self.assertEqual(placement.preference, (2, 1, 3, 0))

    def test_stale_held_snapshot_cannot_hide_newly_released_core(self):
        topology = [core(0, 0, 0, 4), core(0, 1, 1, 5)]
        placement = MODULE.choose_placement(topology, {0, 4}, 2, 0, 0)

        self.assertFalse(placement.spans_nodes)
        self.assertEqual(placement.preference, (1, 0, 5, 4))

    def test_guest_2c4t_maps_to_two_complete_host_smt_cores(self):
        topology = [core(0, index, index, index + 8) for index in range(8)]
        placement = MODULE.choose_placement(
            topology, set(), 4, 0, 0, guest_threads_per_core=2
        )

        selected = placement.preference[:4]
        keys = cpu_core_keys(topology)
        selected_keys = {keys[cpu] for cpu in selected}
        self.assertEqual(selected, (0, 8, 1, 9))
        self.assertEqual(len(selected_keys), 2)
        for item in topology[:2]:
            self.assertEqual(set(item.threads), set(selected) & set(item.threads))

    def test_guest_4c4t_maps_to_four_distinct_host_physical_cores(self):
        topology = [core(0, index, index, index + 8) for index in range(8)]
        placement = MODULE.choose_placement(
            topology, set(), 4, 0, 0,
            guest_threads_per_core=1, host_threads_per_core=1,
        )

        selected = placement.preference[:4]
        keys = cpu_core_keys(topology)
        self.assertEqual(selected, (0, 1, 2, 3))
        self.assertEqual(len({keys[cpu] for cpu in selected}), 4)
        arguments = MODULE.parse_args([
            "1", "4", "/tmp/test.qmp", "/helper", "0", "1", "1",
        ])
        self.assertEqual(
            (arguments.cpus, arguments.guest_threads_per_core,
             arguments.host_threads_per_core),
            (4, 1, 1),
        )

    def test_guest_4c4t_cannot_be_compressed_to_two_host_physical_cores(self):
        arguments = MODULE.parse_args([
            "1", "4", "/tmp/test.qmp", "/helper", "0", "1", "2",
        ])
        with mock.patch.object(MODULE, "discover_topology") as discover_mock:
            outcome = MODULE.run_pinner(arguments)

        self.assertEqual(outcome.status, 2)
        discover_mock.assert_not_called()

    def test_helper_receives_independent_guest_and_host_tpc(self):
        arguments = MODULE.parse_args([
            "1", "4", "/tmp/test.qmp", "/helper", "auto", "1", "1",
        ])
        topology = [core(0, index, index, index + 8) for index in range(5)]
        completed = MODULE.subprocess.CompletedProcess([], 0, "", "")
        with mock.patch.dict(MODULE.os.environ, {"HOST_RESERVE_CORES": "0"}), \
             mock.patch.object(MODULE, "discover_topology", return_value=topology), \
             mock.patch.object(MODULE, "emit_supervisor_status", return_value=True), \
             mock.patch.object(MODULE, "query_vcpus", return_value=[
                 (0, 100), (1, 101), (2, 102), (3, 103),
             ]), mock.patch.object(MODULE, "tgid_of", return_value=123), \
             mock.patch.object(MODULE, "process_starttime", return_value="456"), \
             mock.patch.object(MODULE, "read_held_cpus", return_value=set()), \
             mock.patch.object(
                 MODULE.subprocess, "run", return_value=completed
             ) as helper_mock:
            outcome = MODULE.run_pinner(arguments)

        command = helper_mock.call_args.args[0]
        self.assertEqual((outcome.status, command[7]),
                         (0, "0,1,2,3,4,8,9,10,11,12"))
        self.assertEqual(command[-3:], ["1", "1", "1"])

    def test_auto_service_cpu_falls_back_on_four_core_host(self):
        topology = [core(0, index, index, index + 4) for index in range(4)]
        placement = MODULE.choose_placement(topology, set(), 4, 1, 0, 1, 1)
        fallback = MODULE.choose_placement(topology, set(), 4, 0, 0, 1, 1)
        self.assertFalse(placement.has_capacity)
        self.assertTrue(placement.spans_nodes)
        self.assertTrue(fallback.has_capacity)
        self.assertFalse(fallback.spans_nodes)

    def test_guest_2c2t_vcpus_use_two_distinct_physical_cores(self):
        topology = [core(0, index, index, index + 8) for index in range(8)]
        keys = cpu_core_keys(topology)
        placement = MODULE.choose_placement(
            topology, set(), 2, 0, 0, guest_threads_per_core=1,
            host_threads_per_core=1,
        )
        selected = placement.preference[:2]
        self.assertEqual(len(selected), 2)
        self.assertEqual(len({keys[cpu] for cpu in selected}), 2)

    def test_e5_22c44t_runs_nine_4c4t_guests_without_logical_overlap(self):
        # Xeon E5 v4 常见编号是前半段主线程、后半段 SMT 同胞，不能假设同胞相邻。
        topology = [core(0, index, index, index + 22) for index in range(22)]
        keys = cpu_core_keys(topology)
        held: set[int] = set()
        reserve = MODULE._auto_reserve(
            topology, held, 4, 0,
            guest_threads_per_core=1, host_threads_per_core=1,
        )

        self.assertEqual(reserve, 3)
        for instance in range(9):
            with self.subTest(instance=instance + 1):
                placement = MODULE.choose_placement(
                    topology, held, 4, 0, reserve,
                    guest_threads_per_core=1,
                    host_threads_per_core=1,
                )
                selected = []
                selected_keys = set()
                for cpu in placement.preference:
                    key = keys[cpu]
                    if cpu not in held and key not in selected_keys:
                        selected.append(cpu)
                        selected_keys.add(key)
                    if len(selected) == 4:
                        break
                self.assertEqual(len(selected), 4)
                self.assertEqual(len(selected_keys), 4)
                self.assertTrue(set(selected).isdisjoint(held))
                held.update(selected)

        # 9 台严格占 36 条不同逻辑 CPU；另外 6 条属于 3 个管理核。
        self.assertEqual(len(held), 36)

    def test_e5_single_socket_capacity_follows_profile_topology(self):
        topology = [core(0, index, index, index + 22) for index in range(22)]
        reserve = MODULE._auto_reserve(topology, set(), 4, 0, 2)
        usable_cores = len(topology) - reserve
        usable_threads = usable_cores * 2

        self.assertEqual((reserve, usable_cores), (3, 19))
        self.assertEqual(usable_threads // 2, 19)  # 2C2T
        self.assertEqual(usable_cores // 2, 9)  # 2C4T
        self.assertEqual(usable_threads // 4, 9)  # 4C4T
        self.assertEqual((usable_threads // 3, usable_threads // 5), (12, 7))

    def test_dual_socket_and_cod_capacity_are_counted_per_domain(self):
        def remaining_by_node(topology, reserve):
            result = {}
            for item in topology[reserve:]:
                result[item.node] = result.get(item.node, 0) + 1
            return list(result.values())

        def can_place(capacities, guests, cores_per_guest=2):
            remaining = list(capacities)
            for _guest in range(guests):
                index = max(range(len(remaining)), key=remaining.__getitem__)
                if remaining[index] < cores_per_guest:
                    return False
                remaining[index] -= cores_per_guest
            return True

        dual = [
            core(node, index, node * 22 + index, node * 22 + index + 44)
            for node in range(2) for index in range(22)
        ]
        cod = [
            core(node, index, node * 11 + index, node * 11 + index + 44)
            for node in range(4) for index in range(11)
        ]
        dual_reserve = MODULE._auto_reserve(dual, set(), 4, 0, 1)
        cod_reserve = MODULE._auto_reserve(cod, set(), 4, 0, 1)

        self.assertEqual((dual_reserve, cod_reserve), (6, 6))
        dual_capacity = remaining_by_node(dual, dual_reserve)
        cod_capacity = remaining_by_node(cod, cod_reserve)
        self.assertEqual((dual_capacity, cod_capacity), ([16, 22], [5, 11, 11, 11]))
        self.assertEqual((sum(dual_capacity), sum(cod_capacity)), (38, 38))
        self.assertEqual((sum(item // 2 for item in dual_capacity),
                          sum(item // 2 for item in cod_capacity)), (19, 17))
        dual_logical = [item * 2 for item in dual_capacity]
        cod_logical = [item * 2 for item in cod_capacity]
        self.assertEqual((sum(item // 4 for item in dual_logical),
                          sum(item // 4 for item in cod_logical)), (19, 17))
        self.assertTrue(can_place(dual_logical, 8, 4))
        self.assertTrue(can_place(cod_logical, 8, 4))

    def test_multi_numa_guest_candidate_prefix_never_crosses_node(self):
        topology = [
            *(core(0, index, index, index + 16) for index in range(4)),
            *(core(1, index, index + 4, index + 20) for index in range(6)),
        ]
        keys = cpu_core_keys(topology)
        placement = MODULE.choose_placement(
            topology, set(), 4, 0, 0, guest_threads_per_core=2
        )

        selected = placement.preference[:4]
        selected_nodes = {keys[cpu][0] for cpu in selected}
        self.assertEqual(placement.memory_nodes, (1, 0))
        self.assertEqual(selected_nodes, {1})

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
        with mock.patch.object(
                 MODULE, "run_pinner", return_value=MODULE.PinOutcome(1)
             ), \
             mock.patch.object(MODULE, "ignore_lifecycle_signals"), \
             mock.patch.object(MODULE, "request_qmp_quit", return_value=True) as quit_mock, \
             mock.patch.object(MODULE, "release_instance", return_value=True) as release_mock:
            self.assertEqual(MODULE.main(arguments), 1)
            quit_mock.assert_called_once_with(
                "/tmp/vmate-test.qmp", timeout=0.5
            )
            release_mock.assert_called_once_with("/bin/true", "1")

    def test_strict_unexpected_apply_exception_still_attempts_idempotent_release(self):
        arguments = [
            "1", "4", "/tmp/vmate-test.qmp", "/bin/true", "0",
            "--abort-on-failure",
        ]
        with mock.patch.object(
                 MODULE, "run_pinner", side_effect=RuntimeError("after apply")
             ), \
             mock.patch.object(MODULE, "ignore_lifecycle_signals"), \
             mock.patch.object(MODULE, "request_qmp_quit", return_value=False), \
             mock.patch.object(MODULE, "release_instance", return_value=False) as release_mock:
            self.assertEqual(MODULE.main(arguments), 1)
            release_mock.assert_called_once_with("/bin/true", "1")

    def test_supervised_unowned_failure_never_quits_or_signals_foreign_qemu(self):
        arguments = [
            "1", "4", "/tmp/vmate-test.qmp", "/bin/true", "0",
            "--status-fd", "1", "--abort-on-failure",
        ]
        with mock.patch.object(
                 MODULE, "run_pinner", return_value=MODULE.PinOutcome(1)
             ), mock.patch.object(MODULE, "ignore_lifecycle_signals"), \
             mock.patch.object(MODULE, "emit_supervisor_status", return_value=True), \
             mock.patch.object(MODULE, "request_qmp_quit") as quit_mock, \
             mock.patch.object(MODULE, "stop_bound_qemu") as stop_mock, \
             mock.patch.object(MODULE, "release_instance", return_value=True):
            self.assertEqual(MODULE.main(arguments), 1)
        quit_mock.assert_not_called()
        stop_mock.assert_not_called()

    def test_strict_bound_failure_stops_then_releases_possible_partial_state(self):
        arguments = [
            "1", "4", "/tmp/vmate-test.qmp", "/bin/true", "0",
            "--abort-on-failure",
        ]
        outcome = MODULE.PinOutcome(1, 123, "456")
        order = []
        with mock.patch.object(MODULE, "run_pinner", return_value=outcome), \
             mock.patch.object(MODULE, "ignore_lifecycle_signals"), \
             mock.patch.object(
                 MODULE, "stop_bound_qemu",
                 side_effect=lambda *_args: order.append("stop") or True,
             ), mock.patch.object(
                 MODULE, "release_instance",
                 side_effect=lambda *_args: order.append("release") or True,
             ):
            self.assertEqual(MODULE.main(arguments), 1)
        self.assertEqual(order, ["stop", "release"])

    def test_strict_success_resumes_only_after_helper_success(self):
        arguments = [
            "1", "4", "/tmp/vmate-test.qmp", "/bin/true", "0", "2",
            "--abort-on-failure",
        ]
        outcome = MODULE.PinOutcome(0, 123, "456", True)
        with mock.patch.object(MODULE, "run_pinner", return_value=outcome), \
             mock.patch.object(
                 MODULE, "request_qmp_command", return_value=True
             ) as command_mock, \
             mock.patch.object(MODULE, "ignore_lifecycle_signals"), \
             mock.patch.object(
                 MODULE, "watch_and_release", return_value=True
             ) as watch_mock:
            self.assertEqual(MODULE.main(arguments), 0)
            command_mock.assert_called_once_with(
                "/tmp/vmate-test.qmp", "cont", 123, "456"
            )
            watch_mock.assert_called_once_with("/bin/true", "1", 123, "456")

    def test_strict_cont_failure_closes_paused_guest(self):
        arguments = [
            "1", "4", "/tmp/vmate-test.qmp", "/bin/true", "0", "2",
            "--abort-on-failure",
        ]
        outcome = MODULE.PinOutcome(0, 123, "456", True)
        with mock.patch.object(MODULE, "run_pinner", return_value=outcome), \
             mock.patch.object(MODULE, "request_qmp_command", return_value=False), \
             mock.patch.object(
                 MODULE, "cleanup_applied_failure", return_value=True
             ) as cleanup_mock, \
             mock.patch.object(MODULE, "ignore_lifecycle_signals"), \
             mock.patch.object(MODULE, "watch_and_release") as watch_mock:
            self.assertEqual(MODULE.main(arguments), 1)
            cleanup_mock.assert_called_once_with(
                "/tmp/vmate-test.qmp", "/bin/true", "1", 123, "456"
            )
            watch_mock.assert_not_called()

    def test_compat_runtime_failure_does_not_stop_guest(self):
        arguments = ["1", "4", "/tmp/vmate-test.qmp", "/bin/true", "0"]
        with mock.patch.object(
                 MODULE, "run_pinner", return_value=MODULE.PinOutcome(1)
             ), \
             mock.patch.object(MODULE, "ignore_lifecycle_signals"), \
             mock.patch.object(MODULE, "request_qmp_quit") as quit_mock:
            self.assertEqual(MODULE.main(arguments), 1)
            quit_mock.assert_not_called()

    def test_compat_success_still_watches_and_releases_partition(self):
        arguments = ["1", "4", "/tmp/vmate-test.qmp", "/bin/true", "0"]
        outcome = MODULE.PinOutcome(0, 123, "456", True)
        with mock.patch.object(MODULE, "run_pinner", return_value=outcome), \
             mock.patch.object(MODULE, "ignore_lifecycle_signals"), \
             mock.patch.object(
                 MODULE, "watch_and_release", return_value=True
             ) as watch_mock, \
             mock.patch.object(MODULE, "request_qmp_command") as command_mock:
            self.assertEqual(MODULE.main(arguments), 0)
            command_mock.assert_not_called()
            watch_mock.assert_called_once_with("/bin/true", "1", 123, "456")


if __name__ == "__main__":
    unittest.main()
