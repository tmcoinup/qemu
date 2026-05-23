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
