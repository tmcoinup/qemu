#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SOURCE="$DEPLOY_DIR/windows/gpup/native/VMateHdvPeerProbe.c"
BUILD_SCRIPT="$DEPLOY_DIR/tools/build-vmate-hdv-peer-probe.sh"

test -f "$SOURCE"
test -x "$BUILD_SCRIPT"

rg -F 'operation\":\"read-only-hcs-open' "$SOURCE" >/dev/null
rg -F 'operation\":\"hdv-peer-probe' "$SOURCE" >/dev/null
rg -F 'HdvInitializeDeviceHost' "$SOURCE" >/dev/null
rg -F 'HdvTeardownDeviceHost' "$SOURCE" >/dev/null
rg -F 'VidGetHvPartitionId' "$SOURCE" >/dev/null
rg -F -- '--initialize-hdv' "$SOURCE" >/dev/null
rg -F -- '--create-device' "$SOURCE" >/dev/null
rg -F -- '--add-flexible-iov' "$SOURCE" >/dev/null
rg -F 'mutatingCalls\":false' "$SOURCE" >/dev/null
if rg -F 'VidRegisterCpuidResult' "$SOURCE" >/dev/null; then
    echo 'HDV peer probe must not register CPUID results' >&2
    exit 1
fi
rg -F 'HcsModifyComputeSystem' "$SOURCE" >/dev/null
rg -F 'VirtualMachine/Devices/FlexibleIov/' "$SOURCE" >/dev/null
rg -F 'if (SUCCEEDED(modify_submit_result))' "$SOURCE" >/dev/null

"$BUILD_SCRIPT" >/dev/null
EXE="$DEPLOY_DIR/windows/gpup/native/bin/VMateHdvPeerProbe.exe"
test -f "$EXE"
x86_64-w64-mingw32-objdump -p "$EXE" | rg -F 'KERNEL32.dll' >/dev/null
if x86_64-w64-mingw32-objdump -p "$EXE" |
    rg -F -e 'computecore.dll' -e 'vmdevicehost.dll' -e 'vid.dll' >/dev/null; then
    echo 'probe must load Hyper-V APIs from System32 at runtime' >&2
    exit 1
fi

echo 'PASS: Hyper-V HDV peer probe is explicit, transient, and buildable'
