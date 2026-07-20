#!/usr/bin/env bash
# 验证 clone 对 UI 预写 profile 与实例目录执行精确 owner/mode 收尾。
# shellcheck disable=SC1090,SC1091
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
LIFECYCLE="$REPO_ROOT/deploy/scripts/lib/clone-lifecycle.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

source "$LIFECYCLE"

# helper 只需要 sudo -u USER -- COMMAND；测试以当前非 root 用户模拟最终 VM 用户。
FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == -u && "${3:-}" == -- ]] || exit 90
shift 3
exec "$@"
EOF
chmod 0755 "$FAKE_BIN/sudo"

ORIG_USER="$(id -un)"
ORIG_UID="$(id -u)"
ORIG_GID="$(id -g)"
VMS_DIR="$TMP_DIR/vms"
VM_DIR="$VMS_DIR/81"
DISK="$VM_DIR/disk.qcow2"
PROFILE="$VM_DIR/profile"
OVMF="$VM_DIR/ovmf-vars.fd"

mkdir -p "$VM_DIR"
chmod 0755 "$VM_DIR"
printf 'ui-profile\n' >"$PROFILE"
chmod 0644 "$PROFILE"
PATH="$FAKE_BIN:$PATH" clone_lifecycle_prepare_instance_dir \
    "$ORIG_USER" "$ORIG_UID" "$ORIG_GID" \
    "$VMS_DIR" "$VM_DIR" "$DISK" "$PROFILE" "$OVMF"
[[ "$(stat -c '%a' -- "$VM_DIR")" == 700 ]] ||
    fail "prepare 未在 staging 前把已有 VM_DIR 收紧到 0700"

printf 'overlay\n' >"$DISK"
printf 'nvram\n' >"$OVMF"
chmod 0644 "$DISK" "$PROFILE" "$OVMF"
clone_lifecycle_assign_output_ownership \
    "$ORIG_UID" "$ORIG_GID" 0 none \
    "$VM_DIR" "$DISK" "$PROFILE" "$OVMF"
[[ "$(stat -c '%u:%g:%a' -- "$VM_DIR")" == "$ORIG_UID:$ORIG_GID:700" ]] ||
    fail "复用目录未满足 owner/0700 提交后置条件"
for path in "$DISK" "$PROFILE" "$OVMF"; do
    [[ "$(stat -c '%u:%g:%a' -- "$path")" == "$ORIG_UID:$ORIG_GID:600" ]] ||
        fail "clone 输出未满足 owner/0600 后置条件: $path"
done

ln "$PROFILE" "$TMP_DIR/profile-hardlink"
if PATH="$FAKE_BIN:$PATH" clone_lifecycle_prepare_instance_dir \
        "$ORIG_USER" "$ORIG_UID" "$ORIG_GID" \
        "$VMS_DIR" "$VM_DIR" "$TMP_DIR/new-disk" "$PROFILE" "$TMP_DIR/new-ovmf" \
        >/dev/null 2>&1; then
    fail "存在外部硬链接的 UI profile 被 clone 接管"
fi

echo "OK: clone output ownership and permissions passed"
