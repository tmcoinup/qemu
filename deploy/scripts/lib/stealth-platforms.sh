#!/usr/bin/env bash
# 版本化整机平台清单加载器。
#
# 本文件只负责读取、校验和导出 deploy/hardware/platforms.json；平台事实必须写在
# JSON 中，禁止在这里再维护第二份 CPU/主板映射。Python 标准库负责严格解析 JSON，
# Shell 侧通过 base64 传值，不使用 source/eval 解释清单内容。

_STEALTH_PLATFORMS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${STEALTH_PLATFORM_MANIFEST:=$_STEALTH_PLATFORMS_LIB_DIR/../../hardware/platforms.json}"

_stealth_platform_python() {
    local action="$1"
    local platform_id="${2:-}"
    local strict_hardware="${STRICT_HARDWARE:-1}"
    local allow_compatibility="${ALLOW_PLATFORM_COMPATIBILITY:-0}"

    command -v python3 >/dev/null 2>&1 || {
        echo "ERROR: 读取整机平台清单需要 python3" >&2
        return 1
    }

    # 中文注释：显式把两个门禁值作为 argv 传给 Python，而不是依赖 shell 函数
    # 临时赋值是否进入子进程环境的细节。这样测试里的
    # `ALLOW_PLATFORM_COMPATIBILITY=1 stealth_platform_load ...` 与生产 CLI
    # 具有完全相同的语义。
    python3 - "$STEALTH_PLATFORM_MANIFEST" "$action" "$platform_id" \
        "$strict_hardware" "$allow_compatibility" <<'PY'
import base64
import datetime
import json
import pathlib
import re
import sys


def fail(message: str) -> None:
    """用统一格式终止，避免调用方把损坏清单当成空候选池。"""
    raise ValueError(message)


def require(mapping: dict, key: str, expected_type: type, where: str):
    """读取必填字段，同时给出能定位到平台和字段的中文错误。"""
    if key not in mapping:
        fail(f"{where} 缺少字段 {key}")
    value = mapping[key]
    if expected_type is int and isinstance(value, bool):
        fail(f"{where}.{key} 类型错误：布尔值不能代替整数")
    if not isinstance(value, expected_type):
        fail(f"{where}.{key} 类型错误，应为 {expected_type.__name__}")
    return value


def require_hex(value: str, where: str, width: tuple[int, ...] = (4,)) -> None:
    """PCI/SMBIOS 十六进制统一使用 0x 前缀，防止十进制/十六进制混写。"""
    if not re.fullmatch(r"0x[0-9A-Fa-f]+", value):
        fail(f"{where} 不是 0x 十六进制值")
    if len(value) - 2 not in width:
        fail(f"{where} 十六进制宽度错误")


def validate_fidelity(root: dict) -> None:
    """锁定 Q35 行为边界，避免 supported 被误读成目标 PCH 等价。"""
    fidelity = require(root, "fidelity", dict, "manifest")
    controlled = {
        "supported_semantics": "launch_candidate_after_runtime_preflight",
        "machine_model": "q35",
        "chipset_identity_scope": "pci_configuration_identity_only",
        "target_pch_behavior": "not_emulated",
    }
    for key, expected in controlled.items():
        actual = require(fidelity, key, str, "manifest.fidelity")
        if actual != expected:
            fail(f"manifest.fidelity.{key} 必须为受控值 {expected}")
    if require(fidelity, "target_pch_bdf_equivalent", bool,
               "manifest.fidelity") is not False:
        fail("manifest.fidelity 不得宣称 Q35 BDF 与目标 PCH 等价")

    # 地址是当前 Linux/Windows 启动器实际生成的 Q35 布局。HDA 位于最后一个
    # 自动分配 root port 之后，所以两个启动器的端口数不同会产生不同地址。
    # 这些值不是 H110/H310 固定功能布局；调整设备顺序时必须同步升级目录修订号。
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
    if set(layout) != set(expected_layout):
        fail("manifest.fidelity.bdf_layout 字段集合不完整或含未知字段")
    for key, expected in expected_layout.items():
        expected_type = list if isinstance(expected, list) else str
        actual = require(layout, key, expected_type,
                         "manifest.fidelity.bdf_layout")
        if actual != expected:
            fail(f"manifest.fidelity.bdf_layout.{key} 与当前 Q35 启动器不一致")
        values = actual if isinstance(actual, list) else [actual]
        if any(not re.fullmatch(r"[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]", value)
               for value in values):
            fail(f"manifest.fidelity.bdf_layout.{key} 不是规范 BDF")


def validate_platform(platform: dict, seen_ids: set[str]) -> None:
    """校验会影响整机一致性的硬约束，拒绝不完整或跨层矛盾的 bundle。"""
    platform_id = require(platform, "id", str, "platform")
    where = f"platform[{platform_id}]"
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{7,95}", platform_id):
        fail(f"{where}.id 格式错误")
    if platform_id in seen_ids:
        fail(f"平台 id 重复：{platform_id}")
    seen_ids.add(platform_id)

    enabled = require(platform, "enabled", bool, where)
    status = require(platform, "status", str, where)
    if status not in ("supported", "compatibility"):
        fail(f"{where}.status 不在受控状态集合")
    if enabled and status != "supported":
        fail(f"{where} 已启用但 status 不是 supported")
    release_year = require(platform, "release_year", int, where)
    if not 2005 <= release_year <= datetime.date.today().year:
        fail(f"{where}.release_year 超出合理范围")

    cpu = require(platform, "cpu", dict, where)
    board = require(platform, "board", dict, where)
    memory = require(platform, "memory", dict, where)
    devices = require(platform, "devices", dict, where)
    bios = require(platform, "bios", dict, where)
    system = require(platform, "system", dict, where)

    for key in ("qemu_arg", "vendor_id", "name", "part", "socket", "features"):
        if not require(cpu, key, str, f"{where}.cpu"):
            fail(f"{where}.cpu.{key} 不能为空")
    if cpu["vendor_id"] not in ("AuthenticAMD", "GenuineIntel"):
        fail(f"{where}.cpu.vendor_id 不支持")
    for key in ("max_mhz", "current_mhz", "tsc_mhz", "cores", "threads", "phys_bits"):
        if require(cpu, key, int, f"{where}.cpu") <= 0:
            fail(f"{where}.cpu.{key} 必须为正整数")
    if cpu["current_mhz"] > cpu["max_mhz"]:
        fail(f"{where} CPU 当前频率超过最大频率")
    if cpu["threads"] < cpu["cores"] or cpu["threads"] % cpu["cores"] != 0:
        fail(f"{where} CPU 核数/线程数不可能")
    # QEMU/KVM 的 X86CPU phys-bits 属性当前上限是 52；清单若放行 53..57，
    # 会出现“manifest 校验成功、运行时必然失败”的分层矛盾。
    if not 32 <= cpu["phys_bits"] <= 52:
        fail(f"{where}.cpu.phys_bits 超出 QEMU/KVM [32,52] 范围")
    if cpu["vendor_id"] == "GenuineIntel" and "+topoext" in cpu["features"]:
        fail(f"{where} Intel CPU 不得启用 AMD topoext")
    if cpu["vendor_id"] == "AuthenticAMD" and "+topoext" not in cpu["features"]:
        fail(f"{where} AMD Zen 平台缺少 topoext")

    igpu = require(cpu, "integrated_gpu", dict, f"{where}.cpu")
    require(igpu, "present", bool, f"{where}.cpu.integrated_gpu")
    state = require(igpu, "profile_state", str, f"{where}.cpu.integrated_gpu")
    require(igpu, "model", str, f"{where}.cpu.integrated_gpu")
    if state not in ("absent", "fused_off", "disabled_in_bios"):
        fail(f"{where} 核显状态不受支持")
    if igpu["present"] != (state == "disabled_in_bios"):
        fail(f"{where} 核显 present 与 profile_state 矛盾")

    smbios = require(cpu, "smbios", dict, f"{where}.cpu")
    for key in ("family", "upgrade", "characteristics"):
        require_hex(require(smbios, key, str, f"{where}.cpu.smbios"),
                    f"{where}.cpu.smbios.{key}", (2, 4))
    for key in ("voltage_mv", "external_clock_mhz"):
        if require(smbios, key, int, f"{where}.cpu.smbios") <= 0:
            fail(f"{where}.cpu.smbios.{key} 必须为正整数")

    for key in ("manufacturer", "product", "family", "version", "serial_fn",
                "subsystem_vendor", "subsystem_device", "pch"):
        if not require(board, key, str, f"{where}.board"):
            fail(f"{where}.board.{key} 不能为空")
    require_hex(board["subsystem_vendor"], f"{where}.board.subsystem_vendor")
    require_hex(board["subsystem_device"], f"{where}.board.subsystem_device")
    if not re.fullmatch(r"_serial_(asus|msi|giga|asr)", board["serial_fn"]):
        fail(f"{where}.board.serial_fn 不在序列号生成器白名单")
    for key in ("pcie_generation", "dimm_slots", "max_memory_gib"):
        if require(board, key, int, f"{where}.board") <= 0:
            fail(f"{where}.board.{key} 必须为正整数")

    if require(memory, "type", str, f"{where}.memory") not in ("DDR3", "DDR4"):
        fail(f"{where}.memory.type 不支持")
    channels = require(memory, "channels", int, f"{where}.memory")
    max_mts = require(memory, "max_mts", int, f"{where}.memory")
    allowed_mts = require(memory, "allowed_mts", list, f"{where}.memory")
    if channels not in (1, 2, 4) or not allowed_mts:
        fail(f"{where} 内存通道/速率列表无效")
    if any(isinstance(rate, bool) or not isinstance(rate, int) or rate <= 0
           or rate > max_mts for rate in allowed_mts):
        fail(f"{where} 内存允许速率超过平台上限或类型错误")
    if board["dimm_slots"] < channels:
        fail(f"{where} DIMM 槽数少于内存通道数")
    voltage_mv = require(memory, "voltage_mv", int, f"{where}.memory")
    rank = require(memory, "rank", int, f"{where}.memory")
    module_mib = require(memory, "module_mib", list, f"{where}.memory")
    allowed_total_mib = require(memory, "allowed_total_mib", list, f"{where}.memory")
    if voltage_mv not in (1200, 1500) or rank not in (1, 2):
        fail(f"{where} 内存电压或 rank 不支持")
    if not module_mib or any(isinstance(size, bool) or not isinstance(size, int) or size <= 0
                             for size in module_mib):
        fail(f"{where}.memory.module_mib 无效")
    if not allowed_total_mib or any(isinstance(size, bool) or not isinstance(size, int) or size <= 0
                                    for size in allowed_total_mib):
        fail(f"{where}.memory.allowed_total_mib 无效")
    possible_totals = {size * count for size in module_mib
                       for count in range(1, board["dimm_slots"] + 1)}
    if any(total not in possible_totals for total in allowed_total_mib):
        fail(f"{where} 允许总容量无法由 DIMM 物料和槽位组成")
    if max(allowed_total_mib) > board["max_memory_gib"] * 1024:
        fail(f"{where} 允许总容量超过主板上限")

    chipset = require(devices, "chipset", dict, f"{where}.devices")
    for component_name in ("mch", "lpc", "smbus", "ahci"):
        component = require(chipset, component_name, list, f"{where}.devices.chipset")
        if len(component) != 3:
            fail(f"{where}.devices.chipset.{component_name} 必须是 vendor/device/revision 三元组")
        for index, value in enumerate(component):
            if not isinstance(value, str):
                fail(f"{where}.devices.chipset.{component_name}[{index}] 不是字符串")
            require_hex(value, f"{where}.devices.chipset.{component_name}[{index}]", (2, 4))

    for device_name in ("root_port", "xhci"):
        device = require(devices, device_name, dict, f"{where}.devices")
        for key in ("pci_vendor", "pci_device", "revision"):
            value = require(device, key, str, f"{where}.devices.{device_name}")
            require_hex(value, f"{where}.devices.{device_name}.{key}", (2, 4))
    nvme = require(devices, "nvme", dict, f"{where}.devices")
    if require(nvme, "max_pcie_generation", int, f"{where}.devices.nvme") > board["pcie_generation"]:
        fail(f"{where} NVMe PCIe 代际超过主板")
    if require(nvme, "lanes", int, f"{where}.devices.nvme") not in (1, 2, 4):
        fail(f"{where} NVMe lane 数无效")
    require(nvme, "boot_supported", bool, f"{where}.devices.nvme")
    if require(nvme, "attachment", str, f"{where}.devices.nvme") != "m2_socket":
        fail(f"{where} 当前只允许可核验的主板 M.2 socket")

    for device_name in ("nic", "audio"):
        device = require(devices, device_name, dict, f"{where}.devices")
        for key, value in device.items():
            if key.startswith("pci_") or key.startswith("controller_pci_"):
                require_hex(value, f"{where}.devices.{device_name}.{key}")
            elif not isinstance(value, str) or not value:
                fail(f"{where}.devices.{device_name}.{key} 不能为空")
    nic = devices["nic"]
    for key in ("subsystem_vendor", "subsystem_device"):
        require_hex(require(nic, key, str, f"{where}.devices.nic"),
                    f"{where}.devices.nic.{key}")
    if not re.fullmatch(r"[0-9a-f]{2}(?::[0-9a-f]{2}){2}",
                        require(nic, "mac_oui", str, f"{where}.devices.nic")):
        fail(f"{where}.devices.nic.mac_oui 必须是小写三字节 OUI")
    if nic.get("attachment") != "add_in" or nic.get("board_nic_state") != "disabled_in_bios":
        fail(f"{where} 当前仅允许禁用板载网卡并使用受支持的 add-in NIC")
    if (nic.get("pci_vendor"), nic.get("pci_device"), nic.get("subsystem_vendor"),
            nic.get("subsystem_device"), nic.get("mac_oui")) != (
                "0x8086", "0x10D3", "0x8086", "0xA01F", "3c:fd:fe"):
        fail(f"{where} 当前 NIC 行为模型只能声明 Intel 82574L")
    audio = devices["audio"]
    for key in ("codec_id", "codec_revision", "codec_subsystem_id"):
        require_hex(require(audio, key, str, f"{where}.devices.audio"),
                    f"{where}.devices.audio.{key}", (8,))
    if (audio.get("codec"), audio.get("codec_id"), audio.get("codec_revision"),
            audio.get("codec_subsystem_id")) != (
                "ALC887", "0x10ec0887", "0x00100302", "0x104386c7"):
        fail(f"{where} ALC887 协议身份字段不是已审计组合")
    if audio.get("identity_fidelity") != "protocol_identity_only":
        fail(f"{where} 必须明示 ALC887 只实现协议身份，不得声称完整拓扑")

    for key in ("vendor", "version", "date"):
        if not require(bios, key, str, f"{where}.bios"):
            fail(f"{where}.bios.{key} 不能为空")
    try:
        datetime.datetime.strptime(bios["date"], "%m/%d/%Y")
    except ValueError as exc:
        fail(f"{where}.bios.date 必须为 MM/DD/YYYY：{exc}")
    for key in ("product", "family"):
        if not require(system, key, str, f"{where}.system"):
            fail(f"{where}.system.{key} 不能为空")
    # 新建平台统一采用 DMTF Desktop(0x03)。它是整机身份的一部分，
    # 不能再由 Linux/Windows 启动器各自随机或使用不同默认值。
    chassis_type = require(system, "chassis_type", str, f"{where}.system")
    require_hex(chassis_type, f"{where}.system.chassis_type", (2,))
    if chassis_type != "0x03":
        fail(f"{where}.system.chassis_type 当前只支持 DMTF Desktop 0x03")
    refs = require(platform, "source_refs", list, where)
    if len(refs) < 2 or any(not isinstance(ref, str) or not ref.startswith("https://") for ref in refs):
        fail(f"{where}.source_refs 至少需要两个 HTTPS 官方来源")


def export_pairs(root: dict, platform: dict) -> dict[str, str]:
    """将嵌套 JSON 映射成现有启动器和新设备层共同使用的环境变量。"""
    cpu = platform["cpu"]
    board = platform["board"]
    memory = platform["memory"]
    devices = platform["devices"]
    smbios = cpu["smbios"]
    igpu = cpu["integrated_gpu"]
    bios = platform["bios"]
    system = platform["system"]
    root_port = devices["root_port"]
    xhci = devices["xhci"]
    nvme = devices["nvme"]
    nic = devices["nic"]
    audio = devices["audio"]
    chipset = devices["chipset"]

    return {
        "PLATFORM_SCHEMA_VERSION": root["schema_version"],
        "PLATFORM_CATALOG_REVISION": root["catalog_revision"],
        "PLATFORM_ID": platform["id"],
        "PLATFORM_STATUS": platform["status"],
        "PLATFORM_RELEASE_YEAR": platform["release_year"],
        "PLATFORM_DEFAULT_VCPUS": root["defaults"]["vcpus"],
        "PLATFORM_DEFAULT_MEMORY_MIB": root["defaults"]["memory_total_mib"],
        "CPU_QEMU_ARG": cpu["qemu_arg"],
        "CPU_VENDOR": cpu["vendor_id"],
        "CPU_NAME": cpu["name"],
        "CPU_MAX_MHZ": cpu["max_mhz"],
        "CPU_CUR_MHZ": cpu["current_mhz"],
        "CPU_TSC_MHZ": cpu["tsc_mhz"],
        "CPU_PART": cpu["part"],
        "CPU_PROC_FAMILY": smbios["family"],
        "CPU_SOCKET": cpu["socket"],
        "CPU_MODEL": cpu["qemu_arg"].split(",", 1)[0],
        "CPU_CORES": cpu["cores"],
        "CPU_THREADS": cpu["threads"],
        "CPU_PHYS_BITS": cpu["phys_bits"],
        "CPU_FEATURES": cpu["features"],
        "CPU_SMBIOS_UPGRADE": smbios["upgrade"],
        "CPU_SMBIOS_VOLTAGE": smbios["voltage_mv"],
        "CPU_SMBIOS_EXT_CLOCK": smbios["external_clock_mhz"],
        "CPU_SMBIOS_CHARACTERISTICS": smbios["characteristics"],
        "CPU_IGPU_PRESENT": int(igpu["present"]),
        "CPU_IGPU_STATE": igpu["profile_state"],
        "CPU_IGPU_MODEL": igpu["model"],
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
        "MEM_ALLOWED_MTS": ",".join(str(rate) for rate in memory["allowed_mts"]),
        "MEM_VOLTAGE_MV": memory["voltage_mv"],
        "MEM_RANK": memory["rank"],
        "MEM_MODULE_MB": ",".join(str(size) for size in memory["module_mib"]),
        "MEM_ALLOWED_TOTAL_MB": ",".join(str(size) for size in memory["allowed_total_mib"]),
        "MEM_MAX_CAPACITY_MB": board["max_memory_gib"] * 1024,
        "MCH_PCI_VEN": chipset["mch"][0],
        "MCH_PCI_DEV": chipset["mch"][1],
        "MCH_REV": chipset["mch"][2],
        "LPC_PCI_VEN": chipset["lpc"][0],
        "LPC_PCI_DEV": chipset["lpc"][1],
        "LPC_REV": chipset["lpc"][2],
        "SMBUS_PCI_VEN": chipset["smbus"][0],
        "SMBUS_PCI_DEV": chipset["smbus"][1],
        "SMBUS_REV": chipset["smbus"][2],
        "AHCI_PCI_VEN": chipset["ahci"][0],
        "AHCI_PCI_DEV": chipset["ahci"][1],
        "AHCI_REV": chipset["ahci"][2],
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
        "BIOS_VENDOR": bios["vendor"],
        "BIOS_VERSION": bios["version"],
        "BIOS_DATE": bios["date"],
        "SYSTEM_PRODUCT": system["product"],
        "SYSTEM_FAMILY": system["family"],
        "SYSTEM_CHASSIS_TYPE": system["chassis_type"],
    }


manifest_path = pathlib.Path(sys.argv[1])
action = sys.argv[2]
wanted_id = sys.argv[3]
strict_hardware = sys.argv[4]
allow_compatibility = sys.argv[5]

try:
    with manifest_path.open("r", encoding="utf-8") as stream:
        root = json.load(stream)
    if not isinstance(root, dict):
        fail("清单根节点必须是对象")
    if require(root, "schema_version", int, "manifest") != 1:
        fail("不支持的 schema_version")
    if not require(root, "catalog_revision", str, "manifest"):
        fail("catalog_revision 不能为空")
    defaults = require(root, "defaults", dict, "manifest")
    if require(defaults, "vcpus", int, "manifest.defaults") <= 0:
        fail("manifest.defaults.vcpus 必须为正整数")
    if require(defaults, "memory_total_mib", int, "manifest.defaults") <= 0:
        fail("manifest.defaults.memory_total_mib 必须为正整数")
    validate_fidelity(root)
    platforms = require(root, "platforms", list, "manifest")
    if not platforms:
        fail("platforms 不能为空")
    seen: set[str] = set()
    for item in platforms:
        if not isinstance(item, dict):
            fail("platforms 条目必须是对象")
        validate_platform(item, seen)

    if action == "validate":
        print(f"OK: platform manifest schema=1 platforms={len(platforms)}")
    elif action == "index":
        for item in platforms:
            cpu = item["cpu"]
            print("|".join((item["id"], str(item["enabled"]).lower(), cpu["vendor_id"],
                            str(cpu["max_mhz"]), str(cpu["threads"]), str(cpu["tsc_mhz"]))))
    elif action == "status":
        # profile 是用户可编辑输入，授权判断不能信任其中自报的 PLATFORM_STATUS。
        # 这里只返回已经完整校验过的 manifest 真值，并且不触发 compatibility 放行。
        selected = next((item for item in platforms if item["id"] == wanted_id), None)
        if selected is None:
            fail(f"平台不存在：{wanted_id}")
        print(selected["status"])
    elif action in ("legacy_cpu", "legacy_board"):
        rows: list[str] = []
        seen_rows: set[str] = set()
        for item in platforms:
            if not item["enabled"]:
                continue
            cpu = item["cpu"]
            board = item["board"]
            smbios = cpu["smbios"]
            if action == "legacy_cpu":
                row = "|".join((cpu["qemu_arg"], cpu["vendor_id"], cpu["name"],
                                str(cpu["max_mhz"]), str(cpu["current_mhz"]), cpu["part"],
                                smbios["family"], cpu["socket"]))
            else:
                row = "|".join((cpu["socket"], board["manufacturer"], board["product"],
                                board["family"], board["version"], board["serial_fn"],
                                board["subsystem_vendor"], board["subsystem_device"]))
            if row not in seen_rows:
                rows.append(row)
                seen_rows.add(row)
        print("\n".join(rows))
    elif action == "export":
        selected = next((item for item in platforms if item["id"] == wanted_id), None)
        if selected is None:
            fail(f"平台不存在：{wanted_id}")
        if not selected["enabled"]:
            explicitly_allowed = allow_compatibility == "1"
            legacy_non_strict = strict_hardware == "0"
            if (selected["status"] != "compatibility" or
                    not (explicitly_allowed or legacy_non_strict)):
                fail(f"平台已禁用：{wanted_id}；如确认接受 Q35 行为边界，需显式允许 compatibility")
            print(f"WARN: 显式加载 Q35/ICH9 compatibility 平台，不能宣称真实目标主板行为：{wanted_id}",
                  file=sys.stderr)
        for key, value in export_pairs(root, selected).items():
            encoded = base64.b64encode(str(value).encode("utf-8")).decode("ascii")
            print(f"{key}\t{encoded}")
    else:
        fail(f"未知清单动作：{action}")
except (OSError, json.JSONDecodeError, ValueError) as exc:
    print(f"ERROR: 无法使用平台清单 {manifest_path}: {exc}", file=sys.stderr)
    sys.exit(1)
PY
}

stealth_platform_validate() {
    _stealth_platform_python validate
}

stealth_platform_index() {
    _stealth_platform_python index
}

# 返回指定平台在已校验 manifest 中的真实状态。该只读查询不执行平台加载，也不受
# STRICT_HARDWARE 影响，专供 profile 加载器在授权前识别伪改状态。
stealth_platform_manifest_status() {
    local platform_id="$1"
    _stealth_platform_python status "$platform_id"
}

stealth_platform_legacy_cpu_rows() {
    _stealth_platform_python legacy_cpu
}

stealth_platform_legacy_board_rows() {
    _stealth_platform_python legacy_board
}

stealth_platform_load() {
    local platform_id="$1"
    local output key encoded value

    if ! output="$(_stealth_platform_python export "$platform_id")"; then
        return 1
    fi
    while IFS=$'\t' read -r key encoded; do
        [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || {
            echo "ERROR: 平台导出包含非法变量名: $key" >&2
            return 1
        }
        if ! value="$(printf '%s' "$encoded" | base64 --decode 2>/dev/null)"; then
            echo "ERROR: 平台字段 $key 的编码损坏" >&2
            return 1
        fi
        printf -v "$key" '%s' "$value"
        # `${key?}` 仍按变量内容导出动态字段名，同时明确 key 必须已赋值，
        # 避免静态检查器把它误判成试图导出名为 `$key` 的变量。
        export "${key?}"
    done <<<"$output"
}
