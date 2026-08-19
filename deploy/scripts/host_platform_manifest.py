#!/usr/bin/env python3
"""host compatibility 共享清单的严格结构校验。"""

from __future__ import annotations

import re
from typing import Any


SUPPORTED_VENDORS = {"GenuineIntel", "AuthenticAMD"}
HEX4_RE = re.compile(r"0x[0-9A-F]{4}")


def fail(message: str) -> None:
    """以可定位的中文错误拒绝损坏或语义漂移的清单。"""
    raise ValueError(message)


def require(mapping: dict[str, Any], key: str, value_type: type, where: str) -> Any:
    """读取必填字段；布尔值不能冒充 Python 整数。"""
    if key not in mapping:
        fail(f"{where} 缺少字段 {key}")
    value = mapping[key]
    if value_type is int and isinstance(value, bool):
        fail(f"{where}.{key} 不能用布尔值代替整数")
    if not isinstance(value, value_type):
        fail(f"{where}.{key} 类型错误，应为 {value_type.__name__}")
    return value


def require_exact_keys(mapping: dict[str, Any], keys: set[str], where: str) -> None:
    """锁定结构，避免拼写错误或未知策略被静默忽略。"""
    if set(mapping) != keys:
        missing = sorted(keys - set(mapping))
        unknown = sorted(set(mapping) - keys)
        fail(f"{where} 字段集合错误：missing={missing} unknown={unknown}")


def require_hex4(value: str, where: str) -> None:
    """PCI 标识统一用四位大写十六进制，便于跨平台逐字绑定。"""
    if not HEX4_RE.fullmatch(value):
        fail(f"{where} 必须是 0x 加四位大写十六进制")


def validate_board(board: dict[str, Any]) -> None:
    """通用主板只能陈述 QEMU/Q35 事实，不能借用物理板厂身份。"""
    keys = {
        "manufacturer", "product", "family", "version", "serial_fn",
        "subsystem_vendor", "subsystem_device", "pch", "pcie_generation",
        "dimm_slots", "max_memory_gib",
    }
    require_exact_keys(board, keys, "manifest.common.board")
    expected_text = {
        "manufacturer": "QEMU",
        "product": "Standard PC (Q35 + ICH9, 2009)",
        "family": "Q35 Virtual Platform",
        "version": "pc-q35",
        "serial_fn": "_serial_qemu",
        "pch": "QEMU Q35/ICH9",
    }
    for key, expected in expected_text.items():
        if require(board, key, str, "manifest.common.board") != expected:
            fail(f"manifest.common.board.{key} 不是受控 Q35 值")
    for key in ("subsystem_vendor", "subsystem_device"):
        require_hex4(
            require(board, key, str, "manifest.common.board"),
            f"manifest.common.board.{key}",
        )
    for key in ("pcie_generation", "dimm_slots", "max_memory_gib"):
        if require(board, key, int, "manifest.common.board") <= 0:
            fail(f"manifest.common.board.{key} 必须为正整数")


def validate_memory(memory: dict[str, Any]) -> None:
    """验证客体虚拟 DIMM 几何，不反推宿主的物理内存类型。"""
    keys = {
        "type", "channels", "max_mts", "allowed_mts", "voltage_mv",
        "rank", "module_mib", "allowed_total_mib",
    }
    require_exact_keys(memory, keys, "manifest.common.memory")
    if require(memory, "type", str, "manifest.common.memory") != "DDR4":
        fail("host compatibility 虚拟内存当前固定为 DDR4")
    for key in ("channels", "max_mts", "voltage_mv", "rank"):
        if require(memory, key, int, "manifest.common.memory") <= 0:
            fail(f"manifest.common.memory.{key} 必须为正整数")
    for key in ("allowed_mts", "module_mib", "allowed_total_mib"):
        values = require(memory, key, list, "manifest.common.memory")
        if not values or len(values) != len(set(values)) or any(
            isinstance(value, bool) or not isinstance(value, int) or value <= 0
            for value in values
        ):
            fail(f"manifest.common.memory.{key} 含无效或重复值")


def validate_devices(devices: dict[str, Any]) -> None:
    """锁定会进入 QEMU argv 的原生/通用虚拟设备标识。"""
    keys = {"identity_scope", "chipset", "root_port", "xhci", "nvme", "nic", "audio"}
    require_exact_keys(devices, keys, "manifest.common.devices")
    if require(devices, "identity_scope", str, "manifest.common.devices") != (
        "explicit_virtual_compatibility"
    ):
        fail("manifest.common.devices.identity_scope 非法")
    chipset = require(devices, "chipset", dict, "manifest.common.devices")
    require_exact_keys(
        chipset, {"mch", "lpc", "smbus", "ahci"},
        "manifest.common.devices.chipset",
    )
    for key, triple in chipset.items():
        if not isinstance(triple, list) or len(triple) != 3:
            fail(f"manifest.common.devices.chipset.{key} 必须是 PCI 三元组")
        require_hex4(triple[0], f"chipset.{key}.vendor")
        require_hex4(triple[1], f"chipset.{key}.device")
        if not re.fullmatch(r"0x[0-9A-F]{2}", triple[2]):
            fail(f"chipset.{key}.revision 必须是两位十六进制")
    for key in ("root_port", "xhci"):
        item = require(devices, key, dict, "manifest.common.devices")
        require_exact_keys(
            item, {"pci_vendor", "pci_device", "revision"},
            f"manifest.common.devices.{key}",
        )
        require_hex4(item["pci_vendor"], f"{key}.pci_vendor")
        require_hex4(item["pci_device"], f"{key}.pci_device")
        if not re.fullmatch(r"0x[0-9A-F]{2}", item["revision"]):
            fail(f"{key}.revision 必须是两位十六进制")
    expected_devices = {
        "nvme": {
            "max_pcie_generation": 3,
            "lanes": 4,
            "boot_supported": True,
            "attachment": "pcie_root_port",
        },
        "nic": {
            "vendor": "Intel",
            "model": "Intel 82574L Gigabit Network Connection",
            "pci_vendor": "0x8086",
            "pci_device": "0x10D3",
            "subsystem_vendor": "0x8086",
            "subsystem_device": "0xA01F",
            "mac_oui": "3c:fd:fe",
            "attachment": "add_in",
            "board_nic_state": "not_applicable",
        },
        "audio": {
            "vendor": "QEMU",
            "codec": "Generic HDA Codec",
            "codec_id": "0x1AF40022",
            "codec_revision": "0x00100101",
            "codec_subsystem_id": "0x1AF40022",
            "identity_fidelity": "generic_virtual_protocol",
            "controller_pci_vendor": "0x8086",
            "controller_pci_device": "0x293E",
        },
    }
    for key, expected in expected_devices.items():
        if require(devices, key, dict, "manifest.common.devices") != expected:
            fail(f"manifest.common.devices.{key} 偏离受控虚拟设备身份")


def validate_system_firmware(common: dict[str, Any]) -> None:
    """固件保持运行时默认；系统/机箱只报告明确的 QEMU 平台。"""
    bios = require(common, "bios", dict, "manifest.common")
    if bios != {"mode": "runtime_firmware_default"}:
        fail("manifest.common.bios 只能声明 runtime_firmware_default")
    system = require(common, "system", dict, "manifest.common")
    expected = {
        "manufacturer": "QEMU",
        "product": "Standard PC (Q35 + ICH9, 2009)",
        "family": "Q35 Virtual Platform",
        "version": "pc-q35",
        "chassis_type": "0x03",
    }
    if system != expected:
        fail("manifest.common.system 偏离受控 Q35 身份")


def validate_tpm(tpm: dict[str, Any]) -> None:
    """宿主兜底不猜测物理板 TPM；默认必须完整关闭。"""
    expected = {
        "capability": "none",
        "supported": False,
        "implementation": "none",
        "version": "none",
        "emulation_frontend": "none",
        "pcr_banks": [],
    }
    if tpm != expected:
        fail("manifest.common.tpm 必须是无 TPM 的 fail-closed 配置")


def validate_manifest(root: dict[str, Any]) -> None:
    """验证共享清单的策略边界及 Linux/Windows 共用字段。"""
    require_exact_keys(
        root,
        {
            "schema_version", "catalog_revision", "identity_scope",
            "machine_model", "defaults", "selection_policy",
            "smbios_policy", "common", "templates",
        },
        "manifest",
    )
    if require(root, "schema_version", int, "manifest") != 1:
        fail("manifest.schema_version 当前只支持 1")
    if not re.fullmatch(
        r"[0-9]{4}-[0-9]{2}-[0-9]{2}\.[0-9]+",
        require(root, "catalog_revision", str, "manifest"),
    ):
        fail("manifest.catalog_revision 格式错误")
    if require(root, "identity_scope", str, "manifest") != (
        "generic_q35_host_passthrough_compatibility"
    ):
        fail("manifest.identity_scope 不是受控 host compatibility 语义")
    if require(root, "machine_model", str, "manifest") != "q35":
        fail("host compatibility 当前只支持 q35")

    defaults = require(root, "defaults", dict, "manifest")
    require_exact_keys(defaults, {"vcpus", "memory_total_mib"}, "manifest.defaults")
    if require(defaults, "vcpus", int, "manifest.defaults") <= 0:
        fail("manifest.defaults.vcpus 必须为正整数")
    if require(defaults, "memory_total_mib", int, "manifest.defaults") <= 0:
        fail("manifest.defaults.memory_total_mib 必须为正整数")

    expected_policy = {
        "requires_explicit_allow": True,
        "physical_platform_claim": False,
        "cpu_vendor_must_match_host": True,
        "cpu_model_source": "host_passthrough",
        "guest_cpu_class": "household_only",
        "server_brand_policy": "reject",
        "host_topology_policy": "bounded_guest_subset_2c2t_2c4t_4c4t",
        "profile_binding": (
            "vendor_brand_family_model_stepping_phys_bits_tsc_topology"
        ),
        "tsc_policy": "host_default_no_tsc_freq",
        "kvm_realize_required": True,
    }
    if require(root, "selection_policy", dict, "manifest") != expected_policy:
        fail("manifest.selection_policy 偏离受控兜底策略")
    expected_smbios = {
        "type0": "runtime_firmware_default",
        "type1_to_type3": "generic_virtual_platform",
        "type4": "host_name_vendor_and_guest_topology",
        "unknown_physical_fields": "omit",
    }
    if require(root, "smbios_policy", dict, "manifest") != expected_smbios:
        fail("manifest.smbios_policy 偏离受控兼容语义")

    common = require(root, "common", dict, "manifest")
    require_exact_keys(
        common,
        {"status", "release_year", "board", "memory", "devices",
         "bios", "system", "tpm"},
        "manifest.common",
    )
    if require(common, "status", str, "manifest.common") != "compatibility":
        fail("host template 必须是 compatibility")
    if require(common, "release_year", int, "manifest.common") != 2009:
        fail("Q35 compatibility release_year 必须固定为 2009")
    validate_board(require(common, "board", dict, "manifest.common"))
    validate_memory(require(common, "memory", dict, "manifest.common"))
    validate_devices(require(common, "devices", dict, "manifest.common"))
    validate_system_firmware(common)
    validate_tpm(require(common, "tpm", dict, "manifest.common"))

    templates = require(root, "templates", list, "manifest")
    if len(templates) != 2:
        fail("manifest.templates 必须恰好包含 Intel/AMD 两个模板")
    expected_ids = {
        "GenuineIntel": "compat-host-intel-q35",
        "AuthenticAMD": "compat-host-amd-q35",
    }
    seen: set[str] = set()
    for index, template in enumerate(templates):
        where = f"manifest.templates[{index}]"
        if not isinstance(template, dict):
            fail(f"{where} 必须是对象")
        require_exact_keys(template, {"id", "vendor_id", "cpu_policy"}, where)
        vendor = require(template, "vendor_id", str, where)
        template_id = require(template, "id", str, where)
        if vendor not in SUPPORTED_VENDORS or template_id != expected_ids.get(vendor):
            fail(f"{where} ID 与 CPU 厂商不匹配")
        if vendor in seen:
            fail(f"{where} CPU 厂商重复")
        seen.add(vendor)
        cpu_policy = require(template, "cpu_policy", dict, where)
        if cpu_policy != {
            "qemu_model": "host",
            "feature_policy": "host_default",
            "integrated_gpu_state": "not_exposed",
        }:
            fail(f"{where}.cpu_policy 偏离 host passthrough 策略")
