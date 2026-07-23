#!/usr/bin/env python3
"""验证默认正常池的完整 CPU/主板/内存/固件组合不可成套漂移。"""

from __future__ import annotations

import copy
import json
import pathlib
import sys
import tempfile


SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parents[2]
sys.path.insert(0, str(REPO_ROOT / "deploy" / "scripts"))

from platform_manifest import load_manifest  # noqa: E402


MANIFEST = REPO_ROOT / "deploy" / "hardware" / "platforms.json"


def assert_rejected(root: dict, label: str) -> None:
    """把变异清单写入私有临时文件，并要求正式加载器 fail closed。"""
    with tempfile.TemporaryDirectory() as directory:
        path = pathlib.Path(directory) / "platforms.json"
        path.write_text(json.dumps(root), encoding="utf-8")
        try:
            load_manifest(path)
        except ValueError:
            return
    raise AssertionError(f"完整平台摘要放行未审计漂移: {label}")


def main() -> None:
    root = json.loads(MANIFEST.read_text(encoding="utf-8"))
    platforms = {item["id"]: item for item in root["platforms"]}
    target_id = "intel-lga1151-i5-6400t-asus-h110m-a-m2"

    # 这些值分别仍在通用校验的数值/格式范围内，但组合并不是目录审核过的
    # H110M-A/M.2；必须由完整对象摘要拒绝，而不能只验证 CPU。
    drift = copy.deepcopy(root)
    target = next(item for item in drift["platforms"] if item["id"] == target_id)
    target["board"]["pcie_generation"] = 4
    target["board"]["max_memory_gib"] = 64
    target["devices"]["chipset"]["mch"][1] = "0xFFFF"
    target["bios"]["version"] = "9999"
    target["bios"]["date"] = "12/31/2020"
    assert_rejected(drift, "H110 主板/内存/PCH/BIOS 联动漂移")

    # 官方来源本身也属于审计闭包，不能在保留字段格式的同时换成未核对页面。
    drift = copy.deepcopy(root)
    target = next(item for item in drift["platforms"] if item["id"] == target_id)
    target["source_refs"].append("https://www.intel.com/content/www/us/en/homepage.html")
    assert_rejected(drift, "来源集合漂移")

    if set(platforms) != {
        "amd-am4-r3-1200-asus-prime-b350-plus",
        "intel-lga1151-i3-9100f-asus-prime-h310m-a-r2",
        "intel-lga1151-celeron-g4900-asus-prime-h310m-a-r2",
        "intel-lga1151-pentium-g5400-asus-prime-h310m-a-r2",
        "intel-lga1151-i3-9100f-msi-h310m-pro-m2-plus-ms-7c08",
        "intel-lga1151-pentium-g5400-gigabyte-h310m-s2h-2",
        target_id,
    }:
        raise AssertionError("默认平台集合发生未审计增删")
    print("OK: full platform fact digests reject coordinated drift")


if __name__ == "__main__":
    main()
