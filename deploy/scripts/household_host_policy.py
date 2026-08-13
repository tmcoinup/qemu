#!/usr/bin/env python3
"""锁定家用 CPU 目录的物理宿主分类与精确型号边界。"""

from __future__ import annotations

from typing import Any


HOST_CLASS_KEYS = {
    "id", "vendor_id", "cpuid_families", "cpuid_models",
    "brand_names", "guest_generations",
}

# 顺序属于分类策略的一部分：Ryzen 7 5800 的精确规则必须先于覆盖整个
# Family 19h 的 amd-zen 通配规则，否则正常池会永远无法命中。
EXPECTED_HOST_CLASSES: tuple[tuple[str, tuple[Any, ...]], ...] = (
    ("e5-v1", ("GenuineIntel", [6], [45], [], ["sandy-bridge"])),
    ("e5-v2", ("GenuineIntel", [6], [62], [], ["ivy-bridge"])),
    ("e5-v3", ("GenuineIntel", [6], [63], [], ["haswell"])),
    ("e5-v4", ("GenuineIntel", [6], [79], [], ["haswell"])),
    ("amd-k10", ("AuthenticAMD", [16], [2, 4, 5, 6, 8, 10], [], ["k10"])),
    (
        "amd-ryzen7-5800",
        (
            "AuthenticAMD", [25], [33],
            ["AMD Ryzen 7 5800 8-Core Processor"], ["zen"],
        ),
    ),
    ("amd-zen", ("AuthenticAMD", [23, 25, 26], [], [], ["zen"])),
)


def _fail(message: str) -> None:
    """使用与主清单校验器一致的异常类型，保留清晰的调用方诊断。"""
    raise ValueError(message)


def _exact(mapping: dict[str, Any], where: str) -> None:
    """拒绝未知或缺失字段，避免宿主型号门禁因拼写错误而静默放宽。"""
    if set(mapping) != HOST_CLASS_KEYS:
        _fail(
            f"{where} 字段集合错误："
            f"missing={sorted(HOST_CLASS_KEYS - set(mapping))} "
            f"unknown={sorted(set(mapping) - HOST_CLASS_KEYS)}"
        )


def validate_host_classes(value: Any, where: str) -> dict[str, dict[str, Any]]:
    """校验完整、有序的宿主分类，并返回按稳定 ID 建立的索引视图。"""
    if not isinstance(value, list):
        _fail(f"{where} 必须是数组")
    expected_ids = [item[0] for item in EXPECTED_HOST_CLASSES]
    actual_ids = [item.get("id") if isinstance(item, dict) else None for item in value]
    if actual_ids != expected_ids:
        _fail(f"{where} 顺序或覆盖范围错误：actual={actual_ids!r}")

    classes: dict[str, dict[str, Any]] = {}
    for index, (host, expected_entry) in enumerate(zip(value, EXPECTED_HOST_CLASSES)):
        item_where = f"{where}[{index}]"
        if not isinstance(host, dict):
            _fail(f"{item_where} 必须是对象")
        _exact(host, item_where)
        host_id, expected = expected_entry
        actual = (
            host["vendor_id"], host["cpuid_families"], host["cpuid_models"],
            host["brand_names"], host["guest_generations"],
        )
        if host["id"] != host_id or actual != expected:
            _fail(f"{item_where} CPUID、品牌串或代际映射被篡改")
        classes[host_id] = host
    return classes


def classify_host_class(
    classes: list[dict[str, Any]],
    vendor: str,
    family: int,
    model: int,
    brand_name: str = "",
) -> str:
    """按受审计顺序分类；带品牌白名单的规则必须同时精确命中品牌串。"""
    for host in classes:
        model_matches = not host["cpuid_models"] or model in host["cpuid_models"]
        brand_matches = not host["brand_names"] or brand_name in host["brand_names"]
        if (
            host["vendor_id"] == vendor
            and family in host["cpuid_families"]
            and model_matches
            and brand_matches
        ):
            return str(host["id"])
    raise ValueError(
        "宿主 CPUID 没有受控家用兜底分类: "
        f"vendor={vendor} family={family} model={model} brand={brand_name!r}"
    )
