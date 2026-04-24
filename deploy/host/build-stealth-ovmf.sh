#!/usr/bin/env bash
#
# build-stealth-ovmf.sh — 把 Ubuntu ovmf 源码里的 PcdFirmwareVendor 改成
# "American Megatrends Inc." 并重建，产出 host/OVMF_CODE_4M_stealth.fd。
#
# 首次需 ~8 分钟 build。重运行不会重复 apt-get source，若工作树已在就 rebuild。
#
# 依赖：
#   - apt-get build-dep edk2  (首次自动装)
#   - deb-src 源已打开  (/etc/apt/sources.list.d/deb-src.sources)
#
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
HOST_DIR="$(pwd)"

WORK=ovmf-build
SRC_DIR=""
mkdir -p "$WORK"
cd "$WORK"

# 1) apt-get source edk2 如果还没下过
if ! ls edk2-*/debian/rules 2>/dev/null | head -1 > /dev/null; then
    echo "[build] apt-get source edk2 (~25 MB)"
    apt-get source edk2
fi
SRC_DIR=$(ls -d edk2-*/ | head -1 | sed 's#/$##')
cd "$SRC_DIR"
echo "[build] source tree: $(pwd)"

# 2) apply our stealth patch (idempotent via grep check)
if grep -q 'American Megatrends Inc.' debian/rules; then
    echo "[build] debian/rules already patched — skip"
else
    echo "[build] applying ovmf-stealth.patch"
    patch -p1 < "$HOST_DIR/ovmf-stealth.patch"
fi

# 3) build-dep
if ! dpkg -s edk2-dev >/dev/null 2>&1; then
    echo "[build] installing build deps"
    sudo apt-get build-dep -y edk2
fi

# 4) build only ovmf (skip aarch64/riscv64, they're slow and unused)
echo "[build] dpkg-buildpackage --target build-ovmf"
dpkg-buildpackage -us -uc -b --target build-ovmf

# 5) stage the fd
OUT=debian/ovmf-install/OVMF_CODE_4M.fd
if [[ ! -f "$OUT" ]]; then
    echo "[build] ERROR: expected $OUT not produced"; exit 1
fi
DST="$HOST_DIR/OVMF_CODE_4M_stealth.fd"
cp "$OUT" "$DST"
echo "[build] installed: $DST"
ls -la "$DST"

cat <<EOF
Done.  Now run from deploy/:
    STEALTH_OVMF=1 ./up.sh --connect
Verify in guest:
    Get-ItemProperty 'HKLM:\\HARDWARE\\DESCRIPTION\\System' SystemBiosVersion
should show "American Megatrends Inc. - 10000" in the list (not "Ubuntu ...").
EOF
