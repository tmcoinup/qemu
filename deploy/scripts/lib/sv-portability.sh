# ---------------------------------------------------------------------------
# Host portability preflight.
#
# 目标：迁移到不同 host 时允许路径/QEMU 二进制可配置，但绝不静默降级真机画像。
# 如果误用系统自带 stock QEMU，很多 stealth 属性会变成 unknown property；
# 更糟的是如果脚本改成 fallback，会让 guest 看到 Red Hat NVMe / 默认 EDID /
# 默认 USB HID。这里默认 fail-fast，并给出明确修复入口。
# ---------------------------------------------------------------------------

_sv_die_missing_qemu_feature() {
    local what="$1"

    echo "ERROR: 当前 QEMU 缺少必要 stealth 能力: $what" >&2
    echo "       QEMU=$QEMU" >&2
    echo "       请在此 host 使用本仓库编译的 build/qemu-system-x86_64，" >&2
    echo "       或显式 QEMU=/path/to/patched/qemu-system-x86_64。" >&2
    echo "       若只是做非隐身调试，可设 QEMU_CAP_CHECK=0 跳过本检查。" >&2
    exit 1
}

_sv_qemu_help_has_all() {
    local help="$1"
    shift
    local prop

    for prop in "$@"; do
        grep -q -- "$prop" <<<"$help" || return 1
    done
    return 0
}

_sv_qemu_device_help() {
    local dev="$1"

    "$QEMU" -device "$dev,help" 2>&1
}

_sv_check_qemu_caps() {
    local help

    [[ "${QEMU_CAP_CHECK:-1}" == "1" ]] || return 0

    [[ -x "$QEMU" ]] || {
        echo "ERROR: QEMU 不存在或不可执行: $QEMU" >&2
        echo "       迁移 host 后先跑 deploy/tools/build.sh，或传 QEMU=/path/to/qemu。" >&2
        exit 1
    }
    [[ -x "$QEMU_IMG" ]] || {
        echo "ERROR: qemu-img 不存在或不可执行: $QEMU_IMG" >&2
        echo "       迁移 host 后先跑 deploy/tools/build.sh，或传 QEMU_IMG=/path/to/qemu-img。" >&2
        exit 1
    }

    help="$(_sv_qemu_device_help nvme)"
    _sv_qemu_help_has_all "$help" \
        'use-samsung-id=' 'model-number=' 'firmware-rev=' \
        || _sv_die_missing_qemu_feature "nvme Samsung identity/model/firmware 属性"

    help="$(_sv_qemu_device_help virtio-vga)"
    _sv_qemu_help_has_all "$help" \
        'edid-vendor=' 'edid-name=' 'edid-serial=' \
        'edid-width-mm=' 'edid-height-mm=' \
        'x-pci-sub-vendor-id=' 'x-pci-sub-device-id=' \
        || _sv_die_missing_qemu_feature "virtio-vga EDID / PCI subsystem 属性"

    if [[ "${SDL:-0}" == "1" && "${STABLE_DISPLAY:-0}" != "1" ]]; then
        help="$(_sv_qemu_device_help virtio-vga-gl)"
        _sv_qemu_help_has_all "$help" \
            'edid-vendor=' 'edid-name=' 'edid-serial=' \
            'edid-width-mm=' 'edid-height-mm=' \
            || _sv_die_missing_qemu_feature "virtio-vga-gl EDID 属性"
    fi

    for _dev in usb-kbd usb-mouse usb-tablet; do
        help="$(_sv_qemu_device_help "$_dev")"
        _sv_qemu_help_has_all "$help" \
            'vendorid=' 'productid=' 'manufacturer=' 'product=' \
            || _sv_die_missing_qemu_feature "$_dev USB 身份属性"
    done

    help="$(_sv_qemu_device_help pcie-root-port)"
    _sv_qemu_help_has_all "$help" \
        'x-pci-vendor-id=' 'x-pci-device-id=' 'x-pci-revision=' \
        'x-speed=' 'x-width=' \
        || _sv_die_missing_qemu_feature "pcie-root-port 平台 ID / 链路属性"

    help="$(_sv_qemu_device_help qemu-xhci)"
    _sv_qemu_help_has_all "$help" \
        'x-pci-vendor-id=' 'x-pci-device-id=' 'x-pci-revision=' \
        || _sv_die_missing_qemu_feature "qemu-xhci 平台 ID 属性"

    if [[ "${FB_SHM:-1}" == "1" ]]; then
        help="$("$QEMU" -object help 2>&1)"
        _sv_qemu_help_has_all "$help" 'fb-shm' 'memory-backend-memfd' \
            || _sv_die_missing_qemu_feature "fb-shm / memfd object"
    fi

    echo ">> portability: QEMU stealth 能力检查通过"
}

_sv_check_qemu_caps
