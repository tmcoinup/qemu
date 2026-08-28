#!/usr/bin/env bash
# Isolated behavior tests for start-vm's process-local legacy-A migration
# source exception.  Every launcher call is --dry-run; no VM is started/stopped.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CREATE_VM="$REPO_ROOT/deploy/scripts/create-vm.sh"
START_VM="$REPO_ROOT/deploy/scripts/start-vm.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

require_text() {
    local needle=$1 file=$2 label=${3:-$1}
    grep -F -- "$needle" "$file" >/dev/null \
        || fail "$label missing from $(basename "$file")"
}

run_expect_reject() {
    local label=$1 needle=$2
    shift 2
    if run_start "$@" >"$TMP_DIR/reject.out" 2>"$TMP_DIR/reject.err"; then
        fail "$label was accepted"
    fi
    require_text "$needle" "$TMP_DIR/reject.err" "$label"
}

replace_json() {
    local file=$1 filter=$2 tmp
    tmp="$file.tmp"
    jq "$filter" "$file" >"$tmp"
    chmod 0600 "$tmp"
    mv -T -- "$tmp" "$file"
}

TMP_DIR="$(mktemp -d)"
IMAGE_ROOT="$TMP_DIR"
VM_ROOT="$TMP_DIR/vms"
STAGE_DIR="$TMP_DIR/staging"
EMPTY_VGPU_CONFIG="$TMP_DIR/vgpu-host.conf"
VM_ID=37
MIGRATION_ID=0123456789ABCDEFFEDCBA9876543210
ARCHIVE_SHA=A3D7AD8B8082D6AC6214565B4766B5190A819BC9B7574765B14897E0DB809690
INF_SHA=67A240E1D464CF97DABFEC1A7CECF000EAA9DDFD702F32BA2C8771F17905DC2B
CAT_SHA=56B07BD93280BBDA761CB5C9A3A13262C3605320D7286953989E2A5B16D5EC6F

cleanup() {
    rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT

for dependency in jq sha256sum truncate awk sed stat; do
    command -v "$dependency" >/dev/null 2>&1 \
        || fail "missing test dependency: $dependency"
done
[[ -x "$CREATE_VM" && -x "$START_VM" ]] \
    || fail "root VM lifecycle scripts are unavailable"

touch "$TMP_DIR/OVMF_CODE.fd" "$TMP_DIR/OVMF_VARS.fd" "$EMPTY_VGPU_CONFIG"
cat >"$TMP_DIR/qemu-system-x86_64" <<'EOF'
#!/bin/sh
if [ "$#" -eq 2 ] && [ "$1" = -display ] && [ "$2" = help ]; then
    printf '%s\n' gtk sdl
    exit 0
fi
if [ "$#" -eq 2 ] && [ "$1" = -device ] \
        && [ "$2" = vfio-pci-nohotplug,help ]; then
    printf '  ramfb=<bool>\n'
    exit 0
fi
if [ "$#" -eq 2 ] && [ "$1" = -device ] \
        && [ "$2" = pcie-root-port,help ]; then
    printf '%s\n' \
        '  x-speed=<PCIELinkSpeed>' \
        '  x-width=<PCIELinkWidth>' \
        '  x-pci-vendor-id=<uint32>' \
        '  x-pci-device-id=<uint32>' \
        '  x-pci-revision=<uint32>'
    exit 0
fi
if [ "$#" -eq 2 ] && [ "$1" = -object ] && [ "$2" = fb-shm,help ]; then
    printf 'fb-shm options:\n  path=<string>\n  rate=<uint32>\n'
    exit 0
fi
echo "unexpected fake QEMU invocation: $*" >&2
exit 99
EOF
chmod +x "$TMP_DIR/qemu-system-x86_64"

env -i \
    HOME="${HOME:-/tmp}" \
    PATH=/usr/bin:/bin \
    IMAGE_ROOT="$IMAGE_ROOT" \
    VM_ROOT="$VM_ROOT" \
    STAGE_DIR="$STAGE_DIR" \
    "$CREATE_VM" "$VM_ID" \
        --platform i5-4590-h81m-s1-8g \
        --ssd-profile samsung-850-pro-512gb \
        --gpu-profile gtx1050_2gb \
        --monitor-profile dell-se2416h >"$TMP_DIR/create.out"

CONF="$VM_ROOT/${VM_ID}/vm.conf"
chmod u+w "$CONF"
sed -i 's/^SPOOF_MODE=.*/SPOOF_MODE=A/' "$CONF"
chmod 0444 "$CONF"
UUID=$(sed -n 's/^VM_UUID=//p' "$CONF")
PROFILE=$(sed -n 's/^GPU_PROFILE=//p' "$CONF")
GPU_NAME=$(
    sed -n 's/^GPU_NAME=//p' "$CONF" |
        sed -E 's/^"(.*)"$/\1/'
)
[[ "$UUID" =~ ^[0-9a-f-]{36}$ && "$PROFILE" == gtx1050_2gb &&
   "$GPU_NAME" == "NVIDIA GeForce GTX 1050" ]] \
    || fail "generated fixture identity is unexpected"

PACKAGE_ROOT="$STAGE_DIR/VgpuProductionMigration"
PACKAGE_DIR="$PACKAGE_ROOT/vm${VM_ID}-${UUID}"
STATE="$PACKAGE_DIR/host-state.json"
CONTRACT="$PACKAGE_DIR/migration-contract.json"
EXE="$PACKAGE_DIR/VgpuProductionMigration.exe"
mkdir -p "$PACKAGE_DIR"
chmod 0700 "$PACKAGE_ROOT" "$PACKAGE_DIR"

jq -n \
    --arg migrationId "$MIGRATION_ID" \
    --argjson vmId "$VM_ID" \
    --arg vmUuid "${UUID^^}" \
    --arg gpuProfile "$PROFILE" \
    --arg gpuName "$GPU_NAME" \
    --arg archiveSha "$ARCHIVE_SHA" \
    --arg infSha "$INF_SHA" \
    --arg catSha "$CAT_SHA" '
    {
        schemaVersion: 1,
        migrationId: $migrationId,
        vmId: $vmId,
        vmUuid: $vmUuid,
        gpuProfile: $gpuProfile,
        gpuName: $gpuName,
        legacyPnpId: "PCI\\VEN_10DE&DEV_1C81&SUBSYS_11C01028",
        nativePnpId: "PCI\\VEN_10DE&DEV_1E30",
        driver: {
            archiveName: "538.33-display-driver.zip",
            archiveBytes: 860703853,
            archiveSha256: $archiveSha,
            infRelativePath: "Display.Driver/nvgridsw.inf",
            infSha256: $infSha,
            catalogRelativePath: "Display.Driver/nvgridsw.cat",
            catalogSha256: $catSha,
            driverVersion: "31.0.15.3833"
        },
        gpuz: {
            name: "GpuZProfile.exe",
            sha256:
              "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        }
    }
' >"$CONTRACT"
chmod 0600 "$CONTRACT"

# Keep the fixture sparse while exercising the same lower bound as the real
# 821 MiB launcher.  sha256sum still observes its exact declared bytes.
truncate -s 268435457 "$EXE"
chmod 0600 "$EXE"
EXE_SHA=$(sha256sum "$EXE" | awk '{print toupper($1)}')
EXE_BYTES=$(stat -c %s "$EXE")

publish_state() {
    local config_sha contract_sha
    config_sha=$(sha256sum "$CONF" | awk '{print toupper($1)}')
    contract_sha=$(sha256sum "$CONTRACT" | awk '{print toupper($1)}')
    jq -n \
        --arg migrationId "$MIGRATION_ID" \
        --argjson vmId "$VM_ID" \
        --arg vmUuid "$UUID" \
        --arg gpuProfile "$PROFILE" \
        --arg gpuName "$GPU_NAME" \
        --arg sourceConfigSha "$config_sha" \
        --arg contractSha "$contract_sha" \
        --arg exeSha "$EXE_SHA" \
        --argjson exeBytes "$EXE_BYTES" \
        --arg archiveSha "$ARCHIVE_SHA" \
        --arg infSha "$INF_SHA" \
        --arg catSha "$CAT_SHA" '
        {
            schemaVersion: 1,
            migrationId: $migrationId,
            vmId: $vmId,
            vmUuid: $vmUuid,
            gpuProfile: $gpuProfile,
            gpuName: $gpuName,
            sourceHostMode: "A",
            sourceConfigSha256: $sourceConfigSha,
            guestContractSha256: $contractSha,
            exeSha256: $exeSha,
            exeBytes: $exeBytes,
            archiveSha256: $archiveSha,
            sourceInfSha256: $infSha,
            sourceCatalogSha256: $catSha,
            requiredHostModeAfterReceipt: "B"
        }
    ' >"$STATE"
    chmod 0600 "$STATE"
}
publish_state
cp -- "$CONF" "$TMP_DIR/conf.pristine"
cp -- "$STATE" "$TMP_DIR/state.pristine"
cp -- "$CONTRACT" "$TMP_DIR/contract.pristine"
chmod 0600 "$TMP_DIR/conf.pristine" "$TMP_DIR/state.pristine" \
    "$TMP_DIR/contract.pristine"

restore_package_json() {
    cp -- "$TMP_DIR/state.pristine" "$STATE"
    cp -- "$TMP_DIR/contract.pristine" "$CONTRACT"
    chmod 0600 "$STATE" "$CONTRACT"
}

run_start() {
    env -i \
        HOME="${HOME:-/tmp}" \
        PATH=/usr/bin:/bin \
        DISPLAY=:99 \
        IMAGE_ROOT="$IMAGE_ROOT" \
        VM_ROOT="$VM_ROOT" \
        STAGE_DIR="$STAGE_DIR" \
        QEMU_BIN="$TMP_DIR/qemu-system-x86_64" \
        OVMF_CODE="$TMP_DIR/OVMF_CODE.fd" \
        OVMF_VARS="$TMP_DIR/OVMF_VARS.fd" \
        VGPU_HOST_CONFIG="$EMPTY_VGPU_CONFIG" \
        REPAIR_DISPLAY_VARS=off \
        "$START_VM" "$VM_ID" --dry-run --no-tpm --cpu-isolate=false \
            --no-monitor-sync "$@"
}

# The ordinary strict-A guard remains unchanged before and after a successful
# explicitly authorized dry run.
run_expect_reject \
    "ordinary strict-A startup" \
    "strict-A startup is disabled"
CONFIG_BEFORE=$(sha256sum "$CONF")
STATE_BEFORE=$(sha256sum "$STATE")
CONTRACT_BEFORE=$(sha256sum "$CONTRACT")
run_start --production-migration-source \
    >"$TMP_DIR/authorized.out" 2>"$TMP_DIR/authorized.err" \
    || {
        cat "$TMP_DIR/authorized.err" >&2
        fail "exact production migration source was rejected"
    }
require_text \
    "production-migration-source authorized for this invocation only" \
    "$TMP_DIR/authorized.out" "process-local authorization"
require_text \
    "GPU target: NVIDIA GeForce GTX 1050 (name + consumer PCI ID spoof)" \
    "$TMP_DIR/authorized.out" "authorized A identity"
[[ "$(sha256sum "$CONF")" == "$CONFIG_BEFORE" &&
   "$(sha256sum "$STATE")" == "$STATE_BEFORE" &&
   "$(sha256sum "$CONTRACT")" == "$CONTRACT_BEFORE" ]] \
    || fail "authorized dry run mutated config/package evidence"
run_expect_reject \
    "non-persistent strict-A follow-up" \
    "strict-A startup is disabled"

run_expect_reject \
    "duplicate source switch" \
    "--production-migration-source may appear only once" \
    --production-migration-source --production-migration-source
run_expect_reject \
    "source switch with off override" \
    "valid only for the exact legacy A source mode" \
    --production-migration-source --no-spoof
run_expect_reject \
    "source switch hidden as --extra value" \
    "strict-A startup is disabled" \
    --extra --production-migration-source
run_expect_reject \
    "source switch rescue mode" \
    "only the normal native vGPU display may boot the A source" \
    --production-migration-source --rescue-sdl

chmod u+w "$CONF"
printf '\n# tamper\n' >>"$CONF"
chmod 0444 "$CONF"
run_expect_reject \
    "changed source config hash" \
    "host-state does not exactly match this VM/config/source mode" \
    --production-migration-source
chmod u+w "$CONF"
cp -- "$TMP_DIR/conf.pristine" "$CONF"
chmod 0444 "$CONF"
[[ "$(sha256sum "$CONF")" == "$CONFIG_BEFORE" ]] \
    || fail "test failed to restore config bytes"

replace_json "$STATE" '.vmId = 38'
run_expect_reject \
    "host-state VM ID mismatch" \
    "host-state does not exactly match this VM/config/source mode" \
    --production-migration-source
restore_package_json

replace_json "$STATE" '.vmUuid = "00000000-0000-4000-8000-000000000037"'
run_expect_reject \
    "host-state UUID mismatch" \
    "host-state does not exactly match this VM/config/source mode" \
    --production-migration-source
restore_package_json

replace_json "$STATE" '.gpuProfile = "gt1030_2gb"'
run_expect_reject \
    "host-state profile mismatch" \
    "host-state does not exactly match this VM/config/source mode" \
    --production-migration-source
restore_package_json

replace_json "$STATE" '.sourceHostMode = "B"'
run_expect_reject \
    "host-state source mode mismatch" \
    "host-state does not exactly match this VM/config/source mode" \
    --production-migration-source
restore_package_json

replace_json "$CONTRACT" '.nativePnpId = "PCI\\\\VEN_10DE&DEV_1C81"'
run_expect_reject \
    "contract hash mismatch" \
    "migration-contract hash does not match host-state" \
    --production-migration-source
restore_package_json

# Even if a tamperer updates host-state's contract hash, the exact production
# tuple and cross-file VM identity remain independently enforced.
replace_json "$CONTRACT" '.gpuProfile = "gt1030_2gb"'
CONTRACT_TAMPER_SHA=$(sha256sum "$CONTRACT" | awk '{print toupper($1)}')
replace_json "$STATE" \
    ".guestContractSha256 = \"$CONTRACT_TAMPER_SHA\""
run_expect_reject \
    "semantically changed contract" \
    "migration-contract identity/production-driver tuple is invalid" \
    --production-migration-source
restore_package_json

truncate -s 0 "$EXE"
truncate -s "$EXE_BYTES" "$EXE"
printf X | dd of="$EXE" bs=1 seek=$((EXE_BYTES - 1)) conv=notrunc \
    status=none
run_expect_reject \
    "migration EXE hash mismatch" \
    "migration EXE does not match host-state" \
    --production-migration-source
truncate -s 0 "$EXE"
truncate -s "$EXE_BYTES" "$EXE"

chmod 0640 "$STATE"
run_expect_reject \
    "non-private host-state mode" \
    "package node owner/mode mismatch" \
    --production-migration-source
chmod 0600 "$STATE"

echo "PASS: process-local production-migration-source start gate"
