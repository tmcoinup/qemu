#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SOURCE="$DEPLOY_DIR/windows/gpup/native/VMateCpuidBrandExtension.c"
BUILD_SCRIPT="$DEPLOY_DIR/tools/build-vmate-cpuid-brand-extension.sh"
RUNNER="$DEPLOY_DIR/windows/gpup/Invoke-VMateCpuidBrandExtension.ps1"

test -f "$SOURCE"
test -x "$BUILD_SCRIPT"
test -f "$RUNNER"

for text in \
    'One-shot CPUID brand extension' \
    'VMATE_VID_GET_HV_PARTITION_ID_IOCTL 0x002210af' \
    'VMATE_VID_REGISTER_CPUID_RESULT_IOCTL 0x00221134' \
    'VMATE_VID_UNREGISTER_CPUID_RESULT_IOCTL 0x002211b0' \
    '0x80000002u + LeafIndex' \
    'VMATE_BRAND_LEAF_COUNT 3u' \
    'VMATE_CONTRACT_VERSION 2u' \
    'VMATE_CPUID_ALWAYS_OVERRIDE 1u' \
    'Input->Flags = VMATE_CPUID_ALWAYS_OVERRIDE;' \
    'VMateIssueBufferedIoctl' \
    'Partial application is rolled back' \
    'return STATUS_UNSUCCESSFUL;'; do
    rg -F "$text" "$SOURCE" >/dev/null || {
        echo "CPUID brand extension missing contract text: $text" >&2
        exit 1
    }
done

if rg -F -e 'IoCreateDevice' -e 'IoCreateSymbolicLink' -e 'IRP_MJ_' \
    "$SOURCE" >/dev/null; then
    echo 'one-shot CPUID extension must expose no device/IOCTL surface' >&2
    exit 1
fi

"$BUILD_SCRIPT" >/dev/null
SYS="$DEPLOY_DIR/windows/gpup/native/bin/VMateCpuidBrandExtension.sys"
test -f "$SYS"
headers="$(x86_64-w64-mingw32-objdump -p "$SYS")"
rg -F 'Subsystem' <<<"$headers" | rg -i -F 'native' >/dev/null
rg -F 'ntoskrnl.exe' <<<"$headers" >/dev/null
if rg -i -F -e 'KERNEL32.dll' -e 'msvcrt.dll' <<<"$headers" >/dev/null; then
    echo 'CPUID extension unexpectedly imports a user-mode runtime' >&2
    exit 1
fi

imports="$(x86_64-w64-mingw32-objdump -p "$SYS" |
    sed -n '/The Import Tables/,/The Export Tables/p')"
for symbol in PsLookupProcessByProcessId PsGetProcessImageFileName \
    PsCreateSystemThread PsTerminateSystemThread IoGetCurrentProcess \
    IoGetRelatedDeviceObject IoBuildDeviceIoControlRequest IofCallDriver \
    ObReferenceObjectByHandle IoFileObjectType ZwDuplicateObject \
    ZwAllocateVirtualMemory ZwFreeVirtualMemory ZwWaitForSingleObject; do
    rg -F "$symbol" <<<"$imports" >/dev/null || {
        echo "missing expected kernel import: $symbol" >&2
        exit 1
    }
done

[[ "$(od -An -tx1 -N3 "$RUNNER" | tr -d ' \n')" == efbbbf ]] || {
    echo 'PowerShell 5.1 UTF-8 BOM missing from CPUID extension runner' >&2
    exit 1
}
for text in ExpectedDriverSha256 ExpectedVmwpSha256 ExpectedVidSha256 \
    ExpectedVidSysSha256 Get-AuthenticodeSignature \
    CODEINTEGRITY_OPTION_TESTSIGN "-cne 'Paused'" \
    MaxPausedUptimeSeconds RuntimeModelSwitch WhitelistedLeafCount \
    AlwaysOverride \
    RegisterLeaf80000002NtStatus RegisterLeaf80000003NtStatus \
    RegisterLeaf80000004NtStatus FailedOrRolledBack; do
    rg -F -- "$text" "$RUNNER" >/dev/null || {
        echo "runner missing fail-closed contract: $text" >&2
        exit 1
    }
done
rg -F '@($registerStatuses | Where-Object { $_ -ne 0 }).Count' \
    "$RUNNER" >/dev/null || {
    echo 'runner must preserve an empty failed-status pipeline as an array' >&2
    exit 1
}
if rg -i -F -e 'bcdedit' -e 'testsigning on' -e 'nointegritychecks' \
    -e 'Start-VM' -e 'Resume-VM' -e 'Stop-VM' "$RUNNER" >/dev/null; then
    echo 'CPUID runner must not alter boot policy or VM lifecycle' >&2
    exit 1
fi

echo 'PASS: Hyper-V CPUID brand extension is paused-only and fail-closed'
