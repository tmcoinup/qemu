#!/usr/bin/env bash
# 安装宿主调优/CPU隔离 helper 的 root-owned 固定副本和最小 sudoers 授权。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT_PREFIX="${VMATE_INSTALL_ROOT:-}"
TARGET_UID="${VMATE_TARGET_UID:-${SUDO_UID:-$(id -u)}}"
LIBEXEC_DIR="$ROOT_PREFIX/usr/local/libexec"
SUDOERS_DIR="$ROOT_PREFIX/etc/sudoers.d"
PERF_DEST="$LIBEXEC_DIR/qemu-vmate-host-performance"
ISO_DEST="$LIBEXEC_DIR/qemu-vmate-cpu-isolate"
ISO_RUNTIME_DEST="$LIBEXEC_DIR/qemu-vmate-cpu-isolate-runtime.sh"
QEMU_TRUST_DEST="$LIBEXEC_DIR/qemu-vmate-cpu-isolate-qemu.conf"
SUDOERS_DEST="$SUDOERS_DIR/qemu-vmate-host"
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

check_install_directory() {
    local metadata
    [[ -d "$LIBEXEC_DIR" && ! -L "$LIBEXEC_DIR" ]] || return 1
    metadata="$(stat -Lc '%u:%g:%a' "$LIBEXEC_DIR" 2>/dev/null || true)"
    [[ "$metadata" == "$OWNER_UID:$OWNER_GID:755" ]]
}

check_qemu_trust_manifest() {
    local line key value actual_meta actual_digest
    local trust_path="" trust_sha256="" trust_device="" trust_inode=""

    check_regular_file "$QEMU_TRUST_DEST" 644 || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == *=* ]] || return 1
        key="${line%%=*}"; value="${line#*=}"
        case "$key" in
            path) [[ -z "$trust_path" ]] || return 1; trust_path="$value" ;;
            sha256) [[ -z "$trust_sha256" ]] || return 1; trust_sha256="$value" ;;
            device) [[ -z "$trust_device" ]] || return 1; trust_device="$value" ;;
            inode) [[ -z "$trust_inode" ]] || return 1; trust_inode="$value" ;;
            *) return 1 ;;
        esac
    done < "$QEMU_TRUST_DEST"
    [[ "$trust_path" == /* && -f "$trust_path" && ! -L "$trust_path" &&
       -x "$trust_path" &&
       "$trust_sha256" =~ ^[0-9a-f]{64}$ && "$trust_device" =~ ^[0-9]+$ &&
       "$trust_inode" =~ ^[0-9]+$ ]] || return 1
    actual_meta="$(stat -Lc '%d:%i' -- "$trust_path" 2>/dev/null)" || return 1
    [[ "$actual_meta" == "$trust_device:$trust_inode" ]] || return 1
    actual_digest="$(sha256sum -- "$trust_path" 2>/dev/null)" || return 1
    [[ "${actual_digest%% *}" == "$trust_sha256" ]] || return 1
}

check_sudoers_contract() {
    local expected actual

    check_regular_file "$SUDOERS_DEST" 440 || return 1
    expected="$(
        printf '%s\n' '# 由 qemu vmate setup-host-helpers.sh 生成；禁止环境变量注入。'
        printf '#%s ALL=(root) NOPASSWD:NOSETENV: %s *\n' \
            "$TARGET_UID" "/usr/local/libexec/qemu-vmate-host-performance"
        printf '#%s ALL=(root) NOPASSWD:NOSETENV: %s *\n' \
            "$TARGET_UID" "/usr/local/libexec/qemu-vmate-cpu-isolate"
    )"
    actual="$(<"$SUDOERS_DEST")" || return 1
    [[ "$actual" == "$expected" ]]
}

QEMU_OVERRIDE="${VMATE_QEMU_BINARY:-}"
case "${1:-install}" in
    install|--install)
        (( $# <= 2 )) || { echo "用法: sudo $0 install [--qemu=/path]" >&2; exit 2; }
        if (( $# == 2 )); then
            [[ "$2" == --qemu=* && -n "${2#--qemu=}" ]] \
                || { echo "ERROR: 第二参数必须是 --qemu=/path" >&2; exit 2; }
            QEMU_OVERRIDE="${2#--qemu=}"
        fi
        ;;
    check|--check)
        (( $# == 1 )) || { echo "用法: sudo $0 check" >&2; exit 2; }
        check_install_directory || {
            echo "ERROR: libexec 必须为可信 owner 的非符号链接 0755 目录" >&2
            exit 1
        }
        check_regular_file "$PERF_DEST" 755 || exit 1
        check_regular_file "$ISO_DEST" 755 || exit 1
        check_regular_file "$ISO_RUNTIME_DEST" 755 || exit 1
        check_qemu_trust_manifest || {
            echo "ERROR: QEMU root-owned 信任清单无效或构建产物已变化" >&2
            exit 1
        }
        check_sudoers_contract || {
            echo "ERROR: sudoers 必须为可信 owner 的 0440 单链接普通文件，且内容精确匹配" >&2
            exit 1
        }
        echo "PASS: host helpers 安装契约有效"
        exit 0
        ;;
    *) echo "用法: sudo $0 [install [--qemu=/path]|check]" >&2; exit 2 ;;
esac

# 开发版 QEMU 可以位于用户可写工作树，但 NOPASSWD helper 只信任管理员安装时记录的
# 精确 canonical path、device/inode 与 SHA-256。重新编译后必须重新安装清单；这样既
# 支持仓库自建二进制，也不再允许任意同名伪进程占用宿主独占 CPU。
QEMU_SOURCE="${QEMU_OVERRIDE:-$HERE/../../build/qemu-system-x86_64}"
QEMU_SOURCE="$(realpath -e -- "$QEMU_SOURCE" 2>/dev/null)" || {
    echo "ERROR: 找不到可信 QEMU；请先构建或设置 VMATE_QEMU_BINARY" >&2
    exit 1
}
[[ -f "$QEMU_SOURCE" && -x "$QEMU_SOURCE" && "$QEMU_SOURCE" != *$'\n'* &&
   "$QEMU_SOURCE" != *$'\r'* ]] || {
    echo "ERROR: 可信 QEMU 必须是可执行普通文件且路径不能含换行" >&2
    exit 1
}
QEMU_META="$(stat -Lc '%d %i' -- "$QEMU_SOURCE")"
read -r QEMU_DEVICE QEMU_INODE <<<"$QEMU_META"
QEMU_SHA256="$(sha256sum -- "$QEMU_SOURCE")"
QEMU_SHA256="${QEMU_SHA256%% *}"

install -d -o "$OWNER_UID" -g "$OWNER_GID" -m 0755 "$LIBEXEC_DIR" "$SUDOERS_DIR"
install -o "$OWNER_UID" -g "$OWNER_GID" -m 0755 "$HERE/host-performance.sh" "$PERF_DEST"
install -o "$OWNER_UID" -g "$OWNER_GID" -m 0755 "$HERE/host-cpu-isolate.sh" "$ISO_DEST"
install -o "$OWNER_UID" -g "$OWNER_GID" -m 0755 \
    "$HERE/host-cpu-isolate-runtime.sh" "$ISO_RUNTIME_DEST"
trust_tmp="$(mktemp "$LIBEXEC_DIR/.qemu-vmate-cpu-trust.XXXXXX")"
{
    printf 'path=%s\n' "$QEMU_SOURCE"
    printf 'sha256=%s\n' "$QEMU_SHA256"
    printf 'device=%s\n' "$QEMU_DEVICE"
    printf 'inode=%s\n' "$QEMU_INODE"
} > "$trust_tmp"
chown "$OWNER_UID:$OWNER_GID" "$trust_tmp" 2>/dev/null || true
chmod 0644 "$trust_tmp"
mv -fT -- "$trust_tmp" "$QEMU_TRUST_DEST"

sudoers_tmp="$(mktemp "$SUDOERS_DIR/.qemu-vmate-host.XXXXXX")"
cleanup() { rm -f "$sudoers_tmp"; }
trap cleanup EXIT
{
    echo "# 由 qemu vmate setup-host-helpers.sh 生成；禁止环境变量注入。"
    printf '#%s ALL=(root) NOPASSWD:NOSETENV: %s *\n' "$TARGET_UID" "/usr/local/libexec/qemu-vmate-host-performance"
    printf '#%s ALL=(root) NOPASSWD:NOSETENV: %s *\n' "$TARGET_UID" "/usr/local/libexec/qemu-vmate-cpu-isolate"
} >"$sudoers_tmp"
chown "$OWNER_UID:$OWNER_GID" "$sudoers_tmp" 2>/dev/null || true
chmod 0440 "$sudoers_tmp"

# 测试根目录可能没有 visudo；真实系统安装必须通过语法校验。
if [[ -z "$ROOT_PREFIX" ]]; then
    command -v visudo >/dev/null || { echo "ERROR: 缺少 visudo" >&2; exit 1; }
    visudo -cf "$sudoers_tmp" >/dev/null
fi
mv -fT -- "$sudoers_tmp" "$SUDOERS_DEST"
trap - EXIT

# 删除旧版直接授权 Git 工作区脚本的规则；不存在时无副作用。
rm -f "$SUDOERS_DIR/qemu-hostperf" "$SUDOERS_DIR/qemu-cpuiso"

echo ">> 已安装 root-owned helper:"
echo "   $PERF_DEST"
echo "   $ISO_DEST"
echo "   $ISO_RUNTIME_DEST"
echo "   $QEMU_TRUST_DEST (QEMU: $QEMU_SOURCE)"
echo ">> sudoers: $SUDOERS_DEST (UID $TARGET_UID, NOPASSWD:NOSETENV)"
