#!/usr/bin/env bash
# shellcheck disable=SC2016 # 单引号内容用于匹配生产脚本中的变量字面量。
# seal/clone 共用的 base 镜像格式、原子发布与入口接线回归。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BASE_LIB="$REPO_ROOT/deploy/scripts/lib/base-image.sh"
SUDO_SESSION_LIB="$REPO_ROOT/deploy/scripts/lib/sv-sudo-session.sh"
PUBLISH_HELPER="$REPO_ROOT/deploy/scripts/lib/seal-base-publish.py"
SEAL="$REPO_ROOT/deploy/scripts/seal-base.sh"
CLONE="$REPO_ROOT/deploy/scripts/clone-from-base.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

QEMU_IMG="$REPO_ROOT/build/qemu-img"
if [[ ! -x "$QEMU_IMG" ]]; then
    QEMU_IMG="$(command -v qemu-img 2>/dev/null || true)"
fi
[[ -n "$QEMU_IMG" && -x "$QEMU_IMG" ]] ||
    fail "缺少 qemu-img，无法测试 base 生命周期"

# shellcheck source=../lib/base-image.sh
source "$BASE_LIB"

STANDALONE="$TMP_DIR/standalone.qcow2"
CHAINED="$TMP_DIR/chained.qcow2"
RAW="$TMP_DIR/raw.img"
EXTERNAL_DATA="$TMP_DIR/external-data.raw"
EXTERNAL_QCOW="$TMP_DIR/external-data.qcow2"
"$QEMU_IMG" create -q -f qcow2 "$STANDALONE" 1M
base_image_require_standalone_qcow2 "$QEMU_IMG" "$STANDALONE" ||
    fail "独立 qcow2 被错误拒绝"
[[ "$BASE_IMAGE_FORMAT" == qcow2 &&
   "$BASE_IMAGE_VIRTUAL_SIZE" == 1048576 &&
   "$BASE_IMAGE_HAS_BACKING" == 0 &&
   "$BASE_IMAGE_HAS_EXTERNAL_DATA" == 0 ]] ||
    fail "base 元数据解析错误"
chmod 0444 "$STANDALONE"
if base_image_require_trusted_backing_qcow2_fast \
        "$QEMU_IMG" "$STANDALONE" 1048576 \
        >"$TMP_DIR/untrusted-owner.log" 2>&1; then
    fail "普通用户拥有的 0444 base 被运行期 backing 门禁接受"
fi
grep -F "root-owned 0444" "$TMP_DIR/untrusted-owner.log" >/dev/null ||
    fail "不可信 backing owner/mode 没有明确诊断"
base_image_require_trusted_backing_qcow2_fast \
    "$QEMU_IMG" "$STANDALONE" 1048576 1 ||
    fail "legacy 普通用户 0444 base 无法兼容启动"

# 传输落地的 0644 base 只能在 sudo clone 的导入边界自动密封；普通用户直接调用
# 共享库不得越权修改 owner/mode。成功路径由 root helper 的稳定 FD 契约覆盖。
chmod 0644 "$STANDALONE"
if base_image_adopt_portable_copy \
        "$QEMU_IMG" "$PUBLISH_HELPER" "$STANDALONE" \
        >"$TMP_DIR/non-root-adopt.log" 2>&1; then
    fail "普通用户绕过 sudo 自动密封了传输 base"
fi
grep -F "需要由普通用户通过 sudo 调用 clone" \
        "$TMP_DIR/non-root-adopt.log" >/dev/null ||
    fail "传输 base 的非 root 导入诊断不明确"
chmod 0444 "$STANDALONE"

# fakeroot 让同一组 Bash/Python 子进程共享虚拟 uid/chown 视图，可在无 sudo 的 CI
# 中覆盖 0666 下载文件的完整成功编排；真实内核权限仍由 helper 的 root 门禁约束。
if command -v fakeroot >/dev/null 2>&1; then
    PORTABLE_COPY="$TMP_DIR/portable-download.qcow2"
    "$QEMU_IMG" create -q -f qcow2 "$PORTABLE_COPY" 1M
    chmod 0666 "$PORTABLE_COPY"
    fakeroot env SUDO_UID="$(id -u)" bash -c '
        set -euo pipefail
        source "$1"
        chown "$SUDO_UID" "$4"
        base_image_adopt_portable_copy "$2" "$3" "$4"
        [[ "$(stat -c "%u:%g:%a:%h" -- "$4")" == 0:0:444:1 ]]
        [[ "$BASE_IMAGE_ADOPTED_FROM_UID" == "$SUDO_UID" ]]
    ' _ "$BASE_LIB" "$QEMU_IMG" "$PUBLISH_HELPER" "$PORTABLE_COPY" \
        >"$TMP_DIR/portable-adopt.log" ||
        fail "复制/下载后的 0666 base 无法自动密封"
    grep -F "已自动导入为 root:root 0444" \
            "$TMP_DIR/portable-adopt.log" >/dev/null ||
        fail "base 自动导入成功路径没有明确报告"
fi

"$QEMU_IMG" create -q -f qcow2 -F qcow2 -b "$STANDALONE" "$CHAINED"
if base_image_require_standalone_qcow2 \
        "$QEMU_IMG" "$CHAINED" >"$TMP_DIR/chained.log" 2>&1; then
    fail "带 backing file 的链式 base 被接受"
fi
grep -F "不是独立密封镜像" "$TMP_DIR/chained.log" >/dev/null ||
    fail "链式 base 拒绝原因不明确"

"$QEMU_IMG" create -q -f raw "$RAW" 1M
if base_image_require_standalone_qcow2 \
        "$QEMU_IMG" "$RAW" >"$TMP_DIR/raw.log" 2>&1; then
    fail "raw 镜像被当作 qcow2 base 接受"
fi
grep -F "base 必须是 qcow2" "$TMP_DIR/raw.log" >/dev/null ||
    fail "raw base 拒绝原因不明确"

"$QEMU_IMG" create -q -f raw "$EXTERNAL_DATA" 1M
"$QEMU_IMG" create -q -f qcow2 \
    -o "data_file=$EXTERNAL_DATA" "$EXTERNAL_QCOW" 1M
if base_image_require_standalone_qcow2 \
        "$QEMU_IMG" "$EXTERNAL_QCOW" >"$TMP_DIR/external.log" 2>&1; then
    fail "依赖 external data file 的 qcow2 被当作独立 base"
fi
grep -F "external data file" "$TMP_DIR/external.log" >/dev/null ||
    fail "external data base 拒绝原因不明确"

# overlay 可以记录相对 backing，但完整解析路径、容量和格式必须仍精确匹配 base。
OVERLAY_DIR="$TMP_DIR/instance"
OVERLAY="$OVERLAY_DIR/disk.qcow2"
mkdir -p "$OVERLAY_DIR"
(
    cd "$OVERLAY_DIR"
    "$QEMU_IMG" create -q -f qcow2 -F qcow2 \
        -b ../standalone.qcow2 disk.qcow2
)
base_image_require_overlay_qcow2 \
    "$QEMU_IMG" "$OVERLAY" "$STANDALONE" 1048576 ||
    fail "合法相对 backing overlay 被错误拒绝"
if base_image_require_overlay_qcow2 \
        "$QEMU_IMG" "$OVERLAY" "$EXTERNAL_QCOW" 1048576 \
        >"$TMP_DIR/wrong-backing.log" 2>&1; then
    fail "overlay 的错误 expected base 被接受"
fi
BAD_BACKING_FORMAT="$OVERLAY_DIR/bad-backing-format.qcow2"
(
    cd "$OVERLAY_DIR"
    "$QEMU_IMG" create -q -f qcow2 -F raw \
        -b ../standalone.qcow2 "$(basename "$BAD_BACKING_FORMAT")"
)
if base_image_require_overlay_qcow2 \
        "$QEMU_IMG" "$BAD_BACKING_FORMAT" "$STANDALONE" 1048576 \
        >"$TMP_DIR/bad-backing-format.log" 2>&1; then
    fail "声明为 raw 的 qcow2 backing 被 overlay 校验接受"
fi

# hard-link 发布必须 no-replace，且回滚只能删除仍与 staging 同 inode 的目标。
STAGING="$TMP_DIR/.base.seal.tmp"
TARGET="$TMP_DIR/base.qcow2"
cp -- "$STANDALONE" "$STAGING"
base_image_publish_no_replace "$STAGING" "$TARGET" ||
    fail "完整 staging 无法原子发布"
[[ "$STAGING" -ef "$TARGET" ]] || fail "发布结果没有保持同一 inode"
if base_image_publish_no_replace \
        "$STAGING" "$TARGET" >"$TMP_DIR/existing.log" 2>&1; then
    fail "原子发布覆盖了已有目标"
fi
base_image_remove_published_file "$STAGING" "$TARGET"
[[ ! -e "$TARGET" ]] || fail "本次发布目标无法安全回滚"

ln -s "$TMP_DIR/missing" "$TARGET"
if base_image_publish_no_replace \
        "$STAGING" "$TARGET" >"$TMP_DIR/symlink.log" 2>&1; then
    fail "原子发布覆盖了 dangling symlink"
fi
[[ ! -e "$TMP_DIR/missing" ]] || fail "原子发布跟随了 dangling symlink"
rm -- "$TARGET"
mkdir "$TARGET"
if base_image_publish_no_replace \
        "$STAGING" "$TARGET" >"$TMP_DIR/directory.log" 2>&1; then
    fail "原子发布把已有目录当成目标文件"
fi
[[ ! -e "$TARGET/$(basename "$STAGING")" ]] ||
    fail "目录竞争导致 staging 硬链接泄漏到目标目录"
rmdir "$TARGET"

# 实例内 hard-link pin 必须保留原 inode；仓库目录项被换名后不能让既有 overlay
# 静默改指向同名新文件。
PIN_SOURCE="$TMP_DIR/pin-source.qcow2"
PIN_TARGET="$OVERLAY_DIR/.base.qcow2"
cp -- "$STANDALONE" "$PIN_SOURCE"
ln -- "$PIN_SOURCE" "$PIN_TARGET"
mv -- "$PIN_SOURCE" "$TMP_DIR/pin-source.old"
printf 'replacement\n' >"$PIN_SOURCE"
[[ "$PIN_TARGET" -ef "$TMP_DIR/pin-source.old" &&
   ! "$PIN_TARGET" -ef "$PIN_SOURCE" ]] ||
    fail "实例 base pin 没有隔离仓库目录项替换"

# seal 默认会原地清理源盘，因此必须在任何 profile/QEMU 操作前拒绝多链接 inode。
if (( EUID != 0 )); then
    HARDLINK_VMS="$TMP_DIR/hardlink-vms"
    mkdir -p "$HARDLINK_VMS/9"
    "$QEMU_IMG" create -q -f qcow2 "$HARDLINK_VMS/9/disk.qcow2" 1M
    ln "$HARDLINK_VMS/9/disk.qcow2" "$TMP_DIR/source-alias.qcow2"
    printf 'placeholder-profile\n' >"$HARDLINK_VMS/9/profile"
    if "$SEAL" 9 hardlink-base --no-clean \
            --vms-dir="$HARDLINK_VMS" --qemu-img="$QEMU_IMG" \
            >"$TMP_DIR/hardlink-source.log" 2>&1; then
        fail "seal 接受了存在其它硬链接的源 disk"
    fi
    grep -F "源 disk 存在其它硬链接" "$TMP_DIR/hardlink-source.log" >/dev/null ||
        fail "seal 的源 disk 硬链接拒绝原因不明确"
fi

# 两个入口必须接入同一契约；seal 还必须先持实例锁，再检查/转换源盘。
grep -F 'source "$SCRIPT_DIR/lib/base-image.sh"' "$SEAL" >/dev/null ||
    fail "seal 未加载 base 镜像共享库"
grep -F 'source "$SCRIPT_DIR/lib/base-image.sh"' "$CLONE" >/dev/null ||
    fail "clone 未加载 base 镜像共享库"
grep -F 'exec 8>"$INSTANCE_LOCK"' "$SEAL" >/dev/null ||
    fail "seal 未持有 start/stop 共用的实例锁"
grep -F 'source "$SCRIPT_DIR/lib/sv-sudo-session.sh"' "$SEAL" >/dev/null ||
    fail "seal 未加载长任务 sudo 会话管理库"
[[ "$(grep -cF 'sv_sudo_session_run_supervised \' "$SEAL")" == 2 ]] ||
    fail "seal 清理与发布没有复用同一个受监督 sudo 会话"
grep -F 'python3 "$BASE_PUBLISH_HELPER" publish \' "$SEAL" >/dev/null ||
    fail "seal 未通过非交互 sudo 和稳定 FD root helper 发布独立 base inode"
grep -F 'sv_sudo_session_supervise \' "$SEAL" >/dev/null ||
    fail "seal 没有在主 shell 中监督长时间 qemu-img convert"
grep -F "trap 'seal_signal_exit 143' TERM" "$SEAL" >/dev/null ||
    fail "seal 没有在 TERM 时先清理受监督子进程"
grep -F 'base_image_remove_published_fingerprint' "$SEAL" >/dev/null ||
    fail "seal 回滚仍依赖可置换的 staging 路径"
[[ "$(grep -cF 'rm -f -- "$BASE_TMP"' "$SEAL")" == 2 ]] ||
    fail "seal 没有在成功与异常路径中非交互删除只读 staging"
[[ -f "$PUBLISH_HELPER" ]] || fail "seal root 发布 helper 缺失"
if grep -F '"$QEMU_IMG" convert -p -O qcow2 -c "$SRC_DISK" "$BASE_FILE"' \
        "$SEAL" >/dev/null; then
    fail "seal 仍直接把 convert 输出写到最终路径"
fi
grep -F 'base_image_require_overlay_qcow2' "$CLONE" >/dev/null ||
    fail "clone 未在发布前后验证 overlay backing 契约"
grep -F 'base_image_adopt_portable_copy "$QEMU_IMG"' "$CLONE" >/dev/null ||
    fail "clone 未自动接管复制/下载后丢失 owner/mode 的 base"
grep -F 'clone_lifecycle_prepare_base_pin' "$CLONE" >/dev/null ||
    fail "clone 未在实例目录固定 base backing inode"
grep -F '"$QEMU_IMG" "$DISK" "$BASE_PIN" "$BASE_BYTES"' "$CLONE" >/dev/null ||
    fail "clone 提交校验仍引用可替换的 base 仓库目录项"
grep -F 'base_image_require_trusted_backing_qcow2_fast' \
        "$REPO_ROOT/deploy/scripts/lib/sv-disk.sh" >/dev/null ||
    fail "start 磁盘路径未快速复核已密封 backing"
grep -F 'python3 "$helper" adopt "$source_fd_path" "$fingerprint"' \
        "$BASE_LIB" >/dev/null ||
    fail "base 自动导入未通过稳定 FD root helper 密封"
grep -F 'os.fchown(source_fd, 0, 0)' "$PUBLISH_HELPER" >/dev/null ||
    fail "base 导入 helper 未设置 root:root owner"
grep -F 'source_stat.st_nlink != 1' "$PUBLISH_HELPER" >/dev/null ||
    fail "base 导入 helper 未拒绝共享硬链接"
if grep -F 'command -v qemu-img' "$SEAL" "$CLONE" >/dev/null; then
    fail "显式/默认 qemu-img 错误仍会静默回退系统工具"
fi
if grep -F 'command -v qemu-system-x86_64' "$CLONE" >/dev/null; then
    fail "clone 仍会静默回退 stock qemu-system-x86_64"
fi
grep -F 'if [[ "$TARGET_BYTES" != "$BASE_BYTES" ]]' "$CLONE" >/dev/null ||
    fail "clone 未在发布前 fail-closed 校验启动盘容量"

LOCK_LINE="$(grep -nF 'exec 8>"$INSTANCE_LOCK"' "$SEAL" | head -n1 | cut -d: -f1)"
PROCESS_LINE="$(grep -nF 'sv_qemu_instance_pids "$SRC_INSTANCE"' "$SEAL" |
    head -n1 | cut -d: -f1)"
CONVERT_LINE="$(grep -nF '"$QEMU_IMG" convert -p -O qcow2' "$SEAL" |
    head -n1 | cut -d: -f1)"
[[ -n "$LOCK_LINE" && -n "$PROCESS_LINE" && -n "$CONVERT_LINE" &&
   "$LOCK_LINE" -lt "$PROCESS_LINE" && "$LOCK_LINE" -lt "$CONVERT_LINE" ]] ||
    fail "seal 没有在停机检查与 convert 前持有生命周期锁"

# fake sudo 只记录 argv，并以当前用户执行受控 fixture。这里动态验证长任务只进行
# 一次可交互认证，所有 sudo 都由同一父 Bash 启动，且续期失败不会二次询问密码。
test_sudo_session_lifecycle() (
    local fake_bin="$TMP_DIR/sudo-session-bin"
    local sudo_log="$TMP_DIR/sudo-session.log"
    local real_sleep session_owner probe_pid probe_starttime

    mkdir -p "$fake_bin"
    real_sleep="$(command -v sleep)"
    : >"$sudo_log"
    cat >"$fake_bin/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf -v rendered '%q ' "$@"
printf 'ppid=%s\t%s\n' "$PPID" "$rendered" >>"$FAKE_SUDO_LOG"
if [[ "${FAKE_SUDO_FAIL_REFRESH:-0}" == 1 && "$*" == "-n -v" ]]; then
    exit 40
fi
[[ "$*" == "-v" || "$*" == "-n -v" ]] && exit 0
[[ "${1:-}" == "-n" && "${2:-}" == "--" ]] || exit 64
shift 2
exec "$@"
EOF
    cat >"$fake_bin/sleep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
"$REAL_SLEEP" 0.02
EOF
    cat >"$fake_bin/long-command" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${LONG_COMMAND_PID_FILE:-}" ]]; then
    printf '%s\n' "$$" >"$LONG_COMMAND_PID_FILE"
fi
"$REAL_SLEEP" "${LONG_COMMAND_SECONDS:-0.35}"
EOF
    cat >"$fake_bin/fail-command" <<'EOF'
#!/usr/bin/env bash
exit 41
EOF
    chmod +x "$fake_bin/sudo" "$fake_bin/sleep" \
        "$fake_bin/long-command" "$fake_bin/fail-command"

    export FAKE_SUDO_LOG="$sudo_log" REAL_SLEEP="$real_sleep"
    PATH="$fake_bin:$PATH"
    export PATH
    # shellcheck source=../lib/sv-sudo-session.sh
    source "$SUDO_SESSION_LIB"

    session_owner="$BASHPID"
    sv_sudo_session_open || fail "fake sudo 会话无法启动"
    sv_sudo_session_run_supervised long-command ||
        fail "同一 sudo 会话无法执行受监督命令"
    grep -F $'\t-n -v ' "$sudo_log" >/dev/null ||
        fail "长任务 sudo 会话没有执行非交互续期"
    if sv_sudo_session_run_supervised \
            fail-command 2>"$TMP_DIR/sudo-command-failure.log"; then
        fail "非交互 sudo 失败被错误吞掉"
    fi
    grep -F "不会再次询问密码" "$TMP_DIR/sudo-command-failure.log" >/dev/null ||
        fail "非交互 sudo 失败没有明确说明不会二次询问密码"

    [[ "$(grep -cF $'\t-v ' "$sudo_log")" == 1 ]] ||
        fail "长任务 sudo 会话发生了多次可交互认证"
    grep -F $'\t-n -- long-command ' "$sudo_log" >/dev/null ||
        fail "特权命令没有强制使用 sudo -n --"
    awk -F '\t' -v expected="ppid=$session_owner" \
        '$1 != expected { exit 1 }' "$sudo_log" ||
        fail "sudo 认证、续期和特权命令没有保持同一个父 Bash"
    sv_sudo_session_close

    # 续期失败必须关闭会话并 fail-closed；不能退回交互 sudo 再问第二次密码。
    : >"$sudo_log"
    export FAKE_SUDO_FAIL_REFRESH=0 LONG_COMMAND_SECONDS=1
    export LONG_COMMAND_PID_FILE="$TMP_DIR/sudo-long-command.pid"
    sv_sudo_session_open || fail "续期失败场景无法启动 fake sudo 会话"
    export FAKE_SUDO_FAIL_REFRESH=1
    if sv_sudo_session_run_supervised long-command \
            2>"$TMP_DIR/sudo-refresh-failure.log"; then
        fail "sudo 续期失败后仍执行了特权命令"
    fi
    [[ -z "$SV_SUDO_SESSION_ACTIVE_PID" ]] ||
        fail "sudo 续期失败后仍保留受监督子进程"
    [[ -s "$LONG_COMMAND_PID_FILE" ]] ||
        fail "续期失败测试没有启动受监督子进程"
    if kill -0 "$(<"$LONG_COMMAND_PID_FILE")" 2>/dev/null; then
        fail "sudo 续期失败后受监督子进程仍然存活"
    fi
    [[ "$(grep -cF $'\t-v ' "$sudo_log")" == 1 ]] ||
        fail "sudo 续期失败场景发生了二次交互认证"
    grep -F "不会再次询问密码" "$TMP_DIR/sudo-refresh-failure.log" >/dev/null ||
        fail "sudo 续期失败没有明确阻止二次密码提示"
    sv_sudo_session_close

    # starttime 是 PID 身份的一部分；不匹配时 cancel 不得向该 PID 发信号。
    "$real_sleep" 1 &
    probe_pid=$!
    _sv_sudo_session_read_starttime "$probe_pid" ||
        fail "无法读取受监督测试进程 starttime"
    probe_starttime="$SV_SUDO_SESSION_STARTTIME_RESULT"
    _sv_sudo_session_process_matches "$probe_pid" "$probe_starttime" ||
        fail "相同 PID/starttime 没有被识别为同一进程"
    if _sv_sudo_session_process_matches "$probe_pid" "$((probe_starttime + 1))"; then
        fail "PID 相同但 starttime 不同的进程被错误视为同一进程"
    fi
    kill "$probe_pid"
    wait "$probe_pid" 2>/dev/null || true
)

test_sudo_session_lifecycle

python3 -m py_compile "$PUBLISH_HELPER" ||
    fail "base 发布/导入 helper Python 语法错误"

echo "OK: base image validation, locking and atomic publish passed"
