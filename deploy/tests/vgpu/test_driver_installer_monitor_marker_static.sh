#!/usr/bin/env bash
# Static contract: R535 repair invalidates only the exact per-VM monitor marker
# after preflight and before its first guest write; R580 skips this R535 cache.
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
    branch_gate = text.index(
        'if [[ "$VGPU_SELECTED_DRIVER_NEEDS_R535_MONITOR" == 1 ]]', definition
    )
    call = text.index('\n    invalidate_monitor_sync_marker\n', branch_gate)
    topology = text.index('vgpu_require_safe_driver_install_topology "$VM_ID"')
    verify = text.index('vgpu_verify_driver_assets ', definition)
    ip_binding = text.index(
        'IP=$(vgpu_resolve_bound_guest_ip "$VM_ID" "$IP_OVERRIDE")', verify
    )
    asset_loop = text.index('for asset in ', verify)
    asset_done = text.index('\ndone', asset_loop)
    first_guest_write = text.index(
        'GUEST_PASS_VALUE=$GUEST_PASS "$WINRM_PYTHON" -', call
    )

    require(
        definition < topology < verify < ip_binding < asset_loop < asset_done < branch_gate < call < first_guest_write,
        f"{label} topology/VM/IP/marker gate is not before guest write",
    )
    require(
        text.count('\n    invalidate_monitor_sync_marker\n') == 1,
        f"{label} must invalidate the marker exactly once in the R535 gate",
    )
    require(
        'R580: skip R535 monitor/NV_Modes marker invalidation' in text,
        f"{label} does not explicitly skip the R535 cache on R580",
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
        "[ValidateSet('Required', 'Offline')]" \
        "\$ConsoleGuardPolicy -eq 'Required'" \
        'headless console is host-isolated' \
        '"-ConsoleGuardPolicy $ConsoleGuardPolicy"' \
        "\$scriptPath = 'C:\\nv\\install-driver-runonce.ps1'" \
        "\$launcherPath = 'C:\\nv\\install-driver-runonce.cmd'" \
        "\$cmd.Length -gt 260" \
        "stage=launcher-entered" \
        "stage=powershell-entered" \
        "runonce-console.log" \
        "'-s', '-n', 'Display.Driver'" \
        "'-log:C:\\nv\\installer-logs'" \
        '"source_package_sha256=$($ExpectedSourcePackageSha256.ToUpperInvariant())"' \
        '"installer_sha256=$packageSha256"' \
        '"payload_sha256=$payloadSha256"' \
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
        "[[ \"\$RECEIPT\" == *'package_signature='* && \"\$RECEIPT\" == *'console_safe='* ]]" \
        '"$DISPLAY_MODE" == 1920x1080' \
        '"$CONSOLE_BYTES" == 8294400' \
        '"$CONSOLE_SAFE" == 1' \
        '"$VGPU_DRIVER_INSTALL_BACKEND" == headless' \
        '"$DISPLAY_MODE" == 0x0' \
        'headless console isolated; offline page-safe sync required' \
        'R535/GRID 538.33 signed / Code 0 / page-safe 1920x1080' \
        'R580/${DRIVER_LABEL} signed / Code 0 / runtime code integrity enforced' \
        'Win32_PnPSignedDriver' \
        'Win32_SystemDriver' \
        "\$kernelDriverPath -replace '^\\\\SystemRoot', \$env:SystemRoot" \
        'Microsoft Windows Hardware Compatibility Publisher' \
        'development_signatures' \
        "environment={'G11_ARM_ADMIN_PASS': pw}" \
        'except Exception as exc:' \
        'operation_timeout=30, read_timeout=45'; do
    grep -Fq -- "$required" "$repo_root/deploy/install-vgpu-driver-gui.sh" ||
        fail "GUI installer receipt gate omits: $required"
done

for required in \
        "Set-ItemProperty -Path \$wl -Name 'DefaultDomainName' -Value \$env:COMPUTERNAME" \
        "Set-ItemProperty -Path \$wl -Name 'AutoLogonCount'  -Value 2"; do
    grep -Fq -- "$required" "$runonce" ||
        fail "RunOnce AutoLogon hardening omits: $required"
done
for required in \
        "Remove-G11RegistryValueIfPresent \$wl 'DefaultUserName'" \
        "Remove-G11RegistryValueIfPresent \$wl 'DefaultDomainName'"; do
    grep -Fq -- "$required" "$repo_root/deploy/install-vgpu-driver-gui.sh" ||
        fail "GUI installer AutoLogon cleanup omits: $required"
done

if grep -Fq 'def ps_literal' "$repo_root/deploy/install-vgpu-driver-gui.sh"; then
    fail "GUI installer must not interpolate the guest password into PowerShell text"
fi

if command -v rg >/dev/null 2>&1; then
    forbidden_match=$(rg -n -i \
        'testsigning|nointegritychecks|bcdedit|self[- ]signed|自签' \
        "$runonce" "$repo_root/deploy/install-vgpu-driver.sh" \
        "$repo_root/deploy/install-vgpu-driver-gui.sh" || true)
else
    forbidden_match=$(grep -Eni \
        'testsigning|nointegritychecks|bcdedit|self[- ]signed|自签' \
        "$runonce" "$repo_root/deploy/install-vgpu-driver.sh" \
        "$repo_root/deploy/install-vgpu-driver-gui.sh" || true)
fi
if [[ -n "$forbidden_match" ]]; then
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
