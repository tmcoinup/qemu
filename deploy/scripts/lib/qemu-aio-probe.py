#!/usr/bin/env python3
"""用一次真实 O_DIRECT 读取验证 QEMU 文件 AIO 后端，不创建临时磁盘。"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import subprocess
import sys
from collections.abc import Sequence


FALLBACK_WARNING = "Unable to use Linux AIO, falling back to thread pool"


class ProbeError(RuntimeError):
    """后端不可用或 QMP 探测结果不可信。"""


def qmp_input() -> str:
    """生成三条有序命令：协商、实际读 4 KiB、退出。"""

    commands = (
        {"execute": "qmp_capabilities"},
        {
            "execute": "human-monitor-command",
            "arguments": {
                "command-line": 'qemu-io aio-probe "read -q 0 4096"',
            },
        },
        {"execute": "quit"},
    )
    return "".join(json.dumps(command) + "\n" for command in commands)


def blockdev_argument(binary: pathlib.Path, mode: str) -> str:
    """用 JSON 编码路径，避免空格、逗号或反斜杠进入 QEMU option 分隔语义。"""

    options = {
        "driver": "file",
        "node-name": "aio-probe",
        "filename": str(binary),
        "aio": mode,
        "read-only": True,
        "cache": {"direct": True, "no-flush": False},
    }
    return json.dumps(options, separators=(",", ":"))


def validate_qmp_output(stdout: str, stderr: str, returncode: int) -> None:
    """要求三个 command response 全部成功，并拒绝 native 的静默线程回退。"""

    diagnostics = f"{stdout}\n{stderr}"
    if returncode != 0:
        raise ProbeError(f"QEMU probe 退出码 {returncode}")
    if FALLBACK_WARNING in diagnostics:
        raise ProbeError("Linux AIO 初始化失败并静默回退 thread pool")

    responses: list[object] = []
    for raw_line in stdout.splitlines():
        if not raw_line.strip():
            continue
        try:
            message = json.loads(raw_line)
        except json.JSONDecodeError as error:
            raise ProbeError("QMP stdout 含非 JSON 数据") from error
        if not isinstance(message, dict):
            raise ProbeError("QMP response 不是 object")
        if "error" in message:
            raise ProbeError(f"QMP 命令失败: {message['error']!r}")
        if "return" in message:
            responses.append(message["return"])
    if responses != [{}, "", {}]:
        raise ProbeError(f"QMP active-read 响应序列异常: {responses!r}")


def probe(binary_text: str, mode: str, timeout: float) -> None:
    """启动最小 machine，并从 QEMU 自身 ELF 完成一次候选后端读取。"""

    if mode not in ("threads", "native", "io_uring"):
        raise ProbeError(f"未知 AIO 后端: {mode}")
    binary = pathlib.Path(binary_text).expanduser().absolute()
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise ProbeError(f"QEMU 不可执行: {binary}")
    command = [
        str(binary),
        "-machine", "none",
        "-no-user-config",
        "-nodefaults",
        "-display", "none",
        "-S",
        "-qmp", "stdio",
        "-blockdev", blockdev_argument(binary, mode),
    ]
    completed = subprocess.run(
        command,
        input=qmp_input(),
        capture_output=True,
        text=True,
        errors="replace",
        timeout=timeout,
        check=False,
    )
    validate_qmp_output(
        completed.stdout,
        completed.stderr,
        completed.returncode,
    )


def parse_args(arguments: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="QEMU 文件 AIO active-read probe")
    parser.add_argument("qemu")
    parser.add_argument("mode", choices=("threads", "native", "io_uring"))
    parser.add_argument("--timeout", type=float, default=10.0)
    parser.add_argument("--quiet", action="store_true")
    return parser.parse_args(arguments)


def main(arguments: Sequence[str]) -> int:
    args = parse_args(arguments)
    try:
        if args.timeout <= 0 or args.timeout > 60:
            raise ProbeError("timeout 必须在 (0,60] 秒")
        probe(args.qemu, args.mode, args.timeout)
        return 0
    except (OSError, subprocess.SubprocessError, ProbeError) as error:
        if not args.quiet:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
