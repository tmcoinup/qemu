#!/usr/bin/env bash
# Offline cleanup for WeGame/Tencent state that must not be shared by every
# clone made from one Windows base.  This is the G-11-safe counterpart of the
# V-11 helper: dirty/hibernated NTFS fails closed and is never force-repaired.
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HIVE_VALIDATOR="$DEPLOY_DIR/lib/windows_hive.py"

usage() {
    cat <<'EOF'
usage: sudo ./deploy/scripts/host-clean-tencent.sh VM_ID [options]

Options:
  --disk QCOW2     Clean this explicit VM disk (seal-base.sh uses this)
  --dry-run        List matching files/registry keys without changing them
  --no-registry    Delete file caches only; keep Tencent registry keys
  --nbd DEVICE     Use an explicit free /dev/nbdN
  -h, --help       Show this help

The normal seal-base.sh path invokes this automatically.  It removes Tencent/
WeGame QIMEI, login/SSO, SDK/device and GPU shader caches, but does not remove
ACE program files.  Dirty or hibernated Windows volumes are rejected without
ntfsfix, remove_hiberfile, BCD changes, or driver changes.
EOF
}

log() {
    printf '[clean-tencent] %s\n' "$*"
}

die() {
    log "ERROR: $*" >&2
    exit 1
}

VM_ID=""
DISK_ARG=""
DRY_RUN=0
DO_REGISTRY=1
NBD_ARG=""
while (($#)); do
    case "$1" in
        --disk)
            (($# >= 2)) || die "--disk requires a path"
            DISK_ARG=$2
            shift 2
            ;;
        --disk=*)
            DISK_ARG=${1#*=}
            [[ -n "$DISK_ARG" ]] || die "--disk requires a path"
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --no-registry)
            DO_REGISTRY=0
            shift
            ;;
        --nbd)
            (($# >= 2)) || die "--nbd requires a device"
            NBD_ARG=$2
            shift 2
            ;;
        --nbd=*)
            NBD_ARG=${1#*=}
            [[ -n "$NBD_ARG" ]] || die "--nbd requires a device"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            if [[ -z "$VM_ID" && "$1" =~ ^[1-9][0-9]*$ ]]; then
                VM_ID=$1
                shift
            else
                die "unknown argument or duplicate/invalid VM_ID: $1"
            fi
            ;;
    esac
done

[[ -n "$VM_ID" ]] || {
    usage >&2
    exit 2
}
(( EUID == 0 )) || die "需要 root（qemu-nbd / NTFS 离线挂载）"

for dependency in qemu-nbd qemu-img ntfs-3g.probe mount umount blkid \
        lsblk modprobe partprobe udevadm flock lsof realpath python3 sync find; do
    command -v "$dependency" >/dev/null 2>&1 ||
        die "missing dependency: $dependency"
done
python3 -c 'import hivex' >/dev/null 2>&1 ||
    die "missing dependency: python3-hivex"
[[ -r "$HIVE_VALIDATOR" ]] || die "missing hive validator: $HIVE_VALIDATOR"

if [[ -z "$DISK_ARG" ]]; then
    # shellcheck source=../lib/vm-storage.sh
    source "$DEPLOY_DIR/lib/vm-storage.sh"
    vm_storage_init
    vm_storage_require_namespace_ready "$VM_ID"
    DISK_ARG=$(vm_storage_disk_path "$VM_ID")
fi
[[ "$DISK_ARG" == /* && "$DISK_ARG" != / ]] ||
    die "disk must be a non-root absolute path"
DISK=$(realpath -e -- "$DISK_ARG") || die "disk does not exist: $DISK_ARG"
[[ -f "$DISK" && ! -L "$DISK" ]] ||
    die "disk must be a regular non-symlink file: $DISK"
qemu-img check -q "$DISK" || die "qcow2 check failed before cleanup"

if [[ -n "$NBD_ARG" ]]; then
    [[ "$NBD_ARG" =~ ^/dev/nbd([0-9]|[12][0-9]|3[01])$ ]] ||
        die "--nbd must be /dev/nbd0 through /dev/nbd31"
    NBD=$NBD_ARG
    _NBD_PINNED=1
elif [[ -n "${NBD:-}" ]]; then
    [[ "$NBD" =~ ^/dev/nbd([0-9]|[12][0-9]|3[01])$ ]] ||
        die "NBD must be /dev/nbd0 through /dev/nbd31"
    _NBD_PINNED=1
else
    NBD=/dev/nbd0
    _NBD_PINNED=""
fi

# shellcheck source=../lib/nbd-lock.sh
source "$DEPLOY_DIR/lib/nbd-lock.sh"
MOUNT_DIR=$(mktemp -d /tmp/g11-wegame-clean.XXXXXXXX)
MOUNTED=0
CLEANUP_COMPLETE=0
cleanup() {
    local status=$?
    local cleanup_status=$status
    trap - EXIT HUP INT TERM
    if (( MOUNTED )); then
        if umount -- "$MOUNT_DIR" >/dev/null 2>&1; then
            MOUNTED=0
        else
            log "ERROR: cleanup could not unmount $MOUNT_DIR" >&2
            cleanup_status=70
        fi
    fi
    if [[ "${_NBD_CONNECTED:-0}" == 1 && -n "${_NBD_DEV:-}" ]]; then
        if qemu-nbd --disconnect "$_NBD_DEV" >/dev/null 2>&1; then
            _NBD_CONNECTED=0
        else
            log "ERROR: cleanup could not disconnect $_NBD_DEV" >&2
            cleanup_status=70
        fi
    fi
    rmdir -- "$MOUNT_DIR" >/dev/null 2>&1 || true
    if (( status == 0 && ! CLEANUP_COMPLETE )); then
        cleanup_status=70
    elif (( cleanup_status == 0 )); then
        cleanup_status=$status
    fi
    exit "$cleanup_status"
}
trap cleanup EXIT HUP INT TERM

modprobe nbd max_part=32 >/dev/null 2>&1 || true
access_mode=read-write
(( DRY_RUN )) && access_mode=read-only
log "disk: $DISK"
(( DRY_RUN )) && log "DRY-RUN：只列出，不删除"
nbd_connect NBD "$DISK" "$access_mode"
partprobe "$NBD"
udevadm settle

mapfile -t PARTITIONS < <(
    lsblk -lnpo NAME,TYPE "$NBD" | awk '$2 == "part" { print $1 }'
)
((${#PARTITIONS[@]} > 0)) || die "磁盘没有可见分区"

WINDOWS_PARTITION=""
for partition in "${PARTITIONS[@]}"; do
    [[ "$(blkid -o value -s TYPE -- "$partition" 2>/dev/null || true)" == ntfs ]] ||
        continue
    if mount -t ntfs-3g -o ro,norecover -- "$partition" "$MOUNT_DIR" \
            >/dev/null 2>&1; then
        MOUNTED=1
        if [[ -d "$MOUNT_DIR/Windows/System32/config" &&
              -d "$MOUNT_DIR/Users" ]]; then
            WINDOWS_PARTITION=$partition
        fi
        umount -- "$MOUNT_DIR" || die "临时只读挂载无法卸载: $partition"
        MOUNTED=0
        [[ -z "$WINDOWS_PARTITION" ]] || break
    fi
done
[[ -n "$WINDOWS_PARTITION" ]] || die "找不到 Windows NTFS 系统分区"
log "Windows system partition: $WINDOWS_PARTITION"

if (( DRY_RUN )); then
    mount -t ntfs-3g -o ro,norecover -- "$WINDOWS_PARTITION" "$MOUNT_DIR" ||
        die "Windows NTFS 无法安全只读挂载"
else
    probe_rc=0
    ntfs-3g.probe --readwrite "$WINDOWS_PARTITION" || probe_rc=$?
    case "$probe_rc" in
        0) ;;
        14)
            die "Windows 处于休眠/Fast Startup；请在 guest 执行 powercfg -h off 后完整关机再重试"
            ;;
        15)
            die "Windows 卷未干净卸载；请正常启动 guest 并完整关机后重试"
            ;;
        *)
            die "NTFS 可写性预检失败（ntfs-3g.probe rc=$probe_rc）"
            ;;
    esac
    mount -t ntfs-3g -o rw,norecover -- "$WINDOWS_PARTITION" "$MOUNT_DIR" ||
        die "Windows NTFS 无法安全可写挂载"
fi
MOUNTED=1

shopt -s nullglob
PROFILE_DIRS=()
for profile_dir in "$MOUNT_DIR"/Users/*/; do
    [[ -d "$profile_dir" ]] || continue
    case "$(basename -- "$profile_dir")" in
        'All Users'|'Default'|'Default User'|'Public') continue ;;
    esac
    PROFILE_DIRS+=("$profile_dir")
done

HIVE_PATHS=()
HIVE_KEYS=()
HIVE_LABELS=()
if (( DO_REGISTRY )); then
    SOFTWARE_HIVE="$MOUNT_DIR/Windows/System32/config/SOFTWARE"
    [[ -f "$SOFTWARE_HIVE" ]] || die "Windows SOFTWARE hive is missing"
    HIVE_PATHS+=("$SOFTWARE_HIVE")
    HIVE_KEYS+=('Tencent|WOW6432Node\Tencent')
    HIVE_LABELS+=('HKLM\\SOFTWARE')
    for profile_dir in "${PROFILE_DIRS[@]}"; do
        [[ -f "${profile_dir}NTUSER.DAT" ]] || continue
        HIVE_PATHS+=("${profile_dir}NTUSER.DAT")
        HIVE_KEYS+=('Software\Tencent')
        HIVE_LABELS+=("HKU\\$(basename -- "$profile_dir")")
    done

    # Validate every hive before deleting any files or registry keys.  Dirty
    # headers/logs are rejected rather than normalized behind Windows' back.
    for index in "${!HIVE_PATHS[@]}"; do
        PYTHONDONTWRITEBYTECODE=1 python3 "$HIVE_VALIDATOR" \
            "${HIVE_PATHS[$index]}" "${HIVE_LABELS[$index]} preflight" >/dev/null
    done
fi

TARGETS=(
    "$MOUNT_DIR/ProgramData/Tencent"
    "$MOUNT_DIR/ProgramData/WeGame"
)
for profile_dir in "${PROFILE_DIRS[@]}"; do
    TARGETS+=(
        "${profile_dir}AppData/Roaming/Tencent"
        "${profile_dir}AppData/Local/WeGame"
        "${profile_dir}AppData/Local/rail"
        "${profile_dir}AppData/Local/RailCrashReport"
        "${profile_dir}AppData/Local/ConnectedDevicesPlatform"
        "${profile_dir}AppData/Local/D3DSCache"
        "${profile_dir}AppData/Local/Temp"
    )
done

deleted_targets=0
log "file caches:"
for target in "${TARGETS[@]}"; do
    [[ -e "$target" || -L "$target" ]] || continue
    log "  $([[ $DRY_RUN == 1 ]] && printf '[dry] ')remove ${target#"$MOUNT_DIR"}"
    if (( ! DRY_RUN )); then
        rm -rf -- "$target"
    fi
    deleted_targets=$((deleted_targets + 1))
done
log "matched file-cache targets: $deleted_targets"

truncate_hive_logs() {
    local hive=$1 hive_dir hive_name transaction_log
    hive_dir=$(dirname -- "$hive")
    hive_name=$(basename -- "$hive")
    while IFS= read -r -d '' transaction_log; do
        log "  clear stale transaction log ${transaction_log#"$MOUNT_DIR"}"
        : >"$transaction_log"
    done < <(
        find "$hive_dir" -maxdepth 1 -type f \
            \( -iname "${hive_name}.LOG" -o \
               -iname "${hive_name}.LOG1" -o \
               -iname "${hive_name}.LOG2" \) -print0
    )
}

if (( DO_REGISTRY )); then
    log "registry keys:"
    for index in "${!HIVE_PATHS[@]}"; do
        hive_rc=0
        HIVE_PATH="${HIVE_PATHS[$index]}" \
        KEY_PATHS="${HIVE_KEYS[$index]}" \
        HIVE_LABEL="${HIVE_LABELS[$index]}" \
        DRY_RUN="$DRY_RUN" python3 - <<'PY' || hive_rc=$?
import hivex
import os

hive_path = os.environ["HIVE_PATH"]
label = os.environ["HIVE_LABEL"]
dry_run = os.environ["DRY_RUN"] == "1"
key_paths = [item for item in os.environ["KEY_PATHS"].split("|") if item]
hive = hivex.Hivex(hive_path, write=not dry_run)


def child_casefold(parent, name):
    wanted = name.casefold()
    for candidate in hive.node_children(parent):
        if hive.node_name(candidate).casefold() == wanted:
            return candidate
    return None


deleted = 0
for key_path in key_paths:
    parent = hive.root()
    parts = [part for part in key_path.split("\\") if part]
    for part in parts[:-1]:
        parent = child_casefold(parent, part)
        if parent is None:
            break
    if parent is None:
        continue
    target = child_casefold(parent, parts[-1])
    if target is None:
        continue
    print(f"[clean-tencent]   {'[dry] ' if dry_run else ''}remove {label}\\{key_path}")
    if not dry_run:
        hive.node_delete_child(target)
        deleted += 1

if deleted:
    hive.commit(None)
del hive
raise SystemExit(0 if deleted else 3)
PY
        case "$hive_rc" in
            0)
                PYTHONDONTWRITEBYTECODE=1 python3 "$HIVE_VALIDATOR" \
                    "${HIVE_PATHS[$index]}" \
                    "${HIVE_LABELS[$index]} post-commit" >/dev/null
                # hivex may rearrange the primary hive.  Once that clean
                # commit is validated, old LOG/LOG1/LOG2 pages must not be
                # replayed against the new layout on first boot.
                truncate_hive_logs "${HIVE_PATHS[$index]}"
                ;;
            3)
                # No matching key, or a dry-run: no hive bytes changed.
                ;;
            *)
                die "hivex cleanup failed for ${HIVE_LABELS[$index]} (rc=$hive_rc)"
                ;;
        esac
    done
else
    log "registry keys: --no-registry selected"
fi

(( DRY_RUN )) || sync
umount -- "$MOUNT_DIR" || die "cleanup completed but NTFS could not be unmounted"
MOUNTED=0
if ! qemu-nbd --disconnect "$_NBD_DEV" >/dev/null; then
    die "NTFS was unmounted but NBD could not be disconnected"
fi
_NBD_CONNECTED=0
udevadm settle
qemu-img check -q "$DISK" || die "qcow2 check failed after cleanup"
CLEANUP_COMPLETE=1
if (( DRY_RUN )); then
    log "dry-run complete; no guest data changed"
else
    log "complete; clones will regenerate WeGame/Tencent identity from their own hardware"
fi
