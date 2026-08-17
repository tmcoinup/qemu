#!/usr/bin/env bash
# Static contract: supported driver repair wrappers invalidate only the exact
# per-VM monitor marker after preflight and before their first guest write.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
installers=(
    "$repo_root/deploy/install-vgpu-driver.sh"
    "$repo_root/deploy/install-vgpu-driver-gui.sh"
)

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

for installer in "${installers[@]}"; do
    bash -n "$installer" || fail "invalid Bash syntax: $installer"
done

python3 - "${installers[@]}" <<'PY'
import sys
from pathlib import Path


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"FAIL: {message}")


for raw_path in sys.argv[1:]:
    path = Path(raw_path)
    text = path.read_text(encoding="utf-8")
    label = path.name

    for required in (
        'invalidate_monitor_sync_marker() {',
        'instance_dir=$(vm_storage_instance_dir "$VM_ID")',
        'vm_storage_validate_root_path "$instance_dir"',
        'vm_storage_validate_instance_tree "$VM_ID"',
        'monitor_marker=$(vm_storage_run_preferred_path "$VM_ID" monitor-edid)',
        '[[ "$monitor_marker" == "$instance_dir/run/monitor-edid.sha256" ]]',
        '[[ -L "$monitor_marker" ||',
        '( -e "$monitor_marker" && ! -f "$monitor_marker" )',
        'rm -f -- "$monitor_marker"',
        '[[ ! -e "$monitor_marker" && ! -L "$monitor_marker" ]]',
    ):
        require(required in text, f"{label} omits safety gate {required!r}")

    definition = text.index('invalidate_monitor_sync_marker() {')
    call = text.index('\ninvalidate_monitor_sync_marker\n', definition)
    verify = text.index('vgpu_verify_driver_assets ', definition)
    ip_binding = text.index(
        'IP=$(vgpu_resolve_bound_guest_ip "$VM_ID" "$IP_OVERRIDE")', verify
    )
    asset_loop = text.index('for asset in ', verify)
    asset_done = text.index('\ndone', asset_loop)
    if label == 'install-vgpu-driver.sh':
        first_guest_write = text.index('\nexec python3 - ', call)
    else:
        first_guest_write = text.index('\npython3 - ', call)

    require(
        definition < verify < ip_binding < asset_loop < asset_done < call < first_guest_write,
        f"{label} VM/IP binding or marker invalidation is not before guest write",
    )
    require(
        text.count('\ninvalidate_monitor_sync_marker\n') == 1,
        f"{label} must invalidate the marker exactly once and unconditionally",
    )
    require(
        'vm_storage_run_legacy_path "$VM_ID" monitor-edid' not in text,
        f"{label} may not delete a legacy/unresolved marker path",
    )
    require(
        'IP="$IP_OVERRIDE"' not in text,
        f"{label} trusts an IP override without binding it to VM_ID",
    )

print('PASS: driver installers safely invalidate the per-VM monitor marker before guest writes')
PY
