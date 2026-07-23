#!/usr/bin/env bash
# 验证多品牌 NVMe 身份画像会原子设置 PCI 字段，并拒绝跨品牌混搭。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
QEMU="${QEMU:-$ROOT_DIR/build/qemu-system-x86_64}"

[[ -x "$QEMU" ]] || {
    echo "FAIL: 缺少可执行文件: $QEMU" >&2
    exit 1
}

python3 - "$QEMU" <<'PY'
import json
import subprocess
import sys


qemu = sys.argv[1]
profiles = (
    {
        "id": "samsung-970-pro-512gb",
        "model": "Samsung SSD 970 PRO 512GB",
        "firmware": "1B2QEXP7",
        "serial": "S4EVN1234567890",
        "pci": (0x144D, 0xA808, 0x144D, 0xA801),
    },
    {
        "id": "intel-760p-512gb",
        "model": "INTEL SSDPEKKW512G8",
        "firmware": "001C",
        "serial": "BTHH1234ABCD512D",
        "pci": (0x8086, 0xF1A6, 0x8086, 0x390B),
    },
    {
        "id": "wd-pc-sn730-512gb",
        "model": "WDC PC SN730 SDBPNTY-512G-1027",
        "firmware": "11110000",
        "serial": "1839A8012345",
        "pci": (0x15B7, 0x5006, 0x15B7, 0x5006),
    },
    {
        "id": "kioxia-xg6-512gb",
        "model": "KXG60ZNV512G KIOXIA",
        "firmware": "AGHA4101",
        "serial": "69UPA0ABC123",
        "pci": (0x1179, 0x011A, 0x1179, 0x0001),
    },
)


def run(profile, **overrides):
    values = dict(profile)
    values.update(overrides)
    vendor, _device, subsystem_vendor, subsystem_device = values["pci"]
    device = (
        f"nvme,id=testnvme,serial={values['serial']},"
        f"x-identity-profile={values['id']},"
        f"model-number={values['model']},firmware-rev={values['firmware']},"
        f"subsys-vendor-id=0x{subsystem_vendor:04x},"
        f"subsys-id=0x{subsystem_device:04x}"
    )
    request = "\n".join((
        '{"execute":"qmp_capabilities"}',
        '{"execute":"query-pci"}',
        '{"execute":"quit"}',
        "",
    ))
    return subprocess.run(
        [
            qemu, "-machine", "q35", "-accel", "tcg", "-display", "none",
            "-nodefaults", "-S", "-device", device, "-qmp", "stdio",
        ],
        input=request,
        text=True,
        capture_output=True,
        timeout=15,
        check=False,
    )


for profile in profiles:
    proc = run(profile)
    if proc.returncode != 0:
        raise SystemExit(
            f"合法 NVMe 画像启动失败: {profile['id']}\n{proc.stderr}"
        )
    replies = []
    for line in proc.stdout.splitlines():
        try:
            replies.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    buses = next(
        item["return"] for item in replies
        if isinstance(item.get("return"), list)
    )
    actual = {
        (
            dev["id"]["vendor"],
            dev["id"]["device"],
            dev["id"]["subsystem-vendor"],
            dev["id"]["subsystem"],
        )
        for bus in buses for dev in bus["devices"]
    }
    if profile["pci"] not in actual:
        raise SystemExit(
            f"{profile['id']} PCI 身份错误: {actual!r}"
        )


def must_fail(profile, expected, **overrides):
    proc = run(profile, **overrides)
    output = proc.stdout + proc.stderr
    if proc.returncode == 0 or expected not in output:
        raise SystemExit(
            f"非法画像未失败: {profile['id']} overrides={overrides!r}\n"
            f"returncode={proc.returncode}\n{output}"
        )


def must_succeed(profile, **overrides):
    proc = run(profile, **overrides)
    if proc.returncode != 0:
        raise SystemExit(
            f"合法序列号被拒绝: {profile['id']} overrides={overrides!r}\n"
            f"{proc.stdout}{proc.stderr}"
        )


# 固定格式位不参与占位判断；可变负载只在全 0、全 F 或全 N 时拒绝。
for profile_index, serial in (
    (0, "SN0NN0000000000"),
    (1, "BTHHN0000000512D"),
    (2, "N00000000000"),
    (2, "NFFFFFFFFFFF"),
    (3, "N00000000000"),
    (3, "NFFFFFFFFFFF"),
):
    must_succeed(profiles[profile_index], serial=serial)


must_fail(
    profiles[1],
    "model-number does not match",
    model=profiles[0]["model"],
)
must_fail(
    profiles[1],
    "firmware-rev does not match",
    firmware=profiles[2]["firmware"],
)
must_fail(
    profiles[1],
    "serial does not match vendor format",
    serial=profiles[0]["serial"],
)
must_fail(
    profiles[3],
    "subsys-id must be 0x0001",
    pci=(0x1179, 0x011A, 0x1179, 0x5006),
)
must_fail(
    profiles[1],
    "serial does not match vendor format",
    serial="BTHH123456789ABC",
)
for profile_index, serial in (
    (0, "S000N0000000000"),
    (0, "SFFFNFFFFFFFFFF"),
    (0, "SNNNNNNNNNNNNNN"),
    (1, "BTHH00000000512D"),
    (1, "BTHHFFFFFFFF512D"),
    (1, "BTHHNNNNNNNN512D"),
    (2, "000000000000"),
    (2, "FFFFFFFFFFFF"),
    (2, "NNNNNNNNNNNN"),
    (3, "000000000000"),
    (3, "FFFFFFFFFFFF"),
    (3, "NNNNNNNNNNNN"),
):
    must_fail(
        profiles[profile_index],
        "serial does not match vendor format",
        serial=serial,
    )
PY

echo "OK: NVMe multi-brand identity profiles"
