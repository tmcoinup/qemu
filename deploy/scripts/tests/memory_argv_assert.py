#!/usr/bin/env python3
"""按共享目录校验 Windows dry-run 的 SMBIOS/SPD 内存原子身份。"""

from __future__ import annotations

import json
import pathlib
import re
import sys


def fail(message: str) -> None:
    raise SystemExit(f"FAIL: {message}")


def keyvals(line: str) -> dict[str, str]:
    result: dict[str, str] = {}
    for token in line.split(",")[1:]:
        if "=" in token:
            key, value = token.split("=", 1)
            result[key] = value
    return result


def main() -> None:
    if len(sys.argv) != 6:
        fail("用法：memory_argv_assert.py MEMORY PLATFORMS PLATFORM OUTPUT MIB")
    memory = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
    platforms = json.loads(
        pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
    )
    platform_id, output_path, total_text = sys.argv[3:]
    total_mib = int(total_text)
    selected_platforms = [
        item for item in platforms["platforms"]
        if item["id"] == platform_id and item["enabled"]
    ]
    if len(selected_platforms) != 1:
        fail(f"找不到唯一启用平台：{platform_id}")
    platform = selected_platforms[0]
    lines = pathlib.Path(output_path).read_text(encoding="utf-8").splitlines()
    type17 = [line for line in lines if line.startswith("type=17,")]
    if len(type17) != 1:
        fail(f"SMBIOS Type 17 参数数量应为 1，实际为 {len(type17)}")
    values = keyvals(type17[0])
    matches = [
        item for item in memory["modules"]
        if item["status"] == "active"
        and item["manufacturer"] == values.get("manufacturer")
        and item["part_number"] == values.get("part")
    ]
    if len(matches) != 1:
        fail("Type 17 品牌/料号没有唯一匹配活动 DIMM")
    module = matches[0]
    facts = {
        "speed": str(module["rated_mts"]),
        "memory-type": "0x1a" if module["type"] == "DDR4" else "0x18",
        "type-detail": "0x80",
        "rank": str(module["rank"]),
        "voltage": str(module["voltage_mv"]),
        "device-width": str(module["device_width_bits"]),
    }
    for key, expected in facts.items():
        if values.get(key) != expected:
            fail(f"Type 17 {key} 与 DIMM 条目不一致")
    ee1004 = values.get("spd-ee1004") == "on"
    if ee1004 != bool(module["spd_ee1004"]):
        fail("Type 17 EE1004 状态与 DIMM 代际不一致")

    memory_policy = platform["memory"]
    cpu_socket = platform["cpu"]["socket"]
    module_count, remainder = divmod(total_mib, int(module["module_mib"]))
    if (
        remainder
        or module_count < 1
        or module_count > int(platform["board"]["dimm_slots"])
        or module["type"] != memory_policy["type"]
        or int(module["voltage_mv"]) != int(memory_policy["voltage_mv"])
        or cpu_socket not in module["allowed_sockets"]
        or int(memory_policy["channels"])
        not in module["allowed_platform_channel_counts"]
    ):
        fail("Type 17 DIMM 与平台插槽/代际/供电组合不合法")
    compatible = [
        int(rate) for rate in memory_policy["allowed_mts"]
        if int(rate) <= int(module["rated_mts"])
        and int(rate) <= int(memory_policy["max_mts"])
    ]
    if not compatible or values.get("configured-speed") != str(max(compatible)):
        fail("Type 17 configured-speed 不是平台合法训练速率")
    serials = values.get("serial", "").split("|")
    reserved = set(memory["serial_policy"]["reserved_values"])
    pattern = re.compile(memory["serial_policy"]["pattern"], re.ASCII)
    if (
        len(serials) != module_count
        or len(set(serials)) != len(serials)
        or any(pattern.fullmatch(serial) is None or serial in reserved
               for serial in serials)
    ):
        fail("Type 17 SPD 序列号数量、格式或唯一性无效")


if __name__ == "__main__":
    main()
