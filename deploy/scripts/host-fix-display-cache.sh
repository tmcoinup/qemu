#!/bin/bash
# host-fix-display-cache.sh — 离线刷新某个 stealth VM 的显示器 EDID/模式缓存
#
# 背景：
#   Windows 把显示器 EDID 缓存在
#     HKLM\SYSTEM\CurrentControlSet\Enum\DISPLAY\<PNP>\<inst>\Device Parameters\EDID
#   分辨率下拉就是从这份【缓存的 EDID】解析出来的。stock viogpudo 不会在每次
#   开机时把设备的实时 EDID 重新喂给 Windows，所以即便 QEMU 端 edid-generate.c
#   改了，旧 guest（以及从旧 base 克隆出来的实例）仍显示缓存里的老分辨率集。
#   GraphicsDrivers\Configuration / Connectivity 还会按显示器签名缓存"已验证
#   模式表"，同样会拖着旧分辨率。
#
#   本脚本离线地：
#     1) 按实例 profile 重新生成与设备完全一致的【正常 1080p 列表】EDID
#        （qemu-edid 接收完整组件字段），写进每个 Enum\DISPLAY 实例的
#        Device Parameters\EDID；
#     2) 清空 GraphicsDrivers\Configuration / Connectivity 的子键（含跨厂商
#        残留，如 DEL0F65），让 Windows 下次开机从新 EDID 重建模式表。
#
# 用法：
#   sudo deploy/scripts/host-fix-display-cache.sh <实例号>      # 默认 2
#   NBD=/dev/nbd5 sudo deploy/scripts/host-fix-display-cache.sh 2
#
# 安全：
#   - 只动 vms/<N>/disk.qcow2（overlay 增量盘），不碰只读 base。
#   - 若该实例的 QEMU 进程在跑，直接拒绝（挂载运行中的 overlay 必损坏）。
#
# 依赖：qemu-utils(qemu-nbd) + ntfs-3g + python3-hivex
set -u -o pipefail

INSTANCE="${1:-2}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VMDIR="/home/ubuntu/images/vms/${INSTANCE}"
DISK="${VMDIR}/disk.qcow2"
PROFILE="${VMDIR}/profile"
QEMU_EDID="${REPO_ROOT}/build/qemu-edid"
_NBD_PINNED="${NBD:+1}"   # 记录用户是否显式指定 NBD（忙时决定 fail-fast vs 自动选盘）
NBD="${NBD:-/dev/nbd0}"
MOUNT="/tmp/winmnt-disp-${INSTANCE}"
EDID_BIN="/tmp/stealth-edid-${INSTANCE}.bin"

log() { echo "[disp-cache] $*"; }
die() { echo "[disp-cache] ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "需要 root（qemu-nbd / mount）。用 sudo 跑。"
# root 必须锁住最终 VM 用户与 start/stop 共用的实例锁，不能落到 UID 0 的
# /run/user/0。锁在首次读取 disk/profile 前取得，并由 FD 8 持有到 EXIT cleanup
# 完成，避免 start/stop 与离线 RW 挂载交错。
# shellcheck source=lib/host-display-cache-guard.sh
source "$SCRIPT_DIR/lib/host-display-cache-guard.sh"
host_display_cache_acquire_instance_lock \
    "$INSTANCE" "$VMDIR" "$SCRIPT_DIR/lib/sv-instance-lock.sh" \
    "$SCRIPT_DIR/lib/clone-lifecycle.sh" ||
    die "无法取得最终 VM 用户的实例生命周期锁"
log "已锁定实例 ${INSTANCE}（VM 用户: $HOST_DISPLAY_VM_USER）"

[[ -f "$DISK" && ! -L "$DISK" ]] || die "找不到安全的普通磁盘文件 $DISK"
[[ -f "$PROFILE" && ! -L "$PROFILE" ]] ||
    die "找不到安全的普通 profile $PROFILE"
[[ -x "$QEMU_EDID" ]] || die "找不到 $QEMU_EDID（先 ninja -C build qemu-edid）"

# ---- guard：取得生命周期锁后复核实例 VM 未运行 ----
if pgrep -af "qemu-system-x86_64" 2>/dev/null | grep -q "vms/${INSTANCE}/disk.qcow2"; then
    die "实例 ${INSTANCE} 的 QEMU 正在运行——挂载它的 overlay 会损坏磁盘。先 stop-vm.sh ${INSTANCE}。"
fi

# ---- 1) 读 profile 的 EDID 参数 ----
# 安全解析（P1#2）：不再 `eval grep`（被篡改的 profile 会执行任意 shell 代码），
# 改用白名单单字段读取，并按稳定组件 ID 回查目录，避免扩池后把旧 profile
# 默认为目录中的第一款显示器。
source "$SCRIPT_DIR/lib/stealth-profile-io.sh"
PROFILE_HASH_BEFORE="$(stealth_profile_sha256 "$PROFILE")" ||
    die "无法计算 profile 初始 SHA256"
EDID_COMPONENT_ID="$(stealth_profile_get EDID_COMPONENT_ID "$PROFILE" || true)"
EDID_VENDOR="$(stealth_profile_get EDID_VENDOR "$PROFILE" || true)"
EDID_NAME="$(stealth_profile_get EDID_NAME "$PROFILE" || true)"
EDID_SERIAL="$(stealth_profile_get EDID_SERIAL "$PROFILE" || true)"
EDID_WIDTH_MM="$(stealth_profile_get EDID_WIDTH_MM "$PROFILE" || true)"
EDID_HEIGHT_MM="$(stealth_profile_get EDID_HEIGHT_MM "$PROFILE" || true)"
EDID_BINARY_SERIAL="$(stealth_profile_get EDID_BINARY_SERIAL "$PROFILE" || true)"
EDID_REVISION="$(stealth_profile_get EDID_REVISION "$PROFILE" || true)"
EDID_PRODUCT_ID="$(stealth_profile_get EDID_PRODUCT_ID "$PROFILE" || true)"
EDID_MANUFACTURE_WEEK="$(
    stealth_profile_get EDID_MANUFACTURE_WEEK "$PROFILE" || true
)"
EDID_MANUFACTURE_YEAR="$(
    stealth_profile_get EDID_MANUFACTURE_YEAR "$PROFILE" || true
)"
EDID_VIDEO_INPUT="$(stealth_profile_get EDID_VIDEO_INPUT "$PROFILE" || true)"
EDID_MIN_VFREQ_HZ="$(stealth_profile_get EDID_MIN_VFREQ_HZ "$PROFILE" || true)"
EDID_MAX_VFREQ_HZ="$(stealth_profile_get EDID_MAX_VFREQ_HZ "$PROFILE" || true)"
EDID_MIN_HFREQ_KHZ="$(stealth_profile_get EDID_MIN_HFREQ_KHZ "$PROFILE" || true)"
EDID_MAX_HFREQ_KHZ="$(stealth_profile_get EDID_MAX_HFREQ_KHZ "$PROFILE" || true)"
EDID_MAX_PIXEL_CLOCK_MHZ="$(
    stealth_profile_get EDID_MAX_PIXEL_CLOCK_MHZ "$PROFILE" || true
)"
EDID_SECONDARY_XRES="$(
    stealth_profile_get EDID_SECONDARY_XRES "$PROFILE" || true
)"
EDID_SECONDARY_YRES="$(
    stealth_profile_get EDID_SECONDARY_YRES "$PROFILE" || true
)"
EDID_SECONDARY_REFRESH_RATE="$(
    stealth_profile_get EDID_SECONDARY_REFRESH_RATE "$PROFILE" || true
)"
EDID_SECONDARY_PIXEL_CLOCK_KHZ="$(
    stealth_profile_get EDID_SECONDARY_PIXEL_CLOCK_KHZ "$PROFILE" || true
)"
EDID_SECONDARY_HFRONT="$(
    stealth_profile_get EDID_SECONDARY_HFRONT "$PROFILE" || true
)"
EDID_SECONDARY_HSYNC="$(
    stealth_profile_get EDID_SECONDARY_HSYNC "$PROFILE" || true
)"
EDID_SECONDARY_HBLANK="$(
    stealth_profile_get EDID_SECONDARY_HBLANK "$PROFILE" || true
)"
EDID_SECONDARY_VFRONT="$(
    stealth_profile_get EDID_SECONDARY_VFRONT "$PROFILE" || true
)"
EDID_SECONDARY_VSYNC="$(
    stealth_profile_get EDID_SECONDARY_VSYNC "$PROFILE" || true
)"
EDID_SECONDARY_VBLANK="$(
    stealth_profile_get EDID_SECONDARY_VBLANK "$PROFILE" || true
)"
EDID_SECONDARY_HSYNC_POSITIVE="$(
    stealth_profile_get EDID_SECONDARY_HSYNC_POSITIVE "$PROFILE" || true
)"
EDID_SECONDARY_VSYNC_POSITIVE="$(
    stealth_profile_get EDID_SECONDARY_VSYNC_POSITIVE "$PROFILE" || true
)"
EDID_SECONDARY_WIDTH_MM="$(
    stealth_profile_get EDID_SECONDARY_WIDTH_MM "$PROFILE" || true
)"
EDID_SECONDARY_HEIGHT_MM="$(
    stealth_profile_get EDID_SECONDARY_HEIGHT_MM "$PROFILE" || true
)"
MONITOR_ROW="$(stealth_component_monitor_row "$EDID_COMPONENT_ID" 2>/dev/null)" ||
    die "profile 的显示器稳定 ID 不在受控组件目录中"
IFS='|' read -r _ EXPECTED_VENDOR EXPECTED_NAME EXPECTED_WIDTH_MM \
    EXPECTED_HEIGHT_MM _ EXPECTED_PRODUCT_ID EXPECTED_WEEK EXPECTED_YEAR \
    EXPECTED_VIDEO_INPUT EXPECTED_MIN_VFREQ EXPECTED_MAX_VFREQ \
    EXPECTED_MIN_HFREQ EXPECTED_MAX_HFREQ EXPECTED_MAX_PIXEL_CLOCK \
    EXPECTED_SECONDARY_X EXPECTED_SECONDARY_Y EXPECTED_SECONDARY_REFRESH \
    <<<"$MONITOR_ROW"
[[ "$EDID_VENDOR" == "$EXPECTED_VENDOR" &&
   "$EDID_NAME" == "$EXPECTED_NAME" &&
   "$EDID_WIDTH_MM" == "$EXPECTED_WIDTH_MM" &&
   "$EDID_HEIGHT_MM" == "$EXPECTED_HEIGHT_MM" &&
   "$EDID_PRODUCT_ID" == "$EXPECTED_PRODUCT_ID" &&
   "$EDID_MANUFACTURE_WEEK" == "$EXPECTED_WEEK" &&
   "$EDID_MANUFACTURE_YEAR" == "$EXPECTED_YEAR" &&
   "$EDID_VIDEO_INPUT" == "$EXPECTED_VIDEO_INPUT" &&
   "$EDID_MIN_VFREQ_HZ" == "$EXPECTED_MIN_VFREQ" &&
   "$EDID_MAX_VFREQ_HZ" == "$EXPECTED_MAX_VFREQ" &&
   "$EDID_MIN_HFREQ_KHZ" == "$EXPECTED_MIN_HFREQ" &&
   "$EDID_MAX_HFREQ_KHZ" == "$EXPECTED_MAX_HFREQ" &&
   "$EDID_MAX_PIXEL_CLOCK_MHZ" == "$EXPECTED_MAX_PIXEL_CLOCK" &&
   "$EDID_SECONDARY_XRES" == "$EXPECTED_SECONDARY_X" &&
   "$EDID_SECONDARY_YRES" == "$EXPECTED_SECONDARY_Y" &&
   "$EDID_SECONDARY_REFRESH_RATE" == "$EXPECTED_SECONDARY_REFRESH" ]] &&
    stealth_component_monitor_serial_is_valid \
        "$EDID_COMPONENT_ID" "$EDID_SERIAL" >/dev/null 2>&1 ||
    die "profile 的显示器 EDID 身份与受控组件目录不一致"
EXPECTED_BINARY_SERIAL="$(
    stealth_component_monitor_binary_serial \
        "$EDID_COMPONENT_ID" "$EDID_SERIAL"
)" || die "profile 的文本序列号无法映射到品牌绑定的 EDID binary serial"
EXPECTED_REVISION="$(stealth_component_monitor_revision "$EDID_COMPONENT_ID")" ||
    die "profile 的显示器 EDID revision 不在受控组件目录中"
EXPECTED_SECONDARY_DETAIL="$(
    stealth_component_monitor_secondary_detail "$EDID_COMPONENT_ID"
)" || die "profile 的显示器次要 DTD 细节不在受控组件目录中"
IFS='|' read -r EXPECTED_SECONDARY_CLOCK EXPECTED_SECONDARY_HFRONT \
    EXPECTED_SECONDARY_HSYNC EXPECTED_SECONDARY_HBLANK \
    EXPECTED_SECONDARY_VFRONT EXPECTED_SECONDARY_VSYNC \
    EXPECTED_SECONDARY_VBLANK EXPECTED_SECONDARY_HSYNC_POSITIVE \
    EXPECTED_SECONDARY_VSYNC_POSITIVE EXPECTED_SECONDARY_WIDTH_MM \
    EXPECTED_SECONDARY_HEIGHT_MM <<<"$EXPECTED_SECONDARY_DETAIL"
[[ "$EDID_BINARY_SERIAL" == "$EXPECTED_BINARY_SERIAL" &&
   "$EDID_REVISION" == "$EXPECTED_REVISION" &&
   "$EDID_SECONDARY_PIXEL_CLOCK_KHZ" == "$EXPECTED_SECONDARY_CLOCK" &&
   "$EDID_SECONDARY_HFRONT" == "$EXPECTED_SECONDARY_HFRONT" &&
   "$EDID_SECONDARY_HSYNC" == "$EXPECTED_SECONDARY_HSYNC" &&
   "$EDID_SECONDARY_HBLANK" == "$EXPECTED_SECONDARY_HBLANK" &&
   "$EDID_SECONDARY_VFRONT" == "$EXPECTED_SECONDARY_VFRONT" &&
   "$EDID_SECONDARY_VSYNC" == "$EXPECTED_SECONDARY_VSYNC" &&
   "$EDID_SECONDARY_VBLANK" == "$EXPECTED_SECONDARY_VBLANK" &&
   "$EDID_SECONDARY_HSYNC_POSITIVE" == "$EXPECTED_SECONDARY_HSYNC_POSITIVE" &&
   "$EDID_SECONDARY_VSYNC_POSITIVE" == "$EXPECTED_SECONDARY_VSYNC_POSITIVE" &&
   "$EDID_SECONDARY_WIDTH_MM" == "$EXPECTED_SECONDARY_WIDTH_MM" &&
   "$EDID_SECONDARY_HEIGHT_MM" == "$EXPECTED_SECONDARY_HEIGHT_MM" ]] ||
    die "profile 的显示器 binary serial/revision/DTD 与受控目录不一致"
log "实例 ${INSTANCE} 显示器: ${EDID_VENDOR} ${EDID_NAME} sn=${EDID_SERIAL} ${EDID_WIDTH_MM}x${EDID_HEIGHT_MM}mm"

# ---- 2) 生成与设备一致的 16:9 EDID（qemu-edid 用当前 edid-generate.c）----
# 离线缓存修复必须传入与 virtio-vga 启动参数相同的完整组件事实，不能只改品牌
# 字符串后让非 Samsung 型号继承 qemu-edid 的通用默认产品码、日期或扫描范围。
# 先删除同实例的旧临时文件；生成或深层校验任一步失败都必须停止，绝不能把
# 上一次运行残留的 EDID 写回 guest。
rm -f -- "$EDID_BIN" || die "无法清理旧 EDID 临时文件: $EDID_BIN"
"$QEMU_EDID" -o "$EDID_BIN" -v "$EDID_VENDOR" -n "$EDID_NAME" -s "$EDID_SERIAL" \
    -x 1920 -y 1080 -X 1920 -Y 1080 \
    --width-mm "$EDID_WIDTH_MM" --height-mm "$EDID_HEIGHT_MM" \
    --product-id "$EXPECTED_PRODUCT_ID" \
    --binary-serial "$EXPECTED_BINARY_SERIAL" \
    --revision "$EXPECTED_REVISION" \
    --manufacture-week "$EXPECTED_WEEK" --manufacture-year "$EXPECTED_YEAR" \
    --video-input "$EXPECTED_VIDEO_INPUT" \
    --min-vfreq-hz "$EXPECTED_MIN_VFREQ" \
    --max-vfreq-hz "$EXPECTED_MAX_VFREQ" \
    --min-hfreq-khz "$EXPECTED_MIN_HFREQ" \
    --max-hfreq-khz "$EXPECTED_MAX_HFREQ" \
    --max-pixel-clock-mhz "$EXPECTED_MAX_PIXEL_CLOCK" \
    --secondary-xres "$EXPECTED_SECONDARY_X" \
    --secondary-yres "$EXPECTED_SECONDARY_Y" \
    --secondary-refresh-rate "$EXPECTED_SECONDARY_REFRESH" >/dev/null ||
    die "qemu-edid 生成显示器 EDID 失败"
python3 - "$EDID_BIN" "$EDID_VENDOR" "$EDID_NAME" "$EDID_SERIAL" \
    "$EDID_WIDTH_MM" "$EDID_HEIGHT_MM" "$EXPECTED_PRODUCT_ID" \
    "$EXPECTED_WEEK" "$EXPECTED_YEAR" "$EXPECTED_VIDEO_INPUT" \
    "$EXPECTED_MIN_VFREQ" "$EXPECTED_MAX_VFREQ" \
    "$EXPECTED_MIN_HFREQ" "$EXPECTED_MAX_HFREQ" \
    "$EXPECTED_MAX_PIXEL_CLOCK" "$EXPECTED_SECONDARY_X" \
    "$EXPECTED_SECONDARY_Y" "$EXPECTED_BINARY_SERIAL" \
    "$EXPECTED_REVISION" "$EXPECTED_SECONDARY_CLOCK" \
    "$EXPECTED_SECONDARY_HFRONT" "$EXPECTED_SECONDARY_HSYNC" \
    "$EXPECTED_SECONDARY_HBLANK" "$EXPECTED_SECONDARY_VFRONT" \
    "$EXPECTED_SECONDARY_VSYNC" "$EXPECTED_SECONDARY_VBLANK" \
    "$EXPECTED_SECONDARY_HSYNC_POSITIVE" \
    "$EXPECTED_SECONDARY_VSYNC_POSITIVE" \
    "$EXPECTED_SECONDARY_WIDTH_MM" "$EXPECTED_SECONDARY_HEIGHT_MM" \
    <<'PY' || die "生成的显示器 EDID 未通过深层字段校验"
import sys
path, vendor, name, serial = sys.argv[1:5]
wmm, hmm = map(int, sys.argv[5:7])
product = int(sys.argv[7], 0)
week, year, video = int(sys.argv[8]), int(sys.argv[9]), int(sys.argv[10], 0)
min_v, max_v, min_h, max_h, max_clock = map(int, sys.argv[11:16])
secondary_x, secondary_y = map(int, sys.argv[16:18])
binary_serial = int(sys.argv[18], 0)
revision = int(sys.argv[19])
secondary_clock, secondary_hfront, secondary_hsync, secondary_hblank, \
    secondary_vfront, secondary_vsync, secondary_vblank = map(
        int, sys.argv[20:27])
secondary_hsync_positive, secondary_vsync_positive, \
    secondary_width_mm, secondary_height_mm = map(int, sys.argv[27:31])
e = bytearray(open(path, 'rb').read())
assert len(e) >= 128 and e[:8] == b'\x00\xff\xff\xff\xff\xff\xff\x00'
vendor_word = (e[8] << 8) | e[9]
actual_vendor = ''.join(chr(64 + ((vendor_word >> shift) & 0x1f))
                        for shift in (10, 5, 0))
assert actual_vendor == vendor, (actual_vendor, vendor)
assert (e[10] | (e[11] << 8)) == product
assert int.from_bytes(e[12:16], 'little') == binary_serial
assert (e[18], e[19]) == (1, revision)
assert e[16] == week and e[17] + 1990 == year and e[20] == video
assert e[21] == wmm // 10 and e[22] == hmm // 10
# ---- 自检：确认是"正常 1080p 列表"结构 ----
asp = {0:'16:10',1:'4:3',2:'5:4',3:'16:9'}
std = []
for i in range(38, 54, 2):
    b0, b1 = e[i], e[i+1]
    if (b0 == 1 and b1 == 1) or (b0 == 0 and b1 == 0): continue
    x = (b0+31)*8; a = (b1>>6)&3; y = {0:x*10//16,1:x*3//4,2:x*4//5,3:x*9//16}[a]
    std.append(f'{x}x{y}/{asp[a]}')
dtds = []
dtd_details = {}
texts = {}
range_desc = None
descriptor_bases = [54, 72, 90, 108]
if len(e) >= 256 and e[128] == 0x02:
    descriptor_bases.extend(range(128 + e[130], 128 + 127 - 17, 18))
for base in descriptor_bases:
    if (e[base] or e[base+1]) and not (e[base]==0 and e[base+1]==0 and e[base+2]==0):
        ha = ((e[base+4]&0xf0)<<4)|e[base+2]; va = ((e[base+7]&0xf0)<<4)|e[base+5]
        dtds.append(f'{ha}x{va}')
        hblank = ((e[base+4] & 0x0f) << 8) | e[base+3]
        vblank = ((e[base+7] & 0x0f) << 8) | e[base+6]
        hfront = ((e[base+11] & 0xc0) << 2) | e[base+8]
        hsync = ((e[base+11] & 0x30) << 4) | e[base+9]
        vfront = ((e[base+11] & 0x0c) << 2) | (e[base+10] >> 4)
        vsync = ((e[base+11] & 0x03) << 4) | (e[base+10] & 0x0f)
        actual_w = e[base+12] | ((e[base+14] & 0xf0) << 4)
        actual_h = e[base+13] | ((e[base+14] & 0x0f) << 8)
        hsync_positive = int(bool(e[base+17] & 0x02))
        vsync_positive = int(bool(e[base+17] & 0x04))
        dtd_details[base] = (
            int.from_bytes(e[base:base+2], 'little') * 10,
            ha, va, hfront, hsync, hblank, vfront, vsync, vblank,
            hsync_positive, vsync_positive, actual_w, actual_h,
        )
    elif e[base:base+3] == b'\x00\x00\x00':
        tag = e[base+3]
        if tag in (0xfc, 0xff):
            texts[tag] = bytes(e[base+5:base+18]).decode(
                'ascii').rstrip(' \n\x00')
        elif tag == 0xfd:
            range_desc = tuple(e[base+5:base+10])
m35 = {0:'800x600/4:3', 5:'640x480/4:3'}; m36 = {3:'1024x768/4:3'}
est = [m35[b] for b in m35 if e[35] & (1<<b)] + [m36[b] for b in m36 if e[36] & (1<<b)]
chk0 = sum(e[0:128]) & 0xff
print(f'[disp-cache] 生成 EDID: DTD={dtds} 标准时序={std or "(空,符合预期)"} established(4:3)={est} blk0_chk={chk0}')
# 关键不变式：标准时序必须为空——否则 16:9 会被 Windows 误读成 16:10 幻影档
assert not std, f'标准时序非空 {std}：会冒出 16:10 幻影（如 1920×1200）！'
assert '1920x1080' in dtds and f'{secondary_x}x{secondary_y}' in dtds, \
    f'DTD 缺首选或组件次要时序: {dtds}'
expected_primary_detail = (
    148500, 1920, 1080, 88, 44, 280, 4, 5, 45, 1, 1, wmm, hmm,
)
expected_secondary_detail = (
    secondary_clock, secondary_x, secondary_y,
    secondary_hfront, secondary_hsync, secondary_hblank,
    secondary_vfront, secondary_vsync, secondary_vblank,
    secondary_hsync_positive, secondary_vsync_positive,
    secondary_width_mm, secondary_height_mm,
)
assert dtd_details.get(54) == expected_primary_detail, \
    f'首选 DTD(base=54) 与固定 1080p 时序不一致: {dtd_details}'
assert dtd_details.get(72) == expected_secondary_detail, \
    f'次要 DTD(base=72) 与组件 raw EDID 不一致: {dtd_details}'
assert all('4:3' in m for m in est), f'established 含非 4:3: {est}'
assert texts.get(0xfc) == name and texts.get(0xff) == serial, texts
assert range_desc == (min_v, max_v, min_h, max_h, (max_clock + 9) // 10), \
    range_desc
assert all(sum(e[base:base+128]) & 0xff == 0
           for base in range(0, len(e), 128))
PY
log "EDID blob: $EDID_BIN ($(stat -c%s "$EDID_BIN") bytes)"

# ---- 3) NBD 连接 overlay（RW，写只落到增量盘）+ 挂载 ----
# 并发安全 (P2)：取全局 NBD 锁，串行化所有 host-*.sh 离线工具，防并发抢同一 nbd 设备。
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/nbd-lock.sh"
modprobe nbd max_part=16 2>/dev/null || true
cleanup() {
    local rc=$?
    umount "$MOUNT" 2>/dev/null || true
    nbd_disconnect_if_owned   # 只断本脚本成功连接的设备（不误断外部）
    exit $rc
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
    if mount -t ntfs-3g -o ro "$p" "$MOUNT" 2>/dev/null; then
        if [[ -f "$MOUNT/Windows/System32/config/SYSTEM" ]]; then
            umount "$MOUNT"; SYSPART="$p"; break
        fi
        umount "$MOUNT" 2>/dev/null || true
    fi
done
[[ -n "$SYSPART" ]] || die "找不到含 Windows 的 NTFS 分区"
log "Windows 系统分区: $SYSPART"

ntfsfix --clear-dirty "$SYSPART" >/dev/null
MOUNT_ERR="$(mktemp)"
if ! mount -t ntfs-3g -o rw,remove_hiberfile "$SYSPART" "$MOUNT" 2>"$MOUNT_ERR"; then
    cat "$MOUNT_ERR" >&2
    grep -q hibernated "$MOUNT_ERR" && die "guest 处于 Fast Startup/休眠，先在 guest 内 powercfg -h off 再 shutdown /s"
    die "RW 挂载失败"
fi
rm -f "$MOUNT_ERR"

HIVE="${MOUNT}/Windows/System32/config/SYSTEM"
[[ -f "$HIVE" ]] || die "SYSTEM hive 不存在"

# profile 事实从读取到 NBD 挂载期间仍可能被不遵守实例锁的进程替换。首次改写
# SYSTEM hive 前必须复核摘要；变化时由既有 EXIT trap 安全卸载并断开本脚本的 NBD。
host_display_cache_require_profile_hash "$PROFILE" "$PROFILE_HASH_BEFORE" ||
    die "profile 在离线维护期间发生变化，拒绝写入 SYSTEM hive"

# ---- 4) regf 头 pre-fixup（让 hivex 能打开）----
python3 - "$HIVE" <<'PY'
import struct, sys
path = sys.argv[1]; HBIN = 0x1000
d = bytearray(open(path, 'rb').read())
assert d[:4] == b'regf', '不是 regf'
pri, sec = struct.unpack_from('<I', d, 4)[0], struct.unpack_from('<I', d, 8)[0]
eolp = struct.unpack_from('<I', d, 0x28)[0]
if pri != sec:
    n = max(pri, sec); struct.pack_into('<I', d, 4, n); struct.pack_into('<I', d, 8, n)
off = HBIN; last = HBIN
while off < len(d):
    if bytes(d[off:off+4]) != b'hbin': break
    sz = struct.unpack_from('<I', d, off+8)[0]
    if sz == 0 or off+sz > len(d): break
    last = off+sz; off += sz
ae = last - HBIN
if eolp > ae: struct.pack_into('<I', d, 0x28, ae)
csum = 0
for i in range(0, 0x1fc, 4): csum ^= struct.unpack_from('<I', d, i)[0]
struct.pack_into('<I', d, 0x1fc, csum)
open(path, 'wb').write(d)
print('[disp-cache] pre-fixup OK')
PY

# ---- 5) hivex：替换缓存 EDID + 清模式配置 ----
HIVE="$HIVE" EDID_BIN="$EDID_BIN" python3 - <<'PY'
import hivex, os, struct
HIVE = os.environ['HIVE']
edid = open(os.environ['EDID_BIN'], 'rb').read()
h = hivex.Hivex(HIVE, write=True)
root = h.root()

def child(n, name):
    for c in h.node_children(n):
        if h.node_name(c).lower() == name.lower(): return c
    return None
def walk(n, parts):
    for p in parts:
        n = child(n, p)
        if n is None: return None
    return n

# 所有 ControlSetNNN（current + LastKnownGood 都刷，避免回退到旧缓存）
csets = [h.node_name(c) for c in h.node_children(root)
         if h.node_name(c).lower().startswith('controlset')]
print('[disp-cache] ControlSets:', csets)

edid_writes = 0
cfg_deletes = 0
for cs in csets:
    # 5a) 每个 Enum\DISPLAY 实例的 Device Parameters\EDID -> 新 16:9 blob
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
                    edid_writes += 1
                    print(f'  {cs}\\...\\{h.node_name(pnp)}\\{h.node_name(inst)}: EDID 替换 ({len(edid)}B)')
    # 5b) 清 GraphicsDrivers\Configuration / Connectivity 子键
    for sub in ('Configuration', 'Connectivity'):
        gd = walk(root, [cs, 'Control', 'GraphicsDrivers', sub])
        if gd:
            kids = list(h.node_children(gd))
            for k in kids:
                h.node_delete_child(k)
                cfg_deletes += 1
            if kids:
                print(f'  {cs}\\Control\\GraphicsDrivers\\{sub}: 删 {len(kids)} 子键')

print(f'[disp-cache] EDID 替换 {edid_writes} 处, 模式配置删 {cfg_deletes} 子键')
assert edid_writes > 0, '没找到任何缓存 EDID 的 DISPLAY 实例——guest 可能还没枚举过显示器'
h.commit(None)
del h
print('[disp-cache] hivex commit 完成')
PY

# ---- 6) Phase C：commit 后再同步 seq + 重算 checksum（保险）----
python3 - "$HIVE" <<'PY'
import struct, sys
path = sys.argv[1]; HBIN = 0x1000
d = bytearray(open(path, 'rb').read())
pri, sec = struct.unpack_from('<I', d, 4)[0], struct.unpack_from('<I', d, 8)[0]
if pri != sec:
    n = max(pri, sec); struct.pack_into('<I', d, 4, n); struct.pack_into('<I', d, 8, n)
off = HBIN; last = HBIN
while off < len(d):
    if bytes(d[off:off+4]) != b'hbin': break
    sz = struct.unpack_from('<I', d, off+8)[0]
    if sz == 0 or off+sz > len(d): break
    last = off+sz; off += sz
ae = last - HBIN
eolp = struct.unpack_from('<I', d, 0x28)[0]
if eolp > ae:
    struct.pack_into('<I', d, 0x28, ae)
csum = 0
for i in range(0, 0x1fc, 4): csum ^= struct.unpack_from('<I', d, i)[0]
struct.pack_into('<I', d, 0x1fc, csum)
open(path, 'wb').write(d)
print('[disp-cache] Phase C: seq 同步 + checksum 重算 OK')
PY

sync
log "完成。下次开机 Windows 会从新 EDID 重建为正常 1080p 分辨率列表（vms/${INSTANCE}）。"
