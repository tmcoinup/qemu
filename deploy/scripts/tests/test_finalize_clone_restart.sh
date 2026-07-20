#!/usr/bin/env bash
# 验证 finalize --restart 的第二次 sudo 会把自定义镜像目录和 clone 创建参数
# 原样交给 start-vm。测试仅把 EUID 分支改成 false，并用本地替身执行其余生产脚本。
# shellcheck disable=SC2016
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
FINALIZE="$REPO_ROOT/deploy/scripts/finalize-clone-gpu.sh"
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

echo "OK: finalize clone restart preserves custom image paths and start args"
