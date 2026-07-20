#!/usr/bin/env python3
"""导出显式授权的 Q35 + host-passthrough 兼容平台。"""

from __future__ import annotations

import base64
import hashlib
import json
from pathlib import Path
import sys
from typing import Any

from host_platform_manifest import fail, validate_manifest
from host_platform_probe import detect_host_facts, parse_positive_int


def template_digest(root: dict[str, Any], template: dict[str, Any]) -> str:
    """摘要绑定共享策略、通用设备和模板，目录变化会使旧 profile 失配。"""
    material = {
        key: root[key]
        for key in (
            "schema_version", "catalog_revision", "identity_scope",
            "machine_model", "defaults", "selection_policy",
            "smbios_policy", "common",
        )
    }
    material["template"] = template
    encoded = json.dumps(
        material, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def add_pci_triple(
    result: dict[str, str | int],
    prefix: str,
    triple: list[str],
) -> None:
    """把 vendor/device/revision 三元组投影为现有启动器变量。"""
    result[f"{prefix}_PCI_VEN"] = triple[0]
    result[f"{prefix}_PCI_DEV"] = triple[1]
    result[f"{prefix}_REV"] = triple[2]


def export_pairs(
    root: dict[str, Any],
    template: dict[str, Any],
    facts: dict[str, int | str],
    guest_cpus: int,
) -> dict[str, str | int]:
    """把共享模板与宿主事实投影为现有 Linux 启动器变量。"""
    common = root["common"]
    board = common["board"]
    memory = common["memory"]
    devices = common["devices"]
    chipset = devices["chipset"]
    root_port = devices["root_port"]
    xhci = devices["xhci"]
    nvme = devices["nvme"]
    nic = devices["nic"]
    audio = devices["audio"]
    system = common["system"]
    tpm = common["tpm"]

    result: dict[str, str | int] = {
        "PLATFORM_SCHEMA_VERSION": root["schema_version"],
        "PLATFORM_CATALOG_REVISION": root["catalog_revision"],
        "PLATFORM_ID": template["id"],
        "PLATFORM_STATUS": common["status"],
        "PLATFORM_RELEASE_YEAR": common["release_year"],
        "PLATFORM_DEFAULT_VCPUS": root["defaults"]["vcpus"],
        "PLATFORM_DEFAULT_MEMORY_MIB": root["defaults"]["memory_total_mib"],
        "PLATFORM_CPU_SOURCE": "host-passthrough",
        "PLATFORM_MACHINE_MODEL": root["machine_model"],
        "PLATFORM_IDENTITY_SCOPE": root["identity_scope"],
        "PLATFORM_DEVICE_IDENTITY_SCOPE": devices["identity_scope"],
        "PLATFORM_SMBIOS_POLICY": "generic-q35-host",
        "PLATFORM_TEMPLATE_DIGEST": template_digest(root, template),
        "CPU_QEMU_ARG": "host",
        "CPU_VENDOR": facts["vendor"],
        "CPU_NAME": facts["brand"],
        "CPU_MAX_MHZ": facts["max_mhz"],
        "CPU_CUR_MHZ": facts["current_mhz"],
        "CPU_TSC_MHZ": facts["tsc_mhz"],
        "CPU_PART": "",
        "CPU_PROC_FAMILY": "0x0002",
        "CPU_SOCKET": "",
        "CPU_MODEL": "host",
        "CPU_CORES": facts["cores"],
        "CPU_THREADS": guest_cpus,
        "CPU_PHYS_BITS": facts["guest_phys_bits"],
        "CPU_FEATURES": "",
        "CPU_SMBIOS_UPGRADE": "0x02",
        "CPU_SMBIOS_VOLTAGE": 0,
        "CPU_SMBIOS_EXT_CLOCK": 0,
        "CPU_SMBIOS_CHARACTERISTICS": "0x00EC",
        "CPU_IGPU_PRESENT": 0,
        "CPU_IGPU_STATE": "not_exposed",
        "CPU_IGPU_MODEL": "not_exposed",
        "CPU_HOST_FAMILY": facts["family"],
        "CPU_HOST_MODEL": facts["model"],
        "CPU_HOST_STEPPING": facts["stepping"],
        "CPU_HOST_CORES": facts["cores"],
        "CPU_HOST_ONLINE_THREADS": facts["online_threads"],
        "CPU_HOST_PHYS_BITS": facts["phys_bits"],
        "CPU_HOST_TSC_KHZ": facts["tsc_khz"],
        "CPU_HOST_FINGERPRINT": facts["fingerprint"],
        "BOARD_MFR": board["manufacturer"],
        "BOARD_PRODUCT": board["product"],
        "BOARD_FAMILY": board["family"],
        "BOARD_VERSION": board["version"],
        "SERIAL_FN": board["serial_fn"],
        "BOARD_SUBSYS_VEN": board["subsystem_vendor"],
        "BOARD_SUBSYS_DEV": board["subsystem_device"],
        "PCH_MODEL": board["pch"],
        "PCIE_GENERATION": board["pcie_generation"],
        "BOARD_DIMM_SLOTS": board["dimm_slots"],
        "BOARD_MAX_MEMORY_GIB": board["max_memory_gib"],
        "MEM_TYPE": memory["type"],
        "MEM_CHANNELS": memory["channels"],
        "MEM_MAX_MTS": memory["max_mts"],
        "MEM_ALLOWED_MTS": ",".join(str(value) for value in memory["allowed_mts"]),
        "MEM_VOLTAGE_MV": memory["voltage_mv"],
        "MEM_RANK": memory["rank"],
        "MEM_MODULE_MB": ",".join(str(value) for value in memory["module_mib"]),
        "MEM_ALLOWED_TOTAL_MB": ",".join(
            str(value) for value in memory["allowed_total_mib"]
        ),
        "MEM_MAX_CAPACITY_MB": board["max_memory_gib"] * 1024,
        "ROOT_PORT_PCI_VEN": root_port["pci_vendor"],
        "ROOT_PORT_PCI_DEV": root_port["pci_device"],
        "ROOT_PORT_REV": root_port["revision"],
        "XHCI_PCI_VEN": xhci["pci_vendor"],
        "XHCI_PCI_DEV": xhci["pci_device"],
        "XHCI_REV": xhci["revision"],
        "NVME_MAX_PCIE_GENERATION": nvme["max_pcie_generation"],
        "NVME_LANES": nvme["lanes"],
        "NVME_BOOT_SUPPORTED": int(nvme["boot_supported"]),
        "NVME_ATTACHMENT": nvme["attachment"],
        "NIC_VENDOR": nic["vendor"],
        "NIC_MODEL": nic["model"],
        "NIC_PCI_VEN": nic["pci_vendor"],
        "NIC_PCI_DEV": nic["pci_device"],
        "NIC_SUBSYSTEM_VEN": nic["subsystem_vendor"],
        "NIC_SUBSYSTEM_DEV": nic["subsystem_device"],
        "NIC_MAC_OUI": nic["mac_oui"],
        "NIC_ATTACHMENT": nic["attachment"],
        "BOARD_NIC_STATE": nic["board_nic_state"],
        "AUDIO_VENDOR": audio["vendor"],
        "AUDIO_CODEC": audio["codec"],
        "AUDIO_CODEC_ID": audio["codec_id"],
        "AUDIO_CODEC_REVISION": audio["codec_revision"],
        "AUDIO_CODEC_SUBSYSTEM_ID": audio["codec_subsystem_id"],
        "AUDIO_IDENTITY_FIDELITY": audio["identity_fidelity"],
        "AUDIO_CONTROLLER_PCI_VEN": audio["controller_pci_vendor"],
        "AUDIO_CONTROLLER_PCI_DEV": audio["controller_pci_device"],
        "BIOS_VENDOR": "",
        "BIOS_VERSION": "",
        "BIOS_DATE": "",
        "SYSTEM_MFR": system["manufacturer"],
        "SYSTEM_PRODUCT": system["product"],
        "SYSTEM_FAMILY": system["family"],
        "SYSTEM_VERSION": system["version"],
        "SYSTEM_CHASSIS_TYPE": system["chassis_type"],
        "TPM_CAPABILITY": tpm["capability"],
        "TPM_SUPPORTED": int(tpm["supported"]),
        "TPM_IMPLEMENTATION": tpm["implementation"],
        "TPM_VERSION": tpm["version"],
        "TPM_FRONTEND": tpm["emulation_frontend"],
        "TPM_PCR_BANKS": ",".join(tpm["pcr_banks"]),
    }
    for key in ("mch", "lpc", "smbus", "ahci"):
        add_pci_triple(result, key.upper(), chipset[key])
    return result


def emit_pairs(pairs: dict[str, str | int]) -> None:
    """使用 base64 传值，Shell 端无需 source/eval。"""
    for key, value in pairs.items():
        encoded = base64.b64encode(str(value).encode("utf-8")).decode("ascii")
        print(f"{key}\t{encoded}")


def select_template(
    root: dict[str, Any],
    template_id: str,
) -> dict[str, Any]:
    """按保留 ID 精确查找，未知模板不得回退到另一厂商。"""
    selected = next(
        (item for item in root["templates"] if item["id"] == template_id),
        None,
    )
    if selected is None:
        fail(f"host compatibility template 不存在: {template_id}")
    return selected


def main() -> int:
    """执行 validate/index/status/export 四个窄动作。"""
    if len(sys.argv) < 3:
        print(
            "usage: host-platform.py MANIFEST validate|index|status|export "
            "[TEMPLATE_ID] [GUEST_CPUS]",
            file=sys.stderr,
        )
        return 2
    path = Path(sys.argv[1])
    action = sys.argv[2]
    try:
        root = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(root, dict):
            fail("manifest 根节点必须是对象")
        validate_manifest(root)
        if action == "validate":
            print(root["catalog_revision"])
            return 0
        if action == "index":
            for template in root["templates"]:
                print(f"{template['id']}|{template['vendor_id']}")
            return 0
        if len(sys.argv) < 4:
            fail(f"{action} 缺少 TEMPLATE_ID")
        selected = select_template(root, sys.argv[3])
        if action == "status":
            print(root["common"]["status"])
            return 0
        if action != "export":
            fail(f"未知动作: {action}")
        if len(sys.argv) != 5:
            fail("export 需要 TEMPLATE_ID 和 GUEST_CPUS")
        guest_cpus = parse_positive_int(sys.argv[4], "GUEST_CPUS", 8192)
        facts = detect_host_facts(guest_cpus)
        if selected["vendor_id"] != facts["vendor"]:
            fail(
                "host compatibility CPU 厂商不匹配: "
                f"template={selected['vendor_id']} host={facts['vendor']}"
            )
        emit_pairs(export_pairs(root, selected, facts, guest_cpus))
        return 0
    except (OSError, json.JSONDecodeError, ValueError) as exc:
        print(
            f"ERROR: 无法使用 host compatibility 清单 {path}: {exc}",
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
