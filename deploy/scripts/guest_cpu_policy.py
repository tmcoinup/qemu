#!/usr/bin/env python3
"""Guest 家用 CPU 分类的共享硬门禁。"""

from __future__ import annotations

import re


# 品牌词覆盖 Intel/AMD 服务器及工作站系列；E 系列表达式额外覆盖被裁掉
# “Xeon”前缀的 E3/E5/E7 与较新的 Xeon E-2xxx 字符串，避免清单或探针仅靠
# 品牌格式差异绕过。边界刻意不匹配 AMD E-350 这类早期家用 APU。
SERVER_BRAND_RE = re.compile(
    r"\b(?:Xeon|EPYC|Opteron|Threadripper)\b|"
    r"(?<![A-Za-z0-9])E[357][-\s]*[0-9]{3,5}[A-Za-z0-9]*(?![A-Za-z0-9])|"
    r"(?<![A-Za-z0-9])E-[0-9]{4,5}[A-Za-z0-9]*(?![A-Za-z0-9])",
    re.IGNORECASE,
)

INTEL_HOUSEHOLD_RE = re.compile(
    r"\b(?:Core|Pentium|Celeron|Atom)\b|"
    r"Intel\(R\)\s+(?:Processor\s+)?[NU][0-9]{2,4}\b",
    re.IGNORECASE,
)
AMD_HOUSEHOLD_RE = re.compile(
    r"\b(?:Ryzen|Athlon|Phenom|Sempron)\b|"
    r"(?<![A-Za-z0-9])(?:FX|A(?:4|6|8|10|12))-[0-9]",
    re.IGNORECASE,
)
HOUSEHOLD_QEMU_BASES = {
    "SandyBridge-IBRS", "IvyBridge-IBRS", "Haswell-v4",
    "Skylake-Client-IBRS", "phenom", "Ryzen3-1200",
}


def forbidden_server_identity(*values: str) -> bool:
    """CPU 名称或 QEMU model-id 任一含服务器系列即返回真。"""
    return any(SERVER_BRAND_RE.search(value or "") for value in values)


def named_household_qemu_base_allowed(qemu_arg: str) -> bool:
    """只接受已经进入家用目录审计范围的 QEMU named CPU 基型。"""
    return (qemu_arg or "").split(",", 1)[0] in HOUSEHOLD_QEMU_BASES


def household_brand_allowed(vendor_id: str, brand: str) -> bool:
    """只接受能由品牌串正向证明的 Intel/AMD 家用系列。"""
    if forbidden_server_identity(brand):
        return False
    if vendor_id == "GenuineIntel":
        return bool(INTEL_HOUSEHOLD_RE.search(brand))
    if vendor_id == "AuthenticAMD":
        return bool(AMD_HOUSEHOLD_RE.search(brand))
    return False
