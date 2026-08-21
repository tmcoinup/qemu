#!/usr/bin/env bash
# Regression coverage for semantic profile_override synchronization.
# Every --apply invocation below targets a temporary fake host; /etc and the
# real mdev sysfs tree are never passed to the wrapper.
set -euo pipefail

SCRIPT_DIR=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -P -- "$SCRIPT_DIR/../../.." && pwd)
PY_HELPER="$REPO_ROOT/deploy/host/sync-vgpu-profile-override.py"
WRAPPER="$REPO_ROOT/deploy/host/sync-vgpu-profile-override.sh"
TEMPLATE="$REPO_ROOT/deploy/host/profile_override.toml"
TMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TMP_DIR"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

expect_status() {
    local expected=$1
    shift
    local output="$TMP_DIR/command-output.$$.${expect_counter}"
    local actual
    expect_counter=$((expect_counter + 1))
    last_expect_output=$output
    set +e
    "$@" >"$output" 2>&1
    actual=$?
    set -e
    [[ "$actual" == "$expected" ]] || {
        sed -n '1,160p' "$output" >&2
        fail "expected exit $expected, got $actual: $*"
    }
}

file_hash() {
    sha256sum "$1" | awk '{print $1}'
}

backup_count() {
    local directory=$1
    if [[ ! -d "$directory" ]]; then
        printf '0\n'
        return
    fi
    find "$directory" -maxdepth 1 -type f -name '*.bak' | wc -l
}

assert_synced_and_preserved() {
    local original=$1 candidate=$2
    python3 - "$TEMPLATE" "$original" "$candidate" <<'PY'
import copy
import pathlib
import sys
import tomllib

managed = ("nvidia-256", "nvidia-257")


def load(path):
    return tomllib.loads(pathlib.Path(path).read_text(encoding="utf-8"))


def unmanaged(document):
    projected = copy.deepcopy(document)
    profiles = projected.get("profile")
    if isinstance(profiles, dict):
        for key in managed:
            profiles.pop(key, None)
    return projected


template, original, candidate = map(load, sys.argv[1:])
for key in managed:
    assert candidate["profile"][key] == template["profile"][key], key
assert unmanaged(candidate) == unmanaged(original)
assert candidate.get("mdev") == original.get("mdev")
PY
}

host_apply() {
    local apply_config=$1 apply_backup=$2 apply_devices=$3 apply_lock=$4
    local apply_admin_lock=$5
    env MDEV_DEVICES_DIR="$apply_devices" \
        VGPU_HOST_LOCK_FILE="$apply_lock" \
        VGPU_MDEV_ADMIN_LOCK_FILE="$apply_admin_lock" \
        VGPU_HOST_LOCK_WAIT_SECONDS=2 \
        "$WRAPPER" --apply --config "$apply_config" \
        --template "$TEMPLATE" --backup-dir "$apply_backup"
}

command -v python3 >/dev/null 2>&1 || fail 'python3 is unavailable'
command -v sha256sum >/dev/null 2>&1 || fail 'sha256sum is unavailable'
expect_counter=0

ORIGINAL="$TMP_DIR/original.toml"
cat >"$ORIGINAL" <<'EOF'
schema = 7
site_name = "keep this root value"

[custom.runtime]
enabled = true
labels = ["alpha", "beta"]

# Deliberately stale and incomplete: nvidia-256 is absent.
[profile.nvidia-257]
num_displays = 4
display_width = 2560
display_height = 1600
max_pixels = 4096000
framebuffer = 0x80000000
framebuffer_reservation = 0x10000000

[profile.nvidia-999]
unknown_driver_field = 12345
unknown_name = "must survive"

[mdev."11111111-2222-3333-4444-555555555555"]
card_name = "VM One"
adapter_name = "VM One"
display_width = 1920

[mdev."11111111-2222-3333-4444-555555555555".identity]
rm_fb_bus_width = 128
rm_fb_ram_type = 8

[mdev."aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"]
card_name = "VM Two"
adapter_name = "VM Two"
custom_mdev_field = "preserve me"
EOF

PYTHONPYCACHEPREFIX="$TMP_DIR/pycache" python3 -m py_compile "$PY_HELPER"
bash -n "$WRAPPER" "$BASH_SOURCE"

# Direct check reports semantic drift (1) and does not touch the input.
CHECK_CONFIG="$TMP_DIR/check.toml"
cp "$ORIGINAL" "$CHECK_CONFIG"
before=$(file_hash "$CHECK_CONFIG")
expect_status 1 python3 "$PY_HELPER" --template "$TEMPLATE" \
    --config "$CHECK_CONFIG" --check
[[ "$(file_hash "$CHECK_CONFIG")" == "$before" ]] ||
    fail 'Python --check modified the config'

# Render replaces only the two managed profiles. Unknown profiles and every
# per-mdev value remain semantically identical, and a second render is stable.
RENDERED="$TMP_DIR/rendered.toml"
RENDERED_AGAIN="$TMP_DIR/rendered-again.toml"
python3 "$PY_HELPER" --template "$TEMPLATE" --config "$CHECK_CONFIG" \
    --output "$RENDERED" >/dev/null
python3 "$PY_HELPER" --template "$TEMPLATE" --config "$RENDERED" \
    --check >/dev/null
assert_synced_and_preserved "$ORIGINAL" "$RENDERED"
python3 "$PY_HELPER" --template "$TEMPLATE" --config "$RENDERED" \
    --output "$RENDERED_AGAIN" >/dev/null
cmp -s "$RENDERED" "$RENDERED_AGAIN" ||
    fail 'semantic rendering is not byte-idempotent'

# Wrapper check is also read-only: it neither needs nor creates the host lock,
# mdev tree, or backup directory.
WRAPPER_CHECK="$TMP_DIR/wrapper-check.toml"
CHECK_BACKUPS="$TMP_DIR/check-backups"
CHECK_HOST_LOCK="$TMP_DIR/check-locks/host.lock"
CHECK_ADMIN_LOCK="$TMP_DIR/check-locks/admin.lock"
cp "$ORIGINAL" "$WRAPPER_CHECK"
before=$(file_hash "$WRAPPER_CHECK")
expect_status 1 env VGPU_HOST_LOCK_FILE="$CHECK_HOST_LOCK" \
    VGPU_MDEV_ADMIN_LOCK_FILE="$CHECK_ADMIN_LOCK" \
    MDEV_DEVICES_DIR="$TMP_DIR/check-mdev-devices" \
    "$WRAPPER" --config "$WRAPPER_CHECK" \
    --template "$TEMPLATE" --backup-dir "$CHECK_BACKUPS"
[[ "$(file_hash "$WRAPPER_CHECK")" == "$before" ]] ||
    fail 'wrapper --check modified the config'
[[ ! -e "$CHECK_BACKUPS" ]] || fail 'wrapper --check created a backup directory'
[[ ! -e "$CHECK_HOST_LOCK" && ! -L "$CHECK_HOST_LOCK" &&
   ! -e "$CHECK_ADMIN_LOCK" && ! -L "$CHECK_ADMIN_LOCK" ]] ||
    fail 'wrapper --check touched a host or admin lock'
[[ ! -e "$TMP_DIR/check-locks" && ! -e "$TMP_DIR/check-mdev-devices" ]] ||
    fail 'wrapper --check created a lock parent or mdev directory'

# Apply against an empty fake mdev host: exact backup, preserved mode, atomic
# replacement, and no second backup for an already-synchronized file.
DEVICES="$TMP_DIR/fake-host/mdev/devices"
LOCK="$TMP_DIR/fake-host/state/current"
ADMIN_LOCK="$TMP_DIR/fake-host/run/qemu-vgpu-mdev-admin.lock"
APPLY_CONFIG="$TMP_DIR/apply/profile_override.toml"
APPLY_BACKUPS="$TMP_DIR/apply/backups"
mkdir -p "$DEVICES" "$(dirname "$LOCK")" "$(dirname "$ADMIN_LOCK")" \
    "$(dirname "$APPLY_CONFIG")"
printf 'vgpu\n' >"$LOCK"
cp "$ORIGINAL" "$APPLY_CONFIG"
chmod 0640 "$APPLY_CONFIG"
host_apply "$APPLY_CONFIG" "$APPLY_BACKUPS" "$DEVICES" "$LOCK" \
    "$ADMIN_LOCK" >/dev/null
[[ -f "$ADMIN_LOCK" && ! -L "$ADMIN_LOCK" ]] ||
    fail 'apply did not safely create the missing admin lock inode'
[[ "$(backup_count "$APPLY_BACKUPS")" == 1 ]] ||
    fail 'successful apply did not create exactly one backup'
BACKUP=$(find "$APPLY_BACKUPS" -maxdepth 1 -type f -name '*.bak' -print -quit)
cmp -s "$ORIGINAL" "$BACKUP" || fail 'backup is not the exact pre-apply file'
[[ "$(stat -c '%a' "$APPLY_CONFIG")" == 640 ]] ||
    fail 'apply did not preserve config mode'
assert_synced_and_preserved "$ORIGINAL" "$APPLY_CONFIG"
python3 "$PY_HELPER" --template "$TEMPLATE" --config "$APPLY_CONFIG" \
    --check >/dev/null
host_apply "$APPLY_CONFIG" "$APPLY_BACKUPS" "$DEVICES" "$LOCK" \
    "$ADMIN_LOCK" >/dev/null
[[ "$(backup_count "$APPLY_BACKUPS")" == 1 ]] ||
    fail 'no-op apply created a redundant backup'

# A direct privileged helper holds this lock without the library host lock.
# Apply must wait on it after taking the host lock and publish nothing.
ADMIN_BUSY_CONFIG="$TMP_DIR/admin-busy/profile_override.toml"
ADMIN_BUSY_BACKUPS="$TMP_DIR/admin-busy/backups"
mkdir -p "$(dirname "$ADMIN_BUSY_CONFIG")"
cp "$ORIGINAL" "$ADMIN_BUSY_CONFIG"
before=$(file_hash "$ADMIN_BUSY_CONFIG")
exec 7<"$ADMIN_LOCK"
flock -x 7
expect_status 2 host_apply "$ADMIN_BUSY_CONFIG" "$ADMIN_BUSY_BACKUPS" \
    "$DEVICES" "$LOCK" "$ADMIN_LOCK"
flock -u 7
exec 7<&-
grep -Fq 'timed out waiting for vGPU mdev admin lock' \
    "$last_expect_output" ||
    fail 'admin-lock contention did not fail at the admin lock'
[[ "$(file_hash "$ADMIN_BUSY_CONFIG")" == "$before" ]] ||
    fail 'admin-lock contention modified the config'
[[ ! -e "$ADMIN_BUSY_BACKUPS" ]] ||
    fail 'admin-lock contention created backups'

# Existing symlink lock paths are never the missing-lock bootstrap case.
ADMIN_LINK="$TMP_DIR/fake-host/run/admin-link.lock"
ADMIN_LINK_CONFIG="$TMP_DIR/admin-link/profile_override.toml"
ADMIN_LINK_BACKUPS="$TMP_DIR/admin-link/backups"
ln -s "$ADMIN_LOCK" "$ADMIN_LINK"
mkdir -p "$(dirname "$ADMIN_LINK_CONFIG")"
cp "$ORIGINAL" "$ADMIN_LINK_CONFIG"
before=$(file_hash "$ADMIN_LINK_CONFIG")
admin_lock_before=$(file_hash "$ADMIN_LOCK")
expect_status 2 host_apply "$ADMIN_LINK_CONFIG" "$ADMIN_LINK_BACKUPS" \
    "$DEVICES" "$LOCK" "$ADMIN_LINK"
grep -Fq 'vGPU mdev admin lock must not be a symlink' \
    "$last_expect_output" ||
    fail 'admin lock symlink refusal was not clear'
[[ "$(file_hash "$ADMIN_LINK_CONFIG")" == "$before" ]] ||
    fail 'admin lock symlink rejection modified the config'
[[ "$(file_hash "$ADMIN_LOCK")" == "$admin_lock_before" ]] ||
    fail 'admin lock symlink rejection modified its target'
[[ ! -e "$ADMIN_LINK_BACKUPS" ]] ||
    fail 'admin lock symlink rejection created backups'

# Missing admin locks are created only inside an already-safe parent; apply
# must not manufacture an arbitrary parent path.
MISSING_PARENT_CONFIG="$TMP_DIR/admin-missing-parent/profile_override.toml"
MISSING_PARENT_BACKUPS="$TMP_DIR/admin-missing-parent/backups"
MISSING_PARENT_LOCK="$TMP_DIR/no-admin-parent/admin.lock"
mkdir -p "$(dirname "$MISSING_PARENT_CONFIG")"
cp "$ORIGINAL" "$MISSING_PARENT_CONFIG"
before=$(file_hash "$MISSING_PARENT_CONFIG")
expect_status 2 host_apply "$MISSING_PARENT_CONFIG" \
    "$MISSING_PARENT_BACKUPS" "$DEVICES" "$LOCK" "$MISSING_PARENT_LOCK"
grep -Fq 'admin lock parent directory is missing or unsafe' \
    "$last_expect_output" ||
    fail 'missing admin lock parent refusal was not clear'
[[ "$(file_hash "$MISSING_PARENT_CONFIG")" == "$before" ]] ||
    fail 'missing admin-lock parent rejection modified the config'
[[ ! -e "$(dirname "$MISSING_PARENT_LOCK")" ]] ||
    fail 'apply created an unsafe missing admin-lock parent'

# Any entry in the locked mdev directory blocks apply before backup or publish.
ACTIVE_CONFIG="$TMP_DIR/active/profile_override.toml"
ACTIVE_BACKUPS="$TMP_DIR/active/backups"
mkdir -p "$(dirname "$ACTIVE_CONFIG")" "$TMP_DIR/fake-mdev-target"
cp "$ORIGINAL" "$ACTIVE_CONFIG"
ln -s "$TMP_DIR/fake-mdev-target" \
    "$DEVICES/99999999-8888-7777-6666-555555555555"
before=$(file_hash "$ACTIVE_CONFIG")
lock_before=$(file_hash "$LOCK")
expect_status 2 host_apply "$ACTIVE_CONFIG" "$ACTIVE_BACKUPS" \
    "$DEVICES" "$LOCK" "$ADMIN_LOCK"
[[ "$(file_hash "$ACTIVE_CONFIG")" == "$before" ]] ||
    fail 'active-mdev rejection modified the config'
[[ "$(file_hash "$LOCK")" == "$lock_before" ]] ||
    fail 'apply modified the persistent host lock file'
[[ ! -e "$ACTIVE_BACKUPS" ]] ||
    fail 'active-mdev rejection created a backup directory'
rm "$DEVICES/99999999-8888-7777-6666-555555555555"

# A config or output symlink is rejected without changing its target.
SYMLINK_TARGET="$TMP_DIR/symlink-target.toml"
SYMLINK_CONFIG="$TMP_DIR/symlink-config.toml"
cp "$ORIGINAL" "$SYMLINK_TARGET"
ln -s "$SYMLINK_TARGET" "$SYMLINK_CONFIG"
before=$(file_hash "$SYMLINK_TARGET")
expect_status 2 "$WRAPPER" --check --config "$SYMLINK_CONFIG" \
    --template "$TEMPLATE" --backup-dir "$TMP_DIR/symlink-backups"
expect_status 2 host_apply "$SYMLINK_CONFIG" "$TMP_DIR/symlink-backups" \
    "$DEVICES" "$LOCK" "$ADMIN_LOCK"
[[ "$(file_hash "$SYMLINK_TARGET")" == "$before" ]] ||
    fail 'config symlink rejection modified its target'
[[ ! -e "$TMP_DIR/symlink-backups" ]] ||
    fail 'config symlink rejection created backups'

OUTPUT_TARGET="$TMP_DIR/output-target.toml"
OUTPUT_LINK="$TMP_DIR/output-link.toml"
printf 'sentinel\n' >"$OUTPUT_TARGET"
ln -s "$OUTPUT_TARGET" "$OUTPUT_LINK"
before=$(file_hash "$OUTPUT_TARGET")
expect_status 2 python3 "$PY_HELPER" --template "$TEMPLATE" \
    --config "$ORIGINAL" --output "$OUTPUT_LINK"
[[ "$(file_hash "$OUTPUT_TARGET")" == "$before" ]] ||
    fail 'output symlink rejection modified its target'

# A symlink used as the backup directory is also rejected before publishing.
BACKUP_LINK_CONFIG="$TMP_DIR/backup-link-config.toml"
BACKUP_TARGET="$TMP_DIR/backup-target"
BACKUP_LINK="$TMP_DIR/backup-link"
mkdir "$BACKUP_TARGET"
ln -s "$BACKUP_TARGET" "$BACKUP_LINK"
cp "$ORIGINAL" "$BACKUP_LINK_CONFIG"
before=$(file_hash "$BACKUP_LINK_CONFIG")
expect_status 2 host_apply "$BACKUP_LINK_CONFIG" "$BACKUP_LINK" \
    "$DEVICES" "$LOCK" "$ADMIN_LOCK"
[[ "$(file_hash "$BACKUP_LINK_CONFIG")" == "$before" ]] ||
    fail 'unsafe backup-directory rejection published the config'
[[ -z "$(find "$BACKUP_TARGET" -mindepth 1 -print -quit)" ]] ||
    fail 'unsafe backup-directory rejection wrote through its symlink'

# Malformed or surgically unlocatable TOML fails closed. A template containing
# runtime mdev state can never be used as the canonical source.
MALFORMED="$TMP_DIR/malformed.toml"
UNSUPPORTED="$TMP_DIR/unsupported.toml"
BAD_TEMPLATE="$TMP_DIR/bad-template.toml"
BAD_ROOT_TEMPLATE="$TMP_DIR/bad-root-template.toml"
BAD_PROFILE_TEMPLATE="$TMP_DIR/bad-profile-template.toml"
printf '[profile.nvidia-257\nvalue = 1\n' >"$MALFORMED"
cat >"$UNSUPPORTED" <<'EOF'
[profile."nvidia-257"]
num_displays = 4

[mdev."12345678-1234-1234-1234-123456789abc"]
card_name = "preserve"
EOF
cp "$TEMPLATE" "$BAD_TEMPLATE"
cat >>"$BAD_TEMPLATE" <<'EOF'

[mdev."12345678-1234-1234-1234-123456789abc"]
card_name = "template must not own runtime state"
EOF
cp "$TEMPLATE" "$BAD_ROOT_TEMPLATE"
cat >>"$BAD_ROOT_TEMPLATE" <<'EOF'

[unexpected_template_root]
enabled = true
EOF
cp "$TEMPLATE" "$BAD_PROFILE_TEMPLATE"
cat >>"$BAD_PROFILE_TEMPLATE" <<'EOF'

[profile.nvidia-999]
unknown_driver_field = 1
EOF
expect_status 2 python3 "$PY_HELPER" --template "$TEMPLATE" \
    --config "$MALFORMED" --output "$TMP_DIR/malformed-output.toml"
[[ ! -e "$TMP_DIR/malformed-output.toml" ]] ||
    fail 'malformed input produced an output file'
expect_status 2 python3 "$PY_HELPER" --template "$TEMPLATE" \
    --config "$UNSUPPORTED" --output "$TMP_DIR/unsupported-output.toml"
[[ ! -e "$TMP_DIR/unsupported-output.toml" ]] ||
    fail 'unsupported managed header was duplicated into an output file'
expect_status 2 python3 "$PY_HELPER" --template "$BAD_TEMPLATE" \
    --config "$ORIGINAL" --output "$TMP_DIR/bad-template-output.toml"
[[ ! -e "$TMP_DIR/bad-template-output.toml" ]] ||
    fail 'template runtime state produced an output file'
expect_status 2 python3 "$PY_HELPER" --template "$BAD_ROOT_TEMPLATE" \
    --config "$ORIGINAL" --output "$TMP_DIR/bad-root-output.toml"
[[ ! -e "$TMP_DIR/bad-root-output.toml" ]] ||
    fail 'unexpected template root produced an output file'
expect_status 2 python3 "$PY_HELPER" --template "$BAD_PROFILE_TEMPLATE" \
    --config "$ORIGINAL" --output "$TMP_DIR/bad-profile-output.toml"
[[ ! -e "$TMP_DIR/bad-profile-output.toml" ]] ||
    fail 'unexpected template profile produced an output file'

# Simulate failure at the atomic commit rename. The verified backup remains,
# while the original live path and contents are untouched.
FAIL_CONFIG="$TMP_DIR/rename-failure/profile_override.toml"
FAIL_BACKUPS="$TMP_DIR/rename-failure/backups"
FAKE_BIN="$TMP_DIR/fake-bin"
REAL_MV=$(command -v mv)
mkdir -p "$(dirname "$FAIL_CONFIG")" "$FAKE_BIN"
cp "$ORIGINAL" "$FAIL_CONFIG"
cat >"$FAKE_BIN/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
last=
for argument in "$@"; do
    last=$argument
done
if [[ "$last" == "${SYNC_TEST_FAIL_DEST:?}" ]]; then
    exit 23
fi
exec "${SYNC_TEST_REAL_MV:?}" "$@"
EOF
chmod +x "$FAKE_BIN/mv"
before=$(file_hash "$FAIL_CONFIG")
expect_status 23 env PATH="$FAKE_BIN:$PATH" \
    SYNC_TEST_FAIL_DEST="$FAIL_CONFIG" SYNC_TEST_REAL_MV="$REAL_MV" \
    MDEV_DEVICES_DIR="$DEVICES" VGPU_HOST_LOCK_FILE="$LOCK" \
    VGPU_MDEV_ADMIN_LOCK_FILE="$ADMIN_LOCK" \
    VGPU_HOST_LOCK_WAIT_SECONDS=2 "$WRAPPER" --apply \
    --config "$FAIL_CONFIG" --template "$TEMPLATE" \
    --backup-dir "$FAIL_BACKUPS"
[[ "$(file_hash "$FAIL_CONFIG")" == "$before" ]] ||
    fail 'failed atomic rename changed the live config'
[[ "$(backup_count "$FAIL_BACKUPS")" == 1 ]] ||
    fail 'failed publish did not retain its verified backup'
FAIL_BACKUP=$(find "$FAIL_BACKUPS" -maxdepth 1 -type f -name '*.bak' -print -quit)
cmp -s "$ORIGINAL" "$FAIL_BACKUP" ||
    fail 'failed-publish backup does not match the original'

if grep -Eq '(^|[[:space:]])(systemctl|service)[[:space:]]' "$WRAPPER"; then
    fail 'profile synchronization wrapper unexpectedly manages services'
fi

echo 'PASS: profile_override sync is semantic, conservative, and atomic'
