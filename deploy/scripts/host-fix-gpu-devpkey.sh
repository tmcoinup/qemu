#!/usr/bin/env bash
# host-fix-gpu-devpkey.sh — offline fix for DEVPKEY DriverProvider / DriverDesc
# on the virtio-gpu device of a shut-down Win10 guest.
#
# Why this script exists:
#   Device Manager → GPU → 驱动程序 → 驱动程序提供商 shows "未知" unless
#     (a) the SD of Enum\PCI\<hwid>\<inst>\Properties\{a8b865dd-...} is
#         readable by Administrators (Windows installs it as TrustedInstaller-
#         only), AND
#     (b) vk.type of the 00000000 value under pid 0004 / 0009 equals
#         0xFFFF0012 (DEVPROP_TYPE_STRING), NOT REG_SZ (0x1).
#
#   apply-gpu-spoof.ps1 handles (a) via Take-RegOwnership from inside the
#   guest, but `reg.exe add /t REG_SZ` can only produce type 0x1, and
#   SetupDiGetDeviceProperty fails (→ "未知") if the type word is wrong.
#
#   This script does both offline by raw-editing the hive on qcow2.
#
# 2026-05 改进：默认从 vms/<N>/profile **自动读** GPU_NAME / GPU_VENDOR，
# 不再需要手工传 PROVIDER / DEVICE_DESC；NVIDIA / AMD 都识别。
#
# Prereqs (apt 一行装齐)：
#   sudo apt install -y qemu-utils ntfs-3g python3-hivex
#
# 该脚本**纯离线** —— 直接读写 qcow2 文件，不连 guest、不联网。
# 唯一要 root 的原因是 qemu-nbd / mount NTFS 需要。
#
# Usage:
#   sudo deploy/scripts/host-fix-gpu-devpkey.sh <INSTANCE> [--dry-run]
#
# Must be run as root (it does qemu-nbd / ntfsfix / mount). If the VM is
# still running, it will invoke stop-vm.sh (as the original user) first.
#
# Environment overrides（不传就从 profile 自动派生）:
#   DISK=<path>           default /home/ubuntu/images/vms/<N>/disk.qcow2
#                         (auto-falls back to legacy win10-inst<N>.qcow2 layout)
#   NBD=/dev/nbdN         default /dev/nbd0
#   MOUNT=<path>          default /mnt/win10-inst<N>
#   PROVIDER=<string>     default = profile.GPU_VENDOR
#   DEVICE_DESC=<string>  default = profile.GPU_NAME
#   SUBSYS_RE=<regex>     default '^VEN_1AF4&DEV_1050' (virtio-vga 主 ID)
#
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: must be run as root. Try: sudo $0 $*" >&2
    exit 1
fi

INSTANCE="${1:-1}"
shift || true

DRY=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY=1 ;;
        *) echo "unknown flag: $arg" >&2; exit 2 ;;
    esac
done

# The original user for invoking stop-vm.sh (QMP socket is under their uid).
ORIG_USER="${SUDO_USER:-ubuntu}"

# VM 目录（hardware pools v2 新布局；旧 win10-inst<N>.qcow2 还在的话回退过去）
VM_DIR="/home/ubuntu/images/vms/${INSTANCE}"
PROFILE_FILE="${VM_DIR}/profile"
if [[ -z "${DISK:-}" ]]; then
    if [[ -f "${VM_DIR}/disk.qcow2" ]]; then
        DISK="${VM_DIR}/disk.qcow2"
    else
        DISK="/home/ubuntu/images/win10-inst${INSTANCE}.qcow2"
    fi
fi
: "${NBD:=/dev/nbd0}"
: "${MOUNT:=/mnt/win10-inst${INSTANCE}}"
: "${SUBSYS_RE:=^VEN_1AF4&DEV_1050}"

log() { printf '[fix-devpkey] %s\n' "$*"; }
die() { log "ERROR: $*"; exit 1; }

# 一次性自检：缺包给出一行装齐命令，不要分散提示
MISSING=()
command -v qemu-nbd >/dev/null || MISSING+=("qemu-utils")
command -v ntfsfix  >/dev/null || MISSING+=("ntfs-3g")
python3 -c 'import hivex' 2>/dev/null || MISSING+=("python3-hivex")
if (( ${#MISSING[@]} > 0 )); then
    log "缺以下 apt 包：${MISSING[*]}"
    log "一行装齐："
    log "  sudo apt install -y ${MISSING[*]}"
    exit 1
fi

[[ -f "$DISK" ]] || die "disk not found: $DISK"

# ----------------------------------------------------------------------
# 从 vms/<N>/profile 自动读 GPU 信息（PROVIDER / DEVICE_DESC 不传时用）
# ----------------------------------------------------------------------
# 默认值（兜底，profile 不存在时也能跑）
DEFAULT_PROVIDER="NVIDIA"
DEFAULT_DEVICE_DESC="NVIDIA GeForce GTX 1050"

if [[ -f "$PROFILE_FILE" ]]; then
    # 在子 shell 里 source profile 避免污染当前环境；只取 GPU_VENDOR / GPU_NAME
    PROF_GPU_VENDOR=$(bash -c "source '$PROFILE_FILE' 2>/dev/null && echo \"\${GPU_VENDOR:-}\"" 2>/dev/null || echo "")
    PROF_GPU_NAME=$(bash -c "source '$PROFILE_FILE' 2>/dev/null && echo \"\${GPU_NAME:-}\"" 2>/dev/null || echo "")
    if [[ -n "$PROF_GPU_VENDOR" ]]; then
        DEFAULT_PROVIDER="$PROF_GPU_VENDOR"
    fi
    if [[ -n "$PROF_GPU_NAME" ]]; then
        DEFAULT_DEVICE_DESC="$PROF_GPU_NAME"
    fi
    log "profile: ${PROFILE_FILE}"
    log "  GPU_VENDOR=${PROF_GPU_VENDOR:-<空，用默认 NVIDIA>}"
    log "  GPU_NAME=${PROF_GPU_NAME:-<空，用默认 GTX 1050>}"
else
    log "WARN: profile 文件不存在: $PROFILE_FILE"
    log "  用默认 PROVIDER=NVIDIA / DEVICE_DESC='NVIDIA GeForce GTX 1050'"
    log "  正常情况下 start-vm.sh 首启已生成 profile；手动传 env 也行："
    log "  PROVIDER=AMD DEVICE_DESC='AMD Radeon RX 550' sudo $0 $INSTANCE"
fi

# env 显式覆盖 profile（向后兼容旧用法）
: "${PROVIDER:=$DEFAULT_PROVIDER}"
: "${DEVICE_DESC:=$DEFAULT_DEVICE_DESC}"

log "将写入 Device Manager 字段："
log "  驱动程序提供商 (pid 0009): $PROVIDER"
log "  设备描述       (pid 0004): $DEVICE_DESC"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 1) Ensure VM is stopped (stop-vm.sh talks to a user-owned QMP socket).
QMP_SOCK="/tmp/qemu-stealth-${INSTANCE}.qmp"
if [[ -S "$QMP_SOCK" ]]; then
    log "instance $INSTANCE looks running, invoking stop-vm.sh as $ORIG_USER"
    sudo -u "$ORIG_USER" "${SCRIPT_DIR}/stop-vm.sh" "$INSTANCE" --wait=120 || true
    sleep 1
fi

# 2) Attach NBD + ntfsfix + mount rw.
modprobe nbd max_part=16 2>/dev/null || true

cleanup() {
    local rc=$?
    umount "$MOUNT" 2>/dev/null || true
    qemu-nbd --disconnect "$NBD" 2>/dev/null || true
    exit $rc
}
trap cleanup EXIT

log "attaching $DISK to $NBD"
qemu-nbd --connect="$NBD" --format=qcow2 "$DISK"
sleep 1

SYSPART=""
for p in "${NBD}p3" "${NBD}p4" "${NBD}p2" "${NBD}p1"; do
    [[ -b "$p" ]] || continue
    if blkid -o value -s TYPE "$p" 2>/dev/null | grep -q '^ntfs$'; then
        SYSPART="$p"; break
    fi
done
[[ -n "$SYSPART" ]] || die "no NTFS partition found under $NBD"
log "system partition: $SYSPART"

mkdir -p "$MOUNT"
log "ntfsfix --clear-dirty $SYSPART"
ntfsfix --clear-dirty "$SYSPART" >/dev/null
log "mount -t ntfs-3g -o rw,remove_hiberfile $SYSPART $MOUNT"
MOUNT_ERR=$(mktemp)
if ! mount -t ntfs-3g -o rw,remove_hiberfile "$SYSPART" "$MOUNT" 2> "$MOUNT_ERR"; then
    cat "$MOUNT_ERR" >&2
    if grep -q "hibernated" "$MOUNT_ERR"; then
        cat >&2 <<'EOF'

[fix-devpkey] ⚠ Windows 处于 Fast Startup（混合关机）状态，hiberfil.sys 阻止 RW 挂载。
[fix-devpkey]   ntfs-3g 的 remove_hiberfile 选项在该情况下也失败。
[fix-devpkey]
[fix-devpkey] 永久修复（**只需一次**，往后 shutdown 永远干净）：
[fix-devpkey]   1) start-vm.sh <N>      # 重启 VM
[fix-devpkey]   2) guest 管理员 PowerShell:
[fix-devpkey]      powercfg -h off
[fix-devpkey]      Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' `
[fix-devpkey]          -Name HiberbootEnabled -Type DWord -Value 0
[fix-devpkey]      shutdown /s /t 0
[fix-devpkey]   3) host 重跑本脚本
[fix-devpkey]
[fix-devpkey] 副作用：hibernation 被禁用、hiberfil.sys 被删；shutdown /s 变成真正 power-off。
[fix-devpkey] 这跟 stealth 反作弊语义一致——hibernation 唤醒后 TPM/PCI 状态不一定能恢复。

EOF
    fi
    rm -f "$MOUNT_ERR"
    exit 1
fi
rm -f "$MOUNT_ERR"

HIVE="${MOUNT}/Windows/System32/config/SYSTEM"
[[ -f "$HIVE" ]] || die "SYSTEM hive not found at $HIVE"

# NB: 不要 truncate .LOG1/.LOG2 —— Win10 kernel mount SYSTEM hive 时 expects
# LOG1/LOG2 是 valid file（不是 0-byte），否则 winload reject hive → 0xc0000001
# 反复 reboot 后 Recovery 屏。Hive 真改了之后 stale LOG 由 Windows 自己 discard
# （比对 LOG 跟 hive 头 seq 不一致就丢）。

# 3a) Pre-fixup: 同步 primary/secondary seq + 重算 checksum 让 hivex 能打开。
#
# Windows 写 hive 用 dirty-vector 协议：先 ++primary_seq、写数据、再 ++secondary_seq。
# 中途断电 / cold shutdown 之间发生 race，primary > secondary 是常见现象（即"还
# 有未 commit 的写"），libhivex 1.3.x 看见 seq 不一致直接返回 "Operation not supported"。
#
# 我们的修改其实**会重写**这些位置，并且 Python 阶段末尾的 Phase C 会再次同步
# seq + 重算 checksum。所以这里安全地把 secondary 拉齐 primary 让 hivex 能打开，
# 不会丢任何数据（如果 LOG1/LOG2 里有 pending，那才是真要丢的——但本脚本只读
# Windows 已经稳定 commit 的 PCI Properties，pending 的临时 transactions 即使
# 丢了也无影响）。
log "pre-fixup: 同步 hive 头 primary/secondary seq + 拉齐 end_of_last_page + 重算 checksum"
python3 - "$HIVE" <<'PY'
"""regf 头 pre-fixup，让 libhivex 1.3.x 能打开 Win10 22H2 的 SYSTEM hive。

两个常见的 ENOTSUP 原因：
  (1) primary_seq != secondary_seq —— Windows 写过一半没 commit；
      把 secondary 拉齐 primary 即可（hive 本身一致，差的是计数器）。
  (2) end_of_last_page > 实际 hbin 链尾 —— Windows 预留了 reserved hbins
      但 hivex 严格检查 "trailing garbage" 直接拒。把 end_of_last_page
      改成 hivex 能 walk 到的最远 hbin 末尾即可。

两步都安全：Phase C（脚本 Python 主体末尾）写完业务变更后会重算 checksum
+ 重新同步 sequence。这里改的只是让 hivex_open 不报错。
"""
import struct, sys
path = sys.argv[1]
HBIN_BASE = 0x1000

with open(path, 'r+b') as f:
    data = bytearray(f.read())

if data[:4] != b'regf':
    sys.exit(f'{path}: 不是 regf 文件 (got {data[:4]!r})')

pri = struct.unpack_from('<I', data, 4)[0]
sec = struct.unpack_from('<I', data, 8)[0]
eolp = struct.unpack_from('<I', data, 0x28)[0]

# (1) seq fixup
if pri != sec:
    newseq = max(pri, sec)
    struct.pack_into('<I', data, 4, newseq)
    struct.pack_into('<I', data, 8, newseq)
    print(f'  seq: 0x{pri:x}/0x{sec:x} -> 0x{newseq:x}/0x{newseq:x}')

# (2) walk hbin chain，找真实最远 hbin 末尾
off = HBIN_BASE
last_end = HBIN_BASE
while off < len(data):
    if bytes(data[off:off+4]) != b'hbin':
        break
    hbin_size = struct.unpack_from('<I', data, off + 8)[0]
    if hbin_size == 0 or off + hbin_size > len(data):
        break
    last_end = off + hbin_size
    off += hbin_size

actual_eolp = last_end - HBIN_BASE
if eolp > actual_eolp:
    struct.pack_into('<I', data, 0x28, actual_eolp)
    print(f'  end_of_last_page: 0x{eolp:x} -> 0x{actual_eolp:x} (hbin chain 实际止于 0x{last_end:x})')
elif eolp == actual_eolp:
    print(f'  end_of_last_page = 0x{eolp:x}, 与 hbin 链尾一致，无需调整')
else:
    print(f'  WARN: eolp 0x{eolp:x} < actual 0x{actual_eolp:x}; 不动')

# 重算 checksum
csum = 0
for i in range(0, 0x1fc, 4):
    csum ^= struct.unpack_from('<I', data, i)[0]
struct.pack_into('<I', data, 0x1fc, csum)
print(f'  checksum -> 0x{csum:08x}')

with open(path, 'wb') as f:
    f.write(data)
PY

# 3b) Run the embedded Python patcher.
log "patching $HIVE (provider=$PROVIDER, desc=$DEVICE_DESC)"
if [[ $DRY -eq 1 ]]; then
    DRY_RUN=1
fi

DRY_RUN="${DRY_RUN:-0}" HIVE="$HIVE" \
    PROVIDER="$PROVIDER" DEVICE_DESC="$DEVICE_DESC" \
    SUBSYS_RE="$SUBSYS_RE" \
    python3 - <<'PY'
"""Offline fixer for DEVPKEY DriverProvider / DriverDesc on virtio-gpu.

Two-phase:
  Phase A (SD): for every nk under each matching instance's Properties
                subtree, rewrite nk.sk -> instance's own sk so Admins
                can read values. sk refcounts are updated.
  Phase B (type+data): for pid 0004 and 0009, ensure the '00000000'
                value uses type 0xFFFF0012 (DEVPROP_TYPE_STRING) and
                data = UTF-16LE(value + NUL).

Finally: sync primary==secondary sequence + recompute regf checksum.
"""
import hivex
import os
import re
import struct
import sys
import gc

HIVE         = os.environ['HIVE']
PROVIDER     = os.environ['PROVIDER']
DEVICE_DESC  = os.environ['DEVICE_DESC']
SUBSYS_RE    = re.compile(os.environ['SUBSYS_RE'])
DRY_RUN      = os.environ.get('DRY_RUN') == '1'

FMT = '{a8b865dd-2e3d-4094-ad97-e593a70c75d6}'
HBIN_BASE = 0x1000
DEVPROP_STRING = 0xFFFF0012


def utf16z(s):
    return (s + '\0').encode('utf-16-le')


def main():
    # -------- phase 1: enumerate via hivex RO --------
    h = hivex.Hivex(HIVE)
    root = h.root()

    def walk(node, parts):
        for p in parts:
            node = h.node_get_child(node, p)
            if node is None:
                return None
        return node

    def collect(n, out):
        out.append(n)
        for c in h.node_children(n):
            collect(c, out)

    pci = walk(root, ['ControlSet001', 'Enum', 'PCI'])
    if pci is None:
        # sysprep generalize 会清空 Enum\PCI；clone-from-base 后 guest 还没首启
        # 时这是预期状态。不算错——RunOnce + respawn-stealth.ps1 会在 guest
        # 首次开机后自己重做 GPU 注册表对齐，所以这里返回 0 让 clone 流程继续。
        print('  ControlSet001\\Enum\\PCI 不存在 — sysprep base 未首启的预期状态')
        print('  跳过离线 DEVPKEY 覆盖；guest 首次开机后 RunOnce 会处理 GPU 对齐')
        sys.exit(0)

    targets = []
    for ven in h.node_children(pci):
        vname = h.node_name(ven)
        if not SUBSYS_RE.search(vname):
            continue
        for inst in h.node_children(ven):
            iname = h.node_name(inst)
            props = h.node_get_child(inst, 'Properties')
            if props is None:
                continue
            fmt_n = h.node_get_child(props, FMT)
            pid_vk = {}  # pid -> list of (name, vk_abs_offset)
            if fmt_n is not None:
                for pid in ['0004', '0009']:
                    p_n = h.node_get_child(fmt_n, pid)
                    if p_n is None:
                        pid_vk[pid] = []
                        continue
                    vks = []
                    for v in h.node_values(p_n):
                        vks.append((h.value_key(v), v))
                    pid_vk[pid] = vks
            subtree = []
            collect(props, subtree)
            targets.append({
                'subsys': vname, 'inst': iname,
                'inst_node': inst, 'subtree': subtree,
                'pid_vk': pid_vk,
            })
            print(f'  target: {vname}\\{iname}  ({len(subtree)} Properties nk)')

    if not targets:
        sys.exit('no matching PCI instance found (SUBSYS_RE=%s)' % SUBSYS_RE.pattern)

    del h; gc.collect()

    # -------- phase 2: raw binary edit --------
    with open(HIVE, 'rb') as f:
        mm = bytearray(f.read())

    def u32(o): return struct.unpack_from('<I', mm, o)[0]
    def w32(o, v): struct.pack_into('<I', mm, o, v)

    # nk body starts at +4 (cell-size prefix). Fields listed after +4:
    def nk_sig(nk): return bytes(mm[nk+4:nk+6])
    def nk_sk_off(nk): return nk + 4 + 44
    def nk_sk(nk): return u32(nk_sk_off(nk))

    # sk is addressed by its stored offset (relative to hbin base).
    def sk_cell(s): return HBIN_BASE + s
    def sk_sig(s): return bytes(mm[sk_cell(s)+4:sk_cell(s)+6])
    def sk_refcount_off(s): return sk_cell(s) + 4 + 12
    def sk_refcount(s): return u32(sk_refcount_off(s))
    def set_sk_refcount(s, v): w32(sk_refcount_off(s), v)

    # vk body layout (after cell-size prefix): sig(2), name_len(2),
    # data_len(4), data_off(4), type(4), flags(2), spare(2), name.
    def vk_sig(vk): return bytes(mm[vk+4:vk+6])
    def vk_name_len(vk): return struct.unpack_from('<H', mm, vk+4+2)[0]
    def vk_type_off(vk): return vk + 4 + 12
    def vk_data_len_off(vk): return vk + 4 + 4
    def vk_data_off_off(vk): return vk + 4 + 8
    def vk_flags_off(vk):    return vk + 4 + 16

    # ---- Phase A: rewrite Properties subtree sk -> instance sk ----
    refcount_delta = {}
    sk_rewrites = 0

    for t in targets:
        assert nk_sig(t['inst_node']) == b'nk', f"bad inst nk sig"
        inst_sk = nk_sk(t['inst_node'])
        assert sk_sig(inst_sk) == b'sk', f"bad sk sig @0x{inst_sk:x}"
        print(f"  {t['subsys']}\\{t['inst']}: inst_sk=0x{inst_sk:x} "
              f"(refcount before = {sk_refcount(inst_sk)})")
        for nk in t['subtree']:
            if nk_sig(nk) != b'nk':
                continue
            old = nk_sk(nk)
            if old == inst_sk:
                continue
            w32(nk_sk_off(nk), inst_sk)
            sk_rewrites += 1
            refcount_delta[old] = refcount_delta.get(old, 0) - 1
            refcount_delta[inst_sk] = refcount_delta.get(inst_sk, 0) + 1

    for s, d in refcount_delta.items():
        if sk_sig(s) != b'sk':
            continue
        before = sk_refcount(s)
        after = max(0, before + d)
        set_sk_refcount(s, after)
    print(f'  phase A: {sk_rewrites} nk.sk rewrites, '
          f'{len(refcount_delta)} sk refcount updates')

    # ---- Phase B: fix vk.type and data for pid 0004 / 0009 ----
    wanted = {'0004': DEVICE_DESC, '0009': PROVIDER}
    type_fixes = 0
    data_writes = 0

    def alloc_cell(size):
        """Scan hbins for a free cell (negative size = used, positive = free)
        with |size| >= requested. Return absolute offset of cell-size prefix.
        Returns None if no free cell found."""
        # walk hbins
        off = HBIN_BASE
        while off < len(mm):
            if bytes(mm[off:off+4]) != b'hbin':
                break
            hbin_size = u32(off + 8)
            cur = off + 0x20
            end = off + hbin_size
            while cur < end:
                cs = struct.unpack_from('<i', mm, cur)[0]
                cs_abs = cs if cs >= 0 else -cs
                if cs_abs == 0:
                    break
                if cs > 0 and cs >= size:   # free cell big enough
                    return cur
                cur += cs_abs
            off += hbin_size
        return None

    def write_string_data(vk, text):
        """Ensure vk points at a UTF-16LE(text\\0) blob with correct type."""
        nonlocal data_writes
        payload = utf16z(text)
        payload_len = len(payload)
        # Registry "small inline" optimization: if payload fits in 4 bytes and
        # flag bit 0x4000 is set in data_len MSB, data_off holds inline data.
        # We avoid that path — always use an out-of-line data cell.
        old_len = u32(vk_data_len_off(vk))
        old_off = u32(vk_data_off_off(vk))
        inline = (old_len & 0x80000000) != 0
        old_data_cell = None
        old_data_cap = 0
        if not inline and old_off != 0xFFFFFFFF:
            old_data_cell = HBIN_BASE + old_off
            cs = struct.unpack_from('<i', mm, old_data_cell)[0]
            if cs < 0:  # used
                old_data_cap = (-cs) - 4
        # pad payload up to 8 bytes alignment as Windows does
        if old_data_cap >= payload_len:
            # reuse existing cell
            struct.pack_into(f'<{payload_len}s', mm, old_data_cell + 4, payload)
            # zero tail
            tail = old_data_cap - payload_len
            if tail:
                mm[old_data_cell + 4 + payload_len:
                   old_data_cell + 4 + payload_len + tail] = b'\0' * tail
            w32(vk_data_len_off(vk), payload_len)
            data_writes += 1
            return
        # need a new cell. cell_size = 4 + payload rounded up to 8.
        need = payload_len + 4
        need = (need + 7) & ~7
        new_cell = alloc_cell(need)
        if new_cell is None:
            raise RuntimeError('no free cell; hive too tight (bug)')
        free_size = u32(new_cell)          # positive = free
        # split: used part = need, remaining free goes right after
        struct.pack_into('<i', mm, new_cell, -need)
        mm[new_cell + 4:new_cell + 4 + payload_len] = payload
        tail = need - 4 - payload_len
        if tail:
            mm[new_cell + 4 + payload_len:new_cell + need] = b'\0' * tail
        # if remainder >= 8, mark it free
        rem = free_size - need
        if rem >= 8:
            struct.pack_into('<i', mm, new_cell + need, rem)
            # zero leftover signature area of remainder
            mm[new_cell + need + 4:new_cell + need + min(8, rem)] = b'\0' * min(4, rem - 4)
        # update vk
        w32(vk_data_off_off(vk), new_cell - HBIN_BASE)
        w32(vk_data_len_off(vk), payload_len)
        # free the old data cell (if any)
        if old_data_cell is not None and old_data_cap > 0:
            struct.pack_into('<i', mm, old_data_cell, old_data_cap + 4)
        data_writes += 1

    for t in targets:
        for pid, newval in wanted.items():
            for vname, vk in t['pid_vk'].get(pid, []):
                assert vk_sig(vk) == b'vk'
                old_type = u32(vk_type_off(vk))
                if old_type != DEVPROP_STRING:
                    w32(vk_type_off(vk), DEVPROP_STRING)
                    type_fixes += 1
                # also rewrite data to target string
                write_string_data(vk, newval)
                print(f"    {t['subsys']}\\{t['inst']} pid={pid} name={vname!r} "
                      f"type 0x{old_type:08x}->0x{DEVPROP_STRING:08x}  data={newval!r}")

    print(f'  phase B: {type_fixes} type fixes, {data_writes} data writes')

    # ---- Phase C: sync regf sequence + checksum ----
    pri = u32(4); sec = u32(8)
    newseq = max(pri, sec)
    w32(4, newseq); w32(8, newseq)
    csum = 0
    for i in range(0, 0x1fc, 4):
        csum ^= u32(i)
    w32(0x1fc, csum)
    print(f'  phase C: sequence {pri}/{sec} -> {newseq}/{newseq}, '
          f'checksum 0x{csum:08x}')

    if DRY_RUN:
        print('DRY_RUN=1: not writing hive')
        return
    with open(HIVE, 'wb') as f:
        f.write(mm)
    print('hive written.')


if __name__ == '__main__':
    main()
PY

log "done"
