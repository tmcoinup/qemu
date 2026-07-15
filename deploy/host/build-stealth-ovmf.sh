#!/usr/bin/env bash
#
# build-stealth-ovmf.sh — 构建 root deploy 启动器使用的 OVMF：
#   1. 把 PcdFirmwareVendor 改成 "American Megatrends Inc."；
#   2. backport edk2 early-MTRR，避免挂 mdev 时主 FV LZMA 解压卡约 80s；
#   3. 补齐 TcgMor、Hash2DxeCrypto 和通用 RngDxe 安全模块。
#
# 首次需约 2–4 分钟。重运行不会重复 apt-get source，但会干净重建 X64 OVMF。
#
# 依赖：
#   - apt-get build-dep edk2  (首次自动装)
#   - deb-src 源已打开  (/etc/apt/sources.list.d/deb-src.sources)
#
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
HOST_DIR="$(pwd)"
VERIFY_SCRIPT="$HOST_DIR/verify-ovmf-security-modules.sh"

if [[ ! -x "$VERIFY_SCRIPT" ]]; then
    echo "[build] ERROR: missing executable verifier: $VERIFY_SCRIPT" >&2
    exit 1
fi
if ! command -v virt-fw-dump >/dev/null 2>&1; then
    echo "[build] ERROR: virt-fw-dump is required (Ubuntu package: python3-virt-firmware)" >&2
    exit 1
fi

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

if grep -q 'SecMtrrSetup' OvmfPkg/Sec/SecMain.c; then
    echo "[build] mdev early-MTRR patch already applied — skip"
else
    echo "[build] applying ovmf-mdev-fastboot.patch"
    # edk2 sources use CRLF; --binary keeps the patch context CRLF.
    patch --binary -p1 < "$HOST_DIR/ovmf-mdev-fastboot.patch"
fi

# edk2 2024.02 的 X64 DSC/FDF 尚未装入这些通用安全模块。补丁保留
# VirtioRngDxe，并按后续 upstream OVMF 的做法给通用 RngDxe 绑定 CPU
# BaseRngLib。源码是 CRLF，因此 patch 必须使用 --binary。
SECURITY_PATCH="$HOST_DIR/ovmf-security-modules.patch"
security_components=(
    SecurityPkg/Tcg/MemoryOverwriteControl/TcgMor.inf
    SecurityPkg/Hash2DxeCrypto/Hash2DxeCrypto.inf
    SecurityPkg/RandomNumberGenerator/RngDxe/RngDxe.inf
)
security_entries=0
for component in "${security_components[@]}"; do
    if grep -Fq "$component" OvmfPkg/OvmfPkgX64.dsc; then
        security_entries=$((security_entries + 1))
    fi
    if grep -Fq "$component" OvmfPkg/OvmfPkgX64.fdf; then
        security_entries=$((security_entries + 1))
    fi
done
expected_security_entries=$((${#security_components[@]} * 2))

if ((security_entries == expected_security_entries)); then
    echo "[build] OVMF security modules patch already applied — skip"
elif ((security_entries != 0)); then
    echo "[build] ERROR: partial OVMF security modules patch ($security_entries/$expected_security_entries entries)" >&2
    echo "[build]        check OvmfPkgX64.dsc/fdf for a conflicting edit" >&2
    exit 1
elif patch --binary --batch --dry-run --fuzz=0 -p1 < "$SECURITY_PATCH" >/dev/null 2>&1; then
    echo "[build] applying ovmf-security-modules.patch"
    patch --binary --batch --forward --fuzz=0 -p1 < "$SECURITY_PATCH"
else
    echo "[build] ERROR: OVMF security modules patch does not apply cleanly" >&2
    echo "[build]        check that the source is the expected edk2 2024.02 tree" >&2
    exit 1
fi

for component in "${security_components[@]}"; do
    if ! grep -Fq "$component" OvmfPkg/OvmfPkgX64.dsc ||
       ! grep -Fq "$component" OvmfPkg/OvmfPkgX64.fdf; then
        echo "[build] ERROR: security component is not wired into both DSC and FDF: $component" >&2
        exit 1
    fi
done

# 3) build-dep。edk2-dev 是本源码包的产物，不是 build-dep，不能拿它
# 判断依赖是否齐全；dpkg-checkbuilddeps 会按 debian/control 精确检查。
if ! dpkg-checkbuilddeps >/dev/null 2>&1; then
    echo "[build] installing build deps"
    sudo apt-get build-dep -y edk2
fi

# 4) 只构建实际使用的 X64/4M/RELEASE 固件。debian 的 build-ovmf target
# 会连 secureboot/legacy/amdsev 变体一起构建，而且旧产物存在时可能直接
# 判定 up-to-date；这里显式 clean 后调用 edk2 build，保证源码补丁进固件。
echo "[build] clean X64 OVMF build"
make -f debian/rules debian/setup-build-stamp
rm -rf Build/OvmfX64
unset WORKSPACE ECP_SOURCE EDK_SOURCE EFI_SOURCE EDK_TOOLS_PATH CONF_PATH
export PYTHON3_ENABLE=TRUE
set +u
# shellcheck source=/dev/null
source ./edksetup.sh >/dev/null
set -u

build_args=(
    -a X64
    -t GCC5
    -p OvmfPkg/OvmfPkgX64.dsc
    -DCC_MEASUREMENT_ENABLE=TRUE
    -DNETWORK_HTTP_BOOT_ENABLE=TRUE
    -DNETWORK_IP6_ENABLE=TRUE
    -DNETWORK_TLS_ENABLE
    --pcd 'PcdFirmwareVendor=LAmerican Megatrends Inc.\0'
    --pcd 'PcdFirmwareVersionString=LV3.20\0'
    --pcd 'PcdFirmwareReleaseDateString=L04/25/2018\0'
    -DTPM2_ENABLE=TRUE
    -DFD_SIZE_4MB
    -b RELEASE
    -n "$(nproc)"
)
echo "[build] edk2 X64 OVMF RELEASE"
build "${build_args[@]}"

# 5) Verify the actual firmware volume, then stage it atomically. A failed
# security-module check leaves the previously installed firmware untouched.
OUT=Build/OvmfX64/RELEASE_GCC5/FV/OVMF_CODE.fd
if [[ ! -f "$OUT" ]]; then
    echo "[build] ERROR: expected $OUT not produced"; exit 1
fi
DST="$HOST_DIR/OVMF_CODE_4M_stealth.fd"
TMP_DST=$(mktemp "${DST}.tmp.XXXXXX")
trap 'rm -f "$TMP_DST"' EXIT
install -m 0644 "$OUT" "$TMP_DST"
"$VERIFY_SCRIPT" "$TMP_DST"
mv -f "$TMP_DST" "$DST"
trap - EXIT
echo "[build] installed: $DST"
ls -la "$DST"
sha256sum "$DST"

cat <<EOF
Done.  Now run from deploy/:
    ./start-vm.sh 1
Verify in guest:
    Get-ItemProperty 'HKLM:\\HARDWARE\\DESCRIPTION\\System' SystemBiosVersion
should show "American Megatrends Inc. - 10000" in the list (not "Ubuntu ...").
EOF
