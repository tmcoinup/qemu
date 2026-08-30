#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
deploy_dir="$(cd "$here/.." && pwd)"
image="$deploy_dir/firmware/g11-usb-install-boot.img"
expected_image_sha256="7f16e46360c7774e5c426f2ad2c0d51a3a4fb7d5bf0372791fa9dd7ee15d60c1"
expected_efi_sha256="c25165f2098c782a81e8372eebf5cbe3cc6b5df00d6eee2ee4d7415371b95574"

for dependency in sha256sum stat mdir mcopy file; do
    command -v "$dependency" >/dev/null 2>&1 || {
        echo "缺少校验命令: $dependency" >&2
        exit 1
    }
done

[[ -f "$image" && ! -L "$image" && -r "$image" ]] || {
    echo "helper 镜像缺失或不安全: $image" >&2
    exit 1
}
[[ "$(stat -c %s -- "$image")" == 16777216 ]] || {
    echo "helper 镜像必须恰好为 16 MiB" >&2
    exit 1
}

actual_image_sha256=$(sha256sum "$image")
actual_image_sha256=${actual_image_sha256%% *}
[[ "$actual_image_sha256" == "$expected_image_sha256" ]] || {
    echo "helper 镜像 SHA-256 不匹配: $actual_image_sha256" >&2
    exit 1
}

expected_entries=$'::/EFI/\n::/HELPER.MARK\n::/EFI/BOOT/\n::/EFI/BOOT/BOOTX64.EFI'
actual_entries=$(mdir -b -s -i "$image" ::)
[[ "$actual_entries" == "$expected_entries" ]] || {
    echo "helper FAT 文件清单不符合合同:" >&2
    printf '%s\n' "$actual_entries" >&2
    exit 1
}

work_dir="$(mktemp -d)"
cleanup() {
    rm -rf -- "$work_dir"
}
trap cleanup EXIT

efi_file="$work_dir/BOOTX64.EFI"
mcopy -i "$image" ::/EFI/BOOT/BOOTX64.EFI "$efi_file"
actual_efi_sha256=$(sha256sum "$efi_file")
actual_efi_sha256=${actual_efi_sha256%% *}
[[ "$actual_efi_sha256" == "$expected_efi_sha256" ]] || {
    echo "内嵌 BOOTX64.EFI SHA-256 不匹配: $actual_efi_sha256" >&2
    exit 1
}
LC_ALL=C file "$efi_file" | grep -Fq 'PE32+ executable (DLL) (EFI application) x86-64' || {
    echo "内嵌 BOOTX64.EFI 不是 x86_64 UEFI application" >&2
    exit 1
}

echo "OK: G-11 USB install helper source-built asset verified"
