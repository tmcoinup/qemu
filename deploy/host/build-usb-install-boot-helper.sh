#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
deploy_dir="$(cd "$here/.." && pwd)"
source_file="$deploy_dir/firmware/chainloader/ChainLauncher.c"
output_file="${1:-$deploy_dir/firmware/g11-usb-install-boot.img}"
edk2_dir="${EDK2_DIR:-$here/ovmf-build/edk2-2024.02}"
compiler="${MINGW_CC:-x86_64-w64-mingw32-gcc}"

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "缺少命令: $1" >&2
        exit 1
    }
}

require_command "$compiler"
require_command mkfs.vfat
require_command mmd
require_command mcopy
require_command truncate

[[ -r "$source_file" ]] || {
    echo "ChainLauncher 源码不可读: $source_file" >&2
    exit 1
}
[[ -r "$edk2_dir/MdePkg/Include/Uefi.h" ]] || {
    echo "EDK2 头文件不存在: $edk2_dir/MdePkg/Include/Uefi.h" >&2
    echo "请设置 EDK2_DIR，或先运行 ./deploy/host/build-stealth-ovmf.sh 准备源码。" >&2
    exit 1
}

work_dir="$(mktemp -d)"
cleanup() {
    rm -rf -- "$work_dir"
}
trap cleanup EXIT

# PE/FAT timestamps and the FAT volume ID are fixed so a clean rebuild can be
# compared byte-for-byte with the checked-in runtime asset.
export TZ=UTC
export SOURCE_DATE_EPOCH=1704067200

efi_file="$work_dir/BOOTX64.EFI"
object_file="$work_dir/ChainLauncher.o"
image_file="$work_dir/g11-usb-install-boot.img"

"$compiler" \
    -I"$edk2_dir/MdePkg/Include" \
    -I"$edk2_dir/MdePkg/Include/X64" \
    -std=c11 -O2 -Wall -Wextra -Werror \
    -ffreestanding -fno-builtin -fno-stack-protector \
    -fno-asynchronous-unwind-tables -fno-ident -fshort-wchar -mno-red-zone \
    -c "$source_file" -o "$object_file"

"$compiler" \
    -nostdlib -shared \
    -Wl,--subsystem,10,--entry,UefiMain,--no-insert-timestamp,--image-base,0x10000000 \
    "$object_file" -o "$efi_file"

touch -d "@$SOURCE_DATE_EPOCH" "$efi_file"

truncate -s 16M "$image_file"
mkfs.vfat --invariant -F 16 -n G11INSTALL "$image_file" >/dev/null
mmd -i "$image_file" ::/EFI ::/EFI/BOOT
mcopy -i "$image_file" "$efi_file" ::/EFI/BOOT/BOOTX64.EFI
touch -t 202401010000 "$work_dir/HELPER.MARK"
mcopy -i "$image_file" "$work_dir/HELPER.MARK" ::/HELPER.MARK

mkdir -p "$(dirname "$output_file")"
install -m 0644 "$image_file" "$output_file"

echo "已生成: $output_file"
sha256sum "$output_file"
