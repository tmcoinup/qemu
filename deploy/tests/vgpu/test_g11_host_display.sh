#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
helper="$repo_root/deploy/host/g11-host-display.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
write_value() { mkdir -p -- "$(dirname -- "$1")"; printf '%s\n' "$2" >"$1"; }

sys_root="$tmp/sys"
etc_root="$tmp/etc"
run_root="$tmp/run"
journal="$tmp/journal.log"
drivers="$sys_root/bus/pci/drivers"
amd="$sys_root/bus/pci/devices/0000:05:00.0"
nvidia="$sys_root/bus/pci/devices/0000:04:00.0"
mkdir -p "$drivers/amdgpu" "$drivers/nvidia" "$amd/drm/card0" "$nvidia" \
    "$etc_root/systemd/system" "$run_root/gdm3"
ln -s "$drivers/amdgpu" "$amd/driver"
ln -s "$drivers/nvidia" "$nvidia/driver"

write_value "$amd/class" 0x030000
write_value "$amd/vendor" 0x1002
write_value "$amd/device" 0x67df
write_value "$amd/boot_vga" 0
write_value "$nvidia/class" 0x030000
write_value "$nvidia/vendor" 0x10de
write_value "$nvidia/device" 0x1e82
write_value "$nvidia/boot_vga" 1
write_value "$run_root/gdm3/custom.conf" $'[daemon]\nPreferredDisplayServer=xorg'
for _ in 1 2 3 4 5 6; do
    printf '%s\n' 'Cannot run in framebuffer mode. Please specify busIDs for all framebuffer devices' >>"$journal"
done

test_env=(
    G11_HOST_DISPLAY_TEST_MODE=1
    G11_HOST_DISPLAY_SYS_ROOT="$sys_root"
    G11_HOST_DISPLAY_ETC_ROOT="$etc_root"
    G11_HOST_DISPLAY_RUN_ROOT="$run_root"
    G11_HOST_DISPLAY_JOURNAL_FILE="$journal"
)

audit_out=$(env "${test_env[@]}" "$helper" audit 2>&1)
grep -Fq 'display=0000:05:00.0' <<<"$audit_out" || fail 'AMD display BDF missing'
grep -Fq 'vgpu=0000:04:00.0' <<<"$audit_out" || fail 'NVIDIA vGPU BDF missing'
grep -Fq 'firmware_primary=vgpu' <<<"$audit_out" || fail 'firmware mismatch not detected'
grep -Fq 'dropin=absent' <<<"$audit_out" || fail 'fresh audit did not report absent drop-in'
grep -Fq 'preferred=xorg' <<<"$audit_out" || fail 'runtime Xorg preference not detected'
grep -Fq 'xorg_boot_failures=6' <<<"$audit_out" || fail 'Xorg retry count is wrong'

status_json=$(env "${test_env[@]}" "$helper" status --json)
python3 - "$status_json" <<'PY' || fail 'affected JSON status contract is invalid'
import json
import sys

value = json.loads(sys.argv[1])
assert value == {
    "schema": 1,
    "applicable": True,
    "display_bdf": "0000:05:00.0",
    "vgpu_bdf": "0000:04:00.0",
    "firmware_primary": "vgpu",
    "config": "absent",
    "preferred": "xorg",
    "wayland": "default",
    "xorg_boot_failures": 6,
    "recommendation": "apply",
    "managed": False,
    "ready": False,
    "reboot_required": False,
}
PY

apply_out=$(env "${test_env[@]}" "$helper" apply 2>&1)
dropin="$etc_root/systemd/system/gdm.service.d/90-g11-host-display.conf"
[[ -f "$dropin" && ! -L "$dropin" ]] || fail 'apply did not install a regular drop-in'
grep -Fq 'Managed by deploy/host/g11-host-display.sh' "$dropin" || fail 'managed marker missing'
grep -Fq 'Host DRM GPU: 0000:05:00.0 0x1002:0x67df (amdgpu)' "$dropin" ||
    fail 'host GPU binding missing from drop-in'
grep -Fq 'vGPU-only GPU: 0000:04:00.0 0x10de:0x1e82 (nvidia)' "$dropin" ||
    fail 'vGPU binding missing from drop-in'
grep -Fq 'WaylandEnable true' "$dropin" || fail 'Wayland enable override missing'
grep -Fq 'PreferredDisplayServer wayland' "$dropin" || fail 'Wayland preference missing'
grep -Fq '未重启 GDM' <<<"$apply_out" || fail 'apply did not preserve the current desktop'

second_apply=$(env "${test_env[@]}" "$helper" apply 2>&1)
grep -Fq '无需重复写入' <<<"$second_apply" || fail 'apply is not idempotent'

pending_json=$(env "${test_env[@]}" "$helper" status --json)
python3 - "$pending_json" <<'PY' || fail 'pending-reboot JSON status is invalid'
import json
import sys

value = json.loads(sys.argv[1])
assert value["config"] == "exact"
assert value["managed"] is True
assert value["recommendation"] == "reboot"
assert value["reboot_required"] is True
PY

write_value "$run_root/gdm3/custom.conf" $'[daemon]\nWaylandEnable=true\nPreferredDisplayServer=wayland'
: >"$journal"
check_out=$(env "${test_env[@]}" "$helper" check 2>&1)
grep -Fq 'ready=yes' <<<"$check_out" || fail 'post-reboot check did not pass'
ready_json=$(env "${test_env[@]}" "$helper" status --json)
python3 - "$ready_json" <<'PY' || fail 'ready JSON status is invalid'
import json
import sys

value = json.loads(sys.argv[1])
assert value["recommendation"] == "ready"
assert value["ready"] is True
assert value["xorg_boot_failures"] == 0
PY

env "${test_env[@]}" "$helper" rollback >/dev/null
[[ ! -e "$dropin" ]] || fail 'rollback kept the managed drop-in'

mkdir -p -- "$(dirname -- "$dropin")"
write_value "$dropin" $'[Service]\nExecStartPre=/bin/false'
if env "${test_env[@]}" "$helper" apply >/dev/null 2>&1; then
    fail 'apply overwrote a foreign drop-in'
fi
if env "${test_env[@]}" "$helper" rollback >/dev/null 2>&1; then
    fail 'rollback deleted a foreign drop-in'
fi
grep -Fq 'ExecStartPre=/bin/false' "$dropin" || fail 'foreign drop-in was modified'

rm -f -- "$dropin"
mkdir -p "$nvidia/drm/card1"
if env "${test_env[@]}" "$helper" apply >/dev/null 2>&1; then
    fail 'apply accepted an NVIDIA GPU that owns a DRM card'
fi
not_applicable_json=$(env "${test_env[@]}" "$helper" status --json)
python3 - "$not_applicable_json" <<'PY' || fail 'unsupported topology JSON is invalid'
import json
import sys

value = json.loads(sys.argv[1])
assert value["applicable"] is False
assert value["recommendation"] == "not-applicable"
PY

if rg -n 'update-grub|grub-mkconfig|mokutil|modprobe|systemctl restart gdm' "$helper" >/dev/null; then
    fail 'helper crosses its display-manager-only safety boundary'
fi

echo 'PASS: G-11 host AMD display / NVIDIA vGPU-only GDM fix, audit and rollback'
