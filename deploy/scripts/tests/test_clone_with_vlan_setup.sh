#!/usr/bin/env bash
# 验证 VLAN 初始化与基础镜像克隆在同一个提权入口内按顺序执行。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE="$SCRIPT_DIR/../clone-with-vlan-setup.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

if (( EUID == 0 )); then
    echo "SKIP: 该测试使用当前非 root 账号验证调用者身份传递"
    exit 0
fi

mkdir -p "$TEST_ROOT/scripts"
cp "$SOURCE" "$TEST_ROOT/scripts/clone-with-vlan-setup.sh"

cat >"$TEST_ROOT/scripts/setup-bridge.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
[[ "${VLAN_TRUNK:-}" == "1" && "${VLAN_SETUP_AUTO:-}" == "1" ]] || exit 11
[[ "${VM_USER:-}" == "$(id -un)" ]] || exit 12
[[ -z "${STEALTH_PLATFORM_ID+x}" ]] || exit 13
printf 'setup\n' >>"$HERE/../trace"
EOF

cat >"$TEST_ROOT/scripts/clone-from-base.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
[[ "${STEALTH_PLATFORM_ID:-}" == "platform-test" ]] || exit 21
[[ "${SUDO_USER:-}" == "$(id -un)" ]] || exit 22
[[ "$*" == "--vms-dir=/tmp/vms /tmp/base.qcow2 7" ]] || exit 23
printf 'clone\n' >>"$HERE/../trace"
EOF
chmod 0755 "$TEST_ROOT/scripts/"*.sh

# 测试环境无法真正取得 root；复制入口中的 root 身份门禁由静态检查覆盖，这里只
# 在临时副本中移除该行，以运行其后的环境隔离与顺序契约。
sed -i '/(( EUID == 0 )) || fail/d' "$TEST_ROOT/scripts/clone-with-vlan-setup.sh"

env -i \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    "SUDO_USER=$(id -un)" \
    "SUDO_UID=$(id -u)" \
    STEALTH_PLATFORM_ID=platform-test \
    bash "$TEST_ROOT/scripts/clone-with-vlan-setup.sh" \
    --vms-dir=/tmp/vms /tmp/base.qcow2 7

[[ "$(<"$TEST_ROOT/trace")" == $'setup\nclone' ]] \
    || fail "组合入口没有按 setup → clone 顺序执行"
grep -F '(( EUID == 0 )) || fail' "$SOURCE" >/dev/null \
    || fail "生产入口缺少 root 身份门禁"

echo "PASS: VLAN 初始化与克隆复用单一提权入口"
