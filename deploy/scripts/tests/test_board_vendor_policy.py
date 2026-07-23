#!/usr/bin/env python3
"""验证多品牌主板注册表和原子平台厂商绑定不可拆换。"""

from __future__ import annotations

import copy
import json
import pathlib
import re
import sys


SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parents[2]
sys.path.insert(0, str(REPO_ROOT / "deploy" / "scripts"))

from board_vendor_policy import (  # noqa: E402
    REGISTRY_PATH,
    load_board_vendor_registry,
    validate_registry,
)
from platform_manifest import load_manifest, validate_manifest  # noqa: E402


MANIFEST = REPO_ROOT / "deploy" / "hardware" / "platforms.json"
MSI_ID = "intel-lga1151-i3-9100f-msi-h310m-pro-m2-plus-ms-7c08"
GIGABYTE_ID = "intel-lga1151-pentium-g5400-gigabyte-h310m-s2h-2"


def platform(root: dict, platform_id: str) -> dict:
    """按稳定 ID 读取测试对象，避免依赖目录排序。"""
    return next(item for item in root["platforms"] if item["id"] == platform_id)


def assert_rejected(
    root: dict,
    label: str,
    expected_message: str,
) -> None:
    """要求清单变异在完整摘要前也能被定向策略拒绝。"""
    try:
        validate_manifest(root)
    except ValueError as exc:
        if expected_message not in str(exc):
            raise AssertionError(
                f"{label} 虽被拒绝，但未命中定向策略：{exc}"
            ) from exc
        return
    raise AssertionError(f"厂商策略放行非法变异：{label}")


def test_registry() -> None:
    """核对四个常用厂商的 canonical 映射和序号证据策略。"""
    policies = load_board_vendor_registry()
    expected = {
        "ASUSTeK COMPUTER INC.": ("asus", "_serial_asus", "0x1043"),
        "Micro-Star International Co., Ltd.": ("msi", "_serial_msi", "0x1462"),
        "Gigabyte Technology Co., Ltd.": ("gigabyte", "_serial_giga", "0x1458"),
        "ASRock": ("asrock", "_serial_asr", "0x1849"),
    }
    if set(policies) != set(expected):
        raise AssertionError("主板厂商注册表不是审计后的四品牌集合")
    for manufacturer, facts in expected.items():
        policy = policies[manufacturer]
        actual = (
            policy["platform_token"],
            policy["serial_fn"],
            policy["subsystem_vendor"],
        )
        if actual != facts:
            raise AssertionError(f"{manufacturer} canonical 映射错误：{actual}")
        serial = policy["serial_policy"]
        if not re.fullmatch(serial["regex"], serial["example"], flags=re.ASCII):
            raise AssertionError(f"{manufacturer} 序号证据样例不符合自身策略")
        if serial["value_policy"] != "synthetic_random_never_copied_from_device":
            raise AssertionError(f"{manufacturer} 未禁止复制真实设备序号")

    gigabyte = policies["Gigabyte Technology Co., Ltd."]["serial_policy"]["example"]
    year, week = int(gigabyte[2:4]), int(gigabyte[4:6])
    if (year, week) != (14, 12) or not 1 <= week <= 53:
        raise AssertionError("GIGABYTE SN 的 YYWW 日期码位置错误")

    raw = json.loads(REGISTRY_PATH.read_text(encoding="utf-8"))
    broken = copy.deepcopy(raw)
    broken["vendors"]["msi"]["platform_token"] = "asus"
    try:
        validate_registry(broken)
    except ValueError as exc:
        if "platform_token" not in str(exc):
            raise AssertionError(f"错误 token 未命中注册表策略：{exc}") from exc
    else:
        raise AssertionError("注册表放行错厂商 token")


def test_platform_bindings() -> None:
    """分别覆盖 token、PCI subsystem、序号函数与来源的负例。"""
    root = load_manifest(MANIFEST)
    if platform(root, MSI_ID)["devices"]["nvme"] != {
        "max_pcie_generation": 2,
        "lanes": 4,
        "boot_supported": True,
        "attachment": "m2_socket",
    }:
        raise AssertionError("MSI H310M PRO-M2 PLUS M.2 事实错误")
    if platform(root, GIGABYTE_ID)["devices"]["nvme"] != {
        "max_pcie_generation": 2,
        "lanes": 2,
        "boot_supported": True,
        "attachment": "m2_socket",
    }:
        raise AssertionError("GIGABYTE H310M S2H 2.0 M.2 事实错误")

    damaged = copy.deepcopy(root)
    platform(damaged, MSI_ID)["id"] = MSI_ID.replace("-msi-", "-asus-")
    assert_rejected(damaged, "错厂商 platform token", ".id 与 CPU/主板组合不一致")

    damaged = copy.deepcopy(root)
    platform(damaged, MSI_ID)["board"]["subsystem_vendor"] = "0x1043"
    assert_rejected(damaged, "错厂商 PCI subsystem", ".subsystem_vendor 与")

    damaged = copy.deepcopy(root)
    platform(damaged, MSI_ID)["board"]["serial_fn"] = "_serial_asus"
    assert_rejected(damaged, "错厂商序号生成器", ".serial_fn 与")

    damaged = copy.deepcopy(root)
    target = platform(damaged, MSI_ID)
    target["source_refs"][2] = (
        "https://www.asus.com/supportonly/prime%20h310m-a%20r2.0/helpdesk_cpu/"
    )
    assert_rejected(damaged, "混入其他主板厂商来源", ".source_refs")


def main() -> None:
    """运行注册表与整机原子绑定的全部定向断言。"""
    test_registry()
    test_platform_bindings()
    print("OK: board vendor registry and atomic platform bindings")


if __name__ == "__main__":
    main()
