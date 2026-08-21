#!/usr/bin/env bash
# Synchronize only the repository-managed vgpu_unlock profile tables.
#
# --check is deliberately read-only.  --apply first takes the persistent host
# lock used by the supported mdev path, then the privileged admin helper's own
# lock, and only then scans active mdevs.  Holding both through publish also
# excludes an authorized direct admin-helper invocation that bypasses the
# library's outer lock.  This script never restarts vGPU services.
set -euo pipefail

here=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
python_helper="$here/sync-vgpu-profile-override.py"
template="$here/profile_override.toml"
config=/etc/vgpu_unlock/profile_override.toml
backup_dir=/var/backups/qemu-vgpu/profile-override
action=check
action_option=

: "${MDEV_DEVICES_DIR:=/sys/bus/mdev/devices}"
: "${VGPU_HOST_LOCK_FILE:=/opt/nvidia-modes/state/current}"
: "${VGPU_MDEV_ADMIN_LOCK_FILE:=/run/lock/qemu-vgpu-mdev-admin.lock}"
: "${VGPU_HOST_LOCK_WAIT_SECONDS:=30}"

usage() {
    cat >&2 <<'EOF'
usage: sync-vgpu-profile-override.sh [--check|--apply]
       [--config FILE] [--template FILE] [--backup-dir DIR]

--check is the default and never changes the config, lock, or backup directory.
--apply refuses to run while an mdev exists and does not restart any service.
EOF
    exit 2
}

die() {
    printf 'profile override sync: %s\n' "$*" >&2
    exit 2
}

require_regular_file() {
    local path=$1 label=$2
    [[ ! -L "$path" ]] || die "$label must not be a symlink: $path"
    [[ -f "$path" ]] || die "$label is not a regular file: $path"
    [[ -r "$path" ]] || die "$label is not readable: $path"
}

while (($#)); do
    case "$1" in
        --check)
            [[ -z "$action_option" || "$action_option" == check ]] || usage
            action=check
            action_option=check
            ;;
        --apply)
            [[ -z "$action_option" || "$action_option" == apply ]] || usage
            action=apply
            action_option=apply
            ;;
        --config)
            shift
            (($#)) || usage
            config=$1
            ;;
        --template)
            shift
            (($#)) || usage
            template=$1
            ;;
        --backup-dir)
            shift
            (($#)) || usage
            backup_dir=$1
            ;;
        -h|--help)
            usage
            ;;
        *)
            usage
            ;;
    esac
    shift
done

require_regular_file "$python_helper" "Python helper"
require_regular_file "$template" "template"
require_regular_file "$config" "config"
command -v python3 >/dev/null 2>&1 || die "python3 is unavailable"

if [[ "$action" == check ]]; then
    exec python3 "$python_helper" \
        --template "$template" --config "$config" --check
fi

for command_name in flock find mktemp cp cmp mv mkdir date stat dirname rm; do
    command -v "$command_name" >/dev/null 2>&1 ||
        die "$command_name is unavailable"
done
[[ "$VGPU_HOST_LOCK_WAIT_SECONDS" =~ ^[1-9][0-9]*$ ]] ||
    die "VGPU_HOST_LOCK_WAIT_SECONDS must be a positive integer"
[[ -d "$MDEV_DEVICES_DIR" && ! -L "$MDEV_DEVICES_DIR" ]] ||
    die "mdev devices directory is missing or unsafe: $MDEV_DEVICES_DIR"
require_regular_file "$VGPU_HOST_LOCK_FILE" "vGPU host lock"

# Opening the existing lock read-only neither creates nor truncates it.
exec {host_lock_fd}<"$VGPU_HOST_LOCK_FILE" ||
    die "cannot open vGPU host lock: $VGPU_HOST_LOCK_FILE"
flock -x -w "$VGPU_HOST_LOCK_WAIT_SECONDS" "$host_lock_fd" ||
    die "timed out waiting for vGPU host lock: $VGPU_HOST_LOCK_FILE"

# Direct sudo-authorized vgpu-mdev-admin calls take their own /run lock without
# the library's outer host lock.  Acquire it second, in a single documented
# order, so neither those calls nor the supported host->admin path can race the
# semantic merge.  A missing inode is normal before the helper's first use, but
# only an already-existing, non-symlink, traversable/writable parent may host a
# new lock.  O_EXCL|O_NOFOLLOW prevents a concurrent symlink substitution.
admin_lock_dir=$(dirname -- "$VGPU_MDEV_ADMIN_LOCK_FILE")
if [[ ! -e "$VGPU_MDEV_ADMIN_LOCK_FILE" &&
      ! -L "$VGPU_MDEV_ADMIN_LOCK_FILE" ]]; then
    [[ -d "$admin_lock_dir" && ! -L "$admin_lock_dir" &&
       -r "$admin_lock_dir" && -w "$admin_lock_dir" &&
       -x "$admin_lock_dir" ]] ||
        die "admin lock parent directory is missing or unsafe: $admin_lock_dir"
    create_admin_lock_rc=0
    python3 - "$VGPU_MDEV_ADMIN_LOCK_FILE" <<'PY' || create_admin_lock_rc=$?
import os
import sys

path = sys.argv[1]
flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
flags |= getattr(os, "O_NOFOLLOW", 0)
try:
    fd = os.open(path, flags, 0o600)
except FileExistsError:
    raise SystemExit(10)
except OSError as exc:
    print(f"profile override sync: cannot create admin lock {path}: {exc}", file=sys.stderr)
    raise SystemExit(11)
else:
    os.close(fd)
PY
    case "$create_admin_lock_rc" in
        0|10) ;;
        *) die "cannot safely create admin lock: $VGPU_MDEV_ADMIN_LOCK_FILE" ;;
    esac
fi
require_regular_file "$VGPU_MDEV_ADMIN_LOCK_FILE" "vGPU mdev admin lock"
exec {admin_lock_fd}<"$VGPU_MDEV_ADMIN_LOCK_FILE" ||
    die "cannot open vGPU mdev admin lock: $VGPU_MDEV_ADMIN_LOCK_FILE"
[[ "$VGPU_MDEV_ADMIN_LOCK_FILE" -ef "/proc/self/fd/$admin_lock_fd" ]] ||
    die "vGPU mdev admin lock changed while opening: $VGPU_MDEV_ADMIN_LOCK_FILE"
flock -x -w "$VGPU_HOST_LOCK_WAIT_SECONDS" "$admin_lock_fd" ||
    die "timed out waiting for vGPU mdev admin lock: $VGPU_MDEV_ADMIN_LOCK_FILE"

# Both supported library mutations and direct admin-helper mutations are now
# excluded.  Checking only here closes the active-scan-to-publish race.
if ! active_mdev=$(find "$MDEV_DEVICES_DIR" -mindepth 1 -maxdepth 1 \
        -print -quit); then
    die "cannot enumerate mdev devices directory: $MDEV_DEVICES_DIR"
fi
if [[ -n "$active_mdev" ]]; then
    die "active mdev exists; stop its VM and remove the mdev before --apply"
fi

# Revalidate mutable inputs after waiting for the host lock.
require_regular_file "$template" "template"
require_regular_file "$config" "config"

check_rc=0
python3 "$python_helper" \
    --template "$template" --config "$config" --check || check_rc=$?
case "$check_rc" in
    0)
        printf 'profile override is already synchronized; no backup was created\n'
        exit 0
        ;;
    1)
        ;;
    *)
        exit "$check_rc"
        ;;
esac

config_dir=$(dirname -- "$config")
[[ -d "$config_dir" && ! -L "$config_dir" ]] ||
    die "config directory is missing or unsafe: $config_dir"

stage=
rollback_stage=
backup_path=
backup_stage=
published=0
cleanup() {
    local status=$?
    [[ -z "$stage" || ! -e "$stage" ]] || rm -f -- "$stage"
    [[ -z "$rollback_stage" || ! -e "$rollback_stage" ]] ||
        rm -f -- "$rollback_stage"
    [[ -z "$backup_stage" || ! -e "$backup_stage" ]] ||
        rm -f -- "$backup_stage"
    if ((status != 0 && published)); then
        printf 'profile override sync: apply failed after publish; backup retained at %s\n' \
            "$backup_path" >&2
    fi
    exit "$status"
}
trap cleanup EXIT

umask 077
stage=$(mktemp --tmpdir="$config_dir" .profile_override.toml.sync.XXXXXX)
# Copy attributes before rewriting the hidden stage.  Truncating an existing
# regular file preserves its ACLs/xattrs while the content and mtime change.
cp -a -- "$config" "$stage"
python3 "$python_helper" \
    --template "$template" --config "$config" --output "$stage"

config_identity=$(stat -c '%u:%g:%a' -- "$config")
stage_identity=$(stat -c '%u:%g:%a' -- "$stage")
[[ "$stage_identity" == "$config_identity" ]] ||
    die "staged config ownership or mode differs from the live config"
python3 "$python_helper" \
    --template "$template" --config "$stage" --check

if [[ -e "$backup_dir" || -L "$backup_dir" ]]; then
    [[ -d "$backup_dir" && ! -L "$backup_dir" ]] ||
        die "backup directory is not a safe directory: $backup_dir"
else
    mkdir -p -m 0700 -- "$backup_dir"
fi
[[ -d "$backup_dir" && ! -L "$backup_dir" ]] ||
    die "backup directory is missing or unsafe: $backup_dir"

backup_stage=$(mktemp --tmpdir="$backup_dir" \
    ".profile_override.toml.$(date -u +%Y%m%dT%H%M%SZ).$$.XXXXXX.tmp")
backup_path="${backup_stage%.tmp}.bak"
cp -a -- "$config" "$backup_stage"
cmp -s -- "$config" "$backup_stage" ||
    die "backup verification failed: $backup_stage"
mv -fT -- "$backup_stage" "$backup_path"
backup_stage=

# stage and config share a directory, so rename(2) is the atomic commit point.
mv -fT -- "$stage" "$config"
stage=
published=1

postcheck_rc=0
python3 "$python_helper" \
    --template "$template" --config "$config" --check || postcheck_rc=$?
if ((postcheck_rc != 0)); then
    rollback_stage=$(mktemp --tmpdir="$config_dir" \
        .profile_override.toml.rollback.XXXXXX)
    cp -a -- "$backup_path" "$rollback_stage"
    mv -fT -- "$rollback_stage" "$config"
    rollback_stage=
    published=0
    die "post-publish validation failed; the original config was restored"
fi

printf 'profile override synchronized; backup: %s\n' "$backup_path"
