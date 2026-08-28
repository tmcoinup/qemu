#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
packager="$root/deploy/package-vgpu-portable.sh"
dispatcher="$root/deploy/package-vgpu-one-click.sh"
builder="$root/deploy/guest/gpuz-launcher/build.sh"
launcher="$root/deploy/guest/gpuz-launcher/gpuz_profile_launcher.c"
guest="$root/deploy/guest/apply-gpuz-profile.ps1"
profile_writer="$root/deploy/guest/apply-vm-profile.ps1"
start="$root/deploy/scripts/start-vm.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

for memory_mapper in "$guest" "$profile_writer"; do
    rg -Fq "3 { @('Elpida', 'Elpida') }" "$memory_mapper" ||
        fail "Elpida(3) is present in the catalog but missing from ${memory_mapper#$root/}"
done

tmp=$(mktemp -d)
cleanup() {
    rm -rf -- "$tmp"
}
trap cleanup EXIT
mkdir -m 0700 -- "$tmp/out" "$tmp/empty-image-root"

IMAGE_ROOT="$tmp/empty-image-root" "$packager" \
    --output-dir "$tmp/out/.host-bundle" \
    --output-exe "$tmp/out/VgpuPortable.exe" >/dev/null

contract="$tmp/out/.host-bundle/gpuz-contract.json"
manifest="$tmp/out/.host-bundle/bundle-manifest.json"
[[ -s "$tmp/out/VgpuPortable.exe" && -s "$contract" && -s "$manifest" ]] ||
    fail "portable packager did not publish complete outputs"

jq -e '
    (keys | sort) == [
        "appLocal", "bindingMode", "catalog", "catalogSha256",
        "expectedDriverVersion", "expectedPnpId", "gpuz", "profiles",
        "schemaVersion", "spoofMode"
    ] and
    .schemaVersion == 6 and .bindingMode == "portable-auto" and
    .spoofMode == "B" and
    .expectedPnpId == "PCI\\VEN_10DE&DEV_1E30" and
    .expectedDriverVersion == "31.0.15.3833" and
    (.profiles | length) == 25 and
    ([.profiles[].key] | unique | length) == 25 and
    ([.profiles[].asset.name] | unique | length) == 25 and
    ([.profiles[].boardBrand] | unique | sort) ==
        ["ASUS", "Colorful", "Dell", "EVGA", "GALAX", "Gigabyte", "MSI", "NVIDIA", "ZOTAC"] and
    ([.profiles[].memoryMakerName] | unique | sort) ==
        ["Elpida", "Micron", "SK hynix", "Samsung"] and
    .catalog.name == "vgpu-profile-catalog.json" and
    (.catalog.sha256 | test("^[0-9A-F]{64}$")) and
    .appLocal.queryName == "VgpuIdentityQuery.exe" and
    (.appLocal.querySha256 | test("^[0-9A-F]{64}$")) and
    (.gpuz.delivery == "optional-explicit-sibling") and
    (.gpuz.name == "GPU-Z.exe") and
    (.gpuz.bytes == 11642144) and
    (.gpuz.productVersion == "2.70.0") and
    (.gpuz.sha256 ==
        "6CB0EF29682452DE81A9576808881685161411A1FAD00938BA04131159979C29")
' "$contract" >/dev/null ||
    fail "portable contract does not contain the exact audited catalog"

jq -e '
    (keys | sort) == [
        "bindingMode", "files", "optionalExternalFiles", "schemaVersion"
    ] and
    .schemaVersion == 4 and .bindingMode == "portable-auto" and
    ([.files[].name | select(startswith("profile-"))] | length) == 25 and
    ([.files[].name] | index("vgpu-profile-catalog.json")) != null and
    ([.files[].name] | index("G11-1GB-GPU-EXPANSION.md")) != null and
    ([.files[].name] | index("G11-1GB-GPU-EVIDENCE.tsv")) != null and
    ([.files[].name] | index("VgpuIdentityQuery.exe")) != null and
    ([.files[].name] | index("Optimize-Guest.ps1")) != null and
    ([.files[].name] | index("01-Audit.cmd")) != null and
    ([.files[].name] | index("02-Apply-Recommended.cmd")) != null and
    ([.files[].name] | index("03-Verify.cmd")) != null and
    ([.files[].name] | index("04-Rollback.cmd")) != null and
    ([.files[].name] | index("README.txt")) != null and
    ([.files[].name] | index("client_configuration_token.tok")) == null and
    ([.files[].name] | index("install-vgpu-license.ps1")) == null and
    ([.files[].name] | index("GPU-Z.exe")) == null and
    .optionalExternalFiles == [{
        name: "GPU-Z.exe",
        sha256: "6CB0EF29682452DE81A9576808881685161411A1FAD00938BA04131159979C29",
        bytes: 11642144
    }]
' "$manifest" >/dev/null ||
    fail "portable manifest schema is incorrect"
[[ ! -e "$tmp/out/.host-bundle/GPU-Z.exe" &&
   "$(stat -c %s -- "$tmp/out/VgpuPortable.exe")" -lt 11642144 ]] ||
    fail "portable output still contains the GPU-Z payload"

if rg -n '"vm(Id|Uuid)"|vm[0-9]+' \
        "$contract" "$manifest" "$tmp/out/.host-bundle"/profile-*.json; then
    fail "portable guest contract/profile still embeds a VM ID or UUID"
fi

while IFS=$'\t' read -r name hash; do
    [[ "$(sha256sum "$tmp/out/.host-bundle/$name" |
        awk '{print toupper($1)}')" == "$hash" ]] ||
        fail "portable profile hash mismatch: $name"
done < <(jq -r '.profiles[] | [.asset.name,.asset.sha256] | @tsv' "$contract")

receipt_dir="$tmp/out/.VgpuPortable.exe.receipts"
exe_hash=$(sha256sum "$tmp/out/VgpuPortable.exe" |
    awk '{print toupper($1)}')
jq -e --arg hash "$exe_hash" '
    .schemaVersion == 6 and .bindingMode == "portable-auto" and
    .gpuZDelivery == "optional-explicit-sibling" and
    .guestPerformance == "embedded-recommended-native-v1" and
    .launcherFormat == "QEMU_VGPU_PORTABLE_UNIFIED_V6" and
    .exeSha256 == $hash
' "$receipt_dir/$exe_hash.json" >/dev/null ||
    fail "portable host receipt is missing or malformed"

# Rebuild is an authenticated update, not a different VM-specific namespace.
IMAGE_ROOT="$tmp/empty-image-root" "$packager" \
    --output-dir "$tmp/out/.host-bundle" \
    --output-exe "$tmp/out/VgpuPortable.exe" >/dev/null

# The explicit private build keeps the same all-profile identity catalog but
# adds one manifest-bound token and the reviewed atomic license installer.
licensed_token="$tmp/client_configuration_token.tok"
install -m 0600 -- "$root/deploy/guest/install-vgpu-license.ps1" \
    "$licensed_token"
mkdir -m 0700 -- "$tmp/licensed"
IMAGE_ROOT="$tmp/empty-image-root" "$packager" \
    --token-file "$licensed_token" \
    --output-dir "$tmp/licensed/.host-bundle" \
    --output-exe "$tmp/licensed/VgpuPortable.exe" >/dev/null
licensed_contract="$tmp/licensed/.host-bundle/gpuz-contract.json"
licensed_manifest="$tmp/licensed/.host-bundle/bundle-manifest.json"
cmp -s -- "$guest" "$tmp/licensed/.host-bundle/apply-gpuz-profile.ps1" ||
    fail "private portable did not embed apply-gpuz-profile.ps1 from the current checkout"
token_hash=$(sha256sum "$licensed_token" | awk '{print toupper($1)}')
token_bytes=$(stat -c %s -- "$licensed_token")
jq -e --arg tokenHash "$token_hash" --argjson tokenBytes "$token_bytes" '
    (keys | sort) == [
        "appLocal", "bindingMode", "catalog", "catalogSha256",
        "expectedDriverVersion", "expectedPnpId", "gpuz", "licenseToken",
        "profiles", "schemaVersion", "spoofMode"
    ] and
    .schemaVersion == 7 and .bindingMode == "portable-auto" and
    (.profiles | length) == 25 and
    .licenseToken == {
        name: "client_configuration_token.tok",
        sha256: $tokenHash,
        bytes: $tokenBytes,
        delivery: "embedded-private"
    }
' "$licensed_contract" >/dev/null ||
    fail "private portable contract does not exactly bind the token"
jq -e --arg tokenHash "$token_hash" --argjson tokenBytes "$token_bytes" '
    .schemaVersion == 4 and
    [.files[] | select(.name == "client_configuration_token.tok")] == [{
        name: "client_configuration_token.tok",
        sha256: $tokenHash,
        bytes: $tokenBytes
    }] and
    ([.files[].name] | index("install-vgpu-license.ps1")) != null and
    ([.files[].name] | index("Optimize-Guest.ps1")) != null and
    ([.files[].name | select(startswith("profile-"))] | length) == 25
' "$licensed_manifest" >/dev/null ||
    fail "private portable manifest is missing its finalizer assets"
cmp -s -- "$licensed_token" \
    "$tmp/licensed/.host-bundle/client_configuration_token.tok" ||
    fail "private portable token snapshot changed"
[[ "$(stat -c %a -- "$tmp/licensed/VgpuPortable.exe")" == 600 ]] ||
    fail "private portable EXE is not host-private"
licensed_exe_hash=$(sha256sum "$tmp/licensed/VgpuPortable.exe" |
    awk '{print toupper($1)}')
jq -e --arg hash "$licensed_exe_hash" --arg tokenHash "$token_hash" \
    --argjson tokenBytes "$token_bytes" '
    .schemaVersion == 7 and
    .guestPerformance == "embedded-recommended-native-v1" and
    .launcherFormat == "QEMU_VGPU_PORTABLE_LICENSED_UNIFIED_V7" and
    .licenseTokenDelivery == "embedded-private" and
    .licenseTokenSha256 == $tokenHash and
    .licenseTokenBytes == $tokenBytes and
    .exeSha256 == $hash
' "$tmp/licensed/.VgpuPortable.exe.receipts/$licensed_exe_hash.json" \
    >/dev/null || fail "private portable host receipt is malformed"

# A DLS endpoint/token rotation remains fail-closed by default.  The explicit
# replacement path must retain the authenticated old private EXE and embedded
# token before atomically publishing the new generation.
rotated_token="$tmp/client_configuration_token-rotated.tok"
cp -- "$licensed_token" "$rotated_token"
printf '\nrotated\n' >>"$rotated_token"
chmod 0600 "$rotated_token"
old_licensed_exe_hash=$licensed_exe_hash
if IMAGE_ROOT="$tmp/empty-image-root" "$packager" \
        --token-file "$rotated_token" \
        --output-dir "$tmp/licensed/.host-bundle" \
        --output-exe "$tmp/licensed/VgpuPortable.exe" \
        >/dev/null 2>&1; then
    fail "private portable silently replaced an old token generation"
fi
[[ "$(sha256sum "$tmp/licensed/VgpuPortable.exe" |
    awk '{print toupper($1)}')" == "$old_licensed_exe_hash" ]] ||
    fail "refused token rotation changed the existing private EXE"

IMAGE_ROOT="$tmp/empty-image-root" "$packager" \
    --token-file "$rotated_token" --replace-licensed \
    --output-dir "$tmp/licensed/.host-bundle" \
    --output-exe "$tmp/licensed/VgpuPortable.exe" >/dev/null
mapfile -t private_backups < <(
    find "$tmp/package-backups" -mindepth 1 -maxdepth 1 \
        -type d -name 'VgpuPortableLicensed.old.*' -print
)
[[ "${#private_backups[@]}" == 1 ]] ||
    fail "licensed token rotation did not retain exactly one private backup"
private_backup=${private_backups[0]}
[[ "$(stat -c %a "$tmp/package-backups")" == 700 &&
   "$(stat -c %a "$private_backup")" == 700 &&
   "$(stat -c %a "$private_backup/README.txt")" == 600 ]] ||
    fail "licensed token rotation backup permissions are unsafe"
[[ "$(sha256sum "$private_backup/VgpuPortable.exe" |
    awk '{print toupper($1)}')" == "$old_licensed_exe_hash" ]] ||
    fail "licensed token rotation backup does not retain the old EXE"
cmp -s -- "$licensed_token" \
    "$private_backup/.host-bundle/client_configuration_token.tok" ||
    fail "licensed token rotation backup does not retain the old token"
cmp -s -- "$rotated_token" \
    "$tmp/licensed/.host-bundle/client_configuration_token.tok" ||
    fail "licensed token rotation did not publish the new token"

# --replace-licensed is not permission to archive and bless an altered old
# payload.  Even with a valid EXE receipt, every expanded-bundle file must
# still authenticate through READY -> manifest -> payload hashes.
printf '\nmodified-old-token\n' >> \
    "$tmp/licensed/.host-bundle/client_configuration_token.tok"
if IMAGE_ROOT="$tmp/empty-image-root" "$packager" \
        --token-file "$licensed_token" --replace-licensed \
        --output-dir "$tmp/licensed/.host-bundle" \
        --output-exe "$tmp/licensed/VgpuPortable.exe" \
        >/dev/null 2>&1; then
    fail "licensed replacement archived a tampered old bundle"
fi
# Restore the exact authenticated rotated generation for the remaining tests.
cp -- "$rotated_token" \
    "$tmp/licensed/.host-bundle/client_configuration_token.tok"

licensed_tampered="$tmp/licensed-tampered"
cp -a -- "$tmp/licensed/.host-bundle" "$licensed_tampered"
printf '\n' >>"$licensed_tampered/client_configuration_token.tok"
if "$builder" --bundle-dir "$licensed_tampered" \
        --output "$tmp/licensed-tampered.exe" >/dev/null 2>&1; then
    fail "single-EXE builder accepted a tampered private token"
fi

unsafe_token="$tmp/unsafe-token.tok"
install -m 0644 -- "$licensed_token" "$unsafe_token"
if IMAGE_ROOT="$tmp/empty-image-root" "$packager" \
        --token-file "$unsafe_token" \
        --output-dir "$tmp/unsafe/.host-bundle" \
        --output-exe "$tmp/unsafe/VgpuPortable.exe" >/dev/null 2>&1; then
    fail "private portable packager accepted a group/world-readable token"
fi

tampered="$tmp/tampered"
cp -a -- "$tmp/out/.host-bundle" "$tampered"
printf '\n' >>"$tampered/profile-gt1030_2gb.json"
if "$builder" --bundle-dir "$tampered" \
        --output "$tmp/tampered.exe" >/dev/null 2>&1; then
    fail "single-EXE builder accepted a tampered portable profile"
fi

if "$packager" 456 >/dev/null 2>&1; then
    fail "portable packager accepted a VM_ID"
fi
if "$packager" --gpuz-source /does/not/exist >/dev/null 2>&1; then
    fail "portable packager retained the obsolete embedded GPU-Z option"
fi
if "$packager" --replace-public --with-license-token >/dev/null 2>&1; then
    fail "portable packager combined public replacement with a private token"
fi

external_tampered="$tmp/external-tampered"
cp -a -- "$tmp/out/.host-bundle" "$external_tampered"
jq '.optionalExternalFiles[0].sha256 =
    "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"' \
    "$external_tampered/bundle-manifest.json" >"$tmp/external-manifest.json"
mv -f -- "$tmp/external-manifest.json" \
    "$external_tampered/bundle-manifest.json"
manifest_hash=$(sha256sum "$external_tampered/bundle-manifest.json" |
    awk '{print toupper($1)}')
printf 'schema_version=1\nmanifest_sha256=%s\n' "$manifest_hash" \
    >"$external_tampered/READY"
if "$builder" --bundle-dir "$external_tampered" \
        --output "$tmp/external-tampered.exe" >/dev/null 2>&1; then
    fail "builder accepted altered external GPU-Z metadata"
fi

for required in \
        'EXTERNAL_GPUZ_ENABLED' \
        'GetModuleFileNameW' \
        'GetFinalPathNameByHandleW' \
        'GetVolumePathNameW' \
        'handles_share_final_directory' \
        'FILE_FLAG_OPEN_REPARSE_POINT' \
        'FILE_SHARE_READ' \
        'import_external_gpuz' \
        'verify_protected_handle' \
        'sha256_handle'; do
    rg -Fq "$required" "$launcher" ||
        fail "external-sibling launcher safety gate is missing: $required"
done
for required in \
        '[switch]$AdminOnlySourceSnapshot' \
        '[switch]$InstallGpuZ' \
        "'GPU-Z was not selected; identity installation/query continues without it.'" \
        'Install-OptionalProtectedGpuZ' \
        'Get-OptionalValidatedGpuZ' \
        '-AdminOnlySourceSnapshot' \
        'Get-ValidatedGpuZ $contract'; do
    rg -Fq -- "$required" "$guest" ||
        fail "external snapshot preflight/reuse gate is missing: $required"
done

rg -Fq 'if (($# == 0))' "$dispatcher" ||
    fail "one-click dispatcher does not default to portable mode"
rg -Fq 'exec "$here/package-vgpu-portable.sh"' "$dispatcher" ||
    fail "one-click dispatcher does not route to the portable packager"
rg -Fq -- 'if [[ "$1" == --with-license-token || "$1" == --token-file ]]' \
    "$dispatcher" ||
    fail "one-click dispatcher does not expose the private portable finalizer"
rg -Fq -- 'if [[ "$1" == --replace-public ]]' "$dispatcher" ||
    fail "one-click dispatcher does not expose authenticated public replacement"

for required in \
        'G11_VGPU_PROFILE_V1|' \
        'GetRawSmbios' \
        'Expected exactly one read-only portable profile claim' \
        "BindingMode = 'portable-auto'" \
        'hostCommitEligible = $false' \
        'Install-PortableBProfile' \
        'Install-PrivateLicenseToken' \
        'Get-PrivateLicenseEvidence' \
        'Disable-HibernationAndFastStartup' \
        'Assert-HibernationAndFastStartupDisabled' \
        'Invoke-RecommendGuestPerformance' \
        "'Optimize-Guest.ps1'" \
        "'-Mode', \$Mode" \
        'guestPerformance = $performanceEvidence' \
        'client_configuration_token.tok' \
        "'NVDisplay.ContainerLocalSystem'" \
        "'Licensed'" \
        'ProfileKey = [string]$Gpu.profile' \
        "'-ProfileKey \"' + [string]\$Gpu.profile + '\" '"; do
    rg -Fq "$required" "$guest" ||
        fail "guest portable gate is missing: $required"
done
rg -Fq 'VGPU_PORTABLE_PROFILE_CLAIM=' "$start" ||
    fail "start-vm does not publish the automatic runtime profile claim"
rg -Fq 'vgpu_profile_catalog_sha256' "$start" ||
    fail "start-vm claim is not tied to the canonical catalog digest"

python3 - "$guest" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
legacy_start = source.index("function Read-And-ValidatePortableContract")
identity_start = source.index("function Read-And-ValidatePortableIdentityContract")
dispatch_start = source.index("function Read-And-ValidateContract")
legacy = source[legacy_start:identity_start]
identity = source[identity_start:dispatch_start]

# Schema 3/4 contracts predate the query asset. Schemas 5/6/7 must validate
# and return it. Schemas 6/7 use an identity generation that works without
# GPU-Z while still binding the exact optional image accepted later.
assert "queryName" not in legacy
assert "'queryName', 'querySha256'" in identity
assert "QueryPath = Join-Path" in identity
assert "QuerySha256 = [string]$appLocal.querySha256" in identity
assert "$applicationGeneration" in identity
assert "'identity-{0}-{1}-{2}-{3}'" in identity
assert "appLocal.shimSha256" in identity
assert "appLocal.querySha256" in identity
assert "IdentityApplicationDirectory = $applicationDirectory" in identity
assert "'contract.schemaVersion' 5 7" in identity
assert "LicenseTokenPath = $licenseTokenPath" in identity
assert "LicenseInstallerPath = $licenseInstallerPath" in identity
assert "function Get-HealthyDisplayStateWithRetry" in source
assert "$win32Code -ne 32" in source
assert "function Invoke-PortableIdentityMain" in source
assert "if ($InstallGpuZ)" in source
assert "Start-Process -FilePath $queryItem.FullName" in source
PY

echo "PASS: one portable EXE carries identity, guest performance and optional GPU-Z gates"
