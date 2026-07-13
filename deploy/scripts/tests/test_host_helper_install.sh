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
read -r trusted_device trusted_inode < <(stat -Lc '%d %i' "$trusted_qemu")
trusted_sha256="$(sha256sum "$trusted_qemu")"
trusted_sha256="${trusted_sha256%% *}"

VMATE_INSTALL_ROOT="$tmp" VMATE_TARGET_UID="$(id -u)" \
    "$SETUP" install "--qemu=$trusted_qemu" \
    "--expect-device=$trusted_device" "--expect-inode=$trusted_inode" \
    "--expect-sha256=$trusted_sha256" >/dev/null
VMATE_INSTALL_ROOT="$tmp" VMATE_TARGET_UID="$(id -u)" "$SETUP" check >/dev/null

perf_dest="$tmp/usr/local/libexec/qemu-vmate-host-performance"
iso_dest="$tmp/usr/local/libexec/qemu-vmate-cpu-isolate"
runtime_dest="$tmp/usr/local/libexec/qemu-vmate-cpu-isolate-runtime-v1.sh"
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
grep -F '/usr/local/libexec/qemu-vmate-cpu-isolate-runtime-v1.sh' "$sudoers" >/dev/null \
    && fail "sudoers 不得直接授权可 source 的 runtime 库"

# build.sh 传入的验证后快照必须与 installer 提权后重算结果一致；任一字段不符时
# 应在事务开始前拒绝，且原安装继续通过 check。
if [[ "${trusted_sha256:0:1}" == "0" ]]; then
    bad_sha256="1${trusted_sha256:1}"
else
    bad_sha256="0${trusted_sha256:1}"
fi
if VMATE_INSTALL_ROOT="$tmp" VMATE_TARGET_UID="$(id -u)" \
        "$SETUP" install "--qemu=$trusted_qemu" \
        "--expect-device=$trusted_device" "--expect-inode=$trusted_inode" \
        "--expect-sha256=$bad_sha256" >/dev/null 2>&1; then
    fail "installer 接受了与 build 验证结果不同的 QEMU 摘要"
fi
VMATE_INSTALL_ROOT="$tmp" VMATE_TARGET_UID="$(id -u)" "$SETUP" check >/dev/null

# 每个发布点故障都必须恢复旧 helper/runtime/trust/sudoers。替代 QEMU 使用不同内容、
# 路径和 inode，保证 check 通过只能来自真实回滚，而不是新旧文件恰好相同。
replacement_qemu="$tmp/replacement-qemu-system-x86_64"
cp /bin/false "$replacement_qemu"
chmod 0755 "$replacement_qemu"
read -r replacement_device replacement_inode < <(stat -Lc '%d %i' "$replacement_qemu")
replacement_sha256="$(sha256sum "$replacement_qemu")"
replacement_sha256="${replacement_sha256%% *}"
for fail_step in after_backup after_runtime after_trust after_performance \
        after_isolate after_sudoers; do
    if VMATE_INSTALL_ROOT="$tmp" VMATE_TARGET_UID="$(id -u)" \
            VMATE_TEST_FAIL_STEP="$fail_step" \
            "$SETUP" install "--qemu=$replacement_qemu" \
            "--expect-device=$replacement_device" \
            "--expect-inode=$replacement_inode" \
            "--expect-sha256=$replacement_sha256" >/dev/null 2>&1; then
        fail "事务故障注入 $fail_step 未使安装失败"
    fi
    VMATE_INSTALL_ROOT="$tmp" VMATE_TARGET_UID="$(id -u)" \
        "$SETUP" check >/dev/null || fail "事务 $fail_step 回滚后旧安装无效"
    grep -Fx "path=$(realpath -e "$trusted_qemu")" "$trust_dest" >/dev/null \
        || fail "事务 $fail_step 没有恢复旧 QEMU 信任清单"
done

# 两个不同 QEMU 的 installer 必须由 root-owned flock 完整串行化。第一个进程在
# 取得锁后由 FIFO 暂停；第二个进程此时必须保持等待，释放后才可覆盖为第二份清单。
lock_ready_one="$tmp/lock-ready-one"
lock_ready_two="$tmp/lock-ready-two"
lock_release_fifo="$tmp/lock-release.fifo"
mkfifo "$lock_release_fifo"
VMATE_INSTALL_ROOT="$tmp" VMATE_TARGET_UID="$(id -u)" \
    VMATE_TEST_LOCK_READY="$lock_ready_one" \
    VMATE_TEST_LOCK_RELEASE_FIFO="$lock_release_fifo" \
    "$SETUP" install "--qemu=$trusted_qemu" \
    "--expect-device=$trusted_device" "--expect-inode=$trusted_inode" \
    "--expect-sha256=$trusted_sha256" >"$tmp/concurrent-one.log" 2>&1 &
installer_one=$!
for _ in {1..100}; do
    [[ -e "$lock_ready_one" ]] && break
    sleep 0.01
done
[[ -e "$lock_ready_one" ]] || fail "第一个并发 installer 未取得锁"

VMATE_INSTALL_ROOT="$tmp" VMATE_TARGET_UID="$(id -u)" \
    VMATE_TEST_LOCK_READY="$lock_ready_two" \
    "$SETUP" install "--qemu=$replacement_qemu" \
    "--expect-device=$replacement_device" \
    "--expect-inode=$replacement_inode" \
    "--expect-sha256=$replacement_sha256" >"$tmp/concurrent-two.log" 2>&1 &
installer_two=$!
sleep 0.1
[[ ! -e "$lock_ready_two" ]] || fail "第二个 installer 绕过了全局安装锁"
kill -0 "$installer_two" 2>/dev/null || fail "第二个 installer 没有等待全局锁"
printf '%s\n' release > "$lock_release_fifo"
wait "$installer_one" || fail "第一个并发 installer 失败"
wait "$installer_two" || fail "第二个并发 installer 失败"
[[ -e "$lock_ready_two" ]] || fail "释放后第二个 installer 未取得锁"
grep -Fx "path=$(realpath -e "$replacement_qemu")" "$trust_dest" >/dev/null \
    || fail "并发安装最终清单不是锁后执行的第二份 QEMU"
VMATE_INSTALL_ROOT="$tmp" VMATE_TARGET_UID="$(id -u)" "$SETUP" check >/dev/null
rm -f "$lock_release_fifo" "$lock_ready_one" "$lock_ready_two"

# 旧版直接授权工作区脚本的规则既属于 check 契约，也必须由下一次事务安全移除。
legacy_sudoers="$tmp/etc/sudoers.d/qemu-hostperf"
printf '%s\n' 'legacy unsafe rule' > "$legacy_sudoers"
chmod 0440 "$legacy_sudoers"
if VMATE_INSTALL_ROOT="$tmp" VMATE_TARGET_UID="$(id -u)" \
        "$SETUP" check >/dev/null 2>&1; then
    fail "check 应拒绝遗留工作区 sudoers"
fi
VMATE_INSTALL_ROOT="$tmp" VMATE_TARGET_UID="$(id -u)" \
    "$SETUP" install "--qemu=$trusted_qemu" >/dev/null
[[ ! -e "$legacy_sudoers" ]] || fail "安装事务没有移除遗留工作区 sudoers"

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
grep -F 'readonly RUNTIME_LIB="/usr/local/libexec/qemu-vmate-cpu-isolate-runtime-v1.sh"' \
    "$ISOLATE" >/dev/null || fail "CPU isolate 没有固定 root-owned runtime 路径"
grep -F 'readonly CPU_ISOLATE_RUNTIME_ABI="1"' "$ISOLATE" >/dev/null \
    || fail "CPU isolate main 缺少 runtime ABI 绑定"
grep -F 'readonly VMATE_CPU_ISOLATE_RUNTIME_ABI="1"' "$ISOLATE_RUNTIME" >/dev/null \
    || fail "CPU isolate runtime 缺少 ABI 声明"
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
        -e "s|readonly RUNTIME_LIB=\"/usr/local/libexec/qemu-vmate-cpu-isolate-runtime-v1.sh\"|readonly RUNTIME_LIB=\"$runtime_copy\"|" \
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
