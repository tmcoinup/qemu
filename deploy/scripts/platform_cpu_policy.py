#!/usr/bin/env python3
"""锁定默认平台目录中已审计家用 CPU 的完整身份。"""

from __future__ import annotations

import hashlib
import json
import re
from typing import Any

from board_vendor_policy import board_vendor_for


ASUS_H310_CPU_SOURCE = (
    "https://www.asus.com/supportonly/prime%20h310m-a%20r2.0/helpdesk_cpu/"
)
ASUS_H310_MANUAL_SOURCE = (
    "https://dlcdnets.asus.com/pub/ASUS/mb/LGA1151/PRIME_H310M-A_R2.0/"
    "E15471_PRIME_H310M-A_R2.0_UM_V2_WEB.pdf"
)
MSI_H310_SPEC_SOURCE = (
    "https://www.msi.com/Motherboard/H310M-PRO-M2-plus/Specification"
)
MSI_H310_MANUAL_SOURCE = (
    "https://download-2.msi.com/archive/mnu_exe/mb/H310MPRO-M2PLUS100x150.pdf"
)
GIGABYTE_H310_SPEC_SOURCE = (
    "https://www.gigabyte.com/Motherboard/H310M-S2H-20-rev-10/sp"
)
GIGABYTE_H310_SUPPORT_SOURCE = (
    "https://www.gigabyte.com/Motherboard/H310M-S2H-20-rev-10/support"
)
GIGABYTE_H310_MANUAL_SOURCE = (
    "https://download.gigabyte.com/FileList/Manual/mb_manual_h310m-s2h-20_e.pdf"
)
INTEL_CPUID_SOURCE = (
    "https://www.intel.com/content/www/us/en/support/topics/"
    "support-and-servicing-for-processors.html"
)
LOW_END_DISABLED = {
    "adx": "off",
    "avx": "off",
    "avx2": "off",
    "bmi1": "off",
    "bmi2": "off",
    "f16c": "off",
    "fma": "off",
    "hle": "off",
    "rtm": "off",
}
H310_BOARD_SOURCES = {
    "PRIME H310M-A R2.0": {
        ASUS_H310_CPU_SOURCE,
        ASUS_H310_MANUAL_SOURCE,
    },
    "H310M PRO-M2 PLUS (MS-7C08)": {
        MSI_H310_SPEC_SOURCE,
        MSI_H310_MANUAL_SOURCE,
    },
    "H310M S2H 2.0": {
        GIGABYTE_H310_SPEC_SOURCE,
        GIGABYTE_H310_SUPPORT_SOURCE,
        GIGABYTE_H310_MANUAL_SOURCE,
    },
}

# 摘要覆盖 CPU 对象的全部字段和嵌套对象，而不只是当前结构校验显式引用的字段。
# 这样即使某组变异仍分别落在合法范围内，也不能在未重新审计的情况下改变型号事实。
# 规范化规则固定为 UTF-8、对象键排序、无多余空白；目录格式化不会影响摘要。
AUDITED_PLATFORM_CPU_SHA256 = {
    "amd-am4-r3-1200-asus-prime-b350-plus":
        "84f1fa66413a242673d00aef0106c1824f6e02c2806b8038c560fa07a8634921",
    "intel-lga1151-i3-9100f-asus-prime-h310m-a-r2":
        "5d9bc9b2b5cc234480f0ff76cd631c677381d533bda4e3c1b28b595edb26f2ca",
    "intel-lga1151-celeron-g4900-asus-prime-h310m-a-r2":
        "e87d1f9afcc18cf11f30144d2656eeb17169d1401e1c16c68ca0b52c7358fb1f",
    "intel-lga1151-pentium-g5400-asus-prime-h310m-a-r2":
        "4ea617abcb7c704f85620dfe7213649b75f1bc12b295852467cc3c7b2ac3f85f",
    "intel-lga1151-i5-6400t-asus-h110m-a-m2":
        "fdc21df52674cba0d5265650de679d015eca64eab499f8fa73b36d90833a0d05",
    "intel-lga1151-i3-9100f-msi-h310m-pro-m2-plus-ms-7c08":
        "5d9bc9b2b5cc234480f0ff76cd631c677381d533bda4e3c1b28b595edb26f2ca",
    "intel-lga1151-pentium-g5400-gigabyte-h310m-s2h-2":
        "4ea617abcb7c704f85620dfe7213649b75f1bc12b295852467cc3c7b2ac3f85f",
}

# CPU 摘要之外再覆盖完整 platform：主板/PCH/PCIe、内存能力、BIOS、设备、
# TPM 与来源必须作为一个不可拆换的审计组合。否则多个字段即使各自格式合法，
# 仍可能拼出从未存在或从未验证的“正常池”整机。
AUDITED_PLATFORM_FACT_SHA256 = {
    "amd-am4-r3-1200-asus-prime-b350-plus":
        "757d15fd34ac35f18f25a942927cbbca6c59841e20943ab22fc968ba444cd39a",
    "intel-lga1151-i3-9100f-asus-prime-h310m-a-r2":
        "1f58f507c35467b4077cf08fc4dcc86436dbc9afe398b3aa362efe24a5e1b4b4",
    "intel-lga1151-celeron-g4900-asus-prime-h310m-a-r2":
        "8d7f28197663843f8fabc00242e84c2aeb050e28aac237dd495a799c5447b03a",
    "intel-lga1151-pentium-g5400-asus-prime-h310m-a-r2":
        "673eb67d821cf69e93411346bd96a9c33e0223899ec22cc106edc1cf8fde698f",
    "intel-lga1151-i5-6400t-asus-h110m-a-m2":
        "6377296b2e95c3b20382b1473c780e73b0e1fa66d4de78a02fcef5a125779c0c",
    "intel-lga1151-i3-9100f-msi-h310m-pro-m2-plus-ms-7c08":
        "4ecc3a224c534a529366f773e3cf6715a4974423d28c54f29daca1dfa8750215",
    "intel-lga1151-pentium-g5400-gigabyte-h310m-s2h-2":
        "67e9940f1881fc4bc0acb4cd6423ced4c202fb4b458fa66bf1768d0277aadd54",
}

# Intel ARK、Intel ordering、Intel CPUID guidance 与各板厂支持资料共同固化这些值。
# 映射刻意包含所有 H310 原子 bundle；新增主板或 SKU 必须先扩展审计表。
AUDITED_H310_CPUS: dict[str, dict[str, Any]] = {
    "intel-lga1151-celeron-g4900-asus-prime-h310m-a-r2": {
        "release_year": 2018,
        "name": "Intel(R) Celeron(R) G4900 CPU @ 3.10GHz",
        "part": "BX80684G4900",
        "frequency": (3100, 3100, 3100),
        "topology": (2, 2),
        "cpuid": (6, 158, 11),
        "smbios": ("0x00C7", "0x00EC"),
        "igpu": {
            "present": True,
            "profile_state": "disabled_in_bios",
            "model": "Intel UHD Graphics 610",
        },
        "overrides": LOW_END_DISABLED,
        "cpu_source": (
            "https://www.intel.com/content/www/us/en/products/sku/129487/"
            "intel-celeron-g4900-processor-2m-cache-3-10-ghz/specifications.html"
        ),
    },
    "intel-lga1151-pentium-g5400-asus-prime-h310m-a-r2": {
        "release_year": 2018,
        "name": "Intel(R) Pentium(R) Gold G5400 CPU @ 3.70GHz",
        "part": "BX80684G5400",
        "frequency": (3700, 3700, 3700),
        "topology": (2, 4),
        "cpuid": (6, 158, 11),
        "smbios": ("0x000B", "0x00FC"),
        "igpu": {
            "present": True,
            "profile_state": "disabled_in_bios",
            "model": "Intel UHD Graphics 610",
        },
        "overrides": LOW_END_DISABLED,
        "cpu_source": (
            "https://www.intel.com/content/www/us/en/products/sku/129951/"
            "intel-pentium-gold-g5400-processor-4m-cache-3-70-ghz/"
            "specifications.html"
        ),
    },
    "intel-lga1151-i3-9100f-asus-prime-h310m-a-r2": {
        "release_year": 2019,
        "name": "Intel(R) Core(TM) i3-9100F CPU @ 3.60GHz",
        "part": "BX80684I39100F",
        "frequency": (4200, 3600, 3600),
        "topology": (4, 4),
        "cpuid": (6, 158, 11),
        "smbios": ("0x00CE", "0x00EC"),
        "igpu": {
            "present": False,
            "profile_state": "fused_off",
            "model": "none",
        },
        "overrides": {"hle": "off", "rtm": "off"},
        "cpu_source": (
            "https://www.intel.com/content/www/us/en/products/sku/190886/"
            "intel-core-i39100f-processor-6m-cache-up-to-4-20-ghz/"
            "specifications.html"
        ),
    },
}
AUDITED_H310_CPUS.update({
    "intel-lga1151-i3-9100f-msi-h310m-pro-m2-plus-ms-7c08":
        AUDITED_H310_CPUS[
            "intel-lga1151-i3-9100f-asus-prime-h310m-a-r2"
        ],
    "intel-lga1151-pentium-g5400-gigabyte-h310m-s2h-2":
        AUDITED_H310_CPUS[
            "intel-lga1151-pentium-g5400-asus-prime-h310m-a-r2"
        ],
})


def validate_platform_fact_digests(platform: dict[str, Any], where: str) -> None:
    """按平台 ID 比对 CPU 子对象与完整整机对象的稳定审计摘要。"""
    platform_id = platform["id"]
    expected = AUDITED_PLATFORM_CPU_SHA256.get(platform_id)
    if expected is None:
        raise ValueError(f"{where}.cpu 尚未进入完整 CPU 摘要审计表")
    canonical = json.dumps(
        platform["cpu"],
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    actual = hashlib.sha256(canonical).hexdigest()
    if actual != expected:
        raise ValueError(
            f"{where}.cpu 完整审计摘要不匹配：actual={actual} expected={expected}"
        )
    expected_platform = AUDITED_PLATFORM_FACT_SHA256.get(platform_id)
    if expected_platform is None:
        raise ValueError(f"{where} 尚未进入完整整机摘要审计表")
    canonical_platform = json.dumps(
        platform,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    actual_platform = hashlib.sha256(canonical_platform).hexdigest()
    if actual_platform != expected_platform:
        raise ValueError(
            f"{where} 完整整机审计摘要不匹配："
            f"actual={actual_platform} expected={expected_platform}"
        )


def _parse_qemu_arg(qemu_arg: str, where: str) -> tuple[str, dict[str, str]]:
    tokens = qemu_arg.split(",")
    if not tokens or not tokens[0]:
        raise ValueError(f"{where}.cpu.qemu_arg 缺少基型")
    properties: dict[str, str] = {}
    for token in tokens[1:]:
        if "=" not in token:
            raise ValueError(f"{where}.cpu.qemu_arg 属性 {token!r} 必须是 key=value")
        key, value = token.split("=", 1)
        if not key or not value or key in properties:
            raise ValueError(f"{where}.cpu.qemu_arg 属性 {key!r} 非法或重复")
        properties[key] = value
    return tokens[0], properties


def platform_identity_id(cpu: dict[str, Any], board: dict[str, Any]) -> str:
    """由 CPU 系列、socket、注册厂商和主板型号生成稳定目录 ID。"""
    name = cpu["name"]
    if cpu["vendor_id"] == "AuthenticAMD":
        match = re.search(r"\bRyzen\s+(\d+)\s+([0-9A-Za-z]+)\b", name)
        vendor_token = "amd"
        cpu_token = f"r{match.group(1)}-{match.group(2).lower()}" if match else ""
    else:
        vendor_token = "intel"
        core = re.search(r"\bCore\(TM\)\s+i(\d)-([0-9A-Za-z]+)\b", name)
        celeron = re.search(r"\bCeleron\(R\)\s+([A-Z]\d+)\b", name)
        pentium = re.search(r"\bPentium\(R\)\s+Gold\s+([A-Z]\d+)\b", name)
        if core:
            cpu_token = f"i{core.group(1)}-{core.group(2).lower()}"
        elif celeron:
            cpu_token = f"celeron-{celeron.group(1).lower()}"
        elif pentium:
            cpu_token = f"pentium-{pentium.group(1).lower()}"
        else:
            cpu_token = ""
    if not cpu_token:
        raise ValueError(f"无法从 CPU 名称生成平台系列 ID：{name}")
    board_vendor_token = board_vendor_for(board["manufacturer"])["platform_token"]
    product = re.sub(r"\.0\b", "", board["product"]).replace(".", "")
    board_token = re.sub(r"[^a-z0-9]+", "-", product.lower()).strip("-")
    return "-".join((
        vendor_token, cpu["socket"].lower(), cpu_token, board_vendor_token,
        board_token,
    ))


def validate_h310_cpu_policy(platform: dict[str, Any], where: str) -> None:
    """严格校验 H310 家用 SKU，防止 QEMU Skylake 基型多报能力。"""
    board = platform["board"]
    if board["pch"] != "Intel H310":
        return
    board_sources = H310_BOARD_SOURCES.get(board["product"])
    if board_sources is None:
        raise ValueError(f"{where} 的 H310 主板尚未进入原子组合审计表")
    platform_id = platform["id"]
    if platform_id not in AUDITED_H310_CPUS:
        raise ValueError(f"{where} 的 H310 CPU 尚未进入严格审计表")
    expected = AUDITED_H310_CPUS[platform_id]
    cpu = platform["cpu"]
    smbios = cpu["smbios"]
    actual_facts = {
        "release_year": platform["release_year"],
        "name": cpu["name"],
        "part": cpu["part"],
        "frequency": (cpu["max_mhz"], cpu["current_mhz"], cpu["tsc_mhz"]),
        "topology": (cpu["cores"], cpu["threads"]),
        "smbios": (smbios["family"], smbios["characteristics"]),
        "igpu": cpu["integrated_gpu"],
    }
    for key, actual in actual_facts.items():
        if actual != expected[key]:
            raise ValueError(
                f"{where}.{key} 偏离官方 H310/SKU 审计值："
                f"actual={actual!r} expected={expected[key]!r}"
            )
    if (
        platform["enabled"] is not True
        or platform["status"] != "supported"
        or cpu["vendor_id"] != "GenuineIntel"
        or cpu["socket"] != "LGA1151"
        or cpu["phys_bits"] != 39
        or cpu["features"] != "+invtsc,+tsc-deadline"
    ):
        raise ValueError(f"{where} 的 supported Intel/LGA1151 基础字段被篡改")
    memory = platform["memory"]
    if (
        memory["type"],
        memory["channels"],
        memory["max_mts"],
        memory["allowed_mts"],
        memory["voltage_mv"],
    ) != ("DDR4", 2, 2400, [2133, 2400], 1200):
        raise ValueError(f"{where}.memory 不是该 CPU 官方 DDR4-2400 组合")

    base, properties = _parse_qemu_arg(cpu["qemu_arg"], where)
    family, model, stepping = expected["cpuid"]
    identity = {
        "family": str(family),
        "model": str(model),
        "stepping": str(stepping),
        "model-id": expected["name"],
    }
    expected_properties = {**identity, **expected["overrides"]}
    if base != "Skylake-Client-IBRS" or properties != expected_properties:
        raise ValueError(
            f"{where}.cpu.qemu_arg 未精确关闭该 SKU 缺失能力："
            f"actual={properties!r} expected={expected_properties!r}"
        )
    required_sources = {
        expected["cpu_source"],
        INTEL_CPUID_SOURCE,
    } | board_sources
    if not required_sources <= set(platform["source_refs"]):
        raise ValueError(f"{where}.source_refs 缺少 Intel/主板厂商官方组合证据")
