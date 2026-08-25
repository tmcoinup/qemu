#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SOURCE="$DEPLOY_DIR/windows/gpup/native/VMateVidContextProbe.c"
BUILD_SCRIPT="$DEPLOY_DIR/tools/build-vmate-vid-context-probe.sh"
RUNNER="$DEPLOY_DIR/windows/gpup/Invoke-VMateVidContextProbe.ps1"

test -f "$SOURCE"
test -x "$BUILD_SCRIPT"
test -f "$RUNNER"

rg -F 'One-shot, read-only VID process-context probe' "$SOURCE" >/dev/null
rg -F 'VMATE_VID_GET_HV_PARTITION_ID_IOCTL 0x002210af' "$SOURCE" >/dev/null
rg -F 'PsGetProcessImageFileName(process)' "$SOURCE" >/dev/null
rg -F 'VMateAsciiEqualsInsensitive(processImage, "vmwp.exe")' \
    "$SOURCE" >/dev/null
rg -F 'KeStackAttachProcess' "$SOURCE" >/dev/null
rg -F 'KeUnstackDetachProcess' "$SOURCE" >/dev/null
rg -F 'PsCreateSystemThread' "$SOURCE" >/dev/null
rg -F 'PsTerminateSystemThread' "$SOURCE" >/dev/null
rg -F 'ZwWaitForSingleObject' "$SOURCE" >/dev/null
rg -F 'FastIoDeviceControl' "$SOURCE" >/dev/null
rg -F 'IoGetRelatedDeviceObject' "$SOURCE" >/dev/null
rg -F 'ZwAllocateVirtualMemory' "$SOURCE" >/dev/null
rg -F 'ZwFreeVirtualMemory' "$SOURCE" >/dev/null
rg -F 'MutatingCalls' "$SOURCE" >/dev/null
rg -F 'ResidentAfterProbe' "$SOURCE" >/dev/null
rg -F 'return STATUS_UNSUCCESSFUL;' "$SOURCE" >/dev/null

if rg -F -e '0x00221134' -e '0x002211b0' \
    -e 'VidRegisterCpuidResult' -e 'VidUnregisterCpuidResult' \
    "$SOURCE" >/dev/null; then
    echo 'read-only context probe contains a CPUID mutation path' >&2
    exit 1
fi
if rg -F -e 'IoCreateDevice' -e 'IoCreateSymbolicLink' -e 'IRP_MJ_' \
    "$SOURCE" >/dev/null; then
    echo 'one-shot context probe must expose no device/IOCTL surface' >&2
    exit 1
fi

"$BUILD_SCRIPT" >/dev/null
SYS="$DEPLOY_DIR/windows/gpup/native/bin/VMateVidContextProbe.sys"
test -f "$SYS"

headers="$(x86_64-w64-mingw32-objdump -p "$SYS")"
rg -F 'Subsystem' <<<"$headers" | rg -i -F 'native' >/dev/null
rg -F 'ntoskrnl.exe' <<<"$headers" >/dev/null
if rg -i -F -e 'KERNEL32.dll' -e 'msvcrt.dll' <<<"$headers" >/dev/null; then
    echo 'kernel probe unexpectedly imports a user-mode runtime' >&2
    exit 1
fi

imports="$(x86_64-w64-mingw32-objdump -p "$SYS" |
    sed -n '/The Import Tables/,/The Export Tables/p')"
for symbol in KeStackAttachProcess KeUnstackDetachProcess \
    PsLookupProcessByProcessId PsGetProcessImageFileName \
    ObOpenObjectByPointer ObReferenceObjectByHandle \
    IoFileObjectType PsProcessType ZwDuplicateObject \
    ZwDeviceIoControlFile PsCreateSystemThread PsTerminateSystemThread \
    ZwWaitForSingleObject IoGetRelatedDeviceObject \
    ZwAllocateVirtualMemory ZwFreeVirtualMemory IoGetCurrentProcess; do
    rg -F "$symbol" <<<"$imports" >/dev/null || {
        echo "missing expected kernel import: $symbol" >&2
        exit 1
    }
done

[[ "$(od -An -tx1 -N3 "$RUNNER" | tr -d ' \n')" == efbbbf ]] || {
    echo 'PowerShell 5.1 UTF-8 BOM missing from context-probe runner' >&2
    exit 1
}
for text in ExpectedDriverSha256 ExpectedVmwpSha256 ExpectedVidSha256 \
    Get-AuthenticodeSignature CODEINTEGRITY_OPTION_TESTSIGN \
    NtQuerySystemInformation DriverEntryNonResident QuerySucceeded \
    driverentry-fails-after-result-delete-service; do
    rg -F "$text" "$RUNNER" >/dev/null || {
        echo "runner missing fail-closed contract: $text" >&2
        exit 1
    }
done
rg -F "'delete', \$serviceName" "$RUNNER" >/dev/null
if rg -i -F -e 'bcdedit' -e 'testsigning on' -e 'nointegritychecks' \
    "$RUNNER" >/dev/null; then
    echo 'read-only runner must not alter boot/code-integrity policy' >&2
    exit 1
fi

echo 'PASS: Hyper-V VID worker-context probe is one-shot and read-only'
