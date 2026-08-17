#!/usr/bin/env bash
# One host command + one guest EXE for legacy B-mode token/RTC preparation.
# The old GTX 1050 strict-A path is intentionally disabled because it modifies
# an INF and self-signs the replacement catalog.
# No RDP, VNC, WinRM, guest HTTP download, or guest IP discovery is used.
set -euo pipefail
umask 077

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"

# shellcheck source=lib/vm-storage.sh
source "$here/lib/vm-storage.sh"
vm_storage_init
# shellcheck source=lib/vgpu-profiles.sh
source "$here/lib/vgpu-profiles.sh"

usage() {
    cat >&2 <<'EOF'
usage: ./deploy/finish-vgpu-install.sh VM_ID [--token-file FILE.tok] [options]

LEGACY ONLY:
  Current GTX 750 Ti / GT 1030 / GTX 1050 B/native VMs do not use this
  command. Build the unified private finalizer instead:
    ./deploy/package-vgpu-one-click.sh --with-license-token
  This script remains only for pre-unification GTX750Ti/GT1030 token receipts
  and explicit old UTC-to-localtime migration.

Token selection:
  --token-file FILE      Use this local NVIDIA DLS client token
                         If omitted, auto-use $STAGE_DIR/client_configuration_token.tok
                         No token is downloaded by this script

Options:
  --rescue-gtk           Use a local GTK rescue window instead of SDL
  --build-only           Prepare the reusable EXE for supported B-mode targets
                         (GTX 1050 strict-A is disabled)
  --keep-package         Compatibility no-op; the reusable host EXE is kept
  --no-final-start       Prepare/migrate, but do not start the final vGPU boot
  -h, --help             Show this help

For an eligible legacy VM, keep this terminal open. B-mode name-only profiles
copy the old small shared EXE. GTX 1050 strict-A refuses before building
anything until a matching production-signed driver is available.
EOF
}

die() { echo "[vgpu-finish] ERROR: $*" >&2; exit 1; }
log() { echo "[vgpu-finish] $*"; }

export_token_from_local_dls() {
    local output="$STAGE_DIR/client_configuration_token.tok"
    local tmp bytes

    command -v curl >/dev/null 2>&1 || return 1
    mkdir -p "$STAGE_DIR"
    tmp=$(mktemp "$STAGE_DIR/.client_configuration_token.XXXXXX") || return 1
    if ! curl --insecure --fail --silent --show-error \
            --proto '=https' --proto-redir '=https' \
            --connect-timeout 3 --max-time 15 \
            https://127.0.0.1/-/client-token -o "$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    bytes=$(stat -c %s -- "$tmp") || { rm -f -- "$tmp"; return 1; }
    if (( bytes < 1024 || bytes > 1048576 )) ||
            LC_ALL=C head -c 256 -- "$tmp" |
                grep -Eiq '<[[:space:]]*(!doctype[[:space:]]+html|html)'; then
        rm -f -- "$tmp"
        return 1
    fi
    chmod 0600 "$tmp"
    mv -f -- "$tmp" "$output"
    TOKEN_FILE=$output
    log "exported local DLS token over host loopback HTTPS: $output ($bytes bytes)"
}

VM_ID=""
TOKEN_FILE="${VGPU_LICENSE_TOKEN_FILE:-}"
TOKEN_FILE_EXPLICIT=0
RESCUE_MODE=rescue-sdl
BUILD_ONLY=0
FINAL_START=1

while (( $# > 0 )); do
    case "$1" in
        --token-file)
            [[ $# -ge 2 ]] || die "--token-file requires a path"
            TOKEN_FILE=$2
            TOKEN_FILE_EXPLICIT=1
            shift 2
            ;;
        --rescue-gtk) RESCUE_MODE=rescue-gtk; shift ;;
        --build-only) BUILD_ONLY=1; shift ;;
        --keep-package) shift ;;
        --no-final-start) FINAL_START=0; shift ;;
        -h|--help) usage; exit 0 ;;
        [1-9]|[1-9][0-9]*)
            [[ -z "$VM_ID" ]] || die "VM id was supplied more than once"
            VM_ID=$1
            shift
            ;;
        *) die "unknown argument: $1" ;;
    esac
done

[[ -n "$VM_ID" ]] || { usage; exit 2; }
vm_storage_require_namespace_ready "$VM_ID" \
    || die "VM storage still uses an old/conflicting layout"

INSTANCE_DIR=$(vm_storage_instance_dir "$VM_ID")
CONF=$(vm_storage_config_path "$VM_ID")
DISK=$(vm_storage_disk_path "$VM_ID")
[[ -r "$CONF" ]] || die "VM config not found: $CONF"
[[ -f "$DISK" ]] || die "VM disk not found: $DISK"
RTC_CONTRACT_DECLARED=0
if grep -Eq '^RTC_CONTRACT=' "$CONF"; then
    RTC_CONTRACT_DECLARED=1
fi
# Identity and RTC are authoritative only when present in this VM's config.
# Do not let exported shell variables silently fill fields missing from an old
# vm.conf or change which VM the positional argument selected.
REQUESTED_VM_ID=$VM_ID
unset VM_ID VM_UUID GPU_NAME GPU_PROFILE GPU_PCI_VID GPU_PCI_DID \
    GPU_SUB_VID GPU_SUB_DID SPOOF_MODE RTC_CONTRACT VGPU_IDENTITY_TARGET \
    VGPU_MDEV_INTERNAL_PCI_IDENTITY VGPU_MDEV_FRL_ENABLED \
    VGPU_PATCHED_DRIVER_INF VGPU_PATCHED_DRIVER_VERSION \
    VGPU_PATCHED_DRIVER_REQUIRED_VERSION
# shellcheck source=/dev/null
source "$CONF"
CONFIG_VM_ID=${VM_ID-}
VM_ID=$REQUESTED_VM_ID
[[ -z "$CONFIG_VM_ID" || "$CONFIG_VM_ID" == "$VM_ID" ]] \
    || die "VM_ID=$CONFIG_VM_ID in $CONF does not match requested VM $VM_ID"
unset CONFIG_VM_ID REQUESTED_VM_ID
[[ "${VM_UUID:-}" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] \
    || die "VM_UUID is missing or invalid in $CONF"
STRICT_GTX1050=0
GTX1050_DRIVER_VERSION=31.0.15.3833
GTX1050_PATCHED_INF_SHA256=c7e38910c800fc9f5e72ec4d3613594a64b3e7b0465114e81a167ead43d42e4f
if [[ "${GPU_PROFILE:-}" == gtx1050_2gb ]]; then
    # Legacy configs may contain only GPU_PROFILE, or may predate some tuple
    # fields.  Validate every value they do contain before filling the exact
    # audited catalog record in memory; never silently correct a conflicting
    # identity and then attest it as GTX 1050.
    [[ -z "${GPU_NAME:-}" || "$GPU_NAME" == 'NVIDIA GeForce GTX 1050' ]] \
        || die "gtx1050_2gb has a conflicting GPU_NAME in $CONF: $GPU_NAME"
    for tuple_check in \
            "${GPU_PCI_VID:-}|0x10DE|GPU_PCI_VID" \
            "${GPU_PCI_DID:-}|0x1C81|GPU_PCI_DID" \
            "${GPU_SUB_VID:-}|0x1028|GPU_SUB_VID" \
            "${GPU_SUB_DID:-}|0x11C0|GPU_SUB_DID"; do
        IFS='|' read -r tuple_actual tuple_expected tuple_label <<<"$tuple_check"
        [[ -z "$tuple_actual" || "$tuple_actual" == "$tuple_expected" ]] \
            || die "gtx1050_2gb has conflicting $tuple_label=$tuple_actual (expected $tuple_expected)"
    done
    unset tuple_check tuple_actual tuple_expected tuple_label
    [[ -z "${VGPU_PATCHED_DRIVER_REQUIRED_VERSION:-}" ||
       "$VGPU_PATCHED_DRIVER_REQUIRED_VERSION" == "$GTX1050_DRIVER_VERSION" ]] \
        || die "gtx1050_2gb requires patched driver $GTX1050_DRIVER_VERSION, not $VGPU_PATCHED_DRIVER_REQUIRED_VERSION"
    legacy_gtx1050_fields=0
    [[ -n "${GPU_NAME:-}" && -n "${GPU_PCI_VID:-}" &&
       -n "${GPU_PCI_DID:-}" && -n "${GPU_SUB_VID:-}" &&
       -n "${GPU_SUB_DID:-}" ]] || legacy_gtx1050_fields=1
    vgpu_profile_load gtx1050_2gb \
        || die "could not load the audited gtx1050_2gb catalog record"
    (( legacy_gtx1050_fields == 0 )) || \
        log "legacy config: completed the audited GTX 1050 tuple from GPU_PROFILE"
    unset legacy_gtx1050_fields
    STRICT_GTX1050=1
elif [[ "${GPU_NAME:-}" == 'NVIDIA GeForce GTX 1050' ]]; then
    die "GPU_NAME requests strict GTX 1050 but GPU_PROFILE is ${GPU_PROFILE:-missing}; set/restore GPU_PROFILE=gtx1050_2gb before running the one-click flow"
elif [[ -z "${GPU_NAME:-}" ]]; then
    [[ -n "${GPU_PROFILE:-}" ]] \
        || die "GPU_NAME and GPU_PROFILE are both missing in $CONF"
    vgpu_profile_load "$GPU_PROFILE" \
        || die "could not derive GPU_NAME from legacy GPU_PROFILE=$GPU_PROFILE"
    log "legacy config: derived GPU target from GPU_PROFILE=$GPU_PROFILE"
fi
gpu_name_re='^[A-Za-z0-9][A-Za-z0-9._+() -]{0,30}$'
gpu_name_lower=${GPU_NAME,,}
[[ "$GPU_NAME" =~ $gpu_name_re && "$GPU_NAME" == NVIDIA\ * &&
   ${#GPU_NAME} -ge 8 && "$GPU_NAME" != *' ' &&
   "${GPU_NAME:7:1}" =~ [A-Za-z0-9] &&
   "$gpu_name_lower" != *grid* && "$gpu_name_lower" != *rtx6000* ]] \
    || die "GPU_NAME must be a safe 8..31 character NVIDIA consumer name (GRID/RTX6000 are not allowed)"
unset gpu_name_re
unset gpu_name_lower

if (( STRICT_GTX1050 )); then
    [[ "$GPU_NAME" == 'NVIDIA GeForce GTX 1050' &&
       "${GPU_PCI_VID:-}" == 0x10DE && "${GPU_PCI_DID:-}" == 0x1C81 &&
       "${GPU_SUB_VID:-}" == 0x1028 && "${GPU_SUB_DID:-}" == 0x11C0 ]] \
        || die "gtx1050_2gb strict policy does not match the audited 10DE:1C81 / 1028:11C0 tuple"
    die "GTX 1050 strict-A finish is disabled: the legacy flow modifies INF and self-signs its catalog. Keep this VM in B mode until a matching NVIDIA/Microsoft production-signed driver is available; no guest package or A/internal/FRL marker was written."
fi

# Only a flow that survived the production-signature policy may create the
# storage roots and per-instance run/log/backup directories used by rescue.
vm_storage_prepare
vm_storage_prepare_instance "$VM_ID"

# The rescue window can stay open while a file is transferred manually.  Do
# not let a profile edit during that interval be validated against the old
# in-memory UUID/GPU and then cold-booted with a new vm.conf.
refresh_vm_config_sha256() {
    local digest_line
    digest_line=$(sha256sum -- "$CONF") \
        || die "could not hash VM config: $CONF"
    VM_CONFIG_SHA256=${digest_line%% *}
}
verify_vm_config_unchanged() {
    local phase=$1 digest_line current_sha256
    digest_line=$(sha256sum -- "$CONF") \
        || die "VM config disappeared $phase: $CONF"
    current_sha256=${digest_line%% *}
    [[ "$current_sha256" == "$VM_CONFIG_SHA256" ]] \
        || die "VM config changed $phase; refusing to mix old guest preparation with new settings: $CONF"
}
refresh_vm_config_sha256

# The package is shared by every VM.  Keep the lock until the guest marker has
# been consumed so a concurrent run cannot replace a token-bearing EXE while
# the user is being told to copy it.  Atomic rename also means an unrelated
# manual reader sees either the complete old file or the complete new file.
mkdir -p "$STAGE_DIR"
PACKAGE="$STAGE_DIR/VgpuGuestFinish.exe"
PACKAGE_META="$STAGE_DIR/.VgpuGuestFinish.exe.meta"
PACKAGE_LOCK="$STAGE_DIR/.VgpuGuestFinish.exe.lock"
exec {PACKAGE_LOCK_FD}>"$PACKAGE_LOCK"
chmod 0600 "$PACKAGE_LOCK"
command -v flock >/dev/null 2>&1 || die "missing command: flock"
log "waiting for the shared guest EXE lock"
flock "$PACKAGE_LOCK_FD"
PACKAGE_LOCK_HELD=1
release_package_lock() {
    if [[ "${PACKAGE_LOCK_HELD:-0}" == 1 ]]; then
        flock -u "$PACKAGE_LOCK_FD" || true
        exec {PACKAGE_LOCK_FD}>&-
        PACKAGE_LOCK_HELD=0
    fi
}

if [[ -z "$TOKEN_FILE" ]]; then
    for candidate in \
        "$STAGE_DIR/client_configuration_token.tok" \
        "$here/host/fastapi-dls/out/client_configuration_token.tok"; do
        if [[ -f "$candidate" && -r "$candidate" ]]; then
            TOKEN_FILE=$candidate
            log "auto-selected local token: $TOKEN_FILE"
            break
        fi
    done
    if [[ -z "$TOKEN_FILE" ]] && ! export_token_from_local_dls; then
        die "no local token was found and the local DLS is unavailable; for a remote DLS, export client_configuration_token.tok on that server, copy it to this host, then pass --token-file"
    fi
fi
if ! TOKEN_FILE_REAL=$(realpath -e -- "$TOKEN_FILE" 2>/dev/null); then
    fallback="$STAGE_DIR/client_configuration_token.tok"
    if [[ "$TOKEN_FILE_EXPLICIT" == 1 && -f "$fallback" && -r "$fallback" ]]; then
        die "token file does not exist: $TOKEN_FILE; local token found at $fallback (rerun without --token-file)"
    fi
    die "token file does not exist: $TOKEN_FILE"
fi
TOKEN_FILE=$TOKEN_FILE_REAL
unset TOKEN_FILE_REAL
[[ -f "$TOKEN_FILE" && -r "$TOKEN_FILE" ]] || die "token is not a readable regular file"

# The shared EXE is deliberately private, so do not leave its source token
# world/group-readable in the normal staging directory.  An explicitly chosen
# token outside staging may have an administrator-managed ACL; warn rather than
# changing that external file behind the caller's back.
TOKEN_MODE=$(stat -c %a -- "$TOKEN_FILE")
TOKEN_OWNER=$(stat -c %u -- "$TOKEN_FILE")
STAGE_DIR_REAL=$(realpath -m -- "$STAGE_DIR")
if (( (8#$TOKEN_MODE & 077) != 0 )); then
    if [[ "$TOKEN_FILE" == "$STAGE_DIR_REAL/"* ]] &&
            (( EUID == 0 || TOKEN_OWNER == EUID )); then
        if chmod 0600 -- "$TOKEN_FILE"; then
            log "tightened staging token permissions to 0600: $TOKEN_FILE"
        else
            echo "[vgpu-finish] WARN: could not tighten token permissions: $TOKEN_FILE" >&2
        fi
    else
        echo "[vgpu-finish] WARN: token is group/other-accessible (mode $TOKEN_MODE): $TOKEN_FILE" >&2
    fi
fi
unset TOKEN_MODE TOKEN_OWNER STAGE_DIR_REAL

# Snapshot the token while holding the package lock.  The source path may be
# atomically refreshed by an administrator; the builder and expected marker
# hash must nevertheless refer to exactly the same bytes.
TOKEN_SNAPSHOT=$(mktemp "$STAGE_DIR/.VgpuGuestFinish.token.XXXXXX")
PACKAGE_TMP=""
META_TMP=""
BUNDLE_TMP=""
BUNDLE_META_TMP=""
cleanup_package_temps() {
    rm -f -- "${TOKEN_SNAPSHOT:-}" "${PACKAGE_TMP:-}" "${META_TMP:-}" \
        "${BUNDLE_TMP:-}" "${BUNDLE_META_TMP:-}"
}
trap cleanup_package_temps EXIT
install -m 0600 -- "$TOKEN_FILE" "$TOKEN_SNAPSHOT"
TOKEN_SHA256=$(sha256sum -- "$TOKEN_SNAPSHOT" | awk '{print toupper($1)}')
BUILD_INPUT_SHA256=$(sha256sum -- \
    "$here/guest/vgpu-finish/build.sh" \
    "$here/guest/vgpu-finish/vgpu_guest_finish.c" \
    "$here/guest/vgpu-finish/vgpu_guest_finish.rc" \
    "$here/guest/vgpu-finish/vgpu_guest_finish.manifest" |
    sha256sum | awk '{print toupper($1)}')

cache_ok=0
if [[ -f "$PACKAGE" && ! -L "$PACKAGE" && -f "$PACKAGE_META" && ! -L "$PACKAGE_META" ]]; then
    chmod 0600 "$PACKAGE" "$PACKAGE_META"
    PACKAGE_SHA256=$(sha256sum -- "$PACKAGE" | awk '{print toupper($1)}')
    if [[ $(wc -l <"$PACKAGE_META") -eq 3 ]] &&
            grep -Fxq "TOKEN_SHA256=$TOKEN_SHA256" "$PACKAGE_META" &&
            grep -Fxq "EXE_SHA256=$PACKAGE_SHA256" "$PACKAGE_META" &&
            grep -Fxq "BUILD_INPUT_SHA256=$BUILD_INPUT_SHA256" "$PACKAGE_META"; then
        cache_ok=1
    fi
fi

if (( cache_ok )); then
    log "reusing shared guest EXE for this token: $PACKAGE"
else
    PACKAGE_TMP=$(mktemp "$STAGE_DIR/.VgpuGuestFinish.exe.XXXXXX")
    META_TMP=$(mktemp "$STAGE_DIR/.VgpuGuestFinish.exe.meta.XXXXXX")
    log "building shared guest EXE for the selected token"
    "$here/guest/vgpu-finish/build.sh" \
        --token-file "$TOKEN_SNAPSHOT" \
        --output "$PACKAGE_TMP"
    [[ -s "$PACKAGE_TMP" && ! -L "$PACKAGE_TMP" ]] \
        || die "builder did not produce a regular non-empty EXE"
    chmod 0600 "$PACKAGE_TMP"
    PACKAGE_SHA256=$(sha256sum -- "$PACKAGE_TMP" | awk '{print toupper($1)}')
    printf 'TOKEN_SHA256=%s\nEXE_SHA256=%s\nBUILD_INPUT_SHA256=%s\n' \
        "$TOKEN_SHA256" "$PACKAGE_SHA256" "$BUILD_INPUT_SHA256" >"$META_TMP"
    chmod 0600 "$META_TMP"
    # Publish the executable first.  If power is lost between these renames,
    # the old metadata cannot validate the new EXE and the next run rebuilds.
    mv -Tf -- "$PACKAGE_TMP" "$PACKAGE"
    PACKAGE_TMP=""
    mv -Tf -- "$META_TMP" "$PACKAGE_META"
    META_TMP=""
    log "published shared guest EXE atomically: $PACKAGE"
fi
rm -f -- "$TOKEN_SNAPSHOT"
TOKEN_SNAPSHOT=""

TRANSFER_PACKAGE=$PACKAGE
if (( STRICT_GTX1050 )); then
    DRIVER_ARTIFACT="$STAGE_DIR/538.33-gtx1050_2gb-patched"
    DRIVER_STAGER="$here/guest/stage-patched-vgpu-driver.ps1"
    DRIVER_BUNDLE_README="$here/guest/vgpu-finish/README-GTX1050.txt"
    BUNDLE="$STAGE_DIR/VgpuGuestFinish-GTX1050.zip"
    BUNDLE_META="$STAGE_DIR/.VgpuGuestFinish-GTX1050.zip.meta"

    [[ -x "$here/host/build-vgpu-driver-patch.py" ]] \
        || die "missing audited GTX 1050 driver builder"
    [[ -r "$DRIVER_STAGER" && -r "$DRIVER_BUNDLE_README" ]] \
        || die "missing GTX 1050 guest bundle inputs"
    "$here/host/build-vgpu-driver-patch.py" --profile gtx1050_2gb \
        --output-dir "$DRIVER_ARTIFACT"
    [[ -f "$DRIVER_ARTIFACT/.vgpu-patch-manifest.json" ]] \
        || die "audited driver builder did not publish its manifest"

    ARTIFACT_MANIFEST_SHA256=$(sha256sum -- \
        "$DRIVER_ARTIFACT/.vgpu-patch-manifest.json" | awk '{print toupper($1)}')
    DRIVER_STAGER_SHA256=$(sha256sum -- "$DRIVER_STAGER" | awk '{print toupper($1)}')
    DRIVER_BUNDLE_README_SHA256=$(sha256sum -- "$DRIVER_BUNDLE_README" | awk '{print toupper($1)}')
    BUNDLE_INPUT_SHA256=$(printf '%s\n' \
        "$PACKAGE_SHA256" "$ARTIFACT_MANIFEST_SHA256" \
        "$DRIVER_STAGER_SHA256" "$DRIVER_BUNDLE_README_SHA256" |
        sha256sum | awk '{print toupper($1)}')

    bundle_cache_ok=0
    if [[ -f "$BUNDLE" && ! -L "$BUNDLE" &&
          -f "$BUNDLE_META" && ! -L "$BUNDLE_META" ]]; then
        chmod 0600 "$BUNDLE" "$BUNDLE_META"
        BUNDLE_SHA256=$(sha256sum -- "$BUNDLE" | awk '{print toupper($1)}')
        if [[ $(wc -l <"$BUNDLE_META") -eq 2 ]] &&
                grep -Fxq "BUNDLE_INPUT_SHA256=$BUNDLE_INPUT_SHA256" "$BUNDLE_META" &&
                grep -Fxq "ZIP_SHA256=$BUNDLE_SHA256" "$BUNDLE_META"; then
            bundle_cache_ok=1
        fi
    fi

    if (( bundle_cache_ok )); then
        log "reusing audited GTX 1050 guest ZIP: $BUNDLE"
    else
        command -v zip >/dev/null 2>&1 || die "missing command: zip"
        command -v unzip >/dev/null 2>&1 || die "missing command: unzip"
        BUNDLE_TMP="$STAGE_DIR/.VgpuGuestFinish-GTX1050.$$.$RANDOM.zip"
        BUNDLE_META_TMP=$(mktemp "$STAGE_DIR/.VgpuGuestFinish-GTX1050.zip.meta.XXXXXX")
        [[ ! -e "$BUNDLE_TMP" ]] || die "temporary bundle path already exists"
        log "building private GTX 1050 ZIP (first run compresses the locked 1.8 GiB driver tree)"
        (
            cd "$STAGE_DIR"
            zip -q -1 -r "$BUNDLE_TMP" "$(basename "$DRIVER_ARTIFACT")"
        )
        zip -q -j "$BUNDLE_TMP" "$PACKAGE" "$DRIVER_STAGER" \
            "$DRIVER_BUNDLE_README"
        unzip -tq "$BUNDLE_TMP" >/dev/null \
            || die "generated GTX 1050 ZIP failed integrity validation"
        chmod 0600 "$BUNDLE_TMP"
        BUNDLE_SHA256=$(sha256sum -- "$BUNDLE_TMP" | awk '{print toupper($1)}')
        printf 'BUNDLE_INPUT_SHA256=%s\nZIP_SHA256=%s\n' \
            "$BUNDLE_INPUT_SHA256" "$BUNDLE_SHA256" >"$BUNDLE_META_TMP"
        chmod 0600 "$BUNDLE_META_TMP"
        mv -Tf -- "$BUNDLE_TMP" "$BUNDLE"
        BUNDLE_TMP=""
        mv -Tf -- "$BUNDLE_META_TMP" "$BUNDLE_META"
        BUNDLE_META_TMP=""
        log "published audited GTX 1050 guest ZIP atomically: $BUNDLE"
    fi
    TRANSFER_PACKAGE=$BUNDLE
fi
trap - EXIT

if (( BUILD_ONLY )); then
    log "build-only complete: $TRANSFER_PACKAGE"
    release_package_lock
    exit 0
fi

cat <<EOF

==================== 只做这三步 ====================
1. 保持这个宿主终端开着；马上会弹出本地标准显卡救援窗口。
2. 手动把下面这个文件传进 Windows：
   $TRANSFER_PACKAGE
3. GTX 1050：先“全部解压”ZIP，再双击其中 VgpuGuestFinish.exe；
   其他型号：直接双击 EXE。UAC 选「是」，成功窗口点「确定」。

GTX 1050 EXE 会先校验并预暂存 audited 538.33/DEV_1C81 驱动；只有成功后才
安装 token、更新名称、关闭休眠/Fast Startup、写 V3 回执并完整关机。
不要点“重启”，不要关闭 QEMU 窗口，也不需要 RDP/VNC/guest IP。
====================================================
EOF

# Acquire sudo before the rescue window opens.  Otherwise a long-idle terminal
# could stop for a password only after Windows has already shut down.
if (( EUID != 0 )) && ! sudo -n true 2>/dev/null; then
    log "host-only RTC migration will need sudo; authenticate once now"
    sudo -v || die "sudo authentication failed"
fi

# The qemu-9.2.0 lineage always supplied a local RTC but did not persist a
# field in vm.conf.  Treating an absent field as UTC moves Windows backwards
# eight hours and makes NVIDIA DLS reject the lease with Clock windback.
RTC_CONTRACT_CURRENT=${RTC_CONTRACT-localtime}
# The rescue display never attaches the mdev.  Force the in-memory identity to
# off as well, so a hand-edited/half-old A config that is missing tuple fields
# cannot fail internal-ID validation before the repair EXE even starts.
rescue_args=( "$VM_ID" "--${RESCUE_MODE}" --no-monitor-sync --no-spoof )
case "$RTC_CONTRACT_CURRENT" in
    localtime)
        log "starting local rescue with the host local-RTC contract"
        ;;
    utc)
        # This is the only safe first boot for a VM that may already contain
        # RealTimeIsUniversal=1. Switching it to localtime first would jump the
        # Windows clock eight hours into the future.
        rescue_args+=( --rtc-utc-compat )
        log "starting one UTC-compatible local rescue before host-only RTC migration"
        ;;
    *) die "unknown RTC_CONTRACT in $CONF: $RTC_CONTRACT_CURRENT" ;;
esac

verify_vm_config_unchanged "before the rescue boot"
set +e
VGPU_GUEST_FINISH_TARGET="$GPU_NAME" \
    "$here/scripts/start-vm.sh" "${rescue_args[@]}"
rescue_rc=$?
set -e
(( rescue_rc == 0 )) || die "rescue QEMU exited with status $rescue_rc; package was kept at $TRANSFER_PACKAGE"
verify_vm_config_unchanged "while the rescue guest was running"

log "guest stopped; verifying its completion marker and normalizing RTC from the host"
# Manual file transfer/UAC may outlive sudo's timestamp.  Refresh here, after
# the rescue window has closed, so an expired ticket cannot turn a successful
# guest run into a dead end that requires starting the rescue all over again.
if (( EUID != 0 )) && ! sudo -n true 2>/dev/null; then
    log "refreshing sudo authentication for the host-only offline step"
    sudo -v || die "sudo authentication failed after guest shutdown"
fi
RTC_BACKUP_DIR="$INSTANCE_DIR/backups/rtc"
migrate_args=(
    "$here/host/migrate-windows-local-rtc.sh"
    --disk "$DISK"
    --instance "vm${VM_ID}"
    --backup-dir "$RTC_BACKUP_DIR"
    --expected-vm "vm${VM_ID}"
    --expected-uuid "$VM_UUID"
    --expected-gpu-name "$GPU_NAME"
    --expected-token-sha256 "$TOKEN_SHA256"
)
if (( STRICT_GTX1050 )); then
    migrate_args+=(
        --expected-driver-profile gtx1050_2gb
        --expected-driver-version "$GTX1050_DRIVER_VERSION"
        --expected-patched-inf-sha256 "$GTX1050_PATCHED_INF_SHA256"
    )
fi
if (( EUID == 0 )); then
    "${migrate_args[@]}"
elif sudo -n true 2>/dev/null; then
    sudo -- "${migrate_args[@]}"
elif [[ -n "${SUDO_PASSWORD:-}" ]]; then
    printf '%s\n' "$SUDO_PASSWORD" | sudo -S -p '' -- "${migrate_args[@]}"
else
    die "RTC migration needs sudo; run sudo -v and rerun this command"
fi
verify_vm_config_unchanged "during the offline RTC migration"

if [[ "$RTC_CONTRACT_CURRENT" == utc || "$RTC_CONTRACT_DECLARED" == 0 ]]; then
    config_backup_dir="$INSTANCE_DIR/backups/config"
    mkdir -p "$config_backup_dir"
    chmod 0700 "$config_backup_dir"
    config_backup="$config_backup_dir/vm.conf.before-local-rtc-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    install -m 0400 -- "$CONF" "$config_backup"
    config_tmp="$(dirname "$CONF")/.$(basename "$CONF").rtc.$$.$RANDOM"
    cleanup_config_tmp() { rm -f -- "$config_tmp"; }
    trap cleanup_config_tmp EXIT
    awk '!/^RTC_CONTRACT=/' "$CONF" >"$config_tmp"
    printf '\n# QEMU process supplies Asia/Shanghai local RTC; Windows uses default local-RTC semantics.\nRTC_CONTRACT=localtime\n' \
        >>"$config_tmp"
    chmod --reference="$CONF" "$config_tmp"
    mv -T -- "$config_tmp" "$CONF"
    trap - EXIT
    grep -Fxq 'RTC_CONTRACT=localtime' "$CONF" \
        || die "failed to persist RTC_CONTRACT=localtime in $CONF"
    refresh_vm_config_sha256
    log "RTC contract recorded in vm.conf (backup: $config_backup)"
fi

if (( STRICT_GTX1050 )); then
    # The driver receipt was just verified from this stopped Windows disk.
    # Only now make strict consumer identity the persistent default.  Do not
    # retain a cloned VM's oemN.inf number: Windows allocates it per image and
    # the V3 marker already verified the actual published package.
    config_backup_dir="$INSTANCE_DIR/backups/config"
    mkdir -p "$config_backup_dir"
    chmod 0700 "$config_backup_dir"
    strict_backup="$config_backup_dir/vm.conf.before-gtx1050-full-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    install -m 0400 -- "$CONF" "$strict_backup"
    strict_tmp="$(dirname "$CONF")/.$(basename "$CONF").gtx1050.$$.$RANDOM"
    cleanup_strict_tmp() { rm -f -- "$strict_tmp"; }
    trap cleanup_strict_tmp EXIT
    awk '!/^(GPU_PROFILE|GPU_NAME|GPU_PCI_VID|GPU_PCI_DID|GPU_SUB_VID|GPU_SUB_DID|GPU_REV|GPU_VRAM_MB|GPU_VBIOS|GPU_CORE_MHZ|GPU_BOOST_MHZ|GPU_MEMORY_MHZ|GPU_MEMORY_BUS_BITS|GPU_MEMORY_BANDWIDTH_MBPS|GPU_MEMORY_TYPE|GPU_MEMORY_MAKER|GPU_MEMORY_TYPE_NVAPI|GPU_MEMORY_MAKER_NVAPI|GPU_CUDA_CORES|GPU_SHADER_SUBPIPES|GPU_ROP_COUNT|GPU_TMU_COUNT|GPU_ARCHITECTURE|GPU_IMPLEMENTATION|GPU_CHIP_REVISION|GPU_PCIE_WIDTH|VGPU_MDEV_PROFILE|VGPU_FB_MB|SPOOF_MODE|VGPU_IDENTITY_TARGET|VGPU_MDEV_INTERNAL_PCI_IDENTITY|VGPU_MDEV_FRL_ENABLED|VGPU_PATCHED_DRIVER_INF|VGPU_PATCHED_DRIVER_VERSION|VGPU_PATCHED_DRIVER_REQUIRED_VERSION)=/' \
        "$CONF" >"$strict_tmp"
    cat >>"$strict_tmp" <<EOF

# Audited GTX 1050 strict identity; written only after a V3 driver receipt.
GPU_PROFILE=gtx1050_2gb
GPU_NAME="NVIDIA GeForce GTX 1050"
GPU_PCI_VID=0x10DE
GPU_PCI_DID=0x1C81
GPU_SUB_VID=0x1028
GPU_SUB_DID=0x11C0
GPU_REV=$GPU_REV
GPU_VRAM_MB=$GPU_VRAM_MB
GPU_VBIOS="$GPU_VBIOS"
GPU_CORE_MHZ=$GPU_CORE_MHZ
GPU_BOOST_MHZ=$GPU_BOOST_MHZ
GPU_MEMORY_MHZ=$GPU_MEMORY_MHZ
GPU_MEMORY_BUS_BITS=$GPU_MEMORY_BUS_BITS
GPU_MEMORY_BANDWIDTH_MBPS=$GPU_MEMORY_BANDWIDTH_MBPS
GPU_MEMORY_TYPE=$GPU_MEMORY_TYPE
GPU_MEMORY_MAKER=$GPU_MEMORY_MAKER
GPU_MEMORY_TYPE_NVAPI=$GPU_MEMORY_TYPE_NVAPI
GPU_MEMORY_MAKER_NVAPI=$GPU_MEMORY_MAKER_NVAPI
GPU_CUDA_CORES=$GPU_CUDA_CORES
GPU_SHADER_SUBPIPES=$GPU_SHADER_SUBPIPES
GPU_ROP_COUNT=$GPU_ROP_COUNT
GPU_TMU_COUNT=$GPU_TMU_COUNT
GPU_ARCHITECTURE=$GPU_ARCHITECTURE
GPU_IMPLEMENTATION=$GPU_IMPLEMENTATION
GPU_CHIP_REVISION=$GPU_CHIP_REVISION
GPU_PCIE_WIDTH=$GPU_PCIE_WIDTH
VGPU_MDEV_PROFILE=$VGPU_MDEV_PROFILE
VGPU_FB_MB=2048
VGPU_IDENTITY_TARGET=full-consumer
SPOOF_MODE=A
VGPU_MDEV_INTERNAL_PCI_IDENTITY=1
VGPU_MDEV_FRL_ENABLED=0
VGPU_PATCHED_DRIVER_REQUIRED_VERSION=$GTX1050_DRIVER_VERSION
VGPU_PATCHED_DRIVER_VERSION=$GTX1050_DRIVER_VERSION
EOF
    chmod --reference="$CONF" "$strict_tmp"
    chown --reference="$CONF" "$strict_tmp" 2>/dev/null || true
    mv -T -- "$strict_tmp" "$CONF"
    trap - EXIT
    for strict_line in \
            'GPU_PROFILE=gtx1050_2gb' \
            'GPU_NAME="NVIDIA GeForce GTX 1050"' \
            'GPU_PCI_VID=0x10DE' 'GPU_PCI_DID=0x1C81' \
            'GPU_SUB_VID=0x1028' 'GPU_SUB_DID=0x11C0' \
            'GPU_VBIOS="Version 86.07.39.40.F4"' \
            'GPU_MEMORY_TYPE_NVAPI=8' 'GPU_MEMORY_MAKER_NVAPI=1' \
            'GPU_CUDA_CORES=640' 'GPU_SHADER_SUBPIPES=5' \
            'GPU_ROP_COUNT=32' 'GPU_TMU_COUNT=40' 'GPU_ARCHITECTURE=0x130' \
            'GPU_IMPLEMENTATION=7' 'GPU_CHIP_REVISION=0x11' \
            'GPU_PCIE_WIDTH=16' \
            'VGPU_IDENTITY_TARGET=full-consumer' 'SPOOF_MODE=A' \
            'VGPU_MDEV_INTERNAL_PCI_IDENTITY=1' 'VGPU_MDEV_FRL_ENABLED=0' \
            "VGPU_PATCHED_DRIVER_VERSION=$GTX1050_DRIVER_VERSION"; do
        grep -Fxq "$strict_line" "$CONF" \
            || die "failed to persist strict GTX 1050 policy: $strict_line"
    done
    refresh_vm_config_sha256
    log "strict GTX 1050 identity recorded in vm.conf (backup: $strict_backup)"
fi

grep -Fxq 'RTC_CONTRACT=localtime' "$CONF" \
    || die "refusing the final boot: $CONF is not persisted as RTC_CONTRACT=localtime"
verify_vm_config_unchanged "before the final hand-off"

log "kept reusable private guest package: $TRANSFER_PACKAGE (mode 0600); delete only the copied guest files"
release_package_lock

if (( ! FINAL_START )); then
    log "preparation complete; later run: ./deploy/scripts/start-vm.sh $VM_ID"
    exit 0
fi

cat <<EOF

[vgpu-finish] 宿主迁移完成。现在自动执行正常 vGPU 冷启动：
  ./deploy/scripts/start-vm.sh $VM_ID

EDID 会在启动前自动同步。GTX 1050 严格身份的验收是 Code 0、538.33、
DEV_1C81/SUBSYS_11C01028 和 Frame Rate Limit N/A；控制面板无授权页且 host
仍显示 Unlicensed 不等于“已激活”。B/off 模式才继续验收 DLS/Licensed。
EOF
"$here/scripts/start-vm.sh" "$VM_ID"
