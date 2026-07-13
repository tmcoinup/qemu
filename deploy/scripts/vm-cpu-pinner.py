#!/usr/bin/env python3
"""异步等待 QMP vCPU，并按宿主 NUMA/物理核拓扑生成绑核顺序。

QEMU 进程由启动器 ``exec`` 接管，不能同步等待自身 QMP。因此该工具作为短生命周期
后台子进程运行：发现 vCPU TID 后调用安装在 ``/usr/local/libexec`` 的 root helper，
自身随即退出。拓扑计算保留为纯函数，便于在没有 cgroup root 权限时做单元测试。
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import socket
import subprocess
import sys
import time
from dataclasses import dataclass


CPU_NAME_RE = re.compile(r"^cpu([0-9]+)$")


@dataclass(frozen=True)
class PhysicalCore:
    """同一 package/core_id 下共享执行单元的一组 SMT 线程。"""

    node: int
    package: int
    core_id: int
    threads: tuple[int, ...]


@dataclass(frozen=True)
class Placement:
    """传给 root helper 的 CPU 优先序与允许内存节点。"""

    preference: tuple[int, ...]
    memory_nodes: tuple[int, ...]
    spans_nodes: bool
    reserve_cores: int


def log(message: str) -> None:
    print(f">> CPU 隔离:   {message}", flush=True)


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
        entries = list(cpu_root.iterdir())
    except OSError:
        return []

    for cpu_dir in entries:
        match = CPU_NAME_RE.match(cpu_dir.name)
        if match is None:
            continue
        cpu = int(match.group(1))
        topology = cpu_dir / "topology"
        package = _read_int(topology / "physical_package_id", 0)
        core_id = _read_int(topology / "core_id", cpu)
        node = _cpu_node(cpu_dir, node_root, cpu)
        siblings_path = topology / "thread_siblings_list"
        try:
            siblings = expand_list(siblings_path.read_text(encoding="ascii"))
        except (OSError, ValueError):
            siblings = [cpu]
        groups.setdefault((node, package, core_id), set()).update(siblings or [cpu])

    cores = [
        PhysicalCore(node, package, core_id, tuple(sorted(threads)))
        for (node, package, core_id), threads in groups.items()
        if threads
    ]
    return sorted(cores, key=lambda core: (core.node, core.package, core.threads[0]))


def _node_capacity(
    cores: list[PhysicalCore], held: set[int]
) -> dict[int, tuple[int, int]]:
    """返回每个节点的（空闲主线程数，空闲逻辑线程数）。"""

    capacity: dict[int, tuple[int, int]] = {}
    for core in cores:
        primary_free = int(core.threads[0] not in held)
        logical_free = sum(thread not in held for thread in core.threads)
        old_primary, old_logical = capacity.get(core.node, (0, 0))
        capacity[core.node] = (
            old_primary + primary_free,
            old_logical + logical_free,
        )
    return capacity


def choose_placement(
    cores: list[PhysicalCore],
    held_cpus: set[int],
    vcpu_count: int,
    service_cpu_count: int,
    reserve_cores: int,
) -> Placement:
    """优先把一台 VM 完整放入单个 NUMA node，再按主线程→SMT 排序。

    ``reserve_cores`` 从排序最前的物理核中扣除，通常为 node0 的管理核。若任一
    单节点能容纳全部 vCPU/service CPU，则 memory node 也只给该节点；只有容量确实
    不足才跨节点，并在返回值中明确标记。
    """

    if vcpu_count <= 0 or service_cpu_count < 0:
        raise ValueError("vCPU/service CPU 数量非法")
    reserve = max(0, min(reserve_cores, max(0, len(cores) - 1)))
    eligible = cores[reserve:]
    if not eligible:
        return Placement((), (), False, reserve)

    required_logical = vcpu_count + service_cpu_count
    capacity = _node_capacity(eligible, held_cpus)
    fitting_nodes = [
        node
        for node, (primary, logical) in capacity.items()
        if primary >= vcpu_count and logical >= required_logical
    ]
    if fitting_nodes:
        # 空闲主线程最多者优先；相同时选 node id 较小者，保证重启后确定性。
        chosen = sorted(
            fitting_nodes,
            key=lambda node: (-capacity[node][0], -capacity[node][1], node),
        )[0]
        ordered_cores = [core for core in eligible if core.node == chosen]
        memory_nodes = (chosen,)
        spans_nodes = False
    else:
        ordered_cores = eligible
        memory_nodes = tuple(sorted({core.node for core in eligible}))
        spans_nodes = len(memory_nodes) > 1

    primaries = [core.threads[0] for core in ordered_cores]
    siblings = [thread for core in ordered_cores for thread in core.threads[1:]]
    preference = tuple(primaries + siblings)
    return Placement(preference, memory_nodes, spans_nodes, reserve)


def query_vcpus(sock_path: str, timeout: float = 90.0) -> list[tuple[int, int]]:
    """轮询 QMP ``query-cpus-fast``，返回 ``(cpu-index, thread-id)``。"""

    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            client.settimeout(5)
            client.connect(sock_path)
            stream = client.makefile("rw", encoding="utf-8")
            json.loads(stream.readline())
            stream.write(json.dumps({"execute": "qmp_capabilities"}) + "\n")
            stream.flush()
            json.loads(stream.readline())
            stream.write(json.dumps({"execute": "query-cpus-fast"}) + "\n")
            stream.flush()
            response = json.loads(stream.readline())
            entries = response.get("return", [])
            result = sorted(
                (int(entry["cpu-index"]), int(entry["thread-id"]))
                for entry in entries
                if "thread-id" in entry
            )
            if result:
                return result
        except (OSError, TimeoutError, ValueError, json.JSONDecodeError, KeyError):
            pass
        finally:
            client.close()
        time.sleep(1)
    return []


def request_qmp_quit(sock_path: str, timeout: float = 10.0) -> bool:
    """严格绑核失败时请求客机退出，避免未隔离 VM 被误当成合格实例。

    pinner 与 QEMU 并发启动，失败可能早于 socket 创建，因此在短截止时间内重试。
    QMP event 可能夹在命令响应之间，按 ``id`` 读取而不是假设下一行就是响应。
    """

    deadline = time.monotonic() + timeout
    last_error = "QMP socket 未就绪"
    while time.monotonic() < deadline:
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            client.settimeout(2.0)
            client.connect(sock_path)
            stream = client.makefile("rw", encoding="utf-8")
            greeting = json.loads(stream.readline())
            if "QMP" not in greeting:
                raise ValueError("缺少 QMP greeting")

            for command, ident in (
                ("qmp_capabilities", "vmate-pin-caps"),
                ("quit", "vmate-pin-abort"),
            ):
                stream.write(json.dumps({"execute": command, "id": ident}) + "\n")
                stream.flush()
                while True:
                    response = json.loads(stream.readline())
                    if response.get("id") == ident:
                        if "error" in response:
                            raise ValueError(f"QMP {command} 失败: {response['error']}")
                        break
            log("严格绑核失败，已请求 QMP quit")
            return True
        except (OSError, TimeoutError, ValueError, json.JSONDecodeError) as exc:
            last_error = str(exc)
        finally:
            client.close()
        time.sleep(0.25)
    log(f"⚠ 严格绑核失败且无法请求 QMP quit: {last_error}")
    return False


def tgid_of(tid: int) -> int | None:
    try:
        lines = pathlib.Path(f"/proc/{tid}/status").read_text().splitlines()
    except OSError:
        return None
    for line in lines:
        if line.startswith("Tgid:"):
            fields = line.split()
            return int(fields[1]) if len(fields) > 1 else None
    return None


def _read_affinity(status_path: pathlib.Path) -> set[int]:
    try:
        lines = status_path.read_text().splitlines()
    except OSError:
        return set()
    for line in lines:
        if line.startswith("Cpus_allowed_list:"):
            try:
                return set(expand_list(line.split()[1]))
            except (IndexError, ValueError):
                return set()
    return set()


def read_held_cpus(current_pid: int, cgroup_name: str = "vmiso") -> set[int]:
    """读取其它 VM 已显式收窄 affinity 的 vCPU/service CPU。"""

    cgroup = pathlib.Path("/sys/fs/cgroup") / cgroup_name
    try:
        effective = set(expand_list((cgroup / "cpuset.cpus.effective").read_text()))
    except (OSError, ValueError):
        effective = set()
    try:
        pids = (cgroup / "cgroup.procs").read_text().splitlines()
    except OSError:
        return set()

    held: set[int] = set()
    for pid_text in pids:
        if not pid_text.isdigit() or int(pid_text) == current_pid:
            continue
        task_root = pathlib.Path("/proc") / pid_text / "task"
        try:
            tasks = list(task_root.iterdir())
        except OSError:
            continue
        for task in tasks:
            affinity = _read_affinity(task / "status")
            if affinity and (not effective or affinity != effective):
                held.update(affinity)
    return held


def _auto_reserve(
    cores: list[PhysicalCore], held: set[int], vcpus: int, service_cpus: int
) -> int:
    default = min(max(2, (len(cores) + 7) // 8), max(0, len(cores) - 1))
    required = vcpus + service_cpus
    reserve = default
    while reserve > 0:
        capacity = _node_capacity(cores[reserve:], held)
        total_logical = sum(value[1] for value in capacity.values())
        max_primary = max((value[0] for value in capacity.values()), default=0)
        total_primary = sum(value[0] for value in capacity.values())
        if total_logical >= required and (max_primary >= vcpus or total_primary >= vcpus):
            break
        reserve -= 1
    return reserve


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="QEMU vCPU NUMA-aware pinner")
    parser.add_argument("instance")
    parser.add_argument("cpus", type=int)
    parser.add_argument("qmp_socket")
    parser.add_argument("helper")
    parser.add_argument("service_cpus", type=int, nargs="?", default=0)
    parser.add_argument("--timeout", type=float, default=90.0)
    parser.add_argument(
        "--abort-on-failure",
        action="store_true",
        help="绑核失败时通过 QMP 关闭客机，供严格硬件模式使用",
    )
    return parser.parse_args(argv)


def run_pinner(args: argparse.Namespace) -> int:
    """执行一次拓扑发现、QMP 线程查询和 root helper 调用。"""

    if args.cpus <= 0 or not (0 <= args.service_cpus <= 8):
        log("⚠ vCPU/service CPU 参数非法")
        return 2

    topology = discover_topology()
    if len(topology) < 2:
        log(f"⚠ 物理核数={len(topology)}，太少无法隔离")
        return 1 if args.abort_on_failure else 0
    vcpus = query_vcpus(args.qmp_socket, args.timeout)
    if not vcpus:
        log("⚠ 等不到 vCPU 线程（QMP 无响应/超时）")
        return 1
    pid = tgid_of(vcpus[0][1])
    if pid is None:
        log("⚠ 无法取得 QEMU pid")
        return 1

    # root helper 的 cgroup 名是固定安全边界，普通用户环境不得让发现算法读取另一
    # 个分区，否则“看到的已占 CPU”与最终写入的分区不同，会产生重复分配。
    held = read_held_cpus(pid, "vmiso")
    reserve_raw = os.environ.get("HOST_RESERVE_CORES", "auto").strip().lower()
    if reserve_raw in ("", "auto"):
        reserve = _auto_reserve(topology, held, len(vcpus), args.service_cpus)
    else:
        try:
            reserve = int(reserve_raw)
        except ValueError:
            log(f"⚠ HOST_RESERVE_CORES 非法: {reserve_raw}")
            return 2

    placement = choose_placement(
        topology, held, len(vcpus), args.service_cpus, reserve
    )
    if not placement.preference or not placement.memory_nodes:
        log("⚠ 没有可用 CPU/NUMA node")
        return 1
    if placement.spans_nodes:
        log("⚠ 单个 NUMA node 容量不足，本实例将跨节点；建议降低 vCPU 或拆分 VM")

    preference = ",".join(str(cpu) for cpu in placement.preference)
    memory_nodes = ",".join(str(node) for node in placement.memory_nodes)
    tids = ",".join(str(tid) for _index, tid in vcpus)
    log(
        f"pid={pid}, {len(vcpus)} vCPU, node={memory_nodes}, "
        f"预留 {placement.reserve_cores} 颗管理核，候选 {len(placement.preference)} 线程"
    )

    command = [
        "sudo", "-n", args.helper, "apply", args.instance, memory_nodes, str(pid),
        preference, tids, str(args.service_cpus),
    ]
    try:
        result = subprocess.run(
            command, capture_output=True, text=True, timeout=30, check=False
        )
    except (OSError, subprocess.SubprocessError) as exc:
        log(f"⚠ 调用 root helper 失败: {exc}")
        return 1
    for line in result.stdout.splitlines():
        if line.strip():
            print(line.strip(), flush=True)
    if result.returncode != 0:
        log(f"⚠ root helper 返回 {result.returncode}: {result.stderr.strip()[:240]}")
    return result.returncode


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv if argv is not None else sys.argv[1:])
    status = run_pinner(args)
    if status != 0 and args.abort_on_failure:
        request_qmp_quit(args.qmp_socket)
    return status


if __name__ == "__main__":
    raise SystemExit(main())
