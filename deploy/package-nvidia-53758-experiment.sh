#!/usr/bin/env bash
# Build a VM-bound package from the audited production-signed consumer catalog.
# The current catalog contains the exact NVIDIA desktop 537.58 WHQL row. This
# command is build-only: it does
# not start/stop a VM, edit vm.conf, mount a guest disk, touch BCD, or install
# any driver.
set -euo pipefail
umask 077
export LC_ALL=C

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/vm-storage.sh
source "$here/lib/vm-storage.sh"
# shellcheck source=lib/signed-consumer-catalog.sh
source "$here/lib/signed-consumer-catalog.sh"

usage() {
    cat >&2 <<'EOF'
usage: ./deploy/package-nvidia-53758-experiment.sh VM_ID \
         (--confirm-disposable-clone | --production-proof-marker FILE) [options]

Options:
  --driver-key KEY       Audited catalog row; default is the unique row for
                         this VM's canonical GPU_PROFILE
  --driver-exe FILE.exe  Exact original vendor WHQL installer selected by KEY
  --output-root DIR      Private package output root
                         (default: $STAGE_DIR/SignedConsumerPackages-v2)
  --confirm-disposable-clone
                         Required acknowledgement: VM_ID is a disposable,
                         independently cloned disk, never the production VM
  --production-proof-marker FILE
                         Private marker produced by
                         signed-consumer-production.sh record-proof; permits
                         add-only staging media for any matching target VM
  -h, --help             Show this help

Output:
  DIR/vmN-UUID-EXPERIMENT_ID/Run-Phase1.cmd
  DIR/vmN-UUID-EXPERIMENT_ID.iso

Attach the generated ISO read-only only to its matching VM UUID.
Open that CD drive, right-click Run-Phase1.cmd and choose "Run as
administrator". The directory form is retained for host-side hash audit.
EOF
}

die() { echo "[signed-consumer-package] ERROR: $*" >&2; exit 1; }
log() { echo "[signed-consumer-package] $*"; }
sha256_upper() { sha256sum -- "$1" | awk '{print toupper($1)}'; }

VM_ID=""
DRIVER_EXE=""
DRIVER_KEY=""
OUTPUT_ROOT=""
CONFIRMED=0
PRODUCTION_PROOF_MARKER=""
while (($#)); do
    case "$1" in
        --driver-exe)
            (($# >= 2)) || die '--driver-exe requires a host EXE file'
            DRIVER_EXE=$2
            shift 2
            ;;
        --driver-key)
            (($# >= 2)) || die '--driver-key requires a catalog key'
            [[ -z "$DRIVER_KEY" ]] || die '--driver-key may appear only once'
            DRIVER_KEY=$2
            shift 2
            ;;
        --output-root)
            (($# >= 2)) || die '--output-root requires a directory'
            OUTPUT_ROOT=$2
            shift 2
            ;;
        --confirm-disposable-clone)
            ((CONFIRMED == 0)) || die \
                '--confirm-disposable-clone may appear only once'
            CONFIRMED=1
            shift
            ;;
        --production-proof-marker)
            (($# >= 2)) || die '--production-proof-marker requires a file'
            [[ -z "$PRODUCTION_PROOF_MARKER" ]] \
                || die '--production-proof-marker may appear only once'
            PRODUCTION_PROOF_MARKER=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            if vm_storage_id_is_supported "$1" && [[ -z "$VM_ID" ]]; then
                VM_ID=$1
                shift
            else
                die "unknown argument or unsupported VM_ID: $1"
            fi
            ;;
    esac
done

[[ -n "$VM_ID" ]] || { usage; exit 2; }
(( CONFIRMED == 0 || ${#PRODUCTION_PROOF_MARKER} == 0 )) \
    || die '--confirm-disposable-clone and --production-proof-marker are mutually exclusive'
((CONFIRMED)) || [[ -n "$PRODUCTION_PROOF_MARKER" ]] || die \
    'refusing a production disk; rerun only for an independent disposable clone with --confirm-disposable-clone'
for dependency in jq sha256sum stat realpath mktemp install awk od tr \
        find sort 7z rg flock cp xorriso; do
    command -v "$dependency" >/dev/null 2>&1 \
        || die "missing dependency: $dependency"
done
signed_consumer_catalog_validate || die 'signed-consumer catalog self-check failed'

vm_storage_init
vm_storage_require_namespace_ready "$VM_ID" \
    || die 'VM storage still uses an old/conflicting layout'
CONF=$(vm_storage_config_path "$VM_ID")
DISK=$(vm_storage_disk_path "$VM_ID")
[[ -f "$CONF" && ! -L "$CONF" && -r "$CONF" ]] \
    || die "VM config is not a readable regular file: $CONF"
[[ -f "$DISK" && ! -L "$DISK" ]] \
    || die "VM disk is missing or unsafe: $DISK"
CONFIG_SHA256=$(sha256_upper "$CONF")

DEPLOYMENT_INTENT=disposable-experiment
QUALIFICATION_MARKER_SHA256=""
QUALIFICATION_ID=""

config_literal() {
    local field=$1 value
    local -a values=()
    mapfile -t values < <(sed -n -E "s/^[[:space:]]*${field}=//p" "$CONF")
    ((${#values[@]} == 1)) || die "vm.conf 必须恰好包含一个 ${field}= literal"
    value=${values[0]%$'\r'}
    value=$(sed -E \
        's/[[:space:]]+#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//' \
        <<<"$value")
    value=${value#\"}; value=${value%\"}; value=${value#\'}; value=${value%\'}
    [[ -n "$value" ]] || die "vm.conf ${field} 为空"
    printf '%s\n' "$value"
}

config_optional_literal() {
    local field=$1 fallback=$2 count
    count=$(grep -Ec "^[[:space:]]*${field}=" "$CONF")
    case "$count" in
        0) printf '%s\n' "$fallback" ;;
        1) config_literal "$field" ;;
        *) die "vm.conf 不能重复定义 ${field}" ;;
    esac
}

# vm.conf is data, not a shell program.  Parse only the audited literals used
# by this builder so a package operation can never execute guest configuration.
CONFIG_VM_ID=$(config_literal VM_ID)
[[ "$CONFIG_VM_ID" == "$VM_ID" ]] \
    || die "VM_ID in config does not match vm${VM_ID}"
VM_UUID=$(config_literal VM_UUID)
GPU_PROFILE=$(config_literal GPU_PROFILE)
CONFIG_GPU_NAME=$(config_literal GPU_NAME)
CONFIG_GPU_VID=$(config_literal GPU_PCI_VID)
CONFIG_GPU_DID=$(config_literal GPU_PCI_DID)
CONFIG_GPU_SUBVID=$(config_literal GPU_SUB_VID)
CONFIG_GPU_SUBDID=$(config_literal GPU_SUB_DID)
CONFIG_MDEV_PROFILE=$(config_literal VGPU_MDEV_PROFILE)
CONFIG_FB_MB=$(config_literal VGPU_FB_MB)
CONFIG_RESOURCE_PROFILE=$(
    config_optional_literal VGPU_RESOURCE_PROFILE "$CONFIG_MDEV_PROFILE"
)
CONFIG_RESOURCE_FB_MB=$(
    config_optional_literal VGPU_RESOURCE_FB_MB "$CONFIG_FB_MB"
)
SPOOF_MODE=$(config_literal SPOOF_MODE)
VGPU_IDENTITY_TARGET=$(config_literal VGPU_IDENTITY_TARGET)
VGPU_MDEV_INTERNAL_PCI_IDENTITY=$(
    config_optional_literal VGPU_MDEV_INTERNAL_PCI_IDENTITY 0
)
[[ "$VM_UUID" =~ ^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$ ]] \
    || die 'VM_UUID is missing or invalid'
signed_consumer_profile_assert_config "$GPU_PROFILE" "$CONFIG_GPU_NAME" \
    "$CONFIG_GPU_VID" "$CONFIG_GPU_DID" "$CONFIG_GPU_SUBVID" \
    "$CONFIG_GPU_SUBDID" "$CONFIG_MDEV_PROFILE" \
    || die 'vm.conf GPU fields differ from the canonical profile catalog'
[[ "$CONFIG_RESOURCE_PROFILE" == "$SC_CANONICAL_MDEV_PROFILE" &&
   "$CONFIG_RESOURCE_FB_MB" == "$SC_CANONICAL_FB_MB" ]] \
    || die 'actual mdev resource differs from the canonical GPU profile'
PROFILE_SHA256=$(signed_consumer_profile_sha256 "$GPU_PROFILE") \
    || die 'could not calculate the canonical profile digest'
if [[ -z "$DRIVER_KEY" ]]; then
    DRIVER_KEY=$(signed_consumer_driver_audited_default_for_profile "$GPU_PROFILE") \
        || die 'this GPU profile has no audited signed-consumer driver row'
fi
signed_consumer_driver_load "$DRIVER_KEY" || die 'unknown signed-consumer driver key'
signed_consumer_driver_assert_profile || die 'driver key does not match this VM GPU profile'
[[ "$SPOOF_MODE" == B && "$VGPU_IDENTITY_TARGET" == name-only ]] \
    || die 'phase 1 requires SPOOF_MODE=B / VGPU_IDENTITY_TARGET=name-only'
case "${VGPU_MDEV_INTERNAL_PCI_IDENTITY:-0}" in
    0|off|false|no|'') ;;
    *) die 'phase 1 requires native internal mdev PCI identity' ;;
esac

QEMU_PATH=${QEMU_BIN:-$here/../build/qemu-system-x86_64}
QEMU_PATH=$(realpath -e -- "$QEMU_PATH") || die 'current QEMU binary is missing'
QEMU_SHA256=$(signed_consumer_qemu_sha256 "$QEMU_PATH") || die 'current QEMU binary is unsafe'
HOST_DRIVER_SHA256=$(signed_consumer_host_driver_sha256) || die 'current NVIDIA host-driver fact is unavailable'
HOST_STACK_SHA256=$(signed_consumer_host_stack_sha256 \
    "$SC_CANONICAL_MDEV_PROFILE" "$SC_CANONICAL_FB_MB") \
    || die 'current kernel/NVIDIA module/physical GPU/mdev type facts are unavailable'

if [[ -n "$PRODUCTION_PROOF_MARKER" ]]; then
    PRODUCTION_PROOF_MARKER=$(realpath -e -- "$PRODUCTION_PROOF_MARKER") \
        || die 'production proof marker does not exist'
    [[ -f "$PRODUCTION_PROOF_MARKER" && ! -L "$PRODUCTION_PROOF_MARKER" &&
       "$(stat -c %h -- "$PRODUCTION_PROOF_MARKER")" == 1 ]] \
        || die 'production proof marker is unsafe'
    [[ "$(stat -c %u -- "$PRODUCTION_PROOF_MARKER")" == 0 ]] \
        || die 'production proof marker must be root-owned record-proof output'
    marker_mode=$(stat -c %a -- "$PRODUCTION_PROOF_MARKER")
    (( (8#$marker_mode & 022) == 0 )) \
        || die 'production proof marker must not be group/world writable'
    QUALIFICATION_ID=$(jq -er '.qualificationId' "$PRODUCTION_PROOF_MARKER") \
        || die 'production proof marker has no qualificationId'
    jq -e --arg id "$QUALIFICATION_ID" --arg purpose "$SIGNED_CONSUMER_QUALIFICATION_PURPOSE" \
        --arg backend "$SIGNED_CONSUMER_BACKEND_ABI" --arg profile "$SC_CANONICAL_GPU_PROFILE" \
        --arg profileSha "$PROFILE_SHA256" --arg gpuName "$SC_CANONICAL_GPU_NAME" \
        --arg pnp "$SC_CANONICAL_TARGET_PNP" --arg driverKey "$SC_DRIVER_KEY" \
        --arg version "$SC_DRIVER_VERSION" --arg infSha "$SC_INF_SHA256" \
        --arg catSha "$SC_CATALOG_SHA256" --arg sysSha "$SC_KERNEL_SHA256" \
        --arg installerSha "$SC_INSTALLER_SHA256" \
        --arg packageBuilder "$SC_PACKAGE_BUILDER" \
        --arg packageBuilderSha "$SC_PACKAGE_BUILDER_SHA256" \
        --arg guestValidator "$SC_GUEST_VALIDATOR" \
        --arg guestValidatorSha "$SC_GUEST_VALIDATOR_SHA256" \
        --arg signer "$SC_CATALOG_SIGNER_THUMBPRINT" --arg baseline "$SC_BASELINE_PNP_PREFIX" \
        --arg baselineVersion "$SC_BASELINE_DRIVER_VERSION" --arg qemuSha "$QEMU_SHA256" \
        --arg hostDriverSha "$HOST_DRIVER_SHA256" --arg hostStackSha "$HOST_STACK_SHA256" \
        --arg mdev "$SC_CANONICAL_MDEV_PROFILE" \
        --argjson fb "$SC_CANONICAL_FB_MB" '
        .schemaVersion == 2 and .purpose == $purpose and .qualificationId == $id and
        .consumer == {gpuProfile:$profile,profileSha256:$profileSha,gpuName:$gpuName,exactHardwareId:$pnp} and
        .driver == {key:$driverKey,version:$version,infSha256:$infSha,catalogSha256:$catSha,
                    kernelSha256:$sysSha,catalogSignerThumbprint:$signer,
                    baselinePnpPrefix:$baseline,baselineDriverVersion:$baselineVersion,
                    installerSha256:$installerSha,packageBuilder:$packageBuilder,
                    packageBuilderSha256:$packageBuilderSha,
                    guestValidator:$guestValidator,
                    guestValidatorSha256:$guestValidatorSha} and
        .compatibility == {backendAbi:$backend,qemuSha256:$qemuSha,
                           hostDriverSha256:$hostDriverSha,hostStackSha256:$hostStackSha,
                           mdevProfile:$mdev,
                           framebufferMb:$fb,projection:"outer-only",internalIdentity:"native"} and
        .result == {displayCount:1,configManagerErrorCode:0,testsigning:false,
                    nointegritychecks:false,bcdChanged:false}
    ' "$PRODUCTION_PROOF_MARKER" >/dev/null \
        || die 'production proof does not match this canonical profile/driver/host stack'
    [[ "$(signed_consumer_qualification_id "$PROFILE_SHA256" "$QEMU_SHA256" "$HOST_DRIVER_SHA256" "$HOST_STACK_SHA256")" == "$QUALIFICATION_ID" ]] \
        || die 'qualificationId is not the content digest of current compatibility facts'
    QUALIFICATION_MARKER_SHA256=$(sha256_upper "$PRODUCTION_PROOF_MARKER")
    DEPLOYMENT_INTENT=qualified-production-staging
fi

if [[ -z "$DRIVER_EXE" ]]; then
    DRIVER_EXE="$IMAGE_ROOT/$SC_EVIDENCE_INSTALLER_REL"
fi
DRIVER_EXE=$(realpath -e -- "$DRIVER_EXE") \
    || die 'original NVIDIA installer does not exist'
[[ -f "$DRIVER_EXE" && ! -L "$DRIVER_EXE" ]] \
    || die 'driver installer must be a regular, non-symlink file'
[[ "$(basename -- "$DRIVER_EXE")" == "$SC_INSTALLER_NAME" &&
   "$(stat -c %s -- "$DRIVER_EXE")" == "$SC_INSTALLER_BYTES" &&
   "$(sha256_upper "$DRIVER_EXE")" == "$SC_INSTALLER_SHA256" ]] \
    || die 'refusing an installer that differs from the audited original WHQL image'

OUTPUT_ROOT=${OUTPUT_ROOT:-"$STAGE_DIR/SignedConsumerPackages-v2"}
[[ "$OUTPUT_ROOT" == /* && "$OUTPUT_ROOT" != / ]] \
    || die '--output-root must be an absolute non-root path'
OUTPUT_ROOT=$(realpath -m -- "$OUTPUT_ROOT")
if [[ -e "$OUTPUT_ROOT" || -L "$OUTPUT_ROOT" ]]; then
    [[ -d "$OUTPUT_ROOT" && ! -L "$OUTPUT_ROOT" ]] \
        || die "output root is not a real directory: $OUTPUT_ROOT"
else
    mkdir -m 0700 -p -- "$OUTPUT_ROOT"
fi
OUTPUT_ROOT=$(realpath -e -- "$OUTPUT_ROOT")
[[ "$(stat -c %u -- "$OUTPUT_ROOT")" == "$EUID" ]] \
    || die 'output root must be owned by the packager user'
mode=$(stat -c %a -- "$OUTPUT_ROOT")
(( (8#$mode & 077) == 0 )) \
    || die 'output root must not be accessible by group/other users'
exec {LOCK_FD}<"$OUTPUT_ROOT"
flock -x "$LOCK_FD"

EXPERIMENT_ID=$(od -An -N16 -tx1 /dev/urandom |
    tr -d ' \n' | tr a-f A-F)
[[ "$EXPERIMENT_ID" =~ ^[0-9A-F]{32}$ ]] \
    || die 'could not generate experiment ID'
UUID_LOWER=${VM_UUID,,}
UUID_UPPER=${VM_UUID^^}
OUTPUT_DIR="$OUTPUT_ROOT/vm${VM_ID}-${UUID_LOWER}-${EXPERIMENT_ID}"
OUTPUT_ISO="${OUTPUT_DIR}.iso"
[[ ! -e "$OUTPUT_DIR" && ! -L "$OUTPUT_DIR" &&
   ! -e "$OUTPUT_ISO" && ! -L "$OUTPUT_ISO" ]] \
    || die "output already exists: $OUTPUT_DIR"

work=$(mktemp -d "$OUTPUT_ROOT/.vm${VM_ID}-signed-consumer.XXXXXXXX")
cleanup() { rm -rf -- "${work:-}"; }
trap cleanup EXIT

log 'extracting the untouched Display.Driver payload from the locked vendor EXE'
mkdir -m 0700 "$work/extracted"
7z x -y -bd -bso0 -bsp0 \
    -o"$work/extracted" "$DRIVER_EXE" 'Display.Driver/*'
DRIVER_ROOT="$work/extracted/Display.Driver"
[[ -d "$DRIVER_ROOT" && ! -L "$DRIVER_ROOT" ]] \
    || die 'vendor EXE did not produce Display.Driver'
if find "$DRIVER_ROOT" -type l -print -quit | rg -q .; then
    die 'extracted vendor payload unexpectedly contains a symlink'
fi
if find "$DRIVER_ROOT" ! -type f ! -type d -print -quit | rg -q .; then
    die 'extracted vendor payload contains an unsupported object'
fi

INF="$DRIVER_ROOT/$SC_INF_NAME"
CAT="$DRIVER_ROOT/$SC_CATALOG_NAME"
SYS="$DRIVER_ROOT/$SC_KERNEL_NAME"
[[ -f "$INF" && -f "$CAT" && -f "$SYS" ]] \
    || die 'locked INF/CAT/SYS is missing after extraction'
[[ "$(sha256_upper "$INF")" == "$SC_INF_SHA256" &&
   "$(sha256_upper "$CAT")" == "$SC_CATALOG_SHA256" &&
   "$(sha256_upper "$SYS")" == "$SC_KERNEL_SHA256" ]] \
    || die 'extracted INF/CAT/SYS differs from the audited original bytes'
driver_version_regex=${SC_DRIVER_VERSION//./\\.}
rg -q "^[[:space:]]*DriverVer[[:space:]]*=.*,[[:space:]]*${driver_version_regex}[[:space:]]*$" "$INF" \
    || die "$SC_INF_NAME DriverVer changed"
rg -qi "^[[:space:]]*CatalogFile[[:space:]]*=[[:space:]]*${SC_CATALOG_NAME//./\\.}[[:space:]]*$" "$INF" \
    || die "$SC_INF_NAME catalog name changed"
model_line_count=$(tr -d '\r' <"$INF" |
    sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' |
    grep -Fxc -- "$SC_INF_MODEL_LINE" || true)
[[ "$model_line_count" == 1 ]] \
    || die "$SC_INF_NAME does not contain exactly one audited model row for $SC_CANONICAL_TARGET_PNP"

PUBLISHED="$work/published"
mkdir -m 0700 "$PUBLISHED"
mv -- "$DRIVER_ROOT" "$PUBLISHED/Display.Driver"
MANIFEST="$PUBLISHED/payload-manifest.sha256"
: >"$MANIFEST"
file_count=0
payload_bytes=0
while IFS= read -r -d '' relative; do
    [[ "$relative" != *$'\n'* && "$relative" != *$'\r'* ]] \
        || die 'vendor payload contains an unsupported newline in a filename'
    file="$PUBLISHED/Display.Driver/$relative"
    printf '%s  %s\n' "$(sha256_upper "$file")" "$relative" >>"$MANIFEST"
    ((file_count += 1))
    ((payload_bytes += $(stat -c %s -- "$file")))
done < <(find "$PUBLISHED/Display.Driver" -type f -printf '%P\0' | sort -z)
((file_count > 0 && payload_bytes > 0)) \
    || die 'vendor payload manifest is empty'
MANIFEST_SHA256=$(sha256_upper "$MANIFEST")

CONTRACT="$PUBLISHED/experiment-contract.json"
jq -n \
    --argjson schemaVersion 2 \
    --arg experimentId "$EXPERIMENT_ID" \
    --argjson vmId "$VM_ID" \
    --arg vmUuid "$UUID_UPPER" \
    --arg sourceHostMode B \
    --arg gpuProfile "$SC_CANONICAL_GPU_PROFILE" \
    --arg profileSha256 "$PROFILE_SHA256" \
    --arg driverKey "$SC_DRIVER_KEY" \
    --arg qualificationId "$QUALIFICATION_ID" \
    --arg qualificationSha256 "$QUALIFICATION_MARKER_SHA256" \
    --arg deploymentIntent "$DEPLOYMENT_INTENT" \
    --arg baselinePnpId "$SC_BASELINE_PNP_PREFIX" \
    --arg targetPnpId "$SC_CANONICAL_TARGET_PNP" \
    --arg targetGpuName "$SC_CANONICAL_GPU_NAME" \
    --arg installerName "$SC_INSTALLER_NAME" \
    --argjson installerBytes "$SC_INSTALLER_BYTES" \
    --arg installerSha256 "$SC_INSTALLER_SHA256" \
    --arg infName "$SC_INF_NAME" \
    --arg infSha256 "$SC_INF_SHA256" \
    --arg infModelLine "$SC_INF_MODEL_LINE" \
    --arg catalogName "$SC_CATALOG_NAME" \
    --arg catalogSha256 "$SC_CATALOG_SHA256" \
    --arg catalogSignerThumbprint "$SC_CATALOG_SIGNER_THUMBPRINT" \
    --arg kernelName "$SC_KERNEL_NAME" \
    --arg kernelSha256 "$SC_KERNEL_SHA256" \
    --arg kernelSignerThumbprint "$SC_KERNEL_SIGNER_THUMBPRINT" \
    --arg driverVersion "$SC_DRIVER_VERSION" \
    --arg baselineDriverVersion "$SC_BASELINE_DRIVER_VERSION" \
    --arg manifestSha256 "$MANIFEST_SHA256" \
    --argjson fileCount "$file_count" \
    --argjson payloadBytes "$payload_bytes" \
    '{
        schemaVersion: $schemaVersion,
        experimentId: $experimentId,
        vmId: $vmId,
        vmUuid: $vmUuid,
        sourceHostMode: $sourceHostMode,
        gpuProfile: $gpuProfile,
        profileSha256: $profileSha256,
        driverKey: $driverKey,
        qualificationId: $qualificationId,
        qualificationSha256: $qualificationSha256,
        deploymentIntent: $deploymentIntent,
        baselinePnpId: $baselinePnpId,
        targetPnpId: $targetPnpId,
        targetGpuName: $targetGpuName,
        driver: {
            installerName: $installerName,
            installerBytes: $installerBytes,
            installerSha256: $installerSha256,
            infName: $infName,
            infSha256: $infSha256,
            infModelLine: $infModelLine,
            catalogName: $catalogName,
            catalogSha256: $catalogSha256,
            catalogSignerThumbprint: $catalogSignerThumbprint,
            kernelName: $kernelName,
            kernelSha256: $kernelSha256,
            kernelSignerThumbprint: $kernelSignerThumbprint,
            driverVersion: $driverVersion,
            baselineDriverVersion: $baselineDriverVersion
        },
        payload: {
            manifestName: "payload-manifest.sha256",
            manifestSha256: $manifestSha256,
            fileCount: $fileCount,
            bytes: $payloadBytes
        }
    }' >"$CONTRACT"

[[ "$SC_PACKAGE_BUILDER" == "$(basename -- "$0")" ]] \
    || die "driver row $SC_DRIVER_KEY 需要由 $SC_PACKAGE_BUILDER 构建"
GUEST_SCRIPT="$PUBLISHED/$SC_GUEST_VALIDATOR"
install -m 0600 "$here/guest/$SC_GUEST_VALIDATOR" \
    "$GUEST_SCRIPT"
RUNNER="$PUBLISHED/Run-Phase1.cmd"
cat >"$RUNNER" <<CMD
@echo off
setlocal
cd /d "%~dp0"
echo G-11 signed-consumer - Phase 1 add-only staging
echo This UUID-bound package uses an untouched production-signed driver. The VM will fully power off on success.
echo.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0${SC_GUEST_VALIDATOR}" -ContractPath "%~dp0experiment-contract.json" -DriverRoot "%~dp0Display.Driver" -ManifestPath "%~dp0payload-manifest.sha256"
set "result=%ERRORLEVEL%"
if not "%result%"=="0" (
  echo.
  echo Experiment staging failed. No BCD or certificate bypass was attempted.
  pause
)
exit /b %result%
CMD
chmod 0600 "$RUNNER"

CONTRACT_SHA256=$(sha256_upper "$CONTRACT")
SCRIPT_SHA256=$(sha256_upper "$GUEST_SCRIPT")
[[ "$SCRIPT_SHA256" == "$SC_GUEST_VALIDATOR_SHA256" ]] \
    || die 'published guest validator differs from the qualification-bound source bytes'
RUNNER_SHA256=$(sha256_upper "$RUNNER")
PACKAGE_STATE="$PUBLISHED/package-state.json"
jq -n \
    --argjson schemaVersion 2 \
    --arg experimentId "$EXPERIMENT_ID" \
    --argjson vmId "$VM_ID" \
    --arg vmUuid "$UUID_LOWER" \
    --arg sourceConfigSha256 "$CONFIG_SHA256" \
    --arg gpuProfile "$SC_CANONICAL_GPU_PROFILE" \
    --arg profileSha256 "$PROFILE_SHA256" \
    --arg driverKey "$SC_DRIVER_KEY" \
    --arg qualificationId "$QUALIFICATION_ID" \
    --arg qualificationSha256 "$QUALIFICATION_MARKER_SHA256" \
    --arg targetPnpId "$SC_CANONICAL_TARGET_PNP" \
    --arg expectedDriverVersion "$SC_DRIVER_VERSION" \
    --arg installerSha256 "$SC_INSTALLER_SHA256" \
    --arg contractSha256 "$CONTRACT_SHA256" \
    --arg scriptSha256 "$SCRIPT_SHA256" \
    --arg runnerSha256 "$RUNNER_SHA256" \
    --arg manifestSha256 "$MANIFEST_SHA256" \
    --argjson payloadFileCount "$file_count" \
    --argjson payloadBytes "$payload_bytes" \
    --arg deploymentIntent "$DEPLOYMENT_INTENT" \
    '{
        schemaVersion: $schemaVersion,
        experimentId: $experimentId,
        vmId: $vmId,
        vmUuid: $vmUuid,
        sourceHostMode: "B",
        sourceConfigSha256: $sourceConfigSha256,
        gpuProfile: $gpuProfile,
        profileSha256: $profileSha256,
        driverKey: $driverKey,
        qualificationId: $qualificationId,
        qualificationSha256: $qualificationSha256,
        installerSha256: $installerSha256,
        contractSha256: $contractSha256,
        scriptSha256: $scriptSha256,
        runnerSha256: $runnerSha256,
        manifestSha256: $manifestSha256,
        payloadFileCount: $payloadFileCount,
        payloadBytes: $payloadBytes,
        targetPnpId: $targetPnpId,
        expectedDriverVersion: $expectedDriverVersion,
        deploymentIntent: $deploymentIntent
    }' >"$PACKAGE_STATE"

[[ "$(sha256_upper "$CONF")" == "$CONFIG_SHA256" ]] \
    || die 'VM config changed during extraction; discard this package and rebuild'
ISO_WORK="$work/SignedConsumer.iso"
xorriso -as mkisofs -quiet -iso-level 3 -J -joliet-long -r \
    -V "SC_VM${VM_ID}" -o "$ISO_WORK" "$PUBLISHED"
[[ -f "$ISO_WORK" && ! -L "$ISO_WORK" &&
   "$(stat -c %s -- "$ISO_WORK")" -gt 0 ]] \
    || die 'read-only experiment ISO was not produced'
ISO_SHA256=$(sha256_upper "$ISO_WORK")
mv -T -- "$PUBLISHED" "$OUTPUT_DIR"
mv -- "$ISO_WORK" "$OUTPUT_ISO"
trap - EXIT
rm -rf -- "$work"
work=""

if [[ "$DEPLOYMENT_INTENT" == qualified-production-staging ]]; then
    HANDOFF_TARGET="绑定的 vm${VM_ID}；qualification ${QUALIFICATION_ID} 已锁定，仍只做 add-only stage"
else
    HANDOFF_TARGET='绑定的 Windows 可丢弃克隆'
fi
GUEST_RECEIPT_PATH="C:\\ProgramData\\${SC_GUEST_STATE_ROOT}\\receipts"
cat <<EOF
[signed-consumer-package] PASS
  VM:             vm${VM_ID} / ${UUID_LOWER}
  experiment:     ${EXPERIMENT_ID}
  profile:        ${SC_CANONICAL_GPU_PROFILE}
  driver key:     ${SC_DRIVER_KEY}
  source mode:    B/native ${SC_BASELINE_PNP_PREFIX} / ${SC_BASELINE_DRIVER_VERSION}
  deployment:     ${DEPLOYMENT_INTENT}
  qualification:  ${QUALIFICATION_ID:-disposable-unqualified-probe}
  target tuple:   ${SC_CANONICAL_TARGET_PNP}
  target driver:  ${SC_DRIVER_VERSION} / original WHQL
  payload files:  ${file_count}
  payload bytes:  ${payload_bytes}
  package:         ${OUTPUT_DIR}
  entry:           ${OUTPUT_DIR}/Run-Phase1.cmd
  read-only ISO:   ${OUTPUT_ISO}
  ISO SHA256:      ${ISO_SHA256}
  contract SHA256: ${CONTRACT_SHA256}

傻瓜步骤：
  1. 把上面的 ISO 作为只读 CD 挂到${HANDOFF_TARGET}。
  2. 在 B/native 启动中打开光盘，右键 Run-Phase1.cmd -> 以管理员身份运行。
  3. staged 回执写入 ProgramData 后 Windows 自动完整关机。
  4. 只有核对 activeInfBefore == activeInfAfter、DEV_1E30/538.33/Code 0 后，
     才能在宿主切换实验 PCI tuple。下次开机 SYSTEM 自动验收并再次完整关机。
  5. pass/fail 回执位于：
     ${GUEST_RECEIPT_PATH}

此包不修改 INF/CAT/SYS，不导入证书，不写 BCD，不开启 testsigning 或
nointegritychecks；也不会解除正式 VM 的 strict-A 门禁。
EOF
