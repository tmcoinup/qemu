#!/usr/bin/env python3
"""Query a running G-11 QEMU's VFIO display capabilities without stopping it.

Only VFIO_DEVICE_QUERY_GFX_PLANE with PROBE|DMABUF and PROBE|REGION is
issued.  No pixels, DMA-BUF handles, mappings, reset or guest agent are used.
The duplicated VFIO fd is closed after the two capability queries.
"""

import argparse
import ctypes
import errno
import fcntl
import os
from pathlib import Path
import platform
import re
import struct
import sys


# Linux x86_64 UAPI: asm/unistd_64.h and linux/vfio.h.  Refuse other ABIs
# rather than guessing syscall numbers or ioctl structure alignment.
SYS_PIDFD_GETFD_X86_64 = 438
VFIO_DEVICE_QUERY_GFX_PLANE = (ord(";") << 8) | (100 + 14)
VFIO_GFX_PLANE_TYPE_PROBE = 1
VFIO_GFX_PLANE_TYPE_DMABUF = 2
VFIO_GFX_PLANE_TYPE_REGION = 4
GFX_PLANE_INFO_SIZE = 64
VFIO_DEVICE_LINK = "anon_inode:[vfio-device]"


class ProbeError(Exception):
    def __init__(self, operation, error_number=0):
        self.operation = operation
        self.error_number = error_number or 0
        super().__init__(operation)


def positive_pid(value):
    try:
        number = int(value)
    except ValueError:
        raise argparse.ArgumentTypeError("PID 必须是正整数") from None
    if not 0 < number <= 2147483647:
        raise argparse.ArgumentTypeError("PID 必须是有效的正整数")
    return number


def nonnegative_fd(value):
    try:
        number = int(value)
    except ValueError:
        raise argparse.ArgumentTypeError("FD 必须是非负整数") from None
    if not 0 <= number <= 2147483647:
        raise argparse.ArgumentTypeError("FD 必须是有效的非负整数")
    return number


def process_identity(pid):
    root = Path(f"/proc/{pid}")
    exe = os.readlink(root / "exe")
    executable = Path(exe.removesuffix(" (deleted)")).name
    if not executable.startswith("qemu-system-"):
        raise ProbeError("target-is-not-qemu")
    # Field 22 follows the comm field, whose parentheses may contain spaces.
    stat_fields = (root / "stat").read_text().rsplit(")", 1)[1].split()
    start_time = int(stat_fields[19])
    return exe, start_time


def process_vm_name(pid):
    # Read only argv to find -name, never /proc/PID/environ; emit a bounded
    # G-11 label rather than echoing arbitrary command-line arguments.
    argv = Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0")
    for index, arg in enumerate(argv[:-1]):
        if arg == b"-name":
            name = argv[index + 1].split(b",", 1)[0]
            if re.fullmatch(rb"vm[1-9][0-9]*", name):
                return name.decode("ascii")
    return "unavailable"


def find_vm_pid(vm_id):
    expected = f"vm{vm_id}"
    candidates = []
    for entry in Path("/proc").iterdir():
        if not entry.name.isdecimal():
            continue
        pid = int(entry.name)
        try:
            process_identity(pid)
            if process_vm_name(pid) == expected:
                candidates.append(pid)
        except (OSError, ProbeError, IndexError, ValueError):
            continue  # Non-QEMU, inaccessible or exited during enumeration.
    if len(candidates) != 1:
        raise ProbeError("vm-not-running-or-inaccessible" if not candidates else
                         "multiple-qemu-processes-for-vm")
    return candidates[0]


def select_vfio_fd(pid, requested=None):
    root = Path(f"/proc/{pid}/fd")
    if requested is not None:
        if os.readlink(root / str(requested)) != VFIO_DEVICE_LINK:
            raise ProbeError("selected-fd-is-not-vfio-device")
        return requested
    candidates = []
    for entry in root.iterdir():
        if not entry.name.isdecimal():
            continue
        try:
            target = os.readlink(entry)
        except FileNotFoundError:
            continue  # Unrelated fd closed during enumeration.
        if target == VFIO_DEVICE_LINK:
            candidates.append(int(entry.name))
    if len(candidates) != 1:
        raise ProbeError("no-vfio-device-fd" if not candidates else
                         "multiple-vfio-device-fds-use-explicit-fd")
    return candidates[0]


def duplicate_fd(pidfd, target_fd):
    libc = ctypes.CDLL(None, use_errno=True)
    libc.syscall.restype = ctypes.c_long
    result = libc.syscall(ctypes.c_long(SYS_PIDFD_GETFD_X86_64),
                          ctypes.c_int(pidfd), ctypes.c_int(target_fd),
                          ctypes.c_uint(0))
    if result < 0:
        number = ctypes.get_errno()
        raise OSError(number, os.strerror(number))
    return result


def query_support(fd, plane_type):
    if plane_type not in (VFIO_GFX_PLANE_TYPE_DMABUF,
                          VFIO_GFX_PLANE_TYPE_REGION):
        raise ProbeError("invalid-capability-type")
    payload = bytearray(GFX_PLANE_INFO_SIZE)
    # Match hw/vfio/display.c: argsz + flags, every other input zero.
    struct.pack_into("=II", payload, 0, GFX_PLANE_INFO_SIZE,
                     VFIO_GFX_PLANE_TYPE_PROBE | plane_type)
    try:
        fcntl.ioctl(fd, VFIO_DEVICE_QUERY_GFX_PLANE, payload, True)
    except OSError as exc:
        # linux/vfio.h defines EINVAL for an unsupported PROBE type.
        # EPERM, ENOTTY, EIO etc. are not evidence of unsupported DMA-BUF.
        return ("unsupported" if exc.errno == errno.EINVAL else "error",
                exc.errno or 0)
    return "supported", 0


def probe_running_qemu(pid, requested_fd=None, check_only=False, expected_vm=None):
    if platform.system() != "Linux" or platform.machine() != "x86_64":
        raise ProbeError("requires-linux-x86_64")
    if not hasattr(os, "pidfd_open"):
        raise ProbeError("python-pidfd-open-unavailable")
    result = {"PROBE_MODE": "access-only" if check_only else "capability-only",
              "QEMU_PID": pid}
    pidfd = device_fd = None
    operation = "process-identity"
    try:
        identity = process_identity(pid)
        operation = "pidfd-open"
        pidfd = os.pidfd_open(pid, 0)
        operation = "select-vfio-fd"
        target_fd = select_vfio_fd(pid, requested_fd)
        operation = "pidfd-getfd"
        device_fd = duplicate_fd(pidfd, target_fd)
        operation = "validate-duplicate"
        if os.readlink(f"/proc/self/fd/{device_fd}") != VFIO_DEVICE_LINK:
            raise ProbeError("duplicated-fd-is-not-vfio-device")
        if process_identity(pid) != identity:
            raise ProbeError("qemu-process-identity-changed")
        result.update(VM_NAME=process_vm_name(pid), VFIO_FD=target_fd,
                      PIDFD_GETFD="ok")
        if expected_vm is not None and result["VM_NAME"] != f"vm{expected_vm}":
            raise ProbeError("qemu-vm-name-changed")
        if check_only:
            result.update(SOURCE_DMABUF="not-probed", SOURCE_REGION="not-probed",
                          END_TO_END_GPU="unverified", PROBE_RESULT="access-ok")
            return result
        dmabuf, dmabuf_errno = query_support(device_fd, VFIO_GFX_PLANE_TYPE_DMABUF)
        region, region_errno = query_support(device_fd, VFIO_GFX_PLANE_TYPE_REGION)
        result.update(SOURCE_DMABUF=dmabuf, SOURCE_DMABUF_ERRNO=dmabuf_errno,
                      SOURCE_REGION=region, SOURCE_REGION_ERRNO=region_errno,
                      END_TO_END_GPU=("unavailable" if dmabuf == "unsupported"
                                      else "unverified"),
                      PROBE_RESULT=("incomplete" if "error" in (dmabuf, region)
                                    else "complete"))
        return result
    except OSError as exc:
        raise ProbeError(operation, exc.errno) from None
    finally:
        if device_fd is not None:
            os.close(device_fd)
        if pidfd is not None:
            os.close(pidfd)


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="只读查询运行中 G-11 QEMU 的源 VFIO DMA-BUF/REGION 能力；无需重启 VM。")
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--vm", type=positive_pid,
                        help="VM 编号；按 QEMU -name vm编号 精确选择唯一运行进程")
    target.add_argument("--pid", type=positive_pid,
                        help="明确指定运行中的 QEMU PID（诊断用）")
    parser.add_argument("--fd", type=nonnegative_fd,
                        help="多个 VFIO device fd 时明确指定；默认只接受唯一候选")
    parser.add_argument("--check-only", action="store_true",
                        help="仅校验进程和复制 fd 的权限，不执行任何 ioctl")
    args = parser.parse_args(argv)
    pid = args.pid
    try:
        if args.vm is not None:
            pid = find_vm_pid(args.vm)
        result = probe_running_qemu(pid, args.fd, args.check_only, args.vm)
    except ProbeError as exc:
        result = {"QEMU_PID": pid if pid is not None else "unavailable",
                  "PROBE_RESULT": "incomplete",
                  "PROBE_ERROR": exc.operation, "PROBE_ERRNO": exc.error_number,
                  "SOURCE_DMABUF": "unknown", "SOURCE_REGION": "unknown",
                  "END_TO_END_GPU": "unverified"}
    for key, value in result.items():
        print(f"{key}={value}")
    return 2 if result["PROBE_RESULT"] == "incomplete" else 0


if __name__ == "__main__":
    sys.exit(main())
