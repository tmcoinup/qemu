#!/usr/bin/env bash
# Static contract: supported driver repair wrappers invalidate only the exact
# per-VM monitor marker after preflight and before their first guest write.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
installers=(
    "$repo_root/deploy/install-vgpu-driver-gui.sh"
)
compat_installer="$repo_root/deploy/install-vgpu-driver.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

for installer in "$compat_installer" "${installers[@]}"; do
    bash -n "$installer" || fail "invalid Bash syntax: $installer"
done

grep -Fq '"$here/install-vgpu-driver-gui.sh" "${args[@]}"' \
    "$compat_installer" ||
    fail "compat installer does not delegate to the guarded active-desktop path"
grep -Fq 'args=( "$VM_ID" --clean-existing )' "$compat_installer" ||
    fail "compat installer lost its clean-reinstall behavior"
grep -Fq -- '--no-reboot 已停用' "$compat_installer" ||
    fail "compat installer still allows the unsafe session-0 no-reboot path"
for required in \
        'stop-vm.sh" "$VM_ID" --graceful-only' \
        'flock -w 60 "$START_LOCK_FD"' \
        'sync-monitor-profile.sh" "$VM_ID" --force' \
        'VM_START_LOCK_HELD=1' \
        '完整关机、离线 EDID/NV_Modes 收敛'; do
    grep -Fq -- "$required" "$compat_installer" ||
        fail "compat installer omits post-install convergence: $required"
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
    topology = text.index('vgpu_require_safe_driver_install_topology "$VM_ID"')
    verify = text.index('vgpu_verify_driver_assets ', definition)
    ip_binding = text.index(
        'IP=$(vgpu_resolve_bound_guest_ip "$VM_ID" "$IP_OVERRIDE")', verify
    )
    asset_loop = text.index('for asset in ', verify)
    asset_done = text.index('\ndone', asset_loop)
    first_guest_write = text.index('\npython3 - ', call)

    require(
        definition < topology < verify < ip_binding < asset_loop < asset_done < call < first_guest_write,
        f"{label} topology/VM/IP/marker gate is not before guest write",
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

runonce="$repo_root/deploy/guest/install-driver-runonce.ps1"
for required in \
        '[switch]$RunInstaller' \
        'ChangeDisplaySettingsEx' \
        'Get-R535ConsoleFrameBytes' \
        '[Math]::Ceiling($rowBytes / 128.0) * 128' \
        '$frameBytes % 4096' \
        '$mode.dmPelsWidth = 1920' \
        '$mode.dmPelsHeight = 1080' \
        '$process.WaitForExit(1000)' \
        'Wait-SafeFhdDisplayMode -TimeoutSeconds 60' \
        '"installer=$installerExit"' \
        '"console_safe={0}"' \
        'Move-Item -LiteralPath $receiptTemp -Destination $FlagPath -Force'; do
    grep -Fq -- "$required" "$runonce" ||
        fail "RunOnce R535 display guard omits: $required"
done

for required in \
        '--clean-existing' \
        'G11_NVIDIA_PRE_CLEAN_DONE' \
        'pnputil /delete-driver $inf /uninstall /force' \
        "[[ \"\$RECEIPT\" == *'console_safe='* ]]" \
        '"$DISPLAY_MODE" != 1920x1080' \
        '"$CONSOLE_BYTES" != 8294400' \
        '"$CONSOLE_SAFE" != 1' \
        'GRID installer=0 / display=1920x1080'; do
    grep -Fq -- "$required" "$repo_root/deploy/install-vgpu-driver-gui.sh" ||
        fail "GUI installer receipt gate omits: $required"
done

if rg -n -i 'testsigning|nointegritychecks|bcdedit|self[- ]signed|自签' \
        "$runonce" "$repo_root/deploy/install-vgpu-driver.sh" \
        "$repo_root/deploy/install-vgpu-driver-gui.sh" >/dev/null; then
    fail "supported driver installer path mentions a forbidden BCD/signing bypass"
fi

if command -v pwsh >/dev/null 2>&1; then
    RUNONCE_PATH="$runonce" pwsh -NoProfile -Command '
        $errors=$null
        [System.Management.Automation.Language.Parser]::ParseFile(
            $env:RUNONCE_PATH, [ref]$null, [ref]$errors) > $null
        if ($errors.Count) { $errors | Out-String | Write-Error; exit 1 }
    ' || fail "RunOnce PowerShell syntax is invalid"
fi

echo 'PASS: driver RunOnce protects and receipts the R535 page-safe console mode'
