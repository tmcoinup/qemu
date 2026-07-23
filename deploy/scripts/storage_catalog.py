#!/usr/bin/env python3
"""校验并投影只含精确 512GB 容量的 NVMe 身份目录。"""

from __future__ import annotations

import json
import pathlib
import re
import sys
from typing import Any


HEX16 = re.compile(r"^0x[0-9A-Fa-f]{4}$")
ID_PATTERN = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*")
ENTRY_FIELDS = {
    "id", "enabled", "selection_weight", "release_year", "manufacturer",
    "part_number", "identity_profile", "model", "firmware", "raw_bytes",
    "verification_status", "identity_fidelity", "serial_policy", "pci",
    "nvme", "source_refs", "identity_source_refs",
}
SERIAL_FIELDS = {"kind", "pattern", "length", "format_fidelity"}
PCI_FIELDS = {"vendor", "device", "subsystem_vendor", "subsystem_device"}
NVME_FIELDS = {
    "pcie_generation", "lanes", "ieee_oui", "subnqn_template",
    "nqn_fidelity",
}
RAW_512GB_BYTES = 512110190592

# 每个元组都是同一实机型号的原子身份组合，不能跨型号拼接固件、PCI ID、
# OUI 或序列号外形。序列规则只描述公开实机样本，不冒充厂商分配算法。
AUDITED_FACTS = {
    "samsung-970-pro-512gb": (
        6, 2018, "Samsung", "MZ-V7P512BW",
        "Samsung SSD 970 PRO 512GB", "1B2QEXP7",
        ("0x144D", "0xA808", "0x144D", "0xA801"), "00:25:38",
        "samsung-970-pro", r"^S[A-Z0-9]{3}N[A-Z0-9]{10}$", 15,
        "observed_multi_sample_shape_synthetic_value",
    ),
    "intel-760p-512gb": (
        5, 2018, "Intel", "SSDPEKKW512G8", "INTEL SSDPEKKW512G8",
        "001C", ("0x8086", "0xF1A6", "0x8086", "0x390B"), "5C:D2:E4",
        "intel-760p", r"^BTHH[A-Z0-9]{8}512D$", 16,
        "observed_multi_sample_shape_synthetic_value",
    ),
    "wd-pc-sn730-512gb": (
        6, 2019, "Western Digital", "SDBPNTY-512G-1027",
        "WDC PC SN730 SDBPNTY-512G-1027", "11110000",
        ("0x15B7", "0x5006", "0x15B7", "0x5006"), "00:1B:44",
        "wd-pc-sn730", r"^[A-Z0-9]{12}$", 12,
        "observed_vendor_variable_ascii_shape_synthetic_value",
    ),
    "kioxia-xg6-512gb": (
        4, 2018, "KIOXIA", "KXG60ZNV512G", "KXG60ZNV512G KIOXIA",
        "AGHA4101", ("0x1179", "0x011A", "0x1179", "0x0001"), "8C:E3:8E",
        "kioxia-xg6", r"^[A-Z0-9]{12}$", 12,
        "observed_multi_sample_shape_synthetic_value",
    ),
}
SERIAL_SAMPLES = {
    "samsung-970-pro-512gb": "S4EVN1234567890",
    "intel-760p-512gb": "BTHH1234ABCD512D",
    "wd-pc-sn730-512gb": "1839A8012345",
    "kioxia-xg6-512gb": "69UPA0ABC123",
}
SOURCE_HOSTS = {
    "samsung-970-pro-512gb": {"www.samsung.com", "semiconductor.samsung.com"},
    "intel-760p-512gb": {"www.intel.com", "cdrdv2-public.intel.com"},
    "wd-pc-sn730-512gb": {"documents.westerndigital.com"},
    "kioxia-xg6-512gb": {"www.kioxia.com", "europe.kioxia.com"},
}
IDENTITY_HOSTS = {
    "samsung-970-pro-512gb": {"bbs.archlinux.org", "raw.githubusercontent.com"},
    "intel-760p-512gb": {"gist.github.com", "bugs.debian.org"},
    "wd-pc-sn730-512gb": {
        "forum.manjaro.org", "bbs.archlinux.org", "lists.debian.org",
    },
    "kioxia-xg6-512gb": {
        "bugs.debian.org", "mis.sapuraindustrial.com.my", "www.reddit.com",
    },
}


def fail(message: str) -> None:
    """输出与 shell 启动链一致的 fail-closed 错误。"""
    print(f"ERROR: storage catalog: {message}", file=sys.stderr)
    raise SystemExit(1)


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    """JSON 重复键会掩盖身份字段，因此在解析阶段直接拒绝。"""
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            fail(f"JSON 含重复字段 {key}")
        result[key] = value
    return result


def load_json(path: pathlib.Path, label: str) -> dict[str, Any]:
    """读取 UTF-8 JSON 对象并拒绝重复字段。"""
    try:
        root = json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=reject_duplicate_keys,
        )
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"无法读取 {label} {path}: {exc}")
    if not isinstance(root, dict):
        fail(f"{label} 根节点不是对象")
    return root


def validate_urls(value: Any, label: str, allowed_hosts: set[str]) -> None:
    """规格与身份均至少需要两个受控域名上的互不重复 HTTPS 页面。"""
    if (not isinstance(value, list) or len(value) < 2 or
            len(value) != len(set(value))):
        fail(f"{label} 至少需要两个互不重复的来源")
    for url in value:
        match = re.fullmatch(r"https://([^/\s]+)/\S+", url) \
            if isinstance(url, str) else None
        if match is None or match.group(1).lower() not in allowed_hosts:
            fail(f"{label} 含非法或非受控域名的 HTTPS 来源")


def validate_storage(root: dict[str, Any]) -> list[dict[str, Any]]:
    """返回已启用并完整通过原子事实校验的四款 512GB SSD。"""
    if (set(root) != {"schema_version", "catalog_revision", "scope", "storage"} or
            root.get("schema_version") != 1 or
            root.get("scope") != "verified_exact_512gb_nvme_only" or
            not isinstance(root.get("catalog_revision"), str) or
            not root["catalog_revision"]):
        fail("根字段、schema、revision 或 only-512GB scope 无效")
    raw_items = root.get("storage")
    if not isinstance(raw_items, list) or len(raw_items) != len(AUDITED_FACTS):
        fail("SSD 集合必须恰好是四款已核验 512GB NVMe")
    seen_ids: set[str] = set()
    seen_pci: set[tuple[str, str, str, str]] = set()
    enabled: list[dict[str, Any]] = []
    for item in raw_items:
        if not isinstance(item, dict) or set(item) != ENTRY_FIELDS:
            fail("SSD 条目字段集合不完整或包含未知字段")
        stable_id = item.get("id")
        if (not isinstance(stable_id, str) or
                not ID_PATTERN.fullmatch(stable_id) or
                stable_id in seen_ids or stable_id not in AUDITED_FACTS):
            fail("SSD 稳定 ID 为空、重复、非法或未核验")
        expected = AUDITED_FACTS[stable_id]
        actual = tuple(item.get(key) for key in (
            "selection_weight", "release_year", "manufacturer", "part_number",
            "model", "firmware"))
        if actual != expected[:6] or item.get("raw_bytes") != RAW_512GB_BYTES:
            fail(f"{stable_id} 的型号、固件、权重或精确容量被改写")
        if item.get("enabled") is not True or item.get("identity_profile") != stable_id:
            fail(f"{stable_id} 必须启用且画像 ID 必须与稳定 ID 相同")
        if (item.get("verification_status") !=
                "vendor_document_and_observed_identity_reference" or
                item.get("identity_fidelity") !=
                "audited_register_bundle_synthetic_serial"):
            fail(f"{stable_id} 的证据边界无效")
        pci = item.get("pci")
        if not isinstance(pci, dict) or set(pci) != PCI_FIELDS:
            fail(f"{stable_id}.pci 字段集合无效")
        pci_tuple = tuple(pci[key] for key in (
            "vendor", "device", "subsystem_vendor", "subsystem_device"))
        if (pci_tuple != expected[6] or pci_tuple in seen_pci or
                any(not isinstance(value, str) or not HEX16.fullmatch(value)
                    for value in pci_tuple)):
            fail(f"{stable_id} 的 PCI 主/子系统身份非法、重复或不匹配")
        nvme = item.get("nvme")
        if not isinstance(nvme, dict) or set(nvme) != NVME_FIELDS:
            fail(f"{stable_id}.nvme 字段集合无效")
        if tuple(nvme.get(key) for key in (
                "pcie_generation", "lanes", "ieee_oui")) != (3, 4, expected[7]):
            fail(f"{stable_id} 的 NVMe 链路或 OUI 不匹配")
        if (nvme.get("subnqn_template"), nvme.get("nqn_fidelity")) != (
                "nqn.2014-08.org.nvmexpress:uuid:{uuid}",
                "standards_compliant_synthetic_uuid"):
            fail(f"{stable_id} 的 subnqn 模板或合成边界错误")
        policy = item.get("serial_policy")
        if not isinstance(policy, dict) or set(policy) != SERIAL_FIELDS:
            fail(f"{stable_id}.serial_policy 字段集合无效")
        if tuple(policy.get(key) for key in (
                "kind", "pattern", "length", "format_fidelity")) != expected[8:]:
            fail(f"{stable_id} 的序列号样本规则与该型号不匹配")
        sample = SERIAL_SAMPLES[stable_id]
        if len(sample) != policy["length"] or not re.fullmatch(policy["pattern"], sample):
            fail(f"{stable_id} 的受控样本不能通过自身序列规则")
        validate_urls(
            item["source_refs"], f"{stable_id}.source_refs",
            SOURCE_HOSTS[stable_id],
        )
        validate_urls(
            item["identity_source_refs"], f"{stable_id}.identity_source_refs",
            IDENTITY_HOSTS[stable_id],
        )
        seen_ids.add(stable_id)
        seen_pci.add(pci_tuple)
        enabled.append(item)
    return enabled


def print_row(item: dict[str, Any]) -> None:
    """输出兼容旧调用方的 16 列稳定 ABI。"""
    pci = item["pci"]
    nvme = item["nvme"]
    policy = item["serial_policy"]
    values = (
        item["id"], item["model"], item["firmware"], item["raw_bytes"],
        pci["vendor"], pci["device"], pci["subsystem_vendor"],
        pci["subsystem_device"], nvme["subnqn_template"], item["manufacturer"],
        item["part_number"], item["identity_profile"], policy["kind"],
        policy["pattern"], policy["length"], item["selection_weight"],
    )
    print("|".join(str(value) for value in values))


def main() -> None:
    """加载目录并执行 shell/PowerShell 可复用的只读投影操作。"""
    if len(sys.argv) < 4:
        fail("参数不足")
    components_path = pathlib.Path(sys.argv[1])
    storage_path = pathlib.Path(sys.argv[2])
    operation = sys.argv[3]
    components = load_json(components_path, "component manifest")
    if components.get("storage_catalog") != storage_path.name:
        fail("components.json 未精确引用所加载的存储目录")
    root = load_json(storage_path, "storage manifest")
    items = validate_storage(root)
    by_id = {item["id"]: item for item in items}
    if operation == "validate":
        print(root["catalog_revision"])
    elif operation == "rows":
        for item in items:
            print_row(item)
    elif operation == "weights":
        for item in items:
            print(f"{item['id']}|{item['selection_weight']}")
    elif operation in {"id", "serial-spec", "serial-valid"}:
        wanted = sys.argv[4] if len(sys.argv) >= 5 else ""
        if wanted not in by_id:
            fail("未知或缺失的 SSD 稳定 ID")
        item = by_id[wanted]
        policy = item["serial_policy"]
        if operation == "id":
            print_row(item)
        elif operation == "serial-spec":
            print("|".join(str(policy[key]) for key in ("kind", "pattern", "length")))
        else:
            serial = sys.argv[5] if len(sys.argv) == 6 else ""
            if len(serial) != policy["length"] or not re.fullmatch(
                    policy["pattern"], serial):
                fail(f"{wanted} 序列号不符合品牌样本格式")
            if policy["kind"] == "samsung-970-pro":
                # index 4 的 N 是型号格式固定标记；只抽取两侧可变负载。
                payload = serial[1:4] + serial[5:]
            elif policy["kind"] == "intel-760p":
                payload = serial[4:12]
            else:
                payload = serial
            if len(set(payload)) == 1 and payload[0] in "0FN":
                fail(f"{wanted} 序列号使用了全 0/全 F/全 N 占位值")
    else:
        fail(f"未知操作: {operation}")


if __name__ == "__main__":
    main()
