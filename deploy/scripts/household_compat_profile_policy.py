#!/usr/bin/env python3
"""锁定家用整机 profile 的主板、内存、设备与固件事实。"""

from __future__ import annotations

import hashlib
import json
from typing import Any


# 摘要覆盖完整 platform_profile：主板/PCH/PCIe、DDR 类型与容量、启动盘能力、
# PCI 设备、BIOS、系统、TPM 和官方证据链接必须作为一套不可交换事实维护。
EXPECTED_PROFILE_FACT_DIGESTS = {
    "asus-p8h61-m-le-usb3-ddr3": "954cd7d153db16da8d50bf294e6a793273107a8ae29a9e59ff6ac1b7d5b1bda6",
    "asus-p8b75-m-ddr3": "e6820012d3702ba4afef536ebe39f51f054544ba92d1d9e86d62c2f04eeb53c5",
    "asus-h81m-k-ddr3": "30b75061e65c8ef48ab3352e006782cc8ad93475ee2f48d06955824a57f27644",
    "asus-m5a78l-m-usb3-ddr3": "63cf67557a908933c53312c9bef852b17215c0e65720885a03cdcba2cc659506",
    "asus-prime-b350-plus-ddr4": "cb4ef60b70c109533b37ba96937972e683c96664b2f9f90d2c9027635b52bb3f",
    "asus-prime-b350-plus-athlon-ddr4": "ef2ac365e057d4cfc2fcc7ab93fa92153a2f6ee8b251f307b7a5ef2af3dd03ac",
    "asus-p8b75-m-g2020-ddr3-1333": "bae2ce4ef9f6ada6b08faddd199ae7881c7b6b09c47504f11660b44a2580d379",
    "asus-h81m-k-g3220-ddr3-1333": "0d887baf2c638add45027c356a174ffa9323b87939ee023b2641e08ed2b71591",
}


def validate_profile_facts(
    profile: dict[str, Any],
    where: str,
) -> None:
    """把 profile ID 与完整、已审核的配套事实做稳定摘要绑定。"""
    profile_id = profile.get("id")
    expected = EXPECTED_PROFILE_FACT_DIGESTS.get(profile_id)
    if expected is None:
        raise ValueError(f"{where}.id 没有经审核的整机事实摘要")
    canonical = json.dumps(
        profile,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    actual = hashlib.sha256(canonical).hexdigest()
    if actual != expected:
        raise ValueError(
            f"{where} 偏离已审计主板/内存/设备/固件事实："
            f"actual_digest={actual} expected_digest={expected}"
        )
