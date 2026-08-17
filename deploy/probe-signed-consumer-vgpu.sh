#!/usr/bin/env bash
# One-shot, host-attested consumer-PCI probe for an explicitly disposable G-11
# clone.  This wrapper never edits vm.conf, a Windows disk, BCD or a driver.
# The ordinary start-vm strict-A gate remains closed; the launcher accepts the
# probe only while reading an already unlinked, single-use attestation FD.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The probe may never redirect the host identity backend through an inherited
# environment.  Pin both the root-owned TOML and the repository helper before
# vgpu-mdev.sh evaluates its defaults.
for probe_override in VGPU_UNLOCK_PROFILE_OVERRIDE_CONFIG_PATH \
        VGPU_UNLOCK_PROFILE_OVERRIDE_CONFIG VGPU_MDEV_IDENTITY_HELPER; do
    if [[ -v $probe_override ]]; then
        echo "[signed-consumer-probe] ERROR: $probe_override 环境覆盖被禁止" >&2
        exit 2
    fi
done
VGPU_UNLOCK_PROFILE_OVERRIDE_CONFIG_PATH=/etc/vgpu_unlock/profile_override.toml
VGPU_UNLOCK_PROFILE_OVERRIDE_CONFIG=/etc/vgpu_unlock/profile_override.toml
VGPU_MDEV_IDENTITY_HELPER="$here/host/update-vgpu-mdev-identity.py"
VGPU_MDEV_IDENTITY_MODE=required
readonly VGPU_UNLOCK_PROFILE_OVERRIDE_CONFIG_PATH \
    VGPU_UNLOCK_PROFILE_OVERRIDE_CONFIG VGPU_MDEV_IDENTITY_HELPER \
    VGPU_MDEV_IDENTITY_MODE
export VGPU_UNLOCK_PROFILE_OVERRIDE_CONFIG_PATH \
    VGPU_UNLOCK_PROFILE_OVERRIDE_CONFIG VGPU_MDEV_IDENTITY_HELPER \
    VGPU_MDEV_IDENTITY_MODE

# shellcheck source=lib/vm-storage.sh
source "$here/lib/vm-storage.sh"
# shellcheck source=lib/vgpu-mdev.sh
source "$here/lib/vgpu-mdev.sh"
# shellcheck source=lib/signed-consumer-catalog.sh
source "$here/lib/signed-consumer-catalog.sh"
unset probe_override

die() {
    echo "[signed-consumer-probe] ERROR: $*" >&2
    exit 2
}

usage() {
    cat <<'EOF'
Usage:
  probe-signed-consumer-vgpu.sh VM_ID --attest-disposable-clone \
      --stage outer-only|outer+internal [--driver-dir ABS] [storage selector]

  probe-signed-consumer-vgpu.sh VM_ID --stage outer-only|outer+internal \
      [normal start-vm options] [storage selector]

The destination VM must be a stopped, explicitly disposable clone. Its
immutable vm.conf must remain B/name-only and match one canonical GPU profile
with an audited production-signed driver-catalog row. Attestation is one-shot
and stage-specific; no VM number is privileged or special-cased.

Stages:
  outer-only      QEMU outer PCI tuple only; internal vdev/pdev stays native.
  outer+internal  QEMU outer tuple plus the profile-derived vdev/pdev IDs.

This tool does not install a driver. It recognizes only the locally audited,
unaltered bytes selected by the canonical signed-consumer driver row.
EOF
}

[[ $# -ge 1 ]] || { usage >&2; exit 2; }
VM_ID=$1
shift
vm_storage_id_is_supported "$VM_ID" || die "VM_ID 必须是 1..2147483647"
ACTION=launch
STAGE=""
DRIVER_DIR=""
REPLACE_ATTESTATION=0
VMS_DIR_CLI=""
VM_DIR_CLI=""
INSTANCES_DIR_CLI=""
START_ARGS=()
STORAGE_ARGS=()

while (( $# > 0 )); do
    case "$1" in
        --attest-disposable-clone)
            [[ "$ACTION" == launch ]] \
                || die "--attest-disposable-clone 只能指定一次"
            ACTION=attest
            shift
            ;;
        --stage)
            (( $# >= 2 )) || die "--stage 需要 outer-only 或 outer+internal"
            [[ -z "$STAGE" ]] || die "--stage 只能指定一次"
            STAGE=$2
            shift 2
            ;;
        --driver-dir)
            (( $# >= 2 )) || die "--driver-dir 需要绝对目录"
            [[ -z "$DRIVER_DIR" ]] || die "--driver-dir 只能指定一次"
            DRIVER_DIR=$2
            shift 2
            ;;
        --replace-attestation)
            REPLACE_ATTESTATION=1
            shift
            ;;
        --vms-dir|--vm-dir|--instances-dir)
            option=$1
            (( $# >= 2 )) || die "$option 需要绝对目录"
            value=$2
            case "$option" in
                --vms-dir)
                    [[ -z "$VMS_DIR_CLI" ]] || die "$option 只能指定一次"
                    VMS_DIR_CLI=$value ;;
                --vm-dir)
                    [[ -z "$VM_DIR_CLI" ]] || die "$option 只能指定一次"
                    VM_DIR_CLI=$value ;;
                --instances-dir)
                    [[ -z "$INSTANCES_DIR_CLI" ]] || die "$option 只能指定一次"
                    INSTANCES_DIR_CLI=$value ;;
            esac
            STORAGE_ARGS+=( "$option" "$value" )
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            START_ARGS+=( "$1" )
            shift
            ;;
    esac
done

case "$STAGE" in
    outer-only|outer+internal) ;;
    *) die "--stage 必须是 outer-only 或 outer+internal" ;;
esac

selector_count=0
[[ -z "$VMS_DIR_CLI" ]] || selector_count=$((selector_count + 1))
[[ -z "$VM_DIR_CLI" ]] || selector_count=$((selector_count + 1))
[[ -z "$INSTANCES_DIR_CLI" ]] || selector_count=$((selector_count + 1))
(( selector_count <= 1 )) \
    || die "--vms-dir、--vm-dir 与 --instances-dir 只能选择一个"
if [[ -n "$VMS_DIR_CLI" ]]; then
    vm_storage_select_root "$VMS_DIR_CLI" || exit $?
elif [[ -n "$VM_DIR_CLI" ]]; then
    vm_storage_select_instance_dir "$VM_ID" "$VM_DIR_CLI" || exit $?
elif [[ -n "$INSTANCES_DIR_CLI" ]]; then
    vm_storage_select_instances_dir "$INSTANCES_DIR_CLI" || exit $?
fi
vm_storage_init

VM_DIR=$(vm_storage_instance_dir "$VM_ID") || exit $?
CONF=$(vm_storage_config_path "$VM_ID") || exit $?
DISK=$(vm_storage_disk_path "$VM_ID") || exit $?
ATTESTATION_DIR="$VM_DIR/probe"
ATTESTATION="$ATTESTATION_DIR/signed-consumer-${STAGE}.json"

[[ -d "$VM_DIR" && ! -L "$VM_DIR" ]] \
    || die "VM bundle 不存在或不安全: $VM_DIR"
[[ -f "$CONF" && ! -L "$CONF" && "$(stat -c %h -- "$CONF")" == 1 ]] \
    || die "vm.conf 必须是普通非链接文件: $CONF"
[[ -f "$DISK" && ! -L "$DISK" && "$(stat -c %h -- "$DISK")" == 1 ]] \
    || die "disk.qcow2 必须是普通非链接文件: $DISK"

literal_value() {
    local field=$1 value
    local -a lines=()
    mapfile -t lines < <(sed -n -E "s/^[[:space:]]*${field}=//p" "$CONF")
    ((${#lines[@]} == 1)) \
        || die "vm.conf 必须恰好包含一个简单 ${field}= literal"
    value=${lines[0]%$'\r'}
    value=$(sed -E \
        's/[[:space:]]+#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//' \
        <<<"$value")
    if [[ "$value" == \"*\" && "$value" == *\" && ${#value} -ge 2 ]]; then
        value=${value:1:${#value}-2}
    elif [[ "$value" == \'*\' && "$value" == *\' && ${#value} -ge 2 ]]; then
        value=${value:1:${#value}-2}
    fi
    [[ -n "$value" ]] || die "vm.conf ${field} 不能为空"
    printf '%s\n' "$value"
}

CONFIG_VM_ID=$(literal_value VM_ID)
CONFIG_UUID=$(literal_value VM_UUID)
CONFIG_PROFILE=$(literal_value GPU_PROFILE)
CONFIG_MODE=$(literal_value SPOOF_MODE)
CONFIG_TARGET=$(literal_value VGPU_IDENTITY_TARGET)
CONFIG_GPU_NAME=$(literal_value GPU_NAME)
CONFIG_PCI_VID=$(literal_value GPU_PCI_VID)
CONFIG_PCI_DID=$(literal_value GPU_PCI_DID)
CONFIG_SUB_VID=$(literal_value GPU_SUB_VID)
CONFIG_SUB_DID=$(literal_value GPU_SUB_DID)
CONFIG_MDEV_PROFILE=$(literal_value VGPU_MDEV_PROFILE)

[[ "$CONFIG_VM_ID" == "$VM_ID" ]] \
    || die "vm.conf VM_ID 与目标不一致: $CONFIG_VM_ID"
[[ "$CONFIG_UUID" =~ ^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$ ]] \
    || die "vm.conf VM_UUID 非法"
[[ "$CONFIG_MODE" == B && "$CONFIG_TARGET" == name-only ]] \
    || die "probe 只允许 B/name-only 配置"
signed_consumer_profile_assert_config "$CONFIG_PROFILE" "$CONFIG_GPU_NAME" \
    "$CONFIG_PCI_VID" "$CONFIG_PCI_DID" "$CONFIG_SUB_VID" \
    "$CONFIG_SUB_DID" "$CONFIG_MDEV_PROFILE" \
    || die "vm.conf GPU 字段与 canonical profile catalog 不一致"
CONFIG_RM_FB_BUS_WIDTH=$GPU_MEMORY_BUS_BITS
CONFIG_RM_FB_RAM_TYPE=$GPU_MEMORY_TYPE_NVAPI
CONFIG_RM_FB_MEMORY_VENDOR=$GPU_MEMORY_VENDOR_RM
PROFILE_SHA=$(signed_consumer_profile_sha256 "$CONFIG_PROFILE") \
    || die "无法计算 canonical profile digest"
DRIVER_KEY=$(signed_consumer_driver_audited_default_for_profile "$CONFIG_PROFILE") \
    || die "profile $CONFIG_PROFILE 尚无可资格化的原版 WHQL driver 条目"
signed_consumer_driver_load "$DRIVER_KEY" || die "driver catalog 条目无效"
signed_consumer_driver_assert_profile || die "driver catalog 与 canonical profile 不一致"
printf -v EXPECTED_INTERNAL_PCI_ID '0x%04X%04X' \
    "$((SC_CANONICAL_PCI_DID))" "$((SC_CANONICAL_SUB_DID))"
printf -v EXPECTED_INTERNAL_PDEV_ID '0x%04X' "$((SC_CANONICAL_PCI_DID))"
printf -v EXPECTED_PCI_VID '0x%04X' "$((SC_CANONICAL_PCI_VID))"
printf -v EXPECTED_PCI_DID '0x%04X' "$((SC_CANONICAL_PCI_DID))"
printf -v EXPECTED_SUB_VID '0x%04X' "$((SC_CANONICAL_SUB_VID))"
printf -v EXPECTED_SUB_DID '0x%04X' "$((SC_CANONICAL_SUB_DID))"
if grep -Eq \
        '^[[:space:]]*(SPOOF=|VGPU_MDEV_INTERNAL_PCI_IDENTITY=['"'"']?1['"'"']?([[:space:]]|$)|VGPU_MDEV_FRL_ENABLED=|VGPU_PATCHED_DRIVER_(INF|VERSION)=)' \
        "$CONF"; then
    die "vm.conf 含 legacy A/internal/FRL/patched-driver marker；拒绝探测"
fi

CONFIG_SHA=$(sha256sum -- "$CONF" | awk '{print toupper($1)}')
DISK_PATH=$(realpath -e -- "$DISK") || die "无法解析 disk.qcow2"
[[ "$DISK_PATH" == "$DISK" ]] || die "disk.qcow2 路径必须是 canonical path"
DISK_TOKEN=$(stat -Lc '%d:%i:%s:%Y:%Z' -- "$DISK")

if pgrep -f \
        "qemu-system-x86_64.*-name[[:space:]]+vm${VM_ID}([,[:space:]]|$)" \
        >/dev/null 2>&1; then
    die "vm${VM_ID} 正在运行；必须完整关机后再生成/使用 probe attestation"
fi

EXPECTED_INF_SHA=$SC_INF_SHA256
EXPECTED_CAT_SHA=$SC_CATALOG_SHA256
EXPECTED_PACKAGE_SHA=$SC_INSTALLER_SHA256

verify_attestation() {
    local file=$1 issued_at issued_epoch now_epoch age_seconds
    command -v jq >/dev/null 2>&1 || die "缺少 jq，无法验证 host attestation"
    [[ -f "$file" && ! -L "$file" && "$(stat -c %h -- "$file")" == 1 &&
       "$(stat -c %a -- "$file")" == 600 &&
       "$(stat -c %u -- "$file")" == "$(id -u)" &&
       "$(stat -c %s -- "$file")" -le 65536 ]] \
        || die "host attestation 缺失、链接、权限或大小不安全: $file"
    jq -e \
        --argjson vmId "$VM_ID" \
        --arg vmUuid "${CONFIG_UUID,,}" \
        --arg stage "$STAGE" \
        --arg configSha "$CONFIG_SHA" \
        --arg diskPath "$DISK_PATH" \
        --arg diskToken "$DISK_TOKEN" \
        --argjson issuedByUid "$(id -u)" \
        --arg profile "$SC_CANONICAL_GPU_PROFILE" \
        --arg profileSha "$PROFILE_SHA" \
        --arg gpuName "$SC_CANONICAL_GPU_NAME" \
        --arg pciVid "$EXPECTED_PCI_VID" --arg pciDid "$EXPECTED_PCI_DID" \
        --arg subVid "$EXPECTED_SUB_VID" --arg subDid "$EXPECTED_SUB_DID" \
        --arg internalPci "$EXPECTED_INTERNAL_PCI_ID" \
        --arg internalPdev "$EXPECTED_INTERNAL_PDEV_ID" \
        --arg resourceProfile "$SC_CANONICAL_MDEV_PROFILE" \
        --argjson framebufferMb "$SC_CANONICAL_FB_MB" \
        --arg driverKey "$SC_DRIVER_KEY" --arg driverVersion "$SC_DRIVER_VERSION" \
        --arg infName "$SC_INF_NAME" --arg catalogName "$SC_CATALOG_NAME" \
        --arg infSha "$EXPECTED_INF_SHA" \
        --arg catSha "$EXPECTED_CAT_SHA" \
        --arg packageSha "$EXPECTED_PACKAGE_SHA" '
        (keys | sort) == [
          "configSha256", "diskPath", "diskStatToken", "disposableClone",
          "driverEvidence", "gpu", "issuedAtUtc", "issuedByUid", "nonce",
          "purpose", "schemaVersion", "stage", "vmId", "vmUuid"
        ] and
        .schemaVersion == 2 and
        .purpose == "g11-signed-consumer-disposable-clone" and
        .disposableClone == true and .vmId == $vmId and
        .vmUuid == $vmUuid and .stage == $stage and
        .configSha256 == $configSha and .diskPath == $diskPath and
        .diskStatToken == $diskToken and .issuedByUid == $issuedByUid and
        (.issuedAtUtc | (type == "string" and
          test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))) and
        (.nonce | test("^[0-9A-F]{32}$")) and
        (.gpu | keys | sort) == [
          "framebufferMb", "internalPciId", "internalPdevId", "name", "pciDid",
          "pciVid", "profile", "profileSha256", "resourceProfile", "subDid", "subVid"
        ] and
        .gpu == {
          profile: $profile, profileSha256: $profileSha, name: $gpuName,
          pciVid: $pciVid, pciDid: $pciDid, subVid: $subVid, subDid: $subDid,
          internalPciId: $internalPci, internalPdevId: $internalPdev,
          resourceProfile: $resourceProfile, framebufferMb: $framebufferMb
        } and
        (.driverEvidence | keys | sort) == [
          "catalog", "catalogSha256", "driverKey", "driverVersion", "inf", "infSha256",
          "packageSha256", "status"
        ] and
        .driverEvidence == {
          driverKey: $driverKey, driverVersion: $driverVersion, inf: $infName,
          infSha256: $infSha, catalog: $catalogName,
          catalogSha256: $catSha, packageSha256: $packageSha,
          status: "production-signed-pnp-match-host-audited-mdev-unproven"
        }
    ' "$file" >/dev/null \
        || die "host attestation 与当前 VM/disk/stage/driver evidence 不匹配"
    issued_at=$(jq -er .issuedAtUtc "$file") \
        || die "host attestation 缺 issuedAtUtc"
    issued_epoch=$(date -u -d "$issued_at" +%s 2>/dev/null) \
        || die "host attestation issuedAtUtc 无法解析"
    now_epoch=$(date -u +%s)
    age_seconds=$((now_epoch - issued_epoch))
    (( age_seconds >= -5 && age_seconds <= 600 )) \
        || die "host attestation 已过期或来自未来（有效期 10 分钟）"
}

if [[ "$ACTION" == attest ]]; then
    ((${#START_ARGS[@]} == 0)) \
        || die "attest 模式不接受 start-vm 参数"
    [[ "$REPLACE_ATTESTATION" == 0 || "$REPLACE_ATTESTATION" == 1 ]] \
        || die "internal replace state invalid"
    DRIVER_DIR=${DRIVER_DIR:-$IMAGE_ROOT/$SC_EVIDENCE_DRIVER_REL}
    [[ "$DRIVER_DIR" == /* && -d "$DRIVER_DIR" && ! -L "$DRIVER_DIR" ]] \
        || die "driver row $SC_DRIVER_KEY 的 audit 目录缺失或不安全: $DRIVER_DIR"
    INF="$DRIVER_DIR/$SC_INF_NAME"
    CAT="$DRIVER_DIR/$SC_CATALOG_NAME"
    PACKAGE="$IMAGE_ROOT/$SC_EVIDENCE_INSTALLER_REL"
    for evidence in "$INF" "$CAT" "$PACKAGE"; do
        [[ -f "$evidence" && ! -L "$evidence" &&
           "$(stat -c %h -- "$evidence")" == 1 ]] \
            || die "driver evidence 缺失或不安全: $evidence"
    done
    [[ "$(sha256sum -- "$INF" | awk '{print toupper($1)}')" == "$EXPECTED_INF_SHA" &&
       "$(sha256sum -- "$CAT" | awk '{print toupper($1)}')" == "$EXPECTED_CAT_SHA" &&
       "$(sha256sum -- "$PACKAGE" | awk '{print toupper($1)}')" == "$EXPECTED_PACKAGE_SHA" ]] \
        || die "$SC_DRIVER_KEY INF/CAT/package 不是已审计的原始字节"
    grep -Fqi "$SC_DRIVER_VERSION" "$INF" \
        || die "$SC_INF_NAME driver version mismatch"
    grep -Fqx "$SC_INF_MODEL_LINE" <(tr -d '\r' <"$INF" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//') \
        || die "$SC_INF_NAME 不含 canonical profile 的精确 PnP model row"

    if [[ -e "$ATTESTATION" || -L "$ATTESTATION" ]]; then
        (( REPLACE_ATTESTATION )) \
            || die "attestation 已存在；确认仍是可丢弃克隆后加 --replace-attestation"
        [[ -f "$ATTESTATION" && ! -L "$ATTESTATION" &&
           "$(stat -c %u -- "$ATTESTATION")" == "$(id -u)" ]] \
            || die "拒绝覆盖不安全 attestation: $ATTESTATION"
    fi
    [[ ! -e "$ATTESTATION_DIR" ||
       ( -d "$ATTESTATION_DIR" && ! -L "$ATTESTATION_DIR" &&
         "$(stat -c %u -- "$ATTESTATION_DIR")" == "$(id -u)" ) ]] \
        || die "probe 目录不安全: $ATTESTATION_DIR"
    mkdir -p -- "$ATTESTATION_DIR"
    chmod 0700 -- "$ATTESTATION_DIR"
    temporary=$(mktemp "$ATTESTATION_DIR/.attestation.XXXXXXXX")
    chmod 0600 "$temporary"
    nonce=$(tr -d '-' </proc/sys/kernel/random/uuid | tr '[:lower:]' '[:upper:]')
    jq -n \
        --argjson vmId "$VM_ID" \
        --arg vmUuid "${CONFIG_UUID,,}" \
        --arg stage "$STAGE" \
        --arg configSha "$CONFIG_SHA" \
        --arg diskPath "$DISK_PATH" \
        --arg diskToken "$DISK_TOKEN" \
        --argjson issuedByUid "$(id -u)" \
        --arg issuedAtUtc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg nonce "$nonce" \
        --arg profile "$SC_CANONICAL_GPU_PROFILE" \
        --arg profileSha "$PROFILE_SHA" \
        --arg gpuName "$SC_CANONICAL_GPU_NAME" \
        --arg pciVid "$EXPECTED_PCI_VID" --arg pciDid "$EXPECTED_PCI_DID" \
        --arg subVid "$EXPECTED_SUB_VID" --arg subDid "$EXPECTED_SUB_DID" \
        --arg internalPci "$EXPECTED_INTERNAL_PCI_ID" \
        --arg internalPdev "$EXPECTED_INTERNAL_PDEV_ID" \
        --arg resourceProfile "$SC_CANONICAL_MDEV_PROFILE" \
        --argjson framebufferMb "$SC_CANONICAL_FB_MB" \
        --arg driverKey "$SC_DRIVER_KEY" --arg driverVersion "$SC_DRIVER_VERSION" \
        --arg infName "$SC_INF_NAME" --arg catalogName "$SC_CATALOG_NAME" \
        --arg infSha "$EXPECTED_INF_SHA" \
        --arg catSha "$EXPECTED_CAT_SHA" \
        --arg packageSha "$EXPECTED_PACKAGE_SHA" '
        {
          schemaVersion: 2,
          purpose: "g11-signed-consumer-disposable-clone",
          disposableClone: true,
          vmId: $vmId,
          vmUuid: $vmUuid,
          stage: $stage,
          configSha256: $configSha,
          diskPath: $diskPath,
          diskStatToken: $diskToken,
          issuedByUid: $issuedByUid,
          issuedAtUtc: $issuedAtUtc,
          nonce: $nonce,
          gpu: {
            profile: $profile, profileSha256: $profileSha, name: $gpuName,
            pciVid: $pciVid, pciDid: $pciDid,
            subVid: $subVid, subDid: $subDid,
            internalPciId: $internalPci, internalPdevId: $internalPdev,
            resourceProfile: $resourceProfile, framebufferMb: $framebufferMb
          },
          driverEvidence: {
            driverKey: $driverKey, driverVersion: $driverVersion, inf: $infName,
            infSha256: $infSha, catalog: $catalogName,
            catalogSha256: $catSha, packageSha256: $packageSha,
            status: "production-signed-pnp-match-host-audited-mdev-unproven"
          }
        }
    ' >"$temporary"
    verify_attestation "$temporary"
    mv -fT -- "$temporary" "$ATTESTATION"
    echo "[signed-consumer-probe] attested vm${VM_ID} stage=${STAGE}"
    echo "  one-shot marker: $ATTESTATION"
    echo "  config remains: SPOOF_MODE=B / VGPU_IDENTITY_TARGET=name-only"
    echo "  next: $0 $VM_ID --stage '$STAGE' ${STORAGE_ARGS[*]}"
    exit 0
fi

[[ -z "$DRIVER_DIR" ]] || die "--driver-dir 只用于 --attest-disposable-clone"
(( REPLACE_ATTESTATION == 0 )) \
    || die "--replace-attestation 只用于 --attest-disposable-clone"

# These selectors can create a second identity path or inject another device.
# The launcher independently rechecks mode/tuple/config, but reject obvious
# ambiguity here before consuming the one-shot marker.
for argument in "${START_ARGS[@]}"; do
    case "$argument" in
        --spoof|--no-spoof|--spoof-name-only|--spoof-mode|--production-migration-source|\
        --install|--rescue|--rescue-sdl|--rescue-gtk|--no-gpu|--rdp|\
        --legacy-shmem|--extra|--monitor-sync)
            die "probe 不接受 start-vm 参数: $argument"
            ;;
    esac
done

verify_attestation "$ATTESTATION"

# Establish the rollback path before consuming authorization.  A full probe
# may leave internal vdev/pdev in the host TOML until the mdev is removed, so
# force the exact B name plus safe RM framebuffer descriptor contract both
# before and after the child.
DRY_RUN_ONLY=0
for argument in "${START_ARGS[@]}"; do
    [[ "$argument" == --dry-run ]] && DRY_RUN_ONLY=1
done

restore_b_identity() {
    (( DRY_RUN_ONLY )) && return 0
    if mdev_set_identity_override "$CONFIG_UUID" "$CONFIG_GPU_NAME" \
            "" "" "" "$CONFIG_RM_FB_BUS_WIDTH" "$CONFIG_RM_FB_RAM_TYPE" \
            "$CONFIG_RM_FB_MEMORY_VENDOR"; then
        echo "[signed-consumer-probe] host identity 已恢复 B/name-only + RM FB 描述"
        return 0
    fi
    echo "[signed-consumer-probe] ERROR: host identity 自动回 B 失败；不要再探测，先运行普通 B 启动或排查 /etc/vgpu_unlock/profile_override.toml" >&2
    return 1
}

restore_b_identity \
    || die "无法预先证明失败后的 B/RM-FB 恢复路径"

# FD 191 is intentionally inherited by start-vm after the directory entry is
# removed.  start-vm requires a regular mode-0600, caller-owned FD with nlink=0,
# making this authorization stage-specific and impossible to reuse by path.
exec 191<"$ATTESTATION"
flock -n 191 || die "attestation 正被另一个 probe 使用"
rm -f -- "$ATTESTATION"
[[ "$(stat -Lc %h -- /proc/self/fd/191)" == 0 ]] \
    || die "one-shot attestation 未成功消费"

CHILD_PID=""
CONFIG_SHA_BEFORE=$CONFIG_SHA
cleanup_probe() {
    local cleanup_rc=0
    if [[ -n "$CHILD_PID" ]] && kill -0 "$CHILD_PID" 2>/dev/null; then
        kill -TERM "$CHILD_PID" 2>/dev/null || true
        wait "$CHILD_PID" 2>/dev/null || true
    fi
    restore_b_identity || cleanup_rc=1
    if [[ -f "$CONF" && ! -L "$CONF" ]]; then
        current_sha=$(sha256sum -- "$CONF" | awk '{print toupper($1)}')
        if [[ "$current_sha" != "$CONFIG_SHA_BEFORE" ]]; then
            echo "[signed-consumer-probe] ERROR: vm.conf changed during probe；未自动覆盖用户文件" >&2
            cleanup_rc=1
        fi
    else
        echo "[signed-consumer-probe] ERROR: vm.conf disappeared during probe" >&2
        cleanup_rc=1
    fi
    exec 191<&- || true
    return "$cleanup_rc"
}
trap cleanup_probe EXIT
trap '[[ -z "$CHILD_PID" ]] || kill -TERM "$CHILD_PID" 2>/dev/null || true' INT TERM HUP

echo "[signed-consumer-probe] ONE-SHOT vm${VM_ID} stage=${STAGE}"
echo "  vm.conf 仍为 B；本次进程临时外层 PCI=${EXPECTED_PCI_VID}:${EXPECTED_PCI_DID}/${EXPECTED_SUB_VID}:${EXPECTED_SUB_DID}"
if [[ "$STAGE" == outer+internal ]]; then
    echo "  internal: pci_id=${EXPECTED_INTERNAL_PCI_ID} / pdev=${EXPECTED_INTERNAL_PDEV_ID}（退出后恢复 B）"
else
    echo "  internal: native（只测试 outer PCI）"
fi

G11_SIGNED_CONSUMER_PROBE_FD=191 \
    "$here/scripts/start-vm.sh" "$VM_ID" \
        "${STORAGE_ARGS[@]}" \
        --signed-consumer-probe "$STAGE" \
        --no-monitor-sync \
        "${START_ARGS[@]}" &
CHILD_PID=$!
set +e
wait "$CHILD_PID"
probe_rc=$?
set -e
CHILD_PID=""

cleanup_probe
trap - EXIT INT TERM HUP
if (( probe_rc != 0 )); then
    echo "[signed-consumer-probe] stage=${STAGE} failed (rc=${probe_rc}); authorization consumed, host returned to B" >&2
    exit "$probe_rc"
fi
echo "[signed-consumer-probe] stage=${STAGE} ended; authorization consumed, host returned to B"
