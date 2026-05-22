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
#        （qemu-edid + 物理尺寸补丁），写进每个 Enum\DISPLAY 实例的
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
NBD="${NBD:-/dev/nbd0}"
MOUNT="/tmp/winmnt-disp-${INSTANCE}"
EDID_BIN="/tmp/stealth-edid-${INSTANCE}.bin"

log() { echo "[disp-cache] $*"; }
die() { echo "[disp-cache] ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "需要 root（qemu-nbd / mount）。用 sudo 跑。"
[[ -f "$DISK" ]] || die "找不到 $DISK"
[[ -f "$PROFILE" ]] || die "找不到 profile $PROFILE"
[[ -x "$QEMU_EDID" ]] || die "找不到 $QEMU_EDID（先 ninja -C build qemu-edid）"

# ---- guard：实例 VM 不能在运行 ----
if pgrep -af "qemu-system-x86_64" 2>/dev/null | grep -q "vms/${INSTANCE}/disk.qcow2"; then
    die "实例 ${INSTANCE} 的 QEMU 正在运行——挂载它的 overlay 会损坏磁盘。先 stop-vm.sh ${INSTANCE}。"
fi

# ---- 1) 读 profile 的 EDID 参数 ----
# profile 是 shell 赋值格式；在子环境里 source，取我们要的几个变量。
eval "$(grep -E '^EDID_(VENDOR|NAME|SERIAL|WIDTH_MM|HEIGHT_MM)=' "$PROFILE")"
EDID_VENDOR="${EDID_VENDOR:-SAM}"
EDID_NAME="${EDID_NAME:-S24F350}"
EDID_SERIAL="${EDID_SERIAL:-H4ZK500001VL}"
EDID_WIDTH_MM="${EDID_WIDTH_MM:-530}"
EDID_HEIGHT_MM="${EDID_HEIGHT_MM:-300}"
log "实例 ${INSTANCE} 显示器: ${EDID_VENDOR} ${EDID_NAME} sn=${EDID_SERIAL} ${EDID_WIDTH_MM}x${EDID_HEIGHT_MM}mm"

# ---- 2) 生成与设备一致的 16:9 EDID（qemu-edid 用当前 edid-generate.c）----
# qemu-edid 没有 width-mm/height-mm 选项（它从 dpi 推），所以生成后把物理尺寸
# 字节补成 profile 的真实值，再重算两块 checksum —— 这样和 start-vm.sh 传给
# virtio-vga 的 edid-width-mm/height-mm 字节级一致。
"$QEMU_EDID" -o "$EDID_BIN" -v "$EDID_VENDOR" -n "$EDID_NAME" -s "$EDID_SERIAL" \
    -x 1920 -y 1080 -X 1920 -Y 1080 >/dev/null
python3 - "$EDID_BIN" "$EDID_WIDTH_MM" "$EDID_HEIGHT_MM" <<'PY'
import sys
path, wmm, hmm = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
e = bytearray(open(path, 'rb').read())
e[21] = wmm // 10
e[22] = hmm // 10
# 两条 DTD 的物理尺寸都补成真实值（DTD1@54, DTD2@72；同一显示器须一致）。
# qemu-edid 没 width-mm 选项、按 dpi 推出 480×270，这里覆盖成 profile 的真实值。
for base in (54, 72):
    if e[base] or e[base+1]:   # 该描述符是 DTD（pixel clock 非零）才补
        e[base+12] = wmm & 0xff
        e[base+13] = hmm & 0xff
        e[base+14] = ((wmm & 0xf00) >> 4) | ((hmm & 0xf00) >> 8)
# 重算 block0 checksum (byte127)
s = sum(e[0:127]) & 0xff
e[127] = (0x100 - s) & 0xff if s else 0
open(path, 'wb').write(e)
# ---- 自检：确认是"正常 1080p 列表"结构 ----
asp = {0:'16:10',1:'4:3',2:'5:4',3:'16:9'}
std = []
for i in range(38, 54, 2):
    b0, b1 = e[i], e[i+1]
    if (b0 == 1 and b1 == 1) or (b0 == 0 and b1 == 0): continue
    x = (b0+31)*8; a = (b1>>6)&3; y = {0:x*10//16,1:x*3//4,2:x*4//5,3:x*9//16}[a]
    std.append(f'{x}x{y}/{asp[a]}')
dtds = []
for base in (54, 72, 90, 108):
    if (e[base] or e[base+1]) and not (e[base]==0 and e[base+1]==0 and e[base+2]==0):
        ha = ((e[base+4]&0xf0)<<4)|e[base+2]; va = ((e[base+7]&0xf0)<<4)|e[base+5]
        dtds.append(f'{ha}x{va}')
m35 = {0:'800x600/4:3', 5:'640x480/4:3'}; m36 = {3:'1024x768/4:3'}
est = [m35[b] for b in m35 if e[35] & (1<<b)] + [m36[b] for b in m36 if e[36] & (1<<b)]
chk0 = sum(e[0:128]) & 0xff
print(f'[disp-cache] 生成 EDID: DTD={dtds} 标准时序={std or "(空,符合预期)"} established(4:3)={est} blk0_chk={chk0}')
# 关键不变式：标准时序必须为空——否则 16:9 会被 Windows 误读成 16:10 幻影档
assert not std, f'标准时序非空 {std}：会冒出 16:10 幻影（如 1920×1200）！'
assert '1920x1080' in dtds and '1600x900' in dtds, f'DTD 缺 1920×1080 或 1600×900: {dtds}'
assert all('4:3' in m for m in est), f'established 含非 4:3: {est}'
PY
log "EDID blob: $EDID_BIN ($(stat -c%s "$EDID_BIN") bytes)"

# ---- 3) NBD 连接 overlay（RW，写只落到增量盘）+ 挂载 ----
modprobe nbd max_part=16 2>/dev/null || true
cleanup() {
    local rc=$?
    umount "$MOUNT" 2>/dev/null || true
    qemu-nbd --disconnect "$NBD" 2>/dev/null || true
    exit $rc
}
trap cleanup EXIT
qemu-nbd --disconnect "$NBD" 2>/dev/null || true
log "qemu-nbd --connect $NBD $DISK"
qemu-nbd --connect="$NBD" --format=qcow2 "$DISK"
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
