#!/usr/bin/env python3
"""共享整机平台清单的严格解析与一致性校验。"""

from __future__ import annotations

import datetime
import json
import pathlib
import re
from typing import Any

from board_vendor_policy import (
    source_ref_allowed, source_ref_is_board_vendor, source_ref_is_cpu_vendor,
    validate_board_vendor_fields,
)
from guest_cpu_policy import (
    forbidden_server_identity, household_brand_allowed,
    named_household_qemu_base_allowed,
)
from platform_cpu_policy import (
    platform_identity_id, validate_h310_cpu_policy, validate_platform_fact_digests,
)


ROOT_KEYS = {"schema_version", "catalog_revision", "defaults", "fidelity", "platforms"}
PLATFORM_KEYS = {
    "id", "enabled", "status", "release_year", "cpu", "board", "memory",
    "devices", "bios", "system", "tpm", "source_refs",
}
CPU_KEYS = {
    "qemu_arg", "vendor_id", "name", "max_mhz", "current_mhz", "tsc_mhz",
    "part", "socket", "cores", "threads", "phys_bits", "features",
    "integrated_gpu", "smbios",
}
BOARD_KEYS = {
    "manufacturer", "product", "family", "version", "serial_fn",
    "subsystem_vendor", "subsystem_device", "pch", "pcie_generation",
    "dimm_slots", "max_memory_gib",
}
MEMORY_KEYS = {
    "type", "channels", "max_mts", "allowed_mts", "voltage_mv", "rank",
    "module_mib", "allowed_total_mib",
}


def fail(message: str) -> None:
    """用统一异常类型阻止调用方把损坏清单当成空候选池。"""
    raise ValueError(message)


def exact(mapping: dict[str, Any], keys: set[str], where: str) -> None:
    """同时拒绝缺字段和未知字段。"""
    if set(mapping) != keys:
        fail(
            f"{where} 字段集合错误：missing={sorted(keys - set(mapping))} "
            f"unknown={sorted(set(mapping) - keys)}"
        )


def require(
    mapping: dict[str, Any],
    key: str,
    expected_type: type,
    where: str,
) -> Any:
    """读取必填字段，并禁止布尔值冒充整数。"""
    if key not in mapping:
        fail(f"{where} 缺少字段 {key}")
    value = mapping[key]
    if expected_type is int and isinstance(value, bool):
        fail(f"{where}.{key} 类型错误：布尔值不能代替整数")
    if not isinstance(value, expected_type):
        fail(f"{where}.{key} 类型错误，应为 {expected_type.__name__}")
    return value


def require_hex(value: str, where: str, widths: tuple[int, ...] = (4,)) -> None:
    """PCI/SMBIOS 十六进制统一使用 0x 前缀和固定宽度。"""
    if not re.fullmatch(r"0x[0-9A-Fa-f]+", value) or len(value) - 2 not in widths:
        fail(f"{where} 不是允许宽度的 0x 十六进制值")


def duplicate_guard(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    """在 JSON 解码阶段拒绝重复键。"""
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            fail(f"JSON 对象包含重复字段 {key}")
        result[key] = value
    return result


def validate_tpm(
    tpm: dict[str, Any],
    cpu_vendor: str,
    board_policy: dict[str, Any],
    where: str,
) -> None:
    """联合校验主板 TPM 能力与项目仿真前端。"""
    exact(tpm, {
        "capability", "supported", "implementation", "version",
        "emulation_frontend", "pcr_banks", "support_source_ref",
        "version_source_ref",
    }, where)
    capability = require(tpm, "capability", str, where)
    supported = require(tpm, "supported", bool, where)
    implementation = require(tpm, "implementation", str, where)
    version = require(tpm, "version", str, where)
    frontend = require(tpm, "emulation_frontend", str, where)
    banks = require(tpm, "pcr_banks", list, where)
    if capability not in ("none", "firmware", "discrete"):
        fail(f"{where}.capability 不在受控集合")
    if implementation not in ("none", "intel-ptt", "amd-ftpm", "discrete-module"):
        fail(f"{where}.implementation 不在受控集合")
    if version not in ("none", "1.2", "2.0"):
        fail(f"{where}.version 不在受控集合")
    if frontend not in ("none", "tpm-tis", "tpm-crb"):
        fail(f"{where}.emulation_frontend 不在受控集合")
    if (
        any(not isinstance(bank, str) or bank not in ("sha1", "sha256") for bank in banks)
        or len(banks) != len(set(banks))
    ):
        fail(f"{where}.pcr_banks 含无效或重复算法")
    sources = (
        require(tpm, "support_source_ref", str, where),
        require(tpm, "version_source_ref", str, where),
    )
    for source in sources:
        if not source_ref_allowed(source, board_policy, cpu_vendor):
            fail(f"{where} 必须使用当前主板或 CPU 厂商的官方 HTTPS TPM 来源")
    if sources[0] == sources[1]:
        fail(f"{where} 必须分别记录平台支持与 TPM 版本证据")
    if not supported:
        if (capability, implementation, version, frontend, banks) != (
            "none", "none", "none", "none", [],
        ):
            fail(f"{where} 禁用 TPM 时必须完整 fail closed")
        return
    if "none" in (capability, implementation, version, frontend) or not banks:
        fail(f"{where} 支持 TPM 时所有能力字段必须完整")
    if frontend == "tpm-crb" and version != "2.0":
        fail(f"{where} tpm-crb 仅允许 TPM 2.0")
    if version == "1.2" and banks != ["sha1"]:
        fail(f"{where} TPM 1.2 仅允许 sha1 PCR bank")
    expected_firmware = {"AuthenticAMD": "amd-ftpm", "GenuineIntel": "intel-ptt"}
    if capability == "firmware" and implementation != expected_firmware[cpu_vendor]:
        fail(f"{where} 固件 TPM 实现与 CPU 厂商不一致")
    if (capability == "discrete") != (implementation == "discrete-module"):
        fail(f"{where} 独立 TPM capability/implementation 不一致")


def validate_fidelity(root: dict[str, Any]) -> None:
    """锁定 Q35 行为边界，避免 supported 被误读成目标 PCH 等价。"""
    fidelity = require(root, "fidelity", dict, "manifest")
    controlled = {
        "supported_semantics": "launch_candidate_after_runtime_preflight",
        "machine_model": "q35",
        "chipset_identity_scope": "pci_configuration_identity_only",
        "target_pch_behavior": "not_emulated",
        "serial_identity_scope": "synthetic_format_only_no_device_capture",
        "asset_tag_identity_scope": "synthetic_format_only_no_device_capture",
        "mac_identity_scope": "vendor_oui_synthetic_suffix",
        "pci_subsystem_evidence": "catalog_reference_no_lspci_snapshot",
    }
    expected_keys = set(controlled) | {"target_pch_bdf_equivalent", "bdf_layout"}
    exact(fidelity, expected_keys, "manifest.fidelity")
    for key, expected in controlled.items():
        if require(fidelity, key, str, "manifest.fidelity") != expected:
            fail(f"manifest.fidelity.{key} 必须为 {expected}")
    if require(fidelity, "target_pch_bdf_equivalent", bool, "manifest.fidelity"):
        fail("manifest.fidelity 不得宣称 Q35 BDF 与目标 PCH 等价")
    layout = require(fidelity, "bdf_layout", dict, "manifest.fidelity")
    expected_layout = {
        "mch": "00:00.0",
        "lpc": "00:1f.0",
        "ahci": "00:1f.2",
        "smbus": "00:1f.3",
        "linux_root_ports": ["00:01.0", "00:02.0", "00:03.0", "00:04.0"],
        "linux_hda": "00:05.0",
        "windows_root_ports": ["00:01.0", "00:02.0", "00:03.0"],
        "windows_hda": "00:04.0",
    }
    if layout != expected_layout:
        fail("manifest.fidelity.bdf_layout 与当前 Q35 启动器不一致")
    for value in layout.values():
        addresses = value if isinstance(value, list) else [value]
        if any(not re.fullmatch(r"[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]", item)
               for item in addresses):
            fail("manifest.fidelity.bdf_layout 含非规范 BDF")


def validate_memory(
    memory: dict[str, Any],
    board: dict[str, Any],
    where: str,
) -> None:
    exact(memory, MEMORY_KEYS, where)
    if require(memory, "type", str, where) not in ("DDR3", "DDR4"):
        fail(f"{where}.type 不支持")
    channels = require(memory, "channels", int, where)
    max_mts = require(memory, "max_mts", int, where)
    allowed_mts = require(memory, "allowed_mts", list, where)
    if channels not in (1, 2, 4) or not allowed_mts:
        fail(f"{where} 通道/速率列表无效")
    if (
        any(isinstance(rate, bool) or not isinstance(rate, int) or not 0 < rate <= max_mts
            for rate in allowed_mts)
        or allowed_mts != sorted(set(allowed_mts))
    ):
        fail(f"{where}.allowed_mts 超过上限、类型错误或重复")
    if board["dimm_slots"] < channels:
        fail(f"{where} DIMM 槽数少于内存通道数")
    if require(memory, "voltage_mv", int, where) not in (1200, 1500):
        fail(f"{where}.voltage_mv 不支持")
    if require(memory, "rank", int, where) not in (1, 2):
        fail(f"{where}.rank 不支持")
    modules = require(memory, "module_mib", list, where)
    totals = require(memory, "allowed_total_mib", list, where)
    for values, key in ((modules, "module_mib"), (totals, "allowed_total_mib")):
        if (
            not values
            or any(isinstance(item, bool) or not isinstance(item, int) or item <= 0
                   for item in values)
            or values != sorted(set(values))
        ):
            fail(f"{where}.{key} 无效或重复")
    possible = {
        size * count
        for size in modules
        for count in range(1, board["dimm_slots"] + 1)
    }
    if any(total not in possible for total in totals):
        fail(f"{where}.allowed_total_mib 无法由 DIMM 物料和槽位组成")
    if max(totals) > board["max_memory_gib"] * 1024:
        fail(f"{where} 总容量超过主板上限")


def validate_devices(
    devices: dict[str, Any],
    board: dict[str, Any],
    where: str,
) -> None:
    exact(devices, {"chipset", "root_port", "xhci", "nvme", "nic", "audio"}, where)
    chipset = require(devices, "chipset", dict, where)
    exact(chipset, {"mch", "lpc", "smbus", "ahci"}, f"{where}.chipset")
    for component_name, component in chipset.items():
        if not isinstance(component, list) or len(component) != 3:
            fail(f"{where}.chipset.{component_name} 必须是 PCI 三元组")
        for index, value in enumerate(component):
            if not isinstance(value, str):
                fail(f"{where}.chipset.{component_name}[{index}] 不是字符串")
            require_hex(value, f"{where}.chipset.{component_name}[{index}]", (2, 4))
    for device_name in ("root_port", "xhci"):
        device = require(devices, device_name, dict, where)
        exact(device, {"pci_vendor", "pci_device", "revision"},
              f"{where}.{device_name}")
        for key in ("pci_vendor", "pci_device"):
            require_hex(require(device, key, str, where), f"{where}.{device_name}.{key}")
        require_hex(require(device, "revision", str, where),
                    f"{where}.{device_name}.revision", (2,))
    nvme = require(devices, "nvme", dict, where)
    exact(nvme, {"max_pcie_generation", "lanes", "boot_supported", "attachment"},
          f"{where}.nvme")
    if require(nvme, "max_pcie_generation", int, where) > board["pcie_generation"]:
        fail(f"{where}.nvme PCIe 代际超过主板")
    if require(nvme, "lanes", int, where) not in (1, 2, 4):
        fail(f"{where}.nvme lane 数无效")
    require(nvme, "boot_supported", bool, where)
    if require(nvme, "attachment", str, where) != "m2_socket":
        fail(f"{where}.nvme 当前只允许可核验的主板 M.2 socket")

    nic = require(devices, "nic", dict, where)
    exact(nic, {
        "vendor", "model", "pci_vendor", "pci_device", "subsystem_vendor",
        "subsystem_device", "mac_oui", "attachment", "board_nic_state",
    }, f"{where}.nic")
    for key in ("pci_vendor", "pci_device", "subsystem_vendor", "subsystem_device"):
        require_hex(require(nic, key, str, where), f"{where}.nic.{key}")
    if not re.fullmatch(r"[0-9a-f]{2}(?::[0-9a-f]{2}){2}",
                        require(nic, "mac_oui", str, where)):
        fail(f"{where}.nic.mac_oui 必须是小写三字节 OUI")
    expected_nic = (
        "0x8086", "0x10D3", "0x8086", "0xA01F", "3c:fd:fe",
        "add_in", "disabled_in_bios",
    )
    actual_nic = (
        nic["pci_vendor"], nic["pci_device"], nic["subsystem_vendor"],
        nic["subsystem_device"], nic["mac_oui"], nic["attachment"],
        nic["board_nic_state"],
    )
    if actual_nic != expected_nic:
        fail(f"{where}.nic 当前行为模型只能声明 Intel 82574L add-in")

    audio = require(devices, "audio", dict, where)
    exact(audio, {
        "vendor", "codec", "codec_id", "codec_revision", "codec_subsystem_id",
        "identity_fidelity", "controller_pci_vendor", "controller_pci_device",
    }, f"{where}.audio")
    for key in ("codec_id", "codec_revision", "codec_subsystem_id"):
        require_hex(require(audio, key, str, where), f"{where}.audio.{key}", (8,))
    for key in ("controller_pci_vendor", "controller_pci_device"):
        require_hex(require(audio, key, str, where), f"{where}.audio.{key}")
    if (
        audio["codec"], audio["codec_id"], audio["codec_revision"],
        audio["identity_fidelity"],
    ) != ("ALC887", "0x10ec0887", "0x00100302", "protocol_identity_only"):
        fail(f"{where}.audio 不是已审计 ALC887 协议身份")
    if audio["codec_subsystem_id"][2:6].lower() != board["subsystem_vendor"][2:].lower():
        fail(f"{where}.audio codec subsystem vendor 与主板厂商不一致")


def validate_platform(
    platform: dict[str, Any],
    seen_ids: set[str],
) -> None:
    """校验影响整机一致性的硬约束。"""
    exact(platform, PLATFORM_KEYS, "platform")
    platform_id = require(platform, "id", str, "platform")
    where = f"platform[{platform_id}]"
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{7,95}", platform_id):
        fail(f"{where}.id 格式错误")
    if platform_id in seen_ids:
        fail(f"平台 id 重复：{platform_id}")
    seen_ids.add(platform_id)
    enabled = require(platform, "enabled", bool, where)
    status = require(platform, "status", str, where)
    if status not in ("supported", "compatibility") or (enabled and status != "supported"):
        fail(f"{where} enabled/status 组合非法")
    release_year = require(platform, "release_year", int, where)
    if not 2005 <= release_year <= datetime.date.today().year:
        fail(f"{where}.release_year 超出合理范围")

    cpu = require(platform, "cpu", dict, where)
    board = require(platform, "board", dict, where)
    exact(cpu, CPU_KEYS, f"{where}.cpu")
    exact(board, BOARD_KEYS, f"{where}.board")
    for key in ("qemu_arg", "vendor_id", "name", "part", "socket", "features"):
        if not require(cpu, key, str, f"{where}.cpu"):
            fail(f"{where}.cpu.{key} 不能为空")
    if cpu["vendor_id"] not in ("AuthenticAMD", "GenuineIntel"):
        fail(f"{where}.cpu.vendor_id 不支持")
    if (
        not named_household_qemu_base_allowed(cpu["qemu_arg"])
        or forbidden_server_identity(cpu["name"], cpu["qemu_arg"])
        or not household_brand_allowed(cpu["vendor_id"], cpu["name"])
    ):
        fail(f"{where}.cpu 不是受控家用型号，或包含服务器/E 系列身份")
    for key in ("max_mhz", "current_mhz", "tsc_mhz", "cores", "threads", "phys_bits"):
        if require(cpu, key, int, f"{where}.cpu") <= 0:
            fail(f"{where}.cpu.{key} 必须为正整数")
    if cpu["current_mhz"] > cpu["max_mhz"] or cpu["tsc_mhz"] != cpu["current_mhz"]:
        fail(f"{where}.cpu 频率/TSC 不自洽")
    if (cpu["cores"], cpu["threads"]) not in {(2, 2), (2, 4), (4, 4)}:
        fail(f"{where}.cpu 拓扑不在 2C2T/2C4T/4C4T 家用白名单")
    if not 32 <= cpu["phys_bits"] <= 52:
        fail(f"{where}.cpu.phys_bits 超出 QEMU/KVM 范围")
    if cpu["vendor_id"] == "GenuineIntel" and "+topoext" in cpu["features"]:
        fail(f"{where} Intel CPU 不得启用 AMD topoext")
    if cpu["vendor_id"] == "AuthenticAMD" and "+topoext" not in cpu["features"]:
        fail(f"{where} AMD Zen 平台缺少 topoext")

    igpu = require(cpu, "integrated_gpu", dict, f"{where}.cpu")
    exact(igpu, {"present", "profile_state", "model"}, f"{where}.cpu.integrated_gpu")
    present = require(igpu, "present", bool, f"{where}.cpu.integrated_gpu")
    state = require(igpu, "profile_state", str, f"{where}.cpu.integrated_gpu")
    model = require(igpu, "model", str, f"{where}.cpu.integrated_gpu")
    if state not in ("absent", "fused_off", "disabled_in_bios"):
        fail(f"{where}.cpu.integrated_gpu 状态不受支持")
    if present != (state == "disabled_in_bios") or ((model == "none") == present):
        fail(f"{where}.cpu.integrated_gpu 状态/型号矛盾")

    smbios = require(cpu, "smbios", dict, f"{where}.cpu")
    exact(smbios, {
        "family", "upgrade", "voltage_mv", "external_clock_mhz",
        "characteristics",
    }, f"{where}.cpu.smbios")
    for key in ("family", "upgrade", "characteristics"):
        require_hex(require(smbios, key, str, f"{where}.cpu.smbios"),
                    f"{where}.cpu.smbios.{key}", (2, 4))
    for key in ("voltage_mv", "external_clock_mhz"):
        if require(smbios, key, int, f"{where}.cpu.smbios") <= 0:
            fail(f"{where}.cpu.smbios.{key} 必须为正整数")
    has_hardware_threads = bool(int(smbios["characteristics"], 16) & 0x0010)
    if (cpu["threads"] > cpu["cores"]) != has_hardware_threads:
        fail(f"{where}.cpu.smbios.characteristics 的 Hardware Thread 位错误")
    family_by_name = {
        "Ryzen ": 0x006B,
        "Core(TM) i3-": 0x00CE,
        "Core(TM) i5-": 0x00CD,
        "Celeron(R) ": 0x00C7,
        "Pentium(R) Gold ": 0x000B,
    }
    expected_family = next(
        (value for token, value in family_by_name.items() if token in cpu["name"]),
        None,
    )
    if expected_family is not None and int(smbios["family"], 16) != expected_family:
        fail(f"{where}.cpu.smbios.family 与 DMTF CPU 系列不一致")

    for key in (
        "manufacturer", "product", "family", "version", "serial_fn",
        "subsystem_vendor", "subsystem_device", "pch",
    ):
        if not require(board, key, str, f"{where}.board"):
            fail(f"{where}.board.{key} 不能为空")
    for key in ("subsystem_vendor", "subsystem_device"):
        require_hex(board[key], f"{where}.board.{key}")
    board_policy = validate_board_vendor_fields(board, f"{where}.board")
    for key in ("pcie_generation", "dimm_slots", "max_memory_gib"):
        if require(board, key, int, f"{where}.board") <= 0:
            fail(f"{where}.board.{key} 必须为正整数")
    if platform_id != platform_identity_id(cpu, board):
        fail(f"{where}.id 与 CPU/主板组合不一致")

    validate_memory(require(platform, "memory", dict, where), board, f"{where}.memory")
    validate_devices(require(platform, "devices", dict, where), board, f"{where}.devices")
    bios = require(platform, "bios", dict, where)
    exact(bios, {"vendor", "version", "date"}, f"{where}.bios")
    for key in ("vendor", "version", "date"):
        if not require(bios, key, str, f"{where}.bios"):
            fail(f"{where}.bios.{key} 不能为空")
    try:
        datetime.datetime.strptime(bios["date"], "%m/%d/%Y")
    except ValueError as exc:
        fail(f"{where}.bios.date 必须为 MM/DD/YYYY：{exc}")
    system = require(platform, "system", dict, where)
    exact(system, {"product", "family", "chassis_type"}, f"{where}.system")
    if not require(system, "product", str, f"{where}.system"):
        fail(f"{where}.system.product 不能为空")
    if not require(system, "family", str, f"{where}.system"):
        fail(f"{where}.system.family 不能为空")
    chassis = require(system, "chassis_type", str, f"{where}.system")
    require_hex(chassis, f"{where}.system.chassis_type", (2,))
    if chassis != "0x03":
        fail(f"{where}.system.chassis_type 当前只允许 Desktop 0x03")
    validate_tpm(
        require(platform, "tpm", dict, where), cpu["vendor_id"], board_policy,
        f"{where}.tpm",
    )

    refs = require(platform, "source_refs", list, where)
    if (
        len(refs) < 3
        or len(refs) != len(set(refs))
        or any(
            not isinstance(ref, str)
            or not source_ref_allowed(ref, board_policy, cpu["vendor_id"])
            for ref in refs
        )
    ):
        fail(f"{where}.source_refs 至少需要三个不重复的官方 HTTPS 来源")
    if not any(source_ref_is_cpu_vendor(ref, cpu["vendor_id"]) for ref in refs):
        fail(f"{where}.source_refs 缺少 CPU 厂商型号规格")
    if not any(source_ref_is_board_vendor(ref, board_policy) for ref in refs):
        fail(f"{where}.source_refs 缺少当前主板厂商官方资料")
    validate_h310_cpu_policy(platform, where)
    validate_platform_fact_digests(platform, where)


def validate_manifest(root: dict[str, Any]) -> None:
    """验证清单根、受控语义以及全部完整平台。"""
    exact(root, ROOT_KEYS, "manifest")
    if require(root, "schema_version", int, "manifest") != 1:
        fail("不支持的 schema_version")
    revision = require(root, "catalog_revision", str, "manifest")
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}\.\d+", revision):
        fail("manifest.catalog_revision 格式错误")
    defaults = require(root, "defaults", dict, "manifest")
    exact(defaults, {"vcpus", "memory_total_mib"}, "manifest.defaults")
    for key in ("vcpus", "memory_total_mib"):
        if require(defaults, key, int, "manifest.defaults") <= 0:
            fail(f"manifest.defaults.{key} 必须为正整数")
    validate_fidelity(root)
    platforms = require(root, "platforms", list, "manifest")
    if not platforms:
        fail("platforms 不能为空")
    seen: set[str] = set()
    for item in platforms:
        if not isinstance(item, dict):
            fail("platforms 条目必须是对象")
        validate_platform(item, seen)


def load_manifest(path: pathlib.Path) -> dict[str, Any]:
    """读取 JSON，并在返回前完成全部严格校验。"""
    try:
        root = json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=duplicate_guard,
        )
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"无法读取清单 {path}: {exc}")
    if not isinstance(root, dict):
        fail("清单根节点必须是对象")
    validate_manifest(root)
    return root
