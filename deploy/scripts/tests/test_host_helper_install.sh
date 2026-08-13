#!/usr/bin/env bash
# 在临时根目录验证 root helper 安装契约，不修改真实 /etc 或 /usr/local。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SETUP="$REPO_ROOT/deploy/scripts/setup-host-helpers.sh"
PERF="$REPO_ROOT/deploy/scripts/host-performance.sh"
ISOLATE="$REPO_ROOT/deploy/scripts/host-cpu-isolate.sh"
ISOLATE_RUNTIME="$REPO_ROOT/deploy/scripts/host-cpu-isolate-runtime.sh"
ISOLATE_CGROUP="$REPO_ROOT/deploy/scripts/host-cpu-isolate-cgroup.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/empty-proc"
export VMATE_TEST_PROC_ROOT="$tmp/empty-proc"
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
runtime_dest="$tmp/usr/local/libexec/qemu-vmate-cpu-isolate-runtime-v5.sh"
cgroup_dest="$tmp/usr/local/libexec/qemu-vmate-cpu-isolate-cgroup-v5.sh"
trust_dest="$tmp/usr/local/libexec/qemu-vmate-cpu-isolate-qemu.conf"
sudoers="$tmp/etc/sudoers.d/qemu-vmate-host"

[[ "$(stat -c '%a' "$perf_dest")" == "755" ]] || fail "performance helper mode 错误"
grep -F '/proc/sys/kernel/split_lock_mitigate' "$perf_dest" >/dev/null \
    || fail "performance helper 缺少 split-lock 限速管理"
grep -F 'HOST_OOM_SCORE_POLICY="-500"' "$perf_dest" >/dev/null \
    || fail "performance helper 缺少固定 OOM 保护策略"
grep -F 'protect-launcher' "$perf_dest" >/dev/null \
    || fail "performance helper 缺少启动器 OOM 保护子命令"
[[ "$(stat -c '%a' "$iso_dest")" == "755" ]] || fail "isolate helper mode 错误"
[[ "$(stat -c '%a' "$runtime_dest")" == "755" ]] || fail "isolate runtime mode 错误"
[[ "$(stat -c '%a' "$cgroup_dest")" == "755" ]] || fail "isolate cgroup runtime mode 错误"
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
grep -F '/usr/local/libexec/qemu-vmate-cpu-isolate-runtime-v5.sh' "$sudoers" >/dev/null \
    && fail "sudoers 不得直接授权可 source 的 runtime 库"
grep -F '/usr/local/libexec/qemu-vmate-cpu-isolate-cgroup-v5.sh' "$sudoers" >/dev/null \
    && fail "sudoers 不得直接授权可 source 的 cgroup 库"

# sudo 已授权但尚未 exec helper 时 real UID 仍是用户、effective UID 已是 root。
# 二次扫描必须读取 effective 列并回滚，不能在 ABI 发布后放行旧 helper。
fake_proc="$tmp/fake-proc"
mkdir -p "$fake_proc/424242"
printf 'Name:\tfake-sudo\nUid:\t99999\t%s\t99999\t99999\n' "$(id -u)" \
    > "$fake_proc/424242/status"
for helper_argument in "$iso_dest" host-cpu-isolate.sh \
        "/old/worktree/deploy/scripts/host-cpu-isolate.sh"; do
    printf '%s\0' sudo -n "$helper_argument" apply 1 > "$fake_proc/424242/cmdline"
    if VMATE_INSTALL_ROOT="$tmp" VMATE_TARGET_UID="$(id -u)" \
            VMATE_TEST_PROC_ROOT="$fake_proc" \
            "$SETUP" install "--qemu=$trusted_qemu" >/dev/null 2>&1; then
        fail "installer 漏过 effective UID 属于 owner 的 in-flight helper: $helper_argument"
    fi
    VMATE_INSTALL_ROOT="$tmp" VMATE_TARGET_UID="$(id -u)" "$SETUP" check >/dev/null
done
# argv 已变化的 helper waiter 仍持有同一 global.lock FD，也必须被 inode 扫描命中。
printf '%s\0' harmless-root-process > "$fake_proc/424242/cmdline"
mkdir "$fake_proc/424242/fd"
ln -s "$tmp/run/qemu-vmate-cpu-isolate/global.lock" "$fake_proc/424242/fd/9"
if VMATE_INSTALL_ROOT="$tmp" VMATE_TARGET_UID="$(id -u)" \
        VMATE_TEST_PROC_ROOT="$fake_proc" \
        "$SETUP" install "--qemu=$trusted_qemu" >/dev/null 2>&1; then
    fail "installer 漏过等待 CPU 运行锁的 helper"
fi
rm -rf "$fake_proc/424242/fd"
VMATE_INSTALL_ROOT="$tmp" VMATE_TARGET_UID="$(id -u)" "$SETUP" check >/dev/null

# 没有 vmiso 时由当前旧 helper 自动回收已确认死亡的状态；测试 stub 会非阻塞取得
# fake CPU lock、核对 SUDO_UID，并只删除指定实例，证明 installer 没有直接 rm。
legacy_runtime="$tmp/run/qemu-vmate-cpu-isolate"
mkdir -p "$legacy_runtime/instances"
chmod 0700 "$legacy_runtime/instances"
cat > "$iso_dest" <<'LEGACY_HELPER'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" == "2" && "$1" == "release" && "$2" =~ ^[1-9][0-9]{0,9}$ ]] || exit 90
runtime="${VMATE_INSTALL_ROOT:?}/run/qemu-vmate-cpu-isolate"
exec {lock_fd}<>"$runtime/global.lock"
flock -n "$lock_fd" || exit 91
[[ "${SUDO_UID:-}" == "${VMATE_TEST_EXPECT_UID:-${VMATE_TARGET_UID:?}}" ]] || exit 92
[[ "${VMATE_TEST_LEGACY_RELEASE_FAIL:-}" != "$2" ]] || exit 93
printf '%s\n' "$2" >> "$VMATE_INSTALL_ROOT/legacy-release.log"
rm -f -- "$runtime/instances/$2.state"
LEGACY_HELPER
chmod 0755 "$iso_dest"
legacy_instances=(1 2 8 9 10 12 101 999 1000)
for legacy_instance in "${legacy_instances[@]}"; do
    printf 'instance=%s\npid=%s\nstart_time=777\nguest_threads_per_core=1\n' \
        "$legacy_instance" "$((600000 + legacy_instance))" > \
        "$legacy_runtime/instances/$legacy_instance.state"
done
chmod 0600 "$legacy_runtime/instances"/*.state
live_proc="$tmp/live-proc"
mkdir -p "$live_proc/600012"
printf '%s\n' \
    '600012 (qemu worker) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 777' \
    > "$live_proc/600012/stat"
live_status=0
VMATE_INSTALL_ROOT="$tmp" VMATE_TARGET_UID="$(id -u)" \
    VMATE_TEST_PROC_ROOT="$live_proc" \
    "$SETUP" install "--qemu=$trusted_qemu" >"$tmp/legacy-live.log" 2>&1 \
    || live_status=$?
if [[ "$live_status" != 75 || -e "$tmp/legacy-release.log" ]]; then
    tail -n 180 "$tmp/legacy-live.log" >&2
    fail "运行中旧 VM 没有以未修改 helper/state 的 EX_TEMPFAIL 延后升级"
fi
if VMATE_INSTALL_ROOT="$tmp" VMATE_TARGET_UID="$(id -u)" \
        VMATE_TEST_LEGACY_RELEASE_FAIL=12 \
        "$SETUP" install "--qemu=$trusted_qemu" >"$tmp/legacy-fail.log" 2>&1; then
    fail "旧 helper 拒绝 release 后 installer 仍继续升级"
fi
[[ -e "$legacy_runtime/instances/12.state" ]] \
    || fail "release 失败后 installer 直接删除了旧状态"
grep -F -- "旧 helper 无法安全释放实例 12" "$tmp/legacy-fail.log" >/dev/null \
    || fail "自动 release 失败缺少明确诊断"
grep -F -- 'VMATE_TEST_LEGACY_RELEASE_FAIL' "$iso_dest" >/dev/null \
    || fail "release 失败后 installer 覆盖了旧 helper"
# 合法状态与非法条目共存时，完整扫描必须在调用任何 release 前失败。
release_count_before="$(wc -l < "$tmp/legacy-release.log")"
printf 'invalid\n' > "$legacy_runtime/instances/.mixed-invalid"
if VMATE_INSTALL_ROOT="$tmp" VMATE_TARGET_UID="$(id -u)" \
        "$SETUP" install "--qemu=$trusted_qemu" >/dev/null 2>&1; then
    fail "installer 接受了合法/非法混合旧状态"
fi
[[ -e "$legacy_runtime/instances/12.state" &&
   "$(wc -l < "$tmp/legacy-release.log")" == "$release_count_before" ]] \
    || fail "非法旧状态没有阻止全部自动 release"
rm -f "$legacy_runtime/instances/.mixed-invalid"
# sudo 产生的 UID 必须优先于可控测试回退值，并原样传给旧 helper。
SUDO_UID="$(id -u)" VMATE_INSTALL_ROOT="$tmp" VMATE_TARGET_UID=99999 \
    VMATE_TEST_EXPECT_UID="$(id -u)" \
    "$SETUP" install "--qemu=$trusted_qemu" >"$tmp/legacy-success.log"
VMATE_INSTALL_ROOT="$tmp" VMATE_TARGET_UID="$(id -u)" "$SETUP" check >/dev/null
for legacy_instance in "${legacy_instances[@]}"; do
    [[ ! -e "$legacy_runtime/instances/$legacy_instance.state" ]] \
        || fail "自动迁移漏掉旧状态 $legacy_instance"
    [[ "$(grep -Fxc -- "$legacy_instance" "$tmp/legacy-release.log")" == "1" ]] \
        || fail "旧 helper 未精确 release 实例 $legacy_instance"
done
for invalid_entry in bad.state .bad.state unexpected; do
    printf 'invalid\n' > "$legacy_runtime/instances/$invalid_entry"
    invalid_output=""
    if invalid_output="$(VMATE_INSTALL_ROOT="$tmp" VMATE_TARGET_UID="$(id -u)" \
            "$SETUP" install "--qemu=$trusted_qemu" 2>&1)"; then
        fail "ABI5 installer 接受了非法旧状态条目: $invalid_entry"
    fi
    grep -F -- "非法旧 ABI 实例运行态条目" <<<"$invalid_output" >/dev/null \
        || fail "非法旧状态条目没有明确诊断: $invalid_entry"
    ! grep -F -- "清理命令:" <<<"$invalid_output" >/dev/null \
        || fail "非法旧状态条目错误生成了 release 命令: $invalid_entry"
    rm -f "$legacy_runtime/instances/$invalid_entry"
done
rmdir "$legacy_runtime/instances"

# ABI5 不兼容旧 full-sibling 状态：空 vmiso 和任意遗留 child 都必须阻止升级。
fake_vmiso="$tmp/sys/fs/cgroup/vmiso"
mkdir -p "$fake_vmiso"
: > "$fake_vmiso/cgroup.procs"
if VMATE_INSTALL_ROOT="$tmp" VMATE_TARGET_UID="$(id -u)" \
        "$SETUP" install "--qemu=$trusted_qemu" >/dev/null 2>&1; then
    fail "installer 接受了未拆除的空旧 ABI vmiso"
fi
mkdir "$fake_vmiso/vm-1"
# 一个合法 child 不能掩盖未知/隐藏/非法名目录。
for abnormal in foo .foo vm-0 vm-x; do
    mkdir "$fake_vmiso/$abnormal"
    if VMATE_INSTALL_ROOT="$tmp" VMATE_TARGET_UID="$(id -u)" \
            "$SETUP" install "--qemu=$trusted_qemu" >/dev/null 2>&1; then
        fail "installer 忽略了 vmiso 异常目录: $abnormal"
    fi
    rmdir "$fake_vmiso/$abnormal"
done
for abnormal in foo vm-2; do
    ln -s "$tmp" "$fake_vmiso/$abnormal"
    if VMATE_INSTALL_ROOT="$tmp" VMATE_TARGET_UID="$(id -u)" \
            "$SETUP" install "--qemu=$trusted_qemu" >/dev/null 2>&1; then
        fail "installer 忽略了 vmiso symlink: $abnormal"
    fi
    rm -f "$fake_vmiso/$abnormal"
done
printf 'collision\n' > "$fake_vmiso/vm-2"
if VMATE_INSTALL_ROOT="$tmp" VMATE_TARGET_UID="$(id -u)" \
        "$SETUP" install "--qemu=$trusted_qemu" >/dev/null 2>&1; then
    fail "installer 接受了占用实例命名空间的普通文件"
fi
rm -f "$fake_vmiso/vm-2"
if VMATE_INSTALL_ROOT="$tmp" VMATE_TARGET_UID="$(id -u)" \
        "$SETUP" install "--qemu=$trusted_qemu" >/dev/null 2>&1; then
    fail "ABI5 installer 接受了遗留旧 ABI exact child"
fi
rm -rf "$tmp/sys/fs"

# 即使错误产物带执行位，installer 也不能把 0 字节文件登记为可信 QEMU；
# 拒绝必须发生在发布事务前，原有安装随后仍应完整通过 check。
empty_qemu="$tmp/empty-qemu-system-x86_64"
: > "$empty_qemu"
chmod 0755 "$empty_qemu"
if VMATE_INSTALL_ROOT="$tmp" VMATE_TARGET_UID="$(id -u)" \
        "$SETUP" install "--qemu=$empty_qemu" >/dev/null 2>&1; then
    fail "installer 接受了 0 字节 QEMU"
fi
VMATE_INSTALL_ROOT="$tmp" VMATE_TARGET_UID="$(id -u)" "$SETUP" check >/dev/null

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
for fail_step in before_backup_move_0 after_backup_move_0 after_backup after_runtime \
        after_cgroup after_trust after_performance after_isolate after_sudoers; do
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

# helper 本体恢复失败时必须保持 sudoers 关闭，并保留备份供管理员恢复；不能把
# NOPASSWD 重新指向缺失/混合版本。清理临时故障现场后再恢复后续测试基线。
if VMATE_INSTALL_ROOT="$tmp" VMATE_TARGET_UID="$(id -u)" \
        VMATE_TEST_FAIL_STEP=after_isolate VMATE_TEST_FAIL_RESTORE_INDEX=7 \
        "$SETUP" install "--qemu=$replacement_qemu" >/dev/null 2>&1; then
    fail "注入 helper restore 故障后 installer 仍返回成功"
fi
[[ ! -e "$sudoers" ]] || fail "helper 恢复失败后重新开放了 sudoers"
compgen -G "$tmp/usr/local/libexec/.qemu-vmate-backup.*" >/dev/null \
    || fail "helper 恢复失败后没有保留事务备份"
rm -f "$tmp/usr/local/libexec/".qemu-vmate-backup.* \
    "$tmp/etc/sudoers.d/".qemu-vmate-backup.*
VMATE_INSTALL_ROOT="$tmp" VMATE_TARGET_UID="$(id -u)" \
    "$SETUP" install "--qemu=$trusted_qemu" >/dev/null
VMATE_INSTALL_ROOT="$tmp" VMATE_TARGET_UID="$(id -u)" "$SETUP" check >/dev/null

# 两个不同 QEMU 的 installer 必须由 root-owned flock 完整串行化。第一个进程在
# 取得锁后由 FIFO 暂停；第二个进程此时必须保持等待，释放后合并两份清单。
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
[[ "$(grep -Fxc "path=$(realpath -e "$trusted_qemu")" "$trust_dest")" == 1 &&
   "$(grep -Fxc "path=$(realpath -e "$replacement_qemu")" "$trust_dest")" == 1 ]] \
    || fail "并发安装没有原子保留两份 QEMU 信任记录"
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

if "$PERF" 123 456 0 unexpected >/dev/null 2>&1; then
    fail "performance helper 应拒绝多余参数"
fi
if "$PERF" not-a-number >/dev/null 2>&1; then
    fail "performance helper 应拒绝非数字频率"
fi
if "$ISOLATE" apply 1 '0;id' 1 0 1,2 0 1 1 >/dev/null 2>&1; then
    fail "CPU isolate helper 应拒绝非法 mems"
fi
if packing_output="$("$ISOLATE" apply 1 0 1 0,1,2,3 11,12,13,14 0 1 2 2>&1)"; then
    fail "CPU isolate helper 接受了 4C4T→host_tpc=2 的禁用压缩映射"
fi
[[ "$packing_output" == *"不支持的 vCPU/guest_tpc/host_tpc 组合"* ]] \
    || fail "非法 packing 没有在提权前命中硬门禁: $packing_output"
if "$ISOLATE" apply 1 0 1 0,1 11,12 00 1 1 >/dev/null 2>&1; then
    fail "CPU isolate helper 接受了无法由 ABI5 state 重读的 service=00"
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
if "$PERF" 0 0 2 >/dev/null 2>&1; then
    fail "performance helper 应拒绝非 0/1 的 split-lock 策略"
fi
if "$PERF" protect-launcher 1 2 3 -1000 >/dev/null 2>&1; then
    fail "performance helper 不得接受调用方注入 OOM 分数"
fi

# root helper 的锁不得位于 /tmp，也不得允许环境变量改变 cgroup/锁路径；目标进程
# 必须同时校验 sudo 调用 UID、QEMU executable、Tgid 与 vCPU comm。
grep -F 'readonly RUNTIME_DIR="/run/qemu-vmate-cpu-isolate"' "$ISOLATE" >/dev/null \
    || fail "CPU isolate 缺少固定 root 私有运行时目录"
grep -F '/tmp/qemu-cpuiso.lock' "$ISOLATE" >/dev/null \
    && fail "CPU isolate 仍使用可被普通用户置换的 /tmp 锁"
grep -F "VMISO_NAME=\"\${VMISO_NAME" "$ISOLATE" >/dev/null \
    && fail "CPU isolate 仍接受环境覆盖 VMISO_NAME"
grep -F 'readonly RUNTIME_LIB="/usr/local/libexec/qemu-vmate-cpu-isolate-runtime-v5.sh"' \
    "$ISOLATE" >/dev/null || fail "CPU isolate 没有固定 root-owned runtime 路径"
grep -F 'readonly CGROUP_LIB="/usr/local/libexec/qemu-vmate-cpu-isolate-cgroup-v5.sh"' \
    "$ISOLATE" >/dev/null || fail "CPU isolate 没有固定 root-owned cgroup 路径"
grep -F 'readonly CPU_ISOLATE_RUNTIME_ABI="5"' "$ISOLATE" >/dev/null \
    || fail "CPU isolate main 缺少 runtime ABI 绑定"
grep -F 'CPU_ISOLATE_PACKING_POLICY="logical-1to1-v1"' "$ISOLATE" >/dev/null \
    || fail "CPU isolate main 缺少 logical 1:1 packing 策略绑定"
grep -F 'readonly VMATE_CPU_ISOLATE_RUNTIME_ABI="5"' "$ISOLATE_RUNTIME" >/dev/null \
    || fail "CPU isolate runtime 缺少 ABI 声明"
grep -F 'readonly VMATE_CPU_ISOLATE_CGROUP_ABI="5"' "$ISOLATE_CGROUP" >/dev/null \
    || fail "CPU isolate cgroup runtime 缺少 ABI 声明"
grep -F 'host_threads_per_core' "$ISOLATE" >/dev/null \
    || fail "ABI5 实例状态缺少独立 host packing 字段"
grep -F 'refuse_active_legacy_cpu_isolation' "$SETUP" >/dev/null \
    || fail "ABI5 installer 缺少旧状态升级保护"
for required_guard in '_validate_qemu_target' "/proc/\$pid/exe" '^Uid:' '^Tgid:' \
        'CPU\ [0-9]+/(KVM|TCG)' '_validate_trusted_executable' 'qemu_trust_file_sha256'; do
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
    cgroup_copy="$tmp/qemu-vmate-cpu-isolate-cgroup-test.sh"
    trust_copy="$tmp/qemu-vmate-cpu-isolate-trust-test.conf"
    mkdir -p "$fake_cgroup" "$fake_runtime"
    chmod 0700 "$fake_runtime"
    cp "$ISOLATE_RUNTIME" "$runtime_copy"
    cp "$ISOLATE_CGROUP" "$cgroup_copy"
    cp "$trust_dest" "$trust_copy"
    chmod 0755 "$runtime_copy"
    chmod 0755 "$cgroup_copy"
    chmod 0644 "$trust_copy"
    sed \
        -e "s|readonly CG_ROOT=\"/sys/fs/cgroup\"|readonly CG_ROOT=\"$fake_cgroup\"|" \
        -e "s|readonly RUNTIME_DIR=\"/run/qemu-vmate-cpu-isolate\"|readonly RUNTIME_DIR=\"$fake_runtime\"|" \
        -e "s|readonly RUNTIME_LIB=\"/usr/local/libexec/qemu-vmate-cpu-isolate-runtime-v5.sh\"|readonly RUNTIME_LIB=\"$runtime_copy\"|" \
        -e "s|readonly CGROUP_LIB=\"/usr/local/libexec/qemu-vmate-cpu-isolate-cgroup-v5.sh\"|readonly CGROUP_LIB=\"$cgroup_copy\"|" \
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

bash -n "$SETUP" "$PERF" "$ISOLATE" "$ISOLATE_RUNTIME" "$ISOLATE_CGROUP" \
    "$REPO_ROOT/deploy/scripts/lib/sv-host-helpers.sh"
echo "PASS: root-owned host helper installation"
