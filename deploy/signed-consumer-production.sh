#!/usr/bin/env bash
# Generic G-11 outer-only consumer PCI production workflow.
#
# A qualification is global and reusable by any VM whose canonical GPU
# profile and current host compatibility facts match.  Staged/validated
# receipts remain bound to one VM UUID and one experiment.  This wrapper never
# writes a Windows disk: receipt reads use qemu-nbd snapshot + ro,norecover.
set -euo pipefail
umask 077
export LC_ALL=C

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/vm-storage.sh
source "$here/lib/vm-storage.sh"
# shellcheck source=lib/signed-consumer-catalog.sh
source "$here/lib/signed-consumer-catalog.sh"

usage() {
    cat <<'EOF'
用法：
  sudo ./deploy/signed-consumer-production.sh record-proof PROOF_VM_ID \
      --experiment-id ID --confirm-source-proof [--driver-key KEY]

  ./deploy/signed-consumer-production.sh stage TARGET_VM_ID \
      [--qualification-id ID] [--driver-key KEY] [--driver-exe FILE]

  sudo ./deploy/signed-consumer-production.sh commit TARGET_VM_ID \
      --experiment-id ID
  sudo ./deploy/signed-consumer-production.sh finalize TARGET_VM_ID
  sudo ./deploy/signed-consumer-production.sh rollback TARGET_VM_ID
  ./deploy/signed-consumer-production.sh status TARGET_VM_ID

通用流程：先在一台明确可删除的同 profile 克隆上完成 outer-only Code-0
验收并 record-proof。资格证明按 profile + 原版 WHQL driver + 当前 QEMU/
kernel/NVIDIA module/physical GPU/mdev resource 内容寻址，源 VM 删除后仍可供
任意匹配 VM 使用。目标 VM 依次
stage -> guest 管理员运行 Run-Phase1.cmd -> 完整关机 -> commit -> 正常启动
一次等待 SYSTEM 验收/关机 -> finalize。失败时完整关机后 rollback。

可选：
  --proof-root DIR       全局资格目录
  --output-root DIR      VM-bound package 目录
  --receipt-file FILE    record-proof 时显式提供 validated receipt
  --qualification-id ID  多资格时显式选择 64 位内容 ID
  --driver-key KEY       显式选择审核过的正式签名 driver 条目
  --driver-exe FILE      stage 使用的原版 NVIDIA 安装包

本工具不写 BCD，不启用 testsigning/nointegritychecks，不导入证书，不修改
INF/CAT/SYS，也不安装测试签名或自签名内核驱动。
EOF
}

die() { echo "[signed-consumer-production] ERROR: $*" >&2; exit 2; }
log() { echo "[signed-consumer-production] $*"; }
sha256_upper() { sha256sum -- "$1" | awk '{print toupper($1)}'; }

[[ $# -ge 1 ]] || { usage >&2; exit 2; }
ACTION=$1
shift
VM_ID=''
if [[ "$ACTION" != help && "$ACTION" != --help && "$ACTION" != -h ]]; then
    (($# >= 1)) || { usage >&2; exit 2; }
    VM_ID=$1
    shift
    vm_storage_id_is_supported "$VM_ID" || die 'VM_ID 非法'
fi

PROOF_ROOT=''
OUTPUT_ROOT=''
RECEIPT_FILE=''
EXPERIMENT_ID=''
QUALIFICATION_ID=''
DRIVER_KEY=''
DRIVER_EXE=''
CONFIRM_SOURCE_PROOF=0
while (($#)); do
    case "$1" in
        --proof-root) (($# >= 2)) || die '--proof-root 缺参数'; PROOF_ROOT=$2; shift 2 ;;
        --output-root) (($# >= 2)) || die '--output-root 缺参数'; OUTPUT_ROOT=$2; shift 2 ;;
        --receipt-file) (($# >= 2)) || die '--receipt-file 缺参数'; RECEIPT_FILE=$2; shift 2 ;;
        --experiment-id) (($# >= 2)) || die '--experiment-id 缺参数'; EXPERIMENT_ID=$2; shift 2 ;;
        --qualification-id) (($# >= 2)) || die '--qualification-id 缺参数'; QUALIFICATION_ID=$2; shift 2 ;;
        --driver-key) (($# >= 2)) || die '--driver-key 缺参数'; DRIVER_KEY=$2; shift 2 ;;
        --driver-exe) (($# >= 2)) || die '--driver-exe 缺参数'; DRIVER_EXE=$2; shift 2 ;;
        --confirm-source-proof) CONFIRM_SOURCE_PROOF=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "未知参数: $1" ;;
    esac
done

for dependency in jq sha256sum stat realpath install awk flock pgrep grep sed; do
    command -v "$dependency" >/dev/null 2>&1 || die "缺少依赖: $dependency"
done
signed_consumer_catalog_validate || die 'signed-consumer catalog 自检失败'
vm_storage_init
PROOF_ROOT=${PROOF_ROOT:-$STAGE_DIR/SignedConsumerQualifications-v2}
OUTPUT_ROOT=${OUTPUT_ROOT:-$STAGE_DIR/SignedConsumerPackages-v2}
RUNTIME_PROOF_ROOT=$STAGE_DIR/SignedConsumerRuntimeProofs-v2
QEMU_PATH=${QEMU_BIN:-$here/../build/qemu-system-x86_64}
QEMU_PATH=$(realpath -e -- "$QEMU_PATH") || die '找不到当前 QEMU binary'
QEMU_SHA=$(signed_consumer_qemu_sha256 "$QEMU_PATH") || die 'QEMU binary 不安全或不可执行'
HOST_DRIVER_SHA=$(signed_consumer_host_driver_sha256) || die '无法读取当前 NVIDIA host driver 事实'
[[ "$PROOF_ROOT" == /* && "$PROOF_ROOT" != / &&
   "$OUTPUT_ROOT" == /* && "$OUTPUT_ROOT" != / ]] || die 'proof/output root 必须是绝对非根目录'
PROOF_ROOT=$(realpath -m -- "$PROOF_ROOT")
OUTPUT_ROOT=$(realpath -m -- "$OUTPUT_ROOT")

literal_from() {
    local file=$1 field=$2 value
    mapfile -t literal_lines < <(sed -n -E "s/^[[:space:]]*${field}=//p" "$file")
    ((${#literal_lines[@]} == 1)) || die "$(basename "$file") 必须恰好一个 ${field}= literal"
    value=${literal_lines[0]%$'\r'}
    value=$(sed -E 's/[[:space:]]+#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//' <<<"$value")
    value=${value#\"}; value=${value%\"}; value=${value#\'}; value=${value%\'}
    [[ -n "$value" ]] || die "$(basename "$file") ${field} 为空"
    printf '%s\n' "$value"
}

literal_optional_from() {
    local file=$1 field=$2 fallback=$3 count
    count=$(grep -Ec "^[[:space:]]*${field}=" "$file")
    case "$count" in
        0) printf '%s\n' "$fallback" ;;
        1) literal_from "$file" "$field" ;;
        *) die "$(basename "$file") 不能重复定义 ${field}" ;;
    esac
}

load_vm_contract() {
    local requested=$1 config_id config_name config_vid config_did config_subvid
    local config_subdid config_mdev config_fb config_resource_profile
    local config_resource_fb
    vm_storage_require_namespace_ready "$requested" || die "vm${requested} storage layout 未就绪"
    CONF=$(vm_storage_config_path "$requested")
    DISK=$(vm_storage_disk_path "$requested")
    INSTANCE_DIR=$(vm_storage_instance_dir "$requested")
    [[ -f "$CONF" && ! -L "$CONF" && -r "$CONF" &&
       -f "$DISK" && ! -L "$DISK" ]] || die "vm${requested} config/disk 缺失或不安全"
    config_id=$(literal_from "$CONF" VM_ID)
    [[ "$config_id" == "$requested" ]] || die "vm.conf VM_ID=$config_id 与目标 vm${requested} 不一致"
    CONFIG_UUID=$(literal_from "$CONF" VM_UUID)
    [[ "$CONFIG_UUID" =~ ^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$ ]] \
        || die 'VM_UUID 非法'
    CONFIG_PROFILE=$(literal_from "$CONF" GPU_PROFILE)
    config_name=$(literal_from "$CONF" GPU_NAME)
    config_vid=$(literal_from "$CONF" GPU_PCI_VID)
    config_did=$(literal_from "$CONF" GPU_PCI_DID)
    config_subvid=$(literal_from "$CONF" GPU_SUB_VID)
    config_subdid=$(literal_from "$CONF" GPU_SUB_DID)
    config_mdev=$(literal_from "$CONF" VGPU_MDEV_PROFILE)
    signed_consumer_profile_assert_config "$CONFIG_PROFILE" "$config_name" \
        "$config_vid" "$config_did" "$config_subvid" "$config_subdid" \
        "$config_mdev" || die "vm${requested} GPU profile 字段不是 canonical catalog 值"
    config_fb=$(literal_from "$CONF" VGPU_FB_MB)
    config_resource_profile=$(literal_optional_from "$CONF" VGPU_RESOURCE_PROFILE "$config_mdev")
    config_resource_fb=$(literal_optional_from "$CONF" VGPU_RESOURCE_FB_MB "$config_fb")
    [[ "$config_resource_profile" == "$SC_CANONICAL_MDEV_PROFILE" &&
       "$config_resource_fb" == "$SC_CANONICAL_FB_MB" ]] \
        || die "vm${requested} 实际 mdev resource 与 canonical profile 不一致"
    PROFILE_SHA=$(signed_consumer_profile_sha256 "$CONFIG_PROFILE") || die '无法计算 profile digest'
    [[ "$(literal_from "$CONF" SPOOF_MODE)" == B &&
       "$(literal_from "$CONF" VGPU_IDENTITY_TARGET)" == name-only ]] \
        || die "vm${requested} 必须保持 B/name-only"
    ! grep -Eq '^[[:space:]]*(SPOOF=|SPOOF_MODE=A|VGPU_MDEV_INTERNAL_PCI_IDENTITY=1|VGPU_MDEV_FRL_ENABLED=|VGPU_PATCHED_DRIVER_)' "$CONF" \
        || die "vm${requested} 含 legacy A/internal/FRL/patched marker"
}

select_driver_for_loaded_profile() {
    local selected=$DRIVER_KEY
    if [[ -z "$selected" ]]; then
        selected=$(signed_consumer_driver_default_for_profile "$CONFIG_PROFILE") \
            || die "profile $CONFIG_PROFILE 尚无可复用资格；需先在可删除克隆上资格化"
    fi
    signed_consumer_driver_load "$selected" || die 'driver key 不在审核目录'
    signed_consumer_driver_assert_production_enabled \
        || die '该 driver 条目已被稳定性验收隔离；只允许在可删除克隆中复现实验'
    signed_consumer_driver_assert_profile || die 'driver key 与 VM GPU profile 不匹配'
    HOST_STACK_SHA=$(signed_consumer_host_stack_sha256 \
        "$SC_CANONICAL_MDEV_PROFILE" "$SC_CANONICAL_FB_MB") \
        || die '无法读取当前 kernel/NVIDIA module/physical GPU/mdev type 事实'
    DRIVER_KEY=$selected
}

acquire_stopped_locks() {
    vm_storage_validate_root_path "$VM_ROOT" 'VM root' || die 'VM root 不安全'
    mkdir -p -- "$VM_RUN_DIR"
    exec {STORAGE_LOCK_FD}>"$VM_RUN_DIR/.storage.lock"
    flock -s "$STORAGE_LOCK_FD"
    vm_storage_prepare_instance "$VM_ID"
    exec {START_LOCK_FD}>"$(vm_storage_run_path "$VM_ID" start.lock)"
    flock -n "$START_LOCK_FD" || die "vm${VM_ID} start lock 忙"
    exec {DISK_LOCK_FD}>"$(vm_storage_run_path "$VM_ID" disk.lock)"
    flock -n -x "$DISK_LOCK_FD" || die "vm${VM_ID} disk lock 忙"
    if pgrep -f "qemu-system-x86_64.*-name[[:space:]]+vm${VM_ID}([,[:space:]]|$)" >/dev/null 2>&1 ||
            pgrep -af qemu-system-x86_64 2>/dev/null | grep -F -- "$DISK" >/dev/null; then
        die "vm${VM_ID} 正在运行；必须完整关机"
    fi
}

copy_stopped_receipt() (
    local guest_relative=$1 destination=$2 partition='' mounted=0 probe_rc candidate mount_point
    for dependency in qemu-nbd ntfs-3g.probe mount umount blkid modprobe udevadm; do
        command -v "$dependency" >/dev/null 2>&1 || die "缺少停机核验依赖: $dependency"
    done
    # shellcheck source=lib/nbd-lock.sh
    source "$here/lib/nbd-lock.sh"
    NBD=/dev/nbd0
    modprobe nbd max_part=16 2>/dev/null || true
    mount_point=$(mktemp -d "/tmp/signed-consumer-vm${VM_ID}.XXXXXXXX")
    cleanup_offline_receipt() {
        local rc=$?
        ((mounted == 0)) || umount "$mount_point" 2>/dev/null || rc=70
        nbd_disconnect_if_owned
        rmdir "$mount_point" 2>/dev/null || true
        return "$rc"
    }
    trap cleanup_offline_receipt EXIT
    nbd_connect NBD "$DISK" snapshot
    udevadm settle --timeout=10
    for candidate in "${NBD}p3" "${NBD}p4" "${NBD}p2" "${NBD}p1" "${NBD}p5"; do
        [[ -b "$candidate" && "$(blkid -o value -s TYPE "$candidate" 2>/dev/null)" == ntfs ]] || continue
        if mount -t ntfs-3g -o ro,norecover "$candidate" "$mount_point" 2>/dev/null; then
            mounted=1
            if [[ -f "$mount_point/Windows/System32/config/SYSTEM" ]]; then
                partition=$candidate
                umount "$mount_point" || die 'Windows 分区探测卸载失败'
                mounted=0
                break
            fi
            umount "$mount_point" || die 'NTFS 探测卸载失败'
            mounted=0
        fi
    done
    [[ -n "$partition" ]] || die '找不到 Windows 系统分区'
    probe_rc=0; ntfs-3g.probe --readwrite "$partition" || probe_rc=$?
    case "$probe_rc" in
        0) ;;
        14) die 'Windows 仍休眠/Fast Startup；必须完整关机' ;;
        15) die 'Windows 卷 dirty；先正常启动并完整关机' ;;
        *) die "NTFS clean probe 失败 rc=$probe_rc" ;;
    esac
    mount -t ntfs-3g -o ro,norecover "$partition" "$mount_point" || die '只读挂载 Windows 失败'
    mounted=1
    local source="$mount_point/$guest_relative"
    [[ -f "$source" && ! -L "$source" ]] || die "guest 回执不存在: $guest_relative"
    install -m 0600 -- "$source" "$destination"
    umount "$mount_point" || die '卸载 Windows 失败'
    mounted=0
    nbd_disconnect_if_owned
    trap - EXIT
    rmdir "$mount_point" 2>/dev/null || true
)

verify_validated_receipt() {
    local file=$1 vm_id=$2 vm_uuid=$3 experiment=$4 contract_sha=${5:-}
    [[ -f "$file" && ! -L "$file" && "$(stat -c %h -- "$file")" == 1 ]] \
        || die "validated 回执缺失或不安全: $file"
    jq -e --argjson vmId "$vm_id" --arg vmUuid "${vm_uuid,,}" \
        --arg experimentId "$experiment" --arg contractSha "$contract_sha" \
        --arg gpuName "$SC_CANONICAL_GPU_NAME" --arg pnp "$SC_CANONICAL_TARGET_PNP" \
        --arg version "$SC_DRIVER_VERSION" --arg infSha "$SC_INF_SHA256" \
        --arg catSha "$SC_CATALOG_SHA256" --arg sysSha "$SC_KERNEL_SHA256" \
        --arg signer "$SC_CATALOG_SIGNER_THUMBPRINT" '
        .schemaVersion == 1 and .phase == "validated" and .result == "pass" and
        .vmId == $vmId and .vmUuid == $vmUuid and .experimentId == $experimentId and
        ($contractSha == "" or .contractSha256 == $contractSha) and
        (.contractSha256 | test("^[0-9A-F]{64}$")) and
        .displayCount == 1 and .gpuName == $gpuName and .exactHardwareId == $pnp and
        (.pnpDeviceId | startswith($pnp)) and .configManagerErrorCode == 0 and
        .driverVersion == $version and .activeInfSha256 == $infSha and
        .activeCatalogSha256 == $catSha and .driverStoreKernelSha256 == $sysSha and
        .loadedKernelSha256 == $sysSha and .activeCatalogSignerThumbprint == $signer and
        .testsigning == false and .nointegritychecks == false and
        .bcdChanged == false and .bcdAfterSha256 == .bcdBeforeSha256 and
        (.completedUtc | type == "string" and length > 0)
    ' "$file" >/dev/null || die 'validated 回执未证明精确 profile/Code0/WHQL/BCD unchanged'
}

verify_staged_receipt() {
    local file=$1 vm_id=$2 vm_uuid=$3 experiment=$4 contract_sha=$5
    jq -e --argjson vmId "$vm_id" --arg vmUuid "${vm_uuid,,}" \
        --arg experimentId "$experiment" --arg contractSha "$contract_sha" \
        --arg baseline "$SC_BASELINE_PNP_PREFIX" --arg baselineVersion "$SC_BASELINE_DRIVER_VERSION" \
        --arg pnp "$SC_CANONICAL_TARGET_PNP" --arg version "$SC_DRIVER_VERSION" \
        --arg infSha "$SC_INF_SHA256" --arg catSha "$SC_CATALOG_SHA256" \
        --arg sysSha "$SC_KERNEL_SHA256" --arg signer "$SC_CATALOG_SIGNER_THUMBPRINT" '
        .schemaVersion == 1 and .phase == "staged" and .result == "pass" and
        .vmId == $vmId and .vmUuid == $vmUuid and .experimentId == $experimentId and
        .contractSha256 == $contractSha and (.baselinePnpId | startswith($baseline)) and
        .baselineDriverVersion == $baselineVersion and
        .activeInfAfter == .activeInfBefore and .activeDriverChanged == false and
        .targetPnpId == $pnp and .targetDriverVersion == $version and
        .driverStoreInfSha256 == $infSha and .driverStoreCatalogSha256 == $catSha and
        .driverStoreKernelSha256 == $sysSha and .catalogSignerThumbprint == $signer and
        .testsigning == false and .nointegritychecks == false and
        .bcdChanged == false and .bcdAfterSha256 == .bcdBeforeSha256
    ' "$file" >/dev/null || die 'staged 回执未证明 add-only/B-native/WHQL/BCD unchanged'
}

verify_qualification_marker() {
    local file=$1 expected_id=${2:-} mode id
    [[ -f "$file" && ! -L "$file" && "$(stat -c %h -- "$file")" == 1 ]] \
        || die "qualification 缺失或不安全: $file"
    [[ "$(stat -c %u -- "$file")" == 0 ]] \
        || die 'qualification 必须由 root record-proof 生成并持有'
    mode=$(stat -c %a -- "$file"); (( (8#$mode & 022) == 0 )) || die 'qualification 可被 group/world 写入'
    id=$(jq -er '.qualificationId' "$file") || die 'qualificationId 缺失'
    [[ -z "$expected_id" || "$id" == "$expected_id" ]] || die 'qualification ID 与请求不一致'
    jq -e --arg id "$id" --arg purpose "$SIGNED_CONSUMER_QUALIFICATION_PURPOSE" \
        --arg backend "$SIGNED_CONSUMER_BACKEND_ABI" --arg profile "$SC_CANONICAL_GPU_PROFILE" \
        --arg profileSha "$PROFILE_SHA" --arg gpuName "$SC_CANONICAL_GPU_NAME" \
        --arg pnp "$SC_CANONICAL_TARGET_PNP" --arg driverKey "$SC_DRIVER_KEY" \
        --arg version "$SC_DRIVER_VERSION" --arg infSha "$SC_INF_SHA256" \
        --arg catSha "$SC_CATALOG_SHA256" --arg sysSha "$SC_KERNEL_SHA256" \
        --arg installerSha "$SC_INSTALLER_SHA256" \
        --arg packageBuilder "$SC_PACKAGE_BUILDER" \
        --arg packageBuilderSha "$SC_PACKAGE_BUILDER_SHA256" \
        --arg guestValidator "$SC_GUEST_VALIDATOR" \
        --arg guestValidatorSha "$SC_GUEST_VALIDATOR_SHA256" \
        --arg signer "$SC_CATALOG_SIGNER_THUMBPRINT" --arg baseline "$SC_BASELINE_PNP_PREFIX" \
        --arg baselineVersion "$SC_BASELINE_DRIVER_VERSION" --arg qemuSha "$QEMU_SHA" \
        --arg hostDriverSha "$HOST_DRIVER_SHA" --arg hostStackSha "$HOST_STACK_SHA" \
        --arg mdev "$SC_CANONICAL_MDEV_PROFILE" \
        --argjson fb "$SC_CANONICAL_FB_MB" '
        (keys | sort) == ["compatibility","consumer","driver","purpose","qualificationId","result","schemaVersion","sourceProof"] and
        .schemaVersion == 2 and .purpose == $purpose and .qualificationId == $id and
        .consumer == {gpuProfile:$profile, profileSha256:$profileSha, gpuName:$gpuName, exactHardwareId:$pnp} and
        .driver == {key:$driverKey, version:$version, infSha256:$infSha, catalogSha256:$catSha,
                    kernelSha256:$sysSha, catalogSignerThumbprint:$signer,
                    baselinePnpPrefix:$baseline, baselineDriverVersion:$baselineVersion,
                    installerSha256:$installerSha, packageBuilder:$packageBuilder,
                    packageBuilderSha256:$packageBuilderSha,
                    guestValidator:$guestValidator,
                    guestValidatorSha256:$guestValidatorSha} and
        .compatibility == {backendAbi:$backend, qemuSha256:$qemuSha,
                           hostDriverSha256:$hostDriverSha, hostStackSha256:$hostStackSha,
                           mdevProfile:$mdev,
                           framebufferMb:$fb, projection:"outer-only", internalIdentity:"native"} and
        (.sourceProof.vmId | type == "number") and (.sourceProof.vmUuid | test("^[0-9a-f-]{36}$")) and
        (.sourceProof.experimentId | test("^[0-9A-F]{32}$")) and
        (.sourceProof.contractSha256 | test("^[0-9A-F]{64}$")) and
        (.sourceProof.receiptSha256 | test("^[0-9A-F]{64}$")) and
        (.sourceProof.completedUtc | type == "string" and length > 0) and
        .result == {displayCount:1, configManagerErrorCode:0, testsigning:false,
                    nointegritychecks:false, bcdChanged:false}
    ' "$file" >/dev/null || die 'qualification 内容与当前 canonical profile/host/driver 不匹配'
    [[ "$(signed_consumer_qualification_id "$PROFILE_SHA" "$QEMU_SHA" "$HOST_DRIVER_SHA" "$HOST_STACK_SHA")" == "$id" ]] \
        || die 'qualificationId 不是当前兼容性事实的内容摘要'
    printf '%s\n' "$id"
}

ensure_private_root() {
    local path=$1 mode owner
    if [[ -e "$path" || -L "$path" ]]; then
        [[ -d "$path" && ! -L "$path" ]] || die "目录不安全: $path"
    else
        [[ $EUID -eq 0 ]] || die "资格目录不存在；先用 sudo record-proof 创建: $path"
        mkdir -m 0755 -p -- "$path"
    fi
    owner=$(stat -c %u -- "$path")
    mode=$(stat -c %a -- "$path")
    if [[ "$owner" != 0 ]]; then
        [[ $EUID -eq 0 && "${SUDO_UID:-}" == "$owner" &&
           "${SUDO_UID:-0}" =~ ^[1-9][0-9]*$ ]] \
            || die "qualification root 必须由 root 所有: $path"
        (( (8#$mode & 077) == 0 )) \
            || die "拒绝接管可被其他用户访问的 legacy qualification root: $path"
        chown 0:0 -- "$path"
    fi
    (( (8#$mode & 022) == 0 )) \
        || die "qualification root 不能被 group/world 写入: $path"
    if [[ $EUID -eq 0 ]]; then
        chmod 0755 -- "$path"
    fi
}

find_qualification() {
    local requested=${1:-} file id
    local -a matches=()
    if [[ -n "$requested" ]]; then
        [[ "$requested" =~ ^[0-9A-F]{64}$ ]] || die '--qualification-id 必须是 64 位大写 HEX'
        file="$PROOF_ROOT/qualification-${requested}.json"
        verify_qualification_marker "$file" "$requested" >/dev/null
        printf '%s\n' "$file"
        return 0
    fi
    shopt -s nullglob
    for file in "$PROOF_ROOT"/qualification-*.json; do
        id=$(jq -r '.qualificationId // empty' "$file" 2>/dev/null || true)
        [[ "$id" =~ ^[0-9A-F]{64}$ ]] || continue
        jq -e --arg profile "$SC_CANONICAL_GPU_PROFILE" \
            --arg driverKey "$SC_DRIVER_KEY" --arg qemuSha "$QEMU_SHA" \
            --arg hostDriverSha "$HOST_DRIVER_SHA" --arg hostStackSha "$HOST_STACK_SHA" '
            .consumer.gpuProfile == $profile and .driver.key == $driverKey and
            .compatibility.qemuSha256 == $qemuSha and
            .compatibility.hostDriverSha256 == $hostDriverSha and
            .compatibility.hostStackSha256 == $hostStackSha
        ' "$file" >/dev/null 2>&1 || continue
        if verify_qualification_marker "$file" "$id" >/dev/null 2>&1; then
            matches+=("$file")
        fi
    done
    shopt -u nullglob
    ((${#matches[@]} == 1)) || {
        if ((${#matches[@]} == 0)); then
            die "profile $CONFIG_PROFILE 在当前 host stack 没有 qualification；先用可删除克隆 record-proof"
        fi
        die '匹配多个 qualification；请显式给 --qualification-id'
    }
    printf '%s\n' "${matches[0]}"
}

if [[ "$ACTION" == help || "$ACTION" == --help || "$ACTION" == -h ]]; then
    usage
    exit 0
fi

load_vm_contract "$VM_ID"

case "$ACTION" in
    record-proof)
        [[ "$EXPERIMENT_ID" =~ ^[0-9A-F]{32}$ ]] || die 'record-proof 必须提供 --experiment-id'
        ((CONFIRM_SOURCE_PROOF == 1)) || die '必须显式 --confirm-source-proof 确认该来源 VM 可删除且只用于资格证明'
        [[ -z "$QUALIFICATION_ID" && -z "$DRIVER_EXE" ]] || die 'record-proof 不接受 qualification-id/driver-exe'
        select_driver_for_loaded_profile
        [[ $EUID -eq 0 ]] \
            || die 'record-proof 必须使用 sudo；qualification 由 root 持有'
        temporary=''
        if [[ -n "$RECEIPT_FILE" ]]; then
            RECEIPT_FILE=$(realpath -e -- "$RECEIPT_FILE") || die 'receipt-file 不存在'
        else
            acquire_stopped_locks
            temporary=$(mktemp)
            trap 'rm -f -- "$temporary"' EXIT
            copy_stopped_receipt "ProgramData/${SC_GUEST_STATE_ROOT}/receipts/vm${VM_ID}-${EXPERIMENT_ID}-validated.json" "$temporary"
            RECEIPT_FILE=$temporary
        fi
        verify_validated_receipt "$RECEIPT_FILE" "$VM_ID" "$CONFIG_UUID" "$EXPERIMENT_ID"
        contract_sha=$(jq -er '.contractSha256' "$RECEIPT_FILE")
        receipt_sha=$(sha256_upper "$RECEIPT_FILE")
        completed_utc=$(jq -er '.completedUtc' "$RECEIPT_FILE")
        QUALIFICATION_ID=$(signed_consumer_qualification_id "$PROFILE_SHA" "$QEMU_SHA" "$HOST_DRIVER_SHA" "$HOST_STACK_SHA") \
            || die '无法生成 qualificationId'
        ensure_private_root "$PROOF_ROOT"
        marker="$PROOF_ROOT/qualification-${QUALIFICATION_ID}.json"
        if [[ -e "$marker" || -L "$marker" ]]; then
            verify_qualification_marker "$marker" "$QUALIFICATION_ID" >/dev/null
            log "qualification 已存在且有效: $marker"
        else
            tmp=$(mktemp "$PROOF_ROOT/.qualification.XXXXXXXX")
            jq -n --arg id "$QUALIFICATION_ID" --arg purpose "$SIGNED_CONSUMER_QUALIFICATION_PURPOSE" \
                --arg backend "$SIGNED_CONSUMER_BACKEND_ABI" --arg profile "$SC_CANONICAL_GPU_PROFILE" \
                --arg profileSha "$PROFILE_SHA" --arg gpuName "$SC_CANONICAL_GPU_NAME" \
                --arg pnp "$SC_CANONICAL_TARGET_PNP" --arg driverKey "$SC_DRIVER_KEY" \
                --arg version "$SC_DRIVER_VERSION" --arg infSha "$SC_INF_SHA256" \
                --arg catSha "$SC_CATALOG_SHA256" --arg sysSha "$SC_KERNEL_SHA256" \
                --arg installerSha "$SC_INSTALLER_SHA256" \
                --arg packageBuilder "$SC_PACKAGE_BUILDER" \
                --arg packageBuilderSha "$SC_PACKAGE_BUILDER_SHA256" \
                --arg guestValidator "$SC_GUEST_VALIDATOR" \
                --arg guestValidatorSha "$SC_GUEST_VALIDATOR_SHA256" \
                --arg signer "$SC_CATALOG_SIGNER_THUMBPRINT" --arg baseline "$SC_BASELINE_PNP_PREFIX" \
                --arg baselineVersion "$SC_BASELINE_DRIVER_VERSION" --arg qemuSha "$QEMU_SHA" \
                --arg hostDriverSha "$HOST_DRIVER_SHA" --arg hostStackSha "$HOST_STACK_SHA" \
                --arg mdev "$SC_CANONICAL_MDEV_PROFILE" \
                --argjson fb "$SC_CANONICAL_FB_MB" --argjson sourceVm "$VM_ID" \
                --arg sourceUuid "${CONFIG_UUID,,}" --arg experiment "$EXPERIMENT_ID" \
                --arg contractSha "$contract_sha" --arg receiptSha "$receipt_sha" \
                --arg completed "$completed_utc" '{
                  schemaVersion:2, purpose:$purpose, qualificationId:$id,
                  consumer:{gpuProfile:$profile,profileSha256:$profileSha,gpuName:$gpuName,exactHardwareId:$pnp},
                  driver:{key:$driverKey,version:$version,infSha256:$infSha,catalogSha256:$catSha,
                          kernelSha256:$sysSha,catalogSignerThumbprint:$signer,
                          baselinePnpPrefix:$baseline,baselineDriverVersion:$baselineVersion,
                          installerSha256:$installerSha,packageBuilder:$packageBuilder,
                          packageBuilderSha256:$packageBuilderSha,
                          guestValidator:$guestValidator,
                          guestValidatorSha256:$guestValidatorSha},
                  compatibility:{backendAbi:$backend,qemuSha256:$qemuSha,hostDriverSha256:$hostDriverSha,
                                 hostStackSha256:$hostStackSha,
                                 mdevProfile:$mdev,framebufferMb:$fb,projection:"outer-only",internalIdentity:"native"},
                  sourceProof:{vmId:$sourceVm,vmUuid:$sourceUuid,experimentId:$experiment,
                               contractSha256:$contractSha,receiptSha256:$receiptSha,completedUtc:$completed},
                  result:{displayCount:1,configManagerErrorCode:0,testsigning:false,
                          nointegritychecks:false,bcdChanged:false}
                }' >"$tmp"
            chmod 0444 "$tmp"
            verify_qualification_marker "$tmp" "$QUALIFICATION_ID" >/dev/null
            mv -T -- "$tmp" "$marker"
            log "qualification 已固化: $marker"
        fi
        [[ -z "$temporary" ]] || rm -f -- "$temporary"
        trap - EXIT
        log "qualification ID: $QUALIFICATION_ID"
        log '来源 VM 可删除；资格证明不依赖其 VM 编号或磁盘路径。'
        ;;
    stage)
        [[ -z "$EXPERIMENT_ID" && -z "$RECEIPT_FILE" && $CONFIRM_SOURCE_PROOF == 0 ]] \
            || die 'stage 参数不合法'
        select_driver_for_loaded_profile
        ensure_private_root "$PROOF_ROOT"
        marker=$(find_qualification "$QUALIFICATION_ID")
        QUALIFICATION_ID=$(verify_qualification_marker "$marker" "${QUALIFICATION_ID:-}" )
        args=( "$VM_ID" --production-proof-marker "$marker" --driver-key "$DRIVER_KEY" --output-root "$OUTPUT_ROOT" )
        [[ -z "$DRIVER_EXE" ]] || args+=( --driver-exe "$DRIVER_EXE" )
        [[ "$SC_PACKAGE_BUILDER" =~ ^[A-Za-z0-9._-]+$ &&
           -x "$here/$SC_PACKAGE_BUILDER" && ! -L "$here/$SC_PACKAGE_BUILDER" ]] \
            || die "driver row $SC_DRIVER_KEY 没有安全的 package builder"
        exec "$here/$SC_PACKAGE_BUILDER" "${args[@]}"
        ;;
    status)
        [[ -z "$EXPERIMENT_ID$RECEIPT_FILE$DRIVER_EXE" && $CONFIRM_SOURCE_PROOF == 0 ]] || die 'status 不接受这些参数'
        if ! grep -q '^VGPU_SIGNED_CONSUMER_CONTRACT=' "$CONF"; then
            echo "vm${VM_ID}: B/name-only（无 signed-consumer production 合同）"
            exit 0
        fi
        echo "vm${VM_ID}: $(literal_from "$CONF" VGPU_SIGNED_CONSUMER_STATE)"
        echo "  profile:       $(literal_from "$CONF" VGPU_SIGNED_CONSUMER_PROFILE)"
        echo "  driver:        $(literal_from "$CONF" VGPU_SIGNED_CONSUMER_DRIVER_KEY)"
        echo "  qualification: $(literal_from "$CONF" VGPU_SIGNED_CONSUMER_QUALIFICATION_ID)"
        echo "  experiment:    $(literal_from "$CONF" VGPU_SIGNED_CONSUMER_EXPERIMENT_ID)"
        ;;
    commit|finalize|rollback)
        [[ $EUID -eq 0 ]] || die "$ACTION 需要 sudo（只读离线核验与原子 host 配置）"
        [[ -z "$RECEIPT_FILE$DRIVER_EXE" && $CONFIRM_SOURCE_PROOF == 0 ]] || die "$ACTION 参数不合法"
        acquire_stopped_locks
        UUID_LOWER=${CONFIG_UUID,,}
        if [[ "$ACTION" == commit ]]; then
            [[ "$EXPERIMENT_ID" =~ ^[0-9A-F]{32}$ ]] || die 'commit 必须提供 --experiment-id'
            ! grep -q '^VGPU_SIGNED_CONSUMER_CONTRACT=' "$CONF" || die '已有 production consumer 合同'
            package_dir="$OUTPUT_ROOT/vm${VM_ID}-${UUID_LOWER}-${EXPERIMENT_ID}"
            state="$package_dir/package-state.json"
            contract="$package_dir/experiment-contract.json"
            [[ -f "$state" && ! -L "$state" && -f "$contract" && ! -L "$contract" ]] \
                || die 'stage package state/contract 缺失'
            state_driver=$(jq -er '.driverKey' "$state")
            state_qualification=$(jq -er '.qualificationId' "$state")
            DRIVER_KEY=${DRIVER_KEY:-$state_driver}
            [[ "$DRIVER_KEY" == "$state_driver" ]] || die 'CLI driver-key 与 package state 不一致'
            select_driver_for_loaded_profile
            package_validator="$package_dir/$SC_GUEST_VALIDATOR"
            [[ -f "$package_validator" && ! -L "$package_validator" &&
               "$(stat -c %h -- "$package_validator")" == 1 &&
               "$(sha256_upper "$package_validator")" == "$SC_GUEST_VALIDATOR_SHA256" ]] \
                || die 'stage package guest validator 与 qualification 内容不一致'
            QUALIFICATION_ID=${QUALIFICATION_ID:-$state_qualification}
            [[ "$QUALIFICATION_ID" == "$state_qualification" ]] || die 'CLI qualification-id 与 package state 不一致'
            marker="$PROOF_ROOT/qualification-${QUALIFICATION_ID}.json"
            verify_qualification_marker "$marker" "$QUALIFICATION_ID" >/dev/null
            source_sha=$(sha256_upper "$CONF")
            contract_sha=$(sha256_upper "$contract")
            qualification_sha=$(sha256_upper "$marker")
            jq -e --argjson vmId "$VM_ID" --arg vmUuid "$UUID_LOWER" \
                --arg experiment "$EXPERIMENT_ID" --arg sourceSha "$source_sha" \
                --arg contractSha "$contract_sha" --arg profile "$CONFIG_PROFILE" \
                --arg profileSha "$PROFILE_SHA" --arg driverKey "$DRIVER_KEY" \
                --arg qualificationId "$QUALIFICATION_ID" --arg qualificationSha "$qualification_sha" '
                .schemaVersion == 2 and .vmId == $vmId and .vmUuid == $vmUuid and
                .experimentId == $experiment and .sourceHostMode == "B" and
                .sourceConfigSha256 == $sourceSha and .contractSha256 == $contractSha and
                .gpuProfile == $profile and .profileSha256 == $profileSha and
                .driverKey == $driverKey and .qualificationId == $qualificationId and
                .qualificationSha256 == $qualificationSha and
                .deploymentIntent == "qualified-production-staging"
            ' "$state" >/dev/null || die 'package state 未绑定当前 VM/profile/qualification/config'
            [[ "$(jq -er '.scriptSha256' "$state")" == "$SC_GUEST_VALIDATOR_SHA256" ]] \
                || die 'package state guest validator digest 与 catalog 不一致'
            receipt=$(mktemp); trap 'rm -f -- "$receipt"' EXIT
            copy_stopped_receipt "ProgramData/${SC_GUEST_STATE_ROOT}/receipts/vm${VM_ID}-${EXPERIMENT_ID}-staged.json" "$receipt"
            verify_staged_receipt "$receipt" "$VM_ID" "$CONFIG_UUID" "$EXPERIMENT_ID" "$contract_sha"
            [[ "$(sha256_upper "$CONF")" == "$source_sha" ]] || die '离线核验期间 vm.conf 改变'
            ensure_private_root "$RUNTIME_PROOF_ROOT"
            runtime_vm_root="$RUNTIME_PROOF_ROOT/vm${VM_ID}-${UUID_LOWER}"
            ensure_private_root "$runtime_vm_root"
            proof_dir="$runtime_vm_root/$EXPERIMENT_ID"
            [[ ! -e "$proof_dir" && ! -L "$proof_dir" ]] || die '目标 proof 目录已存在；拒绝覆盖'
            mkdir -m 0755 -- "$proof_dir"
            qual_copy="$proof_dir/qualification.json"
            contract_copy="$proof_dir/guest-contract.json"
            staged_copy="$proof_dir/staged.json"
            install -m 0444 -- "$marker" "$qual_copy"
            install -m 0444 -- "$contract" "$contract_copy"
            install -m 0444 -- "$receipt" "$staged_copy"
            staged_sha=$(sha256_upper "$staged_copy")
            backup_dir="$INSTANCE_DIR/backups/signed-consumer-production"
            mkdir -p "$backup_dir"; chmod 0700 "$backup_dir"; chown --reference="$CONF" "$backup_dir"
            backup="$backup_dir/vm.conf.before-signed-consumer-${EXPERIMENT_ID}"
            install -m 0400 -- "$CONF" "$backup"; chown --reference="$CONF" "$backup"
            config_tmp="$(dirname "$CONF")/.$(basename "$CONF").signed-consumer.$$.$RANDOM"
            awk '!/^[[:space:]]*VGPU_SIGNED_CONSUMER_/' "$CONF" >"$config_tmp"
            cat >>"$config_tmp" <<EOF

# Generic qualified production outer-only consumer PCI; not legacy A.
VGPU_SIGNED_CONSUMER_CONTRACT=${SIGNED_CONSUMER_CONTRACT_NAME}
VGPU_SIGNED_CONSUMER_STATE=pending-validation
VGPU_SIGNED_CONSUMER_PROFILE=${CONFIG_PROFILE}
VGPU_SIGNED_CONSUMER_PROFILE_SHA256=${PROFILE_SHA}
VGPU_SIGNED_CONSUMER_DRIVER_KEY=${DRIVER_KEY}
VGPU_SIGNED_CONSUMER_QUALIFICATION_ID=${QUALIFICATION_ID}
VGPU_SIGNED_CONSUMER_QUALIFICATION_SHA256=${qualification_sha}
VGPU_SIGNED_CONSUMER_EXPERIMENT_ID=${EXPERIMENT_ID}
VGPU_SIGNED_CONSUMER_CONTRACT_SHA256=${contract_sha}
VGPU_SIGNED_CONSUMER_STAGED_RECEIPT_SHA256=${staged_sha}
VGPU_SIGNED_CONSUMER_SOURCE_CONFIG_SHA256=${source_sha}
EOF
            chmod --reference="$CONF" "$config_tmp"; chown --reference="$CONF" "$config_tmp"
            mv -T -- "$config_tmp" "$CONF"
            trap - EXIT; rm -f -- "$receipt"
            log "COMMIT PASS: vm${VM_ID} / $CONFIG_PROFILE 已进入 pending-validation"
            log "下一步：正常启动 vm${VM_ID}；SYSTEM 自动验收并完整关机，再运行 finalize ${VM_ID}。"
        else
            [[ -z "$EXPERIMENT_ID" ]] || die "$ACTION 不接受 --experiment-id"
            [[ "$(literal_from "$CONF" VGPU_SIGNED_CONSUMER_CONTRACT)" == "$SIGNED_CONSUMER_CONTRACT_NAME" ]] \
                || die "vm${VM_ID} 没有 v2 production consumer 合同"
            experiment=$(literal_from "$CONF" VGPU_SIGNED_CONSUMER_EXPERIMENT_ID)
            source_sha=$(literal_from "$CONF" VGPU_SIGNED_CONSUMER_SOURCE_CONFIG_SHA256)
            if [[ "$ACTION" == rollback ]]; then
                backup="$INSTANCE_DIR/backups/signed-consumer-production/vm.conf.before-signed-consumer-${experiment}"
                [[ -f "$backup" && ! -L "$backup" && "$(sha256_upper "$backup")" == "$source_sha" ]] \
                    || die '原始 B/name-only vm.conf 回滚备份缺失或 hash 不符'
                restore_tmp="$(dirname "$CONF")/.$(basename "$CONF").rollback.$$.$RANDOM"
                install -m "$(stat -c %a "$CONF")" -- "$backup" "$restore_tmp"
                chown --reference="$CONF" "$restore_tmp"
                mv -T -- "$restore_tmp" "$CONF"
                [[ "$(sha256_upper "$CONF")" == "$source_sha" ]] || die '回滚后 config hash 断言失败'
                log "ROLLBACK PASS: vm${VM_ID} 已精确恢复原始 B/name-only 配置。"
                exit 0
            fi
            [[ "$(literal_from "$CONF" VGPU_SIGNED_CONSUMER_STATE)" == pending-validation ]] \
                || die "vm${VM_ID} 不在 pending-validation"
            [[ "$(literal_from "$CONF" VGPU_SIGNED_CONSUMER_PROFILE)" == "$CONFIG_PROFILE" ]] || die '合同 profile 与 vm.conf 不一致'
            [[ "$(literal_from "$CONF" VGPU_SIGNED_CONSUMER_PROFILE_SHA256)" == "$PROFILE_SHA" ]] || die '合同 profile digest 不一致'
            DRIVER_KEY=$(literal_from "$CONF" VGPU_SIGNED_CONSUMER_DRIVER_KEY)
            select_driver_for_loaded_profile
            QUALIFICATION_ID=$(literal_from "$CONF" VGPU_SIGNED_CONSUMER_QUALIFICATION_ID)
            contract_sha=$(literal_from "$CONF" VGPU_SIGNED_CONSUMER_CONTRACT_SHA256)
            proof_dir="$RUNTIME_PROOF_ROOT/vm${VM_ID}-${UUID_LOWER}/$experiment"
            marker="$proof_dir/qualification.json"
            [[ "$(sha256_upper "$marker")" == "$(literal_from "$CONF" VGPU_SIGNED_CONSUMER_QUALIFICATION_SHA256)" ]] \
                || die 'per-VM qualification SHA 不一致'
            verify_qualification_marker "$marker" "$QUALIFICATION_ID" >/dev/null
            validated=$(mktemp); trap 'rm -f -- "$validated"' EXIT
            copy_stopped_receipt "ProgramData/${SC_GUEST_STATE_ROOT}/receipts/vm${VM_ID}-${experiment}-validated.json" "$validated"
            verify_validated_receipt "$validated" "$VM_ID" "$CONFIG_UUID" "$experiment" "$contract_sha"
            validated_copy="$proof_dir/validated.json"
            [[ ! -e "$validated_copy" && ! -L "$validated_copy" ]] || die 'validated proof 已存在；拒绝覆盖'
            install -m 0444 -- "$validated" "$validated_copy"
            validated_sha=$(sha256_upper "$validated_copy")
            tmp="$(dirname "$CONF")/.$(basename "$CONF").state.$$.$RANDOM"
            sed -E 's/^VGPU_SIGNED_CONSUMER_STATE=pending-validation$/VGPU_SIGNED_CONSUMER_STATE=validated/' "$CONF" >"$tmp"
            printf 'VGPU_SIGNED_CONSUMER_VALIDATED_RECEIPT_SHA256=%s\n' "$validated_sha" >>"$tmp"
            chmod --reference="$CONF" "$tmp"; chown --reference="$CONF" "$tmp"; mv -T -- "$tmp" "$CONF"
            trap - EXIT; rm -f -- "$validated"
            log "FINAL PASS: vm${VM_ID} / $CONFIG_PROFILE 已通过 Code 0 原版 WHQL 验收。"
        fi
        ;;
    *) usage >&2; die "未知 action: $ACTION" ;;
esac
