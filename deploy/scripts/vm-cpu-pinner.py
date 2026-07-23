#!/usr/bin/env python3
"""NUMA-aware QMP vCPU pinner；拓扑算法保持纯函数以便无 root 测试。"""

from __future__ import annotations

import argparse
import os
import pathlib
import re
import subprocess
import sys
from dataclasses import dataclass

SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from vm_cpu_pinner_lifecycle import (  # noqa: E402
    cleanup_applied_failure,
    emit_supervisor_status,
    ignore_lifecycle_signals, log, process_matches,
    process_pgid, process_starttime, query_vcpus,
    release_instance,
    request_qmp_command, request_qmp_quit,
    stop_bound_qemu,
    tgid_of,
    watch_and_release,
)
from vm_cpu_placement import (  # noqa: E402
    PhysicalCore, Placement, _auto_reserve, _node_capacity, choose_placement,
)


CPU_NAME_RE = re.compile(r"^cpu([0-9]+)$")
VM_CHILD_RE = re.compile(r"^vm-[1-9][0-9]{0,9}$")


@dataclass(frozen=True)
class PinOutcome:
    """helper 调用结果及其绑定的 QEMU PID 代际。"""

    status: int
    pid: int | None = None
    starttime: str | None = None
    applied: bool = False


def expand_list(value: str) -> list[int]:
    """展开 Linux cpulist/nodelist，例如 ``0-3,8``。"""

    output: list[int] = []
    for raw_part in value.strip().split(","):
        part = raw_part.strip()
        if not part:
            continue
        if "-" in part:
            start_text, end_text = part.split("-", 1)
            start, end = int(start_text), int(end_text)
            if start > end:
                raise ValueError(f"倒序范围: {part}")
            output.extend(range(start, end + 1))
        else:
            output.append(int(part))
    return sorted(set(output))


def _read_int(path: pathlib.Path, default: int) -> int:
    try:
        return int(path.read_text(encoding="ascii").strip())
    except (OSError, ValueError):
        return default


def _cpu_node(cpu_dir: pathlib.Path, node_root: pathlib.Path, cpu: int) -> int:
    # 新内核通常在 cpuN 下放 nodeN 符号链接；某些服务器只在 nodeN/cpuN 暴露。
    for entry in cpu_dir.glob("node[0-9]*"):
        suffix = entry.name.removeprefix("node")
        if suffix.isdigit():
            return int(suffix)
    for entry in node_root.glob("node[0-9]*"):
        if (entry / f"cpu{cpu}").exists():
            suffix = entry.name.removeprefix("node")
            if suffix.isdigit():
                return int(suffix)
    return 0


def discover_topology(
    cpu_root: pathlib.Path = pathlib.Path("/sys/devices/system/cpu"),
    node_root: pathlib.Path = pathlib.Path("/sys/devices/system/node"),
) -> list[PhysicalCore]:
    """从 sysfs 构造按 NUMA/package/core 分组的物理核列表。"""

    groups: dict[tuple[int, int, int], set[int]] = {}
    try:
        online_cpus = set(
            expand_list((cpu_root / "online").read_text(encoding="ascii"))
        )
        entries = list(cpu_root.iterdir())
    except (OSError, ValueError):
        return []
    if not online_cpus:
        return []

    for cpu_dir in entries:
        match = CPU_NAME_RE.match(cpu_dir.name)
        if match is None:
            continue
        cpu = int(match.group(1))
        if cpu not in online_cpus:
            continue
        topology = cpu_dir / "topology"
        package = _read_int(topology / "physical_package_id", 0)
        core_id = _read_int(topology / "core_id", cpu)
        node = _cpu_node(cpu_dir, node_root, cpu)
        siblings_path = topology / "thread_siblings_list"
        try:
            siblings = [
                sibling
                for sibling in expand_list(
                    siblings_path.read_text(encoding="ascii")
                )
                if sibling in online_cpus
            ]
        except (OSError, ValueError):
            siblings = [cpu]
        if cpu not in siblings:
            siblings.append(cpu)
        groups.setdefault((node, package, core_id), set()).update(siblings or [cpu])

    cores = [
        PhysicalCore(node, package, core_id, tuple(sorted(threads)))
        for (node, package, core_id), threads in groups.items()
        if threads
    ]
    return sorted(cores, key=lambda core: (core.node, core.package, core.threads[0]))


def read_held_cpus(
    current_pid: int,
    cgroup_name: str = "vmiso",
    cgroup_root: pathlib.Path = pathlib.Path("/sys/fs/cgroup"),
) -> set[int]:
    """读取 ABI5 每实例 1:1 exact child cpuset，作为锁外容量排序提示。"""
    del current_pid  # 最终排重由 root helper 锁内完成；这里只做无副作用的容量提示。
    cgroup = cgroup_root / cgroup_name
    held: set[int] = set()
    try:
        children = list(cgroup.iterdir())
    except OSError:
        return held
    for child in children:
        if not VM_CHILD_RE.fullmatch(child.name) \
                or child.is_symlink() or not child.is_dir():
            continue
        try:
            held.update(expand_list((child / "cpuset.cpus").read_text()))
        except (OSError, ValueError):
            pass
    return held


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="QEMU vCPU NUMA-aware pinner")
    parser.add_argument("instance")
    parser.add_argument("cpus", type=int)
    parser.add_argument("qmp_socket")
    parser.add_argument("helper")
    parser.add_argument("service_cpus", type=int, nargs="?", default=0)
    parser.add_argument("guest_threads_per_core", type=int, nargs="?", default=1)
    parser.add_argument("host_threads_per_core", type=int, nargs="?")
    parser.add_argument("--timeout", type=float, default=90.0)
    parser.add_argument("--launcher-pid", type=int)
    parser.add_argument("--launcher-starttime")
    parser.add_argument("--launcher-pgid", type=int)
    parser.add_argument("--status-fd", type=int)
    parser.add_argument(
        "--abort-on-failure",
        action="store_true",
        help="绑核失败时通过 QMP 关闭客机，供严格硬件模式使用",
    )
    return parser.parse_args(argv)


def run_pinner(args: argparse.Namespace) -> PinOutcome:
    """执行一次拓扑发现、QMP 线程查询和 root helper 调用。"""

    host_tpc = args.guest_threads_per_core \
        if args.host_threads_per_core is None else args.host_threads_per_core
    profile = (args.cpus, args.guest_threads_per_core, host_tpc)
    if (
        args.cpus <= 0
        or not (0 <= args.service_cpus <= 8)
        or not (1 <= args.guest_threads_per_core <= 8)
        or not (1 <= host_tpc <= 8)
        or args.cpus % args.guest_threads_per_core != 0
        or args.cpus % host_tpc != 0
        or profile not in {(2, 1, 1), (4, 2, 2), (4, 1, 1)}
        or (args.launcher_pid is None) != (args.launcher_starttime is None)
        or (args.launcher_pgid is not None
            and (args.launcher_pid is None or args.launcher_pgid <= 0))
        or (args.status_fd is not None
            and (args.status_fd != 1 or not args.abort_on_failure))
        or (args.launcher_starttime is not None
            and not args.launcher_starttime.isdigit())
    ):
        log("⚠ vCPU/service CPU/threads-per-core 参数非法")
        return PinOutcome(2)

    topology = discover_topology()
    if sum(len(core.threads) == 2 for core in topology) < 2:
        log("⚠ 完整 SMT2 宿主物理核少于 2，无法隔离")
        return PinOutcome(1 if args.abort_on_failure else 0)
    if not emit_supervisor_status(args.status_fd, "ARMED"):
        log("⚠ 严格启动监督管道已关闭")
        return PinOutcome(1)
    vcpus = query_vcpus(
        args.qmp_socket, args.cpus, args.timeout,
        args.launcher_pid, args.launcher_starttime,
    )
    if not vcpus:
        log("⚠ 等不到 vCPU 线程（QMP 无响应/超时）")
        return PinOutcome(1)
    pid = tgid_of(vcpus[0][1])
    if pid is None:
        log("⚠ 无法取得 QEMU pid")
        return PinOutcome(1)
    starttime = process_starttime(pid)
    if starttime is None or any(tgid_of(tid) != pid for _index, tid in vcpus):
        log("⚠ vCPU TID 不属于同一 QEMU 代际")
        return PinOutcome(1)
    if args.launcher_pgid is not None and (
        not process_matches(args.launcher_pid, args.launcher_starttime)
        or process_pgid(args.launcher_pid) != args.launcher_pgid
        or process_pgid(pid) != args.launcher_pgid
    ):
        log("⚠ QEMU 不属于严格启动器创建的进程组")
        return PinOutcome(1)

    # root helper 的 cgroup 名是固定安全边界，普通用户环境不得让发现算法读取另一
    # 个分区，否则“看到的已占 CPU”与最终写入的分区不同，会产生重复分配。
    held = read_held_cpus(pid, "vmiso")
    reserve_raw = os.environ.get("HOST_RESERVE_CORES", "auto").strip().lower()
    if reserve_raw in ("", "auto"):
        reserve = _auto_reserve(
            topology,
            held,
            len(vcpus),
            args.service_cpus,
            args.guest_threads_per_core,
            host_tpc,
        )
    else:
        try:
            reserve = int(reserve_raw)
        except ValueError:
            log(f"⚠ HOST_RESERVE_CORES 非法: {reserve_raw}")
            return PinOutcome(2, pid, starttime)

    placement = choose_placement(
        topology, held, len(vcpus), args.service_cpus, reserve,
        args.guest_threads_per_core, host_tpc)
    if not placement.preference or not placement.memory_nodes:
        log("⚠ 没有可用 CPU/NUMA node")
        return PinOutcome(1, pid, starttime)
    if placement.spans_nodes:
        log("⚠ 没有单个 NUMA node 能保持完整来宾拓扑，拒绝跨节点静默降级")
        return PinOutcome(1, pid, starttime)

    preference = ",".join(str(cpu) for cpu in placement.preference)
    memory_nodes = ",".join(str(node) for node in placement.memory_nodes)
    tids = ",".join(str(tid) for _index, tid in vcpus)
    free_hint = len(set(placement.preference) - held)
    log(
        f"pid={pid}, {len(vcpus)} vCPU, NUMA候选={memory_nodes}, "
        f"Guest每核 {args.guest_threads_per_core} 线程，"
        f"host每物理核映射 {host_tpc} vCPU，"
        f"预留 {placement.reserve_cores} 颗管理核，候选池 {len(placement.preference)} 个 vCPU 位置，"
        f"锁外空闲快照 {free_hint}，需求 {len(vcpus) + args.service_cpus}"
    )

    command = [
        "sudo", "-n", args.helper, "apply", args.instance, memory_nodes, str(pid),
        preference, tids, str(args.service_cpus),
        str(args.guest_threads_per_core),
        str(host_tpc),
    ]
    try:
        result = subprocess.run(
            command, capture_output=True, text=True, check=False
        )
    except (OSError, subprocess.SubprocessError) as exc:
        log(f"⚠ 调用 root helper 失败: {exc}")
        return PinOutcome(1, pid, starttime)
    for line in result.stdout.splitlines():
        if line.strip():
            log(line.strip())
    if result.returncode != 0:
        log(f"⚠ root helper 返回 {result.returncode}: {result.stderr.strip()[:240]}")
    return PinOutcome(result.returncode, pid, starttime, result.returncode == 0)


def _cleanup_strict_failure(args: argparse.Namespace, outcome: PinOutcome) -> None:
    if not args.abort_on_failure:
        return
    if outcome.pid is not None and outcome.starttime is not None:
        stopped = stop_bound_qemu(args.qmp_socket, outcome.pid, outcome.starttime)
        if stopped:
            release_instance(args.helper, args.instance)
    else:
        if args.status_fd is None:
            request_qmp_quit(args.qmp_socket, timeout=0.5)
        # helper 可能已落盘但尚未来得及构造 PinOutcome；无法从栈外恢复 PID。
        # 先通过 FD8 保护的 QMP 路径请求退出，再调用幂等 release；helper 会拒绝
        # 释放仍含活动进程的 child，既能回收部分事务，也不会把活动 CPU 错放回宿主。
        release_instance(args.helper, args.instance)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv if argv is not None else sys.argv[1:])
    # 后台任务从 QMP discovery 开始就不能被终端 HUP/TERM 截断；启动器代际消失会让
    # discovery 主动退出，helper 成功后则由 PID/starttime 守候并完成 release。
    ignore_lifecycle_signals()
    outcome = PinOutcome(1)
    try:
        outcome = run_pinner(args)
        if outcome.status != 0:
            emit_supervisor_status(args.status_fd, f"FAIL run {outcome.status}")
            _cleanup_strict_failure(args, outcome)
            return outcome.status
        if not outcome.applied:
            return 0
        if outcome.pid is None or outcome.starttime is None:
            log("⚠ helper 成功后缺少 QEMU 代际，拒绝留下无法回收的分区")
            emit_supervisor_status(args.status_fd, "FAIL identity 1")
            _cleanup_strict_failure(args, outcome)
            return 1

        # 从 helper 成功开始持续持有继承的 FD8；即使 QEMU 很快退出，同实例新启动也
        # 必须等本代完成 quit/release，旧 pinner 不可能连接或释放新代资源。
        if args.abort_on_failure and not request_qmp_command(
            args.qmp_socket, "cont", outcome.pid, outcome.starttime
        ):
            emit_supervisor_status(args.status_fd, "FAIL cont 1")
            cleanup_applied_failure(
                args.qmp_socket, args.helper, args.instance,
                outcome.pid, outcome.starttime,
            )
            return 1
        if not emit_supervisor_status(
            args.status_fd, f"RUNNING {outcome.pid} {outcome.starttime}"
        ):
            cleanup_applied_failure(
                args.qmp_socket, args.helper, args.instance,
                outcome.pid, outcome.starttime,
            )
            return 1
        released = watch_and_release(
            args.helper, args.instance, outcome.pid, outcome.starttime
        )
        return 0 if released else 1
    except Exception as exc:  # 最后的 fail-closed 监督边界，防止 paused VM 无人收尾。
        log(f"⚠ CPU pinner 未预期异常: {exc}")
        emit_supervisor_status(args.status_fd, "FAIL exception 1")
        _cleanup_strict_failure(args, outcome)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
