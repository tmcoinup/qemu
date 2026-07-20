#!/bin/bash
# sync-monitor-cache.sh — vGPU host 侧离线刷新 Windows 显示器 EDID/模式缓存
#
# 背景：
#   Windows 把显示器 EDID 缓存在
#     HKLM\SYSTEM\CurrentControlSet\Enum\DISPLAY\<PNP>\<inst>\Device Parameters\EDID
#   分辨率下拉就是从这份【缓存的 EDID】解析出来的。旧 guest（以及从旧 base
#   克隆出来的实例）不会自动刷新这份缓存，所以即便 QEMU 端 EDID 已改变，
#   Windows 仍可能显示旧分辨率集。
#   GraphicsDrivers\Configuration / Connectivity 还会按显示器签名缓存"已验证
#   模式表"，同样会拖着旧分辨率。
#
#   本脚本离线地：
#     1) 按统一真实型号目录生成完整 EDID，写进每个 Enum\DISPLAY 实例的
#        Device Parameters\EDID；
#     2) 清空 GraphicsDrivers 的模式/连接缓存子键（含跨厂商
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
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
QEMU_EDID="${QEMU_EDID:-${REPO_ROOT}/build/qemu-edid}"
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
        --generate-only) GENERATE_ONLY=$2; shift 2 ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "未知参数: $1" >&2; exit 2 ;;
    esac
done

# shellcheck source=../../lib/monitor-profiles.sh
source "$REPO_ROOT/deploy/lib/monitor-profiles.sh"
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
if ! [[ "$MONITOR_SERIAL_VALUE" =~ ^[A-Z0-9]{1,12}$ ]]; then
    MONITOR_SERIAL_VALUE=$(monitor_profile_generate_serial \
        "$MONITOR_SERIAL_PREFIX" "$INSTANCE_LABEL-$MONITOR_PROFILE")
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

# NVIDIA vGPU 正常解析 EDID standard timings；固定保留真实 FHD 显示器常见列表。
python3 - "$EDID_BIN" "$MONITOR_VENDOR" \
    "$MONITOR_PRODUCT_ID" "$MONITOR_WIDTH_MM" "$MONITOR_HEIGHT_MM" <<'PY'
import sys
path = sys.argv[1]
expected_vendor = sys.argv[2]
expected_product = int(sys.argv[3], 0)
wmm, hmm = int(sys.argv[4]), int(sys.argv[5])
e = bytearray(open(path, 'rb').read())
assert len(e) >= 128 and len(e) % 128 == 0

def encode_standard(x, aspect, refresh=60):
    return bytes((x // 8 - 31, (aspect << 6) | (refresh - 60)))

# 实机 FHD 商务屏常见的标准时序：16:9 / 16:10 / 5:4 均由 EDID
# 明确编码，不让 Windows 猜比例。
modes = (
    (1920, 3), (1680, 0), (1600, 3),
    (1280, 2), (1280, 0), (1280, 3),
)
std_bytes = b''.join(encode_standard(x, aspect) for x, aspect in modes)
e[38:54] = std_bytes + b'\x01\x01' * ((16 - len(std_bytes)) // 2)
e[127] = (-sum(e[:127])) & 0xff

raw_vendor = (e[8] << 8) | e[9]
vendor = ''.join(chr(ord('@') + ((raw_vendor >> shift) & 0x1f))
                 for shift in (10, 5, 0))
product = int.from_bytes(e[10:12], 'little')
assert vendor == expected_vendor, (vendor, expected_vendor)
assert product == expected_product, (hex(product), hex(expected_product))
assert e[21] == (wmm + 5) // 10 and e[22] == (hmm + 5) // 10

asp = {0:'16:10',1:'4:3',2:'5:4',3:'16:9'}
std = []
for i in range(38, 54, 2):
    b0, b1 = e[i], e[i+1]
    if (b0 == 1 and b1 == 1) or (b0 == 0 and b1 == 0): continue
    x = (b0+31)*8; a = (b1>>6)&3; y = {0:x*10//16,1:x*3//4,2:x*4//5,3:x*9//16}[a]
    std.append(f'{x}x{y}/{asp[a]}')
dtds = []
for base in (54, 72, 90, 108):
    if e[base] or e[base+1]:
        ha = ((e[base+4]&0xf0)<<4)|e[base+2]; va = ((e[base+7]&0xf0)<<4)|e[base+5]
        dtds.append(f'{ha}x{va}')
m35 = {0:'800x600/4:3', 5:'640x480/4:3'}; m36 = {3:'1024x768/4:3'}
est = [m35[b] for b in m35 if e[35] & (1<<b)] + [m36[b] for b in m36 if e[36] & (1<<b)]
checksums = [sum(e[i:i+128]) & 0xff for i in range(0, len(e), 128)]
assert not any(checksums), checksums
print(f'[disp-cache] EDID: DTD={dtds} standard={std} established={est} checksums={checksums}')
assert '1920x1080' in dtds, f'DTD 缺 native 1920x1080: {dtds}'
expected = ['1920x1080/16:9', '1680x1050/16:10', '1600x900/16:9',
            '1280x1024/5:4', '1280x800/16:10', '1280x720/16:9']
assert std == expected, (std, expected)
assert not any(m.startswith('1920x1200') for m in std), std
assert all('4:3' in m for m in est), f'established 含非 4:3: {est}'
open(path, 'wb').write(e)
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
source "$REPO_ROOT/deploy/lib/nbd-lock.sh"
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

# ---- 5) hivex：替换缓存 EDID/可读身份 + 清模式配置 ----
MONITOR_PNP="${MONITOR_VENDOR}${MONITOR_PRODUCT_ID#0x}"
HIVE="$HIVE" EDID_BIN="$EDID_BIN" \
    MONITOR_NAME="$MONITOR_DISPLAY_NAME" \
    MONITOR_MFG="$MONITOR_MANUFACTURER" MONITOR_PNP="$MONITOR_PNP" \
    python3 - <<'PY'
import hivex, os, struct
HIVE = os.environ['HIVE']
edid = open(os.environ['EDID_BIN'], 'rb').read()
monitor_name = os.environ['MONITOR_NAME']
monitor_mfg = os.environ['MONITOR_MFG']
monitor_hwid = 'MONITOR\\' + os.environ['MONITOR_PNP']
h = hivex.Hivex(HIVE, write=True)
root = h.root()

def reg_sz(value):
    return value.encode('utf-16le') + b'\x00\x00'

def reg_multi(values):
    return ('\x00'.join(values) + '\x00\x00').encode('utf-16le')

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
                    h.node_set_value(inst, {'key': 'DeviceDesc', 't': 1,
                                           'value': reg_sz(monitor_name)})
                    h.node_set_value(inst, {'key': 'FriendlyName', 't': 1,
                                           'value': reg_sz(monitor_name)})
                    h.node_set_value(inst, {'key': 'Mfg', 't': 1,
                                           'value': reg_sz(monitor_mfg)})
                    h.node_set_value(inst, {'key': 'HardwareID', 't': 7,
                                           'value': reg_multi([monitor_hwid])})
                    edid_writes += 1
                    print(f'  {cs}\\...\\{h.node_name(pnp)}\\{h.node_name(inst)}: EDID 替换 ({len(edid)}B)')
    # 5b) 清 GraphicsDrivers\Configuration / Connectivity 子键
    for sub in ('Configuration', 'Connectivity', 'ScaleFactors', 'MonitorDataStore'):
        gd = walk(root, [cs, 'Control', 'GraphicsDrivers', sub])
        if gd:
            kids = list(h.node_children(gd))
            for k in kids:
                h.node_delete_child(k)
                cfg_deletes += 1
            if kids:
                print(f'  {cs}\\Control\\GraphicsDrivers\\{sub}: 删 {len(kids)} 子键')

print(f'[disp-cache] EDID 替换 {edid_writes} 处, 模式配置删 {cfg_deletes} 子键')
if edid_writes == 0:
    print('[disp-cache] WAIT: 没找到缓存 EDID；guest 需要先正常枚举一次显示器')
    raise SystemExit(10)
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
    printf '%s\n' "$MARKER_VALUE" >"$marker_tmp"
    chmod 0644 "$marker_tmp"
    mv -f -- "$marker_tmp" "$MARKER"
fi
log "完成。下次开机 Windows 会按 ${MONITOR_DISPLAY_NAME} 重建正常分辨率列表；guest 内未安装软件。"
