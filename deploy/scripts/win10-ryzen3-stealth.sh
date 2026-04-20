#!/bin/bash
# ---------------------------------------------------------------------------
# win10-ryzen3-stealth.sh
#
# Launches a deeply-hidden QEMU/KVM Win10 guest posing as bare-metal
# AMD Ryzen 3 1200 + random AM4 motherboard + 8GB dual-channel + Samsung
# 970 PRO 512GB (PCIe 3.0 x4) + GTX 1050-class virtual display.
#
#  Usage:
#     ./win10-ryzen3-stealth.sh 1                    # instance 1, disk, br0
#     ./win10-ryzen3-stealth.sh 2                    # instance 2, disk, br0
#     ./win10-ryzen3-stealth.sh 1 --iso=/path/x.iso  # boot ISO (install media)
#     ./win10-ryzen3-stealth.sh 1 --headless         # no SDL, VNC only
#     ./win10-ryzen3-stealth.sh 1 --bridge=br1       # use a non-default bridge
#     ./win10-ryzen3-stealth.sh 1 --no-bridge        # fall back to NAT
#
#  Hardware identity is randomized exactly once — on the first launch for a
#  given instance — and persisted to
#      /home/ubuntu/images/stealth-inst<INSTANCE>.profile
#  Subsequent launches re-use it so Windows / anti-cheat sees the same
#  motherboard / serials / MAC / UUID forever. Run
#      deploy/scripts/reroll-identity.sh <INSTANCE>
#  (or delete the .profile file) to force a re-roll on next launch.
#
#  Environment overrides (all flags have matching env vars too):
#     RAM=8192         MiB of guest RAM (default 8192)
#     CPUS=4           vCPUs (default 4, cores=4, threads=1, sockets=1)
#     HEADLESS=1       disable SDL, use VNC only     (flag: --headless)
#     BRIDGE=br0       host bridge name              (flag: --bridge=br0)
#     ISO=<path>       installer ISO (implies iso boot, flag: --iso=<path>)
#     DISK=<path>      qcow2 disk path               (flag: --disk=<path>)
#     QEMU=<path>      path to qemu-system-x86_64    (flag: --qemu=<path>)
# ---------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# When running from deploy/scripts/, the QEMU repo root is two levels up.
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
source "$HERE/stealth-lib.sh"

_usage() {
    sed -n '2,/^# --*$/p' "$0" | sed -e 's/^# *//' -e 's/^#$//' >&2
    exit "${1:-2}"
}

# ---------------------- CLI parsing ----------------------
# First positional arg = INSTANCE. Everything else is --flag=value or --flag.
_cli_instance=""
_cli_iso=""
_cli_reroll=0
while (( $# > 0 )); do
    case "$1" in
        -h|--help) _usage 0 ;;
        --iso=*)      _cli_iso="${1#*=}" ;;
        --disk=*)     DISK="${1#*=}" ;;
        --bridge=*)   BRIDGE="${1#*=}" ;;
        --no-bridge)  NO_BRIDGE=1 ;;
        --qemu=*)     QEMU="${1#*=}" ;;
        --ram=*)      RAM="${1#*=}" ;;
        --cpus=*)     CPUS="${1#*=}" ;;
        --headless)   HEADLESS=1 ;;
        --reroll)     _cli_reroll=1 ;;
        --)           shift; break ;;
        -*)
            echo "ERROR: unknown flag '$1'" >&2
            _usage ;;
        *)
            if [[ -z "$_cli_instance" ]]; then
                _cli_instance="$1"
            else
                echo "ERROR: unexpected positional argument '$1'" >&2
                _usage
            fi ;;
    esac
    shift
done

# ---------------- defaults ----------------
: "${INSTANCE:=${_cli_instance:-1}}"
[[ -n "$_cli_instance" ]] && INSTANCE="$_cli_instance"
if ! [[ "$INSTANCE" =~ ^[0-9]+$ ]] || (( INSTANCE < 1 )); then
    echo "ERROR: INSTANCE must be a positive integer (got: '$INSTANCE')" >&2
    exit 2
fi

: "${RAM:=8192}"
: "${CPUS:=4}"
: "${HEADLESS:=0}"
: "${ISO:=${_cli_iso:-/home/ubuntu/images/win10.iso}}"
[[ -n "$_cli_iso" ]] && ISO="$_cli_iso"
: "${DISK:=/home/ubuntu/images/win10-inst${INSTANCE}.qcow2}"
: "${QEMU:=$REPO_ROOT/build/qemu-system-x86_64}"
# Bridge is the default network backend. Pass BRIDGE= (empty) or NO_BRIDGE=1
# to opt out and fall back to user-mode NAT. Reason: a real LAN IP is the
# whole point of the stealth bundle for DNF — user mode's 10.0.2.x subnet
# is itself a VM signal.
: "${BRIDGE:=br0}"
[[ "${NO_BRIDGE:-0}" == "1" ]] && BRIDGE=""
PROFILE_FILE="/home/ubuntu/images/stealth-inst${INSTANCE}.profile"

# Low-entropy bash RANDOM seed only used when we re-roll identity; the saved
# profile pins the final values, so reseed quality doesn't matter for steady
# state.
RANDOM=$((INSTANCE * 13 + $(date +%s) % 32768))

# -------------------------------------------------------------------
# Per-instance disk creation (thin 512GB qcow2 on first run — Samsung 970 PRO)
# -------------------------------------------------------------------
if [[ ! -f "$DISK" ]]; then
    echo ">> creating fresh 512GB qcow2 at $DISK"
    /home/ubuntu/projects/qemu/build/qemu-img create -f qcow2 -o preallocation=off,cluster_size=65536 \
        "$DISK" 512000000000
fi

# -------------------------------------------------------------------
# Boot source:
#   --iso=<path>  -> boot from that ISO (install media)
#   (no flag)     -> boot from the qcow2 disk
# -------------------------------------------------------------------
if [[ -n "$_cli_iso" ]]; then
    BOOT="iso"
else
    BOOT="disk"
fi

# -------------------------------------------------------------------
# Hardware identity — random on creation, stable afterwards.
#
# First launch (profile file missing) or --reroll: randomize + save.
# Subsequent launches: source the saved profile. This is what keeps
# Windows from re-activating every boot and what stops XignCode3 from
# noticing the motherboard serial flipping between sessions.
# -------------------------------------------------------------------
if (( _cli_reroll )); then
    echo ">> --reroll: regenerating hardware identity for instance $INSTANCE"
    rm -f "$PROFILE_FILE"
fi

if stealth_have_profile "$PROFILE_FILE"; then
    stealth_load_profile "$PROFILE_FILE"
    echo ">> profile:     loaded from $PROFILE_FILE"
else
    stealth_pick_profile
    stealth_save_profile "$PROFILE_FILE"
    echo ">> profile:     NEW identity saved to $PROFILE_FILE"
fi
stealth_print_profile

# -------------------------------------------------------------------
# Port/socket allocation (offset by INSTANCE)
# -------------------------------------------------------------------
QMP_SOCK="/tmp/qemu-stealth-${INSTANCE}.qmp"
MON_SOCK="/tmp/qemu-stealth-${INSTANCE}.mon"
VNC_DISPLAY=$(( INSTANCE - 1 ))              # VNC port 5900 + display
SPICE_PORT=$(( 5930 + INSTANCE ))
SSH_FWD_PORT=$(( 10022 + INSTANCE ))
RDP_FWD_PORT=$(( 13389 + INSTANCE ))
# MAC: use the NIC_MAC already picked by stealth_pick_profile (Realtek/Intel/ASUS
# OUI pool). Do NOT reuse the 52:54:00 QEMU/KVM OUI — that's a one-line tell.
MAC_OVERRIDE="$NIC_MAC"

rm -f "$QMP_SOCK" "$MON_SOCK"

# -------------------------------------------------------------------
# OVMF firmware (UEFI SecureBoot-capable -> looks like modern PC).
# Per-instance VARS copy so each VM has its own NVRAM.
# -------------------------------------------------------------------
OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd
OVMF_VARS_SRC=/usr/share/OVMF/OVMF_VARS_4M.fd
OVMF_VARS=/home/ubuntu/images/ovmf-vars-${INSTANCE}.fd
if [[ ! -f "$OVMF_VARS" ]]; then
    cp "$OVMF_VARS_SRC" "$OVMF_VARS"
fi

# -------------------------------------------------------------------
# SMBIOS arg list. Tell stealth_smbios_args what per-DIMM capacity to
# declare (so the part# picked matches the actual memory backend size).
# -------------------------------------------------------------------
export MEM_PER_DIMM_MB=$(( RAM / 2 ))
SMBIOS_ARGS=()
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    SMBIOS_ARGS+=("-smbios" "$line")
done < <(stealth_smbios_args)

# -------------------------------------------------------------------
# Guest display: virtio-gpu-gl for 3D accel (DNF needs DirectX).
# We label it as a GTX 1050-class adapter only at the SMBIOS level;
# real GPU driver spoofing requires guest-side INF tweak documented in
# NOTES-GPU.md. virtio-gpu accepts OpenGL via VirGL and Mesa d3d->gl.
# Fallback to qxl-vga if HEADLESS is set.
# -------------------------------------------------------------------
if [[ "$HEADLESS" == "1" ]]; then
    # Headless: VNC only. virtio-vga (no GL) because SPICE GL is local-only
    # and VNC doesn't render OpenGL output. Guest-side DirectX still goes
    # through the Mesa/WARP software renderer via the VirtIO GPU DOD driver
    # - enough for DNF's 2D UI layer.
    #
    # edid=on + xres/yres causes the device to synthesize an EDID block
    # advertising 1920x1080 as the *preferred* mode, which OVMF's GOP and
    # Windows' virtio display driver both honor on first output probe.
    # Without edid=on, UEFI shell + Windows setup default to 1024x768.
    DISP_ARGS=(
        -display none
        -vnc 127.0.0.1:$VNC_DISPLAY
        -device virtio-vga,edid=on,xres=1920,yres=1080
    )
else
    DISP_ARGS=(
        -display sdl,gl=on,show-cursor=on
        -device virtio-vga-gl,edid=on,xres=1920,yres=1080
    )
fi

# -------------------------------------------------------------------
# Boot order
#
# UEFI ignores `-boot order=...` (that's a BIOS directive) and `strict=on`
# can stop OVMF from walking the El Torito UEFI entry when bootindex=
# is set on devices. We rely purely on bootindex= on the -device lines
# and keep -boot minimal: menu + a visible splash window so you can hit
# ESC/F12 and enter the OVMF Boot Manager if auto-boot ever misses.
# -------------------------------------------------------------------
BOOT_ORDER="menu=on,splash-time=5000,reboot-timeout=5000"
if [[ "$BOOT" == "iso" ]]; then
    CDROM_ARGS=(
        -drive file="$ISO",media=cdrom,if=none,id=cd0,readonly=on
        -device ide-cd,drive=cd0,bus=ide.0,bootindex=1
    )
else
    CDROM_ARGS=()
fi

# -------------------------------------------------------------------
# Network backend: bridge (LAN-attached) vs user-mode NAT.
#
# Bridge mode puts the guest on the host's LAN with its own DHCP lease,
# which matters for DNF because anti-cheat treats 10.0.2.x / 192.168.76.x
# NAT subnets as virtual-machine signals. User mode is kept as the default
# fallback for hosts without bridge setup.
# -------------------------------------------------------------------
if [[ -n "${BRIDGE:-}" ]]; then
    _bridge_fail=""
    if ! ip link show "$BRIDGE" &>/dev/null; then
        _bridge_fail="bridge '$BRIDGE' does not exist"
    elif ! grep -q "^allow $BRIDGE" /etc/qemu/bridge.conf 2>/dev/null; then
        _bridge_fail="/etc/qemu/bridge.conf missing 'allow $BRIDGE'"
    fi
    if [[ -n "$_bridge_fail" ]]; then
        echo ">> WARN: $_bridge_fail"
        echo ">>       falling back to user-mode NAT. Run 'sudo deploy/scripts/setup-bridge.sh'"
        echo ">>       (with UPLINK=<iface> for a LAN bridge) to enable bridge mode."
        BRIDGE=""
    fi
fi
if [[ -n "${BRIDGE:-}" ]]; then
    # Pick the first qemu-bridge-helper we find with cap_net_admin (or suid).
    # The source-built QEMU defaults to /usr/local/libexec/qemu-bridge-helper
    # which won't exist on a stock Ubuntu host — passing helper= explicitly
    # removes that entire class of "-netdev bridge: failed to launch helper"
    # errors. setup-bridge.sh also symlinks that path for safety.
    BRIDGE_HELPER=""
    for h in /usr/lib/qemu/qemu-bridge-helper \
             /usr/libexec/qemu-bridge-helper \
             /usr/local/libexec/qemu-bridge-helper \
             "$REPO_ROOT/build/qemu-bridge-helper"; do
        if [[ -x "$h" ]] && { getcap "$h" 2>/dev/null | grep -q cap_net_admin || [[ -u "$h" ]]; }; then
            BRIDGE_HELPER="$h"; break
        fi
    done
    if [[ -z "$BRIDGE_HELPER" ]]; then
        echo "ERROR: no qemu-bridge-helper with cap_net_admin/suid found." >&2
        echo "       Run 'sudo deploy/scripts/setup-bridge.sh' (it installs the apt package + grants caps)." >&2
        exit 1
    fi
    NET_ARGS=(
        -netdev "bridge,id=net0,br=$BRIDGE,helper=$BRIDGE_HELPER"
    )
    echo ">> network:     bridge=$BRIDGE via $BRIDGE_HELPER (guest gets LAN IP via DHCP)"
else
    NET_ARGS=(
        -netdev user,id=net0,hostfwd=tcp:127.0.0.1:$SSH_FWD_PORT-:22,hostfwd=tcp:127.0.0.1:$RDP_FWD_PORT-:3389
    )
    echo ">> network:     user-mode NAT (SSH 127.0.0.1:$SSH_FWD_PORT, RDP 127.0.0.1:$RDP_FWD_PORT)"
fi

# -------------------------------------------------------------------
# Assemble the command line
# -------------------------------------------------------------------
CMD=(
    "$QEMU"

    # --- Machine / firmware ---
    # ACPI OEM IDs default to "ALASKA"/"A M I   " from our aml-build.h patch;
    # no need to pass x-oem-id on the cmdline. smm=on is required for OVMF S3.
    -name "win10-ryzen3-${INSTANCE},debug-threads=on"
    -machine q35,accel=kvm,vmport=off,smm=on,hpet=off,kernel-irqchip=split
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE"
    -drive if=pflash,format=raw,file="$OVMF_VARS"

    # --- CPU: hidden hypervisor, hidden KVM, invtsc, AMD Zen1 profile ---
    -cpu Ryzen3-1200,kvm=off,hypervisor=off,+invtsc,+topoext,+tsc-deadline,enforce=off,host-phys-bits=on,tsc-freq=3100000000,vendor=AuthenticAMD
    -smp cpus=$CPUS,cores=$CPUS,threads=1,sockets=1,maxcpus=$CPUS

    # --- Memory: backed by memfd for prealloc, dual-channel via 2 NUMA nodes ---
    -m "${RAM}M"
    -object memory-backend-memfd,id=mem0,size=$((RAM/2))M,share=off,prealloc=on
    -object memory-backend-memfd,id=mem1,size=$((RAM/2))M,share=off,prealloc=on
    -numa node,nodeid=0,memdev=mem0,cpus=0-$((CPUS/2-1))
    -numa node,nodeid=1,memdev=mem1,cpus=$((CPUS/2))-$((CPUS-1))

    # --- Random identifiers ---
    -uuid "$UUID"
    -rtc base=localtime,clock=host,driftfix=slew
    -global kvm-pit.lost_tick_policy=delay
    -boot "$BOOT_ORDER"
    -no-user-config
    -nodefaults

    # --- SMBIOS / DMI override ---
    "${SMBIOS_ARGS[@]}"

    # --- PCI root complex (pcie-pci-bridge hidden; default q35) ---
    -device pcie-root-port,id=rp0,slot=0,bus=pcie.0,multifunction=on
    -device pcie-root-port,id=rp1,slot=1,bus=pcie.0
    -device pcie-root-port,id=rp2,slot=2,bus=pcie.0
    -device pcie-root-port,id=rp3,slot=3,bus=pcie.0

    # --- Storage: virtio-scsi host + Samsung NVMe as system drive ---
    -object iothread,id=io1
    -drive file="$DISK",if=none,id=nvm0,format=qcow2,cache=none,aio=threads,discard=unmap
    -device nvme,id=nvmectl0,bus=rp1,drive=nvm0,\
serial="$NVME_SERIAL",use-samsung-id=on,bootindex=2,\
model-number="Samsung SSD 970 PRO 512GB",firmware-rev=1B2QEXM7

    "${CDROM_ARGS[@]}"

    # --- Network: e1000e emulation (Intel 82574L) w/ random MAC ---
    "${NET_ARGS[@]}"
    -device e1000e,netdev=net0,mac=$MAC_OVERRIDE,bus=rp2

    # --- USB: xHCI + keyboard/mouse/tablet ---
    -device qemu-xhci,id=xhci,bus=rp3
    -device usb-tablet,bus=xhci.0
    -device usb-kbd,bus=xhci.0

    # --- Audio: ICH9 HDA (looks like Realtek ALC). Use 'none' backend
    # unconditionally -- passes driver probe in guest without requiring
    # ALSA/PipeWire on the host. ---
    -audiodev none,id=aud0
    -device intel-hda,id=hda0
    -device hda-duplex,bus=hda0.0,cad=0,audiodev=aud0

    # --- Display ---
    "${DISP_ARGS[@]}"

    # --- Control: QMP + HMP sockets for API access ---
    -chardev socket,id=qmp0,path=$QMP_SOCK,server=on,wait=off
    -mon chardev=qmp0,mode=control
    -chardev socket,id=mon0,path=$MON_SOCK,server=on,wait=off
    -mon chardev=mon0,mode=readline

    # --- Misc anti-detection knobs ---
    -msg timestamp=off
    -overcommit mem-lock=off,cpu-pm=on
)

echo ">> instance:    $INSTANCE"
echo ">> QMP socket:  $QMP_SOCK"
echo ">> HMP socket:  $MON_SOCK"
echo ">> VNC display: :$VNC_DISPLAY (port $((5900+VNC_DISPLAY)))"
echo ">> SSH/RDP fwd: 127.0.0.1:$SSH_FWD_PORT / 127.0.0.1:$RDP_FWD_PORT"
echo ">> boot mode:   $BOOT"
echo ">> disk:        $DISK ($(stat -c%s "$DISK") bytes)"
echo ">> --- launching ---"

exec "${CMD[@]}"
