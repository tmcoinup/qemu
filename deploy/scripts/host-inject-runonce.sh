#!/usr/bin/env bash
# host-inject-runonce.sh —— offline 在 Win10 guest 的 SOFTWARE hive 里写
# 一个 RunOnce 项，让 guest 下次开机时自动跑指定 PowerShell 命令。
#
# 用法：
#   sudo deploy/scripts/host-inject-runonce.sh <INSTANCE> "<command>"
#
# 例：
#   sudo deploy/scripts/host-inject-runonce.sh 2 \
#       'powershell -NoProfile -ExecutionPolicy Bypass -Command "irm http://192.168.30.33:8765/respawn-stealth.ps1 | iex"'
#
# 机制：
#   HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce 下加 *StealthRespawn
#   值类型 REG_SZ。前缀 '*' 让 RunOnce 即使 Safe Mode 也执行；执行后 Windows
#   自动从 RunOnce 删除该项（避免重复触发）。
#
# Prereqs (apt): qemu-utils ntfs-3g python3-hivex
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: must be run as root" >&2; exit 1
fi

INSTANCE="${1:-}"
COMMAND="${2:-}"
NAME="${3:-*StealthRespawn}"
if [[ -z "$INSTANCE" || -z "$COMMAND" ]]; then
    echo "usage: $0 <INSTANCE> '<powershell command>' [<value_name>]" >&2; exit 2
fi

VM_DIR="/home/ubuntu/images/vms/${INSTANCE}"
DISK="${DISK:-$VM_DIR/disk.qcow2}"
_NBD_PINNED="${NBD:+1}"   # 记录用户是否显式指定 NBD（忙时决定 fail-fast vs 自动选盘）
: "${NBD:=/dev/nbd0}"
: "${MOUNT:=/mnt/win10-inst${INSTANCE}}"

log() { printf '[inject-runonce] %s\n' "$*"; }
die() { log "ERROR: $*"; exit 1; }

[[ -f "$DISK" ]] || die "disk not found: $DISK"
command -v qemu-nbd >/dev/null || die "need apt: qemu-utils"
command -v ntfsfix  >/dev/null || die "need apt: ntfs-3g"
python3 -c 'import hivex' 2>/dev/null || die "need apt: python3-hivex"

# 并发安全 (P2)：取全局 NBD 锁，串行化所有 host-*.sh 离线工具，防并发抢同一 nbd 设备。
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/nbd-lock.sh"
modprobe nbd max_part=16 2>/dev/null || true
cleanup() {
    umount "$MOUNT" 2>/dev/null || true
    nbd_disconnect_if_owned   # 只断本脚本成功连接的设备（不误断外部）
}
trap cleanup EXIT

log "attaching $DISK to $NBD"
nbd_connect NBD "$DISK"   # guard+选盘+connect，置 _NBD_CONNECTED；忙时显式→fail-fast / 默认→自动选盘
sleep 1

SYSPART=""
for p in "${NBD}p3" "${NBD}p4" "${NBD}p2" "${NBD}p1"; do
    [[ -b "$p" ]] || continue
    if blkid -o value -s TYPE "$p" 2>/dev/null | grep -q '^ntfs$'; then
        SYSPART="$p"; break
    fi
done
[[ -n "$SYSPART" ]] || die "no NTFS partition under $NBD"

mkdir -p "$MOUNT"
ntfsfix --clear-dirty "$SYSPART" >/dev/null
mount -t ntfs-3g -o rw,remove_hiberfile "$SYSPART" "$MOUNT"

HIVE="${MOUNT}/Windows/System32/config/SOFTWARE"
[[ -f "$HIVE" ]] || die "SOFTWARE hive 不存在: $HIVE"

# NB: 不要 truncate .LOG1/.LOG2 —— Win10 kernel mount SOFTWARE 时 expects
# LOG 是 valid file（不是 0-byte），truncate 后 winload pass 但 kernel mount
# SOFTWARE 失败 → BSOD → reboot loop → Recovery 0xc0000001。
# 反过来不动 LOG 时改了 SOFTWARE 也不安全 —— LOG 里 captured 旧 seq 的 pending
# transaction 会 replay 把我们刚写的 RunOnce 覆盖掉。
#
# 综上：本脚本已 **deprecated**，clone-from-base.sh 不再调用它。
# 等价命令已搬进 deploy/autounattend/autounattend.xml 的 FirstLogonCommands
# Order=10，OOBE 完成后第一次 logon 自动跑（不需要离线动 hive）。
log "WARN: host-inject-runonce.sh 已 deprecated；用 autounattend FirstLogonCommands 替代"

# Pre-fixup hive header (Win10 22H2 起 SYSTEM hive 偶尔 seq 不一致，SOFTWARE
# 同样保险——逻辑跟 host-fix-gpu-devpkey.sh 那段一致)
log "pre-fixup SOFTWARE hive header"
python3 - "$HIVE" <<'PY'
import struct, sys
path = sys.argv[1]
HBIN_BASE = 0x1000
with open(path, 'r+b') as f:
    data = bytearray(f.read())
if data[:4] != b'regf': sys.exit('not regf')
pri = struct.unpack_from('<I', data, 4)[0]
sec = struct.unpack_from('<I', data, 8)[0]
if pri != sec:
    newseq = max(pri, sec)
    struct.pack_into('<I', data, 4, newseq)
    struct.pack_into('<I', data, 8, newseq)
off = HBIN_BASE; last_end = HBIN_BASE
while off < len(data):
    if bytes(data[off:off+4]) != b'hbin': break
    sz = struct.unpack_from('<I', data, off + 8)[0]
    if sz == 0: break
    last_end = off + sz; off += sz
struct.pack_into('<I', data, 0x28, last_end - HBIN_BASE)
csum = 0
for i in range(0, 0x1fc, 4):
    csum ^= struct.unpack_from('<I', data, i)[0]
struct.pack_into('<I', data, 0x1fc, csum)
with open(path, 'wb') as f: f.write(data)
PY

log "写入 RunOnce: name='$NAME' value='$COMMAND'"
NAME="$NAME" CMD="$COMMAND" HIVE="$HIVE" python3 - <<'PY'
import hivex, os, sys

h = hivex.Hivex(os.environ['HIVE'], write=True)
n = h.root()
for p in ['Microsoft', 'Windows', 'CurrentVersion', 'RunOnce']:
    c = h.node_get_child(n, p)
    if c is None:
        c = h.node_add_child(n, p)
        print(f'  created node: {p}')
    n = c

name = os.environ['NAME']
cmd  = os.environ['CMD']
# REG_SZ value: UTF-16LE + NUL terminator
data = (cmd + '\0').encode('utf-16-le')
h.node_set_value(n, {
    't': 1,            # REG_SZ
    'key': name,
    'value': data,
})
h.commit(None)
print(f'  wrote {name} = {cmd}')
PY

log "done. guest 首次开机会自动跑 RunOnce 命令"
