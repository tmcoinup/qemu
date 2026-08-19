#!/usr/bin/env bash
set -euo pipefail

# Do not let a caller's storage selection escape the per-test temporary roots.
unset IMAGE_ROOT ISO_DIR STAGE_DIR VM_ROOT VMS_DIR VM_INSTANCES_DIR
unset VM_INSTANCE_DIR VM_INSTANCE_ID VM_STORAGE_COMPAT_FALLBACK
unset VM_SHARED_DIR VM_CONFIG_DIR VM_DISK_DIR VM_BASE_DIR VM_NVRAM_DIR
unset VM_CONTROL_DIR VM_RUN_DIR VM_LOG_DIR VM_ASSET_DIR
unset VM_DISK_ARCHIVE_DIR VM_BASE_ARCHIVE_DIR VM_NVRAM_BACKUP_DIR

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
packager="$root/deploy/package-gpuz-profile.sh"
guest_entry="$root/deploy/guest/apply-gpuz-profile.ps1"
launcher_source="$root/deploy/guest/gpuz-launcher/gpuz_profile_launcher.c"
launcher_manifest="$root/deploy/guest/gpuz-launcher/gpuz_profile_launcher.manifest"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

image_root="$tmp/images"
vm_root="$tmp/vms"
stage_dir="$tmp/staging"
locked_gpuz_source="${GPUZ_TEST_SOURCE:-/home/ubuntu/images/candidates/gpuz-2.70-audit/GPU-Z.2.70.0.exe}"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

file_sha256() {
    sha256sum -- "$1" | awk '{print toupper($1)}'
}

[[ -f "$locked_gpuz_source" && ! -L "$locked_gpuz_source" &&
   "$(stat -c %s -- "$locked_gpuz_source")" == 11642144 &&
   "$(file_sha256 "$locked_gpuz_source")" == \
       6CB0EF29682452DE81A9576808881685161411A1FAD00938BA04131159979C29 ]] ||
    fail "locked GPU-Z 2.70.0 package fixture is unavailable: $locked_gpuz_source"
mkdir -p "$image_root/candidates/gpuz-2.70-audit"
install -m 0600 -- "$locked_gpuz_source" \
    "$image_root/candidates/gpuz-2.70-audit/GPU-Z.2.70.0.exe"

create_vm() {
    local vm_id=$1 profile=$2
    VM_ROOT="$vm_root" IMAGE_ROOT="$image_root" STAGE_DIR="$stage_dir" \
        bash "$root/deploy/scripts/create-vm.sh" "$vm_id" \
        --gpu-profile "$profile" >/dev/null
    touch "$vm_root/${vm_id}/disk.qcow2"
}

package_vm() {
    local vm_id=$1 output=$2
    VM_ROOT="$vm_root" IMAGE_ROOT="$image_root" STAGE_DIR="$stage_dir" \
        bash "$packager" "$vm_id" --output-dir "$output" >/dev/null
}

vm_config_value() {
    local root_dir=$1 vm_id=$2 key=$3
    awk -F= -v key="$key" '
        $1 == key {
            value = substr($0, index($0, "=") + 1)
        }
        END {
            if (value == "") {
                exit 1
            }
            print value
        }
    ' "$root_dir/${vm_id}/vm.conf"
}

generic_namespace() {
    local output_root=$1 root_dir=$2 vm_id=$3 uuid
    uuid=$(vm_config_value "$root_dir" "$vm_id" VM_UUID)
    printf '%s/vm%s-%s\n' "$output_root" "$vm_id" "${uuid,,}"
}

assert_manifest() {
    local bundle=$1 vm_id=$2
    local manifest="$bundle/bundle-manifest.json"
    local ready="$bundle/READY"
    [[ -f "$ready" && ! -L "$ready" && -f "$manifest" && ! -L "$manifest" ]] ||
        fail "vm$vm_id bundle markers are missing or unsafe"
    mapfile -t ready_lines <"$ready"
    [[ ${#ready_lines[@]} -eq 2 &&
       "${ready_lines[0]}" == schema_version=1 &&
       "${ready_lines[1]}" =~ ^manifest_sha256=([0-9A-F]{64})$ ]] ||
        fail "vm$vm_id READY is malformed"
    [[ "$(file_sha256 "$manifest")" == "${BASH_REMATCH[1]}" ]] ||
        fail "vm$vm_id READY hash mismatch"
    jq -e --argjson vmId "$vm_id" '
        (keys | sort) == ["files", "schemaVersion", "vmId"] and
        .schemaVersion == 1 and .vmId == $vmId and
        (.files | length) == 10 and
        ([.files[].name] | unique | length) == 10
    ' "$manifest" >/dev/null ||
        fail "vm$vm_id manifest schema mismatch"

    declare -A seen=()
    local name hash bytes
    while IFS=$'\t' read -r name hash bytes; do
        [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ &&
           "$hash" =~ ^[0-9A-F]{64}$ &&
           "$bytes" =~ ^[1-9][0-9]*$ &&
           -z "${seen[$name]+x}" ]] ||
            fail "vm$vm_id unsafe manifest entry"
        seen["$name"]=1
        [[ -f "$bundle/$name" && ! -L "$bundle/$name" ]] ||
            fail "vm$vm_id manifest asset missing: $name"
        [[ "$(file_sha256 "$bundle/$name")" == "$hash" &&
           "$(stat -c %s -- "$bundle/$name")" == "$bytes" ]] ||
            fail "vm$vm_id manifest asset mismatch: $name"
    done < <(jq -er '.files[] | [.name, .sha256, .bytes] | @tsv' "$manifest")

    local expected
    for expected in \
            gpu-profile.json \
            apply-vm-profile.ps1 patch-grid-strings.ps1 \
            vgpu-profile-catalog.json \
            apply-gpuz-profile.ps1 \
            nvapi.dll nvapi_profile_probe32.exe \
            GPU-Z.exe \
            gpuz-contract.json RUN-GPUZ-PROFILE.cmd; do
        [[ -n "${seen[$expected]+x}" ]] ||
            fail "vm$vm_id manifest omitted $expected"
    done
    [[ ! -e "$bundle/purge-rdp-ghosts.ps1" ]] ||
        fail "vm$vm_id bundle contains device cleanup"
    [[ ! -e "$bundle/install-nvapi-shim.ps1" ]] ||
        fail "vm$vm_id bundle contains the system-wide NVAPI installer"
    if find "$bundle" -mindepth 1 -maxdepth 1 \
            ! -type f -print -quit | grep -q .; then
        fail "vm$vm_id bundle has a non-file entry"
    fi
    [[ "$(find "$bundle" -mindepth 1 -maxdepth 1 -type f | wc -l)" -eq 12 ]] ||
        fail "vm$vm_id bundle has an unmanifested file"
}

assert_single_exe() {
    local bundle=$1 vm_id=$2
    local expected_exe=${3:-"${bundle}.exe"}
    local candidate_hash receipt_dir receipt vm_uuid gpu_profile
    [[ -f "$expected_exe" && ! -L "$expected_exe" ]] ||
        fail "vm$vm_id stable single EXE is missing"
    vm_uuid=$(jq -er '.vmUuid' "$bundle/gpuz-contract.json") ||
        fail "vm$vm_id contract omits its UUID binding"
    vm_uuid=${vm_uuid,,}
    gpu_profile=$(jq -er '.gpuProfile' "$bundle/gpuz-contract.json") ||
        fail "vm$vm_id contract omits its GPU profile binding"
    candidate_hash=$(file_sha256 "$expected_exe")
    receipt_dir="$(dirname -- "$bundle")/.$(basename -- "$expected_exe").receipts"
    receipt="$receipt_dir/${candidate_hash}.json"
    [[ -d "$receipt_dir" && ! -L "$receipt_dir" &&
       "$(stat -c %a -- "$receipt_dir")" == 700 &&
       -f "$receipt" && ! -L "$receipt" &&
       "$(stat -c %a -- "$receipt")" == 600 ]] ||
        fail "vm$vm_id stable EXE host receipt is missing or unsafe"
    jq -e \
        --argjson vmId "$vm_id" \
        --arg vmUuid "$vm_uuid" \
        --arg gpuProfile "$gpu_profile" \
        --arg exeName "$(basename -- "$expected_exe")" \
        --arg exeSha256 "$candidate_hash" \
        --argjson exeBytes "$(stat -c %s -- "$expected_exe")" '
        (keys | sort) == [
            "bundleManifestSha256", "exeBytes", "exeName", "exeSha256",
            "gpuProfile", "launcherFormat", "schemaVersion",
            "vmId", "vmUuid"
        ] and
        .schemaVersion == 2 and .vmId == $vmId and
        .vmUuid == $vmUuid and .gpuProfile == $gpuProfile and
        .launcherFormat == "QEMU_GPUZ_SINGLE_EXE_V1" and
        .exeName == $exeName and .exeSha256 == $exeSha256 and
        .exeBytes == $exeBytes and
        (.bundleManifestSha256 | test("^[0-9A-F]{64}$"))
    ' "$receipt" >/dev/null ||
        fail "vm$vm_id stable EXE host receipt does not authenticate it"
    [[ "$(stat -c %a -- "$expected_exe")" == 600 ]] ||
        fail "vm$vm_id single EXE is not private on the host"
    file "$expected_exe" | grep -Fq 'PE32+ executable (console) x86-64' ||
        fail "vm$vm_id single EXE is not native Win64"
    # grep -q can exit before strings finishes; under pipefail that turns a
    # real match into SIGPIPE status 141.  Consume the complete stream.
    strings -a "$expected_exe" |
        grep -F 'requestedExecutionLevel level="requireAdministrator" uiAccess="false"' \
            >/dev/null ||
        fail "vm$vm_id single EXE omits its UAC manifest"
    strings -el "$expected_exe" | grep -F 'QEMU_GPUZ_SINGLE_EXE_V1' \
        >/dev/null ||
        fail "vm$vm_id single EXE omits its launcher marker"
}

assert_profile_bundle() {
    local bundle=$1 vm_id=$2 profile=$3 name=$4 mode=$5 pnp=$6
    assert_manifest "$bundle" "$vm_id"
    assert_single_exe "$bundle" "$vm_id"
    jq -e \
        --argjson vmId "$vm_id" \
        --arg profile "$profile" \
        --arg mode "$mode" \
        --arg pnp "$pnp" '
        (keys | sort) == [
            "appLocal", "expectedDriverVersion", "expectedPnpId",
            "gpuProfile", "gpuz",
            "profile", "schemaVersion", "spoofMode", "vmId", "vmUuid"
        ] and
        .schemaVersion == 2 and .vmId == $vmId and
        .gpuProfile == $profile and .spoofMode == $mode and
        .profile.name == "gpu-profile.json" and
        .expectedPnpId == $pnp and
        .expectedDriverVersion == "31.0.15.3833" and
        (.gpuz | keys | sort) ==
          ["bytes", "name", "productVersion", "sha256"] and
        .gpuz.name == "GPU-Z.exe" and
        .gpuz.bytes == 11642144 and
        .gpuz.productVersion == "2.70.0" and
        .gpuz.sha256 ==
          "6CB0EF29682452DE81A9576808881685161411A1FAD00938BA04131159979C29" and
        (.appLocal.shimSha256 | test("^[0-9A-F]{64}$")) and
        (.appLocal.probeSha256 | test("^[0-9A-F]{64}$")) and
        (has("closeWinrm") | not)
    ' "$bundle/gpuz-contract.json" >/dev/null ||
        fail "vm$vm_id contract mismatch"
    [[ -f "$bundle/GPU-Z.exe" && ! -L "$bundle/GPU-Z.exe" &&
       "$(stat -c %s -- "$bundle/GPU-Z.exe")" == 11642144 &&
       "$(file_sha256 "$bundle/GPU-Z.exe")" == \
           6CB0EF29682452DE81A9576808881685161411A1FAD00938BA04131159979C29 ]] ||
        fail "vm$vm_id bundle does not contain the locked raw GPU-Z executable"
    jq -e --arg profile "$profile" --arg name "$name" '
        . as $root |
        $root.gpu as $gpu |
        $root.schemaVersion == 2 and
        ($root.catalogSha256 | test("^[0-9A-F]{64}$")) and
        $root.spoofMode == "B" and $gpu.profile == $profile and
        $gpu.name == $name and $gpu.memoryType == 8 and
        ($gpu.boardBrand | type == "string") and
        ($gpu.boardModel | type == "string") and
        $gpu.memoryTypeName == "GDDR5" and
        $gpu.memoryMakerName == "Samsung" and
        $gpu.memoryMakerNvapiName == "Samsung" and
        $gpu.identityScope ==
          "B:system-pci=host-mdev,catalog=protected-user-mode" and
        $gpu.nvapiPciVendorId == 4318 and
        (
            ($profile == "gtx750ti_2gb" and
             $gpu.nvapiPciDeviceId == 4992 and
             $gpu.nvapiPciSubVendorId == 4318 and
             $gpu.nvapiPciSubDeviceId == 4992 and
             $gpu.nvapiPciRevisionId == 162) or
            ($profile == "gt1030_2gb" and
             $gpu.nvapiPciDeviceId == 7425 and
             $gpu.nvapiPciSubVendorId == 4163 and
             $gpu.nvapiPciSubDeviceId == 34297 and
             $gpu.nvapiPciRevisionId == 161) or
            ($profile == "gtx1050_2gb" and
             $gpu.nvapiPciDeviceId == 7297 and
             $gpu.nvapiPciSubVendorId == 4136 and
             $gpu.nvapiPciSubDeviceId == 4544 and
             $gpu.nvapiPciRevisionId == 161)
        ) and
        $gpu.memoryMaker == 1 and
        $gpu.boostClockMHz >= $gpu.coreClockMHz and
        $gpu.tmuCount == ($gpu.shaderSubPipes * 8) and
        ([1, 2, 4, 8, 16, 32] | index($gpu.pcieWidth)) != null and
        ((($gpu.memoryClockMHz * 2000 * 2 * $gpu.memoryBusBits / 8000) -
          $gpu.memoryBandwidthMBps) | fabs) * 100 <=
            $gpu.memoryBandwidthMBps
    ' "$bundle/gpu-profile.json" >/dev/null ||
        fail "vm$vm_id staged GDDR5 profile mismatch"
}

# The safe entry is local-only, fail-closed, and dispatches the general
# installer exclusively through its app-local branch.
if rg -n -i \
        'stage-patched-vgpu-driver|install-patched-driver|pnputil|WSMan:|WinRM|Get-NetFirewall|Remove-PnpDevice|purge-rdp' \
        "$guest_entry" "$packager" >/dev/null; then
    fail "one-click sources contain a forbidden network/driver/device mutation"
fi
if rg -n -i 'bcdedit(?:\.exe)?\s+/set|testsigning\s+(?:on|yes)|nointegritychecks\s+(?:on|yes)' \
        "$guest_entry" "$packager" >/dev/null; then
    fail "one-click sources can weaken BCD code integrity"
fi
rg -Fq '& $SystemBcdEdit /enum all' "$guest_entry" ||
    fail "guest entry does not inspect inherited/all BCD integrity flags"
if rg -n -i 'Take-Own|PendingFileRenameOperations|System32\\nvapi64\\.dll.*Copy|SysWOW64\\nvapi\\.dll.*Copy' \
        "$guest_entry" >/dev/null; then
    fail "guest entry contains a system-wide NVAPI installation path"
fi
rg -Fq "Join-Path \$ApplicationDirectory 'nvapi.dll'" "$guest_entry" ||
    fail "guest entry lacks the parameterized protected app-local identity target"
rg -Fq 'Get-PnpDevice -Class Display -PresentOnly' "$guest_entry" ||
    fail "guest entry lacks the present Display acceptance gate"
rg -Fq "Class -ine 'System'" "$guest_entry" ||
    fail "guest entry lacks the System-class parent gate"
rg -Fq '(?i)^PCI\\VEN_(?!10DE)[0-9A-F]{4}&DEV_[0-9A-F]{4}' \
    "$guest_entry" ||
    fail "guest entry does not require one non-NVIDIA PCI parent"
rg -Fq "'(?i)\\b(no|off|false|0)\\s*$'" "$guest_entry" ||
    fail "BCD flag parsing is not fail-closed"
rg -Fq 'Microsoft Windows Hardware Compatibility Publisher' "$guest_entry" ||
    fail "guest entry lacks the production signer gate"
if rg -Fq 'Get-WindowsDriver -Online -Driver $infName' "$guest_entry"; then
    fail "guest entry incorrectly requires one expanded DISM model row"
fi
rg -Fq '$package = $packages[0]' "$guest_entry" ||
    fail "guest entry does not retain the unique package-level DriverStore row"
rg -Fq '([string]$package.OriginalFileName)' "$guest_entry" ||
    fail "guest entry does not use the package-level canonical DriverStore INF"
rg -Fq 'CatalogFile(?:\.[A-Za-z0-9_.-]+)?' "$guest_entry" ||
    fail "guest entry does not resolve the actual DriverStore catalog"
rg -Fq "Get-AuthenticodeSignature -LiteralPath \$catalogItem.FullName" \
    "$guest_entry" || fail "guest entry does not authenticate the driver catalog"
rg -Fq "CompanyName -notmatch '\\ANVIDIA(?: Corporation)?\\z'" "$guest_entry" ||
    fail "guest entry lacks exact NVIDIA CompanyName validation"
rg -Fq 'MICROSOFT_ROOT_DISABLE_FLIGHT_ROOT = 0x00040000' "$guest_entry" ||
    fail "guest entry does not exclude Microsoft test/Flight roots"
rg -Fq 'chainContext, 11, 0' "$guest_entry" ||
    fail "guest entry lacks the positive Third Party Root membership policy"
rg -Fq 'CERT_CHAIN_POLICY_SSL_F12 == (LPCSTR)9' "$guest_entry" ||
    fail "guest entry does not enforce Microsoft Root Program compliance"
rg -Fq 'CryptQueryObject' "$guest_entry" ||
    fail "guest entry does not reuse PKCS#7-embedded intermediate certificates"
rg -Fq 'CERT_CHAIN_CACHE_ONLY_URL_RETRIEVAL' "$guest_entry" ||
    fail "guest entry does not prohibit network retrieval during its strict chain rebuild"
rg -Fq 'CERT_CHAIN_DISABLE_AIA' "$guest_entry" ||
    fail "guest entry does not disable AIA during its strict chain rebuild"
rg -Fq 'locally trusted/private root' "$guest_entry" ||
    fail "guest entry does not explicitly reject a private local trust root"
rg -Fq 'GetFinalPathNameByHandleW' "$guest_entry" ||
    fail "guest entry cannot resolve SUBST/DOS-device aliases by handle"
rg -Fq "Assert-OutsideWindowsTree \$ApplicationDirectory" "$guest_entry" ||
    fail "guest entry does not recheck the final app-local directory identity"
rg -Fq '$item = Resolve-FinalRegularLocalPath $item.FullName $Context' \
    "$guest_entry" ||
    fail "guest entry does not use the real DOS path for ACL/install/launch operations"
rg -Fq 'SetAccessRuleProtection($true, $false)' "$guest_entry" ||
    fail "guest entry does not protect ProgramData ACL inheritance"
rg -Fq 'FileAttributes]::ReparsePoint' "$guest_entry" ||
    fail "guest entry lacks reparse-point rejection"
rg -Fq "'S-1-5-18'" "$guest_entry" ||
    fail "guest entry lacks an explicit SYSTEM ACL"
rg -Fq "'S-1-5-32-544'" "$guest_entry" ||
    fail "guest entry lacks an explicit Administrators ACL"
rg -Fq 'Assert-TrustedGpuZWriteBoundary $item $Context' "$guest_entry" ||
    fail "guest entry does not reject a low-privilege-writable GPU-Z path"
rg -Fq 'untrusted write/delete/control' "$guest_entry" ||
    fail "guest entry lacks the GPU-Z ACL TOCTOU gate"
rg -Fq '$ineffectiveAtThisBoundary =' "$guest_entry" ||
    fail "guest entry does not classify inherit-only ACEs at each boundary"
rg -Fq '$ineffectiveAtThisBoundary)' "$guest_entry" ||
    fail "guest entry does not ignore every ineffective inherit-only boundary ACE"
for app_local_acl_gate in \
        "Assert-TrustedGpuZWriteBoundary \$targetItem 'app-local nvapi.dll'" \
        "Assert-TrustedGpuZWriteBoundary \$originalItem 'app-local nvapi_orig.dll'" \
        'Assert-TrustedGpuZWriteBoundary $probeItem `' \
        "Assert-TrustedGpuZWriteBoundary \$launchTarget \`"; do
    rg -Fq "$app_local_acl_gate" "$guest_entry" ||
        fail "guest entry lacks app-local ACL gate: $app_local_acl_gate"
done
rg -Fq 'Assert-SystemNvapiUnchanged' "$guest_entry" ||
    fail "guest entry lacks system NVAPI immutability verification"
rg -Fq "'zero hardware RT/Tensor cores'" "$guest_entry" ||
    fail "guest entry does not verify zero RT/Tensor cores for pre-RTX profiles"
rg -Fq "'app-local PCI identifiers'" "$guest_entry" ||
    fail "guest entry does not verify the catalog PCI tuple through the app-local shim"
[[ "$(rg -c '^\s*Assert-NormalCodeIntegrityBoot\s*$' "$guest_entry")" -ge 2 ]] ||
    fail "guest entry does not recheck BCD after installation"
[[ "$(rg -c '^\s*\$finalDisplayState = Get-HealthyDisplayState' \
        "$guest_entry")" -eq 1 ]] ||
    fail "guest entry does not recheck signed topology after installation"
rg -Fq 'GPU-Z must not be installed below the Windows system directory.' \
    "$guest_entry" ||
    fail "guest entry can place app-local assets below the Windows system directory"
if rg -Fq '[string]$GpuZExe' "$guest_entry" ||
        rg -Fq 'DefaultGpuZExe' "$guest_entry"; then
    fail "guest entry retains an external/default GPU-Z path contract"
fi
rg -Fq "\$ApplicationsRoot = Join-Path \$InstallRoot 'applications'" \
    "$guest_entry" ||
    fail "guest entry lacks its protected content-addressed applications root"
rg -Fq '$null = Initialize-AdminSystemDirectory $ApplicationsRoot `' \
    "$guest_entry" ||
    fail "guest entry does not initialize the shared applications root"
rg -Fq "'GPU-Z applications root' -AllowUsersReadExecute" "$guest_entry" ||
    fail "guest entry does not validate Users RX on the applications root"
rg -Fq "'GPU-Z persistent application directory' -AllowUsersReadExecute" \
    "$guest_entry" ||
    fail "guest entry does not validate Users RX on the installed GPU-Z directory"
rg -Fq '$null = Initialize-AdminSystemDirectory $stagingDirectory `' \
    "$guest_entry" ||
    fail "guest entry does not initialize the private GPU-Z staging directory"
rg -Fq "'S-1-5-32-545'" "$guest_entry" ||
    fail "guest entry lacks the explicit BUILTIN Users SID"
rg -Fq '[Security.AccessControl.FileSystemRights]::ReadAndExecute' \
    "$guest_entry" ||
    fail "guest entry does not grant the protected application tree Users RX"
rg -Fq 'Assert-UsersReadExecuteAccess $item.FullName $Context' \
    "$guest_entry" ||
    fail "guest entry does not require effective Users RX on every validated GPU-Z image"
for users_rx_gate in \
        'Assert-UsersReadExecuteAccess $targetItem.FullName `' \
        'Assert-UsersReadExecuteAccess $originalItem.FullName `' \
        'Assert-UsersReadExecuteAccess $launchTarget.FullName `' \
        'Assert-UsersReadExecuteAccess $launchOriginal.FullName `'; do
    rg -Fq "$users_rx_gate" "$guest_entry" ||
        fail "guest app-local/launch path lacks effective Users RX gate: $users_rx_gate"
done
for dangerous_application_right in \
        WriteData AppendData WriteExtendedAttributes WriteAttributes \
        Delete DeleteSubdirectoriesAndFiles ChangePermissions TakeOwnership; do
    rg -Fq "[Security.AccessControl.FileSystemRights]::$dangerous_application_right" \
        "$guest_entry" ||
        fail "guest application ACL gate omits dangerous right: $dangerous_application_right"
done
rg -Fq "'contract.schemaVersion' 2 2" "$guest_entry" ||
    fail "guest entry does not require GPU-Z contract schema 2"
rg -Fq "'name', 'bytes', 'productVersion', 'sha256'" "$guest_entry" ||
    fail "guest entry does not enforce the exact contract.gpuz fields"
rg -Fq '$gpuzBytes -ne 11642144' "$guest_entry" ||
    fail "guest entry does not lock the raw GPU-Z byte count"
rg -Fq '6CB0EF29682452DE81A9576808881685161411A1FAD00938BA04131159979C29' \
    "$guest_entry" || fail "guest entry does not lock the raw GPU-Z hash"
rg -Fq '$manifestGpuZHash -cne $gpuzSha256' "$guest_entry" ||
    fail "guest entry does not bind the contract GPU-Z hash to the manifest"
rg -Fq '$manifestGpuZBytes -ne $gpuzBytes' "$guest_entry" ||
    fail "guest entry does not bind the contract GPU-Z bytes to the manifest"
rg -Fq "'.{0}.{1}.tmp' -f \$versionName, [Guid]::NewGuid().ToString('N')" \
    "$guest_entry" ||
    fail "guest entry does not use a randomized private GPU-Z staging directory"
rg -Fq 'Copy-Item -LiteralPath $source.FullName -Destination $stagedPath' \
    "$guest_entry" || fail "guest entry does not copy the manifest-bound raw GPU-Z asset"
rg -Fq "Get-GpuZRawEvidence \$Contract \$stagedPath" "$guest_entry" ||
    fail "guest entry does not validate the private GPU-Z staging copy"
rg -Fq '[IO.Directory]::Move($stagingDirectory, $targetDirectory)' \
    "$guest_entry" || fail "guest entry does not atomically publish the validated GPU-Z tree"
rg -Fq '$evidence = Get-ValidatedGpuZ $Contract' "$guest_entry" ||
    fail "guest entry cannot safely reuse an existing/concurrently published GPU-Z tree"
rg -Fq '[Environment+SpecialFolder]::CommonDesktopDirectory' "$guest_entry" ||
    fail "guest entry does not use the fixed Public Desktop namespace"
rg -Fq "\$shortcutName = 'GPU-Z (vGPU profile).lnk'" "$guest_entry" ||
    fail "guest entry does not own one fixed GPU-Z Public Desktop shortcut"
rg -Fq "'.GPU-Z-vGPU-{0}.tmp.lnk' -f [Guid]::NewGuid().ToString('N')" \
    "$guest_entry" ||
    fail "guest entry does not stage the shortcut under a randomized sibling"
rg -Fq '$shortcut.TargetPath = $ApplicationExe' "$guest_entry" ||
    fail "guest shortcut does not target the installed GPU-Z executable"
rg -Fq '$shortcut.WorkingDirectory = Split-Path -Parent $ApplicationExe' \
    "$guest_entry" ||
    fail "guest shortcut does not use the installed GPU-Z directory"
rg -Fq 'Move-Item -LiteralPath $temporaryPath -Destination $shortcutPath `' \
    "$guest_entry" ||
    fail "guest shortcut is not atomically replaced from its sibling staging file"
rg -Fq 'gpuZ = $gpuZEvidence' "$guest_entry" ||
    fail "guest receipt omits the final raw GPU-Z evidence"
rg -Fq 'gpuZShortcut = $shortcutEvidence' "$guest_entry" ||
    fail "guest receipt omits the validated Public Desktop shortcut"
rg -Fq "'.last-result.{0}.new' -f [Guid]::NewGuid().ToString('N')" \
    "$guest_entry" ||
    fail "guest receipt does not use a randomized same-directory staging file"
rg -Fq 'Set-Content -LiteralPath $temporaryPath -Encoding UTF8 `' \
    "$guest_entry" || fail "guest receipt is not serialized into its private staging file"
rg -Fq 'Move-Item -LiteralPath $temporaryItem.FullName `' "$guest_entry" ||
    fail "guest receipt is not atomically moved into place"
rg -Fq '(Get-Sha256 $publishedItem.FullName) -cne $expectedHash' \
    "$guest_entry" || fail "guest receipt is not hash-verified after publication"
for raw_gpuz_field in \
        'path = $item.FullName' \
        'name = $item.Name' \
        'bytes = [int64]$item.Length' \
        'sha256 = $sha256' \
        'productVersion = $rawProductVersion' \
        'fileVersion = [string]$version.FileVersion' \
        'companyName = [string]$version.CompanyName' \
        'signatureStatus = [string]$signature.Status' \
        'signerSubject = [string]$signature.SignerCertificate.Subject' \
        'signerIssuer = [string]$signature.SignerCertificate.Issuer'; do
    rg -Fq "$raw_gpuz_field" "$guest_entry" ||
        fail "guest raw GPU-Z receipt evidence omits: $raw_gpuz_field"
done
python3 - "$guest_entry" <<'PY'
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
state = re.search(
    r"function Initialize-ProtectedState \{(?P<body>.*?)^\}",
    source,
    flags=re.MULTILINE | re.DOTALL,
)
assert state
state_body = state.group("body")
assert "Initialize-AdminSystemDirectory $path" in state_body
assert "Initialize-AdminSystemDirectory $path `" not in state_body
assert (
    "Initialize-AdminSystemDirectory $ApplicationsRoot `\n"
    "        -AllowUsersReadExecute"
) in state_body
shortcut_validator = re.search(
    r"function Get-ValidatedGpuZShortcut \{(?P<body>.*?)^\}",
    source,
    flags=re.MULTILINE | re.DOTALL,
)
assert shortcut_validator
assert "Assert-UsersReadExecuteAccess" not in shortcut_validator.group("body")
main_start = source.index("function Invoke-Main")
verify_start = source.index("    if ($VerifyOnly) {", main_start)
verify_end = source.index("    Initialize-ProtectedState", verify_start)
body = source[verify_start:verify_end]
assert "Get-ValidatedGpuZ $contract" in body
assert "Install-ProtectedGpuZ" not in body
assert "Install-PublicGpuZShortcut" not in body
PY
rg -Fq '%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe' \
    "$packager" || fail "RUN command does not pin system Windows PowerShell"
rg -Fq -- '-PassThru -Wait' "$packager" ||
    fail "RUN command does not wait for the elevated child"
rg -Fq 'exit [int]$p.ExitCode' "$packager" ||
    fail "RUN command does not propagate the elevated exit code"
rg -Fq 'CreateProcessW(powershell' "$launcher_source" ||
    fail "single EXE does not directly launch fixed system PowerShell"
rg -Fq 'CREATE_UNICODE_ENVIRONMENT' "$launcher_source" ||
    fail "single EXE does not pass an explicit clean environment block"
rg -Fq 'PROC_THREAD_ATTRIBUTE_HANDLE_LIST' "$launcher_source" ||
    fail "single EXE does not restrict inherited handles to the three standard streams"
rg -Fq 'STARTF_USESTDHANDLES' "$launcher_source" ||
    fail "single EXE does not forward redirected stdout/stderr to inner PowerShell"
rg -Fq 'inherited COR_*, COMPLUS_* or DOTNET_*' "$launcher_source" ||
    fail "single EXE does not exclude CLR profiler environment injection"
rg -Fq 'ln -T -- "$SINGLE_EXE_TEMP" "$STABLE_EXE_STAGE"' "$packager" ||
    fail "stable EXE inode is not prepared with no-replace publication"
rg -Fq 'mv -Tf -- "$STABLE_EXE_STAGE" "$OUTPUT_EXE"' "$packager" ||
    fail "stable EXE update is not one same-filesystem rename"
rg -Fq 'exec {PACKAGE_LOCK_FD}<"$LOCK_DIR"' "$packager" ||
    fail "packager does not lock the pinned output-parent directory"
rg -Fq 'gpuz_asset_snapshot "$GPUZ_SOURCE" "$BUNDLE/$GPUZ_ASSET_BUNDLE_NAME"' \
    "$packager" ||
    fail "packager does not validate and bundle a private GPU-Z source snapshot"
if rg -Fq '.gpuz-profile-package.lock' "$packager"; then
    fail "packager still opens a fixed attacker-controlled lock-file path"
fi
rg -Fq 'level="requireAdministrator" uiAccess="false"' "$launcher_manifest" ||
    fail "single EXE does not elevate before extraction"

while IFS='|' read -r vm_id profile name pnp; do
    create_vm "$vm_id" "$profile"
    bundle="$tmp/bundle-vm${vm_id}"
    package_vm "$vm_id" "$bundle"
    assert_profile_bundle "$bundle" "$vm_id" "$profile" "$name" B "$pnp"
done <<'EOF'
4|gtx750ti_2gb|NVIDIA GeForce GTX 750 Ti|PCI\VEN_10DE&DEV_1E30
5|gt1030_2gb|NVIDIA GeForce GT 1030|PCI\VEN_10DE&DEV_1E30
6|gtx1050_2gb|NVIDIA GeForce GTX 1050|PCI\VEN_10DE&DEV_1E30
EOF
[[ -d "$vm_root/shared/bases" && -d "$vm_root/control" &&
   ! -e "$vm_root/instances" ]] ||
    fail "temporary VM storage did not use vmN/shared/bases/control layout"

# An explicit stable EXE name is supported when it shares the trusted output
# parent with the expanded host bundle.
custom_bundle="$tmp/custom-bundle-vm5"
custom_exe="$tmp/custom-gpuz-vm5.exe"
VM_ROOT="$vm_root" IMAGE_ROOT="$image_root" STAGE_DIR="$stage_dir" \
    bash "$packager" 5 --output-dir "$custom_bundle" \
    --output-exe "$custom_exe" >/dev/null
assert_manifest "$custom_bundle" 5
assert_single_exe "$custom_bundle" 5 "$custom_exe"
mkdir "$tmp/custom-parent-a" "$tmp/custom-parent-b"
chmod 0755 "$tmp/custom-parent-a" "$tmp/custom-parent-b"
if VM_ROOT="$vm_root" IMAGE_ROOT="$image_root" STAGE_DIR="$stage_dir" \
        bash "$packager" 5 \
        --output-dir "$tmp/custom-parent-a/bundle" \
        --output-exe "$tmp/custom-parent-b/custom.exe" \
        >/dev/null 2>&1; then
    fail "packager accepted --output-exe outside the bundle's trusted parent"
fi
collision_exe="$tmp/collision.exe"
collision_bundle="$tmp/.collision.exe.receipts"
if VM_ROOT="$vm_root" IMAGE_ROOT="$image_root" STAGE_DIR="$stage_dir" \
        bash "$packager" 5 \
        --output-dir "$collision_bundle" \
        --output-exe "$collision_exe" >/dev/null 2>&1; then
    fail "packager accepted a bundle/receipt-directory path collision"
fi
[[ ! -e "$collision_bundle" && ! -e "$collision_exe" ]] ||
    fail "bundle/receipt-directory collision polluted the output parent"
if VM_ROOT="$vm_root" IMAGE_ROOT="$image_root" STAGE_DIR="$stage_dir" \
        bash "$packager" 456x --output-root "$tmp/invalid-id-output" \
        >/dev/null 2>&1; then
    fail "packager accepted a non-numeric VM_ID suffix"
fi
if VM_ROOT="$vm_root" IMAGE_ROOT="$image_root" STAGE_DIR="$stage_dir" \
        bash "$packager" 2147483648 --output-root "$tmp/oversized-id-output" \
        >/dev/null 2>&1; then
    fail "packager accepted a VM_ID beyond the launcher contract"
fi

# Arbitrary positive VM IDs share one guest-visible filename.  The host keeps
# each UUID-bound payload in its own namespace, so adding vm456 needs no new
# filename or VM-number branch.
create_vm 456 gtx1050_2gb
generic_output_root="$tmp/generic-output"
VM_ROOT="$vm_root" IMAGE_ROOT="$image_root" STAGE_DIR="$stage_dir" \
    bash "$packager" --all --output-root "$generic_output_root" >/dev/null
declare -A generic_namespaces=()
for batch_vm_id in 4 5 6 456; do
    configured_uuid=$(vm_config_value "$vm_root" "$batch_vm_id" VM_UUID)
    namespace=$(generic_namespace "$generic_output_root" "$vm_root" \
        "$batch_vm_id")
    bundle="$namespace/.host-bundle"
    exe="$namespace/GpuZProfile.exe"
    [[ "$(basename -- "$exe")" == GpuZProfile.exe ]] ||
        fail "vm$batch_vm_id guest-visible EXE name is VM-specific"
    [[ "$(basename -- "$namespace")" == \
       "vm${batch_vm_id}-${configured_uuid,,}" ]] ||
        fail "vm$batch_vm_id namespace is not bound to its configured UUID"
    [[ -z "${generic_namespaces[$namespace]+x}" ]] ||
        fail "vm$batch_vm_id reused another VM's output namespace"
    generic_namespaces["$namespace"]=1
    assert_manifest "$bundle" "$batch_vm_id"
    assert_single_exe "$bundle" "$batch_vm_id" "$exe"
done
[[ "${#generic_namespaces[@]}" -eq 4 ]] ||
    fail "arbitrary VM IDs did not receive four isolated UUID namespaces"
[[ "$(find "$generic_output_root" -mindepth 1 -maxdepth 1 -type d \
    -name 'vm*-*' | wc -l)" -eq 4 ]] ||
    fail "--output-root published an unexpected namespace"

# A lifecycle-disabled instance is skipped successfully by --all.  Retirement
# is data-driven; no VM number is special-cased in the packager.
disabled_image="$tmp/disabled-images"
disabled_vm_root="$tmp/disabled-vms"
disabled_stage="$tmp/disabled-staging"
VM_ROOT="$disabled_vm_root" IMAGE_ROOT="$disabled_image" \
STAGE_DIR="$disabled_stage" \
    bash "$root/deploy/scripts/create-vm.sh" 73 \
    --gpu-profile gtx1050_2gb >/dev/null
touch "$disabled_vm_root/73/disk.qcow2"
disabled_conf="$disabled_vm_root/73/vm.conf"
chmod 0600 "$disabled_conf"
sed -i '/^GPUZ_PACKAGE_ENABLED=/d' "$disabled_conf"
printf '\nGPUZ_PACKAGE_ENABLED=0\n' >>"$disabled_conf"
chmod 0444 "$disabled_conf"
disabled_output_root="$tmp/disabled-output"
VM_ROOT="$disabled_vm_root" IMAGE_ROOT="$disabled_image" \
STAGE_DIR="$disabled_stage" \
    bash "$packager" --all --output-root "$disabled_output_root" >/dev/null
[[ ! -e "$(generic_namespace "$disabled_output_root" \
    "$disabled_vm_root" 73)" ]] ||
    fail "--all published lifecycle-disabled vm73"
if VM_ROOT="$disabled_vm_root" IMAGE_ROOT="$disabled_image" \
        STAGE_DIR="$disabled_stage" \
        bash "$packager" 73 --output-root "$disabled_output_root" \
        >/dev/null 2>&1; then
    fail "direct packaging ignored GPUZ_PACKAGE_ENABLED=0 for vm73"
fi
if VM_ROOT="$disabled_vm_root" IMAGE_ROOT="$disabled_image" \
        STAGE_DIR="$disabled_stage" \
        bash "$packager" --all --output-root relative-output \
        >/dev/null 2>&1; then
    fail "all-disabled batch accepted a relative --output-root"
fi

# Batch discovery must reject an instance-directory symlink without sourcing
# the target config, even if that target declares itself lifecycle-disabled.
symlink_image="$tmp/symlink-images"
symlink_vm_root="$tmp/symlink-vms"
symlink_stage="$tmp/symlink-staging"
mkdir -p "$symlink_vm_root" "$tmp/symlink-target/75"
printf 'VM_ID=75\nGPUZ_PACKAGE_ENABLED=0\n' \
    >"$tmp/symlink-target/75/vm.conf"
ln -s "$tmp/symlink-target/75" \
    "$symlink_vm_root/75"
if VM_ROOT="$symlink_vm_root" IMAGE_ROOT="$symlink_image" \
        STAGE_DIR="$symlink_stage" \
        bash "$packager" --all --output-root "$tmp/symlink-output" \
        >/dev/null 2>&1; then
    fail "batch mode followed a symlinked VM instance directory"
fi
[[ ! -e "$tmp/symlink-output" ]] ||
    fail "symlinked instance rejection published an output"

# A vm.conf can never redirect a request into another VM namespace.  The
# directory/CLI identity remains authoritative and must exactly match the
# persisted instance identity before any output path is prepared.
create_vm 74 gtx1050_2gb
mismatched_id_conf="$vm_root/74/vm.conf"
chmod 0600 "$mismatched_id_conf"
sed -i 's/^VM_ID=.*/VM_ID=456/' "$mismatched_id_conf"
chmod 0444 "$mismatched_id_conf"
if package_vm 74 "$tmp/mismatched-vm-id" 2>/dev/null; then
    fail "packager allowed vm.conf to override the requested VM_ID"
fi
[[ ! -e "$tmp/mismatched-vm-id" &&
   ! -e "$tmp/mismatched-vm-id.exe" ]] ||
    fail "VM_ID mismatch published an output"
# The fleet identity gate intentionally rejects every later create while a
# malformed numeric instance remains in VM_ROOT.  Restore this negative
# fixture before the shared root is reused by the remaining package cases.
chmod 0600 "$mismatched_id_conf"
sed -i 's/^VM_ID=.*/VM_ID=74/' "$mismatched_id_conf"
chmod 0444 "$mismatched_id_conf"

# Batch mode continues after an early invalid VM, publishes later valid VMs,
# and still returns nonzero overall.
partial_image="$tmp/partial-images"
partial_vm_root="$tmp/partial-vms"
partial_stage="$tmp/partial-staging"
mkdir -p "$partial_image/candidates/gpuz-2.70-audit"
install -m 0600 -- "$locked_gpuz_source" \
    "$partial_image/candidates/gpuz-2.70-audit/GPU-Z.2.70.0.exe"
for partial_id_profile in '71 gtx1050_2gb' '72 gt1030_2gb'; do
    read -r partial_id partial_profile <<<"$partial_id_profile"
    VM_ROOT="$partial_vm_root" IMAGE_ROOT="$partial_image" \
    STAGE_DIR="$partial_stage" \
        bash "$root/deploy/scripts/create-vm.sh" "$partial_id" \
        --gpu-profile "$partial_profile" >/dev/null
    touch "$partial_vm_root/${partial_id}/disk.qcow2"
done
partial_bad_conf="$partial_vm_root/71/vm.conf"
chmod 0600 "$partial_bad_conf"
sed -i \
    -e 's/^SPOOF_MODE=.*/SPOOF_MODE=A/' \
    -e '/^VGPU_IDENTITY_TARGET=/d' \
    "$partial_bad_conf"
printf '\nVGPU_MDEV_INTERNAL_PCI_IDENTITY=1\nVGPU_MDEV_FRL_ENABLED=0\nVGPU_PATCHED_DRIVER_VERSION=31.0.15.3833\n' \
    >>"$partial_bad_conf"
chmod 0444 "$partial_bad_conf"
if VM_ROOT="$partial_vm_root" IMAGE_ROOT="$partial_image" \
        STAGE_DIR="$partial_stage" \
        bash "$packager" --all >/dev/null 2>&1; then
    fail "batch mode returned success despite one invalid VM"
fi
partial_output_root="$partial_stage/GpuZProfile"
partial_bad_namespace=$(generic_namespace "$partial_output_root" \
    "$partial_vm_root" 71)
partial_good_namespace=$(generic_namespace "$partial_output_root" \
    "$partial_vm_root" 72)
[[ ! -e "$partial_bad_namespace" ]] ||
    fail "batch mode published the invalid VM namespace"
assert_single_exe "$partial_good_namespace/.host-bundle" 72 \
    "$partial_good_namespace/GpuZProfile.exe"

# A is a narrowly pinned GTX 1050 transport contract. The guest still refuses
# it unless both the installed PnP package and loaded kernel image are
# production-signed and normal code-integrity boot is active.
create_vm 64 gtx1050_2gb
a_conf="$vm_root/64/vm.conf"
chmod 0600 "$a_conf"
sed -i \
    -e 's/^SPOOF_MODE=.*/SPOOF_MODE=A/' \
    -e 's/^VGPU_IDENTITY_TARGET=.*/VGPU_IDENTITY_TARGET=full-consumer/' \
    "$a_conf"
printf '\nVGPU_MDEV_INTERNAL_PCI_IDENTITY=1\nVGPU_MDEV_FRL_ENABLED=0\nVGPU_PATCHED_DRIVER_VERSION=31.0.15.3833\n' \
    >>"$a_conf"
chmod 0444 "$a_conf"
a_bundle="$tmp/bundle-vm64"
package_vm 64 "$a_bundle"
assert_profile_bundle "$a_bundle" 64 gtx1050_2gb \
    'NVIDIA GeForce GTX 1050' A \
    'PCI\VEN_10DE&DEV_1C81&SUBSYS_11C01028&REV_A1'

# A non-GTX1050 profile must remain B-only.
create_vm 65 gt1030_2gb
bad_a_conf="$vm_root/65/vm.conf"
chmod 0600 "$bad_a_conf"
sed -i \
    -e 's/^SPOOF_MODE=.*/SPOOF_MODE=A/' \
    -e 's/^VGPU_IDENTITY_TARGET=.*/VGPU_IDENTITY_TARGET=full-consumer/' \
    "$bad_a_conf"
printf '\nVGPU_MDEV_INTERNAL_PCI_IDENTITY=1\nVGPU_MDEV_FRL_ENABLED=0\nVGPU_PATCHED_DRIVER_VERSION=31.0.15.3833\n' \
    >>"$bad_a_conf"
chmod 0444 "$bad_a_conf"
if package_vm 65 "$tmp/forbidden-a" 2>/dev/null; then
    fail "A mode accepted a GT 1030 profile"
fi

# A GTX 1050 must still refuse the current VM3-like incomplete state when the
# explicit full-consumer completion marker is absent.
create_vm 67 gtx1050_2gb
incomplete_a_conf="$vm_root/67/vm.conf"
chmod 0600 "$incomplete_a_conf"
sed -i \
    -e 's/^SPOOF_MODE=.*/SPOOF_MODE=A/' \
    -e '/^VGPU_IDENTITY_TARGET=/d' \
    "$incomplete_a_conf"
printf '\nVGPU_MDEV_INTERNAL_PCI_IDENTITY=1\nVGPU_MDEV_FRL_ENABLED=0\nVGPU_PATCHED_DRIVER_VERSION=31.0.15.3833\n' \
    >>"$incomplete_a_conf"
chmod 0444 "$incomplete_a_conf"
if package_vm 67 "$tmp/incomplete-gtx1050-a" 2>/dev/null; then
    fail "A mode accepted GTX 1050 without VGPU_IDENTITY_TARGET=full-consumer"
fi

# Legacy sparse B configs inherit catalog overlays and ignore stale consumer
# PCI tuples because B retains the native DEV_1E30 endpoint.
create_vm 66 gt1030_2gb
sparse_conf="$vm_root/66/vm.conf"
chmod 0600 "$sparse_conf"
sed -i -E \
    -e '/^(GPU_NAME|GPU_VRAM_MB|GPU_VBIOS|GPU_CORE_MHZ|GPU_BOOST_MHZ|GPU_MEMORY_MHZ|GPU_MEMORY_BUS_BITS|GPU_MEMORY_BANDWIDTH_MBPS|GPU_MEMORY_TYPE|GPU_MEMORY_MAKER|GPU_MEMORY_TYPE_NVAPI|GPU_MEMORY_MAKER_NVAPI|GPU_CUDA_CORES|GPU_SHADER_SUBPIPES|GPU_ROP_COUNT|GPU_TMU_COUNT|GPU_ARCHITECTURE|GPU_IMPLEMENTATION|GPU_CHIP_REVISION|GPU_PCIE_WIDTH|MONITOR_PROFILE|MONITOR_SERIAL)=/d' \
    -e 's/^GPU_PCI_DID=.*/GPU_PCI_DID=0x9999/' \
    -e 's/^GPU_SUB_DID=.*/GPU_SUB_DID=0x086B/' \
    -e 's/^GPU_REV=.*/GPU_REV=0xFF/' \
    "$sparse_conf"
chmod 0444 "$sparse_conf"
sparse_conf_before=$(file_sha256 "$sparse_conf")
sparse_bundle="$tmp/bundle-vm66"
package_vm 66 "$sparse_bundle"
[[ "$(file_sha256 "$sparse_conf")" == "$sparse_conf_before" ]] ||
    fail "legacy monitor fallback changed the live vm.conf"
assert_profile_bundle "$sparse_bundle" 66 gt1030_2gb \
    'NVIDIA GeForce GT 1030' B 'PCI\VEN_10DE&DEV_1E30'
jq -e '
    .monitor.profile == "asus-va24e" and
    .monitor.serial == "KCLMC045CE2A"
' "$sparse_bundle/gpu-profile.json" >/dev/null ||
    fail "legacy monitor fallback was not confined to deterministic transport metadata"

# Never replace an arbitrary existing directory, and never overlap an instance
# or source tree. The sentinel proves failure happened without deletion.
arbitrary="$tmp/do-not-touch"
mkdir -p "$arbitrary"
printf 'user-data\n' >"$arbitrary/sentinel"
if package_vm 4 "$arbitrary" 2>/dev/null; then
    fail "packager replaced an arbitrary existing directory"
fi
grep -Fxq user-data "$arbitrary/sentinel" ||
    fail "arbitrary output sentinel changed"
if package_vm 4 "$vm_root/4/output" 2>/dev/null; then
    fail "packager accepted output inside the VM instance"
fi
if package_vm 4 "$root/deploy/.forbidden-gpuz-output" 2>/dev/null; then
    fail "packager accepted output inside its source tree"
fi
if VM_ROOT="$vm_root" IMAGE_ROOT="$image_root" STAGE_DIR="$stage_dir" \
        bash "$packager" 4 --output-dir "$tmp/obsolete-gpuz-path" \
        --gpuz-exe 'C:\Program Files (x86)\GPU-Z\GPU-Z.exe' \
        >/dev/null 2>&1; then
    fail "packager retained the obsolete guest GPU-Z path option"
fi
bad_gpuz_source="$tmp/not-gpuz.exe"
printf 'not GPU-Z\n' >"$bad_gpuz_source"
if VM_ROOT="$vm_root" IMAGE_ROOT="$image_root" STAGE_DIR="$stage_dir" \
        bash "$packager" 4 --output-dir "$tmp/bad-gpuz-source" \
        --gpuz-source "$bad_gpuz_source" >/dev/null 2>&1; then
    fail "packager accepted a GPU-Z source with the wrong size/hash"
fi
ln -s "$locked_gpuz_source" "$tmp/gpuz-source-symlink.exe"
if VM_ROOT="$vm_root" IMAGE_ROOT="$image_root" STAGE_DIR="$stage_dir" \
        bash "$packager" 4 --output-dir "$tmp/symlink-gpuz-source" \
        --gpuz-source "$tmp/gpuz-source-symlink.exe" >/dev/null 2>&1; then
    fail "packager accepted a symlinked GPU-Z source"
fi

insecure_parent="$tmp/insecure-output-parent"
mkdir "$insecure_parent"
chmod 0777 "$insecure_parent"
printf 'unrelated\n' >"$insecure_parent/sentinel"
if package_vm 4 "$insecure_parent/bundle" 2>/dev/null; then
    fail "packager accepted a group/other-writable output parent"
fi
grep -Fxq unrelated "$insecure_parent/sentinel" ||
    fail "insecure output-parent rejection changed unrelated data"

acl_parent="$tmp/acl-output-parent"
mkdir "$acl_parent"
if command -v setfacl >/dev/null 2>&1; then
    setfacl -m 'u:65534:rwx' "$acl_parent"
    acl_error=""
    if acl_error=$(package_vm 4 "$acl_parent/bundle" 2>&1); then
        fail "packager accepted an output parent carrying an extended POSIX ACL"
    fi
    [[ "$acl_error" == *"extended/default POSIX ACL"* ]] ||
        fail "extended POSIX ACL rejection did not report its safety boundary"
    [[ ! -e "$acl_parent/bundle" && ! -e "$acl_parent/bundle.exe" ]] ||
        fail "extended POSIX ACL rejection published an output"
fi

# Once the stable EXE is the commit point, a broken caller output stream must
# not turn a successful publication into a reported failure.
closed_output_bundle="$tmp/closed-output-bundle"
if ! VM_ROOT="$vm_root" IMAGE_ROOT="$image_root" STAGE_DIR="$stage_dir" \
        bash "$packager" 4 --output-dir "$closed_output_bundle" >&- 2>&-; then
    fail "packager reported failure after committing with closed output streams"
fi
assert_single_exe "$closed_output_bundle" 4

# An owned bundle and its one stable EXE can be atomically refreshed for the
# same VM without leaving another guest-facing candidate, but cannot be
# silently repurposed for another VM.
unchanged_content_hash=$(file_sha256 "$tmp/bundle-vm4.exe")
vm4_conf="$vm_root/4/vm.conf"
chmod 0600 "$vm4_conf"
printf '\n# Host-only lifecycle note; not part of the guest payload.\n' >>"$vm4_conf"
chmod 0444 "$vm4_conf"
package_vm 4 "$tmp/bundle-vm4"
[[ "$(file_sha256 "$tmp/bundle-vm4.exe")" == "$unchanged_content_hash" ]] ||
    fail "irrelevant vm.conf metadata unexpectedly changed the guest EXE"
assert_profile_bundle "$tmp/bundle-vm4" 4 gtx750ti_2gb \
    'NVIDIA GeForce GTX 750 Ti' B 'PCI\VEN_10DE&DEV_1E30'

old_stable_hash=$(file_sha256 "$tmp/bundle-vm4.exe")
VM_ROOT="$vm_root" IMAGE_ROOT="$image_root" STAGE_DIR="$stage_dir" \
    bash "$packager" 4 --output-dir "$tmp/bundle-vm4" \
    --gpuz-source "$locked_gpuz_source" >/dev/null
assert_profile_bundle "$tmp/bundle-vm4" 4 gtx750ti_2gb \
    'NVIDIA GeForce GTX 750 Ti' B 'PCI\VEN_10DE&DEV_1E30'
[[ "$(file_sha256 "$tmp/bundle-vm4.exe")" == "$old_stable_hash" ]] ||
    fail "equivalent locked --gpuz-source changed the stable EXE"
[[ "$(find "$tmp" -mindepth 1 -maxdepth 1 -type f \
    -name 'bundle-vm4-*.exe' | wc -l)" -eq 0 ]] ||
    fail "stable EXE refresh left an ambiguous hash-suffixed sibling"
refreshed_manifest=$(file_sha256 "$tmp/bundle-vm4/bundle-manifest.json")
if package_vm 5 "$tmp/bundle-vm4" 2>/dev/null; then
    fail "packager replaced a bundle owned by another VM"
fi
[[ "$(file_sha256 "$tmp/bundle-vm4/bundle-manifest.json")" == \
   "$refreshed_manifest" && -s "$tmp/bundle-vm4/READY" ]] ||
    fail "cross-VM rejection changed the existing bundle"

# A three-file READY/manifest/contract lookalike is not sufficient ownership
# proof and must never be deleted.
lookalike="$tmp/lookalike"
mkdir "$lookalike"
printf '{"schemaVersion":1,"vmId":4}\n' >"$lookalike/gpuz-contract.json"
jq -n \
    --arg hash "$(file_sha256 "$lookalike/gpuz-contract.json")" \
    --argjson bytes "$(stat -c %s -- "$lookalike/gpuz-contract.json")" '
    {
        schemaVersion: 1,
        vmId: 4,
        files: [{
            name: "gpuz-contract.json",
            sha256: $hash,
            bytes: $bytes
        }]
    }' >"$lookalike/bundle-manifest.json"
printf 'schema_version=1\nmanifest_sha256=%s\n' \
    "$(file_sha256 "$lookalike/bundle-manifest.json")" >"$lookalike/READY"
lookalike_before=$(sha256sum "$lookalike"/*)
if package_vm 4 "$lookalike" 2>/dev/null; then
    fail "packager replaced an incomplete lookalike bundle"
fi
[[ "$(sha256sum "$lookalike"/*)" == "$lookalike_before" ]] ||
    fail "lookalike rejection changed existing data"

# The old fixed lock-file attack must be inert. The packager now locks the
# canonical output-parent directory inode read-only.
lock_parent="$tmp/lock-parent"
mkdir "$lock_parent"
chmod 0755 "$lock_parent"
printf 'do-not-truncate\n' >"$tmp/lock-victim"
ln -s "$tmp/lock-victim" "$lock_parent/.gpuz-profile-package.lock"
package_vm 4 "$lock_parent/bundle"
grep -Fxq do-not-truncate "$tmp/lock-victim" ||
    fail "legacy lock-file symlink target was modified"

# A stable EXE without a trusted full-hash receipt is unrelated data.
unowned_bundle="$tmp/unowned-stable"
printf 'unrelated-exe\n' >"${unowned_bundle}.exe"
unowned_hash=$(file_sha256 "${unowned_bundle}.exe")
if package_vm 4 "$unowned_bundle" 2>/dev/null; then
    fail "packager replaced an unowned stable EXE"
fi
[[ "$(file_sha256 "${unowned_bundle}.exe")" == "$unowned_hash" ]] ||
    fail "unowned stable EXE changed"

# Receipt tampering invalidates replacement before either the expanded bundle
# or stable EXE is changed.
receipt_exe="$tmp/bundle-vm6.exe"
receipt_hash=$(file_sha256 "$receipt_exe")
receipt_file="$tmp/.bundle-vm6.exe.receipts/${receipt_hash}.json"
manifest_before=$(file_sha256 "$tmp/bundle-vm6/bundle-manifest.json")
printf '{}\n' >"$receipt_file"
chmod 0600 "$receipt_file"
if package_vm 6 "$tmp/bundle-vm6" 2>/dev/null; then
    fail "packager accepted a tampered stable-EXE receipt"
fi
[[ "$(file_sha256 "$receipt_exe")" == "$receipt_hash" &&
   "$(file_sha256 "$tmp/bundle-vm6/bundle-manifest.json")" == \
       "$manifest_before" ]] ||
    fail "receipt rejection changed a published output"

echo "PASS: generic GPU-Z packaging covers arbitrary VM IDs, 3 B profiles, and the production-signature-only strict-A boundary"
