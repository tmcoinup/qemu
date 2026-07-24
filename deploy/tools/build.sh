#!/bin/bash
# build.sh - 配置并构建基于 QEMU 11.0.2 的 vmate 源码树。
#
# 默认构建启用编译器警告即错误（--enable-werror）。如确需追加实验性
# configure 参数，继续使用既有 EXTRA_CONFIGURE 环境变量即可。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
EXPECTED_QEMU_VERSION="11.0.2"

CLEAN="${CLEAN:-0}"
RECONFIG="${RECONFIG:-0}"
DEBUG="${DEBUG:-0}"
JOBS="${JOBS:-$(nproc)}"
VERIFY="${VERIFY:-0}"
# 中文注释：构建依赖与宿主 helper 是两条独立策略。依赖 auto 只在 Debian/Ubuntu
# 本地前台终端补齐；CI、容器和后台绝不隐式修改宿主。
INSTALL_BUILD_DEPS="${INSTALL_BUILD_DEPS:-auto}"
# 中文注释：默认 auto 只在本地交互终端同步宿主 helper；CI、容器和无终端
# 打包任务不会意外修改 /usr/local 或 /etc。需要无人值守安装时显式设为 1，
# 并预先配置可用的非交互 sudo；只生成构建产物时显式设为 0。
INSTALL_HOST_HELPERS="${INSTALL_HOST_HELPERS:-auto}"

usage() {
    cat <<'EOF'
用法: deploy/tools/build.sh [选项]

选项（均保留对应环境变量用法）:
  --clean        / CLEAN=1       先删除 build/，执行全新构建
  --reconfig     / RECONFIG=1    保留 build/，但强制重跑 configure
  --debug        / DEBUG=1       启用调试信息并禁止 strip
  --jobs N       / JOBS=N        设置 ninja 并行度（默认 nproc）
  --verify       / VERIFY=1      构建后运行 verify-stealth.sh
  --install-build-deps             强制安装缺失的构建依赖
                  INSTALL_BUILD_DEPS=1
  --no-install-build-deps          禁止系统安装；缺依赖仍 fail closed
                  INSTALL_BUILD_DEPS=0
  --install-host-helpers          强制构建后安装并校验宿主 helper
                  INSTALL_HOST_HELPERS=1
  --no-install-host-helpers       跳过宿主 helper（不影响构建依赖策略）
                  INSTALL_HOST_HELPERS=0
  -h, --help                    显示本帮助

构建依赖默认策略:
  INSTALL_BUILD_DEPS=auto（默认）在 Debian/Ubuntu 本地前台终端缺包时自动运行 APT；
  CI、容器、后台或其它发行版不隐式修改系统。显式强制的无终端任务只使用 sudo -n。

宿主 helper 默认策略:
  INSTALL_HOST_HELPERS=auto（默认）只在本地前台交互终端自动安装；CI、容器或后台跳过。
  安装发生在编译和可选 --verify 成功后，过程中可能提示一次 sudo 密码。

额外 configure 参数:
  EXTRA_CONFIGURE="--enable-foo" deploy/tools/build.sh
EOF
}

while (( $# )); do
    case "$1" in
        --clean)    CLEAN=1 ;;
        --reconfig) RECONFIG=1 ;;
        --debug)    DEBUG=1 ;;
        --verify)   VERIFY=1 ;;
        --install-build-deps) INSTALL_BUILD_DEPS=1 ;;
        --no-install-build-deps) INSTALL_BUILD_DEPS=0 ;;
        --install-host-helpers) INSTALL_HOST_HELPERS=1 ;;
        --no-install-host-helpers) INSTALL_HOST_HELPERS=0 ;;
        --jobs)     JOBS="$2"; shift ;;
        --jobs=*)   JOBS="${1#*=}" ;;
        -h|--help)  usage; exit 0 ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
    shift
done

case "$INSTALL_BUILD_DEPS" in
    auto|0|1) ;;
    *)
        echo "FAIL: INSTALL_BUILD_DEPS 只接受 auto、0 或 1" >&2
        exit 2
        ;;
esac
case "$INSTALL_HOST_HELPERS" in
    auto|0|1) ;;
    *)
        echo "FAIL: INSTALL_HOST_HELPERS 只接受 auto、0 或 1" >&2
        exit 2
        ;;
esac

cd "$REPO_ROOT"

# ---------- 源码版本预检 ----------
# 中文注释：构建脚本与定制设备参数以 11.0.2 为基线。这里显式拒绝其他源码
# 版本，避免误用旧 checkout 或把旧 build/ 产物当成升级后的 vmate。
source_version="$(tr -d '[:space:]' < VERSION)"
if [[ "$source_version" != "$EXPECTED_QEMU_VERSION" ]]; then
    echo "FAIL: 源码 VERSION=$source_version，期望 $EXPECTED_QEMU_VERSION" >&2
    echo "      请切换到正确的 vmate 分支后重新执行。" >&2
    exit 1
fi

# ---------- 构建依赖 ----------
# 依赖保障必须早于 Git 版本证明；否则全新环境缺 git 时会在自动安装前退出。
BUILD_DEPS_HELPER="$HERE/lib/build-dependencies.sh"
[[ -r "$BUILD_DEPS_HELPER" ]] || {
    echo "FAIL: 缺少构建依赖 helper: $BUILD_DEPS_HELPER" >&2
    exit 1
}
# shellcheck source=lib/build-dependencies.sh
source "$BUILD_DEPS_HELPER"
build_dependencies_ensure "$INSTALL_BUILD_DEPS" || exit $?

# ---------- 运行时代码版本证明 ----------
# 上游 qemu-version.sh 的 `git describe --dirty` 会把 deploy 脚本或固件变化也
# 计入 QEMU ELF 的 dirty 标记，但这些资产并不是 C/Rust 运行时编译输入，发布时
# 会由独立 stage 清单记录。这里固定 HEAD 描述，并只把 deploy 之外的已跟踪、
# 未跟踪变化标为 dirty；构建目录等 ignored 产物不会污染版本。
QEMU_RUNTIME_PKGVERSION=""
if [[ -e .git ]]; then
    command -v git >/dev/null 2>&1 || {
        echo "FAIL: Git checkout 中缺少 git，无法生成 QEMU 运行时代码版本证明" >&2
        exit 1
    }
    if ! QEMU_RUNTIME_PKGVERSION="$(
        git describe --match 'v*' --always --abbrev=10 HEAD
    )"; then
        echo "FAIL: 无法解析 QEMU HEAD 版本" >&2
        exit 1
    fi
    QEMU_RUNTIME_STATE="$(
        git status --porcelain --untracked-files=all -- \
            . ':(exclude)deploy'
    )" || {
        echo "FAIL: 无法检查 QEMU 非 deploy 运行时代码状态" >&2
        exit 1
    }
    if [[ -n "$QEMU_RUNTIME_STATE" ]]; then
        QEMU_RUNTIME_PKGVERSION="${QEMU_RUNTIME_PKGVERSION}-dirty"
    fi
    echo ">> QEMU runtime pkgversion: $QEMU_RUNTIME_PKGVERSION"
fi

# ---------- vmate 定制状态提示（不强制） ----------
if ! grep -q 'Ryzen3-1200' target/i386/cpu.c 2>/dev/null; then
    echo ">> NOTE: 当前 11.0.2 源码未检测到 vmate Ryzen3-1200 定制。"
    echo ">>       历史 9.2 补丁不能直接重放；请切换到完整 vmate 分支。"
    echo ""
fi

# ---------- 构建目录 ----------
if (( CLEAN )); then
    echo ">> clean build/"
    rm -rf build
fi
mkdir -p build
cd build

CFG_FLAGS=(
    --target-list=x86_64-softmmu
    --enable-kvm
    --enable-linux-aio
    --enable-linux-io-uring
    --enable-slirp
    --enable-virtfs
    --enable-spice
    --enable-virglrenderer
    --enable-opengl
    --enable-sdl
    --enable-vnc
    --enable-werror
    --disable-docs
)
if (( DEBUG )); then
    CFG_FLAGS+=(--enable-debug --disable-strip)
fi
if [[ -n "${EXTRA_CONFIGURE:-}" ]]; then
    # 中文注释：保持历史接口的按空白拆分语义；额外参数放在默认参数之后，
    # 便于调用方覆盖非安全关键的 configure 选项。
    # shellcheck disable=SC2206
    CFG_FLAGS+=($EXTRA_CONFIGURE)
fi
# 版本证明属于发布安全参数，必须晚于实验性覆盖；运行时代码脏时调用方不能用
# EXTRA_CONFIGURE 伪造 clean 版本。源码包没有 Git 元数据时保留上游空值行为。
if [[ -n "$QEMU_RUNTIME_PKGVERSION" ]]; then
    CFG_FLAGS+=(--with-pkgversion="$QEMU_RUNTIME_PKGVERSION")
fi

aio_build_contract_ready() {
    [[ -r config-host.h ]] &&
        grep -Eq '^#define[[:space:]]+CONFIG_LINUX_AIO([[:space:]]+1)?[[:space:]]*$' \
            config-host.h &&
        grep -Eq '^#define[[:space:]]+CONFIG_LINUX_IO_URING([[:space:]]+1)?[[:space:]]*$' \
            config-host.h
}

# 中文注释：升级前创建的 build/ 会保留旧 Meson feature 值；只运行 ninja 不会
# 启用新增后端。检测最终生成的 config-host.h，比猜测 Meson CLI 状态更可靠，
# 并能让普通 build.sh 自动完成一次必要的重配置。
AIO_RECONFIG=0
if [[ -f build.ninja ]] && ! aio_build_contract_ready; then
    AIO_RECONFIG=1
    echo ">> build AIO 契约已升级，自动重新 configure"
fi

if (( RECONFIG || AIO_RECONFIG )) || [[ ! -f build.ninja ]]; then
    echo ">> configure ${CFG_FLAGS[*]}"
    ../configure "${CFG_FLAGS[@]}"
elif [[ -n "$QEMU_RUNTIME_PKGVERSION" ]]; then
    # 已有 build 也必须立即同步新契约，不能要求用户猜测额外追加 --reconfig。
    # Meson 只更新 pkgversion，保留该目录其它已配置选项；ninja 随后负责重链。
    MESON="$REPO_ROOT/build/pyvenv/bin/meson"
    [[ -x "$MESON" ]] || {
        echo "FAIL: 已有 build 缺少可执行 Meson，无法同步运行时代码版本证明" >&2
        exit 1
    }
    "$MESON" configure . "-Dpkgversion=$QEMU_RUNTIME_PKGVERSION"
fi

aio_build_contract_ready || {
    echo "FAIL: configure 未启用 CONFIG_LINUX_AIO/CONFIG_LINUX_IO_URING" >&2
    echo "      请确认 libaio-dev、liburing-dev 可用且未被 EXTRA_CONFIGURE 禁用。" >&2
    exit 1
}

echo ">> ninja -j$JOBS"
ninja -j"$JOBS"

BIN="$REPO_ROOT/build/qemu-system-x86_64"
if [[ ! -f "$BIN" || ! -s "$BIN" || ! -x "$BIN" ]]; then
    echo "FAIL: $BIN 未生成有效的非空可执行文件" >&2
    exit 1
fi

echo
echo "=== build artifact ==="
printf "  binary : %s\n"   "$BIN"
printf "  size   : %s\n"   "$(stat -c%s "$BIN" | numfmt --to=iec)"
printf "  sha256 : %s\n"   "$(sha256sum "$BIN" | awk '{print $1}')"
printf "  mtime  : %s\n"   "$(stat -c%y "$BIN")"

if (( VERIFY )); then
    echo
    echo "=== running verify-stealth.sh ==="
    "$HERE/../scripts/verify-stealth.sh"
fi

# 可选 verify 完成后再固定将要交给 root installer 的 dev/inode/hash。installer 会
# 重新计算并精确比较，避免长构建后的 sudo 等待窗口登记另一份未验证二进制。
QEMU_TRUST_META_BEFORE="$(stat -Lc '%d %i' -- "$BIN")"
QEMU_TRUST_SHA256="$(sha256sum -- "$BIN")"
QEMU_TRUST_SHA256="${QEMU_TRUST_SHA256%% *}"
QEMU_TRUST_META_AFTER="$(stat -Lc '%d %i' -- "$BIN")"
[[ "$QEMU_TRUST_META_BEFORE" == "$QEMU_TRUST_META_AFTER" ]] || {
    echo "FAIL: QEMU 在生成构建信任快照时被替换，请重新编译" >&2
    exit 1
}
read -r QEMU_TRUST_DEVICE QEMU_TRUST_INODE <<<"$QEMU_TRUST_META_AFTER"

host_helper_terminal_foreground() {
    local process_groups self_pgrp tty_pgrp

    # stdin 与 stderr 都必须是终端，且当前进程组必须拥有该终端。仅检查 -t 会把
    # `build.sh &` 误判成可交互，sudo 随后因读取后台终端而收到 SIGTTIN/Stopped。
    [[ -t 0 && -t 2 ]] || return 1
    process_groups="$(ps -o pgid= -o tpgid= -p "$$" 2>/dev/null)" || return 1
    read -r self_pgrp tty_pgrp <<<"$process_groups"
    [[ "$self_pgrp" =~ ^[0-9]+$ && "$tty_pgrp" =~ ^[0-9]+$ &&
       "$tty_pgrp" != "0" && "$self_pgrp" == "$tty_pgrp" ]]
}

host_helper_container_detected() {
    [[ -e /.dockerenv || -e /run/.containerenv ]] && return 0
    if command -v systemd-detect-virt >/dev/null 2>&1 &&
       systemd-detect-virt --quiet --container 2>/dev/null; then
        return 0
    fi
    grep -Eq '(docker|containerd|kubepods|libpod|lxc)' /proc/1/cgroup 2>/dev/null
}

run_host_helper_as_root() {
    if (( EUID == 0 )); then
        # 直接 root 部署允许显式 VMATE_TARGET_UID，但绝不继承测试安装根或另一份
        # QEMU 环境覆盖；build 始终把当前构建产物作为 CLI 参数传入。
        (
            unset VMATE_INSTALL_ROOT VMATE_QEMU_BINARY
            "$@"
        )
        return
    fi
    if ! command -v sudo >/dev/null 2>&1; then
        echo "FAIL: 自动安装宿主 helper 需要 sudo；当前系统未找到 sudo" >&2
        return 1
    fi
    # sudo 必须直接看到固定 installer 路径，不能包装成宽泛的 `/usr/bin/env`；这样
    # 无人值守部署可以为 installer 配置精确规则。SUDO_UID 由 sudo 自己生成。
    (
        unset VMATE_INSTALL_ROOT VMATE_QEMU_BINARY VMATE_TARGET_UID
        if host_helper_terminal_foreground; then
            sudo -- "$@"
        else
            # 强制的无人值守安装只能使用已有凭据或精确 NOPASSWD，-n 保证立即失败。
            sudo -n -- "$@"
        fi
    )
}

install_host_helpers_after_build() {
    local setup="$REPO_ROOT/deploy/scripts/setup-host-helpers.sh"

    [[ -x "$setup" ]] || {
        echo "FAIL: 找不到可执行的宿主 helper 安装器: $setup" >&2
        return 1
    }
    if (( EUID == 0 )) && [[ -z "${SUDO_UID:-}" && -z "${VMATE_TARGET_UID:-}" ]]; then
        echo "FAIL: 不应直接用 root 构建，否则无法确定 sudoers 应授权的普通用户。" >&2
        echo "      请以普通用户运行 build.sh；确需 root 时设置 VMATE_TARGET_UID。" >&2
        return 1
    fi

    echo
    echo "=== installing host helpers ==="
    echo ">> 将 root-owned helper 和当前 QEMU 信任摘要同步到宿主机"
    if ! run_host_helper_as_root "$setup" install "--qemu=$BIN" \
            "--expect-device=$QEMU_TRUST_DEVICE" \
            "--expect-inode=$QEMU_TRUST_INODE" \
            "--expect-sha256=$QEMU_TRUST_SHA256"; then
        echo "FAIL: QEMU 已编译，但宿主 helper 安装失败；未报告整体构建完成。" >&2
        return 1
    fi
    if ! run_host_helper_as_root "$setup" check; then
        echo "FAIL: QEMU 已编译，但宿主 helper 安装后校验失败。" >&2
        return 1
    fi
}

case "$INSTALL_HOST_HELPERS" in
    1)
        install_host_helpers_after_build
        ;;
    auto)
        if [[ -n "${CI:-}" ]] || host_helper_container_detected ||
           ! host_helper_terminal_foreground; then
            echo
            echo ">> NOTE: CI/容器/非前台交互终端，跳过宿主 helper 安装。"
            echo ">>       目标宿主无人值守部署请使用 --install-host-helpers；仅构建可显式使用 --no-install-host-helpers。"
        else
            install_host_helpers_after_build
        fi
        ;;
    0)
        echo
        echo ">> NOTE: 已按 --no-install-host-helpers 跳过宿主 helper 安装。"
        ;;
esac

echo
echo "=== build complete ==="
