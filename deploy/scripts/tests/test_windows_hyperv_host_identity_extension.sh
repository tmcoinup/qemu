#!/usr/bin/env bash
# P-11 CPUID 编码、宿主扩展期望清单与完整身份证明门禁。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
GPUP="$REPO_ROOT/deploy/windows/gpup"
CPUID="$GPUP/VMate.GpuP.CpuidProfile.ps1"
PROFILE="$GPUP/VMate.GpuP.HardwareProfile.ps1"
HOST_EXTENSION="$GPUP/VMate.HyperV.HostIdentityExtension.ps1"
CATALOG="$REPO_ROOT/deploy/hardware/p11-platforms.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
require_text() {
    rg -F --quiet -- "$1" "$2" || fail "missing '$1' in $2"
}

for file in "$CPUID" "$HOST_EXTENSION"; do
    [[ -f "$file" ]] || fail "missing host identity contract: $file"
    [[ "$(od -An -tx1 -N3 "$file" | tr -d ' \n')" == efbbbf ]] ||
        fail "PowerShell 5.1 UTF-8 BOM missing: $file"
    (( $(wc -l < "$file") <= 500 )) || fail "module exceeds 500 lines: $file"
done

for name in ConvertTo-VMateGpuPCpuidLeaf1Eax \
    ConvertTo-VMateGpuPCpuidBrandLeaves New-VMateGpuPCpuidIdentity; do
    require_text "function $name" "$CPUID"
done
for name in New-VMateHyperVHostIdentityDesiredManifest \
    Publish-VMateHyperVHostIdentityDesiredManifest \
    Test-VMateHyperVHostIdentityAttestation \
    Test-VMateHyperVHostIdentityGuestReadback \
    Get-VMateHyperVHostIdentityExtensionStatus; do
    require_text "function $name" "$HOST_EXTENSION"
done
require_text 'vm-off-publish-next-cold-boot-only' "$HOST_EXTENSION"
require_text 'RuntimeModelSwitch = '\''forbidden'\''' "$HOST_EXTENSION"
require_text 'fail-closed-never-claim-full' "$HOST_EXTENSION"
require_text 'Get-AuthenticodeSignature' "$HOST_EXTENSION"
require_text 'HypervisorSha256' "$HOST_EXTENSION"
require_text 'in-guest-direct-cpuid-and-cim' "$HOST_EXTENSION"

python3 - "$CATALOG" <<'PY'
import json
import pathlib
import struct
import sys

catalog = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
profiles = {item["id"]: item for item in catalog["profiles"]}
expected = {
    "lab-intel-i5-13600kf-galax-b760-metaltop-d4":
        "13th Gen Intel(R) Core(TM) i5-13600KF",
    "lab-intel-i7-13700f-msi-b760m-bomber-wifi":
        "13th Gen Intel(R) Core(TM) i7-13700F",
}
for profile_id, brand in expected.items():
    cpu = profiles[profile_id]["processor"]
    assert cpu["cpuid_leaf1_eax"] == 0x000B0671
    assert cpu["family"] == 6 and cpu["model"] == 183
    assert cpu["stepping"] == 1
    assert cpu["cpuid_evidence_source"].startswith(
        "authorized-lab-direct-cpuid-")
    encoded = brand.encode("ascii").ljust(48, b" ")
    leaves = [
        struct.unpack("<IIII", encoded[offset:offset + 16])
        for offset in (0, 16, 32)
    ]
    decoded = b"".join(struct.pack("<IIII", *leaf) for leaf in leaves)
    assert decoded.rstrip(b" ").decode("ascii") == brand
assert expected[
    "lab-intel-i7-13700f-msi-b760m-bomber-wifi"].encode("ascii")[:4] == \
    struct.pack("<I", 0x68743331)
PY

powershell_bin="$(command -v pwsh || command -v powershell || true)"
if [[ -z "$powershell_bin" ]]; then
    echo 'SKIP: PowerShell not found; host identity static contract passed'
    exit 0
fi

VMATE_CPUID="$CPUID" VMATE_PROFILE="$PROFILE" VMATE_HOST_EXT="$HOST_EXTENSION" \
VMATE_CATALOG="$CATALOG" \
"$powershell_bin" -NoLogo -NoProfile -NonInteractive -Command '
$ErrorActionPreference = "Stop"
. $env:VMATE_CPUID
$leaf = ConvertTo-VMateGpuPCpuidLeaf1Eax 6 183 1
if ($leaf -ne [uint32]0x000B0671) { throw "Leaf 1 EAX encoding failed" }
$brand = ConvertTo-VMateGpuPCpuidBrandLeaves `
    "13th Gen Intel(R) Core(TM) i7-13700F"
if ($brand."0x80000002"[0] -cne "0x68743331") {
    throw "brand leaf byte order failed"
}
. $env:VMATE_PROFILE
$profile = Resolve-VMateGpuPHardwareProfile `
    -ProfileId lab-intel-i7-13700f-msi-b760m-bomber-wifi `
    -CatalogPath $env:VMATE_CATALOG
if ($profile.Processor.Cpuid.BrandString -cne `
        "13th Gen Intel(R) Core(TM) i7-13700F" -or
    $profile.Processor.Cpuid.Leaf1EaxHex -cne "0x000B0671") {
    throw "normalized CPUID facts failed"
}
. $env:VMATE_HOST_EXT
$vm = [pscustomobject]@{
    Id=[Guid]"384f91db-197c-4c64-a9f1-4655037fb955"
    Name="mock"; State="Running"
}
$hardware = [pscustomobject]@{
    Firmware=[pscustomobject]@{ BIOSGUID=[Guid]::NewGuid().ToString() }
}
$rejected = $false
try {
    New-VMateHyperVHostIdentityDesiredManifest $vm $profile $hardware
    throw "running VM accepted"
} catch {
    if ($_.Exception.Message -eq "running VM accepted") { throw }
    $rejected = $true
}
if (-not $rejected) { throw "running VM rejection was not observed" }
Write-Output "running-state-rejected"
'

echo 'PASS: Hyper-V host identity extension fail-closed contract'
