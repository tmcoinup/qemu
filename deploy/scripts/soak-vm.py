#!/usr/bin/env python3
"""通过 QMP 异步监控长时间运行的 VM，并生成机器可读的稳定性报告。"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import pathlib
import re
import signal
import sys
import time
from dataclasses import dataclass, field
from typing import Any


DURATION_PATTERN = re.compile(r"^(?P<value>[1-9][0-9]*)(?P<unit>[smhd]?)$")


def parse_duration(raw: str) -> int:
    """把 30s/10m/24h/2d 转成秒；拒绝小数与零，避免误跑无效验收。"""

    match = DURATION_PATTERN.fullmatch(raw.strip().lower())
    if match is None:
        raise ValueError(f"非法时长：{raw}")
    multipliers = {"": 1, "s": 1, "m": 60, "h": 3600, "d": 86400}
    return int(match.group("value")) * multipliers[match.group("unit")]


class QmpError(RuntimeError):
    """QMP 连接、协议或命令错误的统一异常。"""


class QmpClient:
    """最小异步 QMP 客户端；按命令 ID 过滤异步事件，避免响应串线。"""

    def __init__(self, socket_path: pathlib.Path, timeout: float) -> None:
        self.socket_path = socket_path
        self.timeout = timeout
        self.reader: asyncio.StreamReader | None = None
        self.writer: asyncio.StreamWriter | None = None
        self.command_id = 0

    async def connect(self) -> None:
        try:
            self.reader, self.writer = await asyncio.wait_for(
                asyncio.open_unix_connection(str(self.socket_path)), self.timeout
            )
            greeting = await self._read_message()
            if "QMP" not in greeting:
                raise QmpError("QMP greeting 缺少 QMP 字段")
            await self.execute("qmp_capabilities")
        except (OSError, asyncio.TimeoutError, json.JSONDecodeError) as exc:
            await self.close()
            raise QmpError(f"连接 {self.socket_path} 失败：{exc}") from exc

    async def close(self) -> None:
        if self.writer is not None:
            self.writer.close()
            try:
                await self.writer.wait_closed()
            except (OSError, ConnectionError):
                pass
        self.reader = None
        self.writer = None

    async def _read_message(self) -> dict[str, Any]:
        if self.reader is None:
            raise QmpError("QMP 尚未连接")
        line = await asyncio.wait_for(self.reader.readline(), self.timeout)
        if not line:
            raise QmpError("QMP 连接被客体进程关闭")
        value = json.loads(line.decode("utf-8"))
        if not isinstance(value, dict):
            raise QmpError("QMP 返回值不是对象")
        return value

    async def execute(self, command: str) -> Any:
        if self.writer is None:
            raise QmpError("QMP 尚未连接")
        self.command_id += 1
        request_id = f"soak-{self.command_id}"
        request = {"execute": command, "id": request_id}
        self.writer.write((json.dumps(request) + "\n").encode("utf-8"))
        await asyncio.wait_for(self.writer.drain(), self.timeout)

        # QMP event 与命令响应共用连接；只消费目标 ID，事件不计为错误。
        while True:
            response = await self._read_message()
            if response.get("id") != request_id:
                continue
            if "error" in response:
                raise QmpError(f"{command} 失败：{response['error']}")
            return response.get("return")


@dataclass
class SoakSummary:
    """最终报告统计，便于 CI 或人工验收直接判断通过条件。"""

    started_at_unix: float
    requested_seconds: int
    samples: int = 0
    qmp_failures: int = 0
    state_failures: int = 0
    max_rss_kib: int = 0
    statuses: dict[str, int] = field(default_factory=dict)
    failure_reason: str = ""

    def record_status(self, status: str) -> None:
        self.statuses[status] = self.statuses.get(status, 0) + 1


def read_process_metrics(pid: int | None) -> dict[str, int | bool]:
    if pid is None:
        return {}
    proc_dir = pathlib.Path("/proc") / str(pid)
    if not proc_dir.exists():
        return {"process_alive": False}
    metrics: dict[str, int | bool] = {"process_alive": True}
    try:
        for line in (proc_dir / "status").read_text(encoding="utf-8").splitlines():
            if line.startswith("VmRSS:"):
                metrics["rss_kib"] = int(line.split()[1])
            elif line.startswith("Threads:"):
                metrics["threads"] = int(line.split()[1])
    except (OSError, ValueError, IndexError):
        # /proc 在进程退出瞬间可能消失；下一次状态检查会给出明确结论。
        metrics["process_alive"] = proc_dir.exists()
    return metrics


async def collect_sample(client: QmpClient) -> dict[str, Any]:
    """顺序读取同一 QMP 流；监控循环自身异步等待，不阻塞其它宿主任务。"""

    # 一个 StreamReader 不能由多个协程同时 readline。四条轻量只读命令顺序发送，
    # 可以保证 event/response 的 ID 匹配，同时每一步仍采用异步 I/O 与超时控制。
    status = await client.execute("query-status")
    cpus = await client.execute("query-cpus-fast")
    memory = await client.execute("query-memory-size-summary")
    block = await client.execute("query-blockstats")
    return {
        "status": status,
        "vcpu_count": len(cpus) if isinstance(cpus, list) else None,
        "memory": memory,
        "blockstats": block,
    }


async def monitor(args: argparse.Namespace) -> int:
    requested_seconds = parse_duration(args.duration)
    summary = SoakSummary(time.time(), requested_seconds)
    deadline = time.monotonic() + requested_seconds
    stop_event = asyncio.Event()
    loop = asyncio.get_running_loop()
    for signum in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(signum, stop_event.set)
        except NotImplementedError:
            pass

    output_path = pathlib.Path(args.output).expanduser().resolve()
    output_path.parent.mkdir(parents=True, exist_ok=True)
    consecutive_failures = 0
    with output_path.open("a", encoding="utf-8", buffering=1) as output:
        while time.monotonic() < deadline and not stop_event.is_set():
            sample: dict[str, Any] = {"timestamp_unix": time.time()}
            metrics = read_process_metrics(args.pid)
            sample.update(metrics)
            if metrics.get("process_alive") is False:
                summary.failure_reason = f"QEMU PID {args.pid} 已退出"
                output.write(json.dumps(sample, ensure_ascii=False) + "\n")
                break

            client = QmpClient(pathlib.Path(args.qmp), args.timeout)
            try:
                await client.connect()
                sample.update(await collect_sample(client))
                status_object = sample.get("status")
                status = status_object.get("status", "unknown") if isinstance(status_object, dict) else "unknown"
                summary.record_status(status)
                if status != "running" and not (args.allow_paused and status == "paused"):
                    summary.state_failures += 1
                consecutive_failures = 0
                summary.samples += 1
            except (QmpError, OSError, asyncio.TimeoutError, json.JSONDecodeError) as exc:
                sample["qmp_error"] = str(exc)
                summary.qmp_failures += 1
                consecutive_failures += 1
                if consecutive_failures >= args.max_consecutive_failures:
                    summary.failure_reason = f"QMP 连续失败 {consecutive_failures} 次"
            finally:
                await client.close()

            rss_kib = sample.get("rss_kib")
            if isinstance(rss_kib, int):
                summary.max_rss_kib = max(summary.max_rss_kib, rss_kib)
            output.write(json.dumps(sample, ensure_ascii=False, sort_keys=True) + "\n")
            if summary.failure_reason:
                break
            remaining = deadline - time.monotonic()
            if remaining > 0:
                try:
                    await asyncio.wait_for(stop_event.wait(), min(args.interval, remaining))
                except asyncio.TimeoutError:
                    pass

    result = {
        **summary.__dict__,
        "completed_at_unix": time.time(),
        "passed": not summary.failure_reason and summary.samples > 0 and summary.state_failures == 0,
        "interrupted": stop_event.is_set(),
        "log": str(output_path),
    }
    summary_path = output_path.with_suffix(output_path.suffix + ".summary.json")
    temporary = summary_path.with_suffix(summary_path.suffix + f".tmp.{os.getpid()}")
    temporary.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary, summary_path)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result["passed"] else 1


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="QMP 长稳/压力验收监控器")
    parser.add_argument("--qmp", required=True, help="QMP Unix socket 路径")
    parser.add_argument("--duration", default="24h", help="监控时长，例如 30m、24h、2d")
    parser.add_argument("--interval", type=float, default=30.0, help="采样间隔秒数")
    parser.add_argument("--timeout", type=float, default=5.0, help="单次 QMP 操作超时")
    parser.add_argument("--pid", type=int, help="可选 QEMU PID；提供后同步检查 RSS/存活")
    parser.add_argument("--output", default="vmate-soak.jsonl", help="JSONL 采样日志")
    parser.add_argument("--allow-paused", action="store_true", help="把 paused 状态视为正常")
    parser.add_argument("--max-consecutive-failures", type=int, default=3)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.interval <= 0 or args.timeout <= 0 or args.max_consecutive_failures < 1:
        print("ERROR: interval/timeout/最大连续失败数必须为正数", file=sys.stderr)
        return 2
    try:
        return asyncio.run(monitor(args))
    except (ValueError, OSError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
