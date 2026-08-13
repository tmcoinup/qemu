#!/usr/bin/env bash
# 安装宿主调优/CPU隔离 helper 的 root-owned 固定副本和最小 sudoers 授权。
# 正常流程由 deploy/tools/build.sh 在成功编译后调用；本脚本作为可审计的特权实现
# 独立保留，手工入口只用于 check 诊断或登记仓库外的 patched QEMU。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT_PREFIX="${VMATE_INSTALL_ROOT:-}"
# sudo 入口必须优先信任 sudo 自己生成的 SUDO_UID，不能让被保留的普通环境变量
# VMATE_TARGET_UID 把 NOPASSWD 规则改发给其它 UID。临时安装根/直接 root 测试才使用覆盖值。
TARGET_UID="${SUDO_UID:-${VMATE_TARGET_UID:-$(id -u)}}"
LIBEXEC_DIR="$ROOT_PREFIX/usr/local/libexec"
SUDOERS_DIR="$ROOT_PREFIX/etc/sudoers.d"
PERF_DEST="$LIBEXEC_DIR/qemu-vmate-host-performance"
ISO_DEST="$LIBEXEC_DIR/qemu-vmate-cpu-isolate"
ISO_RUNTIME_DEST="$LIBEXEC_DIR/qemu-vmate-cpu-isolate-runtime-v5.sh"
ISO_CGROUP_DEST="$LIBEXEC_DIR/qemu-vmate-cpu-isolate-cgroup-v5.sh"
ISO_LOADER_DEST="$LIBEXEC_DIR/qemu-vmate-cpu-isolate-loader-v1.sh"
QEMU_TRUST_LIB_DEST="$LIBEXEC_DIR/qemu-vmate-qemu-trust-v1.sh"
QEMU_TRUST_DEST="$LIBEXEC_DIR/qemu-vmate-cpu-isolate-qemu.conf"
SUDOERS_DEST="$SUDOERS_DIR/qemu-vmate-host"
LEGACY_PERF_SUDOERS="$SUDOERS_DIR/qemu-hostperf"
LEGACY_ISO_SUDOERS="$SUDOERS_DIR/qemu-cpuiso"
INSTALL_LOCK_DIR="$ROOT_PREFIX/run/qemu-vmate"
INSTALL_LOCK_FILE="$INSTALL_LOCK_DIR/host-helper-install.lock"
OWNER_UID=0
OWNER_GID=0
# 单元测试可把安装根指向临时目录；此时不提升权限，也不伪造 root 所有权。
if [[ -n "$ROOT_PREFIX" ]]; then
    OWNER_UID="$(id -u)"
    OWNER_GID="$(id -g)"
fi

if [[ -z "$ROOT_PREFIX" && $EUID -ne 0 ]]; then
    exec sudo -- "$0" "$@"
fi

if ! [[ "$TARGET_UID" =~ ^[0-9]+$ ]]; then
    echo "ERROR: 无法确定授权用户 UID: '$TARGET_UID'" >&2
    exit 2
fi

check_regular_file() {
    local path="$1" expected_mode="$2" metadata

    [[ -f "$path" && ! -L "$path" ]] || {
        echo "ERROR: 安装文件必须是非符号链接的普通文件: $path" >&2
        return 1
    }
    metadata="$(stat -Lc '%u:%g:%a:%h' "$path" 2>/dev/null || true)"
    [[ "$metadata" == "$OWNER_UID:$OWNER_GID:$expected_mode:1" ]] || {
        echo "ERROR: 安装文件 owner/mode/link 错误: $path ($metadata)" >&2
        return 1
    }
}

check_secure_directory() {
    local path="$1" expected_mode="$2" metadata
    [[ -d "$path" && ! -L "$path" ]] || return 1
    metadata="$(stat -Lc '%u:%g:%a' "$path" 2>/dev/null || true)"
    [[ "$metadata" == "$OWNER_UID:$OWNER_GID:$expected_mode" ]]
}

check_install_directories() {
    check_secure_directory "$LIBEXEC_DIR" 755 &&
        check_secure_directory "$SUDOERS_DIR" 755
}

# shellcheck source=lib/setup-host-cpu-install-guard.sh
source "$HERE/lib/setup-host-cpu-install-guard.sh"
# shellcheck source=lib/setup-host-qemu-trust.sh
source "$HERE/lib/setup-host-qemu-trust.sh"

acquire_install_lock() {
    local lock_tmp path_meta fd_meta

    command -v flock >/dev/null 2>&1 || {
        echo "ERROR: 缺少 flock，无法串行化宿主 helper 安装" >&2
        return 1
    }
    [[ ! -e "$INSTALL_LOCK_DIR" ||
       ( -d "$INSTALL_LOCK_DIR" && ! -L "$INSTALL_LOCK_DIR" ) ]] || {
        echo "ERROR: helper 安装锁目录不是安全普通目录: $INSTALL_LOCK_DIR" >&2
        return 1
    }
    install -d -o "$OWNER_UID" -g "$OWNER_GID" -m 0700 "$INSTALL_LOCK_DIR"
    check_secure_directory "$INSTALL_LOCK_DIR" 700 || {
        echo "ERROR: helper 安装锁目录 owner/mode 非法" >&2
        return 1
    }

    # 在 root-only 目录中用同文件系统 `mv -nT` 原子竞争首次创建，避免 `> lock`
    # 跟随预置 symlink，也不会产生 hard-link 计数短暂为 2 的并发误判。
    if [[ ! -e "$INSTALL_LOCK_FILE" && ! -L "$INSTALL_LOCK_FILE" ]]; then
        lock_tmp="$(mktemp "$INSTALL_LOCK_DIR/.host-helper-lock.XXXXXX")"
        install -o "$OWNER_UID" -g "$OWNER_GID" -m 0600 /dev/null "$lock_tmp"
        mv -nT -- "$lock_tmp" "$INSTALL_LOCK_FILE"
        rm -f -- "$lock_tmp"
    fi
    check_regular_file "$INSTALL_LOCK_FILE" 600 || {
        echo "ERROR: helper 安装锁文件 owner/mode/link 非法" >&2
        return 1
    }
    exec {INSTALL_LOCK_FD}<>"$INSTALL_LOCK_FILE"
    path_meta="$(stat -Lc '%d:%i' -- "$INSTALL_LOCK_FILE")"
    fd_meta="$(stat -Lc '%d:%i' -- "/proc/$$/fd/$INSTALL_LOCK_FD")"
    [[ "$path_meta" == "$fd_meta" ]] || {
        echo "ERROR: helper 安装锁在打开期间被替换" >&2
        return 1
    }
    flock -x "$INSTALL_LOCK_FD"
    check_regular_file "$INSTALL_LOCK_FILE" 600 || return 1
    fd_meta="$(stat -Lc '%d:%i' -- "/proc/$$/fd/$INSTALL_LOCK_FD")"
    path_meta="$(stat -Lc '%d:%i' -- "$INSTALL_LOCK_FILE")"
    [[ "$path_meta" == "$fd_meta" ]] || return 1

    # 只供临时安装根的并发测试使用：ready 在持锁后创建，FIFO 控制释放时机。
    if [[ -n "$ROOT_PREFIX" && -n "${VMATE_TEST_LOCK_READY:-}" ]]; then
        : > "$VMATE_TEST_LOCK_READY"
    fi
    if [[ -n "$ROOT_PREFIX" && -n "${VMATE_TEST_LOCK_RELEASE_FIFO:-}" ]]; then
        IFS= read -r _ < "$VMATE_TEST_LOCK_RELEASE_FIFO"
    fi
}

check_sudoers_contract() {
    local sudoers="${1:-$SUDOERS_DEST}" expected actual

    check_regular_file "$sudoers" 440 || return 1
    expected="$(
        printf '%s\n' '# 由 qemu vmate setup-host-helpers.sh 生成；仅授权本机 VM 操作者，禁止环境变量注入。'
        printf '#%s ALL=(root) NOPASSWD:NOSETENV: %s *\n' \
            "$TARGET_UID" "/usr/local/libexec/qemu-vmate-host-performance"
        printf '#%s ALL=(root) NOPASSWD:NOSETENV: %s *\n' \
            "$TARGET_UID" "/usr/local/libexec/qemu-vmate-cpu-isolate"
    )"
    actual="$(<"$sudoers")" || return 1
    [[ "$actual" == "$expected" ]]
}

verify_installation() {
    check_install_directories || {
        echo "ERROR: libexec/sudoers 必须为可信 owner 的非符号链接 0755 目录" >&2
        return 1
    }
    check_secure_directory "$INSTALL_LOCK_DIR" 700 || return 1
    check_regular_file "$INSTALL_LOCK_FILE" 600 || return 1
    check_regular_file "$PERF_DEST" 755 || return 1
    check_regular_file "$ISO_DEST" 755 || return 1
    check_regular_file "$ISO_RUNTIME_DEST" 755 || return 1
    check_regular_file "$ISO_CGROUP_DEST" 755 || return 1
    check_regular_file "$ISO_LOADER_DEST" 755 || return 1
    check_regular_file "$QEMU_TRUST_LIB_DEST" 755 || return 1
    check_qemu_trust_manifest "$QEMU_TRUST_DEST" "${1:-}" || {
        echo "ERROR: QEMU root-owned 信任清单无效或构建产物已变化" >&2
        return 1
    }
    check_sudoers_contract || {
        echo "ERROR: sudoers 必须为可信 owner 的 0440 单链接普通文件，且内容精确匹配" >&2
        return 1
    }
    [[ ! -e "$LEGACY_PERF_SUDOERS" && ! -L "$LEGACY_PERF_SUDOERS" &&
       ! -e "$LEGACY_ISO_SUDOERS" && ! -L "$LEGACY_ISO_SUDOERS" ]] || {
        echo "ERROR: 仍存在直接授权 Git 工作区脚本的旧 sudoers" >&2
        return 1
    }
    echo "PASS: host helpers 安装契约有效"
}

usage_install() {
    echo "用法: sudo $0 install [--qemu=/path] [内部构建摘要参数]" >&2
}

QEMU_OVERRIDE="${VMATE_QEMU_BINARY:-}"
EXPECTED_QEMU_DEVICE=""
EXPECTED_QEMU_INODE=""
EXPECTED_QEMU_SHA256=""
command="${1:-install}"
(( $# == 0 )) || shift
case "$command" in
    install|--install)
        qemu_seen=0
        while (( $# )); do
            case "$1" in
                --qemu=*)
                    if (( qemu_seen != 0 )) || [[ -z "${1#--qemu=}" ]]; then
                        echo "ERROR: --qemu 为空或重复" >&2
                        exit 2
                    fi
                    QEMU_OVERRIDE="${1#--qemu=}"; qemu_seen=1
                    ;;
                --expect-device=*) EXPECTED_QEMU_DEVICE="${1#--expect-device=}" ;;
                --expect-inode=*) EXPECTED_QEMU_INODE="${1#--expect-inode=}" ;;
                --expect-sha256=*) EXPECTED_QEMU_SHA256="${1#--expect-sha256=}" ;;
                *) usage_install; exit 2 ;;
            esac
            shift
        done
        expected_count=0
        [[ -z "$EXPECTED_QEMU_DEVICE" ]] || expected_count=$((expected_count + 1))
        [[ -z "$EXPECTED_QEMU_INODE" ]] || expected_count=$((expected_count + 1))
        [[ -z "$EXPECTED_QEMU_SHA256" ]] || expected_count=$((expected_count + 1))
        (( expected_count == 0 || expected_count == 3 )) || {
            echo "ERROR: 构建摘要参数必须同时提供 device、inode 与 sha256" >&2
            exit 2
        }
        if (( expected_count == 3 )); then
            [[ "$EXPECTED_QEMU_DEVICE" =~ ^[0-9]+$ &&
               "$EXPECTED_QEMU_INODE" =~ ^[0-9]+$ &&
               "$EXPECTED_QEMU_SHA256" =~ ^[0-9a-f]{64}$ ]] || {
                echo "ERROR: 构建摘要参数格式非法" >&2
                exit 2
            }
        fi
        acquire_install_lock
        # 尚未持 CPU global.lock 时让当前已安装 helper 自动回收确认死亡的旧实例；
        # helper 会自行串行化并拒绝活动 PID。发布窗口内仍会持锁二次复验。
        release_stale_legacy_cpu_isolation
        ;;
    check|--check)
        CHECK_QEMU=""
        if (( $# == 1 )) && [[ "$1" == --qemu=* && -n "${1#--qemu=}" ]]; then
            CHECK_QEMU="${1#--qemu=}"
        elif (( $# != 0 )); then
            echo "用法: sudo $0 check [--qemu=/path]" >&2; exit 2
        fi
        acquire_install_lock
        verify_installation "$CHECK_QEMU"
        exit 0
        ;;
    unregister|--unregister)
        (( $# == 1 )) && [[ "$1" == --qemu=* && -n "${1#--qemu=}" ]] || {
            echo "用法: sudo $0 unregister --qemu=/canonical/path" >&2; exit 2
        }
        acquire_install_lock
        unregister_qemu_trust_path "${1#--qemu=}"
        exit 0
        ;;
    *) echo "用法: sudo $0 [install|check|unregister]" >&2; exit 2 ;;
esac

# 开发版 QEMU 可以位于用户可写工作树，但 NOPASSWD helper 只信任管理员安装时记录的
# 精确 canonical path、device/inode 与 SHA-256。重新编译后必须重新安装清单；这样既
# 支持仓库自建二进制，也不再允许任意同名伪进程占用宿主独占 CPU。
QEMU_SOURCE="${QEMU_OVERRIDE:-$HERE/../../build/qemu-system-x86_64}"
QEMU_SOURCE="$(realpath -e -- "$QEMU_SOURCE" 2>/dev/null)" || {
    echo "ERROR: 找不到可信 QEMU；请先构建或设置 VMATE_QEMU_BINARY" >&2
    exit 1
}
[[ -f "$QEMU_SOURCE" && -s "$QEMU_SOURCE" && -x "$QEMU_SOURCE" &&
   "$QEMU_SOURCE" != *$'\n'* && "$QEMU_SOURCE" != *$'\r'* ]] || {
    echo "ERROR: 可信 QEMU 必须是非空可执行普通文件且路径不能含换行" >&2
    exit 1
}
QEMU_META="$(stat -Lc '%d %i' -- "$QEMU_SOURCE")"
read -r QEMU_DEVICE QEMU_INODE <<<"$QEMU_META"
QEMU_SHA256="$(qemu_trust_file_sha256 "$QEMU_SOURCE")"

if [[ -n "$EXPECTED_QEMU_DEVICE" ]] &&
   [[ "$QEMU_DEVICE:$QEMU_INODE:$QEMU_SHA256" != \
      "$EXPECTED_QEMU_DEVICE:$EXPECTED_QEMU_INODE:$EXPECTED_QEMU_SHA256" ]]; then
    echo "ERROR: QEMU 在编译验证后、提权登记前发生变化；拒绝信任未验证产物" >&2
    exit 1
fi

recheck_qemu_snapshot() {
    local current_meta current_digest
    current_meta="$(stat -Lc '%d:%i' -- "$QEMU_SOURCE" 2>/dev/null)" || return 1
    current_digest="$(qemu_trust_file_sha256 "$QEMU_SOURCE")" || return 1
    [[ "$current_meta:$current_digest" == \
       "$QEMU_DEVICE:$QEMU_INODE:$QEMU_SHA256" ]]
}

maybe_test_fail() {
    local step="$1"
    # 故障注入只在临时安装根生效，真实 root 部署不能被普通环境变量中断。
    if [[ -n "$ROOT_PREFIX" && "${VMATE_TEST_FAIL_STEP:-}" == "$step" ]]; then
        echo "TEST: 在事务步骤 $step 注入失败" >&2
        return 1
    fi
}

declare -a stage_files=()
declare -a transaction_destinations=(
    "$SUDOERS_DEST"
    "$LEGACY_PERF_SUDOERS"
    "$LEGACY_ISO_SUDOERS"
    "$PERF_DEST"
    "$ISO_RUNTIME_DEST"
    "$ISO_CGROUP_DEST"
    "$ISO_LOADER_DEST"
    "$QEMU_TRUST_LIB_DEST"
    "$QEMU_TRUST_DEST"
    "$ISO_DEST"
)
declare -a transaction_backups=()
declare -a transaction_had_original=()
transaction_started=0
transaction_committed=0
transaction_backup_count=0

finish_transaction() {
    local original_status=$? index permission_index rollback_failed=0 path backup
    # EXIT 回滚一旦开始必须完成；第二个终端信号不能打断 rm→mv 的恢复窗口。
    trap '' HUP INT QUIT TERM
    trap - EXIT

    if (( transaction_started && ! transaction_committed )); then
        echo "ERROR: helper 安装事务失败，正在恢复上一版本" >&2
        # 中文注释：sudoers 是第一个备份项，因此逆序恢复会让它最后重新生效；
        # 在 helper/runtime/trust 全部恢复之前，普通用户无法调用混合版本。
        for (( index=transaction_backup_count - 1; index >= 0; index-- )); do
            path="${transaction_destinations[$index]}"
            backup="${transaction_backups[$index]}"
            if [[ -n "$ROOT_PREFIX" &&
                  "${VMATE_TEST_FAIL_RESTORE_INDEX:-}" == "$index" ]]; then
                rollback_failed=1
                continue
            fi
            if [[ -e "$backup" || -L "$backup" ]]; then
                rm -f -- "$path" 2>/dev/null || rollback_failed=1
                if [[ "${transaction_had_original[$index]}" == "1" ]]; then
                    mv -fT -- "$backup" "$path" 2>/dev/null || rollback_failed=1
                else
                    rm -f -- "$backup" 2>/dev/null || rollback_failed=1
                fi
            elif [[ "${transaction_had_original[$index]}" == "0" ]]; then
                # 本项原本不存在；若新版本已发布，失败回滚应把它移除。
                rm -f -- "$path" 2>/dev/null || rollback_failed=1
            elif [[ ! -e "$path" && ! -L "$path" ]]; then
                # 原文件和备份同时消失意味着无法证明旧版本仍可恢复。
                rollback_failed=1
            fi
        done
        if (( rollback_failed )); then
            # 无论失败出现在依赖还是任一 sudoers 自身，最终都撤销全部授权入口。
            for (( permission_index=0; permission_index<=2; permission_index++ )); do
                rm -f -- "${transaction_destinations[$permission_index]}" 2>/dev/null || true
            done
            echo "CRITICAL: helper 安装回滚不完整；保持失败状态，禁止启动 VM" >&2
            original_status=1
        fi
    fi

    for path in "${stage_files[@]}"; do
        if [[ -n "$path" ]]; then
            rm -f -- "$path" 2>/dev/null || true
        fi
    done
    if (( !rollback_failed )); then
        for path in "${transaction_backups[@]}"; do
            [[ -z "$path" ]] || rm -f -- "$path" 2>/dev/null || true
        done
    else
        echo "CRITICAL: 未删除事务备份，保留现场供管理员恢复" >&2
    fi
    exit "$original_status"
}
trap finish_transaction EXIT

for target_dir in "$LIBEXEC_DIR" "$SUDOERS_DIR"; do
    [[ ! -e "$target_dir" || ( -d "$target_dir" && ! -L "$target_dir" ) ]] || {
        echo "ERROR: 固定安装目录不是安全普通目录: $target_dir" >&2
        exit 1
    }
done
install -d -o "$OWNER_UID" -g "$OWNER_GID" -m 0755 "$LIBEXEC_DIR" "$SUDOERS_DIR"
check_install_directories || {
    echo "ERROR: 无法建立安全的 libexec/sudoers 安装目录" >&2
    exit 1
}
perf_tmp="$(mktemp "$LIBEXEC_DIR/.qemu-vmate-host-performance.XXXXXX")"
stage_files+=("$perf_tmp")
iso_tmp="$(mktemp "$LIBEXEC_DIR/.qemu-vmate-cpu-isolate.XXXXXX")"
stage_files+=("$iso_tmp")
runtime_tmp="$(mktemp "$LIBEXEC_DIR/.qemu-vmate-cpu-runtime-v5.XXXXXX")"
stage_files+=("$runtime_tmp")
cgroup_tmp="$(mktemp "$LIBEXEC_DIR/.qemu-vmate-cpu-cgroup-v5.XXXXXX")"
stage_files+=("$cgroup_tmp")
loader_tmp="$(mktemp "$LIBEXEC_DIR/.qemu-vmate-cpu-loader-v1.XXXXXX")"
stage_files+=("$loader_tmp")
trust_lib_tmp="$(mktemp "$LIBEXEC_DIR/.qemu-vmate-qemu-trust-v1.XXXXXX")"
stage_files+=("$trust_lib_tmp")
trust_tmp="$(mktemp "$LIBEXEC_DIR/.qemu-vmate-cpu-trust.XXXXXX")"
stage_files+=("$trust_tmp")
sudoers_tmp="$(mktemp "$SUDOERS_DIR/.qemu-vmate-host.XXXXXX")"
stage_files+=("$sudoers_tmp")

# 全部内容先在目标文件系统内 staging，并在任何固定路径变化前完成权限、内容和
# visudo 校验；后续 mv -T 均为同文件系统原子发布。
install -o "$OWNER_UID" -g "$OWNER_GID" -m 0755 "$HERE/host-performance.sh" "$perf_tmp"
install -o "$OWNER_UID" -g "$OWNER_GID" -m 0755 "$HERE/host-cpu-isolate.sh" "$iso_tmp"
install -o "$OWNER_UID" -g "$OWNER_GID" -m 0755 \
    "$HERE/host-cpu-isolate-runtime.sh" "$runtime_tmp"
install -o "$OWNER_UID" -g "$OWNER_GID" -m 0755 \
    "$HERE/host-cpu-isolate-cgroup.sh" "$cgroup_tmp"
install -o "$OWNER_UID" -g "$OWNER_GID" -m 0755 \
    "$HERE/host-cpu-isolate-loader.sh" "$loader_tmp"
install -o "$OWNER_UID" -g "$OWNER_GID" -m 0755 \
    "$HERE/qemu-trust-manifest.sh" "$trust_lib_tmp"
stage_qemu_trust_manifest "$trust_tmp"
{
    echo "# 由 qemu vmate setup-host-helpers.sh 生成；仅授权本机 VM 操作者，禁止环境变量注入。"
    printf '#%s ALL=(root) NOPASSWD:NOSETENV: %s *\n' "$TARGET_UID" "/usr/local/libexec/qemu-vmate-host-performance"
    printf '#%s ALL=(root) NOPASSWD:NOSETENV: %s *\n' "$TARGET_UID" "/usr/local/libexec/qemu-vmate-cpu-isolate"
} >"$sudoers_tmp"
chown "$OWNER_UID:$OWNER_GID" "$sudoers_tmp" 2>/dev/null || true
chmod 0440 "$sudoers_tmp"

check_regular_file "$perf_tmp" 755
check_regular_file "$iso_tmp" 755
check_regular_file "$runtime_tmp" 755
check_regular_file "$cgroup_tmp" 755
check_regular_file "$loader_tmp" 755
check_regular_file "$trust_lib_tmp" 755
check_qemu_trust_manifest "$trust_tmp"
check_sudoers_contract "$sudoers_tmp"

# 测试根目录可能没有 visudo；真实系统安装必须通过语法校验。
if [[ -z "$ROOT_PREFIX" ]]; then
    command -v visudo >/dev/null || { echo "ERROR: 缺少 visudo" >&2; exit 1; }
    visudo -cf "$sudoers_tmp" >/dev/null
fi
recheck_qemu_snapshot || {
    echo "ERROR: QEMU 在 staging 期间发生变化；拒绝发布信任清单" >&2
    exit 1
}

# 先移走当前 sudoers，关闭部署窗口内的新 NOPASSWD 调用；旧版工作区授权也纳入
# 同一回滚事务。所有原文件都在各自目录内改名备份，跨文件系统时仍保持原子。
transaction_started=1
for index in "${!transaction_destinations[@]}"; do
    destination="${transaction_destinations[$index]}"
    destination_dir="${destination%/*}"
    [[ ! -d "$destination" || -L "$destination" ]] || {
        echo "ERROR: 固定安装目标不能是目录: $destination" >&2
        exit 1
    }
    backup="$(mktemp "$destination_dir/.qemu-vmate-backup.XXXXXX")"
    rm -f -- "$backup"
    transaction_backups[index]="$backup"
    if [[ -e "$destination" || -L "$destination" ]]; then
        transaction_had_original[index]=1
    else
        transaction_had_original[index]=0
    fi
    # 在任何 rename 前登记本项。信号或 mv 失败时，EXIT 回滚可通过备份路径是否
    # 存在区分“尚未移动”和“已经移动”，不会误删唯一一份旧 helper/sudoers。
    transaction_backup_count=$((index + 1))
    if [[ "${transaction_had_original[$index]}" == "1" ]]; then
        maybe_test_fail "before_backup_move_$index"
        mv -fT -- "$destination" "$backup"
        maybe_test_fail "after_backup_move_$index"
    fi
done
maybe_test_fail after_backup
acquire_cpu_runtime_lock
refuse_active_legacy_cpu_isolation
refuse_inflight_cpu_helpers

# versioned runtime 先发布，main helper 最后切换；即使旧 sudo 调用已在部署前启动，
# 它仍读取旧 ABI 路径。新 sudoers 只有所有文件和 QEMU 快照都就绪后才恢复。
mv -fT -- "$runtime_tmp" "$ISO_RUNTIME_DEST"
maybe_test_fail after_runtime
mv -fT -- "$cgroup_tmp" "$ISO_CGROUP_DEST"
maybe_test_fail after_cgroup
mv -fT -- "$loader_tmp" "$ISO_LOADER_DEST"
maybe_test_fail after_loader
mv -fT -- "$trust_lib_tmp" "$QEMU_TRUST_LIB_DEST"
maybe_test_fail after_trust_library
mv -fT -- "$trust_tmp" "$QEMU_TRUST_DEST"
maybe_test_fail after_trust
mv -fT -- "$perf_tmp" "$PERF_DEST"
maybe_test_fail after_performance
mv -fT -- "$iso_tmp" "$ISO_DEST"
maybe_test_fail after_isolate
recheck_qemu_snapshot || {
    echo "ERROR: QEMU 在发布事务中发生变化；正在回滚" >&2
    exit 1
}
mv -fT -- "$sudoers_tmp" "$SUDOERS_DEST"
maybe_test_fail after_sudoers

verify_installation
transaction_committed=1

echo ">> 已安装 root-owned helper:"
echo "   $PERF_DEST"
echo "   $ISO_DEST"
echo "   $ISO_RUNTIME_DEST"
echo "   $QEMU_TRUST_DEST (QEMU: $QEMU_SOURCE)"
echo ">> sudoers: $SUDOERS_DEST (UID $TARGET_UID, NOPASSWD:NOSETENV)"
