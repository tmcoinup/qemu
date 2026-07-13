#!/usr/bin/env bash
# 在临时根目录验证 root helper 安装契约，不修改真实 /etc 或 /usr/local。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SETUP="$REPO_ROOT/deploy/scripts/setup-host-helpers.sh"
PERF="$REPO_ROOT/deploy/scripts/host-performance.sh"
ISOLATE="$REPO_ROOT/deploy/scripts/host-cpu-isolate.sh"
ISOLATE_RUNTIME="$REPO_ROOT/deploy/scripts/host-cpu-isolate-runtime.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
trusted_qemu="$tmp/trusted-qemu-system-x86_64"
cp /bin/true "$trusted_qemu"
chmod 0755 "$trusted_qemu"

VMATE_INSTALL_ROOT="$tmp" VMATE_TARGET_UID="$(id -u)" \
    VMATE_QEMU_BINARY="$trusted_qemu" "$SETUP" install >/dev/null
VMATE_INSTALL_ROOT="$tmp" VMATE_TARGET_UID="$(id -u)" "$SETUP" check >/dev/null

perf_dest="$tmp/usr/local/libexec/qemu-vmate-host-performance"
iso_dest="$tmp/usr/local/libexec/qemu-vmate-cpu-isolate"
runtime_dest="$tmp/usr/local/libexec/qemu-vmate-cpu-isolate-runtime.sh"
trust_dest="$tmp/usr/local/libexec/qemu-vmate-cpu-isolate-qemu.conf"
sudoers="$tmp/etc/sudoers.d/qemu-vmate-host"

[[ "$(stat -c '%a' "$perf_dest")" == "755" ]] || fail "performance helper mode 错误"
[[ "$(stat -c '%a' "$iso_dest")" == "755" ]] || fail "isolate helper mode 错误"
[[ "$(stat -c '%a' "$runtime_dest")" == "755" ]] || fail "isolate runtime mode 错误"
[[ "$(stat -c '%a' "$trust_dest")" == "644" ]] || fail "QEMU 信任清单 mode 错误"
grep -Fx "path=$(realpath -e "$trusted_qemu")" "$trust_dest" >/dev/null \
    || fail "QEMU 信任清单未绑定安装时指定的 canonical path"
grep -Eq '^sha256=[0-9a-f]{64}$' "$trust_dest" \
    || fail "QEMU 信任清单缺少 SHA-256"
grep -F "NOPASSWD:NOSETENV" "$sudoers" >/dev/null || fail "sudoers 缺少 NOSETENV"
grep -F "/usr/local/libexec/qemu-vmate-host-performance" "$sudoers" >/dev/null \
    || fail "sudoers 没有固定 performance helper 路径"
grep -F "$REPO_ROOT" "$sudoers" >/dev/null \
    && fail "sudoers 不得引用 Git 工作区"
grep -F '/usr/local/libexec/qemu-vmate-cpu-isolate-runtime.sh' "$sudoers" >/dev/null \
    && fail "sudoers 不得直接授权可 source 的 runtime 库"

if "$PERF" 123 456 >/dev/null 2>&1; then
    fail "performance helper 应拒绝多余参数"
fi
if "$PERF" not-a-number >/dev/null 2>&1; then
    fail "performance helper 应拒绝非数字频率"
fi
if "$ISOLATE" apply 1 '0;id' 1 0 1 >/dev/null 2>&1; then
    fail "CPU isolate helper 应拒绝非法 mems"
fi
if "$ISOLATE" release >/dev/null 2>&1; then
    fail "CPU isolate helper release 必须绑定实例登记"
fi
if "$ISOLATE" status unexpected >/dev/null 2>&1; then
    fail "CPU isolate helper 应拒绝多余参数"
fi
if "$ISOLATE" preflight unexpected >/dev/null 2>&1; then
    fail "CPU isolate preflight 应拒绝多余参数"
fi
if "$PERF" 0 10000001 >/dev/null 2>&1; then
    fail "performance helper 应拒绝过大的 halt_poll"
fi

# root helper 的锁不得位于 /tmp，也不得允许环境变量改变 cgroup/锁路径；目标进程
# 必须同时校验 sudo 调用 UID、QEMU executable、Tgid 与 vCPU comm。
grep -F 'readonly RUNTIME_DIR="/run/qemu-vmate-cpu-isolate"' "$ISOLATE" >/dev/null \
    || fail "CPU isolate 缺少固定 root 私有运行时目录"
grep -F '/tmp/qemu-cpuiso.lock' "$ISOLATE" >/dev/null \
    && fail "CPU isolate 仍使用可被普通用户置换的 /tmp 锁"
grep -F "VMISO_NAME=\"\${VMISO_NAME" "$ISOLATE" >/dev/null \
    && fail "CPU isolate 仍接受环境覆盖 VMISO_NAME"
grep -F 'readonly RUNTIME_LIB="/usr/local/libexec/qemu-vmate-cpu-isolate-runtime.sh"' \
    "$ISOLATE" >/dev/null || fail "CPU isolate 没有固定 root-owned runtime 路径"
for required_guard in '_validate_qemu_target' "/proc/\$pid/exe" '^Uid:' '^Tgid:' \
        'CPU\ [0-9]+/(KVM|TCG)' '_validate_trusted_executable' 'sha256sum'; do
    grep -F "$required_guard" "$ISOLATE_RUNTIME" >/dev/null \
        || fail "CPU isolate 缺少目标边界校验: $required_guard"
done

# 在 user namespace 中让测试副本获得 namespace-root，只替换固定 /run 与 cgroup
# 根到临时目录。预置“锁 -> victim”符号链接后调用真实 release 路径；必须在打开 fd
# 前失败，且 victim 内容不能被截断。这是旧 `/tmp` 漏洞的直接回归。
if command -v unshare >/dev/null 2>&1 && unshare -Ur true 2>/dev/null; then
    fake_root="$tmp/fake-root"
    fake_cgroup="$fake_root/sys/fs/cgroup"
    fake_runtime="$fake_root/run/qemu-vmate-cpu-isolate"
    isolate_copy="$tmp/qemu-vmate-cpu-isolate-test"
    runtime_copy="$tmp/qemu-vmate-cpu-isolate-runtime-test.sh"
    trust_copy="$tmp/qemu-vmate-cpu-isolate-trust-test.conf"
    mkdir -p "$fake_cgroup" "$fake_runtime"
    chmod 0700 "$fake_runtime"
    cp "$ISOLATE_RUNTIME" "$runtime_copy"
    cp "$trust_dest" "$trust_copy"
    chmod 0755 "$runtime_copy"
    chmod 0644 "$trust_copy"
    sed \
        -e "s|readonly CG_ROOT=\"/sys/fs/cgroup\"|readonly CG_ROOT=\"$fake_cgroup\"|" \
        -e "s|readonly RUNTIME_DIR=\"/run/qemu-vmate-cpu-isolate\"|readonly RUNTIME_DIR=\"$fake_runtime\"|" \
        -e "s|readonly RUNTIME_LIB=\"/usr/local/libexec/qemu-vmate-cpu-isolate-runtime.sh\"|readonly RUNTIME_LIB=\"$runtime_copy\"|" \
        -e "s|readonly TRUST_MANIFEST=\"/usr/local/libexec/qemu-vmate-cpu-isolate-qemu.conf\"|readonly TRUST_MANIFEST=\"$trust_copy\"|" \
        "$ISOLATE" > "$isolate_copy"
    chmod 0755 "$isolate_copy"
    victim="$tmp/root-victim"
    printf '%s\n' 'DO-NOT-TRUNCATE' > "$victim"
    ln -s "$victim" "$fake_runtime/global.lock"
    if unshare -Ur "$isolate_copy" release 1 >/dev/null 2>&1; then
        fail "CPU isolate 接受了符号链接锁"
    fi
    [[ "$(cat "$victim")" == 'DO-NOT-TRUNCATE' ]] \
        || fail "CPU isolate 符号链接回归截断了 victim"
fi

chmod 0640 "$sudoers"
if VMATE_INSTALL_ROOT="$tmp" VMATE_TARGET_UID="$(id -u)" \
        "$SETUP" check >/dev/null 2>&1; then
    fail "check 应拒绝 mode 非 0440 的 sudoers"
fi
chmod 0440 "$sudoers"
cp -p "$sudoers" "$sudoers.clean"
chmod 0640 "$sudoers"
printf '%s\n' 'ALL ALL=(ALL) NOPASSWD: ALL' >> "$sudoers"
chmod 0440 "$sudoers"
if VMATE_INSTALL_ROOT="$tmp" VMATE_TARGET_UID="$(id -u)" \
        "$SETUP" check >/dev/null 2>&1; then
    fail "check 应拒绝被追加宽泛授权的 sudoers"
fi
mv -fT -- "$sudoers.clean" "$sudoers"
mv "$sudoers" "$sudoers.real"
ln -s "$sudoers.real" "$sudoers"
if VMATE_INSTALL_ROOT="$tmp" VMATE_TARGET_UID="$(id -u)" \
        "$SETUP" check >/dev/null 2>&1; then
    fail "check 应拒绝符号链接 sudoers"
fi
rm -f "$sudoers"
mv "$sudoers.real" "$sudoers"
ln "$sudoers" "$sudoers.hard"
if VMATE_INSTALL_ROOT="$tmp" VMATE_TARGET_UID="$(id -u)" \
        "$SETUP" check >/dev/null 2>&1; then
    fail "check 应拒绝具有额外硬链接的 sudoers"
fi
rm -f "$sudoers.hard"

chmod 0775 "$perf_dest"
if VMATE_INSTALL_ROOT="$tmp" "$SETUP" check >/dev/null 2>&1; then
    fail "check 应拒绝 group-writable helper"
fi
chmod 0755 "$perf_dest"
chmod 0775 "$runtime_dest"
if VMATE_INSTALL_ROOT="$tmp" "$SETUP" check >/dev/null 2>&1; then
    fail "check 应拒绝 group-writable runtime"
fi
chmod 0755 "$runtime_dest"
chmod 0775 "$(dirname "$runtime_dest")"
if VMATE_INSTALL_ROOT="$tmp" "$SETUP" check >/dev/null 2>&1; then
    fail "check 应拒绝 group-writable libexec 目录"
fi
chmod 0755 "$(dirname "$runtime_dest")"
mv "$trust_dest" "$trust_dest.real"
ln -s "$trust_dest.real" "$trust_dest"
if VMATE_INSTALL_ROOT="$tmp" "$SETUP" check >/dev/null 2>&1; then
    fail "check 应拒绝符号链接 QEMU 信任清单"
fi
rm -f "$trust_dest"
mv "$trust_dest.real" "$trust_dest"
mv "$iso_dest" "$iso_dest.real"
ln -s "$iso_dest.real" "$iso_dest"
if VMATE_INSTALL_ROOT="$tmp" "$SETUP" check >/dev/null 2>&1; then
    fail "check 应拒绝符号链接 helper"
fi

bash -n "$SETUP" "$PERF" "$ISOLATE" "$ISOLATE_RUNTIME" \
    "$REPO_ROOT/deploy/scripts/lib/sv-host-helpers.sh"
echo "PASS: root-owned host helper installation"
