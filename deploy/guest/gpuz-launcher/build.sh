#!/usr/bin/env bash
# Validate one GPU-Z directory bundle and compile it into one native Win64 EXE.
set -euo pipefail
export LC_ALL=C
umask 077

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/gpuz-assets.sh
source "$here/../../lib/gpuz-assets.sh"

usage() {
    cat >&2 <<'EOF'
usage: build.sh --bundle-dir DIR --output FILE.exe

The builder embeds every READY/manifest-owned file as an individually
size/SHA-256-pinned PE RCDATA resource.  It accepts both the historical
VM-bound schema and the portable-auto catalog schema.
EOF
}

die() {
    echo "[gpuz-single-exe] ERROR: $*" >&2
    exit 1
}

sha256_upper() {
    sha256sum -- "$1" | awk '{print toupper($1)}'
}

is_reserved_windows_name() {
    local lower=${1,,}
    local stem=${lower%%.*}
    case "$stem" in
        con|prn|aux|nul|com[1-9]|lpt[1-9]) return 0 ;;
        *) return 1 ;;
    esac
}

BUNDLE_DIR=""
OUTPUT=""
while (($#)); do
    case "$1" in
        --bundle-dir)
            (($# >= 2)) || die "--bundle-dir requires a path"
            BUNDLE_DIR=$2
            shift 2
            ;;
        --output)
            (($# >= 2)) || die "--output requires a path"
            OUTPUT=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

[[ -n "$BUNDLE_DIR" && -n "$OUTPUT" ]] || {
    usage
    exit 2
}
for dependency in \
        jq sha256sum awk stat find realpath mktemp install cp cmp \
        x86_64-w64-mingw32-gcc x86_64-w64-mingw32-windres; do
    command -v "$dependency" >/dev/null 2>&1 \
        || die "missing build dependency: $dependency"
done

BUNDLE_SOURCE=$(realpath -e -- "$BUNDLE_DIR") \
    || die "bundle directory does not exist"
[[ -d "$BUNDLE_SOURCE" && ! -L "$BUNDLE_SOURCE" ]] \
    || die "--bundle-dir must be a regular directory"
exec {BUNDLE_SOURCE_FD}<"$BUNDLE_SOURCE" \
    || die "could not pin the input bundle directory"
BUNDLE_FD_PATH="/proc/self/fd/$BUNDLE_SOURCE_FD"
[[ -d "$BUNDLE_FD_PATH" ]] \
    || die "the pinned input bundle descriptor is unavailable"
[[ "$OUTPUT" == /* && "${OUTPUT,,}" == *.exe ]] \
    || die "--output must be an absolute .exe path"
[[ ! -L "$OUTPUT" ]] || die "--output must not be a symlink"
OUTPUT=$(realpath -m -- "$OUTPUT")
case "$OUTPUT" in
    "$BUNDLE_SOURCE"|"$BUNDLE_SOURCE"/*)
        die "--output must not be inside the bundle directory"
        ;;
esac
OUTPUT_PARENT=$(dirname -- "$OUTPUT")
mkdir -p -- "$OUTPUT_PARENT"
OUTPUT_PARENT=$(realpath -e -- "$OUTPUT_PARENT") \
    || die "could not resolve output parent"
[[ -d "$OUTPUT_PARENT" && ! -L "$OUTPUT_PARENT" ]] \
    || die "output parent must be a regular directory"
if [[ -e "$OUTPUT" ]]; then
    [[ -f "$OUTPUT" && ! -L "$OUTPUT" ]] \
        || die "existing output is not a regular file"
fi

tmp=$(mktemp -d "$OUTPUT_PARENT/.gpuz-single-exe.XXXXXXXX")
cleanup() {
    rm -rf -- "$tmp"
}
trap cleanup EXIT

# Snapshot first, then validate and embed only the private snapshot.  This
# avoids validating one source generation and later recomputing trusted
# resource hashes from a different generation of a mutable public directory.
SNAPSHOT="$tmp/input"
mkdir -m 0700 -- "$SNAPSHOT"
cp -a -- "$BUNDLE_FD_PATH/." "$SNAPSHOT/"
BUNDLE_DIR="$SNAPSHOT"

READY="$BUNDLE_DIR/READY"
MANIFEST="$BUNDLE_DIR/bundle-manifest.json"
CONTRACT="$BUNDLE_DIR/gpuz-contract.json"
for required in "$READY" "$MANIFEST" "$CONTRACT"; do
    [[ -f "$required" && ! -L "$required" ]] \
        || die "required bundle file is missing or unsafe: $required"
done
mapfile -t ready_lines <"$READY"
[[ ${#ready_lines[@]} -eq 2 &&
   "${ready_lines[0]}" == schema_version=1 &&
   "${ready_lines[1]}" =~ ^manifest_sha256=([0-9A-F]{64})$ ]] \
    || die "READY is malformed"
EXPECTED_MANIFEST_SHA=${BASH_REMATCH[1]}
[[ "$(sha256_upper "$MANIFEST")" == "$EXPECTED_MANIFEST_SHA" ]] \
    || die "READY does not authenticate bundle-manifest.json"

MANIFEST_SCHEMA=$(jq -er '.schemaVersion' "$MANIFEST") ||
    die "manifest schemaVersion is missing"
BINDING_MODE=""
VM_LABEL=""
case "$MANIFEST_SCHEMA" in
    1)
        jq -e '
            (keys | sort) == ["files", "schemaVersion", "vmId"] and
            .schemaVersion == 1 and
            (.vmId | type) == "number" and (.vmId | floor) == .vmId and
            .vmId >= 1 and .vmId <= 2147483647 and
            (.files | type) == "array" and
            (.files | length) >= 9 and (.files | length) <= 32 and
            all(.files[];
                type == "object" and
                (keys | sort) == ["bytes", "name", "sha256"] and
                (.name | type) == "string" and
                (.sha256 | type) == "string" and
                (.bytes | type) == "number" and
                (.bytes | floor) == .bytes
            )
        ' "$MANIFEST" >/dev/null ||
            die "unsupported VM-bound bundle manifest schema"
        VM_ID=$(jq -er '.vmId' "$MANIFEST")
        VM_LABEL="vm${VM_ID}"
        ;;
    2)
        jq -e '
            (keys | sort) == ["bindingMode", "files", "schemaVersion"] and
            .schemaVersion == 2 and .bindingMode == "portable-auto" and
            (.files | type) == "array" and
            (.files | length) >= 11 and (.files | length) <= 32 and
            all(.files[];
                type == "object" and
                (keys | sort) == ["bytes", "name", "sha256"] and
                (.name | type) == "string" and
                (.sha256 | type) == "string" and
                (.bytes | type) == "number" and
                (.bytes | floor) == .bytes
            )
        ' "$MANIFEST" >/dev/null ||
            die "unsupported portable bundle manifest schema"
        BINDING_MODE=portable-auto
        VM_LABEL=portable-auto
        ;;
    *)
        die "unsupported bundle manifest schema"
        ;;
esac

declare -a CONTRACT_PROFILE_NAMES=()
declare -a CONTRACT_PROFILE_SHAS=()
if [[ "$BINDING_MODE" == portable-auto ]]; then
    jq -e \
        --arg gpuzName "$GPUZ_ASSET_BUNDLE_NAME" \
        --argjson gpuzBytes "$GPUZ_ASSET_BYTES" \
        --arg gpuzVersion "$GPUZ_ASSET_PRODUCT_VERSION" \
        --arg gpuzHash "$GPUZ_ASSET_SHA256" '
        (keys | sort) == [
            "appLocal", "bindingMode", "catalogSha256",
            "expectedDriverVersion", "expectedPnpId", "gpuz", "profiles",
            "schemaVersion", "spoofMode"
        ] and
        .schemaVersion == 3 and .bindingMode == "portable-auto" and
        .spoofMode == "B" and
        (.catalogSha256 | test("^[0-9A-F]{64}$")) and
        .expectedPnpId == "PCI\\VEN_10DE&DEV_1E30" and
        .expectedDriverVersion == "31.0.15.3833" and
        (.profiles | type) == "array" and (.profiles | length) == 3 and
        [.profiles[] | .key] ==
            ["gtx750ti_2gb", "gt1030_2gb", "gtx1050_2gb"] and
        [.profiles[] | .canonicalDisplayName] == [
            "NVIDIA GeForce GTX 750 Ti",
            "NVIDIA GeForce GT 1030",
            "NVIDIA GeForce GTX 1050"
        ] and
        ([.profiles[] | .key] | unique | length) == 3 and
        ([.profiles[] | .canonicalDisplayName] | unique | length) == 3 and
        ([.profiles[] | .asset.name | ascii_downcase] | unique | length) == 3 and
        all(.profiles[];
            (keys | sort) == ["asset", "canonicalDisplayName", "key"] and
            (.asset | keys | sort) == ["name", "sha256"] and
            (.asset.name | test("^profile-[a-z0-9_]+[.]json$")) and
            (.asset.sha256 | test("^[0-9A-F]{64}$"))
        ) and
        (.gpuz | keys | sort) == ["bytes", "name", "productVersion", "sha256"] and
        .gpuz.name == $gpuzName and .gpuz.bytes == $gpuzBytes and
        .gpuz.productVersion == $gpuzVersion and .gpuz.sha256 == $gpuzHash and
        (.appLocal | keys | sort) ==
            ["probeName", "probeSha256", "shimName", "shimSha256"] and
        (.appLocal.shimName | test("^[A-Za-z0-9][A-Za-z0-9._-]*$")) and
        (.appLocal.probeName | test("^[A-Za-z0-9][A-Za-z0-9._-]*$")) and
        (.appLocal.shimSha256 | test("^[0-9A-F]{64}$")) and
        (.appLocal.probeSha256 | test("^[0-9A-F]{64}$"))
    ' "$CONTRACT" >/dev/null ||
        die "portable contract does not match the audited catalog schema"
    mapfile -t CONTRACT_PROFILE_NAMES < <(
        jq -er '.profiles[].asset.name' "$CONTRACT"
    )
    mapfile -t CONTRACT_PROFILE_SHAS < <(
        jq -er '.profiles[].asset.sha256' "$CONTRACT"
    )
else
    jq -e \
        --argjson vmId "$VM_ID" \
        --arg gpuzName "$GPUZ_ASSET_BUNDLE_NAME" \
        --argjson gpuzBytes "$GPUZ_ASSET_BYTES" \
        --arg gpuzVersion "$GPUZ_ASSET_PRODUCT_VERSION" \
        --arg gpuzHash "$GPUZ_ASSET_SHA256" '
        (keys | sort) == [
            "appLocal", "expectedDriverVersion", "expectedPnpId", "gpuProfile", "gpuz",
            "profile", "schemaVersion", "spoofMode", "vmId", "vmUuid"
        ] and
        .schemaVersion == 2 and .vmId == $vmId and
        (.vmUuid | type) == "string" and
        (.vmUuid | test("^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$")) and
        (.spoofMode == "A" or .spoofMode == "B") and
        (.gpuProfile | type) == "string" and
        (.gpuProfile | test("^[a-z0-9][a-z0-9_]*$")) and
        (.expectedPnpId | type) == "string" and
        (.expectedDriverVersion | type) == "string" and
        (.gpuz | keys | sort) == ["bytes", "name", "productVersion", "sha256"] and
        .gpuz.name == $gpuzName and
        .gpuz.bytes == $gpuzBytes and
        .gpuz.productVersion == $gpuzVersion and
        .gpuz.sha256 == $gpuzHash and
        (.profile | keys | sort) == ["name", "sha256"] and
        (.profile.name | test("^[A-Za-z0-9][A-Za-z0-9._-]*$")) and
        (.profile.sha256 | test("^[0-9A-F]{64}$")) and
        (.appLocal | keys | sort) ==
            ["probeName", "probeSha256", "shimName", "shimSha256"] and
        (.appLocal.shimName | test("^[A-Za-z0-9][A-Za-z0-9._-]*$")) and
        (.appLocal.probeName | test("^[A-Za-z0-9][A-Za-z0-9._-]*$")) and
        (.appLocal.shimSha256 | test("^[0-9A-F]{64}$")) and
        (.appLocal.probeSha256 | test("^[0-9A-F]{64}$"))
    ' "$CONTRACT" >/dev/null ||
        die "contract does not match the manifest VM"
    CONTRACT_PROFILE_NAMES+=("$(jq -er '.profile.name' "$CONTRACT")")
    CONTRACT_PROFILE_SHAS+=("$(jq -er '.profile.sha256' "$CONTRACT")")
fi

CONTRACT_SHIM_NAME=$(jq -er '.appLocal.shimName' "$CONTRACT")
CONTRACT_SHIM_SHA=$(jq -er '.appLocal.shimSha256' "$CONTRACT")
CONTRACT_PROBE_NAME=$(jq -er '.appLocal.probeName' "$CONTRACT")
CONTRACT_PROBE_SHA=$(jq -er '.appLocal.probeSha256' "$CONTRACT")
CONTRACT_GPUZ_NAME=$(jq -er '.gpuz.name' "$CONTRACT")
CONTRACT_GPUZ_BYTES=$(jq -er '.gpuz.bytes' "$CONTRACT")
CONTRACT_GPUZ_SHA=$(jq -er '.gpuz.sha256' "$CONTRACT")

declare -a payload_names=(READY bundle-manifest.json)
declare -A seen_casefold=(
    [ready]=1
    [bundle-manifest.json]=1
)
total_bytes=$(($(stat -c %s -- "$READY") + $(stat -c %s -- "$MANIFEST")))
MANIFEST_TSV="$tmp/manifest-files.tsv"
jq -er '.files[] | [.name, .sha256, .bytes] | @tsv' "$MANIFEST" \
    >"$MANIFEST_TSV" \
    || die "manifest file entries could not be decoded"
while IFS=$'\t' read -r name expected_hash expected_bytes; do
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ &&
       "$name" != *..* &&
       "$expected_hash" =~ ^[0-9A-F]{64}$ &&
       "$expected_bytes" =~ ^[1-9][0-9]*$ ]] \
        || die "manifest contains an unsafe file entry"
    is_reserved_windows_name "$name" &&
        die "manifest uses a reserved Windows file name: $name"
    folded=${name,,}
    [[ -z "${seen_casefold[$folded]+x}" ]] \
        || die "manifest contains a duplicate/case-colliding name: $name"
    seen_casefold["$folded"]=1
    file="$BUNDLE_DIR/$name"
    [[ -f "$file" && ! -L "$file" ]] \
        || die "manifest file is missing or unsafe: $name"
    [[ "$(stat -c %s -- "$file")" == "$expected_bytes" &&
       "$(sha256_upper "$file")" == "$expected_hash" ]] \
        || die "manifest file size/hash mismatch: $name"
    ((expected_bytes <= 67108864)) \
        || die "one payload exceeds the 64 MiB resource limit: $name"
    total_bytes=$((total_bytes + expected_bytes))
    ((total_bytes <= 134217728)) \
        || die "combined payload exceeds the 128 MiB limit"
    payload_names+=("$name")
done <"$MANIFEST_TSV"

for required_name in \
        apply-vm-profile.ps1 patch-grid-strings.ps1 \
        apply-gpuz-profile.ps1 gpuz-contract.json \
        nvapi.dll nvapi_profile_probe32.exe RUN-GPUZ-PROFILE.cmd \
        "${CONTRACT_PROFILE_NAMES[@]}" \
        "$CONTRACT_SHIM_NAME" "$CONTRACT_PROBE_NAME" \
        "$CONTRACT_GPUZ_NAME"; do
    [[ -n "${seen_casefold[${required_name,,}]+x}" ]] \
        || die "manifest omits required GPU-Z asset: $required_name"
done
for profile_index in "${!CONTRACT_PROFILE_NAMES[@]}"; do
    [[ "$(sha256_upper \
            "$BUNDLE_DIR/${CONTRACT_PROFILE_NAMES[$profile_index]}")" == \
       "${CONTRACT_PROFILE_SHAS[$profile_index]}" ]] ||
        die "contract profile hash does not match the private snapshot"
done
[[ "$(sha256_upper "$BUNDLE_DIR/$CONTRACT_SHIM_NAME")" == \
       "$CONTRACT_SHIM_SHA" &&
   "$(sha256_upper "$BUNDLE_DIR/$CONTRACT_PROBE_NAME")" == \
       "$CONTRACT_PROBE_SHA" &&
   "$(stat -c %s -- "$BUNDLE_DIR/$CONTRACT_GPUZ_NAME")" == \
       "$CONTRACT_GPUZ_BYTES" &&
   "$(sha256_upper "$BUNDLE_DIR/$CONTRACT_GPUZ_NAME")" == \
       "$CONTRACT_GPUZ_SHA" ]] \
    || die "contract asset hashes do not match the private snapshot"
jq -e \
    --arg name "$CONTRACT_GPUZ_NAME" \
    --arg sha256 "$CONTRACT_GPUZ_SHA" \
    --argjson bytes "$CONTRACT_GPUZ_BYTES" '
    [.files[] | select(.name == $name)] ==
        [{name: $name, sha256: $sha256, bytes: $bytes}]
' "$MANIFEST" >/dev/null \
    || die "manifest does not exactly own the contract GPU-Z name/hash/bytes"
expected_root_count=${#payload_names[@]}
actual_root_count=$(find "$BUNDLE_DIR" -mindepth 1 -maxdepth 1 -printf x | wc -c)
[[ "$actual_root_count" -eq "$expected_root_count" ]] \
    || die "bundle root contains an unmanifested entry"
if find "$BUNDLE_DIR" -mindepth 1 -maxdepth 1 ! -type f -print -quit |
        grep -q .; then
    die "bundle root contains a non-file entry"
fi

install -m 0600 -- "$here/gpuz_profile_launcher.c" \
    "$tmp/gpuz_profile_launcher.c"
install -m 0600 -- "$here/gpuz_profile_launcher.manifest" \
    "$tmp/gpuz_profile_launcher.manifest"

metadata="$tmp/payload_metadata.h"
resource_file="$tmp/gpuz_profile_launcher.rc"
{
    printf '#ifndef QEMU_GPUZ_PAYLOAD_METADATA_H\n'
    printf '#define QEMU_GPUZ_PAYLOAD_METADATA_H\n'
    printf '#define PAYLOAD_COUNT %uu\n' "${#payload_names[@]}"
    printf 'static const PayloadEntry PAYLOAD_ENTRIES[PAYLOAD_COUNT] = {\n'
} >"$metadata"
{
    printf '#include <windows.h>\n'
    printf '1 RT_MANIFEST "gpuz_profile_launcher.manifest"\n'
} >"$resource_file"

resource_id=201
payload_index=0
for name in "${payload_names[@]}"; do
    source_file="$BUNDLE_DIR/$name"
    resource_name=$(printf 'payload-%03u.bin' "$payload_index")
    install -m 0600 -- "$source_file" "$tmp/$resource_name"
    payload_hash=$(sha256_upper "$source_file")
    payload_bytes=$(stat -c %s -- "$source_file")
    hash_initializer=$(sed -E 's/(..)/0x\1,/g' <<<"$payload_hash")
    printf '    {%uu, L"%s", %uu, {%s}},\n' \
        "$resource_id" "$name" "$payload_bytes" "$hash_initializer" \
        >>"$metadata"
    printf '%u RCDATA "%s"\n' "$resource_id" "$resource_name" \
        >>"$resource_file"
    resource_id=$((resource_id + 1))
    payload_index=$((payload_index + 1))
done
{
    printf '};\n'
    printf '#endif\n'
} >>"$metadata"
cat >>"$resource_file" <<'EOF'
1 VERSIONINFO
 FILEVERSION 1,1,0,0
 PRODUCTVERSION 1,1,0,0
 FILEFLAGSMASK 0x3fL
 FILEFLAGS 0x0L
 FILEOS 0x40004L
 FILETYPE 0x1L
 FILESUBTYPE 0x0L
BEGIN
    BLOCK "StringFileInfo"
    BEGIN
        BLOCK "040904b0"
        BEGIN
            VALUE "CompanyName", "Local QEMU vGPU tools\0"
            VALUE "FileDescription", "Single-file GPU-Z profile installer\0"
            VALUE "FileVersion", "1.1.0.0\0"
            VALUE "InternalName", "GpuZProfileInstaller\0"
            VALUE "OriginalFilename", "GpuZProfileInstaller.exe\0"
            VALUE "ProductName", "QEMU GPU-Z profile installer\0"
            VALUE "ProductVersion", "1.1.0.0\0"
            VALUE "SpecialBuild", "QEMU_GPUZ_SINGLE_EXE_V1\0"
        END
    END
    BLOCK "VarFileInfo"
    BEGIN
        VALUE "Translation", 0x0409, 1200
    END
END
EOF

(
    cd "$tmp"
    x86_64-w64-mingw32-windres --use-temp-file \
        -i gpuz_profile_launcher.rc -o gpuz_profile_launcher_res.o
    x86_64-w64-mingw32-gcc \
        -std=c11 -O2 -Wall -Wextra -Werror -static -s -municode \
        -Wl,--no-insert-timestamp \
        -o GpuZProfileInstaller.exe \
        gpuz_profile_launcher.c gpuz_profile_launcher_res.o \
        -ladvapi32 -lbcrypt -lshell32 -luser32
)

chmod 0600 "$tmp/GpuZProfileInstaller.exe"
if [[ -e "$OUTPUT" ]]; then
    if cmp -s -- "$tmp/GpuZProfileInstaller.exe" "$OUTPUT"; then
        echo "[gpuz-single-exe] existing identical output reused: $OUTPUT"
        exit 0
    fi
    die "refusing to replace a different existing EXE: $OUTPUT"
fi
# The temporary build is in OUTPUT_PARENT, so a hard link is an atomic,
# no-replace publication on the same filesystem. Recheck a concurrent winner
# instead of letting mv overwrite it between the earlier existence test and
# publication.
if ! ln -T -- "$tmp/GpuZProfileInstaller.exe" "$OUTPUT"; then
    if [[ -f "$OUTPUT" && ! -L "$OUTPUT" ]] &&
       cmp -s -- "$tmp/GpuZProfileInstaller.exe" "$OUTPUT"; then
        echo "[gpuz-single-exe] concurrent identical output reused: $OUTPUT"
        exit 0
    fi
    die "could not atomically publish EXE without replacing data: $OUTPUT"
fi
echo "[gpuz-single-exe] PASS"
echo "  binding:  ${VM_LABEL}"
echo "  payloads: ${#payload_names[@]} / ${total_bytes} bytes"
echo "  output:   $OUTPUT"
echo "  sha256:   $(sha256_upper "$OUTPUT")"
