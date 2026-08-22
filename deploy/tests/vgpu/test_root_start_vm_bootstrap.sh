#!/usr/bin/env bash
# Exercise start-vm.sh's intent-aware first-start bootstrap entirely under a
# temporary VM_ROOT.  No real qemu process, mdev, TPM, or production image is
# touched.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
START_VM="$REPO_ROOT/deploy/scripts/start-vm.sh"

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

assert_no_persistent_optical_contract() {
    local file=$1 label=$2 optical_line

    while IFS= read -r optical_line; do
        [[ "$optical_line" != *'id=g11-odd'* ]] ||
            fail "$label attached a default g11-odd optical drive: $optical_line"
        [[ "$optical_line" != *'model='* &&
           "$optical_line" != *'serial='* ]] ||
            fail "$label transient media exposed an unaudited identity: $optical_line"
    done < <(
        sed 's/ -/\n-/g' "$file" |
            grep -E -- '((ide|scsi)-cd|usb-storage)\\,' || true
    )
}

TMP_DIR="$(mktemp -d)"
if [[ "${KEEP_TEST_TMP:-0}" == 1 ]]; then
    trap 'printf "retained test fixture: %s\n" "$TMP_DIR" >&2' EXIT
else
    trap 'rm -rf -- "$TMP_DIR"' EXIT
fi

touch "$TMP_DIR/OVMF_CODE.fd" "$TMP_DIR/OVMF_VARS.fd"

# Non-dry-run startup now validates the bridge helper, exact ACL and shared
# maintenance lock even when BRIDGE_UPLINK_CHECK=off (that switch skips only
# the physical-uplink/carrier portion).  Build an entirely local fixture and
# make only its ownership/capability metadata appear root-installed; all other
# stat/getcap calls retain their real behavior.
NETWORK_TEST_ROOT="$TMP_DIR/network-root"
mkdir -p "$TMP_DIR/bin" "$NETWORK_TEST_ROOT"
printf '#!/usr/bin/env bash\nexit 0\n' >"$NETWORK_TEST_ROOT/bridge-helper"
printf 'allow br0\n' >"$NETWORK_TEST_ROOT/bridge.conf"
: >"$NETWORK_TEST_ROOT/network.lock"
chmod 0755 "$NETWORK_TEST_ROOT/bridge-helper"
chmod 0644 "$NETWORK_TEST_ROOT/bridge.conf" "$NETWORK_TEST_ROOT/network.lock"

cat >"$TMP_DIR/bin/stat" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
path=${@: -1}
if [[ "$path" == "$NETWORK_TEST_ROOT"* ]]; then
    case " $* " in
        *' -c %u '*) printf '0\n'; exit 0 ;;
        *' -c %a '*)
            if [[ "$path" == "$NETWORK_TEST_ROOT/bridge-helper" ]]; then
                printf '750\n'
            elif [[ -d "$path" ]]; then
                printf '755\n'
            else
                printf '644\n'
            fi
            exit 0
            ;;
    esac
fi
exec /usr/bin/stat "$@"
EOF
chmod +x "$TMP_DIR/bin/stat"

cat >"$TMP_DIR/bin/getcap" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ $# == 2 && "$1" == -- \
    && "$2" == "$NETWORK_TEST_ROOT/bridge-helper" ]] || exit 1
printf '%s cap_net_admin=ep\n' "$2"
EOF
chmod +x "$TMP_DIR/bin/getcap"

cat >"$TMP_DIR/qemu-img" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_QEMU_IMG_TRACE"
record_size() {
    local image=$1 size=$2 base=${1##*/} image_dir
    image_dir=$(dirname -- "$image")
    printf '%s\n' "$size" >"$image.size"
    # create-disk atomically renames only the real qcow2.  Mirror its final
    # metadata path in this fake; real qemu-img stores virtual-size in-image.
    if [[ "$base" == .disk.qcow2.partial.* ]]; then
        printf '%s\n' "$size" >"$image_dir/disk.qcow2.size"
    fi
}
case "$1" in
    create)
        backing=""
        for ((index = 1; index <= $#; index++)); do
            if [[ "${!index}" == -b ]]; then
                next=$((index + 1))
                backing=${!next}
                break
            fi
        done
        if [[ -n "$backing" ]]; then
            target=${@: -1}
            size=500000000000
        else
            target=${@: -2:1}
            size=${@: -1}
        fi
        mkdir -p "$(dirname "$target")"
        : >"$target"
        record_size "$target" "$size"
        if [[ -n "$backing" ]]; then
            printf '%s\n' "$backing" >"$(dirname -- "$target")/.linked-backing"
        fi
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
        backing=""
        full_backing=""
        image_leaf=${image##*/}
        if [[ "$image_leaf" == disk.qcow2 ||
              "$image_leaf" == .disk.qcow2.partial.* ]] &&
                [[ -f "${image%/*}/.linked-backing" ]]; then
            backing=$(<"${image%/*}/.linked-backing")
            full_backing=$(readlink -m -- "${image%/*}/$backing")
        fi
        if [[ " $* " == *' --output=json '* ]]; then
            if [[ -n "$backing" ]]; then
                printf '{"format":"qcow2","virtual-size":%s,"backing-filename":"%s","full-backing-filename":"%s","format-specific":{"data":{}}}\n' \
                    "$size" "$backing" "$full_backing"
            else
                printf '{"format":"qcow2","virtual-size":%s,"backing-filename":null,"full-backing-filename":null,"format-specific":{"data":{}}}\n' "$size"
            fi
        else
            printf 'image: %s\nfile format: qcow2\nvirtual size: %s\n' "$image" "$size"
            [[ -z "$backing" ]] || printf 'backing file: %s\n' "$backing"
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
if [[ "${1:-}" == --version ]]; then
    echo 'QEMU emulator version 11.0.2 (G-11 bootstrap fake)'
    exit 0
fi
if [[ "$#" -eq 2 && "$1" == -device && "$2" == usb-kbd,help ]]; then
    printf '%s\n' \
        '  x-force-numlock-on=<bool> - on/off (default: off)' \
        '  x-numlock-on-confirmed=<bool>'
    exit 0
fi
if [[ "$#" -eq 2 && "$1" == -device && "$2" == ICH9-LPC,help ]]; then
    printf '%s\n' '  x-g11-chipset=<str>'
    exit 0
fi
if [[ "$#" -eq 2 && "$1" == -device && "$2" == usb-bot,help ]]; then
    printf '%s\n' '  x-no-serial=<bool>'
    exit 0
fi
if [[ "$#" -eq 2 && "$1" == -device && "$2" == scsi-cd,help ]]; then
    printf '%s\n' '  vendor=<str>' '  product=<str>' '  ver=<str>'
    exit 0
fi
printf '%q ' "$@" >>"$FAKE_QEMU_TRACE"
printf '\n' >>"$FAKE_QEMU_TRACE"
if [[ " $* " == *' -qmp stdio '* ]]; then
    echo '{"QMP":{"version":{"qemu":{"major":11,"minor":0,"micro":2}}}}'
    echo '{"return":{}}'
    exit 0
fi
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
        PATH="$TMP_DIR/bin:/usr/bin:/bin" \
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
        CPU_ISOLATION=off \
        HOST_OOM_PROTECT=0 \
        QEMU_DISK_AIO=threads \
        MEM_GUARD=0 \
        REPAIR_DISPLAY_VARS=off \
        BRIDGE_UPLINK_CHECK=off \
        G11_BRIDGE_HELPER="$NETWORK_TEST_ROOT/bridge-helper" \
        G11_BRIDGE_ACL="$NETWORK_TEST_ROOT/bridge.conf" \
        G11_NETWORK_LOCK="$NETWORK_TEST_ROOT/network.lock" \
        NETWORK_TEST_ROOT="$NETWORK_TEST_ROOT" \
        FAKE_QEMU_IMG_TRACE="$TMP_DIR/qemu-img.trace" \
        FAKE_QEMU_TRACE="$TMP_DIR/qemu.trace" \
        FAKE_XORRISO_TRACE="$TMP_DIR/xorriso.trace" \
        "$START_VM" "$vm_id" --no-monitor-sync "$@" \
        >"$output" 2>"$error"
}

# --install must create a blank image even when a qualified public base exists.
INSTALL_ROOT="$TMP_DIR/install-vms"
INSTALL_ID=910001
mkdir -p "$INSTALL_ROOT/_base"
printf 'base-must-not-be-copied\n' >"$INSTALL_ROOT/_base/win10-base.qcow2"
printf 'windows-iso\n' >"$TMP_DIR/windows.iso"
if ! run_start "$INSTALL_ROOT" "$INSTALL_ID" \
        "$TMP_DIR/install.out" "$TMP_DIR/install.err" \
        --install "$TMP_DIR/windows.iso"; then
    sed 's/^/start-vm: /' "$TMP_DIR/install.err" >&2 || true
    fail "install bootstrap failed before its assertions"
fi
INSTALL_DISK="$INSTALL_ROOT/${INSTALL_ID}/disk.qcow2"
[[ -f "$INSTALL_ROOT/${INSTALL_ID}/vm.conf" ]] || \
    fail "install bootstrap did not create vm.conf"
[[ -f "$INSTALL_DISK" ]] || fail "install bootstrap did not create a disk"
[[ ! -s "$INSTALL_DISK" ]] || fail "install bootstrap copied the public base"
require_text 'create -f qcow2' "$TMP_DIR/qemu-img.trace"
require_text "$TMP_DIR/windows.iso" "$TMP_DIR/qemu.trace"
require_text 'id=odd0' "$TMP_DIR/qemu.trace"
require_text 'media=cdrom' "$TMP_DIR/qemu.trace"
require_text 'format=raw' "$TMP_DIR/qemu.trace"
require_text 'id=installboot' "$TMP_DIR/qemu.trace"
require_text 'g11-usb-install-boot.img' "$TMP_DIR/qemu.trace"
require_text 'id=installboot\,format=raw\,readonly=on' "$TMP_DIR/qemu.trace"
require_text 'usb-storage\,id=installboot-usb\,drive=installboot\,bus=xhci.0\,port=4\,bootindex=1\,removable=on' \
    "$TMP_DIR/qemu.trace"
require_text 'usb-storage\,id=odd0-usb\,drive=odd0\,bus=xhci.0\,port=3\,bootindex=3\,removable=on' \
    "$TMP_DIR/qemu.trace"
case "$(<"$TMP_DIR/qemu.trace")" in
    *'usb-storage\,id=odd0-usb'*'usb-storage\,id=installboot-usb'*) ;;
    *) fail "USB ISO frontend must be created before the boot helper so OVMF connects it" ;;
esac
reject_text 'ide-cd\,drive=odd0' "$TMP_DIR/qemu.trace"
require_text 'bootindex=2' "$TMP_DIR/qemu.trace"
require_text 'id=answer0' "$TMP_DIR/qemu.trace"
require_text 'bus=ide.2' "$TMP_DIR/qemu.trace"
assert_no_persistent_optical_contract "$TMP_DIR/qemu.trace" \
    'install bootstrap'
require_text 'autounattend.iso' "$TMP_DIR/qemu.trace"
require_text 'Autounattend.xml' "$TMP_DIR/xorriso.trace"
require_text 'Administrator 空密码 / China Standard Time / NumLock on' \
    "$TMP_DIR/install.out"
require_text '手动安装: 产品密钥 / Windows 版本 / 目标磁盘与分区' \
    "$TMP_DIR/install.out"
require_text '安装模式自动创建空盘' "$TMP_DIR/install.out"
require_text '安装介质: UEFI helper -> xHCI USB BOT CD-ROM' "$TMP_DIR/install.out"
require_text '普通启动全部不挂载' "$TMP_DIR/install.out"
require_text '光驱: 安装模式临时 xHCI USB BOT CD-ROM' \
    "$TMP_DIR/install.out"
require_text '  键盘:' "$TMP_DIR/install.out"
require_text '  绝对指针:' "$TMP_DIR/install.out"
require_text 'KBD_PRODUCT=' \
    "$INSTALL_ROOT/${INSTALL_ID}/vm.conf"
require_text 'POINTER_PRODUCT=' \
    "$INSTALL_ROOT/${INSTALL_ID}/vm.conf"
require_text 'INPUT_COMPONENT_CONTRACT_VERSION=2' \
    "$INSTALL_ROOT/${INSTALL_ID}/vm.conf"
grep -Eq '^XHCI_PCI_VENDOR_ID=0x(1B21|1B73)$' \
    "$INSTALL_ROOT/${INSTALL_ID}/vm.conf" || \
    fail 'install bootstrap xHCI vendor is outside the reviewed X79 pool'
grep -Eq '^XHCI_PCI_DEVICE_ID=0x(1042|1009)$' \
    "$INSTALL_ROOT/${INSTALL_ID}/vm.conf" || \
    fail 'install bootstrap xHCI device is outside the reviewed X79 pool'
grep -Eq '^XHCI_PCI_REVISION=0x(00|02)$' \
    "$INSTALL_ROOT/${INSTALL_ID}/vm.conf" || \
    fail 'install bootstrap xHCI revision is outside the reviewed platform pool'
require_text 'XHCI_PCI_BUS=pcie.0' \
    "$INSTALL_ROOT/${INSTALL_ID}/vm.conf"
require_text 'XHCI_PCI_ADDR=0x6' \
    "$INSTALL_ROOT/${INSTALL_ID}/vm.conf"
reject_text '旧 vm.conf 缺少 xHCI PCI identity' "$TMP_DIR/install.err"
require_text 'usb-kbd\,id=kbd0\,bus=xhci.0\,usb_version=' "$TMP_DIR/qemu.trace"
require_text 'x-force-numlock-on=on' "$TMP_DIR/qemu.trace"
require_text 'usb-tablet\,bus=xhci.0\,usb_version=' "$TMP_DIR/qemu.trace"
require_text 'qemu-xhci\,id=xhci\,bus=pcie.0\,addr=0x6' \
    "$TMP_DIR/qemu.trace"
if grep -F -- 'qemu-xhci\,' "$TMP_DIR/qemu.trace" |
        grep -Eq 'x-pci-(vendor-id|device-id|revision)'; then
    fail 'install bootstrap projected physical PCI facts onto qemu-xhci'
fi
require_text 'i8042=off' "$TMP_DIR/qemu.trace"
require_text '-rtc base=localtime\,clock=vm\,driftfix=slew' "$TMP_DIR/qemu.trace"
require_text 'kvm-pit.lost_tick_policy=delay' "$TMP_DIR/qemu.trace"
require_text 'RTC_CONTRACT=localtime' \
    "$INSTALL_ROOT/${INSTALL_ID}/vm.conf"

# The optimized USB optical path is the default, while a fully explicit IDE
# fallback remains available for unusual firmware diagnostics.  The fallback
# must not silently become a persisted per-VM hardware choice.
INSTALL_IDE_ROOT="$TMP_DIR/install-ide-vms"
INSTALL_IDE_ID=910011
if ! run_start "$INSTALL_IDE_ROOT" "$INSTALL_IDE_ID" \
        "$TMP_DIR/install-ide.out" "$TMP_DIR/install-ide.err" \
        --install "$TMP_DIR/windows.iso" --install-media ide; then
    sed 's/^/start-vm: /' "$TMP_DIR/install-ide.err" >&2 || true
    fail "explicit IDE install-media fallback failed"
fi
require_text 'id=install-odd-media\,media=cdrom\,readonly=on\,format=raw' \
    "$TMP_DIR/qemu.trace"
require_text 'ide-cd\,id=install-odd-ide\,drive=install-odd-media\,bus=ide.0\,unit=0\,model=HL-DT-ST\ DVDRAM\ GH24NS50\,ver=XP02\,serial=\,bootindex=1' \
    "$TMP_DIR/qemu.trace"
reject_text 'usb-storage\,drive=odd0' "$TMP_DIR/qemu.trace"
reject_text 'id=installboot' "$TMP_DIR/qemu.trace"
reject_text 'g11-usb-install-boot.img' "$TMP_DIR/qemu.trace"
reject_text 'id=odd0-usb' "$TMP_DIR/qemu.trace"
require_text '安装介质: ICH9-AHCI IDE CD-ROM' "$TMP_DIR/install-ide.out"
reject_text 'INSTALL_MEDIA_BACKEND=' \
    "$INSTALL_IDE_ROOT/${INSTALL_IDE_ID}/vm.conf"

if run_start "$INSTALL_IDE_ROOT" "$INSTALL_IDE_ID" \
        "$TMP_DIR/install-media-duplicate.out" \
        "$TMP_DIR/install-media-duplicate.err" \
        --install "$TMP_DIR/windows.iso" \
        --install-media usb --install-media ide; then
    fail "duplicate --install-media options were accepted"
fi
require_text '--install-media 只能指定一次' \
    "$TMP_DIR/install-media-duplicate.err"

# Stable mdev identity requires VM_UUID uniqueness across instance configs.
DUPLICATE_ID=910099
mkdir -p "$INSTALL_ROOT/${DUPLICATE_ID}"
cp "$INSTALL_ROOT/${INSTALL_ID}/vm.conf" \
    "$INSTALL_ROOT/${DUPLICATE_ID}/vm.conf"
if run_start "$INSTALL_ROOT" "$INSTALL_ID" \
        "$TMP_DIR/duplicate-uuid.out" "$TMP_DIR/duplicate-uuid.err" \
        --dry-run --no-gpu; then
    fail "start-vm accepted duplicate stable VM_UUID values"
fi
require_text '重复 VM_UUID=' "$TMP_DIR/duplicate-uuid.err"
rm -rf -- "$INSTALL_ROOT/${DUPLICATE_ID}"

# An existing qcow2 whose virtual size no longer matches the immutable SSD
# identity must fail before the full VM starts.  The device-free CPU
# realization preflight may invoke QEMU with QMP stdio first.
install_size=$(<"$INSTALL_DISK.size")
printf '12345\n' >"$INSTALL_DISK.size"
if run_start "$INSTALL_ROOT" "$INSTALL_ID" \
        "$TMP_DIR/capacity-mismatch.out" "$TMP_DIR/capacity-mismatch.err" \
        --install "$TMP_DIR/windows.iso"; then
    fail "start-vm accepted a qcow2/profile virtual-size mismatch"
fi
require_text '磁盘容量与硬件 profile 不一致' \
    "$TMP_DIR/capacity-mismatch.err"
if grep -Fq -- '-name vm' "$TMP_DIR/qemu.trace"; then
    fail "capacity mismatch still launched the full VM"
fi
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
require_text 'id=installboot' "$TMP_DIR/qemu.trace"
require_text 'id=odd0-usb' "$TMP_DIR/qemu.trace"

# The explicit manual-OOBE escape hatch keeps the Windows installer fully
# interactive and must not build or attach the answer medium.
MANUAL_ROOT="$TMP_DIR/manual-vms"
MANUAL_ID=910010
mkdir -p "$MANUAL_ROOT/_base"
printf 'base-must-not-be-copied\n' >"$MANUAL_ROOT/_base/win10-base.qcow2"
run_start "$MANUAL_ROOT" "$MANUAL_ID" \
    "$TMP_DIR/manual.out" "$TMP_DIR/manual.err" \
    --install "$TMP_DIR/windows.iso" --manual-oobe
if grep -Fq 'id=answer0' "$TMP_DIR/qemu.trace"; then
    fail "--manual-oobe still attached the answer ISO"
fi
[[ ! -s "$TMP_DIR/xorriso.trace" ]] || \
    fail "--manual-oobe still invoked xorriso"
require_text '手动 OOBE' "$TMP_DIR/manual.out"
require_text 'id=installboot' "$TMP_DIR/qemu.trace"
require_text 'id=odd0-usb' "$TMP_DIR/qemu.trace"

# Omitting the ISO argument resolves IMAGE_ROOT/iso/win10.iso and keeps the
# same blank-disk guarantee.
DEFAULT_ROOT="$TMP_DIR/default-vms"
DEFAULT_ID=910004
mkdir -p "$DEFAULT_ROOT/_base" "$TMP_DIR/iso"
printf 'base-must-not-be-copied\n' >"$DEFAULT_ROOT/_base/win10-base.qcow2"
printf 'default-windows-iso\n' >"$TMP_DIR/iso/win10.iso"
run_start "$DEFAULT_ROOT" "$DEFAULT_ID" \
    "$TMP_DIR/default.out" "$TMP_DIR/default.err" --install
[[ ! -s "$DEFAULT_ROOT/${DEFAULT_ID}/disk.qcow2" ]] || \
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
[[ ! -e "$BAD_ISO_ROOT/${BAD_ISO_ID}/disk.qcow2" ]] || \
    fail "missing ISO still published a blank disk"

# A normal first start must create the same V-11-style incremental disk used by
# clone-from-base. --no-gpu keeps this lifecycle test away from real mdev sysfs.
CLONE_ROOT="$TMP_DIR/clone-vms"
CLONE_ID=910002
mkdir -p "$CLONE_ROOT/_base"
printf 'qualified-base\n' >"$CLONE_ROOT/_base/win10-base.qcow2"
if ! run_start "$CLONE_ROOT" "$CLONE_ID" \
        "$TMP_DIR/clone.out" "$TMP_DIR/clone.err" --no-gpu; then
    sed 's/^/clone: /' "$TMP_DIR/clone.err" >&2 || true
    fail 'normal linked bootstrap failed before storage assertions'
fi
CLONE_DISK="$CLONE_ROOT/${CLONE_ID}/disk.qcow2"
CLONE_PIN="$CLONE_ROOT/${CLONE_ID}/.base.qcow2"
[[ -f "$CLONE_DISK" && -f "$CLONE_PIN" && ! -L "$CLONE_PIN" ]] ||
    fail 'normal bootstrap did not publish the overlay and base pin'
[[ "$CLONE_PIN" -ef "$CLONE_ROOT/_base/win10-base.qcow2" ]] ||
    fail 'normal bootstrap base pin does not share the selected base inode'
[[ ! "$CLONE_DISK" -ef "$CLONE_PIN" ]] ||
    fail 'normal bootstrap published the base itself as the writable disk'
require_text 'create -q -f qcow2 -F qcow2 -b .base.qcow2' \
    "$TMP_DIR/qemu-img.trace"
if grep -Fq 'preallocation=metadata' "$TMP_DIR/qemu-img.trace"; then
    fail 'normal bootstrap created a blank standalone disk'
fi
require_text '自动从公共 base 创建实例盘' "$TMP_DIR/clone.out"
require_text '实例盘: V-11 式增量盘 / backing=.base.qcow2' \
    "$TMP_DIR/clone.out"
if grep -Fq 'id=answer0' "$TMP_DIR/qemu.trace"; then
    fail "normal base startup attached the install answer ISO"
fi
require_text 'ide-cd.bootindex=-1' "$TMP_DIR/qemu.trace"
reject_text 'id=g11-odd-media' "$TMP_DIR/qemu.trace"
reject_text 'id=g11-odd' "$TMP_DIR/qemu.trace"
reject_text 'id=odd0\,' "$TMP_DIR/qemu.trace"
reject_text 'scsi-cd' "$TMP_DIR/qemu.trace"
reject_text 'usb-storage\,drive=odd0' "$TMP_DIR/qemu.trace"
reject_text 'id=installboot' "$TMP_DIR/qemu.trace"
reject_text 'installboot-usb' "$TMP_DIR/qemu.trace"
reject_text 'g11-usb-install-boot.img' "$TMP_DIR/qemu.trace"
assert_no_persistent_optical_contract "$TMP_DIR/qemu.trace" \
    'normal bootstrap'

# A private Sysprep clone gate attaches exactly its per-VM package as a
# read-only, non-boot, reviewed true-model USB CD-ROM. It must not reintroduce
# the install helper or any ordinary persistent optical identity; the guest
# eject/host watcher pair removes it after the payload is durable.
CLONE_CONF="$CLONE_ROOT/${CLONE_ID}/vm.conf"
CLONE_UUID=$(
    unset VM_UUID
    # shellcheck source=/dev/null
    source "$CLONE_CONF"
    printf '%s' "${VM_UUID,,}"
)
CLONE_GPU_PROFILE=$(
    unset GPU_PROFILE
    # shellcheck source=/dev/null
    source "$CLONE_CONF"
    printf '%s' "$GPU_PROFILE"
)
CLONE_MONITOR_PROFILE=$(
    unset MONITOR_PROFILE
    # shellcheck source=/dev/null
    source "$CLONE_CONF"
    printf '%s' "$MONITOR_PROFILE"
)
CLONE_CONFIG_SHA256=$(sha256sum -- "$CLONE_CONF" | awk '{print toupper($1)}')
INIT_CONTRACT_ID=$(printf '%064d' 0 | tr 0 A)
INIT_ISO_FILE="vm${CLONE_ID}-${CLONE_UUID}-${INIT_CONTRACT_ID:0:16}.iso"
INIT_PACKAGE_ROOT="$CLONE_ROOT/${CLONE_ID}/packages/SystemNvapiProjection"
mkdir -m 0700 -p -- "$INIT_PACKAGE_ROOT"
printf 'private VM-bound initialization ISO\n' >"$INIT_PACKAGE_ROOT/$INIT_ISO_FILE"
chmod 0600 "$INIT_PACKAGE_ROOT/$INIT_ISO_FILE"
INIT_ISO_SHA256=$(sha256sum -- "$INIT_PACKAGE_ROOT/$INIT_ISO_FILE" |
    awk '{print toupper($1)}')
jq -n \
    --arg baseName private-base \
    --arg vmUuid "$CLONE_UUID" \
    --arg gpuProfile "$CLONE_GPU_PROFILE" \
    --arg monitorProfile "$CLONE_MONITOR_PROFILE" \
    --arg sourceConfigSha256 "$CLONE_CONFIG_SHA256" \
    --arg systemNvapiContractId "$INIT_CONTRACT_ID" \
    --arg systemNvapiIsoFile "$INIT_ISO_FILE" \
    --arg systemNvapiIsoSha256 "$INIT_ISO_SHA256" '
    {
        schemaVersion: 2,
        state: "guest-firstboot-required",
        baseName: $baseName,
        catalogSha256: ("B" * 64),
        createdUtc: "2026-08-19T00:00:00Z",
        vmUuid: $vmUuid,
        gpuProfile: $gpuProfile,
        monitorProfile: $monitorProfile,
        sourceConfigSha256: $sourceConfigSha256,
        systemNvapiContractId: $systemNvapiContractId,
        systemNvapiIsoFile: $systemNvapiIsoFile,
        systemNvapiIsoSha256: $systemNvapiIsoSha256
    }' >"$CLONE_ROOT/${CLONE_ID}/.g11-init-required"
chmod 0600 "$CLONE_ROOT/${CLONE_ID}/.g11-init-required"
if ! run_start "$CLONE_ROOT" "$CLONE_ID" \
        "$TMP_DIR/private-init.out" "$TMP_DIR/private-init.err" --no-gpu; then
    sed 's/^/private-init: /' "$TMP_DIR/private-init.err" >&2 || true
    fail 'private initialization startup failed before argv assertions'
fi
require_text "file=${INIT_PACKAGE_ROOT}/${INIT_ISO_FILE}\,if=none\,id=g11-init-odd-media\,media=cdrom\,readonly=on\,format=raw" \
    "$TMP_DIR/qemu.trace"
require_text 'usb-bot\,id=g11-init-odd-usb\,bus=xhci.0\,port=3\,x-no-serial=on' \
    "$TMP_DIR/qemu.trace"
require_text 'scsi-cd\,id=g11-init-odd\,drive=g11-init-odd-media\,bus=g11-init-odd-usb.0\,vendor=HL-DT-ST\,product=DVDRAM\ GH24NS50\,ver=XP02\,serial=\,bootindex=-1' \
    "$TMP_DIR/qemu.trace"
reject_text 'g11-init-odd-usb\,bus=xhci.0\,port=3\,attached=on' \
    "$TMP_DIR/qemu.trace"
if tr ' ' '\n' <"$TMP_DIR/qemu.trace" |
        grep -F 'g11-init-odd-usb' | grep -Fq 'bootindex='; then
    fail "private initialization ISO unexpectedly became bootable"
fi
reject_text 'id=installboot' "$TMP_DIR/qemu.trace"
require_text "系统 NVAPI: VM-bound contract ${INIT_CONTRACT_ID}" \
    "$TMP_DIR/private-init.out"
require_text 'QMP multi: native multi-client' "$TMP_DIR/private-init.out"
require_text '载荷复制后自动热拔' "$TMP_DIR/private-init.out"
[[ -f "$CLONE_ROOT/${CLONE_ID}/.g11-init-required" ]] ||
    fail "start-vm cleared the private initialization gate before host verification"

# The fully parsed final mode decides disk intent. Option values that happen to
# equal --install/--dry-run must not affect bootstrap or lock behavior.
LAST_MODE_ROOT="$TMP_DIR/last-mode-vms"
LAST_MODE_ID=910005
mkdir -p "$LAST_MODE_ROOT/_base"
printf 'last-mode-base\n' >"$LAST_MODE_ROOT/_base/win10-base.qcow2"
run_start "$LAST_MODE_ROOT" "$LAST_MODE_ID" \
    "$TMP_DIR/last-mode.out" "$TMP_DIR/last-mode.err" \
    --install "$TMP_DIR/windows.iso" --no-gpu
[[ -f "$LAST_MODE_ROOT/${LAST_MODE_ID}/disk.qcow2" &&
   "$LAST_MODE_ROOT/${LAST_MODE_ID}/.base.qcow2" -ef "$LAST_MODE_ROOT/_base/win10-base.qcow2" ]] ||
    fail "final --no-gpu mode did not create a linked base disk"

EXTRA_ROOT="$TMP_DIR/extra-vms"
EXTRA_ID=910006
mkdir -p "$EXTRA_ROOT/_base"
printf 'extra-base\n' >"$EXTRA_ROOT/_base/win10-base.qcow2"
run_start "$EXTRA_ROOT" "$EXTRA_ID" \
    "$TMP_DIR/extra.out" "$TMP_DIR/extra.err" \
    --extra --install --no-gpu
[[ -f "$EXTRA_ROOT/${EXTRA_ID}/disk.qcow2" &&
   "$EXTRA_ROOT/${EXTRA_ID}/.base.qcow2" -ef "$EXTRA_ROOT/_base/win10-base.qcow2" ]] ||
    fail "--extra value was mistaken for install mode"

EXTRA_DRY_ROOT="$TMP_DIR/extra-dry-vms"
EXTRA_DRY_ID=910007
mkdir -p "$EXTRA_DRY_ROOT/_base"
printf 'extra-dry-base\n' >"$EXTRA_DRY_ROOT/_base/win10-base.qcow2"
run_start "$EXTRA_DRY_ROOT" "$EXTRA_DRY_ID" \
    "$TMP_DIR/extra-dry.out" "$TMP_DIR/extra-dry.err" \
    --extra --dry-run --no-gpu
[[ -f "$EXTRA_DRY_ROOT/${EXTRA_DRY_ID}/disk.qcow2" ]] || \
    fail "--extra value was mistaken for dry-run mode"
[[ "$EXTRA_DRY_ROOT/${EXTRA_DRY_ID}/.base.qcow2" -ef "$EXTRA_DRY_ROOT/_base/win10-base.qcow2" ]] ||
    fail "--extra value did not preserve linked-clone storage intent"

FINAL_INSTALL_ROOT="$TMP_DIR/final-install-vms"
FINAL_INSTALL_ID=910008
mkdir -p "$FINAL_INSTALL_ROOT/_base"
printf 'final-install-base\n' >"$FINAL_INSTALL_ROOT/_base/win10-base.qcow2"
run_start "$FINAL_INSTALL_ROOT" "$FINAL_INSTALL_ID" \
    "$TMP_DIR/final-install.out" "$TMP_DIR/final-install.err" \
    --no-gpu --install "$TMP_DIR/windows.iso"
[[ ! -s "$FINAL_INSTALL_ROOT/${FINAL_INSTALL_ID}/disk.qcow2" ]] || \
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
[[ -f "$EMPTY_ROOT/${EMPTY_ID}/vm.conf" ]] || \
    fail "missing-base refusal did not retain the generated identity"
[[ ! -e "$EMPTY_ROOT/${EMPTY_ID}/disk.qcow2" ]] || \
    fail "missing-base refusal still created a disk"

echo "PASS: root start-vm intent-aware blank/base bootstrap"
