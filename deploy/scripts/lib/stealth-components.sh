# shellcheck shell=bash
# 版本化可更换部件目录的只读加载器。整机平台仍由 platforms.json 决定；本文件只
# 导出 SSD、显示器和 HID 这类可更换件，并在进入随机池前校验深层身份字段。

_STEALTH_COMPONENT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_STEALTH_COMPONENT_REPO_ROOT="$(cd "$_STEALTH_COMPONENT_LIB_DIR/../../.." && pwd)"
: "${STEALTH_COMPONENT_MANIFEST:=$_STEALTH_COMPONENT_REPO_ROOT/deploy/hardware/components.json}"

_stealth_component_python() {
    local operation="$1"
    python3 - "$STEALTH_COMPONENT_MANIFEST" "$operation" <<'PY'
import json
import pathlib
import re
import sys


path = pathlib.Path(sys.argv[1])
operation = sys.argv[2]
hex16 = re.compile(r"^0x[0-9A-Fa-f]{4}$")


def fail(message):
    print(f"ERROR: component manifest: {message}", file=sys.stderr)
    raise SystemExit(1)


def require_source_refs(item, where, minimum):
    """来源必须是厂商官方 HTTPS 文档，目录自身不能把搜索结果当证据。"""
    refs = item.get("source_refs")
    if not isinstance(refs, list) or len(refs) < minimum:
        fail(f"{where}.source_refs 至少需要 {minimum} 个来源")
    if len(refs) != len(set(refs)):
        fail(f"{where}.source_refs 含重复来源")
    for ref in refs:
        if not isinstance(ref, str) or not re.fullmatch(
                r"https://(?:download\.semiconductor\.samsung\.com|"
                r"images\.samsung\.com|www\.samsung\.com)/\S+", ref):
            fail(f"{where}.source_refs 必须使用 Samsung 官方 HTTPS 文档")


try:
    root = json.loads(path.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError) as exc:
    fail(f"无法读取 {path}: {exc}")

if root.get("schema_version") != 1:
    fail("只支持 schema_version=1")
if not isinstance(root.get("catalog_revision"), str) or not root["catalog_revision"]:
    fail("catalog_revision 缺失")
if root.get("scope", {}).get("gpu") != "out_of_scope_virtual_display":
    fail("GPU 必须明确标记为本分支范围外的虚拟显示")
if root.get("scope", {}).get("tablet") != "generic_virtual_absolute_pointer":
    fail("tablet 必须明确标记为通用虚拟绝对指针")

storages = [item for item in root.get("storage", []) if item.get("enabled") is True]
if len(storages) != 1:
    fail("严格目录必须且只能启用一个已核验 SSD")
storage = storages[0]
if tuple(storage.get(key) for key in (
        "id", "release_year", "model", "firmware", "raw_bytes",
        "verification_status", "identity_fidelity")) != (
    "samsung-970-pro-512gb", 2018, "Samsung SSD 970 PRO 512GB",
    "1B2QEXP7", 512110190592, "vendor_document_reference",
    "model_register_reference_no_device_capture"
):
    fail("SSD 型号、年代、容量或证据边界不是受控的 970 PRO 512GB bundle")
require_source_refs(storage, "storage[samsung-970-pro-512gb]", 2)
pci = storage.get("pci", {})
if tuple(pci.get(key) for key in
         ("vendor", "device", "subsystem_vendor", "subsystem_device")) != (
             "0x144D", "0xA804", "0x144D", "0xA801"):
    fail("970 PRO PCI identity 必须为 144d:a804 / 144d:a801")
nvme = storage.get("nvme", {})
if (nvme.get("pcie_generation"), nvme.get("lanes"), nvme.get("ieee_oui")) != (
    3, 4, "00:25:38"
):
    fail("970 PRO NVMe 总线/OUI 字段错误")
template = nvme.get("subnqn_template", "")
if (template, nvme.get("nqn_fidelity")) != (
        "nqn.2014-08.org.nvmexpress:uuid:{uuid}",
        "standards_compliant_synthetic_uuid"):
    fail("subnqn 必须使用 NVMe 标准 UUID 格式并标明合成边界")
sample_nqn = template.replace(
    "{uuid}", "01234567-89ab-4cde-8f01-23456789abcd")
if (not sample_nqn.isascii() or len(sample_nqn.encode("utf-8")) > 223 or
        "{" in sample_nqn or "}" in sample_nqn):
    fail("subnqn 展开后必须是至多 223 字节的完整 ASCII NQN")

monitors = [item for item in root.get("monitors", []) if item.get("enabled") is True]
if len(monitors) != 1:
    fail("当前 EDID 生成器只能启用一个深层核验显示器")
monitor = monitors[0]
if tuple(monitor.get(key) for key in (
        "id", "release_year", "vendor_code", "product_id", "name",
        "serial_prefix", "width_mm", "height_mm", "manufacture_week",
        "manufacture_year", "video_input", "evidence",
        "identity_fidelity")) != (
        "samsung-s24f350", 2016, "SAM", "0x0F65", "S24F350", "H4ZK",
        521, 293, 32, 2018, "0xA3", "official_model_specs_no_raw_edid",
        "synthetic_edid_identity_fields"):
    fail("S24F350 型号规格或合成 EDID 证据边界被改写")
if len(monitor["serial_prefix"]) + 8 > 12:
    fail("显示器序列号会超过当前 EDID 文本描述符的 12 字符上限")
require_source_refs(monitor, "monitor[samsung-s24f350]", 2)
ranges = monitor.get("range", {})
if tuple(ranges.get(key) for key in (
        "min_vfreq_hz", "max_vfreq_hz", "min_hfreq_khz",
        "max_hfreq_khz", "max_pixel_clock_mhz")) != (56, 75, 30, 81, 149):
    fail("S24F350 扫描范围与官方型号规格不一致")
timing = monitor.get("secondary_timing", {})
if tuple(timing.get(key) for key in (
        "xres", "yres", "refresh_millihz")) != (1600, 900, 60000):
    fail("S24F350 次要时序不是受控模板")

hid = root.get("hid", {})
for kind, expected in (
    ("keyboards", (
        "microsoft-wired-keyboard-600", "0x045E", "0x0750", "0x0163",
        "Microsoft", "Microsoft Wired Keyboard 600",
        "unverified_catalog_identity", "identity_only_generic_report")),
    ("mice", (
        "microsoft-usb-optical-mouse", "0x045E", "0x00CB", "0x0163",
        "Microsoft", "Microsoft USB Optical Mouse",
        "unverified_catalog_identity", "identity_only_generic_report")),
    ("tablets", (
        "qemu-generic-usb-tablet", "0x0627", "0x0001", "0x0000",
        "not_exposed", "QEMU USB Tablet", "qemu_native_virtual_device",
        "generic_virtual_only")),
):
    enabled = [item for item in hid.get(kind, []) if item.get("enabled") is True]
    if len(enabled) != 1:
        fail(f"{kind} 必须且只能启用一个与 C descriptor 匹配的模板")
    item = enabled[0]
    actual = tuple(item.get(key) for key in (
        "id", "vendor_id", "product_id", "bcd_device", "manufacturer",
        "product", "verification_status", "descriptor_fidelity"))
    if actual != expected or item.get("serial_exposed") is not False:
        fail(f"{kind} 身份字段或 descriptor fidelity 与当前 C 实现不匹配")

if operation == "validate":
    print(root["catalog_revision"])
elif operation == "storage":
    print("|".join(str(value) for value in (
        storage["id"], storage["model"], storage["firmware"], storage["raw_bytes"],
        pci["vendor"], pci["device"], pci["subsystem_vendor"],
        pci["subsystem_device"], nvme["subnqn_template"],
    )))
elif operation == "monitor":
    print("|".join(str(value) for value in (
        monitor["id"], monitor["vendor_code"], monitor["name"], monitor["width_mm"],
        monitor["height_mm"], monitor["serial_prefix"], monitor["product_id"],
        monitor["manufacture_week"], monitor["manufacture_year"],
        monitor["video_input"], ranges["min_vfreq_hz"], ranges["max_vfreq_hz"],
        ranges["min_hfreq_khz"], ranges["max_hfreq_khz"],
        ranges["max_pixel_clock_mhz"], timing["xres"], timing["yres"],
        timing["refresh_millihz"],
    )))
elif operation in ("keyboards", "mice", "tablets"):
    item = next(value for value in hid[operation] if value.get("enabled") is True)
    print("|".join(str(value) for value in (
        item["vendor_id"], item["product_id"], item["manufacturer"],
        item["product"], item["id"], item["bcd_device"],
        item["descriptor_fidelity"],
    )))
else:
    fail(f"未知操作: {operation}")
PY
}

stealth_component_validate() {
    _stealth_component_python validate
}

stealth_component_rows() {
    case "$1" in
        storage|monitor|keyboards|mice|tablets) _stealth_component_python "$1" ;;
        *) echo "ERROR: 未知 component kind: $1" >&2; return 2 ;;
    esac
}
