#!/usr/bin/env python3
"""显示器证据样本集合必须由 Python 目录契约逐型号精确锁定。"""

from __future__ import annotations

import contextlib
import copy
import importlib.util
import io
import pathlib


SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parents[2]
POLICY_PATH = REPO_ROOT / "deploy/scripts/component_peripheral_catalog.py"
COMPONENT_PATH = REPO_ROOT / "deploy/hardware/components.json"


def load_policy():
    spec = importlib.util.spec_from_file_location(
        "vmate_component_peripheral_catalog", POLICY_PATH
    )
    if spec is None or spec.loader is None:
        raise RuntimeError("无法加载 component_peripheral_catalog.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> None:
    policy = load_policy()
    root = policy.load_root(COMPONENT_PATH)
    policy.validate_monitors(root)
    faults = {
        "samsung-s24f350": "H4ZMC99999",
        "aoc-24b2xh": "ZZZZ9ZA999999",
        "xiaomi-rmmnt238nf": "2920099999999",
        "lenovo-l24e-30": "URBZZZZZ",
    }
    for monitor_id, replacement in faults.items():
        mutated = copy.deepcopy(root)
        monitor = next(
            item for item in mutated["monitors"] if item["id"] == monitor_id
        )
        monitor["serial_policy"]["reserved_values"][0] = replacement
        try:
            with contextlib.redirect_stderr(io.StringIO()):
                policy.validate_monitors(mutated)
        except SystemExit:
            continue
        raise AssertionError(f"{monitor_id} 接受了非证据 reserved_values")
    for replacement in ("Samsung S24F350\n", "Wrong Monitor"):
        mutated = copy.deepcopy(root)
        mutated["monitors"][0]["windows_friendly_name"] = replacement
        try:
            with contextlib.redirect_stderr(io.StringIO()):
                policy.validate_monitors(mutated)
        except SystemExit:
            continue
        raise AssertionError("接受了非法或未锁定的 Windows FriendlyName")
    print("PASS: Python monitor evidence and FriendlyName exact contract")


if __name__ == "__main__":
    main()
