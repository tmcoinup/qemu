#!/usr/bin/env python3
"""Read the KVM TSC capabilities used by the G-11 launcher.

The probe is read-only from an operator perspective: it creates and closes a
temporary VM/vCPU fd, allocates no guest RAM, and starts no guest instructions.
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import sys
from dataclasses import asdict, dataclass


KVM_CHECK_EXTENSION = 0xAE03
KVM_CREATE_VM = 0xAE01
KVM_CREATE_VCPU = 0xAE41
KVM_GET_TSC_KHZ = 0xAEA3
KVM_CAP_TSC_CONTROL = 60
KVM_CAP_GET_TSC_KHZ = 61


@dataclass(frozen=True)
class KvmCapabilities:
    available: bool
    tsc_control: bool
    get_tsc_khz: bool
    host_tsc_khz: int
    error: str = ""


def _check_extension(kvm_fd: int, capability: int) -> bool:
    return fcntl.ioctl(kvm_fd, KVM_CHECK_EXTENSION, capability) > 0


def inspect_kvm(device: str = "/dev/kvm") -> KvmCapabilities:
    descriptors: list[int] = []
    try:
        kvm_fd = os.open(device, os.O_RDWR | os.O_CLOEXEC)
        descriptors.append(kvm_fd)
        tsc_control = _check_extension(kvm_fd, KVM_CAP_TSC_CONTROL)
        get_tsc_khz = _check_extension(kvm_fd, KVM_CAP_GET_TSC_KHZ)
        host_tsc_khz = 0
        if get_tsc_khz:
            vm_fd = fcntl.ioctl(kvm_fd, KVM_CREATE_VM, 0)
            descriptors.append(vm_fd)
            vcpu_fd = fcntl.ioctl(vm_fd, KVM_CREATE_VCPU, 0)
            descriptors.append(vcpu_fd)
            host_tsc_khz = int(fcntl.ioctl(vcpu_fd, KVM_GET_TSC_KHZ, 0))
        return KvmCapabilities(
            available=True,
            tsc_control=tsc_control,
            get_tsc_khz=get_tsc_khz,
            host_tsc_khz=max(0, host_tsc_khz),
        )
    except OSError as exc:
        return KvmCapabilities(
            available=False,
            tsc_control=False,
            get_tsc_khz=False,
            host_tsc_khz=0,
            error=f"{exc.strerror or str(exc)} (errno={exc.errno})",
        )
    finally:
        for descriptor in reversed(descriptors):
            try:
                os.close(descriptor)
            except OSError:
                pass


def _shell_quote(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"


def format_shell(capabilities: KvmCapabilities) -> str:
    values = {
        "G11_KVM_AVAILABLE": int(capabilities.available),
        "G11_KVM_TSC_CONTROL": int(capabilities.tsc_control),
        "G11_KVM_GET_TSC_KHZ": int(capabilities.get_tsc_khz),
        "G11_KVM_TSC_KHZ": capabilities.host_tsc_khz,
    }
    lines = [f"{name}={value}" for name, value in values.items()]
    lines.append(f"G11_KVM_ERROR={_shell_quote(capabilities.error)}")
    return "\n".join(lines)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="读取 KVM TSC 能力")
    parser.add_argument("--device", default="/dev/kvm")
    parser.add_argument("--format", choices=("json", "shell"), default="json")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv if argv is not None else sys.argv[1:])
    capabilities = inspect_kvm(args.device)
    if args.format == "shell":
        print(format_shell(capabilities))
    else:
        print(json.dumps(asdict(capabilities), ensure_ascii=False, sort_keys=True))
    return 0 if capabilities.available else 1


if __name__ == "__main__":
    raise SystemExit(main())
