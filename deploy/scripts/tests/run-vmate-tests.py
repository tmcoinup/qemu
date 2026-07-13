#!/usr/bin/env python3
"""并发执行 VMate 回归测试，并为每个用例保留独立、可读的日志。"""

from __future__ import annotations

import argparse
import asyncio
import os
import pathlib
import sys
import time
from dataclasses import dataclass


SCRIPT_DIR = pathlib.Path(__file__).resolve().parent

# 快速集只包含不启动完整客机、不修改宿主网络且没有共享实例号的测试。完整集仍会
# 自动发现全部 test_*.sh/test_*.py，但改为串行，防止旧测试共用 /tmp socket 时互撞。
QUICK_TESTS = (
    "test_build_host_helper_integration.sh",
    "test_build_tooling_static.sh",
    "test_component_manifest.sh",
    "test_cpu_asset_profile.sh",
    "test_cpu_realize_preflight.sh",
    "test_ddr3_pool_matching.sh",
    "test_disk_capacity.sh",
    "test_guest_hardware_snapshot_static.sh",
    "test_hardware_pool_catalog.sh",
    "test_hardware_serials.sh",
    "test_host_cpu_isolate_transaction.sh",
    "test_host_helper_install.sh",
    "test_kvm_capabilities.py",
    "test_linux_platform_argv.sh",
    "test_memory_topology.sh",
    "test_memory_speed_fidelity.sh",
    "test_platform_manifest.sh",
    "test_soak_monitor.py",
    "test_stop_vm_instance_lock.sh",
    "test_tsc_policy.sh",
    "test_tpm_private_ca.sh",
    "test_windows_fb_shm_static.sh",
    "test_windows_gpu_sync_static.sh",
    "test_windows_platform_static.sh",
)


@dataclass(frozen=True)
class TestResult:
    """单个子进程的稳定结果；日志延后按测试名排序输出。"""

    name: str
    returncode: int
    output: str
    elapsed_seconds: float


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="运行 VMate 启动器与硬件身份回归测试")
    parser.add_argument(
        "--mode",
        choices=("quick", "full"),
        default="quick",
        help="quick 并发运行安全单测；full 串行运行目录内所有测试",
    )
    parser.add_argument(
        "--jobs",
        type=int,
        default=max(1, min(4, os.cpu_count() or 1)),
        help="quick 模式最大并发数（默认最多 4）",
    )
    return parser.parse_args()


def discover_tests(mode: str) -> list[pathlib.Path]:
    if mode == "quick":
        tests = [SCRIPT_DIR / name for name in QUICK_TESTS]
    else:
        tests = sorted(SCRIPT_DIR.glob("test_*.sh"))
        tests.extend(sorted(SCRIPT_DIR.glob("test_*.py")))
        # 测试调度器本身不是被测用例，否则会无限递归。
        tests = [path for path in tests if path.name != pathlib.Path(__file__).name]

    missing = [str(path) for path in tests if not path.is_file()]
    if missing:
        raise FileNotFoundError("以下测试不存在：" + ", ".join(missing))
    return tests


async def run_one(path: pathlib.Path, gate: asyncio.Semaphore) -> TestResult:
    """异步等待子进程，既限制并发，也不会阻塞状态输出或其它用例。"""

    command = ["bash", str(path)] if path.suffix == ".sh" else [sys.executable, str(path)]
    async with gate:
        started = time.monotonic()
        process = await asyncio.create_subprocess_exec(
            *command,
            cwd=SCRIPT_DIR,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
        )
        output_bytes, _ = await process.communicate()
        elapsed = time.monotonic() - started
        return TestResult(
            name=path.name,
            returncode=process.returncode or 0,
            output=output_bytes.decode("utf-8", errors="replace"),
            elapsed_seconds=elapsed,
        )


async def async_main(args: argparse.Namespace) -> int:
    tests = discover_tests(args.mode)
    # full 模式刻意串行：部分历史集成测试沿用固定 /tmp 路径，不能安全并发。
    jobs = 1 if args.mode == "full" else max(1, args.jobs)
    gate = asyncio.Semaphore(jobs)
    print(f"VMate tests: mode={args.mode}, jobs={jobs}, cases={len(tests)}", flush=True)

    results = await asyncio.gather(*(run_one(path, gate) for path in tests))
    failures = 0
    for result in sorted(results, key=lambda item: item.name):
        state = "PASS" if result.returncode == 0 else "FAIL"
        print(f"[{state}] {result.name} ({result.elapsed_seconds:.2f}s)")
        if result.output.strip():
            print(result.output.rstrip())
        if result.returncode != 0:
            failures += 1

    print(f"VMate tests complete: passed={len(results) - failures}, failed={failures}")
    return 1 if failures else 0


def main() -> int:
    args = parse_args()
    if args.jobs < 1:
        print("ERROR: --jobs 必须大于 0", file=sys.stderr)
        return 2
    try:
        return asyncio.run(async_main(args))
    except (FileNotFoundError, OSError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
