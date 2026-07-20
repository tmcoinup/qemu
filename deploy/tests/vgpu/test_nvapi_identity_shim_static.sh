#!/usr/bin/env bash
# Build both forwarding shims and enforce the per-VM product-name contract.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
SHIM_DIR="$REPO_ROOT/deploy/guest/nvapi-shim"
PATCH_SCRIPT="$REPO_ROOT/deploy/guest/patch-grid-strings.ps1"
APPLY_SCRIPT="$REPO_ROOT/deploy/guest/apply-vm-profile.ps1"
INSTALL_SCRIPT="$REPO_ROOT/deploy/guest/install-nvapi-shim.ps1"
START_SCRIPT="$REPO_ROOT/deploy/start-vm.sh"
SETUP_SCRIPT="$REPO_ROOT/deploy/setup-guest.sh"
SYNC_SCRIPT="$REPO_ROOT/deploy/sync-vgpu-profile.sh"
MDEV_LIB="$REPO_ROOT/deploy/lib/vgpu-mdev.sh"
MDEV_HELPER="$REPO_ROOT/deploy/host/update-vgpu-mdev-identity.py"
TMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TMP_DIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

require_text() {
    local needle=$1 file=$2
    grep -F -- "$needle" "$file" >/dev/null || \
        fail "missing '$needle' in ${file#$REPO_ROOT/}"
}

check_image() {
    local objdump=$1 image=$2 private_clocks=$3 dump strings_dump
    dump="$TMP_DIR/$(basename "$image").exports.$RANDOM"
    strings_dump="$dump.strings"
    "$objdump" -p "$image" >"$dump"
    strings -a "$image" >"$strings_dump"
    grep -F 'Ordinal Base' "$dump" | grep -Eq '[[:space:]]1$' || \
        fail "$(basename "$image") export ordinal base is not 1"
    grep -Eq '^\s*\[\s*0\] nvapi_Direct_GetMethod$' "$dump" || \
        fail "$(basename "$image") ordinal 1 is not nvapi_Direct_GetMethod"
    grep -Eq '^\s*\[\s*1\] nvapi_QueryInterface$' "$dump" || \
        fail "$(basename "$image") ordinal 2 is not nvapi_QueryInterface"
    grep -Fx 'IdentityGpuName' "$strings_dump" >/dev/null || \
        fail "$(basename "$image") lacks the per-VM name registry marker"
    grep -Fx 'NvAPI_GPU_GetFullName' "$strings_dump" >/dev/null || \
        fail "$(basename "$image") lacks the full-name hook marker"
    for marker in \
        IdentityContractVersion \
        IdentityProfileKey \
        IdentityVramMB \
        IdentityCoreClockKHz \
        IdentityBoostClockKHz \
        IdentityMemoryClockKHz \
        IdentityMemoryClockNVAPIKHz \
        IdentityMemoryBandwidthMBps \
        IdentityMemoryBusBits \
        IdentityPciVendorId \
        IdentityPciDeviceId \
        IdentityPciSubVendorId \
        IdentityPciSubDeviceId \
        IdentityPciRevisionId \
        IdentityMemoryType \
        IdentityCudaCores \
        IdentityShaderSubPipes \
        IdentityRopCount \
        IdentityTmuCount \
        IdentityArchitecture \
        IdentityPcieWidth \
        IdentityVbiosVersion \
        IdentityTraceQueryInterface \
        NvAPI_GPU_GetPstates20 \
        NvAPI_GPU_GetPCIIdentifiers \
        NvAPI_GPU_GetRamBusWidth \
        NvAPI_GPU_GetGpuCoreCount \
        NvAPI_GPU_GetROPCount \
        NvAPI_GPU_GetPartitionCount \
        NvAPI_GPU_GetArchInfo \
        NvAPI_GPU_GetBusType \
        NvAPI_GPU_GetCurrentPCIEDownstreamWidth \
        NvAPI_GPU_GetVbiosVersionString \
        NvAPI_GPU_GetGPUInfo; do
        grep -Fx "$marker" "$strings_dump" >/dev/null || \
            fail "$(basename "$image") lacks the $marker marker"
    done
    if [[ "$private_clocks" == yes ]]; then
        grep -Fx 'NvAPI_GPU_GetPerfClocks' "$strings_dump" >/dev/null || \
            fail "$(basename "$image") lacks the x86 GPU-Z private-clock marker"
    elif grep -Fx 'NvAPI_GPU_GetPerfClocks' "$strings_dump" >/dev/null; then
        fail "$(basename "$image") exposes the x86-only GPU-Z private-clock hook"
    fi
}

for tool in x86_64-w64-mingw32-gcc i686-w64-mingw32-gcc \
            x86_64-w64-mingw32-objdump i686-w64-mingw32-objdump \
            cc strings; do
    command -v "$tool" >/dev/null || fail "missing build tool: $tool"
done

cc -O2 -std=c99 -Wall -Wextra -Werror \
    "$SHIM_DIR/test_profile_math.c" -o "$TMP_DIR/test-profile-math"
"$TMP_DIR/test-profile-math"

for spec in \
    'x86_64-w64-mingw32:nvapi_profile_probe64.exe:0x140000000:pei-x86-64:nvapi64.dll' \
    'i686-w64-mingw32:nvapi_profile_probe32.exe:0x00400000:pei-i386:nvapi.dll'; do
    IFS=: read -r triplet name image_base image_format sibling <<<"$spec"
    "$triplet-gcc" \
        -O2 -std=c99 -Wall -Wextra -Werror \
        -o "$TMP_DIR/$name" \
        "$SHIM_DIR/nvapi_profile_probe.c" \
        -Wl,--no-insert-timestamp \
        -Wl,--image-base,"$image_base" \
        -static \
        -Wl,--subsystem,console
    cmp -s "$TMP_DIR/$name" "$SHIM_DIR/$name" || \
        fail "$name is stale; run deploy/guest/nvapi-shim/build.sh"
    "$triplet-objdump" -f "$SHIM_DIR/$name" |
        grep -F "file format $image_format" >/dev/null || \
        fail "$name has the wrong PE architecture"
    strings -a "$SHIM_DIR/$name" |
        grep -Fx 'Memory bandwidth' >/dev/null || \
        fail "$name lacks the bandwidth verification marker"
    for marker in 'GetPerfClocks' 'GetPstates20'; do
        strings -a "$SHIM_DIR/$name" |
            grep -Fx "$marker" >/dev/null || \
            fail "$name lacks the $marker compatibility-clock marker"
    done
    strings -a "$SHIM_DIR/$name" |
        grep -F "sibling $sibling path" >/dev/null || \
        fail "$name does not load its app-local $sibling"
done
require_text 'GetModuleFileNameW(NULL, dll_path, MAX_PATH)' \
    "$SHIM_DIR/nvapi_profile_probe.c"
require_text '"TMU count", 0x86F05D7A' "$SHIM_DIR/nvapi_profile_probe.c"
require_text 'qi(0x2DDFB66E)' "$SHIM_DIR/nvapi_profile_probe.c"
require_text '"PCI identifiers"' "$SHIM_DIR/nvapi_profile_probe.c"
require_text 'if (rc != 0 || gpu_count != 1u)' \
    "$SHIM_DIR/nvapi_profile_probe.c"
if grep -F 'GetSystemDirectoryW' "$SHIM_DIR/nvapi_profile_probe.c" \
        >/dev/null; then
    fail 'NVAPI profile probes must not bypass the app-local shim'
fi
for spec in \
    'x86_64-w64-mingw32:nvapi64.dll:0x180000000:no' \
    'i686-w64-mingw32:nvapi.dll:0x10000000:yes'; do
    IFS=: read -r triplet name image_base private_clocks <<<"$spec"
    "$triplet-gcc" -shared -O2 -std=c99 -Wall -Wextra -Werror \
        -o "$TMP_DIR/$name" "$SHIM_DIR/nvapi_shim.c" \
        "$SHIM_DIR/nvapi_shim.def" -static -lkernel32 \
        -Wl,--no-insert-timestamp \
        -Wl,--image-base,"$image_base" \
        -Wl,--subsystem,windows
    check_image "$triplet-objdump" "$TMP_DIR/$name" "$private_clocks"
    check_image "$triplet-objdump" "$SHIM_DIR/$name" "$private_clocks"
    cmp -s "$TMP_DIR/$name" "$SHIM_DIR/$name" || \
        fail "$name is stale; run deploy/guest/nvapi-shim/build.sh"
done

require_text '0xCEEE8E9F' "$SHIM_DIR/nvapi_shim.c"
require_text '0x2DDFB66E' "$SHIM_DIR/nvapi_shim.c"
require_text 'hook_GetPCIIdentifiers' "$SHIM_DIR/nvapi_shim.c"
require_text 'IdentityGpuName' "$SHIM_DIR/nvapi_shim.c"
require_text '0x1EA54A3B' "$SHIM_DIR/nvapi_shim.c"
require_text '0x6FF81213' "$SHIM_DIR/nvapi_shim.c"
require_text '0x7975C581' "$SHIM_DIR/nvapi_shim.c"
require_text '0xC7026A87' "$SHIM_DIR/nvapi_shim.c"
require_text '0x0BE17923' "$SHIM_DIR/nvapi_shim.c"
require_text '0xFDC129FA' "$SHIM_DIR/nvapi_shim.c"
require_text '0x86F05D7A' "$SHIM_DIR/nvapi_shim.c"
require_text 'hook_GetPartitionCount' "$SHIM_DIR/nvapi_shim.c"
require_text '0xD8265D24' "$SHIM_DIR/nvapi_shim.c"
require_text '0x1BB18724' "$SHIM_DIR/nvapi_shim.c"
require_text '0xD048C3B1' "$SHIM_DIR/nvapi_shim.c"
require_text '0xA561FD7D' "$SHIM_DIR/nvapi_shim.c"
require_text '0xAFD1B02C' "$SHIM_DIR/nvapi_shim.c"
require_text 'nvapi_memory_bandwidth_from_raw_clock_mbps' \
    "$SHIM_DIR/nvapi_shim.c"
require_text 'status_allows_profile_override' "$SHIM_DIR/nvapi_shim.c"
require_text 'g_identity_contract_valid' "$SHIM_DIR/nvapi_shim.c"
require_text 'return g_identity_contract_valid;' "$SHIM_DIR/nvapi_shim.c"
require_text 'profile_key_matches_pci_contract' "$SHIM_DIR/nvapi_shim.c"
for profile_key in gtx750ti_2gb gt1030_2gb gtx1050_2gb; do
    require_text "\"$profile_key\"" "$SHIM_DIR/nvapi_shim.c"
done
if grep -Eq 'FALLBACK_|nvapi_choose_memory_raw_clock_khz' \
        "$SHIM_DIR/nvapi_shim.c"; then
    fail 'shim retains a model fallback instead of forwarding invalid contracts'
fi
require_text 'NVAPI_PROFILE_PERF_CLOCKS_VER1' \
    "$SHIM_DIR/nvapi_profile_clocks.h"
require_text 'NVAPI_PROFILE_PSTATE20_INFO_VER1' \
    "$SHIM_DIR/nvapi_profile_clocks.h"
require_text 'process_uses_gpuz_clock_contract' "$SHIM_DIR/nvapi_shim.c"
require_text 'L"GPU-Z.exe"' "$SHIM_DIR/nvapi_shim.c"
require_text 'nvapi_Direct_GetMethod @1' "$SHIM_DIR/nvapi_shim.def"
require_text 'nvapi_QueryInterface @2' "$SHIM_DIR/nvapi_shim.def"
require_text '-PropertyType String' "$PATCH_SCRIPT"
require_text '1-31 printable ASCII characters' "$PATCH_SCRIPT"
require_text 'IdentityProfileKey' "$PATCH_SCRIPT"
require_text 'IdentityContractVersion' "$PATCH_SCRIPT"
require_text 'NVAPI identity registry contract committed' "$PATCH_SCRIPT"
require_text "ProfileKey = 'gtx750ti_2gb'" "$PATCH_SCRIPT"
require_text "ProfileKey = 'gt1030_2gb'" "$PATCH_SCRIPT"
require_text "ProfileKey = 'gtx1050_2gb'" "$PATCH_SCRIPT"
require_text 'IdentityGpuName' "$APPLY_SCRIPT"
require_text "'gpu.name' 31" "$APPLY_SCRIPT"
require_text 'IdentityTmuCount' "$PATCH_SCRIPT"
require_text 'IdentityTmuCount' "$APPLY_SCRIPT"
for registry_name in \
        IdentityPciVendorId IdentityPciDeviceId \
        IdentityPciSubVendorId IdentityPciSubDeviceId \
        IdentityPciRevisionId; do
    require_text "$registry_name" "$PATCH_SCRIPT"
    require_text "$registry_name" "$APPLY_SCRIPT"
done
require_text 'IdentityRayTracingCores = 0' "$PATCH_SCRIPT"
require_text 'IdentityTensorCores = 0' "$PATCH_SCRIPT"
require_text 'IdentityRayTracingCores = 0' "$APPLY_SCRIPT"
require_text 'IdentityTensorCores = 0' "$APPLY_SCRIPT"
require_text 'Assert-ShimImage' "$INSTALL_SCRIPT"
require_text 'Installed shim hash mismatch' "$INSTALL_SCRIPT"
require_text 'SKIP_NVAPI_SHIM=1' "$SETUP_SCRIPT"
require_text '--with-nvapi-shim) SKIP_NVAPI_SHIM=0; SKIP_STEALTH=0' "$SETUP_SCRIPT"
require_text 'SKIP_STEALTH=1' "$SETUP_SCRIPT"
require_text '--with-guest-identity) SKIP_STEALTH=0' "$SETUP_SCRIPT"
require_text '--with-guest-identity' "$SYNC_SCRIPT"
require_text 'compatibility fallback' "$SYNC_SCRIPT"
require_text 'MDEV_UUID=$VM_UUID' "$START_SCRIPT"
require_text 'mdev_identity_name=$GPU_NAME' "$START_SCRIPT"
require_text 'guest_gpu_name' "$MDEV_LIB"
require_text '1-31 printable ASCII bytes' "$MDEV_HELPER"

if grep -aF 'NVIDIA GeForce GTX 750 Ti' \
        "$SHIM_DIR/nvapi64.dll" "$SHIM_DIR/nvapi.dll" >/dev/null; then
    fail 'checked-in shim hard-codes VM2 instead of reading its registry identity'
fi

if grep -Eq '0x(7A5E9C9F|1DCECC0E)' "$SHIM_DIR/nvapi_shim.c"; then
    fail 'shim reintroduced an unverified historical RAM query ID'
fi

python3 - "$SHIM_DIR/nvapi_shim.c" "$PATCH_SCRIPT" <<'PY'
import pathlib
import re
import sys

shim = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
writer = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8-sig")

gate = re.search(
    r"static BOOL status_allows_profile_override\(.*?^\}",
    shim,
    flags=re.MULTILINE | re.DOTALL,
)
assert gate, "missing centralized override gate"
assert "load_identity_spec();" in gate.group(0)
assert "return g_identity_contract_valid;" in gate.group(0)

loader = re.search(
    r"static BOOL CALLBACK load_identity_once\(.*?^\}",
    shim,
    flags=re.MULTILINE | re.DOTALL,
)
assert loader, "missing identity loader"
loader_text = loader.group(0)
required_values = {
    "IdentityContractVersion",
    "IdentityProfileKey",
    "IdentityGpuName",
    "IdentityVbiosVersion",
    "IdentityVramMB",
    "IdentityPciVendorId",
    "IdentityPciDeviceId",
    "IdentityPciSubVendorId",
    "IdentityPciSubDeviceId",
    "IdentityPciRevisionId",
    "IdentityCoreClockKHz",
    "IdentityBoostClockKHz",
    "IdentityMemoryClockNVAPIKHz",
    "IdentityMemoryClockKHz",
    "IdentityMemoryBusBits",
    "IdentityMemoryBandwidthMBps",
    "IdentityMemoryType",
    "IdentityMemoryMaker",
    "IdentityCudaCores",
    "IdentityShaderSubPipes",
    "IdentityRopCount",
    "IdentityTmuCount",
    "IdentityArchitecture",
    "IdentityImplementation",
    "IdentityChipRevision",
    "IdentityPcieWidth",
    "IdentityRayTracingCores",
    "IdentityTensorCores",
}
assert all(value in loader_text for value in required_values)
assert loader_text.count('"IdentityContractVersion"') >= 2
assert loader_text.count('"IdentityProfileKey"') >= 2
assert loader_text.index("RegCloseKey(key);") < loader_text.index(
    "g_identity_contract_valid = TRUE;"
)

invalidate = writer.index(
    "Remove-ItemProperty -Path $specKey -Name IdentityContractVersion"
)
strings = writer.index("$expectedStrings = [ordered]@{", invalidate)
numbers = writer.index("$spec = @{", strings)
verified = writer.index("if ($registryProblems.Count -gt 0)", numbers)
commit = writer.index(
    "New-ItemProperty -Path $specKey -Name IdentityContractVersion -Value 1",
    verified,
)
readback = writer.index("$committedVersion =", commit)
rewrite = writer.index("function RewriteKey", readback)
assert invalidate < strings < numbers < verified < commit < readback < rewrite
assert writer.count(
    "New-ItemProperty -Path $specKey -Name IdentityContractVersion -Value 1"
) == 1
PY

echo 'PASS: per-VM NVAPI identity shim build/export/profile contract'
