#!/usr/bin/env python3
"""定义 household compatibility 启动盘身份的严格策略。"""

from __future__ import annotations

STORAGE_KEYS = {
    "boot_bus",
    "boot_model",
    "boot_firmware",
    "nvme_role",
    "runtime_switch_required",
    "source_refs",
}
SATA_POOL_MARKER = "storage-compatibility-pool"

# 这些值是逐主板核验后的启动存储能力，不接受清单用一组“彼此自洽”的字段
# 反向改写事实。新增主板必须先在这里登记其板型、芯片组、PCIe 几何和启动能力。
AUDITED_STORAGE_CAPABILITIES = {
    "asus-p8h61-m-le-usb3-ddr3": (
        "P8H61-M LE/USB3", "Intel H61", 2, 2, 4, False, "pcie_add_in",
    ),
    "asus-p8b75-m-ddr3": (
        "P8B75-M", "Intel B75", 3, 2, 4, False, "pcie_add_in",
    ),
    "asus-p8b75-m-g2020-ddr3-1333": (
        "P8B75-M", "Intel B75", 3, 2, 4, False, "pcie_add_in",
    ),
    "asus-h81m-k-ddr3": (
        "H81M-K", "Intel H81", 3, 2, 4, False, "pcie_add_in",
    ),
    "asus-h81m-k-g3220-ddr3-1333": (
        "H81M-K", "Intel H81", 3, 2, 4, False, "pcie_add_in",
    ),
    "asus-m5a78l-m-usb3-ddr3": (
        "M5A78L-M/USB3", "AMD 760G/SB710", 2, 2, 4, False, "pcie_add_in",
    ),
    "asus-prime-b350-plus-ddr4": (
        "PRIME B350-PLUS", "AMD B350", 3, 3, 4, True, "m2_socket",
    ),
    "asus-prime-b350-plus-athlon-ddr4": (
        "PRIME B350-PLUS", "AMD B350", 3, 3, 2, True, "m2_socket",
    ),
}


def validate_storage_policy(
    profile_id: str,
    board: dict[str, object],
    nvme: dict[str, object],
    storage: dict[str, object],
    where: str,
) -> None:
    """校验启动总线、设备身份、固件和证据必须作为一个整体变化。"""
    audited = AUDITED_STORAGE_CAPABILITIES.get(profile_id)
    actual = (
        board.get("product"),
        board.get("pch"),
        board.get("pcie_generation"),
        nvme.get("max_pcie_generation"),
        nvme.get("lanes"),
        nvme.get("boot_supported"),
        nvme.get("attachment"),
    )
    if audited is None or actual != audited:
        raise ValueError(f"{where} 的主板/PCIe/启动能力偏离已核验事实")

    if set(storage) != STORAGE_KEYS:
        raise ValueError(
            f"{where}.storage 字段集合错误："
            f"missing={sorted(STORAGE_KEYS - set(storage))} "
            f"unknown={sorted(set(storage) - STORAGE_KEYS)}"
        )
    if audited[5]:
        expected: dict[str, object] = {
            "boot_bus": "nvme",
            "boot_model": "component",
            "boot_firmware": "component",
            "nvme_role": "boot",
            "runtime_switch_required": False,
            "source_refs": [],
        }
    else:
        expected = {
            "boot_bus": "sata-ahci",
            # 主板清单只声明可实现的总线。具体消费级 SATA SSD 完整组合由独立
            # storage-compatibility.json 选择、持久化和严格重建，避免 CPU/主板
            # 目录复制一份会随扩池而漂移的型号列表。
            "boot_model": SATA_POOL_MARKER,
            "boot_firmware": SATA_POOL_MARKER,
            "nvme_role": "data-only",
            "runtime_switch_required": True,
            "source_refs": [],
        }
    if storage != expected:
        raise ValueError(f"{where}.storage 与启动能力/设备证据不一致")
