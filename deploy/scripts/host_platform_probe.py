#!/usr/bin/env python3
"""从 Linux 内核视图派生 host-passthrough CPU 绑定事实。"""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import re

from guest_cpu_policy import forbidden_server_identity, household_brand_allowed
from host_platform_manifest import SUPPORTED_VENDORS, fail


def test_overrides_enabled() -> bool:
    """只有独立测试可注入宿主事实；生产启动必须读取内核真实视图。"""
    return os.environ.get("STEALTH_HOST_PROBE_TEST_MODE") == "1"


def test_override(name: str) -> str | None:
    """返回受控测试覆盖；普通环境中的同名变量不会改变 host-passthrough。"""
    if not test_overrides_enabled():
        return None
    return os.environ.get(name)


def parse_positive_int(value: str, where: str, maximum: int | None = None) -> int:
    """解析无符号十进制，拒绝空值、符号和不可接受范围。"""
    if not re.fullmatch(r"[0-9]+", value):
        fail(f"{where} 必须是正整数")
    parsed = int(value)
    if parsed <= 0 or (maximum is not None and parsed > maximum):
        fail(f"{where} 超出允许范围")
    return parsed


def parse_uint(value: str, where: str, maximum: int) -> int:
    """解析允许为零的 CPUID 数值；stepping=0 是合法硬件事实。"""
    if not re.fullmatch(r"[0-9]+", value):
        fail(f"{where} 必须是无符号整数")
    parsed = int(value)
    if parsed > maximum:
        fail(f"{where} 超出允许范围")
    return parsed


def read_cpuinfo() -> dict[str, str]:
    """只读取首颗逻辑 CPU，混合厂商/型号宿主不会被拼成一套身份。"""
    result: dict[str, str] = {}
    try:
        text = Path("/proc/cpuinfo").read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        fail(f"无法读取 /proc/cpuinfo: {exc}")
    for line in text.splitlines():
        if not line.strip():
            if result:
                break
            continue
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        result[key.strip()] = value.strip()
    return result


def env_or_cpuinfo(name: str, cpuinfo: dict[str, str], key: str) -> str:
    """测试可显式注入事实；生产默认读取内核导出的 CPUID 视图。"""
    injected = test_override(name)
    return injected if injected is not None else cpuinfo.get(key, "")


def detect_max_mhz(cpuinfo: dict[str, str], tsc_mhz: int) -> int:
    """优先读取稳定上限；无 cpufreq/标称值时用 KVM TSC 作保守基频。"""
    injected = test_override("STEALTH_HOST_CPU_MAX_MHZ")
    if injected is not None:
        return parse_positive_int(injected, "STEALTH_HOST_CPU_MAX_MHZ", 100000)
    maxima: list[int] = []
    for path in Path("/sys/devices/system/cpu").glob(
        "cpu[0-9]*/cpufreq/cpuinfo_max_freq"
    ):
        try:
            khz = int(path.read_text(encoding="ascii").strip())
        except (OSError, ValueError):
            continue
        if khz > 0:
            maxima.append((khz + 500) // 1000)
    if maxima:
        return max(maxima)
    nominal = re.search(
        r"@\s*([0-9]+(?:\.[0-9]+)?)\s*GHz",
        cpuinfo.get("model name", ""),
        re.IGNORECASE,
    )
    if nominal:
        return max(1, round(float(nominal.group(1)) * 1000))
    # 服务器固件经常不提供 cpufreq，AMD 型号字符串也常没有 “@ X GHz”。
    # KVM_GET_TSC_KHZ 是本启动器已经验证过的稳定时钟；把它作为保守基频不会
    # 像历史 99999MHz 那样越权放行，也不会因动态 cpu MHz 在重启间漂移。
    return tsc_mhz


def detect_phys_bits(cpuinfo: dict[str, str]) -> int:
    """读取宿主物理地址位宽；客体上限另行收敛到 QEMU 支持的 52 位。"""
    value = test_override("STEALTH_HOST_CPU_PHYS_BITS")
    if value is None:
        match = re.match(
            r"([0-9]+)\s+bits physical", cpuinfo.get("address sizes", "")
        )
        value = match.group(1) if match else ""
    return parse_positive_int(value, "STEALTH_HOST_CPU_PHYS_BITS", 64)


def detect_online_threads() -> int:
    """逻辑 CPU 数只用于容量门禁和指纹，不冒充物理核心数。"""
    value = test_override("STEALTH_HOST_CPU_ONLINE_THREADS")
    if value is not None:
        return parse_positive_int(value, "STEALTH_HOST_CPU_ONLINE_THREADS", 8192)
    try:
        detected = len(os.sched_getaffinity(0))
    except (AttributeError, OSError):
        detected = os.cpu_count() or 0
    if detected <= 0:
        fail("无法探测宿主在线逻辑 CPU 数")
    return detected


def detect_host_cores(cpuinfo: dict[str, str]) -> int:
    """读取单路家用处理器的物理核心数，禁止猜测 SMT 拓扑。"""
    value = test_override("STEALTH_HOST_CPU_CORES")
    if value is None:
        value = cpuinfo.get("cpu cores", "")
    return parse_positive_int(value, "STEALTH_HOST_CPU_CORES", 4096)


def guest_core_count(host_cores: int, online_threads: int, guest_cpus: int) -> int:
    """在宿主容量内选择产品允许的 2C2T、2C4T 或 4C4T 子拓扑。"""
    if host_cores > online_threads or online_threads % host_cores != 0:
        fail(
            "宿主核心/线程拓扑不可能: "
            f"cores={host_cores} threads={online_threads}"
        )
    threads_per_core = online_threads // host_cores
    if threads_per_core not in {1, 2}:
        fail(f"宿主每核心线程数不受支持: {threads_per_core}")
    if guest_cpus not in {2, 4}:
        fail("host-passthrough Guest 只允许 2 或 4 个 vCPU")
    if online_threads < guest_cpus:
        fail(
            f"host-passthrough Guest CPUS={guest_cpus} 超过宿主在线容量 "
            f"{online_threads}"
        )
    # Guest 固定使用至少两个物理核心。支持 SMT 的大宿主优先形成 2C4T，
    # 不支持 SMT 的宿主形成 4C4T；2 vCPU 始终形成可审计的 2C2T。
    if guest_cpus == 2:
        if host_cores < 2:
            fail("host-passthrough 2C2T 至少需要两个宿主物理核心")
        return 2
    if threads_per_core == 2 and host_cores >= 2:
        return 2
    if host_cores >= 4:
        return 4
    fail("宿主容量无法形成 2C4T 或 4C4T Guest 子拓扑")


def detect_host_facts(guest_cpus: int) -> dict[str, int | str]:
    """形成可持久化的 host-passthrough 最小事实集合。"""
    cpuinfo = read_cpuinfo()
    kernel_brand = cpuinfo.get("model name", "")
    # 即使测试/运维环境意外遗留了覆盖变量，也不能在真实 E5/EPYC 机器上把
    # model name 伪装成 Core/Ryzen 后进入 `-cpu host`；QEMU 最终仍会暴露真实
    # 服务器品牌，因此必须同时检查未经覆盖的内核值。
    if forbidden_server_identity(kernel_brand):
        fail("真实宿主是服务器 CPU，禁止进入 Guest host-passthrough")
    vendor = env_or_cpuinfo("STEALTH_HOST_CPU_VENDOR", cpuinfo, "vendor_id")
    if vendor not in SUPPORTED_VENDORS:
        fail(f"不支持的宿主 CPU 厂商: {vendor or 'unknown'}")
    brand = env_or_cpuinfo("STEALTH_HOST_CPU_MODEL_NAME", cpuinfo, "model name")
    if not 3 <= len(brand) <= 127 or any(ord(char) < 0x20 for char in brand):
        fail("宿主 CPU model name 缺失或含控制字符")
    # 中文注释：host-passthrough 会把宿主品牌串原样交给 Guest。用户要求
    # Guest 只出现家用 CPU，因此 Xeon/E3-E7、EPYC、Opteron 等服务器品牌
    # 不能走这一最终兜底；E5 宿主应改走可塑造家用 CPUID 的完整兼容 bundle。
    if forbidden_server_identity(brand):
        fail("拒绝把服务器 CPU 品牌透传给 Guest；请使用家用 CPU compatibility bundle")
    if not household_brand_allowed(vendor, brand):
        fail("无法从宿主 CPU 品牌证明其属于受控家用系列")
    family = parse_positive_int(
        env_or_cpuinfo("STEALTH_HOST_CPU_FAMILY", cpuinfo, "cpu family"),
        "STEALTH_HOST_CPU_FAMILY",
        0xFFFF,
    )
    model = parse_uint(
        env_or_cpuinfo("STEALTH_HOST_CPU_MODEL", cpuinfo, "model"),
        "STEALTH_HOST_CPU_MODEL",
        0xFFFF,
    )
    stepping = parse_uint(
        env_or_cpuinfo("STEALTH_HOST_CPU_STEPPING", cpuinfo, "stepping"),
        "STEALTH_HOST_CPU_STEPPING",
        0xFFFF,
    )
    online_threads = detect_online_threads()
    cores = detect_host_cores(cpuinfo)
    guest_cores = guest_core_count(cores, online_threads, guest_cpus)
    tsc_khz = parse_positive_int(
        os.environ.get("STEALTH_KVM_TSC_KHZ", ""),
        "STEALTH_KVM_TSC_KHZ",
        100_000_000,
    )
    tsc_mhz = (tsc_khz + 500) // 1000
    max_mhz = detect_max_mhz(cpuinfo, tsc_mhz)
    phys_bits = detect_phys_bits(cpuinfo)
    current_mhz = min(max_mhz, tsc_mhz)
    fingerprint_source = "\0".join(
        str(value)
        for value in (
            vendor, brand, family, model, stepping, cores, online_threads,
            max_mhz, phys_bits, tsc_khz, guest_cores, guest_cpus,
        )
    )
    fingerprint = hashlib.sha256(fingerprint_source.encode("utf-8")).hexdigest()
    return {
        "vendor": vendor,
        "brand": brand,
        "family": family,
        "model": model,
        "stepping": stepping,
        "cores": cores,
        "online_threads": online_threads,
        "guest_cores": guest_cores,
        "max_mhz": max_mhz,
        "current_mhz": current_mhz,
        "phys_bits": phys_bits,
        "guest_phys_bits": min(phys_bits, 52),
        "tsc_khz": tsc_khz,
        "tsc_mhz": tsc_mhz,
        "fingerprint": fingerprint,
    }
