#!/usr/bin/env python3
"""从硬件池导出 Windows 客体显示器名称投影清单。"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


VENDOR_RE = re.compile(r"^[A-Z]{3}$")
NAME_RE = re.compile(r"^[^\x00-\x1f\x7f]{1,128}$")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--catalog", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    return parser.parse_args()


def normalize_product_id(value: object, component_id: str) -> str:
    if not isinstance(value, str) or not re.fullmatch(r"0x[0-9A-Fa-f]{4}", value):
        raise ValueError(f"{component_id}: product_id 必须是 0x 加四位十六进制")
    return value[2:].upper()


def export_manifest(catalog_path: Path) -> dict[str, object]:
    catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
    monitors = catalog.get("monitors")
    if not isinstance(monitors, list) or not monitors:
        raise ValueError("components.json 缺少非空 monitors 数组")

    exported: list[dict[str, str]] = []
    component_ids: set[str] = set()
    pnp_ids: set[str] = set()
    for item in monitors:
        if not isinstance(item, dict) or not item.get("enabled", False):
            continue
        component_id = item.get("id")
        vendor = item.get("vendor_code")
        friendly_name = item.get("windows_friendly_name")
        if not isinstance(component_id, str) or not component_id:
            raise ValueError("启用的显示器缺少 id")
        if not isinstance(vendor, str) or not VENDOR_RE.fullmatch(vendor):
            raise ValueError(f"{component_id}: vendor_code 必须是三个大写字母")
        if not isinstance(friendly_name, str) or not NAME_RE.fullmatch(friendly_name):
            raise ValueError(f"{component_id}: windows_friendly_name 非法")

        product = normalize_product_id(item.get("product_id"), component_id)
        pnp_code = vendor + product
        if component_id in component_ids:
            raise ValueError(f"重复显示器组件 ID: {component_id}")
        if pnp_code in pnp_ids:
            raise ValueError(f"重复显示器 PnP ID: {pnp_code}")
        component_ids.add(component_id)
        pnp_ids.add(pnp_code)
        exported.append(
            {
                "component_id": component_id,
                "pnp_code": pnp_code,
                "hardware_id": rf"MONITOR\{pnp_code}",
                "instance_prefix": f"DISPLAY\\{pnp_code}\\",
                "friendly_name": friendly_name,
            }
        )

    if not exported:
        raise ValueError("没有启用的显示器可导出")
    exported.sort(key=lambda item: item["component_id"])
    return {"schema_version": 1, "monitors": exported}


def main() -> int:
    args = parse_args()
    manifest = export_manifest(args.catalog)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
