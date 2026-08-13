#!/usr/bin/env python3
"""家用 CPU compatibility 完整组合清单的严格校验与投影。"""

from __future__ import annotations

import json
import pathlib
import re
from typing import Any
from urllib.parse import urlparse

from guest_cpu_policy import forbidden_server_identity, household_brand_allowed, named_household_qemu_base_allowed
from household_compat_cpu_policy import validate_cpu_facts, validate_feature_overrides
from household_compat_profile_policy import validate_profile_facts
from household_compat_storage_policy import validate_storage_policy
from household_host_policy import validate_host_classes
from household_selection_policy import (
    AUDITED_IDENTITY_ALIASES,
    EXPECTED_SELECTION_POLICY,
    HOUSEHOLD_IDENTITY_SCOPE,
    validate_candidate_status,
)

ROOT_KEYS = {
    "schema_version", "catalog_revision", "identity_scope", "selection_policy",
    "host_classes", "platform_profiles", "candidates",
}
PROFILE_KEYS = {
    "id", "release_year", "guest_generation", "board", "memory", "storage", "devices",
    "bios", "system", "tpm", "source_refs",
}
CPU_KEYS = {
    "qemu_arg", "vendor_id", "name", "max_mhz", "current_mhz", "tsc_mhz",
    "part", "socket", "cores", "threads", "phys_bits", "features",
    "integrated_gpu", "smbios",
}
ALLOWED_TOPOLOGIES = {(2, 2), (2, 4), (4, 4)}
GENERATION_CPU = {
    "sandy-bridge": ("GenuineIntel", "SandyBridge-IBRS", 6, {42}, 7, "LGA1155"),
    "ivy-bridge": ("GenuineIntel", "IvyBridge-IBRS", 6, {58}, 9, "LGA1155"),
    "haswell": ("GenuineIntel", "Haswell-v4", 6, {60}, 3, "LGA1150"),
    "k10": ("AuthenticAMD", "phenom", 16, {4, 6}, 3, "AM3"),
    "zen": ("AuthenticAMD", "Ryzen3-1200", 23, {1, 17}, None, "AM4"),
}
SOURCE_HOSTS = {
    "www.intel.com", "ark.intel.com", "www.amd.com", "www.asus.com",
    "dlcdnets.asus.com", "dlcdnet.asus.com",
}

def fail(message: str) -> None:
    """统一抛出可定位的清单错误。"""
    raise ValueError(message)


def exact(mapping: dict[str, Any], keys: set[str], where: str) -> None:
    """拒绝缺字段和未知字段，防止拼写错误被静默忽略。"""
    if set(mapping) != keys:
        fail(
            f"{where} 字段集合错误："
            f"missing={sorted(keys - set(mapping))} "
            f"unknown={sorted(set(mapping) - keys)}"
        )


def req(mapping: dict[str, Any], key: str, kind: type, where: str) -> Any:
    """读取必填字段；布尔值不能冒充 Python 整数。"""
    if key not in mapping:
        fail(f"{where} 缺少字段 {key}")
    value = mapping[key]
    if kind is int and isinstance(value, bool):
        fail(f"{where}.{key} 不能用布尔值代替整数")
    if not isinstance(value, kind):
        fail(f"{where}.{key} 类型错误，应为 {kind.__name__}")
    return value


def duplicate_guard(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    """JSON 解码阶段即拒绝同一对象中的重复键。"""
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            fail(f"JSON 对象包含重复字段 {key}")
        result[key] = value
    return result


def load_manifest(path: pathlib.Path) -> dict[str, Any]:
    """读取并严格校验一个清单文件。"""
    try:
        text = path.read_text(encoding="utf-8")
        root = json.loads(text, object_pairs_hook=duplicate_guard)
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"无法读取 compatibility 清单 {path}: {exc}")
    if not isinstance(root, dict):
        fail("manifest 根必须是对象")
    validate_manifest(root)
    return root


def validate_id(value: str, where: str) -> None:
    if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", value):
        fail(f"{where} 不是稳定小写 ID")


def validate_hex(value: str, digits: int, where: str) -> None:
    if not re.fullmatch(rf"0x[0-9A-Fa-f]{{{digits}}}", value):
        fail(f"{where} 必须是 0x 加 {digits} 位十六进制")


def validate_int_list(value: Any, where: str) -> list[int]:
    if not isinstance(value, list) or not value:
        fail(f"{where} 必须是非空整数数组")
    if any(isinstance(item, bool) or not isinstance(item, int) or item <= 0
           for item in value):
        fail(f"{where} 含非正整数")
    if value != sorted(set(value)):
        fail(f"{where} 必须升序且不能重复")
    return value


def validate_sources(value: Any, where: str, required_host: str | None = None) -> None:
    if not isinstance(value, list) or not value:
        fail(f"{where} 必须有官方证据链接")
    hosts: set[str] = set()
    for index, source in enumerate(value):
        if not isinstance(source, str):
            fail(f"{where}[{index}] 必须是字符串")
        parsed = urlparse(source)
        if parsed.scheme != "https" or parsed.hostname not in SOURCE_HOSTS:
            fail(f"{where}[{index}] 不是受控厂商 HTTPS 来源")
        hosts.add(parsed.hostname or "")
    required_hosts = {required_host} if required_host else set()
    if required_host == "www.intel.com":
        required_hosts.add("ark.intel.com")
    if required_hosts and not required_hosts.intersection(hosts):
        fail(f"{where} 缺少 {required_host} 官方 CPU 来源")


def validate_board_memory(profile: dict[str, Any], where: str) -> None:
    board = req(profile, "board", dict, where)
    exact(board, {
        "manufacturer", "product", "family", "version", "serial_fn",
        "subsystem_vendor", "subsystem_device", "pch", "pcie_generation",
        "dimm_slots", "max_memory_gib",
    }, f"{where}.board")
    if board["manufacturer"] != "ASUSTeK COMPUTER INC.":
        fail(f"{where}.board.manufacturer 当前只允许有证据的 ASUS 组合")
    if board["serial_fn"] != "_serial_asus":
        fail(f"{where}.board.serial_fn 与厂商序号策略不匹配")
    for key in ("subsystem_vendor", "subsystem_device"):
        validate_hex(req(board, key, str, f"{where}.board"), 4, f"{where}.board.{key}")
    for key in ("pcie_generation", "dimm_slots", "max_memory_gib"):
        if req(board, key, int, f"{where}.board") <= 0:
            fail(f"{where}.board.{key} 必须为正整数")

    memory = req(profile, "memory", dict, where)
    exact(memory, {
        "type", "channels", "max_mts", "allowed_mts", "voltage_mv", "rank",
        "module_mib", "allowed_total_mib",
    }, f"{where}.memory")
    generation = req(profile, "guest_generation", str, where)
    expected_type = "DDR4" if generation == "zen" else "DDR3"
    if memory["type"] != expected_type or memory["channels"] != 2:
        fail(f"{where}.memory 必须是该代双通道 {expected_type}")
    rates = validate_int_list(memory["allowed_mts"], f"{where}.memory.allowed_mts")
    # DDR4-2667 常以可配置整数档 2666 暴露，允许这一 MT/s 的标称差。
    if memory["max_mts"] - max(rates) not in (0, 1):
        fail(f"{where}.memory.max_mts 必须匹配允许速率上限")
    validate_int_list(memory["module_mib"], f"{where}.memory.module_mib")
    validate_int_list(memory["allowed_total_mib"], f"{where}.memory.allowed_total_mib")
    if memory["voltage_mv"] != (1200 if expected_type == "DDR4" else 1500):
        fail(f"{where}.memory.voltage_mv 与内存类型不符")
    if memory["rank"] not in (1, 2):
        fail(f"{where}.memory.rank 非法")


def validate_pci_item(item: Any, where: str, with_revision: bool = True) -> None:
    if not isinstance(item, dict):
        fail(f"{where} 必须是对象")
    keys = {"pci_vendor", "pci_device", "revision"} if with_revision else set()
    exact(item, keys, where)
    validate_hex(item["pci_vendor"], 4, f"{where}.pci_vendor")
    validate_hex(item["pci_device"], 4, f"{where}.pci_device")
    validate_hex(item["revision"], 2, f"{where}.revision")


def validate_devices(profile: dict[str, Any], where: str) -> None:
    devices = req(profile, "devices", dict, where)
    exact(devices, {"chipset", "root_port", "xhci", "nvme", "nic", "audio"},
          f"{where}.devices")
    chipset = req(devices, "chipset", dict, f"{where}.devices")
    exact(chipset, {"mch", "lpc", "smbus", "ahci"}, f"{where}.devices.chipset")
    for key, triple in chipset.items():
        if not isinstance(triple, list) or len(triple) != 3:
            fail(f"{where}.devices.chipset.{key} 必须是 PCI 三元组")
        validate_hex(triple[0], 4, f"{where}.devices.chipset.{key}.vendor")
        validate_hex(triple[1], 4, f"{where}.devices.chipset.{key}.device")
        validate_hex(triple[2], 2, f"{where}.devices.chipset.{key}.revision")
    validate_pci_item(devices["root_port"], f"{where}.devices.root_port")
    validate_pci_item(devices["xhci"], f"{where}.devices.xhci")

    nvme = req(devices, "nvme", dict, f"{where}.devices")
    exact(nvme, {"max_pcie_generation", "lanes", "boot_supported", "attachment"},
          f"{where}.devices.nvme")
    if nvme["max_pcie_generation"] not in (2, 3) or nvme["lanes"] not in (2, 4):
        fail(f"{where}.devices.nvme PCIe 几何非法")
    if not isinstance(nvme["boot_supported"], bool):
        fail(f"{where}.devices.nvme.boot_supported 必须是布尔值")
    if nvme["attachment"] not in ("pcie_add_in", "m2_socket"):
        fail(f"{where}.devices.nvme.attachment 非法")
    storage = req(profile, "storage", dict, where)
    validate_storage_policy(
        profile["id"], profile["board"], nvme, storage, where,
    )

    nic = req(devices, "nic", dict, f"{where}.devices")
    exact(nic, {
        "vendor", "model", "pci_vendor", "pci_device", "subsystem_vendor",
        "subsystem_device", "mac_oui", "attachment", "board_nic_state",
    }, f"{where}.devices.nic")
    for key in ("pci_vendor", "pci_device", "subsystem_vendor", "subsystem_device"):
        validate_hex(nic[key], 4, f"{where}.devices.nic.{key}")
    if not re.fullmatch(r"[0-9a-f]{2}(?::[0-9a-f]{2}){2}", nic["mac_oui"]):
        fail(f"{where}.devices.nic.mac_oui 非法")

    audio = req(devices, "audio", dict, f"{where}.devices")
    exact(audio, {
        "vendor", "codec", "codec_id", "codec_revision", "codec_subsystem_id",
        "identity_fidelity", "controller_pci_vendor", "controller_pci_device",
    }, f"{where}.devices.audio")
    validate_hex(audio["codec_id"], 8, f"{where}.devices.audio.codec_id")
    validate_hex(audio["codec_revision"], 8, f"{where}.devices.audio.codec_revision")
    validate_hex(audio["codec_subsystem_id"], 8, f"{where}.devices.audio.codec_subsystem_id")
    validate_hex(audio["controller_pci_vendor"], 4, f"{where}.devices.audio.controller_pci_vendor")
    validate_hex(audio["controller_pci_device"], 4, f"{where}.devices.audio.controller_pci_device")


def validate_firmware(profile: dict[str, Any], where: str) -> None:
    bios = req(profile, "bios", dict, where)
    exact(bios, {"vendor", "version", "date"}, f"{where}.bios")
    if bios["vendor"] != "American Megatrends Inc.":
        fail(f"{where}.bios.vendor 与 ASUS 组合不符")
    if not re.fullmatch(r"[0-9]{2}/[0-9]{2}/[0-9]{4}", bios["date"]):
        fail(f"{where}.bios.date 格式错误")
    system = req(profile, "system", dict, where)
    exact(system, {"product", "family", "chassis_type"}, f"{where}.system")
    if system["chassis_type"] != "0x03":
        fail(f"{where}.system.chassis_type 当前只允许桌面机箱")
    tpm = req(profile, "tpm", dict, where)
    exact(tpm, {
        "capability", "supported", "implementation", "version",
        "emulation_frontend", "pcr_banks", "support_source_ref",
        "version_source_ref",
    }, f"{where}.tpm")
    if not isinstance(tpm["supported"], bool):
        fail(f"{where}.tpm.supported 必须是布尔值")
    if tpm["supported"]:
        if (tpm["capability"], tpm["version"], tpm["emulation_frontend"]) != (
            "firmware", "2.0", "tpm-crb",
        ) or tpm["pcr_banks"] != ["sha256"]:
            fail(f"{where}.tpm 的 TPM 2.0 组合不完整")
    elif any((tpm["capability"] != "none", tpm["implementation"] != "none",
              tpm["version"] != "none", tpm["emulation_frontend"] != "none",
              tpm["pcr_banks"] != [])):
        fail(f"{where}.tpm 禁用状态不完整")
    validate_sources([tpm["support_source_ref"], tpm["version_source_ref"]],
                     f"{where}.tpm.sources")


def validate_profile(profile: dict[str, Any], where: str) -> None:
    exact(profile, PROFILE_KEYS, where)
    validate_id(req(profile, "id", str, where), f"{where}.id")
    if not 2008 <= req(profile, "release_year", int, where) <= 2026:
        fail(f"{where}.release_year 超出支持范围")
    if req(profile, "guest_generation", str, where) not in GENERATION_CPU:
        fail(f"{where}.guest_generation 未受支持")
    validate_board_memory(profile, where)
    validate_devices(profile, where)
    validate_firmware(profile, where)
    validate_sources(profile["source_refs"], f"{where}.source_refs")


def parse_qemu_properties(qemu_arg: str, where: str) -> tuple[str, dict[str, str]]:
    tokens = qemu_arg.split(",")
    if not tokens or not tokens[0]:
        fail(f"{where}.qemu_arg 缺少 CPU 基型")
    properties: dict[str, str] = {}
    for token in tokens[1:]:
        if "=" not in token:
            fail(f"{where}.qemu_arg 属性 {token!r} 不是 key=value")
        key, value = token.split("=", 1)
        if not key or not value or key in properties:
            fail(f"{where}.qemu_arg 属性 {key!r} 非法或重复")
        properties[key] = value
    return tokens[0], properties


def validate_cpu(candidate: dict[str, Any], profile: dict[str, Any], where: str) -> None:
    cpu = req(candidate, "cpu", dict, where)
    exact(cpu, CPU_KEYS, f"{where}.cpu")
    generation = profile["guest_generation"]
    vendor, qemu_model, family, models, stepping, socket = GENERATION_CPU[generation]
    if cpu["vendor_id"] != vendor or cpu["socket"] != socket:
        fail(f"{where}.cpu 厂商或插槽与组合代际不符")
    name = req(cpu, "name", str, f"{where}.cpu")
    qemu_arg = req(cpu, "qemu_arg", str, f"{where}.cpu")
    if (
        not named_household_qemu_base_allowed(qemu_arg)
        or forbidden_server_identity(name, qemu_arg)
        or not household_brand_allowed(cpu["vendor_id"], name)
    ):
        fail(f"{where}.cpu 不是受控家用型号，或泄露服务器/E 系列身份")
    base, props = parse_qemu_properties(qemu_arg, f"{where}.cpu")
    if base != qemu_model or props.get("model-id") != name:
        fail(f"{where}.cpu.qemu_arg 基型或 model-id 与家用 SKU 不符")
    validate_feature_overrides(candidate["id"], props, where)
    try:
        actual = (int(props["family"]), int(props["model"]), int(props["stepping"]))
    except (KeyError, ValueError):
        fail(f"{where}.cpu.qemu_arg 缺少合法 family/model/stepping")
    if actual[0] != family or actual[1] not in models:
        fail(f"{where}.cpu CPUID family/model 与代际不符")
    if stepping is not None and actual[2] != stepping:
        fail(f"{where}.cpu CPUID stepping 与代际不符")
    cores = req(cpu, "cores", int, f"{where}.cpu")
    threads = req(cpu, "threads", int, f"{where}.cpu")
    if (cores, threads) not in ALLOWED_TOPOLOGIES:
        fail(f"{where}.cpu 拓扑不在 2C2T/2C4T/4C4T 白名单")
    for key in ("max_mhz", "current_mhz", "tsc_mhz", "phys_bits"):
        if req(cpu, key, int, f"{where}.cpu") <= 0:
            fail(f"{where}.cpu.{key} 必须为正整数")
    if cpu["max_mhz"] < cpu["current_mhz"] or cpu["tsc_mhz"] != cpu["current_mhz"]:
        fail(f"{where}.cpu 频率/TSC 组合不自洽")
    if not 36 <= cpu["phys_bits"] <= 48:
        fail(f"{where}.cpu.phys_bits 超出家用目录范围")
    if not re.fullmatch(r"[A-Z0-9-]{8,24}", req(cpu, "part", str, f"{where}.cpu")):
        fail(f"{where}.cpu.part 不是受控订购/部件号")

    igpu = req(cpu, "integrated_gpu", dict, f"{where}.cpu")
    exact(igpu, {"present", "profile_state", "model"}, f"{where}.cpu.integrated_gpu")
    if not isinstance(igpu["present"], bool):
        fail(f"{where}.cpu.integrated_gpu.present 必须是布尔值")
    expected_state = "disabled_in_bios" if igpu["present"] else "absent"
    expected_model = igpu["model"] != "none" if igpu["present"] else igpu["model"] == "none"
    if igpu["profile_state"] != expected_state or not expected_model:
        fail(f"{where}.cpu.integrated_gpu 状态与是否存在不一致")

    smbios = req(cpu, "smbios", dict, f"{where}.cpu")
    exact(smbios, {
        "family", "upgrade", "voltage_mv", "external_clock_mhz",
        "characteristics",
    }, f"{where}.cpu.smbios")
    validate_hex(smbios["family"], 4, f"{where}.cpu.smbios.family")
    validate_hex(smbios["upgrade"], 2, f"{where}.cpu.smbios.upgrade")
    validate_hex(smbios["characteristics"], 4, f"{where}.cpu.smbios.characteristics")
    expected_characteristics = "0x00FC" if threads > cores else "0x00EC"
    if smbios["characteristics"] != expected_characteristics:
        fail(f"{where}.cpu.smbios.characteristics 的硬件线程位与拓扑不符")
    for key in ("voltage_mv", "external_clock_mhz"):
        if isinstance(smbios[key], bool) or not isinstance(smbios[key], int):
            fail(f"{where}.cpu.smbios.{key} 必须是整数")


def validate_candidate(
    candidate: dict[str, Any],
    profiles: dict[str, dict[str, Any]],
    classes: dict[str, dict[str, Any]],
    where: str,
) -> None:
    candidate_keys = {
        "id", "enabled", "status", "host_classes", "profile_id", "cpu",
        "source_refs",
    }
    if "identity_alias_of" in candidate:
        candidate_keys.add("identity_alias_of")
    exact(candidate, candidate_keys, where)
    candidate_id = req(candidate, "id", str, where)
    validate_id(candidate_id, f"{where}.id")
    expected_alias = AUDITED_IDENTITY_ALIASES.get(candidate_id)
    has_alias = "identity_alias_of" in candidate
    if has_alias != (expected_alias is not None) or candidate.get("identity_alias_of") != expected_alias:
        fail(f"{where}.identity_alias_of 偏离受审计身份别名关系")
    if candidate["enabled"] is not True:
        fail(f"{where} 必须是启用候选")
    profile_id = req(candidate, "profile_id", str, where)
    if profile_id not in profiles:
        fail(f"{where}.profile_id 引用了未知完整组合")
    host_ids = req(candidate, "host_classes", list, where)
    if not host_ids or len(host_ids) != len(set(host_ids)):
        fail(f"{where}.host_classes 不能为空或重复")
    profile = profiles[profile_id]
    validate_candidate_status(
        candidate_id,
        req(candidate, "status", str, where),
        host_ids,
        profile_id,
        profile["guest_generation"],
        profile["memory"]["type"],
        where,
    )
    for host_id in host_ids:
        if host_id not in classes:
            fail(f"{where}.host_classes 包含未知宿主类 {host_id}")
        host = classes[host_id]
        if profile["guest_generation"] not in host["guest_generations"]:
            fail(f"{where} 的宿主类与客体代际不匹配")
        if candidate["cpu"]["vendor_id"] != host["vendor_id"]:
            fail(f"{where} 违反同厂商 CPU 身份约束")
    validate_cpu(candidate, profile, where)
    validate_cpu_facts(candidate_id, candidate["cpu"], where)
    required = "www.intel.com" if candidate["cpu"]["vendor_id"] == "GenuineIntel" else "www.amd.com"
    validate_sources(candidate["source_refs"], f"{where}.source_refs", required)


def validate_manifest(root: dict[str, Any]) -> None:
    """验证策略、宿主分类、完整组合和全部家用 CPU 候选。"""
    exact(root, ROOT_KEYS, "manifest")
    if req(root, "schema_version", int, "manifest") != 1:
        fail("manifest.schema_version 当前只支持 1")
    if not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}\.[0-9]+",
                        req(root, "catalog_revision", str, "manifest")):
        fail("manifest.catalog_revision 格式错误")
    if root["identity_scope"] != HOUSEHOLD_IDENTITY_SCOPE:
        fail("manifest.identity_scope 非法")
    if req(root, "selection_policy", dict, "manifest") != EXPECTED_SELECTION_POLICY:
        fail("manifest.selection_policy 偏离 fail-closed 兜底策略")

    raw_classes = req(root, "host_classes", list, "manifest")
    classes = validate_host_classes(raw_classes, "manifest.host_classes")

    raw_profiles = req(root, "platform_profiles", list, "manifest")
    profiles: dict[str, dict[str, Any]] = {}
    for index, profile in enumerate(raw_profiles):
        where = f"manifest.platform_profiles[{index}]"
        if not isinstance(profile, dict):
            fail(f"{where} 必须是对象")
        validate_profile(profile, where)
        validate_profile_facts(profile, where)
        profile_id = profile["id"]
        if profile_id in profiles:
            fail(f"{where}.id 重复")
        profiles[profile_id] = profile
    if not profiles:
        fail("manifest.platform_profiles 不能为空")

    raw_candidates = req(root, "candidates", list, "manifest")
    candidates_by_id: dict[str, dict[str, Any]] = {}
    part_owners: dict[str, str] = {}
    name_owners: dict[str, str] = {}
    coverage: dict[str, set[tuple[int, int]]] = {key: set() for key in classes}
    used_profiles: set[str] = set()
    for index, candidate in enumerate(raw_candidates):
        where = f"manifest.candidates[{index}]"
        if not isinstance(candidate, dict):
            fail(f"{where} 必须是对象")
        validate_candidate(candidate, profiles, classes, where)
        cpu = candidate["cpu"]
        candidate_id = candidate["id"]
        if candidate_id in candidates_by_id:
            fail(f"{where} 的 ID 重复")
        alias_of = candidate.get("identity_alias_of")
        for value, owners, label in (
            (cpu["part"], part_owners, "部件号"),
            (cpu["name"], name_owners, "CPU 名称"),
        ):
            owner_id = owners.get(value)
            if owner_id is not None and alias_of != owner_id:
                fail(f"{where} 的{label}重复且不是受审计身份别名")
            owners.setdefault(value, candidate_id)
        if alias_of is not None:
            original = candidates_by_id.get(alias_of)
            if original is None:
                fail(f"{where}.identity_alias_of 必须引用前置候选")
            if (
                original["status"] != "compatibility"
                or candidate["status"] != "supported"
                or set(original["host_classes"]) & set(candidate["host_classes"])
                or candidate["profile_id"] != original["profile_id"]
                or candidate["cpu"] != original["cpu"]
                or candidate["source_refs"] != original["source_refs"]
            ):
                fail(f"{where} 未完整复用兼容候选事实，或宿主类发生重叠")
        candidates_by_id[candidate_id] = candidate
        used_profiles.add(candidate["profile_id"])
        for host_id in candidate["host_classes"]:
            coverage[host_id].add((cpu["cores"], cpu["threads"]))
    required_coverage = {
        "e5-v1": ALLOWED_TOPOLOGIES,
        "e5-v2": ALLOWED_TOPOLOGIES,
        "e5-v3": ALLOWED_TOPOLOGIES,
        "e5-v4": ALLOWED_TOPOLOGIES,
        "amd-k10": {(2, 2), (4, 4)},
        "amd-ryzen7-5800": {(4, 4)},
        "amd-zen": {(2, 4), (4, 4)},
    }
    for host_id, required in required_coverage.items():
        if not required <= coverage[host_id]:
            fail(f"宿主类 {host_id} 缺少完整家用拓扑兜底")
    if used_profiles != set(profiles):
        fail("manifest.platform_profiles 含未被任何候选使用的孤立组合")
