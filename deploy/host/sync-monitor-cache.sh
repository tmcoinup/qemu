#!/bin/bash
# sync-monitor-cache.sh — vGPU host 侧离线刷新 Windows 显示器 EDID/模式缓存
#
# 背景：
#   Windows 把显示器 EDID 缓存在
#     HKLM\SYSTEM\CurrentControlSet\Enum\DISPLAY\<PNP>\<inst>\Device Parameters\EDID
#   显示器目标模式从这份【缓存的 EDID】解析。旧 guest（以及从旧 base 克隆
#   出来的实例）不会自动刷新这份缓存，所以即便 QEMU 端 EDID 已改变，
#   Windows 仍可能显示旧目标模式。NVIDIA GRID 还会从显示适配器 software key
#   的 NV_Modes 补充 source modes，必须用同一份 R535 page-safe FHD 合同约束。
#   GraphicsDrivers\Configuration / Connectivity 还会按显示器签名缓存"已验证
#   模式表"，同样会拖着旧分辨率。
#
#   本脚本离线地：
#     1) 按统一真实型号目录生成完整 EDID，同时写进每个
#        Enum\DISPLAY 实例的 Device Parameters\EDID 和 Microsoft 标准
#        EDID_OVERRIDE\0..N；后者才是 Windows 显示栈/第三方工具优先消费的
#        有效 EDID override；
#     2) 沿 Enum\PCI 中的 NVIDIA Driver 关系，只把锁定 GRID 538.33 的
#        NV_Modes 收敛为 EDID 同一份 8 项 page-safe FHD/1K PC 模式合同；
#     3) 清空 GraphicsDrivers 的模式/连接缓存子键（含跨厂商
#        残留，如 DEL0F65），让 Windows 下次开机从新 EDID 重建模式表。
#
# 用法：
#   sudo deploy/host/sync-monitor-cache.sh --disk disk.qcow2 \
#       --monitor-profile dell-p2419h --serial CC3P12345678 --instance vm1
#   NBD=/dev/nbd5 sudo deploy/host/sync-monitor-cache.sh --disk disk.qcow2 \
#       --monitor-profile dell-p2419h --serial CC3P12345678 --instance vm1
#
# 安全：
#   - 只修改显式传入的 vmN/disk.qcow2，不碰公共 base。
#   - 若该实例的 QEMU 进程在跑，直接拒绝（并发挂载实例盘会损坏文件系统）。
#
# 依赖：qemu-utils(qemu-nbd) + ntfs-3g + python3-hivex
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_ROOT="$(cd "$DEPLOY_ROOT/.." && pwd)"
QEMU_EDID="${QEMU_EDID:-${SOURCE_ROOT}/build/qemu-edid}"
# Security-sensitive registry constants are always loaded from this checkout;
# unlike qemu-edid/catalog test inputs, the policy is not environment-overridable.
NVIDIA_MODE_POLICY="${DEPLOY_ROOT}/lib/nvidia_modes.py"
WINDOWS_HIVE_VALIDATOR="${DEPLOY_ROOT}/lib/windows_hive.py"
EXPECTED_DRIVER_VERSION="31.0.15.3833"
EXPECTED_DRIVER_INF_SHA256="67a240e1d464cf97dabfec1a7cecf000eaa9ddfd702f32ba2c8771f17905dc2b"
EXPECTED_DRIVER_CATALOG_SHA256="56b07bd93280bbda761cb5c9a3a13262c3605320d7286953989e2a5b16d5ec6f"
DRIVER_POLICY="grid-53833-native"
# G-11 production B keeps the original GRID package bound to this native
# endpoint.  A legacy-A consumer-ID Enum key can remain as inert migration
# history and must not be mistaken for the current device software key.
EXPECTED_NVIDIA_PNP_ID='PCI\VEN_10DE&DEV_1E30&SUBSYS_132610DE'
INSTANCE_LABEL=""
DISK=""
MONITOR_PROFILE_KEY=""
MONITOR_SERIAL_VALUE=""
MARKER=""
MARKER_VALUE=""
GENERATE_ONLY=""

while (( $# > 0 )); do
    case "$1" in
        --disk) DISK=$2; shift 2 ;;
        --qemu-edid) QEMU_EDID=$2; shift 2 ;;
        --catalog) MONITOR_PROFILE_CATALOG=$2; shift 2 ;;
        --monitor-profile) MONITOR_PROFILE_KEY=$2; shift 2 ;;
        --serial) MONITOR_SERIAL_VALUE=$2; shift 2 ;;
        --instance) INSTANCE_LABEL=$2; shift 2 ;;
        --marker) MARKER=$2; shift 2 ;;
        --marker-value) MARKER_VALUE=$2; shift 2 ;;
        --driver-version) EXPECTED_DRIVER_VERSION=$2; shift 2 ;;
        --driver-inf-sha256) EXPECTED_DRIVER_INF_SHA256=${2,,}; shift 2 ;;
        --driver-catalog-sha256) EXPECTED_DRIVER_CATALOG_SHA256=${2,,}; shift 2 ;;
        --driver-policy) DRIVER_POLICY=$2; shift 2 ;;
        --nvidia-pnp-id) EXPECTED_NVIDIA_PNP_ID=$2; shift 2 ;;
        --generate-only) GENERATE_ONLY=$2; shift 2 ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "未知参数: $1" >&2; exit 2 ;;
    esac
done

# shellcheck source=../../lib/monitor-profiles.sh
source "$DEPLOY_ROOT/lib/monitor-profiles.sh"
monitor_profiles_validate

if [[ -n "$GENERATE_ONLY" ]]; then
    INSTANCE_LABEL="${INSTANCE_LABEL:-generate-only}"
    [[ -n "$MONITOR_PROFILE_KEY" ]] || {
        echo "--generate-only 需要 --monitor-profile" >&2
        exit 2
    }
else
    [[ -n "$DISK" ]] || {
        echo "--disk 是必需参数" >&2
        exit 2
    }
    INSTANCE_LABEL="${INSTANCE_LABEL:-custom}"
fi
SAFE_INSTANCE=${INSTANCE_LABEL//[^A-Za-z0-9_.-]/_}
_NBD_PINNED="${NBD:+1}"   # 记录用户是否显式指定 NBD（忙时决定 fail-fast vs 自动选盘）
NBD="${NBD:-/dev/nbd0}"
MOUNT="/tmp/winmnt-disp-${SAFE_INSTANCE}"
EDID_BIN="/tmp/vgpu-edid-${SAFE_INSTANCE}.bin"

log() { echo "[disp-cache] $*"; }
die() { echo "[disp-cache] ERROR: $*" >&2; exit 1; }

[[ -x "$QEMU_EDID" ]] || die "找不到 $QEMU_EDID（先 ninja -C build qemu-edid）"
[[ -r "$NVIDIA_MODE_POLICY" ]] || die "找不到 NVIDIA 模式策略: $NVIDIA_MODE_POLICY"
[[ -r "$WINDOWS_HIVE_VALIDATOR" ]] || \
    die "找不到 Windows hive 校验器: $WINDOWS_HIVE_VALIDATOR"

# qemu-edid's option names and descriptor layout changed in newer QEMU
# branches.  The untracked build/ directory can therefore contain the other
# branch's binary immediately after a checkout.  Detect that state before
# generation: translating only the option names would still produce an EDID
# outside G-11's reviewed descriptor contract.
if ! QEMU_EDID_HELP=$("$QEMU_EDID" -h 2>&1); then
    die "无法读取 $QEMU_EDID 的参数接口；请运行 ./deploy/host/build-qemu.sh"
fi
qemu_edid_help_has_all() {
    local option
    for option in "$@"; do
        [[ "$QEMU_EDID_HELP" == *"$option"* ]] || return 1
    done
}
if qemu_edid_help_has_all \
        --week --year --range-min-v --range-max-v \
        --range-min-h --range-max-h --max-clock; then
    : # Expected G-11 helper and descriptor layout.
elif qemu_edid_help_has_all \
        --manufacture-week --manufacture-year \
        --min-vfreq-hz --max-vfreq-hz \
        --min-hfreq-khz --max-hfreq-khz --max-pixel-clock-mhz; then
    die "$QEMU_EDID 来自其他 QEMU 分支，EDID 布局不符合 G-11；请运行 ./deploy/host/build-qemu.sh"
else
    die "$QEMU_EDID 的参数接口不受支持；请在 G-11 分支运行 ./deploy/host/build-qemu.sh"
fi
unset QEMU_EDID_HELP
case "$DRIVER_POLICY" in
    grid-53833-native)
        [[ "$EXPECTED_DRIVER_VERSION" == 31.0.15.3833 &&
           "$EXPECTED_DRIVER_INF_SHA256" == \
               67a240e1d464cf97dabfec1a7cecf000eaa9ddfd702f32ba2c8771f17905dc2b &&
           "$EXPECTED_DRIVER_CATALOG_SHA256" == \
               56b07bd93280bbda761cb5c9a3a13262c3605320d7286953989e2a5b16d5ec6f ]] || \
            die "GRID 538.33 monitor policy tuple 不在审核目录"
        case "${EXPECTED_NVIDIA_PNP_ID^^}" in
            'PCI\VEN_10DE&DEV_1E30&SUBSYS_132510DE'|\
            'PCI\VEN_10DE&DEV_1E30&SUBSYS_132610DE') ;;
            *) die "GRID 538.33 B/native PnP 不在 1Q/2Q 审核目录" ;;
        esac
        NVIDIA_MODE_POLICY_KIND=locked-grid
        ;;
    nvidia-53758-dch-whql-gtx1050-dell)
        [[ "$EXPECTED_DRIVER_VERSION" == 31.0.15.3758 &&
           "$EXPECTED_DRIVER_INF_SHA256" == \
               c2860e03d30f7ba610f9726765354e75cabb624791aecea61478066d9ead50f1 &&
           "$EXPECTED_DRIVER_CATALOG_SHA256" == \
               08ad09f3b13e78d40b674914178b51090eabf99df3fd1571c7dcbb367d8b430b &&
           "${EXPECTED_NVIDIA_PNP_ID^^}" == \
               'PCI\VEN_10DE&DEV_1C81&SUBSYS_11C01028' ]] || \
            die "GTX 1050 / 537.58 monitor policy tuple 不在审核目录"
        NVIDIA_MODE_POLICY_KIND=edid-only-consumer
        ;;
    nvidia-53758-dch-whql-gtx750ti-asus)
        [[ "$EXPECTED_DRIVER_VERSION" == 31.0.15.3758 &&
           "$EXPECTED_DRIVER_INF_SHA256" == \
               1b7b9f3a5a13a4fec0074bcea8a1dd64336cef228041b1124b8e31d41cded957 &&
           "$EXPECTED_DRIVER_CATALOG_SHA256" == \
               08ad09f3b13e78d40b674914178b51090eabf99df3fd1571c7dcbb367d8b430b &&
           "${EXPECTED_NVIDIA_PNP_ID^^}" == \
               'PCI\VEN_10DE&DEV_1380&SUBSYS_84BB1043' ]] || \
            die "ASUS GTX 750 Ti / 537.58 monitor policy tuple 不在审核目录"
        NVIDIA_MODE_POLICY_KIND=edid-only-consumer
        ;;
    *) die "未知 NVIDIA monitor driver policy: $DRIVER_POLICY" ;;
esac
if [[ -z "$GENERATE_ONLY" ]]; then
    [[ $EUID -eq 0 ]] || die "需要 root（qemu-nbd / mount）。用 sudo 跑。"
    [[ -f "$DISK" ]] || die "找不到 $DISK"
    command -v ntfs-3g.probe >/dev/null 2>&1 || \
        die "找不到 ntfs-3g.probe（请安装 ntfs-3g）"
fi

# ---- guard：实例 VM 不能在运行 ----
if [[ -z "$GENERATE_ONLY" ]] && \
        pgrep -af "qemu-system-x86_64" 2>/dev/null | grep -F -- "$DISK" >/dev/null; then
    die "${INSTANCE_LABEL} 的 QEMU 正在运行——拒绝挂载运行中的实例盘"
fi

# ---- 1) 取得 vGPU vm.conf 选定的目录 key + 持久 serial ----
[[ -n "$MONITOR_PROFILE_KEY" ]] || die "需要 --monitor-profile"
monitor_profile_load "$MONITOR_PROFILE_KEY" || die "未知显示器 profile: $MONITOR_PROFILE_KEY"
if [[ -z "$MONITOR_SERIAL_VALUE" ]]; then
    MONITOR_SERIAL_VALUE=$(monitor_profile_generate_serial \
        "$MONITOR_SERIAL_PREFIX" "$INSTANCE_LABEL-$MONITOR_PROFILE")
elif ! monitor_profile_serial_validate "$MONITOR_SERIAL_VALUE"; then
    die "serial 不符合 ${MONITOR_PROFILE} 的 ${MONITOR_SERIAL_POLICY} 策略或命中证据样本保留值: $MONITOR_SERIAL_VALUE"
fi
log "${INSTANCE_LABEL}: ${MONITOR_DISPLAY_NAME} ${MONITOR_VENDOR}:${MONITOR_PRODUCT_ID} sn=${MONITOR_SERIAL_VALUE} ${MONITOR_WIDTH_MM}x${MONITOR_HEIGHT_MM}mm"

# ---- 2) 生成完整 EDID；metadata 与 QEMU 设备属性使用同一目录 ----
"$QEMU_EDID" -o "$EDID_BIN" \
    -v "$MONITOR_VENDOR" -n "$MONITOR_EDID_NAME" -s "$MONITOR_SERIAL_VALUE" \
    -x "$MONITOR_NATIVE_X" -y "$MONITOR_NATIVE_Y" \
    -X "$MONITOR_NATIVE_X" -Y "$MONITOR_NATIVE_Y" \
    --width-mm "$MONITOR_WIDTH_MM" --height-mm "$MONITOR_HEIGHT_MM" \
    --product-id "$MONITOR_PRODUCT_ID" --week "$MONITOR_WEEK" \
    --year "$MONITOR_YEAR" --video-input "$MONITOR_VIDEO_INPUT" \
    --range-min-v "$MONITOR_MIN_V" --range-max-v "$MONITOR_MAX_V" \
    --range-min-h "$MONITOR_MIN_H" --range-max-h "$MONITOR_MAX_H" \
    --max-clock "$MONITOR_MAX_CLOCK_MHZ" >/dev/null

# G-11/NVIDIA vGPU 的精简 FHD/1K 合同：EDID 与 NV_Modes 使用同一份
# 8 项 R535 page-safe 白名单。standard timing 由这里写入精确白名单；
# Established Timings III 也必须匹配不含 1680x1050/1440x900 的精确位图。
python3 - "$EDID_BIN" "$MONITOR_VENDOR" \
    "$MONITOR_PRODUCT_ID" "$MONITOR_WIDTH_MM" "$MONITOR_HEIGHT_MM" <<'PY'
import sys

path = sys.argv[1]
expected_vendor = sys.argv[2]
expected_product = int(sys.argv[3], 0)
wmm, hmm = int(sys.argv[4]), int(sys.argv[5])


def fail(message):
    raise SystemExit(f'FHD EDID contract violation: {message}')


def require(condition, message):
    if not condition:
        fail(message)


with open(path, 'rb') as stream:
    e = bytearray(stream.read())

require(len(e) == 256, f'expected exactly 256 bytes, got {len(e)}')
require(e[:8] == bytes.fromhex('00ffffffffffff00'), 'invalid EDID header')
require(e[126] == 1, f'expected one extension, got {e[126]}')
checksums = [sum(e[i:i + 128]) & 0xff for i in (0, 128)]
require(checksums == [0, 0], f'invalid input checksums: {checksums}')

raw_vendor = (e[8] << 8) | e[9]
vendor = ''.join(chr(ord('@') + ((raw_vendor >> shift) & 0x1f))
                 for shift in (10, 5, 0))
product = int.from_bytes(e[10:12], 'little')
require(vendor == expected_vendor,
        f'vendor mismatch: {vendor} != {expected_vendor}')
require(product == expected_product,
        f'product mismatch: {product:#06x} != {expected_product:#06x}')
require(e[21:23] == bytes(((wmm + 5) // 10, (hmm + 5) // 10)),
        f'physical size mismatch: {tuple(e[21:23])}')
require(e[35:38] == bytes.fromhex('210800'),
        f'unexpected established timing bitmap: {e[35:38].hex()}')
require(e[38:54] == b'\x01\x01' * 8,
        f'generator emitted unexpected standard timings: {e[38:54].hex()}')


def dtd_mode(offset):
    return (((e[offset + 4] & 0xf0) << 4) | e[offset + 2],
            ((e[offset + 7] & 0xf0) << 4) | e[offset + 5])


base_dtds = []
base_tags = []
for base in (54, 72, 90, 108):
    if e[base] or e[base + 1]:
        base_dtds.append(dtd_mode(base))
    else:
        base_tags.append((base, e[base + 3]))
require(base_dtds == [(1920, 1080)],
        f'base DTDs must be only 1920x1080: {base_dtds}')
require(base_tags == [(72, 0xf7), (90, 0xfd), (108, 0xfc)],
        f'unexpected base descriptor layout: {base_tags}')
xtra3 = bytes(e[72:90])
expected_xtra3 = (b'\x00\x00\x00\xf7\x00\x0a\x00\x4a\x80' +
                  b'\x00' * 9)
require(xtra3 == expected_xtra3,
        f'Established Timings III contains an unexpected mode: {xtra3.hex()}')

cta = e[128:256]
require(cta[0] == 0x02 and cta[1] == 0x03,
        f'expected CTA-861 revision 3, got {cta[:2].hex()}')
require(cta[3] == 0,
        f'unexpected CTA capability/native-DTD flags: {cta[3]:#04x}')
dtd_offset = cta[2]
require(4 <= dtd_offset <= 127,
        f'invalid CTA DTD offset: {dtd_offset}')
blocks = []
cta_vics = []
pos = 4
while pos < dtd_offset:
    header = cta[pos]
    length = header & 0x1f
    end = pos + 1 + length
    require(end <= dtd_offset,
            f'CTA data block at {pos} overruns offset {dtd_offset}')
    tag = header >> 5
    payload = bytes(cta[pos + 1:end])
    blocks.append((tag, payload))
    if tag == 2:
        cta_vics.extend(vic & 0x7f for vic in payload)
    pos = end
require(pos == dtd_offset, 'CTA data-block collection is malformed')
require(blocks == [(2, bytes((16, 4)))],
        f'CTA must contain only VIC 16 and VIC 4: {blocks}')

# With the xtra3 descriptor in the base block, QEMU places the serial text in
# the CTA descriptor collection and pads the rest with 0x10 dummy descriptors.
# Reject every real CTA DTD and every other descriptor type.
pos = dtd_offset
cta_tags = []
while pos + 18 <= 127:
    descriptor = bytes(cta[pos:pos + 18])
    if not any(descriptor):
        break
    require(not descriptor[0] and not descriptor[1],
            f'unexpected CTA DTD at offset {pos}: {descriptor.hex()}')
    tag = descriptor[3]
    cta_tags.append(tag)
    if len(cta_tags) == 1:
        require(tag == 0xff,
                f'expected serial descriptor at CTA offset {pos}, got {tag:#04x}')
    else:
        require(descriptor == b'\x00\x00\x00\x10' + b'\x00' * 14,
                f'unexpected CTA descriptor at offset {pos}: {descriptor.hex()}')
    pos += 18
require(not any(cta[pos:127]),
        'unexpected CTA timing or trailing data')
require(cta_tags and cta_tags[0] == 0xff,
        f'missing CTA serial descriptor: {cta_tags}')

cta_modes_by_vic = {16: (1920, 1080), 4: (1280, 720)}
cta_modes = [cta_modes_by_vic[vic] for vic in cta_vics]
established = [(1024, 768), (640, 480)]
xtra3_modes = [(1360, 768), (1280, 1024), (1280, 960), (1280, 768)]
standard_modes = [(1920, 1080), (1280, 1024), (1280, 720)]
advertised = (set(base_dtds) | set(cta_modes) | set(established) |
              set(xtra3_modes) | set(standard_modes))
expected = {
    (1920, 1080), (1360, 768),
    (1280, 1024), (1280, 960), (1280, 768), (1280, 720),
    (1024, 768), (640, 480),
}
require(advertised == expected,
        f'advertised modes differ: {advertised} != {expected}')
require(not any(x * 10 == y * 16 for x, y in advertised),
        f'16:10 mode detected: {advertised}')


def r535_console_frame_bytes(mode):
    width, height = mode
    pitch = ((width * 4 + 127) // 128) * 128
    return pitch * height


unsafe = {mode: r535_console_frame_bytes(mode) for mode in advertised
          if r535_console_frame_bytes(mode) % 4096}
require(not unsafe,
        f'R535 page-unsafe mode detected: {unsafe}')

# Add only NVIDIA-safe standard timings after the source blob passes every
# structural check.  Aspect values: 3=16:9 and 2=5:4; no 0=16:10 entry exists.
def encode_standard(x, aspect):
    return bytes((x // 8 - 31, aspect << 6))


standard_bytes = b''.join((
    encode_standard(1920, 3),
    encode_standard(1280, 2),
    encode_standard(1280, 3),
)) + b'\x01\x01' * 5
e[38:54] = standard_bytes
# qemu-edid's source blob contains the ordinary 800x600 established bit.
# Clear it only after the input layout has passed validation: NVIDIA R535's
# 800x600 console frame is 0x1d4c00 bytes and triggers the same page-rounding
# mismatch as the observed 1680x1050 -> 1696x1050 failure.
e[35:38] = bytes.fromhex('200800')
e[127] = (-sum(e[:127])) & 0xff
require(e[38:54] == standard_bytes,
        'standard timing whitelist was not written exactly')
require(e[35:38] == bytes.fromhex('200800'),
        'page-unsafe established timing survived output filtering')
checksums = [sum(e[i:i + 128]) & 0xff for i in (0, 128)]
require(checksums == [0, 0], f'output checksums are invalid: {checksums}')
print(f'[disp-cache] EDID: DTD={base_dtds} CTA={cta_modes} '
      f'standard={standard_modes} xtra3={xtra3_modes} '
      f'established={established} checksums={checksums}')
with open(path, 'wb') as stream:
    stream.write(e)
PY
log "EDID blob: $EDID_BIN ($(stat -c%s "$EDID_BIN") bytes)"
if [[ -n "$GENERATE_ONLY" ]]; then
    install -m 0644 "$EDID_BIN" "$GENERATE_ONLY"
    rm -f -- "$EDID_BIN"
    log "仅生成 EDID: $GENERATE_ONLY"
    exit 0
fi

# ---- 3) 通过 NBD 连接实例盘（RW）并挂载 ----
# 并发安全 (P2)：取全局 NBD 锁，串行化所有 host-*.sh 离线工具，防并发抢同一 nbd 设备。
# shellcheck source=../lib/nbd-lock.sh
source "$DEPLOY_ROOT/lib/nbd-lock.sh"
modprobe nbd max_part=16 2>/dev/null || true
_DISPLAY_MOUNTED=0
MOUNT_ERR=""
cleanup() {
    local rc=$? cleanup_rc
    cleanup_rc=$rc
    if [[ "${_DISPLAY_MOUNTED:-0}" == 1 ]]; then
        if umount "$MOUNT" 2>/dev/null; then
            _DISPLAY_MOUNTED=0
        else
            echo "[disp-cache] ERROR: cleanup 无法卸载 $MOUNT" >&2
            cleanup_rc=70
        fi
    fi
    if [[ "${_NBD_CONNECTED:-0}" == 1 && -n "${_NBD_DEV:-}" ]]; then
        if qemu-nbd --disconnect "$_NBD_DEV" >/dev/null 2>&1; then
            _NBD_CONNECTED=0
        else
            echo "[disp-cache] ERROR: cleanup 无法断开 $_NBD_DEV" >&2
            cleanup_rc=70
        fi
    fi
    if [[ -n "${MOUNT_ERR:-}" ]]; then
        rm -f -- "$MOUNT_ERR"
    fi
    rm -f -- "$EDID_BIN"
    rmdir "$MOUNT" 2>/dev/null || true
    exit "$cleanup_rc"
}
trap cleanup EXIT
log "qemu-nbd --connect $NBD $DISK"
nbd_connect NBD "$DISK"   # guard+选盘+connect，置 _NBD_CONNECTED；忙时显式→fail-fast / 默认→自动选盘
sleep 1

SYSPART=""
for p in "${NBD}p3" "${NBD}p4" "${NBD}p2" "${NBD}p1" "${NBD}p5"; do
    [[ -b "$p" ]] || continue
    blkid -o value -s TYPE "$p" 2>/dev/null | grep -q '^ntfs$' || continue
    mkdir -p "$MOUNT"
    if mount -t ntfs-3g -o ro,norecover "$p" "$MOUNT" 2>/dev/null; then
        _DISPLAY_MOUNTED=1
        if [[ -f "$MOUNT/Windows/System32/config/SYSTEM" ]]; then
            if ! umount "$MOUNT"; then
                die "识别到 Windows 分区，但临时只读挂载无法卸载"
            fi
            _DISPLAY_MOUNTED=0
            SYSPART="$p"
            break
        fi
        if ! umount "$MOUNT"; then
            die "临时只读挂载无法卸载: $p"
        fi
        _DISPLAY_MOUNTED=0
    fi
done
[[ -n "$SYSPART" ]] || die "找不到含 Windows 的 NTFS 分区"
log "Windows 系统分区: $SYSPART"

# 自动启动路径绝不修复 NTFS、清 journal 或删除 hiberfil.sys。先做无写入
# 可挂载性探测；休眠卷返回专用状态，让启动器给出标准显卡救援流程。
probe_rc=0
ntfs-3g.probe --readwrite "$SYSPART" || probe_rc=$?
case "$probe_rc" in
    0) ;;
    14)
        log "DEFER: Windows 处于休眠/Fast Startup；保留 hiberfil.sys，不做离线写入"
        exit 11
        ;;
    15)
        die "Windows 卷未干净卸载；拒绝清 journal/dirty flag，请先让 guest 正常启动并完整关机"
        ;;
    *)
        die "NTFS 可写性预检失败（ntfs-3g.probe rc=$probe_rc）"
        ;;
esac

MOUNT_ERR="$(mktemp)"
if ! mount -t ntfs-3g -o rw,norecover "$SYSPART" "$MOUNT" 2>"$MOUNT_ERR"; then
    cat "$MOUNT_ERR" >&2
    die "RW 挂载失败"
fi
_DISPLAY_MOUNTED=1
rm -f -- "$MOUNT_ERR"
MOUNT_ERR=""

HIVE="${MOUNT}/Windows/System32/config/SYSTEM"
[[ -f "$HIVE" ]] || die "SYSTEM hive 不存在"

# ---- 4) REGF/hbin 只读 preflight ----
# Header 0x28 declares the current logical hbin range.  A physical hive file
# may retain reusable stale hbins/zero pages after that boundary; they are not
# part of the active hive and must be preserved rather than scanned, truncated,
# or folded into Length.  Dirty sequence/checksum and a logical chain failure
# are rejected instead of being "fixed" without transaction-log replay.
PYTHONDONTWRITEBYTECODE=1 \
    python3 "$WINDOWS_HIVE_VALIDATOR" "$HIVE" "SYSTEM hive preflight"

# ---- 5) hivex：替换缓存 EDID/可读身份 + NVIDIA source modes + 清配置 ----
MONITOR_PNP="${MONITOR_VENDOR}${MONITOR_PRODUCT_ID#0x}"
monitor_registry_rc=0
set +e
HIVE="$HIVE" EDID_BIN="$EDID_BIN" \
    NVIDIA_MODE_POLICY="$NVIDIA_MODE_POLICY" \
    WINDOWS_INF_DIR="${MOUNT}/Windows/INF" \
    EXPECTED_DRIVER_VERSION="$EXPECTED_DRIVER_VERSION" \
    EXPECTED_DRIVER_INF_SHA256="$EXPECTED_DRIVER_INF_SHA256" \
    EXPECTED_DRIVER_CATALOG_SHA256="$EXPECTED_DRIVER_CATALOG_SHA256" \
    EXPECTED_NVIDIA_PNP_ID="$EXPECTED_NVIDIA_PNP_ID" \
    DRIVER_POLICY="$DRIVER_POLICY" \
    NVIDIA_MODE_POLICY_KIND="$NVIDIA_MODE_POLICY_KIND" \
    MONITOR_NAME="$MONITOR_DISPLAY_NAME" \
    MONITOR_MFG="$MONITOR_MANUFACTURER" MONITOR_PNP="$MONITOR_PNP" \
    python3 - <<'PY'
import hashlib, hivex, os, re, struct, sys

sys.path.insert(0, os.path.dirname(os.environ['NVIDIA_MODE_POLICY']))
from nvidia_modes import (  # noqa: E402
    DISPLAY_ADAPTER_CLASS_GUID,
    FHD_VISIBLE_MODES,
    GRID_53833_DRIVER_VERSION,
    GRID_53833_INF_SHA256,
    NVIDIA_DISPLAY_SERVICE,
    NvidiaModePolicyError,
    decode_reg_multi_sz,
    encode_reg_multi_sz,
    locked_policy_for,
    mode_set,
    validate_policy,
)

HIVE = os.environ['HIVE']
windows_inf_dir = os.environ['WINDOWS_INF_DIR']
expected_driver_version = os.environ['EXPECTED_DRIVER_VERSION']
expected_driver_inf_sha256 = os.environ['EXPECTED_DRIVER_INF_SHA256'].lower()
expected_driver_catalog_sha256 = os.environ['EXPECTED_DRIVER_CATALOG_SHA256'].lower()
expected_nvidia_pnp_id = os.environ['EXPECTED_NVIDIA_PNP_ID']
driver_policy = os.environ['DRIVER_POLICY']
mode_policy_kind = os.environ['NVIDIA_MODE_POLICY_KIND']
allowed_driver_policies = {
    'grid-53833-native': {
        (GRID_53833_DRIVER_VERSION, GRID_53833_INF_SHA256,
         '56b07bd93280bbda761cb5c9a3a13262c3605320d7286953989e2a5b16d5ec6f',
         r'PCI\VEN_10DE&DEV_1E30&SUBSYS_132510DE', 'locked-grid'),
        (GRID_53833_DRIVER_VERSION, GRID_53833_INF_SHA256,
         '56b07bd93280bbda761cb5c9a3a13262c3605320d7286953989e2a5b16d5ec6f',
         r'PCI\VEN_10DE&DEV_1E30&SUBSYS_132610DE', 'locked-grid'),
    },
    'nvidia-53758-dch-whql-gtx1050-dell': {(
        '31.0.15.3758',
        'c2860e03d30f7ba610f9726765354e75cabb624791aecea61478066d9ead50f1',
        '08ad09f3b13e78d40b674914178b51090eabf99df3fd1571c7dcbb367d8b430b',
        r'PCI\VEN_10DE&DEV_1C81&SUBSYS_11C01028', 'edid-only-consumer')},
    'nvidia-53758-dch-whql-gtx750ti-asus': {(
        '31.0.15.3758',
        '1b7b9f3a5a13a4fec0074bcea8a1dd64336cef228041b1124b8e31d41cded957',
        '08ad09f3b13e78d40b674914178b51090eabf99df3fd1571c7dcbb367d8b430b',
        r'PCI\VEN_10DE&DEV_1380&SUBSYS_84BB1043', 'edid-only-consumer')},
}
expected_policy_tuples = allowed_driver_policies.get(driver_policy)
actual_policy_tuple = (
    expected_driver_version, expected_driver_inf_sha256,
    expected_driver_catalog_sha256, expected_nvidia_pnp_id.upper(),
    mode_policy_kind)
if (expected_policy_tuples is None or
        actual_policy_tuple not in expected_policy_tuples):
    raise SystemExit('helper NVIDIA monitor driver policy tuple 不在审核目录')
expected_enum_prefix = expected_nvidia_pnp_id[4:].lower()
edid = open(os.environ['EDID_BIN'], 'rb').read()
monitor_name = os.environ['MONITOR_NAME']
if len(edid) == 0 or len(edid) % 128:
    raise SystemExit(f'EDID 长度必须是非零 128 字节倍数: {len(edid)}')
edid_blocks = [edid[offset:offset + 128]
               for offset in range(0, len(edid), 128)]
if len(edid_blocks) != edid[126] + 1:
    raise SystemExit(
        f'EDID extension count {edid[126]} 与 {len(edid_blocks)} 个 block 不一致')
h = hivex.Hivex(HIVE, write=True)
root = h.root()

def reg_sz(value):
    return value.encode('utf-16le') + b'\x00\x00'

def child(n, name):
    for c in h.node_children(n):
        if h.node_name(c).lower() == name.lower(): return c
    return None
def walk(n, parts):
    for p in parts:
        n = child(n, p)
        if n is None: return None
    return n

def value(n, name):
    for item in h.node_values(n):
        if h.value_key(item).lower() == name.lower():
            return item
    return None

def typed_value(item, expected_type, label):
    # The supported python3-hivex API returns exactly (registry_type, bytes).
    # Reject every other shape instead of guessing which integer might be a
    # type or length.
    result = h.value_value(item)
    if (not isinstance(result, tuple) or len(result) != 2 or
            not isinstance(result[0], int) or isinstance(result[0], bool) or
            not isinstance(result[1], (bytes, bytearray))):
        raise SystemExit(f'{label}: hivex value_value 返回未知结构')
    actual_type, data = result
    if actual_type != expected_type:
        raise SystemExit(
            f'{label}: 注册表类型 {actual_type} != {expected_type}')
    return bytes(data)

def reg_string(n, name):
    item = value(n, name)
    if item is None:
        return None
    data = typed_value(item, 1, name)
    if len(data) < 2 or len(data) % 2:
        raise SystemExit(f'{name}: REG_SZ 字节长度非法')
    try:
        text = data.decode('utf-16le')
    except UnicodeDecodeError as exc:
        raise SystemExit(f'{name}: REG_SZ 不是有效 UTF-16LE: {exc}')
    if not text.endswith('\x00') or '\x00' in text[:-1]:
        raise SystemExit(f'{name}: REG_SZ 终止符非法')
    return text[:-1]

def reg_dword(n, name, required=True):
    item = value(n, name)
    if item is None:
        if required:
            raise SystemExit(f'缺少 DWORD 注册表值: {name}')
        return None
    data = typed_value(item, 4, name)
    if len(data) != 4:
        raise SystemExit(f'{name}: REG_DWORD 长度 {len(data)} != 4')
    return struct.unpack('<I', data)[0]

inf_hash_cache = {}

def verify_driver_package(target, label):
    provider = reg_string(target, 'ProviderName')
    version = reg_string(target, 'DriverVersion')
    inf_path = reg_string(target, 'InfPath')
    if provider is None or re.fullmatch(
            r'NVIDIA(?: Corporation)?', provider, re.IGNORECASE) is None:
        raise SystemExit(f'{label}: ProviderName 不是 NVIDIA: {provider!r}')
    if version != expected_driver_version:
        raise SystemExit(
            f'{label}: DriverVersion {version!r} != {expected_driver_version!r}')
    if inf_path is None or re.fullmatch(
            r'oem(?:0|[1-9][0-9]*)\.inf', inf_path) is None:
        raise SystemExit(f'{label}: InfPath 不是已发布 oemN.inf: {inf_path!r}')

    key = inf_path.lower()
    if key not in inf_hash_cache:
        try:
            matches = [entry for entry in os.scandir(windows_inf_dir)
                       if entry.name.lower() == key]
        except OSError as exc:
            raise SystemExit(f'{label}: 无法读取 Windows INF 目录: {exc}')
        if len(matches) != 1 or not matches[0].is_file(follow_symlinks=False):
            raise SystemExit(
                f'{label}: Windows INF 中无法唯一定位普通文件 {inf_path!r}')
        digest = hashlib.sha256()
        with open(matches[0].path, 'rb') as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                digest.update(chunk)
        inf_hash_cache[key] = digest.hexdigest()
    actual_hash = inf_hash_cache[key]
    if actual_hash != expected_driver_inf_sha256:
        raise SystemExit(
            f'{label}: {inf_path} SHA-256 {actual_hash} 不是锁定生产 INF')
    print(f'  {label}: {driver_policy} {version} / {inf_path} '
          '生产 INF 哈希验证通过')

def nvidia_driver_targets(cs):
    """Resolve the fixed G-11 B/native DIREG_DRV relation through Enum\\PCI.

    A completed A -> B migration can legitimately leave the old consumer-ID
    Enum node behind as history.  It is not the device QEMU currently exposes,
    so never authenticate or rewrite its software key.
    """
    pci = walk(root, [cs, 'Enum', 'PCI'])
    if pci is None:
        return []
    targets = {}
    for device in h.node_children(pci):
        device_name = h.node_name(device)
        if not device_name.lower().startswith('ven_10de&'):
            continue
        device_name_lower = device_name.lower()
        expected_device = (
            device_name_lower == expected_enum_prefix or
            device_name_lower.startswith(expected_enum_prefix + '&'))
        for instance in h.node_children(device):
            service = reg_string(instance, 'Service')
            if service is None or service.lower() != NVIDIA_DISPLAY_SERVICE:
                continue
            if not expected_device:
                print(f'  {cs}\\Enum\\PCI\\{device_name}: '
                      '跳过 legacy/非当前 B-native NVIDIA PnP 残留')
                continue
            driver = reg_string(instance, 'Driver')
            class_guid = reg_string(instance, 'ClassGUID')
            if class_guid is not None and class_guid.lower() != DISPLAY_ADAPTER_CLASS_GUID:
                raise SystemExit(
                    f'{cs}\\Enum\\PCI\\{device_name}: NVIDIA display ClassGUID '
                    f'异常: {class_guid}')
            match = re.fullmatch(
                re.escape(DISPLAY_ADAPTER_CLASS_GUID) + r'\\(\d{4})',
                driver or '', re.IGNORECASE)
            if match is None:
                raise SystemExit(
                    f'{cs}\\Enum\\PCI\\{device_name}: nvlddmkm Driver 关系异常: '
                    f'{driver!r}')
            target = walk(root, [cs, 'Control', 'Class',
                                 DISPLAY_ADAPTER_CLASS_GUID, match.group(1)])
            if target is None:
                raise SystemExit(
                    f'{cs}\\Control\\Class\\{driver} 不存在')
            label = (f'{cs}\\Control\\Class\\{DISPLAY_ADAPTER_CLASS_GUID}\\'
                     f'{match.group(1)}')
            verify_driver_package(target, label)
            targets[label.lower()] = (target, label)
    return list(targets.values())

# 只同步 Select 明确指向的 Current / Default / LastKnownGood。不全扫
# 孤立旧 ControlSet，也不允许不同 ControlSet 的 EDID/NVIDIA 命中拼成成功。
cset_names = {}
for node in h.node_children(root):
    name = h.node_name(node)
    if re.fullmatch(r'ControlSet[0-9]{3}', name, re.IGNORECASE) is None:
        continue
    key = name.lower()
    if key in cset_names:
        raise SystemExit(f'SYSTEM hive 有重复 ControlSet 名称: {name}')
    cset_names[key] = name
if not cset_names:
    raise SystemExit('SYSTEM hive 没有规范 ControlSetNNN')

select = walk(root, ['Select'])
if select is None:
    raise SystemExit('SYSTEM hive 缺少 Select key，无法确定活动 ControlSet')

selected = []
current_name = None
for select_value, required in (('Current', True), ('Default', False),
                               ('LastKnownGood', False)):
    number = reg_dword(select, select_value, required=required)
    if number is None:
        continue
    if not 1 <= number <= 999:
        raise SystemExit(f'Select\\{select_value} 超出 1..999: {number}')
    requested = f'ControlSet{number:03d}'
    actual = cset_names.get(requested.lower())
    if actual is None:
        raise SystemExit(
            f'Select\\{select_value} 指向不存在的 {requested}')
    if select_value == 'Current':
        current_name = actual
    if actual.lower() not in {name.lower() for name in selected}:
        selected.append(actual)
if current_name is None:
    raise SystemExit('Select\\Current 未解析')
csets = selected
print('[disp-cache] selected ControlSets:', csets)
print('[disp-cache] Select\\Current:', current_name)

edid_writes = 0
override_writes = 0
cfg_deletes = 0
nvidia_devices = 0
nvidia_writes = 0
control_set_stats = {
    cs.lower(): {'edid': 0, 'override': 0, 'nvidia': 0} for cs in csets
}
for cs in csets:
    # 5a) 每个已缓存 EDID 的 Enum\DISPLAY 实例同时更新 raw
    # EDID 和 Microsoft 标准 EDID_OVERRIDE。Override 必须按 128-byte
    # block 分别存在名为 0, 1, ... 的 REG_BINARY 值中；整个 256B
    # blob 写成单一值不会形成合法的 Windows EDID override。
    disp = walk(root, [cs, 'Enum', 'DISPLAY'])
    if disp:
        for pnp in h.node_children(disp):
            for inst in h.node_children(pnp):
                dp = child(inst, 'Device Parameters')
                if dp is None: continue
                # 仅当本就缓存过 EDID 才替换（避免给无关节点塞 EDID）
                has = any(h.value_key(v).lower() == 'edid' for v in h.node_values(dp))
                if has:
                    h.node_set_value(dp, {'key': 'EDID', 't': 3, 'value': edid})
                    old_override = child(dp, 'EDID_OVERRIDE')
                    if old_override is not None:
                        # Recreate only this target-scoped child so stale blocks from a
                        # previous 3/4-block EDID cannot survive a shorter profile.
                        h.node_delete_child(old_override)
                    override = h.node_add_child(dp, 'EDID_OVERRIDE')
                    for block_number, block in enumerate(edid_blocks):
                        h.node_set_value(override, {
                            'key': str(block_number), 't': 3, 'value': block,
                        })
                    written_names = {
                        h.value_key(item) for item in h.node_values(override)
                    }
                    expected_names = {
                        str(number) for number in range(len(edid_blocks))
                    }
                    if written_names != expected_names:
                        raise SystemExit(
                            f'{cs}\\...\\{h.node_name(pnp)}\\{h.node_name(inst)}: '
                            'EDID_OVERRIDE block 名称写后校验失败')
                    for block_number, block in enumerate(edid_blocks):
                        written_block = typed_value(
                            value(override, str(block_number)), 3,
                            f'EDID_OVERRIDE\\{block_number}')
                        if written_block != block:
                            raise SystemExit(
                                f'{cs}\\...\\{h.node_name(pnp)}\\{h.node_name(inst)}: '
                                f'EDID_OVERRIDE\\{block_number} 写后校验失败')
                    # DeviceDesc/Manufacturer/HardwareID are owned by PnP and
                    # the signed monitor driver.  Rewriting them offline is
                    # overwritten at enumeration and can make the Enum tree
                    # internally inconsistent.  FriendlyName is the one
                    # documented writable identity property; the guest
                    # coordinator republishes it through SetupAPI once the
                    # devnode is live.
                    h.node_set_value(inst, {'key': 'FriendlyName', 't': 1,
                                           'value': reg_sz(monitor_name)})
                    edid_writes += 1
                    override_writes += 1
                    control_set_stats[cs.lower()]['edid'] += 1
                    control_set_stats[cs.lower()]['override'] += 1
                    print(f'  {cs}\\...\\{h.node_name(pnp)}\\{h.node_name(inst)}: '
                          f'EDID + EDID_OVERRIDE 替换 '
                          f'({len(edid)}B / {len(edid_blocks)} blocks)')

    # 5b) NVIDIA 的生产 INF 会用 NV_Modes 扩展 source modes，因此将其锁定为
    # EDID 同一份 8 项 page-safe 合同。只沿固定 B/native PnP 的 Enum\\PCI Driver 关系改当前
    # software key；旧 A
    # consumer-ID Enum 历史明确跳过。当前目标的未知驱动值仍失败关闭，绝不
    # 全扫 Class、删除 NV_Modes 或改 NV_R&T。
    for target, label in nvidia_driver_targets(cs):
        nvidia_devices += 1
        control_set_stats[cs.lower()]['nvidia'] += 1
        if mode_policy_kind == 'edid-only-consumer':
            print(f'  {label}: 消费级驱动私有 NV_Modes 保持原样；'
                  '仅发布标准 EDID/EDID_OVERRIDE')
            continue
        item = value(target, 'NV_Modes')
        if item is None:
            raise SystemExit(f'{label}: 已绑定 nvlddmkm 但缺少 NV_Modes')
        try:
            current = decode_reg_multi_sz(typed_value(item, 7, f'{label}\\NV_Modes'))
            policy, changed = locked_policy_for(current)
        except NvidiaModePolicyError as exc:
            raise SystemExit(f'{label}: 拒绝覆盖未知 NV_Modes: {exc}')
        if changed:
            h.node_set_value(target, {
                'key': 'NV_Modes', 't': 7,
                'value': encode_reg_multi_sz(policy),
            })
            nvidia_writes += 1
        # Read the value back from hivex's updated node and validate exact modes.
        try:
            written = decode_reg_multi_sz(typed_value(
                value(target, 'NV_Modes'), 7, f'{label}\\NV_Modes'))
            validate_policy(written)
        except NvidiaModePolicyError as exc:
            raise SystemExit(f'{label}: NV_Modes 写后校验失败: {exc}')
        if mode_set(written) != FHD_VISIBLE_MODES:
            raise SystemExit(f'{label}: NV_Modes 最终列表不完整')
        action = '写入' if changed else '已符合'
        print(f'  {label}: NV_Modes {action} {len(FHD_VISIBLE_MODES)} 个 '
              'R535 page-safe、EDID 对齐的 FHD/1K PC 模式')

    # 5c) 清 GraphicsDrivers\Configuration / Connectivity 子键
    for sub in ('Configuration', 'Connectivity', 'ScaleFactors', 'MonitorDataStore'):
        gd = walk(root, [cs, 'Control', 'GraphicsDrivers', sub])
        if gd:
            kids = list(h.node_children(gd))
            for k in kids:
                h.node_delete_child(k)
                cfg_deletes += 1
            if kids:
                print(f'  {cs}\\Control\\GraphicsDrivers\\{sub}: 删 {len(kids)} 子键')

print(f'[disp-cache] EDID 替换 {edid_writes} 处, '
      f'EDID_OVERRIDE 写入 {override_writes} 处, '
      f'NVIDIA NV_Modes 命中 {nvidia_devices} / 写 {nvidia_writes} 处, '
      f'模式配置删 {cfg_deletes} 子键')
current_stats = control_set_stats[current_name.lower()]
if current_stats['edid'] == 0:
    if current_stats['nvidia'] == 0:
        print(f'[disp-cache] FIRST-DRIVER: {current_name} 同时没有缓存 EDID 和已绑定 '
              'nvlddmkm；必须使用隔离 NVIDIA console 的 driver-install 模式')
        raise SystemExit(13)
    print(f'[disp-cache] WAIT: {current_name} 没找到缓存 EDID；'
          '已认证生产 NVIDIA 驱动，guest 需要先正常枚举一次显示器')
    raise SystemExit(10)
if current_stats['override'] != current_stats['edid']:
    raise SystemExit(
        f'{current_name} EDID_OVERRIDE 写入数 '
        f"{current_stats['override']} != EDID 命中数 {current_stats['edid']}")
if current_stats['nvidia'] == 0:
    # A freshly installed Windows image has a real monitor cache before the
    # NVIDIA software key exists.  Committing the reviewed EDID and deleting
    # stale GraphicsDrivers caches here closes the first-driver-install gap;
    # NV_Modes remains deliberately pending until a signed GRID target can be
    # authenticated after a full shutdown.
    h.commit(None)
    del h
    print('[disp-cache] hivex pre-driver commit 完成：安全 EDID/缓存已落盘，NV_Modes 待驱动安装后认证')
    raise SystemExit(12)
h.commit(None)
del h
print('[disp-cache] hivex full commit 完成')
PY
monitor_registry_rc=$?
set -e
case "$monitor_registry_rc" in
    0)  MONITOR_COMMIT_STATE=full ;;
    12) MONITOR_COMMIT_STATE=predriver ;;
    *)  exit "$monitor_registry_rc" ;;
esac

# ---- 6) hivex commit 后只读验证 ----
# hivex owns the transaction.  Do not conceal an incomplete commit by syncing
# sequence numbers or rewriting Length/checksum afterward.
PYTHONDONTWRITEBYTECODE=1 \
    python3 "$WINDOWS_HIVE_VALIDATOR" "$HIVE" "SYSTEM hive post-commit"

sync

# 标记完成之前必须确认 NTFS 已卸载、NBD 已断开。否则 start-vm.sh 可能在
# 实例盘仍被 host 挂载时启动 QEMU，造成双写损坏。
if ! umount "$MOUNT"; then
    die "SYSTEM hive 已写入，但 NTFS 卸载失败；不会写同步标记或启动 VM"
fi
_DISPLAY_MOUNTED=0
if [[ "${_NBD_CONNECTED:-0}" == 1 && -n "${_NBD_DEV:-}" ]]; then
    if ! qemu-nbd --disconnect "$_NBD_DEV" >/dev/null; then
        die "NTFS 已卸载，但 NBD 断开失败；不会写同步标记或启动 VM"
    fi
    _NBD_CONNECTED=0
fi
if [[ -n "$MARKER" ]]; then
    [[ -n "$MARKER_VALUE" ]] || die "--marker 需要同时指定 --marker-value"
    mkdir -p "$(dirname "$MARKER")"
    marker_tmp="${MARKER}.tmp.$$"
    if [[ "$MONITOR_COMMIT_STATE" == predriver ]]; then
        printf 'g11-r535-predriver-v1:%s\n' "$MARKER_VALUE" >"$marker_tmp"
    else
        printf '%s\n' "$MARKER_VALUE" >"$marker_tmp"
    fi
    chmod 0644 "$marker_tmp"
    mv -f -- "$marker_tmp" "$MARKER"
fi
if [[ "$MONITOR_COMMIT_STATE" == predriver ]]; then
    log "PRE-DRIVER：已提交 ${MONITOR_DISPLAY_NAME} 的安全 EDID/EDID_OVERRIDE 并清理模式缓存；生产 NV_Modes 将在驱动安装后完整关机时认证写入。"
    exit 12
fi
log "完成 Windows 离线 EDID/EDID_OVERRIDE/模式缓存：${MONITOR_DISPLAY_NAME}；此 host 命令不直接修改 live PnP 名称。"
