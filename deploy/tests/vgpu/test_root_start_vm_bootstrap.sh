#!/usr/bin/env bash
# Exercise start-vm.sh's intent-aware first-start bootstrap entirely under a
# temporary VM_ROOT.  No real qemu process, mdev, TPM, or production image is
# touched.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
START_VM="$REPO_ROOT/deploy/start-vm.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

require_text() {
    local needle=$1 file=$2
    grep -F -- "$needle" "$file" >/dev/null || \
        fail "missing '$needle' in $(basename "$file")"
}

reject_text() {
    local needle=$1 file=$2
    if grep -F -- "$needle" "$file" >/dev/null; then
        fail "unexpected '$needle' in $(basename "$file")"
    fi
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT

touch "$TMP_DIR/OVMF_CODE.fd" "$TMP_DIR/OVMF_VARS.fd"

cat >"$TMP_DIR/qemu-img" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_QEMU_IMG_TRACE"
record_size() {
    local image=$1 size=$2 base=${1##*/}
    printf '%s\n' "$size" >"$image.size"
    # create-disk atomically renames only the real qcow2.  Mirror its final
    # metadata path in this fake; real qemu-img stores virtual-size in-image.
    if [[ "$base" == .disk.qcow2.partial.* ]]; then
        printf '%s\n' "$size" >"${image%/*}/disk.qcow2.size"
    fi
}
case "$1" in
    create)
        target=${@: -2:1}
        size=${@: -1}
        mkdir -p "$(dirname "$target")"
        : >"$target"
        record_size "$target" "$size"
        ;;
    resize)
        image=$2
        size=$3
        [[ -f "$image" ]]
        record_size "$image" "$size"
        ;;
    check)
        [[ -f "${@: -1}" ]]
        ;;
    info)
        image=${@: -1}
        [[ -f "$image" ]]
        size=500000000000
        [[ ! -f "$image.size" ]] || size=$(<"$image.size")
        if [[ " $* " == *' --output=json '* ]]; then
            printf '{"format":"qcow2","virtual-size":%s,"backing-filename":null,"full-backing-filename":null,"format-specific":{"data":{}}}\n' "$size"
        else
            printf 'image: %s\nfile format: qcow2\nvirtual size: %s\n' "$image" "$size"
        fi
        ;;
    *)
        echo "unexpected fake qemu-img invocation: $*" >&2
        exit 99
        ;;
esac
EOF
chmod +x "$TMP_DIR/qemu-img"

cat >"$TMP_DIR/qemu-system-x86_64" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >>"$FAKE_QEMU_TRACE"
printf '\n' >>"$FAKE_QEMU_TRACE"
EOF
chmod +x "$TMP_DIR/qemu-system-x86_64"

cat >"$TMP_DIR/xorriso" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >>"$FAKE_XORRISO_TRACE"
printf '\n' >>"$FAKE_XORRISO_TRACE"
output=""
while (( $# > 0 )); do
    if [[ "$1" == -o && $# -ge 2 ]]; then
        output=$2
        break
    fi
    shift
done
[[ -n "$output" ]] || { echo "fake xorriso: missing -o" >&2; exit 99; }
input=${@: -1}
[[ -f "$input/Autounattend.xml" ]] || {
    echo "fake xorriso: missing Autounattend.xml in $input" >&2
    exit 99
}
printf '%s\n' "$input/Autounattend.xml" >>"$FAKE_XORRISO_TRACE"
printf 'fake-answer-iso\n' >"$output"
EOF
chmod +x "$TMP_DIR/xorriso"

run_start() {
    local vm_root=$1 vm_id=$2 output=$3 error=$4
    shift 4
    : >"$TMP_DIR/qemu-img.trace"
    : >"$TMP_DIR/qemu.trace"
    : >"$TMP_DIR/xorriso.trace"
    env -i \
        HOME="${HOME:-/tmp}" \
        PATH=/usr/bin:/bin \
        LANG=en_US.utf8 \
        DISPLAY=:99 \
        IMAGE_ROOT="$TMP_DIR" \
        VM_ROOT="$vm_root" \
        QEMU_IMG="$TMP_DIR/qemu-img" \
        QEMU_BIN="$TMP_DIR/qemu-system-x86_64" \
        XORRISO="$TMP_DIR/xorriso" \
        OVMF_CODE="$TMP_DIR/OVMF_CODE.fd" \
        OVMF_VARS="$TMP_DIR/OVMF_VARS.fd" \
        TPM=0 \
        MEM_GUARD=0 \
        REPAIR_DISPLAY_VARS=off \
        FAKE_QEMU_IMG_TRACE="$TMP_DIR/qemu-img.trace" \
        FAKE_QEMU_TRACE="$TMP_DIR/qemu.trace" \
        FAKE_XORRISO_TRACE="$TMP_DIR/xorriso.trace" \
        "$START_VM" "$vm_id" --no-monitor-sync "$@" \
        >"$output" 2>"$error"
}

# --install must create a blank image even when a qualified public base exists.
INSTALL_ROOT="$TMP_DIR/install-vms"
INSTALL_ID=910001
mkdir -p "$INSTALL_ROOT/shared/bases"
printf 'base-must-not-be-copied\n' >"$INSTALL_ROOT/shared/bases/win10-base.qcow2"
printf 'windows-iso\n' >"$TMP_DIR/windows.iso"
run_start "$INSTALL_ROOT" "$INSTALL_ID" \
    "$TMP_DIR/install.out" "$TMP_DIR/install.err" \
    --install "$TMP_DIR/windows.iso"
INSTALL_DISK="$INSTALL_ROOT/vm${INSTALL_ID}/disk.qcow2"
[[ -f "$INSTALL_ROOT/vm${INSTALL_ID}/vm.conf" ]] || \
    fail "install bootstrap did not create vm.conf"
[[ -f "$INSTALL_DISK" ]] || fail "install bootstrap did not create a disk"
[[ ! -s "$INSTALL_DISK" ]] || fail "install bootstrap copied the public base"
require_text 'create -f qcow2' "$TMP_DIR/qemu-img.trace"
require_text "$TMP_DIR/windows.iso" "$TMP_DIR/qemu.trace"
require_text 'id=odd0' "$TMP_DIR/qemu.trace"
require_text 'media=cdrom' "$TMP_DIR/qemu.trace"
require_text 'ide-cd\,drive=odd0' "$TMP_DIR/qemu.trace"
require_text 'bootindex=1' "$TMP_DIR/qemu.trace"
require_text 'id=answer0' "$TMP_DIR/qemu.trace"
require_text 'bus=ide.2' "$TMP_DIR/qemu.trace"
require_text 'autounattend.iso' "$TMP_DIR/qemu.trace"
require_text 'Autounattend.xml' "$TMP_DIR/xorriso.trace"
require_text 'Administrator 空密码 / China Standard Time / NumLock on' \
    "$TMP_DIR/install.out"
require_text '手动安装: 产品密钥 / Windows 版本 / 目标磁盘与分区' \
    "$TMP_DIR/install.out"
require_text '安装模式自动创建空盘' "$TMP_DIR/install.out"
require_text '  键盘:' "$TMP_DIR/install.out"
require_text '  鼠标:' "$TMP_DIR/install.out"
require_text 'KBD_PRODUCT=' \
    "$INSTALL_ROOT/vm${INSTALL_ID}/vm.conf"
require_text 'TABLET_PRODUCT=' \
    "$INSTALL_ROOT/vm${INSTALL_ID}/vm.conf"
require_text 'XHCI_PCI_VENDOR_ID=0x8086' \
    "$INSTALL_ROOT/vm${INSTALL_ID}/vm.conf"
require_text 'XHCI_PCI_DEVICE_ID=0x' \
    "$INSTALL_ROOT/vm${INSTALL_ID}/vm.conf"
require_text 'XHCI_PCI_REVISION=0x01' \
    "$INSTALL_ROOT/vm${INSTALL_ID}/vm.conf"
require_text 'XHCI_PCI_BUS=pcie.0' \
    "$INSTALL_ROOT/vm${INSTALL_ID}/vm.conf"
require_text 'XHCI_PCI_ADDR=0x6' \
    "$INSTALL_ROOT/vm${INSTALL_ID}/vm.conf"
reject_text '旧 vm.conf 缺少 xHCI PCI identity' "$TMP_DIR/install.err"
require_text 'usb-kbd\,bus=xhci.0\,vendorid=0x' "$TMP_DIR/qemu.trace"
require_text 'usb-tablet\,bus=xhci.0\,vendorid=0x' "$TMP_DIR/qemu.trace"
require_text 'x-pci-revision=0x01' "$TMP_DIR/qemu.trace"
require_text 'i8042=off' "$TMP_DIR/qemu.trace"
require_text '-rtc base=localtime\,clock=host\,driftfix=slew' "$TMP_DIR/qemu.trace"
require_text 'kvm-pit.lost_tick_policy=delay' "$TMP_DIR/qemu.trace"
require_text 'RTC_CONTRACT=localtime' \
    "$INSTALL_ROOT/vm${INSTALL_ID}/vm.conf"

# Stable mdev identity requires VM_UUID uniqueness across instance configs.
DUPLICATE_ID=910099
mkdir -p "$INSTALL_ROOT/vm${DUPLICATE_ID}"
cp "$INSTALL_ROOT/vm${INSTALL_ID}/vm.conf" \
    "$INSTALL_ROOT/vm${DUPLICATE_ID}/vm.conf"
if run_start "$INSTALL_ROOT" "$INSTALL_ID" \
        "$TMP_DIR/duplicate-uuid.out" "$TMP_DIR/duplicate-uuid.err" \
        --dry-run --no-gpu; then
    fail "start-vm accepted duplicate stable VM_UUID values"
fi
require_text '重复 VM_UUID=' "$TMP_DIR/duplicate-uuid.err"
rm -rf -- "$INSTALL_ROOT/vm${DUPLICATE_ID}"

# An existing qcow2 whose virtual size no longer matches the immutable SSD
# identity must fail before QEMU starts.
install_size=$(<"$INSTALL_DISK.size")
printf '12345\n' >"$INSTALL_DISK.size"
if run_start "$INSTALL_ROOT" "$INSTALL_ID" \
        "$TMP_DIR/capacity-mismatch.out" "$TMP_DIR/capacity-mismatch.err" \
        --install "$TMP_DIR/windows.iso"; then
    fail "start-vm accepted a qcow2/profile virtual-size mismatch"
fi
require_text '磁盘容量与硬件 profile 不一致' \
    "$TMP_DIR/capacity-mismatch.err"
[[ ! -s "$TMP_DIR/qemu.trace" ]] || \
    fail "capacity mismatch still launched QEMU"
printf '%s\n' "$install_size" >"$INSTALL_DISK.size"

# --install never replaces an existing disk; it only attaches the ISO.
printf 'existing-disk-marker\n' >"$INSTALL_DISK"
run_start "$INSTALL_ROOT" "$INSTALL_ID" \
    "$TMP_DIR/install-existing.out" "$TMP_DIR/install-existing.err" \
    --install "$TMP_DIR/windows.iso"
grep -Fxq 'existing-disk-marker' "$INSTALL_DISK" || \
    fail "--install overwrote an existing instance disk"
if grep -Fq 'create -f qcow2' "$TMP_DIR/qemu-img.trace"; then
    fail "--install recreated an existing instance disk"
fi
require_text 'id=answer0' "$TMP_DIR/qemu.trace"

# The explicit manual-OOBE escape hatch keeps the Windows installer fully
# interactive and must not build or attach the answer medium.
MANUAL_ROOT="$TMP_DIR/manual-vms"
MANUAL_ID=910010
mkdir -p "$MANUAL_ROOT/shared/bases"
printf 'base-must-not-be-copied\n' >"$MANUAL_ROOT/shared/bases/win10-base.qcow2"
run_start "$MANUAL_ROOT" "$MANUAL_ID" \
    "$TMP_DIR/manual.out" "$TMP_DIR/manual.err" \
    --install "$TMP_DIR/windows.iso" --manual-oobe
if grep -Fq 'id=answer0' "$TMP_DIR/qemu.trace"; then
    fail "--manual-oobe still attached the answer ISO"
fi
[[ ! -s "$TMP_DIR/xorriso.trace" ]] || \
    fail "--manual-oobe still invoked xorriso"
require_text '手动 OOBE' "$TMP_DIR/manual.out"

# Omitting the ISO argument resolves IMAGE_ROOT/iso/win10.iso and keeps the
# same blank-disk guarantee.
DEFAULT_ROOT="$TMP_DIR/default-vms"
DEFAULT_ID=910004
mkdir -p "$DEFAULT_ROOT/shared/bases" "$TMP_DIR/iso"
printf 'base-must-not-be-copied\n' >"$DEFAULT_ROOT/shared/bases/win10-base.qcow2"
printf 'default-windows-iso\n' >"$TMP_DIR/iso/win10.iso"
run_start "$DEFAULT_ROOT" "$DEFAULT_ID" \
    "$TMP_DIR/default.out" "$TMP_DIR/default.err" --install
[[ ! -s "$DEFAULT_ROOT/vm${DEFAULT_ID}/disk.qcow2" ]] || \
    fail "default-ISO install bootstrap copied the public base"
require_text "$TMP_DIR/iso/win10.iso" "$TMP_DIR/qemu.trace"

# A bad ISO fails before a disk is published; correcting the path and retrying
# can reuse the generated immutable identity.
BAD_ISO_ROOT="$TMP_DIR/bad-iso-vms"
BAD_ISO_ID=910009
if run_start "$BAD_ISO_ROOT" "$BAD_ISO_ID" \
        "$TMP_DIR/bad-iso.out" "$TMP_DIR/bad-iso.err" \
        --install "$TMP_DIR/missing.iso"; then
    fail "install bootstrap accepted a missing ISO"
fi
require_text 'ISO 不存在' "$TMP_DIR/bad-iso.err"
[[ ! -e "$BAD_ISO_ROOT/vm${BAD_ISO_ID}/disk.qcow2" ]] || \
    fail "missing ISO still published a blank disk"

# A normal first start must clone the public base and must not invoke
# qemu-img create. --no-gpu keeps this lifecycle test away from real mdev sysfs.
CLONE_ROOT="$TMP_DIR/clone-vms"
CLONE_ID=910002
mkdir -p "$CLONE_ROOT/shared/bases"
printf 'qualified-base\n' >"$CLONE_ROOT/shared/bases/win10-base.qcow2"
run_start "$CLONE_ROOT" "$CLONE_ID" \
    "$TMP_DIR/clone.out" "$TMP_DIR/clone.err" --no-gpu
CLONE_DISK="$CLONE_ROOT/vm${CLONE_ID}/disk.qcow2"
cmp "$CLONE_ROOT/shared/bases/win10-base.qcow2" "$CLONE_DISK" || \
    fail "normal bootstrap did not clone the public base"
if grep -Fq 'create -f qcow2' "$TMP_DIR/qemu-img.trace"; then
    fail "normal bootstrap created a blank disk instead of cloning the base"
fi
require_text '自动从公共 base 创建实例盘' "$TMP_DIR/clone.out"
if grep -Fq 'id=answer0' "$TMP_DIR/qemu.trace"; then
    fail "normal base startup attached the install answer ISO"
fi
require_text 'ide-cd.bootindex=-1' "$TMP_DIR/qemu.trace"
reject_text 'id=odd0' "$TMP_DIR/qemu.trace"
reject_text 'media=cdrom' "$TMP_DIR/qemu.trace"
reject_text 'ide-cd\,drive=' "$TMP_DIR/qemu.trace"
reject_text 'scsi-cd' "$TMP_DIR/qemu.trace"

# The fully parsed final mode decides disk intent. Option values that happen to
# equal --install/--dry-run must not affect bootstrap or lock behavior.
LAST_MODE_ROOT="$TMP_DIR/last-mode-vms"
LAST_MODE_ID=910005
mkdir -p "$LAST_MODE_ROOT/shared/bases"
printf 'last-mode-base\n' >"$LAST_MODE_ROOT/shared/bases/win10-base.qcow2"
run_start "$LAST_MODE_ROOT" "$LAST_MODE_ID" \
    "$TMP_DIR/last-mode.out" "$TMP_DIR/last-mode.err" \
    --install "$TMP_DIR/windows.iso" --no-gpu
cmp "$LAST_MODE_ROOT/shared/bases/win10-base.qcow2" \
    "$LAST_MODE_ROOT/vm${LAST_MODE_ID}/disk.qcow2" || \
    fail "final --no-gpu mode did not override earlier --install disk intent"

EXTRA_ROOT="$TMP_DIR/extra-vms"
EXTRA_ID=910006
mkdir -p "$EXTRA_ROOT/shared/bases"
printf 'extra-base\n' >"$EXTRA_ROOT/shared/bases/win10-base.qcow2"
run_start "$EXTRA_ROOT" "$EXTRA_ID" \
    "$TMP_DIR/extra.out" "$TMP_DIR/extra.err" \
    --extra --install --no-gpu
cmp "$EXTRA_ROOT/shared/bases/win10-base.qcow2" \
    "$EXTRA_ROOT/vm${EXTRA_ID}/disk.qcow2" || \
    fail "--extra value was mistaken for install mode"

EXTRA_DRY_ROOT="$TMP_DIR/extra-dry-vms"
EXTRA_DRY_ID=910007
mkdir -p "$EXTRA_DRY_ROOT/shared/bases"
printf 'extra-dry-base\n' >"$EXTRA_DRY_ROOT/shared/bases/win10-base.qcow2"
run_start "$EXTRA_DRY_ROOT" "$EXTRA_DRY_ID" \
    "$TMP_DIR/extra-dry.out" "$TMP_DIR/extra-dry.err" \
    --extra --dry-run --no-gpu
[[ -f "$EXTRA_DRY_ROOT/vm${EXTRA_DRY_ID}/disk.qcow2" ]] || \
    fail "--extra value was mistaken for dry-run mode"

FINAL_INSTALL_ROOT="$TMP_DIR/final-install-vms"
FINAL_INSTALL_ID=910008
mkdir -p "$FINAL_INSTALL_ROOT/shared/bases"
printf 'final-install-base\n' >"$FINAL_INSTALL_ROOT/shared/bases/win10-base.qcow2"
run_start "$FINAL_INSTALL_ROOT" "$FINAL_INSTALL_ID" \
    "$TMP_DIR/final-install.out" "$TMP_DIR/final-install.err" \
    --no-gpu --install "$TMP_DIR/windows.iso"
[[ ! -s "$FINAL_INSTALL_ROOT/vm${FINAL_INSTALL_ID}/disk.qcow2" ]] || \
    fail "final --install mode did not create a blank disk"

# Without --install or a base, retain the generated identity for a later retry
# but never publish or boot a silently-created empty NVMe device.
EMPTY_ROOT="$TMP_DIR/empty-vms"
EMPTY_ID=910003
if run_start "$EMPTY_ROOT" "$EMPTY_ID" \
        "$TMP_DIR/empty.out" "$TMP_DIR/empty.err" --no-gpu; then
    fail "normal bootstrap without a public base unexpectedly succeeded"
fi
require_text '没有可克隆的公共 base' "$TMP_DIR/empty.err"
require_text '--install' "$TMP_DIR/empty.err"
[[ -f "$EMPTY_ROOT/vm${EMPTY_ID}/vm.conf" ]] || \
    fail "missing-base refusal did not retain the generated identity"
[[ ! -e "$EMPTY_ROOT/vm${EMPTY_ID}/disk.qcow2" ]] || \
    fail "missing-base refusal still created a disk"

echo "PASS: root start-vm intent-aware blank/base bootstrap"
