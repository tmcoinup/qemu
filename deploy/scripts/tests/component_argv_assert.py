#!/usr/bin/env python3
"""校验 Windows dry-run 选择的 SSD 与显示器完整匹配共享部件目录。"""

from __future__ import annotations

import json
import pathlib
import re
import sys


def fail(message: str) -> None:
    raise SystemExit(f"FAIL: {message}")


def only_line(lines: list[str], prefix: str, label: str) -> str:
    matches = [line for line in lines if line.startswith(prefix)]
    if len(matches) != 1:
        fail(f"{label} 参数数量应为 1，实际为 {len(matches)}")
    return matches[0]


def keyvals(line: str) -> dict[str, str]:
    result: dict[str, str] = {}
    for token in line.split(",")[1:]:
        if "=" in token:
            key, value = token.split("=", 1)
            result[key] = value
    return result


def assert_serial(policy: dict[str, object], serial: str, label: str) -> None:
    pattern = str(policy["pattern"])
    if re.fullmatch(pattern, serial, flags=re.ASCII) is None:
        fail(f"{label} 序列号不符合所选厂商规则：{serial}")
    payload = serial
    if policy.get("kind") == "samsung-970-pro":
        payload = serial[1:4] + serial[5:]
    elif policy.get("kind") == "intel-760p":
        payload = serial[4:12]
    if len(set(payload)) == 1 and payload[0] in "0FN":
        fail(f"{label} 序列号使用了占位值：{serial}")


def assert_storage(catalog: dict[str, object], lines: list[str]) -> None:
    line = only_line(lines, "nvme,id=nvmectl0,", "NVMe")
    values = keyvals(line)
    selected_id = values.get("x-identity-profile", "")
    matches = [
        item for item in catalog["storage"]
        if item["enabled"] and item["id"] == selected_id
    ]
    if len(matches) != 1:
        fail(f"NVMe 使用未知或未启用的 identity profile：{selected_id}")
    item = matches[0]
    expected = {
        "model-number": item["model"],
        "firmware-rev": item["firmware"],
        "subsys-vendor-id": item["pci"]["subsystem_vendor"].lower(),
        "subsys-id": item["pci"]["subsystem_device"].lower(),
    }
    for key, value in expected.items():
        if values.get(key) != value:
            fail(f"NVMe {key} 与 {selected_id} 目录事实不一致")
    if re.fullmatch(
        r"nqn\.2014-08\.org\.nvmexpress:uuid:"
        r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}",
        values.get("subnqn", ""),
        flags=re.ASCII,
    ) is None:
        fail("NVMe subnqn 没有绑定规范 UUID")
    serial = values.get("serial", "")
    if len(serial) != int(item["serial_policy"]["length"]):
        fail(f"NVMe 序列号长度与 {selected_id} 目录策略不一致")
    assert_serial(item["serial_policy"], serial, f"NVMe {selected_id}")


def monitor_expected(item: dict[str, object]) -> dict[str, str]:
    scan_range = item["range"]
    timing = item["secondary_timing"]
    return {
        "edid-managed-timing-version": "1",
        "edid-vendor": item["vendor_code"],
        "edid-name": item["name"],
        "edid-width-mm": str(item["width_mm"]),
        "edid-height-mm": str(item["height_mm"]),
        "edid-product-id": item["product_id"].lower(),
        "edid-revision": str(item["edid_revision"]),
        "edid-manufacture-week": str(item["manufacture_week"]),
        "edid-manufacture-year": str(item["manufacture_year"]),
        "edid-video-input": item["video_input"].lower(),
        "edid-min-vfreq-hz": str(scan_range["min_vfreq_hz"]),
        "edid-max-vfreq-hz": str(scan_range["max_vfreq_hz"]),
        "edid-min-hfreq-khz": str(scan_range["min_hfreq_khz"]),
        "edid-max-hfreq-khz": str(scan_range["max_hfreq_khz"]),
        "edid-max-pixel-clock-mhz": str(scan_range["max_pixel_clock_mhz"]),
        "edid-secondary-xres": str(timing["xres"]),
        "edid-secondary-yres": str(timing["yres"]),
        "edid-secondary-refresh-rate": str(timing["refresh_millihz"]),
    }


def assert_monitor(catalog: dict[str, object], lines: list[str]) -> None:
    candidates = [
        line for line in lines
        if line.startswith(("virtio-vga,", "virtio-vga-gl,"))
        and "edid-fixed-native=on" in line
    ]
    if len(candidates) != 1:
        fail(f"固定 EDID 显示设备数量应为 1，实际为 {len(candidates)}")
    values = keyvals(candidates[0])
    for key in ("xres", "yres", "xmax", "ymax"):
        if values.get(key) not in {"1920", "1080"}:
            fail(f"显示器 {key} 未固定为 1920x1080")
    if (values["xres"], values["yres"], values["xmax"], values["ymax"]) != (
        "1920", "1080", "1920", "1080"
    ):
        fail("显示器 native/max mode 不是 1920x1080")

    matches = []
    for item in catalog["monitors"]:
        native = item["native_resolution"]
        if (
            item["enabled"]
            and (native["x"], native["y"], native["aspect_ratio"])
            == (1920, 1080, "16:9")
            and all(values.get(key) == value
                    for key, value in monitor_expected(item).items())
        ):
            matches.append(item)
    if len(matches) != 1:
        fail(f"EDID 深层字段没有唯一匹配 1080p/16:9 目录条目：{len(matches)}")
    item = matches[0]
    serial = values.get("edid-serial", "")
    assert_serial(
        item["serial_policy"],
        serial,
        f"显示器 {item['id']}",
    )
    binary_policy = item["binary_serial_policy"]
    if binary_policy["kind"] == "fixed_u32":
        expected_binary = int(binary_policy["fixed_value"], 0)
    elif binary_policy["kind"] == "decimal_suffix6":
        expected_binary = int(serial[-6:], 10)
    else:
        fail(f"显示器 {item['id']} binary serial 策略未知")
    try:
        actual_binary = int(values.get("edid-binary-serial", ""), 0)
    except ValueError:
        fail(f"显示器 {item['id']} 缺少合法 binary serial")
    if expected_binary == 0 or actual_binary != expected_binary:
        fail(f"显示器 {item['id']} binary serial 与文本序列不一致")


def assert_gpu_carrier(catalog: dict[str, object], lines: list[str]) -> None:
    candidates = [
        line for line in lines
        if line.startswith(("virtio-vga,", "virtio-vga-gl,"))
    ]
    if len(candidates) != 1:
        fail(f"virtio GPU 参数数量应为 1，实际为 {len(candidates)}")
    values = keyvals(candidates[0])
    matches = [
        item for item in catalog["boards"]
        if item["enabled"]
        and values.get("x-pci-sub-vendor-id") == item["carrier_vendor"].lower()
        and values.get("x-pci-sub-device-id") == item["carrier_device"].lower()
        and values.get("x-pci-revision") == item["revision"].lower()
    ]
    if len(matches) != 1:
        fail("virtio GPU carrier 没有唯一匹配已审计 AIB 板卡")
    board = matches[0]
    if (
        board["carrier_vendor"].upper() != "0X1AF4"
        or (
            board["carrier_vendor"].upper(),
            board["carrier_device"].upper(),
        )
        == (
            board["subsystem_vendor"].upper(),
            board["subsystem_device"].upper(),
        )
    ):
        fail("AIB 真实 subsystem 被错误用作 virtio 物理 carrier")


def main() -> None:
    if len(sys.argv) != 3:
        fail("用法：component_argv_assert.py COMPONENTS_JSON DRY_RUN_OUTPUT")
    component_path = pathlib.Path(sys.argv[1])
    catalog = json.loads(component_path.read_text(encoding="utf-8"))
    storage_name = catalog.get("storage_catalog")
    if not isinstance(storage_name, str) or pathlib.Path(storage_name).name != storage_name:
        fail("components.json 的 storage_catalog 不是安全 basename")
    storage_catalog = json.loads(
        (component_path.parent / storage_name).read_text(encoding="utf-8")
    )
    gpu_name = catalog.get("gpu_board_catalog")
    if not isinstance(gpu_name, str) or pathlib.Path(gpu_name).name != gpu_name:
        fail("components.json 的 gpu_board_catalog 不是安全 basename")
    gpu_catalog = json.loads(
        (component_path.parent / gpu_name).read_text(encoding="utf-8")
    )
    lines = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8").splitlines()
    assert_storage(storage_catalog, lines)
    assert_monitor(catalog, lines)
    assert_gpu_carrier(gpu_catalog, lines)


if __name__ == "__main__":
    main()
