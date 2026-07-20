#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
packager="$root/deploy/package-vgpu-portable.sh"
dispatcher="$root/deploy/package-vgpu-one-click.sh"
builder="$root/deploy/guest/gpuz-launcher/build.sh"
guest="$root/deploy/guest/apply-gpuz-profile.ps1"
start="$root/deploy/start-vm.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

tmp=$(mktemp -d)
cleanup() {
    rm -rf -- "$tmp"
}
trap cleanup EXIT
mkdir -m 0700 -- "$tmp/out"

source "$root/deploy/lib/vm-storage.sh"
source "$root/deploy/lib/gpuz-assets.sh"
vm_storage_init
gpuz_source=$(gpuz_asset_default_source) ||
    fail "canonical GPU-Z source is unavailable"

"$packager" \
    --output-dir "$tmp/out/.host-bundle" \
    --output-exe "$tmp/out/VgpuPortable.exe" \
    --gpuz-source "$gpuz_source" >/dev/null

contract="$tmp/out/.host-bundle/gpuz-contract.json"
manifest="$tmp/out/.host-bundle/bundle-manifest.json"
[[ -s "$tmp/out/VgpuPortable.exe" && -s "$contract" && -s "$manifest" ]] ||
    fail "portable packager did not publish complete outputs"

jq -e '
    (keys | sort) == [
        "appLocal", "bindingMode", "catalogSha256",
        "expectedDriverVersion", "expectedPnpId", "gpuz", "profiles",
        "schemaVersion", "spoofMode"
    ] and
    .schemaVersion == 3 and .bindingMode == "portable-auto" and
    .spoofMode == "B" and
    .expectedPnpId == "PCI\\VEN_10DE&DEV_1E30" and
    .expectedDriverVersion == "31.0.15.3833" and
    [.profiles[].key] ==
        ["gtx750ti_2gb", "gt1030_2gb", "gtx1050_2gb"] and
    [.profiles[].canonicalDisplayName] == [
        "NVIDIA GeForce GTX 750 Ti",
        "NVIDIA GeForce GT 1030",
        "NVIDIA GeForce GTX 1050"
    ] and
    ([.profiles[].asset.name] | unique | length) == 3 and
    (.gpuz.sha256 ==
        "6CB0EF29682452DE81A9576808881685161411A1FAD00938BA04131159979C29")
' "$contract" >/dev/null ||
    fail "portable contract does not contain the exact audited catalog"

jq -e '
    (keys | sort) == ["bindingMode", "files", "schemaVersion"] and
    .schemaVersion == 2 and .bindingMode == "portable-auto" and
    ([.files[].name | select(startswith("profile-"))] | length) == 3
' "$manifest" >/dev/null ||
    fail "portable manifest schema is incorrect"

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
    .schemaVersion == 1 and .bindingMode == "portable-auto" and
    .launcherFormat == "QEMU_GPUZ_PORTABLE_EXE_V1" and
    .exeSha256 == $hash
' "$receipt_dir/$exe_hash.json" >/dev/null ||
    fail "portable host receipt is missing or malformed"

# Rebuild is an authenticated update, not a different VM-specific namespace.
"$packager" \
    --output-dir "$tmp/out/.host-bundle" \
    --output-exe "$tmp/out/VgpuPortable.exe" \
    --gpuz-source "$gpuz_source" >/dev/null

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

rg -Fq 'if (($# == 0))' "$dispatcher" ||
    fail "one-click dispatcher does not default to portable mode"
rg -Fq 'exec "$here/package-vgpu-portable.sh"' "$dispatcher" ||
    fail "one-click dispatcher does not route to the portable packager"

for required in \
        'G11_VGPU_PROFILE_V1|' \
        'GetRawSmbios' \
        'Expected exactly one read-only portable profile claim' \
        "BindingMode = 'portable-auto'" \
        'hostCommitEligible = $false' \
        'Install-PortableBProfile' \
        'ProfileKey = [string]$Gpu.profile' \
        "'-ProfileKey \"' + [string]\$Gpu.profile + '\" '"; do
    rg -Fq "$required" "$guest" ||
        fail "guest portable gate is missing: $required"
done
rg -Fq 'VGPU_PORTABLE_PROFILE_CLAIM=' "$start" ||
    fail "start-vm does not publish the automatic runtime profile claim"
rg -Fq 'vgpu_profile_catalog_sha256' "$start" ||
    fail "start-vm claim is not tied to the canonical catalog digest"

echo "PASS: one offline EXE has no VM binding, embeds 3 profiles, and requires the B/native runtime firmware claim"
