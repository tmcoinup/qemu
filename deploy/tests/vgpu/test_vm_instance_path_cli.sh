#!/usr/bin/env bash
# Path-selection coverage for start-vm.sh.  Successful launcher cases are
# dry-runs against temporary bundles; no QEMU process or host device is used.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
START_VM="$REPO_ROOT/deploy/scripts/start-vm.sh"
STORAGE_LIB="$REPO_ROOT/deploy/lib/vm-storage.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_eq() {
    local expected=$1 actual=$2 label=$3

    [[ "$actual" == "$expected" ]] || \
        fail "$label: expected '$expected', got '$actual'"
}

require_text() {
    local needle=$1 file=$2 label=${3:-$1}

    grep -F -- "$needle" "$file" >/dev/null || \
        fail "$label missing from $(basename "$file")"
}

reject_text() {
    local needle=$1 file=$2 label=${3:-$1}

    if grep -F -- "$needle" "$file" >/dev/null; then
        fail "$label unexpectedly present in $(basename "$file")"
    fi
}

reset_storage_env() {
    unset IMAGE_ROOT ISO_DIR STAGE_DIR VM_ROOT VMS_DIR VM_INSTANCES_DIR
    unset VM_INSTANCE_DIR VM_INSTANCE_ID VM_STORAGE_COMPAT_FALLBACK
    unset VM_SHARED_DIR VM_CONTROL_DIR VM_CONFIG_DIR VM_DISK_DIR VM_BASE_DIR
    unset VM_NVRAM_DIR VM_RUN_DIR VM_LOG_DIR VM_ASSET_DIR
    unset VM_DISK_ARCHIVE_DIR VM_BASE_ARCHIVE_DIR VM_NVRAM_BACKUP_DIR
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT

VM_ID=73
DEFAULT_ROOT="$TMP_DIR/default root"
EXACT_PARENT="$TMP_DIR/exact bundles"
EXACT_BUNDLE="$EXACT_PARENT/${VM_ID}"
INSTANCES_PARENT="$TMP_DIR/instance pool with spaces"
INSTANCES_BUNDLE="$INSTANCES_PARENT/${VM_ID}"
VMS_ROOT="$TMP_DIR/complete vms root"
VMS_BUNDLE="$VMS_ROOT/${VM_ID}"

mkdir -p "$DEFAULT_ROOT/legacy/disks" "$EXACT_BUNDLE" \
    "$INSTANCES_BUNDLE" "$VMS_BUNDLE"

# Deliberately create two different old-layout disks.  An explicit selector
# must neither choose one nor report their ambiguity.
printf 'flat legacy disk must stay unused\n' \
    >"$DEFAULT_ROOT/win10-vm${VM_ID}.qcow2"
printf 'categorized legacy disk must stay unused\n' \
    >"$DEFAULT_ROOT/legacy/disks/win10-vm${VM_ID}.qcow2"

# Exercise the pure resolver first so a launcher failure is easier to locate.
(
    reset_storage_env
    VM_ROOT=$DEFAULT_ROOT
    VM_STORAGE_COMPAT_FALLBACK=1
    # shellcheck source=../../../lib/vm-storage.sh
    source "$STORAGE_LIB"
    vm_storage_init
    vm_storage_select_instance_dir "$VM_ID" "$EXACT_BUNDLE"

    assert_eq "$EXACT_BUNDLE" "$(vm_storage_instance_dir "$VM_ID")" \
        "--vm-dir exact bundle"
    assert_eq "$EXACT_BUNDLE/vm.conf" \
        "$(vm_storage_config_path "$VM_ID")" "--vm-dir config"
    assert_eq "$EXACT_BUNDLE/disk.qcow2" \
        "$(vm_storage_disk_path "$VM_ID")" "--vm-dir disk"
    assert_eq "$EXACT_BUNDLE/nvram.fd" \
        "$(vm_storage_nvram_path "$VM_ID")" "--vm-dir NVRAM"
    assert_eq 0 "$VM_STORAGE_COMPAT_FALLBACK" \
        "--vm-dir compatibility fallback"
)

(
    reset_storage_env
    VM_ROOT=$DEFAULT_ROOT
    VM_STORAGE_COMPAT_FALLBACK=1
    source "$STORAGE_LIB"
    vm_storage_init
    vm_storage_select_instances_dir "$INSTANCES_PARENT"

    assert_eq "$INSTANCES_BUNDLE" "$(vm_storage_instance_dir "$VM_ID")" \
        "--instances-dir appends numeric ID"
    assert_eq "$INSTANCES_BUNDLE/vm.conf" \
        "$(vm_storage_config_path "$VM_ID")" "--instances-dir config"
    assert_eq "$INSTANCES_BUNDLE/disk.qcow2" \
        "$(vm_storage_disk_path "$VM_ID")" "--instances-dir disk"
    assert_eq "$INSTANCES_BUNDLE/nvram.fd" \
        "$(vm_storage_nvram_path "$VM_ID")" "--instances-dir NVRAM"
    assert_eq 0 "$VM_STORAGE_COMPAT_FALLBACK" \
        "--instances-dir compatibility fallback"
)

write_vm_conf() {
    local bundle=$1

    cat >"$bundle/vm.conf" <<EOF
VM_ID=$VM_ID
VM_UUID=00000000-0000-4000-8000-000000000073
RTC_CONTRACT=localtime
PLATFORM=i5-4590
CPU_MODEL=Core-i5-4590
TSC_FREQ=3300000000
BOARD_BRAND=Gigabyte
BOARD_MODEL="GA-H97-D3H"
BIOS_VER=F7
BIOS_DATE=09/19/2015
SYS_SN=RT2SKDF1B
MB_SN=NPVUW09WOV3Z
CHASSIS_SN=1N6YC2GT
MEM_BRAND=Kingston
MEM_MODEL=KVR16N11S8/4
MEM_SPEED=1600
MEM_TYPE_BYTE=0x18
MEM_WIDTH=64
MEM_SN=BIK6QG9Q5A9L
SSD_BRAND=Crucial
SSD_MODEL="P3 Plus 512GB"
SSD_SN=XHP8TAQ3W42IH793
GPU_PROFILE=gtx1050_2gb
GPU_PCI_VID=0x10DE
GPU_PCI_DID=0x1C81
GPU_SUB_VID=0x1028
GPU_SUB_DID=0x086B
VM_MAC=00:24:D7:9E:2E:E2
SPOOF_MODE=off
EOF
}

write_vm_conf "$EXACT_BUNDLE"
write_vm_conf "$INSTANCES_BUNDLE"
write_vm_conf "$VMS_BUNDLE"
touch "$TMP_DIR/OVMF_CODE.fd" "$TMP_DIR/OVMF_VARS.fd" \
    "$TMP_DIR/vgpu-host.conf"

# --no-gpu needs no capability probe.  Any invocation of this executable would
# therefore indicate that a dry-run unexpectedly tried to start QEMU.
cat >"$TMP_DIR/qemu-system-x86_64" <<'EOF'
#!/usr/bin/env bash
echo "unexpected QEMU invocation: $*" >&2
exit 99
EOF
chmod +x "$TMP_DIR/qemu-system-x86_64"

run_start() {
    local output=$1 error=$2
    shift 2

    env -i \
        HOME="${HOME:-/tmp}" \
        PATH=/usr/bin:/bin \
        LANG=C.UTF-8 \
        VM_ROOT="$DEFAULT_ROOT" \
        VM_STORAGE_COMPAT_FALLBACK=1 \
        QEMU_BIN="$TMP_DIR/qemu-system-x86_64" \
        OVMF_CODE="$TMP_DIR/OVMF_CODE.fd" \
        OVMF_VARS="$TMP_DIR/OVMF_VARS.fd" \
        VGPU_HOST_CONFIG="$TMP_DIR/vgpu-host.conf" \
        DRY_RUN=1 \
        TPM=0 \
        CPU_ISOLATION=off \
        MONITOR_SYNC=0 \
        MEM_GUARD=0 \
        REPAIR_DISPLAY_VARS=off \
        "$START_VM" "$VM_ID" "$@" >"$output" 2>"$error"
}

assert_selected_bundle() {
    local bundle=$1 output=$2 error=$3 label=$4 quoted_disk quoted_pid

    require_text \
        "DRY_RUN: 实际启动前将创建磁盘: $bundle/disk.qcow2" \
        "$output" "$label missing-disk plan"
    require_text \
        "DRY_RUN: 将创建私有 OVMF VARS: $bundle/nvram.fd" \
        "$output" "$label NVRAM plan"
    printf -v quoted_disk '%q' "$bundle/disk.qcow2"
    printf -v quoted_pid '%q' "$bundle/run/qemu.pid"
    require_text "$quoted_disk" "$output" "$label QEMU disk argv"
    require_text "$quoted_pid" "$output" "$label QEMU pidfile argv"

    reject_text "$DEFAULT_ROOT/win10-vm${VM_ID}.qcow2" "$output" \
        "$label flat legacy disk"
    reject_text "$DEFAULT_ROOT/win10-vm${VM_ID}.qcow2" "$error" \
        "$label flat legacy disk error"
    reject_text "$DEFAULT_ROOT/legacy/disks/win10-vm${VM_ID}.qcow2" \
        "$output" "$label categorized legacy disk"
    reject_text "$DEFAULT_ROOT/legacy/disks/win10-vm${VM_ID}.qcow2" \
        "$error" "$label categorized legacy disk error"
}

run_start "$TMP_DIR/exact.out" "$TMP_DIR/exact.err" \
    --vm-dir "$EXACT_BUNDLE" --dry-run --no-gpu --no-tpm \
    --no-monitor-sync --no-cpu-isolate
assert_selected_bundle "$EXACT_BUNDLE" \
    "$TMP_DIR/exact.out" "$TMP_DIR/exact.err" "--vm-dir"

run_start "$TMP_DIR/instances.out" "$TMP_DIR/instances.err" \
    --instances-dir "$INSTANCES_PARENT" --dry-run --no-gpu --no-tpm \
    --no-monitor-sync --no-cpu-isolate
assert_selected_bundle "$INSTANCES_BUNDLE" \
    "$TMP_DIR/instances.out" "$TMP_DIR/instances.err" "--instances-dir"

run_start "$TMP_DIR/vms.out" "$TMP_DIR/vms.err" \
    --vms-dir "$VMS_ROOT" --dry-run --no-gpu --no-tpm \
    --no-monitor-sync --no-cpu-isolate
assert_selected_bundle "$VMS_BUNDLE" \
    "$TMP_DIR/vms.out" "$TMP_DIR/vms.err" "--vms-dir"
require_text "VM_ROOT=$VMS_ROOT" <(
    "$START_VM" "$VM_ID" --vms-dir "$VMS_ROOT" --print-paths
) "--vms-dir print root"

expect_cli_reject() {
    local label=$1 option=$2
    shift 2
    local output="$TMP_DIR/reject-${label}.out"
    local error="$TMP_DIR/reject-${label}.err"
    local rc

    set +e
    run_start "$output" "$error" "$@"
    rc=$?
    set -e
    [[ "$rc" == 2 ]] || \
        fail "$label: expected CLI status 2, got $rc"
    [[ -s "$error" ]] || fail "$label: $option rejection was silent"
}

expect_cli_reject vm-dir-missing --vm-dir --vm-dir
expect_cli_reject instances-dir-missing --instances-dir --instances-dir
expect_cli_reject vm-dir-relative --vm-dir \
    --vm-dir "relative/${VM_ID}" --dry-run
expect_cli_reject instances-dir-relative --instances-dir \
    --instances-dir "relative instances" --dry-run
expect_cli_reject vm-dir-duplicate --vm-dir \
    --vm-dir "$EXACT_BUNDLE" --vm-dir "$EXACT_BUNDLE" --dry-run
expect_cli_reject instances-dir-duplicate --instances-dir \
    --instances-dir "$INSTANCES_PARENT" \
    --instances-dir "$INSTANCES_PARENT" --dry-run
expect_cli_reject selector-conflict --vm-dir \
    --vm-dir "$EXACT_BUNDLE" --instances-dir "$EXACT_PARENT" --dry-run
expect_cli_reject vms-dir-duplicate --vms-dir \
    --vms-dir "$VMS_ROOT" --vms-dir "$VMS_ROOT" --dry-run
expect_cli_reject vms-selector-conflict --vms-dir \
    --vms-dir "$VMS_ROOT" --vm-dir "$EXACT_BUNDLE" --dry-run

echo "PASS: start-vm explicit bundle/instances paths and fail-closed CLI selection"
