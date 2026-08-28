#!/usr/bin/env bash
# Rootless contract for the generic first/reinstall GRID black-screen fix.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
start_vm="$repo_root/deploy/scripts/start-vm.sh"
cache_helper="$repo_root/deploy/host/sync-monitor-cache.sh"
sync_monitor="$repo_root/deploy/scripts/sync-monitor-profile.sh"
assets_lib="$repo_root/deploy/lib/vgpu-driver-assets.sh"
gui_installer="$repo_root/deploy/install-vgpu-driver-gui.sh"
installer="$repo_root/deploy/install-vgpu-driver.sh"
orchestrator="$repo_root/deploy/scripts/install-vgpu-driver-safe.sh"
vmctl="$repo_root/deploy/scripts/vmctl.sh"
setup_guest="$repo_root/deploy/setup-guest.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
require_text() {
    local needle=$1 file=$2
    grep -Fq -- "$needle" "$file" || fail "$(basename "$file") omits: $needle"
}

for script in "$start_vm" "$cache_helper" "$sync_monitor" "$gui_installer" \
        "$installer" "$orchestrator" "$vmctl" "$setup_guest"; do
    bash -n "$script" || fail "invalid Bash syntax: $script"
done
[[ -x "$orchestrator" ]] || fail "one-click driver installer is not executable"

# Exercise the exact argv validator used against /proc.  Root-port presentation
# IDs are legitimate; only the VFIO endpoint must remain native and display=off.
# shellcheck source=../../lib/vgpu-driver-assets.sh
source "$assets_lib"
uuid=11111111-2222-3333-4444-555555555555
disk=/images/vms/42/disk.qcow2
safe=(
    qemu-system-x86_64
    -name vm42
    -drive "file=${disk},if=none,id=ssd0,format=qcow2"
    -device 'pcie-root-port,id=gpu-root-port,x-pci-vendor-id=0x8086'
    -device "vfio-pci-nohotplug,sysfsdev=/sys/bus/mdev/devices/${uuid},display=off,enable-migration=off,bus=gpu-root-port,addr=0x0,rombar=0"
    -vga none
    -device 'VGA,id=driver-install-vga,bus=pcie.0,addr=0x2'
    -display 'sdl,gl=off,title=win10-42-driver-install'
)
vgpu_driver_install_argv_is_safe 42 "$disk" "$uuid" "${safe[@]}" ||
    fail "reviewed driver-install argv was rejected"

reject_argv() {
    if vgpu_driver_install_argv_is_safe 42 "$disk" "$uuid" "$@"; then
        fail "unsafe driver-install argv was accepted"
    fi
}

unsafe=( "${safe[@]}" )
unsafe[8]="vfio-pci-nohotplug,sysfsdev=/sys/bus/mdev/devices/${uuid},display=on,ramfb=on,enable-migration=off,bus=gpu-root-port,addr=0x0,rombar=0"
reject_argv "${unsafe[@]}"
unsafe=( "${safe[@]}" )
unsafe[8]="vfio-pci-nohotplug,sysfsdev=/sys/bus/mdev/devices/${uuid},display=off,enable-migration=off,bus=gpu-root-port,addr=0x0,rombar=0,x-pci-device-id=0x1381"
reject_argv "${unsafe[@]}"
unsafe=( "${safe[@]}" )
unsafe[12]='VGA,id=wrong-vga,bus=pcie.0,addr=0x2'
reject_argv "${unsafe[@]}"
reject_argv "${safe[@]/$uuid/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee}"

for required in \
        '--driver-install|--driver-install-sdl' \
        'MODE=driver-install-sdl' \
        'SPOOF_MODE=off' \
        'VGPU_MDEV_INTERNAL_PCI_IDENTITY=0' \
        'VGPU_ROMBAR=0' \
        'driver-install-sdl|driver-install-gtk)' \
        'VGA,id=driver-install-vga,bus=pcie.0,addr=0x2' \
        'vfio-pci-nohotplug,${vfio_opts}' \
        'display=off,enable-migration=off' \
        'sdl,gl=off,title=win10-${VM_ID}-driver-install' \
        'GRID 首装基线已落盘' \
        '拒绝在 NVIDIA native console 上做首次枚举' \
        'vmctl.sh driver-install ${VM_ID}'; do
    require_text "$required" "$start_vm"
done

for required in \
        'hivex pre-driver commit 完成' \
        "raise SystemExit(12)" \
        "raise SystemExit(13)" \
        "printf 'g11-r535-predriver-v1:%s\\n'"; do
    require_text "$required" "$cache_helper"
done
require_text '预驱动完成：安全 EDID/模式缓存已落盘' "$sync_monitor"
require_text 'vgpu_require_safe_driver_install_topology "$VM_ID"' "$gui_installer"
require_text 'driver-install|prepare-driver)' "$vmctl"
require_text 'exec_with_vms_root "$install_vgpu_driver"' "$vmctl"
require_text '本脚本不再在线重装显示驱动' "$setup_guest"

python3 - "$cache_helper" "$gui_installer" "$installer" "$orchestrator" <<'PY'
import sys
from pathlib import Path

cache, gui, installer, orchestrator = [Path(p).read_text() for p in sys.argv[1:]]

# The partial transaction must commit before its distinct exit.  A complete
# marker remains impossible until the authenticated NVIDIA branch returns 0.
pre = cache.index("if current_stats['nvidia'] == 0:")
commit = cache.index('h.commit(None)', pre)
partial_exit = cache.index('raise SystemExit(12)', commit)
full_commit = cache.index("print('[disp-cache] hivex full commit 完成')", partial_exit)
assert pre < commit < partial_exit < full_commit

# Every guest mutation is behind the live topology gate.
topology = gui.index('vgpu_require_safe_driver_install_topology "$VM_ID"')
marker = gui.index('\ninvalidate_monitor_sync_marker\n')
guest_write = gui.index('\npython3 - ', marker)
assert topology < marker < guest_write

# Successful installation is not complete until a graceful full shutdown and
# locked offline convergence have both succeeded.
gui_call = installer.index('"$here/install-vgpu-driver-gui.sh" "${args[@]}"')
shutdown = installer.index('stop-vm.sh" "$VM_ID" --graceful-only', gui_call)
lock = installer.index('flock -w 60 "$START_LOCK_FD"', shutdown)
sync = installer.index('sync-monitor-profile.sh" "$VM_ID" --force', lock)
assert gui_call < shutdown < lock < sync

safe_start = orchestrator.index('"$here/scripts/start-vm.sh" "${start_args[@]}" &')
install = orchestrator.index('"$here/install-vgpu-driver.sh" "${install_args[@]}"', safe_start)
assert safe_start < install
PY

if rg -n -i 'testsigning|nointegritychecks|bcdedit|self[- ]signed|自签' \
        "$assets_lib" "$gui_installer" "$installer" "$orchestrator" >/dev/null; then
    fail "safe driver-install path mentions a forbidden BCD/signing bypass"
fi

echo 'PASS: generic GRID first-install mode isolates R535 console, then shuts down and converges offline'
