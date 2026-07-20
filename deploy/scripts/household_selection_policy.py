#!/usr/bin/env python3
"""定义家用 CPU 目录的默认选择层与整机仿真边界。"""

from __future__ import annotations

from typing import Any


# supported 在本目录中只表示：该家用 named-model 已在对应宿主类上通过运行时
# KVM realize，可作为默认启动候选。QEMU machine 仍是 Q35，不能据此宣称 H81
# 等目标 PCH 的寄存器、BDF 或固件行为已经被完整模拟。
HOUSEHOLD_IDENTITY_SCOPE = "household_cpu_catalog_q35_identity_compatibility"
HOST_SUPPORTED_CLASSES = frozenset({"e5-v3", "e5-v4"})
AUDITED_CANDIDATE_BINDINGS = {
    "compat-sandy-g630-p8h61": ("compatibility", "asus-p8h61-m-le-usb3-ddr3"),
    "compat-sandy-i3-2120-p8h61": ("compatibility", "asus-p8h61-m-le-usb3-ddr3"),
    "compat-sandy-i5-2400-p8h61": ("compatibility", "asus-p8h61-m-le-usb3-ddr3"),
    "compat-ivy-g2020-p8b75": (
        "compatibility", "asus-p8b75-m-g2020-ddr3-1333",
    ),
    "compat-ivy-i3-3220-p8b75": ("compatibility", "asus-p8b75-m-ddr3"),
    "compat-ivy-i5-3470-p8b75": ("compatibility", "asus-p8b75-m-ddr3"),
    "compat-haswell-g3220-h81": (
        "supported", "asus-h81m-k-g3220-ddr3-1333",
    ),
    "compat-haswell-i3-4130-h81": ("supported", "asus-h81m-k-ddr3"),
    "compat-haswell-i5-4570-h81": ("supported", "asus-h81m-k-ddr3"),
    "compat-k10-athlon-ii-x2-250-m5a78l": (
        "compatibility", "asus-m5a78l-m-usb3-ddr3",
    ),
    "compat-k10-phenom-ii-x4-955-m5a78l": (
        "compatibility", "asus-m5a78l-m-usb3-ddr3",
    ),
    "compat-zen-athlon-200ge-b350": (
        "compatibility", "asus-prime-b350-plus-athlon-ddr4",
    ),
    "compat-zen-ryzen3-1200-b350": (
        "compatibility", "asus-prime-b350-plus-ddr4",
    ),
}
ALLOWED_CANDIDATE_STATUS = frozenset({"supported", "compatibility"})

EXPECTED_SELECTION_POLICY: dict[str, Any] = {
    "compatibility_requires_explicit_allow": True,
    "supported_requires_explicit_allow": False,
    "host_supported_classes": ["e5-v3", "e5-v4"],
    "priority": (
        "host_supported_then_static_supported_then_same_generation_"
        "compatibility_then_cross_generation_compatibility"
    ),
    "selection": "uniform_random_exact_threads",
    "guest_threads_must_equal_sku_threads": True,
    "allowed_topologies": ["2C2T", "2C4T", "4C4T"],
    "guest_segment": "household_desktop_only",
    "forbidden_guest_brand_tokens": [
        "Xeon", "E3", "E5", "E7", "Xeon E", "EPYC", "Opteron",
        "Threadripper",
    ],
    "server_brand_host_passthrough": "deny",
    "same_vendor_required": True,
    "cross_generation_compatibility_last_resort": True,
    "cross_generation_keeps_runtime_constraints": True,
    "storage_policy_must_be_honored": True,
    "qemu_realize_required": True,
    "target_pch_behavior": "not_emulated",
}


def validate_candidate_status(
    candidate_id: str,
    status: str,
    host_ids: list[str],
    profile_id: str,
    guest_generation: str,
    memory_type: str,
    where: str,
) -> None:
    """只允许 E5 v3/v4 的受审计 Haswell 家用组进入默认正常层。"""
    if status not in ALLOWED_CANDIDATE_STATUS:
        raise ValueError(f"{where}.status 非法")
    expected_binding = AUDITED_CANDIDATE_BINDINGS.get(candidate_id)
    if expected_binding is None or (status, profile_id) != expected_binding:
        raise ValueError(f"{where} 的状态或 CPU/主板/内存绑定未经审核")
    if status != "supported":
        return
    if (
        set(host_ids) != HOST_SUPPORTED_CLASSES
        or guest_generation != "haswell"
        or memory_type != "DDR3"
    ):
        raise ValueError(
            f"{where} 只有 E5 v3/v4 的 H81/DDR3 Haswell 正常池可标记 supported"
        )
