#!/usr/bin/env bash
# 验证 C 层硬件画像参数：覆盖值必须真正进入 PCI 配置空间，非法组合必须失败。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
QEMU="${QEMU:-$ROOT_DIR/build/qemu-system-x86_64}"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# 静态守卫优先使用 ripgrep；精简宿主/CI 没安装 rg 时回退到 POSIX grep 的
# 扩展正则模式。两条路径都只返回匹配状态，不把工具缺失误报成产品代码缺陷。
search_quiet() {
    local pattern="$1"
    shift
    if command -v rg >/dev/null 2>&1; then
        rg -q -- "$pattern" "$@"
    else
        grep -Eq -- "$pattern" "$@"
    fi
}

[[ -x "$QEMU" ]] || fail "缺少可执行文件: $QEMU"

# Python 负责 QMP 收发和超时，避免 shell 管道在 QEMU 异常退出时挂住。
python3 - "$QEMU" <<'PY'
import json
import subprocess
import sys

qemu = sys.argv[1]


def run_qmp(extra_args, timeout=15):
    command = [
        qemu, "-machine", "q35", "-accel", "tcg", "-display", "none",
        "-nodefaults", "-S", *extra_args, "-qmp", "stdio",
    ]
    request = "\n".join([
        '{"execute":"qmp_capabilities"}',
        '{"execute":"query-pci"}',
        ('{"execute":"human-monitor-command","arguments":'
         '{"command-line":"info qtree"}}'),
        '{"execute":"quit"}',
        "",
    ])
    proc = subprocess.run(
        command, input=request, text=True, capture_output=True,
        timeout=timeout, check=False,
    )
    return proc


args = [
    "-global", "q35-pcihost.x-pci-mch-vendor-id=0x8086",
    "-global", "q35-pcihost.x-pci-mch-device-id=0x1237",
    "-global", "q35-pcihost.x-pci-mch-sub-vendor-id=0x1043",
    "-global", "q35-pcihost.x-pci-mch-sub-device-id=0x1111",
    "-global", "ICH9-LPC.x-pci-vendor-id=0x8086",
    "-global", "ICH9-LPC.x-pci-device-id=0x7a87",
    "-global", "ICH9-LPC.x-pci-sub-vendor-id=0x1043",
    "-global", "ICH9-LPC.x-pci-sub-device-id=0x2222",
    "-global", "ICH9-SMB.x-pci-vendor-id=0x8086",
    "-global", "ICH9-SMB.x-pci-device-id=0x7a23",
    "-global", "ICH9-SMB.x-pci-sub-vendor-id=0x1043",
    "-global", "ICH9-SMB.x-pci-sub-device-id=0x3333",
    "-global", "ich9-ahci.x-pci-vendor-id=0x8086",
    "-global", "ich9-ahci.x-pci-device-id=0x7ae2",
    "-global", "ich9-ahci.x-pci-sub-vendor-id=0x1043",
    "-global", "ich9-ahci.x-pci-sub-device-id=0x4444",
    "-device", (
        "ich9-intel-hda,x-pci-vendor-id=0x8086,"
        "x-pci-device-id=0x7ad0,x-pci-sub-vendor-id=0x1043,"
        "x-pci-sub-device-id=0x5555"
    ),
]
result = run_qmp(args)
if result.returncode != 0:
    raise SystemExit(f"PCI 覆盖启动失败:\n{result.stderr}")

responses = []
for line in result.stdout.splitlines():
    try:
        responses.append(json.loads(line))
    except json.JSONDecodeError:
        continue
pci_reply = next(
    item["return"] for item in responses
    if isinstance(item.get("return"), list)
)
devices = {
    (dev["slot"], dev["function"]): dev["id"]
    for bus in pci_reply for dev in bus["devices"]
}
expected = {
    (0, 0): (0x8086, 0x1237, 0x1043, 0x1111),
    (31, 0): (0x8086, 0x7A87, 0x1043, 0x2222),
    (31, 2): (0x8086, 0x7AE2, 0x1043, 0x4444),
    (31, 3): (0x8086, 0x7A23, 0x1043, 0x3333),
    (1, 0): (0x8086, 0x7AD0, 0x1043, 0x5555),
}
for address, values in expected.items():
    identity = devices.get(address)
    if identity is None:
        raise SystemExit(f"缺少 PCI 设备 {address}")
    actual = (
        identity["vendor"], identity["device"],
        identity["subsystem-vendor"], identity["subsystem"],
    )
    if actual != values:
        raise SystemExit(f"PCI {address} 身份错误: {actual!r} != {values!r}")


# 清单中的 fidelity.bdf_layout 必须来自真实 query-pci，而不是按 H110/H310
# 手册臆测。Linux 当前创建四个 root port，Windows 创建三个；HDA 没有显式
# addr，因此分别自动落在 00:05.0 与 00:04.0。PCH 固定功能仍是 Q35/ICH9 的
# 00:1f.0/.2/.3，这项回归专门防止文档把可改 PCI ID 误写成目标 PCH 拓扑。
def assert_q35_bdf(root_port_count, hda_slot, launcher):
    layout_args = []
    for index in range(root_port_count):
        options = f"pcie-root-port,id=rp{index},slot={index},bus=pcie.0"
        if index == 0:
            options += ",multifunction=on"
        layout_args.extend(("-device", options))
    layout_args.extend(("-device", "ich9-intel-hda,id=hda-layout"))
    layout_result = run_qmp(layout_args)
    if layout_result.returncode != 0:
        raise SystemExit(f"{launcher} Q35 BDF 启动失败:\n{layout_result.stderr}")
    layout_responses = []
    for line in layout_result.stdout.splitlines():
        try:
            layout_responses.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    layout_reply = next(
        item["return"] for item in layout_responses
        if isinstance(item.get("return"), list)
    )
    root_bus = next(bus for bus in layout_reply if bus["bus"] == 0)
    actual_layout = {
        (dev["slot"], dev["function"]): (
            dev.get("qdev_id", ""), dev["class_info"]["desc"]
        )
        for dev in root_bus["devices"]
    }
    expected_layout = {
        (0, 0): ("", "Host bridge"),
        (31, 0): ("", "ISA bridge"),
        (31, 2): ("", "SATA controller"),
        (31, 3): ("", "SMBus"),
        (hda_slot, 0): ("hda-layout", "Audio controller"),
    }
    for index in range(root_port_count):
        expected_layout[(index + 1, 0)] = (f"rp{index}", "PCI bridge")
    for address, expected_device in expected_layout.items():
        if actual_layout.get(address) != expected_device:
            raise SystemExit(
                f"{launcher} Q35 BDF {address} 错误: "
                f"{actual_layout.get(address)!r} != {expected_device!r}"
            )


assert_q35_bdf(4, 5, "Linux")
assert_q35_bdf(3, 4, "Windows")


def must_fail(extra_args, expected_text):
    proc = run_qmp(extra_args)
    output = proc.stdout + proc.stderr
    if proc.returncode == 0 or expected_text not in output:
        raise SystemExit(
            f"非法配置未按预期失败: {extra_args!r}\n"
            f"returncode={proc.returncode}\n{output}"
        )


must_fail(
    ["-global", "q35-pcihost.x-pci-mch-device-id=0x10000"],
    "out of range",
)
must_fail([
    "-device",
    "nvme,serial=S123,use-samsung-id=on,"
    "model-number=Samsung SSD 970 PRO 512GB,firmware-rev=1B2QEXM7",
], "does not match Samsung model")
must_fail([
    "-device",
    "nvme,serial=S123,use-samsung-id=on,"
    "model-number=Samsung SSD 980 500GB,firmware-rev=3B4QFXO7",
], "unsupported Samsung model-number")
must_fail([
    "-device",
    "nvme,serial=S123,use-samsung-id=on,"
    "model-number=Samsung SSD 970 PRO 512GB,firmware-rev=1B2QEXP7,"
    "subsys-id=0xa802",
], "subsys-id must be 0xa801")
must_fail([
    "-device", "qemu-xhci,id=xhci",
    "-device",
    "usb-tablet,vendorid=0x256c,productid=0x006d,product=HUION PenTablet",
], "branded tablet descriptors are unsupported")
must_fail([
    "-device", "virtio-vga,edid-product-id=0x10000",
], "EDID profile field is out of range")
must_fail([
    "-smbios", (
        "type=17,memory-type=0x1a,rank=1,voltage=1200,"
        "speed=2133,configured-speed=2400"
    ),
], "configured-speed cannot exceed rated speed")
must_fail([
    "-audiodev", "none,id=audtest",
    "-device", "ich9-intel-hda,id=hda",
    "-device", (
        "hda-duplex,bus=hda.0,audiodev=audtest,"
        "x-codec-id=0x10ec0887"
    ),
], "HDA codec identity overrides require x-identity-compat=on")

# 合法的 SMBIOS、EDID、SPD 与 NVMe 参数至少完成一次真实 QOM realize。
valid = run_qmp([
    "-m", "8G",
    "-smbios", "type=3,chassis-type=0x07",
    "-smbios", (
        "type=4,voltage=0x8c,external-clock=100,processor-upgrade=0x31,"
        "processor-characteristics=0xfc"
    ),
    "-smbios", (
        "type=17,memory-type=0x1a,type-detail=0x80,rank=1,voltage=1200,"
        "speed=2666,configured-speed=2133"
    ),
    "-device", (
        "virtio-vga,edid-product-id=0x0f65,edid-manufacture-week=32,"
        "edid-manufacture-year=2018,edid-video-input=0xa3,"
        "edid-min-vfreq-hz=50,edid-max-vfreq-hz=75,"
        "edid-min-hfreq-khz=30,edid-max-hfreq-khz=83,"
        "edid-max-pixel-clock-mhz=170,edid-secondary-xres=1600,"
        "edid-secondary-yres=900,edid-secondary-refresh-rate=60000"
    ),
    "-device", (
        "nvme,serial=S123,use-samsung-id=on,"
        "model-number=Samsung SSD 970 PRO 512GB,firmware-rev=1B2QEXP7,"
        "subsys-vendor-id=0x144d,subsys-id=0xa801,"
        "subnqn=nqn.1994-11.com.samsung:nvme:970-PRO:M.2:S123"
    ),
    "-audiodev", "none,id=audtest",
    "-device", "ich9-intel-hda,id=hda",
    "-device", (
        "hda-duplex,bus=hda.0,audiodev=audtest,x-identity-compat=on,"
        "x-codec-id=0x10ec0887,x-codec-revision=0x100302,"
        "x-codec-subsystem-id=0x104386c7"
    ),
])
if valid.returncode != 0:
    raise SystemExit(f"合法硬件画像启动失败:\n{valid.stdout}\n{valid.stderr}")
valid_responses = [json.loads(line) for line in valid.stdout.splitlines()]
valid_pci_reply = next(
    item["return"] for item in valid_responses
    if isinstance(item.get("return"), list)
)
valid_pci_ids = {
    (
        dev["id"]["vendor"], dev["id"]["device"],
        dev["id"]["subsystem-vendor"], dev["id"]["subsystem"],
    )
    for bus in valid_pci_reply for dev in bus["devices"]
}
if (0x144D, 0xA804, 0x144D, 0xA801) not in valid_pci_ids:
    raise SystemExit("Samsung 970 PRO 必须报告 144d:a804 / 144d:a801")
qtree = next(
    item["return"] for item in valid_responses
    if isinstance(item.get("return"), str) and "bus: main-system-bus" in item["return"]
)
if qtree.count('dev: smbus-eeprom') != 2:
    raise SystemExit("8GiB/4GiB-per-DIMM 应生成且只生成两条 SPD EEPROM")
PY

# 静态守卫防止后续重构重新引入最初的跨平台硬编码。
! search_quiet 'processor_upgrade = 0x38|memory_type = 0x1A' \
    "$ROOT_DIR/hw/smbios/smbios.c" \
    || fail "SMBIOS 重新引入固定 AM4/DDR4"
! search_quiet 'spd_data_generate_ddr4\(4096, 2666\)' \
    "$ROOT_DIR/hw/i386/pc_q35.c" \
    || fail "Q35 重新引入固定两条 DDR4 SPD"
search_quiet 'hda_audio_identity_param\(a, payload, param->val\)' \
    "$ROOT_DIR/hw/audio/hda-codec.c" \
    || fail "HDA 参数查询未应用 Codec 身份覆盖"
search_quiet 'x-identity-compat=on because the node topology remains' \
    "$ROOT_DIR/hw/audio/hda-codec.c" \
    || fail "HDA Codec 身份覆盖失去显式兼容模式保护"
! search_quiet 'PCI_DEVICE_ID_SAMSUNG_NVME[[:space:]]+0xa809' \
    "$ROOT_DIR/include/hw/pci/pci_ids.h" \
    || fail "Samsung 970 PRO 重新使用了错误的 a809 主设备 ID"

echo "PASS: C 层硬件身份参数化、校验与失败路径"
