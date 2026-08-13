#!/usr/bin/env bash
# 在隔离安装根验证 setup-host-helpers 的多 QEMU 信任集成，不触碰真实 sudoers/libexec。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd -P)"
SETUP="$REPO_ROOT/deploy/scripts/setup-host-helpers.sh"
TRUST_SOURCE="$REPO_ROOT/deploy/scripts/qemu-trust-manifest.sh"
LOADER_SOURCE="$REPO_ROOT/deploy/scripts/host-cpu-isolate-loader.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_eq() {
    local expected="$1" actual="$2" message="$3"
    [[ "$actual" == "$expected" ]] \
        || fail "$message: expected='$expected' actual='$actual'"
}

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
install_root="$tmp/install-root"
empty_proc="$tmp/empty-proc"
qemu_a="$tmp/package/qemu-system-x86_64.real"
qemu_b="$tmp/worktree/build/qemu-system-x86_64"
mkdir -p "$empty_proc" "${qemu_a%/*}" "${qemu_b%/*}"
cp /bin/true "$qemu_a"
cp /bin/false "$qemu_b"
chmod 0755 "$qemu_a" "$qemu_b"
qemu_a="$(realpath -e -- "$qemu_a")"
qemu_b="$(realpath -e -- "$qemu_b")"

run_setup() {
    VMATE_INSTALL_ROOT="$install_root" VMATE_TARGET_UID="$(id -u)" \
        VMATE_TEST_PROC_ROOT="$empty_proc" "$SETUP" "$@"
}

expect_setup_failure() {
    local description="$1"
    shift
    if run_setup "$@" > "$tmp/unexpected-success.log" 2>&1; then
        fail "$description"
    fi
}

manifest="$install_root/usr/local/libexec/qemu-vmate-cpu-isolate-qemu.conf"
trust_runtime="$install_root/usr/local/libexec/qemu-vmate-qemu-trust-v1.sh"
loader_runtime="$install_root/usr/local/libexec/qemu-vmate-cpu-isolate-loader-v1.sh"
isolate_runtime="$install_root/usr/local/libexec/qemu-vmate-cpu-isolate-runtime-v5.sh"
cgroup_runtime="$install_root/usr/local/libexec/qemu-vmate-cpu-isolate-cgroup-v5.sh"
isolate_main="$install_root/usr/local/libexec/qemu-vmate-cpu-isolate"
sudoers="$install_root/etc/sudoers.d/qemu-vmate-host"

# 第一项沿用旧四行格式；第二次安装必须在 root-owned install/runtime 双锁边界内
# 合并为八行两记录，不能让包内 /opt 身份与开发 build 身份互相覆盖。
run_setup install "--qemu=$qemu_a" > "$tmp/install-a.log"
run_setup check "--qemu=$qemu_a" > "$tmp/check-a.log"
assert_eq 4 "$(wc -l < "$manifest")" "首次安装不是兼容旧版的四行单记录"

run_setup install "--qemu=$qemu_b" > "$tmp/install-b.log"
run_setup check "--qemu=$qemu_a" > "$tmp/check-a-after-b.log"
run_setup check "--qemu=$qemu_b" > "$tmp/check-b.log"
assert_eq 8 "$(wc -l < "$manifest")" "第二项安装没有形成两记录并集"
assert_eq 1 "$(grep -Fxc "path=$qemu_a" "$manifest")" "A path 记录丢失或重复"
assert_eq 1 "$(grep -Fxc "path=$qemu_b" "$manifest")" "B path 记录丢失或重复"
assert_eq 2 "$(grep -Ec '^sha256=[0-9a-f]{64}$' "$manifest")" \
    "两项记录没有各自的 SHA-256"
expect_setup_failure "精确 check 接受了未登记路径" \
    check "--qemu=$tmp/not-registered/qemu-system-x86_64"

# 安装事务必须携带新的 trust ABI 和 loader，且固定副本与仓库验证过的源完全一致。
for installed in "$trust_runtime" "$loader_runtime" "$isolate_runtime" \
        "$cgroup_runtime" "$isolate_main"; do
    [[ -f "$installed" && ! -L "$installed" ]] \
        || fail "缺少非符号链接的安装运行库: $installed"
    assert_eq "$(id -u):$(id -g):755:1" \
        "$(stat -Lc '%u:%g:%a:%h' -- "$installed")" "安装运行库元数据错误"
done
cmp -s "$TRUST_SOURCE" "$trust_runtime" || fail "安装 trust ABI 与源文件不一致"
cmp -s "$LOADER_SOURCE" "$loader_runtime" || fail "安装 loader 与源文件不一致"
grep -F '_load_trusted_library "$TRUST_LIB"' "$loader_runtime" >/dev/null \
    || fail "loader 没有从 root-owned TRUST_LIB 加载 trust ABI"
grep -F 'readonly LOADER_LIB="/usr/local/libexec/qemu-vmate-cpu-isolate-loader-v1.sh"' \
    "$isolate_main" >/dev/null || fail "主 helper 没有绑定固定 loader ABI"
grep -F 'readonly TRUST_LIB="/usr/local/libexec/qemu-vmate-qemu-trust-v1.sh"' \
    "$isolate_main" >/dev/null || fail "主 helper 没有绑定固定 trust ABI"
assert_eq "$(id -u):$(id -g):440:1" \
    "$(stat -Lc '%u:%g:%a:%h' -- "$sudoers")" "sudoers 元数据错误"

# 新增 loader/trust ABI 的发布故障必须完整回滚，两条既有记录仍可分别 check。
for fail_step in after_loader after_trust_library; do
    if VMATE_INSTALL_ROOT="$install_root" VMATE_TARGET_UID="$(id -u)" \
            VMATE_TEST_PROC_ROOT="$empty_proc" VMATE_TEST_FAIL_STEP="$fail_step" \
            "$SETUP" install "--qemu=$qemu_a" > "$tmp/$fail_step.log" 2>&1; then
        fail "$fail_step 没有中断发布事务"
    fi
    run_setup check "--qemu=$qemu_a" > /dev/null
    run_setup check "--qemu=$qemu_b" > /dev/null
done

# 回滚失败无论落在 sudoers、loader、trust ABI 还是 main helper，都必须最终撤销
# 三个授权入口，绝不能让 NOPASSWD 指向半恢复依赖。每项使用独立安装根隔离现场。
baseline_root="$install_root"
for restore_index in 0 1 2 6 7 9; do
    install_root="$tmp/restore-$restore_index"
    run_setup install "--qemu=$qemu_a" > /dev/null
    if VMATE_INSTALL_ROOT="$install_root" VMATE_TARGET_UID="$(id -u)" \
            VMATE_TEST_PROC_ROOT="$empty_proc" VMATE_TEST_FAIL_STEP=after_isolate \
            VMATE_TEST_FAIL_RESTORE_INDEX="$restore_index" \
            "$SETUP" install "--qemu=$qemu_b" > "$tmp/restore-$restore_index.log" 2>&1; then
        fail "restore index=$restore_index 故障注入后安装仍成功"
    fi
    for permission in qemu-vmate-host qemu-hostperf qemu-cpuiso; do
        [[ ! -e "$install_root/etc/sudoers.d/$permission" ]] \
            || fail "restore index=$restore_index 失败后仍开放 $permission"
    done
done
install_root="$baseline_root"

# 直接加载实际安装的 trust ABI 并严格读取发布清单，证明安装副本不是只存在但不可用。
bash -c '
    set -euo pipefail
    source "$1"
    qemu_trust_manifest_load_checked "$2" "$3" "$4" 644
    [[ "$(qemu_trust_manifest_count)" == 2 ]]
    qemu_trust_manifest_has_live_record
' _ "$trust_runtime" "$manifest" "$(id -u)" "$(id -g)" \
    || fail "安装 trust ABI 无法解析两项发布清单"

# 注销 A 只能删除 A；B、helper、loader 和 sudoers 继续可用。重复注销必须幂等。
output="$(run_setup unregister "--qemu=$qemu_a")"
assert_eq 'removed=1 remaining=1' "$output" "unregister A 返回契约错误"
! grep -Fx "path=$qemu_a" "$manifest" >/dev/null || fail "unregister A 后记录仍存在"
grep -Fx "path=$qemu_b" "$manifest" >/dev/null || fail "unregister A 误删了 B"
run_setup check "--qemu=$qemu_b" > "$tmp/check-b-after-a.log"
expect_setup_failure "unregister A 后精确 check 仍接受 A" check "--qemu=$qemu_a"
[[ -f "$loader_runtime" && -f "$trust_runtime" && -f "$sudoers" ]] \
    || fail "非最后一项注销删除了共享 helper/runtime/sudoers"
output="$(run_setup unregister "--qemu=$qemu_a")"
assert_eq 'removed=0 remaining=1' "$output" "重复 unregister A 不幂等"

# 注销键是 manifest 的纯词法路径；即使父目录已消失，也不能依赖 realpath 当前拓扑。
missing_key="$tmp/removed-parent/qemu-system-x86_64"
{
    cat "$manifest"
    printf 'path=%s\nsha256=%064d\ndevice=1\ninode=1\n' "$missing_key" 0
} > "$tmp/with-missing.conf"
install -m 0644 "$tmp/with-missing.conf" "$manifest"
output="$(run_setup unregister "--qemu=$missing_key")"
assert_eq 'removed=1 remaining=1' "$output" "不存在父目录的 stale key 无法注销"

# 结构损坏必须让 check/unregister 同时 fail closed，且注销失败不能重写损坏现场。
cp -p -- "$manifest" "$tmp/valid-b.conf"
printf 'path=%s\nunknown=damaged\n' "$qemu_b" > "$manifest"
chmod 0644 "$manifest"
damaged_before="$(sha256sum "$manifest")"
expect_setup_failure "格式损坏后 check 未 fail closed" check "--qemu=$qemu_b"
expect_setup_failure "格式损坏后 unregister 未 fail closed" unregister "--qemu=$qemu_b"
assert_eq "$damaged_before" "$(sha256sum "$manifest")" \
    "失败的 unregister 改写了损坏清单现场"
install -m 0644 "$tmp/valid-b.conf" "$manifest"
run_setup check "--qemu=$qemu_b" > "$tmp/check-restored-b.log"

# 最后一项注销发布合法空 manifest，但不擅自卸载共享 helper；由包管理调用方决定清理。
output="$(run_setup unregister "--qemu=$qemu_b")"
assert_eq 'removed=1 remaining=0' "$output" "最后一项 unregister 返回契约错误"
[[ -f "$manifest" && ! -s "$manifest" && ! -L "$manifest" ]] \
    || fail "最后一项注销没有原子发布空普通 manifest"
[[ -f "$loader_runtime" && -f "$trust_runtime" && -f "$sudoers" ]] \
    || fail "最后一项注销擅自删除了共享 helper/runtime/sudoers"
expect_setup_failure "空信任集仍通过共享 check" check
output="$(run_setup unregister "--qemu=$qemu_b")"
assert_eq 'removed=0 remaining=0' "$output" "空清单重复 unregister 不幂等"

bash -n "$SETUP" "$TRUST_SOURCE" "$LOADER_SOURCE" "$0"
echo "PASS: setup-host-helpers multi-trust install/check/unregister integration"
