#!/usr/bin/env python3
"""加载并校验主板厂商、PCI 子系统和序列号格式的共享策略。"""

from __future__ import annotations

import functools
import json
import pathlib
import re
import urllib.parse
from typing import Any


REGISTRY_PATH = (
    pathlib.Path(__file__).resolve().parent.parent / "hardware" / "board-vendors.json"
)
ROOT_KEYS = {"schema_version", "catalog_revision", "vendors"}
VENDOR_KEYS = {
    "manufacturer", "platform_token", "serial_fn", "subsystem_vendor",
    "official_source_hosts", "serial_policy",
}
SERIAL_KEYS = {
    "regex", "example", "generator_contract", "evidence_scope", "source_ref",
    "value_policy",
}
CPU_SOURCE_HOSTS = {
    "AuthenticAMD": {"www.amd.com"},
    "GenuineIntel": {"www.intel.com"},
}
SERIAL_CONTRACTS = {
    "asus": "asus_12_char_third_s",
    "msi": "msi_601_board_code_14_suffix",
    "gigabyte": "gigabyte_sn_yyww_8_digits",
    "asrock": "asrock_12_char_uppercase_label",
}


def _fail(message: str) -> None:
    """所有注册表错误都必须 fail closed，不能退回猜测厂商。"""
    raise ValueError(message)


def _exact(mapping: dict[str, Any], keys: set[str], where: str) -> None:
    """拒绝缺字段和未知字段，避免策略拼写错误被静默忽略。"""
    if set(mapping) != keys:
        _fail(
            f"{where} 字段集合错误：missing={sorted(keys - set(mapping))} "
            f"unknown={sorted(set(mapping) - keys)}"
        )


def _duplicate_guard(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    """在 JSON 解码阶段拒绝重复键。"""
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            _fail(f"主板厂商注册表包含重复字段 {key}")
        result[key] = value
    return result


def _https_host(source_ref: str) -> str:
    """解析 HTTPS 主机名，并拒绝用户名、端口和片段混淆。"""
    if not isinstance(source_ref, str) or not source_ref:
        _fail("官方来源 URL 必须是非空字符串")
    try:
        parsed = urllib.parse.urlsplit(source_ref)
        port = parsed.port
    except ValueError as exc:
        _fail(f"官方来源 URL 非法：{source_ref!r}: {exc}")
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or port is not None
        or parsed.fragment
    ):
        _fail(f"官方来源必须是无凭据、无端口、无片段的 HTTPS URL：{source_ref}")
    return parsed.hostname.lower()


def validate_registry(root: dict[str, Any]) -> dict[str, dict[str, Any]]:
    """验证共享注册表，并返回按 canonical manufacturer 建立的只读索引。"""
    _exact(root, ROOT_KEYS, "board-vendors")
    if isinstance(root.get("schema_version"), bool) or root.get("schema_version") != 1:
        _fail("board-vendors.schema_version 不受支持")
    revision = root.get("catalog_revision")
    if not isinstance(revision, str) or not re.fullmatch(
        r"\d{4}-\d{2}-\d{2}\.\d+", revision
    ):
        _fail("board-vendors.catalog_revision 格式错误")
    vendors = root.get("vendors")
    if not isinstance(vendors, dict) or set(vendors) != set(SERIAL_CONTRACTS):
        _fail("board-vendors.vendors 必须完整包含 ASUS/MSI/GIGABYTE/ASRock")

    by_manufacturer: dict[str, dict[str, Any]] = {}
    seen_serial_functions: set[str] = set()
    seen_subsystem_vendors: set[str] = set()
    for token, policy in vendors.items():
        where = f"board-vendors.vendors.{token}"
        if not isinstance(policy, dict):
            _fail(f"{where} 必须是对象")
        _exact(policy, VENDOR_KEYS, where)
        if policy["platform_token"] != token:
            _fail(f"{where}.platform_token 与注册表键不一致")
        manufacturer = policy["manufacturer"]
        serial_fn = policy["serial_fn"]
        subsystem_vendor = policy["subsystem_vendor"]
        if not isinstance(manufacturer, str) or not manufacturer:
            _fail(f"{where}.manufacturer 不能为空")
        if not isinstance(serial_fn, str) or not re.fullmatch(
            r"_serial_[a-z]+", serial_fn
        ):
            _fail(f"{where}.serial_fn 格式错误")
        if not isinstance(subsystem_vendor, str) or not re.fullmatch(
            r"0x[0-9A-Fa-f]{4}", subsystem_vendor
        ):
            _fail(f"{where}.subsystem_vendor 格式错误")
        if (
            manufacturer in by_manufacturer
            or serial_fn in seen_serial_functions
            or subsystem_vendor.lower() in seen_subsystem_vendors
        ):
            _fail(f"{where} canonical manufacturer/serial_fn/subsystem_vendor 重复")

        hosts = policy["official_source_hosts"]
        if (
            not isinstance(hosts, list)
            or not hosts
            or any(
                not isinstance(host, str)
                or host != host.lower()
                or not re.fullmatch(r"[a-z0-9.-]+", host)
                for host in hosts
            )
        ):
            _fail(f"{where}.official_source_hosts 必须是有序、唯一的小写主机名")
        if hosts != sorted(set(hosts)):
            _fail(f"{where}.official_source_hosts 必须有序且无重复")

        serial = policy["serial_policy"]
        if not isinstance(serial, dict):
            _fail(f"{where}.serial_policy 必须是对象")
        _exact(serial, SERIAL_KEYS, f"{where}.serial_policy")
        if serial["generator_contract"] != SERIAL_CONTRACTS[token]:
            _fail(f"{where}.serial_policy.generator_contract 与厂商不一致")
        if serial["value_policy"] != "synthetic_random_never_copied_from_device":
            _fail(f"{where}.serial_policy.value_policy 禁止复制真实设备序号")
        try:
            serial_pattern = re.compile(serial["regex"], flags=re.ASCII)
        except (TypeError, re.error) as exc:
            _fail(f"{where}.serial_policy.regex 非法：{exc}")
        if not isinstance(serial["example"], str) or not serial_pattern.fullmatch(
            serial["example"]
        ):
            _fail(f"{where}.serial_policy.example 不符合厂商格式")
        if _https_host(serial["source_ref"]) not in hosts:
            _fail(f"{where}.serial_policy.source_ref 不是该厂商官方来源")
        if not isinstance(serial["evidence_scope"], str) or not serial["evidence_scope"]:
            _fail(f"{where}.serial_policy.evidence_scope 不能为空")

        by_manufacturer[manufacturer] = policy
        seen_serial_functions.add(serial_fn)
        seen_subsystem_vendors.add(subsystem_vendor.lower())
    return by_manufacturer


@functools.lru_cache(maxsize=1)
def load_board_vendor_registry() -> dict[str, dict[str, Any]]:
    """从固定项目路径加载注册表；调用方不能用环境变量替换信任根。"""
    try:
        root = json.loads(
            REGISTRY_PATH.read_text(encoding="utf-8"),
            object_pairs_hook=_duplicate_guard,
        )
    except (OSError, json.JSONDecodeError) as exc:
        _fail(f"无法读取主板厂商注册表 {REGISTRY_PATH}: {exc}")
    if not isinstance(root, dict):
        _fail("主板厂商注册表根节点必须是对象")
    return validate_registry(root)


def board_vendor_for(manufacturer: str) -> dict[str, Any]:
    """按 SMBIOS canonical manufacturer 精确解析厂商，不接受别名猜测。"""
    policy = load_board_vendor_registry().get(manufacturer)
    if policy is None:
        _fail(f"主板厂商未注册：{manufacturer}")
    return policy


def validate_board_vendor_fields(board: dict[str, Any], where: str) -> dict[str, Any]:
    """联合绑定厂商、序号生成器与 PCI subsystem vendor。"""
    policy = board_vendor_for(board["manufacturer"])
    if board["serial_fn"] != policy["serial_fn"]:
        _fail(f"{where}.serial_fn 与 {board['manufacturer']} 序号策略不一致")
    if board["subsystem_vendor"].lower() != policy["subsystem_vendor"].lower():
        _fail(f"{where}.subsystem_vendor 与 {board['manufacturer']} 不一致")
    return policy


def source_ref_allowed(
    source_ref: str,
    board_policy: dict[str, Any],
    cpu_vendor: str,
) -> bool:
    """判断来源是否属于当前主板或 CPU 厂商的精确官方主机集合。"""
    try:
        host = _https_host(source_ref)
    except ValueError:
        return False
    return host in (
        set(board_policy["official_source_hosts"])
        | CPU_SOURCE_HOSTS.get(cpu_vendor, set())
    )


def source_ref_is_board_vendor(
    source_ref: str,
    board_policy: dict[str, Any],
) -> bool:
    """要求整机证据至少包含一项当前主板厂商官方资料。"""
    try:
        return _https_host(source_ref) in board_policy["official_source_hosts"]
    except ValueError:
        return False


def source_ref_is_cpu_vendor(source_ref: str, cpu_vendor: str) -> bool:
    """要求整机证据至少包含一项当前 CPU 厂商官方资料。"""
    try:
        return _https_host(source_ref) in CPU_SOURCE_HOSTS.get(cpu_vendor, set())
    except ValueError:
        return False
