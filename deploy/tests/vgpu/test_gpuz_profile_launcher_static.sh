#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
builder="$root/deploy/guest/gpuz-launcher/build.sh"
portable_packager="$root/deploy/package-vgpu-portable.sh"
source_file="$root/deploy/guest/gpuz-launcher/gpuz_profile_launcher.c"
uac_manifest="$root/deploy/guest/gpuz-launcher/gpuz_profile_launcher.manifest"
gpuz_source="${IMAGE_ROOT:-/home/ubuntu/images}/candidates/gpuz-2.70-audit/GPU-Z.2.70.0.exe"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

hash_upper() {
    sha256sum -- "$1" | awk '{print toupper($1)}'
}

[[ -f "$gpuz_source" && ! -L "$gpuz_source" &&
   "$(stat -c %s -- "$gpuz_source")" == 11642144 &&
   "$(hash_upper "$gpuz_source")" == \
       6CB0EF29682452DE81A9576808881685161411A1FAD00938BA04131159979C29 ]] ||
    fail "locked GPU-Z 2.70.0 launcher fixture is unavailable: $gpuz_source"

make_fixture() {
    local directory=$1
    mkdir -p "$directory"
    printf '# fixture\n' >"$directory/apply-gpuz-profile.ps1"
    printf '# fixture\n' >"$directory/apply-vm-profile.ps1"
    printf '# fixture\n' >"$directory/patch-grid-strings.ps1"
    printf 'fixture-dll\n' >"$directory/nvapi.dll"
    printf 'fixture-probe\n' >"$directory/nvapi_profile_probe32.exe"
    install -m 0600 -- "$gpuz_source" "$directory/GPU-Z.exe"
    printf '{"schemaVersion":1,"vmId":91,"gpu":{"profile":"gt1030_2gb"}}\n' \
        >"$directory/vm91-profile.json"
    printf '@echo off\r\nexit /b 0\r\n' >"$directory/RUN-GPUZ-PROFILE.cmd"
    jq -n \
        --arg profileHash "$(hash_upper "$directory/vm91-profile.json")" \
        --arg shimHash "$(hash_upper "$directory/nvapi.dll")" \
        --arg probeHash "$(hash_upper "$directory/nvapi_profile_probe32.exe")" \
        '{
            schemaVersion:2,
            vmId:91,
            vmUuid:"11111111-2222-3333-4444-555555555555",
            spoofMode:"B",
            gpuProfile:"gt1030_2gb",
            expectedPnpId:"PCI\\VEN_10DE&DEV_1E30",
            expectedDriverVersion:"31.0.15.3833",
            gpuz:{
                name:"GPU-Z.exe",
                bytes:11642144,
                productVersion:"2.70.0",
                sha256:"6CB0EF29682452DE81A9576808881685161411A1FAD00938BA04131159979C29"
            },
            profile:{name:"vm91-profile.json",sha256:$profileHash},
            appLocal:{
                shimName:"nvapi.dll",shimSha256:$shimHash,
                probeName:"nvapi_profile_probe32.exe",probeSha256:$probeHash
            }
        }' >"$directory/gpuz-contract.json"

    local files='[]' name
    for name in \
            vm91-profile.json apply-vm-profile.ps1 \
            patch-grid-strings.ps1 apply-gpuz-profile.ps1 \
            nvapi.dll nvapi_profile_probe32.exe \
            GPU-Z.exe \
            gpuz-contract.json RUN-GPUZ-PROFILE.cmd; do
        files=$(jq -c \
            --arg name "$name" \
            --arg sha256 "$(hash_upper "$directory/$name")" \
            --argjson bytes "$(stat -c %s -- "$directory/$name")" \
            '. + [{name:$name,sha256:$sha256,bytes:$bytes}]' <<<"$files")
    done
    jq -n --argjson files "$files" \
        '{schemaVersion:1,vmId:91,files:$files}' \
        >"$directory/bundle-manifest.json"
    printf 'schema_version=1\nmanifest_sha256=%s\n' \
        "$(hash_upper "$directory/bundle-manifest.json")" \
        >"$directory/READY"
}

bash -n "$builder"
rg -Fq 'level="requireAdministrator" uiAccess="false"' "$uac_manifest" ||
    fail "launcher does not request UAC before extraction"
rg -Fq "LAUNCHER_VERSION_COMMA='1,1,0,0'" "$builder" ||
    fail "launcher numeric file version is not 1.1.0.0"
rg -Fq 'FILEVERSION $LAUNCHER_VERSION_COMMA' "$builder" ||
    fail "launcher numeric product version is not 1.1.0.0"
rg -Fq "LAUNCHER_VERSION_TEXT='1.1.0.0'" "$builder" ||
    fail "launcher display file version is not 1.1.0.0"
rg -Fq 'VALUE "ProductVersion", "$LAUNCHER_VERSION_TEXT\0"' "$builder" ||
    fail "launcher display product version is not 1.1.0.0"
rg -Fq 'version="1.1.0.0"' "$uac_manifest" ||
    fail "launcher assembly version is not 1.1.0.0"
for required in \
        'BCryptGenRandom' \
        'BCRYPT_SHA256_ALGORITHM' \
        'GetFinalPathNameByHandleW' \
        'GetVolumePathNameW' \
        'handles_share_final_directory' \
        'FILE_FLAG_OPEN_REPARSE_POINT' \
        'CREATE_NEW' \
        'O:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)' \
        'verify_protected_handle' \
        'open_protected_directory' \
        'Global\\QemuGpuZProfileSingleExeV1' \
        'SHGetFolderPathW(NULL, CSIDL_COMMON_APPDATA' \
        'WindowsPowerShell\\v1.0\\powershell.exe' \
        'CreateProcessW(powershell' \
        'build_clean_environment' \
        'CREATE_UNICODE_ENVIRONMENT' \
        'EXTENDED_STARTUPINFO_PRESENT' \
        'PROC_THREAD_ATTRIBUTE_HANDLE_LIST' \
        'STARTF_USESTDHANDLES' \
        'inherited COR_*, COMPLUS_* or DOTNET_*' \
        'QemuGpuZProfile-RuntimeTemp' \
        'WaitForSingleObject(process.hProcess, INFINITE)' \
        'delete_tree_without_following_reparse' \
        'L"/with-gpuz"' \
        'install_gpuz ? L" -InstallGpuZ"' \
        'EXTERNAL_GPUZ_OPTIONAL'; do
    rg -Fq "$required" "$source_file" ||
        fail "launcher is missing security primitive: $required"
done
python3 - "$source_file" <<'PY'
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")

# /no-launch is the noninteractive SYSTEM/task-scheduler entry.  It must keep
# console reporting but must never wait on a Session-0 message box.  The sole
# MessageBoxW call is therefore inside the shared reporter's !no_launch guard,
# and every call site passes the parsed mode.
assert source.count("MessageBoxW(") == 1
reporter = re.search(
    r"static void show_message\(BOOL no_launch,.*?^\}",
    source,
    flags=re.MULTILINE | re.DOTALL,
)
assert reporter
reporter_text = reporter.group(0)
assert "fwprintf(stream," in reporter_text
assert "fflush(stream);" in reporter_text
assert re.search(
    r"if \(!no_launch\) \{\s*MessageBoxW\(",
    reporter_text,
    flags=re.DOTALL,
)

calls = re.findall(r"(?<!void )show_message\((.*?)\);", source, re.DOTALL)
assert calls
assert all(call.lstrip().startswith("no_launch,") for call in calls)

# Argument scanning must continue after an invalid token so a trailing
# /no-launch still suppresses UI on the usage-error path.
parser = re.search(
    r"static int parse_arguments\(.*?^\}",
    source,
    flags=re.MULTILINE | re.DOTALL,
)
assert parser
parser_text = parser.group(0)
assert "valid = 0;" in parser_text
assert "return valid;" in parser_text
assert "return 0;" not in parser_text

# Once the child exit code was observed, /no-launch returns that value unless
# the launcher's own protected extraction cleanup fails.  Cleanup failure is
# still an overall failure; suppressing modal UI must not weaken fail-closed
# result semantics.
assert "return_code = (int)child_exit;" in source
assert re.search(
    r"else if \(profile_observed && child_exit == 0\) \{\s*"
    r"return_code = 1;",
    source,
    flags=re.DOTALL,
)
PY
if rg -n -i \
        'ShellExecute|iexpress|7z[[:space:]]|bcdedit.*(/set|-set)|testsigning.*(on|yes)|nointegritychecks.*(on|yes)' \
        "$source_file" "$builder" "$uac_manifest" >/dev/null; then
    fail "launcher can use a forbidden SFX/elevation/code-integrity path"
fi
for forbidden_environment_path in \
        'SetEnvironmentVariableW' \
        'CREATE_UNICODE_ENVIRONMENT, NULL'; do
    if rg -Fq "$forbidden_environment_path" "$source_file"; then
        fail "launcher can inherit or partially mutate an attacker-controlled environment"
    fi
done
rg -Fq 'cp -a -- "$BUNDLE_FD_PATH/." "$SNAPSHOT/"' "$builder" ||
    fail "builder does not validate and embed one private input snapshot"
rg -Fq 'ln -T -- "$tmp/GpuZProfileInstaller.exe" "$OUTPUT"' "$builder" ||
    fail "builder publication can follow a directory/symlink output"

fixture="$tmp/fixture"
make_fixture "$fixture"
output_a="$tmp/fixture-a.exe"
output_b="$tmp/fixture-b.exe"
bash "$builder" --bundle-dir "$fixture" --output "$output_a" >/dev/null
bash "$builder" --bundle-dir "$fixture" --output "$output_b" >/dev/null
cmp -s "$output_a" "$output_b" ||
    fail "identical bundle did not produce a deterministic EXE"
file "$output_a" | grep -Fq 'PE32+ executable (console) x86-64' ||
    fail "launcher is not a native Win64 console PE"
strings -a "$output_a" |
    grep -Fq 'requestedExecutionLevel level="requireAdministrator" uiAccess="false"' ||
    fail "compiled EXE omits its UAC manifest"
strings -el "$output_a" | grep -Fq 'QEMU_GPUZ_SINGLE_EXE_V1' ||
    fail "compiled EXE omits its ownership/version marker"
python3 - "$output_a" "$fixture" <<'PY'
import hashlib
import json
import pathlib
import sys

import pefile

exe = pathlib.Path(sys.argv[1])
bundle = pathlib.Path(sys.argv[2])
manifest = json.loads((bundle / "bundle-manifest.json").read_text())
names = ["READY", "bundle-manifest.json"] + [
    item["name"] for item in manifest["files"]
]
pe = pefile.PE(str(exe), fast_load=False)
resource_root = pe.DIRECTORY_ENTRY_RESOURCE
rcdata_type = next(
    entry for entry in resource_root.entries if entry.id == 10
)
entries = sorted(rcdata_type.directory.entries, key=lambda item: item.id)
assert len(entries) == len(names) == 11
for expected_id, name, entry in zip(range(201, 212), names, entries):
    assert entry.id == expected_id
    language = entry.directory.entries[0]
    rva = language.data.struct.OffsetToData
    size = language.data.struct.Size
    embedded = pe.get_memory_mapped_image()[rva:rva + size]
    source = (bundle / name).read_bytes()
    assert embedded == source
    assert hashlib.sha256(embedded).digest() == hashlib.sha256(source).digest()
PY

# Portable schema 4 is intentionally a different launcher generation: GPU-Z
# is declared as an explicit optional sibling and must never become RCDATA.
mkdir -m 0700 -- "$tmp/portable"
IMAGE_ROOT="$tmp/portable-empty-image-root" "$portable_packager" \
    --output-dir "$tmp/portable/bundle" \
    --output-exe "$tmp/portable/from-packager.exe" >/dev/null
portable_bundle="$tmp/portable/bundle"
portable_a="$tmp/portable-a.exe"
portable_b="$tmp/portable-b.exe"
bash "$builder" --bundle-dir "$portable_bundle" \
    --output "$portable_a" >/dev/null
bash "$builder" --bundle-dir "$portable_bundle" \
    --output "$portable_b" >/dev/null
cmp -s "$portable_a" "$portable_b" ||
    fail "optional-GPU-Z bundle did not produce a deterministic EXE"
strings -el "$portable_a" | grep -Fq 'QEMU_VGPU_PORTABLE_IDENTITY_V4' ||
    fail "multi-brand EXE omits its V4 ownership/version marker"
strings -el "$portable_a" | grep -Fq '1.4.0.0' ||
    fail "multi-brand EXE omits its 1.4.0.0 file/product version"
python3 - "$portable_a" "$portable_bundle/bundle-manifest.json" \
        "$gpuz_source" <<'PY'
import hashlib
import json
import pathlib
import sys

import pefile

exe = pathlib.Path(sys.argv[1])
manifest = json.loads(pathlib.Path(sys.argv[2]).read_text())
gpuz = pathlib.Path(sys.argv[3]).read_bytes()
expected_hash = hashlib.sha256(gpuz).hexdigest().upper()
assert manifest["schemaVersion"] == 4
assert manifest["optionalExternalFiles"] == [{
    "name": "GPU-Z.exe",
    "sha256": expected_hash,
    "bytes": len(gpuz),
}]
assert "GPU-Z.exe" not in {row["name"] for row in manifest["files"]}

pe = pefile.PE(str(exe), fast_load=False)
resources = []
for type_entry in pe.DIRECTORY_ENTRY_RESOURCE.entries:
    type_id = type_entry.id
    if type_id != pefile.RESOURCE_TYPE["RT_RCDATA"]:
        continue
    for id_entry in type_entry.directory.entries:
        for language_entry in id_entry.directory.entries:
            data = language_entry.data.struct
            payload = pe.get_data(data.OffsetToData, data.Size)
            resources.append(payload)
assert len(resources) == len(manifest["files"]) + 2
assert all(len(payload) != len(gpuz) for payload in resources)
assert all(hashlib.sha256(payload).hexdigest().upper() != expected_hash
           for payload in resources)
PY

external_tampered="$tmp/external-manifest-tampered"
cp -a -- "$portable_bundle" "$external_tampered"
jq '.optionalExternalFiles[0].sha256 =
    "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"' \
    "$external_tampered/bundle-manifest.json" \
    >"$tmp/external-tampered-manifest.json"
mv -f -- "$tmp/external-tampered-manifest.json" \
    "$external_tampered/bundle-manifest.json"
printf 'schema_version=1\nmanifest_sha256=%s\n' \
    "$(hash_upper "$external_tampered/bundle-manifest.json")" \
    >"$external_tampered/READY"
if bash "$builder" --bundle-dir "$external_tampered" \
        --output "$tmp/external-manifest-tampered.exe" >/dev/null 2>&1; then
    fail "builder accepted tampered optionalExternalFiles metadata"
fi

external_injected="$tmp/external-file-injected"
cp -a -- "$portable_bundle" "$external_injected"
install -m 0600 -- "$gpuz_source" "$external_injected/GPU-Z.exe"
if bash "$builder" --bundle-dir "$external_injected" \
        --output "$tmp/external-file-injected.exe" >/dev/null 2>&1; then
    fail "builder accepted an unexpected bundled GPU-Z image"
fi

# Reusing an identical target is permitted; silently replacing a different
# existing file is not.
bash "$builder" --bundle-dir "$fixture" --output "$output_a" >/dev/null
printf 'unrelated\n' >"$tmp/unrelated.exe"
if bash "$builder" --bundle-dir "$fixture" \
        --output "$tmp/unrelated.exe" >/dev/null 2>&1; then
    fail "builder replaced an unrelated existing EXE"
fi
grep -Fxq unrelated "$tmp/unrelated.exe" ||
    fail "unrelated output changed"
mkdir "$tmp/output-directory.exe"
if bash "$builder" --bundle-dir "$fixture" \
        --output "$tmp/output-directory.exe" >/dev/null 2>&1; then
    fail "builder treated an output directory as an EXE"
fi
ln -s "$tmp/output-directory.exe" "$tmp/output-symlink.exe"
if bash "$builder" --bundle-dir "$fixture" \
        --output "$tmp/output-symlink.exe" >/dev/null 2>&1; then
    fail "builder followed an output symlink to a directory"
fi
if bash "$builder" --bundle-dir "$fixture" \
        --output "$fixture/new-output/inside.exe" >/dev/null 2>&1; then
    fail "builder accepted output inside its input bundle"
fi
[[ ! -e "$fixture/new-output" ]] ||
    fail "rejected in-bundle output polluted the input directory"

cp -a "$fixture" "$tmp/tampered"
printf 'tamper\n' >>"$tmp/tampered/nvapi.dll"
if bash "$builder" --bundle-dir "$tmp/tampered" \
        --output "$tmp/tampered.exe" >/dev/null 2>&1; then
    fail "builder accepted a manifest asset with a bad size/hash"
fi

for gpuz_manifest_mutation in name sha256 bytes; do
    mutated="$tmp/gpuz-manifest-$gpuz_manifest_mutation"
    cp -a "$fixture" "$mutated"
    case "$gpuz_manifest_mutation" in
        name)
            jq '(.files[] | select(.name == "GPU-Z.exe").name) =
                    "GPU-Z-copy.exe"' "$mutated/bundle-manifest.json" \
                >"$mutated/bundle-manifest.json.new"
            ;;
        sha256)
            jq '(.files[] | select(.name == "GPU-Z.exe").sha256) =
                    "0000000000000000000000000000000000000000000000000000000000000000"' \
                "$mutated/bundle-manifest.json" \
                >"$mutated/bundle-manifest.json.new"
            ;;
        bytes)
            jq '(.files[] | select(.name == "GPU-Z.exe").bytes) =
                    11642143' "$mutated/bundle-manifest.json" \
                >"$mutated/bundle-manifest.json.new"
            ;;
    esac
    mv "$mutated/bundle-manifest.json.new" \
        "$mutated/bundle-manifest.json"
    printf 'schema_version=1\nmanifest_sha256=%s\n' \
        "$(hash_upper "$mutated/bundle-manifest.json")" >"$mutated/READY"
    if bash "$builder" --bundle-dir "$mutated" \
            --output "$tmp/gpuz-manifest-$gpuz_manifest_mutation.exe" \
            >/dev/null 2>&1; then
        fail "builder accepted mismatched GPU-Z manifest $gpuz_manifest_mutation"
    fi
done

cp -a "$fixture" "$tmp/extra"
printf 'extra\n' >"$tmp/extra/not-owned.txt"
if bash "$builder" --bundle-dir "$tmp/extra" \
        --output "$tmp/extra.exe" >/dev/null 2>&1; then
    fail "builder accepted an unmanifested root file"
fi

cp -a "$fixture" "$tmp/symlinked"
mv "$tmp/symlinked/nvapi.dll" "$tmp/symlinked/nvapi-real.dll"
ln -s nvapi-real.dll "$tmp/symlinked/nvapi.dll"
if bash "$builder" --bundle-dir "$tmp/symlinked" \
        --output "$tmp/symlinked.exe" >/dev/null 2>&1; then
    fail "builder accepted a symlinked payload"
fi

cp -a "$fixture" "$tmp/bad-ready"
printf 'schema_version=1\nmanifest_sha256=%064d\n' 0 \
    >"$tmp/bad-ready/READY"
if bash "$builder" --bundle-dir "$tmp/bad-ready" \
        --output "$tmp/bad-ready.exe" >/dev/null 2>&1; then
    fail "builder accepted a bad READY hash"
fi

cp -a "$fixture" "$tmp/malformed-manifest-tail"
jq '.files += [42]' \
    "$tmp/malformed-manifest-tail/bundle-manifest.json" \
    >"$tmp/malformed-manifest-tail/bundle-manifest.json.new"
mv "$tmp/malformed-manifest-tail/bundle-manifest.json.new" \
    "$tmp/malformed-manifest-tail/bundle-manifest.json"
printf 'schema_version=1\nmanifest_sha256=%s\n' \
    "$(hash_upper "$tmp/malformed-manifest-tail/bundle-manifest.json")" \
    >"$tmp/malformed-manifest-tail/READY"
if bash "$builder" --bundle-dir "$tmp/malformed-manifest-tail" \
        --output "$tmp/malformed-manifest-tail.exe" >/dev/null 2>&1; then
    fail "builder accepted a malformed trailing manifest entry"
fi

echo "PASS: generic native GPU-Z single-EXE launcher is deterministic and fail-closed"
