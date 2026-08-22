#!/usr/bin/env bash
# Validate the native vGPU implementation without allocating an
# mdev, starting QEMU, or creating the legacy shared-memory transport.
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

    grep -F -- "$needle" "$file" >/dev/null \
        || fail "missing '$needle' in $(basename "$file")"
}

reject_text() {
    local needle=$1 file=$2

    if grep -F -- "$needle" "$file" >/dev/null; then
        fail "unexpected '$needle' in $(basename "$file")"
    fi
}

require_native_vfio() {
    local file=$1 line

    line="$(grep -F -- 'vfio-pci-nohotplug\,' "$file" || true)"
    [[ -n "$line" ]] || fail "native vfio-pci-nohotplug device is missing"
    [[ "$line" == *"display=on"* ]] || fail "native vGPU does not enable display"
    [[ "$line" == *"ramfb=on"* ]] || fail "native vGPU does not enable ramfb"
    [[ "$line" == *"rombar=0"* ]] || fail "native vGPU must keep its EFI ROM hidden"
    [[ "$line" == *"enable-migration=off"* ]] \
        || fail "native vGPU lost its migration safety setting"
    [[ "$line" == *"bus=gpu-root-port"* && "$line" == *"addr=0x0"* ]] \
        || fail "native vGPU is not attached below its PCIe root port"
    [[ "$line" != *"bus=pcie.0"* ]] \
        || fail "native vGPU is still attached directly to the root complex"
}

require_vgpu_root_port() {
    local file=$1 expected_width=${2:-16} line

    line="$(grep -F -- 'pcie-root-port\,' "$file" || true)"
    [[ -n "$line" ]] || fail "vGPU PCIe root port is missing"
    [[ "$line" == *"id=gpu-root-port"* ]] \
        || fail "vGPU PCIe root port has no stable bus id"
    [[ "$line" == *"bus=pcie.0"* && "$line" == *"addr=0x10"* ]] \
        || fail "vGPU PCIe root port moved from its reserved root-bus address"
    [[ "$line" == *"hotplug=off"* ]] \
        || fail "desktop GPU root port unexpectedly permits hotplug"
    [[ "$line" == *"x-speed=8"* &&
       "$line" == *"x-width=${expected_width}"* ]] \
        || fail "vGPU root port does not advertise PCIe 3.0 x${expected_width}"
    [[ "$line" == *"x-pci-vendor-id=0x8086"* ]] \
        || fail "vGPU root port does not use the platform's Intel identity"
}

require_no_legacy_transport() {
    local file=$1

    reject_text 'ivshmem-plain' "$file"
    reject_text 'memory-backend-file\,id=ivshm' "$file"
    reject_text 'vnc=' "$file"
    reject_text 'stream_client_dda' "$file"
    reject_text 'stream-client/' "$file"
}

require_tpm2() {
    local file=$1

    require_text 'TPM: 2.0 / CRB' "$file"
    require_text 'socket\,id=chrtpm\,path=' "$file"
    require_text 'emulator\,id=tpm0\,chardev=chrtpm' "$file"
    require_text 'tpm-crb\,tpmdev=tpm0' "$file"
}

TMP_DIR="$(mktemp -d)"
VM_ROOT="$TMP_DIR/vms"
# Keep the ID high enough to avoid real instances, but within the launcher's
# twelve-digit deterministic dry-run UUID suffix.
VM_ID=$((900000000 + $$ % 90000000))
DRY_MDEV_UUID="00000000-0000-0000-0000-$(printf '%012d' "$VM_ID")"
SHMEM_PATH="/dev/shm/nv-shmem-vm${VM_ID}"

cleanup() {
    rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT

[[ -x "$START_VM" ]] || fail "start-vm.sh is missing or not executable"
[[ ! -e "$SHMEM_PATH" ]] || fail "test VM id collides with existing shared memory"
[[ ! -e "/sys/bus/mdev/devices/$DRY_MDEV_UUID" ]] \
    || fail "test VM id collides with an existing mdev"

mkdir -p "$VM_ROOT/${VM_ID}/log" \
    "$VM_ROOT/${VM_ID}/run" "$VM_ROOT/control"
touch "$VM_ROOT/${VM_ID}/disk.qcow2"
touch "$VM_ROOT/${VM_ID}/nvram.fd"
touch "$TMP_DIR/OVMF_CODE.fd" "$TMP_DIR/OVMF_VARS.fd"

cat >"$VM_ROOT/${VM_ID}/vm.conf" <<EOF
VM_ID=$VM_ID
VM_UUID=3b5a3617-dd9b-42a1-9010-487ffdc145bf
RTC_CONTRACT=localtime
PLATFORM=i5-4590
CPU_MODEL=Core-i5-4590
TSC_FREQ=3300000000
BOARD_BRAND=Gigabyte
BOARD_MODEL="GA-H97-D3H"
BIOS_VER=F7
BIOS_DATE=09/19/2015
SYS_SN=RT2SKDF1B
MB_SN=NPVUW09WOV3Z
CHASSIS_SN=1N6YC2GT
MEM_BRAND=Kingston
MEM_MODEL=KVR16N11S8/4
MEM_SPEED=1600
MEM_TYPE_BYTE=0x18
MEM_WIDTH=64
MEM_SN=BIK6QG9Q5A9L
SSD_BRAND=Crucial
SSD_MODEL="P3 Plus 512GB"
SSD_SN=XHP8TAQ3W42IH793
GPU_PROFILE=gtx1050_2gb
GPU_PCI_VID=0x10DE
GPU_PCI_DID=0x1C81
GPU_SUB_VID=0x1028
GPU_SUB_DID=0x086B
VM_MAC=00:24:D7:9E:2E:E2
SPOOF_MODE=off
EOF

# Capability probes are the only fake-QEMU calls permitted. An accidental
# attempt to launch the VM exits 99 and fails the test before touching hardware.
cat >"$TMP_DIR/qemu-system-x86_64" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$FAKE_QEMU_TRACE"
printf 'XMODIFIERS=%s SDL_IM_MODULE=%s IBUS_ADDRESS=%s NATIVE_EGL=%s SDL_DRIVER=%s X11_WMCLASS=%s WAYLAND_WMCLASS=%s WINDOW_MODE=%s CURSOR_MODE=%s args=%s\n' \
    "${XMODIFIERS-}" "${SDL_IM_MODULE-}" "${IBUS_ADDRESS-}" \
    "${QEMU_SDL_NATIVE_EGL-}" "${SDL_VIDEODRIVER-}" \
    "${SDL_VIDEO_X11_WMCLASS-}" "${SDL_VIDEO_WAYLAND_WMCLASS-}" \
    "${G11_SDL_WINDOW_MODE-}" "${QEMU_SDL_CURSOR_MODE-}" "$*" \
    >>"$FAKE_QEMU_ENV_TRACE"
if [ "$#" -eq 2 ] && [ "$1" = -display ] && [ "$2" = help ]; then
    printf '%s\n' gtk sdl
    exit 0
fi
if [ "$#" -eq 2 ] && [ "$1" = -device ] \
        && [ "$2" = vfio-pci-nohotplug,help ]; then
    printf '  ramfb=<bool>\n'
    exit 0
fi
if [ "$#" -eq 2 ] && [ "$1" = -device ] \
        && [ "$2" = pcie-root-port,help ]; then
    printf '%s\n' \
        '  x-speed=<PCIELinkSpeed>' \
        '  x-width=<PCIELinkWidth>' \
        '  x-pci-vendor-id=<uint32>' \
        '  x-pci-device-id=<uint32>' \
        '  x-pci-revision=<uint32>'
    exit 0
fi
if [ "$#" -eq 2 ] && [ "$1" = -object ] && [ "$2" = fb-shm,help ]; then
    printf 'fb-shm options:\n  path=<string>\n  rate=<uint32>\n'
    exit 0
fi
echo "unexpected fake QEMU invocation: $*" >&2
exit 99
EOF
chmod +x "$TMP_DIR/qemu-system-x86_64"
: >"$TMP_DIR/qemu.trace"
: >"$TMP_DIR/qemu-env.trace"

run_start_vm() {
    local output=$1
    local -a optional_env=()
    shift

    if [[ -n "${TEST_VGPU_HOST_CONFIG:-}" ]]; then
        optional_env+=("VGPU_HOST_CONFIG=$TEST_VGPU_HOST_CONFIG")
    fi
    if [[ "${TEST_NATIVE_WAYLAND:-0}" == 1 ]]; then
        optional_env+=(
            "XDG_SESSION_TYPE=wayland"
            "XDG_RUNTIME_DIR=/run/user/1000"
            "WAYLAND_DISPLAY=wayland-0"
            "SDL_VIDEODRIVER=wayland"
            "QEMU_SDL_NATIVE_EGL=0"
            "G11_SDL_WINDOW_MODE=native-wayland-v1"
        )
    fi
    env -i \
        HOME="${HOME:-/tmp}" \
        PATH=/usr/bin:/bin \
        DISPLAY=:99 \
        VM_ROOT="$VM_ROOT" \
        QEMU_BIN="$TMP_DIR/qemu-system-x86_64" \
        OVMF_CODE="$TMP_DIR/OVMF_CODE.fd" \
        OVMF_VARS="$TMP_DIR/OVMF_VARS.fd" \
        REPAIR_DISPLAY_VARS=off \
        FAKE_QEMU_TRACE="$TMP_DIR/qemu.trace" \
        FAKE_QEMU_ENV_TRACE="$TMP_DIR/qemu-env.trace" \
        "${optional_env[@]}" \
        "$START_VM" "$VM_ID" --dry-run "$@" >"$output" 2>"${output%.out}.err"
}

SDL_OUT="$TMP_DIR/sdl.out"
GTK_OUT="$TMP_DIR/gtk.out"
RDP_OUT="$TMP_DIR/rdp.out"
RESCUE_OUT="$TMP_DIR/rescue.out"
MISSING_RTC_OUT="$TMP_DIR/missing-rtc.out"
V100_OUT="$TMP_DIR/v100.out"
NO_TPM_OUT="$TMP_DIR/no-tpm.out"
NO_PREVIEW_OUT="$TMP_DIR/no-preview.out"
GUEST_CURSOR_OUT="$TMP_DIR/guest-cursor.out"
WAYLAND_OUT="$TMP_DIR/native-wayland.out"
STREAM_OUT="$TMP_DIR/stream.out"
GT1030_OUT="$TMP_DIR/gt1030.out"
VLAN_OUT="$TMP_DIR/vlan.out"

run_start_vm "$SDL_OUT"
require_text "模式=vgpu-sdl" "$SDL_OUT"
require_text "XMODIFIERS=@im=none SDL_IM_MODULE=none IBUS_ADDRESS=/nonexistent NATIVE_EGL=1 SDL_DRIVER=x11 X11_WMCLASS=win10-${VM_ID} WAYLAND_WMCLASS=win10-${VM_ID} WINDOW_MODE= CURSOR_MODE=host args=-display help" \
    "$TMP_DIR/qemu-env.trace"
require_text 'ide-cd.bootindex=-1' "$SDL_OUT"
reject_text 'id=odd0' "$SDL_OUT"
reject_text 'id=g11-odd' "$SDL_OUT"
reject_text 'id=installboot' "$SDL_OUT"
reject_text 'g11-usb-install-boot.img' "$SDL_OUT"
reject_text 'scsi-cd' "$SDL_OUT"
require_text 'vGPU resource: nvidia-257/2048MB' "$SDL_OUT"
require_native_vfio "$SDL_OUT"
require_vgpu_root_port "$SDL_OUT"
require_text 'x-pci-device-id=0x0C01' "$SDL_OUT"
require_text 'x-pci-revision=0x06' "$SDL_OUT"
require_tpm2 "$SDL_OUT"
require_text "sdl\\,gl=on\\,title=win10-${VM_ID}\\,single-console=on" "$SDL_OUT"
require_text "fb-shm\\,id=dgame-preview-vm${VM_ID}\\,path=${VM_ROOT}/${VM_ID}/run/dgame-fb-shm.sock\\,rate=60" \
    "$SDL_OUT"
require_text 'DGame transport: GPU first (active display EGL/dma-buf)' "$SDL_OUT"
require_text 'DGame fallback: per-client SHM' "$SDL_OUT"
require_text 'processor-upgrade=0x2D' "$SDL_OUT"
require_text 'rank=1\,rank-list=1\|1\,voltage=1500' "$SDL_OUT"
require_text 'firmware-rev=1.0' "$SDL_OUT"
require_text 'qemu-xhci\,id=xhci\,bus=pcie.0\,addr=0x6' "$SDL_OUT"
if grep -F -- 'qemu-xhci\,' "$SDL_OUT" |
        grep -Eq 'x-pci-(vendor-id|device-id|revision)'; then
    fail 'native start projected physical PCI facts onto qemu-xhci'
fi
require_text 'i8042=off' "$SDL_OUT"
require_text '旧 vm.conf 缺少 SSD PCIe 链路元数据' "${SDL_OUT%.out}.err"
require_text '旧 vm.conf 缺少 xHCI 平台事实；按 CPU_MODEL 补齐校验数据，运行时仍固定上游 qemu-xhci 身份' \
    "${SDL_OUT%.out}.err"
require_text '键盘: Microsoft Wired Keyboard 600 legacy tuple / usb-kbd / USB 045E:0750 / SN=none / compat_legacy_identity_only' \
    "$SDL_OUT"
require_text '绝对指针: PenTablet historical branded tuple / usb-tablet / USB 256C:006D / SN=none / quarantined_protocol_mismatch' \
    "$SDL_OUT"
require_text 'usb-kbd\,id=kbd0\,bus=xhci.0\,usb_version=2\,vendorid=0x045E\,productid=0x0750\,bcd-device=0x0163\,manufacturer=Microsoft\,product=Microsoft\ Wired\ Keyboard\ 600\,x-force-numlock-on=on' \
    "$SDL_OUT"
require_text 'usb-tablet\,bus=xhci.0\,usb_version=2\,vendorid=0x256C\,productid=0x006D\,bcd-device=0x0100\,manufacturer=HUION\,product=HUION\ PenTablet' \
    "$SDL_OUT"
require_text "unix:${VM_ROOT}/${VM_ID}/run/qmp.sock\\,server\\,nowait\\,multi=on" \
    "$SDL_OUT"
if grep -F -- 'usb-kbd\,' "$SDL_OUT" | grep -Fq -- 'serial=' ||
        grep -F -- 'usb-tablet\,' "$SDL_OUT" | grep -Fq -- 'serial='; then
    fail 'legacy USB HID fallback invented a descriptor serial number'
fi
reject_text 'show-cursor=on' "$SDL_OUT"
reject_text 'gtk\,gl=on' "$SDL_OUT"
require_no_legacy_transport "$SDL_OUT"
require_text 'bridge\,id=net0\,br=br0\,helper=/usr/local/libexec/qemu-g11-bridge-helper' \
    "$SDL_OUT"
reject_text 'g11t' "$SDL_OUT"

TEST_NATIVE_WAYLAND=1 run_start_vm "$WAYLAND_OUT" --no-dgame-preview-gpu
require_text "模式=vgpu-sdl" "$WAYLAND_OUT"
require_text "NATIVE_EGL=0 SDL_DRIVER=wayland X11_WMCLASS=win10-${VM_ID} WAYLAND_WMCLASS=win10-${VM_ID} WINDOW_MODE=native-wayland-v1 CURSOR_MODE=host args=-display help" \
    "$TMP_DIR/qemu-env.trace"
require_text "sdl\,gl=on\,title=win10-${VM_ID}\,single-console=on" \
    "$WAYLAND_OUT"
require_text "fb-shm\,id=dgame-preview-vm${VM_ID}\,path=${VM_ROOT}/${VM_ID}/run/dgame-fb-shm.sock\,rate=60" \
    "$WAYLAND_OUT"
require_text 'DGame transport: GPU-first disabled; SHM fallback retained' \
    "$WAYLAND_OUT"
reject_text 'DGame transport: GPU first' "$WAYLAND_OUT"

run_start_vm "$GUEST_CURSOR_OUT" --guest-cursor
require_text "模式=vgpu-sdl" "$GUEST_CURSOR_OUT"
require_text "CURSOR_MODE=guest args=-display help" "$TMP_DIR/qemu-env.trace"
require_text "sdl\,gl=on\,title=win10-${VM_ID}\,single-console=on" \
    "$GUEST_CURSOR_OUT"
reject_text 'show-cursor=on' "$GUEST_CURSOR_OUT"

run_start_vm "$NO_PREVIEW_OUT" --no-dgame-preview
reject_text 'id=dgame-preview-vm' "$NO_PREVIEW_OUT"
reject_text 'DGame transport:' "$NO_PREVIEW_OUT"
reject_text 'multi=on' "$NO_PREVIEW_OUT"

run_start_vm "$VLAN_OUT" --vlan-id 11
require_text "网络: access VLAN 11 / g11t${VM_ID} -> br0（guest untagged）" \
    "$VLAN_OUT"
require_text "tap\,id=net0\,ifname=g11t${VM_ID}\,script=no\,downscript=/usr/local/libexec/qemu-g11-vlan-down" \
    "$VLAN_OUT"
reject_text 'bridge\,id=net0\,br=br0' "$VLAN_OUT"
[[ -z "$(find "$VM_ROOT/${VM_ID}/run" -mindepth 1 -print -quit)" ]] \
    || fail "VLAN dry-run created TAP marker/runtime state"

# VLAN is a launch-time network domain, never persistent guest hardware.
cp -- "$VM_ROOT/${VM_ID}/vm.conf" "$TMP_DIR/vm.conf.no-vlan"
printf 'VLAN_ID=99\n' >>"$VM_ROOT/${VM_ID}/vm.conf"
run_start_vm "$TMP_DIR/config-vlan.out"
require_text '网络: br0 默认/native LAN' "$TMP_DIR/config-vlan.out"
reject_text "g11t${VM_ID}" "$TMP_DIR/config-vlan.out"
mv -- "$TMP_DIR/vm.conf.no-vlan" "$VM_ROOT/${VM_ID}/vm.conf"

if run_start_vm "$TMP_DIR/vlan-duplicate.out" --vlan-id 11 --vlan-id=12; then
    fail 'duplicate --vlan-id was accepted'
fi
require_text '--vlan-id 只能指定一次' "$TMP_DIR/vlan-duplicate.err"
if run_start_vm "$TMP_DIR/vlan-invalid.out" --vlan-id 4095; then
    fail 'reserved VLAN 4095 was accepted'
fi
require_text '必须是 1..4094' "$TMP_DIR/vlan-invalid.err"

run_start_vm "$GTK_OUT" --gtk --proxy
require_text "模式=vgpu-gtk" "$GTK_OUT"
require_native_vfio "$GTK_OUT"
require_vgpu_root_port "$GTK_OUT"
require_tpm2 "$GTK_OUT"
require_text 'gtk\,gl=on\,show-cursor=on\,grab-on-hover=on' "$GTK_OUT"
require_text "fb-shm\\,id=dgame-preview-vm${VM_ID}\\,path=${VM_ROOT}/${VM_ID}/run/dgame-fb-shm.sock\\,rate=60" \
    "$GTK_OUT"
require_text "unix:${VM_ROOT}/${VM_ID}/run/qmp.sock\\,server\\,nowait\\,multi=on" \
    "$GTK_OUT"
require_text "QMP multi: native multi-client on ${VM_ROOT}/${VM_ID}/run/qmp.sock" \
    "$GTK_OUT"
require_text "QMP alias: ${VM_ROOT}/${VM_ID}/run/qmp.sock.proxy" \
    "$GTK_OUT"
[[ ! -e "$VM_ROOT/${VM_ID}/run/qmp.sock.proxy" &&
   ! -L "$VM_ROOT/${VM_ID}/run/qmp.sock.proxy" ]] \
    || fail "--proxy dry-run created a QMP compatibility alias"
require_no_legacy_transport "$GTK_OUT"

# GT 1030 is a PCIe 3.0 x4 card even though the physical desktop slot is x16.
# Exercise the profile-specific root-port width without allocating an mdev.
cp -- "$VM_ROOT/${VM_ID}/vm.conf" "$TMP_DIR/vm.conf.gtx1050"
sed -i 's/^GPU_PROFILE=.*/GPU_PROFILE=gt1030_2gb/' \
    "$VM_ROOT/${VM_ID}/vm.conf"
run_start_vm "$GT1030_OUT"
require_native_vfio "$GT1030_OUT"
require_vgpu_root_port "$GT1030_OUT" 4
reject_text 'x-width=16' "$GT1030_OUT"
mv -- "$TMP_DIR/vm.conf.gtx1050" "$VM_ROOT/${VM_ID}/vm.conf"

run_start_vm "$STREAM_OUT" \
    --stream 'rtmp://ingest.example/live/supersecret' \
    --stream-roi 100,50,1280,720 --stream-rate 60 \
    --stream-encoder h264_nvenc --stream-bitrate 8M --stream-mode shm
require_text 'fb-shm\,id=stream-vm' "$STREAM_OUT"
require_text 'fb-shm\,id=dgame-preview-vm' "$STREAM_OUT"
require_text 'rate=60\,x=100\,y=50\,width=1280\,height=720' "$STREAM_OUT"
require_text '推流: fb-shm 60Hz mode=shm encoder=h264_nvenc target=rtmp://...' \
    "$STREAM_OUT"
require_text '推流 ROI: 1280x720@100,50' "$STREAM_OUT"
require_text 'NVENC 接收 SHM rawvideo 后仍有 GPU upload，不是零拷贝' \
    "$STREAM_OUT"
reject_text 'supersecret' "$STREAM_OUT"

if run_start_vm "$TMP_DIR/stream-listener.out" \
        --stream 'srt://0.0.0.0:9000?mode=listener'; then
    fail 'stream listener/wildcard target was accepted'
fi
require_text '禁止 listener 模式' "$TMP_DIR/stream-listener.err"

if run_start_vm "$TMP_DIR/stream-gpu.out" \
        --stream 'rtmp://ingest.example/live/vm' --stream-mode gpu; then
    fail 'R535 strict GPU zero-copy mode was accepted'
fi
require_text 'R535 VFIO display REGION 不导出 DMA-BUF' \
    "$TMP_DIR/stream-gpu.err"

if run_start_vm "$TMP_DIR/stream-rescue.out" --rescue-sdl \
        --stream 'rtmp://ingest.example/live/vm'; then
    fail 'streaming was accepted outside native vGPU mode'
fi
require_text '仅支持 G-11 native vGPU SDL/GTK 模式' \
    "$TMP_DIR/stream-rescue.err"

run_start_vm "$RESCUE_OUT" --rescue-sdl
require_text '模式=rescue-sdl' "$RESCUE_OUT"
require_text 'VGA\,id=rescue-vga\,bus=pcie.0\,addr=0x2' "$RESCUE_OUT"
require_text 'sdl\,gl=off' "$RESCUE_OUT"
require_text '标准显卡 -> SDL 本地救援（无 vGPU/VNC/RDP）' "$RESCUE_OUT"
require_text 'base=localtime\,clock=vm\,driftfix=slew' "$RESCUE_OUT"
require_text 'kvm-pit.lost_tick_policy=delay' "$RESCUE_OUT"
reject_text 'vfio-pci' "$RESCUE_OUT"
reject_text 'vnc=' "$RESCUE_OUT"
reject_text 'id=odd0' "$RESCUE_OUT"
reject_text 'id=g11-odd' "$RESCUE_OUT"
reject_text 'id=installboot' "$RESCUE_OUT"
reject_text 'g11-usb-install-boot.img' "$RESCUE_OUT"

# Configs created before RTC_CONTRACT was persisted must retain the production
# local-RTC behavior.  In particular, absence of the field is not evidence that
# the guest opted into the short-lived UTC compatibility contract.
cp -- "$VM_ROOT/${VM_ID}/vm.conf" "$TMP_DIR/vm.conf.with-rtc"
sed -i '/^RTC_CONTRACT=/d' "$VM_ROOT/${VM_ID}/vm.conf"
run_start_vm "$MISSING_RTC_OUT" --rescue-sdl
require_text 'base=localtime\,clock=vm\,driftfix=slew' "$MISSING_RTC_OUT"
require_text 'kvm-pit.lost_tick_policy=delay' "$MISSING_RTC_OUT"
reject_text 'base=utc\,clock=vm' "$MISSING_RTC_OUT"
mv -- "$TMP_DIR/vm.conf.with-rtc" "$VM_ROOT/${VM_ID}/vm.conf"

run_start_vm "$RDP_OUT" --rdp
require_text "模式=rdp" "$RDP_OUT"
require_text 'vfio-pci\,sysfsdev=' "$RDP_OUT"
require_text 'display=off' "$RDP_OUT"
require_text 'bus=gpu-root-port\,addr=0x0' "$RDP_OUT"
require_vgpu_root_port "$RDP_OUT"
require_text "vnc=:${VM_ID}" "$RDP_OUT"
require_text 'memory-backend-file\,id=ivshm' "$RDP_OUT"
require_text 'size=67108864' "$RDP_OUT"
require_text 'ivshmem-plain\,memdev=ivshm' "$RDP_OUT"
require_tpm2 "$RDP_OUT"
reject_text 'vfio-pci-nohotplug' "$RDP_OUT"

run_start_vm "$NO_TPM_OUT" --rdp --no-tpm
require_text 'TPM: disabled (explicit)' "$NO_TPM_OUT"
reject_text 'socket\,id=chrtpm\,path=' "$NO_TPM_OUT"
reject_text 'tpm-crb\,tpmdev=tpm0' "$NO_TPM_OUT"

# A fixed 2 GiB host tier can select a V100 mdev by sysfs name while the VM's
# guest-visible identity remains the catalog's GTX 1050.  Dry-run deliberately
# does not require the physical V100 to be present.
cat >"$TMP_DIR/vgpu-host-v100.conf" <<'EOF'
VGPU_MGPU=auto
VGPU_HOST_FB_TIER_MB=2048
VGPU_RESOURCE_PROFILE=V100-2Q
VGPU_RESOURCE_FB_MB=2048
VGPU_TOTAL_FB_MB=16384
VGPU_CONSOLE_INTERVAL_US=0
EOF
TEST_VGPU_HOST_CONFIG="$TMP_DIR/vgpu-host-v100.conf"
run_start_vm "$V100_OUT"
require_text 'vGPU resource: V100-2Q/2048MB' "$V100_OUT"
require_text 'GPU identity: gtx1050_2gb / NVIDIA GeForce GTX 1050' "$V100_OUT"
require_native_vfio "$V100_OUT"
require_vgpu_root_port "$V100_OUT"
require_tpm2 "$V100_OUT"
require_no_legacy_transport "$V100_OUT"

# The same fixed 2 GiB host tier must reject a 1 GiB catalog identity before
# probing QEMU or touching runtime state.
cp -- "$VM_ROOT/${VM_ID}/vm.conf" "$TMP_DIR/vm.conf.2gb"
sed -i 's/^GPU_PROFILE=.*/GPU_PROFILE=gtx750_asus_1gb/' \
    "$VM_ROOT/${VM_ID}/vm.conf"
if run_start_vm "$TMP_DIR/v100-1q.out"; then
    fail 'fixed 2 GiB V100 tier accepted a 1 GiB guest identity'
fi
require_text 'VM 要求 1024MB，但宿主固定档是 2048MB' \
    "$TMP_DIR/v100-1q.err"
mv -- "$TMP_DIR/vm.conf.2gb" "$VM_ROOT/${VM_ID}/vm.conf"
unset TEST_VGPU_HOST_CONFIG

# start-vm must enforce the same fail-closed host-policy loader as create-vm;
# otherwise a bad policy can silently fall back to the VM's legacy mdev type.
ln -s "$TMP_DIR/vgpu-host-v100.conf" "$TMP_DIR/vgpu-host-link.conf"
TEST_VGPU_HOST_CONFIG="$TMP_DIR/vgpu-host-link.conf"
if run_start_vm "$TMP_DIR/host-link.out"; then
    fail 'start-vm followed a symlinked host vGPU config'
fi
require_text '可读普通非符号链接文件' "$TMP_DIR/host-link.err"

mkdir "$TMP_DIR/vgpu-host-directory.conf"
TEST_VGPU_HOST_CONFIG="$TMP_DIR/vgpu-host-directory.conf"
if run_start_vm "$TMP_DIR/host-directory.out"; then
    fail 'start-vm sourced a directory as host vGPU config'
fi
require_text '可读普通非符号链接文件' "$TMP_DIR/host-directory.err"

printf '%s\n' 'VGPU_HOST_FB_TIER_MB=(' >"$TMP_DIR/vgpu-host-syntax.conf"
TEST_VGPU_HOST_CONFIG="$TMP_DIR/vgpu-host-syntax.conf"
if run_start_vm "$TMP_DIR/host-syntax.out"; then
    fail 'start-vm swallowed a host vGPU config syntax error'
fi
if ! grep -Fq 'VGPU_HOST_CONFIG 加载失败' "$TMP_DIR/host-syntax.err" &&
        ! grep -Eq 'syntax error|unexpected EOF' "$TMP_DIR/host-syntax.err"; then
    fail 'start-vm host config syntax refusal was not clear'
fi

printf '%s\n' 'VGPU_HOST_FB_TIER_MB=2048' \
    >"$TMP_DIR/vgpu-host-unreadable.conf"
chmod 000 "$TMP_DIR/vgpu-host-unreadable.conf"
TEST_VGPU_HOST_CONFIG="$TMP_DIR/vgpu-host-unreadable.conf"
if run_start_vm "$TMP_DIR/host-unreadable.out"; then
    chmod 600 "$TMP_DIR/vgpu-host-unreadable.conf"
    fail 'start-vm accepted an unreadable host vGPU config'
fi
chmod 600 "$TMP_DIR/vgpu-host-unreadable.conf"
require_text '可读普通非符号链接文件' "$TMP_DIR/host-unreadable.err"

TEST_VGPU_HOST_CONFIG="$TMP_DIR/missing-vgpu-host.conf"
if run_start_vm "$TMP_DIR/host-missing.out"; then
    fail 'start-vm accepted a missing explicit host vGPU config'
fi
require_text 'VGPU_HOST_CONFIG 不存在' "$TMP_DIR/host-missing.err"
unset TEST_VGPU_HOST_CONFIG

cat >"$TMP_DIR/vgpu-host-bad-fb.conf" <<'EOF'
VGPU_RESOURCE_PROFILE=V100-4Q
VGPU_RESOURCE_FB_MB=4096
VGPU_TOTAL_FB_MB=16384
EOF
TEST_VGPU_HOST_CONFIG="$TMP_DIR/vgpu-host-bad-fb.conf"
if run_start_vm "$TMP_DIR/bad-fb.out" 2>"$TMP_DIR/bad-fb.err"; then
    fail 'host resource framebuffer diverged from the guest identity'
fi
require_text 'guest 显存 2048MB 与宿主 mdev 4096MB 不一致' \
    "$TMP_DIR/bad-fb.err"
unset TEST_VGPU_HOST_CONFIG

# Every vGPU run probes the root-port link/identity properties.  Native runs
# also probe their display backend and ramfb support; DGame preview and external
# streaming share one fb-shm capability probe.  Invalid configurations fail
# before any probe.  The explicit --no-dgame-preview run omits that one probe;
# the explicit guest-cursor and native-Wayland SDL runs each exercise the same
# four normal probes; Wayland disables GPU-first but retains the fb-shm object.
QEMU_PROBE_COUNT=$(wc -l <"$TMP_DIR/qemu.trace")
[[ "$QEMU_PROBE_COUNT" -eq 41 ]] \
    || fail "fake QEMU saw an unexpected invocation count: $QEMU_PROBE_COUNT"

[[ -z "$(find "$VM_ROOT/control" -mindepth 1 -print -quit)" ]] \
    || fail "dry-run created runtime state"
[[ -z "$(find "$VM_ROOT/${VM_ID}/run" -mindepth 1 -print -quit)" ]] \
    || fail "dry-run created per-instance TPM/runtime state"
[[ ! -e "$VM_ROOT/${VM_ID}/tpm" ]] \
    || fail "dry-run created persistent TPM state"
[[ ! -e "$SHMEM_PATH" ]] || fail "dry-run created legacy shared memory"
[[ ! -e "/sys/bus/mdev/devices/$DRY_MDEV_UUID" ]] || fail "dry-run created an mdev"
grep -Fq 'QEMU_LOG=$(vm_storage_log_path "$VM_ID")' "$START_VM" \
    || fail "QEMU log no longer resolves inside the VM bundle"
grep -Fq '2> >(tee -a "$QEMU_LOG" >&2)' "$START_VM" \
    || fail "foreground/native QEMU modes no longer retain stderr logs"

echo "PASS: root start-vm native SDL/GTK and legacy RDP dry-run argv"
