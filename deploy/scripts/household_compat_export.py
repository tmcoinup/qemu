#!/usr/bin/env python3
"""将已校验的家用 compatibility 组合投影成启动器环境变量。"""

from __future__ import annotations

from typing import Any

def export_pairs(root: dict[str, Any], candidate: dict[str, Any]) -> dict[str, Any]:
    """保持与物理 platforms.json 加载器相同的完整字段接口。"""
    profiles = {item["id"]: item for item in root["platform_profiles"]}
    profile = profiles[candidate["profile_id"]]
    cpu, board, memory = candidate["cpu"], profile["board"], profile["memory"]
    devices, bios, system, tpm = (
        profile["devices"], profile["bios"], profile["system"], profile["tpm"]
    )
    storage = profile["storage"]
    chipset, root_port, xhci = devices["chipset"], devices["root_port"], devices["xhci"]
    nvme, nic, audio = devices["nvme"], devices["nic"], devices["audio"]
    smbios, igpu = cpu["smbios"], cpu["integrated_gpu"]
    values: dict[str, Any] = {
        "PLATFORM_SCHEMA_VERSION": root["schema_version"],
        "PLATFORM_CATALOG_REVISION": root["catalog_revision"],
        "PLATFORM_ID": candidate["id"], "PLATFORM_STATUS": candidate["status"],
        "PLATFORM_RELEASE_YEAR": profile["release_year"],
        "PLATFORM_CPU_SOURCE": "named-household-compatibility",
        "PLATFORM_HOST_CLASSES": ",".join(candidate["host_classes"]),
        "PLATFORM_BOOT_STORAGE": storage["boot_bus"],
        "PLATFORM_BOOT_MODEL": storage["boot_model"],
        "PLATFORM_BOOT_FIRMWARE": storage["boot_firmware"],
        "PLATFORM_STORAGE_SWITCH_REQUIRED": int(storage["runtime_switch_required"]),
        "CPU_QEMU_ARG": cpu["qemu_arg"], "CPU_VENDOR": cpu["vendor_id"],
        "CPU_NAME": cpu["name"], "CPU_MAX_MHZ": cpu["max_mhz"],
        "CPU_CUR_MHZ": cpu["current_mhz"], "CPU_TSC_MHZ": cpu["tsc_mhz"],
        "CPU_PART": cpu["part"], "CPU_PROC_FAMILY": smbios["family"],
        "CPU_SOCKET": cpu["socket"], "CPU_MODEL": cpu["qemu_arg"].split(",", 1)[0],
        "CPU_CORES": cpu["cores"], "CPU_THREADS": cpu["threads"],
        "CPU_PHYS_BITS": cpu["phys_bits"], "CPU_FEATURES": cpu["features"],
        "CPU_SMBIOS_UPGRADE": smbios["upgrade"],
        "CPU_SMBIOS_VOLTAGE": smbios["voltage_mv"],
        "CPU_SMBIOS_EXT_CLOCK": smbios["external_clock_mhz"],
        "CPU_SMBIOS_CHARACTERISTICS": smbios["characteristics"],
        "CPU_IGPU_PRESENT": int(igpu["present"]), "CPU_IGPU_STATE": igpu["profile_state"],
        "CPU_IGPU_MODEL": igpu["model"], "BOARD_MFR": board["manufacturer"],
        "BOARD_PRODUCT": board["product"], "BOARD_FAMILY": board["family"],
        "BOARD_VERSION": board["version"], "SERIAL_FN": board["serial_fn"],
        "BOARD_SUBSYS_VEN": board["subsystem_vendor"],
        "BOARD_SUBSYS_DEV": board["subsystem_device"], "PCH_MODEL": board["pch"],
        "PCIE_GENERATION": board["pcie_generation"],
        "BOARD_DIMM_SLOTS": board["dimm_slots"],
        "BOARD_MAX_MEMORY_GIB": board["max_memory_gib"],
        "MEM_TYPE": memory["type"], "MEM_CHANNELS": memory["channels"],
        "MEM_MAX_MTS": memory["max_mts"],
        "MEM_ALLOWED_MTS": ",".join(map(str, memory["allowed_mts"])),
        "MEM_VOLTAGE_MV": memory["voltage_mv"], "MEM_RANK": memory["rank"],
        "MEM_MODULE_MB": ",".join(map(str, memory["module_mib"])),
        "MEM_ALLOWED_TOTAL_MB": ",".join(map(str, memory["allowed_total_mib"])),
        "MEM_MAX_CAPACITY_MB": board["max_memory_gib"] * 1024,
        "BIOS_VENDOR": bios["vendor"], "BIOS_VERSION": bios["version"],
        "BIOS_DATE": bios["date"], "SYSTEM_MFR": board["manufacturer"],
        "SYSTEM_PRODUCT": system["product"], "SYSTEM_FAMILY": system["family"],
        "SYSTEM_VERSION": board["version"],
        "SYSTEM_CHASSIS_TYPE": system["chassis_type"],
        "CHASSIS_TYPE": system["chassis_type"],
        "TPM_CAPABILITY": tpm["capability"], "TPM_SUPPORTED": int(tpm["supported"]),
        "TPM_IMPLEMENTATION": tpm["implementation"], "TPM_VERSION": tpm["version"],
        "TPM_FRONTEND": tpm["emulation_frontend"],
        "TPM_PCR_BANKS": ",".join(tpm["pcr_banks"]),
    }
    for prefix, key in (
        ("MCH", "mch"), ("LPC", "lpc"), ("SMBUS", "smbus"), ("AHCI", "ahci")
    ):
        triple = chipset[key]
        values[f"{prefix}_PCI_VEN"] = triple[0]
        values[f"{prefix}_PCI_DEV"] = triple[1]
        values[f"{prefix}_REV"] = triple[2]
    values.update({
        "ROOT_PORT_PCI_VEN": root_port["pci_vendor"],
        "ROOT_PORT_PCI_DEV": root_port["pci_device"], "ROOT_PORT_REV": root_port["revision"],
        "XHCI_PCI_VEN": xhci["pci_vendor"], "XHCI_PCI_DEV": xhci["pci_device"],
        "XHCI_REV": xhci["revision"],
        "NVME_MAX_PCIE_GENERATION": nvme["max_pcie_generation"],
        "NVME_LANES": nvme["lanes"], "NVME_BOOT_SUPPORTED": int(nvme["boot_supported"]),
        "NVME_ATTACHMENT": nvme["attachment"], "NIC_VENDOR": nic["vendor"],
        "NVME_ROLE": storage["nvme_role"],
        "NIC_MODEL": nic["model"], "NIC_PCI_VEN": nic["pci_vendor"],
        "NIC_PCI_DEV": nic["pci_device"], "NIC_SUBSYSTEM_VEN": nic["subsystem_vendor"],
        "NIC_SUBSYSTEM_DEV": nic["subsystem_device"], "NIC_MAC_OUI": nic["mac_oui"],
        "NIC_ATTACHMENT": nic["attachment"], "BOARD_NIC_STATE": nic["board_nic_state"],
        "AUDIO_VENDOR": audio["vendor"], "AUDIO_CODEC": audio["codec"],
        "AUDIO_CODEC_ID": audio["codec_id"],
        "AUDIO_CODEC_REVISION": audio["codec_revision"],
        "AUDIO_CODEC_SUBSYSTEM_ID": audio["codec_subsystem_id"],
        "AUDIO_IDENTITY_FIDELITY": audio["identity_fidelity"],
        "AUDIO_CONTROLLER_PCI_VEN": audio["controller_pci_vendor"],
        "AUDIO_CONTROLLER_PCI_DEV": audio["controller_pci_device"],
    })
    return values
