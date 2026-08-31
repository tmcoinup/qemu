#!/usr/bin/env bash
# Build one VM-unbound Windows identity installer for every audited B/native
# profile.  GPU-Z is neither embedded nor required by the default path.  An
# exact audited official image may be imported later through the explicit
# /with-gpuz option.  A separate, explicitly requested private build may embed
# a DLS client token so the same VgpuPortable.exe can finalize every current
# B/native GPU profile without the legacy model-specific finish flow.
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
# shellcheck source=lib/vgpu-driver-assets.sh
source "$here/lib/vgpu-driver-assets.sh"

usage() {
    cat <<'EOF'
usage: ./deploy/package-vgpu-portable.sh [options]

Build one VM-unbound guest EXE.  It contains every audited identity profile,
does not embed or require GPU-Z, does not contain a VM ID/UUID, and selects
the current VM profile from the read-only per-boot firmware claim published
automatically by start-vm.sh.

Options:
  --output-dir DIR       Expanded host audit bundle
                         (default: public unified or private licensed root)
  --output-exe FILE.exe  Guest file
                         (default: VgpuPortable.exe below the selected root)
  --with-license-token   Build a private all-profile finalizer using
                         $STAGE_DIR/client_configuration_token.tok
  --token-file FILE.tok  Same private finalizer with an explicit token path
  --replace-licensed     Replace an authenticated private output whose receipt
                         binds a different token/catalog.  Licensed builds only;
                         the old EXE/bundle is retained in a mode-0700 backup.
  --replace-public       Replace an authenticated public output from an older
                         catalog/format; retain the old EXE/bundle in a
                         mode-0700 repository-external backup.
  --list-gpu-profiles    Print the embedded profile catalog
  -h, --help             Show this help

No VM_ID is accepted.  Double-click VgpuPortable.exe in any B/native Windows
VM to install/query the identity and apply the recommended G-11 native-display
startup/runtime tuning in the same elevated run.  GPU-Z is optional.  To
install it later, put the exact audited official GPU-Z 2.70 file named
GPU-Z.exe beside VgpuPortable.exe and run "VgpuPortable.exe /with-gpuz".
Future unreviewed GPU-Z versions fail closed; GPU-Z bytes are never embedded
in this EXE.

The default output has no DLS token and is safe to place in a prepared base.
--with-license-token/--token-file instead writes to VgpuPortableLicensed by
default.  That EXE contains a DLS credential, remains mode 0600 on the host,
    must not be published, and installs the token, requires NVIDIA Licensed,
    then disables hibernation/Fast Startup for every supported B/native profile
    (GT 730, GT 740, GTX 750, GTX 750 Ti, GT 1030, GTX 1050).
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
WITH_LICENSE_TOKEN=0
TOKEN_FILE=""
REPLACE_LICENSED=0
REPLACE_PUBLIC=0
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
        --with-license-token)
            WITH_LICENSE_TOKEN=1
            shift
            ;;
        --token-file)
            (($# >= 2)) || die "--token-file requires a path"
            WITH_LICENSE_TOKEN=1
            TOKEN_FILE=$2
            shift 2
            ;;
        --replace-licensed)
            REPLACE_LICENSED=1
            shift
            ;;
        --replace-public)
            REPLACE_PUBLIC=1
            shift
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

((REPLACE_LICENSED == 0 || WITH_LICENSE_TOKEN == 1)) ||
    die "--replace-licensed requires --with-license-token or --token-file"
((REPLACE_PUBLIC == 0 || WITH_LICENSE_TOKEN == 0)) ||
    die "--replace-public cannot be combined with a license token"
((REPLACE_PUBLIC == 0 || REPLACE_LICENSED == 0)) ||
    die "choose only one replacement mode"

for dependency in jq sha256sum awk stat find realpath mktemp install flock \
        x86_64-w64-mingw32-gcc x86_64-w64-mingw32-windres; do
    command -v "$dependency" >/dev/null 2>&1 \
        || die "missing host dependency: $dependency"
done
vgpu_select_driver_stack \
    || die "could not select the reviewed host/guest driver pair"
case "$VGPU_SELECTED_DRIVER_BRANCH" in
    R535|R570) ;;
    *)
        die "$VGPU_SELECTED_DRIVER_BRANCH does not have a validated B/native portable identity contract"
        ;;
esac
PORTABLE_DRIVER_BRANCH=$VGPU_SELECTED_DRIVER_BRANCH
PORTABLE_DRIVER_VERSION=$VGPU_SELECTED_DRIVER_VERSION
PORTABLE_DRIVER_LABEL=$VGPU_SELECTED_DRIVER_LABEL
vgpu_profile_validate_catalog ||
    die "GPU identity catalog validation failed"
"$here/guest/generate-vgpu-profile-catalog.sh" --check ||
    die "guest-readable GPU identity catalog is stale"
"$here/guest/nvapi-shim/generate-profile-catalog.sh" --check ||
    die "compiled NVAPI GPU identity catalog is stale"
vm_storage_init

TOKEN_SHA256=""
TOKEN_BYTES=0
if ((WITH_LICENSE_TOKEN)); then
    [[ -n "$TOKEN_FILE" ]] || \
        TOKEN_FILE="$STAGE_DIR/client_configuration_token.tok"
    [[ ! -L "$TOKEN_FILE" ]] || die "license token must not be a symlink"
    TOKEN_FILE=$(realpath -e -- "$TOKEN_FILE" 2>/dev/null) ||
        die "license token does not exist: $TOKEN_FILE"
    [[ -f "$TOKEN_FILE" && -r "$TOKEN_FILE" && ! -L "$TOKEN_FILE" ]] ||
        die "license token is not a readable regular file: $TOKEN_FILE"
    [[ "$TOKEN_FILE" != "$here" && "$TOKEN_FILE" != "$here/"* ]] ||
        die "license token must remain outside the repository: $TOKEN_FILE"
    TOKEN_BYTES=$(stat -c %s -- "$TOKEN_FILE")
    ((TOKEN_BYTES >= 1024 && TOKEN_BYTES <= 1048576)) ||
        die "license token size must be 1024..1048576 bytes"
    if LC_ALL=C head -c 256 -- "$TOKEN_FILE" |
            grep -Eiq '<[[:space:]]*(!doctype[[:space:]]+html|html)'; then
        die "license token looks like an HTML error page"
    fi
    token_mode=$(stat -c %a -- "$TOKEN_FILE")
    (( (8#$token_mode & 077) == 0 )) ||
        die "license token must not be group/other-accessible (run chmod 600): $TOKEN_FILE"
    TOKEN_SHA256=$(sha256_upper "$TOKEN_FILE")
    PORTABLE_ROOT="$STAGE_DIR/VgpuPortableLicensed"
else
    PORTABLE_ROOT="$STAGE_DIR/VgpuPortable"
fi
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
    if ((WITH_LICENSE_TOKEN)); then
        jq -e \
            --arg catalogSha256 "$CATALOG_SHA256" \
            --arg exeSha256 "$hash" \
            --argjson exeBytes "$bytes" \
            --arg tokenSha256 "$TOKEN_SHA256" \
            --argjson tokenBytes "$TOKEN_BYTES" \
            --arg driverBranch "$PORTABLE_DRIVER_BRANCH" \
            --arg driverVersion "$PORTABLE_DRIVER_VERSION" '
            .bindingMode == "portable-auto" and
            .catalogSha256 == $catalogSha256 and
            .driverBranch == $driverBranch and
            .driverVersion == $driverVersion and
            .gpuZDelivery == "optional-explicit-sibling" and
            .licenseTokenDelivery == "embedded-private" and
            .licenseTokenSha256 == $tokenSha256 and
            .licenseTokenBytes == $tokenBytes and
            .exeSha256 == $exeSha256 and .exeBytes == $exeBytes and
            (.bundleManifestSha256 | test("^[0-9A-F]{64}$")) and
            (
                ((keys | sort) == [
                    "bindingMode", "bundleManifestSha256", "catalogSha256",
                    "exeBytes", "exeSha256", "gpuZDelivery",
                    "launcherFormat", "licenseTokenBytes",
                    "licenseTokenDelivery", "licenseTokenSha256",
                    "schemaVersion"
                ] and
                 .schemaVersion == 5 and
                 .launcherFormat == "QEMU_VGPU_PORTABLE_LICENSED_V5")
                or
                ((keys | sort) == [
                    "bindingMode", "bundleManifestSha256", "catalogSha256",
                    "exeBytes", "exeSha256", "gpuZDelivery",
                    "guestPerformance", "launcherFormat",
                    "licenseTokenBytes", "licenseTokenDelivery",
                    "licenseTokenSha256", "schemaVersion"
                ] and
                .schemaVersion == 7 and
                 .guestPerformance == "embedded-recommended-native-v1" and
                 .launcherFormat ==
                    "QEMU_VGPU_PORTABLE_LICENSED_UNIFIED_V7")
                or
                ((keys | sort) == [
                    "bindingMode", "bundleManifestSha256", "catalogSha256",
                    "driverBranch", "driverVersion", "exeBytes", "exeSha256",
                    "gpuZDelivery", "guestPerformance", "launcherFormat",
                    "licenseTokenBytes", "licenseTokenDelivery",
                    "licenseTokenSha256", "schemaVersion"
                ] and
                 .schemaVersion == 8 and
                 .guestPerformance == "embedded-recommended-native-v1" and
                 .launcherFormat ==
                    "QEMU_VGPU_PORTABLE_LICENSED_BRANCH_V8")
            )
        ' "$receipt" >/dev/null || {
            ((REPLACE_LICENSED)) && return 1
            die "existing licensed portable EXE receipt does not match this token/catalog (rerun with --replace-licensed to retain it in a private backup and rebuild)"
        }
    else
        jq -e \
            --arg catalogSha256 "$CATALOG_SHA256" \
            --arg exeSha256 "$hash" \
            --argjson exeBytes "$bytes" \
            --arg driverBranch "$PORTABLE_DRIVER_BRANCH" \
            --arg driverVersion "$PORTABLE_DRIVER_VERSION" '
        .bindingMode == "portable-auto" and
        .catalogSha256 == $catalogSha256 and
        .driverBranch == $driverBranch and
        .driverVersion == $driverVersion and
        .exeSha256 == $exeSha256 and .exeBytes == $exeBytes and
        (.bundleManifestSha256 | test("^[0-9A-F]{64}$")) and
        (
            ((keys | sort) == [
                "bindingMode", "bundleManifestSha256", "catalogSha256",
                "exeBytes", "exeSha256", "launcherFormat", "schemaVersion"
            ] and
             .schemaVersion == 1 and
             .launcherFormat == "QEMU_GPUZ_PORTABLE_EXE_V1")
            or
            ((keys | sort) == [
                "bindingMode", "bundleManifestSha256", "catalogSha256",
                "exeBytes", "exeSha256", "gpuZDelivery",
                "launcherFormat", "schemaVersion"
            ] and
             .schemaVersion == 2 and
             .gpuZDelivery == "external-sibling" and
             .launcherFormat == "QEMU_GPUZ_PORTABLE_EXTERNAL_V2")
            or
            ((keys | sort) == [
                "bindingMode", "bundleManifestSha256", "catalogSha256",
                "exeBytes", "exeSha256", "gpuZDelivery",
                "launcherFormat", "schemaVersion"
            ] and
             .schemaVersion == 3 and
             .gpuZDelivery == "external-sibling" and
             .launcherFormat == "QEMU_VGPU_PORTABLE_IDENTITY_V3")
            or
            ((keys | sort) == [
                "bindingMode", "bundleManifestSha256", "catalogSha256",
                "exeBytes", "exeSha256", "gpuZDelivery",
                "launcherFormat", "schemaVersion"
            ] and
             .schemaVersion == 4 and
             .gpuZDelivery == "optional-explicit-sibling" and
             .launcherFormat == "QEMU_VGPU_PORTABLE_IDENTITY_V4")
            or
            ((keys | sort) == [
                "bindingMode", "bundleManifestSha256", "catalogSha256",
                "exeBytes", "exeSha256", "gpuZDelivery",
                "guestPerformance", "launcherFormat", "schemaVersion"
            ] and
             .schemaVersion == 6 and
             .gpuZDelivery == "optional-explicit-sibling" and
             .guestPerformance == "embedded-recommended-native-v1" and
             .launcherFormat == "QEMU_VGPU_PORTABLE_UNIFIED_V6")
            or
            ((keys | sort) == [
                "bindingMode", "bundleManifestSha256", "catalogSha256",
                "driverBranch", "driverVersion", "exeBytes", "exeSha256",
                "gpuZDelivery", "guestPerformance", "launcherFormat",
                "schemaVersion"
            ] and
             .schemaVersion == 7 and
             .gpuZDelivery == "optional-explicit-sibling" and
             .guestPerformance == "embedded-recommended-native-v1" and
             .launcherFormat == "QEMU_VGPU_PORTABLE_BRANCH_V7")
        )
        ' "$receipt" >/dev/null || {
            ((REPLACE_PUBLIC)) && return 1
            die "existing portable EXE receipt does not match this catalog (rerun with --replace-public to retain it in a backup and rebuild)"
        }
    fi
}

validate_existing_bundle_authenticity() {
    local manifest ready manifest_hash file_name file_hash file_bytes
    manifest="$OUTPUT_DIR/bundle-manifest.json"
    ready="$OUTPUT_DIR/READY"
    for required in "$manifest" "$ready" "$OUTPUT_DIR/gpuz-contract.json"; do
        [[ -f "$required" && ! -L "$required" ]] ||
            die "existing bundle has a missing/unsafe authenticated file: $required"
    done
    mapfile -t ready_lines <"$ready"
    [[ ${#ready_lines[@]} -eq 2 &&
       "${ready_lines[0]}" == schema_version=1 &&
       "${ready_lines[1]}" =~ ^manifest_sha256=([0-9A-F]{64})$ ]] ||
        die "existing bundle READY is malformed"
    manifest_hash=$(sha256_upper "$manifest")
    [[ "$manifest_hash" == "${BASH_REMATCH[1]}" ]] ||
        die "existing bundle manifest is not authenticated by READY"
    jq -e '
        .schemaVersion == 4 and .bindingMode == "portable-auto" and
        (.files | type) == "array" and (.files | length) >= 10 and
        all(.files[];
            (keys | sort) == ["bytes", "name", "sha256"] and
            (.name | type) == "string" and
            (.sha256 | test("^[0-9A-F]{64}$")) and
            (.bytes | type) == "number" and (.bytes | floor) == .bytes and
            .bytes >= 0
        ) and
        ([.files[].name] | unique | length) == (.files | length)
    ' "$manifest" >/dev/null ||
        die "existing bundle manifest is malformed"
    while IFS=$'\t' read -r file_name file_hash file_bytes; do
        [[ "$file_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$ &&
           "$file_name" != *..* ]] ||
            die "existing bundle contains an unsafe payload name"
        payload="$OUTPUT_DIR/$file_name"
        [[ -f "$payload" && ! -L "$payload" ]] ||
            die "existing bundle payload is missing/unsafe: $file_name"
        [[ "$(stat -c %s -- "$payload")" == "$file_bytes" &&
           "$(sha256_upper "$payload")" == "$file_hash" ]] ||
            die "existing bundle payload failed its manifest: $file_name"
    done < <(jq -er '.files[] | [.name, .sha256, .bytes] | @tsv' "$manifest")
}

EXISTING_EXE=0
REPLACE_EXISTING=0
REPLACEMENT_KIND=""
if [[ -e "$OUTPUT_EXE" || -L "$OUTPUT_EXE" ]]; then
    if ! validate_existing_exe; then
        if ((WITH_LICENSE_TOKEN && REPLACE_LICENSED)); then
            REPLACEMENT_KIND=licensed
        elif ((!WITH_LICENSE_TOKEN && REPLACE_PUBLIC)); then
            REPLACEMENT_KIND=public
        else
            die "existing portable EXE validation failed"
        fi
        REPLACE_EXISTING=1
    fi
    EXISTING_EXE=1
fi
if [[ -e "$OUTPUT_DIR" || -L "$OUTPUT_DIR" ]]; then
    [[ -d "$OUTPUT_DIR" && ! -L "$OUTPUT_DIR" ]] ||
        die "existing expanded bundle is unsafe"
    if ((WITH_LICENSE_TOKEN)); then
        validate_existing_bundle_authenticity
        jq -e --arg catalogSha256 "$CATALOG_SHA256" \
            --arg tokenSha256 "$TOKEN_SHA256" \
            --argjson tokenBytes "$TOKEN_BYTES" \
            --arg driverVersion "$PORTABLE_DRIVER_VERSION" '
            .schemaVersion == 7 and .bindingMode == "portable-auto" and
            .catalogSha256 == $catalogSha256 and
            .expectedDriverVersion == $driverVersion and
            .licenseToken.name == "client_configuration_token.tok" and
            .licenseToken.sha256 == $tokenSha256 and
            .licenseToken.bytes == $tokenBytes and
            .licenseToken.delivery == "embedded-private"
        ' "$OUTPUT_DIR/gpuz-contract.json" >/dev/null 2>&1 || {
            ((REPLACE_LICENSED)) ||
                die "existing licensed bundle does not match this token/catalog (rerun with --replace-licensed to retain it in a private backup and rebuild)"
            REPLACE_EXISTING=1
            REPLACEMENT_KIND=licensed
        }
    else
        if ! jq -e --arg catalogSha256 "$CATALOG_SHA256" \
                --arg driverVersion "$PORTABLE_DRIVER_VERSION" '
            (.schemaVersion == 3 or .schemaVersion == 4 or
             .schemaVersion == 5 or .schemaVersion == 6) and
            .bindingMode == "portable-auto" and
            .catalogSha256 == $catalogSha256 and
            .expectedDriverVersion == $driverVersion
        ' "$OUTPUT_DIR/gpuz-contract.json" >/dev/null 2>&1; then
            ((REPLACE_PUBLIC)) ||
                die "existing expanded bundle is not the current owned portable catalog (rerun with --replace-public)"
            validate_existing_bundle_authenticity
            REPLACE_EXISTING=1
            REPLACEMENT_KIND=public
        fi
    fi
fi

REPLACED_BACKUP=""
if ((REPLACE_EXISTING)); then
    [[ "$REPLACEMENT_KIND" == public || "$REPLACEMENT_KIND" == licensed ]] ||
        die "internal replacement kind is missing"
    backup_root="$(dirname -- "$OUTPUT_PARENT")/package-backups"
    if [[ -e "$backup_root" || -L "$backup_root" ]]; then
        [[ -d "$backup_root" && ! -L "$backup_root" &&
           "$(stat -c %u -- "$backup_root")" == "$EUID" &&
           "$(stat -c %a -- "$backup_root")" == 700 ]] ||
            die "package backup root is unsafe: $backup_root"
    else
        mkdir -m 0700 -- "$backup_root"
    fi
    backup_prefix=VgpuPortable.old
    [[ "$REPLACEMENT_KIND" == public ]] || backup_prefix=VgpuPortableLicensed.old
    REPLACED_BACKUP=$(mktemp -d "$backup_root/${backup_prefix}.XXXXXXXX")
    backup_exe="$REPLACED_BACKUP/$(basename -- "$OUTPUT_EXE")"
    backup_bundle="$REPLACED_BACKUP/$(basename -- "$OUTPUT_DIR")"
    if ((EXISTING_EXE)); then
        ln -T -- "$OUTPUT_EXE" "$backup_exe" ||
            die "could not retain the authenticated old EXE backup"
        chmod 0600 "$backup_exe"
    fi
    if [[ -e "$OUTPUT_DIR" ]]; then
        cp -a -- "$OUTPUT_DIR" "$backup_bundle" ||
            die "could not retain the authenticated old bundle backup"
    fi
    cat >"$REPLACED_BACKUP/README.txt" <<EOF
Portable backup retained before an authenticated ${REPLACEMENT_KIND} replacement.
Source EXE: $OUTPUT_EXE
Source bundle: $OUTPUT_DIR
Do not publish this directory; licensed generations may contain a DLS client token.
EOF
    chmod 0600 "$REPLACED_BACKUP/README.txt"
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
        "$here/guest/vgpu-profile-catalog.json" \
        "$here/docs/G11-1GB-GPU-EXPANSION.md" \
        "$here/docs/G11-1GB-GPU-EVIDENCE.tsv" \
        "$here/guest/guest-performance/Optimize-Guest.ps1" \
        "$here/guest/guest-performance/01-Audit.cmd" \
        "$here/guest/guest-performance/02-Apply-Recommended.cmd" \
        "$here/guest/guest-performance/03-Verify.cmd" \
        "$here/guest/guest-performance/04-Rollback.cmd" \
        "$here/guest/guest-performance/README.txt" \
        "$here/guest/nvapi-shim/nvapi.dll" \
        "$here/guest/nvapi-shim/nvapi_profile_probe32.exe" \
        "$here/guest/nvapi-shim/VgpuIdentityQuery.exe"; do
    [[ -s "$asset" && ! -L "$asset" ]] ||
        die "required guest asset is missing or unsafe: $asset"
done
if ((WITH_LICENSE_TOKEN)); then
    [[ -s "$here/guest/install-vgpu-license.ps1" &&
       ! -L "$here/guest/install-vgpu-license.ps1" ]] ||
        die "required private license installer is missing or unsafe"
fi

install -m 0600 -- "$here/guest/apply-gpuz-profile.ps1" \
    "$BUNDLE/apply-gpuz-profile.ps1"
install -m 0600 -- "$here/guest/apply-vm-profile.ps1" \
    "$BUNDLE/apply-vm-profile.ps1"
install -m 0600 -- "$here/guest/patch-grid-strings.ps1" \
    "$BUNDLE/patch-grid-strings.ps1"
install -m 0600 -- "$here/guest/vgpu-profile-catalog.json" \
    "$BUNDLE/vgpu-profile-catalog.json"
install -m 0600 -- "$here/docs/G11-1GB-GPU-EXPANSION.md" \
    "$BUNDLE/G11-1GB-GPU-EXPANSION.md"
install -m 0600 -- "$here/docs/G11-1GB-GPU-EVIDENCE.tsv" \
    "$BUNDLE/G11-1GB-GPU-EVIDENCE.tsv"
install -m 0600 -- "$here/guest/guest-performance/Optimize-Guest.ps1" \
    "$BUNDLE/Optimize-Guest.ps1"
install -m 0600 -- "$here/guest/guest-performance/01-Audit.cmd" \
    "$BUNDLE/01-Audit.cmd"
install -m 0600 -- "$here/guest/guest-performance/02-Apply-Recommended.cmd" \
    "$BUNDLE/02-Apply-Recommended.cmd"
install -m 0600 -- "$here/guest/guest-performance/03-Verify.cmd" \
    "$BUNDLE/03-Verify.cmd"
install -m 0600 -- "$here/guest/guest-performance/04-Rollback.cmd" \
    "$BUNDLE/04-Rollback.cmd"
install -m 0600 -- "$here/guest/guest-performance/README.txt" \
    "$BUNDLE/README.txt"
install -m 0600 -- "$here/guest/nvapi-shim/nvapi.dll" \
    "$BUNDLE/nvapi.dll"
install -m 0600 -- "$here/guest/nvapi-shim/nvapi_profile_probe32.exe" \
    "$BUNDLE/nvapi_profile_probe32.exe"
install -m 0600 -- "$here/guest/nvapi-shim/VgpuIdentityQuery.exe" \
    "$BUNDLE/VgpuIdentityQuery.exe"
CONTRACT_SCHEMA=6
LICENSE_TOKEN_JSON=null
if ((WITH_LICENSE_TOKEN)); then
    install -m 0600 -- "$here/guest/install-vgpu-license.ps1" \
        "$BUNDLE/install-vgpu-license.ps1"
    install -m 0600 -- "$TOKEN_FILE" \
        "$BUNDLE/client_configuration_token.tok"
    [[ "$(stat -c %s -- "$BUNDLE/client_configuration_token.tok")" == \
           "$TOKEN_BYTES" &&
       "$(sha256_upper "$BUNDLE/client_configuration_token.tok")" == \
           "$TOKEN_SHA256" ]] ||
        die "private license token snapshot changed during packaging"
    CONTRACT_SCHEMA=7
    LICENSE_TOKEN_JSON=$(jq -cn \
        --arg name client_configuration_token.tok \
        --arg sha256 "$TOKEN_SHA256" \
        --argjson bytes "$TOKEN_BYTES" \
        '{name:$name,sha256:$sha256,bytes:$bytes,delivery:"embedded-private"}')
fi
profiles_json='[]'
for profile_key in $(vgpu_profile_keys); do
    vgpu_profile_load "$profile_key" ||
        die "could not load catalog profile $profile_key"
    profile_name="profile-${profile_key}.json"
    profile_path="$BUNDLE/$profile_name"
    jq -e \
        --arg profile "$GPU_PROFILE" \
        --arg catalogSha256 "$CATALOG_SHA256" '
        [.profiles[] | select(.profile == $profile)] as $matches |
        if ($matches | length) != 1 then error("ambiguous profile") else
        {
            schemaVersion: 2,
            bindingMode: "portable-auto",
            catalogSha256: $catalogSha256,
            gpu: $matches[0]
        }
        end
    ' "$BUNDLE/vgpu-profile-catalog.json" >"$profile_path" ||
        die "guest catalog does not contain exactly one $GPU_PROFILE row"
    chmod 0600 "$profile_path"
    profile_sha=$(sha256_upper "$profile_path")
    profiles_json=$(jq -c \
        --arg key "$GPU_PROFILE" \
        --arg canonicalDisplayName "$GPU_NAME" \
        --arg boardBrand "$GPU_BOARD_BRAND" \
        --arg boardModel "$GPU_BOARD_MODEL" \
        --arg memoryMakerName "$GPU_MEMORY_MAKER" \
        --arg name "$profile_name" \
        --arg sha256 "$profile_sha" '
        . + [{
            key: $key,
            canonicalDisplayName: $canonicalDisplayName,
            boardBrand: $boardBrand,
            boardModel: $boardModel,
            memoryMakerName: $memoryMakerName,
            asset: {name: $name, sha256: $sha256}
        }]' <<<"$profiles_json")
done

SHIM_SHA256=$(sha256_upper "$BUNDLE/nvapi.dll")
PROBE_SHA256=$(sha256_upper "$BUNDLE/nvapi_profile_probe32.exe")
QUERY_SHA256=$(sha256_upper "$BUNDLE/VgpuIdentityQuery.exe")
CATALOG_ASSET_SHA256=$(sha256_upper "$BUNDLE/vgpu-profile-catalog.json")
CATALOG_ASSET_BYTES=$(stat -c %s -- "$BUNDLE/vgpu-profile-catalog.json")
jq -n \
    --argjson schemaVersion "$CONTRACT_SCHEMA" \
    --arg bindingMode portable-auto \
    --arg spoofMode B \
    --arg catalogSha256 "$CATALOG_SHA256" \
    --arg expectedPnpId 'PCI\VEN_10DE&DEV_1E30' \
    --arg expectedDriverVersion "$PORTABLE_DRIVER_VERSION" \
    --argjson profiles "$profiles_json" \
    --arg catalogName vgpu-profile-catalog.json \
    --arg catalogAssetSha256 "$CATALOG_ASSET_SHA256" \
    --argjson catalogAssetBytes "$CATALOG_ASSET_BYTES" \
    --arg gpuzName "$GPUZ_ASSET_BUNDLE_NAME" \
    --argjson gpuzBytes "$GPUZ_ASSET_BYTES" \
    --arg gpuzVersion "$GPUZ_ASSET_PRODUCT_VERSION" \
    --arg gpuzSha256 "$GPUZ_ASSET_SHA256" \
    --arg shimSha256 "$SHIM_SHA256" \
    --arg probeSha256 "$PROBE_SHA256" \
    --arg querySha256 "$QUERY_SHA256" \
    --argjson licenseToken "$LICENSE_TOKEN_JSON" '
    ({
        schemaVersion: $schemaVersion,
        bindingMode: $bindingMode,
        spoofMode: $spoofMode,
        catalogSha256: $catalogSha256,
        expectedPnpId: $expectedPnpId,
        expectedDriverVersion: $expectedDriverVersion,
        catalog: {
            name: $catalogName,
            sha256: $catalogAssetSha256,
            bytes: $catalogAssetBytes
        },
        profiles: $profiles,
        gpuz: {
            name: $gpuzName,
            bytes: $gpuzBytes,
            productVersion: $gpuzVersion,
            sha256: $gpuzSha256,
            delivery: "optional-explicit-sibling"
        },
        appLocal: {
            shimName: "nvapi.dll",
            shimSha256: $shimSha256,
            probeName: "nvapi_profile_probe32.exe",
            probeSha256: $probeSha256,
            queryName: "VgpuIdentityQuery.exe",
            querySha256: $querySha256
        }
    } + if $licenseToken == null then {} else {
        licenseToken: $licenseToken
    } end)' >"$BUNDLE/gpuz-contract.json"
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
    --argjson schemaVersion 4 \
    --arg bindingMode portable-auto \
    --argjson files "$files_json" \
    --arg gpuzName "$GPUZ_ASSET_BUNDLE_NAME" \
    --arg gpuzSha256 "$GPUZ_ASSET_SHA256" \
    --argjson gpuzBytes "$GPUZ_ASSET_BYTES" '
    {
        schemaVersion: $schemaVersion,
        bindingMode: $bindingMode,
        files: $files,
        optionalExternalFiles: [{
            name: $gpuzName,
            sha256: $gpuzSha256,
            bytes: $gpuzBytes
        }]
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
RECEIPT_SCHEMA=7
LAUNCHER_FORMAT=QEMU_VGPU_PORTABLE_BRANCH_V7
if ((WITH_LICENSE_TOKEN)); then
    RECEIPT_SCHEMA=8
    LAUNCHER_FORMAT=QEMU_VGPU_PORTABLE_LICENSED_BRANCH_V8
fi
jq -n \
    --argjson schemaVersion "$RECEIPT_SCHEMA" \
    --arg bindingMode portable-auto \
    --arg catalogSha256 "$CATALOG_SHA256" \
    --arg gpuZDelivery optional-explicit-sibling \
    --arg guestPerformance embedded-recommended-native-v1 \
    --arg launcherFormat "$LAUNCHER_FORMAT" \
    --arg driverBranch "$PORTABLE_DRIVER_BRANCH" \
    --arg driverVersion "$PORTABLE_DRIVER_VERSION" \
    --arg exeSha256 "$EXE_SHA256" \
    --argjson exeBytes "$EXE_BYTES" \
    --arg bundleManifestSha256 "$MANIFEST_SHA256" \
    --argjson withLicenseToken "$WITH_LICENSE_TOKEN" \
    --arg tokenSha256 "$TOKEN_SHA256" \
    --argjson tokenBytes "$TOKEN_BYTES" '
    ({
        schemaVersion: $schemaVersion,
        bindingMode: $bindingMode,
        catalogSha256: $catalogSha256,
        gpuZDelivery: $gpuZDelivery,
        guestPerformance: $guestPerformance,
        launcherFormat: $launcherFormat,
        driverBranch: $driverBranch,
        driverVersion: $driverVersion,
        exeSha256: $exeSha256,
        exeBytes: $exeBytes,
        bundleManifestSha256: $bundleManifestSha256
    } + if $withLicenseToken == 1 then {
        licenseTokenDelivery: "embedded-private",
        licenseTokenSha256: $tokenSha256,
        licenseTokenBytes: $tokenBytes
    } else {} end)' >"$RECEIPT_TEMP"
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

if ((EXISTING_EXE && !REPLACE_EXISTING)); then
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
  driver:      ${PORTABLE_DRIVER_BRANCH} / ${PORTABLE_DRIVER_LABEL} / ${PORTABLE_DRIVER_VERSION}
  launcher:    $(if ((WITH_LICENSE_TOKEN)); then printf '%s' '1.7.0.0 / private identity + DLS + guest performance'; else printf '%s' '1.6.0.0 / identity + guest performance'; fi)
  bundle:      ${OUTPUT_DIR}
  single EXE:  ${OUTPUT_EXE}
  EXE bytes:   ${EXE_BYTES}
  EXE sha256:  ${EXE_SHA256}
$(if [[ -n "$REPLACED_BACKUP" ]]; then printf '  old %s backup: %s\n' "$REPLACEMENT_KIND" "$REPLACED_BACKUP"; fi)

$(if ((WITH_LICENSE_TOKEN)); then
    cat <<PRIVATE
这是显式构建的私有授权版通用 guest 文件。它包含 DLS token；不要公开分发。
在任意受支持 B/native VM 中直接双击 VgpuPortable.exe，会统一安装身份、token，
等待 NVIDIA 明确报告 Licensed，关闭休眠/Fast Startup，并应用推荐的登录启动和
native-display 性能优化。完成后让 Windows 完整关机，再正常冷启动复验。
PRIVATE
else
    cat <<PUBLIC
这是默认不安装、也不要求 GPU-Z 的通用 guest 文件。直接双击
VgpuPortable.exe 即可安装并查询显卡/板卡/显存身份，同时应用推荐的登录启动和
native-display 性能优化。
PUBLIC
fi)

以后确实需要 GPU-Z 时，把官网取得且严格匹配 TechPowerUp GPU-Z 2.70 的
GPU-Z.exe 放在同目录，再执行：VgpuPortable.exe /with-gpuz
选装路径会校验 11642144 bytes / ${GPUZ_ASSET_SHA256}；不匹配就在任何
profile 写入前失败。无需为任意 VM ID 或不同品牌分别重新打包。
EOF
