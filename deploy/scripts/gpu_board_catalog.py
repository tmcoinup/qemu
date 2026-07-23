#!/usr/bin/env python3
"""校验并投影独立的 AIB 显卡目录。

物理显示设备始终保持 virtio 1AF4:1050。本目录中的真实主 ID、板卡 subsystem、
料号和 VBIOS 只用于稳定 profile 与客机用户态浅层投影；carrier 是 Red Hat
subsystem 下的内部选择令牌，不能解释成真实 AIB PCI subsystem。
"""

from __future__ import annotations

import json
import pathlib
import re
import sys
from typing import Any

from gpu_board_facts import (
    AUDITED_FACTS,
    EXPECTED_CHIP_PARTNERS,
    FACT_KEYS,
    IDENTITY_HOSTS,
    SOURCE_HOSTS,
)


HEX16 = re.compile(r"^0x[0-9A-Fa-f]{4}$")
HEX8 = re.compile(r"^0x[0-9A-Fa-f]{2}$")
ID_PATTERN = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*")
BOARD_FIELDS = {
    "id", "enabled", "selection_weight", "release_year", "manufacturer",
    "board_partner", "model", "part_number", "pci_vendor", "pci_device",
    "subsystem_vendor", "subsystem_device", "carrier_vendor",
    "carrier_device", "ram_mb", "bios", "revision", "memory_type",
    "memory_bus_width_bits", "base_clock_khz", "boost_clock_khz",
    "memory_clock_khz", "sli_supported", "verification_status",
    "identity_fidelity", "serial_exposed", "source_refs",
    "identity_source_refs",
}
LEGACY_FIELDS = {
    "id", "enabled", "selection_weight", "manufacturer", "model",
    "pci_vendor", "pci_device", "ram_mb", "bios", "revision",
    "memory_type", "memory_bus_width_bits", "base_clock_khz",
    "boost_clock_khz", "memory_clock_khz", "sli_supported",
    "identity_fidelity",
}

def fail(message: str) -> None:
    """输出与旧 shell loader 一致的 fail-closed 错误。"""
    print(f"ERROR: GPU board catalog: {message}", file=sys.stderr)
    raise SystemExit(1)


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    """重复键会覆盖 PCI/ROM 身份字段，因此解析阶段直接拒绝。"""
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            fail(f"JSON 含重复字段 {key}")
        result[key] = value
    return result


def load_json(path: pathlib.Path, label: str) -> dict[str, Any]:
    """只接受没有重复字段的 UTF-8 JSON 对象。"""
    try:
        value = json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=reject_duplicate_keys,
        )
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"无法读取 {label} {path}: {exc}")
    if not isinstance(value, dict):
        fail(f"{label} 根节点不是对象")
    return value


def validate_urls(
        value: Any, label: str, minimum: int, allowed_hosts: set[str]) -> None:
    """证据必须达到该类别的最小数量且使用互不重复的 HTTPS 页面。"""
    if (not isinstance(value, list) or len(value) < minimum or
            len(value) != len(set(value))):
        fail(f"{label} 至少需要 {minimum} 个互不重复的来源")
    for url in value:
        match = re.fullmatch(r"https://([^/\s]+)/\S+", url) \
            if isinstance(url, str) else None
        if match is None or match.group(1).lower() not in allowed_hosts:
            fail(f"{label} 含非法或非受控域名的 HTTPS 来源")


def validate_legacy(components: dict[str, Any]) -> list[dict[str, Any]]:
    """旧芯片标签只用于已有 profile 回查，不能混入新 AIB 抽签池。"""
    legacy = components.get("gpus")
    if not isinstance(legacy, list) or not legacy:
        fail("components.gpus 旧兼容目录缺失")
    seen_ids: set[str] = set()
    seen_pci: set[tuple[str, str]] = set()
    for item in legacy:
        if not isinstance(item, dict) or set(item) != LEGACY_FIELDS:
            fail("旧 GPU 标签字段集合无效")
        stable_id = item.get("id")
        pci = (item.get("pci_vendor"), item.get("pci_device"))
        if (not isinstance(stable_id, str) or not ID_PATTERN.fullmatch(stable_id) or
                stable_id in seen_ids or pci in seen_pci):
            fail("旧 GPU 标签 ID 或 PCI 主 ID 重复")
        if (item.get("identity_fidelity") != "label_only_out_of_scope" or
                any(not isinstance(value, str) or not HEX16.fullmatch(value)
                    for value in pci)):
            fail(f"旧 GPU 标签 {stable_id} 的兼容边界无效")
        seen_ids.add(stable_id)
        seen_pci.add(pci)
    return legacy


def validate_boards(root: dict[str, Any]) -> list[dict[str, Any]]:
    """返回已启用且完整通过原子事实校验的板卡。"""
    if (root.get("schema_version") != 1 or
            root.get("scope") != "shallow_user_projection_no_gpu_passthrough" or
            not isinstance(root.get("catalog_revision"), str)):
        fail("schema、revision 或无直通 scope 无效")
    raw_boards = root.get("boards")
    if not isinstance(raw_boards, list) or len(raw_boards) != len(AUDITED_FACTS):
        fail("板卡集合必须与已核验事实集合完全一致")
    seen_ids: set[str] = set()
    seen_subsystems: set[tuple[str, str, str, str]] = set()
    seen_carriers: set[tuple[str, str]] = set()
    seen_part_numbers: set[tuple[str, str]] = set()
    chip_partners: dict[tuple[str, str], set[str]] = {}
    enabled: list[dict[str, Any]] = []
    for board in raw_boards:
        if not isinstance(board, dict) or set(board) != BOARD_FIELDS:
            fail("板卡条目字段集合不完整或包含未知字段")
        stable_id = board.get("id")
        if (not isinstance(stable_id, str) or not ID_PATTERN.fullmatch(stable_id) or
                stable_id in seen_ids or stable_id not in AUDITED_FACTS):
            fail("板卡稳定 ID 为空、重复、非法或未核验")
        actual = tuple(board.get(key) for key in FACT_KEYS)
        if actual != AUDITED_FACTS[stable_id]:
            fail(f"{stable_id} 的型号、PCI、ROM、显存或时钟原子组合被改写")
        if board.get("enabled") is not True:
            fail(f"{stable_id} 必须启用")
        if board.get("identity_fidelity") != (
                "audited_aib_bundle_shallow_user_projection_no_passthrough"):
            fail(f"{stable_id} 的浅层/无直通证据边界无效")
        if board.get("serial_exposed") is not False:
            fail(f"{stable_id} 不得虚构未标准化的 Guest GPU 序列号")
        for field in ("pci_vendor", "pci_device", "subsystem_vendor",
                      "subsystem_device", "carrier_vendor", "carrier_device"):
            if not isinstance(board[field], str) or not HEX16.fullmatch(board[field]):
                fail(f"{stable_id}.{field} 不是四位 PCI 十六进制值")
        if not HEX8.fullmatch(board["revision"]):
            fail(f"{stable_id}.revision 不是八位 revision")
        if board["carrier_vendor"].upper() != "0X1AF4":
            fail(f"{stable_id} carrier 必须保留 virtio subsystem vendor")
        subsystem = tuple(board[key] for key in (
            "pci_vendor", "pci_device", "subsystem_vendor", "subsystem_device"))
        carrier = (board["carrier_vendor"], board["carrier_device"])
        part_number = (board["board_partner"].casefold(),
                       board["part_number"].casefold())
        if (subsystem in seen_subsystems or carrier in seen_carriers or
                part_number in seen_part_numbers):
            fail(f"{stable_id} 的完整 subsystem、carrier 或品牌料号重复")
        for field in ("manufacturer", "board_partner", "model", "part_number",
                      "bios", "memory_type"):
            value = board[field]
            if (not isinstance(value, str) or not value.isascii() or not value or
                    any(char in value for char in "|,\r\n")):
                fail(f"{stable_id}.{field} 不是安全 ASCII 行字段")
        if (not board["model"].startswith(board["manufacturer"] + " ") or
                len(board["model"]) > 63 or board["memory_type"] != "GDDR5" or
                board["boost_clock_khz"] < board["base_clock_khz"] or
                board["sli_supported"] != 0):
            fail(f"{stable_id} 的名称、显存、时钟或 SLI 约束无效")
        # 部分国内旧型号只有一个仍在线的官方产品页，不能用厂商首页凑第二份规格。
        validate_urls(
            board["source_refs"], f"{stable_id}.source_refs", 1,
            SOURCE_HOSTS[stable_id],
        )
        validate_urls(board["identity_source_refs"],
                      f"{stable_id}.identity_source_refs", 2,
                      IDENTITY_HOSTS[stable_id])
        chip = (board["pci_vendor"], board["pci_device"])
        chip_partners.setdefault(chip, set()).add(board["board_partner"])
        seen_ids.add(stable_id)
        seen_subsystems.add(subsystem)
        seen_carriers.add(carrier)
        seen_part_numbers.add(part_number)
        enabled.append(board)
    if chip_partners != EXPECTED_CHIP_PARTNERS:
        fail("六个芯片型号必须各自精确包含三个不同的已核验板卡品牌")
    expected_carriers = {
        ("0x1AF4", f"0x{value:04X}")
        for value in range(0xA101, 0xA113)
    }
    if seen_carriers != expected_carriers:
        fail("AIB carrier 必须连续且精确占用 0xA101..0xA112")
    return enabled


def print_row(board: dict[str, Any]) -> None:
    """输出 21 列稳定 ABI：ID + 原 13 列 + AIB/真实 subsystem/carrier。"""
    keys = (
        "id", "manufacturer", "model", "pci_vendor", "pci_device", "ram_mb",
        "bios", "revision", "memory_type", "memory_bus_width_bits",
        "base_clock_khz", "boost_clock_khz", "memory_clock_khz",
        "sli_supported", "board_partner", "part_number", "subsystem_vendor",
        "subsystem_device", "carrier_vendor", "carrier_device",
        "identity_fidelity",
    )
    print("|".join(str(board[key]) for key in keys))


def print_legacy_row(item: dict[str, Any]) -> None:
    """旧 profile 仅按原 13 列 label ABI 回查，不进入新板卡抽签池。"""
    keys = (
        "manufacturer", "model", "pci_vendor", "pci_device", "ram_mb",
        "bios", "revision", "memory_type", "memory_bus_width_bits",
        "base_clock_khz", "boost_clock_khz", "memory_clock_khz",
        "sli_supported",
    )
    print("|".join(str(item[key]) for key in keys))


def main() -> None:
    """加载两个目录并执行 shell/PowerShell 共用的只读投影操作。"""
    if len(sys.argv) < 4:
        fail("参数不足")
    components_path = pathlib.Path(sys.argv[1])
    board_path = pathlib.Path(sys.argv[2])
    operation = sys.argv[3]
    components = load_json(components_path, "component manifest")
    if components.get("gpu_board_catalog") != board_path.name:
        fail("components.json 未精确引用所加载的板卡目录")
    legacy = validate_legacy(components)
    root = load_json(board_path, "board manifest")
    boards = validate_boards(root)
    if operation == "validate":
        print(root["catalog_revision"])
    elif operation == "rows":
        for board in boards:
            print_row(board)
    elif operation == "weights":
        for board in boards:
            print(f"{board['id']}|{board['selection_weight']}")
    elif operation == "id":
        wanted = sys.argv[4] if len(sys.argv) == 5 else ""
        matched = [board for board in boards if board["id"] == wanted]
        if len(matched) != 1:
            fail("未知、缺失或不唯一的 AIB GPU 稳定 ID")
        print_row(matched[0])
    elif operation == "legacy-rows":
        for item in legacy:
            print_legacy_row(item)
    elif operation == "legacy-index":
        for item in legacy:
            print(f"{item['id']}|", end="")
            print_legacy_row(item)
    elif operation == "legacy-id":
        wanted = sys.argv[4] if len(sys.argv) == 5 else ""
        matched = [item for item in legacy if item["id"] == wanted]
        if len(matched) != 1:
            fail("未知、缺失或不唯一的旧 GPU label 稳定 ID")
        print_legacy_row(matched[0])
    else:
        fail(f"未知操作: {operation}")


if __name__ == "__main__":
    main()
