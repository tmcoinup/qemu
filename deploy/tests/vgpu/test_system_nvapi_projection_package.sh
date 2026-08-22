#!/usr/bin/env bash
# Validate the VM-bound, process-agnostic system NVAPI/monitor package.
set -euo pipefail

# A caller's storage selection must never escape this test's private roots.
unset IMAGE_ROOT ISO_DIR STAGE_DIR VM_ROOT VMS_DIR VM_INSTANCES_DIR
unset VM_INSTANCE_DIR VM_INSTANCE_ID VM_STORAGE_COMPAT_FALLBACK
unset VM_SHARED_DIR VM_CONFIG_DIR VM_DISK_DIR VM_BASE_DIR VM_NVRAM_DIR
unset VM_CONTROL_DIR VM_RUN_DIR VM_LOG_DIR VM_ASSET_DIR
unset VM_DISK_ARCHIVE_DIR VM_BASE_ARCHIVE_DIR VM_NVRAM_BACKUP_DIR

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
packager="$root/deploy/package-system-nvapi-projection.sh"
coordinator="$root/deploy/guest/install-system-nvapi-projection.ps1"
installer="$root/deploy/guest/install-nvapi-shim.ps1"
create_vm="$root/deploy/scripts/create-vm.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

require_text() {
    local needle=$1 file=$2
    grep -F -- "$needle" "$file" >/dev/null ||
        fail "missing '$needle' in ${file#$root/}"
}

sha256_upper() {
    sha256sum -- "$1" | awk '{print toupper($1)}'
}

for dependency in bash jq sha256sum xorriso python3 stat find rg touch; do
    command -v "$dependency" >/dev/null || fail "missing tool: $dependency"
done
bash -n "$packager"

# This package may replace only user-mode NVAPI images and exact monitor-cache
# values.  It must remain independent of any hardware-reporting process and
# must never weaken Windows code-integrity policy or install a kernel driver.
if rg -n -i \
        'bcdedit(?:\.exe)?[[:space:]]+/set|testsigning[[:space:]]+(on|yes)|nointegritychecks[[:space:]]+(on|yes)' \
        "$packager" "$coordinator" "$installer" >/dev/null; then
    fail 'system projection sources can weaken BCD code integrity'
fi
if rg -n -i \
        'pnputil(?:\.exe)?.*/add-driver|dism(?:\.exe)?.*/add-driver|Add-WindowsDriver|devcon(?:\.exe)?.*install|certutil(?:\.exe)?.*-addstore|Import-Certificate' \
        "$packager" "$coordinator" "$installer" >/dev/null; then
    fail 'system projection sources contain a driver/certificate installation path'
fi
if rg -n -i 'ludashi|\u9c81\u5927\u5e08|gpu-z|gpuz|vm9|AOC 2470W|AOC2470' \
        "$packager" "$coordinator" >/dev/null; then
    fail 'system coordinator/packager contains an application, VM or monitor special case'
fi
require_text '& $bcdedit /enum all' "$coordinator"
require_text "@('testsigning', 'nointegritychecks')" "$coordinator"
require_text "'*S-1-5-32-544:(F)'" "$installer"
require_text 'icacls failed for' "$installer"
if grep -Fq "'Administrators:(F)'" "$installer"; then
    fail 'system installer uses a localized Administrators group name'
fi
require_text "'RefreshMonitor'" "$coordinator"
require_text "'RefreshIdentity'" "$coordinator"
require_text 'function Test-MonitorBaseIdentity' "$coordinator"
require_text 'function Get-MonitorRegistryInstances' "$coordinator"
require_text '[switch]$IncludeNonMatching' "$coordinator"
require_text 'Get-MonitorRegistryInstances $Payload `' "$coordinator"
require_text '-IncludeNonMatching' "$coordinator"
require_text '\ADISPLAY\\NVD[0-9A-F]{4}\\' "$coordinator"
require_text '唯一的 native NVIDIA monitor 实例尚未稳定。' "$coordinator"
require_text 'function Set-MonitorEdidOverride' "$coordinator"
require_text 'function Register-MonitorIdentityTask' "$coordinator"
require_text 'function Wait-RegistryContract' "$coordinator"
require_text "\$trigger.Delay = 'PT45S'" "$coordinator"
require_text '-Action RefreshIdentity -PayloadDir' "$coordinator"
require_text 'Invoke-ProfileWriter $payload' "$coordinator"
require_text "Get-PnpDevice -Class Monitor -PresentOnly" "$coordinator"
require_text 'SetupDiSetDevicePropertyW' "$coordinator"
require_text 'DEVPKEY_Device_FriendlyName' "$coordinator"
require_text 'function Set-MonitorPnpFriendlyName' "$coordinator"
require_text 'Set-MonitorPnpFriendlyName $Instance.InstanceId' "$coordinator"
if rg -n 'Set-ProtectedMonitorValue[[:space:]]+\$Instance\.InstancePath[[:space:]]+.(DeviceDesc|Mfg|HardwareID).' \
        "$coordinator" >/dev/null; then
    fail 'system coordinator directly rewrites an OS/driver-owned monitor property'
fi
require_text 'function Initialize-StorageEjectApi' "$coordinator"
require_text 'IOCTL_STORAGE_EJECT_MEDIA = 0x002D4808' "$coordinator"
require_text 'GENERIC_READ = 0x80000000' "$coordinator"
require_text '@"\\.\" + normalized, GENERIC_READ' "$coordinator"
require_text 'Eject-MatchingPayloadMedia $payload.Contract' "$coordinator"
require_text 'function Get-V11ComputerName' "$coordinator"
require_text "return 'DESKTOP-' + \$compact.Substring(0, 7)" "$coordinator"
require_text 'Prepare-V11CloneComputerName $payload' "$coordinator"
require_text 'Assert-V11CloneComputerName $payload.Contract' "$coordinator"
require_text 'Rename-Computer -NewName $expected -Force' "$coordinator"
require_text "\$names.Count -ne 2 -or \$names[0] -cne '0' -or \$names[1] -cne '1'" \
    "$coordinator"
require_text 'Remove-StaleProjectionTasks $payload.Contract' "$coordinator"
require_text 'Unregister-MonitorIdentityTask $payload.Contract' "$coordinator"
require_text "[string]\$PayloadDir = ''" "$coordinator"
require_text '$PayloadDir = $PSScriptRoot' "$coordinator"
require_text '-Action Install -Reboot' "$packager"
if rg -n -- '-PayloadDir[[:space:]]+"%~d(p)?0"' "$packager" >/dev/null; then
    fail 'batch launcher still passes a drive-root/trailing-backslash PayloadDir'
fi
require_text 'Start-Process -FilePath $env:G11_SYSTEM_NVAPI_ENTRY -Verb RunAs' \
    "$packager"
require_text 'lowLevelInstallerSha256' "$packager"
require_text 'coordinatorSha256' "$packager"
require_text 'identityCatalogJsonSha256' "$packager"
require_text 'transport-device-profile-subsystem' "$packager"
require_text '[int]$contract.profile.memoryMaker -notin @(1, 3, 6, 10)' \
    "$coordinator"
require_text 'PciProjectionMode = [string]$contract.transport.pciProjectionMode' \
    "$coordinator"
require_text 'expectedSubsystem' "$coordinator"
require_text '([int]$profile.rayTracingCores)' "$coordinator"
require_text '([int]$profile.tensorCores)' "$coordinator"
require_text 'function Invoke-NativeD3D12Probes' "$coordinator"
require_text "'D3D12CapabilityProbe32.exe'" "$coordinator"
require_text "'D3D12CapabilityProbe64.exe'" "$coordinator"
require_text "Invoke-NativeD3D12Probes \$payload" "$coordinator"
require_text 'D3D12_NATIVE_VERIFY PASS' "$coordinator"
require_text '$output = (& $probe 2>&1 | Out-String)' "$coordinator"
require_text 'native_raytracing_nonzero=yes' "$coordinator"
require_text 'NVAPI capability: RT cores=${GPU_RAY_TRACING_CORES}' "$packager"
require_text './deploy/scripts/vmctl.sh cdrom' "$packager"
require_text 'D3D12 target:    raytracing tier=${GPU_D3D12_RAYTRACING_TIER}' \
    "$packager"
require_text '不安装应用专用 DLL' "$packager"
require_text '0xAFD1B02Cu' \
    "$root/deploy/guest/nvapi-shim/system_nvapi_probe.c"
require_text 'gpu_info.ray_tracing_cores != expected_rt_cores' \
    "$root/deploy/guest/nvapi-shim/system_nvapi_probe.c"
require_text 'function Get-TrustedPriorShimHashes' "$coordinator"
require_text "'^[0-9A-F]{64}-validated\.json\$'" "$coordinator"
require_text 'Test-PnpPrefix ([string]$receipt.displayInstanceId)' "$coordinator"
require_text 'prior payload digest mismatch' "$coordinator"
require_text 'TrustedPriorX64Sha256 = @($trustedPrior.X64)' "$coordinator"
require_text 'TrustedPriorX86Sha256 = @($trustedPrior.X86)' "$coordinator"
require_text '[string[]]$TrustedPriorX64Sha256 = @()' "$installer"
require_text '[string[]]$TrustedPriorX86Sha256 = @()' "$installer"
require_text "return 'trusted-prior'" "$installer"
require_text 'Assert-OriginalNvidiaImage $backup $Arch.machine' "$installer"
require_text 'Assert-OriginalNvidiaImage $target $Arch.machine' "$installer"
require_text 'original target and redundant backup differ' "$installer"
require_text 'removed byte-identical redundant backup' "$installer"

image_root="$tmp/images"
vm_root="$tmp/vms"
vm_root_1g="$tmp/vms-1g"
stage_dir="$tmp/staging"
host_config="$tmp/vgpu-host-2gb.conf"
host_config_1g="$tmp/vgpu-host-1gb.conf"
mkdir -p "$image_root" "$vm_root" "$vm_root_1g" "$stage_dir"
printf '%s\n' 'VGPU_HOST_FB_TIER_MB=2048' >"$host_config"
printf '%s\n' 'VGPU_HOST_FB_TIER_MB=1024' >"$host_config_1g"

create_fixture() {
    local vm_id=$1 gpu_profile=$2 monitor_profile=$3
    local fixture_root=${4:-$vm_root}
    local fixture_host_config=${5:-$host_config}
    IMAGE_ROOT="$image_root" VM_ROOT="$fixture_root" STAGE_DIR="$stage_dir" \
        VGPU_HOST_CONFIG="$fixture_host_config" \
        bash "$create_vm" "$vm_id" --gpu-profile "$gpu_profile" \
            --monitor-profile "$monitor_profile" >/dev/null
    touch "$fixture_root/$vm_id/disk.qcow2"
}

package_fixture() {
    local vm_id=$1 output=$2
    local fixture_root=${3:-$vm_root}
    IMAGE_ROOT="$image_root" VM_ROOT="$fixture_root" STAGE_DIR="$stage_dir" \
        bash "$packager" "$vm_id" --output-root "$output" >/dev/null
}

assert_edid() {
    local path=$1 vendor=$2 product=$3 name=$4
    python3 - "$path" "$vendor" "$product" "$name" <<'PY'
import pathlib
import sys

path, expected_vendor, expected_product, expected_name = sys.argv[1:]
data = pathlib.Path(path).read_bytes()
assert len(data) == 256
assert data[:8] == bytes((0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00))
assert data[126] == 1
assert sum(data[:128]) % 256 == 0
assert sum(data[128:]) % 256 == 0
word = int.from_bytes(data[8:10], "big")
vendor = "".join(chr(64 + ((word >> shift) & 0x1F)) for shift in (10, 5, 0))
product = int.from_bytes(data[10:12], "little")
assert vendor == expected_vendor
assert product == int(expected_product, 0)
names = []
for offset in (54, 72, 90, 108):
    descriptor = data[offset:offset + 18]
    if descriptor[:5] == b"\x00\x00\x00\xfc\x00":
        names.append(descriptor[5:18].split(b"\n", 1)[0].rstrip(b" \x00").decode("ascii"))
assert names == [expected_name]
PY
}

assert_bundle() {
    local output=$1 vm_id=$2 profile=$3 board=$4 monitor_key=$5
    local monitor_name=$6 monitor_vendor=$7 monitor_product=$8 monitor_pnp=$9
    local monitor_edid_name=${10}
    local monitor_manufacturer=${11}
    local memory_maker_name=${12}
    local memory_maker_id=${13}
    local memory_maker_nvapi_name=${14}
    local fixture_root=${15:-$vm_root}
    local monitor_product_dec=$((monitor_product))
    local -a dirs=() isos=()
    mapfile -t dirs < <(find "$output" -mindepth 1 -maxdepth 1 -type d \
        -name "vm${vm_id}-*" -print)
    mapfile -t isos < <(find "$output" -mindepth 1 -maxdepth 1 -type f \
        -name "vm${vm_id}-*.iso" -print)
    [[ ${#dirs[@]} -eq 1 && ${#isos[@]} -eq 1 ]] ||
        fail "vm$vm_id did not produce one directory and one ISO"
    if find "$output" -mindepth 1 -maxdepth 1 -type d \
            -name '.build-vm*' -print -quit | grep -q .; then
        fail "vm$vm_id left a temporary build directory"
    fi
    local bundle=${dirs[0]} iso=${isos[0]}
    [[ $(stat -c %a -- "$bundle") == 700 && $(stat -c %a -- "$iso") == 600 ]] ||
        fail "vm$vm_id output permissions are not private"
    if find "$bundle" -mindepth 1 -maxdepth 1 ! -type f -print -quit | grep -q .; then
        fail "vm$vm_id bundle contains a non-regular top-level entry"
    fi
    [[ $(find "$bundle" -mindepth 1 -maxdepth 1 -type f | wc -l) -eq 17 ]] ||
        fail "vm$vm_id bundle has an unexpected file count"
    while IFS= read -r file; do
        [[ $(stat -c %a -- "$file") == 600 ]] ||
            fail "vm$vm_id bundle file is not mode 0600: $file"
    done < <(find "$bundle" -mindepth 1 -maxdepth 1 -type f -print)

    python3 - "$bundle" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
for name in (
    "Run-As-Administrator.cmd",
    "Verify-As-Administrator.cmd",
    "Rollback-As-Administrator.cmd",
):
    data = (root / name).read_bytes()
    assert data.endswith(b"\r\n"), name
    assert b"\n" not in data.replace(b"\r\n", b""), name
PY

    local contract="$bundle/system-nvapi-contract.json"
    local manifest="$bundle/system-nvapi-manifest.json"
    jq -e \
        --argjson vmId "$vm_id" --arg profile "$profile" --arg board "$board" \
        --arg monitorKey "$monitor_key" --arg monitorName "$monitor_name" \
        --arg monitorVendor "$monitor_vendor" --arg monitorMfg "$monitor_manufacturer" \
        --arg monitorPnp "$monitor_pnp" \
        --arg memoryMaker "$memory_maker_name" \
        --arg memoryMakerNvapi "$memory_maker_nvapi_name" \
        --argjson memoryMakerId "$memory_maker_id" \
        --argjson monitorProduct "$monitor_product_dec" '
        (keys | sort) == [
          "contractId", "identityCatalogSha256", "monitor", "payload",
          "profile", "purpose", "schemaVersion", "sourceConfigSha256",
          "transport", "vmId", "vmUuid"
        ] and
        .schemaVersion == 4 and .purpose == "g11-system-nvapi-projection" and
        .vmId == $vmId and (.vmUuid | test("^[0-9a-f-]{36}$")) and
        (.sourceConfigSha256 | test("^[0-9A-F]{64}$")) and
        .transport.targetPnpId == "PCI\\VEN_10DE&DEV_1E30" and
        .transport.driverVersion == "31.0.15.3833" and
        .transport.pciVendorId == 4318 and
        .transport.pciDeviceId == 7728 and
        .transport.pciProjectionMode ==
          "transport-device-profile-subsystem" and
        .profile.key == $profile and .profile.boardBrand == $board and
        .profile.memoryTypeName == "GDDR5" and
        .profile.memoryMakerName == $memoryMaker and
        .profile.memoryMakerNvapiName == $memoryMakerNvapi and
        .profile.memoryMaker == $memoryMakerId and .profile.memoryType == 8 and
        .profile.d3d12RaytracingTier == 0 and
        .profile.rayTracingCores == 0 and .profile.tensorCores == 0 and
        .monitor.key == $monitorKey and .monitor.displayName == $monitorName and
        .monitor.manufacturer == $monitorMfg and
        .monitor.pnpVendor == $monitorVendor and
        .monitor.productId == $monitorProduct and .monitor.pnpId == $monitorPnp and
        (.monitor.edidSha256 | test("^[0-9A-F]{64}$")) and
        (.payload | keys | sort) == [
          "coordinatorSha256", "d3dProbeX64Sha256", "d3dProbeX86Sha256",
          "identityCatalogJsonSha256",
          "lowLevelInstallerSha256", "probeX64Sha256", "probeX86Sha256",
          "profileWriterSha256", "shimX64Sha256", "shimX86Sha256"
        ] and all(.payload[]; test("^[0-9A-F]{64}$"))
    ' "$contract" >/dev/null || fail "vm$vm_id contract is not exact"

    local expected_contract_id actual_contract_id
    expected_contract_id=$(jq -cS 'del(.contractId)' "$contract" | sha256sum |
        awk '{print toupper($1)}')
    actual_contract_id=$(jq -er '.contractId' "$contract")
    [[ $actual_contract_id == "$expected_contract_id" ]] ||
        fail "vm$vm_id contract ID is not content-addressed"
    [[ $(sha256_upper "$fixture_root/$vm_id/vm.conf") == \
        "$(jq -er '.sourceConfigSha256' "$contract")" ]] ||
        fail "vm$vm_id source config hash is not bound"

    jq -e --arg contractId "$actual_contract_id" '
        (keys | sort) == ["contractId", "files", "purpose", "schemaVersion"] and
        .schemaVersion == 1 and .purpose == "g11-system-nvapi-projection" and
        .contractId == $contractId and (.files | length) == 12 and
        ([.files[].path] | unique | length) == 12
    ' "$manifest" >/dev/null || fail "vm$vm_id manifest is malformed"
    local path bytes digest
    while IFS=$'\t' read -r path bytes digest; do
        [[ $path =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ &&
           $bytes =~ ^[1-9][0-9]*$ && $digest =~ ^[0-9A-F]{64}$ &&
           -f "$bundle/$path" && ! -L "$bundle/$path" ]] ||
            fail "vm$vm_id manifest entry is unsafe: $path"
        [[ $(stat -c %s -- "$bundle/$path") == "$bytes" &&
           $(sha256_upper "$bundle/$path") == "$digest" ]] ||
            fail "vm$vm_id manifest entry mismatch: $path"
    done < <(jq -er '.files[] | [.path, (.bytes|tostring), .sha256] | @tsv' \
        "$manifest")

    jq -e \
        --arg coordinator "$(sha256_upper "$bundle/install-system-nvapi-projection.ps1")" \
        --arg installerSha "$(sha256_upper "$bundle/install-nvapi-shim.ps1")" \
        --arg writer "$(sha256_upper "$bundle/patch-grid-strings.ps1")" \
        --arg catalog "$(sha256_upper "$bundle/vgpu-profile-catalog.json")" \
        --arg shim86 "$(sha256_upper "$bundle/nvapi.dll")" \
        --arg shim64 "$(sha256_upper "$bundle/nvapi64.dll")" \
        --arg probe86 "$(sha256_upper "$bundle/SystemNvapiProbe32.exe")" \
        --arg probe64 "$(sha256_upper "$bundle/SystemNvapiProbe64.exe")" \
        --arg d3dProbe86 "$(sha256_upper "$bundle/D3D12CapabilityProbe32.exe")" \
        --arg d3dProbe64 "$(sha256_upper "$bundle/D3D12CapabilityProbe64.exe")" '
        .payload.coordinatorSha256 == $coordinator and
        .payload.lowLevelInstallerSha256 == $installerSha and
        .payload.profileWriterSha256 == $writer and
        .payload.identityCatalogJsonSha256 == $catalog and
        .payload.shimX86Sha256 == $shim86 and
        .payload.shimX64Sha256 == $shim64 and
        .payload.probeX86Sha256 == $probe86 and
        .payload.probeX64Sha256 == $probe64 and
        .payload.d3dProbeX86Sha256 == $d3dProbe86 and
        .payload.d3dProbeX64Sha256 == $d3dProbe64
    ' "$contract" >/dev/null || fail "vm$vm_id executable payload is not contract-bound"
    [[ $(sha256_upper "$bundle/monitor-edid.bin") == \
        "$(jq -er '.monitor.edidSha256' "$contract")" ]] ||
        fail "vm$vm_id monitor EDID is not contract-bound"
    assert_edid "$bundle/monitor-edid.bin" "$monitor_vendor" \
        "$monitor_product" "$monitor_edid_name"
    if find "$bundle" -maxdepth 1 -type f \
            \( -iname '*.inf' -o -iname '*.cat' -o -iname '*.sys' \) \
            -print -quit | grep -q .; then
        fail "vm$vm_id package contains a kernel-driver asset"
    fi
    if rg -n '123456|HOST_PASSWORD|SUDO_PASSWORD|password[[:space:]]*=' \
            "$bundle" >/dev/null; then
        fail "vm$vm_id package contains a credential-like value"
    fi
}

# All three supported GPU model families, three board vendors, three memory
# makers and unrelated monitors prove that the coordinator is catalog-driven.
create_fixture 901 gtx750ti_asus_2gb aoc-2470w
package_fixture 901 "$tmp/output-aoc"
assert_bundle "$tmp/output-aoc" 901 gtx750ti_asus_2gb ASUS aoc-2470w \
    'AOC 2470W' AOC 0x2470 AOC2470 2470W AOC Samsung 1 Samsung

create_fixture 902 gt1030_msi_2gb dell-p2419h
package_fixture 902 "$tmp/output-dell"
assert_bundle "$tmp/output-dell" 902 gt1030_msi_2gb MSI dell-p2419h \
    'Dell P2419H' DEL 0xD0D8 DELD0D8 'DELL P2419H' Dell Micron 10 Micron

create_fixture 903 gtx1050_gigabyte_2gb samsung-s24f350
package_fixture 903 "$tmp/output-samsung"
assert_bundle "$tmp/output-samsung" 903 gtx1050_gigabyte_2gb Gigabyte \
    samsung-s24f350 'Samsung S24F350' SAM 0x0D20 SAM0D20 S24F350 \
    Samsung 'SK hynix' 6 Hynix

# A 1 GiB/nvidia-256 fixture exercises the native RTX6000-1Q 1325 transport;
# the older 2 GiB fixtures above exercise the RTX6000-2Q 1326 transport.
create_fixture 904 gtx750_gigabyte_1gb dell-p2419h \
    "$vm_root_1g" "$host_config_1g"
package_fixture 904 "$tmp/output-grid-1q" "$vm_root_1g"
assert_bundle "$tmp/output-grid-1q" 904 gtx750_gigabyte_1gb Gigabyte dell-p2419h \
    'Dell P2419H' DEL 0xD0D8 DELD0D8 'DELL P2419H' Dell Elpida 3 Elpida \
    "$vm_root_1g"

# Without --output-root the delivery artifacts must stay inside the numeric
# VM bundle.  This is the path delete-vm removes atomically with that VM.
default_output="$vm_root_1g/904/packages/SystemNvapiProjection"
IMAGE_ROOT="$image_root" VM_ROOT="$vm_root_1g" STAGE_DIR="$stage_dir" \
    bash "$packager" 904 >"$tmp/default-output.log"
assert_bundle "$default_output" 904 gtx750_gigabyte_1gb Gigabyte dell-p2419h \
    'Dell P2419H' DEL 0xD0D8 DELD0D8 'DELL P2419H' Dell Elpida 3 Elpida \
    "$vm_root_1g"
require_text "$default_output" "$tmp/default-output.log"
require_text './deploy/scripts/vmctl.sh cdrom 904 mount' "$tmp/default-output.log"
require_text './deploy/scripts/vmctl.sh cdrom 904 eject' "$tmp/default-output.log"
[[ ! -e "$stage_dir/SystemNvapiProjection" ]] ||
    fail 'default package escaped into the global staging directory'

# A packages symlink would break delete-vm ownership by redirecting artifacts
# outside the numeric VM bundle.  Default packaging must reject it before
# publishing any file through the link.
create_fixture 905 gtx750_asus_1gb dell-p2419h \
    "$vm_root_1g" "$host_config_1g"
mkdir -p "$tmp/outside-packages"
ln -s "$tmp/outside-packages" "$vm_root_1g/905/packages"
if IMAGE_ROOT="$image_root" VM_ROOT="$vm_root_1g" STAGE_DIR="$stage_dir" \
        bash "$packager" 905 >"$tmp/symlink-output.log" 2>&1; then
    fail 'default package followed a packages directory symlink'
fi
require_text 'VM instance tree is unsafe' "$tmp/symlink-output.log"
if find "$tmp/outside-packages" -mindepth 1 -print -quit | grep -q .; then
    fail 'rejected package path wrote through its symlink'
fi

echo 'PASS: system NVAPI/monitor package is process-agnostic, content-bound and generic'
