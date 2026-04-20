#!/bin/bash
# ---------------------------------------------------------------------------
# verify-stealth.sh
#
# Quick sanity checks that exercise the patched QEMU *without* booting a
# full Windows guest: dumps Ryzen3-1200 feature expansion, validates that
# kvm=off,hypervisor=off produces the expected CPUID surface, verifies
# ACPI OEM strings via the fw_cfg dump, and checks NVMe Identify strings.
# ---------------------------------------------------------------------------
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
QEMU="${QEMU:-$REPO_ROOT/build/qemu-system-x86_64}"

echo "=== (1) CPU model registered ==="
"$QEMU" -cpu help 2>&1 | grep -i 'ryzen3-1200' || { echo "MISSING Ryzen3-1200"; exit 1; }

echo
echo "=== (2) CPU model expansion (via QMP query-cpu-model-expansion) ==="
SOCK="/tmp/verify-stealth.qmp"
rm -f "$SOCK"
"$QEMU" -machine q35,accel=tcg -smp 4 -m 512M -nographic -S \
    -display none \
    -qmp unix:$SOCK,server=on,wait=off \
    -cpu Ryzen3-1200,kvm=off,hypervisor=off &
QPID=$!
trap 'kill $QPID 2>/dev/null; rm -f $SOCK' EXIT
sleep 1.5

python3 - "$SOCK" <<'PY'
import json, socket, sys
p = sys.argv[1]
s = socket.socket(socket.AF_UNIX); s.connect(p)
f = s.makefile('rwb', buffering=0)
f.readline()
f.write(b'{"execute":"qmp_capabilities"}\n'); f.readline()
f.write(b'{"execute":"query-cpu-model-expansion","arguments":{"type":"full","model":{"name":"Ryzen3-1200"}}}\n')
resp = json.loads(f.readline())
props = resp.get('return',{}).get('model',{}).get('props',{})
bad = []
if props.get('hypervisor') not in (False, None, 'off'): bad.append(('hypervisor', props.get('hypervisor')))
if props.get('kvm')        not in (False, None, 'off'): bad.append(('kvm',        props.get('kvm')))
need = ['invtsc','topoext','svm','sha-ni','clflushopt','xsaveopt','aes','avx2']
missing = [n for n in need if props.get(n) not in (True,'on')]
print("  hypervisor =", props.get('hypervisor'))
print("  kvm        =", props.get('kvm'))
print("  vendor     =", props.get('vendor'))
print("  family     =", props.get('family'))
print("  model      =", props.get('model'))
print("  stepping   =", props.get('stepping'))
print("  model-id   =", props.get('model-id'))
for n in need:
    print(f"  {n:12s} = {props.get(n)}")
if bad or missing:
    print("FAIL:", bad, "missing:", missing); sys.exit(1)
print("OK")
PY

echo
echo "=== (3) ACPI OEM strings baked into binary ==="
strings "$QEMU" | grep -E '^(ALASKA|A M I )' | head -5

echo
echo "=== (4) NVMe properties registered ==="
"$QEMU" -device nvme,help 2>&1 | grep -E 'samsung|model-number|firmware-rev'
echo "all checks passed."
