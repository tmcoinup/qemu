#!/usr/bin/env bash
# Host-only, per-mdev GPU identity/RM descriptor contract. No guest assets are used.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
HELPER="$REPO_ROOT/deploy/host/update-vgpu-mdev-identity.py"
MDEV_LIB="$REPO_ROOT/deploy/lib/vgpu-mdev.sh"
START_VM="$REPO_ROOT/deploy/scripts/start-vm.sh"
HOST_PROFILE="$REPO_ROOT/deploy/host/profile_override.toml"
UNLOCK_SETUP="$REPO_ROOT/deploy/host/setup-vgpu-unlock.sh"
TMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TMP_DIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

UUID=a94177e0-3318-4e5c-abd3-ce68b502822e
OTHER=11111111-2222-3333-4444-555555555555
CONFIG="$TMP_DIR/profile_override.toml"
OUTPUT="$TMP_DIR/output.toml"
cat >"$CONFIG" <<EOF
[profile.nvidia-257]
framebuffer = 0x80000000

[mdev."$OTHER"]
card_name = "Other VM"
adapter_name = "Other VM"
EOF

PYTHONPYCACHEPREFIX="$TMP_DIR/pycache" python3 -m py_compile "$HELPER"
python3 "$HELPER" --config "$CONFIG" --output "$OUTPUT" --uuid "$UUID" \
    --name 'NVIDIA GeForce GTX 750 Ti'
mv "$OUTPUT" "$CONFIG"
grep -Fxq "[mdev.\"$UUID\"]" "$CONFIG"
grep -Fxq 'card_name = "NVIDIA GeForce GTX 750 Ti"' "$CONFIG"
grep -Fxq 'adapter_name = "NVIDIA GeForce GTX 750 Ti"' "$CONFIG"
grep -Fxq 'num_displays = 1' "$CONFIG"
grep -Fxq 'display_width = 1920' "$CONFIG"
grep -Fxq 'display_height = 1080' "$CONFIG"
grep -Fxq 'max_pixels = 2073600' "$CONFIG"
grep -Fxq "[mdev.\"$OTHER\"]" "$CONFIG"
if grep -Eq '^(pci_id|pci_device_id|frl_enabled|rm_)[^=]*=' "$CONFIG"; then
    fail 'name-only update unexpectedly wrote an internal identity override'
fi

# Equivalent TOML quoting/whitespace must be replaced, not duplicated.
python3 "$HELPER" --config "$CONFIG" --output "$OUTPUT" --uuid "$UUID" --remove
mv "$OUTPUT" "$CONFIG"
cat >>"$CONFIG" <<EOF

# Per-VM marketing name; generated atomically by start-vm.sh.

# Per-VM GPU identity; generated atomically by start-vm.sh.

[ mdev . '$UUID' ]
card_name = "Legacy spelling"
adapter_name = "Legacy spelling"
EOF
python3 "$HELPER" --config "$CONFIG" --output "$OUTPUT" --uuid "$UUID" \
    --name 'NVIDIA GeForce GTX 1050' \
    --pci-id 0x1C8111C0 --pci-device-id 0x1C81 --frl-enabled 0 \
    --rm-fb-bus-width 128 --rm-fb-ram-type 8 --rm-fb-memory-vendor 1
mv "$OUTPUT" "$CONFIG"
[[ $(grep -Fxc "[mdev.\"$UUID\"]" "$CONFIG") == 1 ]]
grep -Fxq 'pci_id = 0x1C8111C0' "$CONFIG"
grep -Fxq 'pci_device_id = 0x1C81' "$CONFIG"
grep -Fxq 'frl_enabled = 0' "$CONFIG"
grep -Fxq 'rm_fb_bus_width = 128' "$CONFIG"
grep -Fxq 'rm_fb_ram_type = 8' "$CONFIG"
grep -Fxq 'rm_fb_memory_vendor = 1' "$CONFIG"
python3 -c 'import pathlib,tomllib,sys; tomllib.loads(pathlib.Path(sys.argv[1]).read_text())' \
    "$CONFIG"

# A semantic UUID representation that the surgical text rewriter cannot
# locate must fail closed instead of appending a duplicate TOML table.
UNSUPPORTED="$TMP_DIR/unsupported.toml"
cat >"$UNSUPPORTED" <<EOF
[mdev."\\u006194177e0-3318-4e5c-abd3-ce68b502822e"]
card_name = "Escaped key"
EOF
if python3 "$HELPER" --config "$UNSUPPORTED" --output "$OUTPUT" \
        --uuid "$UUID" --name 'NVIDIA GeForce GTX 1050' \
        --pci-id 0x1C8111C0 --pci-device-id 0x1C81 >/dev/null 2>&1; then
    fail 'unsupported semantic UUID header was duplicated instead of rejected'
fi

# Updating is idempotent and does not duplicate the UUID section.
python3 "$HELPER" --config "$CONFIG" --output "$OUTPUT" --uuid "$UUID" \
    --name 'NVIDIA GeForce GTX 1050' \
    --pci-id 0x1C8111C0 --pci-device-id 0x1C81 --frl-enabled 0 \
    --rm-fb-bus-width 128 --rm-fb-ram-type 8 --rm-fb-memory-vendor 1
mv "$OUTPUT" "$CONFIG"
[[ $(grep -Fxc "[mdev.\"$UUID\"]" "$CONFIG") == 1 ]]
[[ $(grep -Fxc '# Per-VM GPU identity and FHD display contract; generated atomically by start-vm.sh.' \
    "$CONFIG") == 1 ]] || fail 'generated marker was not text-idempotent'
if grep -Fq '# Per-VM marketing name; generated atomically by start-vm.sh.' \
        "$CONFIG"; then
    fail 'legacy generated marker survived replacement'
fi
grep -Fxq 'card_name = "NVIDIA GeForce GTX 1050"' "$CONFIG"
grep -Fxq 'pci_id = 0x1C8111C0' "$CONFIG"
grep -Fxq 'frl_enabled = 0' "$CONFIG"
grep -Fxq 'rm_fb_bus_width = 128' "$CONFIG"
grep -Fxq 'rm_fb_ram_type = 8' "$CONFIG"
grep -Fxq 'rm_fb_memory_vendor = 1' "$CONFIG"
if grep -Fq 'GTX 750 Ti' "$CONFIG"; then
    fail 'old per-mdev name survived replacement'
fi

# A legacy name-only rewrite removes every stale optional field atomically.
python3 "$HELPER" --config "$CONFIG" --output "$OUTPUT" --uuid "$UUID" \
    --name 'NVIDIA GeForce GTX 1050'
mv "$OUTPUT" "$CONFIG"
grep -Fxq 'card_name = "NVIDIA GeForce GTX 1050"' "$CONFIG"
if grep -Eq '^(pci_id|pci_device_id|frl_enabled|rm_)[^=]*=' "$CONFIG"; then
    fail 'name-only mode retained stale internal identity fields'
fi

# Empty/off mode removes only this VM override.
python3 "$HELPER" --config "$CONFIG" --output "$OUTPUT" --uuid "$UUID" --remove
mv "$OUTPUT" "$CONFIG"
if grep -Fq "$UUID" "$CONFIG"; then
    fail 'per-mdev section survived removal'
fi
if grep -Fq '# Per-VM GPU identity and FHD display contract; generated atomically by start-vm.sh.' \
        "$CONFIG"; then
    fail 'generated marker survived per-mdev removal'
fi
grep -Fxq "[mdev.\"$OTHER\"]" "$CONFIG"

if python3 "$HELPER" --config "$CONFIG" --output "$OUTPUT" --uuid "$UUID" \
        --name 'XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX' >/dev/null 2>&1; then
    fail 'R535 32-byte card-name overflow was accepted'
fi

# vgpu_unlock stores these as u64, but its NVIDIA ABI requires an exact
# DEV_16:SUBDEV_16 / DEV_16 pair.  Fail closed on incomplete, mismatched,
# vendor/device-packed, oversized, negative, or >64-bit input.
if python3 "$HELPER" --config "$CONFIG" --output "$OUTPUT" --uuid "$UUID" \
        --name 'NVIDIA GeForce GTX 1050' --pci-id 0x1C8111C0 \
        >/dev/null 2>&1; then
    fail 'unpaired pci_id was accepted'
fi
if python3 "$HELPER" --config "$CONFIG" --output "$OUTPUT" --uuid "$UUID" \
        --name 'NVIDIA GeForce GTX 1050' \
        --pci-id 0x1C8111C0 --pci-device-id 0x1D01 >/dev/null 2>&1; then
    fail 'mismatched vdev_id/pdev_id packing was accepted'
fi
if python3 "$HELPER" --config "$CONFIG" --output "$OUTPUT" --uuid "$UUID" \
        --name 'NVIDIA GeForce GTX 1050' \
        --pci-id 0x10DE1C81 --pci-device-id 0x1C81 >/dev/null 2>&1; then
    fail 'vendor/device tuple was accepted as DEV_16:SUBDEV_16'
fi
if python3 "$HELPER" --config "$CONFIG" --output "$OUTPUT" --uuid "$UUID" \
        --name 'NVIDIA GeForce GTX 1050' \
        --pci-id 0x10000000000000000 --pci-device-id 0x1C81 >/dev/null 2>&1; then
    fail '>64-bit pci_id was accepted'
fi
if python3 "$HELPER" --config "$CONFIG" --output "$OUTPUT" --uuid "$UUID" \
        --name 'NVIDIA GeForce GTX 1050' \
        --pci-id=-1 --pci-device-id 0x1C81 >/dev/null 2>&1; then
    fail 'negative pci_id was accepted'
fi
if python3 "$HELPER" --config "$CONFIG" --output "$OUTPUT" --uuid "$UUID" \
        --name 'NVIDIA GeForce GTX 1050' --frl-enabled 2 >/dev/null 2>&1; then
    fail 'invalid frl_enabled was accepted'
fi
if python3 "$HELPER" --config "$CONFIG" --output "$OUTPUT" --uuid "$UUID" \
        --remove --frl-enabled 0 >/dev/null 2>&1; then
    fail 'frl_enabled was accepted while removing an identity'
fi

# RM FB fields form one complete tuple and use NVIDIA's bounded ABI enums.
if python3 "$HELPER" --config "$CONFIG" --output "$OUTPUT" --uuid "$UUID" \
        --name 'NVIDIA GeForce GTX 750 Ti' \
        --rm-fb-bus-width 128 --rm-fb-ram-type 8 >/dev/null 2>&1; then
    fail 'partial RM FB identity was accepted'
fi
for invalid_tuple in '127 8 1' '128 10 1' '128 8 10'; do
    read -r invalid_bus invalid_type invalid_vendor <<<"$invalid_tuple"
    if python3 "$HELPER" --config "$CONFIG" --output "$OUTPUT" --uuid "$UUID" \
            --name 'NVIDIA GeForce GTX 750 Ti' \
            --rm-fb-bus-width "$invalid_bus" \
            --rm-fb-ram-type "$invalid_type" \
            --rm-fb-memory-vendor "$invalid_vendor" >/dev/null 2>&1; then
        fail "invalid RM FB tuple was accepted: $invalid_tuple"
    fi
done
if python3 "$HELPER" --config "$CONFIG" --output "$OUTPUT" --uuid "$UUID" \
        --remove --rm-fb-bus-width 128 --rm-fb-ram-type 8 \
        --rm-fb-memory-vendor 1 >/dev/null 2>&1; then
    fail 'RM FB identity was accepted while removing an identity'
fi
# Exercise the locked library helper without sudo against a writable config.
VGPU_UNLOCK_PROFILE_OVERRIDE_CONFIG="$CONFIG"
VGPU_MDEV_IDENTITY_HELPER="$HELPER"
# shellcheck source=/dev/null
source "$MDEV_LIB"
_mdev_sync_identity_override_locked "$UUID" 'NVIDIA GeForce GTX 750 Ti' \
    >/dev/null 2>&1
grep -Fxq 'card_name = "NVIDIA GeForce GTX 750 Ti"' "$CONFIG"
_mdev_sync_identity_override_locked "$UUID" 'NVIDIA GeForce GTX 1050' \
    0x1C8111C0 0x1C81 0 128 8 1 >/dev/null 2>&1
grep -Fxq 'pci_id = 0x1C8111C0' "$CONFIG"
grep -Fxq 'pci_device_id = 0x1C81' "$CONFIG"
grep -Fxq 'frl_enabled = 0' "$CONFIG"
grep -Fxq 'rm_fb_bus_width = 128' "$CONFIG"
grep -Fxq 'rm_fb_ram_type = 8' "$CONFIG"
grep -Fxq 'rm_fb_memory_vendor = 1' "$CONFIG"
_mdev_sync_identity_override_locked "$UUID" 'NVIDIA GeForce GTX 750 Ti' \
    >/dev/null 2>&1
if grep -Eq '^(pci_id|pci_device_id|frl_enabled|rm_)[^=]*=' "$CONFIG"; then
    fail 'library name-only update retained stale identity fields'
fi
if _mdev_sync_identity_override_locked "$UUID" 'NVIDIA GeForce GTX 1050' \
        0x1C8111C0 >/dev/null 2>&1; then
    fail 'library accepted an unpaired internal PCI identity'
fi

# An atomic replacement failure must propagate and leave the old config live.
mv() { return 23; }
if _mdev_sync_identity_override_locked "$UUID" 'NVIDIA GeForce GTX 1050' \
        >/dev/null 2>&1; then
    fail 'failed atomic rename was reported as a successful identity update'
fi
unset -f mv
grep -Fxq 'card_name = "NVIDIA GeForce GTX 750 Ti"' "$CONFIG"

# Existing mdev ownership is detected before a caller can rewrite its identity.
MDEV_PROC_DIR="$TMP_DIR/proc"
mkdir -p "$MDEV_PROC_DIR/4242"
printf '%s\0' qemu-system-x86_64 -device \
    "sysfsdev=/sys/bus/mdev/devices/$UUID" >"$MDEV_PROC_DIR/4242/cmdline"
[[ "$(mdev_uuid_in_use "$UUID")" == 4242 ]] || \
    fail 'active mdev owner PID was not detected'

grep -Fq 'MDEV_UUID=$VM_UUID' "$START_VM" || \
    fail 'start-vm does not use its stable persisted VM UUID for mdev'
grep -Fq '"$VGPU_RESOURCE_FB_MB" "${mdev_identity_args[@]}"' "$START_VM" || \
    fail 'start-vm does not pass the per-VM name into mdev allocation'
grep -Fq 'VGPU_MDEV_INTERNAL_PCI_IDENTITY=0' "$START_VM" || \
    fail 'start-vm internal PCI identity is not default-off'
grep -Fq '"$VGPU_MDEV_INTERNAL_PCI_IDENTITY" == 1 && "$SPOOF_MODE" == A' \
    "$START_VM" || fail 'start-vm internal PCI identity is not gated by opt-in plus A mode'
grep -Fq '"$(( (internal_did_value << 16) | internal_subdid_value ))"' \
    "$START_VM" || fail 'start-vm does not pack vdev_id as DID<<16|SUB_DID'
grep -Fq 'mdev_identity_contract_args=(' "$START_VM" || \
    fail 'start-vm does not build one complete per-mdev identity contract'
grep -Fq '"$GPU_MEMORY_VENDOR_RM"' "$START_VM" || \
    fail 'start-vm does not pass the canonical RM memory-vendor enum'
grep -Fq 'VGPU_MDEV_FRL_ENABLED' "$START_VM" || \
    fail 'start-vm does not expose an explicit per-mdev FRL override'
grep -Fq 'VGPU_MDEV_IDENTITY_MODE=required' \
    "$REPO_ROOT/deploy/host/vgpu-host-v100.conf.example" || \
    fail 'vGPU 19.5 V100 path does not require the reviewed R580 identity Hook'
grep -Fq 'preserving existing profile_override.toml' "$UNLOCK_SETUP" || \
    fail 'vgpu_unlock maintenance would erase generated per-mdev identities'

# The global type must stay neutral; names belong only under generated mdev sections.
# The host type is shared by multiple VMs.  Names, PCI IDs and RM descriptor
# fields must stay under
# generated per-mdev sections, never in the global nvidia-257 profile.
if awk '
    /^\[profile\.nvidia-257\]$/ { in_profile=1; next }
    /^\[/ { in_profile=0 }
    in_profile && /^(card_name|adapter_name|pci_id|pci_device_id|frl_enabled|rm_)[^=]*=/ { found=1 }
    END { exit(found ? 0 : 1) }
' "$HOST_PROFILE"; then
    fail 'global nvidia-257 profile still hard-codes a per-VM identity'
fi

# The native nvidia-257 2Q split is 1856 MiB usable + 192 MiB reservation.
# Keeping the total at 2048 MiB prevents GPU-Z from reporting the old 2304 MB.
python3 - "$HOST_PROFILE" <<'PY' || fail 'nvidia-257 framebuffer split is not native 2 GiB'
import pathlib
import sys
import tomllib

profile = tomllib.loads(pathlib.Path(sys.argv[1]).read_text())["profile"]["nvidia-257"]
framebuffer = profile.get("framebuffer")
reservation = profile.get("framebuffer_reservation")
assert framebuffer == 0x74000000
assert reservation == 0x0C000000
assert framebuffer + reservation == 2048 * 1024 * 1024
assert profile["num_displays"] == 1
assert profile["display_width"] == 1920
assert profile["display_height"] == 1080
assert profile["max_pixels"] == 1920 * 1080
PY

echo 'PASS: per-mdev GPU identity/RM FB tuple is scoped, validated, removable and reboot-regenerable'
