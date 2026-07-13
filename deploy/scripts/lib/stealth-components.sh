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

storages = [item for item in root.get("storage", []) if item.get("enabled") is True]
if len(storages) != 1:
    fail("严格目录必须且只能启用一个已核验 SSD")
storage = storages[0]
if (storage.get("model"), storage.get("firmware"), storage.get("raw_bytes")) != (
    "Samsung SSD 970 PRO 512GB", "1B2QEXP7", 512110190592
):
    fail("SSD 型号/固件/容量不是核验过的 970 PRO 512GB bundle")
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
if "{serial}" not in nvme.get("subnqn_template", ""):
    fail("subnqn_template 必须绑定每机 NVMe serial")

monitors = [item for item in root.get("monitors", []) if item.get("enabled") is True]
if len(monitors) != 1:
    fail("当前 EDID 生成器只能启用一个深层核验显示器")
monitor = monitors[0]
if len(monitor.get("vendor_code", "")) != 3 or not hex16.fullmatch(
        monitor.get("product_id", "")):
    fail("显示器 vendor_code/product_id 非法")
if not (1 <= monitor.get("manufacture_week", 0) <= 53 and
        1990 <= monitor.get("manufacture_year", 0) <= 2100):
    fail("显示器生产日期非法")
ranges = monitor.get("range", {})
if not (ranges.get("min_vfreq_hz", 0) <= ranges.get("max_vfreq_hz", -1) and
        ranges.get("min_hfreq_khz", 0) <= ranges.get("max_hfreq_khz", -1)):
    fail("显示器扫描范围颠倒")

hid = root.get("hid", {})
for kind, expected in (
    ("keyboards", ("0x045E", "0x0750", "0x0163")),
    ("mice", ("0x045E", "0x00CB", "0x0163")),
    ("tablets", ("0x0627", "0x0001", "0x0000")),
):
    enabled = [item for item in hid.get(kind, []) if item.get("enabled") is True]
    if len(enabled) != 1:
        fail(f"{kind} 必须且只能启用一个与 C descriptor 匹配的模板")
    item = enabled[0]
    actual = (item.get("vendor_id"), item.get("product_id"), item.get("bcd_device"))
    if actual != expected or item.get("serial_exposed") is not False:
        fail(f"{kind} VID/PID/bcdDevice/serial 与 C descriptor 不匹配")

if operation == "validate":
    print(root["catalog_revision"])
elif operation == "storage":
    print("|".join(str(value) for value in (
        storage["id"], storage["model"], storage["firmware"], storage["raw_bytes"],
        pci["vendor"], pci["device"], pci["subsystem_vendor"],
        pci["subsystem_device"], nvme["subnqn_template"],
    )))
elif operation == "monitor":
    timing = monitor["secondary_timing"]
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
