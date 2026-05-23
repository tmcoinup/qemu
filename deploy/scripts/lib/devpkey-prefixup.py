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
