#!/usr/bin/env bash
# build-uefi-chainload-helper.sh —— 造 deploy/firmware/uefi-shell-chainload.img
#
# 为什么需要：
#   Windows 10/11 ISO 的 El Torito UEFI image 描述符 Ldsiz=1 sector（512B），
#   OVMF 2.70 因此拒绝把 CDROM 当 auto-boot 候选 → 装系统时掉 UEFI Shell。
#   解决思路：挂一个 16 MiB FAT helper image 当 virtio-blk disk (bootindex=1)：
#     \EFI\BOOT\BOOTX64.EFI ← ChainLauncher.efi (OvmfPkg/Application/ChainLauncher)
#                              纯 EFI app, ~2KB, **零屏幕输出** —— 不打 banner /
#                              不打 mapping table, 直接 enumerate FS 找含
#                              \EFI\BOOT\BOOTX64.EFI 但不含 \HELPER.MARK 的卷,
#                              LoadImage + StartImage 跑 Win ISO BOOTX64.EFI.
#     \HELPER.MARK          ← marker, 让 ChainLauncher skip helper image 自己
#
#   原先用 EDK2 Shell.efi 也 work, 但 Shell 启动时即使 delay=0 仍会一闪显示
#   "UEFI Interactive Shell v2.2 / Mapping table / Press ESC..." banner, 用户
#   能看到加载页. ChainLauncher 是 silent loader, 用户看到的下一帧直接就是
#   Windows Setup 的 "Press any key to boot from CD or DVD..." prompt.
#
# 用法：
#   ./deploy/tools/build-uefi-chainload-helper.sh            # 输出到默认位置
#   OUT=/path/to.img ./deploy/tools/build-uefi-chainload-helper.sh
#
# 依赖：mtools (mcopy/mmd)、mkfs.vfat (dosfstools)、EDK2 build 出的 ChainLauncher.efi
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DEPLOY="$(cd "$HERE/.." && pwd)"
: "${OUT:=$DEPLOY/firmware/uefi-shell-chainload.img}"
: "${EDK2:=$HOME/src/edk2}"

# 寻找 ChainLauncher.efi (OvmfPkg/Application/ChainLauncher build 后)
SHELL_EFI=""
for cand in \
    "$EDK2/Build/OvmfX64/RELEASE_GCC5/X64/ChainLauncher.efi" \
    "$EDK2/Build/OvmfX64/DEBUG_GCC5/X64/ChainLauncher.efi" \
    "$EDK2/Build/OvmfX64/RELEASE_GCC5/X64/Shell.efi" \
    "$EDK2/Build/OvmfX64/DEBUG_GCC5/X64/Shell.efi"; do
    if [[ -f "$cand" ]]; then SHELL_EFI="$cand"; break; fi
done
if [[ -z "$SHELL_EFI" ]]; then
    echo "ERROR: 找不到 ChainLauncher.efi (或 fallback Shell.efi)。先 build OVMF " >&2
    echo "       (deploy/tools/build-ovmf.sh)，或设置 EDK2=/path/to/edk2。" >&2
    exit 1
fi
echo "[build-helper] using launcher: $(basename "$SHELL_EFI") ($(stat -c%s "$SHELL_EFI") bytes)"

command -v mcopy   >/dev/null || { echo "ERROR: 需要 mtools (apt install mtools)" >&2; exit 1; }
command -v mkfs.vfat >/dev/null || { echo "ERROR: 需要 dosfstools" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# marker 文件让 ChainLauncher 跑遍 FS 时能跳过 helper 自身 (这个 FS 上有
# \EFI\BOOT\BOOTX64.EFI = ChainLauncher 自己，不能 chainload 自己造死循环)。
echo "helper-marker" > "$TMP/HELPER.MARK"

rm -f "$OUT"
dd if=/dev/zero of="$OUT" bs=1M count=16 status=none
mkfs.vfat -F 16 -n UEFINSH "$OUT" >/dev/null
mmd -i "$OUT" ::/EFI ::/EFI/BOOT
mcopy -i "$OUT" "$SHELL_EFI" ::/EFI/BOOT/BOOTX64.EFI
mcopy -i "$OUT" "$TMP/HELPER.MARK" ::/HELPER.MARK

echo "built: $OUT ($(stat -c%s "$OUT") bytes)"
echo "contents:"
mdir -i "$OUT" ::/
mdir -i "$OUT" ::/EFI/BOOT
