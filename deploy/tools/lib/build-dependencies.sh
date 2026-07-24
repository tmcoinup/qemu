# shellcheck shell=bash
# QEMU Linux 构建依赖检测与 Debian/Ubuntu 自动安装。
#
# 调用方先解析 INSTALL_BUILD_DEPS=auto|0|1，再执行：
#   build_dependencies_ensure "$INSTALL_BUILD_DEPS"

BUILD_DEP_PACKAGES=()
BUILD_DEP_REASONS=()
BUILD_DEP_ALLOWED_PACKAGES=(
    build-essential
    bzip2
    git
    meson
    ninja-build
    pkg-config
    python3
    python3-pip
    python3-setuptools
    python3-venv
    python3-wheel
    libaio-dev
    libepoxy-dev
    libglib2.0-dev
    libpixman-1-dev
    libseccomp-dev
    libsdl2-dev
    libslirp-dev
    libspice-server-dev
    liburing-dev
    libvirglrenderer-dev
    zlib1g-dev
)

build_terminal_foreground() {
    local process_groups self_pgrp tty_pgrp

    # 仅检查 -t 会把 `build.sh &` 误判成可交互，sudo 随后可能因读取后台终端
    # 收到 SIGTTIN。进程组必须同时拥有 stdin 与 stderr 所在的控制终端。
    [[ -t 0 && -t 2 ]] || return 1
    process_groups="$(ps -o pgid= -o tpgid= -p "$$" 2>/dev/null)" || return 1
    read -r self_pgrp tty_pgrp <<<"$process_groups"
    [[ "$self_pgrp" =~ ^[0-9]+$ && "$tty_pgrp" =~ ^[0-9]+$ &&
       "$tty_pgrp" != 0 && "$self_pgrp" == "$tty_pgrp" ]]
}

build_container_detected() {
    [[ -e /.dockerenv || -e /run/.containerenv ]] && return 0
    if command -v systemd-detect-virt >/dev/null 2>&1 &&
       systemd-detect-virt --quiet --container 2>/dev/null; then
        return 0
    fi
    grep -Eq '(docker|containerd|kubepods|libpod|lxc)' \
        /proc/1/cgroup 2>/dev/null
}

build_dep_package_allowed() {
    local package="$1" allowed
    for allowed in "${BUILD_DEP_ALLOWED_PACKAGES[@]}"; do
        [[ "$package" == "$allowed" ]] && return 0
    done
    return 1
}

build_dep_add() {
    local package="$1" reason="$2" existing

    build_dep_package_allowed "$package" || {
        echo "FAIL: 依赖检测返回未授权的 APT 包名: $package" >&2
        return 1
    }

    for existing in "${BUILD_DEP_PACKAGES[@]}"; do
        [[ "$existing" == "$package" ]] && return 0
    done
    BUILD_DEP_PACKAGES+=("$package")
    BUILD_DEP_REASONS+=("$reason")
}

build_dependencies_validate_packages() {
    local package

    if (( ${#BUILD_DEP_PACKAGES[@]} != ${#BUILD_DEP_REASONS[@]} )); then
        echo "FAIL: 构建依赖包名与诊断数量不一致" >&2
        return 1
    fi
    for package in "${BUILD_DEP_PACKAGES[@]}"; do
        build_dep_package_allowed "$package" || {
            echo "FAIL: 构建依赖包含非固定 APT 包名: $package" >&2
            return 1
        }
    done
}

build_dependencies_detect_python() {
    local report package reason

    if ! command -v python3 >/dev/null 2>&1; then
        build_dep_add python3 "缺少 python3" || return 1
        build_dep_add python3-venv "无法检测 venv/ensurepip" || return 1
        build_dep_add python3-pip "无法检测 pip" || return 1
        build_dep_add python3-setuptools "无法检测 setuptools" || return 1
        build_dep_add python3-wheel "无法检测 wheel" || return 1
        return 0
    fi

    if ! report="$(python3 - <<'PY'
import importlib.util
import re
from importlib import metadata


def version_tuple(raw_version):
    parts = [int(item) for item in re.findall(r"\d+", raw_version)[:3]]
    return tuple((parts + [0, 0, 0])[:3])


if importlib.util.find_spec("venv") is None:
    print("python3-venv|缺少 Python venv 模块")
if (importlib.util.find_spec("ensurepip") is None and
        importlib.util.find_spec("pip") is None):
    print("python3-pip|ensurepip 与 pip 均不可用")

requirements = {
    "setuptools": ("python3-setuptools", (44, 1, 1)),
    "wheel": ("python3-wheel", (0, 34, 2)),
}
for module, (package, minimum) in requirements.items():
    try:
        installed = metadata.version(module)
    except metadata.PackageNotFoundError:
        print(f"{package}|缺少 Python 包 {module}")
        continue
    if version_tuple(installed) < minimum:
        expected = ".".join(str(item) for item in minimum)
        print(f"{package}|Python 包 {module}={installed}，最低要求 {expected}")
PY
)"; then
        echo "FAIL: 无法检测 QEMU Python 构建依赖" >&2
        return 1
    fi

    while IFS='|' read -r package reason; do
        if [[ -n "$package" ]]; then
            build_dep_add "$package" "$reason" || return 1
        fi
    done <<<"$report"
    return 0
}

build_dependencies_detect() {
    local spec capability package
    local tool_specs=(
        "git:git"
        "gcc:build-essential"
        "g++:build-essential"
        "make:build-essential"
        "bzip2:bzip2"
        "ninja:ninja-build"
        "meson:meson"
        "pkg-config:pkg-config"
    )
    local pkg_specs=(
        "glib-2.0:libglib2.0-dev"
        "pixman-1:libpixman-1-dev"
        "zlib:zlib1g-dev"
        "slirp:libslirp-dev"
        "libseccomp:libseccomp-dev"
        "sdl2:libsdl2-dev"
        "epoxy:libepoxy-dev"
        "virglrenderer:libvirglrenderer-dev"
        "spice-server:libspice-server-dev"
        "liburing:liburing-dev"
    )

    BUILD_DEP_PACKAGES=()
    BUILD_DEP_REASONS=()
    for spec in "${tool_specs[@]}"; do
        capability="${spec%%:*}"
        package="${spec#*:}"
        if ! command -v "$capability" >/dev/null 2>&1; then
            build_dep_add "$package" "缺少命令 $capability" || return 1
        fi
    done

    if command -v pkg-config >/dev/null 2>&1; then
        for spec in "${pkg_specs[@]}"; do
            capability="${spec%%:*}"
            package="${spec#*:}"
            if ! pkg-config --exists "$capability" 2>/dev/null; then
                build_dep_add "$package" \
                    "pkg-config 缺少 $capability" || return 1
            fi
        done
        if ! pkg-config --exists libaio 2>/dev/null &&
           [[ ! -r /usr/include/libaio.h ]]; then
            build_dep_add libaio-dev "缺少 libaio.h/libaio" || return 1
        fi
    else
        # 没有 pkg-config 时无法逐项检测；加入完整、固定的开发包集合，APT
        # 对已经安装的包保持幂等，安装后再用能力检测完整复核。
        for spec in "${pkg_specs[@]}"; do
            build_dep_add "${spec#*:}" \
                "缺少 pkg-config，无法检测 ${spec%%:*}" || return 1
        done
        if [[ ! -r /usr/include/libaio.h ]]; then
            build_dep_add libaio-dev "缺少 libaio.h" || return 1
        fi
    fi
    build_dependencies_detect_python
}

build_dependencies_report() {
    local index

    echo ">> 缺少 QEMU 构建依赖:"
    for index in "${!BUILD_DEP_PACKAGES[@]}"; do
        printf '   %-25s %s\n' \
            "${BUILD_DEP_PACKAGES[$index]}" "${BUILD_DEP_REASONS[$index]}"
    done
}

build_dependencies_manual_hint() {
    if build_dependencies_is_debian; then
        printf '  手动修复: sudo apt-get update && sudo apt-get install -y'
        printf ' %q' "${BUILD_DEP_PACKAGES[@]}"
        printf '\n'
    else
        echo "  当前不是 Debian/Ubuntu；请按上述缺失能力使用发行版包管理器安装。"
    fi
    echo "  依赖说明: deploy/docs/DEVELOPMENT-DEPENDENCIES.md"
}

build_dependencies_is_debian() {
    [[ -r /etc/debian_version && -x /usr/bin/apt-get ]]
}

build_dependencies_run_root() {
    if (( EUID == 0 )); then
        "$@"
        return
    fi
    command -v sudo >/dev/null 2>&1 || {
        echo "FAIL: 自动安装构建依赖需要 sudo；当前系统未找到 sudo" >&2
        return 1
    }
    if build_terminal_foreground; then
        sudo -- "$@"
    else
        sudo -n -- "$@"
    fi
}

build_dependencies_install() {
    echo ">> 自动安装缺失的 QEMU 构建依赖（APT）"
    if ! build_dependencies_run_root \
            /usr/bin/apt-get -o DPkg::Lock::Timeout=120 update; then
        echo "FAIL: apt-get update 失败" >&2
        return 1
    fi
    if ! build_dependencies_run_root \
            /usr/bin/apt-get -o DPkg::Lock::Timeout=120 install \
            --yes --no-install-recommends "${BUILD_DEP_PACKAGES[@]}"; then
        echo "FAIL: apt-get install 失败" >&2
        return 1
    fi
    hash -r
}

build_dependencies_ensure() {
    local mode="$1"

    build_dependencies_detect || return 1
    build_dependencies_validate_packages || return 1
    (( ${#BUILD_DEP_PACKAGES[@]} )) || {
        echo ">> build deps:  complete"
        return 0
    }
    build_dependencies_report

    case "$mode" in
        0)
            echo "FAIL: 已禁用构建依赖自动安装，依赖门禁仍保持启用" >&2
            build_dependencies_manual_hint >&2
            return 1
            ;;
        auto)
            if [[ -n "${CI:-}" ]] || build_container_detected ||
               ! build_terminal_foreground; then
                echo "FAIL: auto 模式不会在 CI、容器或后台任务中隐式修改宿主" >&2
                build_dependencies_manual_hint >&2
                return 1
            fi
            ;;
        1) ;;
        *)
            echo "FAIL: INSTALL_BUILD_DEPS 只接受 auto、0 或 1" >&2
            return 2
            ;;
    esac

    if ! build_dependencies_is_debian; then
        echo "FAIL: 自动安装仅支持 Debian/Ubuntu APT；不猜测其它包管理器" >&2
        build_dependencies_manual_hint >&2
        return 1
    fi
    build_dependencies_install || {
        build_dependencies_manual_hint >&2
        return 1
    }
    build_dependencies_detect || return 1
    build_dependencies_validate_packages || return 1
    if (( ${#BUILD_DEP_PACKAGES[@]} )); then
        echo "FAIL: APT 完成后构建依赖仍不完整" >&2
        build_dependencies_report >&2
        return 1
    fi
    echo ">> build deps:  installed and verified"
}
