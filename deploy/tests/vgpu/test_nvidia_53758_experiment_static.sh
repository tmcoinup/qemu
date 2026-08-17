#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
guest="$here/guest/nvidia-53758-isolated-experiment.ps1"
packager="$here/package-nvidia-53758-experiment.sh"
docs="$here/docs/NVIDIA-53758-ISOLATED-EXPERIMENT.md"
catalog="$here/lib/signed-consumer-catalog.sh"

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

for file in "$guest" "$packager" "$catalog" "$docs"; do
    [[ -s "$file" ]] || fail "missing 537.58 experiment asset: $file"
done
[[ -x "$packager" ]] || fail 'experiment packager is not executable'
bash -n "$packager"
"$packager" --help 2>&1 | rg -q -- '--confirm-disposable-clone' \
    || fail 'help omits disposable-clone acknowledgement'
if missing=$("$packager" 10 --driver-exe 2>&1); then
    fail 'packager accepts --driver-exe without a value'
fi
[[ "$missing" == *'--driver-exe requires a host EXE file'* ]] \
    || fail 'missing --driver-exe value reports a raw shift failure'
if unsafe=$("$packager" 10 2>&1); then
    fail 'packager accepts a VM without disposable-clone acknowledgement'
fi
[[ "$unsafe" == *'refusing a production disk'* ]] \
    || fail 'packager does not fail closed for a production disk'

# Every catalog row is locked to the exact original NVIDIA bytes and one
# canonical profile tuple. The host extracts the complete vendor Display.Driver and
# builds a per-file manifest rather than trusting the small audit subset.
for hash in \
        D6345ABE590E151796ABC424D6661508735AB86CFF58FB644F23D270E89DCB93 \
        C2860E03D30F7BA610F9726765354E75CABB624791AECEA61478066D9EAD50F1 \
        1B7B9F3A5A13A4FEC0074BCEA8A1DD64336CEF228041B1124B8E31D41CDED957 \
        08AD09F3B13E78D40B674914178B51090EABF99DF3FD1571C7DCBB367D8B430B \
        19DBE8ED10DA6052EBFF22B70F51B710C8233ABB237BD544163025B1313EB5F2 \
        B878D8EB696CF3D4505E2F6641C57AF9062EC51A \
        01DF5BFEFA251B27AC1933E4E4CB61F21C44D57B; do
    require_text "$hash" "$catalog" "catalog omits locked value $hash"
    require_text "$hash" "$guest" "guest omits locked value $hash"
done
require_text "SC_INSTALLER_BYTES=675738080" "$catalog" \
    'vendor installer byte count is not pinned'
require_text "7z x .*" "$packager" \
    'packager does not extract the vendor EXE'
require_text "'Display\.Driver/\*'" "$packager" \
    'packager does not extract the complete Display.Driver subtree'
rg -Fq "find \"\$PUBLISHED/Display.Driver\" -type f -printf '%P\\0' | sort -z" \
    "$packager" || fail 'payload manifest is not deterministic/null-safe'
require_text 'payload-manifest\.sha256' "$packager" \
    'packager omits full payload manifest'
require_text 'Source INF no longer contains the one audited model row selected by the contract' \
    "$guest" 'guest does not enforce exact reviewed INF metadata'
require_text 'schemaVersion.*2' "$packager" \
    'packager does not emit the generic v2 contract'
require_text 'gpuProfile' "$guest" \
    'guest contract does not bind the canonical profile'
require_text 'PCI\\VEN_10DE&DEV_1C81&SUBSYS_11C01028' "$guest" \
    'guest Dell target tuple is not exact'
require_text 'PCI\\VEN_10DE&DEV_1380&SUBSYS_84BB1043' "$guest" \
    'guest ASUS target tuple is not exact'
require_text 'nvidia-53758-dch-whql-gtx750ti-asus' "$catalog" \
    'catalog omits the ASUS GTX 750 Ti driver key'
require_text "SC_GPU_PROFILE=gtx750ti_asus_2gb" "$catalog" \
    'ASUS driver row is not bound to its canonical profile'
require_text "SC_INF_NAME='nv_dispig\.inf'" "$catalog" \
    'ASUS driver row does not lock the original nv_dispig.inf'
require_text '%NVIDIA_DEV\.1380%.*Section010, PCI\\VEN_10DE&DEV_1380' \
    "$catalog" 'ASUS driver row does not lock the reviewed generic INF model'
require_text '31\.0\.15\.3758' "$guest" \
    'guest target driver version is not exact'

# Signature acceptance is deliberately a two-path allowlist, not a generic
# "valid NVIDIA/Microsoft" check. Windows reports the original SYS's embedded
# NVIDIA signer before publication, but may resolve the same exact bytes via
# nv_disp.cat's WHCP signer once the file is in DriverStore.
catalog_signature_block=$(
    awk '
        /^function Assert-CatalogSignature[[:space:]]*\{/ { in_block = 1 }
        /^function Assert-KernelSignature[[:space:]]*\{/ { exit }
        in_block { print }
    ' "$guest"
)
kernel_signature_block=$(
    awk '
        /^function Assert-KernelSignature[[:space:]]*\{/ { in_block = 1 }
        /^function Get-CatalogNameFromInf[[:space:]]*\{/ { exit }
        in_block { print }
    ' "$guest"
)
[[ -n "$catalog_signature_block" && -n "$kernel_signature_block" ]] \
    || fail 'could not isolate the signature validator functions'
require_text "signature.Status -cne 'Valid'" <(printf '%s\n' \
    "$catalog_signature_block") 'catalog validator does not require Valid'
require_text '\\ACN=Microsoft Windows Hardware Compatibility Publisher' \
    <(printf '%s\n' "$catalog_signature_block") \
    'catalog validator does not pin the WHCP subject'
[[ "$(rg -c '\$thumbprint -cne \$LockedCatalogSignerThumbprint' \
        <<<"$catalog_signature_block")" == 1 ]] \
    || fail 'catalog validator does not require exactly the locked WHCP thumbprint'
require_text '\$subject -ceq \[string\]\$certificate\.Issuer' \
    <(printf '%s\n' "$catalog_signature_block") \
    'catalog validator no longer rejects a self-signed certificate'

require_text "signature.Status -cne 'Valid'" <(printf '%s\n' \
    "$kernel_signature_block") 'kernel validator does not require Valid'
[[ "$(rg -c '\$thumbprint -ceq \$LockedKernelSignerThumbprint' \
        <<<"$kernel_signature_block")" == 1 ]] \
    || fail 'kernel validator does not pin exactly one NVIDIA embedded thumbprint'
[[ "$(rg -c '\$thumbprint -ceq \$LockedCatalogSignerThumbprint' \
        <<<"$kernel_signature_block")" == 1 ]] \
    || fail 'kernel validator does not pin exactly one Microsoft catalog thumbprint'
require_text '\$isNvidiaEmbedded = \(' <(printf '%s\n' \
    "$kernel_signature_block") 'NVIDIA embedded acceptance path is missing'
require_text '\$isMicrosoftCatalog = \(' <(printf '%s\n' \
    "$kernel_signature_block") 'Microsoft catalog acceptance path is missing'
require_text '\(-not \$isNvidiaEmbedded -and -not \$isMicrosoftCatalog\)' \
    <(printf '%s\n' "$kernel_signature_block") \
    'kernel validator does not reject every signer outside the two-item allowlist'
require_text "signaturePath = 'nvidia-embedded'" <(printf '%s\n' \
    "$kernel_signature_block") 'NVIDIA signature path is not recorded'
require_text "signaturePath = 'microsoft-whcp-catalog'" <(printf '%s\n' \
    "$kernel_signature_block") 'Microsoft catalog signature path is not recorded'
require_text '\$subject -ceq \[string\]\$certificate\.Issuer' \
    <(printf '%s\n' "$kernel_signature_block") \
    'kernel validator no longer rejects a self-signed certificate'
signature_flags=$(
    rg -o '\$is[A-Za-z0-9_]+' <<<"$kernel_signature_block" |
        sort -u
)
[[ "$signature_flags" == $'$isMicrosoftCatalog\n$isNvidiaEmbedded' ]] \
    || fail "kernel validator contains an unreviewed signer allowlist flag: $signature_flags"
require_text 'the caller has already proved the SYS hash' \
    <(printf '%s\n' "$kernel_signature_block") \
    'kernel alternate signature path no longer documents its hash-first precondition'
require_text 'Locked source INF/CAT/SYS hashes changed' "$guest" \
    'source kernel signature is not preceded by exact byte validation'
require_text 'Get-Sha256 \$kernelPath.*LockedKernelSha256' "$guest" \
    'DriverStore kernel signature is not preceded by exact byte validation'
require_text 'Loaded nvlddmkm\.sys bytes differ' "$guest" \
    'loaded kernel signature is not preceded by exact byte validation'

# Phase 1 is B/native + 538.33/Code 0 and strictly add-only. There is no
# binding, deletion, BCD write, certificate import, or signing path.
require_text 'Phase 1 requires B/native' "$guest" \
    'phase 1 lacks native-PnP gate'
require_text 'LockedBaselineDriverVersion = .31\.0\.15\.3833.' "$guest" \
    'phase 1 lacks 538.33 baseline lock'
require_text 'ConfigManagerErrorCode -ne 0' "$guest" \
    'phase 1 lacks Code-0 baseline gate'
require_text '& \$SystemPnpUtil /add-driver \$payload\.InfPath' "$guest" \
    'original package is not staged with pnputil'
[[ "$(rg -c '& \$SystemPnpUtil /add-driver' "$guest")" == 1 ]] \
    || fail 'guest has more than one DriverStore staging call'
[[ "$(rg -c '\$SystemPnpUtil' "$guest")" == 2 ]] \
    || fail 'pnputil is referenced outside its declaration and one add-only call'
require_text '^[[:space:]]*\$output = \(& \$SystemPnpUtil /add-driver \$payload\.InfPath 2>&1 \|$' \
    "$guest" 'DriverStore staging command is not the exact add-only form'
reject_text '/install(?:[[:space:]]|$)' "$guest" \
    'guest contains a pnputil /install path'
reject_text '^[[:space:]]*[^#\r\n]*&[[:space:]]+\$SystemPnpUtil[^\r\n]+/(install|delete-driver|remove-device)' \
    "$guest" 'guest can bind/delete/remove a device with pnputil'
reject_text 'UpdateDriverForPlugAndPlayDevices|INSTALLFLAG_FORCE|QemuVgpuNewDev' \
    "$guest" 'guest contains a direct driver-binding primitive'
[[ "$(rg -c '\$SystemBcdEdit' "$guest")" == 2 ]] \
    || fail 'bcdedit is referenced outside its declaration and one read-only call'
require_text '^[[:space:]]*\$output = \(& \$SystemBcdEdit /enum all 2>&1 \| Out-String\)$' \
    "$guest" 'the sole bcdedit invocation is not the exact read-only enum-all form'
reject_text '/(set|deletevalue|bootsequence|import|create|copy|delete|default|displayorder|toolsdisplayorder|timeout|ems|emssettings|bootems|dbgsettings|debug|hypervisorsettings|hypervisorlaunchtype)([[:space:]]|$)' \
    "$guest" 'guest contains a mutating BCD switch'
staging_phase_block=$(
    awk '
        /^function Invoke-StagingPhase[[:space:]]*\{/ { in_block = 1 }
        /^function Resolve-LoadedKernelPath[[:space:]]*\{/ { exit }
        in_block { print }
    ' "$guest"
)
target_phase_block=$(
    awk '
        /^function Invoke-TargetValidationPhase[[:space:]]*\{/ { in_block = 1 }
        /^function Write-InstalledFailureReceiptAndPowerOff[[:space:]]*\{/ { exit }
        in_block { print }
    ' "$guest"
)
require_text 'Assert-BcdUnchanged \$EntryBcd' <(printf '%s\n' \
    "$staging_phase_block") 'staging phase does not compare its exit BCD snapshot'
require_text 'Assert-BcdUnchanged \$EntryBcd' <(printf '%s\n' \
    "$target_phase_block") 'target phase does not compare its exit BCD snapshot'
[[ "$(rg -c 'bcdBeforeSha256 = ' "$guest")" == 2 &&
   "$(rg -c 'bcdAfterSha256 = ' "$guest")" == 2 &&
   "$(rg -c 'bcdChanged = \$false' "$guest")" == 2 ]] \
    || fail 'pass receipts do not record unchanged BCD before/after evidence'
reject_text '^[[:space:]]*[^#\r\n]*(New-SelfSignedCertificate|Import-Certificate|Set-AuthenticodeSignature|certutil(?:\.exe)?[[:space:]]+-addstore)' \
    "$guest" 'guest can create/import/trust a replacement signature'
reject_text 'testsigning[[:space:]]+(on|yes)|nointegritychecks[[:space:]]+(on|yes)' \
    "$guest" 'guest enables an integrity bypass'
require_text '\$SystemBcdEdit /enum all' "$guest" \
    'guest does not read all BCD entries'
require_text 'activeInfBefore = ' "$guest" \
    'staged receipt lacks active INF before evidence'
require_text 'activeInfAfter = ' "$guest" \
    'staged receipt lacks active INF after evidence'
require_text 'activeDriverChanged = \$false' "$guest" \
    'staged receipt does not explicitly prove add-only behavior'
require_text "phase = 'staged'" "$guest" 'staged receipt is missing'

# The continuation is SYSTEM/AtStartup and only validates what Windows
# actually bound. It must prove exact HWID, unique Display, Code 0, active
# DriverStore hashes, loaded kernel bytes/signature, BCD, receipt and poweroff.
require_text 'New-ScheduledTaskTrigger -AtStartup' "$guest" \
    'phase-2 startup trigger is missing'
require_text 'New-ScheduledTaskPrincipal -UserId SYSTEM' "$guest" \
    'phase-2 validator does not run as SYSTEM'
require_text "-ContractPath .* -Installed'" "$guest" \
    'startup continuation does not select installed validation mode'
require_text 'Get-PnpDevice -Class Display -PresentOnly' "$guest" \
    'unique present Display is not inspected'
require_text "DEVPKEY_Device_HardwareIds" "$guest" \
    'exact target HardwareIds are not inspected'
require_text 'hardwareIds -notcontains \$LockedTargetPnpId' "$guest" \
    'exact target HardwareId is not required'
require_text 'ConfigManagerErrorCode -ne 0' "$guest" \
    'target Code 0 is not required'
require_text 'Get-LockedDriverStorePackages' "$guest" \
    'active package is not rediscovered from DriverStore'
require_text "Name='nvlddmkm'" "$guest" \
    'loaded kernel service is not inspected'
require_text 'Loaded nvlddmkm\.sys bytes differ' "$guest" \
    'loaded kernel hash is not enforced'
require_text 'Get-AuthenticodeSignature -LiteralPath \$CatalogPath' "$guest" \
    'catalog production signature is not validated'
require_text 'Get-AuthenticodeSignature -LiteralPath \$KernelPath' "$guest" \
    'kernel production signature is not validated'
require_text "phase = 'validated'" "$guest" \
    'validated receipt is missing'
require_text "result = 'fail'" "$guest" \
    'failure receipt is missing'
require_text 'Unregister-Continuation' "$guest" \
    'one-shot target validator is not unregistered'
require_text 'InitiateShutdownW' "$guest" \
    'full native poweroff path is missing'
require_text 'SHUTDOWN_POWEROFF' "$guest" \
    'native transition is not a full poweroff'
require_text 'GRACE_SECONDS = 30' "$guest" \
    'native poweroff has no grace contract'
reject_text 'SHUTDOWN_HYBRID|shutdown\.exe' "$guest" \
    'guest can use hybrid/fallback shutdown'

# The generated runner is the only manual guest action and carries all three
# VM-bound assets. start-vm.sh remains outside this experiment packager.
require_text 'Run-Phase1\.cmd' "$packager" 'one-click runner is missing'
require_text 'xorriso -as mkisofs' "$packager" \
    'packager does not produce a directly attachable read-only ISO'
require_text 'ISO SHA256:' "$packager" \
    'packager output omits ISO integrity evidence'
require_text '-ContractPath "%~dp0experiment-contract\.json"' "$packager" \
    'runner omits VM-bound contract'
require_text '-DriverRoot "%~dp0Display\.Driver"' "$packager" \
    'runner omits complete vendor payload'
require_text '-ManifestPath "%~dp0payload-manifest\.sha256"' "$packager" \
    'runner omits payload manifest'
reject_text 'start-vm\.sh' "$packager" \
    'experiment packager mutates/invokes the formal start path'
require_text '可丢弃' "$docs" 'tutorial omits disposable-clone boundary'
require_text '只读 CD' "$docs" 'tutorial omits read-only ISO execution path'
require_text 'activeInfBefore = activeInfAfter' "$docs" \
    'tutorial omits staged receipt handoff gate'
require_text 'validated/fail' "$docs" \
    'tutorial omits target failure receipt behavior'
require_text 'nvidia-embedded' "$docs" \
    'tutorial omits the locked NVIDIA embedded signature path'
require_text 'microsoft-whcp-catalog' "$docs" \
    'tutorial omits the locked Microsoft catalog signature path'
require_text '任意 NVIDIA/Microsoft 签名均可' "$docs" \
    'tutorial does not explicitly reject arbitrary vendor signers'
require_text 'gtx750ti_asus_2gb' "$docs" \
    'tutorial omits the ASUS canonical profile'
require_text 'SUBSYS_84BB1043' "$docs" \
    'tutorial omits the exact ASUS target subsystem'

duplicates=$(
    awk '/^function[[:space:]]+[A-Za-z0-9_-]+[[:space:]]*\{/ { print $2 }' \
        "$guest" | sort | uniq -d
)
[[ -z "$duplicates" ]] \
    || fail "duplicate PowerShell functions: $duplicates"

echo 'PASS: NVIDIA 537.58 isolated guest staging/validation contract'
