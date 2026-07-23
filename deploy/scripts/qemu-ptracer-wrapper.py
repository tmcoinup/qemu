#!/usr/bin/env python3
"""为当前进程设置 QEMU 进程级 Yama 例外，然后原地 exec 目标 QEMU。"""

from __future__ import annotations

import ctypes
import errno
import os
import sys
from collections.abc import Sequence


# Linux include/uapi/linux/prctl.h；PR_SET_PTRACER_ANY 是 unsigned long 的 -1。
PR_SET_PTRACER = 0x59616D61
PR_SET_PTRACER_ANY = ctypes.c_ulong(-1).value


def parse_command(arguments: Sequence[str]) -> list[str]:
    """解析可选的 `--` 分隔符，并保留 QEMU argv 的逐项边界。"""

    command = list(arguments)
    if command and command[0] == "--":
        command.pop(0)
    if not command:
        raise ValueError("用法：qemu-ptracer-wrapper.py [--] <qemu> [QEMU 参数...]")
    return command


def allow_same_uid_ptracers() -> None:
    """解除目标 QEMU 的 Yama scope=1 父子关系限制。"""

    libc = ctypes.CDLL(None, use_errno=True)
    prctl = libc.prctl
    prctl.argtypes = [
        ctypes.c_int,
        ctypes.c_ulong,
        ctypes.c_ulong,
        ctypes.c_ulong,
        ctypes.c_ulong,
    ]
    prctl.restype = ctypes.c_int
    result = prctl(PR_SET_PTRACER, PR_SET_PTRACER_ANY, 0, 0, 0)
    if result == 0:
        return

    error_number = ctypes.get_errno()
    # 未启用 Yama 的内核可能不认识该 prctl；此时不存在需要解除的 Yama 限制。
    if error_number == errno.EINVAL and not os.path.exists(
        "/proc/sys/kernel/yama/ptrace_scope"
    ):
        return
    raise OSError(error_number, os.strerror(error_number))


def main(arguments: Sequence[str]) -> int:
    try:
        command = parse_command(arguments)
        allow_same_uid_ptracers()
        os.execvpe(command[0], command, os.environ)
    except (OSError, ValueError) as error:
        print(f"qemu-ptracer-wrapper: {error}", file=sys.stderr)
        return 126
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
