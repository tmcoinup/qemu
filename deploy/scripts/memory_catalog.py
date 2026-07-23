#!/usr/bin/env python3
"""共享 DIMM 目录的严格校验与 Linux 安全投影。

``module-plans`` 行协议固定为竖线分隔的 15 列，按权重降序、family ID
升序输出：family_id、module_id、manufacturer、type、part_number、
rated_mts、configured_mts、voltage_mv、allowed_sockets(CSV)、rank、
device_width_bits、module_mib、module_count、selection_weight、spd_ee1004(0/1)。
"""

from __future__ import annotations

import json
import re
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any, Iterable


class CatalogError(ValueError):
    """目录字段不完整或物理事实自相矛盾。"""


EXPECTED_JEP106 = {
    "Samsung": (("0x80", "0xCE"), ("0x80", "0xCE")),
    "Kingston": (("0x01", "0x98"), None),
    "Crucial": (("0x85", "0x9B"), ("0x80", "0x2C")),
    "SK hynix": (("0x80", "0xAD"), ("0x80", "0xAD")),
}
TOP_KEYS = {"schema_version", "catalog_revision", "serial_policy", "manufacturers", "modules"}
MODULE_KEYS = {
    "id", "family_id", "status", "selection_weight", "manufacturer", "part_number",
    "type", "module_mib", "rated_mts", "voltage_mv", "rank", "device_width_bits",
    "spd_ee1004", "allowed_sockets", "allowed_platform_channel_counts", "source_refs",
}


def fail(message: str) -> None:
    """用统一异常类型返回可测试的目录错误。"""
    raise CatalogError(message)


def require_keys(value: dict[str, Any], expected: set[str], where: str) -> None:
    """拒绝缺字段，也拒绝拼错后无人读取的多余字段。"""
    actual = set(value)
    if actual != expected:
        fail(
            f"{where} 字段不匹配：missing={sorted(expected - actual)} "
            f"extra={sorted(actual - expected)}"
        )


def require_int(value: Any, where: str, minimum: int = 1) -> int:
    """JSON bool 在 Python 中属于 int 子类，必须显式排除。"""
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        fail(f"{where} 必须是大于等于 {minimum} 的 JSON 整数")
    return value


def normalized_jep106(value: Any, where: str) -> tuple[str, str] | None:
    """把 JSON 两字节 JEP106 表达转换为可稳定比较的元组。"""
    if value is None:
        return None
    if (not isinstance(value, list) or len(value) != 2
        or any(not isinstance(item, str) for item in value)
        or any(not re.fullmatch(r"0x[0-9A-F]{2}", item) for item in value)):
        fail(f"{where} 必须是两个大写十六进制字节或 null")
    return value[0], value[1]


def validate_serial_policy(policy: Any) -> None:
    """SPD 序列号是 JEDEC 的四字节字段，不是品牌营销标签字符串。"""
    expected_keys = {
        "id", "field_bytes", "text_encoding", "pattern", "reserved_values",
        "identity_fidelity",
    }
    if not isinstance(policy, dict):
        fail("serial_policy 必须是对象")
    require_keys(policy, expected_keys, "serial_policy")
    if (
        policy["id"] != "jedec-spd-module-serial-u32"
        or policy["field_bytes"] != 4
        or policy["text_encoding"] != "uppercase_hex_big_endian"
        or policy["pattern"] != "^[0-9A-F]{8}$"
        or policy["identity_fidelity"]
        != "synthetic_value_in_real_jedec_spd_field"
    ):
        fail("serial_policy 必须精确表达 JEDEC 四字节 SPD 序列号")
    reserved = policy["reserved_values"]
    if (not isinstance(reserved, list)
            or set(reserved) != {"00000000", "00000001", "FFFFFFFF"}):
        fail("serial_policy.reserved_values 缺少保留序列号")


def validate_manufacturers(manufacturers: Any) -> None:
    """与 hw/i2c/smbus_eeprom_spd.c 的 JEP106 表保持一一对应。"""
    if not isinstance(manufacturers, dict) or set(manufacturers) != set(EXPECTED_JEP106):
        fail("manufacturers 必须恰好覆盖四个已实现 SPD 品牌")
    expected_keys = {"module_jep106", "dram_jep106", "dram_jep106_fidelity"}
    for name, expected in EXPECTED_JEP106.items():
        value = manufacturers[name]
        if not isinstance(value, dict):
            fail(f"manufacturers.{name} 必须是对象")
        require_keys(value, expected_keys, f"manufacturers.{name}")
        module_id = normalized_jep106(
            value["module_jep106"], f"manufacturers.{name}.module_jep106"
        )
        dram_id = normalized_jep106(
            value["dram_jep106"], f"manufacturers.{name}.dram_jep106"
        )
        if (module_id, dram_id) != expected:
            fail(f"manufacturers.{name} 的 JEP106 映射与 C 层不一致")
        if (not isinstance(value["dram_jep106_fidelity"], str)
                or not value["dram_jep106_fidelity"]):
            fail(f"manufacturers.{name}.dram_jep106_fidelity 不能为空")


def validate_module(module: Any, index: int) -> None:
    """校验一根 DIMM 的型号、SPD 几何与平台边界。"""
    where = f"modules[{index}]"
    if not isinstance(module, dict):
        fail(f"{where} 必须是对象")
    require_keys(module, MODULE_KEYS, where)
    for field in ("id", "family_id"):
        value = module[field]
        if (not isinstance(value, str)
                or not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", value)):
            fail(f"{where}.{field} 不是稳定 kebab-case ID")
    if module["status"] not in {"active", "quarantine"}:
        fail(f"{where}.status 只能是 active 或 quarantine")
    weight = require_int(module["selection_weight"], f"{where}.selection_weight", 0)
    if ((module["status"] == "active" and weight == 0)
            or (module["status"] == "quarantine" and weight != 0)):
        fail(f"{where}.selection_weight 与 active/quarantine 状态不一致")
    if module["manufacturer"] not in EXPECTED_JEP106:
        fail(f"{where}.manufacturer 没有 C 层 SPD 映射")
    part = module["part_number"]
    if (not isinstance(part, str) or not part
        or not part.isascii()
        or any(ord(character) < 0x20 or ord(character) > 0x7E for character in part)):
        fail(f"{where}.part_number 必须是可写入 SPD 的 ASCII")
    memory_type = module["type"]
    if memory_type not in {"DDR3", "DDR4"}:
        fail(f"{where}.type 只能是 DDR3 或 DDR4")
    part_limit = 20 if memory_type == "DDR4" else 18
    if len(part) > part_limit:
        fail(f"{where}.part_number 超过 {memory_type} SPD 字段上限")
    if module["module_mib"] not in {2048, 4096}:
        fail(f"{where}.module_mib 当前只允许 2GiB/4GiB 已实现几何")
    rate = require_int(module["rated_mts"], f"{where}.rated_mts")
    voltage = require_int(module["voltage_mv"], f"{where}.voltage_mv")
    if memory_type == "DDR4" and (rate < 2133 or voltage != 1200):
        fail(f"{where} 的 DDR4 速率或电压不成立")
    if memory_type == "DDR3" and (rate > 2133 or voltage != 1500):
        fail(f"{where} 的 DDR3 速率或电压不成立")
    if module["rank"] not in {1, 2, 3, 4}:
        fail(f"{where}.rank 不受 SPD 生成器支持")
    if module["device_width_bits"] not in {4, 8, 16}:
        fail(f"{where}.device_width_bits 不受 SPD 生成器支持")
    if module["spd_ee1004"] is not (memory_type == "DDR4"):
        fail(f"{where}.spd_ee1004 与内存代际不一致")
    sockets = module["allowed_sockets"]
    if (
        not isinstance(sockets, list)
        or not sockets
        or len(set(sockets)) != len(sockets)
        or any(not isinstance(socket, str) or not socket for socket in sockets)
    ):
        fail(f"{where}.allowed_sockets 必须是非空无重复字符串数组")
    if memory_type == "DDR4" and set(sockets) & {
        "AM3",
        "AM3+",
        "FM2+",
        "LGA1150",
        "LGA1155",
    }:
        fail(f"{where} 把 DDR4 绑定到了 DDR3 平台 socket")
    if memory_type == "DDR3" and set(sockets) & {"AM4", "LGA1151", "LGA1200"}:
        fail(f"{where} 把 1.5V DDR3 绑定到了当前 DDR4 平台 socket")
    channels = module["allowed_platform_channel_counts"]
    if (
        not isinstance(channels, list)
        or not channels
        or len(set(channels)) != len(channels)
        or any(channel not in {1, 2, 4} for channel in channels)
    ):
        fail(f"{where}.allowed_platform_channel_counts 非法")
    refs = module["source_refs"]
    if (
        not isinstance(refs, list)
        or not refs
        or any(not isinstance(ref, str) or not ref.startswith("https://") for ref in refs)
    ):
        fail(f"{where}.source_refs 必须包含 HTTPS 资料来源")


def family_groups(catalog: dict[str, Any]) -> dict[str, list[dict[str, Any]]]:
    """按稳定 family_id 聚合 2GiB/4GiB 同系列料号。"""
    groups: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for module in catalog["modules"]:
        groups[module["family_id"]].append(module)
    return dict(groups)


def validate_families(catalog: dict[str, Any]) -> None:
    """同一系列可缺旧 ABI 不需要的容量，但不能重复容量或混合事实。"""
    family_fields = (
        "status",
        "selection_weight",
        "manufacturer",
        "type",
        "rated_mts",
        "voltage_mv",
        "spd_ee1004",
        "allowed_sockets",
        "allowed_platform_channel_counts",
    )
    for family_id, modules in family_groups(catalog).items():
        by_size = {module["module_mib"]: module for module in modules}
        if len(modules) != len(by_size):
            fail(f"family '{family_id}' 包含重复容量")
        first = modules[0]
        for module in modules[1:]:
            for field in family_fields:
                if module[field] != first[field]:
                    fail(f"family '{family_id}' 的 {field} 不是原子事实")


def load_catalog(path: Path | str) -> dict[str, Any]:
    """读取并完整验证共享 JSON，成功才返回对象。"""
    try:
        with Path(path).open(encoding="utf-8") as handle:
            catalog = json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        fail(f"无法读取内存目录：{error}")
    if not isinstance(catalog, dict):
        fail("目录顶层必须是对象")
    require_keys(catalog, TOP_KEYS, "catalog")
    if catalog["schema_version"] != 1:
        fail("只支持 memory catalog schema 1")
    revision = catalog["catalog_revision"]
    if (not isinstance(revision, str)
            or not re.fullmatch(r"\d{4}-\d{2}-\d{2}-memory-r[1-9][0-9]*", revision)):
        fail("catalog_revision 格式无效")
    validate_serial_policy(catalog["serial_policy"])
    validate_manufacturers(catalog["manufacturers"])
    modules = catalog["modules"]
    if not isinstance(modules, list) or not modules:
        fail("modules 必须是非空数组")
    for index, module in enumerate(modules):
        validate_module(module, index)
    ids = [module["id"] for module in modules]
    parts = [module["part_number"] for module in modules]
    if len(set(ids)) != len(ids) or len(set(parts)) != len(parts):
        fail("DIMM id 与 part_number 必须全局唯一")
    validate_families(catalog)
    return catalog


def iter_families(
    catalog: dict[str, Any], status: str
) -> Iterable[tuple[dict[str, Any], dict[str, Any]]]:
    """按常见品牌优先级和稳定 ID 输出完整物料系列。"""
    pairs = []
    for family_id, modules in family_groups(catalog).items():
        if modules[0]["status"] != status or len(modules) != 2:
            continue
        by_size = {module["module_mib"]: module for module in modules}
        pairs.append((by_size[2048], by_size[4096]))
    return sorted(
        pairs,
        key=lambda pair: (-pair[0]["selection_weight"], pair[0]["family_id"]),
    )


def legacy_row(pair: tuple[dict[str, Any], dict[str, Any]]) -> str:
    """投影为既有九字段 MEM_POOL ABI。"""
    small, large = pair
    return "|".join(
        (
            small["manufacturer"],
            small["part_number"],
            large["part_number"],
            str(small["rated_mts"]),
            ",".join(small["allowed_sockets"]),
            str(small["rank"]),
            str(small["device_width_bits"]),
            str(large["rank"]),
            str(large["device_width_bits"]),
        )
    )


def resolve_family(
    catalog: dict[str, Any],
    status: str,
    manufacturer: str,
    part_2g: str,
    part_4g: str,
    rated_mts: int,
) -> str | None:
    """按旧 profile 的原子四元组解析稳定系列 ID 和两种容量几何。"""
    for small, large in iter_families(catalog, status):
        if (
            small["manufacturer"] == manufacturer
            and small["part_number"] == part_2g
            and large["part_number"] == part_4g
            and small["rated_mts"] == rated_mts
        ):
            return "|".join(
                (
                    small["family_id"],
                    str(small["rank"]),
                    str(small["device_width_bits"]),
                    str(large["rank"]),
                    str(large["device_width_bits"]),
                )
            )
    return None


def platform_plans(
    catalog: dict[str, Any],
    memory_type: str,
    socket: str,
    channels: int,
    voltage_mv: int,
    dimm_slots: int,
    total_mib: int,
    module_mib: set[int],
    allowed_mts: set[int],
    max_mts: int,
    action: str,
    complete_families_only: bool,
) -> list[tuple[list[dict[str, Any]], dict[str, Any], int]]:
    """按 Windows Get-VMateMemoryModulePlans 语义选择实际 DIMM。"""
    if memory_type not in {"DDR3", "DDR4"}:
        fail(f"{action} 的 type 不受支持")
    for value, name in (
        (channels, "channels"),
        (voltage_mv, "voltage_mv"),
        (dimm_slots, "dimm_slots"),
        (total_mib, "total_mib"),
        (max_mts, "max_mts"),
    ):
        require_int(value, f"{action}.{name}")
    if not module_mib or not allowed_mts:
        fail(f"{action} 的容量和速率集合不能为空")
    plans = []
    for modules in family_groups(catalog).values():
        first = modules[0]
        if (
            first["status"] != "active"
            or (complete_families_only and len(modules) != 2)
        ):
            continue
        if (
            first["type"] != memory_type
            or first["voltage_mv"] != voltage_mv
            or channels not in first["allowed_platform_channel_counts"]
            or (socket != "*" and socket not in first["allowed_sockets"])
        ):
            continue
        selected = next((
            module
            for module in sorted(
                modules, key=lambda item: item["module_mib"], reverse=True
            )
            if module["module_mib"] in module_mib
            and total_mib % module["module_mib"] == 0
            and 1 <= total_mib // module["module_mib"] <= dimm_slots
        ), None)
        possible_rates = {
            rate
            for rate in allowed_mts
            if rate <= first["rated_mts"] and rate <= max_mts
        }
        if selected is not None and possible_rates:
            plans.append((modules, selected, max(possible_rates)))
    return sorted(
        plans,
        key=lambda plan: (
            -plan[1]["selection_weight"],
            plan[1]["family_id"],
        ),
    )


def platform_candidate_rows(
    catalog: dict[str, Any], memory_type: str, socket: str, channels: int,
    voltage_mv: int, dimm_slots: int, total_mib: int, module_mib: set[int],
    allowed_mts: set[int], max_mts: int,
) -> list[str]:
    """投影既有十八字段双料号 ABI；不接纳缺少容量兄弟型号的系列。"""
    plans = platform_plans(
        catalog, memory_type, socket, channels, voltage_mv, dimm_slots,
        total_mib, module_mib, allowed_mts, max_mts, "platform-candidates", True,
    )
    rows = []
    for modules, selected, configured_mts in plans:
        by_size = {module["module_mib"]: module for module in modules}
        small, large = by_size[2048], by_size[4096]
        rows.append("|".join((
            small["family_id"], selected["id"], small["manufacturer"], small["type"],
            small["part_number"], large["part_number"], str(small["rated_mts"]),
            str(configured_mts), str(small["voltage_mv"]),
            ",".join(small["allowed_sockets"]), str(small["rank"]),
            str(small["device_width_bits"]), str(large["rank"]),
            str(large["device_width_bits"]), str(selected["module_mib"]),
            str(total_mib // selected["module_mib"]),
            str(small["selection_weight"]), "1" if small["spd_ee1004"] else "0",
        )))
    return rows


def module_plan_rows(
    catalog: dict[str, Any], memory_type: str, socket: str, channels: int,
    voltage_mv: int, dimm_slots: int, total_mib: int, module_mib: set[int],
    allowed_mts: set[int], max_mts: int,
) -> list[str]:
    """投影稳定十五字段实际模块协议，允许 family 只有一个已核验 SKU。"""
    plans = platform_plans(
        catalog, memory_type, socket, channels, voltage_mv, dimm_slots,
        total_mib, module_mib, allowed_mts, max_mts, "module-plans", False,
    )
    return [
        "|".join((
            module["family_id"], module["id"], module["manufacturer"], module["type"],
            module["part_number"], str(module["rated_mts"]), str(configured_mts),
            str(module["voltage_mv"]), ",".join(module["allowed_sockets"]),
            str(module["rank"]), str(module["device_width_bits"]),
            str(module["module_mib"]), str(total_mib // module["module_mib"]),
            str(module["selection_weight"]), "1" if module["spd_ee1004"] else "0",
        ))
        for _, module, configured_mts in plans
    ]


def parse_csv_ints(value: str, where: str) -> set[int]:
    """解析 shell 传入的逗号整数集合，拒绝空项和前后空白。"""
    if not value or any(not item.isdigit() for item in value.split(",")):
        fail(f"{where} 必须是逗号分隔的正整数")
    result = {int(item) for item in value.split(",")}
    if 0 in result:
        fail(f"{where} 不能包含 0")
    return result


def main(argv: list[str]) -> int:
    """CLI 保持简单 TSV/行协议，避免 shell 自己解析 JSON。"""
    if len(argv) < 3:
        print(
            "usage: memory_catalog.py CATALOG "
            "{validate|active-legacy|quarantine-legacy|platform-candidates|module-plans}",
            file=sys.stderr,
        )
        return 2
    catalog = load_catalog(argv[1])
    action = argv[2]
    if action == "validate" and len(argv) == 3:
        print(catalog["catalog_revision"])
        return 0
    if action in {"active-legacy", "quarantine-legacy"} and len(argv) == 3:
        status = action.removesuffix("-legacy")
        for pair in iter_families(catalog, status):
            print(legacy_row(pair))
        return 0
    if action in {"resolve-active", "resolve-quarantine"} and len(argv) == 8:
        status = action.removeprefix("resolve-")
        result = resolve_family(
            catalog, status, argv[3], argv[4], argv[5], int(argv[6])
        )
        expected_family = argv[7]
        if result is None or (expected_family and result.split("|", 1)[0] != expected_family):
            return 1
        print(result)
        return 0
    if action in {"platform-candidates", "module-plans"} and len(argv) == 12:
        row_builder = (
            module_plan_rows if action == "module-plans" else platform_candidate_rows
        )
        rows = row_builder(
            catalog, argv[3], argv[4], int(argv[5]), int(argv[6]), int(argv[7]),
            int(argv[8]),
            parse_csv_ints(argv[9], "module_mib"),
            parse_csv_ints(argv[10], "allowed_mts"),
            int(argv[11]),
        )
        print("\n".join(rows))
        return 0
    print(f"ERROR: action 或参数数量无效：{action}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv))
    except (CatalogError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
