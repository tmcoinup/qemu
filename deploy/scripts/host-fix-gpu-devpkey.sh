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
# Prereqs (apt): qemu-utils, ntfs-3g, python3-hivex
#
# Usage:
#   sudo deploy/scripts/host-fix-gpu-devpkey.sh <INSTANCE> [--dry-run]
#
# Must be run as root (it does qemu-nbd / ntfsfix / mount). If the VM is
# still running, it will invoke stop-vm.sh (as the original user) first.
#
# Environment overrides:
#   DISK=<path>           default /home/ubuntu/images/vms/<N>/disk.qcow2
#                         (auto-falls back to legacy win10-inst<N>.qcow2 layout)
#   NBD=/dev/nbdN         default /dev/nbd0
#   MOUNT=<path>          default /mnt/win10-inst<N>
#   PROVIDER=<string>     default "NVIDIA"            (pid 0009 value)
#   DEVICE_DESC=<string>  default "NVIDIA GeForce GTX 1050"  (pid 0004 value)
#   SUBSYS_RE=<regex>     default '^VEN_1AF4&DEV_1050'
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

# 默认走 hardware pools v2 新布局；旧 win10-inst<N>.qcow2 还在的话回退过去。
if [[ -z "${DISK:-}" ]]; then
    if [[ -f "/home/ubuntu/images/vms/${INSTANCE}/disk.qcow2" ]]; then
        DISK="/home/ubuntu/images/vms/${INSTANCE}/disk.qcow2"
    else
        DISK="/home/ubuntu/images/win10-inst${INSTANCE}.qcow2"
    fi
fi
: "${NBD:=/dev/nbd0}"
: "${MOUNT:=/mnt/win10-inst${INSTANCE}}"
: "${PROVIDER:=NVIDIA}"
: "${DEVICE_DESC:=NVIDIA GeForce GTX 1050}"
: "${SUBSYS_RE:=^VEN_1AF4&DEV_1050}"

log() { printf '[fix-devpkey] %s\n' "$*"; }
die() { log "ERROR: $*"; exit 1; }

[[ -f "$DISK" ]] || die "disk not found: $DISK"
command -v qemu-nbd >/dev/null || die "need apt: qemu-utils"
command -v ntfsfix  >/dev/null || die "need apt: ntfs-3g"
python3 -c 'import hivex' 2>/dev/null || die "need apt: python3-hivex"

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
mount -t ntfs-3g -o rw,remove_hiberfile "$SYSPART" "$MOUNT"

HIVE="${MOUNT}/Windows/System32/config/SYSTEM"
[[ -f "$HIVE" ]] || die "SYSTEM hive not found at $HIVE"

# 3) Run the embedded Python patcher.
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
        sys.exit('ControlSet001\\Enum\\PCI not found')

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
