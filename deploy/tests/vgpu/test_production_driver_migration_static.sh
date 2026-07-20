#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
guest="$here/guest/migrate-vgpu-production-driver.ps1"
packager="$here/package-vgpu-production-migration.sh"
commit="$here/commit-vgpu-production-migration.sh"
builder="$here/guest/vgpu-production-migration/build.sh"
launcher="$here/guest/vgpu-production-migration/vgpu_production_migration.c"
resource="$here/guest/vgpu-production-migration/vgpu_production_migration.rc"
migration_manifest="$here/guest/vgpu-production-migration/vgpu_production_migration.manifest"
docs="$here/docs/VGPU-PRODUCTION-MIGRATION.md"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}
require_text() {
    local pattern=$1 file=$2 label=$3
    rg -q -- "$pattern" "$file" || fail "$label"
}
reject_text() {
    local pattern=$1 file=$2 label=$3
    if rg -i -q -- "$pattern" "$file"; then
        fail "$label"
    fi
}

for file in "$guest" "$packager" "$commit" "$builder" "$launcher" \
        "$resource" "$migration_manifest" "$docs"; do
    [[ -s "$file" ]] || fail "missing migration asset: $file"
done
bash -n "$packager"
bash -n "$commit"
bash -n "$builder"
if missing_value_error=$(bash "$packager" 3 --driver-zip 2>&1); then
    fail 'packager accepts --driver-zip without a value'
fi
[[ "$missing_value_error" == \
   *'[vgpu-production-package] ERROR: --driver-zip requires a host ZIP file'* ]] \
    || fail 'packager reports a raw shell shift error for a missing option value'
if missing_value_error=$(bash "$builder" --contract 2>&1); then
    fail 'single EXE builder accepts --contract without a value'
fi
[[ "$missing_value_error" == \
   *'[vgpu-production-exe] ERROR: --contract requires a JSON file'* ]] \
    || fail 'single EXE builder reports a raw shell shift error for a missing option value'
reject_text 'vm_storage_prepare' "$packager" \
    'build-only packager can create live VM storage directories'
require_text 'requires a legacy A source VM' "$packager" \
    'A-to-B packager accepts a source mode its guest state machine cannot migrate'
require_text 'use --replace only before its EXE has ever run' "$packager" \
    'repackaging can silently invalidate an already staged migration receipt'
require_text 'output root group contains another writable user' "$packager" \
    'custom output root can be replaced by a lower-privilege host user'
require_text 'output root changed while waiting for the package lock' "$packager" \
    'packager locks a replaceable pathname instead of the trusted directory inode'
[[ "$(rg -F -c 'validate_existing_package "$OUTPUT_DIR"' "$packager")" == 2 ]] \
    || fail 'existing output metadata is not revalidated at publication'
require_text 'existing output contains missing, extra or unrelated entries' \
    "$packager" 'replacement can delete files unrelated to this package'
require_text 'existing migration EXE does not match its host-state metadata' \
    "$packager" 'replacement trusts stale/tampered EXE metadata'
require_text 'an output directory appeared during packaging; refusing to replace it without --replace' \
    "$packager" 'late-created output can be silently replaced'
require_text 'VM configuration changed while the package was being built; rebuild first' \
    "$packager" 'long package build can publish against a changed VM config'
require_text 'sudo ./deploy/commit-vgpu-production-migration\.sh \$\{VM_ID\} --output-root \$\{OUTPUT_ROOT_SHELL\}' \
    "$packager" 'success output omits the exact host commit command'
require_text '--gpuz-source FILE' "$packager" \
    'migration packager does not expose the host GPU-Z source option'
require_text '--gpuz-source "\$GPUZ_SOURCE"' "$packager" \
    'migration packager does not propagate the locked GPU-Z source to the nested package'
require_text 'declare -a payloads=\("\$CONTRACT" "\$SCRIPT" "\$DRIVER_ZIP" "\$GPUZ_EXE"\)' \
    "$builder" 'migration launcher no longer has exactly four outer payloads'
require_text 'FILEVERSION 1,1,0,0' "$resource" \
    'migration launcher numeric file version is not 1.1.0.0'
require_text 'PRODUCTVERSION 1,1,0,0' "$resource" \
    'migration launcher numeric product version is not 1.1.0.0'
require_text 'VALUE "FileVersion", "1\.1\.0\.0\\0"' "$resource" \
    'migration launcher display file version is not 1.1.0.0'
require_text 'VALUE "ProductVersion", "1\.1\.0\.0\\0"' "$resource" \
    'migration launcher display product version is not 1.1.0.0'
require_text 'assemblyIdentity version="1\.1\.0\.0"' "$migration_manifest" \
    'migration launcher assembly version is not 1.1.0.0'

driver_keys=$(
    awk '
        /driver: \{/ { inside=1; next }
        inside && /^[[:space:]]*},/ { exit }
        inside && /^[[:space:]]*[A-Za-z][A-Za-z0-9]*:/ {
            line=$0
            sub(/^[[:space:]]*/, "", line)
            sub(/:.*/, "", line)
            print line
        }
    ' "$packager" | sort
)
expected_driver_keys=$(
    printf '%s\n' archiveBytes archiveName archiveSha256 \
        catalogRelativePath catalogSha256 driverVersion \
        infRelativePath infSha256 | sort
)
[[ "$driver_keys" == "$expected_driver_keys" ]] \
    || fail 'migration contract driver object keys are duplicated/incomplete'

# The only bcdedit invocation is an all-entry read.  No bypass/self-signing
# primitive may enter the new production path.
require_text '\$SystemBcdEdit /enum all' "$guest" \
    'guest does not read every BCD entry'
reject_text '\$SystemBcdEdit[^\r\n]+/(set|deletevalue)' "$guest" \
    'guest writes BCD'
reject_text 'New-SelfSignedCertificate|Set-AuthenticodeSignature|Import-Certificate' \
    "$guest" 'guest can create/trust a replacement driver signature'
reject_text '^[[:space:]]*(\$[[:alnum:]_]+[[:space:]]*=[[:space:]]*|&[[:space:]]*)?New-FileCatalog([[:space:]`]|$)' \
    "$guest" 'guest invokes New-FileCatalog to replace the vendor catalog'
reject_text 'testsigning[[:space:]]+(on|yes)|nointegritychecks[[:space:]]+(on|yes)' \
    "$guest" 'guest enables an integrity bypass'

# A-phase must add-only, preserve the active device, and emit the receipt that
# the host consumes.  Test-FileCatalog only understands the relative-path
# attributes emitted by New-FileCatalog, not this Inf2Cat/WHCP driver catalog;
# Windows DriverStore staging is the authoritative catalog-member gate.
reject_text '^[[:space:]]*(\$[[:alnum:]_]+[[:space:]]*=[[:space:]]*|&[[:space:]]*)?(Microsoft\.PowerShell\.Security\\)?Test-FileCatalog([[:space:]`]|$)' \
    "$guest" 'guest invokes Test-FileCatalog on an Inf2Cat driver catalog'
require_text '\$zipItem\.Length -ne \$LockedArchiveBytes' "$guest" \
    'source archive byte count is not enforced'
require_text 'Get-Sha256 \$zipItem\.FullName\) -cne \$LockedArchiveSha256' \
    "$guest" 'source archive SHA-256 is not enforced'
require_text 'Get-Sha256 \$infPath\) -cne \$LockedInfSha256' "$guest" \
    'source/DriverStore INF SHA-256 is not enforced'
require_text 'Get-Sha256 \$catalogPath\) -cne \$LockedCatalogSha256' "$guest" \
    'source/DriverStore catalog SHA-256 is not enforced'
require_text '1935420A805A0CEFEBECDBE59A391A69DB32EAB3' "$guest" \
    'locked Microsoft WHCP leaf thumbprint is missing'
require_text 'CN=Microsoft Windows Hardware Compatibility Publisher' "$guest" \
    'catalog signer is not restricted to Microsoft WHCP'
require_text '\$thumbprint -cne \$LockedCatalogSignerThumbprint' "$guest" \
    'catalog signer thumbprint is not compared with the locked WHCP leaf'
require_text 'Assert-CatalogSignature \$catalogPath' "$guest" \
    'source catalog Authenticode signature is not validated'
require_text '& \$SystemPnpUtil /add-driver \$infPath' "$guest" \
    'original INF is not staged'
require_text 'if \(\$LASTEXITCODE -ne 0\)' "$guest" \
    'pnputil staging failure is not checked'
reject_text '/add-driver[^\r\n]*/install' "$guest" \
    'A-phase can bind/install the driver before the host switch'
require_text '\$packages = @\(Get-OriginalDriverPackages\)' "$guest" \
    'staged DriverStore package is not dynamically rediscovered'
reject_text '\$details\.Count -ne 1' "$guest" \
    'DriverStore package discovery incorrectly requires one expanded DISM model row'
reject_text '^[[:space:]]*[^#\r\n]*Get-WindowsDriver[[:space:]]+-Online[[:space:]]+-Driver' \
    "$guest" 'guest invokes DISM model-row expansion as a package lookup'
require_text '\$infPath = \[string\]\$driver\.OriginalFileName' "$guest" \
    'DriverStore package discovery does not use the package-level canonical INF path'
require_text 'if \(\$packages\.Count -ne 1\)' "$guest" \
    'staged DriverStore package is not required to be unique'
require_text 'driverStoreInfSha256 = Get-Sha256 \$stage\.Package\.InfPath' \
    "$guest" 'staged receipt omits the exact DriverStore INF hash'
require_text 'driverStoreCatalogSha256 = Get-Sha256 \$stage\.Package\.CatalogPath' \
    "$guest" 'staged receipt omits the exact DriverStore catalog hash'
require_text 'activeDriverChanged = \$false' "$guest" \
    'staged receipt omits active-driver preservation'
require_text 'activeInfBefore = \[string\]\$stage.ActiveInfBefore' "$guest" \
    'staged receipt omits the pre-add active INF'
require_text '\.activeInfAfter == \.activeInfBefore' "$commit" \
    'host does not prove active InfName stayed unchanged during add-only staging'
require_text "phase = 'staged'" "$guest" 'staged receipt is missing'
require_text 'ShutdownWhenStaged' "$guest" 'single-click full-stop handoff is missing'
require_text 'InitiateShutdownW' "$guest" \
    'guest does not use the native shutdown API'
require_text 'AdjustTokenPrivileges' "$guest" \
    'guest does not explicitly enable the shutdown privilege'
require_text 'SeShutdownPrivilege' "$guest" \
    'guest does not request SeShutdownPrivilege'
require_text 'ERROR_NOT_ALL_ASSIGNED' "$guest" \
    'guest does not reject a token lacking SeShutdownPrivilege'
require_text 'shutdownStatus != ERROR_SUCCESS' "$guest" \
    'guest ignores the InitiateShutdownW return code'
require_text 'GRACE_SECONDS = 30' "$guest" \
    'native system transition does not preserve the 30-second contract'
require_text 'SHUTDOWN_FORCE_OTHERS' "$guest" \
    'native system transition does not force other processes'
require_text 'SHUTDOWN_FORCE_SELF' "$guest" \
    'native system transition does not force the migration process'
require_text 'SHUTDOWN_POWEROFF' "$guest" \
    'A-phase cannot request a full poweroff'
require_text 'SHUTDOWN_RESTART' "$guest" \
    'B-phase cannot request a restart'
require_text 'SHTDN_REASON_MINOR_MAINTENANCE' "$guest" \
    'native system transition is not marked as maintenance'
require_text 'SHTDN_REASON_FLAG_PLANNED' "$guest" \
    'native system transition is not marked planned'
require_text '\[QemuVgpuShutdown\]::Schedule\(\$false\)' "$guest" \
    'A-phase does not request the native full-poweroff path'
require_text '\[QemuVgpuShutdown\]::Schedule\(\$true\)' "$guest" \
    'B-phase does not request the native restart path'
reject_text 'shutdown\.exe|\$SystemShutdown' "$guest" \
    'guest retains a shutdown.exe fallback'
reject_text 'SHUTDOWN_HYBRID' "$guest" \
    'native A-phase can silently use hybrid shutdown'
reject_text 'USERDOMAIN' "$guest" \
    'guest native shutdown depends on USERDOMAIN'
reject_text 'USERDOMAIN|shutdown\.exe' "$launcher" \
    'single-file launcher environment reintroduces the removed shutdown dependency'
require_text 'GetVolumePathNameW\(windows_root, volume_root, MAX_PATH\)' \
    "$launcher" \
    'single-file launcher does not derive the Windows system volume'
require_text 'system_drive\[0\] = volume_root\[0\]' "$launcher" \
    'single-file launcher does not derive SystemDrive from the Windows volume'
require_text 'L"SystemDrive", system_drive' "$launcher" \
    'single-file launcher omits SystemDrive from its clean child environment'
reject_text 'L"SystemDrive",[[:space:]]*L"[A-Za-z]:"' "$launcher" \
    'single-file launcher hardcodes the Windows system drive'

# Coexisting patched/original 1E30 packages require deterministic binding.
require_text 'UpdateDriverForPlugAndPlayDevicesW' "$guest" \
    'B phase does not force the exact INF'
require_text 'INSTALLFLAG_FORCE' "$guest" \
    'B phase relies on nondeterministic driver rank'
require_text 'INSTALLFLAG_NONINTERACTIVE' "$guest" \
    'SYSTEM-session NewDev binding can prompt interactively'
require_text '/export-driver \$Package.InfName' "$guest" \
    'B phase passes a DriverStore system path instead of exported media to NewDev'
require_text '\$hardwareId, \$bindingSource.InfPath' "$guest" \
    'B phase does not bind from the hash-verified exported INF'
require_text '\[regex\]::Escape\(\$hardwareId\)' "$guest" \
    'B phase does not prove the selected hardware ID exists in the exact INF'
require_text 'Test-ActiveOriginalPackage' "$guest" \
    'active InfName is not checked'
require_text 'basicdisplay.inf' "$guest" \
    'B continuation does not explicitly accept the Microsoft Basic Display input'
require_text 'Get-Sha256 \$package.InfPath' "$guest" \
    'active original INF hash is not checked'
require_text 'Get-Sha256 \$package.CatalogPath' "$guest" \
    'active original catalog hash is not checked'
require_text 'GpuZProfile.exe' "$guest" \
    'final GPU-Z profile is not part of the one-file continuation'
require_text 'Start-GpuZProfileReceiptWindow' "$guest" \
    'outer migration does not open a fresh nested GPU-Z receipt window'
require_text 'Remove-RegularFileIfPresent \$GpuZProfileReceiptPath' "$guest" \
    'outer migration can accept a stale nested GPU-Z receipt'
require_text 'RedirectStandardOutput \$stdoutPath' "$guest" \
    'nested GPU-Z verifier stdout is not captured'
require_text 'RedirectStandardError \$stderrPath' "$guest" \
    'nested GPU-Z verifier stderr is not captured'
require_text 'Protected stdout log: \$stdoutPath' "$guest" \
    'nested GPU-Z failure does not identify its protected stdout log'
require_text 'Protected stderr log: \$stderrPath' "$guest" \
    'nested GPU-Z failure does not identify its protected stderr log'
require_text 'Remove-RegularFileIfPresent \$stdoutPath' "$guest" \
    'successful nested GPU-Z stdout diagnostics are not removed'
require_text 'Remove-RegularFileIfPresent \$stderrPath' "$guest" \
    'successful nested GPU-Z stderr diagnostics are not removed'
reject_text '\.PSIsContainer' "$guest" \
    'guest relies on provider-added PSIsContainer instead of native filesystem types'
python3 - "$guest" <<'PY'
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")

def function_body(name):
    match = re.search(
        rf"(?ms)^function {re.escape(name)} \{{\n(.*?)(?=^function |\Z)",
        source,
    )
    assert match, f"missing PowerShell function: {name}"
    return match.group(1)

resolver = function_body("Get-RegularFileBelowRoot")
assert "$rootItem -isnot [IO.DirectoryInfo]" in resolver
assert "$item -isnot [IO.FileInfo]" in resolver
assert "$cursor -isnot [IO.DirectoryInfo]" in resolver
assert "[IO.FileAttributes]::ReparsePoint" in resolver
assert ".PSIsContainer" not in resolver

reader = function_body("Get-NestedProcessDiagnosticTail")
assert "$results = @(Get-RegularFileBelowRoot" in reader
assert "$results.Count -ne 1" in reader
assert "$results[0] -isnot [IO.FileInfo]" in reader
assert "$item = $results[0]" in reader
PY
require_text 'Assert-ExactProperties \$receipt @\(' "$guest" \
    'nested GPU-Z receipt does not reject missing or extra fields'
require_text '\$completedUtc -lt \$StartedUtc' "$guest" \
    'nested GPU-Z receipt freshness is not bound to this process run'
require_text '\$receiptItem\.LastWriteTimeUtc -lt \$StartedUtc' "$guest" \
    'nested GPU-Z receipt file timestamp is not fresh'
require_text '\[Guid\]\$receipt\.vmUuid -ne \[Guid\]\$Contract\.vmUuid' "$guest" \
    'nested GPU-Z receipt UUID is not bound to the outer contract'
require_text '\$receipt\.gpuProfile.*\$Contract\.gpuProfile' "$guest" \
    'nested GPU-Z receipt profile is not bound to the outer contract'
require_text '\$receipt\.gpuName.*\$Controller\.Name' "$guest" \
    'nested GPU-Z receipt name is not bound to current hardware'
require_text '\$receipt\.pnpDeviceId.*\$Display\.InstanceId' "$guest" \
    'nested GPU-Z receipt PnP ID is not bound to current hardware'
require_text '\$receipt\.parentId.*\$parentId' "$guest" \
    'nested GPU-Z receipt parent is not bound to the current PCI parent'
require_text "'testsigning', 'nointegritychecks', 'systemNvapiChanged'" "$guest" \
    'nested GPU-Z receipt false-only safety flags are not enforced'
require_text '11642144' "$guest" \
    'outer migration does not lock the raw GPU-Z byte count'
require_text '6CB0EF29682452DE81A9576808881685161411A1FAD00938BA04131159979C29' \
    "$guest" 'outer migration does not lock raw GPU-Z 2.70 SHA-256'
require_text '\$GpuZApplicationsRoot' "$guest" \
    'installed GPU-Z is not confined below the protected applications root'
require_text 'Get-AuthenticodeSignature -LiteralPath \$gpuZItem\.FullName' "$guest" \
    'outer migration does not independently verify GPU-Z Authenticode'
require_text 'CN=TechPowerUp' "$guest" \
    'outer migration does not require the TechPowerUp production signer'
require_text '\$certificate\.Subject -ceq \[string\]\$certificate\.Issuer' "$guest" \
    'outer migration can accept a self-issued GPU-Z signer'
require_text '\(\[string\]\$certificate\.Thumbprint\)\.ToUpperInvariant\(\) -cne' \
    "$guest" \
    'actual GPU-Z signer thumbprint is not bound to the nested receipt'
require_text "GPU-Z \\(vGPU profile\\)\\.lnk" "$guest" \
    'outer migration does not verify the published GPU-Z shortcut'
require_text '\$shortcut\.TargetPath' "$guest" \
    'outer migration does not independently read the shortcut target'
require_text 'gpuzProfileReceipt = \$profileProof\.Receipt' "$guest" \
    'outer final receipt omits the validated nested receipt'
require_text 'gpuZ = \$profileProof\.GpuZ' "$guest" \
    'outer final receipt omits independent raw GPU-Z evidence'
require_text 'Join-Path \$StateRoot.*last-error\.txt' "$guest" \
    'successful finalization does not safely clear the stale error record'
require_text 'Remove-ProvenLegacySelfSignedAssets' "$guest" \
    'post-proof legacy cleanup is missing'
require_text '\$referencedSignerThumbprints -cnotcontains \$_' "$guest" \
    'legacy certificate cleanup ignores remaining DriverStore thumbprint references'
require_text 'Unregister-ScheduledTask.*' "$guest" \
    'successful continuation is not unregistered'
require_text 'startup continuation did not unregister' "$guest" \
    'FINAL PASS can be printed while the startup task still exists'
require_text 'MINIMUM_FREE_BYTES' "$launcher" \
    'single-file launcher does not preflight extraction disk space'
require_text 'this can take several minutes' "$launcher" \
    'single-file launcher appears hung while hashing the large embedded archive'
require_text 'show_child_error\(child_exit\)' "$launcher" \
    'single-file launcher hides the protected child exit code'
require_text 'QemuVgpuProductionMigration\\\\last-error\.txt' "$launcher" \
    'single-file launcher does not identify the persistent diagnostic file'

# All three immutable source locks must agree across build, guest and commit.
for digest in \
        A3D7AD8B8082D6AC6214565B4766B5190A819BC9B7574765B14897E0DB809690 \
        67A240E1D464CF97DABFEC1A7CECF000EAA9DDFD702F32BA2C8771F17905DC2B \
        56B07BD93280BBDA761CB5C9A3A13262C3605320D7286953989E2A5B16D5EC6F; do
    require_text "$digest" "$guest" "guest lacks locked digest $digest"
    require_text "$digest" "$commit" "commit lacks locked digest $digest"
done
require_text 'a3d7ad8b8082d6ac6214565b4766b5190a819bc9b7574765b14897e0db809690' \
    "$builder" 'single EXE builder lacks the archive lock'

# Host commit must prove stopped/read-only receipt consumption before its one
# atomic vm.conf rename, and it must remove all legacy A markers.
require_text 'receipt consumption requires a full stop' "$commit" \
    'host does not refuse a running VM'
require_text 'vm_storage_run_path "\$VM_ID" start.lock' "$commit" \
    'host commit does not hold the VM start lifecycle lock'
require_text 'vm_storage_run_path "\$VM_ID" disk.lock' "$commit" \
    'host commit does not hold the VM disk lifecycle lock'
require_text '--receipt-file is check-only' "$commit" \
    'copied receipt can bypass stopped-disk proof during a real commit'
require_text 'mount -t ntfs-3g -o ro,norecover' "$commit" \
    'host receipt is not read from a read-only disk'
require_text 'nbd_connect NBD "\$DISK" snapshot' "$commit" \
    'host probes the original Windows qcow2 without a disposable COW layer'
reject_text 'mount -t ntfs-3g -o rw' "$commit" \
    'host commit can write the Windows disk'
require_text 'activeDriverChanged == false' "$commit" \
    'host does not prove add-only staging'
require_text 'bcdChanged == false' "$commit" \
    'host does not prove BCD preservation'
require_text '\.bcdAfterSha256 == \.bcdBeforeSha256' "$commit" \
    'host trusts a constant bcdChanged flag without before/after BCD evidence'
require_text 'Assert-BcdUnchanged \$EntryBcd' "$guest" \
    'guest does not compare normalized BCD snapshots at phase exit'
require_text 'mv -T -- "\$config_tmp" "\$CONF"' "$commit" \
    'B config commit is not atomic'
require_text 'target_config_valid "\$config_tmp"' "$commit" \
    'generated B config is not validated before atomic commit'
require_text 'original vm.conf was atomically restored' "$commit" \
    'post-commit assertion failure cannot restore the original config'
require_text 'SPOOF_MODE=B' "$commit" 'host does not commit B mode'
require_text '\.sourceHostMode == "A"' "$commit" \
    'host state does not bind the package to a legacy A source'
reject_text 'SPOOF_MODE=A' "$docs" \
    'operator guide tells users to restore A mode'

# Compile the native launcher without constructing the real 821 MiB output.
tmp=$(mktemp -d)
install -m 0600 "$launcher" "$tmp/vgpu_production_migration.c"
install -m 0600 "$resource" "$tmp/vgpu_production_migration.rc"
install -m 0600 \
    "$migration_manifest" \
    "$tmp/vgpu_production_migration.manifest"
(
    cd "$tmp"
    x86_64-w64-mingw32-windres --use-temp-file \
        -i vgpu_production_migration.rc -o resource.o
    x86_64-w64-mingw32-gcc -std=c11 -O2 -Wall -Wextra -Werror \
        -static -s -municode -Wl,--no-insert-timestamp \
        -o VgpuProductionMigration.exe \
        vgpu_production_migration.c resource.o \
        -ladvapi32 -lbcrypt -lshell32 -luser32
)
[[ -s "$tmp/VgpuProductionMigration.exe" ]] \
    || fail 'native single-file launcher did not compile'

echo 'PASS: production-only A-to-B migration gates, receipts and launcher'
