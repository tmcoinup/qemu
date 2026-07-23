#!/usr/bin/env python3
"""校验 components.json 中的显示器与虚拟 HID 外设目录。"""

from __future__ import annotations

import json
import pathlib
import re
import sys
from typing import Any


HEX16 = re.compile(r"^0x[0-9A-Fa-f]{4}$")
ROOT_FIELDS = {
    "schema_version", "catalog_revision", "scope", "gpu_board_catalog",
    "storage_catalog", "gpus", "monitors", "hid",
}
MONITOR_FIELDS = {
    "id", "enabled", "selection_weight", "release_year", "manufacturer",
    "model", "vendor_code", "product_id", "name", "serial_policy",
    "binary_serial_policy", "native_resolution", "width_mm", "height_mm",
    "manufacture_week", "manufacture_year", "video_input", "edid_revision", "range",
    "secondary_timing", "evidence", "identity_fidelity", "source_refs",
    "identity_source_refs",
}
SERIAL_FIELDS = {
    "kind", "length", "pattern", "format_fidelity", "reserved_values",
}
BINARY_SERIAL_FIELDS = {"kind", "fixed_value", "format_fidelity"}
RESOLUTION_FIELDS = {"x", "y", "aspect_ratio"}
RANGE_FIELDS = {
    "min_vfreq_hz", "max_vfreq_hz", "min_hfreq_khz", "max_hfreq_khz",
    "max_pixel_clock_mhz",
}
TIMING_FIELDS = {
    "xres", "yres", "refresh_millihz", "pixel_clock_khz",
    "hfront", "hsync", "hblank", "vfront", "vsync", "vblank",
    "hsync_positive", "vsync_positive", "width_mm", "height_mm",
}
HID_FIELDS = {
    "id", "enabled", "vendor_id", "product_id", "bcd_device", "manufacturer",
    "product", "serial_exposed", "verification_status", "descriptor_fidelity",
}

# 每个模板同时锁定官方规格与实机 EDID；序列值按已观察格式新生成，不复制样本。
MONITOR_FACTS = {
    "samsung-s24f350": (
        2, 2016, "Samsung", "LS24F350FHUXEN", "SAM", "0x0D20", "S24F350",
        521, 293, 49, 2019, "0x80", 50, 75, 30, 81, 170,
        "samsung_h4zmc_decimal5", 10, r"^H4ZMC[0-9]{5}$",
        {"www.samsung.com", "images.samsung.com"},
        {"raw.githubusercontent.com"},
        "official_specs_plus_raw_edid_capture",
        "observed_raw_edid_format_synthetic_value",
        "fixed_u32", "0x5A5A5055", "observed_raw_edid_value",
        3, (1280, 720, 50000, 74250, 440, 40, 700, 5, 5, 30,
            True, True, 521, 293),
        frozenset(("H4ZMC01676", "H4ZMC01889")),
    ),
    "aoc-24b2xh": (
        6, 2020, "AOC", "24B2XH", "AOC", "0x2402", "24B2W1G5",
        527, 296, 39, 2022, "0x80", 48, 75, 30, 85, 180,
        "aoc_upper_alnum7_decimal6", 13,
        r"^[A-Z]{4}[0-9][A-Z0-9]A[0-9]{6}$",
        {"www.aoc.com"}, {"raw.githubusercontent.com", "bugs.kde.org"},
        "official_specs_plus_raw_edid_capture",
        "observed_raw_edid_format_synthetic_value",
        "decimal_suffix6", None, "observed_raw_edid_rule",
        3, (1920, 1080, 74973, 174500, 48, 32, 160, 3, 5, 39,
            True, False, 527, 296),
        frozenset(("UOWN9HA005249", "AWDM61A005357", "RSKN61A000560")),
    ),
    "xiaomi-rmmnt238nf": (
        5, 2020, "Xiaomi", "RMMNT238NF", "XMI", "0x23C3", "Mi Monitor",
        527, 293, 20, 2020, "0x80", 50, 75, 15, 100, 190,
        "xiaomi_29200_label_slash_removed_decimal", 13,
        r"^29200[0-9]{8}$",
        {"www.mi.com"},
        {"raw.githubusercontent.com"},
        "official_specs_plus_raw_edid_capture",
        "official_label_separator_removed_as_observed_in_raw_edid",
        "fixed_u32", "0x00000001", "observed_raw_edid_value",
        3, (1920, 1080, 75002, 185630, 48, 40, 280, 5, 5, 45,
            True, True, 160, 90),
        frozenset(("2920000167575", "2920000116680")),
    ),
    "lenovo-l24e-30": (
        4, 2020, "Lenovo", "L24e-30", "LEN", "0x66BC", "L24e-30",
        527, 296, 5, 2022, "0x80", 48, 75, 30, 83, 180,
        "lenovo_urb_upper_alnum", 8, r"^URB[A-Z0-9]{5}$",
        {"psref.lenovo.com"},
        {"download.lenovo.com", "raw.githubusercontent.com"},
        "official_specs_driver_plus_raw_edid_capture",
        "observed_raw_edid_format_synthetic_value",
        "fixed_u32", "0x01010101", "observed_raw_edid_value",
        3, (1920, 1080, 74973, 174500, 48, 32, 160, 3, 5, 39,
            True, False, 527, 296),
        frozenset(("URB5DT6H", "URB4N2F4", "URB644NY")),
    ),
}
HID_FACTS = {
    "keyboards": (
        "microsoft-wired-keyboard-600", "0x045E", "0x0750", "0x0163",
        "Microsoft", "Microsoft Wired Keyboard 600",
        "unverified_catalog_identity", "identity_only_generic_report",
    ),
    "mice": (
        "microsoft-usb-optical-mouse", "0x045E", "0x00CB", "0x0163",
        "Microsoft", "Microsoft USB Optical Mouse",
        "unverified_catalog_identity", "identity_only_generic_report",
    ),
    "tablets": (
        "qemu-generic-usb-tablet", "0x0627", "0x0001", "0x0000",
        "not_exposed", "QEMU USB Tablet", "qemu_native_virtual_device",
        "generic_virtual_only",
    ),
}


def fail(message: str) -> None:
    """统一输出启动链可识别的 fail-closed 错误。"""
    print(f"ERROR: component peripherals: {message}", file=sys.stderr)
    raise SystemExit(1)


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    """拒绝会覆盖身份字段的 JSON 重复键。"""
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            fail(f"JSON 含重复字段 {key}")
        result[key] = value
    return result


def load_root(path: pathlib.Path) -> dict[str, Any]:
    """读取并校验 components 根对象。"""
    try:
        root = json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=reject_duplicate_keys,
        )
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"无法读取 {path}: {exc}")
    if not isinstance(root, dict) or set(root) != ROOT_FIELDS:
        fail("根节点字段集合不完整或包含未知字段")
    if (root.get("schema_version") != 1 or
            not isinstance(root.get("catalog_revision"), str) or
            not root["catalog_revision"]):
        fail("只支持带非空 revision 的 schema_version=1")
    if root.get("scope") != {
            "gpu": "out_of_scope_virtual_display",
            "tablet": "generic_virtual_absolute_pointer",
    }:
        fail("GPU/tablet scope 无效")
    if (root.get("gpu_board_catalog") != "gpu-boards.json" or
            root.get("storage_catalog") != "storage.json"):
        fail("外置 GPU/SSD 目录引用无效")
    return root


def validate_sources(value: Any, hosts: set[str], label: str) -> None:
    """按字段用途限制官方规格或 raw EDID 证据的 HTTPS 域名。"""
    if (not isinstance(value, list) or len(value) < 2 or
            len(value) != len(set(value))):
        fail(f"{label} 至少需要两个互不重复的来源")
    for url in value:
        match = re.fullmatch(r"https://([^/]+)/\S+", url) \
            if isinstance(url, str) else None
        if match is None or match.group(1).lower() not in hosts:
            fail(f"{label} 必须使用对应厂商官方 HTTPS 文档")


def validate_monitors(root: dict[str, Any]) -> list[dict[str, Any]]:
    """校验四款 1920x1080、16:9 显示器的原子 EDID 模板。"""
    raw_items = root.get("monitors")
    if not isinstance(raw_items, list) or len(raw_items) != len(MONITOR_FACTS):
        fail("显示器集合必须恰好是四款已核验 1080p/16:9 型号")
    seen_ids: set[str] = set()
    seen_edid: set[tuple[str, str]] = set()
    timing_contracts: dict[tuple[int, int, int], tuple[Any, ...]] = {}
    enabled: list[dict[str, Any]] = []
    for item in raw_items:
        if not isinstance(item, dict) or set(item) != MONITOR_FIELDS:
            fail("显示器条目字段集合不完整或包含未知字段")
        stable_id = item.get("id")
        if stable_id in seen_ids or stable_id not in MONITOR_FACTS:
            fail("显示器稳定 ID 重复或未核验")
        expected = MONITOR_FACTS[stable_id]
        ranges = item.get("range")
        if not isinstance(ranges, dict) or set(ranges) != RANGE_FIELDS:
            fail(f"{stable_id}.range 字段集合无效")
        actual = tuple(item.get(key) for key in (
            "selection_weight", "release_year", "manufacturer", "model",
            "vendor_code", "product_id", "name", "width_mm", "height_mm",
            "manufacture_week", "manufacture_year", "video_input",
        )) + tuple(ranges[key] for key in (
            "min_vfreq_hz", "max_vfreq_hz", "min_hfreq_khz",
            "max_hfreq_khz", "max_pixel_clock_mhz",
        ))
        if actual != expected[:17] or item.get("enabled") is not True:
            fail(f"{stable_id} 型号、尺寸、范围、权重或 EDID 字段被改写")
        if (item.get("evidence"), item.get("identity_fidelity")) != (
                expected[22],
                "audited_raw_identity_timing_fields_synthetic_edid"):
            fail(f"{stable_id} 的官方规格/实机 EDID 证据边界无效")
        resolution = item.get("native_resolution")
        timing = item.get("secondary_timing")
        if (not isinstance(resolution, dict) or set(resolution) != RESOLUTION_FIELDS or
                tuple(resolution[key] for key in ("x", "y", "aspect_ratio")) !=
                (1920, 1080, "16:9")):
            fail(f"{stable_id} 必须是 1920x1080、16:9")
        if (not isinstance(timing, dict) or set(timing) != TIMING_FIELDS or
                type(timing.get("hsync_positive")) is not bool or
                type(timing.get("vsync_positive")) is not bool or
                tuple(timing[key] for key in (
                    "xres", "yres", "refresh_millihz", "pixel_clock_khz",
                    "hfront", "hsync", "hblank", "vfront", "vsync",
                    "vblank", "hsync_positive", "vsync_positive",
                    "width_mm", "height_mm")) != expected[28] or
                item.get("edid_revision") != expected[27]):
            fail(f"{stable_id} 的 EDID revision 或次要 DTD 与实机模板不一致")
        selector = tuple(timing[key] for key in (
            "xres", "yres", "refresh_millihz",
        ))
        detail = tuple(timing[key] for key in (
            "pixel_clock_khz", "hfront", "hsync", "hblank", "vfront",
            "vsync", "vblank", "hsync_positive", "vsync_positive",
            "width_mm", "height_mm",
        ))
        prior_detail = timing_contracts.setdefault(selector, detail)
        if prior_detail != detail:
            fail(
                f"{stable_id} 的次要 DTD 选择三元组与另一型号冲突；"
                "当前 QEMU ABI 无法表达同三元组的不同细节"
            )
        if (not re.fullmatch(r"[A-Z]{3}", item["vendor_code"]) or
                not HEX16.fullmatch(item["product_id"]) or
                not 1 <= len(item["name"]) <= 13 or not item["name"].isascii()):
            fail(f"{stable_id} 的 EISA/product/name 不可编码到 EDID")
        edid_key = (item["vendor_code"], item["product_id"])
        if edid_key in seen_edid:
            fail(f"{stable_id} 与另一型号复用了 EDID vendor/product")
        policy = item.get("serial_policy")
        if (not isinstance(policy, dict) or set(policy) != SERIAL_FIELDS or
                tuple(policy.get(key) for key in (
                    "kind", "length", "pattern", "format_fidelity")) != (
                    expected[17], expected[18], expected[19], expected[23]) or
                not isinstance(policy["reserved_values"], list) or
                len(policy["reserved_values"]) < 1 or
                any(not isinstance(value, str) or
                    re.fullmatch(policy["pattern"], value) is None
                    for value in policy["reserved_values"]) or
                len(policy["reserved_values"]) !=
                len(set(policy["reserved_values"])) or
                frozenset(policy["reserved_values"]) != expected[29] or
                policy["length"] > 13):
            fail(f"{stable_id} 的品牌序列规则无效")
        binary_policy = item.get("binary_serial_policy")
        if (not isinstance(binary_policy, dict) or
                set(binary_policy) != BINARY_SERIAL_FIELDS or
                tuple(binary_policy.get(key) for key in (
                    "kind", "fixed_value", "format_fidelity")) !=
                expected[24:27]):
            fail(f"{stable_id} 的 EDID binary serial 策略无效")
        fixed_value = binary_policy["fixed_value"]
        if ((binary_policy["kind"] == "fixed_u32") !=
                isinstance(fixed_value, str) or
                isinstance(fixed_value, str) and
                re.fullmatch(r"0x[0-9A-F]{8}", fixed_value) is None):
            fail(f"{stable_id} 的 fixed EDID binary serial 无效")
        validate_sources(item["source_refs"], expected[20], stable_id)
        validate_sources(
            item["identity_source_refs"], expected[21],
            f"{stable_id}.identity_source_refs",
        )
        seen_ids.add(stable_id)
        seen_edid.add(edid_key)
        enabled.append(item)
    return enabled


def validate_hid(root: dict[str, Any]) -> dict[str, dict[str, Any]]:
    """HID 只保留当前 C descriptor 能准确表达的唯一模板。"""
    hid = root.get("hid")
    if not isinstance(hid, dict) or set(hid) != set(HID_FACTS):
        fail("HID 分类集合无效")
    result: dict[str, dict[str, Any]] = {}
    for kind, expected in HID_FACTS.items():
        raw_items = hid.get(kind)
        if not isinstance(raw_items, list) or len(raw_items) != 1:
            fail(f"{kind} 必须且只能包含一个模板")
        item = raw_items[0]
        if not isinstance(item, dict) or set(item) != HID_FIELDS:
            fail(f"{kind} 字段集合无效")
        actual = tuple(item.get(key) for key in (
            "id", "vendor_id", "product_id", "bcd_device", "manufacturer",
            "product", "verification_status", "descriptor_fidelity",
        ))
        if (actual != expected or item.get("enabled") is not True or
                item.get("serial_exposed") is not False):
            fail(f"{kind} 身份与当前 C descriptor 不匹配")
        result[kind] = item
    return result


def print_monitor_row(item: dict[str, Any]) -> None:
    """输出保持既有 18 列 ABI；第六列现为序列生成器类型。"""
    ranges = item["range"]
    timing = item["secondary_timing"]
    values = (
        item["id"], item["vendor_code"], item["name"], item["width_mm"],
        item["height_mm"], item["serial_policy"]["kind"], item["product_id"],
        item["manufacture_week"], item["manufacture_year"], item["video_input"],
        ranges["min_vfreq_hz"], ranges["max_vfreq_hz"],
        ranges["min_hfreq_khz"], ranges["max_hfreq_khz"],
        ranges["max_pixel_clock_mhz"], timing["xres"], timing["yres"],
        timing["refresh_millihz"],
    )
    print("|".join(str(value) for value in values))


def monitor_binary_serial(item: dict[str, Any], serial: str) -> str:
    """按实机 EDID 规则把文本序列映射为 32-bit little-endian 字段。"""
    policy = item["binary_serial_policy"]
    kind = policy["kind"]
    if kind == "decimal_suffix6":
        value = int(serial[-6:], 10)
    elif kind == "fixed_u32":
        value = int(policy["fixed_value"], 0)
    else:
        fail(f"{item['id']} 的 EDID binary serial 策略未知")
    return f"0x{value:08X}"


def main() -> None:
    """执行外设目录的校验与只读行投影。"""
    if len(sys.argv) < 3:
        fail("参数不足")
    root = load_root(pathlib.Path(sys.argv[1]))
    operation = sys.argv[2]
    monitors = validate_monitors(root)
    hid = validate_hid(root)
    monitor_by_id = {item["id"]: item for item in monitors}
    if operation == "validate":
        print(root["catalog_revision"])
    elif operation == "monitor":
        for item in monitors:
            print_monitor_row(item)
    elif operation == "monitor-weights":
        for item in monitors:
            print(f"{item['id']}|{item['selection_weight']}")
    elif operation in {
            "monitor-id", "monitor-serial-spec", "monitor-serial-valid",
            "monitor-binary-serial", "monitor-revision",
            "monitor-secondary-detail",
    }:
        wanted = sys.argv[3] if len(sys.argv) >= 4 else ""
        if wanted not in monitor_by_id:
            fail("未知或缺失的显示器稳定 ID")
        item = monitor_by_id[wanted]
        policy = item["serial_policy"]
        if operation == "monitor-id":
            print_monitor_row(item)
        elif operation == "monitor-serial-spec":
            print("|".join(str(policy[key]) for key in ("kind", "length")))
        elif operation == "monitor-revision":
            print(item["edid_revision"])
        elif operation == "monitor-secondary-detail":
            timing = item["secondary_timing"]
            values = tuple(timing[key] for key in (
                "pixel_clock_khz", "hfront", "hsync", "hblank",
                "vfront", "vsync", "vblank",
            )) + (
                int(timing["hsync_positive"]),
                int(timing["vsync_positive"]),
                timing["width_mm"],
                timing["height_mm"],
            )
            print("|".join(str(value) for value in values))
        else:
            serial = sys.argv[4] if len(sys.argv) == 5 else ""
            if (len(serial) != policy["length"] or
                    not re.fullmatch(policy["pattern"], serial)):
                fail(f"{wanted} 序列号不符合品牌绑定格式")
            if serial in policy["reserved_values"]:
                fail(f"{wanted} 序列号复制了证据样本")
            binary_serial = monitor_binary_serial(item, serial)
            if binary_serial == "0x00000000":
                fail(f"{wanted} 文本序列映射到了保留的 binary serial 0")
            if operation == "monitor-binary-serial":
                print(binary_serial)
    elif operation in HID_FACTS:
        item = hid[operation]
        print("|".join(str(item[key]) for key in (
            "vendor_id", "product_id", "manufacturer", "product", "id",
            "bcd_device", "descriptor_fidelity")))
    else:
        fail(f"未知操作: {operation}")


if __name__ == "__main__":
    main()
