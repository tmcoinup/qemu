#!/usr/bin/env bash
# 验证 finalize 两次 sudo 边界会显式保留受支持的环境，并把 clone 创建参数原样
# 交给 start-vm；同时确保离线修复绝不改写共享 base pin 的 owner/inode。
# shellcheck disable=SC2016
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
FINALIZE="$REPO_ROOT/deploy/scripts/finalize-clone-gpu.sh"
HOST_FIX="$REPO_ROOT/deploy/scripts/host-fix-gpu-devpkey.sh"
HIVE_PATCHER="$REPO_ROOT/deploy/scripts/lib/devpkey-patch.py"
PACKAGE_HELPER="$REPO_ROOT/deploy/scripts/lib/signed-driver-package.py"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

FIXTURE_DIR="$TMP_DIR/finalize fixture"
FAKE_BIN="$TMP_DIR/fake-bin"
CUSTOM_IMAGE_ROOT="$TMP_DIR/custom images"
CUSTOM_VMS_DIR="$CUSTOM_IMAGE_ROOT/private vms"
BASE_REPOSITORY="$CUSTOM_VMS_DIR/base repository.qcow2"
INSTANCE=812345
TEST_OUT="$TMP_DIR/result"
mkdir -p "$FIXTURE_DIR" "$FAKE_BIN" \
    "$CUSTOM_VMS_DIR/$INSTANCE" "$TEST_OUT"
export TEST_OUT

# clone 的实例 pin 与 base 仓库共享 inode。测试用户无法创建 root-owned 文件，
# 但共享硬链接足以验证 finalizer 完全不应尝试递归改变实例目录 owner。
printf 'sealed base fixture\n' >"$BASE_REPOSITORY"
chmod 0444 "$BASE_REPOSITORY"
ln "$BASE_REPOSITORY" "$CUSTOM_VMS_DIR/$INSTANCE/.base.qcow2"
BASE_INODE_BEFORE="$(stat -c '%d:%i:%u:%g:%a' "$BASE_REPOSITORY")"

# 保留生产脚本全部 root 分支，只把当前非 root 测试进程会走的提权入口禁用。
sed 's/^if \[\[ \$EUID -ne 0 \]\]; then$/if false; then/' \
    "$FINALIZE" >"$FIXTURE_DIR/finalize-clone-gpu.sh"
chmod +x "$FIXTURE_DIR/finalize-clone-gpu.sh"
sed 's/^if \[\[ \$EUID -ne 0 \]\]; then$/if [[ "${FINALIZE_TEST_ROOT:-0}" != 1 ]]; then/' \
    "$FINALIZE" >"$FIXTURE_DIR/finalize-elevation.sh"
chmod +x "$FIXTURE_DIR/finalize-elevation.sh"

cat >"$FIXTURE_DIR/host-fix-gpu-devpkey.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"$TEST_OUT/fix.args"
printf '%s' "${VMS_DIR:-}" >"$TEST_OUT/fix.vms-dir"
printf '%s' "${QEMU_IMG:-}" >"$TEST_OUT/fix.qemu-img"
printf '%s' "${DISK:-}" >"$TEST_OUT/fix.disk"
printf '%s' "${NBD:-}" >"$TEST_OUT/fix.nbd"
printf '%s' "${MOUNT:-}" >"$TEST_OUT/fix.mount"
printf '%s' "${PROVIDER:-}" >"$TEST_OUT/fix.provider"
printf '%s' "${DEVICE_DESC:-}" >"$TEST_OUT/fix.device-desc"
printf '%s' "${SUBSYS_RE:-}" >"$TEST_OUT/fix.subsys-re"
EOF
chmod +x "$FIXTURE_DIR/host-fix-gpu-devpkey.sh"

cat >"$FIXTURE_DIR/start-vm.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s' "${VMS_DIR:-}" >"$TEST_OUT/vms-dir"
printf '%s' "${IMAGE_ROOT:-}" >"$TEST_OUT/image-root"
printf '%s' "${QEMU_IMG:-}" >"$TEST_OUT/qemu-img"
printf '%s\0' "$@" >"$TEST_OUT/start.args"
EOF
chmod +x "$FIXTURE_DIR/start-vm.sh"

# 当前测试用户不能真正 sudo。第一次调用模拟提权重执行并注入测试专用 root 标记；
# 第二次调用模拟 `sudo -u USER env ...`，覆盖降权启动的真实参数边界。
cat >"$FAKE_BIN/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == -- && "${2:-}" == /usr/bin/env ]]; then
    printf '%s\0' "$@" >"$TEST_OUT/elevation.args"
    shift 2
    exec /usr/bin/env FINALIZE_TEST_ROOT=1 \
        SUDO_USER="$TEST_INVOKING_USER" "$@"
fi
if [[ "${1:-}" == -u && "${3:-}" == env ]]; then
    printf '%s' "$2" >"$TEST_OUT/sudo-user"
    shift 2
    exec "$@"
fi
exit 90
EOF
chmod +x "$FAKE_BIN/sudo"

# 旧实现会执行 `chown -R VM_DIR` 并吞掉错误。替身把任何 chown 记录下来，确保
# 回归测试能直接捕获对共享 base pin 的 owner 修改企图。
cat >"$FAKE_BIN/chown" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\0' "$@" >"$TEST_OUT/chown.args"
EOF
chmod +x "$FAKE_BIN/chown"

QEMU_WITH_SPACE="$TMP_DIR/qemu build/qemu-system-x86_64"
CUSTOM_QEMU_IMG="$TMP_DIR/qemu build/qemu-img"
CUSTOM_DISK="$CUSTOM_VMS_DIR/$INSTANCE/disk override.qcow2"
CUSTOM_MOUNT="$TMP_DIR/mount with spaces"
TEST_INVOKING_USER="$(id -un)"
export TEST_INVOKING_USER

# 先覆盖普通用户到 root 的第一次重执行；sudoers 即使禁止 -E，白名单变量也必须
# 作为 env argv 明确传入。host-fix 替身记录它实际收到的值。
PATH="$FAKE_BIN:$PATH" \
VMS_DIR="$CUSTOM_VMS_DIR" \
IMAGE_ROOT="$CUSTOM_IMAGE_ROOT" \
QEMU_IMG="$CUSTOM_QEMU_IMG" \
DISPLAY=:77 \
STABLE_DISPLAY=1 \
HOST_RESERVE_CORES=3 \
QEMU_SVC_CPUS=1 \
QEMU_SERVICE_CPUS=2 \
DISK="$CUSTOM_DISK" \
NBD=/dev/nbd15 \
MOUNT="$CUSTOM_MOUNT" \
PROVIDER='Test Vendor' \
DEVICE_DESC='Test Display Adapter' \
SUBSYS_RE='^VEN_TEST&DEV_TEST$' \
    "$FIXTURE_DIR/finalize-elevation.sh" "$INSTANCE" \
    >"$TMP_DIR/elevation.log"

[[ "$(cat "$TEST_OUT/fix.vms-dir")" == "$CUSTOM_VMS_DIR" ]] ||
    fail "finalize 第一次 sudo 丢失自定义 VMS_DIR"
[[ "$(cat "$TEST_OUT/fix.qemu-img")" == "$CUSTOM_QEMU_IMG" ]] ||
    fail "finalize 第一次 sudo 丢失自定义 QEMU_IMG"
[[ "$(cat "$TEST_OUT/fix.disk")" == "$CUSTOM_DISK" &&
   "$(cat "$TEST_OUT/fix.nbd")" == /dev/nbd15 &&
   "$(cat "$TEST_OUT/fix.mount")" == "$CUSTOM_MOUNT" ]] ||
    fail "finalize 第一次 sudo 丢失离线磁盘挂载参数"
[[ "$(cat "$TEST_OUT/fix.provider")" == 'Test Vendor' &&
   "$(cat "$TEST_OUT/fix.device-desc")" == 'Test Display Adapter' &&
   "$(cat "$TEST_OUT/fix.subsys-re")" == '^VEN_TEST&DEV_TEST$' ]] ||
    fail "finalize 第一次 sudo 丢失 GPU 修复参数"

PATH="$FAKE_BIN:$PATH" \
SUDO_USER="$(id -un)" \
VMS_DIR="$CUSTOM_VMS_DIR" \
IMAGE_ROOT="$CUSTOM_IMAGE_ROOT" \
QEMU_IMG="$CUSTOM_QEMU_IMG" \
    "$FIXTURE_DIR/finalize-clone-gpu.sh" "$INSTANCE" \
    --restart -- \
    --cpus=2 \
    "--qemu=$QEMU_WITH_SPACE" \
    --allow-platform-compatibility \
    --proxy >"$TMP_DIR/finalize.log"

[[ "$(cat "$TEST_OUT/vms-dir")" == "$CUSTOM_VMS_DIR" ]] ||
    fail "finalize 第二次 sudo 丢失自定义 VMS_DIR"
[[ "$(cat "$TEST_OUT/image-root")" == "$CUSTOM_IMAGE_ROOT" ]] ||
    fail "finalize 第二次 sudo 丢失自定义 IMAGE_ROOT"
[[ "$(cat "$TEST_OUT/qemu-img")" == "$CUSTOM_QEMU_IMG" ]] ||
    fail "finalize 第二次 sudo 丢失自定义 QEMU_IMG"
[[ "$(cat "$TEST_OUT/sudo-user")" == "$(id -un)" ]] ||
    fail "finalize 没有以原始用户重新启动"
[[ "$(cat "$TEST_OUT/fix.args")" == "$INSTANCE" ]] ||
    fail "finalize fixture 未执行离线修复步骤"
[[ ! -e "$TEST_OUT/chown.args" ]] ||
    fail "finalize 不得 chown 实例目录或共享 base pin"
[[ "$(stat -c '%d:%i:%u:%g:%a' "$BASE_REPOSITORY")" == "$BASE_INODE_BEFORE" ]] ||
    fail "finalize 改变了共享 base inode 的密封元数据"
[[ "$BASE_REPOSITORY" -ef "$CUSTOM_VMS_DIR/$INSTANCE/.base.qcow2" ]] ||
    fail "finalize 替换了实例 base pin"

mapfile -d '' -t START_ARGV <"$TEST_OUT/start.args"
[[ "${START_ARGV[0]:-}" == "$INSTANCE" &&
   "${START_ARGV[1]:-}" == --cpus=2 &&
   "${START_ARGV[2]:-}" == "--qemu=$QEMU_WITH_SPACE" &&
   "${START_ARGV[3]:-}" == --allow-platform-compatibility &&
   "${START_ARGV[4]:-}" == --proxy &&
   "${#START_ARGV[@]}" == 5 ]] ||
    fail "finalize --restart 没有逐参数传播 clone/start 配置"

grep -F 'VMS_DIR="$VMS_DIR"' "$FINALIZE" >/dev/null ||
    fail "生产 finalize 未显式注入 VMS_DIR"
grep -F 'IMAGE_ROOT="${IMAGE_ROOT:-}"' "$FINALIZE" >/dev/null ||
    fail "生产 finalize 未显式注入 IMAGE_ROOT"
grep -F 'STOCK_MATCHING_ID = r'\''PCI\VEN_1AF4&DEV_1050'\''' \
    "$HIVE_PATCHER" >/dev/null ||
    fail "离线修复器未固定 stock viogpudo MatchingDeviceId"
for signed_metadata_contract in \
        "service.casefold() == 'viogpudod'" \
        "%viogpudod.devicedesc%;" \
        "%vendor%;" \
        "'DriverDesc': STOCK_DRIVER_DESCRIPTION" \
        "'ProviderName': STOCK_DRIVER_PROVIDER" \
        "'MatchingDeviceId': STOCK_MATCHING_ID"; do
    grep -F "$signed_metadata_contract" "$HIVE_PATCHER" >/dev/null ||
        fail "离线修复器缺少签名关联契约：$signed_metadata_contract"
done
grep -F "re.fullmatch(" "$PACKAGE_HELPER" >/dev/null ||
    fail "签名包预检没有约束发布 INF 文件名"
grep -F 'EXPECTED_DIGESTS' "$PACKAGE_HELPER" >/dev/null ||
    fail "签名包预检没有固定 INF/CAT/SYS 摘要"
grep -F 'os.link(temporary, published, follow_symlinks=False)' "$PACKAGE_HELPER" >/dev/null ||
    fail "离线修复器没有原子无覆盖恢复缺失的 oemN.inf"
grep -F 'get_regular_file_metadata' "$PACKAGE_HELPER" >/dev/null ||
    fail "离线修复器没有拒绝非普通发布 INF"
grep -F "if not published_missing:" "$PACKAGE_HELPER" >/dev/null ||
    fail "签名包预检没有对 existing oemN.inf fail-closed"
grep -F "f'ControlSet{current:03d}'" "$HIVE_PATCHER" "$PACKAGE_HELPER" >/dev/null ||
    fail "离线修复仍硬编码 ControlSet001"
grep -F 'STOCK_INF="$STOCK_INF"' "$HOST_FIX" >/dev/null ||
    fail "host finalize 没有把受信 stock INF 传给离线修复器"
grep -F 'updated persistent refresh helper' "$HOST_FIX" >/dev/null ||
    fail "host finalize 没有更新客体持久化 refresh helper"
grep -F '安装关联字段（保留微软签名链）' "$HOST_FIX" >/dev/null ||
    fail "host finalize 没有报告签名关联修复"

python3 -m py_compile "$HIVE_PATCHER" "$PACKAGE_HELPER" ||
    fail "离线修复器 Python 语法错误"

echo "OK: finalize preserves start args and repairs the complete signed-driver association"
