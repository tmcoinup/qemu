#!/usr/bin/env bash
# 验证 finalize --restart 的第二次 sudo 会把自定义镜像目录和 clone 创建参数
# 原样交给 start-vm。测试仅把 EUID 分支改成 false，并用本地替身执行其余生产脚本。
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
INSTANCE=812345
TEST_OUT="$TMP_DIR/result"
mkdir -p "$FIXTURE_DIR" "$FAKE_BIN" \
    "$CUSTOM_VMS_DIR/$INSTANCE" "$TEST_OUT"
export TEST_OUT

# 保留生产脚本全部 root 分支，只把当前非 root 测试进程会走的提权入口禁用。
sed 's/^if \[\[ \$EUID -ne 0 \]\]; then$/if false; then/' \
    "$FINALIZE" >"$FIXTURE_DIR/finalize-clone-gpu.sh"
chmod +x "$FIXTURE_DIR/finalize-clone-gpu.sh"

cat >"$FIXTURE_DIR/host-fix-gpu-devpkey.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"$TEST_OUT/fix.args"
EOF
chmod +x "$FIXTURE_DIR/host-fix-gpu-devpkey.sh"

cat >"$FIXTURE_DIR/start-vm.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s' "${VMS_DIR:-}" >"$TEST_OUT/vms-dir"
printf '%s' "${IMAGE_ROOT:-}" >"$TEST_OUT/image-root"
printf '%s\0' "$@" >"$TEST_OUT/start.args"
EOF
chmod +x "$FIXTURE_DIR/start-vm.sh"

# 当前测试用户不能真正 sudo；替身只接受生产使用的 `sudo -u USER env ...` 形状，
# 随后执行 env/start 替身，从而覆盖第二次降权调用的真实参数边界。
cat >"$FAKE_BIN/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == -u && "${3:-}" == env ]] || exit 90
printf '%s' "$2" >"$TEST_OUT/sudo-user"
shift 2
exec "$@"
EOF
chmod +x "$FAKE_BIN/sudo"

QEMU_WITH_SPACE="$TMP_DIR/qemu build/qemu-system-x86_64"
PATH="$FAKE_BIN:$PATH" \
SUDO_USER="$(id -un)" \
VMS_DIR="$CUSTOM_VMS_DIR" \
IMAGE_ROOT="$CUSTOM_IMAGE_ROOT" \
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
[[ "$(cat "$TEST_OUT/sudo-user")" == "$(id -un)" ]] ||
    fail "finalize 没有以原始用户重新启动"
[[ "$(cat "$TEST_OUT/fix.args")" == "$INSTANCE" ]] ||
    fail "finalize fixture 未执行离线修复步骤"

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
