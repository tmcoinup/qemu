#!/usr/bin/env python3
"""Set a process-local Yama ptracer exception, then exec the target QEMU."""

from __future__ import annotations

import ctypes
import errno
import os
import sys
from collections.abc import Sequence


PR_SET_PTRACER = 0x59616D61
PR_SET_PTRACER_ANY = ctypes.c_ulong(-1).value


def parse_command(arguments: Sequence[str]) -> list[str]:
    command = list(arguments)
    if command and command[0] == "--":
        command.pop(0)
    if not command:
        raise ValueError(
            "usage: qemu-ptracer-wrapper.py [--] <qemu> [QEMU arguments...]"
        )
    return command


def allow_same_uid_ptracers() -> None:
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
    if prctl(PR_SET_PTRACER, PR_SET_PTRACER_ANY, 0, 0, 0) == 0:
        return

    error_number = ctypes.get_errno()
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
