#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SOURCE="$DEPLOY_DIR/windows/gpup/native/VMateVidPartitionProbe.c"
BUILD_SCRIPT="$DEPLOY_DIR/tools/build-vmate-vid-partition-probe.sh"

test -f "$SOURCE"
test -x "$BUILD_SCRIPT"

rg -F 'operation\":\"read-only-probe' "$SOURCE" >/dev/null
rg -F 'VidGetHvPartitionId' "$SOURCE" >/dev/null
rg -F 'zeroIdQueryCount' "$SOURCE" >/dev/null
rg -F -- '--list-access-denied' "$SOURCE" >/dev/null
rg -F 'accessDeniedCandidateHandles' "$SOURCE" >/dev/null
if rg -F 'VidRegisterCpuidResult' "$SOURCE" >/dev/null; then
    echo 'read-only probe must not import the CPUID mutation API' >&2
    exit 1
fi

"$BUILD_SCRIPT" >/dev/null
EXE="$DEPLOY_DIR/windows/gpup/native/bin/VMateVidPartitionProbe.exe"
test -f "$EXE"
x86_64-w64-mingw32-objdump -p "$EXE" | rg -F 'vid.dll' >/dev/null && {
    echo 'probe must load vid.dll from System32 at runtime' >&2
    exit 1
}
x86_64-w64-mingw32-objdump -p "$EXE" |
    rg -F 'KERNEL32.dll' >/dev/null

echo 'PASS: Hyper-V VID partition probe is read-only and buildable'
