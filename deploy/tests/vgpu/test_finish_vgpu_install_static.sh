#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
HOST="$REPO_ROOT/deploy/finish-vgpu-install.sh"
START="$REPO_ROOT/deploy/start-vm.sh"
BUILDER="$REPO_ROOT/deploy/guest/vgpu-finish/build.sh"
SOURCE="$REPO_ROOT/deploy/guest/vgpu-finish/vgpu_guest_finish.c"
MANIFEST="$REPO_ROOT/deploy/guest/vgpu-finish/vgpu_guest_finish.manifest"
RTC_MIGRATOR="$REPO_ROOT/deploy/host/migrate-windows-local-rtc.sh"
DRIVER_STAGER="$REPO_ROOT/deploy/guest/stage-patched-vgpu-driver.ps1"
LEGACY_DRIVER_INSTALLER="$REPO_ROOT/deploy/guest/install-patched-driver.ps1"

fail() { echo "FAIL: $*" >&2; exit 1; }
require_text() {
    grep -F -- "$1" "$2" >/dev/null || fail "missing '$1' in $2"
}
reject_text() {
    ! grep -Fi -- "$1" "$2" >/dev/null || fail "unexpected '$1' in $2"
}

bash -n "$HOST"
bash -n "$START"
bash -n "$BUILDER"
bash -n "$RTC_MIGRATOR"
[[ -x "$HOST" && -x "$BUILDER" && -x "$RTC_MIGRATOR" ]] \
    || fail "finish scripts must be executable"

require_text 'requireAdministrator' "$MANIFEST"
require_text 'powercfg.exe' "$SOURCE"
require_text '/hibernate off' "$SOURCE"
require_text 'HiberbootEnabled' "$SOURCE"
require_text 'shutdown.exe' "$SOURCE"
require_text 'client_configuration_token.tok' "$SOURCE"
require_text 'BCryptFinishHash' "$SOURCE"
require_text 'GetSystemFirmwareTable' "$SOURCE"
require_text 'QEMU_VGPU_TARGET=' "$SOURCE"
require_text 'read_target_gpu_hint' "$SOURCE"
require_text 'is_safe_gpu_name_ascii' "$SOURCE"
require_text 'SetupDiGetClassDevsW(&GUID_DEVCLASS_DISPLAY, NULL, NULL, 0)' "$SOURCE"
require_text 'SPDRP_HARDWAREID' "$SOURCE"
require_text 'L"PCI\\VEN_10DE"' "$SOURCE"
require_text 'L"PCI\\VEN_10DE&DEV_1C81&SUBSYS_11C01028"' "$SOURCE"
require_text 'if (prefer_gtx1050 && exact_matches == 1)' "$SOURCE"
require_text 'target_is_gtx1050 = strcmp(target_gpu_name_ascii, GTX1050_NAME) == 0' "$SOURCE"
require_text 'selected = exact_selected' "$SOURCE"
require_text 'SPDRP_SERVICE' "$SOURCE"
require_text 'L"nvlddmkm"' "$SOURCE"
require_text 'SPDRP_ENUMERATOR_NAME' "$SOURCE"
require_text 'SetupDiSetDeviceRegistryPropertyW' "$SOURCE"
require_text 'SPDRP_FRIENDLYNAME' "$SOURCE"
require_text 'wcscmp(verified_name, target_name)' "$SOURCE"
require_text 'GPU_NAME=%s' "$SOURCE"
require_text 'QEMU_VGPU_PREPARED_V2' "$SOURCE"
require_text 'QEMU_VGPU_PREPARED_V3' "$SOURCE"
require_text 'stage-patched-vgpu-driver.ps1' "$SOURCE"
require_text '538.33-gtx1050_2gb.receipt' "$SOURCE"
require_text 'Missing or partial bundle contents must never fall back' "$SOURCE"
require_text 'PATCHED_INF_SHA256=' "$SOURCE"
require_text 'prepared-%ls.txt' "$SOURCE"
require_text 'write_prepared_marker' "$SOURCE"
reject_text 'VGPU_VM_ID_' "$SOURCE"
reject_text 'VGPU_VM_UUID_' "$SOURCE"
reject_text 'VGPU_GPU_NAME_' "$SOURCE"
reject_text 'RealTimeIsUniversal' "$SOURCE"
reject_text 'tzutil' "$SOURCE"
reject_text 'http://' "$SOURCE"
reject_text 'https://' "$SOURCE"

require_text 'RESCUE_MODE=rescue-sdl' "$HOST"
require_text '"--${RESCUE_MODE}"' "$HOST"
require_text 'rescue_args=( "$VM_ID" "--${RESCUE_MODE}" --no-monitor-sync --no-spoof )' "$HOST"
require_text 'auto-selected local token' "$HOST"
require_text '$STAGE_DIR/client_configuration_token.tok' "$HOST"
require_text '--rtc-utc-compat' "$HOST"
require_text 'migrate-windows-local-rtc.sh' "$HOST"
require_text 'RTC_CONTRACT=localtime' "$HOST"
require_text '--expected-token-sha256' "$HOST"
require_text '--expected-gpu-name "$GPU_NAME"' "$HOST"
require_text 'VGPU_GUEST_FINISH_TARGET="$GPU_NAME"' "$HOST"
require_text '$STAGE_DIR/VgpuGuestFinish.exe' "$HOST"
require_text '$STAGE_DIR/VgpuGuestFinish-GTX1050.zip' "$HOST"
require_text 'VGPU_MDEV_INTERNAL_PCI_IDENTITY=1' "$HOST"
require_text 'VGPU_MDEV_FRL_ENABLED=0' "$HOST"
require_text '--expected-driver-profile gtx1050_2gb' "$HOST"
require_text 'BUILD_INPUT_SHA256=' "$HOST"
require_text '.VgpuGuestFinish.exe.lock' "$HOST"
require_text 'mv -Tf -- "$PACKAGE_TMP" "$PACKAGE"' "$HOST"
require_text 'start-vm.sh" "$VM_ID"' "$HOST"
reject_text '--vm-id "$VM_ID"' "$HOST"
reject_text '--vm-uuid "$VM_UUID"' "$HOST"
reject_text '--gpu-name "$GPU_NAME"' "$HOST"
reject_text 'rdp-vm.sh' "$HOST"
reject_text 'vncviewer' "$HOST"
reject_text 'WinRM port' "$HOST"
require_text "--proto '=https'" "$HOST"
require_text 'https://127.0.0.1/-/client-token' "$HOST"
reject_text 'http://' "$HOST"
require_text 'GTX 1050 strict-A finish is disabled' "$HOST"
require_text 'DISABLED: the legacy pre-stager was removed' \
    "$DRIVER_STAGER"
require_text 'DISABLED: the legacy patched-driver installer was removed' \
    "$LEGACY_DRIVER_INSTALLER"
for retired_driver_entry in "$DRIVER_STAGER" "$LEGACY_DRIVER_INSTALLER"; do
    reject_text 'New-SelfSignedCertificate' "$retired_driver_entry"
    reject_text 'Set-AuthenticodeSignature' "$retired_driver_entry"
    reject_text 'New-FileCatalog' "$retired_driver_entry"
    reject_text 'Import-Certificate' "$retired_driver_entry"
    reject_text 'pnputil' "$retired_driver_entry"
    reject_text 'bcdedit' "$retired_driver_entry"
done

require_text 'VGPU_GUEST_FINISH_TARGET_ENV=' "$START"
require_text 'type=11,value=QEMU_VGPU_TARGET=${VGPU_GUEST_FINISH_TARGET}' "$START"
require_text 'VGPU_GUEST_FINISH_TARGET 只允许用于 rescue-sdl/gtk' "$START"
require_text 'guest_finish_gpu_name_lower' "$START"

require_text 'RealTimeIsUniversal' "$RTC_MIGRATOR"
require_text 'node_set_values' "$RTC_MIGRATOR"
require_text 'ntfs-3g.probe --readwrite' "$RTC_MIGRATOR"
require_text 'norecover' "$RTC_MIGRATOR"
require_text 'SYSTEM.before-local-rtc-' "$RTC_MIGRATOR"
require_text 'guest completion marker is missing' "$RTC_MIGRATOR"
require_text 'TOKEN_SHA256=' "$RTC_MIGRATOR"
require_text 'GPU_NAME=${EXPECTED_GPU_NAME}' "$RTC_MIGRATOR"
require_text 'prepared-${EXPECTED_UUID}.txt' "$RTC_MIGRATOR"
require_text 'QEMU_VGPU_PREPARED_V2' "$RTC_MIGRATOR"
require_text 'QEMU_VGPU_PREPARED_V3' "$RTC_MIGRATOR"
require_text 'strict consumer driver requires a V3' "$RTC_MIGRATOR"
require_text 'DRIVER_INF' "$RTC_MIGRATOR"
reject_text '${EXPECTED_VM}-prepared.txt' "$RTC_MIGRATOR"

for tool in x86_64-w64-mingw32-gcc x86_64-w64-mingw32-windres \
            x86_64-w64-mingw32-objcopy x86_64-w64-mingw32-objdump; do
    command -v "$tool" >/dev/null 2>&1 || fail "missing test tool: $tool"
done

TMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TMP_DIR"' EXIT
TOKEN="$TMP_DIR/client_configuration_token.tok"
dd if=/dev/zero bs=1 count=1536 of="$TOKEN" status=none
printf 'offline-test-token' | dd of="$TOKEN" conv=notrunc status=none
chmod 0600 "$TOKEN"

for name in first second; do
    "$BUILDER" --token-file "$TOKEN" \
        --output "$TMP_DIR/$name.exe" >"$TMP_DIR/$name.out"
    [[ "$(stat -c %a "$TMP_DIR/$name.exe")" == 600 ]] \
        || fail "built EXE is not mode 0600"
    file "$TMP_DIR/$name.exe" | grep -Fq 'PE32+ executable' \
        || fail "builder did not produce a Win64 PE"
done
cmp -s "$TMP_DIR/first.exe" "$TMP_DIR/second.exe" \
    || fail "identical inputs did not produce an identical EXE"
strings -el "$TMP_DIR/first.exe" >"$TMP_DIR/wide-strings.txt"
reject_text 'NVIDIA GeForce GTX 1050' "$TMP_DIR/wide-strings.txt"
if "$BUILDER" --token-file "$TOKEN" --vm-id 3 \
        --output "$TMP_DIR/per-vm.exe" >"$TMP_DIR/per-vm.out" 2>&1; then
    fail "universal builder accepted removed per-VM arguments"
fi

x86_64-w64-mingw32-objcopy --dump-section .rsrc="$TMP_DIR/resources.bin" \
    "$TMP_DIR/first.exe"
strings "$TMP_DIR/resources.bin" >"$TMP_DIR/resources.txt"
require_text 'requireAdministrator' "$TMP_DIR/resources.txt"
require_text 'offline-test-token' "$TMP_DIR/resources.txt"
x86_64-w64-mingw32-objdump -p "$TMP_DIR/first.exe" >"$TMP_DIR/pe.txt"
require_text 'DLL Name: ADVAPI32.dll' "$TMP_DIR/pe.txt"
require_text 'DLL Name: bcrypt.dll' "$TMP_DIR/pe.txt"
require_text 'DLL Name: KERNEL32.dll' "$TMP_DIR/pe.txt"
require_text 'DLL Name: SETUPAPI.dll' "$TMP_DIR/pe.txt"
require_text 'Subsystem' "$TMP_DIR/pe.txt"

# The foolproof host entry point must find the local staging token when the
# user supplies only a VM id.
TEST_VM_ROOT="$TMP_DIR/vms"
TEST_STAGE="$TMP_DIR/staging"
mkdir -p "$TEST_VM_ROOT/vm1" "$TEST_VM_ROOT/vm3" \
    "$TEST_VM_ROOT/vm5" "$TEST_STAGE"
cp -- "$TOKEN" "$TEST_STAGE/client_configuration_token.tok"
chmod 0644 "$TEST_STAGE/client_configuration_token.tok"
cat >"$TEST_VM_ROOT/vm3/vm.conf" <<'EOF'
VM_ID=3
VM_UUID=b088ce0e-ea16-40df-b349-cb775b3f345e
GPU_NAME="NVIDIA GeForce GT 1030"
RTC_CONTRACT=localtime
EOF
touch "$TEST_VM_ROOT/vm3/disk.qcow2"
VM_ROOT="$TEST_VM_ROOT" STAGE_DIR="$TEST_STAGE" \
    "$HOST" 3 --build-only >"$TMP_DIR/host-build.out"
require_text "auto-selected local token: $TEST_STAGE/client_configuration_token.tok" \
    "$TMP_DIR/host-build.out"
SHARED_PACKAGE="$TEST_STAGE/VgpuGuestFinish.exe"
SHARED_META="$TEST_STAGE/.VgpuGuestFinish.exe.meta"
[[ -s "$SHARED_PACKAGE" ]] \
    || fail "host entry point did not publish the shared auto-token EXE"
[[ "$(stat -c %a "$SHARED_PACKAGE")" == 600 &&
   "$(stat -c %a "$SHARED_META")" == 600 ]] \
    || fail "shared EXE/cache metadata is not mode 0600"
[[ "$(stat -c %a "$TEST_STAGE/client_configuration_token.tok")" == 600 ]] \
    || fail "default staging token permissions were not tightened to 0600"
require_text 'tightened staging token permissions to 0600' \
    "$TMP_DIR/host-build.out"
require_text 'BUILD_INPUT_SHA256=' "$SHARED_META"
first_shared_sha=$(sha256sum "$SHARED_PACKAGE" | awk '{print $1}')

# A different VM using the same token must reuse the exact same public file.
cat >"$TEST_VM_ROOT/vm5/vm.conf" <<'EOF'
VM_ID=5
VM_UUID=55555555-bbbb-cccc-dddd-eeeeeeeeeeee
GPU_NAME="NVIDIA GeForce GT 1030"
RTC_CONTRACT=localtime
EOF
touch "$TEST_VM_ROOT/vm5/disk.qcow2"
VM_ROOT="$TEST_VM_ROOT" STAGE_DIR="$TEST_STAGE" \
    "$HOST" 5 --build-only >"$TMP_DIR/host-reuse.out"
require_text 'reusing shared guest EXE for this token' "$TMP_DIR/host-reuse.out"
[[ "$(sha256sum "$SHARED_PACKAGE" | awk '{print $1}')" == "$first_shared_sha" ]] \
    || fail "same-token VM changed the shared EXE"
[[ ! -e "$TEST_VM_ROOT/vm3/transfer/VgpuGuestFinish-vm3.exe" &&
   ! -e "$TEST_VM_ROOT/vm5/transfer/VgpuGuestFinish-vm5.exe" ]] \
    || fail "host still published a per-VM EXE"

# Legacy VM configs that only persist GPU_PROFILE must derive the same safe
# target from the audited catalog without rewriting vm.conf.
cat >"$TEST_VM_ROOT/vm1/vm.conf" <<'EOF'
VM_ID=1
VM_UUID=11111111-bbbb-cccc-dddd-eeeeeeeeeeee
GPU_PROFILE=gt1030_2gb
RTC_CONTRACT=localtime
EOF
touch "$TEST_VM_ROOT/vm1/disk.qcow2"
VM_ID=999 GPU_NAME='NVIDIA GeForce GTX 750 Ti' GPU_PROFILE=gt1030_2gb \
    RTC_CONTRACT=utc VM_ROOT="$TEST_VM_ROOT" STAGE_DIR="$TEST_STAGE" \
    "$HOST" 1 --build-only >"$TMP_DIR/host-legacy.out"
require_text 'derived GPU target from GPU_PROFILE=gt1030_2gb' \
    "$TMP_DIR/host-legacy.out"
! grep -q '^GPU_NAME=' "$TEST_VM_ROOT/vm1/vm.conf" \
    || fail "legacy fallback unexpectedly rewrote vm.conf"

# Changing token bytes must atomically replace the shared package and cache.
TOKEN2="$TMP_DIR/client_configuration_token-2.tok"
cp -- "$TOKEN" "$TOKEN2"
printf X | dd of="$TOKEN2" bs=1 seek=900 conv=notrunc status=none
VM_ROOT="$TEST_VM_ROOT" STAGE_DIR="$TEST_STAGE" \
    "$HOST" 5 --token-file "$TOKEN2" --build-only \
    >"$TMP_DIR/host-token-change.out"
require_text 'building shared guest EXE for the selected token' \
    "$TMP_DIR/host-token-change.out"
[[ "$(sha256sum "$SHARED_PACKAGE" | awk '{print $1}')" != "$first_shared_sha" ]] \
    || fail "changed token did not replace the shared EXE"

# Reject unsafe/non-consumer target hints on the host, before opening a VM.
INVALID_ROOT="$TMP_DIR/vms-invalid"
mkdir -p "$INVALID_ROOT/vm6"
touch "$INVALID_ROOT/vm6/disk.qcow2"
for bad_name in 'NVIDIA GRID RTX6000-2Q' 'NVIDIA RTX6000' \
        'NVIDIA GeForce GTX 1050 ' 'AMD Radeon'; do
    cat >"$INVALID_ROOT/vm6/vm.conf" <<EOF
VM_ID=6
VM_UUID=66666666-bbbb-cccc-dddd-eeeeeeeeeeee
GPU_NAME="$bad_name"
RTC_CONTRACT=localtime
EOF
    if VM_ROOT="$INVALID_ROOT" STAGE_DIR="$TMP_DIR/staging-invalid" \
            "$HOST" 6 --token-file "$TOKEN" --build-only \
            >"$TMP_DIR/invalid-name.out" 2>"$TMP_DIR/invalid-name.err"; then
        fail "host accepted unsafe GPU target: $bad_name"
    fi
    require_text 'GPU_NAME must be a safe' "$TMP_DIR/invalid-name.err"
done

# The EXE keys GTX 1050 driver staging from the authenticated target name.  A
# host config that requests that name without the matching profile must fail
# before it can hand the user a small EXE that will inevitably reject itself.
cat >"$INVALID_ROOT/vm6/vm.conf" <<'EOF'
VM_ID=6
VM_UUID=66666666-bbbb-cccc-dddd-eeeeeeeeeeee
GPU_NAME="NVIDIA GeForce GTX 1050"
RTC_CONTRACT=localtime
EOF
if VM_ROOT="$INVALID_ROOT" STAGE_DIR="$TMP_DIR/staging-invalid" \
        "$HOST" 6 --token-file "$TOKEN" --build-only \
        >"$TMP_DIR/missing-gtx-profile.out" \
        2>"$TMP_DIR/missing-gtx-profile.err"; then
    fail 'host accepted GTX 1050 target without gtx1050_2gb profile'
fi
require_text 'GPU_NAME requests strict GTX 1050 but GPU_PROFILE is missing' \
    "$TMP_DIR/missing-gtx-profile.err"

# With no file at all, only the host loopback exporter may create one.  A fake
# curl keeps this test offline while exercising the atomic auto-export branch.
TEST_VM_ROOT2="$TMP_DIR/vms-export"
TEST_STAGE2="$TMP_DIR/staging-export"
FAKE_BIN="$TMP_DIR/fake-bin"
mkdir -p "$TEST_VM_ROOT2/vm4" "$TEST_STAGE2" "$FAKE_BIN"
cat >"$TEST_VM_ROOT2/vm4/vm.conf" <<'EOF'
VM_ID=4
VM_UUID=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
GPU_NAME="NVIDIA GeForce GT 1030"
RTC_CONTRACT=localtime
EOF
touch "$TEST_VM_ROOT2/vm4/disk.qcow2"
cat >"$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=""
while (( $# > 0 )); do
    case "$1" in
        -o) output=$2; shift 2 ;;
        *) shift ;;
    esac
done
[[ -n "$output" ]]
cp -- "$FAKE_DLS_TOKEN" "$output"
EOF
chmod +x "$FAKE_BIN/curl"
PATH="$FAKE_BIN:$PATH" FAKE_DLS_TOKEN="$TOKEN" \
    VM_ROOT="$TEST_VM_ROOT2" STAGE_DIR="$TEST_STAGE2" \
    "$HOST" 4 --build-only >"$TMP_DIR/host-export.out"
require_text 'exported local DLS token over host loopback HTTPS' \
    "$TMP_DIR/host-export.out"
[[ "$(stat -c %a "$TEST_STAGE2/client_configuration_token.tok")" == 600 ]] \
    || fail "auto-exported token is not mode 0600"
cmp -s "$TOKEN" "$TEST_STAGE2/client_configuration_token.tok" \
    || fail "auto-exported token content changed"

# Exercise the RTC orchestration itself with harmless stand-ins for QEMU, the
# guest package builder, sudo, and the offline registry migrator.  Missing
# RTC_CONTRACT is the historical localtime contract; only an explicit `utc`
# value may request the one-boot --rtc-utc-compat rescue.
HARNESS="$TMP_DIR/finish-harness"
mkdir -p "$HARNESS/deploy/lib" "$HARNESS/deploy/guest/vgpu-finish" \
    "$HARNESS/deploy/guest" "$HARNESS/deploy/host" "$HARNESS/bin"
cp -- "$HOST" "$HARNESS/deploy/finish-vgpu-install.sh"
cp -- "$REPO_ROOT/deploy/lib/vm-storage.sh" "$HARNESS/deploy/lib/vm-storage.sh"
cp -- "$REPO_ROOT/deploy/lib/vgpu-profiles.sh" "$HARNESS/deploy/lib/vgpu-profiles.sh"

cat >"$HARNESS/deploy/guest/vgpu-finish/build.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=""
while (( $# > 0 )); do
    case "$1" in
        --output) output=$2; shift 2 ;;
        *) shift ;;
    esac
done
[[ -n "$output" ]]
mkdir -p "$(dirname "$output")"
if [[ -n "${FAKE_BUILD_DELAY:-}" ]]; then
    sleep "$FAKE_BUILD_DELAY"
fi
printf 'fake universal guest package\n' >"$output"
chmod 0600 "$output"
if [[ -n "${FAKE_BUILD_TRACE:-}" ]]; then
    printf 'build\n' >>"$FAKE_BUILD_TRACE"
fi
EOF

for guest_input in vgpu_guest_finish.c vgpu_guest_finish.rc \
        vgpu_guest_finish.manifest; do
    printf 'fake build input: %s\n' "$guest_input" \
        >"$HARNESS/deploy/guest/vgpu-finish/$guest_input"
done
printf 'fake bundle instructions\n' \
    >"$HARNESS/deploy/guest/vgpu-finish/README-GTX1050.txt"
printf 'fake audited guest stager\n' \
    >"$HARNESS/deploy/guest/stage-patched-vgpu-driver.ps1"

cat >"$HARNESS/deploy/host/build-vgpu-driver-patch.py" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=""
while (( $# > 0 )); do
    case "$1" in
        --output-dir) output=$2; shift 2 ;;
        *) shift ;;
    esac
done
[[ -n "$output" ]]
mkdir -p "$output/Display.Driver"
printf '{"fake":"locked manifest"}\n' >"$output/.vgpu-patch-manifest.json"
printf 'fake driver payload\n' >"$output/Display.Driver/nvlddmkm.sys"
EOF

cat >"$HARNESS/deploy/start-vm.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'target=%s args=%s\n' "${VGPU_GUEST_FINISH_TARGET:-}" "$*" \
    >>"$FAKE_START_TRACE"
if [[ -n "${FAKE_MUTATE_CONF:-}" ]]; then
    printf '# changed during rescue\n' >>"$FAKE_MUTATE_CONF"
fi
EOF

cat >"$HARNESS/deploy/host/migrate-windows-local-rtc.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_MIGRATE_TRACE"
EOF

cat >"$HARNESS/bin/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
    -n)
        shift
        [[ "${1:-}" == true ]] && exit 0
        ;;
    -v) exit 0 ;;
esac
[[ "${1:-}" != -- ]] || shift
exec "$@"
EOF
cat >"$HARNESS/bin/zip" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=""
for argument in "$@"; do
    [[ "$argument" == *.zip ]] && { output=$argument; break; }
done
[[ -n "$output" ]]
printf 'fake zip member\n' >>"$output"
EOF
cat >"$HARNESS/bin/unzip" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$HARNESS/deploy/finish-vgpu-install.sh" \
    "$HARNESS/deploy/guest/vgpu-finish/build.sh" \
    "$HARNESS/deploy/host/build-vgpu-driver-patch.py" \
    "$HARNESS/deploy/start-vm.sh" \
    "$HARNESS/deploy/host/migrate-windows-local-rtc.sh" \
    "$HARNESS/bin/sudo" "$HARNESS/bin/zip" "$HARNESS/bin/unzip"

run_finish_rtc_case() {
    local name=$1 vm_id=$2 contract=${3:-} expect_compat=$4
    local root="$TMP_DIR/rtc-$name" conf start_trace migrate_trace
    local -a polluted_environment=()
    conf="$root/vm${vm_id}/vm.conf"
    start_trace="$root/start.trace"
    migrate_trace="$root/migrate.trace"
    mkdir -p "$(dirname "$conf")" "$root/staging"
    cat >"$conf" <<EOF
VM_ID=$vm_id
VM_UUID=aaaaaaaa-bbbb-cccc-dddd-$(printf '%012d' "$vm_id")
GPU_NAME="NVIDIA GeForce GT 1030"
EOF
    [[ -z "$contract" ]] || printf 'RTC_CONTRACT=%s\n' "$contract" >>"$conf"
    touch "$root/vm${vm_id}/disk.qcow2" "$start_trace" "$migrate_trace"

    if [[ "$name" == missing ]]; then
        # Missing RTC_CONTRACT is historical localtime. An exported value must
        # not silently convert this VM into the explicit UTC migration path.
        polluted_environment+=( RTC_CONTRACT=utc VM_ID=999 )
    fi

    env -i \
        HOME="${HOME:-/tmp}" \
        PATH="$HARNESS/bin:/usr/bin:/bin" \
        VM_ROOT="$root" \
        STAGE_DIR="$root/staging" \
        FAKE_START_TRACE="$start_trace" \
        FAKE_MIGRATE_TRACE="$migrate_trace" \
        "${polluted_environment[@]}" \
        "$HARNESS/deploy/finish-vgpu-install.sh" "$vm_id" \
            --token-file "$TOKEN" --keep-package --no-final-start \
            >"$root/finish.out" 2>"$root/finish.err"

    require_text "$vm_id --rescue-sdl --no-monitor-sync" "$start_trace"
    require_text 'target=NVIDIA GeForce GT 1030' "$start_trace"
    if [[ "$expect_compat" == yes ]]; then
        require_text '--rtc-utc-compat' "$start_trace"
    else
        reject_text '--rtc-utc-compat' "$start_trace"
    fi
    require_text "--expected-vm vm${vm_id}" "$migrate_trace"
    require_text '--expected-gpu-name NVIDIA GeForce GT 1030' "$migrate_trace"
    [[ "$(grep -Fc 'RTC_CONTRACT=localtime' "$conf")" -eq 1 ]] \
        || fail "$name did not persist exactly one localtime RTC contract"
    reject_text 'RTC_CONTRACT=utc' "$conf"
}

run_finish_rtc_case missing 31 '' no
run_finish_rtc_case localtime 32 localtime no
run_finish_rtc_case explicit-utc 33 utc yes

# A generated full-consumer GTX 1050 target must now fail before building or
# launching anything.  The legacy self-signed driver flow may not create a ZIP
# or persist A/internal/FRL completion markers.
STRICT_ROOT="$TMP_DIR/strict-gtx1050"
STRICT_CONF="$STRICT_ROOT/vm35/vm.conf"
STRICT_START="$STRICT_ROOT/start.trace"
STRICT_MIGRATE="$STRICT_ROOT/migrate.trace"
mkdir -p "$(dirname "$STRICT_CONF")" "$STRICT_ROOT/staging"
cat >"$STRICT_CONF" <<'EOF'
VM_ID=35
VM_UUID=35353535-bbbb-cccc-dddd-eeeeeeeeeeee
GPU_PROFILE=gtx1050_2gb
GPU_NAME="NVIDIA GeForce GTX 1050"
GPU_PCI_VID=0x10DE
GPU_PCI_DID=0x1C81
GPU_SUB_VID=0x1028
GPU_SUB_DID=0x11C0
VGPU_IDENTITY_TARGET=full-consumer
SPOOF_MODE=B
RTC_CONTRACT=localtime
EOF
touch "$STRICT_ROOT/vm35/disk.qcow2" \
    "$STRICT_START" "$STRICT_MIGRATE"
strict_before=$(sha256sum "$STRICT_CONF")
if env -i \
    HOME="${HOME:-/tmp}" \
    PATH="$HARNESS/bin:/usr/bin:/bin" \
    VM_ROOT="$STRICT_ROOT" \
    STAGE_DIR="$STRICT_ROOT/staging" \
    FAKE_START_TRACE="$STRICT_START" \
    FAKE_MIGRATE_TRACE="$STRICT_MIGRATE" \
    "$HARNESS/deploy/finish-vgpu-install.sh" 35 \
        --token-file "$TOKEN" --no-final-start \
        >"$STRICT_ROOT/finish.out" 2>"$STRICT_ROOT/finish.err"; then
    fail 'strict GTX 1050 finish did not reject the legacy self-signed path'
fi
require_text 'GTX 1050 strict-A finish is disabled' "$STRICT_ROOT/finish.err"
[[ "$(sha256sum "$STRICT_CONF")" == "$strict_before" &&
   ! -s "$STRICT_START" && ! -s "$STRICT_MIGRATE" &&
   ! -e "$STRICT_ROOT/staging/VgpuGuestFinish.exe" &&
   ! -e "$STRICT_ROOT/staging/VgpuGuestFinish-GTX1050.zip" &&
   ! -e "$STRICT_ROOT/vm35/log" &&
   ! -e "$STRICT_ROOT/vm35/run" &&
   ! -e "$STRICT_ROOT/vm35/backups" &&
   ! -e "$STRICT_ROOT/shared/bases" &&
   ! -e "$STRICT_ROOT/control" &&
   ! -e "$STRICT_ROOT/shared/assets" ]] \
    || fail 'strict GTX 1050 rejection changed config or published/launched an artifact'

# A pre-policy legacy GTX 1050 config must hit the same fail-closed guard after
# catalog derivation, without being rewritten or receiving a strict ZIP.
LEGACY_STRICT_ROOT="$TMP_DIR/legacy-strict-gtx1050"
LEGACY_STRICT_CONF="$LEGACY_STRICT_ROOT/vm36/vm.conf"
LEGACY_STRICT_START="$LEGACY_STRICT_ROOT/start.trace"
LEGACY_STRICT_MIGRATE="$LEGACY_STRICT_ROOT/migrate.trace"
mkdir -p "$(dirname "$LEGACY_STRICT_CONF")" "$LEGACY_STRICT_ROOT/staging"
cat >"$LEGACY_STRICT_CONF" <<'EOF'
VM_ID=36
VM_UUID=36363636-bbbb-cccc-dddd-eeeeeeeeeeee
GPU_PROFILE=gtx1050_2gb
RTC_CONTRACT=localtime
EOF
touch "$LEGACY_STRICT_ROOT/vm36/disk.qcow2" \
    "$LEGACY_STRICT_START" "$LEGACY_STRICT_MIGRATE"
legacy_strict_before=$(sha256sum "$LEGACY_STRICT_CONF")
if env -i \
    HOME="${HOME:-/tmp}" \
    PATH="$HARNESS/bin:/usr/bin:/bin" \
    VM_ROOT="$LEGACY_STRICT_ROOT" \
    STAGE_DIR="$LEGACY_STRICT_ROOT/staging" \
    FAKE_START_TRACE="$LEGACY_STRICT_START" \
    FAKE_MIGRATE_TRACE="$LEGACY_STRICT_MIGRATE" \
    "$HARNESS/deploy/finish-vgpu-install.sh" 36 \
        --token-file "$TOKEN" --no-final-start \
        >"$LEGACY_STRICT_ROOT/finish.out" 2>"$LEGACY_STRICT_ROOT/finish.err"; then
    fail 'legacy strict GTX 1050 config bypassed the production-signature guard'
fi
require_text 'completed the audited GTX 1050 tuple from GPU_PROFILE' \
    "$LEGACY_STRICT_ROOT/finish.out"
require_text 'GTX 1050 strict-A finish is disabled' \
    "$LEGACY_STRICT_ROOT/finish.err"
[[ "$(sha256sum "$LEGACY_STRICT_CONF")" == "$legacy_strict_before" &&
   ! -s "$LEGACY_STRICT_START" && ! -s "$LEGACY_STRICT_MIGRATE" &&
   ! -e "$LEGACY_STRICT_ROOT/staging/VgpuGuestFinish.exe" &&
   ! -e "$LEGACY_STRICT_ROOT/staging/VgpuGuestFinish-GTX1050.zip" &&
   ! -e "$LEGACY_STRICT_ROOT/vm36/log" &&
   ! -e "$LEGACY_STRICT_ROOT/vm36/run" &&
   ! -e "$LEGACY_STRICT_ROOT/vm36/backups" &&
   ! -e "$LEGACY_STRICT_ROOT/shared/bases" &&
   ! -e "$LEGACY_STRICT_ROOT/control" &&
   ! -e "$LEGACY_STRICT_ROOT/shared/assets" ]] \
    || fail 'legacy strict rejection changed config or published/launched an artifact'

# A manual rescue may remain open for minutes.  If vm.conf changes during that
# time, the old marker intent must not be accepted and the migrator must not run.
CHANGED_ROOT="$TMP_DIR/config-changed"
CHANGED_CONF="$CHANGED_ROOT/vm34/vm.conf"
CHANGED_START="$CHANGED_ROOT/start.trace"
CHANGED_MIGRATE="$CHANGED_ROOT/migrate.trace"
mkdir -p "$(dirname "$CHANGED_CONF")" "$CHANGED_ROOT/staging"
cat >"$CHANGED_CONF" <<'EOF'
VM_ID=34
VM_UUID=34343434-bbbb-cccc-dddd-eeeeeeeeeeee
GPU_NAME="NVIDIA GeForce GT 1030"
RTC_CONTRACT=localtime
EOF
touch "$CHANGED_ROOT/vm34/disk.qcow2" \
    "$CHANGED_START" "$CHANGED_MIGRATE"
if env -i \
        HOME="${HOME:-/tmp}" \
        PATH="$HARNESS/bin:/usr/bin:/bin" \
        VM_ROOT="$CHANGED_ROOT" \
        STAGE_DIR="$CHANGED_ROOT/staging" \
        FAKE_START_TRACE="$CHANGED_START" \
        FAKE_MIGRATE_TRACE="$CHANGED_MIGRATE" \
        FAKE_MUTATE_CONF="$CHANGED_CONF" \
        "$HARNESS/deploy/finish-vgpu-install.sh" 34 \
            --token-file "$TOKEN" --no-final-start \
            >"$CHANGED_ROOT/finish.out" 2>"$CHANGED_ROOT/finish.err"; then
    fail "finish accepted a vm.conf change made during rescue"
fi
require_text 'VM config changed while the rescue guest was running' \
    "$CHANGED_ROOT/finish.err"
[[ ! -s "$CHANGED_MIGRATE" ]] \
    || fail "migrator ran after vm.conf changed during rescue"

# The cache key includes the guest implementation inputs, not just token
# bytes.  A source/manifest change must force one new atomic publication.
CACHE_ROOT="$TMP_DIR/cache-input-root"
CACHE_STAGE="$TMP_DIR/cache-input-stage"
CACHE_TRACE="$TMP_DIR/cache-input-build.trace"
mkdir -p "$CACHE_ROOT/vm41" "$CACHE_STAGE"
cat >"$CACHE_ROOT/vm41/vm.conf" <<'EOF'
VM_ID=41
VM_UUID=41414141-bbbb-cccc-dddd-eeeeeeeeeeee
GPU_NAME="NVIDIA GeForce GT 1030"
RTC_CONTRACT=localtime
EOF
touch "$CACHE_ROOT/vm41/disk.qcow2" "$CACHE_TRACE"
for run in first cached; do
    VM_ROOT="$CACHE_ROOT" STAGE_DIR="$CACHE_STAGE" \
        FAKE_BUILD_TRACE="$CACHE_TRACE" \
        "$HARNESS/deploy/finish-vgpu-install.sh" 41 \
            --token-file "$TOKEN" --build-only >"$TMP_DIR/cache-$run.out"
done
[[ "$(wc -l <"$CACHE_TRACE")" -eq 1 ]] \
    || fail "same build inputs were not reused"
require_text 'reusing shared guest EXE for this token' "$TMP_DIR/cache-cached.out"
printf 'changed\n' >>"$HARNESS/deploy/guest/vgpu-finish/vgpu_guest_finish.manifest"
VM_ROOT="$CACHE_ROOT" STAGE_DIR="$CACHE_STAGE" \
    FAKE_BUILD_TRACE="$CACHE_TRACE" \
    "$HARNESS/deploy/finish-vgpu-install.sh" 41 \
        --token-file "$TOKEN" --build-only >"$TMP_DIR/cache-changed.out"
[[ "$(wc -l <"$CACHE_TRACE")" -eq 2 ]] \
    || fail "changed build input did not rebuild the shared EXE"
require_text 'building shared guest EXE for the selected token' \
    "$TMP_DIR/cache-changed.out"

# Two concurrent build-only callers serialize on the shared package lock;
# neither sees a partial file and only one compilation is needed.
CONCURRENT_STAGE="$TMP_DIR/concurrent-stage"
CONCURRENT_TRACE="$TMP_DIR/concurrent-build.trace"
mkdir -p "$CONCURRENT_STAGE"
: >"$CONCURRENT_TRACE"
concurrent_pids=()
for caller in 1 2; do
    VM_ROOT="$CACHE_ROOT" STAGE_DIR="$CONCURRENT_STAGE" \
        FAKE_BUILD_TRACE="$CONCURRENT_TRACE" FAKE_BUILD_DELAY=0.2 \
        "$HARNESS/deploy/finish-vgpu-install.sh" 41 \
            --token-file "$TOKEN" --build-only \
            >"$TMP_DIR/concurrent-$caller.out" &
    concurrent_pids+=("$!")
done
for concurrent_pid in "${concurrent_pids[@]}"; do
    wait "$concurrent_pid"
done
[[ "$(wc -l <"$CONCURRENT_TRACE")" -eq 1 ]] \
    || fail "concurrent callers compiled or published more than once"
[[ -s "$CONCURRENT_STAGE/VgpuGuestFinish.exe" &&
   "$(stat -c %a "$CONCURRENT_STAGE/VgpuGuestFinish.exe")" == 600 ]] \
    || fail "concurrent shared EXE publication is missing or unsafe"

echo "PASS: offline one-EXE vGPU finish flow"
