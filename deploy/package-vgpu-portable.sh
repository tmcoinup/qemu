#!/usr/bin/env bash
# Build one offline, VM-unbound Windows EXE for every audited B/native profile.
set -euo pipefail
umask 077

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"

# shellcheck source=lib/vm-storage.sh
source "$here/lib/vm-storage.sh"
# shellcheck source=lib/vgpu-profiles.sh
source "$here/lib/vgpu-profiles.sh"
# shellcheck source=lib/gpuz-assets.sh
source "$here/lib/gpuz-assets.sh"

usage() {
    cat <<'EOF'
usage: ./deploy/package-vgpu-portable.sh [options]

Build one completely offline guest EXE.  It contains every audited profile,
does not contain a VM ID/UUID, and selects the current VM profile from the
read-only per-boot firmware claim published automatically by start-vm.sh.

Options:
  --output-dir DIR       Expanded host audit bundle
                         (default: $STAGE_DIR/VgpuPortable/.host-bundle)
  --output-exe FILE.exe  Guest file
                         (default: $STAGE_DIR/VgpuPortable/VgpuPortable.exe)
  --gpuz-source FILE     Audited TechPowerUp GPU-Z 2.70 source
  --list-gpu-profiles    Print the embedded profile catalog
  -h, --help             Show this help

No VM_ID is accepted.  Copy VgpuPortable.exe into any B/native Windows VM,
or place it in the Windows base image before cloning.
EOF
}

die() {
    echo "[vgpu-portable-package] ERROR: $*" >&2
    exit 1
}

log() {
    echo "[vgpu-portable-package] $*"
}

sha256_upper() {
    sha256sum -- "$1" | awk '{print toupper($1)}'
}

OUTPUT_DIR=""
OUTPUT_EXE=""
GPUZ_SOURCE=""
while (($#)); do
    case "$1" in
        --output-dir)
            (($# >= 2)) || die "--output-dir requires a path"
            OUTPUT_DIR=$2
            shift 2
            ;;
        --output-exe)
            (($# >= 2)) || die "--output-exe requires a path"
            OUTPUT_EXE=$2
            shift 2
            ;;
        --gpuz-source)
            (($# >= 2)) || die "--gpuz-source requires a host file"
            GPUZ_SOURCE=$2
            shift 2
            ;;
        --list-gpu-profiles)
            vgpu_profile_print_catalog
            exit 0
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument (portable mode accepts no VM_ID): $1"
            ;;
    esac
done

for dependency in jq sha256sum awk stat find realpath mktemp install flock \
        x86_64-w64-mingw32-gcc x86_64-w64-mingw32-windres; do
    command -v "$dependency" >/dev/null 2>&1 \
        || die "missing host dependency: $dependency"
done
vgpu_profile_validate_catalog ||
    die "GPU identity catalog validation failed"
vm_storage_init
vm_storage_prepare

if [[ -z "$GPUZ_SOURCE" ]]; then
    GPUZ_SOURCE=$(gpuz_asset_default_source) ||
        die "could not derive the canonical GPU-Z source"
fi
GPUZ_SOURCE=$(gpuz_asset_resolve_source "$GPUZ_SOURCE") ||
    die "invalid --gpuz-source"

PORTABLE_ROOT="$STAGE_DIR/VgpuPortable"
[[ -n "$OUTPUT_DIR" ]] || OUTPUT_DIR="$PORTABLE_ROOT/.host-bundle"
[[ -n "$OUTPUT_EXE" ]] || OUTPUT_EXE="$PORTABLE_ROOT/VgpuPortable.exe"
[[ "$OUTPUT_DIR" == /* && "$OUTPUT_DIR" != / ]] ||
    die "--output-dir must be a non-root absolute path"
[[ "$OUTPUT_EXE" == /* && "${OUTPUT_EXE,,}" == *.exe ]] ||
    die "--output-exe must be an absolute .exe path"
OUTPUT_DIR=$(realpath -m -- "$OUTPUT_DIR")
OUTPUT_EXE=$(realpath -m -- "$OUTPUT_EXE")
[[ "$(dirname -- "$OUTPUT_DIR")" == "$(dirname -- "$OUTPUT_EXE")" ]] ||
    die "--output-dir and --output-exe must share one trusted parent"
[[ "$OUTPUT_DIR" != "$OUTPUT_EXE" ]] ||
    die "bundle directory and EXE path must differ"
[[ "$OUTPUT_DIR" != "$here" && "$OUTPUT_DIR" != "$here/"* ]] ||
    die "output must not be inside the deploy source tree"
[[ ! -L "$OUTPUT_DIR" && ! -L "$OUTPUT_EXE" ]] ||
    die "output paths must not be symlinks"

OUTPUT_PARENT=$(dirname -- "$OUTPUT_EXE")
mkdir -p -- "$OUTPUT_PARENT"
OUTPUT_PARENT=$(realpath -e -- "$OUTPUT_PARENT") ||
    die "could not resolve output parent"
[[ -d "$OUTPUT_PARENT" && ! -L "$OUTPUT_PARENT" ]] ||
    die "output parent must be a regular directory"
[[ "$(stat -c %u -- "$OUTPUT_PARENT")" == "$EUID" ]] ||
    die "output parent must be owned by the packaging user"
parent_mode=$(stat -c %a -- "$OUTPUT_PARENT")
(( (8#$parent_mode & 002) == 0 )) ||
    die "output parent must not be other-writable"

# Lock the directory inode instead of creating a public lock pathname.
exec {PACKAGE_LOCK_FD}<"$OUTPUT_PARENT" ||
    die "could not open output parent for locking"
flock -x "$PACKAGE_LOCK_FD"
[[ "$(stat -Lc '%d:%i' -- "/proc/self/fd/$PACKAGE_LOCK_FD")" == \
   "$(stat -Lc '%d:%i' -- "$OUTPUT_PARENT")" ]] ||
    die "output parent changed while acquiring the package lock"

CATALOG_SHA256=$(vgpu_profile_catalog_sha256)
[[ "$CATALOG_SHA256" =~ ^[0-9A-F]{64}$ ]] ||
    die "could not calculate the canonical profile catalog hash"

RECEIPT_DIR="$OUTPUT_PARENT/.$(basename -- "$OUTPUT_EXE").receipts"
validate_receipt_dir() {
    [[ -d "$RECEIPT_DIR" && ! -L "$RECEIPT_DIR" &&
       "$(stat -c %u -- "$RECEIPT_DIR")" == "$EUID" &&
       "$(stat -c %a -- "$RECEIPT_DIR")" == 700 ]] ||
        die "portable EXE receipt directory is unsafe"
}
if [[ -e "$RECEIPT_DIR" || -L "$RECEIPT_DIR" ]]; then
    validate_receipt_dir
else
    mkdir -m 0700 -- "$RECEIPT_DIR"
    validate_receipt_dir
fi

validate_existing_exe() {
    [[ -f "$OUTPUT_EXE" && ! -L "$OUTPUT_EXE" ]] ||
        die "existing portable EXE is not a regular file"
    local hash bytes receipt
    hash=$(sha256_upper "$OUTPUT_EXE")
    bytes=$(stat -c %s -- "$OUTPUT_EXE")
    receipt="$RECEIPT_DIR/$hash.json"
    [[ -f "$receipt" && ! -L "$receipt" &&
       "$(stat -c %u -- "$receipt")" == "$EUID" &&
       "$(stat -c %a -- "$receipt")" == 600 ]] ||
        die "existing portable EXE has no trusted content receipt"
    jq -e \
        --arg catalogSha256 "$CATALOG_SHA256" \
        --arg exeSha256 "$hash" \
        --argjson exeBytes "$bytes" '
        (keys | sort) == [
            "bindingMode", "bundleManifestSha256", "catalogSha256",
            "exeBytes", "exeSha256", "launcherFormat", "schemaVersion"
        ] and
        .schemaVersion == 1 and .bindingMode == "portable-auto" and
        .catalogSha256 == $catalogSha256 and
        .launcherFormat == "QEMU_GPUZ_PORTABLE_EXE_V1" and
        .exeSha256 == $exeSha256 and .exeBytes == $exeBytes and
        (.bundleManifestSha256 | test("^[0-9A-F]{64}$"))
    ' "$receipt" >/dev/null ||
        die "existing portable EXE receipt does not match this catalog"
}

EXISTING_EXE=0
if [[ -e "$OUTPUT_EXE" || -L "$OUTPUT_EXE" ]]; then
    validate_existing_exe
    EXISTING_EXE=1
fi
if [[ -e "$OUTPUT_DIR" || -L "$OUTPUT_DIR" ]]; then
    [[ -d "$OUTPUT_DIR" && ! -L "$OUTPUT_DIR" ]] ||
        die "existing expanded bundle is unsafe"
    jq -e --arg catalogSha256 "$CATALOG_SHA256" '
        .schemaVersion == 3 and .bindingMode == "portable-auto" and
        .catalogSha256 == $catalogSha256
    ' "$OUTPUT_DIR/gpuz-contract.json" >/dev/null 2>&1 ||
        die "existing expanded bundle is not an owned portable catalog"
fi

WORK_ROOT=$(mktemp -d "$OUTPUT_PARENT/.vgpu-portable.XXXXXXXX")
cleanup() {
    rm -rf -- "${WORK_ROOT:-}"
    [[ -z "${EXE_STAGE:-}" ]] || rm -f -- "$EXE_STAGE"
}
trap cleanup EXIT
BUNDLE="$WORK_ROOT/bundle"
mkdir -m 0700 -- "$BUNDLE"

for asset in \
        "$here/guest/apply-gpuz-profile.ps1" \
        "$here/guest/apply-vm-profile.ps1" \
        "$here/guest/patch-grid-strings.ps1" \
        "$here/guest/nvapi-shim/nvapi.dll" \
        "$here/guest/nvapi-shim/nvapi_profile_probe32.exe"; do
    [[ -s "$asset" && ! -L "$asset" ]] ||
        die "required guest asset is missing or unsafe: $asset"
done

install -m 0600 -- "$here/guest/apply-gpuz-profile.ps1" \
    "$BUNDLE/apply-gpuz-profile.ps1"
install -m 0600 -- "$here/guest/apply-vm-profile.ps1" \
    "$BUNDLE/apply-vm-profile.ps1"
install -m 0600 -- "$here/guest/patch-grid-strings.ps1" \
    "$BUNDLE/patch-grid-strings.ps1"
install -m 0600 -- "$here/guest/nvapi-shim/nvapi.dll" \
    "$BUNDLE/nvapi.dll"
install -m 0600 -- "$here/guest/nvapi-shim/nvapi_profile_probe32.exe" \
    "$BUNDLE/nvapi_profile_probe32.exe"
gpuz_asset_snapshot "$GPUZ_SOURCE" "$BUNDLE/$GPUZ_ASSET_BUNDLE_NAME" ||
    die "refusing a non-locked GPU-Z source"

profiles_json='[]'
for profile_key in $(vgpu_profile_keys); do
    vgpu_profile_load "$profile_key" ||
        die "could not load catalog profile $profile_key"
    profile_name="profile-${profile_key}.json"
    profile_path="$BUNDLE/$profile_name"
    jq -n \
        --argjson schemaVersion 1 \
        --arg bindingMode portable-auto \
        --arg profile "$GPU_PROFILE" \
        --arg name "$GPU_NAME" \
        --arg expectedPnpId 'PCI\VEN_10DE&DEV_1E30' \
        --argjson nvapiPciVendorId "$((GPU_PCI_VID))" \
        --argjson nvapiPciDeviceId "$((GPU_PCI_DID))" \
        --argjson nvapiPciSubVendorId "$((GPU_SUB_VID))" \
        --argjson nvapiPciSubDeviceId "$((GPU_SUB_DID))" \
        --argjson nvapiPciRevisionId "$((GPU_REV))" \
        --argjson coreClockMHz "$GPU_CORE_MHZ" \
        --argjson boostClockMHz "$GPU_BOOST_MHZ" \
        --argjson memoryClockMHz "$GPU_MEMORY_MHZ" \
        --argjson memoryBusBits "$GPU_MEMORY_BUS_BITS" \
        --argjson memoryBandwidthMBps "$GPU_MEMORY_BANDWIDTH_MBPS" \
        --argjson vramMB "$GPU_VRAM_MB" \
        --argjson memoryType "$GPU_MEMORY_TYPE_NVAPI" \
        --argjson memoryMaker "$GPU_MEMORY_MAKER_NVAPI" \
        --argjson cudaCores "$GPU_CUDA_CORES" \
        --argjson shaderSubPipes "$GPU_SHADER_SUBPIPES" \
        --argjson ropCount "$GPU_ROP_COUNT" \
        --argjson tmuCount "$GPU_TMU_COUNT" \
        --argjson architecture "$((GPU_ARCHITECTURE))" \
        --argjson implementation "$GPU_IMPLEMENTATION" \
        --argjson chipRevision "$((GPU_CHIP_REVISION))" \
        --argjson pcieWidth "$GPU_PCIE_WIDTH" \
        --arg vbiosVersion "${GPU_VBIOS#Version }" '
        {
            schemaVersion: $schemaVersion,
            bindingMode: $bindingMode,
            gpu: {
                profile: $profile,
                name: $name,
                expectedPnpId: $expectedPnpId,
                nvapiPciVendorId: $nvapiPciVendorId,
                nvapiPciDeviceId: $nvapiPciDeviceId,
                nvapiPciSubVendorId: $nvapiPciSubVendorId,
                nvapiPciSubDeviceId: $nvapiPciSubDeviceId,
                nvapiPciRevisionId: $nvapiPciRevisionId,
                coreClockMHz: $coreClockMHz,
                boostClockMHz: $boostClockMHz,
                memoryClockMHz: $memoryClockMHz,
                memoryBusBits: $memoryBusBits,
                memoryBandwidthMBps: $memoryBandwidthMBps,
                vramMB: $vramMB,
                memoryType: $memoryType,
                memoryMaker: $memoryMaker,
                cudaCores: $cudaCores,
                shaderSubPipes: $shaderSubPipes,
                ropCount: $ropCount,
                tmuCount: $tmuCount,
                architecture: $architecture,
                implementation: $implementation,
                chipRevision: $chipRevision,
                pcieWidth: $pcieWidth,
                vbiosVersion: $vbiosVersion
            }
        }' >"$profile_path"
    chmod 0600 "$profile_path"
    profile_sha=$(sha256_upper "$profile_path")
    profiles_json=$(jq -c \
        --arg key "$GPU_PROFILE" \
        --arg canonicalDisplayName "$GPU_NAME" \
        --arg name "$profile_name" \
        --arg sha256 "$profile_sha" '
        . + [{
            key: $key,
            canonicalDisplayName: $canonicalDisplayName,
            asset: {name: $name, sha256: $sha256}
        }]' <<<"$profiles_json")
done

SHIM_SHA256=$(sha256_upper "$BUNDLE/nvapi.dll")
PROBE_SHA256=$(sha256_upper "$BUNDLE/nvapi_profile_probe32.exe")
jq -n \
    --argjson schemaVersion 3 \
    --arg bindingMode portable-auto \
    --arg spoofMode B \
    --arg catalogSha256 "$CATALOG_SHA256" \
    --arg expectedPnpId 'PCI\VEN_10DE&DEV_1E30' \
    --arg expectedDriverVersion 31.0.15.3833 \
    --argjson profiles "$profiles_json" \
    --arg gpuzName "$GPUZ_ASSET_BUNDLE_NAME" \
    --argjson gpuzBytes "$GPUZ_ASSET_BYTES" \
    --arg gpuzVersion "$GPUZ_ASSET_PRODUCT_VERSION" \
    --arg gpuzSha256 "$GPUZ_ASSET_SHA256" \
    --arg shimSha256 "$SHIM_SHA256" \
    --arg probeSha256 "$PROBE_SHA256" '
    {
        schemaVersion: $schemaVersion,
        bindingMode: $bindingMode,
        spoofMode: $spoofMode,
        catalogSha256: $catalogSha256,
        expectedPnpId: $expectedPnpId,
        expectedDriverVersion: $expectedDriverVersion,
        profiles: $profiles,
        gpuz: {
            name: $gpuzName,
            bytes: $gpuzBytes,
            productVersion: $gpuzVersion,
            sha256: $gpuzSha256
        },
        appLocal: {
            shimName: "nvapi.dll",
            shimSha256: $shimSha256,
            probeName: "nvapi_profile_probe32.exe",
            probeSha256: $probeSha256
        }
    }' >"$BUNDLE/gpuz-contract.json"
chmod 0600 "$BUNDLE/gpuz-contract.json"

cat >"$BUNDLE/RUN-GPUZ-PROFILE.cmd" <<'EOF'
@echo off
setlocal
cd /d "%~dp0"
set "GPUZ_PROFILE_SCRIPT=%~dp0apply-gpuz-profile.ps1"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Stop'; try { $q=[char]34; $ps=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'; $a='-NoProfile -ExecutionPolicy Bypass -File '+$q+$env:GPUZ_PROFILE_SCRIPT+$q; $p=Start-Process -FilePath $ps -Verb RunAs -PassThru -Wait -ArgumentList $a; if ($null -eq $p) { throw 'Elevation did not start.' }; exit [int]$p.ExitCode } catch { Write-Error $_; exit 1 }"
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" echo Portable vGPU profile failed with exit code %RC%.
pause
exit /b %RC%
EOF
chmod 0600 "$BUNDLE/RUN-GPUZ-PROFILE.cmd"

files_json='[]'
while IFS= read -r name; do
    hash=$(sha256_upper "$BUNDLE/$name")
    bytes=$(stat -c %s -- "$BUNDLE/$name")
    files_json=$(jq -c \
        --arg name "$name" --arg sha256 "$hash" --argjson bytes "$bytes" \
        '. + [{name: $name, sha256: $sha256, bytes: $bytes}]' \
        <<<"$files_json")
done < <(find "$BUNDLE" -mindepth 1 -maxdepth 1 -type f \
    ! -name READY ! -name bundle-manifest.json -printf '%f\n' | sort)

jq -n \
    --argjson schemaVersion 2 \
    --arg bindingMode portable-auto \
    --argjson files "$files_json" '
    {
        schemaVersion: $schemaVersion,
        bindingMode: $bindingMode,
        files: $files
    }' >"$BUNDLE/bundle-manifest.json"
chmod 0600 "$BUNDLE/bundle-manifest.json"
MANIFEST_SHA256=$(sha256_upper "$BUNDLE/bundle-manifest.json")
printf 'schema_version=1\nmanifest_sha256=%s\n' "$MANIFEST_SHA256" \
    >"$BUNDLE/READY"
chmod 0600 "$BUNDLE/READY"

SINGLE_EXE="$WORK_ROOT/VgpuPortable.exe"
bash "$here/guest/gpuz-launcher/build.sh" \
    --bundle-dir "$BUNDLE" --output "$SINGLE_EXE" >/dev/null
EXE_SHA256=$(sha256_upper "$SINGLE_EXE")
EXE_BYTES=$(stat -c %s -- "$SINGLE_EXE")
RECEIPT_TEMP="$WORK_ROOT/$EXE_SHA256.json"
jq -n \
    --argjson schemaVersion 1 \
    --arg bindingMode portable-auto \
    --arg catalogSha256 "$CATALOG_SHA256" \
    --arg launcherFormat QEMU_GPUZ_PORTABLE_EXE_V1 \
    --arg exeSha256 "$EXE_SHA256" \
    --argjson exeBytes "$EXE_BYTES" \
    --arg bundleManifestSha256 "$MANIFEST_SHA256" '
    {
        schemaVersion: $schemaVersion,
        bindingMode: $bindingMode,
        catalogSha256: $catalogSha256,
        launcherFormat: $launcherFormat,
        exeSha256: $exeSha256,
        exeBytes: $exeBytes,
        bundleManifestSha256: $bundleManifestSha256
    }' >"$RECEIPT_TEMP"
chmod 0600 "$RECEIPT_TEMP"
RECEIPT_FINAL="$RECEIPT_DIR/$EXE_SHA256.json"
if [[ -e "$RECEIPT_FINAL" || -L "$RECEIPT_FINAL" ]]; then
    [[ -f "$RECEIPT_FINAL" && ! -L "$RECEIPT_FINAL" ]] ||
        die "existing content receipt is unsafe"
    cmp -s -- "$RECEIPT_TEMP" "$RECEIPT_FINAL" ||
        die "existing content receipt conflicts with this build"
else
    ln -T -- "$RECEIPT_TEMP" "$RECEIPT_FINAL" ||
        die "could not publish the content receipt"
fi

if ((EXISTING_EXE)); then
    validate_existing_exe
fi
EXE_STAGE="$OUTPUT_PARENT/.$(basename -- "$OUTPUT_EXE").new.$$.$RANDOM"
ln -T -- "$SINGLE_EXE" "$EXE_STAGE" ||
    die "could not prepare stable EXE publication"
chmod 0600 "$EXE_STAGE"

OLD_BUNDLE=""
if [[ -e "$OUTPUT_DIR" ]]; then
    OLD_BUNDLE="$OUTPUT_DIR.old.$$.$RANDOM"
    mv -T -- "$OUTPUT_DIR" "$OLD_BUNDLE"
fi
if ! mv -T -- "$BUNDLE" "$OUTPUT_DIR"; then
    [[ -z "$OLD_BUNDLE" ]] || mv -T -- "$OLD_BUNDLE" "$OUTPUT_DIR"
    die "could not publish expanded bundle"
fi
BUNDLE=""

if ((EXISTING_EXE)); then
    mv -Tf -- "$EXE_STAGE" "$OUTPUT_EXE" ||
        die "could not atomically replace the authenticated portable EXE"
else
    if ! ln -T -- "$EXE_STAGE" "$OUTPUT_EXE"; then
        die "could not atomically publish the portable EXE"
    fi
    rm -f -- "$EXE_STAGE"
fi
EXE_STAGE=""
[[ -z "$OLD_BUNDLE" ]] || rm -rf -- "$OLD_BUNDLE"

trap - EXIT
rm -rf -- "$WORK_ROOT"
WORK_ROOT=""
cat <<EOF
[vgpu-portable-package] PASS
  binding:     portable-auto (no VM ID, no VM UUID)
  profiles:    $(vgpu_profile_keys | paste -sd, -)
  catalog:     ${CATALOG_SHA256}
  launcher:    1.1.0.0
  bundle:      ${OUTPUT_DIR}
  single EXE:  ${OUTPUT_EXE}
  EXE bytes:   ${EXE_BYTES}
  EXE sha256:  ${EXE_SHA256}

这是离线通用 guest 文件。可放进 Windows 基础镜像，克隆后的任意
B/native VM 直接双击；不需要为 VM3/VM4/VM456 分别重新打包。
EOF
