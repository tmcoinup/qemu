#!/usr/bin/env python3
"""VMate 的 NUMA/SMT 候选生成与自动管理核预留纯算法。"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class PhysicalCore:
    """同一 package/core_id 下共享执行单元的一组 SMT 线程。"""

    node: int
    package: int
    core_id: int
    threads: tuple[int, ...]


@dataclass(frozen=True)
class Placement:
    """传给 root helper 的逻辑 CPU 优先序与 NUMA 节点优先序。"""

    preference: tuple[int, ...]
    memory_nodes: tuple[int, ...]
    spans_nodes: bool
    has_capacity: bool
    reserve_cores: int


def _free_threads(
    core: PhysicalCore, held: set[int], host_threads_per_core: int
) -> int:
    """返回当前策略可用的逻辑线程数；SMT2 packing 不接受半颗空闲核。"""

    if len(core.threads) != 2 or host_threads_per_core not in (1, 2):
        return 0
    free = sum(thread not in held for thread in core.threads)
    return free if host_threads_per_core == 1 or free == 2 else 0


def _node_capacity(
    cores: list[PhysicalCore], held: set[int], host_threads_per_core: int = 1
) -> dict[int, tuple[int, int]]:
    """返回每个节点可用于单台 VM 的（物理核数，逻辑线程数）。

    host TPC=1 时，同一 VM 的 vCPU 仍分占不同物理核，但不同 VM 可以使用同一
    物理核上互不重复的 SMT sibling。host TPC=2 时只接受两条线程都空闲的核。
    """

    capacity: dict[int, tuple[int, int]] = {}
    for core in cores:
        logical_free = _free_threads(core, held, host_threads_per_core)
        physical_free = int(logical_free >= host_threads_per_core)
        old_physical, old_logical = capacity.get(core.node, (0, 0))
        capacity[core.node] = (
            old_physical + physical_free,
            old_logical + logical_free,
        )
    return capacity


def _core_rank(
    core: PhysicalCore, held_cpus: set[int], host_threads_per_core: int
) -> tuple[bool, bool, tuple[int, ...]]:
    """优先选择完全空闲核；不足时再使用未占用的 SMT sibling。"""

    del host_threads_per_core
    held_count = sum(thread in held_cpus for thread in core.threads)
    return held_count != 0, held_count == 2, core.threads


def choose_placement(
    cores: list[PhysicalCore],
    held_cpus: set[int],
    vcpu_count: int,
    service_cpu_count: int,
    reserve_cores: int,
    guest_threads_per_core: int = 1,
    host_threads_per_core: int | None = None,
) -> Placement:
    """生成单 locality domain 内的 1:1 逻辑 CPU 候选顺序。

    ``reserve_cores`` 从完整 SMT2 池前端扣除。TPC1 候选按每核一条线程分两轮
    输出，root helper 因而能在锁内避开并发占用，同时保证同一 VM 不复用物理核。
    TPC2 则保持每颗核的两个 sibling 相邻，供 2C4T Guest 成组选择。
    """

    host_tpc = guest_threads_per_core \
        if host_threads_per_core is None else host_threads_per_core
    if (
        vcpu_count <= 0
        or service_cpu_count < 0
        or guest_threads_per_core <= 0
        or host_tpc not in (1, 2)
        or vcpu_count % guest_threads_per_core != 0
        or vcpu_count % host_tpc != 0
    ):
        raise ValueError("vCPU/service CPU 数量非法")

    allocatable = [core for core in cores if len(core.threads) == 2]
    reserve = max(0, min(reserve_cores, max(0, len(allocatable) - 1)))
    eligible = allocatable[reserve:]
    if not eligible:
        return Placement((), (), bool(cores), False, reserve)

    required_logical = vcpu_count + service_cpu_count
    required_physical = (
        vcpu_count // host_tpc
        + (service_cpu_count + host_tpc - 1) // host_tpc
    )
    capacity = _node_capacity(eligible, held_cpus, host_tpc)
    total_capacity = _node_capacity(eligible, set(), host_tpc)
    memory_nodes = tuple(
        sorted(
            capacity,
            key=lambda node: (-capacity[node][0], -capacity[node][1], node),
        )
    )
    spans_nodes = not any(
        physical >= required_physical and logical >= required_logical
        for physical, logical in total_capacity.values()
    )
    has_capacity = any(
        physical >= required_physical and logical >= required_logical
        for physical, logical in capacity.values()
    )

    ordered_cores: list[PhysicalCore] = []
    for node in memory_nodes:
        node_cores = [core for core in eligible if core.node == node]
        ordered_cores.extend(sorted(
            node_cores,
            key=lambda core: _core_rank(core, held_cpus, host_tpc),
        ))
    if host_tpc == 1:
        ordered_threads = [
            tuple(sorted(core.threads, key=lambda cpu: cpu in held_cpus))
            for core in ordered_cores
        ]
        preference = tuple(
            threads[lane]
            for lane in range(2)
            for threads in ordered_threads
        )
    else:
        preference = tuple(
            thread for core in ordered_cores for thread in core.threads
        )
    return Placement(preference, memory_nodes, spans_nodes, has_capacity, reserve)


def _auto_reserve(
    cores: list[PhysicalCore],
    held: set[int],
    vcpus: int,
    service_cpus: int,
    guest_threads_per_core: int = 1,
    host_threads_per_core: int | None = None,
) -> int:
    """按完整 SMT2 池固定管理核边界，仅在本次 Guest 无法容纳时收缩。"""

    del held  # 已占集合是瞬时快照，不能让并发 release 改变管理核边界。
    allocatable = [core for core in cores if len(core.threads) == 2]
    default = min(
        max(2, (len(allocatable) + 7) // 8),
        max(0, len(allocatable) - 1),
    )
    host_tpc = guest_threads_per_core \
        if host_threads_per_core is None else host_threads_per_core
    required_physical = (
        vcpus // host_tpc + (service_cpus + host_tpc - 1) // host_tpc
    )
    required_logical = vcpus + service_cpus
    reserve = default
    while reserve > 0:
        capacity = _node_capacity(allocatable[reserve:], set(), host_tpc)
        if any(
            physical >= required_physical and logical >= required_logical
            for physical, logical in capacity.values()
        ):
            break
        reserve -= 1
    return reserve
