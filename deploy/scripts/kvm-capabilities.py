#!/usr/bin/env python3
"""读取启动虚拟机前必须确认的 KVM 能力。

这个工具刻意只依赖 Python 标准库。启动脚本需要在创建 QEMU 进程以前知道
宿主是否支持 TSC scaling，以及 KVM 实际交给 vCPU 的 TSC 频率。仅依据 CPU
型号或 ``/proc/cpuinfo`` 推断会漏掉 OEM 处理器、嵌套虚拟化和内核差异。
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import sys
from dataclasses import asdict, dataclass


# Linux UAPI 中 KVMIO=0xAE；这些命令均为不携带结构体的 _IO ioctl。
KVM_CHECK_EXTENSION = 0xAE03
KVM_CREATE_VM = 0xAE01
KVM_CREATE_VCPU = 0xAE41
KVM_GET_TSC_KHZ = 0xAEA3
KVM_CAP_TSC_CONTROL = 60
KVM_CAP_GET_TSC_KHZ = 61


@dataclass(frozen=True)
class KvmCapabilities:
    """启动器消费的最小 KVM 能力集合。"""

    available: bool
    tsc_control: bool
    get_tsc_khz: bool
    host_tsc_khz: int
    error: str = ""


def _check_extension(kvm_fd: int, capability: int) -> bool:
    """通过 KVM_CHECK_EXTENSION 查询布尔能力。"""

    return fcntl.ioctl(kvm_fd, KVM_CHECK_EXTENSION, capability) > 0


def inspect_kvm(device: str = "/dev/kvm") -> KvmCapabilities:
    """打开 KVM，并用一个临时 VM/vCPU 读取实际 TSC 频率。

    临时 fd 在函数结束前全部关闭，不会启动客体、分配客体内存或改变宿主状态。
    某些受限容器允许读取设备节点但禁止 KVM_CREATE_VM；这种情况作为不可用返回，
    由上层严格策略决定是否终止。
    """

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
                # fd 已被内核或测试替身关闭时，无需覆盖原始探测结果。
                pass


def _shell_quote(value: str) -> str:
    """生成可被 Bash ``source`` 安全读取的单引号字符串。"""

    return "'" + value.replace("'", "'\"'\"'") + "'"


def format_shell(capabilities: KvmCapabilities) -> str:
    """输出固定字段的 Bash 赋值，不执行任何动态代码。"""

    values = {
        "STEALTH_KVM_AVAILABLE": int(capabilities.available),
        "STEALTH_KVM_TSC_CONTROL": int(capabilities.tsc_control),
        "STEALTH_KVM_GET_TSC_KHZ": int(capabilities.get_tsc_khz),
        "STEALTH_KVM_TSC_KHZ": capabilities.host_tsc_khz,
    }
    lines = [f"{name}={value}" for name, value in values.items()]
    lines.append(f"STEALTH_KVM_ERROR={_shell_quote(capabilities.error)}")
    return "\n".join(lines)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="读取 KVM TSC 能力")
    parser.add_argument("--device", default="/dev/kvm", help="KVM 设备路径")
    parser.add_argument(
        "--format",
        choices=("json", "shell"),
        default="json",
        help="输出格式",
    )
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
