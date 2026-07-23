#!/usr/bin/env bash
# 验证离线 qemu-edid 与运行时 virtio-gpu 使用同一套多品牌深层字段。
# shellcheck disable=SC2016 # 静态契约必须匹配生产脚本中的 $var 字面量。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
QEMU_EDID="$REPO_ROOT/build/qemu-edid"
CATALOG="$REPO_ROOT/deploy/hardware/components.json"
HOST_FIX="$REPO_ROOT/deploy/scripts/host-fix-display-cache.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[[ -x "$QEMU_EDID" ]] || fail "缺少 build/qemu-edid"
[[ -f "$CATALOG" ]] || fail "缺少显示器目录"
[[ -f "$HOST_FIX" ]] || fail "缺少离线显示缓存修复工具"

python3 - "$QEMU_EDID" "$CATALOG" "$TMP_DIR" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

tool, catalog_path, temp_dir = sys.argv[1:]
catalog = json.loads(Path(catalog_path).read_text(encoding="utf-8"))


def vendor_code(edid: bytes) -> str:
    word = (edid[8] << 8) | edid[9]
    return "".join(chr(64 + ((word >> shift) & 0x1F))
                   for shift in (10, 5, 0))


def descriptors(edid: bytes) -> list[int]:
    result = [54, 72, 90, 108]
    if len(edid) >= 256 and edid[128] == 0x02:
        result.extend(range(128 + edid[130], 128 + 127 - 17, 18))
    return result


def binary_serial(item: dict[str, object], serial: str) -> int:
    policy = item["binary_serial_policy"]
    if policy["kind"] == "fixed_u32":
        return int(policy["fixed_value"], 0)
    if policy["kind"] == "decimal_suffix6":
        return int(serial[-6:], 10)
    raise SystemExit(f"{item['id']} binary serial 策略未知")


for item in catalog["monitors"]:
    if item.get("enabled") is not True:
        continue
    serial_policy = item["serial_policy"]
    serial = {
        "samsung_h4zmc_decimal5": "H4ZMC12345",
        "aoc_upper_alnum7_decimal6": "ABCD12A345678",
        "xiaomi_29200_label_slash_removed_decimal": "2920012345678",
        "lenovo_urb_upper_alnum": "URB12AB3",
    }[serial_policy["kind"]]
    expected_binary_serial = binary_serial(item, serial)
    output = str(Path(temp_dir) / f"{item['id']}.bin")
    native = item["native_resolution"]
    scan = item["range"]
    timing = item["secondary_timing"]
    cmd = [
        tool, "-o", output, "-v", item["vendor_code"],
        "-n", item["name"], "-s", serial,
        "-x", str(native["x"]), "-y", str(native["y"]),
        "-X", str(native["x"]), "-Y", str(native["y"]),
        "--width-mm", str(item["width_mm"]),
        "--height-mm", str(item["height_mm"]),
        "--product-id", item["product_id"],
        "--binary-serial", f"0x{expected_binary_serial:08X}",
        "--revision", str(item["edid_revision"]),
        "--manufacture-week", str(item["manufacture_week"]),
        "--manufacture-year", str(item["manufacture_year"]),
        "--video-input", item["video_input"],
        "--min-vfreq-hz", str(scan["min_vfreq_hz"]),
        "--max-vfreq-hz", str(scan["max_vfreq_hz"]),
        "--min-hfreq-khz", str(scan["min_hfreq_khz"]),
        "--max-hfreq-khz", str(scan["max_hfreq_khz"]),
        "--max-pixel-clock-mhz", str(scan["max_pixel_clock_mhz"]),
        "--secondary-xres", str(timing["xres"]),
        "--secondary-yres", str(timing["yres"]),
        "--secondary-refresh-rate", str(timing["refresh_millihz"]),
    ]
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL)
    edid = Path(output).read_bytes()
    if len(edid) not in (128, 256, 384):
        raise SystemExit(f"{item['id']} EDID 长度异常: {len(edid)}")
    if any(sum(edid[pos:pos + 128]) & 0xFF
           for pos in range(0, len(edid), 128)):
        raise SystemExit(f"{item['id']} EDID checksum 错误")
    if vendor_code(edid) != item["vendor_code"]:
        raise SystemExit(f"{item['id']} EISA vendor 不一致")
    if (edid[10] | (edid[11] << 8)) != int(item["product_id"], 0):
        raise SystemExit(f"{item['id']} product ID 不一致")
    if int.from_bytes(edid[12:16], "little") != expected_binary_serial:
        raise SystemExit(f"{item['id']} binary serial 不一致")
    if (edid[18], edid[19]) != (1, item["edid_revision"]):
        raise SystemExit(f"{item['id']} EDID revision 不一致")
    if (edid[16], edid[17] + 1990, edid[20]) != (
            item["manufacture_week"], item["manufacture_year"],
            int(item["video_input"], 0)):
        raise SystemExit(f"{item['id']} 生产日期/video input 不一致")

    dtds: list[tuple[int, int]] = []
    dtd_details: dict[int, tuple[int, ...]] = {}
    text: dict[int, str] = {}
    range_desc = None
    for base in descriptors(edid):
        if edid[base] or edid[base + 1]:
            xres = ((edid[base + 4] & 0xF0) << 4) | edid[base + 2]
            yres = ((edid[base + 7] & 0xF0) << 4) | edid[base + 5]
            width = edid[base + 12] | ((edid[base + 14] & 0xF0) << 4)
            height = edid[base + 13] | ((edid[base + 14] & 0x0F) << 8)
            dtds.append((xres, yres))
            hblank = edid[base + 3] | ((edid[base + 4] & 0x0F) << 8)
            vblank = edid[base + 6] | ((edid[base + 7] & 0x0F) << 8)
            hfront = edid[base + 8] | ((edid[base + 11] & 0xC0) << 2)
            hsync = edid[base + 9] | ((edid[base + 11] & 0x30) << 4)
            vfront = (edid[base + 10] >> 4) | (
                (edid[base + 11] & 0x0C) << 2)
            vsync = (edid[base + 10] & 0x0F) | (
                (edid[base + 11] & 0x03) << 4)
            dtd_details[base] = (
                int.from_bytes(edid[base:base + 2], "little") * 10,
                xres, yres, hfront, hsync, hblank,
                vfront, vsync, vblank,
                int(bool(edid[base + 17] & 0x02)),
                int(bool(edid[base + 17] & 0x04)),
                width, height,
            )
        elif edid[base:base + 3] == b"\x00\x00\x00":
            tag = edid[base + 3]
            if tag in (0xFC, 0xFF):
                text[tag] = edid[base + 5:base + 18].decode(
                    "ascii").rstrip(" \n\x00")
            elif tag == 0xFD:
                range_desc = tuple(edid[base + 5:base + 10])
    expected_dtds = {
        (native["x"], native["y"]),
        (timing["xres"], timing["yres"]),
    }
    if not expected_dtds.issubset(dtds):
        raise SystemExit(f"{item['id']} DTD 不完整: {dtds}")
    expected_primary = (
        148500, 1920, 1080, 88, 44, 280, 4, 5, 45, 1, 1,
        item["width_mm"], item["height_mm"],
    )
    expected_secondary = (
        timing["pixel_clock_khz"], timing["xres"], timing["yres"],
        timing["hfront"], timing["hsync"], timing["hblank"],
        timing["vfront"], timing["vsync"], timing["vblank"],
        int(timing["hsync_positive"]), int(timing["vsync_positive"]),
        timing["width_mm"], timing["height_mm"],
    )
    if dtd_details.get(54) != expected_primary:
        raise SystemExit(
            f"{item['id']} base=54 首选 DTD 不一致: {dtd_details}")
    if dtd_details.get(72) != expected_secondary:
        raise SystemExit(
            f"{item['id']} base=72 次要 DTD 与 raw EDID 不一致: "
            f"{dtd_details}")
    if text.get(0xFC) != item["name"] or text.get(0xFF) != serial:
        raise SystemExit(f"{item['id']} 名称/序列描述符不一致: {text}")
    expected_range = (
        scan["min_vfreq_hz"], scan["max_vfreq_hz"],
        scan["min_hfreq_khz"], scan["max_hfreq_khz"],
        (scan["max_pixel_clock_mhz"] + 9) // 10,
    )
    if range_desc != expected_range:
        raise SystemExit(f"{item['id']} 扫描范围不一致: {range_desc}")
PY

if "$QEMU_EDID" --width-mm 527 -o "$TMP_DIR/bad.bin" \
        >/dev/null 2>&1; then
    fail "qemu-edid 接受了单边物理尺寸"
fi
if "$QEMU_EDID" --manufacture-year 1800 -o "$TMP_DIR/bad.bin" \
        >/dev/null 2>&1; then
    fail "qemu-edid 接受了越界生产年份"
fi
if "$QEMU_EDID" --min-vfreq-hz 80 --max-vfreq-hz 50 \
        -o "$TMP_DIR/bad.bin" >/dev/null 2>&1; then
    fail "qemu-edid 接受了反向扫描范围"
fi
if "$QEMU_EDID" --revision 2 -o "$TMP_DIR/bad.bin" \
        >/dev/null 2>&1; then
    fail "qemu-edid 接受了不支持的 EDID revision"
fi

for option in width-mm height-mm product-id manufacture-week manufacture-year \
        binary-serial revision video-input min-vfreq-hz max-vfreq-hz \
        min-hfreq-khz max-hfreq-khz \
        max-pixel-clock-mhz secondary-xres secondary-yres \
        secondary-refresh-rate; do
    grep -F -- "--$option" "$HOST_FIX" >/dev/null ||
        fail "离线缓存修复没有传入 --$option"
done

for field in EDID_BINARY_SERIAL EDID_REVISION EDID_PRODUCT_ID \
        EDID_MANUFACTURE_WEEK EDID_MANUFACTURE_YEAR EDID_VIDEO_INPUT \
        EDID_MIN_VFREQ_HZ EDID_MAX_VFREQ_HZ EDID_MIN_HFREQ_KHZ \
        EDID_MAX_HFREQ_KHZ EDID_MAX_PIXEL_CLOCK_MHZ \
        EDID_SECONDARY_XRES EDID_SECONDARY_YRES EDID_SECONDARY_REFRESH_RATE \
        EDID_SECONDARY_PIXEL_CLOCK_KHZ EDID_SECONDARY_HFRONT \
        EDID_SECONDARY_HSYNC EDID_SECONDARY_HBLANK EDID_SECONDARY_VFRONT \
        EDID_SECONDARY_VSYNC EDID_SECONDARY_VBLANK \
        EDID_SECONDARY_HSYNC_POSITIVE EDID_SECONDARY_VSYNC_POSITIVE \
        EDID_SECONDARY_WIDTH_MM EDID_SECONDARY_HEIGHT_MM; do
    grep -F "stealth_profile_get $field" "$HOST_FIX" >/dev/null ||
        fail "离线缓存修复未读取 profile 字段 $field"
done
grep -F '"$EDID_BINARY_SERIAL" == "$EXPECTED_BINARY_SERIAL"' \
    "$HOST_FIX" >/dev/null ||
    fail "离线缓存修复未把 profile binary serial 与目录逐项比较"
grep -F '"$EDID_SECONDARY_PIXEL_CLOCK_KHZ" == "$EXPECTED_SECONDARY_CLOCK"' \
    "$HOST_FIX" >/dev/null ||
    fail "离线缓存修复未把 profile 完整 DTD 与目录逐项比较"
grep -F 'assert dtd_details.get(54) == expected_primary_detail' \
    "$HOST_FIX" >/dev/null ||
    fail "离线缓存修复未把 base=54 精确绑定为首选 1080p DTD"
grep -F 'assert dtd_details.get(72) == expected_secondary_detail' \
    "$HOST_FIX" >/dev/null ||
    fail "离线缓存修复未把 base=72 精确绑定为目录次要 DTD"
if grep -F 'expected_secondary_detail in dtd_details' "$HOST_FIX" >/dev/null; then
    fail "离线缓存修复仍用 membership 匹配同分辨率 DTD"
fi

# 直接抽取生产脚本的 EDID 阶段做故障注入，防止 `set -u -o pipefail`
# 环境下某个命令失败后仍继续进入 NBD/hivex。两种失败都不允许到达阶段尾标记：
# 1) 生成器明确失败；2) 生成器返回成功但没有产生可校验的 EDID。
EDID_STAGE="$(
    awk '
        /^# ---- 2\)/ { capture = 1; next }
        /^# ---- 3\)/ { capture = 0 }
        capture { print }
    ' "$HOST_FIX"
)"
[[ -n "$EDID_STAGE" ]] || fail "无法抽取离线缓存修复的 EDID 阶段"
grep -F 'rm -f -- "$EDID_BIN" || die' <<<"$EDID_STAGE" >/dev/null ||
    fail "离线缓存修复未在生成前清理旧 EDID"
grep -F 'die "qemu-edid 生成显示器 EDID 失败"' \
    <<<"$EDID_STAGE" >/dev/null ||
    fail "离线缓存修复未对生成失败执行 fail-closed"
grep -F 'die "生成的显示器 EDID 未通过深层字段校验"' \
    <<<"$EDID_STAGE" >/dev/null ||
    fail "离线缓存修复未对深层校验失败执行 fail-closed"

run_injected_edid_stage() {
    local injected_tool="$1"
    local output="$2"
    local reached_marker="$3"
    EDID_STAGE="$EDID_STAGE" QEMU_EDID="$injected_tool" EDID_BIN="$output" \
        REACHED_MARKER="$reached_marker" \
        EDID_VENDOR=AOC EDID_NAME=24B2W1G5 \
        EDID_SERIAL=ABCD12A345678 \
        EDID_WIDTH_MM=527 EDID_HEIGHT_MM=296 \
        EXPECTED_PRODUCT_ID=0x2402 EXPECTED_WEEK=39 EXPECTED_YEAR=2022 \
        EXPECTED_VIDEO_INPUT=0x80 EXPECTED_MIN_VFREQ=48 \
        EXPECTED_MAX_VFREQ=75 EXPECTED_MIN_HFREQ=30 \
        EXPECTED_MAX_HFREQ=85 EXPECTED_MAX_PIXEL_CLOCK=180 \
        EXPECTED_SECONDARY_X=1920 EXPECTED_SECONDARY_Y=1080 \
        EXPECTED_SECONDARY_REFRESH=74973 \
        EXPECTED_BINARY_SERIAL=0x0005464E EXPECTED_REVISION=3 \
        EXPECTED_SECONDARY_CLOCK=174500 EXPECTED_SECONDARY_HFRONT=48 \
        EXPECTED_SECONDARY_HSYNC=32 EXPECTED_SECONDARY_HBLANK=160 \
        EXPECTED_SECONDARY_VFRONT=3 EXPECTED_SECONDARY_VSYNC=5 \
        EXPECTED_SECONDARY_VBLANK=39 \
        EXPECTED_SECONDARY_HSYNC_POSITIVE=1 \
        EXPECTED_SECONDARY_VSYNC_POSITIVE=0 \
        EXPECTED_SECONDARY_WIDTH_MM=527 EXPECTED_SECONDARY_HEIGHT_MM=296 \
        bash -c '
            set -u -o pipefail
            log() { :; }
            die() { exit 97; }
            eval "$EDID_STAGE"
            touch "$REACHED_MARKER"
        '
}

STALE_EDID="$TMP_DIR/stale.bin"
GENERATOR_MARKER="$TMP_DIR/generator-stage-reached"
printf 'old-edid-must-not-survive' >"$STALE_EDID"
if run_injected_edid_stage /bin/false "$STALE_EDID" \
        "$GENERATOR_MARKER" >/dev/null 2>&1; then
    fail "qemu-edid 失败后生产 EDID 阶段仍返回成功"
fi
[[ ! -e "$STALE_EDID" ]] ||
    fail "qemu-edid 失败后仍保留了旧 EDID 临时文件"
[[ ! -e "$GENERATOR_MARKER" ]] ||
    fail "qemu-edid 失败后仍执行到了 EDID 阶段末尾"

VALIDATOR_MARKER="$TMP_DIR/validator-stage-reached"
if run_injected_edid_stage /bin/true "$TMP_DIR/missing.bin" \
        "$VALIDATOR_MARKER" >/dev/null 2>&1; then
    fail "EDID 深层校验失败后生产阶段仍返回成功"
fi
[[ ! -e "$VALIDATOR_MARKER" ]] ||
    fail "EDID 深层校验失败后仍执行到了 EDID 阶段末尾"

echo "PASS: qemu-edid reproduces all multi-brand component profiles"
