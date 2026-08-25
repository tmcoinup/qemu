#!/usr/bin/env bash
# P-11 成组硬件池、保真边界和一次绑定策略回归。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CATALOG="$REPO_ROOT/deploy/hardware/p11-platforms.json"
SHARED="$REPO_ROOT/deploy/hardware/platforms.json"
HOUSEHOLD="$REPO_ROOT/deploy/hardware/household-compatibility.json"
MODULE="$REPO_ROOT/deploy/windows/gpup/VMate.GpuP.HardwareProfile.ps1"
CATALOG_MODULE="$REPO_ROOT/deploy/windows/gpup/VMate.GpuP.HardwareCatalog.ps1"

fail() { echo "FAIL: $*" >&2; exit 1; }
require_text() {
    rg -F --quiet -- "$1" "$2" || fail "missing '$1' in $2"
}

[[ -f "$CATALOG" && -f "$SHARED" && -f "$HOUSEHOLD" && \
   -f "$MODULE" && -f "$CATALOG_MODULE" ]] || \
    fail 'hardware profile assets are incomplete'
[[ "$(od -An -tx1 -N3 "$MODULE" | tr -d ' \n')" == efbbbf ]] || \
    fail 'hardware profile module lacks UTF-8 BOM'
[[ "$(od -An -tx1 -N3 "$CATALOG_MODULE" | tr -d ' \n')" == efbbbf ]] || \
    fail 'hardware catalog module lacks UTF-8 BOM'
(( $(wc -l < "$MODULE") <= 500 )) || fail 'hardware profile module exceeds 500 lines'
(( $(wc -l < "$CATALOG_MODULE") <= 220 )) || \
    fail 'hardware catalog module exceeds 220 lines'

python3 - "$CATALOG" "$SHARED" "$HOUSEHOLD" <<'PY'
import json
import pathlib
import sys

p11 = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
shared = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
household = json.loads(pathlib.Path(sys.argv[3]).read_text(encoding="utf-8"))
assert p11["schema_version"] == 1
assert p11["selection_policy"] == "atomic-platform-bundle-only"
assert p11["shared_platform_catalog"] == "platforms.json"
assert p11["shared_compatibility_catalog"] == "household-compatibility.json"
assert p11["shared_compatibility_policy"] == \
    "deduplicate-equivalent-identity-bundles"
profiles = {item["id"]: item for item in p11["profiles"] if item["enabled"]}
assert len(profiles) == 3 and "host-native" in profiles
shared_enabled = [item for item in shared["platforms"] if item["enabled"]]
assert len(shared_enabled) == 6
platforms = {item["id"]: item for item in household["platform_profiles"]}
bundle_keys = set()
household_enabled = []
for candidate in household["candidates"]:
    assert candidate["status"] in ("supported", "compatibility")
    platform = platforms[candidate["profile_id"]]
    key = (
        candidate["cpu"]["name"].strip().lower(),
        platform["board"]["manufacturer"].strip().lower(),
        platform["board"]["product"].strip().lower(),
        platform["memory"]["type"].strip().lower(),
        str(platform["memory"]["max_mts"]),
    )
    if key in bundle_keys:
        continue
    bundle_keys.add(key)
    if candidate["enabled"]:
        household_enabled.append(candidate)
assert len(household_enabled) == 13
assert len(profiles) + len(shared_enabled) + len(household_enabled) == 22
amd_ids = {
    "compat-k10-athlon-ii-x2-250-m5a78l",
    "compat-k10-phenom-ii-x4-955-m5a78l",
    "compat-zen-athlon-200ge-b350",
    "compat-zen-ryzen3-1200-b350",
}
amd = {item["id"]: item for item in household_enabled if item["id"] in amd_ids}
assert set(amd) == amd_ids
assert all(item["cpu"]["vendor_id"] == "AuthenticAMD" for item in amd.values())
assert {item["cpu"]["socket"] for item in amd.values()} == {"AM3", "AM4"}

pc01 = profiles["lab-intel-i5-13600kf-galax-b760-metaltop-d4"]
pc02 = profiles["lab-intel-i7-13700f-msi-b760m-bomber-wifi"]
assert pc01["processor"]["name"].endswith("i5-13600KF")
assert pc01["platform"]["product"] == "GALAX B760 METALTOP D4"
assert pc02["processor"]["name"].endswith("i7-13700F")
assert pc02["platform"]["product"] == "B760M BOMBER WIFI (MS-7D90)"
for profile in (pc01, pc02):
    assert profile["identity_fidelity"] == "host-extension-required"
    assert profile["processor"]["count"] == 20
    assert profile["gpu"]["quota_profile"] == "win10-reference-100"
    assert profile["gpu"]["observed_reference_quota_profile"] == \
        "win10-reference-100"
    assert profile["gpu"]["low_mmio_bytes"] == 3 * 1024**3
    assert profile["gpu"]["high_mmio_bytes"] == 32 * 1024**3
    assert profile["gpu"]["console_resolution_type"] == "Maximum"
    assert profile["gpu"]["console_horizontal_resolution"] == 3840
    assert profile["gpu"]["console_vertical_resolution"] == 2400
    assert profile["gpu"]["vm_configuration_version"] == "9.2"
    assert profile["firmware"]["serial_policy"] == "vmate-unique-generated-once"
    assert "mac_address" not in profile["network"]

serialized = json.dumps(p11, ensure_ascii=False).lower()
for forbidden in ("independent-random", "copy-reference-serial", "copy-reference-mac"):
    assert forbidden not in serialized
PY

require_text 'function Get-VMateGpuPHardwareProfiles' "$MODULE"
require_text 'function Resolve-VMateGpuPHardwareProfile' "$MODULE"
require_text 'function Assert-VMateGpuPHardwareProfileOverrides' "$MODULE"
require_text 'function Set-VMateGpuPHardwareProfileBinding' "$MODULE"
require_text 'shared platform catalog 必须是同目录 platforms.json' "$MODULE"
require_text 'household compatibility catalog/policy 无效' "$MODULE"
require_text 'function ConvertTo-VMateGpuPHouseholdProfile' "$CATALOG_MODULE"
require_text 'function Get-VMateGpuPHouseholdBundleKey' "$CATALOG_MODULE"
require_text "PersistencePolicy = 'select-once-no-reroll'" "$MODULE"
require_text '普通启动禁止重新抽取' "$MODULE"
require_text '标准 Hyper-V 只会应用计算资源、固件序号、静态 MAC 和 GPU 配额' "$MODULE"

powershell_bin="$(command -v pwsh || command -v powershell || true)"
if [[ -n "$powershell_bin" ]]; then
    VMATE_PROFILE_MODULE="$MODULE" VMATE_PROFILE_CATALOG="$CATALOG" \
        "$powershell_bin" -NoLogo -NoProfile -NonInteractive -Command '
        $ErrorActionPreference = "Stop"
        . $env:VMATE_PROFILE_MODULE
        $profiles = @(Get-VMateGpuPHardwareProfiles `
            -CatalogPath $env:VMATE_PROFILE_CATALOG)
        if ($profiles.Count -ne 22) { throw "unexpected enabled profile count" }
        $sample = Resolve-VMateGpuPHardwareProfile `
            -ProfileId lab-intel-i5-13600kf-galax-b760-metaltop-d4 `
            -CatalogPath $env:VMATE_PROFILE_CATALOG
        if ($sample.FullIdentitySupported -or $sample.Processor.Count -ne 20) {
            throw "sample fidelity was overstated"
        }
        $household = Resolve-VMateGpuPHardwareProfile `
            -ProfileId "household:compat-sandy-g630-p8h61" `
            -CatalogPath $env:VMATE_PROFILE_CATALOG
        if ($household.FullIdentitySupported -or
            $household.Processor.Count -ne 2 -or
            $household.Platform.product -cne "P8H61-M LE/USB3" -or
            $household.Gpu.quota_profile -cne "win10-reference-100" -or
            [uint64]$household.Gpu.low_mmio_bytes -ne [uint64]3GB -or
            [string]$household.Gpu.vm_configuration_version -cne "9.2") {
            throw "household profile conversion is invalid"
        }
        try {
            Resolve-VMateGpuPHardwareProfile -ProfileId $sample.Id `
                -CatalogPath $env:VMATE_PROFILE_CATALOG -RequireFullIdentity
            throw "unsupported full identity was accepted"
        } catch {
            if ($_.Exception.Message -eq "unsupported full identity was accepted") { throw }
        }
        try {
            Assert-VMateGpuPHardwareProfileOverrides $sample @{
                ProcessorCount = 4
            }
            throw "split profile override was accepted"
        } catch {
            if ($_.Exception.Message -eq "split profile override was accepted") { throw }
        }
        # A caught terminating error leaves `$?` false in pwsh 7 and would make
        # the process exit with code 1 even though both negative tests passed.
        exit 0
    '
else
    echo 'SKIP: PowerShell not found; hardware pool static contract passed'
fi

echo 'PASS: Windows GPU-P atomic hardware profile pool contract'
