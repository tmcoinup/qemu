#!/usr/bin/env python3
"""严格校验并导出老式家用平台可用的消费级 SATA SSD 完整组合。"""

from __future__ import annotations

import argparse
import base64
import json
import pathlib
import re
import sys
from typing import Any
from urllib.parse import urlparse


ROOT_KEYS = {
    "schema_version",
    "catalog_revision",
    "identity_scope",
    "selection_policy",
    "profiles",
}
POLICY_KEYS = {
    "platform_boot_bus",
    "qemu_driver",
    "selection",
    "persist_selected_bundle",
    "reload_binding",
    "consumer_only",
}
PROFILE_KEYS = {
    "id",
    "manufacturer",
    "series",
    "model",
    "part_number",
    "firmware",
    "capacity_label",
    "capacity_bytes",
    "interface",
    "compatible_link_rates_gbps",
    "form_factor",
    "protocol",
    "consumer_class",
    "identity_fidelity",
    "source_refs",
}
OFFICIAL_SOURCE_HOSTS = {
    "www.samsung.com",
    "semiconductor.samsung.com",
}
EXPECTED_BUNDLES = {
    "860 PRO": ("samsung-860-pro-512gb-sata", "MZ-76P512BW", "RVM02B6Q"),
    "850 PRO": ("samsung-850-pro-512gb-sata", "MZ-7KE512BW", "EXM04B6Q"),
    "840 PRO": ("samsung-840-pro-512gb-sata", "MZ-7PD512BW", "DXM06B0Q"),
}


def fail(message: str) -> None:
    """统一产生可定位的目录错误。"""
    raise ValueError(message)


def duplicate_guard(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    """在 JSON 解码阶段拒绝重复键，避免后值静默覆盖前值。"""
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            fail(f"JSON 对象包含重复字段 {key}")
        result[key] = value
    return result


def exact(mapping: dict[str, Any], keys: set[str], where: str) -> None:
    """字段必须完整且不能包含未被运行时理解的拼写。"""
    if set(mapping) != keys:
        fail(
            f"{where} 字段集合错误：missing={sorted(keys - set(mapping))} "
            f"unknown={sorted(set(mapping) - keys)}"
        )


def text(value: Any, where: str) -> str:
    """读取非空字符串。"""
    if not isinstance(value, str) or not value:
        fail(f"{where} 必须是非空字符串")
    return value


def validate_sources(value: Any, where: str) -> None:
    """每个型号必须同时有官方产品页和官方固件页。"""
    if not isinstance(value, list) or len(value) < 2:
        fail(f"{where} 至少需要产品与固件两条官方来源")
    seen: set[str] = set()
    for index, source in enumerate(value):
        source = text(source, f"{where}[{index}]")
        parsed = urlparse(source)
        if parsed.scheme != "https" or parsed.hostname not in OFFICIAL_SOURCE_HOSTS:
            fail(f"{where}[{index}] 不是受控厂商 HTTPS 来源")
        if source in seen:
            fail(f"{where} 包含重复来源")
        seen.add(source)
    if not any("/support/tools/" in source for source in value):
        fail(f"{where} 缺少官方固件目录")
    if not any("/owners/product/" in source for source in value):
        fail(f"{where} 缺少官方产品资料")


def validate_profile(profile: Any, index: int) -> tuple[str, tuple[Any, ...]]:
    """验证一个 Guest 可见 SATA 身份不可混搭型号、固件或容量。"""
    where = f"profiles[{index}]"
    if not isinstance(profile, dict):
        fail(f"{where} 必须是对象")
    exact(profile, PROFILE_KEYS, where)
    profile_id = text(profile["id"], f"{where}.id")
    if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", profile_id):
        fail(f"{where}.id 不是稳定小写 ID")
    manufacturer = text(profile["manufacturer"], f"{where}.manufacturer")
    series = text(profile["series"], f"{where}.series")
    model = text(profile["model"], f"{where}.model")
    part_number = text(profile["part_number"], f"{where}.part_number")
    firmware = text(profile["firmware"], f"{where}.firmware")
    if manufacturer != "Samsung" or series not in EXPECTED_BUNDLES:
        fail(f"{where} 当前目录只接受已审计的 Samsung 消费级 PRO 系列")
    if model != f"Samsung SSD {series} 512GB":
        fail(f"{where}.model 与系列/容量不一致")
    expected_id, expected_part, expected_firmware = EXPECTED_BUNDLES[series]
    if (profile_id, part_number, firmware) != (
        expected_id,
        expected_part,
        expected_firmware,
    ):
        fail(f"{where} 的 ID/料号/固件不是该系列固定完整组合")
    if not re.fullmatch(r"MZ-[A-Z0-9]{8}", part_number):
        fail(f"{where}.part_number 格式非法")
    if profile["capacity_label"] != "512GB":
        fail(f"{where}.capacity_label 必须与该受控 SKU 一致")
    capacity = profile["capacity_bytes"]
    if isinstance(capacity, bool) or capacity != 512110190592:
        fail(f"{where}.capacity_bytes 与 512GB 虚拟盘几何不一致")
    if profile["interface"] != "SATA 6 Gb/s":
        fail(f"{where}.interface 不是 SATA SSD")
    if profile["compatible_link_rates_gbps"] != [1.5, 3, 6]:
        fail(f"{where} 未声明 SATA 1.5/3/6 Gb/s 向下兼容链路")
    if profile["form_factor"] != "2.5-inch" or profile["protocol"] != "ATA":
        fail(f"{where} 不是 2.5 英寸 ATA/SATA 完整组合")
    if profile["consumer_class"] is not True:
        fail(f"{where} 不是消费级条目")
    if profile["identity_fidelity"] != \
            "vendor-document-model-and-firmware-no-device-capture":
        fail(f"{where}.identity_fidelity 夸大了 ATA IDENTIFY 证据")
    if len(model.encode("ascii", errors="ignore")) != len(model) or len(model) > 40:
        fail(f"{where}.model 不能安全写入 ATA Identify model 字段")
    if not re.fullmatch(r"[A-Z0-9]{8}", firmware):
        fail(f"{where}.firmware 不能安全写入 QEMU ver 字段")
    validate_sources(profile["source_refs"], f"{where}.source_refs")
    bundle = (model, part_number, firmware, capacity, profile["interface"])
    return profile_id, bundle


def validate_manifest(root: Any) -> None:
    """校验已解析目录，供 CLI 与 mutation 测试共享同一规则。"""
    if not isinstance(root, dict):
        fail("manifest 根必须是对象")
    exact(root, ROOT_KEYS, "manifest")
    if root["schema_version"] != 1:
        fail("schema_version 必须为 1")
    revision = text(root["catalog_revision"], "catalog_revision")
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}\.\d+", revision):
        fail("catalog_revision 格式非法")
    if root["identity_scope"] != "consumer-sata-boot-compatibility":
        fail("identity_scope 非法")
    policy = root["selection_policy"]
    if not isinstance(policy, dict):
        fail("selection_policy 必须是对象")
    exact(policy, POLICY_KEYS, "selection_policy")
    expected_policy = {
        "platform_boot_bus": "sata-ahci",
        "qemu_driver": "ide-hd",
        "selection": "uniform-random-on-profile-create",
        "persist_selected_bundle": True,
        "reload_binding": "catalog-id-and-all-visible-fields",
        "consumer_only": True,
    }
    if policy != expected_policy:
        fail("selection_policy 不能绕过 SATA、持久化或消费级边界")
    profiles = root["profiles"]
    if not isinstance(profiles, list) or len(profiles) < 3:
        fail("profiles 至少需要 3 个消费级 SATA SSD 完整组合")
    ids: set[str] = set()
    bundles: set[tuple[Any, ...]] = set()
    for index, profile in enumerate(profiles):
        profile_id, bundle = validate_profile(profile, index)
        if profile_id in ids:
            fail(f"profiles 包含重复 ID {profile_id}")
        if bundle in bundles:
            fail(f"profiles 包含重复完整组合 {profile_id}")
        ids.add(profile_id)
        bundles.add(bundle)


def load_manifest(path: pathlib.Path) -> dict[str, Any]:
    """读取目录并执行完整结构、来源和唯一性校验。"""
    try:
        root = json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=duplicate_guard,
        )
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"无法读取 storage compatibility 清单 {path}: {exc}")
    validate_manifest(root)
    return root


def find_profile(root: dict[str, Any], profile_id: str) -> dict[str, Any]:
    """按稳定 ID 精确查找，不允许模糊回退。"""
    for profile in root["profiles"]:
        if profile["id"] == profile_id:
            return profile
    fail(f"storage compatibility 条目不存在: {profile_id}")


def emit_export(root: dict[str, Any], profile: dict[str, Any]) -> None:
    """以 base64 TSV 输出，供 Bash 无 eval 地加载。"""
    values = {
        "BOOT_STORAGE_CATALOG_REVISION": root["catalog_revision"],
        "BOOT_STORAGE_COMPONENT_ID": profile["id"],
        "BOOT_STORAGE_MANUFACTURER": profile["manufacturer"],
        "BOOT_STORAGE_MODEL": profile["model"],
        "BOOT_STORAGE_PART_NUMBER": profile["part_number"],
        "BOOT_STORAGE_FIRMWARE": profile["firmware"],
        "BOOT_STORAGE_SIZE_BYTES": profile["capacity_bytes"],
        "BOOT_STORAGE_INTERFACE": profile["interface"],
    }
    for key, value in values.items():
        encoded = base64.b64encode(str(value).encode("utf-8")).decode("ascii")
        print(f"{key}\t{encoded}")


def parse_args() -> argparse.Namespace:
    """解析目录路径、动作和可选条目 ID。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=pathlib.Path)
    parser.add_argument("action", choices=("validate", "list", "export"))
    parser.add_argument("profile_id", nargs="?")
    return parser.parse_args()


def main() -> int:
    """执行只读目录操作。"""
    args = parse_args()
    try:
        root = load_manifest(args.manifest)
        if args.action == "validate":
            if args.profile_id is not None:
                fail("validate 不接受 profile_id")
            print(root["catalog_revision"])
        elif args.action == "list":
            if args.profile_id is not None:
                fail("list 不接受 profile_id")
            for profile in root["profiles"]:
                print(profile["id"])
        else:
            if args.profile_id is None:
                fail("export 必须指定 profile_id")
            emit_export(root, find_profile(root, args.profile_id))
        return 0
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
