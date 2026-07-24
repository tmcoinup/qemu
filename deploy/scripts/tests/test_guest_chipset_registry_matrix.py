#!/usr/bin/env python3
"""验证所有可加载平台的 SMBus 身份都有明确 guest 识别策略。"""

from __future__ import annotations

import json
import re
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[3]
HARDWARE = REPO_ROOT / "deploy" / "hardware"
INSTALLER = REPO_ROOT / "deploy" / "guest-stealth" / "install-chipset-device.ps1"
PAYLOAD_DIR = REPO_ROOT / "deploy" / "scripts" / "stock-intel-chipset-inf"


def load_json(name: str) -> dict[str, object]:
    return json.loads((HARDWARE / name).read_text(encoding="utf-8"))


def smbus_id(platform: dict[str, object]) -> str:
    chipset = platform["devices"]["chipset"]
    vendor, device, _revision = chipset["smbus"]
    if vendor.casefold() != "0x8086":
        raise AssertionError(f"guest installer 仅支持 Intel SMBus，发现 {vendor}:{device}")
    return device.removeprefix("0x").upper()


def enabled_registry_ids() -> set[str]:
    result: set[str] = set()
    platforms = load_json("platforms.json")
    for platform in platforms["platforms"]:
        if platform.get("enabled") is True:
            result.add(smbus_id(platform))

    household = load_json("household-compatibility.json")
    profiles = {item["id"]: item for item in household["platform_profiles"]}
    for candidate in household["candidates"]:
        if candidate.get("enabled") is True:
            result.add(smbus_id(profiles[candidate["profile_id"]]))

    host = load_json("host-compatibility.json")
    if host["templates"]:
        result.add(smbus_id(host["common"]))
    return result


def powershell_objects(source: str, variable: str) -> list[dict[str, str]]:
    match = re.search(
        rf"(?ms)^\${re.escape(variable)}\s*=\s*@\((.*?)^\)$", source
    )
    if match is None:
        raise AssertionError(f"安装器缺少 ${variable}")
    objects: list[dict[str, str]] = []
    for body in re.findall(r"(?ms)\[pscustomobject\]@\{(.*?)^\s*\}", match.group(1)):
        fields = dict(re.findall(r"(?m)^\s*(\w+)\s*=\s*'([^']*)'\s*$", body))
        if fields:
            objects.append(fields)
    if not objects:
        raise AssertionError(f"${variable} 没有可解析策略")
    return objects


def main() -> None:
    source = INSTALLER.read_text(encoding="utf-8-sig")
    payloads = powershell_objects(source, "ChipsetPayloads")
    inbox = powershell_objects(source, "InboxChipsetPolicies")
    policies = payloads + inbox

    policy_ids = [item["DeviceId"].upper() for item in policies]
    if len(policy_ids) != len(set(policy_ids)):
        raise AssertionError(f"SMBus guest 策略 ID 重复: {policy_ids}")
    expected = enabled_registry_ids()
    if set(policy_ids) != expected:
        raise AssertionError(
            f"registry→guest SMBus 策略不闭合: registry={sorted(expected)}, "
            f"installer={sorted(policy_ids)}"
        )

    for payload in payloads:
        if payload.get("Provisioning") != "Payload":
            raise AssertionError(f"{payload['DeviceId']} 不是 Payload 策略")
        inf_path = PAYLOAD_DIR / payload["InfName"]
        cat_path = PAYLOAD_DIR / payload["CatName"]
        if not inf_path.is_file() or not cat_path.is_file():
            raise AssertionError(f"{payload['DeviceId']} 缺少 INF/CAT")
        inf = inf_path.read_text(encoding="utf-8")
        hardware_id = f"PCI\\VEN_8086&DEV_{payload['DeviceId']}"
        if (
            hardware_id.casefold() not in inf.casefold()
            or "[needs_no_drv]" not in inf.casefold()
            or f"CatalogFile={payload['CatalogFile']}".casefold()
            not in inf.casefold()
        ):
            raise AssertionError(f"{payload['DeviceId']} INF 语义不完整")

    if inbox != [
        {
            "Provisioning": "Inbox",
            "DeviceId": "2930",
            "InfName": "machine.inf",
        }
    ]:
        raise AssertionError(f"2930 inbox 策略漂移: {inbox}")
    required_inbox_guards = (
        "$State.Status -ine 'OK'",
        "$State.ProblemCode -ne 0",
        "$State.ClassName -ine 'System'",
        "$State.InfPath -ine $State.Payload.InfName",
        "$State.Service",
        "FriendlyName=<empty>",
    )
    for guard in required_inbox_guards:
        if guard not in source:
            raise AssertionError(f"2930 inbox 健康门禁缺少: {guard}")

    print(
        "OK: registry→guest SMBus matrix is closed: "
        + ", ".join(sorted(expected))
    )


if __name__ == "__main__":
    main()
