#!/usr/bin/env bash
# P-11 AMD CPU/主板 profile 与 AMD GPU-P 官方驱动路径合同回归。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
HOUSEHOLD="$REPO_ROOT/deploy/hardware/household-compatibility.json"
DISCOVERY="$REPO_ROOT/deploy/windows/gpup/VMate.GpuP.DriverDiscovery.ps1"
GUEST="$REPO_ROOT/deploy/windows/gpup/VMate.GpuP.GuestValidation.ps1"
NEW_VM="$REPO_ROOT/deploy/windows/gpup/New-VMateGpuPVM.ps1"

fail() { echo "FAIL: $*" >&2; exit 1; }
require_text() { rg -F --quiet -- "$1" "$2" || fail "missing '$1' in $2"; }

python3 - "$HOUSEHOLD" <<'PY'
import json, pathlib, sys
data=json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
wanted={
    "compat-k10-athlon-ii-x2-250-m5a78l",
    "compat-k10-phenom-ii-x4-955-m5a78l",
    "compat-zen-athlon-200ge-b350",
    "compat-zen-ryzen3-1200-b350",
}
profiles={item["id"]:item for item in data["candidates"] if item.get("enabled")}
assert wanted <= profiles.keys()
for key in wanted:
    item=profiles[key]
    assert item["cpu"]["vendor_id"] == "AuthenticAMD"
    assert item["cpu"]["name"].startswith("AMD ")
    assert item["profile_id"].startswith("asus-")
assert {profiles[key]["cpu"]["socket"] for key in wanted} == {"AM3", "AM4"}
PY

require_text 'VEN_(10DE|1002)' "$DISCOVERY"
require_text "Vendor = 'AMD'; VendorId = '1002'" "$DISCOVERY"
require_text "'Advanced Micro Devices, Inc.'" "$DISCOVERY"
require_text "@('atidxx64.dll', 'amdxx64.dll', 'amdxc64.dll', 'amdocl64.dll')" "$GUEST"
require_text "@('amdkmdag', 'amdwddmg', 'amdkmdap')" "$GUEST"
require_text "[ValidateSet('Auto', 'NVIDIA', 'AMD')]" "$NEW_VM"
require_text "AMD GPU-P 验证不能要求 nvidia-smi" "$GUEST"

powershell_bin="$(command -v pwsh || command -v powershell || true)"
if [[ -n "$powershell_bin" ]]; then
    VMATE_DISCOVERY="$DISCOVERY" "$powershell_bin" -NoLogo -NoProfile \
        -NonInteractive -Command '
        $ErrorActionPreference = "Stop"
        . $env:VMATE_DISCOVERY
        $amd = Get-VMateGpuPVendor "PCI\VEN_1002&DEV_73BF\0"
        if ($amd.Vendor -cne "AMD" -or $amd.VendorId -cne "1002") {
            throw "AMD vendor resolution failed"
        }
        if (-not (Test-VMateGpuPProvider "Advanced Micro Devices, Inc." $amd)) {
            throw "AMD provider allowlist failed"
        }
    '
else
    echo 'SKIP: PowerShell not found; static AMD contract passed'
fi

echo 'PASS: Windows GPU-P AMD platform and driver contract'
